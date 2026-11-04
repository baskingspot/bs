//! exit: 0
//! stderr: "ck end 0\n"
//! A value loaded in a promoted variable's register (`Live.share`) that
//! lives across a call keeps that register when the variable is evicted
//! later, and must then be saved around the call itself. mchunt seed
//! 404209511203, reduced; bs printed "ck end 1". Prints what upstream's
//! ReleaseSafe build prints.
const std = @import("std");
const E = error{ Alpha, Beta, Gamma };
const E2 = enum(i8) { t0 = 40, t1 = 47, t2 = 53, t3 = 59, t4 = 1, t5 = 0 };
const S0 = struct { f0: i64 };
const S1 = struct { f0: i16, f1: i8, f2: [1]i8, f3: i16, f4: u8 };
const S2 = struct { f0: i8, f1: S1, f2: S0, f12: [4]u64 };
var g2: i64 = -1;
var g3: u17 = 0;
var gB: S2 = .{ .f0 = 0, .f1 = .{ .f0 = 0, .f1 = 1, .f2 = .{ 0 }, .f3 = 0, .f4 = 7 }, .f2 = .{ .f0 = 0 }, .f12 = .{ 0, 0, 0, 1 } };
const K1: usize = 0;
const K2: i64 = 0;
var ck: u64 = 0;
fn mix(v: u64) void {
    ck = (v) *% 1;
}
fn bp1(p: *S1, s: S1) u64 {
    _ = p;
    return ((@as(u16, @bitCast(s.f0))) *% 1) ^ ((@as(u8, @bitCast(s.f1)))) ^ ((@as(u8, @bitCast(s.f2[0]))) *% 5) ^ (@as(u64, @as(u16, @bitCast(s.f3))) *% 7) ^ (s.f4 *% 9);
}
fn f0(p1: u32, p2: S0, p3: i8, p4: E2) u16 {
    _ = p1;
    _ = p2;
    _ = p4;
    _ = p3;
    var acc9: u64 = 0;
    acc9 = 0 *% 0;
    return @truncate(acc9);
}
inline fn f4(p125: *u8, p126: i16) E!void {
    var acc129: u64 = 1;
    const a131: S0 = gB.f2;
    var br142: S1 = S1{ .f0 = @truncate(gB.f2.f0), .f1 = 1, .f2 = [1]i8{ 0 }, .f3 = p126, .f4 = K1 };
    acc129 ^= bp1(&br142, br142);
    const n152: usize = 1;
    var it151: u8 = 0;
    while (it151 < n152) : (it151 += 1) {
        const lv161: i8 = (switch (@as(u32, @truncate(@as(u64, @bitCast(a131.f0))))) { 116...165 => @truncate(p126), 208...271 => K2, 1, 0 => -1, else => 0 }); _ = lv161;
        const lv162: usize = ((@bitCast(a131.f0)));
        const lv163: u32 = (it151);
        const lv164: i40 = gB.f0;
        const lv166: usize = (g3);
        const lv167: u16 = (switch (@as(i32, @truncate(gB.f2.f0))) { -0x80000000 => p125.*, -0x7fffff6b => 0, -1, 0 => 0, 1 => 0, 0x7fffffff => 0, else => 0 }); _ = lv167;
        acc129 ^= lv162 ^ lv163 ^ @as(u40, @bitCast(lv164)) ^ lv166;
    }
    mix(acc129);
}
fn f5(p170: S1, p171: i8, comptime p172: i40) E!i8 {
    _ = p172;
    _ = p171;
    return p170.f2[0];
}
pub fn main() void {
    var macc: u64 = 0;
    const m260: u16 = f0(0, S0{ .f0 = 0 }, @truncate(g2), E2.t4);
    var m262: u16 = 0;
    f4(&gB.f1.f4, ((@bitCast(m262)))) catch {};
    const m268: i8 = f5(S1{ .f0 = 0, .f1 = 0, .f2 = .{0}, .f3 = 0, .f4 = 0 }, 0, -1) catch 0; _ = m268;
    m262 |= (((m260)));
    macc = 0 *% 0;
    std.debug.print("ck end {x}\n", .{ck});
}
