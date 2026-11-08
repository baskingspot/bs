#!/usr/bin/env python3
"""Differential hunter for bs's comptime evaluation and Sema (see README.md).

Generates programs of independent comptime tests (gen.py), compiles each
with upstream zig 0.17.1 (the oracle) and with bs, and compares which
tests each compiler rejects and, for the tests upstream accepts, the
values the program prints. bs runs three ways: as it is (`bs`), with
its comptime evaluator off (`bs-walk`, BS_COMPTIME_EVAL=0), and with
the evaluator taking every function after one walker run (`bs-eval1`,
BS_COMPTIME_EVAL=1), so a finding says whether the walker or the
evaluator is at fault.

Each target given with --target is a leg of its own: both compilers
build for it, and aarch64-linux binaries run under qemu's user-mode
emulator (qemu-aarch64-static, or qemu-aarch64), so layouts, C ABI types
and vector sizes that differ between targets are compared too.

    python3 tools/cthunt/hunt.py                   # hunt until interrupted
    python3 tools/cthunt/hunt.py --count 500       # 500 programs
    python3 tools/cthunt/hunt.py --one 1234        # one seed, with its outcomes
    python3 tools/cthunt/hunt.py --file p.zig      # one saved program
    python3 tools/cthunt/hunt.py --target x86_64-linux --target aarch64-linux
"""

import argparse
import concurrent.futures as cf
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(os.path.dirname(TOOL_DIR))
WORK = os.path.join(TOOL_DIR, ".work")
FOUND = os.path.join(WORK, "found")
sys.path.insert(0, TOOL_DIR)
import gen

COMPILE_TIMEOUT = 120
RUN_TIMEOUT = 10

# Name -> (compiler, environment).
CONFIGS = {
    "zig": ("zig", {}),
    "bs": ("bs", {}),
    "bs-walk": ("bs", {"BS_COMPTIME_EVAL": "0"}),
    "bs-eval1": ("bs", {"BS_COMPTIME_EVAL": "1"}),
    # Upstream with LLVM, which rechecks a value upstream's self-hosted
    # x86_64 backend prints: it trusts the bits above a narrow integer's
    # width in memory (a packed union's signed field after an unsigned
    # one was written gives 5, not -3), where LLVM and bs extend.
    "zig-llvm": ("zig", {}),
}
BS_CONFIGS = ["bs", "bs-walk", "bs-eval1"]
SAVE = [True]


def log(msg):
    print(time.strftime("%H:%M:%S ") + msg, file=sys.stderr, flush=True)


TARGETS = ("x86_64-linux", "aarch64-linux")


class Tools:
    def __init__(self, bs=None, zig=None, target="x86_64-linux"):
        self.bs = os.path.abspath(bs or os.path.join(REPO_DIR, "zig-out", "bin", "bs"))
        self.zig = zig or shutil.which("zig") or "zig"
        self.target = target
        # Same CPU as tools/conformance/run.py's aarch64-linux leg.
        qemu = shutil.which("qemu-aarch64-static") or shutil.which("qemu-aarch64") or "qemu-aarch64"
        self.runner = [] if target == "x86_64-linux" else [qemu, "-cpu", "cortex-a53"]

    def leg(self, target):
        return Tools(self.bs, self.zig, target)


class Build:
    """One compile and, if it produced a binary, its run. `status` is
    "ok", "error" (compile errors), "crash" (the compiler crashed),
    "timeout", or "run-fail" (the binary did not exit 0)."""

    def __init__(self, status, text="", errors=(), lines=None):
        self.status, self.text, self.errors, self.lines = status, text, set(errors), lines or {}

    def to_json(self):
        return {"status": self.status, "errors": sorted(self.errors), "lines": self.lines, "text": self.text[-6000:]}


def test_ranges(src):
    """Maps each source line (1-based) to its test number."""
    owner = {}
    cur = None
    for i, line in enumerate(src.splitlines(), 1):
        m = re.match(r"// test (\d+)", line)
        if m:
            cur = int(m.group(1))
        m2 = re.search(r"// test (\d+)$", line)
        if m2 and not line.startswith("//"):
            owner[i] = int(m2.group(1))
            continue
        if cur is not None:
            owner[i] = cur
        if re.match(r"// end \d+", line):
            cur = None
    return owner


ERR_LINE = re.compile(r"^(\S+?):(\d+):\d+: error")
LOC = re.compile(r"(\S+?\.zig):(\d+):\d+")


