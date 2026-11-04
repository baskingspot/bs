#!/usr/bin/env python3
"""Edit-to-artifact latency of `zig build --watch` against `zap build --watch`.

For each project and compiler: copy the pristine checkout (bench/build_phases.py's
checkout), warm the compiler's own global cache with one plain build, empty the
local cache and zig-out, then start `<compiler> build --watch --summary new` and:

- first: time from spawning the process to the installed artifact appearing and to
  the first "Build Summary" line.
- edit-zig / edit-build: build_phases.py's one-line edits (a new
  `std.mem.doNotOptimizeAway(@as(u32, N))` each time). Latency is from the edited
  file's write returning to (a) the installed artifact being replaced (new inode,
  polled every 0.5 ms) and (b) the next "Build Summary" line on stderr.
  After each rebuild the harness waits `--settle` seconds and counts any further
  Build Summary lines (extra rebuilds) and checks the artifact's hash changed.
- build.zig marker: twice, a build.zig edit that installs a new file
  (zig-out/watch-marker-N), to check that build.zig edits are really applied.

Every edit waits for the build's Build Summary (plus `--settle`), so no edit
lands while an earlier build (tests, extra rebuilds) is still running, and the
first build is timed under --watch. Needs Linux 6.5 or later: upstream's runner
(lib/compiler/Maker/Watch.zig) uses `name_to_handle_at` with `AT_HANDLE_FID`,
and on older kernels it panics after the first build, under `zig build` and
`zap build` alike.

    python3 bench/watch.py --zap zig-out/bin/zap
    python3 bench/watch.py --zap zig-out/bin/zap --extra=-fincremental
    python3 bench/watch.py --zap zig-out/bin/zap --projects zls --bp-steps   # zls's install+test

`--protocol` measures, on any kernel, what a watch rebuild asks of the
compiler alone: the artifact's compile step (its command line from `build
--verbose`) runs once with `--listen=-` and answers an `update` after each Zig
edit, as under `--watch`; the time is from the update to the compiler's answer,
without change detection, the debounce, run steps or the install. `--extra`
arguments that start with `-f` (such as `-fincremental`) go to the compile step.

    python3 bench/watch.py --zap zig-out/bin/zap --protocol
    python3 bench/watch.py --zap zig-out/bin/zap --protocol --extra=-fincremental

Works with either version of build_phases.py (with or without steps_of,
zig_edit_of and the three-argument Edit). The 2026-11-04 timbot numbers used the
zap-build-watch version, whose build.zig edit appends to the `pub fn build(` line.
Scratch files and logs go to bench/.work/watch_bench.
"""
import argparse
import hashlib
import json
import os
import shutil
import signal
import statistics
import subprocess
import sys
import threading
import time

BENCH_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BENCH_DIR)


def load_build_phases():
    """build_phases.py's namespace, without running its main()."""
    path = os.path.join(BENCH_DIR, "build_phases.py")
    src = open(path).read().rstrip()
    if src.endswith("\nmain()"):  # older build_phases.py calls main() unguarded
        src = src[: -len("main()")]
    ns = {"__file__": path, "__name__": "build_phases"}
    exec(compile(src, path, "exec"), ns)
    return ns


BP = load_build_phases()
WORK = os.path.join(BENCH_DIR, ".work", "watch_bench")
ZIG = ZAP = None  # set from the command line


def steps_of(name):
    return BP["steps_of"](name) if "steps_of" in BP else []


def edits_of(name, cwd):
    """(zig path, zig Edit factory, build.zig Edit factory) for either build_phases.py."""
    Edit = BP["Edit"]
    if "zig_edit_of" in BP:
        path, anchor, suffix = BP["zig_edit_of"](name, cwd)
        return (path, lambda p: Edit(p, anchor, suffix), lambda p: Edit(p, None, BP["HEADER_SUFFIX"]))
    path, anchor = BP["PROJECTS"][name][1]
    return path, lambda p: Edit(p, anchor), lambda p: Edit(p, None)

ARTIFACTS = {"vaxis": "zig-out/bin/example-text_input", "zls": "zig-out/bin/zls", "monstar": "zig-out/bin/monstar"}


