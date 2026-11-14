//! exit: 0
//! stderr: "11 16 0\n100000011 3 100000018 4 26 0 10000001f 2 100000196 4 \nefcdab8967452301 efcdab89 23016745ab89efcd 67452301efcdab89 f7b3d591 600 12340000abcd0009 ff00ffff 1000000f0ffff 10000 ffff00f000000001 f0ffff00010000 800000 1317 12340000abcd0009 ff00ffff \n2020 3611ecc7a27d5833 86613c17 36 14ef caa5805b true\n000000ff00ffff00ff000000ffff0000\nffffffff0000ffffffffffff0000ffff\n30cac4e983a2ec3680caef5ea8f23c86\n0b559f0e587dc7115ba5143983cd1761\n163e183f0630587efaad25224a4d9ac2\n5b80a5caefc4e95e83a8cdf2c7ec6186\n5b5b5b86365c5b5bab5b375c5b5b5c5b\n5b5b5b8600000000ffffff00000000ff\n"
//! targets: aarch64-macos aarch64-linux
//! aarch64 inline assembly as hand-written string routines use it (Arm's
//! optimized-routines, which libcs and fastmem port): a NEON search for a
//! byte (`ld1` of a register list, `cmeq`, `shrn`, `fmov` to a general
//! register, `rbit`, `clz`), conditional select and its aliases, `ccmp`,
//! byte and bit reversal, the move-wide instructions, an element moved to
//! a general register, `st1` with a post-index, and the vector compares,
//! pairwise reductions and bit selects. Each case prints what upstream
//! prints. Other targets print the same text without running the assembly.
const std = @import("std");
const builtin = @import("builtin");

/// The index of the first zero byte of the 16 at `p`, or 16: a 4-bit mask
/// per byte, narrowed out of the comparison.
noinline fn firstZero(p: *const [16]u8) u64 {
    return asm (
        \\    ld1 {v0.16b}, [%[p]]
        \\    cmeq v0.16b, v0.16b, #0
        \\    shrn v0.8b, v0.8h, #4
        \\    fmov %[o], d0
        \\    rbit %[o], %[o]
        \\    clz %[o], %[o]
        \\    lsr %[o], %[o], #2
        : [o] "=&r" (-> u64),
        : [p] "r" (p),
        : .{ .v0 = true });
}

/// Conditional select and its aliases, each adding what it selects.
noinline fn selects(a: u64, b: u64) u64 {
    return asm (
        \\    cmp %[a], %[b]
        \\    csel %[o], %[a], %[b], hi
        \\    cset x9, lo
        \\    add %[o], %[o], x9
        \\    cinc %[o], %[o], eq
        \\    csinv x9, %[a], xzr, hs
        \\    cneg x9, x9, lo
        \\    add %[o], %[o], x9
        \\    csetm w10, ne
        \\    add %[o], %[o], x10
        \\    csinc x9, %[a], %[b], cc
        \\    csneg x10, %[b], %[a], CS
        \\    cinv x10, x10, mi
        \\    add %[o], %[o], x9
        \\    add %[o], %[o], x10
        : [o] "=&r" (-> u64),
        : [a] "r" (a),
          [b] "r" (b),
        : .{ .x9 = true, .x10 = true, .nzcv = true });
}

/// Conditional compares with an immediate and with a register: 1 if `a`
/// is 5 and `b` is 7, and twice a count of two more conditions.
noinline fn compares(a: u64, b: u64) u64 {
    return asm (
        \\    cmp %[a], #5
        \\    ccmp %[b], #7, #0, eq
        \\    cset %[o], eq
        \\    cmp %[a], %[b]
        \\    ccmn %[b:w], #1, #4, ne
        \\    cset x9, ne
        \\    cmp %[a], #100
        \\    ccmp %[a], %[b], 2, lo
        \\    cinc x9, x9, hi
        \\    add %[o], %[o], x9, lsl #1
        : [o] "=&r" (-> u64),
        : [a] "r" (a),
          [b] "r" (b),
        : .{ .x9 = true, .nzcv = true });
}

