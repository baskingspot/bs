#!/usr/bin/env python3
"""`zig build` (or `zap build`) of real projects, timed per scenario and split
into phases.

Scenarios, each with the global cache warm (the build runner compiled, the
packages fetched):

- first:      a first build of the project: empty local cache, no zig-out.
- noop:       nothing changed since the last build.
- edit-zig:   a one-line function-body edit to one of the project's Zig sources.
- edit-build: the same edit to the first statement of `pub fn build` in build.zig.

Phases come from the process tree (`perf record -a` of the scheduler's exec,
fork and exit events; low overhead, unlike strace, which slows upstream's
threaded compiler down eightfold):

- startup:    `zig build`/`zap build` until it execs the build runner.
- configurer: compiling build.zig (the compile that runs before the configure
              script) and running the configure script.
- compile:    compile steps (the compiler's processes), minus the above.
- run:        other child processes (run steps, code generators, pkg-config).
- maker:      the build runner's own time, with none of its children running.

Projects are checked out once under bench/.work/phases/src and copied per
compiler. The vaxis workload is bench.py's (its wrapper build of the
text_input example); zap is this repository at HEAD; the corpus projects are
tools/corpus/manifest.json's pinned commits; monstar is the C acceptance
target. Median wall time of `--runs` runs (`--edit-runs` for first and the
edits); the phases are of the fastest of three more runs, recorded with perf.

    python3 bench/build_phases.py                          # upstream zig
    python3 bench/build_phases.py --zap zig-out/bin/zap    # zap
"""

import argparse
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import time

BENCH_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(BENCH_DIR)
WORK = os.path.join(BENCH_DIR, ".work", "phases")
sys.path.insert(0, BENCH_DIR)
import bench  # noqa: E402  (the vaxis checkout)

EDIT_SUFFIX = " std.mem.doNotOptimizeAway(@as(u32, {n}));"
MONSTAR = ("https://github.com/rockorager/monstar", "406c48eb")

# name: (build directory within the checkout, Zig source edit (path, anchor line)).
# The build.zig edit goes after the `pub fn build(` line.
PROJECTS = {
    "vaxis": ("wrapper", ("../libvaxis/src/Vaxis.zig", "    var started: bool = false;")),
    "zap": (".", ("src/main.zig", "    const raw_args = try init.minimal.args.toSlice(arena);")),
    "zf": (".", ("src/tui/main.zig", "    const io = init.io;")),
    "ziggy": (".", ("src/main.zig", "    const io = init.io;")),
    "tls.zig": (".", ("src/handshake_client.zig", "        h.max_client_record_len = h.output.end;")),
    "zls": (".", ("src/features/hover.zig", "    const is_negative = tree.tokenTag(token_index -| 1) == .minus;")),
    "monstar": (".", ("src/main.zig", "    const args = try init.minimal.args.toSlice(arena);")),
}
SCENARIOS = ["first", "noop", "edit-zig", "edit-build"]
PHASES = ["startup", "configurer", "maker", "compile", "run"]


