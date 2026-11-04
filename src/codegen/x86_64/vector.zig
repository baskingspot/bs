//! x86_64 lowering of the vector operations that `../vector.zig` accepts:
//! SSE2 on XMM registers, 16 bytes of lanes at a time (docs/architecture.md,
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
pub fn inXmm(ip: *const InternPool, ty: Index) bool {
    const s = shape(ip, ty) orelse return false;
    return s.bytes() <= 16;
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
        .add_wrap, .sub_wrap, .mul_wrap, .bit_and, .bit_or, .xor, .add_float, .sub_float, .mul_float, .div_float => ip.keyTag(cg.typeOf(data.bin_op.lhs)) == .vector_type,
        .not => ip.keyTag(data.ty_op.ty) == .vector_type,
        // Between vectors of 9 to 16 bytes, from register to register.
        // (Smaller ones move through a GPR as integers do.)
        .bitcast => blk: {
            const ty = data.ty_op.ty;
            const src_ty = cg.typeOf(data.ty_op.operand);
            break :blk inXmm(ip, ty) and inXmm(ip, src_ty) and Type.abiSize(ip, ty) == 16 and Type.abiSize(ip, src_ty) == 16;
        },
        .aggregate_init => isSplat(cg, data),
        else => false,
    };
}

/// Whether `aggregate_init` `data` broadcasts one runtime element to a
/// vector of lanes (`splat`).
fn isSplat(cg: *CodeGen, data: Inst.Data) bool {
    if (shape(cg.ip, data.ty_pl.ty) == null) return false;
    const extra = cg.ir.extraData(Ir.Aggregate, data.ty_pl.payload);
    const elems = cg.ir.refSlice(extra.end, extra.data.len);
    if (elems[0].toInterned() != null) return false;
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
    if (!readsChunks(cg, inst)) return;
    const T = struct {
        cg: *CodeGen,
        before: []const Inst.Index,
        at: u32,
        pub fn use(t: @This(), ref: Ref) void {
            const c = t.cg;
            const ip = c.ip;
            const i = ref.toIndex() orelse return;
            if (shape(ip, c.typeOf(ref)) == null) return;
            const ii = @backingInt(i);
            const live = c.ssa.live.slice();
            if (live.items(.uses)[ii] != 1 or c.homes[ii] != .none) return;
            const tags = c.ir.instructions.items(.tag);
            const data = c.ir.instructions.items(.data)[ii];
            switch (tags[ii]) {
                .load => {
                    c.deferLoad(ref, t.before, t.at);
                    // No register either.
                    if (c.homes[ii] == .deferred) live.items(.reg)[ii] = Ssa.no_reg;
                },
                .bitcast => {
                    const l = data.ty_op.operand.toIndex() orelse return;
                    if (tags[@backingInt(l)] != .load or live.items(.fate)[ii] != .normal) return;
                    if (Type.abiSize(ip, c.typeOf(data.ty_op.operand)) < Type.abiSize(ip, data.ty_op.ty)) return;
                    c.deferLoad(data.ty_op.operand, t.before, t.at);
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
    Ssa.forEachOperand(cg.ir, inst, T{ .cg = cg, .before = before, .at = pos });
}

pub fn gen(cg: *CodeGen, inst: Inst.Index, tag: Inst.Tag, data: Inst.Data) Error!void {
    const ip = cg.ip;
    switch (tag) {
        .cmp_vector => {
            const x = cg.ir.extraData(Ir.VectorCmp, data.ty_pl.payload).data;
            try compare(cg, inst, data.ty_pl.ty, x.operator(), x.lhs, x.rhs);
        },
        .reduce => {
            const x = cg.ir.extraData(Ir.Reduce, data.ty_pl.payload).data;
            if (isBits(ip, cg.typeOf(x.operand))) return reduceBits(cg, inst, x.operation(), x.operand);
            try reduce(cg, inst, data.ty_pl.ty, x.operation(), x.operand);
        },
        .select => {
            const x = cg.ir.extraData(Ir.Select, data.ty_pl.payload).data;
            try select(cg, inst, data.ty_pl.ty, x.pred, x.a, x.b);
        },
        .shuffle => {
            const x = cg.ir.extraData(Ir.Shuffle, data.ty_pl.payload).data;
            try shuffle(cg, inst, data.ty_pl.ty, x.a, x.b, x.mask);
        },
        .aggregate_init => {
            const extra = cg.ir.extraData(Ir.Aggregate, data.ty_pl.payload);
            try splat(cg, inst, data.ty_pl.ty, cg.ir.refSlice(extra.end, extra.data.len)[0]);
        },
        .bitcast => {
            const dst = try Dst.of(cg, inst, data.ty_op.ty);
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
                // Bitwise operations on bool vectors' bits.
                const d = cg.destReg(inst);
                try cg.load(.rax, data.bin_op.lhs);
                try cg.load(.rcx, data.bin_op.rhs);
                try cg.e.alu(switch (tag) {
                    .bit_and => .@"and",
                    .bit_or => .@"or",
                    .xor => .xor,
                    else => unreachable,
                }, .qword, .{ .reg = .rax }, .{ .reg = .rcx });
                if (d != .rax) try cg.e.mov(.qword, .{ .reg = d }, .{ .reg = .rax });
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

fn chunk(cg: *CodeGen, ref: Ref, k: u32) Error!Chunk {
    const ip = cg.ip;
    if (ref.toInterned()) |v| {
        const ty = ip.typeOf(v);
        if (splatBits(cg, v)) |bits| {
            const lb = shape(ip, ty).?.lane.bytes();
            if (bits == 0) return .zero;
            if (bits == lenMask(lb * 8)) return .ones;
        }
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
    try cg.e.mov(.qword, .{ .reg = .r11 }, .{ .imm = @bitCast(mask) });
    try cg.e.alu(.xor, .qword, .{ .reg = reg }, .{ .reg = .r11 });
}

/// `reg &= mask`. Uses r11.
fn andImm(cg: *CodeGen, reg: Reg, mask: u64) Error!void {
    if (mask == std.math.maxInt(u64)) return;
    if (mask == std.math.maxInt(u32)) return cg.e.mov(.dword, .{ .reg = reg }, .{ .reg = reg });
    if (std.math.cast(i32, @as(i64, @bitCast(mask)))) |imm| return cg.e.alu(.@"and", .qword, .{ .reg = reg }, .{ .imm = imm });
    try cg.e.mov(.qword, .{ .reg = .r11 }, .{ .imm = @bitCast(mask) });
    try cg.e.alu(.@"and", .qword, .{ .reg = reg }, .{ .reg = .r11 });
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

/// Each lane's sign bit set, in `r`, for unsigned compares as signed ones.
fn signBits(cg: *CodeGen, r: Xmm, lane: Lane) Error!void {
    const pattern: u32 = switch (lane) {
        .i8 => 0x8080_8080,
        .i16 => 0x8000_8000,
        .i32 => 0x8000_0000,
        else => unreachable,
    };
    try cg.e.mov(.dword, .{ .reg = .rcx }, .{ .imm = pattern });
    try cg.e.movToXmm(.dword, r, .{ .reg = .rcx });
    try cg.e.pshuf(.d, r, .{ .reg = r }, 0);
}

// ---------------------------------------------------------------------------
// Operations

fn arith(cg: *CodeGen, inst: Inst.Index, tag: Inst.Tag, ty: Index, lhs: Ref, rhs: Ref) Error!void {
    const s = shape(cg.ip, ty).?;
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
                .i32 => {
                    // The even lanes' products, then the odd lanes'
                    // (moved to even positions), interleaved again.
                    try loadChunk(cg, .xmm1, rhs, k);
                    try e.pshuf(.d, .xmm2, .{ .reg = r }, 0xf5);
                    try e.pshuf(.d, .xmm3, .{ .reg = .xmm1 }, 0xf5);
                    try e.pint(.pmuludq, r, .{ .reg = .xmm1 });
                    try e.pint(.pmuludq, .xmm2, .{ .reg = .xmm3 });
                    try e.pshuf(.d, r, .{ .reg = r }, 0x08);
                    try e.pshuf(.d, .xmm2, .{ .reg = .xmm2 }, 0x08);
                    try e.pint(.punpckldq, r, .{ .reg = .xmm2 });
                },
                else => unreachable,
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
    const invert = !s.lane.isFloat() and (op == .neq or op == .lte or op == .gte);
    const a, const b = if (swap) .{ rhs, lhs } else .{ lhs, rhs };
    const n = s.perChunk();
    const biased = !s.lane.isFloat() and !signed and op != .eq and op != .neq;
    if (biased) try signBits(cg, .xmm3, s.lane);
    for (0..s.chunks()) |kk| {
        const k: u32 = @intCast(kk);
        try loadChunk(cg, .xmm0, a, k);
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
                try e.movmskp(s.float(), .rcx, .xmm1);
            } else {
                try e.cmpp(s.float(), .xmm0, try srcChunk(cg, b, k, .xmm1), pred);
                try e.movmskp(s.float(), .rcx, .xmm0);
            }
        } else {
            if (op == .eq or op == .neq) {
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
                    try e.pint(switch (s.lane) {
                        .i8 => .pcmpgtb,
                        .i16 => .pcmpgtw,
                        else => .pcmpgtd,
                    }, .xmm0, try srcChunk(cg, b, k, .xmm1));
                } else {
                    try loadChunk(cg, .xmm1, b, k);
                    try e.pint(.pxor, .xmm0, .{ .reg = .xmm3 });
                    try e.pint(.pxor, .xmm1, .{ .reg = .xmm3 });
                    try e.pint(switch (s.lane) {
                        .i8 => .pcmpgtb,
                        .i16 => .pcmpgtw,
                        else => .pcmpgtd,
                    }, .xmm0, .{ .reg = .xmm1 });
                }
            }
            switch (s.lane) {
                .i8 => try e.pmovmskb(.rcx, .xmm0),
                .i16 => {
                    try e.pint(.packsswb, .xmm0, .{ .reg = .xmm0 });
                    try e.pmovmskb(.rcx, .xmm0);
                    try e.movzx(.dword, .rcx, .byte, .{ .reg = .rcx });
                },
                .i32 => try e.movmskp(.f32, .rcx, .xmm0),
                .i64 => try e.movmskp(.f64, .rcx, .xmm0),
                else => unreachable,
            }
        }
        if (k == 0) {
            try e.mov(.dword, .{ .reg = d }, .{ .reg = .rcx });
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

/// `@reduce` of bool vector `operand`'s bits.
fn reduceBits(cg: *CodeGen, inst: Inst.Index, op: Ir.ReduceOp, operand: Ref) Error!void {
    const e = &cg.e;
    const mask = lenMask(cg.ip.keyPayload(.vector_type, cg.typeOf(operand)).len);
    try cg.load(.rax, operand);
    try andImm(cg, .rax, mask);
    const cc: Encoder.Cond = switch (op) {
        .@"or" => .ne,
        .@"and" => blk: {
            try xorImm(cg, .rax, mask);
            break :blk .e;
        },
        .xor => blk: {
            // The parity of the bits, folded into the low byte.
            for ([_]u8{ 32, 16, 8 }) |sh| {
                try e.mov(.qword, .{ .reg = .rcx }, .{ .reg = .rax });
                try e.shift(.shr, .qword, .{ .reg = .rcx }, sh);
                try e.alu(.xor, .qword, .{ .reg = .rax }, .{ .reg = .rcx });
            }
            try e.@"test"(.byte, .{ .reg = .rax }, .{ .reg = .rax });
            break :blk .np;
        },
        else => unreachable,
    };
    if (op != .xor) try e.@"test"(.qword, .{ .reg = .rax }, .{ .reg = .rax });
    const d = cg.destReg(inst);
    try e.setcc(cc, .{ .reg = d });
    try e.movzx(.dword, d, .byte, .{ .reg = d });
    try cg.setResult(inst, .bool_type, d);
}

/// `@reduce` of integer lanes: the chunks combined, the lanes past the
/// length set to `op`'s identity, then halves combined down to one lane.
fn reduce(cg: *CodeGen, inst: Inst.Index, ty: Index, op: Ir.ReduceOp, operand: Ref) Error!void {
    const ip = cg.ip;
    const s = shape(ip, cg.typeOf(operand)).?;
    const e = &cg.e;
    const pop: Encoder.PackedOp = switch (op) {
        .@"and" => .pand,
        .@"or" => .por,
        .xor => .pxor,
        .add => switch (s.lane) {
            .i8 => .paddb,
            .i16 => .paddw,
            .i32 => .paddd,
            .i64 => .paddq,
            else => unreachable,
        },
        else => unreachable,
    };
    const chunks = s.chunks();
    const tail = s.bytes() % 16;
    // Lanes past the length are read only if a full chunk follows or the
    // last one's lanes are not a power of two in bytes.
    const pad = tail != 0 and (chunks > 1 or !std.math.isPowerOfTwo(tail));
    for (0..chunks) |kk| {
        const k: u32 = @intCast(kk);
        const r: Xmm = if (k == 0) .xmm0 else .xmm1;
        try loadChunk(cg, r, operand, k);
        if (pad and k == chunks - 1) {
            var bytes: [16]u8 = @splat(0);
            @memset(bytes[0..tail], 0xff);
            if (op == .@"and") {
                for (&bytes) |*b| b.* = ~b.*;
                try e.pint(.por, r, .{ .mem = try constMem(cg, bytes) });
            } else try e.pint(.pand, r, .{ .mem = try constMem(cg, bytes) });
        }
        if (k != 0) try e.pint(pop, .xmm0, .{ .reg = .xmm1 });
    }
    var width: u32 = if (chunks > 1) 16 else std.math.ceilPowerOfTwoAssert(u32, s.bytes());
    while (width > s.lane.bytes()) {
        width /= 2;
        try e.movdq(true, .{ .reg = .xmm1 }, .{ .reg = .xmm0 });
        try e.pshift(.psrldq, .xmm1, @intCast(width));
        try e.pint(pop, .xmm0, .{ .reg = .xmm1 });
    }
    const d = cg.destReg(inst);
    const signed = Type.intInfo(ip, ty).signedness == .signed;
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
/// within one register, else lane by lane through memory.
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
        if (sel[i] >= 0) from_b = false else from_a = false;
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
    if (s.lane.isFloat()) {
        try cg.loadXmm(r, try cg.valOf(elem));
    } else {
        try cg.load(.rax, elem);
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
