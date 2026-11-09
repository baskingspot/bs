#!/usr/bin/env python3
"""Scores bs's compile errors on the mistakes coding agents make.

Upstream's compile-error suite tests what upstream thought of. This eval
tests what agents write: Zig against an older std (0.11 to 0.16 APIs in
0.17 code), misspelled names, a missing `try`, and the like. It takes
the seed programs in seeds/ (correct 0.17 code that bs and upstream
compile), rewrites each one into mistakes by the rules in rules.py, and
compiles every mistake with bs and with upstream zig. A seed named
`build_*.zig` is a build.zig instead, configured with `build -l` next to
a hello-world src/main.zig, so build scripts written against an older
std.Build are scored through the `bs build` path. A seed named
`test_*.zig` is compiled with `test`, so its test blocks count.

A case whose rewrite upstream still accepts is not a mistake and is
dropped. For each remaining case it checks, for bs and for upstream:

- loc:    the first error is on a line the rewrite changed;
- facts:  the output (as an agent reads it: text, with source lines and
          notes) contains what the fix needs, such as the 0.17 name of an
          API (the rule's `facts`);

and for bs alone:

- cand:   a candidate list names the right identifier (rules with an
          answer);
- fix:    bs offers a fix of an error at a changed line, or one that
          edits a changed line; applying bs's fixes round
          after round either restores the seed ("restored"), or gives a
          program upstream compiles ("compiles"), or neither ("wrong");
- accept: bs and upstream agree that the program is wrong. A
          disagreement is a bug in bs and is listed.

Usage:

    python3 tools/diag/eval/run.py --bs zig-out/bin/bs [--jobs 3] [--out eval.json]
    python3 tools/diag/eval/run.py --filter arraylist --show   # print each case's outputs

The report lists the score per category and the cases where upstream's
output alone lacks the facts ("upstream leaves the agent guessing").
"""

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, HERE)
import rules

SEEDS = os.path.join(HERE, "seeds")


def run(cmd, cwd, env=None):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env, timeout=300, check=False)
    return p.returncode, p.stdout + p.stderr


# A seed named `build_*` is a build.zig, configured (`build -l`) next to
# this src/main.zig; the others are a main.zig, compiled.
BUILD_MAIN = 'const std = @import("std");\npub fn main() void {\n    std.debug.print("hi\\n", .{});\n}\n'


def seed_file(seed):
    if seed.startswith("build_"):
        return "build.zig"
    return "tests.zig" if seed.startswith("test_") else "main.zig"


def compile_cmd(fname):
    """The subcommand that compiles a seed file: its tests for `test_*`
    seeds (tests.zig), else as an executable."""
    return "test" if fname == "tests.zig" else "build-exe"


def write_case(d, seed, src):
    with open(os.path.join(d, seed_file(seed)), "w") as f:
        f.write(src)
    if seed_file(seed) == "build.zig":
        os.makedirs(os.path.join(d, "src"), exist_ok=True)
        with open(os.path.join(d, "src", "main.zig"), "w") as f:
            f.write(BUILD_MAIN)


class Compilers:
    def __init__(self, bs, zig, cache):
        self.bs = bs
        self.zig = zig
        self.cache = cache
        self.env = dict(os.environ, BS_CACHE="off")

    def bs_json(self, d, fname):
        if fname == "build.zig":
            # `bs build` renders upstream's text, with bs's facts as notes.
            _, out = self.bs_text(d, fname)
            return parse_bundle_text(out, d)
        _, out = run([self.bs, compile_cmd(fname), "-fno-emit-bin", "--error-format=json", fname], d, self.env)
        diags = []
        for line in out.splitlines():
            if line.startswith("{"):
                obj = json.loads(line)
                if "summary" not in obj:
                    diags.append(obj)
        return diags

    def bs_text(self, d, fname):
        if fname == "build.zig":
            return run([self.bs, "build", "-l"], d, self.env)
        return run([self.bs, compile_cmd(fname), "-fno-emit-bin", fname], d, self.env)

    def upstream(self, d, fname):
        if fname == "build.zig":
            return run([self.zig, "build", "-l", "--cache-dir", os.path.join(d, ".zig-cache")], d)
        return run([self.zig, compile_cmd(fname), "-fno-emit-bin", "--cache-dir", self.cache, fname], d)


