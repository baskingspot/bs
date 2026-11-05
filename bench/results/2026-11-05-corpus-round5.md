# Corpus round 5 (2026-11-05)

Round 5 adds 17 projects (52 targets) to the corpus, aimed at 128-bit
arithmetic and crypto, inline assembly, heavy comptime, C and C++
interop, and programs with real run time. bs is ReleaseFast from main
84c75e56, with donors on. Upstream is zig 0.17.1 Debug. The machine is
an orb with 4 vCPUs (Intel Xeon @ 2.60GHz), 7 GB of memory (runs capped
at 6 GB) and Linux 6.1.

## Method

- `python3 tools/corpus/run.py --bs <bs> --no-edit --donors --projects
  <round 5> --results w5`, as for the donors rerun: each bs target builds
  cold-local without donors (timed), then again with donors, and that
  second binary runs. Run time is one wall-clock sample per target.
- wamr's four blocked targets were rerun with two lines patched in the
  work copy (below) to see what lies behind the first refusal.

## Summary

- 46 of 52 targets match upstream. The 6 others are 2 bs gaps (both
  `unsupported` refusals, no miscompile) and 1 CPU-dependent test.
- Cold-local build time, over the 46 targets that both compilers build:
  geomean 1.55x faster than upstream. With donors: 3.19x. zbullet-tests
  took 15.28 s cold because it was the run's first `-lc++` link, which
  built bs's libc++ and libc++abi into the global cache (0.24 to 0.35 s
  on later cold builds; upstream's were already cached). run.py now warms
  libc++ before timing, as it does bs's translate-c tool. Without that
  row the geomean is 1.68x.
- Run time, over the 15 matching targets whose run takes at least 50 ms:
  geomean 1.70x faster than upstream Debug. No target is slower.

| Project | Target | Verdict | Class |
|---|---|---|---|
| wamr | wamr-exe, spec-test-runner, simd-bench-runner, test:src/root.zig | bs refuses inline `mfence`, then `incl %eax` | bs (x86_64 inline assembler), fixed on main c0e63031 |
| zig-graph-compiler | zgc-executable-runner-test | bs refuses `--force_undefined` | bs (CLI and linker), fixed on main c0e63031 |
| zig-graph-compiler | test | comptime cost model picks a plan by `suggestVectorLength(f32)`; upstream at `-mcpu=x86_64_v2` fails the same way | CPU clamp, not a bug |
| forklift | test (test_user) | both panic in flir.test.int2float | forklift's bug |

## The bs gaps

Both are fixed on main c0e63031 (x86-asm-gaps and force-undefined).
Rerun there with an unpatched wamr, all 5 targets match upstream:
wamr-exe, spec-test-runner and simd-bench-runner build 1.6x to 2.2x
faster cold, test:src/root.zig passes 20 tests and skips 2 under both,
and zgc-executable-runner-test builds in 285 ms against 492 ms. A naked
function with the 27 instructions below and 9 more variants assembles to
the same bytes under both compilers.

- **x86_64 inline assembler.** wamr's `memoryFenceSeqCst`
  (src/platform/platform.zig:501) is `asm volatile ("mfence" ::: .{
  .memory = true })`, and its naked longjmp (src/runtime/aot/trap_jmp.zig:110)
  uses `incl %%eax`. With the fence moved to wamr's portable seq-cst RMW
  and `incl` replaced by `movl $1`, all four targets compile and match
  upstream (test:src/root.zig: 20 passed, 2 skipped under both). A probe
  of 39 common instructions, one per naked function, found 29 that bs
  refuses. Upstream accepts 27 of them: incl, incq, decl, bswapq, imulq
  reg,reg, popcntq, lzcntq, bsfq, cmovzq, sete, cmpxchgq reg,mem, `lock
  orq $0, (%rsp)`, `rep movsb`, cld, nop, hlt, leave, pushfq, rdtsc,
  rdtscp, rdrand, stmxcsr, ldmxcsr, clflush, mfence, lfence and sfence.
  The other two, movzbl and an unsized `prefetcht0 (%rdi)`, upstream
  rejects too. The error points at the enclosing `fn` line, not the `asm`
  statement.
