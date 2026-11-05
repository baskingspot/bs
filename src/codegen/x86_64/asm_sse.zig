//! x86_64 inline assembly's SSE instructions through SSE4.2, and SHA,
//! taken as upstream's assembler takes them (`airAsm` in upstream's
//! src/codegen/x86_64/CodeGen.zig, with its encodings.zon): register
//! operands only, since upstream cannot size a 128-bit memory operand
//! (no AT&T suffix names 128 bits, and a suffix would size the xmm
//! registers too), general-purpose registers of the sizes its encodings
//! take, and an encoding only on a CPU with its feature. The bytes are
//! upstream's, which are GNU as's. CodeGen's `asmSimd` assembles AES-NI,
//! PCLMULQDQ and the VEX forms std uses.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Encoder = @import("Encoder.zig");
const asm_insn = @import("asm_insn.zig");
const Reg = Encoder.Reg;
const Xmm = Encoder.Xmm;
const Size = Encoder.Size;
const Feature = std.Target.x86.Feature;
const Fail = asm_insn.Fail;

pub const Operand = union(enum) {
    xmm: Xmm,
    reg: struct { reg: Reg, size: Size },
    imm: i64,
    /// A memory or symbol operand, which no form here takes.
    other,
};

/// Which operands a form takes, in AT&T order (destination last), after
/// an 8-bit immediate when the form has one (`Form.imm`).
const Shape = enum {
    /// `xmm, xmm`: ModRM.rm the source, ModRM.reg the destination.
    xx,
    /// `xmm, xmm` or `%xmm0, xmm, xmm`: xmm0 is implicit (`pblendvb`,
    /// `sha256rnds2`).
    xx0,
    /// `xmm`: ModRM.rm, with ModRM.reg the opcode extension `ext` (the
    /// shifts by an immediate).
    x_ext,
    /// `xmm, gpr`: ModRM.reg the general-purpose register (`pmovmskb`).
    x_g,
    /// `xmm, gpr`: ModRM.reg the xmm register (`pextrd`, `movd` out).
    x_g_mr,
    /// `gpr, xmm`: ModRM.reg the xmm register (`pinsrd`, `movd` in).
    g_x,
};

/// The general-purpose register sizes a form takes, and whether a 64-bit
/// one sets REX.W.
const Gpr = enum { r32, r64, r32_r64, r32_r64_w };

const Form = struct {
    name: []const u8,
    /// Mandatory prefix: 0x66, 0xf2, 0xf3, or 0 for none.
    prefix: u8,
    /// The opcode bytes, from 0x0f on.
    op: []const u8,
    shape: Shape = .xx,
    imm: bool = false,
    ext: u3 = 0,
    gpr: Gpr = .r32,
    feature: ?Feature = null,
};

fn f66(name: []const u8, op: u8) Form {
    return .{ .name = name, .prefix = 0x66, .op = &.{ 0x0f, op } };
}

fn np(name: []const u8, op: u8) Form {
    return .{ .name = name, .prefix = 0, .op = &.{ 0x0f, op } };
}

fn f38(name: []const u8, op: u8, feature: Feature) Form {
    return .{ .name = name, .prefix = 0x66, .op = &.{ 0x0f, 0x38, op }, .feature = feature };
}

fn f3a(name: []const u8, op: u8, feature: Feature) Form {
    return .{ .name = name, .prefix = 0x66, .op = &.{ 0x0f, 0x3a, op }, .imm = true, .feature = feature };
}

fn with(f: Form, prefix: u8) Form {
    var g = f;
    g.prefix = prefix;
    return g;
}

fn shiftImm(name: []const u8, op: u8, ext: u3) Form {
    return .{ .name = name, .prefix = 0x66, .op = &.{ 0x0f, op }, .shape = .x_ext, .imm = true, .ext = ext };
}

fn gpr(f: Form, shape: Shape, sizes: Gpr) Form {
    var g = f;
    g.shape = shape;
    g.gpr = sizes;
    return g;
}

fn imm(f: Form) Form {
    var g = f;
    g.imm = true;
    return g;
}

fn xx0(f: Form) Form {
    var g = f;
    g.shape = .xx0;
    return g;
}

