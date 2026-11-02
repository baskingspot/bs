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
(default: test_runner.zig next to this file); results are parsed from the
runner's "@zap-test" line protocol, documented in test_runner.zig, so any
runner that speaks it works. A crash or timeout marks the running test and
the binary is rerun with --start=<next index> to run the rest.

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


def unit_root(unit, workdir):
    """The unit's root source file, generated if needed."""
    if unit == ROOT_UNIT:
        return UPSTREAM_TEST / "behavior.zig"
    unit_dir = workdir / "units" / unit[: -len(".zig")]
    unit_dir.mkdir(parents=True, exist_ok=True)
    link = unit_dir / "behavior"
    if not link.is_symlink() or os.readlink(link) != str(UPSTREAM_TEST / "behavior"):
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


def run_process(argv, cwd, timeout):
    """Runs argv in its own process group. Returns (returncode, stdout, stderr,
    timed_out); returncode is negative for a signal, as in subprocess."""
    proc = subprocess.Popen(
        argv,
        cwd=cwd,
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


def compile_unit(compiler, unit, cfg, args, workdir):
    bin_path = workdir / "bin" / cfg["name"] / (unit[: -len(".zig")] + ".test")
    bin_path.parent.mkdir(parents=True, exist_ok=True)
    if bin_path.exists():
        bin_path.unlink()
    argv = [
        str(compiler), "test", str(unit_root(unit, workdir)),
        "--test-runner", str(args.test_runner),
        "-target", cfg["zig_target"],
        "--test-no-exec",
        f"-femit-bin={bin_path}",
    ]
    for f in unit_filters(unit):
        argv += ["--test-filter", f]
    code, out, err, timed_out = run_process(argv, workdir, args.compile_timeout)
    if code == 0 and not timed_out and bin_path.exists():
        return bin_path, None
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


def run_one(compiler, unit, cfg, args, workdir):
    bin_path, failure = compile_unit(compiler, unit, cfg, args, workdir)
    if failure:
        return failure
    try:
        return run_unit(bin_path, lambda name: unit_owns(unit, name), args, workdir)
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


def build_zap(workdir):
    prefix = workdir / "zap"
    argv = ["zig", "build", "-Doptimize=ReleaseSafe", "-p", str(prefix)]
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
        "test_runner": str(args.test_runner),
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
        f"{cfg['name']}: {passed}/{expected} behavior tests pass ({pct:.1f}% of upstream); "
        f"{ok_files}/{len(files)} files compiled and ran"
        f"{'; ' + problems if problems else ''}{note} -> {rel(out)}"
    )


# ---------------------------------------------------------------- main


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--upstream", action="store_true", help="compute the upstream baseline with zig instead of running zap")
    p.add_argument("--target", action="append", choices=sorted(TARGETS), help="target to run (repeatable; default: all)")
    p.add_argument("--zap", type=Path, help="zap executable (default: build zap with -Doptimize=ReleaseSafe)")
    p.add_argument("--zig", default="zig", help="upstream zig 0.17.0 for --upstream (default: zig on PATH)")
    p.add_argument("--test-runner", type=Path, default=HERE / "test_runner.zig", help="test runner passed to the compiler")
    p.add_argument("--files", nargs="+", help="only run these units, e.g. basic.zig behavior.zig")
    p.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4, help="files compiled and run in parallel")
    p.add_argument("--compile-timeout", type=float, default=300, help="seconds per file compile")
    p.add_argument("--run-timeout", type=float, default=60, help="seconds per test binary run")
    p.add_argument("--workdir", type=Path, default=REPO / ".zig-cache" / "conformance", help="scratch directory")
    p.add_argument("--out", type=Path, help="JSON output path (only with one --target)")
    p.add_argument("--keep-binaries", action="store_true", help="keep test binaries in the workdir")
    p.add_argument("-v", "--verbose", action="store_true", help="print each file's result to stderr")
    args = p.parse_args()

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
            compiler = args.zap.resolve() if args.zap else build_zap(args.workdir)
    try:
        for name in targets:
            cfg = dict(TARGETS[name], name=name)
            if name not in runnable:
                print(f"{name}: not run (needs an {name} host)")
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
