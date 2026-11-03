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
  `output` file counts as part of its stdout.
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
  - Every build is Debug: a release `-O` some build scripts force on their
    build-time tools becomes `-Odebug`, and upstream's `-fllvm` becomes
    `-fno-llvm`, so the baseline is upstream's Debug default on x86_64-linux
    (the self-hosted backend).
  - zap gets the same command line as upstream: it takes every flag the
    corpus's build scripts pass.
- Both binaries run from the same path (programs print `argv[0]`). A test
  binary's verdict is its exit status and summary line (`All N tests
  passed.`); an executable's is its exit status and stdout.
- The edit build appends `std.mem.doNotOptimizeAway(@as(u32, N));` to the
  target's `edit` line and rebuilds with the same cache: a full rebuild for
  upstream (`zig build-exe` caches nothing of the Zig compilation without
  `--listen`), an incremental one for zap.
- Results go to `.work/results.json` and `.work/scoreboard.md`.

## Scope

zap compiles neither C nor `@cImport`, so only targets that build without C
are in the corpus: no C sources, no C libraries, no libc. Projects whose
every artifact links libc or a C library are listed under `excluded` in the
manifest with the reason.

## Scoreboard

2026-11-03, zap at branch `corpus2` on main b90d615 (main plus batch 2's
fixes; std compiles in the same time as main's), upstream zig 0.17.0, on a
4-core orb. All 72 targets of 29 projects compile with zap, and what they
build behaves as upstream's build does: same exit status, same stdout,
same test summary. Some tests fail under both compilers: ghostty-vt-test
(tinyio's realPathFile), zbor (an ECDSA vector) and zig-hpke (an ML-KEM
vector). "not run" marks a target that needs the network or a terminal.
Times are one sample each: cold-local is an empty local cache with a warm
global cache; edit is the rebuild after a one-line edit. Geometric-mean
speedups: 2.0x cold-local over 72 targets (103.2 s vs 51.0 s in total)
and 32.6x on edit builds over 39 (80.0 s vs 1.7 s). Single samples
sometimes spike by 0.5–1.3 s: linuxwave's 1.57 s takes 0.23–0.25 s when
rerun.

| Project | Target | Verdict | upstream run | zap run | cold-local zig / zap | edit zig / zap |
|---|---|---|---|---|---:|---:|
| zls | zls | ok | exit 0 | exit 0 | 2.93 s / 1.39 s (2.1x) | 2.84 s / 68 ms (41.5x) |
| zls | lsp-codegen | ok | exit 0 | exit 0 | 889 ms / 422 ms (2.1x) | 1.05 s / 37 ms (28.6x) |
| zls | test | ok | exit 0, 487 passed; 11 skipped; 0 failed. | exit 0, 487 passed; 11 skipped; 0 failed. | 2.63 s / 1.39 s (1.9x) | 2.75 s / 60 ms (45.7x) |
| zls | src test | ok | exit 0, All 94 tests passed. | exit 0, All 94 tests passed. | 1.29 s / 612 ms (2.1x) | 1.20 s / 24 ms (50.8x) |
| ghostty | ghostty-vt-test | ok | exit 1, 3004 passed; 102 skipped; 1 failed. | exit 1, 3004 passed; 102 skipped; 1 failed. | 25.49 s / 10.93 s (2.3x) | 25.95 s / 238 ms (109.2x) |
| ghostty | props-unigen | ok | exit 0 | exit 0 | 947 ms / 600 ms (1.6x) | 823 ms / 30 ms (27.6x) |
| ghostty | symbols-unigen | ok | exit 0 | exit 0 | 808 ms / 403 ms (2.0x) | 879 ms / 49 ms (17.8x) |
| ghostty | uucode_generate | ok | exit 0 | exit 0 | 826 ms / 478 ms (1.7x) | 835 ms / 69 ms (12.1x) |
| superhtml | superhtml | ok | exit 1 | exit 1 | 2.91 s / 1.41 s (2.1x) | 2.97 s / 37 ms (80.2x) |
| superhtml | test | ok | exit 0, All 85 tests passed. | exit 0, All 85 tests passed. | 2.67 s / 1.18 s (2.3x) | 2.85 s / 56 ms (50.6x) |
| superhtml | language-tag-parser | ok | not run | not run | 562 ms / 229 ms (2.5x) | 541 ms / 29 ms (18.9x) |
| ziggy | ziggy | ok | exit 1 | exit 1 | 1.26 s / 629 ms (2.0x) | 1.28 s / 30 ms (42.8x) |
| ziggy | test | ok | exit 0, All 99 tests passed. | exit 0, All 99 tests passed. | 828 ms / 379 ms (2.2x) | 881 ms / 74 ms (12.0x) |
| z2d | test | ok | exit 0, All 199 tests passed. | exit 0, All 199 tests passed. | 1.31 s / 948 ms (1.4x) | 1.36 s / 29 ms (47.4x) |
| zf | zf | ok | exit 0 | exit 0 | 1.27 s / 482 ms (2.6x) | 1.16 s / 29 ms (39.9x) |
| zf | test | ok | exit 0, All 10 tests passed. | exit 0, All 10 tests passed. | 519 ms / 235 ms (2.2x) | 493 ms / 29 ms (16.8x) |
| zig-clap | test | ok | exit 0, All 27 tests passed. | exit 0, All 27 tests passed. | 587 ms / 275 ms (2.1x) | 663 ms / 20 ms (32.3x) |
| zig-clap | simple | ok | exit 0 | exit 0 | 466 ms / 206 ms (2.3x) | 461 ms / 27 ms (16.9x) |
| zig-clap | subcommands | ok | exit 1 | exit 1 | 464 ms / 209 ms (2.2x) | 459 ms / 32 ms (14.2x) |
| zig-clap | usage | ok | exit 0 | exit 0 | 477 ms / 187 ms (2.5x) | 470 ms / 26 ms (17.8x) |
| anyzig | zig | ok | not run | not run | 3.21 s / 1.50 s (2.1x) | 3.26 s / 49 ms (66.9x) |
| anyzig | test | ok | not run | not run | 715 ms / 338 ms (2.1x) | – / – |
| zine | translate-c | ok | exit 0 | exit 0 | 2.74 s / 1.64 s (1.7x) | 2.92 s / 55 ms (53.4x) |
| zine | camera | ok | not run | not run | 522 ms / 212 ms (2.5x) | 481 ms / 22 ms (21.6x) |
| zig-protobuf | protoc-gen-zig | ok | not run | not run | 999 ms / 454 ms (2.2x) | – / – |
| zig-protobuf | tests | ok | exit 0, All 5 tests passed. | exit 0, All 5 tests passed. | 769 ms / 355 ms (2.2x) | 770 ms / 34 ms (22.5x) |
| zig-protobuf | protobuf | ok | exit 0, All 26 tests passed. | exit 0, All 26 tests passed. | 752 ms / 352 ms (2.1x) | – / – |
| zig-protobuf | json | ok | exit 0, All 153 tests passed. | exit 0, All 153 tests passed. | 1.20 s / 593 ms (2.0x) | 1.18 s / 26 ms (45.9x) |
| zig-protobuf | alltypes | ok | exit 0, All 10 tests passed. | exit 0, All 10 tests passed. | 1.33 s / 656 ms (2.0x) | – / – |
| zig-protobuf | varints | ok | exit 0, All 36 tests passed. | exit 0, All 36 tests passed. | 610 ms / 262 ms (2.3x) | – / – |
| vulkan-zig | vulkan-zig-generator | ok | exit 0 | exit 0 | 771 ms / 358 ms (2.2x) | 760 ms / 32 ms (23.4x) |
| vulkan-zig | test | ok | exit 0, All 11 tests passed. | exit 0, All 11 tests passed. | 553 ms / 506 ms (1.1x) | – / – |
| tls.zig | test | ok | exit 0, 88 passed; 1 skipped; 0 failed. | exit 0, 88 passed; 1 skipped; 0 failed. | 2.34 s / 1.14 s (2.1x) | 2.48 s / 34 ms (72.1x) |
| tls.zig | http_get | ok | not run | not run | 1.62 s / 822 ms (2.0x) | – / – |
| tls.zig | server | ok | not run | not run | 1.59 s / 815 ms (1.9x) | – / – |
| zlinter | no_unused_unit_test_coverage | ok | exit 0, All 6 tests passed. | exit 0, All 6 tests passed. | 756 ms / 356 ms (2.1x) | – / – |
| zlinter | require_fmt_unit_test_coverage | ok | exit 0, All 7 tests passed. | exit 0, All 7 tests passed. | 773 ms / 347 ms (2.2x) | – / – |
| zlinter | build_lint_builtin | ok | not run | not run | 449 ms / 186 ms (2.4x) | – / – |
| zig-ecs | test | ok | exit 0, All 52 tests passed. | exit 0, All 52 tests passed. | 604 ms / 268 ms (2.3x) | 629 ms / 31 ms (20.3x) |
| zig-minisign | minizign | ok | exit 1 | exit 1 | 608 ms / 271 ms (2.2x) | – / – |
| zig-minisign | test | ok | exit 0, All 15 tests passed. | exit 0, All 15 tests passed. | 595 ms / 535 ms (1.1x) | – / – |
| zalgebra | test | ok | exit 0, All 70 tests passed. | exit 0, All 70 tests passed. | 550 ms / 260 ms (2.1x) | – / – |
| zig-args | test | ok | exit 0, All 15 tests passed. | exit 0, All 15 tests passed. | 592 ms / 265 ms (2.2x) | – / – |
| zig-args | demo | ok | exit 0 | exit 0 | 483 ms / 204 ms (2.4x) | – / – |
| zig-args | demo_verb | ok | exit 1 | exit 1 | 500 ms / 205 ms (2.4x) | – / – |
| zBench | runner | ok | exit 0, All 3 tests passed. | exit 0, All 3 tests passed. | 490 ms / 264 ms (1.9x) | – / – |
| zBench | statistics | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 515 ms / 256 ms (2.0x) | – / – |
| zBench | platform | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 477 ms / 218 ms (2.2x) | – / – |
| zBench | partial | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 487 ms / 202 ms (2.4x) | – / – |
| linuxwave | linuxwave | ok | exit 0 | exit 0 | 578 ms / 1.57 s (0.4x) | – / – |
| linuxwave | wav-tests | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 494 ms / 231 ms (2.1x) | – / – |
| linuxwave | gen-tests | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 528 ms / 266 ms (2.0x) | – / – |
| linuxwave | file-tests | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 528 ms / 211 ms (2.5x) | – / – |
| linuxwave | main-tests | ok | exit 0, All 4 tests passed. | exit 0, All 4 tests passed. | 563 ms / 248 ms (2.3x) | – / – |
| zli | test | ok | exit 0, All 32 tests passed. | exit 0, All 32 tests passed. | 605 ms / 271 ms (2.2x) | – / – |
| zig-compiler | translate-c | ok | exit 0 | exit 0 | 2.71 s / 1.35 s (2.0x) | 2.67 s / 64 ms (41.9x) |
| zig-compiler | resinator | ok | exit 0 | exit 0 | 2.43 s / 1.18 s (2.1x) | 2.59 s / 48 ms (54.1x) |
| zig-compiler | resinator-test | ok | exit 0, 73 passed; 1 skipped; 0 failed. | exit 0, 73 passed; 1 skipped; 0 failed. | 1.28 s / 815 ms (1.6x) | – / – |
| zig-compiler | aro-test | ok | exit 0, All 42 tests passed. | exit 0, All 42 tests passed. | 2.16 s / 1.35 s (1.6x) | 2.22 s / 90 ms (24.6x) |
| zig-compiler | objcopy | ok | exit 0 | exit 0 | 527 ms / 239 ms (2.2x) | – / – |
| zig-compiler | objdump | ok | exit 0 | exit 0 | 695 ms / 333 ms (2.1x) | – / – |
| zig-compiler | reduce | ok | exit 0 | exit 0 | 1.07 s / 515 ms (2.1x) | – / – |
| zig-compiler | std-docs | ok | exit 0 | exit 0 | 1.01 s / 464 ms (2.2x) | – / – |
| zigimg | zigimgtest | ok | exit 0, 347 passed; 170 skipped; 0 failed. | exit 0, 347 passed; 170 skipped; 0 failed. | 1.53 s / 677 ms (2.3x) | 1.47 s / 39 ms (37.3x) |
| zeit | test | ok | exit 0, All 33 tests passed. | exit 0, All 33 tests passed. | 667 ms / 302 ms (2.2x) | 740 ms / 28 ms (26.1x) |
| zbor | test | ok | exit 1, 97 passed; 0 skipped; 1 failed. | exit 1, 97 passed; 0 skipped; 1 failed. | 1.10 s / 528 ms (2.1x) | 1.12 s / 28 ms (40.7x) |
| libvaxis | test | ok | exit 0, 203 passed; 3 skipped; 0 failed. | exit 0, 203 passed; 3 skipped; 0 failed. | 1.78 s / 1.04 s (1.7x) | 1.58 s / 39 ms (40.7x) |
| libvaxis | example-text_input | ok | not run | not run | 1.22 s / 671 ms (1.8x) | – / – |
| cache.zig | test | ok | exit 0, 20 of 20 tests passed | exit 0, 20 of 20 tests passed | 579 ms / 262 ms (2.2x) | 582 ms / 37 ms (15.9x) |
| zul | test | ok | exit 0, 86 of 86 tests passed | exit 0, 86 of 86 tests passed | 2.25 s / 1.02 s (2.2x) | 2.29 s / 33 ms (69.4x) |
| metrics.zig | test | ok | exit 0, 41 of 41 tests passed | exit 0, 41 of 41 tests passed | 721 ms / 353 ms (2.0x) | 725 ms / 38 ms (19.2x) |
| zig-hpke | test | ok | exit 1, 30 passed; 0 skipped; 1 failed. | exit 1, 30 passed; 0 skipped; 1 failed. | 1.48 s / 685 ms (2.2x) | 1.58 s / 25 ms (62.4x) |
