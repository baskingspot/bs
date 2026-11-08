#!/usr/bin/env python3
"""Conformance harness: upstream Zig 0.17.1's test/behavior, compiled by bs.

The measure, per target: the behavior tests bs compiles and passes, divided by
the tests upstream zig 0.17.1 passes on that target with its default Debug
backend. Upstream's per-test results are committed in baseline/<target>.json.

    tools/conformance/run.py              # build bs, run it on every target this host can run
    tools/conformance/run.py --upstream   # recompute baseline/<target>.json with upstream zig

Each run prints one summary line per target to stdout and writes a per-file,
per-test JSON breakdown (bs: .zig-cache/conformance/<target>.json).

With --zig-version 0.16, every measure is the same for bs's second
language (docs/slop/zig-0.16.md): upstream 0.16.0's tree at upstream-0.16/
(its test/, and its lib/ for --std), its baselines in baseline/0.16/, zig
0.16.0 as the oracle (BS_ZIG_0_16, else where .agents/setup installs it),
test_runner_0_16.zig as the runner, a scratch directory of its own
(.zig-cache/conformance-0.16), and bs run with BS_ZIG_VERSION=0.16.

Every file that upstream/test/behavior.zig imports is compiled and run on its
own (see "units" below), so one file that fails to compile or crashes does not
hide the others. Tests are identified by the fully qualified names that
upstream's own test step reports (for example "behavior.basic.test.truncate"),
which is what the compiler puts in builtin.test_functions.

The compiler builds each unit with the test runner given by --test-runner
(default: test_runner.zig; bs_runner.zig for bs on x86_64-linux); results are parsed from the
runner's "@bs-test" line protocol, documented in test_runner.zig, so any
runner that speaks it works. A crash or timeout marks the running test and
the binary is rerun with --start=<next index> to run the rest.

With --default-runner, units are built as a user's `zig test` builds them,
with the compiler's default runner (upstream's lib/compiler/test_runner.zig)
and no --test-runner. The binary first runs as `zig test` runs it, and its
terminal output ("1/9 name...OK", leak reports, the summary line) is parsed.
After a crash or timeout, the rest of the tests run through the runner's
--listen=- protocol (std.zig.Server, as `zig build test` drives it), one
test at a time, restarting after each further crash.

With --std, the measure is upstream's std tests instead: lib/std/std.zig
built as one `zig test` unit with the default runner and --zig-lib-dir
upstream/lib (the source tree, which has std's testdata), as
`zig build test-std` builds its Debug entry for the target. Results are
parsed as with --default-runner and compared with baseline/std-<target>.json.
--std --libc links glibc (-lc, -target <arch>-linux-gnu, upstream's
test-matrix entry for std with libc) and compares with
baseline/std-<target>-gnu-libc.json. --std --musl links musl instead
(-lc, -target <arch>-linux-musl: libc.a and crt1.o built from the lib
directory's sources, static) and compares with
baseline/std-<target>-musl-libc.json.

With --c-abi, the measure is upstream's C ABI tests instead:
test/c_abi/main.zig with cfuncs.c (-std=c99), linked against glibc
(-lc, -target <arch>-linux-gnu), built and run like --std, as upstream's
test-c-abi step builds its self-hosted entry (with musl there; glibc
here, bs's dynamic -lc path), and compared with baseline/c-abi-<target>.json.

With --compile-errors, the measure is diagnostics instead: every case in
upstream's test/cases/compile_errors that applies to the target, compiled
by bs as upstream's case harness compiles it: as a root file named
tmp.zig, so that its types are named `tmp.T`, in a module named root
(`-Mroot=`), with build-obj, or build-exe
or test when the case says so. A case is "exact" when bs reports the same
error lines (location and message) as the case expects, "same location"
when only the messages differ, and otherwise "different", "accepted" (no
error), "crash" or "timeout". Notes are compared separately.

With --cases, the measure is the rest of upstream's test/cases (the
run cases, including test/cases/safety, plus compile and error cases)
that apply to the target with the self-hosted backend: each built as
upstream's case harness builds it (root tmp.zig, Debug), a run case run
and its exit status (0) and stdout compared with the manifest's, a
compile case only built, an error case compared as --compile-errors
compares. The cases upstream passes are recorded by --cases --upstream
in baseline/cases-<target>.json.

With --standalone, the measure is upstream's test/standalone: each
project copied to the workdir and built there with `build` (its default
step, which upstream's standalone step runs) on the host. A project passes when the build succeeds; it is "unsupported"
when each failed step failed on a bs `[unsupported]` diagnostic (another
target, LLVM, a shared library, `-femit-asm` and the like). The projects
upstream passes are recorded by --standalone --upstream in
baseline/standalone-<target>.json.

With --langref, the measure is upstream's doc/langref examples: each
built from the workdir as upstream's tools/doctest.zig builds it (its
manifest names the kind: exe, test, test_error, test_safety, obj, syntax,
lib, and options), a built exe run. bs matches upstream on an example
when the outcome is the same: both build or both fail; a failure's first
error (file, line, column and message); an exe's exit status, stdout,
normalized stderr, or, if it fails, its first panic line; a test's exit
status, summary line and first panic line. Examples for other targets
are skipped; under an emulator, a test is built with --test-no-exec and
run under it. Upstream's outcomes are recorded by --langref --upstream in
baseline/langref-<target>.json.

Portable to Linux and macOS: Python 3 standard library only.
"""

import argparse
import json
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import zlib
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
UPSTREAM_TEST = REPO / "upstream" / "test"
UPSTREAM_LIB = REPO / "upstream" / "lib"
BASELINE_DIR = HERE / "baseline"
# Measuring Zig 0.16 (`--zig-version 0.16`, `use_zig_0_16`).
ZIG_0_16 = False
FORMAT = 1

# bs's targets, the `-target` both compilers get, and the host that can run
# the test binaries (platform.system(), platform.machine()). The zig targets
# match upstream's own test matrix entries in test/tests.zig, whose Debug
# builds use the default backend: self-hosted x86_64 on x86_64-linux, LLVM on
# aarch64-macos (see selfHostedBackendIsAsRobustAsLlvm in src/target.zig).
TARGETS = {
    "x86_64-linux": {"zig_target": "x86_64-linux-none", "host": ("Linux", "x86_64")},
    "aarch64-macos": {"zig_target": "aarch64-macos-none", "host": ("Darwin", "arm64")},
    # LLVM is upstream's Debug default here too. An x86_64-linux host runs
    # the binaries under qemu's user-mode emulator as a Cortex-A53, an
    # ARMv8.0 core like the target's generic baseline, so newer instructions
    # trap. The emulator is whichever of the names is on PATH, as in
    # build.zig: .agents/setup installs qemu-aarch64-static, the Nix shell
    # qemu-aarch64. Binaries linking glibc load it from the emulator's
    # sysroot, which .agents/setup installs (libc6-arm64-cross).
    "aarch64-linux": {
        "zig_target": "aarch64-linux-none",
        "host": ("Linux", "aarch64"),
        "emulated": {("Linux", "x86_64"): (("qemu-aarch64-static", "qemu-aarch64"), ["-cpu", "cortex-a53"])},
        "emulated_glibc": "/usr/aarch64-linux-gnu",
    },
}


def emulator(cfg, host):
    """The command prefix that runs cfg's binaries on host under emulation,
    or None when host has no emulator for it or none is installed."""
    names, args = cfg.get("emulated", {}).get(host, ((), []))
    path = next(filter(None, map(shutil.which, names)), None)
    return [path, *args] if path else None


# The emulator command that runs the current target's binaries on this host,
# if they do not run natively (set per target by main).
exec_prefix = []


def exec_argv(bin_path, *args):
    return exec_prefix + [str(bin_path), *args]


# std tests that hang on a host with fewer than 4 CPUs, in upstream's build
# too: Io.Threaded's async_limit is cpu_count - 1, so with 3 CPUs the
# test's last group.async runs its task inline, under the blocked cancel
# protection of the task that spawns it, and Group.cancel waits out its
# 100,000 s sleep (lib/std/Io/test.zig:575). --std leaves them out of both
# counts there instead of waiting out the run timeout.
FEW_CPU_HANGS = frozenset({"Io.test.test.tasks spawned in group after Group.cancel are canceled"})
MIN_CPUS = 4

ROOT_UNIT = "behavior.zig"
ROOT_TEST_RE = re.compile(r"^behavior\.(test\.|test_\d+$)")
PROTOCOL_PREFIX = "@bs-test "
TEST_OUTCOMES = ("pass", "skip", "fail", "leak", "crash", "timeout", "not_run")
LOG_LIMIT = 4000
STATUS_LABELS = {
    "compile_error": "compile errors",
    "compile_crash": "compiler crashes",
    "compile_timeout": "compile timeouts",
    "incomplete": "incomplete runs",
    "edit_verify_failed": "edit-verify failures",
    "sched_check_failed": "sched-check failures",
}


# ---------------------------------------------------------------- units
#
# A unit is one file that behavior.zig imports, compiled on its own. Its root
# is a generated wrapper named behavior.zig next to a `behavior` symlink to
# upstream/test/behavior/, containing only
#
#     comptime { _ = @import("behavior/<file>"); }
#
# so that the file's namespace is "behavior.<file stem>" exactly as in
# upstream's full build. Tests such as typename.zig's check @typeName results
# that include this namespace, and the test names stay identical to the names
# upstream's test step reports. The unit "behavior.zig" is upstream's root file
# itself, filtered to its own tests: one of them only reproduces in the root.


def lint_off(d):
    """bs lints a project's files by default; upstream's code is compiled
    with lint off. A `.bs.zon` in `d` turns it off for root files there
    (all bs searches outside a project) and for a project rooted there."""
    (d / ".bs.zon").write_text(".{ .lint = false }\n")


