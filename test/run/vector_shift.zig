//! exit: 0
//! stdout: "4677605232285930260\n4677605232285930260\n193328559537025888\n193328559537025888\n10774758675848779400\n10774758675848779400\n7634351645255654784\n7634351645255654784\n4677605232285930260\n4677605232285930260\n4604463406903522144\n4604463406903522144\n11272524194738223072\n11272524194738223072\n3091589608818368384\n3091589608818368384\n47615592481078\n47615592481078\n18446732495240849995\n18446732495240849995\n888329859\n888329859\n621114264\n621114264\n18446744073317079860\n18446744073317079860\n18446744073709521794\n18446744073709521794\n18446744060192346572\n18446744060192346572\n18446744073709551615\n18446744073709551615\n15047281494068570048\n15047281494068570048\n10616774372579262616\n10616774372579262616\n4748548425591182099\n4748548425591182099\n0\n0\n18168355408325890508\n18168355408325890508\n0\n0\n18446743813725658739\n18446743683148266111\n123447086782\n1842009164032\n"
// Vector `<<` and `>>` by an amount that is the same in every lane,
// lowered as SSE shifts: by a constant (an immediate) and by a runtime
// `@splat` (a count register). Bytes shift as masked words, signed bytes
// as the high bytes of words, and signed 64-bit lanes with their sign
// shifted in, so each of those is tested at amounts 0, 1 and the largest.
// Each line folds a vector's lanes into one number.
const std = @import("std");
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn fold(comptime T: type, comptime n: usize, v: @Vector(n, T)) u64 {
    const a: [n]T = v;
    var h: u64 = 0;
    for (a) |x| h = h *% 31 +% @as(u64, @bitCast(@as(i64, @as(@Int(.signed, @bitSizeOf(T)), @bitCast(x)))));
    return h;
}

noinline fn bytes(comptime T: type, comptime n: usize) @Vector(n, T) {
    var a: [n]T = undefined;
    for (&a, 0..) |*x, i| x.* = @bitCast(@as(@Int(.unsigned, @bitSizeOf(T)), @truncate(i *% 0x9e3779b97f4a7c15 >> 7)));
    return a;
}

noinline fn amount(comptime T: type, k: std.math.Log2Int(T)) std.math.Log2Int(T) {
    return k;
}

/// `v << k` and `v >> k` by constant `k` and by the same amount at run
/// time.
fn both(comptime T: type, comptime n: usize, v: @Vector(n, T), comptime k: std.math.Log2Int(T)) void {
    const r = amount(T, k);
    rt.printInt(fold(T, n, v << @splat(k)) *% 3 +% fold(T, n, v >> @splat(k)));
    rt.printInt(fold(T, n, v << @splat(r)) *% 3 +% fold(T, n, v >> @splat(r)));
}

fn main() callconv(.c) noreturn {
    // Two chunks of bytes, and an odd length.
    inline for (.{ 0, 1, 3, 7 }) |k| both(u8, 32, bytes(u8, 32), k);
    inline for (.{ 0, 1, 5, 7 }) |k| both(i8, 32, bytes(i8, 32), k);
    inline for (.{ 1, 9, 15 }) |k| both(u16, 8, bytes(u16, 8), k);
    inline for (.{ 1, 9, 15 }) |k| both(i16, 5, bytes(i16, 5), k);
    inline for (.{ 1, 31 }) |k| both(i32, 3, bytes(i32, 3), k);
    inline for (.{ 0, 1, 33, 63 }) |k| both(i64, 4, bytes(i64, 4), k);
    inline for (.{ 1, 63 }) |k| both(u64, 3, bytes(u64, 3), k);
    // std.math.rotr on vectors, as BLAKE3 uses it.
    const V = @Vector(4, u32);
    rt.printInt(fold(u32, 4, std.math.rotr(V, bytes(u32, 4), 7)));
    rt.printInt(fold(u32, 4, std.math.rotl(V, bytes(u32, 4), amount(u32, 12))));
    // Exact shifts that shift out only zeros keep their checks.
    const lo = bytes(u32, 4) >> @splat(4) << @splat(4);
    rt.printInt(fold(u32, 4, @shrExact(lo, @splat(amount(u32, 4)))));
    rt.printInt(fold(u32, 4, @shlExact(lo >> @splat(8), @splat(amount(u32, 8)))));
    rt.exit(0);
}
