//! exit: 0
//! stderr: "2468acea42e300 61b3 4320fedcccf16c60 bbbbbbbcab65c9b5 100dd74a4 fffffffffeda709f fce00000 fffffffffedf0000 ee0d3c569d3a50 ff11f2c3a962c5b0 ffcac7d4ccf16c60 ff11f2c4ab65c9b5 102030406 8baed1f5 76543 ffffffffffffff87 32100102030405 2100 fedcba9876020304 4321000000001020 \n555566667778108a 5555666677778845 1212232334344545 48488c8cd0d116f4 a4244646686800fa\n590ef0 5f3a 3d18f3ce ffffffac d4af8a65401bf6d1 d15f3a15f0cba681 \nf8 9 c026c00000000000 c02e400000000000 c002e8ba2e8ba2e9 400465655f122ff6 40d00000 fffffffffffffffd 3ff0000000000000 1 bfc8000000000000 41f0000000000000 fffffffd 7 1 0 \n"
//! targets: aarch64-macos aarch64-linux
//! aarch64 inline assembly beyond what string routines use, a family at a
//! time: multiplies, divides, carries and bitfield moves; the exclusive
//! and the acquire and release loads and stores, and with the CPU's `lse`
//! feature its atomic instructions; unscaled, non-temporal and
//! sign-extending pair loads and stores and prefetches; and scalar
//! floating point. Each case prints what upstream prints. Other targets
//! print the same text without running the assembly.
const std = @import("std");
const builtin = @import("builtin");