def zig_unescape(text):
    """The bytes of the inside of a Zig string literal."""
    out, i = bytearray(), 0
    b = text.encode()
    while i < len(b):
        c = b[i]
        if c != 0x5C:
            out.append(c)
            i += 1
            continue
        e = chr(b[i + 1])
        if e == "x":
            out.append(int(b[i + 2 : i + 4], 16))
            i += 4
        elif e == "u":
            end = b.index(b"}", i)
            out += chr(int(b[i + 3 : end], 16)).encode()
            i = end + 1
        else:
            out += {"n": b"\n", "r": b"\r", "t": b"\t"}.get(e, e.encode())
            i += 2
    return out.decode()


def parse_bundle_text(text, d):
    """bs's diagnostics as `bs_json` gives them, from the upstream-style
    text of `bs build`: errors and notes with a location, and the
    candidates, hint and fixes it renders as notes without one. Fix spans
    are byte offsets, found from line and column in the edited file."""
    diags = []
    fix_re = re.compile(r'^note: (fix\??) (\S+?):(\d+):(\d+)-(\d+):(\d+): "(.*)"$')
    for line in text.splitlines():
        m = re.match(r"^(\S+?):(\d+):(\d+): (error|note): (.*)$", line)
        if m:
            path, ln, _, kind, msg = m.groups()
            if kind == "error":
                msg = re.sub(r"^\[[a-z-]+\] ", "", msg)
                diags.append({"file": path, "line": int(ln), "msg": msg, "notes": [], "fixes": []})
            elif diags:
                diags[-1]["notes"].append({"file": path, "line": int(ln), "msg": msg})
            continue
        if not diags:
            continue
        if line.startswith("note: candidates: "):
            diags[-1]["candidates"] = line[len("note: candidates: ") :].split(", ")
            continue
        m = fix_re.match(line)
        if m:
            kind, path, l1, c1, l2, c2, body = m.groups()
            try:
                src = open(os.path.join(d, path), "rb").read()
            except OSError:
                continue
            starts = [0] + [i + 1 for i, ch in enumerate(src) if ch == 0x0A]
            span = [starts[int(l1) - 1] + int(c1) - 1, starts[int(l2) - 1] + int(c2) - 1]
            edit = {"file": path, "span": span, "text": zig_unescape(body)}
            fixes = diags[-1]["fixes"]
            # Consecutive edits of one kind belong to one fix.
            if (
                fixes
                and fixes[-1]["applicability"] == ("exact" if kind == "fix" else "maybe")
                and fixes[-1].get("_open")
            ):
                fixes[-1]["edits"].append(edit)
            else:
                fixes.append({"applicability": "exact" if kind == "fix" else "maybe", "edits": [edit], "_open": True})
            continue
        for f in diags[-1]["fixes"]:
            f.pop("_open", None)
    return diags


def upstream_errors(text, fname="main.zig"):
    """(line, msg, note lines) of each error in upstream's output, with
    lines in `fname` only (0 elsewhere)."""
    out = []
    for line in text.splitlines():
        for kind in (": error: ", ": note: "):
            head, sep, msg = line.partition(kind)
            if sep:
                break
        else:
            continue
        path, ln, _ = head.rsplit(":", 2) if head.count(":") >= 2 else (head, "0", "0")
        ln = int(ln) if path.endswith(fname) and ln.isdigit() else 0
        if kind == ": error: ":
            out.append((ln, msg, []))
        elif out:
            out[-1][2].append(ln)
    return out


def has_facts(text, facts):
    return all(any(alt in text for alt in group) for group in facts)


def apply_fixes(src, fixes):
    """`src` with `fixes` applied, skipping any that overlaps an earlier one."""
    taken, edits = [], []
    for fix in fixes:
        spans = [e["span"] for e in fix["edits"]]
        if any(s < te and ts < e or s == e == ts for s, e in spans for ts, te in taken):
            continue
        taken += spans
        edits += fix["edits"]
    data = src.encode()
    out, pos = b"", 0
    for e in sorted(edits, key=lambda e: e["span"][0]):
        s, t = e["span"]
        out += data[pos:s] + e["text"].encode()
        pos = t
    return (out + data[pos:]).decode()


