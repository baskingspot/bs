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
const InternPool = @import("../InternPool.zig");
const Index = InternPool.Index;
const Type = @import("../Type.zig");
const Ir = @import("../Ir.zig");

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
    switch (cpu.arch) {
        .x86_64 => {},
        // TODO(aarch64-rebased): NEON answers, with the aarch64
        // backend's lowering (docs/slop/architecture.md, "Vectors").
        else => return false,
    }
    // SSE4.2 orders 64-bit integers (pcmpgtq); SSE2 only in many
    // instructions.
    const order64 = cpu.has(.x86, .sse4_2);
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
        // SSE2 multiplies 16-bit lanes, and 32-bit ones through pmuludq.
        .mul_wrap => l == .i16 or l == .i32,
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
            .mul => l == .i16 or l == .i32,
        },
        .shuffle => true,
        .cast => unreachable,
    };
}
