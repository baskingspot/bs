//! x86_64 lowering of the vector operations that `../vector.zig` accepts:
//! SSE2 on XMM registers, 16 bytes of lanes at a time (docs/slop/architecture.md,
//! "Vectors").
//!
//! Values: a vector of up to 16 bytes of lanes lives in an XMM register
//! (`Home.xmm`, the float class) or in a 16-byte slot; a longer one lives in
//! memory, 16-byte chunks in a row, which each operation processes in turn
//! in scratch registers. Bool vectors of up to 64 elements are their bits
//! in a general-purpose register or memory (element `i` is bit `i`; bits
//! above the length are 0). Lanes past a vector's length (the padding of a
//! `@Vector(3, u32)`) hold anything; compares and reductions ignore them.
//!
//! Scratch: xmm0-xmm5 (no value lives there; see `float_regs`), and rax,
//! rcx, rdx, and r11 as the scalar lowerings use them. An operand read in
//! place (`Home.deferred`, `Home.view`) may be addressed through r11, so it
//! is read before r11 is written.

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
const Mem = Encoder.Mem;
const Xmm = Encoder.Xmm;
const XmmRm = Encoder.XmmRm;
const Error = CodeGen.Error;

/// A vector type lowered as lanes.
pub const Shape = struct {
    lane: Lane,
    len: u32,

    fn bytes(s: Shape) u32 {
        return s.len * s.lane.bytes();
    }

    fn chunks(s: Shape) u32 {
        return (s.bytes() + 15) / 16;
    }

    fn perChunk(s: Shape) u32 {
        return 16 / s.lane.bytes();
    }

    fn float(s: Shape) Encoder.Float {
        return if (s.lane == .f64) .f64 else .f32;
    }
};

/// The lanes of vector type `ty`, if it is one that `../vector.zig` may
/// accept (not a bool vector).
pub fn shape(ip: *const InternPool, ty: Index) ?Shape {
    const l = shared.lane(ip, ty) orelse return null;
    if (l == .bool) return null;
    const len = ip.keyPayload(.vector_type, ty).len;
    if (len == 0 or len * l.bytes() > shared.max_bytes) return null;
    return .{ .lane = l, .len = len };
}

/// Whether `ty`'s values live in one XMM register when they get one.
/// Vectors of narrow integers (`../vector.zig`) stay in memory, where
/// their layout is settled.
pub fn inXmm(ip: *const InternPool, ty: Index) bool {
    const s = shape(ip, ty) orelse return false;
    return s.bytes() <= 16 and !shared.narrow(ip, ty);
}

/// Whether `ty` is a bool vector kept as its bits (`../vector.zig`).
pub fn isBits(ip: *const InternPool, ty: Index) bool {
    if (ip.keyTag(ty) != .vector_type) return false;
    const v = ip.keyPayload(.vector_type, ty);
    return v.child == .bool_type and v.len != 0 and v.len <= shared.max_bools;
}

/// Whether `inst`, an instruction on vectors, is lowered here. These
/// lowerings use only the scratch registers above, so none is a clobber
/// point (`CodeGen.clobbers`).
pub fn lowers(cg: *CodeGen, inst: Inst.Index) bool {
    const ip = cg.ip;
    const ir = cg.ir;
    const data = ir.instructions.items(.data)[@backingInt(inst)];
    return switch (ir.instructions.items(.tag)[@backingInt(inst)]) {
        .cmp_vector, .reduce, .select, .shuffle => true,
        .min_int, .max_int => true,
        .add_wrap, .sub_wrap, .mul_wrap, .bit_and, .bit_or, .xor, .shl, .shr, .add_float, .sub_float, .mul_float, .div_float, .min_float, .max_float => ip.keyTag(cg.typeOf(data.bin_op.lhs)) == .vector_type,
        .neg_float, .abs_float, .sqrt => ip.keyTag(cg.typeOf(data.un_op)) == .vector_type,
        .not => ip.keyTag(data.ty_op.ty) == .vector_type,
        // Sema emits these on vectors only when `shared.native` says so.
        .intcast, .trunc => ip.keyTag(data.ty_op.ty) == .vector_type,
        // Between 16-byte vectors in XMM registers, or one and a 16-byte
        // value in memory (an array, a wide integer): one movdqu. Between
        // a vector in an XMM register and an integer or array of 1, 2, 4,
        // or 8 bytes in a general-purpose register: one movd or movq.
        .bitcast => blk: {
            const ty = data.ty_op.ty;
            const src_ty = cg.typeOf(data.ty_op.operand);
            if ((inXmm(ip, src_ty) and inGpr(ip, ty)) or (inXmm(ip, ty) and inGpr(ip, src_ty))) break :blk true;
            if (Type.abiSize(ip, ty) != 16 or Type.abiSize(ip, src_ty) != 16) break :blk false;
            break :blk (inXmm(ip, ty) or inXmm(ip, src_ty)) and (inXmm(ip, ty) or inMem(cg, ty)) and (inXmm(ip, src_ty) or inMem(cg, src_ty));
        },
        .aggregate_init => isSplat(cg, data),
        else => false,
    };
}

/// Whether values of 16-byte type `ty` live in memory, never in
/// registers.
fn inMem(cg: *CodeGen, ty: Index) bool {
    return !inXmm(cg.ip, ty) and !cg.inPair(ty);
}

/// Whether values of type `ty` are an integer or an array of 1, 2, 4, or 8
/// bytes, which live in a general-purpose register, extended as a load
/// extends them (`CodeGen.normalize`).
fn inGpr(ip: *const InternPool, ty: Index) bool {
    return switch (Type.abiSize(ip, ty)) {
        1, 2, 4, 8 => Type.isInt(ip, ty) or ip.keyTag(ty) == .array_type,
        else => false,
    };
}

/// For `CodeGen.storeInPlace`: whether bitcast `inst`, of a vector that an
/// operation here computed to an array or integer in memory of the same
/// size, writes the stored-to memory itself (`CodeGen.resultMem`): its
/// operand gets its own register or slot (no `Home` yet), not memory the
/// store may overlap.
pub fn bitcastInPlace(cg: *CodeGen, inst: Inst.Index) bool {
    const data = cg.ir.instructions.items(.data)[@backingInt(inst)];
    const x = data.ty_op.operand.toIndex() orelse return false;
    if (shape(cg.ip, cg.typeOf(data.ty_op.operand)) == null or !lowers(cg, x)) return false;
    if (Type.abiSize(cg.ip, data.ty_op.ty) != Type.abiSize(cg.ip, cg.typeOf(data.ty_op.operand))) return false;
    return cg.homes[@backingInt(x)] == .none;
}

/// Whether `aggregate_init` `data` broadcasts one element to a vector of
/// lanes (`splat`).
fn isSplat(cg: *CodeGen, data: Inst.Data) bool {
    if (shape(cg.ip, data.ty_pl.ty) == null) return false;
    const extra = cg.ir.extraData(Ir.Aggregate, data.ty_pl.payload);
    const elems = cg.ir.refSlice(extra.end, extra.data.len);
    // A constant element (after the rewrite rules fold one) is
    // broadcast too, but not an undefined one.
    if (elems[0].toInterned()) |v| if (cg.ip.keyTag(v) == .undef) return false;
    for (elems[1..]) |x| if (x != elems[0]) return false;
    return true;
}

/// Whether `inst` reads its vector operands chunk by chunk (`chunk`), so a
/// load of one can be read in place (`deferOperands`).
fn readsChunks(cg: *CodeGen, inst: Inst.Index) bool {
    return switch (cg.ir.instructions.items(.tag)[@backingInt(inst)]) {
        .shuffle => false,
        .not, .bit_and, .bit_or, .xor => shape(cg.ip, cg.ir.typeOfIndex(inst, cg.ip)) != null,
        else => lowers(cg, inst),
    };
}

/// For `CodeGen.planDeferred`: the vector operands of `inst` that are loads
/// used only by it are read in place (`Home.deferred`), and so are loads
/// seen through a bitcast to a vector used only by it (`Home.view`), when
/// the load's memory covers the vector's chunks. `before` are the values
/// before `inst` in its block.
pub fn deferOperands(cg: *CodeGen, inst: Inst.Index, before: []const Inst.Index) void {
    if (cg.ir.instructions.items(.tag)[@backingInt(inst)] == .reduce) fuseIndexSelect(cg, inst, before);
    if (!readsChunks(cg, inst)) return;
    const T = struct {
        cg: *CodeGen,
        before: []const Inst.Index,
        at: u32,
        /// A bitcast reads its operand, an array or a wide integer, in
        /// place too.
        bitcast: bool,
        const Self = @This();
        pub fn use(t: Self, ref: Ref) void {
            const c = t.cg;
            const ip = c.ip;
            const i = ref.toIndex() orelse return;
            if (shape(ip, c.typeOf(ref)) == null and !t.bitcast) return;
            const ii = @backingInt(i);
            const live = c.ssa.live.slice();
            if (live.items(.uses)[ii] != 1 or c.homes[ii] != .none) return;
            const tags = c.ir.instructions.items(.tag);
            const data = c.ir.instructions.items(.data)[ii];
            switch (tags[ii]) {
                .load => {
                    c.deferLoad(ref, t.before, &.{}, t.at);
                    // No register either.
                    if (c.homes[ii] == .deferred) live.items(.reg)[ii] = Ssa.no_reg;
                },
                .bitcast => {
                    const l = data.ty_op.operand.toIndex() orelse return;
                    if (tags[@backingInt(l)] != .load or live.items(.fate)[ii] != .normal) return;
                    // A 16-byte bitcast reads its load in place itself, at
                    // its own position, which a view would move here.
                    if (c.homes[@backingInt(l)] != .none) return;
                    if (Type.abiSize(ip, c.typeOf(data.ty_op.operand)) < Type.abiSize(ip, data.ty_op.ty)) return;
                    c.deferLoad(data.ty_op.operand, t.before, &.{}, t.at);
                    if (c.homes[@backingInt(l)] != .deferred) return;
                    c.homes[ii] = .view;
                    live.items(.reg)[ii] = Ssa.no_reg;
                    live.items(.reg)[@backingInt(l)] = Ssa.no_reg;
                },
                else => {},
            }
        }
    };
    const pos = cg.ssa.live.items(.def)[@backingInt(inst)];
    const bitcast = cg.ir.instructions.items(.tag)[@backingInt(inst)] == .bitcast;
    // A bitcast that the next value, a vector operation, alone reads is
    // better read in place by that operation (a `view`).
    if (bitcast and cg.ssa.live.items(.uses)[@backingInt(inst)] == 1 and viewedByNext(cg, inst, before)) return;
    Ssa.forEachOperand(cg.ir, inst, T{ .cg = cg, .before = before, .at = pos, .bitcast = bitcast });
}

