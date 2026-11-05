//! aarch64 machine code encoder for the Debug CodeGen. Appends one
//! instruction per call to `code`; references to other symbols become
//! `Atom.Reloc`s and branches to local labels are patched by `finish`. It
//! always picks one encoding per form and does no instruction selection
//! beyond what an operand forces (for example the scaled or unscaled
//! immediate form of a load): invalid operand combinations are caller bugs
//! and trip assertions.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Atom = @import("../../link/Atom.zig");
const SymbolKey = Atom.SymbolKey;

const Encoder = @This();

gpa: Allocator,
code: std.ArrayList(u8) = .empty,
/// The atom's `targets` (`refs.targets.keys()`) and `relocs` (`refs.relocs.items`).
refs: Atom.RelocList = .{},
/// Offset each label is bound to, or `unbound`.
labels: std.ArrayList(u32) = .empty,
/// Every reference to a label, in code order; `finish` patches them.
fixups: std.ArrayList(Fixup) = .empty,
/// After `finish`: the offsets, before relaxation, of the conditional
/// branches it relaxed, in increasing order (see `finalOffset`).
relaxed: std.ArrayList(u32) = .empty,
/// The atom's `Debug.lines`, written by `finish` from `line_events` at the
/// rows' final offsets.
lines: Atom.LineProgram = .{},
line_events: std.ArrayList(LineEvent) = .empty,

const LineEvent = struct { offset: u32, kind: enum { row, switch_to }, a: u32, b: u32 };

const unbound = std.math.maxInt(u32);

/// General-purpose registers. Encoding 31 means `sp` or `xzr`/`wzr`
/// depending on the operand; the two are separate values here so that an
/// operand that cannot take one of them trips an assertion.
pub const Reg = enum(u6) {
    x0,
    x1,
    x2,
    x3,
    x4,
    x5,
    x6,
    x7,
    x8,
    x9,
    x10,
    x11,
    x12,
    x13,
    x14,
    x15,
    x16,
    x17,
    x18,
    x19,
    x20,
    x21,
    x22,
    x23,
    x24,
    x25,
    x26,
    x27,
    x28,
    x29,
    x30,
    sp,
    zr,

    pub const fp: Reg = .x29;
    pub const lr: Reg = .x30;

    /// The register as an operand that may be `sp` but not `zr`.
    fn spEnc(r: Reg) u32 {
        assert(r != .zr);
        return @as(u5, @truncate(@backingInt(r)));
    }
    /// The register as an operand that may be `zr` but not `sp`.
    fn zrEnc(r: Reg) u32 {
        assert(r != .sp);
        return if (r == .zr) 31 else @backingInt(r);
    }
};

/// SIMD and floating-point registers, used as scalars.
pub const VReg = enum(u5) {
    v0,
    v1,
    v2,
    v3,
    v4,
    v5,
    v6,
    v7,
    v8,
    v9,
    v10,
    v11,
    v12,
    v13,
    v14,
    v15,
    v16,
    v17,
    v18,
    v19,
    v20,
    v21,
    v22,
    v23,
    v24,
    v25,
    v26,
    v27,
    v28,
    v29,
    v30,
    v31,

    fn enc(v: VReg) u32 {
        return @backingInt(v);
    }
};

/// Register width of a data-processing instruction: w (32-bit) or x
/// (64-bit) registers.
pub const Width = enum(u1) {
    w,
    x,

    fn sf(w: Width) u32 {
        return @as(u32, @backingInt(w)) << 31;
    }
    pub fn bits(w: Width) u7 {
        return if (w == .x) 64 else 32;
    }
};

/// Access size of a load or store, numbered as the instructions' size field.
pub const Size = enum(u2) {
    byte,
    half,
    word,
    dword,

    pub fn bytes(s: Size) u8 {
        return @as(u8, 1) << @backingInt(s);
    }
};

/// Scalar floating-point types, numbered as the instructions' ftype field.
pub const Float = enum(u2) {
    f32 = 0b00,
    f64 = 0b01,
    f16 = 0b11,

    fn ftype(f: Float) u32 {
        return @as(u32, @backingInt(f)) << 22;
    }
    /// Access size of a load or store of the type.
    fn size(f: Float) Size {
        return switch (f) {
            .f16 => .half,
            .f32 => .word,
            .f64 => .dword,
        };
    }
};

/// Condition codes, numbered as in the instructions.
pub const Cond = enum(u4) {
    eq,
    ne,
    /// Unsigned >=, carry set.
    hs,
    /// Unsigned <, carry clear.
    lo,
    mi,
    pl,
    vs,
    vc,
    hi,
    ls,
    ge,
    lt,
    gt,
    le,
    al,
    nv,

    pub fn negate(c: Cond) Cond {
        assert(c != .al and c != .nv);
        return @fromBackingInt(@backingInt(c) ^ 1);
    }
};

/// A memory operand of a load or store.
pub const Mem = struct {
    /// An x register or sp.
    base: Reg,
    offset: Offset = .{ .imm = 0 },

    pub const Offset = union(enum) {
        /// `[base, #imm]`. Single loads and stores use the scaled unsigned
        /// 12-bit form when `imm` is a multiple of the access size in its
        /// range, else the unscaled signed 9-bit form (ldur/stur). Pairs
        /// take a signed 7-bit multiple of the access size.
        imm: i32,
        /// `[base, #imm]!`: pre-index, writing the address back to `base`.
        pre: i32,
        /// `[base], #imm`: post-index.
        post: i32,
        /// `[base, index{, extend #amount}]`. Not for pairs.
        index: Index,
        /// `[base, #:lo12:sym+addend]` (pageoff12 relocation), after
        /// `adrp base, sym+addend`. Not for pairs.
        page_off: SymRef,
        /// `[base, #:got_lo12:sym]` (GOT pageoff12 relocation) after
        /// `adrpGot base, sym`: loads the address of `sym` from its GOT
        /// slot. Only for 64-bit `ldr`.
        got_page_off: SymbolKey,
    };

    pub const Index = struct {
        /// An x register for `lsl` and `sxtx`, a w register for `uxtw` and
        /// `sxtw`.
        reg: Reg,
        extend: IndexExtend = .lsl,
        /// Shift the index left by log2 of the access size.
        scaled: bool = false,
    };
    pub const IndexExtend = enum(u3) { uxtw = 0b010, lsl = 0b011, sxtw = 0b110, sxtx = 0b111 };

    /// `[base, #imm]`
    pub fn at(base: Reg, imm: i32) Mem {
        return .{ .base = base, .offset = .{ .imm = imm } };
    }
};

/// A symbol and addend, the target of an address relocation.
pub const SymRef = struct { sym: SymbolKey, addend: i32 = 0 };

pub const Shift = enum(u2) { lsl, lsr, asr, ror };

/// Register extension of the extended-register add/sub forms.
pub const Extend = enum(u3) { uxtb, uxth, uxtw, uxtx, sxtb, sxth, sxtw, sxtx };

/// Second source operand of add, sub, and the comparisons built on them.
pub const AddOperand = union(enum) {
    /// An unsigned 12-bit immediate, optionally shifted left by 12: any
    /// value below 4096, or a multiple of 4096 below 2^24.
    imm: u32,
    /// A register, shifted (`lsl`, `lsr`, `asr`) by `amount`. With no shift
    /// and sp as the destination or first source, the extended-register
    /// form is used, as assemblers do.
    reg: ShiftedReg,
    /// A w or x register, extended and shifted left by 0 to 4.
    extended: struct { reg: Reg, extend: Extend, amount: u3 = 0 },
    /// `#:lo12:sym+addend` (pageoff12 relocation), completing the address
    /// that `adrp` started. Only for `add`.
    page_off: SymRef,

    pub fn r(reg: Reg) AddOperand {
        return .{ .reg = .{ .reg = reg } };
    }
};

pub const ShiftedReg = struct { reg: Reg, shift: Shift = .lsl, amount: u6 = 0 };

/// Second source operand of the logical instructions.
pub const LogicOperand = union(enum) {
    /// Must be encodable as a bitmask immediate (`bitmaskImm`). Not for the
    /// inverting forms (bic, orn, eon, bics).
    imm: u64,
    reg: ShiftedReg,

    pub fn r(reg: Reg) LogicOperand {
        return .{ .reg = .{ .reg = reg } };
    }
};

pub const Label = enum(u32) { _ };
pub const Target = union(enum) { label: Label, sym: SymbolKey };

/// A reference to `label` from offset `at`. For `word32`, `anchor` is the
/// label the word is relative to.
const Fixup = struct { at: u32, label: Label, field: BranchField, anchor: Label = undefined };

/// The PC-relative field a fixup patches.
const BranchField = enum {
    /// b, bl: ±128 MiB, in instructions.
    imm26,
    /// b.cond, cbz, cbnz: ±1 MiB, in instructions. Relaxable.
    imm19,
    /// tbz, tbnz: ±32 KiB, in instructions. Relaxable.
    imm14,
    /// adr: ±1 MiB, in bytes (immhi:immlo).
    adr21,
    /// A 32-bit data word: label - anchor, in bytes.
    word32,

    fn bits(f: BranchField) u5 {
        return switch (f) {
            .imm26 => 26,
            .imm19 => 19,
            .imm14 => 14,
            .adr21 => 21,
            .word32 => unreachable,
        };
    }
    fn lsb(f: BranchField) u5 {
        return switch (f) {
            .imm26 => 0,
            .imm19, .imm14 => 5,
            .adr21, .word32 => unreachable,
        };
    }
    fn relaxable(f: BranchField) bool {
        return f == .imm19 or f == .imm14;
    }
};

pub fn init(gpa: Allocator) Encoder {
    return .{ .gpa = gpa };
}

pub fn deinit(e: *Encoder) void {
    e.code.deinit(e.gpa);
    e.refs.deinit(e.gpa);
    e.labels.deinit(e.gpa);
    e.fixups.deinit(e.gpa);
    e.relaxed.deinit(e.gpa);
    e.lines.deinit(e.gpa);
    e.line_events.deinit(e.gpa);
}

/// A line row at the current offset (see `Atom.LineProgram.addRow`).
pub fn line(e: *Encoder, line_: u32, column: u32) !void {
    try e.line_events.append(e.gpa, .{ .offset = @intCast(e.code.items.len), .kind = .row, .a = line_, .b = column });
}

