#!/usr/bin/env python3
"""Real-world corpus: build pinned Zig projects with bs and upstream zig.

For each project in manifest.json this clones the pinned commit, runs
upstream `zig build --verbose` once to fetch dependencies, run code
generators, and record each compile step's command line, then builds the
manifest's targets from those command lines with upstream zig (Debug,
self-hosted x86_64 backend) and with bs, runs the results, and compares
them. Results go to .work/results.json and a Markdown scoreboard. See
tools/corpus/README.md.
"""

import argparse
import glob
import hashlib
import json
import os
import re
import shlex
import shutil
import statistics
import subprocess
import sys
import time

CORPUS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(os.path.dirname(CORPUS_DIR))
WORK = os.path.join(CORPUS_DIR, ".work")

# Appended to the edit line: keeps the line count, and differs per edit.
EDIT_SUFFIX = " std.mem.doNotOptimizeAway(@as(u32, {n}));"

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
    proj["fetched"] = {"src": src, "zig_lib": os.path.join(REPO_DIR, "upstream", "lib"),
                       "gen": os.path.join(WORK, "gen", proj["name"])}
    if "copy" in proj:
        # A directory of this checkout, such as upstream's own tools in
        # upstream/lib/compiler: copied so that edits leave it alone, plus
        # the manifest's `files` (root files for modules whose code
        # imports outside its own directory). There is no build.zig: the
        # manifest gives the commands.
        if not os.path.isdir(src):
            shutil.copytree(os.path.join(REPO_DIR, proj["copy"]), src)
        for name, text in proj.get("files", {}).items():
            os.makedirs(os.path.dirname(os.path.join(src, name)), exist_ok=True)
            with open(os.path.join(src, name), "w") as f:
                f.write(text)
        return src, proj["commands"]
    if not os.path.isdir(os.path.join(src, ".git")):
        os.makedirs(os.path.dirname(src), exist_ok=True)
        sh(["git", "clone", "--quiet", "--filter=blob:none", proj["url"], src], WORK)
    if sh(["git", "rev-parse", "HEAD"], src).stdout.strip() != proj["commit"]:
        sh(["git", "fetch", "--quiet", "origin", proj["commit"]], src, check=False)
        sh(["git", "checkout", "--quiet", "--force", "--detach", proj["commit"]], src)
    # Data packages a target's run needs (`fetch`), unpacked under .work/fetch/.
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
            if len(words) >= 2 and words[1] == "translate-c":
                # A translated header, which each compiler translates
                # itself for the targets that import it (`translate`).
                cmds.setdefault("translate-c:" + translate_source(words), words)
                continue
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
            # bs has no other mode. (Some build scripts force a release
            # mode on their build-time tools.)
            res.append("-Odebug")
        elif w in ("--cache-dir", "--global-cache-dir", "--zig-lib-dir"):
            # The recording zig's lib dir: each compiler uses its own, so
            # bs gets the std it was built for and upstream its release's.
            i += 1
        else:
            res.append(w)
        i += 1
    res += ["--cache-dir", cache_dir, f"-femit-bin={out}"]
    if words[1] == "test":
        res.append("--test-no-exec")
    return res


def translate_source(words):
    """The C file a recorded `translate-c` command translates."""
    rest = strip_translate(words)
    return next(w for w in rest if not w.startswith("-") and w.endswith((".h", ".c")))


def strip_translate(words):
    res = []
    i = 2
    while i < len(words):
        if words[i] in ("--cache-dir", "--global-cache-dir", "--zig-lib-dir"):
            i += 1
        elif words[i] != "--listen=-":
            res.append(words[i])
        i += 1
    return res


