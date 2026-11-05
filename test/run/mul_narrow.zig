//! exit: 0
//! stderr: "i128 725744b2861d48e0 u128 9d17e7a11331cebd i100 d608aef51d4a332a u100 f5366a275be79625 i65 e91d9a0f63faf37a\n456789 1700000000123456789000000000\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux

// 128-bit and narrower wide multiplies with overflow whose operands fit in
// 64 bits take one widening multiply: their products, overflow bits, and
// checked products around the edges where the operands stop fitting
// (2^63, 2^64) and where the product stops fitting a narrower type.
const std = @import("std");

var h: u64 = 0xcbf29ce484222325;

fn mix(x: anytype) void {
    const U = @Int(.unsigned, @bitSizeOf(@TypeOf(x)));
    const u: U = @bitCast(x);
    var i: u16 = 0;
    while (i < @bitSizeOf(U)) : (i += 64) h = (h ^ @as(u64, @truncate(u >> @intCast(i)))) *% 0x100000001b3;
}

fn sweep(comptime T: type, vals: []const T, comptime consts: []const T) u64 {
    h = 0xcbf29ce484222325;
    for (vals) |a| {
        for (vals) |b| {
            const r = @mulWithOverflow(a, b);
            mix(r[0]);
            mix(r[1]);
            if (r[1] == 0) mix(a * b);
        }
        inline for (consts) |c| {
            const r = @mulWithOverflow(a, c);
            mix(r[0]);
            mix(r[1]);
            if (r[1] == 0) mix(c * a);
        }
    }
    return h;
}

const m63 = 1 << 63;
var i128s = [_]i128{ 0, 1, -1, 3, -7, 1_000_000, -1_000_000_000, 1_700_000_000_123_456_789, -1_700_000_000_123_456_789, (1 << 32) + 1, -(1 << 32), m63 - 1, -m63, -m63 + 1, m63, -m63 - 1, (1 << 64) - 1, 1 << 64, std.math.maxInt(i128), std.math.minInt(i128), 0x1234_5678_9abc_def0_1357_9bdf_2468_ace0 };
var u128s = [_]u128{ 0, 1, 2, 1_000_000_000, (1 << 32) - 1, 1 << 32, m63, (1 << 64) - 1, 1 << 64, (1 << 64) + 1, std.math.maxInt(u128), 0xfedc_ba98_7654_3210_0123_4567_89ab_cdef };
var i100s = [_]i100{ 0, 1, -1, 5, -9, 1 << 40, -(1 << 40), (1 << 49) - 1, 1 << 49, -(1 << 49), -(1 << 49) - 1, m63 - 1, -m63, m63, std.math.maxInt(i100), std.math.minInt(i100) };
var u100s = [_]u100{ 0, 1, 3, 1 << 36, (1 << 50) - 1, 1 << 50, (1 << 64) - 1, 1 << 64, std.math.maxInt(u100) };
var i65s = [_]i65{ 0, 1, -1, 2, -2, 1 << 32, -(1 << 32), (1 << 32) + 1, m63 - 1, -m63, std.math.maxInt(i65), std.math.minInt(i65) };

pub fn main() void {
    const a = sweep(i128, &i128s, &.{ 0, 1, -1, 1000, 1_000_000_000, -86400, m63 - 1, -m63, m63, (1 << 64) + 3, std.math.minInt(i128) });
    const b = sweep(u128, &u128s, &.{ 0, 1, 1_000_000_000, (1 << 64) - 1, 1 << 64 });
    const c = sweep(i100, &i100s, &.{ 1, -1, 1 << 36, -m63, m63 });
    const d = sweep(u100, &u100s, &.{ 7, 1 << 36, (1 << 64) - 1, 1 << 64 });
    const e = sweep(i65, &i65s, &.{ -1, 3, 1 << 32, m63 - 1 });
    std.debug.print("i128 {x} u128 {x} i100 {x} u100 {x} i65 {x}\n", .{ a, b, c, d, e });
    const ns: i128 = i128s[7];
    std.debug.print("{d} {d}\n", .{ ns - @divFloor(ns, 1_000_000) * 1_000_000, @as(i128, @as(i64, @truncate(ns))) * 1_000_000_000 });
}
