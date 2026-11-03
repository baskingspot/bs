# Compile-time benchmarks

`bench/bench.py` times Debug builds of fixed workloads with a chosen compiler
binary (upstream `zig` 0.17.0 or zap) and writes a Markdown report and a JSON
file to `bench/results/`. zap is tracked against the upstream baseline in
[`results/`](results/) at every milestone.

## Baseline: upstream zig 0.17.0 (2026-11-02)

Full report: [`results/2026-11-02-zig-0.17.0.md`](results/2026-11-02-zig-0.17.0.md)
(JSON next to it). Amp orb, 4 vCPU Xeon @ 2.60 GHz, 7.8 GiB, Linux 6.1.
Median wall time over 10 runs (cold: 5 runs for build-exe, 3 for zig build),
peak RSS in parentheses.

| Workload, mode | cold | cold-local | warm | edit root | edit lib | incr. edit root | incr. edit lib |
|---|---:|---:|---:|---:|---:|---:|---:|
| hello, build-exe | 4.24 s (298 MiB) | 350 ms | 352 ms (129 MiB) | 351 ms | 3.61 s¹ | 9.1 ms | 48 ms |
| vaxis, build-exe | 4.74 s (346 MiB) | 988 ms | 861 ms (159 MiB) | 869 ms | 866 ms | 14 ms | 29 ms |
| vaxis, zig build | 87.4 s (908 MiB)² | 5.19 s | 17 ms (39 MiB) | 902 ms | 894 ms | not measured³ | not measured³ |

What the numbers say about upstream:

- **Backend.** 0.17.0 already picks the self-hosted x86_64 backend and its
  own ELF linker for Debug on x86_64-linux (`src/Compilation/Config.zig`,
  `selfHostedBackendIsAsRobustAsLlvm` in `src/target.zig`). A probe
  program built without flags reports `builtin.zig_backend =
  .stage2_x86_64`, so the commands pass no backend flags. libvaxis's own
  `build.zig` forces LLVM by default (`-Dllvm`, default true); the
  `zig build` reference avoids it through the wrapper.
- **`zig build-exe` caches nothing of the Zig compilation.** Without
  `--listen` the CLI uses cache mode `none` (`src/main.zig`), so warm and
  edited rebuilds are full compiles; only per-file ZIR (local cache) and
  compiler_rt (global cache) are reused. This is the number zap's
  per-declaration cache should beat by the most.
- **Cold build-exe is mostly compiler_rt**, the only thing in the global
  cache: cold minus cold-local is 3.9 s of hello's 4.24 s.
- ¹ **Editing std rebuilds compiler_rt.** compiler_rt is cached on the
  contents of the std files it imports, so the hello library edit (in
  `std/debug.zig`) costs a compiler_rt rebuild, 3.6 s instead of 0.35 s.
  The in-process incremental session does not rebuild it (48 ms).
- **`-fincremental` only helps with a live compiler.** 0.17.0 writes the
  incremental state (`<name>.zcs`) but never loads it, so separate
  processes gain nothing and pay 0.1–0.3 s more per build. `zig build
  -fincremental` without `--watch` recompiles every step on every run,
  even with no change: 4.1–4.2 s against 17 ms warm for vaxis, because it
  also rebuilds uucode's table generator with LLVM. Kept alive over
  `--listen=-`, the compiler applies the same edits in 9–48 ms.
- ² **Cold `zig build` is mostly the build runner.** zig compiles its
  build runner (`lib/compiler/Maker.zig`) in ReleaseSafe with LLVM, once per
  global cache. `zig build -h` from an empty global cache, which builds
  only the runner and `build.zig`, takes 75 s of the 87 s, and the runner
  compile is the 908 MiB peak.
- ³ **`zig build --watch` panics on this kernel** right after the first
  build: `lib/compiler/Maker/Watch.zig` calls `name_to_handle_at` with
  `AT_HANDLE_FID` (Linux 6.5+), Linux 6.1 returns EINVAL, and std.posix
  treats that as unreachable. The build-exe incremental rows use the same
  compiler protocol `--watch` drives, so they stand in for it.
- **The orb's speed drifts.** In the first half hour of this orb the same
  commands took 1.6–1.7× as long (vaxis warm 1.47 s, cold `zig build`
  140 s), with CPU time up in proportion, so the machine was slower,
  not the work bigger. The calibration loop in each report (104 ms before,
  88 ms after for the baseline) shows such drift. Compare zap and zig from
  runs in the same session, not against an old report.

## `zap build` against `zig build` (2026-11-03)

