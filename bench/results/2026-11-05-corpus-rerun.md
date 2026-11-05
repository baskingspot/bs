# Corpus rerun on main 23faa91 (2026-11-05)

These are the full corpus and the real-world run-time benchmarks, with bs
built from main 23faa91 (ReleaseFast). That build includes m7-corpus4 (the
zigcli, astroz and revo Sema fixes), probe-below-sp, fix-rvo-null,
fix-ret-rax, fix-asm-pinned and fix-tie-share. Upstream is zig 0.17.1. The
machine is an orb with 4 vCPUs (Intel Xeon @ 2.60GHz), 7 GB of memory
(runs capped at 6 GB) and Linux 6.1.

## Method

- Corpus: `python3 tools/corpus/run.py --bs <bs> --no-edit --results <name>`
  ran over all 60 projects and 178 targets. Each build is cold-local: an
  empty local cache with the global caches warm, and one build per
  compiler. zls, tokamak, zine and libvaxis were rerun after `--refresh`,
  because their recorded build options still named the removed
  `~/.cache/zap` toolchain.
- Run time: `python3 bench/realworld.py --compiler <bs> --workloads
  zig-fmt,zig-sema,vaxis,zls-test,corpus --runs 3`. The table gives the
  median wall time.

## Corpus

- 178 targets: 158 ok and 20 not.
- Cold-local build time, over the 162 targets that both compilers build:
  geomean 1.75x faster than upstream Debug, and 137 s against 261 s in
  total (1.90x).
- Six targets were slower than upstream in this run. On a rerun with
  three samples each, astroz is even (0.30 s against 0.30 s) and
  raylib-zig basic_window is 1.8x faster (0.35 s against 0.63 s). fizzy's
  lsp-protocol tests take 0.23 s against 0.64 s. The global bs cache had
  been emptied just before the run, so the first targets also paid for
  global artifacts.

| Project | Target | Verdict | First error or difference | Class |
|---|---|---|---|---|
| zwasm | test:src/zwasm.zig | run differs (exit 70 against 3464 passed) | SIGSEGV after jitTrampoline: `asm volatile ("" ::: jit_cohort_clobbers)` drops callee-saved clobbers given as a named constant | bs (Sema) |
| nanoui | test | 2 of 252 fail (scroll-bar tests) | a float kept in caller-saved xmm9 across a call (`tween`/`ease`) | bs (backend) |
| zig-libs | regex | both abort: bs in test 37 (SIGSEGV), upstream in test 44 (stack overflow) | deferred 7-byte load through a spilled pointer: loadBytes overwrites the r11 base | bs (backend) |
| libvaxis | example-c-tty | bs compile error | compiler_rt/stack_probe.zig: `orl $0,16(%%rsp)` unsupported in inline asm | bs (backend) |
| fizzy | fizzy, fizzy-glass-tests | bs compile error | dvui Data.zig:97:40 `@ptrCast` of `?[]u8`; SDLBackend.zig:4107 comptime reinterpret | bs (Sema), routed earlier |
| fizzy | text | bs compile error | `--export=fizzy_plugin_abi_fingerprint` unsupported | bs (CLI), routed earlier |
| revo | 6 targets | bs compile error | `-target x86_64-native-gnu` unsupported | bs (CLI), routed earlier |
| tokamak | test | bs abort against 1 upstream failure | `incorrect alignment` in meta.transmute: `@alignCast` of a 1-aligned local to `*const u128`, which upstream's frame layout happens to satisfy | program |
| zio | coro-demo | bs exit 0, upstream SIGABRT | upstream crash | upstream |
| buzz | 3 targets | upstream fails to compile | tail calls unsupported by the self-hosted backend (bs refuses them the same way) | upstream |
| zmath | 2 targets | upstream fails to compile | `genSetReg called with a value larger than dst_reg` (bs passes 78/78 tests) | upstream |

ghostty-vt-test now matches upstream: 3004 passed, 102 skipped and 1 failed
on both compilers, the same tinyio `dirRealPathFile` test. Both run its
3107 tests, but in a different order. zwasm's other targets and all of
ziex pass.

## Run time against upstream Debug and ReleaseSafe

bs/Debug geomean: 0.46 (24 workloads). bs/ReleaseSafe geomean: 3.79 (22
workloads; the compiler has no ReleaseSafe build).

| workload | bs | Debug | ReleaseSafe | bs / Debug | bs / ReleaseSafe |
|---|---|---|---|---|---|
| zig-fmt | 2.03 s | 4.07 s | - | 0.50x | - |
| zig-sema | 5.50 s | 11.19 s | - | 0.49x | - |
| vaxis | 523 ms | 1.06 s | 253 ms | 0.49x | 2.07x |
| zls-test | 932 ms | 1.53 s | 280 ms | 0.61x | 3.33x |
| translate-c | 2.33 s | 3.92 s | 329 ms | 0.60x | 7.08x |
| uucode-gen | 721 ms | 2.20 s | 190 ms | 0.33x | 3.81x |
| vulkan-gen | 418 ms | 871 ms | 138 ms | 0.48x | 3.03x |
| zigimg-test | 572 ms | 1.67 s | 203 ms | 0.34x | 2.82x |
| json-zig-test | 891 ms | 1.61 s | 276 ms | 0.55x | 3.23x |
| msgpack-test | 503 ms | 817 ms | 60 ms | 0.62x | 8.33x |
| tls-test | 1.03 s | 2.85 s | 114 ms | 0.36x | 9.06x |
| hpke-test | 309 ms | 1.22 s | 19 ms | 0.25x | 16.19x |
| zedis-test | 2.88 s | 3.41 s | 2.20 s | 0.84x | 1.31x |
| yaml-test | 1.47 s | 3.35 s | 399 ms | 0.44x | 3.68x |
| jinja-test | 2.54 s | 4.47 s | 576 ms | 0.57x | 4.40x |
| json5-test | 977 ms | 1.58 s | 117 ms | 0.62x | 8.36x |
| ini-test | 3.44 s | 6.43 s | 726 ms | 0.53x | 4.74x |
| tar-test | 1.58 s | 2.77 s | 561 ms | 0.57x | 2.81x |
| trie-test | 8.74 s | 20.38 s | 2.38 s | 0.43x | 3.68x |
| qr-test | 4.76 s | 12.33 s | 1.86 s | 0.39x | 2.56x |
| loc | 63 ms | 165 ms | 44 ms | 0.38x | 1.44x |
| zwasm-keccak | 2.13 s | 4.96 s | 769 ms | 0.43x | 2.77x |
| zwasm-gimli | 997 ms | 2.18 s | 281 ms | 0.46x | 3.55x |
| zwasm-memmove | 730 ms | 2.57 s | 269 ms | 0.28x | 2.72x |

tar-test skips one test fewer under ReleaseSafe (154 passed and 2 skipped,
against 153 and 3), so its output differs by mode, not by compiler.
