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

A build that fails for a reason other than a finding (an error that is
not a finding, or a nonzero exit with no finding) hides the findings of
everything it did not compile: that tree or project counts as
`build-failed`, with the first such error.

sema-type and unanalyzed are told apart by side alone; spot-check them
with --list.

Findings in the build script (build.zig and the files it imports) fail
the build's configure step, which hides every other step's, so when bs
reports any there, it runs again with an ignore comment appended to each
of their lines (the files are restored), and takes them from the first
run.

With --corpus, it compares on the parity set instead: the baskingspot
projects in tools/corpus/manifest.json's `lint` list, which have a
.ziglint.zon and build with zig 0.17.1, each at its pinned commit with its
`build` steps (checked out by tools/corpus/run.py under
tools/corpus/.work/src/).

A finding that several compile steps report counts once.

Exits 1 if there is a `bug` difference or a `build-failed` build.

    python3 tools/lint/parity.py --bs zig-out/bin/bs --ziglint ziglint [--tree DIR] [-- build args]
    python3 tools/lint/parity.py --bs zig-out/bin/bs --ziglint ziglint --corpus [--projects a,b] [--list]
"""

import argparse
import collections
import itertools
import json
import os
import re
import subprocess
import sys

REPO_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

SEMA = {"Z010", "Z011", "Z029", "Z034"}
LANGUAGE = {"Z027"}
HYBRID = {"Z006", "Z012", "Z015", "Z023", "Z032", "Z033"}

ZIGLINT_LINE = re.compile(r"^(Z\d{3}): (.+?):(\d+): ")
# Text output (`error[style, Z026]`) and the build runner's rendering of
# the compiler protocol's (`error: [style Z026]`).
BS_LINE = re.compile(
    r"^(.+?):(\d+):(\d+): error(?:\[(?:style|deprecated), (Z\d{3})\]|: \[(?:style|deprecated) (Z\d{3})\])"
)

# The end of one compilation's errors: the build runner's, or bs's own.
BLOCK_END = re.compile(r"^(?:error: )?\d+ (?:compilation )?errors?$")
# Any error, located or not; a finding or a block's end is not a failure.
ANY_ERROR = re.compile(r"^(?:.+?:\d+:\d+: )?error\b")


def ziglint_findings(ziglint, tree):
    out = subprocess.run([ziglint], check=False, cwd=tree, capture_output=True, text=True)
    found = collections.Counter()
    for line in (out.stdout + out.stderr).splitlines():
        m = ZIGLINT_LINE.match(line)
        if m:
            found[(m.group(1), os.path.normpath(m.group(2)), int(m.group(3)))] += 1
    return found


def bs_run(bs, tree, args):
    """Returns the findings, and the first error that is not one (or the
    exit status, when the run failed with no error at all), or None."""
    out = subprocess.run([bs, *args], check=False, cwd=tree, capture_output=True, text=True)
    lines = (out.stdout + out.stderr).splitlines()
    # Each compile step that covers a file reports its findings: count a
    # finding (rule and column) as often as one compilation reports it.
    # A compilation's errors end with their count.
    most = collections.Counter()
    block = collections.Counter()
    failure = None
    for i, line in enumerate(lines + ["1 error"]):
        m = BS_LINE.match(line)
        if m:
            block[(m.group(4) or m.group(5), os.path.normpath(m.group(1)), int(m.group(2)), int(m.group(3)))] += 1
        elif BLOCK_END.match(line):
            most |= block
            block = collections.Counter()
        elif failure is None and ANY_ERROR.match(line):
            # With the notes that follow it, which say what failed when
            # the error itself does not (translate-c's "translation
            # failure").
            notes = list(itertools.takewhile(lambda n: n.startswith(" ") or "note:" in n, lines[i + 1 : i + 6]))
            failure = "\n".join([line, *notes])
    found = collections.Counter()
    for key, n in most.items():
        found[key[:3]] += n
    if failure is None and out.returncode != 0 and not found:
        failure = f"exit status {out.returncode}" + (f": {lines[-1]}" if lines else "")
    return found, failure


def bs_findings(bs, tree, args):
    """Returns the findings and the first failure (bs_run)."""
    found, failure = bs_run(bs, tree, args)
    if failure or not any(k[1] == "build.zig" for k in found):
        return found, failure
    # The build script's findings fail the configure step, before any other
    # step runs: run again with each of them ignored by a comment at the end
    # of its line (which keeps the line numbers), and restore the files.
    lines = collections.defaultdict(lambda: collections.defaultdict(set))
    for rule, path, line in found:
        lines[path][line].add(rule)
    originals = {}
    try:
        for path, by_line in lines.items():
            full = os.path.join(tree, path)
            with open(full) as f:
                originals[full] = f.read()
            text = originals[full].split("\n")
            for line, rules in by_line.items():
                # The comment makes the line longer.
                text[line - 1] += " // ziglint-ignore: " + " ".join(sorted(rules | {"Z024"}))
            with open(full, "w") as f:
                f.write("\n".join(text))
        rest, failure = bs_run(bs, tree, args)
    finally:
        for full, text in originals.items():
            with open(full, "w") as f:
                f.write(text)
    return found + rest, failure


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


def compare(bs, ziglint, tree, args, list_all, indent=""):
    """Prints the comparison on `tree`; returns the differences' classes."""
    zl = ziglint_findings(ziglint, tree)
    ours, failure = bs_findings(bs, tree, args)
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

    print(f"{indent}ziglint: {sum(zl.values())} findings; bs: {sum(ours.values())}; matched: {sum(both.values())}")
    for rule in sorted(rows):
        print(f"{indent}  {rule}: " + ", ".join(f"{k} {v}" for k, v in sorted(rows[rule].items())))
    classes = collections.Counter()
    for cls, side, key, n in diffs:
        classes[cls] += n
    if failure:
        classes["build-failed"] += 1
        print(f"{indent}build-failed: " + failure.replace("\n", "\n" + indent + "  "))
    print(f"{indent}differences: " + (", ".join(f"{c} {n}" for c, n in sorted(classes.items())) or "none"))
    for cls, side, (rule, path, line), n in sorted(diffs, key=lambda d: (d[0], d[2])):
        if cls == "bug" or list_all:
            print(f"{indent}  {cls}: {side}: {rule} {path}:{line}" + (f" ({n} times)" if n > 1 else ""))
    return classes, sum(zl.values()), sum(ours.values()), sum(both.values())


