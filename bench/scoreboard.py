#!/usr/bin/env python3
"""The compile-time and run-time scoreboard against upstream zig 0.17.1.

One command runs every measurement the roadmap's scoreboard quotes, in one
session, and writes bench/results/<date>-scoreboard.md and .json:

1. bench/bench.py on hello, vaxis (libvaxis text_input), zig (upstream's
   compiler) and std (std's tests): upstream Debug, then bs, then bs
   without donors (cold-local only), workload by workload so that the
   three run close together;
2. tools/corpus/run.py over every corpus target, build only: upstream
   and bs back to back per target, bs's cold-local without and with
   donors, and the edit build;
3. bench/runtime.py and bench/realworld.py: bs's code against upstream
   Debug and ReleaseSafe.

    zig build -Doptimize=ReleaseFast
    python3 bench/scoreboard.py --bs zig-out/bin/bs

It takes about an hour on a 4 vCPU orb. `--parts` runs a
subset (bench,corpus,runtime) and `--from-json` re-renders a report.
"""

import argparse
import datetime
import json
import math
import os
import platform
import re
import shutil
import subprocess
import sys

BENCH_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(BENCH_DIR)
CORPUS_DIR = os.path.join(REPO_DIR, "tools", "corpus")
# Each corpus target's cold-local and edit builds are the median of this
# many.
CORPUS_SAMPLES = 3
WORK = os.path.join(BENCH_DIR, ".work", "scoreboard")

# Workload, warm/edit runs, cold runs. The big two take 10-25 s a build
# upstream, so they get fewer runs.
WORKLOADS = [("hello", 10, 5), ("vaxis", 10, 5), ("zig", 5, 3), ("std", 5, 3)]
SCENARIOS = ["cold", "cold-local", "warm", "edit-root", "edit-lib"]
LABELS = {
    "hello": "hello world",
    "vaxis": "libvaxis text_input example",
    "zig": "upstream's zig 0.17.1 compiler (no LLVM)",
    "std": "`zig test lib/std/std.zig` (std's tests, --test-no-exec)",
}
SCENARIO_LABELS = {
    "cold": "cold (empty caches)",
    "cold-local": "cold-local (global cache warm)",
    "warm": "no edit",
    "edit-root": "edit root file",
    "edit-lib": "edit library",
}
EDIT_LABELS = {
    ("hello", "edit-lib"): "edit std (`std/debug.zig`)",
    ("vaxis", "edit-lib"): "edit library (`src/Vaxis.zig`)",
    ("zig", "edit-root"): "edit root (`src/main.zig`)",
    ("zig", "edit-lib"): "edit `src/Sema.zig`",
    ("std", "edit-root"): "edit a test (`std/mem.zig`)",
    ("std", "edit-lib"): "edit `std/debug.zig`",
}


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def run(argv, **kw):
    log("$ " + " ".join(argv))
    subprocess.run(argv, check=True, **kw)


def fmt_s(s):
    if s is None:
        return "–"
    if s >= 1:
        return f"{s:.2f} s"
    if s >= 0.01:
        return f"{s * 1000:.0f} ms"
    return f"{s * 1000:.1f} ms"


def fmt_mib(kb):
    return "–" if kb is None else f"{kb / 1024:.0f} MiB"


def geomean(xs):
    xs = [x for x in xs if x and x > 0]
    return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else None


def git(*args):
    return subprocess.run(["git", *args], cwd=REPO_DIR, stdout=subprocess.PIPE, text=True, check=False).stdout.strip()


def machine():
    info = {"cpus": os.cpu_count(), "kernel": platform.release()}
    with open("/proc/cpuinfo") as f:
        m = re.search(r"model name\s*:\s*(.*)", f.read())
        info["cpu"] = m.group(1).strip() if m else None
    with open("/proc/meminfo") as f:
        info["mem_gib"] = round(int(re.search(r"MemTotal:\s*(\d+) kB", f.read()).group(1)) / 1024 / 1024, 1)
    return info


