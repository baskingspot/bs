"""Compiling and running one program under each configuration (tools/mchunt).

A configuration is a compiler, an optimize mode and environment
variables. A run's outcome is what the program printed of its own
(`ck` lines) up to a panic, the panic message, and how it exited; stack
traces and thread ids are dropped, since they differ between compilers.
"""

import os
import re
import shutil
import subprocess
import tempfile

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(os.path.dirname(TOOL_DIR))
WORK = os.path.join(TOOL_DIR, ".work")

COMPILE_TIMEOUT = 120
RUN_TIMEOUT = 10


class Config:
    """`kind` is "zig" (upstream) or "zap"."""

    def __init__(self, name, kind, mode="Debug", env=None):
        self.name, self.kind, self.mode, self.env = name, kind, mode, env or {}


# The oracle, the configurations every program runs under, and the ones
# that only a mismatch pays for (upstream ReleaseSafe goes through LLVM
# and takes ~15 s per program).
UP_DEBUG = Config("zig", "zig")
UP_SAFE = Config("zig-safe", "zig", "ReleaseSafe")
ZAP_DEBUG = Config("zap", "zap")
ZAP_SAFE = Config("zap-safe", "zap", "ReleaseSafe")
ZAP_NOINLINE = Config("zap-noinline", "zap", env={"ZAP_INLINE": "0"})
ZAP_INLINE_SAFE = Config("zap-inline-safe", "zap", env={"ZAP_INLINE_SAFE": "1"})
ALWAYS = [ZAP_DEBUG, ZAP_SAFE, ZAP_NOINLINE]
TRIAGE = [UP_SAFE, ZAP_INLINE_SAFE]
BY_NAME = {c.name: c for c in [UP_DEBUG, UP_SAFE, ZAP_DEBUG, ZAP_SAFE, ZAP_NOINLINE, ZAP_INLINE_SAFE]}


class Tools:
    def __init__(self, zap=None, zig=None):
        self.zap = os.path.abspath(zap or os.path.join(REPO_DIR, "zig-out", "bin", "zap"))
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
    if cfg.kind == "zap":
        env["ZAP_CACHE"] = "off"
        argv = [tools.zap, "build-exe", src, f"-femit-bin={out}"]
    else:
        argv = [tools.zig, "build-exe", src, f"-femit-bin={out}", "--cache-dir", cache_dir]
    if cfg.mode != "Debug":
        argv.append(f"-O{cfg.mode}")
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
        p = subprocess.run([path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors="replace",
                           timeout=RUN_TIMEOUT, stdin=subprocess.DEVNULL)
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


def run_config(tools, cfg, src, scratch):
    """Compiles `src` with `cfg` into `scratch` and runs it."""
    out = os.path.join(scratch, cfg.name)
    if os.path.exists(out):
        os.unlink(out)
    o = compile_prog(tools, cfg, src, out, os.path.join(scratch, "zig-cache"))
    if o is not None:
        return o
    return run_bin(out)


def ast_check(tools, src):
    p = subprocess.run([tools.zig, "ast-check", src], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                       errors="replace", timeout=30)
    return p.returncode == 0, p.stderr


def new_scratch(prefix="mchunt-"):
    base = os.path.join(WORK, "tmp")
    os.makedirs(base, exist_ok=True)
    return tempfile.mkdtemp(prefix=prefix, dir=base)
