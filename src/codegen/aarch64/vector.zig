//! aarch64 lowering of the vector operations that `../vector.zig` accepts:
//! NEON (Advanced SIMD) on V registers, 16 bytes of lanes at a time
//! (docs/slop/architecture.md, "Vectors").
//!
//! Values: a vector of at most 16 bytes may live in one of v20-v29
//! (`inVreg`, `CodeGen.allocateRegs`); others live in stack slots. Each
//! operation reads its operands' 16-byte chunks from their registers or
//! loads them into scratch V registers, computes, and writes the result's
//! chunks to its register or slot. A vector of less than 16 bytes (its
//! size is a power of two, `Type.abiSize`) is loaded with the load of its
//! size, which zeroes the rest of the register; lane-wise operations run
//! on the whole register and store the vector's bytes, so a vector's own
//! register holds anything past its bytes.
//! Bool vectors of up to 64 elements are their bits in memory or a
//! general-purpose register (element `i` is bit `i`; bits above the
//! length are 0), as on x86_64, except those that live as lane masks in
//! a V register ("Lane masks" below). Lanes past a vector's length (the padding
//! of a `@Vector(3, u32)`) hold anything; compares and reductions ignore
//! them.
//!
//! Scratch: v0-v7, v16-v19, v30 and v31 (no value lives there), x9-x14 as
//! the scalar lowerings use them, and x16 and x17 for addresses.

const std = @import("std");
const InternPool = @import("../../InternPool.zig");
const Index = InternPool.Index;
const Ir = @import("../../Ir.zig");
const Inst = Ir.Inst;
const Ref = Inst.Ref;
const Type = @import("../../Type.zig");
const Encoder = @import("Encoder.zig");
const CodeGen = @import("CodeGen.zig");
const Ssa = @import("../Ssa.zig");
const shared = @import("../vector.zig");
const Lane = shared.Lane;
const Reg = Encoder.Reg;
const VReg = Encoder.VReg;
const Mem = CodeGen.Mem;
const Error = CodeGen.Error;

/// A vector type lowered as lanes.
const Shape = struct {
    lane: Lane,
    len: u32,
    /// The type's size: a power of two, below 16 or a multiple of it.
    size: u32,

    /// The 16-byte chunks holding lanes; the rest of a vector whose size
    /// rounds up to a power of two is padding.
    fn chunks(s: Shape) u32 {
        return (s.len * s.lane.bytes() + 15) / 16;
    }

    /// Lanes in a 16-byte register.
    fn perReg(s: Shape) u32 {
        return 16 / s.lane.bytes();
    }

    /// The NEON element size field: 0 for bytes up to 3 for 64-bit lanes.
    fn esize(s: Shape) u2 {
        return laneSize(s.lane);
    }

    /// The float `sz` bit: 0 for f32, 1 for f64.
    fn sz(s: Shape) u1 {
        return @intFromBool(s.lane == .f64);
    }
};

fn laneSize(l: Lane) u2 {
    return switch (l.bytes()) {
        1 => 0,
        2 => 1,
        4 => 2,
        8 => 3,
        else => unreachable,
    };
}

fn shape(ip: *const InternPool, ty: Index) ?Shape {
    const l = shared.lane(ip, ty) orelse return null;
    if (l == .bool) return null;
    const len = ip.keyPayload(.vector_type, ty).len;
    if (len == 0 or len * l.bytes() > shared.max_bytes) return null;
    return .{ .lane = l, .len = len, .size = @intCast(Type.abiSize(ip, ty)) };
}

/// Whether `ty` is a bool vector kept as its bits.
fn isBits(ip: *const InternPool, ty: Index) bool {
    if (ip.keyTag(ty) != .vector_type) return false;
    const v = ip.keyPayload(.vector_type, ty);
    return v.child == .bool_type and v.len != 0 and v.len <= shared.max_bools;
}

/// Whether `inst`, an instruction on vectors, is lowered here. Sema emits
/// these on vectors only when `shared.native` says so.
pub fn lowers(cg: *CodeGen, inst: Inst.Index) bool {
    const ip = cg.ip;
    const ir = cg.ir;
    const data = ir.instructions.items(.data)[@backingInt(inst)];
    return switch (ir.instructions.items(.tag)[@backingInt(inst)]) {
        .cmp_vector, .reduce, .select, .shuffle, .min_int, .max_int => true,
        .add_wrap, .sub_wrap, .mul_wrap, .bit_and, .bit_or, .xor, .shl, .shr, .add_float, .sub_float, .mul_float, .div_float, .min_float, .max_float => ip.keyTag(cg.typeOf(data.bin_op.lhs)) == .vector_type,
        .neg_float, .abs_float, .sqrt => ip.keyTag(cg.typeOf(data.un_op)) == .vector_type,
        .not, .intcast, .trunc => ip.keyTag(data.ty_op.ty) == .vector_type,
        .aggregate_init => isSplat(cg, data),
        .bitcast => storedBitcast(cg, inst) or maskLane(cg, data.ty_op.operand) != null,
        .load => loadedBitcast(cg, inst) != null,
        else => false,
    };
}

/// Whether `aggregate_init` `data` broadcasts one element to a vector of
/// lanes.
fn isSplat(cg: *CodeGen, data: Inst.Data) bool {
    if (shape(cg.ip, data.ty_pl.ty) == null) return false;
    const extra = cg.ir.extraData(Ir.Aggregate, data.ty_pl.payload);
    const elems = cg.ir.refSlice(extra.end, extra.data.len);
    if (elems[0].toInterned()) |v| if (cg.ip.keyTag(v) == .undef) return false;
    for (elems[1..]) |x| if (x != elems[0]) return false;
    return true;
}

pub fn gen(cg: *CodeGen, inst: Inst.Index, tag: Inst.Tag, data: Inst.Data) Error!void {
    const ip = cg.ip;
    switch (tag) {
        // A mask's bits, or nothing: the store after it stores the
        // operand (`stored`).
        .bitcast => if (maskLane(cg, data.ty_op.operand) != null) {
            try bitsOf(cg, .x10, data.ty_op.operand);
            try cg.setResult(inst, data.ty_op.ty, .x10);
        },
        .load => {}, // the bitcast after it loads (`loaded`)
        .intcast, .trunc => try cast(cg, inst, data.ty_op.ty, data.ty_op.operand),
        .cmp_vector => {
            if (absorbed(cg, inst)) return; // computed by its reduce
            const x = cg.ir.extraData(Ir.VectorCmp, data.ty_pl.payload).data;
            if (maskLane(cg, inst.toRef()) != null) {
                const src_ty = cg.typeOf(x.lhs);
                return compareMask(cg, shape(ip, src_ty).?, isSigned(cg, src_ty), x.operator(), x.lhs, x.rhs, 0, cg.homes[@backingInt(inst)].vreg);
            }
            try compare(cg, inst, data.ty_pl.ty, x.operator(), x.lhs, x.rhs);
        },
        .reduce => {
            if (cg.fate(inst) == .fused) return; // read by its branch
            const x = cg.ir.extraData(Ir.Reduce, data.ty_pl.payload).data;
            if (isBits(ip, cg.typeOf(x.operand))) {
                const cond = try condFlags(cg, inst);
                try cg.e.cset(.x, .x9, cond);
                return cg.setResult(inst, .bool_type, .x9);
            }
            if (indexSelect(cg, inst)) |sel| return reduceIndex(cg, inst, data.ty_pl.ty, x.operation(), sel);
            try reduce(cg, inst, data.ty_pl.ty, x.operation(), x.operand);
        },
        .select => {
            if (absorbed(cg, inst)) return; // read by its reduce
            const x = cg.ir.extraData(Ir.Select, data.ty_pl.payload).data;
            try select(cg, inst, data.ty_pl.ty, x.pred, x.a, x.b);
        },
        .shuffle => {
            const x = cg.ir.extraData(Ir.Shuffle, data.ty_pl.payload).data;
            try shuffle(cg, inst, data.ty_pl.ty, x.a, x.b, x.mask);
        },
        .shl, .shr => try shift(cg, inst, tag == .shl, cg.typeOf(data.bin_op.lhs), data.bin_op.lhs, data.bin_op.rhs),
        .neg_float, .abs_float, .sqrt => {
            const ty = cg.typeOf(data.un_op);
            const s = shape(ip, ty).?;
            const dst = try dest(cg, inst, ty) orelse return;
            const u: u1, const op: u5 = switch (tag) {
                .neg_float => .{ 1, 0b01111 },
                .abs_float => .{ 0, 0b01111 },
                .sqrt => .{ 1, 0b11111 },
                else => unreachable,
            };
            for (0..s.chunks()) |k| {
                const r = destReg(dst, .v0);
                try emit(cg, misc(u, 0b10 | @as(u2, s.sz()), op, r, try srcChunk(cg, data.un_op, @intCast(k), .v0)));
                try storeChunk(cg, dst, r, s, @intCast(k));
            }
        },
        .aggregate_init => {
            const extra = cg.ir.extraData(Ir.Aggregate, data.ty_pl.payload);
            try splat(cg, inst, data.ty_pl.ty, cg.ir.refSlice(extra.end, extra.data.len)[0]);
        },
        .not => {
            const ty = data.ty_op.ty;
            if (isBits(ip, ty)) {
                if (maskLane(cg, inst.toRef())) |w| {
                    const a = try maskChunk(cg, data.ty_op.operand, 0, w, .v0);
                    return emit(cg, misc(1, 0, 0b00101, cg.homes[@backingInt(inst)].vreg, a));
                }
                const len = ip.keyPayload(.vector_type, ty).len;
                try bitsOf(cg, .x9, data.ty_op.operand);
                if (len == 64) try cg.e.mvn(.x, .x9, .x9) else try cg.e.logic(.eor, .x, .x9, .x9, .{ .imm = lenMask(len) });
                return cg.setResult(inst, ty, .x9);
            }
            const s = shape(ip, ty).?;
            const dst = try dest(cg, inst, ty) orelse return;
            for (0..s.chunks()) |k| {
                const r = destReg(dst, .v0);
                try emit(cg, misc(1, 0, 0b00101, r, try srcChunk(cg, data.ty_op.operand, @intCast(k), .v0)));
                try storeChunk(cg, dst, r, s, @intCast(k));
            }
        },
        else => {
            const ty = cg.typeOf(data.bin_op.lhs);
            if (isBits(ip, ty)) {
                if (maskLane(cg, inst.toRef())) |w| {
                    const a = try maskChunk(cg, data.bin_op.lhs, 0, w, .v0);
                    const b = try maskChunk(cg, data.bin_op.rhs, 0, w, .v1);
                    return bitwise(cg, switch (tag) {
                        .bit_and => .@"and",
                        .bit_or => .orr,
                        .xor => .eor,
                        else => unreachable,
                    }, cg.homes[@backingInt(inst)].vreg, a, b);
                }
                try bitsOf(cg, .x9, data.bin_op.lhs);
                try bitsOf(cg, .x10, data.bin_op.rhs);
                try cg.e.logic(switch (tag) {
                    .bit_and => .@"and",
                    .bit_or => .orr,
                    .xor => .eor,
                    else => unreachable,
                }, .x, .x9, .x9, .r(.x10));
                return cg.setResult(inst, ty, .x9);
            }
            try arith(cg, inst, tag, ty, data.bin_op.lhs, data.bin_op.rhs);
        },
    }
}