/// Rows from here come from local file `file`, relative to base `base`
/// (see `Atom.LineProgram.switchTo`).
pub fn switchLines(e: *Encoder, file: u32, base: u32) !void {
    try e.line_events.append(e.gpa, .{ .offset = @intCast(e.code.items.len), .kind = .switch_to, .a = file, .b = base });
}

/// Patches every reference to a label; every label must be bound. A
/// conditional branch that cannot reach its label (b.cond, cbz, and cbnz
/// reach ±1 MiB, tbz and tbnz ±32 KiB) is relaxed into the inverted branch
/// over a `b`, which inserts 4 bytes after it, until every branch reaches
/// (each round only relaxes, so this ends). Labels and relocations move
/// with the code; offsets the caller recorded before `finish`, such as
/// line rows, inline ranges, or the code size, map with `finalOffset`.
/// Fails only if an `adr` or `b` cannot reach its label.
pub fn finish(e: *Encoder) (Allocator.Error || error{BranchOutOfRange})!void {
    const gpa = e.gpa;
    e.relaxed.clearRetainingCapacity();
    const relax = try gpa.alloc(bool, e.fixups.items.len);
    defer gpa.free(relax);
    @memset(relax, false);
    while (true) {
        var changed = false;
        for (e.fixups.items, relax) |f, *r| {
            if (r.* or !f.field.relaxable()) continue;
            const dest = e.labels.items[@backingInt(f.label)];
            assert(dest != unbound);
            const delta = @as(i64, e.finalOffset(dest)) - e.finalOffset(f.at);
            if (fits(delta >> 2, f.field.bits())) continue;
            r.* = true;
            changed = true;
        }
        if (!changed) break;
        e.relaxed.clearRetainingCapacity();
        for (e.fixups.items, relax) |f, r| if (r) try e.relaxed.append(gpa, f.at);
    }
    if (e.relaxed.items.len > 0) {
        var code: std.ArrayList(u8) = try .initCapacity(gpa, e.code.items.len + 4 * e.relaxed.items.len);
        var prev: u32 = 0;
        for (e.relaxed.items) |at| {
            code.appendSliceAssumeCapacity(e.code.items[prev..at]);
            const insn = std.mem.readInt(u32, e.code.items[at..][0..4], .little);
            // b.cond inverts its condition; cbz/cbnz and tbz/tbnz flip bit
            // 24. The inverted branch skips the `b` that follows it.
            const field: BranchField = if (insn & 0x7e000000 == 0x36000000) .imm14 else .imm19;
            const inverted = if (insn & 0xff000010 == 0x54000000) inv: {
                assert(insn & 0xe < 0xe);
                break :inv insn ^ 1;
            } else insn ^ (1 << 24);
            const cleared = inverted & ~(((@as(u32, 1) << field.bits()) - 1) << field.lsb());
            std.mem.writeInt(u32, code.addManyAsArrayAssumeCapacity(4), cleared | (@as(u32, 2) << field.lsb()), .little);
            std.mem.writeInt(u32, code.addManyAsArrayAssumeCapacity(4), 0x14000000, .little);
            prev = at + 4;
        }
        code.appendSliceAssumeCapacity(e.code.items[prev..]);
        e.code.deinit(gpa);
        e.code = code;
        for (e.labels.items) |*l| if (l.* != unbound) {
            l.* = e.finalOffset(l.*);
        };
        for (e.refs.relocs.items) |*r| r.offset = e.finalOffset(r.offset);
    }
    for (e.fixups.items, relax) |f, r| {
        const at = e.finalOffset(f.at);
        const dest = e.labels.items[@backingInt(f.label)];
        if (r) {
            try e.patchBranch(at + 4, dest, .imm26);
        } else switch (f.field) {
            .imm26, .imm19, .imm14 => try e.patchBranch(at, dest, f.field),
            .adr21 => {
                const delta = @as(i64, dest) - at;
                if (!fits(delta, 21)) return error.BranchOutOfRange;
                const d: u32 = @truncate(@as(u64, @bitCast(delta)));
                const insn = e.code.items[at..][0..4];
                std.mem.writeInt(u32, insn, std.mem.readInt(u32, insn, .little) | ((d & 3) << 29) | (((d >> 2) & 0x7ffff) << 5), .little);
            },
            .word32 => {
                const delta: i32 = @intCast(@as(i64, dest) - e.labels.items[@backingInt(f.anchor)]);
                std.mem.writeInt(i32, e.code.items[at..][0..4], delta, .little);
            },
        }
    }
    e.fixups.clearRetainingCapacity();
    for (e.line_events.items) |ev| switch (ev.kind) {
        .row => try e.lines.addRow(e.gpa, e.finalOffset(ev.offset), ev.a, ev.b),
        .switch_to => try e.lines.switchTo(e.gpa, ev.a, ev.b),
    };
    e.line_events.clearRetainingCapacity();
}

/// Where code that was at `offset` before `finish` relaxed branches is
/// after it: later by 4 bytes for each relaxed branch before `offset`.
/// The offset of a relaxed branch itself does not change, and the code's
/// old size maps to its new size.
pub fn finalOffset(e: *const Encoder, offset: u32) u32 {
    const before = std.sort.lowerBound(u32, e.relaxed.items, offset, struct {
        fn order(o: u32, at: u32) std.math.Order {
            return std.math.order(o, at);
        }
    }.order);
    return offset + 4 * @as(u32, @intCast(before));
}

fn fits(v: i64, bits: u5) bool {
    return v >= -(@as(i64, 1) << (bits - 1)) and v < (@as(i64, 1) << (bits - 1));
}

pub fn newLabel(e: *Encoder) Allocator.Error!Label {
    try e.labels.append(e.gpa, unbound);
    return @fromBackingInt(@intCast(e.labels.items.len - 1));
}

/// Binds `label` to the current offset.
pub fn bind(e: *Encoder, label: Label) void {
    assert(e.labels.items[@backingInt(label)] == unbound);
    e.labels.items[@backingInt(label)] = @intCast(e.code.items.len);
}

// ---------------------------------------------------------------- loads and stores

/// Loads `size` bytes into `dst`, zero-extended: ldrb, ldrh, and ldr into a
/// w register, ldr into an x register for `.dword`.
pub fn ldr(e: *Encoder, size: Size, dst: Reg, mem: Mem) !void {
    try e.loadStore(size, false, 0b01, dst.zrEnc(), mem);
}

/// Loads `size` bytes into `dst` sign-extended to `width`: ldrsb, ldrsh
/// (to w or x), and ldrsw (to x only).
pub fn ldrs(e: *Encoder, size: Size, width: Width, dst: Reg, mem: Mem) !void {
    assert(size != .dword and !(size == .word and width == .w));
    try e.loadStore(size, false, if (width == .x) 0b10 else 0b11, dst.zrEnc(), mem);
}

/// Stores the low `size` bytes of `src`: strb, strh, str.
pub fn str(e: *Encoder, size: Size, src: Reg, mem: Mem) !void {
    try e.loadStore(size, false, 0b00, src.zrEnc(), mem);
}

/// Loads an h, s, or d register.
pub fn ldrFp(e: *Encoder, ty: Float, dst: VReg, mem: Mem) !void {
    try e.loadStore(ty.size(), true, 0b01, dst.enc(), mem);
}

/// Stores an h, s, or d register.
pub fn strFp(e: *Encoder, ty: Float, src: VReg, mem: Mem) !void {
    try e.loadStore(ty.size(), true, 0b00, src.enc(), mem);
}

/// Loads two w (`.word`) or x (`.dword`) registers from consecutive slots.
pub fn ldp(e: *Encoder, size: Size, r1: Reg, r2: Reg, mem: Mem) !void {
    try e.pair(size, false, true, r1.zrEnc(), r2.zrEnc(), mem);
}

/// Stores two w (`.word`) or x (`.dword`) registers to consecutive slots.
pub fn stp(e: *Encoder, size: Size, r1: Reg, r2: Reg, mem: Mem) !void {
    try e.pair(size, false, false, r1.zrEnc(), r2.zrEnc(), mem);
}

/// Loads two s or d registers from consecutive slots.
pub fn ldpFp(e: *Encoder, ty: Float, r1: VReg, r2: VReg, mem: Mem) !void {
    assert(ty != .f16);
    try e.pair(ty.size(), true, true, r1.enc(), r2.enc(), mem);
}

/// Stores two s or d registers to consecutive slots.
pub fn stpFp(e: *Encoder, ty: Float, r1: VReg, r2: VReg, mem: Mem) !void {
    assert(ty != .f16);
    try e.pair(ty.size(), true, false, r1.enc(), r2.enc(), mem);
}

/// Loads a q register (128 bits).
pub fn ldrQ(e: *Encoder, dst: VReg, mem: Mem) !void {
    try e.loadStore(.byte, true, 0b11, dst.enc(), mem);
}

/// Stores a q register (128 bits).
pub fn strQ(e: *Encoder, src: VReg, mem: Mem) !void {
    try e.loadStore(.byte, true, 0b10, src.enc(), mem);
}

/// Loads two q registers from consecutive 16-byte slots.
pub fn ldpQ(e: *Encoder, r1: VReg, r2: VReg, mem: Mem) !void {
    try e.pairRaw(0b10, 4, true, true, r1.enc(), r2.enc(), mem);
}

/// Stores two q registers to consecutive 16-byte slots.
pub fn stpQ(e: *Encoder, r1: VReg, r2: VReg, mem: Mem) !void {
    try e.pairRaw(0b10, 4, true, false, r1.enc(), r2.enc(), mem);
}

