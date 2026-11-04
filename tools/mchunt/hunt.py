#!/usr/bin/env python3
"""Differential miscompile hunter for bs (see tools/mchunt/README.md).

Generates random well-defined Zig programs (gen.py), compiles each with
upstream zig 0.17.1 (Debug, the oracle) and with bs in several
configurations, runs them, and compares what they print and how they
exit. A mismatch is triaged (upstream ReleaseSafe as a second oracle,
pass toggles), saved under .work/found/, and minimized (reduce.py).

    python3 tools/mchunt/hunt.py                  # hunt until interrupted
    python3 tools/mchunt/hunt.py --hours 3 --follow   # rebuild bs when origin/main moves
"""

import argparse
import concurrent.futures as cf
import hashlib
import json
import os
import shutil
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen  # noqa: E402
import harness as H  # noqa: E402

FOUND = os.path.join(H.WORK, "found")


def log(msg):
    print(time.strftime("%H:%M:%S ") + msg, file=sys.stderr, flush=True)


def classify(up, res):
    """Names the finding for a mismatch, or None when every bs
    configuration agrees with upstream."""
    bad = sorted(n for n, o in res.items() if n.startswith("bs") and o.key() != up.key())
    if not bad:
        return None, bad
    safe = res.get("zig-safe")
    zd = res.get("bs")
    if safe is not None and safe.compiled() and safe.key() != up.key():
        # Upstream disagrees with itself: Debug (x86_64 backend) against
        # ReleaseSafe (LLVM).
        if zd is not None and zd.key() == safe.key():
            return "upstream-debug-bug", bad
        return "oracle-split", bad
    if any(res[n].status == "compile-crash" for n in bad):
        return "bs-crash", bad
    if any(res[n].status in ("compile-error", "compile-timeout") for n in bad):
        return "bs-reject", bad
    return "miscompile", bad


def signature(cls, bad, up, res):
    first = res[bad[0]]
    return f"{cls}|{','.join(bad)}|{up.kind()}|{first.kind()}"


def check(seed, tools, size, branch=None, base=None):
    """Runs one seed. Returns a small record; saves findings. For a
    branch campaign, `base` is bs from origin/main: a finding is run
    again with it to tell the branch's regressions from main's bugs."""
    scratch = H.new_scratch()
    try:
        src = os.path.join(scratch, f"p{seed}.zig")
        text = gen.generate(seed, size)
        with open(src, "w") as f:
            f.write(text)
        t0 = time.time()
        up = H.run_config(tools, H.UP_DEBUG, src, scratch)
        rec = {"seed": seed, "up": up.status, "lines": len(text.splitlines())}
        if not up.compiled():
            if up.status == "compile-crash":
                rec["result"] = "upstream-crash"
            else:
                first = next((l for l in up.detail.splitlines() if "error:" in l), "")
                rec["result"] = "discard"
                rec["why"] = first.split("error: ", 1)[-1][:60]
            return rec
        if up.status in ("timeout", "signal", "exit"):
            rec["result"] = "upstream-" + up.status
            return rec
        res = {}
        for cfg in H.ALWAYS:
            res[cfg.name] = H.run_config(tools, cfg, src, scratch)
        cls, bad = classify(up, res)
        if cls is None:
            rec["result"] = "pass"
            rec["secs"] = time.time() - t0
            return rec
        for cfg in H.TRIAGE:
            res[cfg.name] = H.run_config(tools, cfg, src, scratch)
        cls, bad = classify(up, res)
        if cls is None:
            rec["result"] = "flaky"
            return rec
        sig = signature(cls, bad, up, res)
        extra = {}
        if branch:
            extra["branch"] = branch
            if base is not None and cls in ("miscompile", "bs-crash", "bs-reject"):
                on_main = [n for n in bad if H.run_config(base, H.BY_NAME[n], src, scratch).key() != up.key()]
                extra["base_bs"] = base.bs
                extra["also_on_main"] = on_main
                if not on_main:
                    cls = "branch-" + cls
                    sig = f"{branch}|{sig}"
        rec["result"] = cls
        rec["sig"] = sig
        rec["dir"] = save_finding(seed, text, tools, up, res, cls, bad, sig, extra)
        return rec
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def save_finding(seed, text, tools, up, res, cls, bad, sig, extra=None):
    d = os.path.join(FOUND, f"{cls}-{seed}")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "orig.zig"), "w") as f:
        f.write(text)
    meta = {
        "seed": seed, "class": cls, "bad": bad, "sig": sig, "bs": tools.bs, "bs_rev": bs_rev(tools.bs),
        "time": time.strftime("%Y-%m-%d %H:%M:%S"),
        "outcomes": {"zig": up.to_json(), **{n: o.to_json() for n, o in res.items()}},
        **(extra or {}),
    }
    with open(os.path.join(d, "meta.json"), "w") as f:
        json.dump(meta, f, indent=1)
    return d


