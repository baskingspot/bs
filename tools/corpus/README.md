# Real-world corpus

`tools/corpus/run.py` builds pinned, pure-Zig projects with bs and with
upstream zig 0.17.1, runs what they build, and compares the two. It finds
the bugs real programs hit that `test/behavior` and std's tests miss.

```sh
zig build -Doptimize=ReleaseFast
python3 tools/corpus/run.py                      # every project and target
python3 tools/corpus/run.py --projects zls,z2d --targets test
python3 tools/corpus/run.py --bs-only --no-edit # quick check after a fix
```

Options: `--bs PATH`, `--zig PATH`, `--refresh` (record the compile
commands again), `--list` (record and list them only), `--bs-only` (keep
the last upstream results), `--no-edit` (skip the edit builds), `--no-run`
(build only), `--cache-check` (bs's edit builds check themselves against
a full build with `BS_CACHE_VERIFY` and `BS_CACHE_CHECK`; not timed),
`--samples N` (time each cold-local and edit build N times and keep the
median), `--donors` (also build with donors, bs's first build in a
fresh checkout: the cold build without donors publishes none, so the
first sample takes what the global store holds, often another target's
donor, and later samples the target's own; the binary that runs is the
donor build's, and a donor build that fails is a divergence),
`--results NAME` (write `.work/NAME.json` and
`.work/NAME.md` instead of `results.json` and `scoreboard.md`).
`bench/scoreboard.py` runs it with `--no-run --donors --samples 3`.

`tools/corpus/steps.py` checks whole builds instead: each project's
`build` steps (install and test) under `zig build` and `bs build`, each
with an empty local cache, its own install prefix and `--summary all`.
A step list matches when the exit status, the step tree (statuses and
test counts, without timings) and the installed files (paths, executable
bits, and contents other than ELF files and archives) are the same. It
takes `--projects`, `--bs`, `--zig`, `--bs-only`, `--timeout` and
`--results` (default `steps`: `.work/steps.json` and `.work/steps.md`),
skips anyzig unless named, and clones projects as run.py does, without
recording their commands.

## How it works

- [`manifest.json`](manifest.json) lists each project: repository, pinned
  commit (a commit whose `build.zig.zon` declares `minimum_zig_version`
  0.17.0 or which CI builds with 0.17.0), the `zig build` steps that build
  its targets (`build`), and the targets: compile steps named by their
  `--name`, how to run each (`run`: arguments for an executable; tests run
  without arguments), and an `edit` line for the edit build. Recording
  anyzig's `test` step runs its tests, which download several Zig
  releases (about 4 GB); delete ~/.local/share/anyzig afterwards. Run arguments
  and `cwd` may name `{src}` (the checkout), `{zig_lib}` (upstream's lib
  directory), `{gen}` (the generation cache, where code generators write)
  or a `fetch`ed package, and a glob there names its first match. A run's
  `output` file counts as part of its stdout. A `note` explains a known
  difference, such as a bug in the project that one compiler survives.
- A project with `copy` instead of `url` is a directory of this checkout,
  copied to `.work/src/`: `zig-compiler` is upstream 0.17.1's own tools in
  `upstream/lib/compiler` (translate-c and resinator on Aro, Aro's tests,
  objcopy, objdump, reduce, std-docs). It has no build.zig, so the
  manifest gives its `commands` and the root `files` its modules need
  (upstream builds these tools with the module root at lib/compiler,
  which `-M` cannot express).
- Setup clones each project into `.work/src/` (gitignored) and runs upstream
  `zig build <step> --verbose` once with a fresh cache under `.work/gen/`.
  That fetches dependencies, runs code generators (uucode's tables, lsp-kit's
  types), and prints every compile step's command line; the commands are
  kept in `.work/commands/`.
- Each target is then built from its recorded command line, by upstream
  zig and by bs, from the project's directory:
  - The build-system plumbing goes (`--listen=-`, the cache directories,
    the recording zig's `--zig-lib-dir`: each compiler uses its own lib
    directory, so the commands survive a move to another Zig release);
    each build gets an empty local cache and the user's global cache
    (`cold-local`) and emits to `.work/out/`. Tests add `--test-no-exec`.
    bs's cold build runs with `BS_CACHE_DONOR=off`: a first build that
    replays a donor from the global store takes a time that depends on
    what the store holds.
  - Every build is Debug: a release `-O` some build scripts force on their
    build-time tools becomes `-Odebug`, and upstream's `-fllvm` becomes
    `-fno-llvm`, so the baseline is upstream's Debug default on x86_64-linux
    (the self-hosted backend). On aarch64-macos (a Mac satellite: pass
    `--zig ~/.cache/bs/zig-aarch64-macos-0.17.1/zig`) the baseline is
    upstream's Debug default there, LLVM: the LLVM flags go, as upstream's
    self-hosted aarch64 backend does not finish even an empty `main`.
    Upstream's `translate-c -lc` does not finish on some headers there
    (sqlite3.h, tokamak's and zigcli's); a translation gives up after 10
    minutes.
  - bs gets the same command line as upstream: it takes every flag the
    corpus's build scripts pass.
  - A module that is a translated C header (`b.addTranslateC`, recorded
    from upstream's `translate-c` command) is translated again by each
    compiler, `zig translate-c` or `bs translate-c`, into the build's
    local cache, and that time counts in the cold build. bs compiles its
    translate-c tool (Aro) on its first `bs translate-c` into the global
    cache, once per bs binary (about 2 s), where upstream's is built in:
    the run builds it before timing anything and reports that time on its
    own, under the scoreboard.
- Both binaries run from the same path (programs print `argv[0]`). A test
  binary's verdict is its exit status, its summary line (`All N tests
  passed.`) and each test's outcome by name, in any order: bs's test
  runner sorts tests and upstream's takes its work queue's order, and
  what tests print follows that order. An executable's verdict is its
  exit status and stdout.
- The edit build appends `std.mem.doNotOptimizeAway(@as(u32, N));` to the
  target's `edit` line and rebuilds with the same cache: a full rebuild for
  upstream (`zig build-exe` caches nothing of the Zig compilation without
  `--listen`), an incremental one for bs.
- Results go to `.work/results.json` and `.work/scoreboard.md`.

## The lint parity set

`manifest.json`'s `lint` list is the parity set of bs's ziglint rules
(docs/slop/ziglint-in-bs.md): baskingspot's projects that have a
`.ziglint.zon` and build with zig 0.17.1, each at a pinned commit, with
the `zig build` steps to build (`build`, a list of step names). run.py and
steps.py do not build them;
`python3 tools/lint/parity.py --bs zig-out/bin/bs --ziglint ziglint --corpus`
checks each out as run.py does and compares bs's findings with ziglint
0.8.1's. Left out (2026-11-08): image, encoding, docgen, html and
zigdoc-poc, whose build.zig does not configure under 0.17.1 (`b.args`,
`b.graph.random_seed`), and hparse, release-probe and zigdoc-wip, which
have no `.ziglint.zon`. websocket's `install` step builds examples with
`@cImport`, which 0.17.1 removed, so its entry builds `test`.
testingx's and fastmem's `test` steps also run checks that fail outside
their own CI, under upstream zig too (testingx reads PMU counters;
fastmem's checks run llvm-readelf, llvm-nm and llvm-objdump), so their
entries build steps that compile the same tests without running them
(`check`; `test-unit-bin` and `test-bin`).

## Scope

bs compiles no C itself: C sources go to upstream's `zig cc`, the same
compiler in both builds. Linking glibc (`-lc`) and translating C headers
(`bs translate-c`) are in: libxev, zio, zedis and tokamak link libc, and
tokamak translates its `src/c.h`. zig-sqlite, raylib-zig, ziglua, zigmod,
buzz, supermd and zflecs compile C sources (raylib's C-only `raylib`
library and ziglua's `lua` are targets of their own, timed but not run;
buzz's vendored C comes from git submodules, `"submodules": true`).
Projects left out are listed under `excluded` in the manifest with the
reason.

The 15 projects after tokamak in the manifest (zig-sqlite through
zig-libs, all MIT) were added on 2026-11-04 to find what bs still cannot
build; their open bs bugs and upstream's own failures (buzz's tail calls,
zmath's vector rounding on upstream's self-hosted backend) are in each
target's `note`. The 12 after zig-libs (zwasm through
StaticHttpFileServer; zwasm is Apache-2.0, the rest MIT) were added on
2026-11-05 the same way: a WebAssembly runtime, a text editor (fizzy), web
frameworks (ziex, merjs), a GPU UI toolkit (nanoui), a scripting language
(revo) and smaller libraries. A step name a build uses twice (zwasm's and
revo's several `test`s) is recorded as `<name>:<root file>` for each of
its steps (`#2` and on after the first with that root, as superhtml's
per-target builds), and the bare name is the step with the first root
file in sort order, since the parallel build prints the steps in no
fixed order. The 15 after StaticHttpFileServer (flash through XirAsm) were
added on 2026-11-05 toward the kinds of code that had found bugs: crypto
and protocols (zquic, zig-blind-rsa-signatures, zig-cbc, nats.zig), SIMD
and image processing (zignal), a columnar format (zarrow), an assembler
(XirAsm), a text editor and a terminal (flow, teru), a glob walker
(zlob), an inference engine (zlaya), a GIR translator (zig-gobject) and
smaller libraries; they are MIT, Apache-2.0 or 0BSD. flow is recorded
with `-Dtarget=x86_64-linux-gnu`, and flow-musl builds its default
target, x86_64-linux-musl with musl's libc.
Setup installs into `.work/install/`, deleted after each step, so a
project's install output does not fill the disk.

The 17 after XirAsm (zprof through evm.zig) were added on 2026-11-05
toward code bs had seen least: comptime serializers (serde.zig, s2s,
comptime-serde), an ECS (knoedel), SIMD (csv-zero, oma), emulators full
of packed registers (ChipZ, sandopolis, zitrus), fibers and event loops
(marionette, wild, zeptun), an allocator profiler (zprof), an EVM
(evm.zig), comptime HTML templates (verse), a state-machine library
(polyrole) and a Markdown renderer (zigdown); they are MIT (evm.zig
MIT or Apache-2.0). ChipZ records only its test (its exe needs SDL2);
sandopolis records `test-unit` and `test-property` (its full `test`
needs ROMs).

The 17 after monstar (eth.zig through ssz.zig) were added on 2026-11-05
toward 128-bit arithmetic and crypto (eth.zig, ssz.zig, ulid.zig), inline
assembly (wamr, a WebAssembly runtime and AOT compiler; forklift, a JIT),
heavy comptime (zig-graph-compiler, which compiles a tensor graph at
comptime), C and C++ interop (zbullet's C++ Bullet, zstbi, zig-lmdb,
zstd.zig, element-0) and programs with real run time; they are MIT,
Apache-2.0 (element-0, zoto, wamr), ISC (maxminddb.zig) or the Unlicense
(ssz.zig). maxminddb.zig's test data comes from a git submodule. forklift
records `test_user`, and wamr `test-minimal-wasi` and
`test-execution-context`: forklift's full `test` does not compile under
upstream, and wamr's needs an aarch64 objdump. ulid.zig's `bench` prints
timings, so its stdout is not compared (`"compare_stdout": false`).

siv (MIT), the owner's GUI toolkit for Wayland, comes after ssz.zig as
a whole build: 45 targets of its `install` and `test`, its 34 test
binaries and its libraries and executables. It links Vulkan, compiles
harfbuzz, dav1d, libavif and Lua from source with upstream's `zig cc`,
and translates headers, among them its own siv.h next to Zig files it
generates with the same name (run.py tells them apart by content).

Each run is timed once (`run_secs`, the scoreboard's "run zig / bs"
column), so run-time ratios to upstream come from the same run as the
verdicts.

## Scoreboard

2026-11-04, bs at main e97f36a plus c17b8ae (the inline-call fix that
libxev's tests need; ReleaseFast), upstream zig 0.17.0 (its results from
the run on main 4f846d0), on a 4-core orb. All 83 targets of 33 projects
compile with bs. 81 behave as upstream's build does: same exit status,
same stdout, same test summary. Two differ, each with a `note` in the
manifest: tokamak's test panics under bs on illegal behavior in
tokamak's own `meta.transmute` (an `@alignCast` of an align(1) value's
address) that upstream's build survives only by its stack layout, and
upstream's build of zio's coro-demo overflows the 64 KiB coroutine stack
the demo allocates, where bs's fits. Some tests fail under both
compilers: ghostty-vt-test (tinyio's realPathFile), zbor (an ECDSA
vector), zig-hpke (an ML-KEM vector) and tokamak (http.client's
AddressInUse, with the alignment bug patched out). "not run" marks a
target that needs the network, a terminal, or a server's clients.