def unit_root(unit, workdir, editable=False):
    """The unit's root source file, generated if needed. If `editable`, the
    unit's own file is a copy (`behavior/<unit>`), the others links."""
    if unit == ROOT_UNIT:
        return UPSTREAM_TEST / "behavior.zig"
    unit_dir = workdir / "units" / unit[: -len(".zig")]
    unit_dir.mkdir(parents=True, exist_ok=True)
    link = unit_dir / "behavior"
    if editable:
        if link.is_symlink():
            link.unlink()
        shutil.rmtree(link, ignore_errors=True)
        link.mkdir()
        for entry in (UPSTREAM_TEST / "behavior").iterdir():
            if entry.name == unit:
                shutil.copyfile(entry, link / entry.name)
            else:
                (link / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
    elif not link.is_symlink() or os.readlink(link) != str(UPSTREAM_TEST / "behavior"):
        if link.is_dir() and not link.is_symlink():
            shutil.rmtree(link)
        link.unlink(missing_ok=True)
        link.symlink_to(UPSTREAM_TEST / "behavior", target_is_directory=True)
    lint_off(unit_dir)
    root = unit_dir / "behavior.zig"
    text = f'comptime {{\n    _ = @import("behavior/{unit}");\n}}\n'
    if not root.exists() or root.read_text() != text:
        root.write_text(text)
    return root


def unit_filters(unit):
    # Unnamed tests ignore filters, so behavior.zig's `test { _ = @import(...) }`
    # still imports every file; unit_owns drops the tests that are not its own.
    return ["behavior.test"] if unit == ROOT_UNIT else []


def unit_owns(unit, name):
    """Whether test `name` belongs to `unit`. A unit's binary can also contain
    tests that upstream counts in another unit; each counts only in its own."""
    if unit == ROOT_UNIT:
        return ROOT_TEST_RE.match(name) is not None
    return name.startswith("behavior." + unit[: -len(".zig")] + ".")


def behavior_imports():
    """Files upstream/test/behavior.zig imports, conditional ones included."""
    text = (UPSTREAM_TEST / "behavior.zig").read_text()
    return sorted(set(re.findall(r'@import\("behavior/([^"/]+\.zig)"\)', text)))


# ---------------------------------------------------------------- processes

_live = set()
_live_lock = threading.Lock()


def run_process(argv, cwd, timeout, env=None):
    """Runs argv in its own process group. Returns (returncode, stdout, stderr,
    timed_out); returncode is negative for a signal, as in subprocess."""
    proc = subprocess.Popen(
        argv,
        cwd=cwd,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    with _live_lock:
        _live.add(proc)
    timed_out = False
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        kill_group(proc)
        out, err = proc.communicate()
    finally:
        with _live_lock:
            _live.discard(proc)
    return proc.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace"), timed_out


def kill_group(proc):
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def kill_all():
    with _live_lock:
        for proc in list(_live):
            kill_group(proc)


def describe_exit(code, timed_out, timeout):
    if timed_out:
        return f"timed out after {timeout:g}s"
    if code < 0:
        try:
            return f"killed by {signal.Signals(-code).name}"
        except ValueError:
            return f"killed by signal {-code}"
    return f"exit code {code}"


def crash_log(stderr):
    """The start of what the crashing test wrote to stderr (the panic message
    and trace), cut after the runner's last start marker if it wrote one."""
    lines = stderr.splitlines()
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].startswith(PROTOCOL_PREFIX + "start "):
            lines = lines[i + 1 :]
            break
    stderr = "\n".join(lines).strip()
    return stderr if len(stderr) <= 1500 else stderr[:1500] + "\n..."


def tail(text, limit=LOG_LIMIT):
    text = text.strip()
    return text if len(text) <= limit else "...\n" + text[-limit:]


# ---------------------------------------------------------------- one unit


def test_runner(args, cfg):
    """The runner given with --test-runner, else test_runner.zig, except for
    bs on x86_64-linux, which uses bs_runner.zig (its own `_start` and
    system calls) until it compiles std.start there."""
    if args.test_runner is not None:
        return args.test_runner
    bs_runner = not args.upstream and cfg["name"] == "x86_64-linux"
    return HERE / ("bs_runner.zig" if bs_runner else "test_runner.zig")


def mcpu_args(args):
    """`--mcpu`'s CPU for both compilers, else none: an explicit target's
    baseline, which the committed baselines were recorded with."""
    return [f"-mcpu={args.mcpu}"] if args.mcpu else []


def compile_unit(compiler, unit, cfg, args, workdir, env=None, run_env=None, generated=False):
    """Builds the unit's test binary. `env` is an edit build's environment:
    the unit's generated root, and a failure is edit_verify_failed. Else
    `run_env`, if given, is the build's environment; a failure that the
    cache's checks report is edit_verify_failed too. With `generated`, the
    root is the one `unit_root` made, as it is."""
    bin_path = workdir / "bin" / cfg["name"] / (unit[: -len(".zig")] + ".test")
    bin_path.parent.mkdir(parents=True, exist_ok=True)
    if bin_path.exists():
        bin_path.unlink()
    editable = args.edit_verify and unit != ROOT_UNIT
    argv = [
        str(compiler),
        "test",
        str(unit_root(unit, workdir, editable) if env is None and not generated else generated_root(unit, workdir)),
    ]
    if not args.default_runner:
        argv += ["--test-runner", str(test_runner(args, cfg))]
    argv += ["-target", cfg["zig_target"], *mcpu_args(args), "--test-no-exec", f"-femit-bin={bin_path}"]
    for f in unit_filters(unit):
        argv += ["--test-filter", f]
    code, out, err, timed_out = run_process(argv, workdir, args.compile_timeout, env if env is not None else run_env)
    if code == 0 and not timed_out and bin_path.exists():
        return bin_path, None
    if env is not None or (run_env is not None and "error: BS_CACHE_" in err):
        return None, {
            "status": "edit_verify_failed",
            "log": describe_exit(code, timed_out, args.compile_timeout) + "\n" + tail(err + out),
            "tests": {},
        }
    if timed_out:
        status = "compile_timeout"
    elif code < 0:
        status = "compile_crash"
    else:
        status = "compile_error"
    log = describe_exit(code, timed_out, args.compile_timeout) + "\n" + tail(err + out)
    return None, {"status": status, "log": log, "tests": {}}


def run_unit(bin_path, owns, args, workdir):
    """Runs a test binary, resuming after crashes and timeouts. Keeps the
    tests for which owns(name) is true, keyed by name."""
    by_index = {}  # index -> [name, outcome, detail]
    backend = None
    status = "ok"
    log = None
    start = 0
    while True:
        code, out, err, timed_out = run_process(exec_argv(bin_path, f"--start={start}"), workdir, args.run_timeout)
        current = None
        first_start = None
        count = None
        done = False
        for line in out.splitlines():
            if not line.startswith(PROTOCOL_PREFIX):
                continue
            parts = line[len(PROTOCOL_PREFIX) :].split(" ", 2)
            kind = parts[0]
            try:
                if kind == "v1":
                    count = int(parts[1])
                    if len(parts) > 2:
                        backend = parts[2]
                elif kind == "start":
                    current = int(parts[1])
                    if first_start is None:
                        first_start = current
                    by_index[current] = [parts[2] if len(parts) > 2 else "", None, None]
                elif kind in ("pass", "skip", "fail", "leak"):
                    index = int(parts[1])
                    if index == current:
                        by_index[index][1] = kind
                        if kind == "fail" and len(parts) > 2:
                            by_index[index][2] = parts[2]
                        current = None
                elif kind == "done":
                    done = True
            except (IndexError, ValueError):
                continue  # A line torn by a crash.
        if done:
            break
        how = describe_exit(code, timed_out, args.run_timeout)
        if current is None:
            # Died outside any test: in the runner itself, or after the last
            # result without reaching "done".
            status = "incomplete"
            log = how + "\n" + tail(err)
            break
        by_index[current][1] = "timeout" if timed_out else "crash"
        by_index[current][2] = how + "\n" + crash_log(err)
        if first_start != start:
            status = "incomplete"  # The runner ignored --start; stop.
            log = "runner did not honor --start"
            break
        start = current + 1
        if count is not None and start >= count:
            break

    tests = {}
    details = {}
    for index in sorted(by_index):
        name, outcome, detail = by_index[index]
        if not owns(name):
            continue
        key = name
        n = 2
        while key in tests:  # Keep duplicate names distinct.
            key = f"{name}#{n}"
            n += 1
        tests[key] = outcome or "crash"
        if detail:
            details[key] = detail
    result = {"status": status, "tests": tests}
    if backend:
        result["backend"] = backend
    if details:
        result["details"] = details
    if log:
        result["log"] = log
    return result


# ---------------------------------------------------------------- default runner
#
# Upstream's lib/compiler/test_runner.zig speaks no @bs-test protocol. Run as
# `zig test` runs it (no arguments, stderr not a terminal), it writes
# "<i>/<n> <name>..." before each test and "OK", "SKIP" or "FAIL (<error>)"
# after it; testing.allocator reports leaks after the result, and the run
# ends with "All <n> tests passed." or "<p> passed; <s> skipped; <f> failed.".
# With --listen=- it is a std.zig.Server that runs the tests it is asked for.

CLIENT_EXIT, CLIENT_QUERY_TEST_METADATA, CLIENT_RUN_TEST = 0, 4, 5
SERVER_ZIG_VERSION, SERVER_TEST_METADATA, SERVER_TEST_RESULTS, SERVER_TEST_STARTED = 0, 3, 4, 5
TERMINAL_SUMMARY_RE = re.compile(r"^(All \d+ tests passed\.|\d+ passed; \d+ skipped; \d+ failed\.)", re.MULTILINE)


class ServerSession:
    """A test binary run with --listen=-, driven like `zig build test`."""

    def __init__(self, bin_path, workdir):
        self.proc = subprocess.Popen(
            exec_argv(bin_path, "--listen=-"),
            cwd=workdir,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        with _live_lock:
            _live.add(self.proc)
        self.buf = b""
        self.err = []
        self.err_thread = threading.Thread(target=lambda: self.err.append(self.proc.stderr.read()), daemon=True)
        self.err_thread.start()

    def send(self, tag, body=b""):
        self.proc.stdin.write(tag.to_bytes(4, "little") + len(body).to_bytes(4, "little") + body)
        self.proc.stdin.flush()

    def _read(self, n, deadline):
        import select

        fd = self.proc.stdout.fileno()
        while len(self.buf) < n:
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError
            ready, _, _ = select.select([fd], [], [], left)
            if not ready:
                raise TimeoutError
            chunk = os.read(fd, 65536)
            if not chunk:
                raise EOFError
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def receive(self, deadline):
        hdr = self._read(8, deadline)
        tag = int.from_bytes(hdr[:4], "little")
        return tag, self._read(int.from_bytes(hdr[4:], "little"), deadline)

    def close(self):
        try:
            self.send(CLIENT_EXIT)
        except OSError:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            kill_group(self.proc)
            self.proc.wait()
        self.err_thread.join(timeout=5)
        with _live_lock:
            _live.discard(self.proc)
        return b"".join(self.err).decode("utf-8", "replace")

    def kill(self):
        kill_group(self.proc)
        return self.close()


def query_test_names(bin_path, args, workdir):
    s = ServerSession(bin_path, workdir)
    try:
        deadline = time.monotonic() + args.run_timeout
        tag, _ = s.receive(deadline)
        if tag != SERVER_ZIG_VERSION:
            raise EOFError
        s.send(CLIENT_QUERY_TEST_METADATA)
        tag, body = s.receive(deadline)
        if tag != SERVER_TEST_METADATA:
            raise EOFError
        strings_len = int.from_bytes(body[0:4], "little")
        n = int.from_bytes(body[4:8], "little")
        offs = [int.from_bytes(body[8 + 4 * i : 12 + 4 * i], "little") for i in range(n)]
        strings = body[8 + 8 * n : 8 + 8 * n + strings_len]
        names = [strings[o : strings.index(b"\0", o)].decode("utf-8", "replace") for o in offs]
        s.close()
        return names, None
    except (EOFError, TimeoutError, OSError):
        return None, s.kill()


def parse_terminal(err, names):
    """Outcomes of the tests the terminal run reached: index -> (outcome,
    detail); the last may be None (started, no result)."""
    n = len(names)
    starts = []
    pos = 0
    for i, name in enumerate(names):
        marker = f"{i + 1}/{n} {name}..."
        at = err.find(marker, pos)
        if at < 0:
            break
        starts.append((i, at, at + len(marker)))
        pos = at + len(marker)
    out = {}
    for k, (i, at, body) in enumerate(starts):
        end = starts[k + 1][1] if k + 1 < len(starts) else len(err)
        seg = err[body:end]
        if k + 1 == len(starts):
            m = TERMINAL_SUMMARY_RE.search(seg)
            if m:
                seg = seg[: m.start()]
        m = re.search(r"(?:^|(?<=\.\.\.)|\n)(OK|SKIP|FAIL \((.*?)\))\n", seg)
        if not m:
            out[i] = (None, seg)
            continue
        if m.group(1) == "OK":
            out[i] = ("leak" if "leaked" in seg[m.end() :] else "pass", None)
        elif m.group(1) == "SKIP":
            out[i] = ("skip", None)
        else:
            out[i] = ("fail", m.group(2))
    return out


def run_server(bin_path, names, start, skip, by_index, args, workdir):
    """Runs tests `start` onward one at a time through the server protocol,
    except those named in `skip`, into `by_index`; a crash or timeout marks
    the test and a new process takes the rest. Returns (status, log)."""
    while start < len(names):
        s = ServerSession(bin_path, workdir)
        current = None
        try:
            tag, _ = s.receive(time.monotonic() + args.run_timeout)
            for i in range(start, len(names)):
                if names[i] in skip:
                    continue
                current = i
                s.send(CLIENT_RUN_TEST, i.to_bytes(4, "little"))
                deadline = time.monotonic() + args.run_timeout
                while True:
                    tag, body = s.receive(deadline)
                    if tag == SERVER_TEST_RESULTS:
                        break
                flags = int.from_bytes(body[4:12], "little")
                st = ("pass", "fail", "skip", "fail")[flags & 3]
                leaks = (flags >> 33) & ((1 << 31) - 1)
                by_index[i] = ["leak" if st == "pass" and leaks else st, None]
            s.close()
            break
        except (EOFError, TimeoutError, OSError) as e:
            timed = isinstance(e, TimeoutError)
            serr = s.kill()
            if current is None:
                return "incomplete", "the test runner did not answer on --listen=-\n" + tail(serr)
            code = s.proc.returncode
            by_index[current] = [
                "timeout" if timed else "crash",
                describe_exit(code, timed, args.run_timeout) + "\n" + tail(serr, 1500),
            ]
            start = current + 1
    return "ok", None


def run_unit_default(bin_path, owns, args, workdir, skip=frozenset()):
    """Runs a test binary with upstream's default test runner. Tests named
    in `skip` are not run, so then every test runs through the server
    protocol, which runs them by index."""
    names, err = query_test_names(bin_path, args, workdir)
    if names is None:
        return {
            "status": "incomplete",
            "log": "the test runner did not answer on --listen=-\n" + tail(err or ""),
            "tests": {},
        }
    by_index = {}
    status, log = "ok", None
    if skip.intersection(names):
        status, log = run_server(bin_path, names, 0, skip, by_index, args, workdir)
    else:
        code, _out, err, timed_out = run_process(exec_argv(bin_path), workdir, args.run_timeout)
        parsed = parse_terminal(err, names)
        for i, (outcome, detail) in parsed.items():
            by_index[i] = [outcome, detail]
        finished = (
            TERMINAL_SUMMARY_RE.search(err) is not None
            and len(parsed) == len(names)
            and all(o for o, _ in parsed.values())
        )
        if not finished:
            how = describe_exit(code, timed_out, args.run_timeout)
            if not parsed or by_index[max(parsed)][0] is not None:
                if len(parsed) != len(names):
                    status, log = "incomplete", how + "\n" + tail(err)
            else:
                last = max(parsed)
                by_index[last] = ["timeout" if timed_out else "crash", how + "\n" + crash_log(by_index[last][1] or "")]
                # The rest, one at a time through the server protocol.
                status, log = run_server(bin_path, names, last + 1, skip, by_index, args, workdir)
    tests, details = {}, {}
    for i in sorted(by_index):
        name = names[i]
        outcome, detail = by_index[i]
        if not owns(name):
            continue
        key = name
        n = 2
        while key in tests:
            key = f"{name}#{n}"
            n += 1
        tests[key] = outcome or "crash"
        if detail and outcome != "pass":
            details[key] = detail
    result = {"status": status, "tests": tests}
    if details:
        result["details"] = details
    if log:
        result["log"] = log
    return result


def edit_verify(compiler, unit, cfg, args, workdir):
    """--edit-verify: after the unit's first build, edits its file and builds
    it again, then restores it and builds once more, each an edit build
    that bs checks against a full build (BS_CACHE_VERIFY) with its
    dependency checks on (BS_CACHE_CHECK). The edits move every line,
    change a test's body, and add a declaration. Returns the last build's
    binary and a failure, if any."""
    path = workdir / "units" / unit[: -len(".zig")] / "behavior" / unit
    original = path.read_text()
    lines = original.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if re.match(r"^test\b.*\{\s*$", line):
            lines.insert(i + 1, "    _ = 0;\n")
            break
    edited = "// bs edit-verify\n" + "".join(lines) + "\npub const bs_edit_probe: u32 = 1;\n"
    env = dict(os.environ, BS_CACHE_VERIFY="1", BS_CACHE_CHECK="1")
    result = None, None
    for text in (edited, original):
        path.write_text(text)
        result = compile_unit(compiler, unit, cfg, args, workdir, env)
        if result[1]:
            break
    path.write_text(original)
    return result


def generated_root(unit, workdir):
    """The root `unit_root` made for `unit`, as it is."""
    if unit == ROOT_UNIT:
        return UPSTREAM_TEST / "behavior.zig"
    return workdir / "units" / unit[: -len(".zig")] / "behavior.zig"


def sched_check(compiler, unit, cfg, args, workdir):
    """--sched-check: builds the unit again four ways on one thread:
    generating each function's code as soon as it is analyzed; with
    BS_SCHED_FUZZ=late, only when analysis waits for CodeGen, after
    whatever it resolved meanwhile; with BS_SCHED_FUZZ=sema:<seed>,
    analyzing in a random order; and with BS_COMPTIME_EVAL=1, running
    every comptime call in the evaluator instead of the walker. Each is a
    full build checked node by node against the unit's last build
    (BS_CACHE_VERIFY=full), which also seeds the error codes from it, as
    edit builds are: codes are numbered in the order names are first used.
    The binaries must be identical, and the nodes the same: a difference
    is code or a cache record that depends on when a declaration was
    resolved, on analysis order, or on which comptime tier ran a call,
    which differ between a full build, an edit build, and runs under load.
    Returns a failure, if any."""
    seed = args.sched_seed + zlib.crc32(unit.encode())
    builds = (
        ("BS_THREADS=1", {}),
        ("BS_SCHED_FUZZ=late", {"BS_SCHED_FUZZ": "late"}),
        (f"BS_SCHED_FUZZ=sema:{seed}", {"BS_SCHED_FUZZ": f"sema:{seed}"}),
        ("BS_COMPTIME_EVAL=1", {"BS_COMPTIME_EVAL": "1"}),
    )
    # The unit's own command line, so its compilation and the manifest its
    # last build wrote.
    return order_check(
        lambda env: compile_unit(compiler, unit, cfg, args, workdir, run_env=env, generated=True),
        dict(os.environ, BS_THREADS="1"),
        builds,
    )


def tier_swap(argv, bin_path, workdir, timeout):
    """--sched-check with --std or --c-abi: builds the suite again with the
    comptime evaluator off (BS_COMPTIME_EVAL=0, the walker runs every
    comptime call), then eager (BS_COMPTIME_EVAL=1, the evaluator runs every
    one), then off again, each a full build checked node by node against the
    one before (BS_CACHE_VERIFY=full). That check only finds dependencies
    the previous build lacks, so the swap runs both ways: a dependency only
    one tier records shows in one of them. The binaries must be identical.
    Returns a failure, if any."""

    def build(env):
        code, out, err, timed_out = run_process(argv, workdir, timeout, env=env)
        if code == 0 and not timed_out and bin_path.exists():
            return bin_path, None
        return None, {"log": describe_exit(code, timed_out, timeout) + "\n" + tail(err + out), "tests": {}}

    walker, evaluator = (
        ("BS_COMPTIME_EVAL=0", {"BS_COMPTIME_EVAL": "0"}),
        ("BS_COMPTIME_EVAL=1", {"BS_COMPTIME_EVAL": "1"}),
    )
    return order_check(build, os.environ, (walker, evaluator, walker))


def order_check(build, base, builds):
    """Runs build(env) once per (label, extra env) in builds, each with
    BS_CACHE_VERIFY=full and BS_CACHE_CHECK=1 on top of base, so each is a
    full build checked node by node against the build before it. build
    returns (binary path, failure). The binaries must be identical. Returns
    a failure (status sched_check_failed), if any."""
    base = dict(base, BS_CACHE_VERIFY="full", BS_CACHE_CHECK="1")
    contents, sizes = [], []
    for label, extra in builds:
        path, failure = build(dict(base, **extra))
        if failure:
            failure["status"] = "sched_check_failed"
            failure["log"] = f"{label} with BS_CACHE_VERIFY=full:\n" + failure["log"]
            return failure
        contents.append(path.read_bytes())
        sizes.append(symbol_sizes(path))
    for k in range(1, len(builds)):
        if contents[k] == contents[0]:
            continue
        a, b = contents[0], contents[k]
        at = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
        log = f"the binary differs between {builds[0][0]} and {builds[k][0]} at byte {at} ({len(a)} vs {len(b)} bytes)"
        differ = [
            f"{name}: {sizes[0].get(name)} vs {sizes[k].get(name)} bytes"
            for name in sorted(set(sizes[0]) | set(sizes[k]))
            if sizes[0].get(name) != sizes[k].get(name)
        ]
        if differ:
            log += "\nsymbols whose size differs:\n" + "\n".join(differ[:20])
        return {"status": "sched_check_failed", "log": log, "tests": {}}
    return None


def symbol_sizes(path):
    """Each symbol's size in the binary at `path`, by name (nm -S), or none
    without nm."""
    try:
        out = subprocess.run(["nm", "-S", str(path)], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return {}
    sizes = {}
    for line in out.splitlines():
        parts = line.split(maxsplit=3)
        if len(parts) == 4:
            sizes[parts[3]] = int(parts[1], 16)
    return sizes


def run_one(compiler, unit, cfg, args, workdir):
    # A first build that a donor seeds is an edit build of the donor's
    # graph: checked as the edit builds are.
    first_env = dict(os.environ, BS_CACHE_VERIFY="1", BS_CACHE_CHECK="1") if args.edit_verify else None
    bin_path, failure = compile_unit(compiler, unit, cfg, args, workdir, run_env=first_env)
    if failure:
        return failure
    if args.edit_verify and unit != ROOT_UNIT:
        bin_path, failure = edit_verify(compiler, unit, cfg, args, workdir)
        if failure:
            return failure
    if args.sched_check:
        failure = sched_check(compiler, unit, cfg, args, workdir)
        if failure:
            bin_path.unlink(missing_ok=True)
            return failure
    try:
        run = run_unit_default if args.default_runner else run_unit
        return run(bin_path, lambda name: unit_owns(unit, name), args, workdir)
    finally:
        if not args.keep_binaries:
            bin_path.unlink(missing_ok=True)


def run_units(compiler, units, cfg, args, workdir):
    results = {}
    total = len(units)
    show_progress = sys.stderr.isatty()
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(run_one, compiler, u, cfg, args, workdir): u for u in units}
        try:
            for future in as_completed(futures):
                unit = futures[future]
                results[unit] = future.result()
                if args.verbose:
                    r = results[unit]
                    counts = count_outcomes(r["tests"].values())
                    print(f"  {cfg['name']} {unit}: {r['status']} {fmt_counts(counts)}", file=sys.stderr)
                elif show_progress:
                    print(f"\r  {cfg['name']}: {len(results)}/{total} files", end="", file=sys.stderr, flush=True)
        except KeyboardInterrupt:
            kill_all()
            pool.shutdown(cancel_futures=True)
            raise
    if show_progress and not args.verbose:
        print(file=sys.stderr)
    return {u: results[u] for u in sorted(results)}


def pop_backends(files):
    """Removes each unit's reported backend; returns the distinct ones."""
    backends = {r.pop("backend") for r in files.values() if "backend" in r}
    return ", ".join(sorted(backends)) or None


# ---------------------------------------------------------------- reporting


def count_outcomes(outcomes):
    counts = {k: 0 for k in TEST_OUTCOMES}
    for o in outcomes:
        counts[o] += 1
    return counts


def fmt_counts(counts):
    return ", ".join(f"{counts[k]} {k}" for k in TEST_OUTCOMES if counts[k])


def count_statuses(files):
    statuses = {}
    for r in files.values():
        statuses[r["status"]] = statuses.get(r["status"], 0) + 1
    return dict(sorted(statuses.items()))


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=1, ensure_ascii=False) + "\n")
    tmp.replace(path)


