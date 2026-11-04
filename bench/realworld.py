#!/usr/bin/env python3
"""Run-time benchmarks on real programs: the speed of the code zap generates
where microbenchmarks can mislead.

Each workload builds a real program with zap and, unless --no-upstream, with
upstream zig 0.17.1 in Debug (self-hosted x86_64 backend) and ReleaseSafe
(LLVM), checks that the builds print the same output, and reports the
median wall time of each:

- zig-fmt:  upstream's compiler (src/main.zig without LLVM), built by each
            compiler, running `zig fmt --check` over upstream's lib/std.
- zig-sema: the same binary analyzing hello.zig (`build-exe -fno-emit-bin`)
            with an empty cache: Sema, the InternPool, and std's hash maps.
- vaxis:    bench/realworld/vaxis_render.zig, libvaxis's layout and render
            path into memory (the libvaxis checkout bench.py sets up).
- zls-test: zls's test suite (the corpus's pinned zls; `tools/corpus/run.py
            --projects zls --list` records its command line).

Upstream's builds of a workload do not change, so they are kept in the work
directory and reused. The compiler has no ReleaseSafe build: LLVM needs more
memory for it than an orb's 7 GB.
"""

import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

BENCH_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(BENCH_DIR)
sys.path.insert(0, BENCH_DIR)
import bench  # noqa: E402  (the vaxis checkout and its module flags)

WORKLOADS = ["zig-fmt", "zig-sema", "vaxis", "zls-test"]
MODES = {
    "zap": [],
    "Debug": ["-fno-llvm", "-fno-lld"],
    "ReleaseSafe": ["-OReleaseSafe"],
}


def build(argv, cwd, out):
    if os.path.exists(out):
        os.remove(out)
    t0 = time.perf_counter()
    r = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, env=dict(os.environ, ZAP_CACHE="off"))
    if r.returncode != 0:
        sys.exit(f"build failed in {cwd}: {' '.join(argv)}\n{r.stdout[-4000:]}{r.stderr[-4000:]}")
    return time.perf_counter() - t0


def with_mode(argv, mode):
    """`argv` (a build-exe or test command line) for `mode`: zap's as is,
    upstream's with its optimize mode and backend."""
    if mode == "zap":
        return argv
    res = [w for w in argv if not w.startswith("-O")]
    return res[:2] + MODES[mode] + res[2:]


class Workload:
    modes = list(MODES)

    def __init__(self, work, zig):
        self.work = work
        self.zig = zig

    def run_once(self, binary):
        """Runs the program once; returns (seconds, output to compare)."""
        with tempfile.TemporaryDirectory(prefix="zap-rw-") as tmp:
            argv = [binary if a == "{bin}" else a.replace("{tmp}", tmp) for a in self.run_argv]
            t0 = time.perf_counter()
            r = subprocess.run(argv, cwd=self.run_cwd, stdin=subprocess.DEVNULL, capture_output=True, text=True)
            elapsed = time.perf_counter() - t0
        if r.returncode != 0:
            sys.exit(f"{' '.join(argv)} exited with {r.returncode}:\n{r.stderr[-4000:]}")
        return elapsed, self.output(r.stdout + r.stderr)

    def output(self, text):
        return text


class ZigCompiler(Workload):
    def setup(self):
        d = os.path.join(self.work, "zig-src")
        if not os.path.isdir(d):
            shutil.copytree(os.path.join(REPO_DIR, "upstream", "src"), os.path.join(d, "src"))
            shutil.copy(os.path.join(BENCH_DIR, "workloads", "zig", "build_options.zig"), d)
        self.cwd = d
        self.lib = os.path.join(REPO_DIR, "upstream", "lib")

    def build_argv(self, compiler, mode, out):
        return with_mode([compiler, "build-exe", "--stack", "48234496", "-fno-sanitize-thread", "-Odebug",
                          "--dep", "build_options", "-Mroot=src/main.zig", "-Mbuild_options=build_options.zig",
                          "--name", "zig", f"-femit-bin={out}",
                          "--cache-dir", os.path.join(self.work, "cache", mode, "local"),
                          "--global-cache-dir", os.path.join(self.work, "cache", mode, "global")], mode)

    # Both zig workloads share the compiler's build.
    key = "zig"
    modes = ["zap", "Debug"]


class ZigFmt(ZigCompiler):
    name = "zig-fmt"

    def setup(self):
        super().setup()
        self.run_cwd = self.cwd
        self.run_argv = ["{bin}", "fmt", "--check", os.path.join(self.lib, "std")]


class ZigSema(ZigCompiler):
    name = "zig-sema"

    def setup(self):
        super().setup()
        self.run_cwd = self.cwd
        self.run_argv = ["{bin}", "build-exe", "-fno-emit-bin", os.path.join(BENCH_DIR, "workloads", "hello", "hello.zig"),
                         "--zig-lib-dir", self.lib, "--cache-dir", "{tmp}", "--global-cache-dir", "{tmp}"]