def bench_part(bs, zig, note):
    out = {}
    for wname, runs, cold_runs in WORKLOADS:
        variants = [
            ("zig", [zig], SCENARIOS),
            ("bs", [bs], SCENARIOS),
            ("bs-nodonor", [bs, "--env", "BS_CACHE_DONOR=off"], ["cold-local"]),
        ]
        out[wname] = {}
        for vname, comp, scen in variants:
            path = os.path.join(WORK, f"bench-{wname}-{vname}")
            run(
                [
                    sys.executable,
                    os.path.join(BENCH_DIR, "bench.py"),
                    "--compiler",
                    comp[0],
                    *comp[1:],
                    "--setup-zig",
                    zig,
                    "--workloads",
                    wname,
                    "--modes",
                    "build-exe",
                    "--scenarios",
                    ",".join(scen),
                    "--runs",
                    str(runs),
                    "--cold-runs",
                    str(cold_runs),
                    "--machine-note",
                    note,
                    "--out",
                    path,
                ]
            )
            with open(path + ".json") as f:
                out[wname][vname] = json.load(f)
    return out


def warm_translate_c(bs):
    """A new bs binary builds its translate-c tool once, which takes
    seconds; build it now so that the first target that translates a
    header does not pay for it."""
    d = os.path.join(WORK, "translate-c-warm")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "warm.h"), "w") as f:
        f.write("int warm(void);\n")
    run([bs, "translate-c", "warm.h", "--cache-dir", "cache"], cwd=d, stdout=subprocess.DEVNULL)


def corpus_part(bs, zig, name="scoreboard", bs_only=False):
    warm_translate_c(bs)
    if bs_only:
        # Upstream's columns come from the full run's results.
        shutil.copy(
            os.path.join(CORPUS_DIR, ".work", "scoreboard.json"), os.path.join(CORPUS_DIR, ".work", name + ".json")
        )
    run(
        [
            sys.executable,
            os.path.join(CORPUS_DIR, "run.py"),
            "--bs",
            bs,
            "--zig",
            zig,
            "--no-run",
            "--donors",
            "--samples",
            str(CORPUS_SAMPLES),
            "--results",
            name,
            *(["--bs-only"] if bs_only else []),
        ]
    )
    with open(os.path.join(CORPUS_DIR, ".work", name + ".json")) as f:
        results = json.load(f)
    # The compilers' output and command lines stay in .work; the report
    # keeps the numbers.
    for r in results:
        for which in ("zig", "bs"):
            for k in ("output", "argv"):
                (r.get(which) or {}).pop(k, None)
    return results


def donors_part(bs, zig, note):
    """bs's donor-on rows again, with another bs (`--add-donors`): each
    workload's cold-local, upstream then bs, and the corpus's bs
    columns against the full run's upstream columns."""
    out = {"bench": {}}
    for wname, runs, _ in WORKLOADS:
        out["bench"][wname] = {}
        for vname, comp in (("zig", zig), ("bs", bs)):
            path = os.path.join(WORK, f"donors-{wname}-{vname}")
            run(
                [
                    sys.executable,
                    os.path.join(BENCH_DIR, "bench.py"),
                    "--compiler",
                    comp,
                    "--setup-zig",
                    zig,
                    "--workloads",
                    wname,
                    "--modes",
                    "build-exe",
                    "--scenarios",
                    "cold-local",
                    "--runs",
                    str(runs),
                    "--machine-note",
                    note,
                    "--out",
                    path,
                ]
            )
            with open(path + ".json") as f:
                out["bench"][wname][vname] = json.load(f)
    out["corpus"] = corpus_part(bs, zig, "scoreboard-donors", bs_only=True)
    return out