Reports: [`results/2026-11-03-zap-build-zap.md`](results/2026-11-03-zap-build-zap.md)
and [`results/2026-11-03-zap-build-zig-0.17.0.md`](results/2026-11-03-zap-build-zig-0.17.0.md),
run back to back on the same orb (calibration 126–129 ms, so about 1.3x
slower than the baseline's orb: upstream's cold build took 104 s here
against 87 s there). vaxis `zig-build` mode, the wrapper project, zap
ReleaseFast. Median wall time, peak RSS in parentheses.

| | cold | cold-local | warm (no edit) | edit root | edit lib |
|---|---:|---:|---:|---:|---:|
| `zig build` | 103.7 s (908 MiB) | 6.51 s (304 MiB) | 24 ms (39 MiB) | 1.19 s | 1.20 s |
| `zap build` | 5.14 s (314 MiB) | 2.37 s (138 MiB) | 38 ms (18 MiB) | 144 ms | 139 ms |

- **cold** includes compiling the build runner (`lib/compiler/Maker.zig`),
  a one-time cost per global cache (upstream, ReleaseSafe with LLVM, about
  75 s at the baseline's speed) or per zap binary (zap, Debug, about 3 s).
  It is not a per-build cost. **cold-local** is the per-project first
  build: runner cached, empty local cache.
- **warm is slower with zap: 38 ms against 24 ms.** zap's own check
  that the runner is current costs about 3 ms; the rest is the runner
  itself, which zap builds in Debug (safety checks, little optimization)
  where upstream builds it in ReleaseSafe with LLVM. Its configure phase
  and step graph walk take about twice as long. The compile steps
  themselves are cache hits in about 2–3 ms.
- **The build.zig compile** (the configurer step, `build-exe ... --name
  configurer -fsingle-threaded --dep @build --dep @dependencies
  -Mroot=<lib>/compiler/configurer.zig`), served over `--listen=-` by each
  compiler from the runner's exact command line, one process per run,
  global cache warm, 10 runs:

  | project | compiler | first compile | no change | one-line edit to build.zig |
  |---|---|---:|---:|---:|
  | libvaxis | zig | 1198 ms | 6.7 ms | 1226 ms |
  | libvaxis | zap | 691 ms | 1.7 ms | 213 ms |
  | zap repo | zig | 1202 ms | 5.4 ms | 1185 ms |
  | zap repo | zap | 682 ms | 1.5 ms | 186 ms |

  The edit appends a statement to the `pub fn build` line. This is the
  compile every `zig build` pays when its build script changed.

## Running

```sh
# Upstream baseline: every mode and scenario (about 15 minutes on a 4 vCPU orb).
python3 bench/bench.py --machine-note "Amp orb, 4 vCPU"

# zap, built with -Doptimize=ReleaseFast (a Debug build of zap is ~10x slower).
zig build -Doptimize=ReleaseFast
python3 bench/bench.py --compiler zig-out/bin/zap --machine-note "Amp orb, 4 vCPU"
```

Useful options: `--workloads hello,vaxis,zig`, `--modes build-exe,zig-build`,
`--scenarios core` or a comma-separated list, `--runs`, `--cold-runs`,
`--build-cold-runs`, `--out PATH` (without extension). Both modes run by
default; with zap, `zig-build` times `zap build`, which compiles and runs
upstream's build runner with zap as the compiler. With a compiler other
than upstream zig the default scenarios are the core ones (cold,
cold-local, warm, edit-root, edit-lib).

### Profiling with valgrind

```sh
zig build -Doptimize=ReleaseFast -Dcpu=x86_64_v3 -p /tmp/zapvg
ZAP_CACHE=off valgrind --tool=callgrind --aspace-minaddr=0x100000000 \
    /tmp/zapvg/bin/zap test upstream/test/behavior/x86_64/binary.zig --test-no-exec
```

- `-Dcpu=x86_64_v3`: valgrind 3.19 does not decode AVX-512, which a native
  build of zap uses (SIGILL in `memset` at startup).
- `--aspace-minaddr=0x100000000`: valgrind places mappings bottom-up from
  about 0x4800000, and std's `PageAllocator` hints each new mapping just
  below the previous one, without checking for wraparound. Once one
  allocation is larger than the address of the last mapping (Emit's arena
  reaches 127 MB on binary.zig), the hint wraps past zero, valgrind rejects
  the mmap with EINVAL where Linux ignores a bad hint, and zap fails with
  `error.OutOfMemory`. Starting mappings at 4 GiB keeps the hint in range.
- Valgrind computes x87 `f80` arithmetic in 64-bit precision, and zap folds
  comptime `f80` math in the host's `f80`, so files with comptime `f80`
  math analyze differently under valgrind. binary.zig makes about 4% fewer
  instantiations of its generic `binary` function (110,860 instead of
  115,414) and emits a different binary. The counts are still useful for
  comparing changes, but they don't describe exactly the native workload.

The harness needs Python 3, git, network access on first use (to clone
libvaxis and fetch its dependencies) and upstream zig 0.17.0 on `PATH`
(`--setup-zig`), which prepares the workloads but is never timed. Scratch
files live in `bench/.work/` (gitignored); delete it to start over.

## Workloads

- **hello**: [`workloads/hello/hello.zig`](workloads/hello/hello.zig), hello
  world through `std.debug.print`. It builds against a private copy of std
  (`--zig-lib-dir`) so the library edit can touch `std/debug.zig`.
- **vaxis**: the `text_input` example of
  [libvaxis](https://github.com/rockorager/libvaxis) at commit
  `0620b34e091d` (main as of 2026-10-31, unpatched; it requires zig 0.17.0),
  with its pinned dependencies zigimg and uucode. The timed command is a
  plain `zig build-exe` with `-M`/`--dep` flags, the same module graph
  libvaxis's `build.zig` produces. uucode generates `tables.zig` (7 MB) at
  build time; setup runs libvaxis's build once and keeps the generated
  modules in `.work/vaxis/gen/`, so the command needs no build system.
- **zig**: upstream zig 0.17.0's own compiler (`upstream/src/main.zig`, a
  copy of `.agents/setup`'s source tree) without LLVM: the build-exe
  command `zig build -Denable-llvm=false -Dversion-string=0.17.0 --verbose`
  runs, with its generated build options module checked in as
  [`workloads/zig/build_options.zig`](workloads/zig/build_options.zig).
  The output check runs `zig version`. Both edits are in the root module
  (`src/main.zig`, `src/Sema.zig`), which is the compiler's only module
  besides std.

The `zig-build` mode builds the same example through
[`workloads/vaxis-build/`](workloads/vaxis-build/), a wrapper project that
depends on the checkout by path. libvaxis's own `build.zig` is not used
directly because it forces the LLVM backend unless `-Dllvm=false` and its
install step also compiles the library's test binary.

The exact commands are recorded in each report.

## Scenarios

| Scenario | What is timed |
|---|---|
| `cold` | build with empty local and global caches |
| `cold-local` | build with an empty local cache and a warm global cache |
| `warm` | rebuild with no change |
| `edit-root` | rebuild after a one-line edit to a function body in the root file |
| `edit-lib` | the same in a library file (`std/debug.zig` for hello, `src/Vaxis.zig` for vaxis, `src/Sema.zig` for zig) |
| `incr-cli-edit-*` | the edits with `-fincremental` added, one compiler process per build |
| `incr-edit-*` | the edits as in-process incremental updates: `-fincremental --listen=-`, compiler kept alive |

An edit appends ` std.mem.doNotOptimizeAway(@as(u32, N));` to one statement
line, with a new N for every build. The line count stays the same, so only
that function body changes, and no edit can hit a cache entry from an earlier
one. After every edit the harness checks that the output binary changed; it
runs hello after every build.

Each build is a fresh process. Wall time is reported as the median with
min–max and standard deviation; CPU is user+sys of the process tree; peak RSS
is the largest single process in the tree, from `wait4`. In-process
incremental rows time each update from the protocol message to the end of the
compiler's reply, and their RSS and CPU cover the whole session.

## Run-time benchmarks

`bench/runtime.py` times the code zap generates. It builds each program in
[`runtime/`](runtime/) with zap and with upstream zig 0.17.0 in Debug
(self-hosted x86_64 backend) and ReleaseSafe (LLVM), checks that the three
binaries print the same output, and reports the median wall time of each.
Every program reads its problem size from an exported variable, so no
compiler folds the work away.

| Program | What it exercises |
|---|---|
| fib | recursive calls: argument passing, call overhead |
| sieve | tight loops over a byte array with bounds checks |
| sort | `std.mem.sort` and `std.mem.sortUnstable` on u32s: generic std code, comparator calls |
| hash | `std.AutoHashMap(u64, u64)`: hashing, probing, growth, lookups |
| nbody | f64 arithmetic on small structs passed by value |
| fmt | `std.Io.Writer.print` into a buffer: formatting, interface calls |

```sh
zig build -Doptimize=ReleaseFast
python3 bench/runtime.py --compiler zig-out/bin/zap --machine-note "Amp orb, 4 vCPU"
```

Options: `--programs fib,sort`, `--runs`, `--no-upstream` (zap only),
`--zig PATH`, `--out PATH` (without extension). Baseline before the
optimizing backend: [`results/2026-11-03-runtime-zap-8fe40fe.md`](results/2026-11-03-runtime-zap-8fe40fe.md).