// ---------------------------------------------------------------------------
// Fusion
//
// A compare or select whose only user is the reduce right after it in its
// block is not emitted (`absorbed`): the reduce computes from its operands,
// which nothing between overwrites, since no value is defined between
// (and, for a reduce its branch computes, none after it either). A
// bitcast of a vector whose only user is the store right after it is not
// emitted either (`storedBitcast`).

fn isDbg(tag: Inst.Tag) bool {
    return tag == .dbg_stmt or tag == .dbg_inline_begin or tag == .dbg_inline_end;
}

/// The values of the block being emitted from `inst` on, or null when
/// liveness did not run.
fn fromHere(cg: *CodeGen, inst: Inst.Index) ?[]const Inst.Index {
    if (!cg.live or cg.block == .none) return null;
    const b = cg.ssa.blocks.items[@backingInt(cg.block)];
    const i = (cg.ssa.live.items(.def)[@backingInt(inst)] - 2) / 2;
    if (i < b.start or i >= b.start + b.len) return null;
    const insts = cg.ssa.blockInsts(cg.block)[i - b.start ..];
    std.debug.assert(insts[0] == inst);
    return insts;
}

/// The reduce that absorbs operand `x` of it, a compare or select used
/// only by it, if it is the next value after `x` in the block.
fn absorber(cg: *CodeGen, x: Inst.Index) ?Inst.Index {
    const live = cg.ssa.live.slice();
    if (live.items(.uses)[@backingInt(x)] != 1 or live.items(.fate)[@backingInt(x)] != .normal) return null;
    const insts = fromHere(cg, x) orelse return null;
    const tags = cg.ir.instructions.items(.tag);
    for (insts[1..], 1..) |r, j| {
        if (isDbg(tags[@backingInt(r)])) continue;
        if (tags[@backingInt(r)] != .reduce) return null;
        const red = cg.ir.extraData(Ir.Reduce, cg.ir.instructions.items(.data)[@backingInt(r)].ty_pl.payload).data;
        if (red.operand.toIndex() != x) return null;
        // A reduce its branch computes reads `x`'s operands at the end of
        // the block.
        if (cg.fate(r) == .fused) for (insts[j + 1 ..]) |y| if (!isDbg(tags[@backingInt(y)])) return null;
        return r;
    }
    return null;
}

/// Whether compare or select `inst` is computed by the reduce after it
/// (`cmpFlags`, `reduceIndex`) instead of emitted.
fn absorbed(cg: *CodeGen, inst: Inst.Index) bool {
    const r = absorber(cg, inst) orelse return false;
    return switch (cg.ir.instructions.items(.tag)[@backingInt(inst)]) {
        .cmp_vector => fusedCmp(cg, r) != null,
        .select => indexSelect(cg, r) != null,
        else => false,
    };
}

/// The compare that `@reduce(.Or)` or `@reduce(.And)` `inst` absorbs: one
/// of lanes, whose mask the reduce tests directly (`cmpFlags`).
fn fusedCmp(cg: *CodeGen, inst: Inst.Index) ?Inst.Index {
    const x = cg.ir.extraData(Ir.Reduce, cg.ir.instructions.items(.data)[@backingInt(inst)].ty_pl.payload).data;
    if (x.operation() != .@"or" and x.operation() != .@"and") return null;
    const c = x.operand.toIndex() orelse return null;
    if (cg.ir.instructions.items(.tag)[@backingInt(c)] != .cmp_vector) return null;
    if (absorber(cg, c) != inst) return null;
    return c;
}

/// Whether bitcast `inst`, of a vector of lanes to an array or vector of
/// its size (the coercion before storing a vector into an array), is not
/// emitted: its only user is the store right after it, which stores the
/// operand instead (`stored`), saving a copy of the vector.
fn storedBitcast(cg: *CodeGen, inst: Inst.Index) bool {
    const insts = fromHere(cg, inst) orelse return false;
    const ip = cg.ip;
    const data = cg.ir.instructions.items(.data)[@backingInt(inst)].ty_op;
    const src_ty = cg.typeOf(data.operand);
    if (shape(ip, src_ty) == null) return false;
    if (ip.keyTag(data.ty) != .array_type and ip.keyTag(data.ty) != .vector_type) return false;
    if (Type.abiSize(ip, data.ty) != Type.abiSize(ip, src_ty)) return false;
    const live = cg.ssa.live.slice();
    if (live.items(.uses)[@backingInt(inst)] != 1 or live.items(.fate)[@backingInt(inst)] != .normal) return false;
    const tags = cg.ir.instructions.items(.tag);
    for (insts[1..]) |x| {
        if (isDbg(tags[@backingInt(x)])) continue;
        return tags[@backingInt(x)] == .store and cg.ir.instructions.items(.data)[@backingInt(x)].bin_op.rhs == inst.toRef();
    }
    return false;
}

/// The bitcast that loads for load `inst`, which is not emitted: the
/// load's only user, right after it, converting an array or vector to a
/// vector of its size in a register.
fn loadedBitcast(cg: *CodeGen, inst: Inst.Index) ?Inst.Index {
    const insts = fromHere(cg, inst) orelse return null;
    const live = cg.ssa.live.slice();
    if (live.items(.uses)[@backingInt(inst)] != 1 or live.items(.fate)[@backingInt(inst)] != .normal) return null;
    const tags = cg.ir.instructions.items(.tag);
    // Not a load of a variable, which `Ssa.plan` may forward or promote
    // so that it has no memory.
    const ptr = cg.ir.instructions.items(.data)[@backingInt(inst)].ty_op.operand;
    if (ptr.toIndex()) |p| if (tags[@backingInt(p)] == .alloc) return null;
    for (insts[1..]) |x| {
        if (isDbg(tags[@backingInt(x)])) continue;
        // A bitcast a store absorbs is not emitted to load either.
        if (tags[@backingInt(x)] != .bitcast or !bitcastToVreg(cg, x) or storedBitcast(cg, x)) return null;
        if (cg.ir.instructions.items(.data)[@backingInt(x)].ty_op.operand != inst.toRef()) return null;
        return x;
    }
    return null;
}

