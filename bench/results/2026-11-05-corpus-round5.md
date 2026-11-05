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
| wamr | wamr-exe, spec-test-runner, simd-bench-runner, test:src/root.zig | bs refuses inline `mfence`, then `incl %eax` | bs (x86_64 inline assembler), open |
| zig-graph-compiler | zgc-executable-runner-test | bs refuses `--force_undefined` | bs (CLI and linker), open |
| zig-graph-compiler | test | comptime cost model picks a plan by `suggestVectorLength(f32)`; upstream at `-mcpu=x86_64_v2` fails the same way | CPU clamp, not a bug |
| forklift | test (test_user) | both panic in flir.test.int2float | forklift's bug |

## The bs gaps

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
