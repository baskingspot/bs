//! 128-bit integers (`u128`, `i128`) in register pairs: `CodeGen.inPair`
//! gives them two of x19-x28 (`Home.regs`, the low eightbyte in `lo`),
//! and the operations here compute them there instead of limb by limb in
//! memory (`CodeGen.genWide`): addition, subtraction, bitwise operations,
//! multiplication, shifts by constant amounts, casts, comparisons, and
//! overflow additions and subtractions. The other operations read them
//! from memory (`CodeGen.valMem`).
//!
//! Each operation reads its operands' halves where they are: a pair's
//! registers, a widened value's one register (`plan`), or x11-x14, loaded
//! from memory or with a constant. It computes the result in its own pair
//! when writing one half first overwrites no register it reads after
//! (`Out`), else in x9 and x10, which it then moves home.

const std = @import("std");
const Ir = @import("../../Ir.zig");
const Inst = Ir.Inst;
const Ref = Inst.Ref;
const InternPool = @import("../../InternPool.zig");
const Index = InternPool.Index;
const Type = @import("../../Type.zig");
const Encoder = @import("Encoder.zig");
const CodeGen = @import("CodeGen.zig");
const Ssa = @import("../Ssa.zig");
const Reg = Encoder.Reg;
const Cond = Encoder.Cond;
const Error = CodeGen.Error;

/// Whether `ty` is an integer type lowered here.
pub fn is128(ip: *const InternPool, ty: Index) bool {
    return Type.class(ip, ty) == .int and Type.intInfo(ip, ty).bits == 128;
}

/// Where `inst`'s result lives if `gen` computes it: in a pair, or in one
/// register (a truncation or a comparison).
pub fn lowers(cg: *CodeGen, inst: Inst.Index) ?enum { pair, gpr } {
    const ip = cg.ip;
    const data = cg.ir.instructions.items(.data)[@backingInt(inst)];
    const tag = cg.ir.instructions.items(.tag)[@backingInt(inst)];
    return switch (tag) {
        .add_wrap, .sub_wrap, .mul_wrap, .bit_and, .bit_or, .xor => if (is128(ip, cg.typeOf(data.bin_op.lhs))) .pair else null,
        .shl, .shr => if (is128(ip, cg.typeOf(data.bin_op.lhs)) and amount(cg, data.bin_op.rhs) != null) .pair else null,
        .not => if (is128(ip, data.ty_op.ty)) .pair else null,
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => if (is128(ip, cg.typeOf(data.bin_op.lhs))) .gpr else null,
        .intcast, .trunc, .bitcast => {
            const src_ty = cg.typeOf(data.ty_op.operand);
            if (is128(ip, data.ty_op.ty)) {
                if (is128(ip, src_ty)) return .pair;
                if (tag != .bitcast and Type.class(ip, src_ty) == .int and Type.intInfo(ip, src_ty).bits <= 64) return .pair;
                return null;
            }
            if (tag != .bitcast and is128(ip, src_ty) and Type.class(ip, data.ty_op.ty) == .int and Type.intInfo(ip, data.ty_op.ty).bits <= 64) return .gpr;
            return null;
        },
        else => null,
    };
}

/// Whether `inst` is an overflow operation on 128-bit integers that
/// `overflow` computes: addition, subtraction, and unsigned
/// multiplication.
pub fn isOverflow(cg: *CodeGen, inst: Inst.Index) bool {
    const tag = cg.ir.instructions.items(.tag)[@backingInt(inst)];
    switch (tag) {
        .add_with_overflow, .sub_with_overflow, .mul_with_overflow => {},
        else => return false,
    }
    const data = cg.ir.instructions.items(.data)[@backingInt(inst)];
    const ty = cg.typeOf(cg.ir.extraData(Ir.Bin, data.ty_pl.payload).data.lhs);
    return is128(cg.ip, ty) and (tag != .mul_with_overflow or Type.intInfo(cg.ip, ty).signedness == .unsigned);
}