/// Whether bitcast `inst` loads its result's vector register from its
/// operand, an array or vector of the same size outside general-purpose
/// registers (`CodeGen` lowers the rest).
pub fn bitcastToVreg(cg: *CodeGen, inst: Inst.Index) bool {
    if (cg.homes[@backingInt(inst)] != .vreg) return false;
    const data = cg.ir.instructions.items(.data)[@backingInt(inst)].ty_op;
    const src_ty = cg.typeOf(data.operand);
    return !cg.inGpr(src_ty) and Type.abiSize(cg.ip, data.ty) == Type.abiSize(cg.ip, src_ty);
}

/// For a bitcast to a vector register: the pointer to load from, when
/// its operand is a load it absorbs (`loadedBitcast`).
pub fn loaded(cg: *CodeGen, operand: Ref) ?Ref {
    const i = operand.toIndex() orelse return null;
    if (cg.ir.instructions.items(.tag)[@backingInt(i)] != .load or loadedBitcast(cg, i) == null) return null;
    return cg.ir.instructions.items(.data)[@backingInt(i)].ty_op.operand;
}

/// The value store operand `val` stands for: the vector a bitcast before
/// the store converts (`storedBitcast`), else `val`.
pub fn stored(cg: *CodeGen, val: Ref) Ref {
    const i = val.toIndex() orelse return val;
    if (cg.ir.instructions.items(.tag)[@backingInt(i)] != .bitcast or !storedBitcast(cg, i)) return val;
    return cg.ir.instructions.items(.data)[@backingInt(i)].ty_op.operand;
}

/// For `CodeGen.fusable`: whether `inst` is an `@reduce(.Or)` or
/// `@reduce(.And)` of a bool vector, which a branch reads from the flags
/// (`condFlags`).
pub fn fusable(cg: *CodeGen, inst: Inst.Index) bool {
    const x = cg.ir.extraData(Ir.Reduce, cg.ir.instructions.items(.data)[@backingInt(inst)].ty_pl.payload).data;
    return isBits(cg.ip, cg.typeOf(x.operand)) and (x.operation() == .@"or" or x.operation() == .@"and");
}

/// For `CodeGen.condFlags`: sets the flags for `@reduce` `inst` of a bool
/// vector and returns the condition that is its result.
pub fn condFlags(cg: *CodeGen, inst: Inst.Index) Error!Encoder.Cond {
    const x = cg.ir.extraData(Ir.Reduce, cg.ir.instructions.items(.data)[@backingInt(inst)].ty_pl.payload).data;
    if (fusedCmp(cg, inst)) |c| return cmpFlags(cg, c, x.operation());
    if (maskLane(cg, x.operand)) |w| if (x.operation() != .xor) {
        const len = cg.ip.keyPayload(.vector_type, cg.typeOf(x.operand)).len;
        return maskFlags(cg, x.operation(), (try cg.locOf(x.operand)).vreg, len * w);
    };
    return reduceBitsFlags(cg, x.operation(), x.operand);
}

/// `@reduce(.Or)` (any lane true) or `@reduce(.And)` (all lanes true) of
/// compare `inst`: its lane masks combined, the lanes past the length
/// set to the identity, then umaxv or uminv, nonzero when the result is
/// true.
fn cmpFlags(cg: *CodeGen, inst: Inst.Index, op: Ir.ReduceOp) Error!Encoder.Cond {
    const x = cg.ir.extraData(Ir.VectorCmp, cg.ir.instructions.items(.data)[@backingInt(inst)].ty_pl.payload).data;
    const src_ty = cg.typeOf(x.lhs);
    const s = shape(cg.ip, src_ty).?;
    const any = op == .@"or";
    const chunks = s.chunks();
    const tail = s.len * s.lane.bytes() - (chunks - 1) * 16;
    if (chunks == 1) {
        try compareMask(cg, s, isSigned(cg, src_ty), x.operator(), x.lhs, x.rhs, 0, .v0);
        return maskFlags(cg, op, .v0, tail);
    }
    for (0..chunks) |kk| {
        const k: u32 = @intCast(kk);
        try compareMask(cg, s, isSigned(cg, src_ty), x.operator(), x.lhs, x.rhs, k, .v0);
        if (k == chunks - 1 and tail != 16) {
            var keep: [16]u8 = @splat(0);
            @memset(keep[0..tail], 0xff);
            if (any) {
                try loadConst(cg, .v6, keep);
                try bitwise(cg, .@"and", .v0, .v0, .v6);
            } else {
                for (&keep) |*b| b.* = ~b.*;
                try loadConst(cg, .v6, keep);
                try bitwise(cg, .orr, .v0, .v0, .v6);
            }
        }
        if (k == 0) {
            if (chunks > 1) try bitwise(cg, .orr, .v3, .v0, .v0);
        } else {
            try bitwise(cg, if (any) .orr else .@"and", .v3, .v3, .v0);
        }
    }
    try emit(cg, across(1, 0, if (any) 0b01010 else 0b11010, .v0, if (chunks > 1) .v3 else .v0));
    try cg.e.fmovToGpr(.w, .x9, .f32, .v0);
    try cg.e.cmp(.w, .x9, .{ .imm = 0 });
    return .ne;
}

/// The select that `@reduce` `inst` absorbs when it is the index of a
/// predicate's first or last true lane (`std.simd.firstTrue`,
/// `lastTrue`): `@reduce(.Min, @select(T, pred, iota, @splat(m)))` with
/// `m` at least the last index, or `.Max` with `m` 0.
fn indexSelect(cg: *CodeGen, inst: Inst.Index) ?Inst.Index {
    const ip = cg.ip;
    const ir = cg.ir;
    const x = ir.extraData(Ir.Reduce, ir.instructions.items(.data)[@backingInt(inst)].ty_pl.payload).data;
    const op = x.operation();
    if (op != .min and op != .max) return null;
    const si = x.operand.toIndex() orelse return null;
    if (ir.instructions.items(.tag)[@backingInt(si)] != .select) return null;
    if (absorber(cg, si) != inst) return null;
    const sel = ir.extraData(Ir.Select, ir.instructions.items(.data)[@backingInt(si)].ty_pl.payload).data;
    const ty = cg.typeOf(x.operand);
    if (!isBits(ip, cg.typeOf(sel.pred)) or Type.intInfo(ip, Type.childType(ip, ty)).signedness != .unsigned) return null;
    const a = sel.a.toInterned() orelse return null;
    const b = sel.b.toInterned() orelse return null;
    const len = ip.keyPayload(.vector_type, ty).len;
    if (ip.keyTag(a) != .aggregate or ip.keyTag(b) != .aggregate) return null;
    switch (ip.keyPayload(.aggregate, a).storage) {
        .elems => |elems| for (elems, 0..) |el, i| {
            if (ip.keyTag(el) != .int or ip.intValue(u64, el) != i) return null;
        },
        else => return null,
    }
    const m = switch (ip.keyPayload(.aggregate, b).storage) {
        .repeated_elem => |el| ip.intValue(u64, el) orelse return null,
        else => return null,
    };
    if (if (op == .min) m < len - 1 else m != 0) return null;
    return si;
}

/// `reduce` of a select `indexSelect` found: the index of the predicate's
/// lowest set bit (rbit, clz) or highest (clz), `m` when none is set.
fn reduceIndex(cg: *CodeGen, inst: Inst.Index, ty: Index, op: Ir.ReduceOp, si: Inst.Index) Error!void {
    const ip = cg.ip;
    const sel = cg.ir.extraData(Ir.Select, cg.ir.instructions.items(.data)[@backingInt(si)].ty_pl.payload).data;
    const len = ip.keyPayload(.vector_type, cg.typeOf(sel.pred)).len;
    const m = ip.intValue(u64, ip.keyPayload(.aggregate, sel.b.toInterned().?).storage.repeated_elem).?;
    const e = &cg.e;
    // Each lane's bits in x9: one, or for a mask, the lane narrowed to a
    // byte (four bits of each byte lane, shrn)
    var lane_shift: u6 = 0;
    if (maskLane(cg, sel.pred)) |w| {
        const v = (try cg.locOf(sel.pred)).vreg;
        if (w == 1) {
            try emit(cg, shiftImm(0, 0, 0b10000, 12, .v0, v)); // shrn v0.8b, v.8h, #4
        } else {
            try emit(cg, xtn(laneSize(intLane(w / 2)), .v0, v));
        }
        try cg.e.fmovToGpr(.x, .x9, .f64, .v0);
        lane_shift = switch (w) {
            1 => 2,
            2 => 3,
            4 => 4,
            8 => 5,
            else => unreachable,
        };
        const used = @as(u64, len) << lane_shift;
        if (used < 64) try e.logic(.@"and", .x, .x9, .x9, .{ .imm = lenMask(@intCast(used)) });
    } else {
        try cg.load(.x9, sel.pred);
        // Bits above the length may be padding read from memory, unless the
        // bits fill the bytes the load reads.
        if (len != 8 and len != 16 and len != 32 and len != 64) try e.logic(.@"and", .x, .x9, .x9, .{ .imm = lenMask(len) });
    }
    if (op == .min) {
        try e.bitOp(.rbit, .x, .x10, .x9);
        try e.bitOp(.clz, .x, .x10, .x10);
        try e.movImm(.x, .x11, m);
    } else {
        try e.bitOp(.clz, .x, .x10, .x9);
        try e.movImm(.x, .x11, 63);
        try e.addSub(.sub, .x, .x10, .x11, .r(.x10));
        try e.movImm(.x, .x11, 0);
    }
    if (lane_shift != 0) try e.shiftImm(.lsr, .x, .x10, .x10, lane_shift);
    try e.cmp(.x, .x9, .{ .imm = 0 });
    try e.csel(.csel, .x, .x10, .x11, .x10, .eq);
    try cg.setResult(inst, ty, .x10);
}

