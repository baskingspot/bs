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
  - zap drops flags it does not take that do not change a pure-Zig
    x86_64-linux Debug build (`--build-root`, `--zig-lib-dir`,
    `-fno-sanitize-c`, ...). Flags that change `builtin` but that zap does
    not implement yet (`-fsingle-threaded`, `-fPIC`) are dropped and
    recorded in the result's `notes`.
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

2026-11-03, branch `corpus` on main 804a68a, both compilers on a 4-core
orb. Every one of the 55 targets compiles with zap, and what it builds
behaves the same as upstream's build: same exit status, same stdout, and
the same test summary. ghostty-vt-test fails one test (tinyio's
realPathFile) under both compilers. "not run" means a target that needs
the network or a terminal. Times are one sample each: cold-local is an empty
local cache with a warm global cache; edit is the rebuild after a one-line
edit. Geometric-mean speedups: 2.0x cold-local over 55 targets (81.3 s vs 38.7 s
in total) and 6.5x on edit over 28 (61.2 s vs 7.4 s). Single samples sometimes
spike by 0.5–1.3 s: zls's 1.67 s edit build takes 0.36–0.42 s when rerun.

| Project | Target | Verdict | upstream run | zap run | cold-local zig / zap | edit zig / zap |
|---|---|---|---|---|---:|---:|
| zls | zls | ok | exit 0 | exit 0 | 2.71 s / 1.31 s (2.1x) | 2.68 s / 1.67 s (1.6x) |
| zls | lsp-codegen | ok | exit 0 | exit 0 | 826 ms / 396 ms (2.1x) | 839 ms / 124 ms (6.8x) |
| zls | test | ok | exit 0, 487 passed; 11 skipped; 0 failed. | exit 0, 487 passed; 11 skipped; 0 failed. | 2.38 s / 1.30 s (1.8x) | 2.61 s / 342 ms (7.6x) |
| zls | src test | ok | exit 0, All 94 tests passed. | exit 0, All 94 tests passed. | 1.20 s / 557 ms (2.2x) | 1.19 s / 163 ms (7.3x) |
| ghostty | ghostty-vt-test | ok | exit 1, 3004 passed; 102 skipped; 1 failed. | exit 1, 3004 passed; 102 skipped; 1 failed. | 26.96 s / 10.87 s (2.5x) | 25.09 s / 907 ms (27.6x) |
| ghostty | props-unigen | ok | exit 0 | exit 0 | 848 ms / 385 ms (2.2x) | 809 ms / 95 ms (8.5x) |
| ghostty | symbols-unigen | ok | exit 0 | exit 0 | 928 ms / 385 ms (2.4x) | 745 ms / 104 ms (7.2x) |
| ghostty | uucode_generate | ok | exit 0 | exit 0 | 899 ms / 449 ms (2.0x) | 843 ms / 155 ms (5.4x) |
| superhtml | superhtml | ok | exit 1 | exit 1 | 2.89 s / 1.38 s (2.1x) | 3.01 s / 397 ms (7.6x) |
| superhtml | test | ok | exit 0, All 85 tests passed. | exit 0, All 85 tests passed. | 2.68 s / 1.28 s (2.1x) | 2.85 s / 387 ms (7.4x) |
| superhtml | language-tag-parser | ok | not run | not run | 585 ms / 251 ms (2.3x) | 519 ms / 95 ms (5.5x) |
| ziggy | ziggy | ok | exit 1 | exit 1 | 1.37 s / 687 ms (2.0x) | 1.35 s / 276 ms (4.9x) |
| ziggy | test | ok | exit 0, All 99 tests passed. | exit 0, All 99 tests passed. | 877 ms / 451 ms (1.9x) | 927 ms / 165 ms (5.6x) |
| z2d | test | ok | exit 0, All 199 tests passed. | exit 0, All 199 tests passed. | 1.40 s / 679 ms (2.1x) | 1.55 s / 182 ms (8.5x) |
| zf | zf | ok | exit 0 | exit 0 | 1.26 s / 529 ms (2.4x) | 1.16 s / 142 ms (8.2x) |
| zf | test | ok | exit 0, All 10 tests passed. | exit 0, All 10 tests passed. | 517 ms / 243 ms (2.1x) | 527 ms / 101 ms (5.2x) |
| zig-clap | test | ok | exit 0, All 27 tests passed. | exit 0, All 27 tests passed. | 612 ms / 370 ms (1.7x) | 611 ms / 110 ms (5.6x) |
| zig-clap | simple | ok | exit 0 | exit 0 | 496 ms / 216 ms (2.3x) | 541 ms / 94 ms (5.8x) |
| zig-clap | subcommands | ok | exit 1 | exit 1 | 492 ms / 219 ms (2.2x) | 501 ms / 87 ms (5.8x) |
| zig-clap | usage | ok | exit 0 | exit 0 | 483 ms / 213 ms (2.3x) | 477 ms / 92 ms (5.2x) |
| anyzig | zig | ok | not run | not run | 2.94 s / 1.57 s (1.9x) | 3.12 s / 398 ms (7.8x) |
| anyzig | test | ok | not run | not run | 670 ms / 353 ms (1.9x) | – / – |
| zine | translate-c | ok | exit 0 | exit 0 | 2.80 s / 1.50 s (1.9x) | 2.91 s / 491 ms (5.9x) |
| zine | camera | ok | not run | not run | 440 ms / 255 ms (1.7x) | 446 ms / 113 ms (4.0x) |
| zig-protobuf | protoc-gen-zig | ok | not run | not run | 1.01 s / 494 ms (2.0x) | – / – |
| zig-protobuf | tests | ok | exit 0, All 5 tests passed. | exit 0, All 5 tests passed. | 746 ms / 371 ms (2.0x) | 717 ms / 141 ms (5.1x) |
| zig-protobuf | protobuf | ok | exit 0, All 26 tests passed. | exit 0, All 26 tests passed. | 646 ms / 522 ms (1.2x) | – / – |
| zig-protobuf | json | ok | exit 0, All 153 tests passed. | exit 0, All 153 tests passed. | 1.42 s / 829 ms (1.7x) | 1.23 s / 162 ms (7.6x) |
| zig-protobuf | alltypes | ok | exit 0, All 10 tests passed. | exit 0, All 10 tests passed. | 1.33 s / 598 ms (2.2x) | – / – |
| zig-protobuf | varints | ok | exit 0, All 36 tests passed. | exit 0, All 36 tests passed. | 639 ms / 308 ms (2.1x) | – / – |
| vulkan-zig | vulkan-zig-generator | ok | exit 0 | exit 0 | 769 ms / 419 ms (1.8x) | 804 ms / 124 ms (6.5x) |
| vulkan-zig | test | ok | exit 0, All 11 tests passed. | exit 0, All 11 tests passed. | 544 ms / 248 ms (2.2x) | – / – |
| tls.zig | test | ok | exit 0, 88 passed; 1 skipped; 0 failed. | exit 0, 88 passed; 1 skipped; 0 failed. | 2.44 s / 1.21 s (2.0x) | 2.45 s / 154 ms (15.9x) |
| tls.zig | http_get | ok | not run | not run | 1.68 s / 1.03 s (1.6x) | – / – |
| tls.zig | server | ok | not run | not run | 1.71 s / 933 ms (1.8x) | – / – |
| zlinter | no_unused_unit_test_coverage | ok | exit 0, All 6 tests passed. | exit 0, All 6 tests passed. | 745 ms / 418 ms (1.8x) | – / – |
| zlinter | require_fmt_unit_test_coverage | ok | exit 0, All 7 tests passed. | exit 0, All 7 tests passed. | 798 ms / 394 ms (2.0x) | – / – |
| zlinter | build_lint_builtin | ok | not run | not run | 511 ms / 212 ms (2.4x) | – / – |
| zig-ecs | test | ok | exit 0, All 52 tests passed. | exit 0, All 52 tests passed. | 635 ms / 335 ms (1.9x) | 704 ms / 129 ms (5.5x) |
| zig-minisign | minizign | ok | exit 1 | exit 1 | 631 ms / 347 ms (1.8x) | – / – |
| zig-minisign | test | ok | exit 0, All 15 tests passed. | exit 0, All 15 tests passed. | 599 ms / 381 ms (1.6x) | – / – |
| zalgebra | test | ok | exit 0, All 70 tests passed. | exit 0, All 70 tests passed. | 558 ms / 471 ms (1.2x) | – / – |
| zig-args | test | ok | exit 0, All 15 tests passed. | exit 0, All 15 tests passed. | 589 ms / 307 ms (1.9x) | – / – |
| zig-args | demo | ok | exit 0 | exit 0 | 506 ms / 262 ms (1.9x) | – / – |
| zig-args | demo_verb | ok | exit 1 | exit 1 | 483 ms / 210 ms (2.3x) | – / – |
| zBench | runner | ok | exit 0, All 3 tests passed. | exit 0, All 3 tests passed. | 479 ms / 218 ms (2.2x) | – / – |
| zBench | statistics | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 483 ms / 212 ms (2.3x) | – / – |
| zBench | platform | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 546 ms / 210 ms (2.6x) | – / – |
| zBench | partial | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 472 ms / 233 ms (2.0x) | – / – |
| linuxwave | linuxwave | ok | exit 0 | exit 0 | 518 ms / 247 ms (2.1x) | – / – |
| linuxwave | wav-tests | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 507 ms / 423 ms (1.2x) | – / – |
| linuxwave | gen-tests | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 483 ms / 240 ms (2.0x) | – / – |
| linuxwave | file-tests | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 484 ms / 220 ms (2.2x) | – / – |
| linuxwave | main-tests | ok | exit 0, All 4 tests passed. | exit 0, All 4 tests passed. | 540 ms / 315 ms (1.7x) | – / – |
| zli | test | ok | exit 0, All 32 tests passed. | exit 0, All 32 tests passed. | 542 ms / 265 ms (2.0x) | – / – |
