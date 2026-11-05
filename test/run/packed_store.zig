//! exit: 0
//! stderr: "1234 1 true 5\n1235 3 false\n77 2 true\n-3 d a beef true 123456789\n91a2b3c4c48d0dfd 123456789\n5fedcba987654321deadbeef01234567\n99 3 true\n8d\n402a\n{ 65535, 61344, 65535 }\npanic: integer does not fit in destination type; e12c\n"
//! A packed struct literal stored through a pointer writes its host
//! integer once, without reading it when every field is written
//! (`PackedChain` in Sema.zig), also across the safety checks of its
//! field values, whose failing paths write the fields so far before the
//! panic, as the panic handler here sees. A field that reads the
//! destination, separate statements, volatile pointers and hosts over 64
//! bits keep the field-by-field writes, and each field still sees the
//! fields written before it.
const std = @import("std");

pub const panic = std.debug.FullPanic(onPanic);
var watched: ?*H = null;
fn onPanic(msg: []const u8, _: ?usize) noreturn {
    // The field written before the failing check is in memory.
    std.debug.print("panic: {s}; {x}\n", .{ msg, @as(u16, @bitCast(watched.?.data)) });
    std.process.exit(0);
}
const P = packed struct(u16) { len: u13, a: u2, p: bool };
const H = struct { x: u32, data: P };
const E = enum(u3) { a, b, c, d, e };
const Q = packed struct(u64) { s: i7, e: E, inner: packed struct(u20) { lo: u4, hi: u16 }, f: bool, rest: u33 };
const D = packed struct(u8) { a: u3 = 5, b: u5 };
const Wide = packed struct(u128) { a: u64, b: u60, c: u4 };

noinline fn set(h: *H, n: u13, b: bool) void {
    h.data = .{ .len = n, .a = 1, .p = b };
}
noinline fn selfRead(h: *H) void {
    // Reads the destination between field stores: each field sees the
    // fields written before it, as upstream.
    h.data = .{ .len = h.data.len +% 1, .a = @truncate(h.data.len), .p = h.data.len & 1 == 0 };
}
noinline fn checked(h: *H, n: usize, al: u6) void {
    h.data = .{ .len = @intCast(n), .a = @intCast(al), .p = true };
}
noinline fn setQ(q: *Q, s: i7, e: E, hi: u16, r: u33) void {
    q.* = .{ .s = s, .e = e, .inner = .{ .lo = 0xa, .hi = hi }, .f = true, .rest = r };
}
noinline fn setInner(q: *Q, lo: u4, hi: u16) void {
    q.inner = .{ .lo = lo, .hi = hi };
}
noinline fn setW(w: *Wide, a: u64, b: u60) void {
    w.* = .{ .a = a, .b = b, .c = 5 };
}
noinline fn twoStmts(h: *H, n: u13) void {
    h.data.len = n;
    h.data.a = 3;
}
noinline fn defaults(d: *D, b: u5) void {
    d.* = .{ .b = b };
}
noinline fn vol(p: *volatile P, n: u13) void {
    p.* = .{ .len = n, .a = 2, .p = false };
}
noinline fn arr(ps: []P, i: usize, n: u13) void {
    ps[i] = .{ .len = n, .a = 3, .p = true };
}

pub fn main() void {
    var h: H = .{ .x = 5, .data = .{ .len = 0, .a = 0, .p = false } };
    set(&h, 1234, true);
    std.debug.print("{d} {d} {} {d}\n", .{ h.data.len, h.data.a, h.data.p, h.x });
    selfRead(&h);
    std.debug.print("{d} {d} {}\n", .{ h.data.len, h.data.a, h.data.p });
    checked(&h, 77, 2);
    std.debug.print("{d} {d} {}\n", .{ h.data.len, h.data.a, h.data.p });
    var q: Q = @bitCast(@as(u64, 0xffff_ffff_ffff_ffff));
    setQ(&q, -3, .d, 0xbeef, 0x1_2345_6789);
    std.debug.print("{d} {t} {x} {x} {} {x}\n", .{ q.s, q.e, q.inner.lo, q.inner.hi, q.f, q.rest });
    setInner(&q, 3, 0x1234);
    std.debug.print("{x} {x}\n", .{ @as(u64, @bitCast(q)), q.rest });
    var w: Wide = @bitCast(@as(u128, 0));
    setW(&w, 0xdead_beef_0123_4567, 0xfed_cba9_8765_4321);
    std.debug.print("{x}\n", .{@as(u128, @bitCast(w))});
    twoStmts(&h, 99);
    std.debug.print("{d} {d} {}\n", .{ h.data.len, h.data.a, h.data.p });
    var d: D = @bitCast(@as(u8, 0));
    defaults(&d, 17);
    std.debug.print("{x}\n", .{@as(u8, @bitCast(d))});
    var v: P = @bitCast(@as(u16, 0xffff));
    vol(&v, 42);
    std.debug.print("{x}\n", .{@as(u16, @bitCast(v))});
    var ps: [3]P = @bitCast([_]u16{ 0xffff, 0xffff, 0xffff });
    arr(&ps, 1, 4000);
    std.debug.print("{any}\n", .{@as([3]u16, @bitCast(ps))});
    h.data = @bitCast(@as(u16, 0xffff));
    watched = &h;
    checked(&h, 300, 9);
}