/// Single-register load/store with any addressing form. `opc` selects
/// store (00), load (01), or sign-extending load to x (10) or w (11); for
/// SIMD registers with size 00, opc 10 and 11 store and load a q register.
fn loadStore(e: *Encoder, size: Size, simd: bool, opc: u2, rt: u32, mem: Mem) !void {
    try e.reserve();
    const sz: u5 = @backingInt(size);
    const common = (@as(u32, sz) << 30) | (@as(u32, @intFromBool(simd)) << 26) | (@as(u32, opc) << 22) | (mem.base.spEnc() << 5) | rt;
    switch (mem.offset) {
        .imm => |imm| {
            const scale = @as(i32, 1) << (if (simd and opc >= 0b10) 4 else sz);
            if (imm >= 0 and @rem(imm, scale) == 0 and @divExact(imm, scale) < 4096) {
                e.word(0x39000000 | common | (@as(u32, @intCast(@divExact(imm, scale))) << 10));
            } else {
                e.word(0x38000000 | common | (simm(9, imm) << 12));
            }
        },
        .pre => |imm| e.word(0x38000c00 | common | (simm(9, imm) << 12)),
        .post => |imm| e.word(0x38000400 | common | (simm(9, imm) << 12)),
        .index => |i| {
            assert(i.reg != .sp);
            e.word(0x38200800 | common | (i.reg.zrEnc() << 16) | (@as(u32, @backingInt(i.extend)) << 13) | (@as(u32, @intFromBool(i.scaled)) << 12));
        },
        .page_off => |s| {
            try e.reloc(.aarch64_pageoff12, s.sym, s.addend);
            e.word(0x39000000 | common);
        },
        .got_page_off => |sym| {
            assert(size == .dword and !simd and opc == 0b01);
            try e.reloc(.aarch64_got_load_pageoff12, sym, 0);
            e.word(0x39000000 | common);
        },
    }
}

fn pair(e: *Encoder, size: Size, simd: bool, load: bool, r1: u32, r2: u32, mem: Mem) !void {
    // opc: 32-bit 00, 64-bit 10 for integers; s 00, d 01 for SIMD.
    const opc: u2 = switch (size) {
        .word => 0b00,
        .dword => if (simd) 0b01 else 0b10,
        else => unreachable,
    };
    try e.pairRaw(opc, @backingInt(size), simd, load, r1, r2, mem);
}

/// A pair load or store with the opc field `opc` (q registers: 10 with
/// SIMD) and slots of `1 << log2_size` bytes.
fn pairRaw(e: *Encoder, opc: u2, log2_size: u3, simd: bool, load: bool, r1: u32, r2: u32, mem: Mem) !void {
    try e.reserve();
    const scale = @as(i32, 1) << log2_size;
    const mode: u32, const imm = switch (mem.offset) {
        .post => |i| .{ 0b001, i },
        .imm => |i| .{ 0b010, i },
        .pre => |i| .{ 0b011, i },
        else => unreachable,
    };
    e.word(0x28000000 | (@as(u32, opc) << 30) | (@as(u32, @intFromBool(simd)) << 26) | (mode << 23) | (@as(u32, @intFromBool(load)) << 22) |
        (simm(7, @divExact(imm, scale)) << 15) | (r2 << 10) | (mem.base.spEnc() << 5) | r1);
}

// ---------------------------------------------------------------- atomics

/// Memory ordering of an atomic instruction: acquire sets A (or L), release
/// sets R (or o0). `seq_cst` read-modify-writes use `acq_rel`.
pub const Ordering = enum(u2) {
    relaxed = 0b00,
    release = 0b01,
    acquire = 0b10,
    acq_rel = 0b11,

    fn aBit(o: Ordering) u32 {
        return @backingInt(o) >> 1;
    }
    fn rBit(o: Ordering) u32 {
        return @backingInt(o) & 1;
    }
};

/// `ldar`: a load-acquire of `size` bytes from `[base]`, zero-extended.
pub fn ldar(e: *Encoder, size: Size, dst: Reg, base: Reg) !void {
    try e.reserve();
    e.word(0x08dffc00 | (@as(u32, @backingInt(size)) << 30) | (base.spEnc() << 5) | dst.zrEnc());
}

/// `stlr`: a store-release of the low `size` bytes of `src` to `[base]`.
pub fn stlr(e: *Encoder, size: Size, src: Reg, base: Reg) !void {
    try e.reserve();
    e.word(0x089ffc00 | (@as(u32, @backingInt(size)) << 30) | (base.spEnc() << 5) | src.zrEnc());
}

/// `ldaxr{b,h}`: a load-acquire exclusive of `size` bytes from `[base]`,
/// zero-extended (ARMv8.0).
pub fn ldaxr(e: *Encoder, size: Size, dst: Reg, base: Reg) !void {
    try e.reserve();
    e.word(0x085ffc00 | (@as(u32, @backingInt(size)) << 30) | (base.spEnc() << 5) | dst.zrEnc());
}

/// `stlxr{b,h}`: a store-release exclusive of the low `size` bytes of
/// `src` to `[base]`; `status` gets 0 if it stored, 1 if not.
pub fn stlxr(e: *Encoder, size: Size, status: Reg, src: Reg, base: Reg) !void {
    assert(status != src and status != base);
    try e.reserve();
    e.word(0x0800fc00 | (@as(u32, @backingInt(size)) << 30) | (status.zrEnc() << 16) | (base.spEnc() << 5) | src.zrEnc());
}

/// `ldaxp`: a load-acquire exclusive of the x register pair at `[base]`,
/// single-copy atomic only once a `stlxp` to it succeeds.
pub fn ldaxp(e: *Encoder, lo: Reg, hi: Reg, base: Reg) !void {
    try e.reserve();
    e.word(0xc87f8000 | (hi.zrEnc() << 10) | (base.spEnc() << 5) | lo.zrEnc());
}

/// `stlxp`: a store-release exclusive of the x register pair `lo`, `hi`
/// to `[base]`; `status` gets 0 if it stored, 1 if not.
pub fn stlxp(e: *Encoder, status: Reg, lo: Reg, hi: Reg, base: Reg) !void {
    assert(status != lo and status != hi and status != base);
    try e.reserve();
    e.word(0xc8208000 | (status.zrEnc() << 16) | (hi.zrEnc() << 10) | (base.spEnc() << 5) | lo.zrEnc());
}

/// `cas{a}{l}{b,h}`: compares `size` bytes at `[base]` with `expected`
/// and, if equal, stores `new`. `expected` receives the old value either
/// way (LSE, ARMv8.1, which every Apple Silicon core has).
pub fn cas(e: *Encoder, size: Size, order: Ordering, expected: Reg, new: Reg, base: Reg) !void {
    try e.reserve();
    e.word(0x08a07c00 | (@as(u32, @backingInt(size)) << 30) | (order.aBit() << 22) | (expected.zrEnc() << 16) |
        (order.rBit() << 15) | (base.spEnc() << 5) | new.zrEnc());
}

/// `casp{a}{l}`: `cas` of a pair of w (`.word`) or x (`.dword`) registers.
/// `expected` and `new` name the first of two consecutive registers, which
/// must be even.
pub fn casp(e: *Encoder, size: Size, order: Ordering, expected: Reg, new: Reg, base: Reg) !void {
    assert(size == .word or size == .dword);
    assert(expected.zrEnc() & 1 == 0 and new.zrEnc() & 1 == 0);
    try e.reserve();
    e.word(0x08207c00 | (@as(u32, @intFromBool(size == .dword)) << 30) | (order.aBit() << 22) | (expected.zrEnc() << 16) |
        (order.rBit() << 15) | (base.spEnc() << 5) | new.zrEnc());
}

pub const AtomicOp = enum(u4) { add, clr, eor, set, smax, smin, umax, umin, swp };

/// The LSE read-modify-writes `ld<op>{a}{l}{b,h}` and `swp`: `dst` gets
/// the old `size` bytes at `[base]`, and memory gets `old op src` (`src`
/// for swp; `clr` is and-not). With `dst` = zr and no acquire this is the
/// `st<op>` alias.
pub fn atomic(e: *Encoder, op: AtomicOp, size: Size, order: Ordering, src: Reg, dst: Reg, base: Reg) !void {
    try e.reserve();
    const o3: u32, const opc: u32 = if (op == .swp) .{ 1, 0 } else .{ 0, @backingInt(op) };
    e.word(0x38200000 | (@as(u32, @backingInt(size)) << 30) | (order.aBit() << 23) | (order.rBit() << 22) |
        (src.zrEnc() << 16) | (o3 << 15) | (opc << 12) | (base.spEnc() << 5) | dst.zrEnc());
}

/// Shareability domain and access types of a barrier, numbered as CRm.
pub const Barrier = enum(u4) {
    oshld = 0b0001,
    oshst = 0b0010,
    osh = 0b0011,
    nshld = 0b0101,
    nshst = 0b0110,
    nsh = 0b0111,
    ishld = 0b1001,
    ishst = 0b1010,
    /// Inner shareable, all accesses: what a `seq_cst` fence needs.
    ish = 0b1011,
    ld = 0b1101,
    st = 0b1110,
    sy = 0b1111,
};

/// `dmb option`
pub fn dmb(e: *Encoder, option: Barrier) !void {
    try e.reserve();
    e.word(0xd50330bf | (@as(u32, @backingInt(option)) << 8));
}

// ---------------------------------------------------------------- addresses

/// `adrp dst, sym+addend`: the 4 KiB page of the address, relative to this
/// instruction's page (page21 relocation). Complete it with `add` of
/// `.page_off` or a load or store with a `.page_off` offset.
pub fn adrp(e: *Encoder, dst: Reg, sym: SymbolKey, addend: i32) !void {
    try e.reserve();
    try e.reloc(.aarch64_page21, sym, addend);
    e.word(0x90000000 | dst.zrEnc());
}

/// `adr dst, label`: the address of a label in this function, ±1 MiB.
pub fn adr(e: *Encoder, dst: Reg, label: Label) !void {
    try e.reserve();
    try e.branchTo(0x10000000 | dst.zrEnc(), label, .adr21);
}

/// A 32-bit data word holding `label - anchor` in bytes, as a jump table
/// entry relative to the table's start: `adr x16, table; ldrsw x17, [x16,
/// idx, lsl #2]; add x16, x16, x17; br x16`.
pub fn labelDelta(e: *Encoder, label: Label, anchor: Label) !void {
    try e.reserve();
    try e.fixups.append(e.gpa, .{ .at = @intCast(e.code.items.len), .label = label, .field = .word32, .anchor = anchor });
    e.word(0);
}

/// `adrp dst, sym@GOTPAGE`: the page of `sym`'s GOT slot (GOT page21
/// relocation). Complete it with `ldr` of `.got_page_off`.
pub fn adrpGot(e: *Encoder, dst: Reg, sym: SymbolKey) !void {
    try e.reserve();
    try e.reloc(.aarch64_got_load_page21, sym, 0);
    e.word(0x90000000 | dst.zrEnc());
}

