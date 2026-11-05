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
import re
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
# MCHUNT_BOOST=vector=8,sroa=3: weight multipliers for statement kinds
# (aiming a campaign at one pass).
BOOST = {k: float(v) for k, v in (x.split("=") for x in filter(None, __import__("os").environ.get("MCHUNT_BOOST", "").split(",")))}


# Struct results of 32 to 256 bytes from non-inlined calls (s_retbig).
# Fields: (name, int type, array length or 0).
RB_TYPES = {
    "R32": [("a", "u64", 0), ("b", "u32", 0), ("c", "u16", 0), ("d", "u8", 0), ("e", "u8", 13)],
    "R72": [("a", "u64", 3), ("b", "u32", 0), ("c", "i16", 0), ("d", "u16", 5), ("e", "u8", 0), ("f", "u64", 0)],
    "R136": [("a", "u64", 16), ("b", "u8", 0)],
    "R256": [("a", "u64", 31), ("b", "u32", 0), ("c", "u16", 0), ("d", "u8", 0)],
}


def _rb_decl():
    out = []
    for tn, fs in RB_TYPES.items():
        ty = lambda t, n: f"[{n}]{t}" if n else t
        out.append(f"const {tn} = struct {{ {', '.join(f'{f}: {ty(t, n)}' for f, t, n in fs)} }};")
        out.append(f"var g{tn}: {tn} = undefined;")
        cv = lambda t, e: f"@as({t}, @truncate({e}))" if t[0] == "u" else f"@as({t}, @bitCast(@as(u{t[1:]}, @truncate({e}))))"
        # Every field written, some twice; an early return after a partial overwrite.
        out.append(f"noinline fn mk{tn}(x: u64, c: bool) {tn} {{")
        out.append(f"    var r: {tn} = undefined;")
        for k, (f, t, n) in enumerate(fs):
            if n:
                out.append(f"    for (&r.{f}, 0..) |*p, i| p.* = {cv(t, f'x +% @as(u64, i) *% {0x9E37 + k}')};")
            else:
                out.append(f"    r.{f} = {cv(t, f'x >> {k * 5}')};")
        f0, t0, n0 = fs[-1]
        out.append(f"    if (c) {{")
        out.append(f"        r.{f0}{'[1]' if n0 else ''} = {cv(t0, 'x *% 3')};")
        out.append("        return r;")
        out.append("    }")
        f1, t1, n1 = fs[0]
        out.append(f"    r.{f1}{'[0]' if n1 else ''} ^= {cv(t1, '~x')};")
        out.append("    return r;")
        out.append("}")
        # A result built in place from an aggregate literal.
        lit = []
        for k, (f, t, n) in enumerate(fs):
            if n:
                lit.append(f".{f} = @splat({cv(t, f'x +% {k}')})")
            else:
                lit.append(f".{f} = {cv(t, f'x ^ {k * 0x1111}')}")
        out.append(f"noinline fn mk2{tn}(x: u64) {tn} {{ return .{{ {', '.join(lit)} }}; }}")
        # By value in, result out (callers pass the location they assign to).
        f2, t2, n2 = fs[len(fs) // 2]
        out.append(f"noinline fn ed{tn}(v: {tn}, x: u64) {tn} {{")
        out.append(f"    var r = v;")
        out.append(f"    r.{f2}{'[' + str(n2 - 1) + ']' if n2 else ''} +%= {cv(t2, 'x')};")
        out.append(f"    r.{f1}{'[0]' if n1 else ''} +%= 1;")
        out.append("    return r;")
        out.append("}")
        terms = []
        for f, t, n in fs:
            w = (lambda e: f"@as(u64, {e})") if t[0] == "u" else (lambda e: f"@as(u64, @as(u{t[1:]}, @bitCast({e})))")
            if n:
                terms.append(f"for (v.{f}) |e| h = (h ^ {w('e')}) *% 0x100000001b3;")
            else:
                terms.append(f"h = (h ^ {w(f'v.{f}')}) *% 0x9E3779B97F4A7C15;")
        # Results through error unions, and loops inside inlined callees (s_erragg).
        fa, ta, na = next((x for x in fs if x[2]), fs[0])
        fl = f"{fa}[i % {na}]" if na else fa
        out.append(f"noinline fn eg{tn}(x: u64, k: u2) E!{tn} {{")
        out.append("    if (k == 3) return error.Beta;")
        out.append(f"    var r = mk2{tn}(x);")
        out.append("    if (k == 2) {")
        out.append(f"        r.{f2}{'[0]' if n2 else ''} = {cv(t2, 'x >> 3')};")
        out.append("        return r;")
        out.append("    }")
        out.append(f"    return mk{tn}(x, k == 1);")
        out.append("}")
        out.append(f"inline fn il{tn}(x: u64, n: usize) {tn} {{")
        out.append(f"    var r = mk2{tn}(x);")
        out.append("    var i: usize = 0;")
        out.append("    while (i < n) : (i += 1) {")
        out.append(f"        r.{fl} +%= {cv(ta, 'i *% 7 +% x')};")
        out.append(f"        r.{f1}{'[0]' if n1 else ''} ^= {cv(t1, 'i')};")
        out.append("    }")
        out.append("    return r;")
        out.append("}")
        out.append(f"inline fn ilE{tn}(x: u64, n: usize) E!{tn} {{")
        out.append("    if (n > 5) return error.Gamma;")
        out.append(f"    var r = try eg{tn}(x, @truncate(n));")
        out.append(f"    for (0..n) |i| r.{fl} -%= {cv(ta, 'i')};")
        out.append("    return r;")
        out.append("}")
        out.append(f"fn tr{tn}(x: u64, k: u2) E!u64 {{")
        out.append(f"    const v = try eg{tn}(x, k);")
        out.append(f"    return fold{tn}(&v);")
        out.append("}")
        out.append(f"fn fold{tn}(v: *const {tn}) u64 {{")
        out.append(f"    var h: u64 = 0;")
        for t_ in terms:
            out.append(f"    {t_}")
        out.append("    return h;")
        out.append("}")
    return out


RB_DECL = _rb_decl()

# Packed structs for s_packstore. Fields: (name, kind, default or None);
# kinds are ("u", bits), ("i", bits), "bool", "PE", or a packed type name.
PK_TYPES = {
    "PN": (6, [("x", ("u", 2), None), ("y", ("i", 4), None)]),
    "P8": (8, [("a", ("u", 3), None), ("b", "bool", "true"), ("c", ("i", 4), None)]),
    "P16": (16, [("a", ("u", 5), "3"), ("b", "PE", None), ("c", "PN", None), ("d", "bool", None), ("e", ("u", 1), "1")]),
    "P32": (32, [("a", ("i", 7), None), ("b", ("u", 9), "100"), ("c", "PN", None), ("d", "PE", ".c"), ("e", "bool", None),
                 ("f", ("u", 6), None)]),
    "P64": (64, [("a", ("u", 20), None), ("b", ("i", 13), "-5"), ("c", "P8", None), ("d", "PE", None), ("e", ("u", 17), "0x1abcd"),
                 ("f", "bool", "false"), ("g", ("u", 2), None)]),
    "P128": (128, [("a", ("u", 60), None), ("b", ("i", 30), "-77"), ("c", "P16", None), ("d", ("u", 22), None)]),
}
PK_HOSTS = ["P8", "P16", "P32", "P64", "P128"]


def pk_bits(kind):
    if isinstance(kind, tuple):
        return kind[1]
    return {"bool": 1, "PE": 3}.get(kind) or PK_TYPES[kind][0]


def pk_to_u64(e, kind):
    """A packed field's value as u64 bits (u128 hosts fold their halves)."""
    if kind == "bool":
        return f"@as(u64, @intFromBool({e}))"
    if kind == "PE":
        return f"@as(u64, @intFromEnum({e}))"
    b = pk_bits(kind)
    if b == 128:
        return f"blk: {{ const w: u128 = @bitCast({e}); break :blk @as(u64, @truncate(w)) ^ @as(u64, @truncate(w >> 64)); }}"
    return f"@as(u64, @as(u{b}, @bitCast({e})))"


def pk_from_u64(e, kind, checked=False):
    """A field value of `kind` from the u64 expression `e`; `checked` uses
    @intCast (a safety check that can fire) instead of @truncate."""
    if kind == "bool":
        return f"(({e}) & 1 == 1)"
    if kind == "PE":
        return f"@as(PE, @enumFromInt(@as(u3, @truncate({e})) % 5))"
    if isinstance(kind, tuple):
        sg, b = kind
        if sg == "u":
            return f"@as(u{b}, @intCast({e}))" if checked else f"@as(u{b}, @truncate({e}))"
        if checked:
            return f"@as(i{b}, @intCast(@as(i64, @bitCast({e}))))"
        return f"@as(i{b}, @bitCast(@as(u{b}, @truncate({e}))))"
    return f"@as({kind}, @bitCast(@as(u{PK_TYPES[kind][0]}, @truncate({e}))))"


def _pk_decl():
    out = ["const PE = enum(u3) { a, b, c, d, e };"]
    for tn, (bits, fs) in PK_TYPES.items():
        fl = []
        for f, k, d in fs:
            ty = k if isinstance(k, str) else f"{k[0]}{k[1]}"
            fl.append(f"{f}: {ty}" + (f" = {d}" if d is not None else ""))
        out.append(f"const {tn} = packed struct(u{bits}) {{ {', '.join(fl)} }};")
    for tn in PK_HOSTS:
        b = PK_TYPES[tn][0]
        out.append(f"var g{tn}: {tn} = @bitCast(@as(u{b}, {hex((0x5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a >> (128 - b)))}));")
        # A whole literal built from x, through an inlined function.
        fs = PK_TYPES[tn][1]
        lit = ", ".join(f".{f} = {pk_from_u64(f'x >> {i * 7}', k)}" for i, (f, k, _) in enumerate(fs))
        out.append(f"inline fn pkSet{tn}(p: *{tn}, x: u64) void {{ p.* = .{{ {lit} }}; }}")
    out.append("var gPA: [3]P32 = @bitCast([3]u32{ 0x01234567, 0x89abcdef, 0x0f1e2d3c });")
    out.append("var gPS: struct { pad: u8, p: P16 } = .{ .pad = 7, .p = @bitCast(@as(u16, 0xbeef)) };")
    # A failed safety check prints the hosts' bits, so the memory at the
    # check is compared, and exits 0.
    out.append("pub const panic = std.debug.FullPanic(pkPanic);")
    out.append("fn pkPanic(msg: []const u8, _: ?usize) noreturn {")
    out.append('    std.debug.print("ck pkpanic {s} {x} {x} {x} {x} {x} {x} {x} {x} {x}\\n", .{ msg, @as(u8, @bitCast(gP8)), '
               '@as(u16, @bitCast(gP16)), @as(u32, @bitCast(gP32)), @as(u64, @bitCast(gP64)), @as(u128, @bitCast(gP128)), '
               '@as(u32, @bitCast(gPA[0])), @as(u32, @bitCast(gPA[1])), @as(u32, @bitCast(gPA[2])), @as(u16, @bitCast(gPS.p)) });')
    out.append("    std.process.exit(0);")
    out.append("}")
    return out


PK_DECL = _pk_decl()

# Declarations for shapes from corpus miscompiles; a program gets the
# ones it uses.
EXTRA_DECL = {
    # 1. Aggregates over 16 bytes returned early straight from a global.
    "rvo": [
        "const QS = struct { pad: u32, f: [4]u64, d: [4]f64 };",
        "var gQ4: [4]u64 = .{ 0x1111, 0x2222, 0x3333, 0x4444 };",
        "var gQD: [4]f64 = .{ 1.5, -2.25, 3.0, 0.5 };",
        "var gQS: QS = .{ .pad = 9, .f = .{ 5, 6, 7, 8 }, .d = .{ -1.0, 2.5, 0.25, 8.0 } };",
        "noinline fn rq0(k: u8) [4]u64 {",
        "    if (k & 3 == 0) return gQ4;",
        "    if (k & 3 == 1) return gQS.f;",
        "    var r: [4]u64 = undefined;",
        "    for (&r, 0..) |*p, i| p.* = @as(u64, k) *% (i + 1);",
        "    return r;",
        "}",
        "noinline fn rq1(k: u8) [4]f64 {",
        "    if (k % 3 == 0) return gQD;",
        "    if (k % 3 == 1) return gQS.d;",
        "    return .{ @floatFromInt(k), 1.0, 2.0, @floatFromInt(k >> 1) };",
        "}",
        "noinline fn rq2(k: u8) QS {",
        "    if (k & 1 == 0) return gQS;",
        "    const r: QS = .{ .pad = k, .f = .{ k, 1, 2, 3 }, .d = .{ 0.5, 1.5, 2.5, 3.5 } };",
        "    return r;",
        "}",
        "noinline fn rq3(k: u8, b: bool) [4]u64 {",
        "    if (b) {",
        "        if (k > 100) return gQS.f;",
        "        return gQ4;",
        "    }",
        "    return .{ k, k +% 1, k +% 2, k +% 3 };",
        "}",
    ],
    # 2. An and/or bool live across a call returning an optional, an early
    # return, then returned from a later block.
    "boolret": [
        "noinline fn qfind(s: []const u8, ch: u8) ?usize {",
        "    for (s, 0..) |c, i| if (c == ch) return i;",
        "    return null;",
        "}",
        "noinline fn bq0(a: u32, b: u32, s: []const u8) bool {",
        "    const c = (a < b and b != 7) or s.len > 5;",
        "    const idx = qfind(s, @truncate(a)) orelse 99;",
        "    if (idx == b) return false;",
        "    if (a == 3) {",
        "        if (b & 1 == 0) return true;",
        "    }",
        "    return c;",
        "}",
        "noinline fn bq1(a: u32, b: u32, s: []const u8) bool {",
        "    const c = a != 0 and (b > a or s.len == 0);",
        "    var n: usize = 0;",
        "    while (n < 3) : (n += 1) {",
        "        if (qfind(s, @truncate(b +% @as(u32, @intCast(n))))) |i| {",
        "            if (i == a) return !c;",
        "        }",
        "    }",
        "    return c;",
        "}",
        "noinline fn bq2(a: u32, b: u32, s: []const u8) u8 {",
        "    const c = a > b or (s.len > 1 and s[1] == 'q');",
        "    const i = qfind(s, 'z') orelse return @as(u8, @intFromBool(c)) + 10;",
        "    if (i > a) return 7;",
        "    return @intFromBool(c);",
        "}",
        "const qstr = [_][]const u8{ \"\", \"qz\", \"xyz\", \"aqzzzzq\", \"zz\" };",
    ],
    # 3. Inline asm naming register-pinned operands.
    "asmpin": [
        "fn asmTarget() callconv(.c) u64 { return 0x1234; }",
        "fn asmTarget2() callconv(.c) u64 { return 0xfeed; }",
        "noinline fn asmNop() void { std.mem.doNotOptimizeAway(@as(u8, 1)); }",
        "noinline fn asmCall(f: *const fn () callconv(.c) u64) u64 {",
        "    asmNop();",
        "    return asm volatile (\"callq *%[callee]\"",
        "        : [ret] \"={rax}\" (-> u64),",
        "        : [callee] \"{rax}\" (f),",
        "        : .{ .rcx = true, .rdx = true, .rsi = true, .rdi = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .memory = true });",
        "}",
        "noinline fn asmAdd(a: u64, b: u64) u64 {",
        "    return asm (\"addq %[b], %[a]\"",
        "        : [ret] \"={rax}\" (-> u64),",
        "        : [a] \"{rax}\" (a),",
        "          [b] \"{rcx}\" (b),",
        "    );",
        "}",
        "noinline fn asmXchg(a: u64, b: u64) u64 {",
        "    var x = a;",
        "    var y = b;",
        "    asm (\"xchgq %[x], %[y]\"",
        "        : [x] \"={rdx}\" (x),",
        "          [y] \"={rsi}\" (y),",
        "        : [xi] \"{rdx}\" (x),",
        "          [yi] \"{rsi}\" (y),",
        "    );",
        "    return x -% y;",
        "}",
    ],
    # Switch shapes (s_swx).
    "swx": [
        "var gSwCnt: u64 = 0;",
        "noinline fn swSide(v: u64) bool {",
        "    gSwCnt = gSwCnt *% 31 +% v +% 1;",
        "    return v & 1 == 1;",
        "}",
        "const SwN = enum(i8) { lo = -128, m1 = -1, z = 0, f = 5, hi = 127, _ };",
        "const SwX = enum(i16) { a = -300, b = -2, c = 7, d = 1000 };",
        "const SwU = enum(u3) { a, b, c, d, e, f, g, h };",
    ],
    # 4. Calls through @extern and extern pointers whose result goes back
    # into the variable the argument came from.
    "xcall": [
        "export fn mchExp1(x: u64) u64 { return x *% 3 +% 1; }",
        "fn mchE2(x: u64) callconv(.c) u64 { return (x ^ 0x5555) +% 7; }",
        "comptime { @export(&mchE2, .{ .name = \"mchExp2\" }); }",
        "extern fn mchExp2(x: u64) callconv(.c) u64;",
        "fn mchE3(x: u64, y: u64) callconv(.c) u64 { return x -% (y << 1); }",
        "comptime { @export(&mchE3, .{ .name = \"mchExp3\" }); }",
        "noinline fn xf(x: u64) u64 { return x +% 0x10; }",
    ],
}

# By-value aggregates read through a pointer parameter that stays live
# past an sret call (s_argbase). Name: (type, fold expression over `d`,
# literal from x).
AB_TYPES = {
    "S16": ("struct { s: []const u64 }", "blk: { var h: u64 = 0; for (d.s) |e| h = (h ^ e) *% 0x100000001b3; break :blk h; }",
            None),
    "U16": ("struct { a: u64, b: u64 }", "d.a ^ (d.b *% 3)", ".{{ .a = {x}, .b = {x} >> 7 }}"),
    "B7": ("[7]u8", "blk: { var h: u64 = 0; for (d) |e| h = (h << 3) ^ e; break :blk h; }", "@as([7]u8, @splat(@truncate({x})))"),
    "B15": ("[15]u8", "blk: { var h: u64 = 0; for (d) |e| h = (h *% 5) ^ e; break :blk h; }", "@as([15]u8, @splat(@truncate({x})))"),
    "B9": ("struct { a: [8]u8, b: u8 }", "(@as(u64, d.a[0]) << 8) ^ d.a[7] ^ (@as(u64, d.b) << 16)",
           ".{{ .a = @splat(@truncate({x})), .b = @truncate({x} >> 8) }}"),
    "B11": ("struct { a: [8]u8, b: [3]u8 }", "@as(u64, d.a[3]) ^ (@as(u64, d.b[0]) << 8) ^ (@as(u64, d.b[2]) << 24)",
            ".{{ .a = @splat(@truncate({x})), .b = .{{ 1, @truncate({x} >> 3), 7 }} }}"),
    "H11": ("struct { a: u16, b: u16, c: u16, d: u16, e: u16, f: u8 }",
            "@as(u64, d.a) ^ (@as(u64, d.c) << 16) ^ (@as(u64, d.e) << 32) ^ (@as(u64, d.f) << 48) ^ d.b ^ d.d",
            ".{{ .a = @truncate({x}), .b = 2, .c = @truncate({x} >> 16), .d = 4, .e = 5, .f = @truncate({x} >> 40) }}"),
    "W13": ("struct { a: u32, b: u32, c: u32, d: u8 }", "@as(u64, d.a) ^ (@as(u64, d.b) << 20) ^ d.c ^ (@as(u64, d.d) << 40)",
            ".{{ .a = @truncate({x}), .b = @truncate({x} >> 32), .c = 9, .d = @truncate({x} >> 5) }}"),
}


def _ab_decl():
    out = ["const ABl = union(enum) { inside: [2]u64, outside };",
           "const ABb = struct { a: u64, b: u64, c: u64 };",
           "fn abSelect(m: u64, x: u64) bool { return m % 5 == x % 5; }",
           "var gABf: *const fn (u64) bool = &abIs;",
           "fn abIs(x: u64) bool { return x & 3 == 1; }"]
    for nm, (ty, fold, _) in AB_TYPES.items():
        out.append(f"const AB{nm}D = {ty};")
        out.append(f"const AB{nm} = struct {{")
        out.append(f"    data: AB{nm}D,")
        out.append("    const Self = @This();")
        out.append(f"    fn fold(d: AB{nm}D) u64 {{ return {fold}; }}")
        # sret union result, self first (rsi), second (rdx) and third (rcx).
        out.append("    noinline fn lookup(self: Self, x: u64) ABl {")
        out.append("        const h = fold(self.data);")
        out.append("        if (abSelect(h, x)) return .{ .inside = .{ h, x } };")
        out.append("        return .outside;")
        out.append("    }")
        out.append("    noinline fn lookup2(x: u64, self: Self) ABl { return lookup(self, x); }")
        out.append("    noinline fn big(self: Self, x: u64) ABb { const h = fold(self.data); return .{ .a = h, .b = x, .c = h ^ x }; }")
        out.append("    inline fn twice(local: ?*const Self, x: u64) u64 {")
        out.append("        var r: u64 = 0;")
        out.append("        if (local) |cm| switch (cm.lookup(x)) {")
        out.append("            .inside => |v| r +%= v[0] ^ v[1],")
        out.append("            .outside => r +%= 1,")
        out.append("        };")
        out.append("        if (local) |cm| switch (lookup2(x +% 1, cm.*)) {")
        out.append("            .inside => |v| r +%= v[0] *% 3 +% v[1],")
        out.append("            .outside => r +%= 2,")
        out.append("        };")
        out.append("        if (local) |cm| r ^= cm.big(x).c;")
        out.append("        return r +% @intFromBool(gABf(x));")
        out.append("    }")
        # The pointer in rdi, rsi and rdx; then, with the runner's own sret
        # result taking rdi, in rsi, rdx and rcx.
        out.append("    noinline fn runS(local: ?*const Self, x: u64) ?ABb { if (x == 0) return null; "
                   "return .{ .a = twice(local, x), .b = twice(local, x +% 1), .c = 2 }; }")
        out.append("    noinline fn runR(x: u64, local: ?*const Self, y: u64) ?ABb { if (x == 0) return null; "
                   "return .{ .a = twice(local, x), .b = twice(local, y), .c = 1 }; }")
        out.append("    noinline fn runQ(x: u64, y: u64, local: ?*const Self) ABb { "
                   "return .{ .a = twice(local, x), .b = twice(local, y), .c = 3 }; }")
        out.append("    noinline fn run0(local: ?*const Self, x: u64) u64 { return twice(local, x) +% twice(local, x +% 5); }")
        out.append("    noinline fn run1(x: u64, local: ?*const Self) u64 { return twice(local, x) ^ twice(local, x *% 3); }")
        out.append("    noinline fn run2(x: u64, y: u64, local: ?*const Self) u64 { return twice(local, x) -% twice(local, y); }")
        out.append("};")
    # C callconv callees taking a 16-byte int pair or {u64, u32}, returning >16 bytes.
    out.append("const ABcp = extern struct { a: i64, b: i64 };")
    out.append("const ABcw = extern struct { a: u64, b: u32 };")
    out.append("const ABcr = extern struct { a: u64, b: u64, c: u64 };")
    out.append("fn abCp(p: ABcp, x: u64) callconv(.c) ABcr { return .{ .a = @bitCast(p.a), .b = @bitCast(p.b), .c = x }; }")
    out.append("fn abCw(x: u64, p: ABcw) callconv(.c) ABcr { return .{ .a = p.a, .b = p.b, .c = x ^ p.a }; }")
    out.append("noinline fn abCrunR(x: u64, local: ?*const ABcp, w: ?*const ABcw) ?ABb {")
    out.append("    if (x == 1) return null;")
    out.append("    var r: u64 = 0;")
    out.append("    if (local) |p| r +%= abCp(p.*, x).a;")
    out.append("    if (w) |q| r ^= abCw(x, q.*).c;")
    out.append("    if (local) |p| r +%= abCp(p.*, x +% 1).b;")
    out.append("    return .{ .a = r, .b = if (w) |q| abCw(r, q.*).b else 0, .c = 4 };")
    out.append("}")
    out.append("noinline fn abCrun(x: u64, local: ?*const ABcp, w: ?*const ABcw) u64 {")
    out.append("    var r: u64 = 0;")
    out.append("    if (local) |p| r +%= abCp(p.*, x).a;")
    out.append("    if (w) |q| r ^= abCw(x, q.*).c;")
    out.append("    if (local) |p| r +%= abCp(p.*, x +% 1).b;")
    out.append("    if (w) |q| r +%= abCw(r, q.*).b;")
    out.append("    return r;")
    out.append("}")
    return out


EXTRA_DECL["argbase"] = _ab_decl()

# Copies written back field by field from a const copy (s_sharefwd).
EXTRA_DECL["sharefwd"] = [
    "var gSfA: u32 = 11;",
    "var gSfB: u32 = 22;",
    "noinline fn sfMix(a: u64, b: u64) u64 { return a *% 31 +% b; }",
    "inline fn sfIn(a: u64, b: u64) u64 { return (a ^ b) +% (a >> 3); }",
]

# Byte loops over @ptrCast slices of *T and constant-length subslices
# (s_unrollswap).
EXTRA_DECL["unrollswap"] = [
    "const UsE = extern struct { a: u8, b: u16, c: u8 };",
    "const UsP = packed struct(u24) { a: u5, b: u11, c: u8 };",
    "const UsS = struct { x: u40, y: u8 };",
    "const UsO = extern struct { a: [3]u8, b: u8, c: u8 };",
    "fn usSwap(comptime T: type, a: *T, b: *T) void {",
    "    const ab: []align(@alignOf(T)) u8 = @ptrCast(a);",
    "    const bb: []align(@alignOf(T)) u8 = @ptrCast(b);",
    "    for (ab, bb) |*x, *y| {",
    "        const t = x.*;",
    "        x.* = y.*;",
    "        y.* = t;",
    "    }",
    "}",
    "inline fn usSwapI(comptime T: type, a: *T, b: *T) void {",
    "    const ab: []u8 = @ptrCast(a);",
    "    const bb: []u8 = @ptrCast(b);",
    "    for (ab, bb) |*x, *y| {",
    "        const t = x.*;",
    "        x.* = y.*;",
    "        y.* = t;",
    "    }",
    "}",
]

# Stores through pointers, then loads of the same address (s_storefwd).
EXTRA_DECL["storefwd"] = [
    "const SfL = struct { items: []u32, cap: usize, tag: u8 };",
    "var gSfBuf: [64]u32 = @splat(0x5a5a);",
    "var gSfL: SfL = .{ .items = gSfBuf[0..8], .cap = 64, .tag = 1 };",
    "var gSfIdx: usize = 0;",
    "noinline fn sfPut(p: *usize, v: usize) void { p.* = v; }",
    "noinline fn sfPutG(v: usize) void { gSfIdx = v; gSfL.items.len = @min(v, 64); }",
    "noinline fn sfPutLen(sp: *[]u32, n: usize) void { sp.len = n; }",
    "noinline fn sfSet(l: *SfL, n: usize) void { l.items.len = n; }",
    "noinline fn sfRead(p: *const usize) usize { return p.*; }",
    "inline fn sfGrow(l: *SfL, k: usize) []u32 { const old = l.items.len; l.items.len = old + k; return l.items[old..][0..k]; }",
    "noinline fn sfGrowN(l: *SfL, k: usize) []u32 { const old = l.items.len; l.items.len = old + k; return l.items[old..][0..k]; }",
]

# Loads and copies around writes that may alias them (s_fwdalias).
EXTRA_DECL["fwdalias"] = [
    "const AQ = struct { a: u32, b: u32, c: u64 };",
    "var gAQ: AQ = .{ .a = 1, .b = 2, .c = 3 };",
    "var gAQp: *AQ = &gAQ;",
    "var gAU: u32 = 5;",
    "noinline fn aqWrite(p: *AQ, v: u32) void { p.a +%= v; p.c ^= v; }",
    "noinline fn aqWriteG(v: u32) void { gAQ.b = v; gAU +%= v; }",
    "noinline fn aqWriteSaved(v: u32) void { gAQp.a = v; gAQp.b +%= 1; }",
    "noinline fn aqSave(p: *AQ) void { gAQp = p; }",
    "noinline fn aqRead(p: *const AQ) u64 { return p.a +% p.b +% p.c; }",
    "noinline fn aqTwo(p: *AQ, q: *const AQ) u64 { const x1 = q.a; p.a = 99; const x2 = q.a; return x1 *% 1000 +% x2; }",
    "inline fn aqTwoI(p: *AQ, q: *const AQ) u64 { const x1 = q.b; p.* = .{ .a = 7, .b = 8, .c = 9 }; const x2 = q.b; return x1 *% 1000 +% x2; }",
    "noinline fn aqFld(p: *AQ, f: *const u32) u64 { const x1 = f.*; p.* = .{ .a = x1 +% 1, .b = 5, .c = 6 }; return x1 *% 1000 +% f.*; }",
    "noinline fn aqCopy(p: *AQ, q: *const AQ) u64 { const c = q.*; p.a = 50; p.b = 51; return @as(u64, c.a) *% 3 +% c.b +% q.a; }",
    "inline fn aqCopyArg(c: AQ, p: *AQ) u64 { p.a = 77; return @as(u64, c.a) *% 5 +% c.b; }",
]

# Slices returned by noinline callees whose length is (or nearly is) one
# argument (s_retlen).
EXTRA_DECL["retlen"] = [
    "var gRlBuf: [64]u32 = blk: { var a: [64]u32 = undefined; for (&a, 0..) |*p, i| p.* = @intCast(i * 7 + 1); break :blk a; };",
    "var gRlN: usize = 5;",
    "noinline fn rlAll(c: u8, n: usize) []u32 {",
    "    const s: []u32 = gRlBuf[0..];",
    "    if (c & 1 == 0) return s[0..n];",
    "    if (c & 2 == 0) return gRlBuf[0..n];",
    "    return s[0..n];",
    "}",
    "noinline fn rlM(c: u8, n: usize, m: usize) []u32 { if (c & 1 == 0) return gRlBuf[0..n]; return gRlBuf[0..m]; }",
    "noinline fn rlOff(c: u8, n: usize) []u32 { if (c & 1 == 0) return gRlBuf[0..n]; return gRlBuf[1..n]; }",
    "noinline fn rlDec(c: u8, n: usize) []u32 { if (c & 1 == 0) return gRlBuf[0..n]; return gRlBuf[0 .. n - 1]; }",
    "noinline fn rlMin(c: u8, n: usize) []u32 { if (c & 1 == 0) return gRlBuf[0..n]; return gRlBuf[0..@min(n, 3)]; }",
    "noinline fn rlOpt(c: u8, n: usize) ?[]u32 { if (c & 3 == 0) return null; return gRlBuf[0..n]; }",
    "noinline fn rlBlk(c: u8, n: usize) []u32 {",
    "    const r = blk: {",
    "        if (c & 1 == 0) break :blk gRlBuf[0..n];",
    "        break :blk gRlBuf[2..][0..n];",
    "    };",
    "    return r;",
    "}",
    "noinline fn rlIf(c: u8, n: usize) []u32 { return if (c & 1 == 0) gRlBuf[0..n] else gRlBuf[3..][0..n]; }",
    "noinline fn rlErr(c: u8, n: usize) E![]u32 { if (c & 3 == 1) return error.Beta; return gRlBuf[0..n]; }",
    "noinline fn rlErrM(c: u8, n: usize) E![]u32 { if (c & 3 == 1) return error.Beta; if (c & 4 == 0) return gRlBuf[0..n]; return gRlBuf[0 .. n / 2]; }",
    "noinline fn rlCt(comptime k: u8, x: u64, n: usize) []u32 { if (x == 7) return gRlBuf[0..n]; return gRlBuf[k..][0..n]; }",
    "noinline fn rlLater(a: usize, b: usize, n: usize) []u32 { if (a == b) return gRlBuf[1..][0..n]; return gRlBuf[0..n]; }",
    "noinline fn rlGlob(c: u8) []u32 { gRlN = (gRlN +% (c & 1)) % 60; return gRlBuf[0..gRlN]; }",
    "noinline fn rlRec(n: usize, d: u8) []u32 { if (d == 0) return gRlBuf[0..n]; return rlRec(n, d - 1); }",
    "noinline fn rlMa(n: usize, d: u8) []u32 { if (d == 0) return gRlBuf[0..n]; return rlMb(n, d - 1); }",
    "noinline fn rlMb(n: usize, d: u8) []u32 { if (d == 0) return gRlBuf[1..][0..n]; return rlMa(n, d - 1); }",
    "noinline fn rlRecM(n: usize, d: u8) []u32 { if (d == 0) return gRlBuf[0..n]; const r = rlRecM(n, d - 1); return r[0 .. r.len - @intFromBool(d == 3)]; }",
    "noinline fn rlPtr(c: u8, np: *const usize) []u32 { if (c == 9) return gRlBuf[1..np.*]; return gRlBuf[0..np.*]; }",
]

SE_DECL = [
    "const SE = struct {",
    "    a: u64,",
    "    b: u32,",
    "    c: u8,",
    "    d: i16,",
    "    e: [3]u16,",
    "    inline fn mix(self: *SE, x: u64) void {",
    "        self.a = (self.a ^ x) *% 0x100000001b3;",
    "        self.b +%= @truncate(self.a >> 7);",
    "        self.c ^= @truncate(x);",
    "    }",
    "    inline fn rounds(self: *SE, n: usize) void {",
    "        var i: usize = 0;",
    "        while (i < n) : (i += 1) {",
    "            self.a = std.math.rotl(u64, self.a, 13) +% self.b;",
    "            self.b ^= @truncate(self.a);",
    "            self.d -%= 3;",
    "            self.e[i % 3] +%= @truncate(self.a);",
    "        }",
    "    }",
    "    fn step2(self: *SE, x: u32) void {",
    "        self.mix(x);",
    "        self.d = @bitCast(@as(u16, @truncate(self.a)) ^ self.e[1]);",
    "    }",
    "    noinline fn absorb(self: *SE, x: u32) void {",
    "        self.b = self.b *% 31 +% x;",
    "        self.e[2] -%= @truncate(x);",
    "    }",
    "    inline fn fold(self: *const SE) u64 {",
    "        return self.a ^ (@as(u64, self.b) << 3) ^ (@as(u64, self.c) << 40) ^ @as(u64, @as(u16, @bitCast(self.d))) ^",
    "            (@as(u64, self.e[0]) << 16) ^ (@as(u64, self.e[1]) << 32) ^ (@as(u64, self.e[2]) << 48);",
    "    }",
    "};",
    "var gSEp: *SE = undefined;",
    "noinline fn seBump(x: u32) void {",
    "    gSEp.b +%= x;",
    "    gSEp.e[0] ^= 0x5a5a;",
    "}",
    "noinline fn seRead(p: *const SE) u64 {",
    "    return p.a +% p.b +% p.c;",
    "}",
]


class Gen:
    def __init__(self, seed, size=1.0):
        self.r = random.Random(seed)
        self.seed = seed
        self.size = size
        self.n = 0
        self.out = []
        self.use_pk = False
        self.extra = set()  # keys of EXTRA_DECL the program uses
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
        # An .auto struct over 16 bytes (passed by reference) for s_byref.
        big = self.make_struct(len(self.structs))
        big.layout = "auto"
        big.fields = [(f, t) for f, t in big.fields if not isinstance(t, Struct) or t.layout != "packed"]
        big.fields.append((f"f{len(big.fields) + 9}", Array(self.pick([U64, Int(True, 64), U32]), self.r.randint(3, 5))))
        self.big = big
        self.structs.append(big)
        # A struct of 64 to 256 bytes for whole copies (s_bigcopy); kept out
        # of self.structs so ordinary statements do not spell it out.
        n = self.r.randint(5, 28)
        hf = [("f0", U64), ("f1", Array(self.pick([U64, Int(True, 64)]), n)), ("f2", U32)]
        if self.chance(0.5):
            hf.append(("f3", Array(Int(False, 16), self.r.randint(1, 4))))
        hf.append(("f4", Int(True, 64)))
        self.huge = Struct("SH", hf, "auto")

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
            (1, "statesw"), (2, "bce"), (2, "copy"), (2, "alias"), (2, "repeat"), (2, "vector"), (3, "prove"),
            (2, "sroa"), (2, "addr"), (1, "parent"), (2, "live"), (2, "byref"), (2, "window"),
            (2, "wide"), (2, "rot"), (2, "not"), (2, "bigcopy"), (2, "range"), (2, "optreg"),
            (2, "sroaesc"), (2, "retbig"), (2, "erragg"), (2, "packstore"),
            (2, "rvoglob"), (2, "boolret"), (1, "asmpin"), (2, "xcall"), (2, "prove3"),
            (2, "swx"), (2, "scopenum"), (2, "argbase"), (2, "mulbound"), (2, "retlen"),
            (2, "sharefwd"), (2, "fwdalias"), (2, "storefwd"), (2, "unrollswap"),
        ]
        if d >= 3 or ctx["stmts"] > ctx["stmt_cap"]:
            w = [(10, "decl"), (9, "assign"), (6, "sink")]
        if DISABLED:
            w = [x for x in w if x[1] not in DISABLED]
        if BOOST:
            w = [(n * BOOST.get(k, 1), k) for n, k in w]
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

    def s_vector(self, ctx):
        """Explicit @Vector code, lowered to SIMD registers by both
        compilers: element-wise operations on lanes of any width,
        compares, @select, @shuffle, casts, then reductions, mask
        searches and element reads folded into the checksum."""
        odd = [Int(False, 4), Int(True, 24), Int(False, 33), Int(False, 1), Int(True, 7), Int(False, 12),
               Int(True, 48), Int(False, 63), Int(True, 3)]
        et = self.pick([Int(False, 8), Int(False, 16), U32, U64, Int(True, 8), Int(True, 16), Int(True, 32),
                        Int(True, 64)] + odd + [t for t in self.ints if t.bits <= 64 and self.chance(0.2)])
        n = self.pick([2, 4, 8, 16, 3, 5, 4, 8, 32 if et.bits <= 16 else 6])
        en = et.name()
        vt = f"@Vector({n}, {en})"
        arrs = [p for p in self.paths(ctx, lambda x: isinstance(x, Array) and x.n == n and x.elem.name() == en)]
        texts = []

        def operand():
            k = self.r.random()
            if arrs and k < 0.25:
                e = self.render_path(ctx, self.pick(arrs)[0])
            elif k < 0.45:
                e = f"@as({vt}, @splat({self.int_expr(ctx, et, 2)}))"
            elif k < 0.52 and not et.signed and et.max() >= n - 1:
                e = f"std.simd.iota({en}, {n})"
            else:
                e = f"{vt}{{ {', '.join(self.int_expr(ctx, et, 1) for _ in range(n))} }}"
            texts.append(e)
            return e

        a, b = self.fresh("va"), self.fresh("vb")
        self.emit(ctx, f"const {a}: {vt} = {operand()};")
        if self.chance(0.3):
            # Lanes written one at a time.
            self.emit(ctx, f"var {b}: {vt} = {operand()};")
            for _ in range(self.r.randint(1, 3)):
                self.emit(ctx, f"{b}[{self.r.randrange(n)}] = {self.int_expr(ctx, et, 1)};")
        else:
            self.emit(ctx, f"const {b}: {vt} = {operand()};")
        rt = any(self.is_rt(t) for t in texts)
        cur = [a, b]
        for step in range(self.r.randint(1, 3)):
            # Each result feeds the next; the first step reads both operands.
            x, y = (a, b) if step == 0 else (cur[-1], self.pick(cur))
            if self.chance(0.5):
                x, y = y, x
            r = self.fresh("vr")
            k = self.r.random()
            if k < 0.3:
                e = f"{x} {self.pick(['+%', '-%', '*%', '&', '|', '^', '+|', '-|', '*|'])} {y}"
            elif k < 0.38:
                e = f"@{self.pick(['min', 'max'])}({x}, {y})"
            elif k < 0.5:
                e = f"@select({en}, {x} {self.pick(['<', '<=', '==', '!=', '>', '>='])} {y}, {x}, {y})"
            elif k < 0.6:
                mask = [self.r.randrange(n) if self.chance(0.5) else -1 - self.r.randrange(n) for _ in range(n)]
                e = f"@shuffle({en}, {x}, {y}, @Vector({n}, i32){{ {', '.join(map(str, mask))} }})"
            elif k < 0.68 and et.bits > 1:
                amts = [str(self.r.randrange(et.bits)) for _ in range(n)]
                e = f"({x} {self.pick(['<<', '>>'])} @Vector({n}, std.math.Log2Int({en})){{ {', '.join(amts)} }}) ^ {y}"
            elif k < 0.73:
                e = f"~{x} ^ {y}"
            elif k < 0.78:
                e = f"-%{x} +% {y}"
            elif k < 0.83 and not et.signed:
                e = f"@divTrunc({x}, {y} | @as({vt}, @splat(1))) +% @rem({x}, {y} | @as({vt}, @splat(1)))"
            elif k < 0.88:
                e = self.pick([f"std.simd.reverseOrder({x})", f"std.simd.rotateElementsLeft({x}, {self.r.randrange(n)})",
                               f"std.simd.shiftElementsRight({x}, {self.r.randrange(n)}, {self.int_expr(ctx, et, 1)})"]) + f" ^ {y}"
            elif k < 0.94 and rt:
                # Checked lanes: the check fires for the lane that overflows.
                ctx["fn"].risky = True
                e = f"{x} {self.pick(['+', '-', '*'])} {y}"
            else:
                # Through a wider lane type and back.
                w = Int(et.signed, min(64, et.bits * 2 + 1))
                e = f"@as({vt}, @truncate(@as(@Vector({n}, {w.name()}), {x}) +% @as(@Vector({n}, {w.name()}), {y})))"
            self.emit(ctx, f"const {r}: {vt} = {e};")
            cur.append(r)
        r = cur[-1]
        red = self.pick([".Xor", ".And", ".Or", ".Min", ".Max", ".Add", ".Mul"])
        self.sink(ctx, f"@reduce({red}, {r})", et)
        if self.chance(0.5):
            self.sink(ctx, f"{r}[{self.r.randrange(n)}]", et)
        if self.chance(0.3):
            arr = self.fresh("vx")
            self.emit(ctx, f"const {arr}: [{n}]{en} = {r};")
            self.sink(ctx, f"{arr}[{self.index(ctx, n, allow_oob=False)}]", et)
        if self.chance(0.5):
            m = self.fresh("vm")
            self.emit(ctx, f"const {m} = {self.pick(cur)} {self.pick(['<', '<=', '==', '!=', '>', '>='])} {self.pick(cur)};")
            k = self.r.random()
            if k < 0.25:
                self.sink(ctx, f"@as(u{n}, @bitCast({m}))", Int(False, n))
            elif k < 0.45:
                self.sink(ctx, f"@as(u8, @intFromBool(@reduce({self.pick(['.Or', '.And'])}, {m})))", Int(False, 8))
            elif k < 0.75:
                f_ = self.pick(["firstTrue", "lastTrue"])
                self.sink(ctx, f"(if (std.simd.{f_}({m})) |ix| @as(u64, ix) + 1 else 0)", U64)
            else:
                self.sink(ctx, f"@as(u64, std.simd.countTrues({m}))", U64)
        if self.chance(0.25):
            f_ = self.pick(["popCount", "clz", "ctz"])
            self.sink(ctx, f"@reduce(.Add, @as(@Vector({n}, u16), @{f_}({r})))", Int(False, 16))
        if self.chance(0.15) and et.signed:
            self.sink(ctx, f"@reduce(.Max, @abs({r}))", Int(False, et.bits))

    def rt_int(self, ctx, t):
        """A runtime-known integer expression of type `t` (from a path),
        or None."""
        cands = [p for p in self.paths(ctx, lambda x: is_int(x)) if self.is_rt(p[2].name)]
        if not cands:
            return None
        steps, ft, _ = self.pick(cands)
        return self.conv(self.render_path(ctx, steps), ft, t)

    def s_prove(self, ctx):
        """A check next to the comparisons that decide it, or nearly do
        (what a prover of safety checks reasons about). The near misses
        must keep their check: they fire for some values."""
        k = self.r.randrange(23)
        t = self.pick([Int(False, 8), Int(True, 8), Int(False, 16), Int(True, 16), U32, Int(True, 32), U64,
                       USIZE, Int(False, 5), Int(True, 7)])
        x = self.rt_int(ctx, t)
        if x is None:
            return self.s_sink(ctx)
        v = self.fresh("pv")
        if self.chance(0.5):
            self.emit(ctx, f"const {v}: {t.name()} = {x};")
        else:
            # A variable the prover tracks through its stores.
            self.emit(ctx, f"var {v}: {t.name()} = {x};")
            self.emit(ctx, f"{v} +%= {self.r.randint(0, 1) if t.max() >= 1 else 0};")
        self.rt_names.add(v)
        ctx["fn"].risky = True
        n = t.name()
        near = self.chance(0.35)
        I = lambda: self.emit(ctx, "}")

        def body(e, et=None):
            ctx["indent"] += 1
            self.sink(ctx, e, et or t)
            ctx["indent"] -= 1

        if k == 0:
            # A bound on the widened value, the operation on the narrow one.
            w = Int(t.signed, min(t.bits * 2, 64)) if t.bits < 64 else t
            c = t.max() + (1 if near else 0)
            self.emit(ctx, f"if (@as({w.name()}, {v}) < {self.bare(c)}) {{")
            body(f"{v} + 1")
            I()
        elif k == 1:
            # A bound, then a store, then the use.
            arr = self.fresh("pa")
            ln = self.r.randint(1, 8)
            self.emit(ctx, f"var {arr}: [{ln}]{n} = @splat({v});")
            self.emit(ctx, f"_ = &{arr};")
            self.emit(ctx, f"var {v}i: usize = {self.conv(v, t, USIZE)} % {ln};")
            self.emit(ctx, f"if ({v}i < {ln}) {{")
            ctx["indent"] += 1
            if near:
                self.emit(ctx, f"{v}i = {self.conv(self.rt_int(ctx, Int(False, 8)) or '0', Int(False, 8), USIZE)} % {ln + 2};")
            else:
                self.emit(ctx, f"{v}i = {self.conv(self.rt_int(ctx, Int(False, 8)) or '0', Int(False, 8), USIZE)} % {ln};")
            self.sink(ctx, f"{arr}[{v}i]", t)
            ctx["indent"] -= 1
            I()
        elif k == 2 and t.signed:
            # Signed bounds: i < c does not keep i + d in range when c + d overflows.
            c = self.r.randint(1, t.max())
            d = t.max() - c + 1 + (1 if near else 0)  # v <= c - 1
            self.emit(ctx, f"if ({v} < {self.bare(c)}) {{")
            body(f"{v} + {self.bare(min(d, t.max()))}")
            I()
        elif k == 3:
            # i > lo, then i - 1 (or i - 2 for a near miss).
            lo = 0 if not t.signed else self.r.randint(t.min(), 0)
            self.emit(ctx, f"if ({v} > {self.bare(lo)}) {{")
            body(f"{v} - {2 if near else 1}")
            I()
        elif k == 4:
            # A loop that moves its index inside the body.
            arr = self.fresh("pa")
            ln = self.r.randint(1, 8)
            self.emit(ctx, f"const {arr}: [{ln}]{n} = @splat({v});")
            j = self.fresh("pj")
            self.emit(ctx, f"var {j}: usize = 0;")
            self.emit(ctx, f"while ({j} < {arr}.len) : ({j} += 1) {{")
            ctx["indent"] += 1
            self.sink(ctx, f"{arr}[{j}]", t)
            self.emit(ctx, f"if (({self.conv(v, t, USIZE)} & {self.r.choice([1, 2, 3])}) == 0) {j} += 1;" if not near
                      else f"{j} += 1;")
            self.sink(ctx, f"{arr}[{j}]" if near else f"{arr}[@min({j}, {ln - 1})]", t)
            ctx["indent"] -= 1
            I()
        elif k == 5:
            # A fact on one path only.
            arr = self.fresh("pa")
            ln = self.r.randint(1, 8)
            self.emit(ctx, f"const {arr}: [{ln}]{n} = @splat({v});")
            j = self.fresh("pj")
            self.emit(ctx, f"var {j}: usize = {self.conv(v, t, USIZE)};")
            self.emit(ctx, f"if ({self.bool_expr(ctx, 1)}) {{")
            ctx["indent"] += 1
            self.emit(ctx, f"if ({j} >= {ln}) {j} = 0;")
            ctx["indent"] -= 1
            self.emit(ctx, "} else {")
            ctx["indent"] += 1
            self.emit(ctx, f"{j} = {j} % {ln + (1 if near else 0)};")
            ctx["indent"] -= 1
            I()
            self.sink(ctx, f"{arr}[{j}]", t)
        elif k == 6 and not t.signed:
            # i < n, then a[i -% 1] (wraps to huge at 0).
            arr = self.fresh("pa")
            ln = self.r.randint(1, 8)
            self.emit(ctx, f"const {arr}: [{ln}]{n} = @splat({v});")
            j = self.fresh("pj")
            self.emit(ctx, f"const {j}: usize = {self.conv(v, t, USIZE)};")
            self.emit(ctx, f"if ({j} < {ln}) {{" if near else f"if ({j} < {ln} and {j} >= 1) {{")
            body(f"{arr}[{j} -% 1]")
            I()
        elif k == 7:
            # i + 1 < n proves a[i + 1], not a[i + 2].
            arr = self.fresh("pa")
            ln = self.r.randint(2, 8)
            self.emit(ctx, f"const {arr}: [{ln}]{n} = @splat({v});")
            j = self.fresh("pj")
            self.emit(ctx, f"const {j}: usize = {self.conv(v, t, USIZE)} % {ln + 2};")
            self.emit(ctx, f"if ({j} + 1 < {arr}.len) {{")
            body(f"{arr}[{j} + {2 if near else 1}]")
            I()
        elif k == 8:
            # A bound that keeps i * m in range, or just misses.
            m = self.r.randint(2, min(70, t.max()))
            c = t.max() // m + (2 if near else 1)  # v <= max / m keeps v * m in range
            if c > t.max():
                return self.s_sink(ctx)
            self.emit(ctx, f"if ({v} < {self.bare(c)}{f' and {v} >= {self.bare(-(t.max() // m))}' if t.signed else ''}) {{")
            body(f"{v} * {m}")
            I()
        elif k == 9:
            # A bound for one array used on a shorter one.
            a1, a2 = self.fresh("pa"), self.fresh("pa")
            l1 = self.r.randint(2, 8)
            l2 = l1 - (1 if near else 0)
            self.emit(ctx, f"const {a1}: [{l1}]{n} = @splat({v});")
            self.emit(ctx, f"const {a2}: [{l2}]{n} = @splat({v} ^ 1);")
            j = self.fresh("pj")
            self.emit(ctx, f"const {j}: usize = {self.conv(v, t, USIZE)} % {l1 + 1};")
            self.emit(ctx, f"if ({j} < {a1}.len) {{")
            body(f"{a1}[{j}] ^ {a2}[{j}]")
            I()
        elif k == 11:
            # A wrapping add in the comparison: i +% c <= n says nothing
            # about i when the add wraps.
            arr = self.fresh("pa")
            ln = self.r.randint(1, 8)
            self.emit(ctx, f"const {arr}: [{ln}]{n} = @splat({v});")
            j = self.fresh("pj")
            src = f"{self.conv(v, t, USIZE)}" if not near else f"({self.conv(v, t, USIZE)} | 0xfffffffffffffff0)"
            self.emit(ctx, f"const {j}: usize = {src};")
            c = self.r.randint(1, 3)
            self.emit(ctx, f"if ({j} +% {c} <= {arr}.len) {{")
            body(f"{arr}[{j}]")
            I()
        elif k == 12:
            # A store between the check and the use, in a variable.
            arr = self.fresh("pa")
            ln = self.r.randint(1, 8)
            self.emit(ctx, f"const {arr}: [{ln}]{n} = @splat({v});")
            j = self.fresh("pj")
            self.emit(ctx, f"var {j}: usize = {self.conv(v, t, USIZE)};")
            self.emit(ctx, f"if ({j} < {arr}.len) {{")
            ctx["indent"] += 1
            self.emit(ctx, f"{j} +%= 1;" if near else f"{j} = ({j} +% 1) % {ln};")
            self.sink(ctx, f"{arr}[{j}]", t)
            ctx["indent"] -= 1
            I()
        elif k == 13:
            # A check carried around a back edge.
            arr = self.fresh("pa")
            ln = self.r.randint(1, 8)
            self.emit(ctx, f"const {arr}: [{ln}]{n} = @splat({v});")
            j = self.fresh("pj")
            step = self.r.randint(1, 3)
            self.emit(ctx, f"var {j}: usize = {self.conv(v, t, USIZE)} % {ln + 1};")
            self.emit(ctx, "while (true) {")
            ctx["indent"] += 1
            self.emit(ctx, f"if ({j} {'>' if near else '>='} {ln}) break;")
            self.sink(ctx, f"{arr}[{j}]", t)
            self.emit(ctx, f"{j} += {step};")
            ctx["indent"] -= 1
            I()
        elif k == 14:
            # A bound on a value of another width or sign than the index.
            arr = self.fresh("pa")
            ln = self.r.randint(1, 8)
            self.emit(ctx, f"const {arr}: [{ln}]{n} = @splat({v});")
            if t.signed:
                # s < len does not make s a valid index while s may be negative.
                self.emit(ctx, f"if ({v} < {ln}{'' if near else f' and {v} >= 0'}) {{")
                body(f"{arr}[@intCast({v})]")
            else:
                # A truncated copy below the bound says nothing about the value.
                tr = Int(False, max(1, min(t.bits, 8) - 1)) if t.bits > 1 else t
                if near:
                    self.emit(ctx, f"if (@as({tr.name()}, @truncate({v})) < {ln}) {{")
                else:
                    self.emit(ctx, f"if ({v} < {ln}) {{")
                body(f"{arr}[{self.conv(v, t, USIZE)}]")
            I()
        elif k == 15:
            # Stored, then compared through a cast (the load's value is the
            # stored one, not the one before the store).
            arr = self.fresh("pa")
            ln = self.r.randint(1, 8)
            w = self.fresh("pw")
            self.emit(ctx, f"var {w}: {n} = {v};")
            self.emit(ctx, f"{w} +%= {self.r.randint(1, 2) if t.max() >= 2 else 0};")
            self.emit(ctx, f"const {arr}: [{ln}]{n} = @splat({w});")
            j = self.fresh("pj")
            self.emit(ctx, f"const {j}: usize = {self.conv(w, t, USIZE)};")
            self.emit(ctx, f"if ({j} {'<=' if near else '<'} {arr}.len) {{")
            body(f"{arr}[{j}]")
            I()
        elif k >= 16:
            self.prove_more(ctx, k, t, v, near, body, I)
        else:
            # i <= n proves nothing about a[i] when a.len == n.
            arr = self.fresh("pa")
            ln = self.r.randint(1, 8)
            self.emit(ctx, f"const {arr}: [{ln}]{n} = @splat({v});")
            j = self.fresh("pj")
            self.emit(ctx, f"const {j}: usize = {self.conv(v, t, USIZE)};")
            self.emit(ctx, f"if ({j} {'<=' if near else '<'} {arr}.len) {{")
            body(f"{arr}[{j}]")
            I()

    # ------------------------------------------------------------ backend shapes
    def leaves(self, e, t, depth=0):
        """The integer places inside a value of type t at e."""
        if is_int(t):
            return [(e, t)]
        out = []
        if isinstance(t, Struct) and depth < 3:
            for fn, ft in t.fields:
                out += self.leaves(f"{e}.{fn}", ft, depth + 1)
        elif isinstance(t, Array) and depth < 3:
            for i in range(t.n):
                out += self.leaves(f"{e}[{i}]", t.elem, depth + 1)
        return out

    def init_fields(self, ctx, e, t):
        """Assigns every scalar of e, one store each."""
        if is_int(t):
            self.emit(ctx, f"{e} = {self.int_expr(ctx, t, 1)};")
        elif isinstance(t, Bool):
            self.emit(ctx, f"{e} = {self.bool_expr(ctx, 1)};")
        elif isinstance(t, Enum):
            self.emit(ctx, f"{e} = .{self.pick(t.tags)[0]};")
        elif isinstance(t, Struct):
            for fn, ft in t.fields:
                self.init_fields(ctx, f"{e}.{fn}", ft)
        elif isinstance(t, Array):
            if t.n > 3 and is_int(t.elem) and self.chance(0.5):
                self.emit(ctx, f"{e} = @splat({self.int_expr(ctx, t.elem, 1)});")
            else:
                for i in range(t.n):
                    self.init_fields(ctx, f"{e}[{i}]", t.elem)

    def leaf_ops(self, ctx, lv, n):
        """Field-by-field reads, writes and copies between scalars."""
        for _ in range(n):
            e, t = self.pick(lv)
            k = self.r.random()
            if k < 0.4:
                self.emit(ctx, f"{e} {self.pick(['=', '+%=', '^=', '*%=', '-%=', '|='])} {self.int_expr(ctx, t, 1)};")
            elif k < 0.7:
                e2, t2 = self.pick(lv)
                self.emit(ctx, f"{e} = {self.conv(e2, t2, t)};")
            else:
                self.sink(ctx, e, t)

    def s_sroa(self, ctx):
        """An aggregate local written and read field by field (what scalar
        replacement turns into registers)."""
        if self.structs and self.chance(0.65):
            t = self.pick(self.structs)
        else:
            t = Array(self.rand_int_type(), self.r.randint(2, 6))
        lv = self.leaves("X", t)
        if not lv:
            return self.s_aggr(ctx)
        name = self.fresh("sr")
        if self.chance(0.5):
            self.emit(ctx, f"var {name}: {t.name()} = undefined;")
            self.init_fields(ctx, name, t)
        else:
            self.emit(ctx, f"var {name}: {t.name()} = {self.value_expr(ctx, t, 1)};")
        lv = [(name + e[1:], ft) for e, ft in lv]
        self.emit(ctx, f"_ = &{name};")
        self.leaf_ops(ctx, lv, self.r.randint(2, 6))
        if self.chance(0.4):
            # A whole copy, then the original changes: the copy keeps its values.
            cp = self.fresh("sc")
            self.emit(ctx, f"const {cp} = {name};")
            self.leaf_ops(ctx, lv, self.r.randint(1, 3))
            self.sink_value(ctx, cp, t)
        if self.chance(0.3):
            # Through a loop: the scalars are live around the back edge.
            i = self.fresh("ix")
            self.emit(ctx, f"for (0..{self.r.randint(1, 4)}) |{i}| {{")
            ctx["indent"] += 1
            e, ft = self.pick(lv)
            self.emit(ctx, f"{e} +%= {self.conv(i, USIZE, ft)};")
            self.leaf_ops(ctx, lv, self.r.randint(1, 2))
            ctx["indent"] -= 1
            self.emit(ctx, "}")
        self.sink_value(ctx, name, t)

    def s_addr(self, ctx):
        """Loads and stores at a pointer plus a constant offset, below the
        pointer too (address modes)."""
        et = self.rand_int_type()
        n = self.r.randint(3, 8)
        arr = self.fresh("ad")
        if self.chance(0.5):
            self.emit(ctx, f"var {arr}: [{n}]{et.name()} = .{{ {', '.join(self.lit(et) for _ in range(n))} }};")
        else:
            self.emit(ctx, f"var {arr}: [{n}]{et.name()} = @splat({self.int_expr(ctx, et, 1)});")
        k = self.r.randint(1, n - 1)
        mp, q = self.fresh("mp"), self.fresh("q")
        self.emit(ctx, f"const {mp}: [*]{et.name()} = &{arr};")
        self.emit(ctx, f"const {q} = {mp} + {k};")
        self.emit(ctx, f"{q}[0] +%= {self.int_expr(ctx, et, 1)};")
        for _ in range(self.r.randint(2, 6)):
            # Element offset from q in [-k, n-1-k].
            off = self.r.randint(-k, n - 1 - k)
            if off >= 0:
                at = f"{q}[{off}]" if self.chance(0.6) else f"({q} + {off})[0]"
            else:
                at = f"({q} - {-off})[0]" if self.chance(0.6) else f"({mp} + {k + off})[0]"
            w = self.r.random()
            if w < 0.45:
                self.emit(ctx, f"{at} {self.pick(['=', '+%=', '^=', '-%='])} {self.int_expr(ctx, et, 1)};")
            elif w < 0.7:
                self.sink(ctx, at, et)
            elif w < 0.85:
                # A runtime index from the offset base.
                rt = self.rt_int(ctx, Int(False, 8))
                if rt is None:
                    continue
                self.sink(ctx, f"({q} - {k})[{self.conv(rt, Int(False, 8), USIZE)} % {n}]", et)
            else:
                lo = self.r.randint(0, n - 1)
                hi = self.r.randint(lo, n)
                sl = self.fresh("sl")
                self.emit(ctx, f"const {sl} = ({q} - {k})[{lo}..{hi}];")
                self.emit(ctx, f"for ({sl}) |x| mix({self.to_u64('x', et)});" if not ctx["fn"].pure
                          else f"_ = {sl}.len;")
        self.emit(ctx, f"_ = &{arr};")
        self.sink_value(ctx, arr, Array(et, n))

    def s_parent(self, ctx):
        """Writes through @fieldParentPtr of a field pointer."""
        cands = [s for s in self.structs if s.layout != "packed" and len(s.fields) >= 2]
        if not cands:
            return self.s_addr(ctx)
        t = self.pick(cands)
        lv = self.leaves("X", t)
        if not lv:
            return self.s_sroa(ctx)
        fn, ft = self.pick(t.fields)
        if self.chance(0.4):
            # An element of an array of structs.
            n = self.r.randint(2, 4)
            arr = self.fresh("pa")
            self.emit(ctx, f"var {arr}: [{n}]{t.name()} = .{{ {', '.join(self.global_init(t) for _ in range(n))} }};")
            base = f"{arr}[{self.r.randrange(n)}]"
            whole, wt = arr, Array(t, n)
        else:
            s = self.fresh("ps")
            self.emit(ctx, f"var {s}: {t.name()} = {self.value_expr(ctx, t, 1)};")
            base, whole, wt = s, s, t
        fp, par = self.fresh("fp"), self.fresh("pp")
        self.emit(ctx, f"const {fp} = &{base}.{fn};")
        # The field pointer only promises the field's alignment.
        al = "1" if self.chance(0.3) else f"@alignOf({ft.name()})"
        self.emit(ctx, f"const {par}: *align({al}) {t.name()} = @fieldParentPtr(\"{fn}\", {fp});")
        plv = [(par + e[1:], lt) for e, lt in lv] + [(base + e[1:], lt) for e, lt in lv]
        if is_int(ft):
            plv.append((f"{fp}.*", ft))
        e, lt = self.pick(lv)
        self.emit(ctx, f"{par}{e[1:]} {self.pick(['+%=', '^=', '='])} {self.int_expr(ctx, lt, 1)};")
        self.leaf_ops(ctx, plv, self.r.randint(2, 5))
        self.emit(ctx, f"_ = &{whole};")
        self.sink_value(ctx, whole, wt)

    def s_live(self, ctx):
        """Many values live across calls (callee-saved registers, spills,
        coalescing)."""
        n = self.r.randint(5, 14)
        names = []
        for _ in range(n):
            t = self.rand_int_type()
            v = self.fresh("lv")
            self.emit(ctx, f"const {v}: {t.name()} = {self.int_expr(ctx, t, 1)};")
            names.append((v, t))
        for _ in range(self.r.randint(1, 3)):
            if not ctx["fn"].pure and self.chance(0.3):
                v, t = self.pick(names)
                self.emit(ctx, f"mix({self.to_u64(v, t)});")
            else:
                self.s_callstmt(ctx)
            if self.chance(0.4):
                # Some die here, the rest stay live across the next call.
                v, t = names.pop(self.r.randrange(len(names)))
                self.sink(ctx, v, t)
                if not names:
                    return
        if self.chance(0.5):
            self.sink(ctx, " ^ ".join(self.to_u64(v, t) for v, t in names), U64)
        else:
            for v, t in names:
                self.sink(ctx, v, t)

    def s_byref(self, ctx):
        """A by-value aggregate argument that aliases a global the callee
        writes, the result location, or a pointer argument."""
        if ctx["fn"].pure or not self.byref:
            return self.s_live(ctx)
        kind, name, t, g = self.pick(self.byref)
        if kind == "bv":
            # The argument is the global the callee writes, or a constant.
            arg = g if self.chance(0.75) else ("KB" if t is self.big and self.chance(0.5) else self.global_init(t))
            self.sink(ctx, f"{name}({arg})", U64)
            return
        if kind == "fw":
            self.sink(ctx, f"{name}({g}, {self.r.randint(0, 3)})", U64)
            return
        if kind == "perm":
            ag = ["gB", "KB"]
            self.sink(ctx, f"permB({self.int_expr(ctx, U64, 1)}, {self.pick(ag)}, {self.int_expr(ctx, U32, 1)}, "
                           f"{self.pick(ag)}, {self.int_expr(ctx, Int(True, 16), 1)})", U64)
            return
        if kind == "many":
            big = self.big.name()
            locs = [p for p in self.paths(ctx, lambda x: x.name() == big, depth=1)]
            aggs = ["gB", "KB", f"@as({big}, {self.global_init(self.big)})"] + \
                   [self.render_path(ctx, p[0]) for p in locs]
            ints = [self.int_expr(ctx, pt, 1) for pt in name[1]]
            a = [self.pick(["gB", self.pick(aggs)]) for _ in range(3)]
            args = [ints[0], ints[1], a[0], ints[2], ints[3], ints[4], a[1], ints[5], ints[6], ints[7], a[2]]
            self.sink(ctx, f"{name[0]}({', '.join(args)})", U64)
            return
        locs = [p for p in self.paths(ctx, lambda x: x.name() == t.name(), writable=True, depth=1)
                if not self.in_packed(p[0])]
        if locs and self.chance(0.7):
            steps, _, _ = self.pick(locs)
            lv = self.render_path(ctx, steps, writing=True)
        else:
            lv = self.fresh("br")
            self.emit(ctx, f"var {lv}: {t.name()} = {self.value_expr(ctx, t, 1)};")
            self.emit(ctx, f"_ = &{lv};")
        if kind == "ru":
            # The result location is the argument.
            self.emit(ctx, f"{lv} = {name}({lv});")
        else:
            self.sink(ctx, f"{name}(&{lv}, {lv})", U64)
        self.sink_value(ctx, lv, t)

    def byref_helpers(self):
        """Top-level helpers for s_byref; self.byref lists them."""
        out = self.out
        self.byref = []

        def digest(e, t):
            return " ^ ".join(f"({self.to_u64(x, xt)} *% {2 * j + 1})" for j, (x, xt) in enumerate(self.leaves(e, t))) or "0"

        for g in self.globals:
            t = g.ty
            if g.kind != "global" or not isinstance(t, (Struct, Array)) or not self.leaves("s", t):
                continue
            e, et = self.pick(self.leaves(g.name, t))
            name = f"bv_{g.name}"
            out.append(f"fn {name}(s: {t.name()}) u64 {{")
            out.append(f"    const d0 = {digest('s', t)};")
            out.append(f"    {e} {self.pick(['+%=', '^='])} {self.lit(et)};")
            out.append(f"    mix(d0);")
            out.append(f"    return {digest('s', t)};")
            out.append("}")
            self.byref.append(("bv", name, t, g.name))
        big, bt = self.big, self.big.name()
        if any(k == "bv" and g_ == "gB" for k, _, _, g_ in self.byref):
            # Forwarded: the by-reference argument passes on down a chain,
            # and the last callee writes where it came from.
            out.append(f"fn fwB(s: {bt}, n: u8) u64 {{")
            out.append(f"    if (n == 0) return bv_gB(s);")
            out.append(f"    return fwB(s, n - 1) *% 3 +% ({digest('s', big)});")
            out.append("}")
            self.byref.append(("fw", "fwB", big, "gB"))
        # More arguments than there are argument registers.
        its = [U64, U32, Int(True, 16), Int(False, 8), U64, Int(False, 16), Int(True, 32), U64]
        e, et = self.pick(self.leaves("gB", big))
        p_ = [f"mb{j}: {t.name()}" for j, t in enumerate(its)]
        ps = ", ".join(p_[:2] + [f"mbs1: {bt}"] + p_[2:5] + [f"mbs2: {bt}"] + p_[5:] + [f"mbs3: {bt}"])
        out.append(f"fn manyB({ps}) u64 {{")
        out.append(f"    const d = ({digest('mbs1', big)}) ^ (({digest('mbs2', big)}) *% 3) ^ (({digest('mbs3', big)}) *% 5);")
        out.append(f"    {e} +%= {self.lit(et)};")
        out.append(f"    mix(d);")
        sums = " +% ".join(self.to_u64(f"mb{j}", t) for j, t in enumerate(its))
        out.append(f"    return (d *% 7) ^ ({digest('mbs1', big)}) ^ ({digest('mbs3', big)}) ^ ({sums});")
        out.append("}")
        self.byref.append(("many", ("manyB", its), big, None))
        tys = list(self.structs) + [Array(self.rand_int_type(), self.r.randint(2, 4)), self.huge]
        for i, t in enumerate(tys):
            lv = self.leaves("r", t)
            if not lv:
                continue
            name = f"ru{i}"
            out.append(f"fn {name}(s: {t.name()}) {t.name()} {{")
            out.append(f"    var r = s;")
            for e, et in self.r.sample(lv, min(len(lv), 3)):
                e2, et2 = self.pick(lv)
                out.append(f"    {e} = {self.conv('s' + e2[1:], et2, et)} +% {self.lit(et)};")
            out.append(f"    mix({self.to_u64('s' + lv[0][0][1:], lv[0][1])});")
            out.append("    return r;")
            out.append("}")
            self.byref.append(("ru", name, t, None))
            if isinstance(t, Struct) and t.layout == "packed":
                continue
            name = f"bp{i}"
            e, et = self.pick(lv)
            out.append(f"fn {name}(p: *{t.name()}, s: {t.name()}) u64 {{")
            out.append(f"    const d0 = {digest('s', t)};")
            out.append(f"    p{e[1:]} {self.pick(['+%=', '^='])} {self.lit(et)};")
            out.append(f"    mix(d0);")
            out.append(f"    return {digest('s', t)};")
            out.append("}")
            self.byref.append(("bp", name, t, None))
        self.huge_fns = {k_: n_ for k_, n_, t_, _ in self.byref if t_ is self.huge}
        # Small optionals: wrap, unwrap-or, map (s_optreg).
        for o in self.opt_types():
            tn, nm = o["t"], o["n"]
            out.append(f"fn ow_{nm}(x: {tn}, c: bool) ?{tn} {{ return if (c) x else null; }}")
            out.append(f"fn ou_{nm}(o: ?{tn}, d: {tn}) {tn} {{ return o orelse d; }}")
            out.append(f"fn om_{nm}(o: ?{tn}) ?{tn} {{ const v = o orelse return null; return {o['step']('v')}; }}")
        # Arguments forwarded in another order (the callee's registers are
        # a permutation of the caller's).
        out.append(f"fn permB(x: u64, s1: {bt}, y: u32, s2: {bt}, z: i16) u64 {{")
        out.append(f"    return manyB(x, y, s2, z, @truncate(x), y, s1, @truncate(y), @bitCast(@as(u32, @truncate(x))), x +% 1, s2);")
        out.append("}")
        self.byref.append(("perm", "permB", big, None))
        out.append("")

    def s_range(self, ctx):
        """Values whose range a prover can know: blocks and switches yielding
        only constants, +% and -% whose exact result stays in range, and
        `a and b` bounds (also as switch prong ranges), with stores and
        loops between the guard and the use. Near misses keep a check."""
        a8, b8 = self.rt_int(ctx, Int(False, 8)), self.rt_int(ctx, Int(False, 8))
        if a8 is None or b8 is None:
            return self.s_prove(ctx)
        ctx["fn"].risky = True
        near = self.chance(0.35)
        e = lambda s_: self.emit(ctx, s_)
        u8 = Int(False, 8)
        arr = self.fresh("ga")

        def mkarr(n):
            n = max(1, n)
            e(f"var {arr}: [{n}]u16 = @splat({self.int_expr(ctx, Int(False, 16), 1)});")
            e(f"{arr}[{self.r.randrange(n)}] +%= 1;")

        def body(x, t=Int(False, 16)):
            ctx["indent"] += 1
            self.sink(ctx, x, t)
            ctx["indent"] -= 1

        k = self.r.randrange(7)
        c = self.fresh("gc")
        if k == 0:
            # A labeled block yielding constants (or, near, one runtime value).
            lo, hi = self.pick([(65, 97), (48, 57), (0, 9), (200, 255)])
            b = self.fresh("gb")
            e(f"const {c}: u8 = {b}: {{")
            e(f"    if (({a8} & 1) == 0) break :{b} {lo};")
            e(f"    if (({a8} & 2) == 0) break :{b} {(lo + hi) // 2};")
            e(f"    break :{b} {b8 if near else hi};")
            e("};")
            # c - lo cannot underflow unless a br is not constant.
            mkarr(hi - lo + 1)
            self.sink(ctx, f"{arr}[{c} - {lo}]", Int(False, 16))
        elif k == 1:
            # A switch expression yielding constants, then arithmetic on it.
            vals = sorted(self.r.sample(range(0, 40), 3))
            e(f"const {c}: u8 = switch ({a8} % 4) {{ 0 => {vals[0]}, 1 => {vals[1]}, else => {vals[2]} }};")
            mkarr(vals[2] + 1 - (1 if near else 0))
            self.sink(ctx, f"{arr}[{c}]", Int(False, 16))
            self.sink(ctx, f"{c} * 6 + {255 - 6 * vals[2] - (0 if not near else -1)}", u8)
        elif k == 2:
            # +% whose exact sum stays in u8, widened afterwards.
            m = self.r.randint(2, 127)
            x, y, z = self.fresh("gx"), self.fresh("gy"), self.fresh("gz")
            e(f"const {x}: u8 = {a8} % {m if not near else 200};")
            e(f"const {y}: u8 = {b8} % {m};")
            e(f"const {z}: u8 = {x} +% {y};")
            mkarr(2 * m - 1)
            self.sink(ctx, f"{arr}[@as(usize, {z})]", Int(False, 16))
            if self.chance(0.5):
                # Two levels: (x +% y) -% small stays >= 0 only when x + y >= small.
                w = self.fresh("gw")
                e(f"const {w}: u8 = ({z} +% 1) -% 1;")
                self.sink(ctx, f"{arr}[{w}]", Int(False, 16))
        elif k == 3:
            # -% that would go negative, and signed +%.
            x, y, z = self.fresh("gx"), self.fresh("gy"), self.fresh("gz")
            if self.chance(0.5):
                e(f"const {x}: u8 = {a8} % 50 + 50;")
                e(f"const {y}: u8 = {b8} % {80 if near else 50};")
                e(f"const {z}: u8 = {x} -% {y};")   # in [1, 99] unless near
                mkarr(100)
                self.sink(ctx, f"{arr}[{z}]", Int(False, 16))
            else:
                e(f"const {x}: i8 = @as(i8, @intCast({a8} % 61)) - 30;")
                e(f"const {y}: i8 = @as(i8, @intCast({b8} % {97 if near else 61})) - 30;")
                e(f"const {z}: i8 = {x} +% {y};")   # in [-60, 60] unless near
                mkarr(121)
                self.sink(ctx, f"{arr}[@intCast(@as(i16, {z}) + 60)]", Int(False, 16))
        elif k == 4:
            # A prong range, and the same as an `and` of two compares.
            lo, hi = sorted(self.r.sample(range(0, 120), 2))
            hi = max(hi, lo + 1)
            mkarr(hi - lo + (0 if near else 1))
            if self.chance(0.5):
                e(f"switch ({a8}) {{")
                e(f"    {lo}...{hi} => mix({arr}[{a8} - {lo}]),")
                e(f"    else => {{}},")
                e("}")
            else:
                e(f"if ({a8} >= {lo} and {a8} <= {hi}) {{")
                body(f"{arr}[{a8} - {lo}]")
                e("}")
        elif k == 5:
            # One side of the `and` already known; a store between guard and use.
            m = self.r.randint(10, 60)
            x = self.fresh("gx")
            e(f"var {x}: u8 = {a8} % {m};")
            lo = self.r.randint(0, 5)
            mkarr(m - lo)
            e(f"if ({x} >= {lo} and {x} <= {m + 20}) {{")
            ctx["indent"] += 1
            if near:
                e(f"{x} +%= 1;")
            else:
                e(f"{x} = {x};")
            self.sink(ctx, f"{arr}[{x} - {lo}]", Int(False, 16))
            ctx["indent"] -= 1
            e("}")
        else:
            # A loop whose condition is an `and` of two bounds.
            i = self.fresh("gi")
            lo, n = self.r.randint(1, 4), self.r.randint(5, 12)
            mkarr(n - lo + (0 if not near else -1))
            e(f"var {i}: usize = {self.conv(a8, u8, USIZE)} % {n + 3};")
            e(f"while ({i} >= {lo} and {i} < {n}) : ({i} += 1) {{")
            body(f"{arr}[{i} - {lo}]")
            e("}")
            self.sink(ctx, i, USIZE)

    def opt_types(self):
        """The small optional payloads s_optreg uses: name, type, a value
        expression, a step (for om_ and loop accumulators), and a fold to u64."""
        if getattr(self, "_opts", None) is not None:
            return self._opts
        en = self.enums[0]
        errs = lambda v, other: f"switch ({v}) {{ error.Alpha => error.Beta, error.Beta => error.Gamma, {other} }}"
        self._opts = [
            {"n": "u4", "t": "u4", "val": lambda g, c: g.int_expr(c, Int(False, 4), 1), "step": lambda v: f"{v} +% 3",
             "u64": lambda v: f"@as(u64, {v})"},
            {"n": "u32", "t": "u32", "val": lambda g, c: g.int_expr(c, U32, 1), "step": lambda v: f"{v} *% 0x9E37 +% 1",
             "u64": lambda v: f"@as(u64, {v})"},
            {"n": "bool", "t": "bool", "val": lambda g, c: g.bool_expr(c, 1), "step": lambda v: f"!{v}",
             "u64": lambda v: f"@as(u64, @intFromBool({v}))"},
            {"n": "en", "t": en.ename, "val": lambda g, c: f"@as({en.ename}, .{g.pick(en.tags)[0]})",
             "step": lambda v: f"switch ({v}) {{ {', '.join(f'.{a} => .{b}' for (a, _), (b, _) in zip(en.tags, en.tags[1:] + en.tags[:1]))} }}",
             "u64": lambda v: self.to_u64(v, en)},
            {"n": "ae", "t": "anyerror", "val": lambda g, c: f"@as(anyerror, error.{g.pick(ERRS)})",
             "step": lambda v: errs(v, "else => error.Alpha"),
             "u64": lambda v: f"@as(u64, switch ({v}) {{ error.Alpha => 11, error.Beta => 12, error.Gamma => 13, else => 14 }})"},
            {"n": "es", "t": "E", "val": lambda g, c: f"@as(E, error.{g.pick(ERRS)})",
             "step": lambda v: errs(v, "error.Gamma => error.Alpha"),
             "u64": lambda v: f"@as(u64, switch ({v}) {{ error.Alpha => 21, error.Beta => 22, error.Gamma => 23 }})"},
        ]
        return self._opts

    def s_optreg(self, ctx):
        """Small optionals of ints, bools, enums and error sets: wrapped,
        unwrapped, null-tested, passed, returned, and loop accumulators."""
        o = self.pick(self.opt_types())
        tn, nm = o["t"], o["n"]
        e = lambda s_: self.emit(ctx, s_)
        a, b = self.fresh("oa"), self.fresh("ob")
        cond = self.bool_expr(ctx, 1)
        if self.chance(0.5) or ctx["fn"].pure:
            e(f"const {a}: ?{tn} = if ({cond}) @as({tn}, {o['val'](self, ctx)}) else null;")
        else:
            e(f"const {a}: ?{tn} = ow_{nm}({o['val'](self, ctx)}, {cond});")
        k = self.r.randrange(5)
        if k == 0:
            v = self.fresh("ov")
            e(f"if ({a}) |{v}| {{")
            ctx["indent"] += 1
            self.sink(ctx, o["u64"](v), U64)
            ctx["indent"] -= 1
            e("} else {")
            ctx["indent"] += 1
            self.sink(ctx, "@as(u8, 0x5a)", Int(False, 8))
            ctx["indent"] -= 1
            e("}")
        elif k == 1:
            self.sink(ctx, f"@as(u8, @intFromBool({a} {self.pick(['==', '!='])} null))", Int(False, 8))
            self.sink(ctx, o["u64"](f"({a} orelse {o['val'](self, ctx)})"), U64)
        elif k == 2 and not ctx["fn"].pure:
            e(f"const {b}: ?{tn} = om_{nm}({a});")
            self.sink(ctx, o["u64"](f"ou_{nm}({b}, {o['val'](self, ctx)})"), U64)
            self.sink(ctx, f"@as(u8, @intFromBool({b} == null))", Int(False, 8))
        elif k == 3:
            # A loop accumulator.
            i = self.fresh("oi")
            e(f"var {b}: ?{tn} = {a};")
            e(f"for (0..{self.r.randint(1, 5)}) |{i}| {{")
            ctx["indent"] += 1
            e(f"{b} = if ({b}) |v| (if (({i} & 1) == 0) @as(?{tn}, {o['step']('v')}) else null) else {o['val'](self, ctx)};")
            ctx["indent"] -= 1
            e("}")
            self.sink(ctx, f"@as(u8, @intFromBool({b} != null))", Int(False, 8))
            self.sink(ctx, o["u64"](f"({b} orelse {o['val'](self, ctx)})"), U64)
        else:
            # Unwrap with .? behind a null test.
            e(f"if ({a} != null) {{")
            ctx["indent"] += 1
            self.sink(ctx, o["u64"](f"{a}.?"), U64)
            ctx["indent"] -= 1
            e("}")

    def s_wide(self, ctx):
        """64x64->128 widening multiplies and their halves, wide wrapping and
        checked arithmetic, and u128 compares, shifts and division."""
        sg = self.chance(0.35)
        h, w = (Int(True, 64), Int(True, 128)) if sg else (self.pick([U64, U64, U32, Int(False, 17), Int(False, 48), Int(False, 63)]), Int(False, 128))
        a, b, p = self.fresh("xa"), self.fresh("xb"), self.fresh("xp")
        e = lambda x: self.emit(ctx, x)
        ae, be = self.int_expr(ctx, h, 1), self.int_expr(ctx, h, 1)
        e(f"const {a}: {h.name()} = {ae};")
        e(f"const {b}: {h.name()} = {be};")
        e(f"const {p}: {w.name()} = @as({w.name()}, {a}) * @as({w.name()}, {b});")
        self.sink(ctx, f"@as({h.name()}, @truncate({p} >> 64))", h)
        self.sink(ctx, f"@as({h.name()}, @truncate({p}))", h)
        k = self.r.random()
        if k < 0.25:
            ov = self.fresh("xo")
            e(f"const {ov} = @mulWithOverflow({a}, {b});")
            self.sink(ctx, f"{ov}[0]", h)
            self.sink(ctx, f"{ov}[1]", Int(False, 1))
        elif k < 0.45:
            q = self.fresh("xq")
            e(f"const {q}: {w.name()} = {p} *% @as({w.name()}, {a} | 1) +% @as({w.name()}, {b});")
            self.sink(ctx, f"@as(u64, @truncate(@as(u128, @bitCast({q})) >> {self.r.randrange(128)}))", U64)
        elif k < 0.6 and not sg:
            self.sink(ctx, f"@as(u64, @truncate(@divTrunc({p}, @as(u128, {b} | 1)) ^ @rem({p}, @as(u128, {a} | 1))))", U64)
        elif k < 0.75:
            amt = self.rt_int(ctx, Int(False, 8))
            sh = f"@as(u7, @truncate({self.conv(amt, Int(False, 8), USIZE)}))" if amt else str(self.r.randrange(128))
            self.sink(ctx, f"@as(u64, @truncate(@as(u128, @bitCast({p} {self.pick(['<<', '>>'])} {sh}))))", U64)
        elif k < 0.85 and self.trap_ok(ctx, ae, be):
            # A checked multiply that can overflow the 128 bits.
            self.sink(ctx, f"@as(u64, @truncate(@as(u128, @bitCast({p} * @as({w.name()}, {a})))))", U64)
        else:
            self.sink(ctx, f"@as(u8, @intFromBool({p} {self.pick(['<', '<=', '==', '!=', '>', '>='])} @as({w.name()}, {a}) << 64))", Int(False, 8))

    def s_rot(self, ctx):
        """Rotates: std.math.rotl/rotr by runtime and constant amounts on any
        width, and the shift-or idiom."""
        t = self.pick([U64, U32, Int(False, 16), Int(False, 8), Int(False, 128)] + [x for x in self.ints if not x.signed and x.bits > 1])
        tn = t.name()
        x = self.fresh("rx")
        e = lambda s_: self.emit(ctx, s_)
        e(f"const {x}: {tn} = {self.int_expr(ctx, t, 1)};")
        amt = self.rt_int(ctx, Int(False, 8))
        ka = self.conv(amt, Int(False, 8), USIZE) if amt else str(self.r.randrange(200))
        f = self.pick(["rotl", "rotr"])
        self.sink(ctx, f"std.math.{f}({tn}, {x}, {ka})", t)
        if self.chance(0.5):
            self.sink(ctx, f"std.math.{self.pick(['rotl', 'rotr'])}({tn}, {x}, {self.r.randrange(t.bits * 2)})", t)
        if t.bits & (t.bits - 1) == 0:
            # x << k | x >> -%k: a rotate for every k when the width is a power of two.
            k = self.fresh("rk")
            e(f"const {k}: std.math.Log2Int({tn}) = @truncate({ka});")
            op1, op2 = self.pick([("<<", ">>"), (">>", "<<")])
            self.sink(ctx, f"({x} {op1} {k}) | ({x} {op2} -%{k})", t)
        else:
            k = self.fresh("rk")
            e(f"const {k}: std.math.Log2Int({tn}) = @intCast(1 + {ka} % {t.bits - 1});")
            self.sink(ctx, f"({x} << {k}) | ({x} >> @intCast({t.bits} - @as(u16, {k})))", t)

    def s_not(self, ctx):
        """Branches on negated compares and bools."""
        t = self.rand_int_type()
        a, b = self.int_expr(ctx, t, 1), self.int_expr(ctx, t, 1)
        c = self.fresh("nc")
        e = lambda s_: self.emit(ctx, s_)
        op = self.pick(['<', '<=', '==', '!=', '>', '>='])
        e(f"const {c}: bool = {a} {op} {b};")
        k = self.r.randrange(6)
        if k == 4:
            # The overflow bit of an add/sub/mul.
            ob = self.fresh("no")
            e(f"const {ob} = @{self.pick(['add', 'sub', 'mul'])}WithOverflow({a}, {b});")
            e(f"if (!({ob}[1] == 1)) {{")
            ctx["indent"] += 1
            self.sink(ctx, f"{ob}[0]", t)
            ctx["indent"] -= 1
            e("} else {")
            ctx["indent"] += 1
            self.sink(ctx, f"@as(u8, @intFromBool({c}))", Int(False, 8))
            ctx["indent"] -= 1
            e("}")
            return
        if k == 5:
            # Float compares that NaN makes false both ways.
            f = self.fresh("nf")
            ft = self.pick(["f32", "f64"])
            nan = f"std.math.nan({ft})" if self.chance(0.5) else f"@as({ft}, 1.5)"
            e(f"const {f}: {ft} = if ({c}) {nan} else @floatFromInt({self.conv(a, t, Int(True, 32))});")
            fop = self.pick(['<', '<=', '==', '!=', '>', '>='])
            e(f"if (!({f} {fop} @as({ft}, 2.0))) {{")
            ctx["indent"] += 1
            self.sink(ctx, f"@as(u8, @intFromBool(std.math.isNan({f})))", Int(False, 8))
            ctx["indent"] -= 1
            e("} else {")
            ctx["indent"] += 1
            self.sink(ctx, f"@as(u8, {self.r.randint(0, 200)})", Int(False, 8))
            ctx["indent"] -= 1
            e("}")
            return
        if k == 0:
            e(f"if (!({a} {op} {b})) {{")
            self.block(ctx, 1)
            e("} else {")
            self.block(ctx, 1)
            e("}")
            self.sink(ctx, f"@as(u8, @intFromBool(!{c}))", Int(False, 8))
        elif k == 1:
            other = self.bool_expr(ctx, 1)
            e(f"if (!{c} {self.pick(['and', 'or'])} !({other})) {{")
            self.block(ctx, 1)
            e("}")
        elif k == 2:
            n_, i_ = self.fresh("nd"), self.fresh("ni")
            e(f"var {n_}: bool = !{c};")
            e(f"var {i_}: u8 = 0;")
            e(f"while (!{n_}) : ({i_} += 1) {{")
            ctx["indent"] += 1
            self.sink(ctx, i_, Int(False, 8))
            e(f"{n_} = !({i_} < {self.r.randint(0, 3)});")
            ctx["indent"] -= 1
            e("}")
            self.sink(ctx, i_, Int(False, 8))
        else:
            r = self.fresh("nr")
            e(f"const {r}: {t.name()} = if (!{c}) {a} else {b};")
            self.sink(ctx, r, t)

    def s_sroaesc(self, ctx):
        """A local SE worked through inlined methods taking `self: *SE`, in
        loops, sometimes after its address escapes into a global or a
        non-inlined call (SROA must keep it in memory then)."""
        e = lambda s_: self.emit(ctx, s_)
        n = self.fresh("se")
        u64 = lambda: self.int_expr(ctx, U64, 1)
        e(f"var {n}: SE = .{{ .a = {u64()}, .b = {self.int_expr(ctx, U32, 1)}, .c = {self.int_expr(ctx, Int(False, 8), 1)}, "
          f".d = {self.int_expr(ctx, Int(True, 16), 1)}, .e = .{{ {', '.join(self.int_expr(ctx, Int(False, 16), 1) for _ in range(3))} }} }};")
        who = n
        if self.chance(0.4):
            who = self.fresh("sp")
            e(f"const {who}: *SE = &{n};")
        escaped = False
        for _ in range(self.r.randint(2, 5)):
            k = self.r.randrange(8)
            if k == 0:
                e(f"{who}.mix({u64()});")
            elif k == 1:
                e(f"{who}.rounds({self.r.randint(0, 4) if self.chance(0.5) else f'@as(usize, {self.int_expr(ctx, Int(False, 2), 1)})'});")
            elif k == 2:
                i = self.fresh("si")
                e(f"for (0..{self.r.randint(1, 6)}) |{i}| {{")
                ctx["indent"] += 1
                e(f"{who}.mix(@as(u64, {i}) *% {self.lit(U64)});")
                if self.chance(0.5):
                    e(f"if (({i} & 1) == 0) {who}.c +%= 1 else {who}.e[{i} % 3] ^= @truncate({who}.a);")
                ctx["indent"] -= 1
                e("}")
            elif k == 3:
                e(f"{who}.step2({self.int_expr(ctx, U32, 1)});")
            elif k == 4 and not ctx["fn"].pure:
                e(f"{who}.absorb({self.int_expr(ctx, U32, 1)});")
            elif k == 5 and not ctx["fn"].pure:
                # The address escapes into a global, and a call writes through it.
                e(f"gSEp = &{n};")
                e(f"seBump({self.int_expr(ctx, U32, 1)});")
                escaped = True
            elif k == 6 and not ctx["fn"].pure:
                self.sink(ctx, f"seRead(&{n})", U64)
            else:
                cp = self.fresh("sq")
                e(f"const {cp} = {n};")
                e(f"{who}.mix({self.lit(U64)});")
                self.sink(ctx, f"{cp}.fold()", U64)
        if escaped and self.chance(0.5):
            e(f"gSEp.d -%= 5;")
        self.sink(ctx, f"{who}.fold()", U64)
        if self.chance(0.3):
            self.sink(ctx, f"@as(u64, {n}.e[{self.r.randint(0, 2)}])", U64)

    def s_retbig(self, ctx):
        """Large struct results of non-inlined calls copied into locals,
        globals and array elements, then read field by field."""
        if ctx["fn"].pure:
            return self.s_sroa(ctx)
        tn = self.pick(list(RB_TYPES))
        fs = RB_TYPES[tn]
        e = lambda s_: self.emit(ctx, s_)
        u64 = lambda: self.int_expr(ctx, U64, 1)

        def field(v):
            f, t, n = self.pick(fs)
            at = f"{v}.{f}[{self.r.randrange(n)}]" if n else f"{v}.{f}"
            return f"@as(u64, @as(u{t[1:]}, @bitCast({at})))" if t[0] == "i" else f"@as(u64, {at})"

        v = self.fresh("rv")
        call = lambda: f"mk{tn}({u64()}, {self.bool_expr(ctx, 1)})" if self.chance(0.6) else f"mk2{tn}({u64()})"
        e(f"const {v}: {tn} = {call()};")
        for _ in range(self.r.randint(1, 3)):
            self.sink(ctx, field(v), U64)
        k = self.r.randrange(5)
        w = self.fresh("rw")
        if k == 0:
            # The assigned location is also the argument.
            e(f"var {w}: {tn} = {call()};")
            e(f"{w} = ed{tn}({w}, {u64()});")
            self.sink(ctx, field(w), U64)
            self.sink(ctx, f"fold{tn}(&{w})", U64)
        elif k == 1:
            e(f"g{tn} = {call()};")
            e(f"g{tn} = ed{tn}(g{tn}, {u64()});")
            self.sink(ctx, field(f"g{tn}"), U64)
        elif k == 2:
            i = self.fresh("ri")
            e(f"var {w}: [2]{tn} = undefined;")
            e(f"for (0..2) |{i}| {w}[{i}] = mk{tn}(@as(u64, {i}) +% {u64()}, ({i} & 1) == 0);")
            e(f"{w}[{self.r.randint(0, 1)}] = ed{tn}({w}[{self.r.randint(0, 1)}], {u64()});")
            self.sink(ctx, field(f"{w}[{self.r.randint(0, 1)}]"), U64)
            self.sink(ctx, f"fold{tn}(&{w}[1])", U64)
        elif k == 3:
            # Overwrite a local in a loop; the previous result feeds the next call.
            i = self.fresh("ri")
            e(f"var {w}: {tn} = mk2{tn}({u64()});")
            e(f"for (0..{self.r.randint(1, 4)}) |{i}| {{")
            ctx["indent"] += 1
            e(f"{w} = mk{tn}(fold{tn}(&{w}) +% {i}, ({i} & 1) == 1);")
            ctx["indent"] -= 1
            e("}")
            self.sink(ctx, field(w), U64)
        else:
            self.sink(ctx, f"fold{tn}(&{v})", U64)

    def s_erragg(self, ctx):
        """Large struct results through error unions (try, catch unreachable
        into a var, catch with a fallback, if/else on the union) and loops
        inside inlined callees."""
        if ctx["fn"].pure:
            return self.s_sroa(ctx)
        tn = self.pick(list(RB_TYPES))
        e = lambda s_: self.emit(ctx, s_)
        u64 = lambda: self.int_expr(ctx, U64, 1)
        kq = lambda: f"@as(u2, @truncate({self.int_expr(ctx, U64, 1)})) % 3"  # never 3: no error
        k = lambda: f"@as(u2, @truncate({self.int_expr(ctx, U64, 1)}))"
        nn = lambda: f"@as(usize, @as(u3, @truncate({self.int_expr(ctx, U64, 1)})))"
        w = self.fresh("ew")
        e(f"var {w}: {tn} = eg{tn}({u64()}, {kq()}) catch unreachable;")
        for _ in range(self.r.randint(1, 4)):
            j = self.r.randrange(6)
            if j == 0:
                e(f"{w} = il{tn}(fold{tn}(&{w}), {nn() if self.chance(0.6) else self.r.randint(0, 6)});")
            elif j == 1:
                e(f"{w} = eg{tn}(fold{tn}(&{w}), {k()}) catch |err| switch (err) {{ error.Beta => mk2{tn}({u64()}), else => {w} }};")
            elif j == 2:
                e(f"{w} = ilE{tn}({u64()}, {nn()}) catch mk2{tn}({self.lit(U64)});")
            elif j == 3:
                self.sink(ctx, f"(tr{tn}({u64()}, {k()}) catch |err| @as(u64, switch (err) {{ error.Alpha => 1, error.Beta => 2, error.Gamma => 3 }}))", U64)
            elif j == 4:
                v = self.fresh("ev")
                e(f"if (eg{tn}({u64()}, {k()})) |{v}| {{")
                ctx["indent"] += 1
                self.sink(ctx, f"fold{tn}(&{v})", U64)
                ctx["indent"] -= 1
                e("} else |err| {")
                ctx["indent"] += 1
                self.sink(ctx, f"@as(u8, @intFromBool(err == error.Beta))", Int(False, 8))
                ctx["indent"] -= 1
                e("}")
            else:
                i = self.fresh("ei")
                e(f"for (0..{self.r.randint(1, 4)}) |{i}| {{")
                ctx["indent"] += 1
                e(f"{w} = il{tn}(fold{tn}(&{w}) +% {i}, {i} + 1);")
                ctx["indent"] -= 1
                e("}")
        self.sink(ctx, f"fold{tn}(&{w})", U64)

    def s_packstore(self, ctx):
        """Packed struct stores: whole literals through pointers, array
        elements and fields, with defaults, field values that read the
        destination, checked casts inside them, separate field writes,
        volatile pointers, loops, and inlined functions."""
        if ctx["fn"].pure:
            return self.s_sroa(ctx)
        self.use_pk = True
        e = lambda s_: self.emit(ctx, s_)
        tn = self.pick(PK_HOSTS + ["P32", "P16"])
        fs = PK_TYPES[tn][1]
        u64 = lambda: self.int_expr(ctx, U64, 1)
        # The destination.
        where = self.r.randrange(5)
        if where == 0 and tn == "P32":
            dest = f"&gPA[{self.r.randint(0, 2)}]"
        elif where == 1 and tn == "P16":
            dest = "&gPS.p"
        elif where == 2:
            loc = self.fresh("pl")
            e(f"var {loc}: {tn} = g{tn};")
            dest = f"&{loc}"
        else:
            dest = f"&g{tn}"
        p = self.fresh("pp")
        vol = self.chance(0.2)
        e(f"const {p}: *{'volatile ' if vol else ''}{tn} = {dest};")

        def value(f, k, idx=None):
            r = self.r.random()
            if r < 0.3:
                # Read the destination itself (an earlier or later field).
                g, gk, _ = self.pick(fs)
                src = pk_to_u64(f"{p}.{g}", gk)
                extra = f" +% {idx}" if idx else ""
                return pk_from_u64(f"({src} +% {self.r.randint(0, 3)}{extra})", k)
            if r < 0.45 and isinstance(k, tuple):
                # A checked cast that fires when the value does not fit.
                small = self.r.randint(0, (1 << (k[1] - 1)) + 2)
                return pk_from_u64(f"(@as(u64, {small}) +% (@as(u64, @as(u8, @bitCast(gP8))) & 1))", k, checked=True)
            if r < 0.55 and k in PK_TYPES:
                sub = PK_TYPES[k][1]
                return ".{ " + ", ".join(f".{sf} = {pk_from_u64(u64(), sk)}" for sf, sk, _ in sub) + " }"
            return pk_from_u64(u64() + (f" +% {idx}" if idx else ""), k)

        def literal(idx=None):
            parts = []
            for f, k, d in fs:
                if d is not None and self.chance(0.5):
                    continue  # the field default
                parts.append(f".{f} = {value(f, k, idx)}")
            return ".{ " + ", ".join(parts) + " }" if parts else ".{}"

        form = self.r.randrange(6)
        if form <= 1:
            e(f"{p}.* = {literal()};")
        elif form == 2:
            for f, k, _ in self.r.sample(fs, self.r.randint(1, len(fs))):
                e(f"{p}.{f} = {value(f, k)};")
        elif form == 3:
            i = self.fresh("pi")
            lt = literal(i)
            used = re.search(rf"\b{i}\b", lt) is not None
            e(f"for (0..{self.r.randint(1, 4)}) |{i if used else '_'}| {{")
            ctx["indent"] += 1
            e(f"{p}.* = {lt};")
            ctx["indent"] -= 1
            e("}")
        elif form == 4 and not vol:
            e(f"pkSet{tn}({p}, {u64()});")
            f, k, _ = self.pick(fs)
            e(f"{p}.{f} = {value(f, k)};")
        else:
            # Copy one host into another through the pointer, then a literal.
            e(f"{p}.* = g{tn};")
            e(f"{p}.* = {literal()};")
        self.sink(ctx, pk_to_u64(f"{p}.*", tn), U64)
        if self.chance(0.4):
            f, k, _ = self.pick(fs)
            self.sink(ctx, pk_to_u64(f"{p}.{f}", k), U64)

    def s_prove3(self, ctx):
        """Checks a prover may drop from facts: asserts and `if (!ok)
        unreachable` before a use, the same load twice with or without a
        store between, a facts-carrying bool block, a counted-down loop,
        ranges of %, &, >>, @min/@max and casts, and facts at a block's
        single br. Near misses keep their check."""
        x = self.rt_int(ctx, U64)
        if x is None:
            return self.s_prove(ctx)
        ctx["fn"].risky = True
        e = lambda s_: self.emit(ctx, s_)
        near = self.chance(0.35)
        n = self.r.randint(2, 9)
        a = self.fresh("pa")
        e(f"var {a}: [{n}]u32 = @splat({self.int_expr(ctx, U32, 1)});")
        e(f"{a}[{self.r.randrange(n)}] ^= {self.lit(U32)};")
        sl = self.fresh("ps")
        lo = self.r.randint(0, n - 1)
        e(f"var {sl}: []u32 = {a}[{lo}..];")
        e(f"_ = &{sl};")
        i = self.fresh("pi")
        k = self.r.randrange(9)
        if k == 0:
            # assert, then use; near: the assert can fail (it panics).
            bound = f"{sl}.len" if not near else f"{sl}.len + 1"
            e(f"const {i}: usize = @as(usize, @truncate({x})) % ({n} + 1);")
            e(f"if ({i} < {bound}) {{")
            ctx["indent"] += 1
            e(f"std.debug.assert({i} < {sl}.len);" if not near else f"std.debug.assert({i} <= {sl}.len);")
            self.sink(ctx, f"{sl}[{i}]", U32)
            ctx["indent"] -= 1
            e("}")
        elif k == 1:
            e(f"const {i}: usize = @as(usize, @truncate({x})) & 7;")
            if self.chance(0.5) or ctx.get("in_defer") or ctx["fn"].err:
                e(f"if (!({i} < {sl}.len{' + 1' if near else ''})) unreachable;")
            else:
                e(f"if ({i} >= {sl}.len{' + 1' if near else ''}) return {self.ret_value(ctx)};")
            self.sink(ctx, f"{sl}[{i}]", U32)
        elif k == 2:
            # The same load twice; a store between may change it.
            p = self.fresh("pp")
            j = self.fresh("pj")
            e(f"const {p}: *[{n}]u32 = &{a};")
            e(f"const {i}: usize = {p}[0] % {n};")
            if self.chance(0.6):
                e(f"{p}[{self.r.randrange(n)}] = {self.int_expr(ctx, U32, 1)};")
            e(f"const {j}: usize = {p}[0] % {n + (1 if near else 0)};")
            self.sink(ctx, f"{a}[{i}] +% {a}[{j}]", U32)
        elif k == 3:
            # A bool block that carries the bound.
            ok = self.fresh("pk")
            e(f"const {i}: usize = @as(usize, @truncate({x})) % 12;")
            e(f"const {ok} = blk: {{")
            ctx["indent"] += 1
            e(f"if ({self.bool_expr(ctx, 1)}) break :blk {i} < {sl}.len{' + 1' if near else ''};")
            e(f"break :blk {i} < {max(0, n - lo - 1)};")
            ctx["indent"] -= 1
            e("};")
            e(f"if ({ok}) {{")
            ctx["indent"] += 1
            self.sink(ctx, f"{sl}[{i}]", U32)
            ctx["indent"] -= 1
            e("}")
        elif k == 4:
            # Counted down; near: one past the end.
            v = self.fresh("pv")
            e(f"var {v}: usize = {sl}.len{' + 1' if near else ''};")
            e(f"while ({v} > 0) {{")
            ctx["indent"] += 1
            e(f"{v} -= 1;")
            self.sink(ctx, f"{sl}[{v}]", U32)
            if self.chance(0.4):
                e(f"if ({sl}[{v}] & 3 == 1) break;")
            ctx["indent"] -= 1
            e("}")
        elif k == 5:
            # Ranges of %, &, >>, @min, @max and casts.
            m = n - lo
            r = self.pick([f"@as(usize, @truncate({x})) % {m + (1 if near else 0)}",
                           f"@as(usize, @truncate({x})) & {(1 << max(0, m.bit_length() - 1)) - 1 + (m if near else 0)}",
                           f"@as(usize, @truncate({x} >> {64 - max(1, (m - 1).bit_length()) - (1 if near else 0)}))" if m > 1 else "0",
                           f"@min(@as(usize, @truncate({x})), {m - 1 + (1 if near else 0)})",
                           f"@max(@as(usize, @as(u3, @truncate({x}))), 1) - 1" if m >= 7 + (1 if near else 0) else "0",
                           f"@as(usize, @as(u2, @truncate({x})))" if m >= 4 + (1 if near else 0) else "0"])
            e(f"const {i}: usize = {r};")
            self.sink(ctx, f"{sl}[{i}]", U32)
        elif k == 6:
            # Exact add/sub ranges.
            e(f"const {i}: usize = (@as(usize, @as(u2, @truncate({x}))) + 1) - {0 if near else 1};")
            self.sink(ctx, f"{a}[{i} % {n}] +% {sl}[@min({i}, {sl}.len - 1)]", U32)
            if 4 + (1 if near else 0) <= n:
                self.sink(ctx, f"{a}[{i}]", U32)
        elif k == 7:
            # Facts at a block's single br; a store between the check and the use.
            b = self.fresh("pb")
            e(f"var {i}: usize = @as(usize, @truncate({x})) % 10;")
            e(f"_ = &{i};")
            e(f"{b}: {{")
            ctx["indent"] += 1
            e(f"if ({i} >= {sl}.len) break :{b};")
            if self.chance(0.5):
                e(f"{i} {'+= 1' if near else '-|= 1'};")
            self.sink(ctx, f"{sl}[{i}]", U32)
            ctx["indent"] -= 1
            e("}")
        else:
            # A loop whose bound shrinks; the check must follow the shrink.
            j = self.fresh("pj")
            e(f"var {j}: usize = 0;")
            e(f"while ({j} < {sl}.len) : ({j} += 1) {{")
            ctx["indent"] += 1
            e(f"if ({sl}[{j}] & 1 == 0 and {sl}.len > 1) {sl} = {sl}[0 .. {sl}.len - 1];")
            self.sink(ctx, f"{sl}[{j}]" if not near else f"{sl}[{j} + 1]", U32)
            ctx["indent"] -= 1
            e("}")

    def s_sharefwd(self, ctx):
        """A struct, array or tuple copied whole into a const in a loop, new
        values computed from the copy, then written back field by field,
        some from the copy and some from the computed values."""
        if ctx["fn"].pure:
            return self.s_sroa(ctx)
        self.extra.add("sharefwd")
        e = lambda s_: self.emit(ctx, s_)
        n = self.r.randint(1, 9)
        cnt = self.fresh("fi")
        kind = self.r.randrange(4)
        outer = self.chance(0.3)
        if outer:
            e(f"for (0..{self.r.randint(1, 3)}) |_| {{")
            ctx["indent"] += 1
        # Fields: (name, type, init, combine(x, y) -> expr, to_u64(v))
        kinds = {
            "u64": ("u64", lambda: self.int_expr(ctx, U64, 1), lambda x, y: self.pick([f"{x} +% {y}", f"{x} % ({y} | 1)",
                    f"sfMix({x}, {y})", f"sfIn({x}, {y})", f"{x} *% 3 +% {y}"]), lambda v: v),
            "u32": ("u32", lambda: self.int_expr(ctx, U32, 1), lambda x, y: self.pick([f"{x} +% {y}", f"{x} ^ ({y} >> 1)",
                    f"@as(u32, @truncate(sfMix({x}, {y})))"]), lambda v: f"@as(u64, {v})"),
            "i16": ("i16", lambda: self.int_expr(ctx, Int(True, 16), 1), lambda x, y: f"{x} -% {y}",
                    lambda v: f"@as(u64, @as(u16, @bitCast({v})))"),
            "f64": ("f64", lambda: self.pick(["1.5", "-0.25", "3.0", "0.0"]), lambda x, y: self.pick([f"{x} + {y}", f"{x} * 0.5 - {y}"]),
                    lambda v: f"@as(u64, @bitCast({v}))"),
            "bool": ("bool", lambda: self.bool_expr(ctx, 1), lambda x, y: self.pick([f"{x} != {y}", f"!{x}", f"{x} and {y}"]),
                     lambda v: f"@as(u64, @intFromBool({v}))"),
            "ptr": ("*const u32", lambda: self.pick(["&gSfA", "&gSfB"]), lambda x, y: y, lambda v: f"@as(u64, {v}.*)"),
        }
        if kind <= 1:
            nf = self.r.randint(2, 8)
            fts = [self.pick(["u64", "u64", "u32", "i16", "f64", "bool", "ptr"]) for _ in range(nf)]
            names = [f"f{i}" for i in range(nf)]
            T = self.fresh("SF")
            e(f"const {T} = struct {{ {', '.join(f'{nm}: {kinds[ft][0]}' for nm, ft in zip(names, fts))} }};")
            v = self.fresh("sf")
            e(f"var {v}: {T} = .{{ {', '.join(f'.{nm} = {kinds[ft][1]()}' for nm, ft in zip(names, fts))} }};")
            acc = lambda c, i: f"{c}.{names[i]}"
            store = lambda i, val: f"{v}.{names[i]} = {val};"
            whole = None
        elif kind == 2:
            nf = self.r.randint(2, 6)
            fts = ["u64"] * nf
            v = self.fresh("sa")
            e(f"var {v}: [{nf}]u64 = .{{ {', '.join(kinds['u64'][1]() for _ in range(nf))} }};")
            acc = lambda c, i: f"{c}[{i}]"
            store = lambda i, val: f"{v}[{i}] = {val};"
            whole = "arr"
        else:
            nf = self.r.randint(2, 4)
            fts = ["u64"] * nf
            v = self.fresh("st")
            e(f"var {v}: struct {{ {', '.join(['u64'] * nf)} }} = .{{ {', '.join(kinds['u64'][1]() for _ in range(nf))} }};")
            acc = lambda c, i: f"{c}[{i}]"
            store = lambda i, val: f"{v}[{i}] = {val};"
            whole = "tuple"
        e(f"var {cnt}: usize = 0;")
        e(f"while ({cnt} < {n}) : ({cnt} += 1) {{")
        ctx["indent"] += 1
        t = self.fresh("sc")
        e(f"const {t} = {v};")
        # New values: copies of same-typed fields, or computed from them.
        vals = []
        for i, ft in enumerate(fts):
            same = [j for j, g in enumerate(fts) if g == ft]
            if self.chance(0.5):
                vals.append(acc(t, self.pick(same)))
            else:
                nv = self.fresh("sn")
                e(f"const {nv} = {kinds[ft][2](acc(t, self.pick(same)), acc(t, self.pick(same)))};")
                vals.append(nv)
        if whole is not None and self.chance(0.4):
            e(f"{v} = .{{ {', '.join(vals)} }};")
        else:
            order = list(range(nf))
            self.r.shuffle(order)
            br = self.r.randrange(len(order) + 1) if self.chance(0.3) else -1
            for pos, i in enumerate(order):
                if pos == br:
                    e(f"if ({self.bool_expr(ctx, 1)}) {{")
                    ctx["indent"] += 1
                    e(store(i, vals[i]))
                    ctx["indent"] -= 1
                    e("} else {")
                    ctx["indent"] += 1
                    e(store(i, acc(t, i)))
                    ctx["indent"] -= 1
                    e("}")
                else:
                    e(store(i, vals[i]))
        ctx["indent"] -= 1
        e("}")
        for i, ft in enumerate(fts):
            self.sink(ctx, kinds[ft][3](acc(v, i)), U64)
        if outer:
            ctx["indent"] -= 1
            e("}")

    def s_fwdalias(self, ctx):
        """Loads and copies with writes in between that may alias them:
        through another pointer to the same local or global, a field
        pointer, the whole struct, calls that write through a given, global
        or saved pointer, @memcpy/@memset, payload pointers, and loops that
        write after the load."""
        if ctx["fn"].pure:
            return self.s_sroa(ctx)
        self.extra.add("fwdalias")
        e = lambda s_: self.emit(ctx, s_)
        u32 = lambda: self.int_expr(ctx, U32, 1)
        sk = lambda x: self.sink(ctx, x, U64)
        k = self.r.randrange(10)
        if k <= 7:
            # The target: a local (sometimes saved globally) or the global.
            if self.chance(0.7):
                l = self.fresh("al")
                e(f"var {l}: AQ = .{{ .a = {u32()}, .b = {u32()}, .c = {self.int_expr(ctx, U64, 1)} }};")
                tgt = f"&{l}"
                if self.chance(0.4):
                    e(f"aqSave(&{l});")
                    e("defer aqSave(&gAQ);")
            else:
                tgt = "&gAQ"
            p, q = self.fresh("ap"), self.fresh("aq")
            e(f"const {p}: *AQ = {tgt};")
            e(f"const {q}: *AQ = {self.pick([tgt, p, 'gAQp'])};")
            e(f"_ = &{p};")
            e(f"_ = &{q};")
        x1, x2 = self.fresh("ax"), self.fresh("ay")
        if k == 0:
            f = self.pick(["a", "b", "c"])
            e(f"const {x1} = {p}.{f};")
            w = self.r.randrange(3)
            if w == 0:
                e(f"{q}.{f} = {'@as(u64, ' + u32() + ')' if f == 'c' else u32()};")
            elif w == 1:
                e(f"{q}.* = .{{ .a = {u32()}, .b = {u32()}, .c = 17 }};")
            else:
                fp = self.fresh("af")
                e(f"const {fp}: *{'u64' if f == 'c' else 'u32'} = &{q}.{f};")
                e(f"{fp}.* +%= 3;")
            e(f"const {x2} = {p}.{f};")
            sk(f"@as(u64, {x1}) *% 1000 +% {x2}")
        elif k == 1:
            f = self.pick(["a", "b"])
            e(f"const {x1} = {p}.{f};")
            e(self.pick([f"aqWrite({q}, {u32()});", f"aqWriteG({u32()});", f"aqWriteSaved({u32()});"]))
            e(f"const {x2} = {p}.{f};")
            sk(f"@as(u64, {x1}) *% 1000 +% {x2}")
            sk(f"aqRead({p})")
        elif k == 2:
            c = self.fresh("ac")
            e(f"const {c} = {p}.*;")
            e(self.pick([f"{q}.a = {u32()};", f"aqWrite({q}, {u32()});", f"aqWriteSaved({u32()});", f"{q}.* = .{{ .a = 1, .b = 2, .c = 3 }};"]))
            sk(f"@as(u64, {c}.a) *% 7 +% {c}.b +% {c}.c")
            sk(f"aqRead({p})")
        elif k == 3:
            c = self.fresh("ac")
            e(f"const {c} = {p}.*;")
            e(f"{q}.* = .{{ .a = {c}.b, .b = {c}.a, .c = {c}.c +% {c}.a }};")
            sk(f"aqRead({p})")
            sk(f"@as(u64, {p}.a) << 32 | {p}.b")
        elif k == 4:
            e(f"const {x1} = {self.pick(['aqTwo', 'aqCopy'])}({p}, {q});")
            sk(x1)
            sk(f"aqRead({p})")
        elif k == 5:
            e(f"const {x1} = aqTwoI({p}, {q});")
            sk(x1)
            e(f"const {x2} = aqFld({p}, &{q}.{self.pick(['a', 'b'])});")
            sk(x2)
        elif k == 6:
            e(f"const {x1} = aqCopyArg({p}.*, {q});")
            sk(x1)
            sk(f"aqRead({p})")
        elif k == 7:
            # A loop that writes after the load.
            i = self.fresh("ai")
            e(f"for (0..{self.r.randint(1, 5)}) |{i}| {{")
            ctx["indent"] += 1
            e(f"const {x1} = {p}.a;")
            sk(x1)
            e(self.pick([f"{q}.a +%= @intCast({i} + 1);", f"aqWrite({q}, @intCast({i}));", f"aqWriteSaved(@intCast({i} * 3));"]))
            ctx["indent"] -= 1
            e("}")
            sk(f"aqRead({p})")
        elif k == 8:
            # @memcpy / @memset between two loads of the same element.
            b, o = self.fresh("ab"), self.fresh("ao")
            e(f"var {b}: [4]u32 = .{{ {u32()}, {u32()}, {u32()}, {u32()} }};")
            e(f"var {o}: [4]u32 = @splat({u32()});")
            e(f"_ = &{o};")
            sl = self.fresh("as")
            e(f"const {sl}: []u32 = {b}[{self.r.randint(0, 1)}..];")
            e(f"_ = &{sl};")
            idx = self.r.randint(1, 2)
            e(f"const {x1} = {b}[{idx}];")
            e(self.pick([f"@memset({sl}[0..2], {u32()});", f"@memcpy({sl}[0..2], {o}[0..2]);", f"@memset({b}[0..], 9);"]))
            e(f"const {x2} = {b}[{idx}];")
            sk(f"@as(u64, {x1}) *% 1000 +% {x2}")
        else:
            # Optional and error-union payload pointers.
            if self.chance(0.5):
                o = self.fresh("ao")
                e(f"var {o}: ?AQ = .{{ .a = {u32()}, .b = {u32()}, .c = 4 }};")
                pp = self.fresh("app")
                e(f"if ({o}) |*{pp}| {{")
                ctx["indent"] += 1
                e(f"const {x1} = {pp}.a;")
                e(self.pick([f"{o}.?.a = {u32()};", f"{o} = .{{ .a = 5, .b = 6, .c = 7 }};", f"aqWrite(&{o}.?, 3);"]))
                e(f"const {x2} = {pp}.a;")
                sk(f"@as(u64, {x1}) *% 1000 +% {x2}")
                ctx["indent"] -= 1
                e("}")
            else:
                o = self.fresh("ae")
                e(f"var {o}: E!u32 = {u32()};")
                pp = self.fresh("app")
                e(f"if ({o}) |*{pp}| {{")
                ctx["indent"] += 1
                e(f"const {x1} = {pp}.*;")
                e(f"{o} = {u32()};")
                e(f"const {x2} = {pp}.*;")
                sk(f"@as(u64, {x1}) *% 1000 +% {x2}")
                ctx["indent"] -= 1
                e("} else |_| {}")

    def s_unrollswap(self, ctx):
        """std.mem.swap and its byte loop over @ptrCast slices of *T (odd
        sizes, packed and extern structs, arrays), swaps through aliasing,
        identical or overlapping pointers, byte loops that break or
        continue early, and loops over constant-length subslices
        `s[a..][0..N]`, directly or through a slice local that may be
        reassigned through a pointer."""
        if ctx["fn"].pure:
            return self.s_sroa(ctx)
        ctx["fn"].risky = True
        self.extra.add("unrollswap")
        e = lambda s_: self.emit(ctx, s_)
        sk = lambda x: self.sink(ctx, x, U64)
        u8 = lambda: f"@as(u8, @truncate({self.int_expr(ctx, U64, 1)}))"
        sel = self.fresh("us")
        e(f"var {sel} = [_]usize{{ 0, 1, 2, 3, 4, 5, 7, 9 }};")
        e(f"_ = &{sel};")
        pv = lambda: f"{sel}[@as(usize, @truncate({self.int_expr(ctx, U64, 1)})) % 8]"
        # (type, literal, fields to sink, has no padding)
        def lit(t):
            if t == "UsE":
                return f".{{ .a = {u8()}, .b = {self.int_expr(ctx, Int(False, 16), 1)}, .c = {u8()} }}", ["a", "b", "c"], False
            if t == "UsP":
                return f".{{ .a = @truncate({u8()}), .b = @truncate({self.int_expr(ctx, Int(False, 16), 1)}), .c = {u8()} }}", ["a", "b", "c"], False
            if t == "UsS":
                return f".{{ .x = @truncate({self.int_expr(ctx, U64, 1)}), .y = {u8()} }}", ["x", "y"], False
            if t == "UsO":
                return f".{{ .a = .{{ {u8()}, 2, {u8()} }}, .b = {u8()}, .c = 7 }}", ["a[0]", "a[1]", "a[2]", "b", "c"], True
            if t == "[7]u8":
                return f"@splat({u8()})", [f"[{i}]" for i in range(7)], True
            if t == "[3]u16":
                return f".{{ {self.int_expr(ctx, Int(False, 16), 1)}, 5, 0xffff }}", ["[0]", "[1]", "[2]"], True
            return f"@truncate({self.int_expr(ctx, U64, 1)})", [""], False
        def sinkv(v, fields):
            for f in fields:
                sk(f"@as(u64, {v}{'.' + f if f and not f.startswith('[') else f})")
        k = self.r.randrange(8)
        if k <= 3:
            t = self.pick(["UsE", "UsP", "UsS", "UsO", "[7]u8", "[3]u16", "u24"])
            a, b = self.fresh("ua"), self.fresh("ub")
            la, fields, nopad = lit(t)
            lb, _, _ = lit(t)
            e(f"var {a}: {t} = {la};")
            e(f"var {b}: {t} = {lb};")
            e(f"_ = &{b};")
            w = self.r.randrange(6)
            if w <= 1:
                e(f"std.mem.swap({t}, &{a}, &{b});")
            elif w == 2:
                e(f"usSwap({t}, &{a}, &{a});")
            elif w == 3:
                pa = self.fresh("up")
                e(f"const {pa}: *{t} = {self.pick([f'&{a}', f'&{b}'])};")
                e(f"{self.pick(['usSwap', 'usSwapI'])}({t}, {pa}, &{a});")
            elif w == 4:
                e(f"usSwapI({t}, &{a}, &{b});")
            else:
                for _ in range(self.r.randint(2, 3)):
                    e(f"std.mem.swap({t}, &{a}, &{b});")
            if nopad and self.chance(0.6):
                # Mutate the bytes, with an early break or continue.
                bs, i = self.fresh("uby"), self.fresh("ui")
                e(f"const {bs}: []u8 = @ptrCast(&{a});")
                e(f"for ({bs}, 0..) |*x, {i}| {{")
                ctx["indent"] += 1
                ex = self.r.randrange(3)
                if ex == 0:
                    e(f"if ({i} == {pv()}) break;")
                elif ex == 1:
                    e(f"if (x.* == {u8()} or {i} == {pv()}) continue;")
                e(f"x.* +%= @truncate({i} *% 3 +% 1);")
                ctx["indent"] -= 1
                e("}")
            sinkv(a, fields)
            sinkv(b, fields)
        elif k == 4:
            # Overlapping byte windows of one buffer.
            buf = self.fresh("ubuf")
            n = self.r.randint(2, 5)
            e(f"var {buf}: [10]u8 = .{{ {', '.join(str(self.r.randint(0, 255)) for _ in range(10))} }};")
            e(f"usSwap([{n}]u8, {buf}[{self.r.randint(0, 2)}..][0..{n}], {buf}[{self.r.randint(0, 4)}..][0..{n}]);")
            sk(f"std.mem.readInt(u64, {buf}[0..8], .little)")
            sk(f"@as(u64, {buf}[8]) << 8 | {buf}[9]")
        else:
            # Loops over constant-length subslices s[a..][0..N].
            buf = self.fresh("ubuf")
            L = self.r.randint(6, 16)
            e(f"var {buf}: [{L}]u8 = @splat({u8()});")
            sl = self.fresh("usl")
            e(f"const {sl}: []u8 = &{buf};")
            n = self.r.randint(1, min(8, L))
            a = self.fresh("uo")
            e(f"const {a}: usize = {pv()}{' % ' + str(L - n + 1) if self.chance(0.85) else ''};")
            if k == 5:
                src = f"{sl}[{a}..][0..{n}]"
            elif k == 6:
                cs = self.fresh("ucs")
                e(f"const {cs}: []u8 = {sl}[{a}..][0..{n}];")
                src = cs
            else:
                vs, vp = self.fresh("uvs"), self.fresh("uvp")
                e(f"var {vs}: []u8 = {sl}[{a}..][0..{n}];")
                e(f"const {vp}: *[]u8 = &{vs};")
                m = self.r.randint(0, min(8, L))
                e(f"if ({self.bool_expr(ctx, 1)}) {vp}.* = {sl}[{self.r.randint(0, L - m)}..][0..{m}];")
                src = vs
            i = self.fresh("ui")
            e(f"for ({src}, 0..) |*x, {i}| {{")
            ctx["indent"] += 1
            ex = self.r.randrange(3)
            if ex == 0:
                e(f"if ({i} == {pv()}) break;")
            elif ex == 1:
                e(f"if ({i} & 1 == {self.r.randint(0, 1)}) continue;")
            e(f"x.* = x.* *% 7 +% @as(u8, @truncate({i}));")
            if self.chance(0.4):
                sk(f"@as(u64, {sl}[{a} + {i}])")
            ctx["indent"] -= 1
            e("}")
            for j in range(L):
                sk(f"@as(u64, {buf}[{j}])")

    def s_storefwd(self, ctx):
        """A store through a pointer, then a load of the same address used
        as an index or a slice length, with writes in between that must
        invalidate it (an aliasing pointer, a byte pointer, a call, inline
        asm, a volatile store, a whole-struct or whole-slice store), stores
        in one branch or case only, stores in loops, `undefined` stores, and
        slice lengths stored through `*[]T`, struct fields and globals."""
        if ctx["fn"].pure:
            return self.s_sroa(ctx)
        ctx["fn"].risky = True
        self.extra.add("storefwd")
        e = lambda s_: self.emit(ctx, s_)
        sk = lambda x: self.sink(ctx, x, U32)
        sel = self.fresh("fs")
        vals = [0, 1, 2, 3, 5, 7, 8, 9, 15, 16, 17, 40]
        e(f"var {sel} = [_]usize{{ {', '.join(map(str, vals))} }};")
        e(f"_ = &{sel};")
        pv = lambda: f"{sel}[@as(usize, @truncate({self.int_expr(ctx, U64, 1)})) % {len(vals)}]"
        k = self.r.randrange(13)
        if k <= 5 or k == 12:
            # A usize index held in a local, an array element, a struct
            # field or a global, stored and loaded through p.
            arr = self.fresh("fa")
            e(f"var {arr}: [16]u32 = @splat({self.int_expr(ctx, U32, 1)});")
            e(f"_ = &{arr};")
            h = self.r.randrange(4)
            hv = self.fresh("fh")
            if h == 0:
                e(f"var {hv}: usize = {pv()};")
                addr = f"&{hv}"
            elif h == 1:
                e(f"var {hv}: [4]usize = .{{ {pv()}, {pv()}, 1, 2 }};")
                addr = f"&{hv}[{self.r.randint(0, 3)}]"
            elif h == 2:
                e(f"var {hv}: struct {{ a: usize, b: u8 }} = .{{ .a = {pv()}, .b = 3 }};")
                addr = f"&{hv}.a"
            else:
                addr = "&gSfIdx"
            e(f"_ = &{hv};" if h < 3 else "_ = &gSfIdx;")
            p = self.fresh("fp")
            e(f"const {p}: *usize = {addr};")
            small = self.pick([f"{pv()} & 7", str(self.r.randint(0, 15)), f"@min({pv()}, 15)"])
            big = pv
            idx = lambda: f"{p}.*"
            if k <= 3:
                e(f"{p}.* = {small};")
                w = self.r.randrange(9)
                if w == 0:
                    q = self.fresh("fq")
                    if h == 1:
                        e(f"const {q}: *usize = &{hv}[{pv()} & 3];")
                    else:
                        e(f"const {q}: *usize = {addr};")
                    e(f"{q}.* = {big()};")
                elif w == 1:
                    bp = self.fresh("fb")
                    e(f"const {bp}: *u8 = @ptrCast({p});")
                    e(f"{bp}.* = @truncate({big()});")
                elif w == 2:
                    if h == 2:
                        e(f"{hv} = .{{ .a = {big()}, .b = 4 }};")
                    elif h == 1:
                        e(f"{hv} = .{{ {big()}, {big()}, {big()}, {big()} }};")
                    else:
                        e(f"sfPut({p}, {big()});")
                elif w == 3:
                    e(f"sfPut({p}, {big()});")
                elif w == 4:
                    e(f"sfPutG({big()});")
                elif w == 5:
                    e(f'asm volatile ("movq %[v], (%%rdi)" : : [p] "{{rdi}}" ({p}), [v] "r" ({big()}) : .{{ .memory = true }});')
                elif w == 6:
                    vp = self.fresh("fv")
                    e(f"const {vp}: *volatile usize = {p};")
                    e(f"{vp}.* = {big()};")
                elif w == 7:
                    e(f"_ = sfRead({p});")
                # w == 8: nothing in between, the load is forwarded.
            elif k == 4:
                # A store on one side only; the old value may be big.
                if self.chance(0.5):
                    e(f"if ({self.bool_expr(ctx, 1)}) {p}.* = {small};")
                else:
                    e(f"switch ({pv()} % 3) {{")
                    e(f"    0 => {p}.* = {small},")
                    e("    1 => {},")
                    e(f"    else => {p}.* = {self.r.randint(0, 15)},")
                    e("}")
            elif k == 5:
                # Stores in a loop, loaded in the next iteration and after.
                i = self.fresh("fi")
                e(f"{p}.* = {small};")
                e(f"for (0..{self.r.randint(1, 5)}) |{i}| {{")
                ctx["indent"] += 1
                sk(f"{arr}[{p}.*]")
                e(f"{p}.* = {sel}[({i} + {self.r.randint(0, 11)}) % {len(vals)}]{' & 15' if self.chance(0.6) else ''};")
                ctx["indent"] -= 1
                e("}")
            else:
                e(f"{p}.* = undefined;")
                e(f"if ({self.bool_expr(ctx, 1)}) {p}.* = {small};")
            if self.chance(0.4):
                e(f"if ({idx()} < {arr}.len) {{")
                e(f"    {arr}[{idx()}] +%= 1;")
                e("}")
            sk(f"{arr}[{idx()}]")
            if self.chance(0.3):
                sk(f"{arr}[{idx()}..][0..1][0]")
            return
        # Slice lengths.
        n = self.fresh("fn")
        e(f"const {n}: usize = {pv()};")
        if k <= 9:
            buf = self.fresh("fbuf")
            e(f"var {buf}: [64]u32 = @splat({self.int_expr(ctx, U32, 1)});")
            off = self.r.randint(0, 8)
            l0 = self.r.randint(0, 64 - off)
            if self.chance(0.5):
                sv = self.fresh("fsl")
                e(f"var {sv}: []u32 = {buf}[{off}..][0..{l0}];")
                e(f"_ = &{sv};")
                sp = self.fresh("fsp")
                e(f"const {sp}: *[]u32 = &{sv};")
                sl, lenp, holder = f"{sp}.*", f"{sp}.len", None
            else:
                lv = self.fresh("fl")
                e(f"var {lv}: SfL = .{{ .items = {buf}[{off}..][0..{l0}], .cap = {64 - off}, .tag = 0 }};")
                e(f"_ = &{lv};")
                lp = self.fresh("flp")
                e(f"const {lp}: *SfL = &{lv};")
                sl, lenp, holder = f"{lp}.items", f"{lp}.items.len", lp
        else:
            buf = "gSfBuf"
            if self.chance(0.5):
                sl, lenp, holder = "gSfL.items", "gSfL.items.len", "&gSfL"
            else:
                gp = self.fresh("fgp")
                e(f"const {gp}: *[]u32 = &gSfL.items;")
                sl, lenp, holder = f"{gp}.*", f"{gp}.len", "&gSfL"
        if k == 9 or k == 11:
            # Append-style: grow by kk and fill the new tail.
            kk = self.fresh("fk")
            e(f"{lenp} = {n} & 31;")
            e(f"const {kk}: usize = {pv()} & 15;")
            if holder is not None and self.chance(0.6):
                g = self.fresh("fg")
                e(f"const {g} = {self.pick(['sfGrow', 'sfGrowN'])}({holder}, {kk});")
            else:
                g = self.fresh("fg")
                old = self.fresh("fo")
                e(f"const {old} = {lenp};")
                e(f"{lenp} = {old} + {kk};")
                e(f"const {g} = {sl}[{old}..][0..{kk}{' + 1' if self.chance(0.1) else ''}];")
            e(f"for ({g}, 0..) |*x, xi| x.* +%= @intCast(xi);")
            e(f"if ({kk} > 0) {{")
            ctx["indent"] += 1
            sk(f"{g}[{kk} - 1]")
            ctx["indent"] -= 1
            e("}")
            sk(f"@as(u32, @truncate({sl}.len))")
            return
        e(f"{lenp} = {n};")
        w = self.r.randrange(8)
        if w == 0:
            lnp = self.fresh("fln")
            e(f"const {lnp}: *usize = &{lenp};")
            e(f"{lnp}.* = {n} -| 1;")
        elif w == 1:
            if holder is None or self.chance(0.5):
                e(f"sfPutLen(&{sl}, {n} -| {self.r.randint(0, 2)});")
            else:
                e(f"sfSet({holder}, {n} -| 1);")
        elif w == 2:
            e(f"{sl} = {buf}[0..{pv()}];")
        elif w == 3 and k == 10:
            e(f"sfPutG({pv()});")
        elif w == 4:
            e(f"if ({self.bool_expr(ctx, 1)}) {lenp} = {n} -| 1;")
        # otherwise nothing in between
        u = self.r.randrange(4)
        if u == 0:
            e(f"if ({n} > 0) {{")
            ctx["indent"] += 1
            sk(f"{sl}[{n} - 1]")
            ctx["indent"] -= 1
            e("}")
        elif u == 1:
            sk(f"{sl}[{self.pick([n, n + ' -| 1', n + ' + 1', n + ' / 2'])}]")
        elif u == 2:
            a, kk = self.fresh("fa"), self.fresh("fk")
            e(f"const {a}: usize = {n} / {self.r.randint(1, 3)};")
            e(f"const {kk}: usize = {n} - {a}{self.pick(['', '', ' + 1', ' -| 1'])};")
            e(f"for ({sl}[{a}..][0..{kk}]) |x| {{")
            ctx["indent"] += 1
            sk("x")
            ctx["indent"] -= 1
            e("}")
        else:
            i = self.fresh("fi")
            e(f"for (0..{n}) |{i}| {sl}[{i}] +%= 1;")
            sk(f"@as(u32, @truncate({sl}.len))")

    def s_retlen(self, ctx):
        """Slices from noinline callees whose returned length is one argument
        (or nearly: another argument, an offset, n - 1, @min), through ?, E!,
        labeled blocks and if expressions, recursion, a global or pointer
        length, and allocators; then indexing at n - 1, n and n + 1, loops
        bounded by n or by another value, and n changed after the call."""
        if ctx["fn"].pure:
            return self.s_sroa(ctx)
        ctx["fn"].risky = True
        self.extra.add("retlen")
        e = lambda s_: self.emit(ctx, s_)
        sel, n, c = self.fresh("rs"), self.fresh("rn"), self.fresh("rc")
        vals = [0, 1, 3, 5, 17, 40, 59]
        e(f"var {sel} = [_]usize{{ {', '.join(map(str, vals))} }};")
        e(f"_ = &{sel};")
        e(f"var {n}: usize = {sel}[@as(usize, @truncate({self.int_expr(ctx, U64, 1)})) % {len(vals)}];")
        e(f"const {c}: u8 = @truncate({self.int_expr(ctx, U64, 1)});")
        e(f"_ = &{c};")
        s = self.fresh("rl")
        k = self.r.randrange(16)
        if k <= 1:
            e(f"const {s} = rlAll({c}, {n});")
        elif k == 2:
            e(f"const {s} = rlM({c}, {n}, {sel}[@as(usize, {c}) % {len(vals)}]);")
        elif k == 3:
            e(f"const {s} = rlOff({c}, {n} +| 1);")
        elif k == 4:
            e(f"const {s} = rlDec({c}, {n});")
        elif k == 5:
            e(f"const {s} = rlMin({c}, {n});")
        elif k == 6:
            e(f"const {s} = rlOpt({c}, {n}) orelse gRlBuf[0..{n}];")
        elif k == 7:
            e(f"const {s} = {self.pick(['rlBlk', 'rlIf'])}({c}, {n});")
        elif k == 8:
            if ctx["fn"].err and self.chance(0.5):
                e(f"const {s} = try {self.pick(['rlErr', 'rlErrM'])}({c}, {n});")
            else:
                e(f"const {s} = {self.pick(['rlErr', 'rlErrM'])}({c}, {n}) catch gRlBuf[0..{n}];")
        elif k == 9:
            e(f"const {s} = rlCt({self.r.randint(0, 4)}, {self.int_expr(ctx, U64, 1)}, {n});")
        elif k == 10:
            e(f"const {s} = rlLater({self.int_expr(ctx, USIZE, 1)}, {n}, {n});")
        elif k == 11:
            e(f"const {s} = rlGlob({c});")
            e(f"{n} = gRlN{' + 1' if self.chance(0.3) else ''};")
        elif k == 12:
            e(f"const {s} = {self.pick(['rlRec', 'rlMa', 'rlMb', 'rlRecM'])}({n}, {self.r.randint(0, 4)});")
        elif k == 13:
            e(f"const {s} = rlPtr({c}, &{n});")
        elif k == 14:
            al = self.pick(["std.heap.page_allocator", "arena"])
            if al == "arena":
                ar = self.fresh("ra")
                e(f"var {ar} = std.heap.ArenaAllocator.init(std.heap.page_allocator);")
                e(f"defer {ar}.deinit();")
                al = f"{ar}.allocator()"
            e(f"const {s} = {al}.alloc(u32, {n}) catch unreachable;")
            if al == "std.heap.page_allocator":
                e(f"defer std.heap.page_allocator.free({s});")
            e(f"@memset({s}, {self.r.randint(0, 99)});")
        else:
            e(f"const {s} = rlAll({c}, {n});")
            e(f"{n} {self.pick(['+= 1', '-|= 1', '= ' + n + ' *| 2'])};")
        e(f"_ = &{n};")
        self.sink(ctx, f"{s}.len", USIZE)
        j = self.r.randrange(4)
        if j == 0:
            i = self.fresh("ri")
            e(f"for (0..{n}) |{i}| {{")
            ctx["indent"] += 1
            self.sink(ctx, f"{s}[{i}]", U32)
            ctx["indent"] -= 1
            e("}")
        elif j == 1:
            off = self.pick(["-| 1", "", "+ 1"])
            e(f"if ({n} > 0) {{")
            ctx["indent"] += 1
            self.sink(ctx, f"{s}[{n} {off}]" if off else f"{s}[{n}]", U32)
            ctx["indent"] -= 1
            e("}")
        elif j == 2:
            # A loop bounded by a different value.
            i = self.fresh("ri")
            e(f"for (0..{self.pick(['@min(' + n + ', ' + s + '.len)', s + '.len', str(self.r.randint(0, 6))])}) |{i}| {{")
            ctx["indent"] += 1
            self.sink(ctx, f"{s}[{i}]", U32)
            ctx["indent"] -= 1
            e("}")
        else:
            i = self.fresh("ri")
            e(f"var {i}: usize = 0;")
            e(f"while ({i} < {n}) : ({i} += {self.r.randint(1, 3)}) {{")
            ctx["indent"] += 1
            self.sink(ctx, f"{s}[{i}]", U32)
            ctx["indent"] -= 1
            e("}")

    def s_mulbound(self, ctx):
        """Checked products of widened operands: proven when the operands'
        bounds multiply into the type (u32 x u32 in u64, u64 x u64 in u128),
        not when one bit more could overflow (u33 x u32, u127, u65); operands
        narrowed by masks, % and guards with near misses; products fed into
        indices and other products; signed and mixed operands; constants;
        @mulWithOverflow; the same product on two paths."""
        if ctx["fn"].pure:
            return self.s_sroa(ctx)
        ctx["fn"].risky = True
        e = lambda s_: self.emit(ctx, s_)
        U = lambda b: Int(False, b)
        I = lambda b: Int(True, b)
        # Operand values picked at run time from each width's interesting values.
        def operand(t, near_max=True):
            mx = (1 << (t.bits - 1)) - 1 if t.signed else (1 << t.bits) - 1
            mn = -(1 << (t.bits - 1)) if t.signed else 0
            vals = sorted(v for v in {0, 1, 2, 3, mx, mx - 1, mx >> 1, (mx >> 1) + 1, mn, mn + 1} if mn <= v <= mx)
            sel, v = self.fresh("mv"), self.fresh("mo")
            e(f"var {sel}: [{len(vals)}]{t.name()} = .{{ {', '.join(f'@as({t.name()}, {x})' for x in vals)} }};")
            e(f"_ = &{sel};")
            e(f"const {v}: {t.name()} = {sel}[@as(usize, @truncate({self.int_expr(ctx, U64, 1)})) % {len(vals)}];")
            return v
        k = self.r.randrange(9)
        r = self.fresh("mp")
        if k == 0:
            # Widened products: fits (a+b <= W) or one bit over.
            W = self.pick([64, 64, 128, 127, 96])
            ta, tb = self.pick([(32, 32), (33, 32), (16, 48), (31, 33), (32, 31), (48, 17), (64, 64), (65, 64), (64, 63), (63, 64),
                                (1, 64), (40, 24)])
            if ta + tb > W + 1:
                ta, tb = W // 2, W - W // 2 + self.r.randint(0, 1)
            a, b = operand(U(ta)), operand(U(tb))
            if self.chance(0.4):
                wa = self.fresh("mw")
                e(f"const {wa}: u{W} = {a};")
                e(f"const {r}: u{W} = {wa} * @as(u{W}, {b});")
            else:
                e(f"const {r}: u{W} = @as(u{W}, {a}) * @as(u{W}, {b});")
            self.sink(ctx, f"@as(u64, @truncate({r} ^ ({r} >> 32)))", U64)
        elif k == 1:
            # Narrowed by a mask, % or a guard; near misses one past.
            x, y = self.int_expr(ctx, U64, 1), self.int_expr(ctx, U64, 1)
            near = self.chance(0.35)
            a, b = self.fresh("ma"), self.fresh("mb")
            how = self.r.randrange(3)
            if how == 0:
                e(f"const {a}: u64 = {x} & 0x{'1ffff' if near else 'ffff'};")
                e(f"const {b}: u64 = ({y} & 0xffff_ffff_ffff) {'+ 0' if not near else '| 0x1_0000_0000_0000'};")
                e(f"const {r}: u64 = {a} * {b};")
            elif how == 1:
                e(f"const {a}: u64 = {x} % {1000 if not near else 1001};")
                e(f"const {b}: u64 = {y} % {(((1 << 64) - 1) // 1000) + (2 if near else 0)};")
                e(f"const {r}: u64 = {a} * {b};")
            else:
                e(f"const {a}: u64 = {x};")
                e(f"const {b}: u64 = {y} >> {44 if not near else 43};")
                e(f"var {r}: u64 = 7;")
                e(f"if ({a} < (1 << 20){' + 1' if near else ''}) {r} = {a} * {b};")
            self.sink(ctx, r, U64)
        elif k == 2:
            # A product as an index, and as an operand of another product.
            n = self.r.randint(2, 9)
            arr = self.fresh("mr")
            e(f"var {arr}: [{n * n}]u16 = @splat({self.int_expr(ctx, Int(False, 16), 1)});")
            e(f"{arr}[{self.r.randrange(n * n)}] ^= 5;")
            i, j = self.fresh("mi"), self.fresh("mj")
            near = self.chance(0.3)
            e(f"const {i}: usize = @as(usize, @truncate({self.int_expr(ctx, U64, 1)})) % {n + (1 if near else 0)};")
            e(f"const {j}: usize = @as(usize, @truncate({self.int_expr(ctx, U64, 1)})) % {n};")
            self.sink(ctx, f"{arr}[{i} * {n} + {j}]", Int(False, 16))
            a, b, c = operand(U(16)), operand(U(16)), operand(U(31 if not near else 32))
            e(f"const {r}: u64 = (@as(u64, {a}) * @as(u64, {b})) * @as(u64, {c});")
            self.sink(ctx, r, U64)
            self.sink(ctx, f"(@as(u32, {a}) *% @as(u32, {b})) +% {c}", U32)
        elif k == 3:
            # Signed and mixed: nothing to prove.
            a, b = operand(I(self.pick([32, 31, 16]))), operand(self.pick([I(32), U(31), U(32)]))
            e(f"const {r}: i64 = @as(i64, {a}) * @as(i64, {b});")
            self.sink(ctx, f"@as(u64, @bitCast({r}))", U64)
        elif k == 4:
            # Constant operands.
            a = operand(U(self.pick([32, 33, 64])))
            if self.chance(0.5):
                e(f"const {r}: u64 = @as(u64, @truncate({a})) * 0xffff_ffff;")
                self.sink(ctx, r, U64)
            else:
                w = self.pick([128, 128, 127])
                e(f"const {r}: u{w} = @as(u{w}, {a}) * std.math.maxInt(u64);")
                self.sink(ctx, f"@as(u64, @truncate({r} >> 1))", U64)
        elif k == 5:
            # @mulWithOverflow with the overflow bit used.
            t = self.pick([U(32), U(64), U(16), I(32)])
            a, b = operand(t), operand(t)
            e(f"const {r} = @mulWithOverflow({a}, {b});")
            e(f"if ({r}[1] == 0) {{")
            ctx["indent"] += 1
            self.sink(ctx, f"{r}[0]", t)
            self.sink(ctx, f"{a} * {b}", t)
            ctx["indent"] -= 1
            e("} else {")
            ctx["indent"] += 1
            self.sink(ctx, f"@as(u8, 0xee)", Int(False, 8))
            ctx["indent"] -= 1
            e("}")
        elif k == 6:
            # The same product in two switch cases and after.
            a, b = operand(U(33)), operand(U(32))
            e(f"switch (@as(u2, @truncate({self.int_expr(ctx, U64, 1)}))) {{")
            ctx["indent"] += 1
            e(f"0 => {{ const {r}: u64 = @as(u64, @as(u32, @truncate({a}))) * @as(u64, {b}); mix({r}); }},")
            e(f"1 => {{ const {r}: u64 = @as(u64, {a}) * @as(u64, {b}); mix({r}); }},")
            e("else => {},")
            ctx["indent"] -= 1
            e("}")
            self.sink(ctx, f"@as(u64, {a}) * @as(u64, {b})", U64)
        elif k == 7:
            # *% with an exact range, then used in a bound.
            n = self.r.randint(4, 60)
            arr = self.fresh("mr")
            e(f"var {arr}: [{n}]u8 = @splat(3);")
            e(f"{arr}[{n - 1}] = 9;")
            a = self.fresh("ma")
            near = self.chance(0.3)
            e(f"const {a}: u32 = @as(u32, @truncate({self.int_expr(ctx, U64, 1)})) % {max(1, int((n - 1) ** 0.5)) + (1 if near else 0)};")
            e(f"const {r}: u32 = {a} *% {a};")
            self.sink(ctx, f"{arr}[{r}]", Int(False, 8))
        else:
            # A checked product whose check passed bounds a later index.
            a = operand(U(8))
            arr = self.fresh("mq")
            e(f"var {arr}: [256]u8 = @splat(1);")
            e(f"_ = &{arr};")
            e(f"const {r}: u8 = {a} * 2;")
            self.sink(ctx, f"{arr}[{r}]", Int(False, 8))
            self.sink(ctx, f"{arr}[@as(usize, {r}) + 1]", Int(False, 8))

    def s_argbase(self, ctx):
        """By-value aggregates of 7 to 16 bytes read through an optional
        pointer parameter that stays live past sret calls taking them."""
        if ctx["fn"].pure:
            return self.s_sroa(ctx)
        self.extra.add("argbase")
        e = lambda s_: self.emit(ctx, s_)
        u64 = lambda: self.int_expr(ctx, U64, 1)
        if self.chance(0.2):
            p, w = self.fresh("ap"), self.fresh("aw")
            e(f"const {p}: ABcp = .{{ .a = @bitCast({u64()}), .b = -3 }};")
            e(f"const {w}: ABcw = .{{ .a = {u64()}, .b = 77 }};")
            pa = "null" if self.chance(0.15) else f"&{p}"
            if pa == "null":
                e(f"_ = {p};")
            if self.chance(0.5):
                self.sink(ctx, f"abCrun({u64()}, {pa}, &{w})", U64)
            else:
                rr = self.fresh("abr")
                e(f"const {rr} = abCrunR({u64()}, {pa}, &{w});")
                self.sink(ctx, f"(if ({rr}) |q| q.a ^ q.b ^ q.c else 99)", U64)
            return
        nm = self.pick(list(AB_TYPES))
        ty, _, mk = AB_TYPES[nm]
        v = self.fresh("ab")
        if mk is None:
            sl = self.fresh("abs")
            n = self.r.randint(0, 4)
            e(f"const {sl} = [_]u64{{ {', '.join(u64() for _ in range(n))} }};")
            e(f"const {v}: AB{nm} = .{{ .data = .{{ .s = &{sl} }} }};")
        else:
            x = self.fresh("abx")
            e(f"const {x}: u64 = {u64()};")
            e(f"const {v}: AB{nm} = .{{ .data = {mk.format(x=x)} }};")
        ptr = "null" if self.chance(0.1) else f"&{v}"
        if ptr == "null":
            e(f"_ = {v};")
        k = self.r.randrange(6)
        if k < 3:
            call = [f"AB{nm}.run0({ptr}, {u64()})", f"AB{nm}.run1({u64()}, {ptr})", f"AB{nm}.run2({u64()}, {u64()}, {ptr})"][k]
            self.sink(ctx, call, U64)
            return
        rr = self.fresh("abr")
        if k == 3:
            e(f"const {rr} = AB{nm}.runS({ptr}, {u64()});")
        elif k == 4:
            e(f"const {rr} = AB{nm}.runR({u64()}, {ptr}, {u64()});")
        else:
            e(f"const {rr}: ?ABb = AB{nm}.runQ({u64()}, {u64()}, {ptr});")
        self.sink(ctx, f"(if ({rr}) |q| q.a ^ (q.b *% 3) ^ q.c else 99)", U64)

    def s_scopenum(self, ctx):
        """The same checked expression (a + K, s.len - i, i * i) computed on
        one path only (an if side, a switch case, a loop body left by a
        break inside an if, a labeled block with one break) and computed
        again elsewhere, then a bounds check that depends on it. Operands
        near the type's end make the recomputation overflow on paths where
        the first one never ran."""
        if ctx["fn"].pure:
            return self.s_sroa(ctx)
        ctx["fn"].risky = True
        e = lambda s_: self.emit(ctx, s_)
        kind = self.r.randrange(3)
        x = self.fresh("nx")
        sel = self.fresh("nv")
        if kind == 0:
            t = self.pick([Int(False, 8), Int(True, 8), Int(False, 16), USIZE, Int(False, 5)])
            K = self.r.randint(1, 6)
            mx = (1 << (t.bits - 1)) - 1 if t.signed else (1 << t.bits) - 1
            cands = [0, 1, mx - K - 1, mx - K, mx - K + 1, mx]
            if t.signed:
                cands.append(-(1 << (t.bits - 1)))
            expr = lambda: f"{x} + {K}"
            # ar[t - x] is in bounds exactly when t == x + K.
            arlen = K + 1
            idx = lambda tv: f"@as(usize, @intCast({tv} - {x}))"
            ty = t.name()
        elif kind == 1:
            t = USIZE
            n = self.r.randint(1, 6)
            sl = self.fresh("ns")
            arr = self.fresh("na")
            e(f"var {arr}: [{n}]u16 = @splat({self.int_expr(ctx, Int(False, 16), 1)});")
            e(f"const {sl}: []u16 = {arr}[{self.r.randint(0, n - 1)}..];")
            cands = [0, 1, n - 1, n, n + 1, n + 7]
            expr = lambda: f"{sl}.len - {x}"
            arlen = None
            idx = lambda tv: f"{tv} -| 1"
            ty = "usize"
        else:
            t = Int(False, 8)
            cands = [0, 3, 14, 15, 16, 17, 255]
            expr = lambda: f"{x} * {x}"
            arlen = 226
            idx = lambda tv: f"@min(@as(usize, {tv}), 225)"
            ty = "u8"
        cands = sorted(set(cands))
        lit = lambda v: f"@as({ty}, {v})"
        e(f"var {sel}: [{len(cands)}]{ty} = .{{ {', '.join(lit(c) for c in cands)} }};")
        e(f"_ = &{sel};")
        e(f"const {x}: {ty} = {sel}[@as(usize, @truncate({self.int_expr(ctx, U64, 1)})) % {len(cands)}];")
        ar = self.fresh("nr")
        if kind == 1:
            ar_use = lambda tv: f"{sl}[{idx(tv)} % {sl}.len]" if False else f"{arr}[@min({idx(tv)}, {n - 1})]"
            ar_t = Int(False, 16)
        else:
            e(f"var {ar}: [{arlen}]u8 = @splat({self.int_expr(ctx, Int(False, 8), 1)});")
            e(f"{ar}[{arlen - 1}] +%= 1;")
            ar_use = lambda tv: f"{ar}[{idx(tv)}]"
            ar_t = Int(False, 8)
        to64 = (lambda v: f"@as(u64, @bitCast(@as(i64, {v})))") if (ty.startswith("i")) else (lambda v: f"@as(u64, {v})")

        def first():
            t1 = self.fresh("n1")
            e(f"const {t1} = {expr()};")
            self.sink(ctx, to64(t1), U64)

        def again():
            t2 = self.fresh("n2")
            e(f"const {t2} = {expr()};")
            self.sink(ctx, ar_use(t2), ar_t)

        def block(fn):
            ctx["indent"] += 1
            fn()
            ctx["indent"] -= 1

        place = self.r.randrange(6)
        c = lambda: self.bool_expr(ctx, 1)
        if place == 0:  # one side of an if, then after
            e(f"if ({c()}) {{")
            block(first)
            e("} else {")
            block(lambda: self.sink(ctx, f"@as(u8, {self.r.randint(0, 9)})", Int(False, 8)))
            e("}")
            again()
        elif place == 1:  # one side, then the other side
            e(f"if ({c()}) {{")
            block(first)
            e("} else {")
            block(again)
            e("}")
        elif place == 2:  # a switch case, the next case, and after
            sv = f"@as(u2, @truncate({self.int_expr(ctx, U64, 1)}))"
            e(f"switch ({sv}) {{")
            ctx["indent"] += 1
            e("0 => {")
            block(first)
            e("},")
            e("1 => {")
            block(again)
            e("},")
            e("else => {},")
            ctx["indent"] -= 1
            e("}")
            if self.chance(0.6):
                again()
        elif place == 3:  # a loop left by a break inside an if
            i = self.fresh("ni")
            e(f"var {i}: u32 = 0;")
            e(f"while ({i} < {self.r.randint(1, 4)}) : ({i} += 1) {{")
            ctx["indent"] += 1
            e(f"if ({c()} or {i} == {self.r.randint(0, 3)}) {{")
            block(first)
            ctx["indent"] += 1
            e("break;")
            ctx["indent"] -= 1
            e("}")
            ctx["indent"] -= 1
            e("}")
            again()
        elif place == 4:  # a labeled block with one break; the first is under an if
            b = self.fresh("nb")
            e(f"{b}: {{")
            ctx["indent"] += 1
            e(f"if ({c()}) {{")
            block(first)
            e("}")
            e(f"break :{b};")
            ctx["indent"] -= 1
            e("}")
            again()
        else:  # a labeled block with one break; the first runs on every path to it
            b = self.fresh("nb")
            e(f"{b}: {{")
            block(first)
            ctx["indent"] += 1
            e(f"break :{b};")
            ctx["indent"] -= 1
            e("}")
            again()

    def _sw_int(self):
        """An integer type for a switch operand: u8..u64, i8..i64, odd
        widths, and wider than 64 bits."""
        return self.pick([Int(False, 8), Int(False, 16), Int(False, 32), U64, Int(True, 8), Int(True, 16), Int(True, 32),
                          Int(True, 64), Int(False, 3), Int(True, 5), Int(False, 65), Int(False, 128), Int(True, 100),
                          Int(False, 12), Int(True, 33)])

    def s_swx(self, ctx):
        """Switches as jump tables, binary searches and compares: dense,
        sparse and mixed items, range prongs (signed, at the type ends,
        wide), enums with negative and non-exhaustive tags, labeled switch
        continues, and and/or/! conditions guarding slice indexing."""
        if ctx["fn"].pure:
            return self.s_sroa(ctx)
        self.extra.add("swx")
        k = self.r.randrange(5)
        if k <= 1:
            self._sw_items(ctx)
        elif k == 2:
            self._sw_enum(ctx)
        elif k == 3:
            self._sw_labeled(ctx)
        else:
            self._sw_cond(ctx)
        self.sink(ctx, "gSwCnt", U64)

    def _sw_items(self, ctx):
        e = lambda s_: self.emit(ctx, s_)
        t = self._sw_int()
        sg, b = t.signed, t.bits
        lo, hi = (-(1 << (b - 1)), (1 << (b - 1)) - 1) if sg else (0, (1 << b) - 1)
        lit = lambda v: f"@as({t.name()}, {v})"
        shape = self.r.randrange(3)
        n = self.r.randint(2, 14)
        vals = set()
        if shape == 0:  # dense from a base (maybe at a type end)
            base = self.pick([lo, max(lo, hi - n), 0 if lo <= 0 else lo, self.r.randint(lo, max(lo, hi - n))])
            vals = {v for v in range(base, base + n) if lo <= v <= hi}
        else:
            for _ in range(n):
                vals.add(self.pick([lo, lo + 1, hi, hi - 1, 0 if lo <= 0 <= hi else lo, self.r.randint(lo, hi),
                                    self.r.randint(max(lo, -40), min(hi, 40))]))
            if shape == 2:  # mixed: a dense run plus sparse
                base = self.r.randint(max(lo, -20), max(lo, min(hi - 8, 20)))
                vals |= {v for v in range(base, base + 6) if lo <= v <= hi}
        vals = sorted(vals)
        # Range prongs over gaps, disjoint from the items.
        ranges = []
        used = set(vals)
        for _ in range(self.r.randint(0, 3)):
            a = self.pick([lo, self.r.randint(lo, hi), max(lo, hi - self.r.randint(0, 1000))])
            w = self.pick([1, 3, 50, (hi - lo) // 4])
            z = min(hi, a + w)
            if any(a <= v <= z for v in used) or any(not (z < r0 or a > r1) for r0, r1 in ranges):
                continue
            ranges.append((a, z))
        full = len(vals) == (hi - lo + 1)
        prongs = []
        groups = list(vals)
        self.r.shuffle(groups)
        i = 0
        while i < len(groups):
            g = groups[i:i + self.r.choice([1, 1, 1, 2, 3])]
            i += len(g)
            prongs.append(("items", g))
        for r0, r1 in ranges:
            prongs.append(("range", (r0, r1)))
        self.r.shuffle(prongs)
        # A runtime selector over interesting values: items, range ends +-1, type ends.
        cands = set(vals) | {lo, hi} | {x for r0, r1 in ranges for x in (r0 - 1, r0, r1, r1 + 1)}
        cands = sorted(c for c in cands if lo <= c <= hi)
        sel = self.fresh("sw")
        e(f"var {sel}: [{len(cands)}]{t.name()} = .{{ {', '.join(lit(c) for c in cands)} }};")
        e(f"{sel}[{self.r.randrange(len(cands))}] {'+%' if self.chance(0.5) else '-%'}= {lit(self.r.randint(0, 1))};")
        idx = f"@as(usize, @truncate({self.int_expr(ctx, U64, 1)})) % {len(cands)}"
        v = self.fresh("sv")
        e(f"const {v}: {t.name()} = {sel}[{idx}];")
        r = self.fresh("sr")
        e(f"const {r}: u64 = switch ({v}) {{")
        ctx["indent"] += 1
        for kind, pv in prongs:
            body = self.pick([f"{self.r.randint(0, 999)}", "|c| " + self.to_u64("c", t) + f" +% {self.r.randint(1, 9)}"])
            cap = ""
            if body.startswith("|c| "):
                cap, body = "|c| ", body[4:]
            if kind == "items":
                e(f"{', '.join(lit(x) for x in pv)} => {cap}{body},")
            else:
                e(f"{lit(pv[0])}...{lit(pv[1])} => {cap}{body},")
        if not full:
            e(f"else => {self.pick(['77', '|c| ' + self.to_u64('c', t) + ' ^ 0x55'])},")
        ctx["indent"] -= 1
        e("};")
        self.sink(ctx, r, U64)

    def _sw_enum(self, ctx):
        e = lambda s_: self.emit(ctx, s_)
        k = self.r.randrange(3)
        r = self.fresh("sr")
        if k == 0:
            # Non-exhaustive with negative tags: any i8 is a valid value.
            v = self.fresh("se")
            e(f"const {v}: SwN = @enumFromInt(@as(i8, @truncate(@as(i64, @bitCast({self.int_expr(ctx, U64, 1)})))));")
            items = self.r.sample(["lo", "m1", "z", "f", "hi"], self.r.randint(1, 5))
            e(f"const {r}: u64 = switch ({v}) {{")
            ctx["indent"] += 1
            for it in items:
                e(f".{it} => {self.r.randint(0, 99)},")
            if len(items) == 5 and self.chance(0.5):
                e(f"_ => |c| @as(u64, @as(u8, @bitCast(@intFromEnum(c)))),")
            else:
                e(f"else => |c| @as(u64, @as(u8, @bitCast(@intFromEnum(c)))) +% 1000,")
            ctx["indent"] -= 1
            e("};")
        elif k == 1:
            sel = self.fresh("sw")
            e(f"var {sel} = [_]SwX{{ .a, .b, .c, .d, .{self.pick(['a', 'b', 'c', 'd'])} }};")
            e(f"_ = &{sel};")
            e(f"const {r}: u64 = switch ({sel}[@as(usize, @truncate({self.int_expr(ctx, U64, 1)})) % 5]) {{")
            ctx["indent"] += 1
            e(f".a, .d => {self.r.randint(0, 99)},")
            if self.chance(0.5):
                e(f".b => |c| @as(u64, @as(u16, @bitCast(@intFromEnum(c)))),")
                e(f".c => {self.r.randint(0, 99)},")
            else:
                e("else => |c| @as(u64, @as(u16, @bitCast(@intFromEnum(c)))) ^ 3,")
            ctx["indent"] -= 1
            e("};")
        else:
            v = self.fresh("se")
            e(f"const {v}: SwU = @enumFromInt(@as(u3, @truncate({self.int_expr(ctx, U64, 1)})));")
            tags = ["a", "b", "c", "d", "e", "f", "g", "h"]
            self.r.shuffle(tags)
            cut = self.r.randint(1, 7)
            e(f"const {r}: u64 = switch ({v}) {{")
            ctx["indent"] += 1
            e(f"{', '.join('.' + x for x in tags[:cut])} => |c| @as(u64, @intFromEnum(c)) *% 3,")
            e(f"{', '.join('.' + x for x in tags[cut:])} => {self.r.randint(0, 99)},")
            ctx["indent"] -= 1
            e("};")
        self.sink(ctx, r, U64)

    def _sw_labeled(self, ctx):
        """`continue :s <const>` into items, ranges and else, with and
        without captures, and bounded runtime continues."""
        e = lambda s_: self.emit(ctx, s_)
        t = self.pick([Int(False, 8), Int(True, 8), Int(False, 32), Int(True, 16), U64, Int(False, 3)])
        sg, b = t.signed, t.bits
        lo, hi = (-(1 << (b - 1)), (1 << (b - 1)) - 1) if sg else (0, (1 << b) - 1)
        lit = lambda v: f"@as({t.name()}, {v})"
        # States: items 0..5 (clamped into range), a range prong, else.
        st = sorted({max(lo, min(hi, v)) for v in [0, 1, 2, 3, 5, hi]})
        rlo, rhi = (max(lo, 10), min(hi, 20)) if hi >= 20 else (None, None)
        acc, cnt, lab = self.fresh("la"), self.fresh("lc"), self.fresh("ls")
        e(f"var {acc}: u64 = {self.int_expr(ctx, U64, 1)};")
        e(f"var {cnt}: u32 = 0;")
        start = self.pick(st + ([rlo] if rlo is not None else []) + ([lo] if lo not in st else []))
        startx = lit(start) if self.chance(0.5) else f"{lit(start)} +% @as({t.name()}, @intFromBool({self.bool_expr(ctx, 1)}))"
        e(f"{lab}: switch ({startx}) {{")
        ctx["indent"] += 1
        targets = st + ([rlo, rhi] if rlo is not None else []) + [hi]
        later = lambda x: [y for y in st if y > x]
        for x in st:
            nxt = later(x)
            if x == st[-1] or not nxt:
                e(f"{lit(x)} => break :{lab},")
                continue
            cap = self.chance(0.4)
            e(f"{lit(x)} => {'|c| ' if cap else ''}{{")
            ctx["indent"] += 1
            e(f"{acc} = ({acc} ^ {('@as(u64, @bitCast(@as(i64, c)))' if sg else '@as(u64, c)') if cap else str(x)}) *% 0x9E3779B97F4A7C15;")
            j = self.r.randrange(4)
            if j == 0:
                e(f"continue :{lab} {lit(self.pick(nxt))};")
            elif j == 1 and rlo is not None:
                e(f"continue :{lab} {lit(self.r.randint(rlo, rhi))};")
            elif j == 2:
                # Into else (a value no prong names).
                ev = next((y for y in range(lo, hi + 1) if y not in targets and not (rlo is not None and rlo <= y <= rhi)), None)
                e(f"continue :{lab} {lit(ev) if ev is not None else lit(self.pick(nxt))};")
            else:
                # Runtime continue, bounded by the counter.
                e(f"{cnt} += 1;")
                e(f"if ({cnt} < 4 and {self.bool_expr(ctx, 1)}) continue :{lab} {lit(self.pick(nxt))};")
                e(f"continue :{lab} {lit(st[-1])};")
            ctx["indent"] -= 1
            e("},")
        if rlo is not None:
            e(f"{lit(rlo)}...{lit(rhi)} => |c| {{")
            ctx["indent"] += 1
            e(f"{acc} +%= {'@as(u64, @bitCast(@as(i64, c)))' if sg else '@as(u64, c)'};")
            e(f"continue :{lab} {lit(st[-1])};")
            ctx["indent"] -= 1
            e("},")
        if len(st) + (rhi - rlo + 1 if rlo is not None else 0) < hi - lo + 1:
            e("else => |c| {")
            ctx["indent"] += 1
            e(f"{acc} ^= {'@as(u64, @bitCast(@as(i64, c)))' if sg else '@as(u64, c)'};")
            e(f"{cnt} += 1;")
            e(f"if ({cnt} < 6) continue :{lab} {lit(st[0])};")
            e(f"break :{lab};")
            ctx["indent"] -= 1
            e("},")
        ctx["indent"] -= 1
        e("}")
        self.sink(ctx, acc, U64)
        self.sink(ctx, cnt, U32)

    def _sw_cond(self, ctx):
        """and/or/! as values and as branches, with side effects on the
        right, guarding slice indexing; near misses keep the bounds check."""
        e = lambda s_: self.emit(ctx, s_)
        n = self.r.randint(1, 6)
        a = self.fresh("ca")
        e(f"var {a}: [{n}]u8 = @splat({self.int_expr(ctx, Int(False, 8), 1)});")
        e(f"{a}[{self.r.randrange(n)}] +%= 1;")
        sl = self.fresh("cs")
        e(f"const {sl}: []u8 = {a}[{self.r.randint(0, n - 1)}..];")
        i = self.fresh("ci")
        e(f"const {i}: usize = @as(usize, @truncate({self.int_expr(ctx, U64, 1)})) % {n + 2};")
        near = self.chance(0.3)
        side = lambda: f"swSide({self.int_expr(ctx, U64, 1)})"
        guard = self.pick([f"{i} < {sl}.len", f"!({i} >= {sl}.len)", f"{sl}.len > {i}"])
        if near:
            guard = self.pick([f"{i} <= {sl}.len", f"!({i} > {sl}.len)"])
        use = f"{sl}[{i}] {self.pick(['>', '==', '!=', '<'])} {self.r.randint(0, 255)}"
        k = self.r.randrange(5)
        c = self.fresh("cc")
        if k == 0:
            e(f"const {c} = ({guard} and {use}) or {side()};")
            self.sink(ctx, f"@as(u8, @intFromBool({c}))", Int(False, 8))
        elif k == 1:
            e(f"if ({guard} and ({use} or {side()})) {{")
            ctx["indent"] += 1
            self.sink(ctx, f"{sl}[{i}]", Int(False, 8))
            ctx["indent"] -= 1
            e("}")
        elif k == 2:
            e(f"if (!({guard}) or {side()}) {{")
            ctx["indent"] += 1
            self.sink(ctx, f"@as(u8, {self.r.randint(0, 9)})", Int(False, 8))
            ctx["indent"] -= 1
            e("} else {")
            ctx["indent"] += 1
            self.sink(ctx, f"{sl}[{i}]", Int(False, 8))
            ctx["indent"] -= 1
            e("}")
        elif k == 3:
            e(f"const {c} = !({side()} and !({guard}));")
            e(f"if ({c} and {guard}) {{")
            ctx["indent"] += 1
            self.sink(ctx, f"{sl}[{i}]", Int(False, 8))
            ctx["indent"] -= 1
            e("}")
        else:
            j = self.fresh("cj")
            e(f"_ = {i};")
            e(f"var {j}: usize = 0;")
            e(f"while ({j} < {n + 1} and ({j} < {sl}.len{' + 1' if near else ''} or {side()})) : ({j} += 1) {{")
            ctx["indent"] += 1
            e(f"if ({j} < {sl}.len{' + 1' if near else ''}) {sl}[{j}] +%= 1;")
            ctx["indent"] -= 1
            e("}")
            self.sink(ctx, j, USIZE)

    def s_rvoglob(self, ctx):
        """Aggregates over 16 bytes returned early straight from a global;
        the global changes afterwards, so the result must be a copy."""
        if ctx["fn"].pure:
            return self.s_sroa(ctx)
        self.extra.add("rvo")
        e = lambda s_: self.emit(ctx, s_)
        k = f"@as(u8, @truncate({self.int_expr(ctx, U64, 1)}))"
        v = self.fresh("rr")
        f = self.r.randrange(4)
        if f == 0:
            e(f"const {v} = rq0({k});")
            el = lambda i: f"{v}[{i}]"
        elif f == 1:
            e(f"const {v} = rq1({k});")
            el = lambda i: f"@as(u64, @bitCast({v}[{i}]))"
        elif f == 2:
            e(f"const {v} = rq2({k});")
            el = lambda i: self.pick([f"{v}.f[{i}]", f"@as(u64, @bitCast({v}.d[{i}]))", f"@as(u64, {v}.pad)"])
        else:
            e(f"const {v} = rq3({k}, {self.bool_expr(ctx, 1)});")
            el = lambda i: f"{v}[{i}]"
        if self.chance(0.6):
            e(self.pick([f"gQ4[{self.r.randint(0, 3)}] +%= 1;", f"gQS.f[{self.r.randint(0, 3)}] ^= 0xff;",
                         f"gQD[{self.r.randint(0, 3)}] += 1.0;", f"gQS.d[{self.r.randint(0, 3)}] *= 2.0;"]))
        for i in self.r.sample(range(4), self.r.randint(1, 4)):
            self.sink(ctx, el(i), U64)

    def s_boolret(self, ctx):
        """A short-circuit bool kept across a call returning an optional,
        then returned after a conditional early return."""
        if ctx["fn"].pure:
            return self.s_sroa(ctx)
        self.extra.add("boolret")
        a = f"@as(u32, @truncate({self.int_expr(ctx, U64, 1)}))"
        b = f"@as(u32, @truncate({self.int_expr(ctx, U64, 1)} % 9))"
        st = f"qstr[{self.r.randint(0, 4)}]"
        fn = self.pick(["bq0", "bq1", "bq2"])
        if fn == "bq2":
            self.sink(ctx, f"bq2({a}, {b}, {st})", Int(False, 8))
        else:
            self.sink(ctx, f"@as(u8, @intFromBool({fn}({a}, {b}, {st})))", Int(False, 8))

    def s_asmpin(self, ctx):
        """Inline asm with register-pinned operands named in the template."""
        if ctx["fn"].pure:
            return self.s_sroa(ctx)
        self.extra.add("asmpin")
        k = self.r.randrange(3)
        if k == 0:
            self.sink(ctx, f"asmCall(&{self.pick(['asmTarget', 'asmTarget2'])})", U64)
        elif k == 1:
            self.sink(ctx, f"asmAdd({self.int_expr(ctx, U64, 1)}, {self.int_expr(ctx, U64, 1)})", U64)
        else:
            self.sink(ctx, f"asmXchg({self.int_expr(ctx, U64, 1)}, {self.int_expr(ctx, U64, 1)})", U64)

    def s_xcall(self, ctx):
        """A chain of calls through extern and @extern function pointers on
        one variable: x = callee(x), the callee computed just before."""
        if ctx["fn"].pure:
            return self.s_sroa(ctx)
        self.extra.add("xcall")
        e = lambda s_: self.emit(ctx, s_)
        x = self.fresh("xc")
        e(f"var {x}: u64 = {self.pick(['0', self.int_expr(ctx, U64, 1)])};")
        e(f"{x} = xf({x});")
        for _ in range(self.r.randint(1, 5)):
            k = self.r.randrange(5)
            if k == 0:
                e(f"{x} = @extern(*const fn (u64) callconv(.c) u64, .{{ .name = \"mchExp1\" }})({x});")
            elif k == 1:
                cp = self.fresh("xp")
                e(f"const {cp} = @extern(*const fn (u64) callconv(.c) u64, .{{ .name = \"{self.pick(['mchExp1', 'mchExp2'])}\" }});")
                e(f"{x} = {cp}({x});")
            elif k == 2:
                e(f"{x} = mchExp2({x});")
            elif k == 3:
                e(f"{x} = @extern(*const fn (u64, u64) callconv(.c) u64, .{{ .name = \"mchExp3\" }})({x}, {x} >> 3);")
            else:
                e(f"{x} = mchExp1(xf({x}));")
        self.sink(ctx, x, U64)

    def s_bigcopy(self, ctx):
        """Whole copies of a 64-256 byte struct: into locals, globals and
        through pointers, by value into callees that write the source, and
        returned into the location they read."""
        hs, fns = self.huge, self.huge_fns
        lv = self.leaves("X", hs)
        h = self.fresh("hh")
        e = lambda s_: self.emit(ctx, s_)
        if ctx["fn"].pure:
            e(f"var {h}: SH = {self.global_init(hs)};")
        else:
            e(f"var {h}: SH = gH;")
        for _ in range(self.r.randint(1, 3)):
            x, t = self.pick(lv)
            e(f"{h}{x[1:]} {self.pick(['+%=', '^=', '='])} {self.int_expr(ctx, t, 1)};")
        # The helpers call mix(), so a pure (comptime-callable) function
        # only copies.
        k = 1.0 if ctx["fn"].pure else self.r.random()
        if k < 0.25:
            if self.chance(0.5):
                e(f"gH = {h};")
            else:
                p = self.fresh("hp")
                e(f"const {p}: *SH = &gH;")
                e(f"{p}.* = {h};")
        elif k < 0.45 and "bv" in fns:
            self.sink(ctx, f"{fns['bv']}({self.pick(['gH', h])})", U64)
        elif k < 0.65 and "ru" in fns:
            tgt = self.pick([h, "gH"])
            e(f"{tgt} = {fns['ru']}({tgt});")
        elif k < 0.8 and "bp" in fns:
            tgt = self.pick([h, h, "gH"])
            self.sink(ctx, f"{fns['bp']}(&{tgt}, {tgt})", U64)
        else:
            a = self.fresh("ha")
            e(f"var {a}: [2]SH = .{{ {h}, {h} }};")
            x, t = self.pick(lv)
            e(f"{a}[0]{x[1:]} ^= {self.int_expr(ctx, t, 1)};")
            e(f"{a}[1] = {a}[0];")
            for x, t in self.r.sample(lv, min(3, len(lv))):
                self.sink(ctx, f"{a}[1]{x[1:]}", t)
        for x, t in self.r.sample(lv, min(4, len(lv))):
            self.sink(ctx, f"{h}{x[1:]}", t)

    def s_window(self, ctx):
        """Loops over windows `sl[i..][0..N]` of a runtime slice, with the
        guard in the loop condition, before the loop, or on a shrinking
        bound; indices stepping by more than 1, wrapping near the type's
        maximum, or starting past the end. Each has a near miss whose
        check must stay (what prove's offset and loop-start facts decide)."""
        t = self.rand_int_type()
        a, b = self.rt_int(ctx, Int(False, 8)), self.rt_int(ctx, Int(False, 8))
        if a is None or b is None:
            return self.s_prove(ctx)
        ctx["fn"].risky = True
        ra, rb = self.conv(a, Int(False, 8), USIZE), self.conv(b, Int(False, 8), USIZE)
        L = self.r.randint(4, 16)
        arr, sl, i = self.fresh("wa"), self.fresh("ws"), self.fresh("wi")
        n = self.r.randint(1, 4)
        r = self.r.randrange(n)
        step = self.pick([1, 1, 2, 3, n])
        near = self.chance(0.35)
        tn = t.name()
        e = lambda x: self.emit(ctx, x)
        e(f"var {arr}: [{L}]{tn} = @splat({self.int_expr(ctx, t, 1)});")
        e(f"{arr}[{self.r.randrange(L)}] = {self.int_expr(ctx, t, 1)};")
        e(f"const {sl}: []const {tn} = {arr}[{ra} % {L // 2}..{L} - {rb} % {L // 2}];")

        def body(x):
            ctx["indent"] += 1
            self.sink(ctx, x, t)
            ctx["indent"] -= 1

        k = self.r.randrange(5)
        if k == 0:
            # The guard is the loop condition.
            e(f"var {i}: usize = {ra} % 3;")
            cond = f"{i} < {sl}.len" if near else f"{i} + {n} <= {sl}.len"
            e(f"while ({cond}) : ({i} += {step}) {{")
            body(f"{sl}[{i}..][0..{n}][{r}]")
            e("}")
        elif k == 1:
            # One guard before the loop covers every window.
            m = self.r.randint(1, 3)
            e(f"if ({sl}.len >= {n * m - 1 if near else n * m}) {{")
            ctx["indent"] += 1
            e(f"for (0..{m}) |{i}| {{")
            body(f"{sl}[{i} * {n} ..][0..{n}][{r}]")
            e("}")
            ctx["indent"] -= 1
            e("}")
        elif k == 2:
            # A shrinking bound.
            e(f"var {i}: usize = {sl}.len;")
            e(f"while ({i} {'> 0' if near else f'>= {n}'}) : ({i} -= @min({step}, {i})) {{")
            body(f"{sl}[{i} - {n} ..][0..{n}][{r}]")
            e("}")
        elif k == 3:
            # Wrapping +% near the maximum: i +% N <= len says nothing.
            it = self.fresh("wt")
            e(f"var {i}: usize = {self.bare((1 << 64) - 1)} - ({ra} & 7);")
            e(f"var {it}: u8 = 0;")
            e(f"while ({it} < 12) : ({{ {i} +%= {step}; {it} += 1; }}) {{")
            ctx["indent"] += 1
            g = f"{i} +% {n} <= {sl}.len" if near else f"{i} <= {sl}.len and {sl}.len - {i} >= {n}"
            e(f"if ({g}) {{")
            # Upstream (0.17.1, Debug and LLVM) checks sl[i..][0..n] with a
            # wrapping i + n, so the near miss indexes one element instead.
            body(f"{sl}[{i}]" if near else f"{sl}[{i}..][0..{n}][{r}]")
            e("}")
            ctx["indent"] -= 1
            e("}")
        else:
            # A runtime start, possibly past the end; the body may move it.
            end = self.fresh("we")
            e(f"const {end}: usize = @min({sl}.len{' + 1' if near and self.chance(0.5) else ''}, {rb} % {L + 2});")
            e(f"var {i}: usize = {ra} % {L + 2};")
            e(f"while ({i} < {end}) : ({i} += {step}) {{")
            body(f"{sl}[{i}]")
            if near and self.chance(0.5):
                ctx["indent"] += 1
                e(f"if (({i} & 1) == 0) {i} += 1;")
                ctx["indent"] -= 1
                body(f"{sl}[{i}]")
            e("}")

    def prove_more(self, ctx, k, t, v, near, body, I):
        """More of s_prove: checked adds in compares, blocks left by a
        break to an outer block, values merged into one const, undefined
        then stored, and casts that change width or sign."""
        n = t.name()
        arr = self.fresh("pa")
        ln = self.r.randint(1, 8)
        self.emit(ctx, f"const {arr}: [{ln}]{n} = @splat({v});")
        x = self.conv(v, t, USIZE)
        j = self.fresh("pj")
        e = lambda s_: self.emit(ctx, s_)
        if k == 16:
            # An overflow-checked add in the compare (the add's own check stays).
            c = self.r.randint(1, 3)
            e(f"const {j}: usize = {x};")
            if self.chance(0.5):
                e(f"if ({j} + {c} {'<=' if near else '<'} {arr}.len) {{")
                body(f"{arr}[{j} + {c}]")
            else:
                ov = self.fresh("po")
                e(f"const {ov} = @addWithOverflow({j}, {c});")
                e(f"if ({ov}[1] == 0 and {ov}[0] {'<=' if near else '<'} {arr}.len) {{")
                body(f"{arr}[{ov}[0]]")
            I()
        elif k == 17:
            # Leaving an inner block with a break to the outer one: only
            # paths that passed the check reach the use.
            r, outer, inner = self.fresh("pr"), self.fresh("po"), self.fresh("pi")
            e(f"const {j}: usize = {x};")
            e(f"const {r}: {n} = {outer}: {{")
            ctx["indent"] += 1
            e(f"{inner}: {{")
            ctx["indent"] += 1
            leave = f"if (({j} & {self.r.randint(1, 3)}) == 0) break :{inner};"
            check = f"if ({j} >= {arr}.len) break :{outer} {self.lit(t)};"
            for line in ([leave, check] if near else [check, leave]):
                e(line)
            if self.chance(0.5):
                e(f"if ({j} == {self.r.randrange(ln)}) break :{outer} {arr}[{j}];")
            ctx["indent"] -= 1
            e("}")
            e(f"break :{outer} {arr}[{j}];")
            ctx["indent"] -= 1
            e("};")
            self.sink(ctx, r, t)
        elif k == 18:
            # One const from two arms; both must bound it for the check to go.
            cond = f"(({x}) & 1) == 0"
            other = f"{x} % {ln + 1}" if near else f"{x} % {ln}"
            w = self.r.random()
            if w < 0.4:
                e(f"const {j}: usize = if ({cond}) {x} % {ln} else {other};")
                self.sink(ctx, f"{arr}[{j}]", t)
            elif w < 0.7:
                b = self.fresh("pb")
                e(f"const {j}: usize = {b}: {{")
                e(f"    if ({cond}) break :{b} {other};")
                e(f"    break :{b} {x} % {ln};")
                e("};")
                self.sink(ctx, f"{arr}[{j}]", t)
            else:
                ja, jb, p = self.fresh("pj"), self.fresh("pj"), self.fresh("pp")
                e(f"const {ja}: usize = {x} % {ln};")
                e(f"const {jb}: usize = {other};")
                e(f"const {p}: *const usize = if ({cond}) &{ja} else &{jb};")
                self.sink(ctx, f"{arr}[{p}.*]", t)
        elif k == 19:
            # Undefined, then stored on every path.
            e(f"var {j}: usize = undefined;")
            if self.chance(0.5):
                e(f"if ((({x}) & 2) == 0) {{")
                e(f"    {j} = {x} % {ln};")
                e("} else {")
                e(f"    {j} = {x} % {ln + 1 if near else ln};")
                e("}")
                self.sink(ctx, f"{arr}[{j}]", t)
            else:
                e(f"{j} = {x};")
                e(f"if ({j} {'<=' if near else '<'} {ln}) {{")
                body(f"{arr}[{j}]")
                I()
        elif k == 20:
            # Narrowing casts after a bound on the wider value.
            self.sink(ctx, f"{arr}[0]", t)
            if t.signed and t.bits > 2:
                nt = Int(False, t.bits - 1)
                lo = "-1" if near else "0"
                e(f"if ({v} >= {lo} and {v} <= {nt.max()}) {{")
                body(f"@as({nt.name()}, @intCast({v}))", nt)
            elif not t.signed and t.bits > 1:
                nt = Int(self.chance(0.3), t.bits - 1)
                hi = nt.max() + (1 if near else 0)
                e(f"if ({v} <= {hi}) {{")
                body(f"@as({nt.name()}, @intCast({v}))", nt)
            else:
                e(f"if ({x} < {ln}) {{")
                body(f"{arr}[{x}]")
            I()
        elif k == 21:
            # Widened, shifted down, then used as an index.
            wi = self.fresh("pw")
            d = self.r.randint(0, 3)
            e(f"const {wi}: i128 = @as(i128, {v}) - {d};")
            e(f"if ({wi} >= {'-1' if near else '0'} and {wi} < {ln}) {{")
            body(f"{arr}[@intCast({wi})]")
            I()
        else:
            # Counting down to zero, or clamping.
            if self.chance(0.5):
                e(f"var {j}: usize = {x} % {ln + 1};")
                if near:
                    e(f"while ({j} > 0) : ({j} -= 1) {{")
                    body(f"{arr}[{j}]")
                else:
                    e(f"while ({j} > 0) {{")
                    ctx["indent"] += 1
                    e(f"{j} -= 1;")
                    self.sink(ctx, f"{arr}[{j}]", t)
                    ctx["indent"] -= 1
                I()
            else:
                e(f"const {j}: usize = @min({x}, {ln if near else ln - 1});")
                self.sink(ctx, f"{arr}[{j}]", t)

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
        # A global of the big struct, and a comptime constant of it.
        v = Var("gB", self.big, "global")
        self.rt_names.add("gB")
        v.used = True
        self.globals.append(v)
        out.append(f"var gB: {self.big.name()} = {self.global_init(self.big)};")
        out.append(f"const KB: {self.big.name()} = {self.global_init(self.big)};")
        hs = self.huge
        out.append(f"const SH = struct {{ {', '.join(f'{n_}: {t_.name()}' for n_, t_ in hs.fields)} }};")
        v = Var("gH", hs, "global")
        self.rt_names.add("gH")
        v.used = True
        self.globals.append(v)
        out.append(f"var gH: SH = {self.global_init(hs)};")
        # A local struct worked through an inlined self pointer (s_sroaesc).
        out.extend(SE_DECL)
        out.extend(RB_DECL)
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
        self.byref_helpers()
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
        if self.use_pk:
            out.extend(PK_DECL)
        for k_ in sorted(self.extra):
            out.extend(EXTRA_DECL[k_])
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
