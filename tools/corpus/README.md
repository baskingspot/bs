# Real-world corpus

`tools/corpus/run.py` builds pinned, pure-Zig projects with zap and with
upstream zig 0.17.0, runs what they build, and compares the two. It finds
the bugs real programs hit that `test/behavior` and std's tests miss.

```sh
zig build -Doptimize=ReleaseFast
python3 tools/corpus/run.py                      # every project and target
python3 tools/corpus/run.py --projects zls,z2d --targets test
python3 tools/corpus/run.py --zap-only --no-edit # quick check after a fix
```

Options: `--zap PATH`, `--zig PATH`, `--refresh` (record the compile
commands again), `--list` (record and list them only), `--zap-only` (keep
the last upstream results), `--no-edit` (skip the edit builds), `--no-run`
(build only), `--cache-check` (zap's edit builds check themselves against
a full build with `ZAP_CACHE_VERIFY` and `ZAP_CACHE_CHECK`; not timed).

## How it works

- [`manifest.json`](manifest.json) lists each project: repository, pinned
  commit (a commit whose `build.zig.zon` declares `minimum_zig_version`
  0.17.0 or which CI builds with 0.17.0), the `zig build` steps that build
  its targets (`build`), and the targets: compile steps named by their
  `--name`, how to run each (`run`: arguments for an executable; tests run
  without arguments), and an `edit` line for the edit build. Run arguments
  and `cwd` may name `{src}` (the checkout), `{zig_lib}` (upstream's lib
  directory), `{gen}` (the generation cache, where code generators write)
  or a `fetch`ed package, and a glob there names its first match. A run's
  `output` file counts as part of its stdout. A `note` explains a known
  difference, such as a bug in the project that one compiler survives.
- A project with `copy` instead of `url` is a directory of this checkout,
  copied to `.work/src/`: `zig-compiler` is upstream 0.17.0's own tools in
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
  zig and by zap, from the project's directory:
  - The build-system plumbing goes (`--listen=-`, the cache directories);
    each build gets an empty local cache and the user's global cache
    (`cold-local`) and emits to `.work/out/`. Tests add `--test-no-exec`.
    zap's cold build runs with `ZAP_CACHE_DONOR=off`: a first build that
    replays a donor from the global store takes a time that depends on
    what the store holds.
  - Every build is Debug: a release `-O` some build scripts force on their
    build-time tools becomes `-Odebug`, and upstream's `-fllvm` becomes
    `-fno-llvm`, so the baseline is upstream's Debug default on x86_64-linux
    (the self-hosted backend).
  - zap gets the same command line as upstream: it takes every flag the
    corpus's build scripts pass.
  - A module that is a translated C header (`b.addTranslateC`, recorded
    from upstream's `translate-c` command) is translated again by each
    compiler, `zig translate-c` or `zap translate-c`, into the build's
    local cache, and that time counts in the cold build.
- Both binaries run from the same path (programs print `argv[0]`). A test
  binary's verdict is its exit status and summary line (`All N tests
  passed.`); an executable's is its exit status and stdout.
- The edit build appends `std.mem.doNotOptimizeAway(@as(u32, N));` to the
  target's `edit` line and rebuilds with the same cache: a full rebuild for
  upstream (`zig build-exe` caches nothing of the Zig compilation without
  `--listen`), an incremental one for zap.
- Results go to `.work/results.json` and `.work/scoreboard.md`.

## Scope

zap compiles no C, so only targets that build without C sources are in the
corpus. Linking glibc (`-lc`) and translating C headers (`zap translate-c`)
are in: libxev, zio, zedis and tokamak link libc, and tokamak translates
its `src/c.h`. Projects that need C sources or other C libraries are
listed under `excluded` in the manifest with the reason.

## Scoreboard

2026-11-04, zap at main e97f36a plus c17b8ae (the inline-call fix that
libxev's tests need; ReleaseFast), upstream zig 0.17.0 (its results from
the run on main 4f846d0), on a 4-core orb. All 83 targets of 33 projects
compile with zap. 81 behave as upstream's build does: same exit status,
same stdout, same test summary. Two differ, each with a `note` in the
manifest: tokamak's test panics under zap on illegal behavior in
tokamak's own `meta.transmute` (an `@alignCast` of an align(1) value's
address) that upstream's build survives only by its stack layout, and
upstream's build of zio's coro-demo overflows the 64 KiB coroutine stack
the demo allocates, where zap's fits. Some tests fail under both
compilers: ghostty-vt-test (tinyio's realPathFile), zbor (an ECDSA
vector), zig-hpke (an ML-KEM vector) and tokamak (http.client's
AddressInUse, with the alignment bug patched out). "not run" marks a
target that needs the network, a terminal, or a server's clients.

Times are one sample each: cold-local is an empty local cache with a warm
global cache (zap without donors); edit is the rebuild after a one-line
edit. Geometric-mean speedups: 1.9x cold-local over 83 targets (123.7 s
vs 65.9 s in total) and 28.6x on edit builds over 45 (91.6 s vs 2.4 s);
the libc projects' edit builds gain 21.3x over their 6 targets. ghostty's
props-unigen and symbols-unigen edit builds are lazy again (35 ms and
44 ms) now that atoms are named at link time, and their symbols match a
full build's. Single samples spike by 0.5–2 s on different targets from
run to run: the zap rows of the eleven projects that spiked in the first
run come from a second run, and zf, zlinter's
require_fmt_unit_test_coverage, zul and linuxwave's main-tests still
carry a spike, which is most of the drop from 2.0x. Timed directly
against main 1037019, zls, symbols-unigen and std compile in the same
time, and ghostty-vt-test 3–5% slower. tokamak's first cold build with
a new zap binary includes building zap's translate-c (3.3–5.8 s); the
table's 1.59 s is from a later run.

| Project | Target | Verdict | upstream run | zap run | cold-local zig / zap | edit zig / zap |
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
| zio | coro-demo | zap: run differs (exit 0 vs exit signal 6) | exit signal 6 | exit 0 | 585 ms / 266 ms (2.2x) | – / – |
| zio | mutex-demo | ok | exit 0 | exit 0 | 869 ms / 488 ms (1.8x) | – / – |
| zio | ev-demo | ok | exit 0 | exit 0 | 722 ms / 394 ms (1.8x) | – / – |
| zio | producer-consumer | ok | exit 0 | exit 0 | 908 ms / 645 ms (1.4x) | – / – |
| zedis | test-unit | ok | exit 0, All 384 tests passed. | exit 0, All 384 tests passed. | 1.23 s / 719 ms (1.7x) | 1.27 s / 52 ms (24.5x) |
| zedis | zedis | ok | not run | not run | 1.21 s / 772 ms (1.6x) | 1.20 s / 54 ms (22.5x) |
| tokamak | test | zap: run differs (exit signal 6, no summary vs exit 1, 88 passed; 0 skipped; 1 failed.) | exit 1, 88 passed; 0 skipped; 1 failed. | exit signal 6, no summary | 2.88 s / 1.59 s (1.8x) | 2.87 s / 44 ms (65.3x) |
