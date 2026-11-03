#!/usr/bin/env python3
"""Real-world corpus: build pinned Zig projects with zap and upstream zig.

For each project in manifest.json this clones the pinned commit, runs
upstream `zig build --verbose` once to fetch dependencies, run code
generators, and record each compile step's command line, then builds the
manifest's targets from those command lines with upstream zig (Debug,
self-hosted x86_64 backend) and with zap, runs the results, and compares
them. Results go to .work/results.json and a Markdown scoreboard. See
tools/corpus/README.md.
"""

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time

CORPUS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(os.path.dirname(CORPUS_DIR))
WORK = os.path.join(CORPUS_DIR, ".work")

# Appended to the edit line: keeps the line count, and differs per edit.
EDIT_SUFFIX = " std.mem.doNotOptimizeAway(@as(u32, {n}));"

# Flags of upstream's command lines that zap does not take and that do not
# change what a pure-Zig x86_64-linux Debug build means: dropped silently.
ZAP_DROP = {"-fno-sanitize-c", "-fllvm", "-fno-llvm", "-fno-lld", "-fno-strip", "-fno-omit-frame-pointer",
            "-funwind-tables", "-fno-sanitize-thread", "-freference-trace", "-fno-single-threaded"}
ZAP_DROP_ARG = {"--listen=-": 0, "--build-root": 1, "--zig-lib-dir": 1}
# Flags zap does not implement yet that change semantics (builtin values):
# dropped, and recorded as a difference.
ZAP_DROP_NOTE = {"-fsingle-threaded", "-fPIC", "-fPIE"}


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def sh(argv, cwd, env=None, timeout=None, check=True):
    p = subprocess.run(argv, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                       errors="replace", timeout=timeout)
    if check and p.returncode != 0:
        sys.exit(f"{shlex.join(argv)} failed in {cwd}:\n{p.stdout}\n{p.stderr}")
    return p


def setup(proj, zig, refresh):
    """Clone, fetch, generate; return the recorded commands by target name."""
    src = os.path.join(WORK, "src", proj["name"])
    if not os.path.isdir(os.path.join(src, ".git")):
        os.makedirs(os.path.dirname(src), exist_ok=True)
        sh(["git", "clone", "--quiet", "--filter=blob:none", proj["url"], src], WORK)
    if sh(["git", "rev-parse", "HEAD"], src).stdout.strip() != proj["commit"]:
        sh(["git", "fetch", "--quiet", "origin", proj["commit"]], src, check=False)
        sh(["git", "checkout", "--quiet", "--force", "--detach", proj["commit"]], src)
    # Data packages a target's run needs (`fetch`), unpacked under .work/fetch/.
    proj["fetched"] = {}
    for name, url in proj.get("fetch", {}).items():
        h = sh([zig, "fetch", url], WORK).stdout.strip()
        dest = os.path.join(WORK, "fetch", h)
        if not os.path.isdir(dest):
            # The global cache keeps a package as `<hash>.tar.gz` holding `<hash>/`.
            tarball = os.path.join(os.path.expanduser("~/.cache/zig/p"), h + ".tar.gz")
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            sh(["tar", "xzf", tarball, "-C", os.path.dirname(dest)], WORK)
        proj["fetched"][name] = dest
    cmds_path = os.path.join(WORK, "commands", proj["name"] + ".json")
    if os.path.exists(cmds_path) and not refresh:
        with open(cmds_path) as f:
            return src, json.load(f)
    # A fresh generation cache, so every compile step runs and prints its
    # command. Generated sources stay in it; the recorded commands use them.
    gen = os.path.join(WORK, "gen", proj["name"])
    shutil.rmtree(gen, ignore_errors=True)
    cmds = {}
    for args in proj.get("build", [["install"]]):
        argv = [zig, "build", *args, "--verbose", "--cache-dir", gen]
        log(f"  {shlex.join(argv)}")
        p = sh(argv, src, check=False, timeout=3600)
        for line in p.stderr.splitlines():
            if not line.startswith("info(verbose): "):
                continue
            words = shlex.split(line[len("info(verbose): "):])
            if len(words) < 2 or words[1] not in ("build-exe", "test", "build-obj", "build-lib"):
                continue
            if "--name" not in words:
                continue
            name = words[words.index("--name") + 1]
            cmds.setdefault(name, words)
        if p.returncode != 0:
            log(f"  zig build {' '.join(args)} failed (exit {p.returncode}); recorded what ran:\n{p.stderr[-3000:]}")
    os.makedirs(os.path.dirname(cmds_path), exist_ok=True)
    with open(cmds_path, "w") as f:
        json.dump(cmds, f, indent=1)
    return src, cmds


