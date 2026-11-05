//! exit: 0
//! stderr: "ints 337d32c15e9c288a\nfloats 31195d8ec9834b6\ncasts af130e3c9243af4b\nshuffles 3fb40b1862acdb51\nbools 68b43126322bce72\nnarrow 1c0ab8eeb68281a1\nsearch 871573d1fcb6c270\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux

// Vector operations lowered in SIMD registers on every target (SSE on
// x86_64, NEON on aarch64), at the shapes where a lowering goes wrong:
// lanes past the length (a @Vector(3, u32) has a fourth lane, a
// @Vector(4, u8) on aarch64 fills only part of a register), vectors of
// several 16-byte chunks with a partial last one, 64-bit lanes, signed
// and unsigned bounds, narrow integers, select and compare bits past 16
// lanes, shuffles over more than four source chunks, casts across three
// lane widths, shifts of signed bytes and 64-bit lanes, and the
// std.simd index searches. Each line folds one group's results; floats
// avoid zeros and NaNs, whose min and quotient bits differ by target.
const std = @import("std");

var seed: u64 = 0x9e3779b97f4a7c15;

fn next() u64 {
    seed = seed *% 6364136223846793005 +% 1442695040888963407;
    return seed >> 11;
}

/// A runtime vector of edge values and noise.
noinline fn vec(comptime n: usize, comptime T: type) @Vector(n, T) {
    var a: [n]T = undefined;
    for (&a, 0..) |*x, i| {
        const r = next();
        x.* = switch (@typeInfo(T)) {
            .int => switch (r % 6) {
                0 => std.math.maxInt(T),
                1 => std.math.minInt(T),
                2 => 0,
                else => @bitCast(@as(@Int(.unsigned, @bitSizeOf(T)), @truncate(r))),
            },
            .float => @as(T, @floatFromInt(@as(i32, @truncate(@as(i64, @bitCast(r)))) >> 8 | 1)) / 7,
            .bool => r % 3 == 0,
            else => unreachable,
        };
        if (i == n - 1 and n > 1) x.* = a[0];
    }
    return a;
}

var h: u64 = 0;

fn mix(x: anytype) void {
    const T = @TypeOf(x);
    switch (@typeInfo(T)) {
        .vector => |v| inline for (0..v.len) |i| mix(x[i]),
        .bool => mix(@as(u8, @intFromBool(x))),
        .float => mix(@as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(x))),
        .int => h = (h ^ @as(u64, @truncate(@as(u128, @as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(x)))))) *% 0x100000001b3,
        else => unreachable,
    }
}

fn line(name: []const u8) void {
    std.debug.print("{s} {x}\n", .{ name, h });
    h = 0;
}

noinline fn ints(comptime n: usize, comptime T: type) void {
    const a = vec(n, T);
    const b = vec(n, T);
    mix(a +% b);
    mix(a -% b);
    if (@sizeOf(T) < 8) mix(a *% b);
    mix(a & b ^ ~a | b);
    mix(@min(a, b));
    mix(@max(b, a));
    mix(a == b);
    mix(a != b);
    mix(a < b);
    mix(a <= b);
    mix(a > b);
    mix(a >= b);
    mix(@reduce(.Add, a));
    mix(@reduce(.Min, a));
    mix(@reduce(.Max, a));
    mix(@reduce(.And, a));
    mix(@reduce(.Or, a));
    mix(@reduce(.Xor, a));
    if (@sizeOf(T) < 8) mix(@reduce(.Mul, a));
    mix(@reduce(.Or, a == b));
    mix(@reduce(.And, a != b));
    mix(@select(T, a < b, a, b));
    mix(@as(@Vector(n, T), @splat(a[1])));
}

noinline fn floats(comptime n: usize, comptime T: type) void {
    const a = vec(n, T);
    const b = vec(n, T);
    mix(a + b);
    mix(a - b);
    mix(a * b);
    mix(a / b);
    mix(-a);
    mix(@abs(a));
    mix(@sqrt(@abs(a)));
    mix(@min(a, b));
    mix(@max(a, b));
    mix(a == b);
    mix(a != b);
    mix(a < b);
    mix(a >= b);
    mix(@select(T, a < b, a, b));
}