/// `dst = &sym + addend` for a symbol in this image: adrp, add.
pub fn loadAddr(e: *Encoder, dst: Reg, sym: SymbolKey, addend: i32) !void {
    try e.adrp(dst, sym, addend);
    try e.addSub(.add, .x, dst, dst, .{ .page_off = .{ .sym = sym, .addend = addend } });
}

/// `dst = &sym` through its GOT slot, for symbols that may be imported
/// from a dylib: adrp, ldr. The linker turns the ldr into an add when
/// `sym` turns out to be defined in the image.
pub fn loadGotAddr(e: *Encoder, dst: Reg, sym: SymbolKey) !void {
    try e.adrpGot(dst, sym);
    try e.ldr(.dword, dst, .{ .base = dst, .offset = .{ .got_page_off = sym } });
}

/// x0 = the address of thread-local `sym` for the calling thread: its
/// descriptor's address (tlvp relocations), then a call to the
/// descriptor's thunk, `adrp x0; add x0, x0; ldr x16, [x0]; blr x16`. The
/// thunk (dyld's tlv_get_addr) clobbers only x0, x16, x17, lr, and the
/// flags.
pub fn threadLocalAddr(e: *Encoder, sym: SymbolKey) !void {
    try e.reserve();
    try e.reloc(.aarch64_tlvp_page21, sym, 0);
    e.word(0x90000000); // adrp x0
    try e.reserve();
    try e.reloc(.aarch64_tlvp_pageoff12, sym, 0);
    e.word(0x91000000); // add x0, x0, #0
    try e.ldr(.dword, .x16, .at(.x0, 0));
    try e.blr(.x16);
}

/// `dst` = the address of thread-local `sym` for the calling thread, ELF
/// local-exec: `mrs dst, tpidr_el0; add dst, dst, #:tprel_hi12:sym, lsl
/// #12; add dst, dst, #:tprel_lo12_nc:sym`.
pub fn threadLocalOffset(e: *Encoder, dst: Reg, sym: SymbolKey) !void {
    try e.raw(System.mrs_tpidr_el0 | dst.zrEnc());
    try e.reserve();
    try e.reloc(.aarch64_tprel_hi12, sym, 0);
    e.word(0x91400000 | dst.zrEnc() << 5 | dst.zrEnc()); // add dst, dst, #0, lsl #12
    try e.reserve();
    try e.reloc(.aarch64_tprel_lo12_nc, sym, 0);
    e.word(0x91000000 | dst.zrEnc() << 5 | dst.zrEnc()); // add dst, dst, #0
}

// ---------------------------------------------------------------- moves

/// `mov dst, src`: orr with zr, or `add dst, src, #0` when either is sp.
pub fn mov(e: *Encoder, width: Width, dst: Reg, src: Reg) !void {
    if (dst == .sp or src == .sp) return e.addSub(.add, width, dst, src, .{ .imm = 0 });
    try e.logic(.orr, width, dst, .zr, .r(src));
}

pub const MovWideOp = enum(u2) { movn = 0b00, movz = 0b10, movk = 0b11 };

/// movz, movn, or movk of `imm` shifted left by `shift` (0, 16, 32, or 48;
/// 0 or 16 for w registers).
pub fn movWide(e: *Encoder, op: MovWideOp, width: Width, dst: Reg, imm: u16, shift: u6) !void {
    assert(shift % 16 == 0 and shift < width.bits());
    try e.reserve();
    e.word(0x12800000 | width.sf() | (@as(u32, @backingInt(op)) << 29) | (@as(u32, shift / 16) << 21) | (@as(u32, imm) << 5) | dst.zrEnc());
}

pub fn movz(e: *Encoder, width: Width, dst: Reg, imm: u16, shift: u6) !void {
    try e.movWide(.movz, width, dst, imm, shift);
}

pub fn movk(e: *Encoder, width: Width, dst: Reg, imm: u16, shift: u6) !void {
    try e.movWide(.movk, width, dst, imm, shift);
}

pub fn movn(e: *Encoder, width: Width, dst: Reg, imm: u16, shift: u6) !void {
    try e.movWide(.movn, width, dst, imm, shift);
}

/// movz or movk of the link-time value assigned to `sym`, such as an error
/// code, which must fit 16 bits (movw_value16 relocation).
pub fn movWideValue(e: *Encoder, op: MovWideOp, width: Width, dst: Reg, sym: SymbolKey, shift: u6) !void {
    assert(op != .movn);
    try e.reserve();
    try e.reloc(.aarch64_movw_value16, sym, 0);
    try e.movWide(op, width, dst, 0, shift);
}

/// Loads any constant into `dst` in as few instructions as this encoder
/// knows: one movz or movn, else one orr of a bitmask immediate, else movz
/// or movn (whichever leaves fewer halfwords to fix) followed by movks.
/// For w registers only the low 32 bits of `value` count.
pub fn movImm(e: *Encoder, width: Width, dst: Reg, value: u64) !void {
    assert(dst != .sp);
    const v = if (width == .w) value & 0xffff_ffff else value;
    const n: u3 = if (width == .w) 2 else 4;
    var zeros: u3 = 0;
    var ones: u3 = 0;
    for (0..n) |i| {
        const h: u16 = @truncate(v >> @intCast(i * 16));
        zeros += @intFromBool(h == 0);
        ones += @intFromBool(h == 0xffff);
    }
    if (zeros < n - 1 and ones < n - 1) if (bitmaskImm(width, v) != null)
        return e.logic(.orr, width, dst, .zr, .{ .imm = v });
    // Start from all zeros (movz) or all ones (movn); every halfword that
    // differs from the background needs a movk after the first.
    const inverted = ones > zeros;
    const background: u16 = if (inverted) 0xffff else 0;
    var first = true;
    for (0..n) |i| {
        const shift: u6 = @intCast(i * 16);
        const h: u16 = @truncate(v >> shift);
        if (h == background) continue;
        if (first) {
            if (inverted) try e.movn(width, dst, ~h, shift) else try e.movz(width, dst, h, shift);
            first = false;
        } else try e.movk(width, dst, h, shift);
    }
    if (first) {
        if (inverted) try e.movn(width, dst, 0, 0) else try e.movz(width, dst, 0, 0);
    }
}

// ---------------------------------------------------------------- arithmetic

pub const AddOp = enum(u2) { add = 0b00, adds = 0b01, sub = 0b10, subs = 0b11 };

/// `dst = src1 op src2` for add, sub, and their flag-setting forms. dst and
/// src1 may be sp, except that the flag-setting forms write zr instead and
/// shifted registers allow neither.
pub fn addSub(e: *Encoder, op: AddOp, width: Width, dst: Reg, src1: Reg, src2: AddOperand) !void {
    try e.reserve();
    const sets_flags = @backingInt(op) & 1 != 0;
    const base = width.sf() | (@as(u32, @backingInt(op)) << 29);
    switch (src2) {
        .imm => |imm| {
            const sh: u32, const imm12 = if (imm < 4096)
                .{ 0, imm }
            else blk: {
                assert(imm & 0xfff == 0 and imm < 1 << 24);
                break :blk .{ 1, imm >> 12 };
            };
            e.word(0x11000000 | base | (sh << 22) | (imm12 << 10) | (src1.spEnc() << 5) | rdSp(dst, sets_flags));
        },
        .reg => |s| {
            if ((dst == .sp or src1 == .sp) and s.shift == .lsl and s.amount == 0) {
                e.word(0x0b200000 | base | (s.reg.zrEnc() << 16) | (@as(u32, if (width == .x) 0b011 else 0b010) << 13) | (src1.spEnc() << 5) | rdSp(dst, sets_flags));
            } else {
                assert(s.shift != .ror and s.amount < width.bits());
                e.word(0x0b000000 | base | (@as(u32, @backingInt(s.shift)) << 22) | (s.reg.zrEnc() << 16) | (@as(u32, s.amount) << 10) | (src1.zrEnc() << 5) | dst.zrEnc());
            }
        },
        .extended => |x| {
            assert(x.amount <= 4);
            e.word(0x0b200000 | base | (x.reg.zrEnc() << 16) | (@as(u32, @backingInt(x.extend)) << 13) | (@as(u32, x.amount) << 10) | (src1.spEnc() << 5) | rdSp(dst, sets_flags));
        },
        .page_off => |s| {
            assert(op == .add);
            try e.reloc(.aarch64_pageoff12, s.sym, s.addend);
            e.word(0x11000000 | base | (src1.spEnc() << 5) | rdSp(dst, sets_flags));
        },
    }
}

/// The destination of the immediate and extended-register forms: sp,
/// unless the instruction sets flags, when 31 is zr.
fn rdSp(dst: Reg, sets_flags: bool) u32 {
    return if (sets_flags) dst.zrEnc() else dst.spEnc();
}

/// `cmp lhs, rhs`: subs to zr.
pub const CarryOp = enum(u2) { adc = 0b00, adcs = 0b01, sbc = 0b10, sbcs = 0b11 };

/// `dst = src1 + src2 + C` (adc, adcs) or `src1 - src2 - !C` (sbc, sbcs),
/// for arithmetic over several words.
pub fn carry(e: *Encoder, op: CarryOp, width: Width, dst: Reg, src1: Reg, src2: Reg) !void {
    try e.reserve();
    e.word(0x1a000000 | width.sf() | (@as(u32, @backingInt(op)) << 29) | (src2.zrEnc() << 16) | (src1.zrEnc() << 5) | dst.zrEnc());
}

pub fn cmp(e: *Encoder, width: Width, lhs: Reg, rhs: AddOperand) !void {
    try e.addSub(.subs, width, .zr, lhs, rhs);
}

/// `cmn lhs, rhs`: adds to zr.
pub fn cmn(e: *Encoder, width: Width, lhs: Reg, rhs: AddOperand) !void {
    try e.addSub(.adds, width, .zr, lhs, rhs);
}

/// The logical operations; the second four invert their register operand.
pub const LogicOp = enum(u3) { @"and", orr, eor, ands, bic, orn, eon, bics };

