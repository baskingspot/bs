#!/usr/bin/env python3
"""Edit-sequence hunter for bs's cache (see README.md).

Applies random sequences of edits to a real project and builds after
each one with the same cache, as an editing session does. Every step's
edit build (BS_CACHE_CHECK=1) must give the bytes of a full build of the
same sources checked node by node against it (BS_CACHE_VERIFY=full, in a
copy of the cache), and the outcome of a build without the cache
(BS_CACHE=off): the same compile errors, or a binary that behaves the
same. The first difference stops the sequence, saved for replay and
reduction.

    python3 tools/edithunt/hunt.py libvaxis/test           # hunt until ^C
    python3 tools/edithunt/hunt.py zig --sequences 3       # the zig compiler
    python3 tools/edithunt/hunt.py zls/test --target aarch64-linux
    python3 tools/edithunt/hunt.py --replay tools/edithunt/.work/found/<dir>
    python3 tools/edithunt/hunt.py --reduce tools/edithunt/.work/found/<dir>
"""

import argparse
import difflib
import filecmp
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(os.path.dirname(TOOL_DIR))
WORK = os.path.join(TOOL_DIR, ".work")
FOUND = os.path.join(WORK, "found")
UPSTREAM = os.path.join(REPO_DIR, "upstream")
sys.path.insert(0, os.path.join(REPO_DIR, "tools", "corpus"))
import run as corpus  # noqa: E402

BUILD_TIMEOUT = 1800
RUN_TIMEOUT = 300
# Builds that reproduce a finding before it counts (a race shows in some).
ERROR_RE = re.compile(r"^(\S.*?):(\d+):(\d+): error(?:\[[^\]]*\])?: (.*)$", re.M)


