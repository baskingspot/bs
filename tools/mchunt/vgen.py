"""Random @Vector programs for the differential hunter (tools/mchunt).

`hunt.py --kind vector` uses this instead of gen.py. A program is a set
of noinline test functions, each building vectors from runtime inputs
and running them through lane ops, wrapping and saturating arithmetic,
shifts by splats and by vectors, compares, select, shuffles (negative
and undefined mask lanes), @reduce of every op, casts and bitcasts,
memory, calls and comptime. Main calls each one and prints the running
checksum after it (`ck <n> <hash>`), as gen.py's programs do.

Every program is well defined: shift amounts are in range, divisors are
nonzero and never -1, checked arithmetic cannot overflow, float to int
conversions are clamped, undefined shuffle lanes are never read. Float
results hash every NaN alike, and @min/@max results add +0.0 so that a
signed zero cannot depend on operand order; float vectors are never
bitcast to integers, so NaN payloads stay unobservable.
"""

import random
import re
import sys

LENS = [1, 2, 3, 4, 5, 8, 16, 17, 32, 33, 64]
INT_BITS = [1, 2, 7, 8, 8, 16, 16, 24, 32, 32, 33, 64, 64, 65]
FLOAT_BITS = [16, 32, 32, 64, 64]
MAX_BYTES = 512


