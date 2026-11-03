# Compile-time benchmark: 0.17.0

Generated 2026-11-03T18:15:29+00:00 by `bench/bench.py` (zap 3795f8a).

## Machine and compiler

- Machine: Amp orb, 4 vCPU Intel(R) Xeon(R) Processor @ 2.60GHz, 4 logical CPUs, 7.8 GiB RAM, Linux 6.1.158+ x86_64
- Compiler: `/home/user/.cache/zap/zig-0.17.0/zig`, version `0.17.0`
- Default Debug build (no backend flags) reports `builtin.zig_backend = .stage2_x86_64`, mode `debug`, object format `elf`
- CPU calibration (fixed pure-Python loop, best of 5, lower is faster): 128 ms before the benchmarks, 126 ms after
- Runs: 10 per scenario, 5 for cold build-exe, 3 for cold zig build

Wall time is the median over the runs with min–max and sample standard deviation. CPU is user+sys of the whole process tree. Peak RSS is the largest single process in the tree (median over runs). For in-process incremental rows, time is per update and RSS/CPU cover the whole compiler session, including its initial full build.

## vaxis: libvaxis 0620b34e091d examples/text_input.zig

| Mode | Scenario | Runs | Median | Min–max | Stdev | CPU | Peak RSS |
|---|---|---:|---:|---:|---:|---:|---:|
| zig-build | cold | 3 | **103.73 s** | 102.70 s–105.58 s | 1.46 s | 105.21 s | 908 MiB |
| zig-build | cold-local | 10 | **6.51 s** | 6.38 s–6.74 s | 120 ms | 8.25 s | 304 MiB |
| zig-build | warm | 10 | **24 ms** | 22 ms–35 ms | 3.9 ms | 24 ms | 39 MiB |
| zig-build | edit-root | 10 | **1.19 s** | 1.12 s–1.26 s | 47 ms | 1.82 s | 159 MiB |
| zig-build | edit-lib | 10 | **1.20 s** | 1.13 s–1.25 s | 31 ms | 1.91 s | 160 MiB |

Commands (run from the working directory shown, relative to the harness work dir):

- zig-build, in `vaxis/wrapper`:

  ```sh
  ZIG_GLOBAL_CACHE_DIR=../build-cache/global zig build --cache-dir ../build-cache/local
  ```

Edits (the anchor line gets ` std.mem.doNotOptimizeAway(@as(u32, N));` appended, with a new N for every build):

- root: `vaxis/libvaxis/examples/text_input.zig` line 23: `const alloc = init.gpa;`
- lib: `vaxis/libvaxis/src/Vaxis.zig` line 407: `var started: bool = false;`

## Scenarios

- `cold`: empty local and global caches
- `cold-local`: empty local cache, warm global cache (compiler_rt, build runner)
- `warm`: rebuild, no change
- `edit-root`: rebuild after a one-line edit to a function body in the root file
- `edit-lib`: rebuild after a one-line edit to a function body in a library file
- `incr-cli-edit-root`: edit-root with -fincremental, one compiler process per build
- `incr-cli-edit-lib`: edit-lib with -fincremental, one compiler process per build
- `incr-edit-root`: edit-root, in-process incremental update (-fincremental, compiler kept alive)
- `incr-edit-lib`: edit-lib, in-process incremental update (-fincremental, compiler kept alive)

In-process incremental rows append `-fincremental --listen=-` to the build-exe command and send compiler-protocol `update` messages, as `zig build --watch` does; `incr-cli-*` rows append `-fincremental` only.