def error_tests(text, fname, owner):
    """The tests the compile errors in `text` belong to: each error's
    first location in the program, else the first program location its
    notes and reference trace name. None when some error names none."""
    blocks = []
    for line in text.splitlines():
        if ERR_LINE.match(line):
            blocks.append([line])
        elif blocks:
            blocks[-1].append(line)
    ids = set()
    for b in blocks:
        tid = None
        for line in b:
            for m in LOC.finditer(line):
                if os.path.basename(m.group(1)) == fname and int(m.group(2)) in owner:
                    tid = owner[int(m.group(2))]
                    break
            if tid is not None:
                break
        if tid is None:
            return None
        ids.add(tid)
    return ids


def compile_run(tools, cfg, src, scratch):
    kind, env_extra = CONFIGS[cfg]
    out = os.path.join(scratch, cfg)
    if os.path.exists(out):
        os.unlink(out)
    env = dict(os.environ)
    env.update(env_extra)
    if kind == "bs":
        env["BS_CACHE"] = "off"
        argv = [tools.bs, "build-exe", src, f"-femit-bin={out}"]
    else:
        argv = [tools.zig, "build-exe", src, f"-femit-bin={out}", "--cache-dir", os.path.join(scratch, "zc")]
        if cfg == "zig-llvm":
            argv.append("-fllvm")
    argv += ["-target", tools.target]
    try:
        p = subprocess.run(
            argv,
            check=False,
            env=env,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=COMPILE_TIMEOUT,
            cwd=scratch,
        )
    except subprocess.TimeoutExpired:
        return Build("timeout")
    text = p.stdout + p.stderr
    if p.returncode != 0 or not os.path.exists(out):
        crash = (
            p.returncode < 0
            or "panic:" in text
            or "Segmentation fault" in text
            or "error" not in text
            or "unable to " in text
            and "bs bug" in text
        )
        if crash:
            return Build("crash", text)
        owner = test_ranges(open(src).read())
        ids = error_tests(text, os.path.basename(src), owner)
        if ids is None or not ids:
            return Build("error", text, errors={-1})
        return Build("error", text, errors=ids)
    try:
        r = subprocess.run(
            [*tools.runner, out],
            check=False,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=RUN_TIMEOUT,
            stdin=subprocess.DEVNULL,
        )
    except subprocess.TimeoutExpired:
        return Build("run-fail", "timeout")
    lines = {}
    for line in r.stderr.splitlines():
        m = re.match(r"t(\d+) (.*)$", line)
        if m:
            # A NaN's sign is not specified.
            # A NaN's sign is unspecified; a pointer prints its address.
            lines[int(m.group(1))] = re.sub(r"@[0-9a-f]+\b", "@addr", m.group(2).replace("-nan", "nan"))
    if r.returncode != 0:
        return Build("run-fail", r.stderr[-3000:], lines=lines)
    return Build("ok", lines=lines)


