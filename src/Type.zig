//! Queries on interned types, shared by Sema and CodeGen.
//!
//! Layout follows upstream's ABI for the two supported targets, which are
//! both 64-bit (`usize` is 64 bits, pointers are 8 bytes). Struct fields are
//! laid out in declaration order; auto-layout field order is not observable
//! by the subset zap compiles yet.

const std = @import("std");
const assert = std.debug.assert;
const InternPool = @import("InternPool.zig");
const Index = InternPool.Index;

pub const ptr_bits = 64;

pub const Class = enum {
    type,
    void,
    bool,
    noreturn,
    int,
    comptime_int,
    float,
    comptime_float,
    pointer,
    array,
    vector,
    @"struct",
    @"enum",
    @"union",
    tuple,
    optional,
    error_union,
    error_set,
    @"fn",
    enum_literal,
    null,
    undefined,
    @"opaque",
    @"anyframe",
    /// zap-modeled `std.lang` types.
    special,
};

pub fn class(ip: *const InternPool, ty: Index) Class {
    return switch (ip.indexToKey(ty)) {
        .int_type => .int,
        .ptr_type => .pointer,
        .array_type => .array,
        .vector_type => .vector,
        .opt_type => .optional,
        .anyframe_type => .@"anyframe",
        .error_union_type => .error_union,
        .error_set_type, .inferred_error_set_type => .error_set,
        .struct_type => .@"struct",
        .enum_type => .@"enum",
        .union_type => .@"union",
        .opaque_type => .@"opaque",
        .tuple_type => .tuple,
        .func_type => .@"fn",
        .simple_type => |s| switch (s) {
            .f16, .f32, .f64, .f80, .f128, .c_longdouble => .float,
            .usize, .isize, .c_char, .c_short, .c_ushort, .c_int, .c_uint, .c_long, .c_ulong, .c_longlong, .c_ulonglong => .int,
            .anyopaque => .@"opaque",
            .bool => .bool,
            .void => .void,
            .type => .type,
            .anyerror, .adhoc_inferred_error_set => .error_set,
            .comptime_int => .comptime_int,
            .comptime_float => .comptime_float,
            .noreturn => .noreturn,
            .null => .null,
            .undefined => .undefined,
            .enum_literal => .enum_literal,
            .generic_poison, .calling_convention, .clobbers => .special,
        },
        else => unreachable, // not a type
    };
}

pub fn isInt(ip: *const InternPool, ty: Index) bool {
    return class(ip, ty) == .int;
}

pub const IntInfo = std.lang.Type.Int;

pub fn intInfo(ip: *const InternPool, ty: Index) IntInfo {
    return switch (ip.indexToKey(ty)) {
        .int_type => |t| t,
        .simple_type => |s| switch (s) {
            .usize => .{ .signedness = .unsigned, .bits = ptr_bits },
            .isize => .{ .signedness = .signed, .bits = ptr_bits },
            .c_char => .{ .signedness = .signed, .bits = 8 },
            .c_short => .{ .signedness = .signed, .bits = 16 },
            .c_ushort => .{ .signedness = .unsigned, .bits = 16 },
            .c_int => .{ .signedness = .signed, .bits = 32 },
            .c_uint => .{ .signedness = .unsigned, .bits = 32 },
            .c_long, .c_longlong => .{ .signedness = .signed, .bits = 64 },
            .c_ulong, .c_ulonglong => .{ .signedness = .unsigned, .bits = 64 },
            // Error codes are `u16`, like upstream's default.
            .anyerror, .adhoc_inferred_error_set => .{ .signedness = .unsigned, .bits = 16 },
            else => unreachable,
        },
        .error_set_type, .inferred_error_set_type => .{ .signedness = .unsigned, .bits = 16 },
        // An enum is represented by its integer tag.
        .enum_type => intInfo(ip, ip.structInfo(ty).tag_type),
        else => unreachable,
    };
}

