//! exit: 0
//! stderr: "fed6e40b03d0930a\ndbffb73024f621ef\n21cf68a7c9c42dd\n6fca40eda49dc75d\n755793acaa71e674 1ffd\n4f956e01d8bc9f97\n"
//! targets: aarch64-macos aarch64-linux
//! aarch64 inline assembly's Advanced SIMD instructions, a group of
//! operand shapes at a time: three vectors of one arrangement, two, the
//! widening and narrowing forms, shifts by an immediate, reductions
//! across a vector, multiplies by an element, copies between elements,
//! scalars and general registers, immediates, table lookups, and the
//! structure loads and stores. Each group stores its vectors, and the
//! test prints a checksum of each, which is what upstream prints. Other
//! targets print the same text without running the assembly.
const std = @import("std");
const builtin = @import("builtin");

const In = *const [64]u8;

/// Vectors v0 to v3 are the input in every group.
noinline fn same(in: In, out: *[16][16]u8) void {
    asm volatile (
        \\    ld1 {v0.16b-v3.16b}, [%[in]]
        \\    add v4.8h, v0.8h, v1.8h
        \\    sqadd v5.16b, v0.16b, v1.16b
        \\    uqsub v6.4s, v2.4s, v3.4s
        \\    mul v7.4s, v0.4s, v3.4s
        \\    st1 {v4.16b, v5.16b, v6.16b, v7.16b}, [%[out]], #64
        \\    mla v4.8h, v2.8h, v3.8h
        \\    urhadd v5.16b, v2.16b, v3.16b
        \\    sabd v6.4h, v0.4h, v1.4h
        \\    ushl v7.2d, v0.2d, v1.2d
        \\    st1 {v4.16b, v5.16b, v6.16b, v7.16b}, [%[out]], #64
        \\    cmhi v4.4s, v0.4s, v1.4s
        \\    cmlo v5.16b, v0.16b, v1.16b
        \\    uzp1 v6.16b, v0.16b, v1.16b
        \\    zip2 v7.4s, v2.4s, v3.4s
        \\    st1 {v4.16b, v5.16b, v6.16b, v7.16b}, [%[out]], #64
        \\    trn1 v4.8h, v0.8h, v3.8h
        \\    pmul v5.16b, v0.16b, v1.16b
        \\    sqdmulh v6.8h, v2.8h, v3.8h
        \\    eor v7.16b, v0.16b, v1.16b
        \\    add d7, d7, d6
        \\    sqsub b6, b6, b5
        \\    cmge d5, d5, d4
        \\    st1 {v4.16b, v5.16b, v6.16b, v7.16b}, [%[out]], #64
        :
        : [in] "r" (in),
          [out] "r" (out),
        : .{ .v0 = true, .v1 = true, .v2 = true, .v3 = true, .v4 = true, .v5 = true, .v6 = true, .v7 = true, .memory = true });
}

noinline fn float(in: *const [4][4]f32, out: *[12][16]u8) void {
    asm volatile (
        \\    ld1 {v0.4s, v1.4s, v2.4s, v3.4s}, [%[in]]
        \\    fadd v4.4s, v0.4s, v1.4s
        \\    fmul v5.4s, v2.4s, v3.4s
        \\    fmla v5.4s, v0.4s, v1.4s
        \\    fdiv v6.4s, v0.4s, v2.4s
        \\    fmaxnm v7.4s, v1.4s, v3.4s
        \\    st1 {v4.4s, v5.4s, v6.4s, v7.4s}, [%[out]], #64
        \\    fcvtl v4.2d, v0.2s
        \\    fcvtl2 v5.2d, v0.4s
        \\    fsqrt v5.2d, v5.2d
        \\    fcvtn v6.2s, v5.2d
        \\    fcvtn2 v6.4s, v4.2d
        \\    fabd v7.2d, v4.2d, v5.2d
        \\    faddp v7.2d, v7.2d, v4.2d
        \\    st1 {v4.2d, v5.2d, v6.2d, v7.2d}, [%[out]], #64
        \\    fcmgt v4.4s, v0.4s, v1.4s
        \\    fcmle v5.4s, v2.4s, #0.0
        \\    fcvtzs v6.4s, v3.4s
        \\    scvtf v6.4s, v6.4s, #3
        \\    frintm v7.4s, v2.4s
        \\    fneg v7.4s, v7.4s
        \\    fcvtas v7.4s, v7.4s
        \\    faddp s16, v0.2s
        \\    fmaxv s17, v1.4s
        \\    fmulx s16, s16, s17
        \\    fcvtl v17.2d, v3.2s
        \\    fcvtzu d17, d17, #5
        \\    ucvtf d17, d17
        \\    frecpe s18, s16
        \\    facge s18, s18, s16
        \\    ins v7.s[1], v16.s[0]
        \\    ins v7.d[1], v17.d[0]
        \\    ins v4.s[3], v18.s[0]
        \\    st1 {v4.4s, v5.4s, v6.4s, v7.4s}, [%[out]], #64
        :
        : [in] "r" (in),
          [out] "r" (out),
        : .{ .v0 = true, .v1 = true, .v2 = true, .v3 = true, .v4 = true, .v5 = true, .v6 = true, .v7 = true, .v16 = true, .v17 = true, .v18 = true, .memory = true });
}

