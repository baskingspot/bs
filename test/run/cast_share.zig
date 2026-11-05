//! exit: 0
//! stderr: "ffffffff 7fffffff fffffffe 1 ffffffff 0 fffffffe00000001 fffffffe00000001 ffffffffffffffac ffffffff -1 2147483647 0 7f ffffffffffffffff 7ffffffe80000002\n"
//! Casts that emit no instruction. A truncation of an unsigned value
//! shifted right or masked to fewer bits than the result is the value's
//! register (`valueBits`), but one that still has a high bit set must
//! clear it, which a later widening would show. A widening whose operand
//! stays live shares the operand's register (`planCasts`) unless its user
//! computes into it, which would overwrite the operand: here the operand
//! is read again after the multiply, under pressure and across calls.
const std = @import("std");

var g: u64 = 0xffff_ffff_ffff_fffe;
var g32: u32 = 0xffff_ffff;
var s32: i32 = -1;
var k: [8]u64 = .{ 3, 5, 7, 11, 13, 17, 19, 23 };

noinline fn id(x: u64) u64 {
    return x;
}

noinline fn truncs() void {
    const x = g;
    // 33 bits survive a shift by 31; the result's register must lose bit 32.
    const t31: u32 = @truncate(x >> 31);
    const w31: u64 = t31;
    const t33: u32 = @truncate(x >> 33);
    const w33: u64 = t33;
    const t32: u32 = @truncate(x >> 32);
    const m33: u32 = @truncate(x & 0x1_ffff_ffff);
    const wm33: u64 = m33;
    const m32: u32 = @truncate(x & 0xffff_ffff);
    std.debug.print("{x} {x} {x} {x} {x} {x} ", .{ w31, w33, wm33, (x >> 63), t32, @as(u64, m32) >> 32 });
}

noinline fn widens() void {
    const y = g32;
    const a = k[0];
    // The widening is the multiply's first operand, which imul overwrites.
    const p = @as(u64, y) *% id(@as(u64, y));
    // The widening is the second operand; y stays live.
    const q = id(p) *% 0 +% id(@as(u64, y)) *% @as(u64, y);
    var acc: u64 = 0;
    // Pressure: eight live values across the loop.
    const v0 = k[0] *% a;
    const v1 = k[1] *% a;
    const v2 = k[2] *% a;
    const v3 = k[3] *% a;
    const v4 = k[4] *% a;
    const v5 = k[5] *% a;
    const v6 = k[6] *% a;
    const v7 = k[7] *% a;
    for (0..2) |i| acc +%= @as(u64, y) *% (i + 1);
    acc +%= v0 +% v1 +% v2 +% v3 +% v4 +% v5 +% v6 +% v7;
    std.debug.print("{x} {x} {x} {x} ", .{ p, q, acc -% 3 *% @as(u64, y) -% 3 *% 0x7e, y });
}

noinline fn signed() void {
    const z = s32;
    const w: i64 = z;
    const n: i64 = -%@as(i64, z) *% 0x7fff_ffff;
    std.debug.print("{d} {d} {d} {x} ", .{ w, n, @as(i64, z) - w, @as(u64, @bitCast(w)) >> 57 });
}

noinline fn mixed() void {
    const lo: u32 = g32;
    const hi: u32 = @truncate(g >> 32);
    const w: u64 = @as(u64, hi) << 32 | lo;
    const m = @as(u64, lo >> 1) *% @as(u64, hi) +% (@as(u64, lo) >> 31);
    std.debug.print("{x} {x}\n", .{ w, m });
}

pub fn main() void {
    truncs();
    widens();
    signed();
    mixed();
}