pub fn floatBits(ip: *const InternPool, ty: Index) u16 {
    return switch (ip.indexToKey(ty).simple_type) {
        .f16 => 16,
        .f32 => 32,
        .f64 => 64,
        .f80, .c_longdouble => 80,
        .f128, .comptime_float => 128,
        else => unreachable,
    };
}

/// Bits of precision, counting the implicit leading bit.
pub fn floatSignificandBits(ip: *const InternPool, ty: Index) u16 {
    return switch (floatBits(ip, ty)) {
        16 => 11,
        32 => 24,
        64 => 53,
        80 => 64,
        128 => 113,
        else => unreachable,
    };
}

/// The float type of `bits` bits (`c_longdouble` becomes `f80`).
pub fn floatOfBits(bits: u16) Index {
    return switch (bits) {
        16 => .f16_type,
        32 => .f32_type,
        64 => .f64_type,
        80 => .f80_type,
        128 => .f128_type,
        else => unreachable,
    };
}

pub fn ptrInfo(ip: *const InternPool, ty: Index) InternPool.PtrType {
    return ip.indexToKey(ty).ptr_type;
}

pub fn isSlice(ip: *const InternPool, ty: Index) bool {
    return switch (ip.indexToKey(ty)) {
        .ptr_type => |p| p.flags.size == .slice,
        else => false,
    };
}

/// The child of a pointer, optional, or array type.
pub fn childType(ip: *const InternPool, ty: Index) Index {
    return switch (ip.indexToKey(ty)) {
        .ptr_type => |p| p.child,
        .opt_type => |c| c,
        .array_type => |a| a.child,
        .vector_type => |v| v.child,
        else => unreachable,
    };
}

/// The element type of a vector type; any other type itself.
pub fn scalarType(ip: *const InternPool, ty: Index) Index {
    return switch (ip.indexToKey(ty)) {
        .vector_type => |v| v.child,
        else => ty,
    };
}

/// Whether `?ty` is represented as `ty` with 0 meaning null.
pub fn optionalReprIsPtr(ip: *const InternPool, child: Index) bool {
    return switch (ip.indexToKey(child)) {
        .ptr_type => |p| p.flags.size != .c and p.flags.size != .slice and !p.flags.is_allowzero,
        else => false,
    };
}

/// Whether values of this type exist only at compile time.
pub fn isComptimeOnly(ip: *const InternPool, ty: Index) bool {
    var hit_cycle = false;
    return comptimeOnly(ip, ty, &hit_cycle);
}

/// Sets `hit_cycle` when the answer assumed that a struct already being
/// examined is not comptime-only; such answers are not cached.
fn comptimeOnly(ip: *const InternPool, ty: Index, hit_cycle: *bool) bool {
    return switch (class(ip, ty)) {
        .type, .comptime_int, .comptime_float, .enum_literal, .null, .undefined, .@"fn", .special => true,
        .pointer => class(ip, childType(ip, ty)) != .@"fn" and comptimeOnly(ip, childType(ip, ty), hit_cycle),
        .array, .vector, .optional => comptimeOnly(ip, childType(ip, ty), hit_cycle),
        .error_union => comptimeOnly(ip, ip.indexToKey(ty).error_union_type.payload_type, hit_cycle),
        .tuple => {
            const t = ip.indexToKey(ty).tuple_type;
            for (t.types, t.values) |ft, fv| if (fv == .none and comptimeOnly(ip, ft, hit_cycle)) return true;
            return false;
        },
        .@"struct", .@"union" => {
            const info = ip.structInfo(ty);
            switch (info.comptime_only) {
                .yes => return true,
                .no => return false,
                .computing => {
                    hit_cycle.* = true;
                    return false;
                },
                .unknown => {},
            }
            info.comptime_only = .computing;
            var inner_cycle = false;
            const result = for (info.field_types) |ft| {
                if (comptimeOnly(ip, ft, &inner_cycle)) break true;
            } else false;
            const complete = switch (info.status) {
                .have_field_types, .layout_wip, .have_layout => true,
                else => false,
            };
            info.comptime_only = if (result) .yes else if (inner_cycle or !complete) .unknown else .no;
            if (inner_cycle) hit_cycle.* = true;
            return result;
        },
        else => false,
    };
}