- **`--force_undefined`.** zig-graph-compiler's build.zig calls
  `forceUndefinedSymbol("zgc_runtime_run")`; bs refuses the flag
  (src/main.zig's list of unsupported flags). Repro: `bs build-exe fu.zig
  --force_undefined keep_me` with `export fn keep_me() callconv(.c) u32`
  in fu.zig.

## Harness changes

- When both test runs die in the same test, run.py compares only the
  tests both runs reached: each compiler orders tests differently, so
  each has run a different set before the crash (forklift's test_user).
- run.py warms bs's libc++ and libc++abi before timing.

## Run time

Targets that match upstream and run for at least 50 ms. One sample
each, except eth.zig's, retimed once more back to back: 149.5 s
against 129.6 s (1.15x), matching the run's 147.6 s against 129.7 s.

| Project | Target | upstream | bs | upstream / bs |
|---|---|---:|---:|---:|
| eth.zig | test | 147.58 s | 129.70 s | 1.14x |
| zig-lmdb | test | 2.89 s | 2.91 s | 1.00x |
| hocdb | test:src/root.zig | 855 ms | 441 ms | 1.94x |
| maxminddb.zig | test | 121 ms | 65 ms | 1.88x |
| zig-rbtree | test.from_sorted | 1.55 s | 983 ms | 1.57x |
| archive.zig | test | 127 ms | 65 ms | 1.95x |
| lanes.zig | test | 82 ms | 70 ms | 1.17x |
| element-0 | e1_ffi_pow | 103 ms | 66 ms | 1.57x |
| element-0 | e2_ffi_list_increment | 94 ms | 64 ms | 1.45x |
| element-0 | e3_ffi_sum_of_squares | 102 ms | 64 ms | 1.60x |
| element-0 | test | 6.30 s | 4.07 s | 1.55x |
| zstd.zig | test | 53.34 s | 19.38 s | 2.75x |
| forklift | test | 187 ms | 68 ms | 2.74x |
| ulid.zig | bench | 28.17 s | 7.84 s | 3.59x |
| ssz.zig | test | 201 ms | 156 ms | 1.29x |

eth.zig and zig-lmdb are the low ratios because their time is in C that
upstream's `zig cc` compiles for both: 19 of 25 gdb stack samples of
bs's eth.zig run (21 of 25 of upstream's) are in blst's `mul_mont_n`,
and zig-lmdb's test runs LMDB.

## Scoreboard

Verdicts are recomputed with the run.py of this change.

| Project | Target | Verdict | upstream run | bs run | cold-local zig / bs | cold-local zig / bs with donors | edit zig / bs | run zig / bs |
|---|---|---|---|---|---:|---:|---:|---:|
| eth.zig | test | ok | exit 0, All 1122 tests passed. | exit 0, All 1122 tests passed. | 23.45 s / 8.76 s (2.7x) | 23.45 s / 7.76 s (3.0x) | – / – | 147.58 s / 129.70 s (1.1x) |
| zbullet | zbullet-tests | ok | exit 0, All 10 tests passed. | exit 0, All 10 tests passed. | 779 ms / 15.28 s (0.1x) | 779 ms / 239 ms (3.3x) | – / – | 28 ms / 19 ms (1.5x) |
| zstbi | zstbi-tests | ok | exit 0, All 3 tests passed. | exit 0, All 3 tests passed. | 1.01 s / 494 ms (2.0x) | 1.01 s / 540 ms (1.9x) | – / – | 11 ms / 7 ms (1.5x) |
| zig-lmdb | test | ok | exit 0, All 10 tests passed. | exit 0, All 10 tests passed. | 1.67 s / 1.09 s (1.5x) | 1.67 s / 1.05 s (1.6x) | – / – | 2.89 s / 2.91 s (1.0x) |
| hocdb | hocdb | ok | exit 0 | exit 0 | 998 ms / 347 ms (2.9x) | 998 ms / 936 ms (1.1x) | – / – | 13 ms / 12 ms (1.1x) |
| hocdb | test | ok | exit 0, All 0 tests passed. | exit 0, All 0 tests passed. | 508 ms / 329 ms (1.5x) | 508 ms / 294 ms (1.7x) | – / – | 6 ms / 3 ms (1.9x) |
| hocdb | test:src/root.zig | ok | exit 0, All 99 tests passed. | exit 0, All 99 tests passed. | 1.31 s / 646 ms (2.0x) | 1.31 s / 490 ms (2.7x) | – / – | 855 ms / 441 ms (1.9x) |
| zig-graph-compiler | zgc | ok | not run | not run | 1.02 s / 577 ms (1.8x) | 1.02 s / 455 ms (2.2x) | – / – | – / – |
| zig-graph-compiler | zgc-executable-runner-test | bs: compile error | not run | error[unsupported]: bs does not support '--force_undefined' yet | 534 ms / 1 ms (452.4x) | 534 ms / – | – / – | – / – |
| zig-graph-compiler | test | bs: compile error | exit 0, All 130 tests passed. | tests/network.zig:36:40: error[inactive-field]: access of union field 'kernel' while field | 7.35 s / 3.96 s (1.9x) | 7.35 s / – | – / – | 12 ms / – |
| maxminddb.zig | test | ok | exit 0, All 91 tests passed. | exit 0, All 91 tests passed. | 820 ms / 520 ms (1.6x) | 820 ms / 368 ms (2.2x) | – / – | 121 ms / 65 ms (1.9x) |
| zig-rbtree | example | ok | exit 0 | exit 0 | 468 ms / 472 ms (1.0x) | 468 ms / 245 ms (1.9x) | – / – | 5 ms / 2 ms (2.1x) |
| zig-rbtree | src.meta | ok | exit 0, All 32 tests passed. | exit 0, All 32 tests passed. | 502 ms / 283 ms (1.8x) | 502 ms / 121 ms (4.1x) | – / – | 19 ms / 11 ms (1.8x) |
| zig-rbtree | src.rbtree | ok | exit 0, All 0 tests passed. | exit 0, All 0 tests passed. | 474 ms / 261 ms (1.8x) | 474 ms / 125 ms (3.8x) | – / – | 5 ms / 2 ms (2.2x) |
| zig-rbtree | test.cached-nodes | ok | exit 0, All 2 tests passed. | exit 0, All 2 tests passed. | 554 ms / 279 ms (2.0x) | 554 ms / 170 ms (3.3x) | – / – | 7 ms / 3 ms (2.6x) |
| zig-rbtree | example.augmented_example | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 483 ms / 307 ms (1.6x) | 483 ms / 206 ms (2.3x) | – / – | 8 ms / 4 ms (2.0x) |
| zig-rbtree | src.rb_node | ok | exit 0, All 0 tests passed. | exit 0, All 0 tests passed. | 557 ms / 555 ms (1.0x) | 557 ms / 302 ms (1.8x) | – / – | 5 ms / 2 ms (2.5x) |
| zig-rbtree | test.from_sorted | ok | exit 0, All 3 tests passed. | exit 0, All 3 tests passed. | 495 ms / 285 ms (1.7x) | 495 ms / 168 ms (2.9x) | – / – | 1.55 s / 983 ms (1.6x) |
| zig-rbtree | test.test | ok | exit 0, All 29 tests passed. | exit 0, All 29 tests passed. | 600 ms / 396 ms (1.5x) | 600 ms / 208 ms (2.9x) | – / – | 10 ms / 9 ms (1.1x) |
| zig-rbtree | src.rb_unmanaged | ok | exit 0, All 0 tests passed. | exit 0, All 0 tests passed. | 470 ms / 293 ms (1.6x) | 470 ms / 25 ms (19.2x) | – / – | 5 ms / 2 ms (2.3x) |
| zig-rbtree | src.rb_managed | ok | exit 0, All 0 tests passed. | exit 0, All 0 tests passed. | 612 ms / 303 ms (2.0x) | 612 ms / 30 ms (20.3x) | – / – | 6 ms / 2 ms (2.6x) |
| zig-rbtree | src.index_functions | ok | exit 0, All 46 tests passed. | exit 0, All 46 tests passed. | 592 ms / 307 ms (1.9x) | 592 ms / 172 ms (3.4x) | – / – | 38 ms / 19 ms (2.0x) |
| zig-rbtree | src.rb_implementation | ok | exit 0, All 0 tests passed. | exit 0, All 0 tests passed. | 483 ms / 275 ms (1.8x) | 483 ms / 25 ms (19.6x) | – / – | 5 ms / 2 ms (2.5x) |
| zig-rbtree | example.release-example | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 628 ms / 320 ms (2.0x) | 628 ms / 195 ms (3.2x) | – / – | 6 ms / 3 ms (2.1x) |
| archive.zig | archive | ok | not run | not run | 75 ms / 167 ms (0.4x) | 75 ms / 10 ms (7.3x) | – / – | – / – |
| archive.zig | test | ok | exit 0, All 63 tests passed. | exit 0, All 63 tests passed. | 929 ms / 599 ms (1.6x) | 929 ms / 369 ms (2.5x) | – / – | 127 ms / 65 ms (1.9x) |
| lanes.zig | test | ok | exit 0, All 9 tests passed. | exit 0, All 9 tests passed. | 497 ms / 282 ms (1.8x) | 497 ms / 123 ms (4.0x) | – / – | 82 ms / 70 ms (1.2x) |
| element-0 | elz-repl | ok | not run | not run | 1.21 s / 652 ms (1.9x) | 1.21 s / 525 ms (2.3x) | – / – | – / – |
| element-0 | e1_ffi_pow | ok | exit 0 | exit 0 | 867 ms / 557 ms (1.6x) | 867 ms / 278 ms (3.1x) | – / – | 103 ms / 66 ms (1.6x) |
| element-0 | e2_ffi_list_increment | ok | exit 0 | exit 0 | 928 ms / 529 ms (1.8x) | 928 ms / 237 ms (3.9x) | – / – | 94 ms / 64 ms (1.5x) |
| element-0 | e3_ffi_sum_of_squares | ok | exit 0 | exit 0 | 874 ms / 541 ms (1.6x) | 874 ms / 205 ms (4.3x) | – / – | 102 ms / 64 ms (1.6x) |
| element-0 | test | ok | exit 0, All 120 tests passed. | exit 0, All 120 tests passed. | 1.06 s / 728 ms (1.5x) | 1.06 s / 534 ms (2.0x) | – / – | 6.30 s / 4.07 s (1.5x) |
| zstd.zig | zstd | ok | not run | not run | 66 ms / 27 ms (2.4x) | 66 ms / 15 ms (4.5x) | – / – | – / – |
| zstd.zig | test | ok | exit 0, All 536 tests passed. | exit 0, All 536 tests passed. | 868 ms / 571 ms (1.5x) | 868 ms / 404 ms (2.1x) | – / – | 53.34 s / 19.38 s (2.8x) |
| forklift | run | ok | not run | not run | 742 ms / 554 ms (1.3x) | 742 ms / 331 ms (2.2x) | – / – | – / – |
| forklift | test | ok | exit signal 6, no summary, died in flir.test.int2float | exit signal 6, no summary, died in flir.test.int2float | 820 ms / 498 ms (1.6x) | 820 ms / 341 ms (2.4x) | – / – | 187 ms / 68 ms (2.7x) |
| ulid.zig | bench | ok | exit 0 | exit 0 | 528 ms / 288 ms (1.8x) | 528 ms / 154 ms (3.4x) | – / – | 28.17 s / 7.84 s (3.6x) |
| ulid.zig | basic | ok | exit 0 | exit 0 | 457 ms / 292 ms (1.6x) | 457 ms / 133 ms (3.5x) | – / – | 5 ms / 2 ms (2.1x) |
| ulid.zig | test | ok | exit 0, All 17 tests passed. | exit 0, All 17 tests passed. | 482 ms / 358 ms (1.3x) | 482 ms / 122 ms (4.0x) | – / – | 5 ms / 2 ms (2.6x) |
| zoto | test | ok | exit 0, All 9 tests passed. | exit 0, All 9 tests passed. | 532 ms / 288 ms (1.8x) | 532 ms / 149 ms (3.6x) | – / – | 16 ms / 6 ms (2.6x) |
| wamr | wamrc | ok | not run | not run | 1.87 s / 1.19 s (1.6x) | 1.87 s / 964 ms (1.9x) | – / – | – / – |
| wamr | wamr-exe | bs: compile error | not run | src/platform/platform.zig:499:5: error[unsupported]: bs codegen: bs does not support this  | 4.09 s / 2.08 s (2.0x) | 4.09 s / – | – / – | – / – |
| wamr | spec-test-runner | bs: compile error | not run | src/platform/platform.zig:499:5: error[unsupported]: bs codegen: bs does not support this  | 2.07 s / 948 ms (2.2x) | 2.07 s / – | – / – | – / – |
| wamr | simd-bench-runner | bs: compile error | not run | src/platform/platform.zig:499:5: error[unsupported]: bs codegen: bs does not support this  | 1.82 s / 758 ms (2.4x) | 1.82 s / – | – / – | – / – |
| wamr | test | ok | exit 0, All 7 tests passed. | exit 0, All 7 tests passed. | 539 ms / 342 ms (1.6x) | 539 ms / 136 ms (4.0x) | – / – | 5 ms / 2 ms (2.4x) |
| wamr | test:src/wasi/minimal.zig | ok | exit 0, All 12 tests passed. | exit 0, All 12 tests passed. | 566 ms / 304 ms (1.9x) | 566 ms / 195 ms (2.9x) | – / – | 9 ms / 3 ms (3.3x) |
| wamr | test:tests/minimal_wasi.zig | ok | exit 0, All 2 tests passed. | exit 0, All 2 tests passed. | 563 ms / 384 ms (1.5x) | 563 ms / 185 ms (3.0x) | – / – | 6 ms / 4 ms (1.3x) |
| wamr | test:src/runtime/common/execution_context.zig | ok | exit 0, All 2 tests passed. | exit 0, All 2 tests passed. | 562 ms / 348 ms (1.6x) | 562 ms / 153 ms (3.7x) | – / – | 7 ms / 3 ms (2.1x) |
| wamr | test:src/root.zig | bs: compile error | exit 0, 20 passed; 2 skipped; 0 failed. | src/platform/platform.zig:499:5: error[unsupported]: bs codegen: bs does not support this  | 2.08 s / 903 ms (2.3x) | 2.08 s / – | – / – | 28 ms / – |
| ssz.zig | ssz | ok | not run | not run | 43 ms / 17 ms (2.5x) | 43 ms / 13 ms (3.4x) | – / – | – / – |
| ssz.zig | test | ok | exit 0, All 184 tests passed. | exit 0, All 184 tests passed. | 16.90 s / 8.97 s (1.9x) | 16.90 s / 8.56 s (2.0x) | – / – | 201 ms / 156 ms (1.3x) |
| ssz.zig | test:src/lib.zig | ok | exit 0, All 9 tests passed. | exit 0, All 9 tests passed. | 11.26 s / 4.66 s (2.4x) | 11.26 s / 4.55 s (2.5x) | – / – | 5 ms / 3 ms (2.1x) |

bs's translate-c tool was warmed before timing (46 ms). bs's libc++ was not yet: zbullet-tests' cold-local time includes its first build (see Summary).

## siv

Added after round 5: siv (github.com/rockorager/siv, 449e66f9, MIT), as
a whole build. bs is ReleaseFast from stage-next 8b8a35e4 (main plus
elfobj-alias and rdynamic), with donors and edit builds on. The edit
appends a statement to `Pool.submit` in src/pool/pool.zig.

- All 45 targets match upstream: the 34 test binaries pass 940 tests
  and skip 3 under both compilers.
- Cold-local: geomean 1.23x faster than upstream, 66 s
  against 97 s in total. With donors: 1.80x, 56 s.
- After the one-line edit: geomean 62.2x, 20.6 s against 89 s in
  total.
- Run time, over the 20 test binaries that run at least 50 ms: geomean
  1.37x. headless, the largest, takes 307.90 s against 148.09 s.
  render-vulkan's 0.70x in the run was its first sample (Mesa's shader
  cache): retimed 3 times, bs is 2.19 s against 2.35 s. loop is slower,
  0.85x over 3 samples: its stress test spins on `std.atomic.spinLoopHint`,
  an inline `pause`, and bs keeps every value of a function containing
  inline assembly in memory. A single-threaded loop of 50,000 random
  runs of up to 2000 `spinLoopHint`s takes 1.17 s under bs and 0.83 s
  under upstream, whose loop counter stays in a register.

| Target | upstream run | bs run | cold-local zig / bs | with donors | edit zig / bs | run zig / bs |
|---|---|---|---:|---:|---:|---:|
| siv | not run | not run | 13.91 s / 10.38 s (1.3x) | 13.91 s / 10.02 s (1.4x) | 13.33 s / 9.48 s (1.4x) | – |
| siv-static | not run | not run | 14.03 s / 9.05 s (1.6x) | 14.03 s / 9.18 s (1.5x) | 13.23 s / 8.69 s (1.5x) | – |
| siv-lua: | not run | not run | 156 ms / 557 ms (0.3x) | 156 ms / 572 ms (0.3x) | 131 ms / 2 ms (60.1x) | – |
| siv-lua-module: | not run | not run | 118 ms / 575 ms (0.2x) | 118 ms / 548 ms (0.2x) | 107 ms / 2 ms (44.4x) | – |
| siv-lua:src/lua/main.zig | not run | not run | 489 ms / 349 ms (1.4x) | 489 ms / 347 ms (1.4x) | 554 ms / 4 ms (145.1x) | – |
| lua: | not run | not run | 2.47 s / 1.77 s (1.4x) | 2.47 s / 1.32 s (1.9x) | 72 ms / 7 ms (10.3x) | – |
| abi | not run | not run | 145 ms / 339 ms (0.4x) | 145 ms / 212 ms (0.7x) | 61 ms / 4 ms (17.3x) | – |
| smoke | not run | not run | 111 ms / 455 ms (0.2x) | 111 ms / 294 ms (0.4x) | 64 ms / 4 ms (15.5x) | – |
| app: | not run | not run | 186 ms / 561 ms (0.3x) | 186 ms / 395 ms (0.5x) | 61 ms / 6 ms (10.7x) | – |
| guide-counter_test | not run | not run | 122 ms / 464 ms (0.3x) | 122 ms / 393 ms (0.3x) | 63 ms / 5 ms (12.0x) | – |
| guide-zig-package | not run | not run | 440 ms / 416 ms (1.1x) | 440 ms / 255 ms (1.7x) | 557 ms / 4 ms (129.3x) | – |
| a11y | exit 0, All 14 tests passed. | exit 0, All 14 tests passed. | 2.66 s / 1.75 s (1.5x) | 2.66 s / 1.67 s (1.6x) | 2.13 s / 169 ms (12.6x) | 930 ms / 885 ms (1.1x) |
| abi-unit | exit 0, All 17 tests passed. | exit 0, All 17 tests passed. | 669 ms / 476 ms (1.4x) | 669 ms / 239 ms (2.8x) | 786 ms / 2 ms (433.6x) | 16 ms / 6 ms (2.7x) |
| abi-wrapper | exit 0, All 5 tests passed. | exit 0, All 5 tests passed. | 1.65 s / 1.11 s (1.5x) | 1.65 s / 474 ms (3.5x) | 1.63 s / 4 ms (417.5x) | 14 ms / 10 ms (1.3x) |
| app | exit 0, All 24 tests passed. | exit 0, All 24 tests passed. | 4.13 s / 2.76 s (1.5x) | 4.13 s / 2.07 s (2.0x) | 3.82 s / 194 ms (19.7x) | 1.81 s / 1.72 s (1.1x) |
| compositor | exit 0, All 36 tests passed. | exit 0, All 36 tests passed. | 1.97 s / 1.53 s (1.3x) | 1.97 s / 1.14 s (1.7x) | 1.48 s / 117 ms (12.6x) | 1.72 s / 1.68 s (1.0x) |
| css | exit 0, All 10 tests passed. | exit 0, All 10 tests passed. | 790 ms / 551 ms (1.4x) | 790 ms / 606 ms (1.3x) | 884 ms / 2 ms (470.5x) | 14 ms / 7 ms (2.1x) |
| dbus | exit 0, All 51 tests passed. | exit 0, All 51 tests passed. | 741 ms / 427 ms (1.7x) | 741 ms / 307 ms (2.4x) | 788 ms / 18 ms (43.0x) | 1.49 s / 959 ms (1.5x) |
| doc | exit 0, All 23 tests passed. | exit 0, All 23 tests passed. | 2.38 s / 1.38 s (1.7x) | 2.38 s / 1.06 s (2.2x) | 2.17 s / 104 ms (21.0x) | 451 ms / 267 ms (1.7x) |
| docview | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 1.40 s / 1.05 s (1.3x) | 1.40 s / 891 ms (1.6x) | 744 ms / 115 ms (6.5x) | 12 ms / 15 ms (0.8x) |
| epub | exit 0, All 5 tests passed. | exit 0, All 5 tests passed. | 610 ms / 340 ms (1.8x) | 610 ms / 133 ms (4.6x) | 644 ms / 2 ms (368.6x) | 11 ms / 5 ms (2.3x) |
| headless | exit 0, All 331 tests passed. | exit 0, All 331 tests passed. | 15.68 s / 11.34 s (1.4x) | 15.68 s / 10.03 s (1.6x) | 15.03 s / 898 ms (16.7x) | 307.90 s / 148.09 s (2.1x) |
| html | exit 0, All 8 tests passed. | exit 0, All 8 tests passed. | 771 ms / 500 ms (1.5x) | 771 ms / 280 ms (2.8x) | 836 ms / 2 ms (357.3x) | 256 ms / 182 ms (1.4x) |
| icon | exit 0, All 6 tests passed. | exit 0, All 6 tests passed. | 588 ms / 433 ms (1.4x) | 588 ms / 182 ms (3.2x) | 597 ms / 2 ms (339.3x) | 20 ms / 7 ms (2.8x) |
| image | exit 0, All 15 tests passed. | exit 0, All 15 tests passed. | 809 ms / 490 ms (1.7x) | 809 ms / 405 ms (2.0x) | 812 ms / 2 ms (390.4x) | 87 ms / 77 ms (1.1x) |
| intl | exit 0, All 23 tests passed. | exit 0, All 23 tests passed. | 780 ms / 496 ms (1.6x) | 780 ms / 417 ms (1.9x) | 837 ms / 2 ms (347.5x) | 44 ms / 17 ms (2.7x) |
| loop | exit 0, All 12 tests passed. | exit 0, All 12 tests passed. | 681 ms / 493 ms (1.4x) | 681 ms / 198 ms (3.4x) | 957 ms / 37 ms (26.0x) | 1.95 s / 2.09 s (0.9x) |
| lua-gen-types | exit 0, All 5 tests passed. | exit 0, All 5 tests passed. | 11.77 s / 4.80 s (2.4x) | 11.77 s / 4.83 s (2.4x) | 11.66 s / 2 ms (4840.2x) | 70 ms / 30 ms (2.3x) |
| lua-notices | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 491 ms / 319 ms (1.5x) | 491 ms / 121 ms (4.1x) | 507 ms / 1 ms (356.5x) | 6 ms / 2 ms (2.7x) |
| markdown | exit 0, All 4 tests passed. | exit 0, All 4 tests passed. | 561 ms / 319 ms (1.8x) | 561 ms / 203 ms (2.8x) | 594 ms / 2 ms (321.0x) | 70 ms / 38 ms (1.8x) |
| notices | exit 0, All 2 tests passed. | exit 0, All 2 tests passed. | 521 ms / 301 ms (1.7x) | 521 ms / 140 ms (3.7x) | 527 ms / 1 ms (361.4x) | 7 ms / 3 ms (1.9x) |
| pdf | exit 0, All 11 tests passed. | exit 0, All 11 tests passed. | 1.52 s / 1.23 s (1.2x) | 1.52 s / 929 ms (1.6x) | 1.25 s / 248 ms (5.0x) | 71 ms / 42 ms (1.7x) |
| platform | exit 0, 26 passed; 1 skipped; 0 failed. | exit 0, 26 passed; 1 skipped; 0 failed. | 929 ms / 595 ms (1.6x) | 929 ms / 534 ms (1.7x) | 953 ms / 21 ms (45.8x) | 222 ms / 211 ms (1.1x) |
| pool | exit 0, All 7 tests passed. | exit 0, All 7 tests passed. | 572 ms / 284 ms (2.0x) | 572 ms / 124 ms (4.6x) | 515 ms / 21 ms (24.4x) | 80 ms / 74 ms (1.1x) |
| portal | exit 0, All 26 tests passed. | exit 0, All 26 tests passed. | 748 ms / 457 ms (1.6x) | 748 ms / 254 ms (2.9x) | 722 ms / 18 ms (39.3x) | 909 ms / 880 ms (1.0x) |
| raster | exit 0, All 22 tests passed. | exit 0, All 22 tests passed. | 536 ms / 312 ms (1.7x) | 536 ms / 159 ms (3.4x) | 541 ms / 2 ms (309.2x) | 12 ms / 7 ms (1.9x) |
| render-cpu | exit 0, All 23 tests passed. | exit 0, All 23 tests passed. | 1.17 s / 778 ms (1.5x) | 1.17 s / 558 ms (2.1x) | 869 ms / 103 ms (8.5x) | 399 ms / 281 ms (1.4x) |
| render-vulkan | exit 0, 7 passed; 2 skipped; 0 failed. | exit 0, 7 passed; 2 skipped; 0 failed. | 1.43 s / 1.08 s (1.3x) | 1.43 s / 907 ms (1.6x) | 1.05 s / 109 ms (9.6x) | 2.30 s / 3.31 s (0.7x) |
| scene | exit 0, All 9 tests passed. | exit 0, All 9 tests passed. | 594 ms / 365 ms (1.6x) | 594 ms / 209 ms (2.8x) | 614 ms / 2 ms (355.0x) | 12 ms / 6 ms (2.0x) |
| spell | exit 0, All 15 tests passed. | exit 0, All 15 tests passed. | 753 ms / 416 ms (1.8x) | 753 ms / 277 ms (2.7x) | 744 ms / 2 ms (354.3x) | 234 ms / 115 ms (2.0x) |
| svg | exit 0, All 24 tests passed. | exit 0, All 24 tests passed. | 1.03 s / 659 ms (1.6x) | 1.03 s / 435 ms (2.4x) | 948 ms / 2 ms (490.1x) | 23 ms / 12 ms (2.0x) |
| text | exit 0, All 71 tests passed. | exit 0, All 71 tests passed. | 1.69 s / 884 ms (1.9x) | 1.69 s / 806 ms (2.1x) | 1.62 s / 5 ms (302.3x) | 13.40 s / 8.25 s (1.6x) |
| trash | exit 0, All 10 tests passed. | exit 0, All 10 tests passed. | 559 ms / 360 ms (1.6x) | 559 ms / 187 ms (3.0x) | 568 ms / 2 ms (319.1x) | 18 ms / 12 ms (1.6x) |
| tray | exit 0, All 5 tests passed. | exit 0, All 5 tests passed. | 670 ms / 396 ms (1.7x) | 670 ms / 193 ms (3.5x) | 627 ms / 18 ms (35.3x) | 23 ms / 12 ms (1.9x) |
| ui | exit 0, All 91 tests passed. | exit 0, All 91 tests passed. | 2.95 s / 1.95 s (1.5x) | 2.95 s / 1.77 s (1.7x) | 2.74 s / 189 ms (14.5x) | 7.48 s / 3.54 s (2.1x) |
