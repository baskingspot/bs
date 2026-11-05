#!/usr/bin/env python3
"""Random Zig programs that compute values at comptime (tools/cthunt).

`python3 gen.py SEED` prints one program. Each program is a list of
independent tests. Test N is a container-level `const tN` whose value is
computed at comptime (in a labeled block, or by calling functions the
test declares just above it), and `main` prints it at run time as one
line, `tN <value>`.

Unlike tools/mchunt, a test need not be well defined: comptime overflow,
division by zero, out-of-range casts and the like are compile errors,
and upstream decides which tests are errors. The hunter compares which
tests each compiler rejects, drops the ones upstream rejects, and
compares the printed values of the rest.

Every test's text lies between `// test N` and `// end N` lines, and
main's print of it carries `// test N`, so a compile error's line names
its test and a test can be cut out on its own.
"""

import random
import sys

# ---------------------------------------------------------------- types


class Int:
    def __init__(self, signed, bits):
        self.signed, self.bits = signed, bits

    def name(self):
        return ("i" if self.signed else "u") + str(self.bits)

    def min(self):
        return -(1 << (self.bits - 1)) if self.signed else 0

    def max(self):
        return (1 << (self.bits - 1)) - 1 if self.signed else (1 << self.bits) - 1

    def __eq__(self, o):
        return isinstance(o, Int) and (o.signed, o.bits) == (self.signed, self.bits)

    def __hash__(self):
        return hash((self.signed, self.bits))


class Float:
    def __init__(self, bits):
        self.bits = bits

    def name(self):
        return f"f{self.bits}"

    def __eq__(self, o):
        return isinstance(o, Float) and o.bits == self.bits

    def __hash__(self):
        return hash(("f", self.bits))


class Bool:
    def name(self):
        return "bool"

    def __eq__(self, o):
        return isinstance(o, Bool)

    def __hash__(self):
        return 1


BOOL = Bool()
USIZE = Int(False, 64)
U32 = Int(False, 32)
U8 = Int(False, 8)

INT_BITS = [
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    8,
    9,
    12,
    15,
    16,
    16,
    17,
    24,
    31,
    32,
    32,
    33,
    48,
    63,
    64,
    64,
    65,
    96,
    100,
    127,
    128,
    128,
    129,
    200,
    255,
    256,
]
FLOAT_BITS = [16, 32, 64, 80, 128]


def usize_name(t):
    return "usize" if t == USIZE else t.name()


def log2_ceil(n):
    b = 0
    while (1 << b) < n:
        b += 1
    return b


# ---------------------------------------------------------------- generator


