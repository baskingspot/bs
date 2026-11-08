//! exit: 0
//! stderr: "10 2468acf13579bdfffffffffffffffd0 fdb97530eca864200000000000000030 369d0369d0369cfffffffffffffffe00 20 123456789abcdefffffffffffffffff 8123456676543211fedcba987654321f 7edcba9a7654320e0123456789abcdff \n10 fdb97530eca864200000000000000030 2468acf13579bdfffffffffffffffd0 369d0369d0369cfffffffffffffffe00 20 fedcba9876543210000000000000002f 7edcba9989abcdee0123456789abcdcf 8123456989abcdee0123456789abcdcf \n123456789abcdeffffffffffffffff1 123456789abcdeefffffffffffffff1 8acf135789abcdefffffffeffffffff0 ddc927501a9e732fedcba98765432110 123456789abcdf0fffffffffffffff0 7edcba987654320f8000000000000010 \nfdb97530eca864200000000000000040 100000000000000000 200000000000000000 400000000000000000 0 7f6e5d4c3b2a19080000000000000010 fedcba9876543210 fedcba9 fffffffff6e5d4c3b2a19087f6e5d4c4 ffffffffffffffffffffffffdb97530e ffffffffffffffffffffffffedcba987 ffffffffffffffffffffffffffffffff \n110001110001 110001110001 001101001100 010110010111 \n123456789abcdeffffffffffffffff0 deadbeefcafebabe ffffffffffffffffffffffffffffffb3 ffffffffedcba9876543210fedcba988 ffffffff 19400000000000000000 ffffffffffffffffffffffffffffff88 \n84eea2ede509f5e59223703b7d266e40\n11 2468acf13579bdfffffffffffffffd1 a3d70a3d70a3d6fffffffffffffffa01 1 ffffffffdb97530eca86421fdb97530f de 0 1 2 90fd0056bbeb9f92d0546341327b60 \nff0123456789abce000000000000001e feb851eb851eb8520000000000000022 147ae147ae147adfffffffffffffff41 1 2468acf13579bde02468acf1 6f 0 0 2 121fa00ad77d73f25a0a8c68264f6c \n39f7e3b890d7814b79825911e87d70b6\n369d0369d0369cfffffffffffffffe00 2468acf13579bdfffffffffffffffd0\n6a23bb3dcede7315 6a23bb3dcede7315\n"
//! 128-bit integers in register pairs (`int128`): each operation with
//! register, memory and constant operands, constants whose halves do
//! not fit an immediate, carries and borrows across the halves, shifts
//! on both sides of 64, signed and unsigned comparisons that differ only
//! in the high half or only in the low one, enough live values that
//! some stay in memory, and a truncation in a loop of a shift before it.
const std = @import("std");

const big: u128 = 0x8000_0001_ffff_fffe_0123_4567_89ab_cdef;

noinline fn arith(a: u128, b: u128) [8]u128 {
    return .{
        a +% b,
        a -% b,
        b -% a,
        a *% b,
        a & b,
        a | ~b,
        a ^ big,
        big -% a,
    };
}

noinline fn consts(a: u128) [6]u128 {
    return .{
        a +% 1,
        a -% 0xffff_ffff_ffff_ffff,
        a *% 0x1_0000_0001,
        a *% big,
        a +% (1 << 64),
        0x7fff_ffff_ffff_ffff_8000_0000_0000_0000 -% a,
    };
}

noinline fn shifts(a: u128, s: i128) [12]u128 {
    return .{
        a << 1,  a << 63,  a << 64,          a << 65,           a << 127,          a >> 1,
        a >> 64, a >> 100, @bitCast(s >> 1), @bitCast(s >> 63), @bitCast(s >> 64), @bitCast(s >> 127),
    };
}

noinline fn compare(a: u128, b: u128, x: i128, y: i128) [12]bool {
    return .{
        a < b, a <= b, a > b, a >= b, a == b, a != b,
        x < y, x <= y, x > y, x >= y, x == y, x < -1,
    };
}

noinline fn casts(a: u128, x: i128, w: u64, v: i64, n: u7) [7]u128 {
    return .{
        @truncate(a),
        @as(u128, w),
        @bitCast(@as(i128, v)),
        @bitCast(x),
        @as(u32, @truncate(a >> 32)),
        @as(u128, n) << 70,
        @bitCast(@as(i128, @as(i8, @truncate(x)))),
    };
}

/// A promoted variable, carried around a loop with many live values.
noinline fn loop(seed: u64, n: u32) u128 {
    var acc: u128 = seed;
    var b: u128 = big;
    var c: u128 = @as(u128, seed) << 64;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const t = acc *% b +% c;
        c = (c >> 3) ^ t;
        b = b +% (t >> 64) +% 1;
        acc = t ^ (b << 7);
    }
    return acc ^ b ^ c;
}

