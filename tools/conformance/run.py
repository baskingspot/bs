#!/usr/bin/env python3
"""Conformance harness: upstream Zig 0.17.0's test/behavior, compiled by zap.

The measure, per target: the behavior tests zap compiles and passes, divided by
the tests upstream zig 0.17.0 passes on that target with its default Debug
backend. Upstream's per-test results are committed in baseline/<target>.json.

    tools/conformance/run.py              # build zap, run it on every target this host can run
    tools/conformance/run.py --upstream   # recompute baseline/<target>.json with upstream zig

Each run prints one summary line per target to stdout and writes a per-file,
per-test JSON breakdown (zap: .zig-cache/conformance/<target>.json).

Every file that upstream/test/behavior.zig imports is compiled and run on its
own (see "units" below), so one file that fails to compile or crashes does not
hide the others. Tests are identified by the fully qualified names that
upstream's own test step reports (for example "behavior.basic.test.truncate"),
which is what the compiler puts in builtin.test_functions.

The compiler builds each unit with the test runner given by --test-runner
(default: test_runner.zig for upstream, zap_runner.zig for zap); results are parsed from the
runner's "@zap-test" line protocol, documented in test_runner.zig, so any
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
baseline/std-<target>-gnu-libc.json.

With --c-abi, the measure is upstream's C ABI tests instead:
test/c_abi/main.zig with cfuncs.c (-std=c99), linked against glibc
(-lc, -target <arch>-linux-gnu), built and run like --std, as upstream's
test-c-abi step builds its self-hosted entry (which uses musl, which zap
does not link), and compared with baseline/c-abi-<target>.json.

With --compile-errors, the measure is diagnostics instead: every case in
upstream's test/cases/compile_errors that applies to the target, compiled
by zap as upstream's case harness compiles it: as a root file named
tmp.zig, so that its types are named `tmp.T`, in a module named root
(`-Mroot=`), with build-obj, or build-exe
or test when the case says so. A case is "exact" when zap reports the same
error lines (location and message) as the case expects, "same location"
when only the messages differ, and otherwise "different", "accepted" (no
error), "crash" or "timeout". Notes are compared separately.

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
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
UPSTREAM_TEST = REPO / "upstream" / "test"
UPSTREAM_LIB = REPO / "upstream" / "lib"
BASELINE_DIR = HERE / "baseline"
FORMAT = 1

# zap's targets, the `-target` both compilers get, and the host that can run
# the test binaries (platform.system(), platform.machine()). The zig targets
# match upstream's own test matrix entries in test/tests.zig, whose Debug
# builds use the default backend: self-hosted x86_64 on x86_64-linux, LLVM on
# aarch64-macos (see selfHostedBackendIsAsRobustAsLlvm in src/target.zig).
TARGETS = {
    "x86_64-linux": {"zig_target": "x86_64-linux-none", "host": ("Linux", "x86_64")},
    "aarch64-macos": {"zig_target": "aarch64-macos-none", "host": ("Darwin", "arm64")},
}

ROOT_UNIT = "behavior.zig"
ROOT_TEST_RE = re.compile(r"^behavior\.(test\.|test_\d+$)")
PROTOCOL_PREFIX = "@zap-test "
TEST_OUTCOMES = ("pass", "skip", "fail", "leak", "crash", "timeout", "not_run")
LOG_LIMIT = 4000
STATUS_LABELS = {
    "compile_error": "compile errors",
    "compile_crash": "compiler crashes",
    "compile_timeout": "compile timeouts",
    "incomplete": "incomplete runs",
    "edit_verify_failed": "edit-verify failures",
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
            lines = lines[i + 1:]
            break
    stderr = "\n".join(lines).strip()
    return stderr if len(stderr) <= 1500 else stderr[:1500] + "\n..."


def tail(text, limit=LOG_LIMIT):
    text = text.strip()
    return text if len(text) <= limit else "...\n" + text[-limit:]


# ---------------------------------------------------------------- one unit


def compile_unit(compiler, unit, cfg, args, workdir, env=None):
    bin_path = workdir / "bin" / cfg["name"] / (unit[: -len(".zig")] + ".test")
    bin_path.parent.mkdir(parents=True, exist_ok=True)
    if bin_path.exists():
        bin_path.unlink()
    editable = args.edit_verify and unit != ROOT_UNIT
    argv = [str(compiler), "test", str(unit_root(unit, workdir, editable) if env is None else workdir / "units" / unit[: -len(".zig")] / "behavior.zig")]
    if not args.default_runner:
        argv += ["--test-runner", str(args.test_runner)]
    argv += ["-target", cfg["zig_target"], "--test-no-exec", f"-femit-bin={bin_path}"]
    for f in unit_filters(unit):
        argv += ["--test-filter", f]
    code, out, err, timed_out = run_process(argv, workdir, args.compile_timeout, env)
    if code == 0 and not timed_out and bin_path.exists():
        return bin_path, None
    if env is not None:
        return None, {"status": "edit_verify_failed", "log": describe_exit(code, timed_out, args.compile_timeout) + "\n" + tail(err + out), "tests": {}}
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
        code, out, err, timed_out = run_process(
            [str(bin_path), f"--start={start}"], workdir, args.run_timeout
        )
        current = None
        first_start = None
        count = None
        done = False
        for line in out.splitlines():
            if not line.startswith(PROTOCOL_PREFIX):
                continue
            parts = line[len(PROTOCOL_PREFIX):].split(" ", 2)
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
# Upstream's lib/compiler/test_runner.zig speaks no @zap-test protocol. Run as
# `zig test` runs it (no arguments, stderr not a terminal), it writes
# "<i>/<n> <name>..." before each test and "OK", "SKIP" or "FAIL (<error>)"
# after it; testing.allocator reports leaks after the result, and the run
# ends with "All <n> tests passed." or "<p> passed; <s> skipped; <f> failed.".
# With --listen=- it is a std.zig.Server that runs the tests it is asked for.

CLIENT_EXIT, CLIENT_QUERY_TEST_METADATA, CLIENT_RUN_TEST = 0, 4, 5
SERVER_ZIG_VERSION, SERVER_TEST_METADATA, SERVER_TEST_RESULTS, SERVER_TEST_STARTED = 0, 3, 4, 5
TERMINAL_SUMMARY_RE = re.compile(r"^(All \d+ tests passed\.|\d+ passed; \d+ skipped; \d+ failed\.)", re.M)


class ServerSession:
    """A test binary run with --listen=-, driven like `zig build test`."""

    def __init__(self, bin_path, workdir):
        self.proc = subprocess.Popen(
            [str(bin_path), "--listen=-"], cwd=workdir, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
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
        offs = [int.from_bytes(body[8 + 4 * i:12 + 4 * i], "little") for i in range(n)]
        strings = body[8 + 8 * n:8 + 8 * n + strings_len]
        names = [strings[o:strings.index(b"\0", o)].decode("utf-8", "replace") for o in offs]
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
                seg = seg[:m.start()]
        m = re.search(r"(?:^|(?<=\.\.\.)|\n)(OK|SKIP|FAIL \((.*?)\))\n", seg)
        if not m:
            out[i] = (None, seg)
            continue
        if m.group(1) == "OK":
            out[i] = ("leak" if "leaked" in seg[m.end():] else "pass", None)
        elif m.group(1) == "SKIP":
            out[i] = ("skip", None)
        else:
            out[i] = ("fail", m.group(2))
    return out


def run_unit_default(bin_path, owns, args, workdir):
    names, err = query_test_names(bin_path, args, workdir)
    if names is None:
        return {"status": "incomplete", "log": "the test runner did not answer on --listen=-\n" + tail(err or ""), "tests": {}}
    by_index = {}
    code, out, err, timed_out = run_process([str(bin_path)], workdir, args.run_timeout)
    parsed = parse_terminal(err, names)
    for i, (outcome, detail) in parsed.items():
        by_index[i] = [outcome, detail]
    status, log = "ok", None
    finished = TERMINAL_SUMMARY_RE.search(err) is not None and len(parsed) == len(names) and all(o for o, _ in parsed.values())
    if not finished:
        how = describe_exit(code, timed_out, args.run_timeout)
        if not parsed or by_index[max(parsed)][0] is not None:
            if len(parsed) != len(names):
                status, log = "incomplete", how + "\n" + tail(err)
        else:
            last = max(parsed)
            by_index[last] = ["timeout" if timed_out else "crash", how + "\n" + crash_log(by_index[last][1] or "")]
            # The rest, one at a time through the server protocol.
            start = last + 1
            while start < len(names):
                s = ServerSession(bin_path, workdir)
                current = None
                try:
                    tag, _ = s.receive(time.monotonic() + args.run_timeout)
                    for i in range(start, len(names)):
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
                        status, log = "incomplete", "the test runner did not answer on --listen=-\n" + tail(serr)
                        break
                    code = s.proc.returncode
                    by_index[current] = ["timeout" if timed else "crash", describe_exit(code, timed, args.run_timeout) + "\n" + tail(serr, 1500)]
                    start = current + 1
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
    that zap checks against a full build (ZAP_CACHE_VERIFY) with its
    dependency checks on (ZAP_CACHE_CHECK). The edits move every line,
    change a test's body, and add a declaration. Returns the last build's
    binary and a failure, if any."""
    path = workdir / "units" / unit[: -len(".zig")] / "behavior" / unit
    original = path.read_text()
    lines = original.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if re.match(r"^test\b.*\{\s*$", line):
            lines.insert(i + 1, "    _ = 0;\n")
            break
    edited = "// zap edit-verify\n" + "".join(lines) + "\npub const zap_edit_probe: u32 = 1;\n"
    env = dict(os.environ, ZAP_CACHE_VERIFY="1", ZAP_CACHE_CHECK="1")
    result = None, None
    for text in (edited, original):
        path.write_text(text)
        result = compile_unit(compiler, unit, cfg, args, workdir, env)
        if result[1]:
            break
    path.write_text(original)
    return result


