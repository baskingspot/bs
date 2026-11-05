#!/usr/bin/env python3
"""Whole builds: each corpus project's `build` steps under `zig build` and
`bs build`, compared step by step.

Each build gets an empty local cache (`--cache-dir`) and its own install
prefix, both deleted afterwards, and runs with `--summary all`. A build
matches when the exit status, the step tree (each step's status and test
counts, without timings, MaxRSS or "cached") and the installed files
(their paths and executable bits, and the contents of everything that
is not an ELF file or an archive; tar files by member names and
contents) are the same.

    python3 tools/corpus/steps.py --bs zig-out/bin/bs
    python3 tools/corpus/steps.py --projects zls,zio --bs-only

Results go to .work/steps.json and .work/steps.md (`--results NAME`).
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time

import run

# Recording anyzig's test step downloads several Zig releases (README).
SKIP = {"anyzig"}
TIMING = re.compile(r" (?:\d+(?:\.\d+)?(?:ns|us|ms|s|m) ?)+(?=MaxRSS| |$)")
MAXRSS = re.compile(r" MaxRSS:\S+")


def summary(output):
    """The step tree after "Build Summary", normalized for comparison."""
    lines = output.splitlines()
    start = next((i for i, line in enumerate(lines) if line.startswith("Build Summary:")), None)
    if start is None:
        return []
    tree = []
    for line in lines[start:]:
        if not line.strip():
            break
        line = MAXRSS.sub("", line)
        line = TIMING.sub("", line)
        line = line.replace(" cached", " success")
        tree.append(line.rstrip())
    return tree


def installed(prefix):
    """Installed files: path -> content hash, or the kind of a build product."""
    files = {}
    for root, _, names in os.walk(prefix):
        for name in names:
            path = os.path.join(root, name)
            rel = os.path.relpath(path, prefix)
            if os.path.islink(path):
                files[rel] = "link " + os.readlink(path)
                continue
            mode = "x " if os.access(path, os.X_OK) else ""
            with open(path, "rb") as f:
                head = f.read(8)
            if head.startswith((b"\x7fELF", b"!<arch>")):
                files[rel] = mode + "binary"
            elif name.endswith(".tar"):
                # By member names and contents: the headers hold the
                # mtimes of generated files (`-femit-docs`' sources.tar).
                h = hashlib.sha256()
                with tarfile.open(path) as t:
                    for m in t:
                        h.update(m.name.encode() + b"\0")
                        if m.isfile():
                            h.update(t.extractfile(m).read())
                files[rel] = mode + "tar " + h.hexdigest()[:16]
            else:
                with open(path, "rb") as f:
                    files[rel] = mode + hashlib.sha256(f.read()).hexdigest()[:16]
    return files


def build(compiler, src, args, timeout):
    work = os.path.join(run.WORK, "steps-tmp")
    cache, prefix = os.path.join(work, "cache"), os.path.join(work, "prefix")
    shutil.rmtree(work, ignore_errors=True)
    argv = [compiler, "build", *args, "--summary", "all", "--cache-dir", cache, "--prefix", prefix]
    t0 = time.perf_counter()
    try:
        p = subprocess.run(
            argv, check=False, cwd=src, capture_output=True, text=True, errors="replace", timeout=timeout
        )
        code, out = p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired as e:
        code, out = "timeout", (e.stdout or b"").decode(errors="replace") + (e.stderr or b"").decode(errors="replace")
    secs = time.perf_counter() - t0
    res = {
        "exit": code,
        "seconds": round(secs, 2),
        "summary": summary(out),
        "installed": installed(prefix),
        "tail": out[-4000:],
    }
    shutil.rmtree(work, ignore_errors=True)
    return res


def compare(zig, bs, compilers):
    """`compilers`: both compilers' paths, which steps may name (a step
    that runs `b.graph.zig_exe`)."""
    if zig is None:
        return "no upstream result"
    diffs = []
    if zig["exit"] != bs["exit"]:
        diffs.append(f"exit {bs['exit']} vs {zig['exit']}")

    def tree(r):
        lines = r["summary"]
        for c in compilers:
            lines = [line.replace(c, "<zig>") for line in lines]
        return lines

    if tree(zig) != tree(bs):
        diffs.append("step tree")
    zi, bi = zig["installed"], bs["installed"]
    if zi.keys() != bi.keys():
        diffs.append(f"installed files ({len(bi.keys() - zi.keys())} extra, {len(zi.keys() - bi.keys())} missing)")
    else:
        changed = sorted(k for k in zi if zi[k] != bi[k])
        if changed:
            diffs.append("installed contents: " + ", ".join(changed[:5]))
    return "same" if not diffs else "differs: " + "; ".join(diffs)


def write_md(results, path):
    rows = ["| Project | Steps | Result | `zig build` | `bs build` |", "| --- | --- | --- | --- | --- |"]
    same = 0
    for r in results:
        z, b = r.get("zig") or {}, r["bs"]
        same += r["verdict"] == "same"
        rows.append(
            f"| {r['project']} | {' '.join(r['args'])} | {r['verdict']} "
            f"| exit {z.get('exit', '–')}, {z.get('seconds', '–')} s | exit {b['exit']}, {b['seconds']} s |"
        )
    with open(path, "w") as f:
        f.write(f"`bs build` matches `zig build` on {same} of {len(results)} step lists.\n\n" + "\n".join(rows) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--projects", help="comma-separated project names (default: all)")
    ap.add_argument("--bs", default=os.path.join(run.REPO_DIR, "zig-out", "bin", "bs"))
    ap.add_argument("--zig", default="zig")
    ap.add_argument("--bs-only", action="store_true", help="skip the upstream builds (reuse their last results)")
    ap.add_argument("--timeout", type=int, default=3600, help="seconds per build (default 3600)")
    ap.add_argument("--results", default="steps", help="name of the results files in .work (default: steps)")
    args = ap.parse_args()

    with open(os.path.join(run.CORPUS_DIR, "manifest.json")) as f:
        manifest = json.load(f)
    names = args.projects.split(",") if args.projects else None
    projects = [
        p for p in manifest["projects"] if "copy" not in p and (p["name"] in names if names else p["name"] not in SKIP)
    ]
    path = os.path.join(run.WORK, args.results + ".json")
    old = {}
    if os.path.exists(path):
        with open(path) as f:
            old = {(r["project"], tuple(r["args"])): r for r in json.load(f)}
    bs = os.path.abspath(args.bs)
    compilers = [bs, os.path.realpath(shutil.which(args.zig) or args.zig)]
    for proj in projects:
        run.log(f"{proj['name']} {proj['commit'][:12]}")
        src = run.checkout(proj, args.zig)
        for steps in proj.get("build", [["install"]]):
            key = (proj["name"], tuple(steps))
            prev = old.get(key, {})
            res = {"project": proj["name"], "args": steps}
            res["zig"] = prev.get("zig") if args.bs_only else build(args.zig, src, steps, args.timeout)
            res["bs"] = build(bs, src, steps, args.timeout)
            res["verdict"] = compare(res["zig"], res["bs"], compilers)
            run.log(f"  {' '.join(steps)} => {res['verdict']}")
            old[key] = res
            order = {p["name"]: i for i, p in enumerate(manifest["projects"])}
            results = sorted(old.values(), key=lambda r: (order.get(r["project"], 1 << 30), r["args"]))
            with open(path, "w") as f:
                json.dump(results, f, indent=1)
            write_md(results, os.path.join(run.WORK, args.results + ".md"))


if __name__ == "__main__":
    sys.exit(main())
