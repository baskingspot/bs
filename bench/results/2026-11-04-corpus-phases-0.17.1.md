# `zap build` against `zig build` over tools/corpus (Zig 0.17.1)

bench/build_phases.py over every git project in tools/corpus that zap
builds, on a 4-vCPU orb (Linux 6.1), 2026-11-04, Zig 0.17.1: zap
(ReleaseFast) at fc7df0f on main 1431f79 against upstream zig 0.17.1. Same
method as 2026-11-04-corpus-phases.md (0.17.0): the manifest's `build` steps
in one invocation, 5 runs (3 for edits), median wall time; phases (ms) of one
perf-recorded run: startup / configurer / maker / compile steps / run steps.
zap's `first` may take donors from the global store; `first-nodonor` is zap
without them, against upstream's `first`. Left out: ghostty (zap crashed in
codegen/x86_64/vector.zig `reduceIndex`; fixed on main 72ae234 by
fix-reduce-view, where ghostty's step and monstar build again),
libvaxis (zap's `[switch-incomplete]` at src/c_api.zig:1183) and zine (C-only
objects), all routed to their threads.

| scenario | projects | geomean zap/zig | max zap/zig |
|---|---:|---:|---:|
| first | 29 | 0.10 | 0.72 |
| noop | 29 | 0.35 | 1.01 |
| edit-zig | 29 | 0.11 | 0.76 |
| edit-build | 29 | 0.08 | 0.95 |
| first-nodonor | 29 | 0.47 | 0.84 |

zap slower: zio noop: zig 12.06 s, zap 12.23 s. zio runs its tests on every
build (`has_side_effects`): the build itself takes zap 46 ms against
upstream's 377 ms, and zap's test binary runs 12.2 s against 11.0 s, a
question of generated-code speed. libxev's xev-test did not hang in any run.