noinline fn integer(a: u64, b: u64, out: *[20]u64) void {
    asm volatile (
        \\    madd x9, %[a], %[b], %[a]
        \\    msub x10, %[a], %[b], %[b]
        \\    stp x9, x10, [%[out]]
        \\    umulh x9, %[a], %[b]
        \\    smulh x10, %[a], %[b]
        \\    stp x9, x10, [%[out], #16]
        \\    udiv x9, %[a], %[b]
        \\    sdiv x10, %[a], %[b]
        \\    stp x9, x10, [%[out], #32]
        \\    umull x9, %[a:w], %[b:w]
        \\    smnegl x10, %[a:w], %[b:w]
        \\    stp x9, x10, [%[out], #48]
        \\    umaddl x9, %[a:w], %[b:w], %[a]
        \\    smsubl x10, %[a:w], %[b:w], %[b]
        \\    stp x9, x10, [%[out], #64]
        \\    adds x9, %[a], %[a]
        \\    adc x9, %[b], xzr
        \\    sbcs x10, %[a], %[b]
        \\    ngc w10, w10
        \\    stp x9, x10, [%[out], #80]
        \\    ubfx x9, %[a], #12, #20
        \\    sbfx x10, %[a], #28, #8
        \\    stp x9, x10, [%[out], #96]
        \\    mov x9, %[b]
        \\    bfi x9, %[a], #40, #16
        \\    ubfiz x10, %[a], #4, #12
        \\    stp x9, x10, [%[out], #112]
        \\    mov x9, %[a]
        \\    bfxil x9, %[b], #8, #24
        \\    extr x10, %[a], %[b], #20
        \\    stp x9, x10, [%[out], #128]
        \\    mov x9, %[a]
        \\    bfc x9, #8, #40
        \\    sbfiz w10, %[b:w], #3, #9
        \\    stp x9, x10, [%[out], #144]
        \\    lslv x9, %[a], %[b]
        \\    rorv w10, %[a:w], %[b:w]
        \\    mul w10, w10, %[b:w]
        \\    mneg x9, x9, x10
        \\    asrv x9, x9, %[b]
        \\    lsrv x10, x10, %[a]
        \\    stp x9, x10, [%[out], #-16]!
        :
        : [a] "r" (a),
          [b] "r" (b),
          [out] "r" (out[2..]),
        : .{ .x9 = true, .x10 = true, .nzcv = true, .memory = true });
}

/// Adds `v` to the first word with an exclusive load and store, swaps the
/// two words with an exclusive pair (which is 16 bytes aligned), and
/// stores a byte with a release.
noinline fn exclusive(p: *align(16) [2]u64, v: u64) u64 {
    return asm (
        \\ 1: ldaxr x9, [%[p]]
        \\    add x10, x9, %[v]
        \\    stlxr w11, x10, [%[p], #0]
        \\    cbnz w11, 1b
        \\ 2: ldxp x9, x10, [%[p]]
        \\    stxp w11, x10, x9, [%[p]]
        \\    cbnz w11, 2b
        \\    stlrb w9, [%[p]]
        \\ 3: ldxrh w9, [%[p]]
        \\    stxrh w11, w9, [%[p]]
        \\    cbnz w11, 3b
        \\    clrex
        \\    ldar %[o], [%[p]]
        \\    add %[o], %[o], x9
        : [o] "=&r" (-> u64),
        : [p] "r" (p),
          [v] "r" (v),
        : .{ .x9 = true, .x10 = true, .x11 = true, .memory = true });
}

/// The `lse` instructions where the CPU has them: an add, a swap, a
/// compare and swap and a bit set, each returning what was there.
noinline fn atomics(p: *u64, v: u64) u64 {
    if (comptime !builtin.cpu.has(.aarch64, .lse)) {
        const n = 2 *% p.* +% v;
        p.* = (n | v) & ~@as(u64, 0xff00);
        return 2 *% n;
    }
    return asm (
        \\    ldadd %[v], x9, [%[p]]
        \\    swpal %[v], x10, [%[p]]
        \\    add x9, x9, x10
        \\    mov x10, %[v]
        \\    casal x10, x9, [%[p]]
        \\    ldsetl %[v], x11, [%[p]]
        \\    mov w10, #0xff00
        \\    stclrh w10, [%[p]]
        \\    add %[o], x9, x11
        : [o] "=&r" (-> u64),
        : [p] "r" (p),
          [v] "r" (v),
        : .{ .x9 = true, .x10 = true, .x11 = true, .memory = true });
}

noinline fn memory(in: *const [32]u8, out: *[6]u64) void {
    asm volatile (
        \\    prfm pldl1keep, [%[in]]
        \\    prfm pstl2strm, [%[out], #8]
        \\    prfum plil3keep, [%[in], #-3]
        \\    prfm pldl1strm, [%[in], x9, lsl #3]
        \\    ldurb w9, [%[in], #3]
        \\    ldursh x10, [%[in], #5]
        \\    stp x9, x10, [%[out]]
        \\    ldursw x9, [%[in], #9]
        \\    ldursb w10, [%[in], #15]
        \\    stp x9, x10, [%[out], #16]
        \\    ldnp x9, x10, [%[in], #16]
        \\    stnp x10, x9, [%[out], #32]
        \\    ldpsw x9, x10, [%[in], #12]
        \\    add x9, x9, x10
        \\    sturh w9, [%[out], #1]
        \\    ldnp q0, q1, [%[in]]
        \\    stnp d1, d0, [%[out], #32]
        \\    sturb w10, [%[out], #47]
        :
        : [in] "r" (in),
          [out] "r" (out),
        : .{ .x9 = true, .x10 = true, .v0 = true, .v1 = true, .memory = true });
}

noinline fn floats(in: *const [2]f64, out: *[16]u64) void {
    asm volatile (
        \\    ldp d0, d1, [%[in]]
        \\    fmadd d2, d0, d1, d0
        \\    fnmsub d3, d0, d1, d1
        \\    stp d2, d3, [%[out]]
        \\    fdiv d2, d0, d1
        \\    fsqrt d3, d0
        \\    stp d2, d3, [%[out], #16]
        \\    fcvt s2, d0
        \\    fmov w9, s2
        \\    frintm d3, d1
        \\    fcvtzs x10, d3
        \\    stp x9, x10, [%[out], #32]
        \\    fmov d2, #-1.25
        \\    fmov d3, #0x70
        \\    fmul d2, d2, d1
        \\    fcmp d2, d3
        \\    fcsel d4, d2, d3, mi
        \\    fccmp d0, d1, #2, gt
        \\    cset x9, hi
        \\    str d4, [%[out], #48]
        \\    str x9, [%[out], #56]
        \\    scvtf d2, x10, #4
        \\    ucvtf s3, w10
        \\    fcvt d3, s3
        \\    stp d2, d3, [%[out], #64]
        \\    fcvtas w9, d1
        \\    fcvtpu x10, d0
        \\    stp x9, x10, [%[out], #80]
        \\    fcmpe d0, #0.0
        \\    cset x9, gt
        \\    fmov d2, xzr
        \\    fmov x10, d2
        \\    fmov v2.d[1], x9
        \\    fmov x9, v2.d[1]
        \\    stp x9, x10, [%[out], #96]
        \\    fmaxnm d2, d0, d1
        \\    fmin d3, d0, d1
        \\    fabs d3, d3
        \\    fneg d2, d2
        \\    fnmul d2, d2, d3
        \\    fsub d3, d3, d2
        \\    stp d2, d3, [%[out], #112]
        \\    fmov s2, #31.0
        \\    fcvtzu w9, s2, #3
        \\    fmov d3, #2
        \\    fadd d3, d3, d0
        \\    frinta d3, d3
        \\    fcvtnu x10, d3
        \\    stp x9, x10, [%[out], #-16]!
        :
        : [in] "r" (in),
          [out] "r" (out[2..]),
        : .{ .x9 = true, .x10 = true, .v0 = true, .v1 = true, .v2 = true, .v3 = true, .v4 = true, .nzcv = true, .memory = true });
}

pub fn main() void {
    if (builtin.cpu.arch != .aarch64) {
        std.debug.print("2468acea42e300 61b3 4320fedcccf16c60 bbbbbbbcab65c9b5 100dd74a4 fffffffffeda709f fce00000 fffffffffedf0000 ee0d3c569d3a50 ff11f2c3a962c5b0 ffcac7d4ccf16c60 ff11f2c4ab65c9b5 102030406 8baed1f5 76543 ffffffffffffff87 32100102030405 2100 fedcba9876020304 4321000000001020 \n555566667778108a 5555666677778845 1212232334344545 48488c8cd0d116f4 a4244646686800fa\n590ef0 5f3a 3d18f3ce ffffffac d4af8a65401bf6d1 d15f3a15f0cba681 \nf8 9 c026c00000000000 c02e400000000000 c002e8ba2e8ba2e9 400465655f122ff6 40d00000 fffffffffffffffd 3ff0000000000000 1 bfc8000000000000 41f0000000000000 fffffffd 7 1 0 \n", .{});
        return;
    }
    var words: [20]u64 = undefined;
    integer(0xfedc_ba98_7654_3210, 0x0000_0001_0203_0405, &words);
    for (words) |w| std.debug.print("{x} ", .{w});
    std.debug.print("\n", .{});
    var cell: [2]u64 align(16) = .{ 0x1111_2222_3333_4444, 0x5555_6666_7777_8888 };
    std.debug.print("{x}", .{exclusive(&cell, 0x0101_0101_0101_0101)});
    std.debug.print(" {x} {x}", .{ cell[0], cell[1] });
    std.debug.print(" {x}", .{atomics(&cell[1], 0x8000_0000_0000_00f0)});
    std.debug.print(" {x}\n", .{cell[1]});
    var bytes: [32]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(i * 37 + 129);
    var six: [6]u64 = @splat(0);
    memory(&bytes, &six);
    for (six) |w| std.debug.print("{x} ", .{w});
    std.debug.print("\n", .{});
    var bits: [16]u64 = undefined;
    floats(&.{ 6.5, -2.75 }, &bits);
    for (bits) |w| std.debug.print("{x} ", .{w});
    std.debug.print("\n", .{});
}