// ---------------------------------------------------------------------------
// Lane masks
//
// A bool vector that a compare of one register's lanes computes, or a
// bitwise operation on such, may live as its lane mask in a V register:
// each lane all ones or all zeros, at the compare's lane width, so that
// reductions (umaxv, uminv), selects (bsl) and bitwise operations read it
// directly, and only a bitcast to an integer, firstTrue or a user of the
// bits pays for them. `planMasks` picks the candidates, whose every user
// reads a mask; those the allocator gives a V register are masks
// (`maskLane`), the rest bits. Lanes past the length hold anything.

/// Marks the mask candidates in `cg.mask_lanes` with their lane width in
/// bytes: compares of at most 16 bytes of lanes, and bitwise operations
/// on bool vectors with a candidate operand (whose width they take), that
/// only `readsMask` users read.
pub fn planMasks(cg: *CodeGen) Error!void {
    const ir = cg.ir;
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    const values = cg.ssa.values.items(.inst);
    for (values) |inst| {
        if (cmpLane(cg, inst) != 0) break;
    } else return;
    const lanes = try cg.gpa.alloc(u8, ir.instructions.len);
    @memset(lanes, 0);
    cg.mask_lanes = lanes;
    // 0xff marks a value some user reads as bits.
    const Reads = struct {
        cg: *CodeGen,
        user: ?Inst.Index,
        pub fn use(r: @This(), ref: Ref) void {
            const i = ref.toIndex() orelse return;
            if (r.user == null or !readsMask(r.cg, r.user.?, ref)) r.cg.mask_lanes[@backingInt(i)] = 0xff;
        }
    };
    for (values) |inst| Ssa.forEachOperand(ir, inst, Reads{ .cg = cg, .user = inst });
    const term_reads: Reads = .{ .cg = cg, .user = null };
    for (cg.ssa.blocks.items) |b| switch (b.term.tag) {
        .jump, .branch => if (tags[@backingInt(b.term.inst)] == .br) term_reads.use(datas[@backingInt(b.term.inst)].br.operand),
        .ret => term_reads.use(datas[@backingInt(b.term.inst)].un_op),
        else => {},
    };
    var changed = true;
    while (changed) {
        changed = false;
        for (values) |inst| {
            const i = @backingInt(inst);
            if (lanes[i] != 0) continue;
            lanes[i] = cmpLane(cg, inst);
            if (lanes[i] == 0 and isBoolOp(cg, inst)) {
                const Find = struct {
                    lanes: []const u8,
                    w: u8 = 0,
                    pub fn use(f: *@This(), ref: Ref) void {
                        const x = ref.toIndex() orelse return;
                        const l = f.lanes[@backingInt(x)];
                        if (f.w == 0 and l != 0 and l != 0xff) f.w = l;
                    }
                };
                var find: Find = .{ .lanes = lanes };
                Ssa.forEachOperand(ir, inst, &find);
                lanes[i] = find.w;
            }
            changed = changed or lanes[i] != 0;
        }
    }
    for (lanes) |*l| if (l.* == 0xff) {
        l.* = 0;
    };
}

/// The lane width of compare `inst` when its lanes fill at most one
/// register, else 0.
fn cmpLane(cg: *CodeGen, inst: Inst.Index) u8 {
    if (cg.ir.instructions.items(.tag)[@backingInt(inst)] != .cmp_vector) return 0;
    const x = cg.ir.extraData(Ir.VectorCmp, cg.ir.instructions.items(.data)[@backingInt(inst)].ty_pl.payload).data;
    const s = shape(cg.ip, cg.typeOf(x.lhs)) orelse return 0;
    return if (s.size <= 16) @intCast(s.lane.bytes()) else 0;
}

fn isBoolOp(cg: *CodeGen, inst: Inst.Index) bool {
    const data = cg.ir.instructions.items(.data)[@backingInt(inst)];
    return switch (cg.ir.instructions.items(.tag)[@backingInt(inst)]) {
        .bit_and, .bit_or, .xor => isBits(cg.ip, cg.typeOf(data.bin_op.lhs)),
        .not => isBits(cg.ip, data.ty_op.ty),
        else => false,
    };
}

/// Whether `user` reads bool vector operand `ref` as a mask when it is
/// one: reductions, a select's predicate, bitwise operations, and bitcasts
/// to an integer.
fn readsMask(cg: *CodeGen, user: Inst.Index, ref: Ref) bool {
    const data = cg.ir.instructions.items(.data)[@backingInt(user)];
    return switch (cg.ir.instructions.items(.tag)[@backingInt(user)]) {
        .reduce => true,
        .select => cg.ir.extraData(Ir.Select, data.ty_pl.payload).data.pred == ref,
        .bitcast => Type.class(cg.ip, data.ty_op.ty) == .int,
        else => isBoolOp(cg, user),
    };
}

/// For `CodeGen.clobbers`: whether `inst` wants a V register for its lane
/// mask.
pub fn wantsMask(cg: *CodeGen, inst: Inst.Index) bool {
    return cg.mask_lanes.len != 0 and cg.mask_lanes[@backingInt(inst)] != 0;
}

/// The lane width in bytes of bool vector `ref`'s mask when it is one,
/// else null: it is its bits.
fn maskLane(cg: *CodeGen, ref: Ref) ?u32 {
    const i = ref.toIndex() orelse return null;
    if (!wantsMask(cg, i) or cg.homes[@backingInt(i)] != .vreg) return null;
    return cg.mask_lanes[@backingInt(i)];
}

fn intLane(bytes: u32) Lane {
    return switch (bytes) {
        1 => .i8,
        2 => .i16,
        4 => .i32,
        8 => .i64,
        else => unreachable,
    };
}

/// Sets the flags for `@reduce(.Or)` (any lane true) or `@reduce(.And)`
/// (all lanes true) of the lane mask in `v`, whose first `bytes` bytes
/// are its lanes; returns the condition that holds when the result is
/// true. Up to 8 bytes are tested in x9; more, with the rest set to the
/// identity, by umaxv or uminv.
fn maskFlags(cg: *CodeGen, op: Ir.ReduceOp, v: VReg, bytes: u32) Error!Encoder.Cond {
    const any = op == .@"or";
    if (bytes <= 8) {
        try cg.e.fmovToGpr(.x, .x9, .f64, v);
        if (any) {
            if (bytes == 8) try cg.e.cmp(.x, .x9, .{ .imm = 0 }) else try cg.e.tst(.x, .x9, .{ .imm = lenMask(bytes * 8) });
            return .ne;
        }
        // All of the lanes' bits set: with the rest set too, plus one is 0.
        if (bytes != 8) try cg.e.logic(.orr, .x, .x9, .x9, .{ .imm = ~lenMask(bytes * 8) });
        try cg.e.addSub(.add, .x, .x9, .x9, .{ .imm = 1 });
        try cg.e.cmp(.x, .x9, .{ .imm = 0 });
        return .eq;
    }
    var r = v;
    if (bytes != 16) {
        var keep: [16]u8 = @splat(0);
        @memset(keep[0..bytes], 0xff);
        if (!any) for (&keep) |*b| {
            b.* = ~b.*;
        };
        try loadConst(cg, .v6, keep);
        try bitwise(cg, if (any) .@"and" else .orr, .v0, v, .v6);
        r = .v0;
    }
    try emit(cg, across(1, 0, if (any) 0b01010 else 0b11010, .v0, r));
    try cg.e.fmovToGpr(.w, .x9, .f32, .v0);
    try cg.e.cmp(.w, .x9, .{ .imm = 0 });
    return .ne;
}