noinline fn shifts(comptime n: usize, comptime T: type) void {
    const Amt = std.math.Log2Int(T);
    const a = vec(n, T);
    var k: Amt = @truncate(next());
    mix(a << @splat(k));
    mix(a >> @splat(k));
    k = @bitSizeOf(T) - 1;
    mix(a >> @splat(k));
    mix(a << @as(@Vector(n, Amt), @splat(3)));
    mix(a >> @as(@Vector(n, Amt), @splat(1)));
    mix(a >> @as(@Vector(n, Amt), @splat(@bitSizeOf(T) - 1)));
}

noinline fn casts() void {
    const a = vec(24, u8);
    const b = vec(24, i8);
    mix(@as(@Vector(24, u64), a));
    mix(@as(@Vector(24, i32), b));
    const c = vec(17, u64);
    mix(@as(@Vector(17, u8), @truncate(c)));
    mix(@as(@Vector(17, u16), @truncate(c)));
    const d = vec(5, i32);
    mix(@as(@Vector(5, i64), d));
    mix(@as(@Vector(5, u8), @truncate(@as(@Vector(5, u32), @bitCast(d)))));
}

noinline fn shuffles() void {
    const a = vec(32, u32);
    const b = vec(9, u32);
    mix(@shuffle(u32, a, b, [_]i32{ 31, ~@as(i32, 8), 0, 17, ~@as(i32, 0), 5, 30, ~@as(i32, 4) }));
    const c = vec(3, u8);
    mix(@shuffle(u8, c, undefined, [_]i32{ 2, 1, 0, 2, 1 }));
    const d = vec(20, u16);
    mix(@shuffle(u16, d, d, [_]i32{ 19, 18, ~@as(i32, 1), 0, 9, 10 }));
}

noinline fn bools(comptime n: usize) void {
    const a = vec(n, bool);
    const b = vec(n, bool);
    mix(a & b);
    mix(a | b);
    mix(a ^ b);
    mix(!a);
    mix(@reduce(.And, a));
    mix(@reduce(.Or, b));
    mix(@reduce(.Xor, a));
    mix(@reduce(.And, !(a & b) | a));
    mix(if (std.simd.firstTrue(a)) |i| @as(u32, i) else 99);
    mix(if (std.simd.lastTrue(b)) |i| @as(u32, i) else 99);
    mix(std.simd.countTrues(a));
    const x = vec(n, u8);
    mix(@select(u8, a, x, @as(@Vector(n, u8), @splat(7))));
}

noinline fn narrow() void {
    const a = vec(7, u4);
    const b = vec(7, u4);
    mix(a & b);
    mix(a < b);
    mix(@min(a, b));
    mix(@reduce(.Max, a));
    const c = vec(9, i5);
    mix(c >= vec(9, i5));
    mix(~c);
    mix(@reduce(.Min, c));
}

noinline fn search(hay: []const u8, needle: u8) void {
    mix(std.mem.indexOfScalar(u8, hay, needle) orelse 99999);
    mix(std.mem.lastIndexOfScalar(u8, hay, needle) orelse 99999);
    var it = std.mem.splitScalar(u8, hay, needle);
    while (it.next()) |part| mix(part.len);
    mix(@intFromBool(std.mem.eql(u8, hay[1..], hay[0 .. hay.len - 1])));
}

pub fn main() void {
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64 }) |T| {
        inline for (.{ 2, 3, 4, 16, 33 }) |n| {
            if (n * @sizeOf(T) <= 128) {
                ints(n, T);
                shifts(n, T);
            }
        }
    }
    line("ints");
    inline for (.{ f32, f64 }) |T| inline for (.{ 2, 3, 4, 9 }) |n| floats(n, T);
    line("floats");
    casts();
    line("casts");
    shuffles();
    line("shuffles");
    inline for (.{ 3, 8, 13, 16, 31, 40, 64 }) |n| bools(n);
    line("bools");
    narrow();
    line("narrow");
    var hay: [3000]u8 = undefined;
    for (&hay, 0..) |*c, j| c.* = @truncate(j *% 7 +% j / 13);
    for (0..40) |j| search(hay[j * 5 ..][0..900], @truncate(j * 11));
    line("search");
}
