//! aarch64 inline assembly's instructions without a label operand: an
//! instruction and its operands as written, to the word upstream's
//! assembler (LLVM) gives, or an error where LLVM rejects the operands.
//! CodeGen's `asmInst` parses the statement, assembles the instructions
//! that branch or that the backend's Encoder already has (`mov`, `add`,
//! loads and stores, the logical instructions), and brings the rest here.

const std = @import("std");
const Atom = @import("../../link/Atom.zig");
const SymbolKey = Atom.SymbolKey;
const Encoder = @import("Encoder.zig");
const Reg = Encoder.Reg;
const VReg = Encoder.VReg;
const Cond = Encoder.Cond;

pub const Operand = union(enum) {
    reg: GpReg,
    imm: i64,
    sym: struct { key: SymbolKey, off: i32 },
    label: Encoder.Label,
    mem: Mem,
    /// A bare word: a barrier option, a system register, a cache
    /// operation, or a named label, by the instruction.
    name: []const u8,
    /// A SIMD register (`v3.16b`, `q3`, `%[name].4s`), with the width
    /// and the arrangement it is written with.
    vreg: struct { reg: VReg, kind: VKind = .v, arr: ?Arrangement },
    /// A list of consecutive SIMD registers (`{v3.16b}`).
    vlist: struct { first: VReg, len: u3, arr: ?Arrangement },
    /// One element of a SIMD register (`v3.d[1]`): its size as a power
    /// of two bytes and its index.
    velem: struct { reg: VReg, log2: u2, index: u8 },
    /// The shift or extension of the register before it (`lsl #2`,
    /// `uxtw`, `sxtw #3`), or of an immediate (`lsl #12`).
    modifier: struct { op: Modifier, amount: ?u8 },
};

/// A memory operand as written. An index register's shift amount is
/// checked against the access size once the instruction is known
/// (CodeGen's `asmMem`).
pub const Mem = struct { mem: Encoder.Mem, shift: ?u8 = null };

/// How a SIMD register is named: the whole vector (`v3`) or its low
/// bytes as a scalar (`q3`, `d3`, `s3`, `h3`, `b3`).
pub const VKind = enum {
    v,
    q,
    d,
    s,
    h,
    b,

    pub fn of(c: u8) ?VKind {
        return std.meta.stringToEnum(VKind, &.{std.ascii.toLower(c)});
    }

    /// The width a load or store of the register moves.
    pub fn size(k: VKind) ?Encoder.VSize {
        return switch (k) {
            .v => null,
            .q => .q,
            .d => .d,
            .s => .s,
            .h => .h,
            .b => .b,
        };
    }
};

/// A register operand's shift (lsl, lsr, asr, ror) or extension (the
/// rest), in Encoder.Shift's and Encoder.Extend's orders.
pub const Modifier = enum { lsl, lsr, asr, ror, uxtb, uxth, uxtw, uxtx, sxtb, sxth, sxtw, sxtx };

/// A vector register's arrangement suffix (`.16b`, `.4s`, ...).
pub const Arrangement = enum {
    @"8b",
    @"16b",
    @"4h",
    @"8h",
    @"2s",
    @"4s",
    @"1d",
    @"2d",
    @"1q",

    /// The Q bit of an instruction on whole vectors of this arrangement.
    pub fn q(a: Arrangement) u32 {
        return switch (a) {
            .@"8b", .@"4h", .@"2s", .@"1d" => 0,
            .@"16b", .@"8h", .@"4s", .@"2d", .@"1q" => 1,
        };
    }

    /// `16b` or `16B`.
    pub fn parse(s: []const u8) ?Arrangement {
        var buf: [3]u8 = undefined;
        if (s.len > buf.len) return null;
        return std.meta.stringToEnum(Arrangement, std.ascii.lowerString(&buf, s));
    }
};

/// A general register as written: its number and the width it is named with.
pub const GpReg = struct { reg: Reg, width: Encoder.Width };

