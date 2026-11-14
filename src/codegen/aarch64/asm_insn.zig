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
const Width = Encoder.Width;
const Feature = std.Target.aarch64.Feature;

/// The sf bit of an instruction on registers of width `w`.
fn sfBit(w: Width) u32 {
    return @as(u32, @backingInt(w)) << 31;
}

pub const Operand = union(enum) {
    reg: GpReg,
    imm: i64,
    /// An immediate written with a fraction or an exponent (`#0.0`,
    /// `#-1.25`, `#1e1`), which LLVM tells from an integer.
    fimm: f64,
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
pub const Mem = struct {
    mem: Encoder.Mem,
    shift: ?u8 = null,
    /// `[x1, #0]`, where some instructions take `[x1]` only.
    offset_written: bool = false,
};

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
pub const GpReg = struct { reg: Reg, width: Width };

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
        if (try a.scalar(mnemonic, ops)) |w| return w;
        if (try a.integer(mnemonic, ops)) |w| return w;
        if (try a.float(mnemonic, ops)) |w| return w;
        if (try a.atomic(mnemonic, ops)) |w| return w;
        return a.memory(mnemonic, ops);
    }

    fn fail(a: *Asm, comptime fmt: []const u8, args: anytype) Error {
        a.msg = std.mem.print(&a.buf, fmt, args) catch &a.buf;
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
    fn zrReg(a: *Asm, ops: []const Operand, i: usize, width: Width) Error!u32 {
        if (i >= ops.len or ops[i] != .reg or ops[i].reg.width != width) return error.AsmUnsupported;
        if (ops[i].reg.reg == .sp) return a.badSp();
        return ops[i].reg.reg.zrEnc();
    }

    /// The integer instructions hand-written string routines (Arm's
    /// optimized-routines, which fastmem and libcs port) use beyond the ones
    /// `asmInst` reads: conditional select and its aliases, conditional
    /// compare, bit and byte reversal and leading-bit counts, the move-wide
    /// instructions, and a move of a SIMD register's element to a general
    /// register (`umov`, `mov x0, v1.d[0]`). Encoded as upstream's
    /// assembler (LLVM) encodes them. Returns null for another instruction.
    fn scalar(a: *Asm, mnemonic: []const u8, ops: []const Operand) Error!?u32 {
        const eql = std.mem.eql;
        const sf = struct {
            fn bit(w: Width) u32 {
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
        const feature: ?Feature = if (std.mem.startsWith(u8, mnemonic, "aes") or pmull_size != 0) .aes else if (std.mem.startsWith(u8, mnemonic, "sha256")) .sha2 else null;
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
                if (r.reg == .sp or r.width != (if (imm5 == 0b01000) Width.x else Width.w)) return error.AsmUnsupported;
                break :w insn[2] | q << 30 | imm5 << 16 | r.reg.zrEnc() << 5 | rd;
            },
        };
        return word;
    }

    fn needs(a: *Asm, feature: Feature) Error {
        return a.fail("inline assembly instruction '{s}' needs the target CPU feature '{t}', as upstream's assembler does", .{ a.line, feature });
    }

    /// Operand `i`, an immediate from `lo` to `hi`, neither negative, which
    /// `what` names in the error.
    fn immIn(a: *Asm, ops: []const Operand, i: usize, lo: u32, hi: u32, what: []const u8) Error!u32 {
        if (i >= ops.len or ops[i] != .imm) return error.AsmUnsupported;
        const v = ops[i].imm;
        if (v < lo or v > hi) return a.fail("inline assembly: {s} is {d} to {d}: '{s}'", .{ what, lo, hi, a.line });
        return @intCast(v);
    }

    /// The base register of operand `i`, a memory operand without an
    /// offset: `[x1]`, and unless `bare`, `[x1, #0]`.
    fn baseOnly(ops: []const Operand, i: usize, bare: bool) Error!u32 {
        if (i >= ops.len or ops[i] != .mem) return error.AsmUnsupported;
        const m = ops[i].mem.mem;
        if (m.offset != .imm or m.offset.imm != 0 or (bare and ops[i].mem.offset_written)) return error.AsmUnsupported;
        return m.base.spEnc();
    }

    /// Multiply, divide, shifts by a register, add and subtract with
    /// carry, the bitfield moves and their aliases, and `extr`.
    fn integer(a: *Asm, mnemonic: []const u8, ops: []const Operand) Error!?u32 {
        if (ops.len == 0 or ops[0] != .reg) return null;
        const eql = std.mem.eql;
        const w = ops[0].reg.width;
        // The operands: registers of one width (d, n, m; d and m; d, n, m
        // and a), or an x result of w registers (with an x addend), or x
        // registers only.
        const Form = enum { rrr, rm, rrrr, long, long_add, high };
        const table = [_]struct { []const u8, u32, Form }{
            .{ "udiv", 0x1AC00800, .rrr },        .{ "sdiv", 0x1AC00C00, .rrr },        .{ "lslv", 0x1AC02000, .rrr },
            .{ "lsrv", 0x1AC02400, .rrr },        .{ "asrv", 0x1AC02800, .rrr },        .{ "rorv", 0x1AC02C00, .rrr },
            .{ "adc", 0x1A000000, .rrr },         .{ "adcs", 0x3A000000, .rrr },        .{ "sbc", 0x5A000000, .rrr },
            .{ "sbcs", 0x7A000000, .rrr },        .{ "mul", 0x1B007C00, .rrr },         .{ "mneg", 0x1B00FC00, .rrr },
            .{ "ngc", 0x5A0003E0, .rm },          .{ "ngcs", 0x7A0003E0, .rm },         .{ "madd", 0x1B000000, .rrrr },
            .{ "msub", 0x1B008000, .rrrr },       .{ "smaddl", 0x9B200000, .long_add }, .{ "smsubl", 0x9B208000, .long_add },
            .{ "umaddl", 0x9BA00000, .long_add }, .{ "umsubl", 0x9BA08000, .long_add }, .{ "smull", 0x9B207C00, .long },
            .{ "smnegl", 0x9B20FC00, .long },     .{ "umull", 0x9BA07C00, .long },      .{ "umnegl", 0x9BA0FC00, .long },
            .{ "smulh", 0x9B407C00, .high },      .{ "umulh", 0x9BC07C00, .high },
        };
        for (table) |t| if (eql(u8, mnemonic, t[0])) {
            const count: usize = switch (t[2]) {
                .rm => 2,
                .rrr, .long, .high => 3,
                .rrrr, .long_add => 4,
            };
            if (ops.len != count) return error.AsmUnsupported;
            return switch (t[2]) {
                .rrr => t[1] | sfBit(w) | try a.zrReg(ops, 2, w) << 16 | try a.zrReg(ops, 1, w) << 5 | try a.zrReg(ops, 0, w),
                .rm => t[1] | sfBit(w) | try a.zrReg(ops, 1, w) << 16 | try a.zrReg(ops, 0, w),
                .rrrr => t[1] | sfBit(w) | try a.zrReg(ops, 2, w) << 16 | try a.zrReg(ops, 3, w) << 10 | try a.zrReg(ops, 1, w) << 5 | try a.zrReg(ops, 0, w),
                .long => t[1] | try a.zrReg(ops, 2, .w) << 16 | try a.zrReg(ops, 1, .w) << 5 | try a.zrReg(ops, 0, .x),
                .long_add => t[1] | try a.zrReg(ops, 2, .w) << 16 | try a.zrReg(ops, 3, .x) << 10 | try a.zrReg(ops, 1, .w) << 5 | try a.zrReg(ops, 0, .x),
                .high => t[1] | try a.zrReg(ops, 2, .x) << 16 | try a.zrReg(ops, 1, .x) << 5 | try a.zrReg(ops, 0, .x),
            };
        };
        // A bitfield move as written (immr, imms), or by the field's least
        // significant bit and width: out of the source (`ubfx`), into the
        // destination (`ubfiz`), or zeros into it (`bfc`).
        const Field = enum { raw, extract, insert, clear };
        const fields = [_]struct { []const u8, u32, Field }{
            .{ "sbfm", 0x13000000, .raw },     .{ "bfm", 0x33000000, .raw },       .{ "ubfm", 0x53000000, .raw },
            .{ "sbfx", 0x13000000, .extract }, .{ "bfxil", 0x33000000, .extract }, .{ "ubfx", 0x53000000, .extract },
            .{ "sbfiz", 0x13000000, .insert }, .{ "bfi", 0x33000000, .insert },    .{ "ubfiz", 0x53000000, .insert },
            .{ "bfc", 0x33000000, .clear },
        };
        for (fields) |f| if (eql(u8, mnemonic, f[0])) {
            const bits: u32 = w.bits();
            const k: usize = if (f[2] == .clear) 1 else 2;
            if (ops.len != k + 2) return error.AsmUnsupported;
            const d = try a.zrReg(ops, 0, w);
            const n: u32 = if (f[2] == .clear) 31 else try a.zrReg(ops, 1, w);
            const first = try a.immIn(ops, k, 0, bits - 1, if (f[2] == .raw) "the first immediate" else "the field's least significant bit");
            const second = if (f[2] == .raw) try a.immIn(ops, k + 1, 0, bits - 1, "the second immediate") else try a.immIn(ops, k + 1, 1, bits - first, "the field's width here");
            const immr, const imms = switch (f[2]) {
                .raw => .{ first, second },
                .extract => .{ first, first + second - 1 },
                .insert, .clear => .{ (bits - first) % bits, second - 1 },
            };
            return f[1] | sfBit(w) | @as(u32, @backingInt(w)) << 22 | immr << 16 | imms << 10 | n << 5 | d;
        };
        if (eql(u8, mnemonic, "extr")) {
            if (ops.len != 4) return error.AsmUnsupported;
            const lsb = try a.immIn(ops, 3, 0, w.bits() - 1, "the least significant bit");
            return 0x13800000 | sfBit(w) | @as(u32, @backingInt(w)) << 22 | try a.zrReg(ops, 2, w) << 16 | lsb << 10 | try a.zrReg(ops, 1, w) << 5 | try a.zrReg(ops, 0, w);
        }
        return null;
    }

    /// The type field of operand `i`, a scalar floating-point register
    /// (`s3`, `d3`, `h3`), or null for another operand.
    fn fpType(ops: []const Operand, i: usize) ?u32 {
        if (i >= ops.len or ops[i] != .vreg or ops[i].vreg.arr != null) return null;
        return switch (ops[i].vreg.kind) {
            .s => 0,
            .d => 1,
            .h => 3,
            .v, .q, .b => null,
        };
    }

    /// The number of operand `i`, a SIMD register.
    fn vNum(ops: []const Operand, i: usize) u32 {
        return @backingInt(ops[i].vreg.reg);
    }

    /// The eight bits that encode `v` in `fmov` with an immediate: plus or
    /// minus 16 to 31 sixteenths times a power of two from 1/8 to 16.
    fn fpImm8(v: f64) ?u32 {
        const bits: u64 = @bitCast(v);
        const exp = @as(i32, @intCast(bits >> 52 & 0x7ff)) - 1023;
        if (bits & 0xffff_ffff_ffff != 0 or exp < -3 or exp > 4) return null;
        const e: u32 = @intCast(exp + 3);
        return @as(u32, @intCast(bits >> 63)) << 7 | (~e & 4) << 4 | (e & 3) << 4 | @as(u32, @intCast(bits >> 48 & 15));
    }

    /// The scalar floating-point instructions on s and d registers, and
    /// with the CPU's `fullfp16` feature h ones: arithmetic, rounding,
    /// compares, selects, `fmov` in its forms, and conversions between
    /// the types and to and from the general registers. Returns null for
    /// another instruction, as for the SIMD forms of these mnemonics
    /// (`fabs v0.2d, v1.2d`, `scvtf d0, d1`).
    fn float(a: *Asm, mnemonic: []const u8, ops: []const Operand) Error!?u32 {
        if (ops.len < 2) return null;
        const high_half = std.mem.eql(u8, mnemonic, "fmov") and (ops[0] == .velem or ops[1] == .velem);
        if (fpType(ops, 0) == null and fpType(ops, 1) == null and !high_half) return null;
        const word = try a.floatWord(mnemonic, ops) orelse return null;
        if (!a.cpu.has(.aarch64, .fp_armv8)) return a.needs(.fp_armv8);
        // Half precision is the `fullfp16` feature's, but for converting
        // it to and from the other two.
        if (std.mem.eql(u8, mnemonic, "fcvt")) return word;
        for (ops, 0..) |_, i| if (fpType(ops, i) == 3 and !a.cpu.has(.aarch64, .fullfp16)) return a.needs(.fullfp16);
        return word;
    }

    fn floatWord(a: *Asm, mnemonic: []const u8, ops: []const Operand) Error!?u32 {
        const eql = std.mem.eql;
        const t0 = fpType(ops, 0);
        const t1 = fpType(ops, 1);
        // How many of the first operands are registers of the first's type.
        var same: usize = 0;
        if (t0 != null) for (ops, 0..) |_, i| {
            if (fpType(ops, i) != t0) break;
            same = i + 1;
        };
        const condition: ?u32 = if (condOf(ops[ops.len - 1])) |c| @backingInt(c) else null;
        if (same == 3 and ops.len == 3) {
            const binary = [_][]const u8{ "fmul", "fdiv", "fadd", "fsub", "fmax", "fmin", "fmaxnm", "fminnm", "fnmul" };
            for (binary, 0..) |name, op| if (eql(u8, mnemonic, name))
                return 0x1E200800 | t0.? << 22 | vNum(ops, 2) << 16 | @as(u32, @intCast(op)) << 12 | vNum(ops, 1) << 5 | vNum(ops, 0);
        }
        if (same == 2 and ops.len == 2) {
            const unary = [_]struct { []const u8, u32, ?Feature }{
                .{ "fmov", 0, null },          .{ "fabs", 1, null },          .{ "fneg", 2, null },          .{ "fsqrt", 3, null },
                .{ "frintn", 8, null },        .{ "frintp", 9, null },        .{ "frintm", 10, null },       .{ "frintz", 11, null },
                .{ "frinta", 12, null },       .{ "frintx", 14, null },       .{ "frinti", 15, null },       .{ "frint32z", 16, .fptoint },
                .{ "frint32x", 17, .fptoint }, .{ "frint64z", 18, .fptoint }, .{ "frint64x", 19, .fptoint },
            };
            for (unary) |u| if (eql(u8, mnemonic, u[0])) {
                if (u[2]) |f| {
                    if (t0.? == 3) return null;
                    if (!a.cpu.has(.aarch64, f)) return a.needs(f);
                }
                return 0x1E204000 | t0.? << 22 | u[1] << 15 | vNum(ops, 1) << 5 | vNum(ops, 0);
            };
            if (eql(u8, mnemonic, "fcmp") or eql(u8, mnemonic, "fcmpe"))
                return 0x1E202000 | t0.? << 22 | vNum(ops, 1) << 16 | vNum(ops, 0) << 5 | @as(u32, @intFromBool(mnemonic.len == 5)) << 4;
        }
        if (same == 1 and ops.len == 2 and t1 != null and eql(u8, mnemonic, "fcvt")) {
            // To single, double and half precision.
            const op: u32 = switch (t0.?) {
                0 => 4,
                1 => 5,
                else => 7,
            };
            return 0x1E204000 | t1.? << 22 | op << 15 | vNum(ops, 1) << 5 | vNum(ops, 0);
        }
        if (same == 1 and ops.len == 2 and ops[1] == .fimm and (eql(u8, mnemonic, "fcmp") or eql(u8, mnemonic, "fcmpe"))) {
            // LLVM reads `0.` and what follows it only.
            if (@as(u64, @bitCast(ops[1].fimm)) != 0 or !std.mem.startsWith(u8, a.lastImm(), "0.")) return a.fail("inline assembly: '{s}' compares with a register or #0.0: '{s}'", .{ mnemonic, a.line });
            return 0x1E202008 | t0.? << 22 | vNum(ops, 0) << 5 | @as(u32, @intFromBool(mnemonic.len == 5)) << 4;
        }
        if (same == 4 and ops.len == 4) {
            const fused = [_][]const u8{ "fmadd", "fmsub", "fnmadd", "fnmsub" };
            for (fused, 0..) |name, k| if (eql(u8, mnemonic, name)) {
                const op: u32 = @intCast(k);
                return 0x1F000000 | t0.? << 22 | (op >> 1) << 21 | vNum(ops, 2) << 16 | (op & 1) << 15 | vNum(ops, 3) << 10 | vNum(ops, 1) << 5 | vNum(ops, 0);
            };
        }
        if (same == 2 and ops.len == 4 and (eql(u8, mnemonic, "fccmp") or eql(u8, mnemonic, "fccmpe"))) {
            const flags = try a.immIn(ops, 2, 0, 15, "the flags");
            const cond = condition orelse return null;
            return 0x1E200400 | t0.? << 22 | vNum(ops, 1) << 16 | cond << 12 | vNum(ops, 0) << 5 | @as(u32, @intFromBool(mnemonic.len == 6)) << 4 | flags;
        }
        if (same == 3 and ops.len == 4 and eql(u8, mnemonic, "fcsel")) {
            const cond = condition orelse return null;
            return 0x1E200C00 | t0.? << 22 | vNum(ops, 2) << 16 | cond << 12 | vNum(ops, 1) << 5 | vNum(ops, 0);
        }
        if (eql(u8, mnemonic, "fmov") and ops.len == 2) return a.fmov(ops);
        // Conversions to and from a general register: an integer, or with
        // a third operand a fixed-point number of that many fraction bits.
        const from_int = eql(u8, mnemonic, "scvtf") or eql(u8, mnemonic, "ucvtf");
        const convert: ?u32 = if (from_int)
            @as(u32, if (mnemonic[0] == 's') 2 else 3)
        else if (mnemonic.len == 6 and std.mem.startsWith(u8, mnemonic, "fcvt") and (mnemonic[5] == 's' or mnemonic[5] == 'u'))
            if (std.mem.findScalar(u8, "napmz", mnemonic[4])) |mode| @as(u32, @intFromBool(mnemonic[5] == 'u')) | @as(u32, switch (mode) {
                0 => 0b00_000,
                1 => 0b00_100,
                2 => 0b01_000,
                3 => 0b10_000,
                else => 0b11_000,
            }) else null
        else
            null;
        const g: usize = if (from_int) 1 else 0;
        if (convert) |op| if (ops[g] == .reg and fpType(ops, 1 - g) != null) {
            const w = ops[g].reg.width;
            const r = try a.zrReg(ops, g, w);
            const t = fpType(ops, 1 - g).?;
            const v = vNum(ops, 1 - g);
            const rd, const rn = if (from_int) .{ v, r } else .{ r, v };
            if (ops.len == 2) return 0x1E200000 | sfBit(w) | t << 22 | op << 16 | rn << 5 | rd;
            if (ops.len != 3 or ops[2] != .imm or (!from_int and mnemonic[4] != 'z')) return null;
            const fbits = try a.immIn(ops, 2, 1, w.bits(), "the number of fraction bits");
            return 0x1E000000 | sfBit(w) | t << 22 | op << 16 | (64 - fbits) << 10 | rn << 5 | rd;
        };
        if (eql(u8, mnemonic, "fjcvtzs") and ops.len == 2 and t1 == 1 and ops[0] == .reg) {
            if (!a.cpu.has(.aarch64, .jsconv)) return a.needs(.jsconv);
            return 0x1E7E0000 | vNum(ops, 1) << 5 | try a.zrReg(ops, 0, .w);
        }
        return null;
    }

    /// `fmov` other than between two registers of one type: an immediate
    /// to a register, and the bits between a general register and a
    /// floating-point one of its size or a half, or the high half of a
    /// vector (`v1.d[1]`).
    fn fmov(a: *Asm, ops: []const Operand) Error!?u32 {
        if (fpType(ops, 0)) |t| {
            const d = vNum(ops, 0);
            // Plus zero is zr's bits; the others are eight bits' worth.
            const value: f64 = switch (ops[1]) {
                .fimm => |v| v,
                .imm => |v| value: {
                    // In hexadecimal, the eight bits themselves; in
                    // decimal, the value.
                    const tok = a.lastImm();
                    if (std.mem.startsWith(u8, tok, "0x") or std.mem.startsWith(u8, tok, "-0x")) {
                        if (v < 0 or v > 255) return a.fail("inline assembly: an encoded floating-point immediate is 0 to 255: '{s}'", .{a.line});
                        return 0x1E201000 | t << 22 | @as(u32, @intCast(v)) << 13 | d;
                    }
                    const digits = tok[@intFromBool(tok[0] == '-')..];
                    if (tok[0] != '%' and std.mem.findNone(u8, digits, "0123456789") != null) return a.fail("inline assembly: 'fmov' takes a decimal number or its encoding in hexadecimal: '{s}'", .{a.line});
                    break :value @floatFromInt(v);
                },
                .reg => |r| {
                    if (t != 3 and (r.width == .x) != (t == 1)) return null;
                    return 0x1E270000 | sfBit(r.width) | t << 22 | try a.zrReg(ops, 1, r.width) << 5 | d;
                },
                else => return null,
            };
            if (@as(u64, @bitCast(value)) == 0) return 0x1E2703E0 | @as(u32, @intFromBool(t == 1)) << 31 | t << 22 | d;
            const imm8 = fpImm8(value) orelse return a.fail("inline assembly: 'fmov' takes #0.0 or plus or minus 16 to 31 sixteenths times a power of two from 1/8 to 16: '{s}'", .{a.line});
            return 0x1E201000 | t << 22 | imm8 << 13 | d;
        }
        if (ops[0] == .reg) {
            const r = ops[0].reg;
            if (fpType(ops, 1)) |t| {
                if (t != 3 and (r.width == .x) != (t == 1)) return null;
                return 0x1E260000 | sfBit(r.width) | t << 22 | vNum(ops, 1) << 5 | try a.zrReg(ops, 0, r.width);
            }
            if (ops[1] != .velem or ops[1].velem.log2 != 3 or ops[1].velem.index != 1 or r.width != .x) return null;
            return 0x9EAE0000 | @as(u32, @backingInt(ops[1].velem.reg)) << 5 | try a.zrReg(ops, 0, .x);
        }
        if (ops[0] != .velem or ops[0].velem.log2 != 3 or ops[0].velem.index != 1 or ops[1] != .reg) return null;
        return 0x9EAF0000 | try a.zrReg(ops, 1, .x) << 5 | @as(u32, @backingInt(ops[0].velem.reg));
    }

    /// The statement's last operand as written, an immediate, without
    /// its `#`.
    fn lastImm(a: *const Asm) []const u8 {
        const comma = std.mem.findScalarLast(u8, a.line, ',') orelse return a.line;
        return std.mem.trimStart(u8, a.line[comma + 1 ..], " \t#");
    }

    /// The exclusive and the acquire and release loads and stores, and
    /// with the CPU's `lse` feature compare and swap, swap, and the atomic
    /// memory operations (`ldadd`, `stset` and so on), each with its
    /// acquire (`a`), release (`l`) and byte or halfword (`b`, `h`) forms.
    fn atomic(a: *Asm, mnemonic: []const u8, ops: []const Operand) Error!?u32 {
        if (ops.len == 0 or ops[0] != .reg) return null;
        const eql = std.mem.eql;
        // A register and the address; a status register before those; two
        // registers and the address; a status register before those.
        const Form = enum { one, status_one, pair, status_pair };
        const exclusives = [_]struct { []const u8, u32, Form }{
            .{ "ldxr", 0x885F7C00, .one },          .{ "ldaxr", 0x885FFC00, .one },       .{ "ldar", 0x88DFFC00, .one },
            .{ "stlr", 0x889FFC00, .one },          .{ "stxr", 0x88007C00, .status_one }, .{ "stlxr", 0x8800FC00, .status_one },
            .{ "ldxp", 0x887F0000, .pair },         .{ "ldaxp", 0x887F8000, .pair },      .{ "stxp", 0x88200000, .status_pair },
            .{ "stlxp", 0x88208000, .status_pair },
        };
        // The access size a `b` or `h` suffix names.
        const narrow: ?u32 = switch (mnemonic[mnemonic.len - 1]) {
            'b' => 0,
            'h' => 1,
            else => null,
        };
        for (exclusives) |x| {
            const single = x[2] == .one or x[2] == .status_one;
            const suffixed = narrow != null and single and eql(u8, mnemonic[0 .. mnemonic.len - 1], x[0]);
            if (!suffixed and !eql(u8, mnemonic, x[0])) continue;
            const status = x[2] == .status_one or x[2] == .status_pair;
            const k: usize = @intFromBool(status);
            const count: usize = k + @as(usize, if (single) 2 else 3);
            if (ops.len != count or ops[k] != .reg) return error.AsmUnsupported;
            const w = ops[k].reg.width;
            if (suffixed and w != .w) return error.AsmUnsupported;
            const t = try a.zrReg(ops, k, w);
            const t2: u32 = if (single) 0 else try a.zrReg(ops, k + 1, w) << 10;
            const s: u32 = if (status) try a.zrReg(ops, 0, .w) << 16 else 0;
            const n = try baseOnly(ops, count - 1, false);
            const base_reg = ops[count - 1].mem.mem.base;
            // What LLVM calls unpredictable and rejects.
            if (status) {
                const sr = ops[0].reg.reg;
                if (sr == ops[1].reg.reg or (!single and sr == ops[2].reg.reg) or sr == base_reg)
                    return a.fail("inline assembly: the status register is also a source or the base, which is unpredictable: '{s}'", .{a.line});
            }
            const size: u32 = if (suffixed) narrow.? << 30 else 1 << 31 | @as(u32, @backingInt(w)) << 30;
            return (x[1] & 0x3FFFFFFF) | size | s | t2 | n << 5 | t;
        }
        const Lse = enum { cas, casp, swp, load, store };
        const prefixes = [_]struct { []const u8, Lse, u32 }{
            .{ "casp", .casp, 0 },    .{ "cas", .cas, 0 },      .{ "swp", .swp, 0 },      .{ "ldadd", .load, 0 },
            .{ "ldclr", .load, 1 },   .{ "ldeor", .load, 2 },   .{ "ldset", .load, 3 },   .{ "ldsmax", .load, 4 },
            .{ "ldsmin", .load, 5 },  .{ "ldumax", .load, 6 },  .{ "ldumin", .load, 7 },  .{ "stadd", .store, 0 },
            .{ "stclr", .store, 1 },  .{ "steor", .store, 2 },  .{ "stset", .store, 3 },  .{ "stsmax", .store, 4 },
            .{ "stsmin", .store, 5 }, .{ "stumax", .store, 6 }, .{ "stumin", .store, 7 },
        };
        for (prefixes) |p| {
            if (!std.mem.startsWith(u8, mnemonic, p[0])) continue;
            var rest = mnemonic[p[0].len..];
            const acquire = rest.len > 0 and rest[0] == 'a';
            if (acquire) rest = rest[1..];
            const release = rest.len > 0 and rest[0] == 'l';
            if (release) rest = rest[1..];
            const suffixed = rest.len == 1 and narrow != null;
            if (rest.len != @intFromBool(suffixed) or (acquire and p[1] == .store) or (suffixed and p[1] == .casp)) continue;
            if (!a.cpu.has(.aarch64, .lse)) return a.needs(.lse);
            const w = ops[0].reg.width;
            if (suffixed and w != .w) return error.AsmUnsupported;
            const size: u32 = if (suffixed) narrow.? << 30 else 1 << 31 | @as(u32, @backingInt(w)) << 30;
            const al = @as(u32, @intFromBool(acquire)) << 1 | @intFromBool(release);
            switch (p[1]) {
                .casp => {
                    if (ops.len != 5) return error.AsmUnsupported;
                    const s = try a.zrReg(ops, 0, w);
                    const t = try a.zrReg(ops, 2, w);
                    if (s % 2 != 0 or try a.zrReg(ops, 1, w) != s + 1 or t % 2 != 0 or try a.zrReg(ops, 3, w) != t + 1)
                        return a.fail("inline assembly: each pair of '{s}' is an even register and the next one: '{s}'", .{ mnemonic, a.line });
                    const n = try baseOnly(ops, 4, true);
                    return 0x08207C00 | @as(u32, @backingInt(w)) << 30 | @as(u32, @intFromBool(acquire)) << 22 | @as(u32, @intFromBool(release)) << 15 | s << 16 | n << 5 | t;
                },
                .cas => {
                    if (ops.len != 3) return error.AsmUnsupported;
                    const n = try baseOnly(ops, 2, true);
                    return 0x08A07C00 | size | @as(u32, @intFromBool(acquire)) << 22 | @as(u32, @intFromBool(release)) << 15 | try a.zrReg(ops, 0, w) << 16 | n << 5 | try a.zrReg(ops, 1, w);
                },
                .swp, .load => {
                    if (ops.len != 3) return error.AsmUnsupported;
                    const n = try baseOnly(ops, 2, true);
                    const op: u32 = if (p[1] == .swp) 0x38208000 else 0x38200000 | p[2] << 12;
                    return op | size | al << 22 | try a.zrReg(ops, 0, w) << 16 | n << 5 | try a.zrReg(ops, 1, w);
                },
                .store => {
                    if (ops.len != 2) return error.AsmUnsupported;
                    const n = try baseOnly(ops, 1, true);
                    return 0x38200000 | p[2] << 12 | size | al << 22 | try a.zrReg(ops, 0, w) << 16 | n << 5 | 31;
                },
            }
        }
        return null;
    }

    /// A prefetch operation: its name (`pldl1keep`), in either case, or
    /// its number.
    fn prefetchOp(a: *Asm, op: Operand) Error!u32 {
        switch (op) {
            .imm => |v| return if (v >= 0 and v <= 31) @intCast(v) else a.fail("inline assembly: a prefetch operation is a name or 0 to 31: '{s}'", .{a.line}),
            .name => |name| {
                var buf: [9]u8 = undefined;
                if (name.len < 8 or name.len > buf.len) return error.AsmUnsupported;
                const n = std.ascii.lowerString(&buf, name);
                const kind: u32 = for ([_][]const u8{ "pld", "pli", "pst" }, 0..) |k, i| {
                    if (std.mem.startsWith(u8, n, k)) break @intCast(i);
                } else return error.AsmUnsupported;
                if (n[3] != 'l' or n[4] < '1' or n[4] > '3') return error.AsmUnsupported;
                const stream = std.mem.eql(u8, n[5..], "strm");
                if (!stream and !std.mem.eql(u8, n[5..], "keep")) return error.AsmUnsupported;
                return kind << 3 | @as(u32, n[4] - '1') << 1 | @intFromBool(stream);
            },
            else => return error.AsmUnsupported,
        }
    }

    /// Operand `i`, a memory operand with a signed 9-bit offset
    /// (`[x1, #-8]`): the base and offset fields.
    fn memUnscaled(a: *Asm, ops: []const Operand, i: usize) Error!u32 {
        if (i >= ops.len or ops[i] != .mem) return error.AsmUnsupported;
        const m = ops[i].mem.mem;
        if (m.offset != .imm) return error.AsmUnsupported;
        const v = m.offset.imm;
        if (v < -256 or v > 255) return a.fail("inline assembly: the offset is -256 to 255: '{s}'", .{a.line});
        return (@as(u32, @bitCast(v)) & 0x1FF) << 12 | m.base.spEnc() << 5;
    }

    /// The loads and stores CodeGen's Encoder has no use for: the unscaled
    /// and unprivileged ones of a byte, halfword or word, the pairs
    /// `ldnp`, `stnp` and `ldpsw`, and prefetches.
    fn memory(a: *Asm, mnemonic: []const u8, ops: []const Operand) Error!?u32 {
        const eql = std.mem.eql;
        // The encodings for a w and for an x register, where there is one.
        const singles = [_]struct { []const u8, ?u32, ?u32 }{
            .{ "sturb", 0x38000000, null },        .{ "ldurb", 0x38400000, null },      .{ "ldursb", 0x38C00000, 0x38800000 },
            .{ "sturh", 0x78000000, null },        .{ "ldurh", 0x78400000, null },      .{ "ldursh", 0x78C00000, 0x78800000 },
            .{ "ldursw", null, 0xB8800000 },       .{ "sttrb", 0x38000800, null },      .{ "ldtrb", 0x38400800, null },
            .{ "ldtrsb", 0x38C00800, 0x38800800 }, .{ "sttrh", 0x78000800, null },      .{ "ldtrh", 0x78400800, null },
            .{ "ldtrsh", 0x78C00800, 0x78800800 }, .{ "sttr", 0xB8000800, 0xF8000800 }, .{ "ldtr", 0xB8400800, 0xF8400800 },
            .{ "ldtrsw", null, 0xB8800800 },
        };
        for (singles) |s| if (eql(u8, mnemonic, s[0])) {
            if (ops.len != 2 or ops[0] != .reg) return error.AsmUnsupported;
            const w = ops[0].reg.width;
            const base = (if (w == .x) s[2] else s[1]) orelse return error.AsmUnsupported;
            return base | try a.memUnscaled(ops, 1) | try a.zrReg(ops, 0, w);
        };
        const no_allocate = eql(u8, mnemonic, "ldnp") or eql(u8, mnemonic, "stnp");
        if (no_allocate or eql(u8, mnemonic, "ldpsw")) {
            if (ops.len != 3 or ops[2] != .mem) return error.AsmUnsupported;
            // The registers, the opc field and log2 of the bytes each moves.
            const t1: u32, const t2: u32, const opc: u32, const log2: u5 = switch (ops[0]) {
                .reg => |r| if (no_allocate)
                    .{ try a.zrReg(ops, 0, r.width), try a.zrReg(ops, 1, r.width), @as(u32, @backingInt(r.width)) << 31, @as(u5, 2) + @backingInt(r.width) }
                else
                    .{ try a.zrReg(ops, 0, .x), try a.zrReg(ops, 1, .x), 1 << 30, 2 },
                .vreg => |v| regs: {
                    if (!no_allocate or ops[1] != .vreg or ops[1].vreg.kind != v.kind or v.arr != null or ops[1].vreg.arr != null) return error.AsmUnsupported;
                    const size: u32 = switch (v.kind) {
                        .s => 0,
                        .d => 1,
                        .q => 2,
                        .v, .h, .b => return error.AsmUnsupported,
                    };
                    break :regs .{ @backingInt(v.reg), @backingInt(ops[1].vreg.reg), size << 30 | 1 << 26, @intCast(size + 2) };
                },
                else => return error.AsmUnsupported,
            };
            const load = mnemonic[0] == 'l';
            if (load and t1 == t2) return a.fail("inline assembly: the two registers loaded are the same, which is unpredictable: '{s}'", .{a.line});
            const m = ops[2].mem.mem;
            const form: u32, const offset = switch (m.offset) {
                .imm => |v| .{ @as(u32, if (no_allocate) 0b000 else 0b010), v },
                .pre => |v| .{ 0b011, v },
                .post => |v| .{ 0b001, v },
                else => return error.AsmUnsupported,
            };
            if (form & 1 != 0) {
                if (no_allocate) return error.AsmUnsupported;
                if (m.base.spEnc() == t1 or m.base.spEnc() == t2) return a.fail("inline assembly: the base register written back is also loaded, which is unpredictable: '{s}'", .{a.line});
            }
            const scale = @as(i32, 1) << log2;
            if (@rem(offset, scale) != 0 or offset < -64 * scale or offset > 63 * scale)
                return a.fail("inline assembly: the offset is a multiple of {d} from {d} to {d}: '{s}'", .{ scale, -64 * scale, 63 * scale, a.line });
            const imm7 = @as(u32, @bitCast(@divExact(offset, scale))) & 0x7F;
            return 0x28000000 | opc | form << 23 | @as(u32, @intFromBool(load)) << 22 | imm7 << 15 | t2 << 10 | m.base.spEnc() << 5 | t1;
        }
        const unscaled = eql(u8, mnemonic, "prfum");
        if (unscaled or eql(u8, mnemonic, "prfm")) {
            if (ops.len != 2 or ops[1] != .mem) return error.AsmUnsupported;
            const op = try a.prefetchOp(ops[0]);
            const m = ops[1].mem.mem;
            const n = m.base.spEnc() << 5;
            switch (m.offset) {
                .imm => |v| {
                    // The scaled form where the offset fits it, as LLVM picks.
                    if (!unscaled and v >= 0 and @rem(v, 8) == 0 and v <= 32760) return 0xF9800000 | @as(u32, @intCast(@divExact(v, 8))) << 10 | n | op;
                    if (v < -256 or v > 255) return a.fail("inline assembly: the offset is {s}-256 to 255: '{s}'", .{ if (unscaled) "" else "a multiple of 8 from 0 to 32760, or ", a.line });
                    return 0xF8800000 | try a.memUnscaled(ops, 1) | op;
                },
                .index => |x| {
                    if (unscaled) return error.AsmUnsupported;
                    const shift = ops[1].mem.shift orelse 0;
                    if (shift != 0 and shift != 3) return a.fail("inline assembly: the index register of a prefetch shifts left by 0 or 3: '{s}'", .{a.line});
                    return 0xF8A00800 | x.reg.zrEnc() << 16 | @as(u32, @backingInt(x.extend)) << 13 | @as(u32, @intFromBool(shift == 3)) << 12 | n | op;
                },
                else => return error.AsmUnsupported,
            }
        }
        return null;
    }
};
