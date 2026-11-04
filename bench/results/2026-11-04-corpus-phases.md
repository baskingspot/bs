# `zap build` against `zig build` over tools/corpus

bench/build_phases.py over every git project in tools/corpus, on a 4-vCPU
orb (Linux 6.1), 2026-11-04, Zig 0.17.0: zap (ReleaseFast) at e89b24b with
zap-build-speed and the cached `-fno-emit-bin` steps, against upstream zig
0.17.0. Builds run the manifest's `build` steps in one invocation, 5 runs (3
for edits). Median wall time; phases (ms) of one perf-recorded run: startup /
configurer / maker / compile steps / run steps. `first` has the global cache
warm (build runner compiled) and the local cache empty; zap's `first` may take
donors from the global store, and `first-nodonor` is zap without them, against
upstream's `first`.

| scenario | projects | geomean zap/zig | max zap/zig |
|---|---:|---:|---:|
| first | 25 | 0.10 | 0.67 |
| noop | 25 | 0.45 | 1.09 |
| edit-zig | 25 | 0.12 | 0.79 |
| edit-build | 25 | 0.08 | 0.95 |
| first-nodonor | 25 | 0.48 | 0.84 |

zap slower: anyzig noop: zig 29.3 ms, zap 30.9 ms; zio noop: zig 11.65 s, zap 12.75 s; zul noop: zig 7.22 s, zap 7.25 s

Not compared: ghostty (zap: compile errors in src/terminal/c/terminal.zig on
this base; on main 05cced6 a crash in codegen/x86_64/vector.zig reduceIndex);
libvaxis (zap: `[switch-incomplete]` at src/c_api.zig:1183, which upstream
accepts); libxev (zap's xev-test hangs in ThreadPool, 3 of 40 runs; upstream's
0 of 80); zine (zap does not compile its C-only objects yet); zbor and
zig-hpke (one test vector fails under upstream too); tokamak (a test fails
under upstream too); zig-compiler (not a git project). build_phases.py now
builds tokamak's install step and accepts the known zbor and zig-hpke
failures.

The three noop losses are noise or run time: anyzig takes zap 20 ms and zig 30 ms in a
direct rerun; zul's run steps take 7.1 s under both; zio runs its tests on
every build (`has_side_effects`) and zap's test binary takes 12.4 s against
10.8 s.

