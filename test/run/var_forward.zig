//! exit: 0
//! stdout: "loop 60\nmerge 4243039992\nescape 11\nfall 10 255\nundef 42 0\nwide ffff\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux
//! `Ssa.plan` forwards a variable whose one value store dominates its
//! loads, and keeps the others variables.
const std = @import("std");

/// Stored once before a loop, read inside it: forwarded.
noinline fn loop(n: u32, k: u32) u32 {
    var x: u32 = undefined;
    x = k * 3;
    var sum: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) sum += x;
    return sum;
}

/// Stored in one branch only, read after the merge: not forwarded. The
/// value is computed in the branch, which runs in the first iteration
/// only; later ones read it from the variable.
noinline fn merge(n: u32, k: u32) u32 {
    var x: u32 = undefined;
    var sum: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (i == 0) x = k *% 3 +% 1;
        sum +%= x ^ i;
        sum = sum *% 31 +% i *% k;
    }
    return sum;
}

noinline fn bump(p: *u32) void {
    p.* += 1;
}

/// Stored once, but its address escapes: not forwarded.
noinline fn escape(a: u32) u32 {
    var x: u32 = a;
    bump(&x);
    return x;
}

/// `i += 1` after an overflow check that passes into the next block.
noinline fn fall(a: u8) [2]u8 {
    var i: u8 = a;
    if (i < 255) i += 1;
    var j: u8 = a;
    j +|= 250;
    return .{ i, j };
}

/// An undefined store, then the value store: forwarded, and the
/// undefined store goes too.
noinline fn undef(a: u32, b: u32) [2]u32 {
    var x: u32 = undefined;
    var y: u32 = undefined;
    x = a + b;
    y = x - a - b;
    return .{ x, y };
}

var wide_y: u16 = 0xffff;
var wide_zero: usize = 0;

/// A variable read as a factor of a 128-bit product, whose cast x86_64's
/// `planMulWide` does not emit: the value stored lives until the product
/// (tools/mchunt xm-2 seed 25000113, minimized).
noinline fn wideFactor() u16 {
    var acc: u64 = 0;
    var k: u64 = 0;
    const a: u32 = @truncate(wide_zero);
    var x: u48 = 1;
    _ = &x;
    var y: u64 = wide_y;
    _ = &y;
    const p: u128 = @as(u128, y) * x;
    k = @truncate(p);
    const sq = x *% x;
    _ = sq;
    const o = @mulWithOverflow(a, a);
    const s = o[0];
    _ = s;
    acc = k;
    var c: u64 = 0;
    const l: u64 = wide_zero;
    c +%= l;
    return @truncate(acc);
}

pub fn main(init: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const w = &fw.interface;
    try w.print("loop {}\n", .{loop(4, 5)});
    try w.print("merge {}\n", .{merge(6, 9)});
    try w.print("escape {}\n", .{escape(10)});
    const f = fall(9);
    try w.print("fall {} {}\n", .{ f[0], f[1] });
    const u = undef(40, 2);
    try w.print("undef {} {}\n", .{ u[0], u[1] });
    try w.print("wide {x}\n", .{wideFactor()});
    try w.flush();
}
