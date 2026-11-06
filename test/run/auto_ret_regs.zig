//! exit: 0
//! stderr: "s17 17 1 s19 19 3 s20 20 5 s24 24 7 s28 28 9 s32 32 11 s33 33 13 eu 3 hi 2 err 1 opt 4 fp 6 wide 8 vec 10\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux
//! `.auto` results of 17 to 32 bytes come back in x0-x3 on aarch64, the
//! last register holding only the bytes past 16 or 24; 33 bytes still go
//! through x8. Every byte of each result must arrive, at sizes whose tail
//! takes one load (24) or several (19, 28), through `try` chains and
//! function pointers.
const std = @import("std");

fn Bytes(comptime n: usize, comptime al: usize) type {
    return extern struct { b: [n]u8 align(al) };
}

noinline fn make(comptime T: type, seed: u8) T {
    var t: T = undefined;
    for (&t.b, 0..) |*x, i| x.* = seed +% @as(u8, @intCast(i)) *% 7;
    return t;
}

fn check(comptime T: type, t: T, seed: u8) usize {
    for (t.b, 0..) |x, i| if (x != seed +% @as(u8, @intCast(i)) *% 7) return 1000 + i;
    return t.b.len;
}

const Err = error{ Bad, Worse };

noinline fn slice(buf: []const u8, fail: bool) Err![]const u8 {
    if (fail) return error.Worse;
    return buf[1..4];
}

noinline fn sliceTry(buf: []const u8, fail: bool) Err![]const u8 {
    const s = try slice(buf, fail);
    return s;
}

noinline fn sliceHi(buf: []const u8) anyerror![]const u8 {
    const s = try sliceTry(buf, false);
    return s[1..];
}

noinline fn optPair(x: u64) Err!?[2]u64 {
    if (x == 0) return null;
    return .{ x, x * 2 };
}

const Wide = struct { a: u64, e: u64, b: u32, c: u16, d: u8 };

noinline fn wide(x: u64) Wide {
    return .{ .a = x, .e = x * 3, .b = @intCast(x + 1), .c = @intCast(x + 2), .d = @intCast(x + 3) };
}

noinline fn vec(x: u32) @Vector(8, u32) {
    return @splat(x);
}

pub fn main() void {
    var seed: u8 = 1;
    _ = &seed;
    const s17 = make(Bytes(17, 1), seed);
    const s19 = make(Bytes(19, 1), seed + 2);
    const s20 = make(Bytes(20, 4), seed + 4);
    const s24 = make(Bytes(24, 8), seed + 6);
    const s28 = make(Bytes(28, 4), seed + 8);
    const s32 = make(Bytes(32, 8), seed + 10);
    const s33 = make(Bytes(33, 1), seed + 12);
    const buf = "abcdef";
    const eu = sliceTry(buf, false) catch unreachable;
    const hi = sliceHi(buf) catch unreachable;
    const err: usize = if (sliceTry(buf, true)) |_| 0 else |e| @intFromBool(e == error.Worse);
    const opt = (optPair(2) catch unreachable).?;
    var f: *const fn (u64) Wide = &wide;
    _ = &f;
    const w = f(5);
    const t = wide(8);
    const v = vec(10);
    std.debug.print("s17 {} {} s19 {} {} s20 {} {} s24 {} {} s28 {} {} s32 {} {} s33 {} {} eu {} hi {} err {} opt {} fp {} wide {} vec {}\n", .{
        check(Bytes(17, 1), s17, seed),      s17.b[16] - 7 * 16,
        check(Bytes(19, 1), s19, seed + 2),  s19.b[0],
        check(Bytes(20, 4), s20, seed + 4),  s20.b[0],
        check(Bytes(24, 8), s24, seed + 6),  s24.b[0],
        check(Bytes(28, 4), s28, seed + 8),  s28.b[0],
        check(Bytes(32, 8), s32, seed + 10), s32.b[0],
        check(Bytes(33, 1), s33, seed + 12), s33.b[0],
        eu.len,                              hi.len,
        err,                                 opt[1],
        w.b + (w.d - w.c) - 1,               t.a,
        @reduce(.Add, v) / 8,
    });
}