def rel(path):
    try:
        return str(Path(path).resolve().relative_to(Path.cwd()))
    except ValueError:
        return str(path)


# ---------------------------------------------------------------- upstream mode


def full_run(zig, cfg, args, workdir):
    """Runs all of behavior.zig as one binary, the way upstream's test step
    does, to cross-check the per-file results. Returns name -> outcome."""
    bin_path = workdir / "bin" / cfg["name"] / "behavior-full.test"
    bin_path.parent.mkdir(parents=True, exist_ok=True)
    argv = [
        str(zig),
        "test",
        str(UPSTREAM_TEST / "behavior.zig"),
        "--test-runner",
        str(test_runner(args, cfg)),
        "-target",
        cfg["zig_target"],
        *mcpu_args(args),
        "--test-no-exec",
        f"-femit-bin={bin_path}",
    ]
    code, _out, err, timed_out = run_process(argv, workdir, args.compile_timeout * 4)
    if code != 0 or timed_out:
        sys.exit(
            f"error: compiling all of behavior.zig failed ({describe_exit(code, timed_out, args.compile_timeout * 4)}):\n{tail(err)}"
        )
    try:
        r = run_unit(bin_path, lambda _name: True, args, workdir)
    finally:
        bin_path.unlink(missing_ok=True)
    if r["status"] != "ok":
        sys.exit(f"error: running all of behavior.zig: {r.get('log')}")
    return r["tests"]


def upstream_target(zig, cfg, args, workdir):
    # The full run decides which of behavior.zig's imports apply to this
    # target: some are conditional on the architecture or backend, and a file
    # with no tests in the full run adds nothing to the denominator.
    full = full_run(zig, cfg, args, workdir)
    namespaces = {name.split(".")[1] for name in full if not ROOT_TEST_RE.match(name)}
    imports = behavior_imports()
    units = [f for f in imports if f[: -len(".zig")] in namespaces] + [ROOT_UNIT]
    if args.files:
        units = [u for u in units if u in args.files]
    files = run_units(zig, units, cfg, args, workdir)
    backend = pop_backends(files)

    per_file = {}
    for r in files.values():
        for key, outcome in r["tests"].items():
            per_file[key] = outcome
    mismatches = {}
    if not args.files:
        for key in sorted(set(full) | set(per_file)):
            a, b = full.get(key, "absent"), per_file.get(key, "absent")
            if a != b:
                mismatches[key] = {"full_run": a, "per_file": b}

    counts = count_outcomes(per_file.values())
    zig_version = subprocess.run([str(zig), "version"], capture_output=True, text=True, check=False).stdout.strip()
    data = {
        "format": FORMAT,
        "target": cfg["name"],
        "zig_target": cfg["zig_target"],
        "compiler": f"zig {zig_version}",
        "backend": backend,
        "summary": {
            "files": len(files),
            "file_status": count_statuses(files),
            "tests": len(per_file),
            **{k: v for k, v in counts.items() if k != "not_run"},
        },
        "full_run_check": {
            "tests": len(full),
            "pass": sum(1 for o in full.values() if o == "pass"),
            "mismatches": mismatches,
        },
        # Imports that have no tests on this target.
        "files_without_tests": [f for f in imports if f[: -len(".zig")] not in namespaces],
        "files": files,
    }
    out = args.out or BASELINE_DIR / f"{cfg['name']}.json"
    write_json(out, data)
    check = (
        "full-run cross-check identical" if not mismatches else f"full-run cross-check: {len(mismatches)} mismatches"
    )
    if args.files:
        check = "full-run cross-check skipped (--files)"
    print(
        f"{cfg['name']}: upstream zig {zig_version} ({backend}): {counts['pass']} pass, "
        f"{counts['skip']} skip, {counts['fail'] + counts['leak'] + counts['crash'] + counts['timeout']} fail "
        f"of {len(per_file)} tests in {len(files)} files run individually; {check} -> {rel(out)}"
    )


# ---------------------------------------------------------------- bs mode


