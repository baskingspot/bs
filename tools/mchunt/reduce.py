#!/usr/bin/env python3
"""Minimizes a Zig program while a mismatch persists (tools/mchunt).

    python3 tools/mchunt/reduce.py .work/found/miscompile-1234
    python3 tools/mchunt/reduce.py prog.zig --bad bs      # any program

The property kept is the finding's: upstream zig (Debug) compiles the
program and runs it to a normal exit or a panic, and the failing bs
configuration compiles it and disagrees, with the same kinds of outcome
as the original (say, upstream exits normally and bs panics with
"integer overflow"). A control configuration that agreed with upstream
originally (bs with BS_INLINE=0, say) must keep agreeing, so the
reduction stays on the same bug and keeps its attribution.

Passes, repeated until nothing shrinks: delete statements and
declarations (a line and the block it opens), hoist the body of an
`if`/loop/block, and replace parenthesized expressions with an operand,
a branch, a builtin's argument, or a literal. Zig rejects unused locals,
never-mutated `var`s and pointless discards, so after each edit the
errors `zig ast-check` reports for those are fixed mechanically.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness as H  # noqa: E402

DIGITS = re.compile(r"\d+")


def norm_kind(o):
    return DIGITS.sub("N", o.kind())


def first_error(detail):
    for l in detail.splitlines():
        if "error" in l or "panic" in l:
            return DIGITS.sub("N", l.split(": ", 1)[-1])[:120]
    return ""


class Property:
    def __init__(self, tools, bad, up_kind, bad_kind, control=None, cls="miscompile", err="", base=None):
        self.tools, self.bad, self.up_kind, self.bad_kind = tools, H.BY_NAME[bad], up_kind, bad_kind
        # A branch's regression: bs from main (`base`) must keep agreeing.
        self.base = base
        self.control = H.BY_NAME[control] if control else None
        self.cls, self.err = cls, err
        self.cache = {}
        self.tests = 0
        self.scratch = H.new_scratch("reduce-")

    def __call__(self, text):
        h = hashlib.sha1(text.encode()).hexdigest()
        if h not in self.cache:
            self.cache[h] = self.check(text)
        return self.cache[h]

    def check(self, text):
        self.tests += 1
        src = os.path.join(self.scratch, "r.zig")
        with open(src, "w") as f:
            f.write(text)
        ok, _ = H.ast_check(self.tools, src)
        if not ok:
            return False
        b = H.run_config(self.tools, self.bad, src, self.scratch)
        if self.cls == "bs-crash":
            if b.status != "compile-crash" or first_error(b.detail) != self.err:
                return False
        elif self.cls == "bs-reject":
            if b.status != "compile-error" or first_error(b.detail) != self.err:
                return False
        elif not b.compiled() or norm_kind(b) != self.bad_kind:
            return False
        up = H.run_config(self.tools, H.ORACLE, src, self.scratch)
        if up.status not in ("ok", "panic") or norm_kind(up) != self.up_kind:
            return False
        if self.cls == "miscompile" and up.key() == b.key():
            return False
        if self.control is not None:
            c = H.run_config(self.tools, self.control, src, self.scratch)
            if c.key() != up.key():
                return False
        if self.base is not None:
            c = H.run_config(self.base, self.bad, src, self.scratch)
            if c.key() != up.key():
                return False
        return True

    def close(self):
        shutil.rmtree(self.scratch, ignore_errors=True)


# ---------------------------------------------------------------- text helpers


def matching(text, i):
    """Index of the bracket closing the one at `i`, skipping strings and
    comments; -1 if unbalanced."""
    open_, close = text[i], {"(": ")", "[": "]", "{": "}"}[text[i]]
    depth = 0
    j = i
    n = len(text)
    while j < n:
        c = text[j]
        if c == '"':
            j += 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
        elif c == "/" and text.startswith("//", j):
            while j < n and text[j] != "\n":
                j += 1
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                return j if c == close else -1
        j += 1
    return -1


def units(lines):
    """(start, end) line ranges of statements: a line and, if it opens
    more brackets than it closes, every line up to where they close."""
    out = []
    depth_at = []
    d = 0
    for l in lines:
        depth_at.append(d)
        d += line_depth(l)
    for i, l in enumerate(lines):
        s = l.strip()
        if not s or s.startswith("}") or s.startswith("//"):
            continue
        if line_depth(l) > 0:
            j = i + 1
            dd = depth_at[i] + line_depth(l)
            while j < len(lines) and dd > depth_at[i]:
                dd += line_depth(lines[j])
                j += 1
            out.append((i, j))
        elif line_depth(l) == 0:
            out.append((i, i + 1))
    return out


def line_depth(l):
    d = 0
    instr = False
    i = 0
    while i < len(l):
        c = l[i]
        if instr:
            if c == "\\":
                i += 1
            elif c == '"':
                instr = False
        elif c == '"':
            instr = True
        elif l.startswith("//", i):
            break
        elif c in "([{":
            d += 1
        elif c in ")]}":
            d -= 1
        i += 1
    return d


# ---------------------------------------------------------------- fixer

ERR = re.compile(r"^[^:]+:(\d+):(\d+): error: (.*)$")


def ident_at(line, col):
    m = re.match(r"[A-Za-z_]\w*", line[col - 1:])
    return m.group(0) if m else None


def stmt_end(lines, li, col):
    """(line, col index after) the `;` ending the statement at li:col."""
    depth = 0
    i, c = li, col - 1
    while i < len(lines):
        l = lines[i]
        while c < len(l):
            ch = l[c]
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
            elif ch == ";" and depth <= 0:
                return i, c + 1
            c += 1
        i += 1
        c = 0
    return None


def fix_once(text, errs):
    """Applies the first fixable AstGen error; returns new text or None."""
    lines = text.split("\n")
    for line, col, msg in errs:
        li = line - 1
        if li >= len(lines):
            continue
        l = lines[li]
        name = ident_at(l, col)
        if msg in ("unused local constant", "unused local variable") and name:
            e = stmt_end(lines, li, col)
            if e:
                el, ec = e
                lines[el] = lines[el][:ec] + f" _ = {name};" + lines[el][ec:]
                return "\n".join(lines)
        if msg == "unused function parameter" and name:
            j = li
            while j < len(lines) and not lines[j].rstrip().endswith("{"):
                j += 1
            lines.insert(j + 1, f"    _ = {name};")
            return "\n".join(lines)
        if msg == "local variable is never mutated":
            k = l.rfind("var ", 0, col - 1)
            if k >= 0:
                lines[li] = l[:k] + "const " + l[k + 4:]
                return "\n".join(lines)
        if msg.startswith("pointless discard"):
            m = re.match(r"_ = [A-Za-z_]\w*;", l[col - 1:])
            if m:
                lines[li] = (l[:col - 1] + l[col - 1 + m.end():]).rstrip()
                if not lines[li].strip():
                    del lines[li]
                return "\n".join(lines)
        if msg == "unused capture" and name:
            lines[li] = l[:col - 1] + "_" + l[col - 1 + len(name):]
            return "\n".join(lines)
        if msg == "discard of capture; omit it instead":
            k = l.rfind("|", 0, col - 1)
            m = re.match(r"\|\s*_\s*\|\s?", l[k:]) if k >= 0 else None
            if m:
                lines[li] = l[:k] + l[k + m.end():]
                return "\n".join(lines)
        if msg == "discard of unbounded counter":
            nl = re.sub(r", 0\.\.\)", ")", l, count=1)
            nl = re.sub(r", _\|", "|", nl, count=1)
            if nl != l:
                lines[li] = nl
                return "\n".join(lines)
        if msg.startswith("unused") and "label" in msg and name:
            lines[li] = l[:col - 1] + l[col - 1:].replace(f"{name}: ", "", 1)
            return "\n".join(lines)
    return None


def fix(tools, text, scratch, rounds=40):
    src = os.path.join(scratch, "fix.zig")
    for _ in range(rounds):
        with open(src, "w") as f:
            f.write(text)
        ok, err = H.ast_check(tools, src)
        if ok:
            return text
        errs = []
        for l in err.splitlines():
            m = ERR.match(l)
            if m:
                errs.append((int(m.group(1)), int(m.group(2)), m.group(3)))
        if not errs:
            return None
        nt = fix_once(text, errs)
        if nt is None:
            return None
        text = nt
    return None


# ---------------------------------------------------------------- passes

BINOPS = ["<<|", "+%", "-%", "*%", "+|", "-|", "*|", "<<", ">>", "==", "!=", "<=", ">=", "and", "or",
          "+", "-", "*", "/", "%", "&", "|", "^", "<", ">", "orelse", "catch"]


def split_top(inner):
    """Operands of a top-level binary operator in `inner`, if any."""
    depth = 0
    i = 0
    n = len(inner)
    prev_operand = False
    while i < n:
        c = inner[i]
        if c == '"':
            j = i + 1
            while j < n and inner[j] != '"':
                j += 2 if inner[j] == "\\" else 1
            i = j + 1
            prev_operand = True
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            prev_operand = True
            i += 1
            continue
        if depth == 0:
            if c == " ":
                i += 1
                continue
            for op in BINOPS:
                if inner.startswith(op, i) and prev_operand:
                    if op.isalpha() and not (inner[i - 1:i] == " " and inner[i + len(op):i + len(op) + 1] == " "):
                        continue
                    if op in ("<", ">", "|", "&", "*", "-", "+", "%", "/", "^") and inner[i + 1:i + 2] == "=":
                        continue
                    return inner[:i].strip(), inner[i + len(op):].strip()
            if c.isalnum() or c in "_@.?":
                prev_operand = True
            else:
                prev_operand = False
        i += 1
    return None


def group_candidates(text, i, j):
    """Replacements for the bracketed group text[i..j] (inclusive)."""
    inner = text[i + 1:j]
    before = text[:i]
    m = re.search(r"(@\w+|[A-Za-z_]\w*)\s*$", before)
    word = m.group(1) if m else None
    cands = []
    if word in ("@import", "@setEvalBranchQuota"):
        return cands
    if word and word.startswith("@"):
        # A builtin call: replace the whole call with an argument.
        start = i - len(m.group(0))
        args = split_args(inner)
        for a in args:
            if a and not a.startswith("std.math.") and not re.match(r"^[ui]\d+$|^bool$|^usize$", a):
                cands.append((start, j + 1, f"({a})" if " " in a else a))
        if word == "@as" and len(args) == 2:
            cands.append((start, j + 1, f"@as({args[0]}, 0)"))
        return cands
    if word in ("if", "while", "switch"):
        if word != "switch":
            cands += [(i, j + 1, "(true)"), (i, j + 1, "(false)")]
        return cands
    if word or text[i] != "(":
        return cands
    parts = split_top(inner)
    if parts:
        for p in parts:
            cands.append((i, j + 1, f"({p})"))
    ifm = re.match(r"^if (\(.*?\)) (.*) else (.*)$", inner, re.S)
    if ifm:
        cands.append((i, j + 1, f"({ifm.group(2)})"))
        cands.append((i, j + 1, f"({ifm.group(3)})"))
    cands += [(i, j + 1, "0"), (i, j + 1, "1"), (i, j + 1, "false")]
    return cands


def split_args(inner):
    out, depth, cur = [], 0, ""
    for c in inner:
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        if c == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += c
    out.append(cur.strip())
    return out


class Reducer:
    def __init__(self, prop, log=None, deadline=None):
        self.prop = prop
        self.log = log or (lambda m: None)
        self.deadline = deadline
        self.fix_scratch = prop.scratch

    def timed_out(self):
        return self.deadline is not None and time.time() > self.deadline

    def try_text(self, text, than):
        """`text` after fixing, if it is smaller than `than` and keeps
        the property."""
        t = fix(self.prop.tools, text, self.fix_scratch)
        if t is None or len(t) >= len(than):
            return None
        return t if self.prop(t) else None

    def pass_units(self, text):
        """Deletes statements, largest first, then smaller; also hoists
        block bodies."""
        changed = False
        lines = text.split("\n")
        us = sorted(units(lines), key=lambda u: -(u[1] - u[0]))
        tried = set()
        k = 0
        while k < len(us) and not self.timed_out():
            a, b = us[k]
            k += 1
            if (a, b, len(lines)) in tried:
                continue
            tried.add((a, b, len(lines)))
            cand = "\n".join(lines[:a] + lines[b:])
            t = self.try_text(cand, text)
            if t is None and b - a > 2:
                # Hoist the body of the block (the first branch).
                body = []
                d = 0
                for l in lines[a + 1:b - 1]:
                    if d == 0 and l.strip().startswith("}") and l.strip().endswith("{"):
                        break
                    body.append(l)
                    d += line_depth(l)
                t = self.try_text("\n".join(lines[:a] + body + lines[b:]), text)
            if t is not None:
                changed = True
                text = t
                lines = text.split("\n")
                us = sorted(units(lines), key=lambda u: -(u[1] - u[0]))
                k = 0
                self.log(f"  units: {len(lines)} lines, {self.prop.tests} tests")
        return text, changed

    def pass_exprs(self, text):
        changed = False
        pos = 0
        while pos < len(text) and not self.timed_out():
            # The next bracketed group at or after pos, outermost first.
            i = min((k for k in (text.find("(", pos), text.find("[", pos)) if k >= 0), default=-1)
            if i < 0:
                break
            j = matching(text, i)
            if j < 0:
                pos = i + 1
                continue
            done = False
            for s, e, rep in group_candidates(text, i, j):
                if text[s:e] == rep:
                    continue
                t = self.try_text(text[:s] + rep + text[e:], text)
                if t is not None:
                    text = t
                    changed = True
                    done = True
                    break
            if not done:
                pos = i + 1
            else:
                pos = max(0, i - 1) if i < len(text) else i
        return text, changed

    def pass_ints(self, text):
        changed = False
        for m in list(re.finditer(r"(?<![\w.])(0x[0-9a-fA-F]+|\d{2,})(?![\w.])", text))[::-1]:
            if self.timed_out():
                break
            for rep in ("0", "1"):
                cand = text[:m.start()] + rep + text[m.end():]
                t = self.try_text(cand, text)
                if t is not None:
                    text, changed = t, True
                    break
        return text, changed

    def run(self, text):
        if not self.prop(text):
            raise RuntimeError("the original program does not have the property")
        rounds = 0
        while not self.timed_out():
            rounds += 1
            before = len(text)
            text, c1 = self.pass_units(text)
            text, c2 = self.pass_exprs(text)
            if not (c1 or c2):
                text, c3 = self.pass_ints(text)
                if not c3:
                    break
            self.log(f"round {rounds}: {before} -> {len(text)} bytes, {self.prop.tests} tests")
        return text


def property_for(meta, tools):
    bad = "bs" if "bs" in meta["bad"] else meta["bad"][0]
    oc = meta["outcomes"]
    up = H.Outcome(**{k: oc["zig"][k] for k in ("status", "lines", "code", "detail")})
    b = H.Outcome(**{k: oc[bad][k] for k in ("status", "lines", "code", "detail")})
    control = None
    for c in ("bs-noinline", "bs-inline-safe", "bs-safe", "bs"):
        if c in oc and c not in meta["bad"] and c != bad:
            control = c
            break
    cls = meta["class"]
    base = None
    if cls.startswith("branch-"):
        cls = cls[len("branch-"):]
        base = H.Tools(meta["base_bs"], tools.zig)
    return Property(tools, bad, norm_kind(up), norm_kind(b), control, cls, first_error(b.detail) if not b.compiled() else "", base)


def reduce_finding(d, bs=None, zig=None, minutes=90):
    """Reduces the finding in directory `d`; writes reduced.zig,
    reduced.json and report.md there."""
    tools = H.Tools(bs, zig)
    meta = json.load(open(os.path.join(d, "meta.json")))
    if meta.get("ref_env"):
        H.set_ref_env(meta["ref_env"])
    t = meta.get("target") or {"flags": [], "runner": []}
    H.set_target(t["flags"], t["runner"])
    if meta.get("oracle"):
        H.set_oracle(meta["oracle"])
    prop = property_for(meta, tools)
    logf = open(os.path.join(d, "reduce.log"), "a")

    def log(m):
        logf.write(time.strftime("%H:%M:%S ") + m + "\n")
        logf.flush()

    text = open(os.path.join(d, "orig.zig")).read()
    log(f"reducing with {prop.bad.name} (control {prop.control.name if prop.control else '-'}), "
        f"upstream {prop.up_kind!r}, bs {prop.bad_kind!r}")
    try:
        r = Reducer(prop, log, time.time() + minutes * 60)
        out = r.run(text)
    finally:
        prop.close()
    with open(os.path.join(d, "reduced.zig"), "w") as f:
        f.write(out)
    summary = describe(d, out, tools, meta)
    log(f"done: {len(text.splitlines())} -> {len(out.splitlines())} lines, {prop.tests} tests")
    return f"{d}: {len(out.splitlines())} lines; {summary}"


def describe(d, text, tools, meta):
    """Runs the reduced program under every configuration; writes
    reduced.json and report.md."""
    scratch = H.new_scratch()
    try:
        src = os.path.join(scratch, "repro.zig")
        with open(src, "w") as f:
            f.write(text)
        res = {c.name: H.run_config(tools, c, src, scratch) for c in H.REPORT + H.ALWAYS + [H.BS_INLINE_SAFE]}
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    json.dump({n: o.to_json() for n, o in res.items()}, open(os.path.join(d, "reduced.json"), "w"), indent=1)
    up = res[H.ORACLE.name]
    agree = [n for n, o in res.items() if o.key() == up.key()]
    differ = [n for n, o in res.items() if o.key() != up.key()]
    rep = [f"# {meta['class']} (seed {meta['seed']})", "",
           f"bs {meta.get('bs_rev', '?')[:12]}; agree with {H.ORACLE.name}: {', '.join(agree)}; "
           f"differ: {', '.join(differ)}", "", "```zig", text.rstrip(), "```", ""]
    for n, o in res.items():
        rep += [f"## {n}", "```", o.text(), "```", ""]
    open(os.path.join(d, "report.md"), "w").write("\n".join(rep))
    return f"differ: {', '.join(differ)}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target", help="a finding directory, or a .zig file (with --bad)")
    ap.add_argument("--bad", help="for a .zig file: the failing configuration (bs, bs-safe, bs-noinline, ...)")
    ap.add_argument("--control", help="for a .zig file: a configuration that must keep agreeing with upstream")
    ap.add_argument("--bs")
    ap.add_argument("--zig")
    ap.add_argument("--minutes", type=float, default=90)
    ap.add_argument("--target", dest="triple", help="for a .zig file: the -target every configuration compiles for")
    ap.add_argument("--mcpu", help="for a .zig file: the -mcpu every configuration compiles for")
    args = ap.parse_args()
    H.set_target(*H.target_for(args.triple, args.mcpu))
    if os.path.isdir(args.target):
        print(reduce_finding(args.target, args.bs, args.zig, args.minutes))
        return
    tools = H.Tools(args.bs, args.zig)
    text = open(args.target).read()
    scratch = H.new_scratch()
    src = os.path.join(scratch, "p.zig")
    open(src, "w").write(text)
    up = H.run_config(tools, H.ORACLE, src, scratch)
    b = H.run_config(tools, H.BY_NAME[args.bad or "bs"], src, scratch)
    shutil.rmtree(scratch, ignore_errors=True)
    cls = "miscompile" if b.compiled() else ("bs-crash" if b.status == "compile-crash" else "bs-reject")
    prop = Property(tools, args.bad or "bs", norm_kind(up), norm_kind(b), args.control, cls,
                    first_error(b.detail) if not b.compiled() else "")
    try:
        out = Reducer(prop, lambda m: print(m, file=sys.stderr), time.time() + args.minutes * 60).run(text)
    finally:
        prop.close()
    sys.stdout.write(out)


if __name__ == "__main__":
    main()