/// The register holding the lane mask of bool vector `ref`'s lanes from
/// `first` on, at lanes of `to` bytes: `ref`'s own when it is a mask of
/// that width, else `scratch`, converted (ext, then sxtl or xtn) or, from
/// bits, each lane's bit tested (cmtst). Uses v3, v7 and x9-x11.
fn maskChunk(cg: *CodeGen, ref: Ref, first: u32, to: u32, scratch: VReg) Error!VReg {
    if (maskLane(cg, ref)) |w| {
        var r = (try cg.locOf(ref)).vreg;
        if (first != 0) {
            try emit(cg, ext(scratch, r, r, @intCast(first * w)));
            r = scratch;
        }
        var b = w;
        while (b < to) : (b *= 2) {
            try emit(cg, shiftImm(0, 0, 0b10100, @as(u7, 8) << laneSize(intLane(b)), scratch, r)); // sxtl
            r = scratch;
        }
        while (b > to) : (b /= 2) {
            try emit(cg, xtn(laneSize(intLane(b / 2)), scratch, r));
            r = scratch;
        }
        return r;
    }
    try bitsOf(cg, .x11, ref);
    if (first != 0) try cg.e.shiftImm(.lsr, .x, .x11, .x11, @intCast(first));
    if (to == 1) {
        // The low byte to lanes 0-7, the next to lanes 8-15.
        try emit(cg, dupGpr(0, scratch, .x11));
        try cg.e.shiftImm(.lsr, .x, .x10, .x11, 8);
        try emit(cg, dupGpr(0, .v3, .x10));
        try emit(cg, 0x6e180400 | vn(.v3) << 5 | vn(scratch)); // ins scratch.d[1], v3.d[0]
    } else {
        try emit(cg, dupGpr(laneSize(intLane(to)), scratch, .x11));
    }
    try loadConst(cg, .v7, bitWeights(to));
    try emit(cg, same(0, laneSize(intLane(to)), 0b10001, scratch, scratch, .v7)); // cmtst
    return scratch;
}

/// Loads bool vector `ref`'s bits into `d`: a mask's, weighted and
/// summed (`toBits`), with the bits past its length cleared. Uses v0, v7.
fn bitsOf(cg: *CodeGen, d: Reg, ref: Ref) Error!void {
    const w = maskLane(cg, ref) orelse return cg.load(d, ref);
    const len = cg.ip.keyPayload(.vector_type, cg.typeOf(ref)).len;
    try loadConst(cg, .v7, bitWeights(w));
    try move(cg, .v0, (try cg.locOf(ref)).vreg);
    try toBits(cg, .{ .lane = intLane(w), .len = len, .size = 16 }, d);
    if (len < 16 / w) try cg.e.logic(.@"and", .x, d, d, .{ .imm = lenMask(len) });
}

// ---------------------------------------------------------------------------
// Encodings (Arm ARM, "Advanced SIMD")

fn emit(cg: *CodeGen, insn: u32) Error!void {
    try cg.e.raw(insn);
}

fn vn(r: VReg) u32 {
    return @backingInt(r);
}

fn xn(r: Reg) u32 {
    return @backingInt(r);
}

/// Three registers of the same type, 128 bits: `op vd, vn, vm`.
fn same(u: u1, size: u2, opcode: u5, d: VReg, n: VReg, m: VReg) u32 {
    return 0x4e200400 | @as(u32, u) << 29 | @as(u32, size) << 22 | vn(m) << 16 | @as(u32, opcode) << 11 | vn(n) << 5 | vn(d);
}

/// Two-register miscellaneous, 128 bits: `op vd, vn`.
fn misc(u: u1, size: u2, opcode: u5, d: VReg, n: VReg) u32 {
    return 0x4e200800 | @as(u32, u) << 29 | @as(u32, size) << 22 | @as(u32, opcode) << 12 | vn(n) << 5 | vn(d);
}

/// Across lanes, 128 bits: addv, smaxv, ... into lane 0 of `d`.
fn across(u: u1, size: u2, opcode: u5, d: VReg, n: VReg) u32 {
    return 0x4e300800 | @as(u32, u) << 29 | @as(u32, size) << 22 | @as(u32, opcode) << 12 | vn(n) << 5 | vn(d);
}

/// Shift by immediate: `immhb` is immh:immb.
fn shiftImm(q: u1, u: u1, opcode: u5, immhb: u7, d: VReg, n: VReg) u32 {
    return 0x0f000400 | @as(u32, q) << 30 | @as(u32, u) << 29 | @as(u32, immhb) << 16 | @as(u32, opcode) << 11 | vn(n) << 5 | vn(d);
}

/// `dup vd.T, wn/xn` for lanes of element size `size`.
fn dupGpr(size: u2, d: VReg, n: Reg) u32 {
    const imm5: u32 = @as(u32, 1) << size;
    return 0x4e000c00 | imm5 << 16 | xn(n) << 5 | vn(d);
}

/// `umov wd, vn.T[0]` (or `mov xd, vn.d[0]`).
fn umov0(size: u2, d: Reg, n: VReg) u32 {
    const imm5: u32 = @as(u32, 1) << size;
    return 0x0e003c00 | @as(u32, @intFromBool(size == 3)) << 30 | imm5 << 16 | vn(n) << 5 | xn(d);
}

/// `ext vd.16b, vn.16b, vm.16b, #imm`.
fn ext(d: VReg, n: VReg, m: VReg, imm: u4) u32 {
    return 0x6e000000 | vn(m) << 16 | @as(u32, imm) << 11 | vn(n) << 5 | vn(d);
}

/// `tbl`/`tbx vd.16b, {vn.16b - vn+regs-1}, vm.16b`.
fn tbl(extend: bool, regs: u32, d: VReg, n: VReg, m: VReg) u32 {
    return 0x4e000000 | vn(m) << 16 | (regs - 1) << 13 | @as(u32, @intFromBool(extend)) << 12 | vn(n) << 5 | vn(d);
}

/// `xtn vd.Tb, vn.Ta`: each lane's low half, into the low 64 bits; `size`
/// is the narrow lanes' element size.
fn xtn(size: u2, d: VReg, n: VReg) u32 {
    return 0x0e212800 | @as(u32, size) << 22 | vn(n) << 5 | vn(d);
}

/// `uzp1 vd.T, vn.T, vm.T`: the even lanes of `n` then of `m`.
fn uzp1(size: u2, d: VReg, n: VReg, m: VReg) u32 {
    return 0x4e001800 | @as(u32, size) << 22 | vn(m) << 16 | vn(n) << 5 | vn(d);
}

fn bitwise(cg: *CodeGen, op: enum { @"and", orr, eor, bsl }, d: VReg, n: VReg, m: VReg) Error!void {
    try emit(cg, switch (op) {
        .@"and" => same(0, 0b00, 0b00011, d, n, m),
        .orr => same(0, 0b10, 0b00011, d, n, m),
        .eor => same(1, 0b00, 0b00011, d, n, m),
        .bsl => same(1, 0b01, 0b00011, d, n, m),
    });
}

/// `movi vd.2d, #0`.
fn zero(cg: *CodeGen, d: VReg) Error!void {
    try emit(cg, 0x6f00e400 | vn(d));
}

// ---------------------------------------------------------------------------
// Operands and results

/// Loads 16-byte chunk `k` of vector `ref` into `r`; a vector of less
/// than 16 bytes fills the low bytes, zeroing the rest.
fn loadChunk(cg: *CodeGen, r: VReg, ref: Ref, k: u32) Error!void {
    const size: u32 = @intCast(Type.abiSize(cg.ip, cg.typeOf(ref)));
    switch (try cg.locOf(ref)) {
        .mem => |m| try loadMem(cg, r, m.plus(16 * k), @min(size, 16)),
        .imm => |x| {
            // An undefined vector of up to 8 bytes.
            try cg.e.movImm(.x, .x9, x);
            try cg.e.fmovFromGpr(.f64, r, .x, .x9);
        },
        .none => try zero(cg, r),
        .vreg => |v| try move(cg, r, v),
        // Vectors have no general register (`CodeGen.inGpr`).
        .addr, .err, .reg => unreachable,
    }
}

/// The register holding 16-byte chunk `k` of vector `ref`: its own, or
/// `scratch` loaded with it (`loadChunk`). Only reads of the result may
/// follow.
fn srcChunk(cg: *CodeGen, ref: Ref, k: u32, scratch: VReg) Error!VReg {
    if (try cg.locOf(ref) == .vreg) return (try cg.locOf(ref)).vreg;
    try loadChunk(cg, scratch, ref, k);
    return scratch;
}

/// The register to compute a chunk of `dst` in: its own, or `scratch`
/// for `storeChunk` to store.
fn destReg(dst: Dst, scratch: VReg) VReg {
    return switch (dst) {
        .reg => |r| r,
        .mem => scratch,
    };
}

/// Loads vector `ref`, of at most 16 bytes, into `r`.
pub fn loadVec(cg: *CodeGen, r: VReg, ref: Ref) Error!void {
    try loadChunk(cg, r, ref, 0);
}

/// `mov d.16b, s.16b`.
pub fn move(cg: *CodeGen, d: VReg, s: VReg) Error!void {
    if (d != s) try bitwise(cg, .orr, d, s, s);
}