/// The forms that upstream's assembler takes, a name's forms together.
/// Upstream refuses `movq`, `pavgb`, `pavgw`, `rcpps`, `rsqrtps`,
/// `mpsadbw`, `maskmovdqu` and the `pcmp?str?` family, so they are not
/// here.
const forms = [_]Form{
    // SSE2 integer operations, 66 0f xx.
    f66("paddb", 0xfc),                                                                                f66("paddw", 0xfd),                                                                                    f66("paddd", 0xfe),                                                                    f66("paddq", 0xd4),
    f66("psubb", 0xf8),                                                                                f66("psubw", 0xf9),                                                                                    f66("psubd", 0xfa),                                                                    f66("psubq", 0xfb),
    f66("paddsb", 0xec),                                                                               f66("paddsw", 0xed),                                                                                   f66("paddusb", 0xdc),                                                                  f66("paddusw", 0xdd),
    f66("psubsb", 0xe8),                                                                               f66("psubsw", 0xe9),                                                                                   f66("psubusb", 0xd8),                                                                  f66("psubusw", 0xd9),
    f66("pmullw", 0xd5),                                                                               f66("pmulhw", 0xe5),                                                                                   f66("pmulhuw", 0xe4),                                                                  f66("pmuludq", 0xf4),
    f66("pmaddwd", 0xf5),                                                                              f66("pminub", 0xda),                                                                                   f66("pmaxub", 0xde),                                                                   f66("pminsw", 0xea),
    f66("pmaxsw", 0xee),                                                                               f66("psadbw", 0xf6),                                                                                   f66("pand", 0xdb),                                                                     f66("pandn", 0xdf),
    f66("por", 0xeb),                                                                                  f66("pxor", 0xef),                                                                                     f66("pcmpeqb", 0x74),                                                                  f66("pcmpeqw", 0x75),
    f66("pcmpeqd", 0x76),                                                                              f66("pcmpgtb", 0x64),                                                                                  f66("pcmpgtw", 0x65),                                                                  f66("pcmpgtd", 0x66),
    f66("packsswb", 0x63),                                                                             f66("packuswb", 0x67),                                                                                 f66("packssdw", 0x6b),                                                                 f66("punpcklbw", 0x60),
    f66("punpcklwd", 0x61),                                                                            f66("punpckldq", 0x62),                                                                                f66("punpcklqdq", 0x6c),                                                               f66("punpckhbw", 0x68),
    f66("punpckhwd", 0x69),                                                                            f66("punpckhdq", 0x6a),                                                                                f66("punpckhqdq", 0x6d),                                                               f66("movdqa", 0x6f),
    with(f66("movdqu", 0x6f), 0xf3),                                                                   imm(f66("pshufd", 0x70)),                                                                              imm(with(f66("pshuflw", 0x70), 0xf2)),                                                 imm(with(f66("pshufhw", 0x70), 0xf3)),
    // Shifts by xmm (66 0f xx) or by an immediate (66 0f 71-73 /ext).
    f66("psllw", 0xf1),                                                                                shiftImm("psllw", 0x71, 6),                                                                            f66("pslld", 0xf2),                                                                    shiftImm("pslld", 0x72, 6),
    f66("psllq", 0xf3),                                                                                shiftImm("psllq", 0x73, 6),                                                                            f66("psrlw", 0xd1),                                                                    shiftImm("psrlw", 0x71, 2),
    f66("psrld", 0xd2),                                                                                shiftImm("psrld", 0x72, 2),                                                                            f66("psrlq", 0xd3),                                                                    shiftImm("psrlq", 0x73, 2),
    f66("psraw", 0xe1),                                                                                shiftImm("psraw", 0x71, 4),                                                                            f66("psrad", 0xe2),                                                                    shiftImm("psrad", 0x72, 4),
    shiftImm("pslldq", 0x73, 7),                                                                       shiftImm("psrldq", 0x73, 3),
    // Between xmm and general-purpose registers. pmovmskb and movmsk*
    // take a 64-bit register without REX.W, as upstream encodes them.
                                                                              gpr(f66("pmovmskb", 0xd7), .x_g, .r32_r64),                                            gpr(np("movmskps", 0x50), .x_g, .r32_r64),
    gpr(f66("movmskpd", 0x50), .x_g, .r32_r64),                                                        gpr(f66("movd", 0x6e), .g_x, .r32),                                                                    gpr(f66("movd", 0x7e), .x_g_mr, .r32),                                                 imm(gpr(f66("pextrw", 0xc5), .x_g, .r32)),
    imm(gpr(f66("pinsrw", 0xc4), .g_x, .r32)),
    // SSE and SSE2 floating point.
                                                            np("movaps", 0x28),                                                                                    f66("movapd", 0x28),                                                                   np("movups", 0x10),
    f66("movupd", 0x10),                                                                               with(np("movss", 0x10), 0xf3),                                                                         with(np("movsd", 0x10), 0xf2),                                                         np("movhlps", 0x12),
    np("movlhps", 0x16),                                                                               np("andps", 0x54),                                                                                     f66("andpd", 0x54),                                                                    np("andnps", 0x55),
    f66("andnpd", 0x55),                                                                               np("orps", 0x56),                                                                                      f66("orpd", 0x56),                                                                     np("xorps", 0x57),
    f66("xorpd", 0x57),                                                                                np("unpcklps", 0x14),                                                                                  np("unpckhps", 0x15),                                                                  f66("unpcklpd", 0x14),
    f66("unpckhpd", 0x15),                                                                             np("addps", 0x58),                                                                                     f66("addpd", 0x58),                                                                    with(np("addss", 0x58), 0xf3),
    with(np("addsd", 0x58), 0xf2),                                                                     np("mulps", 0x59),                                                                                     f66("mulpd", 0x59),                                                                    with(np("mulss", 0x59), 0xf3),
    with(np("mulsd", 0x59), 0xf2),                                                                     np("subps", 0x5c),                                                                                     f66("subpd", 0x5c),                                                                    with(np("subss", 0x5c), 0xf3),
    with(np("subsd", 0x5c), 0xf2),                                                                     np("minps", 0x5d),                                                                                     f66("minpd", 0x5d),                                                                    with(np("minss", 0x5d), 0xf3),
    with(np("minsd", 0x5d), 0xf2),                                                                     np("divps", 0x5e),                                                                                     f66("divpd", 0x5e),                                                                    with(np("divss", 0x5e), 0xf3),
    with(np("divsd", 0x5e), 0xf2),                                                                     np("maxps", 0x5f),                                                                                     f66("maxpd", 0x5f),                                                                    with(np("maxss", 0x5f), 0xf3),
    with(np("maxsd", 0x5f), 0xf2),                                                                     np("sqrtps", 0x51),                                                                                    f66("sqrtpd", 0x51),                                                                   with(np("sqrtss", 0x51), 0xf3),
    with(np("sqrtsd", 0x51), 0xf2),                                                                    np("ucomiss", 0x2e),                                                                                   f66("ucomisd", 0x2e),                                                                  np("comiss", 0x2f),
    f66("comisd", 0x2f),                                                                               imm(np("shufps", 0xc6)),                                                                               imm(f66("shufpd", 0xc6)),                                                              imm(np("cmpps", 0xc2)),
    imm(f66("cmppd", 0xc2)),                                                                           imm(with(np("cmpss", 0xc2), 0xf3)),                                                                    imm(with(np("cmpsd", 0xc2), 0xf2)),                                                    np("cvtdq2ps", 0x5b),
    f66("cvtps2dq", 0x5b),                                                                             with(np("cvttps2dq", 0x5b), 0xf3),                                                                     np("cvtps2pd", 0x5a),                                                                  f66("cvtpd2ps", 0x5a),
    with(np("cvtss2sd", 0x5a), 0xf3),                                                                  with(np("cvtsd2ss", 0x5a), 0xf2),                                                                      with(np("cvtdq2pd", 0xe6), 0xf3),                                                      with(np("cvtpd2dq", 0xe6), 0xf2),
    f66("cvttpd2dq", 0xe6),                                                                            gpr(with(np("cvtsi2ss", 0x2a), 0xf3), .g_x, .r32_r64_w),                                               gpr(with(np("cvtsi2sd", 0x2a), 0xf2), .g_x, .r32_r64_w),                               gpr(with(np("cvttss2si", 0x2c), 0xf3), .x_g, .r32_r64_w),
    gpr(with(np("cvttsd2si", 0x2c), 0xf2), .x_g, .r32_r64_w),                                          gpr(with(np("cvtss2si", 0x2d), 0xf3), .x_g, .r32_r64_w),                                               gpr(with(np("cvtsd2si", 0x2d), 0xf2), .x_g, .r32_r64_w),
    // SSSE3, 66 0f 38 xx and 66 0f 3a 0f.
                                  f38("pshufb", 0x00, .ssse3),
    f38("phaddw", 0x01, .ssse3),                                                                       f38("phaddd", 0x02, .ssse3),                                                                           f38("phaddsw", 0x03, .ssse3),                                                          f38("pmaddubsw", 0x04, .ssse3),
    f38("phsubw", 0x05, .ssse3),                                                                       f38("phsubd", 0x06, .ssse3),                                                                           f38("phsubsw", 0x07, .ssse3),                                                          f38("psignb", 0x08, .ssse3),
    f38("psignw", 0x09, .ssse3),                                                                       f38("psignd", 0x0a, .ssse3),                                                                           f38("pmulhrsw", 0x0b, .ssse3),                                                         f38("pabsb", 0x1c, .ssse3),
    f38("pabsw", 0x1d, .ssse3),                                                                        f38("pabsd", 0x1e, .ssse3),                                                                            f3a("palignr", 0x0f, .ssse3),
    // SSE4.1.
                                                             xx0(f38("pblendvb", 0x10, .sse4_1)),
    xx0(f38("blendvps", 0x14, .sse4_1)),                                                               xx0(f38("blendvpd", 0x15, .sse4_1)),                                                                   f38("ptest", 0x17, .sse4_1),                                                           f38("pmovsxbw", 0x20, .sse4_1),
    f38("pmovsxbd", 0x21, .sse4_1),                                                                    f38("pmovsxbq", 0x22, .sse4_1),                                                                        f38("pmovsxwd", 0x23, .sse4_1),                                                        f38("pmovsxwq", 0x24, .sse4_1),
    f38("pmovsxdq", 0x25, .sse4_1),                                                                    f38("pmuldq", 0x28, .sse4_1),                                                                          f38("pcmpeqq", 0x29, .sse4_1),                                                         f38("packusdw", 0x2b, .sse4_1),
    f38("pmovzxbw", 0x30, .sse4_1),                                                                    f38("pmovzxbd", 0x31, .sse4_1),                                                                        f38("pmovzxbq", 0x32, .sse4_1),                                                        f38("pmovzxwd", 0x33, .sse4_1),
    f38("pmovzxwq", 0x34, .sse4_1),                                                                    f38("pmovzxdq", 0x35, .sse4_1),                                                                        f38("pminsb", 0x38, .sse4_1),                                                          f38("pminsd", 0x39, .sse4_1),
    f38("pminuw", 0x3a, .sse4_1),                                                                      f38("pminud", 0x3b, .sse4_1),                                                                          f38("pmaxsb", 0x3c, .sse4_1),                                                          f38("pmaxsd", 0x3d, .sse4_1),
    f38("pmaxuw", 0x3e, .sse4_1),                                                                      f38("pmaxud", 0x3f, .sse4_1),                                                                          f38("pmulld", 0x40, .sse4_1),                                                          f38("phminposuw", 0x41, .sse4_1),
    f3a("roundps", 0x08, .sse4_1),                                                                     f3a("roundpd", 0x09, .sse4_1),                                                                         f3a("roundss", 0x0a, .sse4_1),                                                         f3a("roundsd", 0x0b, .sse4_1),
    f3a("blendps", 0x0c, .sse4_1),                                                                     f3a("blendpd", 0x0d, .sse4_1),                                                                         f3a("pblendw", 0x0e, .sse4_1),                                                         f3a("insertps", 0x21, .sse4_1),
    f3a("dpps", 0x40, .sse4_1),                                                                        f3a("dppd", 0x41, .sse4_1),                                                                            gpr(f3a("pextrb", 0x14, .sse4_1), .x_g_mr, .r32),                                      gpr(f3a("pextrd", 0x16, .sse4_1), .x_g_mr, .r32),
    gpr(f3a("pextrq", 0x16, .sse4_1), .x_g_mr, .r64),                                                  gpr(f3a("extractps", 0x17, .sse4_1), .x_g_mr, .r32),                                                   gpr(f3a("pinsrb", 0x20, .sse4_1), .g_x, .r32),                                         gpr(f3a("pinsrd", 0x22, .sse4_1), .g_x, .r32),
    gpr(f3a("pinsrq", 0x22, .sse4_1), .g_x, .r64),
    // SSE4.2.
                                                        f38("pcmpgtq", 0x37, .sse4_2),
    // SHA, np 0f 38 xx and np 0f 3a cc (std's sha2 with -mcpu sha and avx2).
                                                                            .{ .name = "sha1nexte", .prefix = 0, .op = &.{ 0x0f, 0x38, 0xc8 }, .feature = .sha },  .{ .name = "sha1msg1", .prefix = 0, .op = &.{ 0x0f, 0x38, 0xc9 }, .feature = .sha },
    .{ .name = "sha1msg2", .prefix = 0, .op = &.{ 0x0f, 0x38, 0xca }, .feature = .sha },               .{ .name = "sha256rnds2", .prefix = 0, .op = &.{ 0x0f, 0x38, 0xcb }, .shape = .xx0, .feature = .sha }, .{ .name = "sha256msg1", .prefix = 0, .op = &.{ 0x0f, 0x38, 0xcc }, .feature = .sha }, .{ .name = "sha256msg2", .prefix = 0, .op = &.{ 0x0f, 0x38, 0xcd }, .feature = .sha },
    .{ .name = "sha1rnds4", .prefix = 0, .op = &.{ 0x0f, 0x3a, 0xcc }, .imm = true, .feature = .sha },
};