/// For `deferOperands`: whether the value after `inst` in its block
/// (`before` are the ones before it) reads `inst` chunk by chunk.
fn viewedByNext(cg: *CodeGen, inst: Inst.Index, before: []const Inst.Index) bool {
    const all = cg.ssa.values.items(.inst);
    var j = (@intFromPtr(before.ptr) - @intFromPtr(all.ptr)) / @sizeOf(Inst.Index) + before.len;
    std.debug.assert(all[j] == inst);
    const tags = cg.ir.instructions.items(.tag);
    const next = while (j + 1 < all.len) {
        j += 1;
        if (tags[@backingInt(all[j])] != .dbg_stmt) break all[j];
    } else return false;
    if (!readsChunks(cg, next)) return false;
    const T = struct {
        inst: Inst.Index,
        found: *bool,
        const Self = @This();
        pub fn use(t: Self, ref: Ref) void {
            if (ref.toIndex() == t.inst) t.found.* = true;
        }
    };
    var found = false;
    Ssa.forEachOperand(cg.ir, next, T{ .inst = inst, .found = &found });
    return found;
}

/// For `deferOperands`: `@reduce(.Min, @select(T, pred, iota, @splat(m)))`
/// with `m` at least the last index is the index of `pred`'s first set
/// bit, or `m` (`std.simd.firstTrue`); `.Max` with `m` 0 is the last set
/// bit's, or 0 (`lastTrue`). The select, whose only user is the reduce
/// right after it, is not emitted (`Home.view`), and `reduceIndex` scans
/// `pred`'s bits instead.
fn fuseIndexSelect(cg: *CodeGen, inst: Inst.Index, before: []const Inst.Index) void {
    const ip = cg.ip;
    const ir = cg.ir;
    const tags = ir.instructions.items(.tag);
    const x = ir.extraData(Ir.Reduce, ir.instructions.items(.data)[@backingInt(inst)].ty_pl.payload).data;
    const op = x.operation();
    if (op != .min and op != .max) return;
    const si = x.operand.toIndex() orelse return;
    const ii = @backingInt(si);
    if (tags[ii] != .select) return;
    const live = cg.ssa.live.slice();
    if (live.items(.uses)[ii] != 1 or live.items(.fate)[ii] != .normal or cg.homes[ii] != .none) return;
    const adjacent = for (0..@min(before.len, 8)) |j| {
        const v = before[before.len - 1 - j];
        if (v == si) break true;
        switch (tags[@backingInt(v)]) {
            .dbg_stmt, .dbg_inline_begin, .dbg_inline_end => {},
            else => break false,
        }
    } else false;
    if (!adjacent) return;
    const sel = ir.extraData(Ir.Select, ir.instructions.items(.data)[ii].ty_pl.payload).data;
    const ty = cg.typeOf(x.operand);
    if (!isBits(ip, cg.typeOf(sel.pred)) or Type.intInfo(ip, Type.childType(ip, ty)).signedness != .unsigned) return;
    const a = sel.a.toInterned() orelse return;
    const b = sel.b.toInterned() orelse return;
    const len = ip.keyPayload(.vector_type, ty).len;
    if (ip.keyTag(a) != .aggregate) return;
    switch (ip.keyPayload(.aggregate, a).storage) {
        .elems => |elems| for (elems, 0..) |el, i| {
            if (ip.keyTag(el) != .int or ip.intValue(u64, el) != i) return;
        },
        else => return,
    }
    const m = splatBits(cg, b) orelse return;
    if (if (op == .min) m < len - 1 else m != 0) return;
    if (sel.pred.toIndex()) |p| {
        const end = live.items(.end);
        end[@backingInt(p)] = @max(end[@backingInt(p)], live.items(.def)[@backingInt(inst)]);
    }
    cg.homes[ii] = .view;
    live.items(.reg)[ii] = Ssa.no_reg;
}

/// `reduce` of a select fused by `fuseIndexSelect`: bsf or bsr of the
/// predicate's bits, `m` when none is set.
fn reduceIndex(cg: *CodeGen, inst: Inst.Index, ty: Index, op: Ir.ReduceOp, operand: Ref) Error!void {
    const ir = cg.ir;
    const e = &cg.e;
    const sel = ir.extraData(Ir.Select, ir.instructions.items(.data)[@backingInt(operand.toIndex().?)].ty_pl.payload).data;
    const len = cg.ip.keyPayload(.vector_type, cg.typeOf(operand)).len;
    const d = cg.destReg(inst);
    // Bits filling their bytes are scanned where they are (see
    // `bitsFlags`).
    const src: Reg = if (exactBits(len)) if (sel.pred.toIndex()) |p| switch (cg.homes[@backingInt(p)]) {
        .reg => |r| r,
        else => .rax,
    } else .rax else .rax;
    if (src == .rax) {
        try cg.load(.rax, sel.pred);
        if (!exactBits(len)) try andImm(cg, .rax, lenMask(len));
    }
    try e.mov(.qword, .{ .reg = .rcx }, .{ .imm = @bitCast(splatBits(cg, sel.b.toInterned().?).?) });
    try e.bitScan(op == .max, .qword, .rax, .{ .reg = src });
    try e.cmov(.e, .qword, .rax, .{ .reg = .rcx });
    if (d != .rax) try e.mov(.qword, .{ .reg = d }, .{ .reg = .rax });
    try cg.setResult(inst, ty, d);
}

pub fn gen(cg: *CodeGen, inst: Inst.Index, tag: Inst.Tag, data: Inst.Data) Error!void {
    const ip = cg.ip;
    switch (tag) {
        .intcast, .trunc => try cast(cg, inst, data.ty_op.ty, data.ty_op.operand),
        .cmp_vector => {
            const x = cg.ir.extraData(Ir.VectorCmp, data.ty_pl.payload).data;
            try compare(cg, inst, data.ty_pl.ty, x.operator(), x.lhs, x.rhs);
        },
        .reduce => {
            const x = cg.ir.extraData(Ir.Reduce, data.ty_pl.payload).data;
            if (isBits(ip, cg.typeOf(x.operand))) return reduceBits(cg, inst, x.operation(), x.operand);
            // A select fused by `fuseIndexSelect` (a bitcast of a load
            // read in place is a `view` too).
            if (x.operand.toIndex()) |o| if (cg.homes[@backingInt(o)] == .view and cg.ir.instructions.items(.tag)[@backingInt(o)] == .select)
                return reduceIndex(cg, inst, data.ty_pl.ty, x.operation(), x.operand);
            try reduce(cg, inst, data.ty_pl.ty, x.operation(), x.operand);
        },
        .select => {
            if (cg.homes[@backingInt(inst)] == .view) return; // read by its reduce
            const x = cg.ir.extraData(Ir.Select, data.ty_pl.payload).data;
            try select(cg, inst, data.ty_pl.ty, x.pred, x.a, x.b);
        },
        .shuffle => {
            const x = cg.ir.extraData(Ir.Shuffle, data.ty_pl.payload).data;
            try shuffle(cg, inst, data.ty_pl.ty, x.a, x.b, x.mask);
        },
        .min_float, .max_float => try floatMinMax(cg, inst, tag == .max_float, cg.typeOf(data.bin_op.lhs), data.bin_op.lhs, data.bin_op.rhs),
        .shl, .shr => try shift(cg, inst, tag == .shl, cg.typeOf(data.bin_op.lhs), data.bin_op.lhs, data.bin_op.rhs),
        .neg_float, .abs_float, .sqrt => try floatUnary(cg, inst, tag, data.un_op),
        .aggregate_init => {
            const extra = cg.ir.extraData(Ir.Aggregate, data.ty_pl.payload);
            try splat(cg, inst, data.ty_pl.ty, cg.ir.refSlice(extra.end, extra.data.len)[0]);
        },
        .bitcast => {
            if (inGpr(ip, data.ty_op.ty)) return toGpr(cg, inst, data.ty_op.ty, data.ty_op.operand);
            const dst = try Dst.of(cg, inst, data.ty_op.ty);
            if (inGpr(ip, cg.typeOf(data.ty_op.operand))) {
                const r = dst.home orelse .xmm0;
                const size: Encoder.Size = if (Type.abiSize(ip, cg.typeOf(data.ty_op.operand)) == 8) .qword else .dword;
                const g = gprOf(cg, data.ty_op.operand) orelse g: {
                    try cg.load(.rax, data.ty_op.operand);
                    break :g .rax;
                };
                try cg.e.movToXmm(size, r, .{ .reg = g });
                return dst.put(cg, r, 0);
            }
            const r = dst.home orelse .xmm0;
            try loadChunk(cg, r, data.ty_op.operand, 0);
            try dst.put(cg, r, 0);
        },
        .not => {
            const ty = data.ty_op.ty;
            if (isBits(ip, ty)) {
                const d = cg.destReg(inst);
                try cg.load(d, data.ty_op.operand);
                try xorImm(cg, d, lenMask(ip.keyPayload(.vector_type, ty).len));
                return cg.setResult(inst, ty, d);
            }
            const s = shape(ip, ty).?;
            const dst = try Dst.of(cg, inst, ty);
            for (0..s.chunks()) |k| {
                const r = dst.home orelse .xmm0;
                try loadChunk(cg, r, data.ty_op.operand, @intCast(k));
                try cg.e.pint(.pcmpeqd, .xmm1, .{ .reg = .xmm1 });
                try cg.e.pint(.pxor, r, .{ .reg = .xmm1 });
                try dst.put(cg, r, @intCast(k));
            }
        },
        else => {
            const ty = cg.typeOf(data.bin_op.lhs);
            if (isBits(ip, ty)) {
                // Bitwise operations on bool vectors' bits, in the
                // result's register (commuted when the right side is in
                // it), from the right side's register when it has one.
                const d = cg.destReg(inst);
                const lhs, const rhs = if (gprOf(cg, data.bin_op.rhs) == d and data.bin_op.lhs != data.bin_op.rhs)
                    .{ data.bin_op.rhs, data.bin_op.lhs }
                else
                    .{ data.bin_op.lhs, data.bin_op.rhs };
                try cg.load(d, lhs);
                const src: Reg = gprOf(cg, rhs) orelse blk: {
                    try cg.load(.rcx, rhs);
                    break :blk .rcx;
                };
                try cg.e.alu(switch (tag) {
                    .bit_and => .@"and",
                    .bit_or => .@"or",
                    .xor => .xor,
                    else => unreachable,
                }, .qword, .{ .reg = d }, .{ .reg = src });
                return cg.setResult(inst, ty, d);
            }
            try arith(cg, inst, tag, ty, data.bin_op.lhs, data.bin_op.rhs);
        },
    }
}

