//! Interned types and comptime values.
//!
//! Every item is deduplicated by its `Key` and carries a 128-bit stable hash
//! computed from its contents and the stable hashes of the items it refers
//! to, never from indices (see docs/architecture.md). Indices are an
//! in-memory detail.
//!
//! Concurrency: each thread appends to its own `Local` shard (selected by the
//! `Tid` every mutating call takes), so an `Index` encodes the owning thread
//! in its top bits. Deduplication maps are sharded by hash and guarded by a
//! mutex per shard. Published items are immutable and readable without locks:
//! when a shard's arrays grow, the old arrays stay alive until `deinit`, so a
//! slice returned by `indexToKey` stays valid. The skeleton runs one thread,
//! but the API is already shaped for many.
//!
//! The first `static_len` items mirror `Zir.Inst.Ref`, so a ZIR ref below
//! `static_len` is also an InternPool index.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Zir = std.zig.Zir;
const BigIntConst = std.math.big.int.Const;
const Limb = std.math.big.Limb;

const InternPool = @This();

gpa: Allocator,
io: Io,
locals: []Local,
shards: []Shard,
/// Number of bits of an index that select the owning thread.
tid_width: u5,
/// Global error set: error name to error value. Error values are an
/// in-memory detail; Atoms refer to errors by name (see docs/architecture.md).
errors_mutex: Io.Mutex = .init,
error_names: std.ArrayList(String) = .empty,
error_map: std.AutoHashMapUnmanaged(String, u32) = .empty,
/// Source of unique ids for comptime allocations.
next_comptime_alloc: std.atomic.Value(u32) = .init(0),
/// Stable hashes of the static items, derived from their index alone. Static
/// keys refer to static items interned after them (the slice types refer to
/// `.zero_u8`), so content hashes would read hashes that don't exist yet.
/// The static indices mirror `Zir.Inst.Ref` of the pinned Zig release, so
/// their numbers are as stable as their contents.
static_hashes: [static_len]Hash = undefined,

pub const Hash = u128;

/// A per-thread handle. Every call that may append to the pool takes one.
pub const Tid = enum(u8) {
    main = 0,
    _,
};

// ---------------------------------------------------------------------------
// Indices

pub const Index = enum(u32) {
    u0_type,
    u1_type,
    u8_type,
    i8_type,
    u16_type,
    i16_type,
    u29_type,
    u32_type,
    i32_type,
    u64_type,
    i64_type,
    u80_type,
    u128_type,
    i128_type,
    u256_type,
    usize_type,
    isize_type,
    c_char_type,
    c_short_type,
    c_ushort_type,
    c_int_type,
    c_uint_type,
    c_long_type,
    c_ulong_type,
    c_longlong_type,
    c_ulonglong_type,
    c_longdouble_type,
    f16_type,
    f32_type,
    f64_type,
    f80_type,
    f128_type,
    anyopaque_type,
    bool_type,
    void_type,
    type_type,
    anyerror_type,
    comptime_int_type,
    comptime_float_type,
    noreturn_type,
    anyframe_type,
    null_type,
    undefined_type,
    enum_literal_type,
    ptr_usize_type,
    ptr_const_comptime_int_type,
    manyptr_u8_type,
    manyptr_const_u8_type,
    manyptr_const_u8_sentinel_0_type,
    slice_const_u8_type,
    slice_const_u8_sentinel_0_type,
    manyptr_const_slice_const_u8_type,
    slice_const_slice_const_u8_type,
    optional_type_type,
    manyptr_const_type_type,
    slice_const_type_type,
    vector_8_i8_type,
    vector_16_i8_type,
    vector_32_i8_type,
    vector_64_i8_type,
    vector_1_u8_type,
    vector_2_u8_type,
    vector_4_u8_type,
    vector_8_u8_type,
    vector_16_u8_type,
    vector_32_u8_type,
    vector_64_u8_type,
    vector_2_i16_type,
    vector_4_i16_type,
    vector_8_i16_type,
    vector_16_i16_type,
    vector_32_i16_type,
    vector_4_u16_type,
    vector_8_u16_type,
    vector_16_u16_type,
    vector_32_u16_type,
    vector_2_i32_type,
    vector_4_i32_type,
    vector_8_i32_type,
    vector_16_i32_type,
    vector_4_u32_type,
    vector_8_u32_type,
    vector_16_u32_type,
    vector_2_i64_type,
    vector_4_i64_type,
    vector_8_i64_type,
    vector_2_u64_type,
    vector_4_u64_type,
    vector_8_u64_type,
    vector_1_u128_type,
    vector_2_u128_type,
    vector_1_u256_type,
    vector_4_f16_type,
    vector_8_f16_type,
    vector_16_f16_type,
    vector_32_f16_type,
    vector_2_f32_type,
    vector_4_f32_type,
    vector_8_f32_type,
    vector_16_f32_type,
    vector_2_f64_type,
    vector_4_f64_type,
    vector_8_f64_type,
    optional_noreturn_type,
    anyerror_void_error_union_type,
    adhoc_inferred_error_set_type,
    generic_poison_type,
    empty_tuple_type,
    undef,
    undef_bool,
    undef_usize,
    undef_u1,
    zero,
    zero_usize,
    zero_u1,
    zero_u8,
    one,
    one_usize,
    one_u1,
    one_u8,
    four_u8,
    negative_one,
    void_value,
    unreachable_value,
    null_value,
    bool_true,
    bool_false,
    empty_tuple,
    // zap-specific static items follow the ones shared with ZIR.
    /// `std.lang.CallingConvention`, which zap models directly until it
    /// analyzes `std.lang` (milestone 3).
    calling_convention_type,
    /// `std.lang.Clobbers`, modeled directly for the same reason.
    clobbers_type,

    none = std.math.maxInt(u32),
    _,

    pub fn toOptional(i: Index) Index {
        return i;
    }

    pub fn unwrap(i: Index) ?Index {
        return if (i == .none) null else i;
    }
};

comptime {
    // The static prefix must match ZIR's reserved refs one for one.
    const zir_names = @typeInfo(Zir.Inst.Ref).@"enum".field_names;
    const ip_names = @typeInfo(Index).@"enum".field_names;
    for (zir_names[0..Zir.Inst.Ref.static_len], ip_names[0..Zir.Inst.Ref.static_len]) |a, b| {
        if (!std.mem.eql(u8, a, b)) @compileError("InternPool.Index does not match Zir.Inst.Ref at " ++ a);
    }
}

pub const static_len = @backingInt(Index.clobbers_type) + 1;

/// An interned byte string (may contain zero bytes).
pub const String = enum(u32) {
    empty = 0,
    _,
};

pub const NavIndex = enum(u32) { none = std.math.maxInt(u32), _ };
pub const ContainerInfoIndex = enum(u32) { _ };

pub const Nav = struct {
    /// Simple name of the declaration.
    name: String,
    /// Fully qualified display name, for example `root:main.zig:Point.init`.
    fqn: String,
    /// Stable unit key. Equal to `fqn` except inside anonymous and generic
    /// types, whose keys are not their display names.
    key: String,
    file: u32,
    /// The `declaration` ZIR instruction.
    zir_inst: Zir.Inst.Index,
    /// Namespace (owned by Zcu) that contains this declaration.
    namespace: u32,
    hash: Hash,
    is_pub: bool,
    // The fields below belong to the `nav_val` analysis unit.
    status: enum { unresolved, resolving, resolved, failed } = .unresolved,
    ty: Index = .none,
    val: Index = .none,
    is_const: bool = true,
    linkage: Zir.Inst.Declaration.Unwrapped.Linkage = .normal,
};

