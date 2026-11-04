# Scoreboard 2026-11-04: zap 13942f5 against upstream zig 0.17.0

Machine: Intel(R) Xeon(R) Processor @ 2.60GHz, 4 logical CPUs, 7.8 GiB, Linux 6.1.158+ (Amp orb, 4 vCPU). zap 13942f5 built with `-Doptimize=ReleaseFast`; upstream zig 0.17.0 Debug (self-hosted x86_64 backend and linker) unless a column says ReleaseSafe (LLVM). Made by `python3 bench/scoreboard.py --zap <zap>` in one session (2026-11-04 14:32 to 2026-11-04 15:27 UTC).

## Compile time vs upstream zig 0.17.0 Debug

`bench/bench.py`, `build-exe` mode (std: `zig test`), each workload measured upstream, zap, then zap without donors, back to back. Median wall time; runs per scenario: hello and vaxis 10 (cold 5), zig and std 5 (cold 3); peak RSS where it matters. cold-local is the first build of a project with zap's global store warm: with donors, zap replays the earlier build of the same compilation from the store (zap's real first-build path in a fresh checkout); `ZAP_CACHE_DONOR=off` analyzes everything. Edits append a statement to one line of a function body, new each build. CPU calibration loop 123 ms–132 ms over the session.

| Workload (`zig build-exe`) | Scenario | Upstream zig | zap | zig / zap |
| --- | --- | --- | --- | ---: |
| hello world | cold (empty caches) | 5.09 s | 432 ms | 11.8x |
| hello world | cold-local (global cache warm) | 449 ms | **95 ms** with donors (203 ms without, 2.2x) | 4.7x |
| hello world | no edit | 465 ms | 1.4 ms | 339.8x |
| hello world | edit root file | 451 ms | 25 ms | 18.3x |
| hello world | edit std (`std/debug.zig`) | 4.27 s | 49 ms | 87.4x |
| libvaxis text_input example | cold (empty caches) | 5.88 s | 683 ms | 8.6x |
| libvaxis text_input example | cold-local (global cache warm) | 1.24 s | **254 ms** with donors (511 ms without, 2.4x) | 4.9x |
| libvaxis text_input example | no edit | 1.13 s | 1.4 ms | 786.3x |
| libvaxis text_input example | edit root file | 1.11 s | 36 ms | 30.6x |
| libvaxis text_input example | edit library (`src/Vaxis.zig`) | 1.10 s | 45 ms | 24.3x |
| upstream's zig 0.17.0 compiler (no LLVM) | cold (empty caches) | 28.48 s, 1364 MiB | 12.51 s, 1425 MiB | 2.3x |
| upstream's zig 0.17.0 compiler (no LLVM) | cold-local (global cache warm) | 24.40 s, 1272 MiB | **5.05 s, 1410 MiB** with donors (12.38 s without, 2.0x) | 4.8x |
| upstream's zig 0.17.0 compiler (no LLVM) | no edit | 24.19 s | 2.5 ms | 9556.1x |
| upstream's zig 0.17.0 compiler (no LLVM) | edit root (`src/main.zig`) | 24.17 s | 361 ms | 66.9x |
| upstream's zig 0.17.0 compiler (no LLVM) | edit `src/Sema.zig` | 24.03 s | 618 ms | 38.9x |
| `zig test lib/std/std.zig` (std's tests, --test-no-exec) | cold (empty caches) | 21.92 s, 974 MiB | 9.18 s, 808 MiB | 2.4x |
| `zig test lib/std/std.zig` (std's tests, --test-no-exec) | cold-local (global cache warm) | 16.65 s, 880 MiB | **1.35 s, 615 MiB** with donors (8.52 s without, 2.0x) | 12.4x |
| `zig test lib/std/std.zig` (std's tests, --test-no-exec) | no edit | 16.72 s | 1.7 ms | 10008.1x |
| `zig test lib/std/std.zig` (std's tests, --test-no-exec) | edit a test (`std/mem.zig`) | 20.79 s | 207 ms | 100.5x |
| `zig test lib/std/std.zig` (std's tests, --test-no-exec) | edit `std/debug.zig` | 21.14 s | 1.77 s | 12.0x |

## Corpus: every target, zap vs upstream Debug

`tools/corpus/run.py --no-run --donors`: each target's recorded compile command, upstream then zap, median of 3 samples. cold-local is an empty local cache with a warm global cache; zap's is timed without donors, then again with donors (which then find the build just made in the global store); edit is the rebuild after the manifest's one-line edit. Geometric means of the per-target ratio zig / zap:

| Scenario | zig / zap |
| --- | ---: |
| cold-local, without donors | 2.0x over 83 targets (120.4 s vs 60.7 s in total) |
| cold-local, with donors | 4.6x over 83 targets (120.4 s vs 21.7 s in total) |
| edit build | 24.9x over 45 targets (89.1 s vs 2.7 s in total) |

| Project | Target | cold-local zig / zap | with donors | edit zig / zap |
| --- | --- | ---: | ---: | ---: |
| zls | zls | 2.79 s / 1.61 s (1.7x) | 731 ms (3.8x) | 2.86 s / 82 ms (35.0x) |
| zls | lsp-codegen | 926 ms / 473 ms (2.0x) | 255 ms (3.6x) | 914 ms / 67 ms (13.6x) |
| zls | test | 2.84 s / 1.57 s (1.8x) | 666 ms (4.3x) | 2.65 s / 101 ms (26.3x) |
| zls | src test | 1.27 s / 614 ms (2.1x) | 288 ms (4.4x) | 1.16 s / 29 ms (40.2x) |
| ghostty | ghostty-vt-test | 26.13 s / 12.18 s (2.1x) | 1.22 s (21.4x) | 26.05 s / 274 ms (95.1x) |
| ghostty | props-unigen | 911 ms / 496 ms (1.8x) | 314 ms (2.9x) | 773 ms / 35 ms (22.4x) |
| ghostty | symbols-unigen | 873 ms / 431 ms (2.0x) | 256 ms (3.4x) | 836 ms / 35 ms (23.8x) |
| ghostty | uucode_generate | 849 ms / 446 ms (1.9x) | 169 ms (5.0x) | 846 ms / 88 ms (9.6x) |
| superhtml | superhtml | 3.13 s / 1.45 s (2.2x) | 540 ms (5.8x) | 3.10 s / 61 ms (51.1x) |
| superhtml | test | 2.72 s / 1.24 s (2.2x) | 400 ms (6.8x) | 2.89 s / 75 ms (38.5x) |
| superhtml | language-tag-parser | 518 ms / 256 ms (2.0x) | 122 ms (4.2x) | 503 ms / 37 ms (13.5x) |
| ziggy | ziggy | 1.36 s / 732 ms (1.9x) | 294 ms (4.6x) | 1.36 s / 42 ms (32.4x) |
| ziggy | test | 871 ms / 470 ms (1.9x) | 224 ms (3.9x) | 875 ms / 51 ms (17.2x) |
| z2d | test | 1.47 s / 773 ms (1.9x) | 249 ms (5.9x) | 1.42 s / 33 ms (42.5x) |
| zf | zf | 1.29 s / 561 ms (2.3x) | 325 ms (4.0x) | 1.14 s / 39 ms (29.1x) |
| zf | test | 514 ms / 312 ms (1.6x) | 114 ms (4.5x) | 543 ms / 26 ms (20.7x) |
| zig-clap | test | 650 ms / 328 ms (2.0x) | 132 ms (4.9x) | 704 ms / 27 ms (25.7x) |
| zig-clap | simple | 496 ms / 251 ms (2.0x) | 113 ms (4.4x) | 505 ms / 38 ms (13.4x) |
| zig-clap | subcommands | 523 ms / 252 ms (2.1x) | 124 ms (4.2x) | 500 ms / 30 ms (16.8x) |
| zig-clap | usage | 465 ms / 242 ms (1.9x) | 103 ms (4.5x) | 480 ms / 33 ms (14.6x) |
| anyzig | zig | 3.11 s / 1.74 s (1.8x) | 431 ms (7.2x) | 3.16 s / 63 ms (50.3x) |
| anyzig | test | 708 ms / 349 ms (2.0x) | 187 ms (3.8x) | – / – |
| zine | translate-c | 3.00 s / 1.68 s (1.8x) | 873 ms (3.4x) | 2.94 s / 82 ms (35.8x) |
| zine | camera | 494 ms / 235 ms (2.1x) | 110 ms (4.5x) | 505 ms / 30 ms (16.9x) |
| zig-protobuf | protoc-gen-zig | 1.09 s / 629 ms (1.7x) | 227 ms (4.8x) | – / – |
| zig-protobuf | tests | 761 ms / 399 ms (1.9x) | 176 ms (4.3x) | 759 ms / 37 ms (20.5x) |
| zig-protobuf | protobuf | 703 ms / 354 ms (2.0x) | 221 ms (3.2x) | – / – |
| zig-protobuf | json | 1.19 s / 586 ms (2.0x) | 297 ms (4.0x) | 1.16 s / 29 ms (40.0x) |
| zig-protobuf | alltypes | 1.35 s / 626 ms (2.2x) | 258 ms (5.2x) | – / – |
| zig-protobuf | varints | 678 ms / 330 ms (2.1x) | 187 ms (3.6x) | – / – |
| vulkan-zig | vulkan-zig-generator | 829 ms / 458 ms (1.8x) | 195 ms (4.2x) | 841 ms / 48 ms (17.7x) |
| vulkan-zig | test | 548 ms / 311 ms (1.8x) | 129 ms (4.2x) | – / – |
| tls.zig | test | 2.53 s / 1.29 s (2.0x) | 185 ms (13.7x) | 2.46 s / 51 ms (48.6x) |
| tls.zig | http_get | 1.75 s / 1.03 s (1.7x) | 199 ms (8.8x) | – / – |
| tls.zig | server | 1.66 s / 878 ms (1.9x) | 148 ms (11.2x) | – / – |
| zlinter | no_unused_unit_test_coverage | 816 ms / 425 ms (1.9x) | 193 ms (4.2x) | – / – |
| zlinter | require_fmt_unit_test_coverage | 875 ms / 436 ms (2.0x) | 221 ms (4.0x) | – / – |
| zlinter | build_lint_builtin | 473 ms / 242 ms (2.0x) | 114 ms (4.1x) | – / – |
| zig-ecs | test | 636 ms / 349 ms (1.8x) | 208 ms (3.1x) | 652 ms / 47 ms (13.9x) |
| zig-minisign | minizign | 675 ms / 353 ms (1.9x) | 148 ms (4.6x) | – / – |
| zig-minisign | test | 713 ms / 304 ms (2.3x) | 148 ms (4.8x) | – / – |
| zalgebra | test | 619 ms / 297 ms (2.1x) | 136 ms (4.6x) | – / – |
| zig-args | test | 653 ms / 326 ms (2.0x) | 127 ms (5.1x) | – / – |
| zig-args | demo | 508 ms / 252 ms (2.0x) | 113 ms (4.5x) | – / – |
| zig-args | demo_verb | 534 ms / 260 ms (2.1x) | 113 ms (4.7x) | – / – |
| zBench | runner | 521 ms / 247 ms (2.1x) | 111 ms (4.7x) | – / – |
| zBench | statistics | 570 ms / 246 ms (2.3x) | 107 ms (5.3x) | – / – |
| zBench | platform | 497 ms / 251 ms (2.0x) | 109 ms (4.6x) | – / – |
| zBench | partial | 553 ms / 242 ms (2.3x) | 106 ms (5.2x) | – / – |
| linuxwave | linuxwave | 567 ms / 312 ms (1.8x) | 122 ms (4.6x) | – / – |
| linuxwave | wav-tests | 515 ms / 252 ms (2.0x) | 139 ms (3.7x) | – / – |
| linuxwave | gen-tests | 563 ms / 257 ms (2.2x) | 134 ms (4.2x) | – / – |
| linuxwave | file-tests | 526 ms / 242 ms (2.2x) | 112 ms (4.7x) | – / – |
| linuxwave | main-tests | 663 ms / 303 ms (2.2x) | 143 ms (4.6x) | – / – |
| zli | test | 593 ms / 300 ms (2.0x) | 131 ms (4.5x) | – / – |
| zig-compiler | translate-c | 2.91 s / 1.56 s (1.9x) | 734 ms (4.0x) | 2.86 s / 86 ms (33.1x) |
| zig-compiler | resinator | 2.47 s / 1.36 s (1.8x) | 549 ms (4.5x) | 2.39 s / 69 ms (34.4x) |
| zig-compiler | resinator-test | 1.47 s / 722 ms (2.0x) | 552 ms (2.7x) | – / – |
| zig-compiler | aro-test | 2.31 s / 1.26 s (1.8x) | 649 ms (3.6x) | 2.15 s / 152 ms (14.1x) |
| zig-compiler | objcopy | 526 ms / 252 ms (2.1x) | 109 ms (4.8x) | – / – |
| zig-compiler | objdump | 737 ms / 337 ms (2.2x) | 128 ms (5.7x) | – / – |
| zig-compiler | reduce | 1.19 s / 605 ms (2.0x) | 323 ms (3.7x) | – / – |
| zig-compiler | std-docs | 1.07 s / 488 ms (2.2x) | 203 ms (5.3x) | – / – |
| zigimg | zigimgtest | 1.58 s / 798 ms (2.0x) | 266 ms (6.0x) | 1.44 s / 51 ms (28.4x) |
| zeit | test | 747 ms / 376 ms (2.0x) | 166 ms (4.5x) | 698 ms / 44 ms (15.8x) |
| zbor | test | 1.21 s / 530 ms (2.3x) | 168 ms (7.2x) | 1.21 s / 34 ms (35.5x) |
| libvaxis | test | 1.74 s / 801 ms (2.2x) | 353 ms (4.9x) | 1.60 s / 74 ms (21.6x) |
| libvaxis | example-text_input | 1.30 s / 510 ms (2.5x) | 304 ms (4.3x) | – / – |
| cache.zig | test | 624 ms / 336 ms (1.9x) | 175 ms (3.6x) | 677 ms / 56 ms (12.1x) |
| zul | test | 2.32 s / 1.34 s (1.7x) | 280 ms (8.3x) | 2.43 s / 58 ms (42.1x) |
| metrics.zig | test | 829 ms / 442 ms (1.9x) | 327 ms (2.5x) | 802 ms / 39 ms (20.7x) |
| zig-hpke | test | 1.58 s / 798 ms (2.0x) | 136 ms (11.6x) | 1.56 s / 32 ms (49.0x) |
| libxev | xev-test | 787 ms / 382 ms (2.1x) | 204 ms (3.9x) | 751 ms / 52 ms (14.5x) |
| libxev | xev | 441 ms / 209 ms (2.1x) | 211 ms (2.1x) | – / – |
| zio | test | 2.14 s / 1.21 s (1.8x) | 539 ms (4.0x) | 2.07 s / 136 ms (15.3x) |
| zio | hello-world | 814 ms / 436 ms (1.9x) | 217 ms (3.8x) | 745 ms / 54 ms (13.9x) |
| zio | coro-demo | 521 ms / 250 ms (2.1x) | 140 ms (3.7x) | – / – |
| zio | mutex-demo | 884 ms / 471 ms (1.9x) | 253 ms (3.5x) | – / – |
| zio | ev-demo | 709 ms / 355 ms (2.0x) | 215 ms (3.3x) | – / – |
| zio | producer-consumer | 915 ms / 505 ms (1.8x) | 264 ms (3.5x) | – / – |
| zedis | test-unit | 1.35 s / 653 ms (2.1x) | 313 ms (4.3x) | 1.18 s / 49 ms (24.1x) |
| zedis | zedis | 1.13 s / 642 ms (1.8x) | 298 ms (3.8x) | 1.10 s / 47 ms (23.6x) |
| tokamak | test | 3.02 s / 1.55 s (1.9x) | 455 ms (6.6x) | 2.88 s / 49 ms (58.7x) |

## Run time vs upstream Debug and ReleaseSafe

`bench/runtime.py`, median of 5 runs; the three binaries print the same output.

| Program | zap | upstream Debug | upstream ReleaseSafe | zap / Debug | zap / ReleaseSafe |
| --- | ---: | ---: | ---: | ---: | ---: |
| fib | 117 ms | 177 ms | 73 ms | 0.66x | 1.6x |
| sieve | 128 ms | 483 ms | 107 ms | 0.27x | 1.2x |
| sort | 273 ms | 573 ms | 90 ms | 0.48x | 3.0x |
| hash | 304 ms | 690 ms | 48 ms | 0.44x | 6.3x |
| nbody | 198 ms | 442 ms | 21 ms | 0.45x | 9.3x |
| fmt | 109 ms | 206 ms | 22 ms | 0.53x | 4.9x |

`bench/realworld.py`, median of 5 runs:

| Workload | zap | upstream Debug | upstream ReleaseSafe | zap / Debug | zap / ReleaseSafe |
| --- | ---: | ---: | ---: | ---: | ---: |
| zig-fmt | 2.63 s | 4.44 s | – | 0.59x | – |
| zig-sema | 7.13 s | 11.50 s | – | 0.62x | – |
| vaxis | 845 ms | 1.16 s | 253 ms | 0.73x | 3.3x |
| zls-test | 1.16 s | 1.68 s | 291 ms | 0.69x | 4.0x |

## Donor-on rows again on zap 15abfd4

Lazy donor builds (156d6f2) and every file's ZIR in the global cache (15abfd4) landed after the run above. Same orb and session as above (2026-11-04 15:48 to 2026-11-04 15:59 UTC); `bench/scoreboard.py --add-donors`. cold-local, median of 10 (zig and std: 5), upstream measured again next to zap:

| Workload | Upstream zig | zap 13942f5 | zap 15abfd4 | zig / zap |
| --- | ---: | ---: | ---: | ---: |
| hello world | 447 ms | 95 ms | **19 ms** | 23.5x |
| libvaxis text_input example | 1.30 s | 254 ms | **33 ms** | 39.5x |
| upstream's zig 0.17.0 compiler (no LLVM) | 24.90 s | 5.05 s | **210 ms** | 118.6x |
| `zig test lib/std/std.zig` (std's tests, --test-no-exec) | 18.78 s | 1.35 s | **98 ms** | 192.5x |

Corpus, zap 15abfd4 against the upstream columns above (geometric means of zig / zap):

| Scenario | zig / zap |
| --- | ---: |
| cold-local, without donors | 2.0x over 83 targets (120.2 s vs 61.5 s in total) |
| cold-local, with donors | 28.2x over 83 targets (120.2 s vs 3.9 s in total) |
| edit build | 24.5x over 45 targets (89.0 s vs 2.7 s in total) |

Targets where zap was slower than upstream in some column: none.

## Findings

- **No workload or corpus target is slower with zap than with upstream** in steady state. In the full run, tokamak's test target came out slower at cold-local (2.86 s against 3.56 s). That was a one-time cost: a new zap binary builds its translate-c tool the first time a header is translated (about 2 s), and tokamak is the first corpus target that translates one. Rerun alone, the target is 3.02 s against 1.55 s (1.9x), and that rerun replaces the first run's row above (the first run's row is kept in the JSON as `corpus_first_run_tokamak`). `bench/scoreboard.py` now builds the translate-c tool before the corpus starts.
- **The std-tests edit to `std/debug.zig` (1.77 s) falls back from a lazy edit build to an eager one.** The same edit on hello takes 49 ms. Cause: `Replay.refreshInlines` returns null for compiler_rt's kept `fmod_f64`. One of its inlined callees is in debug.zig, so its inline line info needs a refresh, and its other inlined callee `generic_fmod` isn't found: it is a generic inline instance, and compiler_rt's files are not loaded in a lazy build, so `isChangedPath` reports them as changed. Minimal repro: a hello that prints `@rem(a, b)` on runtime f64s. With the debug.zig edit it builds in 0.15 s against hello's 0.04 s, and the fallback still happens on 15abfd4. Sent to the cache thread. The std edit-root (a test in std/mem.zig) stays lazy at 207 ms.
- **The zig workload's Sema.zig edit (618 ms) stays lazy.** It re-analyzes 99 functions and spends 110 ms in AstGen of Sema.zig and 110 ms linking 135k atoms from the manifest. It was 0.34 s in the cache thread's earlier session. This orb ran 1.2–1.3x slower than the Nov 2 session: upstream hello cold-local was 449 ms against 350 ms then.
- **Donor-on cold-local on 13942f5 is the eager donor replay.** The zig workload took 5.05 s: Sema 2.2 s, mostly replaying 140k units; 672 functions analyzed again, with `CodeGen.genBody` alone 330 ms; the recording after the link 1.1 s. Lazy donor builds (156d6f2) remove that, so see the next section.
- **Lazy donors (15abfd4) bring cold-local down to 19–210 ms** on the bench workloads. Over the corpus, cold-local with donors goes from 4.5x to 28.2x upstream. These are best-case numbers: the harness builds each donor-on target right after the same compilation's own build, so the exact donor is in the store. Donors are keyed by zap, target, std and options, so every non-`-lc` corpus target shares one key, and `max_donors_per_key = 4` keeps only the 4 newest. After the corpus run, ghostty-vt-test's exact donor had been evicted. Its first build then picked a donor sharing 560 of 702 inputs, replayed it eagerly ("the donor has files this build lacks"), and took 13.6 s, the same as without donors (13.3 s). With its own donor it takes 0.27 s. Someone switching between more than four projects gets the eager path. Sent to the cache thread as an observation.
- **Targets with a slower donor-on build on 15abfd4:**
  - ghostty props-unigen 251 ms, zio ev-demo 203 ms and tokamak 247 ms: eager donors from a neighbouring target, as above.
  - libxev xev 235 ms: a `-lc` `build-lib`, which doesn't use the cache (nothing printed under ZAP_CACHE_TIMING; Sema 186 ms).
  - zedis test-unit measured 328 ms in the run, but 30–35 ms in each of three runs afterwards (a lazy donor replaying 4 units). I haven't explained that.

### Rerunning

    zig build -Doptimize=ReleaseFast -p /tmp/zap-rf
    python3 bench/scoreboard.py --zap /tmp/zap-rf/bin/zap --note "Amp orb, 4 vCPU"

That command runs everything above except the last section, in about 1 h; `--parts` picks a subset. The donor-on rerun after a donor change:

    python3 bench/scoreboard.py --from-json bench/results/<date>-scoreboard.json --zap <new zap> --zap-commit <sha> --add-donors "<what changed>"