/// Overflow operations: the value and the bit, read right away, kept as a
/// tuple, or branched on; multiplications that overflow in each of
/// their ways (both high halves set, a cross product's high half, the
/// cross sum's carry, the carry into the high half) and that do not.
noinline fn ovf(a: u128, b: u128, x: i128, y: i128) [10]u128 {
    const s = @addWithOverflow(a, b);
    const d = @subWithOverflow(a, b);
    const m = @mulWithOverflow(a, b);
    const t = @addWithOverflow(x, y);
    var keep = @subWithOverflow(x, y);
    _ = &keep;
    const br: u128 = if (@addWithOverflow(a, a)[1] == 1) 111 else 222;
    return .{
        s[0] ^ s[1],                            d[0] +% d[1], m[0] *% 3 +% m[1], @as(u128, @bitCast(t[0])) +% t[1],
        @as(u128, @bitCast(keep[0])) ^ keep[1], br,
        @mulWithOverflow(a >> 64, b >> 70)[1], // high halves only: fits or not
        @mulWithOverflow(a & 0xffff_ffff_ffff_ffff, b)[1],
        @mulWithOverflow(@as(u128, 0xffff_ffff_ffff_ffff), @as(u128, 0x1_0000_0001) << 31)[1] + @as(u128, @mulWithOverflow(a | 1, @as(u128, 1) << 64)[1]) * 2,
        @mulWithOverflow(a >> 66, b >> 63)[0],
    };
}

/// A sum of checked products, as curve25519's `Fe.mul` computes.
noinline fn dot(l: [3]u64, r: [3]u64) u128 {
    var acc: u128 = 0;
    for (l, r) |p, q| acc += @as(u128, p) * q;
    return acc;
}

/// A truncation inside a loop of a right shift before it: the shifted
/// value lives through the loop, also when it is a variable's (which
/// `Ssa.plan` forwards).
inline fn truncLoop(s: u128, g: u64, n: usize) u64 {
    var k: u64 = 0;
    for (0..n) |i| {
        const t: u64 = @as(u32, @truncate(s));
        const c1 = g *% (i +% 1);
        const c2 = g *% (i +% 2);
        const c3 = g *% (i +% 3);
        const c4 = g *% (i +% 4);
        const c5 = g *% (i +% 5);
        const c6 = g *% (i +% 6);
        const c7 = g *% (i +% 7);
        const c8 = g *% (i +% 8);
        const c9 = g *% (i +% 9);
        const c10 = g *% (i +% 10);
        const c11 = g *% (i +% 11);
        const c12 = g *% (i +% 12);
        k +%= t ^ (c1 *% c2) ^ (c3 *% c4) ^ (c5 *% c6) ^ (c7 *% c8) ^ (c9 *% c10) ^ (c11 *% c12);
    }
    return k;
}
noinline fn shrBeforeLoop(a: u128, b: u128, g: u64, n: usize) u64 {
    const w = a ^ b;
    return truncLoop(w >> 70, g, n);
}
noinline fn shrBeforeLoopVar(a: u128, b: u128, g: u64, n: usize) u64 {
    var w = a ^ b;
    _ = &w;
    return truncLoop(w >> 70, g, n);
}

const Pair = struct { x: u128, y: u128 };
noinline fn fields(p: *const Pair, q: *Pair) void {
    q.x = p.x *% p.y;
    q.y = p.x -% p.y;
}

pub fn main() void {
    var a: u128 = 0x0123_4567_89ab_cdef_ffff_ffff_ffff_fff0;
    var b: u128 = 0xfedc_ba98_7654_3210_0000_0000_0000_0020;
    var x: i128 = -0x1234_5678_9abc_def0_1234_5678;
    var y: i128 = 0x1234_5678_9abc_def0_1234_5679;
    var w: u64 = 0xdead_beef_cafe_babe;
    var v: i64 = -77;
    var n: u7 = 101;
    var iters: usize = 3;
    _ = .{ &a, &b, &x, &y, &w, &v, &n, &iters };
    for (arith(a, b)) |r| std.debug.print("{x} ", .{r});
    std.debug.print("\n", .{});
    for (arith(b, a)) |r| std.debug.print("{x} ", .{r});
    std.debug.print("\n", .{});
    for (consts(a)) |r| std.debug.print("{x} ", .{r});
    std.debug.print("\n", .{});
    for (shifts(b, x)) |r| std.debug.print("{x} ", .{r});
    std.debug.print("\n", .{});
    // Equal high halves, then equal low halves.
    const lo_only = a +% 5;
    const hi_only = a +% (@as(u128, 3) << 64);
    for ([_][4]u128{ .{ a, b, @bitCast(x), @bitCast(y) }, .{ a, lo_only, @bitCast(x), @bitCast(x +% 5) }, .{ hi_only, a, @bitCast(y), @bitCast(x) }, .{ a, a, @bitCast(x), @bitCast(x) } }) |c| {
        for (compare(c[0], c[1], @bitCast(c[2]), @bitCast(c[3]))) |r| std.debug.print("{d}", .{@intFromBool(r)});
        std.debug.print(" ", .{});
    }
    std.debug.print("\n", .{});
    for (casts(a, x, w, v, n)) |r| std.debug.print("{x} ", .{r});
    std.debug.print("\n{x}\n", .{loop(w, 1000)});
    for (ovf(a, b, x, y)) |r| std.debug.print("{x} ", .{r});
    std.debug.print("\n", .{});
    for (ovf(b, a >> 3, y, x)) |r| std.debug.print("{x} ", .{r});
    std.debug.print("\n{x}\n", .{dot(.{ w, ~w, 3 }, .{ ~w, w, w })});
    const p: Pair = .{ .x = a, .y = b };
    var q: Pair = undefined;
    fields(&p, &q);
    std.debug.print("{x} {x}\n", .{ q.x, q.y });
    std.debug.print("{x} {x}\n", .{ shrBeforeLoop(a, b, w, iters), shrBeforeLoopVar(a, b, w, iters) });
}
