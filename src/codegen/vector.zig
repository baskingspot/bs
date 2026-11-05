//! Which vector operations a backend lowers natively, in SIMD registers
//! (docs/slop/architecture.md, "Vectors"). Sema asks `native` before emitting
//! an operation on whole vectors; for the rest it scalarizes, so a backend
//! sees only the vector operations it answers true for here. The answers
//! follow what upstream's Debug backend lowers natively on the same
//! architecture, and add the compares, selects, and shuffles that it
//! scalarizes but that SSE and NEON do in a few instructions.
//!
//! The architecture's backend lowers each operation for every vector type
//! accepted here; changing an answer changes Sema's output, so it goes with
//! the backend change.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const Index = InternPool.Index;
const Type = @import("../Type.zig");
const Ir = @import("../Ir.zig");
const Inst = Ir.Inst;
const Ssa = @import("Ssa.zig");

pub const Op = union(enum) {
    add_wrap,
    sub_wrap,
    mul_wrap,
    bit_and,
    bit_or,
    xor,
    not,
    add_float,
    sub_float,
    mul_float,
    div_float,
    /// `@min` and `@max`: `min_int`/`max_int` or `min_float`/`max_float`.
    min,
    max,
    /// Float `-x`, `@abs`, and `@sqrt`.
    neg,
    abs,
    sqrt,
    cmp: std.math.CompareOperator,
    reduce: Ir.ReduceOp,
    select,
    shuffle,
    /// `@intCast` that widens (every source value fits the destination,
    /// so no lane needs a check) or `@truncate`, to this vector type.
    cast: Index,
    /// `<<` and `>>` (arithmetic for signed lanes) by an amount that is
    /// the same in every lane, as SIMD shifts take it; Sema checks that.
    shl,
    shr,
};

/// The element of a vector type as a SIMD lane.
pub const Lane = enum {
    /// Bool vectors: bits (element `i` is bit `i`), not lanes.
    bool,
    i8,
    i16,
    i32,
    i64,
    f32,
    f64,

    pub fn bytes(l: Lane) u32 {
        return switch (l) {
            .bool => unreachable,
            .i8 => 1,
            .i16 => 2,
            .i32, .f32 => 4,
            .i64, .f64 => 8,
        };
    }

    pub fn isFloat(l: Lane) bool {
        return l == .f32 or l == .f64;
    }
};

/// The lane of vector type `ty`'s elements, if they have one: integers of
/// up to 64 bits, f32, f64, and bool. An integer narrower than its lane
/// (`narrow`: a `u4` in a byte lane, as vectors lay it out in memory) is
/// held extended to the lane, as narrow integers are in memory.
pub fn lane(ip: *const InternPool, ty: Index) ?Lane {
    if (ip.keyTag(ty) != .vector_type) return null;
    const child = ip.keyPayload(.vector_type, ty).child;
    if (child == .bool_type) return .bool;
    return switch (Type.class(ip, child)) {
        .int => if (Type.intInfo(ip, child).bits == 0 or Type.intInfo(ip, child).bits > 64) null else switch (Type.abiSize(ip, child)) {
            1 => .i8,
            2 => .i16,
            4 => .i32,
            8 => .i64,
            else => null,
        },
        .float => switch (Type.floatBits(ip, child)) {
            32 => .f32,
            64 => .f64,
            else => null,
        },
        else => null,
    };
}

/// The index of the field a struct wraps, as `crypto.aes` wraps its
/// blocks: its one runtime field, when that field is as large as the
/// struct, so it sits at offset 0 and the struct is its bits. A backend
/// keeps such a struct where it keeps the field (a vector in a vector
/// register), so `struct_field_val` and `aggregate_init` on it are moves.
pub fn wrappedField(ip: *const InternPool, ty: Index) ?u32 {
    if (ip.keyTag(ty) != .struct_type or Type.isPacked(ip, ty)) return null;
    const info = ip.structInfo(ty);
    var only: ?u32 = null;
    for (info.field_types, 0..) |ft, i| {
        if (info.fieldIsComptime(i) or !Type.hasRuntimeBits(ip, ft)) continue;
        if (only != null) return null;
        only = @intCast(i);
    }
    const i = only orelse return null;
    return if (Type.abiSize(ip, info.field_types[i]) == Type.abiSize(ip, ty)) i else null;
}

