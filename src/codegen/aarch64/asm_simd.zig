//! aarch64 inline assembly's Advanced SIMD instructions: `table` names
//! each instruction with the shape of its operands (`Kind`) and its
//! encoding with the registers, the Q bit and the size zero, and
//! `Match` reads the operands of one statement against a shape. The
//! instructions whose operands decide the encoding (`mov`, `dup`, `ins`,
//! `movi`, `tbl`, `ext`, the structure loads and stores) are functions of
//! their own. Every form is checked against upstream's assembler (LLVM),
//! which also decides what is an error.

const std = @import("std");
const asm_insn = @import("asm_insn.zig");
const Asm = asm_insn.Asm;
const Error = Asm.Error;
const Operand = asm_insn.Operand;
const Arrangement = asm_insn.Arrangement;
const Feature = std.Target.aarch64.Feature;

/// Element sizes an instruction takes, a bit for each: bytes, halfwords,
/// words and doublewords.
const Sizes = u4;
const sz_b: Sizes = 1;
const sz_h: Sizes = 2;
const sz_s: Sizes = 4;
const sz_d: Sizes = 8;
const bhs: Sizes = 7;
const hs: Sizes = 6;
const all: Sizes = 15;

/// Bit 28 and bit 30 make the scalar form of a vector encoding.
const scalar_form: u32 = 0x50000000;

/// The shape of an instruction's operands. T is an arrangement, Tw the
/// one of elements twice as wide, Tn of elements half as wide.
const Kind = enum {
    /// `Vd.T, Vn.T, Vm.T`, and of scalars `Dd, Dn, Dm`.
    same3,
    /// `Vd.T, Vn.T, Vm.T` of bytes, whose encoding has no size.
    logic3,
    /// `same3` of floating-point elements.
    fp3,
    /// `Vd.T, Vn.T`, and of scalars.
    misc2,
    /// `Vd.T, Vn.T, #0`.
    zero2,
    /// `misc2` of floating-point elements.
    fp2,
    /// `Vd.T, Vn.T, #0.0`.
    fpzero2,
    /// `Vd.4s, Vn.16b, Vm.16b`: words from four bytes each.
    dot,
    /// `Vd.Tw, Vn.T` of half as many elements (`saddlp`).
    long2,
    /// `Vd.Tn, Vn.T` (`xtn`), and with a 2 the high half.
    narrow2,
    /// `Vd.Tw, Vn.T, #bits` of an element.
    shll,
    fcvtn,
    fcvtl,
    fcvtxn,
    /// `Vd.Tw, Vn.T, Vm.T`, and with a 2 of the high halves.
    long3,
    /// `Vd.Tw, Vn.Tw, Vm.T`.
    wide3,
    /// `Vd.Tn, Vn.T, Vm.T`.
    narrow3,
    /// `Vd.T, Vn.T, #shift` to the right, 1 to the element's bits.
    shift_r,
    /// To the left, 0 to one less than the element's bits.
    shift_l,
    /// `Vd.Tn, Vn.T, #shift` to the right.
    shift_narrow,
    /// `Vd.Tw, Vn.T, #shift` to the left.
    shift_long,
    /// `shift_long` by zero (`sxtl`).
    extend_long,
    /// `Vd.T, Vn.T, #fbits` of floating-point elements.
    shift_fp,
    /// `Bd, Vn.T`: a scalar of the element's size.
    across,
    /// `Hd, Vn.T`: a scalar of twice the element's size.
    across_long,
    /// `Sd, Vn.4s`.
    across_fp,
    /// `Vd.T, Vn.T, Vm.Ts[i]`.
    elem,
    elem_fp,
    /// `Vd.Tw, Vn.T, Vm.Ts[i]`.
    elem_long,
    /// `Dd, Vn.2d`.
    pair,
    /// `Sd, Vn.2s` and `Dd, Vn.2d`.
    fpair,
    /// Two, three and four vectors of the instruction's one arrangement.
    v2,
    v3,
    v4,
    /// `Qd, Qn, Vm.T`.
    qqv,
    /// `Qd, Sn, Vm.T`.
    qsv,
    /// `Sd, Sn`.
    ss,
    /// `Vd.2d, Vn.2d, Vm.2d, #imm6`.
    xar,

    /// Whether the mnemonic with a 2 after it is the form on the high
    /// half of a vector.
    fn hasHigh(k: Kind) bool {
        return switch (k) {
            .narrow2, .shll, .fcvtn, .fcvtl, .fcvtxn, .long3, .wide3, .narrow3, .shift_narrow, .shift_long, .extend_long, .elem_long => true,
            else => false,
        };
    }
};

const Insn = struct {
    name: []const u8,
    kind: Kind,
    base: u32,
    /// The element sizes of the vector form; for floating point, nonzero
    /// where there is one.
    sizes: Sizes = 0,
    /// The sizes of the scalar form.
    scalar: Sizes = 0,
    feature: ?Feature = null,
    /// An alias with the two sources the other way around (`cmlo`).
    swap: bool = false,
    /// The one arrangement of `v2`, `v3`, `v4`, `qqv` and `qsv`.
    arr: Arrangement = .@"16b",
};

fn i(name: []const u8, kind: Kind, base: u32, sizes: Sizes, scalar: Sizes) Insn {
    return .{ .name = name, .kind = kind, .base = base, .sizes = sizes, .scalar = scalar };
}

fn swapped(name: []const u8, kind: Kind, base: u32, scalar: Sizes) Insn {
    return .{ .name = name, .kind = kind, .base = base, .sizes = all, .scalar = scalar, .swap = true };
}

fn crypto(name: []const u8, kind: Kind, base: u32, arr: Arrangement, feature: Feature) Insn {
    return .{ .name = name, .kind = kind, .base = base, .arr = arr, .feature = feature };
}

fn rdm(name: []const u8, kind: Kind, base: u32) Insn {
    return .{ .name = name, .kind = kind, .base = base, .sizes = hs, .scalar = hs, .feature = .rdm };
}