// ---------------------------------------------------------------------------
// Operands and results

/// Where 16-byte chunk `k` of a vector operand is.
const Chunk = union(enum) {
    reg: Xmm,
    /// 16-byte aligned memory, usable as an SSE operand.
    mem: Mem,
    /// Memory of unknown alignment.
    umem: Mem,
    zero,
    ones,
};

/// The repeated element's bits of constant vector `val` whose elements are
/// all the same, else null.
fn splatBits(cg: *CodeGen, val: Index) ?u64 {
    const ip = cg.ip;
    if (ip.keyTag(val) != .aggregate) return null;
    const a = ip.keyPayload(.aggregate, val);
    const e = switch (a.storage) {
        .repeated_elem => |e| e,
        else => return null,
    };
    return switch (ip.indexToKey(e)) {
        .int => CodeGen.intBits(ip, e),
        .float => |f| @truncate(f.bits()),
        else => null,
    };
}

/// The general-purpose register value `ref` is in, if any.
fn gprOf(cg: *CodeGen, ref: Ref) ?Reg {
    const i = ref.toIndex() orelse return null;
    return switch (cg.homes[@backingInt(i)]) {
        .reg => |r| r,
        else => null,
    };
}

/// The bits of integer or float constant `val`, as `splatBits` reads an
/// element.
fn constBits(cg: *CodeGen, val: Index) ?u64 {
    return switch (cg.ip.indexToKey(val)) {
        .int => CodeGen.intBits(cg.ip, val),
        .float => |f| @truncate(f.bits()),
        else => null,
    };
}

fn chunk(cg: *CodeGen, ref: Ref, k: u32) Error!Chunk {
    const ip = cg.ip;
    if (ref.toInterned()) |v| {
        const ty = ip.typeOf(v);
        if (shape(ip, ty)) |s| if (splatBits(cg, v)) |all_bits| {
            const lb = s.lane.bytes();
            const bits = all_bits & lenMask(lb * 8);
            if (bits == 0) return .zero;
            if (bits == lenMask(lb * 8)) return .ones;
        };
        return switch (try cg.locOf(ref)) {
            .mem => |m| .{ .mem = CodeGen.offsetMem(m, 16 * k) },
            else => unreachable, // a vector constant lives in memory
        };
    }
    const i = ref.toIndex().?;
    switch (cg.homes[@backingInt(i)]) {
        .xmm => |x| {
            std.debug.assert(k == 0);
            return .{ .reg = x };
        },
        // rbp is 16-byte aligned; a stack argument may be only 8.
        .slot => |off| {
            const m = Mem.at(.rbp, off + @as(i32, @intCast(16 * k)));
            return if (@mod(off, 16) == 0) .{ .mem = m } else .{ .umem = m };
        },
        // A bitcast of a load read in place: the load's memory.
        .view => return switch (try chunk(cg, cg.ir.instructions.items(.data)[@backingInt(i)].ty_op.operand, k)) {
            .mem => |m| .{ .umem = m },
            else => |c| c,
        },
        else => return switch (try cg.locOf(ref)) {
            .mem => |m| .{ .umem = CodeGen.offsetMem(m, 16 * k) },
            else => unreachable,
        },
    }
}

/// Bitcast of vector `operand`, which lives in an XMM register when it has
/// one, to `ty`, an integer or array of 1, 2, 4, or 8 bytes (`inGpr`): its
/// low bytes, extended as a load of `ty` extends them.
fn toGpr(cg: *CodeGen, inst: Inst.Index, ty: Index, operand: Ref) Error!void {
    const e = &cg.e;
    const d = cg.destReg(inst);
    const n = Type.abiSize(cg.ip, ty);
    // A signed integer, or one narrower than its bytes, is extended from
    // its bits afterwards; the rest are zero-extended.
    const extend = Type.isInt(cg.ip, ty) and (Type.intInfo(cg.ip, ty).signedness == .signed or Type.intInfo(cg.ip, ty).bits != 8 * n);
    switch (try chunk(cg, operand, 0)) {
        .mem, .umem => |m| switch (n) {
            8 => try e.mov(.qword, .{ .reg = d }, .{ .mem = m }),
            4 => try e.mov(.dword, .{ .reg = d }, .{ .mem = m }),
            else => try e.movzx(.dword, d, CodeGen.sizeOf(n), .{ .mem = m }),
        },
        else => |c| {
            const x = switch (c) {
                .reg => |x| x,
                else => x: {
                    try loadFrom(cg, .xmm0, c);
                    break :x .xmm0;
                },
            };
            try e.movFromXmm(if (n == 8) .qword else .dword, .{ .reg = d }, x);
            if (n < 4 and !extend) try e.movzx(.dword, d, CodeGen.sizeOf(n), .{ .reg = d });
        },
    }
    if (extend) try cg.normalize(d, ty);
    return cg.setResult(inst, ty, d);
}

/// Loads chunk `k` of vector `ref` into `r`.
fn loadChunk(cg: *CodeGen, r: Xmm, ref: Ref, k: u32) Error!void {
    return loadFrom(cg, r, try chunk(cg, ref, k));
}

fn loadFrom(cg: *CodeGen, r: Xmm, c: Chunk) Error!void {
    switch (c) {
        .reg => |x| if (x != r) try cg.e.movdq(true, .{ .reg = r }, .{ .reg = x }),
        .mem => |m| try cg.e.movdq(true, .{ .reg = r }, .{ .mem = m }),
        .umem => |m| try cg.e.movdq(false, .{ .reg = r }, .{ .mem = m }),
        .zero => try cg.e.pint(.pxor, r, .{ .reg = r }),
        .ones => try cg.e.pint(.pcmpeqd, r, .{ .reg = r }),
    }
}

/// Chunk `k` of vector `ref` as the source of an SSE instruction: its
/// register, its aligned memory, or `scratch` loaded with it.
fn srcChunk(cg: *CodeGen, ref: Ref, k: u32, scratch: Xmm) Error!XmmRm {
    switch (try chunk(cg, ref, k)) {
        .reg => |x| return .{ .reg = x },
        .mem => |m| return .{ .mem = m },
        else => |c| {
            try loadFrom(cg, scratch, c);
            return .{ .reg = scratch };
        },
    }
}

/// `@intCast` that widens or `@truncate` (`intcast`, `trunc`) of integer
/// vector `operand` to vector type `ty`, chunk by chunk in xmm0. Widening
/// moves each result chunk's source bytes to the bottom of a register and
/// interleaves its lanes with zeros or, for a signed source, their sign
/// masks, once per doubling. Truncating packs pairs of source chunks into
/// one with lanes half as wide (`packTree`).
fn cast(cg: *CodeGen, inst: Inst.Index, ty: Index, operand: Ref) Error!void {
    const ip = cg.ip;
    const e = &cg.e;
    const src_ty = cg.typeOf(operand);
    const s = shape(ip, src_ty).?;
    const d = shape(ip, ty).?;
    const dst = try Dst.of(cg, inst, ty);
    const widen = d.lane.bytes() > s.lane.bytes();
    const ratio = if (widen) d.lane.bytes() / s.lane.bytes() else s.lane.bytes() / d.lane.bytes();
    const signed = Type.intInfo(ip, Type.childType(ip, src_ty)).signedness == .signed;
    for (0..d.chunks()) |jj| {
        const j: u32 = @intCast(jj);
        if (!widen) {
            try packTree(cg, operand, s, d.lane, j * ratio, ratio, .xmm0);
        } else {
            const off = j * 16 / ratio;
            try loadChunk(cg, .xmm0, operand, off / 16);
            if (off % 16 != 0) try e.pshift(.psrldq, .xmm0, @intCast(off % 16));
            var l = s.lane;
            while (l != d.lane) : (l = wider(l)) {
                try e.pint(.pxor, .xmm1, .{ .reg = .xmm1 });
                if (signed) try e.pint(switch (l) {
                    .i8 => .pcmpgtb,
                    .i16 => .pcmpgtw,
                    else => .pcmpgtd,
                }, .xmm1, .{ .reg = .xmm0 });
                try e.pint(switch (l) {
                    .i8 => .punpcklbw,
                    .i16 => .punpcklwd,
                    else => .punpckldq,
                }, .xmm0, .{ .reg = .xmm1 });
            }
        }
        try dst.put(cg, .xmm0, j);
    }
}