def strip_common(words, cache_dir, out):
    """Drop the build-system plumbing both compilers get rid of."""
    res = []
    i = 2
    while i < len(words):
        w = words[i]
        if w in ("--listen=-", "-femit-docs"):
            pass
        elif w.startswith("-O"):
            # Every build is Debug: the baseline is upstream Debug, and
            # zap has no other mode. (Some build scripts force a release
            # mode on their build-time tools.)
            res.append("-Odebug")
        elif w in ("--cache-dir", "--global-cache-dir"):
            i += 1
        else:
            res.append(w)
        i += 1
    res += ["--cache-dir", cache_dir, f"-femit-bin={out}"]
    if words[1] == "test":
        res.append("--test-no-exec")
    return res


def upstream_argv(zig, words, cache_dir, out):
    rest = strip_common(words, cache_dir, out)
    # The baseline is upstream's Debug default on x86_64-linux: the
    # self-hosted backend, even where the build script asks for LLVM.
    rest = ["-fno-llvm" if w == "-fllvm" else w for w in rest]
    return [zig, words[1], *rest]


def zap_argv(zap, words, cache_dir, out):
    rest = strip_common(words, cache_dir, out)
    res, notes = [], []
    i = 0
    while i < len(rest):
        w = rest[i]
        if w in ZAP_DROP:
            pass
        elif w in ZAP_DROP_ARG:
            i += ZAP_DROP_ARG[w]
        elif w in ZAP_DROP_NOTE:
            notes.append(w)
        else:
            res.append(w)
        i += 1
    return [zap, words[1], *res], sorted(set(notes))


def timed(argv, cwd, env=None, timeout=1800):
    t = time.monotonic()
    try:
        p = subprocess.run(argv, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                           errors="replace", timeout=timeout)
        return time.monotonic() - t, p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return time.monotonic() - t, None, "timeout"


def first_error(output):
    lines = [ln for ln in output.splitlines() if "error" in ln]
    return (lines[0] if lines else output.strip().splitlines()[-1] if output.strip() else "")[:300]


TEST_SUMMARY = re.compile(r"^(All \d+ tests passed\.|\d+ passed; \d+ skipped; \d+ failed\.)", re.M)


