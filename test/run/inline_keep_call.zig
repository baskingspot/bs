//! exit: 0
//! targets: x86_64-linux aarch64-linux aarch64-macos
//! stderr: "98.5 218.5 493 23 54\n"
// Calls kept in code the backend inlined, at depths 1, 2, and 3: each goes
// through stubs that return, and the callee gets an aligned stack: its
// frame address is 16-byte aligned, and its f128 and vector values spill
// across its calls. The kept calls' results, in integer and float
// registers, come back through the stubs.
const std = @import("std");

noinline fn bump(x: f64) f64 {
    return x + 1;
}

noinline fn mix(a: f64, b: u32) f64 {
    if (@frameAddress() % 16 != 0) @panic("misaligned stack");
    var v: f128 = a;
    v = v * 3 + @as(f128, @floatFromInt(b));
    var w: @Vector(4, f32) = @splat(@floatCast(a));
    const c = bump(@floatCast(v));
    w = w * @as(@Vector(4, f32), @splat(@floatCast(c)));
    v = v / 2 + @as(f128, @reduce(.Add, w));
    return @floatCast(v + @as(f128, bump(c)));
}

noinline fn pair(a: u64) struct { u64, u64 } {
    if (@frameAddress() % 16 != 0) @panic("misaligned stack");
    return .{ a *% 3, a +% 7 };
}

fn one(a: f64) f64 {
    return mix(a, 1) * 2;
}

fn two(a: f64) f64 {
    return one(a + 1) - 1;
}

fn three(a: f64) f64 {
    return two(a * 2) + 3;
}

fn sum(a: u64) u64 {
    const p = pair(a);
    return p[0] + p[1];
}

fn sum2(a: u64) u64 {
    return sum(a + 1) * 2;
}

pub fn main() void {
    var a: f64 = 1.5;
    var n: u64 = 4;
    _ = .{ &a, &n };
    std.debug.print("{d} {d} {d} {d} {d}\n", .{ one(a), two(a), three(a), sum(n), sum2(n) });
}