def runtime_part(bs, zig, note):
    rt = os.path.join(WORK, "runtime")
    run(
        [
            sys.executable,
            os.path.join(BENCH_DIR, "runtime.py"),
            "--compiler",
            bs,
            "--zig",
            zig,
            "--machine-note",
            note,
            "--out",
            rt,
        ]
    )
    rw = os.path.join(WORK, "realworld.json")
    run([sys.executable, os.path.join(BENCH_DIR, "realworld.py"), "--compiler", bs, "--zig", zig, "--out", rw])
    with open(rt + ".json") as f, open(rw) as g:
        return {"runtime": json.load(f), "realworld": json.load(g)}


def summary(pairs):
    return (
        f"{geomean([a / b for a, b in pairs]):.1f}x over {len(pairs)} targets "
        f"({sum(a for a, _ in pairs):.1f} s vs {sum(b for _, b in pairs):.1f} s in total)"
    )


def stats(report, scenario):
    return next((r["stats"] for r in report["results"] if r["scenario"] == scenario), None)


def render(data):
    m, lines = data["machine"], []
    lines += [f"# Scoreboard {data['date']}: bs {data['commit']} against upstream zig 0.17.1", ""]
    lines += [
        (
            f"Machine: {m['cpu']}, {m['cpus']} logical CPUs, {m['mem_gib']} GiB, Linux {m['kernel']} "
            f"({data['note']}). bs {data['commit']} built with `-Doptimize=ReleaseFast`; upstream zig 0.17.1 "
            "Debug (self-hosted x86_64 backend and linker) unless a column says ReleaseSafe (LLVM). "
            f"Made by `python3 bench/scoreboard.py --bs <bs>` in one session ({data['started']} to "
            f"{data['finished']} UTC)."
        ),
        "",
    ]
    if "bench" in data:
        b = data["bench"]
        cal = [r["calibration_s"][k] for w in b.values() for r in w.values() for k in ("start", "end")]
        lines += ["## Compile time vs upstream zig 0.17.1 Debug", ""]
        lines += [
            (
                "`bench/bench.py`, `build-exe` mode (std: `zig test`), each workload measured upstream, bs, "
                "then bs without donors, back to back. Median wall time; runs per scenario: hello and vaxis "
                "10 (cold 5), zig and std 5 (cold 3); peak RSS where it matters. cold-local is the first "
                "build of a project with bs's global store warm: with donors, bs replays the earlier build "
                "of the same compilation from the store (bs's real first-build path in a fresh checkout); "
                "`BS_CACHE_DONOR=off` analyzes everything. Edits append a statement to one line of a "
                "function body, new each build. CPU calibration loop "
                f"{fmt_s(min(cal))}–{fmt_s(max(cal))} over the session."
            ),
            "",
        ]
        lines += [
            "| Workload (`zig build-exe`) | Scenario | Upstream zig | bs | zig / bs |",
            "| --- | --- | --- | --- | ---: |",
        ]
        for wname, w in b.items():
            for sc in SCENARIOS:
                u, z = stats(w["zig"], sc), stats(w["bs"], sc)
                if not u or not z:
                    continue
                label = EDIT_LABELS.get((wname, sc), SCENARIO_LABELS[sc])
                ucell, zcell = fmt_s(u["median_s"]), fmt_s(z["median_s"])
                if wname in ("zig", "std") and sc in ("cold", "cold-local"):
                    ucell += f", {fmt_mib(u['maxrss_median_kb'])}"
                    zcell += f", {fmt_mib(z['maxrss_median_kb'])}"
                if sc == "cold-local":
                    nd = stats(w["bs-nodonor"], "cold-local")
                    zcell = f"**{zcell}** with donors ({fmt_s(nd['median_s'])} without, {u['median_s'] / nd['median_s']:.1f}x)"
                ratio = u["median_s"] / z["median_s"]
                lines.append(f"| {LABELS[wname]} | {label} | {ucell} | {zcell} | {ratio:.1f}x |")
        lines += [""]
    if "corpus" in data:
        res = data["corpus"]
        rows = []
        for r in res:
            u, z = r.get("zig") or {}, r.get("bs") or {}
            if u.get("compile_exit") == 0 and z.get("compile_exit") == 0:
                rows.append((r, u, z))
        cl = [(u["cold_local"], z["cold_local"]) for _, u, z in rows]
        cd = [(u["cold_local"], z["cold_local_donor"]) for _, u, z in rows if z.get("cold_local_donor")]
        ed = [(u["edit"], z["edit"]) for _, u, z in rows if u.get("edit") and z.get("edit")]

        failed = [f"{r['project']} {r['target']}" for r in res if r not in [x[0] for x in rows]]
        lines += ["## Corpus: every target, bs vs upstream Debug", ""]
        lines += [
            (
                "`tools/corpus/run.py --no-run --donors`: each target's recorded compile command, upstream "
                f"then bs, median of {data.get('corpus_samples', CORPUS_SAMPLES)} samples. cold-local is an empty local cache with a warm global cache; "
                "bs's is timed without donors, then again with donors (which then find the build just made "
                "in the global store); edit is the rebuild after the manifest's one-line edit. Geometric "
                "means of the per-target ratio zig / bs:"
            ),
            "",
        ]
        lines += [
            "| Scenario | zig / bs |",
            "| --- | ---: |",
            f"| cold-local, without donors | {summary(cl)} |",
            f"| cold-local, with donors | {summary(cd)} |",
            f"| edit build | {summary(ed)} |",
            "",
        ]
        if failed:
            lines += [f"Not compared (a compiler failed): {', '.join(failed)}.", ""]
        slow = [
            (r, u, z)
            for r, u, z in rows
            if z["cold_local"] > u["cold_local"]
            or (z.get("cold_local_donor") or 0) > u["cold_local"]
            or (u.get("edit") and z.get("edit") and z["edit"] > u["edit"])
        ]
        if slow:
            lines += ["Targets where bs was slower than upstream in some column:", ""]
            for r, u, z in slow:
                lines.append(
                    f"- {r['project']} {r['target']}: cold-local {fmt_s(u['cold_local'])} / "
                    f"{fmt_s(z['cold_local'])}, with donors {fmt_s(z.get('cold_local_donor'))}, "
                    f"edit {fmt_s(u.get('edit'))} / {fmt_s(z.get('edit'))}"
                )
            lines += [""]
        lines += [
            "| Project | Target | cold-local zig / bs | with donors | edit zig / bs |",
            "| --- | --- | ---: | ---: | ---: |",
        ]
        for r, u, z in rows:

            def ratio(a, b):
                return f" ({a / b:.1f}x)" if a and b else ""

            lines.append(
                f"| {r['project']} | {r['target']} | {fmt_s(u['cold_local'])} / {fmt_s(z['cold_local'])}"
                f"{ratio(u['cold_local'], z['cold_local'])} | {fmt_s(z.get('cold_local_donor'))}"
                f"{ratio(u['cold_local'], z.get('cold_local_donor'))} | {fmt_s(u.get('edit'))} / "
                f"{fmt_s(z.get('edit'))}{ratio(u.get('edit'), z.get('edit'))} |"
            )
        lines += [""]
    if "runtime" in data:
        rt, rw = data["runtime"]["runtime"], data["runtime"]["realworld"]
        lines += ["## Run time vs upstream Debug and ReleaseSafe", ""]
        lines += [f"`bench/runtime.py`, median of {rt['runs']} runs; the three binaries print the same output.", ""]
        lines += [
            "| Program | bs | upstream Debug | upstream ReleaseSafe | bs / Debug | bs / ReleaseSafe |",
            "| --- | ---: | ---: | ---: | ---: | ---: |",
        ]
        for prog, r in rt["results"].items():
            z, d, s = r["bs"]["median_s"], r["Debug"]["median_s"], r["ReleaseSafe"]["median_s"]
            lines.append(f"| {prog} | {fmt_s(z)} | {fmt_s(d)} | {fmt_s(s)} | {z / d:.2f}x | {z / s:.1f}x |")
        lines += ["", f"`bench/realworld.py`, median of {rw['runs']} runs:", ""]
        lines += [
            "| Workload | bs | upstream Debug | upstream ReleaseSafe | bs / Debug | bs / ReleaseSafe |",
            "| --- | ---: | ---: | ---: | ---: | ---: |",
        ]
        for wname, r in rw["results"].items():
            z = r["bs"]["median"]
            d = r.get("Debug", {}).get("median")
            s = r.get("ReleaseSafe", {}).get("median")
            lines.append(
                f"| {wname} | {fmt_s(z)} | {fmt_s(d)} | {fmt_s(s)} | "
                f"{f'{z / d:.2f}x' if d else '–'} | {f'{z / s:.1f}x' if s else '–'} |"
            )
        lines += [""]
    if "donors" in data:
        dn = data["donors"]
        lines += [f"## Donor-on rows again on bs {dn['commit']}", ""]
        lines += [
            (
                f"{dn.get('why', '')} Same orb and session as above ({dn['started']} to {dn['finished']} UTC); "
                "`bench/scoreboard.py --add-donors`. cold-local, median of 10 (zig and std: 5), upstream "
                "measured again next to bs:"
            ),
            "",
        ]
        lines += [
            f"| Workload | Upstream zig | bs {data['commit']} | bs {dn['commit']} | zig / bs |",
            "| --- | ---: | ---: | ---: | ---: |",
        ]
        for wname, w in dn["bench"].items():
            u, z = stats(w["zig"], "cold-local"), stats(w["bs"], "cold-local")
            old_z = stats(data["bench"][wname]["bs"], "cold-local") if "bench" in data else None
            lines.append(
                f"| {LABELS[wname]} | {fmt_s(u['median_s'])} | {fmt_s(old_z['median_s']) if old_z else '–'} | "
                f"**{fmt_s(z['median_s'])}** | {u['median_s'] / z['median_s']:.1f}x |"
            )
        lines += [""]
        rows = [(r, r.get("zig") or {}, r.get("bs") or {}) for r in dn["corpus"]]
        rows = [(r, u, z) for r, u, z in rows if u.get("compile_exit") == 0 and z.get("compile_exit") == 0]
        cl = [(u["cold_local"], z["cold_local"]) for _, u, z in rows]
        cd = [(u["cold_local"], z["cold_local_donor"]) for _, u, z in rows if z.get("cold_local_donor")]
        ed = [(u["edit"], z["edit"]) for _, u, z in rows if u.get("edit") and z.get("edit")]
        lines += [
            f"Corpus, bs {dn['commit']} against the upstream columns above (geometric means of zig / bs):",
            "",
            "| Scenario | zig / bs |",
            "| --- | ---: |",
            f"| cold-local, without donors | {summary(cl)} |",
            f"| cold-local, with donors | {summary(cd)} |",
            f"| edit build | {summary(ed)} |",
            "",
        ]
        slow = [
            (r, u, z)
            for r, u, z in rows
            if z["cold_local"] > u["cold_local"]
            or (z.get("cold_local_donor") or 0) > u["cold_local"]
            or (u.get("edit") and z.get("edit") and z["edit"] > u["edit"])
        ]
        lines += [
            "Targets where bs was slower than upstream in some column: "
            + ("; ".join(f"{r['project']} {r['target']}" for r, _, _ in slow) if slow else "none")
            + ".",
            "",
        ]
    if data.get("findings"):
        lines += [data["findings"].rstrip(), ""]
    return "\n".join(lines)