def build_bs(workdir, zig):
    prefix = workdir / "bs"
    argv = [zig, "build", "-Doptimize=ReleaseSafe", "-p", str(prefix)]
    proc = subprocess.run(argv, cwd=REPO, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        sys.exit(f"error: building bs failed:\n{proc.stderr}")
    return prefix / "bin" / ("bs.exe" if os.name == "nt" else "bs")


def bs_target(bs, cfg, args, workdir):
    baseline_path = BASELINE_DIR / f"{cfg['name']}.json"
    if not baseline_path.exists():
        print(f"{cfg['name']}: no baseline; run with --upstream on a {cfg['name']} host first")
        return
    baseline = json.loads(baseline_path.read_text())
    units = list(baseline["files"])
    if args.files:
        units = [u for u in units if u in args.files]
    files = run_units(bs, units, cfg, args, workdir)
    backend = pop_backends(files)

    passed = expected = extra = unknown = 0
    for unit in units:
        r = files[unit]
        upstream_tests = baseline["files"][unit]["tests"]
        bs_tests = r["tests"]
        # Upstream's tests come first, in upstream order, with bs's outcome;
        # tests upstream did not report follow.
        merged = {}
        for key, up in upstream_tests.items():
            got = bs_tests.get(key, "not_run")
            merged[key] = {"upstream": up, "bs": got}
            if up == "pass":
                expected += 1
                passed += got == "pass"
            elif got == "pass":
                extra += 1
        for key, got in bs_tests.items():
            if key not in upstream_tests:
                merged[key] = {"upstream": "absent", "bs": got}
                unknown += 1
        r["tests"] = merged
        r["pass"] = sum(1 for t in merged.values() if t["upstream"] == "pass" and t["bs"] == "pass")
        r["of"] = sum(1 for t in merged.values() if t["upstream"] == "pass")

    statuses = count_statuses(files)
    pct = 100.0 * passed / expected if expected else 0.0
    data = {
        "format": FORMAT,
        "target": cfg["name"],
        "zig_target": cfg["zig_target"],
        "compiler": str(bs),
        "test_runner": "default" if args.default_runner else str(test_runner(args, cfg)),
        "backend": backend,
        "baseline": {"compiler": baseline["compiler"], "backend": baseline["backend"]},
        "summary": {
            "pass": passed,
            "of": expected,
            "percent": round(pct, 2),
            "files": len(files),
            "file_status": statuses,
            "extra_passes": extra,
            "unknown_tests": unknown,
        },
        "files": files,
    }
    out = args.out or workdir / f"{cfg['name']}.json"
    write_json(out, data)
    ok_files = statuses.get("ok", 0)
    problems = ", ".join(f"{n} {STATUS_LABELS.get(s, s)}" for s, n in statuses.items() if s != "ok")
    note = f"; {unknown} tests not in baseline" if unknown else ""
    print(
        f"{cfg['name']}{' (default runner)' if args.default_runner else ''}: {passed}/{expected} behavior tests pass ({pct:.1f}% of upstream); "
        f"{ok_files}/{len(files)} files compiled and ran"
        f"{'; ' + problems if problems else ''}{note} -> {rel(out)}"
    )


# ---------------------------------------------------------------- std mode


def std_target(compiler, cfg, args, workdir):
    """--std: upstream's std tests as one unit, built by `compiler`.

    With --libc, linked against glibc: `-lc` and the target's gnu ABI,
    upstream's test-matrix entry for std with libc (`x86_64-linux-gnu`).
    With --c-abi, upstream's test/c_abi instead, linked against glibc."""
    global exec_prefix
    suite = "c-abi" if args.c_abi else "std"
    gnu = args.libc or args.c_abi
    if gnu and args.musl:
        sys.exit("--musl and --libc (or --c-abi) exclude each other")
    if gnu and exec_prefix:
        sysroot = cfg.get("emulated_glibc")
        if not sysroot or not Path(sysroot, "lib").is_dir():
            print(f"{cfg['name']} {suite}: not run (the emulator needs {cfg['name']}'s glibc at {sysroot})")
            return
        exec_prefix = exec_prefix + ["-L", sysroot]
    if gnu:
        cfg = dict(cfg, zig_target=cfg["zig_target"].rsplit("-", 1)[0] + "-gnu")
    if args.libc:
        cfg = dict(cfg, name=cfg["name"] + "-gnu-libc")
    if args.musl:
        # Static, so the emulator needs no sysroot.
        cfg = dict(cfg, zig_target=cfg["zig_target"].rsplit("-", 1)[0] + "-musl", name=cfg["name"] + "-musl-libc")
    baseline_path = BASELINE_DIR / f"{suite}-{cfg['name']}.json"
    baseline = None
    if not args.upstream:
        if not baseline_path.exists():
            print(f"{cfg['name']} {suite}: no baseline; run with --upstream --{suite} on a {cfg['name']} host first")
            return
        baseline = json.loads(baseline_path.read_text())
    bin_path = workdir / "bin" / cfg["name"] / f"{suite}.test"
    bin_path.parent.mkdir(parents=True, exist_ok=True)
    bin_path.unlink(missing_ok=True)
    if args.c_abi:
        # 0.16's cfuncs.c compiles its bool-vector functions only for the
        # backends that pass them (its test/tests.zig defines this for
        # x86_64's self-hosted backend); 0.17's has no such switch.
        defines = ["-DZIG_BACKEND_STAGE2_X86_64"] if ZIG_0_16 and cfg["name"].startswith("x86_64-") else []
        sources = [
            str(UPSTREAM_TEST / "c_abi" / "main.zig"),
            "-cflags",
            "-std=c99",
            *defines,
            "--",
            str(UPSTREAM_TEST / "c_abi" / "cfuncs.c"),
        ]
    else:
        sources = [str(UPSTREAM_LIB / "std" / "std.zig")]
    argv = (
        [str(compiler), "test"]
        + sources
        + [
            "--zig-lib-dir",
            str(UPSTREAM_LIB),
            "-target",
            cfg["zig_target"],
            *mcpu_args(args),
            "--test-no-exec",
            f"-femit-bin={bin_path}",
        ]
        + (["-lc"] if gnu or args.musl else [])
    )
    if args.upstream:
        # A fresh cache, so that the baseline's compile time is a cold build.
        cache = workdir / f"{suite}-zig-cache"
        shutil.rmtree(cache, ignore_errors=True)
        argv += ["--cache-dir", str(cache / "local"), "--global-cache-dir", str(cache / "global")]
    timeout = args.compile_timeout * 4
    cpus = os.cpu_count() or 1
    skip = FEW_CPU_HANGS if suite == "std" and cpus < MIN_CPUS else frozenset()
    for name in sorted(skip):
        print(
            f"{cfg['name']} {suite}: not run on this {cpus}-CPU host: {name} (Io.Threaded's async_limit = "
            f"cpu_count - 1 makes it hang below {MIN_CPUS} CPUs, upstream too)"
        )
    start = time.monotonic()
    code, out, err, timed_out = run_process(argv, workdir, timeout)
    compile_s = time.monotonic() - start
    failure = None
    if code == 0 and not timed_out and bin_path.exists() and args.sched_check and not args.upstream:
        failure = tier_swap(argv, bin_path, workdir, timeout)
    if failure:
        bin_path.unlink(missing_ok=True)
        r = failure
    elif code == 0 and not timed_out and bin_path.exists():
        run_args = argparse.Namespace(**vars(args))
        run_args.run_timeout = max(args.run_timeout, 600)
        try:
            r = run_unit_default(bin_path, lambda _name: True, run_args, workdir, skip)
        finally:
            if not args.keep_binaries:
                bin_path.unlink(missing_ok=True)
    else:
        status = "compile_timeout" if timed_out else "compile_crash" if code < 0 else "compile_error"
        if args.upstream:
            sys.exit(f"error: upstream failed to compile {suite}'s tests:\n{tail(err + out)}")
        r = {"status": status, "log": describe_exit(code, timed_out, timeout) + "\n" + tail(err + out), "tests": {}}
    counts = count_outcomes(r["tests"].values())
    data = {
        "format": FORMAT,
        "target": cfg["name"],
        "zig_target": cfg["zig_target"],
        "compiler": str(compiler),
        "compile_seconds": round(compile_s, 1),
        "status": r["status"],
        "summary": {"tests": len(r["tests"]), **{k: v for k, v in counts.items() if k != "not_run"}},
    }
    if "log" in r:
        data["log"] = r["log"]
    if args.upstream:
        zig_version = subprocess.run(
            [str(compiler), "version"], capture_output=True, text=True, check=False
        ).stdout.strip()
        data["compiler"] = f"zig {zig_version}"
        data["tests"] = r["tests"]
        out_path = args.out or baseline_path
        write_json(out_path, data)
        print(
            f"{cfg['name']} {suite}: upstream zig {zig_version}: {counts['pass']} pass, {counts['skip']} skip, "
            f"{len(r['tests']) - counts['pass'] - counts['skip']} fail of {len(r['tests'])} tests; "
            f"compiled in {compile_s:.1f}s -> {rel(out_path)}"
        )
        return
    # Upstream's tests first, in upstream order, with bs's outcome.
    merged = {}
    passed = expected = 0
    for key, up in baseline["tests"].items():
        if key in skip:
            continue
        got = r["tests"].get(key, "not_run")
        merged[key] = {"upstream": up, "bs": got}
        if up == "pass":
            expected += 1
            passed += got == "pass"
    for key, got in r["tests"].items():
        if key not in merged:
            merged[key] = {"upstream": "absent", "bs": got}
    unknown = sum(1 for t in merged.values() if t["upstream"] == "absent")
    pct = 100.0 * passed / expected if expected else 0.0
    data["summary"] = {"pass": passed, "of": expected, "percent": round(pct, 2), "unknown_tests": unknown}
    data["baseline"] = {"compiler": baseline["compiler"], "compile_seconds": baseline["compile_seconds"]}
    data["tests"] = merged
    if "details" in r:
        data["details"] = r["details"]
    out_path = args.out or workdir / f"{suite}-{cfg['name']}.json"
    write_json(out_path, data)
    note = f"; {unknown} tests not in baseline" if unknown else ""
    status = "" if r["status"] == "ok" else f"; {STATUS_LABELS.get(r['status'], r['status'])}"
    print(
        f"{cfg['name']} {suite}: {passed}/{expected} {suite} tests pass ({pct:.1f}% of upstream){status}{note}; "
        f"compiled in {compile_s:.1f}s (upstream baseline {baseline['compile_seconds']:.1f}s) -> {rel(out_path)}"
    )
    # The tests upstream passes and bs does not, so a log shows which.
    details = r.get("details", {})
    for key, t in merged.items():
        if t["upstream"] == "pass" and t["bs"] != "pass":
            print(f"  {t['bs']}: {key}")
            for line in (details.get(key) or "").strip().splitlines()[:20]:
                print(f"    {line}")
    if failure:
        print(failure["log"])


# ---------------------------------------------------------------- compile-errors mode

CASES_DIR = UPSTREAM_TEST / "cases" / "compile_errors"
LOC_RE = re.compile(r"^(?P<path>[^\s:][^:]*)?:(?P<line>\d+):(?P<col>\d+): (?P<kind>error|note): (?P<msg>.*)$")


def parse_case(path):
    """The case's config and expected lines, or None if it is not an error case."""
    src = path.read_text(errors="replace")
    at = src.rfind("\n// error\n")
    if at < 0:
        return None
    cfg, expected = {}, []
    for ln in src[at + len("\n// error\n") :].splitlines():
        # As upstream's manifest parser: `//` then optional whitespace.
        text = ln[2:].strip(" \t") if ln.startswith("//") else ""
        m = re.match(r"^(\w+)=(.*)$", text)
        if m and not expected:
            cfg[m.group(1)] = m.group(2)
        elif text:
            # Upstream names the case file itself as 'tmp.zig:' when the
            # errors span several files; bs_lines() writes it as ':'.
            if text.startswith("tmp.zig:"):
                text = text[len("tmp.zig") :]
            # Some cases omit the leading ':' before the line.
            elif re.match(r"^\d+:\d+: (error|note): ", text):
                text = ":" + text
            expected.append(text)
    return cfg, expected


def case_applies(cfg, target):
    targets = cfg.get("target", "native").split(",")
    arch_os = target.split("-")[:2]
    if not any(
        t == "native"
        or t.split("-")[:2] == arch_os
        or t in ("x86_64-native", "native-linux")
        and arch_os == ["x86_64", "linux"]
        for t in targets
    ):
        return False
    return all(b in ("auto", "selfhosted", "stage2") for b in cfg.get("backend", "auto").split(","))


def bs_lines(stderr, case_name):
    """bs's diagnostics (--error-format=json) as upstream-style
    ':line:col: error: msg' lines. Notes in the case file keep their
    location; notes elsewhere become '?: note: msg', as other_note() turns
    upstream's ':?:?: note:' and bare 'note:' lines. Call-site frames are
    notes, worded as upstream's."""
    errors, notes = [], []
    for ln in stderr.splitlines():
        try:
            d = json.loads(ln)
        except ValueError:
            continue
        if "msg" not in d:
            continue
        here = lambda o: os.path.basename(o.get("file", "")) == case_name
        prefix = ":" if here(d) else os.path.basename(d.get("file", "")) + ":"
        # An error without a location (a dependency loop) is written as
        # upstream's case files write it.
        errors.append(
            f"{prefix}{d['line']}:{d.get('col', 0)}: error: {d['msg']}" if "line" in d else f"error: {d['msg']}"
        )
        times = lambda o: f" ({o['count']} times)" if o.get("count") else ""
        for n in d.get("notes", []):
            msg = n["msg"] + times(n)
            if "line" not in n:
                notes.append(f"?: note: {msg}")
            elif here(n):
                notes.append(f":{n['line']}:{n['col']}: note: {msg}")
            else:
                # Upstream names imported files (ZON) and writes ':?:?:'
                # for the rest; run_case() matches either form.
                notes.append(f"{os.path.basename(n['file'])}:{n['line']}:{n['col']}: note: {msg}")
        for c in d.get("calls", []):
            msg = {
                "inline": "called inline here",
                "comptime": "called at comptime here",
                "generic": "generic function instantiated here",
            }[c["kind"]] + times(c)
            notes.append(f":{c['line']}:{c['col']}: note: {msg}" if here(c) else f"?: note: {msg}")
    return errors, notes


def other_note(line):
    """Upstream's note outside the case file (':?:?: note:' or a bare
    'note:'), as bs_lines() writes one; None for other lines."""
    m = re.match(r"^(?::\?:\?: |: )?note: (.*)$", line)
    return f"?: note: {m.group(1)}" if m else None


def crash_frame(stderr):
    """The first frame of a crash's stack trace in bs's own source."""
    for ln in stderr.splitlines():
        m = re.search(r"/src/(\S+?\.zig:\d+):\d+: 0x[0-9a-f]+ in", ln)
        if m:
            return m.group(1)
    return "?"


def run_case(compiler, path, cfg, expected, args, workdir, target=None):
    """`target`: the `-target` to compile for, or None for the host."""
    out_dir = workdir / "compile-errors" / path.stem
    out_dir.mkdir(parents=True, exist_ok=True)
    lint_off(out_dir)
    # Upstream's harness compiles each case as tmp.zig, in a module named
    # root.
    root = out_dir / "tmp.zig"
    shutil.copyfile(path, root)
    # Cases import ZON files from the corpus's own subdirectories.
    for sub in path.parent.iterdir():
        if sub.is_dir() and not (out_dir / sub.name).exists():
            (out_dir / sub.name).symlink_to(sub.resolve())
    if cfg.get("is_test") == "true":
        argv = [str(compiler), "test", "--test-no-exec", f"-Mroot={root}", f"-femit-bin={out_dir / 'case.test'}"]
    elif cfg.get("output_mode", "Obj").lower() == "exe":
        argv = [str(compiler), "build-exe", f"-Mroot={root}", f"-femit-bin={out_dir / 'case'}"]
    else:
        argv = [str(compiler), "build-obj", f"-Mroot={root}", f"-femit-bin={out_dir / 'case.o'}"]
    if target:
        argv += ["-target", target]
    argv.append("--error-format=json")
    code, _out, err, timed_out = run_process(argv, workdir, args.compile_timeout)
    shutil.rmtree(out_dir, ignore_errors=True)
    # Upstream's harness matches a line by its end, so ': error: msg' and
    # ':?:?: error: msg' match the error at any location.
    any_loc = lambda e: re.match(r"^(?::\?:\?:|:) error: ", e)
    exp_errors = [
        e
        for e in expected
        if LOC_RE.match(e) and LOC_RE.match(e).group("kind") == "error" or e.startswith("error: ") or any_loc(e)
    ]
    exp_notes = [e for e in expected if LOC_RE.match(e) and LOC_RE.match(e).group("kind") == "note"] + [
        o for o in map(other_note, expected) if o
    ]
    r = {"expected": exp_errors}
    if timed_out:
        r["status"] = "timeout"
    elif code < 0 or "panic: " in err and not re.search(r"^\S+:\d+:\d+: error", err, re.MULTILINE):
        r["status"], r["crash"] = "crash", crash_frame(err)
    elif code == 0:
        r["status"] = "accepted"
    else:
        errors, notes = bs_lines(err, root.name)
        r["got"] = list(errors)
        for e in filter(any_loc, exp_errors):
            tail = e[e.index(" error: ") :]
            for i, g in enumerate(errors):
                if g.endswith(tail) and not any_loc(g) and g not in exp_errors:
                    errors[i] = e
                    break
        locs = lambda ls: sorted(l.split(": error:")[0] for l in ls)
        if sorted(errors) == sorted(exp_errors):
            r["status"] = "exact"
            other = lambda ln: re.sub(r"^[^:\s]+:\d+:\d+: note: ", "?: note: ", ln) if ln not in exp_notes else ln
            r["notes_match"] = sorted(map(other, notes)) == sorted(exp_notes)
        elif locs(errors) == locs(exp_errors):
            r["status"] = "same_location"
        else:
            r["status"] = "different"
    return path.name, r


def compile_errors_target(compiler, cfg, args, workdir):
    """--compile-errors: upstream's compile-error cases, compiled by bs."""
    if args.upstream:
        sys.exit("error: --compile-errors measures bs; the cases' expectations are upstream's")
    # Failing builds record nothing worth reusing across cases.
    os.environ["BS_CACHE"] = "off"
    # Off the target's host, each case is cross-compiled for it: for the
    # target its manifest names, or else the target's own.
    cross = (platform.system(), platform.machine()) != cfg["host"]
    arch_os = cfg["zig_target"].split("-")[:2]

    def case_target(case_cfg):
        if not cross:
            return None
        named = [t for t in case_cfg.get("target", "native").split(",") if t.split("-")[:2] == arch_os]
        return named[0] if named else cfg["zig_target"]

    cases = []
    for path in sorted(CASES_DIR.rglob("*.zig")):
        parsed = parse_case(path)
        if parsed and case_applies(parsed[0], cfg["zig_target"]):
            cases.append((path, *parsed))
    if args.files:
        cases = [c for c in cases if c[0].name in args.files]
    results = {}
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = [ex.submit(run_case, compiler, p, c, e, args, workdir, case_target(c)) for p, c, e in cases]
        for f in as_completed(futs):
            name, r = f.result()
            results[name] = r
            if args.verbose:
                print(
                    f"  {name}: {r['status']}{' ' + r.get('crash', '') if r['status'] == 'crash' else ''}",
                    file=sys.stderr,
                )
    counts = {}
    for r in results.values():
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    notes_ok = sum(1 for r in results.values() if r.get("notes_match"))
    data = {
        "format": FORMAT,
        "target": cfg["name"],
        "compiler": str(compiler),
        "summary": {"cases": len(results), **counts, "exact_with_notes": notes_ok},
        "cases": dict(sorted(results.items())),
    }
    out_path = args.out or workdir / f"compile-errors-{cfg['name']}.json"
    write_json(out_path, data)
    n = len(results)
    loc = counts.get("exact", 0) + counts.get("same_location", 0)
    print(
        f"{cfg['name']} compile errors: {counts.get('exact', 0)}/{n} exact ({notes_ok} with notes), "
        f"{loc}/{n} same location; {counts.get('different', 0)} different, {counts.get('accepted', 0)} accepted, "
        f"{counts.get('crash', 0)} crashes, {counts.get('timeout', 0)} timeouts -> {rel(out_path)}"
    )
    crashes = {}
    for name, r in results.items():
        if r["status"] == "crash":
            crashes.setdefault(r["crash"], []).append(name)
    for frame, names in sorted(crashes.items(), key=lambda kv: -len(kv[1])):
        print(f"  crash at {frame}: {len(names)} ({', '.join(sorted(names)[:3])}{', ...' if len(names) > 3 else ''})")


# ---------------------------------------------------------------- cases mode

CASES_ROOT = UPSTREAM_TEST / "cases"


def parse_manifest(src):
    """Upstream's test manifest (test/src/Cases.zig, TestManifest.parse):
    the last block of `//` lines, its first line the case type, then
    key=value lines up to a blank comment line, then the trailing lines
    (a run case's expected stdout). None without a manifest."""
    lines = src.rstrip(" \r\n\t").split("\n")
    start = len(lines)
    while start > 0 and lines[start - 1].startswith("//"):
        start -= 1
    block = [ln.rstrip("\r") for ln in lines[start:] if ln.rstrip("\r")]
    if not block:
        return None
    kind = block[0][2:].strip(" \t")
    cfg, i = {}, 1
    while i < len(block):
        text = block[i][2:].strip(" \t")
        i += 1
        if not text:
            break
        key, _, value = text.partition("=")
        cfg[key] = value
    # TrailingIterator: '//' alone is an empty line, else the text after
    # '// ', right-trimmed; trailingSplit joins them with newlines.
    trailing = ["" if len(ln) == 2 else ln[3:].rstrip(" \t") for ln in block[i:]]
    return kind, cfg, "\n".join(trailing)


def case_target(cfg, kind, target):
    """The `-target` a case is built for on bs's `target` ("native" for
    none), or None when the case does not run there: its targets (default
    native, plus wasm) must name the target and its backends the
    self-hosted one."""
    default = "native" if kind == "error" else "native,wasm32-wasi"
    arch_os = target.split("-")[:2]
    backends = cfg.get("backend", "auto").split(",")
    if not any(b in ("auto", "selfhosted", "stage2") for b in backends):
        return None
    for t in cfg.get("target", default).split(","):
        parts = t.split("-")
        if (
            t == "native"
            or parts[:2] == arch_os
            or t in ("x86_64-native", "native-linux")
            and arch_os == ["x86_64", "linux"]
        ):
            if parts[:2] != arch_os:
                return "native"
            return t
    return None


def collect_cases(cfg):
    """Upstream's test/cases other than compile_errors (the --compile-errors
    mode's): (name, path, kind, config, trailing, -target) for each case
    that runs on the target."""
    cases = []
    for path in sorted(CASES_ROOT.rglob("*.zig")):
        rel_path = path.relative_to(CASES_ROOT)
        if rel_path.parts[0] == "compile_errors":
            continue
        m = parse_manifest(path.read_text(errors="replace"))
        if not m or m[0] not in ("run", "compile", "error"):
            continue
        target = case_target(m[1], m[0], cfg["zig_target"])
        if target:
            cases.append((str(rel_path), path, *m, target))
    return cases


def run_one_case(compiler, case, args, workdir):
    """Builds a case as upstream's harness builds it (root file tmp.zig in
    module root, Debug) and runs a run case. The result: `status` (pass,
    compile_error, compile_crash, compile_timeout, wrong_exit, wrong_stdout,
    run_timeout; for error cases, the --compile-errors statuses) and what
    was observed."""
    name, path, kind, cfg, trailing, target = case
    out_dir = workdir / "cases" / re.sub(r"[^\w.-]", "_", name)
    shutil.rmtree(out_dir, ignore_errors=True)
    out_dir.mkdir(parents=True)
    lint_off(out_dir)
    if kind == "error":
        _, expected = parse_case(path)
        if args.upstream:
            # Upstream passes when each expected line ends one of its
            # diagnostic lines, as its harness matches them.
            root = out_dir / "tmp.zig"
            shutil.copyfile(path, root)
            code, _out, err, _t = run_process(
                [
                    str(compiler),
                    "build-obj",
                    *(["-target", target] if target != "native" else []),
                    f"-Mroot={root}",
                    "-fno-emit-bin",
                ],
                out_dir,
                args.compile_timeout,
            )
            got = [ln.split("tmp.zig", 1)[-1] for ln in err.splitlines()]
            ok = code > 0 and all(any(g.endswith(e.lstrip(":?")) for g in got) for e in expected)
            shutil.rmtree(out_dir, ignore_errors=True)
            return name, {"kind": kind, "status": "pass" if ok else "different"}
        # The --compile-errors comparison, on these few outside that
        # directory.
        _, r = run_case(compiler, path, cfg, expected, args, out_dir)
        r["kind"], r["status"] = kind, {"exact": "pass"}.get(r["status"], r["status"])
        shutil.rmtree(out_dir, ignore_errors=True)
        return name, r
    root = out_dir / "tmp.zig"
    shutil.copyfile(path, root)
    for imp in filter(None, cfg.get("imports", "").split(",")):
        shutil.copyfile(path.parent / imp, out_dir / imp)
    is_test = cfg.get("is_test") == "true"
    mode = cfg.get("output_mode", "Exe" if kind == "run" else "Obj").lower()
    bin_path = out_dir / "case"
    argv = [str(compiler), "test" if is_test else {"exe": "build-exe", "lib": "build-lib", "obj": "build-obj"}[mode]]
    if target != "native":
        argv += ["-target", target]
    argv.append(f"-Mroot={root}")
    if is_test:
        argv.append("--test-no-exec")
    if cfg.get("link_libc") == "true":
        argv.append("-lc")
    if cfg.get("cpu_features"):
        argv.append(f"-mcpu=baseline{cfg['cpu_features']}")
    for key, flag in (("pic", "PIC"), ("pie", "PIE")):
        if cfg.get(key) in ("true", "false"):
            argv.append(f"-f{'' if cfg[key] == 'true' else 'no-'}{flag}")
    argv.append("-fno-emit-bin" if cfg.get("emit_bin") == "false" else f"-femit-bin={bin_path}")
    code, _out, err, timed_out = run_process(argv, out_dir, args.compile_timeout)
    r = {"kind": kind}
    if timed_out:
        r["status"] = "compile_timeout"
    elif code < 0 or code != 0 and "panic: " in err and not re.search(r"^\S+:\d+:\d+: error", err, re.MULTILINE):
        r["status"], r["crash"] = "compile_crash", crash_frame(err)
    elif code != 0:
        r["status"], r["log"] = "compile_error", err[-LOG_LIMIT:]
    elif kind != "run":
        r["status"] = "pass"
    else:
        code, out, err, timed_out = run_process([str(bin_path)], out_dir, args.run_timeout)
        r["exit"], r["stdout"] = code, out[-LOG_LIMIT:]
        if timed_out:
            r["status"] = "run_timeout"
        elif code != 0:
            r["status"], r["log"] = "wrong_exit", err[-LOG_LIMIT:]
        elif not is_test and out != trailing:
            r["status"], r["expected_stdout"] = "wrong_stdout", trailing
        else:
            r["status"] = "pass"
    shutil.rmtree(out_dir, ignore_errors=True)
    return name, r


def cases_target(compiler, cfg, args, workdir):
    """--cases: upstream's test/cases (run, compile and error cases outside
    compile_errors), against baseline/cases-<target>.json."""
    os.environ["BS_CACHE"] = "off"
    cases = collect_cases(cfg)
    if args.files:
        cases = [c for c in cases if c[0] in args.files or c[1].name in args.files]
    results = {}
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = [ex.submit(run_one_case, compiler, c, args, workdir) for c in cases]
        for f in as_completed(futs):
            name, r = f.result()
            results[name] = r
            if args.verbose:
                print(f"  {name}: {r['status']}", file=sys.stderr)
    data = {"format": FORMAT, "target": cfg["name"], "compiler": str(compiler), "cases": dict(sorted(results.items()))}
    baseline_path = BASELINE_DIR / f"cases-{cfg['name']}.json"
    if args.upstream:
        zig_version = subprocess.run(
            [str(compiler), "version"], capture_output=True, text=True, check=False
        ).stdout.strip()
        data["compiler"] = f"zig {zig_version}"
        data["summary"] = {"cases": len(results), "pass": sum(r["status"] == "pass" for r in results.values())}
        write_json(baseline_path, data)
        print(f"{cfg['name']} cases (upstream): {data['summary']['pass']}/{len(results)} pass -> {rel(baseline_path)}")
        return
    baseline = json.loads(baseline_path.read_text())["cases"] if baseline_path.exists() else {}
    up_pass = [n for n, b in baseline.items() if b["status"] == "pass" and (n in results or not args.files)]
    passed = [n for n in up_pass if results.get(n, {}).get("status") == "pass"]
    # Cases bs passes and upstream does not, and those where bs's result
    # differs from upstream's on a case neither passes.
    extra = sorted(
        n for n, r in results.items() if r["status"] == "pass" and baseline.get(n, {}).get("status") != "pass"
    )
    for n, r in results.items():
        b = baseline.get(n)
        if b:
            r["upstream"] = b["status"]
    counts = {}
    for r in results.values():
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    pct = 100 * len(passed) / len(up_pass) if up_pass else 0
    data["summary"] = {
        "pass": len(passed),
        "of": len(up_pass),
        "percent": round(pct, 2),
        "cases": len(results),
        **counts,
    }
    out_path = args.out or workdir / f"cases-{cfg['name']}.json"
    write_json(out_path, data)
    fails = ", ".join(f"{counts[k]} {k.replace('_', ' ')}" for k in sorted(counts) if k != "pass")
    print(
        f"{cfg['name']} cases: {len(passed)}/{len(up_pass)} pass ({pct:.1f}% of upstream); "
        f"{len(results)} cases{'; ' + fails if fails else ''}"
        f"{'; ' + str(len(extra)) + ' pass only with bs' if extra else ''} -> {rel(out_path)}"
    )
    for n in sorted(set(up_pass) - set(passed)):
        print(f"  {n}: {results.get(n, {}).get('status', 'missing')}")


# ---------------------------------------------------------------- standalone

STANDALONE_ROOT = UPSTREAM_TEST / "standalone"
SUMMARY_RE = re.compile(r"^Build Summary: (\d+)/(\d+) steps succeeded", re.MULTILINE)


def run_one_standalone(compiler, name, args, workdir, env):
    """Runs `<compiler> build` (the project's default step, as upstream's
    standalone step runs it) on a copy in the workdir of one project of
    upstream's test/standalone, whose cache stays inside it as in
    upstream's tree (run_cwd runs a program by a path relative to it).
    The result:
    `status` (pass; unsupported when each failed step failed on a bs
    `[unsupported]` diagnostic; fail; timeout), the steps that succeeded,
    and the failed steps' output."""
    out_dir = workdir / "standalone" / name
    shutil.rmtree(out_dir, ignore_errors=True)
    shutil.copytree(STANDALONE_ROOT / name, out_dir)
    lint_off(out_dir)
    argv = [str(compiler), "build", "--summary", "all"]
    code, _out, err, timed_out = run_process(argv, out_dir, args.compile_timeout, env)
    r = {}
    m = SUMMARY_RE.search(err)
    if m:
        r["steps"] = f"{m[1]}/{m[2]}"
    if timed_out:
        r["status"] = "timeout"
    elif code == 0:
        r["status"] = "pass"
    else:
        # The build runner prints each failed step's output, then its
        # "failed command:" line.
        chunks = err.split("failed command:")[:-1] or [err]
        real = [c for c in chunks if "[unsupported]" not in c]
        r["status"] = "fail" if real else "unsupported"
        r["log"] = (real or chunks)[0][-LOG_LIMIT:]
    shutil.rmtree(out_dir, ignore_errors=True)
    return name, r


def standalone_target(compiler, cfg, args, workdir):
    """--standalone: upstream's test/standalone projects built and run with
    `build`, against baseline/standalone-<target>.json."""
    names = sorted(p.parent.name for p in STANDALONE_ROOT.glob("*/build.zig"))
    if args.files:
        names = [n for n in names if n in args.files]
    global_cache = workdir / "standalone-global"
    shutil.rmtree(global_cache, ignore_errors=True)
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(global_cache))
    results = {}
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = [ex.submit(run_one_standalone, compiler, n, args, workdir, env) for n in names]
        for f in as_completed(futs):
            name, r = f.result()
            results[name] = r
            if args.verbose:
                print(f"  {name}: {r['status']}", file=sys.stderr)
    shutil.rmtree(global_cache, ignore_errors=True)
    data = {
        "format": FORMAT,
        "target": cfg["name"],
        "compiler": str(compiler),
        "projects": dict(sorted(results.items())),
    }
    baseline_path = BASELINE_DIR / f"standalone-{cfg['name']}.json"
    if args.upstream:
        zig_version = subprocess.run(
            [str(compiler), "version"], capture_output=True, text=True, check=False
        ).stdout.strip()
        data["compiler"] = f"zig {zig_version}"
        if args.files and baseline_path.exists():
            # Only the projects run are recomputed.
            data["projects"] = dict(sorted({**json.loads(baseline_path.read_text())["projects"], **results}.items()))
        projects = data["projects"]
        data["summary"] = {"projects": len(projects), "pass": sum(r["status"] == "pass" for r in projects.values())}
        write_json(baseline_path, data)
        print(
            f"{cfg['name']} standalone (upstream): {data['summary']['pass']}/{len(projects)} pass -> {rel(baseline_path)}"
        )
        return
    baseline = json.loads(baseline_path.read_text())["projects"] if baseline_path.exists() else {}
    up_pass = [n for n, b in baseline.items() if b["status"] == "pass" and n in results]
    passed = [n for n in up_pass if results[n]["status"] == "pass"]
    unsupported = [n for n in up_pass if results[n]["status"] == "unsupported"]
    for n, r in results.items():
        if n in baseline:
            r["upstream"] = baseline[n]["status"]
    counts = {}
    for r in results.values():
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    supported = len(up_pass) - len(unsupported)
    data["summary"] = {
        "pass": len(passed),
        "of": len(up_pass),
        "supported": supported,
        "projects": len(results),
        **counts,
    }
    out_path = args.out or workdir / f"standalone-{cfg['name']}.json"
    write_json(out_path, data)
    print(
        f"{cfg['name']} standalone: {len(passed)}/{len(up_pass)} pass of upstream's, "
        f"{len(passed)}/{supported} of those bs supports ({len(unsupported)} need what bs does not support) "
        f"-> {rel(out_path)}"
    )
    for n in sorted(set(up_pass) - set(passed) - set(unsupported)):
        print(f"  {n}: {results[n]['status']}")


