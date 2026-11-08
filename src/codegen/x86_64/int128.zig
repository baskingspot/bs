//! 128-bit integers (`u128`, `i128`) in register pairs: `CodeGen.inPair`
//! gives them two registers (`Home.regs`, the low eightbyte in `lo`), and
//! the operations here compute them there instead of limb by limb in
//! memory (`genWide`): addition, subtraction, bitwise operations,
//! multiplication, shifts by constant amounts, casts, and comparisons.
//! The other operations read them from memory (`spillPair`).
//!
//! Each operation reads its operands' halves in place (registers, memory,
//! or a constant's eightbytes) and computes the result in its own pair
//! when writing the low half there first overwrites no half it reads
//! later (`Out`), else in rdx:rax, which it then moves home. rcx and r10
//! hold immediates that do not fit an instruction, and rcx the cross
//! products of a multiplication.

const std = @import("std");
const Ir = @import("../../Ir.zig");
const Inst = Ir.Inst;
const InternPool = @import("../../InternPool.zig");
const Index = InternPool.Index;
const Type = @import("../../Type.zig");
const Encoder = @import("Encoder.zig");
const CodeGen = @import("CodeGen.zig");
const Ssa = @import("../Ssa.zig");
const Reg = Encoder.Reg;
const Operand = Encoder.Operand;
const Error = CodeGen.Error;
const offsetMem = CodeGen.offsetMem;

/// Whether `ty` is an integer type lowered here.
pub fn is128(ip: *const InternPool, ty: Index) bool {
    return Type.class(ip, ty) == .int and Type.intInfo(ip, ty).bits == 128;
}

/// Where `inst`'s result lives if it is computed here (`gen`): in a pair,
/// in one register (a truncation or comparison), or in memory or its
/// fields' homes (an overflow operation's tuple).
pub fn lowers(cg: *CodeGen, inst: Inst.Index) ?enum { pair, gpr, tuple } {
    const ip = cg.ip;
    const data = cg.ir.instructions.items(.data)[@backingInt(inst)];
    return switch (cg.ir.instructions.items(.tag)[@backingInt(inst)]) {
        .add_with_overflow, .sub_with_overflow => if (is128(ip, cg.typeOf(cg.ir.extraData(Ir.Bin, data.ty_pl.payload).data.lhs))) .tuple else null,
        .mul_with_overflow => {
            const lhs_ty = cg.typeOf(cg.ir.extraData(Ir.Bin, data.ty_pl.payload).data.lhs);
            return if (is128(ip, lhs_ty) and Type.intInfo(ip, lhs_ty).signedness == .unsigned) .tuple else null;
        },
        // An overflow operation's value.
        .struct_field_val => {
            const sf = cg.ir.extraData(Ir.StructField, data.ty_pl.payload).data;
            if (sf.index != 0 or !is128(ip, data.ty_pl.ty)) return null;
            const op = sf.operand.toIndex() orelse return null;
            return switch (cg.ir.instructions.items(.tag)[@backingInt(op)]) {
                .add_with_overflow, .sub_with_overflow, .mul_with_overflow => if (lowers(cg, op) != null) .pair else null,
                else => null,
            };
        },
        .add_wrap, .sub_wrap, .mul_wrap, .bit_and, .bit_or, .xor => if (is128(ip, cg.typeOf(data.bin_op.lhs))) .pair else null,
        .shl, .shr => if (is128(ip, cg.typeOf(data.bin_op.lhs)) and amount(cg, data.bin_op.rhs) != null) .pair else null,
        .not => if (is128(ip, data.ty_op.ty)) .pair else null,
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => if (is128(ip, cg.typeOf(data.bin_op.lhs))) .gpr else null,
        .intcast, .trunc, .bitcast => {
            const src_ty = cg.typeOf(data.ty_op.operand);
            if (is128(ip, data.ty_op.ty)) {
                if (is128(ip, src_ty)) return .pair;
                if (Type.class(ip, src_ty) == .int and Type.intInfo(ip, src_ty).bits <= 64) return .pair;
                return null;
            }
            if (is128(ip, src_ty) and Type.class(ip, data.ty_op.ty) == .int and Type.intInfo(ip, data.ty_op.ty).bits <= 64) return .gpr;
            return null;
        },
        else => null,
    };
}