/// Whether `inst` widens an integer of at most 64 bits to 128 bits.
fn isExt(cg: *CodeGen, inst: Inst.Index) bool {
    const ip = cg.ip;
    if (cg.ir.instructions.items(.tag)[@backingInt(inst)] != .intcast) return false;
    const data = cg.ir.instructions.items(.data)[@backingInt(inst)];
    if (!is128(ip, data.ty_op.ty)) return false;
    const src_ty = cg.typeOf(data.ty_op.operand);
    return Type.class(ip, src_ty) == .int and Type.intInfo(ip, src_ty).bits <= 64;
}

/// Before allocation: a widening of an integer of at most 64 bits that
/// only the operations here read (`half`) gets one register, which holds
/// the low half (the high half is its extension), or none: it is folded
/// into its operand's register, which lives as long as it does
/// (`Ssa.want_fold`, `CodeGen.pair_base`). Fiat-crypto's `mulxU64`
/// multiplies two of them. And a right shift by 64 or more that only a
/// truncation reads is not emitted: the truncation shifts the high half
/// (`gen`), which lives until it.
pub fn plan(cg: *CodeGen) Error!void {
    const f = cg.ssa;
    const live = f.live.slice();
    const reg = live.items(.reg);
    const uses = live.items(.uses);
    const fate = live.items(.fate);
    const def = live.items(.def);
    const end = live.items(.end);
    const crosses = live.items(.crosses);
    const share = live.items(.share);
    const fwd = live.items(.fwd);
    const cl = f.clobbers.items;
    const tags = cg.ir.instructions.items(.tag);
    const datas = cg.ir.instructions.items(.data);
    const T = struct {
        cg: *CodeGen,
        reg: []u8,
        n: *std.AutoHashMapUnmanaged(u32, u32),
        failed: bool = false,
        const Self = @This();
        pub fn use(t: *Self, ref: Ref) void {
            const c = ref.toIndex() orelse return;
            const ci = @backingInt(c);
            if (t.reg[ci] != Ssa.want_pair or !isExt(t.cg, c)) return;
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
        if (fate[@backingInt(v)] == .dead) continue;
        if (lowers(cg, v) != null or isOverflow(cg, v)) Ssa.forEachOperand(cg.ir, v, &t);
    }
    if (t.failed) return error.OutOfMemory;
    // The shifts first: a widening a folded shift read lives until the
    // truncation when it takes its operand's register below.
    for (f.values.items(.inst)) |v| {
        const vi = @backingInt(v);
        if (fate[vi] != .normal or tags[vi] != .trunc or lowers(cg, v) != .gpr) continue;
        const sh = datas[vi].ty_op.operand.toIndex() orelse continue;
        const si = @backingInt(sh);
        if (tags[si] != .shr or fate[si] != .normal or uses[si] != 1) continue;
        if (lowers(cg, sh) != .pair or amount(cg, datas[si].bin_op.rhs).? < 64) continue;
        if (datas[si].bin_op.lhs.toIndex()) |x| {
            const xi = @backingInt(x);
            if (fate[xi] != .normal or share[xi] != Ssa.no_tie) continue;
            end[xi] = @max(end[xi], def[vi]);
            crosses[xi] = crosses[xi] or cl[def[vi]][0] != cl[def[xi]][0] or cl[def[vi]][1] != cl[def[xi]][1];
        }
        fate[si] = .dead;
        reg[si] = Ssa.no_reg;
    }
    var it = n.iterator();
    while (it.next()) |e| {
        const ci = e.key_ptr.*;
        if (fate[ci] != .normal or uses[ci] != e.value_ptr.*) continue;
        reg[ci] = Ssa.want_reg;
        // Not an operand whose interval decided more than its own
        // register: a load sharing its variable's, or a forwarded one.
        const src = datas[ci].ty_op.operand.toIndex() orelse continue;
        const si = @backingInt(src);
        if (fate[si] != .normal or reg[si] != Ssa.want_reg or share[si] != Ssa.no_tie or fwd[si] != Ssa.no_tie) continue;
        end[si] = @max(end[si], end[ci]);
        crosses[si] = crosses[si] or crosses[ci] or cl[end[si]][0] != cl[def[si]][0];
        reg[ci] = Ssa.want_fold;
        cg.pair_base[ci] = si;
    }
    // A truncation to 64 bits reads a pair's low half, or its high half
    // through a shift by 64 folded above, and takes no register of its
    // own when the pair has them: its users read the pair's (`gen`).
    for (f.values.items(.inst)) |v| {
        const vi = @backingInt(v);
        if (fate[vi] != .normal or reg[vi] != Ssa.want_reg or lowers(cg, v) != .gpr) continue;
        if (tags[vi] != .trunc and tags[vi] != .intcast) continue;
        if (Type.intInfo(cg.ip, datas[vi].ty_op.ty).bits != 64) continue;
        var b = datas[vi].ty_op.operand.toIndex() orelse continue;
        if (fate[@backingInt(b)] == .dead) {
            const bin = datas[@backingInt(b)].bin_op;
            if (amount(cg, bin.rhs).? != 64) continue;
            b = bin.lhs.toIndex() orelse continue;
        }
        const bi = @backingInt(b);
        if (fate[bi] != .normal or reg[bi] != Ssa.want_pair or share[bi] != Ssa.no_tie or fwd[bi] != Ssa.no_tie) continue;
        end[bi] = @max(end[bi], end[vi]);
        crosses[bi] = crosses[bi] or crosses[vi] or cl[end[bi]][0] != cl[def[bi]][0];
        reg[vi] = Ssa.want_fold;
        cg.pair_base[vi] = bi;
    }
}

/// A shift amount's value if it is a constant below 128.
fn amount(cg: *CodeGen, ref: Ref) ?u7 {
    const v = ref.toInterned() orelse return null;
    if (cg.ip.keyTag(v) != .int) return null;
    return switch (cg.ip.keyPayload(.int, v).storage) {
        .u64 => |u| if (u < 128) @intCast(u) else null,
        .i64 => |i| if (i >= 0 and i < 128) @intCast(i) else null,
        .big => null,
    };
}

/// The bits of 128-bit constant `v`.
fn constBits(cg: *CodeGen, v: Index) u128 {
    if (cg.ip.keyTag(v) == .undef) return ~@as(u128, 0) / 3 * 2;
    return switch (cg.ip.keyPayload(.int, v).storage) {
        .u64 => |u| u,
        .i64 => |i| @bitCast(@as(i128, i)),
        .big => |b| if (b.positive) b.toInt(u128) catch unreachable else @bitCast(b.toInt(i128) catch unreachable),
    };
}

/// The low half of 128-bit `ref` if it is a constant whose low half an
/// add or compare takes as an immediate.
fn lowImm(cg: *CodeGen, ref: Ref) ?u32 {
    const v = ref.toInterned() orelse return null;
    const lo: u64 = @truncate(constBits(cg, v));
    return if (lo < 4096) @intCast(lo) else null;
}

/// Half `i` (0 the low one) of 128-bit value `ref` in a register: its
/// own, zr for a zero constant, or `scratch`, loaded with it.
fn half(cg: *CodeGen, ref: Ref, i: u1, scratch: Reg) Error!Reg {
    if (ref.toInterned()) |v| {
        const x: u64 = @truncate(constBits(cg, v) >> @as(u7, i) * 64);
        if (x == 0) return .zr;
        try cg.e.movImm(.x, scratch, x);
        return scratch;
    }
    const inst = ref.toIndex().?;
    switch (cg.homes[@backingInt(inst)]) {
        .regs => |p| return if (i == 0) p.lo else p.hi,
        // A widening in one register, its own or its operand's (`plan`),
        // extended by its operand's signedness.
        .reg => |r| {
            if (i == 0) return r;
            const src_ty = cg.typeOf(cg.ir.instructions.items(.data)[@backingInt(inst)].ty_op.operand);
            if (Type.intInfo(cg.ip, src_ty).signedness == .unsigned) return .zr;
            try cg.e.shiftImm(.asr, .x, scratch, r, 63);
            return scratch;
        },
        else => {},
    }
    try cg.ldrLimb(scratch, try cg.memOf(ref), i);
    return scratch;
}

/// Loads 128-bit constant `v` into `d`.
pub fn loadConst(cg: *CodeGen, d: CodeGen.Regs, v: Index) Error!void {
    const bits = constBits(cg, v);
    try cg.e.movImm(.x, d.lo, @truncate(bits));
    try cg.e.movImm(.x, d.hi, @truncate(bits >> 64));
}

/// Half `i` of `ref` as the second operand of a logical instruction.
fn logicSrc(cg: *CodeGen, ref: Ref, i: u1, scratch: Reg) Error!Encoder.LogicOperand {
    if (ref.toInterned()) |v| {
        const x: u64 = @truncate(constBits(cg, v) >> @as(u7, i) * 64);
        if (x != 0 and Encoder.bitmaskImm(.x, x) != null) return .{ .imm = x };
    }
    return .r(try half(cg, ref, i, scratch));
}

/// Where an operation computes its result: `lo` and `hi`, which are
/// `inst`'s own pair or x9 and x10.
const Out = struct {
    lo: Reg,
    hi: Reg,
    own: bool,

    const scratch: Out = .{ .lo = .x9, .hi = .x10, .own = false };

    /// `inst`'s pair if writing its low half overwrites none of
    /// `after_lo` (read after it is written) and its high half none of
    /// `after_hi`.
    fn pick(cg: *CodeGen, inst: Inst.Index, after_lo: []const Reg, after_hi: []const Reg) Out {
        const p = cg.pairOf(inst.toRef()) orelse return scratch;
        if (std.mem.findScalar(Reg, after_lo, p.lo) != null) return scratch;
        if (std.mem.findScalar(Reg, after_hi, p.hi) != null) return scratch;
        return .{ .lo = p.lo, .hi = p.hi, .own = true };
    }

    /// Moves the result to `inst`'s home if it is not computed there.
    /// Changes no flags.
    fn finish(o: Out, cg: *CodeGen, inst: Inst.Index, ty: Index) Error!void {
        if (o.own) return;
        if (cg.pairOf(inst.toRef())) |p| {
            try cg.e.mov(.x, p.lo, o.lo);
            return cg.e.mov(.x, p.hi, o.hi);
        }
        const m = try cg.resultMem(inst, ty) orelse return;
        try cg.storeRegsMem(m, .{ .lo = o.lo, .hi = o.hi });
    }
};

/// `mov dst, src` unless `src` is `dst`.
fn mov(cg: *CodeGen, dst: Reg, src: Reg) Error!void {
    if (dst != src) try cg.e.mov(.x, dst, src);
}

pub fn gen(cg: *CodeGen, inst: Inst.Index, tag: Inst.Tag, data: Inst.Data) Error!void {
    const ip = cg.ip;
    const e = &cg.e;
    switch (tag) {
        .add_wrap, .sub_wrap => {
            const ty = cg.typeOf(data.bin_op.lhs);
            var lhs = data.bin_op.lhs;
            var rhs = data.bin_op.rhs;
            if (tag == .add_wrap and lhs.toInterned() != null) std.mem.swap(Ref, &lhs, &rhs);
            const add = tag == .add_wrap;
            const a0 = try half(cg, lhs, 0, .x11);
            const a1 = try half(cg, lhs, 1, .x12);
            // An immediate's base register may not be zr, which encodes sp.
            const imm = if (a0 != .zr) lowImm(cg, rhs) else null;
            const b0: Reg = if (imm == null) try half(cg, rhs, 0, .x13) else .zr;
            const b1 = try half(cg, rhs, 1, .x14);
            const b: Encoder.AddOperand = if (imm) |k| .{ .imm = k } else .r(b0);
            const o = Out.pick(cg, inst, &.{ a1, b1 }, &.{});
            try e.addSub(if (add) .adds else .subs, .x, o.lo, a0, b);
            try e.carry(if (add) .adc else .sbc, .x, o.hi, a1, b1);
            try o.finish(cg, inst, ty);
        },
        .bit_and, .bit_or, .xor => {
            const ty = cg.typeOf(data.bin_op.lhs);
            var lhs = data.bin_op.lhs;
            var rhs = data.bin_op.rhs;
            if (lhs.toInterned() != null) std.mem.swap(Ref, &lhs, &rhs);
            const op: Encoder.LogicOp = switch (tag) {
                .bit_and => .@"and",
                .bit_or => .orr,
                else => .eor,
            };
            const a0 = try half(cg, lhs, 0, .x11);
            const a1 = try half(cg, lhs, 1, .x12);
            const b0 = try logicSrc(cg, rhs, 0, .x13);
            const b1 = try logicSrc(cg, rhs, 1, .x14);
            const o = Out.pick(cg, inst, &.{ a1, if (b1 == .reg) b1.reg.reg else .zr }, &.{});
            try e.logic(op, .x, o.lo, a0, b0);
            try e.logic(op, .x, o.hi, a1, b1);
            try o.finish(cg, inst, ty);
        },
        .not => {
            const a0 = try half(cg, data.ty_op.operand, 0, .x11);
            const a1 = try half(cg, data.ty_op.operand, 1, .x12);
            const o = Out.pick(cg, inst, &.{a1}, &.{});
            try e.mvn(.x, o.lo, a0);
            try e.mvn(.x, o.hi, a1);
            try o.finish(cg, inst, data.ty_op.ty);
        },
        .mul_wrap => {
            const ty = cg.typeOf(data.bin_op.lhs);
            const lhs = data.bin_op.lhs;
            const rhs = data.bin_op.rhs;
            if (cg.factorExt(lhs)) |fa| if (cg.factorExt(rhs)) |fb| {
                // A product of extended 64-bit values (`CodeGen.mulExt`).
                const x = try half(cg, lhs, 0, .x11);
                const y = try half(cg, rhs, 0, .x12);
                const o = Out.pick(cg, inst, &.{}, &.{ x, y });
                try cg.mulExt(o.lo, o.hi, x, y, fa, fb);
                return o.finish(cg, inst, ty);
            };
            // The high half of a0 * b0, plus the low halves of the cross
            // products, then the low half.
            const a0 = try half(cg, lhs, 0, .x11);
            const a1 = try half(cg, lhs, 1, .x12);
            const b0 = try half(cg, rhs, 0, .x13);
            const b1 = try half(cg, rhs, 1, .x14);
            const o = Out.pick(cg, inst, &.{}, &.{ a0, a1, b0, b1 });
            try e.mulHigh(false, o.hi, a0, b0);
            if (a1 != .zr and b0 != .zr) try e.mulAdd(.madd, .x, o.hi, a1, b0, o.hi);
            if (a0 != .zr and b1 != .zr) try e.mulAdd(.madd, .x, o.hi, a0, b1, o.hi);
            try e.mul(.x, o.lo, a0, b0);
            try o.finish(cg, inst, ty);
        },
        .shl, .shr => {
            const ty = cg.typeOf(data.bin_op.lhs);
            const a0 = try half(cg, data.bin_op.lhs, 0, .x11);
            const a1 = try half(cg, data.bin_op.lhs, 1, .x12);
            const k = amount(cg, data.bin_op.rhs).?;
            const right: Encoder.Shift = if (Type.intInfo(ip, ty).signedness == .signed) .asr else .lsr;
            if (k == 0) {
                const o = Out.pick(cg, inst, &.{a1}, &.{});
                try mov(cg, o.lo, a0);
                try mov(cg, o.hi, a1);
                return o.finish(cg, inst, ty);
            }
            if (k < 64) {
                const r: u6 = @intCast(k);
                if (tag == .shl) {
                    // The high half first: (a1:a0) >> (64 - k).
                    const o = Out.pick(cg, inst, &.{}, &.{a0});
                    try e.extr(.x, o.hi, a1, a0, @intCast(64 - @as(u7, r)));
                    try e.shiftImm(.lsl, .x, o.lo, a0, r);
                    return o.finish(cg, inst, ty);
                }
                const o = Out.pick(cg, inst, &.{a1}, &.{});
                try e.extr(.x, o.lo, a1, a0, r);
                try e.shiftImm(right, .x, o.hi, a1, r);
                return o.finish(cg, inst, ty);
            }
            const r: u6 = @intCast(k - 64);
            if (tag == .shl) {
                // The low half moves up; zeros below.
                const o = Out.pick(cg, inst, &.{}, &.{});
                if (r == 0) try mov(cg, o.hi, a0) else try e.shiftImm(.lsl, .x, o.hi, a0, r);
                try e.mov(.x, o.lo, .zr);
                return o.finish(cg, inst, ty);
            }
            // The high half moves down; its sign or zeros above.
            const o = Out.pick(cg, inst, &.{a1}, &.{});
            if (r == 0) try mov(cg, o.lo, a1) else try e.shiftImm(right, .x, o.lo, a1, r);
            if (right == .asr) try e.shiftImm(.asr, .x, o.hi, a1, 63) else try e.mov(.x, o.hi, .zr);
            try o.finish(cg, inst, ty);
        },
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => try cg.genCond(inst),
        .intcast, .trunc, .bitcast => {
            const ty = data.ty_op.ty;
            const src = data.ty_op.operand;
            const src_ty = cg.typeOf(src);
            if (!is128(ip, ty)) {
                const sh = src.toIndex();
                if (cg.ssa.live.items(.reg)[@backingInt(inst)] == Ssa.folded) {
                    // A half of its pair's (`plan`).
                    const p = cg.homes[cg.pair_base[@backingInt(inst)]].regs;
                    cg.homes[@backingInt(inst)] = .{ .reg = if (cg.fate(sh.?) == .dead) p.hi else p.lo };
                    return;
                }
                const d = cg.resultReg(inst, .x9);
                if (sh != null and cg.fate(sh.?) == .dead) {
                    // The high half of a right shift by 64 or more (`plan`).
                    const bin = cg.ir.instructions.items(.data)[@backingInt(sh.?)].bin_op;
                    const r: u6 = @intCast(amount(cg, bin.rhs).? - 64);
                    const h = try half(cg, bin.lhs, 1, .x12);
                    const right: Encoder.Shift = if (Type.intInfo(ip, cg.typeOf(bin.lhs)).signedness == .signed) .asr else .lsr;
                    if (r == 0) try mov(cg, d, h) else try e.shiftImm(right, .x, d, h, r);
                } else {
                    // The low half, truncated.
                    try mov(cg, d, try half(cg, src, 0, .x11));
                }
                try cg.normalize(d, ty);
                return cg.setResult(inst, ty, d);
            }
            if (is128(ip, src_ty)) {
                const a0 = try half(cg, src, 0, .x11);
                const a1 = try half(cg, src, 1, .x12);
                const o = Out.pick(cg, inst, &.{a1}, &.{});
                try mov(cg, o.lo, a0);
                try mov(cg, o.hi, a1);
                return o.finish(cg, inst, ty);
            }
            // Folded: its operand's register (`plan`).
            if (cg.ssa.live.items(.reg)[@backingInt(inst)] == Ssa.folded) {
                cg.homes[@backingInt(inst)] = .{ .reg = cg.homes[cg.pair_base[@backingInt(inst)]].reg };
                return;
            }
            // Its low half only (`plan`).
            if (cg.homes[@backingInt(inst)] == .reg) return cg.load(cg.homes[@backingInt(inst)].reg, src);
            // Extended by the operand's signedness, as its register holds it.
            const a = try cg.use(src, .x11);
            const o = Out.pick(cg, inst, &.{}, &.{});
            try mov(cg, o.lo, a);
            if (Type.intInfo(ip, src_ty).signedness == .signed) {
                try e.shiftImm(.asr, .x, o.hi, o.lo, 63);
            } else try e.mov(.x, o.hi, .zr);
            try o.finish(cg, inst, ty);
        },
        else => unreachable,
    }
}

/// Sets the flags of comparison `tag` of 128-bit integers `lhs` and
/// `rhs`, and returns the condition under which it holds.
pub fn cmpFlags(cg: *CodeGen, tag: Inst.Tag, lhs: Ref, rhs: Ref) Error!Cond {
    const e = &cg.e;
    var a = lhs;
    var b = rhs;
    // The flags of a - b over both halves: `>` and `<=` swap.
    if (tag == .cmp_gt or tag == .cmp_lte) std.mem.swap(Ref, &a, &b);
    const a0 = try half(cg, a, 0, .x11);
    const a1 = try half(cg, a, 1, .x12);
    const imm = if (a0 != .zr) lowImm(cg, b) else null;
    const b0: Reg = if (imm == null) try half(cg, b, 0, .x13) else .zr;
    const b1 = try half(cg, b, 1, .x14);
    const b_lo: Encoder.AddOperand = if (imm) |k| .{ .imm = k } else .r(b0);
    try e.cmp(.x, a0, b_lo);
    if (tag == .cmp_eq or tag == .cmp_neq) {
        // The high halves' compare if the low halves are equal, else ne.
        try e.ccmp(false, .x, a1, .{ .reg = b1 }, 0, .eq);
        return if (tag == .cmp_eq) .eq else .ne;
    }
    try e.carry(.sbcs, .x, .zr, a1, b1);
    const s = Type.intInfo(cg.ip, cg.typeOf(lhs)).signedness == .signed;
    return switch (tag) {
        .cmp_lt, .cmp_gt => if (s) .lt else .lo,
        else => if (s) .ge else .hs,
    };
}

/// An overflow operation on 128-bit integers (`isOverflow`): the value in
/// x10:x9 and the bit from the flags (addition, subtraction) or in x11
/// (multiplication), then written to the fields' homes when they have
/// their own (`Ssa.pairs`), else to the tuple's memory; a fused bit stays
/// in the flags (`CodeGen.ovf_cc`).
pub fn overflow(cg: *CodeGen, inst: Inst.Index, tag: Inst.Tag, data: Inst.Data) Error!void {
    const ip = cg.ip;
    const e = &cg.e;
    const bin = cg.ir.extraData(Ir.Bin, data.ty_pl.payload).data;
    const tuple_ty = data.ty_pl.ty;
    const ty = cg.typeOf(bin.lhs);
    const pair = cg.fate(inst) == .pair;
    const fields = if (pair) cg.ssa.pairs.get(@backingInt(inst)).? else .{ Ssa.no_tie, Ssa.no_tie };
    const in_flags = fields[1] != Ssa.no_tie and cg.fate(@fromBackingInt(fields[1])) == .fused;
    if (tag == .mul_with_overflow) {
        try mulOverflow(cg, bin.lhs, bin.rhs);
    } else {
        const add = tag == .add_with_overflow;
        const a0 = try half(cg, bin.lhs, 0, .x11);
        const a1 = try half(cg, bin.lhs, 1, .x12);
        const imm = if (a0 != .zr) lowImm(cg, bin.rhs) else null;
        const b0: Reg = if (imm == null) try half(cg, bin.rhs, 0, .x13) else .zr;
        const b1 = try half(cg, bin.rhs, 1, .x14);
        const b_lo: Encoder.AddOperand = if (imm) |k| .{ .imm = k } else .r(b0);
        try e.addSub(if (add) .adds else .subs, .x, .x9, a0, b_lo);
        try e.carry(if (add) .adcs else .sbcs, .x, .x10, a1, b1);
        const cc: Cond = if (Type.intInfo(ip, ty).signedness == .signed) .vs else if (add) .hs else .lo;
        if (in_flags) cg.ovf_cc = cc else try e.cset(.x, .x11, cc);
    }
    // Only moves and stores from here on, which keep the flags.
    if (pair) {
        if (fields[0] != Ssa.no_tie) try Out.scratch.finish(cg, @fromBackingInt(fields[0]), ty);
        if (fields[1] != Ssa.no_tie and !in_flags) try cg.setResult(@fromBackingInt(fields[1]), .u1_type, .x11);
        return;
    }
    const m = try cg.resultMem(inst, tuple_ty) orelse return;
    try cg.storeRegsMem(m, .{ .lo = .x9, .hi = .x10 });
    try cg.storeReg(m.plus(Type.fieldOffset(ip, tuple_ty, 1)), .x11, 1);
}

/// The unsigned product of 128-bit `lhs` and `rhs` in x10:x9 and whether
/// it overflowed in x11. With a = a1:a0 and b = b1:b0, it overflows when
/// a1 and b1 are both nonzero, when a1 * b0 or a0 * b1 needs more than 64
/// bits, or when adding their low halves, or their sum to the high half
/// of a0 * b0, carries. The bit collects in x16, the cross sum in x10;
/// x17 holds the second cross product, then the high half of a0 * b0.
/// Halves known zero (widened operands, constants) drop their terms. Not
/// x15, which holds the error return trace pointer (`trace_x15`).
fn mulOverflow(cg: *CodeGen, lhs: Ref, rhs: Ref) Error!void {
    const e = &cg.e;
    const a0 = try half(cg, lhs, 0, .x11);
    const a1 = try half(cg, lhs, 1, .x12);
    const b0 = try half(cg, rhs, 0, .x13);
    const b1 = try half(cg, rhs, 1, .x14);
    try e.mov(.x, .x16, .zr);
    if (a1 != .zr and b1 != .zr) {
        // Z set (equal) when a1 is zero, else b1's compare.
        try e.cmp(.x, a1, .{ .imm = 0 });
        try e.ccmp(false, .x, b1, .{ .imm = 0 }, 0b0100, .ne);
        try e.cset(.x, .x16, .ne);
    }
    const c1 = a1 != .zr and b0 != .zr;
    const c2 = a0 != .zr and b1 != .zr;
    if (c1 or c2) {
        if (c1) try e.mulHigh(false, .x10, a1, b0);
        if (c2) try e.mulHigh(false, .x17, a0, b1);
        if (c1 and c2) try e.logic(.orr, .x, .x10, .x10, .r(.x17));
        try e.cmp(.x, if (c1) .x10 else .x17, .{ .imm = 0 });
        try e.csel(.csinc, .x, .x16, .x16, .zr, .eq);
        if (c1) try e.mul(.x, .x10, a1, b0);
        if (c2) try e.mul(.x, .x17, a0, b1);
        if (c1 and c2) {
            try e.addSub(.adds, .x, .x10, .x10, .r(.x17));
            try e.csel(.csinc, .x, .x16, .x16, .zr, .lo);
        } else if (c2) try e.mov(.x, .x10, .x17);
        try e.mulHigh(false, .x17, a0, b0);
        try e.addSub(.adds, .x, .x10, .x10, .r(.x17));
        try e.csel(.csinc, .x, .x16, .x16, .zr, .lo);
    } else try e.mulHigh(false, .x10, a0, b0);
    try e.mul(.x, .x9, a0, b0);
    try e.mov(.x, .x11, .x16);
}