fn wider(l: Lane) Lane {
    return switch (l) {
        .i8 => .i16,
        .i16 => .i32,
        .i32 => .i64,
        else => unreachable,
    };
}

/// Computes in `r` one chunk of lanes `out` from the `count` source chunks
/// of `operand` (shape `s`) from `first` on, a power of two: the two halves
/// computed in lanes twice as wide, in `r` and the next register, then
/// each lane's low half kept, in order. Source chunks past the operand's
/// are padding, never read. Uses `r` up to xmm3 and xmm5.
fn packTree(cg: *CodeGen, operand: Ref, s: Shape, out: Lane, first: u32, count: u32, r: Xmm) Error!void {
    const e = &cg.e;
    if (count == 1) return loadChunk(cg, r, operand, first);
    const in = wider(out);
    const b: Xmm = @fromBackingInt(@intCast(@backingInt(r) + 1));
    try packTree(cg, operand, s, in, first, count / 2, r);
    // The right half, or the left again when it is all padding.
    const right = first + count / 2 < s.chunks();
    if (right) try packTree(cg, operand, s, in, first + count / 2, count / 2, b);
    const src: Xmm = if (right) b else r;
    switch (out) {
        // packuswb saturates, so clear each word's high byte first.
        .i8 => {
            try e.pint(.pcmpeqw, .xmm5, .{ .reg = .xmm5 });
            try e.pshift(.psrlw, .xmm5, 8);
            try e.pint(.pand, r, .{ .reg = .xmm5 });
            if (right) try e.pint(.pand, b, .{ .reg = .xmm5 });
            try e.pint(.packuswb, r, .{ .reg = src });
        },
        // packssdw saturates, so sign-extend each dword's low word first.
        .i16 => {
            const both = [_]Xmm{ r, b };
            for (both[0..if (right) 2 else 1]) |x| {
                try e.pshift(.pslld, x, 16);
                try e.pshift(.psrad, x, 16);
            }
            try e.pint(.packssdw, r, .{ .reg = src });
        },
        .i32 => {
            try e.pshuf(.d, r, .{ .reg = r }, 0x08);
            if (right) try e.pshuf(.d, b, .{ .reg = b }, 0x08);
            try e.pint(.punpcklqdq, r, .{ .reg = src });
        },
        else => unreachable,
    }
}

/// Where a vector result goes: its register, or its memory, chunk by chunk.
const Dst = struct {
    home: ?Xmm,
    mem: ?Mem = null,
    aligned: bool = false,

    fn of(cg: *CodeGen, inst: Inst.Index, ty: Index) Error!Dst {
        if (cg.xmmOf(inst.toRef())) |x| return .{ .home = x };
        const m = (try cg.resultMem(inst, ty)).?;
        const home = cg.homes[@backingInt(inst)];
        return .{ .home = null, .mem = m, .aligned = home == .slot and @mod(home.slot, 16) == 0 };
    }

    /// Stores chunk `k`, computed in `r`, to its memory.
    fn put(d: Dst, cg: *CodeGen, r: Xmm, k: u32) Error!void {
        if (d.home) |h| {
            if (h != r) try cg.e.movdq(true, .{ .reg = h }, .{ .reg = r });
            return;
        }
        try cg.e.movdq(d.aligned, .{ .mem = CodeGen.offsetMem(d.mem.?, 16 * k) }, .{ .reg = r });
    }
};

/// The register for a chunk of `inst`'s result computed from `lhs` first
/// and `rhs` second: the result's home unless `rhs` is in it (and is not
/// `lhs`), else xmm0.
fn destFor(cg: *CodeGen, dst: Dst, lhs: Ref, rhs: Ref) Xmm {
    const h = dst.home orelse return .xmm0;
    if (lhs != rhs) if (cg.xmmOf(rhs)) |x| if (x == h) return .xmm0;
    return h;
}

// ---------------------------------------------------------------------------
// Constants

/// `(1 << bits) - 1`, for 1 to 64 bits.
fn lenMask(bits: u32) u64 {
    return if (bits >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(bits)) - 1;
}

/// `reg ^= mask`. Uses r11.
fn xorImm(cg: *CodeGen, reg: Reg, mask: u64) Error!void {
    if (std.math.cast(i32, @as(i64, @bitCast(mask)))) |imm| return cg.e.alu(.xor, .qword, .{ .reg = reg }, .{ .imm = imm });
    try cg.e.mov(.qword, .{ .reg = cg.r11() }, .{ .imm = @bitCast(mask) });
    try cg.e.alu(.xor, .qword, .{ .reg = reg }, .{ .reg = cg.r11() });
}

/// `reg &= mask`. Uses r11.
fn andImm(cg: *CodeGen, reg: Reg, mask: u64) Error!void {
    if (mask == std.math.maxInt(u64)) return;
    if (mask == std.math.maxInt(u32)) return cg.e.mov(.dword, .{ .reg = reg }, .{ .reg = reg });
    if (std.math.cast(i32, @as(i64, @bitCast(mask)))) |imm| return cg.e.alu(.@"and", .qword, .{ .reg = reg }, .{ .imm = imm });
    try cg.e.mov(.qword, .{ .reg = cg.r11() }, .{ .imm = @bitCast(mask) });
    try cg.e.alu(.@"and", .qword, .{ .reg = reg }, .{ .reg = cg.r11() });
}

/// A 16-byte constant in read-only data, 16-byte aligned.
fn constMem(cg: *CodeGen, bytes: [16]u8) Error!Mem {
    return Mem.sym(try cg.emit.contentAtom(16, &bytes, &.{}, &.{}), 0);
}

/// 16 bytes of `n` lanes of `lane_bytes` each, lane `i` holding `f(i)`.
fn laneConst(cg: *CodeGen, lane_bytes: u32, f: *const fn (u32) u64) Error!Mem {
    var b: [16]u8 = undefined;
    for (0..16 / lane_bytes) |i| {
        const v = f(@intCast(i));
        for (0..lane_bytes) |j| b[i * lane_bytes + j] = @truncate(v >> @intCast(8 * j));
    }
    return constMem(cg, b);
}

/// Whether the target CPU has x86 feature `f` (`-mcpu`).
fn has(cg: *CodeGen, f: std.Target.x86.Feature) bool {
    return cg.emit.zcu.cpu.has(.x86, f);
}

/// 16 bytes of lanes with only their sign bit set, for unsigned compares
/// as signed ones.
fn signMem(cg: *CodeGen, lane: Lane) Error!Mem {
    return laneConst(cg, lane.bytes(), switch (lane) {
        .i8 => struct {
            fn f(_: u32) u64 {
                return 0x80;
            }
        }.f,
        .i16 => struct {
            fn f(_: u32) u64 {
                return 0x8000;
            }
        }.f,
        .i32 => struct {
            fn f(_: u32) u64 {
                return 0x8000_0000;
            }
        }.f,
        .i64 => struct {
            fn f(_: u32) u64 {
                return 1 << 63;
            }
        }.f,
        else => unreachable,
    });
}

// ---------------------------------------------------------------------------
// Operations

