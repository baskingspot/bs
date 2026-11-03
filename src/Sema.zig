//! Semantic analysis: ZIR to InternPool types and values, and to typed IR
//! for runtime function bodies.
//!
//! One `Sema` analyzes one analysis unit (see docs/architecture.md): a
//! declaration's value, a struct's layout, a `comptime` declaration, or a
//! runtime function body. Everything a unit reads from another unit goes
//! through `declareDependency`. Comptime code is evaluated by walking ZIR;
//! every comptime call goes through `callComptime`, which memoizes by the
//! callee and the stable hashes of its arguments. Comptime-mutable memory
//! lives in `comptime_allocs` and is only touched by the functions in the
//! "Comptime memory" section.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Ast = std.zig.Ast;
const Zir = std.zig.Zir;
const BigInt = std.math.big.int.Managed;
const BigIntConst = std.math.big.int.Const;

const InternPool = @import("InternPool.zig");
const Index = InternPool.Index;
const Ir = @import("Ir.zig");
const Ref = Ir.Inst.Ref;
const Type = @import("Type.zig");
const Zcu = @import("Zcu.zig");
const print = @import("Ir/print.zig");

const Sema = @This();

zcu: *Zcu,
ip: *InternPool,
gpa: Allocator,
/// Freed when the unit's analysis ends.
arena: Allocator,
file: u32,
code: *const Zir,
owner: Zcu.AnalUnit,
/// The declaration whose value is being analyzed, for `nav_val` units.
owner_nav: InternPool.NavIndex = .none,
/// The runtime function whose body is being analyzed, or `.none`.
func: Index = .none,
/// Return type of the function whose body (runtime, or comptime-inlined)
/// is being analyzed.
fn_ret_ty: Index = .none,
ir_insts: std.MultiArrayList(Ir.Inst) = .empty,
ir_extra: std.ArrayList(u32) = .empty,
inst_map: std.AutoHashMapUnmanaged(Zir.Inst.Index, Ref) = .empty,
deps: std.ArrayList(Zcu.Dependee) = .empty,
comptime_break_inst: Zir.Inst.Index = undefined,
comptime_allocs: std.AutoHashMapUnmanaged(u32, ComptimeAlloc) = .empty,
/// Parameters collected by `param` instructions for the next `func`
/// instruction (a function prototype or function type). Arena-allocated.
params: std.ArrayList(Block.Param) = .empty,
inferred_allocs: std.AutoHashMapUnmanaged(Ir.Inst.Index, InferredAlloc) = .empty,
/// For each runtime bool vector being initialized through a result pointer,
/// the `[N]bool` local its elements are stored to first: bit-packed
/// elements have no addresses. Arena-allocated.
bool_vector_inits: std.AutoHashMapUnmanaged(Ref, Ref) = .empty,
/// Whether a peer of the current `resolvePeerTypes` is comptime-known.
peers_comptime_known: bool = false,
branch_quota: u32 = 1000,
branch_count: u32 = 0,
last_dbg_stmt: ?Ir.Inst.Index = null,
/// Nesting of runtime inline calls, to fail on unbounded inline recursion.
inline_depth: u32 = 0,
/// Anonymous types this unit has created so far, for their stable keys.
anon_types: u32 = 0,

pub const CompileError = error{
    /// A compile error was reported to the Zcu.
    AnalysisFail,
    OutOfMemory,
    /// A unit depends on itself through the units it is resolving.
    DependencyLoop,
    /// Comptime control flow: `sema.comptime_break_inst` breaks out to an
    /// enclosing body.
    ComptimeBreak,
    /// Comptime control flow: a comptime call returned.
    ComptimeReturn,
};

const ComptimeAlloc = struct {
    ty: Index,
    val: Index,
    is_const: bool,
};

const InferredAlloc = struct {
    stores: std.ArrayList(Ir.Inst.Index) = .empty,
    is_const: bool,
    /// Requested alignment, or 0.
    alignment: u64 = 0,
};

pub const Block = struct {
    parent: ?*Block,
    sema: *Sema,
    namespace: u32,
    instructions: std.ArrayList(Ir.Inst.Index) = .empty,
    is_comptime: bool,
    label: ?*Label = null,
    inlining: ?*Inlining = null,
    /// Absolute AST node that ZIR source offsets in this body are relative to.
    src_base: Ast.Node.Index,
    want_safety: bool = true,
    /// The innermost runtime `loop` this block is inside of.
    loop: ?Ir.Inst.Index = null,

    pub const Label = struct {
        zir_block: Zir.Inst.Index,
        merges: Merges,
    };

    pub const Merges = struct {
        block_inst: Ir.Inst.Index,
        results: std.ArrayList(Ref) = .empty,
        brs: std.ArrayList(Ir.Inst.Index) = .empty,
    };

    /// A comptime call, or a runtime inline call, being evaluated.
    pub const Inlining = struct {
        func: Index,
        ret_ty: Index,
        result: Ref = .none,
        /// Comptime arguments (`none` for runtime ones), for naming types
        /// the call returns.
        args: []const Index,
        /// Anonymous types created by this call so far.
        anon_types: u32 = 0,
        /// A runtime call of an inline function: returns break to this
        /// block. Null for comptime calls.
        merges: ?*Merges = null,
    };

    pub const Param = struct {
        ty: Index,
        is_comptime: bool,
        name: Zir.NullTerminatedString,
    };

    fn child(b: *Block) Block {
        return .{
            .parent = b,
            .sema = b.sema,
            .namespace = b.namespace,
            .is_comptime = b.is_comptime,
            .label = null,
            .inlining = b.inlining,
            .src_base = b.src_base,
            .want_safety = b.want_safety,
            .loop = b.loop,
        };
    }

    pub fn nodeSrc(b: *const Block, offset: Ast.Node.Offset) Src {
        return .{ .base = b.src_base, .loc = .{ .node = offset } };
    }

    pub fn tokSrc(b: *const Block, offset: Ast.TokenOffset) Src {
        return .{ .base = b.src_base, .loc = .{ .token = offset } };
    }
};

/// A source location relative to a declaration's AST node.
pub const Src = struct {
    base: Ast.Node.Index,
    loc: union(enum) {
        node: Ast.Node.Offset,
        token: Ast.TokenOffset,
        node_abs: Ast.Node.Index,
        /// The initializer of the variable declaration `base`, or `base` if it has none.
        var_init,
    },

    fn span(src: Src, tree: *const Ast) Ast.Span {
        return switch (src.loc) {
            .node => |off| tree.nodeToSpan(off.toAbsolute(src.base)),
            .node_abs => |n| tree.nodeToSpan(n),
            .token => |off| tree.tokenToSpan(off.toAbsolute(tree.firstToken(src.base))),
            .var_init => tree.nodeToSpan(if (tree.fullVarDecl(src.base)) |vd| vd.ast.init_node.unwrap() orelse src.base else src.base),
        };
    }
};

// ---------------------------------------------------------------------------
// Entry points (one per kind of analysis unit)

fn create(zcu: *Zcu, arena: Allocator, file: u32, owner: Zcu.AnalUnit) Sema {
    return .{
        .zcu = zcu,
        .ip = &zcu.ip,
        .gpa = zcu.gpa,
        .arena = arena,
        .file = file,
        .code = &zcu.file(file).zir,
        .owner = owner,
    };
}

fn destroy(sema: *Sema) void {
    const gpa = sema.gpa;
    sema.ir_insts.deinit(gpa);
    sema.ir_extra.deinit(gpa);
    sema.inst_map.deinit(gpa);
    sema.deps.deinit(gpa);
    sema.comptime_allocs.deinit(gpa);
    var it = sema.inferred_allocs.valueIterator();
    while (it.next()) |ia| ia.stores.deinit(gpa);
    sema.inferred_allocs.deinit(gpa);
}

fn finish(sema: *Sema) !void {
    try sema.zcu.recordDeps(sema.owner, sema.deps.items);
}

fn rootBlock(sema: *Sema, namespace: u32, src_base: Ast.Node.Index, is_comptime: bool) Block {
    return .{
        .parent = null,
        .sema = sema,
        .namespace = namespace,
        .is_comptime = is_comptime,
        .src_base = src_base,
    };
}

pub fn analyzeNavVal(zcu: *Zcu, nav_index: InternPool.NavIndex) CompileError!void {
    const nav = zcu.ip.getNav(nav_index);
    var arena_state: std.heap.ArenaAllocator = .init(zcu.gpa);
    defer arena_state.deinit();
    var sema = create(zcu, arena_state.allocator(), nav.file, .{ .nav_val = nav_index });
    defer sema.destroy();
    sema.owner_nav = nav_index;
    const decl = sema.code.getDeclaration(nav.zir_inst);
    var block = sema.rootBlock(nav.namespace, decl.src_node, true);
    defer block.instructions.deinit(zcu.gpa);
    const src = block.nodeSrc(.zero);

    if (decl.linkage == .@"extern") return sema.fail(&block, src, "zap does not support extern declarations yet", .{});
    const decl_ty: Index = if (decl.type_body) |body| blk: {
        const ref = try sema.resolveInlineBody(&block, body, nav.zir_inst);
        break :blk try sema.analyzeAsType(&block, src, ref);
    } else .none;
    // Within the value body, the `declaration` instruction refers to the type.
    if (decl_ty != .none) try sema.inst_map.put(sema.gpa, nav.zir_inst, .fromInterned(decl_ty));
    var val_ref = try sema.resolveInlineBody(&block, decl.value_body.?, nav.zir_inst);
    if (decl_ty != .none) {
        val_ref = try sema.coerce(&block, decl_ty, val_ref, .{ .base = decl.src_node, .loc = .var_init });
    }
    const val = try sema.resolveConstValue(&block, src, val_ref, "global variable initializer must be comptime-known");
    nav.val = val;
    nav.ty = sema.ip.typeOf(val);
    try sema.finish();
}

/// Sets `builtin.test_functions` to the collected tests, if the test runner
/// referenced it. Runs after analysis, like upstream's
/// `populateTestFunctions`, so every test is known.
pub fn populateTestFunctions(zcu: *Zcu) CompileError!void {
    const ip = &zcu.ip;
    const builtin_file = zcu.moduleRootFile(.builtin) orelse return;
    if (zcu.file_root_types.items[builtin_file] == .none) return;
    const ns = zcu.namespacePtr(ip.structInfo(zcu.file_root_types.items[builtin_file]).namespace);
    const nav_index = ns.decls.get(try ip.getString(Zcu.tid, "test_functions")) orelse return;
    const nav = ip.getNav(nav_index);
    if (nav.status != .resolved) return;
    var arena_state: std.heap.ArenaAllocator = .init(zcu.gpa);
    defer arena_state.deinit();
    var sema = create(zcu, arena_state.allocator(), nav.file, .{ .nav_val = nav_index });
    defer sema.destroy();
    const test_fn_ty = Type.ptrInfo(ip, nav.ty).child;
    const info = ip.structInfo(test_fn_ty);
    const func_ptr_ty = info.field_types[info.fieldIndex(ip, "func").?];
    const elems = try sema.arena.alloc(Index, zcu.test_functions.items.len);
    for (elems, zcu.test_functions.items) |*e, test_nav| {
        const t = ip.getNav(test_nav);
        if (t.status != .resolved) return;
        const name = ip.stringSlice(t.fqn);
        const name_ptr = try sema.stringLiteral(name);
        const many = try sema.intern(.{ .ptr = .{ .ty = .manyptr_const_u8_type, .base = ip.indexToKey(name_ptr).ptr.base } });
        const name_val = try sema.intern(.{ .slice = .{ .ty = .slice_const_u8_type, .ptr = many, .len = try sema.intValue(.usize_type, name.len) } });
        const func_val = try sema.intern(.{ .ptr = .{ .ty = func_ptr_ty, .base = .{ .nav = test_nav } } });
        const fields = try sema.arena.alloc(Index, 2);
        fields[info.fieldIndex(ip, "name").?] = name_val;
        fields[info.fieldIndex(ip, "func").?] = func_val;
        e.* = try sema.intern(.{ .aggregate = .{ .ty = test_fn_ty, .storage = .{ .elems = fields } } });
    }
    nav.val = try sema.sliceValue(test_fn_ty, elems);
}

pub fn analyzeComptimeDecl(zcu: *Zcu, c: Zcu.ComptimeDecl) CompileError!void {
    var arena_state: std.heap.ArenaAllocator = .init(zcu.gpa);
    defer arena_state.deinit();
    var sema = create(zcu, arena_state.allocator(), c.file, .{ .comptime_decl = c });
    defer sema.destroy();
    const decl = sema.code.getDeclaration(c.inst);
    var block = sema.rootBlock(c.namespace, decl.src_node, true);
    defer block.instructions.deinit(zcu.gpa);
    _ = try sema.resolveInlineBody(&block, decl.value_body.?, c.inst);
    try sema.finish();
}

pub fn analyzeStructLayout(zcu: *Zcu, ty: Index) CompileError!void {
    const ip = &zcu.ip;
    const key = ip.containerType(ty).?;
    const info = ip.structInfo(ty);
    var arena_state: std.heap.ArenaAllocator = .init(zcu.gpa);
    defer arena_state.deinit();
    var sema = create(zcu, arena_state.allocator(), key.file, .{ .type_layout = ty });
    defer sema.destroy();
    switch (ip.indexToKey(ty)) {
        .struct_type => {},
        .enum_type => return sema.analyzeEnumLayout(key, info),
        .union_type => return sema.analyzeUnionLayout(key, info),
        else => unreachable,
    }
    if (reifyNode(sema.code, key.zir_inst)) |node| return sema.analyzeReifiedStructLayout(key, info, node);
    const decl = sema.code.getStructDecl(key.zir_inst);
    var block = sema.rootBlock(info.namespace, decl.fields_baseline_src_node, true);
    defer block.instructions.deinit(zcu.gpa);

    info.status = .field_types_wip;
    const n = decl.field_names.len;
    const names = try ip.arena(Zcu.tid).alloc(InternPool.String, n);
    const types = try ip.arena(Zcu.tid).alloc(Index, n);
    const defaults = try ip.arena(Zcu.tid).alloc(Index, n);
    const offsets = try ip.arena(Zcu.tid).alloc(u64, n);
    const aligns = try sema.arena.alloc(u64, n);
    @memset(aligns, 0);
    var it = decl.iterateFields();
    while (it.next()) |field| {
        const i = field.idx;
        names[i] = try ip.getString(Zcu.tid, sema.code.nullTerminatedString(field.name));
        if (field.is_comptime) return sema.fail(&block, block.nodeSrc(.zero), "zap does not support comptime fields yet", .{});
        if (field.align_body) |body| {
            if (decl.layout == .@"packed") return sema.fail(&block, block.nodeSrc(.zero), "unable to override alignment of packed struct fields", .{});
            const a_ref = try sema.coerce(&block, .u32_type, try sema.resolveInlineBody(&block, body, key.zir_inst), block.nodeSrc(.zero));
            const a = ip.intValue(u64, try sema.resolveConstValue(&block, block.nodeSrc(.zero), a_ref, "struct field alignment must be comptime-known")).?;
            if (a == 0 or !std.math.isPowerOfTwo(a)) return sema.fail(&block, block.nodeSrc(.zero), "alignment value '{d}' is not a power of two", .{a});
            aligns[i] = a;
        }
        const ty_ref = try sema.resolveInlineBody(&block, field.type_body, key.zir_inst);
        types[i] = try sema.analyzeAsType(&block, block.nodeSrc(.zero), ty_ref);
        defaults[i] = .none;
    }
    info.field_names = names;
    info.field_types = types;
    info.status = .have_field_types;


    const explicit_backing: Index = if (decl.backing_int_type_body) |body|
        try sema.analyzeAsType(&block, block.nodeSrc(.zero), try sema.resolveInlineBody(&block, body, key.zir_inst))
    else
        .none;
    try sema.structLayout(&block, info, decl.layout, explicit_backing, offsets, aligns);

    // Defaults may refer to the struct itself (for example its size), so
    // they are evaluated after the layout. Until then every field reads as
    // having no default.
    info.field_defaults = defaults;
    it = decl.iterateFields();
    while (it.next()) |field| {
        const body = field.default_body orelse continue;
        // Within the default body, the struct instruction stands for the
        // field type (the result type of the default value).
        try sema.inst_map.put(sema.gpa, key.zir_inst, .fromInterned(types[field.idx]));
        const ref = try sema.resolveInlineBody(&block, body, key.zir_inst);
        const coerced = try sema.coerce(&block, types[field.idx], ref, block.nodeSrc(.zero));
        defaults[field.idx] = try sema.resolveConstValue(&block, block.nodeSrc(.zero), coerced, "struct field default value must be comptime-known");
    }
    info.field_defaults = defaults;
    try sema.finish();
}

/// The node of a `@Struct`, `@Union`, or `@Enum` instruction, or null if
/// `inst` declares a container in source.
fn reifyNode(code: *const Zir, inst: Zir.Inst.Index) ?Ast.Node.Index {
    if (code.instructions.items(.tag)[@backingInt(inst)] != .extended) return null;
    const ext = code.instructions.items(.data)[@backingInt(inst)].extended;
    return switch (ext.opcode) {
        .reify_struct => code.extraData(Zir.Inst.ReifyStruct, ext.operand).data.node,
        .reify_union => code.extraData(Zir.Inst.ReifyUnion, ext.operand).data.node,
        .reify_enum => code.extraData(Zir.Inst.ReifyEnum, ext.operand).data.node,
        else => null,
    };
}

/// A `@Struct` type's fields were set when it was created; its captures
/// are the layout and the backing integer.
fn analyzeReifiedStructLayout(sema: *Sema, key: InternPool.ContainerType, info: *InternPool.ContainerInfo, node: Ast.Node.Index) CompileError!void {
    const ip = sema.ip;
    var block = sema.rootBlock(info.namespace, node, true);
    defer block.instructions.deinit(sema.gpa);
    const layout = std.meta.stringToEnum(std.lang.Type.ContainerLayout, sema.enumTagName(key.captures[0]).?).?;
    const backing = ip.indexToKey(key.captures[1]).opt.val;
    const offsets = try ip.arena(Zcu.tid).alloc(u64, info.field_types.len);
    try sema.structLayout(&block, info, layout, backing, offsets, &.{});
    try sema.finish();
}

/// Computes the layout of a struct whose field types are known. `aligns`
/// holds explicit field alignments (0 for none), or is empty.
fn structLayout(sema: *Sema, block: *Block, info: *InternPool.ContainerInfo, layout: std.lang.Type.ContainerLayout, explicit_backing: Index, offsets: []u64, aligns: []const u64) CompileError!void {
    const ip = sema.ip;
    const types = info.field_types;
    info.status = .layout_wip;
    if (layout == .@"packed") {
        // Fields are packed into the backing integer from bit 0.
        const src = block.nodeSrc(.zero);
        var bits: u64 = 0;
        for (types, 0..) |ft, i| {
            try sema.resolveLayout(block, src, ft);
            const fb = Type.packedBits(ip, ft) orelse {
                if (Type.class(ip, ft) == .pointer) return sema.failUnsupported(block, src, "pointer fields in packed structs");
                return sema.fail(block, src, "packed structs cannot contain fields of type '{f}'", .{sema.fmtType(ft)});
            };
            offsets[i] = bits;
            bits += fb;
        }
        const backing: Index = if (explicit_backing != .none) blk: {
            const t = explicit_backing;
            if (Type.class(ip, t) != .int) return sema.fail(block, src, "expected backing integer type, found '{f}'", .{sema.fmtType(t)});
            if (Type.intInfo(ip, t).bits != bits) return sema.fail(block, src, "backing integer type '{f}' has bit size {d} but the struct fields have a total bit size of {d}", .{ sema.fmtType(t), Type.intInfo(ip, t).bits, bits });
            break :blk t;
        } else blk: {
            if (bits > std.math.maxInt(u16)) return sema.fail(block, src, "size of packed struct '{d}' exceeds maximum bit width of 65535", .{bits});
            break :blk try sema.intType(.unsigned, @intCast(bits));
        };
        info.field_offsets = offsets;
        info.tag_type = backing;
        info.size = Type.abiSize(ip, backing);
        info.alignment = Type.abiAlignment(ip, backing);
    } else {
        var offset: u64 = 0;
        var alignment: u64 = 1;
        for (types, 0..) |ft, i| {
            try sema.resolveLayout(block, block.nodeSrc(.zero), ft);
            if (!Type.hasRuntimeBits(ip, ft)) {
                offsets[i] = offset;
                continue;
            }
            // An explicit alignment can raise or lower the natural one.
            const a = if (aligns.len != 0 and aligns[i] != 0) aligns[i] else Type.abiAlignment(ip, ft);
            offset = std.mem.alignForward(u64, offset, a);
            offsets[i] = offset;
            offset += Type.abiSize(ip, ft);
            alignment = @max(alignment, a);
        }
        info.field_offsets = offsets;
        info.size = std.mem.alignForward(u64, offset, alignment);
        info.alignment = alignment;
    }
    info.status = .have_layout;
}

fn analyzeEnumLayout(sema: *Sema, key: InternPool.ContainerType, info: *InternPool.ContainerInfo) CompileError!void {
    const ip = sema.ip;
    const decl = sema.code.getEnumDecl(key.zir_inst);
    var block = sema.rootBlock(info.namespace, decl.fields_baseline_src_node, true);
    defer block.instructions.deinit(sema.gpa);
    const src = block.nodeSrc(.zero);
    info.status = .field_types_wip;
    const tag_ty: Index = if (decl.tag_type_body) |body| blk: {
        const t = try sema.analyzeAsType(&block, src, try sema.resolveInlineBody(&block, body, key.zir_inst));
        if (Type.class(ip, t) != .int) return sema.fail(&block, src, "expected integer tag type, found '{f}'", .{sema.fmtType(t)});
        break :blk t;
    } else blk: {
        if (decl.nonexhaustive) return sema.fail(&block, src, "non-exhaustive enum missing integer tag type", .{});
        const n = decl.field_names.len;
        break :blk try sema.intType(.unsigned, if (n == 0) 0 else std.math.log2_int_ceil(usize, n));
    };
    const n = decl.field_names.len;
    const names = try ip.arena(Zcu.tid).alloc(InternPool.String, n);
    const values = try ip.arena(Zcu.tid).alloc(Index, n);
    var next: ?Index = try sema.intValue(tag_ty, 0);
    var it = decl.iterateFields();
    while (it.next()) |field| {
        const i = field.idx;
        names[i] = try ip.getString(Zcu.tid, sema.code.nullTerminatedString(field.name));
        const val = if (field.value_body) |body| blk: {
            if (decl.tag_type_body == null) return sema.fail(&block, src, "explicitly valued enum requires an integer tag type", .{});
            try sema.inst_map.put(sema.gpa, key.zir_inst, .fromInterned(tag_ty));
            const ref = try sema.coerce(&block, tag_ty, try sema.resolveInlineBody(&block, body, key.zir_inst), src);
            break :blk try sema.resolveConstValue(&block, src, ref, "enum tag value must be comptime-known");
        } else next orelse return sema.fail(&block, src, "enumeration value '{f}' too large for type '{f}'", .{ sema.fmtValue(values[i - 1]), sema.fmtType(tag_ty) });
        for (values[0..i], 0..) |v, j| {
            if (v == val) return sema.fail(&block, src, "enum tag value {f} already taken by field '{s}'", .{ sema.fmtValue(val), ip.stringSlice(names[j]) });
        }
        values[i] = val;
        const one = try sema.intValue(tag_ty, 1);
        var big = try sema.bigValue(val);
        try big.add(&big, &(try sema.bigValue(one)));
        next = if (big.toConst().fitsInTwosComp(Type.intInfo(ip, tag_ty).signedness, Type.intInfo(ip, tag_ty).bits)) try sema.bigToValue(tag_ty, big.toConst()) else null;
    }
    info.field_names = names;
    info.field_defaults = values;
    info.tag_type = tag_ty;
    info.nonexhaustive = decl.nonexhaustive;
    info.size = Type.abiSize(ip, tag_ty);
    info.alignment = Type.abiAlignment(ip, tag_ty);
    info.status = .have_layout;
    try sema.finish();
}

fn analyzeUnionLayout(sema: *Sema, key: InternPool.ContainerType, info: *InternPool.ContainerInfo) CompileError!void {
    const ip = sema.ip;
    // A `@Union` type's fields were set when it was created; its captures
    // are the layout and the tag type.
    const reify_node = reifyNode(sema.code, key.zir_inst);
    const decl = if (reify_node == null) sema.code.getUnionDecl(key.zir_inst) else undefined;
    var block = sema.rootBlock(info.namespace, reify_node orelse decl.fields_baseline_src_node, true);
    defer block.instructions.deinit(sema.gpa);
    const src = block.nodeSrc(.zero);
    var kind: Zir.Inst.UnionDecl.Kind = undefined;
    var arg_ty: Index = .none;
    if (reify_node != null) {
        arg_ty = ip.indexToKey(key.captures[1]).opt.val;
        const layout = std.meta.stringToEnum(std.lang.Type.ContainerLayout, sema.enumTagName(key.captures[0]).?).?;
        kind = switch (layout) {
            .auto => if (arg_ty != .none) .tagged_explicit else .auto,
            .@"extern" => .@"extern",
            .@"packed" => .@"packed",
        };
    } else kind = decl.kind;
    info.status = .field_types_wip;
    if (reify_node == null) {
        const n = decl.field_names.len;
        const names = try ip.arena(Zcu.tid).alloc(InternPool.String, n);
        const types = try ip.arena(Zcu.tid).alloc(Index, n);
        if (decl.arg_type_body) |body| arg_ty = try sema.analyzeAsType(&block, src, try sema.resolveInlineBody(&block, body, key.zir_inst));
        var it = decl.iterateFields();
        while (it.next()) |field| {
            const i = field.idx;
            names[i] = try ip.getString(Zcu.tid, sema.code.nullTerminatedString(field.name));
            if (field.align_body != null) return sema.failUnsupported(&block, src, "union field alignment");
            types[i] = if (field.type_body) |body|
                try sema.analyzeAsType(&block, src, try sema.resolveInlineBody(&block, body, key.zir_inst))
            else
                .void_type;
        }
        info.field_names = names;
        info.field_types = types;
    }
    const names = info.field_names;
    const types = info.field_types;
    const n = names.len;

    // The tag: a declared enum, a generated one, or (untagged auto-layout
    // unions in Debug) a hidden integer safety tag.
    switch (kind) {
        .tagged_explicit => {
            if (ip.indexToKey(arg_ty) != .enum_type) return sema.fail(&block, src, "expected enum tag type, found '{f}'", .{sema.fmtType(arg_ty)});
            try sema.resolveLayout(&block, src, arg_ty);
            const tag_info = ip.structInfo(arg_ty);
            if (tag_info.field_names.len != n) return sema.fail(&block, src, "union fields do not match tag type '{f}'", .{sema.fmtType(arg_ty)});
            for (names) |name| {
                if (tag_info.fieldIndex(ip, ip.stringSlice(name)) == null) return sema.fail(&block, src, "no field named '{s}' in enum '{f}'", .{ ip.stringSlice(name), sema.fmtType(arg_ty) });
            }
            info.tag_type = arg_ty;
        },
        .tagged_enum, .tagged_enum_explicit => {
            const int_ty = if (arg_ty != .none) arg_ty else try sema.intType(.unsigned, if (n == 0) 0 else std.math.log2_int_ceil(usize, n));
            const values = try ip.arena(Zcu.tid).alloc(Index, n);
            var next: u64 = 0;
            var it = decl.iterateFields();
            while (it.next()) |field| {
                if (field.value_body) |body| {
                    try sema.inst_map.put(sema.gpa, key.zir_inst, .fromInterned(int_ty));
                    const ref = try sema.coerce(&block, int_ty, try sema.resolveInlineBody(&block, body, key.zir_inst), src);
                    values[field.idx] = try sema.resolveConstValue(&block, src, ref, "enum tag value must be comptime-known");
                    next = (ip.intValue(u64, values[field.idx]) orelse 0) + 1;
                } else {
                    values[field.idx] = try sema.intValue(int_ty, next);
                    next += 1;
                }
            }
            const tag_name = try std.fmt.allocPrint(sema.arena, "@typeInfo({s}).@\"union\".tag_type.?", .{ip.stringSlice(key.name)});
            const tag_key = try std.fmt.allocPrint(sema.arena, "{s}@tag", .{ip.stringSlice(key.key)});
            const tag_info = try ip.createContainerInfo(Zcu.tid, .{
                .namespace = info.namespace,
                .layout = .auto,
                .status = .have_layout,
                .field_names = names,
                .field_defaults = values,
                .tag_type = int_ty,
                .size = Type.abiSize(ip, int_ty),
                .alignment = Type.abiAlignment(ip, int_ty),
            });
            info.tag_type = try sema.intern(.{ .enum_type = .{
                .file = key.file,
                .zir_inst = key.zir_inst,
                .captures = key.captures,
                .name = try sema.getString(tag_name),
                .key = try sema.getString(tag_key),
                .info = tag_info,
            } });
        },
        .auto => info.tag_type = try sema.intType(.unsigned, if (n == 0) 0 else std.math.log2_int_ceil(usize, n)),
        .@"extern" => {},
        .@"packed", .packed_explicit => {
            // Every field has the backing integer's bit width.
            info.status = .layout_wip;
            if (n == 0) return sema.fail(&block, src, "packed union has no fields", .{});
            for (types) |ft| try sema.resolveLayout(&block, src, ft);
            const field_bits = try sema.arena.alloc(u16, n);
            for (types, field_bits) |ft, *b| b.* = Type.packedBits(ip, ft) orelse {
                if (Type.class(ip, ft) == .pointer) return sema.failUnsupported(&block, src, "pointer fields in packed unions");
                return sema.fail(&block, src, "packed unions cannot contain fields of type '{f}'", .{sema.fmtType(ft)});
            };
            const backing = if (arg_ty != .none) blk: {
                if (Type.class(ip, arg_ty) != .int) return sema.fail(&block, src, "expected backing integer type, found '{f}'", .{sema.fmtType(arg_ty)});
                for (field_bits) |b| if (b != Type.intInfo(ip, arg_ty).bits) return sema.fail(&block, src, "field bit width does not match backing integer", .{});
                break :blk arg_ty;
            } else blk: {
                for (field_bits[1..]) |b| if (b != field_bits[0]) return sema.fail(&block, src, "field bit width does not match earlier field", .{});
                break :blk try sema.intType(.unsigned, field_bits[0]);
            };
            info.tag_type = backing;
            info.size = Type.abiSize(ip, backing);
            info.alignment = Type.abiAlignment(ip, backing);
            info.status = .have_layout;
            return sema.finish();
        },
    }
    info.has_runtime_tag = info.tag_type != .none and Type.hasRuntimeBits(ip, info.tag_type);
    info.status = .have_field_types;

    info.status = .layout_wip;
    var payload_size: u64 = 0;
    var payload_align: u64 = 1;
    for (types) |ft| {
        try sema.resolveLayout(&block, src, ft);
        if (Type.class(ip, ft) == .noreturn) continue;
        if (Type.hasRuntimeBits(ip, ft)) payload_size = @max(payload_size, Type.abiSize(ip, ft));
        payload_align = @max(payload_align, Type.abiAlignment(ip, ft));
    }
    var size = payload_size;
    var alignment = payload_align;
    if (info.has_runtime_tag) {
        size += Type.abiSize(ip, info.tag_type);
        alignment = @max(alignment, Type.abiAlignment(ip, info.tag_type));
    }
    info.size = std.mem.alignForward(u64, size, alignment);
    info.alignment = alignment;
    info.status = .have_layout;
    try sema.finish();
}

pub fn analyzeFuncBody(zcu: *Zcu, func_index: Index) CompileError!Ir {
    const ip = &zcu.ip;
    const func = ip.indexToKey(func_index).func;
    const nav = ip.getNav(func.owner_nav);
    const fn_ty = ip.indexToKey(func.ty).func_type;
    var arena_state: std.heap.ArenaAllocator = .init(zcu.gpa);
    defer arena_state.deinit();
    var sema = create(zcu, arena_state.allocator(), nav.file, .{ .func = func_index });
    defer sema.destroy();
    sema.func = func_index;
    sema.fn_ret_ty = fn_ty.return_type;
    if (ip.indexToKey(fn_ty.return_type) == .error_union_type) {
        const eu = ip.indexToKey(fn_ty.return_type).error_union_type;
        if (eu.error_set_type == .adhoc_inferred_error_set_type) {
            const ies = try ip.get(Zcu.tid, .{ .inferred_error_set_type = func_index });
            sema.fn_ret_ty = try ip.get(Zcu.tid, .{ .error_union_type = .{ .error_set_type = ies, .payload_type = eu.payload_type } });
        }
    }
    const decl = sema.code.getDeclaration(nav.zir_inst);
    var block = sema.rootBlock(nav.namespace, decl.src_node, false);
    defer block.instructions.deinit(zcu.gpa);
    const gpa = zcu.gpa;
    // Upstream builds compiler_rt in a release mode: no safety checks.
    if (zcu.file(nav.file).module == .compiler_rt) block.want_safety = false;

    for (fn_ty.param_types) |pt| try sema.resolveLayout(&block, block.nodeSrc(.zero), pt);
    try sema.resolveLayout(&block, block.nodeSrc(.zero), fn_ty.return_type);

    const fn_info = sema.code.getFnInfo(func.zir_inst);
    // `comptime_args` is indexed by ZIR parameter; only runtime parameters
    // appear in the function type and become `arg` instructions.
    var zir_param_i: u32 = 0;
    var arg_i: u32 = 0;
    for (fn_info.param_body) |inst| {
        switch (sema.code.instructions.items(.tag)[@backingInt(inst)]) {
            .param, .param_comptime, .param_anytype, .param_anytype_comptime => {},
            else => continue,
        }
        const ref: Ref = if (func.comptime_args.len != 0 and func.comptime_args[zir_param_i] != .none)
            .fromInterned(func.comptime_args[zir_param_i])
        else blk: {
            defer arg_i += 1;
            break :blk try sema.addInst(&block, .{ .tag = .arg, .data = .{ .arg = .{ .ty = fn_ty.param_types[arg_i], .index = arg_i } } });
        };
        try sema.inst_map.put(gpa, inst, ref);
        zir_param_i += 1;
    }

    sema.analyzeBodyInner(&block, fn_info.body) catch |err| switch (err) {
        error.ComptimeBreak, error.ComptimeReturn => unreachable,
        else => |e| return e,
    };
    if (fn_ty.cc == .naked) {
        // A naked function falls off its end into whatever follows.
    }

    // `Func.SrcLocs` follows the body in `extra`.
    const body_end = (@intFromPtr(fn_info.body.ptr) - @intFromPtr(sema.code.extra.ptr)) / @sizeOf(u32) + fn_info.body.len;
    const src_locs = sema.code.extraData(Zir.Inst.Func.SrcLocs, body_end).data;

    const main_block: u32 = @intCast(sema.ir_extra.items.len);
    try sema.ir_extra.append(gpa, @intCast(block.instructions.items.len));
    try sema.ir_extra.appendSlice(gpa, @ptrCast(block.instructions.items));
    try sema.finish();
    var ir: Ir = .{
        .instructions = sema.ir_insts.toOwnedSlice(),
        .extra = try sema.ir_extra.toOwnedSlice(gpa),
        .func = func_index,
        .main_block = main_block,
        .rbrace_line = src_locs.rbrace_line,
        .rbrace_column = @as(u16, @truncate(src_locs.columns >> 16)),
    };
    _ = &ir;
    return ir;
}

// ---------------------------------------------------------------------------
// Diagnostics

pub fn fail(sema: *Sema, block: *const Block, src: Src, comptime fmt: []const u8, args: anytype) CompileError {
    _ = block;
    const tree = try sema.zcu.fe.tree(@fromBackingInt(sema.file));
    try sema.zcu.addError(sema.file, src.span(tree), fmt, args);
    return error.AnalysisFail;
}

const FmtType = struct {
    ip: *const InternPool,
    ty: Index,
    pub fn format(f: FmtType, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try print.printType(f.ip, f.ty, w);
    }
};

fn fmtType(sema: *Sema, ty: Index) FmtType {
    return .{ .ip = sema.ip, .ty = ty };
}

const FmtValue = struct {
    ip: *const InternPool,
    val: Index,
    pub fn format(f: FmtValue, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try print.printValue(f.ip, f.val, w);
    }
};

fn fmtValue(sema: *Sema, val: Index) FmtValue {
    return .{ .ip = sema.ip, .val = val };
}

fn failUnsupported(sema: *Sema, block: *Block, src: Src, what: []const u8) CompileError {
    return sema.fail(block, src, "zap does not support {s} yet", .{what});
}

/// Notes call site `src` on the error a failed call reported (if it reported
/// one since there were `n_errors`), and returns `err`.
fn noteCallSite(sema: *Sema, block: *Block, src: Src, n_errors: usize, err: CompileError, comptime note: []const u8) CompileError {
    _ = block;
    if (err == error.AnalysisFail and sema.zcu.errors.items.len > n_errors) {
        const tree = try sema.zcu.fe.tree(@fromBackingInt(sema.file));
        try sema.zcu.addNote(sema.file, src.span(tree), note, .{});
    }
    return err;
}

/// Converts a dependency loop reported by the Zcu into a compile error here.
fn depLoop(sema: *Sema, block: *Block, src: Src, err: CompileError) CompileError {
    return switch (err) {
        error.DependencyLoop => sema.fail(block, src, "dependency loop detected", .{}),
        else => err,
    };
}

// ---------------------------------------------------------------------------
// Dependencies

/// The one place a unit records what it read from another unit.
pub fn declareDependency(sema: *Sema, dependee: Zcu.Dependee) !void {
    for (sema.deps.items) |d| {
        if (std.meta.eql(d, dependee)) return;
    }
    try sema.deps.append(sema.gpa, dependee);
}

fn ensureNavVal(sema: *Sema, block: *Block, src: Src, nav: InternPool.NavIndex) CompileError!void {
    try sema.declareDependency(.{ .nav_val = nav });
    sema.zcu.ensureNavVal(nav) catch |err| return sema.depLoop(block, src, err);
}

/// Resolves the layout of `ty` and every type it contains by value.
fn resolveLayout(sema: *Sema, block: *Block, src: Src, ty: Index) CompileError!void {
    const ip = sema.ip;
    switch (ip.indexToKey(ty)) {
        .struct_type, .enum_type, .union_type => {
            try sema.declareDependency(.{ .type_layout = ty });
            sema.zcu.ensureStructLayout(ty) catch |err| return sema.depLoop(block, src, err);
        },
        .array_type => |a| try sema.resolveLayout(block, src, a.child),
        .opt_type => |c| try sema.resolveLayout(block, src, c),
        .error_union_type => |e| try sema.resolveLayout(block, src, e.payload_type),
        .tuple_type => |t| for (t.types) |ft| try sema.resolveLayout(block, src, ft),
        else => {},
    }
}

/// Whether the layout of `ty` (and of the types it contains) is resolved.
fn layoutResolved(sema: *Sema, ty: Index) bool {
    const ip = sema.ip;
    return switch (ip.indexToKey(ty)) {
        .struct_type, .enum_type, .union_type => ip.structInfo(ty).status == .have_layout,
        .array_type => |a| sema.layoutResolved(a.child),
        .opt_type => |c| sema.layoutResolved(c),
        .error_union_type => |e| sema.layoutResolved(e.payload_type),
        .tuple_type => |t| for (t.types) |ft| {
            if (!sema.layoutResolved(ft)) break false;
        } else true,
        else => true,
    };
}

/// Resolves the layout of a comptime value's type, which CodeGen needs if
/// the value reaches runtime code, unless a layout it depends on is being
/// resolved right now (a type referring to itself).
fn resolveLayoutIfIdle(sema: *Sema, block: *Block, src: Src, ty: Index) CompileError!void {
    const ip = sema.ip;
    switch (ip.indexToKey(ty)) {
        .struct_type, .enum_type, .union_type => switch (ip.structInfo(ty).status) {
            .field_types_wip, .layout_wip => {},
            else => try sema.resolveLayout(block, src, ty),
        },
        .array_type => |a| try sema.resolveLayoutIfIdle(block, src, a.child),
        .opt_type => |c| try sema.resolveLayoutIfIdle(block, src, c),
        .error_union_type => |e| try sema.resolveLayoutIfIdle(block, src, e.payload_type),
        .tuple_type => |t| for (t.types) |ft| try sema.resolveLayoutIfIdle(block, src, ft),
        else => {},
    }
}

/// Resolves the field types (not necessarily the layout) of a struct.
fn resolveStructFields(sema: *Sema, block: *Block, src: Src, ty: Index) CompileError!void {
    const info = sema.ip.structInfo(ty);
    if (info.status == .layout_wip or info.status == .have_field_types) return;
    try sema.resolveLayout(block, src, ty);
}

// ---------------------------------------------------------------------------
// IR construction

fn addInst(sema: *Sema, block: *Block, inst: Ir.Inst) !Ref {
    // Callers should have checked with `requireRuntime` and a precise source
    // location; this is the backstop for paths that do not yet.
    if (block.is_comptime) return sema.fail(block, .{ .base = block.src_base, .loc = .{ .node = .zero } }, "unable to evaluate comptime expression", .{});
    const index: Ir.Inst.Index = @fromBackingInt(@intCast(sema.ir_insts.len));
    try sema.ir_insts.append(sema.gpa, inst);
    try block.instructions.append(sema.gpa, index);
    return index.toRef();
}

fn addExtra(sema: *Sema, value: anytype) !u32 {
    const T = @TypeOf(value);
    const start: u32 = @intCast(sema.ir_extra.items.len);
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        const field = @field(value, name);
        try sema.ir_extra.append(sema.gpa, switch (@TypeOf(field)) {
            u32 => field,
            else => @backingInt(field),
        });
    }
    return start;
}

fn addBinOp(sema: *Sema, block: *Block, tag: Ir.Inst.Tag, lhs: Ref, rhs: Ref) !Ref {
    return sema.addInst(block, .{ .tag = tag, .data = .{ .bin_op = .{ .lhs = lhs, .rhs = rhs } } });
}

fn addTyOp(sema: *Sema, block: *Block, tag: Ir.Inst.Tag, ty: Index, operand: Ref) !Ref {
    return sema.addInst(block, .{ .tag = tag, .data = .{ .ty_op = .{ .ty = ty, .operand = operand } } });
}

fn addUnOp(sema: *Sema, block: *Block, tag: Ir.Inst.Tag, operand: Ref) !Ref {
    return sema.addInst(block, .{ .tag = tag, .data = .{ .un_op = operand } });
}

fn addTyPlBin(sema: *Sema, block: *Block, tag: Ir.Inst.Tag, ty: Index, lhs: Ref, rhs: Ref) !Ref {
    const payload = try sema.addExtra(Ir.Bin{ .lhs = lhs, .rhs = rhs });
    return sema.addInst(block, .{ .tag = tag, .data = .{ .ty_pl = .{ .ty = ty, .payload = payload } } });
}

fn addStructField(sema: *Sema, block: *Block, tag: Ir.Inst.Tag, ty: Index, operand: Ref, index: u32) !Ref {
    const payload = try sema.addExtra(Ir.StructField{ .operand = operand, .index = index });
    return sema.addInst(block, .{ .tag = tag, .data = .{ .ty_pl = .{ .ty = ty, .payload = payload } } });
}

fn addPanic(sema: *Sema, block: *Block, id: Ir.PanicId, lhs: Ref, rhs: Ref) !void {
    const payload = if (lhs != .none) try sema.addExtra(Ir.Bin{ .lhs = lhs, .rhs = rhs }) else 0;
    _ = try sema.addInst(block, .{ .tag = .panic, .data = .{ .panic = .{ .id = id, .payload = payload } } });
}

/// Appends a body's length and instructions to `ir_extra`.
fn appendBody(sema: *Sema, body: []const Ir.Inst.Index) !void {
    try sema.ir_extra.appendSlice(sema.gpa, @ptrCast(body));
}

/// Emits `if (!ok) panic(id)`.
fn addSafetyCheck(sema: *Sema, block: *Block, ok: Ref, id: Ir.PanicId, lhs: Ref, rhs: Ref) !void {
    if (ok.toInterned()) |v| {
        if (v == .bool_true) return;
    }
    var fail_block = block.child();
    defer fail_block.instructions.deinit(sema.gpa);
    try sema.addPanic(&fail_block, id, lhs, rhs);
    // `block { cond_br(ok, { br }, { panic }) }`
    const block_inst: Ir.Inst.Index = @fromBackingInt(@intCast(sema.ir_insts.len));
    try sema.ir_insts.append(sema.gpa, .{ .tag = .block, .data = .{ .ty_pl = .{ .ty = .void_type, .payload = undefined } } });
    var ok_block = block.child();
    defer ok_block.instructions.deinit(sema.gpa);
    _ = try sema.addInst(&ok_block, .{ .tag = .br, .data = .{ .br = .{ .block_inst = block_inst, .operand = .void_value } } });
    var inner = block.child();
    defer inner.instructions.deinit(sema.gpa);
    try sema.addCondBr(&inner, ok, ok_block.instructions.items, fail_block.instructions.items);
    const payload = try sema.addExtra(Ir.Block{ .body_len = @intCast(inner.instructions.items.len) });
    try sema.appendBody(inner.instructions.items);
    sema.ir_insts.items(.data)[@backingInt(block_inst)].ty_pl.payload = payload;
    try block.instructions.append(sema.gpa, block_inst);
}

fn addCondBr(sema: *Sema, block: *Block, cond: Ref, then_body: []const Ir.Inst.Index, else_body: []const Ir.Inst.Index) !void {
    const payload = try sema.addExtra(Ir.CondBr{ .then_body_len = @intCast(then_body.len), .else_body_len = @intCast(else_body.len) });
    try sema.appendBody(then_body);
    try sema.appendBody(else_body);
    _ = try sema.addInst(block, .{ .tag = .cond_br, .data = .{ .pl_op = .{ .operand = cond, .payload = payload } } });
}

/// Emits a block from instructions analyzed into `child_block`.
fn addBlock(sema: *Sema, block: *Block, block_inst: Ir.Inst.Index, ty: Index, body: []const Ir.Inst.Index) !void {
    const payload = try sema.addExtra(Ir.Block{ .body_len = @intCast(body.len) });
    try sema.appendBody(body);
    sema.ir_insts.set(@backingInt(block_inst), .{ .tag = .block, .data = .{ .ty_pl = .{ .ty = ty, .payload = payload } } });
    try block.instructions.append(sema.gpa, block_inst);
}

fn reserveInst(sema: *Sema) !Ir.Inst.Index {
    const index: Ir.Inst.Index = @fromBackingInt(@intCast(sema.ir_insts.len));
    try sema.ir_insts.append(sema.gpa, .{ .tag = .unreach, .data = .{ .no_op = {} } });
    return index;
}

// ---------------------------------------------------------------------------
// Values and types

fn intern(sema: *Sema, key: InternPool.Key) !Index {
    return sema.ip.get(Zcu.tid, key);
}

fn typeOf(sema: *Sema, ref: Ref) Index {
    if (ref.toInterned()) |i| return sema.ip.typeOf(i);
    const ir: Ir = .{ .instructions = sema.ir_insts.slice(), .extra = sema.ir_extra.items, .func = .none, .main_block = 0 };
    return ir.typeOfIndex(ref.toIndex().?, sema.ip);
}

fn resolveInst(sema: *Sema, zir_ref: Zir.Inst.Ref) Ref {
    if (zir_ref.toIndex()) |i| return sema.inst_map.get(i).?;
    return .fromInterned(@fromBackingInt(@backingInt(zir_ref)));
}

/// The comptime-known value of `ref`, or null if it is runtime-known.
fn resolveValue(sema: *Sema, ref: Ref) ?Index {
    _ = sema;
    return ref.toInterned();
}

fn resolveConstValue(sema: *Sema, block: *Block, src: Src, ref: Ref, reason: []const u8) CompileError!Index {
    return sema.resolveValue(ref) orelse sema.fail(block, src, "unable to resolve comptime value: {s}", .{reason});
}

fn resolveDefinedValue(sema: *Sema, block: *Block, src: Src, ref: Ref) CompileError!?Index {
    const val = sema.resolveValue(ref) orelse return null;
    if (sema.isUndef(val)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
    return val;
}

fn isUndef(sema: *Sema, val: Index) bool {
    return sema.ip.indexToKey(val) == .undef;
}

fn analyzeAsType(sema: *Sema, block: *Block, src: Src, ref: Ref) CompileError!Index {
    const coerced = try sema.coerce(block, .type_type, ref, src);
    return sema.resolveConstValue(block, src, coerced, "types must be comptime-known");
}

fn resolveType(sema: *Sema, block: *Block, src: Src, zir_ref: Zir.Inst.Ref) CompileError!Index {
    return sema.analyzeAsType(block, src, sema.resolveInst(zir_ref));
}

fn resolveInt(sema: *Sema, block: *Block, src: Src, zir_ref: Zir.Inst.Ref, ty: Index, reason: []const u8) CompileError!u64 {
    const coerced = try sema.coerce(block, ty, sema.resolveInst(zir_ref), src);
    const val = try sema.resolveConstValue(block, src, coerced, reason);
    if (sema.isUndef(val)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
    return sema.ip.intValue(u64, val) orelse sema.fail(block, src, "integer value out of range", .{});
}

fn resolveBool(sema: *Sema, block: *Block, src: Src, ref: Ref, reason: []const u8) CompileError!bool {
    const coerced = try sema.coerce(block, .bool_type, ref, src);
    const val = try sema.resolveConstValue(block, src, coerced, reason);
    if (sema.isUndef(val)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
    return val == .bool_true;
}

fn boolValue(b: bool) Index {
    return if (b) .bool_true else .bool_false;
}

fn ptrType(sema: *Sema, info: InternPool.PtrType) !Index {
    return sema.intern(.{ .ptr_type = info });
}

fn optType(sema: *Sema, child: Index) !Index {
    return sema.intern(.{ .opt_type = child });
}

fn intType(sema: *Sema, signedness: std.lang.Signedness, bits: u16) !Index {
    return sema.intern(.{ .int_type = .{ .signedness = signedness, .bits = bits } });
}

fn getString(sema: *Sema, bytes: []const u8) !InternPool.String {
    return sema.ip.getString(Zcu.tid, bytes);
}

fn zirString(sema: *Sema, s: Zir.NullTerminatedString) []const u8 {
    return sema.code.nullTerminatedString(s);
}

fn undefValue(sema: *Sema, ty: Index) !Index {
    return sema.intern(.{ .undef = ty });
}

fn intValue(sema: *Sema, ty: Index, value: anytype) !Index {
    return sema.ip.getInt(Zcu.tid, ty, value);
}

fn bigValue(sema: *Sema, val: Index) !BigInt {
    var space: [2]std.math.big.Limb = undefined;
    const c = sema.ip.intToBig(val, &space);
    return c.toManaged(sema.arena);
}

fn bigToValue(sema: *Sema, ty: Index, big: BigIntConst) !Index {
    return sema.ip.getInt(Zcu.tid, ty, big);
}

/// Whether a comptime-known integer fits in integer type `ty`.
fn intFits(sema: *Sema, val: Index, ty: Index) bool {
    if (ty == .comptime_int_type) return true;
    var space: [2]std.math.big.Limb = undefined;
    const big = sema.ip.intToBig(val, &space);
    const info = Type.intInfo(sema.ip, ty);
    return big.fitsInTwosComp(info.signedness, info.bits);
}

fn minIntValue(sema: *Sema, ty: Index) !Index {
    const info = Type.intInfo(sema.ip, ty);
    if (info.signedness == .unsigned or info.bits == 0) return sema.intValue(ty, 0);
    var big = try BigInt.initSet(sema.arena, 1);
    try big.shiftLeft(&big, info.bits - 1);
    big.negate();
    return sema.bigToValue(ty, big.toConst());
}

fn maxIntValue(sema: *Sema, ty: Index) !Index {
    const info = Type.intInfo(sema.ip, ty);
    if (info.bits == 0) return sema.intValue(ty, 0);
    var big = try BigInt.initSet(sema.arena, 1);
    try big.shiftLeft(&big, info.bits - @intFromBool(info.signedness == .signed));
    var one = try BigInt.initSet(sema.arena, 1);
    try big.sub(&big, &one);
    return sema.bigToValue(ty, big.toConst());
}

// ---------------------------------------------------------------------------
// Body analysis

/// Analyzes a body whose result is delivered by a `break_inline` (or comptime
/// `break`) to `break_target`, and returns that result.
fn resolveInlineBody(sema: *Sema, block: *Block, body: []const Zir.Inst.Index, break_target: Zir.Inst.Index) CompileError!Ref {
    return (try sema.analyzeInlineBody(block, body, break_target)) orelse .unreachable_value;
}

/// Like `resolveInlineBody`, but returns null if the body ended with runtime
/// `noreturn` control flow instead of breaking to `break_target`.
fn analyzeInlineBody(sema: *Sema, block: *Block, body: []const Zir.Inst.Index, break_target: Zir.Inst.Index) CompileError!?Ref {
    sema.analyzeBodyInner(block, body) catch |err| switch (err) {
        error.ComptimeBreak => {
            const brk = sema.code.instructions.items(.data)[@backingInt(sema.comptime_break_inst)].@"break";
            const extra = sema.code.extraData(Zir.Inst.Break, brk.payload_index).data;
            if (extra.block_inst != break_target) return error.ComptimeBreak;
            return sema.resolveInst(brk.operand);
        },
        else => |e| return e,
    };
    return null;
}

fn emitBackwardBranch(sema: *Sema, block: *Block, src: Src) CompileError!void {
    sema.branch_count += 1;
    if (sema.branch_count > sema.branch_quota) {
        return sema.fail(block, src, "evaluation exceeded {d} backwards branches", .{sema.branch_quota});
    }
}

fn analyzeBodyInner(sema: *Sema, block: *Block, start_body: []const Zir.Inst.Index) CompileError!void {
    const tags = sema.code.instructions.items(.tag);
    const datas = sema.code.instructions.items(.data);
    const gpa = sema.gpa;
    var body = start_body;
    var i: usize = 0;
    while (true) {
        const inst = body[i];
        const data = datas[@backingInt(inst)];
        const ref: Ref = switch (tags[@backingInt(inst)]) {
            // Control flow.
            .@"break" => {
                if (block.is_comptime) {
                    sema.comptime_break_inst = inst;
                    return error.ComptimeBreak;
                }
                try sema.zirBreak(block, inst);
                return;
            },
            .break_inline => {
                sema.comptime_break_inst = inst;
                return error.ComptimeBreak;
            },
            .repeat => {
                if (block.is_comptime) {
                    try sema.emitBackwardBranch(block, block.nodeSrc(data.node));
                    i = 0;
                    continue;
                }
                _ = try sema.addInst(block, .{ .tag = .repeat, .data = .{ .repeat = .{ .loop_inst = block.loop.? } } });
                return;
            },
            .repeat_inline => {
                try sema.emitBackwardBranch(block, block.nodeSrc(data.node));
                i = 0;
                continue;
            },
            .loop => if (block.is_comptime) try sema.zirBlockInline(block, inst) else try sema.zirLoop(block, inst),
            .block => if (block.is_comptime) try sema.zirBlockInline(block, inst) else try sema.zirBlock(block, inst),
            .block_inline => try sema.zirBlockInline(block, inst),
            .block_comptime => blk: {
                const extra = sema.code.extraData(Zir.Inst.BlockComptime, data.pl_node.payload_index);
                const block_body = sema.code.bodySlice(extra.end, extra.data.body_len);
                var child = block.child();
                defer child.instructions.deinit(gpa);
                child.is_comptime = true;
                const result = try sema.resolveInlineBody(&child, block_body, inst);
                if (sema.resolveValue(result) == null) {
                    return sema.fail(block, block.nodeSrc(data.pl_node.src_node), "unable to resolve comptime value", .{});
                }
                break :blk result;
            },
            .condbr => if (block.is_comptime) {
                body = try sema.condbrInlineBody(block, inst);
                i = 0;
                continue;
            } else {
                if (try sema.zirCondbr(block, inst)) |taken| {
                    body = taken;
                    i = 0;
                    continue;
                }
                return;
            },
            .condbr_inline => {
                body = try sema.condbrInlineBody(block, inst);
                i = 0;
                continue;
            },
            .check_comptime_control_flow => {
                i += 1;
                continue;
            },
            .@"defer" => {
                const defer_body = sema.code.bodySlice(data.@"defer".index, data.@"defer".len);
                sema.analyzeBodyInner(block, defer_body) catch |err| switch (err) {
                    error.ComptimeBreak => {
                        if (sema.comptime_break_inst != defer_body[defer_body.len - 1]) return error.ComptimeBreak;
                        i += 1;
                        continue;
                    },
                    else => |e| return e,
                };
                return;
            },
            .ret_node, .ret_implicit => {
                if (tags[@backingInt(inst)] == .ret_implicit and block.inlining == null and sema.func != .none) {
                    const src = block.tokSrc(data.un_tok.src_tok);
                    const fn_ty = sema.ip.indexToKey(sema.ip.typeOf(sema.func)).func_type;
                    if (fn_ty.cc == .naked) {
                        _ = try sema.addInst(block, .{ .tag = if (block.want_safety) .trap else .unreach, .data = .{ .no_op = {} } });
                        return;
                    }
                    if (fn_ty.return_type == .noreturn_type) return sema.fail(block, src, "function declared 'noreturn' implicitly returns", .{});
                }
                const operand = if (tags[@backingInt(inst)] == .ret_node) data.un_node.operand else data.un_tok.operand;
                const src = if (tags[@backingInt(inst)] == .ret_node) block.nodeSrc(data.un_node.src_node) else block.tokSrc(data.un_tok.src_tok);
                try sema.analyzeRet(block, sema.resolveInst(operand), src);
                return;
            },
            .ret_load => {
                const src = block.nodeSrc(data.un_node.src_node);
                const val = try sema.analyzeLoad(block, src, sema.resolveInst(data.un_node.operand));
                try sema.analyzeRet(block, val, src);
                return;
            },
            .ret_err_value => {
                const src = block.tokSrc(data.str_tok.src_tok);
                const name = try sema.getString(data.str_tok.get(sema.code.*));
                const err_ty = try sema.intern(.{ .error_set_type = &.{name} });
                const val = try sema.intern(.{ .err = .{ .ty = err_ty, .name = name } });
                try sema.analyzeRet(block, .fromInterned(val), src);
                return;
            },
            .@"unreachable" => {
                const src = block.nodeSrc(data.@"unreachable".src_node);
                if (block.is_comptime) return sema.fail(block, src, "reached unreachable code", .{});
                if (block.want_safety) {
                    try sema.addPanic(block, .reached_unreachable, .none, .none);
                } else {
                    _ = try sema.addInst(block, .{ .tag = .unreach, .data = .{ .no_op = {} } });
                }
                return;
            },
            .trap => {
                if (block.is_comptime) return sema.fail(block, block.nodeSrc(data.node), "encountered @trap at comptime", .{});
                _ = try sema.addInst(block, .{ .tag = .trap, .data = .{ .no_op = {} } });
                return;
            },
            .panic => {
                const src = block.nodeSrc(data.un_node.src_node);
                const msg = try sema.coerce(block, .slice_const_u8_type, sema.resolveInst(data.un_node.operand), src);
                if (block.is_comptime) return sema.fail(block, src, "encountered @panic at comptime", .{});
                try sema.addPanic(block, .explicit, msg, .none);
                return;
            },
            .compile_error => {
                const src = block.nodeSrc(data.un_node.src_node);
                const msg = try sema.resolveConstString(block, src, sema.resolveInst(data.un_node.operand));
                return sema.fail(block, src, "{s}", .{msg});
            },

            // Instructions with no result.
            .dbg_stmt => {
                // Lines in an inlined body are relative to another declaration.
                if (!block.is_comptime and block.inlining == null) try sema.addDbgStmt(block, data.dbg_stmt.line, data.dbg_stmt.column);
                i += 1;
                continue;
            },
            .dbg_var_ptr,
            .dbg_var_val,
            .ensure_result_non_error,
            .ensure_err_union_payload_void,
            .save_err_ret_index,
            .restore_err_ret_index_unconditional,
            .restore_err_ret_index_fn_entry,
            .validate_struct_init_ty,
            .validate_struct_init_result_ty,
            .validate_array_init_ty,
            .validate_array_init_result_ty,
            .validate_ref_ty,
            .set_eval_branch_quota,
            => {
                if (tags[@backingInt(inst)] == .set_eval_branch_quota) {
                    const src = block.nodeSrc(data.un_node.src_node);
                    const quota = try sema.resolveInt(block, src, data.un_node.operand, .u32_type, "eval branch quota must be comptime-known");
                    sema.branch_quota = @max(sema.branch_quota, @as(u32, @intCast(quota)));
                }
                i += 1;
                continue;
            },
            .ensure_result_used => {
                try sema.zirEnsureResultUsed(block, inst);
                i += 1;
                continue;
            },
            .store_node => {
                try sema.zirStoreNode(block, inst);
                i += 1;
                continue;
            },
            .store_to_inferred_ptr => {
                try sema.zirStoreToInferredPtr(block, inst);
                i += 1;
                continue;
            },
            .validate_ptr_struct_init => {
                try sema.zirValidatePtrStructInit(block, inst);
                i += 1;
                continue;
            },
            .validate_ptr_array_init => {
                try sema.zirValidatePtrArrayInit(block, inst);
                i += 1;
                continue;
            },
            .validate_const => {
                if (block.is_comptime and sema.resolveValue(sema.resolveInst(data.un_node.operand)) == null) {
                    return sema.fail(block, block.nodeSrc(data.un_node.src_node), "unable to resolve comptime value", .{});
                }
                i += 1;
                continue;
            },
            .@"export" => {
                try sema.zirExport(block, inst);
                i += 1;
                continue;
            },
            .validate_destructure => return sema.failUnsupported(block, block.nodeSrc(.zero), "destructuring"),
            .set_runtime_safety => {
                const src = block.nodeSrc(data.un_node.src_node);
                const safety = try sema.resolveBool(block, src, sema.resolveInst(data.un_node.operand), "operand to @setRuntimeSafety must be comptime-known");
                if (sema.zcu.file(sema.file).module != .compiler_rt) block.want_safety = safety;
                i += 1;
                continue;
            },

            .param, .param_comptime, .param_anytype, .param_anytype_comptime => {
                try sema.zirParam(block, inst);
                i += 1;
                continue;
            },

            .extended => switch (data.extended.opcode) {
                .dbg_empty_stmt, .restore_err_ret_index, .branch_hint => {
                    i += 1;
                    continue;
                },
                else => try sema.zirExtended(block, inst),
            },

            else => try sema.analyzeInst(block, inst),
        };
        try sema.inst_map.put(gpa, inst, ref);
        if (sema.typeOf(ref) == .noreturn_type) {
            // A call to a `noreturn` function, or a block all of whose paths
            // are `noreturn`, ends the body.
            if (!block.is_comptime) {
                if (block.instructions.items.len == 0 or !sema.isNoReturnInst(block.instructions.getLast())) {
                    _ = try sema.addInst(block, .{ .tag = .unreach, .data = .{ .no_op = {} } });
                }
            }
            return;
        }
        i += 1;
    }
}

fn isNoReturnInst(sema: *Sema, inst: Ir.Inst.Index) bool {
    return switch (sema.ir_insts.items(.tag)[@backingInt(inst)]) {
        .repeat, .br, .cond_br, .switch_br, .ret, .unreach, .trap, .panic => true,
        else => false,
    };
}

fn addDbgStmt(sema: *Sema, block: *Block, line: u32, column: u32) !void {
    // Consecutive statements without code between them collapse into one.
    if (block.instructions.items.len != 0) {
        const last = block.instructions.getLast();
        if (sema.ir_insts.items(.tag)[@backingInt(last)] == .dbg_stmt) {
            sema.ir_insts.items(.data)[@backingInt(last)] = .{ .dbg_stmt = .{ .line = line, .column = column } };
            return;
        }
    }
    _ = try sema.addInst(block, .{ .tag = .dbg_stmt, .data = .{ .dbg_stmt = .{ .line = line, .column = column } } });
}

fn condbrInlineBody(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError![]const Zir.Inst.Index {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.CondBr, data.payload_index);
    const then_body = sema.code.bodySlice(extra.end, extra.data.then_body_len);
    const else_body = sema.code.bodySlice(extra.end + then_body.len, extra.data.else_body_len);
    const src = block.nodeSrc(data.src_node);
    const cond = try sema.resolveBool(block, src, sema.resolveInst(extra.data.condition), "condition must be comptime-known");
    return if (cond) then_body else else_body;
}

fn zirBlockInline(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Block, data.payload_index);
    const body = sema.code.bodySlice(extra.end, extra.data.body_len);
    return sema.resolveInlineBody(block, body, inst);
}

fn zirBlock(sema: *Sema, parent: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Block, data.payload_index);
    const body = sema.code.bodySlice(extra.end, extra.data.body_len);
    const block_inst = try sema.reserveInst();
    var label: Block.Label = .{ .zir_block = inst, .merges = .{ .block_inst = block_inst } };
    var child = parent.child();
    child.label = &label;
    defer {
        child.instructions.deinit(sema.gpa);
        label.merges.results.deinit(sema.gpa);
        label.merges.brs.deinit(sema.gpa);
    }
    // A comptime break to this block (from a nested inline body) delivers
    // the result directly.
    if (try sema.analyzeInlineBody(&child, body, inst)) |result| {
        // Comptime control flow reached the end: splice into the parent.
        if (label.merges.results.items.len == 0) {
            try parent.instructions.appendSlice(sema.gpa, child.instructions.items);
            return result;
        }
        // Mixed: a runtime br plus a comptime break. Turn the latter into a br.
        try sema.addBr(&child, &label, result);
    }
    return sema.resolveBlock(parent, parent.nodeSrc(data.src_node), &child, &label.merges);
}

/// Finishes a runtime block whose body was analyzed into `child`.
fn resolveBlock(sema: *Sema, parent: *Block, src: Src, child: *Block, merges: *Block.Merges) CompileError!Ref {
    const gpa = sema.gpa;
    const results = merges.results.items;
    if (results.len == 0) {
        // Every path is `noreturn`.
        try parent.instructions.appendSlice(gpa, child.instructions.items);
        return .unreachable_value;
    }
    if (results.len == 1 and child.instructions.items.len != 0 and child.instructions.getLast() == merges.brs.items[0]) {
        // The only exit is the end of the body: no block needed.
        try parent.instructions.appendSlice(gpa, child.instructions.items[0 .. child.instructions.items.len - 1]);
        return results[0];
    }
    const result_ty = try sema.resolvePeerTypes(parent, src, results);
    try sema.resolveLayout(parent, src, result_ty);
    for (merges.brs.items, results) |br, result| {
        try sema.coerceBrOperand(child, br, result_ty, result, src);
    }
    try sema.addBlock(parent, merges.block_inst, result_ty, child.instructions.items);
    // A block whose result is comptime-known in every branch still runs
    // its side effects; its value is the IR block.
    return merges.block_inst.toRef();
}

/// Rewrites `br` (or `store`) instruction `inst`, whose operand is `operand`,
/// so that the operand is coerced to `ty` first.
fn coerceBrOperand(sema: *Sema, b: *Block, inst: Ir.Inst.Index, ty: Index, operand: Ref, src: Src) CompileError!void {
    if (sema.typeOf(operand) == ty) return;
    var coerce_block = b.child();
    defer coerce_block.instructions.deinit(sema.gpa);
    const coerced = try sema.coerce(&coerce_block, ty, operand, src);
    var data = sema.ir_insts.items(.data)[@backingInt(inst)];
    const tag = sema.ir_insts.items(.tag)[@backingInt(inst)];
    switch (tag) {
        .br => data.br.operand = coerced,
        .store => data.bin_op.rhs = coerced,
        else => unreachable,
    }
    if (coerce_block.instructions.items.len == 0) {
        sema.ir_insts.items(.data)[@backingInt(inst)] = data;
        return;
    }
    // Move the original instruction to a new index and turn `inst` into a
    // block that coerces and then performs it.
    const moved: Ir.Inst.Index = @fromBackingInt(@intCast(sema.ir_insts.len));
    try sema.ir_insts.append(sema.gpa, .{ .tag = tag, .data = data });
    try coerce_block.instructions.append(sema.gpa, moved);
    const payload = try sema.addExtra(Ir.Block{ .body_len = @intCast(coerce_block.instructions.items.len) });
    try sema.appendBody(coerce_block.instructions.items);
    const block_ty: Index = if (tag == .br) .noreturn_type else .void_type;
    if (tag == .store) {
        // A store-block needs an exit: append `br` to it.
        return sema.failUnsupported(b, src, "coercing stores to inferred allocations");
    }
    sema.ir_insts.set(@backingInt(inst), .{ .tag = .block, .data = .{ .ty_pl = .{ .ty = block_ty, .payload = payload } } });
}

fn addBr(sema: *Sema, b: *Block, label: *Block.Label, operand: Ref) !void {
    const br = try sema.addInst(b, .{ .tag = .br, .data = .{ .br = .{ .block_inst = label.merges.block_inst, .operand = operand } } });
    try label.merges.results.append(sema.gpa, operand);
    try label.merges.brs.append(sema.gpa, br.toIndex().?);
}

fn zirBreak(sema: *Sema, b: *Block, inst: Zir.Inst.Index) CompileError!void {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].@"break";
    const extra = sema.code.extraData(Zir.Inst.Break, data.payload_index).data;
    const operand = sema.resolveInst(data.operand);
    var it: ?*Block = b;
    while (it) |cur| : (it = cur.parent) {
        const label = cur.label orelse continue;
        if (label.zir_block == extra.block_inst) return sema.addBr(b, label, operand);
    }
    // The target is an inline block (for example an `inline` loop) outside
    // of runtime control flow.
    sema.comptime_break_inst = inst;
    return error.ComptimeBreak;
}

fn zirLoop(sema: *Sema, parent: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Block, data.payload_index);
    const body = sema.code.bodySlice(extra.end, extra.data.body_len);
    const gpa = sema.gpa;
    // `block { loop { body } }`: breaks to the ZIR loop exit the block.
    const block_inst = try sema.reserveInst();
    const loop_inst = try sema.reserveInst();
    var label: Block.Label = .{ .zir_block = inst, .merges = .{ .block_inst = block_inst } };
    var loop_block = parent.child();
    loop_block.label = &label;
    loop_block.loop = loop_inst;
    defer {
        loop_block.instructions.deinit(gpa);
        label.merges.results.deinit(gpa);
        label.merges.brs.deinit(gpa);
    }
    try sema.analyzeBodyInner(&loop_block, body);
    const loop_payload = try sema.addExtra(Ir.Block{ .body_len = @intCast(loop_block.instructions.items.len) });
    try sema.appendBody(loop_block.instructions.items);
    sema.ir_insts.set(@backingInt(loop_inst), .{ .tag = .loop, .data = .{ .ty_pl = .{ .ty = .noreturn_type, .payload = loop_payload } } });

    var outer = parent.child();
    defer outer.instructions.deinit(gpa);
    try outer.instructions.append(gpa, loop_inst);
    if (label.merges.results.items.len == 0) {
        try parent.instructions.append(gpa, loop_inst);
        return .unreachable_value;
    }
    const src = parent.nodeSrc(data.src_node);
    const result_ty = try sema.resolvePeerTypes(parent, src, label.merges.results.items);
    for (label.merges.brs.items, label.merges.results.items) |br, result| try sema.coerceBrOperand(&outer, br, result_ty, result, src);
    try sema.addBlock(parent, block_inst, result_ty, outer.instructions.items);
    return block_inst.toRef();
}

/// Returns the body to continue with if the condition is comptime-known.
fn zirCondbr(sema: *Sema, parent: *Block, inst: Zir.Inst.Index) CompileError!?[]const Zir.Inst.Index {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.CondBr, data.payload_index);
    const then_body = sema.code.bodySlice(extra.end, extra.data.then_body_len);
    const else_body = sema.code.bodySlice(extra.end + then_body.len, extra.data.else_body_len);
    const src = parent.nodeSrc(data.src_node);
    const cond = try sema.coerce(parent, .bool_type, sema.resolveInst(extra.data.condition), src);
    if (try sema.resolveDefinedValue(parent, src, cond)) |v| return if (v == .bool_true) then_body else else_body;

    const gpa = sema.gpa;
    var then_block = parent.child();
    defer then_block.instructions.deinit(gpa);
    try sema.analyzeBodyInner(&then_block, then_body);
    var else_block = parent.child();
    defer else_block.instructions.deinit(gpa);
    try sema.analyzeBodyInner(&else_block, else_body);
    try sema.addCondBr(parent, cond, then_block.instructions.items, else_block.instructions.items);
    return null;
}

fn analyzeRet(sema: *Sema, b: *Block, operand: Ref, src: Src) CompileError!void {
    if (b.inlining) |inlining| {
        // An inlined function's inferred error set is what its returns
        // produce.
        var ty = inlining.ret_ty;
        if (sema.ip.indexToKey(ty) == .error_union_type and sema.ip.indexToKey(ty).error_union_type.error_set_type == .adhoc_inferred_error_set_type) {
            const op_ty = sema.typeOf(operand);
            const set: Index = switch (Type.class(sema.ip, op_ty)) {
                .error_union => sema.ip.indexToKey(op_ty).error_union_type.error_set_type,
                .error_set => op_ty,
                else => try sema.intern(.{ .error_set_type = &.{} }),
            };
            ty = try sema.intern(.{ .error_union_type = .{ .error_set_type = set, .payload_type = sema.ip.indexToKey(ty).error_union_type.payload_type } });
        }
        const coerced = try sema.coerce(b, ty, operand, src);
        if (inlining.merges) |merges| {
            if (b.is_comptime) return sema.fail(b, src, "function called at runtime cannot return value at comptime", .{});
            const br = try sema.addInst(b, .{ .tag = .br, .data = .{ .br = .{ .block_inst = merges.block_inst, .operand = coerced } } });
            try merges.results.append(sema.gpa, coerced);
            try merges.brs.append(sema.gpa, br.toIndex().?);
            return;
        }
        inlining.result = coerced;
        return error.ComptimeReturn;
    }
    if (b.is_comptime) return sema.fail(b, src, "function called at runtime cannot return value at comptime", .{});
    try sema.recordInferredErrors(b, src, operand);
    const coerced = try sema.coerce(b, sema.fn_ret_ty, operand, src);
    _ = try sema.addUnOp(b, .ret, coerced);
}

// ---------------------------------------------------------------------------
// Instructions

fn analyzeInst(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const tag = sema.code.instructions.items(.tag)[@backingInt(inst)];
    const data = sema.code.instructions.items(.data)[@backingInt(inst)];
    return switch (tag) {
        .int => .fromInterned(try sema.intValue(.comptime_int_type, data.int)),
        .int_big => blk: {
            // `str.len` counts limbs, and the bytes may contain zeros.
            const limbs = try sema.arena.alloc(std.math.big.Limb, data.str.len);
            const limb_bytes = sema.code.string_bytes[@backingInt(data.str.start)..][0 .. limbs.len * @sizeOf(std.math.big.Limb)];
            @memcpy(std.mem.sliceAsBytes(limbs), limb_bytes);
            break :blk .fromInterned(try sema.bigToValue(.comptime_int_type, .{ .limbs = limbs, .positive = true }));
        },
        .float => .fromInterned(try sema.floatValue(.comptime_float_type, data.float)),
        .float128 => .fromInterned(try sema.floatValue(.comptime_float_type, sema.code.extraData(Zir.Inst.Float128, data.pl_node.payload_index).data.get())),
        .str => .fromInterned(try sema.stringLiteral(data.str.get(sema.code.*))),
        .enum_literal => .fromInterned(try sema.intern(.{ .enum_literal = try sema.getString(data.str_tok.get(sema.code.*)) })),
        .error_value => blk: {
            const name = try sema.getString(data.str_tok.get(sema.code.*));
            _ = try sema.ip.errorValue(name);
            const ty = try sema.intern(.{ .error_set_type = &.{name} });
            break :blk .fromInterned(try sema.intern(.{ .err = .{ .ty = ty, .name = name } }));
        },
        .decl_val => sema.zirDeclVal(block, inst, false),
        .decl_ref => sema.zirDeclVal(block, inst, true),
        .import => sema.zirImport(block, inst),
        .decl_literal, .decl_literal_no_coerce => sema.zirDeclLiteral(block, inst),

        // Types.
        .int_type => .fromInterned(try sema.intType(data.int_type.signedness, data.int_type.bit_count)),
        .ptr_type => sema.zirPtrType(block, inst),
        .array_type => blk: {
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const len = try sema.resolveInt(block, src, extra.lhs, .usize_type, "array length must be comptime-known");
            const elem = try sema.resolveType(block, src, extra.rhs);
            break :blk .fromInterned(try sema.intern(.{ .array_type = .{ .len = len, .child = elem } }));
        },
        .array_type_sentinel => blk: {
            const extra = sema.code.extraData(Zir.Inst.ArrayTypeSentinel, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const len = try sema.resolveInt(block, src, extra.len, .usize_type, "array length must be comptime-known");
            const elem = try sema.resolveType(block, src, extra.elem_type);
            const sentinel = try sema.resolveConstValue(block, src, try sema.coerce(block, elem, sema.resolveInst(extra.sentinel), src), "array sentinel must be comptime-known");
            break :blk .fromInterned(try sema.intern(.{ .array_type = .{ .len = len, .child = elem, .sentinel = sentinel } }));
        },
        .optional_type => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            break :blk .fromInterned(try sema.optType(try sema.resolveType(block, src, data.un_node.operand)));
        },
        .error_union_type => blk: {
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const set = try sema.resolveType(block, src, extra.lhs);
            const payload = try sema.resolveType(block, src, extra.rhs);
            if (Type.class(sema.ip, set) != .error_set) return sema.fail(block, src, "expected error set type, found '{f}'", .{sema.fmtType(set)});
            break :blk .fromInterned(try sema.intern(.{ .error_union_type = .{ .error_set_type = set, .payload_type = payload } }));
        },
        .error_set_decl => blk: {
            const extra = sema.code.extraData(Zir.Inst.ErrorSetDecl, data.pl_node.payload_index);
            const names = try sema.arena.alloc(InternPool.String, extra.data.fields_len);
            for (names, 0..) |*n, k| {
                const s: Zir.NullTerminatedString = @fromBackingInt(sema.code.extra[extra.end + k]);
                n.* = try sema.getString(sema.zirString(s));
                _ = try sema.ip.errorValue(n.*);
            }
            break :blk .fromInterned(try sema.errorSetType(names));
        },
        .merge_error_sets => blk: {
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const a = try sema.resolveType(block, src, extra.lhs);
            const b = try sema.resolveType(block, src, extra.rhs);
            break :blk .fromInterned(try sema.mergeErrorSets(block, src, a, b));
        },
        .elem_type => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            var ty = try sema.resolveType(block, src, data.un_node.operand);
            while (true) switch (sema.ip.indexToKey(ty)) {
                .opt_type => |c| ty = c,
                .error_union_type => |e| ty = e.payload_type,
                else => break,
            };
            if (ty == .generic_poison_type) break :blk .fromInterned(.generic_poison_type);
            const child = Type.ptrInfo(sema.ip, ty).child;
            break :blk .fromInterned(if (child == .anyopaque_type) .generic_poison_type else child);
        },
        .indexable_ptr_elem_type => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const ty = try sema.resolveType(block, src, data.un_node.operand);
            const p = Type.ptrInfo(sema.ip, ty);
            break :blk .fromInterned(if (p.flags.size == .one) Type.childType(sema.ip, p.child) else p.child);
        },
        .reify_int => blk: {
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const sv = try sema.resolveConstValue(block, src, sema.resolveInst(extra.lhs), "signedness must be comptime-known");
            const bits = try sema.resolveInt(block, src, extra.rhs, .u16_type, "bit count must be comptime-known");
            const signedness: std.lang.Signedness = if (std.mem.eql(u8, sema.enumTagName(sv).?, "signed")) .signed else .unsigned;
            break :blk .fromInterned(try sema.intType(signedness, @intCast(bits)));
        },
        .vector_type => blk: {
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const len = try sema.resolveInt(block, src, extra.lhs, .u32_type, "vector length must be comptime-known");
            const child = try sema.resolveType(block, src, extra.rhs);
            const ok = switch (Type.class(sema.ip, child)) {
                .int, .float, .bool => true,
                .pointer => !Type.isSlice(sema.ip, child),
                .optional => Type.optionalReprIsPtr(sema.ip, Type.childType(sema.ip, child)),
                else => false,
            };
            if (!ok) return sema.fail(block, src, "expected integer, float, bool, or pointer for the vector element type; found '{f}'", .{sema.fmtType(child)});
            break :blk .fromInterned(try sema.vectorType(@intCast(len), child));
        },
        .anyframe_type => sema.failUnsupported(block, block.nodeSrc(.zero), @tagName(tag)),
        .typeof => .fromInterned(sema.typeOf(sema.resolveInst(data.un_node.operand))),
        .typeof_builtin => blk: {
            const extra = sema.code.extraData(Zir.Inst.Block, data.pl_node.payload_index);
            const body = sema.code.bodySlice(extra.end, extra.data.body_len);
            var child = block.child();
            defer child.instructions.deinit(sema.gpa);
            // The operand is analyzed for its type only, as runtime code even
            // in a comptime scope (like upstream); any IR it emits is never
            // referenced by a body.
            child.is_comptime = false;
            const operand = try sema.resolveInlineBody(&child, body, inst);
            break :blk .fromInterned(sema.typeOf(operand));
        },
        .typeof_log2_int_type => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const operand_ty = sema.typeOf(sema.resolveInst(data.un_node.operand));
            const ty = Type.scalarType(sema.ip, operand_ty);
            if (ty == .comptime_int_type) break :blk .fromInterned(.comptime_int_type);
            if (!Type.isInt(sema.ip, ty)) return sema.fail(block, src, "bit shifting operation expected integer type, found '{f}'", .{sema.fmtType(operand_ty)});
            const shift_ty = try sema.intType(.unsigned, Type.log2IntBits(Type.intInfo(sema.ip, ty).bits));
            break :blk .fromInterned(if (sema.vectorLen(operand_ty)) |len| try sema.vectorType(len, shift_ty) else shift_ty);
        },
        .ret_type => .fromInterned(sema.currentRetTy(block)),

        .as_node, .as_shift_operand => blk: {
            const extra = sema.code.extraData(Zir.Inst.As, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const dest = try sema.resolveType(block, src, extra.dest_type);
            break :blk sema.coerce(block, dest, sema.resolveInst(extra.operand), src);
        },

        // Memory.
        .alloc, .alloc_mut => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const ty = try sema.resolveType(block, src, data.un_node.operand);
            break :blk sema.analyzeAlloc(block, src, ty, tag == .alloc, false);
        },
        .alloc_comptime_mut => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const ty = try sema.resolveType(block, src, data.un_node.operand);
            break :blk sema.analyzeAlloc(block, src, ty, false, true);
        },
        .alloc_inferred, .alloc_inferred_mut => sema.allocInferred(block, tag == .alloc_inferred, false),
        .alloc_inferred_comptime, .alloc_inferred_comptime_mut => sema.allocInferred(block, tag == .alloc_inferred_comptime, true),
        .resolve_inferred_alloc => sema.zirResolveInferredAlloc(block, inst),
        .make_ptr_const => blk: {
            const ptr = sema.resolveInst(data.un_node.operand);
            var info = Type.ptrInfo(sema.ip, sema.typeOf(ptr));
            info.flags.is_const = true;
            break :blk sema.coercePtrTo(block, ptr, try sema.ptrType(info));
        },
        .load => sema.analyzeLoad(block, block.nodeSrc(data.un_node.src_node), sema.resolveInst(data.un_node.operand)),
        .ref => sema.analyzeRef(block, block.tokSrc(data.un_tok.src_tok), sema.resolveInst(data.un_tok.operand)),
        .deref => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const ptr = sema.resolveInst(data.un_node.operand);
            try sema.checkDerefable(block, src, sema.typeOf(ptr));
            break :blk sema.analyzeLoad(block, src, ptr);
        },
        .ref_deref => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const ptr = sema.resolveInst(data.un_node.operand);
            try sema.checkDerefable(block, src, sema.typeOf(ptr));
            break :blk ptr;
        },
        .ret_ptr => sema.analyzeAlloc(block, block.nodeSrc(data.node), sema.currentRetTy(block), false, block.is_comptime),

        // Arithmetic.
        .add, .addwrap, .add_unsafe, .sub, .subwrap, .mul, .mulwrap, .div, .div_trunc, .div_floor, .div_exact, .div_ceil, .mod, .rem, .mod_rem, .shl, .shr, .bit_and, .bit_or, .xor => blk: {
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            break :blk sema.analyzeArithmetic(block, src, tag, sema.resolveInst(extra.lhs), sema.resolveInst(extra.rhs));
        },
        .array_cat => sema.zirArrayCat(block, inst),
        .min, .max => blk: {
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            break :blk sema.analyzeMinMax(block, block.nodeSrc(data.pl_node.src_node), tag, &.{ sema.resolveInst(extra.lhs), sema.resolveInst(extra.rhs) });
        },
        .add_sat, .sub_sat, .mul_sat, .shl_sat, .shl_exact, .shr_exact => blk: {
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            break :blk sema.analyzeArithmetic(block, src, tag, sema.resolveInst(extra.lhs), sema.resolveInst(extra.rhs));
        },
        .negate => sema.analyzeNegate(block, block.nodeSrc(data.un_node.src_node), sema.resolveInst(data.un_node.operand)),
        .negate_wrap => sema.analyzeNegateWrap(block, block.nodeSrc(data.un_node.src_node), sema.resolveInst(data.un_node.operand)),
        .bit_not => sema.analyzeBitNot(block, block.nodeSrc(data.un_node.src_node), sema.resolveInst(data.un_node.operand)),
        .bool_not => sema.analyzeBoolNot(block, block.nodeSrc(data.un_node.src_node), sema.resolveInst(data.un_node.operand)),
        .bool_br_and, .bool_br_or => sema.zirBoolBr(block, inst, tag == .bool_br_or),
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => blk: {
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const op: std.math.CompareOperator = switch (tag) {
                .cmp_lt => .lt,
                .cmp_lte => .lte,
                .cmp_eq => .eq,
                .cmp_gte => .gte,
                .cmp_gt => .gt,
                .cmp_neq => .neq,
                else => unreachable,
            };
            break :blk sema.analyzeCmp(block, src, op, sema.resolveInst(extra.lhs), sema.resolveInst(extra.rhs));
        },

        // Calls and returns.
        .call => sema.zirCall(block, inst),
        .func, .func_inferred, .func_fancy => sema.zirFunc(block, inst),
        .field_call => sema.zirFieldCall(block, inst),
        .builtin_call => sema.zirBuiltinCall(block, inst),
        .ret_is_non_err, .is_non_err => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            break :blk sema.analyzeIsNonErr(block, src, sema.resolveInst(data.un_node.operand));
        },
        .is_non_err_ptr => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const loaded = try sema.analyzeLoad(block, src, sema.resolveInst(data.un_node.operand));
            break :blk sema.analyzeIsNonErr(block, src, loaded);
        },

        // Aggregates and pointers.
        .field_ptr, .field_ptr_load => blk: {
            const extra = sema.code.extraData(Zir.Inst.Field, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const name = sema.zirString(extra.field_name_start);
            const lhs = sema.resolveInst(extra.lhs);
            break :blk if (tag == .field_ptr) sema.fieldPtr(block, src, lhs, name) else sema.fieldVal(block, src, lhs, name);
        },
        .field_ptr_named, .field_ptr_named_load => blk: {
            const extra = sema.code.extraData(Zir.Inst.FieldNamed, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const name = try sema.resolveConstString(block, src, sema.resolveInst(extra.field_name));
            const lhs = sema.resolveInst(extra.lhs);
            break :blk if (tag == .field_ptr_named) sema.fieldPtr(block, src, lhs, name) else sema.fieldVal(block, src, lhs, name);
        },
        .elem_ptr_node, .elem_ptr, .elem_ptr_load, .elem_val => blk: {
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const lhs = sema.resolveInst(extra.lhs);
            const index = sema.resolveInst(extra.rhs);
            const safety = tag == .elem_ptr_node or tag == .elem_ptr_load;
            break :blk switch (tag) {
                .elem_ptr_node => sema.elemPtr(block, src, lhs, index, safety),
                .elem_ptr => sema.elemPtrOneLayer(block, src, lhs, index),
                .elem_ptr_load => if (sema.zeroBitVectorElemPtr(sema.typeOf(lhs))) |elem_ty|
                    Ref.fromInterned(try sema.intValue(elem_ty, 0))
                else if (sema.isBoolVectorPtr(sema.typeOf(lhs)) and sema.resolveValue(index) != null)
                    // Bool vectors are bit-packed: load the vector, then the bit.
                    sema.elemVal(block, src, try sema.analyzeLoad(block, src, lhs), index, true)
                else
                    sema.analyzeLoad(block, src, try sema.elemPtr(block, src, lhs, index, safety)),
                .elem_val => sema.elemVal(block, src, lhs, index, false),
                else => unreachable,
            };
        },
        .elem_val_imm => blk: {
            const operand = sema.resolveInst(data.elem_val_imm.operand);
            const index: Ref = .fromInterned(try sema.intValue(.usize_type, data.elem_val_imm.idx));
            break :blk sema.elemVal(block, block.nodeSrc(.zero), operand, index, false);
        },
        .indexable_ptr_len => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const ptr = sema.resolveInst(data.un_node.operand);
            const val = try sema.analyzeLoad(block, src, ptr);
            break :blk sema.fieldVal(block, src, val, "len");
        },
        .slice_start, .slice_end, .slice_length, .slice_sentinel => sema.zirSlice(block, inst),
        .slice_sentinel_ty => blk: {
            // The element type of what `lhs[a..b :s]` slices; the operand
            // is a pointer to `lhs`.
            const src = block.nodeSrc(data.un_node.src_node);
            const ip = sema.ip;
            const ptr_ty = sema.typeOf(sema.resolveInst(data.un_node.operand));
            if (Type.class(ip, ptr_ty) != .pointer) return sema.fail(block, src, "expected pointer, found '{f}'", .{sema.fmtType(ptr_ty)});
            const lhs_ty = Type.ptrInfo(ip, ptr_ty).child;
            break :blk .fromInterned(switch (ip.indexToKey(lhs_ty)) {
                .array_type => |a| a.child,
                .ptr_type => |p| switch (p.flags.size) {
                    .many, .c, .slice => p.child,
                    .one => switch (ip.indexToKey(p.child)) {
                        .array_type => |a| a.child,
                        else => return sema.fail(block, src, "slice of single-item pointer cannot have sentinel", .{}),
                    },
                },
                else => return sema.fail(block, src, "slice of non-array type '{f}'", .{sema.fmtType(lhs_ty)}),
            });
        },
        .for_len => sema.zirForLen(block, inst),

        // Optionals and error unions.
        .is_non_null => sema.analyzeIsNonNull(block, block.nodeSrc(data.un_node.src_node), sema.resolveInst(data.un_node.operand)),
        .is_non_null_ptr => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const loaded = try sema.analyzeLoad(block, src, sema.resolveInst(data.un_node.operand));
            break :blk sema.analyzeIsNonNull(block, src, loaded);
        },
        .optional_payload_safe, .optional_payload_unsafe => sema.optionalPayload(block, block.nodeSrc(data.un_node.src_node), sema.resolveInst(data.un_node.operand), tag == .optional_payload_safe),
        .optional_payload_safe_ptr, .optional_payload_unsafe_ptr => sema.optionalPayloadPtr(block, block.nodeSrc(data.un_node.src_node), sema.resolveInst(data.un_node.operand), tag == .optional_payload_safe_ptr, false),
        .err_union_payload_unsafe => sema.errUnionPayload(block, block.nodeSrc(data.un_node.src_node), sema.resolveInst(data.un_node.operand)),
        .err_union_payload_unsafe_ptr => sema.errUnionPayloadPtr(block, block.nodeSrc(data.un_node.src_node), sema.resolveInst(data.un_node.operand), false),
        .err_union_code => sema.errUnionCode(block, block.nodeSrc(data.un_node.src_node), sema.resolveInst(data.un_node.operand)),
        .err_union_code_ptr => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const loaded = try sema.analyzeLoad(block, src, sema.resolveInst(data.un_node.operand));
            break :blk sema.errUnionCode(block, src, loaded);
        },
        .@"try" => sema.zirTry(block, inst),
        .try_ptr => sema.failUnsupported(block, block.nodeSrc(data.pl_node.src_node), "try through a pointer"),
        .switch_block => sema.zirSwitchBlock(block, inst),
        .switch_block_err_union => sema.zirSwitchBlockErrUnion(block, inst),
        .memcpy => sema.zirMemcpy(block, inst, .memcpy),
        .memmove => sema.zirMemcpy(block, inst, .memmove),
        .memset => sema.zirMemset(block, inst),
        .switch_block_ref => sema.failUnsupported(block, block.nodeSrc(data.pl_node.src_node), @tagName(tag)),

        // Initialization.
        .struct_init_empty, .struct_init_empty_result, .struct_init_empty_ref_result => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const result_ty = try sema.resolveType(block, src, data.un_node.operand);
            if (tag != .struct_init_empty_ref_result) break :blk sema.structInitEmpty(block, src, result_ty);
            const ptr_ty = sema.unwrapOptEu(result_ty);
            if (ptr_ty == .generic_poison_type or Type.class(sema.ip, ptr_ty) != .pointer) break :blk sema.analyzeRef(block, src, .fromInterned(.empty_tuple));
            const p = Type.ptrInfo(sema.ip, ptr_ty);
            if (p.flags.size == .one) break :blk sema.analyzeRef(block, src, try sema.structInitEmpty(block, src, p.child));
            // `&.{}` as a slice or many-pointer: an empty array.
            const array_ty = try sema.intern(.{ .array_type = .{ .len = 0, .child = p.child, .sentinel = p.sentinel } });
            const ref = try sema.analyzeRef(block, src, try sema.structInitEmpty(block, src, array_ty));
            break :blk sema.coerce(block, result_ty, ref, src);
        },
        .struct_init, .struct_init_ref => blk: {
            const val = try sema.zirStructInit(block, inst);
            break :blk if (tag == .struct_init_ref) sema.analyzeRef(block, block.nodeSrc(data.pl_node.src_node), val) else val;
        },
        .struct_init_anon => blk: {
            const extra = sema.code.extraData(Zir.Inst.StructInitAnon, data.pl_node.payload_index);
            const names = try sema.arena.alloc(InternPool.String, extra.data.fields_len);
            const inits = try sema.arena.alloc(Ref, extra.data.fields_len);
            var i = extra.end;
            for (names, inits) |*n, *init| {
                const item = sema.code.extraData(Zir.Inst.StructInitAnon.Item, i);
                i = item.end;
                n.* = try sema.getString(sema.zirString(item.data.field_name));
                init.* = sema.resolveInst(item.data.init);
            }
            break :blk sema.anonStructInit(block, inst, data.pl_node.src_node, names, inits);
        },
        .struct_init_field_type => blk: {
            const extra = sema.code.extraData(Zir.Inst.FieldType, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const ty = try sema.resolveType(block, src, extra.container_type);
            break :blk .fromInterned(try sema.fieldTypeByName(block, src, ty, sema.zirString(extra.name_start)));
        },
        .struct_init_field_ptr => blk: {
            const extra = sema.code.extraData(Zir.Inst.Field, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const ptr = sema.resolveInst(extra.lhs);
            const name = sema.zirString(extra.field_name_start);
            const child = Type.ptrInfo(sema.ip, sema.typeOf(ptr)).child;
            if (sema.ip.indexToKey(child) == .union_type) {
                break :blk sema.unionFieldPtr(block, src, ptr, try sema.unionFieldIndex(block, src, child, name), true);
            }
            break :blk sema.fieldPtr(block, src, ptr, name);
        },
        .array_init, .array_init_ref, .array_init_anon => blk: {
            const val = try sema.zirArrayInit(block, inst);
            break :blk if (tag == .array_init_ref) sema.analyzeRef(block, block.nodeSrc(data.pl_node.src_node), val) else val;
        },
        .validate_array_init_ref_ty => blk: {
            const extra = sema.code.extraData(Zir.Inst.ArrayInitRefTy, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const ptr_ty = sema.unwrapOptEu(try sema.resolveType(block, src, extra.ptr_ty));
            if (ptr_ty == .generic_poison_type or Type.class(sema.ip, ptr_ty) != .pointer) break :blk .fromInterned(.generic_poison_type);
            const p = Type.ptrInfo(sema.ip, ptr_ty);
            if (p.flags.size == .one) break :blk .fromInterned(p.child);
            break :blk .fromInterned(try sema.intern(.{ .array_type = .{ .len = extra.elem_count, .child = p.child, .sentinel = p.sentinel } }));
        },
        .array_init_elem_type => blk: {
            const ty = try sema.resolveType(block, block.nodeSrc(.zero), data.bin.lhs);
            if (ty == .generic_poison_type) break :blk .fromInterned(.generic_poison_type);
            const idx: usize = @backingInt(data.bin.rhs);
            break :blk .fromInterned(switch (sema.ip.indexToKey(ty)) {
                .array_type => |a| a.child,
                .vector_type => |v| v.child,
                .tuple_type => |t| t.types[idx],
                .struct_type => sema.ip.structInfo(ty).field_types[idx],
                else => .generic_poison_type,
            });
        },
        .array_init_elem_ptr => blk: {
            const extra = sema.code.extraData(Zir.Inst.ElemPtrImm, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const index: Ref = .fromInterned(try sema.intValue(.usize_type, extra.index));
            const ptr = sema.resolveInst(extra.ptr);
            if (sema.isBoolVectorPtr(sema.typeOf(ptr)) and sema.resolveValue(ptr) == null) {
                const gop = try sema.bool_vector_inits.getOrPut(sema.arena, ptr);
                if (!gop.found_existing) {
                    const len = sema.vectorLen(Type.ptrInfo(sema.ip, sema.typeOf(ptr)).child).?;
                    gop.value_ptr.* = try sema.analyzeAlloc(block, src, try sema.intern(.{ .array_type = .{ .len = len, .child = .bool_type } }), false, false);
                }
                break :blk sema.elemPtr(block, src, gop.value_ptr.*, index, false);
            }
            break :blk sema.elemPtr(block, src, ptr, index, false);
        },
        .opt_eu_base_ptr_init => sema.zirOptEuBasePtrInit(block, inst),
        .coerce_ptr_elem_ty => blk: {
            const ip = sema.ip;
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const operand = sema.resolveInst(extra.rhs);
            var ptr_ty = try sema.resolveType(block, src, extra.lhs);
            if (ptr_ty == .generic_poison_type) break :blk operand;
            // Through `?*T` and `E!*T` result types (as upstream's `optEuBaseType`).
            while (true) ptr_ty = switch (Type.class(ip, ptr_ty)) {
                .optional => Type.childType(ip, ptr_ty),
                .error_union => ip.indexToKey(ptr_ty).error_union_type.payload_type,
                else => break,
            };
            if (Type.class(ip, ptr_ty) != .pointer) return sema.fail(block, src, "expected type '{f}', found pointer", .{sema.fmtType(ptr_ty)});
            const p = Type.ptrInfo(ip, ptr_ty);
            const operand_ty = sema.typeOf(operand);
            switch (p.flags.size) {
                .one => {
                    // `*[1]T` from `&t`, and `*anyopaque`: the pointer coerces instead.
                    if (ip.indexToKey(p.child) == .array_type and ip.indexToKey(p.child).array_type.child == operand_ty) break :blk operand;
                    if (p.child == .anyopaque_type) break :blk operand;
                    break :blk sema.coerce(block, p.child, operand, src);
                },
                .slice, .many => {
                    // `&.{...}`: coerce to an array of the element type.
                    const len: u64 = switch (ip.indexToKey(operand_ty)) {
                        .array_type => |a| a.len,
                        .tuple_type => |t| t.types.len,
                        else => return sema.fail(block, src, "expected array of '{f}', found '{f}'", .{ sema.fmtType(p.child), sema.fmtType(operand_ty) }),
                    };
                    const want = try sema.intern(.{ .array_type = .{ .len = len, .child = p.child, .sentinel = p.sentinel } });
                    break :blk sema.coerce(block, want, operand, src);
                },
                .c => break :blk operand,
            }
        },

        // Floats.
        .float_from_int => sema.zirFloatFromInt(block, inst),
        .float_cast => sema.zirFloatCast(block, inst),
        .int_from_float => blk: {
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const dest_ty = sema.unwrapOptEu(try sema.resolveType(block, src, extra.lhs));
            break :blk sema.analyzeFloatToInt(block, src, dest_ty, sema.resolveInst(extra.rhs), .truncate);
        },
        .sqrt, .sin, .cos, .tan, .exp, .exp2, .log, .log2, .log10, .floor, .ceil, .trunc, .round => sema.analyzeFloatUnary(block, block.nodeSrc(data.un_node.src_node), switch (tag) {
            .trunc => .trunc_float,
            inline .sqrt, .sin, .cos, .tan, .exp, .exp2, .log, .log2, .log10, .floor, .ceil, .round => |t| @field(Ir.Inst.Tag, @tagName(t)),
            else => unreachable,
        }, sema.resolveInst(data.un_node.operand)),
        .abs => sema.analyzeAbs(block, block.nodeSrc(data.un_node.src_node), sema.resolveInst(data.un_node.operand)),
        .mul_add => sema.zirMulAdd(block, inst),

        // Casts and type queries.
        .int_cast => sema.zirIntCast(block, inst),
        .truncate => sema.zirTruncate(block, inst),
        .bitcast => sema.zirBitCast(block, inst),
        .int_from_bool => sema.analyzeIntFromBool(block, block.nodeSrc(data.un_node.src_node), sema.resolveInst(data.un_node.operand)),
        .int_from_enum, .backing_int => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            var operand = sema.resolveInst(data.un_node.operand);
            var ty = sema.typeOf(operand);
            if (tag == .backing_int and Type.class(sema.ip, ty) != .@"enum") return sema.failUnsupported(block, src, "@backingInt of non-enum types");
            if (Type.class(sema.ip, ty) == .@"union") {
                try sema.resolveLayout(block, src, ty);
                if (sema.ip.indexToKey(sema.ip.structInfo(ty).tag_type) != .enum_type) return sema.fail(block, src, "untagged union '{f}' cannot be converted to integer", .{sema.fmtType(ty)});
                operand = try sema.unionTag(block, src, operand);
                ty = sema.typeOf(operand);
            }
            if (Type.class(sema.ip, ty) != .@"enum") return sema.fail(block, src, "expected enum or tagged union, found '{f}'", .{sema.fmtType(ty)});
            try sema.resolveLayout(block, src, ty);
            const int_ty = sema.ip.structInfo(ty).tag_type;
            if (sema.resolveValue(operand)) |v| {
                if (sema.isUndef(v)) break :blk .fromInterned(try sema.undefValue(int_ty));
                break :blk .fromInterned(sema.ip.indexToKey(v).enum_tag.int);
            }
            break :blk sema.addTyOp(block, .bitcast, int_ty, operand);
        },
        .from_backing_int_arg_ty => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            var ty = try sema.resolveType(block, src, data.un_node.operand);
            while (true) switch (sema.ip.indexToKey(ty)) {
                .opt_type => |c| ty = c,
                .error_union_type => |e| ty = e.payload_type,
                else => break,
            };
            if (ty == .generic_poison_type) break :blk .fromInterned(ty);
            if (Type.class(sema.ip, ty) != .@"enum") return sema.failUnsupported(block, src, "@fromBackingInt to non-enum types");
            try sema.resolveLayout(block, src, ty);
            break :blk .fromInterned(sema.ip.structInfo(ty).tag_type);
        },
        .enum_from_int, .from_backing_int => blk: {
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const ty = try sema.resolveType(block, src, extra.lhs);
            if (Type.class(sema.ip, ty) != .@"enum") return sema.fail(block, src, "expected enum, found '{f}'", .{sema.fmtType(ty)});
            break :blk sema.enumFromInt(block, src, ty, sema.resolveInst(extra.rhs));
        },
        .tag_name => sema.zirTagName(block, inst),
        .error_name => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const operand = try sema.coerce(block, .anyerror_type, sema.resolveInst(data.un_node.operand), src);
            if (sema.resolveValue(operand)) |v| {
                if (sema.isUndef(v)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
                break :blk .fromInterned(try sema.nameSliceValue(sema.ip.stringSlice(sema.ip.indexToKey(v).err.name)));
            }
            try sema.requireRuntime(block, src);
            break :blk sema.addUnOp(block, .error_name, operand);
        },
        .type_info => sema.zirTypeInfo(block, inst),
        .clz, .ctz, .pop_count, .byte_swap, .bit_reverse => sema.zirBitOp(block, inst, tag),
        .reduce => sema.zirReduce(block, inst),
        .shuffle => sema.zirShuffle(block, inst),
        .splat_op_result_ty => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const ty = try sema.resolveType(block, src, data.un_node.operand);
            if (ty == .generic_poison_type) break :blk .fromInterned(.generic_poison_type);
            if (Type.class(sema.ip, ty) != .array and Type.class(sema.ip, ty) != .vector) return sema.fail(block, src, "expected array or vector result type for @splat, found '{f}'", .{sema.fmtType(ty)});
            break :blk .fromInterned(Type.childType(sema.ip, ty));
        },
        .splat => blk: {
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const ty = try sema.resolveType(block, src, extra.lhs);
            if (sema.ip.indexToKey(ty) == .vector_type) {
                const v = sema.ip.indexToKey(ty).vector_type;
                const scalar = try sema.coerce(block, v.child, sema.resolveInst(extra.rhs), src);
                const elems = try sema.arena.alloc(Ref, v.len);
                @memset(elems, scalar);
                break :blk sema.aggregate(block, src, ty, elems);
            }
            if (Type.class(sema.ip, ty) != .array) return sema.fail(block, src, "expected array or vector result type for @splat, found '{f}'", .{sema.fmtType(ty)});
            const a = sema.ip.indexToKey(ty).array_type;
            const scalar = try sema.coerce(block, a.child, sema.resolveInst(extra.rhs), src);
            const elems = try sema.arena.alloc(Ref, a.lenIncludingSentinel());
            @memset(elems, scalar);
            if (a.sentinel != .none) elems[a.len] = .fromInterned(a.sentinel);
            break :blk sema.aggregate(block, src, ty, elems);
        },
        .int_from_ptr => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const operand = sema.resolveInst(data.un_node.operand);
            const ty = sema.typeOf(operand);
            if (Type.class(sema.ip, ty) != .pointer) return sema.fail(block, src, "expected pointer, found '{f}'", .{sema.fmtType(ty)});
            const ptr = if (Type.isSlice(sema.ip, ty)) try sema.slicePtr(block, operand) else operand;
            if (sema.resolveValue(ptr)) |v| if (sema.ip.indexToKey(v) == .ptr and sema.ip.indexToKey(v).ptr.base == .int)
                break :blk .fromInterned(try sema.intValue(.usize_type, sema.ip.indexToKey(v).ptr.byte_offset));
            if (block.is_comptime) return sema.fail(block, src, "unable to evaluate comptime expression: pointer address is not known until link time", .{});
            break :blk sema.addUnOp(block, .int_from_ptr, ptr);
        },
        .ptr_from_int => blk: {
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const ty = try sema.resolveType(block, src, extra.lhs);
            const operand = try sema.coerce(block, .usize_type, sema.resolveInst(extra.rhs), src);
            if (try sema.resolveDefinedValue(block, src, operand)) |v| {
                const addr = sema.ip.intValue(u64, v).?;
                // A non-null optional pointer is an `opt` around its pointer.
                if (Type.class(sema.ip, ty) == .optional) {
                    if (addr == 0) break :blk .fromInterned(try sema.intern(.{ .opt = .{ .ty = ty, .val = .none } }));
                    const ptr = try sema.intern(.{ .ptr = .{ .ty = Type.childType(sema.ip, ty), .base = .int, .byte_offset = addr } });
                    break :blk .fromInterned(try sema.intern(.{ .opt = .{ .ty = ty, .val = ptr } }));
                }
                if (addr == 0 and !Type.ptrInfo(sema.ip, ty).flags.is_allowzero and Type.ptrInfo(sema.ip, ty).flags.size != .c)
                    return sema.fail(block, src, "pointer type '{f}' does not allow address zero", .{sema.fmtType(ty)});
                break :blk .fromInterned(try sema.intern(.{ .ptr = .{ .ty = ty, .base = .int, .byte_offset = addr } }));
            }
            break :blk sema.addTyOp(block, .ptr_from_int, ty, operand);
        },
        .ptr_cast => sema.analyzePtrCast(block, inst, .{ .ptr_cast = true }),
        .size_of, .bit_size_of => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const ty = try sema.resolveType(block, src, data.un_node.operand);
            try sema.resolveLayout(block, src, ty);
            const size = if (Type.hasRuntimeBits(sema.ip, ty)) Type.abiSize(sema.ip, ty) else 0;
            const bits = if (tag == .size_of) size else if (Type.isInt(sema.ip, ty)) Type.intInfo(sema.ip, ty).bits else if (ty == .bool_type) 1 else if (Type.class(sema.ip, ty) == .float) Type.floatBits(sema.ip, ty) else size * 8;
            break :blk .fromInterned(try sema.intValue(.comptime_int_type, bits));
        },
        .align_of => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const ty = try sema.resolveType(block, src, data.un_node.operand);
            try sema.resolveLayout(block, src, ty);
            break :blk .fromInterned(try sema.intValue(.comptime_int_type, Type.abiAlignment(sema.ip, ty)));
        },
        .has_decl => sema.zirHasDecl(block, inst),
        .has_field => blk: {
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const ty = try sema.resolveType(block, src, extra.lhs);
            const name = try sema.resolveConstString(block, src, sema.resolveInst(extra.rhs));
            const ip = sema.ip;
            break :blk .fromInterned(boolValue(switch (ip.indexToKey(ty)) {
                .struct_type => has: {
                    try sema.resolveStructFields(block, src, ty);
                    break :has ip.structInfo(ty).fieldIndex(ip, name) != null;
                },
                .union_type, .enum_type => has: {
                    try sema.resolveLayout(block, src, ty);
                    break :has ip.structInfo(ty).fieldIndex(ip, name) != null;
                },
                .tuple_type => |t| has: {
                    if (t.names.len != 0) {
                        for (t.names) |n| if (std.mem.eql(u8, ip.stringSlice(n), name)) break :has true;
                        break :has false;
                    }
                    const i = std.fmt.parseInt(u32, name, 10) catch break :has false;
                    break :has i < t.types.len;
                },
                else => return sema.fail(block, src, "type '{f}' does not support '@hasField'", .{sema.fmtType(ty)}),
            }));
        },
        else => sema.failUnsupported(block, block.nodeSrc(.zero), @tagName(tag)),
    };
}

fn zirExtended(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ext = sema.code.instructions.items(.data)[@backingInt(inst)].extended;
    return switch (ext.opcode) {
        .struct_decl => sema.zirContainerDecl(block, inst, .@"struct"),
        .enum_decl => sema.zirContainerDecl(block, inst, .@"enum"),
        .union_decl => sema.zirContainerDecl(block, inst, .@"union"),
        .opaque_decl => sema.zirContainerDecl(block, inst, .@"opaque"),
        .this => blk: {
            const ns = sema.zcu.namespacePtr(block.namespace);
            break :blk .fromInterned(ns.owner_type);
        },
        .closure_get => blk: {
            const ns = sema.zcu.namespacePtr(block.namespace);
            const captures = sema.ip.containerType(ns.owner_type).?.captures;
            break :blk .fromInterned(captures[ext.small]);
        },
        .@"asm", .asm_expr => sema.zirAsm(block, inst),
        .tuple_decl => blk: {
            // `struct { T, U = init }`: fields with an init are comptime.
            const extra = sema.code.extraData(Zir.Inst.TupleDecl, ext.operand);
            const src = block.nodeSrc(extra.data.src_node);
            const refs: []const Zir.Inst.Ref = @ptrCast(sema.code.extra[extra.end..][0 .. 2 * @as(usize, ext.small)]);
            const types = try sema.arena.alloc(Index, ext.small);
            const values = try sema.arena.alloc(Index, ext.small);
            for (types, values, 0..) |*t, *v, k| {
                t.* = try sema.resolveType(block, src, refs[2 * k]);
                if (Type.class(sema.ip, t.*) == .@"opaque") return sema.fail(block, src, "opaque types have unknown size and therefore cannot be directly embedded in tuples", .{});
                v.* = .none;
                if (refs[2 * k + 1] != .none) {
                    const init = try sema.coerce(block, t.*, sema.resolveInst(refs[2 * k + 1]), src);
                    v.* = (try sema.resolveDefinedValue(block, src, init)) orelse
                        return sema.fail(block, src, "unable to resolve comptime value: tuple field default value must be comptime-known", .{});
                }
            }
            break :blk .fromInterned(try sema.intern(.{ .tuple_type = .{ .types = types, .values = values } }));
        },
        .alloc => blk: {
            const extra = sema.code.extraData(Zir.Inst.AllocExtended, ext.operand);
            const small: Zir.Inst.AllocExtended.Small = @bitCast(ext.small);
            const src = block.nodeSrc(extra.data.src_node);
            // Only the type's own alignment, which needs no other pointer
            // type, is supported.
            const alignment: u64 = if (small.has_align) blk2: {
                const align_ref = try sema.coerce(block, .u29_type, sema.resolveInst(@fromBackingInt(sema.code.extra[extra.end + @intFromBool(small.has_type)])), src);
                break :blk2 sema.ip.intValue(u64, try sema.resolveConstValue(block, src, align_ref, "alignment must be comptime-known")).?;
            } else 0;
            if (!small.has_type) {
                const ref = try sema.allocInferred(block, small.is_const, small.is_comptime);
                if (alignment != 0) {
                    const ia = sema.inferred_allocs.getPtr(ref.toIndex() orelse return sema.failUnsupported(block, src, "aligned comptime variables")).?;
                    ia.alignment = alignment;
                }
                break :blk ref;
            }
            const ty = try sema.resolveType(block, src, @fromBackingInt(sema.code.extra[extra.end]));
            if (alignment != 0) {
                try sema.resolveLayout(block, src, ty);
                if (alignment != Type.abiAlignment(sema.ip, ty)) return sema.failUnsupported(block, src, "local variables aligned differently from their type");
            }
            break :blk sema.analyzeAlloc(block, src, ty, small.is_const, small.is_comptime);
        },
        .select => sema.zirSelect(block, ext),
        .min_multi, .max_multi => blk: {
            const extra = sema.code.extraData(Zir.Inst.NodeMultiOp, ext.operand);
            const refs = sema.code.refSlice(extra.end, ext.small);
            const operands = try sema.arena.alloc(Ref, refs.len);
            for (operands, refs) |*o, r| o.* = sema.resolveInst(r);
            break :blk sema.analyzeMinMax(block, block.nodeSrc(extra.data.src_node), if (ext.opcode == .min_multi) .min else .max, operands);
        },
        .add_with_overflow, .sub_with_overflow, .mul_with_overflow => blk: {
            const extra = sema.code.extraData(Zir.Inst.BinNode, ext.operand).data;
            const src = block.nodeSrc(extra.node);
            break :blk sema.analyzeOverflowBuiltin(block, src, ext.opcode, sema.resolveInst(extra.lhs), sema.resolveInst(extra.rhs));
        },
        .shl_with_overflow => blk: {
            const extra = sema.code.extraData(Zir.Inst.BinNode, ext.operand).data;
            break :blk sema.analyzeShlWithOverflow(block, block.nodeSrc(extra.node), sema.resolveInst(extra.lhs), sema.resolveInst(extra.rhs));
        },
        .std_lang_value => blk: {
            const which: Zir.Inst.StdLangValue = @fromBackingInt(ext.small);
            const src = block.nodeSrc(@fromBackingInt(@as(i32, @bitCast(ext.operand))));
            break :blk switch (which) {
                .calling_convention => .fromInterned(.calling_convention_type),
                .clobbers => .fromInterned(.clobbers_type),
                .calling_convention_c => .fromInterned(try sema.intern(.{ .calling_convention = .c })),
                .calling_convention_inline => .fromInterned(try sema.intern(.{ .calling_convention = .@"inline" })),
                .spirv_type_options => sema.fail(block, src, "zap does not support std.lang.{s}", .{@tagName(which)}),
                else => sema.stdLangDecl(block, src, switch (which) {
                    .atomic_order => "AtomicOrder",
                    .atomic_rmw_op => "AtomicRmwOp",
                    .address_space => "AddressSpace",
                    .float_mode => "FloatMode",
                    .signedness => "Signedness",
                    .reduce_op => "ReduceOp",
                    .call_modifier => "CallModifier",
                    .prefetch_options => "PrefetchOptions",
                    .export_options => "ExportOptions",
                    .extern_options => "ExternOptions",
                    .branch_hint => "BranchHint",
                    .pointer_size => "Type.Pointer.Size",
                    .pointer_attributes => "Type.Pointer.Attributes",
                    .fn_attributes => "Type.Fn.Attributes",
                    .container_layout => "Type.ContainerLayout",
                    .enum_mode => "Type.Enum.Mode",
                    else => unreachable,
                }),
            };
        },
        .inplace_arith_result_ty => blk: {
            const lhs = sema.resolveInst(@fromBackingInt(ext.operand));
            const ty = sema.typeOf(lhs);
            break :blk .fromInterned(if (Type.class(sema.ip, ty) == .pointer) .usize_type else ty);
        },
        .round_op => blk: {
            const extra = sema.code.extraData(Zir.Inst.BinNode, ext.operand).data;
            const src = block.nodeSrc(extra.node);
            const operand = sema.resolveInst(extra.rhs);
            const op: Ir.Inst.Tag, const mode: IntFromFloatMode = switch (@as(Zir.Inst.RoundOp, @fromBackingInt(@intCast(ext.small)))) {
                .round => .{ .round, .round },
                .floor => .{ .floor, .floor },
                .ceil => .{ .ceil, .ceil },
                .trunc => .{ .trunc_float, .truncate },
            };
            const raw_ty = try sema.resolveType(block, src, extra.lhs);
            if (raw_ty == .generic_poison_type) break :blk sema.analyzeFloatUnary(block, src, op, operand);
            const dest_ty = sema.unwrapOptEu(raw_ty);
            const oc = Type.class(sema.ip, sema.typeOf(operand));
            if (oc != .float and oc != .comptime_float) return sema.fail(block, src, "expected float or vector type, found '{f}'", .{sema.fmtType(sema.typeOf(operand))});
            break :blk switch (Type.class(sema.ip, dest_ty)) {
                .float, .comptime_float => sema.analyzeFloatUnary(block, src, op, try sema.coerce(block, dest_ty, operand, src)),
                .int, .comptime_int => sema.analyzeFloatToInt(block, src, dest_ty, operand, mode),
                else => sema.fail(block, src, "expected integer, float, or vector of either integers or floats, found '{f}'", .{sema.fmtType(dest_ty)}),
            };
        },
        .round_op_ty => blk: {
            const extra = sema.code.extraData(Zir.Inst.UnNode, ext.operand).data;
            const src = block.nodeSrc(extra.node);
            const ty = sema.unwrapOptEu(try sema.resolveType(block, src, extra.operand));
            if (ty == .generic_poison_type) break :blk .fromInterned(ty);
            break :blk .fromInterned(switch (Type.class(sema.ip, ty)) {
                .float, .comptime_float => ty,
                else => .generic_poison_type,
            });
        },
        .float_op_result_ty => blk: {
            const extra = sema.code.extraData(Zir.Inst.UnNode, ext.operand).data;
            const src = block.nodeSrc(extra.node);
            const ty = sema.unwrapOptEu(try sema.resolveType(block, src, extra.operand));
            if (ty == .generic_poison_type) break :blk .fromInterned(ty);
            switch (Type.class(sema.ip, Type.scalarType(sema.ip, ty))) {
                .float, .comptime_float => {},
                else => return sema.fail(block, src, "expected vector of floats or float type, found '{f}'", .{sema.fmtType(ty)}),
            }
            break :blk .fromInterned(ty);
        },
        .in_comptime => .fromInterned(boolValue(block.is_comptime)),
        // Instrumentation and intrinsics are not something zap emits.
        .disable_instrumentation, .disable_intrinsics => .void_value,
        .reify_pointer_sentinel_ty => blk: {
            const extra = sema.code.extraData(Zir.Inst.UnNode, ext.operand).data;
            const elem_ty = try sema.resolveType(block, block.nodeSrc(extra.node), extra.operand);
            // Opaque and null children cannot be optional; their sentinel is `?noreturn`.
            break :blk .fromInterned(switch (Type.class(sema.ip, elem_ty)) {
                .@"opaque", .null => try sema.optType(.noreturn_type),
                else => try sema.optType(elem_ty),
            });
        },
        .reify_pointer => sema.zirReifyPointer(block, ext),
        .reify_struct => sema.zirReifyContainer(block, inst, ext, .@"struct"),
        .reify_union => sema.zirReifyContainer(block, inst, ext, .@"union"),
        .reify_enum => sema.zirReifyContainer(block, inst, ext, .@"enum"),
        .reify_slice_arg_ty => blk: {
            // `@Struct` and friends take their per-field arguments as
            // arrays as long as the field names.
            const extra = sema.code.extraData(Zir.Inst.UnNode, ext.operand).data;
            const src = block.nodeSrc(extra.node);
            const info: Zir.Inst.ReifySliceArgInfo = @fromBackingInt(@intCast(ext.small));
            const in_ty: Index, const out_ty: Index = switch (info) {
                .type_to_fn_param_attrs => .{ .type_type, try sema.stdLangType(block, src, "Type.Fn.ParamAttributes") },
                .string_to_struct_field_type, .string_to_union_field_type => .{ .slice_const_u8_type, .type_type },
                .string_to_struct_field_attrs => .{ .slice_const_u8_type, try sema.stdLangType(block, src, "Type.Struct.FieldAttributes") },
                .string_to_union_field_attrs => .{ .slice_const_u8_type, try sema.stdLangType(block, src, "Type.Union.FieldAttributes") },
            };
            const operand = try sema.coerce(block, try sema.ptrType(.{ .child = in_ty, .flags = .{ .size = .slice, .is_const = true } }), sema.resolveInst(extra.operand), src);
            const len = (try sema.constSliceElems(block, src, operand, "reified type arguments must be comptime-known")).len;
            break :blk .fromInterned(try sema.ptrType(.{ .child = try sema.intern(.{ .array_type = .{ .len = len, .child = out_ty } }), .flags = .{ .is_const = true } }));
        },
        .reify_enum_value_slice_ty => blk: {
            const extra = sema.code.extraData(Zir.Inst.BinNode, ext.operand).data;
            const src = block.nodeSrc(extra.node);
            const tag_ty = try sema.resolveType(block, src, extra.lhs);
            const names = try sema.coerce(block, .slice_const_slice_const_u8_type, sema.resolveInst(extra.rhs), src);
            const len = (try sema.constSliceElems(block, src, names, "enum field names must be comptime-known")).len;
            break :blk .fromInterned(try sema.ptrType(.{ .child = try sema.intern(.{ .array_type = .{ .len = len, .child = tag_ty } }), .flags = .{ .is_const = true } }));
        },
        .reify_tuple => blk: {
            const extra = sema.code.extraData(Zir.Inst.UnNode, ext.operand).data;
            const src = block.nodeSrc(extra.node);
            const types = try sema.constSliceElems(block, src, try sema.coerce(block, .slice_const_type_type, sema.resolveInst(extra.operand), src), "tuple field types must be comptime-known");
            for (types) |t| if (sema.isUndef(t)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
            const values = try sema.arena.alloc(Index, types.len);
            @memset(values, .none);
            break :blk .fromInterned(try sema.intern(.{ .tuple_type = .{ .types = types, .values = values } }));
        },
        .ptr_cast_full => blk: {
            const flags: Zir.Inst.FullPtrCastFlags = @bitCast(@as(u5, @truncate(ext.small)));
            break :blk sema.analyzePtrCast(block, inst, flags);
        },
        .ptr_cast_no_dest => blk: {
            const extra = sema.code.extraData(Zir.Inst.UnNode, ext.operand).data;
            const src = block.nodeSrc(extra.node);
            const ip = sema.ip;
            const operand = sema.resolveInst(extra.operand);
            const operand_ty = sema.typeOf(operand);
            const is_opt = Type.class(ip, operand_ty) == .optional;
            const ptr_ty = if (is_opt) Type.childType(ip, operand_ty) else operand_ty;
            if (Type.class(ip, ptr_ty) != .pointer) return sema.fail(block, src, "expected pointer type, found '{f}'", .{sema.fmtType(operand_ty)});
            var info = Type.ptrInfo(ip, ptr_ty);
            const flags: Zir.Inst.FullPtrCastFlags = @bitCast(@as(u5, @truncate(ext.small)));
            if (flags.const_cast) info.flags.is_const = false;
            if (flags.volatile_cast) info.flags.is_volatile = false;
            const dest_ptr_ty = try sema.ptrType(info);
            if (!is_opt) break :blk sema.coercePtrTo(block, operand, dest_ptr_ty);
            const dest_ty = try sema.optType(dest_ptr_ty);
            if (sema.resolveValue(operand)) |v| break :blk switch (ip.indexToKey(v)) {
                .opt => |o| .fromInterned(try sema.intern(.{ .opt = .{
                    .ty = dest_ty,
                    .val = if (o.val == .none) .none else (try sema.coercePtrTo(block, .fromInterned(o.val), dest_ptr_ty)).toInterned().?,
                } })),
                else => .fromInterned(try sema.undefValue(dest_ty)),
            };
            try sema.requireRuntime(block, src);
            break :blk sema.addTyOp(block, .bitcast, dest_ty, operand);
        },
        .typeof_peer => blk: {
            const extra = sema.code.extraData(Zir.Inst.TypeOfPeer, ext.operand);
            const src = block.nodeSrc(extra.data.src_node);
            const body = sema.code.bodySlice(extra.data.body_index, extra.data.body_len);
            var child = block.child();
            defer child.instructions.deinit(sema.gpa);
            child.is_comptime = block.is_comptime;
            _ = try sema.analyzeInlineBody(&child, body, inst);
            const refs = try sema.arena.alloc(Ref, ext.small);
            for (refs, 0..) |*r, k| r.* = sema.resolveInst(@fromBackingInt(sema.code.extra[extra.end + k]));
            break :blk .fromInterned(try sema.resolvePeerTypes(block, src, refs));
        },
        .builtin_src, .ret_addr, .frame_address, .error_return_trace => sema.failUnsupported(block, block.nodeSrc(.zero), @tagName(ext.opcode)),
        else => sema.failUnsupported(block, block.nodeSrc(.zero), @tagName(ext.opcode)),
    };
}

// ---------------------------------------------------------------------------
// Declarations, imports, and type declarations

fn stdLangType(sema: *Sema, block: *Block, src: Src, path: []const u8) CompileError!Index {
    const ty = try sema.resolveConstValue(block, src, try sema.stdLangDecl(block, src, path), "std.lang declarations are comptime-known");
    try sema.resolveLayout(block, src, ty);
    return ty;
}

/// A value of struct `ty` from field name/value pairs; other fields take
/// their defaults.
fn structValue(sema: *Sema, block: *Block, src: Src, ty: Index, fields: []const struct { []const u8, Index }) CompileError!Index {
    const ip = sema.ip;
    try sema.resolveLayout(block, src, ty);
    const info = ip.structInfo(ty);
    const elems = try sema.arena.alloc(Index, info.field_types.len);
    @memcpy(elems, info.field_defaults);
    for (fields) |f| elems[info.fieldIndex(ip, f[0]).?] = f[1];
    for (elems) |e| assert(e != .none);
    return sema.intern(.{ .aggregate = .{ .ty = ty, .storage = .{ .elems = elems } } });
}

/// A value of union `ty` with field `name` active.
fn unionValue(sema: *Sema, block: *Block, src: Src, ty: Index, name: []const u8, val: Index) CompileError!Index {
    const i = try sema.unionFieldIndex(block, src, ty, name);
    return sema.intern(.{ .un = .{ .ty = ty, .tag = try sema.unionFieldTagValue(ty, i), .val = val } });
}

/// The value of enum `ty`'s field `name`.
fn enumValueByName(sema: *Sema, block: *Block, src: Src, ty: Index, name: []const u8) CompileError!Index {
    const i = (try sema.enumFieldIndex(block, src, ty, name)) orelse unreachable;
    return sema.enumTagValue(ty, i);
}

/// A `[]const T` slice value of comptime-known elements.
fn sliceValue(sema: *Sema, elem_ty: Index, elems: []const Index) !Index {
    const array_ty = try sema.intern(.{ .array_type = .{ .len = elems.len, .child = elem_ty } });
    const array = try sema.intern(.{ .aggregate = .{ .ty = array_ty, .storage = .{ .elems = elems } } });
    const many_ty = try sema.ptrType(.{ .child = elem_ty, .flags = .{ .size = .many, .is_const = true } });
    const slice_ty = try sema.ptrType(.{ .child = elem_ty, .flags = .{ .size = .slice, .is_const = true } });
    const ptr = try sema.intern(.{ .ptr = .{ .ty = many_ty, .base = .{ .uav = .{ .val = array, .orig_ty = many_ty } } } });
    return sema.intern(.{ .slice = .{ .ty = slice_ty, .ptr = ptr, .len = try sema.intValue(.usize_type, elems.len) } });
}

/// A `[]const [:0]const u8` of names.
fn namesValue(sema: *Sema, names: []const InternPool.String) !Index {
    const elems = try sema.arena.alloc(Index, names.len);
    for (names, elems) |n, *e| e.* = try sema.nameSliceValue(sema.ip.stringSlice(n));
    return sema.sliceValue(.slice_const_u8_sentinel_0_type, elems);
}

/// `?*const anyopaque` pointing to a copy of `val`, or null.
fn optRefValue(sema: *Sema, val: Index) !Index {
    const ptr_ty = try sema.ptrType(.{ .child = .anyopaque_type, .flags = .{ .is_const = true } });
    const opt_ty = try sema.optType(ptr_ty);
    if (val == .none) return sema.intern(.{ .opt = .{ .ty = opt_ty, .val = .none } });
    const orig_ty = try sema.ptrType(.{ .child = sema.ip.typeOf(val), .flags = .{ .is_const = true } });
    const ptr = try sema.intern(.{ .ptr = .{ .ty = ptr_ty, .base = .{ .uav = .{ .val = val, .orig_ty = orig_ty } } } });
    return sema.intern(.{ .opt = .{ .ty = opt_ty, .val = ptr } });
}

fn optValue(sema: *Sema, child_ty: Index, val: Index) !Index {
    return sema.intern(.{ .opt = .{ .ty = try sema.optType(child_ty), .val = val } });
}

/// `decl_names` of `@typeInfo`: the public declarations of a namespace.
/// Observing all of them is a dependency on the namespace's name list.
fn declNamesValue(sema: *Sema, ns_index: u32) !Index {
    const ip = sema.ip;
    try sema.declareDependency(.{ .namespace = ns_index });
    var names: std.ArrayList(InternPool.String) = .empty;
    const ns = sema.zcu.namespacePtr(ns_index);
    for (ns.decls.values()) |nav| {
        if (ip.getNav(nav).is_pub) try names.append(sema.arena, ip.getNav(nav).name);
    }
    return sema.namesValue(names.items);
}

fn zirTypeInfo(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ip = sema.ip;
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].un_node;
    const src = block.nodeSrc(data.src_node);
    const ty = try sema.resolveType(block, src, data.operand);
    const info_ty = try sema.stdLangType(block, src, "Type");
    try sema.resolveLayout(block, src, ty);
    const S = struct { []const u8, Index };
    const class = Type.class(ip, ty);
    const payload: Index = switch (class) {
        .type, .void, .bool, .noreturn, .comptime_float, .comptime_int, .undefined, .null, .enum_literal => .void_value,
        .int => try sema.structValue(block, src, try sema.stdLangType(block, src, "Type.Int"), &[_]S{
            .{ "signedness", try sema.enumValueByName(block, src, try sema.stdLangType(block, src, "Signedness"), @tagName(Type.intInfo(ip, ty).signedness)) },
            .{ "bits", try sema.intValue(.u16_type, Type.intInfo(ip, ty).bits) },
        }),
        .float => try sema.structValue(block, src, try sema.stdLangType(block, src, "Type.Float"), &[_]S{
            .{ "bits", try sema.intValue(.u16_type, Type.floatBits(ip, ty)) },
        }),
        .pointer => blk: {
            const p = Type.ptrInfo(ip, ty);
            const as_ty = try sema.stdLangType(block, src, "AddressSpace");
            const attrs = try sema.structValue(block, src, try sema.stdLangType(block, src, "Type.Pointer.Attributes"), &[_]S{
                .{ "const", boolValue(p.flags.is_const) },
                .{ "volatile", boolValue(p.flags.is_volatile) },
                .{ "allowzero", boolValue(p.flags.is_allowzero) },
                .{ "addrspace", try sema.optValue(as_ty, try sema.enumValueByName(block, src, as_ty, "generic")) },
                .{ "align", try sema.optValue(.usize_type, if (p.flags.alignment == 0) .none else try sema.intValue(.usize_type, @as(u64, 1) << @intCast(p.flags.alignment - 1))) },
            });
            break :blk try sema.structValue(block, src, try sema.stdLangType(block, src, "Type.Pointer"), &[_]S{
                .{ "size", try sema.enumValueByName(block, src, try sema.stdLangType(block, src, "Type.Pointer.Size"), @tagName(p.flags.size)) },
                .{ "attrs", attrs },
                .{ "child", p.child },
                .{ "sentinel_ptr", try sema.optRefValue(p.sentinel) },
            });
        },
        .array => blk: {
            const a = ip.indexToKey(ty).array_type;
            break :blk try sema.structValue(block, src, try sema.stdLangType(block, src, "Type.Array"), &[_]S{
                .{ "len", try sema.intValue(.comptime_int_type, a.len) },
                .{ "child", a.child },
                .{ "sentinel_ptr", try sema.optRefValue(a.sentinel) },
            });
        },
        .vector => try sema.structValue(block, src, try sema.stdLangType(block, src, "Type.Vector"), &[_]S{
            .{ "len", try sema.intValue(.comptime_int_type, ip.indexToKey(ty).vector_type.len) },
            .{ "child", ip.indexToKey(ty).vector_type.child },
        }),
        .optional => try sema.structValue(block, src, try sema.stdLangType(block, src, "Type.Optional"), &[_]S{
            .{ "child", Type.childType(ip, ty) },
        }),
        .error_union => blk: {
            const eu = ip.indexToKey(ty).error_union_type;
            break :blk try sema.structValue(block, src, try sema.stdLangType(block, src, "Type.ErrorUnion"), &[_]S{
                .{ "error_set", eu.error_set_type },
                .{ "payload", eu.payload_type },
            });
        },
        .error_set => blk: {
            const names = try sema.errorSetNames(block, src, ty);
            const names_ty = try sema.ptrType(.{ .child = .slice_const_u8_sentinel_0_type, .flags = .{ .size = .slice, .is_const = true } });
            break :blk try sema.structValue(block, src, try sema.stdLangType(block, src, "Type.ErrorSet"), &[_]S{
                .{ "error_names", try sema.optValue(names_ty, if (names) |n| try sema.namesValue(n) else .none) },
            });
        },
        .@"enum" => blk: {
            const info = ip.structInfo(ty);
            const vals = try sema.arena.alloc(Index, info.field_defaults.len);
            for (vals, info.field_defaults) |*v, d| {
                var space: [2]std.math.big.Limb = undefined;
                v.* = try sema.bigToValue(.comptime_int_type, ip.intToBig(d, &space));
            }
            break :blk try sema.structValue(block, src, try sema.stdLangType(block, src, "Type.Enum"), &[_]S{
                .{ "tag_type", info.tag_type },
                .{ "mode", try sema.enumValueByName(block, src, try sema.stdLangType(block, src, "Type.Enum.Mode"), if (info.nonexhaustive) "nonexhaustive" else "exhaustive") },
                .{ "field_names", try sema.namesValue(info.field_names) },
                .{ "field_values", try sema.sliceValue(.comptime_int_type, vals) },
                .{ "decl_names", try sema.declNamesValue(info.namespace) },
            });
        },
        .@"struct", .tuple => blk: {
            const is_tuple = class == .tuple and ip.indexToKey(ty).tuple_type.names.len == 0;
            const n = Type.fieldCount(ip, ty);
            const attrs_ty = try sema.stdLangType(block, src, "Type.Struct.FieldAttributes");
            const names = try sema.arena.alloc(InternPool.String, n);
            const types = try sema.arena.alloc(Index, n);
            const attrs = try sema.arena.alloc(Index, n);
            for (0..n) |i| {
                types[i] = Type.fieldType(ip, ty, i);
                var is_comptime = false;
                var default: Index = .none;
                if (class == .tuple) {
                    const t = ip.indexToKey(ty).tuple_type;
                    names[i] = if (is_tuple) try sema.getString(try std.fmt.allocPrint(sema.arena, "{d}", .{i})) else t.names[i];
                    default = t.values[i];
                    is_comptime = default != .none;
                } else {
                    names[i] = ip.structInfo(ty).field_names[i];
                    default = ip.structInfo(ty).field_defaults[i];
                }
                attrs[i] = try sema.structValue(block, src, attrs_ty, &[_]S{
                    .{ "comptime", boolValue(is_comptime) },
                    .{ "default_value_ptr", try sema.optRefValue(default) },
                });
            }
            const layout_ty = try sema.stdLangType(block, src, "Type.ContainerLayout");
            const backing: Index = if (class != .tuple and Type.isPackedStruct(ip, ty)) b: {
                try sema.resolveLayout(block, src, ty);
                break :b ip.structInfo(ty).tag_type;
            } else .none;
            break :blk try sema.structValue(block, src, try sema.stdLangType(block, src, "Type.Struct"), &[_]S{
                .{ "is_tuple", boolValue(is_tuple) },
                .{ "layout", try sema.enumValueByName(block, src, layout_ty, if (class == .tuple) "auto" else @tagName(ip.structInfo(ty).layout)) },
                .{ "backing_integer", try sema.optValue(.type_type, backing) },
                .{ "field_names", try sema.namesValue(names) },
                .{ "field_types", try sema.sliceValue(.type_type, types) },
                .{ "field_attrs", try sema.sliceValue(attrs_ty, attrs) },
                .{ "decl_names", if (class == .tuple) try sema.namesValue(&.{}) else try sema.declNamesValue(ip.structInfo(ty).namespace) },
            });
        },
        .@"union" => blk: {
            const info = ip.structInfo(ty);
            const attrs_ty = try sema.stdLangType(block, src, "Type.Union.FieldAttributes");
            const attrs = try sema.arena.alloc(Index, info.field_types.len);
            for (attrs) |*a| a.* = try sema.structValue(block, src, attrs_ty, &.{});
            const tagged = info.tag_type != .none and ip.indexToKey(info.tag_type) == .enum_type;
            break :blk try sema.structValue(block, src, try sema.stdLangType(block, src, "Type.Union"), &[_]S{
                .{ "layout", try sema.enumValueByName(block, src, try sema.stdLangType(block, src, "Type.ContainerLayout"), @tagName(info.layout)) },
                .{ "tag_type", try sema.optValue(.type_type, if (tagged) info.tag_type else .none) },
                .{ "backing_integer", try sema.optValue(.type_type, if (info.layout == .@"packed") info.tag_type else .none) },
                .{ "field_names", try sema.namesValue(info.field_names) },
                .{ "field_types", try sema.sliceValue(.type_type, info.field_types) },
                .{ "field_attrs", try sema.sliceValue(attrs_ty, attrs) },
                .{ "decl_names", try sema.declNamesValue(info.namespace) },
            });
        },
        .@"opaque" => blk: {
            if (ty == .anyopaque_type) break :blk try sema.structValue(block, src, try sema.stdLangType(block, src, "Type.Opaque"), &[_]S{.{ "decl_names", try sema.namesValue(&.{}) }});
            break :blk try sema.structValue(block, src, try sema.stdLangType(block, src, "Type.Opaque"), &[_]S{
                .{ "decl_names", try sema.declNamesValue(ip.structInfo(ty).namespace) },
            });
        },
        .@"fn" => blk: {
            const f = ip.indexToKey(ty).func_type;
            const opt_type = try sema.optType(.type_type);
            const pattrs_ty = try sema.stdLangType(block, src, "Type.Fn.ParamAttributes");
            const ptypes = try sema.arena.alloc(Index, f.param_types.len);
            const pattrs = try sema.arena.alloc(Index, f.param_types.len);
            var is_generic = f.is_generic;
            for (f.param_types, ptypes, pattrs, 0..) |pt, *t, *a, i| {
                const generic = pt == .generic_poison_type;
                if (generic or (i < 32 and (f.comptime_bits >> @intCast(i)) & 1 != 0) or (!generic and Type.isComptimeOnly(ip, pt))) is_generic = true;
                t.* = try sema.intern(.{ .opt = .{ .ty = opt_type, .val = if (generic) .none else pt } });
                a.* = try sema.structValue(block, src, pattrs_ty, &[_]S{.{ "noalias", boolValue(i < 32 and (f.noalias_bits >> @intCast(i)) & 1 != 0) }});
            }
            const ret_generic = f.return_type == .generic_poison_type;
            if (ret_generic or Type.isComptimeOnly(ip, f.return_type)) is_generic = true;
            const cc_ty = try sema.stdLangType(block, src, "CallingConvention");
            const cc = try sema.stdCallingConvention(block, src, cc_ty, f.cc);
            const attrs = try sema.structValue(block, src, try sema.stdLangType(block, src, "Type.Fn.Attributes"), &[_]S{
                .{ "callconv", cc },
                .{ "varargs", boolValue(f.is_var_args) },
            });
            break :blk try sema.structValue(block, src, try sema.stdLangType(block, src, "Type.Fn"), &[_]S{
                .{ "attrs", attrs },
                .{ "is_generic", boolValue(is_generic) },
                .{ "return_type", try sema.intern(.{ .opt = .{ .ty = opt_type, .val = if (ret_generic) .none else f.return_type } }) },
                .{ "param_types", try sema.sliceValue(opt_type, ptypes) },
                .{ "param_attrs", try sema.sliceValue(pattrs_ty, pattrs) },
            });
        },
        else => return sema.fail(block, src, "zap does not support @typeInfo of '{f}' yet", .{sema.fmtType(ty)}),
    };
    return .fromInterned(try sema.unionValue(block, src, info_ty, if (class == .tuple) "struct" else @tagName(class), payload));
}

fn zirBitOp(sema: *Sema, block: *Block, inst: Zir.Inst.Index, tag: Zir.Inst.Tag) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].un_node;
    return sema.analyzeBitOp(block, block.nodeSrc(data.src_node), tag, sema.resolveInst(data.operand));
}

fn analyzeBitOp(sema: *Sema, block: *Block, src: Src, tag: Zir.Inst.Tag, operand: Ref) CompileError!Ref {
    const ip = sema.ip;
    const ty = sema.typeOf(operand);
    if (sema.vectorLen(ty)) |len| return sema.vectorMap(block, src, len, .none, &.{operand}, struct {
        tag: Zir.Inst.Tag,
        fn call(o: @This(), s: *Sema, b: *Block, sr: Src, e: []const Ref) CompileError!Ref {
            return s.analyzeBitOp(b, sr, o.tag, e[0]);
        }
    }{ .tag = tag });
    if (Type.class(ip, ty) != .int) return sema.fail(block, src, "expected integer type, found '{f}'", .{sema.fmtType(ty)});
    const info = Type.intInfo(ip, ty);
    if (tag == .byte_swap and info.bits % 8 != 0) return sema.fail(block, src, "@byteSwap requires the number of bits to be evenly divisible by 8, but '{f}' has {d} bits", .{ sema.fmtType(ty), info.bits });
    const result_ty = switch (tag) {
        .byte_swap, .bit_reverse => ty,
        else => try sema.intType(.unsigned, std.math.log2_int_ceil(u17, @as(u17, info.bits) + 1)),
    };
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(result_ty));
        var space: [2]std.math.big.Limb = undefined;
        const big = ip.intToBig(v, &space);
        var m = try std.math.big.int.Managed.init(sema.arena);
        try m.ensureTwosCompCapacity(info.bits);
        var mut = m.toMutable();
        switch (tag) {
            .clz => return .fromInterned(try sema.intValue(result_ty, big.clz(info.bits))),
            .ctz => return .fromInterned(try sema.intValue(result_ty, big.ctz(info.bits))),
            .pop_count => return .fromInterned(try sema.intValue(result_ty, big.popCount(info.bits))),
            .byte_swap => mut.byteSwap(big, info.signedness, info.bits / 8),
            .bit_reverse => mut.bitReverse(big, info.signedness, info.bits),
            else => unreachable,
        }
        return .fromInterned(try sema.bigToValue(ty, mut.toConst()));
    }
    try sema.requireRuntime(block, src);
    return sema.addTyOp(block, switch (tag) {
        .clz => .clz,
        .ctz => .ctz,
        .pop_count => .popcount,
        .byte_swap => .byte_swap,
        .bit_reverse => .bit_reverse,
        else => unreachable,
    }, result_ty, operand);
}

/// zap's calling convention as a `std.lang.CallingConvention` value.
fn stdCallingConvention(sema: *Sema, block: *Block, src: Src, cc_ty: Index, cc: InternPool.CallingConvention) CompileError!Index {
    const ip = sema.ip;
    const name = switch (cc) {
        .auto => "auto",
        .c => "x86_64_sysv",
        .naked => "naked",
        .@"inline" => "inline",
    };
    const i = try sema.unionFieldIndex(block, src, cc_ty, name);
    const field_ty = ip.structInfo(cc_ty).field_types[i];
    const payload = if (field_ty == .void_type) .void_value else try sema.structValue(block, src, field_ty, &.{});
    return sema.intern(.{ .un = .{ .ty = cc_ty, .tag = try sema.unionFieldTagValue(cc_ty, i), .val = payload } });
}

/// `ty` without optional and error union wrappers: the type that a result
/// location of type `ty` initializes.
fn unwrapOptEu(sema: *Sema, ty: Index) Index {
    var t = ty;
    while (true) switch (sema.ip.indexToKey(t)) {
        .opt_type => |c| t = c,
        .error_union_type => |e| t = e.payload_type,
        else => return t,
    };
}

/// The value of `std.lang.<path>`, where `path` may be dotted.
fn stdLangDecl(sema: *Sema, block: *Block, src: Src, path: []const u8) CompileError!Ref {
    const std_file = sema.zcu.moduleRootFile(.std) orelse return sema.fail(block, src, "std.lang.{s} requires the std module", .{path});
    var cur: Ref = try sema.namespaceLookupVal(block, src, try sema.zcu.fileRootType(std_file), "lang");
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |part| {
        const container = try sema.resolveConstValue(block, src, cur, "std.lang declarations are comptime-known");
        cur = try sema.namespaceLookupVal(block, src, container, part);
    }
    return cur;
}

/// The field name of a comptime-known enum value.
fn enumTagName(sema: *Sema, val: Index) ?[]const u8 {
    const ip = sema.ip;
    const i = sema.enumTagIndex(val) orelse return null;
    return ip.stringSlice(ip.structInfo(ip.indexToKey(val).enum_tag.ty).field_names[i]);
}

fn lookupName(sema: *Sema, block: *Block, src: Src, name: []const u8) CompileError!InternPool.NavIndex {
    const name_str = try sema.getString(name);
    var ns_index = block.namespace;
    while (ns_index != Zcu.Namespace.none) {
        const ns = sema.zcu.namespacePtr(ns_index);
        try sema.declareDependency(.{ .namespace_name = .{ .namespace = ns_index, .name = name_str } });
        if (ns.decls.get(name_str)) |nav| return nav;
        ns_index = ns.parent;
    }
    return sema.fail(block, src, "use of undeclared identifier '{s}'", .{name});
}

/// Looks up a declaration of the namespace of container type `ty`.
fn lookupInType(sema: *Sema, ty: Index, name: []const u8) !?InternPool.NavIndex {
    if (sema.ip.containerType(ty) == null) return null;
    const ns_index = sema.ip.structInfo(ty).namespace;
    const name_str = try sema.getString(name);
    try sema.declareDependency(.{ .namespace_name = .{ .namespace = ns_index, .name = name_str } });
    return sema.zcu.namespacePtr(ns_index).decls.get(name_str);
}

fn zirDeclVal(sema: *Sema, block: *Block, inst: Zir.Inst.Index, is_ref: bool) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].str_tok;
    const src = block.tokSrc(data.src_tok);
    const nav = try sema.lookupName(block, src, data.get(sema.code.*));
    return if (is_ref) sema.navRef(block, src, nav) else sema.navVal(block, src, nav);
}

fn navVal(sema: *Sema, block: *Block, src: Src, nav_index: InternPool.NavIndex) CompileError!Ref {
    try sema.ensureNavVal(block, src, nav_index);
    const nav = sema.ip.getNav(nav_index);
    if (nav.is_const) return .fromInterned(nav.val);
    return sema.analyzeLoad(block, src, try sema.navRef(block, src, nav_index));
}

fn navRef(sema: *Sema, block: *Block, src: Src, nav_index: InternPool.NavIndex) CompileError!Ref {
    try sema.ensureNavVal(block, src, nav_index);
    const nav = sema.ip.getNav(nav_index);
    if (sema.ip.indexToKey(nav.val) == .func) try sema.zcu.queueFunc(nav.val);
    const ptr_ty = try sema.ptrType(.{ .child = nav.ty, .flags = .{ .is_const = nav.is_const } });
    return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = ptr_ty, .base = .{ .nav = nav_index } } }));
}

/// `@export(&decl, .{ .name = ... })`: exports a declaration under a symbol
/// name. Only the name is honored; linkage, section, and visibility are
/// those of a strong global symbol in a static executable.
fn zirExport(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!void {
    const ip = sema.ip;
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Export, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    const ptr = sema.resolveInst(extra.exported);
    const ptr_val = try sema.resolveConstValue(block, src, ptr, "export target must be comptime-known");
    const ptr_ty = ip.typeOf(ptr_val);
    if (Type.class(ip, ptr_ty) != .pointer) return sema.fail(block, src, "expected pointer type, found '{f}'", .{sema.fmtType(ptr_ty)});
    if (Type.isSlice(ip, ptr_ty)) return sema.fail(block, src, "export target cannot be slice", .{});
    const options_ty = try sema.stdLangType(block, src, "ExportOptions");
    const options = try sema.resolveConstValue(block, src, try sema.coerce(block, options_ty, sema.resolveInst(extra.options), src), "export options must be comptime-known");
    const name_val = try sema.fieldValue(options, ip.structInfo(options_ty).fieldIndex(ip, "name").?);
    const name = try sema.resolveConstString(block, src, .fromInterned(name_val));
    const nav_index = switch (ip.indexToKey(ptr_val).ptr.base) {
        .nav => |n| n,
        .uav => return sema.failUnsupported(block, src, "exporting anonymous values"),
        else => return sema.fail(block, src, "export target must be a global variable or a comptime-known constant", .{}),
    };
    try sema.ensureNavVal(block, src, nav_index);
    const val = ip.getNav(nav_index).val;
    const export_nav = switch (ip.indexToKey(val)) {
        .func => |f| f.owner_nav,
        else => nav_index,
    };
    if (ip.indexToKey(val) == .func) try sema.zcu.queueFunc(val);
    try sema.zcu.exports.append(sema.gpa, .{ .nav = export_nav, .name = try sema.getString(name) });
}

fn zirImport(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_tok;
    const extra = sema.code.extraData(Zir.Inst.Import, data.payload_index).data;
    const src = block.tokSrc(data.src_tok);
    const path = sema.zirString(extra.path);
    const fe = sema.zcu.fe;
    const this_file = sema.zcu.file(sema.file);
    const key = if (std.mem.endsWith(u8, path, ".zig")) blk: {
        const dir = std.fs.path.dirname(this_file.sub_path) orelse "";
        const sub = try std.fs.path.resolvePosix(sema.arena, &.{ dir, path });
        const key = try std.fmt.allocPrint(sema.arena, "{d}:{s}", .{ @backingInt(this_file.module), sub });
        const file_index = fe.file_map.get(key) orelse return sema.fail(block, src, "unable to find '{s}'", .{path});
        break :blk @backingInt(file_index);
    } else if (std.mem.eql(u8, path, "std"))
        sema.zcu.moduleRootFile(.std).?
    else if (std.mem.eql(u8, path, "root"))
        sema.zcu.moduleRootFile(.root).?
    else if (std.mem.eql(u8, path, "builtin"))
        sema.zcu.moduleRootFile(.builtin).?
    else
        return sema.fail(block, src, "no module named '{s}' available within module '{s}'", .{ path, fe.module(this_file.module).name });
    return .fromInterned(try sema.zcu.fileRootType(key));
}

fn zirDeclLiteral(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const tag = sema.code.instructions.items(.tag)[@backingInt(inst)];
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Field, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    const name = sema.zirString(extra.field_name_start);
    const orig_ty = try sema.resolveType(block, src, extra.lhs);
    var ty = orig_ty;
    while (true) switch (sema.ip.indexToKey(ty)) {
        .opt_type => |c| ty = c,
        .error_union_type => |e| ty = e.payload_type,
        else => break,
    };
    if (ty == .calling_convention_type) {
        const cc: InternPool.CallingConvention = if (std.mem.eql(u8, name, "c"))
            .c
        else if (std.mem.eql(u8, name, "naked"))
            .naked
        else if (std.mem.eql(u8, name, "auto"))
            .auto
        else if (std.mem.eql(u8, name, "inline"))
            .@"inline"
        else if (std.mem.eql(u8, name, "x86_64_sysv"))
            .c
        else
            return sema.fail(block, src, "zap does not support calling convention '{s}' yet", .{name});
        return .fromInterned(try sema.intern(.{ .calling_convention = cc }));
    }
    if (ty == .generic_poison_type) return sema.fail(block, src, "decl literal requires a result type", .{});
    const nav = (try sema.lookupInType(ty, name)) orelse {
        // Not a declaration: an enum literal.
        const lit: Ref = .fromInterned(try sema.intern(.{ .enum_literal = try sema.getString(name) }));
        if (tag == .decl_literal_no_coerce) return lit;
        return sema.coerce(block, orig_ty, lit, src);
    };
    const val = try sema.navVal(block, src, nav);
    if (tag == .decl_literal_no_coerce) return val;
    return sema.coerce(block, orig_ty, val, src);
}

fn zirHasDecl(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Bin, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    const ty = try sema.resolveType(block, src, extra.lhs);
    const name = try sema.resolveConstString(block, src, sema.resolveInst(extra.rhs));
    // Records exactly what was observed: whether this name exists.
    const nav = (try sema.lookupInType(ty, name)) orelse return .fromInterned(.bool_false);
    const is_visible = sema.ip.getNav(nav).is_pub or sema.ip.getNav(nav).file == sema.file;
    return .fromInterned(boolValue(is_visible));
}

fn zirContainerDecl(sema: *Sema, block: *Block, inst: Zir.Inst.Index, kind: Zcu.ContainerKind) CompileError!Ref {
    const code = sema.code;
    const src_node: Ast.Node.Index, const name_strategy: Zir.Inst.NameStrategy, const decl_captures: []const Zir.Inst.Capture = switch (kind) {
        .@"struct" => blk: {
            const d = code.getStructDecl(inst);
            break :blk .{ d.src_node, d.name_strategy, d.captures };
        },
        .@"enum" => blk: {
            const d = code.getEnumDecl(inst);
            break :blk .{ d.src_node, d.name_strategy, d.captures };
        },
        .@"union" => blk: {
            const d = code.getUnionDecl(inst);
            break :blk .{ d.src_node, d.name_strategy, d.captures };
        },
        .@"opaque" => blk: {
            const d = code.getOpaqueDecl(inst);
            break :blk .{ d.src_node, d.name_strategy, d.captures };
        },
    };
    const src: Src = .{ .base = src_node, .loc = .{ .node_abs = src_node } };
    const captures = try sema.arena.alloc(Index, decl_captures.len);
    for (decl_captures, captures) |cap, *out| {
        out.* = switch (cap.unwrap()) {
            .nested => |i| sema.ip.containerType(sema.zcu.namespacePtr(block.namespace).owner_type).?.captures[i],
            .instruction => |i| try sema.resolveConstValue(block, src, sema.resolveInst(i.toRef()), "captured value must be comptime-known"),
            .instruction_load => |i| blk: {
                const loaded = try sema.analyzeLoad(block, src, sema.resolveInst(i.toRef()));
                break :blk try sema.resolveConstValue(block, src, loaded, "captured value must be comptime-known");
            },
            .decl_val => |name| try sema.resolveConstValue(block, src, try sema.navVal(block, src, try sema.lookupName(block, src, sema.zirString(name))), "captured value must be comptime-known"),
            .decl_ref => |name| try sema.resolveConstValue(block, src, try sema.navRef(block, src, try sema.lookupName(block, src, sema.zirString(name))), "captured value must be comptime-known"),
        };
    }
    const name = try sema.typeName(block, name_strategy, inst, kind);
    const ty = try sema.zcu.createContainerType(kind, sema.file, inst, captures, name.display, name.key, block.namespace, null);
    return .fromInterned(ty);
}

const TypeName = struct {
    /// Upstream's `@typeName`.
    display: []const u8,
    /// Stable key (see "Analysis units" in docs/architecture.md).
    key: []const u8,
};

/// The names of a new type, following `strategy`.
fn typeName(sema: *Sema, block: *Block, strategy: Zir.Inst.NameStrategy, inst: Zir.Inst.Index, kind: Zcu.ContainerKind) Allocator.Error!TypeName {
    const ip = sema.ip;
    switch (strategy) {
        .parent => if (sema.owner_nav != .none and block.inlining == null) {
            const nav = ip.getNav(sema.owner_nav);
            return .{ .display = ip.stringSlice(nav.fqn), .key = ip.stringSlice(nav.key) };
        },
        .func => if (block.inlining) |inlining| {
            var aw: std.Io.Writer.Allocating = .init(sema.arena);
            const nav = ip.getNav(ip.indexToKey(inlining.func).func.owner_nav);
            const w = &aw.writer;
            w.print("{s}(", .{ip.stringSlice(nav.fqn)}) catch return error.OutOfMemory;
            var first = true;
            for (inlining.args) |arg| {
                if (arg == .none) continue;
                if (!first) w.writeAll(",") catch return error.OutOfMemory;
                first = false;
                (if (ip.isType(arg)) print.printType(ip, arg, w) else print.printValue(ip, arg, w)) catch return error.OutOfMemory;
            }
            w.writeAll(")") catch return error.OutOfMemory;
            return .{ .display = aw.written(), .key = try sema.inliningKey(inlining) };
        },
        .anon, .dbg_var => {},
    }
    const parent = sema.zcu.namespacePtr(block.namespace).fqn;
    const display = try std.fmt.allocPrint(sema.arena, "{s}__{t}_{d}", .{ parent, kind, @backingInt(inst) });
    // Keyed by the creating unit (or comptime call) and an ordinal.
    const prefix, const counter = if (block.inlining) |inlining|
        .{ try sema.inliningKey(inlining), &inlining.anon_types }
    else blk: {
        var aw: std.Io.Writer.Allocating = .init(sema.arena);
        sema.zcu.unitKey(sema.owner, &aw.writer) catch return error.OutOfMemory;
        break :blk .{ aw.written(), &sema.anon_types };
    };
    defer counter.* += 1;
    return .{ .display = display, .key = try std.fmt.allocPrint(sema.arena, "{s}#anon{d}", .{ prefix, counter.* }) };
}

/// Stable key of a comptime call: the callee's key and the stable hashes of
/// its arguments.
fn inliningKey(sema: *Sema, inlining: *const Block.Inlining) Allocator.Error![]const u8 {
    const ip = sema.ip;
    var aw: std.Io.Writer.Allocating = .init(sema.arena);
    const w = &aw.writer;
    w.print("{s}(", .{ip.stringSlice(ip.getNav(ip.indexToKey(inlining.func).func.owner_nav).key)}) catch return error.OutOfMemory;
    for (inlining.args, 0..) |arg, i| {
        if (i != 0) w.writeAll(",") catch return error.OutOfMemory;
        if (arg != .none) w.print("{x}", .{ip.stableHash(arg)}) catch return error.OutOfMemory;
    }
    w.writeAll(")") catch return error.OutOfMemory;
    return aw.written();
}

fn zirPtrType(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].ptr_type;
    const extra = sema.code.extraData(Zir.Inst.PtrType, data.payload_index);
    const src = block.nodeSrc(extra.data.src_node);
    const elem = try sema.resolveType(block, src, extra.data.elem_type);
    var i = extra.end;
    var sentinel: Index = .none;
    if (data.flags.has_sentinel) {
        const ref = sema.resolveInst(@fromBackingInt(sema.code.extra[i]));
        i += 1;
        sentinel = try sema.resolveConstValue(block, src, try sema.coerce(block, elem, ref, src), "pointer sentinel must be comptime-known");
    }
    var alignment: u6 = 0;
    if (data.flags.has_align) {
        const a = try sema.resolveInt(block, src, @fromBackingInt(sema.code.extra[i]), .u32_type, "pointer alignment must be comptime-known");
        i += 1;
        if (a == 0 or !std.math.isPowerOfTwo(a)) return sema.fail(block, src, "alignment value '{d}' is not a power of two", .{a});
        alignment = @intCast(std.math.log2_int(u64, a) + 1);
        // `*align(4) u32` is `*u32`.
        if (sema.naturalAlignment(elem) == a) alignment = 0;
    }
    if (data.flags.has_addrspace) return sema.failUnsupported(block, src, "address spaces");
    var packed_offset: InternPool.PtrType.PackedOffset = .{};
    if (data.flags.has_bit_range) {
        const bit_offset = try sema.resolveInt(block, src, @fromBackingInt(sema.code.extra[i]), .u16_type, "bit offset must be comptime-known");
        const host_size = try sema.resolveInt(block, src, @fromBackingInt(sema.code.extra[i + 1]), .u16_type, "host size must be comptime-known");
        i += 2;
        if (host_size != 0) {
            try sema.resolveLayout(block, src, elem);
            const bits = Type.packedBits(sema.ip, elem) orelse return sema.fail(block, src, "bit-pointer cannot refer to value of type '{f}'", .{sema.fmtType(elem)});
            if (bit_offset >= host_size * 8) return sema.fail(block, src, "packed type '{f}' at bit offset {d} starts {d} bits after the end of a {d} byte host integer", .{ sema.fmtType(elem), bit_offset, bit_offset - host_size * 8, host_size });
            if (bits > host_size * 8 - bit_offset) return sema.fail(block, src, "packed type '{f}' at bit offset {d} ends {d} bits after the end of a {d} byte host integer", .{ sema.fmtType(elem), bit_offset, bits - (host_size * 8 - bit_offset), host_size });
        }
        packed_offset = .{ .bit_offset = @intCast(bit_offset), .host_size = @intCast(host_size) };
    }
    return .fromInterned(try sema.ptrType(.{
        .packed_offset = packed_offset,
        .child = elem,
        .sentinel = sentinel,
        .flags = .{
            .size = data.size,
            .is_const = !data.flags.is_mutable,
            .is_volatile = data.flags.is_volatile,
            .is_allowzero = data.flags.is_allowzero,
            .alignment = alignment,
        },
    }));
}

fn stringLiteral(sema: *Sema, bytes: []const u8) !Index {
    const with_sentinel = try sema.arena.alloc(u8, bytes.len + 1);
    @memcpy(with_sentinel[0..bytes.len], bytes);
    with_sentinel[bytes.len] = 0;
    const array_ty = try sema.intern(.{ .array_type = .{ .len = bytes.len, .child = .u8_type, .sentinel = .zero_u8 } });
    const val = try sema.intern(.{ .aggregate = .{ .ty = array_ty, .storage = .{ .bytes = try sema.getString(with_sentinel) } } });
    const ptr_ty = try sema.ptrType(.{ .child = array_ty, .flags = .{ .is_const = true } });
    return sema.intern(.{ .ptr = .{ .ty = ptr_ty, .base = .{ .uav = .{ .val = val, .orig_ty = ptr_ty } } } });
}

/// The bytes of a comptime-known `[]const u8`, `*const [N]u8`, or similar.
fn resolveConstString(sema: *Sema, block: *Block, src: Src, ref: Ref) CompileError![]const u8 {
    const coerced = try sema.coerce(block, .slice_const_u8_type, ref, src);
    const val = try sema.resolveConstValue(block, src, coerced, "string must be comptime-known");
    const slice = sema.ip.indexToKey(val).slice;
    const len = sema.ip.intValue(u64, slice.len).?;
    const bytes = try sema.arena.alloc(u8, len);
    for (bytes, 0..) |*b, k| {
        const elem_ptr = try sema.ptrElemPtrVal(slice.ptr, k);
        const elem = try sema.comptimeLoad(block, src, elem_ptr);
        b.* = sema.ip.intValue(u8, elem) orelse return sema.fail(block, src, "string must be comptime-known", .{});
    }
    return bytes;
}

fn errorSetType(sema: *Sema, names: []InternPool.String) !Index {
    const ip = sema.ip;
    std.mem.sort(InternPool.String, names, ip, struct {
        fn lt(p: *InternPool, a: InternPool.String, b: InternPool.String) bool {
            return std.mem.order(u8, p.stringSlice(a), p.stringSlice(b)) == .lt;
        }
    }.lt);
    var n: usize = 0;
    for (names) |name| {
        if (n != 0 and names[n - 1] == name) continue;
        names[n] = name;
        n += 1;
    }
    return sema.intern(.{ .error_set_type = names[0..n] });
}

/// The names of an explicit error set, or null for `anyerror` and
/// inferred error sets.
/// The names in error set `ty`, or null if it is `anyerror` or not yet
/// known (the inferred error set of the function being analyzed). Resolving
/// another function's inferred error set analyzes that function's body.
fn errorSetNames(sema: *Sema, block: *Block, src: Src, ty: Index) CompileError!?[]const InternPool.String {
    return switch (sema.ip.indexToKey(ty)) {
        .error_set_type => |names| names,
        .inferred_error_set_type => |func| {
            if (func == sema.func) return null;
            try sema.declareDependency(.{ .func_ies = func });
            return sema.zcu.ensureFuncIes(func) catch |err| switch (err) {
                error.DependencyLoop => return sema.fail(block, src, "unable to resolve inferred error set", .{}),
                else => |e| return e,
            };
        },
        else => null,
    };
}

fn mergeErrorSets(sema: *Sema, block: *Block, src: Src, a: Index, b: Index) CompileError!Index {
    const an = (try sema.errorSetNames(block, src, a)) orelse return if (a == .anyerror_type) .anyerror_type else sema.failUnsupported(block, src, "merging inferred error sets");
    const bn = (try sema.errorSetNames(block, src, b)) orelse return if (b == .anyerror_type) .anyerror_type else sema.failUnsupported(block, src, "merging inferred error sets");
    const names = try sema.arena.alloc(InternPool.String, an.len + bn.len);
    @memcpy(names[0..an.len], an);
    @memcpy(names[an.len..], bn);
    return sema.errorSetType(names);
}

fn currentRetTy(sema: *Sema, block: *Block) Index {
    if (block.inlining) |inlining| return inlining.ret_ty;
    return sema.fn_ret_ty;
}

fn recordInferredErrors(sema: *Sema, block: *Block, src: Src, operand: Ref) CompileError!void {
    if (sema.func == .none) return;
    const ret = sema.ip.indexToKey(sema.fn_ret_ty);
    if (ret != .error_union_type) return;
    if (sema.ip.indexToKey(ret.error_union_type.error_set_type) != .inferred_error_set_type) return;
    const ty = sema.typeOf(operand);
    const set: Index = switch (sema.ip.indexToKey(ty)) {
        .error_set_type => ty,
        .error_union_type => |e| e.error_set_type,
        else => return,
    };
    try sema.addInferredErrors(block, src, set);
}

/// Adds the errors of `set` to the current function's inferred error set.
fn addInferredErrors(sema: *Sema, block: *Block, src: Src, set: Index) CompileError!void {
    const names = (try sema.errorSetNames(block, src, set)) orelse return;
    const gop = try sema.zcu.inferred_errors.getOrPut(sema.gpa, sema.func);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    outer: for (names) |n| {
        for (gop.value_ptr.items) |existing| if (existing == n) continue :outer;
        try gop.value_ptr.append(sema.gpa, n);
    }
}

// ---------------------------------------------------------------------------
// Coercion and peer type resolution

fn coerce(sema: *Sema, block: *Block, dest_ty: Index, inst: Ref, src: Src) CompileError!Ref {
    if (try sema.coerceInner(block, dest_ty, inst, src)) |r| return r;
    return sema.fail(block, src, "expected type '{f}', found '{f}'", .{ sema.fmtType(dest_ty), sema.fmtType(sema.typeOf(inst)) });
}

/// Returns null if `inst` does not coerce to `dest_ty`.
fn coerceInner(sema: *Sema, block: *Block, dest_ty: Index, inst: Ref, src: Src) CompileError!?Ref {
    const ip = sema.ip;
    const src_ty = sema.typeOf(inst);
    if (src_ty == dest_ty or dest_ty == .generic_poison_type) return inst;
    if (src_ty == .noreturn_type) return inst;
    if (src_ty == .undefined_type) return .fromInterned(try sema.undefValue(dest_ty));
    const val = sema.resolveValue(inst);
    const dc = Type.class(ip, dest_ty);
    const sc = Type.class(ip, src_ty);
    switch (dc) {
        .int, .comptime_int => if (sc == .int or sc == .comptime_int) {
            if (val) |v| {
                if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(dest_ty));
                if (!sema.intFits(v, dest_ty)) return sema.fail(block, src, "type '{f}' cannot represent integer value '{f}'", .{ sema.fmtType(dest_ty), sema.fmtValue(v) });
                var space: [2]std.math.big.Limb = undefined;
                return .fromInterned(try sema.bigToValue(dest_ty, ip.intToBig(v, &space)));
            }
            if (dc == .comptime_int or sc == .comptime_int) return sema.fail(block, src, "unable to resolve comptime value", .{});
            const s = Type.intInfo(ip, src_ty);
            const d = Type.intInfo(ip, dest_ty);
            const fits = if (s.signedness == d.signedness) d.bits >= s.bits else s.signedness == .unsigned and d.bits > s.bits;
            if (fits) return try sema.addTyOp(block, .intcast, dest_ty, inst);
            return null;
        } else if (sc == .float or sc == .comptime_float) {
            const v = val orelse {
                if (dc == .comptime_int) return sema.fail(block, src, "unable to resolve comptime value", .{});
                return null;
            };
            return .fromInterned(try sema.intFromFloat(block, src, v, dest_ty, .exact));
        },
        .float, .comptime_float => switch (sc) {
            .float, .comptime_float => {
                if (val) |v| {
                    if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(dest_ty));
                    const r = try sema.floatCast(v, dest_ty);
                    if (sc == .float and try sema.floatCast(r, src_ty) != v)
                        return sema.fail(block, src, "type '{f}' cannot represent float value '{f}'", .{ sema.fmtType(dest_ty), sema.fmtValue(v) });
                    return .fromInterned(r);
                }
                if (dc == .comptime_float) return sema.fail(block, src, "unable to resolve comptime value", .{});
                if (Type.floatBits(ip, dest_ty) >= Type.floatBits(ip, src_ty)) return try sema.addTyOp(block, .float_cast, dest_ty, inst);
                return null;
            },
            .int, .comptime_int => {
                const v = val orelse {
                    if (dc == .comptime_float) return sema.fail(block, src, "unable to resolve comptime value", .{});
                    const info = Type.intInfo(ip, src_ty);
                    if (info.bits - @intFromBool(info.signedness == .signed) <= Type.floatSignificandBits(ip, dest_ty))
                        return try sema.addTyOp(block, .float_from_int, dest_ty, inst);
                    return null;
                };
                if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(dest_ty));
                const r = try sema.floatValue(dest_ty, sema.toF128(v));
                // Exactly representable: the float converts back to the same integer.
                const fits = switch (ip.indexToKey(r).float.storage) {
                    inline else => |x| fits: {
                        if (!std.math.isFinite(x)) break :fits false;
                        var m: std.math.big.int.Mutable = .{ .limbs = try sema.arena.alloc(std.math.big.Limb, std.math.big.int.calcLimbLen(x)), .len = undefined, .positive = undefined };
                        if (m.setFloat(x, .nearest_even) == .inexact) break :fits false;
                        var space: [2]std.math.big.Limb = undefined;
                        break :fits m.toConst().eql(ip.intToBig(v, &space));
                    },
                };
                if (!fits) return sema.fail(block, src, "type '{f}' cannot represent integer value '{f}'", .{ sema.fmtType(dest_ty), sema.fmtValue(v) });
                return .fromInterned(r);
            },
            else => {},
        },
        .optional => {
            const child = Type.childType(ip, dest_ty);
            if (sc == .null) return .fromInterned(try sema.intern(.{ .opt = .{ .ty = dest_ty, .val = .none } }));
            if (sc == .optional) {
                // `?*T` to `?*const T` and similar.
                const s_child = Type.childType(ip, src_ty);
                if (Type.class(ip, s_child) == .pointer and Type.class(ip, child) == .pointer and sema.ptrCoercibleInPlace(s_child, child)) {
                    if (val) |v| switch (ip.indexToKey(v)) {
                        .opt => |o| {
                            const payload: Index = if (o.val == .none) .none else (try sema.coercePtrTo(block, .fromInterned(o.val), child)).toInterned().?;
                            return .fromInterned(try sema.intern(.{ .opt = .{ .ty = dest_ty, .val = payload } }));
                        },
                        else => return .fromInterned(try sema.undefValue(dest_ty)),
                    };
                    return try sema.addTyOp(block, .bitcast, dest_ty, inst);
                }
                return null;
            }
            const payload = (try sema.coerceInner(block, child, inst, src)) orelse return null;
            if (sema.resolveValue(payload)) |pv| return .fromInterned(try sema.intern(.{ .opt = .{ .ty = dest_ty, .val = pv } }));
            try sema.resolveLayout(block, src, dest_ty);
            return try sema.addTyOp(block, .wrap_optional, dest_ty, payload);
        },
        .error_union => {
            const eu = ip.indexToKey(dest_ty).error_union_type;
            if (sc == .error_set) {
                const err = (try sema.coerceInner(block, eu.error_set_type, inst, src)) orelse return null;
                if (sema.resolveValue(err)) |ev| return .fromInterned(try sema.intern(.{ .error_union = .{ .ty = dest_ty, .val = .{ .err_name = ip.indexToKey(ev).err.name } } }));
                try sema.resolveLayout(block, src, dest_ty);
                return try sema.addTyOp(block, .wrap_errunion_err, dest_ty, err);
            }
            if (sc == .error_union) {
                const s_eu = ip.indexToKey(src_ty).error_union_type;
                if (s_eu.payload_type != eu.payload_type) return null;
                if (!try sema.errorSetCoercible(block, src, s_eu.error_set_type, eu.error_set_type, if (val) |v| v else .none)) return null;
                if (val) |v| return .fromInterned(switch (ip.indexToKey(v)) {
                    .error_union => |e| try sema.intern(.{ .error_union = .{ .ty = dest_ty, .val = e.val } }),
                    else => try sema.undefValue(dest_ty),
                });
                return try sema.addTyOp(block, .bitcast, dest_ty, inst);
            }
            const payload = (try sema.coerceInner(block, eu.payload_type, inst, src)) orelse return null;
            if (sema.resolveValue(payload)) |pv| return .fromInterned(try sema.intern(.{ .error_union = .{ .ty = dest_ty, .val = .{ .payload = pv } } }));
            try sema.resolveLayout(block, src, dest_ty);
            return try sema.addTyOp(block, .wrap_errunion_payload, dest_ty, payload);
        },
        .error_set => if (sc == .error_set) {
            if (!try sema.errorSetCoercible(block, src, src_ty, dest_ty, if (val) |v| v else .none)) return null;
            if (val) |v| return .fromInterned(switch (ip.indexToKey(v)) {
                .err => |e| try sema.intern(.{ .err = .{ .ty = dest_ty, .name = e.name } }),
                else => try sema.undefValue(dest_ty),
            });
            return try sema.addTyOp(block, .bitcast, dest_ty, inst);
        },
        .pointer => switch (sc) {
            .pointer => return sema.coercePtr(block, dest_ty, inst),
            .null => if (Type.ptrInfo(ip, dest_ty).flags.size == .c)
                return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = dest_ty, .base = .int, .byte_offset = 0 } })),
            .int, .comptime_int => if (Type.ptrInfo(ip, dest_ty).flags.size == .c) {
                if (val) |v| {
                    const addr = ip.intValue(u64, v) orelse return null;
                    return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = dest_ty, .base = .int, .byte_offset = addr } }));
                }
                if (sc == .comptime_int) return null;
                const addr = try sema.coerce(block, .usize_type, inst, src);
                return try sema.addTyOp(block, .ptr_from_int, dest_ty, addr);
            },
            .@"fn" => {
                // A function body coerces to a pointer to it.
                const d = Type.ptrInfo(ip, dest_ty);
                const v = val orelse return null;
                if (d.flags.size != .one or d.child != src_ty or ip.indexToKey(v) != .func) return null;
                const f = ip.indexToKey(v).func;
                if (f.generic_owner != .none) return null;
                try sema.zcu.queueFunc(v);
                return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = dest_ty, .base = .{ .nav = f.owner_nav } } }));
            },
            else => {},
        },
        .vector, .array => if ((dc == .vector and (sc == .array or sc == .vector)) or (dc == .array and sc == .vector)) {
            // Between arrays and vectors of the same length, element by
            // element (as upstream's `coerceArrayLike`).
            const len: u64 = if (dc == .vector) ip.indexToKey(dest_ty).vector_type.len else ip.indexToKey(dest_ty).array_type.len;
            const s_len: u64 = if (sc == .vector) ip.indexToKey(src_ty).vector_type.len else ip.indexToKey(src_ty).array_type.len;
            if (len != s_len) return null;
            if (dc == .array and ip.indexToKey(dest_ty).array_type.sentinel != .none) return null;
            const dest_elem = Type.childType(ip, dest_ty);
            const same = dest_elem == Type.childType(ip, src_ty);
            const elems = try sema.arena.alloc(Ref, @intCast(len));
            for (elems, 0..) |*e, i| {
                const elem = try sema.vectorElem(block, inst, @intCast(i));
                e.* = if (same) elem else (try sema.coerceInner(block, dest_elem, elem, src)) orelse return null;
            }
            return try sema.aggregate(block, src, dest_ty, elems);
        } else if (dc == .vector and sc == .tuple) {
            const v = ip.indexToKey(dest_ty).vector_type;
            const t = ip.indexToKey(src_ty).tuple_type;
            if (t.types.len != v.len) return null;
            const elems = try sema.arena.alloc(Ref, v.len);
            for (elems, 0..) |*e, k| e.* = (try sema.coerceInner(block, v.child, try sema.tupleField(block, inst, @intCast(k)), src)) orelse return null;
            return try sema.aggregate(block, src, dest_ty, elems);
        } else if (dc == .array and sc == .array) {
            // `[N:s]T` to `[N]T`.
            const a = ip.indexToKey(dest_ty).array_type;
            const s = ip.indexToKey(src_ty).array_type;
            if (a.len != s.len or a.child != s.child or a.sentinel != .none) return null;
            if (val) |v| {
                if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(dest_ty));
                const elems = try sema.arena.alloc(Index, a.len);
                for (elems, 0..) |*e, i| e.* = try sema.elemValue(v, i);
                return .fromInterned(try sema.intern(.{ .aggregate = .{ .ty = dest_ty, .storage = .{ .elems = elems } } }));
            }
            const ref = try sema.analyzeRef(block, src, inst);
            const ptr = try sema.coercePtrTo(block, ref, try sema.ptrType(.{ .child = dest_ty, .flags = .{ .is_const = true } }));
            return try sema.analyzeLoad(block, src, ptr);
        } else if (dc == .array and sc == .tuple) {
            const a = ip.indexToKey(dest_ty).array_type;
            const t = ip.indexToKey(src_ty).tuple_type;
            if (t.types.len != a.len or t.names.len != 0) return null;
            const elems = try sema.arena.alloc(Ref, a.lenIncludingSentinel());
            for (0..t.types.len) |k| {
                const field = try sema.tupleField(block, inst, @intCast(k));
                elems[k] = (try sema.coerceInner(block, a.child, field, src)) orelse return null;
            }
            if (a.sentinel != .none) elems[a.len] = .fromInterned(a.sentinel);
            return try sema.aggregate(block, src, dest_ty, elems);
        },
        .@"enum" => switch (sc) {
            .enum_literal => {
                const name = ip.stringSlice(ip.indexToKey(val.?).enum_literal);
                const i = (try sema.enumFieldIndex(block, src, dest_ty, name)) orelse
                    return sema.fail(block, src, "enum '{f}' has no field named '{s}'", .{ sema.fmtType(dest_ty), name });
                return .fromInterned(try sema.enumTagValue(dest_ty, i));
            },
            .@"union" => {
                try sema.resolveLayout(block, src, src_ty);
                if (ip.structInfo(src_ty).tag_type != dest_ty) return null;
                return try sema.unionTag(block, src, inst);
            },
            else => {},
        },
        .@"union" => if (sc == .enum_literal or sc == .@"enum") {
            try sema.resolveLayout(block, src, dest_ty);
            const info = ip.structInfo(dest_ty);
            const tag_ty = info.tag_type;
            if (tag_ty == .none or ip.indexToKey(tag_ty) != .enum_type) return null;
            const tag = (try sema.coerceInner(block, tag_ty, inst, src)) orelse return null;
            const tv = try sema.resolveConstValue(block, src, tag, "union tag must be comptime-known");
            const i = sema.enumTagIndex(tv).?;
            const field_ty = info.field_types[i];
            if (Type.hasRuntimeBits(ip, field_ty) or Type.class(ip, field_ty) == .noreturn)
                return sema.fail(block, src, "coercion from enum '{f}' to union '{f}' must initialize '{f}' field '{s}'", .{ sema.fmtType(src_ty), sema.fmtType(dest_ty), sema.fmtType(field_ty), ip.stringSlice(info.field_names[i]) });
            return .fromInterned(try sema.intern(.{ .un = .{ .ty = dest_ty, .tag = tv, .val = try sema.undefOrVoid(field_ty) } }));
        },
        .special => if (dest_ty == .calling_convention_type and sc == .enum_literal) {
            return null;
        },
        else => {},
    }
    return null;
}

/// The value of a zero-bit type (`void`, `u0`, ...), as a union payload.
fn undefOrVoid(sema: *Sema, ty: Index) !Index {
    if (ty == .void_type) return .void_value;
    return sema.undefValue(ty);
}

/// The index of field `name` of enum `ty`, or null.
fn enumFieldIndex(sema: *Sema, block: *Block, src: Src, ty: Index, name: []const u8) CompileError!?u32 {
    try sema.resolveLayout(block, src, ty);
    return sema.ip.structInfo(ty).fieldIndex(sema.ip, name);
}

/// The tag value of field `i` of enum `ty`, whose layout is resolved.
fn enumTagValue(sema: *Sema, ty: Index, i: u32) !Index {
    return sema.intern(.{ .enum_tag = .{ .ty = ty, .int = sema.ip.structInfo(ty).field_defaults[i] } });
}

/// The field index of an `enum_tag` value, or null for an unnamed tag of a
/// non-exhaustive enum.
fn enumTagIndex(sema: *Sema, val: Index) ?u32 {
    const ip = sema.ip;
    const e = ip.indexToKey(val).enum_tag;
    for (ip.structInfo(e.ty).field_defaults, 0..) |v, i| {
        if (v == e.int) return @intCast(i);
    }
    return null;
}

fn enumFromInt(sema: *Sema, block: *Block, src: Src, ty: Index, uncasted: Ref) CompileError!Ref {
    const ip = sema.ip;
    try sema.resolveLayout(block, src, ty);
    const info = ip.structInfo(ty);
    const int_ty = info.tag_type;
    const operand = try sema.coerce(block, int_ty, uncasted, src);
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(ty));
        const val = try sema.intern(.{ .enum_tag = .{ .ty = ty, .int = v } });
        if (!info.nonexhaustive and sema.enumTagIndex(val) == null)
            return sema.fail(block, src, "enum '{f}' has no tag with value '{f}'", .{ sema.fmtType(ty), sema.fmtValue(v) });
        return .fromInterned(val);
    }
    try sema.requireRuntime(block, src);
    if (!info.nonexhaustive and block.want_safety and info.field_defaults.len < std.math.maxInt(u16)) {
        // The value must be one of the tags.
        var ok: Ref = .fromInterned(.bool_false);
        for (info.field_defaults) |v| {
            const eq = try sema.addBinOp(block, .cmp_eq, operand, .fromInterned(v));
            ok = if (ok == Ref.fromInterned(.bool_false)) eq else try sema.addBinOp(block, .bit_or, ok, eq);
        }
        try sema.addSafetyCheck(block, ok, .invalid_enum_value, .none, .none);
    }
    return sema.addTyOp(block, .bitcast, ty, operand);
}

fn zirTagName(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ip = sema.ip;
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].un_node;
    const src = block.nodeSrc(data.src_node);
    var operand = sema.resolveInst(data.operand);
    var ty = sema.typeOf(operand);
    if (Type.class(ip, ty) == .@"union") {
        try sema.resolveLayout(block, src, ty);
        if (ip.indexToKey(ip.structInfo(ty).tag_type) != .enum_type) return sema.fail(block, src, "union '{f}' is untagged", .{sema.fmtType(ty)});
        operand = try sema.unionTag(block, src, operand);
        ty = sema.typeOf(operand);
    }
    switch (Type.class(ip, ty)) {
        .enum_literal => {
            const v = try sema.resolveConstValue(block, src, operand, "enum literal must be comptime-known");
            return sema.tagNameValue(ip.stringSlice(ip.indexToKey(v).enum_literal));
        },
        .@"enum" => {},
        else => return sema.fail(block, src, "expected enum or union; found '{f}'", .{sema.fmtType(ty)}),
    }
    try sema.resolveLayout(block, src, ty);
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
        const i = sema.enumTagIndex(v) orelse
            return sema.fail(block, src, "no field with value '{f}' in enum '{f}'", .{ sema.fmtValue(ip.indexToKey(v).enum_tag.int), sema.fmtType(ty) });
        return sema.tagNameValue(ip.stringSlice(ip.structInfo(ty).field_names[i]));
    }
    try sema.requireRuntime(block, src);
    return sema.addTyOp(block, .tag_name, .slice_const_u8_sentinel_0_type, operand);
}

/// The comptime-known result of `@tagName`: like upstream, a string
/// literal (`*const [N:0]u8`), which coerces to `[:0]const u8` and
/// `[*:0]const u8`.
fn tagNameValue(sema: *Sema, name: []const u8) !Ref {
    return .fromInterned(try sema.stringLiteral(name));
}

/// A `[:0]const u8` value of `name`.
fn nameSliceValue(sema: *Sema, name: []const u8) !Index {
    const ptr = try sema.stringLiteral(name);
    const many = try sema.intern(.{ .ptr = .{ .ty = .manyptr_const_u8_sentinel_0_type, .base = .{ .elem = .{ .base = ptr, .index = 0 } } } });
    return sema.intern(.{ .slice = .{ .ty = .slice_const_u8_sentinel_0_type, .ptr = many, .len = try sema.intValue(.usize_type, name.len) } });
}

/// The tag of union value `operand`.
fn unionTag(sema: *Sema, block: *Block, src: Src, operand: Ref) CompileError!Ref {
    const union_ty = sema.typeOf(operand);
    const tag_ty = sema.ip.structInfo(union_ty).tag_type;
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(tag_ty));
        return .fromInterned(sema.ip.indexToKey(v).un.tag);
    }
    try sema.requireRuntime(block, src);
    return sema.addTyOp(block, .get_union_tag, tag_ty, operand);
}

fn tupleField(sema: *Sema, block: *Block, tuple: Ref, index: u32) CompileError!Ref {
    const t = sema.ip.indexToKey(sema.typeOf(tuple)).tuple_type;
    if (t.values[index] != .none) return .fromInterned(t.values[index]);
    if (sema.resolveValue(tuple)) |v| return .fromInterned(try sema.fieldValue(v, index));
    return sema.addStructField(block, .struct_field_val, t.types[index], tuple, index);
}

/// Whether error set `src_ty` (or comptime-known error value `val`)
/// coerces to error set `dest_ty`. Adds errors to the current function's
/// inferred error set when `dest_ty` is it.
fn errorSetCoercible(sema: *Sema, block: *Block, src: Src, src_ty: Index, dest_ty: Index, val: Index) CompileError!bool {
    const ip = sema.ip;
    if (dest_ty == .anyerror_type) return true;
    switch (ip.indexToKey(dest_ty)) {
        .inferred_error_set_type => |func| {
            if (func == sema.func) {
                if (try sema.errorSetNames(block, src, src_ty)) |_| try sema.addInferredErrors(block, src, src_ty) else if (ip.indexToKey(src_ty) != .inferred_error_set_type) {
                    return sema.fail(block, src, "zap does not support coercing '{f}' into an inferred error set yet", .{sema.fmtType(src_ty)});
                }
            }
            return true;
        },
        else => {},
    }
    const dest_names = (try sema.errorSetNames(block, src, dest_ty)) orelse return false;
    if (val != .none and ip.indexToKey(val) == .err) {
        const name = ip.indexToKey(val).err.name;
        for (dest_names) |n| if (n == name) return true;
        return false;
    }
    const src_names = (try sema.errorSetNames(block, src, src_ty)) orelse return false;
    outer: for (src_names) |s| {
        for (dest_names) |d| if (d == s) continue :outer;
        return false;
    }
    return true;
}

/// The ABI alignment of `ty` in bytes, or null if its layout is not
/// resolved yet.
fn naturalAlignment(sema: *Sema, ty: Index) ?u64 {
    const ip = sema.ip;
    if (!sema.layoutResolved(ty)) return null;
    return switch (Type.class(ip, ty)) {
        .@"opaque", .@"fn" => null,
        else => if (Type.hasRuntimeBits(ip, ty)) Type.abiAlignment(ip, ty) else null,
    };
}

/// The alignment in bytes of what pointer `p` points to, or null if unknown.
fn ptrAlignment(sema: *Sema, p: InternPool.PtrType) ?u64 {
    if (p.flags.alignment != 0) return @as(u64, 1) << @intCast(p.flags.alignment - 1);
    return sema.naturalAlignment(p.child);
}

/// Whether a pointer of type `src_ty` can be used as `dest_ty` without
/// changing its representation.
fn ptrCoercibleInPlace(sema: *Sema, src_ty: Index, dest_ty: Index) bool {
    const ip = sema.ip;
    const s = Type.ptrInfo(ip, src_ty);
    const d = Type.ptrInfo(ip, dest_ty);
    if (s.flags.is_const and !d.flags.is_const) return false;
    if (s.flags.is_volatile and !d.flags.is_volatile) return false;
    if (d.flags.alignment != s.flags.alignment) {
        // The alignment may only decrease.
        const sa = sema.ptrAlignment(s) orelse return false;
        const da = sema.ptrAlignment(d) orelse return false;
        if (da > sa) return false;
    }
    const s_array: ?InternPool.ArrayType = if (ip.indexToKey(s.child) == .array_type) ip.indexToKey(s.child).array_type else null;
    // C pointers coerce to and from single and many pointers of the same child.
    if (s.flags.size == .c and d.flags.size != .slice) return s.child == d.child or d.child == .anyopaque_type;
    if (d.flags.size == .c and s.flags.size != .slice)
        return s.child == d.child or d.child == .anyopaque_type or (s.flags.size == .one and s_array != null and s_array.?.child == d.child);
    if (s.flags.size == d.flags.size) {
        if (d.sentinel != .none and d.sentinel != s.sentinel) return false;
        if (s.child == d.child) return true;
        if (d.child == .anyopaque_type and s.flags.size != .slice) return true;
        if (s.flags.size == .one and ip.indexToKey(d.child) == .array_type) {
            const b = ip.indexToKey(d.child).array_type;
            // `*[N:s]T` to `*[N]T`.
            if (s_array) |a| return a.len == b.len and a.child == b.child and b.sentinel == .none;
            // `*T` to `*[1]T`.
            return b.len == 1 and b.child == s.child and b.sentinel == .none;
        }
        return false;
    }
    // `[*]T` to `*anyopaque`.
    if (s.flags.size == .many and d.flags.size == .one and d.child == .anyopaque_type) return true;
    // `*[N]T` to `[*]T`.
    if (s.flags.size == .one and d.flags.size == .many) {
        if (s_array) |a| return a.child == d.child and (d.sentinel == .none or d.sentinel == a.sentinel);
    }
    return false;
}

fn coercePtr(sema: *Sema, block: *Block, dest_ty: Index, inst: Ref) CompileError!?Ref {
    const ip = sema.ip;
    const src_ty = sema.typeOf(inst);
    if (sema.ptrCoercibleInPlace(src_ty, dest_ty)) return try sema.coercePtrTo(block, inst, dest_ty);
    const s = Type.ptrInfo(ip, src_ty);
    const d = Type.ptrInfo(ip, dest_ty);
    // `*[N]T` to `[]T`.
    if (s.flags.size == .one and d.flags.size == .slice and ip.indexToKey(s.child) == .array_type) {
        const a = ip.indexToKey(s.child).array_type;
        if (a.child != d.child) return null;
        // A pointer to a zero-length array coerces to any slice, even a mutable one.
        if (s.flags.is_const and !d.flags.is_const and a.len != 0) return null;
        if (d.sentinel != .none and d.sentinel != a.sentinel) return null;
        const many_ty = try sema.ptrType(.{ .child = d.child, .sentinel = d.sentinel, .flags = .{ .size = .many, .is_const = d.flags.is_const, .is_volatile = d.flags.is_volatile } });
        const ptr = try sema.coercePtrTo(block, inst, many_ty);
        const len: Ref = .fromInterned(try sema.intValue(.usize_type, a.len));
        return try sema.makeSlice(block, dest_ty, ptr, len);
    }
    return null;
}

fn makeSlice(sema: *Sema, block: *Block, slice_ty: Index, ptr: Ref, len: Ref) CompileError!Ref {
    if (sema.resolveValue(ptr)) |p| if (sema.resolveValue(len)) |l|
        return .fromInterned(try sema.intern(.{ .slice = .{ .ty = slice_ty, .ptr = p, .len = l } }));
    return sema.addTyPlBin(block, .slice, slice_ty, ptr, len);
}

/// Reinterprets a pointer as pointer type `ty` (a representation-preserving
/// change, checked by the caller).
fn coercePtrTo(sema: *Sema, block: *Block, ptr: Ref, ty: Index) CompileError!Ref {
    const ip = sema.ip;
    const src_ty = sema.typeOf(ptr);
    if (src_ty == ty) return ptr;
    if (sema.resolveValue(ptr)) |v| {
        switch (ip.indexToKey(v)) {
            .undef => return .fromInterned(try sema.undefValue(ty)),
            .slice => |sl| {
                const d = Type.ptrInfo(ip, ty);
                const many_ty = try sema.ptrType(.{ .child = d.child, .sentinel = d.sentinel, .flags = .{ .size = .many, .is_const = d.flags.is_const, .is_volatile = d.flags.is_volatile, .alignment = d.flags.alignment } });
                const p = try sema.coercePtrTo(block, .fromInterned(sl.ptr), many_ty);
                return .fromInterned(try sema.intern(.{ .slice = .{ .ty = ty, .ptr = p.toInterned().?, .len = sl.len } }));
            },
            .ptr => |p| {
                const s = Type.ptrInfo(ip, src_ty);
                const d = Type.ptrInfo(ip, ty);
                if (s.flags.size == .one and d.flags.size != .one and ip.indexToKey(s.child) == .array_type and p.base != .int) {
                    // Pointer to an array becomes a pointer to its first element.
                    return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = ty, .base = .{ .elem = .{ .base = v, .index = 0 } } } }));
                }
                var new = p;
                new.ty = ty;
                return .fromInterned(try sema.intern(.{ .ptr = new }));
            },
            else => {},
        }
    }
    if (block.is_comptime) return sema.fail(block, .{ .base = block.src_base, .loc = .{ .node = .zero } }, "unable to evaluate comptime expression", .{});
    return sema.addTyOp(block, .bitcast, ty, ptr);
}

fn resolvePeerTypes(sema: *Sema, block: *Block, src: Src, refs: []const Ref) CompileError!Index {
    var chosen: Index = .noreturn_type;
    sema.peers_comptime_known = false;
    for (refs) |r| sema.peers_comptime_known = sema.peers_comptime_known or sema.resolveValue(r) != null;
    for (refs) |r| {
        const ty = sema.typeOf(r);
        if (ty == .noreturn_type) continue;
        if (chosen == .noreturn_type) {
            chosen = ty;
            continue;
        }
        chosen = try sema.peerPair(block, src, chosen, ty);
    }
    return chosen;
}

fn peerPair(sema: *Sema, block: *Block, src: Src, a: Index, b: Index) CompileError!Index {
    const ip = sema.ip;
    if (a == b) return a;
    if (a == .undefined_type) return b;
    if (b == .undefined_type) return a;
    const ca = Type.class(ip, a);
    const cb = Type.class(ip, b);
    if (ca == .null) return if (cb == .optional) b else sema.optType(b);
    if (cb == .null) return if (ca == .optional) a else sema.optType(a);
    if (ca == .optional and cb != .optional) return sema.optType(try sema.peerPair(block, src, Type.childType(ip, a), b));
    if (cb == .optional and ca != .optional) return sema.optType(try sema.peerPair(block, src, a, Type.childType(ip, b)));
    if (ca == .error_set and cb == .error_set) return sema.mergeErrorSets(block, src, a, b);
    if (ca == .error_union or cb == .error_union or ca == .error_set or cb == .error_set) {
        const Split = struct { set: Index, payload: Index };
        const split = struct {
            fn f(p: *InternPool, ty: Index, c: Type.Class) Split {
                return switch (c) {
                    .error_union => .{ .set = p.indexToKey(ty).error_union_type.error_set_type, .payload = p.indexToKey(ty).error_union_type.payload_type },
                    .error_set => .{ .set = ty, .payload = .none },
                    else => .{ .set = .none, .payload = ty },
                };
            }
        }.f;
        const sa = split(ip, a, ca);
        const sb = split(ip, b, cb);
        const set = if (sa.set == .none) sb.set else if (sb.set == .none or sa.set == sb.set) sa.set else try sema.mergeErrorSets(block, src, sa.set, sb.set);
        const payload = if (sa.payload == .none) sb.payload else if (sb.payload == .none) sa.payload else try sema.peerPair(block, src, sa.payload, sb.payload);
        return sema.intern(.{ .error_union_type = .{ .error_set_type = set, .payload_type = payload } });
    }
    if (ca == .vector or cb == .vector) {
        const elems = struct {
            fn f(p: *InternPool, ty: Index) ?struct { u64, Index } {
                return switch (p.indexToKey(ty)) {
                    .vector_type => |v| .{ v.len, v.child },
                    .array_type => |r| .{ r.len, r.child },
                    else => null,
                };
            }
        }.f;
        const ea = elems(ip, a) orelse return sema.fail(block, src, "mixed scalar and vector operands: '{f}' and '{f}'", .{ sema.fmtType(a), sema.fmtType(b) });
        const eb = elems(ip, b) orelse return sema.fail(block, src, "mixed scalar and vector operands: '{f}' and '{f}'", .{ sema.fmtType(a), sema.fmtType(b) });
        if (ea[0] != eb[0]) return sema.fail(block, src, "vector length mismatch", .{});
        return sema.vectorType(@intCast(ea[0]), try sema.peerPair(block, src, ea[1], eb[1]));
    }
    // Upstream's `comptime_float` and `fixed_float` strategies. An integer
    // peer of a float that it cannot coerce to fails later, in the
    // coercion.
    if (ca == .float and cb == .float) return Type.floatOfBits(@max(Type.floatBits(ip, a), Type.floatBits(ip, b)));
    if (ca == .float and (cb == .comptime_float or cb == .comptime_int or cb == .int)) return a;
    if (cb == .float and (ca == .comptime_float or ca == .comptime_int or ca == .int)) return b;
    if ((ca == .comptime_float and cb == .comptime_int) or (ca == .comptime_int and cb == .comptime_float)) return .comptime_float_type;
    if (ca == .comptime_int and cb == .int) return b;
    if (cb == .comptime_int and ca == .int) return a;
    if (ca == .int and cb == .int) {
        const ia = Type.intInfo(ip, a);
        const ib = Type.intInfo(ip, b);
        if (ia.signedness == ib.signedness) return if (ia.bits >= ib.bits) a else b;
        if (ia.signedness == .unsigned and ib.bits > ia.bits) return b;
        if (ib.signedness == .unsigned and ia.bits > ib.bits) return a;
        // Upstream's legacy rule: with a comptime-known peer, the wider
        // unsigned type or else the first; the coercion checks the values.
        if (sema.peers_comptime_known) return if (ia.signedness == .unsigned and ia.bits > ib.bits) a else if (ib.signedness == .unsigned and ib.bits > ia.bits) b else a;
    }
    if (ca == .pointer and cb == .pointer) {
        if (sema.ptrCoercibleInPlace(a, b)) return b;
        if (sema.ptrCoercibleInPlace(b, a)) return a;
    }
    return sema.fail(block, src, "incompatible types: '{f}' and '{f}'", .{ sema.fmtType(a), sema.fmtType(b) });
}

// ---------------------------------------------------------------------------
// Arithmetic and comparison

fn overflowTupleType(sema: *Sema, ty: Index) !Index {
    return sema.intern(.{ .tuple_type = .{ .types = &.{ ty, .u1_type }, .values = &.{ .none, .none } } });
}

fn requireRuntime(sema: *Sema, block: *Block, src: Src) CompileError!void {
    if (block.is_comptime) return sema.fail(block, src, "unable to evaluate comptime expression", .{});
}

fn analyzeArithmetic(sema: *Sema, block: *Block, src: Src, tag: Zir.Inst.Tag, uncasted_lhs: Ref, uncasted_rhs: Ref) CompileError!Ref {
    const ip = sema.ip;
    switch (tag) {
        .shl, .shr, .shl_sat, .shl_exact, .shr_exact => return sema.analyzeShift(block, src, tag, uncasted_lhs, uncasted_rhs),
        else => {},
    }
    if (Type.class(ip, sema.typeOf(uncasted_lhs)) == .pointer and (tag == .add or tag == .sub or tag == .addwrap or tag == .subwrap))
        return sema.analyzePtrArithmetic(block, src, tag == .add or tag == .addwrap, uncasted_lhs, uncasted_rhs);
    const ty = try sema.resolvePeerTypes(block, src, &.{ uncasted_lhs, uncasted_rhs });
    if (sema.vectorLen(ty)) |len| {
        const lhs = try sema.coerce(block, ty, uncasted_lhs, src);
        const rhs = try sema.coerce(block, ty, uncasted_rhs, src);
        return sema.vectorMap(block, src, len, ty, &.{ lhs, rhs }, VectorArith{ .tag = tag });
    }
    const is_bool = ty == .bool_type;
    const class = Type.class(ip, ty);
    if (class == .float or class == .comptime_float) return sema.analyzeFloatArithmetic(block, src, tag, ty, uncasted_lhs, uncasted_rhs);
    if (!(class == .int or class == .comptime_int or (is_bool and (tag == .bit_and or tag == .bit_or or tag == .xor)))) {
        return sema.fail(block, src, "invalid operands to binary expression: '{f}' and '{f}'", .{ sema.fmtType(sema.typeOf(uncasted_lhs)), sema.fmtType(sema.typeOf(uncasted_rhs)) });
    }
    const lhs = try sema.coerce(block, ty, uncasted_lhs, src);
    const rhs = try sema.coerce(block, ty, uncasted_rhs, src);
    const signed = !is_bool and (class == .comptime_int or Type.intInfo(ip, ty).signedness == .signed);

    // Signed division and remainder need an explicit rounding mode.
    if (tag == .div or tag == .mod_rem) {
        if (signed) {
            const lv = sema.resolveValue(lhs);
            const rv = sema.resolveValue(rhs);
            const nonneg = lv != null and rv != null and !sema.isUndef(lv.?) and !sema.isUndef(rv.?) and
                sema.intSign(lv.?) >= 0 and sema.intSign(rv.?) > 0;
            if (!nonneg) {
                if (tag == .div) return sema.fail(block, src, "division with '{f}' and '{f}': signed integers must use @divTrunc, @divFloor, or @divExact", .{ sema.fmtType(ty), sema.fmtType(ty) });
                return sema.fail(block, src, "remainder division with '{f}' and '{f}': signed integers and floats must use @rem or @mod", .{ sema.fmtType(ty), sema.fmtType(ty) });
            }
        }
    }

    if (sema.resolveValue(lhs)) |lv| if (sema.resolveValue(rhs)) |rv| {
        if (sema.isUndef(lv) or sema.isUndef(rv)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
        if (is_bool) {
            const a = lv == .bool_true;
            const b = rv == .bool_true;
            return .fromInterned(boolValue(switch (tag) {
                .bit_and => a and b,
                .bit_or => a or b,
                .xor => a != b,
                else => unreachable,
            }));
        }
        return .fromInterned(try sema.foldArithmetic(block, src, tag, ty, lv, rv));
    };
    try sema.requireRuntime(block, src);
    if (class == .comptime_int) return sema.fail(block, src, "unable to resolve comptime value", .{});

    const safety = block.want_safety;
    switch (tag) {
        .add, .sub, .mul => {
            if (!safety) return sema.addBinOp(block, switch (tag) {
                .add => .add_wrap,
                .sub => .sub_wrap,
                else => .mul_wrap,
            }, lhs, rhs);
            const tuple_ty = try sema.overflowTupleType(ty);
            const ov = try sema.addTyPlBin(block, switch (tag) {
                .add => .add_with_overflow,
                .sub => .sub_with_overflow,
                else => .mul_with_overflow,
            }, tuple_ty, lhs, rhs);
            const result = try sema.addStructField(block, .struct_field_val, ty, ov, 0);
            const bit = try sema.addStructField(block, .struct_field_val, .u1_type, ov, 1);
            const ok = try sema.addBinOp(block, .cmp_eq, bit, .zero_u1);
            try sema.addSafetyCheck(block, ok, .integer_overflow, .none, .none);
            return result;
        },
        .add_sat, .sub_sat, .mul_sat => {
            // The wrapped result, or on overflow the bound the exact result
            // passed: for signed add and sub the one on lhs's side of zero,
            // for signed mul the one with the product's sign.
            const ov = try sema.addTyPlBin(block, switch (tag) {
                .add_sat => .add_with_overflow,
                .sub_sat => .sub_with_overflow,
                else => .mul_with_overflow,
            }, try sema.overflowTupleType(ty), lhs, rhs);
            const result = try sema.addStructField(block, .struct_field_val, ty, ov, 0);
            const bit = try sema.addStructField(block, .struct_field_val, .u1_type, ov, 1);
            const overflowed = try sema.addBinOp(block, .cmp_neq, bit, .zero_u1);
            const bound = if (!signed)
                Ref.fromInterned(if (tag == .sub_sat) try sema.intValue(ty, 0) else try sema.maxIntValue(ty))
            else
                try sema.signedBound(block, ty, if (tag == .mul_sat) try sema.addBinOp(block, .xor, lhs, rhs) else lhs);
            return sema.select(block, ty, overflowed, bound, result);
        },
        .addwrap, .add_unsafe => return sema.addBinOp(block, .add_wrap, lhs, rhs),
        .subwrap => return sema.addBinOp(block, .sub_wrap, lhs, rhs),
        .mulwrap => return sema.addBinOp(block, .mul_wrap, lhs, rhs),
        .bit_and => return sema.addBinOp(block, .bit_and, lhs, rhs),
        .bit_or => return sema.addBinOp(block, .bit_or, lhs, rhs),
        .xor => return sema.addBinOp(block, .xor, lhs, rhs),
        .min, .max => {
            const take_lhs = try sema.addBinOp(block, if (tag == .min) .cmp_lt else .cmp_gt, lhs, rhs);
            return sema.select(block, ty, take_lhs, lhs, rhs);
        },
        .div, .div_trunc, .div_floor, .div_ceil, .div_exact, .rem, .mod, .mod_rem => {
            if (safety) {
                const rv = sema.resolveValue(rhs);
                if (rv == null) {
                    const zero: Ref = .fromInterned(try sema.intValue(ty, 0));
                    const ok = try sema.addBinOp(block, .cmp_neq, rhs, zero);
                    try sema.addSafetyCheck(block, ok, .divide_by_zero, .none, .none);
                } else if (sema.intSign(rv.?) == 0) {
                    return sema.fail(block, src, "division by zero here causes illegal behavior", .{});
                }
                const is_div = tag == .div_trunc or tag == .div_floor or tag == .div_ceil or tag == .div_exact;
                if (signed and is_div) {
                    const rhs_may_be_neg_one = if (rv) |v| sema.ip.intValue(i64, v) == -1 else true;
                    const lhs_may_be_min = if (sema.resolveValue(lhs)) |v| v == try sema.minIntValue(ty) else true;
                    if (rhs_may_be_neg_one and lhs_may_be_min) {
                        const min: Ref = .fromInterned(try sema.minIntValue(ty));
                        const neg_one: Ref = .fromInterned(try sema.intValue(ty, -1));
                        const lhs_ok = try sema.addBinOp(block, .cmp_neq, lhs, min);
                        const rhs_ok = try sema.addBinOp(block, .cmp_neq, rhs, neg_one);
                        const ok = try sema.addBinOp(block, .bit_or, lhs_ok, rhs_ok);
                        try sema.addSafetyCheck(block, ok, .integer_overflow, .none, .none);
                    }
                }
                if (tag == .div_exact) {
                    const r = try sema.addBinOp(block, .rem, lhs, rhs);
                    const ok = try sema.addBinOp(block, .cmp_eq, r, .fromInterned(try sema.intValue(ty, 0)));
                    try sema.addSafetyCheck(block, ok, .exact_division_remainder, .none, .none);
                }
            }
            return sema.addBinOp(block, switch (tag) {
                .div, .div_trunc, .div_exact => .div_trunc,
                .div_floor => if (signed) .div_floor else .div_trunc,
                .div_ceil => .div_ceil,
                .rem, .mod_rem => .rem,
                .mod => if (signed) .mod else .rem,
                else => unreachable,
            }, lhs, rhs);
        },
        else => unreachable,
    }
}

/// `ptr + n` and `ptr - n` on many-item and C pointers.
fn analyzePtrArithmetic(sema: *Sema, block: *Block, src: Src, is_add: bool, ptr: Ref, uncasted_n: Ref) CompileError!Ref {
    const ip = sema.ip;
    const ptr_ty = sema.typeOf(ptr);
    const p = Type.ptrInfo(ip, ptr_ty);
    if (p.flags.size != .many and p.flags.size != .c) return sema.fail(block, src, "invalid pointer arithmetic operand: '{f}'", .{sema.fmtType(ptr_ty)});
    const n = try sema.coerce(block, .usize_type, uncasted_n, src);
    const elem_size = Type.abiSize(ip, p.child);
    if (sema.resolveValue(ptr)) |pv| if (sema.resolveValue(n)) |nv| {
        if (ip.indexToKey(pv) == .ptr and !sema.isUndef(nv)) {
            const k = ip.indexToKey(pv).ptr;
            const count = ip.intValue(u64, nv).?;
            const delta = count *% elem_size;
            return .fromInterned(try sema.intern(.{ .ptr = .{
                .ty = ptr_ty,
                .base = switch (k.base) {
                    .elem => |e| .{ .elem = .{ .base = e.base, .index = if (is_add) e.index + count else e.index -% count } },
                    else => k.base,
                },
                .byte_offset = switch (k.base) {
                    .elem => k.byte_offset,
                    else => if (is_add) k.byte_offset +% delta else k.byte_offset -% delta,
                },
            } }));
        }
    };
    try sema.requireRuntime(block, src);
    const offset = if (is_add) n else try sema.addBinOp(block, .sub_wrap, .fromInterned(.zero_usize), n);
    return sema.addTyPlBin(block, .ptr_add, ptr_ty, ptr, offset);
}

/// `block { cond_br(cond, { br a }, { br b }) }`
fn select(sema: *Sema, block: *Block, ty: Index, cond: Ref, a: Ref, b: Ref) CompileError!Ref {
    const block_inst = try sema.reserveInst();
    var then_block = block.child();
    defer then_block.instructions.deinit(sema.gpa);
    _ = try sema.addInst(&then_block, .{ .tag = .br, .data = .{ .br = .{ .block_inst = block_inst, .operand = a } } });
    var else_block = block.child();
    defer else_block.instructions.deinit(sema.gpa);
    _ = try sema.addInst(&else_block, .{ .tag = .br, .data = .{ .br = .{ .block_inst = block_inst, .operand = b } } });
    var inner = block.child();
    defer inner.instructions.deinit(sema.gpa);
    try sema.addCondBr(&inner, cond, then_block.instructions.items, else_block.instructions.items);
    try sema.addBlock(block, block_inst, ty, inner.instructions.items);
    return block_inst.toRef();
}

fn intSign(sema: *Sema, val: Index) i2 {
    var space: [2]std.math.big.Limb = undefined;
    const big = sema.ip.intToBig(val, &space);
    if (big.eqlZero()) return 0;
    return if (big.positive) 1 else -1;
}

fn foldArithmetic(sema: *Sema, block: *Block, src: Src, tag: Zir.Inst.Tag, ty: Index, lv: Index, rv: Index) CompileError!Index {
    const a = try sema.bigValue(lv);
    const b = try sema.bigValue(rv);
    var r = try BigInt.init(sema.arena);
    var wrap = false;
    switch (tag) {
        .add, .addwrap, .add_unsafe, .add_sat => try r.add(&a, &b),
        .sub, .subwrap, .sub_sat => try r.sub(&a, &b),
        .mul, .mulwrap, .mul_sat => try r.mul(&a, &b),
        .bit_and => try r.bitAnd(&a, &b),
        .bit_or => try r.bitOr(&a, &b),
        .xor => try r.bitXor(&a, &b),
        .min => return if (a.order(b) == .gt) rv else lv,
        .max => return if (a.order(b) == .lt) rv else lv,
        .div, .div_trunc, .div_floor, .div_ceil, .div_exact, .rem, .mod, .mod_rem => {
            if (b.eqlZero()) return sema.fail(block, src, "division by zero here causes illegal behavior", .{});
            var q = try BigInt.init(sema.arena);
            var rem = try BigInt.init(sema.arena);
            switch (tag) {
                .div_floor, .mod => try q.divFloor(&rem, &a, &b),
                else => try q.divTrunc(&rem, &a, &b),
            }
            switch (tag) {
                .div, .div_trunc, .div_floor => r = q,
                .div_ceil => {
                    r = q;
                    // Truncation rounded down when the exact quotient is positive.
                    if (!rem.eqlZero() and a.isPositive() == b.isPositive()) try r.addScalar(&r, 1);
                },
                .div_exact => {
                    if (!rem.eqlZero()) return sema.fail(block, src, "exact division produced remainder", .{});
                    r = q;
                },
                .rem, .mod, .mod_rem => r = rem,
                else => unreachable,
            }
        },
        else => unreachable,
    }
    switch (tag) {
        .addwrap, .add_unsafe, .subwrap, .mulwrap => wrap = true,
        else => {},
    }
    if (ty != .comptime_int_type) {
        const info = Type.intInfo(sema.ip, ty);
        if (wrap) {
            try r.truncate(&r, info.signedness, info.bits);
        } else if (tag == .add_sat or tag == .sub_sat or tag == .mul_sat) {
            try sema.saturate(&r, ty);
        } else if (!r.fitsInTwosComp(info.signedness, info.bits)) {
            return sema.fail(block, src, "overflow of integer type '{f}' with value '{f}'", .{ sema.fmtType(ty), r.toConst() });
        }
    }
    return sema.bigToValue(ty, r.toConst());
}

fn analyzeShift(sema: *Sema, block: *Block, src: Src, tag: Zir.Inst.Tag, lhs: Ref, uncasted_rhs: Ref) CompileError!Ref {
    const ip = sema.ip;
    const ty = sema.typeOf(lhs);
    if (sema.vectorLen(ty)) |len| {
        const rhs_len = sema.vectorLen(sema.typeOf(uncasted_rhs));
        if (rhs_len != null and rhs_len.? != len) return sema.fail(block, src, "vector length mismatch", .{});
        return sema.vectorMap(block, src, len, ty, &.{ lhs, uncasted_rhs }, VectorArith{ .tag = tag });
    }
    if (sema.vectorLen(sema.typeOf(uncasted_rhs)) != null)
        return sema.fail(block, src, "mixed scalar and vector operands: '{f}' and '{f}'", .{ sema.fmtType(ty), sema.fmtType(sema.typeOf(uncasted_rhs)) });
    const class = Type.class(ip, ty);
    if (class != .int and class != .comptime_int) return sema.fail(block, src, "bit shifting operation expected integer type, found '{f}'", .{sema.fmtType(ty)});
    // `<<|` takes any integer amount; AstGen coerces the others' amounts.
    const sat = tag == .shl_sat;
    const left = tag != .shr and tag != .shr_exact;
    if (sat and !Type.isInt(ip, sema.typeOf(uncasted_rhs)) and sema.typeOf(uncasted_rhs) != .comptime_int_type)
        return sema.fail(block, src, "expected integer type, found '{f}'", .{sema.fmtType(sema.typeOf(uncasted_rhs))});
    const rv = sema.resolveValue(uncasted_rhs);
    if (rv) |v| {
        if (sema.isUndef(v)) {
            if (sat) return .fromInterned(try sema.undefValue(ty));
            return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
        }
        if (sema.intSign(v) < 0) return sema.fail(block, src, "shift by negative amount '{f}'", .{sema.fmtValue(v)});
        if (!sat and class == .int and (sema.ip.intValue(u64, v) orelse std.math.maxInt(u64)) >= Type.intInfo(ip, ty).bits)
            return sema.fail(block, src, "shift amount '{f}' is too large for operand type '{f}'", .{ sema.fmtValue(v), sema.fmtType(ty) });
    }
    if (sema.resolveValue(lhs)) |lv| if (rv) |v| {
        if (sema.isUndef(lv)) {
            if (sat) return .fromInterned(lv);
            return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
        }
        const a = try sema.bigValue(lv);
        var r = try BigInt.init(sema.arena);
        const amount = sema.ip.intValue(u64, v) orelse std.math.maxInt(u64);
        if (sat and class == .int and (a.eqlZero() or amount >= Type.intInfo(ip, ty).bits)) {
            // Every bit shifts out: zero stays zero, the rest saturate.
            if (a.eqlZero()) return .fromInterned(lv);
            return .fromInterned(if (a.isPositive()) try sema.maxIntValue(ty) else try sema.minIntValue(ty));
        }
        if (left) try r.shiftLeft(&a, @intCast(amount)) else try r.shiftRight(&a, @intCast(amount));
        if (class == .int) {
            const info = Type.intInfo(ip, ty);
            if (sat) {
                try sema.saturate(&r, ty);
            } else if (tag == .shl_exact and !r.fitsInTwosComp(info.signedness, info.bits)) {
                return sema.fail(block, src, "overflow of integer type '{f}' with value '{f}'", .{ sema.fmtType(ty), r.toConst() });
            } else {
                try r.truncate(&r, info.signedness, info.bits);
            }
        }
        if (tag == .shr_exact) {
            var back = try BigInt.init(sema.arena);
            try back.shiftLeft(&r, @intCast(amount));
            if (!back.eql(a)) return sema.fail(block, src, "exact shift shifted out 1 bits", .{});
        }
        return .fromInterned(try sema.bigToValue(ty, r.toConst()));
    };
    if (class == .comptime_int) return sema.fail(block, src, "LHS of shift must be a fixed-width integer type, or RHS must be comptime-known", .{});
    try sema.requireRuntime(block, src);
    const bits = Type.intInfo(ip, ty).bits;
    const shift_ty = try sema.intType(.unsigned, Type.log2IntBits(bits));
    if (sat) return sema.shlSat(block, src, ty, shift_ty, lhs, uncasted_rhs);
    const rhs = try sema.coerce(block, shift_ty, uncasted_rhs, src);
    if (block.want_safety and rv == null and !std.math.isPowerOfTwo(bits)) {
        const ok = try sema.addBinOp(block, .cmp_lt, rhs, .fromInterned(try sema.intValue(shift_ty, bits)));
        try sema.addSafetyCheck(block, ok, .shift_rhs_too_big, .none, .none);
    }
    const result = try sema.addBinOp(block, if (left) .shl else .shr, lhs, rhs);
    if (block.want_safety and (tag == .shl_exact or tag == .shr_exact)) {
        // Exact shifts shift out only zeros: shifting back restores lhs.
        const back = try sema.addBinOp(block, if (left) .shr else .shl, result, rhs);
        const ok = try sema.addBinOp(block, .cmp_eq, back, lhs);
        try sema.addSafetyCheck(block, ok, if (left) .shl_overflow else .shr_overflow, .none, .none);
    }
    return result;
}

/// Runtime `lhs <<| rhs`: the shifted value, or the bound on lhs's side of
/// zero when a nonzero bit shifts out or past the sign bit.
fn shlSat(sema: *Sema, block: *Block, src: Src, ty: Index, shift_ty: Index, lhs: Ref, rhs: Ref) CompileError!Ref {
    const ip = sema.ip;
    const bits = Type.intInfo(ip, ty).bits;
    var too_big: Ref = .fromInterned(.bool_false);
    var amount: Ref = undefined;
    if (sema.resolveValue(rhs)) |v| {
        const n = ip.intValue(u64, v) orelse std.math.maxInt(u64);
        if (n >= bits) too_big = .fromInterned(.bool_true);
        amount = .fromInterned(try sema.intValue(shift_ty, if (n >= bits) 0 else n));
    } else {
        const rhs_ty = sema.typeOf(rhs);
        const r = Type.intInfo(ip, rhs_ty);
        if (r.signedness == .signed) return sema.fail(block, src, "shift by signed type '{f}'", .{sema.fmtType(rhs_ty)});
        const s_bits = Type.intInfo(ip, shift_ty).bits;
        var clamped = rhs;
        if (r.bits >= 64 or (@as(u64, 1) << @intCast(r.bits)) > bits) {
            const limit: Ref = .fromInterned(try sema.intValue(rhs_ty, bits));
            too_big = try sema.addBinOp(block, .cmp_gte, rhs, limit);
            clamped = try sema.select(block, rhs_ty, too_big, .fromInterned(try sema.intValue(rhs_ty, 0)), rhs);
        }
        amount = if (r.bits > s_bits)
            try sema.addTyOp(block, .trunc, shift_ty, clamped)
        else if (r.bits < s_bits)
            try sema.addTyOp(block, .intcast, shift_ty, clamped)
        else
            clamped;
    }
    const shifted = try sema.addBinOp(block, .shl, lhs, amount);
    const back = try sema.addBinOp(block, .shr, shifted, amount);
    var overflowed = try sema.addBinOp(block, .cmp_neq, back, lhs);
    if (too_big != Ref.fromInterned(.bool_false)) {
        const nonzero = try sema.addBinOp(block, .cmp_neq, lhs, .fromInterned(try sema.intValue(ty, 0)));
        overflowed = if (too_big == Ref.fromInterned(.bool_true))
            nonzero
        else
            try sema.addBinOp(block, .bit_or, overflowed, try sema.addBinOp(block, .bit_and, too_big, nonzero));
    }
    const bound = if (Type.intInfo(ip, ty).signedness == .unsigned)
        Ref.fromInterned(try sema.maxIntValue(ty))
    else
        try sema.signedBound(block, ty, lhs);
    return sema.select(block, ty, overflowed, bound, shifted);
}

/// The minimum of signed `ty` if `sign_of` is negative, else its maximum.
fn signedBound(sema: *Sema, block: *Block, ty: Index, sign_of: Ref) CompileError!Ref {
    const negative = try sema.addBinOp(block, .cmp_lt, sign_of, .fromInterned(try sema.intValue(ty, 0)));
    return sema.select(block, ty, negative, .fromInterned(try sema.minIntValue(ty)), .fromInterned(try sema.maxIntValue(ty)));
}

/// Clamps `r` to the range of integer type `ty`.
fn saturate(sema: *Sema, r: *BigInt, ty: Index) !void {
    const info = Type.intInfo(sema.ip, ty);
    if (r.fitsInTwosComp(info.signedness, info.bits)) return;
    const bound = if (r.isPositive()) try sema.maxIntValue(ty) else try sema.minIntValue(ty);
    r.* = try sema.bigValue(bound);
}

fn analyzeNegate(sema: *Sema, block: *Block, src: Src, operand: Ref) CompileError!Ref {
    return sema.negate(block, src, operand, false);
}

fn analyzeNegateWrap(sema: *Sema, block: *Block, src: Src, operand: Ref) CompileError!Ref {
    return sema.negate(block, src, operand, true);
}

fn negate(sema: *Sema, block: *Block, src: Src, operand: Ref, wrap: bool) CompileError!Ref {
    if (try sema.vectorUnary(block, src, operand, if (wrap) analyzeNegateWrap else analyzeNegate)) |r| return r;
    const ty = sema.typeOf(operand);
    switch (Type.class(sema.ip, ty)) {
        .float, .comptime_float => {
            if (wrap) return sema.fail(block, src, "invalid operands to binary expression: '{t}' and '{t}'", .{ Type.class(sema.ip, ty), Type.class(sema.ip, ty) });
            return sema.analyzeFloatNegate(block, src, operand);
        },
        else => {},
    }
    const zero: Ref = if (ty == .comptime_int_type) .zero else .fromInterned(try sema.intValue(ty, 0));
    if (Type.class(sema.ip, ty) == .int and Type.intInfo(sema.ip, ty).signedness == .unsigned and !wrap)
        return sema.fail(block, src, "negation of type '{f}'", .{sema.fmtType(ty)});
    return sema.analyzeArithmetic(block, src, if (wrap) .subwrap else .sub, zero, operand);
}

fn analyzeIntFromBool(sema: *Sema, block: *Block, src: Src, uncasted: Ref) CompileError!Ref {
    if (try sema.vectorUnary(block, src, uncasted, analyzeIntFromBool)) |r| return r;
    const operand = try sema.coerce(block, .bool_type, uncasted, src);
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(.undef_u1);
        return .fromInterned(if (v == .bool_true) .one_u1 else .zero_u1);
    }
    return sema.addUnOp(block, .int_from_bool, operand);
}

fn analyzeBoolNot(sema: *Sema, block: *Block, src: Src, uncasted: Ref) CompileError!Ref {
    if (try sema.vectorUnary(block, src, uncasted, analyzeBoolNot)) |r| return r;
    const operand = try sema.coerce(block, .bool_type, uncasted, src);
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(v);
        return .fromInterned(boolValue(v != .bool_true));
    }
    return sema.addTyOp(block, .not, .bool_type, operand);
}

fn analyzeBitNot(sema: *Sema, block: *Block, src: Src, operand: Ref) CompileError!Ref {
    if (try sema.vectorUnary(block, src, operand, analyzeBitNot)) |r| return r;
    const ty = sema.typeOf(operand);
    if (ty == .bool_type) return sema.analyzeBoolNot(block, src, operand);
    if (Type.class(sema.ip, ty) != .int) return sema.fail(block, src, "unable to perform binary not operation on type '{f}'", .{sema.fmtType(ty)});
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(v);
        const a = try sema.bigValue(v);
        var r = try BigInt.init(sema.arena);
        const info = Type.intInfo(sema.ip, ty);
        try r.bitNotWrap(&a, info.signedness, info.bits);
        return .fromInterned(try sema.bigToValue(ty, r.toConst()));
    }
    try sema.requireRuntime(block, src);
    return sema.addTyOp(block, .not, ty, operand);
}

fn analyzeOverflowBuiltin(sema: *Sema, block: *Block, src: Src, op: Zir.Inst.Extended, uncasted_lhs: Ref, uncasted_rhs: Ref) CompileError!Ref {
    const ty = try sema.resolvePeerTypes(block, src, &.{ uncasted_lhs, uncasted_rhs });
    if (Type.class(sema.ip, ty) != .int) return sema.fail(block, src, "expected integer type, found '{f}'", .{sema.fmtType(ty)});
    const lhs = try sema.coerce(block, ty, uncasted_lhs, src);
    const rhs = try sema.coerce(block, ty, uncasted_rhs, src);
    const tuple_ty = try sema.overflowTupleType(ty);
    if (sema.resolveValue(lhs)) |lv| if (sema.resolveValue(rhs)) |rv| {
        if (sema.isUndef(lv) or sema.isUndef(rv)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
        const a = try sema.bigValue(lv);
        const b = try sema.bigValue(rv);
        var r = try BigInt.init(sema.arena);
        switch (op) {
            .add_with_overflow => try r.add(&a, &b),
            .sub_with_overflow => try r.sub(&a, &b),
            .mul_with_overflow => try r.mul(&a, &b),
            else => unreachable,
        }
        const info = Type.intInfo(sema.ip, ty);
        const overflowed = !r.fitsInTwosComp(info.signedness, info.bits);
        try r.truncate(&r, info.signedness, info.bits);
        const result = try sema.bigToValue(ty, r.toConst());
        return .fromInterned(try sema.intern(.{ .aggregate = .{ .ty = tuple_ty, .storage = .{ .elems = &.{ result, if (overflowed) .one_u1 else .zero_u1 } } } }));
    };
    try sema.requireRuntime(block, src);
    return sema.addTyPlBin(block, switch (op) {
        .add_with_overflow => .add_with_overflow,
        .sub_with_overflow => .sub_with_overflow,
        .mul_with_overflow => .mul_with_overflow,
        else => unreachable,
    }, tuple_ty, lhs, rhs);
}

/// `@shlWithOverflow`: the wrapped shift and whether it shifted out bits
/// that differ from the result's sign.
fn analyzeShlWithOverflow(sema: *Sema, block: *Block, src: Src, lhs: Ref, uncasted_rhs: Ref) CompileError!Ref {
    const ip = sema.ip;
    const ty = sema.typeOf(lhs);
    if (Type.class(ip, ty) != .int) return sema.fail(block, src, "expected integer type, found '{f}'", .{sema.fmtType(ty)});
    const info = Type.intInfo(ip, ty);
    const shift_ty = try sema.intType(.unsigned, Type.log2IntBits(info.bits));
    const rhs = try sema.coerce(block, shift_ty, uncasted_rhs, src);
    const tuple_ty = try sema.overflowTupleType(ty);
    const rv = sema.resolveValue(rhs);
    if (rv) |v| if (!sema.isUndef(v) and ip.intValue(u64, v).? >= info.bits)
        return sema.fail(block, src, "shift amount '{f}' is too large for operand type '{f}'", .{ sema.fmtValue(v), sema.fmtType(ty) });
    if (sema.resolveValue(lhs)) |lv| if (rv) |v| {
        if (sema.isUndef(lv) or sema.isUndef(v)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
        const a = try sema.bigValue(lv);
        var r = try BigInt.init(sema.arena);
        try r.shiftLeft(&a, @intCast(ip.intValue(u64, v).?));
        const overflowed = !r.fitsInTwosComp(info.signedness, info.bits);
        try r.truncate(&r, info.signedness, info.bits);
        return .fromInterned(try sema.intern(.{ .aggregate = .{ .ty = tuple_ty, .storage = .{ .elems = &.{ try sema.bigToValue(ty, r.toConst()), if (overflowed) .one_u1 else .zero_u1 } } } }));
    };
    try sema.requireRuntime(block, src);
    if (block.want_safety and rv == null and !std.math.isPowerOfTwo(info.bits)) {
        const ok = try sema.addBinOp(block, .cmp_lt, rhs, .fromInterned(try sema.intValue(shift_ty, info.bits)));
        try sema.addSafetyCheck(block, ok, .shift_rhs_too_big, .none, .none);
    }
    const result = try sema.addBinOp(block, .shl, lhs, rhs);
    const back = try sema.addBinOp(block, .shr, result, rhs);
    const bit = try sema.addUnOp(block, .int_from_bool, try sema.addBinOp(block, .cmp_neq, back, lhs));
    return sema.aggregate(block, src, tuple_ty, &.{ result, bit });
}

// ---------------------------------------------------------------------------
// Floats
//
// Comptime float math runs in the host's float type of the operation's
// precision (`comptime_float` is `f128`), as upstream's does, so results
// round exactly as upstream's do.

fn floatValue(sema: *Sema, ty: Index, value: anytype) !Index {
    return sema.ip.getFloat(Zcu.tid, ty, value);
}

/// A comptime-known integer or float as an `f128`; integers round to
/// nearest even.
fn toF128(sema: *Sema, val: Index) f128 {
    return switch (sema.ip.indexToKey(val)) {
        .float => |f| f.toF128(),
        .int => |int| switch (int.storage) {
            .u64 => |v| @floatFromInt(v),
            .i64 => |v| @floatFromInt(v),
            .big => |b| b.toFloat(f128, .nearest_even)[0],
        },
        else => unreachable,
    };
}

/// Float `val` converted to float type `ty`, rounded once from its own
/// precision.
fn floatCast(sema: *Sema, val: Index, ty: Index) !Index {
    return switch (sema.ip.indexToKey(val).float.storage) {
        inline else => |v| sema.floatValue(ty, v),
    };
}

fn isNan(sema: *Sema, val: Index) bool {
    return switch (sema.ip.indexToKey(val)) {
        .float => |f| switch (f.storage) {
            inline else => |x| std.math.isNan(x),
        },
        else => false,
    };
}

fn isInf(sema: *Sema, val: Index) ?enum { pos, neg } {
    return switch (sema.ip.indexToKey(val)) {
        .float => |f| switch (f.storage) {
            inline else => |x| if (std.math.isPositiveInf(x)) .pos else if (std.math.isNegativeInf(x)) .neg else null,
        },
        else => null,
    };
}

/// The order of two comptime-known numbers, neither NaN.
fn numOrder(sema: *Sema, a: Index, b: Index) std.math.Order {
    if (sema.ip.indexToKey(a) == .float or sema.ip.indexToKey(b) == .float) return std.math.order(sema.toF128(a), sema.toF128(b));
    var sa: [2]std.math.big.Limb = undefined;
    var sb: [2]std.math.big.Limb = undefined;
    return sema.ip.intToBig(a, &sa).order(sema.ip.intToBig(b, &sb));
}

/// Upstream's `Value.compareHetero` for numbers.
fn numCompare(sema: *Sema, a: Index, op: std.math.CompareOperator, b: Index) bool {
    if (sema.isNan(a) or sema.isNan(b)) return op == .neq;
    return sema.numOrder(a, b).compare(op);
}

/// Folds a binary float operation in the precision of `ty`.
fn foldFloat(sema: *Sema, op: Ir.Inst.Tag, ty: Index, lv: Index, rv: Index) !Index {
    const r = sema.ip.indexToKey(rv).float.storage;
    return switch (sema.ip.indexToKey(lv).float.storage) {
        inline else => |a, t| blk: {
            const b = @field(r, @tagName(t));
            break :blk sema.floatValue(ty, switch (op) {
                .add_float => a + b,
                .sub_float => a - b,
                .mul_float => a * b,
                .div_float => a / b,
                .div_trunc => @divTrunc(a, b),
                .div_floor => @divFloor(a, b),
                .div_ceil => @divCeil(a, b),
                .rem => @rem(a, b),
                .mod => @mod(a, b),
                else => unreachable,
            });
        },
    };
}

/// Folds a unary float operation in the precision of `ty`.
fn foldFloatUnary(sema: *Sema, op: Ir.Inst.Tag, ty: Index, v: Index) !Index {
    return switch (sema.ip.indexToKey(v).float.storage) {
        inline else => |a| sema.floatValue(ty, switch (op) {
            .neg_float => -a,
            .sqrt => @sqrt(a),
            .sin => @sin(a),
            .cos => @cos(a),
            .tan => @tan(a),
            .exp => @exp(a),
            .exp2 => @exp2(a),
            .log => @log(a),
            .log2 => @log2(a),
            .log10 => @log10(a),
            .abs_float => @abs(a),
            .floor => @floor(a),
            .ceil => @ceil(a),
            .round => @round(a),
            .trunc_float => @trunc(a),
            else => unreachable,
        }),
    };
}

fn isFloatZero(sema: *Sema, val: Index) bool {
    return sema.ip.indexToKey(val) == .float and sema.toF128(val) == 0;
}

/// Binary arithmetic on operands whose peer type `ty` is a float type.
fn analyzeFloatArithmetic(sema: *Sema, block: *Block, src: Src, tag: Zir.Inst.Tag, ty: Index, uncasted_lhs: Ref, uncasted_rhs: Ref) CompileError!Ref {
    const ip = sema.ip;
    const lt = sema.typeOf(uncasted_lhs);
    const rt = sema.typeOf(uncasted_rhs);
    switch (tag) {
        .add, .add_unsafe, .sub, .mul, .div, .div_trunc, .div_floor, .div_ceil, .div_exact, .rem, .mod, .mod_rem, .min, .max => {},
        else => return sema.fail(block, src, "invalid operands to binary expression: '{t}' and '{t}'", .{ Type.class(ip, lt), Type.class(ip, rt) }),
    }
    const lhs = try sema.coerce(block, ty, uncasted_lhs, src);
    const rhs = try sema.coerce(block, ty, uncasted_rhs, src);
    const lv = sema.resolveValue(lhs);
    const rv = sema.resolveValue(rhs);

    if (tag == .min or tag == .max) {
        if (lv != null and rv != null) {
            const a = lv.?;
            const b = rv.?;
            if (sema.isUndef(a) or sema.isUndef(b)) return .fromInterned(try sema.undefValue(ty));
            if (sema.isNan(a)) return .fromInterned(b);
            if (sema.isNan(b)) return .fromInterned(a);
            return .fromInterned(if (sema.numCompare(a, if (tag == .min) .lt else .gt, b)) a else b);
        }
        try sema.requireRuntime(block, src);
        return sema.addBinOp(block, if (tag == .min) .min_float else .max_float, lhs, rhs);
    }

    if (tag == .mod_rem) {
        // `%` on floats is ambiguous between `@rem` and `@mod` unless both
        // operands are comptime-known and the remainder is zero or both are
        // non-negative.
        const zero = try sema.floatValue(ty, @as(f128, 0));
        if (lv != null and rv != null and !sema.isUndef(lv.?) and !sema.isUndef(rv.?)) {
            const r = try sema.foldFloat(.rem, ty, lv.?, rv.?);
            const neg = !sema.numCompare(lv.?, .gte, zero) or !sema.numCompare(rv.?, .gte, zero);
            if (!neg or sema.numCompare(r, .eq, zero)) return .fromInterned(r);
        }
        return sema.fail(block, src, "remainder division with '{f}' and '{f}': signed integers and floats must use @rem or @mod", .{ sema.fmtType(lt), sema.fmtType(rt) });
    }

    // `/` of a `comptime_int` and a `comptime_float` must not depend on
    // which one is coerced.
    if (tag == .div and ((lt == .comptime_float_type and rt == .comptime_int_type) or (lt == .comptime_int_type and rt == .comptime_float_type))) {
        const r = try sema.foldFloat(.rem, ty, lv.?, rv.?);
        if (!sema.isFloatZero(r)) return sema.fail(block, src, "ambiguous coercion of division operands '{f}' and '{f}'; non-zero remainder '{f}'", .{ sema.fmtType(lt), sema.fmtType(rt), sema.fmtValue(r) });
    }

    const op: Ir.Inst.Tag = switch (tag) {
        .add, .add_unsafe => .add_float,
        .sub => .sub_float,
        .mul => .mul_float,
        .div => .div_float,
        .div_trunc, .div_exact => .div_trunc,
        .div_floor => .div_floor,
        .div_ceil => .div_ceil,
        .rem => .rem,
        .mod => .mod,
        else => unreachable,
    };
    const is_div = switch (tag) {
        .div, .div_trunc, .div_floor, .div_ceil, .div_exact => true,
        else => false,
    };
    // Floats divide by zero to infinities and NaNs, except `comptime_float`
    // and `@divExact`, for which it is illegal.
    const allow_div_zero = !is_div or (ty != .comptime_float_type and tag != .div_exact);
    const can_be_ib = !allow_div_zero or tag == .div_exact;

    if (lv != null and rv != null) {
        const a = lv.?;
        const b = rv.?;
        if (!allow_div_zero and sema.isFloatZero(b)) return sema.fail(block, src, "division by zero here causes illegal behavior", .{});
        if (sema.isUndef(a) or sema.isUndef(b)) {
            if (can_be_ib) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
            return .fromInterned(try sema.undefValue(ty));
        }
        if (tag == .div_exact and !sema.isFloatZero(try sema.foldFloat(.mod, ty, a, b)))
            return sema.fail(block, src, "exact division produced remainder", .{});
        return .fromInterned(try sema.foldFloat(op, ty, a, b));
    }
    for ([_]?Index{ lv, rv }, 0..) |known, i| {
        const v = known orelse continue;
        if (sema.isUndef(v)) {
            if (can_be_ib) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
            return .fromInterned(try sema.undefValue(ty));
        }
        if (i == 1 and !allow_div_zero and sema.isFloatZero(v)) return sema.fail(block, src, "division by zero here causes illegal behavior", .{});
    }
    try sema.requireRuntime(block, src);
    if (ty == .comptime_float_type) return sema.fail(block, src, "unable to resolve comptime value", .{});
    const result = try sema.addBinOp(block, op, lhs, rhs);
    if (tag == .div_exact and block.want_safety) {
        // Upstream's check: the truncated quotient is integral.
        const floored = try sema.addUnOp(block, .floor, result);
        const ok = try sema.addBinOp(block, .cmp_eq, result, floored);
        try sema.addSafetyCheck(block, ok, .exact_division_remainder, .none, .none);
    }
    return result;
}

/// `@abs`: integers become unsigned of the same width.
fn analyzeAbs(sema: *Sema, block: *Block, src: Src, operand: Ref) CompileError!Ref {
    const ip = sema.ip;
    if (try sema.vectorUnary(block, src, operand, analyzeAbs)) |r| return r;
    const ty = sema.typeOf(operand);
    switch (Type.class(ip, ty)) {
        .float, .comptime_float => return sema.analyzeFloatUnary(block, src, .abs_float, operand),
        .comptime_int, .int => {},
        else => return sema.fail(block, src, "expected integer, float, or vector of either integers or floats, found '{f}'", .{sema.fmtType(ty)}),
    }
    const info: Type.IntInfo = if (ty == .comptime_int_type) .{ .signedness = .signed, .bits = 0 } else Type.intInfo(ip, ty);
    if (info.signedness == .unsigned) return operand;
    // As upstream's `Type.toUnsigned`: C integer types keep their C names.
    const result_ty: Index = switch (ty) {
        .comptime_int_type => ty,
        .isize_type => .usize_type,
        .c_short_type => .c_ushort_type,
        .c_int_type => .c_uint_type,
        .c_long_type => .c_ulong_type,
        .c_longlong_type => .c_ulonglong_type,
        else => try sema.intType(.unsigned, info.bits),
    };
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(result_ty));
        var big = try sema.bigValue(v);
        big.abs();
        return .fromInterned(try sema.bigToValue(result_ty, big.toConst()));
    }
    try sema.requireRuntime(block, src);
    if (info.bits == 0) return .fromInterned(try sema.intValue(result_ty, 0));
    // `(x ^ s) -% s` with `s = x >> (bits - 1)`.
    const shift_ty = try sema.intType(.unsigned, Type.log2IntBits(info.bits));
    const s = try sema.addBinOp(block, .shr, operand, .fromInterned(try sema.intValue(shift_ty, info.bits - 1)));
    const flipped = try sema.addBinOp(block, .xor, operand, s);
    const diff = try sema.addBinOp(block, .sub_wrap, flipped, s);
    return sema.addTyOp(block, .bitcast, result_ty, diff);
}

/// `-x` of a float.
fn analyzeFloatNegate(sema: *Sema, block: *Block, src: Src, operand: Ref) CompileError!Ref {
    const ty = sema.typeOf(operand);
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(v);
        return .fromInterned(try sema.foldFloatUnary(.neg_float, ty, v));
    }
    try sema.requireRuntime(block, src);
    return sema.addUnOp(block, .neg_float, operand);
}

/// `@sqrt`, `@sin`, ..., `@round`, and `@abs` of a float.
fn analyzeFloatUnary(sema: *Sema, block: *Block, src: Src, op: Ir.Inst.Tag, operand: Ref) CompileError!Ref {
    const ty = sema.typeOf(operand);
    if (sema.vectorLen(ty)) |len| return sema.vectorMap(block, src, len, .none, &.{operand}, struct {
        op: Ir.Inst.Tag,
        fn call(o: @This(), s: *Sema, b: *Block, sr: Src, e: []const Ref) CompileError!Ref {
            return s.analyzeFloatUnary(b, sr, o.op, e[0]);
        }
    }{ .op = op });
    const class = Type.class(sema.ip, ty);
    if (class != .float and class != .comptime_float)
        return sema.fail(block, src, "expected float type, found '{f}'", .{sema.fmtType(ty)});
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(v);
        return .fromInterned(try sema.foldFloatUnary(op, ty, v));
    }
    try sema.requireRuntime(block, src);
    return sema.addUnOp(block, op, operand);
}

/// `@min` and `@max`, as upstream's `analyzeMinMax`: comptime-known
/// operands fold first; integer results get the smallest type that holds
/// every possible result (`@max(u32, i64)` is a `u63`), computed in a type
/// that holds every operand.
fn analyzeMinMax(sema: *Sema, block: *Block, src: Src, tag: Zir.Inst.Tag, operands: []const Ref) CompileError!Ref {
    const ip = sema.ip;
    const first_ty = sema.typeOf(operands[0]);
    const vector_len = sema.vectorLen(first_ty);
    for (operands) |o| {
        const ty = sema.typeOf(o);
        const c = Type.class(ip, Type.scalarType(ip, ty));
        if (c != .int and c != .comptime_int and c != .float and c != .comptime_float)
            return sema.fail(block, src, "expected number, found '{f}'", .{sema.fmtType(ty)});
        const len = sema.vectorLen(ty);
        if ((len == null) != (vector_len == null)) return sema.fail(block, src, "expected vector, found '{f}'", .{sema.fmtType(if (len == null) ty else first_ty)});
        if (len != null and len.? != vector_len.?) return sema.fail(block, src, "expected vector of length '{d}', found '{f}'", .{ vector_len.?, sema.fmtType(ty) });
    }
    if (operands.len == 1) return operands[0];

    // The scalar result and intermediate types.
    var float_ty: Index = .none;
    var all_comptime_int = true;
    var r_min: ?BigInt = null;
    var r_max: ?BigInt = null;
    var o_min: ?BigInt = null;
    var o_max: ?BigInt = null;
    for (operands) |o| {
        const ty = Type.scalarType(ip, sema.typeOf(o));
        switch (Type.class(ip, ty)) {
            .float => float_ty = if (float_ty == .none or float_ty == .comptime_float_type or Type.floatBits(ip, ty) > Type.floatBits(ip, float_ty)) ty else float_ty,
            .comptime_float => if (float_ty == .none) {
                float_ty = .comptime_float_type;
            },
            else => {
                var lo: BigInt = undefined;
                var hi: BigInt = undefined;
                const val = sema.resolveValue(o);
                if (ty != .comptime_int_type) all_comptime_int = false;
                if (val != null and !sema.isUndef(val.?) and vector_len == null) {
                    lo = try sema.bigValue(val.?);
                    hi = lo;
                } else if (val != null and vector_len != null and !sema.isUndef(val.?)) {
                    lo = try sema.bigValue(try sema.elemValue(val.?, 0));
                    hi = lo;
                    for (1..vector_len.?) |i| {
                        const e = try sema.elemValue(val.?, i);
                        if (sema.isUndef(e)) break;
                        const b = try sema.bigValue(e);
                        if (b.order(lo) == .lt) lo = b;
                        if (b.order(hi) == .gt) hi = b;
                    }
                } else if (ty == .comptime_int_type) {
                    continue; // An undefined comptime_int.
                } else {
                    lo = try sema.bigValue(try sema.minIntValue(ty));
                    hi = try sema.bigValue(try sema.maxIntValue(ty));
                }
                const pick = struct {
                    fn f(cur: ?BigInt, new: BigInt, want: std.math.Order) BigInt {
                        const c = cur orelse return new;
                        return if (new.order(c) == want) new else c;
                    }
                }.f;
                const want_r: std.math.Order = if (tag == .min) .lt else .gt;
                r_min = pick(r_min, lo, want_r);
                r_max = pick(r_max, hi, want_r);
                o_min = pick(o_min, lo, .lt);
                o_max = pick(o_max, hi, .gt);
            },
        }
    }
    const result_scalar: Index, const inter_scalar: Index = if (float_ty != .none)
        .{ float_ty, float_ty }
    else if (all_comptime_int or r_min == null)
        .{ .comptime_int_type, .comptime_int_type }
    else
        .{ try sema.intFittingRange(r_min.?, r_max.?), try sema.intFittingRange(o_min.?, o_max.?) };
    const result_ty = if (vector_len) |len| try sema.vectorType(len, result_scalar) else result_scalar;
    const inter_ty = if (vector_len) |len| try sema.vectorType(len, inter_scalar) else inter_scalar;
    if (Type.isInt(ip, result_scalar) and Type.intInfo(ip, result_scalar).bits == 0) {
        const zero: Ref = .fromInterned(try sema.intValue(result_scalar, 0));
        if (vector_len) |len| {
            const elems = try sema.arena.alloc(Ref, len);
            @memset(elems, zero);
            return sema.aggregate(block, src, result_ty, elems);
        }
        return zero;
    }

    // Comptime-known operands first, then runtime ones, in order.
    var cur: Ref = .none;
    for ([_]bool{ true, false }) |known| for (operands) |o| {
        if ((sema.resolveValue(o) != null) != known) continue;
        const x = try sema.coerce(block, inter_ty, o, src);
        cur = if (cur == .none) x else try sema.analyzeArithmetic(block, src, tag, cur, x);
    };
    if (result_ty == inter_ty) return cur;
    // The result fits: no safety check.
    return if (vector_len != null)
        (try sema.vectorCast(block, src, result_ty, cur, intCastUnchecked)).?
    else
        sema.intCastUnchecked(block, src, result_ty, cur);
}

/// The smallest integer type holding `min` through `max`, as upstream's
/// `intFittingRange`.
fn intFittingRange(sema: *Sema, min: BigInt, max: BigInt) !Index {
    const sign = !min.isPositive() and !min.eqlZero();
    const bits = struct {
        fn f(b: BigInt, s: bool) usize {
            if (b.eqlZero()) return @intFromBool(s);
            if (b.isPositive()) return b.bitCountAbs() + @intFromBool(s);
            return b.bitCountTwosComp();
        }
    }.f;
    return sema.intType(if (sign) .signed else .unsigned, @intCast(@max(bits(min, sign), bits(max, sign))));
}

/// An integer cast known to fit.
fn intCastUnchecked(sema: *Sema, block: *Block, src: Src, dest_ty: Index, operand: Ref) CompileError!Ref {
    _ = src;
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(dest_ty));
        return .fromInterned(try sema.bigToValue(dest_ty, (try sema.bigValue(v)).toConst()));
    }
    return sema.addTyOp(block, .intcast, dest_ty, operand);
}

const IntFromFloatMode = enum { exact, truncate, round, floor, ceil };

/// Comptime-known float `val` as integer type `int_ty`.
fn intFromFloat(sema: *Sema, block: *Block, src: Src, val: Index, int_ty: Index, mode: IntFromFloatMode) CompileError!Index {
    if (sema.isUndef(val)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
    var float = sema.toF128(val);
    switch (mode) {
        .round => float = @round(float),
        .floor => float = @floor(float),
        .ceil => float = @ceil(float),
        .truncate, .exact => {},
    }
    if (std.math.isNan(float)) return sema.fail(block, src, "float value NaN cannot be stored in integer type '{f}'", .{sema.fmtType(int_ty)});
    if (std.math.isInf(float)) return sema.fail(block, src, "float value Inf cannot be stored in integer type '{f}'", .{sema.fmtType(int_ty)});
    var big: std.math.big.int.Mutable = .{ .limbs = try sema.arena.alloc(std.math.big.Limb, std.math.big.int.calcLimbLen(float)), .len = undefined, .positive = undefined };
    if (big.setFloat(float, .trunc) == .inexact and mode == .exact)
        return sema.fail(block, src, "fractional component prevents float value '{f}' from coercion to type '{f}'", .{ sema.fmtValue(val), sema.fmtType(int_ty) });
    if (int_ty != .comptime_int_type) {
        const info = Type.intInfo(sema.ip, int_ty);
        if (!big.toConst().fitsInTwosComp(info.signedness, info.bits))
            return sema.fail(block, src, "float value '{f}' cannot be stored in integer type '{f}'", .{ sema.fmtValue(val), sema.fmtType(int_ty) });
    }
    return sema.bigToValue(int_ty, big.toConst());
}

/// Runtime float `operand` truncated (after rounding by `mode`) to integer
/// type `int_ty`, with the bounds check upstream emits.
fn analyzeIntFromFloat(sema: *Sema, block: *Block, src: Src, operand: Ref, int_ty: Index, mode: IntFromFloatMode) CompileError!Ref {
    _ = src;
    const ip = sema.ip;
    const float_ty = sema.typeOf(operand);
    const rounded = switch (mode) {
        .truncate, .exact => operand,
        .round => try sema.addUnOp(block, .round, operand),
        .floor => try sema.addUnOp(block, .floor, operand),
        .ceil => try sema.addUnOp(block, .ceil, operand),
    };
    const info = Type.intInfo(ip, int_ty);
    if (block.want_safety) {
        // The truncated value fits iff `min - 1 < x < max + 1`. `max + 1`
        // is a power of two; `min - 1` is used when the float type
        // represents it, else the floats above it start at `min`.
        const hi = try sema.floatValue(float_ty, std.math.ldexp(@as(f128, 1), @as(i32, info.bits) - @intFromBool(info.signedness == .signed)));
        const lo_exact: f128 = if (info.signedness == .unsigned) -1 else -std.math.ldexp(@as(f128, 1), @as(i32, info.bits) - 1) - 1;
        const lo = try sema.floatValue(float_ty, lo_exact);
        const lo_ok = if (sema.toF128(lo) == lo_exact or std.math.isInf(sema.toF128(lo)))
            try sema.addBinOp(block, .cmp_gt, rounded, .fromInterned(lo))
        else
            try sema.addBinOp(block, .cmp_gte, rounded, .fromInterned(lo));
        const hi_ok = try sema.addBinOp(block, .cmp_lt, rounded, .fromInterned(hi));
        const ok = try sema.addBinOp(block, .bit_and, lo_ok, hi_ok);
        try sema.addSafetyCheck(block, ok, .integer_part_out_of_bounds, .none, .none);
    }
    if (info.bits == 0) return .fromInterned(try sema.intValue(int_ty, 0));
    return sema.addTyOp(block, .int_from_float, int_ty, rounded);
}

/// `@intFromFloat`, and `@round`... with an integer result type.
fn analyzeFloatToIntTruncate(sema: *Sema, block: *Block, src: Src, dest_ty: Index, operand: Ref) CompileError!Ref {
    return sema.analyzeFloatToInt(block, src, dest_ty, operand, .truncate);
}

fn analyzeFloatToInt(sema: *Sema, block: *Block, src: Src, dest_ty: Index, operand: Ref, mode: IntFromFloatMode) CompileError!Ref {
    const ip = sema.ip;
    if (mode == .truncate) if (try sema.vectorCast(block, src, dest_ty, operand, analyzeFloatToIntTruncate)) |r| return r;
    const ty = sema.typeOf(operand);
    if (Type.class(ip, dest_ty) != .int and dest_ty != .comptime_int_type) return sema.fail(block, src, "expected integer result type, found '{f}'", .{sema.fmtType(dest_ty)});
    const class = Type.class(ip, ty);
    if (class != .float and class != .comptime_float) return sema.fail(block, src, "expected float type, found '{f}'", .{sema.fmtType(ty)});
    if (sema.resolveValue(operand)) |v| return .fromInterned(try sema.intFromFloat(block, src, v, dest_ty, mode));
    if (dest_ty == .comptime_int_type) return sema.fail(block, src, "unable to resolve comptime value", .{});
    try sema.requireRuntime(block, src);
    return sema.analyzeIntFromFloat(block, src, operand, dest_ty, mode);
}

fn zirFloatFromInt(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Bin, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    const dest_ty = sema.unwrapOptEu(try sema.resolveType(block, src, extra.lhs));
    return sema.analyzeFloatFromInt(block, src, dest_ty, sema.resolveInst(extra.rhs));
}

fn analyzeFloatFromInt(sema: *Sema, block: *Block, src: Src, dest_ty: Index, operand: Ref) CompileError!Ref {
    const ip = sema.ip;
    if (try sema.vectorCast(block, src, dest_ty, operand, analyzeFloatFromInt)) |r| return r;
    const ty = sema.typeOf(operand);
    const dc = Type.class(ip, dest_ty);
    if (dc != .float and dc != .comptime_float) return sema.fail(block, src, "expected float result type, found '{f}'", .{sema.fmtType(dest_ty)});
    if (Type.class(ip, ty) != .int and ty != .comptime_int_type) return sema.fail(block, src, "expected integer type, found '{f}'", .{sema.fmtType(ty)});
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(dest_ty));
        return .fromInterned(try sema.floatValue(dest_ty, sema.toF128(v)));
    }
    if (dc == .comptime_float) return sema.fail(block, src, "unable to resolve comptime value", .{});
    try sema.requireRuntime(block, src);
    return sema.addTyOp(block, .float_from_int, dest_ty, operand);
}

fn zirFloatCast(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Bin, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    const dest_ty = sema.unwrapOptEu(try sema.resolveType(block, src, extra.lhs));
    return sema.analyzeFloatCast(block, src, dest_ty, sema.resolveInst(extra.rhs));
}

fn analyzeFloatCast(sema: *Sema, block: *Block, src: Src, dest_ty: Index, operand: Ref) CompileError!Ref {
    const ip = sema.ip;
    if (try sema.vectorCast(block, src, dest_ty, operand, analyzeFloatCast)) |r| return r;
    const ty = sema.typeOf(operand);
    const dc = Type.class(ip, dest_ty);
    const sc = Type.class(ip, ty);
    if (dc != .float and dc != .comptime_float) return sema.fail(block, src, "expected float or vector type, found '{f}'", .{sema.fmtType(dest_ty)});
    if (sc != .float and sc != .comptime_float) return sema.fail(block, src, "expected float or vector type, found '{f}'", .{sema.fmtType(ty)});
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(dest_ty));
        return .fromInterned(try sema.floatCast(v, dest_ty));
    }
    if (dc == .comptime_float) return sema.fail(block, src, "unable to cast runtime value to 'comptime_float'", .{});
    try sema.requireRuntime(block, src);
    if (Type.floatBits(ip, dest_ty) == Type.floatBits(ip, ty)) return sema.addTyOp(block, .bitcast, dest_ty, operand);
    return sema.addTyOp(block, .float_cast, dest_ty, operand);
}

fn zirMulAdd(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.MulAdd, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    const addend = sema.resolveInst(extra.addend);
    const ty = sema.typeOf(addend);
    if (sema.vectorLen(ty)) |len| {
        const a = try sema.coerce(block, ty, sema.resolveInst(extra.mulend1), src);
        const b = try sema.coerce(block, ty, sema.resolveInst(extra.mulend2), src);
        return sema.vectorMap(block, src, len, ty, &.{ a, b, addend }, struct {
            fn call(_: @This(), s: *Sema, blk: *Block, sr: Src, e: []const Ref) CompileError!Ref {
                return s.mulAdd(blk, sr, e[0], e[1], e[2]);
            }
        }{});
    }
    return sema.mulAdd(block, src, sema.resolveInst(extra.mulend1), sema.resolveInst(extra.mulend2), addend);
}

fn mulAdd(sema: *Sema, block: *Block, src: Src, mulend1: Ref, mulend2: Ref, addend: Ref) CompileError!Ref {
    const ip = sema.ip;
    const ty = sema.typeOf(addend);
    const class = Type.class(ip, ty);
    if (class != .float and class != .comptime_float) return sema.fail(block, src, "expected vector of floats or float type, found '{f}'", .{sema.fmtType(ty)});
    const a = try sema.coerce(block, ty, mulend1, src);
    const b = try sema.coerce(block, ty, mulend2, src);
    const av = sema.resolveValue(a);
    const bv = sema.resolveValue(b);
    const cv = sema.resolveValue(addend);
    if (av != null and bv != null and cv != null) {
        if (sema.isUndef(av.?) or sema.isUndef(bv.?) or sema.isUndef(cv.?)) return .fromInterned(try sema.undefValue(ty));
        const x = ip.indexToKey(bv.?).float.storage;
        const y = ip.indexToKey(cv.?).float.storage;
        return .fromInterned(switch (ip.indexToKey(av.?).float.storage) {
            inline else => |m, t| try sema.floatValue(ty, @mulAdd(@TypeOf(m), m, @field(x, @tagName(t)), @field(y, @tagName(t)))),
        });
    }
    try sema.requireRuntime(block, src);
    const payload = try sema.addExtra(Ir.Bin{ .lhs = a, .rhs = b });
    return sema.addInst(block, .{ .tag = .mul_add, .data = .{ .pl_op = .{ .operand = addend, .payload = payload } } });
}

fn cmpTag(op: std.math.CompareOperator) Ir.Inst.Tag {
    return switch (op) {
        .lt => .cmp_lt,
        .lte => .cmp_lte,
        .eq => .cmp_eq,
        .gte => .cmp_gte,
        .gt => .cmp_gt,
        .neq => .cmp_neq,
    };
}

/// A comparison of numbers at least one of which is a float: upstream's
/// `cmpNumeric`, including its comptime shortcuts and the integer type it
/// compares a float with an integer in.
fn cmpFloat(sema: *Sema, block: *Block, src: Src, op: std.math.CompareOperator, uncasted_lhs: Ref, uncasted_rhs: Ref) CompileError!Ref {
    const ip = sema.ip;
    const lt0 = sema.typeOf(uncasted_lhs);
    const rt0 = sema.typeOf(uncasted_rhs);
    // `comptime_float` coerces to the other operand's fixed-width float.
    const lhs = if (lt0 == .comptime_float_type and Type.class(ip, rt0) == .float) try sema.coerce(block, rt0, uncasted_lhs, src) else uncasted_lhs;
    const rhs = if (rt0 == .comptime_float_type and Type.class(ip, lt0) == .float) try sema.coerce(block, lt0, uncasted_rhs, src) else uncasted_rhs;
    const lt = sema.typeOf(lhs);
    const rt = sema.typeOf(rhs);
    const lc = Type.class(ip, lt);
    const rc = Type.class(ip, rt);
    const l_float = lc == .float or lc == .comptime_float;
    const r_float = rc == .float or rc == .comptime_float;
    const lv = sema.resolveValue(lhs);
    const rv = sema.resolveValue(rhs);

    // A known NaN or infinity decides some results alone.
    for ([_]?Index{ lv, rv }, 0..) |known, i| {
        const v = known orelse continue;
        if (sema.isNan(v)) return .fromInterned(boolValue(op == .neq));
        const other = if (i == 0) rc else lc;
        if (other != .int) continue;
        const sign = sema.isInf(v) orelse continue;
        // Relation of the infinity to the other operand.
        const inf_gt = sign == .pos;
        const left_gt = if (i == 0) inf_gt else !inf_gt;
        return .fromInterned(boolValue(switch (op) {
            .neq => true,
            .eq => false,
            .gt, .gte => left_gt,
            .lt, .lte => !left_gt,
        }));
    }
    if (lv) |v| if (sema.isUndef(v)) return .fromInterned(.undef_bool);
    if (rv) |v| if (sema.isUndef(v)) return .fromInterned(.undef_bool);
    if (lv != null and rv != null) return .fromInterned(boolValue(sema.numCompare(lv.?, op, rv.?)));
    try sema.requireRuntime(block, src);

    if (l_float and r_float) {
        const dest_ty = if (lc == .comptime_float) rt else if (rc == .comptime_float) lt else if (Type.floatBits(ip, lt) >= Type.floatBits(ip, rt)) lt else rt;
        return sema.addBinOp(block, cmpTag(op), try sema.coerce(block, dest_ty, lhs, src), try sema.coerce(block, dest_ty, rhs, src));
    }

    // A float and an integer: compare in the float type if the float is
    // runtime-known, else in an integer type wide enough for both.
    const zero: Index = .zero;
    const l_signed = if (lv) |v| !sema.numCompare(v, .gte, zero) else (lc == .float or Type.intInfo(ip, lt).signedness == .signed);
    const r_signed = if (rv) |v| !sema.numCompare(v, .gte, zero) else (rc == .float or Type.intInfo(ip, rt).signedness == .signed);
    const dest_signed = l_signed or r_signed;
    var dest_float: Index = .none;
    var bits: [2]usize = undefined;
    const sides = [2]struct { val: ?Index, ty: Index, is_float: bool, other_signed: bool }{
        .{ .val = lv, .ty = lt, .is_float = l_float, .other_signed = r_signed },
        .{ .val = rv, .ty = rt, .is_float = r_float, .other_signed = l_signed },
    };
    for (sides, &bits, 0..) |side, *b, i| {
        // `op` with this side on the left.
        const side_op = if (i == 0) op else op.reverse();
        const is_signed = if (i == 0) l_signed else r_signed;
        if (side.val) |v| {
            if (!side.other_signed) switch (sema.numOrder(v, zero)) {
                .gt => {},
                // The other side is unsigned.
                .eq => switch (side_op) {
                    .lte => return .fromInterned(.bool_true),
                    .gt => return .fromInterned(.bool_false),
                    else => {},
                },
                .lt => return .fromInterned(boolValue(switch (side_op) {
                    .neq, .lt, .lte => true,
                    .eq, .gt, .gte => false,
                })),
            };
            if (side.is_float) {
                const f = sema.toF128(v);
                var m: std.math.big.int.Mutable = .{ .limbs = try sema.arena.alloc(std.math.big.Limb, std.math.big.int.calcLimbLen(f)), .len = undefined, .positive = undefined };
                if (m.setFloat(f, .away) == .inexact) switch (op) {
                    .eq => return .fromInterned(.bool_false),
                    .neq => return .fromInterned(.bool_true),
                    else => {},
                };
                b.* = m.toConst().bitCountTwosComp();
            } else {
                var space: [2]std.math.big.Limb = undefined;
                b.* = ip.intToBig(v, &space).bitCountTwosComp();
            }
            b.* += @intFromBool(!is_signed and dest_signed);
        } else if (side.is_float) {
            dest_float = side.ty;
        } else {
            const info = Type.intInfo(ip, side.ty);
            b.* = info.bits + @intFromBool(info.signedness == .unsigned and dest_signed);
        }
    }
    const dest_ty = if (dest_float != .none) dest_float else blk: {
        const max_bits = @max(bits[0], bits[1]);
        const casted = std.math.cast(u16, max_bits) orelse return sema.fail(block, src, "{d} exceeds maximum integer bit count", .{max_bits});
        break :blk try sema.intType(if (dest_signed) .signed else .unsigned, casted);
    };
    return sema.addBinOp(block, cmpTag(op), try sema.coerce(block, dest_ty, lhs, src), try sema.coerce(block, dest_ty, rhs, src));
}

/// `==` and `!=` where an operand is optional: null equals only null, and
/// payloads compare like their type.
fn cmpOptional(sema: *Sema, block: *Block, src: Src, op: std.math.CompareOperator, lhs: Ref, rhs: Ref) CompileError!Ref {
    const ip = sema.ip;
    const l_opt = Type.class(ip, sema.typeOf(lhs)) == .optional;
    const r_opt = Type.class(ip, sema.typeOf(rhs)) == .optional;
    const Side = struct { nn: ?Ref, payload: Ref };
    const side = struct {
        fn f(s: *Sema, b: *Block, sr: Src, r: Ref, is_opt: bool) CompileError!?Side {
            if (!is_opt) return .{ .nn = null, .payload = r };
            if (s.resolveValue(r)) |v| {
                if (s.isUndef(v)) return s.fail(b, sr, "use of undefined value here causes illegal behavior", .{});
                const pv = s.ip.indexToKey(v).opt.val;
                // Comptime-known null.
                if (pv == .none) return null;
                return .{ .nn = null, .payload = .fromInterned(pv) };
            }
            return .{ .nn = try s.analyzeIsNonNull(b, sr, r), .payload = try s.optionalPayload(b, sr, r, false) };
        }
    }.f;
    const l = try side(sema, block, src, lhs, l_opt);
    const r = try side(sema, block, src, rhs, r_opt);
    var eq: Ref = undefined;
    if (l == null or r == null) {
        // One side is null: equal when the other is null too.
        const other = if (l == null) r else l;
        eq = if (other == null) .fromInterned(.bool_true) else if (other.?.nn) |nn| try sema.boolNot(block, nn) else .fromInterned(.bool_false);
    } else {
        const pe = try sema.analyzeCmp(block, src, .eq, l.?.payload, r.?.payload);
        if (l.?.nn != null and r.?.nn != null) {
            // (nn_l == nn_r) and (!nn_l or payloads equal)
            const same = try sema.analyzeCmp(block, src, .eq, l.?.nn.?, r.?.nn.?);
            eq = try sema.boolOp(block, .bit_and, same, try sema.boolOp(block, .bit_or, try sema.boolNot(block, l.?.nn.?), pe));
        } else if (l.?.nn orelse r.?.nn) |nn| {
            eq = try sema.boolOp(block, .bit_and, nn, pe);
        } else eq = pe;
    }
    return if (op == .eq) eq else sema.boolNot(block, eq);
}

fn boolNot(sema: *Sema, block: *Block, operand: Ref) CompileError!Ref {
    if (sema.resolveValue(operand)) |v| if (!sema.isUndef(v)) return .fromInterned(boolValue(v != .bool_true));
    return sema.addTyOp(block, .not, .bool_type, operand);
}

fn boolOp(sema: *Sema, block: *Block, tag: Ir.Inst.Tag, a: Ref, b: Ref) CompileError!Ref {
    const av = sema.resolveValue(a);
    const bv = sema.resolveValue(b);
    const absorbing: Index = if (tag == .bit_and) .bool_false else .bool_true;
    if (av == absorbing or bv == absorbing) return .fromInterned(absorbing);
    if (av != null and bv != null) return .fromInterned(if (tag == .bit_and) boolValue(av == .bool_true and bv == .bool_true) else boolValue(av == .bool_true or bv == .bool_true));
    // The identity element drops out.
    if (av != null) return b;
    if (bv != null) return a;
    return sema.addBinOp(block, tag, a, b);
}

fn analyzeCmp(sema: *Sema, block: *Block, src: Src, op: std.math.CompareOperator, lhs: Ref, rhs: Ref) CompileError!Ref {
    const ip = sema.ip;
    const lt = sema.typeOf(lhs);
    const rt = sema.typeOf(rhs);
    const lc = Type.class(ip, lt);
    const rc = Type.class(ip, rt);
    if (lc == .vector or rc == .vector) {
        const ty = try sema.resolvePeerTypes(block, src, &.{ lhs, rhs });
        const len = sema.vectorLen(ty).?;
        const l = try sema.coerce(block, ty, lhs, src);
        const r = try sema.coerce(block, ty, rhs, src);
        return sema.vectorMap(block, src, len, try sema.vectorType(len, .bool_type), &.{ l, r }, VectorCmp{ .op = op });
    }
    const is_eq = op == .eq or op == .neq;

    // Comparison with `null`.
    if (lc == .null or rc == .null) {
        if (!is_eq) return sema.fail(block, src, "operator {s} not allowed for type '{f}'", .{ @tagName(op), sema.fmtType(if (lc == .null) rt else lt) });
        const other = if (lc == .null) rhs else lhs;
        const other_ty = sema.typeOf(other);
        if (Type.class(ip, other_ty) == .null) return .fromInterned(boolValue(op == .eq));
        if (Type.class(ip, other_ty) == .pointer and Type.ptrInfo(ip, other_ty).flags.size == .c)
            return sema.analyzeCmp(block, src, op, other, try sema.coerce(block, other_ty, if (lc == .null) lhs else rhs, src));
        const non_null = try sema.analyzeIsNonNull(block, src, other);
        if (op == .neq) return non_null;
        if (sema.resolveValue(non_null)) |v| return .fromInterned(boolValue(v != .bool_true));
        return sema.addTyOp(block, .not, .bool_type, non_null);
    }
    if (is_eq and (lc == .optional or rc == .optional)) return sema.cmpOptional(block, src, op, lhs, rhs);
    if (is_eq and lt == .void_type and rt == .void_type) return .fromInterned(boolValue(op == .eq));
    if (is_eq and lt == rt and Type.isPacked(ip, lt)) {
        // Packed structs and unions compare as their backing integers.
        try sema.resolveLayout(block, src, lt);
        const backing = ip.structInfo(lt).tag_type;
        if (sema.resolveValue(lhs)) |a| if (sema.resolveValue(rhs)) |b| {
            if (sema.isUndef(a) or sema.isUndef(b)) return .fromInterned(try sema.undefValue(.bool_type));
            var ab = try BigInt.init(sema.arena);
            var bb = try BigInt.init(sema.arena);
            try sema.valueBits(a, &ab, 0);
            try sema.valueBits(b, &bb, 0);
            return .fromInterned(boolValue(ab.eql(bb) == (op == .eq)));
        };
        try sema.requireRuntime(block, src);
        return sema.addBinOp(block, if (op == .eq) .cmp_eq else .cmp_neq, try sema.addTyOp(block, .bitcast, backing, lhs), try sema.addTyOp(block, .bitcast, backing, rhs));
    }
    if (is_eq and ((lc == .error_union and rc == .error_set) or (lc == .error_set and rc == .error_union))) {
        // `eu == error.X`: the error union holds that error.
        const eu = if (lc == .error_union) lhs else rhs;
        const err = if (lc == .error_union) rhs else lhs;
        const non_err = try sema.analyzeIsNonErr(block, src, eu);
        if (sema.resolveValue(non_err)) |v| if (v == .bool_true) return .fromInterned(boolValue(op == .neq));
        // At runtime, the error field of a payload is 0, never a valid
        // error code.
        return sema.analyzeCmp(block, src, op, try sema.errUnionCode(block, src, eu), err);
    }
    if (is_eq and ((lc == .pointer and Type.ptrInfo(ip, lt).flags.size == .c and (rc == .int or rc == .comptime_int)) or
        (rc == .pointer and Type.ptrInfo(ip, rt).flags.size == .c and (lc == .int or lc == .comptime_int))))
    {
        const ptr_ty = if (lc == .pointer) lt else rt;
        return sema.analyzeCmp(block, src, op, try sema.coerce(block, ptr_ty, lhs, src), try sema.coerce(block, ptr_ty, rhs, src));
    }
    if (lt == .type_type and rt == .type_type and is_eq) {
        const a = try sema.resolveConstValue(block, src, lhs, "types must be comptime-known");
        const b = try sema.resolveConstValue(block, src, rhs, "types must be comptime-known");
        return .fromInterned(boolValue((a == b) == (op == .eq)));
    }
    if (lc == .enum_literal and rc == .enum_literal and is_eq) {
        const a = try sema.resolveConstValue(block, src, lhs, "enum literals are comptime-known");
        const b = try sema.resolveConstValue(block, src, rhs, "enum literals are comptime-known");
        return .fromInterned(boolValue((a == b) == (op == .eq)));
    }
    if (is_eq and (lc == .@"enum" or rc == .@"enum" or lc == .@"union" or rc == .@"union") and
        (lc == .@"enum" or lc == .enum_literal or lc == .@"union") and (rc == .@"enum" or rc == .enum_literal or rc == .@"union"))
    {
        // Compare tags: a union compares by its tag.
        const tag_of = struct {
            fn f(s: *Sema, b: *Block, sr: Src, r: Ref) CompileError!Ref {
                const t = s.typeOf(r);
                if (Type.class(s.ip, t) != .@"union") return r;
                try s.resolveLayout(b, sr, t);
                if (s.ip.indexToKey(s.ip.structInfo(t).tag_type) != .enum_type) return s.fail(b, sr, "comparison of union and enum literal is only valid for tagged union types", .{});
                return s.unionTag(b, sr, r);
            }
        }.f;
        const l0 = try tag_of(sema, block, src, lhs);
        const r0 = try tag_of(sema, block, src, rhs);
        const ty = if (Type.class(ip, sema.typeOf(l0)) == .@"enum") sema.typeOf(l0) else sema.typeOf(r0);
        const l = try sema.coerce(block, ty, l0, src);
        const r = try sema.coerce(block, ty, r0, src);
        if (sema.resolveValue(l)) |a| if (sema.resolveValue(r)) |b| {
            if (sema.isUndef(a) or sema.isUndef(b)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
            return .fromInterned(boolValue((a == b) == (op == .eq)));
        };
        try sema.requireRuntime(block, src);
        return sema.addBinOp(block, if (op == .eq) .cmp_eq else .cmp_neq, l, r);
    }
    if (lc == .error_set and rc == .error_set and is_eq) {
        const l = try sema.coerce(block, .anyerror_type, lhs, src);
        const r = try sema.coerce(block, .anyerror_type, rhs, src);
        if (sema.resolveValue(l)) |a| if (sema.resolveValue(r)) |b| return .fromInterned(boolValue((a == b) == (op == .eq)));
        try sema.requireRuntime(block, src);
        return sema.addBinOp(block, if (op == .eq) .cmp_eq else .cmp_neq, l, r);
    }
    if (lc == .bool and rc == .bool and is_eq) {
        if (sema.resolveValue(lhs)) |a| if (sema.resolveValue(rhs)) |b| return .fromInterned(boolValue((a == b) == (op == .eq)));
        try sema.requireRuntime(block, src);
        return sema.addBinOp(block, if (op == .eq) .cmp_eq else .cmp_neq, lhs, rhs);
    }
    if (lc == .pointer and rc == .pointer) {
        if (!is_eq) return sema.failUnsupported(block, src, "ordered pointer comparison");
        if (sema.resolveValue(lhs)) |a| if (sema.resolveValue(rhs)) |b| {
            if (sema.isUndef(a) or sema.isUndef(b)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
            const ka = ip.indexToKey(a);
            const kb = ip.indexToKey(b);
            if (ka == .ptr and kb == .ptr) {
                const a_int = ka.ptr.base == .int;
                const b_int = kb.ptr.base == .int;
                // Addresses from integers compare by value; an address of
                // memory is never 0.
                const known: ?bool = if (a == b)
                    true
                else if (a_int and b_int)
                    ka.ptr.byte_offset == kb.ptr.byte_offset
                else if ((a_int and ka.ptr.byte_offset == 0) or (b_int and kb.ptr.byte_offset == 0))
                    false
                else if (!a_int and !b_int)
                    sema.comptimePtrsEqual(ka.ptr, kb.ptr)
                else
                    null;
                if (known) |eq| return .fromInterned(boolValue(eq == (op == .eq)));
            }
        };
        try sema.requireRuntime(block, src);
        const ty = try sema.resolvePeerTypes(block, src, &.{ lhs, rhs });
        return sema.addBinOp(block, if (op == .eq) .cmp_eq else .cmp_neq, try sema.coerce(block, ty, lhs, src), try sema.coerce(block, ty, rhs, src));
    }
    const l_int = lc == .int or lc == .comptime_int;
    const r_int = rc == .int or rc == .comptime_int;
    const l_float = lc == .float or lc == .comptime_float;
    const r_float = rc == .float or rc == .comptime_float;
    if ((l_float or r_float) and (l_int or l_float) and (r_int or r_float)) return sema.cmpFloat(block, src, op, lhs, rhs);
    if (!l_int or !r_int) return sema.fail(block, src, "operator {s} not allowed for types '{f}' and '{f}'", .{ @tagName(op), sema.fmtType(lt), sema.fmtType(rt) });

    const lv = sema.resolveValue(lhs);
    const rv = sema.resolveValue(rhs);
    if (lv != null and rv != null) {
        if (sema.isUndef(lv.?) or sema.isUndef(rv.?)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
        var sa: [2]std.math.big.Limb = undefined;
        var sb: [2]std.math.big.Limb = undefined;
        const order = ip.intToBig(lv.?, &sa).order(ip.intToBig(rv.?, &sb));
        return .fromInterned(boolValue(order.compare(op)));
    }
    try sema.requireRuntime(block, src);
    // A comptime-known operand outside the other's range decides the result.
    if (lv != null or rv != null) {
        const known = if (lv) |v| v else rv.?;
        const other_ty = if (lv != null) rt else lt;
        if (Type.class(ip, other_ty) == .int and !sema.intFits(known, other_ty)) {
            const known_is_big = sema.intSign(known) > 0;
            // Relation of the runtime operand to the known one.
            const runtime_lt_known = known_is_big;
            const runtime_on_left = lv == null;
            const left_lt_right = if (runtime_on_left) runtime_lt_known else !runtime_lt_known;
            return .fromInterned(boolValue(switch (op) {
                .eq => false,
                .neq => true,
                .lt, .lte => left_lt_right,
                .gt, .gte => !left_lt_right,
            }));
        }
    }
    var ty: Index = undefined;
    if (lc == .comptime_int) ty = rt else if (rc == .comptime_int) ty = lt else {
        const a = Type.intInfo(ip, lt);
        const b = Type.intInfo(ip, rt);
        if (a.signedness == b.signedness) {
            ty = if (a.bits >= b.bits) lt else rt;
        } else {
            const ub = if (a.signedness == .unsigned) a.bits else b.bits;
            const sb = if (a.signedness == .signed) a.bits else b.bits;
            ty = try sema.intType(.signed, @max(ub + 1, sb));
        }
    }
    const l = try sema.coerce(block, ty, lhs, src);
    const r = try sema.coerce(block, ty, rhs, src);
    return sema.addBinOp(block, switch (op) {
        .lt => .cmp_lt,
        .lte => .cmp_lte,
        .eq => .cmp_eq,
        .gte => .cmp_gte,
        .gt => .cmp_gt,
        .neq => .cmp_neq,
    }, l, r);
}

fn zirBoolBr(sema: *Sema, parent: *Block, inst: Zir.Inst.Index, is_or: bool) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.BoolBr, data.payload_index);
    const body = sema.code.bodySlice(extra.end, extra.data.body_len);
    const src = parent.nodeSrc(data.src_node);
    const lhs = try sema.coerce(parent, .bool_type, sema.resolveInst(extra.data.lhs), src);
    if (try sema.resolveDefinedValue(parent, src, lhs)) |v| {
        if ((v == .bool_true) == is_or) return .fromInterned(v);
        const rhs = try sema.resolveInlineBody(parent, body, inst);
        return sema.coerce(parent, .bool_type, rhs, src);
    }
    try sema.requireRuntime(parent, src);
    const block_inst = try sema.reserveInst();
    var rhs_block = parent.child();
    defer rhs_block.instructions.deinit(sema.gpa);
    const rhs = try sema.coerce(&rhs_block, .bool_type, try sema.resolveInlineBody(&rhs_block, body, inst), src);
    _ = try sema.addInst(&rhs_block, .{ .tag = .br, .data = .{ .br = .{ .block_inst = block_inst, .operand = rhs } } });
    var short_block = parent.child();
    defer short_block.instructions.deinit(sema.gpa);
    _ = try sema.addInst(&short_block, .{ .tag = .br, .data = .{ .br = .{ .block_inst = block_inst, .operand = .fromInterned(boolValue(is_or)) } } });
    var inner = parent.child();
    defer inner.instructions.deinit(sema.gpa);
    if (is_or) {
        try sema.addCondBr(&inner, lhs, short_block.instructions.items, rhs_block.instructions.items);
    } else {
        try sema.addCondBr(&inner, lhs, rhs_block.instructions.items, short_block.instructions.items);
    }
    try sema.addBlock(parent, block_inst, .bool_type, inner.instructions.items);
    return block_inst.toRef();
}

// ---------------------------------------------------------------------------
// Memory

fn analyzeAlloc(sema: *Sema, block: *Block, src: Src, ty: Index, is_const: bool, force_comptime: bool) CompileError!Ref {
    if (block.is_comptime or force_comptime) return .fromInterned(try sema.createComptimeAlloc(ty, is_const));
    try sema.resolveLayout(block, src, ty);
    if (Type.isComptimeOnly(sema.ip, ty)) {
        return sema.fail(block, src, "variable of type '{f}' must be const or comptime", .{sema.fmtType(ty)});
    }
    const ptr_ty = try sema.ptrType(.{ .child = ty });
    return sema.addInst(block, .{ .tag = .alloc, .data = .{ .ty = ptr_ty } });
}

fn allocInferred(sema: *Sema, block: *Block, is_const: bool, force_comptime: bool) CompileError!Ref {
    if (block.is_comptime or force_comptime) return .fromInterned(try sema.createComptimeAlloc(.none, is_const));
    const ref = try sema.addInst(block, .{ .tag = .alloc, .data = .{ .ty = .none } });
    try sema.inferred_allocs.put(sema.gpa, ref.toIndex().?, .{ .is_const = is_const });
    return ref;
}

fn zirStoreToInferredPtr(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!void {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Bin, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    const ptr = sema.resolveInst(extra.lhs);
    const operand = sema.resolveInst(extra.rhs);
    if (sema.resolveValue(ptr)) |pv| {
        const id = sema.ip.indexToKey(pv).ptr.base.comptime_alloc;
        const alloc = sema.comptime_allocs.getPtr(id).?;
        const val = try sema.resolveConstValue(block, src, operand, "value stored to a comptime variable must be comptime-known");
        alloc.ty = sema.ip.typeOf(val);
        alloc.val = val;
        return;
    }
    const ia = sema.inferred_allocs.getPtr(ptr.toIndex().?).?;
    const store = try sema.addBinOp(block, .store, ptr, operand);
    try ia.stores.append(sema.gpa, store.toIndex().?);
}

fn zirResolveInferredAlloc(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].un_node;
    const src = block.nodeSrc(data.src_node);
    const ptr = sema.resolveInst(data.operand);
    if (sema.resolveValue(ptr)) |pv| {
        const id = sema.ip.indexToKey(pv).ptr.base.comptime_alloc;
        const alloc = sema.comptime_allocs.getPtr(id).?;
        if (alloc.ty == .none) return sema.fail(block, src, "unable to infer variable type", .{});
        const ptr_ty = try sema.ptrType(.{ .child = alloc.ty, .flags = .{ .is_const = alloc.is_const } });
        return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = ptr_ty, .base = .{ .comptime_alloc = id } } }));
    }
    const alloc_inst = ptr.toIndex().?;
    const ia = sema.inferred_allocs.getPtr(alloc_inst).?;
    const operands = try sema.arena.alloc(Ref, ia.stores.items.len);
    for (ia.stores.items, operands) |store, *op| op.* = sema.ir_insts.items(.data)[@backingInt(store)].bin_op.rhs;
    const ty = try sema.resolvePeerTypes(block, src, operands);
    if (ty == .noreturn_type) return sema.fail(block, src, "unable to infer variable type", .{});
    if (Type.isComptimeOnly(sema.ip, ty)) return sema.fail(block, src, "variable of type '{f}' must be const or comptime", .{sema.fmtType(ty)});
    try sema.resolveLayout(block, src, ty);
    if (ia.alignment != 0 and ia.alignment != Type.abiAlignment(sema.ip, ty)) return sema.failUnsupported(block, src, "local variables aligned differently from their type");
    const ptr_ty = try sema.ptrType(.{ .child = ty });
    sema.ir_insts.items(.data)[@backingInt(alloc_inst)] = .{ .ty = ptr_ty };
    for (ia.stores.items, operands) |store, op| try sema.coerceBrOperand(block, store, ty, op, src);
    if (ia.is_const) {
        const const_ty = try sema.ptrType(.{ .child = ty, .flags = .{ .is_const = true } });
        return sema.addTyOp(block, .bitcast, const_ty, ptr);
    }
    return ptr;
}

fn zirStoreNode(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!void {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Bin, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    try sema.analyzeStore(block, src, sema.resolveInst(extra.lhs), sema.resolveInst(extra.rhs));
}

fn analyzeStore(sema: *Sema, block: *Block, src: Src, ptr: Ref, uncasted: Ref) CompileError!void {
    const ip = sema.ip;
    const ptr_ty = sema.typeOf(ptr);
    if (Type.class(ip, ptr_ty) != .pointer) return sema.fail(block, src, "expected pointer, found '{f}'", .{sema.fmtType(ptr_ty)});
    const info = Type.ptrInfo(ip, ptr_ty);
    if (info.flags.is_const) return sema.fail(block, src, "cannot assign to constant", .{});
    const operand = try sema.coerce(block, info.child, uncasted, src);
    if (sema.resolveValue(ptr)) |pv| {
        if (try sema.comptimePtrRoot(pv) == .comptime_alloc) {
            const val = try sema.resolveConstValue(block, src, operand, "value stored to a comptime variable must be comptime-known");
            return sema.comptimeStore(block, src, pv, val);
        }
    }
    try sema.requireRuntime(block, src);
    try sema.resolveLayout(block, src, info.child);
    if (!Type.hasRuntimeBits(ip, info.child)) return;
    if (info.packed_offset.host_size != 0) {
        // Read, modify, and write the host integer.
        const host_ty = try sema.intType(.unsigned, info.packed_offset.host_size * 8);
        const host_ptr = try sema.addTyOp(block, .bitcast, try sema.ptrType(.{ .child = host_ty, .flags = .{ .is_volatile = info.flags.is_volatile } }), ptr);
        const old = try sema.addTyOp(block, .load, host_ty, host_ptr);
        const new = try sema.packedInsert(block, old, info.packed_offset.bit_offset, operand);
        _ = try sema.addBinOp(block, .store, host_ptr, new);
        return;
    }
    _ = try sema.addBinOp(block, .store, ptr, operand);
}

fn analyzeLoad(sema: *Sema, block: *Block, src: Src, ptr: Ref) CompileError!Ref {
    const ip = sema.ip;
    const ptr_ty = sema.typeOf(ptr);
    if (Type.class(ip, ptr_ty) != .pointer) return sema.fail(block, src, "expected pointer, found '{f}'", .{sema.fmtType(ptr_ty)});
    const info = Type.ptrInfo(ip, ptr_ty);
    if (sema.resolveValue(ptr)) |pv| {
        if (try sema.comptimeLoadOrNull(block, src, pv)) |v| return .fromInterned(v);
    }
    try sema.requireRuntime(block, src);
    try sema.resolveLayout(block, src, info.child);
    if (!Type.hasRuntimeBits(ip, info.child)) {
        if (info.child == .void_type) return .void_value;
        if (Type.isComptimeOnly(ip, info.child)) return sema.fail(block, src, "unable to load comptime-only type '{f}' at runtime", .{sema.fmtType(info.child)});
    }
    if (info.packed_offset.host_size != 0) {
        const host_ty = try sema.intType(.unsigned, info.packed_offset.host_size * 8);
        const host_ptr = try sema.addTyOp(block, .bitcast, try sema.ptrType(.{ .child = host_ty, .flags = .{ .is_const = true, .is_volatile = info.flags.is_volatile } }), ptr);
        return sema.packedExtract(block, try sema.addTyOp(block, .load, host_ty, host_ptr), info.packed_offset.bit_offset, info.child);
    }
    return sema.addTyOp(block, .load, info.child, ptr);
}

// ---------------------------------------------------------------------------
// Packed structs
//
// A packed struct is its backing integer at runtime. Sema lowers field
// reads, field writes through bit pointers, and initialization to integer
// operations on it, so CodeGen never sees a packed field.

/// Runtime value `val` as an unsigned integer of its packed bit width.
fn packedToBits(sema: *Sema, block: *Block, val: Ref) CompileError!Ref {
    const ip = sema.ip;
    const ty = sema.typeOf(val);
    const bits_ty = try sema.intType(.unsigned, Type.packedBits(ip, ty).?);
    if (ty == bits_ty) return val;
    var v = val;
    if (Type.class(ip, ty) == .@"enum") v = try sema.addTyOp(block, .bitcast, ip.structInfo(ty).tag_type, v);
    if (Type.isPacked(ip, ty)) v = try sema.addTyOp(block, .bitcast, ip.structInfo(ty).tag_type, v);
    if (sema.typeOf(v) == bits_ty) return v;
    return sema.addTyOp(block, .bitcast, bits_ty, v);
}

/// The value of type `ty` whose packed bits are unsigned integer `bits`.
fn packedFromBits(sema: *Sema, block: *Block, bits: Ref, ty: Index) CompileError!Ref {
    const ip = sema.ip;
    if (sema.typeOf(bits) == ty) return bits;
    if (Type.class(ip, ty) == .@"enum") {
        const tag_ty = ip.structInfo(ty).tag_type;
        const tag = if (tag_ty == sema.typeOf(bits)) bits else try sema.addTyOp(block, .bitcast, tag_ty, bits);
        return sema.addTyOp(block, .bitcast, ty, tag);
    }
    return sema.addTyOp(block, .bitcast, ty, bits);
}

/// The field of type `ty` at `bit_offset` in runtime integer `host`.
fn packedExtract(sema: *Sema, block: *Block, host: Ref, bit_offset: u16, ty: Index) CompileError!Ref {
    const ip = sema.ip;
    const host_ty = sema.typeOf(host);
    const host_bits = Type.intInfo(ip, host_ty).bits;
    const bits = Type.packedBits(ip, ty).?;
    if (bits == 0) return .fromInterned(try sema.undefValue(ty));
    var v = host;
    if (bit_offset != 0) v = try sema.addBinOp(block, .shr, v, .fromInterned(try sema.intValue(try sema.intType(.unsigned, Type.log2IntBits(host_bits)), bit_offset)));
    if (bits != host_bits) v = try sema.addTyOp(block, .trunc, try sema.intType(.unsigned, bits), v);
    return sema.packedFromBits(block, v, ty);
}

/// Runtime integer `host` with the field at `bit_offset` replaced by `val`.
fn packedInsert(sema: *Sema, block: *Block, host: Ref, bit_offset: u16, val: Ref) CompileError!Ref {
    const ip = sema.ip;
    const host_ty = sema.typeOf(host);
    const host_bits = Type.intInfo(ip, host_ty).bits;
    const bits = Type.packedBits(ip, sema.typeOf(val)).?;
    if (bits == 0) return host;
    // host & ~(mask << bit_offset) | (val << bit_offset)
    var mask = try std.math.big.int.Managed.initSet(sema.arena, 1);
    try mask.shiftLeft(&mask, bits);
    try mask.addScalar(&mask, -1);
    try mask.shiftLeft(&mask, bit_offset);
    var all = try std.math.big.int.Managed.initSet(sema.arena, 1);
    try all.shiftLeft(&all, host_bits);
    try all.addScalar(&all, -1);
    try mask.bitXor(&mask, &all);
    const cleared = try sema.addBinOp(block, .bit_and, host, .fromInterned(try sema.bigToValue(host_ty, mask.toConst())));
    var v = try sema.packedToBits(block, val);
    if (bits != host_bits) v = try sema.addTyOp(block, .intcast, host_ty, v);
    if (bit_offset != 0) v = try sema.addBinOp(block, .shl, v, .fromInterned(try sema.intValue(try sema.intType(.unsigned, Type.log2IntBits(host_bits)), bit_offset)));
    return sema.addBinOp(block, .bit_or, cleared, v);
}

fn analyzeRef(sema: *Sema, block: *Block, src: Src, operand: Ref) CompileError!Ref {
    const ty = sema.typeOf(operand);
    const ptr_ty = try sema.ptrType(.{ .child = ty, .flags = .{ .is_const = true } });
    if (sema.resolveValue(operand)) |v| {
        try sema.resolveLayoutIfIdle(block, src, ty);
        return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = ptr_ty, .base = .{ .uav = .{ .val = v, .orig_ty = ptr_ty } } } }));
    }
    try sema.requireRuntime(block, src);
    try sema.resolveLayout(block, src, ty);
    const alloc = try sema.addInst(block, .{ .tag = .alloc, .data = .{ .ty = ptr_ty } });
    _ = try sema.addBinOp(block, .store, alloc, operand);
    return alloc;
}

fn checkDerefable(sema: *Sema, block: *Block, src: Src, ty: Index) CompileError!void {
    if (Type.class(sema.ip, ty) != .pointer or Type.ptrInfo(sema.ip, ty).flags.size != .one) {
        return sema.fail(block, src, "cannot dereference non-pointer type '{f}'", .{sema.fmtType(ty)});
    }
}

// ---------------------------------------------------------------------------
// Comptime memory
//
// Comptime-mutable memory is a set of allocations, each holding one interned
// value. Pointers into them are interned `ptr` values whose base is
// `comptime_alloc` (possibly through `field`/`elem` derivations). A store
// rebuilds the aggregate along the pointer's path.

fn createComptimeAlloc(sema: *Sema, ty: Index, is_const: bool) !Index {
    const id = sema.ip.next_comptime_alloc.fetchAdd(1, .monotonic);
    try sema.comptime_allocs.put(sema.gpa, id, .{
        .ty = ty,
        .val = if (ty == .none) .none else try sema.undefValue(ty),
        .is_const = is_const,
    });
    const ptr_ty = try sema.ptrType(.{ .child = if (ty == .none) .generic_poison_type else ty });
    return sema.intern(.{ .ptr = .{ .ty = ptr_ty, .base = .{ .comptime_alloc = id } } });
}

const PtrRoot = enum { comptime_alloc, uav, nav, int };

fn comptimePtrRoot(sema: *Sema, ptr: Index) !PtrRoot {
    var p = ptr;
    while (true) {
        switch (sema.ip.indexToKey(p)) {
            .ptr => |k| switch (k.base) {
                .comptime_alloc => return .comptime_alloc,
                .uav => return .uav,
                .nav => return .nav,
                .int => return .int,
                .field => |f| p = f.base,
                .elem => |e| p = e.base,
            },
            else => return .int,
        }
    }
}

/// Whether two comptime-known pointers into memory (not from integers)
/// are equal, or null if zap cannot tell without their layouts.
fn comptimePtrsEqual(sema: *Sema, a: InternPool.Ptr, b: InternPool.Ptr) ?bool {
    if (std.meta.eql(a.base, b.base) and a.byte_offset == b.byte_offset) return true;
    // Pointers into different allocations differ.
    const ra = sema.ptrRootBase(a);
    const rb = sema.ptrRootBase(b);
    if (!std.meta.eql(ra, rb)) return false;
    return null;
}

/// The allocation a comptime pointer points into.
fn ptrRootBase(sema: *Sema, ptr: InternPool.Ptr) InternPool.Ptr.BaseAddr {
    var k = ptr;
    while (true) switch (k.base) {
        .field => |f| k = sema.ip.indexToKey(f.base).ptr,
        .elem => |e| k = sema.ip.indexToKey(e.base).ptr,
        .uav => |u| return .{ .uav = .{ .val = u.val, .orig_ty = .none } },
        else => return k.base,
    };
}

/// Loads through a comptime-known pointer, or returns null if the memory is
/// only known at runtime (a global `var`, an address from an integer).
fn comptimeLoadOrNull(sema: *Sema, block: *Block, src: Src, ptr: Index) CompileError!?Index {
    const ip = sema.ip;
    const key = switch (ip.indexToKey(ptr)) {
        .ptr => |k| k,
        .undef => return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{}),
        else => return null,
    };
    return switch (key.base) {
        .comptime_alloc => |id| blk: {
            const alloc = sema.comptime_allocs.get(id) orelse
                return sema.fail(block, src, "comptime variable is not accessible here", .{});
            break :blk try sema.loadAtOffset(alloc.val, key);
        },
        .uav => |u| try sema.loadAtOffset(u.val, key),
        .nav => |n| blk: {
            try sema.ensureNavVal(block, src, n);
            const nav = ip.getNav(n);
            if (!nav.is_const) break :blk null;
            break :blk try sema.loadAtOffset(nav.val, key);
        },
        .int => null,
        .field => |f| blk: {
            const parent = (try sema.comptimeLoadOrNull(block, src, f.base)) orelse break :blk null;
            if (ip.typeOf(parent) != Type.ptrInfo(ip, ip.typeOf(f.base)).child)
                return sema.failUnsupported(block, src, "reinterpreting memory at comptime");
            break :blk try sema.fieldValue(parent, @intCast(f.index));
        },
        .elem => |e| blk: {
            const parent = (try sema.comptimeLoadOrNull(block, src, e.base)) orelse break :blk null;
            const parent_ty = Type.ptrInfo(ip, ip.typeOf(e.base)).child;
            if (ip.indexToKey(parent_ty) == .vector_type) {
                if (ip.typeOf(parent) != parent_ty or e.index >= ip.indexToKey(parent_ty).vector_type.len)
                    return sema.failUnsupported(block, src, "reinterpreting memory at comptime");
                break :blk try sema.elemValue(parent, e.index);
            }
            if (ip.indexToKey(parent_ty) != .array_type) break :blk null;
            if (ip.indexToKey(ip.typeOf(parent)) != .array_type) {
                // A single item viewed as a one-element array (`*T` to `*[1]T`).
                if (e.index == 0 and ip.typeOf(parent) == ip.indexToKey(parent_ty).array_type.child) break :blk parent;
                return sema.failUnsupported(block, src, "reinterpreting memory at comptime");
            }
            if (ip.typeOf(parent) != parent_ty or e.index >= ip.indexToKey(parent_ty).array_type.lenIncludingSentinel())
                return sema.failUnsupported(block, src, "reinterpreting memory at comptime");
            const elem_ty = ip.indexToKey(parent_ty).array_type.child;
            const load_ty = Type.ptrInfo(ip, key.ty).child;
            if (load_ty != elem_ty and ip.indexToKey(load_ty) == .array_type and ip.indexToKey(load_ty).array_type.child == elem_ty) {
                // A subarray (from slicing with comptime-known bounds).
                const a = ip.indexToKey(load_ty).array_type;
                if (e.index + a.len > ip.indexToKey(parent_ty).array_type.lenIncludingSentinel())
                    return sema.failUnsupported(block, src, "reinterpreting memory at comptime");
                const elems = try sema.arena.alloc(Index, @intCast(a.lenIncludingSentinel()));
                for (elems, 0..) |*x, i| x.* = if (i == a.len) a.sentinel else try sema.elemValue(parent, e.index + i);
                break :blk try sema.intern(.{ .aggregate = .{ .ty = load_ty, .storage = .{ .elems = elems } } });
            }
            break :blk try sema.elemValue(parent, e.index);
        },
    };
}

/// The value pointer `key` loads from root value `val`: `val` itself, or an
/// element of array `val` that a pointer with a byte offset (from a
/// many-pointer or a cast to the element type) addresses. Null if the
/// pointer reinterprets memory in a way zap does not model.
fn loadAtOffset(sema: *Sema, val: Index, key: InternPool.Ptr) !?Index {
    const ip = sema.ip;
    if (val == .none) return val;
    const p = Type.ptrInfo(ip, key.ty);
    const load_ty = p.child;
    const val_ty = ip.typeOf(val);
    if (load_ty == val_ty or load_ty == .generic_poison_type or load_ty == .anyopaque_type) return if (key.byte_offset == 0) val else null;
    if (key.byte_offset == 0 and ip.indexToKey(load_ty) == .array_type) {
        const b = ip.indexToKey(load_ty).array_type;
        // `*T` viewed as `*[1]T`.
        if (b.len == 1 and b.child == val_ty and b.sentinel == .none)
            return try sema.intern(.{ .aggregate = .{ .ty = load_ty, .storage = .{ .elems = &.{val} } } });
        // `*[N:s]T` viewed as `*[N]T`.
        if (ip.indexToKey(val_ty) == .array_type) {
            const a = ip.indexToKey(val_ty).array_type;
            if (a.len == b.len and a.child == b.child and b.sentinel == .none) {
                const elems = try sema.arena.alloc(Index, b.len);
                for (elems, 0..) |*e, i| e.* = try sema.elemValue(val, i);
                return try sema.intern(.{ .aggregate = .{ .ty = load_ty, .storage = .{ .elems = elems } } });
            }
        }
    }
    if (ip.indexToKey(val_ty) != .array_type) return if (key.byte_offset == 0) val else null;
    const a = ip.indexToKey(val_ty).array_type;
    if (load_ty != a.child) return if (key.byte_offset == 0) val else null;
    const size = Type.abiSize(ip, a.child);
    if (size == 0) return try sema.elemValue(val, 0);
    if (key.byte_offset % size != 0 or key.byte_offset / size > a.len) return null;
    return try sema.elemValue(val, key.byte_offset / size);
}

fn comptimeLoad(sema: *Sema, block: *Block, src: Src, ptr: Index) CompileError!Index {
    return (try sema.comptimeLoadOrNull(block, src, ptr)) orelse
        sema.fail(block, src, "unable to evaluate comptime expression: memory is runtime-known", .{});
}

fn comptimeStore(sema: *Sema, block: *Block, src: Src, ptr: Index, val: Index) CompileError!void {
    const key = sema.ip.indexToKey(ptr).ptr;
    switch (key.base) {
        .comptime_alloc => |id| {
            const alloc = sema.comptime_allocs.getPtr(id) orelse
                return sema.fail(block, src, "comptime variable is not accessible here", .{});
            if (key.byte_offset == 0) {
                alloc.val = val;
            } else {
                // An element addressed by offset (through a many-pointer).
                const ip = sema.ip;
                const arr_ty = ip.typeOf(alloc.val);
                if (ip.indexToKey(arr_ty) != .array_type) return sema.fail(block, src, "unable to store to this memory at comptime", .{});
                const a = ip.indexToKey(arr_ty).array_type;
                const size = Type.abiSize(ip, a.child);
                if (size == 0 or key.byte_offset % size != 0) return sema.fail(block, src, "unable to store to this memory at comptime", .{});
                if (key.byte_offset / size >= a.len or ip.typeOf(val) != a.child) return sema.failUnsupported(block, src, "reinterpreting memory at comptime");
                alloc.val = try sema.withElem(alloc.val, key.byte_offset / size, val);
            }
        },
        .field => |f| {
            const parent = try sema.comptimeLoad(block, src, f.base);
            if (sema.ip.typeOf(parent) != Type.ptrInfo(sema.ip, sema.ip.typeOf(f.base)).child)
                return sema.failUnsupported(block, src, "reinterpreting memory at comptime");
            try sema.comptimeStore(block, src, f.base, try sema.withElem(parent, f.index, val));
        },
        .elem => |e| {
            const parent = try sema.comptimeLoad(block, src, e.base);
            const parent_ty = sema.ip.typeOf(parent);
            if (sema.ip.indexToKey(parent_ty) == .vector_type) {
                const v = sema.ip.indexToKey(parent_ty).vector_type;
                if (e.index >= v.len or sema.ip.typeOf(val) != v.child) return sema.failUnsupported(block, src, "reinterpreting memory at comptime");
                return sema.comptimeStore(block, src, e.base, try sema.withElem(parent, e.index, val));
            }
            if (sema.ip.indexToKey(parent_ty) != .array_type) {
                // A single item viewed as a one-element array.
                if (e.index == 0 and parent_ty == sema.ip.typeOf(val)) return sema.comptimeStore(block, src, e.base, val);
                return sema.failUnsupported(block, src, "reinterpreting memory at comptime");
            }
            const a = sema.ip.indexToKey(parent_ty).array_type;
            const val_ty = sema.ip.typeOf(val);
            if (sema.ip.indexToKey(val_ty) == .array_type) {
                // A subarray (from slicing with comptime-known bounds).
                const sub = sema.ip.indexToKey(val_ty).array_type;
                if (sub.child == a.child and e.index + sub.len <= a.len) {
                    const elems = try sema.aggregateElems(parent);
                    for (0..@intCast(sub.len)) |i| elems[@intCast(e.index + i)] = try sema.elemValue(val, i);
                    return sema.comptimeStore(block, src, e.base, try sema.intern(.{ .aggregate = .{ .ty = parent_ty, .storage = .{ .elems = elems } } }));
                }
            }
            if (e.index >= a.lenIncludingSentinel() or val_ty != a.child) return sema.failUnsupported(block, src, "reinterpreting memory at comptime");
            try sema.comptimeStore(block, src, e.base, try sema.withElem(parent, e.index, val));
        },
        else => return sema.fail(block, src, "unable to store to this memory at comptime", .{}),
    }
}

/// The elements of an aggregate value (including an array's sentinel).
fn aggregateElems(sema: *Sema, val: Index) ![]Index {
    const ip = sema.ip;
    const ty = ip.typeOf(val);
    const n: usize = switch (ip.indexToKey(ty)) {
        .array_type => |a| a.lenIncludingSentinel(),
        .vector_type => |v| v.len,
        .struct_type => ip.structInfo(ty).field_types.len,
        .tuple_type => |t| t.types.len,
        else => unreachable,
    };
    const elems = try sema.arena.alloc(Index, n);
    for (elems, 0..) |*e, i| e.* = try sema.elemValue(val, i);
    return elems;
}

/// A copy of aggregate (or optional/error union payload) `val` with element
/// `index` replaced by `elem`.
fn withElem(sema: *Sema, val: Index, index: u64, elem: Index) !Index {
    const ip = sema.ip;
    const ty = ip.typeOf(val);
    switch (ip.indexToKey(ty)) {
        .opt_type => return sema.intern(.{ .opt = .{ .ty = ty, .val = elem } }),
        .error_union_type => return sema.intern(.{ .error_union = .{ .ty = ty, .val = .{ .payload = elem } } }),
        .union_type => return sema.intern(.{ .un = .{ .ty = ty, .tag = try sema.unionFieldTagValue(ty, @intCast(index)), .val = elem } }),
        .ptr_type => {
            // A slice: field 0 is the pointer, field 1 the length.
            const s = ip.indexToKey(val).slice;
            return sema.intern(.{ .slice = .{ .ty = ty, .ptr = if (index == 0) elem else s.ptr, .len = if (index == 1) elem else s.len } });
        },
        else => {},
    }
    const elems = try sema.aggregateElems(val);
    elems[@intCast(index)] = elem;
    return sema.intern(.{ .aggregate = .{ .ty = ty, .storage = .{ .elems = elems } } });
}

/// Element `index` of an array, struct, or tuple value, or field 0 (the
/// payload) of an optional or error union, or a slice's pointer/length.
fn elemValue(sema: *Sema, val: Index, index: u64) Allocator.Error!Index {
    const ip = sema.ip;
    const ty = ip.typeOf(val);
    const elem_ty: Index = switch (ip.indexToKey(ty)) {
        .array_type => |a| if (a.sentinel != .none and index == a.len) return a.sentinel else a.child,
        .vector_type => |v| v.child,
        .struct_type => ip.structInfo(ty).field_types[@intCast(index)],
        .tuple_type => |t| t.types[@intCast(index)],
        .opt_type => |c| c,
        .error_union_type => |e| e.payload_type,
        .union_type => blk: {
            const ft = ip.structInfo(ty).field_types[@intCast(index)];
            if (ip.indexToKey(val) == .un and ip.indexToKey(val).un.tag == try sema.unionFieldTagValue(ty, @intCast(index))) return ip.indexToKey(val).un.val;
            if (ip.indexToKey(val) == .un and Type.isPacked(ip, ty)) {
                // Another field of a packed union: the same bits.
                var bits = try BigInt.init(sema.arena);
                try sema.valueBits(ip.indexToKey(val).un.val, &bits, 0);
                return sema.bitsValue(ft, bits.toConst(), 0);
            }
            break :blk ft;
        },
        .ptr_type => if (index == 0) blk: {
            const p = ip.indexToKey(ty).ptr_type;
            break :blk try sema.ptrType(.{ .child = p.child, .sentinel = p.sentinel, .flags = .{ .size = .many, .is_const = p.flags.is_const, .is_volatile = p.flags.is_volatile } });
        } else .usize_type,
        else => unreachable,
    };
    return switch (ip.indexToKey(val)) {
        .undef => sema.undefValue(elem_ty),
        .aggregate => |a| switch (a.storage) {
            .elems => |elems| elems[@intCast(index)],
            .bytes => |s| sema.intValue(.u8_type, ip.stringSlice(s)[@intCast(index)]),
            .repeated_elem => |e| e,
        },
        .opt => |o| if (o.val == .none) sema.undefValue(elem_ty) else o.val,
        .error_union => |e| switch (e.val) {
            .payload => |p| p,
            .err_name => sema.undefValue(elem_ty),
        },
        .slice => |s| if (index == 0) s.ptr else s.len,
        .un => sema.undefValue(elem_ty),
        else => unreachable,
    };
}

fn fieldValue(sema: *Sema, val: Index, index: u32) !Index {
    return sema.elemValue(val, index);
}

/// A pointer to element `i` of what array pointer or many-pointer value
/// `ptr` points into.
fn ptrElemPtrVal(sema: *Sema, ptr: Index, i: u64) !Index {
    const ip = sema.ip;
    const key = ip.indexToKey(ptr).ptr;
    const p = Type.ptrInfo(ip, key.ty);
    const elem_ty = if (p.flags.size == .one) Type.childType(ip, p.child) else p.child;
    const elem_ptr_ty = try sema.ptrType(.{ .child = elem_ty, .flags = .{ .is_const = p.flags.is_const, .is_volatile = p.flags.is_volatile } });
    if (p.flags.size == .one) {
        return sema.intern(.{ .ptr = .{ .ty = elem_ptr_ty, .base = .{ .elem = .{ .base = ptr, .index = i } } } });
    }
    return switch (key.base) {
        .elem => |e| sema.intern(.{ .ptr = .{ .ty = elem_ptr_ty, .base = .{ .elem = .{ .base = e.base, .index = e.index + i } } } }),
        else => sema.intern(.{ .ptr = .{ .ty = elem_ptr_ty, .base = key.base, .byte_offset = key.byte_offset + i * Type.abiSize(ip, elem_ty) } }),
    };
}

// ---------------------------------------------------------------------------
// Fields, elements, and slices

fn fieldTypeByName(sema: *Sema, block: *Block, src: Src, ty: Index, name: []const u8) CompileError!Index {
    const ip = sema.ip;
    if (ty == .generic_poison_type) return .generic_poison_type;
    if (ty == .clobbers_type) return .bool_type;
    switch (ip.indexToKey(ty)) {
        .struct_type => {
            try sema.resolveStructFields(block, src, ty);
            const info = ip.structInfo(ty);
            const i = info.fieldIndex(ip, name) orelse return sema.fail(block, src, "no field named '{s}' in struct '{f}'", .{ name, sema.fmtType(ty) });
            return info.field_types[i];
        },
        .union_type => return ip.structInfo(ty).field_types[try sema.unionFieldIndex(block, src, ty, name)],
        .tuple_type => |t| {
            if (t.names.len != 0) return t.types[try sema.structFieldIndex(block, src, ty, name)];
            const i = std.fmt.parseInt(u32, name, 10) catch return sema.fail(block, src, "no field named '{s}' in tuple '{f}'", .{ name, sema.fmtType(ty) });
            if (i >= t.types.len) return sema.fail(block, src, "index {d} outside tuple of length {d}", .{ i, t.types.len });
            return t.types[i];
        },
        else => return sema.fail(block, src, "type '{f}' does not support struct initialization syntax", .{sema.fmtType(ty)}),
    }
}

fn unionFieldIndex(sema: *Sema, block: *Block, src: Src, ty: Index, name: []const u8) CompileError!u32 {
    try sema.resolveLayout(block, src, ty);
    return sema.ip.structInfo(ty).fieldIndex(sema.ip, name) orelse
        sema.fail(block, src, "no field named '{s}' in union '{f}'", .{ name, sema.fmtType(ty) });
}

/// The tag of union `ty` when field `i` is active: an `enum_tag`, or the
/// field index as a `u32` for untagged unions.
fn unionFieldTagValue(sema: *Sema, ty: Index, i: u32) !Index {
    const ip = sema.ip;
    const tag_ty = ip.structInfo(ty).tag_type;
    if (tag_ty == .none or ip.indexToKey(tag_ty) != .enum_type) return sema.intValue(.u32_type, i);
    const tag_info = ip.structInfo(tag_ty);
    return sema.enumTagValue(tag_ty, tag_info.fieldIndex(ip, ip.stringSlice(ip.structInfo(ty).field_names[i])).?);
}

/// The runtime tag value of union `ty` with field `i` active, of the type
/// that `get_union_tag` and `set_union_tag` use.
fn unionRuntimeTag(sema: *Sema, ty: Index, i: u32) !Index {
    const ip = sema.ip;
    const tag_ty = ip.structInfo(ty).tag_type;
    if (ip.indexToKey(tag_ty) == .enum_type) return sema.unionFieldTagValue(ty, i);
    return sema.intValue(tag_ty, i);
}

/// A union value with field `i` holding `init`.
fn unionInit(sema: *Sema, block: *Block, src: Src, ty: Index, i: u32, init: Ref) CompileError!Ref {
    if (sema.resolveValue(init)) |v| return .fromInterned(try sema.intern(.{ .un = .{ .ty = ty, .tag = try sema.unionFieldTagValue(ty, i), .val = v } }));
    try sema.requireRuntime(block, src);
    if (Type.isPacked(sema.ip, ty)) return sema.addTyOp(block, .bitcast, ty, try sema.packedToBits(block, init));
    return sema.addStructField(block, .union_init, ty, init, i);
}

/// `&u.field` where `ptr` points to a union. `initializing` makes the field
/// active; otherwise Debug checks that it is.
fn unionFieldPtr(sema: *Sema, block: *Block, src: Src, ptr: Ref, i: u32, initializing: bool) CompileError!Ref {
    const ip = sema.ip;
    const union_ty = Type.ptrInfo(ip, sema.typeOf(ptr)).child;
    const info = ip.structInfo(union_ty);
    const field_ty = info.field_types[i];
    if (sema.resolveValue(ptr)) |pv| if (try sema.comptimePtrRoot(pv) != .int) {
        if (!initializing and info.layout != .@"packed") if (try sema.comptimeLoadOrNull(block, src, pv)) |uv| if (ip.indexToKey(uv) == .un) {
            const active = ip.indexToKey(uv).un.tag;
            if (active != try sema.unionFieldTagValue(union_ty, i)) {
                const active_i = for (0..info.field_names.len) |k| {
                    if (try sema.unionFieldTagValue(union_ty, @intCast(k)) == active) break k;
                } else 0;
                return sema.fail(block, src, "access of union field '{s}' while field '{s}' is active", .{ ip.stringSlice(info.field_names[i]), ip.stringSlice(info.field_names[active_i]) });
            }
        };
        return sema.fieldPtrAt(block, src, ptr, field_ty, i);
    };
    try sema.requireRuntime(block, src);
    if (info.has_runtime_tag) {
        const tag: Ref = .fromInterned(try sema.unionRuntimeTag(union_ty, i));
        if (initializing) {
            _ = try sema.addBinOp(block, .set_union_tag, ptr, tag);
        } else if (block.want_safety) {
            const loaded = try sema.analyzeLoad(block, src, ptr);
            const active = try sema.addTyOp(block, .get_union_tag, info.tag_type, loaded);
            const ok = try sema.addBinOp(block, .cmp_eq, active, tag);
            try sema.addSafetyCheck(block, ok, .inactive_union_field, .none, .none);
        }
    }
    return sema.fieldPtrAt(block, src, ptr, field_ty, i);
}

fn structFieldIndex(sema: *Sema, block: *Block, src: Src, ty: Index, name: []const u8) CompileError!u32 {
    const ip = sema.ip;
    switch (ip.indexToKey(ty)) {
        .struct_type => {
            try sema.resolveStructFields(block, src, ty);
            return ip.structInfo(ty).fieldIndex(ip, name) orelse
                sema.fail(block, src, "no field named '{s}' in struct '{f}'", .{ name, sema.fmtType(ty) });
        },
        .tuple_type => |t| {
            if (t.names.len != 0) {
                for (t.names, 0..) |n, i| if (std.mem.eql(u8, ip.stringSlice(n), name)) return @intCast(i);
                return sema.fail(block, src, "no field named '{s}' in struct '{f}'", .{ name, sema.fmtType(ty) });
            }
            const i = std.fmt.parseInt(u32, name, 10) catch return sema.fail(block, src, "no field named '{s}' in tuple '{f}'", .{ name, sema.fmtType(ty) });
            if (i >= t.types.len) return sema.fail(block, src, "index '{d}' out of bounds of tuple '{f}'", .{ i, sema.fmtType(ty) });
            return i;
        },
        else => unreachable,
    }
}

/// `lhs.name` where `lhs` is a value, a pointer to the object, or a type.
fn fieldVal(sema: *Sema, block: *Block, src: Src, lhs: Ref, name: []const u8) CompileError!Ref {
    const ip = sema.ip;
    const ty = sema.typeOf(lhs);
    switch (Type.class(ip, ty)) {
        .type => {
            const container = try sema.resolveConstValue(block, src, lhs, "types must be comptime-known");
            return sema.namespaceLookupVal(block, src, container, name);
        },
        .pointer => {
            const p = Type.ptrInfo(ip, ty);
            if (p.flags.size == .slice) {
                if (std.mem.eql(u8, name, "len")) return sema.sliceLen(block, lhs);
                if (std.mem.eql(u8, name, "ptr")) return sema.slicePtr(block, lhs);
                return sema.fail(block, src, "no member named '{s}' in '{f}'", .{ name, sema.fmtType(ty) });
            }
            if (p.flags.size != .one) return sema.fail(block, src, "type '{f}' does not support field access", .{sema.fmtType(ty)});
            switch (Type.class(ip, p.child)) {
                .array => {
                    const a = ip.indexToKey(p.child).array_type;
                    if (std.mem.eql(u8, name, "len")) return .fromInterned(try sema.intValue(.usize_type, a.len));
                    // `*[N:s]T` to `[*:s]T`.
                    if (std.mem.eql(u8, name, "ptr")) return sema.coercePtrTo(block, lhs, try sema.ptrType(.{ .child = a.child, .sentinel = a.sentinel, .flags = .{
                        .size = .many,
                        .is_const = p.flags.is_const,
                        .is_volatile = p.flags.is_volatile,
                        .alignment = p.flags.alignment,
                    } }));
                },
                .tuple => if (std.mem.eql(u8, name, "len")) return .fromInterned(try sema.intValue(.comptime_int_type, ip.indexToKey(p.child).tuple_type.types.len)) else return sema.analyzeLoad(block, src, try sema.fieldPtr(block, src, lhs, name)),
                .@"struct", .@"union" => return sema.analyzeLoad(block, src, try sema.fieldPtr(block, src, lhs, name)),
                .pointer, .type => return sema.fieldVal(block, src, try sema.analyzeLoad(block, src, lhs), name),
                else => {},
            }
            return sema.fail(block, src, "no member named '{s}' in '{f}'", .{ name, sema.fmtType(p.child) });
        },
        .@"struct", .tuple => {
            if (ip.indexToKey(ty) == .tuple_type and ip.indexToKey(ty).tuple_type.names.len == 0 and std.mem.eql(u8, name, "len"))
                return .fromInterned(try sema.intValue(.comptime_int_type, ip.indexToKey(ty).tuple_type.types.len));
            const i = try sema.structFieldIndex(block, src, ty, name);
            if (ip.indexToKey(ty) == .tuple_type) return sema.tupleField(block, lhs, i);
            if (sema.resolveValue(lhs)) |v| return .fromInterned(try sema.fieldValue(v, i));
            try sema.requireRuntime(block, src);
            if (Type.isPackedStruct(ip, ty)) {
                try sema.resolveLayout(block, src, ty);
                const backing = ip.structInfo(ty).tag_type;
                return sema.packedExtract(block, try sema.addTyOp(block, .bitcast, backing, lhs), Type.packedFieldBitOffset(ip, ty, i), Type.fieldType(ip, ty, i));
            }
            return sema.addStructField(block, .struct_field_val, Type.fieldType(ip, ty, i), lhs, i);
        },
        .array => if (std.mem.eql(u8, name, "len")) return .fromInterned(try sema.intValue(.usize_type, ip.indexToKey(ty).array_type.len)),
        .@"union" => {
            const i = try sema.unionFieldIndex(block, src, ty, name);
            if (sema.resolveValue(lhs)) |v| {
                const field_ty = ip.structInfo(ty).field_types[i];
                if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(field_ty));
                if (Type.isPacked(ip, ty)) return .fromInterned(try sema.fieldValue(v, i));
                const u = ip.indexToKey(v).un;
                if (u.tag != try sema.unionFieldTagValue(ty, i)) return sema.fail(block, src, "access of inactive union field '{s}'", .{name});
                return .fromInterned(u.val);
            }
            if (Type.isPacked(ip, ty)) {
                // Any field: the backing integer's bits.
                try sema.requireRuntime(block, src);
                const field_ty = ip.structInfo(ty).field_types[i];
                return sema.packedFromBits(block, try sema.packedToBits(block, lhs), field_ty);
            }
            return sema.analyzeLoad(block, src, try sema.fieldPtr(block, src, try sema.analyzeRef(block, src, lhs), name));
        },
        else => {},
    }
    return sema.fail(block, src, "type '{f}' does not support field access", .{sema.fmtType(ty)});
}

fn namespaceLookupVal(sema: *Sema, block: *Block, src: Src, container: Index, name: []const u8) CompileError!Ref {
    const ip = sema.ip;
    if (Type.class(ip, container) == .error_set) {
        const n = try sema.getString(name);
        if (try sema.errorSetNames(block, src, container)) |names| {
            for (names) |x| if (x == n) return .fromInterned(try sema.intern(.{ .err = .{ .ty = container, .name = n } }));
            return sema.fail(block, src, "no error named '{s}' in '{f}'", .{ name, sema.fmtType(container) });
        }
    }
    const nav = (try sema.lookupInType(container, name)) orelse {
        // `E.field` names an enum tag; `U.field` the tag of a tagged union.
        const tag_ty: Index = switch (ip.indexToKey(container)) {
            .enum_type => container,
            .union_type => blk: {
                try sema.resolveLayout(block, src, container);
                const t = ip.structInfo(container).tag_type;
                break :blk if (t != .none and ip.indexToKey(t) == .enum_type) t else .none;
            },
            else => .none,
        };
        if (tag_ty != .none) {
            if (try sema.enumFieldIndex(block, src, tag_ty, name)) |i| return .fromInterned(try sema.enumTagValue(tag_ty, i));
        }
        return sema.fail(block, src, "'{f}' has no member named '{s}'", .{ sema.fmtType(container), name });
    };
    const n = ip.getNav(nav);
    if (!n.is_pub and n.file != sema.file) return sema.fail(block, src, "'{s}' is not marked 'pub'", .{name});
    return sema.navVal(block, src, nav);
}

/// `&lhs.name` where `ptr` points to the object.
fn fieldPtr(sema: *Sema, block: *Block, src: Src, ptr: Ref, name: []const u8) CompileError!Ref {
    const ip = sema.ip;
    const ptr_ty = sema.typeOf(ptr);
    if (Type.class(ip, ptr_ty) != .pointer) {
        if (ptr_ty == .type_type) {
            const container = try sema.resolveConstValue(block, src, ptr, "types must be comptime-known");
            const nav = (try sema.lookupInType(container, name)) orelse
                return sema.fail(block, src, "'{f}' has no member named '{s}'", .{ sema.fmtType(container), name });
            return sema.navRef(block, src, nav);
        }
        return sema.fail(block, src, "expected pointer, found '{f}'", .{sema.fmtType(ptr_ty)});
    }
    const p = Type.ptrInfo(ip, ptr_ty);
    const child = p.child;
    switch (Type.class(ip, child)) {
        .pointer => if (Type.ptrInfo(ip, child).flags.size == .one) {
            return sema.fieldPtr(block, src, try sema.analyzeLoad(block, src, ptr), name);
        } else if (Type.isSlice(ip, child)) {
            const i: u32 = if (std.mem.eql(u8, name, "ptr")) 0 else if (std.mem.eql(u8, name, "len")) 1 else return sema.fail(block, src, "no member named '{s}' in '{f}'", .{ name, sema.fmtType(child) });
            const field_ty = if (i == 0) try sema.elemValueType(child) else .usize_type;
            return sema.fieldPtrAt(block, src, ptr, field_ty, i);
        },
        .type => return sema.fieldPtr(block, src, try sema.analyzeLoad(block, src, ptr), name),
        .@"struct", .tuple => {
            const i = try sema.structFieldIndex(block, src, child, name);
            if (ip.indexToKey(child) == .tuple_type and ip.indexToKey(child).tuple_type.values[i] != .none) {
                return sema.analyzeRef(block, src, .fromInterned(ip.indexToKey(child).tuple_type.values[i]));
            }
            return sema.fieldPtrAt(block, src, ptr, Type.fieldType(ip, child, i), i);
        },
        .array => if (std.mem.eql(u8, name, "len")) {
            return sema.analyzeRef(block, src, .fromInterned(try sema.intValue(.usize_type, ip.indexToKey(child).array_type.len)));
        },
        .@"union" => return sema.unionFieldPtr(block, src, ptr, try sema.unionFieldIndex(block, src, child, name), false),
        else => {},
    }
    return sema.fail(block, src, "type '{f}' does not support field access", .{sema.fmtType(child)});
}

/// The many-pointer type of a slice's `ptr` field.
/// The element type of a pointer that `@memcpy` and `@memset` accept,
/// and its length (comptime-known for `*[N]T`), or `.none` for a
/// many-pointer.
fn memOperand(sema: *Sema, block: *Block, src: Src, ptr: Ref) CompileError!struct { elem: Index, len: Ref } {
    const ip = sema.ip;
    const ty = sema.typeOf(ptr);
    if (Type.class(ip, ty) != .pointer) return sema.fail(block, src, "expected pointer, found '{f}'", .{sema.fmtType(ty)});
    const p = Type.ptrInfo(ip, ty);
    return switch (p.flags.size) {
        .slice => .{ .elem = p.child, .len = try sema.sliceLen(block, ptr) },
        .many, .c => .{ .elem = p.child, .len = .none },
        .one => switch (ip.indexToKey(p.child)) {
            .array_type => |a| .{ .elem = a.child, .len = .fromInterned(try sema.intValue(.usize_type, a.len)) },
            else => sema.fail(block, src, "type '{f}' is not an indexable pointer", .{sema.fmtType(ty)}),
        },
    };
}

/// The many-pointer or array pointer inside a `@memcpy` operand.
fn memRawPtr(sema: *Sema, block: *Block, ptr: Ref) CompileError!Ref {
    if (Type.ptrInfo(sema.ip, sema.typeOf(ptr)).flags.size == .slice) return sema.slicePtr(block, ptr);
    return ptr;
}

/// The elements of comptime-known slice `slice`.
fn constSliceElems(sema: *Sema, block: *Block, src: Src, slice: Ref, reason: []const u8) CompileError![]Index {
    const ip = sema.ip;
    const v = try sema.resolveConstValue(block, src, slice, reason);
    if (sema.isUndef(v)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
    const s = ip.indexToKey(v).slice;
    const elems = try sema.arena.alloc(Index, @intCast(ip.intValue(u64, s.len).?));
    for (elems, 0..) |*e, i| e.* = try sema.comptimeLoad(block, src, try sema.ptrElemPtrVal(s.ptr, i));
    return elems;
}

/// Field `name` of comptime-known struct value `val`.
fn structFieldValue(sema: *Sema, val: Index, name: []const u8) !Index {
    const ip = sema.ip;
    return sema.fieldValue(val, ip.structInfo(ip.typeOf(val)).fieldIndex(ip, name).?);
}

/// `@Pointer(size, attrs, child, sentinel)`.
/// `@Struct`, `@Union`, and `@Enum`. The type's identity is the
/// instruction and its canonicalized arguments (its captures); its fields
/// are known at once, and a struct's or union's layout is resolved lazily
/// like a declared type's (see `reifyNode`).
fn zirReifyContainer(sema: *Sema, block: *Block, inst: Zir.Inst.Index, ext: Zir.Inst.Extended.InstData, kind: Zcu.ContainerKind) CompileError!Ref {
    const ip = sema.ip;
    const node: Ast.Node.Index, const args: [4]Zir.Inst.Ref, const names_ref: Zir.Inst.Ref = switch (kind) {
        .@"struct" => blk: {
            const e = sema.code.extraData(Zir.Inst.ReifyStruct, ext.operand).data;
            break :blk .{ e.node, .{ e.layout, e.backing_ty, e.field_types, e.field_attrs }, e.field_names };
        },
        .@"union" => blk: {
            const e = sema.code.extraData(Zir.Inst.ReifyUnion, ext.operand).data;
            break :blk .{ e.node, .{ e.layout, e.arg_ty, e.field_types, e.field_attrs }, e.field_names };
        },
        .@"enum" => blk: {
            const e = sema.code.extraData(Zir.Inst.ReifyEnum, ext.operand).data;
            break :blk .{ e.node, .{ e.tag_ty, e.mode, e.field_values, .none }, e.field_names };
        },
        .@"opaque" => unreachable,
    };
    const src: Src = .{ .base = node, .loc = .{ .node_abs = node } };
    const reason = "reified type arguments must be comptime-known";
    const name_vals = try sema.constSliceElems(block, src, try sema.coerce(block, .slice_const_slice_const_u8_type, sema.resolveInst(names_ref), src), reason);
    const n = name_vals.len;
    const names = try ip.arena(Zcu.tid).alloc(InternPool.String, n);
    for (name_vals, names, 0..) |v, *name, i| {
        name.* = try sema.getString(try sema.resolveConstString(block, src, .fromInterned(v)));
        for (names[0..i]) |prev| if (prev == name.*) return sema.fail(block, src, "duplicate {t} field name '{s}'", .{ kind, ip.stringSlice(prev) });
    }

    if (kind == .@"enum") {
        const tag_ty = try sema.resolveType(block, src, args[0]);
        if (Type.class(ip, tag_ty) != .int) return sema.fail(block, src, "tag type must be an integer type", .{});
        const mode_ty = try sema.stdLangType(block, src, "Type.Enum.Mode");
        const mode = try sema.resolveConstValue(block, src, try sema.coerce(block, mode_ty, sema.resolveInst(args[1]), src), reason);
        const value_slice_ty = try sema.ptrType(.{ .child = tag_ty, .flags = .{ .size = .slice, .is_const = true } });
        const values = try sema.constSliceElems(block, src, try sema.coerce(block, value_slice_ty, sema.resolveInst(args[2]), src), reason);
        if (values.len != n) return sema.fail(block, src, "{d} enum field names but {d} values", .{ n, values.len });
        for (values, 0..) |v, i| {
            if (sema.isUndef(v)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
            for (values[0..i]) |prev| if (prev == v) return sema.fail(block, src, "enum tag value {f} already taken", .{sema.fmtValue(v)});
        }
        const captures = [_]Index{ tag_ty, mode, try sema.namesValue(names), try sema.intern(.{ .aggregate = .{ .ty = try sema.intern(.{ .array_type = .{ .len = n, .child = tag_ty } }), .storage = .{ .elems = values } } }) };
        const name = try sema.typeName(block, @fromBackingInt(@intCast(ext.small)), inst, kind);
        const ty = try sema.zcu.createContainerType(kind, sema.file, inst, &captures, name.display, name.key, block.namespace, .auto);
        const info = ip.structInfo(ty);
        if (info.status == .none) {
            info.field_names = names;
            info.field_defaults = try ip.arena(Zcu.tid).dupe(Index, values);
            info.tag_type = tag_ty;
            info.nonexhaustive = std.mem.eql(u8, sema.enumTagName(mode).?, "nonexhaustive");
            info.size = Type.abiSize(ip, tag_ty);
            info.alignment = Type.abiAlignment(ip, tag_ty);
            info.status = .have_layout;
        }
        return .fromInterned(ty);
    }

    const layout_ty = try sema.stdLangType(block, src, "Type.ContainerLayout");
    const layout_val = try sema.resolveConstValue(block, src, try sema.coerce(block, layout_ty, sema.resolveInst(args[0]), src), reason);
    if (sema.isUndef(layout_val)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
    const layout = std.meta.stringToEnum(std.lang.Type.ContainerLayout, sema.enumTagName(layout_val).?).?;
    const arg_ty = try sema.resolveConstValue(block, src, try sema.coerce(block, try sema.optType(.type_type), sema.resolveInst(args[1]), src), reason);
    const types = try sema.constSliceElems(block, src, try sema.coerce(block, .slice_const_type_type, sema.resolveInst(args[2]), src), reason);
    if (types.len != n) return sema.fail(block, src, "{d} field names but {d} field types", .{ n, types.len });
    const attrs_ty = try sema.stdLangType(block, src, if (kind == .@"struct") "Type.Struct.FieldAttributes" else "Type.Union.FieldAttributes");
    const attrs = try sema.constSliceElems(block, src, try sema.coerce(block, try sema.ptrType(.{ .child = attrs_ty, .flags = .{ .size = .slice, .is_const = true } }), sema.resolveInst(args[3]), src), reason);
    if (attrs.len != n) return sema.fail(block, src, "{d} field names but {d} field attributes", .{ n, attrs.len });
    const defaults = try ip.arena(Zcu.tid).alloc(Index, n);
    for (attrs, types, defaults) |a, ft, *d| {
        if (sema.isUndef(a) or sema.isUndef(ft)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
        if (ip.indexToKey(try sema.structFieldValue(a, "align")).opt.val != .none) return sema.failUnsupported(block, src, "field alignment");
        d.* = .none;
        if (kind != .@"struct") continue;
        if (try sema.structFieldValue(a, "comptime") == .bool_true) return sema.failUnsupported(block, src, "comptime fields");
        const dp = ip.indexToKey(try sema.structFieldValue(a, "default_value_ptr")).opt.val;
        if (dp != .none) {
            // The default value is behind a type-erased pointer.
            var p = ip.indexToKey(dp).ptr;
            p.ty = try sema.ptrType(.{ .child = ft, .flags = .{ .is_const = true } });
            d.* = (try sema.comptimeLoadOrNull(block, src, try sema.intern(.{ .ptr = p }))) orelse
                return sema.fail(block, src, "unable to resolve comptime value: default value must be comptime-known", .{});
        }
    }
    // The captures are the canonical arguments: no pointers into comptime
    // memory, which is neither stable nor immutable.
    var captures: std.ArrayList(Index) = .empty;
    try captures.appendSlice(sema.arena, &.{ layout_val, arg_ty, try sema.namesValue(names), try sema.intern(.{ .aggregate = .{ .ty = try sema.intern(.{ .array_type = .{ .len = n, .child = .type_type } }), .storage = .{ .elems = types } } }) });
    try captures.appendSlice(sema.arena, defaults);
    const name = try sema.typeName(block, @fromBackingInt(@intCast(ext.small)), inst, kind);
    const ty = try sema.zcu.createContainerType(kind, sema.file, inst, captures.items, name.display, name.key, block.namespace, layout);
    const info = ip.structInfo(ty);
    if (info.status == .none) {
        info.field_names = names;
        info.field_types = try ip.arena(Zcu.tid).dupe(Index, types);
        info.field_defaults = defaults;
        info.status = .have_field_types;
    }
    return .fromInterned(ty);
}

fn zirReifyPointer(sema: *Sema, block: *Block, ext: Zir.Inst.Extended.InstData) CompileError!Ref {
    const ip = sema.ip;
    const extra = sema.code.extraData(Zir.Inst.ReifyPointer, ext.operand).data;
    const src = block.nodeSrc(extra.node);
    const size_ty = try sema.stdLangType(block, src, "Type.Pointer.Size");
    const attrs_ty = try sema.stdLangType(block, src, "Type.Pointer.Attributes");
    const size_val = try sema.resolveConstValue(block, src, try sema.coerce(block, size_ty, sema.resolveInst(extra.size), src), "pointer size must be comptime-known");
    const attrs = try sema.resolveConstValue(block, src, try sema.coerce(block, attrs_ty, sema.resolveInst(extra.attrs), src), "pointer attributes must be comptime-known");
    if (sema.isUndef(size_val) or sema.isUndef(attrs)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
    const size_name = ip.stringSlice(ip.structInfo(size_ty).field_names[sema.enumTagIndex(size_val).?]);
    const size = std.meta.stringToEnum(InternPool.PtrType.Size, size_name).?;
    const elem_ty = try sema.resolveType(block, src, extra.elem_ty);
    switch (Type.class(ip, elem_ty)) {
        .noreturn => return sema.fail(block, src, "pointer to noreturn not allowed", .{}),
        .null => return sema.fail(block, src, "cannot reify pointer to '@TypeOf(null)'", .{}),
        .@"fn" => if (size != .one) return sema.fail(block, src, "function pointers must be single pointers", .{}),
        .@"opaque" => if (size != .one) return sema.fail(block, src, "indexable pointer to opaque type '{f}' not allowed", .{sema.fmtType(elem_ty)}),
        else => {},
    }
    var alignment: u6 = 0;
    const align_val = try sema.structFieldValue(attrs, "align");
    if (ip.indexToKey(align_val).opt.val != .none) {
        const a = ip.intValue(u64, ip.indexToKey(align_val).opt.val).?;
        if (a == 0 or !std.math.isPowerOfTwo(a)) return sema.fail(block, src, "alignment value '{d}' is not a power of two", .{a});
        if (sema.naturalAlignment(elem_ty) != a) alignment = @intCast(std.math.log2_int(u64, a) + 1);
    }
    const addr_space = ip.indexToKey(try sema.structFieldValue(attrs, "addrspace")).opt.val;
    if (addr_space != .none) {
        const as_ty = ip.typeOf(addr_space);
        if (!std.mem.eql(u8, ip.stringSlice(ip.structInfo(as_ty).field_names[sema.enumTagIndex(addr_space).?]), "generic"))
            return sema.failUnsupported(block, src, "address spaces");
    }
    const sentinel_opt = try sema.resolveConstValue(block, src, try sema.coerce(block, try sema.optType(elem_ty), sema.resolveInst(extra.sentinel), src), "pointer sentinel must be comptime-known");
    if (sema.isUndef(sentinel_opt)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
    const sentinel = ip.indexToKey(sentinel_opt).opt.val;
    if (sentinel != .none and (size == .one or size == .c)) return sema.fail(block, src, "sentinels are only allowed on slices and unknown-length pointers", .{});
    return .fromInterned(try sema.ptrType(.{
        .child = elem_ty,
        .sentinel = sentinel,
        .flags = .{
            .size = size,
            .is_const = try sema.structFieldValue(attrs, "const") == .bool_true,
            .is_volatile = try sema.structFieldValue(attrs, "volatile") == .bool_true,
            .is_allowzero = try sema.structFieldValue(attrs, "allowzero") == .bool_true,
            .alignment = alignment,
        },
    }));
}

fn zirMemcpy(sema: *Sema, block: *Block, inst: Zir.Inst.Index, tag: Ir.Inst.Tag) CompileError!Ref {
    const ip = sema.ip;
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Bin, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    var dest = sema.resolveInst(extra.lhs);
    var source = sema.resolveInst(extra.rhs);
    const d = try sema.memOperand(block, src, dest);
    const s = try sema.memOperand(block, src, source);
    if (Type.ptrInfo(ip, sema.typeOf(dest)).flags.is_const) return sema.fail(block, src, "cannot copy to constant pointer", .{});
    if (d.len == .none and s.len == .none) return sema.fail(block, src, "unknown copy length", .{});
    if (d.elem != s.elem) return sema.fail(block, src, "pointer element type '{f}' cannot coerce into element type '{f}'", .{ sema.fmtType(s.elem), sema.fmtType(d.elem) });
    try sema.resolveLayout(block, src, d.elem);

    var len = if (d.len != .none) d.len else s.len;
    if (d.len != .none and s.len != .none) {
        if (sema.resolveValue(d.len)) |dl| if (sema.resolveValue(s.len)) |sl| {
            if (dl != sl) return sema.fail(block, src, "non-matching copy lengths", .{});
        };
        if (sema.resolveValue(d.len) == null) {
            if (sema.resolveValue(s.len) != null) len = s.len;
            if (block.want_safety and !block.is_comptime) {
                const ok = try sema.addBinOp(block, .cmp_eq, d.len, s.len);
                try sema.addSafetyCheck(block, ok, .copy_len_mismatch, .none, .none);
            }
        }
    }
    if (!Type.hasRuntimeBits(ip, d.elem) and !Type.isComptimeOnly(ip, d.elem)) return .void_value;
    const len_val = sema.resolveValue(len);
    if (len_val != null and ip.intValue(u64, len_val.?).? == 0) return .void_value;

    // Comptime: copy element by element (all loads first, for `@memmove`).
    if (sema.resolveValue(dest)) |dv| if (sema.resolveValue(source)) |sv| if (len_val) |lv| {
        const n = ip.intValue(u64, lv).?;
        const raw_dest = (try sema.memRawPtr(block, .fromInterned(dv))).toInterned().?;
        if (!sema.isUndef(raw_dest) and try sema.comptimePtrRoot(raw_dest) == .comptime_alloc) {
            const raw_src = (try sema.memRawPtr(block, .fromInterned(sv))).toInterned().?;
            if (sema.isUndef(raw_src)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
            const elems = try sema.arena.alloc(Index, @intCast(n));
            for (elems, 0..) |*e, i| e.* = try sema.comptimeLoad(block, src, try sema.ptrElemPtrVal(raw_src, i));
            for (elems, 0..) |e, i| try sema.comptimeStore(block, src, try sema.ptrElemPtrVal(raw_dest, i), e);
            return .void_value;
        }
    };
    try sema.requireRuntime(block, src);
    if (Type.isComptimeOnly(ip, d.elem)) return sema.fail(block, src, "cannot copy comptime-only type '{f}' at runtime", .{sema.fmtType(d.elem)});

    // The IR form: `dest` gives the length, `source` is a pointer.
    if (d.len == .none) {
        const dp = Type.ptrInfo(ip, sema.typeOf(dest));
        const slice_ty = try sema.ptrType(.{ .child = d.elem, .flags = .{ .size = .slice, .is_const = dp.flags.is_const, .is_volatile = dp.flags.is_volatile } });
        dest = try sema.makeSlice(block, slice_ty, try sema.coercePtrTo(block, dest, try sema.ptrType(.{ .child = d.elem, .flags = .{ .size = .many, .is_volatile = dp.flags.is_volatile } })), len);
    }
    source = try sema.memRawPtr(block, source);

    if (tag == .memcpy and block.want_safety) {
        // The regions must not overlap: dest + bytes <= src or src + bytes <= dest.
        const elem_size: Ref = .fromInterned(try sema.intValue(.usize_type, Type.abiSize(ip, d.elem)));
        const bytes = try sema.addBinOp(block, .mul_wrap, len, elem_size);
        const da = try sema.addUnOp(block, .int_from_ptr, try sema.memRawPtr(block, dest));
        const sa = try sema.addUnOp(block, .int_from_ptr, source);
        const ok1 = try sema.addBinOp(block, .cmp_gte, sa, try sema.addBinOp(block, .add_wrap, da, bytes));
        const ok2 = try sema.addBinOp(block, .cmp_gte, da, try sema.addBinOp(block, .add_wrap, sa, bytes));
        try sema.addSafetyCheck(block, try sema.addBinOp(block, .bit_or, ok1, ok2), .memcpy_alias, .none, .none);
    }
    _ = try sema.addBinOp(block, tag, dest, source);
    return .void_value;
}

fn zirMemset(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ip = sema.ip;
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Bin, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    const dest = sema.resolveInst(extra.lhs);
    const d = try sema.memOperand(block, src, dest);
    if (Type.ptrInfo(ip, sema.typeOf(dest)).flags.is_const) return sema.fail(block, src, "cannot memset constant pointer", .{});
    if (d.len == .none) return sema.fail(block, src, "unknown @memset length", .{});
    try sema.resolveLayout(block, src, d.elem);
    const elem = try sema.coerce(block, d.elem, sema.resolveInst(extra.rhs), src);
    if (!Type.hasRuntimeBits(ip, d.elem) and !Type.isComptimeOnly(ip, d.elem)) return .void_value;
    const len_val = sema.resolveValue(d.len);
    if (len_val != null and ip.intValue(u64, len_val.?).? == 0) return .void_value;

    if (sema.resolveValue(dest)) |dv| if (len_val) |lv| if (sema.resolveValue(elem)) |ev| {
        const raw_dest = (try sema.memRawPtr(block, .fromInterned(dv))).toInterned().?;
        if (!sema.isUndef(raw_dest) and try sema.comptimePtrRoot(raw_dest) == .comptime_alloc) {
            for (0..@intCast(ip.intValue(u64, lv).?)) |i| try sema.comptimeStore(block, src, try sema.ptrElemPtrVal(raw_dest, i), ev);
            return .void_value;
        }
    };
    try sema.requireRuntime(block, src);
    if (Type.isComptimeOnly(ip, d.elem)) return sema.fail(block, src, "cannot store comptime-only element '{f}' at runtime", .{sema.fmtType(d.elem)});
    _ = try sema.addBinOp(block, .memset, dest, elem);
    return .void_value;
}

fn elemValueType(sema: *Sema, slice_ty: Index) !Index {
    const p = Type.ptrInfo(sema.ip, slice_ty);
    return sema.ptrType(.{ .child = p.child, .sentinel = p.sentinel, .flags = .{ .size = .many, .is_const = p.flags.is_const, .is_volatile = p.flags.is_volatile } });
}

fn fieldPtrAt(sema: *Sema, block: *Block, src: Src, ptr: Ref, field_ty: Index, i: u32) CompileError!Ref {
    const ip = sema.ip;
    const p = Type.ptrInfo(ip, sema.typeOf(ptr));
    if (Type.isPackedStruct(ip, p.child)) {
        // A bit pointer into the struct's backing integer, at the same
        // address as the struct.
        try sema.resolveLayout(block, src, p.child);
        const bit_offset = p.packed_offset.bit_offset + Type.packedFieldBitOffset(ip, p.child, i);
        // The struct pointer's alignment, as upstream.
        const align_bytes: u64 = if (p.flags.alignment != 0) @as(u64, 1) << (p.flags.alignment - 1) else Type.abiAlignment(ip, p.child);
        const alignment: u6 = if (sema.naturalAlignment(field_ty) == align_bytes) 0 else @intCast(std.math.log2_int(u64, align_bytes) + 1);
        const result_ty = try sema.ptrType(.{
            .child = field_ty,
            .flags = .{ .is_const = p.flags.is_const, .is_volatile = p.flags.is_volatile, .alignment = alignment },
            .packed_offset = .{
                .host_size = if (p.packed_offset.host_size != 0) p.packed_offset.host_size else @intCast(Type.abiSize(ip, p.child)),
                .bit_offset = bit_offset,
            },
        });
        if (sema.resolveValue(ptr)) |pv| {
            if (!sema.isUndef(pv) and try sema.comptimePtrRoot(pv) != .int) {
                return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = result_ty, .base = .{ .field = .{ .base = pv, .index = i } } } }));
            }
        }
        try sema.requireRuntime(block, src);
        return sema.addTyOp(block, .bitcast, result_ty, ptr);
    }
    if (ip.indexToKey(p.child) == .union_type and Type.isPacked(ip, p.child)) {
        // The union's address, alignment, and bit offset, as upstream.
        try sema.resolveLayout(block, src, p.child);
        var info = p;
        info.child = field_ty;
        const align_bytes: u64 = if (p.flags.alignment != 0) @as(u64, 1) << (p.flags.alignment - 1) else Type.abiAlignment(ip, p.child);
        info.flags.alignment = if (sema.naturalAlignment(field_ty) == align_bytes) 0 else @intCast(std.math.log2_int(u64, align_bytes) + 1);
        const result_ty = try sema.ptrType(info);
        if (sema.resolveValue(ptr)) |pv| {
            if (!sema.isUndef(pv) and try sema.comptimePtrRoot(pv) != .int) {
                return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = result_ty, .base = .{ .field = .{ .base = pv, .index = i } } } }));
            }
        }
        try sema.requireRuntime(block, src);
        return sema.addTyOp(block, .bitcast, result_ty, ptr);
    }
    const result_ty = try sema.ptrType(.{ .child = field_ty, .flags = .{ .is_const = p.flags.is_const, .is_volatile = p.flags.is_volatile } });
    if (sema.resolveValue(ptr)) |pv| {
        if (try sema.comptimePtrRoot(pv) != .int) {
            return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = result_ty, .base = .{ .field = .{ .base = pv, .index = i } } } }));
        }
    }
    try sema.requireRuntime(block, src);
    return sema.addStructField(block, .struct_field_ptr, result_ty, ptr, i);
}

fn sliceLen(sema: *Sema, block: *Block, slice: Ref) CompileError!Ref {
    if (sema.resolveValue(slice)) |v| {
        if (sema.isUndef(v)) return .fromInterned(.undef_usize);
        return .fromInterned(sema.ip.indexToKey(v).slice.len);
    }
    return sema.addTyOp(block, .slice_len, .usize_type, slice);
}

fn slicePtr(sema: *Sema, block: *Block, slice: Ref) CompileError!Ref {
    const many_ty = try sema.elemValueType(sema.typeOf(slice));
    if (sema.resolveValue(slice)) |v| {
        if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(many_ty));
        return .fromInterned(sema.ip.indexToKey(v).slice.ptr);
    }
    return sema.addTyOp(block, .slice_ptr, many_ty, slice);
}

/// Emits `index < len` as a safety check.
fn boundsCheck(sema: *Sema, block: *Block, src: Src, index: Ref, len: Ref, allow_eq: bool) CompileError!void {
    if (sema.resolveValue(index)) |i| if (sema.resolveValue(len)) |l| {
        if (sema.isUndef(i) or sema.isUndef(l)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
        const iv = sema.ip.intValue(u64, i).?;
        const lv = sema.ip.intValue(u64, l).?;
        if (iv > lv or (iv == lv and !allow_eq)) return sema.fail(block, src, "index {d} outside array of length {d}", .{ iv, lv });
        return;
    };
    if (!block.want_safety or block.is_comptime) return;
    const ok = try sema.addBinOp(block, if (allow_eq) .cmp_lte else .cmp_lt, index, len);
    try sema.addSafetyCheck(block, ok, .out_of_bounds, index, len);
}

/// `&lhs[index]` where `ptr` points to the indexable object.
fn elemPtr(sema: *Sema, block: *Block, src: Src, ptr: Ref, uncasted_index: Ref, safety: bool) CompileError!Ref {
    const ip = sema.ip;
    const ptr_ty = sema.typeOf(ptr);
    if (Type.class(ip, ptr_ty) != .pointer) return sema.fail(block, src, "expected pointer, found '{f}'", .{sema.fmtType(ptr_ty)});
    const p = Type.ptrInfo(ip, ptr_ty);
    const child = p.child;
    switch (ip.indexToKey(child)) {
        .array_type => |a| {
            const index = try sema.coerce(block, .usize_type, uncasted_index, src);
            const len: Ref = .fromInterned(try sema.intValue(.usize_type, a.len));
            if (safety or sema.resolveValue(index) != null) try sema.boundsCheck(block, src, index, len, a.sentinel != .none);
            return sema.elemPtrOfArrayPtr(block, src, ptr, index);
        },
        .vector_type => |v| {
            const index = try sema.coerce(block, .usize_type, uncasted_index, src);
            if (v.len == 0) return sema.fail(block, src, "cannot index into empty vector", .{});
            if (sema.resolveValue(index) == null) return sema.fail(block, src, "vector index not comptime known", .{});
            try sema.boundsCheck(block, src, index, .fromInterned(try sema.intValue(.usize_type, v.len)), false);
            // Bool vectors are bit-packed; other vectors are laid out like arrays.
            if (v.child == .bool_type and !(sema.resolveValue(ptr) != null and sema.resolveValue(index) != null))
                return sema.failUnsupported(block, src, "runtime pointers to elements of bool vectors");
            return sema.elemPtrOfArrayPtr(block, src, ptr, index);
        },
        .ptr_type => |cp| switch (cp.flags.size) {
            .one => return sema.elemPtr(block, src, try sema.analyzeLoad(block, src, ptr), uncasted_index, safety),
            .many, .c => {
                const index = try sema.coerce(block, .usize_type, uncasted_index, src);
                return sema.elemPtrOfManyPtr(block, src, try sema.analyzeLoad(block, src, ptr), index);
            },
            .slice => return sema.elemPtrOfSlice(block, src, try sema.analyzeLoad(block, src, ptr), uncasted_index, safety),
        },
        .tuple_type => {
            const iv = sema.resolveValue(try sema.coerce(block, .usize_type, uncasted_index, src)) orelse return sema.fail(block, src, "tuple index must be comptime-known", .{});
            const i = ip.intValue(u64, iv).?;
            var buf: [20]u8 = undefined;
            return sema.fieldPtr(block, src, ptr, std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable);
        },
        else => {},
    }
    if (p.flags.size == .many or p.flags.size == .slice) return sema.fail(block, src, "expected pointer to an indexable object, found '{f}'", .{sema.fmtType(ptr_ty)});
    return sema.fail(block, src, "type '{f}' does not support indexing", .{sema.fmtType(child)});
}

/// `elem_ptr`: `&lhs[index]` where `lhs` itself is the pointer (a for
/// loop's pointer capture).
fn elemPtrOneLayer(sema: *Sema, block: *Block, src: Src, ptr: Ref, uncasted_index: Ref) CompileError!Ref {
    const ip = sema.ip;
    const ptr_ty = sema.typeOf(ptr);
    if (Type.class(ip, ptr_ty) != .pointer) return sema.fail(block, src, "pointer capture of non pointer type '{f}'", .{sema.fmtType(ptr_ty)});
    switch (Type.ptrInfo(ip, ptr_ty).flags.size) {
        .one => return sema.elemPtr(block, src, ptr, uncasted_index, false),
        .many, .c => return sema.elemPtrOfManyPtr(block, src, ptr, try sema.coerce(block, .usize_type, uncasted_index, src)),
        .slice => return sema.elemPtrOfSlice(block, src, ptr, uncasted_index, false),
    }
}

fn elemPtrOfSlice(sema: *Sema, block: *Block, src: Src, slice: Ref, uncasted_index: Ref, safety: bool) CompileError!Ref {
    const cp = Type.ptrInfo(sema.ip, sema.typeOf(slice));
    const index = try sema.coerce(block, .usize_type, uncasted_index, src);
    if (safety) try sema.boundsCheck(block, src, index, try sema.sliceLen(block, slice), cp.sentinel != .none);
    if (sema.resolveValue(slice)) |sv| if (sema.resolveValue(index)) |iv| {
        return .fromInterned(try sema.ptrElemPtrVal(sema.ip.indexToKey(sv).slice.ptr, sema.ip.intValue(u64, iv).?));
    };
    try sema.requireRuntime(block, src);
    const elem_ptr_ty = try sema.ptrType(.{ .child = cp.child, .flags = .{ .is_const = cp.flags.is_const, .is_volatile = cp.flags.is_volatile } });
    return sema.addTyPlBin(block, .slice_elem_ptr, elem_ptr_ty, slice, index);
}

fn elemPtrOfArrayPtr(sema: *Sema, block: *Block, src: Src, ptr: Ref, index: Ref) CompileError!Ref {
    const p = Type.ptrInfo(sema.ip, sema.typeOf(ptr));
    const elem_ty = Type.childType(sema.ip, p.child);
    const result_ty = try sema.ptrType(.{ .child = elem_ty, .flags = .{ .is_const = p.flags.is_const, .is_volatile = p.flags.is_volatile } });
    if (sema.resolveValue(ptr)) |pv| if (sema.resolveValue(index)) |iv| {
        if (try sema.comptimePtrRoot(pv) != .int)
            return .fromInterned(try sema.ptrElemPtrVal(pv, sema.ip.intValue(u64, iv).?));
    };
    try sema.requireRuntime(block, src);
    return sema.addTyPlBin(block, .ptr_elem_ptr, result_ty, ptr, index);
}

fn elemPtrOfManyPtr(sema: *Sema, block: *Block, src: Src, ptr: Ref, index: Ref) CompileError!Ref {
    const p = Type.ptrInfo(sema.ip, sema.typeOf(ptr));
    const result_ty = try sema.ptrType(.{ .child = p.child, .flags = .{ .is_const = p.flags.is_const, .is_volatile = p.flags.is_volatile } });
    if (sema.resolveValue(ptr)) |pv| if (sema.resolveValue(index)) |iv| {
        if (sema.ip.indexToKey(pv) == .ptr and try sema.comptimePtrRoot(pv) != .int)
            return .fromInterned(try sema.ptrElemPtrVal(pv, sema.ip.intValue(u64, iv).?));
    };
    try sema.requireRuntime(block, src);
    return sema.addTyPlBin(block, .ptr_elem_ptr, result_ty, ptr, index);
}

/// `lhs[index]` where `lhs` is an indexable value.
fn elemVal(sema: *Sema, block: *Block, src: Src, lhs: Ref, uncasted_index: Ref, safety: bool) CompileError!Ref {
    const ip = sema.ip;
    const ty = sema.typeOf(lhs);
    switch (ip.indexToKey(ty)) {
        .ptr_type => |p| switch (p.flags.size) {
            .slice => {
                const index = try sema.coerce(block, .usize_type, uncasted_index, src);
                // The sentinel of a sentinel-terminated slice can be read.
                if (safety) try sema.boundsCheck(block, src, index, try sema.sliceLen(block, lhs), p.sentinel != .none);
                if (sema.resolveValue(lhs)) |sv| if (sema.resolveValue(index)) |iv| {
                    const ep = try sema.ptrElemPtrVal(ip.indexToKey(sv).slice.ptr, ip.intValue(u64, iv).?);
                    if (try sema.comptimeLoadOrNull(block, src, ep)) |v| return .fromInterned(v);
                };
                try sema.requireRuntime(block, src);
                return sema.addBinOp(block, .slice_elem_val, lhs, index);
            },
            .one, .many, .c => {
                const index = try sema.coerce(block, .usize_type, uncasted_index, src);
                const ep = if (p.flags.size == .one) blk: {
                    const a = ip.indexToKey(p.child).array_type;
                    if (safety) try sema.boundsCheck(block, src, index, .fromInterned(try sema.intValue(.usize_type, a.len)), a.sentinel != .none);
                    break :blk try sema.elemPtrOfArrayPtr(block, src, lhs, index);
                } else try sema.elemPtrOfManyPtr(block, src, lhs, index);
                return sema.analyzeLoad(block, src, ep);
            },
        },
        .array_type => |a| {
            const index = try sema.coerce(block, .usize_type, uncasted_index, src);
            if (safety or sema.resolveValue(index) != null) try sema.boundsCheck(block, src, index, .fromInterned(try sema.intValue(.usize_type, a.len)), a.sentinel != .none);
            if (sema.resolveValue(lhs)) |v| if (sema.resolveValue(index)) |iv| return .fromInterned(try sema.elemValue(v, ip.intValue(u64, iv).?));
            try sema.requireRuntime(block, src);
            return sema.addBinOp(block, .array_elem_val, lhs, index);
        },
        .vector_type => |v| {
            const index = try sema.coerce(block, .usize_type, uncasted_index, src);
            if (safety or sema.resolveValue(index) != null) try sema.boundsCheck(block, src, index, .fromInterned(try sema.intValue(.usize_type, v.len)), false);
            if (Type.isInt(ip, v.child) and Type.intInfo(ip, v.child).bits == 0) return .fromInterned(try sema.intValue(v.child, 0));
            if (sema.resolveValue(lhs)) |val| if (sema.resolveValue(index)) |iv| return .fromInterned(try sema.elemValue(val, ip.intValue(u64, iv).?));
            try sema.requireRuntime(block, src);
            return sema.addBinOp(block, .array_elem_val, lhs, index);
        },
        .tuple_type => {
            const iv = sema.resolveValue(try sema.coerce(block, .usize_type, uncasted_index, src)) orelse return sema.fail(block, src, "tuple index must be comptime-known", .{});
            return sema.tupleField(block, lhs, @intCast(ip.intValue(u64, iv).?));
        },
        else => return sema.fail(block, src, "type '{f}' does not support indexing", .{sema.fmtType(ty)}),
    }
}

fn zirSlice(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ip = sema.ip;
    const tag = sema.code.instructions.items(.tag)[@backingInt(inst)];
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const src = block.nodeSrc(data.src_node);
    var lhs_ref: Zir.Inst.Ref = undefined;
    var start_ref: Zir.Inst.Ref = undefined;
    var end_ref: Zir.Inst.Ref = .none;
    var len_ref: Zir.Inst.Ref = .none;
    var sentinel_ref: Zir.Inst.Ref = .none;
    switch (tag) {
        .slice_start => {
            const e = sema.code.extraData(Zir.Inst.SliceStart, data.payload_index).data;
            lhs_ref = e.lhs;
            start_ref = e.start;
        },
        .slice_end => {
            const e = sema.code.extraData(Zir.Inst.SliceEnd, data.payload_index).data;
            lhs_ref = e.lhs;
            start_ref = e.start;
            end_ref = e.end;
        },
        .slice_length => {
            const e = sema.code.extraData(Zir.Inst.SliceLength, data.payload_index).data;
            lhs_ref = e.lhs;
            start_ref = e.start;
            len_ref = e.len;
            sentinel_ref = e.sentinel;
        },
        .slice_sentinel => {
            const e = sema.code.extraData(Zir.Inst.SliceSentinel, data.payload_index).data;
            lhs_ref = e.lhs;
            start_ref = e.start;
            end_ref = e.end;
            sentinel_ref = e.sentinel;
        },
        else => unreachable,
    }
    const ptr = sema.resolveInst(lhs_ref);
    const ptr_ty = sema.typeOf(ptr);
    if (Type.class(ip, ptr_ty) != .pointer) return sema.fail(block, src, "expected pointer, found '{f}'", .{sema.fmtType(ptr_ty)});
    const child = Type.ptrInfo(ip, ptr_ty).child;

    // Find the base many-pointer, the element type, and the length if known.
    var base: Ref = undefined; // a many-pointer to element 0
    var len: Ref = .none;
    var is_const = Type.ptrInfo(ip, ptr_ty).flags.is_const;
    var ptr_align = Type.ptrInfo(ip, ptr_ty).flags.alignment;
    var elem_ty: Index = undefined;
    // The sentinel of the sliced object, which the result keeps when it
    // ends where the object does.
    var ptr_sentinel: Index = .none;
    var many_obj: Ref = .none;
    switch (ip.indexToKey(child)) {
        .array_type => |a| {
            elem_ty = a.child;
            ptr_sentinel = a.sentinel;
            len = .fromInterned(try sema.intValue(.usize_type, a.len));
            base = try sema.coercePtrTo(block, ptr, try sema.ptrType(.{ .child = a.child, .flags = .{ .size = .many, .is_const = is_const } }));
        },
        .ptr_type => |cp| {
            const obj = try sema.analyzeLoad(block, src, ptr);
            is_const = cp.flags.is_const;
            ptr_align = cp.flags.alignment;
            switch (cp.flags.size) {
                .one => {
                    const a = ip.indexToKey(cp.child).array_type;
                    elem_ty = a.child;
                    ptr_sentinel = a.sentinel;
                    len = .fromInterned(try sema.intValue(.usize_type, a.len));
                    base = try sema.coercePtrTo(block, obj, try sema.ptrType(.{ .child = a.child, .flags = .{ .size = .many, .is_const = is_const } }));
                },
                .slice => {
                    elem_ty = cp.child;
                    ptr_sentinel = cp.sentinel;
                    len = try sema.sliceLen(block, obj);
                    base = try sema.slicePtr(block, obj);
                    if (cp.sentinel != .none) base = try sema.coercePtrTo(block, base, try sema.ptrType(.{ .child = elem_ty, .flags = .{ .size = .many, .is_const = is_const } }));
                },
                .many, .c => {
                    elem_ty = cp.child;
                    ptr_sentinel = cp.sentinel;
                    many_obj = obj;
                    base = obj;
                    if (cp.sentinel != .none) base = try sema.coercePtrTo(block, base, try sema.ptrType(.{ .child = elem_ty, .flags = .{ .size = .many, .is_const = is_const } }));
                },
            }
        },
        else => return sema.fail(block, src, "slice of non-array type '{f}'", .{sema.fmtType(child)}),
    }
    const start = try sema.coerce(block, .usize_type, sema.resolveInst(start_ref), src);
    var end: Ref = undefined;
    var slice_len: Ref = .none;
    if (len_ref != .none) {
        slice_len = try sema.coerce(block, .usize_type, sema.resolveInst(len_ref), src);
        end = try sema.analyzeArithmetic(block, src, .add, start, slice_len);
    } else if (end_ref != .none) {
        end = try sema.coerce(block, .usize_type, sema.resolveInst(end_ref), src);
    } else if (len == .none) {
        // `ptr[start..]` of a many-pointer is pointer arithmetic, keeping
        // the pointer's type.
        if (sentinel_ref != .none) return sema.failUnsupported(block, src, "sentinel-terminated slicing of many-item pointers");
        return sema.analyzePtrArithmetic(block, src, true, many_obj, start);
    } else {
        end = len;
    }
    const slice_sentinel: Index = if (sentinel_ref != .none) blk: {
        const casted = try sema.coerce(block, elem_ty, sema.resolveInst(sentinel_ref), src);
        break :blk try sema.resolveConstValue(block, src, casted, "slice sentinel must be comptime-known");
    } else .none;
    if (len != .none) {
        // The sliced object's sentinel may be included, and a slice sentinel
        // must be within the object.
        const len_s = if (ptr_sentinel == .none) len else try sema.analyzeArithmetic(block, src, .add, len, .fromInterned(.one_usize));
        const end_s = if (slice_sentinel == .none) end else try sema.analyzeArithmetic(block, src, .add, end, .fromInterned(.one_usize));
        try sema.boundsCheck(block, src, end_s, len_s, true);
    }
    const start_val = sema.resolveValue(start);
    const end_val = sema.resolveValue(end);
    // Whether the result ends where the sliced object does (not counting
    // its sentinel).
    const end_is_len = end_ref == .none and len_ref == .none or blk: {
        if (len == .none) break :blk false;
        const lv = sema.resolveValue(len) orelse break :blk false;
        const ev = end_val orelse break :blk false;
        break :blk ip.intValue(u64, lv).? == ip.intValue(u64, ev).?;
    };
    const result_sentinel: Index = if (slice_sentinel != .none) slice_sentinel else if (end_is_len) ptr_sentinel else .none;
    if (start_val != null and end_val != null) {
        const sv = ip.intValue(u64, start_val.?).?;
        const ev = ip.intValue(u64, end_val.?).?;
        if (sv > ev) return sema.fail(block, src, "start index {d} is larger than end index {d}", .{ sv, ev });
    } else if (block.want_safety and !block.is_comptime) {
        const ok = try sema.addBinOp(block, .cmp_lte, start, end);
        try sema.addSafetyCheck(block, ok, .start_greater_than_end, start, end);
    }

    // The result keeps an explicit alignment as far as the start allows.
    const result_align: u6 = if (ptr_align == 0) 0 else a: {
        const sv = if (start_val) |v| ip.intValue(u64, v).? else break :a 0;
        const off = sv * Type.abiSize(ip, elem_ty);
        const bytes: u64 = @as(u64, 1) << @intCast(ptr_align - 1);
        const al = if (off == 0) bytes else @min(bytes, @as(u64, 1) << @intCast(@ctz(off)));
        break :a if (sema.naturalAlignment(elem_ty) == al) 0 else @intCast(std.math.log2_int(u64, al) + 1);
    };
    const many_ty = sema.typeOf(base);
    const base_val = sema.resolveValue(base);
    const new_ptr: Ref = if (start_val != null and ip.intValue(u64, start_val.?).? == 0)
        base
    else if (base_val != null and sema.isUndef(base_val.?))
        .fromInterned(try sema.undefValue(many_ty))
    else if (base_val != null and start_val != null and try sema.comptimePtrRoot(base_val.?) != .int)
        try sema.coercePtrToMany(try sema.ptrElemPtrVal(base_val.?, ip.intValue(u64, start_val.?).?), many_ty)
    else
        try sema.addTyPlBin(block, .ptr_add, many_ty, base, start);

    // A comptime-known length (`x[a..][0..4]`, or both bounds) gives a
    // pointer to an array.
    const known_len: ?u64 = if (slice_len != .none)
        (if (sema.resolveValue(slice_len)) |v| ip.intValue(u64, v).? else null)
    else if (start_val != null and end_val != null)
        ip.intValue(u64, end_val.?).? - ip.intValue(u64, start_val.?).?
    else
        null;
    if (slice_sentinel != .none) try sema.checkSliceSentinel(block, src, new_ptr, start_val, end_val, start, end, elem_ty, slice_sentinel);
    if (known_len) |n| {
        const array_ty = try sema.intern(.{ .array_type = .{ .len = n, .child = elem_ty, .sentinel = result_sentinel } });
        const result_ty = try sema.ptrType(.{ .child = array_ty, .flags = .{ .is_const = is_const, .alignment = result_align } });
        if (sema.resolveValue(new_ptr)) |pv| {
            if (sema.isUndef(pv)) return .fromInterned(try sema.undefValue(result_ty));
            const k = ip.indexToKey(pv).ptr;
            switch (k.base) {
                .elem => |e| {
                    if (try sema.isArrayPtrOfLen(e.base, elem_ty, n) and e.index == 0 and result_sentinel == .none) return .fromInterned(e.base);
                    // A pointer to the subarray starting at element `e.index`.
                    return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = result_ty, .base = k.base } }));
                },
                // The same address viewed as an array pointer.
                else => return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = result_ty, .base = k.base, .byte_offset = k.byte_offset } })),
            }
        }
        return sema.addTyOp(block, .bitcast, result_ty, new_ptr);
    }
    const slice_ty = try sema.ptrType(.{ .child = elem_ty, .sentinel = result_sentinel, .flags = .{ .size = .slice, .is_const = is_const, .alignment = result_align } });
    const new_len = try sema.analyzeArithmetic(block, src, .subwrap, end, start);
    return sema.makeSlice(block, slice_ty, new_ptr, new_len);
}

/// `ptr[start..end :s]` requires `ptr[end - start] == s`: checked at
/// comptime when the memory is comptime-known, else at runtime.
fn checkSliceSentinel(sema: *Sema, block: *Block, src: Src, many: Ref, start_val: ?Index, end_val: ?Index, start: Ref, end: Ref, elem_ty: Index, sentinel: Index) CompileError!void {
    const ip = sema.ip;
    if (start_val != null and end_val != null) if (sema.resolveValue(many)) |pv| if (try sema.comptimePtrRoot(pv) != .int) {
        const idx = ip.intValue(u64, end_val.?).? - ip.intValue(u64, start_val.?).?;
        const elem_ptr = try sema.ptrElemPtrVal(pv, idx);
        if (try sema.comptimeLoadOrNull(block, src, elem_ptr)) |actual| {
            if (actual != sentinel) return sema.fail(block, src, "value in memory does not match slice sentinel", .{});
            return;
        }
    };
    if (!block.want_safety or block.is_comptime) return;
    const idx = try sema.analyzeArithmetic(block, src, .subwrap, end, start);
    const elem_ptr = try sema.addTyPlBin(block, .ptr_add, sema.typeOf(many), many, idx);
    const actual = try sema.analyzeLoad(block, src, elem_ptr);
    const ok = try sema.analyzeCmp(block, src, .eq, actual, .fromInterned(sentinel));
    _ = elem_ty;
    try sema.addSafetyCheck(block, ok, .sentinel_mismatch, .fromInterned(sentinel), actual);
}

fn isArrayPtrOfLen(sema: *Sema, ptr: Index, elem_ty: Index, n: u64) !bool {
    const child = Type.ptrInfo(sema.ip, sema.ip.typeOf(ptr)).child;
    return switch (sema.ip.indexToKey(child)) {
        .array_type => |a| a.child == elem_ty and a.len == n and a.sentinel == .none,
        else => false,
    };
}

/// Turns a comptime pointer to an element into a many-pointer of type `ty`.
fn coercePtrToMany(sema: *Sema, elem_ptr: Index, ty: Index) !Ref {
    var k = sema.ip.indexToKey(elem_ptr).ptr;
    k.ty = ty;
    return .fromInterned(try sema.intern(.{ .ptr = k }));
}

fn zirForLen(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.MultiOp, data.payload_index);
    const args = sema.code.refSlice(extra.end, extra.data.operands_len);
    const src = block.nodeSrc(data.src_node);
    var len: Ref = .none;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const a = args[i];
        const b = args[i + 1];
        if (a == .none and b == .none) continue;
        const this_len = if (b == .none) blk: {
            const obj = sema.resolveInst(a);
            break :blk try sema.fieldVal(block, src, obj, "len");
        } else blk: {
            const start = try sema.coerce(block, .usize_type, sema.resolveInst(a), src);
            const end = try sema.coerce(block, .usize_type, sema.resolveInst(b), src);
            break :blk try sema.analyzeArithmetic(block, src, .sub, end, start);
        };
        if (len == .none) {
            len = this_len;
        } else if (block.want_safety) {
            const ok = try sema.analyzeCmp(block, src, .eq, len, this_len);
            if (sema.resolveValue(ok)) |v| {
                if (v != .bool_true) return sema.fail(block, src, "non-matching for loop lengths", .{});
            } else try sema.addSafetyCheck(block, ok, .for_len_mismatch, .none, .none);
        }
    }
    if (len == .none) return sema.fail(block, src, "unbounded for loop", .{});
    return len;
}

// ---------------------------------------------------------------------------
// Optionals, error unions, and switch

fn analyzeIsNonNull(sema: *Sema, block: *Block, src: Src, operand: Ref) CompileError!Ref {
    const ty = sema.typeOf(operand);
    switch (Type.class(sema.ip, ty)) {
        .null => return .fromInterned(.bool_false),
        .optional => {},
        else => return sema.fail(block, src, "expected optional type, found '{f}'", .{sema.fmtType(ty)}),
    }
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(.undef_bool);
        return .fromInterned(boolValue(sema.ip.indexToKey(v).opt.val != .none));
    }
    try sema.requireRuntime(block, src);
    return sema.addUnOp(block, .is_non_null, operand);
}

fn optionalPayload(sema: *Sema, block: *Block, src: Src, operand: Ref, safe: bool) CompileError!Ref {
    const ty = sema.typeOf(operand);
    if (Type.class(sema.ip, ty) != .optional) return sema.fail(block, src, "expected optional type, found '{f}'", .{sema.fmtType(ty)});
    const child = Type.childType(sema.ip, ty);
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(child));
        const payload = sema.ip.indexToKey(v).opt.val;
        if (payload == .none) return sema.fail(block, src, "unable to unwrap null", .{});
        return .fromInterned(payload);
    }
    try sema.requireRuntime(block, src);
    if (safe and block.want_safety) {
        const ok = try sema.addUnOp(block, .is_non_null, operand);
        try sema.addSafetyCheck(block, ok, .unwrap_null, .none, .none);
    }
    return sema.addTyOp(block, .optional_payload, child, operand);
}

fn optionalPayloadPtr(sema: *Sema, block: *Block, src: Src, ptr: Ref, safe: bool, set: bool) CompileError!Ref {
    const ip = sema.ip;
    const p = Type.ptrInfo(ip, sema.typeOf(ptr));
    if (Type.class(ip, p.child) != .optional) return sema.fail(block, src, "expected optional type, found '{f}'", .{sema.fmtType(p.child)});
    const child = Type.childType(ip, p.child);
    const result_ty = try sema.ptrType(.{ .child = child, .flags = .{ .is_const = p.flags.is_const, .is_volatile = p.flags.is_volatile } });
    if (sema.resolveValue(ptr)) |pv| if (try sema.comptimePtrRoot(pv) != .int) {
        if (set) {
            try sema.comptimeStore(block, src, pv, try sema.intern(.{ .opt = .{ .ty = p.child, .val = try sema.undefValue(child) } }));
        } else if (try sema.comptimeLoadOrNull(block, src, pv)) |v| {
            if (safe and !sema.isUndef(v) and ip.indexToKey(v).opt.val == .none) return sema.fail(block, src, "unable to unwrap null", .{});
        }
        return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = result_ty, .base = .{ .field = .{ .base = pv, .index = 0 } } } }));
    };
    try sema.requireRuntime(block, src);
    if (safe and block.want_safety) {
        const loaded = try sema.analyzeLoad(block, src, ptr);
        const ok = try sema.addUnOp(block, .is_non_null, loaded);
        try sema.addSafetyCheck(block, ok, .unwrap_null, .none, .none);
    }
    return sema.addTyOp(block, if (set) .optional_payload_ptr_set else .optional_payload_ptr, result_ty, ptr);
}

fn analyzeIsNonErr(sema: *Sema, block: *Block, src: Src, operand: Ref) CompileError!Ref {
    const ty = sema.typeOf(operand);
    switch (Type.class(sema.ip, ty)) {
        .error_set => return .fromInterned(.bool_false),
        .error_union => {},
        else => return .fromInterned(.bool_true),
    }
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(.undef_bool);
        return .fromInterned(boolValue(sema.ip.indexToKey(v).error_union.val == .payload));
    }
    try sema.requireRuntime(block, src);
    return sema.addUnOp(block, .is_non_err, operand);
}

fn errUnionPayload(sema: *Sema, block: *Block, src: Src, operand: Ref) CompileError!Ref {
    const ty = sema.typeOf(operand);
    if (Type.class(sema.ip, ty) != .error_union) return sema.fail(block, src, "expected error union type, found '{f}'", .{sema.fmtType(ty)});
    const payload_ty = sema.ip.indexToKey(ty).error_union_type.payload_type;
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(payload_ty));
        switch (sema.ip.indexToKey(v).error_union.val) {
            .payload => |p| return .fromInterned(p),
            .err_name => |n| return sema.fail(block, src, "caught unexpected error 'error.{s}'", .{sema.ip.stringSlice(n)}),
        }
    }
    try sema.requireRuntime(block, src);
    return sema.addTyOp(block, .unwrap_errunion_payload, payload_ty, operand);
}

fn errUnionPayloadPtr(sema: *Sema, block: *Block, src: Src, ptr: Ref, set: bool) CompileError!Ref {
    const ip = sema.ip;
    const p = Type.ptrInfo(ip, sema.typeOf(ptr));
    if (Type.class(ip, p.child) != .error_union) return sema.fail(block, src, "expected error union type, found '{f}'", .{sema.fmtType(p.child)});
    const payload_ty = ip.indexToKey(p.child).error_union_type.payload_type;
    const result_ty = try sema.ptrType(.{ .child = payload_ty, .flags = .{ .is_const = p.flags.is_const, .is_volatile = p.flags.is_volatile } });
    if (sema.resolveValue(ptr)) |pv| if (try sema.comptimePtrRoot(pv) != .int) {
        if (set) try sema.comptimeStore(block, src, pv, try sema.intern(.{ .error_union = .{ .ty = p.child, .val = .{ .payload = try sema.undefValue(payload_ty) } } }));
        return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = result_ty, .base = .{ .field = .{ .base = pv, .index = 0 } } } }));
    };
    try sema.requireRuntime(block, src);
    return sema.addTyOp(block, if (set) .errunion_payload_ptr_set else .unwrap_errunion_payload_ptr, result_ty, ptr);
}

fn errUnionCode(sema: *Sema, block: *Block, src: Src, operand: Ref) CompileError!Ref {
    const ty = sema.typeOf(operand);
    if (Type.class(sema.ip, ty) != .error_union) return sema.fail(block, src, "expected error union type, found '{f}'", .{sema.fmtType(ty)});
    const set_ty = sema.ip.indexToKey(ty).error_union_type.error_set_type;
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(set_ty));
        switch (sema.ip.indexToKey(v).error_union.val) {
            .err_name => |n| return .fromInterned(try sema.intern(.{ .err = .{ .ty = set_ty, .name = n } })),
            .payload => return sema.fail(block, src, "expected error, found payload", .{}),
        }
    }
    try sema.requireRuntime(block, src);
    return sema.addTyOp(block, .unwrap_errunion_err, set_ty, operand);
}

fn zirTry(sema: *Sema, parent: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Try, data.payload_index);
    const body = sema.code.bodySlice(extra.end, extra.data.body_len);
    const src = parent.nodeSrc(data.src_node);
    const operand = sema.resolveInst(extra.data.operand);
    const ty = sema.typeOf(operand);
    if (Type.class(sema.ip, ty) != .error_union) return sema.fail(parent, src, "expected error union type, found '{f}'", .{sema.fmtType(ty)});
    const is_non_err = try sema.analyzeIsNonErr(parent, src, operand);
    if (sema.resolveValue(is_non_err)) |v| {
        if (v == .bool_true) return sema.errUnionPayload(parent, src, operand);
        try sema.analyzeBodyInner(parent, body);
        return .unreachable_value;
    }
    const block_inst = try sema.reserveInst();
    var ok_block = parent.child();
    defer ok_block.instructions.deinit(sema.gpa);
    _ = try sema.addInst(&ok_block, .{ .tag = .br, .data = .{ .br = .{ .block_inst = block_inst, .operand = .void_value } } });
    var err_block = parent.child();
    defer err_block.instructions.deinit(sema.gpa);
    try sema.analyzeBodyInner(&err_block, body);
    var inner = parent.child();
    defer inner.instructions.deinit(sema.gpa);
    try sema.addCondBr(&inner, is_non_err, ok_block.instructions.items, err_block.instructions.items);
    try sema.addBlock(parent, block_inst, .void_type, inner.instructions.items);
    return sema.errUnionPayload(parent, src, operand);
}

const SwitchCase = struct {
    items: []Index,
    /// Inclusive `first...last` pairs.
    ranges: [][2]Index,
    body: []const Zir.Inst.Index,
    capture: Zir.Inst.SwitchBlock.ProngInfo.Capture,
    /// An inline prong has one comptime-known item per analysis.
    is_inline: bool = false,
    /// The instruction a union tag capture binds, or `none`.
    tag_inst: Zir.Inst.OptionalIndex = .none,
};

fn zirSwitchBlock(sema: *Sema, parent: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const src = parent.nodeSrc(data.src_node);
    const sb = sema.code.getSwitchBlock(inst);
    return sema.analyzeSwitch(parent, src, inst, sema.resolveInst(sb.main_operand));
}

/// `if (eu) |payload| ... else |err| switch (err) { ... }` and
/// `eu catch |err| switch (err) { ... }`.
fn zirSwitchBlockErrUnion(sema: *Sema, parent: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const gpa = sema.gpa;
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const src = parent.nodeSrc(data.src_node);
    const sb = sema.code.getSwitchBlock(inst);
    const non_err = sb.non_err_case.?;
    var eu = sema.resolveInst(sb.main_operand);
    if (non_err.operand_is_ref) {
        if (non_err.capture == .by_ref) return sema.failUnsupported(parent, src, "error union payload captures by reference");
        eu = try sema.analyzeLoad(parent, src, eu);
    }
    if (Type.class(sema.ip, sema.typeOf(eu)) != .error_union) return sema.fail(parent, src, "expected error union type, found '{f}'", .{sema.fmtType(sema.typeOf(eu))});
    const cond = try sema.analyzeIsNonErr(parent, src, eu);
    if (parent.is_comptime) {
        const v = sema.resolveValue(cond) orelse return sema.fail(parent, src, "unable to evaluate comptime expression", .{});
        if (v == .bool_false) return sema.analyzeSwitch(parent, src, inst, try sema.errUnionCode(parent, src, eu));
        if (non_err.capture != .none) try sema.inst_map.put(gpa, inst, try sema.errUnionPayload(parent, src, eu));
        return (try sema.analyzeInlineBody(parent, non_err.body, inst)) orelse .unreachable_value;
    }

    const block_inst = try sema.reserveInst();
    var label: Block.Label = .{ .zir_block = inst, .merges = .{ .block_inst = block_inst } };
    defer {
        label.merges.results.deinit(gpa);
        label.merges.brs.deinit(gpa);
    }
    var outer = parent.child();
    outer.label = &label;
    defer outer.instructions.deinit(gpa);

    const cond_val = sema.resolveValue(cond);
    var then_block = outer.child();
    defer then_block.instructions.deinit(gpa);
    if (cond_val != .bool_false) {
        if (non_err.capture != .none) try sema.inst_map.put(gpa, inst, try sema.errUnionPayload(&then_block, src, eu));
        if (try sema.analyzeInlineBody(&then_block, non_err.body, inst)) |result| try sema.addBr(&then_block, &label, result);
    }
    var else_block = outer.child();
    defer else_block.instructions.deinit(gpa);
    if (cond_val != .bool_true) {
        const code = try sema.errUnionCode(&else_block, src, eu);
        const result = try sema.analyzeSwitch(&else_block, src, inst, code);
        if (sema.typeOf(result) != .noreturn_type) try sema.addBr(&else_block, &label, result);
    }
    if (cond_val) |v| {
        const chosen = if (v == .bool_true) &then_block else &else_block;
        try outer.instructions.appendSlice(gpa, chosen.instructions.items);
    } else {
        try sema.addCondBr(&outer, cond, then_block.instructions.items, else_block.instructions.items);
    }
    return sema.resolveBlock(parent, src, &outer, &label.merges);
}

fn analyzeSwitch(sema: *Sema, parent: *Block, src: Src, inst: Zir.Inst.Index, operand: Ref) CompileError!Ref {
    const ip = sema.ip;
    const gpa = sema.gpa;
    const sb = sema.code.getSwitchBlock(inst);
    if (sb.has_continue) return sema.failUnsupported(parent, src, "labeled switch continue");
    // A tagged union switches on its tag; prongs capture the payload.
    var cond = operand;
    if (Type.class(ip, sema.typeOf(operand)) == .@"union") {
        try sema.resolveLayout(parent, src, sema.typeOf(operand));
        if (ip.indexToKey(ip.structInfo(sema.typeOf(operand)).tag_type) != .enum_type) return sema.fail(parent, src, "switch on union with no attached enum", .{});
        cond = try sema.unionTag(parent, src, operand);
    }
    const operand_ty = sema.typeOf(cond);
    switch (Type.class(ip, operand_ty)) {
        .int, .comptime_int, .bool, .error_set, .enum_literal, .type, .@"enum" => {},
        else => return sema.fail(parent, src, "zap does not support switching on '{f}' yet", .{sema.fmtType(operand_ty)}),
    }
    if (Type.class(ip, operand_ty) == .@"enum") try sema.resolveLayout(parent, src, operand_ty);
    const capture_inst: Zir.Inst.Index = sb.payload_capture_placeholder.unwrap() orelse inst;
    const tag_inst: Zir.Inst.Index = sb.tag_capture_placeholder.unwrap() orelse inst;
    const is_union = Type.class(ip, sema.typeOf(operand)) == .@"union";

    // Evaluate the case items at comptime.
    var cases: std.ArrayList(SwitchCase) = .empty;
    var item_block = parent.child();
    defer item_block.instructions.deinit(gpa);
    item_block.is_comptime = true;
    var extra_index = sb.end;
    var under_index: ?usize = null;
    var it = sb.iterateCases();
    while (it.next()) |case| {
        if (case.prong_info.has_tag_capture and !is_union) return sema.fail(parent, src, "cannot capture tag of non-union type '{f}'", .{sema.fmtType(sema.typeOf(operand))});
        const body = sema.code.bodySlice(extra_index, case.prong_info.body_len);
        extra_index += body.len;
        var items: std.ArrayList(Index) = .empty;
        for (case.item_infos) |info| {
            if (info.unwrap() == .under) {
                under_index = cases.items.len;
                continue;
            }
            try items.append(sema.arena, try sema.switchItem(&item_block, src, inst, info, operand_ty, &extra_index));
        }
        const ranges = try sema.arena.alloc([2]Index, case.range_infos.len);
        for (case.range_infos, ranges) |pair, *range| {
            range[0] = try sema.switchItem(&item_block, src, inst, pair[0], operand_ty, &extra_index);
            range[1] = try sema.switchItem(&item_block, src, inst, pair[1], operand_ty, &extra_index);
        }
        try cases.append(sema.arena, .{
            .items = items.items,
            .ranges = ranges,
            .body = body,
            .capture = case.prong_info.capture,
            .is_inline = case.prong_info.is_inline,
            .tag_inst = if (case.prong_info.has_tag_capture) tag_inst.toOptional() else .none,
        });
    }
    var else_case: ?SwitchCase = if (sb.else_case) |e| .{
        .items = &.{},
        .ranges = &.{},
        .body = e.body,
        .capture = e.capture,
        .is_inline = e.is_inline,
        .tag_inst = if (e.has_tag_capture) tag_inst.toOptional() else .none,
    } else null;
    if (else_case) |e| if (e.tag_inst != .none and !is_union) return sema.fail(parent, src, "cannot capture tag of non-union type '{f}'", .{sema.fmtType(sema.typeOf(operand))});
    if (sb.has_under and (Type.class(ip, operand_ty) != .@"enum" or !ip.structInfo(operand_ty).nonexhaustive))
        return sema.fail(parent, src, "'_' prong only allowed when switching on non-exhaustive enums", .{});
    if (else_case == null and Type.class(ip, operand_ty) == .bool) {
        var seen_true = false;
        var seen_false = false;
        for (cases.items) |c| for (c.items) |v| {
            if (v == .bool_true) seen_true = true else seen_false = true;
        };
        if (!seen_true or !seen_false) return sema.fail(parent, src, "switch must handle all possibilities", .{});
    } else if (else_case == null and Type.class(ip, operand_ty) == .@"enum") {
        const info = ip.structInfo(operand_ty);
        if (info.nonexhaustive and !sb.has_under) return sema.fail(parent, src, "switch on non-exhaustive enum must include 'else' or '_' prong", .{});
        for (info.field_defaults) |fv| {
            const tv = try sema.intern(.{ .enum_tag = .{ .ty = operand_ty, .int = fv } });
            for (cases.items) |c| {
                if (std.mem.indexOfScalar(Index, c.items, tv) != null) break;
            } else return sema.fail(parent, src, "switch must handle all possibilities", .{});
        }
    } else if (else_case == null and Type.class(ip, operand_ty) != .error_set) {
        if (!try sema.switchCoversAllInts(cases.items, operand_ty)) return sema.fail(parent, src, "switch must handle all possibilities", .{});
    }

    // A `_` prong is the else prong of a non-exhaustive enum.
    const under_prong: ?SwitchCase = if (under_index) |k| cases.items[k] else null;
    if (else_case) |e| if (e.is_inline) {
        // `inline else` becomes one inline prong per value no other prong
        // handles.
        const all = try sema.switchAllValues(parent, src, operand_ty);
        for (all) |v| {
            for (cases.items) |c| {
                if (try sema.switchCaseMatches(c, v)) break;
            } else {
                const items = try sema.arena.alloc(Index, 1);
                items[0] = v;
                var c = e;
                c.items = items;
                try cases.append(sema.arena, c);
            }
        }
        else_case = null;
    };
    {
        // Split inline prongs into one prong per item.
        var expanded: std.ArrayList(SwitchCase) = .empty;
        for (cases.items) |c| {
            if (!c.is_inline or (c.items.len == 1 and c.ranges.len == 0)) {
                try expanded.append(sema.arena, c);
                continue;
            }
            for (c.items) |item| {
                var one = c;
                one.items = try sema.arena.dupe(Index, &.{item});
                one.ranges = &.{};
                try expanded.append(sema.arena, one);
            }
            for (c.ranges) |r| {
                const lo = sema.ip.intValue(i64, r[0]) orelse return sema.failUnsupported(parent, src, "large inline switch ranges");
                const hi = sema.ip.intValue(i64, r[1]) orelse return sema.failUnsupported(parent, src, "large inline switch ranges");
                if (hi - lo >= 1 << 12) return sema.failUnsupported(parent, src, "large inline switch ranges");
                var x = lo;
                while (x <= hi) : (x += 1) {
                    var one = c;
                    one.items = try sema.arena.dupe(Index, &.{try sema.intValue(operand_ty, x)});
                    one.ranges = &.{};
                    try expanded.append(sema.arena, one);
                }
            }
        }
        cases = expanded;
    }
    const under_case = under_prong orelse else_case;

    // Comptime-known operand: analyze only the matching prong.
    if (sema.resolveValue(cond)) |v| {
        const chosen = for (cases.items) |c| {
            if (try sema.switchCaseMatches(c, v)) break c;
        } else under_case orelse return sema.fail(parent, src, "switch must handle all possibilities", .{});
        if (parent.is_comptime) {
            try sema.bindSwitchCaptures(parent, src, chosen, operand, capture_inst);
            return sema.resolveInlineBody(parent, chosen.body, inst);
        }
        return sema.switchProngsRuntime(parent, src, inst, cond, operand, &.{chosen}, null, capture_inst);
    }
    try sema.requireRuntime(parent, src);
    return sema.switchProngsRuntime(parent, src, inst, cond, operand, cases.items, under_case, capture_inst);
}

/// Every value of `ty`, for `inline else`.
fn switchAllValues(sema: *Sema, block: *Block, src: Src, ty: Index) CompileError![]const Index {
    const ip = sema.ip;
    var vals: std.ArrayList(Index) = .empty;
    switch (Type.class(ip, ty)) {
        .bool => try vals.appendSlice(sema.arena, &.{ .bool_false, .bool_true }),
        .@"enum" => {
            const info = ip.structInfo(ty);
            if (info.nonexhaustive) return sema.fail(block, src, "cannot enumerate values of type '{f}' for 'inline else'", .{sema.fmtType(ty)});
            for (info.field_defaults) |fv| try vals.append(sema.arena, try sema.intern(.{ .enum_tag = .{ .ty = ty, .int = fv } }));
        },
        .error_set => switch (ip.indexToKey(ty)) {
            .error_set_type => |names| for (names) |name| {
                try vals.append(sema.arena, try sema.intern(.{ .err = .{ .ty = ty, .name = name } }));
            },
            else => return sema.fail(block, src, "cannot enumerate values of type '{f}' for 'inline else'", .{sema.fmtType(ty)}),
        },
        .int => {
            const info = Type.intInfo(ip, ty);
            if (info.bits > 12) return sema.fail(block, src, "cannot enumerate values of type '{f}' for 'inline else'", .{sema.fmtType(ty)});
            var x = ip.intValue(i64, try sema.minIntValue(ty)).?;
            const max = ip.intValue(i64, try sema.maxIntValue(ty)).?;
            while (x <= max) : (x += 1) try vals.append(sema.arena, try sema.intValue(ty, x));
        },
        else => return sema.fail(block, src, "cannot enumerate values of type '{f}' for 'inline else'", .{sema.fmtType(ty)}),
    }
    return vals.items;
}

fn switchItem(sema: *Sema, block: *Block, src: Src, switch_inst: Zir.Inst.Index, info: Zir.Inst.SwitchBlock.ItemInfo, operand_ty: Index, extra_index: *usize) CompileError!Index {
    const ref: Ref = switch (info.unwrap()) {
        .body_len => |len| blk: {
            const body = sema.code.bodySlice(extra_index.*, len);
            extra_index.* += len;
            // The result type of item bodies is `.{ .coerce_ty = switch_inst }`.
            try sema.inst_map.put(sema.gpa, switch_inst, .fromInterned(operand_ty));
            defer _ = sema.inst_map.remove(switch_inst);
            break :blk try sema.resolveInlineBody(block, body, switch_inst);
        },
        .enum_literal => |s| .fromInterned(try sema.intern(.{ .enum_literal = try sema.getString(sema.zirString(s)) })),
        .error_value => |s| blk: {
            const name = try sema.getString(sema.zirString(s));
            const ty = try sema.intern(.{ .error_set_type = &.{name} });
            break :blk .fromInterned(try sema.intern(.{ .err = .{ .ty = ty, .name = name } }));
        },
        .under => unreachable,
    };
    const coerced = try sema.coerce(block, operand_ty, ref, src);
    return sema.resolveConstValue(block, src, coerced, "switch prong values must be comptime-known");
}

fn switchCaseMatches(sema: *Sema, c: SwitchCase, v: Index) !bool {
    for (c.items) |item| if (item == v) return true;
    for (c.ranges) |r| {
        var s0: [2]std.math.big.Limb = undefined;
        var s1: [2]std.math.big.Limb = undefined;
        var s2: [2]std.math.big.Limb = undefined;
        const x = sema.ip.intToBig(v, &s0);
        if (x.order(sema.ip.intToBig(r[0], &s1)) != .lt and x.order(sema.ip.intToBig(r[1], &s2)) != .gt) return true;
    }
    return false;
}

/// Whether the items and ranges of `cases` cover every value of int type `ty`.
fn switchCoversAllInts(sema: *Sema, cases: []const SwitchCase, ty: Index) !bool {
    if (ty == .comptime_int_type) return false;
    const info = Type.intInfo(sema.ip, ty);
    if (info.bits > 16) return false;
    const min = sema.ip.intValue(i64, try sema.minIntValue(ty)).?;
    const max = sema.ip.intValue(i64, try sema.maxIntValue(ty)).?;
    var covered: i64 = 0;
    for (cases) |c| {
        covered += @intCast(c.items.len);
        for (c.ranges) |r| covered += sema.ip.intValue(i64, r[1]).? - sema.ip.intValue(i64, r[0]).? + 1;
    }
    return covered >= max - min + 1;
}

fn switchProngsRuntime(
    sema: *Sema,
    parent: *Block,
    src: Src,
    inst: Zir.Inst.Index,
    cond: Ref,
    operand: Ref,
    cases: []const SwitchCase,
    else_case: ?SwitchCase,
    capture_inst: Zir.Inst.Index,
) CompileError!Ref {
    const gpa = sema.gpa;
    const block_inst = try sema.reserveInst();
    var label: Block.Label = .{ .zir_block = inst, .merges = .{ .block_inst = block_inst } };
    defer {
        label.merges.results.deinit(gpa);
        label.merges.brs.deinit(gpa);
    }
    var outer = parent.child();
    outer.label = &label;
    defer outer.instructions.deinit(gpa);

    if (cases.len == 1 and else_case == null and sema.resolveValue(cond) != null) {
        // A comptime-known operand selected this prong.
        try sema.analyzeProng(&outer, cases[0], operand, capture_inst, inst);
    } else {
        var any_ranges = false;
        for (cases) |c| any_ranges = any_ranges or c.ranges.len != 0;
        if (any_ranges) {
            try sema.switchAsCondBrs(&outer, src, cases, else_case, cond, operand, capture_inst, inst);
        } else {
            // switch_br: cases with items, then the else body.
            var bodies: std.ArrayList(u32) = .empty;
            defer bodies.deinit(gpa);
            for (cases) |c| {
                var prong = outer.child();
                defer prong.instructions.deinit(gpa);
                try sema.analyzeProng(&prong, c, operand, capture_inst, inst);
                try bodies.append(gpa, @intCast(c.items.len));
                try bodies.append(gpa, @intCast(prong.instructions.items.len));
                for (c.items) |item| try bodies.append(gpa, @backingInt(item));
                try bodies.appendSlice(gpa, @ptrCast(prong.instructions.items));
            }
            var else_block = outer.child();
            defer else_block.instructions.deinit(gpa);
            if (else_case) |e| {
                try sema.analyzeProng(&else_block, e, operand, capture_inst, inst);
            } else if (outer.want_safety) {
                try sema.addPanic(&else_block, .corrupt_switch, .none, .none);
            } else {
                _ = try sema.addInst(&else_block, .{ .tag = .unreach, .data = .{ .no_op = {} } });
            }
            const payload = try sema.addExtra(Ir.SwitchBr{ .cases_len = @intCast(cases.len), .else_body_len = @intCast(else_block.instructions.items.len) });
            try sema.ir_extra.appendSlice(gpa, bodies.items);
            try sema.appendBody(else_block.instructions.items);
            _ = try sema.addInst(&outer, .{ .tag = .switch_br, .data = .{ .pl_op = .{ .operand = cond, .payload = payload } } });
        }
    }
    return sema.resolveBlock(parent, src, &outer, &label.merges);
}

/// What a prong captures: the operand, or a union's payload.
fn switchCapture(sema: *Sema, block: *Block, src: Src, c: SwitchCase, operand: Ref) CompileError!Ref {
    const ip = sema.ip;
    const ty = sema.typeOf(operand);
    if (Type.class(ip, ty) == .error_set and c.items.len != 0 and !c.is_inline) {
        // The capture's type is the set of the prong's errors.
        const names = try sema.arena.alloc(InternPool.String, c.items.len);
        for (names, c.items) |*n, item| n.* = ip.indexToKey(item).err.name;
        const set = try sema.errorSetType(names);
        if (sema.resolveValue(operand)) |v| {
            if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(set));
            return .fromInterned(try sema.intern(.{ .err = .{ .ty = set, .name = ip.indexToKey(v).err.name } }));
        }
        return sema.addTyOp(block, .bitcast, set, operand);
    }
    if (Type.class(ip, ty) != .@"union") return if (c.is_inline) .fromInterned(c.items[0]) else operand;
    if (c.items.len == 0) return operand;
    const info = ip.structInfo(ty);
    const name = sema.enumTagName(c.items[0]).?;
    const i = info.fieldIndex(ip, name).?;
    if (sema.resolveValue(operand)) |v| return .fromInterned(try sema.fieldValue(v, i));
    try sema.requireRuntime(block, src);
    return sema.addStructField(block, .struct_field_val, info.field_types[i], operand, i);
}

fn bindSwitchCaptures(sema: *Sema, block: *Block, src: Src, c: SwitchCase, operand: Ref, capture_inst: Zir.Inst.Index) CompileError!void {
    try sema.inst_map.put(sema.gpa, capture_inst, if (c.capture == .none) operand else try sema.switchCapture(block, src, c, operand));
    if (c.tag_inst.unwrap()) |t| {
        try sema.inst_map.put(sema.gpa, t, if (c.is_inline) .fromInterned(c.items[0]) else try sema.unionTag(block, src, operand));
    }
}

fn analyzeProng(sema: *Sema, block: *Block, c: SwitchCase, operand: Ref, capture_inst: Zir.Inst.Index, switch_inst: Zir.Inst.Index) CompileError!void {
    if (c.capture == .by_ref) return sema.failUnsupported(block, block.nodeSrc(.zero), "switch captures by reference");
    try sema.bindSwitchCaptures(block, block.nodeSrc(.zero), c, operand, capture_inst);
    if (try sema.analyzeInlineBody(block, c.body, switch_inst)) |result| {
        // A prong ended with a comptime break to the switch.
        try sema.addBr(block, block.label.?, result);
    }
}

fn switchAsCondBrs(sema: *Sema, block: *Block, src: Src, cases: []const SwitchCase, else_case: ?SwitchCase, cond_operand: Ref, operand: Ref, capture_inst: Zir.Inst.Index, switch_inst: Zir.Inst.Index) CompileError!void {
    if (cases.len == 0) {
        if (else_case) |e| return sema.analyzeProng(block, e, operand, capture_inst, switch_inst);
        if (block.want_safety) return sema.addPanic(block, .corrupt_switch, .none, .none);
        _ = try sema.addInst(block, .{ .tag = .unreach, .data = .{ .no_op = {} } });
        return;
    }
    const c = cases[0];
    var cond: Ref = .fromInterned(.bool_false);
    for (c.items) |item| {
        const eq = try sema.addBinOp(block, .cmp_eq, cond_operand, .fromInterned(item));
        cond = if (cond.toInterned() == .bool_false) eq else try sema.addBinOp(block, .bit_or, cond, eq);
    }
    for (c.ranges) |r| {
        const ge = try sema.addBinOp(block, .cmp_gte, cond_operand, .fromInterned(r[0]));
        const le = try sema.addBinOp(block, .cmp_lte, cond_operand, .fromInterned(r[1]));
        const in = try sema.addBinOp(block, .bit_and, ge, le);
        cond = if (cond.toInterned() == .bool_false) in else try sema.addBinOp(block, .bit_or, cond, in);
    }
    var then_block = block.child();
    defer then_block.instructions.deinit(sema.gpa);
    try sema.analyzeProng(&then_block, c, operand, capture_inst, switch_inst);
    var else_block = block.child();
    defer else_block.instructions.deinit(sema.gpa);
    try sema.switchAsCondBrs(&else_block, src, cases[1..], else_case, cond_operand, operand, capture_inst, switch_inst);
    try sema.addCondBr(block, cond, then_block.instructions.items, else_block.instructions.items);
}

// ---------------------------------------------------------------------------
// Struct and array initialization

/// Builds an aggregate value from its elements (including an array's
/// sentinel), comptime-known if every element is.
fn aggregate(sema: *Sema, block: *Block, src: Src, ty: Index, elems: []const Ref) CompileError!Ref {
    const vals = try sema.arena.alloc(Index, elems.len);
    var all_comptime = true;
    for (elems, vals) |e, *v| {
        v.* = sema.resolveValue(e) orelse blk: {
            all_comptime = false;
            break :blk .none;
        };
    }
    if (all_comptime) return .fromInterned(try sema.intern(.{ .aggregate = .{ .ty = ty, .storage = .{ .elems = vals } } }));
    try sema.requireRuntime(block, src);
    try sema.resolveLayout(block, src, ty);
    if (Type.isPackedStruct(sema.ip, ty)) {
        const backing = sema.ip.structInfo(ty).tag_type;
        var host: Ref = .fromInterned(try sema.intValue(backing, 0));
        for (elems, 0..) |e, i| host = try sema.packedInsert(block, host, Type.packedFieldBitOffset(sema.ip, ty, i), e);
        return sema.addTyOp(block, .bitcast, ty, host);
    }
    const payload = try sema.addExtra(Ir.Aggregate{ .len = @intCast(elems.len) });
    try sema.ir_extra.appendSlice(sema.gpa, @ptrCast(elems));
    return sema.addInst(block, .{ .tag = .aggregate_init, .data = .{ .ty_pl = .{ .ty = ty, .payload = payload } } });
}

fn structInitEmpty(sema: *Sema, block: *Block, src: Src, ty: Index) CompileError!Ref {
    const ip = sema.ip;
    // `.{}` without a result type is the empty tuple.
    if (ty == .generic_poison_type) return .fromInterned(.empty_tuple);
    switch (ip.indexToKey(ty)) {
        .struct_type => {
            try sema.resolveStructFields(block, src, ty);
            const info = ip.structInfo(ty);
            const elems = try sema.arena.alloc(Ref, info.field_types.len);
            for (elems, 0..) |*e, i| {
                const d = info.field_defaults[i];
                if (d == .none) return sema.fail(block, src, "missing struct field: {s}", .{ip.stringSlice(info.field_names[i])});
                e.* = .fromInterned(d);
            }
            return sema.aggregate(block, src, ty, elems);
        },
        .array_type => |a| {
            if (a.len != 0) return sema.fail(block, src, "expected {d} array elements; found 0", .{a.len});
            return sema.aggregate(block, src, ty, if (a.sentinel != .none) &.{.fromInterned(a.sentinel)} else &.{});
        },
        .vector_type => |v| {
            if (v.len != 0) return sema.fail(block, src, "expected {d} vector elements; found 0", .{v.len});
            return sema.aggregate(block, src, ty, &.{});
        },
        .tuple_type => |t| if (t.types.len == 0) return .fromInterned(.empty_tuple),
        else => if (ty == .void_type) return .void_value,
    }
    return sema.fail(block, src, "type '{f}' does not support struct initialization syntax", .{sema.fmtType(ty)});
}

fn zirStructInit(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ip = sema.ip;
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const src = block.nodeSrc(data.src_node);
    const extra = sema.code.extraData(Zir.Inst.StructInit, data.payload_index);
    const n = extra.data.fields_len;
    var i = extra.end;
    var ty: Index = .none;
    const Item = struct { name: []const u8, init: Ref };
    const items = try sema.arena.alloc(Item, n);
    for (items) |*item| {
        const e = sema.code.extraData(Zir.Inst.StructInit.Item, i);
        i = e.end;
        const ft_data = sema.code.instructions.items(.data)[@backingInt(e.data.field_type)].pl_node;
        const ft = sema.code.extraData(Zir.Inst.FieldType, ft_data.payload_index).data;
        if (ty == .none) ty = try sema.resolveType(block, src, ft.container_type);
        item.* = .{ .name = sema.zirString(ft.name_start), .init = sema.resolveInst(e.data.init) };
    }
    if (ty == .clobbers_type) return .fromInterned(try sema.undefValue(.clobbers_type));
    if (ty == .generic_poison_type) {
        // No result type: an anonymous struct literal.
        const names = try sema.arena.alloc(InternPool.String, items.len);
        const inits = try sema.arena.alloc(Ref, items.len);
        for (items, names, inits) |item, *nm, *init| {
            nm.* = try sema.getString(item.name);
            init.* = item.init;
        }
        return sema.anonStructInit(block, inst, data.src_node, names, inits);
    }
    if (ip.indexToKey(ty) == .union_type) {
        if (items.len != 1) return sema.fail(block, src, "union initialization expects exactly one field", .{});
        const fi = try sema.unionFieldIndex(block, src, ty, items[0].name);
        const init = try sema.coerce(block, ip.structInfo(ty).field_types[fi], items[0].init, src);
        return sema.unionInit(block, src, ty, fi, init);
    }
    if (ip.indexToKey(ty) != .struct_type) return sema.fail(block, src, "type '{f}' does not support struct initialization syntax", .{sema.fmtType(ty)});
    try sema.resolveStructFields(block, src, ty);
    const info = ip.structInfo(ty);
    const elems = try sema.arena.alloc(Ref, info.field_types.len);
    @memset(elems, .none);
    for (items) |item| {
        const idx = try sema.structFieldIndex(block, src, ty, item.name);
        elems[idx] = try sema.coerce(block, info.field_types[idx], item.init, src);
    }
    for (elems, 0..) |*e, k| {
        if (e.* != .none) continue;
        const d = info.field_defaults[k];
        if (d == .none) return sema.fail(block, src, "missing struct field: {s}", .{ip.stringSlice(info.field_names[k])});
        e.* = .fromInterned(d);
    }
    return sema.aggregate(block, src, ty, elems);
}

/// `.{ .a = x, .b = y }` without a result type. Like upstream, its type is
/// a struct equal by its literal and fields, with comptime-known fields
/// as comptime fields, named `Parent__struct_<inst>`.
fn anonStructInit(sema: *Sema, block: *Block, inst: Zir.Inst.Index, src_node: Ast.Node.Offset, names: []const InternPool.String, inits: []const Ref) CompileError!Ref {
    const ip = sema.ip;
    const src = block.nodeSrc(src_node);
    for (names, 0..) |n, i| for (names[0..i]) |m| if (m == n)
        return sema.fail(block, src, "duplicate field name '{s}'", .{ip.stringSlice(n)});
    const types = try sema.arena.alloc(Index, inits.len);
    const values = try sema.arena.alloc(Index, inits.len);
    for (inits, types, values) |init, *t, *v| {
        t.* = sema.typeOf(init);
        v.* = sema.resolveValue(init) orelse .none;
        // A field referring to comptime-mutable memory cannot be a comptime field.
        if (v.* != .none and ip.indexToKey(v.*) == .ptr and try sema.comptimePtrRoot(v.*) == .comptime_alloc) v.* = .none;
    }

    var site: std.Io.Writer.Allocating = .init(sema.arena);
    var parent: std.Io.Writer.Allocating = .init(sema.arena);
    const owner_nav: InternPool.NavIndex = if (block.inlining) |inl|
        ip.indexToKey(inl.func).func.owner_nav
    else switch (sema.owner) {
        .func => |f| ip.indexToKey(f).func.owner_nav,
        else => sema.owner_nav,
    };
    if (owner_nav != .none) {
        site.writer.writeAll(ip.stringSlice(ip.getNav(owner_nav).key)) catch return error.OutOfMemory;
        parent.writer.writeAll(ip.stringSlice(ip.getNav(owner_nav).fqn)) catch return error.OutOfMemory;
    } else {
        sema.zcu.unitKey(sema.owner, &site.writer) catch return error.OutOfMemory;
        parent.writer.writeAll(sema.zcu.namespacePtr(block.namespace).fqn) catch return error.OutOfMemory;
    }
    site.writer.print("#lit{d}", .{@backingInt(src_node)}) catch return error.OutOfMemory;
    parent.writer.print("__struct_{d}", .{@backingInt(inst)}) catch return error.OutOfMemory;

    const ty = try sema.intern(.{ .tuple_type = .{
        .types = types,
        .values = values,
        .names = names,
        .site = try sema.getString(site.written()),
        .name = try sema.getString(parent.written()),
    } });
    return sema.aggregate(block, src, ty, inits);
}

fn zirValidatePtrStructInit(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!void {
    const ip = sema.ip;
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const src = block.nodeSrc(data.src_node);
    const extra = sema.code.extraData(Zir.Inst.Block, data.payload_index);
    const field_ptrs = sema.code.bodySlice(extra.end, extra.data.body_len);
    const first = sema.code.instructions.items(.data)[@backingInt(field_ptrs[0])].pl_node;
    const obj_ptr = sema.resolveInst(sema.code.extraData(Zir.Inst.Field, first.payload_index).data.lhs);
    const ty = Type.ptrInfo(ip, sema.typeOf(obj_ptr)).child;
    if (ip.indexToKey(ty) != .struct_type) return;
    const info = ip.structInfo(ty);
    const seen = try sema.arena.alloc(bool, info.field_types.len);
    @memset(seen, false);
    for (field_ptrs) |fp| {
        const d = sema.code.instructions.items(.data)[@backingInt(fp)].pl_node;
        const name = sema.zirString(sema.code.extraData(Zir.Inst.Field, d.payload_index).data.field_name_start);
        seen[try sema.structFieldIndex(block, src, ty, name)] = true;
    }
    for (seen, 0..) |s, k| {
        if (s) continue;
        const d = info.field_defaults[k];
        if (d == .none) return sema.fail(block, src, "missing struct field: {s}", .{ip.stringSlice(info.field_names[k])});
        const field_ptr = try sema.fieldPtrAt(block, src, obj_ptr, info.field_types[k], @intCast(k));
        try sema.analyzeStore(block, src, field_ptr, .fromInterned(d));
    }
}

fn zirValidatePtrArrayInit(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!void {
    const ip = sema.ip;
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const src = block.nodeSrc(data.src_node);
    const extra = sema.code.extraData(Zir.Inst.Block, data.payload_index);
    const elem_ptrs = sema.code.bodySlice(extra.end, extra.data.body_len);
    const first = sema.code.instructions.items(.data)[@backingInt(elem_ptrs[0])].pl_node;
    const arr_ptr = sema.resolveInst(sema.code.extraData(Zir.Inst.ElemPtrImm, first.payload_index).data.ptr);
    const ty = Type.ptrInfo(ip, sema.typeOf(arr_ptr)).child;
    switch (ip.indexToKey(ty)) {
        .array_type => |a| {
            if (a.len != elem_ptrs.len) return sema.fail(block, src, "expected {d} array elements; found {d}", .{ a.len, elem_ptrs.len });
            if (a.sentinel != .none) {
                const len: Ref = .fromInterned(try sema.intValue(.usize_type, a.len));
                const sp = try sema.elemPtrOfArrayPtr(block, src, arr_ptr, len);
                try sema.analyzeStore(block, src, sp, .fromInterned(a.sentinel));
            }
        },
        .vector_type => |v| {
            if (v.len != elem_ptrs.len) return sema.fail(block, src, "expected {d} vector elements; found {d}", .{ v.len, elem_ptrs.len });
            if (sema.bool_vector_inits.fetchRemove(arr_ptr)) |kv| {
                const arr = try sema.analyzeLoad(block, src, kv.value);
                try sema.analyzeStore(block, src, arr_ptr, try sema.coerce(block, ty, arr, src));
            }
        },
        else => {},
    }
}

fn zirArrayInit(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ip = sema.ip;
    const tag = sema.code.instructions.items(.tag)[@backingInt(inst)];
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const src = block.nodeSrc(data.src_node);
    const extra = sema.code.extraData(Zir.Inst.MultiOp, data.payload_index);
    const args = sema.code.refSlice(extra.end, extra.data.operands_len);
    const result_ty: Index = if (tag == .array_init_anon) .generic_poison_type else try sema.resolveType(block, src, args[0]);
    if (result_ty == .generic_poison_type) {
        // An anonymous array literal, or one whose result type is unknown: a tuple.
        const operands = if (tag == .array_init_anon) args else args[1..];
        const types = try sema.arena.alloc(Index, operands.len);
        const values = try sema.arena.alloc(Index, operands.len);
        const elems = try sema.arena.alloc(Ref, operands.len);
        for (operands, types, values, elems) |a, *t, *v, *e| {
            e.* = sema.resolveInst(a);
            t.* = sema.typeOf(e.*);
            v.* = sema.resolveValue(e.*) orelse .none;
        }
        const ty = try sema.intern(.{ .tuple_type = .{ .types = types, .values = values } });
        return sema.aggregate(block, src, ty, elems);
    }
    var ty = result_ty;
    const inits = args[1..];
    switch (ip.indexToKey(ty)) {
        .array_type => |a| {
            if (a.len != inits.len) return sema.fail(block, src, "expected {d} array elements; found {d}", .{ a.len, inits.len });
            const elems = try sema.arena.alloc(Ref, a.lenIncludingSentinel());
            for (inits, 0..) |e, k| elems[k] = try sema.coerce(block, a.child, sema.resolveInst(e), src);
            if (a.sentinel != .none) elems[a.len] = .fromInterned(a.sentinel);
            return sema.aggregate(block, src, ty, elems);
        },
        .vector_type => |v| {
            if (v.len != inits.len) return sema.fail(block, src, "expected {d} vector elements; found {d}", .{ v.len, inits.len });
            const elems = try sema.arena.alloc(Ref, v.len);
            for (inits, elems) |e, *r| r.* = try sema.coerce(block, v.child, sema.resolveInst(e), src);
            return sema.aggregate(block, src, ty, elems);
        },
        .tuple_type => |t| {
            if (t.types.len != inits.len) return sema.fail(block, src, "expected {d} tuple elements; found {d}", .{ t.types.len, inits.len });
            const elems = try sema.arena.alloc(Ref, inits.len);
            for (inits, 0..) |e, k| elems[k] = try sema.coerce(block, t.types[k], sema.resolveInst(e), src);
            return sema.aggregate(block, src, ty, elems);
        },
        else => {
            ty = ty;
            return sema.fail(block, src, "type '{f}' does not support array initialization syntax", .{sema.fmtType(ty)});
        },
    }
}

/// `lhs ++ rhs`: arrays, pointers to arrays, comptime-known slices, and
/// tuples. The result is an array, or a constant pointer to one if either
/// operand is a pointer; two tuples give a tuple.
fn zirArrayCat(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ip = sema.ip;
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Bin, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    const lhs = sema.resolveInst(extra.lhs);
    const rhs = sema.resolveInst(extra.rhs);
    const lhs_ty = sema.typeOf(lhs);
    const rhs_ty = sema.typeOf(rhs);
    const lhs_tuple = ip.indexToKey(lhs_ty) == .tuple_type;
    const rhs_tuple = ip.indexToKey(rhs_ty) == .tuple_type;
    if (lhs_tuple and rhs_tuple) {
        const a = ip.indexToKey(lhs_ty).tuple_type;
        const b = ip.indexToKey(rhs_ty).tuple_type;
        if (a.types.len == 0) return rhs;
        if (b.types.len == 0) return lhs;
        const n = a.types.len + b.types.len;
        const types = try sema.arena.alloc(Index, n);
        const values = try sema.arena.alloc(Index, n);
        @memcpy(types[0..a.types.len], a.types);
        @memcpy(types[a.types.len..], b.types);
        @memcpy(values[0..a.types.len], a.values);
        @memcpy(values[a.types.len..], b.values);
        const ty = try sema.intern(.{ .tuple_type = .{ .types = types, .values = values } });
        const elems = try sema.arena.alloc(Ref, n);
        for (elems, 0..) |*e, i| e.* = if (i < a.types.len)
            try sema.tupleField(block, lhs, @intCast(i))
        else
            try sema.tupleField(block, rhs, @intCast(i - a.types.len));
        return sema.aggregate(block, src, ty, elems);
    }
    const l = try sema.arrayCatInfo(block, src, lhs, rhs_ty) orelse
        return sema.fail(block, src, "expected indexable; found '{f}'", .{sema.fmtType(lhs_ty)});
    const r = try sema.arrayCatInfo(block, src, rhs, lhs_ty) orelse
        return sema.fail(block, src, "expected indexable; found '{f}'", .{sema.fmtType(rhs_ty)});
    const elem_ty = try sema.peerPair(block, src, l.elem, r.elem);
    // Both sentinels must agree; a lone sentinel is kept.
    var sentinel: Index = .none;
    if (l.sentinel != .none or r.sentinel != .none) {
        const ls: Index = if (l.sentinel == .none) .none else sema.resolveValue(try sema.coerce(block, elem_ty, .fromInterned(l.sentinel), src)).?;
        const rs: Index = if (r.sentinel == .none) .none else sema.resolveValue(try sema.coerce(block, elem_ty, .fromInterned(r.sentinel), src)).?;
        sentinel = if (ls == .none) rs else if (rs == .none or rs == ls) ls else .none;
    }
    const len = l.len + r.len;
    const result_ty = try sema.intern(.{ .array_type = .{ .len = len, .child = elem_ty, .sentinel = sentinel } });
    const elems = try sema.arena.alloc(Ref, @intCast(len + @intFromBool(sentinel != .none)));
    try sema.catElems(block, src, lhs, elem_ty, elems[0..@intCast(l.len)]);
    try sema.catElems(block, src, rhs, elem_ty, elems[@intCast(l.len)..@intCast(len)]);
    if (sentinel != .none) elems[@intCast(len)] = .fromInterned(sentinel);
    const result = try sema.aggregate(block, src, result_ty, elems);
    const is_ptr = Type.class(ip, lhs_ty) == .pointer or Type.class(ip, rhs_ty) == .pointer;
    return if (is_ptr) sema.analyzeRef(block, src, result) else result;
}

const ArrayCatInfo = struct { elem: Index, len: u64, sentinel: Index };

fn arrayCatInfo(sema: *Sema, block: *Block, src: Src, operand: Ref, peer_ty: Index) CompileError!?ArrayCatInfo {
    const ip = sema.ip;
    const ty = sema.typeOf(operand);
    switch (ip.indexToKey(ty)) {
        .array_type => |a| return .{ .elem = a.child, .len = a.len, .sentinel = a.sentinel },
        .ptr_type => |p| switch (p.flags.size) {
            .slice => {
                const v = try sema.resolveConstValue(block, src, operand, "slice value being concatenated must be comptime-known");
                if (sema.isUndef(v)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
                return .{ .elem = p.child, .len = ip.intValue(u64, ip.indexToKey(v).slice.len).?, .sentinel = p.sentinel };
            },
            .one => if (ip.indexToKey(p.child) == .array_type) {
                const a = ip.indexToKey(p.child).array_type;
                return .{ .elem = a.child, .len = a.len, .sentinel = a.sentinel };
            },
            .many, .c => {},
        },
        .tuple_type => |t| {
            const peer_elem: Index = switch (ip.indexToKey(peer_ty)) {
                .array_type => |a| a.child,
                .ptr_type => |p| if (p.flags.size != .one)
                    p.child
                else if (ip.indexToKey(p.child) == .array_type)
                    ip.indexToKey(p.child).array_type.child
                else
                    return null,
                else => return null,
            };
            return .{ .elem = peer_elem, .len = t.types.len, .sentinel = .none };
        },
        else => {},
    }
    return null;
}

/// The elements of `++` operand `operand`, coerced to `elem_ty`.
fn catElems(sema: *Sema, block: *Block, src: Src, operand: Ref, elem_ty: Index, out: []Ref) CompileError!void {
    const ip = sema.ip;
    const ty = sema.typeOf(operand);
    // A comptime-known array (directly or behind a pointer) is read once.
    var val: ?Index = if (sema.resolveValue(operand)) |v| switch (ip.indexToKey(ty)) {
        .ptr_type => |p| if (p.flags.size == .one) try sema.comptimeLoadOrNull(block, src, v) else null,
        else => v,
    } else null;
    if (val == .none) val = null;
    for (out, 0..) |*e, i| {
        const elem: Ref = if (val) |v|
            .fromInterned(try sema.elemValue(v, i))
        else
            try sema.elemVal(block, src, operand, .fromInterned(try sema.intValue(.usize_type, i)), false);
        e.* = try sema.coerce(block, elem_ty, elem, src);
    }
}

fn zirOptEuBasePtrInit(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].un_node;
    const src = block.nodeSrc(data.src_node);
    var ptr = sema.resolveInst(data.operand);
    while (true) {
        const child = Type.ptrInfo(sema.ip, sema.typeOf(ptr)).child;
        switch (Type.class(sema.ip, child)) {
            .optional => ptr = try sema.optionalPayloadPtr(block, src, ptr, false, true),
            .error_union => ptr = try sema.errUnionPayloadPtr(block, src, ptr, true),
            else => return ptr,
        }
    }
}

// ---------------------------------------------------------------------------
// Casts

fn zirEnsureResultUsed(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!void {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].un_node;
    const src = block.nodeSrc(data.src_node);
    const ty = sema.typeOf(sema.resolveInst(data.operand));
    switch (Type.class(sema.ip, ty)) {
        .void, .noreturn => {},
        .error_set => return sema.fail(block, src, "error set is ignored", .{}),
        .error_union => return sema.fail(block, src, "error union is ignored", .{}),
        else => return sema.fail(block, src, "value of type '{f}' ignored", .{sema.fmtType(ty)}),
    }
}

fn zirIntCast(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Bin, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    const dest_ty = try sema.resolveType(block, src, extra.lhs);
    return sema.analyzeIntCast(block, src, dest_ty, sema.resolveInst(extra.rhs));
}

fn analyzeIntCast(sema: *Sema, block: *Block, src: Src, dest_ty: Index, operand: Ref) CompileError!Ref {
    const ip = sema.ip;
    if (try sema.vectorCast(block, src, dest_ty, operand, analyzeIntCast)) |r| return r;
    const src_ty = sema.typeOf(operand);
    if (!Type.isInt(ip, dest_ty) and dest_ty != .comptime_int_type) return sema.fail(block, src, "expected integer type, found '{f}'", .{sema.fmtType(dest_ty)});
    if (!Type.isInt(ip, src_ty) and src_ty != .comptime_int_type) return sema.fail(block, src, "expected integer type, found '{f}'", .{sema.fmtType(src_ty)});
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(dest_ty));
        if (!sema.intFits(v, dest_ty)) return sema.fail(block, src, "type '{f}' cannot represent integer value '{f}'", .{ sema.fmtType(dest_ty), sema.fmtValue(v) });
        var space: [2]std.math.big.Limb = undefined;
        return .fromInterned(try sema.bigToValue(dest_ty, ip.intToBig(v, &space)));
    }
    try sema.requireRuntime(block, src);
    if (dest_ty == .comptime_int_type) return sema.fail(block, src, "unable to cast runtime value to 'comptime_int'", .{});
    if (dest_ty == src_ty) return operand;
    const s = Type.intInfo(ip, src_ty);
    const d = Type.intInfo(ip, dest_ty);
    if (block.want_safety) {
        // Check the value is within the destination's range, comparing in
        // the source type.
        var ok: Ref = .fromInterned(.bool_true);
        const min = try sema.minIntValue(dest_ty);
        const max = try sema.maxIntValue(dest_ty);
        if (s.signedness == .signed and sema.intSign(min) >= 0 or (s.signedness == .signed and d.bits < s.bits)) {
            if (sema.intFits(min, src_ty)) {
                var space: [2]std.math.big.Limb = undefined;
                const min_s: Ref = .fromInterned(try sema.bigToValue(src_ty, ip.intToBig(min, &space)));
                ok = try sema.addBinOp(block, .cmp_gte, operand, min_s);
            }
        }
        if (sema.intFits(max, src_ty)) {
            var space: [2]std.math.big.Limb = undefined;
            const src_max = try sema.maxIntValue(src_ty);
            if (src_max != try sema.bigToValue(src_ty, ip.intToBig(max, &space))) {
                const max_s: Ref = .fromInterned(try sema.bigToValue(src_ty, ip.intToBig(max, &space)));
                const hi = try sema.addBinOp(block, .cmp_lte, operand, max_s);
                ok = if (ok.toInterned() == .bool_true) hi else try sema.addBinOp(block, .bit_and, ok, hi);
            }
        }
        try sema.addSafetyCheck(block, ok, .integer_out_of_bounds, .none, .none);
    }
    return sema.addTyOp(block, .intcast, dest_ty, operand);
}

fn zirTruncate(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Bin, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    const dest_ty = try sema.resolveType(block, src, extra.lhs);
    return sema.analyzeTruncate(block, src, dest_ty, sema.resolveInst(extra.rhs));
}

fn analyzeTruncate(sema: *Sema, block: *Block, src: Src, dest_ty: Index, operand: Ref) CompileError!Ref {
    const ip = sema.ip;
    if (try sema.vectorCast(block, src, dest_ty, operand, analyzeTruncate)) |r| return r;
    const src_ty = sema.typeOf(operand);
    if (dest_ty == .comptime_int_type) return sema.coerce(block, dest_ty, operand, src);
    if (!Type.isInt(ip, dest_ty)) return sema.fail(block, src, "expected integer type, found '{f}'", .{sema.fmtType(dest_ty)});
    if (!Type.isInt(ip, src_ty) and src_ty != .comptime_int_type) return sema.fail(block, src, "expected integer type, found '{f}'", .{sema.fmtType(src_ty)});
    const d = Type.intInfo(ip, dest_ty);
    if (d.bits == 0) return .fromInterned(try sema.intValue(dest_ty, 0));
    // As upstream: a truncation that drops no bits is a coercion.
    if (src_ty != .comptime_int_type) {
        const s = Type.intInfo(ip, src_ty);
        if (s.signedness != d.signedness) return sema.fail(block, src, "expected {t} integer type, found '{f}'", .{ d.signedness, sema.fmtType(src_ty) });
        if (d.bits >= s.bits) return sema.coerce(block, dest_ty, operand, src);
    }
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(dest_ty));
        var big = try sema.bigValue(v);
        try big.truncate(&big, d.signedness, d.bits);
        return .fromInterned(try sema.bigToValue(dest_ty, big.toConst()));
    }
    try sema.requireRuntime(block, src);
    return sema.addTyOp(block, .trunc, dest_ty, operand);
}

fn zirBitCast(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ip = sema.ip;
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Bin, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    const dest_ty = try sema.resolveType(block, src, extra.lhs);
    const operand = sema.resolveInst(extra.rhs);
    const src_ty = sema.typeOf(operand);
    if (Type.isInt(ip, dest_ty) and Type.isInt(ip, src_ty)) {
        const d = Type.intInfo(ip, dest_ty);
        if (d.bits != Type.intInfo(ip, src_ty).bits) return sema.fail(block, src, "@bitCast size mismatch: destination type '{f}' has {d} bits but source type '{f}' has {d} bits", .{ sema.fmtType(dest_ty), d.bits, sema.fmtType(src_ty), Type.intInfo(ip, src_ty).bits });
        if (sema.resolveValue(operand)) |v| {
            if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(dest_ty));
            var big = try sema.bigValue(v);
            try big.truncate(&big, d.signedness, d.bits);
            return .fromInterned(try sema.bigToValue(dest_ty, big.toConst()));
        }
        try sema.requireRuntime(block, src);
        return sema.addTyOp(block, .bitcast, dest_ty, operand);
    }
    // Integers, floats, and arrays of them without padding bits: the same
    // bits in memory order.
    try sema.resolveLayout(block, src, dest_ty);
    try sema.resolveLayout(block, src, src_ty);
    if (sema.bitCastBits(dest_ty)) |d_bits| if (sema.bitCastBits(src_ty)) |s_bits| {
        if (d_bits != s_bits) return sema.fail(block, src, "@bitCast size mismatch: destination type '{f}' has {d} bits but source type '{f}' has {d} bits", .{ sema.fmtType(dest_ty), d_bits, sema.fmtType(src_ty), s_bits });
        if (sema.resolveValue(operand)) |v| {
            if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(dest_ty));
            var bits = try BigInt.init(sema.arena);
            try sema.valueBits(v, &bits, 0);
            return .fromInterned(try sema.bitsValue(dest_ty, bits.toConst(), 0));
        }
        try sema.requireRuntime(block, src);
        return sema.addTyOp(block, .bitcast, dest_ty, operand);
    };
    return sema.failUnsupported(block, src, "@bitCast between these types");
}

/// The bits of `ty` if `@bitCast` reinterprets it as plain bits: an
/// integer, a float, or an array of them without padding bits.
fn bitCastBits(sema: *Sema, ty: Index) ?u64 {
    const ip = sema.ip;
    return switch (ip.indexToKey(ty)) {
        .int_type => |info| info.bits,
        .array_type => |a| blk: {
            if (a.sentinel != .none) break :blk null;
            const eb = sema.bitCastBits(a.child) orelse break :blk null;
            if (eb != Type.abiSize(ip, a.child) * 8) break :blk null;
            break :blk eb * a.len;
        },
        // Bool vectors are bit-packed in memory too; other elements must
        // fill their bytes.
        .vector_type => |v| blk: {
            if (v.child == .bool_type) break :blk v.len;
            const eb = sema.bitCastBits(v.child) orelse break :blk null;
            if (eb != Type.abiSize(ip, v.child) * 8) break :blk null;
            break :blk eb * v.len;
        },
        .struct_type, .union_type => if (Type.isPacked(ip, ty)) Type.intInfo(ip, ip.structInfo(ty).tag_type).bits else null,
        else => if (Type.class(ip, ty) == .float) Type.floatBits(ip, ty) else if (ty == .bool_type) 1 else null,
    };
}

/// ORs the bits of value `v` (see `bitCastBits`) into `out` at bit `offset`.
fn valueBits(sema: *Sema, v: Index, out: *BigInt, offset: u64) Allocator.Error!void {
    const ip = sema.ip;
    const ty = ip.typeOf(v);
    var part = try BigInt.init(sema.arena);
    switch (Type.class(ip, ty)) {
        .array => {
            const child = Type.childType(ip, ty);
            const eb = sema.bitCastBits(child).?;
            for (0..ip.indexToKey(ty).array_type.len) |i| try sema.valueBits(try sema.elemValue(v, i), out, offset + i * eb);
            return;
        },
        .vector => {
            const child = Type.childType(ip, ty);
            const eb = sema.bitCastBits(child).?;
            for (0..ip.indexToKey(ty).vector_type.len) |i| try sema.valueBits(try sema.elemValue(v, i), out, offset + i * eb);
            return;
        },
        .float => try part.set(ip.indexToKey(v).float.bits()),
        .bool => try part.set(@intFromBool(v == .bool_true)),
        // A packed struct's fields, and an enum (a packed struct field) by
        // its tag.
        .@"struct" => {
            if (sema.isUndef(v)) return;
            for (0..Type.fieldCount(ip, ty)) |i| try sema.valueBits(try sema.fieldValue(v, @intCast(i)), out, offset + Type.packedFieldBitOffset(ip, ty, i));
            return;
        },
        .@"enum" => {
            if (sema.isUndef(v)) return;
            return sema.valueBits(ip.indexToKey(v).enum_tag.int, out, offset);
        },
        // A packed union by its active field.
        .@"union" => {
            if (sema.isUndef(v)) return;
            return sema.valueBits(ip.indexToKey(v).un.val, out, offset);
        },
        .void => return,
        else => {
            if (sema.isUndef(v)) return; // An undefined element: zeros.
            part = try sema.bigValue(v);
            try part.truncate(&part, .unsigned, Type.intInfo(ip, ty).bits);
        },
    }
    try part.shiftLeft(&part, @intCast(offset));
    try out.bitOr(out, &part);
}

/// The value of type `ty` (see `bitCastBits`) whose bits are those of `bits`
/// from bit `offset`.
fn bitsValue(sema: *Sema, ty: Index, bits: std.math.big.int.Const, offset: u64) Allocator.Error!Index {
    const ip = sema.ip;
    var part = try BigInt.init(sema.arena);
    try part.shiftRight(&try bits.toManaged(sema.arena), @intCast(offset));
    switch (Type.class(ip, ty)) {
        .array => {
            const child = Type.childType(ip, ty);
            const eb = sema.bitCastBits(child).?;
            const elems = try sema.arena.alloc(Index, @intCast(ip.indexToKey(ty).array_type.len));
            for (elems, 0..) |*e, i| e.* = try sema.bitsValue(child, bits, offset + i * eb);
            return sema.intern(.{ .aggregate = .{ .ty = ty, .storage = .{ .elems = elems } } });
        },
        .vector => {
            const child = Type.childType(ip, ty);
            const eb = sema.bitCastBits(child).?;
            const elems = try sema.arena.alloc(Index, ip.indexToKey(ty).vector_type.len);
            for (elems, 0..) |*e, i| e.* = try sema.bitsValue(child, bits, offset + i * eb);
            return sema.intern(.{ .aggregate = .{ .ty = ty, .storage = .{ .elems = elems } } });
        },
        .float => {
            try part.truncate(&part, .unsigned, Type.floatBits(ip, ty));
            return sema.floatFromBits(ty, part.toConst().toInt(u128) catch unreachable);
        },
        .bool => return boolValue(part.toConst().limbs[0] & 1 != 0),
        .@"struct" => {
            const elems = try sema.arena.alloc(Index, Type.fieldCount(ip, ty));
            for (elems, 0..) |*e, i| e.* = try sema.bitsValue(Type.fieldType(ip, ty, i), bits, offset + Type.packedFieldBitOffset(ip, ty, i));
            return sema.intern(.{ .aggregate = .{ .ty = ty, .storage = .{ .elems = elems } } });
        },
        .@"enum" => return sema.intern(.{ .enum_tag = .{ .ty = ty, .int = try sema.bitsValue(ip.structInfo(ty).tag_type, bits, offset) } }),
        .@"union" => return sema.intern(.{ .un = .{ .ty = ty, .tag = try sema.unionFieldTagValue(ty, 0), .val = try sema.bitsValue(ip.structInfo(ty).field_types[0], bits, offset) } }),
        .void => return .void_value,
        else => {
            const info = Type.intInfo(ip, ty);
            try part.truncate(&part, info.signedness, info.bits);
            return sema.bigToValue(ty, part.toConst());
        },
    }
}

/// The value of float type `ty` whose bits are the low bits of `bits`.
fn floatFromBits(sema: *Sema, ty: Index, bits: u128) !Index {
    return sema.intern(.{ .float = .{ .ty = ty, .storage = switch (Type.floatBits(sema.ip, ty)) {
        16 => .{ .f16 = @bitCast(@as(u16, @truncate(bits))) },
        32 => .{ .f32 = @bitCast(@as(u32, @truncate(bits))) },
        64 => .{ .f64 = @bitCast(@as(u64, @truncate(bits))) },
        80 => .{ .f80 = @bitCast(@as(u80, @truncate(bits))) },
        128 => .{ .f128 = @bitCast(bits) },
        else => unreachable,
    } } });
}

fn analyzePtrCast(sema: *Sema, block: *Block, inst: Zir.Inst.Index, flags: Zir.Inst.FullPtrCastFlags) CompileError!Ref {
    const tag = sema.code.instructions.items(.tag)[@backingInt(inst)];
    const data = sema.code.instructions.items(.data)[@backingInt(inst)];
    const dest_ref: Zir.Inst.Ref, const operand_ref: Zir.Inst.Ref, const src = if (tag == .extended) blk: {
        const e = sema.code.extraData(Zir.Inst.BinNode, data.extended.operand).data;
        break :blk .{ e.lhs, e.rhs, block.nodeSrc(e.node) };
    } else blk: {
        const e = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
        break :blk .{ e.lhs, e.rhs, block.nodeSrc(data.pl_node.src_node) };
    };
    const dest_ty = try sema.resolveType(block, src, dest_ref);
    const operand = sema.resolveInst(operand_ref);
    const src_ty = sema.typeOf(operand);
    if (Type.class(sema.ip, dest_ty) != .pointer or Type.class(sema.ip, src_ty) != .pointer)
        return sema.failUnsupported(block, src, "pointer casts involving non-pointer types");
    const d = Type.ptrInfo(sema.ip, dest_ty);
    const s = Type.ptrInfo(sema.ip, src_ty);
    if (s.flags.is_const and !d.flags.is_const and !flags.const_cast) return sema.fail(block, src, "@ptrCast discards const qualifier", .{});
    const ip = sema.ip;
    if (s.flags.size == .slice and d.flags.size != .slice) {
        // The slice's pointer.
        const raw = try sema.slicePtr(block, operand);
        return sema.coercePtrTo(block, raw, dest_ty);
    }
    if (d.flags.size == .slice and s.flags.size != .slice) {
        // Only `*[N]T` provides a length.
        if (s.flags.size != .one or ip.indexToKey(s.child) != .array_type) return sema.fail(block, src, "cannot infer length of slice from '{f}'", .{sema.fmtType(src_ty)});
        const a = ip.indexToKey(s.child).array_type;
        try sema.resolveLayout(block, src, d.child);
        const bytes = a.len * Type.abiSize(ip, a.child);
        const dsize = Type.abiSize(ip, d.child);
        if (dsize == 0 or bytes % dsize != 0) return sema.fail(block, src, "type '{f}' does not divide exactly into destination elements", .{sema.fmtType(s.child)});
        const many = try sema.coercePtrTo(block, operand, try sema.elemValueType(dest_ty));
        return sema.makeSlice(block, dest_ty, many, .fromInterned(try sema.intValue(.usize_type, bytes / dsize)));
    }
    if (d.flags.size == .slice) {
        try sema.resolveLayout(block, src, d.child);
        try sema.resolveLayout(block, src, s.child);
        const ssize = Type.abiSize(ip, s.child);
        const dsize = Type.abiSize(ip, d.child);
        if (ssize == dsize) return sema.coercePtrTo(block, operand, dest_ty);
        if (dsize == 0) return sema.failUnsupported(block, src, "slice casts to zero-bit elements");
        // The length scales by the element sizes.
        const many = try sema.coercePtrTo(block, try sema.slicePtr(block, operand), try sema.elemValueType(dest_ty));
        const len = try sema.sliceLen(block, operand);
        if (sema.resolveValue(len)) |lv| {
            const bytes = ip.intValue(u64, lv).? * ssize;
            if (bytes % dsize != 0) return sema.fail(block, src, "slice length does not divide exactly into destination elements", .{});
            return sema.makeSlice(block, dest_ty, many, .fromInterned(try sema.intValue(.usize_type, bytes / dsize)));
        }
        try sema.requireRuntime(block, src);
        const bytes = try sema.addBinOp(block, .mul_wrap, len, .fromInterned(try sema.intValue(.usize_type, ssize)));
        const new_len = try sema.addBinOp(block, .div_trunc, bytes, .fromInterned(try sema.intValue(.usize_type, dsize)));
        if (block.want_safety and ssize % dsize != 0) {
            const rem = try sema.addBinOp(block, .rem, bytes, .fromInterned(try sema.intValue(.usize_type, dsize)));
            try sema.addSafetyCheck(block, try sema.addBinOp(block, .cmp_eq, rem, .fromInterned(.zero_usize)), .exact_division_remainder, .none, .none);
        }
        return sema.makeSlice(block, dest_ty, many, new_len);
    }
    return sema.coercePtrTo(block, operand, dest_ty);
}

// ---------------------------------------------------------------------------
// Inline assembly

fn zirAsm(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ext = sema.code.instructions.items(.data)[@backingInt(inst)].extended;
    const extra = sema.code.extraData(Zir.Inst.Asm, ext.operand);
    const small: Zir.Inst.Asm.Small = @bitCast(ext.small);
    const src = block.nodeSrc(extra.data.src_node);
    if (block.is_comptime) return sema.fail(block, src, "unable to evaluate comptime expression: inline assembly", .{});
    const gpa = sema.gpa;
    var result_ty: Index = .void_type;
    var operands: std.ArrayList(Ir.Asm.Operand) = .empty;
    defer operands.deinit(gpa);
    var i = extra.end;
    for (0..small.outputs_len) |k| {
        const o = sema.code.extraData(Zir.Inst.Asm.Output, i);
        i = o.end;
        const is_type = (extra.data.output_type_bits >> @intCast(k)) & 1 != 0;
        var operand: Ref = .none;
        if (is_type) {
            if (result_ty != .void_type) return sema.failUnsupported(block, src, "inline assembly with more than one result output");
            result_ty = try sema.resolveType(block, src, o.data.operand);
        } else operand = sema.resolveInst(o.data.operand);
        try operands.append(gpa, .{
            .name = try sema.getString(sema.zirString(o.data.name)),
            .constraint = try sema.getString(sema.zirString(o.data.constraint)),
            .operand = operand,
        });
    }
    for (0..small.inputs_len) |_| {
        const in = sema.code.extraData(Zir.Inst.Asm.Input, i);
        i = in.end;
        var operand = sema.resolveInst(in.data.operand);
        const ty = sema.typeOf(operand);
        if (ty == .comptime_int_type) operand = try sema.coerce(block, .usize_type, operand, src);
        if (Type.isComptimeOnly(sema.ip, sema.typeOf(operand))) return sema.fail(block, src, "inline assembly input of comptime-only type '{f}'", .{sema.fmtType(sema.typeOf(operand))});
        try operands.append(gpa, .{
            .name = try sema.getString(sema.zirString(in.data.name)),
            .constraint = try sema.getString(sema.zirString(in.data.constraint)),
            .operand = operand,
        });
    }
    // Clobbers need no handling: CodeGen keeps no values in registers
    // across instructions.
    const payload = try sema.addExtra(Ir.Asm{
        .source = if (ext.opcode == .asm_expr)
            try sema.getString(try sema.resolveConstString(block, src, sema.resolveInst(@fromBackingInt(@backingInt(extra.data.asm_source)))))
        else
            try sema.getString(sema.zirString(extra.data.asm_source)),
        .outputs_len = small.outputs_len,
        .inputs_len = small.inputs_len,
        .is_volatile = @intFromBool(small.is_volatile),
    });
    for (operands.items) |op| _ = try sema.addExtra(op);
    return sema.addInst(block, .{ .tag = .assembly, .data = .{ .ty_pl = .{ .ty = result_ty, .payload = payload } } });
}

// ---------------------------------------------------------------------------
// Functions and calls

fn zirParam(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!void {
    const tag = sema.code.instructions.items(.tag)[@backingInt(inst)];
    const data = sema.code.instructions.items(.data)[@backingInt(inst)];
    switch (tag) {
        .param, .param_comptime => {
            const extra = sema.code.extraData(Zir.Inst.Param, data.pl_tok.payload_index);
            const body = sema.code.bodySlice(extra.end, extra.data.type.body_len);
            const src = block.tokSrc(data.pl_tok.src_tok);
            const ty: Index = if (extra.data.type.is_generic) .generic_poison_type else blk: {
                // A function type in the parameter's type has its own parameters.
                const prev = sema.params;
                sema.params = .empty;
                defer sema.params = prev;
                const ref = try sema.resolveInlineBody(block, body, inst);
                break :blk try sema.analyzeAsType(block, src, ref);
            };
            try sema.params.append(sema.arena, .{ .ty = ty, .is_comptime = tag == .param_comptime, .name = extra.data.name });
        },
        .param_anytype, .param_anytype_comptime => {
            try sema.params.append(sema.arena, .{ .ty = .generic_poison_type, .is_comptime = tag == .param_anytype_comptime, .name = data.str_tok.start });
        },
        else => unreachable,
    }
    try sema.inst_map.put(sema.gpa, inst, .fromInterned(.generic_poison_type));
}

fn zirFunc(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ip = sema.ip;
    const tag = sema.code.instructions.items(.tag)[@backingInt(inst)];
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const src = block.nodeSrc(data.src_node);
    const fn_info = sema.code.getFnInfo(inst);
    // The return type and calling convention bodies may contain function
    // types with parameters of their own.
    const params = sema.params.items;
    sema.params = .empty;

    var cc: InternPool.CallingConvention = if (sema.owner_nav != .none and ip.getNav(sema.owner_nav).linkage == .@"export") .c else .auto;
    var body_len: u32 = 0;
    if (tag == .func_fancy) {
        const extra = sema.code.extraData(Zir.Inst.FuncFancy, data.payload_index);
        body_len = extra.data.body_len;
        if (extra.data.bits.is_var_args) return sema.failUnsupported(block, src, "variadic functions");
        var cc_ref: Ref = .none;
        if (extra.data.bits.has_cc_body) {
            const len = sema.code.extra[extra.end];
            cc_ref = try sema.resolveInlineBody(block, sema.code.bodySlice(extra.end + 1, len), inst);
        } else if (extra.data.bits.has_cc_ref) {
            cc_ref = sema.resolveInst(@fromBackingInt(sema.code.extra[extra.end]));
        }
        if (cc_ref != .none) {
            const v = try sema.resolveConstValue(block, src, cc_ref, "calling convention must be comptime-known");
            cc = switch (ip.indexToKey(v)) {
                .calling_convention => |c| c,
                else => return sema.fail(block, src, "expected calling convention, found '{f}'", .{sema.fmtType(ip.typeOf(v))}),
            };
        }
    } else {
        body_len = sema.code.extraData(Zir.Inst.Func, data.payload_index).data.body_len;
    }

    var ret_ty: Index = if (fn_info.ret_ty_body.len != 0) blk: {
        if (fn_info.ret_ty_is_generic) break :blk .generic_poison_type;
        const ref = try sema.resolveInlineBody(block, fn_info.ret_ty_body, inst);
        break :blk try sema.analyzeAsType(block, src, ref);
    } else try sema.resolveType(block, src, fn_info.ret_ty_ref);
    // A generic return type stays generic_poison: instantiation adds the
    // inferred error set (see `calleeRetTy`).
    if (fn_info.inferred_error_set and ret_ty != .generic_poison_type) {
        ret_ty = try sema.intern(.{ .error_union_type = .{ .error_set_type = .adhoc_inferred_error_set_type, .payload_type = ret_ty } });
    }

    var is_generic = ret_ty == .generic_poison_type;
    var comptime_bits: u32 = 0;
    const param_types = try sema.arena.alloc(Index, params.len);
    for (params, param_types, 0..) |p, *t, k| {
        t.* = p.ty;
        // Parameters of comptime-only types are implicitly comptime.
        const is_comptime = p.is_comptime or (p.ty != .generic_poison_type and Type.isComptimeOnly(ip, p.ty));
        if (is_comptime) {
            // Like upstream, only the first 32 parameters can be comptime.
            if (k >= 32) return sema.fail(block, src, "zap does not support comptime parameters after the 32nd", .{});
            comptime_bits |= @as(u32, 1) << @intCast(k);
        }
        if (is_comptime or p.ty == .generic_poison_type) is_generic = true;
    }
    const fn_ty = try sema.intern(.{ .func_type = .{
        .param_types = param_types,
        .return_type = ret_ty,
        .cc = cc,
        .comptime_bits = comptime_bits,
        .is_generic = is_generic,
    } });
    if (body_len == 0) return .fromInterned(fn_ty);
    if (sema.owner_nav == .none) return sema.fail(block, src, "function declared outside of a declaration", .{});
    return .fromInterned(try sema.intern(.{ .func = .{ .owner_nav = sema.owner_nav, .ty = fn_ty, .zir_inst = inst } }));
}

const CallArgs = union(enum) {
    /// Argument bodies of a ZIR `call`/`field_call`, after `first`.
    zir: struct { call_inst: Zir.Inst.Index, extra_end: usize, args_len: u32 },
    /// Already analyzed arguments (`@call`), after `first`.
    resolved: []const Ref,

    fn len(args: CallArgs) usize {
        return switch (args) {
            .zir => |z| z.args_len,
            .resolved => |r| r.len,
        };
    }
};

/// `@call(modifier, callee, args)`.
fn zirBuiltinCall(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ip = sema.ip;
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const src = block.nodeSrc(data.src_node);
    const extra = sema.code.extraData(Zir.Inst.BuiltinCall, data.payload_index).data;
    const modifier_ty = try sema.stdLangType(block, src, "CallModifier");
    const modifier_val = try sema.resolveConstValue(block, src, try sema.coerce(block, modifier_ty, sema.resolveInst(extra.modifier), src), "call modifier must be comptime-known");
    const modifier: std.lang.CallModifier = @fromBackingInt(@intCast(ip.intValue(u64, ip.indexToKey(modifier_val).enum_tag.int).?));
    const callee = sema.resolveInst(extra.callee);
    const args_tuple = sema.resolveInst(extra.args);
    const args_ty = sema.typeOf(args_tuple);
    if (ip.indexToKey(args_ty) != .tuple_type) return sema.fail(block, src, "expected a tuple, found '{f}'", .{sema.fmtType(args_ty)});
    const n = ip.indexToKey(args_ty).tuple_type.types.len;
    const args = try sema.arena.alloc(Ref, n);
    for (args, 0..) |*a, k| a.* = try sema.tupleField(block, args_tuple, @intCast(k));
    return sema.analyzeCall(block, src, callee, .none, .{ .resolved = args }, modifier);
}

fn zirCall(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const src = block.nodeSrc(data.src_node);
    const extra = sema.code.extraData(Zir.Inst.Call, data.payload_index);
    const callee = sema.resolveInst(extra.data.callee);
    const modifier: std.lang.CallModifier = @fromBackingInt(@intCast(extra.data.flags.packed_modifier));
    return sema.analyzeCall(block, src, callee, .none, .{ .zir = .{ .call_inst = inst, .extra_end = extra.end, .args_len = extra.data.flags.args_len } }, modifier);
}

fn zirFieldCall(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ip = sema.ip;
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const src = block.nodeSrc(data.src_node);
    const extra = sema.code.extraData(Zir.Inst.FieldCall, data.payload_index);
    const name = sema.zirString(extra.data.field_name_start);
    const obj = sema.resolveInst(extra.data.obj_ptr);
    const modifier: std.lang.CallModifier = @fromBackingInt(@intCast(extra.data.flags.packed_modifier));
    const args: CallArgs = .{ .zir = .{ .call_inst = inst, .extra_end = extra.end, .args_len = extra.data.flags.args_len } };
    const obj_ty = sema.typeOf(obj);
    if (obj_ty == .type_type) {
        const callee = try sema.fieldVal(block, src, obj, name);
        return sema.analyzeCall(block, src, callee, .none, args, modifier);
    }
    // `obj` points to the object; find the container of the method.
    if (Type.class(ip, obj_ty) != .pointer) return sema.fail(block, src, "type '{f}' has no member named '{s}'", .{ sema.fmtType(obj_ty), name });
    var self_ptr = obj;
    var container = Type.ptrInfo(ip, obj_ty).child;
    if (container == .type_type) {
        const callee = try sema.fieldVal(block, src, try sema.analyzeLoad(block, src, obj), name);
        return sema.analyzeCall(block, src, callee, .none, args, modifier);
    }
    if (Type.class(ip, container) == .pointer and Type.ptrInfo(ip, container).flags.size == .one) {
        self_ptr = try sema.analyzeLoad(block, src, obj);
        container = Type.ptrInfo(ip, container).child;
    }
    if (ip.indexToKey(container) == .struct_type) {
        try sema.resolveStructFields(block, src, container);
        if (ip.structInfo(container).fieldIndex(ip, name) != null) {
            const callee = try sema.fieldVal(block, src, obj, name);
            return sema.analyzeCall(block, src, callee, .none, args, modifier);
        }
    }
    const nav = (try sema.lookupInType(container, name)) orelse
        return sema.fail(block, src, "no field or member function named '{s}' in '{f}'", .{ name, sema.fmtType(container) });
    const callee = try sema.navVal(block, src, nav);
    const callee_ty = sema.typeOf(callee);
    if (Type.class(ip, callee_ty) != .@"fn") return sema.fail(block, src, "no field or member function named '{s}' in '{f}'", .{ name, sema.fmtType(container) });
    const fn_ty = ip.indexToKey(callee_ty).func_type;
    if (fn_ty.param_types.len == 0) return sema.fail(block, src, "member function '{s}' has no parameters", .{name});
    const first_ty = fn_ty.param_types[0];
    const self: Ref = if (first_ty != .generic_poison_type and Type.class(ip, first_ty) == .pointer) self_ptr else try sema.analyzeLoad(block, src, self_ptr);
    return sema.analyzeCall(block, src, callee, self, args, modifier);
}

fn analyzeCall(
    sema: *Sema,
    block: *Block,
    src: Src,
    callee: Ref,
    first_arg: Ref,
    call_args_in: CallArgs,
    modifier: std.lang.CallModifier,
) CompileError!Ref {
    const ip = sema.ip;
    // The callee is a function, or a pointer to one: comptime-known to be a
    // declared function (a direct call) or not (an indirect call).
    const callee_ty = sema.typeOf(callee);
    var func: Index = .none;
    const fn_ty_index: Index = switch (Type.class(ip, callee_ty)) {
        .@"fn" => blk: {
            const v = try sema.resolveConstValue(block, src, callee, "function value must be comptime-known");
            if (ip.indexToKey(v) != .func) return sema.fail(block, src, "type '{f}' not a function", .{sema.fmtType(callee_ty)});
            func = v;
            break :blk callee_ty;
        },
        .pointer => blk: {
            const p = Type.ptrInfo(ip, callee_ty);
            if (p.flags.size != .one or Type.class(ip, p.child) != .@"fn") return sema.fail(block, src, "type '{f}' not a function", .{sema.fmtType(callee_ty)});
            if (sema.resolveValue(callee)) |v| if (ip.indexToKey(v) == .ptr) {
                const k = ip.indexToKey(v).ptr;
                if (k.base == .nav and k.byte_offset == 0) {
                    try sema.ensureNavVal(block, src, k.base.nav);
                    const nv = ip.getNav(k.base.nav).val;
                    if (ip.indexToKey(nv) == .func) func = nv;
                }
            };
            break :blk p.child;
        },
        else => return sema.fail(block, src, "type '{f}' not a function", .{sema.fmtType(callee_ty)}),
    };
    const fn_ty = ip.indexToKey(fn_ty_index).func_type;
    const total_args = call_args_in.len() + @intFromBool(first_arg != .none);
    if (total_args != fn_ty.param_types.len) {
        return sema.fail(block, src, "expected {d} argument(s), found {d}", .{ fn_ty.param_types.len, total_args });
    }
    switch (modifier) {
        .auto, .compile_time, .always_inline, .never_inline, .never_tail, .no_suspend => {},
        else => return sema.fail(block, src, "zap does not support call modifier '{s}' yet", .{@tagName(modifier)}),
    }

    // Arguments are analyzed in the caller, with the call instruction
    // standing for the parameter type.
    const args = try sema.arena.alloc(Ref, total_args);
    var arg_i: usize = 0;
    if (first_arg != .none) {
        args[0] = if (fn_ty.param_types[0] == .generic_poison_type) first_arg else try sema.coerce(block, fn_ty.param_types[0], first_arg, src);
        arg_i = 1;
    }
    switch (call_args_in) {
        .zir => |zir_args| {
            var arg_start: u32 = zir_args.args_len;
            for (0..zir_args.args_len) |k| {
                const arg_end = sema.code.extra[zir_args.extra_end + k];
                const body = sema.code.bodySlice(zir_args.extra_end + arg_start, arg_end - arg_start);
                arg_start = arg_end;
                // A generic parameter's type can depend on the arguments before it;
                // it is the argument's result type, as upstream.
                const param_ty = if (fn_ty.param_types[arg_i] == .generic_poison_type and func != .none)
                    try sema.genericParamType(block, src, func, args[0..arg_i])
                else
                    fn_ty.param_types[arg_i];
                try sema.inst_map.put(sema.gpa, zir_args.call_inst, .fromInterned(param_ty));
                const arg = try sema.resolveInlineBody(block, body, zir_args.call_inst);
                args[arg_i] = if (param_ty == .generic_poison_type) arg else try sema.coerce(block, param_ty, arg, src);
                arg_i += 1;
            }
        },
        .resolved => |resolved| for (resolved) |arg| {
            const param_ty = if (fn_ty.param_types[arg_i] == .generic_poison_type and func != .none)
                try sema.genericParamType(block, src, func, args[0..arg_i])
            else
                fn_ty.param_types[arg_i];
            args[arg_i] = if (param_ty == .generic_poison_type) arg else try sema.coerce(block, param_ty, arg, src);
            arg_i += 1;
        },
    }

    const ret_ty = fn_ty.return_type;
    const comptime_call = block.is_comptime or modifier == .compile_time or
        (ret_ty != .generic_poison_type and Type.isComptimeOnly(ip, ret_ty));
    if (func == .none) {
        if (comptime_call) return sema.fail(block, src, "unable to resolve comptime value: function pointer is not comptime-known", .{});
        if (fn_ty.is_generic) return sema.fail(block, src, "cannot call a generic function through a pointer", .{});
        try sema.requireRuntime(block, src);
        for (fn_ty.param_types) |pt| try sema.resolveLayout(block, src, pt);
        try sema.resolveLayout(block, src, ret_ty);
        const payload = try sema.addExtra(Ir.Call{ .ret_ty = ret_ty, .args_len = @intCast(args.len) });
        try sema.ir_extra.appendSlice(sema.gpa, @ptrCast(args));
        return sema.addInst(block, .{ .tag = .call, .data = .{ .pl_op = .{ .operand = callee, .payload = payload } } });
    }
    if (comptime_call) {
        const vals = try sema.arena.alloc(Index, args.len);
        for (args, vals) |a, *v| v.* = try sema.resolveConstValue(block, src, a, "argument to function being called at comptime must be comptime-known");
        const n = sema.zcu.errors.items.len;
        return .fromInterned(sema.callComptime(block, src, func, vals) catch |err| return sema.noteCallSite(block, src, n, err, "called at comptime from here"));
    }

    if (fn_ty.cc == .@"inline" or modifier == .always_inline) {
        const n = sema.zcu.errors.items.len;
        return sema.inlineCall(block, src, func, args) catch |err| return sema.noteCallSite(block, src, n, err, "called inline here");
    }

    var callee_func = func;
    var call_args = args;
    if (fn_ty.is_generic) {
        const inst = try sema.instantiate(block, src, func, args);
        callee_func = inst.func;
        call_args = inst.runtime_args;
        if (Type.isComptimeOnly(ip, ip.indexToKey(ip.typeOf(callee_func)).func_type.return_type)) {
            const vals = try sema.arena.alloc(Index, args.len);
            for (args, vals) |a, *v| v.* = try sema.resolveConstValue(block, src, a, "argument to function being called at comptime must be comptime-known");
            const n = sema.zcu.errors.items.len;
            return .fromInterned(sema.callComptime(block, src, func, vals) catch |err| return sema.noteCallSite(block, src, n, err, "called at comptime from here"));
        }
    }
    try sema.requireRuntime(block, src);
    const callee_fn_ty = ip.indexToKey(ip.typeOf(callee_func)).func_type;
    for (call_args, callee_fn_ty.param_types) |a, pt| {
        if (Type.isComptimeOnly(ip, pt)) return sema.fail(block, src, "parameter of comptime-only type '{f}' must be declared comptime", .{sema.fmtType(pt)});
        _ = a;
    }
    if (callee_fn_ty.cc == .naked) return sema.fail(block, src, "unable to call function with naked calling convention", .{});
    try sema.declareDependency(.{ .nav_val = ip.indexToKey(callee_func).func.owner_nav });
    try sema.zcu.queueFunc(callee_func);
    for (callee_fn_ty.param_types) |pt| try sema.resolveLayout(block, src, pt);
    try sema.resolveLayout(block, src, callee_fn_ty.return_type);
    var call_ret_ty = callee_fn_ty.return_type;
    if (ip.indexToKey(call_ret_ty) == .error_union_type) {
        const eu = ip.indexToKey(call_ret_ty).error_union_type;
        if (eu.error_set_type == .adhoc_inferred_error_set_type) {
            const ies = try sema.intern(.{ .inferred_error_set_type = callee_func });
            call_ret_ty = try sema.intern(.{ .error_union_type = .{ .error_set_type = ies, .payload_type = eu.payload_type } });
        }
    }
    const payload = try sema.addExtra(Ir.Call{ .ret_ty = call_ret_ty, .args_len = @intCast(call_args.len) });
    try sema.ir_extra.appendSlice(sema.gpa, @ptrCast(call_args));
    return sema.addInst(block, .{ .tag = .call, .data = .{ .pl_op = .{ .operand = .fromInterned(callee_func), .payload = payload } } });
}

/// State saved while analyzing another function's ZIR in this Sema.
const CalleeScope = struct {
    code: *const Zir,
    file: u32,
    inst_map: std.AutoHashMapUnmanaged(Zir.Inst.Index, Ref),

    fn enter(sema: *Sema, func: Index) CalleeScope {
        const nav = sema.ip.getNav(sema.ip.indexToKey(func).func.owner_nav);
        const saved: CalleeScope = .{ .code = sema.code, .file = sema.file, .inst_map = sema.inst_map };
        sema.code = &sema.zcu.file(nav.file).zir;
        sema.file = nav.file;
        sema.inst_map = .empty;
        return saved;
    }

    fn leave(saved: CalleeScope, sema: *Sema) void {
        sema.inst_map.deinit(sema.gpa);
        sema.code = saved.code;
        sema.file = saved.file;
        sema.inst_map = saved.inst_map;
    }
};

fn calleeBlock(sema: *Sema, parent: *Block, func: Index) Block {
    const nav = sema.ip.getNav(sema.ip.indexToKey(func).func.owner_nav);
    const decl = sema.code.getDeclaration(nav.zir_inst);
    return .{
        .parent = null,
        .sema = sema,
        .namespace = nav.namespace,
        .is_comptime = true,
        .src_base = decl.src_node,
        .want_safety = parent.want_safety,
    };
}

/// Maps the parameters of `func` (whose ZIR is current) to `args`, evaluating
/// generic parameter types. `args` are coerced in `caller`. Runtime-known
/// arguments map to undefined values of their type.
fn mapCalleeParams(sema: *Sema, callee_block: *Block, caller: *Block, src: Src, func: Index, args: []Ref) CompileError!void {
    const ip = sema.ip;
    const f = ip.indexToKey(func).func;
    const fn_ty = ip.indexToKey(f.ty).func_type;
    const fn_info = sema.code.getFnInfo(f.zir_inst);
    var i: usize = 0;
    for (fn_info.param_body) |inst| {
        const tag = sema.code.instructions.items(.tag)[@backingInt(inst)];
        const data = sema.code.instructions.items(.data)[@backingInt(inst)];
        switch (tag) {
            .param, .param_comptime => if (fn_ty.param_types[i] == .generic_poison_type) {
                const extra = sema.code.extraData(Zir.Inst.Param, data.pl_tok.payload_index);
                const body = sema.code.bodySlice(extra.end, extra.data.type.body_len);
                const ty = try sema.analyzeAsType(callee_block, src, try sema.resolveInlineBody(callee_block, body, inst));
                args[i] = try sema.coerce(caller, ty, args[i], src);
            },
            .param_anytype, .param_anytype_comptime => {},
            else => continue,
        }
        const val: Index = sema.resolveValue(args[i]) orelse try sema.undefValue(sema.typeOf(args[i]));
        try sema.inst_map.put(sema.gpa, inst, .fromInterned(val));
        i += 1;
    }
}

/// A runtime call of inline function `func`: its body analyzed in the
/// caller with its parameters bound to `args`, as upstream. The result is
/// comptime-known when the body's only exit returns a comptime-known value.
fn inlineCall(sema: *Sema, caller: *Block, src: Src, func: Index, args: []Ref) CompileError!Ref {
    const ip = sema.ip;
    const gpa = sema.gpa;
    if (sema.inline_depth >= 1000) return sema.fail(caller, src, "inline call depth exceeded", .{});
    sema.inline_depth += 1;
    defer sema.inline_depth -= 1;
    const f = ip.indexToKey(func).func;
    const fn_ty = ip.indexToKey(f.ty).func_type;
    const saved = CalleeScope.enter(sema, func);
    defer saved.leave(sema);
    // Parameter and return types evaluate at comptime, the body at runtime.
    var ct_block = sema.calleeBlock(caller, func);
    defer ct_block.instructions.deinit(gpa);
    const fn_info = sema.code.getFnInfo(f.zir_inst);
    const comptime_args = try sema.arena.alloc(Index, args.len);
    var i: usize = 0;
    for (fn_info.param_body) |inst| {
        const tag = sema.code.instructions.items(.tag)[@backingInt(inst)];
        switch (tag) {
            .param, .param_comptime => if (fn_ty.param_types[i] == .generic_poison_type) {
                const data = sema.code.instructions.items(.data)[@backingInt(inst)];
                const extra = sema.code.extraData(Zir.Inst.Param, data.pl_tok.payload_index);
                const body = sema.code.bodySlice(extra.end, extra.data.type.body_len);
                const ty = try sema.analyzeAsType(&ct_block, src, try sema.resolveInlineBody(&ct_block, body, inst));
                args[i] = try sema.coerce(caller, ty, args[i], src);
            },
            .param_anytype, .param_anytype_comptime => {},
            else => continue,
        }
        comptime_args[i] = sema.resolveValue(args[i]) orelse .none;
        const is_comptime = tag == .param_comptime or tag == .param_anytype_comptime or Type.isComptimeOnly(ip, sema.typeOf(args[i]));
        if (is_comptime and comptime_args[i] == .none) return sema.fail(caller, src, "unable to resolve comptime value: argument to comptime parameter must be comptime-known", .{});
        try sema.inst_map.put(gpa, inst, args[i]);
        i += 1;
    }
    // With an inferred error set, the result's error set is what the
    // returns produce (see `analyzeRet`).
    const ret_ty = try sema.calleeRetTy(&ct_block, src, func);
    try sema.declareDependency(.{ .func_body = func });

    var merges: Block.Merges = .{ .block_inst = try sema.reserveInst() };
    defer {
        merges.results.deinit(gpa);
        merges.brs.deinit(gpa);
    }
    var inlining: Block.Inlining = .{ .func = func, .ret_ty = ret_ty, .args = comptime_args, .merges = &merges };
    var child: Block = .{
        .parent = null,
        .sema = sema,
        .namespace = ct_block.namespace,
        .is_comptime = false,
        .inlining = &inlining,
        .src_base = ct_block.src_base,
        .want_safety = caller.want_safety,
    };
    defer child.instructions.deinit(gpa);
    try sema.analyzeBodyInner(&child, fn_info.body);
    return sema.resolveBlock(caller, src, &child, &merges);
}

/// The type of the parameter of generic `func` after `prior` arguments,
/// evaluated with them; `generic_poison_type` for an `anytype` parameter.
fn genericParamType(sema: *Sema, caller: *Block, src: Src, func: Index, prior: []const Ref) CompileError!Index {
    const saved = CalleeScope.enter(sema, func);
    defer saved.leave(sema);
    var callee_block = sema.calleeBlock(caller, func);
    defer callee_block.instructions.deinit(sema.gpa);
    const fn_info = sema.code.getFnInfo(sema.ip.indexToKey(func).func.zir_inst);
    var i: usize = 0;
    for (fn_info.param_body) |inst| {
        const tag = sema.code.instructions.items(.tag)[@backingInt(inst)];
        switch (tag) {
            .param, .param_comptime => if (i == prior.len) {
                const data = sema.code.instructions.items(.data)[@backingInt(inst)];
                const extra = sema.code.extraData(Zir.Inst.Param, data.pl_tok.payload_index);
                const body = sema.code.bodySlice(extra.end, extra.data.type.body_len);
                return sema.analyzeAsType(&callee_block, src, try sema.resolveInlineBody(&callee_block, body, inst));
            },
            .param_anytype, .param_anytype_comptime => if (i == prior.len) return .generic_poison_type,
            else => continue,
        }
        const val: Index = sema.resolveValue(prior[i]) orelse try sema.undefValue(sema.typeOf(prior[i]));
        try sema.inst_map.put(sema.gpa, inst, .fromInterned(val));
        i += 1;
    }
    unreachable;
}

fn calleeRetTy(sema: *Sema, callee_block: *Block, src: Src, func: Index) CompileError!Index {
    const ip = sema.ip;
    const f = ip.indexToKey(func).func;
    const ret = ip.indexToKey(f.ty).func_type.return_type;
    if (ret != .generic_poison_type) return ret;
    const fn_info = sema.code.getFnInfo(f.zir_inst);
    var ty = if (fn_info.ret_ty_body.len != 0)
        try sema.analyzeAsType(callee_block, src, try sema.resolveInlineBody(callee_block, fn_info.ret_ty_body, f.zir_inst))
    else
        try sema.resolveType(callee_block, src, fn_info.ret_ty_ref);
    if (fn_info.inferred_error_set) {
        ty = try sema.intern(.{ .error_union_type = .{ .error_set_type = .adhoc_inferred_error_set_type, .payload_type = ty } });
    }
    return ty;
}

/// The one entry point for comptime calls. Memoized by the callee and the
/// stable hashes of the arguments.
fn callComptime(sema: *Sema, caller: *Block, src: Src, func: Index, args: []const Index) CompileError!Index {
    const ip = sema.ip;
    var hasher: InternPool.Hasher = .init("comptime call");
    hasher.int(InternPool.Hash, ip.stableHash(func));
    var memoizable = true;
    for (args) |a| {
        hasher.int(InternPool.Hash, ip.stableHash(a));
        if (sema.refersToComptimeAlloc(a)) memoizable = false;
    }
    const key = hasher.final();
    try sema.declareDependency(.{ .func_body = func });
    if (memoizable) if (sema.zcu.comptime_memo.get(key)) |result| return result;

    const saved = CalleeScope.enter(sema, func);
    defer saved.leave(sema);
    var callee_block = sema.calleeBlock(caller, func);
    defer callee_block.instructions.deinit(sema.gpa);
    const arg_refs = try sema.arena.alloc(Ref, args.len);
    for (args, arg_refs) |a, *r| r.* = .fromInterned(a);
    try sema.mapCalleeParams(&callee_block, caller, src, func, arg_refs);
    var inlining: Block.Inlining = .{ .func = func, .ret_ty = try sema.calleeRetTy(&callee_block, src, func), .args = args };
    callee_block.inlining = &inlining;
    const fn_info = sema.code.getFnInfo(ip.indexToKey(func).func.zir_inst);
    sema.analyzeBodyInner(&callee_block, fn_info.body) catch |err| switch (err) {
        error.ComptimeReturn => {},
        else => return err,
    };
    const result = try sema.resolveConstValue(&callee_block, src, inlining.result, "comptime call must return a comptime-known value");
    if (memoizable and !sema.refersToComptimeAlloc(result)) try sema.zcu.comptime_memo.put(sema.gpa, key, result);
    return result;
}

fn refersToComptimeAlloc(sema: *Sema, val: Index) bool {
    return switch (sema.ip.indexToKey(val)) {
        .ptr => (sema.comptimePtrRoot(val) catch return true) == .comptime_alloc,
        .slice => |s| sema.refersToComptimeAlloc(s.ptr),
        .aggregate => |a| switch (a.storage) {
            .elems => |elems| for (elems) |e| {
                if (sema.refersToComptimeAlloc(e)) break true;
            } else false,
            .repeated_elem => |e| sema.refersToComptimeAlloc(e),
            .bytes => false,
        },
        .opt => |o| o.val != .none and sema.refersToComptimeAlloc(o.val),
        else => false,
    };
}

const Instance = struct { func: Index, runtime_args: []Ref };

/// Instantiates generic function `func` for `args`.
fn instantiate(sema: *Sema, caller: *Block, src: Src, func: Index, args: []Ref) CompileError!Instance {
    const ip = sema.ip;
    const generic = ip.indexToKey(func).func;
    const generic_ty = ip.indexToKey(generic.ty).func_type;
    const comptime_args = try sema.arena.alloc(Index, args.len);
    var runtime_types: std.ArrayList(Index) = .empty;
    var runtime_args: std.ArrayList(Ref) = .empty;
    const ret_ty = blk: {
        const saved = CalleeScope.enter(sema, func);
        defer saved.leave(sema);
        var callee_block = sema.calleeBlock(caller, func);
        defer callee_block.instructions.deinit(sema.gpa);
        try sema.mapCalleeParams(&callee_block, caller, src, func, args);
        break :blk try sema.calleeRetTy(&callee_block, src, func);
    };
    for (args, comptime_args, 0..) |a, *ca, k| {
        // An `anytype` argument of a comptime-only type is comptime.
        if ((k < 32 and (generic_ty.comptime_bits >> @intCast(k)) & 1 != 0) or Type.isComptimeOnly(ip, sema.typeOf(a))) {
            ca.* = try sema.resolveConstValue(caller, src, a, "argument to comptime parameter must be comptime-known");
        } else {
            ca.* = .none;
            try runtime_types.append(sema.arena, sema.typeOf(a));
            try runtime_args.append(sema.arena, a);
        }
    }
    const fn_ty = try sema.intern(.{ .func_type = .{
        .param_types = runtime_types.items,
        .return_type = ret_ty,
        .cc = generic_ty.cc,
    } });
    const instance = try sema.intern(.{ .func = .{
        .owner_nav = generic.owner_nav,
        .ty = fn_ty,
        .zir_inst = generic.zir_inst,
        .generic_owner = func,
        .comptime_args = comptime_args,
    } });
    return .{ .func = instance, .runtime_args = runtime_args.items };
}

// ---------------------------------------------------------------------------
// Vectors
//
// Vector operations are scalarized here: each element is extracted (folded
// when comptime-known, else `array_elem_val`), the scalar operation is
// analyzed with its usual checks, and the results are reassembled with
// `aggregate_init`. A scalarized lowering is what Debug needs; CodeGen sees
// vectors only as values in memory.

fn vectorType(sema: *Sema, len: u32, child: Index) !Index {
    return sema.intern(.{ .vector_type = .{ .len = len, .child = child } });
}

/// The element type of the vector `ty` points to if it is a zero-bit
/// integer, whose only value needs no load.
fn zeroBitVectorElemPtr(sema: *Sema, ty: Index) ?Index {
    const ip = sema.ip;
    if (Type.class(ip, ty) != .pointer) return null;
    const child = Type.ptrInfo(ip, ty).child;
    if (ip.indexToKey(child) != .vector_type) return null;
    const elem = ip.indexToKey(child).vector_type.child;
    return if (Type.isInt(ip, elem) and Type.intInfo(ip, elem).bits == 0) elem else null;
}

fn isBoolVectorPtr(sema: *Sema, ty: Index) bool {
    const ip = sema.ip;
    if (Type.class(ip, ty) != .pointer) return false;
    const child = Type.ptrInfo(ip, ty).child;
    return ip.indexToKey(child) == .vector_type and ip.indexToKey(child).vector_type.child == .bool_type;
}

fn vectorLen(sema: *Sema, ty: Index) ?u32 {
    return switch (sema.ip.indexToKey(ty)) {
        .vector_type => |v| v.len,
        else => null,
    };
}

/// An undefined `ty`, or its only value if it has one (as upstream, an
/// undefined `u0` is 0).
fn undefElem(sema: *Sema, ty: Index) !Index {
    if (Type.isInt(sema.ip, ty) and Type.intInfo(sema.ip, ty).bits == 0) return sema.intValue(ty, 0);
    return sema.undefValue(ty);
}

/// Element `i` of vector or array `v`.
fn vectorElem(sema: *Sema, block: *Block, v: Ref, i: u32) CompileError!Ref {
    const elem_ty = Type.childType(sema.ip, sema.typeOf(v));
    if (Type.isInt(sema.ip, elem_ty) and Type.intInfo(sema.ip, elem_ty).bits == 0) return .fromInterned(try sema.intValue(elem_ty, 0));
    if (sema.resolveValue(v)) |val| return .fromInterned(try sema.elemValue(val, i));
    return sema.addBinOp(block, .array_elem_val, v, .fromInterned(try sema.intValue(.usize_type, i)));
}

/// Applies `op.call(sema, block, src, scalars)` to each element of the
/// vector `operands` (non-vector operands are passed unchanged) and builds
/// a vector of type `result_ty`, or of the results' type if `.none`.
fn vectorMap(sema: *Sema, block: *Block, src: Src, len: u32, result_ty: Index, operands: []const Ref, op: anytype) CompileError!Ref {
    const results = try sema.arena.alloc(Ref, len);
    const scalars = try sema.arena.alloc(Ref, operands.len);
    for (results, 0..) |*r, i| {
        for (operands, scalars) |o, *sc| sc.* = if (sema.vectorLen(sema.typeOf(o)) != null) try sema.vectorElem(block, o, @intCast(i)) else o;
        r.* = try op.call(sema, block, src, scalars);
    }
    const ty = if (result_ty != .none) result_ty else if (len == 0)
        return sema.failUnsupported(block, src, "this operation on zero-length vectors")
    else
        try sema.vectorType(len, sema.typeOf(results[0]));
    return sema.aggregate(block, src, ty, results);
}

const VectorArith = struct {
    tag: Zir.Inst.Tag,
    fn call(op: VectorArith, sema: *Sema, block: *Block, src: Src, s: []const Ref) CompileError!Ref {
        return sema.analyzeArithmetic(block, src, op.tag, s[0], s[1]);
    }
};

const VectorCmp = struct {
    op: std.math.CompareOperator,
    fn call(op: VectorCmp, sema: *Sema, block: *Block, src: Src, s: []const Ref) CompileError!Ref {
        return sema.analyzeCmp(block, src, op.op, s[0], s[1]);
    }
};

/// A unary operation `f(sema, block, src, operand)`.
const VectorUnary = struct {
    f: *const fn (*Sema, *Block, Src, Ref) CompileError!Ref,
    fn call(op: VectorUnary, sema: *Sema, block: *Block, src: Src, s: []const Ref) CompileError!Ref {
        return op.f(sema, block, src, s[0]);
    }
};

/// A cast `f(sema, block, src, dest_ty, operand)` to the element type.
const VectorCast = struct {
    f: *const fn (*Sema, *Block, Src, Index, Ref) CompileError!Ref,
    elem_ty: Index,
    fn call(op: VectorCast, sema: *Sema, block: *Block, src: Src, s: []const Ref) CompileError!Ref {
        return op.f(sema, block, src, op.elem_ty, s[0]);
    }
};

/// `f(operand)` element by element if `operand` is a vector.
fn vectorUnary(sema: *Sema, block: *Block, src: Src, operand: Ref, f: *const fn (*Sema, *Block, Src, Ref) CompileError!Ref) CompileError!?Ref {
    const len = sema.vectorLen(sema.typeOf(operand)) orelse return null;
    return try sema.vectorMap(block, src, len, .none, &.{operand}, VectorUnary{ .f = f });
}

/// The cast `f` to `dest_ty` element by element if either type is a vector.
fn vectorCast(sema: *Sema, block: *Block, src: Src, dest_ty: Index, operand: Ref, f: *const fn (*Sema, *Block, Src, Index, Ref) CompileError!Ref) CompileError!?Ref {
    const d_len = sema.vectorLen(dest_ty);
    const s_len = sema.vectorLen(sema.typeOf(operand));
    if (d_len == null and s_len == null) return null;
    if (d_len == null or s_len == null) return sema.fail(block, src, "expected vector of length {d}, found '{f}'", .{ d_len orelse s_len.?, sema.fmtType(if (d_len == null) dest_ty else sema.typeOf(operand)) });
    if (d_len.? != s_len.?) return sema.fail(block, src, "vector length mismatch: {d} and {d}", .{ d_len.?, s_len.? });
    return try sema.vectorMap(block, src, d_len.?, dest_ty, &.{operand}, VectorCast{ .f = f, .elem_ty = Type.childType(sema.ip, dest_ty) });
}

fn zirReduce(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Bin, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    const op_val = try sema.resolveConstValue(block, src, sema.resolveInst(extra.lhs), "@reduce operation must be comptime-known");
    const op = sema.enumTagName(op_val).?;
    const operand = sema.resolveInst(extra.rhs);
    const ty = sema.typeOf(operand);
    const len = sema.vectorLen(ty) orelse return sema.fail(block, src, "expected vector, found '{f}'", .{sema.fmtType(ty)});
    if (len == 0) return sema.fail(block, src, "@reduce operation requires a vector with nonzero length", .{});
    const elem_ty = Type.childType(sema.ip, ty);
    const is_float = Type.class(sema.ip, elem_ty) == .float;
    const tag: Zir.Inst.Tag = if (std.mem.eql(u8, op, "And"))
        .bit_and
    else if (std.mem.eql(u8, op, "Or"))
        .bit_or
    else if (std.mem.eql(u8, op, "Xor"))
        .xor
    else if (std.mem.eql(u8, op, "Min"))
        .min
    else if (std.mem.eql(u8, op, "Max"))
        .max
    else if (std.mem.eql(u8, op, "Add"))
        (if (is_float) .add else .addwrap)
    else if (std.mem.eql(u8, op, "Mul"))
        (if (is_float) .mul else .mulwrap)
    else
        unreachable;
    if (is_float and (tag == .bit_and or tag == .bit_or or tag == .xor))
        return sema.fail(block, src, "@reduce operation '{s}' requires integer or boolean operand; found '{f}'", .{ op, sema.fmtType(ty) });
    // A left fold, in element order.
    var acc = try sema.vectorElem(block, operand, 0);
    for (1..len) |i| acc = try sema.analyzeArithmetic(block, src, tag, acc, try sema.vectorElem(block, operand, @intCast(i)));
    return acc;
}

fn zirSelect(sema: *Sema, block: *Block, extended: Zir.Inst.Extended.InstData) CompileError!Ref {
    const ip = sema.ip;
    const extra = sema.code.extraData(Zir.Inst.Select, extended.operand).data;
    const src = block.nodeSrc(extra.node);
    const elem_ty = try sema.resolveType(block, src, extra.elem_type);
    const uncasted_pred = sema.resolveInst(extra.pred);
    const len: u32 = switch (ip.indexToKey(sema.typeOf(uncasted_pred))) {
        .vector_type => |v| v.len,
        .array_type => |a| @intCast(a.len),
        else => return sema.fail(block, src, "expected vector or array, found '{f}'", .{sema.fmtType(sema.typeOf(uncasted_pred))}),
    };
    const pred = try sema.coerce(block, try sema.vectorType(len, .bool_type), uncasted_pred, src);
    const vec_ty = try sema.vectorType(len, elem_ty);
    const a = try sema.coerce(block, vec_ty, sema.resolveInst(extra.a), src);
    const b = try sema.coerce(block, vec_ty, sema.resolveInst(extra.b), src);
    const Op = struct {
        elem_ty: Index,
        fn call(op: @This(), s: *Sema, blk: *Block, sr: Src, e: []const Ref) CompileError!Ref {
            const p = try s.coerce(blk, .bool_type, e[0], sr);
            if (s.resolveValue(p)) |pv| {
                if (s.isUndef(pv)) return .fromInterned(try s.undefElem(op.elem_ty));
                return if (pv == .bool_true) e[1] else e[2];
            }
            return s.select(blk, op.elem_ty, p, e[1], e[2]);
        }
    };
    return sema.vectorMap(block, src, len, vec_ty, &.{ pred, a, b }, Op{ .elem_ty = elem_ty });
}

fn zirShuffle(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ip = sema.ip;
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Shuffle, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    const elem_ty = try sema.resolveType(block, src, extra.elem_type);
    const mask_val = try sema.resolveConstValue(block, src, sema.resolveInst(extra.mask), "shuffle mask must be comptime-known");
    const mask_ty = ip.typeOf(mask_val);
    const mask_len: u32 = switch (ip.indexToKey(mask_ty)) {
        .vector_type => |v| v.len,
        .array_type => |a| @intCast(a.len),
        else => return sema.fail(block, src, "expected vector or array, found '{f}'", .{sema.fmtType(mask_ty)}),
    };
    const operand = struct {
        fn f(s: *Sema, blk: *Block, sr: Src, et: Index, ref: Zir.Inst.Ref) CompileError!struct { Ref, u32 } {
            const r = s.resolveInst(ref);
            const t = s.typeOf(r);
            if (t == .undefined_type) return .{ r, 0 };
            const n: u32 = switch (s.ip.indexToKey(t)) {
                .vector_type => |v| v.len,
                .array_type => |a| @intCast(a.len),
                else => return s.fail(blk, sr, "expected vector or array, found '{f}'", .{s.fmtType(t)}),
            };
            return .{ try s.coerce(blk, try s.vectorType(n, et), r, sr), n };
        }
    }.f;
    const a, const a_len = try operand(sema, block, src, elem_ty, extra.a);
    const b, const b_len = try operand(sema, block, src, elem_ty, extra.b);
    const elems = try sema.arena.alloc(Ref, mask_len);
    for (elems, 0..) |*e, i| {
        const m = try sema.elemValue(mask_val, i);
        if (sema.isUndef(m)) {
            e.* = .fromInterned(try sema.undefElem(elem_ty));
            continue;
        }
        const k = ip.intValue(i64, (try sema.coerce(block, .i32_type, .fromInterned(m), src)).toInterned().?).?;
        const from_a = k >= 0;
        const idx: u32 = @intCast(if (from_a) k else ~k);
        if (idx >= (if (from_a) a_len else b_len))
            return sema.fail(block, src, "mask index '{d}' has out-of-bounds selection", .{i});
        e.* = try sema.vectorElem(block, if (from_a) a else b, idx);
    }
    return sema.aggregate(block, src, try sema.vectorType(mask_len, elem_ty), elems);
}

// ---------------------------------------------------------------------------
// Tests: analyze a source file and compare the IR dump or the errors.

const Frontend = @import("Frontend.zig");

fn testAnalyze(source: []const u8) ![]u8 {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "t.zig", .data = source });
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/t.zig", .{tmp.sub_path});
    defer gpa.free(root);
    var fe: Frontend = try .init(gpa, io, "/nonexistent", .{ .root_src_path = root, .builtin_dir = "/nonexistent" });
    defer fe.deinit();
    var fe_errors: std.zig.ErrorBundle.Wip = try .init(gpa);
    defer fe_errors.deinit();
    try std.testing.expect(try fe.loadAll(&fe_errors));

    var zcu: Zcu = try .init(gpa, io, &fe);
    defer zcu.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const Sink = struct {
        w: *std.Io.Writer,
        pub fn function(s: *@This(), z: *Zcu, ir: *const Ir) !void {
            try print.dump(ir, &z.ip, s.w);
        }
    };
    var sink: Sink = .{ .w = &out.writer };
    try zcu.analyzeAll(&sink);
    for (zcu.errors.items) |e| {
        const loc = std.zig.findLineColumn(source, e.span.main);
        try out.writer.print("error({d}:{d}): {s}\n", .{ loc.line + 1, loc.column + 1, e.msg });
    }
    return out.toOwnedSlice();
}

fn expectAnalysis(source: []const u8, expected: []const u8) !void {
    const actual = try testAnalyze(source);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "dump: runtime add gets an overflow check, comptime operands fold" {
    try expectAnalysis(
        \\export fn f(a: u8) u8 {
        \\    return a + comptime (2 * 3);
        \\}
    ,
        \\fn t.f(u8) u8 callconv(.c) {
        \\  %0 = arg(u8, 0)
        \\  %1 = dbg_stmt(2:14)
        \\  %2 = add_with_overflow(struct { u8, u1 }, %0, <u8, 6>)
        \\  %3 = struct_field_val(u8, %2, 0)
        \\  %4 = struct_field_val(u1, %2, 1)
        \\  %5 = cmp_eq(%4, <u1, 0>)
        \\  %7 = block(void, {
        \\    %9 = cond_br(%5, {
        \\      %8 = br(%7, <void, void>)
        \\    }, {
        \\      %6 = panic(integer_overflow)
        \\    })
        \\  })
        \\  %10 = dbg_stmt(2:5)
        \\  %11 = ret(%3)
        \\}
        \\
    );
}

test "dump: slice indexing gets a bounds check" {
    try expectAnalysis(
        \\export fn f(s: [*]const u8, n: usize, i: usize) u8 {
        \\    return s[0..n][i];
        \\}
    ,
        \\fn t.f([*]const u8, usize, usize) u8 callconv(.c) {
        \\  %0 = arg([*]const u8, 0)
        \\  %1 = arg(usize, 1)
        \\  %2 = arg(usize, 2)
        \\  %3 = alloc(*const [*]const u8)
        \\  %4 = store(%3, %0)
        \\  %5 = dbg_stmt(2:13)
        \\  %6 = load([*]const u8, %3)
        \\  %7 = cmp_lte(<usize, 0>, %1)
        \\  %9 = block(void, {
        \\    %11 = cond_br(%7, {
        \\      %10 = br(%9, <void, void>)
        \\    }, {
        \\      %8 = panic(start_greater_than_end, <usize, 0>, %1)
        \\    })
        \\  })
        \\  %12 = sub_wrap(%1, <usize, 0>)
        \\  %13 = slice([]const u8, %6, %12)
        \\  %14 = alloc(*const []const u8)
        \\  %15 = store(%14, %13)
        \\  %16 = dbg_stmt(2:19)
        \\  %17 = load([]const u8, %14)
        \\  %18 = slice_len(usize, %17)
        \\  %19 = cmp_lt(%2, %18)
        \\  %21 = block(void, {
        \\    %23 = cond_br(%19, {
        \\      %22 = br(%21, <void, void>)
        \\    }, {
        \\      %20 = panic(out_of_bounds, %2, %18)
        \\    })
        \\  })
        \\  %24 = slice_elem_ptr(*const u8, %17, %2)
        \\  %25 = load(u8, %24)
        \\  %26 = dbg_stmt(2:5)
        \\  %27 = ret(%25)
        \\}
        \\
    );
}

test "dump: generic instances are shared and comptime calls fold" {
    try expectAnalysis(
        \\fn max(comptime T: type, a: T, b: T) T {
        \\    return if (a > b) a else b;
        \\}
        \\fn fib(n: u32) u32 {
        \\    return if (n < 2) n else fib(n - 1) + fib(n - 2);
        \\}
        \\export fn f(a: u16) u16 {
        \\    return max(u16, a, comptime fib(10)) + max(u16, 1, a);
        \\}
    ,
        \\fn t.f(u16) u16 callconv(.c) {
        \\  %0 = arg(u16, 0)
        \\  %1 = dbg_stmt(2:15)
        \\  %2 = call(<fn (u16, u16) u16, t.max[u16]>, [%0, <u16, 55>])
        \\  %3 = dbg_stmt(2:47)
        \\  %4 = call(<fn (u16, u16) u16, t.max[u16]>, [<u16, 1>, %0])
        \\  %5 = dbg_stmt(2:42)
        \\  %6 = add_with_overflow(struct { u16, u1 }, %2, %4)
        \\  %7 = struct_field_val(u16, %6, 0)
        \\  %8 = struct_field_val(u1, %6, 1)
        \\  %9 = cmp_eq(%8, <u1, 0>)
        \\  %11 = block(void, {
        \\    %13 = cond_br(%9, {
        \\      %12 = br(%11, <void, void>)
        \\    }, {
        \\      %10 = panic(integer_overflow)
        \\    })
        \\  })
        \\  %14 = dbg_stmt(2:5)
        \\  %15 = ret(%7)
        \\}
        \\fn t.max[u16](u16, u16) u16 {
        \\  %0 = arg(u16, 0)
        \\  %1 = arg(u16, 1)
        \\  %2 = dbg_stmt(2:16)
        \\  %3 = block(u16, {
        \\    %4 = cmp_gt(%0, %1)
        \\    %7 = cond_br(%4, {
        \\      %5 = br(%3, %0)
        \\    }, {
        \\      %6 = br(%3, %1)
        \\    })
        \\  })
        \\  %8 = dbg_stmt(2:5)
        \\  %9 = ret(%3)
        \\}
        \\
    );
}

test "dump: a function type in a parameter's type has its own parameters" {
    try expectAnalysis(
        \\fn apply(x: u16, g: *const fn (u8) u8) u16 {
        \\    return g(@truncate(x));
        \\}
        \\fn inc(v: u8) u8 {
        \\    return v +% 1;
        \\}
        \\export fn f(x: u16) u16 {
        \\    return apply(x, &inc);
        \\}
    ,
        \\fn t.f(u16) u16 callconv(.c) {
        \\  %0 = arg(u16, 0)
        \\  %1 = dbg_stmt(2:17)
        \\  %2 = call(<fn (u16, *const fn (u8) u8) u16, t.apply>, [%0, <*const fn (u8) u8, &t.inc>])
        \\  %3 = dbg_stmt(2:5)
        \\  %4 = ret(%2)
        \\}
        \\fn t.inc(u8) u8 {
        \\  %0 = arg(u8, 0)
        \\  %1 = dbg_stmt(2:5)
        \\  %2 = add_wrap(%0, <u8, 1>)
        \\  %3 = dbg_stmt(2:5)
        \\  %4 = ret(%2)
        \\}
        \\fn t.apply(u16, *const fn (u8) u8) u16 {
        \\  %0 = arg(u16, 0)
        \\  %1 = arg(*const fn (u8) u8, 1)
        \\  %2 = dbg_stmt(2:14)
        \\  %3 = trunc(u8, %0)
        \\  %4 = call(%1, [%3])
        \\  %5 = dbg_stmt(2:5)
        \\  %6 = intcast(u16, %4)
        \\  %7 = ret(%6)
        \\}
        \\
    );
}

test "dump: inferred error sets resolve through the callee's body" {
    try expectAnalysis(
        \\fn g(x: u8) !u8 {
        \\    if (x == 0) return error.Zero;
        \\    return x;
        \\}
        \\export fn f(x: u8) u8 {
        \\    return g(x) catch |err| switch (err) {
        \\        error.Zero => 1,
        \\    };
        \\}
    ,
        \\fn t.f(u8) u8 callconv(.c) {
        \\  %0 = arg(u8, 0)
        \\  %1 = dbg_stmt(2:13)
        \\  %2 = call(<fn (u8) (inferred error set)!u8, t.g>, [%0])
        \\  %3 = dbg_stmt(2:12)
        \\  %4 = is_non_err(%2)
        \\  %5 = block(u8, {
        \\    %14 = cond_br(%4, {
        \\      %6 = unwrap_errunion_payload(u8, %2)
        \\      %7 = br(%5, %6)
        \\    }, {
        \\      %8 = unwrap_errunion_err(@typeInfo(@typeInfo(@TypeOf(t.g)).@"fn".return_type.?).error_union.error_set, %2)
        \\      %9 = block(u8, {
        \\        %12 = switch_br(%8, [<@typeInfo(@typeInfo(@TypeOf(t.g)).@"fn".return_type.?).error_union.error_set, error.Zero>] => {
        \\          %10 = br(%9, <u8, 1>)
        \\        }, else => {
        \\          %11 = panic(corrupt_switch)
        \\        })
        \\      })
        \\      %13 = br(%5, %9)
        \\    })
        \\  })
        \\  %15 = dbg_stmt(2:5)
        \\  %16 = ret(%5)
        \\}
        \\fn t.g(u8) (inferred error set)!u8 {
        \\  %0 = arg(u8, 0)
        \\  %1 = dbg_stmt(2:9)
        \\  %2 = block(void, {
        \\    %3 = cmp_eq(%0, <u8, 0>)
        \\    %7 = cond_br(%3, {
        \\      %4 = dbg_stmt(2:17)
        \\      %5 = ret(<@typeInfo(@typeInfo(@TypeOf(t.g)).@"fn".return_type.?).error_union.error_set!u8, error.Zero>)
        \\    }, {
        \\      %6 = br(%2, <void, void>)
        \\    })
        \\  })
        \\  %8 = dbg_stmt(3:5)
        \\  %9 = wrap_errunion_payload(@typeInfo(@typeInfo(@TypeOf(t.g)).@"fn".return_type.?).error_union.error_set!u8, %0)
        \\  %10 = ret(%9)
        \\}
        \\
    );
}

test "errors: comptime-known values out of range" {
    try expectAnalysis(
        \\const x: u8 = 300;
        \\export fn f() u8 {
        \\    return x;
        \\}
    ,
        \\error(1:15): type 'u8' cannot represent integer value '300'
        \\
    );
}

/// Stable hashes of the elements of `const T = [_]type{ ... }` in `source`.
fn testTypeHashes(source: []const u8, out: []InternPool.Hash) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "t.zig", .data = source });
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/t.zig", .{tmp.sub_path});
    defer gpa.free(root);
    var fe: Frontend = try .init(gpa, io, "/nonexistent", .{ .root_src_path = root, .builtin_dir = "/nonexistent" });
    defer fe.deinit();
    var fe_errors: std.zig.ErrorBundle.Wip = try .init(gpa);
    defer fe_errors.deinit();
    try std.testing.expect(try fe.loadAll(&fe_errors));
    var zcu: Zcu = try .init(gpa, io, &fe);
    defer zcu.deinit();
    const NoSink = struct {
        pub fn function(_: *@This(), _: *Zcu, _: *const Ir) !void {}
    };
    var sink: NoSink = .{};
    try zcu.analyzeAll(&sink);
    try std.testing.expectEqual(0, zcu.errors.items.len);
    const ip = &zcu.ip;
    const nav = zcu.namespaces.items[0].decls.get(try ip.getString(Zcu.tid, "T")).?;
    const elems = ip.indexToKey(ip.getNav(nav).val).aggregate.storage.elems;
    for (out, elems) |*h, e| h.* = ip.stableHash(e);
}

test "anonymous types are keyed by unit and ordinal, not ZIR index" {
    var a: [2]InternPool.Hash = undefined;
    try testTypeHashes(
        \\const T = [_]type{ struct { x: u8 }, struct { x: u8 } };
        \\comptime { _ = T; }
    , &a);
    // Identical text in one declaration still gives two distinct types.
    try std.testing.expect(a[0] != a[1]);
    var b: [2]InternPool.Hash = undefined;
    try testTypeHashes(
        \\const Unrelated = struct { y: u32, fn f() void {} };
        \\const T = [_]type{ struct { x: u8 }, struct { x: u8 } };
        \\comptime { _ = T; }
    , &b);
    // Code above shifts every ZIR index; the keys stay put.
    try std.testing.expectEqualSlices(InternPool.Hash, &a, &b);
}
