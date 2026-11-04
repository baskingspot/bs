//! exit: 0
//! stderr: "ck 2 f80fc85b71a05394\n"
//! A struct local split into one local per field, whose field is loaded
//! into the field's register before a call and used after it
//! (`sr53.f4 *%= f0()`), with the field evicted later: the load must be
//! saved around the call itself. mchunt seed 404209511455, reduced; bs
//! printed "ck 2 7ab5e0058e17341f". Prints what upstream's ReleaseSafe
//! build prints.
const std = @import("std");
const E = error{ Alpha, Beta, Gamma };
const E2 = enum(u8) { t0 = 7, t1 = 25, t2 = 132, t3 = 142 };
const S2 = extern struct { f0: u32, f1: u8, f2: i64, f3: i8, f4: i64 };
const S3 = struct { f0: u11, f1: u5, f11: [5]i64 };
var g0: [1]u16 = .{ @as(u16, 0xdf2b) };
var g1: S2 = .{ .f0 = @as(u32, 0), .f1 = @as(u8, 0), .f2 = @as(i64, 0x7fffffffffffffff), .f3 = @as(i8, 127), .f4 = @as(i64, -1) };
var g2: u9 = @as(u9, 0);
var g3: i64 = @as(i64, -0x62ccddb755ea3f1c);
var g4: bool = true;
var g5: i16 = @as(i16, 0);
var g6: bool = false;
var g7: i32 = @as(i32, -0x80000000);
var gB: S3 = .{ .f0 = @as(u11, 1), .f1 = @as(u5, 16), .f11 = .{ @as(i64, 0), @as(i64, 0x7fffffffffffffff), @as(i64, 0x7fffffffffffffff), @as(i64, -0x8000000000000000), @as(i64, 1) } };
const K0: i9 = @as(i9, 35);
var ck: u64 = 0xcbf29ce484222325;
fn mix(v: u64) void {
    ck = (ck ^ v) *% 0x100000001b3;
}
fn f0() i32 {
    var acc1: u64 = 0xdca46f02c3a83ca7;
    var ad7: [4]i8 = @splat(@as(i8, @truncate(g5)));
    const mp8: [*]i8 = &ad7;
    const q9 = mp8 + 3;
    acc1 = (acc1 ^ @as(u64, @as(u8, @bitCast((q9 - 3)[@as(usize, @as(u8, @truncate(@as(u64, @bitCast(gB.f11[@min((@as(usize, g1.f0) *% @as(usize, @as(u16, @bitCast(g5)))), 4)]))))) % 4])))) *% 0x9E3779B97F4A7C15;
    return @as(i32, @truncate(@as(i64, @bitCast(acc1))));
}
fn f1(p11: *i16) u8 {
    _ = p11;
    var acc13: u64 = 0x2e4eec855d2133f5;
        const v21: u8 = @shlWithOverflow(@as(u8, @truncate(@as(u9, @bitCast(K0)))), @as(std.math.Log2Int(u8), @truncate(@as(u64, @as(u16, 0)))))[0];
        const v23: u32 = (@as(u32, @bitCast(@as(i32, @truncate(@as(i64, @as(i8, @bitCast(v21))))))) +% 36);
        acc13 = (acc13 ^ @as(u64, v23)) *% 0x9E3779B97F4A7C15;
    return (@as(u8, @truncate(acc13)) ^ ((b25: { const l26 = @as(u8, @truncate(@as(u9, @bitCast(K0)))); break :b25 if (l26 > 0 and l26 < 127) l26 * 2 else l26; }) >> 0));
}
fn f2(p27: i64, p28: i16) usize {
    var acc31: u64 = 0x17ad367a6499ae4f;
    const lv35: i8 = @as(i8, @truncate(@as(i32, @bitCast(@as(u32, gB.f1)))));
    const lv36: i64 = (@as(i64, @as(i8, @bitCast(g1.f1))) -% @as(i64, @as(i1, @bitCast(@as(u1, @intFromBool(g6))))));
    const lv37: u9 = @as(u9, @as(u1, @intFromBool(g6)));
    const lv38: u8 = (@as(u8, @truncate(@as(u32, @bitCast(g7)))) +% @as(u8, @truncate(@as(u32, @bitCast(g7)))));
    const lv39: i9 = (@as(i9, @as(i5, @bitCast(gB.f1))) *% @as(i9, @truncate(g1.f2)));
    const lv40: u9 = (@as(u9, 1) -% 1);
    const lv41: u8 = @as(u8, @truncate(@as(u9, @as(u8, @bitCast(g1.f3)))));
    const lv42: u32 = @as(u32, @as(u16, @bitCast(p28)));
    const lv43: i16 = (@as(i16, @as(i8, @bitCast(g1.f1))) >> @as(std.math.Log2Int(i16), @truncate(@as(u64, @as(u9, gB.f1)))));
    const lv45: usize = @as(usize, 0);
    const lv46: u8 = @as(u8, @truncate(@as(u64, @bitCast(g1.f4))));
    const r47: u8 = f1(&g5); _ = r47;
    acc31 = (acc31 ^ @as(u64, lv38)) *% 0x9E3779B97F4A7C15;
    const r49: u8 = f1(&g5);
    const r51: u8 = f1(&g5);
    acc31 = (acc31 ^ @as(u64, @as(u8, @bitCast(lv35))) ^ @as(u64, @as(u64, @bitCast(lv36))) ^ @as(u64, lv37) ^ @as(u64, @as(u9, @bitCast(lv39))) ^ @as(u64, lv40) ^ @as(u64, lv41) ^ @as(u64, lv42) ^ @as(u64, @as(u16, @bitCast(lv43))) ^ @as(u64, lv45) ^ @as(u64, lv46)) *% 0x9E3779B97F4A7C15;
    var sr53: S2 = g1;
    sr53.f4 *%= @as(i64, f0());
    const sc54 = sr53;
    sr53.f4 = (std.math.add(i64, p27, @as(i64, 0x3ffffffffffffffe)) catch @as(i64, 0x4f9c6ffbf17af280));
    sr53.f3 *%= @as(i8, @as(i8, @bitCast(r49)));
    mix(@as(u64, sc54.f0));
    acc31 = (acc31 ^ @as(u64, sc54.f1)) *% 0x9E3779B97F4A7C15;
    mix(@as(u64, @as(u8, @bitCast(sc54.f3))));
    acc31 = (acc31 ^ @as(u64, @as(u64, @bitCast(sc54.f4)))) *% 0x9E3779B97F4A7C15;
    acc31 = (acc31 ^ @as(u64, @as(u64, @bitCast(sr53.f2)))) *% 0x9E3779B97F4A7C15;
    acc31 = (acc31 ^ @as(u64, @as(u64, @bitCast(sr53.f4)))) *% 0x9E3779B97F4A7C15;
    if (((@as(i16, @truncate(g7)) & 6) <= (-0x8000))) {
        const va57: @Vector(4, u16) = @Vector(4, u16){ (@as(u16, 28) +% @as(u16, g1.f1)), (g0[(@as(usize, 1) % 1)] & @as(u16, r51)), (@as(u16, gB.f1) - @as(u16, g1.f1)), (@as(u16, g2) *| @as(u16, 0xffff)) };
        const vb58: @Vector(4, u16) = @Vector(4, u16){ @mod(@as(u16, gB.f1), @max(@as(u16, @truncate(g1.f0)), 1)), @as(u16, @truncate(@as(u32, @bitCast(g7)))), @as(u16, @ctz(@as(i16, @truncate(g3)))), @as(u16, gB.f1) };
        const vr59: @Vector(4, u16) = -%vb58 +% va57;
        const vr60: @Vector(4, u16) = @select(u16, va57 < vr59, va57, vr59);
        acc31 = (acc31 ^ @as(u64, @reduce(.Add, @as(@Vector(4, u16), @clz(vr60))))) *% 0x9E3779B97F4A7C15;
    }
    return (@as(usize, acc31) ^ @bitReverse((b79: { const l80 = @as(usize, 0); break :b79 if (l80 > 0 and l80 < 0x7fffffffffffffff) l80 * 2 else l80; })));
}
inline fn f3(p81: *i32, p82: u64, p83: E2) E!i64 {
    _ = p81;
    _ = p82;
    _ = p83;
    const acc87: u64 = 0x36de953e9538c264;
    return (@as(i64, @as(i64, @bitCast(acc87))) ^ @as(i64, @as(i1, @bitCast(@as(u1, @intFromBool(g4))))));
}
pub fn main() void {
    var macc: u64 = 0;
    var m133: i32 = f0();
    m133 = ((@as(i32, @as(i1, @bitCast(@as(u1, @intFromBool(g6))))) +% @as(i32, @as(i9, @bitCast(g2)))) >> 3);
    const m135: u8 = f1(&g5);
    macc = (macc ^ @as(u64, m135)) *% 0x9E3779B97F4A7C15;
    const m137: u8 = f1(&g5);
    mix(@as(u64, m137));
    const m139: usize = f2((g3 ^ @as(i64, @as(i8, @bitCast(g1.f1)))), ((@as(i16, -1) >> 1) - (@as(i16, @as(i1, @bitCast(@as(u1, @intFromBool(g6))))) >> 1)));
    macc = (macc ^ @as(u64, m139)) *% 0x9E3779B97F4A7C15;
    const m143: usize = f2((@as(i64, @as(i1, @bitCast(@as(u1, @intFromBool(g4))))) -% gB.f11[(@as(usize, @as(u32, @bitCast(@as(i32, @as(i1, @bitCast(@as(u1, @intFromBool(g4)))))))) % 5)]), (b141: { const l142 = @as(i16, @as(i11, @bitCast(gB.f0))); break :b141 if (l142 < 0x7ffd) l142 + 2 else l142; }));
    mix(@as(u64, m143));
    std.debug.print("ck 2 {x}\n", .{ck});
    const m145: i64 = f3(&g7, (@as(u64, @as(u1, @intFromBool(g4))) -% @as(u64, @as(u32, @bitCast(g7)))), E2.t2) catch |err| switch (err) { error.Alpha => @as(i64, 0), else => @as(i64, 0x3fffffffffffffff) };
    macc = (macc ^ @as(u64, @as(u64, @bitCast(m145)))) *% 0x9E3779B97F4A7C15;
}