# ---------------------------------------------------------------- langref

LANGREF_ROOT = REPO / "upstream" / "doc" / "langref"
ERROR_RE = re.compile(r"^(\S+?):(\d+):(\d+): error(?:\[[\w-]+\])?: (.*)$", re.MULTILINE)
# The test runner's last line: every test passed, the counts, or leaks.
TEST_SUMMARY_RE = re.compile(r"^All \d+ tests passed|^\d+ passed; \d+ skipped; \d+ failed|tests? leaked memory")


def parse_langref(src):
    """A langref example's manifest, as upstream's tools/doctest.zig reads
    it: the `//` lines after the last blank line, the first the example's
    kind (`exe=succeed|fail|build_fail`, `test`, `test_error=<text>`,
    `test_safety=<text>`, `obj`, `obj=<text>`, `syntax`, `lib`), then
    options (`optimize=`, `target=`, `link_libc`, `additional_option=`,
    `llvm=`, `link_mode=`, `disable_cache`)."""
    start = src.rfind("\n\n// ")
    lines = [ln[3:] for ln in src[start:].strip().split("\n")]
    kind, _, expect = lines[0].partition("=")
    opts = {"additional_option": []}
    for ln in lines[1:]:
        key, _, value = ln.partition("=")
        if key == "additional_option":
            opts[key].append(value)
        else:
            opts[key] = value
    return kind, expect, opts