const table = [_]Insn{
    i("shadd", .same3, 0x0E200400, bhs, 0),
    i("sqadd", .same3, 0x0E200C00, all, all),
    i("srhadd", .same3, 0x0E201400, bhs, 0),
    i("shsub", .same3, 0x0E202400, bhs, 0),
    i("sqsub", .same3, 0x0E202C00, all, all),
    i("cmgt", .same3, 0x0E203400, all, sz_d),
    i("cmge", .same3, 0x0E203C00, all, sz_d),
    i("sshl", .same3, 0x0E204400, all, sz_d),
    i("sqshl", .same3, 0x0E204C00, all, all),
    i("srshl", .same3, 0x0E205400, all, sz_d),
    i("sqrshl", .same3, 0x0E205C00, all, all),
    i("smax", .same3, 0x0E206400, bhs, 0),
    i("smin", .same3, 0x0E206C00, bhs, 0),
    i("sabd", .same3, 0x0E207400, bhs, 0),
    i("saba", .same3, 0x0E207C00, bhs, 0),
    i("add", .same3, 0x0E208400, all, sz_d),
    i("cmtst", .same3, 0x0E208C00, all, sz_d),
    i("mla", .same3, 0x0E209400, bhs, 0),
    i("mul", .same3, 0x0E209C00, bhs, 0),
    i("smaxp", .same3, 0x0E20A400, bhs, 0),
    i("sminp", .same3, 0x0E20AC00, bhs, 0),
    i("sqdmulh", .same3, 0x0E20B400, hs, hs),
    i("addp", .same3, 0x0E20BC00, all, 0),
    i("uhadd", .same3, 0x2E200400, bhs, 0),
    i("uqadd", .same3, 0x2E200C00, all, all),
    i("urhadd", .same3, 0x2E201400, bhs, 0),
    i("uhsub", .same3, 0x2E202400, bhs, 0),
    i("uqsub", .same3, 0x2E202C00, all, all),
    i("cmhi", .same3, 0x2E203400, all, sz_d),
    i("cmhs", .same3, 0x2E203C00, all, sz_d),
    i("ushl", .same3, 0x2E204400, all, sz_d),
    i("uqshl", .same3, 0x2E204C00, all, all),
    i("urshl", .same3, 0x2E205400, all, sz_d),
    i("uqrshl", .same3, 0x2E205C00, all, all),
    i("umax", .same3, 0x2E206400, bhs, 0),
    i("umin", .same3, 0x2E206C00, bhs, 0),
    i("uabd", .same3, 0x2E207400, bhs, 0),
    i("uaba", .same3, 0x2E207C00, bhs, 0),
    i("sub", .same3, 0x2E208400, all, sz_d),
    i("cmeq", .same3, 0x2E208C00, all, sz_d),
    i("mls", .same3, 0x2E209400, bhs, 0),
    i("pmul", .same3, 0x2E209C00, sz_b, 0),
    i("umaxp", .same3, 0x2E20A400, bhs, 0),
    i("uminp", .same3, 0x2E20AC00, bhs, 0),
    i("sqrdmulh", .same3, 0x2E20B400, hs, hs),
    rdm("sqrdmlah", .same3, 0x2E008400),
    rdm("sqrdmlsh", .same3, 0x2E008C00),
    swapped("cmlo", .same3, 0x2E203400, sz_d),
    swapped("cmls", .same3, 0x2E203C00, sz_d),
    swapped("cmlt", .same3, 0x0E203400, sz_d),
    swapped("cmle", .same3, 0x0E203C00, sz_d),
    .{ .name = "sdot", .kind = .dot, .base = 0x0E809400, .feature = .dotprod },
    .{ .name = "udot", .kind = .dot, .base = 0x2E809400, .feature = .dotprod },
    i("uzp1", .same3, 0x0E001800, all, 0),
    i("trn1", .same3, 0x0E002800, all, 0),
    i("zip1", .same3, 0x0E003800, all, 0),
    i("uzp2", .same3, 0x0E005800, all, 0),
    i("trn2", .same3, 0x0E006800, all, 0),
    i("zip2", .same3, 0x0E007800, all, 0),

    i("and", .logic3, 0x0E201C00, 0, 0),
    i("bic", .logic3, 0x0E601C00, 0, 0),
    i("orr", .logic3, 0x0EA01C00, 0, 0),
    i("orn", .logic3, 0x0EE01C00, 0, 0),
    i("eor", .logic3, 0x2E201C00, 0, 0),
    i("bsl", .logic3, 0x2E601C00, 0, 0),
    i("bit", .logic3, 0x2EA01C00, 0, 0),
    i("bif", .logic3, 0x2EE01C00, 0, 0),

    i("fmaxnm", .fp3, 0x0E20C400, 1, 0),
    i("fmla", .fp3, 0x0E20CC00, 1, 0),
    i("fadd", .fp3, 0x0E20D400, 1, 0),
    i("fmulx", .fp3, 0x0E20DC00, 1, 1),
    i("fcmeq", .fp3, 0x0E20E400, 1, 1),
    i("fmax", .fp3, 0x0E20F400, 1, 0),
    i("frecps", .fp3, 0x0E20FC00, 1, 1),
    i("fminnm", .fp3, 0x0EA0C400, 1, 0),
    i("fmls", .fp3, 0x0EA0CC00, 1, 0),
    i("fsub", .fp3, 0x0EA0D400, 1, 0),
    i("fmin", .fp3, 0x0EA0F400, 1, 0),
    i("frsqrts", .fp3, 0x0EA0FC00, 1, 1),
    i("fmaxnmp", .fp3, 0x2E20C400, 1, 0),
    i("faddp", .fp3, 0x2E20D400, 1, 0),
    i("fmul", .fp3, 0x2E20DC00, 1, 0),
    i("fcmge", .fp3, 0x2E20E400, 1, 1),
    i("facge", .fp3, 0x2E20EC00, 1, 1),
    i("fmaxp", .fp3, 0x2E20F400, 1, 0),
    i("fdiv", .fp3, 0x2E20FC00, 1, 0),
    i("fminnmp", .fp3, 0x2EA0C400, 1, 0),
    i("fabd", .fp3, 0x2EA0D400, 1, 1),
    i("fcmgt", .fp3, 0x2EA0E400, 1, 1),
    i("facgt", .fp3, 0x2EA0EC00, 1, 1),
    i("fminp", .fp3, 0x2EA0F400, 1, 0),
    swapped("fcmle", .fp3, 0x2E20E400, 1),
    swapped("fcmlt", .fp3, 0x2EA0E400, 1),
    swapped("facle", .fp3, 0x2E20EC00, 1),
    swapped("faclt", .fp3, 0x2EA0EC00, 1),

    i("rev64", .misc2, 0x0E200800, bhs, 0),
    i("rev16", .misc2, 0x0E201800, sz_b, 0),
    i("suqadd", .misc2, 0x0E203800, all, all),
    i("cls", .misc2, 0x0E204800, bhs, 0),
    i("cnt", .misc2, 0x0E205800, sz_b, 0),
    i("sqabs", .misc2, 0x0E207800, all, all),
    i("abs", .misc2, 0x0E20B800, all, sz_d),
    i("urecpe", .misc2, 0x0E21C800, sz_s, 0),
    i("rev32", .misc2, 0x2E200800, sz_b | sz_h, 0),
    i("usqadd", .misc2, 0x2E203800, all, all),
    i("clz", .misc2, 0x2E204800, bhs, 0),
    i("mvn", .misc2, 0x2E205800, sz_b, 0),
    i("not", .misc2, 0x2E205800, sz_b, 0),
    i("rbit", .misc2, 0x2E605800, sz_b, 0),
    i("sqneg", .misc2, 0x2E207800, all, all),
    i("neg", .misc2, 0x2E20B800, all, sz_d),
    i("ursqrte", .misc2, 0x2E21C800, sz_s, 0),
    i("cmgt", .zero2, 0x0E208800, all, sz_d),
    i("cmeq", .zero2, 0x0E209800, all, sz_d),
    i("cmlt", .zero2, 0x0E20A800, all, sz_d),
    i("cmge", .zero2, 0x2E208800, all, sz_d),
    i("cmle", .zero2, 0x2E209800, all, sz_d),
    i("saddlp", .long2, 0x0E202800, bhs, 0),
    i("sadalp", .long2, 0x0E206800, bhs, 0),
    i("uaddlp", .long2, 0x2E202800, bhs, 0),
    i("uadalp", .long2, 0x2E206800, bhs, 0),
    i("xtn", .narrow2, 0x0E212800, bhs, 0),
    i("sqxtn", .narrow2, 0x0E214800, bhs, bhs),
    i("sqxtun", .narrow2, 0x2E212800, bhs, bhs),
    i("uqxtn", .narrow2, 0x2E214800, bhs, bhs),
    i("shll", .shll, 0x2E213800, bhs, 0),

    i("frintn", .fp2, 0x0E218800, 1, 0),
    i("frintm", .fp2, 0x0E219800, 1, 0),
    i("fcvtns", .fp2, 0x0E21A800, 1, 1),
    i("fcvtms", .fp2, 0x0E21B800, 1, 1),
    i("fcvtas", .fp2, 0x0E21C800, 1, 1),
    i("scvtf", .fp2, 0x0E21D800, 1, 1),
    i("fabs", .fp2, 0x0EA0F800, 1, 0),
    i("frintp", .fp2, 0x0EA18800, 1, 0),
    i("frintz", .fp2, 0x0EA19800, 1, 0),
    i("fcvtps", .fp2, 0x0EA1A800, 1, 1),
    i("fcvtzs", .fp2, 0x0EA1B800, 1, 1),
    i("frecpe", .fp2, 0x0EA1D800, 1, 1),
    i("frecpx", .fp2, 0x0EA1F800, 0, 1),
    i("frinta", .fp2, 0x2E218800, 1, 0),
    i("frintx", .fp2, 0x2E219800, 1, 0),
    i("fcvtnu", .fp2, 0x2E21A800, 1, 1),
    i("fcvtmu", .fp2, 0x2E21B800, 1, 1),
    i("fcvtau", .fp2, 0x2E21C800, 1, 1),
    i("ucvtf", .fp2, 0x2E21D800, 1, 1),
    i("fneg", .fp2, 0x2EA0F800, 1, 0),
    i("frinti", .fp2, 0x2EA19800, 1, 0),
    i("fcvtpu", .fp2, 0x2EA1A800, 1, 1),
    i("fcvtzu", .fp2, 0x2EA1B800, 1, 1),
    i("frsqrte", .fp2, 0x2EA1D800, 1, 1),
    i("fsqrt", .fp2, 0x2EA1F800, 1, 0),
    .{ .name = "frint32z", .kind = .fp2, .base = 0x0E21E800, .sizes = 1, .feature = .fptoint },
    .{ .name = "frint32x", .kind = .fp2, .base = 0x2E21E800, .sizes = 1, .feature = .fptoint },
    .{ .name = "frint64z", .kind = .fp2, .base = 0x0E21F800, .sizes = 1, .feature = .fptoint },
    .{ .name = "frint64x", .kind = .fp2, .base = 0x2E21F800, .sizes = 1, .feature = .fptoint },
    i("fcmgt", .fpzero2, 0x0EA0C800, 1, 1),
    i("fcmeq", .fpzero2, 0x0EA0D800, 1, 1),
    i("fcmlt", .fpzero2, 0x0EA0E800, 1, 1),
    i("fcmge", .fpzero2, 0x2EA0C800, 1, 1),
    i("fcmle", .fpzero2, 0x2EA0D800, 1, 1),
    i("fcvtn", .fcvtn, 0x0E216800, 0, 0),
    i("fcvtl", .fcvtl, 0x0E217800, 0, 0),
    i("fcvtxn", .fcvtxn, 0x2E616800, 0, 0),

    i("saddl", .long3, 0x0E200000, bhs, 0),
    i("saddw", .wide3, 0x0E201000, bhs, 0),
    i("ssubl", .long3, 0x0E202000, bhs, 0),
    i("ssubw", .wide3, 0x0E203000, bhs, 0),
    i("addhn", .narrow3, 0x0E204000, bhs, 0),
    i("sabal", .long3, 0x0E205000, bhs, 0),
    i("subhn", .narrow3, 0x0E206000, bhs, 0),
    i("sabdl", .long3, 0x0E207000, bhs, 0),
    i("smlal", .long3, 0x0E208000, bhs, 0),
    i("sqdmlal", .long3, 0x0E209000, hs, hs),
    i("smlsl", .long3, 0x0E20A000, bhs, 0),
    i("sqdmlsl", .long3, 0x0E20B000, hs, hs),
    i("smull", .long3, 0x0E20C000, bhs, 0),
    i("sqdmull", .long3, 0x0E20D000, hs, hs),
    i("pmull", .long3, 0x0E20E000, sz_b | sz_d, 0),
    i("uaddl", .long3, 0x2E200000, bhs, 0),
    i("uaddw", .wide3, 0x2E201000, bhs, 0),
    i("usubl", .long3, 0x2E202000, bhs, 0),
    i("usubw", .wide3, 0x2E203000, bhs, 0),
    i("raddhn", .narrow3, 0x2E204000, bhs, 0),
    i("uabal", .long3, 0x2E205000, bhs, 0),
    i("rsubhn", .narrow3, 0x2E206000, bhs, 0),
    i("uabdl", .long3, 0x2E207000, bhs, 0),
    i("umlal", .long3, 0x2E208000, bhs, 0),
    i("umlsl", .long3, 0x2E20A000, bhs, 0),
    i("umull", .long3, 0x2E20C000, bhs, 0),

    i("sshr", .shift_r, 0x0F000400, all, sz_d),
    i("ssra", .shift_r, 0x0F001400, all, sz_d),
    i("srshr", .shift_r, 0x0F002400, all, sz_d),
    i("srsra", .shift_r, 0x0F003400, all, sz_d),
    i("shl", .shift_l, 0x0F005400, all, sz_d),
    i("sqshl", .shift_l, 0x0F007400, all, all),
    i("ushr", .shift_r, 0x2F000400, all, sz_d),
    i("usra", .shift_r, 0x2F001400, all, sz_d),
    i("urshr", .shift_r, 0x2F002400, all, sz_d),
    i("ursra", .shift_r, 0x2F003400, all, sz_d),
    i("sri", .shift_r, 0x2F004400, all, sz_d),
    i("sli", .shift_l, 0x2F005400, all, sz_d),
    i("sqshlu", .shift_l, 0x2F006400, all, all),
    i("uqshl", .shift_l, 0x2F007400, all, all),
    i("shrn", .shift_narrow, 0x0F008400, bhs, 0),
    i("rshrn", .shift_narrow, 0x0F008C00, bhs, 0),
    i("sqshrn", .shift_narrow, 0x0F009400, bhs, bhs),
    i("sqrshrn", .shift_narrow, 0x0F009C00, bhs, bhs),
    i("sqshrun", .shift_narrow, 0x2F008400, bhs, bhs),
    i("sqrshrun", .shift_narrow, 0x2F008C00, bhs, bhs),
    i("uqshrn", .shift_narrow, 0x2F009400, bhs, bhs),
    i("uqrshrn", .shift_narrow, 0x2F009C00, bhs, bhs),
    i("sshll", .shift_long, 0x0F00A400, bhs, 0),
    i("ushll", .shift_long, 0x2F00A400, bhs, 0),
    i("sxtl", .extend_long, 0x0F00A400, bhs, 0),
    i("uxtl", .extend_long, 0x2F00A400, bhs, 0),
    i("scvtf", .shift_fp, 0x0F00E400, 1, 1),
    i("fcvtzs", .shift_fp, 0x0F00FC00, 1, 1),
    i("ucvtf", .shift_fp, 0x2F00E400, 1, 1),
    i("fcvtzu", .shift_fp, 0x2F00FC00, 1, 1),

    i("addv", .across, 0x0E31B800, bhs, 0),
    i("smaxv", .across, 0x0E30A800, bhs, 0),
    i("sminv", .across, 0x0E31A800, bhs, 0),
    i("umaxv", .across, 0x2E30A800, bhs, 0),
    i("uminv", .across, 0x2E31A800, bhs, 0),
    i("saddlv", .across_long, 0x0E303800, bhs, 0),
    i("uaddlv", .across_long, 0x2E303800, bhs, 0),
    i("fmaxnmv", .across_fp, 0x2E30C800, 0, 0),
    i("fmaxv", .across_fp, 0x2E30F800, 0, 0),
    i("fminnmv", .across_fp, 0x2EB0C800, 0, 0),
    i("fminv", .across_fp, 0x2EB0F800, 0, 0),

    i("mul", .elem, 0x0F008000, hs, 0),
    i("mla", .elem, 0x2F000000, hs, 0),
    i("mls", .elem, 0x2F004000, hs, 0),
    i("sqdmulh", .elem, 0x0F00C000, hs, hs),
    i("sqrdmulh", .elem, 0x0F00D000, hs, hs),
    rdm("sqrdmlah", .elem, 0x2F00D000),
    rdm("sqrdmlsh", .elem, 0x2F00F000),
    i("fmla", .elem_fp, 0x0F801000, 1, 1),
    i("fmls", .elem_fp, 0x0F805000, 1, 1),
    i("fmul", .elem_fp, 0x0F809000, 1, 1),
    i("fmulx", .elem_fp, 0x2F809000, 1, 1),
    i("smlal", .elem_long, 0x0F002000, hs, 0),
    i("sqdmlal", .elem_long, 0x0F003000, hs, hs),
    i("smlsl", .elem_long, 0x0F006000, hs, 0),
    i("sqdmlsl", .elem_long, 0x0F007000, hs, hs),
    i("smull", .elem_long, 0x0F00A000, hs, 0),
    i("sqdmull", .elem_long, 0x0F00B000, hs, hs),
    i("umlal", .elem_long, 0x2F002000, hs, 0),
    i("umlsl", .elem_long, 0x2F006000, hs, 0),
    i("umull", .elem_long, 0x2F00A000, hs, 0),

    i("addp", .pair, 0x5EF1B800, 0, 0),
    i("faddp", .fpair, 0x7E30D800, 0, 0),
    i("fmaxp", .fpair, 0x7E30F800, 0, 0),
    i("fminp", .fpair, 0x7EB0F800, 0, 0),
    i("fmaxnmp", .fpair, 0x7E30C800, 0, 0),
    i("fminnmp", .fpair, 0x7EB0C800, 0, 0),

    crypto("aese", .v2, 0x4E284800, .@"16b", .aes),
    crypto("aesd", .v2, 0x4E285800, .@"16b", .aes),
    crypto("aesmc", .v2, 0x4E286800, .@"16b", .aes),
    crypto("aesimc", .v2, 0x4E287800, .@"16b", .aes),
    crypto("sha1c", .qsv, 0x5E000000, .@"4s", .sha2),
    crypto("sha1p", .qsv, 0x5E001000, .@"4s", .sha2),
    crypto("sha1m", .qsv, 0x5E002000, .@"4s", .sha2),
    crypto("sha1su0", .v3, 0x5E003000, .@"4s", .sha2),
    crypto("sha1h", .ss, 0x5E280800, .@"4s", .sha2),
    crypto("sha1su1", .v2, 0x5E281800, .@"4s", .sha2),
    crypto("sha256h", .qqv, 0x5E004000, .@"4s", .sha2),
    crypto("sha256h2", .qqv, 0x5E005000, .@"4s", .sha2),
    crypto("sha256su1", .v3, 0x5E006000, .@"4s", .sha2),
    crypto("sha256su0", .v2, 0x5E282800, .@"4s", .sha2),
    crypto("sha512h", .qqv, 0xCE608000, .@"2d", .sha3),
    crypto("sha512h2", .qqv, 0xCE608400, .@"2d", .sha3),
    crypto("sha512su0", .v2, 0xCEC08000, .@"2d", .sha3),
    crypto("sha512su1", .v3, 0xCE608800, .@"2d", .sha3),
    crypto("rax1", .v3, 0xCE608C00, .@"2d", .sha3),
    crypto("eor3", .v4, 0xCE000000, .@"16b", .sha3),
    crypto("bcax", .v4, 0xCE200000, .@"16b", .sha3),
    crypto("xar", .xar, 0xCE800000, .@"2d", .sha3),
};

