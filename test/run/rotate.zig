//! exit: 0
//! stdout: "13163660794882078655\n897170929\n63933\n223\n7460683158682411845\n10002234564411262093\n4294967292\n10166205622844374018\n12377850\n11760917740897211756\n"
//! `x << k | x >> (bits - k)` on unsigned integers is a rotate: std.math's
//! rotl and rotr at each register width, the operands in either order,
//! and near misses that must stay shifts (amounts that do not add up to
//! the width, signed operands, a shift used twice), and shifts before a
//! loop whose `or` is inside it. Each case prints what
//! upstream's ReleaseSafe build prints.
const std = @import("std");
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

noinline fn r64(x: u64) u64 {
    return std.math.rotl(u64, x, 13) ^ std.math.rotr(u64, x, 7);
}
noinline fn r32(x: u32) u32 {
    return std.math.rotl(u32, x, 5);
}
noinline fn r16(x: u16) u16 {
    return std.math.rotr(u16, x, 3);
}
noinline fn r8(x: u8) u8 {
    return std.math.rotl(u8, x, 1);
}
noinline fn swapped(x: u64) u64 {
    return (x >> 40) | (x << 24);
}
noinline fn shortBy1(x: u64) u64 {
    return (x << 17) | (x >> 46);
}
noinline fn signed(x: i32) i32 {
    return (x << 3) | (x >> 29);
}
noinline fn reused(x: u64) u64 {
    const a = x << 9;
    return (a | (x >> 55)) +% a;
}
noinline fn odd(x: u24) u24 {
    return std.math.rotl(u24, x, 4);
}
/// Shifts before a loop and their `or` inside it: `x` lives through the
/// loop.
noinline fn beforeLoop(x: u64, g: u64, n: usize) u64 {
    const a = x << 13;
    const b = x >> 51;
    var k: u64 = 0;
    for (0..n) |i| {
        const c1 = g *% (i + 7);
        const c2 = g *% (i + 9);
        const c3 = g *% (i + 11);
        const c4 = g *% (i + 13);
        const c5 = g *% (i + 15);
        const c6 = g *% (i + 17);
        const c7 = g *% (i + 19);
        const c8 = g *% (i + 21);
        const c9 = g *% (i + 23);
        k +%= (a | b) ^ c1 ^ (c2 +% c3) ^ (c4 *% c5) ^ (c6 -% c7) ^ (c8 | c9);
    }
    return k;
}

fn main() callconv(.c) noreturn {
    var x: u64 = 0x0123456789abcdef;
    _ = &x;
    rt.printInt(r64(x));
    rt.printInt(r32(@truncate(x)));
    rt.printInt(r16(@truncate(x)));
    rt.printInt(r8(@truncate(x)));
    rt.printInt(swapped(x));
    rt.printInt(shortBy1(x));
    rt.printInt(@as(u32, @bitCast(signed(@bitCast(@as(u32, @truncate(x)))))));
    rt.printInt(reused(x));
    rt.printInt(odd(@truncate(x)));
    var n: usize = 3;
    _ = &n;
    rt.printInt(beforeLoop(x, 0x800000000020, n));
    rt.exit(0);
}