/// Whether vectors of type `ty` live in a vector register when the
/// allocator gives them one (`CodeGen.inVreg`): those of at most 16 bytes
/// of lanes, which are one chunk.
pub fn inVreg(ip: *const InternPool, ty: Index) bool {
    const s = shape(ip, ty) orelse return false;
    return s.size <= 16;
}

/// Where an instruction's vector result goes: its register, or memory.
const Dst = union(enum) { mem: Mem, reg: VReg };

/// The destination of vector result `inst`, or null when it has no bits.
fn dest(cg: *CodeGen, inst: Inst.Index, ty: Index) Error!?Dst {
    if (cg.homes[@backingInt(inst)] == .vreg) return .{ .reg = cg.homes[@backingInt(inst)].vreg };
    return .{ .mem = try cg.resultMem(inst, ty) orelse return null };
}

/// Loads the `bytes` bytes (1 to 16, a power of two) at `m` into `r`.
pub fn loadMem(cg: *CodeGen, r: VReg, m: Mem, bytes: u32) Error!void {
    const a = try cg.access(m, bytes, .x16);
    switch (bytes) {
        16 => try cg.e.ldrQ(r, a),
        8 => try cg.e.ldrFp(.f64, r, a),
        4 => try cg.e.ldrFp(.f32, r, a),
        2 => try cg.e.ldrFp(.f16, r, a),
        1 => {
            try cg.e.ldr(.byte, .x9, a);
            try cg.e.fmovFromGpr(.f32, r, .w, .x9);
        },
        else => unreachable,
    }
}

/// Stores `r` as chunk `k` of a vector of shape `s` at `dst`.
fn storeChunk(cg: *CodeGen, dst: Dst, r: VReg, s: Shape, k: u32) Error!void {
    switch (dst) {
        .reg => |h| {
            std.debug.assert(k == 0);
            try move(cg, h, r);
        },
        .mem => |m| try storeMem(cg, m.plus(16 * k), r, @min(s.size, 16)),
    }
}

/// Stores the low `bytes` bytes (1 to 16, a power of two) of `r` at `m`.
pub fn storeMem(cg: *CodeGen, m: Mem, r: VReg, bytes: u32) Error!void {
    const a = try cg.access(m, bytes, .x17);
    switch (bytes) {
        16 => try cg.e.strQ(r, a),
        8 => try cg.e.strFp(.f64, r, a),
        4 => try cg.e.strFp(.f32, r, a),
        2 => try cg.e.strFp(.f16, r, a),
        1 => {
            try cg.e.fmovToGpr(.w, .x9, .f32, r);
            try cg.e.str(.byte, .x9, a);
        },
        else => unreachable,
    }
}

/// Loads a 16-byte constant from read-only data into `r`.
fn loadConst(cg: *CodeGen, r: VReg, bytes: [16]u8) Error!void {
    const key = try cg.emit.contentAtom(16, &bytes, &.{}, &.{});
    try cg.e.ldrQ(r, try cg.access(.sym(key, 0), 16, .x16));
}

/// 16 bytes of lanes of `lane_bytes` each, lane `i` holding `f(i)`.
fn laneBytes(lane_bytes: u32, f: *const fn (u32) u64) [16]u8 {
    var b: [16]u8 = undefined;
    for (0..16 / lane_bytes) |i| {
        const v = f(@intCast(i));
        for (0..lane_bytes) |j| b[i * lane_bytes + j] = @truncate(v >> @intCast(8 * j));
    }
    return b;
}

/// Each lane's bit in a bool vector's bits: bit `i % 8` for lanes of
/// bytes, which `toBits` sums per 8 lanes; bit `i` for wider ones.
fn bitWeights(lane_bytes: u32) [16]u8 {
    return laneBytes(lane_bytes, if (lane_bytes == 1) struct {
        fn f(i: u32) u64 {
            return @as(u64, 1) << @intCast(i % 8);
        }
    }.f else struct {
        fn f(i: u32) u64 {
            return @as(u64, 1) << @intCast(i);
        }
    }.f);
}

fn lenMask(bits: u32) u64 {
    return if (bits >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(bits)) - 1;
}

fn isSigned(cg: *CodeGen, ty: Index) bool {
    const child = Type.childType(cg.ip, ty);
    return Type.class(cg.ip, child) == .int and Type.intInfo(cg.ip, child).signedness == .signed;
}

/// Element `i` of comptime vector `val`.
fn elemValue(ip: *const InternPool, val: Index, i: usize) Index {
    const a = ip.keyPayload(.aggregate, val);
    return switch (a.storage) {
        .elems => |elems| elems[i],
        .repeated_elem => |el| el,
        .bytes => unreachable, // an i32 or small-integer vector
    };
}

// ---------------------------------------------------------------------------
// Lane-wise operations

fn arith(cg: *CodeGen, inst: Inst.Index, tag: Inst.Tag, ty: Index, lhs: Ref, rhs: Ref) Error!void {
    const s = shape(cg.ip, ty).?;
    const signed = isSigned(cg, ty);
    const dst = try dest(cg, inst, ty) orelse return;
    const sz: u2 = s.sz();
    const es = s.esize();
    for (0..s.chunks()) |kk| {
        const k: u32 = @intCast(kk);
        const a = try srcChunk(cg, lhs, k, .v0);
        const b = try srcChunk(cg, rhs, k, .v1);
        var r = destReg(dst, .v0);
        switch (tag) {
            .add_wrap => try emit(cg, same(0, es, 0b10000, r, a, b)),
            .sub_wrap => try emit(cg, same(1, es, 0b10000, r, a, b)),
            .mul_wrap => try emit(cg, same(0, es, 0b10011, r, a, b)),
            .bit_and => try bitwise(cg, .@"and", r, a, b),
            .bit_or => try bitwise(cg, .orr, r, a, b),
            .xor => try bitwise(cg, .eor, r, a, b),
            .min_int, .max_int => r = try minMax(cg, tag == .max_int, es, signed, r, a, b),
            .add_float => try emit(cg, same(0, sz, 0b11010, r, a, b)),
            .sub_float => try emit(cg, same(0, 0b10 | sz, 0b11010, r, a, b)),
            .mul_float => try emit(cg, same(1, sz, 0b11011, r, a, b)),
            .div_float => try emit(cg, same(1, sz, 0b11111, r, a, b)),
            // fmaxnm and fminnm, as the scalar lowering: a NaN operand
            // yields the other.
            .max_float => try emit(cg, same(0, sz, 0b11000, r, a, b)),
            .min_float => try emit(cg, same(0, 0b10 | sz, 0b11000, r, a, b)),
            else => unreachable,
        }
        try storeChunk(cg, dst, r, s, k);
    }
}

/// `@min` or `@max` of integer lanes in `a` and `b`, into `d` or v2;
/// returns the register holding it. Clobbers v2.
fn minMax(cg: *CodeGen, max: bool, es: u2, signed: bool, d: VReg, a: VReg, b: VReg) Error!VReg {
    const u: u1 = @intFromBool(!signed);
    if (es != 3) {
        try emit(cg, same(u, es, if (max) 0b01100 else 0b01101, d, a, b));
        return d;
    }
    // No 64-bit smax: a > b (cmgt or cmhi), then a bit select.
    try emit(cg, same(u, 3, 0b00110, .v2, a, b));
    if (max) try bitwise(cg, .bsl, .v2, a, b) else try bitwise(cg, .bsl, .v2, b, a);
    return .v2;
}

fn splat(cg: *CodeGen, inst: Inst.Index, ty: Index, elem: Ref) Error!void {
    const s = shape(cg.ip, ty).?;
    const dst = try dest(cg, inst, ty) orelse return;
    try cg.load(.x9, elem);
    const r = destReg(dst, .v0);
    try emit(cg, dupGpr(s.esize(), r, .x9));
    for (0..s.chunks()) |k| try storeChunk(cg, dst, r, s, @intCast(k));
}

/// `@intCast` that widens, or `@truncate`, between integer lanes.
fn cast(cg: *CodeGen, inst: Inst.Index, ty: Index, operand: Ref) Error!void {
    const ip = cg.ip;
    const src_ty = cg.typeOf(operand);
    const s = shape(ip, src_ty).?;
    const d = shape(ip, ty).?;
    const dst = try dest(cg, inst, ty) orelse return;
    const widen = d.lane.bytes() > s.lane.bytes();
    const ratio = if (widen) d.lane.bytes() / s.lane.bytes() else s.lane.bytes() / d.lane.bytes();
    const u: u1 = @intFromBool(!isSigned(cg, src_ty));
    for (0..d.chunks()) |jj| {
        const j: u32 = @intCast(jj);
        if (widen) {
            // The source bytes of this chunk, low in v0, then each lane
            // extended to twice its width (ushll or sshll #0) until wide
            // enough.
            const off = j * 16 / ratio;
            try loadChunk(cg, .v0, operand, off / 16);
            if (off % 16 != 0) try emit(cg, ext(.v0, .v0, .v0, @intCast(off % 16)));
            var es = s.esize();
            while (es != d.esize()) : (es += 1) {
                try emit(cg, shiftImm(0, u, 0b10100, @as(u7, 8) << es, .v0, .v0));
            }
            try storeChunk(cg, dst, .v0, d, j);
        } else {
            try pack(cg, operand, s, j * ratio, ratio, 0);
            try storeChunk(cg, dst, .v0, d, j);
        }
    }
}

