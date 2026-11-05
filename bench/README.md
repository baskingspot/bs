# Compile-time benchmarks

`bench/bench.py` times Debug builds of fixed workloads with a chosen compiler
binary (upstream `zig` 0.17.0 or bs) and writes a Markdown report and a JSON
file to `bench/results/`. bs is tracked against the upstream baseline in
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
  compiler_rt (global cache) are reused. This is the number bs's
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
  88 ms after for the baseline) shows such drift. Compare bs and zig from
  runs in the same session, not against an old report.

## `bs build` against `zig build` (2026-11-03)

Reports: [`results/2026-11-03-bs-build-bs.md`](results/2026-11-03-bs-build-bs.md)
and [`results/2026-11-03-bs-build-zig-0.17.0.md`](results/2026-11-03-bs-build-zig-0.17.0.md),
run back to back on the same orb (calibration 126–129 ms, so about 1.3x
slower than the baseline's orb: upstream's cold build took 104 s here
against 87 s there). vaxis `zig-build` mode, the wrapper project, bs
ReleaseFast. Median wall time, peak RSS in parentheses.

| | cold | cold-local | warm (no edit) | edit root | edit lib |
|---|---:|---:|---:|---:|---:|
| `zig build` | 103.7 s (908 MiB) | 6.51 s (304 MiB) | 24 ms (39 MiB) | 1.19 s | 1.20 s |
| `bs build` | 5.14 s (314 MiB) | 2.37 s (138 MiB) | 38 ms (18 MiB) | 144 ms | 139 ms |