/// Whether values of this type occupy memory at runtime.
pub fn hasRuntimeBits(ip: *const InternPool, ty: Index) bool {
    if (isComptimeOnly(ip, ty)) return false;
    return switch (class(ip, ty)) {
        .void, .noreturn, .@"opaque" => false,
        .int, .@"enum" => intInfo(ip, ty).bits != 0,
        .array => ip.indexToKey(ty).array_type.lenIncludingSentinel() != 0 and hasRuntimeBits(ip, childType(ip, ty)),
        .@"struct", .tuple, .@"union" => abiSize(ip, ty) != 0,
        else => true,
    };
}

pub fn intAbiSize(bits: u16) u64 {
    if (bits == 0) return 0;
    const bytes: u64 = (@as(u64, bits) + 7) / 8;
    return std.mem.alignForward(u64, bytes, intAbiAlignment(bits));
}

pub fn intAbiAlignment(bits: u16) u64 {
    if (bits == 0) return 1;
    const bytes: u64 = (@as(u64, bits) + 7) / 8;
    return @min(std.math.ceilPowerOfTwoAssert(u64, bytes), 16);
}

pub fn abiSize(ip: *const InternPool, ty: Index) u64 {
    return switch (class(ip, ty)) {
        .void, .noreturn, .type, .comptime_int, .comptime_float, .enum_literal, .null, .undefined, .@"fn", .special, .@"opaque" => 0,
        .bool => 1,
        .int, .error_set, .@"enum" => intAbiSize(intInfo(ip, ty).bits),
        .float => switch (ip.indexToKey(ty).simple_type) {
            .f16 => 2,
            .f32 => 4,
            .f64 => 8,
            .f80, .c_longdouble => 16,
            .f128 => 16,
            else => unreachable,
        },
        .pointer => if (isSlice(ip, ty)) 16 else 8,
        .@"anyframe" => 8,
        .array => blk: {
            const a = ip.indexToKey(ty).array_type;
            break :blk a.lenIncludingSentinel() * abiSize(ip, a.child);
        },
        .vector => blk: {
            // Upstream's stage2_x86_64 layout: bools are bits, other
            // elements are laid out like an array.
            const v = ip.indexToKey(ty).vector_type;
            const bytes = if (v.child == .bool_type) (v.len + 7) / 8 else v.len * abiSize(ip, v.child);
            break :blk std.mem.alignForward(u64, bytes, abiAlignment(ip, ty));
        },
        .optional => blk: {
            const child = childType(ip, ty);
            if (optionalReprIsPtr(ip, child)) break :blk 8;
            if (!hasRuntimeBits(ip, child)) break :blk 1;
            break :blk std.mem.alignForward(u64, abiSize(ip, child) + 1, abiAlignment(ip, child));
        },
        .error_union => blk: {
            const layout = errorUnionLayout(ip, ty);
            break :blk layout.size;
        },
        .@"struct", .@"union" => blk: {
            const info = ip.structInfo(ty);
            assert(info.status == .have_layout);
            break :blk info.size;
        },
        .tuple => tupleLayout(ip, ty, null).size,
    };
}