def bs_rev(path):
    """The commit a bs binary was built from, when it came from
    `build_bs` (.work/bs/<sha>/bin/bs); else the checkout's HEAD."""
    parts = path.split(os.sep)
    if "bs" in parts and len(parts) >= 3 and parts[-2] == "bin":
        cand = parts[-3]
        if len(cand) == 40:
            return cand
    try:
        return subprocess.run(["git", "-C", H.REPO_DIR, "rev-parse", "HEAD"], stdout=subprocess.PIPE, text=True).stdout.strip()
    except OSError:
        return "?"


def build_bs(sha):
    """Builds bs at `sha` (ReleaseFast) in a worktree under .work and
    returns the binary's path. Cached per commit."""
    dest = os.path.join(H.WORK, "bs", sha)
    binp = os.path.join(dest, "bin", "bs")
    if os.path.exists(binp):
        return binp
    tree = os.path.join(H.WORK, "tree")
    if not os.path.isdir(tree):
        subprocess.run(["git", "-C", H.REPO_DIR, "worktree", "add", "--detach", tree, sha], check=True,
                       stdout=subprocess.DEVNULL)
    else:
        subprocess.run(["git", "-C", tree, "checkout", "--quiet", "--detach", sha], check=True)
    up = os.path.join(H.REPO_DIR, "upstream")
    if os.path.exists(up) and not os.path.exists(os.path.join(tree, "upstream")):
        os.symlink(os.path.realpath(up), os.path.join(tree, "upstream"))
    log(f"building bs {sha[:10]} (ReleaseFast)")
    p = subprocess.run(["zig", "build", "-Doptimize=ReleaseFast", "--prefix", dest], cwd=tree,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if p.returncode != 0 or not os.path.exists(binp):
        raise RuntimeError(f"building bs at {sha} failed:\n{p.stdout[-3000:]}")
    return binp


def origin_main():
    subprocess.run(["git", "-C", H.REPO_DIR, "fetch", "--quiet", "origin", "main"], check=False)
    return subprocess.run(["git", "-C", H.REPO_DIR, "rev-parse", "origin/main"], stdout=subprocess.PIPE,
                          text=True).stdout.strip()


def recheck_findings(tools):
    """Runs every saved finding's smallest program again with `tools`;
    marks the ones that now agree with upstream as fixed."""
    if not os.path.isdir(FOUND):
        return
    for name in sorted(os.listdir(FOUND)):
        d = os.path.join(FOUND, name)
        mp = os.path.join(d, "meta.json")
        if not os.path.exists(mp):
            continue
        meta = json.load(open(mp))
        if meta.get("fixed_in") or meta["class"] not in ("miscompile", "bs-crash", "bs-reject"):
            continue
        prog = os.path.join(d, "reduced.zig") if os.path.exists(os.path.join(d, "reduced.zig")) else os.path.join(d, "orig.zig")
        scratch = H.new_scratch()
        try:
            src = os.path.join(scratch, "p.zig")
            shutil.copy(prog, src)
            up = H.run_config(tools, H.UP_DEBUG, src, scratch)
            still = any(H.run_config(tools, H.BY_NAME[n], src, scratch).key() != up.key() for n in meta["bad"])
        finally:
            shutil.rmtree(scratch, ignore_errors=True)
        if not still:
            meta["fixed_in"] = bs_rev(tools.bs)
            json.dump(meta, open(mp, "w"), indent=1)
            log(f"{name}: fixed in {meta['fixed_in'][:10]}")


class Stats:
    def __init__(self):
        self.counts = {}
        self.why = {}
        self.panics = 0
        self.t0 = time.time()
        self.n = 0

    def add(self, rec):
        self.n += 1
        r = rec["result"]
        self.counts[r] = self.counts.get(r, 0) + 1
        if r == "discard":
            self.why[rec.get("why", "")] = self.why.get(rec.get("why", ""), 0) + 1
        if rec.get("up") == "panic" and r not in ("discard",):
            self.panics += 1

    def line(self):
        el = time.time() - self.t0
        c = " ".join(f"{k}={v}" for k, v in sorted(self.counts.items()))
        ran = self.n - self.counts.get("discard", 0) - self.counts.get("upstream-crash", 0)
        return f"{self.n} programs in {el / 60:.1f} min ({self.n / max(el, 1):.2f}/s): {c}; upstream panicked in {self.panics}/{max(ran, 1)}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 1), help="hunting workers")
    ap.add_argument("--reducers", type=int, default=1, help="concurrent reductions")
    ap.add_argument("--bs", help="bs binary (default zig-out/bin/bs; with --follow, built from origin/main)")
    ap.add_argument("--zig", help="upstream zig 0.17.1 (default: zig on PATH)")
    ap.add_argument("--seed", type=int, help="first seed (default: random)")
    ap.add_argument("--count", type=int, help="stop after this many programs")
    ap.add_argument("--hours", type=float, help="stop after this long")
    ap.add_argument("--size", type=float, default=1.0, help="program size factor")
    ap.add_argument("--follow", action="store_true",
                    help="hunt with bs built from origin/main; rebuild and recheck findings whenever it moves")
    ap.add_argument("--branches", metavar="GLOB",
                    help="with --follow: hunt on each branch matching GLOB (say 'm7-*') whose head appears or "
                         "moves while this runs, before it merges")
    ap.add_argument("--branches-now", action="store_true",
                    help="also hunt on the heads that match --branches when this starts")
    ap.add_argument("--skip-branch", action="append", default=[], help="branch to leave out of --branches")
    ap.add_argument("--branch-programs", type=int, default=2500, help="programs per branch head")
    ap.add_argument("--no-reduce", action="store_true")
    ap.add_argument("--per-sig", type=int, default=2, help="reductions per finding signature")
    ap.add_argument("--one", type=int, help="check one seed and print its outcomes")
    args = ap.parse_args()

    tools = H.Tools(args.bs, args.zig)
    if args.one is not None:
        rec = check(args.one, tools, args.size)
        print(json.dumps(rec, indent=1))
        return

    current = None
    if args.follow:
        current = origin_main()
        tools = H.Tools(build_bs(current), args.zig)
    if not os.path.exists(tools.bs):
        sys.exit(f"no bs at {tools.bs}: build it with `zig build -Doptimize=ReleaseFast` or pass --follow")
    log(f"bs {tools.bs} ({bs_rev(tools.bs)[:10]}), zig {tools.zig}, {args.jobs} workers")

    import random
    seed = args.seed if args.seed is not None else random.randrange(1 << 40)
    start = seed
    stats = Stats()
    deadline = time.time() + args.hours * 3600 if args.hours else None
    sig_reduced = {}
    lock = threading.Lock()
    rebuilt = {"tools": tools, "sha": current}

    # Branch campaigns: each new head of a matching branch gets
    # --branch-programs programs, ahead of main.
    seen_path = os.path.join(H.WORK, "branches.json")
    seen = json.load(open(seen_path)) if os.path.exists(seen_path) else {}
    fresh = not os.path.exists(seen_path)
    queue = []
    rebuilt["campaign"] = None

    def branch_heads():
        if not args.branches:
            return {}
        out = subprocess.run(["git", "-C", H.REPO_DIR, "for-each-ref", "--format=%(refname:strip=3) %(objectname)",
                              f"refs/remotes/origin/{args.branches}"], stdout=subprocess.PIPE, text=True).stdout
        return {b: h for b, h in (l.split() for l in out.splitlines()) if b not in args.skip_branch}

    def poll_branches(first):
        for b, h in branch_heads().items():
            if seen.get(b) == h:
                continue
            seen[b] = h
            if first and fresh and not args.branches_now:
                continue  # heads that exist on the first run are the baseline
            if (b, h) not in queue:
                log(f"branch {b} at {h[:10]}: queued")
                queue.append((b, h))
        json.dump(seen, open(seen_path, "w"), indent=1)

    def start_campaign():
        if rebuilt["campaign"] is not None or not queue:
            return
        b, h = queue.pop(0)
        if seen.get(b) != h:
            return  # superseded by a newer head
        t = H.Tools(build_bs(h), args.zig)
        with lock:
            rebuilt["campaign"] = {"branch": b, "sha": h, "tools": t, "left": args.branch_programs,
                                   "done": 0, "findings": [], "t0": time.time()}
        log(f"campaign {b} {h[:10]}: {args.branch_programs} programs")

    def follower():
        first = True
        while True:
            try:
                sha = origin_main()
                if sha and sha != rebuilt["sha"]:
                    log(f"origin/main moved to {sha[:10]}")
                    path = build_bs(sha)
                    t = H.Tools(path, args.zig)
                    with lock:
                        rebuilt["tools"], rebuilt["sha"] = t, sha
                    recheck_findings(t)
                poll_branches(first)
                first = False
                start_campaign()
            except Exception as e:  # keep hunting on a failed build
                log(f"follow: {e}")
            time.sleep(300)

    def finish_campaign(c):
        el = (time.time() - c["t0"]) / 60
        msg = f"campaign {c['branch']} {c['sha'][:10]} done: {c['done']} programs in {el:.0f} min, " \
              f"findings: {', '.join(c['findings']) or 'none'}"
        log(msg)
        with open(os.path.join(H.WORK, "campaigns.log"), "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M ") + msg + "\n")

    if args.follow:
        threading.Thread(target=follower, daemon=True).start()

    hunt = cf.ProcessPoolExecutor(args.jobs)
    red = cf.ProcessPoolExecutor(args.reducers)
    pending = set()
    reductions = set()
    last = time.time()
    try:
        while True:
            done_hunting = (args.count is not None and seed - start >= args.count) \
                or (deadline and time.time() > deadline)
            while not done_hunting and len(pending) < args.jobs * 2:
                with lock:
                    c = rebuilt["campaign"]
                    if c is not None and c["left"] > 0:
                        c["left"] -= 1
                        fut = hunt.submit(check, seed, c["tools"], args.size, c["branch"], rebuilt["tools"])
                        fut.campaign = c
                    else:
                        fut = hunt.submit(check, seed, rebuilt["tools"], args.size)
                        fut.campaign = None
                pending.add(fut)
                seed += 1
            if not pending and not reductions:
                break
            done, _ = cf.wait(pending | reductions, timeout=5, return_when=cf.FIRST_COMPLETED)
            for fut in done:
                if fut in reductions:
                    reductions.discard(fut)
                    try:
                        log(f"reduced: {fut.result()}")
                    except Exception as e:
                        log(f"reduction failed: {e}")
                    continue
                pending.discard(fut)
                try:
                    rec = fut.result()
                except Exception as e:
                    log(f"worker error: {e!r}")
                    continue
                stats.add(rec)
                c = fut.campaign
                if c is not None:
                    c["done"] += 1
                    if rec["result"] not in ("pass", "discard") and not rec["result"].startswith("upstream"):
                        c["findings"].append(f"{rec['result']}-{rec['seed']}")
                    if c["left"] == 0 and c["done"] >= args.branch_programs:
                        finish_campaign(c)
                        with lock:
                            rebuilt["campaign"] = None
                if rec["result"] not in ("pass", "discard"):
                    log(f"seed {rec['seed']}: {rec['result']} {rec.get('sig', rec.get('why', ''))}")
                if rec["result"].replace("branch-", "") in ("miscompile", "bs-crash", "bs-reject") and not args.no_reduce:
                    n = sig_reduced.get(rec["sig"], 0)
                    if n < args.per_sig:
                        sig_reduced[rec["sig"]] = n + 1
                        import reduce as R
                        bs = c["tools"].bs if c is not None else rebuilt["tools"].bs
                        reductions.add(red.submit(R.reduce_finding, rec["dir"], bs, tools.zig))
            if time.time() - last > 60:
                last = time.time()
                log(stats.line())
                if stats.why:
                    top = sorted(stats.why.items(), key=lambda kv: -kv[1])[:4]
                    log("  discards: " + "; ".join(f"{v}× {k}" for k, v in top))
    except KeyboardInterrupt:
        log("interrupted")
    finally:
        log(stats.line())
        hunt.shutdown(cancel_futures=True)
        red.shutdown(cancel_futures=True)


if __name__ == "__main__":
    main()
