#!/usr/bin/env python3
"""Finds the bs commit that introduced a finding (tools/mchunt).

    python3 tools/mchunt/bisect_bs.py tools/mchunt/.work/found/miscompile-1234
    python3 tools/mchunt/bisect_bs.py repro.zig --bad-config bs --good HEAD~50

Builds bs (Debug, which takes seconds instead of minutes) at each step
in a worktree under .work/bisect-tree and runs the finding's program
(reduced.zig when there is one) under the failing configuration. A
commit is bad when bs still disagrees with upstream, good when bs
compiles the program and agrees, and skipped otherwise (bs does not
build, or rejects the program for another reason). Without --good, it
searches back from --bad (default origin/main) for a good commit.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness as H  # noqa: E402

TREE = os.path.join(H.WORK, "bisect-tree")


def git(*args, cwd=TREE, check=True):
    return subprocess.run(["git", *args], cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                          check=check).stdout.strip()


def build(sha):
    dest = os.path.join(H.WORK, "bsdbg", sha)
    binp = os.path.join(dest, "bin", "bs")
    if os.path.exists(binp):
        return binp
    git("checkout", "--quiet", "--detach", sha)
    up = os.path.join(H.REPO_DIR, "upstream")
    if os.path.exists(up) and not os.path.exists(os.path.join(TREE, "upstream")):
        os.symlink(os.path.realpath(up), os.path.join(TREE, "upstream"))
    p = subprocess.run(["zig", "build", "--prefix", dest], cwd=TREE, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True)
    return binp if p.returncode == 0 and os.path.exists(binp) else None


def verdict(sha, src, cfg, up):
    """'bad', 'good' or 'skip' for bs at `sha`."""
    bs = build(sha)
    if bs is None:
        return "skip", "bs does not build"
    tools = H.Tools(bs)
    scratch = H.new_scratch("bisect-")
    try:
        o = H.run_config(tools, cfg, src, scratch)
        if H.ORACLE.kind == "bs":
            # The reference is the same bs with a pass off.
            up = H.run_config(tools, H.ORACLE, src, scratch)
            if not up.compiled():
                return "skip", "reference does not compile"
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    if o.key() == up.key():
        return "good", "agrees with upstream"
    if not o.compiled() and up.compiled():
        return ("bad", o.status) if o.status == "compile-crash" else ("skip", "rejects: " + o.detail.splitlines()[0][:100] if o.detail else o.status)
    return "bad", " / ".join(o.lines[-2:]) or o.status


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target", help="finding directory or .zig file")
    ap.add_argument("--bad-config", default=None, help="failing configuration (default: from the finding, else bs)")
    ap.add_argument("--bad", default="origin/main")
    ap.add_argument("--good")
    args = ap.parse_args()

    if os.path.isdir(args.target):
        meta = json.load(open(os.path.join(args.target, "meta.json")))
        prog = os.path.join(args.target, "reduced.zig")
        if not os.path.exists(prog):
            prog = os.path.join(args.target, "orig.zig")
        cfgname = args.bad_config or ("bs" if "bs" in meta["bad"] else meta["bad"][0])
        if meta.get("ref_env"):
            H.set_ref_env(meta["ref_env"])
    else:
        meta, prog, cfgname = None, args.target, args.bad_config or "bs"
    cfg = H.BY_NAME[cfgname]
    if not os.path.isdir(TREE):
        git("worktree", "add", "--detach", TREE, "origin/main", cwd=H.REPO_DIR)
    git("fetch", "--quiet", "origin", cwd=H.REPO_DIR, check=False)
    src_dir = H.new_scratch("bisect-src-")
    src = os.path.join(src_dir, "repro.zig")
    shutil.copy(prog, src)
    up = H.run_config(H.Tools(), H.UP_DEBUG, src, src_dir) if H.ORACLE.kind == "zig" else None
    if up is None:
        up = H.Outcome("ok", [], 0, "")  # replaced per commit by the reference
    print(f"upstream: {up.text()}" if H.ORACLE.kind == "zig" else f"reference: bs with {H.ORACLE.env}", flush=True)

    bad = git("rev-parse", args.bad, cwd=H.REPO_DIR)
    v, why = verdict(bad, src, cfg, up)
    print(f"{bad[:10]} {v}: {why}", flush=True)
    if v != "bad":
        sys.exit("the bad end does not show the bug")
    if args.good:
        good = git("rev-parse", args.good, cwd=H.REPO_DIR)
        v, why = verdict(good, src, cfg, up)
        print(f"{good[:10]} {v}: {why}", flush=True)
        if v != "good":
            sys.exit("the good end does not pass")
    else:
        good = None
        step = 8
        while good is None:
            cand = git("rev-parse", f"{bad}~{step}", cwd=H.REPO_DIR, check=False)
            if not cand or "fatal" in cand:
                sys.exit("no good commit found")
            v, why = verdict(cand, src, cfg, up)
            print(f"{cand[:10]} (~{step}) {v}: {why}", flush=True)
            if v == "good":
                good = cand
            else:
                if v == "bad":
                    bad = cand
                step *= 2
    # Bisect over first-parent history between good and bad.
    revs = git("rev-list", "--first-parent", "--reverse", f"{good}..{bad}", cwd=H.REPO_DIR).split()
    lo, hi = -1, len(revs) - 1  # revs[lo] good (or `good`), revs[hi] bad
    skipped = set()
    while hi - lo > 1:
        mid = (lo + hi) // 2
        # Step around skipped commits.
        probe = mid
        while probe in skipped and probe < hi - 1:
            probe += 1
        if probe in skipped:
            break
        v, why = verdict(revs[probe], src, cfg, up)
        print(f"{revs[probe][:10]} {v}: {why}", flush=True)
        if v == "bad":
            hi = probe
        elif v == "good":
            lo = probe
        else:
            skipped.add(probe)
    first = revs[hi]
    print(f"\nfirst bad commit: {git('log', '-1', '--format=%h %s', first, cwd=H.REPO_DIR)}")
    if lo + 1 < hi:
        print(f"(somewhere in {hi - lo} commits; skipped {len(skipped)})")
    shutil.rmtree(src_dir, ignore_errors=True)
    if meta is not None:
        meta["first_bad"] = first
        json.dump(meta, open(os.path.join(args.target, "meta.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
