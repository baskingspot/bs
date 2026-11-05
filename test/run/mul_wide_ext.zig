//! exit: 0
//! stderr: "94255905406016c9 5692a638d6d32a31 8db85cb94b502d01 9a86cad9d593e915 bd9ab62e643221c1 d7e9f42a66cd95ad\n1ce35f85406016c9 723d9d0601c73e1 2d9aebe079b7887d ebdb5d65eab965ad 461c07b2794ea6b9\nbe412755a1024e4b 22428999a77e012a 21db69397099938c feee138562b1feb6 aa946a59d95c1f6 efadddfed6af1a3e f068d5ed7908f52d\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux

// A 128-bit product of two extended 64-bit values (Wyhash's mum, the
// crypto field multiplies) is one 64-bit multiply and its high half on
// aarch64: unsigned, signed and mixed factors, narrower ones, and
// constants on either side, around the top bits where umulh and smulh
// differ. Shifts of wide integers by a constant and truncations of wide
// integers to at most 64 bits read their limbs directly.
const std = @import("std");

var h: u64 = 0xcbf29ce484222325;

fn mix(x: anytype) void {
    const U = @Int(.unsigned, @bitSizeOf(@TypeOf(x)));
    const u: U = @bitCast(x);
    if (@bitSizeOf(U) <= 64) {
        h = (h ^ @as(u64, u)) *% 0x100000001b3;
        return;
    }
    var i: u16 = 0;
    while (i < @bitSizeOf(U)) : (i += 64) h = (h ^ @as(u64, @truncate(u >> @intCast(i)))) *% 0x100000001b3;
}

/// An integer of `bits` bits with `T`'s signedness.
fn Like(comptime T: type, comptime bits: u16) type {
    return @Int(@typeInfo(T).int.signedness, bits);
}

fn halves(p: anytype) void {
    const P = @TypeOf(p);
    mix(p);
    mix(@as(Like(P, 64), @truncate(p)));
    mix(@as(Like(P, 64), @truncate(p >> 64)));
    mix(@as(Like(P, 32), @truncate(p >> 64)));
    mix(@as(Like(P, 1), @truncate(p >> 64)));
}

fn prods(comptime P: type, comptime A: type, comptime B: type, as: []const A, bs: []const B) u64 {
    h = 0xcbf29ce484222325;
    for (as) |a| for (bs) |b| {
        halves(@as(P, a) *% @as(P, b));
        halves(@as(P, b) *% @as(P, a));
    };
    return h;
}

fn consts(comptime P: type, comptime A: type, as: []const A, comptime cs: []const comptime_int) u64 {
    h = 0xcbf29ce484222325;
    for (as) |a| inline for (cs) |c| {
        halves(@as(P, a) *% c);
        halves(c *% @as(P, a));
    };
    return h;
}

fn shifts(comptime T: type, vs: []const T) u64 {
    h = 0xcbf29ce484222325;
    for (vs) |v| inline for (.{ 0, 1, 7, 63, 64, 65, 100, 127, 128, 191, 200 }) |k| if (k < @bitSizeOf(T)) {
        mix(v >> k);
        mix(v << k);
        mix(@as(Like(T, 64), @truncate(v >> k)));
        mix(@as(Like(T, 8), @truncate(v << k)));
    };
    return h;
}

var u64s = [_]u64{ 0, 1, 2, 0x7fff_ffff_ffff_ffff, 0x8000_0000_0000_0000, 0xffff_ffff_ffff_ffff, 0xdead_beef_1234_5678, 1_000_000_007 };
var i64s = [_]i64{ 0, 1, -1, 2, -2, std.math.maxInt(i64), std.math.minInt(i64), -0x2152_4110_edcb_a988, 1_000_000_007 };
var u32s = [_]u32{ 0, 1, 0xffff_ffff, 0x8000_0000, 12345 };
var i32s = [_]i32{ 0, -1, std.math.minInt(i32), std.math.maxInt(i32), -12345 };
var u63s = [_]u63{ 0, 1, std.math.maxInt(u63), 0x4000_0000_0000_0001 };
var i8s = [_]i8{ 0, -128, 127, -3 };

var u128s = [_]u128{ 0, 1, std.math.maxInt(u128), 1 << 64, (1 << 64) - 1, 1 << 127, 0x1234_5678_9abc_def0_0fed_cba9_8765_4321 };
var i128s = [_]i128{ 0, -1, std.math.minInt(i128), std.math.maxInt(i128), -(1 << 64), (1 << 63), -0x1234_5678_9abc_def0_0fed_cba9_8765_4321 };
var u256s = [_]u256{ 0, std.math.maxInt(u256), 0x1234_5678_9abc_def0_0fed_cba9_8765_4321_0011_2233_4455_6677_8899_aabb_ccdd_eeff };
var i256s = [_]i256{ -1, std.math.minInt(i256), -0x1234_5678_9abc_def0_0fed_cba9_8765_4321_0011_2233_4455_6677_8899_aabb_ccdd_eeff };
var u100s = [_]u100{ 0, std.math.maxInt(u100), 0xf_1234_5678_9abc_def0_0fed_cba9 };
var i65s = [_]i65{ -1, std.math.minInt(i65), std.math.maxInt(i65), -0x1_2345_6789_abcd_ef0 };

fn checked(as: []const u64) u64 {
    // `*`, whose overflow check is proven away into a wrapping multiply.
    h = 0xcbf29ce484222325;
    for (as) |a| for (as) |b| halves(@as(u128, a) * @as(u128, b));
    return h;
}

pub fn main() void {
    std.debug.print("{x} {x} {x} {x} {x} {x}\n", .{
        prods(u128, u64, u64, &u64s, &u64s),
        prods(i128, i64, i64, &i64s, &i64s),
        prods(i128, u64, i64, &u64s, &i64s),
        prods(u128, u32, u63, &u32s, &u63s),
        prods(i128, u63, i32, &u63s, &i32s),
        prods(i128, i8, u64, &i8s, &u64s),
    });
    std.debug.print("{x} {x} {x} {x} {x}\n", .{
        prods(u100, u64, u64, &u64s, &u64s),
        prods(i100, i64, u64, &i64s, &u64s),
        consts(u128, u64, &u64s, &.{ 0, 1, 3, 0x7fff_ffff_ffff_ffff, 0x8000_0000_0000_0000, 0xffff_ffff_ffff_ffff, 1 << 64, 0x9e37_79b9_7f4a_7c15 }),
        consts(i128, i64, &i64s, &.{ 0, 1, -1, -5, std.math.maxInt(i64), std.math.minInt(i64), 0xffff_ffff_ffff_ffff, -(1 << 64) }),
        consts(i128, u64, &u64s, &.{ -1, -7, std.math.minInt(i64), 0x8000_0000_0000_0000 }),
    });
    std.debug.print("{x} {x} {x} {x} {x} {x} {x}\n", .{
        shifts(u128, &u128s),
        shifts(i128, &i128s),
        shifts(u256, &u256s),
        shifts(i256, &i256s),
        shifts(u100, &u100s),
        shifts(i65, &i65s),
        checked(&u64s),
    });
}
