# Scoreboard 2026-11-04: zap d47bcde against upstream zig 0.17.1

Machine: Intel(R) Xeon(R) Processor @ 2.60GHz, 4 logical CPUs, 7.8 GiB, Linux 6.1.158+ (Amp orb, 4 vCPU). zap d47bcde built with `-Doptimize=ReleaseFast`; upstream zig 0.17.1 Debug (self-hosted x86_64 backend and linker) unless a column says ReleaseSafe (LLVM). Made by `python3 bench/scoreboard.py --zap <zap>` in one session (2026-11-04 19:44 to 2026-11-04 20:39 UTC).

## Compile time vs upstream zig 0.17.1 Debug

`bench/bench.py`, `build-exe` mode (std: `zig test`), each workload measured upstream, zap, then zap without donors, back to back. Median wall time; runs per scenario: hello and vaxis 10 (cold 5), zig and std 5 (cold 3); peak RSS where it matters. cold-local is the first build of a project with zap's global store warm: with donors, zap replays the earlier build of the same compilation from the store (zap's real first-build path in a fresh checkout); `ZAP_CACHE_DONOR=off` analyzes everything. Edits append a statement to one line of a function body, new each build. CPU calibration loop 125 ms–143 ms over the session.

| Workload (`zig build-exe`) | Scenario | Upstream zig | zap | zig / zap |
| --- | --- | --- | --- | ---: |
| hello world | cold (empty caches) | 5.10 s | 456 ms | 11.2x |
| hello world | cold-local (global cache warm) | 441 ms | **21 ms** with donors (207 ms without, 2.1x) | 21.2x |
| hello world | no edit | 441 ms | 1.4 ms | 316.4x |
| hello world | edit root file | 441 ms | 26 ms | 17.0x |
| hello world | edit std (`std/debug.zig`) | 4.36 s | 57 ms | 77.0x |
| libvaxis text_input example | cold (empty caches) | 5.84 s | 694 ms | 8.4x |
| libvaxis text_input example | cold-local (global cache warm) | 1.28 s | **34 ms** with donors (405 ms without, 3.2x) | 37.7x |
| libvaxis text_input example | no edit | 1.15 s | 1.5 ms | 753.3x |
| libvaxis text_input example | edit root file | 1.11 s | 38 ms | 29.1x |
| libvaxis text_input example | edit library (`src/Vaxis.zig`) | 1.15 s | 50 ms | 22.9x |
| upstream's zig 0.17.1 compiler (no LLVM) | cold (empty caches) | 29.49 s, 1362 MiB | 13.24 s, 1291 MiB | 2.2x |
| upstream's zig 0.17.1 compiler (no LLVM) | cold-local (global cache warm) | 26.80 s, 1273 MiB | **242 ms, 332 MiB** with donors (12.27 s without, 2.2x) | 110.8x |
| upstream's zig 0.17.1 compiler (no LLVM) | no edit | 25.14 s | 2.8 ms | 8966.2x |
| upstream's zig 0.17.1 compiler (no LLVM) | edit root (`src/main.zig`) | 25.56 s | 396 ms | 64.6x |
| upstream's zig 0.17.1 compiler (no LLVM) | edit `src/Sema.zig` | 25.51 s | 642 ms | 39.7x |
| `zig test lib/std/std.zig` (std's tests, --test-no-exec) | cold (empty caches) | 22.04 s, 975 MiB | 9.07 s, 753 MiB | 2.4x |
| `zig test lib/std/std.zig` (std's tests, --test-no-exec) | cold-local (global cache warm) | 16.85 s, 880 MiB | **107 ms, 169 MiB** with donors (8.51 s without, 2.0x) | 157.3x |
| `zig test lib/std/std.zig` (std's tests, --test-no-exec) | no edit | 16.89 s | 1.8 ms | 9165.5x |
| `zig test lib/std/std.zig` (std's tests, --test-no-exec) | edit a test (`std/mem.zig`) | 21.64 s | 217 ms | 99.7x |
| `zig test lib/std/std.zig` (std's tests, --test-no-exec) | edit `std/debug.zig` | 21.05 s | 379 ms | 55.5x |

## Corpus: every target, zap vs upstream Debug

`tools/corpus/run.py --no-run --donors`: each target's recorded compile command, upstream then zap, median of 3 samples. cold-local is an empty local cache with a warm global cache; zap's is timed without donors, then again with donors (which then find the build just made in the global store); edit is the rebuild after the manifest's one-line edit. Geometric means of the per-target ratio zig / zap:

| Scenario | zig / zap |
| --- | ---: |
| cold-local, without donors | 2.0x over 82 targets (95.4 s vs 49.0 s in total) |
| cold-local, with donors | 28.6x over 82 targets (95.4 s vs 3.5 s in total) |
| edit build | 23.5x over 44 targets (63.6 s vs 2.5 s in total) |

Not compared (a compiler failed): ghostty ghostty-vt-test.

| Project | Target | cold-local zig / zap | with donors | edit zig / zap |
| --- | --- | ---: | ---: | ---: |
| zls | zls | 2.91 s / 1.61 s (1.8x) | 52 ms (55.6x) | 2.97 s / 95 ms (31.3x) |
| zls | lsp-codegen | 951 ms / 478 ms (2.0x) | 32 ms (29.6x) | 973 ms / 52 ms (18.8x) |
| zls | test | 2.77 s / 1.53 s (1.8x) | 59 ms (46.8x) | 2.74 s / 80 ms (34.0x) |
| zls | src test | 1.29 s / 622 ms (2.1x) | 33 ms (39.2x) | 1.30 s / 33 ms (39.4x) |
| ghostty | props-unigen | 885 ms / 344 ms (2.6x) | 31 ms (28.5x) | 775 ms / 36 ms (21.6x) |
| ghostty | symbols-unigen | 895 ms / 344 ms (2.6x) | 32 ms (27.7x) | 794 ms / 42 ms (19.0x) |
| ghostty | uucode_generate | 903 ms / 435 ms (2.1x) | 25 ms (36.5x) | 856 ms / 94 ms (9.1x) |
| superhtml | superhtml | 3.02 s / 1.42 s (2.1x) | 38 ms (78.5x) | 3.00 s / 61 ms (49.5x) |
| superhtml | test | 2.84 s / 1.25 s (2.3x) | 39 ms (72.8x) | 2.76 s / 81 ms (34.0x) |
| superhtml | language-tag-parser | 524 ms / 291 ms (1.8x) | 23 ms (22.7x) | 527 ms / 38 ms (13.7x) |
| ziggy | ziggy | 1.33 s / 713 ms (1.9x) | 34 ms (39.2x) | 1.39 s / 46 ms (30.1x) |
| ziggy | test | 872 ms / 492 ms (1.8x) | 30 ms (28.8x) | 868 ms / 50 ms (17.5x) |
| z2d | test | 1.46 s / 734 ms (2.0x) | 32 ms (44.8x) | 1.37 s / 38 ms (35.9x) |
| zf | zf | 1.38 s / 414 ms (3.3x) | 37 ms (37.7x) | 1.12 s / 42 ms (26.4x) |
| zf | test | 524 ms / 257 ms (2.0x) | 23 ms (23.2x) | 542 ms / 28 ms (19.5x) |
| zig-clap | test | 645 ms / 379 ms (1.7x) | 22 ms (28.8x) | 634 ms / 25 ms (24.9x) |
| zig-clap | simple | 481 ms / 242 ms (2.0x) | 29 ms (16.8x) | 469 ms / 41 ms (11.6x) |
| zig-clap | subcommands | 472 ms / 234 ms (2.0x) | 23 ms (20.2x) | 496 ms / 32 ms (15.5x) |
| zig-clap | usage | 466 ms / 223 ms (2.1x) | 21 ms (22.3x) | 464 ms / 32 ms (14.4x) |
| anyzig | zig | 3.10 s / 1.65 s (1.9x) | 35 ms (87.7x) | 3.12 s / 65 ms (48.0x) |
| anyzig | test | 720 ms / 350 ms (2.1x) | 47 ms (15.5x) | – / – |
| zine | translate-c | 2.91 s / 1.63 s (1.8x) | 53 ms (54.8x) | 2.88 s / 81 ms (35.7x) |
| zine | camera | 479 ms / 253 ms (1.9x) | 22 ms (21.7x) | 483 ms / 33 ms (14.6x) |
| zig-protobuf | protoc-gen-zig | 1.07 s / 494 ms (2.2x) | 25 ms (42.8x) | – / – |
| zig-protobuf | tests | 757 ms / 369 ms (2.1x) | 27 ms (28.4x) | 840 ms / 40 ms (20.9x) |
| zig-protobuf | protobuf | 686 ms / 379 ms (1.8x) | 24 ms (28.2x) | – / – |
| zig-protobuf | json | 1.18 s / 725 ms (1.6x) | 31 ms (38.1x) | 1.21 s / 32 ms (37.6x) |
| zig-protobuf | alltypes | 1.55 s / 651 ms (2.4x) | 35 ms (43.9x) | – / – |
| zig-protobuf | varints | 718 ms / 405 ms (1.8x) | 25 ms (29.1x) | – / – |
| vulkan-zig | vulkan-zig-generator | 806 ms / 455 ms (1.8x) | 25 ms (31.9x) | 812 ms / 48 ms (16.8x) |
| vulkan-zig | test | 581 ms / 270 ms (2.1x) | 26 ms (22.1x) | – / – |
| tls.zig | test | 2.53 s / 1.58 s (1.6x) | 29 ms (86.7x) | 2.64 s / 41 ms (63.6x) |
| tls.zig | http_get | 2.00 s / 971 ms (2.1x) | 28 ms (70.1x) | – / – |
| tls.zig | server | 1.78 s / 1.07 s (1.7x) | 43 ms (40.9x) | – / – |
| zlinter | no_unused_unit_test_coverage | 855 ms / 486 ms (1.8x) | 30 ms (28.8x) | – / – |
| zlinter | require_fmt_unit_test_coverage | 923 ms / 512 ms (1.8x) | 28 ms (32.7x) | – / – |
| zlinter | build_lint_builtin | 487 ms / 283 ms (1.7x) | 24 ms (20.0x) | – / – |
| zig-ecs | test | 678 ms / 406 ms (1.7x) | 25 ms (27.0x) | 697 ms / 50 ms (14.0x) |
| zig-minisign | minizign | 693 ms / 357 ms (1.9x) | 25 ms (27.3x) | – / – |
| zig-minisign | test | 671 ms / 301 ms (2.2x) | 27 ms (25.0x) | – / – |
| zalgebra | test | 599 ms / 359 ms (1.7x) | 24 ms (24.5x) | – / – |
| zig-args | test | 714 ms / 371 ms (1.9x) | 29 ms (24.3x) | – / – |
| zig-args | demo | 536 ms / 294 ms (1.8x) | 28 ms (19.5x) | – / – |
| zig-args | demo_verb | 510 ms / 270 ms (1.9x) | 24 ms (20.9x) | – / – |
| zBench | runner | 530 ms / 264 ms (2.0x) | 23 ms (23.5x) | – / – |
| zBench | statistics | 564 ms / 263 ms (2.1x) | 24 ms (23.4x) | – / – |
| zBench | platform | 522 ms / 257 ms (2.0x) | 26 ms (20.2x) | – / – |
| zBench | partial | 538 ms / 256 ms (2.1x) | 23 ms (23.5x) | – / – |
| linuxwave | linuxwave | 575 ms / 280 ms (2.1x) | 32 ms (17.7x) | – / – |
| linuxwave | wav-tests | 566 ms / 327 ms (1.7x) | 28 ms (20.1x) | – / – |
| linuxwave | gen-tests | 542 ms / 274 ms (2.0x) | 40 ms (13.5x) | – / – |
| linuxwave | file-tests | 546 ms / 270 ms (2.0x) | 27 ms (20.1x) | – / – |
| linuxwave | main-tests | 655 ms / 309 ms (2.1x) | 30 ms (22.0x) | – / – |
| zli | test | 649 ms / 344 ms (1.9x) | 26 ms (24.9x) | – / – |
| zig-compiler | translate-c | 3.03 s / 1.65 s (1.8x) | 53 ms (57.4x) | 2.94 s / 92 ms (31.9x) |
| zig-compiler | resinator | 2.57 s / 1.40 s (1.8x) | 47 ms (54.7x) | 2.45 s / 81 ms (30.3x) |
| zig-compiler | resinator-test | 1.50 s / 670 ms (2.2x) | 40 ms (37.3x) | – / – |
| zig-compiler | aro-test | 2.36 s / 1.28 s (1.8x) | 45 ms (52.6x) | 2.33 s / 161 ms (14.5x) |
| zig-compiler | objcopy | 584 ms / 338 ms (1.7x) | 32 ms (18.4x) | – / – |
| zig-compiler | objdump | 766 ms / 399 ms (1.9x) | 23 ms (33.9x) | – / – |
| zig-compiler | reduce | 1.22 s / 634 ms (1.9x) | 31 ms (39.2x) | – / – |
| zig-compiler | std-docs | 1.07 s / 595 ms (1.8x) | 26 ms (40.7x) | – / – |
| zigimg | zigimgtest | 1.65 s / 841 ms (2.0x) | 39 ms (42.0x) | 1.62 s / 58 ms (28.1x) |
| zeit | test | 710 ms / 361 ms (2.0x) | 24 ms (29.7x) | 711 ms / 36 ms (19.5x) |
| zbor | test | 1.23 s / 571 ms (2.2x) | 28 ms (44.2x) | 1.22 s / 40 ms (30.4x) |
| libvaxis | test | 1.38 s / 451 ms (3.1x) | 36 ms (38.4x) | 1.21 s / 46 ms (26.0x) |
| libvaxis | example-text_input | 1.26 s / 417 ms (3.0x) | 37 ms (34.4x) | – / – |
| cache.zig | test | 636 ms / 312 ms (2.0x) | 25 ms (25.3x) | 614 ms / 50 ms (12.3x) |
| zul | test | 2.39 s / 1.18 s (2.0x) | 33 ms (71.7x) | 2.40 s / 57 ms (42.1x) |
| metrics.zig | test | 774 ms / 431 ms (1.8x) | 25 ms (31.0x) | 782 ms / 44 ms (17.6x) |
| zig-hpke | test | 1.64 s / 855 ms (1.9x) | 25 ms (65.5x) | 1.62 s / 37 ms (43.7x) |
| libxev | xev-test | 760 ms / 402 ms (1.9x) | 30 ms (25.4x) | 760 ms / 63 ms (12.0x) |
| libxev | xev | 481 ms / 195 ms (2.5x) | 195 ms (2.5x) | – / – |
| zio | test | 2.17 s / 1.22 s (1.8x) | 51 ms (42.4x) | 2.12 s / 153 ms (13.8x) |
| zio | hello-world | 805 ms / 395 ms (2.0x) | 33 ms (24.7x) | 737 ms / 57 ms (13.0x) |
| zio | coro-demo | 594 ms / 228 ms (2.6x) | 32 ms (18.7x) | – / – |
| zio | mutex-demo | 941 ms / 460 ms (2.0x) | 40 ms (23.4x) | – / – |
| zio | ev-demo | 698 ms / 326 ms (2.1x) | 245 ms (2.9x) | – / – |
| zio | producer-consumer | 973 ms / 477 ms (2.0x) | 32 ms (30.5x) | – / – |
| zedis | test-unit | 1.26 s / 705 ms (1.8x) | 345 ms (3.7x) | 1.36 s / 56 ms (24.3x) |
| zedis | zedis | 1.16 s / 614 ms (1.9x) | 39 ms (29.8x) | 1.08 s / 52 ms (20.9x) |
| tokamak | test | 2.90 s / 1.80 s (1.6x) | 286 ms (10.2x) | 2.88 s / 49 ms (58.8x) |

## Run time vs upstream Debug and ReleaseSafe

`bench/runtime.py`, median of 5 runs; the three binaries print the same output.

| Program | zap | upstream Debug | upstream ReleaseSafe | zap / Debug | zap / ReleaseSafe |
| --- | ---: | ---: | ---: | ---: | ---: |
| fib | 118 ms | 190 ms | 71 ms | 0.62x | 1.7x |
| sieve | 125 ms | 451 ms | 111 ms | 0.28x | 1.1x |
| sort | 254 ms | 586 ms | 89 ms | 0.43x | 2.8x |
| hash | 337 ms | 685 ms | 56 ms | 0.49x | 6.0x |
| nbody | 201 ms | 436 ms | 24 ms | 0.46x | 8.3x |
| fmt | 105 ms | 201 ms | 21 ms | 0.52x | 4.9x |

`bench/realworld.py`, median of 5 runs:

| Workload | zap | upstream Debug | upstream ReleaseSafe | zap / Debug | zap / ReleaseSafe |
| --- | ---: | ---: | ---: | ---: | ---: |
| zig-fmt | 2.38 s | 4.09 s | – | 0.58x | – |
| zig-sema | 6.53 s | 11.40 s | – | 0.57x | – |
| vaxis | 750 ms | 1.07 s | 251 ms | 0.70x | 3.0x |
| zls-test | 1.08 s | 1.54 s | 267 ms | 0.70x | 4.0x |

## Findings

- **Behavior on 0.17.1** (`tools/corpus/run.py`, every target built and run with both compilers): 80 of 83 targets match upstream. The other three:
  - **ghostty ghostty-vt-test: zap crashes compiling it on d47bcde** (SIGSEGV; in ReleaseSafe, "access of union field 'ty_pl' while field 'ty_op' is active" in `vector.reduceIndex`). `@reduce` of a vector bitcast from a load reached the fused-`firstTrue` path, because the bitcast is also a `.view` operand. Minimal repro: `const v: @Vector(16, u8) = @bitCast(p.*); return @reduce(.Max, v);` with `p: *const [16]u8`. The vector thread's fix-reduce-view (78650d6, in the current batch) fixes it. With the same change, the target matches upstream (exit 1, 3004 passed, 102 skipped, 1 failed, in both builds) and times 25.82 s / 11.76 s cold-local (2.2x), 181 ms with donors (142x), and 25.42 s / 296 ms on the edit (86x). That row is left out of the corpus table above, which is d47bcde as it stands.
  - **tokamak test** differs as before: zap's frame trips tokamak's own misaligned `meta.transmute` in dom.document.test_0 (manifest note). Upstream's single failure is now http.client.test_0 expecting `.ok` from a live HTTP request, which depends on the network, not on the compiler.
  - **zio coro-demo** differs as before: upstream's Debug frames overflow the demo's 64 KiB coroutine stacks (manifest note).
- **No target is slower with zap than with upstream.**
- **std's debug.zig edit went from 1.77 s to 379 ms** with the cache thread's lazy-rt-inline fix; it now stays a lazy build. hello's same edit takes 57 ms.
- **Against the 0.17.0 scoreboard** (same orb type, 13942f5 and 15abfd4 for donors), every row moved by noise only: hello 21 ms cold-local with donors (19 ms before), vaxis 34 ms (33), zig 242 ms (210), std 107 ms (98). Without donors, vaxis went from 511 to 405 ms. Corpus: 2.0x without donors, 28.6x with (28.2x), edit builds 23.5x (24.5x).
- **Harness fixes for 0.17.1**:
  - The corpus no longer passes the recording zig's `--zig-lib-dir`, so each compiler uses its own lib dir. This run's commands were already re-recorded with 0.17.1 (`--refresh`); only five projects that are no longer in the manifest kept 0.17.0 paths.
  - anyzig's `test` and zine's `camera` targets were missing from 0.17.1's install-step recording, so their manifest entries now record the `test` step too. Recording anyzig's test step runs its tests, which download several Zig releases (about 4 GB under ~/.local/share/anyzig and the generation cache); delete them afterwards.
  - bench's zig workload says 0.17.1 (build_options version), and realworld.py copies upstream's source again on every run. It used to keep its 0.17.0 copy and its 0.17.0 upstream binaries, which made this run fail at first.
  - `bench/scoreboard.py` now saves its JSON after each part, and `--resume` continues an interrupted run.

### Rerunning

    zig build -Doptimize=ReleaseFast -p /tmp/zap-rf
    python3 bench/scoreboard.py --zap /tmp/zap-rf/bin/zap --note "Amp orb, 4 vCPU" [--out PATH] [--resume]