Times are one sample each: cold-local is an empty local cache with a warm
global cache (bs without donors); edit is the rebuild after a one-line
edit. Geometric-mean speedups: 1.9x cold-local over 83 targets (123.7 s
vs 65.9 s in total) and 28.6x on edit builds over 45 (91.6 s vs 2.4 s);
the libc projects' edit builds gain 21.3x over their 6 targets. ghostty's
props-unigen and symbols-unigen edit builds are lazy again (35 ms and
44 ms) now that atoms are named at link time, and their symbols match a
full build's. Single samples spike by 0.5–2 s on different targets from
run to run: the bs rows of the eleven projects that spiked in the first
run come from a second run, and zf, zlinter's
require_fmt_unit_test_coverage, zul and linuxwave's main-tests still
carry a spike, which is most of the drop from 2.0x. Timed directly
against main 1037019, zls, symbols-unigen and std compile in the same
time, and ghostty-vt-test 3–5% slower. tokamak's first cold build with
a new bs binary includes building bs's translate-c (3.3–5.8 s); the
table's 1.59 s is from a later run.

| Project | Target | Verdict | upstream run | bs run | cold-local zig / bs | edit zig / bs |
|---|---|---|---|---|---:|---:|
| zls | zls | ok | exit 0 | exit 0 | 2.80 s / 1.55 s (1.8x) | 2.97 s / 76 ms (38.9x) |
| zls | lsp-codegen | ok | exit 0 | exit 0 | 885 ms / 507 ms (1.7x) | 1.07 s / 46 ms (23.2x) |
| zls | test | ok | exit 0, 487 passed; 11 skipped; 0 failed. | exit 0, 487 passed; 11 skipped; 0 failed. | 2.66 s / 1.45 s (1.8x) | 2.63 s / 64 ms (41.4x) |
| zls | src test | ok | exit 0, All 94 tests passed. | exit 0, All 94 tests passed. | 1.19 s / 584 ms (2.0x) | 1.26 s / 29 ms (43.5x) |
| ghostty | ghostty-vt-test | ok | exit 1, 3004 passed; 102 skipped; 1 failed. | exit 1, 3004 passed; 102 skipped; 1 failed. | 27.76 s / 13.40 s (2.1x) | 25.99 s / 249 ms (104.3x) |
| ghostty | props-unigen | ok | exit 0 | exit 0 | 1.23 s / 422 ms (2.9x) | 843 ms / 35 ms (24.0x) |
| ghostty | symbols-unigen | ok | exit 0 | exit 0 | 873 ms / 897 ms (1.0x) | 793 ms / 44 ms (18.0x) |
| ghostty | uucode_generate | ok | exit 0 | exit 0 | 850 ms / 487 ms (1.7x) | 852 ms / 83 ms (10.3x) |
| superhtml | superhtml | ok | exit 1 | exit 1 | 2.98 s / 1.59 s (1.9x) | 3.25 s / 48 ms (67.4x) |
| superhtml | test | ok | exit 0, All 85 tests passed. | exit 0, All 85 tests passed. | 2.82 s / 1.30 s (2.2x) | 2.89 s / 64 ms (45.5x) |
| superhtml | language-tag-parser | ok | not run | not run | 584 ms / 270 ms (2.2x) | 573 ms / 34 ms (16.8x) |
| ziggy | ziggy | ok | exit 1 | exit 1 | 1.49 s / 751 ms (2.0x) | 1.50 s / 35 ms (43.3x) |
| ziggy | test | ok | exit 0, All 99 tests passed. | exit 0, All 99 tests passed. | 885 ms / 450 ms (2.0x) | 939 ms / 42 ms (22.4x) |
| z2d | test | ok | exit 0, All 199 tests passed. | exit 0, All 199 tests passed. | 2.12 s / 894 ms (2.4x) | 1.38 s / 32 ms (42.6x) |
| zf | zf | ok | exit 0 | exit 0 | 1.32 s / 1.42 s (0.9x) | 1.13 s / 55 ms (20.5x) |
| zf | test | ok | exit 0, All 10 tests passed. | exit 0, All 10 tests passed. | 549 ms / 283 ms (1.9x) | 551 ms / 27 ms (20.1x) |
| zig-clap | test | ok | exit 0, All 27 tests passed. | exit 0, All 27 tests passed. | 664 ms / 346 ms (1.9x) | 691 ms / 27 ms (26.0x) |
| zig-clap | simple | ok | exit 0 | exit 0 | 495 ms / 229 ms (2.2x) | 544 ms / 35 ms (15.8x) |
| zig-clap | subcommands | ok | exit 1 | exit 1 | 647 ms / 229 ms (2.8x) | 596 ms / 29 ms (20.5x) |
| zig-clap | usage | ok | exit 0 | exit 0 | 558 ms / 219 ms (2.6x) | 565 ms / 33 ms (17.2x) |
| anyzig | zig | ok | not run | not run | 3.09 s / 1.72 s (1.8x) | 3.36 s / 61 ms (54.7x) |
| anyzig | test | ok | not run | not run | 726 ms / 352 ms (2.1x) | – / – |
| zine | translate-c | ok | exit 0 | exit 0 | 2.97 s / 1.86 s (1.6x) | 3.00 s / 59 ms (51.2x) |
| zine | camera | ok | not run | not run | 512 ms / 233 ms (2.2x) | 485 ms / 27 ms (17.8x) |
| zig-protobuf | protoc-gen-zig | ok | not run | not run | 1.00 s / 476 ms (2.1x) | – / – |
| zig-protobuf | tests | ok | exit 0, All 5 tests passed. | exit 0, All 5 tests passed. | 816 ms / 375 ms (2.2x) | 818 ms / 32 ms (25.2x) |
| zig-protobuf | protobuf | ok | exit 0, All 26 tests passed. | exit 0, All 26 tests passed. | 692 ms / 329 ms (2.1x) | – / – |
| zig-protobuf | json | ok | exit 0, All 153 tests passed. | exit 0, All 153 tests passed. | 1.21 s / 626 ms (1.9x) | 1.22 s / 42 ms (29.0x) |
| zig-protobuf | alltypes | ok | exit 0, All 10 tests passed. | exit 0, All 10 tests passed. | 1.44 s / 693 ms (2.1x) | – / – |
| zig-protobuf | varints | ok | exit 0, All 36 tests passed. | exit 0, All 36 tests passed. | 731 ms / 339 ms (2.2x) | – / – |
| vulkan-zig | vulkan-zig-generator | ok | exit 0 | exit 0 | 877 ms / 387 ms (2.3x) | 897 ms / 37 ms (24.2x) |
| vulkan-zig | test | ok | exit 0, All 11 tests passed. | exit 0, All 11 tests passed. | 559 ms / 247 ms (2.3x) | – / – |
| tls.zig | test | ok | exit 0, 88 passed; 1 skipped; 0 failed. | exit 0, 88 passed; 1 skipped; 0 failed. | 2.55 s / 1.15 s (2.2x) | 2.59 s / 35 ms (73.7x) |
| tls.zig | http_get | ok | not run | not run | 1.77 s / 1.25 s (1.4x) | – / – |
| tls.zig | server | ok | not run | not run | 1.86 s / 899 ms (2.1x) | – / – |
| zlinter | no_unused_unit_test_coverage | ok | exit 0, All 6 tests passed. | exit 0, All 6 tests passed. | 830 ms / 485 ms (1.7x) | – / – |
| zlinter | require_fmt_unit_test_coverage | ok | exit 0, All 7 tests passed. | exit 0, All 7 tests passed. | 900 ms / 1.61 s (0.6x) | – / – |
| zlinter | build_lint_builtin | ok | not run | not run | 529 ms / 272 ms (1.9x) | – / – |
| zig-ecs | test | ok | exit 0, All 52 tests passed. | exit 0, All 52 tests passed. | 777 ms / 320 ms (2.4x) | 709 ms / 36 ms (19.9x) |
| zig-minisign | minizign | ok | exit 1 | exit 1 | 687 ms / 334 ms (2.1x) | – / – |
| zig-minisign | test | ok | exit 0, All 15 tests passed. | exit 0, All 15 tests passed. | 618 ms / 304 ms (2.0x) | – / – |
| zalgebra | test | ok | exit 0, All 70 tests passed. | exit 0, All 70 tests passed. | 639 ms / 386 ms (1.7x) | – / – |
| zig-args | test | ok | exit 0, All 15 tests passed. | exit 0, All 15 tests passed. | 772 ms / 307 ms (2.5x) | – / – |
| zig-args | demo | ok | exit 0 | exit 0 | 567 ms / 269 ms (2.1x) | – / – |
| zig-args | demo_verb | ok | exit 1 | exit 1 | 485 ms / 221 ms (2.2x) | – / – |
| zBench | runner | ok | exit 0, All 3 tests passed. | exit 0, All 3 tests passed. | 524 ms / 239 ms (2.2x) | – / – |
| zBench | statistics | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 497 ms / 265 ms (1.9x) | – / – |
| zBench | platform | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 495 ms / 228 ms (2.2x) | – / – |
| zBench | partial | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 540 ms / 227 ms (2.4x) | – / – |
| linuxwave | linuxwave | ok | exit 0 | exit 0 | 522 ms / 260 ms (2.0x) | – / – |
| linuxwave | wav-tests | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 525 ms / 231 ms (2.3x) | – / – |
| linuxwave | gen-tests | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 538 ms / 252 ms (2.1x) | – / – |
| linuxwave | file-tests | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 581 ms / 240 ms (2.4x) | – / – |
| linuxwave | main-tests | ok | exit 0, All 4 tests passed. | exit 0, All 4 tests passed. | 642 ms / 643 ms (1.0x) | – / – |
| zli | test | ok | exit 0, All 32 tests passed. | exit 0, All 32 tests passed. | 572 ms / 271 ms (2.1x) | – / – |
| zig-compiler | translate-c | ok | exit 0 | exit 0 | 2.79 s / 1.56 s (1.8x) | 2.92 s / 77 ms (37.9x) |
| zig-compiler | resinator | ok | exit 0 | exit 0 | 2.57 s / 1.43 s (1.8x) | 2.49 s / 60 ms (41.6x) |
| zig-compiler | resinator-test | ok | exit 0, 73 passed; 1 skipped; 0 failed. | exit 0, 73 passed; 1 skipped; 0 failed. | 1.43 s / 715 ms (2.0x) | – / – |
| zig-compiler | aro-test | ok | exit 0, All 42 tests passed. | exit 0, All 42 tests passed. | 2.28 s / 1.32 s (1.7x) | 2.48 s / 122 ms (20.3x) |
| zig-compiler | objcopy | ok | exit 0 | exit 0 | 588 ms / 261 ms (2.3x) | – / – |
| zig-compiler | objdump | ok | exit 0 | exit 0 | 713 ms / 346 ms (2.1x) | – / – |
| zig-compiler | reduce | ok | exit 0 | exit 0 | 1.15 s / 575 ms (2.0x) | – / – |
| zig-compiler | std-docs | ok | exit 0 | exit 0 | 1.02 s / 544 ms (1.9x) | – / – |
| zigimg | zigimgtest | ok | exit 0, 347 passed; 170 skipped; 0 failed. | exit 0, 347 passed; 170 skipped; 0 failed. | 1.62 s / 833 ms (1.9x) | 1.62 s / 56 ms (28.8x) |
| zeit | test | ok | exit 0, All 33 tests passed. | exit 0, All 33 tests passed. | 681 ms / 388 ms (1.8x) | 706 ms / 31 ms (22.7x) |
| zbor | test | ok | exit 1, 97 passed; 0 skipped; 1 failed. | exit 1, 97 passed; 0 skipped; 1 failed. | 1.13 s / 542 ms (2.1x) | 1.28 s / 33 ms (39.4x) |
| libvaxis | test | ok | exit 0, 203 passed; 3 skipped; 0 failed. | exit 0, 203 passed; 3 skipped; 0 failed. | 2.38 s / 772 ms (3.1x) | 1.65 s / 44 ms (37.8x) |
| libvaxis | example-text_input | ok | not run | not run | 1.25 s / 500 ms (2.5x) | – / – |
| cache.zig | test | ok | exit 0, 20 of 20 tests passed | exit 0, 20 of 20 tests passed | 621 ms / 322 ms (1.9x) | 632 ms / 40 ms (15.7x) |
| zul | test | ok | exit 0, 86 of 86 tests passed | exit 0, 86 of 86 tests passed | 2.29 s / 1.80 s (1.3x) | 2.38 s / 47 ms (50.7x) |
| metrics.zig | test | ok | exit 0, 41 of 41 tests passed | exit 0, 41 of 41 tests passed | 754 ms / 409 ms (1.8x) | 793 ms / 33 ms (23.9x) |
| zig-hpke | test | ok | exit 1, 30 passed; 0 skipped; 1 failed. | exit 1, 30 passed; 0 skipped; 1 failed. | 1.54 s / 839 ms (1.8x) | 1.61 s / 31 ms (52.3x) |
| libxev | xev-test | ok | exit 0, 142 passed; 4 skipped; 0 failed. | exit 0, 142 passed; 4 skipped; 0 failed. | 863 ms / 436 ms (2.0x) | 721 ms / 45 ms (16.1x) |
| libxev | xev | ok | not run | not run | 395 ms / 191 ms (2.1x) | – / – |
| zio | test | ok | exit 0, 817 of 817 tests passed | exit 0, 817 of 817 tests passed | 2.08 s / 1.26 s (1.7x) | 2.11 s / 149 ms (14.1x) |
| zio | hello-world | ok | exit 0 | exit 0 | 803 ms / 428 ms (1.9x) | 767 ms / 67 ms (11.5x) |
| zio | coro-demo | bs: run differs (exit 0 vs exit signal 6) | exit signal 6 | exit 0 | 585 ms / 266 ms (2.2x) | – / – |
| zio | mutex-demo | ok | exit 0 | exit 0 | 869 ms / 488 ms (1.8x) | – / – |
| zio | ev-demo | ok | exit 0 | exit 0 | 722 ms / 394 ms (1.8x) | – / – |
| zio | producer-consumer | ok | exit 0 | exit 0 | 908 ms / 645 ms (1.4x) | – / – |
| zedis | test-unit | ok | exit 0, All 384 tests passed. | exit 0, All 384 tests passed. | 1.23 s / 719 ms (1.7x) | 1.27 s / 52 ms (24.5x) |
| zedis | zedis | ok | not run | not run | 1.21 s / 772 ms (1.6x) | 1.20 s / 54 ms (22.5x) |
| tokamak | test | bs: run differs (exit signal 6, no summary vs exit 1, 88 passed; 0 skipped; 1 failed.) | exit 1, 88 passed; 0 skipped; 1 failed. | exit signal 6, no summary | 2.88 s / 1.59 s (1.8x) | 2.87 s / 44 ms (65.3x) |
