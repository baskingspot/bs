//! exit: 0
//! stderr: "ok 1000\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux

// Values get registers in functions with inline assembly: values that
// meet an assembly statement (its operands, its result, those live across
// it) keep out of the registers it names, pins, clobbers, or takes for
// operands. The statements sit in a loop and in inlined callees, next to
// integers and floats live across them, and the result is checked against
// the same computation without assembly.
const std = @import("std");
const builtin = @import("builtin");
const a64 = builtin.cpu.arch == .aarch64;

/// x + 1 in an `r` operand.
inline fn inc(x: u64) u64 {
    return if (a64)
        asm ("add %[out], %[x], #1"
            : [out] "=r" (-> u64),
            : [x] "r" (x),
        )
    else
        asm (
            \\ movq %[x], %[out]
            \\ addq $1, %[out]
            : [out] "=r" (-> u64),
            : [x] "r" (x),
        );
}

/// x through a pinned callee-saved register.
inline fn pinned(x: u64) u64 {
    return if (a64)
        asm ("mov %[out], x21"
            : [out] "=r" (-> u64),
            : [x] "{x21}" (x),
        )
    else
        asm ("movq %%rbx, %[out]"
            : [out] "=r" (-> u64),
            : [x] "{rbx}" (x),
        );
}

/// k + a + b + c + d + e + g, with k pinned to a callee-saved register
/// and loaded first, before the `r` operands, one of which holds a value
/// that lived in that register.
inline fn sum7(k: u64, a: u64, b: u64, c: u64, d: u64, e: u64, g: u64) u64 {
    return if (a64)
        asm (
            \\ add %[out], x21, %[a]
            \\ add %[out], %[out], %[b]
            \\ add %[out], %[out], %[c]
            \\ add %[out], %[out], %[d]
            \\ add %[out], %[out], %[e]
            \\ add %[out], %[out], %[g]
            : [out] "=&r" (-> u64),
            : [k] "{x21}" (k),
              [a] "r" (a),
              [b] "r" (b),
              [c] "r" (c),
              [d] "r" (d),
              [e] "r" (e),
              [g] "r" (g),
        )
    else
        asm (
            \\ movq %%rbx, %[out]
            \\ addq %[a], %[out]
            \\ addq %[b], %[out]
            \\ addq %[c], %[out]
            \\ addq %[d], %[out]
            \\ addq %[e], %[out]
            \\ addq %[g], %[out]
            : [out] "=r" (-> u64),
            : [k] "{rbx}" (k),
              [a] "r" (a),
              [b] "r" (b),
              [c] "r" (c),
              [d] "r" (d),
              [e] "r" (e),
              [g] "r" (g),
        );
}

/// a ^ b ^ c ^ d ^ e ^ f through SIMD operands, which get v16 on: values
/// defined last to first, so a later operand's value would sit in the
/// register an earlier one gets, were the operands in v20-v29.
noinline fn xor6(x: @Vector(16, u8)) @Vector(16, u8) {
    const f = x +% @as(@Vector(16, u8), @splat(6));
    const e = x +% @as(@Vector(16, u8), @splat(5));
    const d = x +% @as(@Vector(16, u8), @splat(4));
    const c = x +% @as(@Vector(16, u8), @splat(3));
    const b = x +% @as(@Vector(16, u8), @splat(2));
    const a = x +% @as(@Vector(16, u8), @splat(1));
    if (!a64) return a ^ b ^ c ^ d ^ e ^ f;
    return asm (
        \\ eor %[out].16b, %[a].16b, %[b].16b
        \\ eor %[out].16b, %[out].16b, %[c].16b
        \\ eor %[out].16b, %[out].16b, %[d].16b
        \\ eor %[out].16b, %[out].16b, %[e].16b
        \\ eor %[out].16b, %[out].16b, %[f].16b
        : [out] "=&w" (-> @Vector(16, u8)),
        : [a] "w" (a),
          [b] "w" (b),
          [c] "w" (c),
          [d] "w" (d),
          [e] "w" (e),
          [f] "w" (f),
    );
}

/// Zeroes registers it names as clobbers: callee-saved ones, and rsi,
/// which holds values elsewhere on x86_64.
inline fn trash() void {
    if (a64)
        asm volatile (
            \\ mov x19, #0
            \\ mov x20, #0
            \\ movi v8.16b, #0
            ::: .{ .x19 = true, .x20 = true, .v8 = true })
    else
        asm volatile (
            \\ xorl %%ebx, %%ebx
            \\ xorl %%r12d, %%r12d
            \\ xorl %%esi, %%esi
            ::: .{ .rbx = true, .r12 = true, .rsi = true });
}

noinline fn withAsm(n: u64, y: f64) u64 {
    const a = n *% 7;
    const b = n ^ 0x55;
    const c = n +% 13;
    const d = n *% n;
    const e = n >> 1;
    const g = n | 3;
    const p = y * 3;
    var sum: u64 = 0;
    var f: f64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        trash();
        sum +%= inc(i) +% pinned(a ^ i) +% b;
        sum +%= sum7(i, a, b, c, d, e, g);
        f += p;
        trash();
    }
    return sum +% a +% b +% c +% d +% e +% g +% @as(u64, @intFromFloat(f));
}

noinline fn without(n: u64, y: f64) u64 {
    const a = n *% 7;
    const b = n ^ 0x55;
    const c = n +% 13;
    const d = n *% n;
    const e = n >> 1;
    const g = n | 3;
    const p = y * 3;
    var sum: u64 = 0;
    var f: f64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        sum +%= (i + 1) +% (a ^ i) +% b;
        sum +%= i +% a +% b +% c +% d +% e +% g;
        f += p;
    }
    return sum +% a +% b +% c +% d +% e +% g +% @as(u64, @intFromFloat(f));
}

pub fn main() void {
    var n: u64 = 1000;
    _ = &n;
    if (withAsm(n, 0.5) != without(n, 0.5)) {
        std.debug.print("bad {d} {d}\n", .{ withAsm(n, 0.5), without(n, 0.5) });
        std.process.exit(1);
    }
    var v: @Vector(16, u8) = @splat(0x30);
    _ = &v;
    const w = v +% @as(@Vector(16, u8), @splat(1));
    const want = w ^ (v +% @as(@Vector(16, u8), @splat(2))) ^ (v +% @as(@Vector(16, u8), @splat(3))) ^
        (v +% @as(@Vector(16, u8), @splat(4))) ^ (v +% @as(@Vector(16, u8), @splat(5))) ^ (v +% @as(@Vector(16, u8), @splat(6)));
    if (@reduce(.Or, xor6(v) != want)) {
        std.debug.print("bad vectors {any}\n", .{xor6(v)});
        std.process.exit(1);
    }
    std.debug.print("ok {d}\n", .{n});
}
