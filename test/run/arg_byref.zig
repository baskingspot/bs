//! exit: 0
//! stdout: "21 100 22 270 22 278 27 71 197 1496 10003 10010 46 7890123456\n"

// `.auto` passes an argument larger than 16 bytes by reference: a pointer
// to memory that does not change during the call. The callee reads it
// there, through a register holding the pointer when it gets one, and
// otherwise copies it in. The caller passes a constant's memory, a value's
// slot, or a by-reference parameter's pointer, and copies anything else.
// A callee that writes the argument's source through a pointer or a global
// still sees the value it was called with; so does one whose result goes
// where its argument came from. Twelve such parameters live across calls
// do not all get registers; four are passed on the stack. A tail call
// passes on its by-reference parameters and constants.
const std = @import("std");
const builtin = @import("builtin");

const Big = struct { v: [6]u64 };
const Odd = struct { b: [17]u8 };

noinline fn sum(x: Big) u64 {
    var t: u64 = 0;
    for (x.v) |e| t += e;
    return t;
}

const table: Big = .{ .v = .{ 10, 20, 30, 40, 0, 0 } };

/// Writes the argument's source through `p` before reading the argument.
noinline fn clobberPtr(x: Big, p: *Big) u64 {
    p.v[0] = 1000;
    return sum(x) + x.v[0];
}

var global: Big = .{ .v = .{ 1, 2, 3, 4, 5, 6 } };

noinline fn clobberGlobal(x: Big) u64 {
    global.v[5] = 500;
    return x.v[5] * 10 + sum(x) * 10;
}

noinline fn inner(x: Big) u64 {
    global.v[1] = 77;
    return sum(x);
}

noinline fn middle(x: Big, k: u64) u64 {
    const c = x;
    return inner(c) + inner(x) + c.v[2] * k;
}

/// The result goes to the memory its argument was loaded from.
noinline fn reverse(x: Big) Big {
    var r: Big = undefined;
    for (0..6) |i| r.v[i] = x.v[5 - i] + 1;
    return r;
}

noinline fn opaque_(n: u64) u64 {
    std.mem.doNotOptimizeAway(n);
    return n;
}

/// More by-reference parameters live across calls than there are
/// registers that survive them; four are passed on the stack, and all
/// are passed on.
noinline fn many(a: Big, b: Big, c: Big, d: Big, e: Big, f: Big, g: Big, h: Big, i: Big, j: Big, k: Big, l: Big) u64 {
    var t: u64 = opaque_(1);
    t += a.v[0] + b.v[1] + c.v[2] + d.v[3] + e.v[4] + f.v[5];
    t += opaque_(2);
    t += g.v[0] + h.v[1] + i.v[2] + j.v[3] + k.v[4] + l.v[5];
    t += opaque_(3);
    return t + a.v[1] + l.v[0] + sum(l) + sum(a) + manyAgain(l, k, j, i, h, g, f, e, d, c, b, a);
}

noinline fn manyAgain(a: Big, b: Big, c: Big, d: Big, e: Big, f: Big, g: Big, h: Big, i: Big, j: Big, k: Big, l: Big) u64 {
    return a.v[0] + b.v[0] + c.v[0] + d.v[0] + e.v[0] + f.v[0] + g.v[0] + h.v[0] + i.v[0] + j.v[0] + k.v[0] + l.v[0];
}

noinline fn odd(x: Odd, y: Odd) u64 {
    const c = x;
    var t: u64 = 0;
    for (c.b, y.b) |p, q| t += @as(u64, p) * q;
    return t;
}

noinline fn overAligned(x: Big) u64 {
    const c: Big align(32) = x;
    std.debug.assert(@intFromPtr(&c) % 32 == 0);
    return c.v[3];
}

noinline fn countdown(x: Big, y: Big, n: u64) u64 {
    if (n == 0) return x.v[0] * 1000 + y.v[0];
    // A tail call passes its by-reference parameters on, swapped, and a
    // constant; upstream's x86_64 backend has no tail calls.
    if (n == 1) return @call(if (builtin.cpu.arch == .aarch64) .always_tail else .auto, countdown, .{ table, x, n - 1 });
    return @call(if (builtin.cpu.arch == .aarch64) .always_tail else .auto, countdown, .{ y, x, n - 1 });
}

/// Rotates ten by-reference parameters, two passed on the stack, through
/// tail calls, which read every pointer before writing the stack slots.
noinline fn rotate(a: Big, b: Big, c: Big, d: Big, e: Big, f: Big, g: Big, h: Big, i: Big, j: Big, n: u64) u64 {
    if (n == 0) return a.v[0] * 1000000000 + b.v[0] * 100000000 + c.v[0] * 10000000 + d.v[0] * 1000000 + e.v[0] * 100000 + f.v[0] * 10000 + g.v[0] * 1000 + h.v[0] * 100 + i.v[0] * 10 + j.v[0];
    const modifier: std.builtin.CallModifier = if (builtin.cpu.arch == .aarch64) .always_tail else .auto;
    if (n == 1) return @call(modifier, rotate, .{ seven, a, b, c, d, e, f, g, h, i, n - 1 });
    return @call(modifier, rotate, .{ j, a, b, c, d, e, f, g, h, i, n - 1 });
}

const seven: Big = .{ .v = .{ 7, 0, 0, 0, 0, 0 } };

pub fn main() void {
    var v: Big = .{ .v = .{ 1, 2, 3, 4, 5, 6 } };
    std.mem.doNotOptimizeAway(&v);
    var o: Odd = undefined;
    for (&o.b, 0..) |*b, i| b.* = @intCast(i);
    std.mem.doNotOptimizeAway(&o);
    var out: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    const a = sum(v);
    const b = sum(table);
    const c = clobberPtr(v, &v);
    v.v[0] = 1;
    const d = clobberGlobal(global);
    global.v[5] = 6;
    const e = clobberPtr(v, &v);
    v.v[0] = 1;
    const f = middle(global, 2) + middle(table, 1);
    global.v[1] = 2;
    v = reverse(v);
    const g = sum(v);
    v = reverse(v);
    const h = sum(v) + v.v[0] * 10 + v.v[5];
    const i = many(v, table, global, v, table, global, v, table, global, v, table, global);
    var r: [10]Big = undefined;
    for (&r, 0..) |*x, k| x.* = .{ .v = .{ k, 0, 0, 0, 0, 0 } };
    std.mem.doNotOptimizeAway(&r);
    w.print("{} {} {} {} {} {} {} {} {} {} {} {} {} {}\n", .{
        a,
        b,
        c,
        d,
        e,
        f,
        g,
        h,
        i,
        odd(o, o),
        countdown(v, global, 3),
        countdown(table, v, 1),
        overAligned(v) + overAligned(table),
        rotate(r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], 3),
    }) catch unreachable;
    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, w.buffered()) catch {};
}