def translate(compiler, words, cmds, cache_dir, src):
    """Translates the C headers a target imports with `compiler`, into
    `cache_dir`, and returns the target's command line importing them.
    upstream's build cache names a translation `<digest>/<stem>.zig`, so a
    module root whose name is a translated header's stem is that header."""
    by_stem = {}
    for key, tc in cmds.items():
        if key.startswith("translate-c:"):
            stem = os.path.splitext(os.path.basename(key[len("translate-c:"):]))[0] + ".zig"
            if stem in by_stem:
                sys.exit(f"two translated headers are named {stem}")
            by_stem[stem] = tc
    res = list(words)
    for i, w in enumerate(words):
        m = re.match(r"-M([^=]+)=(.*)$", w)
        if not m or os.path.basename(m.group(2)) not in by_stem or "/o/" not in m.group(2):
            continue
        tc = by_stem[os.path.basename(m.group(2))]
        argv = [compiler, "translate-c", *strip_translate(tc), "--cache-dir", cache_dir]
        p = subprocess.run(argv, cwd=src, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors="replace")
        if p.returncode != 0:
            return None, p.stdout + p.stderr
        out = os.path.join(cache_dir, "translated", os.path.basename(m.group(2)))
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "w") as f:
            f.write(p.stdout)
        res[i] = f"-M{m.group(1)}={out}"
    return res, ""


def compile_argv(compiler, words, cache_dir, out):
    """The command line of a target for either compiler: bs takes all of
    upstream's flags."""
    rest = strip_common(words, cache_dir, out)
    # The baseline is upstream's Debug default on x86_64-linux: the
    # self-hosted backend, even where the build script asks for LLVM.
    rest = ["-fno-llvm" if w == "-fllvm" else w for w in rest]
    return [compiler, words[1], *rest]


def clear_cache(cache):
    """Empties a target's cache directory but for the translated headers
    its command line names."""
    for entry in os.listdir(cache):
        if entry != "translated":
            p = os.path.join(cache, entry)
            shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)


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


TEST_SUMMARY = re.compile(r"^(?:\x1b\[[0-9;]*m)*(All \d+ tests passed\.|\d+ passed; \d+ skipped; \d+ failed\.|\d+ of \d+ tests passed)", re.M)


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


def expand(arg, proj):
    """A run argument or directory with `{src}`, `{zig_lib}`, `{gen}` (the
    generation cache: code generators' outputs) or a fetched package
    substituted; a glob names its first match, as a generated file's path
    holds a hash."""
    arg = arg.format(**proj["fetched"])
    if "*" in arg:
        matches = sorted(glob.glob(arg, recursive=True))
        if not matches:
            sys.exit(f"{proj['name']}: nothing matches {arg}")
        arg = matches[0]
    return arg