/// The instructions `special` assembles.
const specials = [_][]const u8{ "mov", "dup", "ins", "smov", "movi", "mvni", "orr", "bic", "fmov", "tbl", "tbx", "ext", "ld1", "ld2", "ld3", "ld4", "st1", "st2", "st3", "st4", "ld1r", "ld2r", "ld3r", "ld4r" };

/// The word for `mnemonic_in`, an Advanced SIMD instruction, with `ops`,
/// or null for another instruction or other operands.
pub fn encode(a: *Asm, mnemonic_in: []const u8, ops: []const Operand) Error!?u32 {
    const eql = std.mem.eql;
    const dot = std.mem.findScalar(u8, mnemonic_in, '.') orelse mnemonic_in.len;
    const mnemonic = mnemonic_in[0..dot];
    // Apple's syntax has the arrangement on the mnemonic (`add.16b v0, v1, v2`).
    const suffix: ?Arrangement = if (dot == mnemonic_in.len) null else Arrangement.parse(mnemonic_in[dot + 1 ..]) orelse return null;
    var simd_operand = false;
    for (ops) |op| switch (op) {
        .vreg, .vlist, .velem => simd_operand = true,
        else => {},
    };
    if (!simd_operand) return null;
    var m: Match = .{ .a = a, .ops = ops, .suffix = suffix };
    var known = false;
    const word: u32 = word: {
        for (table) |insn| {
            m.high = false;
            if (!eql(u8, insn.name, mnemonic)) {
                if (!insn.kind.hasHigh() or mnemonic.len != insn.name.len + 1 or mnemonic[insn.name.len] != '2' or !std.mem.startsWith(u8, mnemonic, insn.name)) continue;
                m.high = true;
            }
            known = true;
            if (try m.one(insn)) |w| {
                if (insn.feature) |f| if (!a.cpu.has(.aarch64, f)) return a.needs(f);
                break :word w;
            }
        }
        for (specials) |name| if (eql(u8, name, mnemonic)) {
            known = true;
            if (try m.special(mnemonic)) |w| break :word w;
        };
        if (!known) return null;
        return a.fail("inline assembly: '{s}' does not take these operands; check each register's arrangement (such as '.16b') and the number of operands: '{s}'", .{ mnemonic, a.line });
    };
    if (!a.cpu.has(.aarch64, .neon)) return a.needs(.neon);
    return word;
}

