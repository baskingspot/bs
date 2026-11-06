//! exit: 0
//! stderr: "0 6 ac 7 5 3.5 { 6, 8, 10, 12 } -1\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux
//! Block results in registers on aarch64: an integer if-expression in a
//! loop, a slice (two registers) and a float that live across a call, a
//! vector, and a bool block that a branch tests.
const std = @import("std");

noinline fn count(xs: []const u32, k: u32) u32 {
    var n: u32 = 0;
    for (xs) |x| {
        const d = if (x > k) x - k else k - x;
        n +%= if (d < 3) 1 else 0;
    }
    return n;
}

noinline fn len(s: []const u8) usize {
    return s.len;
}

noinline fn pick(a: []const u8, b: []const u8, first: bool) []const u8 {
    const s = if (first) a else b;
    // The block's registers survive the call.
    const n = len(b);
    return s[0 .. s.len - n + n];
}

noinline fn half(x: f64) f64 {
    return x / 2;
}

noinline fn fl(x: f64, y: f64) f64 {
    const m = if (x > y) x else y;
    return m + half(m) - half(m);
}

noinline fn vec(a: @Vector(4, f32), b: @Vector(4, f32), add: bool) @Vector(4, f32) {
    const v = if (add) a + b else a - b;
    return v * @as(@Vector(4, f32), @splat(2));
}

noinline fn sign(x: i64, y: i64) i64 {
    const both = x < 0 and y < 0;
    if (both) return -1;
    return if (x < y) 1 else 2;
}

pub fn main() void {
    const xs = [_]u32{ 1, 5, 9, 10, 11, 12, 13, 20 };
    const s = pick("abc", "ac", false);
    std.debug.print("{d} {d} {s} {d} {d} {d} {d} {d}\n", .{
        count(xs[0..0], 0),
        count(&xs, 1) + count(&xs, 11),
        s,
        @as(u64, len(pick("abcdefg", "x", true))),
        @as(u64, count(&xs, 11)),
        fl(3.5, 1.25),
        vec(.{ 1, 2, 3, 4 }, .{ 2, 2, 2, 2 }, true),
        sign(-3, -4),
    });
}