/// Whether `inst` widens an unsigned integer of at most 64 bits to 128.
fn isZext(cg: *CodeGen, inst: Inst.Index) bool {
    const ip = cg.ip;
    const tag = cg.ir.instructions.items(.tag)[@backingInt(inst)];
    if (tag != .intcast) return false;
    const data = cg.ir.instructions.items(.data)[@backingInt(inst)];
    if (!is128(ip, data.ty_op.ty)) return false;
    const src_ty = cg.typeOf(data.ty_op.operand);
    if (Type.class(ip, src_ty) != .int) return false;
    const info = Type.intInfo(ip, src_ty);
    return info.signedness == .unsigned and info.bits <= 64;
}

/// Before allocation: a widening of an unsigned value of at most 64 bits
/// that only the operations here (`halves`) and `mulWide` products
/// (`loadFactor`) read gets one register, which holds the low half: the
/// high half is zero. Fiat-crypto's `addcarryxU64` adds two of them.
pub fn plan(cg: *CodeGen) Error!void {
    const f = cg.ssa;
    const live = f.live.slice();
    const reg = live.items(.reg);
    const uses = live.items(.uses);
    const fate = live.items(.fate);
    const tags = cg.ir.instructions.items(.tag);
    const T = struct {
        cg: *CodeGen,
        reg: []u8,
        n: *std.AutoHashMapUnmanaged(u32, u32),
        failed: bool = false,
        const Self = @This();
        pub fn use(t: *Self, ref: Inst.Ref) void {
            const c = ref.toIndex() orelse return;
            const ci = @backingInt(c);
            if (t.reg[ci] != Ssa.want_pair or !isZext(t.cg, c)) return;
            const gop = t.n.getOrPut(t.cg.gpa, ci) catch {
                t.failed = true;
                return;
            };
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    };
    var n: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer n.deinit(cg.gpa);
    var t: T = .{ .cg = cg, .reg = reg, .n = &n };
    for (f.values.items(.inst)) |v| {
        if (fate[@backingInt(v)] != .normal) continue;
        const halved = lowers(cg, v) != null or (tags[@backingInt(v)] == .mul_wrap and cg.mulWide(v) != null);
        if (halved) Ssa.forEachOperand(cg.ir, v, &t);
    }
    if (t.failed) return error.OutOfMemory;
    var it = n.iterator();
    while (it.next()) |e| {
        const ci = e.key_ptr.*;
        if (fate[ci] == .normal and uses[ci] == e.value_ptr.*) reg[ci] = Ssa.want_reg;
    }
    // A right shift by 64 or more that only a truncation reads is not
    // emitted: the truncation shifts the high half (`gen`), which lives
    // until it.
    const datas = cg.ir.instructions.items(.data);
    const def = live.items(.def);
    const end = live.items(.end);
    const crosses = live.items(.crosses);
    const share = live.items(.share);
    const fwd = live.items(.fwd);
    const cl = f.clobbers.items;
    for (f.values.items(.inst)) |v| {
        const vi = @backingInt(v);
        if (fate[vi] != .normal or tags[vi] != .trunc or lowers(cg, v) != .gpr) continue;
        const sh = datas[vi].ty_op.operand.toIndex() orelse continue;
        const si = @backingInt(sh);
        if (tags[si] != .shr or fate[si] != .normal or uses[si] != 1 or cg.homes[si] != .none) continue;
        if (lowers(cg, sh) != .pair or amount(cg, datas[si].bin_op.rhs).? < 64) continue;
        if (datas[si].bin_op.lhs.toIndex()) |x| {
            // A forwarded load is its value stored (`Live.fwd`).
            var xi = @backingInt(x);
            if (fwd[xi] != Ssa.no_tie) xi = fwd[xi];
            if (fate[xi] != .normal or share[xi] != Ssa.no_tie) continue;
            end[xi] = @max(end[xi], def[vi]);
            crosses[xi] = crosses[xi] or cl[def[vi]][0] != cl[def[xi]][0] or cl[def[vi]][1] != cl[def[xi]][1];
        }
        fate[si] = .dead;
        reg[si] = Ssa.no_reg;
        cg.homes[si] = .dead;
    }
}

/// A shift amount's value if it is a constant.
fn amount(cg: *CodeGen, ref: Inst.Ref) ?u8 {
    const v = ref.toInterned() orelse return null;
    if (cg.ip.keyTag(v) != .int) return null;
    return switch (cg.ip.keyPayload(.int, v).storage) {
        .u64 => |u| if (u < 128) @intCast(u) else null,
        .i64 => |i| if (i >= 0 and i < 128) @intCast(i) else null,
        .big => null,
    };
}

/// The low and high halves of 128-bit value `ref`, where they can be read.
fn halves(cg: *CodeGen, ref: Inst.Ref) Error![2]Operand {
    if (cg.pairOf(ref)) |p| return .{ .{ .reg = p.lo }, .{ .reg = p.hi } };
    // A widened value in one register (`plan`), or in the 8-byte slot
    // `genSplit` saved that register to around a clobbering instruction.
    if (ref.toIndex()) |i| switch (cg.homes[@backingInt(i)]) {
        .reg => |r| return .{ .{ .reg = r }, .{ .imm = 0 } },
        .slot => |off| for (cg.split_now.items) |s| {
            if (s.v == @backingInt(i) and s.home == .reg) return .{ .{ .mem = .at(.rbp, off) }, .{ .imm = 0 } };
        },
        else => {},
    };
    if (ref.toInterned()) |v| {
        const bits: u128 = if (cg.ip.keyTag(v) == .undef) ~@as(u128, 0) / 3 * 2 else switch (cg.ip.keyPayload(.int, v).storage) {
            .u64 => |u| u,
            .i64 => |i| @bitCast(@as(i128, i)),
            .big => |b| if (b.positive) b.toInt(u128) catch unreachable else @bitCast(b.toInt(i128) catch unreachable),
        };
        return .{ .{ .imm = @bitCast(@as(u64, @truncate(bits))) }, .{ .imm = @bitCast(@as(u64, @truncate(bits >> 64))) } };
    }
    const m = try cg.memOf(ref);
    return .{ .{ .mem = m }, .{ .mem = offsetMem(m, 8) } };
}

fn fitsImm32(x: Operand) bool {
    return x != .imm or std.math.cast(i32, x.imm) != null;
}

/// `x`, with an immediate that no ALU instruction takes in rcx.
fn aluSrc(cg: *CodeGen, x: Operand) Error!Operand {
    if (fitsImm32(x)) return x;
    try cg.e.mov(.qword, .{ .reg = .rcx }, x);
    return .{ .reg = .rcx };
}

/// `x` as a register or memory operand, an immediate in `scratch`.
fn rm(cg: *CodeGen, x: Operand, scratch: Reg) Error!Encoder.Rm {
    return switch (x) {
        .reg => |r| .{ .reg = r },
        .mem => |m| .{ .mem = m },
        .imm => {
            try cg.e.mov(.qword, .{ .reg = scratch }, x);
            return .{ .reg = scratch };
        },
    };
}

fn isZero(x: Operand) bool {
    return x == .imm and x.imm == 0;
}

/// Whether reading `x` reads register `r`.
fn reads(x: Operand, r: Reg) bool {
    return switch (x) {
        .reg => |q| q == r,
        .mem => |m| (m.base == .reg and m.base.reg == r) or (m.index != null and m.index.?.reg == r),
        .imm => false,
    };
}

/// Where an operation computes its result: `lo` and `hi`, which are
/// `inst`'s own pair or rax and rdx.
const Out = struct {
    lo: Reg,
    hi: Reg,
    own: bool,

    /// `inst`'s pair if writing its low half overwrites none of `later`
    /// (read after it is written) and its high half none of `after_hi`.
    fn pick(cg: *CodeGen, inst: Inst.Index, later: []const Operand, after_hi: []const Operand) Out {
        const scratch: Out = .{ .lo = .rax, .hi = .rdx, .own = false };
        const p = cg.pairOf(inst.toRef()) orelse return scratch;
        for (later) |x| if (reads(x, p.lo)) return scratch;
        for (after_hi) |x| if (reads(x, p.hi)) return scratch;
        return .{ .lo = p.lo, .hi = p.hi, .own = true };
    }

    /// `mov dst, x` unless `x` is `dst`.
    fn mov(cg: *CodeGen, dst: Reg, x: Operand) Error!void {
        if (x == .reg and x.reg == dst) return;
        try cg.e.mov(.qword, .{ .reg = dst }, x);
    }

    /// Moves the result to `inst`'s home if it is not computed there.
    fn finish(o: Out, cg: *CodeGen, inst: Inst.Index, ty: Index) Error!void {
        if (o.own) return;
        if (cg.pairOf(inst.toRef())) |p| {
            try cg.e.mov(.qword, .{ .reg = p.lo }, .{ .reg = o.lo });
            return cg.e.mov(.qword, .{ .reg = p.hi }, .{ .reg = o.hi });
        }
        const m = try cg.resultMem(inst, ty) orelse return;
        try cg.e.mov(.qword, .{ .mem = m }, .{ .reg = o.lo });
        try cg.e.mov(.qword, .{ .mem = offsetMem(m, 8) }, .{ .reg = o.hi });
    }
};

/// The result in rdx:rax, moved to `inst`'s home.
fn finish(cg: *CodeGen, inst: Inst.Index, ty: Index) Error!void {
    return (Out{ .lo = .rax, .hi = .rdx, .own = false }).finish(cg, inst, ty);
}

pub fn gen(cg: *CodeGen, inst: Inst.Index, tag: Inst.Tag, data: Inst.Data) Error!void {
    const ip = cg.ip;
    const e = &cg.e;
    switch (tag) {
        .add_with_overflow, .sub_with_overflow, .mul_with_overflow => return overflow(cg, inst, tag, data),
        .struct_field_val => {
            // Of a tuple in memory; else its operation wrote it.
            const sf = cg.ir.extraData(Ir.StructField, data.ty_pl.payload).data;
            if (cg.homes[@backingInt(sf.operand.toIndex().?)] == .pair) return;
            const m = try cg.memOf(sf.operand);
            const o = Out.pick(cg, inst, &.{.{ .mem = m }}, &.{});
            try e.mov(.qword, .{ .reg = o.lo }, .{ .mem = m });
            try e.mov(.qword, .{ .reg = o.hi }, .{ .mem = offsetMem(m, 8) });
            return o.finish(cg, inst, data.ty_pl.ty);
        },
        .add_wrap, .sub_wrap, .bit_and, .bit_or, .xor => {
            const ty = cg.typeOf(data.bin_op.lhs);
            const a = try halves(cg, data.bin_op.lhs);
            const b = try halves(cg, data.bin_op.rhs);
            const ops: [2]Encoder.AluOp = switch (tag) {
                .add_wrap => .{ .add, .adc },
                .sub_wrap => .{ .sub, .sbb },
                .bit_and => .{ .@"and", .@"and" },
                .bit_or => .{ .@"or", .@"or" },
                else => .{ .xor, .xor },
            };
            // Wide immediates are loaded before the flags are set.
            const b1 = try aluSrc(cg, b[1]);
            var b0 = try aluSrc0(cg, b[0]);
            var a0 = a[0];
            // The low half computed over the operand it lives in, if
            // the operation commutes.
            if (tag != .sub_wrap and b0 == .reg and !(a0 == .reg and a0.reg == b0.reg)) if (cg.pairOf(inst.toRef())) |p| if (p.lo == b0.reg) std.mem.swap(Operand, &a0, &b0);
            // b0 is read as the low half is written, unless it is a0.
            const b0_late: Operand = if (a0 == .reg and b0 == .reg and a0.reg == b0.reg) .{ .imm = 0 } else b0;
            const o = Out.pick(cg, inst, &.{ b0_late, a[1], b1 }, &.{if (a[1] == .reg and b1 == .reg and a[1].reg == b1.reg) .{ .imm = 0 } else b1});
            try Out.mov(cg, o.lo, a0);
            try e.alu(ops[0], .qword, .{ .reg = o.lo }, b0);
            try Out.mov(cg, o.hi, a[1]);
            try e.alu(ops[1], .qword, .{ .reg = o.hi }, b1);
            try o.finish(cg, inst, ty);
        },
        .mul_wrap => {
            const ty = cg.typeOf(data.bin_op.lhs);
            var a = try halves(cg, data.bin_op.lhs);
            var b = try halves(cg, data.bin_op.rhs);
            if (b[0] == .imm and a[0] != .imm) std.mem.swap([2]Operand, &a, &b);
            // a.lo * b.lo in rdx:rax, plus the low halves of the cross
            // products in rdx.
            try e.mov(.qword, .{ .reg = .rax }, a[0]);
            try e.unary(.mul, .qword, try rm(cg, b[0], .rcx));
            for ([_][2]Operand{ .{ a[0], b[1] }, .{ a[1], b[0] } }) |x| {
                if (isZero(x[0]) or isZero(x[1])) continue;
                try e.mov(.qword, .{ .reg = .rcx }, x[0]);
                if (x[1] == .imm and fitsImm32(x[1]))
                    try e.imul(.qword, .rcx, .{ .reg = .rcx }, @intCast(x[1].imm))
                else if (x[1] == .imm) {
                    // rcx * imm64: the immediate into r10, a scalar scratch.
                    try e.mov(.qword, .{ .reg = .r10 }, x[1]);
                    try e.imul(.qword, .rcx, .{ .reg = .r10 }, null);
                } else try e.imul(.qword, .rcx, switch (x[1]) {
                    .reg => |r| .{ .reg = r },
                    .mem => |m| .{ .mem = m },
                    .imm => unreachable,
                }, null);
                try e.alu(.add, .qword, .{ .reg = .rdx }, .{ .reg = .rcx });
            }
            try finish(cg, inst, ty);
        },
        .shl, .shr => {
            const ty = cg.typeOf(data.bin_op.lhs);
            const a = try halves(cg, data.bin_op.lhs);
            const k = amount(cg, data.bin_op.rhs).?;
            const right_op: Encoder.ShiftOp = if (Type.intInfo(ip, ty).signedness == .signed) .sar else .shr;
            if (k < 64) {
                // Both halves, then a double shift.
                const o = Out.pick(cg, inst, &.{a[1]}, &.{});
                try Out.mov(cg, o.lo, a[0]);
                try Out.mov(cg, o.hi, a[1]);
                if (k != 0) if (tag == .shl) {
                    try e.shiftDoubleImm(true, .{ .reg = o.hi }, o.lo, k);
                    try e.shift(.shl, .qword, .{ .reg = o.lo }, k);
                } else {
                    try e.shiftDoubleImm(false, .{ .reg = o.lo }, o.hi, k);
                    try e.shift(right_op, .qword, .{ .reg = o.hi }, k);
                };
                return o.finish(cg, inst, ty);
            }
            if (tag == .shl) {
                // The low half moves up; zeros below.
                const o = Out.pick(cg, inst, &.{}, &.{a[0]});
                try Out.mov(cg, o.hi, a[0]);
                if (k != 64) try e.shift(.shl, .qword, .{ .reg = o.hi }, k - 64);
                try e.alu(.xor, .dword, .{ .reg = o.lo }, .{ .reg = o.lo });
                return o.finish(cg, inst, ty);
            }
            // The high half moves down; its sign or zeros above.
            const o = Out.pick(cg, inst, &.{}, &.{});
            try Out.mov(cg, o.lo, a[1]);
            if (right_op == .sar) {
                try e.mov(.qword, .{ .reg = o.hi }, .{ .reg = o.lo });
                try e.shift(.sar, .qword, .{ .reg = o.hi }, 63);
            } else try e.alu(.xor, .dword, .{ .reg = o.hi }, .{ .reg = o.hi });
            if (k != 64) try e.shift(right_op, .qword, .{ .reg = o.lo }, k - 64);
            try o.finish(cg, inst, ty);
        },
        .not => {
            const a = try halves(cg, data.ty_op.operand);
            const o = Out.pick(cg, inst, &.{a[1]}, &.{});
            try Out.mov(cg, o.lo, a[0]);
            try Out.mov(cg, o.hi, a[1]);
            try e.unary(.not, .qword, .{ .reg = o.lo });
            try e.unary(.not, .qword, .{ .reg = o.hi });
            try o.finish(cg, inst, data.ty_op.ty);
        },
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => {
            // Computed by the branch it decides (`CodeGen.condFlags`).
            if (cg.homes[@backingInt(inst)] == .fused) return;
            const cc = try cmpFlags(cg, tag, data.bin_op.lhs, data.bin_op.rhs);
            const d = cg.destReg(inst);
            try e.setcc(cc, .{ .reg = d });
            try e.movzx(.dword, d, .byte, .{ .reg = d });
            try cg.setResult(inst, .bool_type, d);
        },
        .intcast, .trunc, .bitcast => {
            const ty = data.ty_op.ty;
            const src = data.ty_op.operand;
            const src_ty = cg.typeOf(src);
            if (!is128(ip, ty)) {
                const d = cg.destReg(inst);
                const folded = if (src.toIndex()) |sh| cg.homes[@backingInt(sh)] == .dead else false;
                if (folded) {
                    const sh = src.toIndex().?;
                    // The high half of a right shift by 64 or more (`plan`).
                    const bin = cg.ir.instructions.items(.data)[@backingInt(sh)].bin_op;
                    const k = amount(cg, bin.rhs).?;
                    try e.mov(.qword, .{ .reg = d }, (try halves(cg, bin.lhs))[1]);
                    if (k != 64) try e.shift(if (Type.intInfo(ip, cg.typeOf(bin.lhs)).signedness == .signed) .sar else .shr, .qword, .{ .reg = d }, k - 64);
                } else {
                    // The low half, truncated.
                    try e.mov(.qword, .{ .reg = d }, (try halves(cg, src))[0]);
                }
                try cg.normalize(d, ty);
                return cg.setResult(inst, ty, d);
            }
            if (is128(ip, src_ty)) {
                const a = try halves(cg, src);
                const o = Out.pick(cg, inst, &.{a[1]}, &.{});
                try Out.mov(cg, o.lo, a[0]);
                try Out.mov(cg, o.hi, a[1]);
                return o.finish(cg, inst, ty);
            }
            if (cg.homes[@backingInt(inst)] == .reg) {
                // Its low half only (`plan`).
                const d = cg.destReg(inst);
                try cg.load(d, src);
                return;
            }
            // Extended by the operand's signedness, as its register holds it.
            const o = Out.pick(cg, inst, &.{}, &.{});
            try cg.load(o.lo, src);
            if (Type.intInfo(ip, src_ty).signedness == .signed) {
                try e.mov(.qword, .{ .reg = o.hi }, .{ .reg = o.lo });
                try e.shift(.sar, .qword, .{ .reg = o.hi }, 63);
            } else try e.alu(.xor, .dword, .{ .reg = o.hi }, .{ .reg = o.hi });
            try o.finish(cg, inst, ty);
        },
        else => unreachable,
    }
}

/// Sets the flags of comparison `tag` of 128-bit integers `lhs` and
/// `rhs`, and returns the condition under which it holds.
pub fn cmpFlags(cg: *CodeGen, tag: Inst.Tag, lhs: Inst.Ref, rhs: Inst.Ref) Error!Encoder.Cond {
    const e = &cg.e;
    var a = try halves(cg, lhs);
    var b = try halves(cg, rhs);
    if (tag == .cmp_eq or tag == .cmp_neq) {
        // ZF of (a.lo ^ b.lo) | (a.hi ^ b.hi).
        const b1 = try aluSrc(cg, b[1]);
        try e.mov(.qword, .{ .reg = .rax }, a[0]);
        try e.alu(.xor, .qword, .{ .reg = .rax }, try aluSrc0(cg, b[0]));
        try e.mov(.qword, .{ .reg = .rdx }, a[1]);
        try e.alu(.xor, .qword, .{ .reg = .rdx }, b1);
        try e.alu(.@"or", .qword, .{ .reg = .rax }, .{ .reg = .rdx });
        return if (tag == .cmp_eq) .e else .ne;
    }
    // The flags of a - b over both halves: `>` and `<=` swap.
    if (tag == .cmp_gt or tag == .cmp_lte) std.mem.swap([2]Operand, &a, &b);
    const b1 = try aluSrc(cg, b[1]);
    try e.mov(.qword, .{ .reg = .rax }, a[0]);
    try e.alu(.cmp, .qword, .{ .reg = .rax }, try aluSrc0(cg, b[0]));
    try e.mov(.qword, .{ .reg = .rdx }, a[1]);
    try e.alu(.sbb, .qword, .{ .reg = .rdx }, b1);
    const s = Type.intInfo(cg.ip, cg.typeOf(lhs)).signedness == .signed;
    return switch (tag) {
        .cmp_lt, .cmp_gt => if (s) .l else .b,
        else => if (s) .ge else .ae,
    };
}

/// An overflow operation on 128-bit integers: the value in rdx:rax and the
/// bit in the flags (addition, subtraction) or r11 (multiplication), then
/// written to the fields' homes when they have their own (`Ssa.pairs`),
/// else to the tuple's memory.
fn overflow(cg: *CodeGen, inst: Inst.Index, tag: Inst.Tag, data: Inst.Data) Error!void {
    const ip = cg.ip;
    const e = &cg.e;
    const bin = cg.ir.extraData(Ir.Bin, data.ty_pl.payload).data;
    const tuple_ty = data.ty_pl.ty;
    const ty = cg.typeOf(bin.lhs);
    const signed = Type.intInfo(ip, ty).signedness == .signed;
    const pair = cg.homes[@backingInt(inst)] == .pair;
    const fields = if (pair) cg.ssa.pairs.get(@backingInt(inst)).? else .{ Ssa.no_tie, Ssa.no_tie };
    const in_flags = fields[1] != Ssa.no_tie and cg.homes[fields[1]] == .fused;
    const a = try halves(cg, bin.lhs);
    const b = try halves(cg, bin.rhs);
    var cc: ?Encoder.Cond = null;
    if (tag == .mul_with_overflow) {
        // a * b with a = a1:a0 and b = b1:b0 overflows when a1 and b1 are
        // both nonzero, when a1 * b0 or a0 * b1 needs more than 64 bits,
        // or when adding them, or their sum to the high half of a0 * b0,
        // carries. The bit collects in r11; the cross sum in r10.
        try e.alu(.xor, .dword, .{ .reg = cg.r11() }, .{ .reg = cg.r11() });
        try e.alu(.xor, .dword, .{ .reg = .r10 }, .{ .reg = .r10 });
        if (!isZero(a[1]) and !isZero(b[1])) {
            try e.mov(.qword, .{ .reg = .rax }, a[1]);
            try e.@"test"(.qword, .{ .reg = .rax }, .{ .reg = .rax });
            try e.setcc(.ne, .{ .reg = .rdx });
            try e.mov(.qword, .{ .reg = .rax }, b[1]);
            try e.@"test"(.qword, .{ .reg = .rax }, .{ .reg = .rax });
            try e.setcc(.ne, .{ .reg = .rax });
            try e.alu(.@"and", .byte, .{ .reg = .rdx }, .{ .reg = .rax });
            try e.alu(.@"or", .byte, .{ .reg = cg.r11() }, .{ .reg = .rdx });
        }
        for ([_][2]Operand{ .{ a[1], b[0] }, .{ a[0], b[1] } }) |x| {
            if (isZero(x[0]) or isZero(x[1])) continue;
            try e.mov(.qword, .{ .reg = .rax }, x[0]);
            try e.unary(.mul, .qword, try rm(cg, x[1], .rcx));
            try e.setcc(.b, .{ .reg = .rdx });
            try e.alu(.@"or", .byte, .{ .reg = cg.r11() }, .{ .reg = .rdx });
            try e.alu(.add, .qword, .{ .reg = .r10 }, .{ .reg = .rax });
            try e.setcc(.b, .{ .reg = .rdx });
            try e.alu(.@"or", .byte, .{ .reg = cg.r11() }, .{ .reg = .rdx });
        }
        try e.mov(.qword, .{ .reg = .rax }, a[0]);
        try e.unary(.mul, .qword, try rm(cg, b[0], .rcx));
        try e.alu(.add, .qword, .{ .reg = .rdx }, .{ .reg = .r10 });
        try e.setcc(.b, .{ .reg = .r10 });
        try e.alu(.@"or", .byte, .{ .reg = cg.r11() }, .{ .reg = .r10 });
    } else {
        const b1 = try aluSrc(cg, b[1]);
        const b0 = try aluSrc0(cg, b[0]);
        const ops: [2]Encoder.AluOp = if (tag == .add_with_overflow) .{ .add, .adc } else .{ .sub, .sbb };
        try e.mov(.qword, .{ .reg = .rax }, a[0]);
        try e.alu(ops[0], .qword, .{ .reg = .rax }, b0);
        try e.mov(.qword, .{ .reg = .rdx }, a[1]);
        try e.alu(ops[1], .qword, .{ .reg = .rdx }, b1);
        cc = if (signed) .o else .b;
        if (in_flags) {
            cg.ovf_cc = cc.?;
        } else if (!pair or fields[1] != Ssa.no_tie) {
            try e.setcc(cc.?, .{ .reg = cg.r11() });
            try e.movzx(.dword, cg.r11(), .byte, .{ .reg = cg.r11() });
        }
    }
    // Only moves from here on, which keep the flags.
    if (pair) {
        if (fields[0] != Ssa.no_tie) try finish(cg, @fromBackingInt(fields[0]), ty);
        if (fields[1] != Ssa.no_tie and !in_flags) try cg.setResult(@fromBackingInt(fields[1]), .u1_type, cg.r11());
        return;
    }
    const m = try cg.resultMem(inst, tuple_ty) orelse return;
    try e.mov(.qword, .{ .mem = m }, .{ .reg = .rax });
    try e.mov(.qword, .{ .mem = offsetMem(m, 8) }, .{ .reg = .rdx });
    try e.mov(.byte, .{ .mem = offsetMem(m, Type.fieldOffset(ip, tuple_ty, 1)) }, .{ .reg = cg.r11() });
}

/// `x` as an ALU source once rcx holds another immediate: a too-wide
/// immediate goes to r10, a scalar scratch register.
fn aluSrc0(cg: *CodeGen, x: Operand) Error!Operand {
    if (fitsImm32(x)) return x;
    try cg.e.mov(.qword, .{ .reg = .r10 }, x);
    return .{ .reg = .r10 };
}