def corpus(opts, bs):
    """The parity set: tools/corpus/manifest.json's `lint` projects, each
    checked out at its pinned commit by tools/corpus/run.py and compared
    with its `build` steps."""
    sys.path.insert(0, os.path.join(REPO_DIR, "tools", "corpus"))
    import run as corpus_run

    with open(os.path.join(REPO_DIR, "tools", "corpus", "manifest.json")) as f:
        projects = json.load(f)["lint"]
    if opts.projects:
        names = set(opts.projects.split(","))
        projects = [p for p in projects if p["name"] in names]
    total = collections.Counter()
    sums = [0, 0, 0]
    for proj in projects:
        src = corpus_run.checkout(proj, opts.zig)
        print(f"{proj['name']} ({' '.join(proj['build'])}):")
        # Two jobs: the projects' compile steps in parallel exhaust an
        # orb's memory.
        classes, zl, ours, both = compare(bs, opts.ziglint, src, ["build", "-j2", *proj["build"]], opts.list, "  ")
        total += classes
        sums = [sums[0] + zl, sums[1] + ours, sums[2] + both]
    print(f"parity set: {len(projects)} projects; ziglint: {sums[0]} findings; bs: {sums[1]}; matched: {sums[2]}")
    print("differences: " + (", ".join(f"{c} {n}" for c, n in sorted(total.items())) or "none"))
    return 1 if total["bug"] or total["build-failed"] else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bs", required=True)
    ap.add_argument("--ziglint", default="ziglint")
    ap.add_argument("--tree", default=".")
    ap.add_argument("--list", action="store_true", help="list every difference, not only bugs")
    ap.add_argument("--corpus", action="store_true", help="compare on the parity set instead of --tree")
    ap.add_argument("--projects", help="with --corpus: only these projects (comma-separated)")
    ap.add_argument("--zig", default="zig", help="with --corpus: upstream zig, for fetching")
    ap.add_argument("args", nargs="*", default=["build"], help="bs's arguments (default: build)")
    opts = ap.parse_args()
    bs = os.path.abspath(opts.bs)
    if opts.corpus:
        return corpus(opts, bs)
    classes = compare(bs, opts.ziglint, opts.tree, opts.args, opts.list)[0]
    return 1 if classes["bug"] or classes["build-failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
