#!/usr/bin/env python3
"""Run-time benchmarks on real programs: the speed of the code bs generates
where microbenchmarks can mislead.

Each workload builds a real program with bs and, unless --no-upstream, with
upstream zig 0.17.1 in Debug (self-hosted x86_64 backend; LLVM on
aarch64-macos) and ReleaseSafe (LLVM), checks that the builds print the
same output, and reports the median wall time of each:

- zig-fmt:  upstream's compiler (src/main.zig without LLVM), built by each
            compiler, running `zig fmt --check` over upstream's lib/std.
- zig-sema: the same binary analyzing hello.zig (`build-exe -fno-emit-bin`)
            with an empty cache: Sema, the InternPool, and std's hash maps.
- vaxis:    bench/realworld/vaxis_render.zig, libvaxis's layout and render
            path into memory (the libvaxis checkout bench.py sets up).
- zls-test: zls's test suite (the corpus's pinned zls; `tools/corpus/run.py
            --projects zls --list` records its command line).
- corpus:   the corpus targets in `Corpus.TARGETS` with a CPU-bound run,
            built from their recorded command lines (`--workloads corpus`
            runs them all). A mode that fails to build or run is reported
            as failing; the other modes still run.

With --callgrind, every build also gets -fno-valgrind, and each binary runs
once more under callgrind. That run reports its instructions (Ir), and how
many of them were spent in std's heap.SafeAllocator.captureStackTrace, the
stack trace a Debug build records on every allocation and free. Which
return addresses collide in std's unwinder cache depends on code layout, so
that part swings by several billion Ir between builds whose code is the
same (zig-sema, zls-test); compare codegen changes on the Ir without it.

Upstream's builds of a workload do not change, so they are kept in the work
directory and reused. The compiler has no ReleaseSafe build: LLVM needs more
memory for it than an orb's 7 GB.
"""

import argparse
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from typing import ClassVar

BENCH_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(BENCH_DIR)
sys.path.insert(0, BENCH_DIR)
import bench

WORKLOADS = ["zig-fmt", "zig-sema", "vaxis", "zls-test"]
# Upstream's Debug default: the self-hosted backend on x86_64-linux, LLVM on
# aarch64-macos, where its self-hosted backend is unfinished.
NO_LLVM = [] if sys.platform == "darwin" else ["-fno-llvm", "-fno-lld"]
MODES = {
    "bs": [],
    "Debug": NO_LLVM,
    "ReleaseSafe": ["-OReleaseSafe"],
}


class BuildError(Exception):
    """A workload that does not build or run as expected in one mode."""


def build(argv, cwd, out):
    if os.path.exists(out):
        os.remove(out)
    t0 = time.perf_counter()
    r = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, env=dict(os.environ, BS_CACHE="off"), check=False)
    if r.returncode != 0:
        raise BuildError(f"build failed in {cwd}: {' '.join(argv)}\n{r.stdout[-4000:]}{r.stderr[-4000:]}")
    return time.perf_counter() - t0


def with_mode(argv, mode):
    """`argv` (a build-exe or test command line) for `mode`: bs's as is,
    upstream's with its optimize mode and backend."""
    if mode == "bs":
        return argv
    res = [w for w in argv if not w.startswith("-O") and (NO_LLVM or w not in ("-fno-llvm", "-fno-lld"))]
    return res[:2] + MODES[mode] + res[2:]


class Workload:
    modes: ClassVar[list[str]] = list(MODES)

    def __init__(self, work, zig):
        self.work = work
        self.zig = zig

    def run_once(self, binary):
        """Runs the program once; returns (seconds, output to compare)."""
        with tempfile.TemporaryDirectory(prefix="bs-rw-") as tmp:
            argv = [binary if a == "{bin}" else a.replace("{tmp}", tmp) for a in self.run_argv]
            t0 = time.perf_counter()
            r = subprocess.run(
                argv, cwd=self.run_cwd, stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False
            )
            elapsed = time.perf_counter() - t0
        if not self.run_ok(r.returncode):
            raise BuildError(f"{' '.join(argv)} exited with {r.returncode}:\n{r.stderr[-4000:]}")
        return elapsed, self.output(r.stdout + r.stderr)

    def run_ok(self, code):
        return code == 0

    def output(self, text):
        return text