const Match = struct {
    a: *Asm,
    ops: []const Operand,
    suffix: ?Arrangement,
    /// The mnemonic ends in the 2 of the high-half form.
    high: bool = false,

    /// The arrangement of operand `k`, a whole vector: its own, or the
    /// mnemonic's, never both.
    fn key(m: *const Match, k: usize) ?Arrangement {
        if (k >= m.ops.len or m.ops[k] != .vreg) return null;
        const v = m.ops[k].vreg;
        if (v.kind != .v or (v.arr != null) == (m.suffix != null)) return null;
        return v.arr orelse m.suffix;
    }

    /// The number of operand `k`, a whole vector of `arr`. With the
    /// arrangement on the mnemonic, the operand has none.
    fn vecAs(m: *const Match, k: usize, arr: Arrangement) ?u32 {
        if (k >= m.ops.len or m.ops[k] != .vreg) return null;
        const v = m.ops[k].vreg;
        if (v.kind != .v) return null;
        if (v.arr) |x| return if (x == arr and m.suffix == null) @backingInt(v.reg) else null;
        return if (m.suffix != null) @backingInt(v.reg) else null;
    }

    /// Log2 of the bytes of operand `k`, a scalar SIMD register (`b3` to
    /// `q3`). There is none with an arrangement on the mnemonic.
    fn scalarOf(m: *const Match, k: usize) ?u32 {
        if (k >= m.ops.len or m.ops[k] != .vreg or m.suffix != null) return null;
        const v = m.ops[k].vreg;
        if (v.arr != null) return null;
        return switch (v.kind) {
            .v => null,
            .b => 0,
            .h => 1,
            .s => 2,
            .d => 3,
            .q => 4,
        };
    }

    /// The number of operand `k`, a scalar register of `1 << log2` bytes.
    fn scalarAs(m: *const Match, k: usize, log2: u32) ?u32 {
        return if (m.scalarOf(k) == log2) m.num(k) else null;
    }

    /// The number of operand `k`, a 128-bit register as the crypto
    /// instructions name it: `q3`, or `v3` without an arrangement.
    fn wholeAs(m: *const Match, k: usize) ?u32 {
        if (k >= m.ops.len or m.ops[k] != .vreg) return null;
        const v = m.ops[k].vreg;
        return if (v.arr == null and (v.kind == .q or v.kind == .v)) @backingInt(v.reg) else null;
    }

    fn num(m: *const Match, k: usize) u32 {
        return @backingInt(m.ops[k].vreg.reg);
    }

    /// Operand `k`, an immediate from `lo` to `hi`, or null for another
    /// operand.
    fn imm(m: *const Match, k: usize, lo: u32, hi: u32, what: []const u8) Error!?u32 {
        if (k >= m.ops.len or m.ops[k] != .imm) return null;
        const value = try m.a.immIn(m.ops, k, lo, hi, what);
        return value;
    }

    /// The size field of integer elements of `arr`, if `sizes` has them.
    fn intSize(arr: Arrangement, sizes: Sizes) ?u32 {
        if (arr == .@"1d" or arr == .@"1q") return null;
        const log2 = arr.log2();
        return if (sizes >> @intCast(log2) & 1 != 0) log2 else null;
    }

    const FpForm = enum { three, two, shift, element };

    /// `base` for floating-point elements of `1 << log2` bytes: words as
    /// it is, doublewords with the sz bit, and halfwords, the `fullfp16`
    /// feature's, in the encoding `form` has for them.
    fn fpBase(m: *const Match, log2: u32, base: u32, form: FpForm) Error!?u32 {
        switch (log2) {
            1 => {
                if (!m.a.cpu.has(.aarch64, .fullfp16)) return m.a.needs(.fullfp16);
                return switch (form) {
                    .three => (base & ~@as(u32, 1 << 21 | 3 << 14)) | 1 << 22,
                    .two => base | 0x580000,
                    .shift => base,
                    .element => base & ~@as(u32, 1 << 23),
                };
            },
            2 => return base,
            3 => return if (form == .shift) base else base | 1 << 22,
            else => return null,
        }
    }

    /// The vector or the scalar form of floating-point operand `k`: log2
    /// of its elements' bytes and the bits that tell the forms apart.
    fn fpOperand(m: *const Match, k: usize, insn: Insn) ?struct { u32, u32, ?Arrangement } {
        if (m.key(k)) |arr| {
            if (insn.sizes == 0 or arr == .@"1d" or arr == .@"1q" or arr.log2() == 0) return null;
            return .{ arr.log2(), arr.q() << 30, arr };
        }
        const log2 = m.scalarOf(k) orelse return null;
        if (insn.scalar == 0 or log2 == 0 or log2 > 3) return null;
        return .{ log2, scalar_form, null };
    }

    /// Operand `k` of the form `fpOperand` found: a vector of `arr` or a
    /// scalar of `1 << log2` bytes.
    fn fpAs(m: *const Match, k: usize, log2: u32, arr: ?Arrangement) ?u32 {
        return if (arr) |x| m.vecAs(k, x) else m.scalarAs(k, log2);
    }

    fn one(m: *const Match, insn: Insn) Error!?u32 {
        const ops = m.ops;
        const base = insn.base;
        const high: u32 = @intFromBool(m.high);
        switch (insn.kind) {
            .same3 => {
                if (ops.len != 3) return null;
                const x: usize = if (insn.swap) 2 else 1;
                if (m.key(0)) |arr| {
                    const size = intSize(arr, insn.sizes) orelse return null;
                    const n = m.vecAs(x, arr) orelse return null;
                    const r = m.vecAs(3 - x, arr) orelse return null;
                    return base | arr.q() << 30 | size << 22 | r << 16 | n << 5 | m.num(0);
                }
                const log2 = m.scalarOf(0) orelse return null;
                if (log2 > 3 or insn.scalar >> @intCast(log2) & 1 == 0) return null;
                const n = m.scalarAs(x, log2) orelse return null;
                const r = m.scalarAs(3 - x, log2) orelse return null;
                return base | scalar_form | log2 << 22 | r << 16 | n << 5 | m.num(0);
            },
            .logic3 => {
                if (ops.len != 3) return null;
                const arr = m.key(0) orelse return null;
                if (arr.log2() != 0) return null;
                const n = m.vecAs(1, arr) orelse return null;
                const r = m.vecAs(2, arr) orelse return null;
                return base | arr.q() << 30 | r << 16 | n << 5 | m.num(0);
            },
            .fp3 => {
                if (ops.len != 3) return null;
                const x: usize = if (insn.swap) 2 else 1;
                const log2, const form, const arr = m.fpOperand(0, insn) orelse return null;
                // LLVM has no alias on half-precision scalars.
                if (insn.swap and arr == null and log2 == 1) return null;
                const n = m.fpAs(x, log2, arr) orelse return null;
                const r = m.fpAs(3 - x, log2, arr) orelse return null;
                const word = try m.fpBase(log2, base, .three) orelse return null;
                return word | form | r << 16 | n << 5 | m.num(0);
            },
            .misc2, .zero2 => {
                if (insn.kind == .zero2) {
                    if (ops.len != 3 or ops[2] != .imm) return null;
                    if (ops[2].imm != 0) return m.a.fail("inline assembly: '{s}' compares with a register or #0: '{s}'", .{ insn.name, m.a.line });
                } else if (ops.len != 2) return null;
                if (m.key(0)) |arr| {
                    const size = intSize(arr, insn.sizes) orelse return null;
                    const n = m.vecAs(1, arr) orelse return null;
                    return base | arr.q() << 30 | size << 22 | n << 5 | m.num(0);
                }
                const log2 = m.scalarOf(0) orelse return null;
                if (log2 > 3 or insn.scalar >> @intCast(log2) & 1 == 0) return null;
                const n = m.scalarAs(1, log2) orelse return null;
                return base | scalar_form | log2 << 22 | n << 5 | m.num(0);
            },
            .fp2, .fpzero2 => {
                if (insn.kind == .fpzero2) {
                    if (ops.len != 3) return null;
                    const zero = switch (ops[2]) {
                        .imm => |v| v == 0,
                        .fimm => |v| @as(u64, @bitCast(v)) == 0,
                        else => return null,
                    };
                    if (!zero) return m.a.fail("inline assembly: '{s}' compares with a register or #0.0: '{s}'", .{ insn.name, m.a.line });
                } else if (ops.len != 2) return null;
                const log2, const form, const arr = m.fpOperand(0, insn) orelse return null;
                // Rounding to an integer's range has no half precision.
                if (insn.feature == .fptoint and log2 == 1) return null;
                const n = m.fpAs(1, log2, arr) orelse return null;
                const word = try m.fpBase(log2, base, .two) orelse return null;
                return word | form | n << 5 | m.num(0);
            },
            .dot => {
                if (ops.len != 3) return null;
                const arr = m.key(0) orelse return null;
                if (arr.log2() != 2) return null;
                const bytes: Arrangement = .of(0, arr.q());
                const n = m.vecAs(1, bytes) orelse return null;
                const r = m.vecAs(2, bytes) orelse return null;
                return base | arr.q() << 30 | r << 16 | n << 5 | m.num(0);
            },
            .long2 => {
                if (ops.len != 2) return null;
                const arr = m.key(0) orelse return null;
                if (arr.log2() == 0 or arr == .@"1q") return null;
                const n = m.vecAs(1, .of(arr.log2() - 1, arr.q())) orelse return null;
                return base | arr.q() << 30 | (arr.log2() - 1) << 22 | n << 5 | m.num(0);
            },
            .narrow2 => {
                if (ops.len != 2) return null;
                if (m.key(0)) |arr| {
                    if (arr.log2() > 2 or arr.q() != high) return null;
                    const n = m.vecAs(1, .of(arr.log2() + 1, 1)) orelse return null;
                    return base | high << 30 | arr.log2() << 22 | n << 5 | m.num(0);
                }
                const log2 = m.scalarOf(0) orelse return null;
                if (log2 > 2 or insn.scalar == 0 or m.high) return null;
                const n = m.scalarAs(1, log2 + 1) orelse return null;
                return base | scalar_form | log2 << 22 | n << 5 | m.num(0);
            },
            .shll => {
                if (ops.len != 3) return null;
                const arr = m.key(0) orelse return null;
                if (arr.log2() == 0 or arr.log2() > 3 or arr.q() != 1) return null;
                const n = m.vecAs(1, .of(arr.log2() - 1, high)) orelse return null;
                const bits = @as(u32, 4) << @intCast(arr.log2());
                _ = try m.imm(2, bits, bits, "the shift, the bits of an element,") orelse return null;
                return base | high << 30 | (arr.log2() - 1) << 22 | n << 5 | m.num(0);
            },
            .fcvtn => {
                // To halfwords from words, or to words from doublewords.
                // LLVM has no form with the arrangement on the mnemonic
                // for these three.
                if (ops.len != 2 or m.suffix != null) return null;
                const arr = m.key(0) orelse return null;
                if ((arr.log2() != 1 and arr.log2() != 2) or arr.q() != high) return null;
                const n = m.vecAs(1, .of(arr.log2() + 1, 1)) orelse return null;
                return base | high << 30 | (arr.log2() - 1) << 22 | n << 5 | m.num(0);
            },
            .fcvtl => {
                if (ops.len != 2 or m.suffix != null) return null;
                const arr = m.key(0) orelse return null;
                if ((arr.log2() != 2 and arr.log2() != 3) or arr.q() != 1) return null;
                const n = m.vecAs(1, .of(arr.log2() - 1, high)) orelse return null;
                return base | high << 30 | (arr.log2() - 2) << 22 | n << 5 | m.num(0);
            },
            .fcvtxn => {
                if (ops.len != 2 or m.suffix != null) return null;
                if (m.key(0)) |arr| {
                    if (arr.log2() != 2 or arr.q() != high) return null;
                    const n = m.vecAs(1, .@"2d") orelse return null;
                    return base | high << 30 | n << 5 | m.num(0);
                }
                if (m.high or m.scalarOf(0) != 2) return null;
                const n = m.scalarAs(1, 3) orelse return null;
                return base | scalar_form | n << 5 | m.num(0);
            },
            .long3, .wide3, .narrow3 => {
                if (ops.len != 3) return null;
                if (m.key(0)) |arr| {
                    if (insn.kind == .narrow3) {
                        if (arr.log2() > 2 or arr.q() != high) return null;
                        const wide: Arrangement = .of(arr.log2() + 1, 1);
                        const n = m.vecAs(1, wide) orelse return null;
                        const r = m.vecAs(2, wide) orelse return null;
                        return base | high << 30 | arr.log2() << 22 | r << 16 | n << 5 | m.num(0);
                    }
                    if (arr == .@"1q") {
                        // pmull of two doublewords, the `aes` feature's.
                        if (insn.sizes & sz_d == 0 or insn.kind != .long3) return null;
                        const half: Arrangement = if (m.high) .@"2d" else .@"1d";
                        const n = m.vecAs(1, half) orelse return null;
                        const r = m.vecAs(2, half) orelse return null;
                        if (!m.a.cpu.has(.aarch64, .aes)) return m.a.needs(.aes);
                        return base | high << 30 | 3 << 22 | r << 16 | n << 5 | m.num(0);
                    }
                    if (arr.log2() == 0 or arr.q() != 1) return null;
                    const size = arr.log2() - 1;
                    if (insn.sizes >> @intCast(size) & 1 == 0) return null;
                    const half: Arrangement = .of(size, high);
                    const n = m.vecAs(1, if (insn.kind == .wide3) arr else half) orelse return null;
                    const r = m.vecAs(2, half) orelse return null;
                    return base | high << 30 | size << 22 | r << 16 | n << 5 | m.num(0);
                }
                // `sqdmlal s0, h1, h2`.
                const log2 = m.scalarOf(0) orelse return null;
                if (m.high or log2 == 0 or log2 > 3 or insn.scalar >> @intCast(log2 - 1) & 1 == 0) return null;
                const n = m.scalarAs(1, log2 - 1) orelse return null;
                const r = m.scalarAs(2, log2 - 1) orelse return null;
                return base | scalar_form | (log2 - 1) << 22 | r << 16 | n << 5 | m.num(0);
            },
            .shift_r, .shift_l => {
                if (ops.len != 3) return null;
                const log2: u32, const form: u32, const n: u32 = if (m.key(0)) |arr| .{
                    intSize(arr, insn.sizes) orelse return null,
                    arr.q() << 30,
                    m.vecAs(1, arr) orelse return null,
                } else operands: {
                    const log2 = m.scalarOf(0) orelse return null;
                    if (log2 > 3 or insn.scalar >> @intCast(log2) & 1 == 0) return null;
                    break :operands .{ log2, scalar_form, m.scalarAs(1, log2) orelse return null };
                };
                const bits = @as(u32, 8) << @intCast(log2);
                const field = if (insn.kind == .shift_r)
                    2 * bits - (try m.imm(2, 1, bits, "the shift right") orelse return null)
                else
                    bits + (try m.imm(2, 0, bits - 1, "the shift left") orelse return null);
                return base | form | field << 16 | n << 5 | m.num(0);
            },
            .shift_narrow => {
                if (ops.len != 3) return null;
                const log2: u32, const form: u32, const n: u32 = if (m.key(0)) |arr| operands: {
                    if (arr.log2() > 2 or arr.q() != high) return null;
                    break :operands .{ arr.log2(), high << 30, m.vecAs(1, .of(arr.log2() + 1, 1)) orelse return null };
                } else operands: {
                    const log2 = m.scalarOf(0) orelse return null;
                    if (log2 > 2 or insn.scalar == 0 or m.high) return null;
                    break :operands .{ log2, scalar_form, m.scalarAs(1, log2 + 1) orelse return null };
                };
                const bits = @as(u32, 8) << @intCast(log2);
                const shift = try m.imm(2, 1, bits, "the shift right") orelse return null;
                return base | form | (2 * bits - shift) << 16 | n << 5 | m.num(0);
            },
            .shift_long, .extend_long => {
                if (ops.len != @as(usize, if (insn.kind == .shift_long) 3 else 2)) return null;
                const arr = m.key(0) orelse return null;
                if (arr.log2() == 0 or arr.log2() > 3 or arr.q() != 1) return null;
                const n = m.vecAs(1, .of(arr.log2() - 1, high)) orelse return null;
                const bits = @as(u32, 4) << @intCast(arr.log2());
                const shift = if (insn.kind == .shift_long) try m.imm(2, 0, bits - 1, "the shift left") orelse return null else 0;
                return base | high << 30 | (bits + shift) << 16 | n << 5 | m.num(0);
            },
            .shift_fp => {
                if (ops.len != 3) return null;
                const log2, const form, const arr = m.fpOperand(0, insn) orelse return null;
                const n = m.fpAs(1, log2, arr) orelse return null;
                const word = try m.fpBase(log2, base, .shift) orelse return null;
                const bits = @as(u32, 8) << @intCast(log2);
                const fbits = try m.imm(2, 1, bits, "the number of fraction bits") orelse return null;
                return word | form | (2 * bits - fbits) << 16 | n << 5 | m.num(0);
            },
            .across, .across_long => {
                if (ops.len != 2) return null;
                const arr = m.key(1) orelse return null;
                // Of at least four elements.
                if (arr.log2() > 2 or arr == .@"2s") return null;
                const d = m.scalarAsAny(0, arr.log2() + @intFromBool(insn.kind == .across_long)) orelse return null;
                return base | arr.q() << 30 | arr.log2() << 22 | m.num(1) << 5 | d;
            },
            .across_fp => {
                if (ops.len != 2) return null;
                const arr = m.key(1) orelse return null;
                const d = m.scalarAsAny(0, arr.log2()) orelse return null;
                switch (arr) {
                    .@"4s" => return base | 1 << 30 | m.num(1) << 5 | d,
                    .@"4h", .@"8h" => {
                        if (!m.a.cpu.has(.aarch64, .fullfp16)) return m.a.needs(.fullfp16);
                        return (base & ~@as(u32, 1 << 29)) | arr.q() << 30 | m.num(1) << 5 | d;
                    },
                    else => return null,
                }
            },
            .elem, .elem_fp, .elem_long => {
                if (ops.len != 3 or ops[2] != .velem) return null;
                const el = ops[2].velem;
                const fp = insn.kind == .elem_fp;
                const long: u32 = @intFromBool(insn.kind == .elem_long);
                // The elements' size, the form's bits and the first source.
                const log2: u32, const form: u32, const n: u32 = if (m.key(0)) |arr| operands: {
                    if (arr == .@"1d" or arr == .@"1q" or arr.log2() < long) return null;
                    const log2 = arr.log2() - long;
                    if (long == 1 and arr.q() != 1) return null;
                    const q = if (long == 1) high else arr.q();
                    break :operands .{ log2, q << 30, m.vecAs(1, .of(log2, q)) orelse return null };
                } else operands: {
                    const d = m.scalarOf(0) orelse return null;
                    if (insn.scalar == 0 or m.high or d > 3 or d < long) return null;
                    break :operands .{ d - long, scalar_form, m.scalarAs(1, d - long) orelse return null };
                };
                if (el.log2 != log2) return null;
                if (fp) {
                    if (log2 == 0) return null;
                } else if (insn.sizes >> @intCast(log2) & 1 == 0) return null;
                const lanes = @as(u32, 16) >> @intCast(log2);
                if (el.index >= lanes) return m.a.fail("inline assembly: the element index is 0 to {d}: '{s}'", .{ lanes - 1, m.a.line });
                const r: u32 = @backingInt(el.reg);
                const index: u32 = el.index;
                // The index is the bits H, L and M, as many as it needs,
                // and a halfword's register has four bits left.
                const field: u32 = switch (log2) {
                    1 => field: {
                        if (r > 15) return m.a.fail("inline assembly: an element of halfwords is of v0 to v15 here: '{s}'", .{m.a.line});
                        break :field (index >> 2) << 11 | (index & 3) << 20 | r << 16;
                    },
                    2 => (index >> 1) << 11 | (index & 1) << 21 | r << 16,
                    else => index << 11 | r << 16,
                };
                const word = if (fp) try m.fpBase(log2, base, .element) orelse return null else base | log2 << 22;
                return word | form | field | n << 5 | m.num(0);
            },
            .pair => {
                if (ops.len != 2) return null;
                const d = m.scalarAsAny(0, 3) orelse return null;
                if (m.key(1) != .@"2d") return null;
                return base | m.num(1) << 5 | d;
            },
            .fpair => {
                if (ops.len != 2) return null;
                const arr = m.key(1) orelse return null;
                if (arr != .@"2s" and arr != .@"2d") return null;
                const d = m.scalarAsAny(0, arr.log2()) orelse return null;
                return base | @as(u32, @intFromBool(arr == .@"2d")) << 22 | m.num(1) << 5 | d;
            },
            .v2, .v3, .v4, .xar => {
                const count: usize = switch (insn.kind) {
                    .v2 => 2,
                    .v3 => 3,
                    else => 4,
                };
                if (ops.len != count or (m.suffix != null and m.suffix != insn.arr)) return null;
                const d = m.vecAs(0, insn.arr) orelse return null;
                const n = m.vecAs(1, insn.arr) orelse return null;
                if (count == 2) return base | n << 5 | d;
                const r = m.vecAs(2, insn.arr) orelse return null;
                if (count == 3) return base | r << 16 | n << 5 | d;
                const last = if (insn.kind == .xar) try m.imm(3, 0, 63, "the rotation") orelse return null else m.vecAs(3, insn.arr) orelse return null;
                return base | r << 16 | last << 10 | n << 5 | d;
            },
            .qqv, .qsv => {
                if (ops.len != 3 or (m.suffix != null and m.suffix != insn.arr)) return null;
                const d = m.wholeAs(0) orelse return null;
                const n = if (insn.kind == .qqv) m.wholeAs(1) orelse return null else m.scalarAsAny(1, 2) orelse return null;
                const r = m.vecAs(2, insn.arr) orelse return null;
                return base | r << 16 | n << 5 | d;
            },
            .ss => {
                if (ops.len != 2) return null;
                const d = m.scalarAs(0, 2) orelse return null;
                const n = m.scalarAs(1, 2) orelse return null;
                return base | n << 5 | d;
            },
        }
    }

    /// `scalarAs`, also with an arrangement on the mnemonic, which is
    /// then another operand's (`addv.8b b0, v1`).
    fn scalarAsAny(m: *const Match, k: usize, log2: u32) ?u32 {
        if (k >= m.ops.len or m.ops[k] != .vreg) return null;
        const v = m.ops[k].vreg;
        if (v.arr != null or v.kind == .v) return null;
        const size: u32 = switch (v.kind) {
            .v => unreachable,
            .b => 0,
            .h => 1,
            .s => 2,
            .d => 3,
            .q => 4,
        };
        return if (size == log2) @backingInt(v.reg) else null;
    }

    fn special(m: *const Match, mnemonic: []const u8) Error!?u32 {
        const eql = std.mem.eql;
        if (std.mem.startsWith(u8, mnemonic, "ld") or std.mem.startsWith(u8, mnemonic, "st")) return m.structure(mnemonic);
        if (eql(u8, mnemonic, "tbl") or eql(u8, mnemonic, "tbx")) {
            if (m.ops.len != 3 or m.ops[1] != .vlist) return null;
            const arr = m.key(0) orelse return null;
            const list = m.ops[1].vlist;
            if (arr.log2() != 0 or list.elem != null) return null;
            if (list.arr) |x| {
                if (x != .@"16b" or m.suffix != null) return null;
            } else if (m.suffix == null) return null;
            const r = m.vecAs(2, arr) orelse return null;
            const extend: u32 = @intFromBool(mnemonic[2] == 'x');
            return 0x0E000000 | arr.q() << 30 | r << 16 | @as(u32, list.len - 1) << 13 | extend << 12 | @as(u32, @backingInt(list.first)) << 5 | m.num(0);
        }
        if (eql(u8, mnemonic, "ext")) {
            if (m.ops.len != 4) return null;
            const arr = m.key(0) orelse return null;
            if (arr.log2() != 0) return null;
            const n = m.vecAs(1, arr) orelse return null;
            const r = m.vecAs(2, arr) orelse return null;
            const first = try m.imm(3, 0, (@as(u32, 8) << @intCast(arr.q())) - 1, "the first byte") orelse return null;
            return 0x2E000000 | arr.q() << 30 | r << 16 | first << 11 | n << 5 | m.num(0);
        }
        if (eql(u8, mnemonic, "movi") or eql(u8, mnemonic, "mvni") or eql(u8, mnemonic, "orr") or eql(u8, mnemonic, "bic") or eql(u8, mnemonic, "fmov")) return m.immediate(mnemonic);
        return m.copy(mnemonic);
    }

    /// The imm5 field that names element `index` of `1 << log2` bytes.
    fn imm5(m: *const Match, log2: u32, index: u32) Error!u32 {
        const lanes = @as(u32, 16) >> @intCast(log2);
        if (index >= lanes) return m.a.fail("inline assembly: the element index is 0 to {d}: '{s}'", .{ lanes - 1, m.a.line });
        return (index << @intCast(log2 + 1) | @as(u32, 1) << @intCast(log2)) << 16;
    }

    /// `mov`, `dup`, `ins` and `smov`: copies between whole vectors,
    /// their elements, scalars and general registers.
    fn copy(m: *const Match, mnemonic: []const u8) Error!?u32 {
        const eql = std.mem.eql;
        const ops = m.ops;
        if (ops.len != 2) return null;
        const is_mov = eql(u8, mnemonic, "mov");
        const is_dup = eql(u8, mnemonic, "dup");
        const is_ins = eql(u8, mnemonic, "ins");
        switch (ops[0]) {
            .vreg => {
                if (m.key(0)) |arr| {
                    const d = m.num(0);
                    if (is_mov) {
                        // `orr` of a vector with itself, whatever the
                        // elements.
                        const n = m.vecAs(1, arr) orelse return null;
                        if (arr == .@"1q") return null;
                        return 0x0EA01C00 | arr.q() << 30 | n << 16 | n << 5 | d;
                    }
                    if (!is_dup or arr == .@"1d" or arr == .@"1q") return null;
                    switch (ops[1]) {
                        .reg => |r| {
                            // Every element from a general register: an
                            // x register for doublewords, else a w one.
                            if ((r.width == .x) != (arr.log2() == 3)) return null;
                            return 0x0E000C00 | arr.q() << 30 | try m.imm5(arr.log2(), 0) | try m.a.zrReg(ops, 1, r.width) << 5 | d;
                        },
                        .velem => |el| {
                            if (el.log2 != arr.log2() or m.suffix != null) return null;
                            return 0x0E000400 | arr.q() << 30 | try m.imm5(el.log2, el.index) | @as(u32, @backingInt(el.reg)) << 5 | d;
                        },
                        else => return null,
                    }
                }
                // A scalar from an element of its size.
                const log2 = m.scalarOf(0) orelse return null;
                if ((!is_mov and !is_dup) or log2 > 3 or ops[1] != .velem or ops[1].velem.log2 != log2) return null;
                const el = ops[1].velem;
                return 0x5E000400 | try m.imm5(log2, el.index) | @as(u32, @backingInt(el.reg)) << 5 | m.num(0);
            },
            .velem => |el| {
                if ((!is_mov and !is_ins) or m.suffix != null) return null;
                const d: u32 = @backingInt(el.reg);
                switch (ops[1]) {
                    .reg => |r| {
                        if ((r.width == .x) != (el.log2 == 3)) return null;
                        return 0x4E001C00 | try m.imm5(el.log2, el.index) | try m.a.zrReg(ops, 1, r.width) << 5 | d;
                    },
                    .velem => |from| {
                        if (from.log2 != el.log2) return null;
                        const to = try m.imm5(el.log2, el.index);
                        _ = try m.imm5(from.log2, from.index);
                        return 0x6E000400 | to | (@as(u32, from.index) << el.log2) << 11 | @as(u32, @backingInt(from.reg)) << 5 | d;
                    },
                    else => return null,
                }
            },
            .reg => |r| {
                // An element to a general register, sign-extended.
                if (!eql(u8, mnemonic, "smov") or ops[1] != .velem or m.suffix != null) return null;
                const el = ops[1].velem;
                if (el.log2 > @as(u32, if (r.width == .x) 2 else 1)) return null;
                return 0x0E002C00 | @as(u32, @intFromBool(r.width == .x)) << 30 | try m.imm5(el.log2, el.index) | @as(u32, @backingInt(el.reg)) << 5 | try m.a.zrReg(ops, 0, r.width);
            },
            else => return null,
        }
    }

    /// `movi`, `mvni`, `orr`, `bic` and `fmov` of an immediate in every
    /// element: eight bits, shifted left where the elements have room,
    /// or for `movi` on doublewords eight bytes each of zeros or ones.
    fn immediate(m: *const Match, mnemonic: []const u8) Error!?u32 {
        const a = m.a;
        const ops = m.ops;
        if (ops.len < 2 or ops.len > 3 or ops[0] != .vreg) return null;
        const d = m.num(0);
        const is_movi = std.mem.eql(u8, mnemonic, "movi");
        if (mnemonic[0] == 'f') {
            if (ops.len != 2) return null;
            const arr = m.key(0) orelse return null;
            const bits: u32 = switch (ops[1]) {
                .fimm => |v| Asm.fpImm8(v) orelse return a.fail("inline assembly: 'fmov' takes plus or minus 16 to 31 sixteenths times a power of two from 1/8 to 16: '{s}'", .{a.line}),
                .imm => |v| bits: {
                    const tok = a.lastImm();
                    if (std.mem.startsWith(u8, tok, "0x")) {
                        if (v < 0 or v > 255) return a.fail("inline assembly: an encoded floating-point immediate is 0 to 255: '{s}'", .{a.line});
                        break :bits @intCast(v);
                    }
                    const digits = tok[@intFromBool(tok[0] == '-')..];
                    if (tok[0] != '%' and std.mem.findNone(u8, digits, "0123456789") != null) return null;
                    break :bits Asm.fpImm8(@floatFromInt(v)) orelse return a.fail("inline assembly: 'fmov' takes plus or minus 16 to 31 sixteenths times a power of two from 1/8 to 16: '{s}'", .{a.line});
                },
                else => return null,
            };
            const form: u32 = switch (arr) {
                .@"2s", .@"4s" => 0x0F00F400,
                .@"2d" => 0x2F00F400,
                .@"4h", .@"8h" => form: {
                    if (!a.cpu.has(.aarch64, .fullfp16)) return a.needs(.fullfp16);
                    break :form 0x0F00FC00;
                },
                else => return null,
            };
            return form | arr.q() << 30 | (bits >> 5) << 16 | (bits & 31) << 5 | d;
        }
        if (ops[1] != .imm) return null;
        const value = ops[1].imm;
        // A shift that moves zeros in (`lsl`) or ones (`msl`).
        const Shift = struct { ones: bool, amount: u32 };
        const shift: ?Shift = if (ops.len == 2) null else switch (ops[2]) {
            .modifier => |x| if (x.op == .lsl and x.amount != null) Shift{ .ones = false, .amount = x.amount.? } else return null,
            .msl => |amount| .{ .ones = true, .amount = amount },
            else => return null,
        };
        const inverted: u32 = @intFromBool(mnemonic[0] == 'm' and mnemonic[1] == 'v' or mnemonic[0] == 'b');
        const sets = mnemonic[0] == 'o' or mnemonic[0] == 'b';
        const wide = is_movi and shift == null and (m.scalarOf(0) == 3 or m.key(0) == .@"2d");
        if (wide) {
            var mask: u32 = 0;
            for (0..8) |k| {
                const byte: u8 = @truncate(@as(u64, @bitCast(value)) >> @intCast(8 * k));
                if (byte != 0 and byte != 0xff) return a.fail("inline assembly: each byte of this immediate is 0 or 0xff: '{s}'", .{a.line});
                mask |= @as(u32, byte & 1) << @intCast(k);
            }
            const q: u32 = @intFromBool(m.scalarOf(0) == null);
            return 0x2F00E400 | q << 30 | (mask >> 5) << 16 | (mask & 31) << 5 | d;
        }
        const arr = m.key(0) orelse return null;
        const amount = if (shift) |x| x.amount else 0;
        const ones = shift != null and shift.?.ones;
        const cmode: u32 = switch (arr) {
            .@"8b", .@"16b" => cmode: {
                if (!is_movi) return null;
                if (shift != null) return a.fail("inline assembly: an immediate in bytes takes no shift: '{s}'", .{a.line});
                break :cmode 0b1110;
            },
            .@"4h", .@"8h" => cmode: {
                if (ones) return null;
                if (amount != 0 and amount != 8) return a.fail("inline assembly: an immediate in halfwords shifts by 'lsl #0' or 'lsl #8': '{s}'", .{a.line});
                break :cmode 0b1000 | (amount / 8) << 1 | @intFromBool(sets);
            },
            .@"2s", .@"4s" => cmode: {
                if (ones) {
                    if (sets) return null;
                    if (amount != 8 and amount != 16) return a.fail("inline assembly: 'msl' shifts by 8 or 16: '{s}'", .{a.line});
                    break :cmode @as(u32, 0b1100) | @intFromBool(amount == 16);
                }
                if (amount % 8 != 0 or amount > 24) return a.fail("inline assembly: an immediate in words shifts by 'lsl' 0, 8, 16 or 24: '{s}'", .{a.line});
                break :cmode (amount / 8) << 1 | @intFromBool(sets);
            },
            else => return null,
        };
        if (value < 0 or value > 255) return a.fail("inline assembly: the immediate of '{s}' is 0 to 255, with a shift where the elements have room: '{s}'", .{ mnemonic, a.line });
        const bits: u32 = @intCast(value);
        return 0x0F000400 | arr.q() << 30 | inverted << 29 | (bits >> 5) << 16 | cmode << 12 | (bits & 31) << 5 | d;
    }

    /// `ld1` to `ld4` and `st1` to `st4` of whole registers or of one
    /// element of each, and `ld1r` to `ld4r`, which load one element into
    /// every one: at the base register, optionally adding the bytes moved
    /// or an x register to it afterwards.
    fn structure(m: *const Match, mnemonic: []const u8) Error!?u32 {
        const a = m.a;
        const ops = m.ops;
        if (mnemonic.len < 3 or mnemonic.len > 4 or mnemonic[2] < '1' or mnemonic[2] > '4') return null;
        const load = mnemonic[0] == 'l';
        const replicate = mnemonic.len == 4;
        if (replicate and (!load or mnemonic[3] != 'r')) return null;
        const count: u32 = mnemonic[2] - '0';
        if (ops.len < 2 or ops.len > 3 or ops[0] != .vlist or ops[1] != .mem) return null;
        const list = ops[0].vlist;
        const mem = ops[1].mem.mem;
        // The post-index field: 31 for the bytes moved, else the register.
        var post: ?u32 = null;
        var step: ?i32 = null;
        if (ops.len == 3) {
            if (mem.offset != .imm or mem.offset.imm != 0) return null;
            // xzr is register 31, the immediate form, as LLVM takes it.
            post = try a.zrReg(ops, 2, .x);
        } else switch (mem.offset) {
            .imm => |v| if (v != 0 or ops[1].mem.offset_written) return a.fail("inline assembly: '{s}' takes no offset: '{s}'", .{ mnemonic, a.line }),
            .post => |v| {
                step = v;
                post = 31;
            },
            else => return null,
        }
        const registers = @as(u32, @backingInt(list.first)) | mem.base.spEnc() << 5 | @as(u32, @intFromBool(load)) << 22 | if (post) |r| 1 << 23 | r << 16 else 0;
        const even: u32 = @intFromBool(count == 2 or count == 4);
        const upper: u32 = @intFromBool(count >= 3);
        const word: u32, const bytes: u32 = if (list.elem) |el| word: {
            // One element of each register.
            if (replicate or list.len != count or m.suffix != null) return null;
            const lanes = @as(u32, 16) >> el.log2;
            if (el.index >= lanes) return a.fail("inline assembly: the element index is 0 to {d}: '{s}'", .{ lanes - 1, a.line });
            const index: u32 = el.index;
            // The index is the bits Q, S and size, as many as it needs.
            const q: u32, const s: u32, const size: u32 = switch (el.log2) {
                0 => .{ index >> 3, index >> 2 & 1, index & 3 },
                1 => .{ index >> 2, index >> 1 & 1, (index & 1) << 1 },
                2 => .{ index >> 1, index & 1, 0 },
                3 => .{ index, 0, 1 },
            };
            const scale: u32 = @min(el.log2, 2);
            break :word .{ 0x0D000000 | q << 30 | even << 21 | (scale << 1 | upper) << 13 | s << 12 | size << 10, count << el.log2 };
        } else word: {
            if ((list.arr != null) == (m.suffix != null)) return null;
            const arr = list.arr orelse m.suffix.?;
            if (arr == .@"1q") return null;
            const size = arr.log2();
            if (replicate) {
                if (list.len != count) return null;
                break :word .{ 0x0D00C000 | arr.q() << 30 | even << 21 | upper << 13 | size << 10, count << @intCast(size) };
            }
            // `ld1` takes one to four registers, and alone a doubleword
            // in each.
            if (count != 1 and (list.len != count or arr == .@"1d")) return null;
            const opcode: u32 = switch (count) {
                1 => switch (list.len) {
                    1 => 0b0111,
                    2 => 0b1010,
                    3 => 0b0110,
                    else => 0b0010,
                },
                2 => 0b1000,
                3 => 0b0100,
                else => 0b0000,
            };
            break :word .{ 0x0C000000 | arr.q() << 30 | opcode << 12 | size << 10, @as(u32, list.len) * (@as(u32, 8) << @intCast(arr.q())) };
        };
        if (step) |v| if (v != bytes) return a.fail("inline assembly: the post-index immediate is the bytes moved, #{d}: '{s}'", .{ bytes, a.line });
        return word | registers;
    }
};