def norm(src):
    return " ".join(src.split())


def score(case, seed_src, cc, show):
    d = tempfile.mkdtemp(prefix="bs-eval-")
    try:
        fname = seed_file(case.seed)
        path = os.path.join(d, fname)
        write_case(d, case.seed, case.src)
        up_code, up_text = cc.upstream(d, fname)
        if up_code == 0:
            return {"id": case.id, "dropped": "upstream accepts"}
        bs_code, bs_text = cc.bs_text(d, fname)
        r = {
            "id": case.id,
            "rule": case.rule.id,
            "category": case.rule.category,
            "since": case.rule.since,
            "seed": case.seed,
            "lines": case.lines,
        }
        if bs_code == 0:
            r["accept"] = "bs accepts"
            return r
        diags = cc.bs_json(d, fname)
        main_diags = [x for x in diags if x.get("file") == fname]
        up_errs = upstream_errors(up_text, fname)
        lines = set(case.lines)
        # The first error points at a changed line, itself or by a note.
        r["bs_loc"] = bool(diags) and any(
            x.get("file") == fname and x.get("line") in lines for x in [diags[0]] + diags[0].get("notes", [])
        )
        r["up_loc"] = bool(up_errs) and any(ln in lines for ln in [up_errs[0][0]] + up_errs[0][2])
        r["bs_facts"] = has_facts(bs_text, case.facts)
        r["up_facts"] = has_facts(up_text, case.facts)
        r["bs_first"] = f"{diags[0].get('file')}:{diags[0].get('line')}: {diags[0]['msg']}" if diags else ""
        r["up_first"] = f"{fname}:{up_errs[0][0]}: {up_errs[0][1]}" if up_errs else up_text.strip().split("\n")[0]
        if case.answer:
            r["cand"] = any(case.answer in x.get("candidates", []) for x in diags)
        # A fix of an error on a changed line, or one that edits a changed
        # line (a `var` at the declaration for an error at the use).
        # An error raised in std can carry a fix in the case's file.
        edit_lines = lambda x: {
            case.src.count("\n", 0, e["span"][0]) + 1
            for f in x.get("fixes", [])
            for e in f["edits"]
            if e.get("file") == fname
        }
        at = [
            x
            for x in diags
            if x.get("fixes") and ((x in main_diags and x.get("line") in lines) or edit_lines(x) & lines)
        ]
        if at:
            src = case.src
            for _ in range(5):
                fixes = [
                    f
                    for x in cc.bs_json(d, fname)
                    for f in x.get("fixes", [])
                    if f["applicability"] != "placeholder" and all(e.get("file") == fname for e in f["edits"])
                ]
                if not fixes:
                    break
                src = apply_fixes(src, fixes)
                with open(path, "w") as f:
                    f.write(src)
            if norm(src) == norm(seed_src):
                r["fix"] = "restored"
            else:
                code, text = cc.upstream(d, fname)
                edited = set(rules.changed_lines(case.src, src))
                if code == 0:
                    r["fix"] = "compiles"
                elif any(ln in edited for ln, _, _ in upstream_errors(text, fname)):
                    # An error is left or made where a fix edited.
                    r["fix"] = "wrong"
                else:
                    # The fixed errors are gone; others they hid are not.
                    r["fix"] = "partial"
                r["fixed_src"] = src
        if show:
            r["bs_text"] = bs_text
            r["up_text"] = up_text
        return r
    finally:
        shutil.rmtree(d)


def pct(n, d):
    return f"{n}/{d} ({100 * n // d if d else 0}%)"