class ZigCompiler(Workload):
    def setup(self):
        # Copied again every run: upstream/ follows the pinned release.
        d = os.path.join(self.work, "zig-src")
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(os.path.join(REPO_DIR, "upstream", "src"), os.path.join(d, "src"))
        shutil.copy(os.path.join(BENCH_DIR, "workloads", "zig", "build_options.zig"), d)
        self.cwd = d
        self.lib = os.path.join(REPO_DIR, "upstream", "lib")

    def build_argv(self, compiler, mode, out):
        return with_mode(
            [
                compiler,
                "build-exe",
                "--stack",
                "48234496",
                "-fno-sanitize-thread",
                "-Odebug",
                "--dep",
                "build_options",
                "-Mroot=src/main.zig",
                "-Mbuild_options=build_options.zig",
                "--name",
                "zig",
                f"-femit-bin={out}",
                "--cache-dir",
                os.path.join(self.work, "cache", mode, "local"),
                "--global-cache-dir",
                os.path.join(self.work, "cache", mode, "global"),
            ],
            mode,
        )

    # Both zig workloads share the compiler's build.
    key = "zig"
    modes: ClassVar[list[str]] = ["bs", "Debug"]


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
        self.run_argv = [
            "{bin}",
            "build-exe",
            "-fno-emit-bin",
            os.path.join(BENCH_DIR, "workloads", "hello", "hello.zig"),
            "--zig-lib-dir",
            self.lib,
            "--cache-dir",
            "{tmp}",
            "--global-cache-dir",
            "{tmp}",
        ]


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
            res.append(
                "-Mroot=" + os.path.join(BENCH_DIR, "realworld", "vaxis_render.zig") if w.startswith("-Mroot=") else w
            )
            i += 1
        self.flags = res
        self.cwd = cmd["cwd"]
        self.run_cwd = self.cwd
        self.run_argv = ["{bin}"]

    def build_argv(self, compiler, mode, out):
        return with_mode(
            [
                compiler,
                "build-exe",
                *self.flags,
                f"-femit-bin={out}",
                "--cache-dir",
                os.path.join(self.work, "cache", mode, "local"),
                "--global-cache-dir",
                os.path.join(self.work, "cache", mode, "global"),
            ],
            mode,
        )


class ZlsTest(Workload):
    name = "zls-test"
    key = "zls-test"

    def setup(self):
        corpus = os.path.join(REPO_DIR, "tools", "corpus", ".work")
        cmds = os.path.join(corpus, "commands", "zls.json")
        if not os.path.exists(cmds):
            subprocess.run(
                [sys.executable, os.path.join(REPO_DIR, "tools", "corpus", "run.py"), "--projects", "zls", "--list"],
                check=True,
            )
        with open(cmds) as f:
            words = json.load(f)["test"]
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
        return with_mode(
            [
                compiler,
                "test",
                *self.flags,
                "--test-no-exec",
                f"-femit-bin={out}",
                "--cache-dir",
                os.path.join(self.work, "cache", mode, "local"),
            ],
            mode,
        )

    def output(self, text):
        # The summary line; the per-test lines' order is the same, but their
        # timing-dependent progress output is not compared.
        lines = [ln for ln in text.splitlines() if "passed;" in ln]
        return lines[-1] if lines else text