def langref_argv(compiler, path, kind, opts, name, cfg):
    """The command upstream's doctest runs for an example, from its
    directory, for target cfg; None for an example that names another
    target. Off the host, the target is passed and a test is only built
    (`--test-no-exec`), to run under the emulator."""
    target = opts.get("target")
    if target and not target.startswith(cfg["name"]):
        return None
    if not target and exec_prefix:
        target = cfg["zig_target"].rsplit("-", 1)[0] + ("-gnu" if "link_libc" in opts else "")
    sub = {"exe": "build-exe", "test": "test", "test_error": "test", "test_safety": "test", "lib": "build-lib"}.get(
        kind, "build-obj"
    )
    argv = [str(compiler), sub, str(path)]
    if sub == "build-exe":
        argv += ["--name", name]
    elif sub in ("build-obj", "build-lib"):
        argv.append(f"-femit-bin={name}{'.o' if sub == 'build-obj' else '.a'}")
    elif exec_prefix:
        argv += ["--test-no-exec", f"-femit-bin={name}"]
    if "optimize" in opts:
        argv += ["-O", opts["optimize"]]
    if "link_libc" in opts:
        argv.append("-lc")
    if target:
        argv += ["-target", target]
    if "llvm" in opts:
        argv.append("-fllvm" if opts["llvm"] == "true" else "-fno-llvm")
    if "link_mode" in opts:
        argv.append("-" + opts["link_mode"])
    return argv + opts["additional_option"]


def langref_exec(cfg, opts, bin_path):
    """The command that runs a built example: under the emulator off the
    host, with the target's glibc for one that links libc."""
    if exec_prefix and "link_libc" in opts and cfg.get("emulated_glibc"):
        return exec_prefix + ["-L", cfg["emulated_glibc"], str(bin_path)]
    return exec_argv(bin_path)


def normalize_output(text, out_dir):
    """Output with what differs between runs and compilers taken out: the
    scratch and upstream directories, addresses, and thread ids."""
    text = text.replace(str(out_dir) + "/", "").replace(str(LANGREF_ROOT) + "/", "")
    text = re.sub(r"0x[0-9a-f]+", "0x?", text)
    # `{*}`'s address after the type, and an anonymous type's number,
    # which bs takes from its declaration instead of the analysis order
    # (Sema's `anonTypeNumber`).
    text = re.sub(r"@[0-9a-f]{6,}\b", "@?", text)
    text = re.sub(r"__struct_\d+", "__struct_?", text)
    return re.sub(r"thread \d+ panic", "thread ? panic", text)


def first_error(stderr):
    """The first compile error, as (file:line:col, message), the file by its
    base name."""
    m = ERROR_RE.search(stderr)
    return (f"{Path(m[1]).name}:{m[2]}:{m[3]}", m[4].strip()) if m else None


def panic_line(stderr):
    """The first line of a run's panic or error message (not `zig test`'s
    note that the test command failed)."""
    for ln in stderr.splitlines():
        if ln.startswith("error: the following test command"):
            continue
        if "panic: " in ln or ln.startswith("error: "):
            return re.sub(r"thread \d+ panic", "thread ? panic", ln.strip())
    return None