def run_one(compiler, unit, cfg, args, workdir):
    bin_path, failure = compile_unit(compiler, unit, cfg, args, workdir)
    if failure:
        return failure
    if args.edit_verify and unit != ROOT_UNIT:
        bin_path, failure = edit_verify(compiler, unit, cfg, args, workdir)
        if failure:
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
        str(zig), "test", str(UPSTREAM_TEST / "behavior.zig"),
        "--test-runner", str(args.test_runner),
        "-target", cfg["zig_target"], "--test-no-exec", f"-femit-bin={bin_path}",
    ]
    code, out, err, timed_out = run_process(argv, workdir, args.compile_timeout * 4)
    if code != 0 or timed_out:
        sys.exit(f"error: compiling all of behavior.zig failed ({describe_exit(code, timed_out, args.compile_timeout * 4)}):\n{tail(err)}")
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
    for unit, r in files.items():
        for key, outcome in r["tests"].items():
            per_file[key] = outcome
    mismatches = {}
    if not args.files:
        for key in sorted(set(full) | set(per_file)):
            a, b = full.get(key, "absent"), per_file.get(key, "absent")
            if a != b:
                mismatches[key] = {"full_run": a, "per_file": b}

    counts = count_outcomes(per_file.values())
    zig_version = subprocess.run([str(zig), "version"], capture_output=True, text=True).stdout.strip()
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
    check = "full-run cross-check identical" if not mismatches else f"full-run cross-check: {len(mismatches)} mismatches"
    if args.files:
        check = "full-run cross-check skipped (--files)"
    print(
        f"{cfg['name']}: upstream zig {zig_version} ({backend}): {counts['pass']} pass, "
        f"{counts['skip']} skip, {counts['fail'] + counts['leak'] + counts['crash'] + counts['timeout']} fail "
        f"of {len(per_file)} tests in {len(files)} files run individually; {check} -> {rel(out)}"
    )