class Watcher:
    def __init__(self, argv, cwd, env, log_path, artifact):
        self.lines = []  # (t, line)
        self.art = []  # (t, ino) changes
        self.cv = threading.Condition()
        self.artifact = artifact
        self.log = open(log_path, "w")
        self.t_spawn = time.perf_counter()
        self.p = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, start_new_session=True)
        self.alive = True
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._poll, daemon=True).start()

    def _read(self):
        for raw in self.p.stdout:
            t = time.perf_counter()
            line = raw.decode(errors="replace").rstrip("\n")
            self.log.write(f"{t - self.t_spawn:10.4f} {line}\n")
            self.log.flush()
            with self.cv:
                self.lines.append((t, line))
                self.cv.notify_all()
        with self.cv:
            self.alive = False
            self.cv.notify_all()

    def _poll(self):
        last = None
        while self.alive:
            try:
                ino = os.stat(self.artifact).st_ino
            except FileNotFoundError:
                ino = None
            if ino != last:
                t = time.perf_counter()
                with self.cv:
                    self.art.append((t, ino))
                    self.cv.notify_all()
                self.log.write(f"{t - self.t_spawn:10.4f} [harness] artifact inode {last} -> {ino}\n")
                self.log.flush()
                last = ino
            time.sleep(0.0005)

    def summaries_after(self, t0):
        return [(t, l) for t, l in self.lines if t > t0 and l.startswith("Build Summary")]

    def wait_summary(self, t0, timeout):
        end = time.perf_counter() + timeout
        with self.cv:
            while True:
                s = self.summaries_after(t0)
                if s:
                    return s[0]
                if not self.alive:
                    return None
                left = end - time.perf_counter()
                if left <= 0:
                    return None
                self.cv.wait(left)

    def art_after(self, t0):
        return next(((t, i) for t, i in self.art if t > t0 and i is not None), None)

    def note(self, msg):
        self.log.write(f"{time.perf_counter() - self.t_spawn:10.4f} [harness] {msg}\n")
        self.log.flush()

    def stop(self):
        rc = self.p.poll()
        if rc is None:
            os.killpg(self.p.pid, signal.SIGTERM)
            try:
                self.p.wait(5)
            except subprocess.TimeoutExpired:
                os.killpg(self.p.pid, signal.SIGKILL)
                self.p.wait()
        self.alive = False
        time.sleep(0.01)
        self.log.close()
        return rc


def sha(path):
    try:
        return hashlib.sha256(open(path, "rb").read()).hexdigest()[:16]
    except FileNotFoundError:
        return None