class Corpus(Workload):
    """A corpus target (tools/corpus) with a CPU-bound run: built from its
    recorded command line, run with the manifest's arguments."""

    # name: (project, target, the exit status every build's run gives[,
    # run arguments instead of the manifest's]).
    TARGETS: ClassVar[dict] = {
        "translate-c": ("zig-compiler", "translate-c", 0),
        "uucode-gen": ("ghostty", "uucode_generate", 0),
        "vulkan-gen": ("vulkan-zig", "vulkan-zig-generator", 0),
        "zigimg-test": ("zigimg", "zigimgtest", 0),
        # json-zig has three `test` steps; this is its property tests'.
        "json-zig-test": ("json-zig", "test:src/document_property.zig", 0),
        "msgpack-test": ("zig-msgpack", "test", 0),
        "tls-test": ("tls.zig", "test", 0),
        "hpke-test": ("zig-hpke", "test", 1),
        "zedis-test": ("zedis", "test-unit", 0),
        "yaml-test": ("zig-libs", "yaml", 0),
        "jinja-test": ("zig-libs", "jinja", 0),
        "json5-test": ("zig-libs", "json5", 0),
        "ini-test": ("zig-libs", "ini", 0),
        "tar-test": ("zig-libs", "tar", 0),
        "trie-test": ("zig-libs", "trie", 0),
        "qr-test": ("zig-libs", "qr", 0),
        "loc": ("zigcli", "loc", 0),
        "zwasm-keccak": ("zwasm", "zwasm", 0, ["run", "--engine", "interp", "bench/runners/wasm/shootout/keccak.wasm"]),
        "zwasm-gimli": ("zwasm", "zwasm", 0, ["run", "--engine", "interp", "bench/runners/wasm/shootout/gimli.wasm"]),
        "zwasm-memmove": (
            "zwasm",
            "zwasm",
            0,
            ["run", "--engine", "interp", "bench/runners/wasm/shootout/memmove.wasm"],
        ),
    }

    def __init__(self, work, zig, name):
        super().__init__(work, zig)
        self.name = name
        self.project, self.target, self.exit, *self.args = self.TARGETS[name]
        # Workloads that run one target differently share its builds.
        self.key = f"{self.project}-{self.target}".replace("/", "_")

    def setup(self):
        sys.path.insert(0, os.path.join(REPO_DIR, "tools", "corpus"))
        import run as corpus

        self.corpus = corpus
        with open(os.path.join(REPO_DIR, "tools", "corpus", "manifest.json")) as f:
            manifest = json.load(f)
        self.proj = next(p for p in manifest["projects"] if p["name"] == self.project)
        # A target the corpus does not build itself (json-zig's property
        # tests) runs with no arguments in the project's directory.
        tgt = next((t for t in self.proj["targets"] if t["name"] == self.target), {})
        self.cwd, self.cmds = corpus.setup(self.proj, self.zig, False)
        self.words = self.cmds[self.target]
        self.is_test = self.words[1] == "test"
        self.run_cwd = os.path.join(self.cwd, corpus.expand(tgt.get("cwd", "."), self.proj))
        if os.path.isfile(self.run_cwd):
            self.run_cwd = os.path.dirname(self.run_cwd)
        args = self.args[0] if self.args else tgt.get("run", [])
        self.run_argv = ["{bin}", *(corpus.expand(a, self.proj) for a in args)]

    def build_argv(self, compiler, mode, out):
        cache = os.path.join(self.work, "cache", self.key, mode)
        shutil.rmtree(cache, ignore_errors=True)
        words, err = self.corpus.translate(compiler, self.words, self.cmds, cache, self.cwd)
        if words is None:
            raise BuildError(f"translate-c failed:\n{err[-4000:]}")
        argv = self.corpus.compile_argv(compiler, words, cache, out)
        if mode == "ReleaseSafe":
            # LLVM: the corpus's command lines ask for the self-hosted backend.
            argv = [w for w in argv if w != "-fno-llvm"]
        return with_mode(argv, mode)

    def run_ok(self, code):
        return code == self.exit

    def output(self, text):
        if not self.is_test:
            return text
        lines = [ln for ln in text.splitlines() if re.search(r"passed|failed", ln)]
        return lines[-1] if lines else text


