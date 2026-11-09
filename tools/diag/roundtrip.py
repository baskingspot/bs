#!/usr/bin/env python3
"""Checks that bs's fixes fix what they claim to.

For each Zig file, applies the fixes bs reports (`--error-format=json`)
to a copy, round after round until none are left, and checks each round
by bs's account and by upstream zig's: no error may remain or appear at
an edited place, and no syntax error anywhere. Other new errors are the
ones the fixed errors hid (AstGen errors stop Sema). The design's "fixes
round-trip" test ("Diagnostics" in docs/slop/architecture.md):

    python3 tools/diag/roundtrip.py test/diag/*.zig
    python3 tools/diag/roundtrip.py --all test/diag/*.zig  # `maybe` and placeholders too

Exits 1 when a fix leaves its error, adds an error, or does not apply.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def bs_errors(bs, path):
    """bs's diagnostics for `path` (run from its directory), as dicts."""
    out = subprocess.run(
        [bs, "build-exe", "-target", "x86_64-linux", "-fno-emit-bin", "--error-format=json", os.path.basename(path)],
        cwd=os.path.dirname(path),
        capture_output=True,
        text=True,
        env=dict(os.environ, BS_CACHE="off"),
        check=False,
    )
    diags = []
    for line in out.stdout.splitlines() + out.stderr.splitlines():
        if not line.startswith("{"):
            continue
        d = json.loads(line)
        if "summary" not in d:
            diags.append(d)
    return diags


def upstream_errors(zig, path):
    """Upstream's errors for `path` as (byte offset, message)."""
    out = subprocess.run(
        [zig, "build-exe", "-fno-emit-bin", os.path.basename(path)],
        cwd=os.path.dirname(path),
        capture_output=True,
        text=True,
        check=False,
    )
    with open(path, "rb") as f:
        lines = f.read().split(b"\n")
    errs = []
    for line in out.stderr.splitlines():
        head, sep, msg = line.partition(": error: ")
        if not sep:
            continue
        _, ln, col = head.rsplit(":", 2)
        errs.append((sum(len(l) + 1 for l in lines[: int(ln) - 1]) + int(col) - 1, msg))
    return errs


def apply(path, fixes):
    """Applies `fixes` to `path`, skipping ones that overlap an earlier one.
    Returns the fixes applied and the edited ranges of the new text."""
    with open(path, "rb") as f:
        src = f.read()
    taken, applied = [], []
    for fix in fixes:
        spans = [e["span"] for e in fix["edits"]]
        if any(s <= te and ts <= e for s, e in spans for ts, te in taken):
            continue
        taken += spans
        applied.append(fix)
    edits = sorted((e for fix in applied for e in fix["edits"]), key=lambda e: e["span"][0])
    out, pos, ranges = b"", 0, []
    for e in edits:
        s, t = e["span"]
        text = e["text"].encode()
        out += src[pos:s]
        ranges.append((len(out), len(out) + len(text)))
        out += text
        pos = t
    out += src[pos:]
    with open(path, "wb") as f:
        f.write(out)
    return applied, ranges


def at_edit(offset, ranges):
    return any(s <= offset <= e for s, e in ranges)


def check(bs, zig, case, kinds):
    tmp = tempfile.mkdtemp(prefix="bs-roundtrip-")
    try:
        path = os.path.join(tmp, os.path.basename(case))
        shutil.copy(case, path)
        problems = []
        n_applied = 0
        before = bs_errors(bs, path)
        for _ in range(20):
            fixes = [f for d in before for f in d.get("fixes", []) if f["applicability"] in kinds]
            if not fixes:
                break
            applied, ranges = apply(path, fixes)
            n_applied += len(applied)
            fixed = sorted(d["msg"] for d in before if any(f in applied for f in d.get("fixes", [])))
            for d in bs_errors(bs, path):
                if d.get("code") == "syntax" or ("span" in d and at_edit(d["span"][0], ranges)):
                    problems.append(f"after fixing {fixed}, bs: {d.get('line')}:{d.get('col')}: {d['msg']}")
            for offset, msg in upstream_errors(zig, path):
                if at_edit(offset, ranges) or (msg.startswith("expected ") and not msg.startswith("expected type ")):
                    problems.append(f"after fixing {fixed}, upstream: {msg}")
            if problems:
                break
            before = bs_errors(bs, path)
        return n_applied, problems, open(path).read() if problems else None
    finally:
        shutil.rmtree(tmp)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--bs", default=os.path.join(REPO, "zig-out/bin/bs"))
    p.add_argument("--zig", default="zig")
    p.add_argument("--all", action="store_true", help="also apply `maybe` and placeholder fixes")
    p.add_argument("files", nargs="+")
    args = p.parse_args()
    kinds = {"exact", "maybe", "placeholder"} if args.all else {"exact"}
    failed = 0
    total = 0
    for case in args.files:
        n, problems, src = check(os.path.abspath(args.bs), args.zig, os.path.abspath(case), kinds)
        total += n
        if problems:
            failed += 1
            print(f"FAIL {case}:")
            for pr in problems:
                print(f"  {pr}")
            print("  result:\n    " + src.replace("\n", "\n    "))
        elif n:
            print(f"ok   {case}: {n} fixes")
    print(f"{total} fixes applied; {failed} files failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