def run(name, which, args, tag):
    sub = BP["PROJECTS"][name][0]
    src = BP["checkout"](name, ZIG)
    compiler = ZAP if which == "zap" else ZIG
    dest = os.path.join(WORK, which, name)
    shutil.rmtree(dest, ignore_errors=True)
    shutil.copytree(src, dest, symlinks=True, ignore=lambda d, names: [
        n for n in names if n in (".zig-cache", "zig-out") or (d == src and n in ("cache", "build-cache"))])
    cwd = os.path.join(dest, sub)
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=os.path.join(WORK, f"global-{which}"))
    if os.sep in ZIG:  # zap finds its lib directory through the zig on PATH
        env["PATH"] = os.path.dirname(ZIG) + os.pathsep + env["PATH"]
    steps = steps_of(name) if args.bp_steps else []
    r = subprocess.run([compiler, "build", *steps], cwd=cwd, env=env, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True)
    if r.returncode:
        sys.exit(f"{which} {name} warm build failed:\n{r.stdout[-3000:]}")
    for d in (".zig-cache", "zig-out"):
        shutil.rmtree(os.path.join(cwd, d), ignore_errors=True)
    artifact = os.path.join(cwd, ARTIFACTS[name])
    zig_path, zig_edit, build_edit = edits_of(name, cwd)
    os.makedirs(os.path.join(WORK, "logs"), exist_ok=True)
    log = os.path.join(WORK, "logs", f"{tag}-{which}-{name}.log")
    w = Watcher([compiler, "build", *steps, "--watch", "--summary", "new", *args.extra.split()], cwd, env, log,
                artifact)
    res = {"log": log, "problems": []}
    try:
        s = w.wait_summary(0, 600)
        a = w.art_after(0)
        if s is None:
            res["problems"].append("first build: no Build Summary")
            return res
        time.sleep(args.settle)
        a = w.art_after(0)
        res["first"] = {"summary_ms": (s[0] - w.t_spawn) * 1000,
                        "artifact_ms": (a[0] - w.t_spawn) * 1000 if a else None}
        extra = w.summaries_after(s[0])
        if extra:
            res["problems"].append(f"first build: {len(extra)} extra rebuild(s) with no edit")
        for scen in ("edit-zig", "edit-build"):
            path = os.path.join(cwd, zig_path) if scen == "edit-zig" else os.path.join(cwd, "build.zig")
            e = zig_edit(path) if scen == "edit-zig" else build_edit(path)
            rows = []
            prev_hash = sha(artifact)
            try:
                for i in range(args.edits):
                    w.note(f"{scen} #{i}: writing {os.path.relpath(path, cwd)}")
                    e.edit()
                    t0 = time.perf_counter()
                    s = w.wait_summary(t0, args.timeout)
                    if s is None:
                        res["problems"].append(f"{scen} #{i}: no rebuild within {args.timeout} s"
                                               + ("" if w.alive else f" (process exited {w.p.poll()})"))
                        break
                    time.sleep(args.settle)
                    a = w.art_after(t0)
                    extra = w.summaries_after(s[0])
                    h = sha(artifact)
                    rows.append({"summary_ms": (s[0] - t0) * 1000,
                                 "artifact_ms": (a[0] - t0) * 1000 if a and a[0] <= s[0] + 0.05 else None,
                                 "artifact_changed": h != prev_hash, "extra_rebuilds": len(extra),
                                 "summary": s[1]})
                    if extra:
                        res["problems"].append(f"{scen} #{i}: {len(extra)} extra rebuild(s): "
                                               + " | ".join(l for _, l in extra))
                    if scen == "edit-zig" and h == prev_hash:
                        res["problems"].append(f"{scen} #{i}: artifact unchanged after edit")
                    prev_hash = h
            finally:
                w.note(f"{scen}: restoring")
                e.restore()
                t0 = time.perf_counter()
                if w.wait_summary(t0, args.timeout) is None:
                    res["problems"].append(f"{scen}: no rebuild after restore")
                time.sleep(args.settle)
            res[scen] = rows
        # Is a build.zig change really applied? Install a new marker file twice.
        bz = os.path.join(cwd, "build.zig")
        orig = open(bz).read()
        lines = orig.split("\n")
        i = next(i for i, l in enumerate(lines) if l.startswith("pub fn build(")) + 1
        try:
            for k in range(2):
                marker = f"watch-marker-{int(time.time() * 1000)}"
                w.note(f"semantic build.zig edit: install {marker}")
                open(bz, "w").write("\n".join(lines[:i] + [
                    f'    b.getInstallStep().dependOn(&b.addInstallFile(b.path("build.zig"), "{marker}").step);']
                    + lines[i:]))
                t0 = time.perf_counter()
                s = w.wait_summary(t0, args.timeout)
                time.sleep(args.settle)
                ok = os.path.exists(os.path.join(cwd, "zig-out", marker))
                res.setdefault("marker", []).append({"applied": ok, "summary_ms": (s[0] - t0) * 1000 if s else None,
                                                     "extra_rebuilds": len(w.summaries_after(s[0])) if s else None})
                if not ok:
                    res["problems"].append(f"build.zig marker edit #{k}: zig-out/{marker} not installed"
                                           + ("" if s else " (no rebuild)"))
        finally:
            open(bz, "w").write(orig)
            t0 = time.perf_counter()
            w.wait_summary(t0, args.timeout)
            time.sleep(args.settle)
    finally:
        rc = w.stop()
        if rc is not None:
            res["problems"].append(f"watch process exited by itself with {rc}")
    return res