noinline fn two(in: In, out: *[16][16]u8) void {
    asm volatile (
        \\    ld1 {v0.16b-v3.16b}, [%[in]]
        \\    abs v4.16b, v0.16b
        \\    neg v5.4s, v1.4s
        \\    cnt v6.16b, v2.16b
        \\    rev32 v7.8h, v3.8h
        \\    st1 {v4.16b, v5.16b, v6.16b, v7.16b}, [%[out]], #64
        \\    clz v4.4s, v0.4s
        \\    cls v5.8h, v1.8h
        \\    rbit v6.16b, v2.16b
        \\    mvn v7.16b, v3.16b
        \\    rev64 v7.16b, v7.16b
        \\    rev16 v6.16b, v6.16b
        \\    st1 {v4.16b, v5.16b, v6.16b, v7.16b}, [%[out]], #64
        \\    saddlp v4.8h, v0.16b
        \\    uadalp v4.4s, v1.8h
        \\    xtn v5.8b, v2.8h
        \\    xtn2 v5.16b, v3.8h
        \\    sqxtun v6.4h, v0.4s
        \\    uqxtn2 v6.8h, v1.4s
        \\    shll v7.2d, v2.2s, #32
        \\    st1 {v4.16b, v5.16b, v6.16b, v7.16b}, [%[out]], #64
        \\    cmle v4.16b, v0.16b, #0
        \\    cmeq v5.8h, v1.8h, #0
        \\    sqabs v6.2d, v2.2d
        \\    urecpe v7.4s, v3.4s
        \\    not v6.8b, v6.8b
        \\    sqneg h7, h7
        \\    abs d5, d5
        \\    sqxtn b4, h4
        \\    st1 {v4.16b, v5.16b, v6.16b, v7.16b}, [%[out]], #64
        :
        : [in] "r" (in),
          [out] "r" (out),
        : .{ .v0 = true, .v1 = true, .v2 = true, .v3 = true, .v4 = true, .v5 = true, .v6 = true, .v7 = true, .memory = true });
}

noinline fn widths(in: In, out: *[16][16]u8) void {
    asm volatile (
        \\    ld1 {v0.16b-v3.16b}, [%[in]]
        \\    saddl v4.8h, v0.8b, v1.8b
        \\    uaddl2 v5.4s, v0.8h, v1.8h
        \\    ssubw v6.2d, v2.2d, v3.2s
        \\    uaddw2 v7.8h, v2.8h, v3.16b
        \\    st1 {v4.16b, v5.16b, v6.16b, v7.16b}, [%[out]], #64
        \\    addhn v4.8b, v0.8h, v1.8h
        \\    rsubhn2 v4.16b, v2.8h, v3.8h
        \\    umull v5.2d, v0.2s, v1.2s
        \\    smlal2 v5.2d, v2.4s, v3.4s
        \\    sqdmull v6.4s, v0.4h, v3.4h
        \\    pmull v7.8h, v1.8b, v2.8b
        \\    uabal v7.8h, v0.8b, v3.8b
        \\    st1 {v4.16b, v5.16b, v6.16b, v7.16b}, [%[out]], #64
        \\    sshr v4.16b, v0.16b, #3
        \\    usra v4.16b, v1.16b, #8
        \\    shl v5.2d, v2.2d, #63
        \\    sri v5.4s, v3.4s, #7
        \\    sli v5.8h, v0.8h, #15
        \\    urshr v6.4s, v1.4s, #32
        \\    sqshlu v6.8h, v6.8h, #4
        \\    uqshl v7.16b, v2.16b, #0
        \\    srsra v7.2d, v3.2d, #64
        \\    st1 {v4.16b, v5.16b, v6.16b, v7.16b}, [%[out]], #64
        \\    shrn v4.8b, v0.8h, #8
        \\    rshrn2 v4.16b, v1.8h, #1
        \\    sqrshrun v5.4h, v2.4s, #16
        \\    uqshrn2 v5.8h, v3.4s, #5
        \\    sshll v6.2d, v0.2s, #31
        \\    ushll2 v6.4s, v6.8h, #0
        \\    uxtl v7.8h, v1.8b
        \\    sxtl2 v7.4s, v7.8h
        \\    ushr d7, d7, #9
        \\    sqshrn s6, d6, #3
        \\    shl d5, d5, #1
        \\    uqshl b4, b4, #7
        \\    st1 {v4.16b, v5.16b, v6.16b, v7.16b}, [%[out]], #64
        :
        : [in] "r" (in),
          [out] "r" (out),
        : .{ .v0 = true, .v1 = true, .v2 = true, .v3 = true, .v4 = true, .v5 = true, .v6 = true, .v7 = true, .memory = true });
}