class Gen:
    def __init__(self, seed, size):
        self.r = random.Random(seed)
        self.seed = seed
        self.size = size
        self.decls = []  # lines of the current test's declarations
        self.uid = 0
        self.risk = 0.2

    # -------------------------------------------------------- helpers

    def risky(self):
        """Whether to emit an operation that can fail at comptime; the
        rate is drawn per test, so most tests compile."""
        return self.r.random() < self.risk

    def ch(self, xs):
        return self.r.choice(xs)

    def p(self, prob):
        return self.r.random() < prob

    def fresh(self, base):
        self.uid += 1
        return f"{base}_{self.uid}"

    def int_type(self, max_bits=256, min_bits=1):
        bits = [b for b in INT_BITS if min_bits <= b <= max_bits] or [min_bits]
        return Int(self.p(0.45), self.ch(bits))

    def float_type(self):
        return Float(self.ch(FLOAT_BITS))

    def int_lit_val(self, t):
        lo, hi = t.min(), t.max()
        r = self.r.random()
        if r < 0.45:
            cands = [0, 1, hi, lo, hi - 1, lo + 1, hi // 2, (hi // 2) + 1, 2, 3, 7]
            if t.signed:
                cands += [-1, -2, lo // 2]
            v = self.ch(cands)
        elif r < 0.75:
            v = self.r.randint(-20 if t.signed else 0, 20)
        else:
            v = self.r.randint(lo, hi)
        return max(lo, min(hi, v))

    def int_lit(self, t):
        v = self.int_lit_val(t)
        s = hex(v) if abs(v) > 4096 else str(v)
        if v < 0:
            s = "-" + (hex(-v) if -v > 4096 else str(-v))
        return f"@as({t.name()}, {s})"

    def float_lit(self, t):
        n = t.name()
        r = self.r.random()
        if r < 0.3:
            return self.ch(
                [
                    f"@as({n}, 0.0)",
                    f"@as({n}, -0.0)",
                    f"@as({n}, 1.0)",
                    f"@as({n}, -1.0)",
                    f"@as({n}, 0.5)",
                    f"@as({n}, 0.1)",
                    f"@as({n}, 3.0)",
                    f"@as({n}, 1e10)",
                    f"@as({n}, -2.5)",
                    f"std.math.inf({n})",
                    f"-std.math.inf({n})",
                    f"std.math.nan({n})",
                    f"std.math.floatMax({n})",
                    f"std.math.floatMin({n})",
                    f"std.math.floatTrueMin({n})",
                    f"std.math.floatEps({n})",
                    f"-std.math.floatMax({n})",
                ]
            )
        if r < 0.6:
            return f"@as({n}, {self.r.randint(-1000, 1000)}.{self.r.randint(0, 999)})"
        if r < 0.8:
            return f"@as({n}, {self.r.uniform(-1, 1):.6e})"
        return f"@as({n}, {self.r.randint(1, 9)}.{self.r.randint(0, 99)}e{self.r.randint(-40, 40)})"

    # -------------------------------------------------------- expressions

    def vars_of(self, scope, t):
        return [v for v, vt in scope if vt == t]

    def int_expr(self, t, scope, d):
        """A comptime expression of integer type `t`."""
        if d <= 0 or self.p(0.15):
            vs = self.vars_of(scope, t)
            if vs and self.p(0.7):
                return self.ch(vs)
            return self.int_lit(t)
        a = lambda: self.int_expr(t, scope, d - 1)
        n = t.name()
        k = self.r.random()
        bits = t.bits
        if k < 0.30:
            op = self.ch(["+%", "-%", "*%", "&", "|", "^", "+|", "-|", "*|"])
            if self.risky():
                op = self.ch(["+", "-", "*"])
            return f"({a()} {op} {a()})"
        if k < 0.38:
            sh = self.r.randint(0, bits - 1) if not self.risky() or self.p(0.8) else bits
            op = self.ch(["<<", ">>", "<<|", ">>"])
            if op == "<<|" and self.p(0.5):
                sh = self.r.randint(0, bits + 3)
            if self.p(0.3) and bits > 1:
                # A runtime-typed shift amount: Log2Int.
                amt = f"@as(std.math.Log2Int({n}), {min(sh, bits - 1)})"
            else:
                amt = str(sh)
            return f"({a()} {op} {amt})"
        if k < 0.43 and self.risky():
            fn = self.ch(["@shlExact", "@shrExact"])
            return f"{fn}({a()}, {self.r.randint(0, bits - 1)})"
        if k < 0.50:
            if not self.risky():
                # A divisor that is not zero.
                dv = f"({a()} | 1)"
                fn = self.ch(["@divTrunc", "@divFloor", "@rem"] + ([] if t.signed else ["@mod", "/", "%"]))
                if fn in ("/", "%"):
                    return f"({a()} {fn} {dv})"
                return f"{fn}({a()}, {dv})"
            if t.signed:
                fn = self.ch(["@divTrunc", "@divFloor", "@divExact", "@rem", "@mod"])
                return f"{fn}({a()}, {a()})"
            fn = self.ch(["@divTrunc", "@divFloor", "@divExact", "@rem", "@mod", "/", "%"])
            if fn in ("/", "%"):
                return f"({a()} {fn} {a()})"
            return f"{fn}({a()}, {a()})"
        if k < 0.54:
            fn = self.ch(["@addWithOverflow", "@subWithOverflow", "@mulWithOverflow", "@shlWithOverflow"])
            idx = self.ch(["[0]", "[0]", "[1]"])
            second = str(self.r.randint(0, bits - 1)) if fn == "@shlWithOverflow" else a()
            e = f"{fn}({a()}, {second}){idx}"
            if idx == "[1]":
                return self.conv_int(e, Int(False, 1), t)
            return e
        if k < 0.60:
            fn = self.ch(["@clz", "@ctz", "@popCount"] + (["@byteSwap"] if bits % 8 == 0 else []) + ["@bitReverse"])
            if fn in ("@byteSwap", "@bitReverse"):
                return f"{fn}({a()})"
            rt = Int(False, log2_ceil(bits + 1))
            return self.conv_int(f"{fn}({a()})", rt, t)
        if k < 0.64:
            if t.signed:
                return self.ch(
                    [
                        f"(-{a()})" if self.risky() else f"(-%{a()})",
                        f"(-%{a()})",
                        f"@as({n}, @bitCast(@abs({a()})))",
                        f"(~{a()})",
                    ]
                )
            return self.ch([f"(~{a()})", f"@abs({a()})", f"(0 -% {a()})"])
        if k < 0.68:
            return f"{self.ch(['@min', '@max'])}({a()}, {a()})"
        if k < 0.73:
            return f"(if ({self.bool_expr(scope, d - 1)}) {a()} else {a()})"
        if k < 0.85:
            # From another integer type.
            o = self.int_type()
            return self.conv_int(self.int_expr(o, scope, d - 1), o, t)
        if k < 0.90 and self.risky():
            f = self.float_type()
            fe = self.float_expr(f, scope, d - 1)
            if self.p(0.5):
                fe = f"@trunc({fe})"
            return f"@as({n}, @intFromFloat({fe}))"
        if k < 0.93:
            return self.conv_int(f"@intFromBool({self.bool_expr(scope, d - 1)})", Int(False, 1), t)
        if k < 0.96:
            # A switch with ranges over the operand.
            x = a()
            lo, hi = sorted([self.int_lit_val(t), self.int_lit_val(t)])
            v = self.int_lit_val(t)
            return (
                f"(switch ({x}) {{ {lo}...{hi} => {a()}, {v} => {a()}, else => {a()} }})"
                if not lo <= v <= hi
                else f"(switch ({x}) {{ {lo}...{hi} => {a()}, else => {a()} }})"
            )
        # Through std.math.
        return self.ch(
            [
                f"std.math.maxInt({n})",
                f"std.math.minInt({n})",
                f"std.math.rotl({n}, {a()}, {self.r.randint(0, 300)})",
                f"std.math.rotr({n}, {a()}, {self.r.randint(0, 300)})",
                f"(std.math.add({n}, {a()}, {a()}) catch {a()})",
                f"(std.math.mul({n}, {a()}, {a()}) catch {a()})",
                f"std.math.shl({n}, {a()}, {self.r.randint(0, bits + 2)})",
                f"(std.math.divExact({n}, {a()}, {a()}) catch {a()})",
            ]
        )

    def conv_int(self, e, frm, to):
        if frm == to:
            return e
        n = to.name()
        r = self.r.random()
        if frm.bits == to.bits and r < 0.5:
            return f"@as({n}, @bitCast({e}))"
        if to.bits <= frm.bits and r < 0.8:
            # @truncate keeps the operand's signedness.
            if to.signed == frm.signed:
                return f"@as({n}, @truncate({e}))"
            return f"@as({n}, @bitCast(@as({Int(frm.signed, to.bits).name()}, @truncate({e}))))"
        if to.bits > frm.bits and (to.signed or not frm.signed) and r < 0.8:
            return f"@as({n}, {e})"
        if (
            self.risky()
            or to.bits >= frm.bits + (1 if to.signed and not frm.signed else 0)
            and (to.signed or not frm.signed)
        ):
            return f"@as({n}, @intCast({e}))"
        if to.bits <= frm.bits:
            return self.conv_int(e, frm, to)
        # Widen with the operand's signedness, then reinterpret.
        return f"@as({n}, @bitCast(@as({Int(frm.signed, to.bits).name()}, {e})))"

    def float_expr(self, t, scope, d):
        if d <= 0 or self.p(0.15):
            vs = self.vars_of(scope, t)
            if vs and self.p(0.7):
                return self.ch(vs)
            return self.float_lit(t)
        a = lambda: self.float_expr(t, scope, d - 1)
        n = t.name()
        k = self.r.random()
        if k < 0.35:
            return f"({a()} {self.ch(['+', '-', '*', '/'])} {a()})"
        if k < 0.40:
            return f"{self.ch(['@rem', '@mod'])}({a()}, {a()})"
        if k < 0.55:
            # Upstream folds f80 exp and log with its own host's libm
            # (musl's x87 code), which can differ from compiler_rt's in the
            # last bit, and so differs from upstream's own run-time result.
            transc = ["@sin", "@cos", "@tan"]
            if n != "f80":
                transc += ["@exp", "@exp2", "@log", "@log2", "@log10"]
            fn = self.ch(["@sqrt", "@floor", "@ceil", "@trunc", "@round", "@abs", "-"] * 2 + transc)
            return f"(-{a()})" if fn == "-" else f"{fn}({a()})"
        if k < 0.60:
            return f"@mulAdd({n}, {a()}, {a()}, {a()})"
        if k < 0.65:
            return f"{self.ch(['@min', '@max'])}({a()}, {a()})"
        if k < 0.75:
            o = self.float_type()
            return f"@as({n}, @floatCast({self.float_expr(o, scope, d - 1)}))"
        if k < 0.85:
            o = self.int_type()
            return f"@as({n}, @floatFromInt({self.int_expr(o, scope, d - 1)}))"
        if k < 0.90 and t.bits != 80:
            return f"@as({n}, @bitCast({self.int_expr(Int(False, t.bits), scope, d - 1)}))"
        if k < 0.95:
            return f"(if ({self.bool_expr(scope, d - 1)}) {a()} else {a()})"
        return self.ch(
            [
                f"std.math.copysign({a()}, {a()})",
                f"std.math.ldexp({a()}, {self.r.randint(-80, 80)})",
                f"@as({n}, {self.r.randint(-5, 5)})",
            ]
        )

    def bool_expr(self, scope, d):
        k = self.r.random()
        if d <= 0 or k < 0.1:
            vs = self.vars_of(scope, BOOL)
            if vs and self.p(0.5):
                return self.ch(vs)
            return self.ch(["true", "false"])
        if k < 0.55:
            t = self.int_type()
            return (
                f"({self.int_expr(t, scope, d - 1)} {self.ch(['<', '<=', '==', '!=', '>', '>='])} "
                f"{self.int_expr(t, scope, d - 1)})"
            )
        if k < 0.75:
            t = self.float_type()
            if self.p(0.3):
                return (
                    f"std.math.{self.ch(['isNan', 'isInf', 'isNormal', 'signbit', 'isFinite'])}"
                    f"({self.float_expr(t, scope, d - 1)})"
                )
            return (
                f"({self.float_expr(t, scope, d - 1)} {self.ch(['<', '<=', '==', '!=', '>', '>='])} "
                f"{self.float_expr(t, scope, d - 1)})"
            )
        if k < 0.9:
            return (
                f"({self.bool_expr(scope, d - 1)} {self.ch(['and', 'or', '!=', '=='])} {self.bool_expr(scope, d - 1)})"
            )
        return f"(!{self.bool_expr(scope, d - 1)})"

    def expr(self, t, scope, d):
        if isinstance(t, Int):
            return self.int_expr(t, scope, d)
        if isinstance(t, Float):
            return self.float_expr(t, scope, d)
        return self.bool_expr(scope, d)

    def scalar_type(self):
        k = self.r.random()
        if k < 0.65:
            return self.int_type()
        if k < 0.9:
            return self.float_type()
        return BOOL

    # -------------------------------------------------------- statements

    def stmts(self, scope, depth, n, out, ind, in_fn):
        """Appends `n` statements over comptime vars to `out`."""
        for _ in range(n):
            k = self.r.random()
            if k < 0.30 or not scope:
                t = self.scalar_type()
                v = self.fresh("v")
                out.append(f"{ind}var {v}: {t.name()} = {self.expr(t, scope, self.ch([1, 2, 3]))};")
                out.append(f"{ind}_ = &{v};")
                scope.append((v, t))
            elif k < 0.60:
                v, t = self.ch(scope)
                if isinstance(t, Int) and self.p(0.5):
                    op = self.ch(["+%=", "-%=", "*%=", "^=", "|=", "&=", "+=", "-=", "<<=", ">>="])
                    rhs = str(self.r.randint(0, t.bits - 1)) if op in ("<<=", ">>=") else self.expr(t, scope, 2)
                    out.append(f"{ind}{v} {op} {rhs};")
                else:
                    out.append(f"{ind}{v} = {self.expr(t, scope, self.ch([1, 2, 3]))};")
            elif k < 0.72 and depth > 0:
                out.append(f"{ind}if ({self.bool_expr(scope, 2)}) {{")
                self.stmts(list(scope), depth - 1, self.r.randint(1, 3), out, ind + "    ", in_fn)
                if self.p(0.5):
                    out.append(f"{ind}}} else {{")
                    self.stmts(list(scope), depth - 1, self.r.randint(1, 3), out, ind + "    ", in_fn)
                out.append(f"{ind}}}")
            elif k < 0.84 and depth > 0:
                i = self.fresh("ix")
                cnt = self.r.randint(0, 12)
                # `inline` is redundant (an error) where every loop is
                # comptime already: outside function bodies.
                kind = self.ch(["while", "for"] + (["inline for", "inline while"] if in_fn else []))
                if kind == "for":
                    out.append(f"{ind}for (0..{cnt}) |{i}| {{")
                elif kind == "inline for":
                    out.append(f"{ind}inline for (0..{cnt}) |{i}| {{")
                elif kind == "while":
                    out.append(f"{ind}var {i}: usize = 0;")
                    out.append(f"{ind}while ({i} < {cnt}) : ({i} += 1) {{")
                else:
                    out.append(f"{ind}comptime var {i}: usize = 0;")
                    out.append(f"{ind}inline while ({i} < {cnt}) : ({i} += 1) {{")
                # A loop-local var uses the capture.
                lv = self.fresh("v")
                out.append(f"{ind}    var {lv}: usize = {i};")
                out.append(f"{ind}    _ = &{lv};")
                inner = list(scope) + [(lv, USIZE)]
                self.stmts(inner, depth - 1, self.r.randint(1, 3), out, ind + "    ", in_fn)
                if self.p(0.2):
                    out.append(f"{ind}    if ({self.bool_expr(inner, 1)}) break;")
                out.append(f"{ind}}}")
            elif k < 0.92:
                v, t = self.ch(scope)
                if isinstance(t, Int):
                    e = self.int_expr(t, scope, 2)
                    lo, hi = sorted([self.int_lit_val(t), self.int_lit_val(t)])
                    out.append(f"{ind}switch ({e}) {{")
                    out.append(f"{ind}    {lo}...{hi} => {v} = {self.int_expr(t, scope, 2)},")
                    out.append(f"{ind}    else => {{}},")
                    out.append(f"{ind}}}")
                else:
                    out.append(f"{ind}{v} = {self.expr(t, scope, 2)};")
            else:
                out.append(f"{ind}{{")
                self.stmts(list(scope), depth - 1, self.r.randint(1, 2), out, ind + "    ", in_fn)
                out.append(f"{ind}}}")

    # -------------------------------------------------------- tests

    def t_arith(self, name):
        """Scalar arithmetic in a comptime block."""
        out = []
        scope = []
        t = self.scalar_type()
        out.append(f"const {name}: {t.name()} = blk: {{")
        self.stmts(scope, 2, self.r.randint(1, 5), out, "    ", False)
        out.append(f"    break :blk {self.expr(t, scope, 3)};")
        out.append("};")
        return out, t

    def t_fn_eval(self, name):
        """A function called many times at comptime, which bs's comptime
        evaluator lowers after a few walker runs."""
        out = []
        f = self.fresh("f")
        rt = self.scalar_type()
        pt = self.int_type(64)
        scope = [("xv", pt)]
        body = []
        self.stmts(scope, 2, self.r.randint(1, 5), body, "    ", True)
        out.append(f"fn {f}(x: {pt.name()}) {rt.name()} {{")
        out.append(f"    var xv: {pt.name()} = x;")
        out.append("    _ = &xv;")
        out += body
        if self.p(0.3):
            out.append(f"    if ({self.bool_expr(scope, 2)}) return {self.expr(rt, scope, 2)};")
        out.append(f"    return {self.expr(rt, scope, 3)};")
        out.append("}")
        n = self.r.randint(2, 12)
        args = ", ".join(self.int_lit(pt) for _ in range(n))
        out.append(f"const {name} = blk: {{")
        out.append(f"    const args = [_]{pt.name()}{{ {args} }};")
        out.append(f"    var out: [{n}]{rt.name()} = undefined;")
        out.append(f"    for (&out, args) |*o, a| o.* = {f}(a);")
        out.append("    break :blk out;")
        out.append("};")
        return out, ("array", rt)

    def bit_shapes(self, nbits):
        """Type declarations and names of types of exactly `nbits` bits
        that @bitCast accepts."""
        shapes = []
        shapes.append(("", Int(self.p(0.5), nbits).name()))
        if nbits in FLOAT_BITS and nbits != 80:
            shapes.append(("", f"f{nbits}"))
        for eb in (8, 16, 32, 64):
            if nbits % eb == 0 and nbits // eb > 1:
                shapes.append(("", f"[{nbits // eb}]{self.ch(['u', 'i'])}{eb}"))
                shapes.append(("", f"@Vector({nbits // eb}, {self.ch(['u', 'i'])}{eb})"))
        for eb in range(1, 9):
            if nbits % eb == 0 and nbits // eb > 1 and nbits // eb <= 64:
                shapes.append(("", f"[{nbits // eb}]u{eb}"))
        if nbits % 16 == 0 and nbits // 16 > 1:
            shapes.append(("", f"[{nbits // 16}]f16"))
        if nbits <= 64 and nbits > 1:
            shapes.append(("", f"@Vector({nbits}, bool)"))
        # A packed struct with random fields.
        for _ in range(2):
            fields, left = [], nbits
            while left > 0:
                fb = min(left, self.r.randint(1, max(1, min(left, 33))))
                k = self.r.random()
                if fb == 1 and k < 0.4:
                    ft = "bool"
                elif fb in (16, 32) and k < 0.3:
                    ft = f"f{fb}"
                else:
                    ft = f"{self.ch(['u', 'i'])}{fb}"
                fields.append(ft)
                left -= fb
            pn = self.fresh("P")
            decl = (
                f"const {pn} = packed struct({'u' if self.p(0.7) else 'i'}{nbits}) {{ "
                + ", ".join(f"f{i}: {ft}" for i, ft in enumerate(fields))
                + " };"
            )
            shapes.append((decl, pn))
        if nbits <= 64:
            un = self.fresh("U")
            decl = f"const {un} = packed union {{ a: u{nbits}, b: i{nbits} }};"
            shapes.append((decl, un))
        return shapes

    def value_of(self, tname, decls):
        """A literal value of a type `bit_shapes` names."""
        if tname.startswith(("[", "@Vector")):
            if tname.startswith("["):
                n = int(tname[1 : tname.index("]")])
                et = tname[tname.index("]") + 1 :]
                prefix = tname
            else:
                inner = tname[len("@Vector(") : -1]
                n, et = int(inner.split(",")[0]), inner.split(",")[1].strip()
                prefix = tname
            elems = [self.scalar_lit(et) for _ in range(n)]
            if self.p(0.2):
                return f"@as({prefix}, @splat({elems[0]}))"
            return f"{prefix}{{ " + ", ".join(elems) + " }"
        if tname[0] == "P":
            decl = next(d for d in decls if d.startswith(f"const {tname} "))
            fields = decl[decl.index("{ ") + 2 : decl.rindex(" }")].split(", ")
            return (
                f"{tname}{{ "
                + ", ".join(f".{f.split(': ')[0]} = {self.scalar_lit(f.split(': ')[1])}" for f in fields)
                + " }"
            )
        if tname[0] == "U":
            decl = next(d for d in decls if d.startswith(f"const {tname} "))
            bits = int(decl[decl.index("a: u") + 4 : decl.index(",")])
            f = self.ch(["a", "b"])
            return f"{tname}{{ .{f} = {self.scalar_lit(('u' if f == 'a' else 'i') + str(bits))} }}"
        return self.scalar_lit(tname)

    def scalar_lit(self, tname):
        if tname == "bool":
            return self.ch(["true", "false"])
        if tname[0] == "f":
            return self.float_lit(Float(int(tname[1:])))
        return self.int_lit(Int(tname[0] == "i", int(tname[1:])))

    def t_bitcast(self, name):
        """@bitCast between shapes of the same bit size."""
        nbits = self.ch([8, 16, 24, 32, 40, 48, 64, 64, 96, 128, 128, 256, 12, 20, 7, 33])
        shapes = self.bit_shapes(nbits)
        (d1, a), (d2, b) = self.ch(shapes), self.ch(shapes)
        out = [d for d in (d1, d2) if d]
        if d1 == d2 and d1:
            out = [d1]
        decls = [d for d in (d1, d2) if d]
        v = self.value_of(a, decls)
        if self.p(0.5):
            out.append(f"const {name} = @as({b}, @bitCast(@as({a}, {v})));")
        else:
            # Through a comptime var, written field by field or element
            # by element first.
            out.append(f"const {name} = blk: {{")
            out.append(f"    var x: {a} = {v};")
            out.append("    _ = &x;")
            if a[0] == "[":
                n = int(a[1 : a.index("]")])
                et = a[a.index("]") + 1 :]
                for _ in range(self.r.randint(0, 2)):
                    out.append(f"    x[{self.r.randint(0, n - 1)}] = {self.scalar_lit(et)};")
            elif a[0] == "P":
                decl = next(d for d in decls if d.startswith(f"const {a} "))
                fields = decl[decl.index("{ ") + 2 : decl.rindex(" }")].split(", ")
                for _ in range(self.r.randint(0, 2)):
                    f = self.ch(fields)
                    out.append(f"    x.{f.split(': ')[0]} = {self.scalar_lit(f.split(': ')[1])};")
            out.append(f"    var y: {b} = @bitCast(x);")
            out.append("    _ = &y;")
            if b[0] == "P":
                decl = next(d for d in decls if d.startswith(f"const {b} "))
                fields = decl[decl.index("{ ") + 2 : decl.rindex(" }")].split(", ")
                f = self.ch(fields)
                out.append(f"    y.{f.split(': ')[0]} = {self.scalar_lit(f.split(': ')[1])};")
            out.append(f"    break :blk .{{ y, @as({a}, @bitCast(y)) }};")
            out.append("};")
        return out, "any"

    def t_ptrcast(self, name):
        """Reinterpreting comptime memory through @ptrCast."""
        out = []
        k = self.r.random()
        n = self.r.randint(1, 6)
        et = self.ch(["u8", "u16", "u32", "u64", "i16", "i32"])
        int(et[1:]) // 8
        sn = self.fresh("S")
        if k < 0.5:
            fields = [
                self.ch(["u8", "u16", "u32", "u64", "i8", "i16", "i32", "f32", "f64"])
                for _ in range(self.r.randint(1, 4))
            ]
            out.append(
                f"const {sn} = extern struct {{ " + ", ".join(f"f{i}: {t}" for i, t in enumerate(fields)) + " };"
            )
            init = f"{sn}{{ " + ", ".join(f".f{i} = {self.scalar_lit(t)}" for i, t in enumerate(fields)) + " }"
            ty = sn
        else:
            ty = f"[{n * 2}]{et}"
            init = f"{ty}{{ " + ", ".join(self.scalar_lit(et) for _ in range(n * 2)) + " }"
        out.append(f"const {name} = blk: {{")
        out.append(f"    var x: {ty} align(8) = {init};")
        out.append("    _ = &x;")
        view = self.ch(["bytes", "elems", "int"])
        if view == "bytes":
            out.append(f"    const b: *[@sizeOf({ty})]u8 = @ptrCast(&x);")
            for _ in range(self.r.randint(0, 3)):
                out.append(
                    f"    b[{self.r.randint(0, 7)} % b.len] {self.ch(['=', '+%=', '^='])} {self.r.randint(0, 255)};"
                )
            out.append("    break :blk .{ x, b.* };")
        elif view == "elems":
            vt = self.ch(["u8", "u16", "u32", "i8", "i16"])
            vb = int(vt[1:]) // 8
            out.append(f"    const p: [*]{vt} = @ptrCast(&x);")
            out.append(f"    const s = p[0 .. @sizeOf({ty}) / {vb}];")
            for _ in range(self.r.randint(0, 3)):
                out.append(f"    s[{self.r.randint(0, 5)} % s.len] = {self.scalar_lit(vt)};")
            out.append("    break :blk .{ x, s.len, s[s.len - 1] };")
        else:
            out.append(f"    const q: *align(8) [@sizeOf({ty})]u8 = @ptrCast(&x);")
            out.append("    const w: *align(1) u16 = @ptrCast(&q[1]);")
            out.append(f"    w.* {self.ch(['=', '+%=', '^='])} {self.r.randint(0, 65535)};")
            out.append("    break :blk .{ x, w.* };")
        out.append("};")
        return out, "any"

    def t_packed(self, name):
        """Packed structs and unions written in comptime vars, through
        field pointers too."""
        out = []
        nf = self.r.randint(1, 5)
        fts = []
        for _ in range(nf):
            k = self.r.random()
            fts.append("bool" if k < 0.15 else (f"{self.ch(['u', 'i'])}{self.r.randint(1, 20)}"))
        inner = None
        if self.p(0.3):
            inner = self.fresh("Q")
            ib = [f"{self.ch(['u', 'i'])}{self.r.randint(1, 9)}" for _ in range(self.r.randint(1, 3))]
            out.append(f"const {inner} = packed struct {{ " + ", ".join(f"g{i}: {t}" for i, t in enumerate(ib)) + " };")
            fts.append(inner)
        pn = self.fresh("P")
        out.append(f"const {pn} = packed struct {{ " + ", ".join(f"f{i}: {t}" for i, t in enumerate(fts)) + " };")

        def lit(t):
            if t == inner:
                d = out[0]
                fs = d[d.index("{ ") + 2 : d.rindex(" }")].split(", ")
                return (
                    f"{inner}{{ "
                    + ", ".join(f".{f.split(': ')[0]} = {self.scalar_lit(f.split(': ')[1])}" for f in fs)
                    + " }"
                )
            return self.scalar_lit(t)

        init = f"{pn}{{ " + ", ".join(f".f{i} = {lit(t)}" for i, t in enumerate(fts)) + " }"
        out.append(f"const {name} = blk: {{")
        out.append(f"    var x: {pn} = {init};")
        out.append("    _ = &x;")
        for _ in range(self.r.randint(1, 4)):
            i = self.r.randrange(len(fts))
            t = fts[i]
            k = self.r.random()
            if t == inner:
                out.append(
                    f"    x.f{i}.g0 = {self.scalar_lit(out[0][out[0].index('g0: ') + 4 :].split(',')[0].split(' ')[0])};"
                )
            elif k < 0.4:
                out.append(f"    x.f{i} = {lit(t)};")
            elif k < 0.7:
                p = self.fresh("p")
                out.append(f"    const {p} = &x.f{i};")
                out.append(f"    {p}.* = {lit(t)};")
            elif t != "bool":
                out.append(f"    x.f{i} {self.ch(['+%=', '-%=', '^=', '|='])} {lit(t)};")
            else:
                out.append(f"    x.f{i} = !x.f{i};")
        bits = f"@bitSizeOf({pn})"
        out.append(f"    const raw: @Int(.unsigned, {bits}) = @bitCast(x);")
        if self.p(0.5):
            out.append(f"    const y: {pn} = @bitCast(raw);")
            out.append("    break :blk .{ x, raw, y.f0, x == y };")
        else:
            un = self.fresh("U")
            out.append(f"    const {un} = packed union {{ s: {pn}, r: @TypeOf(raw) }};")
            out.append(f"    var u: {un} = .{{ .r = raw }};")
            out.append("    _ = &u;")
            out.append(f"    u.s.f0 = {lit(fts[0])};")
            out.append("    break :blk .{ x, raw, u.r, u.s };")
        out.append("};")
        return out, "any"

    def t_slices(self, name):
        """Slices and pointers into a comptime array."""
        et = self.ch([self.int_type(64), self.int_type(64), self.float_type()])
        n = self.r.randint(1, 10)
        out = [f"const {name} = blk: {{"]
        init = ", ".join(self.scalar_lit(et.name()) for _ in range(n))
        out.append(f"    var a: [{n}]{et.name()} = .{{ {init} }};")
        out.append("    _ = &a;")
        for _ in range(self.r.randint(1, 6)):
            lo = self.r.randint(0, n)
            hi = self.r.randint(lo, n) if self.p(0.95) else n + 1
            k = self.r.random()
            if k < 0.2:
                out.append(f"    for (a[{lo}..{hi}]) |*e| e.* = {self.scalar_lit(et.name())};")
            elif k < 0.35:
                out.append(f"    a[{self.r.randint(0, n - 1)}] = {self.scalar_lit(et.name())};")
            elif k < 0.5:
                p = self.fresh("p")
                out.append(f"    const {p}: [*]{et.name()} = &a;")
                out.append(f"    ({p} + {lo})[0] = {self.scalar_lit(et.name())};" if lo < n else f"    _ = {p};")
            elif k < 0.6:
                s = self.fresh("s")
                out.append(f"    const {s}: []{et.name()} = a[{lo}..{hi}];")
                out.append(f"    if ({s}.len > 0) {s}[{s}.len - 1] = {self.scalar_lit(et.name())};")
            elif k < 0.7:
                lo2 = self.r.randint(0, n)
                ln = self.r.randint(0, min(n - lo, n - lo2)) if self.p(0.9) else 1
                out.append(
                    f"    @memcpy(a[{lo}..][0..{ln}], a[{lo2}..][0..{ln}]);"
                    if self.p(0.2)
                    else f"    @memset(a[{lo}..{hi}], {self.scalar_lit(et.name())});"
                )
            elif k < 0.8:
                p = self.fresh("p")
                i = self.r.randint(0, n - 1)
                out.append(f"    const {p} = &a[{i}];")
                out.append(f"    {p}.* = {self.scalar_lit(et.name())};")
                if i + 1 < n and self.p(0.5):
                    out.append(f"    std.mem.swap({et.name()}, {p}, &a[{i + 1}]);")
            elif k < 0.9:
                out.append(f"    std.mem.reverse({et.name()}, a[{lo}..{hi}]);")
            else:
                s = self.fresh("s")
                out.append(f"    const {s} = a[{lo}..{hi}];")
                out.append(f"    const {s}c: []const {et.name()} = {s};")
                out.append(f"    a[0] = if ({s}c.len > 0) {s}c[0] else a[0];")
        if isinstance(et, Int) and self.p(0.3):
            out.append(f"    a[{n - 1}] = 0;")
            out.append(f"    const z: [:0]{et.name()} = a[0..{n - 1} :0];")
            out.append("    break :blk .{ a, z.len, std.mem.indexOfScalar(" + et.name() + ", z, z[0]) };")
        else:
            out.append("    break :blk a;")
        out.append("};")
        return out, "any"

    def t_opt_err(self, name):
        """Optionals and error unions through comptime calls."""
        t = self.int_type(64)
        f = self.fresh("f")
        g = self.fresh("g")
        es = self.fresh("E")
        out = [f"const {es} = error{{ A, B, C }};"]
        scope = [("x", t)]
        out.append(f"fn {f}(x: {t.name()}) ?{t.name()} {{")
        out.append("    _ = &x;")
        out.append(f"    if ({self.bool_expr(scope, 2)}) return null;")
        out.append(f"    return {self.int_expr(t, scope, 2)};")
        out.append("}")
        out.append(f"fn {g}(x: {t.name()}) {es}!{t.name()} {{")
        out.append("    _ = &x;")
        out.append(f"    if ({self.bool_expr(scope, 2)}) return error.{self.ch(['A', 'B', 'C'])};")
        out.append(f"    const y = {f}(x) orelse return error.{self.ch(['A', 'B'])};")
        out.append(f"    return y {self.ch(['+%', '^', '-%'])} {self.int_lit(t)};")
        out.append("}")
        h = self.fresh("h")
        out.append(f"fn {h}(x: {t.name()}) ({es} || error{{D}})!?{t.name()} {{")
        out.append(f"    const a = try {g}(x);")
        out.append(f"    if (a == {self.int_lit(t)}) return error.D;")
        out.append(f"    return if ({f}(a)) |b| b {self.ch(['&', '|', '+%'])} a else null;")
        out.append("}")
        n = self.r.randint(1, 8)
        args = ", ".join(self.int_lit(t) for _ in range(n))
        out.append(f"const {name} = blk: {{")
        out.append(f"    const args = [_]{t.name()}{{ {args} }};")
        out.append(f"    var r: [{n}]{t.name()} = undefined;")
        out.append(f"    var names: [{n}][]const u8 = undefined;")
        out.append("    for (args, &r, &names) |a, *o, *nm| {")
        k = self.r.random()
        if k < 0.4:
            out.append(f"        if ({h}(a)) |v| {{")
            out.append(f"            o.* = v orelse {self.int_lit(t)};")
            out.append('            nm.* = "ok";')
            out.append("        } else |e| {")
            out.append("            o.* = 0;")
            out.append("            nm.* = @errorName(e);")
            out.append("        }")
        elif k < 0.7:
            out.append(f"        o.* = {g}(a) catch |e| switch (e) {{ error.A => 1, error.B => 2, error.C => 3 }};")
            out.append(f'        nm.* = if ({f}(a) == null) "null" else "some";')
        else:
            out.append(f"        var it: ?{t.name()} = a;")
            out.append("        var steps: usize = 0;")
            out.append(f"        while (it) |v| : (steps += 1) {{ if (steps > 5) break; it = {f}(v); }}")
            out.append(f"        o.* = @bitCast(@as(u{t.bits}, @truncate(steps)));")
            out.append('        nm.* = if (it) |_| "some" else "null";')
        out.append("    }")
        out.append("    break :blk .{ r, names };")
        out.append("};")
        return out, "any"

    def t_typeinfo(self, name):
        """@typeInfo of generated types and their reconstruction."""
        out = []
        k = self.r.random()
        if k < 0.35:
            t = self.int_type()
            out.append(f"const {name} = blk: {{")
            out.append(f"    const info = @typeInfo({t.name()}).int;")
            out.append("    const R = @Int(info.signedness, info.bits);")
            out.append("    const W = @Int(info.signedness, info.bits + 1);")
            out.append(
                f"    break :blk .{{ R == {t.name()}, @bitSizeOf(W), @sizeOf(W), @alignOf(R), "
                f"std.math.maxInt(R) == std.math.maxInt({t.name()}), @typeName(W) }};"
            )
            out.append("};")
            return out, "any"
        if k < 0.7:
            sn = self.fresh("S")
            layout = self.ch(["", "extern ", "packed "])
            fts = []
            for _ in range(self.r.randint(1, 5)):
                if layout == "extern ":
                    fts.append(self.ch(["u8", "u16", "u32", "u64", "i32", "f32", "f64", "bool"]))
                else:
                    fts.append(self.ch(["u3", "u8", "i5", "u16", "bool", "u32", "i64", "u1", "f32"]))
            out.append(
                f"const {sn} = {layout}struct {{ "
                + ", ".join(
                    f"f{i}: {t}" + (f" = {self.scalar_lit(t)}" if self.p(0.4) else "") for i, t in enumerate(fts)
                )
                + ", pub const k = 3; fn m() void {} };"
            )
            out.append(f"const {name} = blk: {{")
            out.append(f'    const info = @typeInfo({sn}).@"struct";')
            out.append("    var attrs: [info.field_names.len]std.lang.Type.Struct.FieldAttributes = undefined;")
            out.append("    for (&attrs, info.field_attrs) |*a, b| a.* = b;")
            names = "info.field_names" if self.p(0.5) else "&.{" + ", ".join(f'"g{i}"' for i in range(len(fts))) + "}"
            out.append(
                f"    const T = @Struct(info.layout, info.backing_integer, {names}, info.field_types[0..info.field_names.len], &attrs);"
            )
            out.append("    var sum: usize = 0;")
            out.append("    for (info.field_names, 0..) |fname, i| {")
            out.append(f"        sum += @offsetOf({sn}, fname) * (i + 1) + @bitOffsetOf({sn}, fname);")
            out.append("    }")
            out.append("    const d: T = .{};" if all(False for _ in fts) else "    const d: ?T = null;")
            bitsize = "@bitSizeOf(T)" if layout == "packed " else "@sizeOf(T)"
            out.append(
                f"    break :blk .{{ @sizeOf(T) == @sizeOf({sn}), @alignOf(T), {bitsize}, info.decl_names.len, "
                f'info.field_names.len, sum, d == null, @hasDecl({sn}, "k"), @hasField(T, info.field_names[0]) }};'
            )
            out.append("};")
            return out, "any"
        # Enums and their fields.
        en = self.fresh("E")
        tag = self.ch(["u8", "u4", "i8", "u16", "i3"])
        bits, signed = int(tag[1:]), tag[0] == "i"
        lo, hi = (-(1 << (bits - 1)), (1 << (bits - 1)) - 1) if signed else (0, (1 << bits) - 1)
        vals = sorted({self.r.randint(lo, hi) for _ in range(self.r.randint(1, 6))})
        ne = self.p(0.3)
        out.append(
            f"const {en} = enum({tag}) {{ "
            + ", ".join(f"e{i} = {v}" for i, v in enumerate(vals))
            + (", _" if ne else "")
            + " };"
        )
        out.append(f"const {name} = blk: {{")
        out.append(f'    const info = @typeInfo({en}).@"enum";')
        out.append("    var vals: [info.field_values.len]info.tag_type = undefined;")
        out.append("    for (&vals, info.field_values) |*v, w| v.* = w;")
        out.append("    const R = @Enum(info.tag_type, info.mode, info.field_names, &vals);")
        out.append("    var acc: i64 = 0;")
        out.append("    for (info.field_names) |fname| acc = acc * 3 + @intFromEnum(@field(R, fname));")
        pick = self.r.randint(lo, hi)
        out.append(
            f'    const tag_name = if (std.enums.fromInt({en}, {pick})) |e| @tagName(e) else "none";'
            if not ne
            else f'    const tag_name = std.enums.tagName({en}, @enumFromInt({pick})) orelse "none";'
        )
        out.append(
            f"    break :blk .{{ acc, info.field_names.len, tag_name, @intFromEnum(@as(R, @enumFromInt({vals[0]}))), "
            f'std.meta.fieldIndex({en}, "e0") }};'
        )
        out.append("};")
        return out, "any"

    def t_generic(self, name):
        """Generic functions, `anytype`, and type-returning functions."""
        out = []
        k = self.r.random()
        if k < 0.4:
            gn = self.fresh("G")
            out.append(f"fn {gn}(comptime n: usize, comptime T: type) type {{")
            out.append("    return struct {")
            out.append("        data: [n]T,")
            out.append("        const Self = @This();")
            out.append("        fn fill(x: T) Self {")
            out.append("            var s: Self = undefined;")
            out.append("            for (&s.data, 0..) |*d, i| d.* = x +% @as(T, @intCast(i));")
            out.append("            return s;")
            out.append("        }")
            out.append("        fn sum(self: Self) T {")
            out.append("            var acc: T = 0;")
            out.append("            for (self.data) |d| acc " + self.ch(["+%=", "^=", "|="]) + " d;")
            out.append("            return acc;")
            out.append("        }")
            out.append("    };")
            out.append("}")
            ts = [self.int_type(64, 8) for _ in range(self.r.randint(1, 3))]
            out.append(f"const {name} = blk: {{")
            parts = []
            for i, t in enumerate(ts):
                n = self.r.randint(0, 9)
                out.append(f"    const V{i} = {gn}({n}, {t.name()});")
                out.append(f"    const s{i} = V{i}.fill({self.int_lit(t)});")
                parts.append(f"s{i}.sum()")
                parts.append(f"V{i} == {gn}({n}, {t.name()})")
            out.append(f"    break :blk .{{ {', '.join(parts)} }};")
            out.append("};")
            return out, "any"
        if k < 0.7:
            g = self.fresh("g")
            out.append(f"fn {g}(x: anytype) @TypeOf(x) {{")
            out.append("    const T = @TypeOf(x);")
            out.append("    return switch (@typeInfo(T)) {")
            out.append("        .int => |info| if (info.bits > 1) x ^ (x >> 1) else ~x,")
            out.append("        .float => x * 2 - 1,")
            out.append("        .bool => !x,")
            out.append("        .array => blk: {")
            out.append("            var y = x;")
            out.append(f"            for (&y) |*e| e.* = {g}(e.*);")
            out.append("            break :blk y;")
            out.append("        },")
            out.append("        .optional => if (x) |v| " + g + "(v) else null,")
            out.append("        else => x,")
            out.append("    };")
            out.append("}")
            vals = []
            for _ in range(self.r.randint(1, 4)):
                t = self.scalar_type()
                kk = self.r.random()
                if kk < 0.6:
                    vals.append(self.scalar_lit(t.name()))
                elif kk < 0.8:
                    n = self.r.randint(1, 4)
                    vals.append(f"[{n}]{t.name()}{{ " + ", ".join(self.scalar_lit(t.name()) for _ in range(n)) + " }")
                else:
                    vals.append(f"@as(?{t.name()}, {self.scalar_lit(t.name()) if self.p(0.6) else 'null'})")
            out.append(f"const {name} = .{{ " + ", ".join(f"{g}({v})" for v in vals) + " };")
            return out, "any"
        # Comptime recursion and memoization.
        f = self.fresh("rec")
        t = self.int_type(128, 8)
        out.append(f"fn {f}(comptime n: u32) {t.name()} {{")
        out.append(f"    if (n < 2) return {self.int_lit(t)};")
        out.append(
            f"    return {f}(n - 1) {self.ch(['+%', '*%', '^', '-%'])} {f}(n - 2) {self.ch(['+%', '^'])} @as({t.name()}, @intCast(n));"
        )
        out.append("}")
        out.append(f"const {name} = .{{ {f}({self.r.randint(0, 14)}), {f}({self.r.randint(0, 10)}) }};")
        return out, "any"

    def t_strings(self, name):
        """Comptime strings: `++`, comptimePrint, slicing."""
        out = [f"const {name} = blk: {{"]
        words = ["ab", "zig", "", "x", "hello", "\\x00", "\\xff"]
        out.append(f'    var s: []const u8 = "{self.ch(words)}";')
        for _ in range(self.r.randint(1, 5)):
            k = self.r.random()
            if k < 0.3:
                out.append(f'    s = s ++ "{self.ch(words)}";')
            elif k < 0.45:
                out.append("    s = if (s.len < 40) s ++ s else s;")
            elif k < 0.6:
                t = self.int_type(64)
                out.append(
                    f'    s = s ++ std.fmt.comptimePrint("{{d}}-{{x}}", .{{ {self.int_lit(t)}, {self.int_lit(t)} }});'
                )
            elif k < 0.75:
                lo = self.r.randint(0, 3)
                out.append(f"    s = if (s.len >= {lo}) s[{lo}..] else s;")
            elif k < 0.85:
                out.append(f"    s = s ++ .{{{self.r.randint(0, 255)}}};")
            else:
                out.append('    s = std.mem.trim(u8, s, "ab");')
        out.append("    const arr: [s.len]u8 = s[0..s.len].*;")
        out.append("    break :blk .{ arr, s.len, std.hash.Fnv1a_32.hash(s) };")
        out.append("};")
        return out, "any"

    def t_vector(self, name):
        """@Vector arithmetic, reductions, shuffles and selects at comptime."""
        et = self.ch([self.int_type(64), self.int_type(64), self.float_type(), BOOL])
        n = self.r.randint(1, 8)
        vt = f"@Vector({n}, {et.name()})"
        lits = lambda: f"{vt}{{ " + ", ".join(self.scalar_lit(et.name()) for _ in range(n)) + " }"
        out = [f"const {name} = blk: {{"]
        out.append(f"    var a: {vt} = {lits()};")
        out.append(f"    var b: {vt} = {lits()};")
        out.append("    _ = .{ &a, &b };")
        for _ in range(self.r.randint(1, 4)):
            k = self.r.random()
            if isinstance(et, Int):
                op = self.ch(["+%", "-%", "*%", "&", "|", "^", "+|", "-|"] + (["+", "*"] if self.risky() else []))
                if k < 0.5:
                    out.append(f"    a = a {op} b;")
                elif k < 0.6:
                    out.append("    a = @min(a, b) ^ @max(a, b);")
                elif k < 0.7:
                    out.append("    b = ~a;")
                elif k < 0.8:
                    out.append(f"    a = a << @splat({self.r.randint(0, et.bits - 1)});")
                else:
                    out.append(f"    a = @select({et.name()}, a > b, a, b);")
            elif isinstance(et, Float):
                if k < 0.5:
                    out.append(f"    a = a {self.ch(['+', '-', '*', '/'])} b;")
                elif k < 0.7:
                    out.append(f"    a = {self.ch(['@sqrt', '@floor', '@abs', '@trunc', '@round'])}(a);")
                else:
                    out.append(f"    a = @select({et.name()}, a < b, a, b);")
            else:
                out.append(
                    f"    a = {self.ch(['a == b', 'a != b', '!a', '@select(bool, a, b, a)'])};"
                    if k < 0.5
                    else "    b = a;"
                )
        mask = ", ".join(
            str(self.r.choice([self.r.randint(0, n - 1), ~self.r.randint(0, n - 1)]))
            for _ in range(self.r.randint(1, 8))
        )
        red = {
            "int": ["Add", "Mul", "And", "Or", "Xor", "Min", "Max"],
            "float": ["Min", "Max", "Add", "Mul"],
            "bool": ["And", "Or", "Xor"],
        }
        kind = "int" if isinstance(et, Int) else ("float" if isinstance(et, Float) else "bool")
        rop = self.ch(red[kind])
        if kind == "int" and rop in ("Add", "Mul") and not self.risky():
            rop = self.ch(["And", "Or", "Xor", "Min", "Max"])
        out.append(f"    const sh = @shuffle({et.name()}, a, b, [_]i32{{ {mask} }});")
        out.append(f"    const arr: [{n}]{et.name()} = a;")
        out.append(
            f"    break :blk .{{ a, sh, @reduce(.{rop}, a), arr[{self.r.randint(0, n - 1)}], a[{self.r.randint(0, n - 1)}] }};"
        )
        out.append("};")
        return out, "any"

    def t_union(self, name):
        """Tagged unions built, switched on and changed at comptime."""
        un = self.fresh("U")
        fts = [
            self.ch(["u8", "i16", "u32", "f32", "bool", "void", "[3]u8", "?u16", "i64"])
            for _ in range(self.r.randint(2, 5))
        ]
        tag = self.ch(["enum", "enum(u8)", "enum(u16)"])
        out = [f"const {un} = union({tag}) {{ " + ", ".join(f"f{i}: {t}" for i, t in enumerate(fts)) + " };"]

        def lit(i):
            t = fts[i]
            if t == "void":
                return f"{un}{{ .f{i} = {{}} }}"
            if t == "[3]u8":
                return f"{un}{{ .f{i} = .{{ {self.r.randint(0, 255)}, {self.r.randint(0, 255)}, {self.r.randint(0, 255)} }} }}"
            if t == "?u16":
                return f"{un}{{ .f{i} = {self.r.choice(['null', str(self.r.randint(0, 65535))])} }}"
            return f"{un}{{ .f{i} = {self.scalar_lit(t)} }}"

        out.append(f"fn {un}_score(u: {un}) u64 {{")
        out.append("    return switch (u) {")
        for i, t in enumerate(fts):
            if t == "void":
                out.append(f"        .f{i} => {i},")
            elif t == "bool":
                out.append(f"        .f{i} => |v| @as(u64, @intFromBool(v)) + {i},")
            elif t == "f32":
                out.append(f"        .f{i} => |v| if (std.math.isNan(v)) 7 else @as(u64, @intFromBool(v > 0)) + 10,")
            elif t == "[3]u8":
                out.append(f"        .f{i} => |v| @as(u64, v[0]) + @as(u64, v[1]) * 3 + v[2],")
            elif t == "?u16":
                out.append(f"        .f{i} => |v| if (v) |w| w else 99,")
            else:
                out.append(f"        .f{i} => |v| @as(u64, @bitCast(@as(i64, v))),")
        out.append("    };")
        out.append("}")
        out.append(f"const {name} = blk: {{")
        k = self.r.randrange(len(fts))
        out.append(f"    var u: {un} = {lit(k)};")
        out.append("    _ = &u;")
        out.append(f"    var acc: u64 = {un}_score(u);")
        for _ in range(self.r.randint(1, 4)):
            j = self.r.randrange(len(fts))
            r = self.r.random()
            if r < 0.4:
                out.append(f"    u = {lit(j)};")
            elif r < 0.7 and fts[j] not in ("void",):
                out.append(
                    f"    switch (u) {{ .f{j} => |*p| {{ p.* = ({lit(j)}).f{j}; }}, else => {{ u = {lit(j)}; }} }}"
                )
            else:
                out.append(f"    if (u == .f{j}) acc +%= 1000;")
            out.append(f"    acc = acc *% 31 +% {un}_score(u);")
        out.append("    break :blk .{ acc, @tagName(u), @intFromEnum(std.meta.activeTag(u)), u };")
        out.append("};")
        return out, "any"

    def t_memory(self, name):
        """Nested aggregates in a comptime var, changed through pointers
        to their fields and elements, slices of them, and copies."""
        et = self.ch(["u8", "u16", "i32", "u64", "f32", "bool", "u5"])
        inner = self.fresh("In")
        outer = self.fresh("Out")
        n = self.r.randint(1, 4)
        m = self.r.randint(1, 4)
        layout = self.ch(["", "extern "]) if et not in ("u5", "bool") else ""
        out = [
            f"const {inner} = {layout}struct {{ a: {et}, b: [{n}]{et} }};",
            f"const {outer} = {layout}struct {{ x: [{m}]{inner}, y: u32 }};",
        ]

        def ilit():
            return (
                f"{inner}{{ .a = {self.scalar_lit(et)}, .b = .{{ "
                + ", ".join(self.scalar_lit(et) for _ in range(n))
                + " } }"
            )

        out.append(f"const {name} = blk: {{")
        out.append(
            f"    var o: {outer} = .{{ .x = .{{ "
            + ", ".join(ilit() for _ in range(m))
            + f" }}, .y = {self.r.randint(0, 99)} }};"
        )
        out.append("    _ = &o;")
        out.append(f"    var copy: {outer} = o;")
        out.append("    _ = &copy;")
        for _ in range(self.r.randint(1, 7)):
            i, j = self.r.randrange(m), self.r.randrange(n)
            k = self.r.random()
            if k < 0.15:
                out.append(f"    o.x[{i}].b[{j}] = {self.scalar_lit(et)};")
            elif k < 0.3:
                p = self.fresh("p")
                out.append(f"    const {p} = &o.x[{i}];")
                out.append(f"    {p}.a = {p}.b[{j}];")
                out.append(f"    {p}.b[{self.r.randrange(n)}] = {self.scalar_lit(et)};")
            elif k < 0.4:
                p = self.fresh("p")
                out.append(f"    const {p}: []{et} = &o.x[{i}].b;")
                out.append(f"    for ({p}, 0..) |*e, idx| {{ if (idx % 2 == 0) e.* = o.x[{i}].a; }}")
            elif k < 0.5:
                out.append(f"    o.x[{i}] = copy.x[{self.r.randrange(m)}];")
            elif k < 0.6:
                out.append(f"    std.mem.swap({inner}, &o.x[{i}], &o.x[{self.r.randrange(m)}]);")
            elif k < 0.7:
                lo = self.r.randint(0, m)
                out.append(f"    for (o.x[{lo}..]) |*e| e.a = e.b[{n - 1}];")
            elif k < 0.8:
                p = self.fresh("pp")
                out.append(f'    const {p}: *{inner} = @fieldParentPtr("a", &o.x[{i}].a);')
                out.append(f"    {p}.b[0] = {p}.a;")
            elif k < 0.9 and not layout:
                yp = self.fresh("yp")
                out.append("    o.y +%= 3;")
                out.append(f"    const {yp}: *const u32 = &o.y;")
                out.append(f"    copy.y = {yp}.*;")
            else:
                out.append("    copy = o;")
                out.append(f"    copy.x[{i}].a = {self.scalar_lit(et)};")
        out.append("    var as: [" + str(m) + "]" + et + " = undefined;")
        out.append("    for (o.x, &as) |e, *a| a.* = e.a;")
        out.append("    break :blk .{ o.x, copy.x, o.y, copy.y, as };")
        out.append("};")
        return out, "any"

    def t_stdlib(self, name):
        """std code run at comptime: sorting, searching, parsing, hashing,
        formatting and integer math, which exercise large swaths of the
        evaluator through real library code."""
        et = self.ch(["u8", "i16", "u32", "i64", "u7"])
        n = self.r.randint(0, 9)
        vals = [self.scalar_lit(et) for _ in range(n)]
        out = [f"const {name} = blk: {{"]
        out.append("    @setEvalBranchQuota(100000);")
        out.append(f"    var a: [{n}]{et} = .{{ " + ", ".join(vals) + " };")
        out.append("    _ = &a;")
        out.append("    var acc: u64 = 0;")
        out.append("    _ = &acc;")
        res = []
        for _ in range(self.r.randint(1, 5)):
            k = self.r.random()
            v = self.fresh("v")
            if k < 0.15:
                out.append(f"    std.mem.sort({et}, &a, {{}}, std.sort.{self.ch(['asc', 'desc'])}({et}));")
            elif k < 0.25:
                out.append(f"    std.mem.reverse({et}, &a);")
            elif k < 0.35:
                out.append(f"    const {v} = std.mem.indexOfScalar({et}, &a, {self.scalar_lit(et)});")
                res.append(v)
            elif k < 0.45:
                num = self.ch(
                    ["0", "-0", "123", "-128", "0x7f", "0b101", "1_000", "99999999999", "zz", "", "+5", "0o17"]
                )
                base = self.ch(["0", "10", "16"])
                t = self.ch(["u8", "i8", "i32", "u64", "i128"])
                out.append(f'    const {v} = std.fmt.parseInt({t}, "{num}", {base}) catch |e| @errorName(e);')
                res.append(v)
            elif k < 0.55:
                t = self.ch(["u8", "i32", "u64", "u17"])
                out.append(
                    f'    const {v} = std.fmt.comptimePrint("{{d}}|{{x:0>4}}|{{b}}|{{any}}", .{{ {self.int_lit(Int(False, 32))}, {self.int_lit(Int(False, 16))}, @as({t}, {self.r.randint(0, 127)}), a }});'
                )
                res.append(v)
            elif k < 0.62:
                out.append("    for (a) |x| acc = std.hash.Wyhash.hash(acc, std.mem.asBytes(&x));")
            elif k < 0.7:
                x, y = self.r.randint(1, 1 << 40), self.r.randint(1, 1 << 20)
                out.append(
                    f"    const {v} = .{{ std.math.gcd(@as(u64, {x}), {y}), std.math.log2_int(u64, {x}), std.math.sqrt(@as(u64, {x})), std.math.divCeil(u64, {x}, {y}) catch 0 }};"
                )
                res.append(v)
            elif k < 0.78:
                b, e = self.r.randint(0, 12), self.r.randint(0, 20)
                t = self.ch(["u32", "i64", "u128"])
                out.append(f"    const {v} = std.math.powi({t}, {b}, {e}) catch |err| @errorName(err);")
                res.append(v)
            elif k < 0.86:
                out.append(f"    const {v} = std.mem.max({et}, &(a ++ [_]{et}{{{self.scalar_lit(et)}}}));")
                res.append(v)
            elif k < 0.93:
                w = self.ch(["Hello", "zig", "ABC def", ""])
                out.append(f'    var {v}: [{len(w)}]u8 = "{w}".*;')
                out.append(f"    for (&{v}) |*c| c.* = std.ascii.{self.ch(['toUpper', 'toLower'])}(c.*);")
                res.append(v)
            else:
                out.append(f"    var {v} = std.bit_set.Integer(70).empty;")
                out.append(f"    for (a) |x| {v}.set(@as(usize, @intCast(@as(u64, @bitCast(@as(i64, x))) % 70)));")
                out.append(f"    acc +%= {v}.count();")
        out.append("    const fin = a;")
        out.append("    break :blk .{ fin, acc" + "".join(", " + r for r in res) + " };")
        out.append("};")
        return out, "any"

    def t_control(self, name):
        """Comptime control flow: labeled switch continue, recursion,
        defer and errdefer, while-else, try and catch in comptime calls."""
        fn = self.fresh("rec")
        out = [
            f"fn {fn}(n: u32) error{{Neg, Big}}!u64 {{",
            "    if (n > 60) return error.Big;",
            "    if (n < 2) return n;",
            f"    return (try {fn}(n - 1)) +% (try {fn}(n - 2)) +% {self.r.randint(0, 3)};",
            "}",
        ]
        st = self.fresh("St")
        out.append(f"const {st} = enum(u8) {{ a, b, c, d, _ }};")
        out.append(f"fn sm_{fn}(start: {st}, steps: u32) u32 {{")
        out.append("    var n = steps;")
        out.append("    var log: u32 = 0;")
        out.append("    sw: switch (start) {")
        out.append(
            f"        .a => {{ log = log *% 3 +% 1; if (n == 0) break :sw; n -= 1; continue :sw .{self.ch('bcd')}; }},"
        )
        out.append(
            f"        .b => {{ log = log *% 5 +% 2; if (n == 0) break :sw; n -= 1; continue :sw if (n % 2 == 0) .a else .{self.ch('cd')}; }},"
        )
        out.append(
            f"        .c => {{ log = log *% 7 +% 3; if (n == 0) break :sw; n -= 1; continue :sw @enumFromInt({self.r.randint(0, 5)}); }},"
        )
        out.append("        .d => { log +%= 4; if (n == 0) break :sw; n -= 1; continue :sw .a; },")
        out.append("        _ => { log +%= 100; if (n == 0) break :sw; n -= 1; continue :sw .b; },")
        out.append("    }")
        out.append("    return log;")
        out.append("}")
        out.append(f"fn df_{fn}(x: *u32, fail: bool) !u32 {{")
        out.append("    defer x.* +%= 10;")
        out.append("    errdefer x.* *%= 2;")
        out.append("    x.* +%= 1;")
        out.append("    if (fail) return error.Fail;")
        out.append("    return x.*;")
        out.append("}")
        out.append(f"const {name} = blk: {{")
        out.append("    @setEvalBranchQuota(50000);")
        rec_n = self.r.randint(0, 16) if self.p(1 - self.risk) else self.r.randint(55, 70)
        out.append(f"    const r1 = {fn}({rec_n}) catch |e| @errorName(e);")
        out.append(f"    const r2 = sm_{fn}(@enumFromInt({self.r.randint(0, 6)}), {self.r.randint(0, 30)});")
        out.append(f"    var x: u32 = {self.r.randint(0, 9)};")
        out.append(f"    const r3 = df_{fn}(&x, {self.ch(['true', 'false'])}) catch |e| @errorName(e);")
        out.append("    var i: u32 = 0;")
        out.append(f"    const r4 = while (i < {self.r.randint(0, 12)}) : (i += 1) {{")
        out.append(f"        if (i * i > {self.r.randint(0, 50)}) break i;")
        out.append("    } else 1000;")
        out.append("    break :blk .{ r1, r2, x, r3, r4 };")
        out.append("};")
        return out, "any"

    KINDS = (
        (t_arith, 5),
        (t_fn_eval, 4),
        (t_bitcast, 3),
        (t_ptrcast, 2),
        (t_packed, 2),
        (t_slices, 2),
        (t_opt_err, 2),
        (t_typeinfo, 2),
        (t_generic, 2),
        (t_strings, 1),
        (t_vector, 2),
        (t_union, 2),
        (t_memory, 3),
        (t_stdlib, 2),
        (t_control, 2),
    )

    def test(self, i):
        self.risk = self.ch([0.02, 0.1, 0.3])
        fns, ws = zip(*self.KINDS)
        kind = self.r.choices(fns, ws)[0]
        lines, rt = kind(self, f"t{i}")
        return kind.__name__, lines, rt


def generate(seed, size=1.0, only=None):
    g = Gen(seed, size)
    n = max(1, int(g.r.randint(8, 16) * size))
    out = [f"// cthunt seed {seed}", 'const std = @import("std");', ""]
    prints = []
    for i in range(n):
        kind, lines, rt = g.test(i)
        if only is not None and i not in only:
            continue
        out.append(f"// test {i} {kind}")
        out += lines
        # A comptime block of its own analyzes the test even when an
        # earlier test's error stops main's analysis.
        out.append(f"comptime {{ _ = t{i}; }}")
        out.append(f"// end {i}")
        if isinstance(rt, Float):
            # The bits too (the sign of zero, rounding), except a NaN's:
            # its sign and payload are not specified.
            prints.append(
                f'    std.debug.print("t{i} {{any}} {{x}}\\n", .{{ t{i}, if (std.math.isNan(t{i})) 0 else @as(u{rt.bits}, @bitCast(t{i})) }}); // test {i}'
            )
        else:
            prints.append(f'    std.debug.print("t{i} {{any}}\\n", .{{t{i}}}); // test {i}')
    out.append("")
    out.append("pub fn main() void {")
    out += prints
    out.append("}")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else random.randrange(1 << 32)
    sys.stdout.write(generate(seed, float(sys.argv[2]) if len(sys.argv) > 2 else 1.0))