# ---------------------------------------------------------------- zap mode


def build_zap(workdir, zig):
    prefix = workdir / "zap"
    argv = [zig, "build", "-Doptimize=ReleaseSafe", "-p", str(prefix)]
    proc = subprocess.run(argv, cwd=REPO, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"error: building zap failed:\n{proc.stderr}")
    return prefix / "bin" / ("zap.exe" if os.name == "nt" else "zap")


def zap_target(zap, cfg, args, workdir):
    baseline_path = BASELINE_DIR / f"{cfg['name']}.json"
    if not baseline_path.exists():
        print(f"{cfg['name']}: no baseline; run with --upstream on a {cfg['name']} host first")
        return
    baseline = json.loads(baseline_path.read_text())
    units = list(baseline["files"])
    if args.files:
        units = [u for u in units if u in args.files]
    files = run_units(zap, units, cfg, args, workdir)
    backend = pop_backends(files)

    passed = expected = extra = unknown = 0
    for unit in units:
        r = files[unit]
        upstream_tests = baseline["files"][unit]["tests"]
        zap_tests = r["tests"]
        # Upstream's tests come first, in upstream order, with zap's outcome;
        # tests upstream did not report follow.
        merged = {}
        for key, up in upstream_tests.items():
            got = zap_tests.get(key, "not_run")
            merged[key] = {"upstream": up, "zap": got}
            if up == "pass":
                expected += 1
                passed += got == "pass"
            elif got == "pass":
                extra += 1
        for key, got in zap_tests.items():
            if key not in upstream_tests:
                merged[key] = {"upstream": "absent", "zap": got}
                unknown += 1
        r["tests"] = merged
        r["pass"] = sum(1 for t in merged.values() if t["upstream"] == "pass" and t["zap"] == "pass")
        r["of"] = sum(1 for t in merged.values() if t["upstream"] == "pass")

    statuses = count_statuses(files)
    pct = 100.0 * passed / expected if expected else 0.0
    data = {
        "format": FORMAT,
        "target": cfg["name"],
        "zig_target": cfg["zig_target"],
        "compiler": str(zap),
        "test_runner": "default" if args.default_runner else str(args.test_runner),
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
    suite = "c-abi" if args.c_abi else "std"
    gnu = args.libc or args.c_abi
    if gnu:
        cfg = dict(cfg, zig_target=cfg["zig_target"].rsplit("-", 1)[0] + "-gnu")
    if args.libc:
        cfg = dict(cfg, name=cfg["name"] + "-gnu-libc")
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
        sources = [str(UPSTREAM_TEST / "c_abi" / "main.zig"), "-cflags", "-std=c99", "--", str(UPSTREAM_TEST / "c_abi" / "cfuncs.c")]
    else:
        sources = [str(UPSTREAM_LIB / "std" / "std.zig")]
    argv = [str(compiler), "test"] + sources + [
        "--zig-lib-dir", str(UPSTREAM_LIB),
        "-target", cfg["zig_target"], "--test-no-exec", f"-femit-bin={bin_path}",
    ] + (["-lc"] if gnu else [])
    if args.upstream:
        # A fresh cache, so that the baseline's compile time is a cold build.
        cache = workdir / f"{suite}-zig-cache"
        shutil.rmtree(cache, ignore_errors=True)
        argv += ["--cache-dir", str(cache / "local"), "--global-cache-dir", str(cache / "global")]
    timeout = args.compile_timeout * 4
    start = time.monotonic()
    code, out, err, timed_out = run_process(argv, workdir, timeout)
    compile_s = time.monotonic() - start
    if code == 0 and not timed_out and bin_path.exists():
        run_args = argparse.Namespace(**vars(args))
        run_args.run_timeout = max(args.run_timeout, 600)
        try:
            r = run_unit_default(bin_path, lambda _name: True, run_args, workdir)
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
        zig_version = subprocess.run([str(compiler), "version"], capture_output=True, text=True).stdout.strip()
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
    # Upstream's tests first, in upstream order, with zap's outcome.
    merged = {}
    passed = expected = 0
    for key, up in baseline["tests"].items():
        got = r["tests"].get(key, "not_run")
        merged[key] = {"upstream": up, "zap": got}
        if up == "pass":
            expected += 1
            passed += got == "pass"
    for key, got in r["tests"].items():
        if key not in merged:
            merged[key] = {"upstream": "absent", "zap": got}
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
    for ln in src[at + len("\n// error\n"):].splitlines():
        # As upstream's manifest parser: `//` then optional whitespace.
        text = ln[2:].strip(" \t") if ln.startswith("//") else ""
        m = re.match(r"^(\w+)=(.*)$", text)
        if m and not expected:
            cfg[m.group(1)] = m.group(2)
        elif text:
            # Upstream names the case file itself as 'tmp.zig:' when the
            # errors span several files; zap_lines() writes it as ':'.
            if text.startswith("tmp.zig:"):
                text = text[len("tmp.zig"):]
            # Some cases omit the leading ':' before the line.
            elif re.match(r"^\d+:\d+: (error|note): ", text):
                text = ":" + text
            expected.append(text)
    return cfg, expected


def case_applies(cfg, target):
    targets = cfg.get("target", "native").split(",")
    arch_os = target.split("-")[:2]
    if not any(t == "native" or t.split("-")[:2] == arch_os or t in ("x86_64-native", "native-linux") and arch_os == ["x86_64", "linux"] for t in targets):
        return False
    return all(b in ("auto", "selfhosted", "stage2") for b in cfg.get("backend", "auto").split(","))


def zap_lines(stderr, case_name):
    """zap's diagnostics (--error-format=json) as upstream-style
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
        errors.append(f"{prefix}{d.get('line', 0)}:{d.get('col', 0)}: error: {d['msg']}")
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
            msg = ("called inline here" if c["kind"] == "inline" else "called at comptime here") + times(c)
            notes.append(f":{c['line']}:{c['col']}: note: {msg}" if here(c) else f"?: note: {msg}")
    return errors, notes


def other_note(line):
    """Upstream's note outside the case file (':?:?: note:' or a bare
    'note:'), as zap_lines() writes one; None for other lines."""
    m = re.match(r"^(?::\?:\?: )?note: (.*)$", line)
    return f"?: note: {m.group(1)}" if m else None


def crash_frame(stderr):
    """The first frame of a crash's stack trace in zap's own source."""
    for ln in stderr.splitlines():
        m = re.search(r"/src/(\S+?\.zig:\d+):\d+: 0x[0-9a-f]+ in", ln)
        if m:
            return m.group(1)
    return "?"


def run_case(compiler, path, cfg, expected, args, workdir):
    out_dir = workdir / "compile-errors" / path.stem
    out_dir.mkdir(parents=True, exist_ok=True)
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
    argv.append("--error-format=json")
    code, out, err, timed_out = run_process(argv, workdir, args.compile_timeout)
    shutil.rmtree(out_dir, ignore_errors=True)
    exp_errors = [e for e in expected if LOC_RE.match(e) and LOC_RE.match(e).group("kind") == "error"]
    exp_notes = [e for e in expected if LOC_RE.match(e) and LOC_RE.match(e).group("kind") == "note"] + [o for o in map(other_note, expected) if o]
    r = {"expected": exp_errors}
    if timed_out:
        r["status"] = "timeout"
    elif code < 0 or "panic: " in err and not re.search(r"^\S+:\d+:\d+: error", err, re.M):
        r["status"], r["crash"] = "crash", crash_frame(err)
    elif code == 0:
        r["status"] = "accepted"
    else:
        errors, notes = zap_lines(err, root.name)
        r["got"] = errors
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
    """--compile-errors: upstream's compile-error cases, compiled by zap."""
    if args.upstream:
        sys.exit("error: --compile-errors measures zap; the cases' expectations are upstream's")
    # Failing builds record nothing worth reusing across cases.
    os.environ["ZAP_CACHE"] = "off"
    cases = []
    for path in sorted(CASES_DIR.rglob("*.zig")):
        parsed = parse_case(path)
        if parsed and case_applies(parsed[0], cfg["zig_target"]):
            cases.append((path, *parsed))
    if args.files:
        cases = [c for c in cases if c[0].name in args.files]
    results = {}
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = [ex.submit(run_case, compiler, p, c, e, args, workdir) for p, c, e in cases]
        for f in as_completed(futs):
            name, r = f.result()
            results[name] = r
            if args.verbose:
                print(f"  {name}: {r['status']}{' ' + r.get('crash', '') if r['status'] == 'crash' else ''}", file=sys.stderr)
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


