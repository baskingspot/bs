#!/usr/bin/env python3
"""`zig build --watch` (or `zap build --watch`): the time from saving an edit to
the rebuilt artifact.

For each project, starts `<compiler> build --watch` once, waits for the first
build, then for each edit writes the same one-line Zig source edit that
bench/build_phases.py makes (a new value each time) and polls the installed
artifact until its stat changes. That time includes the runner's change
detection and its debounce (`--debounce`, 50 ms by default), the compile
step's update, and the install. Projects, checkouts and caches are
build_phases.py's (bench/.work/phases); run build_phases.py once first, or
let this script set them up.

Needs Linux 6.5 or later: upstream's runner (lib/compiler/Maker/Watch.zig)
uses `name_to_handle_at` with `AT_HANDLE_FID`, and on older kernels it
panics right after the first build, under `zig build` and `zap build` alike.

    python3 bench/watch.py                           # upstream zig
    python3 bench/watch.py --zap zig-out/bin/zap     # zap
    python3 bench/watch.py --debounce 0              # without the debounce

`--protocol` measures, on any kernel, what a watch rebuild asks of the
compiler: the artifact's compile step (its command line from `build
--verbose`) runs once with `--listen=-` and answers an `update` after each
edit, as under `--watch`; the time is from the update to the compiler's
answer. Change detection, the debounce and the install are not included.
`--incremental` runs `build --watch -fincremental` (with `--protocol`, it
adds `-fincremental` to the compile step), upstream's incremental
compilation; zap accepts the flag and answers every update the same way.
"""

import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import threading
import time

BENCH_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BENCH_DIR)
import bench  # noqa: E402  (CompilerServer)
import build_phases as bp  # noqa: E402

# The artifact each project's edit rebuilds, relative to its build directory.
ARTIFACTS = {
    "vaxis": "zig-out/bin/example-text_input",
    "zls": "zig-out/bin/zls",
    "monstar": "zig-out/bin/monstar",
}


def stat_key(path):
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return None
    return (st.st_ino, st.st_size, st.st_mtime_ns)