- **cold** includes compiling the build runner (`lib/compiler/Maker.zig`),
  a one-time cost per global cache (upstream, ReleaseSafe with LLVM, about
  75 s at the baseline's speed) or per bs binary (bs, Debug, about 3 s).
  It is not a per-build cost. **cold-local** is the per-project first
  build: runner cached, empty local cache.
- **warm is slower with bs: 38 ms against 24 ms.** bs's own check
  that the runner is current costs about 3 ms; the rest is the runner
  itself, which bs builds in Debug (safety checks, little optimization)
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
  | libvaxis | bs | 691 ms | 1.7 ms | 213 ms |
  | bs repo | zig | 1202 ms | 5.4 ms | 1185 ms |
  | bs repo | bs | 682 ms | 1.5 ms | 186 ms |

  The edit appends a statement to the `pub fn build` line. This is the
  compile every `zig build` pays when its build script changed.

## Scoreboard: one command

`bench/scoreboard.py` runs everything the roadmap's scoreboard quotes in one
session and writes `results/<date>-scoreboard.md` and `.json`: bench.py on
hello, vaxis, zig and std (upstream Debug, bs, and bs without donors,
workload by workload), the corpus harness over every target (build only,
three samples, bs's cold-local without and with donors), runtime.py and
realworld.py. About an hour on a 4 vCPU orb.

```sh
zig build -Doptimize=ReleaseFast -p /tmp/bs-rf
python3 bench/scoreboard.py --bs /tmp/bs-rf/bin/bs --note "Amp orb, 4 vCPU"
```

`--parts bench,corpus,runtime` runs a subset; `--from-json PATH` renders the
report again from a run's JSON. The JSON is saved after each part, and
`--resume` continues an interrupted run with the parts still missing. After a change to donor builds lands, measure
the donor-on rows again with the new bs (each workload's cold-local next to
upstream's, and the corpus's bs columns) and add them to the same report:

```sh
python3 bench/scoreboard.py --from-json bench/results/<date>-scoreboard.json \
    --bs /tmp/bs-new/bin/bs --bs-commit <sha> --add-donors "Lazy donor builds landed."
```

`--findings FILE` ends the report with a hand-written Markdown section.

## `bs build` per scenario and phase (2026-11-04)

Report: [`results/2026-11-04-build-phases.md`](results/2026-11-04-build-phases.md)
(JSON next to it), from `bench/build_phases.py`: libvaxis (the wrapper
above), zf, ziggy, tls.zig, zls, monstar (C and C++) and bs's own
repository; each project's global cache warm. Median wall time, upstream
zig 0.17.0 against bs before (13942f5) and after the bs-build-speed
branch:

| | first | no change | edit a .zig | edit build.zig |
|---|---:|---:|---:|---:|
| vaxis | 6.78 s / 1.10 s / 0.94 s | 29.7 / 34.3 / 9.3 ms | 1.19 s / 83 / 63 ms | 1.28 s / 115 / 61 ms |
| ziggy | 3.81 s / 1.03 s / 0.85 s | 60.6 / 82.6 / 22.4 ms | 1.52 s / 140 / 73 ms | 1.36 s / 130 / 75 ms |
| tls.zig | 9.94 s / 1.37 s / 1.18 s | 40.4 / 50.1 / 13.2 ms | 10.1 s / 274 / 202 ms | 1.22 s / 146 / 70 ms |
| zls | 5.43 s / 1.77 s / 1.35 s | 26.7 / 33.4 / 10.8 ms | 3.06 s / 158 / 107 ms | 1.37 s / 154 / 80 ms |
| monstar | 58.3 s / 16.0 s / 12.4 s | 179 / 689 / 158 ms | 31.5 s / 826 / 300 ms | 2.01 s / 722 / 210 ms |
| bs | 17.9 s / 13.5 s / 12.6 s | 82.8 / 89.7 / 40.1 ms | 5.85 s / 288 / 228 ms | 1.40 s / 144 / 89 ms |

- **Before, a no-change build lost to upstream** on every project but zf
  (vaxis 34 ms against 30, monstar 689 against 179): the runner, which
  bs built in Debug, spent most of its time capturing a DWARF-unwound
  stack trace for every allocation, as Debug's `SafeAllocator` does. bs
  now builds the runner in ReleaseSafe, as upstream does.
- **Projects whose build script cannot be cached** (ziggy runs `git
  describe`, monstar pkg-config, bs's own build.zig a process) rehash
  every input of the configure script on every build; 700 of the 720 are
  std and std.Build files of bs's pinned lib directory, which bs no
  longer reports to the runner (docs/slop/architecture.md, "Inputs under bs's
  own lib directory"). The runner's phase on ziggy went 58 → 8 ms.
- What is left of the runner phase (5–6 ms on a small project, upstream's
  5–6 ms) is the runner's code, which bs compiles with its own code
  generation: std's SipHash runs 4.7x, Wyhash 3.2x and
  `mem.splitScalar` (bool-vector `simd.firstTrue`, scalarized) 10x slower
  than upstream's ReleaseSafe build on a 64 MiB microbenchmark.
- Startup is 0.5 ms against upstream's 7–8 ms (bs's check that the
  runner is current against upstream's runner compilation's cache check),
  and a cached compile step answers in about 2 ms against upstream's 7.

Over the corpus (`--projects corpus`, every git project in
tools/corpus/manifest.json; results/2026-11-04-corpus-phases-0.17.1.md),
bs's geomean against upstream 0.17.1 is 0.10 for a first build, 0.35 for
no change, 0.11 for a Zig edit and 0.08 for a build.zig edit, over 29
projects; bs is slower only on zio's no-change build, whose tests run on
every build and run 12.2 s against 11.0 s (0.17.0:
results/2026-11-04-corpus-phases.md). Two kinds of step had made bs lose:
`-fno-emit-bin` check steps (superhtml's recompiled for 1.2 s on every
build), which now link a hidden output the cache can answer from, and
`-fPIC` steps (libxev's libraries, 214 ms of a 249 ms no-change build),
which the cache does not take and which an inputs record now skips when
nothing changed.

### No-change builds after the nochange-speed branch

A no-change `build` (default step) of libvaxis's wrapper and of zls, each
compiler's global and local caches warm, median of 20 interleaved runs
(ms), and the phases of 10 runs recorded with perf's scheduler events:
upstream zig 0.17.1 / bs before (729ad25) / bs after.

| | total | startup | runner until its first step | compile steps | runner, rest |
|---|---:|---:|---:|---:|---:|
| vaxis (2 steps) | 23.7 / 10.3 / 7.6 | 7.4 / 0.6 / 0.5 | 4.2 / 3.8 / 3.5 | 12.5 / 4.2 / 2.0 | 1.1 / 1.3 / 1.2 |
| zls (3 steps) | 25.1 / 11.4 / 7.6 | 7.4 / 0.6 / 0.5 | 4.8 / 4.5 / 4.0 | 14.4 / 4.3 / 1.9 | 1.2 / 1.6 / 1.4 |

- **A cached compile step takes 0.8–1.0 ms** from exec to exit, against
  about 2 before and upstream's 6–7, close to the cost of starting a
  process on this orb. It no longer stats the ~700 inputs of bs's pinned
  lib directory (43% of its time; docs/slop/architecture.md, "No-edit
  builds"), and a ReleaseFast bs no longer maps and zeroes std's 256 KiB
  per-thread signal stack, which only a segfault handler uses (0.3 ms
  and a quarter of the step's page faults).
- **The runner's stack probes write** (codegen/x86_64/Encoder.zig): a
  probe that read an untouched page mapped the zero page, and the first
  write then copied it and flushed every CPU's TLB, for each page of
  each Fetch worker's 64 KiB buffer.
- What is left is mostly upstream's runner: forking a multithreaded
  process for each step, and before its first step about 4 ms, 40% of
  whose CPU time is page faults (its threads' signal stacks, a 20 MB
  binary's code, fresh heap). bs's code generation still costs it some:
  a store of a packed struct literal is one read-modify-write per field,
  so SafeAllocator's footers read fresh pages before writing them, and
  std's hashes run slower than upstream's (above).

## `bs build --watch` against `zig build --watch` (2026-11-04)

`bench/watch.py` starts `<compiler> build --watch --summary new` on a
project with the compiler's global cache warm and the project's local
cache empty, and times the first build, then 7 one-line Zig edits and 7
build.zig edits (build_phases.py's edits, a new value each time): from the
save to the installed artifact changing, and to the build's summary. Each
edit waits for the previous build's summary plus `--settle` seconds, and
the harness reports extra rebuilds (a build no edit asked for), unchanged
artifacts, and whether a build.zig edit that installs a new file is
applied. Projects and checkouts are build_phases.py's (vaxis, zls and
monstar). monstar links the system's Wayland (1.25), wayland-protocols
(1.49), fontconfig, freetype, harfbuzz and xkbcommon; `.agents/setup`
shows how orbs install them.

It needs Linux 6.5 or later: upstream's runner (`Maker/Watch.zig`) calls
`name_to_handle_at` with `AT_HANDLE_FID` and panics on older kernels,
under `zig build --watch` and `bs build --watch` alike (Linux 6.1 on the
orbs). On such a machine, from this repository with upstream zig on PATH
(`.agents/setup`):

```sh
zig build -Doptimize=ReleaseFast
python3 bench/watch.py --bs zig-out/bin/bs
python3 bench/watch.py --bs zig-out/bin/bs --extra=-fincremental   # upstream's incremental compilation
python3 bench/watch.py --bs zig-out/bin/bs --extra='--debounce 0'  # without the runner's 50 ms debounce
python3 bench/watch.py --bs zig-out/bin/bs --projects zls --bp-steps  # zls's install and test steps
```

Each run prints the medians per compiler and project and writes
`bench/.work/watch_bench/results-<tag>.json`, with every build's log
next to it.

`--protocol` measures on any kernel what a watch rebuild asks of the
compiler alone: the artifact's compile step runs once with `--listen=-`
and answers an `update` per Zig edit, as it does under `--watch`, without
change detection, the debounce, run steps or the install:

```sh
python3 bench/watch.py --bs zig-out/bin/bs --protocol
python3 bench/watch.py --bs zig-out/bin/bs --protocol --extra=-fincremental
```

timbot (Linux 7.2, 12 cores), upstream 0.17.0 against bs-build-watch
5d93d33, default debounce, median of 7 (ms unless marked):

| project | first build, zig / bs | .zig edit to artifact | build.zig edit to summary |
|---|---:|---:|---:|
| vaxis | 3.84 s / 0.28 s | 787 / 90 | 839 / 99 |
| zls | 3.35 s / 0.17 s | 1868 / 114 | 864 / 108 |
| monstar | 28.6 s / 7.08 s | 18.29 s / 167 | not seen by either |

With `-fincremental`, upstream's .zig edits take vaxis 84 / bs 86, zls 90
/ 108 and monstar 8.27 s / 162; its build.zig edits then take 3.2–4.1 s
(the runner restarts after reconfiguring) against about 0.1 s for bs.
With `--debounce 0`, bs's vaxis edit is 39 ms.

That bs build still ran each run step that executes a rebuilt artifact
a second time after every edit (zls's 25 `run analysis` steps, 220 ms
later): it relinked outputs in place in their one directory, which the
runner watches for those steps, so it saw the build's own write as a
change. Now a build that changes the output writes it into the other of
the compilation's two output directories (`serve` in src/main.zig), as
upstream's outputs move to a new digest's directory.

monstar's build.zig edits are missed by upstream's runner, for zig and
bs alike: monstar's configuration runs pkg-config, which poisons it, and
Maker.zig records `configure_source_files` only on a configuration cache
hit or an unpoisoned miss (`options.src_files`, lines 1502 and 1642 in
0.17.1), so the reconfigure step watches nothing. The runner stays unpatched.

## Running

```sh
# Upstream baseline: every mode and scenario (about 15 minutes on a 4 vCPU orb).
python3 bench/bench.py --machine-note "Amp orb, 4 vCPU"

# bs, built with -Doptimize=ReleaseFast (a Debug build of bs is ~10x slower).
zig build -Doptimize=ReleaseFast
python3 bench/bench.py --compiler zig-out/bin/bs --machine-note "Amp orb, 4 vCPU"
```

Useful options: `--workloads hello,vaxis,zig,std`, `--modes build-exe,zig-build`,

`bench/build_phases.py` times `zig build`/`bs build` (`--bs PATH`) of
real projects per scenario and splits each into phases with `perf`
(needs `perf` and `kernel.perf_event_paranoid=-1`; see its docstring).

Useful options: `--workloads hello,vaxis,zig`, `--modes build-exe,zig-build`,
`--scenarios core` or a comma-separated list, `--runs`, `--cold-runs`,
`--build-cold-runs`, `--env KEY=VALUE` (for every timed build, such as
`BS_CACHE_DONOR=off`), `--out PATH` (without extension). Both modes run by
default; with bs, `zig-build` times `bs build`, which compiles and runs
upstream's build runner with bs as the compiler. With a compiler other
than upstream zig the default scenarios are the core ones (cold,
cold-local, warm, edit-root, edit-lib).

### Profiling with valgrind

```sh
zig build -Doptimize=ReleaseFast -Dcpu=x86_64_v3 -p /tmp/bsvg
BS_CACHE=off valgrind --tool=callgrind --aspace-minaddr=0x100000000 \
    /tmp/bsvg/bin/bs test upstream/test/behavior/x86_64/binary.zig --test-no-exec
```

- `-Dcpu=x86_64_v3`: valgrind 3.19 does not decode AVX-512, which a native
  build of bs uses (SIGILL in `memset` at startup).
- `--aspace-minaddr=0x100000000`: valgrind places mappings bottom-up from
  about 0x4800000, and std's `PageAllocator` hints each new mapping just
  below the previous one, without checking for wraparound. Once one
  allocation is larger than the address of the last mapping (Emit's arena
  reaches 127 MB on binary.zig), the hint wraps past zero, valgrind rejects
  the mmap with EINVAL where Linux ignores a bad hint, and bs fails with
  `error.OutOfMemory`. Starting mappings at 4 GiB keeps the hint in range.
- Valgrind computes x87 `f80` arithmetic in 64-bit precision, and bs folds
  comptime `f80` math in the host's `f80`, so files with comptime `f80`
  math analyze differently under valgrind. binary.zig makes about 4% fewer
  instantiations of its generic `binary` function (110,860 instead of
  115,414) and emits a different binary. The counts are still useful for
  comparing changes, but they don't describe exactly the native workload.

To profile a program bs compiled, rather than bs itself, build it with
`-fno-valgrind`. bs enables valgrind support by default, as upstream
Debug does, so `std.debug.inValgrind()` is true under callgrind, and std
takes its valgrind paths: `std.mem.indexOfScalarPos` and `splitScalar`
skip their vector loops (zig issue 17717) and become byte loops, which
made bs's `splitScalar` look 35x slower than upstream ReleaseSafe (whose
default is off) instead of 3.7x. Native wall times are unaffected:
outside valgrind the check is false.

```sh
zig-out/bin/bs build-exe -fno-valgrind prog.zig -femit-bin=/tmp/prog
valgrind --tool=callgrind --callgrind-out-file=/tmp/cg.out /tmp/prog
callgrind_annotate --auto=yes /tmp/cg.out
```

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

- **std**: std's own tests, `zig test zig-lib/std/std.zig --test-no-exec`
  against a private copy of the source tree's lib (`upstream/lib`, which
  has the test data std's tests embed). std.zig has no function body, so
  the root edit is a test in `std/mem.zig`; the library edit is hello's,
  in `std/debug.zig`. build-exe mode only.

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

`bench/runtime.py` times the code bs generates. It builds each program in
[`runtime/`](runtime/) with bs and with upstream zig 0.17.0 in Debug
(self-hosted x86_64 backend) and ReleaseSafe (LLVM), checks that the three
binaries print the same output, and reports the median wall time of each.
Every program reads its problem size from an exported variable, so no
compiler folds the work away.
The timings are native, where valgrind support costs nothing; to profile
one of these programs under callgrind, build it with `-fno-valgrind`
("Profiling with valgrind").

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
python3 bench/runtime.py --compiler zig-out/bin/bs --machine-note "Amp orb, 4 vCPU"
```

Options: `--programs fib,sort`, `--runs`, `--no-upstream` (bs only),
`--zig PATH`, `--out PATH` (without extension). Baseline before the
optimizing backend: [`results/2026-11-03-runtime-bs-8fe40fe.md`](results/2026-11-03-runtime-bs-8fe40fe.md).

`bench/realworld.py` does the same for real programs, so an optimization is
judged on more than the small programs above:

| Workload | What runs |
|---|---|
| zig-fmt | upstream's compiler (built without LLVM by each compiler) running `zig fmt --check` over std |
| zig-sema | the same binary analyzing hello.zig with an empty cache |
| vaxis | libvaxis laying out and rendering text into memory ([`realworld/vaxis_render.zig`](realworld/vaxis_render.zig)) |
| zls-test | the corpus's zls test suite |
| corpus | corpus targets with a CPU-bound run (`Corpus.TARGETS` in realworld.py): translate-c on x86intrin.h, uucode's table generator, vulkan-zig's generator, test suites of zigimg, json-zig, zig-msgpack, tls.zig, zig-hpke, zedis and seven zig-libs modules, zigcli's `loc` over std, and zwasm's interpreter on three shootout programs |

```sh
python3 bench/realworld.py --compiler zig-out/bin/bs
```

Options: `--workloads vaxis,zls-test` (`corpus` for all the corpus
targets, which the corpus checks out and records first), `--runs`, `--no-upstream`, `--out
PATH.json`. Upstream's builds are kept in `bench/.work/realworld/bin` and
reused; the compiler has no ReleaseSafe column, since LLVM needs more than an
orb's 7 GB to build it.