# ---------------------------------------------------------------- main


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--upstream", action="store_true", help="compute the upstream baseline with zig instead of running zap")
    p.add_argument("--target", action="append", choices=sorted(TARGETS), help="target to run (repeatable; default: all)")
    p.add_argument("--zap", type=Path, help="zap executable (default: build zap with -Doptimize=ReleaseSafe)")
    p.add_argument("--zig", default="zig", help="upstream zig 0.17.0, used for --upstream and to build zap (default: zig on PATH)")
    p.add_argument("--test-runner", type=Path, help="test runner passed to the compiler (default: test_runner.zig for --upstream, zap_runner.zig for zap until zap compiles test_runner.zig)")
    p.add_argument("--default-runner", action="store_true", help="zap only: build with the compiler's default test runner (upstream's lib/compiler/test_runner.zig), as `zap test` without --test-runner does")
    p.add_argument("--std", action="store_true", help="measure upstream's std tests (lib/std/std.zig, default runner) instead of test/behavior")
    p.add_argument("--libc", action="store_true", help="with --std: link glibc (-lc, -target <arch>-linux-gnu), baseline/std-<target>-gnu-libc.json")
    p.add_argument("--c-abi", action="store_true", help="measure upstream's test/c_abi (main.zig with cfuncs.c, -lc, -target <arch>-linux-gnu) instead of test/behavior, against baseline/c-abi-<target>.json")
    p.add_argument("--compile-errors", action="store_true", help="zap only: measure diagnostics on upstream's test/cases/compile_errors instead of test/behavior")
    p.add_argument("--files", nargs="+", help="only run these units, e.g. basic.zig behavior.zig")
    p.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4, help="files compiled and run in parallel")
    p.add_argument("--compile-timeout", type=float, default=300, help="seconds per file compile")
    p.add_argument("--run-timeout", type=float, default=60, help="seconds per test binary run")
    p.add_argument("--workdir", type=Path, default=REPO / ".zig-cache" / "conformance", help="scratch directory")
    p.add_argument("--out", type=Path, help="JSON output path (only with one --target)")
    p.add_argument("--keep-binaries", action="store_true", help="keep test binaries in the workdir")
    p.add_argument("--edit-verify", action="store_true", help="zap only: after each file's build, edit it and build again, then restore it and build once more, checking each edit build against a full build (ZAP_CACHE_VERIFY, ZAP_CACHE_CHECK); a difference fails the file as edit_verify_failed")
    p.add_argument("-v", "--verbose", action="store_true", help="print each file's result to stderr")
    args = p.parse_args()

    if args.test_runner is None:
        args.test_runner = HERE / ("test_runner.zig" if args.upstream else "zap_runner.zig")
    args.test_runner = args.test_runner.resolve()
    args.workdir = args.workdir.resolve()
    args.workdir.mkdir(parents=True, exist_ok=True)
    targets = args.target or list(TARGETS)
    if args.out and len(targets) != 1:
        p.error("--out needs exactly one --target")
    if not (UPSTREAM_TEST / "behavior.zig").exists():
        sys.exit(f"error: {UPSTREAM_TEST} is missing; run .agents/setup")

    host = (platform.system(), platform.machine())
    runnable = [t for t in targets if TARGETS[t]["host"] == host]
    compiler = None
    if runnable:
        if args.upstream:
            compiler = shutil.which(args.zig) or sys.exit(f"error: {args.zig} not found")
        else:
            compiler = args.zap.resolve() if args.zap else build_zap(args.workdir, args.zig)
    try:
        for name in targets:
            cfg = dict(TARGETS[name], name=name)
            if name not in runnable:
                print(f"{name}: not run (needs an {name} host)")
            elif args.compile_errors:
                compile_errors_target(compiler, cfg, args, args.workdir)
            elif args.std or args.c_abi:
                std_target(compiler, cfg, args, args.workdir)
            elif args.upstream:
                upstream_target(compiler, cfg, args, args.workdir)
            else:
                zap_target(compiler, cfg, args, args.workdir)
            sys.stdout.flush()
    except KeyboardInterrupt:
        kill_all()
        sys.exit(130)


if __name__ == "__main__":
    main()