def run_binary(path, args, cwd, timeout):
    try:
        p = subprocess.run([path, *args], cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        return {"exit": "timeout", "stdout": (e.stdout or b"").decode(errors="replace"),
                "stderr": (e.stderr or b"").decode(errors="replace")}
    code = p.returncode if p.returncode >= 0 else f"signal {-p.returncode}"
    return {"exit": code, "stdout": p.stdout.decode(errors="replace"), "stderr": p.stderr.decode(errors="replace")}


def summarize_run(r, is_test):
    if is_test:
        m = TEST_SUMMARY.search(r["stderr"])
        return f"exit {r['exit']}, {m.group(1) if m else 'no summary'}"
    return f"exit {r['exit']}"


def apply_edit(path, line, n):
    with open(path) as f:
        text = f.read()
    at = text.find(line)
    if at < 0 or text.find(line, at + 1) >= 0:
        sys.exit(f"edit line not found exactly once in {path}: {line!r}")
    with open(path, "w") as f:
        f.write(text[:at + len(line)] + EDIT_SUFFIX.format(n=n) + text[at + len(line):])
    return text


def build_target(proj, src, words, tgt, compilers, args):
    name = tgt["name"]
    is_test = words[1] == "test"
    out_dir = os.path.join(WORK, "out", proj["name"])
    os.makedirs(out_dir, exist_ok=True)
    result = {"project": proj["name"], "target": name, "kind": words[1]}
    edit = tgt.get("edit")
    for which, comp in compilers:
        out = os.path.join(out_dir, f"{name}.{which}")
        cache = os.path.join(WORK, "cache", proj["name"], f"{name}.{which}")
        shutil.rmtree(cache, ignore_errors=True)
        if os.path.exists(out):
            os.remove(out)
        if which == "zig":
            argv, notes = upstream_argv(comp, words, cache, out), []
        else:
            argv, notes = zap_argv(comp, words, cache, out)
        r = {"argv": shlex.join(argv), "notes": notes}
        log(f"  {which}: {name}")
        secs, code, output = timed(argv, src)
        r["cold_local"] = secs
        r["compile_exit"] = code
        if code != 0:
            r["error"] = first_error(output)
            r["output"] = output[-20000:]
            result[which] = r
            continue
        # Tests run without arguments; an executable runs only with the
        # manifest's "run" arguments.
        run_args = tgt.get("run", [] if is_test else None)
        if run_args is not None:
            run_args = [a.format(**proj["fetched"]) for a in run_args]
        if args.no_run and run_args is not None:
            r["run"] = "skipped"
            run = {"exit": None, "stdout": "", "stderr": ""}
        elif run_args is None:
            r["run"] = "not run"
            run = {"exit": None, "stdout": "", "stderr": ""}
        else:
            # Both binaries run from the same path: programs print argv[0].
            run_path = os.path.join(out_dir, "run", name)
            os.makedirs(os.path.dirname(run_path), exist_ok=True)
            shutil.copy(out, run_path)
            run = run_binary(run_path, run_args, os.path.join(src, tgt.get("cwd", ".")), tgt.get("timeout", 600))
            r["run"] = summarize_run(run, is_test)
        r["run_exit"] = run["exit"]
        r["stdout_sha"] = hashlib.sha256(run["stdout"].encode()).hexdigest()
        r["stdout"] = run["stdout"][-2000:]
        r["stderr"] = run["stderr"][-4000:]
        if edit and not args.no_edit:
            path = os.path.join(src, edit[0])
            orig = apply_edit(path, edit[1], int(time.time()) % 100000)
            env = None
            if which == "zap" and args.cache_check:
                # Check the edit build against a full build (not timed).
                env = dict(os.environ, ZAP_CACHE_VERIFY="1", ZAP_CACHE_CHECK="1")
            try:
                secs, code, output = timed(argv, src, env)
            finally:
                with open(path, "w") as f:
                    f.write(orig)
            r["edit"] = secs if code == 0 else None
            if code != 0:
                r["edit_error"] = first_error(output)
                r["edit_output"] = output[-20000:]
        result[which] = r
    return result


def compare(res, tgt):
    """One verdict: ok, or what differs between zap and upstream."""
    z, u = res.get("zap"), res.get("zig")
    if u is None or z is None:
        return "not built"
    if u["compile_exit"] != 0:
        return "upstream fails to compile"
    if z["compile_exit"] != 0:
        return "zap: compile error" if z["compile_exit"] == 1 else f"zap: crash ({z['compile_exit']})"
    if z["run"] == "skipped":
        return f"zap: edit build failed: {z['edit_error']}" if z.get("edit_error") else "compiles (not run)"
    if z["run"] != u["run"]:
        return f"zap: run differs ({z['run']} vs {u['run']})"
    if tgt.get("compare_stdout", True) and z["stdout_sha"] != u["stdout_sha"]:
        return "zap: stdout differs"
    if z.get("edit_error"):
        return f"zap: edit build failed: {z['edit_error']}"
    return "ok"


def fmt_s(s):
    return "–" if s is None else (f"{s:.2f} s" if s >= 1 else f"{s * 1000:.0f} ms")


def write_scoreboard(results, manifest, path):
    """One row per target: the verdict, both runs, and both build times."""
    lines = ["| Project | Target | Verdict | upstream run | zap run | cold-local zig / zap | edit zig / zap |",
             "|---|---|---|---|---|---:|---:|"]
    for res in results:
        u, z = res.get("zig") or {}, res.get("zap") or {}

        def cell(r):
            return (r.get("run") or r.get("error") or "–").replace("|", "\\|")[:90]

        def ratio(a, b):
            return f" ({a / b:.1f}x)" if a and b else ""
        lines.append("| {} | {} | {} | {} | {} | {} / {}{} | {} / {}{} |".format(
            res["project"], res["target"], res["verdict"].replace("|", "\\|"), cell(u), cell(z),
            fmt_s(u.get("cold_local")), fmt_s(z.get("cold_local")), ratio(u.get("cold_local"), z.get("cold_local")),
            fmt_s(u.get("edit")), fmt_s(z.get("edit")), ratio(u.get("edit"), z.get("edit"))))
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--projects", help="comma-separated project names (default: all)")
    ap.add_argument("--targets", help="comma-separated target names (default: all)")
    ap.add_argument("--zap", default=os.path.join(REPO_DIR, "zig-out", "bin", "zap"))
    ap.add_argument("--zig", default="zig")
    ap.add_argument("--refresh", action="store_true", help="rerun zig build --verbose to re-record commands")
    ap.add_argument("--list", action="store_true", help="only record and list each project's compile commands")
    ap.add_argument("--zap-only", action="store_true", help="skip the upstream builds (reuse their last results)")
    ap.add_argument("--no-edit", action="store_true", help="skip the edit builds")
    ap.add_argument("--no-run", action="store_true", help="build only; do not run what was built")
    ap.add_argument("--cache-check", action="store_true",
                    help="zap's edit builds check themselves against full builds (ZAP_CACHE_VERIFY, ZAP_CACHE_CHECK)")
    args = ap.parse_args()

    with open(os.path.join(CORPUS_DIR, "manifest.json")) as f:
        manifest = json.load(f)
    projects = [p for p in manifest["projects"] if not args.projects or p["name"] in args.projects.split(",")]
    results_path = os.path.join(WORK, "results.json")
    old = {}
    if os.path.exists(results_path):
        with open(results_path) as f:
            old = {(r["project"], r["target"]): r for r in json.load(f)}
    os.makedirs(WORK, exist_ok=True)
    compilers = [("zap", os.path.abspath(args.zap))] + ([] if args.zap_only else [("zig", args.zig)])
    for proj in projects:
        log(f"{proj['name']} {proj['commit'][:12]}")
        src, cmds = setup(proj, args.zig, args.refresh)
        if args.list:
            for name, words in cmds.items():
                print(f"{proj['name']}: {words[1]} --name {name}")
            continue
        for tgt in proj["targets"]:
            if args.targets and tgt["name"] not in args.targets.split(","):
                continue
            words = cmds.get(tgt["name"])
            if words is None:
                log(f"  no recorded command for {tgt['name']}; rerun with --refresh")
                continue
            res = build_target(proj, src, words, tgt, compilers, args)
            if args.zap_only and (proj["name"], tgt["name"]) in old:
                res["zig"] = old[(proj["name"], tgt["name"])].get("zig")
            res["verdict"] = compare(res, tgt)
            log(f"  => {res['verdict']}")
            old[(proj["name"], tgt["name"])] = res
    if args.list:
        return
    order = [(p["name"], t["name"]) for p in manifest["projects"] for t in p["targets"]]
    results = [old[k] for k in order if k in old]
    with open(results_path, "w") as f:
        json.dump(results, f, indent=1)
    write_scoreboard(results, manifest, os.path.join(WORK, "scoreboard.md"))
    print(open(os.path.join(WORK, "scoreboard.md")).read())


if __name__ == "__main__":
    main()