| project | scenario | zig | zap | zap/zig | zig phases | zap phases |
|---|---|---:|---:|---:|---|---|
| anyzig | first | 6.06 s | 444.4 ms | 0.07 | 8 / 2071 / 146 / 3670 / 21 | 1 / 267 / 134 / 59 / 16 |
| anyzig | noop | 45.2 ms | 26.3 ms | 0.58 | 8 / 0 / 16 / 13 / 0 | 1 / 0 / 24 / 4 / 0 |
| anyzig | edit-zig | 3.39 s | 130.5 ms | 0.04 | 9 / 0 / 190 / 3200 / 0 | 1 / 0 / 49 / 69 / 0 |
| anyzig | edit-build | 2.22 s | 357.4 ms | 0.16 | 7 / 2098 / 58 / 15 / 0 | 1 / 294 / 48 / 4 / 0 |
| anyzig | first-nodonor |  | 3.03 s | 0.50 |  | 1 / 1119 / 121 / 1684 / 14 |
| cache.zig | first | 1.81 s | 73.4 ms | 0.04 | 7 / 1241 / 27 / 600 / 10 | 1 / 41 / 6 / 20 / 5 |
| cache.zig | noop | 28.6 ms | 11.7 ms | 0.41 | 10 / 0 / 6 / 9 / 15 | 0 / 0 / 3 / 2 / 5 |
| cache.zig | edit-zig | 633.9 ms | 63.8 ms | 0.10 | 7 / 0 / 11 / 589 / 10 | 1 / 0 / 4 / 78 / 5 |
| cache.zig | edit-build | 1.23 s | 54.0 ms | 0.04 | 7 / 1190 / 19 / 8 / 11 | 1 / 42 / 5 / 2 / 5 |
| cache.zig | first-nodonor |  | 905.4 ms | 0.50 |  | 1 / 595 / 8 / 292 / 6 |
| libxev | first | 2.47 s | 307.7 ms | 0.12 | 7 / 1164 / 61 / 996 / 308 | 1 / 32 / 5 / 237 / 26 |
| libxev | noop | 61.0 ms | 14.2 ms | 0.23 | 7 / 15 / 17 / 23 / 0 | 1 / 6 / 5 / 3 / 0 |
| libxev | edit-zig | 1.41 s | 343.7 ms | 0.24 | 7 / 20 / 46 / 1050 / 298 | 1 / 6 / 20 / 271 / 44 |
| libxev | edit-build | 1.24 s | 72.3 ms | 0.06 | 7 / 1357 / 25 / 24 / 0 | 1 / 63 / 7 / 4 / 0 |
| libxev | first-nodonor |  | 1.32 s | 0.53 |  | 1 / 644 / 20 / 437 / 203 |
| linuxwave | first | 3.15 s | 253.7 ms | 0.08 | 7 / 1270 / 48 / 1708 / 6 | 1 / 92 / 21 / 130 / 141 |
| linuxwave | noop | 44.8 ms | 13.2 ms | 0.29 | 11 / 0 / 8 / 29 / 0 | 1 / 0 / 4 / 5 / 0 |
| linuxwave | edit-zig | 1.27 s | 179.7 ms | 0.14 | 7 / 0 / 23 / 679 / 146 | 1 / 0 / 12 / 35 / 178 |
| linuxwave | edit-build | 1.31 s | 61.9 ms | 0.05 | 7 / 1374 / 21 / 22 / 0 | 1 / 40 / 7 / 6 / 0 |
| linuxwave | first-nodonor |  | 1.55 s | 0.49 |  | 1 / 564 / 12 / 1051 / 0 |
| metrics.zig | first | 2.19 s | 184.5 ms | 0.08 | 7 / 1216 / 29 / 802 / 101 | 1 / 50 / 7 / 32 / 91 |
| metrics.zig | noop | 125.2 ms | 99.4 ms | 0.79 | 13 / 0 / 8 / 10 / 100 | 1 / 0 / 3 / 2 / 92 |
| metrics.zig | edit-zig | 892.6 ms | 151.3 ms | 0.17 | 8 / 0 / 14 / 788 / 94 | 1 / 0 / 4 / 40 / 102 |
| metrics.zig | edit-build | 1.29 s | 126.2 ms | 0.10 | 8 / 1183 / 19 / 7 / 91 | 1 / 40 / 5 / 2 / 77 |
| metrics.zig | first-nodonor |  | 1.23 s | 0.56 |  | 1 / 661 / 8 / 434 / 98 |
| superhtml | first | 5.73 s | 208.0 ms | 0.04 | 7 / 1293 / 71 / 4409 / 0 | 1 / 34 / 14 / 105 / 49 |
| superhtml | noop | 54.8 ms | 25.2 ms | 0.46 | 7 / 21 / 20 / 16 / 0 | 0 / 8 / 8 / 6 / 0 |
| superhtml | edit-zig | 3.21 s | 106.9 ms | 0.03 | 7 / 22 / 221 / 3014 / 0 | 1 / 9 / 24 / 61 / 0 |
| superhtml | edit-build | 1.28 s | 77.3 ms | 0.06 | 11 / 1384 / 20 / 14 / 0 | 1 / 62 / 9 / 7 / 0 |
| superhtml | first-nodonor |  | 3.09 s | 0.54 |  | 0 / 693 / 19 / 3307 / 35 |
| tls.zig | first | 12.01 s | 2.86 s | 0.24 | 7 / 1219 / 101 / 11337 / 3008 | 0 / 52 / 25 / 1652 / 1581 |
| tls.zig | noop | 52.8 ms | 13.2 ms | 0.25 | 8 / 0 / 7 / 35 / 0 | 0 / 0 / 5 / 8 / 0 |
| tls.zig | edit-zig | 10.07 s | 1.56 s | 0.16 | 7 / 0 / 51 / 11104 / 3050 | 1 / 0 / 25 / 216 / 1306 |
| tls.zig | edit-build | 1.21 s | 67.9 ms | 0.06 | 10 / 1171 / 30 / 39 / 0 | 1 / 55 / 8 / 9 / 0 |
| tls.zig | first-nodonor |  | 6.86 s | 0.57 |  | 1 / 547 / 24 / 5090 / 1476 |
| tokamak | first | 1.26 s | 106.8 ms | 0.08 | 8 / 1387 / 19 / 0 / 0 | 1 / 97 / 5 / 0 / 0 |
| tokamak | noop | 14.2 ms | 3.4 ms | 0.24 | 7 / 0 / 4 / 0 / 0 | 1 / 0 / 4 / 0 / 0 |
| tokamak | edit-zig | 14.8 ms | 3.8 ms | 0.25 | 7 / 0 / 4 / 0 / 0 | 1 / 0 / 3 / 0 / 0 |
| tokamak | edit-build | 1.23 s | 59.0 ms | 0.05 | 7 / 1267 / 19 / 0 / 0 | 1 / 55 / 5 / 0 / 0 |
| tokamak | first-nodonor |  | 666.6 ms | 0.53 |  | 1 / 647 / 7 / 0 / 0 |
| vulkan-zig | first | 2.15 s | 97.8 ms | 0.05 | 7 / 1163 / 39 / 916 / 0 | 1 / 55 / 8 / 23 / 4 |
| vulkan-zig | noop | 21.9 ms | 5.1 ms | 0.23 | 7 / 0 / 4 / 7 / 0 | 0 / 0 / 3 / 2 / 0 |
| vulkan-zig | edit-zig | 988.0 ms | 58.5 ms | 0.06 | 7 / 0 / 51 / 918 / 0 | 0 / 0 / 11 / 44 / 0 |
| vulkan-zig | edit-build | 1.56 s | 48.4 ms | 0.03 | 10 / 1389 / 20 / 8 / 0 | 1 / 41 / 5 / 2 / 0 |
| vulkan-zig | first-nodonor |  | 990.2 ms | 0.46 |  | 1 / 578 / 9 / 405 / 0 |
| z2d | first | 3.02 s | 171.0 ms | 0.06 | 8 / 1164 / 65 / 1331 / 159 | 1 / 35 / 21 / 31 / 79 |
| z2d | noop | 24.6 ms | 6.5 ms | 0.26 | 7 / 0 / 4 / 7 / 0 | 1 / 0 / 3 / 2 / 0 |
| z2d | edit-zig | 1.60 s | 137.2 ms | 0.09 | 8 / 0 / 44 / 1365 / 156 | 1 / 0 / 18 / 33 / 77 |
| z2d | edit-build | 1.40 s | 49.3 ms | 0.04 | 8 / 1298 / 21 / 10 / 0 | 1 / 46 / 5 / 2 / 0 |
| z2d | first-nodonor |  | 1.45 s | 0.48 |  | 0 / 573 / 22 / 662 / 89 |
| zalgebra | first | 1.82 s | 83.5 ms | 0.05 | 7 / 1259 / 38 / 623 / 8 | 0 / 48 / 12 / 21 / 4 |
| zalgebra | noop | 17.8 ms | 4.3 ms | 0.24 | 7 / 0 / 4 / 7 / 0 | 1 / 0 / 3 / 2 / 0 |
| zalgebra | edit-zig | 598.2 ms | 39.3 ms | 0.07 | 8 / 0 / 23 / 548 / 8 | 1 / 0 / 10 / 26 / 4 |
| zalgebra | edit-build | 1.22 s | 44.3 ms | 0.04 | 7 / 1132 / 18 / 7 / 0 | 1 / 40 / 5 / 3 / 0 |
| zalgebra | first-nodonor |  | 891.6 ms | 0.49 |  | 1 / 544 / 13 / 267 / 5 |
| zBench | first | 2.78 s | 198.3 ms | 0.07 | 7 / 1196 / 52 / 1467 / 5 | 1 / 56 / 23 / 115 / 4 |
| zBench | noop | 36.6 ms | 8.6 ms | 0.23 | 10 / 0 / 6 / 13 / 0 | 1 / 0 / 4 / 5 / 0 |
| zBench | edit-zig | 585.0 ms | 51.0 ms | 0.09 | 8 / 0 / 23 / 519 / 6 | 1 / 0 / 4 / 50 / 0 |
| zBench | edit-build | 1.19 s | 50.2 ms | 0.04 | 7 / 1152 / 18 / 13 / 0 | 1 / 40 / 6 / 5 / 0 |
| zBench | first-nodonor |  | 1.54 s | 0.55 |  | 1 / 548 / 7 / 611 / 0 |
| zbor | first | 3.19 s | 245.1 ms | 0.08 | 12 / 1216 / 68 / 1370 / 679 | 1 / 43 / 16 / 25 / 147 |
| zbor | noop | 670.6 ms | 167.6 ms | 0.25 | 10 / 0 / 25 / 10 / 653 | 1 / 0 / 13 / 2 / 156 |
| zbor | edit-zig | 1.92 s | 213.9 ms | 0.11 | 13 / 0 / 38 / 1245 / 639 | 1 / 0 / 16 / 35 / 153 |
| zbor | edit-build | 1.95 s | 208.1 ms | 0.11 | 7 / 1134 / 37 / 8 / 651 | 1 / 43 / 15 / 2 / 150 |
| zbor | first-nodonor |  | 1.29 s | 0.40 |  | 1 / 579 / 16 / 470 / 151 |
| zedis | first | 6.22 s | 3.28 s | 0.53 | 10 / 1270 / 61 / 1443 / 3481 | 1 / 125 / 22 / 55 / 3030 |
| zedis | noop | 39.5 ms | 10.0 ms | 0.25 | 7 / 0 / 4 / 19 / 0 | 1 / 0 / 4 / 4 / 0 |
| zedis | edit-zig | 4.91 s | 3.14 s | 0.64 | 7 / 0 / 48 / 1533 / 3778 | 1 / 0 / 20 / 89 / 3084 |
| zedis | edit-build | 1.27 s | 71.2 ms | 0.06 | 10 / 1243 / 21 / 23 / 0 | 1 / 58 / 26 / 3 / 3110 |
| zedis | first-nodonor |  | 4.59 s | 0.74 |  | 2 / 676 / 29 / 746 / 3115 |
| zeit | first | 2.13 s | 397.4 ms | 0.19 | 7 / 1166 / 40 / 738 / 226 | 1 / 61 / 13 / 25 / 309 |
| zeit | noop | 24.8 ms | 5.7 ms | 0.23 | 9 / 0 / 4 / 7 / 0 | 1 / 0 / 3 / 2 / 0 |
| zeit | edit-zig | 1.08 s | 362.6 ms | 0.34 | 10 / 0 / 27 / 717 / 241 | 1 / 0 / 11 / 31 / 315 |
| zeit | edit-build | 1.36 s | 60.7 ms | 0.04 | 7 / 1301 / 19 / 10 / 0 | 0 / 38 / 5 / 2 / 0 |
| zeit | first-nodonor |  | 1.32 s | 0.62 |  | 0 / 537 / 13 / 316 / 307 |
| zf | first | 7.10 s | 438.0 ms | 0.06 | 8 / 1239 / 73 / 4691 / 488 | 1 / 113 / 27 / 52 / 253 |
| zf | noop | 29.4 ms | 13.4 ms | 0.46 | 10 / 0 / 8 / 20 / 0 | 0 / 0 / 6 / 6 / 0 |
| zf | edit-zig | 1.41 s | 70.0 ms | 0.05 | 8 / 0 / 73 / 1404 / 0 | 1 / 0 / 13 / 48 / 0 |
| zf | edit-build | 1.35 s | 67.5 ms | 0.05 | 12 / 1395 / 24 / 16 / 0 | 1 / 64 / 8 / 6 / 0 |
| zf | first-nodonor |  | 1.89 s | 0.27 |  | 1 / 603 / 30 / 899 / 247 |
| zig-args | first | 5.34 s | 98.5 ms | 0.02 | 8 / 1236 / 49 / 4261 / 6 | 1 / 51 / 8 / 22 / 15 |
| zig-args | noop | 42.2 ms | 21.7 ms | 0.51 | 10 / 0 / 8 / 8 / 21 | 0 / 0 / 6 / 3 / 14 |
| zig-args | edit-zig | 4.19 s | 44.2 ms | 0.01 | 7 / 0 / 28 / 3974 / 7 | 1 / 0 / 4 / 28 / 9 |
| zig-args | edit-build | 1.30 s | 64.5 ms | 0.05 | 7 / 1167 / 23 / 10 / 23 | 1 / 39 / 8 / 2 / 13 |
| zig-args | first-nodonor |  | 942.5 ms | 0.18 |  | 1 / 564 / 13 / 362 / 3 |
| zig-clap | first | 3.25 s | 511.6 ms | 0.16 | 7 / 1120 / 42 / 2152 / 0 | 1 / 53 / 14 / 548 / 5 |
| zig-clap | noop | 43.4 ms | 10.2 ms | 0.24 | 7 / 0 / 5 / 28 / 0 | 1 / 0 / 4 / 7 / 0 |
| zig-clap | edit-zig | 2.33 s | 179.1 ms | 0.08 | 11 / 0 / 51 / 2240 / 0 | 1 / 0 / 10 / 114 / 2 |
| zig-clap | edit-build | 1.19 s | 59.4 ms | 0.05 | 8 / 1182 / 23 / 23 / 0 | 1 / 45 / 7 / 6 / 0 |
| zig-clap | first-nodonor |  | 1.67 s | 0.52 |  | 1 / 594 / 12 / 1085 / 0 |
| zig-ecs | first | 3.09 s | 127.5 ms | 0.04 | 7 / 1170 / 42 / 1775 / 0 | 1 / 51 / 13 / 53 / 0 |
| zig-ecs | noop | 80.2 ms | 17.8 ms | 0.22 | 7 / 0 / 5 / 51 / 0 | 1 / 0 / 6 / 7 / 0 |
| zig-ecs | edit-zig | 2.01 s | 110.3 ms | 0.05 | 13 / 0 / 62 / 1908 / 0 | 1 / 0 / 9 / 79 / 0 |
| zig-ecs | edit-build | 1.37 s | 57.3 ms | 0.04 | 7 / 1198 / 38 / 67 / 0 | 1 / 49 / 7 / 10 / 0 |
| zig-ecs | first-nodonor |  | 1.45 s | 0.47 |  | 1 / 848 / 10 / 626 / 0 |
| zig-hpke | first | 4.06 s | 435.2 ms | 0.11 | 7 / 1200 / 47 / 1608 / 1240 | 1 / 53 / 17 / 28 / 324 |
| zig-hpke | noop | 1.30 s | 347.5 ms | 0.27 | 7 / 0 / 28 / 7 / 1256 | 1 / 0 / 13 / 2 / 314 |
| zig-hpke | edit-zig | 2.95 s | 380.5 ms | 0.13 | 8 / 0 / 35 / 1603 / 1295 | 1 / 0 / 13 / 33 / 313 |
| zig-hpke | edit-build | 2.54 s | 394.7 ms | 0.16 | 9 / 1167 / 37 / 8 / 1230 | 1 / 55 / 17 / 3 / 317 |
| zig-hpke | first-nodonor |  | 1.91 s | 0.47 |  | 1 / 592 / 18 / 784 / 314 |
| zig-minisign | first | 2.30 s | 140.8 ms | 0.06 | 8 / 1193 / 41 / 983 / 0 | 1 / 120 / 15 / 31 / 18 |
| zig-minisign | noop | 23.5 ms | 6.1 ms | 0.26 | 11 / 0 / 5 / 8 / 0 | 0 / 0 / 4 / 2 / 0 |
| zig-minisign | edit-zig | 798.4 ms | 40.6 ms | 0.05 | 8 / 0 / 66 / 703 / 0 | 1 / 0 / 10 / 28 / 0 |
| zig-minisign | edit-build | 1.28 s | 56.0 ms | 0.04 | 7 / 1232 / 20 / 7 / 0 | 1 / 44 / 5 / 2 / 0 |
| zig-minisign | first-nodonor |  | 1.08 s | 0.47 |  | 1 / 602 / 9 / 371 / 0 |
| zig-protobuf | first | 12.09 s | 3.55 s | 0.29 | 8 / 1285 / 104 / 9968 / 515 | 1 / 76 / 29 / 3083 / 130 |
| zig-protobuf | noop | 628.7 ms | 231.5 ms | 0.37 | 8 / 0 / 14 / 146 / 470 | 1 / 0 / 17 / 67 / 144 |
| zig-protobuf | edit-zig | 9.73 s | 840.2 ms | 0.09 | 7 / 0 / 56 / 8620 / 596 | 1 / 0 / 24 / 664 / 186 |
| zig-protobuf | edit-build | 1.86 s | 272.9 ms | 0.15 | 7 / 1185 / 36 / 174 / 481 | 1 / 41 / 17 / 70 / 183 |
| zig-protobuf | first-nodonor |  | 5.47 s | 0.45 |  | 1 / 598 / 35 / 4764 / 153 |
| ziggy | first | 6.82 s | 1.06 s | 0.15 | 7 / 1272 / 59 / 5695 / 34 | 1 / 36 / 29 / 707 / 32 |
| ziggy | noop | 105.2 ms | 41.0 ms | 0.39 | 7 / 24 / 21 / 45 / 4 | 1 / 10 / 11 / 12 / 4 |
| ziggy | edit-zig | 1.60 s | 96.4 ms | 0.06 | 9 / 30 / 169 / 1394 / 21 | 1 / 11 / 40 / 48 / 12 |
| ziggy | edit-build | 1.43 s | 86.3 ms | 0.06 | 8 / 1309 / 27 / 50 / 6 | 1 / 62 / 16 / 15 / 8 |
| ziggy | first-nodonor |  | 3.07 s | 0.45 |  | 0 / 952 / 26 / 2512 / 24 |
| zigimg | first | 15.06 s | 730.8 ms | 0.05 | 8 / 1294 / 77 / 11819 / 1444 | 1 / 55 / 13 / 35 / 625 |
| zigimg | noop | 1.44 s | 674.3 ms | 0.47 | 7 / 0 / 5 / 6 / 1446 | 1 / 0 / 4 / 3 / 655 |
| zigimg | edit-zig | 12.91 s | 709.4 ms | 0.05 | 7 / 0 / 134 / 11105 / 1391 | 1 / 0 / 23 / 50 / 637 |
| zigimg | edit-build | 2.60 s | 682.4 ms | 0.26 | 7 / 1137 / 18 / 8 / 1414 | 1 / 45 / 6 / 2 / 687 |
| zigimg | first-nodonor |  | 2.00 s | 0.13 |  | 0 / 588 / 15 / 730 / 653 |
| zio | first | 25.06 s | 17.94 s | 0.72 | 7 / 1273 / 128 / 13526 / 11364 | 1 / 98 / 6 / 6538 / 5853 |
| zio | noop | 12.06 s | 12.23 s | 1.01 | 8 / 0 / 5 / 364 / 10984 | 1 / 0 / 12 / 33 / 12209 |
| zio | edit-zig | 25.63 s | 13.54 s | 0.53 | 7 / 0 / 72 / 16143 / 127 | 1 / 0 / 20 / 827 / 12168 |
| zio | edit-build | 13.14 s | 12.44 s | 0.95 | 8 / 1221 / 19 / 349 / 11946 | 1 / 51 / 6 / 50 / 12531 |
| zio | first-nodonor |  | 20.90 s | 0.83 |  | 1 / 715 / 41 / 7506 / 12465 |
| zli | first | 1.85 s | 128.8 ms | 0.07 | 7 / 1209 / 27 / 629 / 26 | 0 / 53 / 6 / 20 / 17 |
| zli | noop | 46.3 ms | 25.4 ms | 0.55 | 8 / 0 / 5 / 6 / 26 | 1 / 0 / 4 / 2 / 18 |
| zli | edit-zig | 814.7 ms | 44.7 ms | 0.05 | 9 / 0 / 14 / 735 / 26 | 0 / 0 / 4 / 26 / 17 |
| zli | edit-build | 1.31 s | 68.5 ms | 0.05 | 7 / 1234 / 19 / 8 / 27 | 1 / 40 / 6 / 2 / 17 |
| zli | first-nodonor |  | 899.8 ms | 0.49 |  | 1 / 544 / 7 / 294 / 17 |
| zlinter | first | 1.28 s | 103.1 ms | 0.08 | 8 / 1278 / 19 / 0 / 0 | 0 / 117 / 4 / 0 / 0 |
| zlinter | noop | 57.2 ms | 10.6 ms | 0.19 | 8 / 22 / 16 / 0 / 0 | 1 / 7 / 4 / 0 / 0 |
| zlinter | edit-zig | 48.7 ms | 11.4 ms | 0.23 | 8 / 21 / 16 / 0 / 0 | 1 / 8 / 4 / 0 / 0 |
| zlinter | edit-build | 1.34 s | 58.1 ms | 0.04 | 8 / 1347 / 18 / 0 / 0 | 1 / 59 / 4 / 0 / 0 |
| zlinter | first-nodonor |  | 607.5 ms | 0.48 |  | 0 / 581 / 4 / 0 / 0 |
| zls | first | 10.28 s | 2.23 s | 0.22 | 9 / 1299 / 46 / 6527 / 1874 | 1 / 36 / 34 / 111 / 2215 |
| zls | noop | 641.0 ms | 260.5 ms | 0.41 | 8 / 0 / 31 / 24 / 557 | 1 / 0 / 25 / 7 / 233 |
| zls | edit-zig | 6.79 s | 1.99 s | 0.29 | 11 / 0 / 9 / 4689 / 3805 | 1 / 0 / 10 / 129 / 2127 |
| zls | edit-build | 1.90 s | 319.8 ms | 0.17 | 7 / 1356 / 42 / 20 / 542 | 1 / 67 / 26 / 7 / 218 |
| zls | first-nodonor |  | 4.56 s | 0.44 |  | 1 / 704 / 45 / 3580 / 561 |
| zul | first | 11.02 s | 7.23 s | 0.66 | 7 / 1260 / 30 / 2405 / 7158 | 1 / 43 / 6 / 34 / 7118 |
| zul | noop | 7.34 s | 7.12 s | 0.97 | 8 / 0 / 5 / 7 / 7105 | 1 / 0 / 4 / 2 / 7175 |
| zul | edit-zig | 9.61 s | 7.27 s | 0.76 | 11 / 0 / 19 / 2337 / 7062 | 1 / 0 / 5 / 56 / 7191 |
| zul | edit-build | 8.46 s | 7.22 s | 0.85 | 7 / 1256 / 21 / 10 / 7202 | 1 / 50 / 7 / 3 / 7406 |
| zul | first-nodonor |  | 9.20 s | 0.84 |  | 1 / 695 / 8 / 1214 / 7136 |