/// Whether vector type `ty`'s integer elements are narrower than their
/// lane (`lane`). Operations on such lanes must keep them extended, so
/// only those that do are native: bitwise ops, compares, `@select`,
/// `@shuffle`, `@min`/`@max`, and reductions with them.
pub fn narrow(ip: *const InternPool, ty: Index) bool {
    const child = ip.keyPayload(.vector_type, ty).child;
    if (Type.class(ip, child) != .int) return false;
    return Type.intInfo(ip, child).bits != 8 * Type.abiSize(ip, child);
}

/// The longest vectors lowered natively: in bytes of lanes, and in bits of
/// a bool vector, which x86_64 keeps in a general-purpose register.
pub const max_bytes = 128;
pub const max_bools = 64;

/// Whether the backend for `cpu` lowers `op` natively on vectors of type
/// `ty` (the operands' type; for `select` and `shuffle` the result's).
pub fn native(cpu: *const std.Target.Cpu, ip: *const InternPool, op: Op, ty: Index) bool {
    const neon = switch (cpu.arch) {
        .x86_64 => false,
        // Every ARMv8 core has NEON (Advanced SIMD); lanes of f16, which
        // need FEAT_FP16, are not lanes here (`lane`).
        .aarch64 => true,
        else => return false,
    };
    // SSE4.2 orders 64-bit integers (pcmpgtq); SSE2 only in many
    // instructions. NEON orders them (cmgt, cmhi).
    const order64 = neon or cpu.has(.x86, .sse4_2);
    const l = lane(ip, ty) orelse return false;
    const len = ip.keyPayload(.vector_type, ty).len;
    if (len == 0) return false;
    if (l == .bool) {
        if (len > max_bools) return false;
        return switch (op) {
            .bit_and, .bit_or, .xor, .not => true,
            .reduce => |r| r == .@"and" or r == .@"or" or r == .xor,
            else => false,
        };
    }
    if (len * l.bytes() > max_bytes) return false;
    // Between full-width integer lanes of up to 128 bytes, each a
    // different width (SSE2 unpacks and packs).
    if (op == .cast) {
        const d = lane(ip, op.cast) orelse return false;
        if (d == .bool or d.isFloat() or l.isFloat() or d == l) return false;
        return len * d.bytes() <= max_bytes and !narrow(ip, ty) and !narrow(ip, op.cast);
    }
    if (narrow(ip, ty)) switch (op) {
        .bit_and, .bit_or, .xor, .cmp, .select, .shuffle, .min, .max => {},
        // `~` keeps sign-extended lanes extended, not zero-extended ones.
        .not => if (Type.intInfo(ip, ip.keyPayload(.vector_type, ty).child).signedness == .unsigned) return false,
        .reduce => |r| if (r == .add or r == .mul) return false,
        else => return false,
    };
    return switch (op) {
        .add_wrap, .sub_wrap, .bit_and, .bit_or, .xor, .not => !l.isFloat(),
        // SSE2 multiplies 16-bit lanes, and 32-bit ones through pmuludq;
        // NEON's mul takes bytes too, but no 64-bit lanes.
        .mul_wrap => l == .i16 or l == .i32 or (neon and l == .i8),
        .add_float, .sub_float, .mul_float, .div_float, .neg, .abs, .sqrt => l.isFloat(),
        .min, .max => l != .i64 or order64,
        // A bool vector result lives in a general-purpose register.
        .cmp => |c| len <= max_bools and (l != .i64 or order64 or c == .eq or c == .neq),
        .select => len <= max_bools,
        // Float reductions are left folds, whose order a tree would
        // change.
        .reduce => |r| switch (r) {
            .@"and", .@"or", .xor, .add => !l.isFloat(),
            .min, .max => !l.isFloat() and (l != .i64 or order64),
            .mul => l == .i16 or l == .i32 or (neon and l == .i8),
        },
        .shuffle => true,
        // SSE2 shifts 16-, 32- and 64-bit lanes; bytes shift as words,
        // masked or unpacked, and 64-bit lanes shift right arithmetically
        // as logically with their sign bits shifted in. NEON shifts every
        // lane width (shl, ushr, sshr; ushl, sshl by a register).
        .shl, .shr => !l.isFloat(),
        .cast => unreachable,
    };
}

