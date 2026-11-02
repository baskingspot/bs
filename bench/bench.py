#!/usr/bin/env python3
"""Compile-time benchmark harness for zap and upstream zig.

Times Debug builds of fixed workloads with a chosen compiler binary and writes
a Markdown report plus machine-readable JSON. See bench/README.md.
"""

import argparse
import datetime
import hashlib
import json
import os
import platform
import re
import select
import shlex
import shutil
import statistics
import struct
import subprocess
import sys
import tempfile
import time

BENCH_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(BENCH_DIR)

VAXIS_URL = "https://github.com/rockorager/libvaxis"
# libvaxis main as of 2026-10-31; its build.zig.zon declares minimum_zig_version 0.17.0
# and it builds unpatched with zig 0.17.0.
VAXIS_COMMIT = "0620b34e091deaa6f64608922be3814147128dfb"
UUCODE_PKG = "uucode-0.2.0-ZZjBPm6FVgBcY-79AHV8ckQj86z0JwOyVyj89VeZrEiv"
ZIGIMG_PKG = "zigimg-0.1.0-8_eo2sBLGACBebrhQZUwRliZNSUyDn6szp99eip_6-Rw"

SCENARIOS = {
    "cold": "empty local and global caches",
    "cold-local": "empty local cache, warm global cache (compiler_rt, build runner)",
    "warm": "rebuild, no change",
    "edit-root": "rebuild after a one-line edit to a function body in the root file",
    "edit-lib": "rebuild after a one-line edit to a function body in a library file",
    "incr-cli-edit-root": "edit-root with -fincremental, one compiler process per build",
    "incr-cli-edit-lib": "edit-lib with -fincremental, one compiler process per build",
    "incr-edit-root": "edit-root, in-process incremental update (-fincremental, compiler kept alive)",
    "incr-edit-lib": "edit-lib, in-process incremental update (-fincremental, compiler kept alive)",
}
DEFAULT_SCENARIOS = list(SCENARIOS)
CORE_SCENARIOS = ["cold", "cold-local", "warm", "edit-root", "edit-lib"]

MODES = {
    "build-exe": "plain `zig build-exe` command with -M/--dep module flags",
    "zig-build": "`zig build` of the same executable (reference; needs upstream zig's build system)",
}

# Appended to the anchor line for each edit. It keeps the line count, so only
# one function body changes, and the value differs on every edit so no edit
# can hit a cache entry left by an earlier one.
EDIT_SUFFIX = " std.mem.doNotOptimizeAway(@as(u32, {n}));"


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def fmt_time(s):
    if s is None:
        return "–"
    if s >= 1:
        return f"{s:.2f} s"
    if s >= 0.01:
        return f"{s * 1000:.0f} ms"
    return f"{s * 1000:.1f} ms"


def fmt_rss(kb):
    if kb is None:
        return "–"
    return f"{kb / 1024:.0f} MiB"


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def rmtree(path):
    if os.path.lexists(path):
        shutil.rmtree(path)


def run_checked(argv, cwd, env=None):
    log(f"  $ {shlex.join(argv)}  (in {cwd})")
    p = subprocess.run(argv, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if p.returncode != 0:
        sys.exit(f"command failed ({p.returncode}): {shlex.join(argv)}\n{p.stdout[-4000:]}")
    return p.stdout


def run_timed(argv, cwd, env):
    """Run one build; return wall time, user+sys CPU, and peak RSS.

    Peak RSS comes from wait4: on Linux it is the largest RSS of any single
    process in the tree (the compiler itself for build-exe; the largest of
    the build runner and its compiler children for zig build).
    """
    with tempfile.TemporaryFile() as out:
        t0 = time.perf_counter()
        p = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=out)
        _, status, ru = os.wait4(p.pid, 0)
        wall = time.perf_counter() - t0
        p.returncode = os.waitstatus_to_exitcode(status)
        if p.returncode != 0:
            out.seek(0)
            sys.exit(f"build failed ({p.returncode}): {shlex.join(argv)} (in {cwd})\n"
                     f"{out.read()[-4000:].decode(errors='replace')}")
    return {"wall_s": wall, "cpu_s": ru.ru_utime + ru.ru_stime, "maxrss_kb": ru.ru_maxrss}