/// Reversals and leading-bit counts of `x`, of both widths.
noinline fn bits(x: u64) [8]u64 {
    var r: [8]u64 = undefined;
    asm volatile (
        \\    rev x9, %[x]
        \\    str x9, [%[r]]
        \\    rev w9, %[x:w]
        \\    str x9, [%[r], #8]
        \\    rev16 x9, %[x]
        \\    str x9, [%[r], #16]
        \\    rev32 x9, %[x]
        \\    str x9, [%[r], #24]
        \\    rbit w9, %[x:w]
        \\    str x9, [%[r], #32]
        \\    clz w9, %[x:w]
        \\    cls x10, %[x]
        \\    add x9, x9, x10, lsl #8
        \\    str x9, [%[r], #40]
        \\    movz x9, #0x1234, lsl #48
        \\    movk x9, #0xabcd, lsl #16
        \\    movk x9, 0x9
        \\    str x9, [%[r], #48]
        \\    movn w9, #0x00ff, lsl #16
        \\    str x9, [%[r], #56]
        :
        : [x] "r" (x),
          [r] "r" (&r),
        : .{ .x9 = true, .x10 = true, .memory = true });
    return r;
}

/// Elements of the vector at `p` in general registers, after `st1` copies
/// its 32 bytes to `q` and steps both pointers.
noinline fn elements(p: *const [32]u8, q: *[32]u8) [6]u64 {
    var r: [6]u64 = undefined;
    asm volatile (
        \\    mov x9, %[p]
        \\    mov x10, %[q]
        \\    mov x11, #16
        \\    ld1 {v0.16b, v1.16b}, [x9], #32
        \\    st1 {v0.2d}, [x10], x11
        \\    st1 {v1.8h}, [x10], #16
        \\    sub x9, x9, %[p]
        \\    sub x10, x10, %[q]
        \\    add x9, x9, x10, lsl #8
        \\    str x9, [%[r]]
        \\    mov x9, v0.d[1]
        \\    str x9, [%[r], #8]
        \\    mov w9, v1.s[3]
        \\    str x9, [%[r], #16]
        \\    umov w9, v0.b[15]
        \\    str x9, [%[r], #24]
        \\    umov w9, v1.h[2]
        \\    str x9, [%[r], #32]
        \\    fmov w9, s1
        \\    fmov d2, x9
        \\    umov x9, v2.d[0]
        \\    str x9, [%[r], #40]
        :
        : [p] "r" (p),
          [q] "r" (q),
          [r] "r" (&r),
        : .{ .x9 = true, .x10 = true, .x11 = true, .v0 = true, .v1 = true, .v2 = true, .memory = true });
    return r;
}

/// Compares, pairwise reductions, a bit select and arithmetic on the two
/// vectors at `p`, stored at `out`.
noinline fn vectors(p: *const [32]u8, out: *[8][16]u8) void {
    asm volatile (
        \\    ld1 {v0.16b, v1.16b}, [%[p]]
        \\    cmhs v2.16b, v0.16b, v1.16b
        \\    cmeq v3.16b, v0.16b, v1.16b
        \\    cmhi v4.8h, v1.8h, v0.8h
        \\    orr v3.16b, v3.16b, v4.16b
        \\    umaxp v4.16b, v0.16b, v1.16b
        \\    uminp v5.16b, v0.16b, v1.16b
        \\    addp v6.2d, v0.2d, v1.2d
        \\    addp v6.16b, v6.16b, v4.16b
        \\    mov v7.16b, v0.16b
        \\    bif v7.16b, v1.16b, v2.16b
        \\    add v16.4s, v0.4s, v1.4s
        \\    sub v16.8h, v16.8h, v5.8h
        \\    cmgt v17.4s, v16.4s, #0
        \\    cmge v18.16b, v0.16b, v1.16b
        \\    cmtst v17.16b, v17.16b, v18.16b
        \\    smin v17.4s, v17.4s, v16.4s
        \\    st1 {v2.16b, v3.16b, v4.16b, v5.16b}, [%[out]], #64
        \\    st1 {v6.16b, v7.16b}, [%[out]], #32
        \\    st1 {v16.4s}, [%[out]], #16
        \\    st1 {v17.2d}, [%[out]]
        :
        : [p] "r" (p),
          [out] "r" (out),
        : .{ .v0 = true, .v1 = true, .v2 = true, .v3 = true, .v4 = true, .v5 = true, .v6 = true, .v7 = true, .v16 = true, .v17 = true, .v18 = true, .memory = true });
}

pub fn main() void {
    if (builtin.cpu.arch != .aarch64) {
        std.debug.print("11 16 0\n100000011 3 100000018 4 26 0 10000001f 2 100000196 4 \nefcdab8967452301 efcdab89 23016745ab89efcd 67452301efcdab89 f7b3d591 600 12340000abcd0009 ff00ffff 1000000f0ffff 10000 ffff00f000000001 f0ffff00010000 800000 1317 12340000abcd0009 ff00ffff \n2020 3611ecc7a27d5833 86613c17 36 14ef caa5805b true\n000000ff00ffff00ff000000ffff0000\nffffffff0000ffffffffffff0000ffff\n30cac4e983a2ec3680caef5ea8f23c86\n0b559f0e587dc7115ba5143983cd1761\n163e183f0630587efaad25224a4d9ac2\n5b80a5caefc4e95e83a8cdf2c7ec6186\n5b5b5b86365c5b5bab5b375c5b5b5c5b\n5b5b5b8600000000ffffff00000000ff\n", .{});
        return;
    }
    var text: [16]u8 = "hello, aarch64!!".*;
    text[11] = 0;
    std.debug.print("{d}", .{firstZero(&text)});
    text[11] = '6';
    std.debug.print(" {d}", .{firstZero(&text)});
    text[0] = 0;
    std.debug.print(" {d}\n", .{firstZero(&text)});

    var pairs = [_][2]u64{ .{ 5, 7 }, .{ 7, 5 }, .{ 9, 9 }, .{ 0, 31 }, .{ 200, 3 } };
    _ = &pairs;
    for (pairs) |pair| std.debug.print("{x} {d} ", .{ selects(pair[0], pair[1]), compares(pair[0], pair[1]) });
    std.debug.print("\n", .{});

    var x: u64 = 0x0123456789abcdef;
    _ = &x;
    for (bits(x)) |v| std.debug.print("{x} ", .{v});
    for (bits(0xffff_f000_0000_0100)) |v| std.debug.print("{x} ", .{v});
    std.debug.print("\n", .{});

    var bytes: [32]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(i * 37 + 11);
    var copy: [32]u8 = @splat(0);
    for (elements(&bytes, &copy)) |v| std.debug.print("{x} ", .{v});
    std.debug.print("{}\n", .{std.mem.eql(u8, &bytes, &copy)});

    bytes[3] = bytes[19];
    bytes[8] = bytes[24];
    var out: [8][16]u8 = undefined;
    vectors(&bytes, &out);
    for (out) |row| std.debug.print("{x}\n", .{row});
}