| project | scenario | zig | zap | zap/zig | zig phases | zap phases |
|---|---|---:|---:|---:|---|---|
| anyzig | first | 5.98 s | 456.5 ms | 0.08 | 7 / 2168 / 124 / 3564 / 20 | 1 / 282 / 137 / 65 / 16 |
| anyzig | noop | 29.3 ms | 30.9 ms | 1.05 | 6 / 0 / 14 / 12 / 0 | 1 / 0 / 26 / 4 / 0 |
| anyzig | edit-zig | 3.29 s | 117.6 ms | 0.04 | 6 / 0 / 185 / 3007 / 0 | 1 / 0 / 63 / 80 / 0 |
| anyzig | edit-build | 2.11 s | 340.5 ms | 0.16 | 7 / 2113 / 57 / 19 / 0 | 0 / 293 / 52 / 4 / 0 |
| anyzig | first-nodonor |  | 3.22 s | 0.54 |  | 1 / 1128 / 127 / 1849 / 25 |
| cache.zig | first | 1.86 s | 89.8 ms | 0.05 | 9 / 1207 / 31 / 666 / 10 | 1 / 50 / 7 / 22 / 5 |
| cache.zig | noop | 30.2 ms | 12.2 ms | 0.40 | 8 / 0 / 5 / 7 / 10 | 1 / 0 / 4 / 2 / 6 |
| cache.zig | edit-zig | 654.3 ms | 57.5 ms | 0.09 | 8 / 0 / 12 / 628 / 10 | 1 / 0 / 5 / 44 / 6 |
| cache.zig | edit-build | 1.26 s | 57.6 ms | 0.05 | 12 / 1233 / 20 / 8 / 15 | 0 / 42 / 7 / 2 / 6 |
| cache.zig | first-nodonor |  | 919.7 ms | 0.49 |  | 1 / 599 / 8 / 292 / 6 |
| linuxwave | first | 3.19 s | 312.1 ms | 0.10 | 8 / 1282 / 50 / 1858 / 7 | 1 / 100 / 15 / 188 / 132 |
| linuxwave | noop | 28.8 ms | 9.5 ms | 0.33 | 10 / 0 / 5 / 11 / 0 | 1 / 0 / 4 / 5 / 0 |
| linuxwave | edit-zig | 815.5 ms | 180.3 ms | 0.22 | 8 / 0 / 24 / 641 / 140 | 1 / 0 / 9 / 31 / 137 |
| linuxwave | edit-build | 1.24 s | 52.0 ms | 0.04 | 8 / 1199 / 23 / 13 / 0 | 1 / 41 / 6 / 5 / 0 |
| linuxwave | first-nodonor |  | 1.52 s | 0.48 |  | 1 / 643 / 16 / 838 / 2 |
| metrics.zig | first | 2.06 s | 180.5 ms | 0.09 | 11 / 1133 / 26 / 744 / 96 | 1 / 56 / 8 / 23 / 89 |
| metrics.zig | noop | 106.3 ms | 83.9 ms | 0.79 | 7 / 0 / 4 / 6 / 88 | 1 / 0 / 4 / 2 / 75 |
| metrics.zig | edit-zig | 870.1 ms | 114.0 ms | 0.13 | 8 / 0 / 12 / 748 / 91 | 1 / 0 / 4 / 35 / 74 |
| metrics.zig | edit-build | 1.27 s | 132.2 ms | 0.10 | 8 / 1242 / 22 / 7 / 89 | 1 / 40 / 5 / 2 / 102 |
| metrics.zig | first-nodonor |  | 1.18 s | 0.57 |  | 1 / 586 / 7 / 397 / 77 |
| superhtml | first | 6.49 s | 350.6 ms | 0.05 | 8 / 1497 / 72 / 4598 / 0 | 1 / 50 / 31 / 149 / 91 |
| superhtml | noop | 69.0 ms | 28.6 ms | 0.41 | 8 / 22 / 18 / 23 / 0 | 1 / 16 / 12 / 11 / 0 |
| superhtml | edit-zig | 3.09 s | 113.4 ms | 0.04 | 8 / 21 / 167 / 2934 / 0 | 1 / 12 / 36 / 66 / 0 |
| superhtml | edit-build | 1.35 s | 82.6 ms | 0.06 | 8 / 1237 / 19 / 15 / 0 | 1 / 61 / 10 / 7 / 0 |
| superhtml | first-nodonor |  | 3.45 s | 0.53 |  | 1 / 897 / 22 / 2453 / 0 |
| tls.zig | first | 11.24 s | 3.61 s | 0.32 | 8 / 1169 / 64 / 10996 / 4365 | 1 / 46 / 28 / 1537 / 2262 |
| tls.zig | noop | 44.2 ms | 17.3 ms | 0.39 | 7 / 0 / 6 / 30 / 0 | 1 / 0 / 5 / 9 / 0 |
| tls.zig | edit-zig | 10.38 s | 2.56 s | 0.25 | 8 / 0 / 196 / 10181 / 11 | 0 / 0 / 9 / 239 / 2092 |
| tls.zig | edit-build | 1.20 s | 56.3 ms | 0.05 | 8 / 1093 / 22 / 30 / 0 | 1 / 46 / 8 / 10 / 0 |
| tls.zig | first-nodonor |  | 6.90 s | 0.61 |  | 1 / 599 / 31 / 4698 / 2348 |
| vulkan-zig | first | 1.96 s | 69.1 ms | 0.04 | 7 / 1071 / 37 / 786 / 0 | 1 / 31 / 6 / 28 / 3 |
| vulkan-zig | noop | 15.1 ms | 8.8 ms | 0.58 | 7 / 0 / 4 / 6 / 0 | 1 / 0 / 4 / 3 / 0 |
| vulkan-zig | edit-zig | 989.1 ms | 76.9 ms | 0.08 | 8 / 0 / 54 / 883 / 0 | 1 / 0 / 18 / 59 / 0 |
| vulkan-zig | edit-build | 1.16 s | 64.9 ms | 0.06 | 8 / 1133 / 18 / 7 / 0 | 1 / 58 / 9 / 3 / 0 |
| vulkan-zig | first-nodonor |  | 1.07 s | 0.54 |  | 1 / 622 / 12 / 497 / 0 |
| z2d | first | 2.75 s | 226.0 ms | 0.08 | 8 / 1191 / 61 / 1393 / 157 | 1 / 55 / 22 / 40 / 85 |
| z2d | noop | 21.3 ms | 5.8 ms | 0.27 | 8 / 0 / 4 / 6 / 0 | 1 / 0 / 3 / 2 / 0 |
| z2d | edit-zig | 1.53 s | 135.7 ms | 0.09 | 10 / 0 / 44 / 1387 / 156 | 1 / 0 / 18 / 31 / 85 |
| z2d | edit-build | 1.23 s | 52.6 ms | 0.04 | 9 / 1220 / 18 / 8 / 0 | 1 / 49 / 7 / 4 / 0 |
| z2d | first-nodonor |  | 1.67 s | 0.61 |  | 1 / 602 / 25 / 740 / 89 |
| zalgebra | first | 1.75 s | 85.3 ms | 0.05 | 8 / 1112 / 36 / 574 / 8 | 1 / 38 / 12 / 20 / 5 |
| zalgebra | noop | 19.1 ms | 7.3 ms | 0.38 | 8 / 0 / 3 / 8 / 0 | 1 / 0 / 3 / 2 / 0 |
| zalgebra | edit-zig | 597.1 ms | 56.8 ms | 0.10 | 8 / 0 / 23 / 550 / 8 | 1 / 0 / 10 / 24 / 5 |
| zalgebra | edit-build | 1.20 s | 45.2 ms | 0.04 | 8 / 1135 / 24 / 11 / 0 | 1 / 41 / 6 / 2 / 0 |
| zalgebra | first-nodonor |  | 899.4 ms | 0.52 |  | 1 / 539 / 14 / 261 / 5 |
| zBench | first | 3.14 s | 194.6 ms | 0.06 | 10 / 1123 / 51 / 1753 / 5 | 1 / 55 / 15 / 136 / 3 |
| zBench | noop | 39.6 ms | 11.1 ms | 0.28 | 8 / 0 / 5 / 14 / 0 | 1 / 0 / 5 / 7 / 0 |
| zBench | edit-zig | 616.8 ms | 82.0 ms | 0.13 | 9 / 0 / 24 / 569 / 6 | 1 / 0 / 4 / 54 / 0 |
| zBench | edit-build | 1.20 s | 55.4 ms | 0.05 | 8 / 1177 / 20 / 23 / 0 | 1 / 45 / 7 / 6 / 0 |
| zBench | first-nodonor |  | 1.40 s | 0.45 |  | 1 / 626 / 15 / 690 / 2 |
| zedis | first | 6.39 s | 3.14 s | 0.49 | 8 / 1182 / 55 / 1335 / 3711 | 1 / 89 / 22 / 38 / 2964 |
| zedis | noop | 33.1 ms | 6.9 ms | 0.21 | 8 / 0 / 4 / 21 / 0 | 0 / 0 / 4 / 4 / 0 |
| zedis | edit-zig | 4.79 s | 3.04 s | 0.63 | 7 / 0 / 37 / 1289 / 3404 | 1 / 0 / 18 / 57 / 3011 |
| zedis | edit-build | 1.30 s | 62.7 ms | 0.05 | 11 / 1268 / 20 / 21 / 0 | 1 / 50 / 29 / 3 / 2976 |
| zedis | first-nodonor |  | 4.11 s | 0.64 |  | 1 / 609 / 23 / 559 / 3034 |
| zeit | first | 2.14 s | 382.7 ms | 0.18 | 8 / 1160 / 39 / 698 / 224 | 1 / 47 / 15 / 31 / 357 |
| zeit | noop | 14.0 ms | 5.0 ms | 0.36 | 7 / 0 / 4 / 5 / 0 | 1 / 0 / 3 / 2 / 0 |
| zeit | edit-zig | 930.5 ms | 367.0 ms | 0.39 | 8 / 0 / 25 / 676 / 223 | 1 / 0 / 18 / 50 / 303 |
| zeit | edit-build | 1.19 s | 77.0 ms | 0.06 | 8 / 1164 / 17 / 8 / 0 | 1 / 47 / 6 / 2 / 0 |
| zeit | first-nodonor |  | 1.25 s | 0.58 |  | 1 / 612 / 14 / 340 / 320 |
| zf | first | 6.63 s | 479.1 ms | 0.07 | 8 / 1243 / 70 / 4552 / 501 | 1 / 125 / 32 / 62 / 294 |
| zf | noop | 21.4 ms | 12.2 ms | 0.57 | 8 / 0 / 6 / 12 / 0 | 1 / 0 / 6 / 4 / 0 |
| zf | edit-zig | 1.30 s | 74.9 ms | 0.06 | 8 / 0 / 85 / 1197 / 0 | 1 / 0 / 9 / 40 / 4 |
| zf | edit-build | 1.32 s | 68.0 ms | 0.05 | 8 / 1223 / 21 / 17 / 0 | 1 / 54 / 10 / 7 / 0 |
| zf | first-nodonor |  | 1.71 s | 0.26 |  | 1 / 718 / 35 / 948 / 291 |
| zig-args | first | 5.57 s | 106.8 ms | 0.02 | 9 / 1201 / 49 / 4135 / 5 | 1 / 48 / 9 / 28 / 13 |
| zig-args | noop | 47.6 ms | 27.6 ms | 0.58 | 8 / 0 / 8 / 8 / 23 | 1 / 0 / 7 / 4 / 17 |
| zig-args | edit-zig | 4.53 s | 46.5 ms | 0.01 | 9 / 0 / 29 / 4260 / 8 | 1 / 0 / 4 / 28 / 12 |
| zig-args | edit-build | 1.28 s | 66.5 ms | 0.05 | 9 / 1217 / 30 / 17 / 33 | 0 / 38 / 9 / 2 / 14 |
| zig-args | first-nodonor |  | 1.23 s | 0.22 |  | 1 / 573 / 16 / 397 / 5 |
| zig-clap | first | 3.32 s | 481.9 ms | 0.15 | 9 / 1273 / 44 / 2429 / 0 | 1 / 57 / 16 / 413 / 6 |
| zig-clap | noop | 31.7 ms | 9.3 ms | 0.29 | 7 / 0 / 5 / 18 / 0 | 1 / 0 / 4 / 6 / 0 |
| zig-clap | edit-zig | 2.14 s | 159.1 ms | 0.07 | 7 / 0 / 61 / 2310 / 0 | 1 / 0 / 9 / 114 / 0 |
| zig-clap | edit-build | 1.23 s | 55.7 ms | 0.05 | 7 / 1324 / 19 / 23 / 0 | 1 / 39 / 7 / 6 / 0 |
| zig-clap | first-nodonor |  | 1.61 s | 0.49 |  | 1 / 555 / 11 / 942 / 0 |
| zig-ecs | first | 3.12 s | 102.5 ms | 0.03 | 7 / 1109 / 132 / 1732 / 0 | 0 / 43 / 17 / 46 / 0 |
| zig-ecs | noop | 119.4 ms | 22.4 ms | 0.19 | 9 / 0 / 33 / 41 / 0 | 1 / 0 / 13 / 8 / 0 |
| zig-ecs | edit-zig | 1.86 s | 125.9 ms | 0.07 | 7 / 0 / 44 / 1969 / 0 | 1 / 0 / 16 / 126 / 0 |
| zig-ecs | edit-build | 1.26 s | 65.4 ms | 0.05 | 7 / 1157 / 95 / 46 / 0 | 1 / 42 / 11 / 8 / 0 |
| zig-ecs | first-nodonor |  | 1.33 s | 0.43 |  | 0 / 549 / 15 / 772 / 0 |
| zig-minisign | first | 2.16 s | 164.2 ms | 0.08 | 8 / 1146 / 37 / 885 / 18 | 1 / 90 / 13 / 24 / 14 |
| zig-minisign | noop | 14.6 ms | 6.9 ms | 0.47 | 8 / 0 / 4 / 8 / 0 | 1 / 0 / 4 / 3 / 0 |
| zig-minisign | edit-zig | 683.9 ms | 52.6 ms | 0.08 | 8 / 0 / 57 / 617 / 0 | 1 / 0 / 17 / 40 / 0 |
| zig-minisign | edit-build | 1.21 s | 70.8 ms | 0.06 | 7 / 1175 / 17 / 9 / 0 | 1 / 60 / 6 / 3 / 0 |
| zig-minisign | first-nodonor |  | 1.18 s | 0.55 |  | 1 / 657 / 16 / 383 / 13 |
| zig-protobuf | first | 12.00 s | 3.73 s | 0.31 | 8 / 1224 / 112 / 10419 / 458 | 1 / 49 / 36 / 3601 / 262 |
| zig-protobuf | noop | 650.5 ms | 387.8 ms | 0.60 | 8 / 0 / 14 / 147 / 463 | 1 / 0 / 18 / 79 / 374 |
| zig-protobuf | edit-zig | 9.37 s | 963.6 ms | 0.10 | 8 / 0 / 62 / 8551 / 561 | 1 / 0 / 23 / 640 / 503 |
| zig-protobuf | edit-build | 1.75 s | 400.4 ms | 0.23 | 7 / 1123 / 25 / 112 / 494 | 1 / 53 / 19 / 73 / 272 |
| zig-protobuf | first-nodonor |  | 5.28 s | 0.44 |  | 1 / 695 / 45 / 5578 / 275 |
| ziggy | first | 6.71 s | 393.2 ms | 0.06 | 9 / 1207 / 58 / 5142 / 34 | 1 / 53 / 25 / 292 / 31 |
| ziggy | noop | 102.3 ms | 48.5 ms | 0.47 | 7 / 29 / 21 / 37 / 4 | 1 / 12 / 13 / 15 / 4 |
| ziggy | edit-zig | 1.50 s | 101.6 ms | 0.07 | 7 / 26 / 136 / 1344 / 22 | 1 / 12 / 28 / 47 / 9 |
| ziggy | edit-build | 1.28 s | 96.8 ms | 0.08 | 7 / 1213 / 20 / 34 / 3 | 1 / 54 / 15 / 17 / 5 |
| ziggy | first-nodonor |  | 3.22 s | 0.48 |  | 1 / 628 / 28 / 2299 / 12 |
| zigimg | first | 13.84 s | 784.6 ms | 0.06 | 11 / 1136 / 80 / 10750 / 1385 | 0 / 63 / 14 / 33 / 617 |
| zigimg | noop | 1.43 s | 616.7 ms | 0.43 | 7 / 0 / 4 / 6 / 1397 | 1 / 0 / 4 / 2 / 633 |
| zigimg | edit-zig | 12.00 s | 893.3 ms | 0.07 | 8 / 0 / 122 / 10224 / 1402 | 1 / 0 / 27 / 54 / 633 |
| zigimg | edit-build | 2.57 s | 674.7 ms | 0.26 | 8 / 1181 / 19 / 7 / 1473 | 1 / 41 / 6 / 2 / 609 |
| zigimg | first-nodonor |  | 2.10 s | 0.15 |  | 0 / 579 / 15 / 788 / 614 |
| zio | first | 25.14 s | 16.12 s | 0.64 | 9 / 1192 / 115 / 13791 / 11440 | 1 / 80 / 8 / 5082 / 7368 |
| zio | noop | 11.65 s | 12.75 s | 1.09 | 9 / 0 / 6 / 511 / 10838 | 1 / 0 / 5 / 123 / 12373 |
| zio | edit-zig | 24.36 s | 12.18 s | 0.50 | 8 / 0 / 85 / 13527 / 11528 | 1 / 0 / 4 / 890 / 11799 |
| zio | edit-build | 12.51 s | 11.85 s | 0.95 | 8 / 1140 / 17 / 306 / 10673 | 1 / 46 / 5 / 60 / 12370 |
| zio | first-nodonor |  | 15.24 s | 0.61 |  | 0 / 606 / 25 / 5441 / 12157 |
| zli | first | 1.89 s | 105.7 ms | 0.06 | 8 / 1202 / 27 / 677 / 27 | 1 / 50 / 6 / 24 / 19 |
| zli | noop | 46.9 ms | 24.6 ms | 0.52 | 8 / 0 / 4 / 6 / 29 | 1 / 0 / 4 / 2 / 18 |
| zli | edit-zig | 688.5 ms | 45.6 ms | 0.07 | 7 / 0 / 12 / 629 / 4 | 1 / 0 / 4 / 25 / 16 |
| zli | edit-build | 1.17 s | 65.5 ms | 0.06 | 7 / 1088 / 17 / 6 / 27 | 0 / 39 / 7 / 2 / 17 |
| zli | first-nodonor |  | 856.7 ms | 0.45 |  | 1 / 624 / 9 / 292 / 17 |
| zlinter | first | 1.23 s | 115.1 ms | 0.09 | 7 / 1207 / 16 / 0 / 0 | 0 / 112 / 5 / 0 / 0 |
| zlinter | noop | 39.2 ms | 16.6 ms | 0.42 | 8 / 21 / 14 / 0 / 0 | 1 / 10 / 6 / 0 / 0 |
| zlinter | edit-zig | 44.9 ms | 12.7 ms | 0.28 | 7 / 19 / 15 / 0 / 0 | 0 / 8 / 4 / 0 / 0 |
| zlinter | edit-build | 1.23 s | 60.4 ms | 0.05 | 10 / 1236 / 16 / 0 / 0 | 1 / 53 / 5 / 0 / 0 |
| zlinter | first-nodonor |  | 708.4 ms | 0.57 |  | 1 / 606 / 5 / 0 / 0 |
| zls | first | 9.96 s | 2.29 s | 0.23 | 8 / 1247 / 43 / 5550 / 3932 | 1 / 51 / 21 / 160 / 2120 |
| zls | noop | 525.6 ms | 253.7 ms | 0.48 | 7 / 0 / 19 / 17 / 475 | 1 / 0 / 25 / 8 / 228 |
| zls | edit-zig | 7.80 s | 2.18 s | 0.28 | 7 / 0 / 35 / 6304 / 1912 | 1 / 0 / 5 / 181 / 2051 |
| zls | edit-build | 2.02 s | 391.6 ms | 0.19 | 7 / 1433 / 38 / 21 / 509 | 1 / 80 / 38 / 8 / 350 |
| zls | first-nodonor |  | 6.93 s | 0.70 |  | 1 / 1038 / 22 / 4080 / 2055 |
| zul | first | 10.69 s | 7.21 s | 0.67 | 8 / 1169 / 29 / 2234 / 7012 | 1 / 52 / 9 / 31 / 7188 |
| zul | noop | 7.22 s | 7.25 s | 1.00 | 8 / 0 / 5 / 6 / 7137 | 1 / 0 / 4 / 2 / 7160 |
| zul | edit-zig | 9.25 s | 7.27 s | 0.79 | 7 / 0 / 19 / 2323 / 7221 | 1 / 0 / 4 / 48 / 7405 |
| zul | edit-build | 8.32 s | 7.20 s | 0.87 | 7 / 1221 / 18 / 8 / 7186 | 1 / 38 / 7 / 2 / 7138 |
| zul | first-nodonor |  | 8.97 s | 0.84 |  | 1 / 577 / 8 / 1095 / 7067 |