def build_target(proj, src, words, cmds, tgt, compilers, args):
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
        log(f"  {which}: {name}")
        # Translating the target's C headers counts in its cold build.
        t = time.monotonic()
        target_words, output = translate(comp, words, cmds, cache, src)
        tc_secs = time.monotonic() - t
        if target_words is None:
            result[which] = {"cold_local": tc_secs, "compile_exit": 1, "error": first_error(output), "output": output[-20000:]}
            continue
        argv = compile_argv(comp, target_words, cache, out)
        r = {"argv": shlex.join(argv)}
        # A cold build without donors: a donor (another compilation's
        # result in bs's global store) makes the time depend on what the
        # store holds.
        env = dict(os.environ, BS_CACHE_DONOR="off") if which == "bs" else None
        secs, code, output = timed(argv, src, env)
        # More samples (`--samples`): the median, each from an empty local
        # cache.
        cold = [secs]
        while code == 0 and len(cold) < args.samples:
            clear_cache(cache)
            secs, code, output = timed(argv, src, env)
            cold.append(secs)
        secs = statistics.median(cold)
        r["cold_local"] = tc_secs + secs
        r["compile_exit"] = code
        if code != 0:
            r["error"] = first_error(output)
            r["output"] = output[-20000:]
            result[which] = r
            continue
        if which == "bs" and args.donors:
            # bs's real first build in a fresh checkout: an empty local
            # cache, with donors, which find the build just made in the
            # global store. The translated headers stay.
            donor = []
            for _ in range(args.samples):
                clear_cache(cache)
                secs, code, output = timed(argv, src)
                if code != 0:
                    break
                donor.append(secs)
            r["cold_local_donor"] = tc_secs + statistics.median(donor) if code == 0 else None
        # Tests run without arguments; an executable runs only with the
        # manifest's "run" arguments.
        run_args = tgt.get("run", [] if is_test else None)
        if run_args is not None:
            run_args = [expand(a, proj) for a in run_args]
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
            cwd = os.path.join(src, expand(tgt.get("cwd", "."), proj))
            if os.path.isfile(cwd):
                # A generated file names the directory it is in.
                cwd = os.path.dirname(cwd)
            run = run_binary(run_path, run_args, cwd, tgt.get("timeout", 600))
            r["run"] = summarize_run(run, is_test)
        r["run_exit"] = run["exit"]
        r["stdout_sha"] = hashlib.sha256(run["stdout"].encode()).hexdigest()
        # A file the run writes (`output`) counts as part of its stdout.
        if tgt.get("output") and run_args is not None and r["run"] != "skipped":
            out_file = expand(tgt["output"], proj)
            if os.path.exists(out_file):
                with open(out_file, "rb") as f:
                    r["stdout_sha"] = hashlib.sha256(run["stdout"].encode() + f.read()).hexdigest()
                os.remove(out_file)
        r["stdout"] = run["stdout"][-2000:]
        r["stderr"] = run["stderr"][-4000:]
        if edit and not args.no_edit:
            path = os.path.join(src, edit[0])
            env = None
            if which == "bs" and args.cache_check:
                # Check the edit build against a full build (not timed).
                env = dict(os.environ, BS_CACHE_VERIFY="1", BS_CACHE_CHECK="1")
            # Each sample a new edit of the last build.
            edits = []
            for k in range(args.samples):
                orig = apply_edit(path, edit[1], int(time.time()) % 100000 + k)
                try:
                    secs, code, output = timed(argv, src, env)
                finally:
                    with open(path, "w") as f:
                        f.write(orig)
                if code != 0:
                    break
                edits.append(secs)
            secs = statistics.median(edits) if code == 0 else None
            r["edit"] = secs if code == 0 else None
            if code != 0:
                r["edit_error"] = first_error(output)
                r["edit_output"] = output[-20000:]
        result[which] = r
    return result


def compare(res, tgt):
    """One verdict: ok, or what differs between bs and upstream."""
    z, u = res.get("bs"), res.get("zig")
    if u is None or z is None:
        return "not built"
    if u["compile_exit"] != 0:
        return "upstream fails to compile"
    if z["compile_exit"] != 0:
        return "bs: compile error" if z["compile_exit"] == 1 else f"bs: crash ({z['compile_exit']})"
    if z["run"] == "skipped":
        return f"bs: edit build failed: {z['edit_error']}" if z.get("edit_error") else "compiles (not run)"
    if z["run"] != u["run"]:
        return f"bs: run differs ({z['run']} vs {u['run']})"
    if tgt.get("compare_stdout", True) and z["stdout_sha"] != u["stdout_sha"]:
        return "bs: stdout differs"
    if z.get("edit_error"):
        return f"bs: edit build failed: {z['edit_error']}"
    return "ok"


def fmt_s(s):
    return "–" if s is None else (f"{s:.2f} s" if s >= 1 else f"{s * 1000:.0f} ms")