/// Computes in v`r` one 16-byte chunk of lanes `count` times narrower
/// than shape `s`'s, from the `count` source chunks of `operand` from
/// `first` on: the two halves, each from half the chunks (in v`r` and
/// v`r+1`), then each lane's low half kept (uzp1). Source chunks past the
/// operand's are padding, never read. Uses v`r` to v`r+3`.
fn pack(cg: *CodeGen, operand: Ref, s: Shape, first: u32, count: u32, r: u5) Error!void {
    if (count == 1) {
        if (first < s.chunks()) try loadChunk(cg, @fromBackingInt(@intCast(r)), operand, first);
        return;
    }
    try pack(cg, operand, s, first, count / 2, r);
    try pack(cg, operand, s, first + count / 2, count / 2, r + 1);
    const half: Lane = switch (s.lane.bytes() / count) {
        1 => .i8,
        2 => .i16,
        4 => .i32,
        else => unreachable,
    };
    try emit(cg, uzp1(laneSize(half), @fromBackingInt(@intCast(r)), @fromBackingInt(@intCast(r)), @fromBackingInt(@intCast(r + 1))));
}

/// Shifts by an amount that is the same in every lane (Sema checks it):
/// by an immediate when it is comptime-known, else by lane 0 of `rhs`
/// broadcast (ushl, sshl; right shifts by its negation).
fn shift(cg: *CodeGen, inst: Inst.Index, left: bool, ty: Index, lhs: Ref, rhs: Ref) Error!void {
    const ip = cg.ip;
    const s = shape(ip, ty).?;
    const signed = isSigned(cg, ty);
    const dst = try dest(cg, inst, ty) orelse return;
    const es = s.esize();
    const bits: u32 = s.lane.bytes() * 8;
    const amount: ?u32 = if (rhs.toInterned()) |v| @intCast(CodeGen.intBits(ip, elemValue(ip, v, 0))) else null;
    if (amount == null) {
        switch (try cg.locOf(rhs)) {
            .mem => |m| try cg.e.ldr(.byte, .x9, try cg.access(m, 1, .x16)),
            .imm => |x| try cg.e.movImm(.x, .x9, x & 0xff),
            .vreg => |v| {
                try cg.e.fmovToGpr(.w, .x9, .f32, v);
                try cg.e.logic(.@"and", .w, .x9, .x9, .{ .imm = 0xff });
            },
            else => unreachable,
        }
        if (!left) try cg.e.addSub(.sub, .x, .x9, .zr, .r(.x9));
        try emit(cg, dupGpr(es, .v1, .x9));
    }
    for (0..s.chunks()) |kk| {
        const k: u32 = @intCast(kk);
        const a = try srcChunk(cg, lhs, k, .v0);
        var r = destReg(dst, .v0);
        if (amount) |n| {
            if (left) {
                try emit(cg, shiftImm(1, 0, 0b01010, @intCast(bits + n), r, a));
            } else if (n != 0) {
                try emit(cg, shiftImm(1, @intFromBool(!signed), 0b00000, @intCast(2 * bits - n), r, a));
            } else r = a;
        } else {
            try emit(cg, same(@intFromBool(left or !signed), es, 0b01000, r, a, .v1));
        }
        try storeChunk(cg, dst, r, s, k);
    }
}

// ---------------------------------------------------------------------------
// Compares, selects, and reductions

/// Computes in `d` the lane mask of `lhs op rhs` for chunk `k`. Uses v0
/// and v1.
fn compareMask(cg: *CodeGen, s: Shape, signed: bool, op: std.math.CompareOperator, lhs: Ref, rhs: Ref, k: u32, d: VReg) Error!void {
    const a = try srcChunk(cg, lhs, k, .v0);
    const b = try srcChunk(cg, rhs, k, .v1);
    const swap = op == .lt or op == .lte;
    const n: VReg, const m: VReg = if (swap) .{ b, a } else .{ a, b };
    if (s.lane.isFloat()) {
        const sz: u2 = s.sz();
        try emit(cg, switch (op) {
            .eq, .neq => same(0, sz, 0b11100, d, n, m),
            .gt, .lt => same(1, 0b10 | sz, 0b11100, d, n, m),
            .gte, .lte => same(1, sz, 0b11100, d, n, m),
        });
    } else {
        const es = s.esize();
        const u: u1 = @intFromBool(!signed);
        try emit(cg, switch (op) {
            .eq, .neq => same(1, es, 0b10001, d, n, m),
            .gt, .lt => same(u, es, 0b00110, d, n, m),
            .gte, .lte => same(u, es, 0b00111, d, n, m),
        });
    }
    if (op == .neq) try emit(cg, misc(1, 0, 0b00101, d, d));
}

/// The bits of lane mask v0 (shape `s`), weighted by v7 (`bitWeights`),
/// into the low bits of `d`. Clobbers v0.
fn toBits(cg: *CodeGen, s: Shape, d: Reg) Error!void {
    try bitwise(cg, .@"and", .v0, .v0, .v7);
    switch (s.lane.bytes()) {
        1 => {
            // Pairwise sums, three times: bytes 0 and 1 sum lanes 0-7 and
            // 8-15.
            for (0..3) |_| try emit(cg, same(0, 0, 0b10111, .v0, .v0, .v0));
            try emit(cg, umov0(1, d, .v0));
        },
        2 => {
            try emit(cg, across(0, 1, 0b11011, .v0, .v0));
            try emit(cg, umov0(1, d, .v0));
        },
        4 => {
            try emit(cg, across(0, 2, 0b11011, .v0, .v0));
            try emit(cg, umov0(2, d, .v0));
        },
        8 => {
            try emit(cg, 0x5ef1b800); // addp d0, v0.2d
            try emit(cg, umov0(3, d, .v0));
        },
        else => unreachable,
    }
}

fn compare(cg: *CodeGen, inst: Inst.Index, ty: Index, op: std.math.CompareOperator, lhs: Ref, rhs: Ref) Error!void {
    const ip = cg.ip;
    const src_ty = cg.typeOf(lhs);
    const s = shape(ip, src_ty).?;
    const signed = isSigned(cg, src_ty);
    try loadConst(cg, .v7, bitWeights(s.lane.bytes()));
    const per = s.perReg();
    for (0..s.chunks()) |kk| {
        const k: u32 = @intCast(kk);
        try compareMask(cg, s, signed, op, lhs, rhs, k, .v0);
        try toBits(cg, s, if (k == 0) .x10 else .x9);
        if (k != 0) try cg.e.logic(.orr, .x, .x10, .x10, .{ .reg = .{ .reg = .x9, .amount = @intCast(k * per) } });
    }
    // Lanes past the length (padding, or the zeroed rest of a short
    // vector's register) compared too.
    if (s.len < s.chunks() * per) try cg.e.logic(.@"and", .x, .x10, .x10, .{ .imm = lenMask(s.len) });
    try cg.setResult(inst, ty, .x10);
}

/// `@select`: per chunk, the predicate's bits for its lanes broadcast,
/// tested against each lane's bit (cmtst), then a bit select.
fn select(cg: *CodeGen, inst: Inst.Index, ty: Index, pred: Ref, a: Ref, b: Ref) Error!void {
    const s = shape(cg.ip, ty).?;
    const dst = try dest(cg, inst, ty) orelse return;
    const per = s.perReg();
    if (maskLane(cg, pred) != null) {
        for (0..s.chunks()) |kk| {
            const k: u32 = @intCast(kk);
            try move(cg, .v2, try maskChunk(cg, pred, k * per, s.lane.bytes(), .v2));
            try bitwise(cg, .bsl, .v2, try srcChunk(cg, a, k, .v0), try srcChunk(cg, b, k, .v1));
            try storeChunk(cg, dst, .v2, s, k);
        }
        return;
    }
    try loadConst(cg, .v7, bitWeights(s.lane.bytes()));
    try cg.load(.x11, pred);
    for (0..s.chunks()) |kk| {
        const k: u32 = @intCast(kk);
        const bits: Reg = if (k == 0) .x11 else .x9;
        if (k != 0) try cg.e.shiftImm(.lsr, .x, .x9, .x11, @intCast(k * per));
        if (s.lane == .i8) {
            // The low byte to lanes 0-7, the next to lanes 8-15.
            try emit(cg, dupGpr(0, .v2, bits));
            try cg.e.shiftImm(.lsr, .x, .x10, bits, 8);
            try emit(cg, dupGpr(0, .v3, .x10));
            try emit(cg, 0x6e180400 | vn(.v3) << 5 | vn(.v2)); // ins v2.d[1], v3.d[0]
        } else {
            try emit(cg, dupGpr(s.esize(), .v2, bits));
        }
        try emit(cg, same(0, s.esize(), 0b10001, .v2, .v2, .v7)); // cmtst
        try bitwise(cg, .bsl, .v2, try srcChunk(cg, a, k, .v0), try srcChunk(cg, b, k, .v1));
        try storeChunk(cg, dst, .v2, s, k);
    }
}

