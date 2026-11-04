//! Queries on interned types, shared by Sema and CodeGen.
//!
//! Layout follows upstream's ABI for the two supported targets, which are
//! both 64-bit (`usize` is 64 bits, pointers are 8 bytes). Struct fields are
//! laid out in declaration order; auto-layout field order is not observable
//! by the subset bs compiles yet.

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
    /// bs-modeled `std.lang` types.
    special,
};

pub fn class(ip: *const InternPool, ty: Index) Class {
    // Hot: reads the item tag, not the whole key.
    return switch (ip.keyTag(ty)) {
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
        .simple_type => switch (ip.simpleType(ty)) {
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
    if (ip.intType(ty)) |t| return t;
    return switch (ip.keyTag(ty)) {
        .simple_type => switch (ip.simpleType(ty)) {
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
            // The tag of an enum without fields may be `noreturn`.
            .noreturn => .{ .signedness = .unsigned, .bits = 0 },
            else => unreachable,
        },
        .error_set_type, .inferred_error_set_type => .{ .signedness = .unsigned, .bits = 16 },
        // An enum is represented by its integer tag.
        .enum_type => intInfo(ip, ip.structInfo(ty).tag_type),
        else => unreachable,
    };
}

pub fn floatBits(ip: *const InternPool, ty: Index) u16 {
    return switch (ip.simpleType(ty)) {
        .f16 => 16,
        .f32 => 32,
        .f64 => 64,
        .f80 => 80,
        // `long double` is `double` on aarch64-macos.
        .c_longdouble => if (ip.target == .aarch64_macos) 64 else 80,
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
    return ip.keyPayload(.ptr_type, ty);
}

pub fn isSlice(ip: *const InternPool, ty: Index) bool {
    const p = ip.keyAs(.ptr_type, ty) orelse return false;
    return p.flags.size == .slice;
}

/// The child of a pointer, optional, or array type.
pub fn childType(ip: *const InternPool, ty: Index) Index {
    return switch (ip.keyTag(ty)) {
        .ptr_type => ip.keyPayload(.ptr_type, ty).child,
        .opt_type => ip.keyPayload(.opt_type, ty),
        .array_type => ip.keyPayload(.array_type, ty).child,
        .vector_type => ip.keyPayload(.vector_type, ty).child,
        else => unreachable,
    };
}

/// The element type of a vector type; any other type itself.
pub fn scalarType(ip: *const InternPool, ty: Index) Index {
    const v = ip.keyAs(.vector_type, ty) orelse return ty;
    return v.child;
}

/// Whether `?ty` is represented as `ty` with 0 meaning null.
pub fn optionalReprIsPtr(ip: *const InternPool, child: Index) bool {
    const p = ip.keyAs(.ptr_type, child) orelse return false;
    return p.flags.size != .c and p.flags.size != .slice and !p.flags.is_allowzero;
}

/// Whether `?ty` is represented as `ty` with a zero first word meaning
/// null, as upstream's optionalReprIsPayload: single and many pointers,
/// slices (null `ptr`), and error sets (error code 0).
pub fn optionalReprIsPayload(ip: *const InternPool, child: Index) bool {
    return switch (ip.keyTag(child)) {
        .ptr_type => {
            const p = ip.keyPayload(.ptr_type, child);
            return p.flags.size != .c and !p.flags.is_allowzero;
        },
        .error_set_type, .inferred_error_set_type => true,
        .simple_type => ip.simpleType(child) == .anyerror,
        else => false,
    };
}

/// Whether no value of `ty` can exist, as upstream's `classify` returns
/// `no_possible_value`: `noreturn` and opaque types; an array or vector
/// with elements (or a sentinel) of such a type; a struct or tuple with a
/// runtime field of such a type; an auto or extern union whose fields all
/// are (one without fields too); an enum whose tag type is (`noreturn`,
/// which an exhaustive enum without fields has). Asserts that the layouts
/// of `ty` and the types it holds by value are resolved.
pub fn hasNoPossibleValue(ip: *const InternPool, ty: Index) bool {
    return switch (class(ip, ty)) {
        .noreturn, .@"opaque" => true,
        .array => {
            const a = ip.keyPayload(.array_type, ty);
            return (a.len != 0 or a.sentinel != .none) and hasNoPossibleValue(ip, a.child);
        },
        .vector => {
            const v = ip.keyPayload(.vector_type, ty);
            return v.len != 0 and hasNoPossibleValue(ip, v.child);
        },
        .tuple => {
            const t = ip.keyPayload(.tuple_type, ty);
            for (t.types, t.values) |ft, fv| if (fv == .none and hasNoPossibleValue(ip, ft)) return true;
            return false;
        },
        .@"struct" => {
            const info = ip.structInfo(ty);
            if (info.layout == .@"packed") return false;
            for (info.field_types, 0..) |ft, i| if (!info.fieldIsComptime(i) and hasNoPossibleValue(ip, ft)) return true;
            return false;
        },
        .@"union" => {
            const info = ip.structInfo(ty);
            if (info.layout == .@"packed") return false;
            for (info.field_types) |ft| if (!hasNoPossibleValue(ip, ft)) return false;
            return true;
        },
        .@"enum" => hasNoPossibleValue(ip, ip.structInfo(ty).tag_type),
        else => false,
    };
}

/// Whether values of this type exist only at compile time. As upstream's
/// Type.classify, a pointer is a runtime type whatever it points to, so
/// the answer depends only on the types `ty` contains by value: exactly
/// the layouts Sema's resolveLayout resolves and records as dependencies.
/// A struct's or union's answer is fixed when its layout is.
pub fn isComptimeOnly(ip: *const InternPool, ty: Index) bool {
    var hit_cycle = false;
    return comptimeOnly(ip, ty, &hit_cycle);
}

/// Whether a call to a function of type `f` instantiates it: a parameter
/// is declared `comptime`, is of a generic type or a comptime-only one, or
/// the return type is generic. Reads the parameter types' fields, which
/// must be resolved: a declaration's are (`Sema.funcCommon`), a function
/// type's only where Sema resolves them before asking.
pub fn fnIsGeneric(ip: *const InternPool, f: InternPool.FuncType) bool {
    if (f.comptime_bits != 0 or f.return_type == .generic_poison_type) return true;
    for (f.param_types) |p| if (p == .generic_poison_type or isComptimeOnly(ip, p)) return true;
    return false;
}

/// Set on CodeGen worker threads (see `Emit.Pool`), which read types while
/// the Sema thread analyzes: `comptimeOnly` there neither writes the
/// per-type cache nor trusts its in-progress mark.
pub threadlocal var codegen_worker: bool = false;

/// Sets `hit_cycle` when the answer assumed that a struct already being
/// examined is not comptime-only; such answers are not cached.
fn comptimeOnly(ip: *const InternPool, ty: Index, hit_cycle: *bool) bool {
    return switch (class(ip, ty)) {
        .type, .comptime_int, .comptime_float, .enum_literal, .null, .undefined, .@"fn", .special => true,
        .array, .vector, .optional => comptimeOnly(ip, childType(ip, ty), hit_cycle),
        .error_union => comptimeOnly(ip, ip.keyPayload(.error_union_type, ty).payload_type, hit_cycle),
        .tuple => {
            const t = ip.keyPayload(.tuple_type, ty);
            for (t.types, t.values) |ft, fv| if (fv == .none and comptimeOnly(ip, ft, hit_cycle)) return true;
            return false;
        },
        .@"struct", .@"union" => {
            const info = ip.structInfo(ty);
            switch (info.comptime_only) {
                .yes => return true,
                .no => return false,
                // Another thread's mark on a CodeGen worker: answered below.
                .computing => if (!codegen_worker) {
                    hit_cycle.* = true;
                    return false;
                },
                .unknown => {},
            }
            // A CodeGen worker reads only types whose layout is resolved,
            // which contain no cycle, and leaves the cache to the Sema
            // thread, whose in-progress marks it must not see or make.
            if (codegen_worker) return for (info.field_types, 0..) |ft, i| {
                if (!info.fieldIsComptime(i) and comptimeOnly(ip, ft, hit_cycle)) break true;
            } else false;
            info.comptime_only = .computing;
            var inner_cycle = false;
            const result = for (info.field_types, 0..) |ft, i| {
                if (!info.fieldIsComptime(i) and comptimeOnly(ip, ft, &inner_cycle)) break true;
            } else false;
            const complete = switch (info.status) {
                .have_field_types, .layout_wip, .have_layout => true,
                else => false,
            };
            info.comptime_only = if (result) .yes else if (inner_cycle or !complete) .unknown else .no;
            // An answer that assumed a type without known fields is not
            // final for the types containing it either.
            if (inner_cycle or !complete) hit_cycle.* = true;
            return result;
        },
        else => false,
    };
}

/// Whether values of this type occupy memory at runtime.
/// As upstream, a partially comptime aggregate (a struct with a `u32` and
/// a `type` field) has runtime bits: its comptime-only fields take no
/// space, and a pointer to it may reach runtime code.
pub fn hasRuntimeBits(ip: *const InternPool, ty: Index) bool {
    return switch (class(ip, ty)) {
        .void, .noreturn, .@"opaque" => false,
        .int, .@"enum" => intInfo(ip, ty).bits != 0,
        .array => ip.keyPayload(.array_type, ty).lenIncludingSentinel() != 0 and hasRuntimeBits(ip, childType(ip, ty)),
        .@"struct", .tuple, .@"union" => abiSize(ip, ty) != 0,
        .optional => !isComptimeOnly(ip, ty) and abiSize(ip, ty) != 0,
        else => !isComptimeOnly(ip, ty),
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
        .float => switch (ip.keyPayload(.simple_type, ty)) {
            .f16 => 2,
            .f32 => 4,
            .f64 => 8,
            .f80 => 16,
            .c_longdouble => if (ip.target == .aarch64_macos) 8 else 16,
            .f128 => 16,
            else => unreachable,
        },
        .pointer => if (isSlice(ip, ty)) 16 else 8,
        .@"anyframe" => 8,
        .array => blk: {
            const a = ip.keyPayload(.array_type, ty);
            break :blk a.lenIncludingSentinel() * abiSize(ip, a.child);
        },
        .vector => blk: {
            // Upstream's stage2_x86_64 layout: bools are bits, other
            // elements are laid out like an array.
            const v = ip.keyPayload(.vector_type, ty);
            var bytes = if (v.child == .bool_type) (v.len + 7) / 8 else v.len * abiSize(ip, v.child);
            // As LLVM on aarch64-macos, a vector rounds up to a power of
            // two bytes, except one of f80 or f128, soft floats there.
            if (ip.target == .aarch64_macos and bytes != 0 and v.child != .f80_type and v.child != .f128_type)
                bytes = std.math.ceilPowerOfTwoAssert(u64, bytes);
            break :blk std.mem.alignForward(u64, bytes, abiAlignment(ip, ty));
        },
        .optional => blk: {
            const child = childType(ip, ty);
            if (optionalReprIsPayload(ip, child)) break :blk abiSize(ip, child);
            // As upstream, `?T` of a `T` with no possible value is always
            // null: it has one possible value.
            if (hasNoPossibleValue(ip, child)) break :blk 0;
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
        .void, .noreturn, .type, .comptime_int, .comptime_float, .enum_literal, .null, .undefined, .special, .@"opaque" => 1,
        // The target's minimum function alignment, as upstream.
        .@"fn" => if (ip.target == .aarch64_macos) 4 else 1,
        .bool => 1,
        .int, .error_set, .@"enum" => intAbiAlignment(intInfo(ip, ty).bits),
        .float => @min(abiSize(ip, ty), 16),
        .pointer, .@"anyframe" => 8,
        .array => abiAlignment(ip, childType(ip, ty)),
        .vector => blk: {
            // Upstream's stage2_x86_64 rule for a CPU without AVX.
            const v = ip.keyPayload(.vector_type, ty);
            if (v.len == 0) break :blk 1;
            if (v.child == .bool_type) break :blk if (v.len > 64) 16 else std.math.ceilPowerOfTwoAssert(u64, (v.len + 7) / 8);
            break :blk if (abiSize(ip, v.child) == 0) 1 else 16;
        },
        .optional => abiAlignment(ip, childType(ip, ty)),
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
    const payload = ip.keyPayload(.error_union_type, ty).payload_type;
    // As upstream, a payload without bits still aligns the error union
    // (`E!S` of a `struct { x: u64, n: noreturn }` is 8 bytes).
    if (!hasRuntimeBits(ip, payload)) {
        const alignment = @max(2, abiAlignment(ip, payload));
        return .{ .err_offset = 0, .payload_offset = 0, .size = alignment, .alignment = alignment };
    }
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
};

/// Where a union's tag and payload are, as its layout (Sema's
/// `type_layout`) placed them.
pub fn unionLayout(ip: *const InternPool, ty: Index) UnionLayout {
    const info = ip.structInfo(ty);
    if (!info.has_runtime_tag) return .{ .tag_offset = 0, .payload_offset = 0, .tag_size = 0 };
    return .{ .tag_offset = info.field_offsets[0], .payload_offset = info.field_offsets[1], .tag_size = abiSize(ip, info.tag_type) };
}

/// The tag's and the payload's offsets in a union with a runtime tag, for
/// its layout to record: as upstream's `getUnionLayout`, the tag goes
/// first unless the fields that can be active are more aligned than it.
/// (The union's own size and alignment count every field.)
pub fn unionTagPayloadOffsets(ip: *const InternPool, info: *const InternPool.ContainerInfo) [2]u64 {
    var payload_size: u64 = 0;
    var payload_align: u64 = 1;
    for (info.field_types, 0..) |ft, i| {
        if (hasNoPossibleValue(ip, ft)) continue;
        if (hasRuntimeBits(ip, ft)) payload_size = @max(payload_size, abiSize(ip, ft));
        payload_align = @max(payload_align, unionFieldAlign(ip, info, @intCast(i)));
    }
    if (abiAlignment(ip, info.tag_type) < payload_align) return .{ payload_size, 0 };
    return .{ 0, abiSize(ip, info.tag_type) };
}

/// The alignment of union field `i`: its explicit `align(n)`, else its
/// type's.
pub fn unionFieldAlign(ip: *const InternPool, info: *const InternPool.ContainerInfo, i: u32) u64 {
    if (info.field_aligns.len != 0 and info.field_aligns[i] != 0) return info.field_aligns[i];
    return abiAlignment(ip, info.field_types[i]);
}

/// The runtime tag value of union field `field`: its enum tag, or for a
/// hidden safety tag the field index.
pub fn unionFieldTag(ip: *const InternPool, ty: Index, field: u32) u64 {
    const info = ip.structInfo(ty);
    if (ip.keyTag(info.tag_type) != .enum_type) return field;
    const tag_info = ip.structInfo(info.tag_type);
    const i = tag_info.fieldIndex(ip, ip.stringSlice(info.field_names[field])).?;
    const v = tag_info.field_defaults[i];
    return ip.intValue(u64, v) orelse @bitCast(ip.intValue(i64, v).?);
}

pub const TupleLayout = struct { size: u64, alignment: u64, field_offset: u64 };

/// Layout of a tuple; also returns the offset of field `field` if given.
pub fn tupleLayout(ip: *const InternPool, ty: Index, field: ?usize) TupleLayout {
    const t = ip.keyPayload(.tuple_type, ty);
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

/// The value of field `i` of struct or tuple `ty` if it is a `comptime`
/// field, else `.none`.
pub fn comptimeFieldValue(ip: *const InternPool, ty: Index, i: usize) Index {
    return switch (ip.keyTag(ty)) {
        .tuple_type => ip.keyPayload(.tuple_type, ty).values[i],
        .struct_type => if (ip.structInfo(ty).fieldIsComptime(i)) ip.structInfo(ty).field_defaults[i] else .none,
        else => .none,
    };
}

pub fn fieldCount(ip: *const InternPool, ty: Index) usize {
    return switch (ip.keyTag(ty)) {
        .struct_type, .union_type => ip.structInfo(ty).field_types.len,
        .tuple_type => ip.keyPayload(.tuple_type, ty).types.len,
        .array_type => ip.keyPayload(.array_type, ty).len,
        else => unreachable,
    };
}

pub fn fieldType(ip: *const InternPool, ty: Index, i: usize) Index {
    return switch (ip.keyTag(ty)) {
        .struct_type, .union_type => ip.structInfo(ty).field_types[i],
        .tuple_type => ip.keyPayload(.tuple_type, ty).types[i],
        .array_type => ip.keyPayload(.array_type, ty).child,
        else => unreachable,
    };
}

/// The byte offset of field `i`. A packed struct's fields live in its
/// backing integer at offset 0 (see `packedFieldBitOffset`).
pub fn fieldOffset(ip: *const InternPool, ty: Index, i: usize) u64 {
    return switch (ip.keyTag(ty)) {
        .struct_type => if (isPackedStruct(ip, ty)) 0 else ip.structInfo(ty).field_offsets[i],
        .union_type => unionLayout(ip, ty).payload_offset,
        .tuple_type => tupleLayout(ip, ty, i).field_offset,
        .array_type => i * abiSize(ip, ip.keyPayload(.array_type, ty).child),
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
    return ip.keyTag(ty) == .struct_type and ip.structInfo(ty).layout == .@"packed";
}

/// A packed struct or packed union: a value of its backing integer type.
pub fn isPacked(ip: *const InternPool, ty: Index) bool {
    return switch (ip.keyTag(ty)) {
        .struct_type, .union_type => ip.structInfo(ty).layout == .@"packed",
        else => false,
    };
}

/// The bit offset of field `i` of packed struct `ty` in its backing
/// integer.
pub fn packedFieldBitOffset(ip: *const InternPool, ty: Index, i: usize) u16 {
    return @intCast(ip.structInfo(ty).field_offsets[i]);
}

/// The number of bits `ty` occupies in a packed struct, or null if it
/// cannot be a packed struct field (bs does not support pointers there).
pub fn packedBits(ip: *const InternPool, ty: Index) ?u16 {
    if (ty == .bool_type) return 1;
    return switch (class(ip, ty)) {
        .void => 0,
        .int, .@"enum" => intInfo(ip, ty).bits,
        .float => floatBits(ip, ty),
        .@"struct", .@"union" => if (isPacked(ip, ty)) intInfo(ip, ip.structInfo(ty).tag_type).bits else null,
        else => null,
    };
}