/// `dst = src1 op src2`. dst may be sp for and, orr, and eor with an
/// immediate.
pub fn logic(e: *Encoder, op: LogicOp, width: Width, dst: Reg, src1: Reg, src2: LogicOperand) !void {
    try e.reserve();
    const opc: u32 = @as(u2, @truncate(@backingInt(op)));
    const base = width.sf() | (opc << 29) | (src1.zrEnc() << 5);
    switch (src2) {
        .imm => |imm| {
            assert(@backingInt(op) < 4);
            const mask = bitmaskImm(width, imm).?;
            const rd = if (op == .ands) dst.zrEnc() else dst.spEnc();
            e.word(0x12000000 | base | (@as(u32, mask.n) << 22) | (@as(u32, mask.immr) << 16) | (@as(u32, mask.imms) << 10) | rd);
        },
        .reg => |s| {
            assert(s.amount < width.bits());
            const n: u32 = @intFromBool(@backingInt(op) >= 4);
            e.word(0x0a000000 | base | (@as(u32, @backingInt(s.shift)) << 22) | (n << 21) | (s.reg.zrEnc() << 16) | (@as(u32, s.amount) << 10) | dst.zrEnc());
        },
    }
}

/// `tst lhs, rhs`: ands to zr.
pub fn tst(e: *Encoder, width: Width, lhs: Reg, rhs: LogicOperand) !void {
    try e.logic(.ands, width, .zr, lhs, rhs);
}

/// `mvn dst, src`: orn with zr.
pub fn mvn(e: *Encoder, width: Width, dst: Reg, src: Reg) !void {
    try e.logic(.orn, width, dst, .zr, .r(src));
}

pub const BitmaskImm = struct { n: u1, immr: u6, imms: u6 };

/// The N:immr:imms encoding of `value` as a logical immediate of `width`
/// bits, or null if it has none: a rotated run of ones within an element of
/// 2, 4, 8, 16, 32, or 64 bits, repeated. 0 and all ones have none.
pub fn bitmaskImm(width: Width, value: u64) ?BitmaskImm {
    var v = value;
    if (width == .w) {
        if (v >> 32 != 0) return null;
        v |= v << 32;
    }
    if (v == 0 or v == std.math.maxInt(u64)) return null;
    // The smallest element size whose repetition gives v.
    var esize: u7 = 64;
    while (esize > 2) {
        const half = esize / 2;
        const mask = (@as(u64, 1) << @intCast(half)) - 1;
        if ((v & mask) != ((v >> @intCast(half)) & mask)) break;
        esize = half;
    }
    const emask: u64 = if (esize == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(esize)) - 1;
    const elem = v & emask;
    const ones: u7 = @popCount(elem);
    const run = (@as(u64, 1) << @intCast(ones)) - 1;
    // elem must be `run` rotated right by some r within the element.
    var r: u7 = 0;
    while (r < esize) : (r += 1) {
        const rotated = if (r == 0) run else ((run >> @intCast(r)) | (run << @intCast(esize - r))) & emask;
        if (rotated == elem) break;
    } else return null;
    // imms holds the run length minus one, under a prefix of ones that
    // gives the element size (N=1 for 64).
    const prefix: u6 = @truncate(~(@as(u8, esize) * 2 - 1));
    return .{ .n = @intFromBool(esize == 64), .immr = @intCast(r), .imms = prefix | @as(u6, @intCast(ones - 1)) };
}

pub const MulOp = enum { madd, msub };

/// `dst = acc ± src1 * src2` (madd, msub).
pub fn mulAdd(e: *Encoder, op: MulOp, width: Width, dst: Reg, src1: Reg, src2: Reg, acc: Reg) !void {
    try e.reserve();
    e.word(0x1b000000 | width.sf() | (src2.zrEnc() << 16) | (@as(u32, @intFromBool(op == .msub)) << 15) | (acc.zrEnc() << 10) | (src1.zrEnc() << 5) | dst.zrEnc());
}

/// `mul dst, src1, src2`: madd with zr.
pub fn mul(e: *Encoder, width: Width, dst: Reg, src1: Reg, src2: Reg) !void {
    try e.mulAdd(.madd, width, dst, src1, src2, .zr);
}

/// smulh/umulh: the high 64 bits of the 128-bit product of x registers.
pub fn mulHigh(e: *Encoder, signed: bool, dst: Reg, src1: Reg, src2: Reg) !void {
    try e.reserve();
    const base: u32 = if (signed) 0x9b407c00 else 0x9bc07c00;
    e.word(base | (src2.zrEnc() << 16) | (src1.zrEnc() << 5) | dst.zrEnc());
}

/// smull/umull: the 64-bit product of two w registers into an x register
/// (smaddl/umaddl with xzr).
pub fn mulLong(e: *Encoder, signed: bool, dst: Reg, src1: Reg, src2: Reg) !void {
    try e.reserve();
    const base: u32 = if (signed) 0x9b207c00 else 0x9ba07c00;
    e.word(base | (src2.zrEnc() << 16) | (src1.zrEnc() << 5) | dst.zrEnc());
}

/// udiv/sdiv. Division by zero gives 0; it does not trap.
pub fn div(e: *Encoder, signed: bool, width: Width, dst: Reg, src1: Reg, src2: Reg) !void {
    try e.reserve();
    e.word(0x1ac00800 | width.sf() | (src2.zrEnc() << 16) | (@as(u32, @intFromBool(signed)) << 10) | (src1.zrEnc() << 5) | dst.zrEnc());
}

/// Shift by a register (lslv, lsrv, asrv, rorv); the amount is taken modulo
/// the width.
pub fn shiftReg(e: *Encoder, op: Shift, width: Width, dst: Reg, src: Reg, amount: Reg) !void {
    try e.reserve();
    e.word(0x1ac02000 | width.sf() | (amount.zrEnc() << 16) | (@as(u32, @backingInt(op)) << 10) | (src.zrEnc() << 5) | dst.zrEnc());
}

/// Shift by an immediate below the width: lsl and lsr (ubfm), asr (sbfm),
/// ror (extr).
pub fn shiftImm(e: *Encoder, op: Shift, width: Width, dst: Reg, src: Reg, amount: u6) !void {
    const bits = width.bits();
    assert(amount < bits);
    const top: u6 = @intCast(bits - 1);
    switch (op) {
        .lsl => try e.bitfield(.ubfm, width, dst, src, @intCast((bits - amount) % bits), top - amount),
        .lsr => try e.bitfield(.ubfm, width, dst, src, amount, top),
        .asr => try e.bitfield(.sbfm, width, dst, src, amount, top),
        .ror => {
            try e.reserve();
            // extr dst, src, src, #amount
            const n: u32 = @backingInt(width);
            e.word(0x13800000 | width.sf() | (n << 22) | (src.zrEnc() << 16) | (@as(u32, amount) << 10) | (src.zrEnc() << 5) | dst.zrEnc());
        },
    }
}

pub const BitfieldOp = enum(u2) { sbfm = 0b00, bfm = 0b01, ubfm = 0b10 };

/// sbfm, bfm, ubfm, from which the shifts, extensions, and bitfield
/// extracts and inserts are built.
pub fn bitfield(e: *Encoder, op: BitfieldOp, width: Width, dst: Reg, src: Reg, immr: u6, imms: u6) !void {
    assert(immr < width.bits() and imms < width.bits());
    try e.reserve();
    const n: u32 = @backingInt(width);
    e.word(0x13000000 | width.sf() | (@as(u32, @backingInt(op)) << 29) | (n << 22) | (@as(u32, immr) << 16) | (@as(u32, imms) << 10) | (src.zrEnc() << 5) | dst.zrEnc());
}

/// Sign-extends the low `from` bytes of `src` to `width`: sxtb, sxth, sxtw
/// (to x only).
pub fn sxt(e: *Encoder, from: Size, width: Width, dst: Reg, src: Reg) !void {
    assert(@backingInt(from) < 2 or (from == .word and width == .x));
    try e.bitfield(.sbfm, width, dst, src, 0, @intCast(@as(u8, from.bytes()) * 8 - 1));
}

/// Zero-extends the low `from` bytes of `src`: uxtb and uxth (which write a
/// w register and so clear the upper half of the x register), and for
/// `.word` `mov wd, ws`.
pub fn uxt(e: *Encoder, from: Size, dst: Reg, src: Reg) !void {
    switch (from) {
        .byte, .half => try e.bitfield(.ubfm, .w, dst, src, 0, @intCast(@as(u8, from.bytes()) * 8 - 1)),
        .word => try e.mov(.w, dst, src),
        .dword => unreachable,
    }
}

pub const CselOp = enum(u2) { csel, csinc, csinv, csneg };

/// `dst = cond ? src1 : op(src2)`: csel, csinc, csinv, csneg.
pub fn csel(e: *Encoder, op: CselOp, width: Width, dst: Reg, src1: Reg, src2: Reg, cond: Cond) !void {
    try e.reserve();
    const o: u32 = @backingInt(op);
    e.word(0x1a800000 | width.sf() | ((o >> 1) << 30) | (src2.zrEnc() << 16) | (@as(u32, @backingInt(cond)) << 12) | ((o & 1) << 10) | (src1.zrEnc() << 5) | dst.zrEnc());
}

/// `cset dst, cond`: 1 if `cond` holds, else 0 (csinc dst, zr, zr, !cond).
pub fn cset(e: *Encoder, width: Width, dst: Reg, cond: Cond) !void {
    try e.csel(.csinc, width, dst, .zr, .zr, cond.negate());
}

/// `csetm dst, cond`: all ones if `cond` holds, else 0.
pub fn csetm(e: *Encoder, width: Width, dst: Reg, cond: Cond) !void {
    try e.csel(.csinv, width, dst, .zr, .zr, cond.negate());
}

pub const CcmpOperand = union(enum) { reg: Reg, imm: u5 };

/// ccmp/ccmn: if `cond` holds, sets the flags from `lhs - rhs` (or `lhs +
/// rhs` for ccmn), else sets them to `nzcv`. Chains compares for `and`
/// and `or` of conditions without branches.
pub fn ccmp(e: *Encoder, negative: bool, width: Width, lhs: Reg, rhs: CcmpOperand, nzcv: u4, cond: Cond) !void {
    try e.reserve();
    const base: u32 = if (negative) 0x3a400000 else 0x7a400000;
    const m: u32 = switch (rhs) {
        .reg => |r| r.zrEnc() << 16,
        .imm => |i| (@as(u32, i) << 16) | (1 << 11),
    };
    e.word(base | width.sf() | m | (@as(u32, @backingInt(cond)) << 12) | (lhs.zrEnc() << 5) | nzcv);
}