class VT:
    """A vector type: `kind` is "int", "float" or "bool"."""

    def __init__(self, kind, n, bits=1, signed=False):
        self.kind, self.n, self.bits, self.signed = kind, n, bits, signed

    def elem(self):
        if self.kind == "bool":
            return "bool"
        if self.kind == "float":
            return f"f{self.bits}"
        return f"{'i' if self.signed else 'u'}{self.bits}"

    def name(self):
        return f"@Vector({self.n}, {self.elem()})"

    def with_n(self, n):
        return VT(self.kind, n, self.bits, self.signed)

    def nbytes(self):
        return self.n * max(1, (self.bits + 7) // 8)

    def key(self):
        return (self.kind, self.n, self.bits, self.signed)

    def __eq__(self, o):
        return isinstance(o, VT) and self.key() == o.key()

    def __hash__(self):
        return hash(self.key())

    def imin(self):
        return -(1 << (self.bits - 1)) if self.signed else 0

    def imax(self):
        return (1 << (self.bits - 1)) - 1 if self.signed else (1 << self.bits) - 1


PRELUDE = r"""
var ck: u64 = 0xcbf29ce484222325;
fn mix(v: u64) void {
    ck = (ck ^ v) *% 0x100000001b3;
    ck ^= ck >> 29;
}
fn mixv(v: anytype) void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .vector => |vi| {
            const a: [vi.len]vi.child = v;
            for (a) |e| mixv(e);
        },
        .array => for (v) |e| mixv(e),
        .int => |ii| {
            const u: @Int(.unsigned, ii.bits) = @bitCast(v);
            if (comptime ii.bits > 64) mix(@truncate(@as(u128, u) >> 64));
            mix(@truncate(@as(u128, u)));
        },
        .float => |fi| if (std.math.isNan(v)) mix(0x7ff8) else mix(@as(@Int(.unsigned, fi.bits), @bitCast(v))),
        .bool => mix(@intFromBool(v)),
        .optional => if (v) |x| mixv(x) else mix(0xdead),
        .@"struct" => inline for (v) |f| mixv(f),
        .comptime_int => mix(@as(u64, v)),
        else => @compileError("mixv " ++ @typeName(T)),
    }
}
fn cv(comptime T: type, x: u64) T {
    switch (@typeInfo(T)) {
        .int => |ii| {
            const w: u128 = (@as(u128, x *% 0x9e3779b97f4a7c15) << 64) | x;
            return @bitCast(@as(@Int(.unsigned, ii.bits), @truncate(w)));
        },
        .bool => return x & 1 != 0,
        .float => return switch (x % 16) {
            0 => 0.0,
            1 => -0.0,
            2 => 1.0,
            3 => -1.5,
            4 => std.math.inf(T),
            5 => -std.math.inf(T),
            6 => std.math.nan(T),
            7 => std.math.floatMin(T),
            8 => std.math.floatMax(T),
            9 => -std.math.floatTrueMin(T),
            else => @as(T, @floatFromInt(@as(i64, @bitCast(x)) >> 44)) / 8.0,
        },
        else => unreachable,
    }
}
fn ld(comptime V: type, off: usize) V {
    const vi = @typeInfo(V).vector;
    var a: [vi.len]vi.child = undefined;
    for (&a, 0..) |*e, i| e.* = cv(vi.child, in[(off + i * 7) % in.len]);
    return a;
}
fn amtv(comptime L: type, comptime bits: comptime_int, v: anytype) L {
    const li = @typeInfo(L).vector;
    const W = @Int(.unsigned, @bitSizeOf(@typeInfo(@TypeOf(v)).vector.child));
    const va: [li.len]@typeInfo(@TypeOf(v)).vector.child = v;
    var a: [li.len]li.child = undefined;
    for (&a, va) |*e, x| e.* = @intCast(@as(u128, @as(W, @bitCast(x))) % bits);
    return a;
}
fn amt(comptime L: type, comptime bits: comptime_int, off: usize) L {
    const li = @typeInfo(L).vector;
    var a: [li.len]li.child = undefined;
    for (&a, 0..) |*e, i| e.* = @intCast(in[(off + i * 5) % in.len] % bits);
    return a;
}
"""


class Gen:
    def __init__(self, seed, size=1.0):
        self.r = random.Random(seed)
        self.seed, self.size = seed, size
        self.top = []  # declarations after the prelude
        self.aliases = {}
        self.nfresh = 0
        self.pool = []
        self.ct = False  # generating a comptime-callable helper body
        # Upstream's LLVM backend emits invalid bitcode for a vector `<<|`
        # ("Invalid record"), which leaves a program without an LLVM
        # oracle (and, on aarch64, without any): one in four has them.
        self.shl_sat = self.r.random() < 0.25

    def chance(self, p):
        return self.r.random() < p

    def fresh(self, p):
        self.nfresh += 1
        return f"{p}{self.nfresh}"

    def alias(self, t):
        nm = t.name() if isinstance(t, VT) else t
        if nm not in self.aliases:
            a = f"V{len(self.aliases)}"
            self.aliases[nm] = a
            self.top.append(f"const {a} = {nm};")
        return self.aliases[nm]

    def L(self, t):
        return self.alias(f"@Vector({t.n}, std.math.Log2Int({t.elem()}))")

    # Types.

    def rand_type(self, n=None, kinds=("int", "int", "int", "float", "float", "bool")):
        for _ in range(20):
            kind = self.r.choice(kinds)
            nn = n or self.r.choice(LENS)
            if kind == "int":
                t = VT("int", nn, self.r.choice(INT_BITS), self.chance(0.5))
            elif kind == "float":
                t = VT("float", nn, self.r.choice(FLOAT_BITS))
            else:
                t = VT("bool", nn)
            if n is None and self.chance(0.5):
                # Whole registers, where the SIMD lowerings run: 16, 32
                # or 64 bytes of byte-sized lanes.
                eb = (t.bits + 7) // 8
                if t.bits % 8 == 0 or t.kind == "bool":
                    t.n = self.r.choice([16, 16, 32, 64]) // eb
            if t.nbytes() <= MAX_BYTES:
                return t
        return VT("int", n or 4, 8, False)

    # Literals.

    def int_lit(self, t):
        lo, hi = t.imin(), t.imax()
        c = self.r.random()
        if c < 0.3:
            return str(self.r.choice([lo, hi, 0, min(hi, 1), max(lo, -1) if t.signed else hi >> 1]))
        if c < 0.6:
            return str(self.r.randint(max(lo, -20), min(hi, 20)))
        return str(self.r.randint(lo, hi))

    def float_lit(self, t):
        e = t.elem()
        return self.r.choice([
            "0.0", "-0.0", "1.0", "-1.0", "0.5", "-2.75", "3.0", "100.25", "0.1", "-7.0",
            f"std.math.inf({e})", f"-std.math.inf({e})", f"std.math.nan({e})",
            f"std.math.floatMin({e})", f"std.math.floatMax({e})", f"-std.math.floatMax({e})",
            f"std.math.floatTrueMin({e})",
        ])

    def lit(self, t):
        if t.kind == "int":
            return self.int_lit(t)
        if t.kind == "float":
            return self.float_lit(t)
        return self.r.choice(["true", "false"])

    def vec_lit(self, t):
        if self.chance(0.25):
            return f"@as({self.alias(t)}, @splat({self.lit(t)}))"
        return f"@as({self.alias(t)}, .{{ {', '.join(self.lit(t) for _ in range(t.n))} }})"

    def splat(self, t, s):
        return f"@as({self.alias(t)}, @splat({s}))"

    # Scalars of a vector's element type.

    def scalar(self, t, d):
        e = t.elem()
        c = self.r.random()
        if not self.ct and c < 0.35:
            return f"cv({e}, in[{self.r.randrange(64)}])"
        if c < 0.55:
            return self.lane(t, d)
        if c < 0.75 and t.kind != "bool":
            ops = ["Add", "Mul", "Min", "Max"] + (["And", "Or", "Xor"] if t.kind == "int" else [])
            op = self.r.choice(ops)
            r = f"@reduce(.{op}, {self.vexpr(t.with_n(self.r.choice(LENS)), d - 1)})"
            if t.kind == "float" and op in ("Min", "Max"):
                r = f"({r} + 0.0)"
            return r
        if c < 0.75:
            return f"@reduce(.{self.r.choice(['And', 'Or', 'Xor'])}, {self.vexpr(t.with_n(self.r.choice(LENS)), d - 1)})"
        return f"@as({e}, {self.lit(t)})"

    def lane(self, t, d):
        n = self.r.choice(LENS)
        x = self.vexpr(t.with_n(n), d - 1)
        if not self.ct and self.chance(0.4):
            return f"@as([{n}]{t.elem()}, @as({self.alias(t.with_n(n))}, {x}))[in[{self.r.randrange(64)}] % {n}]"
        return f"({x})[{self.r.randrange(n)}]"

    # Vector expressions.

    def leaf(self, t):
        same = [nm for nm, pt in self.pool if pt == t]
        if same and self.chance(0.7):
            return self.r.choice(same)
        if self.ct:
            return self.vec_lit(t)
        c = self.r.random()
        if c < 0.5:
            return f"ld({self.alias(t)}, {self.r.randrange(64)})"
        if c < 0.65:
            return self.splat(t, f"cv({t.elem()}, in[{self.r.randrange(64)}])")
        if c < 0.8 and (t.kind == "float" or t.kind == "int" and t.bits in (8, 16, 32, 64)):
            off = self.r.randrange(0, 256)
            return f"@as(*align(1) const {self.alias(t)}, @ptrCast(&bytes[{off}])).*"
        # A comptime-known operand.
        nm = self.fresh("k")
        self.emit(f"const {nm} = {self.vec_lit(t)};")
        return nm

    def vexpr(self, t, d):
        if d <= 0 or self.chance(0.25):
            return self.leaf(t)
        return getattr(self, f"op_{t.kind}")(t, d)

    def other_int(self, n, cond=lambda t: True):
        for _ in range(20):
            t = VT("int", n, self.r.choice(INT_BITS), self.chance(0.5))
            if t.nbytes() <= MAX_BYTES and cond(t):
                return t
        return None

    def op_int(self, t, d):
        V, b, s = self.alias(t), t.bits, t.signed
        x = lambda: self.vexpr(t, d - 1)  # noqa: E731
        c = self.r.randrange(17)
        if c <= 2:
            op = self.r.choice(["+%", "-%", "*%", "&", "|", "^", "+|", "-|", "*|"])
            return f"({x()} {op} {x()})"
        if c == 3:
            # @as: with comptime-known operands, @min/@max narrow the type.
            return f"@as({V}, @{self.r.choice(['min', 'max'])}({x()}, {x()}))"
        if c == 4:
            return f"({self.r.choice(['~', '-%'])}{x()})"
        if c == 5 and b >= 2:
            one = f"@as({self.L(t)}, @splat(1))"
            if s:
                return f"(({x()} >> {one}) {self.r.choice(['+', '-'])} ({x()} >> {one}))"
            y, z = x(), x()
            return self.r.choice([f"(({y} >> {one}) + ({z} >> {one}))", f"(@as({V}, @max({y}, {z})) - @as({V}, @min({y}, {z})))"])
        if c in (6, 7):
            L = self.L(t)
            op = self.r.choice(["<<", ">>", ">>", "<<|" if self.shl_sat else "<<"])
            k = self.r.random()
            if k < 0.35:
                a = f"@as({L}, @splat({self.r.randrange(b)}))"
            elif k < 0.55 and not self.ct:
                a = f"@as({L}, @splat(@intCast(in[{self.r.randrange(64)}] % {b})))"
            elif k < 0.8:
                src = self.other_int(t.n)
                a = f"amtv({L}, {b}, {self.vexpr(src, d - 1)})"
            elif not self.ct:
                a = f"amt({L}, {b}, {self.r.randrange(64)})"
            else:
                a = f"@as({L}, @splat(0))"
            if op == "<<|" and not s and self.chance(0.3):
                a = x()  # a full-width amount saturates past the width
            return f"({x()} {op} {a})"
        if c == 8:
            src = self.other_int(t.n)
            return f"@shlWithOverflow({x()}, amtv({self.L(t)}, {b}, {self.vexpr(src, d - 1)}))[0]"
        if c == 9 and (b >= 2 or not s):
            mask = f"@as({V}, @splat({(1 << (b - 1)) - 1}))" if s else None
            y = x()
            dz = f"(({y} & {mask}) | @as({V}, @splat(1)))" if s else f"({y} | @as({V}, @splat(1)))"
            ops = ["@divTrunc", "@divFloor", "@rem", "@mod"]
            op = self.r.choice(ops + ([None, None] if not s else []))
            if op is None:
                return f"({x()} {self.r.choice(['/', '%'])} {dz})"
            return f"{op}({x()}, {dz})"
        if c == 10:
            return f"@select({t.elem()}, {self.vexpr(VT('bool', t.n), d - 1)}, {x()}, {x()})"
        if c == 11:
            return self.splat(t, self.scalar(t, d))
        if c == 12:
            # Widening: implicit or @intCast from a type whose range fits.
            def fits(o):
                return o.bits < b and (s or not o.signed) or o.bits == b and o.signed == s
            src = self.other_int(t.n, fits)
            if src is not None:
                e = self.vexpr(src, d - 1)
                return f"@as({V}, {e})" if self.chance(0.5) else f"@as({V}, @intCast({e}))"
        if c == 13:
            src = self.other_int(t.n, lambda o: o.bits >= b and o.signed == s)
            if src is not None:
                return f"@as({V}, @truncate({self.vexpr(src, d - 1)}))"
        if c == 14:
            return self.bitcast_to(t, d)
        if c == 15:
            if self.chance(0.4) and (not s or b >= 2):
                return f"@as({V}, @intFromBool({self.vexpr(VT('bool', t.n), d - 1)}))"
            ft = VT("float", t.n, self.r.choice(FLOAT_BITS))
            lo, hi = max(t.imin(), -1000), min(t.imax(), 1000)
            F = self.alias(ft)
            f = self.vexpr(ft, d - 1)
            return f"@as({V}, @intFromFloat(@trunc(@min(@max({f}, @as({F}, @splat({lo}))), @as({F}, @splat({hi}))))))"
        if c == 16:
            u = self.r.choice(["@popCount", "@clz", "@ctz", "@abs", "@bitReverse"] + (["@byteSwap"] if b % 8 == 0 else []))
            if u in ("@popCount", "@clz", "@ctz", "@abs"):
                # These change the element type; bring it back.
                return f"@as({V}, @bitCast(@as(@Vector({t.n}, u{b}), @truncate(@as(@Vector({t.n}, u{b + 8}), {u}({x()}))))))"
            return f"{u}({x()})"
        return self.shuffle_expr(t, d)

    def bitcast_to(self, t, d):
        """A bitcast to `t`: lane for lane (same width), or a reshape of
        byte-sized lanes. (Upstream's backends disagree about the bit
        layout of other reshapes: LLVM keeps each u33 lane in 8 bytes,
        the x86_64 backend packs them.)"""
        V = self.alias(t)
        total = t.n * (t.bits if t.kind != "bool" else 1)
        cands = []
        if t.kind == "int":
            cands.append(VT("int", t.n, t.bits, not t.signed))
            if t.bits == 1:
                cands.append(VT("bool", t.n))
            if t.bits % 8 == 0:
                for c in (8, 16, 32, 64):
                    if total % c == 0 and 1 <= total // c <= 64:
                        cands.append(VT("int", total // c, c, self.chance(0.5)))
        elif t.kind == "bool":
            cands.append(VT("int", t.n, 1, self.chance(0.5)))
        cands = [c for c in cands if c != t and c.nbytes() <= MAX_BYTES]
        if total <= 128 and (t.kind == "bool" or t.bits % 8 == 0) and (self.chance(0.4) or not cands):
            if self.ct:
                return f"@as({V}, @bitCast(@as(u{total}, {self.int_lit(VT('int', 1, total))})))"
            return f"@as({V}, @bitCast(cv(u{total}, in[{self.r.randrange(64)}])))"
        if not cands:
            return self.leaf(t)
        return f"@as({V}, @bitCast({self.vexpr(self.r.choice(cands), d - 1)}))"

    def op_float(self, t, d):
        V, fb = self.alias(t), t.bits
        x = lambda: self.vexpr(t, d - 1)  # noqa: E731
        c = self.r.randrange(11)
        if c <= 2:
            return f"({x()} {self.r.choice(['+', '-', '*', '/'])} {x()})"
        if c == 3:
            return f"(@{self.r.choice(['min', 'max'])}({x()}, {x()}) + @as({V}, @splat(0.0)))"
        if c == 4:
            u = self.r.choice(["-", "@abs", "@sqrt", "@floor", "@ceil", "@trunc", "@round"])
            return f"(-{x()})" if u == "-" else f"{u}({x()})"
        if c == 5 and fb != 16:
            return f"@mulAdd({V}, {x()}, {x()}, {x()})"
        if c == 6:
            return f"@select({t.elem()}, {self.vexpr(VT('bool', t.n), d - 1)}, {x()}, {x()})"
        if c == 7:
            return self.splat(t, self.scalar(t, d))
        if c == 8:
            src = VT("float", t.n, self.r.choice([f for f in (16, 32, 64) if f != fb]))
            return f"@as({V}, @floatCast({self.vexpr(src, d - 1)}))"
        if c == 9:
            src = self.other_int(t.n)
            return f"@as({V}, @floatFromInt({self.vexpr(src, d - 1)}))"
        if c == 10 and self.chance(0.3):
            src = VT("int", t.n, fb, self.chance(0.5))
            return f"@as({V}, @bitCast({self.vexpr(src, d - 1)}))"
        return self.shuffle_expr(t, d)

    def op_bool(self, t, d):
        x = lambda: self.vexpr(t, d - 1)  # noqa: E731
        c = self.r.randrange(8)
        if c <= 1:
            return f"({x()} {self.r.choice(['&', '|', '^'])} {x()})"
        if c == 2:
            return f"(!{x()})"
        if c <= 4:
            o = self.rand_type(t.n, ("int", "int", "float"))
            op = self.r.choice(["==", "!=", "<", "<=", ">", ">="])
            return f"({self.vexpr(o, d - 1)} {op} {self.vexpr(o, d - 1)})"
        if c == 5:
            return f"@select(bool, {x()}, {x()}, {x()})"
        if c == 6:
            return self.bitcast_to(t, d)
        if c == 7 and not self.ct:
            return self.splat(t, f"(in[{self.r.randrange(64)}] & 1 != 0)")
        return self.shuffle_expr(t, d)

    def shuffle_mask(self, na, nb, m, allow_undef):
        mask, undef = [], []
        for i in range(m):
            c = self.r.random()
            if allow_undef and c < 0.15:
                mask.append("undefined")
                undef.append(i)
            elif nb and c < 0.55:
                mask.append(str(~self.r.randrange(nb)))
            else:
                mask.append(str(self.r.randrange(na)))
        return mask, undef

    def shuffle_expr(self, t, d, allow_undef=False):
        na = self.r.choice(LENS)
        a = self.vexpr(t.with_n(na), d - 1)
        if self.chance(0.3):
            nb, b = 0, "undefined"
        else:
            nb = self.r.choice(LENS)
            b = self.vexpr(t.with_n(nb), d - 1)
        mask, undef = self.shuffle_mask(na, nb, t.n, allow_undef)
        if len(undef) == t.n:
            mask[0], undef = str(self.r.randrange(na)), undef[1:]
        e = f"@shuffle({t.elem()}, {a}, {b}, @Vector({t.n}, i32){{ {', '.join(mask)} }})"
        return (e, undef) if allow_undef else e

    # Statements.

    def emit(self, line):
        self.body.append("    " * self.indent + line)

    def define(self, t, e):
        nm = self.fresh("v")
        self.emit(f"const {nm}: {self.alias(t)} = {e};")
        self.pool.append((nm, t))
        return nm

    def stmt(self, depth):
        c = self.r.randrange(12)
        if c <= 3:
            t = self.rand_type()
            nm = self.define(t, self.vexpr(t, depth))
            if self.chance(0.8):
                self.emit(f"mixv({nm});")
        elif c == 4:
            t = self.rand_type(kinds=("int", "float", "bool"))
            ops = {"int": ["And", "Or", "Xor", "Min", "Max", "Add", "Mul"], "float": ["Add", "Mul", "Min", "Max"],
                   "bool": ["And", "Or", "Xor"]}[t.kind]
            op = self.r.choice(ops)
            r = f"@reduce(.{op}, {self.vexpr(t, depth)})"
            if t.kind == "float" and op in ("Min", "Max"):
                r = f"({r} + 0.0)"
            self.emit(f"mixv({r});")
        elif c == 5:
            t = self.rand_type(kinds=("int", "int", "float", "bool"))
            e, undef = self.shuffle_expr(t, depth, allow_undef=True)
            nm = self.fresh("s")
            self.emit(f"const {nm}: {self.alias(t)} = {e};")
            if not undef:
                self.pool.append((nm, t))
                self.emit(f"mixv({nm});")
            for i in range(t.n):
                if i not in undef:
                    self.emit(f"mixv({nm}[{i}]);")
        elif c == 6:
            t = self.rand_type(kinds=("bool",))
            b = self.vexpr(t, depth)
            f = self.r.choice(["firstTrue", "lastTrue", "countTrues"])
            if t.n <= 64 and self.chance(0.5):
                self.emit(f"mixv(@as(u{t.n}, @bitCast({b})));")
            else:
                self.emit(f"mixv(std.simd.{f}({b}));")
        elif c == 7:
            self.s_memory(depth)
        elif c == 8:
            self.s_call(depth)
        elif c == 9:
            # Bitcasts to integers and arrays.
            t = self.rand_type(kinds=("int", "bool"))
            total = t.n * t.bits
            e = self.vexpr(t, depth)
            if total <= 128 and (t.kind == "bool" or t.bits % 8 == 0) and self.chance(0.6):
                self.emit(f"mixv(@as(u{total}, @bitCast({e})));")
            else:
                self.emit(f"mixv(@as([{t.n}]{t.elem()}, {e}));")
        elif c == 10:
            t = self.rand_type(kinds=("int",))
            if t.bits >= 2 or not t.signed:
                L = self.L(t)
                src = self.other_int(t.n)
                self.emit(f"mixv(@shlWithOverflow({self.vexpr(t, depth)}, amtv({L}, {t.bits}, {self.vexpr(src, depth - 1)})));")
        else:
            t = self.rand_type()
            nm = self.fresh("a")
            self.emit(f"var {nm}: [{t.n}]{t.elem()} = @as({self.alias(t)}, {self.vexpr(t, depth)});")
            self.emit(f"{nm}[{self.r.randrange(t.n)}] = {self.scalar(t, depth - 1)};")
            self.define(t, nm)
            self.emit(f"mixv({self.pool[-1][0]});")

    def s_memory(self, depth):
        t = self.rand_type()
        V = self.alias(t)
        m = self.fresh("m")
        self.emit(f"var {m}: {V} = {self.vexpr(t, depth)};")
        for _ in range(self.r.randint(1, 3)):
            c = self.r.randrange(7)
            k = self.r.randrange(t.n)
            # Not floats: a load of other bytes would see NaN payloads.
            if c == 6 and not (t.kind == "int" and t.bits in (8, 16, 32, 64)):
                c = 0
            if c == 0:
                self.emit(f"{m}[{k}] = {self.scalar(t, depth - 1)};")
            elif c == 1:
                p = self.fresh("p")
                self.emit(f"const {p} = &{m};")
                self.emit(f"{p}.* = {self.vexpr(t, depth - 1).replace(m, p + '.*')};")
            elif c == 2:
                p = self.fresh("p")
                self.emit(f"const {p} = &{m}[{k}];")
                self.emit(f"{p}.* = {self.scalar(t, depth - 1)};")
            elif c == 3:
                g = self.fresh("g")
                self.top.append(f"var {g}: {V} = undefined;")
                self.emit(f"{g} = {m};")
                self.emit(f"{m} = {self.vexpr(t, depth - 1)};")
                self.emit(f"mixv({g});")
            elif c == 4:
                S = self.fresh("S")
                self.top.append(f"const {S} = struct {{ a: u8, v: {V}, b: {t.elem()} }};")
                sv = self.fresh("st")
                self.emit(f"var {sv}: {S} = .{{ .a = 1, .v = {m}, .b = {self.scalar(t, depth - 1)} }};")
                self.emit(f"{sv}.v[{k}] = {sv}.b;")
                self.emit(f"{m} = {sv}.v;")
            elif c == 5:
                arr = self.fresh("av")
                self.emit(f"var {arr}: [3]{V} = .{{ {m}, {self.vexpr(t, depth - 1)}, {m} }};")
                self.emit(f"{arr}[in[{self.r.randrange(64)}] % 3][{k}] = {self.scalar(t, depth - 1)};")
                self.emit(f"{m} = {arr}[in[{self.r.randrange(64)}] % 3];")
            elif c == 6:
                off = self.r.randrange(0, 256)
                # As an array: a vector's store may cover padding (upstream's
                # x86_64 backend gives @Vector(8, u8) 16 bytes), whose
                # undefined bytes later loads would read.
                self.emit(f"@as(*align(1) [{t.n}]{t.elem()}, @ptrCast(&bytes[{off}])).* = {m};")
                self.emit(f"{m} = @as(*align(1) const {V}, @ptrCast(&bytes[{off + self.r.choice([0, 0, 1, 4])}])).*;")
        self.emit(f"mixv({m});")
        self.pool.append((m, t))

    def s_call(self, depth):
        t = self.rand_type()
        V = self.alias(t)
        h = self.fresh("h")
        # The helper's body sees only its parameters and literals, so the
        # same call can run at comptime.
        saved = (self.pool, self.ct, self.body, self.indent)
        self.pool, self.ct, self.body, self.indent = [("a", t), ("b", t)], True, [], 1
        e = self.vexpr(t, depth)
        body = self.body
        self.pool, self.ct, self.body, self.indent = saved
        kw = self.r.choice(["noinline fn", "noinline fn", "fn", "inline fn"])
        byref = self.chance(0.3)
        used = set(re.findall(r"\b[ab]\b", e + "\n".join(body)))
        discard = [f"    _ = {p};" for p in ("a", "b") if p not in used]
        if byref:
            self.top.append(f"{kw} {h}(p: *{V}, b: {V}) void {{")
            self.top.append("    @setEvalBranchQuota(100000);")
            self.top.append("    const a = p.*;")
            self.top.extend(body + discard)
            self.top.append(f"    p.* = {e};")
            self.top.append("}")
        else:
            self.top.append(f"{kw} {h}(a: {V}, b: {V}) {V} {{")
            self.top.append("    @setEvalBranchQuota(100000);")
            self.top.extend(body + discard)
            self.top.append(f"    return {e};")
            self.top.append("}")
        for _ in range(self.r.randint(1, 3)):
            x, y = self.vexpr(t, depth - 1), self.vexpr(t, depth - 1)
            if byref:
                m = self.fresh("r")
                self.emit(f"var {m}: {V} = {x};")
                self.emit(f"{h}(&{m}, {y});")
                self.emit(f"mixv({m});")
                self.pool.append((m, t))
            else:
                self.define(t, f"{h}({x}, {y})")
                self.emit(f"mixv({self.pool[-1][0]});")
        ca, cb = self.vec_lit(t), self.vec_lit(t)
        if byref:
            self.emit(f"mixv(comptime blk: {{ @setEvalBranchQuota(100000); var cm: {V} = {ca}; {h}(&cm, {cb}); break :blk cm; }});")
        else:
            self.emit(f"mixv(comptime blk: {{ @setEvalBranchQuota(100000); break :blk {h}({ca}, {cb}); }});")
            # The same arguments at run time.
            ra, rb = self.fresh("ra"), self.fresh("rb")
            self.emit(f"var {ra}: {V} = {ca};")
            self.emit(f"var {rb}: {V} = {cb};")
            self.emit(f"_ = .{{ &{ra}, &{rb} }};")
            self.emit(f"mixv({h}({ra}, {rb}));")

    def gen_test(self, i):
        self.body, self.indent, self.pool = [], 1, []
        depth = self.r.randint(2, 4)
        for j in range(max(2, int(self.r.randint(3, 8) * self.size))):
            self.stmt(depth)
            # A checkpoint per statement points a mismatch at its statement.
            self.emit(f'std.debug.print("ck {i}.{j} {{x}}\\n", .{{ck}});')
        # Values no later statement used.
        text = "\n".join(self.body)
        for nm in re.findall(r"^ *const (\w+)", text, re.M):
            if len(re.findall(rf"\b{nm}\b", text)) == 1:
                self.body.append(f"    mixv({nm});")
        return [f"noinline fn t{i}() void {{", "    @setEvalBranchQuota(100000);"] + self.body + ["}"]

    def generate(self):
        r = self.r
        edges = [0, 1, 2, 0xff, 0x80, 0x7f, 0xffff, 0x8000, 0xffffffff, 0x80000000, 0x7fffffff,
                 (1 << 64) - 1, 1 << 63, (1 << 63) - 1, 0x5555555555555555, 0xaaaaaaaaaaaaaaaa]
        ins = [r.choice(edges) if r.random() < 0.35 else r.getrandbits(64) if r.random() < 0.5 else r.randrange(1 << r.choice([4, 8, 16, 24, 33]))
               for _ in range(64)]
        tests = []
        nt = max(2, int(r.randint(4, 9) * self.size))
        for i in range(nt):
            tests.append(self.gen_test(i))
        out = [f"// mchunt vector seed {self.seed}", 'const std = @import("std");', ""]
        out.append(f"var in: [64]u64 = .{{ {', '.join(hex(x) for x in ins)} }};")
        mul = r.getrandbits(64) | 1
        out.append("var bytes: [1024]u8 align(64) = blk: {")
        out.append("    @setEvalBranchQuota(10000);")
        out.append("    var b: [1024]u8 = undefined;")
        out.append(f"    for (&b, 0..) |*x, i| x.* = @truncate((@as(u64, i) *% {hex(mul)}) >> 29);")
        out.append("    break :blk b;")
        out.append("};")
        out.extend(PRELUDE.strip("\n").split("\n"))
        out.extend(self.top)
        out.append("")
        for t in tests:
            out.extend(t)
        out.append("pub fn main() void {")
        for i in range(nt):
            out.append(f"    t{i}();")
            out.append(f'    std.debug.print("ck {i} {{x}}\\n", .{{ck}});')
        out.append('    std.debug.print("ck end {x}\\n", .{ck});')
        out.append("}")
        return "\n".join(out) + "\n"


def generate(seed, size=1.0):
    return Gen(seed, size).generate()


if __name__ == "__main__":
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else random.randrange(1 << 32)
    size = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
    sys.stdout.write(generate(seed, size))