pub fn abiAlignment(ip: *const InternPool, ty: Index) u64 {
    return switch (class(ip, ty)) {
        .void, .noreturn, .type, .comptime_int, .comptime_float, .enum_literal, .null, .undefined, .@"fn", .special, .@"opaque" => 1,
        .bool => 1,
        .int, .error_set, .@"enum" => intAbiAlignment(intInfo(ip, ty).bits),
        .float => @min(abiSize(ip, ty), 16),
        .pointer, .@"anyframe" => 8,
        .array => abiAlignment(ip, childType(ip, ty)),
        .vector => blk: {
            // Upstream's stage2_x86_64 rule for a CPU without AVX.
            const v = ip.indexToKey(ty).vector_type;
            if (v.len == 0) break :blk 1;
            if (v.child == .bool_type) break :blk if (v.len > 64) 16 else std.math.ceilPowerOfTwoAssert(u64, (v.len + 7) / 8);
            break :blk if (abiSize(ip, v.child) == 0) 1 else 16;
        },
        .optional => blk: {
            const child = childType(ip, ty);
            if (optionalReprIsPtr(ip, child)) break :blk 8;
            break :blk abiAlignment(ip, child);
        },
        .error_union => errorUnionLayout(ip, ty).alignment,
        .@"struct", .@"union" => blk: {
            const info = ip.structInfo(ty);
            assert(info.status == .have_layout);
            break :blk info.alignment;
        },
        .tuple => tupleLayout(ip, ty, null).alignment,
    };
}

/// Byte offset of the "is non-null" flag of a non-pointer-like optional.
pub fn optionalFlagOffset(ip: *const InternPool, opt_ty: Index) u64 {
    return abiSize(ip, childType(ip, opt_ty));
}

pub const ErrorUnionLayout = struct {
    err_offset: u64,
    payload_offset: u64,
    size: u64,
    alignment: u64,
};

/// The error code (`u16`) comes first, then the payload.
pub fn errorUnionLayout(ip: *const InternPool, ty: Index) ErrorUnionLayout {
    const payload = ip.indexToKey(ty).error_union_type.payload_type;
    if (!hasRuntimeBits(ip, payload)) return .{ .err_offset = 0, .payload_offset = 0, .size = 2, .alignment = 2 };
    const pa = abiAlignment(ip, payload);
    const alignment = @max(pa, 2);
    const payload_offset = std.mem.alignForward(u64, 2, pa);
    return .{
        .err_offset = 0,
        .payload_offset = payload_offset,
        .size = std.mem.alignForward(u64, payload_offset + abiSize(ip, payload), alignment),
        .alignment = alignment,
    };
}

pub const UnionLayout = struct {
    tag_offset: u64,
    payload_offset: u64,
    /// 0 if the union has no runtime tag.
    tag_size: u64,
    payload_size: u64,
};

/// Upstream's union layout: the tag goes first unless the payload is more
/// aligned than it.
pub fn unionLayout(ip: *const InternPool, ty: Index) UnionLayout {
    const info = ip.structInfo(ty);
    var payload_size: u64 = 0;
    var payload_align: u64 = 1;
    for (info.field_types) |ft| {
        if (class(ip, ft) == .noreturn) continue;
        if (hasRuntimeBits(ip, ft)) payload_size = @max(payload_size, abiSize(ip, ft));
        payload_align = @max(payload_align, abiAlignment(ip, ft));
    }
    if (!info.has_runtime_tag) return .{ .tag_offset = 0, .payload_offset = 0, .tag_size = 0, .payload_size = payload_size };
    const tag_size = abiSize(ip, info.tag_type);
    if (abiAlignment(ip, info.tag_type) < payload_align)
        return .{ .tag_offset = payload_size, .payload_offset = 0, .tag_size = tag_size, .payload_size = payload_size };
    return .{ .tag_offset = 0, .payload_offset = tag_size, .tag_size = tag_size, .payload_size = payload_size };
}

/// The runtime tag value of union field `field`: its enum tag, or for a
/// hidden safety tag the field index.
pub fn unionFieldTag(ip: *const InternPool, ty: Index, field: u32) u64 {
    const info = ip.structInfo(ty);
    if (ip.indexToKey(info.tag_type) != .enum_type) return field;
    const tag_info = ip.structInfo(info.tag_type);
    const i = tag_info.fieldIndex(ip, ip.stringSlice(info.field_names[field])).?;
    const v = tag_info.field_defaults[i];
    return ip.intValue(u64, v) orelse @bitCast(ip.intValue(i64, v).?);
}

