//! exit: 0
//! stderr: "many b86b44fdbe971fe3\ncalls ff11b1274f604e3\nloop 995e5ee3c34409a7\nshort d6bcc89073567f5b\nfused 49932c7b3f9e0d1\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux

// Vectors held in vector registers across the shapes where a register
// class goes wrong: more live vectors than registers, vectors live across
// calls (a function, compiler_rt's f128 division and i128 multiply, libm),
// which clobber the caller-saved vector registers, vectors carried
// around a loop, short vectors whose registers hold other bytes, and
// bitcasts fused with the load or store next to them.
const std = @import("std");

const V = @Vector(4, u32);
const B = @Vector(16, u8);

var seed: u64 = 0x2545f4914f6cdd1d;

noinline fn vec() V {
    var a: [4]u32 = undefined;
    for (&a) |*x| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        x.* = @truncate(seed >> 29);
    }
    return a;
}

var h: u64 = 0xcbf29ce484222325;

fn mix(v: anytype) void {
    const a: [@typeInfo(@TypeOf(v)).vector.len]@typeInfo(@TypeOf(v)).vector.child = v;
    for (a) |x| h = (h ^ x) *% 0x100000001b3;
}

/// Sixteen vectors live at once, more than the vector registers.
noinline fn many() void {
    var vs: [16]V = undefined;
    inline for (&vs, 0..) |*v, i| v.* = vec() +% @as(V, @splat(i));
    const v0 = vs[0] *% vs[1];
    const v1 = vs[2] ^ vs[3];
    const v2 = vs[4] -% vs[5];
    const v3 = vs[6] | vs[7];
    const v4 = @max(vs[8], vs[9]);
    const v5 = vs[10] & vs[11];
    const v6 = vs[12] +% vs[13];
    const v7 = @min(vs[14], vs[15]);
    const w0 = v0 +% v1;
    const w1 = v2 ^ v3;
    const w2 = v4 -% v5;
    const w3 = v6 *% v7;
    const x0 = (w0 << @splat(3)) ^ (w1 >> @splat(5));
    const x1 = w2 +% w3;
    mix(x0 ^ x1);
    mix(v0 +% v1 +% v2 +% v3 +% v4 +% v5 +% v6 +% v7);
    mix(w0 ^ w1 ^ w2 ^ w3);
}

noinline fn bump(x: u32) u32 {
    return x *% 3 +% 1;
}

/// Vectors defined before calls and used after them.
noinline fn calls(a: f128, b: f128, c: i128, d: i128, e: f64) void {
    const v = vec();
    const w = vec() *% v;
    const q = a / b; // __divtf3
    const p = c *% d; // __multi3
    const s = @sin(e); // libm
    const n = bump(@truncate(@as(u128, @bitCast(p))));
    const r = v +% w +% @as(V, @splat(n)) +% @as(V, @splat(@as(u32, @intFromFloat(@abs(s) * 1000))));
    mix(r ^ @as(V, @splat(@as(u32, @intFromFloat(q)))));
    const bv: B = @bitCast(r);
    mix(bv +% @as(B, @splat(7)));
}

/// Vectors carried around a loop.
noinline fn loop(n: usize) void {
    var acc: V = @splat(1);
    var x = vec();
    for (0..n) |i| {
        acc = acc *% x +% @as(V, @splat(@as(u32, @intCast(i))));
        x = (x << @splat(1)) ^ (x >> @splat(3));
        if (@reduce(.Or, acc == @as(V, @splat(0)))) acc +%= @splat(1);
    }
    mix(acc);
    mix(x);
}

/// Vectors of less than 16 bytes, whose registers hold anything past
/// their bytes (a splat fills the register), reduced.
noinline fn short(x: u16, y: u8) void {
    const a: @Vector(1, u16) = @splat(x);
    const b: @Vector(2, u8) = @splat(y);
    const c: @Vector(2, u32) = @splat(@as(u32, x) *% 3 +% 1);
    const d = b +% @as(@Vector(2, u8), .{ 1, 2 });
    const r = [_]u64{
        @reduce(.Add, a), @reduce(.Mul, a), @reduce(.Max, a),
        @reduce(.Add, b), @reduce(.Xor, d), @reduce(.Min, d),
        @reduce(.Add, c), @reduce(.And, c), @reduce(.Mul, c),
    };
    for (r) |v| h = (h ^ v) *% 0x100000001b3;
}

const S = struct { a: @Vector(8, i8), b: u8 };

/// Bitcasts next to the load or store they fuse with: vectors loaded from
/// arrays and stored into them, and a load, a bitcast and a store in a
/// row into a vector variable.
noinline fn fused(src: []const u8, dst: []u8, wide: []u32, sp: *const S) void {
    const v: B = src[0..16].*;
    dst[0..16].* = v +% @as(B, @splat(1));
    const w: @Vector(16, u32) = v;
    wide[0..16].* = w;
    var acc: @Vector(1, i64) = .{5};
    var n: usize = src.len % 3 + 1;
    while (n != 0) : (n -= 1) acc = @bitCast(sp.a);
    for (dst[0..16]) |x| h = (h ^ x) *% 0x100000001b3;
    for (wide[0..16]) |x| h = (h ^ x) *% 0x100000001b3;
    h = (h ^ @as(u64, @bitCast(acc[0]))) *% 0x100000001b3;
}

pub fn main() void {
    many();
    std.debug.print("many {x}\n", .{h});
    calls(1000.5, 3.25, 0x1234_5678_9abc, -0x3141_5926, 0.75);
    std.debug.print("calls {x}\n", .{h});
    loop(1000);
    std.debug.print("loop {x}\n", .{h});
    short(0x1234, 0x56);
    std.debug.print("short {x}\n", .{h});
    var src: [24]u8 = undefined;
    for (&src, 0..) |*x, i| x.* = @truncate(i *% 37 +% 11);
    var dst: [16]u8 = undefined;
    var wide: [16]u32 = undefined;
    const s: S = .{ .a = .{ -128, -1, 8, -17, -19, -81, -1, 17 }, .b = 3 };
    fused(&src, &dst, &wide, &s);
    std.debug.print("fused {x}\n", .{h});
}