CLASSES = {"zig-fmt": ZigFmt, "zig-sema": ZigSema, "vaxis": Vaxis, "zls-test": ZlsTest}
for _name in Corpus.TARGETS:
    CLASSES[_name] = lambda work, zig, n=_name: Corpus(work, zig, n)


def fmt_s(s):
    return f"{s:.2f} s" if s >= 1 else f"{s * 1000:.0f} ms"


def fmt_ir(n):
    return f"{n / 1e9:.3f}G" if n >= 1e8 else f"{n / 1e6:.1f}M"


# The Debug-only stack trace std's SafeAllocator records per allocation and
# free; its cost depends on code layout (see the module docstring).
CAPTURE = re.compile(r":heap\.SafeAllocator\.captureStackTrace(?: \[|$)")


def callgrind(w, binary):
    """Runs the program once under callgrind; returns (Ir, Ir in stack capture)."""
    with tempfile.TemporaryDirectory(prefix="bs-rw-cg-") as tmp:
        out = os.path.join(tmp, "callgrind.out")
        argv = [binary if a == "{bin}" else a.replace("{tmp}", tmp) for a in w.run_argv]
        r = subprocess.run(
            ["valgrind", "--tool=callgrind", "--main-stacksize=1073741824", f"--callgrind-out-file={out}", *argv],
            cwd=w.run_cwd,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=False,
        )
        if not w.run_ok(r.returncode):
            raise BuildError(f"callgrind run of {binary} exited with {r.returncode}:\n{r.stderr[-4000:]}")
        ann = subprocess.run(
            ["callgrind_annotate", "--inclusive=yes", "--threshold=100", out], capture_output=True, check=True
        ).stdout.decode("utf-8", "replace")
    total = capture = 0
    for line in ann.splitlines():
        m = re.match(r"\s*([\d,]+) \(", line)
        if not m:
            continue
        n = int(m.group(1).replace(",", ""))
        if "PROGRAM TOTALS" in line:
            total = n
        elif CAPTURE.search(line):
            capture = max(capture, n)
    return total, capture


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--compiler", default="zig-out/bin/bs", help="bs binary (default: zig-out/bin/bs)")
    ap.add_argument("--zig", default="zig", help="upstream zig 0.17.1 (default: zig on PATH)")
    ap.add_argument(
        "--workloads",
        default=",".join(WORKLOADS),
        help="comma-separated subset of "
        + ",".join(WORKLOADS)
        + ", corpus targets ("
        + ",".join(Corpus.TARGETS)
        + "), or corpus for all of those",
    )
    ap.add_argument("--runs", type=int, default=5, help="runs per binary (default 5)")
    ap.add_argument("--no-upstream", action="store_true", help="time only bs's builds")
    ap.add_argument(
        "--work",
        default=os.path.join(BENCH_DIR, ".work", "realworld"),
        help="work directory; keeps upstream's builds (default: bench/.work/realworld)",
    )
    ap.add_argument("--out", help="write PATH.json")
    ap.add_argument(
        "--callgrind",
        action="store_true",
        help="build with -fno-valgrind and also report each binary's callgrind Ir, with and without std's stack capture",
    )
    args = ap.parse_args()

    bs = os.path.abspath(args.compiler)
    zig = shutil.which(args.zig) or args.zig
    os.makedirs(args.work, exist_ok=True)
    all_modes = ["bs"] if args.no_upstream else list(MODES)
    results = {}
    built = {}
    names = []
    for wname in args.workloads.split(","):
        names += list(Corpus.TARGETS) if wname == "corpus" else [wname]
    for wname in names:
        w = CLASSES[wname](args.work, zig)
        w.setup()
        modes = [m for m in all_modes if m in w.modes]
        results[wname] = {}
        outputs = {}
        for mode in modes:
            out = os.path.join(args.work, "bin", f"{w.key}-{mode}{'-novg' if args.callgrind else ''}")
            os.makedirs(os.path.dirname(out), exist_ok=True)
            compiler = bs if mode == "bs" else zig
            try:
                if (w.key, mode) not in built and (mode == "bs" or not os.path.exists(out)):
                    print(f"building {w.key} with {mode}...", file=sys.stderr, flush=True)
                    argv = w.build_argv(compiler, mode, out)
                    if args.callgrind:
                        argv.insert(2, "-fno-valgrind")
                    built[(w.key, mode)] = build(argv, w.cwd, out)
                times = []
                for _ in range(args.runs):
                    t, o = w.run_once(out)
                    times.append(t)
                    if mode in outputs and outputs[mode] != o:
                        raise BuildError(f"{wname} ({mode}) printed different output across runs")
                    outputs[mode] = o
            except BuildError as e:
                # One mode failing (upstream's self-hosted backend refusing
                # zmath, say) leaves the others' times.
                print(f"{wname} ({mode}): {e}", file=sys.stderr, flush=True)
                results[wname][mode] = {"error": str(e).splitlines()[0]}
                continue
            results[wname][mode] = {"median": statistics.median(times), "min": min(times), "max": max(times)}
            if args.callgrind:
                print(f"callgrind: {wname} ({mode})...", file=sys.stderr, flush=True)
                try:
                    ir, capture = callgrind(w, out)
                except BuildError as e:
                    print(f"{wname} ({mode}): {e}", file=sys.stderr, flush=True)
                    continue
                results[wname][mode].update(ir=ir, capture_ir=capture)
        if len(set(outputs.values())) > 1:
            print(f"{wname}: the builds printed different output: {outputs}", file=sys.stderr, flush=True)
            results[wname]["output_differs"] = True

    def ok(r, m):
        return m in r and "median" in r[m]

    def cell(r, m):
        if m in r and "error" in r[m]:
            return "fails"
        return f"{fmt_s(r[m]['median'])} (min {fmt_s(r[m]['min'])})" if ok(r, m) else "-"

    def ratio(r, m):
        return f"{r['bs']['median'] / r[m]['median']:.2f}x" if ok(r, m) and ok(r, "bs") else "-"

    def ir_cell(r, m, key):
        return fmt_ir(r[m][key]) if m in r and key in r[m] else "-"

    # With --callgrind, each wall time has its stack capture's Ir beside
    # it, which tells a wall time that moved with layout from one that
    # moved with the code.
    cols = [f"{m} | {m} capture Ir" if args.callgrind else m for m in all_modes]
    header = "| workload | " + " | ".join(cols) + "".join(f" | bs / {m}" for m in all_modes[1:]) + " |"
    print(header)
    print("|" + "---|" * (header.count("|") - 1))
    for wname, r in results.items():
        cells = [cell(r, m) + (f" | {ir_cell(r, m, 'capture_ir')}" if args.callgrind else "") for m in all_modes]
        print(
            f"| {wname}{' (output differs)' if r.get('output_differs') else ''} | "
            + " | ".join(cells)
            + "".join(f" | {ratio(r, m)}" for m in all_modes[1:])
            + " |"
        )
    if args.callgrind:
        # Ir without the stack capture is the number to compare codegen on.
        for r in results.values():
            for v in r.values():
                if isinstance(v, dict) and "ir" in v:
                    v["ir_without_capture"] = v["ir"] - v["capture_ir"]
        print()
        header = "| workload | " + " | ".join(f"{m} Ir without capture | {m} Ir" for m in all_modes) + " |"
        print(header)
        print("|" + "---|" * (header.count("|") - 1))
        for wname, r in results.items():
            cells = [f"{ir_cell(r, m, 'ir_without_capture')} | {ir_cell(r, m, 'ir')}" for m in all_modes]
            print(f"| {wname} | " + " | ".join(cells) + " |")
    if args.out:
        with open(args.out, "w") as f:
            json.dump({"compiler": bs, "runs": args.runs, "results": results}, f, indent=1)


if __name__ == "__main__":
    main()