def run_checked(argv, cwd, env=None):
    r = subprocess.run(argv, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode != 0:
        sys.exit(f"failed in {cwd}: {' '.join(argv)}\n{r.stdout[-4000:]}")
    return r.stdout


def checkout(name, zig):
    """The project's pristine checkout, with its packages in zig-pkg."""
    src = os.path.join(WORK, "src", name)
    if name == "vaxis":
        v = bench.Vaxis(os.path.join(WORK, "src"), "zig", zig)
        v.setup()
        return v.dir
    if name == "zap":
        shutil.rmtree(src, ignore_errors=True)
        os.makedirs(src)
        archive = subprocess.run(["git", "archive", "HEAD"], cwd=REPO_DIR, stdout=subprocess.PIPE, check=True).stdout
        subprocess.run(["tar", "-x", "-C", src], input=archive, check=True)
        os.symlink(os.path.join(REPO_DIR, "upstream"), os.path.join(src, "upstream"))
        return src
    if name == "monstar":
        url, commit = MONSTAR
    else:
        manifest = json.load(open(os.path.join(REPO_DIR, "tools", "corpus", "manifest.json")))
        p = next(p for p in manifest["projects"] if p["name"] == name)
        url, commit = p["url"], p["commit"]
    if not os.path.isdir(os.path.join(src, ".git")):
        os.makedirs(os.path.dirname(src), exist_ok=True)
        run_checked(["git", "clone", "--quiet", url, src], WORK)
    run_checked(["git", "checkout", "--quiet", "--force", "--detach", commit], src)
    run_checked([zig, "build", "--fetch"], src, dict(os.environ, ZIG_GLOBAL_CACHE_DIR=os.path.join(WORK, "src-global")))
    return src


class Edit:
    def __init__(self, path, anchor):
        self.path = path
        self.original = open(path).read()
        lines = self.original.split("\n")
        if anchor is None:
            i = next(i for i, l in enumerate(lines) if l.startswith("pub fn build(") and l.rstrip().endswith("{"))
            anchor = lines[i + 1]
        hits = [i for i, l in enumerate(lines) if l == anchor]
        if len(hits) != 1:
            sys.exit(f"edit anchor must occur once in {path}, found {len(hits)}: {anchor!r}")
        self.i, self.anchor = hits[0], anchor
        self.n = int(time.time() * 1000) % 2_000_000_000

    def edit(self):
        self.n += 1
        lines = self.original.split("\n")
        lines[self.i] = self.anchor + EDIT_SUFFIX.format(n=self.n)
        open(self.path, "w").write("\n".join(lines))

    def restore(self):
        open(self.path, "w").write(self.original)


def union(iv):
    out = []
    for a, b in sorted(iv):
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out


def length(iv):
    return sum(b - a for a, b in iv)


def subtract(iv, cut):
    out = []
    for a, b in iv:
        segs = [[a, b]]
        for c, d in cut:
            segs = [s for x, y in segs for s in ([[x, y]] if d <= x or c >= y else
                                                 ([[x, c]] if c > x else []) + ([[d, y]] if d < y else []))]
        out += segs
    return out


def phases(data, compiler):
    """The phases of the build `perf record` wrote to `data`."""
    text = subprocess.run(["perf", "script", "-i", data, "-F", "comm,pid,tid,time,event,trace"],
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout
    compiler = os.path.realpath(shutil.which(compiler) or compiler)
    tgid_of, parent, execs, exits = {}, {}, {}, {}
    root = t0 = t_maker = t_end = None
    for line in text.splitlines():
        m = re.match(r"^\s*.*?\s+(\d+)/(\d+)\s+(\d+\.\d+):\s+sched:(\w+):\s+(.*)$", line)
        if not m:
            continue
        pid, tid, t, ev, rest = int(m[1]), int(m[2]), float(m[3]), m[4], m[5]
        tgid_of[tid] = pid
        if ev == "sched_process_fork":
            parent[int(re.search(r"child_pid=(\d+)", rest)[1])] = tid
        elif ev == "sched_process_exec":
            fn = re.search(r"filename=(\S+)", rest)[1]
            if root is None:
                if os.path.realpath(fn) == compiler:
                    root, t0 = pid, t
            elif pid == root and fn.endswith("/maker"):
                t_maker = t
            else:
                execs[pid] = (t, fn)
        elif ev == "sched_process_exit" and tid == pid:
            exits[pid] = t
            if pid == root:
                t_end = t
    kids = {p: v for p, v in execs.items() if tgid_of.get(parent.get(p), parent.get(p)) == root}
    cfg_start = min((t for t, fn in kids.values() if fn.endswith("/configurer")), default=None)
    cls = {"configurer": [], "compile": [], "run": []}
    for p, (t, fn) in kids.items():
        end = exits.get(p, t_end)
        if fn.endswith("/configurer"):
            cls["configurer"].append((t, end))
        elif os.path.realpath(fn) == compiler:
            # The compile before the configure script runs is build.zig's.
            cls["configurer" if cfg_start is not None and end <= cfg_start else "compile"].append((t, end))
        else:
            cls["run"].append((t, end))
    cfg = union(cls["configurer"])
    comp = subtract(union(cls["compile"]), cfg)
    runs = subtract(subtract(union(cls["run"]), cfg), comp)
    t_maker = t_maker or t0
    return {
        "total": t_end - t0,
        "startup": t_maker - t0,
        "configurer": length(cfg),
        "maker": (t_end - t_maker) - length(union(cls["configurer"] + cls["compile"] + cls["run"])),
        "compile": length(comp),
        "run": length(runs),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zap", help="time `zap build` with this zap (default: upstream `zig build`)")
    ap.add_argument("--zig", default="zig", help="upstream zig 0.17.0, for setup and the baseline")
    ap.add_argument("--projects", default=",".join(PROJECTS))
    ap.add_argument("--scenarios", default=",".join(SCENARIOS))
    ap.add_argument("--runs", type=int, default=10)
    ap.add_argument("--edit-runs", type=int, default=5)
    ap.add_argument("--out", help="report path without extension (default: bench/results/<date>-build-phases-<compiler>)")
    args = ap.parse_args()
    compiler = os.path.abspath(args.zap) if args.zap else args.zig
    which = "zap" if args.zap else "zig"
    out = args.out or os.path.join(BENCH_DIR, "results", f"{time.strftime('%Y-%m-%d')}-build-phases-{which}")
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=os.path.join(WORK, f"global-{which}"))
    results = {}
    for name in args.projects.split(","):
        sub, (zig_path, zig_anchor) = PROJECTS[name]
        src = checkout(name, args.zig)
        dest = os.path.join(WORK, which, name)
        shutil.rmtree(dest, ignore_errors=True)
        shutil.copytree(src, dest, symlinks=True, ignore=lambda d, names: [
            n for n in names if n in (".zig-cache", "zig-out") or (d == src and n in ("cache", "build-cache"))])
        cwd = os.path.join(dest, sub)
        argv = [compiler, "build"]

        def build(trace=None):
            a = (["perf", "record", "-q", "-a", "-e", "sched:sched_process_exec", "-e", "sched:sched_process_exit",
                  "-e", "sched:sched_process_fork", "-o", trace, "--"] if trace else []) + argv
            t = time.perf_counter()
            r = subprocess.run(a, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            if r.returncode != 0:
                sys.exit(f"{name}: {' '.join(argv)} failed:\n{r.stdout[-4000:]}")
            return time.perf_counter() - t

        def fresh():
            for d in (".zig-cache", "zig-out"):
                shutil.rmtree(os.path.join(cwd, d), ignore_errors=True)

        build()  # Warms the global cache: the runner, lazy packages.
        res = results[name] = {}
        for scen in args.scenarios.split(","):
            edit = None
            if scen == "first":
                before = fresh
            elif scen == "noop":
                build()
                time.sleep(3)  # Past the caches' windows for too-new timestamps.
                before = lambda: None
            else:
                edit = Edit(os.path.join(cwd, zig_path) if scen == "edit-zig" else os.path.join(cwd, "build.zig"),
                            zig_anchor if scen == "edit-zig" else None)
                before = edit.edit
            try:
                n = args.runs if scen == "noop" else args.edit_runs
                times = []
                for _ in range(n):
                    before()
                    times.append(build())
                split = []
                for _ in range(3):
                    before()
                    data = os.path.join(WORK, "perf.data")
                    build(data)
                    split.append(phases(data, compiler))
                    os.remove(data)
            finally:
                if edit:
                    edit.restore()
                    build()
            res[scen] = {"median_ms": statistics.median(times) * 1000, "times_ms": [t * 1000 for t in times],
                         "phases_ms": {k: v * 1000 for k, v in min(split, key=lambda s: s["total"]).items()}}
            ph = res[scen]["phases_ms"]
            print(f"{name:8} {scen:10} {res[scen]['median_ms']:9.1f} ms | "
                  + " ".join(f"{k} {ph[k]:.1f}" for k in PHASES), flush=True)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    json.dump({"compiler": compiler, "results": results}, open(out + ".json", "w"), indent=1)
    with open(out + ".md", "w") as f:
        f.write(f"# `{which} build` phases ({compiler})\n\nMedian wall time (ms); phases (ms) of the fastest of "
                "three perf-recorded runs.\n\n| project | scenario | median | " + " | ".join(PHASES) + " |\n"
                "|---|---|---:|" + "---:|" * len(PHASES) + "\n")
        for name, res in results.items():
            for scen, r in res.items():
                f.write(f"| {name} | {scen} | {r['median_ms']:.1f} | "
                        + " | ".join(f"{r['phases_ms'][k]:.1f}" for k in PHASES) + " |\n")
    print(f"wrote {out}.md")


main()
