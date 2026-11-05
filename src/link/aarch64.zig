//! aarch64 instruction fields the linkers patch, shared by the Mach-O and
//! ELF linkers.

/// Page(target) - Page(p), in 4 KiB pages, as adrp computes it.
pub fn pageDelta(target: u64, p: u64) i64 {
    return @as(i64, @bitCast(target >> 12)) - @as(i64, @bitCast(p >> 12));
}

/// Sets adrp's immhi:immlo to `pages`.
pub fn patchAdrp(insn: u32, pages: i64) u32 {
    const imm: u32 = @truncate(@as(u64, @bitCast(pages)) & 0x1fffff);
    return (insn & 0x9f00001f) | ((imm & 3) << 29) | ((imm >> 2) << 5);
}

/// log2 of the unit of an instruction's unsigned 12-bit offset: 0 for
/// `add (immediate)`, the access size for loads and stores, or null for an
/// instruction a pageoff12 relocation cannot patch.
pub fn pageOffScale(insn: u32) ?u5 {
    // add wd|xd, wn|sp, #imm (no shift)
    if (insn & 0x7fc00000 == 0x11000000) return 0;
    // Loads and stores, unsigned offset: size 111 V 01 opc imm12 Rn Rt.
    if (insn & 0x3b000000 == 0x39000000) {
        const size: u5 = @intCast(insn >> 30);
        // V=1 with opc<1>=1 and size 00 is a q register.
        if (insn & 0x04800000 == 0x04800000 and size == 0) return 4;
        return size;
    }
    return null;
}

/// Sets the imm12 field (bits 10-21) of an add or a load or store.
pub fn patchImm12(insn: u32, imm: u32) u32 {
    return (insn & ~@as(u32, 0xfff << 10)) | (imm << 10);
}