fn known(mnemonic: []const u8) bool {
    for (forms) |f| if (std.mem.eql(u8, f.name, mnemonic)) return true;
    return false;
}

fn gprFits(sizes: Gpr, size: Size) bool {
    return switch (sizes) {
        .r32 => size == .dword,
        .r64 => size == .qword,
        .r32_r64, .r32_r64_w => size == .dword or size == .qword,
    };
}

/// The register operands `ops` give `f`, after its immediate: ModRM.reg
/// and ModRM.rm, and whether a 64-bit general-purpose one sets REX.W.
fn match(f: Form, ops: []const Operand) ?struct { reg: u4, rm: u4, w: bool } {
    const x = struct {
        fn xmm(op: Operand) ?u4 {
            return if (op == .xmm) @backingInt(op.xmm) else null;
        }
    }.xmm;
    switch (f.shape) {
        .xx => if (ops.len == 2) return .{ .reg = x(ops[1]) orelse return null, .rm = x(ops[0]) orelse return null, .w = false },
        .xx0 => {
            const rest = if (ops.len == 3 and ops[0] == .xmm and ops[0].xmm == .xmm0) ops[1..] else ops;
            if (rest.len == 2) return .{ .reg = x(rest[1]) orelse return null, .rm = x(rest[0]) orelse return null, .w = false };
        },
        .x_ext => if (ops.len == 1) return .{ .reg = f.ext, .rm = x(ops[0]) orelse return null, .w = false },
        .x_g, .x_g_mr, .g_x => if (ops.len == 2) {
            const g = if (f.shape == .g_x) ops[0] else ops[1];
            const v = x(if (f.shape == .g_x) ops[1] else ops[0]) orelse return null;
            if (g != .reg or !gprFits(f.gpr, g.reg.size)) return null;
            const r: u4 = @backingInt(g.reg.reg);
            const w = g.reg.size == .qword and f.gpr != .r32_r64;
            return if (f.shape == .x_g) .{ .reg = r, .rm = v, .w = w } else .{ .reg = v, .rm = r, .w = w };
        },
    }
    return null;
}