pub const BitOp = enum { rbit, rev16, rev32, rev, clz, cls };

/// Data-processing (1 source): rbit, rev16 (bytes within halfwords), rev32
/// (bytes within words, x only), rev (bytes of the register), clz, cls.
pub fn bitOp(e: *Encoder, op: BitOp, width: Width, dst: Reg, src: Reg) !void {
    assert(op != .rev32 or width == .x);
    try e.reserve();
    const opcode: u32 = switch (op) {
        .rbit => 0,
        .rev16 => 1,
        .rev32 => 2,
        .rev => if (width == .x) 3 else 2,
        .clz => 4,
        .cls => 5,
    };
    e.word(0x5ac00000 | width.sf() | (opcode << 10) | (src.zrEnc() << 5) | dst.zrEnc());
}

// ---------------------------------------------------------------- control flow

/// `b`: to a label, or to a symbol (branch26 relocation; the linker sends
/// branches to imported functions through a stub).
pub fn b(e: *Encoder, target: Target) !void {
    try e.branch26(0x14000000, target);
}

/// Rewrites the instruction emitted earlier at offset `at` into `b label`,
/// as a function's prologue jumps to frame allocation code placed after
/// its body once the frame size is known.
pub fn branchFrom(e: *Encoder, at: u32, label: Label) !void {
    std.mem.writeInt(u32, e.code.items[at..][0..4], 0x14000000, .little);
    try e.fixups.append(e.gpa, .{ .at = at, .label = label, .field = .imm26 });
}

/// `bl`, as `b`.
pub fn bl(e: *Encoder, target: Target) !void {
    try e.branch26(0x94000000, target);
}

/// `b.cond` to a label.
pub fn bcond(e: *Encoder, cond: Cond, label: Label) !void {
    try e.reserve();
    try e.branchTo(0x54000000 | @as(u32, @backingInt(cond)), label, .imm19);
}

/// cbz/cbnz: branch to a label if `reg` is zero (or not).
pub fn cbz(e: *Encoder, nonzero: bool, width: Width, reg: Reg, label: Label) !void {
    try e.reserve();
    try e.branchTo(0x34000000 | width.sf() | (@as(u32, @intFromBool(nonzero)) << 24) | reg.zrEnc(), label, .imm19);
}

/// tbz/tbnz: branch to a label if bit `bit` of `reg` is zero (or not).
/// Reaches only ±32 KiB.
pub fn tbz(e: *Encoder, nonzero: bool, reg: Reg, bit: u6, label: Label) !void {
    try e.reserve();
    try e.branchTo(0x36000000 | (@as(u32, bit >> 5) << 31) | (@as(u32, @intFromBool(nonzero)) << 24) | (@as(u32, @as(u5, @truncate(bit))) << 19) | reg.zrEnc(), label, .imm14);
}

/// `br reg`
pub fn br(e: *Encoder, reg: Reg) !void {
    try e.reserve();
    e.word(0xd61f0000 | (reg.zrEnc() << 5));
}

/// `blr reg`
pub fn blr(e: *Encoder, reg: Reg) !void {
    try e.reserve();
    e.word(0xd63f0000 | (reg.zrEnc() << 5));
}

/// `ret` (to x30).
pub fn ret(e: *Encoder) !void {
    try e.reserve();
    e.word(0xd65f03c0);
}

/// `svc #imm`. On macOS the syscall number goes in x16 and `imm` is 0x80.
pub fn svc(e: *Encoder, imm: u16) !void {
    try e.reserve();
    e.word(0xd4000001 | (@as(u32, imm) << 5));
}

/// `brk #imm`. `@trap()` is `brk #1` on aarch64.
pub fn brk(e: *Encoder, imm: u16) !void {
    try e.reserve();
    e.word(0xd4200000 | (@as(u32, imm) << 5));
}

pub fn nop(e: *Encoder) !void {
    try e.reserve();
    e.word(0xd503201f);
}

/// `udf #imm`: permanently undefined; raises SIGILL.
pub fn udf(e: *Encoder, imm: u16) !void {
    try e.reserve();
    e.word(imm);
}

/// An instruction this encoder has no function for, already encoded:
/// inline assembly's hints and system instructions (`System` lists them).
pub fn raw(e: *Encoder, insn: u32) !void {
    try e.reserve();
    e.word(insn);
}

/// Encodings of the operand-less system instructions and system register
/// reads inline assembly uses, as the system assembler writes them.
pub const System = struct {
    pub const nop: u32 = 0xd503201f;
    pub const yield: u32 = 0xd503203f;
    pub const wfe: u32 = 0xd503205f;
    pub const wfi: u32 = 0xd503207f;
    pub const sev: u32 = 0xd503209f;
    pub const sevl: u32 = 0xd50320bf;
    pub const isb: u32 = 0xd5033fdf;
    pub const clrex: u32 = 0xd503305f;
    /// `dsb <option>`: or in the option (`Barrier`) at bit 8.
    pub const dsb: u32 = 0xd503309f;
    /// `mrs xt, tpidrro_el0` / `tpidr_el0`: or in the register.
    pub const mrs_tpidrro_el0: u32 = 0xd53bd060;
    pub const mrs_tpidr_el0: u32 = 0xd53bd040;
    /// `msr tpidr_el0, xt`: or in the register.
    pub const msr_tpidr_el0: u32 = 0xd51bd040;

    /// `mrs xt, <name>` for the system registers EL0 code reads (the
    /// thread pointers, the cache type, and the ID registers that Linux
    /// emulates for std's CPU detection), case-insensitive: or in the
    /// register. Null for another name.
    pub fn mrs(name: []const u8) ?u32 {
        const regs = [_]struct { []const u8, [5]u32 }{
            .{ "tpidr_el0", .{ 3, 3, 13, 0, 2 } },       .{ "tpidrro_el0", .{ 3, 3, 13, 0, 3 } },
            .{ "ctr_el0", .{ 3, 3, 0, 0, 1 } },          .{ "midr_el1", .{ 3, 0, 0, 0, 0 } },
            .{ "id_aa64pfr0_el1", .{ 3, 0, 0, 4, 0 } },  .{ "id_aa64pfr1_el1", .{ 3, 0, 0, 4, 1 } },
            .{ "id_aa64dfr0_el1", .{ 3, 0, 0, 5, 0 } },  .{ "id_aa64dfr1_el1", .{ 3, 0, 0, 5, 1 } },
            .{ "id_aa64afr0_el1", .{ 3, 0, 0, 5, 4 } },  .{ "id_aa64afr1_el1", .{ 3, 0, 0, 5, 5 } },
            .{ "id_aa64isar0_el1", .{ 3, 0, 0, 6, 0 } }, .{ "id_aa64isar1_el1", .{ 3, 0, 0, 6, 1 } },
            .{ "id_aa64mmfr0_el1", .{ 3, 0, 0, 7, 0 } }, .{ "id_aa64mmfr1_el1", .{ 3, 0, 0, 7, 1 } },
            .{ "id_aa64mmfr2_el1", .{ 3, 0, 0, 7, 2 } },
        };
        for (regs) |r| if (std.ascii.eqlIgnoreCase(name, r[0])) {
            const f = r[1];
            return 0xd5200000 | f[0] << 19 | f[1] << 16 | f[2] << 12 | f[3] << 8 | f[4] << 5;
        };
        return null;
    }
};

/// The stack probe before allocating a frame of `size` bytes, needed when
/// `size` exceeds the 4 KiB guard page: `mov x9, #size; bl chkstk`, where
/// `chkstk` is the libSystem import `__chkstk_darwin` (clang emits the
/// same for frames over 4 KiB). It touches every page from sp down to sp -
/// size, counting x9 down, and preserves every register but x9, x16, x17,
/// lr, and the flags; the caller then subtracts `size` from sp.
pub fn stackProbe(e: *Encoder, size: u32, chkstk: SymbolKey) !void {
    try e.movImm(.x, .x9, size);
    try e.bl(.{ .sym = chkstk });
}

// ---------------------------------------------------------------- scalar floating point

/// fmov between floating-point registers of the same type.
pub fn fmov(e: *Encoder, ty: Float, dst: VReg, src: VReg) !void {
    try e.reserve();
    e.word(0x1e204000 | ty.ftype() | (src.enc() << 5) | dst.enc());
}

/// fmov of the bits of a general register into an h, s, or d register: w
/// to s, x to d, w or x to h (low 16 bits).
pub fn fmovFromGpr(e: *Encoder, ty: Float, dst: VReg, width: Width, src: Reg) !void {
    assert(ty == .f16 or (ty == .f32) == (width == .w));
    try e.reserve();
    e.word(0x1e270000 | width.sf() | ty.ftype() | (src.zrEnc() << 5) | dst.enc());
}

/// fmov of the bits of an h, s, or d register into a general register.
pub fn fmovToGpr(e: *Encoder, width: Width, dst: Reg, ty: Float, src: VReg) !void {
    assert(ty == .f16 or (ty == .f32) == (width == .w));
    try e.reserve();
    e.word(0x1e260000 | width.sf() | ty.ftype() | (src.enc() << 5) | dst.zrEnc());
}

pub const FpOp = enum(u4) { mul = 0b0000, div = 0b0001, add = 0b0010, sub = 0b0011, max = 0b0100, min = 0b0101, maxnm = 0b0110, minnm = 0b0111 };

/// `dst = src1 op src2`: fadd, fsub, fmul, fdiv, fmax, fmin, fmaxnm, fminnm.
pub fn fp(e: *Encoder, op: FpOp, ty: Float, dst: VReg, src1: VReg, src2: VReg) !void {
    try e.reserve();
    e.word(0x1e200800 | ty.ftype() | (src2.enc() << 16) | (@as(u32, @backingInt(op)) << 12) | (src1.enc() << 5) | dst.enc());
}

pub const FpUnaryOp = enum(u6) {
    abs = 0b000001,
    neg = 0b000010,
    sqrt = 0b000011,
    /// Round to nearest, ties to even.
    rintn = 0b001000,
    /// Round toward +inf (@ceil).
    rintp = 0b001001,
    /// Round toward -inf (@floor).
    rintm = 0b001010,
    /// Round toward zero (@trunc).
    rintz = 0b001011,
    /// Round to nearest, ties away from zero (@round).
    rinta = 0b001100,
};