/// The fields and layout of a declared container type (struct, enum, union,
/// or opaque). Owned by the type's `type_layout` analysis unit; read by
/// others only after it resolves.
pub const ContainerInfo = struct {
    namespace: u32,
    layout: std.lang.Type.ContainerLayout,
    status: enum { none, field_types_wip, have_field_types, layout_wip, have_layout, failed } = .none,
    field_names: []const String = &.{},
    /// Struct and union fields. Empty for enums.
    field_types: []const Index = &.{},
    /// Structs: the default value, `.none` for fields without one.
    /// Enums: the tag value of each field, of type `tag_type`.
    field_defaults: []const Index = &.{},
    /// Structs only: byte offsets, or bit offsets in the backing integer
    /// for packed structs.
    field_offsets: []const u64 = &.{},
    /// Enums: the integer tag type. Tagged unions: the enum tag type.
    /// Packed structs and unions: the backing integer type. Otherwise
    /// `.none`.
    tag_type: Index = .none,
    /// Enums only: whether the enum is non-exhaustive (`_`).
    nonexhaustive: bool = false,
    /// Unions: whether the union carries a tag at runtime, either declared
    /// or the hidden safety tag of an untagged auto-layout union in Debug.
    has_runtime_tag: bool = false,
    size: u64 = 0,
    alignment: u64 = 1,
    /// Cache for `Type.isComptimeOnly`, which recurses through pointers and
    /// so must stop at self-referential structs.
    comptime_only: enum { unknown, computing, yes, no } = .unknown,

    pub fn fieldIndex(info: *const ContainerInfo, ip: *const InternPool, name: []const u8) ?u32 {
        for (info.field_names, 0..) |n, i| {
            if (std.mem.eql(u8, ip.stringSlice(n), name)) return @intCast(i);
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Keys

pub const SimpleType = enum(u32) {
    f16,
    f32,
    f64,
    f80,
    f128,
    usize,
    isize,
    c_char,
    c_short,
    c_ushort,
    c_int,
    c_uint,
    c_long,
    c_ulong,
    c_longlong,
    c_ulonglong,
    c_longdouble,
    anyopaque,
    bool,
    void,
    type,
    anyerror,
    comptime_int,
    comptime_float,
    noreturn,
    null,
    undefined,
    enum_literal,
    adhoc_inferred_error_set,
    generic_poison,
    calling_convention,
    clobbers,
};

pub const SimpleValue = enum(u32) {
    void,
    @"unreachable",
    null,
    true,
    false,
};

pub const CallingConvention = enum(u8) {
    auto,
    /// The target's C calling convention (x86_64 SysV on x86_64-linux).
    c,
    naked,
    @"inline",
};

pub const PtrType = struct {
    child: Index,
    sentinel: Index = .none,
    flags: Flags = .{},
    /// A bit pointer, to a field of a packed struct: the pointer addresses
    /// a `host_size`-byte integer and the value is at `bit_offset` in it.
    /// `host_size` 0 is an ordinary pointer.
    packed_offset: PackedOffset = .{},

    pub const Size = std.lang.Type.Pointer.Size;
    pub const Flags = packed struct(u32) {
        size: Size = .one,
        is_const: bool = false,
        is_volatile: bool = false,
        is_allowzero: bool = false,
        /// 0 means the child's natural alignment, otherwise log2(align) + 1.
        alignment: u6 = 0,
        _: u21 = 0,
    };

    pub const PackedOffset = packed struct(u32) {
        host_size: u16 = 0,
        bit_offset: u16 = 0,
    };
};

pub const ArrayType = struct {
    len: u64,
    child: Index,
    sentinel: Index = .none,

    pub fn lenIncludingSentinel(a: ArrayType) u64 {
        return a.len + @intFromBool(a.sentinel != .none);
    }
};

/// A declared struct, enum, union, or opaque type. The key's tag says which.
pub const ContainerType = struct {
    file: u32,
    zir_inst: Zir.Inst.Index,
    /// Values captured from enclosing scopes; part of the type's identity.
    captures: []const Index,
    /// Display name, as upstream's `@typeName` renders it.
    name: String,
    /// Stable key, used for the stable hash and the `type_layout` unit key.
    /// The fully qualified name for declared types; for anonymous types the
    /// enclosing unit's key plus an ordinal (see docs/architecture.md).
    key: String,
    info: ContainerInfoIndex,
};

/// A tuple, or the type of an anonymous struct literal (`.{ .a = x }`),
/// which upstream makes a struct type equal by its fields and literal.
/// Both share layout and comptime fields, so they share this key.
pub const TupleType = struct {
    types: []const Index,
    /// `.none` for runtime fields, else the comptime field value.
    values: []const Index,
    /// Anonymous struct literals only: the field names (empty for a tuple),
    /// the literal's stable site key (its declaration's key and source
    /// node offset), and the type's name (`Parent__struct_<n>`).
    names: []const String = &.{},
    site: String = .empty,
    name: String = .empty,
};

pub const FuncType = struct {
    param_types: []const Index,
    return_type: Index,
    cc: CallingConvention = .auto,
    is_var_args: bool = false,
    /// Bit i set if parameter i is `comptime` (generic function types only).
    comptime_bits: u32 = 0,
    noalias_bits: u32 = 0,
    is_generic: bool = false,
};

pub const Int = struct {
    ty: Index,
    storage: Storage,

    pub const Storage = union(enum) {
        u64: u64,
        i64: i64,
        big: BigIntConst,
    };
};

/// A float value. The storage is fixed by the type: `f16`, `f32`, `f64`,
/// `f80` (also `c_longdouble`), and `f128` (also `comptime_float`), so the
/// canonical encoding, hash, and equality are the exact bits: `-0.0` and
/// `0.0` are distinct values, and so are NaNs with different payloads, as
/// upstream interns them.
pub const Float = struct {
    ty: Index,
    storage: Storage,

    pub const Storage = union(enum) {
        f16: f16,
        f32: f32,
        f64: f64,
        f80: f80,
        f128: f128,
    };

    /// The bits of the value, zero-extended.
    pub fn bits(f: Float) u128 {
        return switch (f.storage) {
            inline else => |v| @as(@Int(.unsigned, @bitSizeOf(@TypeOf(v))), @bitCast(v)),
        };
    }

    pub fn toF128(f: Float) f128 {
        return switch (f.storage) {
            inline else => |v| v,
        };
    }
};

pub const Ptr = struct {
    ty: Index,
    base: BaseAddr,
    /// Byte offset from the base address.
    byte_offset: u64 = 0,

    pub const BaseAddr = union(enum) {
        /// The address of a declaration.
        nav: NavIndex,
        /// An unnamed constant (string literals, `&comptime_value`).
        /// `orig_ty` is the pointer type the constant was referenced through.
        uav: struct { val: Index, orig_ty: Index },
        /// A comptime-mutable allocation owned by a Sema instance. Never
        /// reaches runtime code; its id is not stable across runs.
        comptime_alloc: u32,
        /// An address from an integer (`@ptrFromInt`).
        int,
        /// Field `index` of the aggregate that pointer `base` points to.
        field: struct { base: Index, index: u64 },
        /// Element `index` of the array or many-pointer `base` points into.
        elem: struct { base: Index, index: u64 },
    };
};

pub const Aggregate = struct {
    ty: Index,
    storage: Storage,

    pub const Storage = union(enum) {
        /// Includes the sentinel, if any.
        elems: []const Index,
        /// Bytes of a `[N]u8`/`[N:s]u8` array, including the sentinel.
        bytes: String,
        repeated_elem: Index,
    };
};

pub const Func = struct {
    owner_nav: NavIndex,
    ty: Index,
    /// The `func`/`func_inferred`/`func_fancy` instruction.
    zir_inst: Zir.Inst.Index,
    /// For a generic instance: the generic function and the values of its
    /// comptime parameters (`.none` for runtime parameters).
    generic_owner: Index = .none,
    comptime_args: []const Index = &.{},
};

pub const Key = union(enum) {
    int_type: std.lang.Type.Int,
    ptr_type: PtrType,
    array_type: ArrayType,
    vector_type: struct { len: u32, child: Index },
    opt_type: Index,
    /// `.none` child is plain `anyframe`.
    anyframe_type: Index,
    error_union_type: struct { error_set_type: Index, payload_type: Index },
    simple_type: SimpleType,
    struct_type: ContainerType,
    enum_type: ContainerType,
    union_type: ContainerType,
    opaque_type: ContainerType,
    tuple_type: TupleType,
    /// Names sorted by their bytes.
    error_set_type: []const String,
    /// The inferred error set of function instance `func`.
    inferred_error_set_type: Index,
    func_type: FuncType,

    simple_value: SimpleValue,
    undef: Index,
    int: Int,
    float: Float,
    err: struct { ty: Index, name: String },
    error_union: struct { ty: Index, val: union(enum) { err_name: String, payload: Index } },
    enum_literal: String,
    /// A value of an enum type: `int` is the tag value, of the tag type.
    enum_tag: struct { ty: Index, int: Index },
    /// A value of a union type. `tag` is the active field's `enum_tag` value
    /// (for untagged unions, of the union's field index as a `u32`).
    un: struct { ty: Index, tag: Index, val: Index },
    ptr: Ptr,
    slice: struct { ty: Index, ptr: Index, len: Index },
    /// `val == .none` is null.
    opt: struct { ty: Index, val: Index },
    aggregate: Aggregate,
    func: Func,
    /// A function declared `extern`, defined by the export of `name`
    /// (zap links statically, so another part of the program).
    extern_func: ExternFunc,
    calling_convention: CallingConvention,
    /// A container type's capture of declaration `nav` from an enclosing
    /// generic namespace (ZIR's `decl_val`/`decl_ref` captures). The
    /// declaration is resolved only when the type's body reads the capture,
    /// as upstream, so a type may capture the declaration that it is the
    /// value of. Appears only in `ContainerType.captures`.
    nav_capture: struct { nav: NavIndex, by_ref: bool },
};

pub const ExternFunc = struct {
    name: String,
    ty: Index,
    is_weak: bool,
};

// ---------------------------------------------------------------------------
// Storage

const Tag = enum(u8) {
    type_int_signed,
    type_int_unsigned,
    type_simple,
    type_ptr,
    type_array,
    type_vector,
    type_opt,
    type_anyframe,
    type_error_union,
    type_error_set,
    type_inferred_error_set,
    type_struct,
    type_enum,
    type_union,
    type_opaque,
    type_tuple,
    type_func,
    simple_value,
    undef,
    int_u64,
    int_i64,
    int_big,
    /// `extra`: type, then the bits in 1 (f16, f32), 2 (f64), 3 (f80), or
    /// 4 (f128) little-endian words.
    float_f16,
    float_f32,
    float_f64,
    float_f80,
    float_f128,
    err,
    error_union_err,
    error_union_payload,
    enum_literal,
    enum_tag,
    un,
    ptr,
    slice,
    opt_null,
    opt_payload,
    aggregate_elems,
    aggregate_bytes,
    aggregate_repeated,
    func,
    extern_func,
    calling_convention,
    nav_capture_val,
    nav_capture_ref,
};

const Item = struct {
    tag: Tag,
    data: u32,
};

/// An append-only array that one thread appends to while others read
/// published elements without locking. Growing copies into a new buffer and
/// retires the old one until `deinit`, so readers never see freed memory.
fn List(comptime T: type) type {
    return struct {
        ptr: std.atomic.Value([*]T) = .init(@constCast(&[0]T{})),
        len: std.atomic.Value(u32) = .init(0),
        cap: u32 = 0,
        retired: std.ArrayList([]T) = .empty,

        const Self = @This();

        fn deinit(l: *Self, gpa: Allocator) void {
            for (l.retired.items) |buf| gpa.free(buf);
            l.retired.deinit(gpa);
            if (l.cap != 0) gpa.free(l.ptr.raw[0..l.cap]);
        }

        fn ensureUnused(l: *Self, gpa: Allocator, n: u32) !void {
            const len = l.len.raw;
            if (len + n <= l.cap) return;
            const new_cap = @max(16, l.cap * 2, len + n);
            const new = try gpa.alloc(T, new_cap);
            @memcpy(new[0..len], l.ptr.raw[0..len]);
            if (l.cap != 0) try l.retired.append(gpa, l.ptr.raw[0..l.cap]);
            l.ptr.store(new.ptr, .release);
            l.cap = new_cap;
        }

        fn append(l: *Self, gpa: Allocator, item: T) !u32 {
            try l.ensureUnused(gpa, 1);
            const i = l.len.raw;
            l.ptr.raw[i] = item;
            l.len.store(i + 1, .release);
            return i;
        }

        fn appendSlice(l: *Self, gpa: Allocator, items: []const T) !u32 {
            try l.ensureUnused(gpa, @intCast(items.len));
            const i = l.len.raw;
            @memcpy(l.ptr.raw[i..][0..items.len], items);
            l.len.store(i + @as(u32, @intCast(items.len)), .release);
            return i;
        }

        fn view(l: *const Self) [*]T {
            return l.ptr.load(.acquire);
        }
    };
}

const Local = struct {
    items: List(Item) = .{},
    hashes: List(Hash) = .{},
    extra: List(u32) = .{},
    strings: List([]const u8) = .{},
    limbs: List([]const Limb) = .{},
    navs: List(*Nav) = .{},
    structs: List(*ContainerInfo) = .{},
    /// Owns string bytes, limbs, navs, and struct infos.
    arena: std.heap.ArenaAllocator,
};

const Shard = struct {
    mutex: Io.Mutex = .init,
    /// Entries carry the low 64 bits of the item's stable hash, so a probe
    /// rejects non-matching entries without loading the item.
    map: std.HashMapUnmanaged(Entry, void, EntryContext, 80) = .empty,
    string_map: std.HashMapUnmanaged(String, void, StringContext, 80) = .empty,
};

const Entry = struct { hash: u64, index: Index };

const EntryContext = struct {
    pub fn hash(_: EntryContext, e: Entry) u64 {
        return e.hash;
    }
    pub fn eql(_: EntryContext, a: Entry, b: Entry) bool {
        return a.index == b.index;
    }
};

const KeyAdapter = struct {
    ip: *const InternPool,
    key_hash: Hash,
    pub fn hash(ka: KeyAdapter, _: Key) u64 {
        return @truncate(ka.key_hash);
    }
    pub fn eql(ka: KeyAdapter, key: Key, e: Entry) bool {
        return e.hash == @as(u64, @truncate(ka.key_hash)) and keyEql(ka.ip, key, ka.ip.indexToKey(e.index));
    }
};

const StringContext = struct {
    ip: *const InternPool,
    pub fn hash(ctx: StringContext, s: String) u64 {
        return std.hash.Wyhash.hash(0, ctx.ip.stringSlice(s));
    }
    pub fn eql(_: StringContext, a: String, b: String) bool {
        return a == b;
    }
};

const StringAdapter = struct {
    ip: *const InternPool,
    pub fn hash(_: StringAdapter, bytes: []const u8) u64 {
        return std.hash.Wyhash.hash(0, bytes);
    }
    pub fn eql(sa: StringAdapter, bytes: []const u8, s: String) bool {
        return std.mem.eql(u8, bytes, sa.ip.stringSlice(s));
    }
};

// ---------------------------------------------------------------------------
// Lifetime

pub fn init(gpa: Allocator, io: Io, thread_count: u32) !InternPool {
    const n = std.math.ceilPowerOfTwo(u32, @max(thread_count, 1)) catch unreachable;
    const tid_width: u5 = @intCast(std.math.log2_int(u32, n));
    var ip: InternPool = .{
        .gpa = gpa,
        .io = io,
        .locals = try gpa.alloc(Local, n),
        .shards = try gpa.alloc(Shard, n),
        .tid_width = tid_width,
    };
    for (ip.locals) |*l| l.* = .{ .arena = .init(gpa) };
    for (ip.shards) |*s| s.* = .{};
    errdefer ip.deinit();

    // String 0 is the empty string; error value 0 means "no error".
    const empty = try ip.getString(.main, "");
    assert(empty == .empty);
    try ip.error_names.append(gpa, .empty);

    for (&ip.static_hashes, 0..) |*h, i| {
        var hasher: Hasher = .init("static");
        hasher.int(u32, @intCast(i));
        h.* = hasher.final();
    }
    for (static_keys, 0..) |key, i| {
        const index = try ip.get(.main, key);
        assert(@backingInt(index) == i);
    }
    return ip;
}

pub fn deinit(ip: *InternPool) void {
    const gpa = ip.gpa;
    for (ip.locals) |*l| {
        l.items.deinit(gpa);
        l.hashes.deinit(gpa);
        l.extra.deinit(gpa);
        l.strings.deinit(gpa);
        l.limbs.deinit(gpa);
        l.navs.deinit(gpa);
        l.structs.deinit(gpa);
        l.arena.deinit();
    }
    for (ip.shards) |*s| {
        s.map.deinit(gpa);
        s.string_map.deinit(gpa);
    }
    gpa.free(ip.locals);
    gpa.free(ip.shards);
    ip.error_names.deinit(gpa);
    ip.error_map.deinit(gpa);
    ip.* = undefined;
}

// Index encoding: the owning thread sits in the top `tid_width` bits of 31,
// leaving the top bit free for `Ir.Inst.Ref`.

fn tidShift(ip: *const InternPool) u5 {
    return 31 - ip.tid_width;
}

fn wrap(ip: *const InternPool, tid: Tid, local: u32) u32 {
    assert(local < (@as(u32, 1) << ip.tidShift()));
    return (@as(u32, @backingInt(tid)) << ip.tidShift()) | local;
}

fn unwrapIndex(ip: *const InternPool, raw: u32) struct { local: *Local, index: u32 } {
    const shift = ip.tidShift();
    const tid = if (ip.tid_width == 0) 0 else raw >> shift;
    return .{ .local = &ip.locals[tid], .index = raw & ((@as(u32, 1) << shift) - 1) };
}

// ---------------------------------------------------------------------------
// Strings

pub fn getString(ip: *InternPool, tid: Tid, bytes: []const u8) !String {
    const h = std.hash.Wyhash.hash(0, bytes);
    const shard = &ip.shards[h & (ip.shards.len - 1)];
    shard.mutex.lockUncancelable(ip.io);
    defer shard.mutex.unlock(ip.io);
    const gop = try shard.string_map.getOrPutContextAdapted(ip.gpa, bytes, StringAdapter{ .ip = ip }, .{ .ip = ip });
    if (gop.found_existing) return gop.key_ptr.*;
    const local = &ip.locals[@backingInt(tid)];
    const owned = try local.arena.allocator().dupe(u8, bytes);
    const i = try local.strings.append(ip.gpa, owned);
    const s: String = @fromBackingInt(ip.wrap(tid, i));
    gop.key_ptr.* = s;
    return s;
}

pub fn stringSlice(ip: *const InternPool, s: String) []const u8 {
    const u = ip.unwrapIndex(@backingInt(s));
    return u.local.strings.view()[u.index];
}

// ---------------------------------------------------------------------------
// Navs and struct infos

pub fn createNav(ip: *InternPool, tid: Tid, nav: Nav) !NavIndex {
    const local = &ip.locals[@backingInt(tid)];
    const ptr = try local.arena.allocator().create(Nav);
    ptr.* = nav;
    const i = try local.navs.append(ip.gpa, ptr);
    return @fromBackingInt(ip.wrap(tid, i));
}

pub fn getNav(ip: *const InternPool, nav: NavIndex) *Nav {
    const u = ip.unwrapIndex(@backingInt(nav));
    return u.local.navs.view()[u.index];
}

pub fn createContainerInfo(ip: *InternPool, tid: Tid, info: ContainerInfo) !ContainerInfoIndex {
    const local = &ip.locals[@backingInt(tid)];
    const ptr = try local.arena.allocator().create(ContainerInfo);
    ptr.* = info;
    const i = try local.structs.append(ip.gpa, ptr);
    return @fromBackingInt(ip.wrap(tid, i));
}

/// The info of a declared container type of any kind.
pub fn structInfo(ip: *const InternPool, ty: Index) *ContainerInfo {
    const u = ip.unwrapIndex(@backingInt(ip.containerType(ty).?.info));
    return u.local.structs.view()[u.index];
}

/// The container key of a declared struct, enum, union, or opaque type.
pub fn containerType(ip: *const InternPool, ty: Index) ?ContainerType {
    return switch (ip.indexToKey(ty)) {
        .struct_type, .enum_type, .union_type, .opaque_type => |c| c,
        else => null,
    };
}

/// Arena for long-lived data owned by thread `tid` (struct field lists).
pub fn arena(ip: *InternPool, tid: Tid) Allocator {
    return ip.locals[@backingInt(tid)].arena.allocator();
}

// ---------------------------------------------------------------------------
// Errors

/// Returns the in-memory error value for `name`. Order-dependent: never let
/// it reach an Atom; codegen refers to errors by name.
pub fn errorValue(ip: *InternPool, name: String) !u32 {
    ip.errors_mutex.lockUncancelable(ip.io);
    defer ip.errors_mutex.unlock(ip.io);
    const gop = try ip.error_map.getOrPut(ip.gpa, name);
    if (!gop.found_existing) {
        gop.value_ptr.* = @intCast(ip.error_names.items.len);
        try ip.error_names.append(ip.gpa, name);
    }
    return gop.value_ptr.*;
}

// ---------------------------------------------------------------------------
// Interning

/// The dedup shard of a key. Chosen by the hash's high bits; the shard's
/// map uses the low bits, which would otherwise be equal within a shard.
fn shardOf(ip: *InternPool, key_hash: Hash) *Shard {
    return &ip.shards[@as(usize, @truncate(key_hash >> 64)) & (ip.shards.len - 1)];
}

/// The index of `key` if it is interned.
pub fn find(ip: *InternPool, key: Key) ?Index {
    const key_hash = ip.hashKey(key);
    const shard = ip.shardOf(key_hash);
    shard.mutex.lockUncancelable(ip.io);
    defer shard.mutex.unlock(ip.io);
    const e = shard.map.getKeyAdapted(key, KeyAdapter{ .ip = ip, .key_hash = key_hash }) orelse return null;
    return e.index;
}

pub fn get(ip: *InternPool, tid: Tid, key_in: Key) Allocator.Error!Index {
    var bytes_buf: std.ArrayList(u8) = .empty;
    defer bytes_buf.deinit(ip.gpa);
    const key = if (key_in == .aggregate) try ip.canonicalAggregate(tid, key_in.aggregate, &bytes_buf) else key_in;
    const key_hash = ip.hashKey(key);
    const shard = ip.shardOf(key_hash);
    shard.mutex.lockUncancelable(ip.io);
    defer shard.mutex.unlock(ip.io);
    const gop = try shard.map.getOrPutContextAdapted(ip.gpa, key, KeyAdapter{ .ip = ip, .key_hash = key_hash }, .{});
    if (gop.found_existing) return gop.key_ptr.index;
    errdefer _ = shard.map.removeContext(gop.key_ptr.*, .{});
    const local = &ip.locals[@backingInt(tid)];
    const item = try ip.encode(local, key);
    try local.hashes.ensureUnused(ip.gpa, 1);
    const i = try local.items.append(ip.gpa, item);
    _ = try local.hashes.append(ip.gpa, key_hash);
    assert(local.hashes.len.raw == local.items.len.raw);
    const index: Index = @fromBackingInt(ip.wrap(tid, i));
    gop.key_ptr.* = .{ .hash = @truncate(key_hash), .index = index };
    return index;
}

/// Gives each array or vector value one storage form, as upstream does, so
/// equal values intern to the same index: `repeated_elem` when every
/// element (and the sentinel) is the same, else `bytes` for defined `u8`
/// elements, else `elems`.
fn canonicalAggregate(ip: *InternPool, tid: Tid, a: Aggregate, buf: *std.ArrayList(u8)) Allocator.Error!Key {
    const child: Index, const len: u64 = switch (ip.indexToKey(a.ty)) {
        .array_type => |t| .{ t.child, t.lenIncludingSentinel() },
        .vector_type => |t| .{ t.child, t.len },
        else => return .{ .aggregate = a },
    };
    if (len == 0) return .{ .aggregate = a };
    switch (a.storage) {
        .repeated_elem => return .{ .aggregate = a },
        .bytes => |str| {
            const bytes = ip.stringSlice(str)[0..@intCast(len)];
            for (bytes[1..]) |b| if (b != bytes[0]) return .{ .aggregate = a };
            const e = try ip.get(tid, .{ .int = .{ .ty = .u8_type, .storage = .{ .u64 = bytes[0] } } });
            return .{ .aggregate = .{ .ty = a.ty, .storage = .{ .repeated_elem = e } } };
        },
        .elems => |elems| {
            for (elems[1..]) |e| {
                if (e != elems[0]) break;
            } else return .{ .aggregate = .{ .ty = a.ty, .storage = .{ .repeated_elem = elems[0] } } };
            if (child != .u8_type) return .{ .aggregate = a };
            try buf.ensureTotalCapacity(ip.gpa, elems.len);
            for (elems) |e| switch (ip.indexToKey(e)) {
                .int => |i| buf.appendAssumeCapacity(@intCast(i.storage.u64)),
                else => return .{ .aggregate = a },
            };
            return .{ .aggregate = .{ .ty = a.ty, .storage = .{ .bytes = try ip.getString(tid, buf.items) } } };
        },
    }
}

fn addExtra(ip: *InternPool, local: *Local, words: []const u32) !u32 {
    return local.extra.appendSlice(ip.gpa, words);
}

fn idx(i: Index) u32 {
    return @backingInt(i);
}

fn encode(ip: *InternPool, local: *Local, key: Key) !Item {
    const gpa = ip.gpa;
    switch (key) {
        .int_type => |t| return .{ .tag = if (t.signedness == .signed) .type_int_signed else .type_int_unsigned, .data = t.bits },
        .simple_type => |t| return .{ .tag = .type_simple, .data = @backingInt(t) },
        .ptr_type => |t| return .{ .tag = .type_ptr, .data = try ip.addExtra(local, &.{ idx(t.child), idx(t.sentinel), @bitCast(t.flags), @bitCast(t.packed_offset) }) },
        .array_type => |t| return .{ .tag = .type_array, .data = try ip.addExtra(local, &.{ @truncate(t.len), @truncate(t.len >> 32), idx(t.child), idx(t.sentinel) }) },
        .vector_type => |t| return .{ .tag = .type_vector, .data = try ip.addExtra(local, &.{ t.len, idx(t.child) }) },
        .opt_type => |c| return .{ .tag = .type_opt, .data = idx(c) },
        .anyframe_type => |c| return .{ .tag = .type_anyframe, .data = idx(c) },
        .error_union_type => |t| return .{ .tag = .type_error_union, .data = try ip.addExtra(local, &.{ idx(t.error_set_type), idx(t.payload_type) }) },
        .error_set_type => |names| {
            const start = try ip.addExtra(local, &.{@intCast(names.len)});
            _ = try ip.addExtra(local, @ptrCast(names));
            return .{ .tag = .type_error_set, .data = start };
        },
        .inferred_error_set_type => |f| return .{ .tag = .type_inferred_error_set, .data = idx(f) },
        .nav_capture => |c| return .{ .tag = if (c.by_ref) .nav_capture_ref else .nav_capture_val, .data = @backingInt(c.nav) },
        .struct_type, .enum_type, .union_type, .opaque_type => |t| {
            const start = try ip.addExtra(local, &.{ t.file, @backingInt(t.zir_inst), @backingInt(t.name), @backingInt(t.info), @intCast(t.captures.len), @backingInt(t.key) });
            _ = try ip.addExtra(local, @ptrCast(t.captures));
            return .{ .tag = switch (key) {
                .struct_type => .type_struct,
                .enum_type => .type_enum,
                .union_type => .type_union,
                else => .type_opaque,
            }, .data = start };
        },
        .tuple_type => |t| {
            assert(t.types.len == t.values.len);
            assert(t.names.len == 0 or t.names.len == t.types.len);
            const start = try ip.addExtra(local, &.{ @intCast(t.types.len), @intFromBool(t.names.len != 0) });
            _ = try ip.addExtra(local, @ptrCast(t.types));
            _ = try ip.addExtra(local, @ptrCast(t.values));
            if (t.names.len != 0) {
                _ = try ip.addExtra(local, @ptrCast(t.names));
                _ = try ip.addExtra(local, &.{ @backingInt(t.site), @backingInt(t.name) });
            }
            return .{ .tag = .type_tuple, .data = start };
        },
        .func_type => |t| {
            const flags: u32 = @as(u32, @backingInt(t.cc)) | (@as(u32, @intFromBool(t.is_var_args)) << 8) | (@as(u32, @intFromBool(t.is_generic)) << 9);
            const start = try ip.addExtra(local, &.{ @intCast(t.param_types.len), idx(t.return_type), flags, t.comptime_bits, t.noalias_bits });
            _ = try ip.addExtra(local, @ptrCast(t.param_types));
            return .{ .tag = .type_func, .data = start };
        },
        .simple_value => |v| return .{ .tag = .simple_value, .data = @backingInt(v) },
        .undef => |t| return .{ .tag = .undef, .data = idx(t) },
        .int => |int| switch (int.storage) {
            .u64 => |v| return .{ .tag = .int_u64, .data = try ip.addExtra(local, &.{ idx(int.ty), @truncate(v), @truncate(v >> 32) }) },
            .i64 => |v| {
                const u: u64 = @bitCast(v);
                return .{ .tag = .int_i64, .data = try ip.addExtra(local, &.{ idx(int.ty), @truncate(u), @truncate(u >> 32) }) };
            },
            .big => |big| {
                const limbs = try local.arena.allocator().dupe(Limb, big.limbs);
                const li = try local.limbs.append(gpa, limbs);
                return .{ .tag = .int_big, .data = try ip.addExtra(local, &.{ idx(int.ty), @intFromBool(big.positive), li }) };
            },
        },
        .float => |f| {
            const b = f.bits();
            const words = [4]u32{ @truncate(b), @truncate(b >> 32), @truncate(b >> 64), @truncate(b >> 96) };
            const tag: Tag, const n: usize = switch (f.storage) {
                .f16 => .{ .float_f16, 1 },
                .f32 => .{ .float_f32, 1 },
                .f64 => .{ .float_f64, 2 },
                .f80 => .{ .float_f80, 3 },
                .f128 => .{ .float_f128, 4 },
            };
            const start = try ip.addExtra(local, &.{idx(f.ty)});
            _ = try ip.addExtra(local, words[0..n]);
            return .{ .tag = tag, .data = start };
        },
        .err => |e| return .{ .tag = .err, .data = try ip.addExtra(local, &.{ idx(e.ty), @backingInt(e.name) }) },
        .error_union => |e| switch (e.val) {
            .err_name => |n| return .{ .tag = .error_union_err, .data = try ip.addExtra(local, &.{ idx(e.ty), @backingInt(n) }) },
            .payload => |p| return .{ .tag = .error_union_payload, .data = try ip.addExtra(local, &.{ idx(e.ty), idx(p) }) },
        },
        .enum_literal => |s| return .{ .tag = .enum_literal, .data = @backingInt(s) },
        .enum_tag => |e| return .{ .tag = .enum_tag, .data = try ip.addExtra(local, &.{ idx(e.ty), idx(e.int) }) },
        .un => |u| return .{ .tag = .un, .data = try ip.addExtra(local, &.{ idx(u.ty), idx(u.tag), idx(u.val) }) },
        .ptr => |p| {
            const tag: u32, const a: u32, const b: u64 = switch (p.base) {
                .nav => |n| .{ 0, @backingInt(n), 0 },
                .uav => |u| .{ 1, idx(u.val), idx(u.orig_ty) },
                .comptime_alloc => |c| .{ 2, c, 0 },
                .int => .{ 3, 0, 0 },
                .field => |f| .{ 4, idx(f.base), f.index },
                .elem => |e| .{ 5, idx(e.base), e.index },
            };
            return .{ .tag = .ptr, .data = try ip.addExtra(local, &.{ idx(p.ty), tag, a, @truncate(b), @truncate(b >> 32), @truncate(p.byte_offset), @truncate(p.byte_offset >> 32) }) };
        },
        .slice => |s| return .{ .tag = .slice, .data = try ip.addExtra(local, &.{ idx(s.ty), idx(s.ptr), idx(s.len) }) },
        .opt => |o| {
            if (o.val == .none) return .{ .tag = .opt_null, .data = idx(o.ty) };
            return .{ .tag = .opt_payload, .data = try ip.addExtra(local, &.{ idx(o.ty), idx(o.val) }) };
        },
        .aggregate => |a| switch (a.storage) {
            .elems => |elems| {
                const start = try ip.addExtra(local, &.{ idx(a.ty), @intCast(elems.len) });
                _ = try ip.addExtra(local, @ptrCast(elems));
                return .{ .tag = .aggregate_elems, .data = start };
            },
            .bytes => |s| return .{ .tag = .aggregate_bytes, .data = try ip.addExtra(local, &.{ idx(a.ty), @backingInt(s) }) },
            .repeated_elem => |e| return .{ .tag = .aggregate_repeated, .data = try ip.addExtra(local, &.{ idx(a.ty), idx(e) }) },
        },
        .func => |f| {
            const start = try ip.addExtra(local, &.{ @backingInt(f.owner_nav), idx(f.ty), @backingInt(f.zir_inst), idx(f.generic_owner), @intCast(f.comptime_args.len) });
            _ = try ip.addExtra(local, @ptrCast(f.comptime_args));
            return .{ .tag = .func, .data = start };
        },
        .extern_func => |f| return .{ .tag = .extern_func, .data = try ip.addExtra(local, &.{ @backingInt(f.name), idx(f.ty), @intFromBool(f.is_weak) }) },
        .calling_convention => |cc| return .{ .tag = .calling_convention, .data = @backingInt(cc) },
    }
}

pub fn indexToKey(ip: *const InternPool, index: Index) Key {
    assert(index != .none);
    const u = ip.unwrapIndex(@backingInt(index));
    const item = u.local.items.view()[u.index];
    const extra = u.local.extra.view();
    const d = item.data;
    const I = struct {
        fn i(x: u32) Index {
            return @fromBackingInt(x);
        }
        fn s(x: u32) String {
            return @fromBackingInt(x);
        }
        fn u64of(lo: u32, hi: u32) u64 {
            return @as(u64, lo) | (@as(u64, hi) << 32);
        }
    };
    return switch (item.tag) {
        .type_int_signed => .{ .int_type = .{ .signedness = .signed, .bits = @intCast(d) } },
        .type_int_unsigned => .{ .int_type = .{ .signedness = .unsigned, .bits = @intCast(d) } },
        .type_simple => .{ .simple_type = @fromBackingInt(d) },
        .type_ptr => .{ .ptr_type = .{ .child = I.i(extra[d]), .sentinel = I.i(extra[d + 1]), .flags = @bitCast(extra[d + 2]), .packed_offset = @bitCast(extra[d + 3]) } },
        .type_array => .{ .array_type = .{ .len = I.u64of(extra[d], extra[d + 1]), .child = I.i(extra[d + 2]), .sentinel = I.i(extra[d + 3]) } },
        .type_vector => .{ .vector_type = .{ .len = extra[d], .child = I.i(extra[d + 1]) } },
        .type_opt => .{ .opt_type = I.i(d) },
        .type_anyframe => .{ .anyframe_type = I.i(d) },
        .type_error_union => .{ .error_union_type = .{ .error_set_type = I.i(extra[d]), .payload_type = I.i(extra[d + 1]) } },
        .type_error_set => .{ .error_set_type = @ptrCast(extra[d + 1 ..][0..extra[d]]) },
        .type_inferred_error_set => .{ .inferred_error_set_type = I.i(d) },
        .nav_capture_val, .nav_capture_ref => .{ .nav_capture = .{ .nav = @fromBackingInt(d), .by_ref = item.tag == .nav_capture_ref } },
        .type_struct, .type_enum, .type_union, .type_opaque => blk: {
            const c: ContainerType = .{
                .file = extra[d],
                .zir_inst = @fromBackingInt(extra[d + 1]),
                .name = I.s(extra[d + 2]),
                .info = @fromBackingInt(extra[d + 3]),
                .key = I.s(extra[d + 5]),
                .captures = @ptrCast(extra[d + 6 ..][0..extra[d + 4]]),
            };
            break :blk switch (item.tag) {
                .type_struct => .{ .struct_type = c },
                .type_enum => .{ .enum_type = c },
                .type_union => .{ .union_type = c },
                else => .{ .opaque_type = c },
            };
        },
        .type_tuple => blk: {
            const len = extra[d];
            const named = extra[d + 1] != 0;
            const rest = d + 2 + 2 * len;
            break :blk .{ .tuple_type = .{
                .types = @ptrCast(extra[d + 2 ..][0..len]),
                .values = @ptrCast(extra[d + 2 + len ..][0..len]),
                .names = if (named) @ptrCast(extra[rest..][0..len]) else &.{},
                .site = if (named) @fromBackingInt(extra[rest + len]) else .empty,
                .name = if (named) @fromBackingInt(extra[rest + len + 1]) else .empty,
            } };
        },
        .type_func => blk: {
            const flags = extra[d + 2];
            break :blk .{ .func_type = .{
                .param_types = @ptrCast(extra[d + 5 ..][0..extra[d]]),
                .return_type = I.i(extra[d + 1]),
                .cc = @fromBackingInt(@as(u8, @truncate(flags))),
                .is_var_args = (flags >> 8) & 1 != 0,
                .is_generic = (flags >> 9) & 1 != 0,
                .comptime_bits = extra[d + 3],
                .noalias_bits = extra[d + 4],
            } };
        },
        .simple_value => .{ .simple_value = @fromBackingInt(d) },
        .undef => .{ .undef = I.i(d) },
        .int_u64 => .{ .int = .{ .ty = I.i(extra[d]), .storage = .{ .u64 = I.u64of(extra[d + 1], extra[d + 2]) } } },
        .int_i64 => .{ .int = .{ .ty = I.i(extra[d]), .storage = .{ .i64 = @bitCast(I.u64of(extra[d + 1], extra[d + 2])) } } },
        .int_big => .{ .int = .{ .ty = I.i(extra[d]), .storage = .{ .big = .{
            .positive = extra[d + 1] != 0,
            .limbs = u.local.limbs.view()[extra[d + 2]],
        } } } },
        .float_f16, .float_f32, .float_f64, .float_f80, .float_f128 => blk: {
            const w = extra[d + 1 ..];
            const ty = I.i(extra[d]);
            break :blk .{ .float = .{ .ty = ty, .storage = switch (item.tag) {
                .float_f16 => .{ .f16 = @bitCast(@as(u16, @truncate(w[0]))) },
                .float_f32 => .{ .f32 = @bitCast(w[0]) },
                .float_f64 => .{ .f64 = @bitCast(I.u64of(w[0], w[1])) },
                .float_f80 => .{ .f80 = @bitCast(@as(u80, @truncate(@as(u96, w[2]) << 64 | I.u64of(w[0], w[1])))) },
                .float_f128 => .{ .f128 = @bitCast(@as(u128, I.u64of(w[2], w[3])) << 64 | I.u64of(w[0], w[1])) },
                else => unreachable,
            } } };
        },
        .err => .{ .err = .{ .ty = I.i(extra[d]), .name = I.s(extra[d + 1]) } },
        .error_union_err => .{ .error_union = .{ .ty = I.i(extra[d]), .val = .{ .err_name = I.s(extra[d + 1]) } } },
        .error_union_payload => .{ .error_union = .{ .ty = I.i(extra[d]), .val = .{ .payload = I.i(extra[d + 1]) } } },
        .enum_literal => .{ .enum_literal = I.s(d) },
        .enum_tag => .{ .enum_tag = .{ .ty = I.i(extra[d]), .int = I.i(extra[d + 1]) } },
        .un => .{ .un = .{ .ty = I.i(extra[d]), .tag = I.i(extra[d + 1]), .val = I.i(extra[d + 2]) } },
        .ptr => blk: {
            const a = extra[d + 2];
            const b = I.u64of(extra[d + 3], extra[d + 4]);
            break :blk .{ .ptr = .{
                .ty = I.i(extra[d]),
                .base = switch (extra[d + 1]) {
                    0 => .{ .nav = @fromBackingInt(a) },
                    1 => .{ .uav = .{ .val = I.i(a), .orig_ty = I.i(@intCast(b)) } },
                    2 => .{ .comptime_alloc = a },
                    3 => .int,
                    4 => .{ .field = .{ .base = I.i(a), .index = b } },
                    5 => .{ .elem = .{ .base = I.i(a), .index = b } },
                    else => unreachable,
                },
                .byte_offset = I.u64of(extra[d + 5], extra[d + 6]),
            } };
        },
        .slice => .{ .slice = .{ .ty = I.i(extra[d]), .ptr = I.i(extra[d + 1]), .len = I.i(extra[d + 2]) } },
        .opt_null => .{ .opt = .{ .ty = I.i(d), .val = .none } },
        .opt_payload => .{ .opt = .{ .ty = I.i(extra[d]), .val = I.i(extra[d + 1]) } },
        .aggregate_elems => .{ .aggregate = .{ .ty = I.i(extra[d]), .storage = .{ .elems = @ptrCast(extra[d + 2 ..][0..extra[d + 1]]) } } },
        .aggregate_bytes => .{ .aggregate = .{ .ty = I.i(extra[d]), .storage = .{ .bytes = I.s(extra[d + 1]) } } },
        .aggregate_repeated => .{ .aggregate = .{ .ty = I.i(extra[d]), .storage = .{ .repeated_elem = I.i(extra[d + 1]) } } },
        .func => .{ .func = .{
            .owner_nav = @fromBackingInt(extra[d]),
            .ty = I.i(extra[d + 1]),
            .zir_inst = @fromBackingInt(extra[d + 2]),
            .generic_owner = I.i(extra[d + 3]),
            .comptime_args = @ptrCast(extra[d + 5 ..][0..extra[d + 4]]),
        } },
        .extern_func => .{ .extern_func = .{ .name = I.s(extra[d]), .ty = I.i(extra[d + 1]), .is_weak = extra[d + 2] != 0 } },
        .calling_convention => .{ .calling_convention = @fromBackingInt(@as(u8, @truncate(d))) },
    };
}

pub fn stableHash(ip: *const InternPool, index: Index) Hash {
    if (@backingInt(index) < static_len) return ip.static_hashes[@backingInt(index)];
    const u = ip.unwrapIndex(@backingInt(index));
    assert(u.index < u.local.hashes.len.load(.acquire));
    return u.local.hashes.view()[u.index];
}

// ---------------------------------------------------------------------------
// Stable hashing and key equality

/// Builds a 128-bit stable hash, the format of cache keys. Fields are
/// appended to a small buffer that is hashed in one call (chained for long
/// inputs): per-field streaming updates cost more than the hash itself for
/// typical keys.
pub const Hasher = struct {
    buf: [buf_len]u8 = undefined,
    len: usize = 0,
    chain: Hash = 0,

    const buf_len = 128;

    pub fn init(domain: []const u8) Hasher {
        var hasher: Hasher = .{};
        hasher.bytes(domain);
        return hasher;
    }
    pub fn bytes(hasher: *Hasher, b: []const u8) void {
        hasher.int(u64, b.len);
        if (b.len <= buf_len - hasher.len) {
            @memcpy(hasher.buf[hasher.len..][0..b.len], b);
            hasher.len += b.len;
            return;
        }
        var d = b;
        while (d.len > 0) {
            if (hasher.len == buf_len) hasher.flush();
            const n = @min(d.len, buf_len - hasher.len);
            @memcpy(hasher.buf[hasher.len..][0..n], d[0..n]);
            hasher.len += n;
            d = d[n..];
        }
    }
    pub fn int(hasher: *Hasher, comptime T: type, v: T) void {
        const n = @sizeOf(T);
        if (hasher.len + n > buf_len) hasher.flush();
        hasher.buf[hasher.len..][0..n].* = std.mem.toBytes(v);
        hasher.len += n;
    }
    pub fn final(hasher: *Hasher) Hash {
        return hash128(hasher.chain, hasher.buf[0..hasher.len]);
    }
    fn flush(hasher: *Hasher) void {
        hasher.chain = hash128(hasher.chain, hasher.buf[0..hasher.len]);
        hasher.len = 0;
    }
};

/// Two seeded Wyhash passes. Not cryptographic: stable hashes identify
/// content, they do not defend against chosen collisions. Measured against
/// SipHash128 with `zig build bench-intern`.
fn hash128(seed: Hash, data: []const u8) Hash {
    const lo = std.hash.Wyhash.hash(@truncate(seed), data);
    const hi = std.hash.Wyhash.hash(@as(u64, @truncate(seed >> 64)) ^ 0x9e3779b97f4a7c15, data);
    return @as(Hash, hi) << 64 | lo;
}

fn hashIndex(ip: *const InternPool, hasher: *Hasher, i: Index) void {
    hasher.int(Hash, if (i == .none) 0 else ip.stableHash(i));
}

fn hashIndices(ip: *const InternPool, hasher: *Hasher, list: []const Index) void {
    hasher.int(u64, list.len);
    for (list) |i| ip.hashIndex(hasher, i);
}

fn hashString(ip: *const InternPool, hasher: *Hasher, s: String) void {
    hasher.bytes(ip.stringSlice(s));
}

/// The stable hash of `key`, which is also its dedup hash.
pub fn hashKey(ip: *const InternPool, key: Key) Hash {
    var h: Hasher = .init(@tagName(key));
    switch (key) {
        .int_type => |t| {
            h.int(u8, @backingInt(t.signedness));
            h.int(u16, t.bits);
        },
        .simple_type => |t| h.int(u32, @backingInt(t)),
        .ptr_type => |t| {
            ip.hashIndex(&h, t.child);
            ip.hashIndex(&h, t.sentinel);
            h.int(u32, @bitCast(t.flags));
            h.int(u32, @bitCast(t.packed_offset));
        },
        .array_type => |t| {
            h.int(u64, t.len);
            ip.hashIndex(&h, t.child);
            ip.hashIndex(&h, t.sentinel);
        },
        .vector_type => |t| {
            h.int(u32, t.len);
            ip.hashIndex(&h, t.child);
        },
        .opt_type, .anyframe_type, .inferred_error_set_type, .undef => |i| ip.hashIndex(&h, i),
        .nav_capture => |c| {
            h.int(Hash, ip.getNav(c.nav).hash);
            h.int(u8, @intFromBool(c.by_ref));
        },
        .error_union_type => |t| {
            ip.hashIndex(&h, t.error_set_type);
            ip.hashIndex(&h, t.payload_type);
        },
        .error_set_type => |names| {
            h.int(u64, names.len);
            for (names) |n| ip.hashString(&h, n);
        },
        // A declared type's identity in-memory is its ZIR instruction, but
        // its stable hash is its stable key plus captures.
        .struct_type, .enum_type, .union_type, .opaque_type => |t| {
            ip.hashString(&h, t.key);
            ip.hashIndices(&h, t.captures);
        },
        .tuple_type => |t| {
            ip.hashIndices(&h, t.types);
            ip.hashIndices(&h, t.values);
            if (t.names.len != 0) {
                for (t.names) |n| ip.hashString(&h, n);
                ip.hashString(&h, t.site);
            }
        },
        .func_type => |t| {
            ip.hashIndices(&h, t.param_types);
            ip.hashIndex(&h, t.return_type);
            h.int(u8, @backingInt(t.cc));
            h.int(u8, @intFromBool(t.is_var_args));
            h.int(u8, @intFromBool(t.is_generic));
            h.int(u32, t.comptime_bits);
            h.int(u32, t.noalias_bits);
        },
        .simple_value => |v| h.int(u32, @backingInt(v)),
        .int => |int| {
            ip.hashIndex(&h, int.ty);
            switch (int.storage) {
                .u64 => |v| {
                    h.int(u8, 1);
                    h.int(u64, v);
                },
                .i64 => |v| {
                    h.int(u8, if (v < 0) 0 else 1);
                    h.int(u64, @abs(v));
                },
                .big => |big| {
                    h.int(u8, @intFromBool(big.positive));
                    h.bytes(std.mem.sliceAsBytes(big.limbs));
                },
            }
        },
        // The type fixes the storage, so the bits identify the value.
        .float => |f| {
            ip.hashIndex(&h, f.ty);
            h.int(u128, f.bits());
        },
        .err => |e| {
            ip.hashIndex(&h, e.ty);
            ip.hashString(&h, e.name);
        },
        .error_union => |e| {
            ip.hashIndex(&h, e.ty);
            switch (e.val) {
                .err_name => |n| {
                    h.int(u8, 0);
                    ip.hashString(&h, n);
                },
                .payload => |p| {
                    h.int(u8, 1);
                    ip.hashIndex(&h, p);
                },
            }
        },
        .enum_literal => |s| ip.hashString(&h, s),
        .enum_tag => |e| {
            ip.hashIndex(&h, e.ty);
            ip.hashIndex(&h, e.int);
        },
        .un => |u| {
            ip.hashIndex(&h, u.ty);
            ip.hashIndex(&h, u.tag);
            ip.hashIndex(&h, u.val);
        },
        .ptr => |p| {
            ip.hashIndex(&h, p.ty);
            h.int(u8, @backingInt(std.meta.activeTag(p.base)));
            switch (p.base) {
                .nav => |n| h.int(Hash, ip.getNav(n).hash),
                .uav => |u| {
                    ip.hashIndex(&h, u.val);
                    ip.hashIndex(&h, u.orig_ty);
                },
                .comptime_alloc => |c| h.int(u32, c),
                .int => {},
                .field => |f| {
                    ip.hashIndex(&h, f.base);
                    h.int(u64, f.index);
                },
                .elem => |e| {
                    ip.hashIndex(&h, e.base);
                    h.int(u64, e.index);
                },
            }
            h.int(u64, p.byte_offset);
        },
        .slice => |s| {
            ip.hashIndex(&h, s.ty);
            ip.hashIndex(&h, s.ptr);
            ip.hashIndex(&h, s.len);
        },
        .opt => |o| {
            ip.hashIndex(&h, o.ty);
            ip.hashIndex(&h, o.val);
        },
        .aggregate => |a| {
            ip.hashIndex(&h, a.ty);
            h.int(u8, @backingInt(std.meta.activeTag(a.storage)));
            switch (a.storage) {
                .elems => |elems| ip.hashIndices(&h, elems),
                .bytes => |s| ip.hashString(&h, s),
                .repeated_elem => |e| ip.hashIndex(&h, e),
            }
        },
        .func => |f| {
            h.int(Hash, ip.getNav(f.owner_nav).hash);
            ip.hashIndex(&h, f.ty);
            ip.hashIndex(&h, f.generic_owner);
            ip.hashIndices(&h, f.comptime_args);
        },
        .extern_func => |f| {
            ip.hashString(&h, f.name);
            ip.hashIndex(&h, f.ty);
            h.int(u8, @intFromBool(f.is_weak));
        },
        .calling_convention => |cc| h.int(u8, @backingInt(cc)),
    }
    return h.final();
}

fn keyEql(ip: *const InternPool, a: Key, b: Key) bool {
    _ = ip;
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    const eqlIdx = std.mem.eql;
    return switch (a) {
        .int_type => |x| x.signedness == b.int_type.signedness and x.bits == b.int_type.bits,
        .simple_type => |x| x == b.simple_type,
        .ptr_type => |x| x.child == b.ptr_type.child and x.sentinel == b.ptr_type.sentinel and
            @as(u32, @bitCast(x.flags)) == @as(u32, @bitCast(b.ptr_type.flags)) and
            @as(u32, @bitCast(x.packed_offset)) == @as(u32, @bitCast(b.ptr_type.packed_offset)),
        .array_type => |x| x.len == b.array_type.len and x.child == b.array_type.child and x.sentinel == b.array_type.sentinel,
        .vector_type => |x| x.len == b.vector_type.len and x.child == b.vector_type.child,
        .opt_type => |x| x == b.opt_type,
        .anyframe_type => |x| x == b.anyframe_type,
        .inferred_error_set_type => |x| x == b.inferred_error_set_type,
        .nav_capture => |x| x.nav == b.nav_capture.nav and x.by_ref == b.nav_capture.by_ref,
        .undef => |x| x == b.undef,
        .error_union_type => |x| x.error_set_type == b.error_union_type.error_set_type and x.payload_type == b.error_union_type.payload_type,
        .error_set_type => |x| eqlIdx(String, x, b.error_set_type),
        .struct_type, .enum_type, .union_type, .opaque_type => |x| {
            const y = switch (b) {
                .struct_type, .enum_type, .union_type, .opaque_type => |c| c,
                else => unreachable,
            };
            return x.file == y.file and x.zir_inst == y.zir_inst and eqlIdx(Index, x.captures, y.captures);
        },
        .tuple_type => |x| eqlIdx(Index, x.types, b.tuple_type.types) and eqlIdx(Index, x.values, b.tuple_type.values) and
            eqlIdx(String, x.names, b.tuple_type.names) and x.site == b.tuple_type.site,
        .func_type => |x| {
            const y = b.func_type;
            return eqlIdx(Index, x.param_types, y.param_types) and x.return_type == y.return_type and
                x.cc == y.cc and x.is_var_args == y.is_var_args and x.is_generic == y.is_generic and
                x.comptime_bits == y.comptime_bits and x.noalias_bits == y.noalias_bits;
        },
        .simple_value => |x| x == b.simple_value,
        .int => |x| {
            const y = b.int;
            if (x.ty != y.ty) return false;
            if (std.meta.activeTag(x.storage) != std.meta.activeTag(y.storage)) return false;
            return switch (x.storage) {
                .u64 => |v| v == y.storage.u64,
                .i64 => |v| v == y.storage.i64,
                .big => |v| v.eql(y.storage.big),
            };
        },
        .float => |x| x.ty == b.float.ty and std.meta.activeTag(x.storage) == std.meta.activeTag(b.float.storage) and x.bits() == b.float.bits(),
        .err => |x| x.ty == b.err.ty and x.name == b.err.name,
        .error_union => |x| {
            const y = b.error_union;
            if (x.ty != y.ty or std.meta.activeTag(x.val) != std.meta.activeTag(y.val)) return false;
            return switch (x.val) {
                .err_name => |n| n == y.val.err_name,
                .payload => |p| p == y.val.payload,
            };
        },
        .enum_literal => |x| x == b.enum_literal,
        .enum_tag => |x| x.ty == b.enum_tag.ty and x.int == b.enum_tag.int,
        .un => |x| x.ty == b.un.ty and x.tag == b.un.tag and x.val == b.un.val,
        .ptr => |x| {
            const y = b.ptr;
            if (x.ty != y.ty or x.byte_offset != y.byte_offset) return false;
            if (std.meta.activeTag(x.base) != std.meta.activeTag(y.base)) return false;
            return switch (x.base) {
                .nav => |n| n == y.base.nav,
                .uav => |u| u.val == y.base.uav.val and u.orig_ty == y.base.uav.orig_ty,
                .comptime_alloc => |c| c == y.base.comptime_alloc,
                .int => true,
                .field => |f| f.base == y.base.field.base and f.index == y.base.field.index,
                .elem => |e| e.base == y.base.elem.base and e.index == y.base.elem.index,
            };
        },
        .slice => |x| x.ty == b.slice.ty and x.ptr == b.slice.ptr and x.len == b.slice.len,
        .opt => |x| x.ty == b.opt.ty and x.val == b.opt.val,
        .aggregate => |x| {
            const y = b.aggregate;
            if (x.ty != y.ty or std.meta.activeTag(x.storage) != std.meta.activeTag(y.storage)) return false;
            return switch (x.storage) {
                .elems => |e| eqlIdx(Index, e, y.storage.elems),
                .bytes => |s| s == y.storage.bytes,
                .repeated_elem => |e| e == y.storage.repeated_elem,
            };
        },
        .func => |x| {
            const y = b.func;
            return x.owner_nav == y.owner_nav and x.ty == y.ty and x.zir_inst == y.zir_inst and
                x.generic_owner == y.generic_owner and eqlIdx(Index, x.comptime_args, y.comptime_args);
        },
        .extern_func => |x| x.name == b.extern_func.name and x.ty == b.extern_func.ty and x.is_weak == b.extern_func.is_weak,
        .calling_convention => |x| x == b.calling_convention,
    };
}

// ---------------------------------------------------------------------------
// Queries

/// The type of a value. Types have type `type`.
pub fn typeOf(ip: *const InternPool, index: Index) Index {
    return switch (index) {
        .void_value => .void_type,
        .unreachable_value => .noreturn_type,
        .null_value => .null_type,
        .bool_true, .bool_false => .bool_type,
        .empty_tuple => .empty_tuple_type,
        else => switch (ip.indexToKey(index)) {
            .int_type,
            .ptr_type,
            .array_type,
            .vector_type,
            .opt_type,
            .anyframe_type,
            .error_union_type,
            .simple_type,
            .struct_type,
            .enum_type,
            .union_type,
            .opaque_type,
            .tuple_type,
            .error_set_type,
            .inferred_error_set_type,
            .func_type,
            => .type_type,
            .simple_value => unreachable,
            .undef => |t| t,
            .int => |x| x.ty,
            .float => |x| x.ty,
            .err => |x| x.ty,
            .error_union => |x| x.ty,
            .enum_literal => .enum_literal_type,
            .enum_tag => |x| x.ty,
            .un => |x| x.ty,
            .ptr => |x| x.ty,
            .slice => |x| x.ty,
            .opt => |x| x.ty,
            .aggregate => |x| x.ty,
            .func => |x| x.ty,
            .extern_func => |x| x.ty,
            .calling_convention => .calling_convention_type,
            .nav_capture => .generic_poison_type,
        },
    };
}

pub fn isType(ip: *const InternPool, index: Index) bool {
    return ip.typeOf(index) == .type_type;
}

/// Interns an integer value of type `ty`, canonicalizing its storage.
pub fn getInt(ip: *InternPool, tid: Tid, ty: Index, value: anytype) !Index {
    const T = @TypeOf(value);
    if (T == BigIntConst) {
        if (value.positive) {
            if (value.toInt(u64)) |v| return ip.get(tid, .{ .int = .{ .ty = ty, .storage = .{ .u64 = v } } }) else |_| {}
        } else if (value.toInt(i64)) |v| {
            return ip.get(tid, .{ .int = .{ .ty = ty, .storage = .{ .i64 = v } } });
        } else |_| {}
        return ip.get(tid, .{ .int = .{ .ty = ty, .storage = .{ .big = value } } });
    }
    if (value >= 0) return ip.get(tid, .{ .int = .{ .ty = ty, .storage = .{ .u64 = @intCast(value) } } });
    return ip.get(tid, .{ .int = .{ .ty = ty, .storage = .{ .i64 = @intCast(value) } } });
}

/// Interns `value` (any float type) as a value of float type `ty`, rounded
/// to nearest-even into the type's storage.
pub fn getFloat(ip: *InternPool, tid: Tid, ty: Index, value: anytype) !Index {
    return ip.get(tid, .{ .float = .{ .ty = ty, .storage = switch (ip.indexToKey(ty).simple_type) {
        .f16 => .{ .f16 = @floatCast(value) },
        .f32 => .{ .f32 = @floatCast(value) },
        .f64 => .{ .f64 = @floatCast(value) },
        .f80, .c_longdouble => .{ .f80 = @floatCast(value) },
        .f128, .comptime_float => .{ .f128 = @floatCast(value) },
        else => unreachable,
    } } });
}

/// The value of an integer as a big integer. `space` backs small values.
pub fn intToBig(ip: *const InternPool, index: Index, space: *[2]Limb) BigIntConst {
    const int = ip.indexToKey(index).int;
    return switch (int.storage) {
        .u64 => |v| std.math.big.int.Mutable.init(space, v).toConst(),
        .i64 => |v| std.math.big.int.Mutable.init(space, v).toConst(),
        .big => |b| b,
    };
}

/// The value of an integer that fits in `T`, or null.
pub fn intValue(ip: *const InternPool, comptime T: type, index: Index) ?T {
    const int = ip.indexToKey(index).int;
    return switch (int.storage) {
        .u64 => |v| std.math.cast(T, v),
        .i64 => |v| std.math.cast(T, v),
        .big => |b| b.toInt(T) catch null,
    };
}

// ---------------------------------------------------------------------------
// Static keys

const static_keys = blk: {
    const u = std.lang.Signedness.unsigned;
    const s = std.lang.Signedness.signed;
    const vec = struct {
        fn v(len: u32, child: Index) Key {
            return .{ .vector_type = .{ .len = len, .child = child } };
        }
    }.v;
    const int = struct {
        fn i(ty: Index, v: i64) Key {
            return .{ .int = .{ .ty = ty, .storage = if (v < 0) .{ .i64 = v } else .{ .u64 = @intCast(v) } } };
        }
    }.i;
    break :blk [_]Key{
        .{ .int_type = .{ .signedness = u, .bits = 0 } },
        .{ .int_type = .{ .signedness = u, .bits = 1 } },
        .{ .int_type = .{ .signedness = u, .bits = 8 } },
        .{ .int_type = .{ .signedness = s, .bits = 8 } },
        .{ .int_type = .{ .signedness = u, .bits = 16 } },
        .{ .int_type = .{ .signedness = s, .bits = 16 } },
        .{ .int_type = .{ .signedness = u, .bits = 29 } },
        .{ .int_type = .{ .signedness = u, .bits = 32 } },
        .{ .int_type = .{ .signedness = s, .bits = 32 } },
        .{ .int_type = .{ .signedness = u, .bits = 64 } },
        .{ .int_type = .{ .signedness = s, .bits = 64 } },
        .{ .int_type = .{ .signedness = u, .bits = 80 } },
        .{ .int_type = .{ .signedness = u, .bits = 128 } },
        .{ .int_type = .{ .signedness = s, .bits = 128 } },
        .{ .int_type = .{ .signedness = u, .bits = 256 } },
        .{ .simple_type = .usize },
        .{ .simple_type = .isize },
        .{ .simple_type = .c_char },
        .{ .simple_type = .c_short },
        .{ .simple_type = .c_ushort },
        .{ .simple_type = .c_int },
        .{ .simple_type = .c_uint },
        .{ .simple_type = .c_long },
        .{ .simple_type = .c_ulong },
        .{ .simple_type = .c_longlong },
        .{ .simple_type = .c_ulonglong },
        .{ .simple_type = .c_longdouble },
        .{ .simple_type = .f16 },
        .{ .simple_type = .f32 },
        .{ .simple_type = .f64 },
        .{ .simple_type = .f80 },
        .{ .simple_type = .f128 },
        .{ .simple_type = .anyopaque },
        .{ .simple_type = .bool },
        .{ .simple_type = .void },
        .{ .simple_type = .type },
        .{ .simple_type = .anyerror },
        .{ .simple_type = .comptime_int },
        .{ .simple_type = .comptime_float },
        .{ .simple_type = .noreturn },
        .{ .anyframe_type = .none },
        .{ .simple_type = .null },
        .{ .simple_type = .undefined },
        .{ .simple_type = .enum_literal },
        .{ .ptr_type = .{ .child = .usize_type } },
        .{ .ptr_type = .{ .child = .comptime_int_type, .flags = .{ .is_const = true } } },
        .{ .ptr_type = .{ .child = .u8_type, .flags = .{ .size = .many } } },
        .{ .ptr_type = .{ .child = .u8_type, .flags = .{ .size = .many, .is_const = true } } },
        .{ .ptr_type = .{ .child = .u8_type, .sentinel = .zero_u8, .flags = .{ .size = .many, .is_const = true } } },
        .{ .ptr_type = .{ .child = .u8_type, .flags = .{ .size = .slice, .is_const = true } } },
        .{ .ptr_type = .{ .child = .u8_type, .sentinel = .zero_u8, .flags = .{ .size = .slice, .is_const = true } } },
        .{ .ptr_type = .{ .child = .slice_const_u8_type, .flags = .{ .size = .many, .is_const = true } } },
        .{ .ptr_type = .{ .child = .slice_const_u8_type, .flags = .{ .size = .slice, .is_const = true } } },
        .{ .opt_type = .type_type },
        .{ .ptr_type = .{ .child = .type_type, .flags = .{ .size = .many, .is_const = true } } },
        .{ .ptr_type = .{ .child = .type_type, .flags = .{ .size = .slice, .is_const = true } } },
        vec(8, .i8_type),
        vec(16, .i8_type),
        vec(32, .i8_type),
        vec(64, .i8_type),
        vec(1, .u8_type),
        vec(2, .u8_type),
        vec(4, .u8_type),
        vec(8, .u8_type),
        vec(16, .u8_type),
        vec(32, .u8_type),
        vec(64, .u8_type),
        vec(2, .i16_type),
        vec(4, .i16_type),
        vec(8, .i16_type),
        vec(16, .i16_type),
        vec(32, .i16_type),
        vec(4, .u16_type),
        vec(8, .u16_type),
        vec(16, .u16_type),
        vec(32, .u16_type),
        vec(2, .i32_type),
        vec(4, .i32_type),
        vec(8, .i32_type),
        vec(16, .i32_type),
        vec(4, .u32_type),
        vec(8, .u32_type),
        vec(16, .u32_type),
        vec(2, .i64_type),
        vec(4, .i64_type),
        vec(8, .i64_type),
        vec(2, .u64_type),
        vec(4, .u64_type),
        vec(8, .u64_type),
        vec(1, .u128_type),
        vec(2, .u128_type),
        vec(1, .u256_type),
        vec(4, .f16_type),
        vec(8, .f16_type),
        vec(16, .f16_type),
        vec(32, .f16_type),
        vec(2, .f32_type),
        vec(4, .f32_type),
        vec(8, .f32_type),
        vec(16, .f32_type),
        vec(2, .f64_type),
        vec(4, .f64_type),
        vec(8, .f64_type),
        .{ .opt_type = .noreturn_type },
        .{ .error_union_type = .{ .error_set_type = .anyerror_type, .payload_type = .void_type } },
        .{ .simple_type = .adhoc_inferred_error_set },
        .{ .simple_type = .generic_poison },
        .{ .tuple_type = .{ .types = &.{}, .values = &.{} } },
        .{ .undef = .undefined_type },
        .{ .undef = .bool_type },
        .{ .undef = .usize_type },
        .{ .undef = .u1_type },
        int(.comptime_int_type, 0),
        int(.usize_type, 0),
        int(.u1_type, 0),
        int(.u8_type, 0),
        int(.comptime_int_type, 1),
        int(.usize_type, 1),
        int(.u1_type, 1),
        int(.u8_type, 1),
        int(.u8_type, 4),
        int(.comptime_int_type, -1),
        .{ .simple_value = .void },
        .{ .simple_value = .@"unreachable" },
        .{ .simple_value = .null },
        .{ .simple_value = .true },
        .{ .simple_value = .false },
        .{ .aggregate = .{ .ty = .empty_tuple_type, .storage = .{ .elems = &.{} } } },
        .{ .simple_type = .calling_convention },
        .{ .simple_type = .clobbers },
    };
};

comptime {
    assert(static_keys.len == static_len);
}

test "static items match their indices and deduplicate" {
    var ip: InternPool = try .init(std.testing.allocator, std.testing.io, 1);
    defer ip.deinit();
    try std.testing.expectEqual(Index.u8_type, try ip.get(.main, .{ .int_type = .{ .signedness = .unsigned, .bits = 8 } }));
    try std.testing.expectEqual(Index.slice_const_u8_type, try ip.get(.main, .{ .ptr_type = .{
        .child = .u8_type,
        .flags = .{ .size = .slice, .is_const = true },
    } }));
    try std.testing.expectEqual(Index.one_usize, try ip.getInt(.main, .usize_type, @as(u64, 1)));
    try std.testing.expectEqual(Index.negative_one, try ip.getInt(.main, .comptime_int_type, @as(i64, -1)));
    const arr = try ip.get(.main, .{ .array_type = .{ .len = 3, .child = .u8_type } });
    try std.testing.expectEqual(arr, try ip.get(.main, .{ .array_type = .{ .len = 3, .child = .u8_type } }));
    try std.testing.expect(arr != try ip.get(.main, .{ .array_type = .{ .len = 4, .child = .u8_type } }));
    try std.testing.expectEqual(Index.type_type, ip.typeOf(arr));
}

test "floats are interned by their exact bits" {
    var ip: InternPool = try .init(std.testing.allocator, std.testing.io, 1);
    defer ip.deinit();
    const pz = try ip.getFloat(.main, .f64_type, @as(f64, 0.0));
    const nz = try ip.getFloat(.main, .f64_type, @as(f64, -0.0));
    try std.testing.expect(pz != nz);
    try std.testing.expect(ip.stableHash(pz) != ip.stableHash(nz));
    try std.testing.expectEqual(pz, try ip.getFloat(.main, .f64_type, @as(f32, 0.0)));
    const nan = try ip.getFloat(.main, .f32_type, std.math.nan(f32));
    try std.testing.expectEqual(nan, try ip.getFloat(.main, .f32_type, std.math.nan(f64)));
    // The same number in another type is another value.
    try std.testing.expect(pz != try ip.getFloat(.main, .comptime_float_type, @as(f64, 0.0)));
    inline for (.{ .{ Index.f16_type, f16 }, .{ Index.f80_type, f80 }, .{ Index.f128_type, f128 } }) |p| {
        const v = try ip.getFloat(.main, p[0], @as(p[1], -1.5));
        try std.testing.expectEqual(@as(f128, -1.5), ip.indexToKey(v).float.toF128());
        try std.testing.expectEqual(p[0], ip.typeOf(v));
    }
    const third: f80 = 1.0 / 3.0;
    const v80 = try ip.getFloat(.main, .f80_type, third);
    try std.testing.expectEqual(@as(u80, @bitCast(third)), @as(u80, @truncate(ip.indexToKey(v80).float.bits())));
}

test "stable hashes do not depend on interning order or thread" {
    const gpa = std.testing.allocator;
    var a: InternPool = try .init(gpa, std.testing.io, 1);
    defer a.deinit();
    var b: InternPool = try .init(gpa, std.testing.io, 4);
    defer b.deinit();
    // Intern unrelated items first in one pool so indices differ.
    _ = try b.get(.main, .{ .array_type = .{ .len = 99, .child = .i64_type } });
    _ = try b.get(@fromBackingInt(2), .{ .opt_type = .u16_type });

    const pa = try a.get(.main, .{ .ptr_type = .{ .child = .u32_type, .flags = .{ .size = .many } } });
    const xa = try a.get(.main, .{ .array_type = .{ .len = 2, .child = pa } });
    const pb = try b.get(@fromBackingInt(3), .{ .ptr_type = .{ .child = .u32_type, .flags = .{ .size = .many } } });
    const xb = try b.get(@fromBackingInt(1), .{ .array_type = .{ .len = 2, .child = pb } });
    try std.testing.expect(@backingInt(xa) != @backingInt(xb));
    try std.testing.expectEqual(a.stableHash(xa), b.stableHash(xb));
    // Readers on any thread see the item interned by another.
    try std.testing.expectEqual(pb, b.indexToKey(xb).array_type.child);
    try std.testing.expectEqual(xb, try b.get(.main, .{ .array_type = .{ .len = 2, .child = pb } }));
}
