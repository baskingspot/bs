#!/usr/bin/env python3
"""Lists std's public declarations that older releases had and 0.17 lacks,
to seed the migration table in src/diag.zig (see "Diagnostics" in
docs/slop/architecture.md).

Usage: std_removed.py OLD_LIB_STD... NEW_LIB_STD

Each argument is a release's lib/std directory, for example
zig-0.11.0/lib/std ... upstream/lib/std. A declaration is keyed as bs names
its container: the file's path under lib/std without `.zig`, with `/` as
`.` (`mem`, `Io.Dir`, `std` for std.zig), then the declaration's name.
Only file-level `pub` declarations are compared; members of generic types
(`ArrayList(T).init`) are added to the table by hand.

A declaration whose container is gone too is reported once, as its
outermost missing container (`std io` for everything under `std.io`).

Output, most used first: `count container name versions`, where count is
how often the old releases' std writes `<last part of container>.<name>`
(`mem.indexOf`), a rough measure of how common the API was, and versions
lists the releases that had it. The replacement text in the table is written by hand and checked
against 0.17's std.
"""
import os
import re
import sys

DECL = re.compile(r"^pub (?:const|var|fn|inline fn|extern fn) ([A-Za-z_][A-Za-z0-9_]*)", re.M)


def decls(lib_std):
    out = set()
    for root, _, files in os.walk(lib_std):
        for f in files:
            if not f.endswith(".zig"):
                continue
            path = os.path.join(root, f)
            rel = os.path.relpath(path, lib_std)[: -len(".zig")]
            container = "std" if rel == "std" else rel.replace(os.sep, ".")
            try:
                src = open(path, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for name in DECL.findall(src):
                out.add((container, name))
    return out


def uses(lib_std, keys):
    counts = dict.fromkeys(keys, 0)
    by_text = {}
    for container, name in keys:
        by_text.setdefault(f"{container.split('.')[-1]}.{name}", []).append((container, name))
    word = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*)\b")
    for root, _, files in os.walk(lib_std):
        for f in files:
            if f.endswith(".zig"):
                src = open(os.path.join(root, f), encoding="utf-8", errors="replace").read()
                for text in word.findall(src):
                    for key in by_text.get(text, ()):
                        counts[key] += 1
    return counts


def outermost_missing(key, containers):
    """`key` itself if its container exists, else the outermost missing
    container as (parent, name)."""
    container, name = key
    parts = container.split(".") if container != "std" else []
    for i in range(len(parts)):
        prefix = ".".join(parts[: i + 1])
        if prefix not in containers:
            return (".".join(parts[:i]) or "std", parts[i])
    return key


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    *olds, new = sys.argv[1:]
    current = decls(new)
    # A container exists if it is a file or a declaration of 0.17's std.
    containers = {"std"} | {c for c, _ in current} | {(c + "." if c != "std" else "") + n for c, n in current}
    had = {}
    for old in olds:
        version = re.search(r"\d+\.\d+(?:\.\d+)?", os.path.abspath(old))
        for key in decls(old) - current:
            versions = had.setdefault(outermost_missing(key, containers), [])
            v = version.group(0) if version else old
            if v not in versions:
                versions.append(v)
    counts = dict.fromkeys(had, 0)
    for old in olds:
        for key, n in uses(old, had.keys()).items():
            counts[key] += n
    for key, versions in sorted(had.items(), key=lambda kv: (-counts[kv[0]], kv[0])):
        print(counts[key], key[0], key[1], ",".join(versions))


if __name__ == "__main__":
    main()