/// fabs, fneg, fsqrt, frint*.
pub fn fpUnary(e: *Encoder, op: FpUnaryOp, ty: Float, dst: VReg, src: VReg) !void {
    try e.reserve();
    e.word(0x1e204000 | ty.ftype() | (@as(u32, @backingInt(op)) << 15) | (src.enc() << 5) | dst.enc());
}

/// fcvt between h, s, and d.
pub fn fcvt(e: *Encoder, to: Float, dst: VReg, from: Float, src: VReg) !void {
    assert(to != from);
    try e.reserve();
    e.word(0x1e224000 | from.ftype() | (@as(u32, @backingInt(to)) << 15) | (src.enc() << 5) | dst.enc());
}

/// `fcmp lhs, rhs`, or `fcmp lhs, #0.0` when `rhs` is null. An unordered result
/// (a NaN operand) sets C and V, so `eq`, `mi` (<), `ls` (<=), `gt`, and
/// `ge` are false for it and `ne` is true; `lt` and `le` are not ordered.
pub fn fcmp(e: *Encoder, ty: Float, lhs: VReg, rhs: ?VReg) !void {
    try e.reserve();
    const rm: u32, const zero: u32 = if (rhs) |r| .{ r.enc(), 0 } else .{ 0, 0b01000 };
    e.word(0x1e202000 | ty.ftype() | (rm << 16) | (lhs.enc() << 5) | zero);
}

pub const FmaOp = enum(u2) {
    /// `a + n*m`
    madd = 0b00,
    /// `a - n*m`
    msub = 0b01,
    /// `-a - n*m`
    nmadd = 0b10,
    /// `-a + n*m`
    nmsub = 0b11,
};

/// Fused multiply-add (fmadd, fmsub, fnmadd, fnmsub), rounding once.
pub fn fma(e: *Encoder, op: FmaOp, ty: Float, dst: VReg, n: VReg, m: VReg, a: VReg) !void {
    try e.reserve();
    const o: u32 = @backingInt(op);
    e.word(0x1f000000 | ty.ftype() | ((o >> 1) << 21) | (m.enc() << 16) | ((o & 1) << 15) | (a.enc() << 10) | (n.enc() << 5) | dst.enc());
}

/// The 8-bit immediate of `fmov` that encodes `value`, if any: ±n/16 ×
/// 2^e for n in 16..31 and e in -3..4 (0.0 is not one).
pub fn fpImm(value: f64) ?u8 {
    for (0..256) |i| {
        const imm: u8 = @intCast(i);
        if (expandFpImm(imm) == value) return imm;
    }
    return null;
}

fn expandFpImm(imm: u8) f64 {
    const frac: f64 = @floatFromInt(16 + (imm & 15));
    const b54: i32 = (imm >> 4) & 3;
    const exp: i32 = if (imm & 0x40 != 0) b54 - 3 else b54 + 1;
    const mag = std.math.ldexp(frac / 16, exp);
    return if (imm & 0x80 != 0) -mag else mag;
}

/// `fmov dst, #imm`, with `imm` from `fpImm`.
pub fn fmovImm(e: *Encoder, ty: Float, dst: VReg, imm: u8) !void {
    try e.reserve();
    e.word(0x1e201000 | ty.ftype() | (@as(u32, imm) << 13) | dst.enc());
}

/// `cnt vd.8b, vn.8b`: the number of set bits in each byte. `@popCount`
/// is `fmov d, x; cnt; addv b; fmov w, s`.
pub fn cnt(e: *Encoder, dst: VReg, src: VReg) !void {
    try e.reserve();
    e.word(0x0e205800 | (src.enc() << 5) | dst.enc());
}

/// `addv bd, vn.8b`: the sum of the 8 bytes, zeroing the rest of `dst`.
pub fn addv(e: *Encoder, dst: VReg, src: VReg) !void {
    try e.reserve();
    e.word(0x0e31b800 | (src.enc() << 5) | dst.enc());
}

/// fcsel: `dst = cond ? src1 : src2`.
pub fn fcsel(e: *Encoder, ty: Float, dst: VReg, src1: VReg, src2: VReg, cond: Cond) !void {
    try e.reserve();
    e.word(0x1e200c00 | ty.ftype() | (src2.enc() << 16) | (@as(u32, @backingInt(cond)) << 12) | (src1.enc() << 5) | dst.enc());
}

/// scvtf/ucvtf: converts a w or x integer to floating point.
pub fn cvtf(e: *Encoder, signed: bool, ty: Float, dst: VReg, width: Width, src: Reg) !void {
    try e.reserve();
    e.word(0x1e220000 | width.sf() | ty.ftype() | (@as(u32, @intFromBool(!signed)) << 16) | (src.zrEnc() << 5) | dst.enc());
}

/// fcvtzs/fcvtzu: converts floating point to a w or x integer, rounding
/// toward zero and saturating.
pub fn fcvtz(e: *Encoder, signed: bool, width: Width, dst: Reg, ty: Float, src: VReg) !void {
    try e.reserve();
    e.word(0x1e380000 | width.sf() | ty.ftype() | (@as(u32, @intFromBool(!signed)) << 16) | (src.enc() << 5) | dst.zrEnc());
}

// ---------------------------------------------------------------- encoding core

/// Every instruction reserves capacity first, so `word` cannot fail. Only
/// relocations and label fixups allocate in the middle of an instruction.
fn reserve(e: *Encoder) !void {
    try e.code.ensureUnusedCapacity(e.gpa, 4);
}

fn word(e: *Encoder, w: u32) void {
    std.mem.writeInt(u32, e.code.addManyAsArrayAssumeCapacity(4), w, .little);
}

/// `v` as a `bits`-bit two's complement field. Asserts that it fits.
fn simm(comptime bits: u16, v: i32) u32 {
    const T = @Int(.signed, bits);
    const U = @Int(.unsigned, bits);
    return @as(U, @bitCast(@as(T, @intCast(v))));
}

fn reloc(e: *Encoder, kind: Atom.Reloc.Kind, target: SymbolKey, addend: i32) !void {
    try e.refs.append(e.gpa, @intCast(e.code.items.len), kind, target, addend);
}

fn branch26(e: *Encoder, opcode: u32, target: Target) !void {
    try e.reserve();
    switch (target) {
        .sym => |s| {
            try e.reloc(.aarch64_branch26, s, 0);
            e.word(opcode);
        },
        .label => |l| try e.branchTo(opcode, l, .imm26),
    }
}

/// Emits `opcode` with a zero offset field and a fixup that `finish`
/// points at `label`.
fn branchTo(e: *Encoder, opcode: u32, label: Label, field: BranchField) !void {
    try e.fixups.append(e.gpa, .{ .at = @intCast(e.code.items.len), .label = label, .field = field });
    e.word(opcode);
}

fn patchBranch(e: *Encoder, at: u32, dest: u32, field: BranchField) error{BranchOutOfRange}!void {
    assert(dest != unbound);
    const delta = (@as(i64, dest) - at) >> 2;
    const bits = field.bits();
    if (!fits(delta, bits)) return error.BranchOutOfRange;
    const mask = (@as(u32, 1) << bits) - 1;
    const insn = e.code.items[at..][0..4];
    const v = std.mem.readInt(u32, insn, .little) | ((@as(u32, @truncate(@as(u64, @bitCast(delta)))) & mask) << field.lsb());
    std.mem.writeInt(u32, insn, v, .little);
}

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "encodings with special cases match the system assembler" {
    const gpa = std.testing.allocator;
    var e: Encoder = .init(gpa);
    defer e.deinit();
    const foo: SymbolKey = .fromName("foo");
    try e.ldr(.dword, .x0, .at(.sp, 8)); // ldr x0, [sp, #8]: scaled
    try e.ldr(.dword, .x0, .at(.sp, 12)); // ldur x0, [sp, #12]: not a multiple of 8
    try e.ldr(.word, .x1, .at(.x2, -4)); // ldur w1, [x2, #-4]
    try e.ldrs(.byte, .x, .x3, .{ .base = .x4, .offset = .{ .post = 1 } }); // ldrsb x3, [x4], #1
    try e.str(.half, .zr, .{ .base = .x5, .offset = .{ .index = .{ .reg = .x6, .scaled = true } } }); // strh wzr, [x5, x6, lsl #1]
    try e.stp(.dword, .fp, .lr, .{ .base = .sp, .offset = .{ .pre = -16 } }); // stp x29, x30, [sp, #-16]!
    try e.addSub(.add, .x, .fp, .sp, .{ .imm = 0 }); // mov x29, sp
    try e.addSub(.sub, .x, .sp, .sp, .{ .imm = 0x10000 }); // sub sp, sp, #16, lsl #12
    try e.addSub(.add, .x, .x0, .sp, .r(.x1)); // add x0, sp, x1: extended form
    try e.cmp(.w, .x0, .{ .extended = .{ .reg = .x1, .extend = .sxtb } }); // cmp w0, w1, sxtb
    try e.logic(.@"and", .x, .x0, .x1, .{ .imm = 0x00ff00ff00ff00ff }); // and x0, x1, #0xff00ff00ff00ff
    try e.movImm(.x, .x0, 0xffff_ffff_ffff_fffe); // mov x0, #-2: movn
    try e.movImm(.w, .x0, 0x0f0f0f0f); // mov w0, #0xf0f0f0f: orr
    try e.shiftImm(.lsl, .x, .x0, .x1, 3); // lsl x0, x1, #3
    try e.cset(.w, .x0, .lo); // cset w0, lo
    try e.loadAddr(.x0, foo, 8); // adrp x0, foo+8; add x0, x0, :lo12:foo+8
    try e.ldrFp(.f64, .v1, .{ .base = .x0, .offset = .{ .page_off = .{ .sym = foo } } }); // ldr d1, [x0, :lo12:foo]
    try e.bl(.{ .sym = foo }); // bl foo
    try e.fcmp(.f32, .v0, null); // fcmp s0, #0.0
    try e.fcvtz(false, .x, .x0, .f16, .v2); // fcvtzu x0, h2
    const want = hex("e00740f9" ++ "e0c340f8" ++ "41c05fb8" ++ "83148038" ++ "bf782678" ++ "fd7bbfa9" ++ "fd030091" ++
        "ff4340d1" ++ "e063218b" ++ "1f80216b" ++ "209c0092" ++ "20008092" ++ "e0cf0032" ++ "20f07dd3" ++
        "e0279f1a" ++ "00000090" ++ "00000091" ++ "010040fd" ++ "00000094" ++ "0820201e" ++ "4000f99e");
    try std.testing.expectEqualSlices(u8, &want, e.code.items);
    try std.testing.expectEqualSlices(SymbolKey, &.{foo}, e.refs.targets.keys());
    try std.testing.expectEqualDeep(&[_]Atom.Reloc{
        .init(0x3c, .aarch64_page21, 0, 8),
        .init(0x40, .aarch64_pageoff12, 0, 8),
        .init(0x44, .aarch64_pageoff12, 0, 0),
        .init(0x48, .aarch64_branch26, 0, 0),
    }, e.refs.relocs.items);
}

