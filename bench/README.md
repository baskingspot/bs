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

## Running

```sh
# Upstream baseline: every mode and scenario (about 15 minutes on a 4 vCPU orb).
python3 bench/bench.py --machine-note "Amp orb, 4 vCPU"

# zap, built with -Doptimize=ReleaseFast (a Debug build of zap is ~10x slower).
zig build -Doptimize=ReleaseFast
python3 bench/bench.py --compiler zig-out/bin/zap --machine-note "Amp orb, 4 vCPU"
```

Useful options: `--workloads hello,vaxis`, `--modes build-exe,zig-build`,
`--scenarios core` or a comma-separated list, `--runs`, `--cold-runs`,
`--build-cold-runs`, `--out PATH` (without extension). With a compiler other
than upstream zig the defaults are the `build-exe` mode and the core
scenarios (cold, cold-local, warm, edit-root, edit-lib).

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
| `edit-lib` | the same in a library file (`std/debug.zig` for hello, `src/Vaxis.zig` for vaxis) |
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