def log(msg):
    print(time.strftime("%H:%M:%S ") + msg, file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# Projects: a source tree to copy, a command line, how to run the output


class Project:
    """`name`: `zig` (the zig compiler workload: upstream's src/ with
    bench/workloads/zig's build options), `hello`, or a corpus target
    `<project>/<target>` (tools/corpus/manifest.json, recorded by
    tools/corpus/run.py)."""

    def __init__(self, name, bs, target):
        self.name, self.bs, self.target = name, bs, target
        self.run_args, self.is_test = [], False
        if name == "zig":
            self.src = os.path.join(UPSTREAM, "src")
            self.copy_to = "src"
            self.extra = {"build_options.zig": os.path.join(REPO_DIR, "bench", "workloads", "zig", "build_options.zig")}
            self.args = ["build-exe", "--stack", "48234496", "-fno-sanitize-thread", "--dep", "build_options",
                         "-Mroot=src/main.zig", "-Mbuild_options=build_options.zig", "--name", "zig"]
            self.run_args = ["version"]
        elif name == "hello":
            self.src = os.path.join(REPO_DIR, "bench", "workloads", "hello")
            self.copy_to, self.extra = "", {}
            self.args = ["build-exe", "hello.zig"]
        else:
            proj_name, tgt_name = name.split("/", 1)
            manifest = json.load(open(os.path.join(REPO_DIR, "tools", "corpus", "manifest.json")))
            proj = next(p for p in manifest["projects"] if p["name"] == proj_name)
            tgt = next(t for t in proj["targets"] if t["name"] == tgt_name)
            src, cmds = corpus.setup(proj, shutil.which("zig"), False)
            words = cmds[tgt_name]
            self.src, self.copy_to, self.extra = src, "", {}
            # Translated C headers go to a directory of their own, outside
            # the caches the hunt empties.
            tdir = os.path.join(WORK, "translated", name.replace("/", "_"))
            os.makedirs(tdir, exist_ok=True)
            words, err = corpus.translate(bs, words, cmds, tdir, src)
            if words is None:
                sys.exit(f"translate-c failed: {err}")
            argv = corpus.compile_argv(bs, words, "unused", "unused")
            self.args = strip_cache_args(argv[1:])
            self.is_test = words[1] == "test"
            self.run_args = [corpus.expand(a, proj) for a in tgt.get("run", [])]
        if target:
            self.args += ["-target", target]

    def materialize(self, dest):
        """A fresh copy of the sources in `dest`; returns the directory
        builds run from."""
        shutil.rmtree(dest, ignore_errors=True)
        root = dest
        shutil.copytree(self.src, os.path.join(dest, self.copy_to) if self.copy_to else dest, symlinks=True,
                        ignore=shutil.ignore_patterns(".git", ".zig-cache", "zig-out"))
        for rel, path in self.extra.items():
            shutil.copy(path, os.path.join(dest, rel))
        return root

    def roots(self, tree):
        """The module roots: (name, path relative to `tree`)."""
        res = []
        for i, a in enumerate(self.args):
            m = re.match(r"-M([^=]+)=(.*)$", a)
            if m:
                res.append((m.group(1), m.group(2)))
            elif a.endswith(".zig") and not a.startswith("-") and (i == 0 or not self.args[i - 1].startswith("-")):
                res.append(("root", a))
        return [(n, p) for n, p in res if not os.path.isabs(p) or p.startswith(tree)]


def strip_cache_args(args):
    res, skip = [], False
    for a in args:
        if skip:
            skip = False
        elif a in ("--cache-dir", "--global-cache-dir"):
            skip = True
        elif not a.startswith("-femit-bin="):
            res.append(a)
    return res


def reachable(project, tree):
    """The .zig files of `tree` the build can import: from the module
    roots, through `@import` of paths and module names."""
    modules = {}
    for name, path in project.roots(tree):
        modules[name] = os.path.normpath(os.path.join(tree, path))
    seen, todo = set(), list(modules.values())
    while todo:
        f = todo.pop()
        if f in seen or not f.startswith(tree + os.sep) or not os.path.isfile(f):
            continue
        seen.add(f)
        try:
            text = open(f, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
        for imp in re.findall(r'@import\("([^"]+)"\)', text):
            if imp.endswith(".zig"):
                todo.append(os.path.normpath(os.path.join(os.path.dirname(f), imp)))
            elif imp in modules:
                todo.append(modules[imp])
    return sorted(os.path.relpath(f, tree) for f in seen)


# ---------------------------------------------------------------------------
# Edits. Each returns a list of operations, applied in order:
#   {"path", "start", "end", "text"}: replace bytes [start, end) with text
#   {"path", "touch": true}: set the mtime to now


class Scanner:
    def __init__(self):
        self.exe = os.path.join(WORK, "scan")
        src = os.path.join(TOOL_DIR, "scan.zig")
        if not os.path.exists(self.exe) or os.path.getmtime(self.exe) < os.path.getmtime(src):
            os.makedirs(WORK, exist_ok=True)
            subprocess.run([shutil.which("zig"), "build-exe", src, f"-femit-bin={self.exe}",
                            "--cache-dir", os.path.join(WORK, "zig-cache")], check=True)

    def scan(self, path):
        p = subprocess.run([self.exe, "scan", path], capture_output=True, check=False)
        if p.returncode != 0:
            return None
        return json.loads(p.stdout)

    def rename(self, path, old, new):
        p = subprocess.run([self.exe, "rename", path, old, new], capture_output=True, check=False)
        return p.stdout if p.returncode == 0 else None


def line_starts(data):
    return [0] + [m.end() for m in re.finditer(rb"\n", data)]


def indent_at(data, off):
    """The indentation of the line holding `off`, plus one level."""
    ls = data.rfind(b"\n", 0, off) + 1
    m = re.match(rb"[ \t]*", data[ls:])
    return m.group(0).decode() + "    "


class Editor:
    """Makes one random edit to the tree, `kind` drawn by weight."""

    KINDS = {
        # Semantic edits.
        "int": 6, "string": 3, "bool": 2, "field_add": 3, "field_remove": 2, "fn_add": 4, "fn_remove": 2,
        "param_type": 2, "flag_add": 2, "flag_flip": 3, "error_add": 2, "error_remove": 1, "generic": 3,
        "rename": 2, "move": 2, "const_int": 3, "inline": 2, "pub": 1,
        # No-ops for the program: they move lines, or nothing.
        "blank_line": 3, "comment": 2, "touch": 2,
        # A compile error, fixed by a later step.
        "break": 3,
    }

    def __init__(self, rng, tree, files, scanner, seq_id):
        self.rng, self.tree, self.files, self.scanner = rng, tree, files, scanner
        self.n = 0
        self.tag = seq_id
        # The functions of the last binary, by their declarations' names.
        self.live = set()

    def name(self):
        self.n += 1
        return f"{self.tag}_{self.n}"

    def read(self, rel):
        with open(os.path.join(self.tree, rel), "rb") as f:
            return f.read()

    def pick_file(self, pred=None, tries=20):
        for _ in range(tries):
            rel = self.choose_file()
            info = self.scanner.scan(os.path.join(self.tree, rel))
            if info is None or info["parse_errors"]:
                continue
            if pred is None or pred(info):
                return rel, info
        return None, None

    def choose_file(self):
        """A reachable file, the project's own three times in four, not
        its packages' (zig-pkg)."""
        own = [f for f in self.files if not f.startswith("zig-pkg")]
        return self.rng.choice(own if own and self.rng.random() < 0.75 else self.files)

    def edit(self):
        kinds = list(self.KINDS)
        weights = [self.KINDS[k] for k in kinds]
        for _ in range(50):
            kind = self.rng.choices(kinds, weights)[0]
            r = getattr(self, "e_" + kind)()
            if r:
                ops, what = r
                return kind, ops, what
        return None

    # Literals in function bodies.
    def _literal(self, kind, generic=None):
        rel, info = self.pick_file(lambda i: any(l["kind"] == kind and l["body"] is not None and
                                                 (generic is None or l["generic"] == generic) for l in i["literals"]))
        if not rel:
            return None
        lits = [l for l in info["literals"] if l["kind"] == kind and l["body"] is not None and (generic is None or l["generic"] == generic)]
        return rel, self.rng.choice(self._live(lits, lambda l: l["body"]))

    def e_int(self, generic=None):
        r = self._literal("int", generic)
        if not r:
            return None
        rel, lit = r
        text = self.read(rel)[lit["start"]:lit["end"]].decode()
        try:
            v = int(text.replace("_", ""), 0)
        except ValueError:
            return None
        nv = v + 1 if v < 1 << 30 else v - 1
        new = hex(nv) if text.lower().startswith("0x") else str(nv)
        return [op(rel, lit["start"], lit["end"], new)], f"{rel}: integer {text} -> {new} in {lit['body']}"

    def e_const_int(self):
        """An integer outside function bodies: a constant, a default, an
        array length."""
        rel, info = self.pick_file(lambda i: any(l["kind"] == "int" and l["body"] is None for l in i["literals"]))
        if not rel:
            return None
        lit = self.rng.choice([l for l in info["literals"] if l["kind"] == "int" and l["body"] is None])
        text = self.read(rel)[lit["start"]:lit["end"]].decode()
        try:
            v = int(text.replace("_", ""), 0)
        except ValueError:
            return None
        nv = v + 1 if v < 1 << 30 else v - 1
        new = hex(nv) if text.lower().startswith("0x") else str(nv)
        return [op(rel, lit["start"], lit["end"], new)], f"{rel}: integer {text} -> {new} outside function bodies"

    def _decl_head(self, rel, info, pred):
        """A declaration and the match of its head: doc comments, `pub`,
        `inline`, and `fn` or `const` or `var`."""
        decls = [d for c in info["containers"] for d in c["decls"] if not d["extern"] and pred(d)]
        if not decls:
            return None
        d = self.rng.choice(decls)
        data = self.read(rel)
        m = re.match(rb"((?:[ \t]*///[^\n]*\n)*[ \t]*)(pub\s+)?(inline\s+|noinline\s+)?(fn|const|var)\b", data[d["start"]:d["end"]])
        return (d, m) if m else None

    def e_inline(self):
        """A function becomes inline, or stops being inline."""
        rel, info = self.pick_file()
        if not rel:
            return None
        r = self._decl_head(rel, info, lambda d: d["kind"] == "fn" and not d["generic"])
        if not r or r[1].group(4) != b"fn" or (r[1].group(3) or b"").startswith(b"noinline"):
            return None
        d, m = r
        if m.group(3):
            at = d["start"] + m.start(3)
            return [op(rel, at, d["start"] + m.end(3), "")], f"{rel}: {d['name']} stops being inline"
        at = d["start"] + m.start(4)
        return [op(rel, at, at, "inline ")], f"{rel}: {d['name']} becomes inline"

    def e_pub(self):
        """A declaration becomes pub, or stops being pub."""
        rel, info = self.pick_file()
        if not rel:
            return None
        r = self._decl_head(rel, info, lambda d: True)
        if not r:
            return None
        d, m = r
        if m.group(2):
            return [op(rel, d["start"] + m.start(2), d["start"] + m.end(2), "")], f"{rel}: {d['name']} stops being pub"
        at = d["start"] + m.end(1)
        return [op(rel, at, at, "pub ")], f"{rel}: {d['name']} becomes pub"

    def e_string(self):
        r = self._literal("string")
        if not r:
            return None
        rel, lit = r
        at = lit["end"] - 1
        return [op(rel, at, at, "eh")], f"{rel}: string literal in {lit['body']} gains 'eh'"

    def e_bool(self):
        rel, info = self.pick_file(lambda i: bool(self._bools(i)))
        if not rel:
            return None
        start, end, where = self.rng.choice(self._bools(info))
        old = self.read(rel)[start:end].decode()
        new = "false" if old == "true" else "true"
        return [op(rel, start, end, new)], f"{rel}: {old} -> {new} in {where}"

    def _bools(self, info):
        res = [(l["start"], l["end"], l["body"]) for l in info["literals"] if l["kind"] == "bool" and l["body"]]
        return res

    def e_field_add(self):
        def ok(c):
            return c["kind"] in ("struct", "union", "enum") and (not c["root"] or c["fields"])
        rel, info = self.pick_file(lambda i: any(ok(c) for c in i["containers"]))
        if not rel:
            return None
        c = self.rng.choice([c for c in info["containers"] if ok(c)])
        n = self.name()
        if c["kind"] == "enum":
            member = f"bs_eh_f{n},"
        elif c["kind"] == "union":
            member = f"bs_eh_f{n}: u32,"
        else:
            member = f"bs_eh_f{n}: u32 = {self.rng.randrange(100)},"
        data = self.read(rel)
        at = c["fields"][-1]["end"] if c["root"] else c["open"]
        return [op(rel, at, at, "\n" + indent_at(data, at)[4 if c["root"] else 0:] + member)], \
            f"{rel}: {c['kind']} gains field bs_eh_f{n}"

    def e_field_remove(self):
        # Fields this hunt added, else any field.
        for rel in self.rng.sample(self.files, min(len(self.files), 20)):
            data = self.read(rel)
            ms = list(re.finditer(rb"\n[ \t]*bs_eh_f[0-9_]+(: u32( = \d+)?)?,", data))
            if ms:
                m = self.rng.choice(ms)
                return [op(rel, m.start(), m.end(), "")], f"{rel}: field {m.group(0).strip().decode()} removed"
        if self.rng.random() < 0.5:
            return None
        rel, info = self.pick_file(lambda i: any(c["fields"] for c in i["containers"]))
        if not rel:
            return None
        c = self.rng.choice([c for c in info["containers"] if c["fields"]])
        f = self.rng.choice(c["fields"])
        return [op(rel, f["start"], f["end"], "")], f"{rel}: field {f['name']} removed"

    def _bodies(self, info, generic=False):
        res = [b for b in info["bodies"] if b["generic"] == generic and b["name"]]
        return self._live(res, lambda b: b["name"])

    def _live(self, items, name):
        """`items`, those whose function the last binary holds four times
        in five: an edit elsewhere is often never analyzed."""
        live = [x for x in items if name(x) in self.live]
        return live if live and self.rng.random() < 0.8 else items

    def _insert_stmt(self, rel, info, stmt, generic=False):
        """Inserts a statement at the start of a function body."""
        bodies = self._bodies(info, generic)
        if not bodies:
            return None
        b = self.rng.choice(bodies)
        data = self.read(rel)
        at = b["start"] + 1
        return op(rel, at, at, "\n" + indent_at(data, b["start"]) + stmt), b["name"]

    def e_fn_add(self):
        rel, info = self.pick_file(lambda i: bool(self._bodies(i)))
        if not rel:
            return None
        n = self.name()
        k1, k2 = self.rng.randrange(1000), self.rng.randrange(1000)
        call, where = self._insert_stmt(rel, info, f"_ = bsEh{n}({k1});")
        end = len(self.read(rel))
        fn = f"\nfn bsEh{n}(x: u32) u32 {{\n    return @truncate(x +% {k2});\n}}\n"
        # The call's insertion is before the end of the file.
        return [op(rel, end, end, fn), call], f"{rel}: adds fn bsEh{n}, called from {where}"

    def e_fn_remove(self):
        for rel in self.rng.sample(self.files, min(len(self.files), 30)):
            data = self.read(rel)
            defs = list(re.finditer(rb"\nfn (bsEh[0-9_]+)\(x: u\d+\) u32 \{\n    return @truncate\(x \+% \d+\);\n\}\n", data))
            if defs:
                d = self.rng.choice(defs)
                name = d.group(1)
                ops = [op(rel, d.start(), d.end(), "")]
                calls = list(re.finditer(rb"\n[ \t]*_ = " + name + rb"\(\d+\);", data))
                for c in calls:
                    ops.append(op(rel, c.start(), c.end(), ""))
                # Each operation's offsets hold before the ones after it.
                ops.sort(key=lambda o: -o["start"])
                return ops, f"{rel}: removes fn {name.decode()} and its {len(calls)} call(s)"
        return None

    def e_param_type(self):
        widths = {"u8": "u16", "u16": "u32", "u32": "u64", "u64": "u32", "i32": "i64", "i64": "i32", "usize": "u64", "isize": "i64"}
        # This hunt's functions first: their bodies take any width.
        for rel in self.rng.sample(self.files, min(len(self.files), 30)):
            data = self.read(rel)
            ms = list(re.finditer(rb"\nfn bsEh[0-9_]+\(x: (u\d+)\)", data))
            if ms:
                m = self.rng.choice(ms)
                old = m.group(1).decode()
                new = "u64" if old == "u32" else "u32"
                return [op(rel, m.start(1), m.end(1), new)], f"{rel}: parameter of {m.group(0)[4:-6].decode()} {old} -> {new}"
        rel, info = self.pick_file()
        if not rel:
            return None
        data = self.read(rel)
        cands = []
        for c in info["containers"]:
            for d in c["decls"]:
                for p in d.get("params", []):
                    t = data[p["type_start"]:p["type_end"]].decode()
                    if t in widths:
                        cands.append((d["name"], p, t))
        if not cands:
            return None
        name, p, t = self.rng.choice(cands)
        return [op(rel, p["type_start"], p["type_end"], widths[t])], f"{rel}: parameter of {name} {t} -> {widths[t]}"

    def e_flag_add(self):
        rel, info = self.pick_file(lambda i: bool(self._bodies(i)) and any(
            d["name"] == "std" for d in i["containers"][0]["decls"]))
        if not rel:
            return None
        n = self.name()
        k1, k2 = self.rng.randrange(1000), self.rng.randrange(1000)
        stmt = (f"if (bs_eh_flag{n}) std.mem.doNotOptimizeAway(@as(u32, {k1})) "
                f"else std.mem.doNotOptimizeAway(@as(u64, {k2}));")
        ins, where = self._insert_stmt(rel, info, stmt)
        end = len(self.read(rel))
        return [op(rel, end, end, f"\nconst bs_eh_flag{n} = {self.rng.choice(['true', 'false'])};\n"), ins], \
            f"{rel}: adds flag bs_eh_flag{n}, which selects code in {where}"

    def e_flag_flip(self):
        for rel in self.rng.sample(self.files, min(len(self.files), 30)):
            data = self.read(rel)
            ms = list(re.finditer(rb"\nconst bs_eh_flag[0-9_]+ = (true|false);", data))
            if ms:
                m = self.rng.choice(ms)
                old = m.group(1)
                new = b"false" if old == b"true" else b"true"
                return [op(rel, m.start(1), m.end(1), new.decode())], f"{rel}: flips {m.group(0).strip().decode()}"
        # A container-level `const x = true;` of the project's own.
        rel, info = self.pick_file(lambda i: bool(self._flags(i)))
        if not rel:
            return None
        d = self.rng.choice(self._flags(info))
        data = self.read(rel)
        seg = data[d["start"]:d["end"]]
        m = re.search(rb"=\s*(true|false)\s*;", seg)
        if not m:
            return None
        new = "false" if m.group(1) == b"true" else "true"
        return [op(rel, d["start"] + m.start(1), d["start"] + m.end(1), new)], f"{rel}: const {d['name']} -> {new}"

    def _flags(self, info):
        return [d for c in info["containers"] for d in c["decls"] if d.get("init") in ("true", "false")]

    def e_error_add(self):
        rel, info = self.pick_file(lambda i: bool(i["error_sets"]))
        if not rel:
            return None
        e = self.rng.choice(info["error_sets"])
        n = self.name()
        return [op(rel, e["open"], e["open"], f"BsEh{n}, ")], \
            f"{rel}: error set {{{', '.join(e['names'][:3])}{', ...' if len(e['names']) > 3 else ''}}} gains BsEh{n}"

    def e_error_remove(self):
        for rel in self.rng.sample(self.files, min(len(self.files), 30)):
            data = self.read(rel)
            ms = list(re.finditer(rb"BsEh[0-9_]+, ", data))
            if ms:
                m = self.rng.choice(ms)
                return [op(rel, m.start(), m.end(), "")], f"{rel}: error {m.group(0)[:-2].decode()} removed"
        return None

    def e_generic(self):
        if self.rng.random() < 0.5:
            return self.e_int(generic=True)
        rel, info = self.pick_file(lambda i: bool(self._bodies(i, True)))
        if not rel:
            return None
        k = self.rng.randrange(1, 1000)
        r = self._insert_stmt(rel, info, f"if (@as(u32, {k}) == 0) unreachable;", generic=True)
        return [r[0]], f"{rel}: generic {r[1]} gains a statement"

    def e_rename(self):
        rel, info = self.pick_file(lambda i: bool(self._renamable(i)))
        if not rel:
            return None
        d = self.rng.choice(self._renamable(info))
        new = f"{d['name']}_eh{self.name()}"
        data = self.scanner.rename(os.path.join(self.tree, rel), d["name"], new)
        if data is None:
            return None
        return [minimal_op(rel, self.read(rel), data)], f"{rel}: renames {d['name']} to {new}"

    def _renamable(self, info):
        return [d for d in info["containers"][0]["decls"] if not d["pub"] and not d["extern"] and d["name"] not in ("std", "builtin")
                and not d["name"].startswith("@")]

    def e_move(self):
        """Moves a top-level declaration that names no other one of its
        file but `std` and `builtin` to another file of the directory,
        importing it back under the same name."""
        rel, info = self.pick_file(lambda i: bool(self._movable(i)))
        if not rel:
            return None
        d = self.rng.choice(self._movable(info))
        siblings = [f for f in self.files if f != rel and os.path.dirname(f) == os.path.dirname(rel)]
        self.rng.shuffle(siblings)
        for dest in siblings[:5]:
            dinfo = self.scanner.scan(os.path.join(self.tree, dest))
            if not dinfo or dinfo["parse_errors"]:
                continue
            names = {x["name"] for x in dinfo["containers"][0]["decls"]}
            if d["name"] in names or not set(d["uses"]) <= names:
                continue
            data = self.read(rel)
            text = data[d["start"]:d["end"]].decode()
            lines = text.split("\n")
            i = next(i for i, l in enumerate(lines) if not l.lstrip().startswith("///"))
            lines[i] = "pub " + lines[i]
            end = len(self.read(dest))
            imp = f'const {d["name"]} = @import("{os.path.basename(dest)}").{d["name"]};'
            return [op(rel, d["start"], d["end"], imp), op(dest, end, end, "\n" + "\n".join(lines) + "\n")], \
                f"{rel}: moves {d['name']} to {dest}"
        return None

    def _movable(self, info):
        return [d for d in self._renamable(info) if set(d["uses"]) <= {"std", "builtin"} and d["kind"] in ("fn", "const")
                and d["end"] - d["start"] < 4000]

    def e_blank_line(self):
        rel = self.choose_file()
        at = self._line_start(rel)
        return None if at is None else ([op(rel, at, at, "\n")], f"{rel}: a blank line moves the lines below")

    def e_comment(self):
        rel = self.choose_file()
        at = self._line_start(rel)
        return None if at is None else ([op(rel, at, at, f"// bs edithunt {self.name()}\n")], f"{rel}: a comment line")

    def _line_start(self, rel):
        data = self.read(rel)
        starts = line_starts(data)
        for _ in range(20):
            i = self.rng.randrange(len(starts))
            near = data[starts[max(0, i - 1)]:starts[min(len(starts) - 1, i + 1)]]
            # Not inside or next to a multiline string literal.
            if b"\\\\" not in near:
                return starts[i]
        return None

    def e_touch(self):
        rel = self.choose_file()
        return [{"path": rel, "touch": True}], f"{rel}: touched"

    def e_break(self):
        rel, info = self.pick_file(lambda i: bool(self._bodies(i)))
        if not rel:
            return None
        n = self.name()
        how = self.rng.randrange(3)
        if how == 0:
            # An AstGen error, reported wherever the file is reachable.
            r = self._insert_stmt(rel, info, f"const bs_eh_unused{n} = {n.split('_')[-1]};")
            return [r[0]], f"{rel}: unused local constant in {r[1]} (compile error)"
        if how == 1:
            end = len(self.read(rel))
            return [op(rel, end, end, f"\nbs_eh_syntax{n}(\n")], f"{rel}: syntax error at the end (compile error)"
        # A Sema error, if the function is analyzed.
        r = self._insert_stmt(rel, info, f'const bs_eh_t{n}: u32 = "bs"; _ = bs_eh_t{n};')
        return [r[0]], f"{rel}: type mismatch in {r[1]} (compile error if analyzed)"


def op(path, start, end, text):
    return {"path": path, "start": start, "end": end, "text": text}


def minimal_op(path, old, new):
    """The replacement of `old` by `new`, without their common ends."""
    a = 0
    while a < min(len(old), len(new)) and old[a] == new[a]:
        a += 1
    b = 0
    while b < min(len(old), len(new)) - a and old[-1 - b] == new[-1 - b]:
        b += 1
    return op(path, a, len(old) - b, new[a:len(new) - b].decode())


def apply_ops(tree, ops):
    """Applies `ops`; returns their inverse."""
    inverse = []
    for o in ops:
        path = os.path.join(tree, o["path"])
        if o.get("touch"):
            os.utime(path)
            continue
        with open(path, "rb") as f:
            data = f.read()
        new = o["text"].encode()
        inverse.append(op(o["path"], o["start"], o["start"] + len(new), data[o["start"]:o["end"]].decode()))
        with open(path, "wb") as f:
            f.write(data[:o["start"]] + new + data[o["end"]:])
    return list(reversed(inverse))


# ---------------------------------------------------------------------------
# Builds


class Session:
    """A work tree and its caches. Each step's edit build continues the
    session's cache."""

    def __init__(self, project, work, bs, runner):
        self.p, self.work, self.bs, self.runner = project, work, bs, runner
        self.tree = project.materialize(os.path.join(work, "tree"))
        self.local = os.path.join(work, "local")
        self.glob = os.path.join(work, "global")
        for d in (self.local, self.glob):
            shutil.rmtree(d, ignore_errors=True)
        self.out = os.path.join(work, "out", "prog")
        os.makedirs(os.path.dirname(self.out), exist_ok=True)
        for f in os.listdir(os.path.dirname(self.out)):
            os.unlink(os.path.join(os.path.dirname(self.out), f))
        self.files = reachable(project, self.tree)
        self.last_digest = None

    def build(self, env, out, local=None):
        argv = [self.bs] + self.p.args + [f"-femit-bin={out}"]
        e = dict(os.environ, ZIG_LOCAL_CACHE_DIR=local or self.local, ZIG_GLOBAL_CACHE_DIR=self.glob, **env)
        for k in ("BS_CACHE", "BS_CACHE_VERIFY", "BS_CACHE_CHECK", "BS_CACHE_REPLAY"):
            if k not in env:
                e.pop(k, None)
        t0 = time.monotonic()
        try:
            p = subprocess.run(argv, cwd=self.tree, env=e, capture_output=True, text=True, errors="replace", timeout=BUILD_TIMEOUT)
            code, err = p.returncode, p.stderr + p.stdout
        except subprocess.TimeoutExpired as x:
            code, err = "timeout", str(x.stderr or "")
        return {"code": code, "log": err, "secs": time.monotonic() - t0}

    def run(self, path):
        argv = self.runner + [path] + self.p.run_args
        try:
            p = subprocess.run(argv, cwd=self.tree, stdin=subprocess.DEVNULL, capture_output=True, timeout=RUN_TIMEOUT)
            code = p.returncode
            out, err = p.stdout.decode(errors="replace"), p.stderr.decode(errors="replace")
        except subprocess.TimeoutExpired:
            return "timeout"
        if self.p.is_test:
            m = corpus.TEST_SUMMARY.search(err)
            return f"exit {code}, " + (m.group(1) if m else "no summary")
        # argv[0] and addresses differ between the two paths: compare the
        # exit status and stdout.
        return f"exit {code}\n{out}"

    def step(self, verify):
        """Builds the current sources three ways and compares. Returns
        (finding class or None, details, stats)."""
        env = {"BS_CACHE_CHECK": "1", "BS_CACHE_TIMING": "1"}
        if verify:
            env["BS_CACHE_VERIFY"] = "1"
        e = self.build(env, self.out)
        off_out = os.path.join(self.work, "out", "off")
        off = self.build({"BS_CACHE": "off"}, off_out)
        stats = {"edit_s": round(e["secs"], 2), "off_s": round(off["secs"], 2)}
        if internal(e["log"]) or not isinstance(e["code"], int) or e["code"] < 0 or (e["code"] != 0 and not ERROR_RE.search(e["log"])):
            return "edit-build-failed", tail(e["log"]), stats
        if internal(off["log"]) or not isinstance(off["code"], int) or off["code"] < 0 or (off["code"] != 0 and not ERROR_RE.search(off["log"])):
            return "off-build-failed", tail(off["log"]), stats
        if (e["code"] == 0) != (off["code"] == 0):
            return "outcome", f"edit build exit {e['code']}, without the cache exit {off['code']}\n--- edit\n{tail(e['log'])}\n--- off\n{tail(off['log'])}", stats
        if e["code"] != 0:
            ee, oe = errors(e["log"]), errors(off["log"])
            stats["errors"] = len(oe)
            if ee != oe:
                return "errors", "only the edit build: %s\nonly without the cache: %s" % (sorted(ee - oe)[:10], sorted(oe - ee)[:10]), stats
            return None, "compile error", stats
        # The full build, checked node by node against the edit build's
        # records, in a copy of the cache so that the session goes on
        # from the edit build. (An edit build under BS_CACHE_VERIFY did
        # that itself, and its full build replaced the records.)
        ref = self.out
        if not verify:
            scratch = os.path.join(self.work, "scratch-local")
            shutil.rmtree(scratch, ignore_errors=True)
            shutil.copytree(self.local, scratch, symlinks=True)
            kept = self.out + ".edit"
            os.replace(self.out, kept)
            try:
                f = self.build({"BS_CACHE_CHECK": "1", "BS_CACHE_VERIFY": "full"}, self.out, local=scratch)
                stats["full_s"] = round(f["secs"], 2)
                if f["code"] != 0:
                    return "verify-full", tail(f["log"]), stats
                ref = os.path.join(self.work, "out", "full")
                os.replace(self.out, ref)
                if not filecmp.cmp(kept, ref, shallow=False):
                    # A lazy edit build links the base's atoms, then the
                    # log's (docs/slop/architecture.md, determinism rule
                    # 2): the layout differs from a full build's. The
                    # atoms must not, and their records were compared.
                    lazy = self.logged()
                    stats["layout"] = lazy
                    if not lazy or symbols(kept) != symbols(ref):
                        return "bytes", describe_diff(kept, ref), stats
                    re_, rf = self.run(kept), self.run(ref)
                    stats["ran"] = True
                    if re_ != rf:
                        return "behavior", f"edit build: {re_!r}\nfull build: {rf!r}\n{describe_diff(kept, ref)}", stats
            finally:
                if os.path.exists(kept):
                    os.replace(kept, self.out)
                shutil.rmtree(scratch, ignore_errors=True)
        digest = hashlib.sha256(open(ref, "rb").read()).hexdigest()
        stats["changed"] = digest != self.last_digest
        self.last_digest = digest
        if filecmp.cmp(ref, off_out, shallow=False):
            return None, "identical", stats
        # The cache numbers error codes from its last build, a build
        # without it from scratch: bytes may differ where behavior may not.
        re_, ro = self.run(self.out), self.run(off_out)
        stats["ran"] = True
        if re_ != ro:
            return "behavior", f"edit build: {re_!r}\nwithout the cache: {ro!r}\n{describe_diff(ref, off_out)}", stats
        return None, "same behavior, other bytes: " + describe_diff(ref, off_out).split("\n")[0], stats

    def live_names(self):
        """The declaration names of the functions in the last binary."""
        try:
            out = subprocess.run(["nm", self.out], capture_output=True, text=True, check=True).stdout
        except (OSError, subprocess.CalledProcessError):
            return set()
        names = set()
        for line in out.splitlines():
            parts = line.split(maxsplit=2)
            if len(parts) == 3 and parts[1] in "tT":
                name = re.sub(r"\(.*\)", "", parts[2]).split("__func_")[0]
                names.add(name.rsplit(".", 1)[-1])
        return names

    def logged(self):
        """Whether the session's records end in a log since their base: a
        lazy edit build's, laid out base first."""
        c = os.path.join(self.local, "bs", "c")
        return any(os.path.getsize(os.path.join(c, d, "manifest.log")) > 0 for d in os.listdir(c)
                   if os.path.exists(os.path.join(c, d, "manifest.log")))


def internal(log):
    return any(s in log for s in ("panic:", "error: BS_CACHE", "BS_CACHE_CHECK found", "Segmentation fault", "unable to use the cache",
                                  "the cache did not record", "error: out of memory", "warning: cache"))


def errors(log):
    return {(m.group(1), m.group(2), m.group(3), m.group(4)) for m in ERROR_RE.finditer(log)}


def tail(s, n=4000):
    return s[-n:]


def describe_diff(a, b):
    x, y = open(a, "rb").read(), open(b, "rb").read()
    at = next((i for i, (p, q) in enumerate(zip(x, y)) if p != q), min(len(x), len(y)))
    res = f"first difference at byte {at} ({len(x)} vs {len(y)} bytes)"
    try:
        sa, sb = symbols(a), symbols(b)
        differ = [f"  {n}: {sa.get(n)} vs {sb.get(n)}" for n in sorted(set(sa) | set(sb)) if sa.get(n) != sb.get(n)]
        if differ:
            res += f"\nsymbols whose size differs ({len(differ)}):\n" + "\n".join(differ[:15])
    except (OSError, subprocess.CalledProcessError):
        pass
    return res


def symbols(path):
    out = subprocess.run(["nm", "-S", path], capture_output=True, text=True, check=True).stdout
    res = {}
    for line in out.splitlines():
        parts = line.split(maxsplit=3)
        if len(parts) == 4:
            res[parts[3]] = int(parts[1], 16)
    return res


# ---------------------------------------------------------------------------
# Sequences


def runner_for(target):
    if target and target.startswith("aarch64-linux"):
        return [shutil.which("qemu-aarch64-static") or shutil.which("qemu-aarch64")]
    return []


def hunt_one(project, args, seed, counts):
    rng = random.Random(seed)
    work = os.path.join(WORK, "run", f"{project.name.replace('/', '_')}{'-' + args.target if args.target else ''}")
    s = Session(project, work, args.bs, runner_for(args.target))
    editor = Editor(rng, s.tree, s.files, Scanner(), f"s{seed}")
    n_steps = rng.randint(args.min_steps, args.max_steps)
    log(f"sequence {seed}: {n_steps} steps over {len(s.files)} reachable files")
    seq = {"project": project.name, "target": args.target, "seed": seed, "steps": []}
    # Step 0: the first build of the pristine sources.
    cls, det, st = s.step(verify=False)
    log(f"  step 0 (first build): {det} {st}")
    if cls:
        return save(seq, cls, det, s, counts)
    editor.live = s.live_names()
    broken = []  # inverses of steps that broke the build, newest last
    was_broken = False
    for i in range(1, n_steps + 1):
        avoid = {o["path"] for inv, _ in broken for o in inv}
        free = [f for f in s.files if f not in avoid]
        if broken and (rng.random() < 0.6 or len(broken) > 2 or not free):
            inv, what = broken.pop()
            kind, ops = "fix", inv
            what = "fixes: " + what
        else:
            # Away from the files a broken step changed, so that its
            # inverse still applies when it is fixed.
            editor.files = free
            r = editor.edit()
            if not r:
                continue
            kind, ops, what = r
        inverse = apply_ops(s.tree, ops)
        verify = args.verify_every > 0 and i % args.verify_every == 0
        cls, det, st = s.step(verify)
        seq["steps"].append({"kind": kind, "what": what, "ops": ops, "verify": verify})
        counts[kind] = counts.get(kind, 0) + 1
        broke = det == "compile error"
        if broke:
            counts["compile_error_steps"] = counts.get("compile_error_steps", 0) + 1
            # This step broke the build: a later step fixes it.
            if kind != "fix" and not was_broken:
                broken.append((inverse, what))
        was_broken = broke
        if not broke and st.get("changed"):
            editor.live = s.live_names()
        if det.startswith("same behavior"):
            counts["bytes_off_only"] = counts.get("bytes_off_only", 0) + 1
        counts["steps"] = counts.get("steps", 0) + 1
        if st.get("changed"):
            counts["program_changed"] = counts.get("program_changed", 0) + 1
        log(f"  step {i} {kind}: {what} -> {det.splitlines()[0][:100]} {st}")
        if cls:
            return save(seq, cls, det, s, counts)
    counts["sequences_clean"] = counts.get("sequences_clean", 0) + 1
    return None


def save(seq, cls, det, s, counts):
    counts["findings"] = counts.get("findings", 0) + 1
    d = os.path.join(FOUND, f"{cls}-{seq['project'].replace('/', '_')}-{seq['seed']}-{time.strftime('%m%d%H%M%S')}")
    os.makedirs(d)
    seq["class"], seq["details"] = cls, det
    with open(os.path.join(d, "sequence.json"), "w") as f:
        json.dump(seq, f, indent=1)
    with open(os.path.join(d, "steps.txt"), "w") as f:
        for i, st in enumerate(seq["steps"], 1):
            f.write(f"{i}: {st['kind']}: {st['what']}{' (verify)' if st['verify'] else ''}\n")
    log(f"FOUND {cls} at step {len(seq['steps'])}: {d}\n{det[:3000]}")
    return d


def replay(seq, args, builds=None, quiet=False):
    """Builds the sequence again from fresh caches: after step 0 and each
    step in `builds` (all by default; the last step always). Returns the
    finding class at the last step, or None."""
    project = Project(seq["project"], args.bs, seq.get("target"))
    work = os.path.join(WORK, "replay")
    s = Session(project, work, args.bs, runner_for(seq.get("target")))
    last = len(seq["steps"])
    cls, det, st = s.step(verify=False)
    if cls:
        if not quiet:
            log(f"step 0: {cls}\n{det}")
        return cls, 0, det
    for i, step in enumerate(seq["steps"], 1):
        apply_ops(s.tree, step["ops"])
        if builds is not None and i not in builds and i != last:
            continue
        cls, det, st = s.step(step["verify"] and builds is None)
        if not quiet:
            log(f"step {i} {step['kind']}: {step['what']} -> {det.splitlines()[0][:100]} {st}")
        if cls:
            if not quiet:
                log(f"{cls} at step {i}\n{det[:3000]}")
            return cls, i, det
    return None, last, ""


def reduce(seq_dir, args):
    """Keeps the fewest intermediate builds that still give the finding at
    the last step (ddmin): each build left out folds its edits into the
    next one built."""
    seq = json.load(open(os.path.join(seq_dir, "sequence.json")))
    want = seq["class"]
    last = len(seq["steps"])
    keep = list(range(1, last))

    def fails(builds):
        cls, at, _ = replay(seq, args, set(builds), quiet=True)
        log(f"  {len(builds)} intermediate builds: {cls or 'clean'}" + (f" at step {at}" if cls and at != last else ""))
        return cls == want and at == last

    if not fails(keep):
        log("does not reproduce with every step built")
        return
    n = 2
    while len(keep) >= 1:
        chunk = max(1, len(keep) // n)
        reduced = False
        for i in range(0, len(keep), chunk):
            cand = keep[:i] + keep[i + chunk:]
            if fails(cand):
                keep, n, reduced = cand, max(n - 1, 2), True
                break
        if not reduced:
            if chunk == 1:
                break
            n = min(len(keep), n * 2)
    out = dict(seq, builds=keep)
    with open(os.path.join(seq_dir, "reduced.json"), "w") as f:
        json.dump(out, f, indent=1)
    # What each build after the first changed, as diffs.
    project = Project(seq["project"], args.bs, seq.get("target"))
    tree = project.materialize(os.path.join(WORK, "reduce-tree"))
    snap = {}
    lines = [f"builds: step 0, then steps {keep + [last]}\n"]
    for i, step in enumerate(seq["steps"], 1):
        for o in step["ops"]:
            if o["path"] not in snap:
                snap[o["path"]] = open(os.path.join(tree, o["path"]), encoding="utf-8", errors="replace").read()
        apply_ops(tree, step["ops"])
        if i in keep or i == last:
            lines.append(f"=== build after step {i}\n")
            for path, old in sorted(snap.items()):
                new = open(os.path.join(tree, path), encoding="utf-8", errors="replace").read()
                lines += difflib.unified_diff(old.splitlines(True), new.splitlines(True), "a/" + path, "b/" + path, n=2)
                snap[path] = new
    with open(os.path.join(seq_dir, "reduced.diff"), "w") as f:
        f.writelines(lines)
    log(f"reduced to {len(keep)} intermediate builds: {seq_dir}/reduced.json, reduced.diff")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("project", nargs="?", help="zig, hello, or a corpus target <project>/<target> (libvaxis/test, zls/test)")
    ap.add_argument("--bs", default=os.path.join(REPO_DIR, "zig-out", "bin", "bs"))
    ap.add_argument("--target", help="for example aarch64-linux (binaries run under qemu)")
    ap.add_argument("--sequences", type=int, default=0, help="stop after this many sequences (default: until ^C)")
    ap.add_argument("--seed", type=int, help="the first sequence's seed (default: from the clock)")
    ap.add_argument("--min-steps", type=int, default=20)
    ap.add_argument("--max-steps", type=int, default=50)
    ap.add_argument("--verify-every", type=int, default=0,
                    help="every Nth step's edit build also runs under BS_CACHE_VERIFY=1, whose full build then replaces "
                         "the session's records (default 0: never; each step's full build runs in a copy instead)")
    ap.add_argument("--keep-going", action="store_true", help="start the next sequence after a finding")
    ap.add_argument("--replay", metavar="DIR")
    ap.add_argument("--reduce", metavar="DIR")
    args = ap.parse_args()
    args.bs = os.path.abspath(args.bs)
    if args.replay:
        seq = json.load(open(os.path.join(args.replay, "sequence.json")))
        cls, at, _ = replay(seq, args)
        log(f"replay: {cls or 'clean'} at step {at}")
        sys.exit(1 if cls else 0)
    if args.reduce:
        reduce(args.reduce, args)
        return
    if not args.project:
        ap.error("a project is needed")
    project = Project(args.project, args.bs, args.target)
    counts = {}
    seed = args.seed if args.seed is not None else int(time.time()) % 100000
    done = 0
    t0 = time.monotonic()
    try:
        while not args.sequences or done < args.sequences:
            found = hunt_one(project, args, seed, counts)
            done += 1
            seed += 1
            if found and not args.keep_going:
                break
    finally:
        counts["sequences"] = done
        counts["hours"] = round((time.monotonic() - t0) / 3600, 2)
        log("counts: " + json.dumps(counts, sort_keys=True))


if __name__ == "__main__":
    main()