class Vaxis(Workload):
    name = "vaxis"
    key = "vaxis"

    def setup(self):
        v = bench.Vaxis(os.path.join(self.work, "vaxis-setup"), "zig", self.zig)
        v.setup()
        cmd = v.commands["build-exe"]
        argv = cmd["argv"]
        # The benchmark's root instead of the example's, without the cache
        # flags and the name.
        res = []
        i = 2
        while i < len(argv):
            w = argv[i]
            if w in ("--cache-dir", "--global-cache-dir", "--name"):
                i += 2
                continue
            res.append("-Mroot=" + os.path.join(BENCH_DIR, "realworld", "vaxis_render.zig") if w.startswith("-Mroot=") else w)
            i += 1
        self.flags = res
        self.cwd = cmd["cwd"]
        self.run_cwd = self.cwd
        self.run_argv = ["{bin}"]

    def build_argv(self, compiler, mode, out):
        return with_mode([compiler, "build-exe", *self.flags, f"-femit-bin={out}",
                          "--cache-dir", os.path.join(self.work, "cache", mode, "local"),
                          "--global-cache-dir", os.path.join(self.work, "cache", mode, "global")], mode)


class ZlsTest(Workload):
    name = "zls-test"
    key = "zls-test"

    def setup(self):
        corpus = os.path.join(REPO_DIR, "tools", "corpus", ".work")
        cmds = os.path.join(corpus, "commands", "zls.json")
        if not os.path.exists(cmds):
            subprocess.run([sys.executable, os.path.join(REPO_DIR, "tools", "corpus", "run.py"), "--projects", "zls",
                            "--list"], check=True)
        words = json.load(open(cmds))["test"]
        res = []
        i = 2
        while i < len(words):
            w = words[i]
            if w in ("--cache-dir", "--global-cache-dir", "--zig-lib-dir"):
                i += 2
                continue
            if w not in ("--listen=-",):
                res.append(w)
            i += 1
        self.flags = res
        self.cwd = os.path.join(corpus, "src", "zls")
        self.run_cwd = self.cwd
        self.run_argv = ["{bin}"]

    def build_argv(self, compiler, mode, out):
        return with_mode([compiler, "test", *self.flags, "--test-no-exec", f"-femit-bin={out}",
                          "--cache-dir", os.path.join(self.work, "cache", mode, "local")], mode)

    def output(self, text):
        # The summary line; the per-test lines' order is the same, but their
        # timing-dependent progress output is not compared.
        lines = [ln for ln in text.splitlines() if "passed;" in ln]
        return lines[-1] if lines else text


CLASSES = {"zig-fmt": ZigFmt, "zig-sema": ZigSema, "vaxis": Vaxis, "zls-test": ZlsTest}


def fmt_s(s):
    return f"{s:.2f} s" if s >= 1 else f"{s * 1000:.0f} ms"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--compiler", default="zig-out/bin/zap", help="zap binary (default: zig-out/bin/zap)")
    ap.add_argument("--zig", default="zig", help="upstream zig 0.17.1 (default: zig on PATH)")
    ap.add_argument("--workloads", default=",".join(WORKLOADS), help="comma-separated subset of " + ",".join(WORKLOADS))
    ap.add_argument("--runs", type=int, default=5, help="runs per binary (default 5)")
    ap.add_argument("--no-upstream", action="store_true", help="time only zap's builds")
    ap.add_argument("--work", default=os.path.join(BENCH_DIR, ".work", "realworld"),
                    help="work directory; keeps upstream's builds (default: bench/.work/realworld)")
    ap.add_argument("--out", help="write PATH.json")
    args = ap.parse_args()

    zap = os.path.abspath(args.compiler)
    zig = shutil.which(args.zig) or args.zig
    os.makedirs(args.work, exist_ok=True)
    all_modes = ["zap"] if args.no_upstream else list(MODES)
    results = {}
    built = {}
    for wname in args.workloads.split(","):
        w = CLASSES[wname](args.work, zig)
        w.setup()
        modes = [m for m in all_modes if m in w.modes]
        results[wname] = {}
        outputs = {}
        for mode in modes:
            out = os.path.join(args.work, "bin", f"{w.key}-{mode}")
            os.makedirs(os.path.dirname(out), exist_ok=True)
            compiler = zap if mode == "zap" else zig
            if (w.key, mode) not in built and (mode == "zap" or not os.path.exists(out)):
                print(f"building {w.key} with {mode}...", file=sys.stderr, flush=True)
                built[(w.key, mode)] = build(w.build_argv(compiler, mode, out), w.cwd, out)
            times = []
            for _ in range(args.runs):
                t, o = w.run_once(out)
                times.append(t)
                if mode in outputs and outputs[mode] != o:
                    sys.exit(f"{wname} ({mode}) printed different output across runs")
                outputs[mode] = o
            results[wname][mode] = {"median": statistics.median(times), "min": min(times), "max": max(times)}
        if len(set(outputs.values())) != 1:
            sys.exit(f"{wname}: the builds printed different output: {outputs}")

    def cell(r, m):
        return f"{fmt_s(r[m]['median'])} (min {fmt_s(r[m]['min'])})" if m in r else "-"

    def ratio(r, m):
        return f"{r['zap']['median'] / r[m]['median']:.2f}x" if m in r else "-"

    header = "| workload | " + " | ".join(all_modes) + "".join(f" | zap / {m}" for m in all_modes[1:]) + " |"
    print(header)
    print("|" + "---|" * (header.count("|") - 1))
    for wname, r in results.items():
        print(f"| {wname} | " + " | ".join(cell(r, m) for m in all_modes) + "".join(f" | {ratio(r, m)}" for m in all_modes[1:]) + " |")
    if args.out:
        with open(args.out, "w") as f:
            json.dump({"compiler": zap, "runs": args.runs, "results": results}, f, indent=1)


if __name__ == "__main__":
    main()