def run_one_langref(compiler, path, cfg, args, workdir):
    """Builds and runs one example as upstream's doctest does and records
    what it saw: `outcome` (built, build_failed, unsupported, crash,
    timeout, skip), the first error, and for a run its exit status,
    stdout, normalized stderr, and first panic line."""
    name = path.stem
    kind, expect, opts = parse_langref(path.read_text(errors="replace"))
    r = {"kind": kind + (f"={expect}" if expect else "")}
    out_dir = workdir / "langref" / re.sub(r"[^\w.-]", "_", name)
    shutil.rmtree(out_dir, ignore_errors=True)
    out_dir.mkdir(parents=True)
    lint_off(out_dir)
    argv = langref_argv(compiler, path, kind, opts, name, cfg)
    # Under the emulator, an example linking glibc needs the target's
    # glibc (.agents/setup installs it); without it the run says nothing.
    if exec_prefix and "link_libc" in opts and not Path(cfg.get("emulated_glibc", ""), "lib").is_dir():
        argv = None
    if argv is None:
        r["outcome"] = "skip"
        return name, r
    code, out, err, timed_out = run_process(argv, out_dir, args.compile_timeout)
    # A test that panics is a run, not a crash of the compiler.
    runs = kind.startswith("test")
    if timed_out:
        r["outcome"] = "timeout"
    elif "[unsupported]" in err:
        r["outcome"], r["log"] = "unsupported", err[-LOG_LIMIT:]
    elif code < 0 or code != 0 and "panic: " in err and not ERROR_RE.search(err) and not runs:
        r["outcome"], r["crash"] = "crash", crash_frame(err)
    elif runs and exec_prefix:
        # Built only: run the test binary under the emulator, as `test`
        # would run it.
        e = first_error(err)
        if code != 0:
            r["outcome"], r["error"] = "build_failed", list(e) if e else None
        else:
            code, out, err, timed_out = run_process(langref_exec(cfg, opts, out_dir / name), out_dir, args.run_timeout)
            r["outcome"], r["exit"] = "built", "timeout" if timed_out else code
            r["summary"] = next((ln for ln in reversed(err.splitlines()) if TEST_SUMMARY_RE.search(ln)), None)
            r["panic"] = panic_line(err)
    elif kind.startswith("test"):
        # `test` builds and runs: an error before the run fails the build.
        e = first_error(err)
        if code != 0 and e and "All " not in err and "passed" not in err:
            r["outcome"], r["error"] = "build_failed", list(e)
        else:
            r["outcome"], r["exit"] = "built", code
            r["summary"] = next((ln for ln in reversed(err.splitlines()) if TEST_SUMMARY_RE.search(ln)), None)
            r["panic"] = panic_line(err)
    elif code != 0:
        e = first_error(err)
        r["outcome"], r["error"] = "build_failed", list(e) if e else None
        if not e:
            r["log"] = err[-LOG_LIMIT:]
    else:
        r["outcome"] = "built"
        if kind == "exe":
            code, out, err, timed_out = run_process(langref_exec(cfg, opts, out_dir / name), out_dir, args.run_timeout)
            r["exit"] = "timeout" if timed_out else code
            r["stdout"] = out[-LOG_LIMIT:]
            r["stderr"] = normalize_output(err, out_dir)[-LOG_LIMIT:]
            r["panic"] = panic_line(err)
    shutil.rmtree(out_dir, ignore_errors=True)
    return name, r


def compare_langref(r, up):
    """bs's status on an example given upstream's record: pass, or what
    differs first."""
    if r["outcome"] in ("unsupported", "crash", "timeout", "skip"):
        return r["outcome"]
    if up["outcome"] != r["outcome"]:
        return "compile_error" if r["outcome"] == "build_failed" else "accepted"
    if r["outcome"] == "build_failed":
        if r["error"] == up["error"]:
            return "pass"
        same_loc = r["error"] and up["error"] and r["error"][0] == up["error"][0]
        return "error_message" if same_loc else "error_location"
    if r.get("exit") != up.get("exit"):
        return "wrong_exit"
    if r["kind"].startswith("test"):
        return "pass" if r.get("summary") == up.get("summary") and r.get("panic") == up.get("panic") else "wrong_result"
    if r.get("stdout") != up.get("stdout"):
        return "wrong_stdout"
    if r["kind"] == "exe=fail":
        return "pass" if r.get("panic") == up.get("panic") else "wrong_panic"
    if r.get("stderr") != up.get("stderr"):
        return "wrong_stderr"
    return "pass"


def langref_target(compiler, cfg, args, workdir):
    """--langref: upstream's doc/langref examples, each built (and run) as
    upstream's doctest does, against baseline/langref-<target>.json."""
    os.environ["BS_CACHE"] = "off"
    paths = sorted(LANGREF_ROOT.glob("*.zig"))
    if args.files:
        paths = [p for p in paths if p.name in args.files or p.stem in args.files]
    results = {}
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = [ex.submit(run_one_langref, compiler, p, cfg, args, workdir) for p in paths]
        for f in as_completed(futs):
            name, r = f.result()
            results[name] = r
    data = {"format": FORMAT, "target": cfg["name"], "compiler": str(compiler)}
    baseline_path = BASELINE_DIR / f"langref-{cfg['name']}.json"
    if args.upstream:
        zig_version = subprocess.run(
            [str(compiler), "version"], capture_output=True, text=True, check=False
        ).stdout.strip()
        data["compiler"] = f"zig {zig_version}"
        if args.files and baseline_path.exists():
            results = {**json.loads(baseline_path.read_text())["examples"], **results}
        data["examples"] = dict(sorted(results.items()))
        ran = [r for r in results.values() if r["outcome"] in ("built", "build_failed")]
        data["summary"] = {"examples": len(results), "compared": len(ran)}
        write_json(baseline_path, data)
        print(f"{cfg['name']} langref (upstream): {len(ran)}/{len(results)} examples run -> {rel(baseline_path)}")
        return
    baseline = json.loads(baseline_path.read_text())["examples"] if baseline_path.exists() else {}
    counts = {}
    for n, r in results.items():
        up = baseline.get(n)
        if up is None or up["outcome"] not in ("built", "build_failed"):
            r["status"] = "skip"
        else:
            r["status"] = compare_langref(r, up)
            r["upstream"] = {k: v for k, v in up.items() if k != "kind"}
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    compared = len(results) - counts.get("skip", 0)
    passed = counts.get("pass", 0)
    unsupported = counts.get("unsupported", 0)
    data["summary"] = {"pass": passed, "of": compared, "supported": compared - unsupported, **counts}
    data["examples"] = dict(sorted(results.items()))
    out_path = args.out or workdir / f"langref-{cfg['name']}.json"
    write_json(out_path, data)
    fails = ", ".join(f"{counts[k]} {k.replace('_', ' ')}" for k in sorted(counts) if k not in ("pass", "skip"))
    print(
        f"{cfg['name']} langref: {passed}/{compared} match upstream, {passed}/{compared - unsupported} of those bs "
        f"supports{'; ' + fails if fails else ''} -> {rel(out_path)}"
    )
    for n in sorted(results):
        if results[n]["status"] not in ("pass", "skip", "unsupported"):
            print(f"  {n}: {results[n]['status']}")


# ------------------------------------------------------------ incremental

INCREMENTAL_ROOT = UPSTREAM_TEST / "incremental"


def parse_incremental(path):
    """An incremental case's manifest, as upstream's test/src/Runner.zig
    reads it: the compiler arguments (`#exe {...#}`) and the updates, each
    the files it writes or deletes, its name and its check (`stdout` or
    `errors`) with the expected text. A command's contents follow on its
    line after `{` up to the next `#}`, or come from a file of a directory
    case (`#write main.zig 0/main.zig`)."""
    manifest = path / "manifest" if path.is_dir() else path
    text = manifest.read_text()
    exe_args, steps, pending = None, [], []
    pos = 0
    while pos < len(text):
        end = text.find("\n", pos)
        end = len(text) if end < 0 else end
        words = text[pos:end].split(" ")
        pos = end + 1
        if not words[0]:
            continue
        cmd = words[0][1:]
        arg = words[1] if cmd in ("write", "delete", "check", "skip") and len(words) > 1 else None
        rest = " ".join(words[2:] if arg is not None else words[1:])
        contents = ""
        if rest == "{":
            close = text.index("#}", pos)
            contents = text[pos:close]
            pos = text.find("\n", close)
            pos = len(text) if pos < 0 else pos + 1
        elif rest:
            contents = (path / rest).read_text()
        if cmd == "exe":
            exe_args = contents.split()
        elif cmd == "write":
            pending.append((arg, contents))
        elif cmd == "delete":
            pending.append((arg, None))
        elif cmd == "update":
            steps.append({"name": contents.strip() or f"update {len(steps)}", "files": pending})
            pending = []
        elif cmd == "check":
            steps[-1]["check"], steps[-1]["expected"] = arg, contents
    return exe_args, steps


def incremental_errors(stderr):
    """bs's diagnostics (--error-format=json) rendered as upstream's error
    bundle renders them for the incremental harness: no source lines or
    reference traces, notes (call frames worded as upstream's) after their
    error, then the compile log."""
    lines, log = [], []
    for ln in stderr.splitlines():
        try:
            d = json.loads(ln)
        except ValueError:
            continue
        if "compile_log" in d:
            log += d["compile_log"]
        if "msg" not in d:
            continue
        times = lambda o: f" ({o['count']} times)" if o.get("count") else ""
        loc = lambda o: f"{o['file']}:{o['line']}:{o.get('col', 0)}: " if "line" in o else ""
        lines.append(f"{loc(d)}error: {d['msg']}{times(d)}")
        # A location-less error's notes are indented, as upstream renders them.
        indent = "" if "line" in d else "    "
        for n in d.get("notes", []):
            lines.append(f"{indent}{loc(n)}note: {n['msg']}{times(n)}")
        for c in d.get("calls", []):
            msg = {
                "inline": "called inline here",
                "comptime": "called at comptime here",
                "generic": "generic function instantiated here",
            }[c["kind"]]
            lines.append(f"{indent}{loc(c)}note: {msg}{times(c)}")
    out = "".join(ln + "\n" for ln in lines)
    if log:
        out += "\nCompile Log Output:\n" + "".join(ln + "\n" for ln in log)
    return out


def stdout_matches(expected, actual):
    """Upstream's stdout check: equal, or with `#...` matching any text."""
    if "#..." not in expected:
        return expected == actual
    parts = expected.split("#...")
    if not actual.startswith(parts[0]):
        return False
    pos = len(parts[0])
    for part in parts[1:-1]:
        at = actual.find(part, pos)
        if at < 0:
            return False
        pos = at + len(part)
    return actual[pos:].endswith(parts[-1]) and len(actual) - pos >= len(parts[-1])


def run_one_incremental(compiler, path, cfg, args, workdir):
    """Runs a case's updates as successive builds in one directory, each
    after the first an edit build that bs verifies against a full build
    (BS_CACHE_VERIFY=1, BS_CACHE_CHECK=1), and checks each against the
    manifest. A step's status: pass, errors (the errors match but not
    their notes or order), wrong_errors, missing_errors (built where
    errors were expected), unexpected_errors, wrong_stdout, run_failed,
    verify (the edit build differs from a full build), crash, timeout,
    unsupported; the steps after a crash or timeout are not run."""
    name = path.name
    exe_args, steps = parse_incremental(path)
    out_dir = workdir / "incremental" / name
    shutil.rmtree(out_dir, ignore_errors=True)
    src = out_dir / "src"
    src.mkdir(parents=True)
    lint_off(src)
    bin_path = out_dir / "main"
    argv = [str(compiler), "build-exe", *exe_args, f"-femit-bin={bin_path}", "--error-format=json"]
    if cfg["host"] != (platform.system(), platform.machine()):
        argv += ["-target", cfg["zig_target"]]
    mtime = time.time() - 3600
    results = []
    for i, step in enumerate(steps):
        for file, contents in step["files"]:
            if contents is None:
                (src / file).unlink()
                continue
            (src / file).parent.mkdir(parents=True, exist_ok=True)
            (src / file).write_text(contents)
            # As upstream: every update's files are newer than the last's.
            os.utime(src / file, (mtime + 2 * i, mtime + 2 * i))
        # The case's own cache: without a build.zig above it, bs would use
        # the global cache, where every case's `main` shares one manifest.
        # No donors unless asked for: a case's first build would replay
        # whichever case ran before it, making outcomes depend on order.
        env = dict(
            os.environ,
            ZIG_LOCAL_CACHE_DIR=str(out_dir / "cache"),
            BS_CACHE_DONOR=os.environ.get("BS_CACHE_DONOR", "off"),
            BS_CACHE_CHECK="1",
            **({"BS_CACHE_VERIFY": "1"} if i else {}),
        )
        bin_path.unlink(missing_ok=True)
        code, _out, err, timed_out = run_process(argv, src, args.compile_timeout, env)
        r = {"name": step["name"], "check": step["check"]}
        errors = incremental_errors(err)
        if timed_out:
            r["status"] = "timeout"
        elif "[unsupported]" in err:
            r["status"], r["log"] = "unsupported", err[-LOG_LIMIT:]
        elif "BS_CACHE_VERIFY:" in err:
            r["status"], r["log"] = "verify", err[-LOG_LIMIT:]
        elif code < 0 or code != 0 and "panic: " in err and not errors:
            r["status"], r["crash"] = "crash", crash_frame(err)
        elif step["check"] == "errors":
            if code == 0:
                r["status"] = "missing_errors"
            elif errors == step["expected"]:
                r["status"] = "pass"
            else:
                r["expected"], r["got"] = step["expected"], errors or err[-LOG_LIMIT:]
                errs = lambda t: sorted(ln for ln in t.splitlines() if ": error: " in ln or ln.startswith("error: "))
                r["status"] = "errors" if errors and errs(errors) == errs(step["expected"]) else "wrong_errors"
        elif code != 0:
            r["status"], r["got"] = "unexpected_errors", errors or err[-LOG_LIMIT:]
        else:
            rcode, out, rerr, rtimed = run_process(exec_argv(bin_path), src, args.run_timeout)
            if rtimed or rcode != 0:
                r["status"], r["exit"], r["log"] = "run_failed", "timeout" if rtimed else rcode, rerr[-LOG_LIMIT:]
            elif stdout_matches(step["expected"], out):
                r["status"] = "pass"
            else:
                r["status"], r["expected"], r["got"] = "wrong_stdout", step["expected"], out[-LOG_LIMIT:]
        results.append(r)
        if r["status"] in ("crash", "timeout"):
            break
    shutil.rmtree(out_dir, ignore_errors=True)
    passed = sum(r["status"] == "pass" for r in results)
    return name, {"steps": results, "of": len(steps), "pass": passed}