noinline fn elements(in: In, out: *[16][16]u8) u64 {
    return asm (
        \\    ld1 {v0.16b-v3.16b}, [%[in]]
        \\    mov x9, #0x4321
        \\    mov w10, #0x5a
        \\    mov w11, #0xbeef
        \\    addv b4, v0.16b
        \\    umaxv h5, v1.8h
        \\    sminv s6, v2.4s
        \\    uaddlv d7, v3.4s
        \\    saddlv h16, v0.8b
        \\    addp d17, v1.2d
        \\    ins v6.h[7], v16.h[0]
        \\    ins v7.d[1], v17.d[0]
        \\    st1 {v4.16b, v5.16b, v6.16b, v7.16b}, [%[out]], #64
        \\    mul v4.8h, v0.8h, v1.h[7]
        \\    mla v4.4s, v2.4s, v3.s[3]
        \\    sqrdmulh v5.4h, v0.4h, v1.h[2]
        \\    umull v6.2d, v1.2s, v2.s[1]
        \\    smlsl2 v6.4s, v3.8h, v0.h[5]
        \\    sqdmulh s7, s1, v2.s[2]
        \\    sqdmlal d7, s3, v0.s[1]
        \\    st1 {v4.16b, v5.16b, v6.16b, v7.16b}, [%[out]], #64
        \\    dup v4.8h, v0.h[3]
        \\    dup v5.2d, x9
        \\    mov v5.b[5], w10
        \\    mov v5.s[3], v1.s[0]
        \\    ins v5.h[1], w11
        \\    mov b6, v2.b[13]
        \\    dup d7, v3.d[1]
        \\    mov v7.d[1], x9
        \\    smov x9, v0.b[15]
        \\    smov w10, v0.h[7]
        \\    umov w11, v0.b[1]
        \\    add x9, x9, x10
        \\    add x9, x9, x11
        \\    mov v16.8b, v1.8b
        \\    mov v6.s[2], v16.s[1]
        \\    st1 {v4.16b, v5.16b, v6.16b, v7.16b}, [%[out]], #64
        \\    movi v4.16b, #0xa5
        \\    movi v5.4s, #0x7f, lsl #16
        \\    mvni v6.8h, #0x12, lsl #8
        \\    movi v7.2d, #0xff00ffff0000ff00
        \\    orr v5.4s, #0x81, lsl #24
        \\    bic v6.8h, #0xf0
        \\    movi v16.4s, #0x33, msl #8
        \\    mvni v17.2s, #0x44, msl #16
        \\    movi d18, #0xffffff0000000000
        \\    fmov v19.4s, #-1.25
        \\    fmov v20.2d, #17.0
        \\    eor v4.16b, v4.16b, v16.16b
        \\    eor v5.16b, v5.16b, v17.16b
        \\    eor v6.16b, v6.16b, v18.16b
        \\    eor v7.16b, v7.16b, v19.16b
        \\    eor v7.16b, v7.16b, v20.16b
        \\    st1 {v4.16b, v5.16b, v6.16b, v7.16b}, [%[out]], #64
        \\    mov %[sum], x9
        : [sum] "=&r" (-> u64),
        : [in] "r" (in),
          [out] "r" (out),
        : .{ .x9 = true, .x10 = true, .x11 = true, .v0 = true, .v1 = true, .v2 = true, .v3 = true, .v4 = true, .v5 = true, .v6 = true, .v7 = true, .v16 = true, .v17 = true, .v18 = true, .v19 = true, .v20 = true, .memory = true });
}