class Editor:
    """One-line function-body edits to a single anchor line of a file."""

    def __init__(self, path, anchor, counter):
        self.path = path
        self.anchor = anchor
        self.counter = counter
        with open(path) as f:
            self.original = f.read()
        lines = self.original.split("\n")
        hits = [i for i, line in enumerate(lines) if line == anchor]
        if len(hits) != 1:
            sys.exit(f"edit anchor must occur exactly once in {path}, found {len(hits)}: {anchor!r}")
        self.line_index = hits[0]

    def edit(self):
        n = next(self.counter)
        lines = self.original.split("\n")
        lines[self.line_index] = self.anchor + EDIT_SUFFIX.format(n=n)
        with open(self.path, "w") as f:
            f.write("\n".join(lines))

    def restore(self):
        with open(self.path, "w") as f:
            f.write(self.original)


def edit_counter():
    n = int(time.time() * 1000) % 2_000_000_000
    while True:
        n += 1
        yield n


class CompilerServer:
    """Drives `zig build-exe ... -fincremental --listen=-` over the compiler protocol.

    This is the protocol `zig build --watch` uses to keep one compiler process
    per artifact alive between rebuilds (std/zig/Client.zig, Server.zig).
    """

    TAG_EXIT, TAG_UPDATE = 0, 1  # client messages
    TAG_ERROR_BUNDLE, TAG_EMIT_DIGEST = 1, 2  # server messages

    def __init__(self, argv, cwd, env):
        self.stderr = tempfile.TemporaryFile()
        self.p = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=self.stderr)
        self.argv = argv

    def _read_exact(self, n, timeout=900):
        buf = b""
        fd = self.p.stdout.fileno()
        while len(buf) < n:
            ready, _, _ = select.select([fd], [], [], timeout)
            if not ready:
                self._fail("timed out waiting for the compiler")
            chunk = os.read(fd, n - len(buf))
            if not chunk:
                self._fail("compiler exited")
            buf += chunk
        return buf

    def _fail(self, why):
        self.stderr.seek(0)
        sys.exit(f"{why}: {shlex.join(self.argv)}\n{self.stderr.read()[-4000:].decode(errors='replace')}")

    def update(self):
        """Send one update; return (seconds, emitted digest hex)."""
        t0 = time.perf_counter()
        self.p.stdin.write(struct.pack("<II", self.TAG_UPDATE, 0))
        self.p.stdin.flush()
        digest = None
        while True:
            tag, length = struct.unpack("<II", self._read_exact(8))
            body = self._read_exact(length) if length else b""
            if tag == self.TAG_EMIT_DIGEST:
                digest = body[-16:].hex()
            elif tag == self.TAG_ERROR_BUNDLE:
                # The update ends with an error bundle; an empty one follows the
                # emit digest on success.
                elapsed = time.perf_counter() - t0
                if digest is None:
                    text = re.sub(rb"[^ -~]+", b" | ", body).decode()
                    self._fail(f"compile errors: {text[-2000:]}")
                return elapsed, digest

    def close(self):
        self.p.stdin.write(struct.pack("<II", self.TAG_EXIT, 0))
        self.p.stdin.flush()
        self.p.stdin.close()
        _, status, ru = os.wait4(self.p.pid, 0)
        self.p.returncode = os.waitstatus_to_exitcode(status)
        self.p.stdout.close()
        self.stderr.close()
        return ru


