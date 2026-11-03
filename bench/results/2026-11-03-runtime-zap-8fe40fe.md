# Run-time benchmarks

Median wall time of 5 runs; zap 8fe40fe (ReleaseFast) against upstream zig 0.17.0. Amp orb, 4 vCPU Xeon @ 2.60 GHz, 4 CPUs.

| Program | zap | Debug | ReleaseSafe | zap / Debug | zap / ReleaseSafe |
|---|---:|---:|---:|---:|---:|
| fib | 188 ms | 154 ms | 72 ms | 1.22× | 2.6× |
| sieve | 497 ms | 417 ms | 117 ms | 1.19× | 4.2× |
| sort | 613 ms | 480 ms | 82 ms | 1.28× | 7.5× |
| hash | 384 ms | 463 ms | 39 ms | 0.83× | 9.9× |
| nbody | 418 ms | 442 ms | 19 ms | 0.94× | 21.6× |
| fmt | 205 ms | 160 ms | 17 ms | 1.28× | 12.1× |