/// Reads a wrapping struct's field (`wrappedField`) as a field of the
/// struct's value: `load(struct_field_ptr(p, i))`, which Sema emits for
/// `s.repr` on a parameter or `const` (and the inliner and `forward.run`
/// leave on the caller's own local), becomes `struct_field_val(load(p))`
/// when the load comes right after the field pointer and is its only use,
/// reading `p` itself through a pointer cast that only adds `const`. The
/// field is all of the struct's bits, so the load reads the same memory;
/// the local is then only loaded and stored whole, which `Ssa.plan`
/// promotes to the register the backend keeps the struct in, where the
/// field read is a move. Rewrites in place, on the CodeGen workers.
pub fn foldWrappedLoads(gpa: Allocator, ip: *const InternPool, ir: *Ir, scratch: *std.ArrayList(u32)) Allocator.Error!void {
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    // Most functions have none, which this pass finds.
    const any = for (tags, datas) |tag, data| {
        if (tag == .struct_field_ptr and wrappedPtr(ip, ir, data) != null) break true;
    } else false;
    if (!any) return;
    scratch.clearRetainingCapacity();
    const uses = try scratch.addManyAsSlice(gpa, ir.instructions.len);
    @memset(uses, 0);
    const Count = struct {
        uses: []u32,
        const Self = @This();
        pub fn use(c: Self, ref: Inst.Ref) void {
            if (ref.toIndex()) |i| c.uses[@backingInt(i)] +|= 1;
        }
    };
    for (0..ir.instructions.len) |i| Ssa.forEachOperand(ir, @fromBackingInt(@intCast(i)), Count{ .uses = uses });
    foldBody(ip, ir, uses, ir.mainBody());
}

/// The pointer to the wrapping struct whose wrapped field
/// `struct_field_ptr` `data` addresses, if it does and is not volatile.
fn wrappedPtr(ip: *const InternPool, ir: *const Ir, data: Inst.Data) ?Inst.Ref {
    const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
    const info = Type.ptrInfo(ip, ir.typeOf(sf.operand, ip));
    if (info.flags.is_volatile or info.flags.size != .one) return null;
    return if (wrappedField(ip, info.child) == sf.index) sf.operand else null;
}

fn foldBody(ip: *const InternPool, ir: *Ir, uses: []const u32, body: []const Inst.Index) void {
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    var prev: ?Inst.Index = null;
    for (body) |inst| {
        const i = @backingInt(inst);
        switch (tags[i]) {
            .dbg_stmt => continue,
            .block, .loop => {
                const extra = ir.extraData(Ir.Block, datas[i].ty_pl.payload);
                foldBody(ip, ir, uses, ir.bodySlice(extra.end, extra.data.body_len));
            },
            .cond_br => {
                const extra = ir.extraData(Ir.CondBr, datas[i].pl_op.payload);
                foldBody(ip, ir, uses, ir.bodySlice(extra.end, extra.data.then_body_len));
                foldBody(ip, ir, uses, ir.bodySlice(extra.end + extra.data.then_body_len, extra.data.else_body_len));
            },
            .switch_br => {
                var it = ir.switchCases(datas[i].pl_op.payload);
                while (it.next()) |c| foldBody(ip, ir, uses, c.body);
                foldBody(ip, ir, uses, it.elseBody());
            },
            .load => if (prev) |x| if (datas[i].ty_op.operand == x.toRef() and tags[@backingInt(x)] == .struct_field_ptr and uses[@backingInt(x)] == 1) {
                const xi = @backingInt(x);
                if (wrappedPtr(ip, ir, datas[xi])) |p_in| {
                    var p = p_in;
                    // Through a cast to `*const S` of a `*S`.
                    if (p.toIndex()) |c| if (tags[@backingInt(c)] == .bitcast) {
                        const src = datas[@backingInt(c)].ty_op.operand;
                        const to = Type.ptrInfo(ip, datas[@backingInt(c)].ty_op.ty);
                        const from_ty = ir.typeOf(src, ip);
                        if (ip.keyTag(from_ty) == .ptr_type) {
                            const from = Type.ptrInfo(ip, from_ty);
                            if (from.child == to.child and from.flags.size == .one and !from.flags.is_volatile and
                                from.flags.address_space == to.flags.address_space) p = src;
                        }
                    };
                    const payload = datas[xi].ty_pl.payload;
                    const container = Type.ptrInfo(ip, ir.typeOf(p_in, ip)).child;
                    // The struct field pointer's payload, now the field read's.
                    @constCast(ir.extra)[payload] = @backingInt(x.toRef());
                    const field_ty = datas[i].ty_op.ty;
                    datas[i] = .{ .ty_pl = .{ .ty = field_ty, .payload = payload } };
                    tags[i] = .struct_field_val;
                    datas[xi] = .{ .ty_op = .{ .ty = container, .operand = p } };
                    tags[xi] = .load;
                }
            },
            else => {},
        }
        prev = inst;
    }
}