noinline fn structures(in: In, out: *[24][16]u8) void {
    asm volatile (
        \\    ld1 {v0.16b-v3.16b}, [%[in]]
        \\    tbl v4.16b, {v0.16b, v1.16b}, v2.16b
        \\    tbx v5.16b, {v1.16b-v3.16b}, v0.16b
        \\    movi v16.16b, #0x3f
        \\    and v16.16b, v16.16b, v3.16b
        \\    tbl v6.8b, {v0.16b, v1.16b, v2.16b, v3.16b}, v16.8b
        \\    ext v7.16b, v0.16b, v3.16b, #5
        \\    st1 {v4.16b, v5.16b, v6.16b, v7.16b}, [%[out]], #64
        \\    mov x9, %[in]
        \\    ld2 {v4.16b, v5.16b}, [x9], #32
        \\    ld2 {v6.4s, v7.4s}, [x9]
        \\    st1 {v4.16b, v5.16b, v6.16b, v7.16b}, [%[out]], #64
        \\    mov x9, %[in]
        \\    mov x10, #3
        \\    ld3 {v4.8b, v5.8b, v6.8b}, [x9], x10
        \\    ld4 {v16.4h, v17.4h, v18.4h, v19.4h}, [x9], #32
        \\    eor v7.8b, v16.8b, v17.8b
        \\    add v6.4h, v6.4h, v18.4h
        \\    sub v5.4h, v5.4h, v19.4h
        \\    st1 {v4.16b, v5.16b, v6.16b, v7.16b}, [%[out]], #64
        \\    mov x9, %[in]
        \\    ld1r {v4.8h}, [x9], #2
        \\    ld2r {v5.4s, v6.4s}, [x9], #8
        \\    ld1r {v7.2d}, [x9]
        \\    ld1 {v4.b}[3], [x9], #1
        \\    ld1 {v5.h}[7], [x9], #2
        \\    ld2 {v6.s, v7.s}[1], [x9], x10
        \\    ld1 {v7.d}[1], [x9]
        \\    st1 {v4.16b, v5.16b, v6.16b, v7.16b}, [%[out]], #64
        \\    st2 {v0.16b, v1.16b}, [%[out]], #32
        \\    st3 {v1.2s, v2.2s, v3.2s}, [%[out]], #24
        \\    st1 {v0.d}[1], [%[out]], #8
        \\    st4 {v0.8h-v3.8h}, [%[out]]
        \\    st1 {v3.b}[15], [%[out]]
        \\    st2 {v2.h, v3.h}[5], [%[out]]
        \\    st1 {v1.1d, v2.1d}, [%[out]]
        :
        : [in] "r" (in),
          [out] "r" (out),
        : .{ .x9 = true, .x10 = true, .v0 = true, .v1 = true, .v2 = true, .v3 = true, .v4 = true, .v5 = true, .v6 = true, .v7 = true, .v16 = true, .v17 = true, .v18 = true, .v19 = true, .memory = true });
}

fn sum(rows: []const [16]u8) u64 {
    return std.hash.Fnv1a_64.hash(@ptrCast(rows));
}

pub fn main() void {
    if (builtin.cpu.arch != .aarch64) {
        std.debug.print("fed6e40b03d0930a\ndbffb73024f621ef\n21cf68a7c9c42dd\n6fca40eda49dc75d\n755793acaa71e674 1ffd\n4f956e01d8bc9f97\n", .{});
        return;
    }
    var bytes: [64]u8 = undefined;
    for (&bytes, 0..) |*b, n| b.* = @truncate(n * n * 7 + n * 59 + 131);
    var rows: [24][16]u8 = undefined;
    same(&bytes, rows[0..16]);
    std.debug.print("{x}\n", .{sum(rows[0..16])});
    float(&.{ .{ 1.5, -2.25, 100.0, 0.375 }, .{ -8.0, 3.0, 0.5, 7.0 }, .{ 2.0, -0.5, 16.0, 1.0 }, .{ 9.0, 4.75, -6.5, 12.0 } }, rows[0..12]);
    std.debug.print("{x}\n", .{sum(rows[0..12])});
    two(&bytes, rows[0..16]);
    std.debug.print("{x}\n", .{sum(rows[0..16])});
    widths(&bytes, rows[0..16]);
    std.debug.print("{x}\n", .{sum(rows[0..16])});
    const s = elements(&bytes, rows[0..16]);
    std.debug.print("{x} {x}\n", .{ sum(rows[0..16]), s });
    structures(&bytes, &rows);
    std.debug.print("{x}\n", .{sum(&rows)});
}