test "branches to labels bound before and after them" {
    const gpa = std.testing.allocator;
    var e: Encoder = .init(gpa);
    defer e.deinit();
    const top = try e.newLabel();
    const out = try e.newLabel();
    e.bind(top);
    try e.bcond(.eq, out); // 0: b.eq 16
    try e.cbz(true, .x, .x3, out); // 4: cbnz x3, 16
    try e.tbz(false, .x5, 33, out); // 8: tbz x5, #33, 16
    try e.b(.{ .label = top }); // 12: b 0
    e.bind(out); // 16
    try e.ret();
    try e.finish();
    try std.testing.expectEqualSlices(u8, &hex("80000054" ++ "630000b5" ++ "450008b6" ++ "fdffff17" ++ "c0035fd6"), e.code.items);
    try std.testing.expectEqual(0, e.refs.relocs.items.len);
}

test "relaxes conditional branches that cannot reach their labels" {
    const gpa = std.testing.allocator;
    var e: Encoder = .init(gpa);
    defer e.deinit();
    const foo: SymbolKey = .fromName("foo");
    const top = try e.newLabel();
    const mid = try e.newLabel();
    const far = try e.newLabel();
    e.bind(top);
    try e.tbz(false, .x0, 0, mid); // 0: reaches mid at 32764 until the tbnz below grows
    try e.tbz(true, .x1, 3, far); // 4: too far
    try e.bl(.{ .sym = foo }); // 8
    try e.cbz(false, .x, .x2, mid); // 12: in range
    while (e.code.items.len < 32764) try e.nop();
    e.bind(mid);
    try e.adr(.x3, top);
    while (e.code.items.len < 40000) try e.nop();
    e.bind(far);
    try e.tbz(true, .x4, 63, top); // 40000: backward, too far
    try e.ret();
    try e.finish();

    try std.testing.expectEqualSlices(u32, &.{ 0, 4, 40000 }, e.relaxed.items);
    try std.testing.expectEqual(40020, e.code.items.len);
    // Relaxed branches stay put; code after one moves by 4, so an inline
    // range ending right after a relaxed branch covers its `b`, and the old
    // size maps to the new one.
    for ([_][2]u32{ .{ 0, 0 }, .{ 4, 8 }, .{ 8, 16 }, .{ 32764, 32772 }, .{ 40000, 40008 }, .{ 40004, 40016 }, .{ 40008, 40020 } }) |m|
        try std.testing.expectEqual(m[1], e.finalOffset(m[0]));
    // tbnz x0, #0, +8; b mid; tbz w1, #3, +8; b far; bl foo; cbz x2, mid
    try std.testing.expectEqualSlices(u8, &hex("40000037" ++ "00200014" ++ "41001836" ++ "0f270014" ++ "00000094" ++ "82ff03b4"), e.code.items[0..24]);
    try std.testing.expectEqualSlices(u8, &hex("e3fffb10"), e.code.items[32772..][0..4]); // adr x3, top
    // far: tbz x4, #63, +8 (the inverted tbnz); b top; ret
    try std.testing.expectEqualSlices(u8, &hex("4400f8b6" ++ "edd8ff17" ++ "c0035fd6"), e.code.items[40008..]);
    try std.testing.expectEqualDeep(&[_]Atom.Reloc{.init(16, .aarch64_branch26, 0, 0)}, e.refs.relocs.items);
}

test "atomics, bit ops, and other step-5 encodings match the system assembler" {
    const gpa = std.testing.allocator;
    var e: Encoder = .init(gpa);
    defer e.deinit();
    const chkstk: SymbolKey = .fromName("__chkstk_darwin");
    const table = try e.newLabel();
    const case = try e.newLabel();
    try e.ccmp(false, .x, .x1, .{ .imm = 5 }, 0b0100, .ne); // ccmp x1, #5, #4, ne
    try e.ccmp(true, .w, .x2, .{ .reg = .x3 }, 0, .lt); // ccmn w2, w3, #0, lt
    try e.bitOp(.rev, .w, .x0, .x1); // rev w0, w1
    try e.bitOp(.rev32, .x, .x0, .x1); // rev32 x0, x1
    try e.bitOp(.cls, .x, .x5, .x6); // cls x5, x6
    try e.cnt(.v0, .v0); // cnt v0.8b, v0.8b
    try e.addv(.v0, .v0); // addv b0, v0.8b
    try e.fma(.nmsub, .f64, .v0, .v1, .v2, .v3); // fnmsub d0, d1, d2, d3
    try e.fmovImm(.f32, .v4, fpImm(-0.125).?); // fmov s4, #-0.125
    try e.fmovImm(.f64, .v5, fpImm(31.0).?); // fmov d5, #31.0
    try e.cas(.byte, .acq_rel, .x0, .x1, .sp); // casalb w0, w1, [sp]
    try e.casp(.dword, .acquire, .x4, .x6, .x8); // caspa x4, x5, x6, x7, [x8]
    try e.atomic(.swp, .dword, .relaxed, .x1, .x2, .x3); // swp x1, x2, [x3]
    try e.atomic(.umin, .half, .release, .x1, .zr, .x3); // stuminlh w1, [x3]
    try e.ldar(.byte, .x0, .x1); // ldarb w0, [x1]
    try e.stlr(.dword, .zr, .sp); // stlr xzr, [sp]
    try e.dmb(.ish); // dmb ish
    try e.ldrQ(.v1, .at(.sp, 32)); // ldr q1, [sp, #32]
    try e.strQ(.v2, .at(.x0, 8)); // stur q2, [x0, #8]
    try e.stpQ(.v8, .v9, .{ .base = .sp, .offset = .{ .pre = -32 } }); // stp q8, q9, [sp, #-32]!
    try e.udf(0x1234); // udf #0x1234
    try e.carry(.adcs, .x, .x0, .x1, .zr); // adcs x0, x1, xzr
    try e.carry(.sbc, .w, .x2, .x3, .x4); // sbc w2, w3, w4
    try e.raw(System.isb); // isb
    try e.raw(System.dsb | (@as(u32, @backingInt(Barrier.ish)) << 8)); // dsb ish
    try e.raw(System.mrs_tpidrro_el0 | 3); // mrs x3, tpidrro_el0
    try e.raw(System.mrs("MIDR_EL1").? | 3); // mrs x3, MIDR_EL1
    try e.raw(System.mrs("id_aa64mmfr2_el1").? | 3); // mrs x3, ID_AA64MMFR2_EL1
    try e.raw(System.msr_tpidr_el0 | 5); // msr tpidr_el0, x5
    try e.ldaxr(.byte, .x9, .x12); // ldaxrb w9, [x12]
    try e.stlxr(.dword, .x17, .x11, .x12); // stlxr w17, x11, [x12]
    try e.ldaxp(.x10, .x11, .x12); // ldaxp x10, x11, [x12]
    try e.stlxp(.x7, .x2, .x3, .x12); // stlxp w7, x2, x3, [x12]
    try e.stackProbe(0x186b0, chkstk); // mov x9, #0x86b0; movk x9, #1, lsl #16; bl ___chkstk_darwin
    try e.adr(.x16, table); // adr x16, table
    e.bind(case);
    e.bind(table);
    try e.labelDelta(case, table); // .long case - table
    try e.finish();
    const want = hex("241845fa" ++ "40b0433a" ++ "2008c05a" ++ "2008c0da" ++ "c514c0da" ++ "0058200e" ++ "00b8310e" ++
        "208c621f" ++ "0410381e" ++ "05f0671e" ++ "e1ffe008" ++ "067d6448" ++ "628021f8" ++ "7f706178" ++ "20fcdf08" ++
        "ffff9fc8" ++ "bf3b03d5" ++ "e10bc03d" ++ "0280803c" ++ "e827bfad" ++ "34120000" ++ "20001fba" ++ "6200045a" ++ "df3f03d5" ++ "9f3b03d5" ++ "63d03bd5" ++ "030038d5" ++ "430738d5" ++ "45d01bd5" ++ "89fd5f08" ++ "8bfd11c8" ++ "8aad7fc8" ++ "828d27c8" ++ "09d690d2" ++ "2900a0f2" ++
        "00000094" ++ "30000010" ++ "00000000");
    try std.testing.expectEqualSlices(u8, &want, e.code.items);
    try std.testing.expectEqualDeep(&[_]Atom.Reloc{.init(0x8c, .aarch64_branch26, 0, 0)}, e.refs.relocs.items);
}

test "bitmask immediates" {
    try std.testing.expectEqual(null, bitmaskImm(.x, 0));
    try std.testing.expectEqual(null, bitmaskImm(.x, std.math.maxInt(u64)));
    try std.testing.expectEqual(null, bitmaskImm(.x, 0x1234));
    try std.testing.expectEqual(null, bitmaskImm(.w, 0x1_0000_0000));
    // and x0, x0, #0x1 / #0x8000000000000001 / #0xfffffffe00000000 / and w0, w0, #0x55555555
    try std.testing.expectEqual(BitmaskImm{ .n = 1, .immr = 0, .imms = 0 }, bitmaskImm(.x, 1).?);
    try std.testing.expectEqual(BitmaskImm{ .n = 1, .immr = 1, .imms = 1 }, bitmaskImm(.x, 0x8000000000000001).?);
    try std.testing.expectEqual(BitmaskImm{ .n = 1, .immr = 31, .imms = 30 }, bitmaskImm(.x, 0xfffffffe00000000).?);
    try std.testing.expectEqual(BitmaskImm{ .n = 0, .immr = 0, .imms = 0b111100 }, bitmaskImm(.w, 0x55555555).?);
}