def protocol(name, compiler, cwd, env, artifact, edit, args):
    """The compile step's update times over --listen=-, one process for every edit."""
    out = subprocess.run([compiler, "build", *bp.steps_of(name), "--verbose"], cwd=cwd, env=env, check=True,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout
    want = f"--name {os.path.basename(artifact)} "
    line = next((l for l in out.splitlines() if want in l and "--listen=-" in l), None)
    if line is None:
        sys.exit(f"{name}: no compile step named {os.path.basename(artifact)} in build --verbose")
    argv = line.split("info(verbose): ", 1)[-1].split()
    if args.incremental:
        argv.insert(argv.index("--listen=-"), "-fincremental")
    server = bench.CompilerServer(argv, cwd, env)
    times = []
    try:
        server.update()
        for _ in range(args.edits):
            edit.edit()
            dt, _ = server.update()
            times.append(dt * 1000)
    finally:
        edit.restore()
        server.update()
        server.close()
    print(f"{name:8} update after an edit: median {statistics.median(times):8.1f} ms "
          f"(min {min(times):.1f}, max {max(times):.1f})", flush=True)
    return {"median_ms": statistics.median(times), "times_ms": times}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zap", help="time `zap build --watch` with this zap (default: upstream `zig build --watch`)")
    ap.add_argument("--zig", default="zig")
    ap.add_argument("--projects", default=",".join(ARTIFACTS))
    ap.add_argument("--edits", type=int, default=10)
    ap.add_argument("--debounce", type=int, help="the runner's --debounce in ms (default: its own, 50)")
    ap.add_argument("--timeout", type=float, default=600, help="seconds to wait for a build")
    ap.add_argument("--protocol", action="store_true", help="time the compile step's updates over --listen=- only")
    ap.add_argument("--incremental", action="store_true",
                    help="`build --watch -fincremental` (with --protocol: -fincremental on the compile step)")
    ap.add_argument("--out", help="report path without extension (default: bench/results/<date>-watch-<compiler>)")
    args = ap.parse_args()
    compiler = os.path.abspath(args.zap) if args.zap else args.zig
    which = "zap" if args.zap else "zig"
    out = args.out or os.path.join(BENCH_DIR, "results", f"{time.strftime('%Y-%m-%d')}-watch-{which}")
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=os.path.join(bp.WORK, f"global-{which}"))
    results = {}
    for name in args.projects.split(","):
        sub = bp.PROJECTS[name][0] if name in bp.PROJECTS else "."
        src = bp.checkout(name, args.zig)
        dest = os.path.join(bp.WORK, f"watch-{which}", name)
        shutil.rmtree(dest, ignore_errors=True)
        shutil.copytree(src, dest, symlinks=True, ignore=lambda d, names: [
            n for n in names if n in (".zig-cache", "zig-out") or (d == src and n in ("cache", "build-cache"))])
        cwd = os.path.join(dest, sub)
        artifact = os.path.join(cwd, ARTIFACTS[name])
        path, anchor, suffix = bp.zig_edit_of(name, cwd)
        edit = bp.Edit(os.path.join(cwd, path), anchor, suffix)
        argv = [compiler, "build", *bp.steps_of(name), "--watch"]
        if args.debounce is not None:
            argv += ["--debounce", str(args.debounce)]
        if args.incremental:
            argv.append("-fincremental")
        # The first build, outside the watch, so the watch starts warm.
        subprocess.run([compiler, "build", *bp.steps_of(name)], cwd=cwd, env=env, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if args.protocol:
            results[name] = protocol(name, compiler, cwd, env, artifact, edit, args)
            continue
        proc = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log = []
        reader = threading.Thread(target=lambda: log.extend(iter(proc.stdout.readline, b"")), daemon=True)
        reader.start()

        def settle():
            """Waits until the runner has written nothing for 0.5 s."""
            n, quiet = len(log), time.monotonic()
            while time.monotonic() - quiet < 0.5:
                if proc.poll() is not None:
                    sys.exit(f"{name}: {' '.join(argv)} exited ({proc.returncode}):\n"
                             + b"".join(log)[-4000:].decode(errors="replace"))
                if len(log) != n:
                    n, quiet = len(log), time.monotonic()
                time.sleep(0.01)

        times = []
        try:
            settle()
            for _ in range(args.edits):
                before = stat_key(artifact)
                edit.edit()
                t0 = time.perf_counter()
                while stat_key(artifact) == before:
                    if time.perf_counter() - t0 > args.timeout or proc.poll() is not None:
                        sys.exit(f"{name}: no rebuild of {artifact}:\n" + b"".join(log)[-4000:].decode(errors="replace"))
                    time.sleep(0.0005)
                times.append((time.perf_counter() - t0) * 1000)
                settle()
        finally:
            edit.restore()
            proc.kill()
            proc.wait()
        results[name] = {"median_ms": statistics.median(times), "times_ms": times}
        print(f"{name:8} save to artifact: median {statistics.median(times):8.1f} ms "
              f"(min {min(times):.1f}, max {max(times):.1f})", flush=True)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    mode = ("protocol" if args.protocol else
            f"--watch, debounce {args.debounce if args.debounce is not None else 'default'}") + \
        (", -fincremental" if args.incremental else "")
    json.dump({"compiler": compiler, "mode": mode, "results": results}, open(out + ".json", "w"), indent=1)
    with open(out + ".md", "w") as f:
        f.write(f"# `{which} build --watch` ({mode}): edit to rebuilt artifact ({compiler})\n\n"
                "| project | median (ms) | min | max |\n|---|---:|---:|---:|\n")
        for name, r in results.items():
            f.write(f"| {name} | {r['median_ms']:.1f} | {min(r['times_ms']):.1f} | {max(r['times_ms']):.1f} |\n")
    print(f"wrote {out}.md")


if __name__ == "__main__":
    main()