/// Sets the flags for `@reduce(op, operand)` of a bool vector's bits;
/// returns the condition that holds when the result is true.
fn reduceBitsFlags(cg: *CodeGen, op: Ir.ReduceOp, operand: Ref) Error!Encoder.Cond {
    const len = cg.ip.keyPayload(.vector_type, cg.typeOf(operand)).len;
    try bitsOf(cg, .x9, operand);
    // Bits above the length may be padding read from memory, unless the
    // bits fill the bytes the load reads.
    const exact = len == 8 or len == 16 or len == 32 or len == 64;
    switch (op) {
        .@"or" => {
            if (exact) {
                try cg.e.cmp(.x, .x9, .{ .imm = 0 });
            } else {
                try cg.e.tst(.x, .x9, .{ .imm = lenMask(len) });
            }
            return .ne;
        },
        .@"and" => {
            // All of the length's bits set: the bits plus one, masked, are 0.
            try cg.e.addSub(.add, .x, .x9, .x9, .{ .imm = 1 });
            if (len < 64) {
                try cg.e.tst(.x, .x9, .{ .imm = lenMask(len) });
            } else {
                try cg.e.cmp(.x, .x9, .{ .imm = 0 });
            }
            return .eq;
        },
        .xor => {
            // The parity of the bits' count.
            if (!exact) try cg.e.logic(.@"and", .x, .x9, .x9, .{ .imm = lenMask(len) });
            try cg.e.fmovFromGpr(.f64, .v0, .x, .x9);
            try cg.e.cnt(.v0, .v0);
            try cg.e.addv(.v0, .v0);
            try cg.e.fmovToGpr(.w, .x9, .f32, .v0);
            try cg.e.tst(.x, .x9, .{ .imm = 1 });
            return .ne;
        },
        else => unreachable,
    }
}

fn reduce(cg: *CodeGen, inst: Inst.Index, ty: Index, op: Ir.ReduceOp, operand: Ref) Error!void {
    const ip = cg.ip;
    const s = shape(ip, cg.typeOf(operand)).?;
    const signed = Type.intInfo(ip, ty).signedness == .signed;
    const lb = s.lane.bytes();
    const es = s.esize();
    const chunks = s.chunks();
    // The valid bytes of the last chunk's register; the rest get the
    // operation's identity.
    const tail = s.len * lb - (chunks - 1) * 16;
    for (0..chunks) |kk| {
        const k: u32 = @intCast(kk);
        const r: VReg = if (k == 0) .v0 else .v1;
        try loadChunk(cg, r, operand, k);
        if (k == chunks - 1 and tail != 16) {
            const bits = lb * 8;
            const identity: u64 = switch (op) {
                .@"and" => lenMask(bits),
                .@"or", .xor, .add => 0,
                .mul => 1,
                .min => if (signed) lenMask(bits - 1) else lenMask(bits),
                .max => if (signed) @as(u64, 1) << @intCast(bits - 1) else 0,
            };
            var keep: [16]u8 = @splat(0);
            var fill: [16]u8 = @splat(0);
            @memset(keep[0..tail], 0xff);
            var i = tail;
            while (i < 16) : (i += lb) {
                for (0..lb) |j| fill[i + j] = @truncate(identity >> @intCast(8 * j));
            }
            // A short vector's load zeroed the register past its bytes; its
            // own register holds anything there.
            if (tail < @min(s.size, 16) or (tail < 16 and try cg.locOf(operand) == .vreg)) {
                try loadConst(cg, .v6, keep);
                try bitwise(cg, .@"and", r, r, .v6);
            }
            if (identity != 0) {
                try loadConst(cg, .v6, fill);
                try bitwise(cg, .orr, r, r, .v6);
            }
        }
        if (k != 0) {
            const c = try combine(cg, op, es, signed, .v0, .v1);
            if (c != .v0) try bitwise(cg, .orr, .v0, c, c);
        }
    }
    const u: u1 = @intFromBool(!signed);
    switch (op) {
        .add => if (es == 3) try emit(cg, 0x5ef1b800) else try emit(cg, across(0, es, 0b11011, .v0, .v0)),
        .min, .max => if (es == 3) {
            try emit(cg, ext(.v1, .v0, .v0, 8));
            const c = try minMax(cg, op == .max, 3, signed, .v0, .v0, .v1);
            if (c != .v0) try bitwise(cg, .orr, .v0, c, c);
        } else {
            try emit(cg, across(u, es, if (op == .max) 0b01010 else 0b11010, .v0, .v0));
        },
        .@"and", .@"or", .xor, .mul => {
            // Halves combined until one lane is left.
            var width: u32 = 8;
            while (width >= lb) : (width /= 2) {
                try emit(cg, ext(.v1, .v0, .v0, @intCast(width)));
                _ = try combine(cg, op, es, signed, .v0, .v1);
            }
        },
    }
    try emit(cg, umov0(es, .x9, .v0));
    try cg.setResult(inst, ty, .x9);
}

/// `a = op(a, b)` on integer lanes, for `reduce`; returns the register
/// holding it (v2 for 64-bit min and max).
fn combine(cg: *CodeGen, op: Ir.ReduceOp, es: u2, signed: bool, a: VReg, b: VReg) Error!VReg {
    switch (op) {
        .@"and" => try bitwise(cg, .@"and", a, a, b),
        .@"or" => try bitwise(cg, .orr, a, a, b),
        .xor => try bitwise(cg, .eor, a, a, b),
        .add => try emit(cg, same(0, es, 0b10000, a, a, b)),
        .mul => try emit(cg, same(0, es, 0b10011, a, a, b)),
        .min, .max => return minMax(cg, op == .max, es, signed, a, a, b),
    }
    return a;
}

/// `@shuffle`: per result chunk, table lookups (tbl, then tbx) over the
/// operands' chunks, at most four registers at a time.
fn shuffle(cg: *CodeGen, inst: Inst.Index, ty: Index, a: Ref, b: Ref, mask: Index) Error!void {
    const ip = cg.ip;
    const s = shape(ip, ty).?;
    const lb = s.lane.bytes();
    const a_chunks = shape(ip, cg.typeOf(a)).?.chunks();
    const b_shape = shape(ip, cg.typeOf(b));
    const dst = try dest(cg, inst, ty) orelse return;
    // Each result byte's source byte, counting a's chunks then b's, or
    // null for an undefined lane or padding.
    var src: [shared.max_bytes]?u32 = @splat(null);
    for (0..s.len) |i| {
        const m = elemValue(ip, mask, i);
        if (ip.keyTag(m) == .undef) continue;
        const sel = ip.intValue(i32, m).?;
        const base: u32 = if (sel >= 0) @as(u32, @intCast(sel)) * lb else a_chunks * 16 + @as(u32, @intCast(~sel)) * lb;
        for (0..lb) |q| src[i * lb + q] = base + @as(u32, @intCast(q));
    }
    const total_chunks = a_chunks + if (b_shape) |bs| bs.chunks() else 0;
    for (0..s.chunks()) |jj| {
        const j: u32 = @intCast(jj);
        var first = true;
        var g: u32 = 0;
        while (g * 4 < total_chunks) : (g += 1) {
            var idx: [16]u8 = @splat(0xff);
            var regs: u32 = 0;
            for (0..16) |p| {
                const x = src[j * 16 + p] orelse continue;
                if (x / 64 != g) continue;
                idx[p] = @intCast(x % 64);
                regs = @max(regs, x % 64 / 16 + 1);
            }
            if (regs == 0) continue;
            for (0..regs) |c| {
                const chunk = g * 4 + @as(u32, @intCast(c));
                const r: VReg = @fromBackingInt(@intCast(16 + c));
                if (chunk < a_chunks) {
                    try loadChunk(cg, r, a, chunk);
                } else {
                    try loadChunk(cg, r, b, chunk - a_chunks);
                }
            }
            try loadConst(cg, .v4, idx);
            try emit(cg, tbl(!first, regs, .v0, .v16, .v4));
            first = false;
        }
        if (!first) try storeChunk(cg, dst, .v0, s, j);
    }
}