/// One instruction being assembled: the CPU whose features say which
/// instructions exist, the statement for messages, and after
/// `error.AsmInvalid` the message.
pub const Asm = struct {
    cpu: *const std.Target.Cpu,
    line: []const u8,
    msg: []const u8 = "",
    buf: [512]u8 = undefined,

    pub const Error = error{
        /// bs does not assemble this form of the instruction.
        AsmUnsupported,
        /// Upstream's assembler rejects the operands; `msg` says why.
        AsmInvalid,
    };

    /// The word for `mnemonic` with `ops`, or null for an instruction
    /// that is not one of this file's.
    pub fn encode(a: *Asm, mnemonic: []const u8, ops: []const Operand) Error!?u32 {
        if (try a.neon(mnemonic, ops)) |w| return w;
        if (try a.structure(mnemonic, ops)) |w| return w;
        return a.scalar(mnemonic, ops);
    }

    fn fail(a: *Asm, comptime fmt: []const u8, args: anytype) Error {
        a.msg = std.fmt.bufPrint(&a.buf, fmt, args) catch &a.buf;
        return error.AsmInvalid;
    }

    fn badSp(a: *Asm) Error {
        return a.fail("inline assembly: sp is not a valid operand there (register 31 is zr in that position): '{s}'", .{a.line});
    }

    /// The condition `op` names (`eq`, `HS`, `cc`), in either case.
    fn condOf(op: Operand) ?Cond {
        if (op != .name or op.name.len != 2) return null;
        var buf: [2]u8 = undefined;
        const name = std.ascii.lowerString(&buf, op.name);
        if (std.mem.eql(u8, name, "cs")) return .hs;
        if (std.mem.eql(u8, name, "cc")) return .lo;
        return std.meta.stringToEnum(Cond, name);
    }

    /// The encoding of operand `i`, a general register of `width` where
    /// register 31 is zr.
    fn zrReg(a: *Asm, ops: []const Operand, i: usize, width: Encoder.Width) Error!u32 {
        if (i >= ops.len or ops[i] != .reg or ops[i].reg.width != width) return error.AsmUnsupported;
        if (ops[i].reg.reg == .sp) return a.badSp();
        return ops[i].reg.reg.zrEnc();
    }

    /// The integer instructions hand-written string routines (Arm's
    /// optimized-routines, which fastmem and libcs port) use beyond the ones
    /// `asmInst` reads: conditional select and its aliases, conditional
    /// compare, bit and byte reversal and leading-bit counts, the move-wide
    /// instructions, and a move between a general register and a SIMD one
    /// (`fmov x0, d1`, `umov`, `mov x0, v1.d[0]`). Encoded as upstream's
    /// assembler (LLVM) encodes them. Returns null for another instruction.
    fn scalar(a: *Asm, mnemonic: []const u8, ops: []const Operand) Error!?u32 {
        const eql = std.mem.eql;
        const sf = struct {
            fn bit(w: Encoder.Width) u32 {
                return if (w == .x) 1 << 31 else 0;
            }
        }.bit;
        // Which registers the instruction names: all three, the second twice
        // (`cinc`), or zr twice (`cset`).
        const Select = struct { []const u8, u32, enum { full, same, zr } };
        const selects = [_]Select{
            .{ "csel", 0x1A800000, .full },  .{ "csinc", 0x1A800400, .full }, .{ "csinv", 0x5A800000, .full },
            .{ "csneg", 0x5A800400, .full }, .{ "cinc", 0x1A800400, .same },  .{ "cinv", 0x5A800000, .same },
            .{ "cneg", 0x5A800400, .same },  .{ "cset", 0x1A800400, .zr },    .{ "csetm", 0x5A800000, .zr },
        };
        for (selects) |s| if (eql(u8, mnemonic, s[0])) {
            const count: usize = switch (s[2]) {
                .full => 4,
                .same => 3,
                .zr => 2,
            };
            if (ops.len != count or ops[0] != .reg) return error.AsmUnsupported;
            const w = ops[0].reg.width;
            const d = try a.zrReg(ops, 0, w);
            const n: u32 = if (s[2] == .zr) 31 else try a.zrReg(ops, 1, w);
            const m: u32 = if (s[2] == .full) try a.zrReg(ops, 2, w) else n;
            var cond = condOf(ops[count - 1]) orelse return error.AsmUnsupported;
            if (s[2] != .full) {
                // An alias selects on the inverse, which al and nv lack.
                if (cond == .al or cond == .nv) return a.fail("inline assembly: '{s}' takes no condition 'al' or 'nv': '{s}'", .{ mnemonic, a.line });
                cond = cond.negate();
            }
            return s[1] | sf(w) | m << 16 | @as(u32, @backingInt(cond)) << 12 | n << 5 | d;
        };
        if (eql(u8, mnemonic, "ccmp") or eql(u8, mnemonic, "ccmn")) {
            if (ops.len != 4 or ops[0] != .reg or ops[2] != .imm) return error.AsmUnsupported;
            const w = ops[0].reg.width;
            const n = try a.zrReg(ops, 0, w);
            const rhs: u32 = switch (ops[1]) {
                .imm => |v| if (v >= 0 and v <= 31) 1 << 11 | @as(u32, @intCast(v)) << 16 else return a.fail("inline assembly: '{s}' compares with a register or an immediate from 0 to 31: '{s}'", .{ mnemonic, a.line }),
                .reg => try a.zrReg(ops, 1, w) << 16,
                else => return error.AsmUnsupported,
            };
            if (ops[2].imm < 0 or ops[2].imm > 15) return a.fail("inline assembly: the flags '{s}' sets are 0 to 15: '{s}'", .{ mnemonic, a.line });
            const cond = condOf(ops[3]) orelse return error.AsmUnsupported;
            const base: u32 = if (mnemonic[3] == 'p') 0x7A400000 else 0x3A400000;
            return base | sf(w) | rhs | @as(u32, @backingInt(cond)) << 12 | n << 5 | @as(u32, @intCast(ops[2].imm));
        }
        const bit_ops = [_]struct { []const u8, u32 }{
            .{ "rbit", 0x5AC00000 },  .{ "rev16", 0x5AC00400 }, .{ "rev", 0x5AC00800 },
            .{ "rev32", 0x5AC00800 }, .{ "clz", 0x5AC01000 },   .{ "cls", 0x5AC01400 },
        };
        for (bit_ops) |b| if (eql(u8, mnemonic, b[0])) {
            if (ops.len != 2 or ops[0] != .reg) return error.AsmUnsupported;
            const w = ops[0].reg.width;
            const d = try a.zrReg(ops, 0, w);
            const n = try a.zrReg(ops, 1, w);
            // rev32 reverses the bytes of each word of an x register, and rev
            // of an x register is the next opcode.
            if (b[0].len == 5 and b[0][3] == '3' and w != .x) return error.AsmUnsupported;
            const rev64: u32 = if (b[0].len == 3 and b[0][2] == 'v' and w == .x) 0x400 else 0;
            return b[1] | rev64 | sf(w) | n << 5 | d;
        };
        const wides = [_]struct { []const u8, u32 }{ .{ "movn", 0x12800000 }, .{ "movz", 0x52800000 }, .{ "movk", 0x72800000 } };
        for (wides) |m| if (eql(u8, mnemonic, m[0])) {
            if (ops.len < 2 or ops.len > 3 or ops[0] != .reg or ops[1] != .imm) return error.AsmUnsupported;
            const w = ops[0].reg.width;
            const d = try a.zrReg(ops, 0, w);
            if (ops[1].imm < 0 or ops[1].imm > 0xffff) return a.fail("inline assembly: the immediate of '{s}' is 0 to 65535: '{s}'", .{ mnemonic, a.line });
            var shift: u32 = 0;
            if (ops.len == 3) {
                if (ops[2] != .modifier or ops[2].modifier.op != .lsl) return error.AsmUnsupported;
                shift = ops[2].modifier.amount orelse return error.AsmUnsupported;
                if (shift % 16 != 0 or shift >= w.bits()) return a.fail("inline assembly: '{s}' shifts its immediate left by 0{s}: '{s}'", .{ mnemonic, if (w == .x) ", 16, 32 or 48" else " or 16", a.line });
            }
            return m[1] | sf(w) | shift / 16 << 21 | @as(u32, @intCast(ops[1].imm)) << 5 | d;
        };
        if (eql(u8, mnemonic, "fmov")) {
            // Between a w register and an s one, or an x and a d: the bits.
            if (ops.len != 2) return error.AsmUnsupported;
            const to_gp = ops[0] == .reg;
            const g: usize = if (to_gp) 0 else 1;
            if (ops[g] != .reg or ops[1 - g] != .vreg) return error.AsmUnsupported;
            const v = ops[1 - g].vreg;
            const w = ops[g].reg.width;
            if (v.arr != null or v.kind != @as(VKind, if (w == .x) .d else .s)) return error.AsmUnsupported;
            const r = try a.zrReg(ops, g, w);
            const vr: u32 = @backingInt(v.reg);
            const base: u32 = if (w == .x) 0x9E660000 else 0x1E260000;
            return if (to_gp) base | vr << 5 | r else base | 1 << 16 | r << 5 | vr;
        }
        if ((eql(u8, mnemonic, "mov") or eql(u8, mnemonic, "umov")) and ops.len == 2 and ops[0] == .reg and ops[1] == .velem) {
            // An element to a general register, zero-extended: a d element
            // to an x register, the others to a w one. `mov` names the two
            // that fill their register.
            const el = ops[1].velem;
            const w = ops[0].reg.width;
            if ((w == .x) != (el.log2 == 3) or (mnemonic.len == 3 and el.log2 < 2)) return error.AsmUnsupported;
            const d = try a.zrReg(ops, 0, w);
            if (el.index >= @as(u8, 16) >> el.log2) return a.fail("inline assembly: the element index is 0 to {d}: '{s}'", .{ (@as(u8, 16) >> el.log2) - 1, a.line });
            const imm5 = @as(u32, el.index) << (@as(u5, el.log2) + 1) | @as(u32, 1) << el.log2;
            const q: u32 = @intFromBool(w == .x);
            return 0x0E003C00 | q << 30 | imm5 << 16 | @as(u32, @backingInt(el.reg)) << 5 | d;
        }
        return null;
    }

    /// `ld1` and `st1` of one to four whole SIMD registers (`ld1 {v0.16b,
    /// v1.16b}, [x1], #32`): at the base register, optionally adding the
    /// bytes moved or an x register to it afterwards. Returns false for
    /// another instruction.
    fn structure(a: *Asm, mnemonic_in: []const u8, ops: []const Operand) Error!?u32 {
        const dot = std.mem.findScalar(u8, mnemonic_in, '.') orelse mnemonic_in.len;
        const mnemonic = mnemonic_in[0..dot];
        const is_load = std.mem.eql(u8, mnemonic, "ld1");
        if (!is_load and !std.mem.eql(u8, mnemonic, "st1")) return null;
        if (ops.len < 2 or ops.len > 3 or ops[0] != .vlist or ops[1] != .mem) return error.AsmUnsupported;
        const list = ops[0].vlist;
        const suffix: ?Arrangement = if (dot == mnemonic_in.len) null else Arrangement.parse(mnemonic_in[dot + 1 ..]) orelse return error.AsmUnsupported;
        const arr = list.arr orelse suffix orelse return error.AsmUnsupported;
        const size: u32 = switch (arr) {
            .@"8b", .@"16b" => 0,
            .@"4h", .@"8h" => 1,
            .@"2s", .@"4s" => 2,
            .@"1d", .@"2d" => 3,
            .@"1q" => return error.AsmUnsupported,
        };
        const opcode: u32 = switch (list.len) {
            1 => 0b0111,
            2 => 0b1010,
            3 => 0b0110,
            4 => 0b0010,
            else => unreachable,
        };
        const mem = ops[1].mem.mem;
        const bytes = @as(i32, list.len) * (@as(i32, 8) << @intCast(arr.q()));
        // The post-index field: 31 for the bytes moved, else the register.
        var post: ?u32 = null;
        if (ops.len == 3) {
            if (mem.offset != .imm or mem.offset.imm != 0) return error.AsmUnsupported;
            // xzr is register 31, the immediate form, as LLVM takes it.
            post = try a.zrReg(ops, 2, .x);
        } else switch (mem.offset) {
            .imm => |v| if (v != 0) return a.fail("inline assembly: '{s}' takes no offset: '{s}'", .{ mnemonic, a.line }),
            .post => |v| {
                if (v != bytes) return a.fail("inline assembly: the post-index immediate is the bytes moved, #{d}: '{s}'", .{ bytes, a.line });
                post = 31;
            },
            else => return error.AsmUnsupported,
        }
        const indexed: u32 = if (post) |m| 0x0C800000 | m << 16 else 0x0C000000;
        return indexed | arr.q() << 30 | @as(u32, @intFromBool(is_load)) << 22 | opcode << 12 | size << 10 | mem.base.spEnc() << 5 | @as(u32, @backingInt(list.first));
    }

    /// The NEON instructions on whole vectors whose encoding has the element
    /// size, as string routines use them to compare and reduce 16 bytes at a
    /// time: integer add, sub, compares (with a register or `#0`), pairwise
    /// add, maximum and minimum, and `shrn`, a narrowing shift right. Returns
    /// false for an instruction that is not one of them.
    fn neonSized(a: *Asm, mnemonic: []const u8, suffix: ?Arrangement, ops: []const Operand) Error!?u32 {
        const eql = std.mem.eql;
        // The encoding with two registers, the one with a register and `#0`,
        // each zero where there is none, and whether doublewords are elements.
        const Insn = struct { name: []const u8, reg: u32 = 0, zero: u32 = 0, d: bool = true };
        const table = [_]Insn{
            .{ .name = "add", .reg = 0x0E208400 },
            .{ .name = "sub", .reg = 0x2E208400 },
            .{ .name = "addp", .reg = 0x0E20BC00 },
            .{ .name = "cmeq", .reg = 0x2E208C00, .zero = 0x0E209800 },
            .{ .name = "cmge", .reg = 0x0E203C00, .zero = 0x2E208800 },
            .{ .name = "cmgt", .reg = 0x0E203400, .zero = 0x0E208800 },
            .{ .name = "cmle", .zero = 0x2E209800 },
            .{ .name = "cmlt", .zero = 0x0E20A800 },
            .{ .name = "cmhi", .reg = 0x2E203400 },
            .{ .name = "cmhs", .reg = 0x2E203C00 },
            .{ .name = "cmtst", .reg = 0x0E208C00 },
            .{ .name = "smax", .reg = 0x0E206400, .d = false },
            .{ .name = "umax", .reg = 0x2E206400, .d = false },
            .{ .name = "smin", .reg = 0x0E206C00, .d = false },
            .{ .name = "umin", .reg = 0x2E206C00, .d = false },
            .{ .name = "smaxp", .reg = 0x0E20A400, .d = false },
            .{ .name = "umaxp", .reg = 0x2E20A400, .d = false },
            .{ .name = "sminp", .reg = 0x0E20AC00, .d = false },
            .{ .name = "uminp", .reg = 0x2E20AC00, .d = false },
        };
        const d = ops[0].vreg;
        // A whole-vector operand of arrangement `arr`, which Apple's syntax
        // leaves to the mnemonic.
        const vec = struct {
            fn at(o: []const Operand, k: usize, arr: Arrangement) ?u32 {
                if (k >= o.len or o[k] != .vreg) return null;
                const v = o[k].vreg;
                return if (v.kind == .v and (v.arr orelse arr) == arr) @backingInt(v.reg) else null;
            }
        }.at;
        const rd: u32 = @backingInt(d.reg);
        if (eql(u8, mnemonic, "shrn") or eql(u8, mnemonic, "shrn2")) {
            // To elements of half the size: `shrn` fills the low half of the
            // result, `shrn2` the high half.
            const high = mnemonic.len == 5;
            const arr = d.arr orelse suffix orelse return error.AsmUnsupported;
            const narrow: struct { u32, Arrangement } = switch (arr) {
                .@"8b", .@"16b" => .{ 8, .@"8h" },
                .@"4h", .@"8h" => .{ 16, .@"4s" },
                .@"2s", .@"4s" => .{ 32, .@"2d" },
                else => return error.AsmUnsupported,
            };
            if (d.kind != .v or ops.len != 3 or ops[2] != .imm or (arr.q() == 1) != high) return error.AsmUnsupported;
            const rn = vec(ops, 1, if (suffix != null and d.arr == null) arr else narrow[1]) orelse return error.AsmUnsupported;
            if (ops[2].imm < 1 or ops[2].imm > narrow[0]) return a.fail("inline assembly: '{s}' shifts right by 1 to {d} here: '{s}'", .{ mnemonic, narrow[0], a.line });
            const immhb = 2 * narrow[0] - @as(u32, @intCast(ops[2].imm));
            return 0x0F008400 | arr.q() << 30 | immhb << 16 | rn << 5 | rd;
        }
        const insn = for (table) |t| {
            if (eql(u8, t.name, mnemonic)) break t;
        } else return null;
        const arr = d.arr orelse suffix orelse return error.AsmUnsupported;
        const size: u32 = switch (arr) {
            .@"8b", .@"16b" => 0,
            .@"4h", .@"8h" => 1,
            .@"2s", .@"4s" => 2,
            .@"2d" => if (insn.d) 3 else return error.AsmUnsupported,
            .@"1d", .@"1q" => return error.AsmUnsupported,
        };
        if (d.kind != .v or ops.len != 3) return error.AsmUnsupported;
        const rn = vec(ops, 1, arr) orelse return error.AsmUnsupported;
        const fixed = arr.q() << 30 | size << 22 | rn << 5 | rd;
        if (ops[2] == .imm) {
            if (insn.zero == 0) return error.AsmUnsupported;
            if (ops[2].imm != 0) return a.fail("inline assembly: '{s}' compares with a register or #0: '{s}'", .{ mnemonic, a.line });
            return insn.zero | fixed;
        }
        const rm = vec(ops, 2, arr) orelse return error.AsmUnsupported;
        if (insn.reg == 0) return error.AsmUnsupported;
        return insn.reg | fixed | rm << 16;
    }

    /// The NEON instructions std's crypto uses on whole vectors, in the
    /// standard syntax (`eor v0.16b, v1.16b, v2.16b`) and Apple's
    /// (`sha256su0.4s v0, v1`, the arrangement on the mnemonic). Returns null
    /// for an instruction that is not one of them.
    fn neon(a: *Asm, mnemonic_in: []const u8, ops: []const Operand) Error!?u32 {
        if (ops.len == 0 or ops[0] != .vreg) return null;
        const dot = std.mem.findScalar(u8, mnemonic_in, '.') orelse mnemonic_in.len;
        const mnemonic = mnemonic_in[0..dot];
        const suffix: ?Arrangement = if (dot == mnemonic_in.len) null else Arrangement.parse(mnemonic_in[dot + 1 ..]) orelse return error.AsmUnsupported;
        const Shape = enum { two, three, ext, tbl, movi, dup };
        const Insn = struct { []const u8, Shape, u32 };
        // Base encodings with Q clear (or fixed) and the registers zero.
        const table = [_]Insn{
            .{ "mov", .two, 0x0EA01C00 }, // orr Vd, Vn, Vn
            .{ "aese", .two, 0x4E284800 },
            .{ "aesd", .two, 0x4E285800 },
            .{ "aesmc", .two, 0x4E286800 },
            .{ "aesimc", .two, 0x4E287800 },
            .{ "sha256su0", .two, 0x5E282800 },
            .{ "eor", .three, 0x2E201C00 },
            .{ "and", .three, 0x0E201C00 },
            .{ "orr", .three, 0x0EA01C00 },
            .{ "bic", .three, 0x0E601C00 },
            .{ "orn", .three, 0x0EE01C00 },
            .{ "bsl", .three, 0x2E601C00 },
            .{ "bit", .three, 0x2EA01C00 },
            .{ "bif", .three, 0x2EE01C00 },
            .{ "pmull", .three, 0x0E20E000 }, // Vd.1q, Vn.1d, Vm.1d or Vd.8h, Vn.8b, Vm.8b
            .{ "pmull2", .three, 0x4E20E000 }, // Vd.1q, Vn.2d, Vm.2d or Vd.8h, Vn.16b, Vm.16b
            .{ "sha256h", .three, 0x5E004000 },
            .{ "sha256h2", .three, 0x5E005000 },
            .{ "sha256su1", .three, 0x5E006000 },
            .{ "ext", .ext, 0x2E000000 },
            .{ "tbl", .tbl, 0x0E000000 },
            .{ "movi", .movi, 0x0F000400 },
            .{ "dup", .dup, 0x0E000C00 }, // Vd.T, Wn or Xn
        };
        const insn = for (table) |t| {
            if (std.mem.eql(u8, t[0], mnemonic)) break t;
        } else return a.neonSized(mnemonic, suffix, ops);
        const d = ops[0].vreg;
        const arr = d.arr orelse suffix;
        const pmull = std.mem.startsWith(u8, mnemonic, "pmull");
        // The Q bit of the instructions whose encoding above leaves it clear.
        const q: u32 = switch (insn[2] >> 30 & 1) {
            0 => if (pmull) 0 else (arr orelse return error.AsmUnsupported).q(),
            else => 0,
        };
        // pmull's size field is its result's: polynomials of 64 bits (`.1q`)
        // or of 8 (`.8h`).
        const pmull_size: u32 = if (!pmull) 0 else switch (arr orelse return error.AsmUnsupported) {
            .@"1q" => 0b11 << 22,
            .@"8h" => 0,
            else => return error.AsmUnsupported,
        };
        // The crypto instructions need their CPU feature, as `crc32` does;
        // `pmull` on bytes is plain NEON.
        const feature: ?std.Target.aarch64.Feature = if (std.mem.startsWith(u8, mnemonic, "aes") or pmull_size != 0) .aes else if (std.mem.startsWith(u8, mnemonic, "sha256")) .sha2 else null;
        if (feature) |f| if (!a.cpu.has(.aarch64, f))
            return a.fail("inline assembly instruction '{s}' needs the target CPU feature '{t}', as upstream's assembler does", .{ a.line, f });
        const v = struct {
            fn at(o: []const Operand, k: usize) ?u32 {
                return if (k < o.len and o[k] == .vreg) @backingInt(o[k].vreg.reg) else null;
            }
        }.at;
        const rd: u32 = @backingInt(d.reg);
        const word: u32 = switch (insn[1]) {
            .two => w: {
                const rn = v(ops, 1) orelse return error.AsmUnsupported;
                if (ops.len != 2) return error.AsmUnsupported;
                const rm: u32 = if (std.mem.eql(u8, mnemonic, "mov")) rn << 16 else 0;
                break :w insn[2] | q << 30 | rm | rn << 5 | rd;
            },
            .three => w: {
                const rn = v(ops, 1) orelse return error.AsmUnsupported;
                const rm = v(ops, 2) orelse return error.AsmUnsupported;
                if (ops.len != 3) return error.AsmUnsupported;
                break :w insn[2] | pmull_size | q << 30 | rm << 16 | rn << 5 | rd;
            },
            .ext => w: {
                const rn = v(ops, 1) orelse return error.AsmUnsupported;
                const rm = v(ops, 2) orelse return error.AsmUnsupported;
                if (ops.len != 4 or ops[3] != .imm or ops[3].imm < 0 or ops[3].imm > (@as(i64, 8) << @intCast(q)) - 1) return error.AsmUnsupported;
                break :w insn[2] | q << 30 | rm << 16 | @as(u32, @intCast(ops[3].imm)) << 11 | rn << 5 | rd;
            },
            .tbl => w: {
                if (ops.len != 3 or ops[1] != .vlist) return error.AsmUnsupported;
                const rm = v(ops, 2) orelse return error.AsmUnsupported;
                const l = ops[1].vlist;
                break :w insn[2] | q << 30 | rm << 16 | @as(u32, l.len - 1) << 13 | @as(u32, @backingInt(l.first)) << 5 | rd;
            },
            .movi => w: {
                // An 8-bit immediate in each byte (`.16b`, `.8b`) or each
                // word, unshifted (`.4s`, `.2s`).
                if (ops.len != 2 or ops[1] != .imm or ops[1].imm < 0 or ops[1].imm > 255) return error.AsmUnsupported;
                const cmode: u32 = switch (arr.?) {
                    .@"8b", .@"16b" => 0b1110,
                    .@"2s", .@"4s" => 0b0000,
                    else => return error.AsmUnsupported,
                };
                const imm: u32 = @intCast(ops[1].imm);
                break :w insn[2] | q << 30 | (imm >> 5) << 16 | cmode << 12 | (imm & 31) << 5 | rd;
            },
            .dup => w: {
                // Every element from a general register: an x register for
                // `.2d`, else a w register.
                if (ops.len != 2 or ops[1] != .reg) return error.AsmUnsupported;
                const r = ops[1].reg;
                const imm5: u32 = switch (arr.?) {
                    .@"8b", .@"16b" => 0b00001,
                    .@"4h", .@"8h" => 0b00010,
                    .@"2s", .@"4s" => 0b00100,
                    .@"2d" => 0b01000,
                    .@"1d", .@"1q" => return error.AsmUnsupported,
                };
                if (r.reg == .sp or r.width != (if (imm5 == 0b01000) Encoder.Width.x else Encoder.Width.w)) return error.AsmUnsupported;
                break :w insn[2] | q << 30 | imm5 << 16 | r.reg.zrEnc() << 5 | rd;
            },
        };
        return word;
    }
};
