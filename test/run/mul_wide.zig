//! exit: 0
//! stdout: "15452995756747027501\n8521359185914962729\n12943501610297713215\n16208769155697429837\n11990335419632110704\n7138415690893298235\n11752689941954008201\n17063800578687887122\n230792525718168017\n14276831381786596470\n"
//! A 128-bit product of two unsigned values of at most 64 bits is one
//! `mul` (Wyhash's mum, std.math.mulWide), with its halves read straight
//! from rdx:rax. Factors narrower than 64 bits, constants with the top
//! bit set, a product used whole, a shift by 64 that is kept, a product
//! live across a call, and near misses that must stay 128-bit
//! arithmetic (signed factors, a factor over 64 bits, a shift by 63).
//! Each case prints what upstream's ReleaseSafe build prints.
const std = @import("std");
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

noinline fn mum(a: *u64, b: *u64) void {
    const x = @as(u128, a.*) *% b.*;
    a.* = @truncate(x);
    b.* = @truncate(x >> 64);
}
noinline fn narrow(a: u64, b: u32, c: u8) u64 {
    const x = std.math.mulWide(u64, a, b);
    const y = @as(u128, c) *% a;
    return @as(u64, @truncate(x >> 64)) ^ @as(u32, @truncate(x)) ^ @as(u64, @truncate(y >> 64)) ^ @as(u64, @truncate(y));
}
noinline fn konst(a: u64) u64 {
    const x = @as(u128, a) *% 0xe7037ed1a0b428db;
    return @as(u64, @truncate(x >> 64)) +% @as(u64, @truncate(x));
}
noinline fn whole(a: u64, b: u64) u128 {
    const x = @as(u128, a) *% b;
    return x +% (x >> 64);
}
noinline fn other(x: u64) u64 {
    return x *% 3;
}
noinline fn acrossCall(a: u64, b: u64) u64 {
    const x = @as(u128, a) *% b;
    const k = other(a);
    return @as(u64, @truncate(x >> 64)) ^ @as(u64, @truncate(x)) ^ k;
}
noinline fn signed(a: i64, b: i64) u64 {
    const x = @as(i128, a) *% b;
    return @as(u64, @truncate(@as(u128, @bitCast(x)) >> 64));
}
noinline fn wide(a: u128, b: u64) u64 {
    const x = a *% b;
    return @truncate(x >> 64);
}
noinline fn by63(a: u64, b: u64) u64 {
    const x = @as(u128, a) *% b;
    return @truncate(x >> 63);
}

fn main() callconv(.c) noreturn {
    var a: u64 = 0x9e3779b97f4a7c15;
    var b: u64 = 0xbf58476d1ce4e5b9;
    mum(&a, &b);
    rt.printInt(a);
    rt.printInt(b);
    rt.printInt(narrow(a, @truncate(b), @truncate(b >> 32)));
    rt.printInt(konst(b));
    const w = whole(a, b);
    rt.printInt(@truncate(w));
    rt.printInt(@truncate(w >> 64));
    rt.printInt(acrossCall(a, b));
    rt.printInt(signed(@bitCast(a), @bitCast(b)));
    rt.printInt(wide(@as(u128, a) << 32 | b, b));
    rt.printInt(by63(a, b));
    rt.exit(0);
}
