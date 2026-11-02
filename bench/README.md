# Compile-time benchmarks

`bench/bench.py` times Debug builds of fixed workloads with a chosen compiler
binary (upstream `zig` 0.17.0 or zap) and writes a Markdown report and a JSON
file to `bench/results/`. zap is tracked against the upstream baseline in
[`results/`](results/) at every milestone.

## Running

```sh
# Upstream baseline: every mode and scenario (about 25 minutes on a 4 vCPU orb).
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
