//! Which vector operations a backend lowers natively, in SIMD registers
//! (docs/architecture.md, "Vectors"). Sema asks `native` before emitting
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
/// 8, 16, 32, or 64 bits, f32, f64, and bool.
pub fn lane(ip: *const InternPool, ty: Index) ?Lane {
    if (ip.keyTag(ty) != .vector_type) return null;
    const child = ip.keyPayload(.vector_type, ty).child;
    if (child == .bool_type) return .bool;
    return switch (Type.class(ip, child)) {
        .int => switch (Type.intInfo(ip, child).bits) {
            8 => .i8,
            16 => .i16,
            32 => .i32,
            64 => .i64,
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

/// The longest vectors lowered natively: in bytes of lanes, and in bits of
/// a bool vector, which x86_64 keeps in a general-purpose register.
pub const max_bytes = 128;
pub const max_bools = 64;

/// Whether the backend for `arch` lowers `op` natively on vectors of type
/// `ty` (the operands' type; for `select` and `shuffle` the result's).
pub fn native(arch: std.Target.Cpu.Arch, ip: *const InternPool, op: Op, ty: Index) bool {
    switch (arch) {
        .x86_64 => {},
        // NEON lowering comes with the aarch64 backend.
        else => return false,
    }
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
    return switch (op) {
        .add_wrap, .sub_wrap, .bit_and, .bit_or, .xor, .not => !l.isFloat(),
        // SSE2 multiplies 16-bit lanes, and 32-bit ones through pmuludq.
        .mul_wrap => l == .i16 or l == .i32,
        .add_float, .sub_float, .mul_float, .div_float, .neg, .abs, .sqrt => l.isFloat(),
        // SSE2 orders 64-bit integers only in many instructions.
        .min, .max => l != .i64,
        // A bool vector result lives in a general-purpose register;
        // 64-bit lanes only compare equal, as for `min`.
        .cmp => |c| len <= max_bools and (l != .i64 or c == .eq or c == .neq),
        .select => len <= max_bools,
        // Float reductions are left folds, whose order a tree would
        // change.
        .reduce => |r| switch (r) {
            .@"and", .@"or", .xor, .add => !l.isFloat(),
            .min, .max => !l.isFloat() and l != .i64,
            .mul => l == .i16 or l == .i32,
        },
        .shuffle => true,
    };
}