/// Shift of every lane of integer vector `lhs` (of type `ty`) left, or
/// right (arithmetically if signed), by `rhs`, whose lanes all hold the
/// same amount (Sema's `vectorShift`), so lane 0's is the count: an
/// immediate when constant, else in xmm5 (and the derived counts below in
/// xmm4). 16-, 32- and 64-bit lanes shift directly. Bytes shift as words,
/// then a mask clears the bits that crossed from the neighbouring byte;
/// signed bytes shift right as the high bytes of words (`punpck`) by 8
/// more, then pack. A signed 64-bit lane shifts right logically, with its
/// sign mask shifted left by 64 - n or'ed in.
fn shift(cg: *CodeGen, inst: Inst.Index, left: bool, ty: Index, lhs: Ref, rhs: Ref) Error!void {
    const ip = cg.ip;
    const e = &cg.e;
    const s = shape(ip, ty).?;
    const signed = isSigned(cg, ty);
    const Count = union(enum) { imm: u8, xmm: Xmm };
    // The amount, and the one the lowering needs besides: 8 + n for signed
    // bytes, 64 - n for signed 64-bit lanes.
    const extra: ?u8 = if (left or !signed) null else switch (s.lane) {
        .i8 => 8,
        .i64 => 64,
        else => null,
    };
    var n: Count = undefined;
    var n2: Count = undefined;
    if (rhs.toInterned()) |v| {
        const k: u8 = @intCast(CodeGen.intBits(ip, elemValue(ip, v, 0)));
        n = .{ .imm = k };
        if (extra) |x| n2 = .{ .imm = if (x == 8) 8 + k else 64 - k };
    } else {
        switch (try chunk(cg, rhs, 0)) {
            .reg => |x| {
                try e.movFromXmm(.dword, .{ .reg = .rax }, x);
                try e.movzx(.dword, .rax, .byte, .{ .reg = .rax });
            },
            .mem, .umem => |m| try e.movzx(.dword, .rax, .byte, .{ .mem = m }),
            .zero, .ones => unreachable, // a constant
        }
        try e.movToXmm(.dword, .xmm5, .{ .reg = .rax });
        n = .{ .xmm = .xmm5 };
        if (extra) |x| {
            if (x == 8) {
                try e.alu(.add, .dword, .{ .reg = .rax }, .{ .imm = 8 });
            } else {
                try e.mov(.dword, .{ .reg = .rcx }, .{ .imm = 64 });
                try e.alu(.sub, .dword, .{ .reg = .rcx }, .{ .reg = .rax });
                try e.mov(.dword, .{ .reg = .rax }, .{ .reg = .rcx });
            }
            try e.movToXmm(.dword, .xmm4, .{ .reg = .rax });
            n2 = .{ .xmm = .xmm4 };
        }
    }
    const Op = struct {
        fn by(enc: *Encoder, op: Encoder.PshiftOp, r: Xmm, c: Count) Error!void {
            switch (c) {
                .imm => |k| try enc.pshift(op, r, k),
                .xmm => |x| try enc.pint(switch (op) {
                    .psllw => .psllw,
                    .pslld => .pslld,
                    .psllq => .psllq,
                    .psrlw => .psrlw,
                    .psrld => .psrld,
                    .psrlq => .psrlq,
                    .psraw => .psraw,
                    .psrad => .psrad,
                    .psrldq, .pslldq => unreachable,
                }, r, .{ .reg = x }),
            }
        }
    };
    // Unsigned bytes: the mask of the bits that stay in each byte, in xmm3.
    if (s.lane == .i8 and (left or !signed)) switch (n) {
        .imm => |k| {
            const b: u8 = if (left) @truncate(@as(u16, 0xff) << @intCast(k)) else @as(u8, 0xff) >> @intCast(k);
            try e.movdq(true, .{ .reg = .xmm3 }, .{ .mem = try constMem(cg, @splat(b)) });
        },
        .xmm => {
            // 0x00ff in each word, shifted as the lanes are; its low byte
            // is the mask, which packuswb copies to every byte.
            try e.pint(.pcmpeqd, .xmm3, .{ .reg = .xmm3 });
            try e.pshift(.psrlw, .xmm3, 8);
            try Op.by(e, if (left) .psllw else .psrlw, .xmm3, n);
            if (left) {
                try e.pshift(.psllw, .xmm3, 8);
                try e.pshift(.psrlw, .xmm3, 8);
            }
            try e.pint(.packuswb, .xmm3, .{ .reg = .xmm3 });
        },
    };
    const dst = try Dst.of(cg, inst, ty);
    for (0..s.chunks()) |kk| {
        const k: u32 = @intCast(kk);
        const r = dst.home orelse .xmm0;
        try loadChunk(cg, r, lhs, k);
        switch (s.lane) {
            .i8 => if (left or !signed) {
                try Op.by(e, if (left) .psllw else .psrlw, r, n);
                try e.pint(.pand, r, .{ .reg = .xmm3 });
            } else {
                // Each byte as the high byte of a word, whose low byte the
                // shift by 8 + n drops.
                try e.movdq(true, .{ .reg = .xmm1 }, .{ .reg = r });
                try e.pint(.punpcklbw, .xmm1, .{ .reg = r });
                try e.movdq(true, .{ .reg = .xmm2 }, .{ .reg = r });
                try e.pint(.punpckhbw, .xmm2, .{ .reg = r });
                try Op.by(e, .psraw, .xmm1, n2);
                try Op.by(e, .psraw, .xmm2, n2);
                try e.pint(.packsswb, .xmm1, .{ .reg = .xmm2 });
                try e.movdq(true, .{ .reg = r }, .{ .reg = .xmm1 });
            },
            .i16 => try Op.by(e, if (left) .psllw else if (signed) .psraw else .psrlw, r, n),
            .i32 => try Op.by(e, if (left) .pslld else if (signed) .psrad else .psrld, r, n),
            .i64 => if (left or !signed) {
                try Op.by(e, if (left) .psllq else .psrlq, r, n);
            } else {
                // The sign of each lane in all its bits: its high dword's,
                // copied to both dwords and shifted arithmetically.
                try e.pshuf(.d, .xmm1, .{ .reg = r }, 0xf5);
                try e.pshift(.psrad, .xmm1, 31);
                try Op.by(e, .psrlq, r, n);
                try Op.by(e, .psllq, .xmm1, n2);
                try e.pint(.por, r, .{ .reg = .xmm1 });
            },
            else => unreachable,
        }
        try dst.put(cg, r, k);
    }
}

fn arith(cg: *CodeGen, inst: Inst.Index, tag: Inst.Tag, ty: Index, lhs: Ref, rhs: Ref) Error!void {
    const s = shape(cg.ip, ty).?;
    const signed = isSigned(cg, ty);
    const dst = try Dst.of(cg, inst, ty);
    const e = &cg.e;
    for (0..s.chunks()) |kk| {
        const k: u32 = @intCast(kk);
        const r = destFor(cg, dst, lhs, rhs);
        try loadChunk(cg, r, lhs, k);
        switch (tag) {
            .add_float, .sub_float, .mul_float, .div_float => try e.ps(switch (tag) {
                .add_float => .add,
                .sub_float => .sub,
                .mul_float => .mul,
                .div_float => .div,
                else => unreachable,
            }, s.float(), r, try srcChunk(cg, rhs, k, .xmm1)),
            .mul_wrap => switch (s.lane) {
                .i16 => try e.pint(.pmullw, r, try srcChunk(cg, rhs, k, .xmm1)),
                .i32 => if (has(cg, .sse4_1)) {
                    try e.pint38(.pmulld, r, try srcChunk(cg, rhs, k, .xmm1));
                } else {
                    try loadChunk(cg, .xmm1, rhs, k);
                    try mul32(cg, r, .xmm1);
                },
                else => unreachable,
            },
            .min_int, .max_int => {
                try loadChunk(cg, .xmm1, rhs, k);
                try minMax(cg, tag == .max_int, s.lane, signed, r, .xmm1);
            },
            else => try e.pint(switch (tag) {
                .bit_and => .pand,
                .bit_or => .por,
                .xor => .pxor,
                .add_wrap => switch (s.lane) {
                    .i8 => .paddb,
                    .i16 => .paddw,
                    .i32 => .paddd,
                    .i64 => .paddq,
                    else => unreachable,
                },
                .sub_wrap => switch (s.lane) {
                    .i8 => .psubb,
                    .i16 => .psubw,
                    .i32 => .psubd,
                    .i64 => .psubq,
                    else => unreachable,
                },
                else => unreachable,
            }, r, try srcChunk(cg, rhs, k, .xmm1)),
        }
        try dst.put(cg, r, k);
    }
}

/// Whether vector type `ty`'s lanes are signed integers.
fn isSigned(cg: *CodeGen, ty: Index) bool {
    const elem = Type.childType(cg.ip, ty);
    return Type.class(cg.ip, elem) == .int and Type.intInfo(cg.ip, elem).signedness == .signed;
}

/// `r *%= b` on 32-bit lanes: the even lanes' products, then the odd
/// lanes' (moved to even positions), interleaved again; pmulld with
/// SSE4.1. Uses xmm2 and xmm3.
fn mul32(cg: *CodeGen, r: Xmm, b: Xmm) Error!void {
    const e = &cg.e;
    if (has(cg, .sse4_1)) return e.pint38(.pmulld, r, .{ .reg = b });
    try e.pshuf(.d, .xmm2, .{ .reg = r }, 0xf5);
    try e.pshuf(.d, .xmm3, .{ .reg = b }, 0xf5);
    try e.pint(.pmuludq, r, .{ .reg = b });
    try e.pint(.pmuludq, .xmm2, .{ .reg = .xmm3 });
    try e.pshuf(.d, r, .{ .reg = r }, 0x08);
    try e.pshuf(.d, .xmm2, .{ .reg = .xmm2 }, 0x08);
    try e.pint(.punpckldq, r, .{ .reg = .xmm2 });
}

/// `r = @min(r, b)` (or `@max`) on integer lanes: SSE2 has unsigned
/// byte and signed word forms, which the other byte and word signedness
/// reach with the sign bits flipped; 32-bit lanes compare and blend.
/// SSE4.1 has every 8-, 16-, and 32-bit form; 64-bit lanes compare
/// (SSE4.2) and blend. Clobbers `b`, xmm2-xmm4, and rcx.
fn minMax(cg: *CodeGen, max: bool, lane: Lane, signed: bool, r: Xmm, b: Xmm) Error!void {
    const e = &cg.e;
    const sse41 = has(cg, .sse4_1);
    switch (lane) {
        .i8, .i16 => {
            const flip = signed != (lane == .i16);
            if (flip and sse41) return e.pint38(switch (lane) {
                .i8 => if (max) .pmaxsb else .pminsb,
                else => if (max) .pmaxuw else .pminuw,
            }, r, .{ .reg = b });
            const sign: ?Mem = if (flip) try signMem(cg, lane) else null;
            if (sign) |m| {
                try e.pint(.pxor, r, .{ .mem = m });
                try e.pint(.pxor, b, .{ .mem = m });
            }
            try e.pint(switch (lane) {
                .i8 => if (max) .pmaxub else .pminub,
                else => if (max) .pmaxsw else .pminsw,
            }, r, .{ .reg = b });
            if (sign) |m| try e.pint(.pxor, r, .{ .mem = m });
        },
        .i32, .i64 => {
            if (lane == .i32 and sse41) return e.pint38(if (signed)
                (if (max) .pmaxsd else .pminsd)
            else
                (if (max) .pmaxud else .pminud), r, .{ .reg = b });
            // mask = r > b for min, b > r for max; then b where mask, else r.
            try e.movdq(true, .{ .reg = .xmm2 }, .{ .reg = if (max) b else r });
            try e.movdq(true, .{ .reg = .xmm3 }, .{ .reg = if (max) r else b });
            if (!signed) {
                const m = try signMem(cg, lane);
                try e.pint(.pxor, .xmm2, .{ .mem = m });
                try e.pint(.pxor, .xmm3, .{ .mem = m });
            }
            try pcmpgt(cg, lane, .xmm2, .{ .reg = .xmm3 });
            try e.pint(.pand, b, .{ .reg = .xmm2 });
            try e.pint(.pandn, .xmm2, .{ .reg = r });
            try e.movdq(true, .{ .reg = r }, .{ .reg = .xmm2 });
            try e.pint(.por, r, .{ .reg = b });
        },
        else => unreachable,
    }
}

