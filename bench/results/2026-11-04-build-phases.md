# `zap build` against `zig build`, per scenario and phase (2026-11-04)

Amp orb, 4 vCPU, Linux 6.1. zap ReleaseFast: before = origin/main 13942f5,
after = branch zap-build-speed (build runner in ReleaseSafe, no
`file_system_inputs` under zap's own lib directory). Upstream zig 0.17.0.
Each project's global cache warm (runner compiled, packages fetched).
Measured with the harness that became `bench/build_phases.py`.

- first: empty local cache and zig-out (3 runs); noop: nothing changed,
  3 s after the last build (10 runs); edit-zig: a one-line function-body
  edit to a Zig source (5 runs); edit-build: the same edit to build.zig's
  `pub fn build` (5 runs). Median wall time.
- Phases (ms), from `perf record -a` of the scheduler's exec/fork/exit
  events, fastest of three runs: startup (until the runner is exec'd) /
  configurer (build.zig's compile and the configure script) / maker (the
  runner alone) / compile (compile steps) / run (other children: run
  steps, generators, pkg-config, and for zap's repository the upstream
  `zig` it runs for its wasm; under `zig build` those count as compile).
- monstar's build forces `-fllvm` on its exe, which upstream honors and
  zap ignores (zap's rule for backend flags); its first build is mostly
  C++ through `zig clang` for both.

| project | scenario | `zig build` | `zap build` before | `zap build` after | upstream phases | before phases | after phases |
|---|---|---:|---:|---:|---|---|---|
| vaxis | first | 6.78 s | 1.10 s | 940.7 ms | 7.7 / 1275 / 73 / 4795 / 488 | 0.5 / 267 / 74 / 405 / 281 | 0.5 / 226 / 26 / 353 / 289 |
| vaxis | noop | 29.7 ms | 34.3 ms | 9.3 ms | 8.2 / 0.0 / 6.1 / 14 / 0.0 | 0.5 / 0.0 / 21 / 5.1 / 0.0 | 0.6 / 0.0 / 5.5 / 3.7 / 0.0 |
| vaxis | edit-zig | 1.19 s | 83.1 ms | 63.2 ms | 7.3 / 0.0 / 43 / 1062 / 0.0 | 0.5 / 0.0 / 28 / 46 / 0.0 | 0.6 / 0.0 / 12 / 45 / 0.0 |
| vaxis | edit-build | 1.28 s | 114.5 ms | 60.6 ms | 8.4 / 1232 / 21 / 13 / 0.0 | 0.5 / 48 / 55 / 4.8 / 0.0 | 0.5 / 50 / 9.6 / 4.6 / 0.0 |
| zf | first | 6.47 s | 1.11 s | 998.5 ms | 7.0 / 1230 / 82 / 4570 / 515 | 0.5 / 244 / 71 / 378 / 281 | 0.5 / 250 / 28 / 363 / 285 |
| zf | noop | 29.1 ms | 27.2 ms | 9.0 ms | 8.1 / 0.0 / 5.3 / 13 / 0.0 | 0.6 / 0.0 / 21 / 4.0 / 0.0 | 0.5 / 0.0 / 5.2 / 3.7 / 0.0 |
| zf | edit-zig | 1.19 s | 83.3 ms | 50.4 ms | 7.5 / 0.0 / 58 / 1095 / 0.0 | 0.5 / 0.0 / 30 / 40 / 0.0 | 0.5 / 0.0 / 13 / 36 / 0.0 |
| zf | edit-build | 1.28 s | 122.7 ms | 59.9 ms | 7.6 / 1216 / 23 / 14 / 0.0 | 0.6 / 50 / 55 / 4.1 / 0.0 | 0.6 / 46 / 7.9 / 3.8 / 0.0 |
| ziggy | first | 3.81 s | 1.03 s | 851.0 ms | 7.6 / 1245 / 83 / 2184 / 177 | 0.7 / 295 / 73 / 471 / 125 | 0.5 / 247 / 25 / 425 / 109 |
| ziggy | noop | 60.6 ms | 82.6 ms | 22.4 ms | 7.4 / 23 / 17 / 13 / 0.0 | 0.6 / 12 / 58 / 3.9 / 0.0 | 0.6 / 11 / 8.4 / 3.3 / 0.0 |
| ziggy | edit-zig | 1.52 s | 139.8 ms | 72.6 ms | 7.8 / 25 / 119 / 1369 / 0.0 | 0.7 / 13 / 76 / 48 / 0.0 | 0.5 / 12 / 20 / 42 / 0.0 |
| ziggy | edit-build | 1.36 s | 129.8 ms | 75.1 ms | 8.3 / 1233 / 20 / 13 / 0.0 | 0.8 / 66 / 67 / 4.3 / 0.0 | 0.6 / 62 / 8.8 / 3.6 / 0.0 |
| tls.zig | first | 9.94 s | 1.37 s | 1.18 s | 7.6 / 1130 / 62 / 8352 / 0.0 | 0.8 / 267 / 69 / 944 / 0.0 | 0.6 / 233 / 15 / 719 / 0.0 |
| tls.zig | noop | 40.4 ms | 50.1 ms | 13.2 ms | 7.4 / 0.0 / 6.0 / 28 / 0.0 | 0.8 / 0.0 / 36 / 11 / 0.0 | 0.5 / 0.0 / 5.1 / 8.8 / 0.0 |
| tls.zig | edit-zig | 10.13 s | 274.4 ms | 202.3 ms | 8.8 / 0.0 / 286 / 8481 / 0.0 | 0.6 / 0.0 / 78 / 162 / 0.0 | 0.6 / 0.0 / 22 / 206 / 0.0 |
| tls.zig | edit-build | 1.22 s | 145.8 ms | 69.9 ms | 7.9 / 1149 / 21 / 25 / 0.0 | 0.8 / 55 / 78 / 12 / 0.0 | 0.6 / 48 / 9.2 / 9.1 / 0.0 |
| zls | first | 5.43 s | 1.77 s | 1.35 s | 7.8 / 1297 / 116 / 3626 / 177 | 0.6 / 301 / 88 / 940 / 135 | 0.5 / 283 / 36 / 864 / 109 |
| zls | noop | 26.7 ms | 33.4 ms | 10.8 ms | 7.2 / 0.0 / 5.2 / 15 / 0.0 | 0.8 / 0.0 / 27 / 5.1 / 0.0 | 0.5 / 0.0 / 5.6 / 3.7 / 0.0 |
| zls | edit-zig | 3.06 s | 157.5 ms | 106.5 ms | 7.6 / 0.0 / 195 / 2727 / 0.0 | 0.7 / 0.0 / 61 / 84 / 0.0 | 0.5 / 0.0 / 35 / 71 / 0.0 |
| zls | edit-build | 1.37 s | 153.8 ms | 79.6 ms | 7.4 / 1264 / 21 / 12 / 0.0 | 0.6 / 78 / 59 / 4.2 / 0.0 | 0.6 / 66 / 9.8 / 3.7 / 0.0 |
| monstar | first | 58.28 s | 15.97 s | 12.37 s | 7.1 / 1761 / 158 / 55798 / 9.8 | 0.6 / 433 / 511 / 11505 / 7.9 | 0.8 / 438 / 77 / 11693 / 956 |
| monstar | noop | 179.4 ms | 689.3 ms | 157.9 ms | 7.2 / 49 / 38 / 101 / 8.5 | 0.6 / 32 / 549 / 63 / 23 | 0.6 / 38 / 26 / 55 / 11 |
| monstar | edit-zig | 31.49 s | 825.6 ms | 299.9 ms | 11 / 64 / 259 / 31534 / 22 | 0.6 / 29 / 566 / 166 / 15 | 0.6 / 30 / 82 / 145 / 24 |
| monstar | edit-build | 2.01 s | 721.8 ms | 210.1 ms | 7.6 / 1852 / 30 / 90 / 9.1 | 0.6 / 108 / 509 / 62 / 15 | 0.5 / 101 / 25 / 57 / 9.6 |
| zap | first | 17.90 s | 13.48 s | 12.64 s | 9.6 / 1432 / 184 / 15691 / 0.0 | 0.6 / 294 / 96 / 1164 / 10597 | 0.5 / 301 / 54 / 1142 / 10717 |
| zap | noop | 82.8 ms | 89.7 ms | 40.1 ms | 7.3 / 46 / 18 / 7.4 / 0.0 | 0.6 / 25 / 59 / 2.1 / 0.0 | 0.6 / 26 / 9.2 / 2.1 / 0.0 |
| zap | edit-zig | 5.85 s | 287.6 ms | 227.5 ms | 7.7 / 50 / 381 / 5319 / 0.0 | 0.6 / 29 / 133 / 118 / 0.0 | 0.6 / 27 / 64 / 124 / 0.0 |
| zap | edit-build | 1.40 s | 144.2 ms | 88.9 ms | 8.0 / 1348 / 22 / 8.4 / 0.0 | 0.6 / 78 / 58 / 2.4 / 0.0 | 0.6 / 73 / 10.0 / 2.3 / 0.0 |
