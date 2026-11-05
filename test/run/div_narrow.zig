//! exit: 0
//! stderr: "i128 1f678f70083b2620 u128 e5d778ff96ea3a69 i64 86df4ffeb0bd42e4 i32 f2f48fdfc2ec381 i7 656148e1dfec8a9b u64 11dacf12be5a6b1\n1700000000 123456789 -19675925927355 9223372036854775808\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux

// Division of 128-bit integers whose values fit in 64 bits divides them as
// 64-bit integers, around the edges where they stop fitting (2^63, 2^64,
// minInt(i64) / -1); a constant divisor is divided by without a divide at
// any width, signed or not.
const std = @import("std");

var h: u64 = 0xcbf29ce484222325;

fn mix(x: anytype) void {
    const U = @Int(.unsigned, @bitSizeOf(@TypeOf(x)));
    const u: U = @bitCast(x);
    var i: u16 = 0;
    while (i < @bitSizeOf(U)) : (i += 64) h = (h ^ @as(u64, @truncate(u >> @intCast(i)))) *% 0x100000001b3;
}

fn ops(comptime T: type, a: T, b: T) void {
    if (@typeInfo(T).int.signedness == .signed and a == std.math.minInt(T) and b == -1) return;
    mix(@divTrunc(a, b));
    mix(@divFloor(a, b));
    mix(@rem(a, b));
    mix(@mod(a, b));
    if (@typeInfo(T).int.signedness == .unsigned) mix(std.math.divCeil(T, a, b) catch unreachable);
}

fn opsConst(comptime T: type, a: T, comptime b: T) void {
    if (@typeInfo(T).int.signedness == .signed and a == std.math.minInt(T) and b == -1) return;
    mix(@divTrunc(a, b));
    mix(@divFloor(a, b));
    mix(@rem(a, b));
    mix(@mod(a, b));
}

fn sweep(comptime T: type, vals: []const T, comptime consts: []const T) u64 {
    h = 0xcbf29ce484222325;
    for (vals) |a| {
        for (vals) |b| if (b != 0) ops(T, a, b);
        inline for (consts) |c| opsConst(T, a, c);
    }
    return h;
}

var i128s = [_]i128{
    0,             1,              -1,                        2,                          -2,                    3,
    7,             -7,             59,                        -61,                        86400,                 -86400,
    1_000_000_000, -1_000_000_000, 1_700_000_000_123_456_789, -1_700_000_000_123_456_789, (1 << 62) + 5,         -(1 << 62) - 5,
    (1 << 63) - 1, -(1 << 63),     -(1 << 63) + 1,            1 << 63,                    -(1 << 63) - 1,        (1 << 64) - 1,
    1 << 64,       -(1 << 64),     (1 << 64) + 1,             std.math.maxInt(i128),      std.math.minInt(i128), 0x1234_5678_9abc_def0_1357_9bdf_2468_ace0,
};

var u128s = [_]u128{
    0,                     1,                                         2,             3,             7,                         59,
    86400,                 1_000_000_000,                             (1 << 32) - 1, 1 << 32,       1_700_000_000_123_456_789, (1 << 63) - 1,
    1 << 63,               (1 << 63) + 1,                             (1 << 64) - 2, (1 << 64) - 1, 1 << 64,                   (1 << 64) + 1,
    std.math.maxInt(u128), 0xfedc_ba98_7654_3210_0123_4567_89ab_cdef,
};

var i64s = [_]i64{ 0, 1, -1, 2, -2, 3, -3, 7, -7, 999, -999, 1000, -1000, 86399, -86401, 1_700_000_000_123_456_789, -1_700_000_000_123_456_789, std.math.maxInt(i64), std.math.minInt(i64), std.math.minInt(i64) + 1 };
var i32s = [_]i32{ 0, 1, -1, 5, -5, 59, -61, 86400, -86400, std.math.maxInt(i32), std.math.minInt(i32), std.math.minInt(i32) + 1 };
var i7s = [_]i7{ 0, 1, -1, 2, -2, 5, -5, 21, -22, std.math.maxInt(i7), std.math.minInt(i7) };
var u64s = [_]u64{ 0, 1, 2, 999, 1000, 1001, (1 << 63) - 1, 1 << 63, std.math.maxInt(u64) - 1, std.math.maxInt(u64) };

pub fn main() void {
    const a = sweep(i128, &i128s, &.{ 1, 2, 3, 7, 10, 60, 1000, 86400, 1_000_000_000, 1 << 32, 1 << 62, (1 << 63) - 1, -1, -2, -3, -7, -1000, -(1 << 63), 1 << 63, (1 << 64) + 1, std.math.minInt(i128) });
    const b = sweep(u128, &u128s, &.{ 1, 2, 3, 7, 10, 1000, 1_000_000_000, 1 << 32, (1 << 63) - 1, 1 << 63, (1 << 63) + 1, (1 << 64) - 1, 1 << 64, std.math.maxInt(u128) });
    const c = sweep(i64, &i64s, &.{ 1, 2, 3, 7, 10, 60, 1000, 86400, 1_000_000_000, 1 << 32, (1 << 62) + 1, std.math.maxInt(i64), -1, -3, std.math.minInt(i64) });
    const d = sweep(i32, &i32s, &.{ 1, 2, 3, 7, 60, 1000, 86400, std.math.maxInt(i32), -7 });
    const e = sweep(i7, &i7s, &.{ 1, 2, 3, 5, 7, 16, 63, -1, -5 });
    const f = sweep(u64, &u64s, &.{ 1, 3, 1000, (1 << 63) + 1, std.math.maxInt(u64) });
    std.debug.print("i128 {x} u128 {x} i64 {x} i32 {x} i7 {x} u64 {x}\n", .{ a, b, c, d, e, f });
    const ts = i128s[14];
    std.debug.print("{d} {d} {d} {d}\n", .{ @divFloor(ts, 1_000_000_000), @mod(ts, 1_000_000_000), @divFloor(-ts, 86400), @divTrunc(i128s[19], i128s[2]) });
}