/// `r = r > src` per signed integer lane; 64-bit lanes need SSE4.2.
fn pcmpgt(cg: *CodeGen, lane: Lane, r: Xmm, src: XmmRm) Error!void {
    if (lane == .i64) return cg.e.pint38(.pcmpgtq, r, src);
    try cg.e.pint(switch (lane) {
        .i8 => .pcmpgtb,
        .i16 => .pcmpgtw,
        else => .pcmpgtd,
    }, r, src);
}

/// Float `@min`/`@max` as the scalar lowering: `rhs` where `lhs` is NaN,
/// else minps/maxps with `rhs` first, which returns `lhs` on ties and
/// when `rhs` is NaN.
fn floatMinMax(cg: *CodeGen, inst: Inst.Index, max: bool, ty: Index, lhs: Ref, rhs: Ref) Error!void {
    const s = shape(cg.ip, ty).?;
    const e = &cg.e;
    const dst = try Dst.of(cg, inst, ty);
    for (0..s.chunks()) |kk| {
        const k: u32 = @intCast(kk);
        try loadChunk(cg, .xmm1, rhs, k);
        try loadChunk(cg, .xmm2, lhs, k);
        try e.movdq(true, .{ .reg = .xmm4 }, .{ .reg = .xmm1 });
        try e.ps(if (max) .max else .min, s.float(), .xmm4, .{ .reg = .xmm2 });
        try e.movdq(true, .{ .reg = .xmm5 }, .{ .reg = .xmm2 });
        try e.cmpp(s.float(), .xmm5, .{ .reg = .xmm5 }, 3);
        try e.pint(.pand, .xmm1, .{ .reg = .xmm5 });
        try e.pint(.pandn, .xmm5, .{ .reg = .xmm4 });
        try e.pint(.por, .xmm5, .{ .reg = .xmm1 });
        try dst.put(cg, .xmm5, k);
    }
}

/// Float `-x`, `@abs`, and `@sqrt`: the sign bits flipped or cleared, or
/// sqrtps/sqrtpd.
fn floatUnary(cg: *CodeGen, inst: Inst.Index, tag: Inst.Tag, operand: Ref) Error!void {
    const ty = cg.typeOf(operand);
    const s = shape(cg.ip, ty).?;
    const e = &cg.e;
    const dst = try Dst.of(cg, inst, ty);
    var mask: ?Mem = null;
    if (tag != .sqrt) {
        const sign: u64 = if (s.lane == .f64) 1 << 63 else 1 << 31;
        var bytes: [16]u8 = undefined;
        for (0..16 / s.lane.bytes()) |i| {
            const v = if (tag == .neg_float) sign else ~sign;
            for (0..s.lane.bytes()) |j| bytes[i * s.lane.bytes() + j] = @truncate(v >> @intCast(8 * j));
        }
        mask = try constMem(cg, bytes);
    }
    for (0..s.chunks()) |kk| {
        const k: u32 = @intCast(kk);
        const r = dst.home orelse .xmm0;
        switch (tag) {
            .sqrt => try e.ps(.sqrt, s.float(), r, try srcChunk(cg, operand, k, .xmm1)),
            else => {
                try loadChunk(cg, r, operand, k);
                try e.pint(if (tag == .neg_float) .pxor else .pand, r, .{ .mem = mask.? });
            },
        }
        try dst.put(cg, r, k);
    }
}

/// Element-wise compare to a bool vector's bits: per chunk, a lane mask
/// in xmm0, then its lanes' top bits in rcx, gathered in the result.
fn compare(cg: *CodeGen, inst: Inst.Index, ty: Index, op: std.math.CompareOperator, lhs: Ref, rhs: Ref) Error!void {
    const ip = cg.ip;
    const op_ty = cg.typeOf(lhs);
    const s = shape(ip, op_ty).?;
    const elem = Type.childType(ip, op_ty);
    const signed = !s.lane.isFloat() and Type.intInfo(ip, elem).signedness == .signed;
    const e = &cg.e;
    const d = cg.destReg(inst);
    // The compare computed and whether its mask is inverted: integers
    // compare equal or greater, floats with cmpps's predicates.
    const swap = !s.lane.isFloat() and (op == .lt or op == .gte);
    // A compare against a constant that splits the lanes at their sign
    // bit is the sign bits (`signTest`), which movmsk reads directly.
    const st = signTest(cg, op_ty, op, lhs, rhs);
    const invert = if (st) |x| x.invert else !s.lane.isFloat() and (op == .neq or op == .lte or op == .gte);
    const a, const b = if (st) |x| .{ x.operand, x.operand } else if (swap) .{ rhs, lhs } else .{ lhs, rhs };
    const n = s.perChunk();
    const biased = st == null and !s.lane.isFloat() and !signed and op != .eq and op != .neq;
    const sign: ?Mem = if (biased) try signMem(cg, s.lane) else null;
    // One chunk's lane bits go straight to the result's register.
    const t: Reg = if (s.chunks() == 1) d else .rcx;
    for (0..s.chunks()) |kk| {
        const k: u32 = @intCast(kk);
        // A sign test reads a register operand in place, but for 16-bit
        // lanes, which it packs first.
        const c = try chunk(cg, a, k);
        const x: Xmm = if (st != null and s.lane != .i16 and c == .reg) c.reg else .xmm0;
        if (x == .xmm0) try loadFrom(cg, .xmm0, c);
        if (s.lane.isFloat()) {
            const pred: u8 = switch (op) {
                .eq => 0,
                .lt, .gt => 1,
                .lte, .gte => 2,
                .neq => 4,
            };
            if (op == .gt or op == .gte) {
                // b < a, b <= a.
                try loadChunk(cg, .xmm1, b, k);
                try e.cmpp(s.float(), .xmm1, .{ .reg = .xmm0 }, pred);
                try e.movmskp(s.float(), t, .xmm1);
            } else {
                try e.cmpp(s.float(), .xmm0, try srcChunk(cg, b, k, .xmm1), pred);
                try e.movmskp(s.float(), t, .xmm0);
            }
        } else {
            // A sign test reads the lanes' sign bits as they are.
            if (st != null) {} else if ((op == .eq or op == .neq) and s.lane == .i64 and has(cg, .sse4_1)) {
                try e.pint38(.pcmpeqq, .xmm0, try srcChunk(cg, b, k, .xmm1));
            } else if (op == .eq or op == .neq) {
                try e.pint(switch (s.lane) {
                    .i8 => .pcmpeqb,
                    .i16 => .pcmpeqw,
                    else => .pcmpeqd,
                }, .xmm0, try srcChunk(cg, b, k, .xmm1));
                if (s.lane == .i64) {
                    // Both halves equal.
                    try e.pshuf(.d, .xmm1, .{ .reg = .xmm0 }, 0xb1);
                    try e.pint(.pand, .xmm0, .{ .reg = .xmm1 });
                }
            } else {
                // a > b (after the swap), unsigned as signed after flipping
                // the sign bits.
                if (signed) {
                    try pcmpgt(cg, s.lane, .xmm0, try srcChunk(cg, b, k, .xmm1));
                } else {
                    try loadChunk(cg, .xmm1, b, k);
                    try e.pint(.pxor, .xmm0, .{ .mem = sign.? });
                    try e.pint(.pxor, .xmm1, .{ .mem = sign.? });
                    try pcmpgt(cg, s.lane, .xmm0, .{ .reg = .xmm1 });
                }
            }
            switch (s.lane) {
                .i8 => try e.pmovmskb(t, x),
                .i16 => {
                    try e.pint(.packsswb, .xmm0, .{ .reg = .xmm0 });
                    try e.pmovmskb(t, .xmm0);
                    try e.movzx(.dword, t, .byte, .{ .reg = t });
                },
                .i32 => try e.movmskp(.f32, t, x),
                .i64 => try e.movmskp(.f64, t, x),
                else => unreachable,
            }
        }
        if (k == 0) {
            if (t != d) try e.mov(.dword, .{ .reg = d }, .{ .reg = .rcx });
        } else {
            try e.shift(.shl, .qword, .{ .reg = .rcx }, @intCast(k * n));
            try e.alu(.@"or", .qword, .{ .reg = d }, .{ .reg = .rcx });
        }
    }
    // Lanes past the length are padding.
    const mask = lenMask(s.len);
    if (s.chunks() * n > s.len) try andImm(cg, d, mask);
    if (invert) try xorImm(cg, d, mask);
    try cg.setResult(inst, ty, d);
}

