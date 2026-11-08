"""Compiling and running one program under each configuration (tools/mchunt).

A configuration is a compiler, an optimize mode and environment
variables. A run's outcome is what the program printed of its own
(`ck` lines) up to a panic, the panic message, and how it exited; stack
traces and thread ids are dropped, since they differ between compilers.
"""

import os
import platform
import re
import shutil
import subprocess
import tempfile
import time

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(os.path.dirname(TOOL_DIR))
WORK = os.path.join(TOOL_DIR, ".work")

COMPILE_TIMEOUT = 120
RUN_TIMEOUT = 10


# Flags every configuration compiles with, upstream and bs alike (such
# as -target or -mcpu), and the command that runs a binary built for
# another architecture. A finding's meta.json keeps both (`target`).
TARGET_FLAGS = []
RUNNER = []


def set_target(flags=(), runner=()):
    TARGET_FLAGS[:] = flags
    RUNNER[:] = runner


def target_meta():
    return {"flags": list(TARGET_FLAGS), "runner": list(RUNNER)}


def target_for(target=None, mcpu=None):
    """The flags and runner for a `-target` triple and an `-mcpu` CPU.
    aarch64 binaries on another host run under qemu as a Cortex-A53,
    as tools/conformance/run.py runs them."""
    flags, runner = [], []
    if target:
        flags += ["-target", target]
        arch = target.split("-")[0]
        host = {"arm64": "aarch64", "AMD64": "x86_64"}.get(platform.machine(), platform.machine())
        if arch != host:
            if arch != "aarch64":
                raise SystemExit(f"no runner for {target} on {host}")
            q = shutil.which("qemu-aarch64-static") or shutil.which("qemu-aarch64")
            if q is None:
                raise SystemExit("no qemu-aarch64: .agents/setup installs qemu-user-static")
            runner = [q, "-cpu", "cortex-a53"]
    # The native target's CPU is the host's, which bs clamps to what it
    # supports and upstream does not: pin both compilers to one.
    if mcpu or not target:
        flags.append(f"-mcpu={mcpu or 'baseline'}")
    return flags, runner


class Config:
    """`kind` is "zig" (upstream) or "bs"."""

    def __init__(self, name, kind, mode="Debug", env=None, flags=()):
        self.name, self.kind, self.mode, self.env, self.flags = name, kind, mode, env or {}, list(flags)


# The oracle, the configurations every program runs under, and the ones
# that only a mismatch pays for (upstream ReleaseSafe goes through LLVM
# and takes ~15 s per program).
UP_DEBUG = Config("zig", "zig")
UP_SAFE = Config("zig-safe", "zig", "ReleaseSafe")
# The LLVM backend in Debug: the second oracle when ReleaseSafe's
# optimizer crashes or times out on a program.
UP_LLVM = Config("zig-llvm", "zig", flags=["-fllvm"])
BS_DEBUG = Config("bs", "bs")
BS_SAFE = Config("bs-safe", "bs", "ReleaseSafe")
BS_NOINLINE = Config("bs-noinline", "bs", env={"BS_INLINE": "0"})
BS_INLINE_SAFE = Config("bs-inline-safe", "bs", env={"BS_INLINE_SAFE": "1"})
ALWAYS = [BS_DEBUG, BS_SAFE, BS_NOINLINE]
TRIAGE = [UP_SAFE, BS_INLINE_SAFE]
BY_NAME = {c.name: c for c in [UP_DEBUG, UP_SAFE, UP_LLVM, BS_DEBUG, BS_SAFE, BS_NOINLINE, BS_INLINE_SAFE]}
# What every configuration is compared with: upstream Debug, or with
# set_ref_env, bs itself with a pass turned off (no upstream run at all).
ORACLE = UP_DEBUG
REPORT = [UP_DEBUG, UP_SAFE]


def set_oracle(name):
    """Makes another upstream configuration (a finding's `oracle`, such
    as zig-safe) the oracle."""
    global ORACLE
    ORACLE = BY_NAME[name]


def set_ref_env(env):
    """Makes bs under `env` (such as {"BS_PROVE": "off"}) the oracle."""
    global ORACLE, TRIAGE, REPORT
    ORACLE = Config("bs-ref", "bs", env=env)
    BY_NAME[ORACLE.name] = ORACLE
    TRIAGE = [BS_INLINE_SAFE]
    REPORT = [ORACLE]


class Tools:
    def __init__(self, bs=None, zig=None):
        self.bs = os.path.abspath(bs or os.path.join(REPO_DIR, "zig-out", "bin", "bs"))
        self.zig = zig or shutil.which("zig") or "zig"