/// Assembles `prefix mnemonic ops` (in AT&T order) into `e` for `cpu`,
/// or returns why not; `.unknown` for a mnemonic not in this file.
pub fn assemble(e: *Encoder, cpu: std.Target.Cpu, prefix: asm_insn.Prefix, mnemonic: []const u8, ops: []const Operand) Allocator.Error!?Fail {
    if (!known(mnemonic)) {
        // `pxorq`: upstream's suffix sizes the xmm registers, and fails.
        if (mnemonic.len > 1 and std.mem.findScalar(u8, "bwlqt", mnemonic[mnemonic.len - 1]) != null and known(mnemonic[0 .. mnemonic.len - 1])) return .invalid_size;
        return .unknown;
    }
    // `movsd` and `cmpsd` without xmm operands are string instructions.
    for (ops) |op| {
        if (op == .xmm) break;
    } else return .unknown;
    for (ops) |op| if (op == .other) return .xmm_memory;
    for (forms) |f| {
        if (!std.mem.eql(u8, f.name, mnemonic)) continue;
        const regs = if (f.imm) (if (ops.len != 0 and ops[0] == .imm) ops[1..] else continue) else ops;
        const m = match(f, regs) orelse continue;
        // An 8-bit immediate, signed or not.
        const imm_byte: u8 = if (f.imm) (if (std.math.cast(i8, ops[0].imm)) |v| @bitCast(v) else std.math.cast(u8, ops[0].imm) orelse return .operands) else 0;
        if (prefix != .none) return .prefix;
        if (f.feature) |feat| if (!cpu.has(.x86, feat)) return .{ .feature = feat };
        try e.asmModRm(if (m.w) .qword else null, f.prefix, f.op, .{ .reg = @fromBackingInt(m.reg) }, .{ .reg = @fromBackingInt(m.rm) }, imm_byte, @intFromBool(f.imm));
        return null;
    }
    return .operands;
}