/// For `compare`: integer `lhs op rhs` with one side a constant splat
/// that makes it a test of the other side's sign bits: unsigned `x >=
/// 2^(n-1)` and `x > 2^(n-1) - 1`, signed `x < 0` and `x <= -1`, or
/// (`invert`) their negations. Not for narrow lanes, whose sign bit is
/// not the lane's.
fn signTest(cg: *CodeGen, ty: Index, op: std.math.CompareOperator, lhs: Ref, rhs: Ref) ?struct { operand: Ref, invert: bool } {
    const ip = cg.ip;
    const s = shape(ip, ty).?;
    if (s.lane.isFloat() or shared.narrow(ip, ty)) return null;
    // `x op c`, with `c op x` turned around.
    const x: Ref, const c: Index, const o: std.math.CompareOperator = if (rhs.toInterned()) |v|
        .{ lhs, v, op }
    else if (lhs.toInterned()) |v|
        .{ rhs, v, op.reverse() }
    else
        return null;
    if (x.toInterned() != null) return null;
    const bits = s.lane.bytes() * 8;
    const k = (splatBits(cg, c) orelse return null) & lenMask(bits);
    const half = @as(u64, 1) << @intCast(bits - 1);
    const signed = Type.intInfo(ip, Type.childType(ip, ty)).signedness == .signed;
    // The value whose `x >= k` (and so `x > k - 1`) is the sign bit.
    const at = if (signed) 0 else half;
    const below = (at -% 1) & lenMask(bits);
    // Signed lanes are set below 0, so the sign is `x < 0`.
    const set_ops: [2]std.math.CompareOperator = if (signed) .{ .lt, .lte } else .{ .gte, .gt };
    const ks: [2]u64 = .{ at, below };
    for (set_ops, ks) |so, kv| if (k == kv) {
        if (o == so) return .{ .operand = x, .invert = false };
        if (o == negated(so)) return .{ .operand = x, .invert = true };
    };
    return null;
}

fn negated(op: std.math.CompareOperator) std.math.CompareOperator {
    return switch (op) {
        .lt => .gte,
        .lte => .gt,
        .gt => .lte,
        .gte => .lt,
        .eq => .neq,
        .neq => .eq,
    };
}

/// `@reduce` of bool vector `operand`'s bits.
fn reduceBits(cg: *CodeGen, inst: Inst.Index, op: Ir.ReduceOp, operand: Ref) Error!void {
    if (cg.homes[@backingInt(inst)] == .fused) return; // read by its branch
    const cc = try bitsFlags(cg, op, operand);
    const d = cg.destReg(inst);
    try cg.e.setcc(cc, .{ .reg = d });
    try cg.e.movzx(.dword, d, .byte, .{ .reg = d });
    try cg.setResult(inst, .bool_type, d);
}

/// For `CodeGen.fusable`: whether `inst` is an `@reduce(.Or)` or
/// `@reduce(.And)` of a bool vector's bits, which a branch reads from the
/// flags (`condFlags`).
pub fn fusable(cg: *CodeGen, inst: Inst.Index) bool {
    const data = cg.ir.instructions.items(.data)[@backingInt(inst)];
    const x = cg.ir.extraData(Ir.Reduce, data.ty_pl.payload).data;
    return isBits(cg.ip, cg.typeOf(x.operand)) and (x.operation() == .@"or" or x.operation() == .@"and");
}

/// For `CodeGen.condFlags`: sets the flags for fused reduce `inst`
/// (`fusable`) and returns the condition that is its result.
pub fn condFlags(cg: *CodeGen, inst: Inst.Index) Error!Encoder.Cond {
    const data = cg.ir.instructions.items(.data)[@backingInt(inst)];
    const x = cg.ir.extraData(Ir.Reduce, data.ty_pl.payload).data;
    return bitsFlags(cg, x.operation(), x.operand);
}

/// Whether the bits of a bool vector of `len` lanes above the length are
/// known 0: they are in a register, and a load of a vector whose bits fill
/// its bytes zero-extends them, but other lengths may read padding from
/// memory.
fn exactBits(len: u32) bool {
    return len == 8 or len == 16 or len == 32 or len == 64;
}

/// Sets the flags for `@reduce(op)` of bool vector `operand`'s bits and
/// returns the condition that is its result. Uses rax, rcx and r11.
fn bitsFlags(cg: *CodeGen, op: Ir.ReduceOp, operand: Ref) Error!Encoder.Cond {
    const e = &cg.e;
    const len = cg.ip.keyPayload(.vector_type, cg.typeOf(operand)).len;
    const mask = lenMask(len);
    const exact = exactBits(len);
    const size: Encoder.Size = if (len > 32) .qword else .dword;
    // Bits already in a register are tested in place.
    if (exact) if (operand.toIndex()) |o| if (cg.homes[@backingInt(o)] == .reg) {
        const r = cg.homes[@backingInt(o)].reg;
        switch (op) {
            .@"or" => {
                try e.@"test"(size, .{ .reg = r }, .{ .reg = r });
                return .ne;
            },
            .@"and" => {
                const imm: i32 = if (len >= 32) -1 else @intCast(mask);
                try e.alu(.cmp, size, .{ .reg = r }, .{ .imm = imm });
                return .e;
            },
            else => {},
        }
    };
    try cg.load(.rax, operand);
    if (!exact) try andImm(cg, .rax, mask);
    switch (op) {
        .@"or" => {
            try e.@"test"(size, .{ .reg = .rax }, .{ .reg = .rax });
            return .ne;
        },
        .@"and" => {
            try xorImm(cg, .rax, mask);
            return .e;
        },
        .xor => {
            // The parity of the bits, folded into the low byte.
            for ([_]u8{ 32, 16, 8 }) |sh| {
                try e.mov(.qword, .{ .reg = .rcx }, .{ .reg = .rax });
                try e.shift(.shr, .qword, .{ .reg = .rcx }, sh);
                try e.alu(.xor, .qword, .{ .reg = .rax }, .{ .reg = .rcx });
            }
            try e.@"test"(.byte, .{ .reg = .rax }, .{ .reg = .rax });
            return .np;
        },
        else => unreachable,
    }
}

/// `@reduce` of integer lanes: the chunks combined, the lanes past the
/// length set to `op`'s identity, then halves combined down to one lane.
fn reduce(cg: *CodeGen, inst: Inst.Index, ty: Index, op: Ir.ReduceOp, operand: Ref) Error!void {
    const ip = cg.ip;
    const s = shape(ip, cg.typeOf(operand)).?;
    const signed = Type.intInfo(ip, ty).signedness == .signed;
    const e = &cg.e;
    const chunks = s.chunks();
    const tail = s.bytes() % 16;
    // Lanes past the length are read only if a full chunk follows or the
    // last one's lanes are not a power of two in bytes.
    const pad = tail != 0 and (chunks > 1 or !std.math.isPowerOfTwo(tail));
    // Min and max of the signedness the CPU lacks (`minMax`) run on
    // lanes with their sign bits flipped (in xmm5), once for the whole
    // tree.
    const sse41 = has(cg, .sse4_1);
    const flip = (op == .min or op == .max) and switch (s.lane) {
        .i8 => signed and !sse41,
        .i16, .i32 => !signed and !sse41,
        .i64 => !signed,
        else => false,
    };
    const lanes_signed = if (flip) !signed else signed;
    const sign: ?Mem = if (flip) try signMem(cg, s.lane) else null;
    for (0..chunks) |kk| {
        const k: u32 = @intCast(kk);
        const r: Xmm = if (k == 0) .xmm0 else .xmm1;
        try loadChunk(cg, r, operand, k);
        if (pad and k == chunks - 1) {
            // r & keep | fill: the identity in the lanes past the length.
            const lb = s.lane.bytes();
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
            if (identity != lenMask(bits)) try e.pint(.pand, r, .{ .mem = try constMem(cg, keep) });
            if (identity != 0) try e.pint(.por, r, .{ .mem = try constMem(cg, fill) });
        }
        if (sign) |m| try e.pint(.pxor, r, .{ .mem = m });
        if (k != 0) try combine(cg, op, s.lane, lanes_signed, .xmm0, .xmm1);
    }
    var width: u32 = if (chunks > 1) 16 else std.math.ceilPowerOfTwoAssert(u32, s.bytes());
    while (width > s.lane.bytes()) {
        width /= 2;
        try e.movdq(true, .{ .reg = .xmm1 }, .{ .reg = .xmm0 });
        try e.pshift(.psrldq, .xmm1, @intCast(width));
        try combine(cg, op, s.lane, lanes_signed, .xmm0, .xmm1);
    }
    if (sign) |m| try e.pint(.pxor, .xmm0, .{ .mem = m });
    const d = cg.destReg(inst);
    switch (s.lane) {
        .i64 => try e.movFromXmm(.qword, .{ .reg = d }, .xmm0),
        .i32 => {
            try e.movFromXmm(.dword, .{ .reg = d }, .xmm0);
            if (signed) try e.movsx(.qword, d, .dword, .{ .reg = d });
        },
        else => {
            try e.movFromXmm(.dword, .{ .reg = d }, .xmm0);
            const size: Encoder.Size = if (s.lane == .i8) .byte else .word;
            if (signed) try e.movsx(.qword, d, size, .{ .reg = d }) else try e.movzx(.dword, d, size, .{ .reg = d });
        },
    }
    try cg.setResult(inst, ty, d);
}

/// `r = op(r, b)` on integer lanes, for `reduce`. Clobbers `b`.
fn combine(cg: *CodeGen, op: Ir.ReduceOp, lane: Lane, signed: bool, r: Xmm, b: Xmm) Error!void {
    const e = &cg.e;
    switch (op) {
        .min, .max => return minMax(cg, op == .max, lane, signed, r, b),
        .mul => return if (lane == .i32) mul32(cg, r, b) else e.pint(.pmullw, r, .{ .reg = b }),
        else => {},
    }
    try e.pint(switch (op) {
        .@"and" => .pand,
        .@"or" => .por,
        .xor => .pxor,
        .add => switch (lane) {
            .i8 => .paddb,
            .i16 => .paddw,
            .i32 => .paddd,
            .i64 => .paddq,
            else => unreachable,
        },
        else => unreachable,
    }, r, .{ .reg = b });
}

fn bitConst(lane_bytes: u32) *const fn (u32) u64 {
    return switch (lane_bytes) {
        // Bit i % 8 for lanes of bytes, which take 8 bits of the mask per
        // half; bit i for wider lanes.
        1 => struct {
            fn f(i: u32) u64 {
                return @as(u64, 1) << @intCast(i % 8);
            }
        }.f,
        8 => struct {
            // Two dwords per lane, both compared with pcmpeqd.
            fn f(i: u32) u64 {
                return (@as(u64, 1) << @intCast(i)) * 0x1_0000_0001;
            }
        }.f,
        else => struct {
            fn f(i: u32) u64 {
                return @as(u64, 1) << @intCast(i);
            }
        }.f,
    };
}