class Outcome:
    """`status`: "ok", "panic", "signal", "exit", "timeout", or
    "compile-error" / "compile-crash" / "compile-timeout" (no binary)."""

    def __init__(self, status, lines=(), code=0, detail=""):
        self.status, self.lines, self.code, self.detail = status, list(lines), code, detail

    def key(self):
        return (self.status, tuple(self.lines), self.code)

    def compiled(self):
        return not self.status.startswith("compile")

    def kind(self):
        """The shape of the outcome without the checksums."""
        if self.status == "panic":
            return "panic: " + self.lines[-1].split(": ", 1)[-1] if self.lines else "panic"
        return self.status

    def text(self):
        if not self.compiled():
            return f"[{self.status}]\n{self.detail}"
        return "\n".join(self.lines) + f"\n[{self.status} {self.code}]"

    def to_json(self):
        return {"status": self.status, "lines": self.lines, "code": self.code, "detail": self.detail[-4000:]}


PANIC = re.compile(r"^thread \d+ panic: (.*)$")


def normalize(stderr):
    lines = []
    for line in stderr.splitlines():
        if line.startswith("ck "):
            lines.append(line)
            continue
        m = PANIC.match(line)
        if m:
            lines.append("panic: " + m.group(1))
            break
    return lines


def compile_prog(tools, cfg, src, out, cache_dir):
    env = dict(os.environ)
    env.update(cfg.env)
    if cfg.kind == "bs":
        env["BS_CACHE"] = "off"
        argv = [tools.bs, "build-exe", src, f"-femit-bin={out}"]
    else:
        argv = [tools.zig, "build-exe", src, f"-femit-bin={out}", "--cache-dir", cache_dir]
    if cfg.mode != "Debug":
        argv.append(f"-O{cfg.mode}")
    argv += cfg.flags + TARGET_FLAGS
    try:
        p = subprocess.run(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                           errors="replace", timeout=COMPILE_TIMEOUT, cwd=os.path.dirname(src))
    except subprocess.TimeoutExpired:
        return Outcome("compile-timeout")
    if p.returncode == 0 and os.path.exists(out):
        return None
    err = p.stdout + p.stderr
    crash = p.returncode < 0 or "compiler bug" in err or "panic:" in err or "Segmentation fault" in err \
        or "unreachable code" in err and "error:" not in err
    if p.returncode != 0 and "error" not in err:
        crash = True
    return Outcome("compile-crash" if crash else "compile-error", code=p.returncode, detail=err)


def run_bin(path):
    try:
        p = subprocess.run([*RUNNER, path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors="replace",
                           timeout=RUN_TIMEOUT * (5 if RUNNER else 1), stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return Outcome("timeout")
    lines = normalize(p.stderr + p.stdout)
    if p.returncode == 0:
        st = "ok"
    elif lines and lines[-1].startswith("panic: "):
        st = "panic"
    elif p.returncode < 0:
        st = "signal"
    else:
        st = "exit"
    return Outcome(st, lines, p.returncode, detail=p.stderr[-2000:] if st != "ok" else "")


class HarnessError(Exception):
    """The run cannot be trusted (low disk, a program or binary that did
    not reach the disk). Never a pass: hunt.py counts it as harness-error
    and aborts the campaign when they repeat."""


MIN_FREE = 2 << 30
EXE_MAGIC = (b"\x7fELF", b"\xcf\xfa\xed\xfe")


def guard_disk():
    """Waits while the disk has less than MIN_FREE free (an hour at most,
    then HarnessError): a full disk leaves zeroed programs and binaries
    whose identical failures would compare equal."""
    waited = 0
    while True:
        st = os.statvfs(WORK)
        if st.f_bavail * st.f_frsize >= MIN_FREE:
            return
        if waited >= 3600:
            raise HarnessError(f"less than {MIN_FREE >> 30} GB free on {WORK} for an hour")
        time.sleep(60)
        waited += 60


def guard_file(path, what):
    """`path` exists and is neither empty nor all zero bytes."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        raise HarnessError(f"{what} {path}: {e}")
    if not data.strip(b"\0"):
        raise HarnessError(f"{what} {path} is empty or all zero bytes")
    return data


def run_config(tools, cfg, src, scratch):
    """Compiles `src` with `cfg` into `scratch` and runs it."""
    guard_disk()
    guard_file(src, "program")
    out = os.path.join(scratch, cfg.name)
    if os.path.exists(out):
        os.unlink(out)
    o = compile_prog(tools, cfg, src, out, os.path.join(scratch, "zig-cache"))
    if o is not None:
        return o
    if guard_file(out, "binary")[:4] not in EXE_MAGIC:
        raise HarnessError(f"binary {out} is not an executable")
    return run_bin(out)


def ast_check(tools, src):
    p = subprocess.run([tools.zig, "ast-check", src], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                       errors="replace", timeout=30)
    return p.returncode == 0, p.stderr


def lint_off(path):
    """Writes a `.bs.zon` that turns bs's lint off for the root files in
    `path` (and, inside this repository, under it): bs lints a project's
    files by default, and generated programs are not bs's style."""
    with open(os.path.join(path, ".bs.zon"), "w") as f:
        f.write(".{ .lint = false }\n")


def new_scratch(prefix="mchunt-"):
    base = os.path.join(WORK, "tmp")
    os.makedirs(base, exist_ok=True)
    lint_off(WORK)
    d = tempfile.mkdtemp(prefix=prefix, dir=base)
    lint_off(d)
    return d
