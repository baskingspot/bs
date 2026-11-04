#!/usr/bin/env python3
"""Random, well-defined Zig programs for differential testing (tools/mchunt).

`python3 gen.py SEED` prints one program. The program prints checkpoint
lines (`ck <n> <hash>`) of a running checksum to stderr and the final
checksum at exit. It is well defined by construction:

- every variable is initialized, no pointer outlives what it points to,
  and an aggregate is never passed by value or used as a result location
  while it is also reachable through another argument or the callee's
  globals (Zig's parameter and result-location aliasing is unspecified);
- loops are bounded (counters are read-only in the body) and calls form
  a DAG, so every program terminates quickly;
- most checked operations cannot fail (widened operands, halved
  operands, explicit guards, masked indices, divisors forced nonzero);
  a few are left unguarded on purpose, and a safety check that fires
  fires deterministically, so both compilers must panic the same way.

Unused locals, never-mutated `var`s, unused captures and labels are
compile errors in Zig, so declarations are emitted with placeholders and
resolved once their scope has been generated.
"""

import random
import sys

# ---------------------------------------------------------------- types


class Int:
    __slots__ = ("signed", "bits", "alias")

    def __init__(self, signed, bits, alias=None):
        self.signed, self.bits, self.alias = signed, bits, alias

    def name(self):
        return self.alias or ("i" if self.signed else "u") + str(self.bits)

    def min(self):
        return -(1 << (self.bits - 1)) if self.signed else 0

    def max(self):
        return (1 << (self.bits - 1)) - 1 if self.signed else (1 << self.bits) - 1

    def __eq__(self, o):
        return isinstance(o, Int) and o.name() == self.name()

    def __hash__(self):
        return hash(self.name())


class Bool:
    def name(self):
        return "bool"

    def __eq__(self, o):
        return isinstance(o, Bool)

    def __hash__(self):
        return 1


class Struct:
    def __init__(self, name, fields, layout):
        self.sname, self.fields, self.layout = name, fields, layout

    def name(self):
        return self.sname

    def field(self, f):
        return dict(self.fields)[f]


class Array:
    def __init__(self, elem, n):
        self.elem, self.n = elem, n

    def name(self):
        return f"[{self.n}]{self.elem.name()}"


class Slice:
    def __init__(self, elem, const):
        self.elem, self.const = elem, const

    def name(self):
        return ("[]const " if self.const else "[]") + self.elem.name()


class Ptr:
    def __init__(self, elem, const=False):
        self.elem, self.const = elem, const

    def name(self):
        return ("*const " if self.const else "*") + self.elem.name()


class Opt:
    def __init__(self, child):
        self.child = child

    def name(self):
        return "?" + self.child.name()


class Enum:
    def __init__(self, name, tags, tagty):
        self.ename, self.tags, self.tagty = name, tags, tagty

    def name(self):
        return self.ename


BOOL = Bool()
USIZE = Int(False, 64, "usize")
U64 = Int(False, 64)
U32 = Int(False, 32)


def is_int(t):
    return isinstance(t, Int)


def pow2(n):
    return n > 0 and n & (n - 1) == 0


# ---------------------------------------------------------------- scopes


class Var:
    """A name in scope. `kind`: global, cglobal (comptime constant),
    local, param, capture. `ro`: not assignable (params, captures, loop
    counters). Placeholders `{{D<id>}}`, `{{U<id>}}`, `{{C<id>}}` are
    resolved from `used` and `mutated` when the program is finished."""

    __slots__ = ("name", "ty", "kind", "ro", "used", "mutated", "id", "ct", "bound")

    def __init__(self, name, ty, kind, ro=False, ct=False):
        self.name, self.ty, self.kind, self.ro, self.ct = name, ty, kind, ro, ct
        self.used = self.mutated = False
        self.id = None
        self.bound = None


class Func:
    def __init__(self, name):
        self.name = name
        self.params = []  # (name, ty, comptime)
        self.ret = None  # type or None for void
        self.err = False
        self.opt = False
        self.pure = False
        self.inline = False
        self.cost = 1
        self.writes_globals = set()
        # Has a check that may fire: never called at comptime, where a
        # firing check is a compile error.
        self.risky = False


ERRS = ["Alpha", "Beta", "Gamma"]
# MCHUNT_DISABLE=statesw,bce: statement kinds to leave out (experiments).
DISABLED = set(filter(None, __import__("os").environ.get("MCHUNT_DISABLE", "").split(",")))