/// `@select`: per chunk, the predicate's bits for its lanes spread into a
/// lane mask, then `a & mask | b & ~mask`.
fn select(cg: *CodeGen, inst: Inst.Index, ty: Index, pred: Ref, a: Ref, b: Ref) Error!void {
    const s = shape(cg.ip, ty).?;
    const e = &cg.e;
    const dst = try Dst.of(cg, inst, ty);
    // Both arms the same value: it is the result. (The masking below
    // writes r before reading b, and r can be their shared home.)
    if (a == b) {
        for (0..s.chunks()) |k| {
            const r = dst.home orelse .xmm0;
            try loadChunk(cg, r, a, @intCast(k));
            try dst.put(cg, r, @intCast(k));
        }
        return;
    }
    const bits = try laneConst(cg, s.lane.bytes(), bitConst(s.lane.bytes()));
    try cg.load(.rdx, pred);
    const n = s.perChunk();
    for (0..s.chunks()) |kk| {
        const k: u32 = @intCast(kk);
        try e.mov(.qword, .{ .reg = .rax }, .{ .reg = .rdx });
        if (k != 0) try e.shift(.shr, .qword, .{ .reg = .rax }, @intCast(k * n));
        try e.movToXmm(.dword, .xmm2, .{ .reg = .rax });
        switch (s.lane.bytes()) {
            1 => {
                // Byte 0 of the bits to the low eight lanes, byte 1 to
                // the high eight.
                try e.pint(.punpcklbw, .xmm2, .{ .reg = .xmm2 });
                try e.pshuf(.lw, .xmm2, .{ .reg = .xmm2 }, 0x50);
                try e.pshuf(.d, .xmm2, .{ .reg = .xmm2 }, 0x50);
            },
            2 => {
                try e.pshuf(.lw, .xmm2, .{ .reg = .xmm2 }, 0);
                try e.pshuf(.d, .xmm2, .{ .reg = .xmm2 }, 0);
            },
            else => try e.pshuf(.d, .xmm2, .{ .reg = .xmm2 }, 0),
        }
        try e.pint(.pand, .xmm2, .{ .mem = bits });
        try e.pint(switch (s.lane.bytes()) {
            1 => .pcmpeqb,
            2 => .pcmpeqw,
            else => .pcmpeqd,
        }, .xmm2, .{ .mem = bits });
        const r = destFor(cg, dst, a, b);
        try loadChunk(cg, r, a, k);
        try e.pint(.pand, r, .{ .reg = .xmm2 });
        try e.pint(.pandn, .xmm2, try srcChunk(cg, b, k, .xmm1));
        try e.pint(.por, r, .{ .reg = .xmm2 });
        try dst.put(cg, r, k);
    }
}

/// `@shuffle`: pshufd when one operand's dwords (or qwords) are permuted
/// within one register, pshufb on each operand with SSSE3, else lane by
/// lane through memory.
fn shuffle(cg: *CodeGen, inst: Inst.Index, ty: Index, a: Ref, b: Ref, mask: Index) Error!void {
    const ip = cg.ip;
    const s = shape(ip, ty).?;
    const e = &cg.e;
    const lb = s.lane.bytes();
    var sel: [shared.max_bytes]i32 = undefined;
    var undef: [shared.max_bytes]bool = undefined;
    var from_a = true;
    var from_b = true;
    for (0..s.len) |i| {
        const m = elemValue(ip, mask, i);
        undef[i] = ip.keyTag(m) == .undef;
        if (undef[i]) continue;
        sel[i] = ip.intValue(i32, m).?;
        // With a and b the same value, every lane is one of a's: the
        // paths below then never read b after writing a's home.
        if (sel[i] >= 0 or a == b) from_b = false else from_a = false;
    }
    const src_ty = cg.typeOf(if (from_b and !from_a) b else a);
    const src_s = shape(ip, src_ty).?;
    if ((from_a or from_b) and s.bytes() <= 16 and src_s.bytes() <= 16 and lb >= 4) {
        const src = if (from_a) a else b;
        const per = lb / 4;
        var imm: u8 = 0;
        for (0..4) |q| {
            const i = q / per;
            const lane: u32 = if (i >= s.len or undef[i]) @intCast(i) else @intCast(if (sel[i] >= 0) sel[i] else ~sel[i]);
            const dword: u32 = lane * per + @as(u32, @intCast(q % per));
            imm |= @as(u8, @intCast(dword & 3)) << @intCast(2 * q);
        }
        const dst = try Dst.of(cg, inst, ty);
        const r = dst.home orelse .xmm0;
        try e.pshuf(.d, r, try srcChunk(cg, src, 0, .xmm1), imm);
        return dst.put(cg, r, 0);
    }
    if (has(cg, .ssse3) and s.bytes() <= 16 and shape(ip, cg.typeOf(a)).?.bytes() <= 16 and shape(ip, cg.typeOf(b)).?.bytes() <= 16) {
        // Each operand's bytes to their result positions, the others
        // zeroed (0x80), then the two or'ed.
        var masks: [2][16]u8 = .{ @splat(0x80), @splat(0x80) };
        var used: [2]bool = .{ false, false };
        for (0..s.len) |i| {
            if (undef[i]) continue;
            const which: usize = if (sel[i] >= 0 or a == b) 0 else 1;
            const lane: u32 = @intCast(if (sel[i] >= 0) sel[i] else ~sel[i]);
            used[which] = true;
            for (0..lb) |q| masks[which][i * lb + q] = @intCast(lane * lb + q);
        }
        const dst = try Dst.of(cg, inst, ty);
        const r = destFor(cg, dst, a, b);
        var first = true;
        for ([2]Ref{ a, b }, masks, used) |src, m, u| {
            if (!u) continue;
            const t: Xmm = if (first) r else .xmm1;
            try loadChunk(cg, t, src, 0);
            try e.pint38(.pshufb, t, .{ .mem = try constMem(cg, m) });
            if (!first) try e.pint(.por, r, .{ .reg = .xmm1 });
            first = false;
        }
        return dst.put(cg, r, 0);
    }
    // Lane by lane: both operands in memory, the result built in its own.
    const am = try cg.memOf(a);
    const bm = try cg.memOf(b);
    const home = cg.xmmOf(inst.toRef());
    const dm = if (home != null) Mem.at(.rbp, try cg.allocSlot(16, 16)) else (try cg.resultMem(inst, ty)).?;
    const size = CodeGen.sizeOf(lb);
    for (0..s.len) |i| {
        if (undef[i]) continue;
        const m = if (sel[i] >= 0) CodeGen.offsetMem(am, @as(u32, @intCast(sel[i])) * lb) else CodeGen.offsetMem(bm, @as(u32, @intCast(~sel[i])) * lb);
        try e.mov(size, .{ .reg = .rax }, .{ .mem = m });
        try e.mov(size, .{ .mem = CodeGen.offsetMem(dm, @as(u32, @intCast(i)) * lb) }, .{ .reg = .rax });
    }
    if (home) |h| try e.movdq(true, .{ .reg = h }, .{ .mem = dm });
}

/// Element `i` of comptime vector `val`.
fn elemValue(ip: *const InternPool, val: Index, i: usize) Index {
    const a = ip.keyPayload(.aggregate, val);
    return switch (a.storage) {
        .elems => |elems| elems[i],
        .repeated_elem => |el| el,
        .bytes => unreachable, // an i32 vector
    };
}

/// `aggregate_init` of vector type `ty` whose elements are all `elem`
/// (`isSplat`): the element broadcast to every lane.
fn splat(cg: *CodeGen, inst: Inst.Index, ty: Index, elem: Ref) Error!void {
    const s = shape(cg.ip, ty).?;
    const e = &cg.e;
    const dst = try Dst.of(cg, inst, ty);
    const r = dst.home orelse .xmm0;
    // A constant (once the rewrite rules fold one): its 16 bytes.
    if (elem.toInterned()) |v| if (!shared.narrow(cg.ip, ty)) if (constBits(cg, v)) |bits| {
        const lb = s.lane.bytes();
        var b: [16]u8 = undefined;
        for (0..16) |i| b[i] = @truncate(bits >> @intCast(8 * (i % lb)));
        try cg.e.movdq(true, .{ .reg = r }, .{ .mem = try constMem(cg, b) });
        for (0..s.chunks()) |k| try dst.put(cg, r, @intCast(k));
        return;
    };
    if (s.lane.isFloat()) {
        try cg.loadXmm(r, try cg.valOf(elem));
    } else {
        try cg.load(.rax, elem);
        if (shared.narrow(cg.ip, ty)) try cg.normalize(.rax, cg.typeOf(elem));
        try e.movToXmm(if (s.lane == .i64) .qword else .dword, r, .{ .reg = .rax });
    }
    switch (s.lane) {
        .i8 => {
            try e.pint(.punpcklbw, r, .{ .reg = r });
            try e.pshuf(.lw, r, .{ .reg = r }, 0);
            try e.pshuf(.d, r, .{ .reg = r }, 0);
        },
        .i16 => {
            try e.pshuf(.lw, r, .{ .reg = r }, 0);
            try e.pshuf(.d, r, .{ .reg = r }, 0);
        },
        .i32, .f32 => try e.pshuf(.d, r, .{ .reg = r }, 0),
        .i64, .f64 => try e.pshuf(.d, r, .{ .reg = r }, 0x44),
        .bool => unreachable,
    }
    for (0..s.chunks()) |k| try dst.put(cg, r, @intCast(k));
}