pub const TupleLayout = struct { size: u64, alignment: u64, field_offset: u64 };

/// Layout of a tuple; also returns the offset of field `field` if given.
pub fn tupleLayout(ip: *const InternPool, ty: Index, field: ?usize) TupleLayout {
    const t = ip.indexToKey(ty).tuple_type;
    var offset: u64 = 0;
    var alignment: u64 = 1;
    var field_offset: u64 = 0;
    for (t.types, t.values, 0..) |ft, fv, i| {
        if (fv != .none or !hasRuntimeBits(ip, ft)) {
            if (field == i) field_offset = offset;
            continue;
        }
        const a = abiAlignment(ip, ft);
        offset = std.mem.alignForward(u64, offset, a);
        if (field == i) field_offset = offset;
        offset += abiSize(ip, ft);
        alignment = @max(alignment, a);
    }
    return .{ .size = std.mem.alignForward(u64, offset, alignment), .alignment = alignment, .field_offset = field_offset };
}

pub fn fieldCount(ip: *const InternPool, ty: Index) usize {
    return switch (ip.indexToKey(ty)) {
        .struct_type, .union_type => ip.structInfo(ty).field_types.len,
        .tuple_type => |t| t.types.len,
        .array_type => |a| a.len,
        else => unreachable,
    };
}

pub fn fieldType(ip: *const InternPool, ty: Index, i: usize) Index {
    return switch (ip.indexToKey(ty)) {
        .struct_type, .union_type => ip.structInfo(ty).field_types[i],
        .tuple_type => |t| t.types[i],
        .array_type => |a| a.child,
        else => unreachable,
    };
}

/// The byte offset of field `i`. A packed struct's fields live in its
/// backing integer at offset 0 (see `packedFieldBitOffset`).
pub fn fieldOffset(ip: *const InternPool, ty: Index, i: usize) u64 {
    return switch (ip.indexToKey(ty)) {
        .struct_type => if (isPackedStruct(ip, ty)) 0 else ip.structInfo(ty).field_offsets[i],
        .union_type => unionLayout(ip, ty).payload_offset,
        .tuple_type => tupleLayout(ip, ty, i).field_offset,
        .array_type => |a| i * abiSize(ip, a.child),
        // A slice's `ptr` and `len`.
        .ptr_type => i * 8,
        else => unreachable,
    };
}

/// The integer type `@Int(.unsigned, log2(bits))` used for shift amounts.
pub fn log2IntBits(bits: u16) u16 {
    if (bits <= 1) return 0;
    return std.math.log2_int_ceil(u16, bits);
}

pub fn isPackedStruct(ip: *const InternPool, ty: Index) bool {
    return ip.indexToKey(ty) == .struct_type and ip.structInfo(ty).layout == .@"packed";
}

/// The bit offset of field `i` of packed struct `ty` in its backing
/// integer.
pub fn packedFieldBitOffset(ip: *const InternPool, ty: Index, i: usize) u16 {
    return @intCast(ip.structInfo(ty).field_offsets[i]);
}

/// The number of bits `ty` occupies in a packed struct, or null if it
/// cannot be a packed struct field (zap does not support pointers there).
pub fn packedBits(ip: *const InternPool, ty: Index) ?u16 {
    if (ty == .bool_type) return 1;
    return switch (class(ip, ty)) {
        .void => 0,
        .int, .@"enum" => intInfo(ip, ty).bits,
        .float => floatBits(ip, ty),
        .@"struct" => if (isPackedStruct(ip, ty)) intInfo(ip, ip.structInfo(ty).tag_type).bits else null,
        else => null,
    };
}