def incremental_target(compiler, cfg, args, workdir):
    """--incremental: upstream's test/incremental cases, each update an
    edit build of the last, checked against the case's expectations. With
    BS_CACHE=off, every update is a full build, which tells analysis
    failures from the cache's."""
    paths = sorted(INCREMENTAL_ROOT.iterdir())
    if args.files:
        paths = [p for p in paths if p.name in args.files]
    results = {}
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = [ex.submit(run_one_incremental, compiler, p, cfg, args, workdir) for p in paths]
        for f in as_completed(futs):
            name, r = f.result()
            results[name] = r
    cases_passed = sum(r["pass"] == r["of"] for r in results.values())
    steps = sum(r["of"] for r in results.values())
    steps_passed = sum(r["pass"] for r in results.values())
    errors_steps = [s for r in results.values() for s in r["steps"] if s["check"] == "errors"]
    counts = {}
    for r in results.values():
        for s in r["steps"]:
            counts[s["status"]] = counts.get(s["status"], 0) + 1
        counts["not_run"] = counts.get("not_run", 0) + r["of"] - len(r["steps"])
    if not counts["not_run"]:
        del counts["not_run"]
    data = {
        "format": FORMAT,
        "target": cfg["name"],
        "compiler": str(compiler),
        "summary": {
            "cases": len(results),
            "cases_pass": cases_passed,
            "steps": steps,
            "steps_pass": steps_passed,
            "error_steps": len(errors_steps),
            "error_steps_pass": sum(s["status"] == "pass" for s in errors_steps),
            **counts,
        },
        "cases": dict(sorted(results.items())),
    }
    out_path = args.out or workdir / f"incremental-{cfg['name']}.json"
    write_json(out_path, data)
    fails = ", ".join(f"{counts[k]} {k.replace('_', ' ')}" for k in sorted(counts) if k != "pass")
    print(
        f"{cfg['name']} incremental: {cases_passed}/{len(results)} cases pass, {steps_passed}/{steps} updates "
        f"({data['summary']['error_steps_pass']}/{len(errors_steps)} of the error checks)"
        f"{'; ' + fails if fails else ''} -> {rel(out_path)}"
    )
    for n in sorted(results):
        for i, s in enumerate(results[n]["steps"]):
            if s["status"] != "pass":
                print(f"  {n} #{i} ({s['name']}): {s['status']}")


# ---------------------------------------------------------------- main


def use_zig_0_16(args):
    """Points the measures at bs's 0.16 language: upstream-0.16/'s tree,
    baseline/0.16/, zig 0.16.0 as the oracle (bs finds the same one), its
    test runner, and BS_ZIG_VERSION for every bs run. bs itself is still
    built with --zig, the 0.17.1 that builds bs."""
    global UPSTREAM_TEST, UPSTREAM_LIB, BASELINE_DIR, CASES_DIR, CASES_ROOT, STANDALONE_ROOT, INCREMENTAL_ROOT, ZIG_0_16
    ZIG_0_16 = True
    UPSTREAM_TEST = REPO / "upstream-0.16" / "test"
    UPSTREAM_LIB = REPO / "upstream-0.16" / "lib"
    BASELINE_DIR = HERE / "baseline" / "0.16"
    CASES_DIR = UPSTREAM_TEST / "cases" / "compile_errors"
    CASES_ROOT = UPSTREAM_TEST / "cases"
    STANDALONE_ROOT = UPSTREAM_TEST / "standalone"
    INCREMENTAL_ROOT = UPSTREAM_TEST / "incremental"
    host = {"Linux-x86_64": "x86_64-linux", "Darwin-arm64": "aarch64-macos"}.get(
        f"{platform.system()}-{platform.machine()}", ""
    )
    oracle = os.environ.get("BS_ZIG_0_16") or str(Path.home() / ".cache" / "bs" / f"zig-{host}-0.16.0" / "zig")
    args.bs_zig = "zig"
    if args.zig == "zig":
        args.zig = oracle
    os.environ["BS_ZIG_0_16"] = args.zig
    os.environ["BS_ZIG_VERSION"] = "0.16"
    if args.test_runner is None and not args.default_runner:
        args.test_runner = HERE / "test_runner_0_16.zig"


def main():
    global exec_prefix
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument(
        "--upstream", action="store_true", help="compute the upstream baseline with zig instead of running bs"
    )
    p.add_argument(
        "--target", action="append", choices=sorted(TARGETS), help="target to run (repeatable; default: all)"
    )
    p.add_argument("--bs", type=Path, help="bs executable (default: build bs with -Doptimize=ReleaseSafe)")
    p.add_argument(
        "--zig",
        default="zig",
        help="upstream zig 0.17.1, used for --upstream and to build bs (default: zig on PATH); with --zig-version 0.16, the 0.16.0 oracle (default: BS_ZIG_0_16, else where .agents/setup installs it), and bs is built with zig on PATH",
    )
    p.add_argument(
        "--test-runner",
        type=Path,
        help="test runner passed to the compiler (default: test_runner.zig, except bs_runner.zig for bs on x86_64-linux until bs compiles test_runner.zig there)",
    )
    p.add_argument(
        "--default-runner",
        action="store_true",
        help="bs only: build with the compiler's default test runner (upstream's lib/compiler/test_runner.zig), as `bs test` without --test-runner does",
    )
    p.add_argument(
        "--std",
        action="store_true",
        help="measure upstream's std tests (lib/std/std.zig, default runner) instead of test/behavior",
    )
    p.add_argument(
        "--libc",
        action="store_true",
        help="with --std: link glibc (-lc, -target <arch>-linux-gnu), baseline/std-<target>-gnu-libc.json",
    )
    p.add_argument(
        "--musl",
        action="store_true",
        help="with --std: link musl (-lc, -target <arch>-linux-musl), baseline/std-<target>-musl-libc.json",
    )
    p.add_argument(
        "--c-abi",
        action="store_true",
        help="measure upstream's test/c_abi (main.zig with cfuncs.c, -lc, -target <arch>-linux-gnu) instead of test/behavior, against baseline/c-abi-<target>.json",
    )
    p.add_argument(
        "--compile-errors",
        action="store_true",
        help="bs only: measure diagnostics on upstream's test/cases/compile_errors instead of test/behavior",
    )
    p.add_argument(
        "--cases",
        action="store_true",
        help="measure upstream's test/cases outside compile_errors (run, compile and error cases), against baseline/cases-<target>.json",
    )
    p.add_argument(
        "--standalone",
        action="store_true",
        help="measure upstream's test/standalone projects, each built with `build` (its default step), against baseline/standalone-<target>.json",
    )
    p.add_argument(
        "--langref",
        action="store_true",
        help="measure upstream's doc/langref examples, each built and run as upstream's doctest does and compared with baseline/langref-<target>.json",
    )
    p.add_argument(
        "--incremental",
        action="store_true",
        help="bs only: run upstream's test/incremental cases, each update an edit build checked against the case",
    )
    p.add_argument(
        "--mcpu",
        help="behavior and std: build for this CPU (such as native, as bs's native target defaults to), "
        "still compared with the baseline CPU's committed results",
    )
    p.add_argument("--files", nargs="+", help="only run these units, e.g. basic.zig behavior.zig")
    p.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4, help="files compiled and run in parallel")
    p.add_argument("--compile-timeout", type=float, default=300, help="seconds per file compile")
    p.add_argument("--run-timeout", type=float, default=60, help="seconds per test binary run")
    p.add_argument(
        "--zig-version",
        choices=("0.16", "0.17"),
        default="0.17",
        help="the Zig language to measure: its upstream tree, baselines, oracle zig and test runner (default 0.17)",
    )
    p.add_argument("--workdir", type=Path, help="scratch directory (default .zig-cache/conformance, -0.16 for 0.16)")
    p.add_argument("--out", type=Path, help="JSON output path (only with one --target)")
    p.add_argument("--keep-binaries", action="store_true", help="keep test binaries in the workdir")
    p.add_argument(
        "--edit-verify",
        action="store_true",
        help="bs only: verify each file's first build (which a donor may seed), then edit it and build again, then restore it and build once more, checking each edit build against a full build (BS_CACHE_VERIFY, BS_CACHE_CHECK); a difference fails the file as edit_verify_failed",
    )
    p.add_argument(
        "--sched-check",
        action="store_true",
        help="bs only: also build each file again on one thread four ways (code generated as each function is analyzed, BS_SCHED_FUZZ=late, BS_SCHED_FUZZ=sema:<seed>, and BS_COMPTIME_EVAL=1), each a full build checked node by node against its last build (BS_CACHE_VERIFY=full), which must give identical binaries; a difference fails the file as sched_check_failed. With --std or --c-abi: build the suite again with BS_COMPTIME_EVAL=0, =1, and =0, checked the same way",
    )
    p.add_argument(
        "--sched-seed", type=int, default=0, help="for --sched-check: added to each file's seed for BS_SCHED_FUZZ=sema"
    )
    p.add_argument("-v", "--verbose", action="store_true", help="print each file's result to stderr")
    args = p.parse_args()
    args.bs_zig = args.zig
    if args.zig_version == "0.16":
        use_zig_0_16(args)
    if args.workdir is None:
        args.workdir = REPO / ".zig-cache" / ("conformance-0.16" if args.zig_version == "0.16" else "conformance")

    if args.test_runner is not None:
        args.test_runner = args.test_runner.resolve()
    args.workdir = args.workdir.resolve()
    args.workdir.mkdir(parents=True, exist_ok=True)
    targets = args.target or list(TARGETS)
    if args.out and len(targets) != 1:
        p.error("--out needs exactly one --target")
    if not (UPSTREAM_TEST / "behavior.zig").exists():
        sys.exit(f"error: {UPSTREAM_TEST} is missing; run .agents/setup")
    # Upstream's own tree turns lint off with a .bs.zon at its root and
    # beside each build.zig, written by .agents/setup and the flake
    # (`lint_off`).
    for d in (UPSTREAM_TEST.parent, UPSTREAM_TEST.parent / "doc" / "langref"):
        if not (d / ".bs.zon").exists():
            sys.exit(f"error: {d / '.bs.zon'} is missing; run .agents/setup")
    lint_off(args.workdir)

    host = (platform.system(), platform.machine())
    # Compile errors need no binary run, so any host measures any target.
    runnable = [t for t in targets if args.compile_errors or TARGETS[t]["host"] == host or emulator(TARGETS[t], host)]
    compiler = None
    if runnable:
        if args.upstream:
            compiler = shutil.which(args.zig) or sys.exit(f"error: {args.zig} not found")
        else:
            compiler = args.bs.resolve() if args.bs else build_bs(args.workdir, args.bs_zig)
    try:
        for name in targets:
            cfg = dict(TARGETS[name], name=name)
            exec_prefix = [] if cfg["host"] == host else emulator(cfg, host) or []
            # A --mcpu CPU may have instructions the emulated baseline core
            # lacks; qemu's `max` has every one bs generates.
            if exec_prefix and args.mcpu and "-cpu" in exec_prefix:
                exec_prefix = exec_prefix.copy()
                exec_prefix[exec_prefix.index("-cpu") + 1] = "max"
            if name not in runnable:
                print(f"{name}: not run (needs an {name} host or its emulator)")
            elif args.compile_errors:
                compile_errors_target(compiler, cfg, args, args.workdir)
            elif args.cases:
                cases_target(compiler, cfg, args, args.workdir)
            elif args.standalone:
                standalone_target(compiler, cfg, args, args.workdir)
            elif args.langref:
                langref_target(compiler, cfg, args, args.workdir)
            elif args.incremental:
                incremental_target(compiler, cfg, args, args.workdir)
            elif args.std or args.c_abi:
                std_target(compiler, cfg, args, args.workdir)
            elif args.upstream:
                upstream_target(compiler, cfg, args, args.workdir)
            else:
                bs_target(compiler, cfg, args, args.workdir)
            sys.stdout.flush()
    except KeyboardInterrupt:
        kill_all()
        sys.exit(130)


if __name__ == "__main__":
    main()