def save(data, out):
    with open(out + ".json", "w") as f:
        json.dump(data, f, indent=1)
        f.write("\n")


def measure(data, part, bs, zig, note, out):
    """Runs one part and saves the report's JSON after it, so that
    `--resume` can continue an interrupted run."""
    if part == "bench":
        data["bench"] = bench_part(bs, zig, note)
    elif part == "corpus":
        data["corpus"] = corpus_part(bs, zig)
        data["corpus_samples"] = CORPUS_SAMPLES
    elif part == "runtime":
        data["runtime"] = runtime_part(bs, zig, note)
    else:
        sys.exit(f"unknown part {part}")
    save(data, out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bs", default=os.path.join(REPO_DIR, "zig-out", "bin", "bs"), help="bs, ReleaseFast")
    ap.add_argument("--zig", default="zig", help="upstream zig 0.17.1 (default: zig on PATH)")
    ap.add_argument("--parts", default="bench,corpus,runtime", help="comma-separated subset of bench,corpus,runtime")
    ap.add_argument("--note", default="Amp orb", help="describes the machine in the report")
    ap.add_argument(
        "--out", default=None, help="output path without extension (default bench/results/<date>-scoreboard)"
    )
    ap.add_argument("--from-json", help="render the report from an earlier run's JSON")
    ap.add_argument(
        "--resume",
        action="store_true",
        help="continue an interrupted run: keep the parts its JSON (--out) holds, measure the rest",
    )
    ap.add_argument(
        "--add-donors",
        metavar="WHY",
        help="with --from-json: measure the donor-on rows again with --bs (for example after a donor "
        "change lands) and add them to the report; WHY says what changed",
    )
    ap.add_argument("--bs-commit", help="the commit --bs was built from (default: this checkout's HEAD)")
    ap.add_argument("--findings", help="Markdown file whose text the report ends with (kept in the JSON)")
    args = ap.parse_args()

    out = args.out or os.path.join(BENCH_DIR, "results", f"{datetime.date.today().isoformat()}-scoreboard")
    if args.from_json:
        with open(args.from_json) as f:
            data = json.load(f)
    elif args.resume and os.path.exists(out + ".json"):
        # An interrupted run: measure only the parts it has not saved.
        with open(out + ".json") as f:
            data = json.load(f)
        bs = os.path.abspath(args.bs)
        zig = (
            subprocess.run(["which", args.zig], stdout=subprocess.PIPE, text=True, check=False).stdout.strip()
            or args.zig
        )
        now = lambda: datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d %H:%M")
        for part in args.parts.split(","):
            if part not in data:
                measure(data, part, bs, zig, args.note, out)
        data["finished"] = now()
        save(data, out)
    else:
        bs = os.path.abspath(args.bs)
        zig = (
            subprocess.run(["which", args.zig], stdout=subprocess.PIPE, text=True, check=False).stdout.strip()
            or args.zig
        )
        os.makedirs(WORK, exist_ok=True)
        now = lambda: datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d %H:%M")
        data = {
            "date": datetime.date.today().isoformat(),
            "commit": args.bs_commit or git("rev-parse", "--short", "HEAD"),
            "machine": machine(),
            "note": args.note,
            "started": now(),
            "bs": bs,
            "zig": zig,
        }
        for part in args.parts.split(","):
            measure(data, part, bs, zig, args.note, out)
        data["finished"] = now()
        save(data, out)
    if args.add_donors:
        if not args.from_json:
            sys.exit("--add-donors needs --from-json")
        zig = (
            subprocess.run(["which", args.zig], stdout=subprocess.PIPE, text=True, check=False).stdout.strip()
            or args.zig
        )
        now = lambda: datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d %H:%M")
        started = now()
        dn = donors_part(os.path.abspath(args.bs), zig, data["note"])
        dn.update(
            commit=args.bs_commit or git("rev-parse", "--short", "HEAD"),
            why=args.add_donors,
            started=started,
            finished=now(),
        )
        data["donors"] = dn
        save(data, out)
    if args.findings:
        with open(args.findings) as f:
            data["findings"] = f.read()
        save(data, out)
    with open(out + ".md", "w") as f:
        f.write(render(data))
    log(f"wrote {out}.md")


if __name__ == "__main__":
    main()