class Gen:
    def __init__(self, seed, size=1.0):
        self.r = random.Random(seed)
        self.seed = seed
        self.size = size
        self.n = 0
        self.out = []
        self.placeholders = {}  # id -> Var
        self.funcs = []
        self.globals = []
        self.structs = []
        self.enums = []
        self.rt_names = set()

    # ------------------------------------------------------------ utils
    def fresh(self, p):
        self.n += 1
        return f"{p}{self.n}"

    def chance(self, p):
        return self.r.random() < p

    def pick(self, xs):
        return self.r.choice(xs)

    def wpick(self, pairs):
        tot = sum(w for w, _ in pairs)
        x = self.r.random() * tot
        for w, v in pairs:
            x -= w
            if x <= 0:
                return v
        return pairs[-1][1]

    def place(self, var):
        self.n += 1
        var.id = self.n
        self.placeholders[var.id] = var
        return var.id

    # ------------------------------------------------------------ types
    def setup_types(self):
        r = self.r
        widths = [8, 16, 32, 64, 8, 32, 64]
        odd = [1, 2, 3, 4, 5, 6, 7, 9, 11, 12, 13, 15, 17, 20, 24, 31, 33, 40, 47, 48, 53, 56, 63]
        pool = {Int(False, 8), Int(True, 32), U64, USIZE, Int(True, 64), Int(False, 32), Int(True, 8), Int(False, 16), Int(True, 16)}
        for _ in range(r.randint(2, 5)):
            pool.add(Int(r.random() < 0.5, r.choice(odd)))
        for _ in range(r.randint(0, 2)):
            pool.add(Int(r.random() < 0.5, r.choice(widths)))
        if self.chance(0.15):
            pool.add(Int(self.chance(0.5), self.pick([128, 65, 72, 96, 127])))
        self.ints = sorted(pool, key=lambda t: (t.bits, t.signed, t.name()))
        self.c_ints = [t for t in self.ints if t.bits in (8, 16, 32, 64)]
        for i in range(r.randint(1, 3)):
            self.enums.append(self.make_enum(i))
        for i in range(r.randint(1, 4)):
            self.structs.append(self.make_struct(i))

    def make_enum(self, i):
        n = self.r.randint(2, 6)
        tagty = self.pick([Int(False, 8), Int(False, 3), Int(True, 8), Int(False, 16)])
        vals = sorted(self.r.sample(range(0, min(tagty.max(), 200) + 1), n))
        return Enum(f"E{i}", [(f"t{j}", v) for j, v in enumerate(vals)], tagty)

    def make_struct(self, i):
        layout = self.wpick([(5, "auto"), (3, "packed"), (2, "extern")])
        fields = []
        if layout == "packed":
            budget = self.pick([8, 16, 32, 64, 24, 13])
            used = 0
            while used < budget:
                b = min(budget - used, self.r.randint(1, 20))
                t = BOOL if b == 1 and self.chance(0.5) else Int(self.chance(0.5), b)
                fields.append((f"f{len(fields)}", t))
                used += b
        else:
            ints = self.c_ints if layout == "extern" else self.ints
            for j in range(self.r.randint(1, 5)):
                k = self.r.random()
                if k < 0.15 and self.structs and layout == "auto":
                    t = self.pick(self.structs)
                elif k < 0.3:
                    t = Array(self.pick(ints), self.r.randint(1, 5))
                elif k < 0.37 and layout == "auto":
                    t = BOOL
                else:
                    t = self.pick(ints)
                fields.append((f"f{j}", t))
        return Struct(f"S{i}", fields, layout)

    def rand_int_type(self):
        return self.pick(self.ints)

    def rand_value_type(self, depth=0):
        k = self.r.random()
        if k < 0.6 or depth > 1:
            return self.rand_int_type()
        if k < 0.7:
            return BOOL
        if k < 0.82:
            return Array(self.rand_value_type(depth + 1) if self.chance(0.2) else self.rand_int_type(), self.r.randint(1, 8))
        if k < 0.92:
            return self.pick(self.structs)
        return self.pick(self.enums)

    # ------------------------------------------------------------ literals
    def int_value(self, t):
        lo, hi = t.min(), t.max()
        k = self.r.random()
        if k < 0.12:
            return lo
        if k < 0.24:
            return hi
        if k < 0.34:
            return 0
        if k < 0.42:
            return min(1, hi)
        if k < 0.48 and t.signed:
            return -1
        if k < 0.55:
            return max(lo, min(hi, hi // 2 + self.r.randint(-1, 1)))
        if k < 0.75:
            return max(lo, min(hi, self.r.randint(-20, 40)))
        return self.r.randint(lo, hi)

    def lit(self, t, v=None):
        if v is None:
            v = self.int_value(t)
        s = str(v) if abs(v) < 4096 else (("-" if v < 0 else "") + hex(abs(v)))
        return f"@as({t.name()}, {s})"

    def bare(self, v):
        s = str(v) if abs(v) < 4096 else (("-" if v < 0 else "") + hex(abs(v)))
        return f"({s})" if v < 0 else s

    # ------------------------------------------------------------ conversions
    def conv(self, e, f, t):
        """Converts expression `e` of type `f` to type `t` (ints and bools)."""
        if isinstance(f, Bool) and isinstance(t, Bool):
            return e
        if isinstance(f, Bool):
            return self.conv(f"@as(u1, @intFromBool({e}))", Int(False, 1), t)
        if isinstance(t, Bool):
            return f"({e} != 0)"
        if f.name() == t.name():
            return e
        if f.signed != t.signed:
            mid = Int(t.signed, f.bits)
            e = f"@as({mid.name()}, @bitCast({e}))"
            f = mid
        if f.bits <= t.bits:
            return f"@as({t.name()}, {e})"
        return f"@as({t.name()}, @truncate({e}))"

    def to_u64(self, e, t):
        if isinstance(t, Enum):
            return self.conv(f"@intFromEnum({e})", t.tagty, U64)
        return self.conv(e, t, U64)

    # ------------------------------------------------------------ scope access
    def visible(self, ctx):
        vs = []
        for sc in ctx["scopes"]:
            vs.extend(sc)
        if not ctx["fn"].pure:
            vs.extend(self.globals)
        else:
            vs.extend(g for g in self.globals if g.kind == "cglobal")
        return vs

    def is_rt(self, text):
        """Whether `text` is certainly runtime-known: it names a runtime
        variable or calls a non-inline function outside a comptime block."""
        import re
        text = re.sub(r"\(comptime (ct\d+): \{[^{}]*\}\)", "", text)
        return any(w in self.rt_names for w in re.findall(r"[A-Za-z_]\w*", text))

    def trap_ok(self, ctx, *texts):
        """A check that may fire is allowed if its operands are runtime
        (else it would be a compile error); marks the function risky."""
        if any(self.is_rt(t) for t in texts):
            ctx["fn"].risky = True
            return True
        return False

    def use(self, v):
        v.used = True
        return v.name

    def paths(self, ctx, want, writable=False, depth=2):
        """Lists ways to reach a value of type class `want` (a predicate)
        from the variables in scope: (render-steps, type, base var).
        Steps are ('v',var) ('f',name) ('i',n) ('d',) ('pf',name) ('pi',n)."""
        res = []

        def walk(steps, t, base, d, through_ptr):
            if want(t):
                res.append((steps, t, base))
            if d <= 0:
                return
            if isinstance(t, Struct):
                for fn, ft in t.fields:
                    walk(steps + [("f", fn)], ft, base, d - 1, through_ptr)
            elif isinstance(t, Array):
                walk(steps + [("i", t.n)], t.elem, base, d - 1, through_ptr)
            elif isinstance(t, Ptr) and not (writable and t.const):
                walk(steps + [("d",)], t.elem, base, d - 1, True)

        for v in self.visible(ctx):
            if writable:
                if v.kind == "cglobal":
                    continue
                if (v.ro or v.kind == "param") and not isinstance(v.ty, Ptr):
                    continue
                if v.name in ctx.get("noassign", ()):
                    continue
            if isinstance(v.ty, Ptr):
                if writable and v.ty.const:
                    continue
                walk([("v", v), ("d",)], v.ty.elem, v, depth, True)
                if want(v.ty) and not writable:
                    res.append(([("v", v)], v.ty, v))
            else:
                if writable and isinstance(v.ty, Slice):
                    continue
                walk([("v", v)], v.ty, v, depth, False)
        return res

    def render_path(self, ctx, steps, writing=False):
        s = ""
        base = steps[0][1]
        packed_parent = False
        for st in steps:
            if st[0] == "v":
                s = self.use(st[1])
                if writing and not isinstance(st[1].ty, Ptr):
                    st[1].mutated = True
            elif st[0] == "f":
                s += "." + st[1]
            elif st[0] == "i":
                s += "[" + self.index(ctx, st[1]) + "]"
            elif st[0] == "d":
                s += ".*"
        return s

    # ------------------------------------------------------------ indices
    def index(self, ctx, n, allow_oob=True):
        """A usize expression in [0, n), occasionally (deliberately) not."""
        if allow_oob and self.chance(0.01):
            e = self.int_expr(ctx, USIZE, 1)
            if self.trap_ok(ctx, e):
                return f"({e} % {n + 1})"
            return f"({e} % {n})"
        bounded = [v for v in self.visible(ctx) if v.bound is not None and v.bound <= n and is_int(v.ty)]
        k = self.r.random()
        if bounded and k < 0.35:
            v = self.pick(bounded)
            return self.conv(self.use(v), v.ty, USIZE)
        if k < 0.5 or ctx["depth_budget"] <= 0:
            return str(self.r.randrange(n))
        t = self.rand_int_type()
        e = self.conv(self.int_expr(ctx, t, 1), t, USIZE)
        form = self.r.random()
        if form < 0.45:
            return f"({e} % {n})"
        if form < 0.65 and pow2(n):
            return f"({e} & {n - 1})"
        if form < 0.8:
            return f"@min({e}, {n - 1})"
        return f"({n - 1} - ({e} % {n}))"

    # ------------------------------------------------------------ expressions
    def int_expr(self, ctx, t, d):
        ctx["depth_budget"] -= 1
        try:
            if d <= 0 or ctx["depth_budget"] <= 0 or self.chance(0.25):
                return self.int_leaf(ctx, t)
            return self.int_op(ctx, t, d)
        finally:
            ctx["depth_budget"] += 1

    def int_leaf(self, ctx, t):
        k = self.r.random()
        if k < 0.2:
            return self.lit(t)
        cands = self.paths(ctx, lambda x: is_int(x) or isinstance(x, (Bool, Enum)))
        if not cands:
            return self.lit(t)
        steps, ft, base = self.pick(cands)
        e = self.render_path(ctx, steps)
        if isinstance(ft, Enum):
            return self.conv(f"@intFromEnum({e})", ft.tagty, t)
        return self.conv(e, ft, t)

    def sub(self, ctx, t, d):
        return self.int_expr(ctx, t, d - 1)

    def int_op(self, ctx, t, d):
        n = t.name()
        a = lambda: self.sub(ctx, t, d)
        ops = [
            (10, "wrap"), (5, "sat"), (8, "checked"), (6, "bit"), (5, "shift"),
            (3, "div"), (2, "minmax"), (2, "unary"), (2, "count"), (3, "cond"),
            (3, "conv"), (2, "ovf"), (2, "switch"), (2, "call"), (1, "math"),
            (1, "opt"), (1, "block"), (1, "slice"), (1, "ctcall"), (1, "swap"),
            (2, "ident"),
        ]
        op = self.wpick(ops)
        if op == "wrap":
            o = self.pick(["+%", "-%", "*%"])
            return f"({a()} {o} {self.rhs(ctx, t, d)})"
        if op == "sat":
            o = self.pick(["+|", "-|", "*|", "<<|"])
            if o == "<<|":
                st = self.pick([Int(False, 8), U32, Int(False, 3)])
                return f"({a()} <<| {self.sub(ctx, st, d)})"
            return f"({a()} {o} {self.rhs(ctx, t, d)})"
        if op == "checked":
            return self.checked(ctx, t, d)
        if op == "bit":
            o = self.pick(["&", "|", "^"])
            x, y = a(), self.rhs(ctx, t, d)
            return f"({x} {o} {y})"
        if op == "shift" and t.bits > 1:
            return self.shift(ctx, t, d)
        if op == "div":
            return self.div(ctx, t, d)
        if op == "minmax":
            # @min/@max narrow their type to a comptime-known operand's range.
            return f"@as({n}, @{self.pick(['min', 'max'])}({a()}, {self.rhs(ctx, t, d)}))"
        if op == "unary":
            k = self.r.random()
            if k < 0.4:
                return f"(~{a()})"
            if k < 0.7:
                return f"(-%{a()})"
            if t.signed and k < 0.8:
                # Checked negation: minInt panics, deterministically.
                x = a()
                return f"(-{x})" if self.trap_ok(ctx, x) else f"(-%{x})"
            if not t.signed:
                st = Int(True, t.bits)
                return f"@abs({self.sub(ctx, st, d)})"
            return f"(~{a()})"
        if op == "count":
            k = self.r.random()
            st = self.rand_int_type()
            if k < 0.25:
                return self.conv(f"@clz({self.sub(ctx, st, d)})", Int(False, st.bits.bit_length()), t)
            if k < 0.5:
                return self.conv(f"@ctz({self.sub(ctx, st, d)})", Int(False, st.bits.bit_length()), t)
            if k < 0.7:
                return self.conv(f"@popCount({self.sub(ctx, st, d)})", Int(False, st.bits.bit_length()), t)
            if k < 0.85 and t.bits % 8 == 0:
                return f"@byteSwap({a()})"
            return f"@bitReverse({a()})"
        if op == "cond":
            return f"(if ({self.bool_expr(ctx, d - 1)}) {a()} else {a()})"
        if op == "conv":
            st = self.rand_int_type()
            if self.chance(0.3) and st.bits > t.bits and not t.signed:
                # @intCast that always fits: masked below 2^t.bits.
                m = (1 << t.bits) - 1 if not st.signed else min((1 << t.bits) - 1, st.max())
                return f"@as({n}, @intCast({self.sub(ctx, st, d)} & {self.bare(m)}))"
            return self.conv(self.sub(ctx, st, d), st, t)
        if op == "ovf":
            o = self.pick(["add", "sub", "mul", "shl"])
            if o == "shl":
                if t.bits == 1:
                    return a()
                # Upstream does not check @shlWithOverflow's amount (LLVM
                # makes an oversized one poison), so it must stay in range.
                sh = self.shift_amount(ctx, t, d, may_trap=False)
                e = f"@shlWithOverflow({a()}, {sh})"
            else:
                e = f"@{o}WithOverflow({a()}, {self.rhs(ctx, t, d)})"
            if self.chance(0.6):
                return f"{e}[0]"
            return self.conv(f"{e}[1]", Int(False, 1), t)
        if op == "switch":
            return self.switch_expr(ctx, t, d)
        if op == "call":
            e = self.call_expr(ctx, t, d)
            if e:
                return e
        if op == "math":
            o = self.pick(["add", "sub", "mul"])
            return f"(std.math.{o}({n}, {a()}, {self.rhs(ctx, t, d)}) catch {self.lit(t)})"
        if op == "opt":
            ot = Opt(t)
            cands = self.paths(ctx, lambda x: isinstance(x, Opt) and is_int(x.child))
            if cands:
                steps, ft, _ = self.pick(cands)
                e = self.render_path(ctx, steps)
                c = ft.child
                if self.chance(0.5):
                    return self.conv(f"({e} orelse {self.lit(c)})", c, t)
                # Unwrapping with `.?` behind a null check.
                return self.conv(f"(if ({e} != null) {e}.? else {self.lit(c)})", c, t)
        if op == "block":
            lbl = self.fresh("blk")
            tmp = self.fresh("t")
            return f"({lbl}: {{ const {tmp} = {a()}; break :{lbl} {tmp} {self.pick(['+%', '^', '*%'])} {tmp}; }})"
        if op == "slice":
            cands = self.paths(ctx, lambda x: isinstance(x, Slice) and is_int(x.elem), depth=0)
            if cands:
                steps, ft, _ = self.pick(cands)
                e = self.render_path(ctx, steps)
                k = self.r.random()
                if k < 0.3:
                    return self.conv(f"{e}.len", USIZE, t)
                i = self.conv(self.sub(ctx, Int(False, 8), d), Int(False, 8), USIZE)
                if k < 0.97 or not self.trap_ok(ctx, i, e):
                    return self.conv(f"(if ({i} < {e}.len) {e}[{i}] else {self.lit(ft.elem)})", ft.elem, t)
                # Off by one on purpose: panics when the index equals the length.
                return self.conv(f"(if ({i} <= {e}.len) {e}[{i}] else {self.lit(ft.elem)})", ft.elem, t)
        if op == "ctcall":
            e = self.ct_call(ctx, t)
            if e:
                return e
        if op == "ident":
            # Shapes the rewrite rules fold: identities, a value against
            # itself, unsigned against 0, operations on constants.
            x = a()
            k = self.r.randrange(12)
            if t.signed and t.bits == 1 and k in (1, 8, 9):
                k = 0  # `1` is not an i1
            if k == 0:
                return f"({x} +% 0)"
            if k == 1:
                return f"({x} *% 1)"
            if k == 2:
                return f"({x} -% {x})"
            if k == 3:
                return f"({x} ^ {x})"
            if k == 4:
                return f"({x} & {self.bare(t.max()) if not t.signed else '-1'})"
            if k == 5:
                return f"({x} | {x})"
            if k == 6:
                return f"(if ({x} == {x}) {a()} else {a()})"
            if k == 7 and not t.signed:
                return f"(if ({x} >= 0) {a()} else {a()})"
            if k == 8:
                return f"@divTrunc({x}, 1)" if t.signed else f"({x} / 1)"
            if k == 9:
                return f"@addWithOverflow({x}, 0)[0]"
            if k == 10 and t.bits > 1:
                return f"({x} >> 0)"
            return f"(({self.lit(t)} +% {self.bare(self.int_value(t))}) ^ {x})"
        if op == "swap":
            # Mixed-signedness reinterpretation through @bitCast.
            st = Int(not t.signed, t.bits)
            return f"@as({n}, @bitCast({self.sub(ctx, st, d)}))"
        return f"({a()} +% {self.rhs(ctx, t, d)})"

    def rhs(self, ctx, t, d):
        if self.chance(0.3):
            return self.bare(self.int_value(t))
        return self.sub(ctx, t, d)

    def checked(self, ctx, t, d):
        n = t.name()
        o = self.pick(["+", "-", "*"])
        k = self.r.random()
        need = t.bits * 2 + 1 if o == "*" else t.bits + 1
        if k < 0.3 and need <= 128 and (t.signed or o != "-"):
            # Widened operands cannot overflow; truncate back.
            w = Int(t.signed, need)
            x, y = self.sub(ctx, t, d), self.sub(ctx, t, d)
            return f"@as({n}, @truncate(@as({w.name()}, {x}) {o} @as({w.name()}, {y})))"
        if k < 0.5 and o != "*" and t.bits > 1:
            x, y = self.sub(ctx, t, d), self.sub(ctx, t, d)
            if t.signed or o == "+":
                # Halved operands cannot overflow.
                return f"(({x} >> 1) {o} ({y} >> 1))"
            return self.absdiff(x, y, n)
        if k < 0.65 and not t.signed:
            x, y = self.sub(ctx, t, d), self.sub(ctx, t, d)
            lbl, l, rr = self.fresh("b"), self.fresh("l"), self.fresh("r")
            if o == "+":
                return f"({lbl}: {{ const {l} = {x}; const {rr} = {y}; break :{lbl} if ({l} <= std.math.maxInt({n}) - {rr}) {l} + {rr} else {l} -% {rr}; }})"
            if o == "-":
                return f"({lbl}: {{ const {l} = {x}; const {rr} = {y}; break :{lbl} if ({l} >= {rr}) {l} - {rr} else {rr} - {l}; }})"
            half = max(1, t.bits // 2)
            m = (1 << half) - 1
            return f"(({x} & {m}) * ({y} & {m}))"
        if k < 0.8 and 3 <= t.bits < 128:
            # Small constant operand with a range guard on the other.
            c = self.r.randint(0, 3)
            x = self.sub(ctx, t, d)
            lbl, l = self.fresh("b"), self.fresh("l")
            if o == "+":
                return f"({lbl}: {{ const {l} = {x}; break :{lbl} if ({l} < {self.bare(t.max() - c)}) {l} + {c} else {l}; }})"
            if o == "-":
                return f"({lbl}: {{ const {l} = {x}; break :{lbl} if ({l} > {self.bare(t.min() + c)}) {l} - {c} else {l}; }})"
            return f"({lbl}: {{ const {l} = {x}; break :{lbl} if ({l} > {self.bare(t.min() // 2 + 1 if t.signed else 0)} and {l} < {self.bare(t.max() // 2)}) {l} * 2 else {l}; }})"
        # Unguarded: may overflow, which must panic the same way everywhere.
        x = self.sub(ctx, t, d)
        y = self.bare(self.r.randint(0, max(0, min(2, t.max())))) if self.chance(0.6) else self.sub(ctx, t, d)
        if not self.trap_ok(ctx, x, y):
            o += "%"
        return f"({x} {o} {y})"

    def absdiff(self, x, y, n):
        lbl, l, rr = self.fresh("b"), self.fresh("l"), self.fresh("r")
        return f"({lbl}: {{ const {l} = {x}; const {rr} = {y}; break :{lbl} if ({l} >= {rr}) {l} - {rr} else {rr} - {l}; }})"

    def shift_amount(self, ctx, t, d, may_trap=True):
        lt = f"std.math.Log2Int({t.name()})"
        if pow2(t.bits) and self.chance(0.4):
            return self.bare(self.r.randrange(t.bits))
        st = self.rand_int_type()
        e = self.conv(self.sub(ctx, st, d), st, U64)
        if pow2(t.bits):
            return f"@as({lt}, @truncate({e}))"
        if may_trap and self.chance(0.02) and self.trap_ok(ctx, e):
            # May reach the bit width: the shift's safety check must fire.
            m = (1 << (t.bits - 1).bit_length()) - 1
            return f"@as({lt}, @intCast({e} & {m}))"
        return f"@as({lt}, @intCast({e} % {t.bits}))"

    def shift(self, ctx, t, d):
        x = self.sub(ctx, t, d)
        k = self.r.random()
        sh = self.shift_amount(ctx, t, d)
        if k < 0.45:
            return f"({x} << {sh})"
        if k < 0.95:
            return f"({x} >> {sh})"
        return f"@shlExact({x} & 1, {sh})" if t.bits > 2 and not t.signed else f"({x} << {sh})"

    def div(self, ctx, t, d):
        x = self.sub(ctx, t, d)
        if t.bits == 1:
            return x
        y = self.sub(ctx, t, d)
        if t.signed:
            # A positive divisor: never zero, never -1.
            nz = f"(({y} & {self.bare(t.max())}) | 1)" if t.bits > 1 else None
            if nz is None:
                return x
            f = self.pick(["@divTrunc", "@divFloor", "@rem", "@mod"])
            if self.chance(0.03) and self.trap_ok(ctx, y):
                nz = f"({y} | 1)"  # may be -1: minInt / -1 panics in @divTrunc
            return f"{f}({x}, {nz})"
        nz = self.pick([f"({y} | 1)", f"(if ({y} == 0) 1 else {y})", f"@max({y}, 1)"])
        if self.chance(0.02) and self.trap_ok(ctx, y):
            nz = y  # may be zero: must panic the same way
        o = self.pick(["/", "%", "@divTrunc", "@divFloor", "@rem", "@mod"])
        if o in ("/", "%"):
            return f"({x} {o} {nz})"
        return f"{o}({x}, {nz})"

    def switch_expr(self, ctx, t, d):
        st = self.rand_int_type()
        if st.bits < 3:
            st = Int(False, 8)
        x = self.sub(ctx, st, d)
        prongs = self.switch_prongs(st)
        body = ", ".join(f"{p} => {self.sub(ctx, t, d)}" for p in prongs)
        return f"(switch ({x}) {{ {body}, else => {self.sub(ctx, t, d)} }})"

    def switch_prongs(self, st):
        """Disjoint singletons, lists and ranges that never cover every
        value of `st` (an `else` prong follows)."""
        lo, hi = st.min(), st.max()
        cap = min(hi - lo, 300)
        pts = set(lo + self.r.randint(0, cap) for _ in range(self.r.randint(1, 6)))
        if self.chance(0.5):
            pts |= {0, 1, hi, lo}
        pts = sorted(pts)
        lit = lambda v: str(v) if abs(v) < 4096 else ("-" if v < 0 else "") + hex(abs(v))
        prongs, covered, i = [], 0, 0
        while i < len(pts):
            if i + 1 < len(pts) and self.chance(0.3):
                prongs.append(f"{lit(pts[i])}...{lit(pts[i + 1])}")
                covered += pts[i + 1] - pts[i] + 1
                i += 2
            else:
                group = [lit(pts[i])]
                i += 1
                while i < len(pts) and self.chance(0.3):
                    group.append(lit(pts[i]))
                    i += 1
                covered += len(group)
                prongs.append(", ".join(group))
        if covered >= hi - lo + 1:
            prongs = prongs[:-1]
        # Callers switch on types of at least 3 bits, so one value leaves
        # the `else` reachable.
        return prongs or [lit(lo)]

    def bool_expr(self, ctx, d):
        ctx["depth_budget"] -= 1
        try:
            k = self.r.random()
            if d <= 0 or ctx["depth_budget"] <= 0 or k < 0.1:
                cands = self.paths(ctx, lambda x: isinstance(x, Bool))
                if cands and self.chance(0.7):
                    return self.render_path(ctx, self.pick(cands)[0])
                t = self.rand_int_type()
                return f"({self.int_leaf(ctx, t)} {self.pick(['<', '<=', '==', '!=', '>', '>='])} {self.int_leaf(ctx, t)})"
            if k < 0.6:
                t = self.rand_int_type()
                return f"({self.int_expr(ctx, t, d - 1)} {self.pick(['<', '<=', '==', '!=', '>', '>='])} {self.rhs(ctx, t, d)})"
            if k < 0.7:
                return f"!{self.bool_expr(ctx, d - 1)}"
            if k < 0.85:
                return f"({self.bool_expr(ctx, d - 1)} {self.pick(['and', 'or'])} {self.bool_expr(ctx, d - 1)})"
            if k < 0.92:
                cands = self.paths(ctx, lambda x: isinstance(x, Opt))
                if cands:
                    return f"({self.render_path(ctx, self.pick(cands)[0])} {self.pick(['==', '!='])} null)"
            if k < 0.97:
                cands = self.paths(ctx, lambda x: isinstance(x, Enum))
                if cands:
                    steps, et, _ = self.pick(cands)
                    return f"({self.render_path(ctx, steps)} == .{self.pick(et.tags)[0]})"
            return self.pick(["true", "false"]) if self.chance(0.3) else f"({self.int_leaf(ctx, U32)} > {self.r.randint(0, 9)})"
        finally:
            ctx["depth_budget"] += 1

    def value_expr(self, ctx, t, d):
        """An expression of any value type `t` (aggregates as literals)."""
        if is_int(t):
            return self.int_expr(ctx, t, d)
        if isinstance(t, Bool):
            return self.bool_expr(ctx, d)
        if isinstance(t, Enum):
            cands = self.paths(ctx, lambda x: x.name() == t.name())
            if cands and self.chance(0.5):
                return self.render_path(ctx, self.pick(cands)[0])
            if self.chance(0.3):
                # A tag from an integer that is known valid via a switch.
                return f"@as({t.name()}, .{self.pick(t.tags)[0]})"
            return f"{t.name()}.{self.pick(t.tags)[0]}"
        if isinstance(t, Struct):
            cands = self.paths(ctx, lambda x: x.name() == t.name())
            if cands and self.chance(0.3):
                return self.render_path(ctx, self.pick(cands)[0])
            inits = ", ".join(f".{fn} = {self.value_expr(ctx, ft, d - 1)}" for fn, ft in t.fields)
            return f"{t.name()}{{ {inits} }}"
        if isinstance(t, Array):
            if self.chance(0.2):
                return f"@as({t.name()}, @splat({self.value_expr(ctx, t.elem, d - 1)}))"
            return f"{t.name()}{{ {', '.join(self.value_expr(ctx, t.elem, d - 1) for _ in range(t.n))} }}"
        if isinstance(t, Opt):
            if self.chance(0.3):
                return "null"
            return self.value_expr(ctx, t.child, d)
        raise ValueError(t)

    # ------------------------------------------------------------ calls
    def callable(self, ctx, pred):
        me = ctx["fn"]
        out = []
        for f in self.funcs:
            if f is me or not pred(f):
                continue
            if me.pure and not f.pure:
                continue
            if f.cost * ctx["mult"] + ctx["cost"] > ctx["cost_cap"]:
                continue
            out.append(f)
        return out

    def args(self, ctx, f, d):
        """Arguments for `f`. By-value aggregates are never reachable
        through a pointer argument or a global the callee may touch."""
        out = []
        aggr_bases = set()
        ptr_bases = set()
        for name, t, ct in f.params:
            if ct:
                out.append(self.lit(t))
            elif is_int(t) or isinstance(t, (Bool, Enum)):
                out.append(self.value_expr(ctx, t, d - 1))
            elif isinstance(t, Ptr):
                a = self.addr_of(ctx, t.elem, avoid=aggr_bases, const=t.const)
                if a is None:
                    return None
                out.append(a[0])
                ptr_bases.add(a[1])
            elif isinstance(t, Slice):
                a = self.slice_of(ctx, t, avoid=aggr_bases)
                if a is None:
                    return None
                out.append(a[0])
                ptr_bases.add(a[1])
            else:
                # Aggregates by value: a local copy or a fresh literal.
                cands = [p for p in self.paths(ctx, lambda x: x.name() == t.name(), depth=1)
                         if p[2].kind in ("local", "capture") and p[2].name not in ptr_bases
                         and not isinstance(p[2].ty, Ptr)]
                if cands and self.chance(0.6):
                    p = self.pick(cands)
                    aggr_bases.add(p[2].name)
                    out.append(self.render_path(ctx, p[0]))
                else:
                    out.append(self.value_expr(ctx, t, min(d, 1)))
        return out

    def call(self, ctx, f, d):
        # A call abandoned halfway must not leave its arguments' uses
        # and mutations behind: they decide `var`/`const` and `_ = x;`.
        snap = [(v, v.used, v.mutated) for v in self.visible(ctx)]
        a = self.args(ctx, f, d)
        if a is None:
            for v, u, m in snap:
                v.used, v.mutated = u, m
            return None
        ctx["cost"] += f.cost * ctx["mult"]
        ctx["fn"].risky |= f.risky
        return f"{f.name}({', '.join(a)})"

    def call_expr(self, ctx, t, d):
        fs = self.callable(ctx, lambda f: f.ret is not None and (is_int(f.ret) or isinstance(f.ret, Bool)))
        if not fs:
            return None
        f = self.pick(fs)
        c = self.call(ctx, f, d)
        if c is None:
            return None
        rt = f.ret
        if f.err:
            if ctx["fn"].err and self.chance(0.3):
                return self.conv(f"(try {c})", rt, t)
            if self.chance(0.5):
                return self.conv(f"({c} catch {self.lit(rt) if is_int(rt) else 'false'})", rt, t)
            e = self.fresh("e")
            arms = self.err_arms(rt)
            return self.conv(f"({c} catch |{e}| switch ({e}) {{ {arms} }})", rt, t)
        if f.opt:
            if self.chance(0.6):
                return self.conv(f"({c} orelse {self.lit(rt) if is_int(rt) else 'true'})", rt, t)
            v = self.fresh("v")
            return self.conv(f"(if ({c}) |{v}| {v} else {self.lit(rt) if is_int(rt) else 'true'})", rt, t)
        return self.conv(c, rt, t)

    def err_arms(self, rt):
        lit = (lambda: self.lit(rt)) if is_int(rt) else (lambda: self.pick(["true", "false"]))
        if self.chance(0.5):
            return ", ".join(f"error.{e} => {lit()}" for e in ERRS)
        return f"error.{self.pick(ERRS)} => {lit()}, else => {lit()}"

    def ct_call(self, ctx, t):
        """`comptime f(literals)` of a pure function: the comptime
        evaluator against the same function compiled for run time."""
        fs = [f for f in self.funcs if f is not ctx["fn"] and f.pure and not f.risky and f.ret is not None and is_int(f.ret)
              and not f.err and not f.opt and all(is_int(pt) or isinstance(pt, Bool) for _, pt, _ in f.params)]
        if not fs:
            return None
        f = self.pick(fs)
        args = ", ".join(self.lit(pt) if is_int(pt) else self.pick(["true", "false"]) for _, pt, _ in f.params)
        lbl = self.fresh("ct")
        return self.conv(f"(comptime {lbl}: {{ @setEvalBranchQuota(100000); break :{lbl} {f.name}({args}); }})", f.ret, t)

    def addr_of(self, ctx, t, avoid=(), const=False):
        """`&lvalue` of type *t: a local, a global, a field or an element."""
        cands = [p for p in self.paths(ctx, lambda x: x.name() == t.name(), writable=not const, depth=2)
                 if p[2].name not in avoid and not any(s[0] == "d" for s in p[0])
                 and not (p[2].kind == "cglobal") and not self.in_packed(p[0])]
        cands = [p for p in cands if p[2].kind not in ("param",) and not p[2].ro]
        if not cands:
            return None
        steps, _, base = self.pick(cands)
        return "&" + self.render_path(ctx, steps, writing=not const) if not const else "&" + self.render_path(ctx, steps), base.name

    def in_packed(self, steps):
        t = None
        for s in steps:
            if s[0] == "v":
                t = s[1].ty
            elif s[0] == "f":
                if isinstance(t, Struct) and t.layout == "packed":
                    return True
                t = t.field(s[1])
            elif s[0] == "i":
                t = t.elem
            elif s[0] == "d":
                t = t.elem
        return False

    def slice_of(self, ctx, st, avoid=()):
        cands = [p for p in self.paths(ctx, lambda x: isinstance(x, Array) and x.elem.name() == st.elem.name(),
                                       writable=not st.const, depth=1)
                 if p[2].name not in avoid and p[2].kind != "cglobal" and not self.in_packed(p[0])
                 and not any(s[0] == "d" for s in p[0])]
        cands = [p for p in cands if p[2].kind != "param" and not p[2].ro]
        if not cands:
            return None
        steps, at, base = self.pick(cands)
        arr = self.render_path(ctx, steps, writing=not st.const)
        n = at.n
        k = self.r.random()
        if k < 0.3:
            return f"{arr}[0..]", base.name
        if k < 0.5:
            lo = self.r.randint(0, n)
            hi = self.r.randint(lo, n)
            return f"{arr}[{lo}..{hi}]", base.name
        x = self.conv(self.int_expr(ctx, Int(False, 8), 1), Int(False, 8), USIZE)
        y = self.conv(self.int_expr(ctx, Int(False, 8), 1), Int(False, 8), USIZE)
        a = f"({x} % {n + 1})"
        b = f"({y} % {n + 1})"
        return f"{arr}[@min({a}, {b})..@max({a}, {b})]", base.name

    # ------------------------------------------------------------ statements
    def emit(self, ctx, line):
        self.out.append("    " * ctx["indent"] + line)

    def declare(self, ctx, name, t, init, ro=False, force_var=False):
        v = Var(name, t, "local", ro=ro)
        if force_var or self.is_rt(init):
            self.rt_names.add(name)
        pid = self.place(v)
        kw = "var" if force_var else f"{{{{D{pid}}}}}"
        if force_var:
            v.mutated = True
        self.emit(ctx, f"{kw} {name}: {t.name()} = {init};{{{{U{pid}}}}}")
        ctx["scopes"][-1].append(v)
        return v

    def block(self, ctx, n, extra_vars=()):
        ctx["scopes"].append(list(extra_vars))
        ctx["indent"] += 1
        for _ in range(n):
            self.stmt(ctx)
        ctx["indent"] -= 1
        ctx["scopes"].pop()

    def sink(self, ctx, e, t):
        """Folds a value into the function's observable state."""
        acc = ctx["acc"]
        if not ctx["fn"].pure and self.chance(0.4):
            self.emit(ctx, f"mix({self.to_u64(e, t)});")
        else:
            acc.used = acc.mutated = True
            self.emit(ctx, f"{acc.name} = ({acc.name} ^ {self.to_u64(e, t)}) *% 0x9E3779B97F4A7C15;")

    def stmt(self, ctx):
        d = ctx["depth"]
        ctx["stmts"] += 1
        ctx["cost"] += ctx["mult"]
        w = [
            (10, "decl"), (9, "assign"), (6, "sink"), (4, "if"), (3, "while"), (3, "for"),
            (2, "switch"), (3, "callstmt"), (2, "ptr"), (2, "aggr"), (1, "slice"), (1, "opt"),
            (1, "defer"), (1, "guard"), (1, "labeled"), (1, "inlinefor"), (1, "brk"), (1, "ret"),
            (1, "statesw"), (2, "bce"), (2, "copy"), (2, "alias"), (2, "repeat"),
        ]
        if d >= 3 or ctx["stmts"] > ctx["stmt_cap"]:
            w = [(10, "decl"), (9, "assign"), (6, "sink")]
        if DISABLED:
            w = [x for x in w if x[1] not in DISABLED]
        k = self.wpick(w)
        getattr(self, "s_" + k)(ctx)

    def s_decl(self, ctx):
        t = self.rand_int_type() if self.chance(0.85) else BOOL
        name = self.fresh("v")
        e = self.value_expr(ctx, t, self.r.randint(1, 4))
        self.declare(ctx, name, t, e)

    def s_assign(self, ctx):
        cands = self.paths(ctx, lambda x: is_int(x) or isinstance(x, (Bool, Enum)), writable=True)
        if not cands:
            return self.s_decl(ctx)
        steps, t, base = self.pick(cands)
        lhs = self.render_path(ctx, steps, writing=True)
        if isinstance(t, Enum):
            self.emit(ctx, f"{lhs} = {self.value_expr(ctx, t, 1)};")
            return
        if isinstance(t, Bool):
            self.emit(ctx, f"{lhs} = {self.bool_expr(ctx, 2)};")
            return
        k = self.r.random()
        if k < 0.4:
            self.emit(ctx, f"{lhs} = {self.int_expr(ctx, t, self.r.randint(1, 4))};")
        elif k < 0.85:
            op = self.pick(["+%=", "-%=", "*%=", "|=", "&=", "^=", "+|=", "-|="])
            self.emit(ctx, f"{lhs} {op} {self.int_expr(ctx, t, 2)};")
        elif k < 0.95 and t.bits > 1:
            op = self.pick(["<<=", ">>="])
            self.emit(ctx, f"{lhs} {op} {self.shift_amount(ctx, t, 2)};")
        else:
            # Checked compound assignment; may overflow (rarely).
            ctx["fn"].risky = True
            op = self.pick(["+=", "-="])
            self.emit(ctx, f"{lhs} {op} {self.r.randint(0, min(1, t.max()))};")

    def s_sink(self, ctx):
        cands = self.paths(ctx, lambda x: is_int(x) or isinstance(x, (Bool, Enum)))
        if cands and self.chance(0.6):
            steps, t, _ = self.pick(cands)
            self.sink(ctx, self.render_path(ctx, steps), t)
        else:
            t = self.rand_int_type()
            self.sink(ctx, self.int_expr(ctx, t, 3), t)

    def nested(self, ctx, n, extra=(), mult=1):
        ctx["depth"] += 1
        old = ctx["mult"]
        ctx["mult"] *= mult
        self.block(ctx, n, extra)
        ctx["mult"] = old
        ctx["depth"] -= 1

    def body_len(self):
        return self.r.randint(1, 4)

    def s_if(self, ctx):
        self.emit(ctx, f"if ({self.bool_expr(ctx, 3)}) {{")
        self.nested(ctx, self.body_len())
        if self.chance(0.5):
            self.emit(ctx, "} else {")
            self.nested(ctx, self.body_len())
        self.emit(ctx, "}")

    def loop_body(self, ctx, n, extra, mult):
        old = ctx.get("in_loop", 0)
        ctx["in_loop"] = old + 1
        self.nested(ctx, n, extra, mult)
        ctx["in_loop"] = old

    def trip(self, ctx):
        """A trip count: (bound for ranges, expression text)."""
        if self.chance(0.4):
            n = self.r.randint(0, 9)
            return n, str(n)
        b = self.r.randint(1, 12)
        t = self.rand_int_type()
        return b, f"({self.conv(self.int_expr(ctx, t, 2), t, USIZE)} % {b + 1})"

    def s_while(self, ctx):
        b, n = self.trip(ctx)
        it = self.pick([USIZE, U32, Int(False, 8), Int(True, 16)])
        i = self.fresh("it")
        lim = self.fresh("n")
        lv = self.declare(ctx, lim, USIZE, n, ro=True)
        lv.used = True
        v = Var(i, it, "local", ro=True)
        self.rt_names.add(i)
        pid = self.place(v)
        v.mutated = v.used = True
        self.emit(ctx, f"var {i}: {it.name()} = 0;")
        cond = f"{self.conv(i, it, USIZE)} < {lim}"
        step = self.pick([f"{i} += 1", f"{i} +%= 1"])
        self.emit(ctx, f"while ({cond}) : ({step}) {{")
        v.bound = b
        ctx["scopes"][-1].append(v)
        self.loop_body(ctx, self.body_len(), (), max(b, 1))
        ctx["scopes"][-1].remove(v)
        self.emit(ctx, "}")

    def s_for(self, ctx):
        k = self.r.random()
        if k < 0.4:
            b, n = self.trip(ctx)
            i = self.fresh("it")
            v = Var(i, USIZE, "capture", ro=True)
            self.rt_names.add(i)
            v.bound = b
            pid = self.place(v)
            self.emit(ctx, f"for (0..{n}) |{{{{C{pid}}}}}| {{")
            self.loop_body(ctx, self.body_len(), [v], max(b, 1))
            self.emit(ctx, "}")
            return
        cands = self.paths(ctx, lambda x: isinstance(x, (Array, Slice)), depth=1)
        if not cands:
            return self.s_sink(ctx)
        steps, at, base = self.pick(cands)
        n = at.n if isinstance(at, Array) else 8
        ptr_capture = isinstance(at, Array) and self.chance(0.3) and not base.ro and base.kind not in ("param", "cglobal") \
            and not self.in_packed(steps) and not any(s[0] == "d" for s in steps)
        if isinstance(at, Slice) and not at.const and self.chance(0.3):
            ptr_capture = True
        ptr_capture = ptr_capture and is_int(at.elem)
        e = self.render_path(ctx, steps, writing=ptr_capture)
        x = self.fresh("x")
        xv = Var(x, Ptr(at.elem) if ptr_capture else at.elem, "capture", ro=True)
        self.rt_names.add(x)
        xid = self.place(xv)
        extra = [xv]
        caps = f"{'*' if ptr_capture else ''}{{{{C{xid}}}}}"
        src = (f"&{e}" if isinstance(at, Array) else e) if ptr_capture else e
        if self.chance(0.5):
            i = self.fresh("j")
            iv = Var(i, USIZE, "capture", ro=True)
            self.rt_names.add(i)
            iv.bound = n if isinstance(at, Array) else None
            iid = self.place(iv)
            extra.append(iv)
            self.emit(ctx, f"for ({src}{{{{I{iid}}}}}) |{caps}{{{{J{iid}}}}}| {{")
        else:
            self.emit(ctx, f"for ({src}) |{caps}| {{")
        if ptr_capture:
            # `|*_|` is invalid: write through the element pointer first.
            xv.used = True
            ctx["indent"] += 1
            self.emit(ctx, f"{x}.* {self.pick(['+%=', '^=', '=', '*%=', '|='])} {self.int_expr(ctx, at.elem, 2)};")
            ctx["indent"] -= 1
        self.loop_body(ctx, self.body_len(), extra, n)
        self.emit(ctx, "}")

    def s_brk(self, ctx):
        if not ctx.get("in_loop") or ctx.get("in_defer"):
            return self.s_assign(ctx)
        self.emit(ctx, f"if ({self.bool_expr(ctx, 2)}) {self.pick(['break', 'continue'])};")

    def s_ret(self, ctx):
        if ctx.get("in_defer") or ctx["depth"] == 0:
            return self.s_sink(ctx)
        f = ctx["fn"]
        if f.err and self.chance(0.5):
            self.emit(ctx, f"if ({self.bool_expr(ctx, 2)}) return error.{self.pick(ERRS)};")
            return
        self.emit(ctx, f"if ({self.bool_expr(ctx, 2)}) return {self.ret_value(ctx)};")

    def s_guard(self, ctx):
        """`if (i >= n) <exit>;` then `a[i]`: a check that dominates the
        index (what bounds-check elimination by proof reasons about)."""
        arrs = self.paths(ctx, lambda x: isinstance(x, Array), depth=1)
        if not arrs:
            return self.s_sink(ctx)
        steps, at, base = self.pick(arrs)
        t = self.rand_int_type()
        i = self.fresh("gi")
        iv = self.declare(ctx, i, USIZE, self.conv(self.int_expr(ctx, t, 2), t, USIZE) + f" % {at.n + self.r.randint(0, 3)}")
        iv.used = True
        n = at.n
        off = 0 if self.chance(0.95) or not self.trap_ok(ctx, self.out[-1]) else 1  # off by one on purpose, rarely
        self.emit(ctx, f"if ({i} < {n + off}) {{")
        ctx["depth"] += 1
        ctx["scopes"].append([])
        ctx["indent"] += 1
        a = self.render_path(ctx, steps)
        if isinstance(at.elem, (Struct, Array)) or not (is_int(at.elem) or isinstance(at.elem, (Bool, Enum))):
            self.sink(ctx, f"@as(u64, {i})", U64)
        else:
            self.sink(ctx, f"{a}[{i}]", at.elem)
            if self.chance(0.5) and n > 1:
                self.sink(ctx, f"{a}[{i} -| 1]", at.elem)
        ctx["indent"] -= 1
        ctx["scopes"].pop()
        ctx["depth"] -= 1
        self.emit(ctx, "}")

    def s_bce(self, ctx):
        """Index patterns that a bounds-check prover must get right."""
        arrs = self.paths(ctx, lambda x: isinstance(x, Array) and (is_int(x.elem)), depth=1)
        if not arrs:
            return self.s_sink(ctx)
        steps, at, base = self.pick(arrs)
        a = self.render_path(ctx, steps)
        n = at.n
        i = self.fresh("k")
        k = self.r.random()
        if k < 0.3:
            # Descending loop: the index is n-1 down to 0.
            self.emit(ctx, f"var {i}: usize = {n};")
            self.emit(ctx, f"while ({i} > 0) {{")
            self.emit(ctx, f"    {i} -= 1;")
            ctx["indent"] += 1
            self.sink(ctx, f"{a}[{i}]", at.elem)
            ctx["indent"] -= 1
            self.emit(ctx, "}")
        elif k < 0.6:
            # Pairs a[j], a[j+1] for j < n-1.
            self.emit(ctx, f"var {i}: usize = 0;")
            self.emit(ctx, f"while ({i} + 1 < {n}) : ({i} += 1) {{")
            ctx["indent"] += 1
            self.sink(ctx, f"{a}[{i}] +% {a}[{i} + 1]", at.elem)
            ctx["indent"] -= 1
            self.emit(ctx, "}")
        else:
            # A runtime length clamp, then a loop up to it (inclusive, sometimes wrongly).
            m = self.fresh("m")
            t = self.rand_int_type()
            self.emit(ctx, f"const {m}: usize = @min({self.conv(self.int_expr(ctx, t, 2), t, USIZE)}, {n});")
            op = "<" if self.chance(0.97) or not self.trap_ok(ctx, self.out[-1]) else "<="
            self.emit(ctx, f"var {i}: usize = 0;")
            self.emit(ctx, f"while ({i} {op} {m}) : ({i} += 1) {{")
            ctx["indent"] += 1
            self.sink(ctx, f"{a}[{i}]", at.elem)
            ctx["indent"] -= 1
            self.emit(ctx, "}")

    def s_copy(self, ctx):
        """Copies a whole aggregate between two places (what scalar
        replacement of aggregates rewrites)."""
        srcs = self.paths(ctx, lambda x: isinstance(x, (Struct, Array)), depth=2)
        if not srcs:
            return self.s_aggr(ctx)
        steps, t, base = self.pick(srcs)
        dsts = [p for p in self.paths(ctx, lambda x: x.name() == t.name(), writable=True, depth=2)
                if p[2] is not base]
        if not dsts or self.chance(0.3):
            name = self.fresh("a")
            v = self.declare(ctx, name, t, self.render_path(ctx, steps))
            # Change the copy, then observe both.
            fp = self.paths_of(ctx, v, lambda x: is_int(x), writable=True)
            if fp:
                fsteps, ft, _ = self.pick(fp)
                self.emit(ctx, f"{self.render_path(ctx, fsteps, writing=True)} {self.pick(['+%=', '^=', '='])} {self.int_expr(ctx, ft, 2)};")
            return
        dsteps, _, _ = self.pick(dsts)
        self.emit(ctx, f"{self.render_path(ctx, dsteps, writing=True)} = {self.render_path(ctx, steps)};")

    def paths_of(self, ctx, v, want, writable=False):
        return [p for p in self.paths(ctx, want, writable=writable) if p[2] is v]

    def s_alias(self, ctx):
        """Writes through one pointer and reads through another to the
        same place, or to elements that may be the same."""
        t = self.rand_int_type()
        cands = [p for p in self.paths(ctx, lambda x: x.name() == t.name() or isinstance(x, Array) and is_int(x.elem),
                                       writable=True, depth=2)
                 if not any(s[0] == "d" for s in p[0]) and not self.in_packed(p[0])
                 and p[2].kind not in ("param", "cglobal") and not p[2].ro]
        if not cands:
            return self.s_ptr(ctx)
        steps, pt, base = self.pick(cands)
        if isinstance(pt, Array):
            arr = self.render_path(ctx, steps, writing=True)
            et = pt.elem
            i, j = self.index(ctx, pt.n, allow_oob=False), self.index(ctx, pt.n, allow_oob=False)
            a_, b_ = f"&{arr}[{i}]", f"&{arr}[{j}]"
        else:
            et = pt
            lv = self.render_path(ctx, steps, writing=True)
            a_, b_ = f"&{lv}", f"&{lv}"
        pa, pb = self.fresh("pa"), self.fresh("pb")
        self.emit(ctx, f"const {pa}: *{et.name()} = {a_};")
        self.emit(ctx, f"const {pb}: *{et.name()} = {b_};")
        for _ in range(self.r.randint(2, 4)):
            w = self.pick([pa, pb])
            k = self.r.random()
            if k < 0.5:
                self.emit(ctx, f"{w}.* {self.pick(['=', '+%=', '^=', '*%=', '-%='])} {self.int_expr(ctx, et, 1)};")
            else:
                self.sink(ctx, f"{self.pick([pa, pb])}.*", et)
        self.sink(ctx, f"{pa}.* +% {pb}.*", et)

    def s_repeat(self, ctx):
        """The same expression before and after a statement that may
        change what it reads: common subexpressions must not be shared
        across a write or a call."""
        t = self.rand_int_type()
        e = self.int_expr(ctx, t, 3)
        a, b = self.fresh("cs"), self.fresh("cs")
        self.emit(ctx, f"const {a}: {t.name()} = {e};")
        self.wpick([(3, self.s_assign), (1, self.s_callstmt), (1, self.s_sink)])(ctx)
        self.emit(ctx, f"const {b}: {t.name()} = {e};")
        self.sink(ctx, f"{a} ^ {b}", t) if self.chance(0.5) else self.sink(ctx, f"{a} -% {b}", t)

    def s_switch(self, ctx):
        if self.chance(0.3):
            cands = self.paths(ctx, lambda x: isinstance(x, Enum))
            if cands:
                steps, et, _ = self.pick(cands)
                self.emit(ctx, f"switch ({self.render_path(ctx, steps)}) {{")
                tags = [t for t, _ in et.tags]
                self.r.shuffle(tags)
                cut = self.r.randint(1, len(tags))
                ctx["indent"] += 1
                for t in tags[:cut]:
                    self.emit(ctx, f".{t} => {{")
                    self.nested(ctx, self.body_len())
                    self.emit(ctx, "},")
                if cut < len(tags):
                    self.emit(ctx, "else => {")
                    self.nested(ctx, 1)
                    self.emit(ctx, "},")
                ctx["indent"] -= 1
                self.emit(ctx, "}")
                return
        st = self.rand_int_type()
        if st.bits < 3:
            st = Int(False, 8)
        self.emit(ctx, f"switch ({self.int_expr(ctx, st, 2)}) {{")
        ctx["indent"] += 1
        for p in self.switch_prongs(st):
            self.emit(ctx, f"{p} => {{")
            self.nested(ctx, self.body_len())
            self.emit(ctx, "},")
        c = self.fresh("c")
        cv = Var(c, st, "capture", ro=True)
        cid = self.place(cv)
        self.emit(ctx, f"else => {{{{P{cid}}}}}{{")
        self.nested(ctx, self.body_len(), [cv])
        self.emit(ctx, "},")
        ctx["indent"] -= 1
        self.emit(ctx, "}")

    def s_statesw(self, ctx):
        """A labeled switch driven by `continue :label` (a state machine)."""
        lbl = self.fresh("sm")
        steps = self.fresh("st")
        self.emit(ctx, f"var {steps}: u32 = 0;")
        nstates = self.r.randint(2, 5)
        self.emit(ctx, f"{lbl}: switch ({self.conv(self.int_expr(ctx, Int(False, 8), 1), Int(False, 8), Int(False, 8))} % {nstates}) {{")
        ctx["indent"] += 1
        for sidx in range(nstates):
            self.emit(ctx, f"{sidx} => {{")
            ctx["indent"] += 1
            self.emit(ctx, f"{steps} += 1;")
            ctx["depth"] += 1
            old = ctx["mult"]
            ctx["mult"] *= 6
            ctx["scopes"].append([])
            for _ in range(self.r.randint(0, 2)):
                self.stmt(ctx)
            ctx["scopes"].pop()
            ctx["mult"] = old
            ctx["depth"] -= 1
            nxt = self.conv(self.int_expr(ctx, Int(False, 8), 1), Int(False, 8), Int(False, 8))
            self.emit(ctx, f"if ({steps} < {self.r.randint(2, 6)}) continue :{lbl} ({nxt} % {nstates}) else break :{lbl};")
            ctx["indent"] -= 1
            self.emit(ctx, "},")
        self.emit(ctx, "else => unreachable,")
        ctx["indent"] -= 1
        self.emit(ctx, "}")

    def s_callstmt(self, ctx):
        fs = self.callable(ctx, lambda f: True)
        if not fs:
            return self.s_sink(ctx)
        f = self.pick(fs)
        c = self.call(ctx, f, 2)
        if c is None:
            return self.s_sink(ctx)
        if f.ret is None:
            if f.err:
                if ctx["fn"].err and self.chance(0.4):
                    self.emit(ctx, f"try {c};")
                else:
                    e = self.fresh("e")
                    ev = Var(e, None, "capture", ro=True)
                    self.emit(ctx, f"{c} catch |{e}| {{")
                    ctx["indent"] += 1
                    self.sink(ctx, f"@as(u8, switch ({e}) {{ {', '.join(f'error.{x} => {j + 1}' for j, x in enumerate(ERRS))} }})", Int(False, 8))
                    ctx["indent"] -= 1
                    self.emit(ctx, "};")
            else:
                self.emit(ctx, f"{c};")
            return
        rt = f.ret
        name = self.fresh("r")
        if f.err:
            if ctx["fn"].err and self.chance(0.3):
                v = self.declare(ctx, name, rt, f"try {c}")
            elif self.chance(0.5):
                v_ = self.fresh("v")
                e = self.fresh("e")
                self.emit(ctx, f"if ({c}) |{v_}| {{")
                ctx["indent"] += 1
                self.sink(ctx, v_, rt) if not isinstance(rt, (Struct, Array)) else self.sink_value(ctx, v_, rt)
                ctx["indent"] -= 1
                self.emit(ctx, f"}} else |{e}| {{")
                ctx["indent"] += 1
                self.sink(ctx, f"@as(u8, switch ({e}) {{ {', '.join(f'error.{x} => {j + 7}' for j, x in enumerate(ERRS))} }})", Int(False, 8))
                ctx["indent"] -= 1
                self.emit(ctx, "}")
                return
            else:
                e = self.fresh("e")
                v = self.declare(ctx, name, rt, f"{c} catch |{e}| switch ({e}) {{ {self.err_arms(rt)} }}")
        elif f.opt:
            ov = self.declare(ctx, name, Opt(rt), c)
            return
        else:
            v = self.declare(ctx, name, rt, c)
        if isinstance(rt, (Struct, Array)):
            self.sink_value(ctx, self.use(v), rt)

    def sink_value(self, ctx, e, t, depth=0):
        """Folds every scalar of an aggregate into the checksum."""
        if is_int(t) or isinstance(t, (Bool, Enum)):
            return self.sink(ctx, e, t)
        if isinstance(t, Struct):
            for fn, ft in t.fields:
                self.sink_value(ctx, f"{e}.{fn}", ft, depth + 1)
            return
        if isinstance(t, Array):
            x = self.fresh("x")
            self.emit(ctx, f"for ({e}) |{x}| {{")
            ctx["indent"] += 1
            self.sink_value(ctx, x, t.elem, depth + 1)
            ctx["indent"] -= 1
            self.emit(ctx, "}")
            return
        if isinstance(t, Opt):
            x = self.fresh("x")
            self.emit(ctx, f"if ({e}) |{x}| {{")
            ctx["indent"] += 1
            self.sink_value(ctx, x, t.child, depth + 1)
            ctx["indent"] -= 1
            self.emit(ctx, "} else {")
            ctx["indent"] += 1
            self.sink(ctx, "@as(u8, 0x5a)", Int(False, 8))
            ctx["indent"] -= 1
            self.emit(ctx, "}")

    def s_ptr(self, ctx):
        t = self.rand_value_type() if self.chance(0.4) else self.rand_int_type()
        a = self.addr_of(ctx, t)
        if a is None:
            return self.s_decl(ctx)
        p = self.fresh("p")
        pv = self.declare(ctx, p, Ptr(t), a[0])
        # A write through the pointer, then a read through the original
        # path or a second pointer (aliasing).
        if is_int(t):
            self.emit(ctx, f"{self.use(pv)}.* {self.pick(['+%=', '^=', '=', '*%='])} {self.int_expr(ctx, t, 2)};")
            if self.chance(0.5):
                self.sink(ctx, f"{self.use(pv)}.*", t)

    def s_aggr(self, ctx):
        t = self.wpick([(3, "struct"), (3, "array"), (1, "enum")])
        if t == "struct" and self.structs:
            t = self.pick(self.structs)
        elif t == "enum":
            t = self.pick(self.enums)
        else:
            t = Array(self.rand_int_type() if self.chance(0.8) else self.pick(self.structs), self.r.randint(1, 8))
        name = self.fresh("a")
        self.declare(ctx, name, t, self.value_expr(ctx, t, 2))

    def s_slice(self, ctx):
        st = Slice(self.rand_int_type(), self.chance(0.5))
        s = self.slice_of(ctx, st)
        if s is None:
            return self.s_aggr(ctx)
        name = self.fresh("s")
        sv = self.declare(ctx, name, st, s[0])
        if not st.const and self.chance(0.5):
            i = self.conv(self.int_expr(ctx, Int(False, 8), 1), Int(False, 8), USIZE)
            sv.used = True
            self.emit(ctx, f"if ({i} < {name}.len) {name}[{i}] {self.pick(['=', '+%=', '^='])} {self.int_expr(ctx, st.elem, 2)};")

    def s_opt(self, ctx):
        t = self.rand_int_type()
        name = self.fresh("o")
        init = "null" if self.chance(0.3) else self.int_expr(ctx, t, 2)
        ov = self.declare(ctx, name, Opt(t), init)
        k = self.r.random()
        if k < 0.4:
            ov.mutated = ov.used = True
            self.emit(ctx, f"if ({self.bool_expr(ctx, 2)}) {name} = {'null' if self.chance(0.4) else self.int_expr(ctx, t, 2)};")
        x = self.fresh("x")
        xv = Var(x, t, "capture", ro=True)
        xid = self.place(xv)
        ov.used = True
        self.emit(ctx, f"if ({name}) |{{{{C{xid}}}}}| {{")
        self.nested(ctx, self.body_len(), [xv])
        self.emit(ctx, "}")

    def s_defer(self, ctx):
        if ctx.get("in_defer"):
            return self.s_sink(ctx)
        kw = "errdefer" if ctx["fn"].err and self.chance(0.4) else "defer"
        if ctx["fn"].pure and kw == "errdefer":
            kw = "defer"
        self.emit(ctx, f"{kw} {{")
        ctx["in_defer"] = True
        old = ctx.get("in_loop", 0)
        ctx["in_loop"] = 0
        ctx["depth"] += 1
        ctx["scopes"].append([])
        ctx["indent"] += 1
        for _ in range(self.r.randint(1, 2)):
            self.stmt_simple(ctx)
        ctx["indent"] -= 1
        ctx["scopes"].pop()
        ctx["depth"] -= 1
        ctx["in_loop"] = old
        ctx["in_defer"] = False
        self.emit(ctx, "}")

    def stmt_simple(self, ctx):
        self.wpick([(2, self.s_assign), (2, self.s_sink), (1, self.s_decl)])(ctx)

    def s_labeled(self, ctx):
        lbl = self.fresh("L")
        if ctx.get("in_defer"):
            return self.s_sink(ctx)
        t = self.rand_int_type()
        name = self.fresh("v")
        v = Var(name, t, "local")
        pid = self.place(v)
        self.emit(ctx, f"{{{{D{pid}}}}} {name}: {t.name()} = {lbl}: {{")
        ctx["depth"] += 1
        ctx["scopes"].append([])
        ctx["indent"] += 1
        for _ in range(self.r.randint(0, 2)):
            self.stmt_simple(ctx)
        self.emit(ctx, f"if ({self.bool_expr(ctx, 2)}) break :{lbl} {self.int_expr(ctx, t, 2)};")
        self.emit(ctx, f"break :{lbl} {self.int_expr(ctx, t, 2)};")
        ctx["indent"] -= 1
        ctx["scopes"].pop()
        ctx["depth"] -= 1
        self.emit(ctx, f"}};{{{{U{pid}}}}}")
        ctx["scopes"][-1].append(v)

    def s_inlinefor(self, ctx):
        n = self.r.randint(1, 4)
        i = self.fresh("ci")
        v = Var(i, USIZE, "capture", ro=True, ct=True)
        v.bound = n
        pid = self.place(v)
        if self.chance(0.5):
            self.emit(ctx, f"inline for (0..{n}) |{{{{C{pid}}}}}| {{")
        else:
            vals = ", ".join(str(self.r.randint(0, 50)) for _ in range(n))
            v.bound = None
            v.ty = Int(False, 8)
            self.emit(ctx, f"inline for ([_]u8{{ {vals} }}) |{{{{C{pid}}}}}| {{")
        old = ctx.get("in_loop", 0)
        ctx["in_loop"] = 0  # break/continue in inline for: keep it simple
        self.nested(ctx, self.r.randint(1, 2), [v], n)
        ctx["in_loop"] = old
        self.emit(ctx, "}")

    # ------------------------------------------------------------ functions
    def ret_value(self, ctx):
        f = ctx["fn"]
        acc = ctx["acc"]
        acc.used = True
        t = f.ret
        if t is None:
            return ""
        if is_int(t):
            e = f"{self.conv(acc.name, U64, t)}"
            if self.chance(0.6):
                e = f"({e} ^ {self.int_expr(ctx, t, 2)})"
            if f.opt and self.chance(0.3):
                return "null"
            return e
        if isinstance(t, Bool):
            if f.opt and self.chance(0.3):
                return "null"
            return f"(({acc.name} & 1) == 1) != {self.bool_expr(ctx, 2)}"
        if isinstance(t, Struct):
            inits = []
            for fn, ft in t.fields:
                if is_int(ft):
                    inits.append(f".{fn} = {self.conv(acc.name, U64, ft)} ^ {self.int_expr(ctx, ft, 1)}")
                else:
                    inits.append(f".{fn} = {self.value_expr(ctx, ft, 1)}")
            return f".{{ {', '.join(inits)} }}"
        if isinstance(t, Array):
            if is_int(t.elem):
                return f".{{ {', '.join(self.conv(f'({acc.name} >> {j * 3})', U64, t.elem) for j in range(t.n))} }}"
            return self.value_expr(ctx, t, 1)
        return self.value_expr(ctx, t, 1)

    def gen_function(self, idx, budget):
        f = Func(f"f{idx}")
        r = self.r
        if self.chance(0.3):
            # A tiny helper: inlined within the budget, often with
            # constant arguments, so the rewrite rules see its body.
            budget = r.randint(0, 2)
        f.pure = self.chance(0.4)
        f.inline = self.chance(0.12)
        k = r.random()
        if k < 0.6:
            f.ret = self.rand_int_type()
        elif k < 0.67:
            f.ret = BOOL
        elif k < 0.77:
            f.ret = self.pick(self.structs) if self.chance(0.6) else Array(self.rand_int_type(), r.randint(1, 6))
        elif k < 0.85 and not f.pure:
            f.ret = None
        else:
            f.ret = self.rand_int_type()
        if f.ret is not None and (is_int(f.ret) or isinstance(f.ret, Bool)):
            f.err = self.chance(0.2)
            f.opt = not f.err and self.chance(0.12)
        elif f.ret is None:
            f.err = self.chance(0.2)
        params = []
        for j in range(r.randint(0, 4)):
            k = r.random()
            if k < 0.55:
                t = self.rand_int_type()
            elif k < 0.6:
                t = BOOL
            elif k < 0.75:
                t = Ptr(self.rand_value_type() if self.chance(0.3) else self.rand_int_type(), const=self.chance(0.25))
            elif k < 0.83:
                t = Slice(self.rand_int_type(), self.chance(0.5))
            elif k < 0.93:
                t = self.pick(self.structs) if self.chance(0.6) else Array(self.rand_int_type(), r.randint(1, 6))
            else:
                t = self.pick(self.enums)
            ct = is_int(t) and not f.inline and self.chance(0.1)
            params.append((self.fresh("p"), t, ct))
        f.params = params

        start = len(self.out)
        ret = ""
        if f.ret is not None:
            ret = f.ret.name()
            if f.opt:
                ret = "?" + ret
        else:
            ret = "void"
        if f.err:
            ret = "E!" + ret
        ps = ", ".join(f"{'comptime ' if ct else ''}{n}: {t.name()}" for n, t, ct in params)
        self.out.append(f"{'inline ' if f.inline else ''}fn {f.name}({ps}) {ret} {{")
        pvars = []
        for n, t, ct in params:
            v = Var(n, t, "param", ro=True, ct=ct)
            if not ct and not f.inline:
                self.rt_names.add(n)
            if isinstance(t, Slice):
                v.bound = None
            pid = self.place(v)
            pvars.append(v)
            self.out.append(f"    {{{{U{pid}}}}}")
        ctx = {
            "fn": f, "scopes": [pvars], "indent": 1, "depth": 0, "mult": 1, "cost": 1,
            "cost_cap": 30000, "stmts": 0, "stmt_cap": budget, "depth_budget": 6,
        }
        acc = Var(self.fresh("acc"), U64, "local")
        acc.used = True
        acc.ro = True
        ctx["acc"] = acc
        aid = self.place(acc)
        self.out.append(f"    {{{{D{aid}}}}} {acc.name}: u64 = {hex(self.r.getrandbits(64))};{{{{U{aid}}}}}")
        while ctx["stmts"] < budget:
            self.stmt(ctx)
        if f.ret is None:
            self.emit(ctx, f"mix({acc.name});")
        else:
            self.emit(ctx, f"return {self.ret_value(ctx)};")
        self.out.append("}")
        self.out.append("")
        # `_ = p;` for params is emitted as a placeholder line already.
        f.cost = max(1, ctx["cost"])
        self.funcs.append(f)
        if not f.inline:
            self.rt_names.add(f.name)
        return f

    # ------------------------------------------------------------ program
    def global_init(self, t):
        if is_int(t):
            return self.lit(t)
        if isinstance(t, Bool):
            return self.pick(["true", "false"])
        if isinstance(t, Enum):
            return f".{self.pick(t.tags)[0]}"
        if isinstance(t, Struct):
            return f".{{ {', '.join(f'.{fn} = {self.global_init(ft)}' for fn, ft in t.fields)} }}"
        if isinstance(t, Array):
            return f".{{ {', '.join(self.global_init(t.elem) for _ in range(t.n))} }}"
        if isinstance(t, Opt):
            return "null" if self.chance(0.3) else self.global_init(t.child)
        raise ValueError(t)

    def generate(self):
        self.setup_types()
        out = self.out
        out.append(f"// mchunt seed {self.seed}")
        out.append('const std = @import("std");')
        out.append("")
        out.append(f"const E = error{{ {', '.join(ERRS)} }};")
        for e in self.enums:
            tags = ", ".join(f"{n} = {v}" for n, v in e.tags)
            out.append(f"const {e.ename} = enum({e.tagty.name()}) {{ {tags} }};")
        for s in self.structs:
            kw = {"auto": "struct", "packed": "packed struct", "extern": "extern struct"}[s.layout]
            out.append(f"const {s.sname} = {kw} {{ {', '.join(f'{n}: {t.name()}' for n, t in s.fields)} }};")
        out.append("")
        for i in range(self.r.randint(4, 10)):
            t = self.rand_value_type()
            if self.chance(0.15):
                t = Opt(self.rand_int_type())
            v = Var(f"g{i}", t, "global")
            self.rt_names.add(v.name)
            v.used = True
            self.globals.append(v)
            out.append(f"var g{i}: {t.name()} = {self.global_init(t)};")
        for i in range(self.r.randint(0, 3)):
            t = self.rand_int_type()
            v = Var(f"K{i}", t, "cglobal", ro=True, ct=True)
            self.globals.append(v)
            out.append(f"const K{i}: {t.name()} = {self.lit(t)};")
        out.append("")
        out.append("var ck: u64 = 0xcbf29ce484222325;")
        out.append("fn mix(v: u64) void {")
        out.append("    ck = (ck ^ v) *% 0x100000001b3;")
        out.append("    ck ^= ck >> 29;")
        out.append("}")
        out.append("")
        nf = max(2, int(self.r.randint(3, 9) * self.size))
        for i in range(nf):
            self.gen_function(i, max(3, int(self.r.randint(4, 16) * self.size)))
        # main: call every function; checkpoint after each.
        out.append("pub fn main() void {")
        mctx = {
            "fn": Func("main"), "scopes": [[]], "indent": 1, "depth": 0, "mult": 1, "cost": 1,
            "cost_cap": 10 ** 7, "stmts": 0, "stmt_cap": 0, "depth_budget": 4,
        }
        macc = Var("macc", U64, "local", ro=True)
        macc.used = macc.mutated = True
        mctx["acc"] = macc
        out.append("    var macc: u64 = 0;")
        out.append("    _ = &macc;")
        for j, f in enumerate(self.funcs):
            self.out.append(f"    // call {f.name}")
            for _ in range(self.r.randint(1, 2)):
                mctx["cost"] = 1
                old = len(self.out)
                c = self.call(mctx, f, 2)
                if c is None:
                    continue
                if f.ret is None and not f.err:
                    self.emit(mctx, f"{c};")
                elif f.ret is None:
                    self.emit(mctx, f"{c} catch |err| mix(@as(u64, switch (err) {{ {', '.join(f'error.{x} => {k + 1}' for k, x in enumerate(ERRS))} }}));")
                else:
                    name = self.fresh("m")
                    rt = f.ret
                    if f.err:
                        init = f"{c} catch |err| switch (err) {{ {self.err_arms(rt)} }}"
                        v = self.declare(mctx, name, rt, init)
                    elif f.opt:
                        v = self.declare(mctx, name, Opt(rt), c)
                        rt = Opt(rt)
                    else:
                        v = self.declare(mctx, name, rt, c)
                    v.used = True
                    self.sink_value_main(mctx, name, rt)
            self.emit(mctx, f'std.debug.print("ck {j} {{x}}\\n", .{{ck}});')
            # Some globals change between calls.
            if self.chance(0.4):
                mctx["stmts"] = 0
                self.s_assign(mctx)
        for g in self.globals:
            if g.kind == "global":
                self.sink_value_main(mctx, g.name, g.ty)
        self.emit(mctx, "mix(macc);")
        self.emit(mctx, 'std.debug.print("ck end {x}\\n", .{ck});')
        out.append("}")
        return self.resolve("\n".join(out) + "\n")

    def sink_value_main(self, ctx, e, t):
        old = self.chance
        self.sink_value(ctx, e, t)

    def resolve(self, text):
        """Fills in the placeholders. Whether a name is used is read off
        the text (a declaration names it once; a capture placeholder not
        at all), so abandoned partial expressions cannot leave a stale
        flag behind; whether a `var` is mutated comes from the flags."""
        import re

        counts = {}
        for w in re.findall(r"[A-Za-z_]\w*", text):
            counts[w] = counts.get(w, 0) + 1

        def rep(m):
            kind, pid = m.group(1), int(m.group(2))
            v = self.placeholders[pid]
            n = counts.get(v.name, 0)
            if kind == "D":
                return "var" if v.mutated else "const"
            if kind == "U":
                return "" if n > 1 else f" _ = {v.name};"
            if kind == "C":
                return v.name if n > 0 else "_"
            if kind == "I":
                return ", 0.." if n > 0 else ""
            if kind == "J":
                return f", {v.name}" if n > 0 else ""
            if kind == "P":
                return f"|{v.name}| " if n > 0 else ""
            raise ValueError(kind)

        text = re.sub(r"\{\{([DUCPIJ])(\d+)\}\}", rep, text)
        # Lines that held only a parameter placeholder.
        return "\n".join(l for l in text.split("\n") if l.strip() != "") + "\n"


def generate(seed, size=1.0):
    return Gen(seed, size).generate()


if __name__ == "__main__":
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else random.randrange(1 << 32)
    size = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
    sys.stdout.write(generate(seed, size))