# What bs prints for an undefined value (memory filled with 0xaa), as an
# integer of each width, signed and unsigned, and as f32 and f64.
UNDEF = {
    str(v)
    for bits in (8, 16, 32, 64, 128)
    for v in (int("aa" * (bits // 8), 16), int("aa" * (bits // 8), 16) - (1 << bits))
} | {"-3.0316488e-13", "-3.7206620809969885e-103"}
TOKEN = re.compile(r"-?[0-9][0-9a-zA-Z.+-]*|[^0-9-]+|-")


def same_value(got, want):
    """Whether bs's line `got` means `want`: equal, or equal except where
    bs printed an undefined value and upstream printed something else
    (upstream's LLVM backend, which aarch64-linux uses, emits undefined
    memory as zeros, not 0xaa)."""
    if got == want or got is None or want is None:
        return got == want
    g, w = TOKEN.findall(got), TOKEN.findall(want)
    return len(g) == len(w) and all(a == b or a in UNDEF for a, b in zip(g, w))


def value_diff(got, want):
    """A name for how bs's line differs from upstream's, for the finding's
    signature: "sign" when each differing number is a negative one read
    without its sign extension, else ""."""
    g, w = TOKEN.findall(got or ""), TOKEN.findall(want or "")
    if len(g) != len(w):
        return ""
    seen = False
    for a, b in zip(g, w):
        if a == b or a in UNDEF:
            continue
        try:
            ia, ib = int(a), int(b)
        except ValueError:
            return ""
        if not (ib < 0 < ia and (ia - ib) & (ia - ib - 1) == 0):
            return ""
        seen = True
    return "sign" if seen else ""


def new_scratch():
    base = os.path.join(WORK, "tmp")
    os.makedirs(base, exist_ok=True)
    # bs lints a project's files by default; generated programs are
    # compiled with lint off (a .bs.zon over the work tree and in each
    # scratch directory, which is all bs searches outside a project).
    d = tempfile.mkdtemp(prefix="ct-", dir=base)
    for path in (WORK, d):
        with open(os.path.join(path, ".bs.zon"), "w") as f:
            f.write(".{ .lint = false }\n")
    return d


def first_error(text):
    for line in text.splitlines():
        if ERR_LINE.match(line):
            return re.sub(r"^\S+: error(\[[^\]]*\])?: ", "", line)[:90]
    return ""


def check(seed, tools, size=1.0, text=None, save_findings=True):
    """Runs one seed (or a saved program). Returns a record with its
    findings; saves each."""
    SAVE[0] = save_findings
    scratch = new_scratch()
    rec = {"seed": seed, "findings": []}
    try:
        only = None
        for attempt in range(3):
            src_text = text if text is not None else gen.generate(seed, size, only)
            src = os.path.join(scratch, f"p{seed}.zig")
            with open(src, "w") as f:
                f.write(src_text)
            all_ids = {int(x) for x in re.findall(r"^// test (\d+)", src_text, re.MULTILINE)}
            up = compile_run(tools, "zig", src, scratch)
            if up.status in ("crash", "timeout"):
                rec["result"] = "upstream-" + up.status
                return rec
            if up.status == "run-fail":
                rec["result"] = "upstream-run-fail"
                return rec
            if -1 in up.errors:
                rec["result"] = "discard"
                rec["why"] = first_error(up.text)
                return rec
            res = {c: compile_run(tools, c, src, scratch) for c in BS_CONFIGS}
            if attempt == 0:
                rec["tests"] = len(all_ids)
                rec["rejected"] = len(up.errors)
            # Rejections.
            for c, b in res.items():
                if b.status in ("crash", "timeout"):
                    rec["findings"].append(
                        save(
                            seed,
                            src_text,
                            tools,
                            up,
                            res,
                            f"bs-{b.status}",
                            None,
                            [c],
                            first_error(b.text) or b.text.strip().splitlines()[-1:][0][:90]
                            if b.text.strip()
                            else b.status,
                            size,
                            only,
                            text is not None,
                        )
                    )
                    break
            crashed = any(b.status in ("crash", "timeout") for b in res.values())
            if not crashed:
                for tid in sorted(all_ids):
                    bad_rej = [c for c, b in res.items() if tid in b.errors and tid not in up.errors]
                    bad_acc = [
                        c
                        for c, b in res.items()
                        if b.status in ("ok", "error", "run-fail") and tid in up.errors and tid not in b.errors
                    ]
                    if -1 in set().union(*(b.errors for b in res.values())):
                        break
                    if bad_rej:
                        b = res[bad_rej[0]]
                        rec["findings"].append(
                            save(
                                seed,
                                src_text,
                                tools,
                                up,
                                res,
                                "bs-reject",
                                tid,
                                bad_rej,
                                first_error_of(b.text, tid, src_text),
                                size,
                                only,
                                text is not None,
                            )
                        )
                    if bad_acc:
                        rec["findings"].append(
                            save(
                                seed,
                                src_text,
                                tools,
                                up,
                                res,
                                "bs-accept",
                                tid,
                                bad_acc,
                                first_error_of(up.text, tid, src_text),
                                size,
                                only,
                                text is not None,
                            )
                        )
            if not up.errors:
                break
            if text is not None:
                break
            only = (only if only is not None else all_ids) - up.errors
            if not only:
                rec["result"] = "all-rejected"
                return rec
        else:
            rec["result"] = "unsettled"
            return rec
        if up.status != "ok":
            # A saved program (--file, --recheck) is not narrowed to the
            # tests upstream accepts: only its rejections were compared.
            rec["result"] = ("rejections-match" if not rec["findings"] else "fail") if text is not None else "discard"
            rec["why"] = "upstream did not settle"
            return rec
        rec["accepted"] = len(up.lines)
        llvm = None
        for tid, want in sorted(up.lines.items()):
            bad = [
                c for c, b in res.items() if b.status in ("ok", "run-fail") and not same_value(b.lines.get(tid), want)
            ]
            if bad and tools.target == "x86_64-linux":
                if llvm is None:
                    llvm = compile_run(tools, "zig-llvm", src, scratch)
                if llvm.status == "ok" and all(same_value(res[c].lines.get(tid), llvm.lines.get(tid)) for c in bad):
                    rec["upstream_x86"] = rec.get("upstream_x86", 0) + 1
                    continue
            if bad:
                rec["findings"].append(
                    save(
                        seed,
                        src_text,
                        tools,
                        up,
                        res,
                        "wrong-value",
                        tid,
                        bad,
                        value_diff(res[bad[0]].lines.get(tid), want),
                        size,
                        only,
                        text is not None,
                    )
                )
        for c, b in res.items():
            if b.status == "run-fail":
                rec["findings"].append(
                    save(
                        seed,
                        src_text,
                        tools,
                        up,
                        res,
                        "bs-run-fail",
                        None,
                        [c],
                        b.text.strip().splitlines()[0][:90] if b.text.strip() else "",
                        size,
                        only,
                        text is not None,
                    )
                )
        rec["result"] = "findings" if rec["findings"] else "pass"
        return rec
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def first_error_of(text, tid, src_text):
    owner = test_ranges(src_text)
    for line in text.splitlines():
        m = ERR_LINE.match(line)
        if m and owner.get(int(m.group(2))) == tid:
            return re.sub(r"^\S+: error(\[[^\]]*\])?: ", "", line)[:90]
    return first_error(text)


def test_kind(src_text, tid):
    m = re.search(rf"^// test {tid} (\w+)", src_text, re.MULTILINE)
    return m.group(1) if m else "?"


def save(seed, src_text, tools, up, res, cls, tid, bad, msg, size, only, from_file):
    kind = test_kind(src_text, tid) if tid is not None else "-"
    # A finding on the default target keeps its old signature and name.
    leg = "" if tools.target == "x86_64-linux" else f"{tools.target}:"
    sig = f"{leg}{cls}|{kind}|{','.join(bad)}|{re.sub(r'[0-9]+', 'N', msg)}"
    if seed == 0 and from_file and not SAVE[0]:
        return {"dir": "", "sig": sig}
    name = leg.replace(":", "-") + f"{cls}-{seed}" + (f"-t{tid}" if tid is not None else "")
    d = os.path.join(FOUND, name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "orig.zig"), "w") as f:
        f.write(src_text)
    if tid is not None and not from_file:
        with open(os.path.join(d, "test.zig"), "w") as f:
            f.write(gen.generate(seed, size, {tid}))
    meta = {
        "seed": seed,
        "target": tools.target,
        "class": cls,
        "test": tid,
        "kind": kind,
        "bad": bad,
        "sig": sig,
        "bs": tools.bs,
        "time": time.strftime("%Y-%m-%d %H:%M:%S"),
        "outcomes": {"zig": up.to_json(), **{c: b.to_json() for c, b in res.items()}},
    }
    if tid is not None:
        meta["want"] = up.lines.get(tid)
        meta["got"] = {c: res[c].lines.get(tid) for c in bad}
    with open(os.path.join(d, "meta.json"), "w") as f:
        json.dump(meta, f, indent=1)
    return {"dir": d, "sig": sig}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 1))
    ap.add_argument("--bs", help="bs binary (default zig-out/bin/bs; build it with -Doptimize=ReleaseFast)")
    ap.add_argument("--zig", help="upstream zig 0.17.1 (default: zig on PATH)")
    ap.add_argument("--seed", type=int, help="first seed (default: random)")
    ap.add_argument("--count", type=int, help="stop after this many programs")
    ap.add_argument("--hours", type=float, help="stop after this long")
    ap.add_argument("--size", type=float, default=1.0, help="tests per program factor")
    ap.add_argument(
        "--target",
        action="append",
        choices=TARGETS,
        help="target to build for (repeatable, one leg each; default x86_64-linux)",
    )
    ap.add_argument("--one", type=int, help="check one seed and print its record")
    ap.add_argument("--file", help="check one saved program and print its record")
    ap.add_argument(
        "--recheck",
        action="store_true",
        help="check every saved finding's program again; list the ones that still fail",
    )
    args = ap.parse_args()
    tools = Tools(args.bs, args.zig)
    if not os.path.exists(tools.bs):
        sys.exit(f"no bs at {tools.bs}")
    legs = [tools.leg(t) for t in dict.fromkeys(args.target or ["x86_64-linux"])]
    if args.file:
        for leg in legs:
            print(json.dumps(check(0, leg, args.size, text=open(args.file).read()), indent=1))
        return
    if args.recheck:
        recheck(tools)
        return
    if args.one is not None:
        for leg in legs:
            print(json.dumps(check(args.one, leg, args.size), indent=1))
        return
    seed = args.seed if args.seed is not None else random.randrange(1 << 40)
    targets = ", ".join(leg.target for leg in legs)
    log(f"bs {tools.bs}, zig {tools.zig}, {targets}, {args.jobs} workers, first seed {seed}")
    start, t0 = seed, time.time()
    deadline = t0 + args.hours * 3600 if args.hours else None
    counts, sigs, why = {}, {}, {}
    tests = accepted = rejected = 0
    pool = cf.ProcessPoolExecutor(args.jobs)
    pending = set()
    last = time.time()
    try:
        while True:
            stop = (args.count is not None and seed - start >= args.count) or (deadline and time.time() > deadline)
            while not stop and len(pending) < args.jobs * 2:
                for leg in legs:
                    pending.add(pool.submit(check, seed, leg, args.size))
                seed += 1
            if not pending:
                break
            done, pending = cf.wait(pending, timeout=5, return_when=cf.FIRST_COMPLETED)
            for fut in done:
                try:
                    rec = fut.result()
                except Exception as e:  # noqa: BLE001 (keep hunting)
                    log(f"worker error: {e!r}")
                    continue
                counts[rec["result"]] = counts.get(rec["result"], 0) + 1
                tests += rec.get("tests", 0)
                rejected += rec.get("rejected", 0)
                accepted += rec.get("accepted", 0)
                if rec.get("upstream_x86"):
                    # Values only upstream's x86_64 backend got wrong.
                    counts["x86-backend-values"] = counts.get("x86-backend-values", 0) + rec["upstream_x86"]
                if rec["result"] == "discard":
                    why[rec.get("why", "")] = why.get(rec.get("why", ""), 0) + 1
                for f in rec["findings"]:
                    new = f["sig"] not in sigs
                    sigs[f["sig"]] = sigs.get(f["sig"], 0) + 1
                    if new:
                        log(f"seed {rec['seed']}: NEW {f['sig']} -> {os.path.relpath(f['dir'], REPO_DIR)}")
            if time.time() - last > 60:
                last = time.time()
                log(summary(seed - start - len(pending) // len(legs), t0, counts, tests, accepted, rejected, sigs, why))
    except KeyboardInterrupt:
        log("interrupted")
    finally:
        pool.shutdown(cancel_futures=True)
        log(summary(seed - start - len(pending) // len(legs), t0, counts, tests, accepted, rejected, sigs, why))
        for s, n in sorted(sigs.items(), key=lambda kv: -kv[1]):
            log(f"  {n:4d}  {s}")


def recheck(tools):
    """Runs each finding's smallest program (reduced.zig, test.zig or
    orig.zig) again and says whether it still fails."""
    if not os.path.isdir(FOUND):
        return
    for name in sorted(os.listdir(FOUND)):
        d = os.path.join(FOUND, name)
        prog = next(
            (os.path.join(d, f) for f in ("reduced.zig", "test.zig", "orig.zig") if os.path.exists(os.path.join(d, f))),
            None,
        )
        if prog is None:
            continue
        meta = os.path.join(d, "meta.json")
        target = json.load(open(meta)).get("target", "x86_64-linux") if os.path.exists(meta) else "x86_64-linux"
        rec = check(0, tools.leg(target), text=open(prog).read(), save_findings=False)
        sigs = sorted({f["sig"] for f in rec["findings"]})
        print(f"{name}: {'STILL ' + '; '.join(sigs) if sigs else 'fixed (' + rec['result'] + ')'}", flush=True)


def summary(n, t0, counts, tests, accepted, rejected, sigs, why):
    el = time.time() - t0
    c = " ".join(f"{k}={v}" for k, v in sorted(counts.items()))
    s = (
        f"{n} programs in {el / 60:.1f} min: {c}; tests {tests}, upstream rejected {rejected}, "
        f"compared values {accepted}; {len(sigs)} signatures"
    )
    if why:
        s += "\n  discards: " + "; ".join(f"{v}x {k}" for k, v in sorted(why.items(), key=lambda kv: -kv[1])[:4])
    return s


if __name__ == "__main__":
    main()
