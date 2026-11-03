#!/usr/bin/env python3
"""Run-time benchmarks: the speed of the code zap generates.

Builds each program in bench/runtime/ with zap and with upstream zig 0.17.0
in Debug (self-hosted x86_64 backend) and ReleaseSafe (LLVM), checks that
all three print the same output, and reports the median wall time of each
binary. See bench/README.md.
"""

import argparse
import json
import os
import platform
import statistics
import subprocess
import sys
import tempfile
import time

BENCH_DIR = os.path.dirname(os.path.abspath(__file__))
PROGRAMS_DIR = os.path.join(BENCH_DIR, "runtime")
PROGRAMS = ["fib", "sieve", "sort", "hash", "nbody", "fmt"]


def build(argv, cwd):
    t0 = time.perf_counter()
    r = subprocess.run(argv, cwd=cwd, capture_output=True, text=True)
    elapsed = time.perf_counter() - t0
    if r.returncode != 0:
        sys.exit(f"build failed: {' '.join(argv)}\n{r.stdout}{r.stderr}")
    return elapsed


def run(binary, runs):
    times = []
    output = None
    for _ in range(runs):
        t0 = time.perf_counter()
        r = subprocess.run([binary], capture_output=True, text=True)
        times.append(time.perf_counter() - t0)
        if r.returncode != 0:
            sys.exit(f"{binary} exited with {r.returncode}:\n{r.stderr}")
        out = r.stdout + r.stderr
        if output is not None and out != output:
            sys.exit(f"{binary} printed different output across runs")
        output = out
    return statistics.median(times), min(times), max(times), output


def fmt_ms(s):
    return f"{s * 1000:.0f} ms" if s >= 0.01 else f"{s * 1000:.1f} ms"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--compiler", default="zig-out/bin/zap", help="zap binary (default: zig-out/bin/zap)")
    ap.add_argument("--zig", default="zig", help="upstream zig 0.17.0 (default: zig on PATH)")
    ap.add_argument("--programs", default=",".join(PROGRAMS), help="comma-separated subset of " + ",".join(PROGRAMS))
    ap.add_argument("--runs", type=int, default=5, help="runs per binary (default 5)")
    ap.add_argument("--no-upstream", action="store_true", help="time only zap's binaries")
    ap.add_argument("--out", help="write PATH.md and PATH.json")
    ap.add_argument("--machine-note", default=platform.machine(), help="describes the machine in the report")
    args = ap.parse_args()

    zap = os.path.abspath(args.compiler)
    builds = [("zap", lambda src, out: [zap, "build-exe", src, f"-femit-bin={out}"])]
    if not args.no_upstream:
        builds += [
            ("Debug", lambda src, out: [args.zig, "build-exe", "-fno-llvm", "-fno-lld", src, f"-femit-bin={out}"]),
            ("ReleaseSafe", lambda src, out: [args.zig, "build-exe", "-OReleaseSafe", src, f"-femit-bin={out}"]),
        ]

    results = {}
    with tempfile.TemporaryDirectory(prefix="zap-runtime-") as tmp:
        for prog in args.programs.split(","):
            src = os.path.join(PROGRAMS_DIR, f"{prog}.zig")
            results[prog] = {}
            outputs = {}
            for name, argv in builds:
                out = os.path.join(tmp, f"{prog}-{name}")
                compile_s = build(argv(src, out), tmp)
                median, lo, hi, output = run(out, args.runs)
                outputs[name] = output
                results[prog][name] = {"median_s": median, "min_s": lo, "max_s": hi, "compile_s": compile_s}
                print(f"{prog:6} {name:11} {fmt_ms(median):>9}  ({fmt_ms(lo)}–{fmt_ms(hi)})", flush=True)
            if len(set(outputs.values())) != 1:
                sys.exit(f"{prog}: outputs differ: {outputs}")

    names = [n for n, _ in builds]
    lines = [
        "# Run-time benchmarks",
        "",
        f"Median wall time of {args.runs} runs; `{os.path.basename(zap)}` against upstream zig 0.17.0. "
        f"{args.machine_note}, {os.cpu_count()} CPUs.",
        "",
        "| Program | " + " | ".join(names) + (" | zap / Debug | zap / ReleaseSafe |" if len(names) == 3 else " |"),
        "|---|" + "---:|" * (len(names) + (2 if len(names) == 3 else 0)),
    ]
    for prog, r in results.items():
        row = [fmt_ms(r[n]["median_s"]) for n in names]
        if len(names) == 3:
            z = r["zap"]["median_s"]
            row += [f"{z / r['Debug']['median_s']:.2f}×", f"{z / r['ReleaseSafe']['median_s']:.1f}×"]
        lines.append(f"| {prog} | " + " | ".join(row) + " |")
    report = "\n".join(lines) + "\n"
    print()
    print(report)
    if args.out:
        with open(args.out + ".md", "w") as f:
            f.write(report)
        with open(args.out + ".json", "w") as f:
            json.dump({"runs": args.runs, "machine_note": args.machine_note, "results": results}, f, indent=2)


if __name__ == "__main__":
    main()
