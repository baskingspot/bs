# Compile-time benchmark: 0.17.0

Generated 2026-11-03T18:22:22+00:00 by `bench/bench.py` (zap 3795f8a).

## Machine and compiler

- Machine: Amp orb, 4 vCPU Intel(R) Xeon(R) Processor @ 2.60GHz, 4 logical CPUs, 7.8 GiB RAM, Linux 6.1.158+ x86_64
- Compiler: `/home/user/workspace/repo/zig-out/bin/zap`, version `0.17.0`
- Default Debug build (no backend flags) reports `builtin.zig_backend = .stage2_x86_64`, mode `debug`, object format `elf`
- CPU calibration (fixed pure-Python loop, best of 5, lower is faster): 129 ms before the benchmarks, 126 ms after
- Runs: 10 per scenario, 5 for cold build-exe, 3 for cold zig build

Wall time is the median over the runs with min–max and sample standard deviation. CPU is user+sys of the whole process tree. Peak RSS is the largest single process in the tree (median over runs). For in-process incremental rows, time is per update and RSS/CPU cover the whole compiler session, including its initial full build.

## vaxis: libvaxis 0620b34e091d examples/text_input.zig

| Mode | Scenario | Runs | Median | Min–max | Stdev | CPU | Peak RSS |
|---|---|---:|---:|---:|---:|---:|---:|
| zig-build | cold | 3 | **5.14 s** | 5.05 s–5.14 s | 50 ms | 6.14 s | 314 MiB |
| zig-build | cold-local | 10 | **2.37 s** | 2.31 s–2.46 s | 45 ms | 2.58 s | 138 MiB |
| zig-build | warm | 10 | **38 ms** | 37 ms–39 ms | 0.6 ms | 39 ms | 18 MiB |
| zig-build | edit-root | 10 | **144 ms** | 131 ms–178 ms | 14 ms | 164 ms | 69 MiB |
| zig-build | edit-lib | 10 | **139 ms** | 136 ms–145 ms | 2.3 ms | 159 ms | 70 MiB |

Commands (run from the working directory shown, relative to the harness work dir):

- zig-build, in `vaxis/wrapper`:

  ```sh
  ZIG_GLOBAL_CACHE_DIR=../build-cache/global zap build --cache-dir ../build-cache/local
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
