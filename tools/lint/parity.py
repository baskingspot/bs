#!/usr/bin/env python3
"""Compares bs's ziglint findings on a tree with ziglint 0.8.1's.

Runs ziglint in the tree (it reads the tree's .ziglint.zon), runs bs on the
tree's build (`bs build` by default), matches the findings by rule, file
and line, and classifies every difference (docs/slop/ziglint-in-bs.md,
"The conformance measure"):

  sema-type     a finding of a Sema rule (Z010, Z011, Z029, Z034) only bs
                has: Sema types what ziglint's resolver cannot (locals,
                parameters, pointers, aliases)
  unanalyzed    a finding of a Sema rule only ziglint has, in a file bs
                reached: in code Sema did not analyze (nothing references
                it), or where Sema's types say the form is needed (Z010's
                `Other.decl` returned as a `T`)
  language      Z027: in code that compiles, ziglint's findings are
                methods whose receiver it does not recognize
  hybrid        a rule ziglint answers with its type resolver, which bs
                answers from the syntax for now (Z006, Z012, Z015, Z023,
                Z032, Z033)
  unreached     a file bs reported nothing in: no compilation reached it,
                or every finding in it is of the classes above
  bug           anything else, to be fixed

sema-type and unanalyzed are told apart by side alone; spot-check them
with --list.

Findings in build.zig fail the build's configure step, which hides every
other step's, so when bs reports any there, it runs again with build.zig
left out of the config's paths (the tree's .ziglint.zon is restored), and
takes build.zig's findings from the first run.

Exits 1 if there is a `bug` difference.

    python3 tools/lint/parity.py --bs zig-out/bin/bs --ziglint ziglint [--tree DIR] [-- build args]
"""

import argparse
import collections
import os
import re
import subprocess
import sys

SEMA = {"Z010", "Z011", "Z029", "Z034"}
LANGUAGE = {"Z027"}
HYBRID = {"Z006", "Z012", "Z015", "Z023", "Z032", "Z033"}

ZIGLINT_LINE = re.compile(r"^(Z\d{3}): (.+?):(\d+): ")
# Text output (`error[style, Z026]`) and the build runner's rendering of
# the compiler protocol's (`error: [style Z026]`).
BS_LINE = re.compile(
    r"^(.+?):(\d+):\d+: error(?:\[(?:style|deprecated), (Z\d{3})\]|: \[(?:style|deprecated) (Z\d{3})\])"
)


def ziglint_findings(ziglint, tree):
    out = subprocess.run([ziglint], check=False, cwd=tree, capture_output=True, text=True)
    found = collections.Counter()
    for line in (out.stdout + out.stderr).splitlines():
        m = ZIGLINT_LINE.match(line)
        if m:
            found[(m.group(1), os.path.normpath(m.group(2)), int(m.group(3)))] += 1
    return found


def bs_run(bs, tree, args):
    out = subprocess.run([bs, *args], check=False, cwd=tree, capture_output=True, text=True)
    found = collections.Counter()
    for line in (out.stdout + out.stderr).splitlines():
        m = BS_LINE.match(line)
        if m:
            found[(m.group(3) or m.group(4), os.path.normpath(m.group(1)), int(m.group(2)))] += 1
    return found


def bs_findings(bs, tree, args):
    found = bs_run(bs, tree, args)
    in_build = collections.Counter({k: n for k, n in found.items() if k[1] == "build.zig"})
    if not in_build:
        return found
    config = os.path.join(tree, ".ziglint.zon")
    with open(config) as f:
        original = f.read()
    try:
        with open(config, "w") as f:
            f.write(re.sub(r'"build\.zig"\s*,?\s*', "", original))
        rest = bs_run(bs, tree, args)
    finally:
        with open(config, "w") as f:
            f.write(original)
    return in_build + rest


def classify(key, side, bs_files):
    rule, path, _ = key
    if rule in SEMA and side == "bs only":
        return "sema-type"
    if rule in SEMA and path in bs_files:
        return "unanalyzed"
    if rule in LANGUAGE:
        return "language"
    if rule in HYBRID:
        return "hybrid"
    if path not in bs_files:
        return "unreached"
    return "bug"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bs", required=True)
    ap.add_argument("--ziglint", default="ziglint")
    ap.add_argument("--tree", default=".")
    ap.add_argument("--list", action="store_true", help="list every difference, not only bugs")
    ap.add_argument("args", nargs="*", default=["build"], help="bs's arguments (default: build)")
    opts = ap.parse_args()
    bs = os.path.abspath(opts.bs)

    zl = ziglint_findings(opts.ziglint, opts.tree)
    ours = bs_findings(bs, opts.tree, opts.args)
    bs_files = {path for _, path, _ in ours}
    only_zl = zl - ours
    only_bs = ours - zl
    both = zl & ours

    rows = collections.defaultdict(lambda: collections.Counter())
    for key, n in both.items():
        rows[key[0]]["same"] += n
    diffs = []
    for side, counter in (("ziglint only", only_zl), ("bs only", only_bs)):
        for key, n in counter.items():
            cls = classify(key, side, bs_files)
            rows[key[0]][f"{side}: {cls}"] += n
            diffs.append((cls, side, key, n))

    print(f"ziglint: {sum(zl.values())} findings; bs: {sum(ours.values())}; matched: {sum(both.values())}")
    for rule in sorted(rows):
        print(f"  {rule}: " + ", ".join(f"{k} {v}" for k, v in sorted(rows[rule].items())))
    classes = collections.Counter()
    for cls, side, key, n in diffs:
        classes[cls] += n
    print("differences: " + (", ".join(f"{c} {n}" for c, n in sorted(classes.items())) or "none"))
    for cls, side, (rule, path, line), n in sorted(diffs, key=lambda d: (d[0], d[2])):
        if cls == "bug" or opts.list:
            print(f"  {cls}: {side}: {rule} {path}:{line}" + (f" ({n} times)" if n > 1 else ""))
    return 1 if classes["bug"] else 0


if __name__ == "__main__":
    sys.exit(main())
