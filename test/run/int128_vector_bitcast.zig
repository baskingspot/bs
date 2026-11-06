//! exit: 0
//! stderr: "pairs 2e9dcde6df2b2a32\nslots dcd1bcf85d22372\nwidened 797cd5b377e002f7\nasm eaa13e36a7fffde1\n"
//! targets: x86_64-linux aarch64-linux aarch64-macos

// u128 and i128 bitcast to and from 16-byte vectors of 2, 4 and 16 lanes:
// with the integers in register pairs, in stack slots (more live at once
// than there are pairs, and across calls), widened from 64 bits,
// constant, and as inline assembly operands.
const std = @import("std");
const builtin = @import("builtin");

const V2 = @Vector(2, u64);
const V4 = @Vector(4, u32);
const V16 = @Vector(16, u8);

fn mix(h: u64, x: u128) u64 {
    return (h ^ @as(u64, @truncate(x)) ^ @as(u64, @truncate(x >> 64))) *% 0x9e3779b97f4a7c15;
}

noinline fn pairs(a: u128, b: i128) u64 {
    const v2: V2 = @bitCast(a +% 1);
    const v4: V4 = @bitCast(b -% 3);
    const v16: V16 = @bitCast(a ^ @as(u128, @bitCast(b)));
    const x: u128 = @bitCast(v2 +% V2{ 5, 7 });
    const y: i128 = @bitCast(v4 *% @as(V4, @splat(3)));
    const z: u128 = @bitCast(v16 +% @as(V16, @splat(1)));
    var h = mix(0, x);
    h = mix(h, @bitCast(y));
    h = mix(h, z);
    // Back and forth without an operation between.
    const w: u128 = @bitCast(@as(V4, @bitCast(a)));
    const s: i128 = @bitCast(@as(V16, @bitCast(b)));
    return mix(mix(h, w), @bitCast(s));
}

noinline fn other(x: u64) u64 {
    return x *% 31 +% 7;
}

noinline fn slots(seed: u128) u64 {
    var v: [10]u128 = undefined;
    for (&v, 0..) |*e, i| e.* = seed *% (i + 3) +% (seed >> @intCast(i * 5));
    // All live across the call and across each other's bitcasts.
    const a0 = v[0] +% 1;
    const a1 = v[1] +% 2;
    const a2 = v[2] +% 3;
    const a3 = v[3] +% 4;
    const a4 = v[4] +% 5;
    const a5 = v[5] +% 6;
    const a6 = v[6] +% 7;
    const a7 = v[7] +% 8;
    const k = other(@truncate(a0));
    const b0: V2 = @bitCast(a0);
    const b1: V4 = @bitCast(a1);
    const b2: V16 = @bitCast(a2);
    const b3: V2 = @bitCast(a3);
    const b4: V4 = @bitCast(@as(i128, @bitCast(a4)));
    const b5: V16 = @bitCast(@as(i128, @bitCast(a5)));
    const b6: V2 = @bitCast(a6);
    const b7: V4 = @bitCast(a7);
    const k2 = other(k);
    var h = mix(k2, @bitCast(b0 ^ b3 ^ b6));
    h = mix(h, @bitCast(b1 +% b4 +% b7));
    h = mix(h, @bitCast(b2 -% b5));
    const c0: u128 = @bitCast(b0);
    const c1: i128 = @bitCast(b1);
    const c2: u128 = @bitCast(b2);
    h = mix(h, other(@truncate(c0 >> 3)) ^ @as(u64, @truncate(@as(u128, @bitCast(c1)) >> 70)));
    return mix(mix(h, c0 *% c2), a0 ^ a1 ^ a2 ^ a3 ^ a4 ^ a5 ^ a6 ^ a7);
}

noinline fn widened(x: u64, y: u32) u64 {
    const a: V2 = @bitCast(@as(u128, x));
    const b: V4 = @bitCast(@as(i128, @as(i32, @bitCast(y))));
    const c: V16 = @bitCast(@as(u128, 0x0102030405060708090a0b0c0d0e0f10));
    const d: V2 = @bitCast(@as(i128, -2));
    var h = mix(0, @bitCast(a +% V2{ 1, 1 }));
    h = mix(h, @bitCast(b));
    h = mix(h, @bitCast(c));
    return mix(h, @bitCast(d));
}

fn xorLanes(a: V2, b: V2) V2 {
    var x = a;
    switch (builtin.cpu.arch) {
        .x86_64 => asm ("pxor %[b], %[x]"
            : [x] "+x" (x),
            : [b] "x" (b),
        ),
        .aarch64 => asm ("eor %[x].16b, %[x].16b, %[b].16b"
            : [x] "+w" (x),
            : [b] "w" (b),
        ),
        else => unreachable,
    }
    return x;
}

noinline fn asmOperands(a: u128, b: i128, n: usize) u64 {
    var x = a;
    var y = b;
    for (0..n) |i| {
        const r = xorLanes(@bitCast(x), @bitCast(y));
        x = @bitCast(r);
        y = @bitCast(@as(V4, @bitCast(xorLanes(@bitCast(y), @bitCast(@as(u128, i))))) ^ @as(V4, @bitCast(x)));
    }
    return mix(mix(0, x), @bitCast(y));
}

pub fn main() void {
    const a: u128 = 0xfedcba9876543210_0123456789abcdef;
    const b: i128 = -0x123456789abcdef0_fedcba987654321;
    std.debug.print("pairs {x}\n", .{pairs(a, b)});
    std.debug.print("slots {x}\n", .{slots(a)});
    std.debug.print("widened {x}\n", .{widened(0x8000000000000001, 0x80000002)});
    std.debug.print("asm {x}\n", .{asmOperands(a, b, 9)});
}