class Workload:
    """A workload: per-mode commands, cache dirs, edit anchors, and an output check."""

    name = ""
    description = ""

    def __init__(self, work, compiler, setup_zig):
        self.work = work
        self.compiler = compiler
        self.setup_zig = setup_zig
        self.dir = os.path.join(work, self.name)

    def modes(self):
        return list(self.commands)

    def cache_dirs(self, mode):
        c = self.commands[mode]
        return c["local_cache"], c["global_cache"]

    def env(self, mode):
        env = dict(os.environ)
        for k in list(env):
            if k.startswith("ZIG_"):
                del env[k]
        env.update(self.commands[mode].get("env", {}))
        return env

    def check_output(self, path):
        if not os.access(path, os.X_OK):
            sys.exit(f"missing build output {path}")


class Hello(Workload):
    name = "hello"
    description = "hello world through std.debug.print"

    def setup(self):
        os.makedirs(self.dir, exist_ok=True)
        shutil.copy(os.path.join(BENCH_DIR, "workloads", "hello", "hello.zig"), self.dir)
        # A private zig lib dir so the library edit can touch std without
        # changing the installed toolchain: std is copied, the rest symlinked.
        lib_src = zig_env(self.setup_zig)["lib_dir"]
        lib = os.path.join(self.dir, "zig-lib")
        rmtree(lib)
        os.makedirs(lib)
        for entry in sorted(os.listdir(lib_src)):
            src = os.path.join(lib_src, entry)
            if entry == "std":
                shutil.copytree(src, os.path.join(lib, entry), symlinks=True)
            else:
                os.symlink(src, os.path.join(lib, entry))
        self.commands = {
            "build-exe": {
                "cwd": self.dir,
                "argv": [self.compiler, "build-exe", "hello.zig", "--zig-lib-dir", "zig-lib",
                         "--cache-dir", "cache/local", "--global-cache-dir", "cache/global"],
                "local_cache": os.path.join(self.dir, "cache/local"),
                "global_cache": os.path.join(self.dir, "cache/global"),
                "output": os.path.join(self.dir, "hello"),
                "name": "hello",
            },
        }
        self.edits = {
            "root": (os.path.join(self.dir, "hello.zig"), '    std.debug.print("Hello, world!\\n", .{});'),
            "lib": (os.path.join(lib, "std", "debug.zig"),
                    "    stderr.file_writer.interface.print(fmt, args) catch return;"),
        }

    def check_output(self, path):
        p = subprocess.run([path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if p.returncode != 0 or "Hello, world!" not in p.stderr:
            sys.exit(f"{path} did not print the greeting: rc={p.returncode} stderr={p.stderr!r}")


class Vaxis(Workload):
    name = "vaxis"
    description = f"libvaxis {VAXIS_COMMIT[:12]} examples/text_input.zig"

    def setup(self):
        os.makedirs(self.dir, exist_ok=True)
        src = os.path.join(self.dir, "libvaxis")
        if not os.path.isdir(os.path.join(src, ".git")):
            run_checked(["git", "clone", "--quiet", VAXIS_URL, src], self.work)
        run_checked(["git", "checkout", "--quiet", "--force", "--detach", VAXIS_COMMIT], src)
        gen = os.path.join(self.dir, "gen")
        setup_cache = os.path.join(self.work, "setup-cache")
        setup_env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=os.path.join(setup_cache, "global"))
        if not (os.path.exists(os.path.join(gen, "tables.zig"))
                and os.path.isdir(os.path.join(src, "zig-pkg", UUCODE_PKG))):
            # Fetch the pinned dependencies into libvaxis/zig-pkg and run uucode's
            # table generator once with libvaxis's own build, then keep the
            # generated modules so the timed build-exe command needs no build system.
            local = os.path.join(setup_cache, "vaxis-local")
            rmtree(local)
            out = run_checked([self.setup_zig, "build", "-Dllvm=false", "--verbose", "--cache-dir", local],
                              src, setup_env)
            line = next((ln for ln in out.splitlines()
                         if "build-exe" in ln and "--name example-text_input" in ln), None)
            if line is None:
                sys.exit("could not find the example's build-exe command in zig build --verbose output")
            rmtree(gen)
            os.makedirs(gen)
            for mod in ("tables", "build_config"):
                m = re.search(rf"-M{mod}=(\S+)", line)
                shutil.copy(os.path.join(src, m.group(1)), os.path.join(gen, f"{mod}.zig"))
        wrapper = os.path.join(self.dir, "wrapper")
        os.makedirs(wrapper, exist_ok=True)
        for f in ("build.zig", "build.zig.zon"):
            shutil.copy(os.path.join(BENCH_DIR, "workloads", "vaxis-build", f), wrapper)
        if not os.path.isdir(os.path.join(wrapper, "zig-pkg", UUCODE_PKG)):
            run_checked([self.setup_zig, "build", "--cache-dir", os.path.join(setup_cache, "wrapper-local")],
                        wrapper, setup_env)

        u = f"zig-pkg/{UUCODE_PKG}/src"
        argv = [
            self.compiler, "build-exe",
            "--dep", "vaxis", "-Mroot=examples/text_input.zig",
            "--dep", "zigimg", "--dep", "uucode", "-Mvaxis=src/main.zig",
            f"-Mzigimg=zig-pkg/{ZIGIMG_PKG}/zigimg.zig",
            "--dep", "types.zig", "--dep", "config.zig", "--dep", "tables", f"-Muucode={u}/root.zig",
            f"-Mtypes.zig={u}/types.zig",
            "--dep", "types.zig", "--dep", "storage.zig", f"-Mconfig.zig={u}/config.zig",
            "--dep", "config.zig", "--dep", "storage.zig", "--dep", "build_config", "-Mtables=../gen/tables.zig",
            "--dep", "config.zig", f"-Mstorage.zig={u}/storage.zig",
            "--dep", "config.zig", "--dep", "storage.zig", "-Mbuild_config=../gen/build_config.zig",
            "--name", "example-text_input",
            "--cache-dir", "../cache/local", "--global-cache-dir", "../cache/global",
        ]
        self.commands = {
            "build-exe": {
                "cwd": src,
                "argv": argv,
                "local_cache": os.path.join(self.dir, "cache/local"),
                "global_cache": os.path.join(self.dir, "cache/global"),
                "output": os.path.join(src, "example-text_input"),
                "name": "example-text_input",
            },
            "zig-build": {
                "cwd": wrapper,
                "argv": [self.compiler, "build", "--cache-dir", "../build-cache/local"],
                "env": {"ZIG_GLOBAL_CACHE_DIR": "../build-cache/global"},
                "local_cache": os.path.join(self.dir, "build-cache/local"),
                "global_cache": os.path.join(self.dir, "build-cache/global"),
                "output": os.path.join(wrapper, "zig-out/bin/example-text_input"),
                "name": "example-text_input",
            },
        }
        self.edits = {
            "root": (os.path.join(src, "examples/text_input.zig"), "    const alloc = init.gpa;"),
            "lib": (os.path.join(src, "src/Vaxis.zig"), "    var started: bool = false;"),
        }


WORKLOADS = {"hello": Hello, "vaxis": Vaxis}


def zig_env(zig):
    return json_from_zon(subprocess.run([zig, "env"], stdout=subprocess.PIPE, text=True, check=True).stdout)


def json_from_zon(text):
    # `zig env` prints a flat ZON struct; pull out the string fields.
    return dict(re.findall(r'\.(\w+) = "([^"]*)"', text))


def compiler_info(compiler, work):
    info = {"path": shutil.which(compiler) or compiler}
    info["realpath"] = os.path.realpath(info["path"])
    p = subprocess.run([compiler, "version"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    info["version"] = p.stdout.strip() if p.returncode == 0 else None
    # Which backend does a default Debug build use? Ask the compiled program.
    probe = os.path.join(work, "probe")
    rmtree(probe)
    os.makedirs(probe)
    with open(os.path.join(probe, "probe.zig"), "w") as f:
        f.write('const std = @import("std");\nconst builtin = @import("builtin");\n'
                'pub fn main() void {\n'
                '    std.debug.print("{t} {t} {t}\\n", .{ builtin.zig_backend, builtin.mode, builtin.object_format });\n'
                '}\n')
    p = subprocess.run([compiler, "build-exe", "probe.zig", "--cache-dir", "c", "--global-cache-dir", "g"],
                       cwd=probe, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if p.returncode == 0:
        r = subprocess.run(["./probe"], cwd=probe, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        backend, mode, ofmt = (r.stderr.split() + [None] * 3)[:3]
        info.update(default_backend=backend, default_mode=mode, object_format=ofmt)
    else:
        info["probe_error"] = p.stdout[-2000:]
    rmtree(probe)
    return info


def machine_info(note):
    info = {"note": note, "logical_cpus": os.cpu_count(), "kernel": platform.release(),
            "os": platform.system(), "arch": platform.machine(), "python": platform.python_version()}
    try:
        with open("/proc/cpuinfo") as f:
            m = re.search(r"model name\s*:\s*(.*)", f.read())
            info["cpu_model"] = m.group(1).strip() if m else None
        with open("/proc/meminfo") as f:
            m = re.search(r"MemTotal:\s*(\d+) kB", f.read())
            info["mem_total_gib"] = round(int(m.group(1)) / 1024 / 1024, 1)
    except OSError:
        pass
    return info


def calibrate():
    """Time a fixed single-threaded CPU loop (best of 5).

    Shared VMs change speed over time; this number, taken before and after
    the benchmarks, shows whether two reports ran on a comparably fast machine.
    """
    best = None
    for _ in range(5):
        t0 = time.perf_counter()
        x = 0
        for i in range(3_000_000):
            x ^= i * 7
        elapsed = time.perf_counter() - t0
        best = elapsed if best is None else min(best, elapsed)
    return best


def summarize(runs):
    walls = [r["wall_s"] for r in runs]
    cpus = [r["cpu_s"] for r in runs]
    rss = [r["maxrss_kb"] for r in runs]
    return {
        "n": len(runs),
        "median_s": statistics.median(walls),
        "min_s": min(walls),
        "max_s": max(walls),
        "mean_s": statistics.fmean(walls),
        "stdev_s": statistics.stdev(walls) if len(walls) > 1 else 0.0,
        "cpu_median_s": statistics.median(cpus) if None not in cpus else None,
        "maxrss_median_kb": statistics.median(rss) if None not in rss else None,
        "maxrss_max_kb": max(rss) if None not in rss else None,
    }


def bench_scenario(wl, mode, scenario, runs, counter):
    """Return (list of run measurements, extra info) for one scenario."""
    cmd = wl.commands[mode]
    argv, cwd, env = cmd["argv"], cmd["cwd"], wl.env(mode)
    local, glob = wl.cache_dirs(mode)
    out = cmd["output"]
    extra = {}

    def build(a=argv):
        r = run_timed(a, cwd, env)
        wl.check_output(out)
        return r

    if scenario == "cold":
        results = []
        for _ in range(runs):
            rmtree(local)
            rmtree(glob)
            results.append(build())
        return results, extra
    if scenario == "cold-local":
        build()  # make sure the global cache is warm
        results = []
        for _ in range(runs):
            rmtree(local)
            results.append(build())
        return results, extra
    if scenario == "warm":
        build()
        return [build() for _ in range(runs)], extra

    which = scenario.rsplit("-", 1)[1]  # root | lib
    editor = Editor(*wl.edits[which], counter)
    try:
        if scenario.startswith("incr-cli-"):
            a = argv + ["-fincremental"]
            build(a)
            results = []
            for _ in range(runs):
                before = sha256_file(out)
                editor.edit()
                results.append(build(a))
                if sha256_file(out) == before:
                    sys.exit(f"{scenario}: output did not change after an edit")
            return results, extra
        if scenario.startswith("incr-"):
            build()  # warm the global cache so the session's first update is a plain full build
            server = CompilerServer(argv + ["-fincremental", "--listen=-"], cwd, env)
            extra["initial_update_s"], digest = server.update()
            emitted = os.path.join(local, "o", digest, cmd["name"])
            wl.check_output(emitted)
            results = []
            for _ in range(runs):
                before = sha256_file(emitted)
                editor.edit()
                elapsed, digest = server.update()
                emitted = os.path.join(local, "o", digest, cmd["name"])
                wl.check_output(emitted)
                if sha256_file(emitted) == before:
                    sys.exit(f"{scenario}: output did not change after an edit")
                results.append({"wall_s": elapsed, "cpu_s": None, "maxrss_kb": None})
            ru = server.close()
            extra["session_cpu_s"] = ru.ru_utime + ru.ru_stime
            extra["session_maxrss_kb"] = ru.ru_maxrss
            for r in results:
                # Only the whole session's peak is observable from outside.
                r["maxrss_kb"] = ru.ru_maxrss
            return results, extra
        build()
        results = []
        for _ in range(runs):
            before = sha256_file(out)
            editor.edit()
            results.append(build())
            if sha256_file(out) == before:
                sys.exit(f"{scenario}: output did not change after an edit")
        return results, extra
    finally:
        editor.restore()


def skip_reason(mode, scenario):
    if mode == "zig-build" and scenario.startswith("incr-") and not scenario.startswith("incr-cli-"):
        return ("In-process incremental through `zig build` needs `--watch`, which the harness does not drive; "
                "on Linux older than 6.5 it panics after the first build anyway (lib/compiler/Maker/Watch.zig "
                "calls name_to_handle_at with AT_HANDLE_FID, the kernel returns EINVAL, std.posix treats that "
                "as unreachable). The build-exe incr-* rows use the same compiler protocol `--watch` uses")
    return None


def render_markdown(report):
    m, c = report["machine"], report["compiler"]
    lines = [f"# Compile-time benchmark: {c.get('version') or c['path']}", ""]
    lines += [f"Generated {report['generated']} by `bench/bench.py` "
              f"(zap {report['harness_commit'] or 'uncommitted'}).", ""]
    lines += ["## Machine and compiler", ""]
    lines += [f"- Machine: {m.get('note') or ''} {m.get('cpu_model')}, {m['logical_cpus']} logical CPUs, "
              f"{m.get('mem_total_gib')} GiB RAM, {m['os']} {m['kernel']} {m['arch']}".replace("  ", " ")]
    lines += [f"- Compiler: `{c['realpath']}`, version `{c.get('version')}`"]
    lines += [f"- Default Debug build (no backend flags) reports `builtin.zig_backend = .{c.get('default_backend')}`, "
              f"mode `{c.get('default_mode')}`, object format `{c.get('object_format')}`"]
    cal = report.get("calibration_s", {})
    lines += [f"- CPU calibration (fixed pure-Python loop, best of 5, lower is faster): "
              f"{fmt_time(cal.get('start'))} before the benchmarks, {fmt_time(cal.get('end'))} after"]
    lines += [f"- Runs: {report['runs']} per scenario, {report['cold_runs']} for cold build-exe, "
              f"{report['build_cold_runs']} for cold zig build", ""]
    lines += ["Wall time is the median over the runs with min–max and sample standard deviation. "
              "CPU is user+sys of the whole process tree. Peak RSS is the largest single process in "
              "the tree (median over runs). For in-process incremental rows, time is per update and "
              "RSS/CPU cover the whole compiler session, including its initial full build.", ""]
    for wname, w in report["workloads"].items():
        lines += [f"## {wname}: {w['description']}", ""]
        lines += ["| Mode | Scenario | Runs | Median | Min–max | Stdev | CPU | Peak RSS |",
                  "|---|---|---:|---:|---:|---:|---:|---:|"]
        for r in report["results"]:
            if r["workload"] != wname:
                continue
            s = r["stats"]
            cpu = s["cpu_median_s"]
            if cpu is None and "session_cpu_s" in r["extra"]:
                cpu_txt = f"{fmt_time(r['extra']['session_cpu_s'])} (session)"
            else:
                cpu_txt = fmt_time(cpu)
            lines.append(f"| {r['mode']} | {r['scenario']} | {s['n']} | **{fmt_time(s['median_s'])}** | "
                         f"{fmt_time(s['min_s'])}–{fmt_time(s['max_s'])} | {fmt_time(s['stdev_s'])} | "
                         f"{cpu_txt} | {fmt_rss(s['maxrss_median_kb'])} |")
        skipped = [r for r in report["skipped"] if r["workload"] == wname]
        for r in skipped:
            lines.append(f"| {r['mode']} | {r['scenario']} | – | not measured | | | | |")
        lines.append("")
        incr = [r for r in report["results"] if r["workload"] == wname and "initial_update_s" in r["extra"]]
        for r in incr:
            lines.append(f"- `{r['mode']} {r['scenario']}`: the session's first update (a full build) "
                         f"took {fmt_time(r['extra']['initial_update_s'])}.")
        for reason in dict.fromkeys(r["reason"] for r in skipped):
            names = ", ".join(f"`{r['mode']} {r['scenario']}`" for r in skipped if r["reason"] == reason)
            lines.append(f"- Not measured: {names}. {reason}.")
        if incr or skipped:
            lines.append("")
        lines += ["Commands (run from the working directory shown, relative to the harness work dir):", ""]
        for mode, cmd in w["commands"].items():
            env = " ".join(f"{k}={v}" for k, v in cmd.get("env", {}).items())
            lines += [f"- {mode}, in `{cmd['cwd']}`:", "", "  ```sh",
                      f"  {(env + ' ') if env else ''}{shlex.join(cmd['argv'])}", "  ```", ""]
        lines += ["Edits (the anchor line gets ` std.mem.doNotOptimizeAway(@as(u32, N));` appended, "
                  "with a new N for every build):", ""]
        for which, e in w["edits"].items():
            lines.append(f"- {which}: `{e['file']}` line {e['line']}: `{e['anchor'].strip()}`")
        lines.append("")
    lines += ["## Scenarios", ""]
    for k, v in SCENARIOS.items():
        lines.append(f"- `{k}`: {v}")
    lines += ["", "In-process incremental rows append `-fincremental --listen=-` to the build-exe command and "
              "send compiler-protocol `update` messages, as `zig build --watch` does; `incr-cli-*` rows append "
              "`-fincremental` only.", ""]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--compiler", default="zig", help="compiler binary to time (zig or zap; default: zig on PATH)")
    ap.add_argument("--setup-zig", default="zig",
                    help="upstream zig 0.17.0 used to prepare workloads (fetch, generate); never timed")
    ap.add_argument("--workloads", default=",".join(WORKLOADS), help="comma-separated: " + ",".join(WORKLOADS))
    ap.add_argument("--modes", default=None,
                    help="comma-separated: build-exe,zig-build (default: both for zig, build-exe otherwise)")
    ap.add_argument("--scenarios", default=None,
                    help="comma-separated, or 'core' (default: all for zig, core otherwise): " + ",".join(SCENARIOS))
    ap.add_argument("--runs", type=int, default=10, help="runs per warm/edit scenario (default 10)")
    ap.add_argument("--cold-runs", type=int, default=5, help="runs per cold build-exe scenario (default 5)")
    ap.add_argument("--build-cold-runs", type=int, default=3,
                    help="runs per cold zig build scenario (default 3; each rebuilds the build runner)")
    ap.add_argument("--work-dir", default=os.path.join(BENCH_DIR, ".work"), help="scratch dir (default bench/.work)")
    ap.add_argument("--out", default=None, help="output path without extension (default bench/results/<date>-<compiler>)")
    ap.add_argument("--machine-note", default="", help="free-form machine description for the report")
    args = ap.parse_args()

    work = os.path.abspath(args.work_dir)
    os.makedirs(work, exist_ok=True)
    compiler = shutil.which(args.compiler) or os.path.abspath(args.compiler)
    setup_zig = shutil.which(args.setup_zig) or os.path.abspath(args.setup_zig)
    cinfo = compiler_info(compiler, work)
    is_upstream = os.path.realpath(compiler) == os.path.realpath(setup_zig)
    modes = (args.modes.split(",") if args.modes else (list(MODES) if is_upstream else ["build-exe"]))
    if args.scenarios in (None, ""):
        scenarios = DEFAULT_SCENARIOS if is_upstream else CORE_SCENARIOS
    elif args.scenarios == "core":
        scenarios = CORE_SCENARIOS
    else:
        scenarios = args.scenarios.split(",")
    for s in scenarios:
        if s not in SCENARIOS:
            sys.exit(f"unknown scenario {s}")
    log(f"compiler: {compiler} ({cinfo.get('version')}), default backend {cinfo.get('default_backend')}")

    counter = edit_counter()
    report = {
        "schema": 1,
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "harness_commit": subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=REPO_DIR,
                                         stdout=subprocess.PIPE, text=True).stdout.strip() or None,
        "machine": machine_info(args.machine_note),
        "compiler": cinfo,
        "runs": args.runs, "cold_runs": args.cold_runs, "build_cold_runs": args.build_cold_runs,
        "scenario_descriptions": SCENARIOS,
        "calibration_s": {"start": calibrate()},
        "workloads": {}, "results": [], "skipped": [],
    }
    for wname in args.workloads.split(","):
        wl = WORKLOADS[wname](work, compiler, setup_zig)
        log(f"== setup {wname}")
        wl.setup()
        wmodes = [m for m in modes if m in wl.commands]
        report["workloads"][wname] = {
            "description": wl.description,
            "commands": {m: {"cwd": os.path.relpath(wl.commands[m]["cwd"], work),
                             "argv": [os.path.basename(wl.commands[m]["argv"][0])] + wl.commands[m]["argv"][1:],
                             **({"env": wl.commands[m]["env"]} if "env" in wl.commands[m] else {})}
                         for m in wmodes},
            "edits": {k: {"file": os.path.relpath(path, work), "anchor": anchor,
                          "line": Editor(path, anchor, counter).line_index + 1}
                      for k, (path, anchor) in wl.edits.items()},
        }
        if wname == "vaxis":
            report["workloads"][wname]["libvaxis"] = {"url": VAXIS_URL, "commit": VAXIS_COMMIT, "patched": False}
        for mode in wmodes:
            for scenario in scenarios:
                reason = skip_reason(mode, scenario)
                if reason:
                    report["skipped"].append({"workload": wname, "mode": mode, "scenario": scenario,
                                              "reason": reason})
                    continue
                runs = args.runs
                if scenario == "cold":
                    runs = args.build_cold_runs if mode == "zig-build" else args.cold_runs
                log(f"== {wname} {mode} {scenario} x{runs}")
                results, extra = bench_scenario(wl, mode, scenario, runs, counter)
                stats = summarize(results)
                log(f"   median {fmt_time(stats['median_s'])} "
                    f"[{fmt_time(stats['min_s'])}–{fmt_time(stats['max_s'])}] rss {fmt_rss(stats['maxrss_median_kb'])}")
                report["results"].append({"workload": wname, "mode": mode, "scenario": scenario,
                                          "runs": results, "stats": stats, "extra": extra})

    report["calibration_s"]["end"] = calibrate()
    out = args.out or os.path.join(
        BENCH_DIR, "results",
        f"{datetime.date.today().isoformat()}-{os.path.basename(compiler)}-{cinfo.get('version') or 'unknown'}")
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out + ".json", "w") as f:
        json.dump(report, f, indent=1)
        f.write("\n")
    with open(out + ".md", "w") as f:
        f.write(render_markdown(report))
    log(f"wrote {out}.md and {out}.json")


if __name__ == "__main__":
    main()