def write_scoreboard(results, manifest, path):
    """One row per target: the verdict, both runs, and both build times."""
    donors = any((r.get("bs") or {}).get("cold_local_donor") for r in results)
    lines = ["| Project | Target | Verdict | upstream run | bs run | cold-local zig / bs |"
             + (" cold-local zig / bs with donors |" if donors else "") + " edit zig / bs |",
             "|---|---|---|---|---|---:|" + ("---:|" if donors else "") + "---:|"]
    for res in results:
        u, z = res.get("zig") or {}, res.get("bs") or {}

        def cell(r):
            return (r.get("run") or r.get("error") or "–").replace("|", "\\|")[:90]

        def ratio(a, b):
            return f" ({a / b:.1f}x)" if a and b else ""
        donor = " {} / {}{} |".format(fmt_s(u.get("cold_local")), fmt_s(z.get("cold_local_donor")),
                                      ratio(u.get("cold_local"), z.get("cold_local_donor"))) if donors else ""
        lines.append("| {} | {} | {} | {} | {} | {} / {}{} |{} {} / {}{} |".format(
            res["project"], res["target"], res["verdict"].replace("|", "\\|"), cell(u), cell(z),
            fmt_s(u.get("cold_local")), fmt_s(z.get("cold_local")), ratio(u.get("cold_local"), z.get("cold_local")),
            donor, fmt_s(u.get("edit")), fmt_s(z.get("edit")), ratio(u.get("edit"), z.get("edit"))))
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--projects", help="comma-separated project names (default: all)")
    ap.add_argument("--targets", help="comma-separated target names (default: all)")
    ap.add_argument("--bs", default=os.path.join(REPO_DIR, "zig-out", "bin", "bs"))
    ap.add_argument("--zig", default="zig")
    ap.add_argument("--refresh", action="store_true", help="rerun zig build --verbose to re-record commands")
    ap.add_argument("--list", action="store_true", help="only record and list each project's compile commands")
    ap.add_argument("--bs-only", action="store_true", help="skip the upstream builds (reuse their last results)")
    ap.add_argument("--no-edit", action="store_true", help="skip the edit builds")
    ap.add_argument("--no-run", action="store_true", help="build only; do not run what was built")
    ap.add_argument("--samples", type=int, default=1,
                    help="time each cold-local and edit build this many times and keep the median (default 1)")
    ap.add_argument("--donors", action="store_true",
                    help="also time bs's cold-local build with donors (cold_local_donor)")
    ap.add_argument("--results", default="results",
                    help="name of the results and scoreboard files in .work (default: results, scoreboard)")
    ap.add_argument("--cache-check", action="store_true",
                    help="bs's edit builds check themselves against full builds (BS_CACHE_VERIFY, BS_CACHE_CHECK)")
    args = ap.parse_args()

    with open(os.path.join(CORPUS_DIR, "manifest.json")) as f:
        manifest = json.load(f)
    projects = [p for p in manifest["projects"] if not args.projects or p["name"] in args.projects.split(",")]
    results_path = os.path.join(WORK, args.results + ".json")
    scoreboard_path = os.path.join(WORK, "scoreboard.md" if args.results == "results" else args.results + ".md")
    old = {}
    if os.path.exists(results_path):
        with open(results_path) as f:
            old = {(r["project"], r["target"]): r for r in json.load(f)}
    os.makedirs(WORK, exist_ok=True)
    compilers = [("bs", os.path.abspath(args.bs))] + ([] if args.bs_only else [("zig", args.zig)])
    for proj in projects:
        log(f"{proj['name']} {proj['commit'][:12]}")
        src, cmds = setup(proj, args.zig, args.refresh)
        if args.list:
            for name, words in cmds.items():
                print(f"{proj['name']}: {name}" if words[1] == "translate-c" else f"{proj['name']}: {words[1]} --name {name}")
            continue
        for tgt in proj["targets"]:
            if args.targets and tgt["name"] not in args.targets.split(","):
                continue
            words = cmds.get(tgt["name"])
            if words is None:
                log(f"  no recorded command for {tgt['name']}; rerun with --refresh")
                continue
            res = build_target(proj, src, words, cmds, tgt, compilers, args)
            if args.bs_only and (proj["name"], tgt["name"]) in old:
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
    write_scoreboard(results, manifest, scoreboard_path)
    print(open(scoreboard_path).read())


if __name__ == "__main__":
    main()