def report(results):
    kept = [r for r in results if "dropped" not in r]
    dropped = [r for r in results if "dropped" in r]
    print(f"{len(kept)} cases ({len(dropped)} rewrites dropped: upstream accepts them)\n")
    cats = sorted({r["category"] for r in kept})
    hdr = f"{'category':<13}{'cases':>6}  {'loc bs/up':>13}  {'facts bs/up':>13}  {'cand':>7}  {'fix ok/partial/offered':>23}"
    print(hdr)
    print("-" * len(hdr))
    for cat in cats + ["all"]:
        rs = [r for r in kept if cat == "all" or r["category"] == cat]
        scored = [r for r in rs if "accept" not in r]
        n = len(rs)
        zl = sum(r.get("bs_loc", False) for r in scored)
        ul = sum(r.get("up_loc", False) for r in scored)
        zf = sum(r.get("bs_facts", False) for r in scored)
        uf = sum(r.get("up_facts", False) for r in scored)
        cand = [r for r in scored if "cand" in r]
        fixes = [r for r in scored if "fix" in r]
        good = sum(r["fix"] in ("restored", "compiles") for r in fixes)
        part = sum(r["fix"] == "partial" for r in fixes)
        print(
            f"{cat:<13}{n:>6}  {zl:>5} / {ul:<5}  {zf:>5} / {uf:<5}  {sum(r['cand'] for r in cand):>3}/{len(cand):<3}  {good:>7} / {part:<3} / {len(fixes):<6}"
        )
    bad = [r for r in kept if "accept" in r]
    if bad:
        print("\nbs accepts what upstream rejects:")
        for r in bad:
            print(f"  {r['id']}")
    wrong = [r for r in kept if r.get("fix") == "wrong"]
    if wrong:
        print("\nfixes that leave or make an error where they edit:")
        for r in wrong:
            print(f"  {r['id']}")
    print("\nupstream leaves the agent guessing (no facts), and bs:")
    for r in kept:
        if "accept" in r or r.get("up_facts"):
            continue
        mark = "ok  " if r.get("bs_facts") else "MISS"
        print(f"  {mark} {r['id']:<40} {r['up_first'][:110]}")
    print("\nbs misses the facts or the location:")
    for r in kept:
        if "accept" in r or (r.get("bs_facts") and r.get("bs_loc")):
            continue
        what = ("" if r.get("bs_loc") else "loc ") + ("" if r.get("bs_facts") else "facts")
        print(f"  {what:<10} {r['id']:<40} {r['bs_first'][:110]}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--bs", default=os.path.join(REPO, "zig-out/bin/bs"))
    p.add_argument("--zig", default="zig")
    p.add_argument("--jobs", type=int, default=3)
    p.add_argument("--out", help="write every case's result as JSON")
    p.add_argument("--filter", help="only cases whose id contains this")
    p.add_argument("--show", action="store_true", help="print each case's source and both outputs")
    p.add_argument("--list", action="store_true", help="list the cases and exit")
    args = p.parse_args()

    seeds = {}
    for f in sorted(os.listdir(SEEDS)):
        if f.endswith(".zig"):
            seeds[f[:-4]] = open(os.path.join(SEEDS, f)).read()
    cases = [c for rule in rules.RULES for name, src in seeds.items() for c in rule.cases(name, src)]
    if args.filter:
        cases = [c for c in cases if args.filter in c.id]
    if args.list:
        for c in cases:
            print(c.id, c.lines)
        return

    cache = tempfile.mkdtemp(prefix="bs-eval-cache-")
    cc = Compilers(os.path.abspath(args.bs), args.zig, cache)
    try:
        # The seeds themselves must compile with both.
        for name, src in seeds.items():
            d = tempfile.mkdtemp(prefix="bs-eval-seed-")
            write_case(d, name, src)
            for who, (code, out) in (
                ("upstream", cc.upstream(d, seed_file(name))),
                ("bs", cc.bs_text(d, seed_file(name))),
            ):
                if code != 0:
                    sys.exit(f"seed {name} does not compile with {who}:\n{out}")
            shutil.rmtree(d)
        with concurrent.futures.ThreadPoolExecutor(args.jobs) as ex:
            results = list(ex.map(lambda c: score(c, seeds[c.seed], cc, args.show), cases))
    finally:
        shutil.rmtree(cache, ignore_errors=True)

    if args.show:
        by_id = {c.id: c for c in cases}
        for r in results:
            print(f"===== {r['id']} {r.get('dropped', '')}")
            if "dropped" in r:
                continue
            print(by_id[r["id"]].src)
            print("--- bs\n" + r.get("bs_text", ""))
            print("--- upstream\n" + r.get("up_text", ""))
            if "fixed_src" in r:
                print("--- after bs's fixes\n" + r["fixed_src"])
    report(results)
    if args.out:
        with open(args.out, "w") as f:
            json.dump(results, f, indent=1)


if __name__ == "__main__":
    main()