def protocol(name, which, args):
    """The compile step's update times over --listen=-, one process for every edit."""
    import bench  # CompilerServer
    sub = BP["PROJECTS"][name][0]
    src = BP["checkout"](name, ZIG)
    compiler = ZAP if which == "zap" else ZIG
    dest = os.path.join(WORK, which, name)
    shutil.rmtree(dest, ignore_errors=True)
    shutil.copytree(src, dest, symlinks=True, ignore=lambda d, names: [
        n for n in names if n in (".zig-cache", "zig-out") or (d == src and n in ("cache", "build-cache"))])
    cwd = os.path.join(dest, sub)
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=os.path.join(WORK, f"global-{which}"))
    if os.sep in ZIG:
        env["PATH"] = os.path.dirname(ZIG) + os.pathsep + env["PATH"]
    steps = steps_of(name) if args.bp_steps else []
    out = subprocess.run([compiler, "build", *steps, "--verbose"], cwd=cwd, env=env, check=True,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout
    want = f"--name {os.path.basename(ARTIFACTS[name])} "
    line = next((l for l in out.splitlines() if want in l and "--listen=-" in l), None)
    if line is None:
        sys.exit(f"{name}: no compile step named {os.path.basename(ARTIFACTS[name])} in build --verbose")
    argv = line.split("info(verbose): ", 1)[-1].split()
    i = argv.index("--listen=-")
    argv[i:i] = [a for a in args.extra.split() if a.startswith("-f")]
    zig_path, zig_edit, _ = edits_of(name, cwd)
    e = zig_edit(os.path.join(cwd, zig_path))
    server = bench.CompilerServer(argv, cwd, env)
    times = []
    try:
        server.update()
        for _ in range(args.edits):
            e.edit()
            dt, _ = server.update()
            times.append(dt * 1000)
    finally:
        e.restore()
        server.update()
        server.close()
    return {"update_ms": times}


def med(rows, key):
    v = [r[key] for r in rows if r.get(key) is not None]
    return statistics.median(v) if v else None


def main():
    global ZIG, ZAP
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zap", required=True, help="the zap binary (built with -Doptimize=ReleaseFast)")
    ap.add_argument("--zig", default="zig", help="upstream zig, for setup and the baseline")
    ap.add_argument("--projects", default="vaxis,zls,monstar")
    ap.add_argument("--compilers", default="zig,zap")
    ap.add_argument("--edits", type=int, default=7)
    ap.add_argument("--settle", type=float, default=2.0)
    ap.add_argument("--bp-steps", action="store_true", help="build build_phases.steps_of(name), as bench/watch.py")
    ap.add_argument("--extra", default="", help="extra `build` arguments, e.g. -fincremental")
    ap.add_argument("--timeout", type=float, default=300)
    ap.add_argument("--tag", default=time.strftime("%H%M%S"))
    ap.add_argument("--protocol", action="store_true", help="time only the compile step's updates over --listen=-")
    args = ap.parse_args()
    ZIG = os.path.abspath(args.zig) if os.sep in args.zig else args.zig
    ZAP = os.path.abspath(args.zap)
    out = os.path.join(WORK, f"results-{args.tag}.json")
    allres = {}
    for name in args.projects.split(","):
        for which in args.compilers.split(","):
            if args.protocol:
                r = allres[f"{which}/{name}"] = protocol(name, which, args)
                t = r["update_ms"]
                print(f"{which:4} {name:8} update after an edit: median {statistics.median(t):.1f} ms "
                      f"(min {min(t):.1f}, max {max(t):.1f})", flush=True)
                json.dump(allres, open(out, "w"), indent=1)
                continue
            r = run(name, which, args, args.tag)
            allres[f"{which}/{name}"] = r
            f = r.get("first", {})
            print(f"{which:4} {name:8} first {f.get('artifact_ms')} / {f.get('summary_ms')} ms | "
                  + " | ".join(f"{s} art {med(r.get(s, []), 'artifact_ms')} sum {med(r.get(s, []), 'summary_ms')} "
                               "[" + ", ".join("%.0f" % x["summary_ms"] for x in r.get(s, [])) + "]"
                               for s in ("edit-zig", "edit-build"))
                  + (f" | PROBLEMS: {r['problems']}" if r["problems"] else ""), flush=True)
            json.dump(allres, open(out, "w"), indent=1)
    print("wrote", out)


if __name__ == "__main__":
    main()
