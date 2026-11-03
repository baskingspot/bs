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
/// See `panicNamespace`; `.none` until resolved.
panic_ns: Index = .none,
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
/// Runtime `const` locals initialized through a result pointer that may
/// still be comptime-known (see `foldConstAlloc`), by `alloc` instruction.
const_allocs: std.AutoHashMapUnmanaged(Ir.Inst.Index, ConstAlloc) = .empty,
/// Field indices of the bit pointers (`bitcast`s) into packed fields of
/// `const_allocs`. Arena-allocated.
packed_field_ptrs: std.AutoHashMapUnmanaged(Ir.Inst.Index, u32) = .empty,
/// Mutable pointers to comptime fields' values, which stores may only
/// check. Arena-allocated.
comptime_field_ptrs: std.AutoHashMapUnmanaged(Index, void) = .empty,
/// The errors `func` returns so far, for its inferred error set; published
/// to `Zcu.inferred_errors` when its analysis ends. Arena-allocated.
ies_names: std.ArrayList(InternPool.String) = .empty,
/// Whether `func`'s inferred error set took in `anyerror`.
ies_anyerror: bool = false,
/// For each runtime bool vector being initialized through a result pointer,
/// the `[N]bool` local its elements are stored to first: bit-packed
/// elements have no addresses. Arena-allocated.
bool_vector_inits: std.AutoHashMapUnmanaged(Ref, Ref) = .empty,
/// Whether a peer of the current `resolvePeerTypes` is comptime-known.
peers_comptime_known: bool = false,
branch_quota: u32 = 1000,
branch_count: u32 = 0,
/// The statement position of the last `dbg_stmt` added, relative to the
/// declaration of the function or inline call being analyzed: where an
/// inline call made now is called from.
dbg_line: u32 = 0,
dbg_column: u32 = 0,
/// Nesting of runtime inline calls, to fail on unbounded inline recursion.
inline_depth: u32 = 0,

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

/// The stores into a runtime `const` local so far: all of comptime-known
/// values, from the local's own block. Arena-allocated.
const ConstAlloc = struct {
    block: *Block,
    stores: std.ArrayList(struct { ptr: Ref, val: Index }) = .empty,
};

const ComptimeAlloc = struct {
    ty: Index,
    val: Index,
    is_const: bool,
    /// An explicit `align(n)` of an inferred-type variable, or 0.
    alignment: u64 = 0,
};

const InferredAlloc = struct {
    stores: std.ArrayList(Ir.Inst.Index) = .empty,
    is_const: bool,
    /// The block of the `alloc`, and whether every store so far was in it.
    block: *Block,
    same_block: bool = true,
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
    /// See `condChild`.
    runtime_cond: bool = false,
    /// Inside `@TypeOf`'s operand: only the type of values matters.
    is_typeof: bool = false,
    /// A `comptime` block in a runtime function body: as upstream, it may
    /// compute runtime-known values, whose instructions are dropped, as
    /// long as nothing comptime (a branch, a constant, its result) needs
    /// them.
    discards_runtime: bool = false,
    /// The innermost runtime `loop` this block is inside of.
    loop: ?Ir.Inst.Index = null,

    pub const Label = struct {
        zir_block: Zir.Inst.Index,
        merges: Merges,
        /// A runtime labeled switch: `continue :label x` stores `x` here
        /// and repeats `loop_inst`.
        switch_continue: ?struct { loop_inst: Ir.Inst.Index, operand_ptr: Ref, operand_ty: Index } = null,
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
                /// A runtime call of an inline function: returns break to this
        /// block. Null for comptime calls.
        merges: ?*Merges = null,
    };

    pub const Param = struct {
        ty: Index,
        is_comptime: bool,
        name: Zir.NullTerminatedString,
    };

    /// A child whose instructions run only on some paths (a branch,
    /// switch prong, or loop body), unlike a labeled block's.
    fn condChild(b: *Block) Block {
        var c = b.child();
        c.runtime_cond = true;
        return c;
    }

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
            .is_typeof = b.is_typeof,
            .discards_runtime = b.discards_runtime,
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
    sema.const_allocs.deinit(gpa);
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

    const decl_ty: Index = if (decl.type_body) |body| blk: {
        const ref = try sema.resolveInlineBody(&block, body, nav.zir_inst);
        break :blk try sema.analyzeAsType(&block, src, ref);
    } else .none;
    if (decl.align_body) |body| {
        const a_ref = try sema.coerce(&block, .u32_type, try sema.resolveInlineBody(&block, body, nav.zir_inst), src);
        const a = sema.ip.intValue(u64, try sema.resolveConstValue(&block, src, a_ref, "alignment must be comptime-known")).?;
        if (a == 0 or !std.math.isPowerOfTwo(a)) return sema.fail(&block, src, "alignment value '{d}' is not a power of two", .{a});
        nav.alignment = a;
    }
    // A declared type is known before the value, so the value may take its
    // own address (`const foo: S = .{ .self = &foo }`), as upstream.
    if (decl_ty != .none) nav.ty = decl_ty;
    if (decl.linkage == .@"extern") {
        // `extern fn name(...) T;`: defined by an export of `name`, which
        // calls reach through a slot the linker fills (see `extern_ptr`).
        // An extern variable has no value; `navRef` reaches it the same way.
        nav.val = if (Type.class(sema.ip, decl_ty) == .@"fn")
            try sema.intern(.{ .extern_func = .{ .name = nav.name, .ty = decl_ty, .is_weak = false } })
        else
            try sema.undefValue(decl_ty);
        nav.ty = decl_ty;
        try sema.resolveLayoutIfIdle(&block, src, decl_ty);
        return sema.finish();
    }
    // Within the value body, the `declaration` instruction refers to the type.
    if (decl_ty != .none) try sema.inst_map.put(sema.gpa, nav.zir_inst, .fromInterned(decl_ty));
    var val_ref = try sema.resolveInlineBody(&block, decl.value_body.?, nav.zir_inst);
    if (decl_ty != .none) {
        val_ref = try sema.coerce(&block, decl_ty, val_ref, .{ .base = decl.src_node, .loc = .var_init });
    }
    const val = try sema.resolveConstValue(&block, src, val_ref, "global variable initializer must be comptime-known");
    nav.val = val;
    nav.ty = sema.ip.typeOf(val);
    // Emit lays out the value of any declaration code refers to.
    try sema.resolveLayoutIfIdle(&block, src, nav.ty);
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
    var is_comptime: []bool = &.{};
    var it = decl.iterateFields();
    while (it.next()) |field| {
        const i = field.idx;
        names[i] = try ip.getString(Zcu.tid, sema.code.nullTerminatedString(field.name));
        if (field.is_comptime) {
            if (decl.layout != .auto) return sema.fail(&block, block.nodeSrc(.zero), "{t} struct fields cannot be marked comptime", .{decl.layout});
            if (is_comptime.len == 0) {
                is_comptime = try ip.arena(Zcu.tid).alloc(bool, n);
                @memset(is_comptime, false);
            }
            is_comptime[i] = true;
        }
        if (field.align_body) |body| {
            if (decl.layout == .@"packed") return sema.fail(&block, block.nodeSrc(.zero), "unable to override alignment of packed struct fields", .{});
            aligns[i] = try sema.resolveFieldAlign(&block, block.nodeSrc(.zero), try sema.resolveInlineBody(&block, body, key.zir_inst));
        }
        const ty_ref = try sema.resolveInlineBody(&block, field.type_body, key.zir_inst);
        types[i] = try sema.analyzeAsType(&block, block.nodeSrc(.zero), ty_ref);
        defaults[i] = .none;
    }
    info.field_names = names;
    info.field_types = types;
    info.field_is_comptime = is_comptime;
    info.status = .have_field_types;


    const explicit_backing: Index = if (decl.backing_int_type_body) |body|
        try sema.analyzeAsType(&block, block.nodeSrc(.zero), try sema.resolveInlineBody(&block, body, key.zir_inst))
    else
        .none;
    try sema.structLayout(&block, info, decl.layout, explicit_backing, offsets, aligns);
    for (aligns) |a| if (a != 0) {
        info.field_aligns = try ip.arena(Zcu.tid).dupe(u64, aligns);
        break;
    };

    // A `comptime` field's value is part of the layout, as upstream. It
    // may refer to the struct itself (for example its size), so it is
    // evaluated after the layout. The other fields' defaults are the
    // `struct_defaults` unit's (`analyzeStructDefaults`); until then they
    // read as `.none`.
    info.field_defaults = defaults;
    if (is_comptime.len != 0) {
        it = decl.iterateFields();
        while (it.next()) |field| {
            if (!field.is_comptime) continue;
            const body = field.default_body orelse
                return sema.fail(&block, block.nodeSrc(.zero), "comptime field without default initialization value", .{});
            defaults[field.idx] = try sema.fieldDefault(&block, key.zir_inst, types[field.idx], body);
        }
    }
    try sema.finish();
}

/// Evaluates the default values of a declared struct's non-`comptime`
/// fields: its `struct_defaults` unit. They may read the struct's layout,
/// or a containing type's (an inner struct's default `@sizeOf(Outer)`),
/// which is why they are not part of the layout.
pub fn analyzeStructDefaults(zcu: *Zcu, ty: Index) CompileError!void {
    const ip = &zcu.ip;
    const key = ip.containerType(ty).?;
    const info = ip.structInfo(ty);
    var arena_state: std.heap.ArenaAllocator = .init(zcu.gpa);
    defer arena_state.deinit();
    var sema = create(zcu, arena_state.allocator(), key.file, .{ .struct_defaults = ty });
    defer sema.destroy();
    try sema.declareDependency(.{ .type_layout = ty });
    const decl = sema.code.getStructDecl(key.zir_inst);
    var block = sema.rootBlock(info.namespace, decl.fields_baseline_src_node, true);
    defer block.instructions.deinit(zcu.gpa);
    const defaults: []Index = @constCast(info.field_defaults);
    var it = decl.iterateFields();
    while (it.next()) |field| {
        if (field.is_comptime) continue;
        const body = field.default_body orelse continue;
        defaults[field.idx] = try sema.fieldDefault(&block, key.zir_inst, info.field_types[field.idx], body);
    }
    try sema.finish();
}

/// A field's default value, from its ZIR body.
fn fieldDefault(sema: *Sema, block: *Block, struct_inst: Zir.Inst.Index, field_ty: Index, body: []const Zir.Inst.Index) CompileError!Index {
    // Within the default body, the struct instruction stands for the
    // field type (the result type of the default value).
    try sema.inst_map.put(sema.gpa, struct_inst, .fromInterned(field_ty));
    const ref = try sema.resolveInlineBody(block, body, struct_inst);
    const coerced = try sema.coerce(block, field_ty, ref, block.nodeSrc(.zero));
    return sema.resolveConstValue(block, block.nodeSrc(.zero), coerced, "struct field default value must be comptime-known");
}

/// A field's `align(n)`: a comptime-known power of two.
fn resolveFieldAlign(sema: *Sema, block: *Block, src: Src, ref: Ref) CompileError!u64 {
    const a_ref = try sema.coerce(block, .u32_type, ref, src);
    const a = sema.ip.intValue(u64, try sema.resolveConstValue(block, src, a_ref, "field alignment must be comptime-known")).?;
    if (a == 0 or !std.math.isPowerOfTwo(a)) return sema.fail(block, src, "alignment value '{d}' is not a power of two", .{a});
    return a;
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
    try sema.structLayout(&block, info, layout, backing, offsets, info.field_aligns);
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
        // As upstream's resolveStructLayout: an explicit alignment can raise
        // or lower the natural one, and an auto layout lays fields out in
        // descending alignment, sorted exactly as upstream sorts them.
        const field_aligns = try sema.arena.alloc(u64, types.len);
        const order = try sema.arena.alloc(u32, types.len);
        const omitted = std.math.maxInt(u32);
        var alignment: u64 = 1;
        for (types, field_aligns, order, 0..) |ft, *fa, *o, i| {
            offsets[i] = 0;
            if (info.fieldIsComptime(i)) {
                o.* = omitted;
                continue;
            }
            try sema.resolveLayout(block, block.nodeSrc(.zero), ft);
            fa.* = if (aligns.len != 0 and aligns[i] != 0) aligns[i] else Type.abiAlignment(ip, ft);
            alignment = @max(alignment, fa.*);
            o.* = @intCast(i);
        }
        if (layout == .auto) {
            const Ctx = struct {
                aligns: []const u64,
                fn lessThan(ctx: @This(), a: u32, b: u32) bool {
                    if (a == omitted) return false;
                    if (b == omitted) return true;
                    return ctx.aligns[a] > ctx.aligns[b];
                }
            };
            std.mem.sortUnstable(u32, order, Ctx{ .aligns = field_aligns }, Ctx.lessThan);
        }
        var offset: u64 = 0;
        for (order) |i| {
            if (i == omitted) continue;
            offset = std.mem.alignForward(u64, offset, field_aligns[i]);
            offsets[i] = offset;
            offset += Type.abiSize(ip, types[i]);
        }
        info.field_offsets = offsets;
        info.size = std.mem.alignForward(u64, offset, alignment);
        info.alignment = alignment;
    }
    info.status = .have_layout;
    sema.setComptimeOnly(info);
}

/// Fixes whether a struct or union whose layout was just resolved is
/// comptime-only. Its fields' by-value types had their layouts resolved,
/// and recorded as dependencies, by the layout, which is all the answer
/// reads: the `type_layout` result includes it, and is final.
fn setComptimeOnly(sema: *Sema, info: *InternPool.ContainerInfo) void {
    const yes = for (info.field_types, 0..) |ft, i| {
        if (!info.fieldIsComptime(i) and Type.isComptimeOnly(sema.ip, ft)) break true;
    } else false;
    info.comptime_only = if (yes) .yes else .no;
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
        // As upstream, an enum without fields has tag type `noreturn`.
        break :blk if (n == 0) .noreturn_type else try sema.intType(.unsigned, std.math.log2_int_ceil(usize, n));
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
        var aligns: []u64 = &.{};
        var it = decl.iterateFields();
        while (it.next()) |field| {
            const i = field.idx;
            names[i] = try ip.getString(Zcu.tid, sema.code.nullTerminatedString(field.name));
            types[i] = if (field.type_body) |body|
                try sema.analyzeAsType(&block, src, try sema.resolveInlineBody(&block, body, key.zir_inst))
            else
                .void_type;
            if (field.align_body) |body| {
                if (aligns.len == 0) {
                    aligns = try ip.arena(Zcu.tid).alloc(u64, n);
                    @memset(aligns, 0);
                }
                aligns[i] = try sema.resolveFieldAlign(&block, src, try sema.resolveInlineBody(&block, body, key.zir_inst));
            }
        }
        info.field_names = names;
        info.field_types = types;
        info.field_aligns = aligns;
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
            sema.setComptimeOnly(info);
            return sema.finish();
        },
    }
    info.status = .have_field_types;

    info.status = .layout_wip;
    var payload_size: u64 = 0;
    var payload_align: u64 = 1;
    // As upstream, the tag is stored only if more than one field can be
    // active and the union is not comptime-only.
    var possible_tags: u32 = 0;
    var comptime_state = false;
    for (types, 0..) |ft, i| {
        try sema.resolveLayout(&block, src, ft);
        if (Type.hasNoPossibleValue(ip, ft)) continue;
        possible_tags += 1;
        if (Type.isComptimeOnly(ip, ft)) comptime_state = true;
        if (Type.hasRuntimeBits(ip, ft)) payload_size = @max(payload_size, Type.abiSize(ip, ft));
        payload_align = @max(payload_align, Type.unionFieldAlign(ip, info, @intCast(i)));
    }
    info.has_runtime_tag = info.tag_type != .none and possible_tags > 1 and !comptime_state and Type.hasRuntimeBits(ip, info.tag_type);
    var size = payload_size;
    var alignment = payload_align;
    if (info.has_runtime_tag) {
        size += Type.abiSize(ip, info.tag_type);
        alignment = @max(alignment, Type.abiAlignment(ip, info.tag_type));
    }
    info.size = std.mem.alignForward(u64, size, alignment);
    info.alignment = alignment;
    info.status = .have_layout;
    sema.setComptimeOnly(info);
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
    sema.branch_quota = @max(sema.branch_quota, sema.zcu.branch_quotas.get(func_index) orelse 0);
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
            const pt = fn_ty.param_types[arg_i];
            const arg = try sema.addInst(&block, .{ .tag = .arg, .data = .{ .arg = .{ .ty = pt, .index = arg_i } } });
            // A parameter of a type with one possible value is that value.
            if (!Type.hasRuntimeBits(ip, pt) and !Type.isComptimeOnly(ip, pt))
                if (try sema.onePossibleValue(pt)) |v| break :blk .fromInterned(v);
            break :blk arg;
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

    // One allocation per function, in the Zcu arena: a small gpa list per
    // function instance pins allocator pages for the whole compilation.
    if (sema.ies_anyerror) try zcu.anyerror_ies.put(gpa, func_index, {});
    if (sema.ies_names.items.len != 0) {
        try zcu.inferred_errors.put(gpa, func_index, try zcu.arena.allocator().dupe(InternPool.String, sema.ies_names.items));
    }

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

/// `Type.isComptimeOnly`, after resolving the layouts it reads (those of
/// the types `ty` contains by value), which records them as dependencies
/// of this unit. Every Sema read of whether a type is comptime-only goes
/// through here unless that layout was just resolved. A type whose layout
/// is being resolved answers from the fields known so far.
fn isComptimeOnlyResolved(sema: *Sema, block: *Block, src: Src, ty: Index) CompileError!bool {
    try sema.resolveLayoutIfIdle(block, src, ty);
    return Type.isComptimeOnly(sema.ip, ty);
}

/// Resolves the layout and field defaults of a struct type, recording
/// both, before its defaults are read (a struct init that omits fields,
/// `@typeInfo`). Other container types have none.
fn resolveStructDefaults(sema: *Sema, block: *Block, src: Src, ty: Index) CompileError!void {
    if (sema.ip.indexToKey(ty) != .struct_type) return;
    try sema.resolveLayout(block, src, ty);
    try sema.declareDependency(.{ .struct_defaults = ty });
    sema.zcu.ensureStructDefaults(ty) catch |err| return sema.depLoop(block, src, err);
}

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
    if (block.is_comptime and !block.discards_runtime) return sema.fail(block, .{ .base = block.src_base, .loc = .{ .node = .zero } }, "unable to evaluate comptime expression", .{});
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

/// The panics Sema emits, each a call of the `std.lang.panic` handler
/// named after it (`integer_overflow` calls `integerOverflow`).
const PanicId = enum(u32) {
    reached_unreachable,
    unwrap_null,
    cast_to_null,
    incorrect_alignment,
    invalid_error_code,
    integer_out_of_bounds,
    integer_overflow,
    shl_overflow,
    shr_overflow,
    divide_by_zero,
    exact_division_remainder,
    integer_part_out_of_bounds,
    corrupt_switch,
    shift_rhs_too_big,
    invalid_enum_value,
    for_len_mismatch,
    copy_len_mismatch,
    memcpy_alias,
    noreturn_returned,
    /// With the active and accessed tags.
    inactive_union_field,
    /// With the index and length.
    out_of_bounds,
    /// With the start and end.
    start_greater_than_end,
    /// With the error.
    unwrap_error,
    /// With the expected and found sentinels.
    sentinel_mismatch,
    /// `@panic(msg)`: calls `call(msg, null)`.
    explicit,
};

fn addPanic(sema: *Sema, block: *Block, id: PanicId, lhs: Ref, rhs: Ref) CompileError!void {
    if (block.discards_runtime) return;
    // As upstream, call the handler in `std.lang.panic`.
    const ns = try sema.panicNamespace(block);
    const src = block.nodeSrc(.zero);
    const name: []const u8, const args: []const Ref = switch (id) {
        .explicit => .{ "call", &.{ lhs, .fromInterned(try sema.intern(.{ .opt = .{ .ty = try sema.optType(.usize_type), .val = .none } })) } },
        .out_of_bounds => .{ "outOfBounds", &.{ lhs, rhs } },
        .start_greater_than_end => .{ "startGreaterThanEnd", &.{ lhs, rhs } },
        .sentinel_mismatch => .{ "sentinelMismatch", &.{ lhs, rhs } },
        // zap tags an untagged union with an integer, which has no
        // field names to report.
        .inactive_union_field => if (Type.class(sema.ip, sema.typeOf(lhs)) == .@"enum")
            .{ "inactiveUnionField", &.{ lhs, rhs } }
        else
            .{ "call", &.{ .fromInterned(try sema.stringLiteral("access of inactive union field")), .fromInterned(try sema.intern(.{ .opt = .{ .ty = try sema.optType(.usize_type), .val = .none } })) } },
        .unwrap_error => .{ "unwrapError", &.{lhs} },
        inline else => |tag| .{ comptime panicFnName(tag), &.{} },
    };
    const callee = try sema.namespaceLookupVal(block, src, ns, name);
    _ = try sema.analyzeCall(block, src, callee, .none, .{ .resolved = try sema.arena.dupe(Ref, args) }, .auto);
    _ = try sema.addInst(block, .{ .tag = .unreach, .data = .{ .no_op = {} } });
}

/// `std.lang.panic`, the namespace of panic handlers: the root file's
/// `panic` if it declares one, else std's default handler.
fn panicNamespace(sema: *Sema, block: *Block) CompileError!Index {
    if (sema.panic_ns != .none) return sema.panic_ns;
    const src = block.nodeSrc(.zero);
    // `std.lang.panic` is the root's namespace when it declares one; read
    // it directly, which needs no std (the root's deprecated panic
    // function does go through std).
    const root_ty = try sema.zcu.fileRootType(sema.zcu.moduleRootFile(.root).?);
    const root_panic: ?Index = if (try sema.lookupInType(root_ty, "panic")) |nav| blk: {
        const val = try sema.navVal(block, src, nav);
        break :blk if (sema.typeOf(val) == .type_type) try sema.analyzeAsType(block, src, val) else null;
    } else null;
    sema.panic_ns = root_panic orelse try sema.analyzeAsType(block, src, try sema.stdLangDecl(block, src, "panic"));
    return sema.panic_ns;
}

/// The `std.lang.panic` function for a panic without operands:
/// `integer_overflow` is `integerOverflow`.
fn panicFnName(comptime id: PanicId) []const u8 {
    const tag = @tagName(id);
    var out: [tag.len]u8 = undefined;
    var n: usize = 0;
    var upper = false;
    for (tag) |c| {
        if (c == '_') {
            upper = true;
            continue;
        }
        out[n] = if (upper) std.ascii.toUpper(c) else c;
        upper = false;
        n += 1;
    }
    const final = out[0..n].*;
    return &final;
}

/// Appends a body's length and instructions to `ir_extra`.
fn appendBody(sema: *Sema, body: []const Ir.Inst.Index) !void {
    try sema.ir_extra.appendSlice(sema.gpa, @ptrCast(body));
}

/// Emits `if (!ok) panic(id)`.
fn addSafetyCheck(sema: *Sema, block: *Block, ok: Ref, id: PanicId, lhs: Ref, rhs: Ref) !void {
    // Dropped instructions need no checks.
    if (block.discards_runtime) return;
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
            // `continue :sw x` targets the switch too but restarts it.
            if (sema.code.instructions.items(.tag)[@backingInt(sema.comptime_break_inst)] == .switch_continue) return error.ComptimeBreak;
            return sema.resolveInst(brk.operand);
        },
        else => |e| return e,
    };
    return null;
}

fn emitBackwardBranch(sema: *Sema, block: *Block, src: Src) CompileError!void {
    sema.branch_count += 1;
    if (sema.branch_count > sema.branch_quota) {
        const err = sema.fail(block, src, "evaluation exceeded {d} backwards branches", .{sema.branch_quota});
        const tree = try sema.zcu.fe.tree(@fromBackingInt(sema.file));
        try sema.zcu.addNote(sema.file, src.span(tree), "use @setEvalBranchQuota() to raise the branch limit from {d}", .{sema.branch_quota});
        return err;
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
                if (!block.is_comptime) {
                    // To an enclosing runtime block (see `zirBlockInline`).
                    const brk = data.@"break";
                    const target = sema.code.extraData(Zir.Inst.Break, brk.payload_index).data.block_inst;
                    var it: ?*Block = block;
                    while (it) |cur| : (it = cur.parent) {
                        const label = cur.label orelse continue;
                        if (label.zir_block == target) {
                            try sema.addBr(block, label, sema.resolveInst(brk.operand));
                            return;
                        }
                    }
                }
                sema.comptime_break_inst = inst;
                return error.ComptimeBreak;
            },
            .switch_continue => {
                if (!block.is_comptime) if (try sema.zirSwitchContinue(block, inst)) return;
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
                if (!block.is_comptime and sema.func != .none) child.discards_runtime = true;
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
                // Lines in an inlined body are relative to the callee's
                // declaration (see `Ir.Inst.Tag.dbg_inline_begin`).
                if (!block.is_comptime) try sema.addDbgStmt(block, data.dbg_stmt.line, data.dbg_stmt.column);
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
            .validate_destructure => {
                try sema.zirValidateDestructure(block, inst);
                i += 1;
                continue;
            },
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
        .repeat, .br, .cond_br, .switch_br, .ret, .unreach, .trap => true,
        else => false,
    };
}

fn addDbgStmt(sema: *Sema, block: *Block, line: u32, column: u32) !void {
    sema.dbg_line = line;
    sema.dbg_column = column;
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
    // In runtime code, an inline block (such as an `inline for`) may be
    // left by a break inside runtime control flow: it is then a runtime
    // block, as upstream.
    if (!block.is_comptime) return sema.zirBlock(block, inst);
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
    if (results.len == 1 and sema.ir_insts.items(.tag)[@backingInt(merges.brs.items[0])] == .br) if (sema.resolveValue(results[0])) |v| {
        // As upstream, a single comptime-known result is the block's value
        // (it may be comptime-only, like `comptime_int`), and the block
        // itself is void.
        sema.ir_insts.items(.data)[@backingInt(merges.brs.items[0])].br.operand = .void_value;
        try sema.addBlock(parent, merges.block_inst, .void_type, child.instructions.items);
        return .fromInterned(v);
    };
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

/// `continue :sw x` in a runtime labeled switch: store the new operand and
/// repeat the switch's dispatch loop. False if the switch is comptime.
fn zirSwitchContinue(sema: *Sema, b: *Block, inst: Zir.Inst.Index) CompileError!bool {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].@"break";
    const extra = sema.code.extraData(Zir.Inst.Break, data.payload_index).data;
    var it: ?*Block = b;
    while (it) |cur| : (it = cur.parent) {
        const label = cur.label orelse continue;
        if (label.zir_block != extra.block_inst) continue;
        const sc = label.switch_continue orelse return false;
        const src = b.nodeSrc(extra.operand_src_node.unwrap() orelse .zero);
        const operand = try sema.coerce(b, sc.operand_ty, sema.resolveInst(data.operand), src);
        try sema.analyzeStore(b, src, sc.operand_ptr, operand);
        _ = try sema.addInst(b, .{ .tag = .repeat, .data = .{ .repeat = .{ .loop_inst = sc.loop_inst } } });
        return true;
    }
    return false;
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
    var loop_block = parent.condChild();
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
    var then_block = parent.condChild();
    defer then_block.instructions.deinit(gpa);
    try sema.analyzeBodyInner(&then_block, then_body);
    var else_block = parent.condChild();
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
        if (inlining.merges) |merges| if (!b.is_comptime) {
            const br = try sema.addInst(b, .{ .tag = .br, .data = .{ .br = .{ .block_inst = merges.block_inst, .operand = coerced } } });
            try merges.results.append(sema.gpa, coerced);
            try merges.brs.append(sema.gpa, br.toIndex().?);
            return;
        };
        // A return from a comptime block of a runtime inline call ends
        // the call with a comptime-known result (see `inlineCall`).
        if (b.is_comptime) _ = try sema.resolveConstValue(b, src, coerced, "value returned at comptime must be comptime-known");
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
        .embed_file => sema.zirEmbedFile(block, inst),
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
        .typeof => .fromInterned(try sema.typeOfWithIes(sema.resolveInst(data.un_node.operand))),
        .typeof_builtin => blk: {
            const extra = sema.code.extraData(Zir.Inst.Block, data.pl_node.payload_index);
            const body = sema.code.bodySlice(extra.end, extra.data.body_len);
            var child = block.child();
            defer child.instructions.deinit(sema.gpa);
            // The operand is analyzed for its type only, as runtime code even
            // in a comptime scope (like upstream); any IR it emits is never
            // referenced by a body.
            child.is_comptime = false;
            child.is_typeof = true;
            const operand = try sema.resolveInlineBody(&child, body, inst);
            break :blk .fromInterned(try sema.typeOfWithIes(operand));
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
            if (ptr.toIndex()) |i| if (try sema.foldConstAlloc(block, block.nodeSrc(data.un_node.src_node), i)) |folded| break :blk .fromInterned(folded);
            // A constant held in comptime memory (one of a comptime-only
            // type) becomes an immutable value that runtime code can
            // address.
            if (sema.resolveValue(ptr)) |pv| if (sema.ip.indexToKey(pv) == .ptr) {
                const k = sema.ip.indexToKey(pv).ptr;
                if (k.base == .comptime_alloc and k.byte_offset == 0) if (sema.comptime_allocs.get(k.base.comptime_alloc)) |alloc| {
                    if (!sema.refersToComptimeAlloc(alloc.val)) {
                        var info = Type.ptrInfo(sema.ip, k.ty);
                        info.flags.is_const = true;
                        const const_ty = try sema.ptrType(info);
                        break :blk .fromInterned(try sema.intern(.{ .ptr = .{ .ty = const_ty, .base = .{ .uav = .{ .val = alloc.val, .orig_ty = const_ty } } } }));
                    }
                };
            };
            var info = Type.ptrInfo(sema.ip, sema.typeOf(ptr));
            info.flags.is_const = true;
            break :blk sema.coercePtrTo(block, ptr, try sema.ptrType(info));
        },
        .load => sema.analyzeLoad(block, block.nodeSrc(data.un_node.src_node), sema.resolveInst(data.un_node.operand)),
        .ref => sema.analyzeRef(block, block.tokSrc(data.un_tok.src_tok), sema.resolveInst(data.un_tok.operand)),
        .deref => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            break :blk sema.analyzeLoad(block, src, try sema.derefPtr(block, src, sema.resolveInst(data.un_node.operand)));
        },
        .ref_deref => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            break :blk sema.derefPtr(block, src, sema.resolveInst(data.un_node.operand));
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
        .atomic_load => sema.zirAtomicLoad(block, inst),
        .atomic_store => sema.zirAtomicStore(block, inst),
        .atomic_rmw => sema.zirAtomicRmw(block, inst),
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
            break :blk if (tag == .field_ptr) sema.fieldPtr(block, src, lhs, name) else sema.fieldPtrLoad(block, src, lhs, name);
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
                else if (block.is_comptime and sema.resolveValue(lhs) == null and try sema.indexedOnePossibleValue(sema.typeOf(lhs)) != null)
                    // A zero-bit element of runtime memory, read at comptime.
                    Ref.fromInterned((try sema.indexedOnePossibleValue(sema.typeOf(lhs))).?)
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
        .@"try" => sema.zirTry(block, inst, false),
        .try_ptr => sema.zirTry(block, inst, true),
        .switch_block => sema.zirSwitchBlock(block, inst, false),
        .switch_block_err_union => sema.zirSwitchBlockErrUnion(block, inst),
        .memcpy => sema.zirMemcpy(block, inst, .memcpy),
        .memmove => sema.zirMemcpy(block, inst, .memmove),
        .memset => sema.zirMemset(block, inst),
        .switch_block_ref => sema.zirSwitchBlock(block, inst, true),

        // Initialization.
        .struct_init_empty, .struct_init_empty_result, .struct_init_empty_ref_result => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const result_ty = try sema.resolveType(block, src, data.un_node.operand);
            if (tag != .struct_init_empty_ref_result) {
                const base = sema.unwrapOptEu(result_ty);
                break :blk sema.coerce(block, result_ty, try sema.structInitEmpty(block, src, base), src);
            }
            const ptr_ty = sema.unwrapOptEu(result_ty);
            if (ptr_ty == .generic_poison_type or Type.class(sema.ip, ptr_ty) != .pointer) break :blk sema.analyzeRef(block, src, .fromInterned(.empty_tuple));
            const p = Type.ptrInfo(sema.ip, ptr_ty);
            if (p.flags.size == .one or p.flags.size == .c) {
                // Through `*anyopaque`, `.{}` is untyped: the empty tuple.
                if (p.child == .anyopaque_type) break :blk sema.analyzeRef(block, src, .fromInterned(.empty_tuple));
                break :blk sema.analyzeRef(block, src, try sema.structInitEmpty(block, src, p.child));
            }
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
            const ty = sema.unwrapOptEu(try sema.resolveType(block, src, extra.container_type));
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
            const ty = sema.unwrapOptEu(try sema.resolveType(block, block.nodeSrc(.zero), data.bin.lhs));
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
            if (tag == .backing_int and Type.isPacked(sema.ip, ty)) {
                // A packed struct's or union's backing integer: its bits.
                try sema.resolveLayout(block, src, ty);
                break :blk sema.reinterpretBits(block, src, sema.ip.structInfo(ty).tag_type, operand);
            }
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
            if (Type.class(sema.ip, ty) != .@"enum" and !Type.isPacked(sema.ip, ty)) return sema.fail(block, src, "expected enum or packed type, found '{f}'", .{sema.fmtType(ty)});
            try sema.resolveLayout(block, src, ty);
            break :blk .fromInterned(sema.ip.structInfo(ty).tag_type);
        },
        .enum_from_int, .from_backing_int => blk: {
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const ty = try sema.castDestType(block, src, extra.lhs, true);
            if (tag == .from_backing_int and Type.isPacked(sema.ip, ty)) {
                try sema.resolveLayout(block, src, ty);
                const int = try sema.coerce(block, sema.ip.structInfo(ty).tag_type, sema.resolveInst(extra.rhs), src);
                break :blk sema.reinterpretBits(block, src, ty, int);
            }
            if (Type.class(sema.ip, ty) != .@"enum") return sema.fail(block, src, "expected enum, found '{f}'", .{sema.fmtType(ty)});
            break :blk sema.enumFromInt(block, src, ty, sema.resolveInst(extra.rhs));
        },
        .tag_name => sema.zirTagName(block, inst),
        .type_name => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const ty = try sema.resolveType(block, src, data.un_node.operand);
            break :blk .fromInterned(try sema.stringLiteral(try std.fmt.allocPrint(sema.arena, "{f}", .{sema.fmtType(ty)})));
        },
        .offset_of, .bit_offset_of => blk: {
            const src = block.nodeSrc(data.pl_node.src_node);
            const bits = try sema.bitOffsetOf(block, src, sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data);
            break :blk .fromInterned(try sema.intValue(.comptime_int_type, if (tag == .offset_of) bits / 8 else bits));
        },
        .union_init => blk: {
            const extra = sema.code.extraData(Zir.Inst.UnionInit, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const ty = try sema.resolveType(block, src, extra.union_type);
            if (Type.class(sema.ip, ty) != .@"union") return sema.fail(block, src, "expected union type, found '{f}'", .{sema.fmtType(ty)});
            const name = try sema.resolveConstString(block, src, sema.resolveInst(extra.field_name));
            const i = try sema.unionFieldIndex(block, src, ty, name);
            const init = try sema.coerce(block, sema.ip.structInfo(ty).field_types[i], sema.resolveInst(extra.init), src);
            break :blk sema.unionInit(block, src, ty, i, init);
        },
        .field_type_ref => blk: {
            const extra = sema.code.extraData(Zir.Inst.FieldTypeRef, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const ty = try sema.resolveType(block, src, extra.container_type);
            const name = try sema.resolveConstString(block, src, sema.resolveInst(extra.field_name));
            break :blk .fromInterned(try sema.fieldTypeByName(block, src, ty, name));
        },
        .error_name => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const operand = try sema.coerce(block, .anyerror_type, sema.resolveInst(data.un_node.operand), src);
            if (sema.resolveValue(operand)) |v| {
                if (sema.isUndef(v)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
                // A string literal, as upstream.
                break :blk .fromInterned(try sema.stringLiteral(sema.ip.stringSlice(sema.ip.indexToKey(v).err.name)));
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
            const ty = try sema.castDestType(block, src, data.un_node.operand, true);
            if (ty == .generic_poison_type) break :blk .fromInterned(.generic_poison_type);
            if (Type.class(sema.ip, ty) != .array and Type.class(sema.ip, ty) != .vector) return sema.fail(block, src, "expected array or vector result type for @splat, found '{f}'", .{sema.fmtType(ty)});
            break :blk .fromInterned(Type.childType(sema.ip, ty));
        },
        .splat => blk: {
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const ty = try sema.castDestType(block, src, extra.lhs, true);
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
            if (try sema.vectorUnary(block, src, operand, intFromPtr)) |r| break :blk r;
            break :blk sema.intFromPtr(block, src, operand);
        },
        .ptr_from_int => blk: {
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const ty = try sema.castDestType(block, src, extra.lhs, false);
            const operand = sema.resolveInst(extra.rhs);
            if (sema.vectorLen(ty)) |len| {
                const ints = try sema.coerce(block, try sema.vectorType(len, .usize_type), operand, src);
                break :blk (try sema.vectorCast(block, src, ty, ints, ptrFromInt)).?;
            }
            break :blk sema.ptrFromInt(block, src, ty, operand);
        },
        .ptr_cast => sema.analyzePtrCast(block, inst, .{ .ptr_cast = true }),
        .size_of, .bit_size_of => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const ty = try sema.resolveType(block, src, data.un_node.operand);
            try sema.resolveLayout(block, src, ty);
            const size = if (Type.hasRuntimeBits(sema.ip, ty)) Type.abiSize(sema.ip, ty) else 0;
            const bits = if (tag == .size_of) size else bitSize(sema.ip, ty);
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
            const cap = captures[ext.small];
            if (sema.ip.indexToKey(cap) == .nav_capture) {
                // A captured declaration resolves when it is read.
                const c = sema.ip.indexToKey(cap).nav_capture;
                const src = block.nodeSrc(@enumFromInt(@as(i32, @bitCast(ext.operand))));
                break :blk if (c.by_ref) sema.navRef(block, src, c.nav) else sema.navVal(block, src, c.nav);
            }
            if (sema.ip.indexToKey(cap) == .runtime_capture) {
                // Only its type is known; as upstream, only `@TypeOf` reads it.
                const src = block.nodeSrc(@enumFromInt(@as(i32, @bitCast(ext.operand))));
                if (!block.is_typeof) return sema.fail(block, src, "variable not accessible from inner function", .{});
                break :blk sema.addTyOp(block, .bitcast, sema.ip.indexToKey(cap).runtime_capture, .fromInterned(try sema.undefValue(sema.ip.indexToKey(cap).runtime_capture)));
            }
            break :blk .fromInterned(cap);
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
            const alignment: u64 = if (small.has_align) blk2: {
                const align_ref = try sema.coerce(block, .u29_type, sema.resolveInst(@fromBackingInt(sema.code.extra[extra.end + @intFromBool(small.has_type)])), src);
                break :blk2 sema.ip.intValue(u64, try sema.resolveConstValue(block, src, align_ref, "alignment must be comptime-known")).?;
            } else 0;
            if (!small.has_type) {
                const ref = try sema.allocInferred(block, small.is_const, small.is_comptime);
                if (alignment != 0) {
                    if (ref.toIndex()) |i| {
                        sema.inferred_allocs.getPtr(i).?.alignment = alignment;
                    } else {
                        const id = sema.ip.indexToKey(sema.resolveValue(ref).?).ptr.base.comptime_alloc;
                        sema.comptime_allocs.getPtr(id).?.alignment = alignment;
                    }
                }
                break :blk ref;
            }
            const ty = try sema.resolveType(block, src, @fromBackingInt(sema.code.extra[extra.end]));
            const ptr = try sema.analyzeAlloc(block, src, ty, small.is_const, small.is_comptime);
            if (alignment != 0) {
                try sema.resolveLayout(block, src, ty);
                const ptr_ty = try sema.allocPtrType(ty, alignment);
                const alloc_inst = ptr.toIndex() orelse {
                    // A comptime variable: the same allocation, through the
                    // aligned pointer type.
                    var k = sema.ip.indexToKey(sema.resolveValue(ptr).?).ptr;
                    var info = Type.ptrInfo(sema.ip, ptr_ty);
                    info.flags.is_const = Type.ptrInfo(sema.ip, k.ty).flags.is_const;
                    k.ty = try sema.ptrType(info);
                    break :blk .fromInterned(try sema.intern(.{ .ptr = k }));
                };
                sema.ir_insts.items(.data)[@backingInt(alloc_inst)] = .{ .ty = ptr_ty };
            }
            break :blk ptr;
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
            const oc = Type.class(sema.ip, Type.scalarType(sema.ip, sema.typeOf(operand)));
            if (oc != .float and oc != .comptime_float) return sema.fail(block, src, "expected float or vector type, found '{f}'", .{sema.fmtType(sema.typeOf(operand))});
            break :blk switch (Type.class(sema.ip, Type.scalarType(sema.ip, dest_ty))) {
                .float, .comptime_float => sema.analyzeFloatUnary(block, src, op, try sema.coerce(block, dest_ty, operand, src)),
                .int, .comptime_int => if (sema.vectorLen(dest_ty)) |len|
                    sema.vectorMap(block, src, len, dest_ty, &.{operand}, struct {
                        elem_ty: Index,
                        mode: IntFromFloatMode,
                        fn call(o: @This(), s: *Sema, b: *Block, sr: Src, e: []const Ref) CompileError!Ref {
                            return s.analyzeFloatToInt(b, sr, o.elem_ty, e[0], o.mode);
                        }
                    }{ .elem_ty = Type.childType(sema.ip, dest_ty), .mode = mode })
                else
                    sema.analyzeFloatToInt(block, src, dest_ty, operand, mode),
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
        .breakpoint => blk: {
            const src = block.nodeSrc(@enumFromInt(@as(i32, @bitCast(ext.operand))));
            if (block.is_comptime) return sema.fail(block, src, "encountered @breakpoint at comptime", .{});
            _ = try sema.addInst(block, .{ .tag = .breakpoint, .data = .{ .no_op = {} } });
            break :blk .void_value;
        },
        // A prefetch is only a hint; zap's code does without it, as
        // upstream's Debug x86_64 backend may.
        .prefetch => blk: {
            const extra = sema.code.extraData(Zir.Inst.BinNode, ext.operand).data;
            const src = block.nodeSrc(extra.node);
            const ptr = sema.resolveInst(extra.lhs);
            if (Type.class(sema.ip, sema.typeOf(ptr)) != .pointer) return sema.fail(block, src, "expected pointer, found '{f}'", .{sema.fmtType(sema.typeOf(ptr))});
            const opts_ty = try sema.analyzeAsType(block, src, try sema.stdLangDecl(block, src, "PrefetchOptions"));
            _ = try sema.resolveConstValue(block, src, try sema.coerce(block, opts_ty, sema.resolveInst(extra.rhs), src), "prefetch options must be comptime-known");
            break :blk .void_value;
        },
        // Optimized float mode only licenses an optimizer; without one, as
        // in upstream's Debug backends, float operations are the same.
        .set_float_mode => blk: {
            const extra = sema.code.extraData(Zir.Inst.UnNode, ext.operand).data;
            _ = try sema.resolveConstValue(block, block.nodeSrc(extra.node), sema.resolveInst(extra.operand), "operand to @setFloatMode must be comptime-known");
            break :blk .void_value;
        },
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
        .reify_fn => sema.zirReifyFn(block, ext),
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
            // As upstream, the operands are analyzed for their types only,
            // as runtime code even in a comptime scope.
            child.is_comptime = false;
            child.is_typeof = true;
            _ = try sema.analyzeInlineBody(&child, body, inst);
            const refs = try sema.arena.alloc(Ref, ext.small);
            for (refs, 0..) |*r, k| r.* = sema.resolveInst(@fromBackingInt(sema.code.extra[extra.end + k]));
            break :blk .fromInterned(try sema.resolvePeerTypes(block, src, refs));
        },
        .builtin_extern => sema.zirBuiltinExtern(block, inst),
        .field_parent_ptr => sema.zirFieldParentPtr(block, inst),
        .cmpxchg => sema.zirCmpxchg(block, inst),
        .c_va_start => blk: {
            const src = block.nodeSrc(@fromBackingInt(@as(i32, @bitCast(ext.operand))));
            if (sema.func == .none or !sema.ip.indexToKey(sema.ip.typeOf(sema.func)).func_type.is_var_args or block.inlining != null)
                break :blk sema.fail(block, src, "'@cVaStart' only allowed in variadic functions", .{});
            try sema.requireRuntime(block, src);
            break :blk sema.addInst(block, .{ .tag = .c_va_start, .data = .{ .ty = try sema.stdLangType(block, src, "VaList") } });
        },
        .c_va_arg => blk: {
            const extra = sema.code.extraData(Zir.Inst.BinNode, ext.operand).data;
            const src = block.nodeSrc(extra.node);
            const list = try sema.vaListPtr(block, src, extra.lhs);
            const ty = try sema.resolveType(block, src, extra.rhs);
            try sema.resolveLayout(block, src, ty);
            try sema.requireRuntime(block, src);
            break :blk sema.addTyOp(block, .c_va_arg, ty, list);
        },
        .c_va_copy => blk: {
            const extra = sema.code.extraData(Zir.Inst.UnNode, ext.operand).data;
            const src = block.nodeSrc(extra.node);
            const list = try sema.vaListPtr(block, src, extra.operand);
            try sema.requireRuntime(block, src);
            break :blk sema.addTyOp(block, .c_va_copy, try sema.stdLangType(block, src, "VaList"), list);
        },
        // Ending a `VaList` does nothing on x86_64.
        .c_va_end => blk: {
            const extra = sema.code.extraData(Zir.Inst.UnNode, ext.operand).data;
            _ = try sema.vaListPtr(block, block.nodeSrc(extra.node), extra.operand);
            break :blk .void_value;
        },
        .error_cast => sema.zirErrorCast(block, inst),
        // Error values are numbered at link time, so these are runtime
        // operations even on comptime-known operands.
        .int_from_error, .error_from_int => blk: {
            const extra = sema.code.extraData(Zir.Inst.UnNode, ext.operand).data;
            const src = block.nodeSrc(extra.node);
            const to_int = ext.opcode == .int_from_error;
            const operand = try sema.coerce(block, if (to_int) .anyerror_type else .u16_type, sema.resolveInst(extra.operand), src);
            // Comptime-known operands use this compilation's codes, which
            // the manifest keeps stable across rebuilds (see "Error codes"
            // in docs/architecture.md).
            if (sema.resolveValue(operand)) |v| if (!sema.isUndef(v)) {
                const ip = sema.ip;
                if (to_int) break :blk .fromInterned(try sema.intValue(.u16_type, try ip.errorValue(ip.indexToKey(v).err.name)));
                const code = ip.intValue(u64, v).?;
                const name = name: {
                    ip.errors_mutex.lockUncancelable(ip.io);
                    defer ip.errors_mutex.unlock(ip.io);
                    if (code == 0 or code >= ip.error_names.items.len) break :name null;
                    break :name ip.error_names.items[@intCast(code)];
                } orelse break :blk sema.fail(block, src, "integer value '{d}' represents no error", .{code});
                break :blk .fromInterned(try sema.intern(.{ .err = .{ .ty = .anyerror_type, .name = name } }));
            };
            // An error set of zero or one names has one code, as upstream.
            if (to_int) {
                const op_ty = sema.typeOf(sema.resolveInst(extra.operand));
                if (op_ty != .anyerror_type and Type.class(sema.ip, op_ty) == .error_set) {
                    if (try sema.errorSetNames(block, src, op_ty)) |names| switch (names.len) {
                        0 => break :blk .fromInterned(try sema.intValue(.u16_type, 0)),
                        1 => break :blk .fromInterned(try sema.intValue(.u16_type, try sema.ip.errorValue(names[0]))),
                        else => {},
                    };
                }
            }
            if (block.is_comptime) break :blk sema.fail(block, src, "unable to evaluate comptime expression", .{});
            break :blk sema.addTyOp(block, .bitcast, if (to_int) .u16_type else .anyerror_type, operand);
        },
        .ret_addr, .frame_address => blk: {
            // Zero at comptime, as upstream.
            if (block.is_comptime) break :blk .fromInterned(.zero_usize);
            break :blk sema.addInst(block, .{ .tag = if (ext.opcode == .ret_addr) .ret_addr else .frame_addr, .data = .{ .no_op = {} } });
        },
        // zap keeps no error return traces yet: there is never one to show.
        .error_return_trace => blk: {
            const src = block.nodeSrc(.zero);
            const trace_ptr = try sema.ptrType(.{ .child = try sema.stdLangType(block, src, "StackTrace") });
            break :blk .fromInterned(try sema.intern(.{ .opt = .{ .ty = try sema.optType(trace_ptr), .val = .none } }));
        },
        .builtin_src => sema.zirBuiltinSrc(block, ext),
        else => sema.failUnsupported(block, block.nodeSrc(.zero), @tagName(ext.opcode)),
    };
}

/// `@embedFile(path)`: the file's bytes as a string literal. The path is
/// relative to the current file and must stay inside its module.
fn zirEmbedFile(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].un_node;
    const src = block.nodeSrc(data.src_node);
    const name = try sema.resolveConstString(block, src, sema.resolveInst(data.operand));
    if (name.len == 0) return sema.fail(block, src, "file path name cannot be empty", .{});
    const file = sema.zcu.file(sema.file);
    const module = sema.zcu.fe.module(file.module);
    const root: []const u8 = module.abs_root_dir orelse
        std.Io.Dir.cwd().realPathFileAlloc(sema.zcu.fe.io, module.root_dir, sema.arena) catch |err|
            return sema.fail(block, src, "unable to resolve module directory '{s}': {t}", .{ module.root_dir, err });
    const dir = std.fs.path.dirname(file.sub_path) orelse "";
    const full = try std.fs.path.resolveAllocPosix(sema.arena, &.{ root, dir, name });
    if (full.len <= root.len + 1 or !std.mem.startsWith(u8, full, root) or full[root.len] != '/')
        return sema.fail(block, src, "embed of file outside package path: '{s}'", .{name});
    const sub_path = full[root.len + 1 ..];
    const index = sema.zcu.embedFile(file.module, sub_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return sema.fail(block, src, "unable to open '{s}': {t}", .{ name, err }),
    };
    try sema.declareDependency(.{ .embed_file = index });
    return .fromInterned(try sema.stringLiteral(sema.zcu.embed_files.values()[index].bytes));
}

/// `@src()`: a `std.builtin.SourceLocation` of the enclosing function, as
/// upstream: its simple name, its file's path in its module, and the
/// 1-based line and column.
fn zirBuiltinSrc(sema: *Sema, block: *Block, ext: Zir.Inst.Extended.InstData) CompileError!Ref {
    const ip = sema.ip;
    const extra = sema.code.extraData(Zir.Inst.Src, ext.operand).data;
    const src = block.nodeSrc(extra.node);
    const func = if (block.inlining) |inlining| inlining.func else sema.func;
    if (func == .none) return sema.fail(block, src, "@src outside function", .{});
    const fn_name = ip.stringSlice(ip.getNav(ip.indexToKey(func).func.owner_nav).name);
    const file = sema.zcu.file(sema.file);
    // Upstream's module names: `test` for the module under test, the root
    // file's stem for a build-exe root.
    const fe = sema.zcu.fe;
    const module = fe.module(file.module);
    const module_name = if (fe.main_module != .root and file.module == fe.main_module)
        "test"
    else if (file.module == .root and fe.main_module == .root)
        std.fs.path.stem(module.root_file)
    else
        module.name;
    const strings = [_][]const u8{ module_name, file.sub_path, fn_name };
    var vals: [3]Index = undefined;
    for (strings, &vals) |bytes, *v| {
        const lit: Ref = .fromInterned(try sema.stringLiteral(bytes));
        v.* = sema.resolveValue(try sema.coerce(block, .slice_const_u8_sentinel_0_type, lit, src)).?;
    }
    const ty = try sema.stdLangType(block, src, "SourceLocation");
    return .fromInterned(try sema.structValue(block, src, ty, &.{
        .{ "module", vals[0] },
        .{ "file", vals[1] },
        .{ "fn_name", vals[2] },
        .{ "line", try sema.intValue(.u32_type, extra.line + 1) },
        .{ "column", try sema.intValue(.u32_type, extra.column + 1) },
    }));
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
    try sema.resolveStructDefaults(block, src, ty);
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
            try sema.resolveStructDefaults(block, src, ty);
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
                    is_comptime = ip.structInfo(ty).fieldIsComptime(i);
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
                if (generic or (i < 32 and (f.comptime_bits >> @intCast(i)) & 1 != 0) or (!generic and (try sema.isComptimeOnlyResolved(block, src, pt)))) is_generic = true;
                t.* = try sema.intern(.{ .opt = .{ .ty = opt_type, .val = if (generic) .none else pt } });
                a.* = try sema.structValue(block, src, pattrs_ty, &[_]S{.{ "noalias", boolValue(i < 32 and (f.noalias_bits >> @intCast(i)) & 1 != 0) }});
            }
            const ret_generic = f.return_type == .generic_poison_type;
            if (ret_generic or (try sema.isComptimeOnlyResolved(block, src, f.return_type))) is_generic = true;
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
/// The destination type of a cast builtin from its result type: without an
/// error union, and with `remove_opt` without an optional either (inside
/// the error union, or at the top), as upstream's `resolveDestType`.
/// `@intFromPtr` of a pointer or optional pointer.
fn intFromPtr(sema: *Sema, block: *Block, src: Src, operand: Ref) CompileError!Ref {
    const ty = sema.typeOf(operand);
    // As upstream, a pointer or an optional pointer, not a slice.
    const ptr_ty = if (Type.class(sema.ip, ty) == .optional) Type.childType(sema.ip, ty) else ty;
    if (Type.class(sema.ip, ptr_ty) != .pointer or Type.isSlice(sema.ip, ptr_ty) or (ptr_ty != ty and !Type.optionalReprIsPtr(sema.ip, ptr_ty)))
        return sema.fail(block, src, "expected pointer, found '{f}'", .{sema.fmtType(ty)});
    const ptr = operand;
    if (sema.resolveValue(ptr)) |v0| {
        if (sema.isUndef(v0)) return .fromInterned(try sema.undefValue(.usize_type));
        const v = switch (sema.ip.indexToKey(v0)) {
            .opt => |o| if (o.val == .none) return .fromInterned(try sema.intValue(.usize_type, 0)) else o.val,
            else => v0,
        };
        if (sema.ip.indexToKey(v) == .ptr and sema.ip.indexToKey(v).ptr.base == .int)
            return .fromInterned(try sema.intValue(.usize_type, sema.ip.indexToKey(v).ptr.byte_offset));
    }
    if (block.is_comptime) return sema.fail(block, src, "unable to evaluate comptime expression: pointer address is not known until link time", .{});
    return sema.addUnOp(block, .int_from_ptr, ptr);
}

/// `@ptrFromInt` of an address to pointer type `ty`.
fn ptrFromInt(sema: *Sema, block: *Block, src: Src, ty: Index, uncasted: Ref) CompileError!Ref {
    const operand = try sema.coerce(block, .usize_type, uncasted, src);
    if (try sema.resolveDefinedValue(block, src, operand)) |v| {
        const addr = sema.ip.intValue(u64, v).?;
        // A non-null optional pointer is an `opt` around its pointer.
        if (Type.class(sema.ip, ty) == .optional) {
            if (addr == 0) return .fromInterned(try sema.intern(.{ .opt = .{ .ty = ty, .val = .none } }));
            const ptr = try sema.intern(.{ .ptr = .{ .ty = Type.childType(sema.ip, ty), .base = .int, .byte_offset = addr } });
            return .fromInterned(try sema.intern(.{ .opt = .{ .ty = ty, .val = ptr } }));
        }
        if (addr == 0 and !Type.ptrInfo(sema.ip, ty).flags.is_allowzero and Type.ptrInfo(sema.ip, ty).flags.size != .c)
            return sema.fail(block, src, "pointer type '{f}' does not allow address zero", .{sema.fmtType(ty)});
        return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = ty, .base = .int, .byte_offset = addr } }));
    }
    return sema.addTyOp(block, .ptr_from_int, ty, operand);
}

fn castDestType(sema: *Sema, block: *Block, src: Src, ref: Zir.Inst.Ref, remove_opt: bool) CompileError!Index {
    const ip = sema.ip;
    var ty = try sema.resolveType(block, src, ref);
    if (ip.indexToKey(ty) == .error_union_type) ty = ip.indexToKey(ty).error_union_type.payload_type;
    if (remove_opt and ip.indexToKey(ty) == .opt_type) ty = ip.indexToKey(ty).opt_type;
    return ty;
}

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
    if (nav.is_const and !isExternVar(sema.ip, nav)) return .fromInterned(nav.val);
    return sema.analyzeLoad(block, src, try sema.navRef(block, src, nav_index));
}

fn navRef(sema: *Sema, block: *Block, src: Src, nav_index: InternPool.NavIndex) CompileError!Ref {
    const pending = sema.ip.getNav(nav_index);
    if (pending.status == .resolving and pending.ty != .none and pending.linkage == .normal and !pending.is_threadlocal) {
        // Its own initializer (or one it depends on): the address needs
        // only the declared type.
        if (nav_index != sema.owner_nav) try sema.declareDependency(.{ .nav_val = nav_index });
        const alignment: u6 = if (pending.alignment == 0 or sema.naturalAlignment(pending.ty) == pending.alignment) 0 else @intCast(std.math.log2_int(u64, pending.alignment) + 1);
        const ptr_ty = try sema.ptrType(.{ .child = pending.ty, .flags = .{ .is_const = pending.is_const, .alignment = alignment } });
        return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = ptr_ty, .base = .{ .nav = nav_index } } }));
    }
    try sema.ensureNavVal(block, src, nav_index);
    const nav = sema.ip.getNav(nav_index);
    // A generic function has no body of its own until a call instantiates it.
    if (sema.ip.indexToKey(nav.val) == .func and !sema.ip.indexToKey(nav.ty).func_type.is_generic) try sema.zcu.queueFuncFrom(sema.owner, nav.val);
    // A referenced variable is emitted with its type's layout (`var global:
    // @This()` inside the struct leaves it unresolved until now).
    if (!nav.is_const) try sema.resolveLayoutIfIdle(block, src, nav.ty);
    // An explicit alignment shows in the pointer type, as upstream, even
    // when it is the natural one (`&f` for `fn f() align(1)`).
    const alignment: u6 = if (nav.alignment == 0) 0 else @intCast(std.math.log2_int(u64, nav.alignment) + 1);
    const ptr_ty = try sema.ptrType(.{ .child = nav.ty, .flags = .{ .is_const = nav.is_const, .alignment = alignment } });
    // The address of an extern variable or function is known at link time.
    if (nav.linkage == .@"extern") {
        if (block.is_comptime) return sema.fail(block, src, "unable to evaluate comptime expression: zap resolves extern symbols at link time", .{});
        return sema.addInst(block, .{ .tag = .extern_ptr, .data = .{ .ty_pl = .{ .ty = ptr_ty, .payload = @backingInt(nav.name) } } });
    }
    // Each thread has its own copy of a threadlocal variable, at an offset
    // from the thread pointer.
    if (nav.is_threadlocal and !block.is_comptime) {
        return sema.addInst(block, .{ .tag = .tls_ptr, .data = .{ .ty_pl = .{ .ty = ptr_ty, .payload = @backingInt(nav_index) } } });
    }
    return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = ptr_ty, .base = .{ .nav = nav_index } } }));
}

fn isExternVar(ip: *const InternPool, nav: *const InternPool.Nav) bool {
    return nav.linkage == .@"extern" and ip.indexToKey(nav.val) != .extern_func;
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
        .uav => |v| {
            try sema.zcu.exports.append(sema.gpa, .{ .target = .{ .uav = v.val }, .name = try sema.getString(name) });
            return;
        },
        else => return sema.fail(block, src, "export target must be a global variable or a comptime-known constant", .{}),
    };
    try sema.ensureNavVal(block, src, nav_index);
    const val = ip.getNav(nav_index).val;
    const export_nav = switch (ip.indexToKey(val)) {
        .func => |f| f.owner_nav,
        else => nav_index,
    };
    if (ip.indexToKey(val) == .func) try sema.zcu.queueFuncFrom(sema.owner, val);
    try sema.zcu.exports.append(sema.gpa, .{ .target = .{ .nav = export_nav }, .name = try sema.getString(name) });
}

/// `@extern(T, .{ .name = ... })`: the address of a symbol defined
/// elsewhere in the link. zap links everything it compiles into one static
/// executable, so the symbol is one of the compilation's exports; an
/// undefined weak symbol is null. The address is a runtime value, read from
/// a slot the link fills in (see `Emit.finish`).
fn zirBuiltinExtern(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ip = sema.ip;
    const ext = sema.code.instructions.items(.data)[@backingInt(inst)].extended;
    const extra = sema.code.extraData(Zir.Inst.BinNode, ext.operand).data;
    const src = block.nodeSrc(extra.node);
    var ty = try sema.resolveType(block, src, extra.lhs);
    const ptr_ty = if (Type.class(ip, ty) == .optional) Type.childType(ip, ty) else ty;
    if (Type.class(ip, ptr_ty) != .pointer or Type.isSlice(ip, ptr_ty)) return sema.fail(block, src, "expected (optional) pointer", .{});
    const options_ty = try sema.stdLangType(block, src, "ExternOptions");
    const options = try sema.resolveConstValue(block, src, try sema.coerce(block, options_ty, sema.resolveInst(extra.rhs), src), "extern options must be comptime-known");
    const info = ip.structInfo(options_ty);
    const name = try sema.resolveConstString(block, src, .fromInterned(try sema.fieldValue(options, info.fieldIndex(ip, "name").?)));
    const linkage = try sema.fieldValue(options, info.fieldIndex(ip, "linkage").?);
    const is_weak = ip.intValue(u64, ip.indexToKey(linkage).enum_tag.int).? == @backingInt(std.lang.GlobalLinkage.weak);
    if (try sema.fieldValue(options, info.fieldIndex(ip, "is_thread_local").?) == .bool_true)
        return sema.failUnsupported(block, src, "thread-local externs");
    if (is_weak and Type.class(ip, ty) != .optional) ty = try sema.optType(ty);
    // A function's address is a comptime-known pointer to the extern
    // function, which CodeGen reads from the slot the link fills.
    if (!is_weak and Type.class(ip, ty) == .pointer and Type.class(ip, Type.ptrInfo(ip, ty).child) == .@"fn") {
        const f = try sema.intern(.{ .extern_func = .{ .name = try sema.getString(name), .ty = Type.ptrInfo(ip, ty).child, .is_weak = false } });
        return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = ty, .base = .{ .uav = .{ .val = f, .orig_ty = ty } } } }));
    }
    if (block.is_comptime) return sema.fail(block, src, "unable to evaluate comptime expression: zap resolves extern symbols at link time", .{});
    return sema.addInst(block, .{ .tag = .extern_ptr, .data = .{ .ty_pl = .{ .ty = ty, .payload = @backingInt(try sema.getString(name)) } } });
}

// Atomics. x86_64 loads and stores are atomic for every ordering zap
// needs; stores, read-modify-writes, and cmpxchg use locked instructions,
// which are sequentially consistent, so orderings are only validated.

fn atomicOrder(sema: *Sema, block: *Block, src: Src, ref: Zir.Inst.Ref) CompileError!void {
    const ty = try sema.stdLangType(block, src, "AtomicOrder");
    _ = try sema.resolveConstValue(block, src, try sema.coerce(block, ty, sema.resolveInst(ref), src), "atomic ordering must be comptime-known");
}

fn atomicElemType(sema: *Sema, block: *Block, src: Src, ty: Index) CompileError!void {
    const ip = sema.ip;
    try sema.resolveLayout(block, src, ty);
    const ok = switch (Type.class(ip, ty)) {
        .int, .bool, .@"enum", .float => true,
        .pointer => !Type.isSlice(ip, ty),
        .optional => Type.optionalReprIsPtr(ip, Type.childType(ip, ty)),
        .@"struct" => Type.isPacked(ip, ty),
        else => false,
    };
    if (!ok) return sema.fail(block, src, "expected bool, integer, float, enum, packed struct, or pointer type; found '{f}'", .{sema.fmtType(ty)});
    const size = Type.abiSize(ip, ty);
    // Zero-bit types (u0) fold: every value is the same.
    if (size != 0 and size != 1 and size != 2 and size != 4 and size != 8) return sema.failUnsupported(block, src, "atomics on types of this size");
}

/// The pointer operand of an atomic builtin, as a pointer to `elem_ty`.
fn atomicPtr(sema: *Sema, block: *Block, src: Src, ref: Zir.Inst.Ref, is_const: bool) CompileError!struct { Ref, Index } {
    const ip = sema.ip;
    const ptr = sema.resolveInst(ref);
    const ptr_ty = sema.typeOf(ptr);
    if (Type.class(ip, ptr_ty) != .pointer or Type.ptrInfo(ip, ptr_ty).flags.size != .one)
        return sema.fail(block, src, "expected single pointer, found '{f}'", .{sema.fmtType(ptr_ty)});
    const info = Type.ptrInfo(ip, ptr_ty);
    if (!is_const and info.flags.is_const) return sema.fail(block, src, "cannot assign to constant", .{});
    try sema.atomicElemType(block, src, info.child);
    return .{ ptr, info.child };
}

/// `const a, const b = operand;`: the operand must be an array, vector, or
/// tuple of the destructured length. The elements are read by `elem_val_imm`.
fn zirValidateDestructure(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!void {
    const ip = sema.ip;
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.ValidateDestructure, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    const ty = sema.typeOf(sema.resolveInst(extra.operand));
    const len: u64 = switch (ip.indexToKey(ty)) {
        .array_type => |a| a.len,
        .vector_type => |v| v.len,
        .tuple_type => |t| t.types.len,
        else => return sema.fail(block, src, "type '{f}' cannot be destructured", .{sema.fmtType(ty)}),
    };
    if (len != extra.expect_len) return sema.fail(block, src, "expected {d} elements for destructure, found {d}", .{ extra.expect_len, len });
}

fn zirAtomicLoad(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.AtomicLoad, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    const elem_ty = try sema.resolveType(block, src, extra.elem_type);
    try sema.atomicElemType(block, src, elem_ty);
    const ptr = try sema.coerce(block, try sema.ptrType(.{ .child = elem_ty, .flags = .{ .is_const = true } }), sema.resolveInst(extra.ptr), src);
    try sema.atomicOrder(block, src, extra.ordering);
    if (block.is_comptime or Type.abiSize(sema.ip, elem_ty) == 0) return sema.analyzeLoad(block, src, ptr);
    return sema.addTyOp(block, .atomic_load, elem_ty, ptr);
}

fn zirAtomicStore(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.AtomicStore, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    const ptr, const elem_ty = try sema.atomicPtr(block, src, extra.ptr, false);
    const operand = try sema.coerce(block, elem_ty, sema.resolveInst(extra.operand), src);
    try sema.atomicOrder(block, src, extra.ordering);
    if (Type.abiSize(sema.ip, elem_ty) == 0) return .void_value;
    if (block.is_comptime) {
        try sema.analyzeStore(block, src, ptr, operand);
    } else {
        _ = try sema.addBinOp(block, .atomic_store, ptr, operand);
    }
    return .void_value;
}

fn zirAtomicRmw(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ip = sema.ip;
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.AtomicRmw, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    const ptr, const elem_ty = try sema.atomicPtr(block, src, extra.ptr, false);
    const op_ty = try sema.stdLangType(block, src, "AtomicRmwOp");
    const op_val = try sema.resolveConstValue(block, src, try sema.coerce(block, op_ty, sema.resolveInst(extra.operation), src), "atomic operation must be comptime-known");
    const op: std.lang.AtomicRmwOp = @fromBackingInt(@intCast(ip.intValue(u64, ip.indexToKey(op_val).enum_tag.int).?));
    const operand = try sema.coerce(block, elem_ty, sema.resolveInst(extra.operand), src);
    try sema.atomicOrder(block, src, extra.ordering);
    const class = Type.class(ip, elem_ty);
    // Integers, packed structs, and pointers allow every operation.
    switch (class) {
        .@"enum" => if (op != .Xchg) return sema.fail(block, src, "@atomicRmw with enum only allowed with .Xchg", .{}),
        .bool => if (op != .Xchg) return sema.fail(block, src, "@atomicRmw with bool only allowed with .Xchg", .{}),
        .float => switch (op) {
            .Xchg, .Add, .Sub, .Max, .Min => {},
            else => return sema.fail(block, src, "@atomicRmw with float only allowed with .Xchg, .Add, .Sub, .Max, and .Min", .{}),
        },
        else => {},
    }
    if (block.is_comptime) {
        if (op != .Xchg and class != .int and class != .float) return sema.failUnsupported(block, src, "comptime @atomicRmw on this type");
        const old = try sema.analyzeLoad(block, src, ptr);
        const new: Ref = switch (op) {
            .Xchg => operand,
            .Add => try sema.analyzeArithmetic(block, src, if (class == .float) .add else .addwrap, old, operand),
            .Sub => try sema.analyzeArithmetic(block, src, if (class == .float) .sub else .subwrap, old, operand),
            .And => try sema.analyzeArithmetic(block, src, .bit_and, old, operand),
            .Or => try sema.analyzeArithmetic(block, src, .bit_or, old, operand),
            .Xor => try sema.analyzeArithmetic(block, src, .xor, old, operand),
            .Nand => try sema.analyzeBitNot(block, src, try sema.analyzeArithmetic(block, src, .bit_and, old, operand)),
            .Max => try sema.analyzeMinMax(block, src, .max, &.{ old, operand }),
            .Min => try sema.analyzeMinMax(block, src, .min, &.{ old, operand }),
        };
        try sema.analyzeStore(block, src, ptr, new);
        return old;
    }
    if (Type.abiSize(ip, elem_ty) == 0) return sema.analyzeLoad(block, src, ptr);
    if (class == .float and op != .Xchg and Type.floatBits(ip, elem_ty) != 32 and Type.floatBits(ip, elem_ty) != 64)
        return sema.failUnsupported(block, src, "@atomicRmw arithmetic on f16, f80, and f128");
    const payload = try sema.addExtra(Ir.AtomicRmw{ .ptr = ptr, .operand = operand, .op = @backingInt(op) });
    return sema.addInst(block, .{ .tag = .atomic_rmw, .data = .{ .ty_pl = .{ .ty = elem_ty, .payload = payload } } });
}

/// `@cmpxchgStrong` and `@cmpxchgWeak`.
fn zirCmpxchg(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ip = sema.ip;
    const ext = sema.code.instructions.items(.data)[@backingInt(inst)].extended;
    const extra = sema.code.extraData(Zir.Inst.Cmpxchg, ext.operand).data;
    const src = block.nodeSrc(extra.node);
    const ptr, const elem_ty = try sema.atomicPtr(block, src, extra.ptr, false);
    if (Type.class(ip, elem_ty) == .float) return sema.fail(block, src, "expected bool, integer, enum, packed struct, or pointer type; found '{f}'", .{sema.fmtType(elem_ty)});
    const expected = try sema.coerce(block, elem_ty, sema.resolveInst(extra.expected_value), src);
    const new = try sema.coerce(block, elem_ty, sema.resolveInst(extra.new_value), src);
    try sema.atomicOrder(block, src, extra.success_order);
    try sema.atomicOrder(block, src, extra.failure_order);
    const result_ty = try sema.optType(elem_ty);
    try sema.resolveLayout(block, src, result_ty);
    if (block.is_comptime or Type.abiSize(ip, elem_ty) == 0) {
        const old = try sema.analyzeLoad(block, src, ptr);
        const eq = try sema.analyzeCmp(block, src, .eq, old, expected);
        if (sema.resolveValue(eq) == .bool_true) {
            try sema.analyzeStore(block, src, ptr, new);
            return .fromInterned(try sema.intern(.{ .opt = .{ .ty = result_ty, .val = .none } }));
        }
        return sema.coerce(block, result_ty, old, src);
    }
    const payload = try sema.addExtra(Ir.Cmpxchg{ .ptr = ptr, .expected = expected, .new = new });
    return sema.addInst(block, .{ .tag = .cmpxchg, .data = .{ .ty_pl = .{ .ty = result_ty, .payload = payload } } });
}

/// `@errorCast(x)`: an error set or error union as another error set
/// (or error union with the same payload), checking at runtime that the
/// error is in the destination set.
fn zirErrorCast(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ip = sema.ip;
    const ext = sema.code.instructions.items(.data)[@backingInt(inst)].extended;
    const extra = sema.code.extraData(Zir.Inst.BinNode, ext.operand).data;
    const src = block.nodeSrc(extra.node);
    var dest_ty = try sema.resolveType(block, src, extra.lhs);
    if (ip.indexToKey(dest_ty) == .opt_type) dest_ty = ip.indexToKey(dest_ty).opt_type;
    const operand = sema.resolveInst(extra.rhs);
    const operand_ty = sema.typeOf(operand);
    const dest_class = Type.class(ip, dest_ty);
    const operand_class = Type.class(ip, operand_ty);
    if ((dest_class != .error_set and dest_class != .error_union) or (operand_class != .error_set and operand_class != .error_union))
        return sema.fail(block, src, "expected error set or error union type, found '{f}'", .{sema.fmtType(if (dest_class != .error_set and dest_class != .error_union) dest_ty else operand_ty)});
    if (dest_class == .error_set and operand_class == .error_union) return sema.fail(block, src, "cannot cast an error union type to error set", .{});
    if (dest_class == .error_union and operand_class == .error_union and
        ip.indexToKey(dest_ty).error_union_type.payload_type != ip.indexToKey(operand_ty).error_union_type.payload_type)
        return sema.fail(block, src, "payload types of error unions must match", .{});
    const dest_set = if (dest_class == .error_union) ip.indexToKey(dest_ty).error_union_type.error_set_type else dest_ty;
    const operand_set = if (operand_class == .error_union) ip.indexToKey(operand_ty).error_union_type.error_set_type else operand_ty;
    const superset = try sema.errorSetCoercible(block, src, operand_set, dest_set, .none);
    const dest_names = try sema.errorSetNames(block, src, dest_set);

    if (sema.resolveValue(operand)) |v| if (!sema.isUndef(v)) {
        const name = switch (ip.indexToKey(v)) {
            .err => |e| e.name,
            .error_union => |eu| switch (eu.val) {
                .err_name => |n| n,
                .payload => |pv| return .fromInterned(try sema.intern(.{ .error_union = .{ .ty = dest_ty, .val = .{ .payload = pv } } })),
            },
            else => unreachable,
        };
        if (!superset) if (dest_names) |names| {
            for (names) |n| {
                if (n == name) break;
            } else return sema.fail(block, src, "'error.{s}' not a member of error set '{f}'", .{ ip.stringSlice(name), sema.fmtType(dest_set) });
        };
        return .fromInterned(try sema.intern(if (dest_class == .error_set)
            .{ .err = .{ .ty = dest_ty, .name = name } }
        else
            .{ .error_union = .{ .ty = dest_ty, .val = .{ .err_name = name } } }));
    };
    try sema.requireRuntime(block, src);
    if (block.want_safety and !superset) if (dest_names) |names| {
        // The error, if there is one, must be one of the destination's.
        const code = if (operand_class == .error_union) try sema.addTyOp(block, .unwrap_errunion_err, operand_set, operand) else operand;
        var ok: Ref = if (operand_class == .error_union) try sema.analyzeIsNonErr(block, src, operand) else .fromInterned(.bool_false);
        for (names) |n| {
            const err: Ref = .fromInterned(try sema.intern(.{ .err = .{ .ty = operand_set, .name = n } }));
            const eq = try sema.addBinOp(block, .cmp_eq, code, err);
            ok = if (ok.toInterned() == .bool_false) eq else try sema.addBinOp(block, .bit_or, ok, eq);
        }
        try sema.addSafetyCheck(block, ok, .invalid_error_code, .none, .none);
    };
    try sema.resolveLayout(block, src, dest_ty);
    return sema.addTyOp(block, .bitcast, dest_ty, operand);
}

/// The bit offset of a struct field, for `@offsetOf` and `@bitOffsetOf`.
fn bitOffsetOf(sema: *Sema, block: *Block, src: Src, extra: Zir.Inst.Bin) CompileError!u64 {
    const ip = sema.ip;
    const ty = try sema.resolveType(block, src, extra.lhs);
    const name = try sema.resolveConstString(block, src, sema.resolveInst(extra.rhs));
    try sema.resolveLayout(block, src, ty);
    switch (ip.indexToKey(ty)) {
        .struct_type => {
            const i = try sema.structFieldIndex(block, src, ty, name);
            if (ip.structInfo(ty).fieldIsComptime(i)) return sema.fail(block, src, "no offset available for comptime field", .{});
            if (Type.isPacked(ip, ty)) return Type.packedFieldBitOffset(ip, ty, i);
            return Type.fieldOffset(ip, ty, i) * 8;
        },
        .tuple_type => |t| {
            const i = try sema.structFieldIndex(block, src, ty, name);
            if (t.values[i] != .none) return sema.fail(block, src, "no offset available for comptime field", .{});
            return Type.fieldOffset(ip, ty, i) * 8;
        },
        else => return sema.fail(block, src, "expected struct type, found '{f}'", .{sema.fmtType(ty)}),
    }
}

/// `@fieldParentPtr("field", field_ptr)`: the pointer to the struct or
/// union containing the field `field_ptr` points to.
fn zirFieldParentPtr(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ip = sema.ip;
    const ext = sema.code.instructions.items(.data)[@backingInt(inst)].extended;
    const extra = sema.code.extraData(Zir.Inst.FieldParentPtr, ext.operand).data;
    const src = block.nodeSrc(extra.src_node);
    const dest_ty = try sema.castDestType(block, src, extra.parent_ptr_type, false);
    if (Type.class(ip, dest_ty) != .pointer or Type.ptrInfo(ip, dest_ty).flags.size != .one)
        return sema.fail(block, src, "expected single pointer type, found '{f}'", .{sema.fmtType(dest_ty)});
    const parent_ty = Type.ptrInfo(ip, dest_ty).child;
    const name = try sema.resolveConstString(block, src, sema.resolveInst(extra.field_name));
    try sema.resolveLayout(block, src, parent_ty);
    const field_index: u32 = switch (ip.indexToKey(parent_ty)) {
        .struct_type => try sema.structFieldIndex(block, src, parent_ty, name),
        .union_type => try sema.unionFieldIndex(block, src, parent_ty, name),
        .tuple_type => try sema.structFieldIndex(block, src, parent_ty, name),
        else => return sema.fail(block, src, "expected struct or union type, found '{f}'", .{sema.fmtType(parent_ty)}),
    };
    const field_ptr = sema.resolveInst(extra.field_ptr);
    if (Type.class(ip, sema.typeOf(field_ptr)) != .pointer) return sema.fail(block, src, "expected pointer, found '{f}'", .{sema.fmtType(sema.typeOf(field_ptr))});
    if (sema.resolveValue(field_ptr)) |v| if (!sema.isUndef(v)) {
        const k = ip.indexToKey(v).ptr;
        if (k.base == .field and k.base.field.index == field_index and k.byte_offset == 0 and
            Type.ptrInfo(ip, ip.typeOf(k.base.field.base)).child == parent_ty)
            return sema.coercePtrTo(block, .fromInterned(k.base.field.base), dest_ty);
    };
    try sema.requireRuntime(block, src);
    // A packed struct field's pointer has the struct's address (a bit
    // pointer into its backing integer); its type must say which field.
    if (Type.isPackedStruct(ip, parent_ty)) {
        const fp = Type.ptrInfo(ip, sema.typeOf(field_ptr));
        const dp = Type.ptrInfo(ip, dest_ty);
        if (fp.packed_offset.bit_offset != dp.packed_offset.bit_offset + Type.packedFieldBitOffset(ip, parent_ty, field_index))
            return sema.fail(block, src, "pointer type '{f}' is not a pointer to field '{s}' of '{f}'", .{ sema.fmtType(sema.typeOf(field_ptr)), name, sema.fmtType(parent_ty) });
    }
    const offset = Type.fieldOffset(ip, parent_ty, field_index);
    const addr = try sema.addUnOp(block, .int_from_ptr, field_ptr);
    const parent_addr = if (offset == 0) addr else try sema.addBinOp(block, .sub_wrap, addr, .fromInterned(try sema.intValue(.usize_type, offset)));
    return sema.addTyOp(block, .ptr_from_int, dest_ty, parent_addr);
}

fn zirImport(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_tok;
    const extra = sema.code.extraData(Zir.Inst.Import, data.payload_index).data;
    const src = block.tokSrc(data.src_tok);
    const path = sema.zirString(extra.path);
    const fe = sema.zcu.fe;
    const this_file = sema.zcu.file(sema.file);
    const key = if (fe.depModule(this_file.module, path)) |m|
        sema.zcu.moduleRootFile(m).?
    else if (std.mem.endsWith(u8, path, ".zig")) blk: {
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
    return sema.analyzeDeclLiteral(block, src, name, orig_ty, tag == .decl_literal);
}

/// `.name` with result type `orig_ty`: a declaration of `orig_ty` (or of
/// its optional or error union payload), else an enum literal.
fn analyzeDeclLiteral(sema: *Sema, block: *Block, src: Src, name: []const u8, orig_ty: Index, do_coerce: bool) CompileError!Ref {
    var ty = orig_ty;
    while (true) switch (sema.ip.indexToKey(ty)) {
        .opt_type => |c| ty = c,
        .error_union_type => |e| ty = e.payload_type,
        // As upstream, a single-item pointer looks in its child type.
        .ptr_type => |p| if (p.flags.size == .one) {
            ty = p.child;
        } else break,
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
    // No result type (an `anytype` parameter): an enum literal, as upstream.
    if (ty == .generic_poison_type or ty == .enum_literal_type or Type.class(sema.ip, ty) == .error_set)
        return .fromInterned(try sema.intern(.{ .enum_literal = try sema.getString(name) }));
    const nav = (try sema.lookupInType(ty, name)) orelse {
        // Not a declaration: an enum literal.
        const lit: Ref = .fromInterned(try sema.intern(.{ .enum_literal = try sema.getString(name) }));
        if (!do_coerce) return lit;
        return sema.coerce(block, orig_ty, lit, src);
    };
    const val = try sema.navVal(block, src, nav);
    if (!do_coerce) return val;
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
    // Only a `pub` declaration counts, even in the same file, as upstream.
    return .fromInterned(boolValue(sema.ip.getNav(nav).is_pub));
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
            // A runtime value is captured by its type (see `runtime_capture`).
            .instruction => |i| sema.resolveValue(sema.resolveInst(i.toRef())) orelse
                try sema.intern(.{ .runtime_capture = sema.typeOf(sema.resolveInst(i.toRef())) }),
            .instruction_load => |i| blk: {
                const loaded = try sema.analyzeLoad(block, src, sema.resolveInst(i.toRef()));
                break :blk sema.resolveValue(loaded) orelse try sema.intern(.{ .runtime_capture = sema.typeOf(loaded) });
            },
            // As upstream, a captured declaration is resolved only when the
            // type's body reads it: the type may be that declaration's value.
            .decl_val => |name| try sema.intern(.{ .nav_capture = .{ .nav = try sema.lookupName(block, src, sema.zirString(name)), .by_ref = false } }),
            .decl_ref => |name| try sema.intern(.{ .nav_capture = .{ .nav = try sema.lookupName(block, src, sema.zirString(name)), .by_ref = true } }),
        };
    }
    const name = try sema.typeName(block, name_strategy, inst, kind, captures);
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
fn typeName(sema: *Sema, block: *Block, strategy: Zir.Inst.NameStrategy, inst: Zir.Inst.Index, kind: Zcu.ContainerKind, captures: []const Index) Allocator.Error!TypeName {
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
            return .{ .display = aw.written(), .key = try sema.anonTypeKey(block, inst, captures) };
        },
        .anon, .dbg_var => {},
    }
    // Upstream's `type_fqn_ctx`: the function being analyzed or called
    // inline, else the declaration, else `<namespace>.comptime`.
    const parent = if (block.inlining) |inlining|
        ip.stringSlice(ip.getNav(ip.indexToKey(inlining.func).func.owner_nav).fqn)
    else if (sema.func != .none)
        ip.stringSlice(ip.getNav(ip.indexToKey(sema.func).func.owner_nav).fqn)
    else if (sema.owner_nav != .none)
        ip.stringSlice(ip.getNav(sema.owner_nav).fqn)
    else
        try std.fmt.allocPrint(sema.arena, "{s}.comptime", .{sema.zcu.namespacePtr(block.namespace).fqn});
    // `const T = struct {...};` in a function body: named after the local.
    const var_name: ?[]const u8 = if (strategy == .dbg_var) blk: {
        const tags = sema.code.instructions.items(.tag);
        const datas = sema.code.instructions.items(.data);
        for (@backingInt(inst)..tags.len) |k| switch (tags[k]) {
            .dbg_var_ptr, .dbg_var_val => if (datas[k].str_op.operand == inst.toRef()) break :blk datas[k].str_op.getStr(sema.code.*),
            else => {},
        };
        break :blk null;
    } else null;
    const display = if (var_name) |n|
        try std.fmt.allocPrint(sema.arena, "{s}.{s}", .{ parent, n })
    else
        try std.fmt.allocPrint(sema.arena, "{s}__{t}_{d}", .{ parent, kind, @backingInt(inst) });
    return .{ .display = display, .key = try sema.anonTypeKey(block, inst, captures) };
}

/// The stable key of an anonymous container type made by ZIR instruction
/// `inst` with `captures`: the key of the declaration whose code holds
/// `inst`, the offset of `inst` from that declaration, and the stable
/// hashes of the captures. A type's identity is its ZIR instruction and
/// captures, as upstream (`InternPool` compares them), so its key is a
/// function of exactly those: not of the arguments of the comptime call
/// that made it, nor of how many types its unit made before. It must
/// still tell distinct types apart, since their declarations' keys
/// extend it.
fn anonTypeKey(sema: *Sema, block: *Block, inst: Zir.Inst.Index, captures: []const Index) Allocator.Error![]const u8 {
    const ip = sema.ip;
    var aw: std.Io.Writer.Allocating = .init(sema.arena);
    const w = &aw.writer;
    const nav: InternPool.NavIndex = if (block.inlining) |inlining|
        ip.indexToKey(inlining.func).func.owner_nav
    else if (sema.func != .none)
        ip.indexToKey(sema.func).func.owner_nav
    else
        sema.owner_nav;
    const base: Zir.Inst.Index = if (nav != .none) blk: {
        const n = ip.getNav(nav);
        w.writeAll(ip.stringSlice(n.key)) catch return error.OutOfMemory;
        break :blk n.zir_inst;
    } else blk: {
        // A `comptime` block, or a container's field types and defaults.
        sema.zcu.unitKey(sema.owner, w) catch return error.OutOfMemory;
        break :blk switch (sema.owner) {
            .comptime_decl => |c| c.inst,
            .type_layout, .struct_defaults => |ty| ip.containerType(ty).?.zir_inst,
            else => unreachable,
        };
    };
    w.print("#{d}(", .{@as(i64, @backingInt(inst)) - @backingInt(base)}) catch return error.OutOfMemory;
    for (captures, 0..) |c, i| {
        if (i != 0) w.writeAll(",") catch return error.OutOfMemory;
        if (c != .none) w.print("{x}", .{ip.stableHash(c)}) catch return error.OutOfMemory;
    }
    w.writeAll(")") catch return error.OutOfMemory;
    return aw.written();
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
        // As upstream, `*align(4) u32` is a type of its own, which coerces
        // to and from `*u32` in memory.
        alignment = @intCast(std.math.log2_int(u64, a) + 1);
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

/// An error set type's names are in the order of their error codes, as
/// upstream's are in the order its strings were interned (`error{ One,
/// Two } || error{Three}` lists One, Two, Three). Codes are assigned on
/// first use and kept by the manifest, so the order is stable across edit
/// builds of a compilation.
fn errorSetType(sema: *Sema, names: []InternPool.String) !Index {
    const ip = sema.ip;
    for (names) |n| _ = try ip.errorValue(n);
    std.mem.sort(InternPool.String, names, ip, struct {
        fn lt(p: *InternPool, a: InternPool.String, b: InternPool.String) bool {
            return (p.errorValue(a) catch unreachable) < (p.errorValue(b) catch unreachable);
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
/// The names in error set `ty`, or null if it is `anyerror` (or an
/// inferred error set resolved to it) or not yet known (the inferred error
/// set of the function being analyzed). Resolving
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
    const an = (try sema.errorSetNames(block, src, a)) orelse return if (!sema.isOwnIes(a)) .anyerror_type else sema.failUnsupported(block, src, "merging inferred error sets");
    const bn = (try sema.errorSetNames(block, src, b)) orelse return if (!sema.isOwnIes(b)) .anyerror_type else sema.failUnsupported(block, src, "merging inferred error sets");
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

/// Whether `ty` is the inferred error set of the function being analyzed.
fn isOwnIes(sema: *Sema, ty: Index) bool {
    const key = sema.ip.indexToKey(ty);
    return key == .inferred_error_set_type and key.inferred_error_set_type == sema.func;
}

/// Adds the errors of `set` to the current function's inferred error set;
/// `anyerror` makes it `anyerror`.
fn addInferredErrors(sema: *Sema, block: *Block, src: Src, set: Index) CompileError!void {
    const names = (try sema.errorSetNames(block, src, set)) orelse {
        if (!sema.isOwnIes(set)) sema.ies_anyerror = true;
        return;
    };
    outer: for (names) |n| {
        for (sema.ies_names.items) |existing| if (existing == n) continue :outer;
        try sema.ies_names.append(sema.arena, n);
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
            // A zero-bit integer has one possible value, so it is
            // comptime-known even at runtime, as upstream.
            if (s.bits == 0) return .fromInterned(try sema.intValue(dest_ty, 0));
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
                    if (Type.optionalReprIsPtr(ip, s_child) == Type.optionalReprIsPtr(ip, child)) return try sema.addTyOp(block, .bitcast, dest_ty, inst);
                    // `?*T` to `?*allowzero T`: the null flag moves out of
                    // the pointer.
                    try sema.resolveLayout(block, src, dest_ty);
                    const payload = try sema.coercePtrTo(block, try sema.addTyOp(block, .optional_payload, s_child, inst), child);
                    const some = try sema.addTyOp(block, .wrap_optional, dest_ty, payload);
                    const none: Ref = .fromInterned(try sema.intern(.{ .opt = .{ .ty = dest_ty, .val = .none } }));
                    return try sema.select(block, dest_ty, try sema.addUnOp(block, .is_non_null, inst), some, none);
                }
                // `?u64` to `?usize`: integers of the same representation.
                if (sema.sameScalarRepr(s_child, child)) {
                    if (val) |v| switch (ip.indexToKey(v)) {
                        .opt => |o| {
                            const payload: Index = if (o.val == .none) .none else (try sema.coerce(block, child, .fromInterned(o.val), src)).toInterned().?;
                            return .fromInterned(try sema.intern(.{ .opt = .{ .ty = dest_ty, .val = payload } }));
                        },
                        else => return .fromInterned(try sema.undefValue(dest_ty)),
                    };
                    return try sema.addTyOp(block, .bitcast, dest_ty, inst);
                }
                // `?error{A}` to `?error{A,B}`: the same representation.
                if (Type.class(ip, s_child) == .error_set and Type.class(ip, child) == .error_set) {
                    if (val) |v| switch (ip.indexToKey(v)) {
                        .opt => |o| {
                            const payload: Index = if (o.val == .none) .none else ((try sema.coerceInner(block, child, .fromInterned(o.val), src)) orelse return null).toInterned().?;
                            return .fromInterned(try sema.intern(.{ .opt = .{ .ty = dest_ty, .val = payload } }));
                        },
                        else => return .fromInterned(try sema.undefValue(dest_ty)),
                    };
                    if (!try sema.errorSetCoercible(block, src, s_child, child, .none)) return null;
                    return try sema.addTyOp(block, .bitcast, dest_ty, inst);
                }
                // `?T` to `??T`: wrapped like any payload.
                if (Type.class(ip, child) != .optional) return null;
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
                // As upstream, the payload must coerce in memory.
                if (s_eu.payload_type != eu.payload_type and !sema.payloadCoercibleInMemory(s_eu.payload_type, eu.payload_type)) return null;
                if (!try sema.errorSetCoercible(block, src, s_eu.error_set_type, eu.error_set_type, if (val) |v| v else .none)) return null;
                if (val) |v| return .fromInterned(switch (ip.indexToKey(v)) {
                    .error_union => |e| try sema.intern(.{ .error_union = .{ .ty = dest_ty, .val = switch (e.val) {
                        .err_name => e.val,
                        .payload => |pv| .{ .payload = (try sema.coerce(block, eu.payload_type, .fromInterned(pv), src)).toInterned().? },
                    } } }),
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
                // A signed integer goes through isize, as upstream.
                const signed = Type.intInfo(ip, src_ty).signedness == .signed;
                var addr = try sema.coerce(block, if (signed) .isize_type else .usize_type, inst, src);
                if (signed) addr = try sema.addTyOp(block, .bitcast, .usize_type, addr);
                return try sema.addTyOp(block, .ptr_from_int, dest_ty, addr);
            },
            .@"fn" => {
                // A function body coerces to a pointer to it.
                // (See also the `.@"fn"` case below.)
                const d = Type.ptrInfo(ip, dest_ty);
                const v = val orelse return null;
                // An extern function's address is known at link time.
                if (d.flags.size == .one and d.child == src_ty and ip.indexToKey(v) == .extern_func and !block.is_comptime) {
                    return try sema.addInst(block, .{ .tag = .extern_ptr, .data = .{ .ty_pl = .{ .ty = dest_ty, .payload = @backingInt(ip.indexToKey(v).extern_func.name) } } });
                }
                if (d.flags.size != .one or ip.indexToKey(v) != .func) return null;
                if (d.child != src_ty and !try sema.fnTypeCoercible(block, src, v, d.child)) return null;
                const f = ip.indexToKey(v).func;
                if (f.generic_owner != .none) return null;
                try sema.zcu.queueFuncFrom(sema.owner, v);
                return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = dest_ty, .base = .{ .nav = f.owner_nav } } }));
            },
            else => {},
        },
        // A function body coerces to a function type it can be called as;
        // it keeps its own type.
        .@"fn" => if (sc == .@"fn") {
            const v = val orelse return null;
            // An extern function retyped, as upstream's in-memory coercion.
            if (ip.indexToKey(v) == .extern_func) {
                if (!try sema.fnTypeCoercible(block, src, v, dest_ty)) return null;
                var f = ip.indexToKey(v).extern_func;
                f.ty = dest_ty;
                return .fromInterned(try sema.intern(.{ .extern_func = f }));
            }
            if (ip.indexToKey(v) != .func or !try sema.fnTypeCoercible(block, src, v, dest_ty)) return null;
            // A generic function takes the parameter types of the type it
            // coerces to, which its calls then coerce arguments to.
            if (ip.indexToKey(dest_ty).func_type.is_generic and dest_ty != src_ty) {
                var f = ip.indexToKey(v).func;
                f.ty = dest_ty;
                return .fromInterned(try sema.intern(.{ .func = f }));
            }
            return inst;
        },
        .vector, .array => if ((dc == .vector and (sc == .array or sc == .vector)) or (dc == .array and sc == .vector)) {
            // Between arrays and vectors of the same length, element by
            // element (as upstream's `coerceArrayLike`).
            const len: u64 = if (dc == .vector) ip.indexToKey(dest_ty).vector_type.len else ip.indexToKey(dest_ty).array_type.len;
            const s_len: u64 = if (sc == .vector) ip.indexToKey(src_ty).vector_type.len else ip.indexToKey(src_ty).array_type.len;
            if (len != s_len) return null;
            if (dc == .array and ip.indexToKey(dest_ty).array_type.sentinel != .none) return null;
            const dest_elem = Type.childType(ip, dest_ty);
            const src_elem = Type.childType(ip, src_ty);
            const same = dest_elem == src_elem;
            if (val == null and !block.is_comptime) {
                // Arrays and vectors of non-bool elements share a layout
                // (vectors only add padding at the end).
                if (same and dest_elem != .bool_type) return try sema.addTyOp(block, .bitcast, dest_ty, inst);
                if (sema.elemCoercionWidens(dest_elem, src_elem) and dc == .vector and sc == .vector) {
                    return try sema.vectorMap(block, src, @intCast(len), dest_ty, &.{inst}, VectorCast{ .f = coerceElem, .elem_ty = dest_elem });
                }
            }
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
            // `[N:s]T` to `[N]T`, and between element types with the same
            // representation (`[N][:0]const u8` to `[N][]const u8`).
            const a = ip.indexToKey(dest_ty).array_type;
            const s = ip.indexToKey(src_ty).array_type;
            if (a.len != s.len or a.sentinel != .none) return null;
            if (a.child != s.child and !sema.childCoercibleInMemory(s.child, a.child)) return null;
            if (val) |v| {
                if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(dest_ty));
                const elems = try sema.arena.alloc(Index, a.len);
                for (elems, 0..) |*e, i| {
                    e.* = try sema.elemValue(v, i);
                    if (a.child != s.child) e.* = (try sema.coerce(block, a.child, .fromInterned(e.*), src)).toInterned().?;
                }
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
            if (sema.resolveValue(tag) == null) {
                // As upstream: when every field is zero-bit, the union is
                // its tag.
                for (info.field_types) |ft| {
                    if (Type.hasRuntimeBits(ip, ft) or Type.class(ip, ft) == .noreturn) break;
                } else {
                    try sema.requireRuntime(block, src);
                    return try sema.addTyOp(block, .bitcast, dest_ty, tag);
                }
            }
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
        // Field by field, as upstream's `coerceTupleToTuple`.
        .tuple => if (sc == .tuple) {
            const d = ip.indexToKey(dest_ty).tuple_type;
            const s = ip.indexToKey(src_ty).tuple_type;
            if (d.types.len != s.types.len or d.names.len != 0 or s.names.len != 0) return null;
            const elems = try sema.arena.alloc(Ref, d.types.len);
            for (elems, d.types, d.values, 0..) |*e, ft, fv, k| {
                const field = try sema.tupleField(block, inst, @intCast(k));
                e.* = (try sema.coerceInner(block, ft, field, src)) orelse return null;
                if (fv != .none and sema.resolveValue(e.*) != fv) return null;
            }
            return try sema.aggregate(block, src, dest_ty, elems);
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
    if (try sema.onePossibleValue(ty)) |v| return .fromInterned(v);
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
    const info = sema.ip.structInfo(union_ty);
    const tag_ty = info.tag_type;
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(tag_ty));
        return .fromInterned(sema.ip.indexToKey(v).un.tag);
    }
    if (!info.has_runtime_tag) {
        // Only one field can be active, as upstream's unionToTag.
        for (info.field_types, 0..) |ft, i| {
            if (!Type.hasNoPossibleValue(sema.ip, ft)) return .fromInterned(try sema.unionFieldTagValue(union_ty, @intCast(i)));
        }
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
                try sema.addInferredErrors(block, src, src_ty);
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
        .@"opaque" => null,
        // x86_64's minimum function alignment, as upstream.
        .@"fn" => 1,
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
    if (s.flags.is_allowzero and !d.flags.is_allowzero and d.flags.size != .c) return false;
    if (d.flags.alignment != s.flags.alignment) {
        // The alignment may only decrease.
        const sa = sema.ptrAlignment(s) orelse return false;
        const da = sema.ptrAlignment(d) orelse return false;
        if (da > sa) return false;
    }
    const s_array: ?InternPool.ArrayType = if (ip.indexToKey(s.child) == .array_type) ip.indexToKey(s.child).array_type else null;
    // C pointers coerce to and from single and many pointers of the same child.
    if (s.flags.size == .c and d.flags.size != .slice) return s.child == d.child or d.child == .anyopaque_type or (d.flags.is_const and sema.childCoercibleInMemory(s.child, d.child));
    if (d.flags.size == .c and s.flags.size != .slice)
        return s.child == d.child or d.child == .anyopaque_type or (s.flags.size == .one and s_array != null and s_array.?.child == d.child) or
            (d.flags.is_const and sema.childCoercibleInMemory(s.child, d.child));
    if (s.flags.size == d.flags.size) {
        if (d.sentinel != .none and !sema.sentinelsMatch(s.sentinel, d.sentinel)) return false;
        if (s.child == d.child or sema.sameScalarRepr(s.child, d.child)) return true;
        // Through a const pointer, a child may gain qualifiers itself
        // (`[]?[*:0]u8` to `[]const ?[*:0]const u8`).
        if (d.flags.is_const and sema.childCoercibleInMemory(s.child, d.child)) return true;
        if (d.child == .anyopaque_type and s.flags.size != .slice) return true;
        if (Type.class(ip, s.child) == .@"fn" and Type.class(ip, d.child) == .@"fn") return sema.fnTypeCoercibleInMemory(s.child, d.child);
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
        if (s_array) |a| return (a.child == d.child or sema.sameScalarRepr(a.child, d.child) or (d.flags.is_const and sema.childCoercibleInMemory(a.child, d.child))) and
            (d.sentinel == .none or d.sentinel == a.sentinel);
    }
    return false;
}

/// Whether an error union payload of type `s` reads in place as a `d`.
fn payloadCoercibleInMemory(sema: *Sema, s: Index, d: Index) bool {
    const ip = sema.ip;
    if (s == d or sema.sameScalarRepr(s, d)) return true;
    if (Type.class(ip, s) == .pointer and Type.class(ip, d) == .pointer) return sema.ptrCoercibleInPlace(s, d);
    if (Type.class(ip, s) == .optional and Type.class(ip, d) == .optional) {
        const sc = Type.childType(ip, s);
        const dc = Type.childType(ip, d);
        if (Type.class(ip, sc) == .pointer and Type.class(ip, dc) == .pointer) return sema.ptrCoercibleInPlace(sc, dc);
        return sema.sameScalarRepr(sc, dc);
    }
    // `*T` as `?*T`: a pointer-like optional is its pointer.
    if (Type.class(ip, s) == .pointer and Type.class(ip, d) == .optional) {
        const sp = Type.ptrInfo(ip, s);
        const dc = Type.childType(ip, d);
        return sp.flags.size != .slice and sp.flags.size != .c and !sp.flags.is_allowzero and
            Type.class(ip, dc) == .pointer and Type.optionalReprIsPtr(ip, dc) and sema.ptrCoercibleInPlace(s, dc);
    }
    return false;
}

/// Whether `a` and `b` are integer types of the same signedness and bits
/// (`u64` and `usize`) or float types of the same bits (`f80` and
/// `c_longdouble`), which coerce in memory, as upstream.
fn sameScalarRepr(sema: *Sema, a: Index, b: Index) bool {
    const ip = sema.ip;
    const ac = Type.class(ip, a);
    if (ac != Type.class(ip, b)) return false;
    return switch (ac) {
        .int => std.meta.eql(Type.intInfo(ip, a), Type.intInfo(ip, b)),
        .float => Type.floatBits(ip, a) == Type.floatBits(ip, b),
        else => false,
    };
}

/// Whether a value of type `src` can be read as a `dst` in place, where
/// `dst` differs only by adding const or volatile to pointers inside it.
fn childCoercibleInMemory(sema: *Sema, src: Index, dst: Index) bool {
    if (src == dst or sema.sameScalarRepr(src, dst)) return true;
    const ip = sema.ip;
    const sk = ip.indexToKey(src);
    const dk = ip.indexToKey(dst);
    if (sk == .opt_type and dk == .opt_type) {
        const sc = sk.opt_type;
        const dc = dk.opt_type;
        if (Type.class(ip, sc) != .pointer or Type.class(ip, dc) != .pointer) return false;
        return sema.childCoercibleInMemory(sc, dc);
    }
    // A C pointer and an optional single or many pointer share a
    // representation (`?[*]const u8` and `[*c]const u8`), as upstream.
    if (sk == .ptr_type and sk.ptr_type.flags.size == .c and dk == .opt_type and isOptionalNonC(ip, dk.opt_type))
        return sema.cPtrMatches(sk.ptr_type, ip.indexToKey(dk.opt_type).ptr_type);
    if (dk == .ptr_type and dk.ptr_type.flags.size == .c and sk == .opt_type and isOptionalNonC(ip, sk.opt_type))
        return sema.cPtrMatches(ip.indexToKey(sk.opt_type).ptr_type, dk.ptr_type);
    // `*T` read as `?*T`: a pointer-like optional is its pointer, as
    // upstream (`*const *anyopaque` to `*const ?*anyopaque`).
    if (sk == .ptr_type and dk == .opt_type and sk.ptr_type.flags.size != .slice and !sk.ptr_type.flags.is_allowzero) {
        const dc = dk.opt_type;
        if (Type.class(ip, dc) == .pointer and Type.optionalReprIsPtr(ip, dc)) return sema.childCoercibleInMemory(src, dc);
    }
    if (sk != .ptr_type or dk != .ptr_type) return false;
    const s = sk.ptr_type;
    const d = dk.ptr_type;
    if (s.flags.size != d.flags.size) return false;
    if (s.flags.is_const and !d.flags.is_const) return false;
    if (s.flags.is_volatile and !d.flags.is_volatile) return false;
    if (s.flags.is_allowzero != d.flags.is_allowzero) return false;
    if (s.flags.alignment != d.flags.alignment) {
        // The alignment may only decrease.
        const sa = sema.ptrAlignment(s) orelse return false;
        const da = sema.ptrAlignment(d) orelse return false;
        if (da > sa) return false;
    }
    if (d.sentinel != .none and !sema.sentinelsMatch(s.sentinel, d.sentinel)) return false;
    if (s.child == d.child) return true;
    return d.flags.is_const and sema.childCoercibleInMemory(s.child, d.child);
}

fn isOptionalNonC(ip: *const InternPool, child: Index) bool {
    if (ip.indexToKey(child) != .ptr_type) return false;
    const p = ip.indexToKey(child).ptr_type;
    return (p.flags.size == .one or p.flags.size == .many) and !p.flags.is_allowzero;
}

/// Whether pointers `s` and `d`, one of them a C pointer, read each
/// other's memory: the same child and alignment, gaining only qualifiers.
fn cPtrMatches(sema: *Sema, s: InternPool.PtrType, d: InternPool.PtrType) bool {
    if (s.flags.is_const and !d.flags.is_const) return false;
    if (s.flags.is_volatile and !d.flags.is_volatile) return false;
    if (s.flags.alignment != d.flags.alignment) return false;
    return s.child == d.child or (d.flags.is_const and sema.childCoercibleInMemory(s.child, d.child));
}

/// Whether sentinel `s` satisfies sentinel `d`, which may be of a
/// differently qualified type (`null` of `?[*:0]u8` and of
/// `?[*:0]const u8`).
fn sentinelsMatch(sema: *Sema, s: Index, d: Index) bool {
    if (s == d) return true;
    if (s == .none or d == .none) return false;
    const ip = sema.ip;
    const sk = ip.indexToKey(s);
    const dk = ip.indexToKey(d);
    return sk == .opt and dk == .opt and sk.opt.val == .none and dk.opt.val == .none;
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
        if (a.child != d.child and !sema.sameScalarRepr(a.child, d.child) and !(d.flags.is_const and sema.childCoercibleInMemory(a.child, d.child))) return null;
        // A pointer to a zero-length array coerces to any slice, even a mutable one.
        if (s.flags.is_const and !d.flags.is_const and a.len != 0) return null;
        if (d.sentinel != .none and !sema.sentinelsMatch(a.sentinel, d.sentinel)) return null;
        const many_ty = try sema.ptrType(.{ .child = d.child, .sentinel = d.sentinel, .flags = .{ .size = .many, .is_const = d.flags.is_const, .is_volatile = d.flags.is_volatile } });
        const ptr = try sema.coercePtrTo(block, inst, many_ty);
        const len: Ref = .fromInterned(try sema.intValue(.usize_type, a.len));
        return try sema.makeSlice(block, dest_ty, ptr, len);
    }
    // A pointer to a tuple to a const slice or array pointer: the tuple
    // coerced to an array, by reference, as upstream. An empty tuple
    // coerces to any slice.
    if (s.flags.size == .one and ip.indexToKey(s.child) == .tuple_type and ip.indexToKey(s.child).tuple_type.names.len == 0 and
        (d.flags.size == .slice or (d.flags.size == .one and ip.indexToKey(d.child) == .array_type)))
    {
        const n = ip.indexToKey(s.child).tuple_type.types.len;
        if (!d.flags.is_const and !(n == 0 and d.flags.size == .slice)) return null;
        const array_ty = if (d.flags.size == .slice) try sema.intern(.{ .array_type = .{ .len = n, .child = d.child, .sentinel = d.sentinel } }) else d.child;
        const src = block.nodeSrc(.zero);
        const array = if (n == 0)
            try sema.structInitEmpty(block, src, array_ty)
        else
            (try sema.coerceInner(block, array_ty, try sema.analyzeLoad(block, src, inst), src)) orelse return null;
        return sema.coercePtr(block, dest_ty, try sema.analyzeRef(block, src, array));
    }
    // A comptime-known `[]T` to `*[N]T` of its length, as upstream.
    if (s.flags.size == .slice and d.flags.size == .one and ip.indexToKey(d.child) == .array_type) {
        const v = sema.resolveValue(inst) orelse return null;
        if (sema.isUndef(v) or ip.indexToKey(v).slice.len == .undef_usize) return null;
        if (ip.intValue(u64, ip.indexToKey(v).slice.len).? != ip.indexToKey(d.child).array_type.len) return null;
        const array_ptr = try sema.sliceToArrayPtr(block, block.nodeSrc(.zero), v);
        return sema.coercePtr(block, dest_ty, array_ptr);
    }
    // `[]T` to `[*]T`, keeping a sentinel.
    if (s.flags.size == .slice and d.flags.size == .many) {
        if (s.child != d.child and !sema.sameScalarRepr(s.child, d.child) and !(d.flags.is_const and sema.childCoercibleInMemory(s.child, d.child))) return null;
        if (s.flags.is_const and !d.flags.is_const) return null;
        if (d.sentinel != .none and !sema.sentinelsMatch(s.sentinel, d.sentinel)) return null;
        const raw = try sema.slicePtr(block, inst);
        return try sema.coercePtrTo(block, raw, dest_ty);
    }
    // A pointer to a function, to a pointer to a function type it can be
    // called as (`&f` to `*const @TypeOf(f)` names its inferred error set).
    if (s.flags.size == .one and d.flags.size == .one and Type.class(ip, s.child) == .@"fn" and Type.class(ip, d.child) == .@"fn") {
        const v = sema.resolveValue(inst) orelse return null;
        const k = ip.indexToKey(v);
        if (k != .ptr or k.ptr.base != .nav or k.ptr.byte_offset != 0) return null;
        const func = ip.getNav(k.ptr.base.nav).val;
        if (ip.indexToKey(func) != .func or ip.typeOf(func) != s.child) return null;
        if (!try sema.fnTypeCoercible(block, block.nodeSrc(.zero), func, d.child)) return null;
        return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = dest_ty, .base = k.ptr.base } }));
    }
    return null;
}

/// Whether function `func` can be called as a `dst`: the same type except
/// that a `noreturn` function may stand for any return type, and a
/// returned error set may be a subset of `dst`'s (resolving an inferred
/// error set), as upstream.
fn fnTypeCoercible(sema: *Sema, block: *Block, src_loc: Src, func: Index, dst: Index) CompileError!bool {
    const ip = sema.ip;
    const src = ip.typeOf(func);
    if (Type.class(ip, dst) != .@"fn") return false;
    const s = ip.indexToKey(src).func_type;
    const d = ip.indexToKey(dst).func_type;
    if (s.cc != d.cc or s.is_var_args != d.is_var_args or s.is_generic != d.is_generic or
        s.param_types.len != d.param_types.len or s.noalias_bits != d.noalias_bits) return false;
    // Parameters coerce the other way, in memory; a generic one matches any.
    for (s.param_types, d.param_types, 0..) |a, b, i| {
        // `comptime` must match, except where zap made a parameter of a
        // comptime-only type implicitly comptime and upstream does not.
        const bit = @as(u32, 1) << @intCast(@min(i, 31));
        if (i < 32 and (s.comptime_bits & bit) != (d.comptime_bits & bit)) {
            const comptime_side = if (s.comptime_bits & bit != 0) a else b;
            if (comptime_side == .generic_poison_type or !(try sema.isComptimeOnlyResolved(block, src_loc, comptime_side))) return false;
        }
        if (a == b or a == .generic_poison_type or b == .generic_poison_type) continue;
        if (Type.class(ip, a) == .pointer and Type.class(ip, b) == .pointer and sema.ptrCoercibleInPlace(b, a)) continue;
        if (sema.cPtrOptCoercibleInMemory(b, a) or sema.cPtrOptCoercibleInMemory(a, b)) continue;
        return false;
    }
    if (s.return_type == d.return_type or s.return_type == .noreturn_type or s.return_type == .generic_poison_type) return true;
    if (sema.childCoercibleInMemory(s.return_type, d.return_type)) return true;
    const sr = ip.indexToKey(s.return_type);
    const dr = ip.indexToKey(d.return_type);
    if (sr != .error_union_type or dr != .error_union_type) return false;
    if (sr.error_union_type.payload_type != dr.error_union_type.payload_type) return false;
    var set = sr.error_union_type.error_set_type;
    if (set == .adhoc_inferred_error_set_type) set = try sema.intern(.{ .inferred_error_set_type = func });
    return sema.errorSetCoercible(block, src_loc, set, dr.error_union_type.error_set_type, .none);
}

/// Whether a function of type `src` can be called as a `dst` (through a
/// pointer cast `*const fn () error{}!void` to `*const fn () anyerror!void`):
/// the same parameters, and a return value that coerces in memory. An
/// inferred error set only matches itself or `anyerror` here.
fn fnTypeCoercibleInMemory(sema: *Sema, src: Index, dst: Index) bool {
    const ip = sema.ip;
    const s = ip.indexToKey(src).func_type;
    const d = ip.indexToKey(dst).func_type;
    if (s.cc != d.cc or s.is_var_args != d.is_var_args or s.is_generic != d.is_generic or s.comptime_bits != d.comptime_bits or
        s.param_types.len != d.param_types.len or s.noalias_bits != d.noalias_bits) return false;
    for (s.param_types, d.param_types) |a, b| {
        if (a == b) continue;
        if (Type.class(ip, a) == .pointer and Type.class(ip, b) == .pointer and sema.ptrCoercibleInPlace(b, a)) continue;
        return false;
    }
    if (s.return_type == d.return_type or s.return_type == .noreturn_type) return true;
    const sr = ip.indexToKey(s.return_type);
    const dr = ip.indexToKey(d.return_type);
    if (sr != .error_union_type or dr != .error_union_type) return false;
    if (!sema.payloadCoercibleInMemory(sr.error_union_type.payload_type, dr.error_union_type.payload_type)) return false;
    const ss = sr.error_union_type.error_set_type;
    const ds = dr.error_union_type.error_set_type;
    if (ss == ds or ds == .anyerror_type) return true;
    const sn = ip.indexToKey(ss);
    const dn = ip.indexToKey(ds);
    if (sn != .error_set_type or dn != .error_set_type) return false;
    outer: for (sn.error_set_type) |n| {
        for (dn.error_set_type) |m| if (n == m) continue :outer;
        return false;
    }
    return true;
}

/// Whether a C pointer and an optional pointer (`[*c]const u8` and
/// `?[*:0]const u8`) have the same representation, as upstream's in-memory
/// coercion allows between `from` and `to`.
fn cPtrOptCoercibleInMemory(sema: *Sema, from: Index, to: Index) bool {
    const ip = sema.ip;
    if (Type.class(ip, from) != .pointer or Type.class(ip, to) != .optional) return false;
    const c = Type.ptrInfo(ip, from);
    const child = Type.childType(ip, to);
    if (c.flags.size != .c or Type.class(ip, child) != .pointer) return false;
    const o = Type.ptrInfo(ip, child);
    if (o.flags.size == .slice or o.flags.size == .c or o.child != c.child) return false;
    return (o.flags.is_const or !c.flags.is_const) and (o.flags.is_volatile or !c.flags.is_volatile);
}

/// `@TypeOf` a function with an inferred error set names that set, as
/// upstream, though the function value's type has the placeholder.
fn typeOfWithIes(sema: *Sema, operand: Ref) CompileError!Index {
    const ip = sema.ip;
    const ty = sema.typeOf(operand);
    const func = sema.resolveValue(operand) orelse return ty;
    if (ip.indexToKey(func) != .func) return ty;
    var f = ip.indexToKey(ty).func_type;
    const ret = ip.indexToKey(f.return_type);
    if (ret != .error_union_type or ret.error_union_type.error_set_type != .adhoc_inferred_error_set_type) return ty;
    const ies = try sema.intern(.{ .inferred_error_set_type = func });
    f.return_type = try sema.intern(.{ .error_union_type = .{ .error_set_type = ies, .payload_type = ret.error_union_type.payload_type } });
    return sema.intern(.{ .func_type = f });
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
                // (`*[2]i32` cast to `[*][2]i32` instead points at whole
                // arrays, from this one.)
                if (s.flags.size == .one and d.flags.size != .one and ip.indexToKey(s.child) == .array_type and p.base != .int and d.child != s.child) {
                    // A subarray of `buf` (from `buf[a..b]`) starts at an
                    // element of `buf`, so later indices stay within `buf`.
                    if (p.base == .elem and p.byte_offset == 0) {
                        const parent = Type.ptrInfo(ip, ip.typeOf(p.base.elem.base));
                        const parent_elem = switch (ip.indexToKey(parent.child)) {
                            .array_type => |a| if (parent.flags.size == .one) a.child else parent.child,
                            else => parent.child,
                        };
                        if (parent_elem == ip.indexToKey(s.child).array_type.child)
                            return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = ty, .base = p.base } }));
                    }
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
    if (block.is_comptime and !block.discards_runtime) return sema.fail(block, .{ .base = block.src_base, .loc = .{ .node = .zero } }, "unable to evaluate comptime expression", .{});
    return sema.addTyOp(block, .bitcast, ty, ptr);
}

fn resolvePeerTypes(sema: *Sema, block: *Block, src: Src, refs: []const Ref) CompileError!Index {
    var chosen: Index = .noreturn_type;
    sema.peers_comptime_known = false;
    for (refs) |r| sema.peers_comptime_known = sema.peers_comptime_known or sema.resolveValue(r) != null;
    // Upstream resolves all peers at once: array pointers next to a
    // many-pointer become many-pointers, not slices, whatever their order.
    // So many-pointer peers go first.
    var many_first = refs;
    for (refs) |r| {
        if (!sema.isManyPtr(sema.typeOf(r))) continue;
        const sorted = try sema.arena.dupe(Ref, refs);
        std.mem.sort(Ref, sorted, sema, struct {
            fn lt(s: *Sema, x: Ref, y: Ref) bool {
                return s.isManyPtr(s.typeOf(x)) and !s.isManyPtr(s.typeOf(y));
            }
        }.lt);
        many_first = sorted;
        break;
    }
    for (many_first) |r| {
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

fn isManyPtr(sema: *Sema, ty: Index) bool {
    const t = if (Type.class(sema.ip, ty) == .optional) Type.childType(sema.ip, ty) else ty;
    return Type.class(sema.ip, t) == .pointer and Type.ptrInfo(sema.ip, t).flags.size == .many;
}

fn peerPair(sema: *Sema, block: *Block, src: Src, a: Index, b: Index) CompileError!Index {
    const ip = sema.ip;
    if (a == b) return a;
    if (a == .undefined_type) return b;
    if (b == .undefined_type) return a;
    const ca = Type.class(ip, a);
    const cb = Type.class(ip, b);
    // As upstream, error sets come off first, so that an error set and an
    // optional give `E!?T`.
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
    // A C pointer absorbs null.
    if (ca == .null and cb == .pointer and Type.ptrInfo(ip, b).flags.size == .c) return b;
    if (cb == .null and ca == .pointer and Type.ptrInfo(ip, a).flags.size == .c) return a;
    if (ca == .null) return if (cb == .optional) b else sema.optType(b);
    if (cb == .null) return if (ca == .optional) a else sema.optType(a);
    if (ca == .optional and cb != .optional) return sema.optType(try sema.peerPair(block, src, Type.childType(ip, a), b));
    if (cb == .optional and ca != .optional) return sema.optType(try sema.peerPair(block, src, a, Type.childType(ip, b)));
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
        // A tuple peer (`v == .{ 1, 2 }`) contributes each field's type.
        const tuple = ip.indexToKey(if (ca == .vector) b else a);
        if (tuple == .tuple_type) {
            const vec = elems(ip, if (ca == .vector) a else b).?;
            if (tuple.tuple_type.types.len != vec[0]) return sema.fail(block, src, "vector length mismatch", .{});
            var child = vec[1];
            for (tuple.tuple_type.types) |t| child = try sema.peerPair(block, src, child, t);
            return sema.vectorType(@intCast(vec[0]), child);
        }
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
    // Upstream's `enum_or_union` strategy: an enum literal takes the enum's
    // or tagged union's type.
    if (ca == .enum_literal and (cb == .@"enum" or cb == .@"union")) return b;
    if (cb == .enum_literal and (ca == .@"enum" or ca == .@"union")) return a;
    // A tagged union and its tag type resolve to the union, as upstream.
    if ((ca == .@"enum" and cb == .@"union") or (ca == .@"union" and cb == .@"enum")) {
        const u = if (ca == .@"union") a else b;
        const e = if (ca == .@"union") b else a;
        try sema.resolveLayout(block, src, u);
        if (sema.ip.structInfo(u).tag_type == e) return u;
    }
    // Upstream's `array` and `tuple` strategies: arrays of one length with
    // in-memory compatible elements, a tuple of an array's length, and
    // tuples of one length field by field.
    if (ca == .array and cb == .array) {
        const xa = ip.indexToKey(a).array_type;
        const xb = ip.indexToKey(b).array_type;
        if (xa.len == xb.len) {
            const child = if (sema.childCoercibleInMemory(xa.child, xb.child)) xb.child else if (sema.childCoercibleInMemory(xb.child, xa.child)) xa.child else .none;
            if (child != .none) return sema.intern(.{ .array_type = .{ .len = xa.len, .child = child, .sentinel = if (xa.sentinel == xb.sentinel) xa.sentinel else .none } });
        }
    }
    if (ca == .array and cb == .tuple and ip.indexToKey(b).tuple_type.types.len == ip.indexToKey(a).array_type.len) return a;
    if (cb == .array and ca == .tuple and ip.indexToKey(a).tuple_type.types.len == ip.indexToKey(b).array_type.len) return b;
    if (ca == .tuple and cb == .tuple) {
        const ta = ip.indexToKey(a).tuple_type;
        const tb = ip.indexToKey(b).tuple_type;
        if (ta.types.len == tb.types.len) {
            const types = try sema.arena.alloc(Index, ta.types.len);
            const values = try sema.arena.alloc(Index, ta.types.len);
            for (types, values, ta.types, tb.types) |*t, *v, x, y| {
                t.* = try sema.peerPair(block, src, x, y);
                v.* = .none;
            }
            return sema.intern(.{ .tuple_type = .{ .types = types, .values = values } });
        }
    }
    // A function body peered with a pointer acts as a pointer to it.
    if (ca == .@"fn" and cb == .pointer) return sema.peerPair(block, src, try sema.ptrType(.{ .child = a, .flags = .{ .is_const = true } }), b);
    if (cb == .@"fn" and ca == .pointer) return sema.peerPair(block, src, a, try sema.ptrType(.{ .child = b, .flags = .{ .is_const = true } }));
    if (ca == .pointer and cb == .pointer) {
        // A C pointer wins over other pointers to its element type.
        if (try sema.peerCPtr(a, b)) |t| return t;
        if (sema.ptrCoercibleInPlace(a, b)) return b;
        if (sema.ptrCoercibleInPlace(b, a)) return a;
        if (try sema.peerPtrs(a, b)) |t| return t;
        // A pointer to a tuple (`&.{ 'x', 'y' }`) is a pointer to an array
        // of the other peer's elements.
        if (try sema.tuplePtrAsArrayPtr(a, b)) |t| return sema.peerPair(block, src, t, b);
        if (try sema.tuplePtrAsArrayPtr(b, a)) |t| return sema.peerPair(block, src, a, t);
    }
    return sema.fail(block, src, "incompatible types: '{f}' and '{f}'", .{ sema.fmtType(a), sema.fmtType(b) });
}

/// The peer type of pointers to arrays, slices, and many-pointers with the
/// same element type but different lengths or qualifiers, as upstream's
/// pointer strategy: a slice (`*const [5:0]u8` and `*const [4:0]u8` give
/// `[:0]const u8`), or a many-pointer when one peer is one. The sentinel
/// survives only if both peers have it. Qualifiers (const, volatile,
/// allowzero) combine, also for single pointers to one type.
fn peerPtrs(sema: *Sema, a: Index, b: Index) !?Index {
    const ip = sema.ip;
    const Seq = struct { elem: Index, sentinel: Index, size: InternPool.PtrType.Size, p: InternPool.PtrType, array: bool = false };
    const seq = struct {
        fn f(p_ip: *InternPool, ty: Index) ?Seq {
            const p = p_ip.indexToKey(ty).ptr_type;
            if (p.packed_offset.host_size != 0) return null;
            return switch (p.flags.size) {
                .one => if (p_ip.indexToKey(p.child) == .array_type) blk: {
                    const arr = p_ip.indexToKey(p.child).array_type;
                    break :blk .{ .elem = arr.child, .sentinel = arr.sentinel, .size = .one, .p = p, .array = true };
                } else if (p_ip.indexToKey(p.child) == .tuple_type and p_ip.indexToKey(p.child).tuple_type.types.len == 0)
                    // `*const struct {}` (from `&.{}`) acts as a pointer
                    // to an empty array of any element type.
                    .{ .elem = .noreturn_type, .sentinel = .none, .size = .one, .p = p, .array = true }
                else
                    .{ .elem = p.child, .sentinel = .none, .size = .one, .p = p },
                .slice, .many => .{ .elem = p.child, .sentinel = p.sentinel, .size = p.flags.size, .p = p },
                .c => null,
            };
        }
    }.f;
    var sa = seq(ip, a) orelse return null;
    var sb = seq(ip, b) orelse return null;
    if (sa.elem == .noreturn_type) sa.elem = sb.elem;
    if (sb.elem == .noreturn_type) sb.elem = sa.elem;
    if (sa.elem != sb.elem or sa.elem == .noreturn_type) return null;
    // Single pointers to one non-array type merge only their qualifiers.
    const single = sa.size == .one and !sa.array;
    if (single != (sb.size == .one and !sb.array)) return null;
    const size: InternPool.PtrType.Size = if (single) .one else if (sa.size == .many or sb.size == .many) blk: {
        if (sa.size == .slice or sb.size == .slice) return null;
        break :blk .many;
    } else .slice;
    return try sema.ptrType(.{
        .child = sa.elem,
        .sentinel = if (sa.sentinel == sb.sentinel) sa.sentinel else .none,
        .flags = .{
            .size = size,
            .is_const = sa.p.flags.is_const or sb.p.flags.is_const,
            .is_volatile = sa.p.flags.is_volatile or sb.p.flags.is_volatile,
            .is_allowzero = sa.p.flags.is_allowzero or sb.p.flags.is_allowzero,
            .alignment = sema.peerAlignment(sa.p, sb.p) orelse return null,
        },
    });
}

/// The alignment flag of the peer of pointers `a` and `b`: the smaller
/// alignment, explicit if either is; null if one is unknown.
fn peerAlignment(sema: *Sema, a: InternPool.PtrType, b: InternPool.PtrType) ?u6 {
    if (a.flags.alignment == 0 and b.flags.alignment == 0) return 0;
    const x = sema.ptrAlignment(a) orelse return null;
    const y = sema.ptrAlignment(b) orelse return null;
    return @intCast(std.math.log2_int(u64, @min(x, y)) + 1);
}

/// The peer of a C pointer and another pointer to its element type (or
/// to an array of it): the C pointer with both peers' qualifiers.
fn peerCPtr(sema: *Sema, a: Index, b: Index) !?Index {
    const ip = sema.ip;
    const pa = Type.ptrInfo(ip, a);
    const pb = Type.ptrInfo(ip, b);
    if (pa.flags.size != .c and pb.flags.size != .c) return null;
    if (pa.flags.size == .slice or pb.flags.size == .slice) return null;
    const elem = struct {
        fn f(p_ip: *InternPool, p: InternPool.PtrType) Index {
            if (p.flags.size == .one and p_ip.indexToKey(p.child) == .array_type) return p_ip.indexToKey(p.child).array_type.child;
            return p.child;
        }
    }.f;
    const child = if (pa.flags.size == .c) pa.child else pb.child;
    if (elem(ip, pa) != child or elem(ip, pb) != child) return null;
    return try sema.ptrType(.{ .child = child, .flags = .{
        .size = .c,
        .is_const = pa.flags.is_const or pb.flags.is_const,
        .is_volatile = pa.flags.is_volatile or pb.flags.is_volatile,
        .is_allowzero = if (pa.flags.size == .c) pa.flags.is_allowzero else pb.flags.is_allowzero,
        .alignment = sema.peerAlignment(pa, pb) orelse return null,
    } });
}

/// Pointer-to-tuple `ptr_ty` as a pointer to an array of `other`'s element
/// type, or null if either is not such a pointer.
fn tuplePtrAsArrayPtr(sema: *Sema, ptr_ty: Index, other: Index) !?Index {
    const ip = sema.ip;
    const p = Type.ptrInfo(ip, ptr_ty);
    if (p.flags.size != .one or ip.indexToKey(p.child) != .tuple_type) return null;
    const o = Type.ptrInfo(ip, other);
    const elem = switch (o.flags.size) {
        .slice, .many => o.child,
        .one => if (ip.indexToKey(o.child) == .array_type) ip.indexToKey(o.child).array_type.child else return null,
        .c => return null,
    };
    const arr = try sema.intern(.{ .array_type = .{ .len = ip.indexToKey(p.child).tuple_type.types.len, .child = elem } });
    var info = p;
    info.child = arr;
    return try sema.ptrType(info);
}

// ---------------------------------------------------------------------------
// Arithmetic and comparison

/// `@addWithOverflow` and its relatives on vectors: the tuple of the
/// wrapped results and a vector of their overflow bits, each mapped
/// element by element.
fn vectorOverflow(sema: *Sema, block: *Block, src: Src, op: Zir.Inst.Extended, len: u32, ty: Index, lhs: Ref, rhs: Ref) CompileError!Ref {
    const Field = struct {
        op: Zir.Inst.Extended,
        index: u32,
        fn call(o: @This(), s: *Sema, b: *Block, sr: Src, e: []const Ref) CompileError!Ref {
            const t = if (o.op == .shl_with_overflow) try s.analyzeShlWithOverflow(b, sr, e[0], e[1]) else try s.analyzeOverflowBuiltin(b, sr, o.op, e[0], e[1]);
            return s.tupleField(b, t, o.index);
        }
    };
    const bits_ty = try sema.vectorType(len, .u1_type);
    const result = try sema.vectorMap(block, src, len, ty, &.{ lhs, rhs }, Field{ .op = op, .index = 0 });
    const bits = try sema.vectorMap(block, src, len, bits_ty, &.{ lhs, rhs }, Field{ .op = op, .index = 1 });
    const tuple_ty = try sema.intern(.{ .tuple_type = .{ .types = &.{ ty, bits_ty }, .values = &.{ .none, .none } } });
    return sema.aggregate(block, src, tuple_ty, &.{ result, bits });
}

fn overflowTupleType(sema: *Sema, ty: Index) !Index {
    return sema.intern(.{ .tuple_type = .{ .types = &.{ ty, .u1_type }, .values = &.{ .none, .none } } });
}

fn requireRuntime(sema: *Sema, block: *Block, src: Src) CompileError!void {
    if (block.is_comptime and !block.discards_runtime) return sema.fail(block, src, "unable to evaluate comptime expression", .{});
}

fn analyzeArithmetic(sema: *Sema, block: *Block, src: Src, tag: Zir.Inst.Tag, uncasted_lhs: Ref, uncasted_rhs: Ref) CompileError!Ref {
    const ip = sema.ip;
    switch (tag) {
        .shl, .shr, .shl_sat, .shl_exact, .shr_exact => return sema.analyzeShift(block, src, tag, uncasted_lhs, uncasted_rhs),
        else => {},
    }
    if (Type.class(ip, sema.typeOf(uncasted_lhs)) == .pointer and Type.class(ip, sema.typeOf(uncasted_rhs)) == .pointer and tag == .sub)
        return sema.analyzePtrDiff(block, src, uncasted_lhs, uncasted_rhs);
    if (Type.class(ip, sema.typeOf(uncasted_lhs)) == .pointer and (tag == .add or tag == .sub or tag == .addwrap or tag == .subwrap))
        return sema.analyzePtrArithmetic(block, src, tag == .add or tag == .addwrap, uncasted_lhs, uncasted_rhs);
    const ty = try sema.resolvePeerTypes(block, src, &.{ uncasted_lhs, uncasted_rhs });
    if (sema.vectorLen(ty)) |len| {
        const lhs = try sema.vectorOperand(block, src, ty, uncasted_lhs);
        const rhs = try sema.vectorOperand(block, src, ty, uncasted_rhs);
        return sema.vectorMap(block, src, len, ty, &.{ lhs, rhs }, VectorArith{ .tag = tag, .elem_ty = Type.childType(ip, ty) });
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
            // As upstream: comptime-known operands divide by truncation,
            // and a remainder is allowed when neither operand may be
            // negative or the remainder is zero.
            const lv = sema.resolveValue(lhs);
            const rv = sema.resolveValue(rhs);
            const known = lv != null and rv != null and !sema.isUndef(lv.?) and !sema.isUndef(rv.?);
            if (tag == .div and !known) return sema.fail(block, src, "division with '{f}' and '{f}': signed integers must use @divTrunc, @divFloor, or @divExact", .{ sema.fmtType(ty), sema.fmtType(ty) });
            if (tag == .mod_rem) {
                const maybe_negative = !known or sema.intSign(lv.?) < 0 or sema.intSign(rv.?) < 0;
                if (maybe_negative) {
                    const zero = known and sema.intSign(rv.?) != 0 and blk: {
                        var q = try BigInt.init(sema.arena);
                        var r = try BigInt.init(sema.arena);
                        try q.divTrunc(&r, &try sema.bigValue(lv.?), &try sema.bigValue(rv.?));
                        break :blk r.eqlZero();
                    };
                    if (!zero) return sema.fail(block, src, "remainder division with '{f}' and '{f}': signed integers and floats must use @rem or @mod", .{ sema.fmtType(ty), sema.fmtType(ty) });
                }
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
/// `lhs - rhs` of two pointers: the distance in elements, as upstream
/// `(@intFromPtr(lhs) -% @intFromPtr(rhs)) / @sizeOf(T)`.
fn analyzePtrDiff(sema: *Sema, block: *Block, src: Src, lhs: Ref, rhs: Ref) CompileError!Ref {
    const ip = sema.ip;
    const lp = Type.ptrInfo(ip, sema.typeOf(lhs));
    const rp = Type.ptrInfo(ip, sema.typeOf(rhs));
    // As upstream, a pointer to an array steps by its element.
    const elem = struct {
        fn f(p_ip: *InternPool, p: InternPool.PtrType) Index {
            return if (p.flags.size == .one and p_ip.indexToKey(p.child) == .array_type) p_ip.indexToKey(p.child).array_type.child else p.child;
        }
    }.f;
    const elem_ty = elem(ip, lp);
    if (lp.flags.size == .slice or rp.flags.size == .slice or elem_ty != elem(ip, rp))
        return sema.fail(block, src, "incompatible pointer arithmetic operands '{f}' and '{f}'", .{ sema.fmtType(sema.typeOf(lhs)), sema.fmtType(sema.typeOf(rhs)) });
    try sema.resolveLayout(block, src, elem_ty);
    const elem_size = @max(Type.abiSize(ip, elem_ty), 1);
    if (sema.resolveValue(lhs)) |lv| if (sema.resolveValue(rhs)) |rv| {
        const lk = ip.indexToKey(lv).ptr;
        const rk = ip.indexToKey(rv).ptr;
        if (lk.base == .int and rk.base == .int)
            return .fromInterned(try sema.intValue(.usize_type, (lk.byte_offset -% rk.byte_offset) / elem_size));
        // Pointers into the same comptime memory: their offsets within it.
        if (lk.base != .int and rk.base != .int and std.meta.eql(sema.ptrRootBase(lk), sema.ptrRootBase(rk))) {
            const lo = try sema.comptimePtrOffset(block, src, lv);
            const ro = try sema.comptimePtrOffset(block, src, rv);
            return .fromInterned(try sema.intValue(.usize_type, (lo -% ro) / elem_size));
        }
    };
    try sema.requireRuntime(block, src);
    const li = try sema.addUnOp(block, .int_from_ptr, lhs);
    const ri = try sema.addUnOp(block, .int_from_ptr, rhs);
    const bytes = try sema.addBinOp(block, .sub_wrap, li, ri);
    if (elem_size == 1) return bytes;
    return sema.addBinOp(block, .div_trunc, bytes, .fromInterned(try sema.intValue(.usize_type, elem_size)));
}

fn analyzePtrArithmetic(sema: *Sema, block: *Block, src: Src, is_add: bool, ptr: Ref, uncasted_n: Ref) CompileError!Ref {
    const ip = sema.ip;
    const ptr_ty_in = sema.typeOf(ptr);
    const p = Type.ptrInfo(ip, ptr_ty_in);
    if (p.flags.size != .many and p.flags.size != .c) return sema.fail(block, src, "invalid pointer arithmetic operand: '{f}'", .{sema.fmtType(ptr_ty_in)});
    const n = try sema.coerce(block, .usize_type, uncasted_n, src);
    try sema.resolveLayout(block, src, p.child);
    const elem_size = Type.abiSize(ip, p.child);
    // An explicit alignment drops to what the offset keeps, as upstream.
    const ptr_ty = if (p.flags.alignment == 0) ptr_ty_in else ty: {
        const offset: u64 = if (sema.resolveValue(n)) |nv| (if (sema.isUndef(nv)) elem_size else ip.intValue(u64, nv).? *% elem_size) else elem_size;
        if (offset == 0) break :ty ptr_ty_in;
        var info = p;
        info.flags.alignment = @intCast(@min(p.flags.alignment, @as(u32, @ctz(offset)) + 1));
        break :ty try sema.ptrType(info);
    };
    if (sema.resolveValue(ptr)) |pv| if (sema.resolveValue(n)) |nv| {
        if (ip.indexToKey(pv) == .ptr and !sema.isUndef(nv)) {
            const k = ip.indexToKey(pv).ptr;
            const count = ip.intValue(u64, nv).?;
            const delta = count *% elem_size;
            // Step the element index when the pointer still has the
            // element size of the array it indexes (it may have been cast).
            const step_index = k.base == .elem and Type.abiSize(ip, sema.memElemType(ip.typeOf(k.base.elem.base))) == elem_size;
            return .fromInterned(try sema.intern(.{ .ptr = .{
                .ty = ptr_ty,
                .base = if (step_index)
                    .{ .elem = .{ .base = k.base.elem.base, .index = if (is_add) k.base.elem.index + count else k.base.elem.index -% count } }
                else
                    k.base,
                .byte_offset = if (step_index) k.byte_offset else if (is_add) k.byte_offset +% delta else k.byte_offset -% delta,
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
    var then_block = block.condChild();
    defer then_block.instructions.deinit(sema.gpa);
    _ = try sema.addInst(&then_block, .{ .tag = .br, .data = .{ .br = .{ .block_inst = block_inst, .operand = a } } });
    var else_block = block.condChild();
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
        const amount = sema.ip.intValue(u64, v) orelse std.math.maxInt(u64);
        if (!sat and class == .int and amount > 0 and amount >= Type.intInfo(ip, ty).bits)
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
    if (rv) |v| if (sema.intSign(v) == 0) return lhs;
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
    if (sema.vectorLen(ty)) |len| if (Type.class(sema.ip, Type.childType(sema.ip, ty)) == .int)
        return sema.vectorOverflow(block, src, op, len, ty, try sema.coerce(block, ty, uncasted_lhs, src), try sema.coerce(block, ty, uncasted_rhs, src));
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
    if (sema.vectorLen(ty)) |len| if (Type.class(ip, Type.childType(ip, ty)) == .int)
        return sema.vectorOverflow(block, src, .shl_with_overflow, len, ty, lhs, uncasted_rhs);
    if (Type.class(ip, ty) != .int) return sema.fail(block, src, "expected integer type, found '{f}'", .{sema.fmtType(ty)});
    const info = Type.intInfo(ip, ty);
    const shift_ty = try sema.intType(.unsigned, Type.log2IntBits(info.bits));
    const rhs = try sema.coerce(block, shift_ty, uncasted_rhs, src);
    const tuple_ty = try sema.overflowTupleType(ty);
    const rv = sema.resolveValue(rhs);
    if (rv) |v| if (!sema.isUndef(v) and ip.intValue(u64, v).? > 0 and ip.intValue(u64, v).? >= info.bits)
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
                } else if (val != null and vector_len != null and !sema.isUndef(val.?) and !try sema.anyElemUndef(val.?, vector_len.?)) {
                    lo = try sema.bigValue(try sema.elemValue(val.?, 0));
                    hi = lo;
                    for (1..vector_len.?) |i| {
                        const b = try sema.bigValue(try sema.elemValue(val.?, i));
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

/// Whether an element of comptime-known vector `val` is undefined; its
/// other elements then do not narrow `@min`/`@max`'s bounds.
fn anyElemUndef(sema: *Sema, val: Index, len: u32) !bool {
    for (0..len) |i| if (sema.isUndef(try sema.elemValue(val, i))) return true;
    return false;
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
        // represents it (it needs `bits` significant bits), else the
        // floats above it start at `min`, a power of two, unless that
        // overflows to -inf.
        const hi = try sema.floatValue(float_ty, std.math.ldexp(@as(f128, 1), @as(i32, info.bits) - @intFromBool(info.signedness == .signed)));
        const precision: u16 = switch (Type.floatBits(ip, float_ty)) {
            16 => 11,
            32 => 24,
            64 => 53,
            80 => 64,
            128 => 113,
            else => unreachable,
        };
        const min_exact = info.signedness == .unsigned or info.bits <= precision;
        const lo_val: f128 = if (info.signedness == .unsigned) -1 else -std.math.ldexp(@as(f128, 1), @as(i32, info.bits) - 1) - @as(f128, if (min_exact) 1 else 0);
        const lo = try sema.floatValue(float_ty, lo_val);
        const lo_ok = if (min_exact or std.math.isInf(sema.toF128(lo)))
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
    // A comptime_int operand is already integral: every rounding mode
    // leaves it unchanged.
    if (ty == .comptime_int_type) return sema.coerce(block, dest_ty, operand, src);
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
    if (ty == .comptime_int_type) return sema.analyzeFloatFromInt(block, src, dest_ty, operand);
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
        const l = try sema.vectorOperand(block, src, ty, lhs);
        const r = try sema.vectorOperand(block, src, ty, rhs);
        return sema.vectorMap(block, src, len, try sema.vectorType(len, .bool_type), &.{ l, r }, VectorCmp{ .op = op, .elem_ty = Type.childType(ip, ty) });
    }
    const is_eq = op == .eq or op == .neq;
    // The `undefined` literal compares to anything as an undefined bool.
    if (lc == .undefined or rc == .undefined) return .fromInterned(try sema.undefValue(.bool_type));

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
    // A function body compares as a pointer to it.
    if (is_eq and lc == .@"fn" and rc == .pointer) return sema.analyzeCmp(block, src, op, try sema.coerce(block, rt, lhs, src), rhs);
    if (is_eq and rc == .@"fn" and lc == .pointer) return sema.analyzeCmp(block, src, op, lhs, try sema.coerce(block, lt, rhs, src));
    if (lt == .type_type and rt == .type_type and is_eq) {
        const a = try sema.resolveConstValue(block, src, lhs, "types must be comptime-known");
        const b = try sema.resolveConstValue(block, src, rhs, "types must be comptime-known");
        return .fromInterned(boolValue((a == b) == (op == .eq)));
    }
    if (lc == .@"fn" and rc == .@"fn" and is_eq) {
        const a = try sema.resolveConstValue(block, src, lhs, "function bodies are comptime-known");
        const b = try sema.resolveConstValue(block, src, rhs, "function bodies are comptime-known");
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
    // A C pointer compares with an integer as with a pointer from it.
    if (lc == .pointer and Type.ptrInfo(ip, lt).flags.size == .c and (rc == .int or rc == .comptime_int))
        return sema.analyzeCmp(block, src, op, lhs, try sema.coerce(block, lt, rhs, src));
    if (rc == .pointer and Type.ptrInfo(ip, rt).flags.size == .c and (lc == .int or lc == .comptime_int))
        return sema.analyzeCmp(block, src, op, try sema.coerce(block, rt, lhs, src), rhs);
    if (lc == .pointer and rc == .pointer and !is_eq) {
        // Only C pointers are ordered, as upstream.
        for ([_]Index{ lt, rt }) |t| if (Type.ptrInfo(ip, t).flags.size != .c)
            return sema.fail(block, src, "operator {s} not allowed for type '{f}'", .{ @tagName(op), sema.fmtType(t) });
        // Ordered comparison compares addresses: comptime-known for
        // addresses from integers or within the same comptime memory.
        if (sema.resolveValue(lhs)) |a| if (sema.resolveValue(rhs)) |b| {
            const ka = ip.indexToKey(a);
            const kb = ip.indexToKey(b);
            if (ka == .ptr and kb == .ptr) {
                if (ka.ptr.base == .int and kb.ptr.base == .int)
                    return .fromInterned(boolValue(std.math.compare(ka.ptr.byte_offset, op, kb.ptr.byte_offset)));
                if (ka.ptr.base != .int and kb.ptr.base != .int and std.meta.eql(sema.ptrRootBase(ka.ptr), sema.ptrRootBase(kb.ptr)))
                    return .fromInterned(boolValue(std.math.compare(try sema.comptimePtrOffset(block, src, a), op, try sema.comptimePtrOffset(block, src, b))));
            }
        };
        try sema.requireRuntime(block, src);
        const tag: Ir.Inst.Tag = switch (op) {
            .lt => .cmp_lt,
            .lte => .cmp_lte,
            .gt => .cmp_gt,
            .gte => .cmp_gte,
            else => unreachable,
        };
        return sema.addBinOp(block, tag, try sema.addUnOp(block, .int_from_ptr, lhs), try sema.addUnOp(block, .int_from_ptr, rhs));
    }
    if (lc == .pointer and rc == .pointer) {
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
                    sema.comptimePtrsEqual(ka.ptr, kb.ptr) orelse
                        (try sema.comptimePtrOffset(block, src, a) == try sema.comptimePtrOffset(block, src, b))
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
    // A comptime-known operand compared with the runtime operand's whole
    // range may decide the result, even if the other is undefined, as
    // upstream (so the branch not taken is never analyzed).
    for ([2]?Index{ lv, rv }, 0..) |maybe_known, side| {
        const known = maybe_known orelse continue;
        const other_ty = if (side == 0) rt else lt;
        if (!sema.isUndef(known) and Type.class(ip, other_ty) == .int) {
            // Ordered as `known op other`.
            const kop = if (side == 0) op else op.reverse();
            var sk: [2]std.math.big.Limb = undefined;
            var smin: [2]std.math.big.Limb = undefined;
            var smax: [2]std.math.big.Limb = undefined;
            const k = ip.intToBig(known, &sk);
            const vs_min = k.order(ip.intToBig(try sema.minIntValue(other_ty), &smin));
            const vs_max = k.order(ip.intToBig(try sema.maxIntValue(other_ty), &smax));
            const res: ?bool = if (vs_min == .eq and vs_max == .eq) (std.math.Order.eq).compare(kop) else switch (kop) {
                .eq => if (vs_min == .lt or vs_max == .gt) false else null,
                .neq => if (vs_min == .lt or vs_max == .gt) true else null,
                .lt => if (vs_min == .lt) true else if (vs_max != .lt) false else null,
                .gt => if (vs_max == .gt) true else if (vs_min != .gt) false else null,
                .lte => if (vs_min != .gt) true else if (vs_max == .gt) false else null,
                .gte => if (vs_max != .lt) true else if (vs_min == .lt) false else null,
            };
            if (res) |r| return .fromInterned(boolValue(r));
        }
    }
    if (lv != null and rv != null) {
        if (sema.isUndef(lv.?) or sema.isUndef(rv.?)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
        var sa: [2]std.math.big.Limb = undefined;
        var sb: [2]std.math.big.Limb = undefined;
        const order = ip.intToBig(lv.?, &sa).order(ip.intToBig(rv.?, &sb));
        return .fromInterned(boolValue(order.compare(op)));
    }
    try sema.requireRuntime(block, src);
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
    var rhs_block = parent.condChild();
    defer rhs_block.instructions.deinit(sema.gpa);
    const rhs = try sema.coerce(&rhs_block, .bool_type, try sema.resolveInlineBody(&rhs_block, body, inst), src);
    _ = try sema.addInst(&rhs_block, .{ .tag = .br, .data = .{ .br = .{ .block_inst = block_inst, .operand = rhs } } });
    var short_block = parent.condChild();
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
    // `x and false` is false and `x or true` is true whatever `x`, as
    // upstream; both operands still run.
    if (sema.resolveValue(rhs) == boolValue(is_or)) return .fromInterned(boolValue(is_or));
    return block_inst.toRef();
}

// ---------------------------------------------------------------------------
// Memory

/// The type of a pointer to a local of type `ty` declared `align(alignment)`
/// (0 if not), whose layout is resolved.
fn allocPtrType(sema: *Sema, ty: Index, alignment: u64) !Index {
    const flag: u6 = if (alignment == 0 or alignment == Type.abiAlignment(sema.ip, ty)) 0 else @intCast(std.math.log2_int(u64, alignment) + 1);
    return sema.ptrType(.{ .child = ty, .flags = .{ .alignment = flag } });
}

fn analyzeAlloc(sema: *Sema, block: *Block, src: Src, ty: Index, is_const: bool, force_comptime: bool) CompileError!Ref {
    if (block.is_comptime or force_comptime) return .fromInterned(try sema.createComptimeAlloc(ty, is_const));
    try sema.resolveLayout(block, src, ty);
    if ((try sema.isComptimeOnlyResolved(block, src, ty))) {
        // A constant of a comptime-only type is comptime.
        if (is_const) return .fromInterned(try sema.createComptimeAlloc(ty, false));
        return sema.fail(block, src, "variable of type '{f}' must be const or comptime", .{sema.fmtType(ty)});
    }
    const ptr_ty = try sema.ptrType(.{ .child = ty });
    const ref = try sema.addInst(block, .{ .tag = .alloc, .data = .{ .ty = ptr_ty } });
    if (is_const) try sema.const_allocs.put(sema.gpa, ref.toIndex().?, .{ .block = block });
    return ref;
}

/// The runtime `const` local that pointer `ptr` (a field or element
/// pointer into it, or the local itself) addresses, if it may still be
/// comptime-known.
/// `replayable` is whether `constAllocPtr` can follow the derivation.
fn constAllocRoot(sema: *Sema, ptr: Ref) ?struct { alloc: Ir.Inst.Index, replayable: bool } {
    var r = ptr;
    var replayable = true;
    while (r.toIndex()) |i| {
        const data = sema.ir_insts.items(.data)[@backingInt(i)];
        switch (sema.ir_insts.items(.tag)[@backingInt(i)]) {
            .alloc => return if (sema.const_allocs.contains(i)) .{ .alloc = i, .replayable = replayable } else null,
            .struct_field_ptr, .ptr_elem_ptr => r = @fromBackingInt(sema.ir_extra.items[data.ty_pl.payload]),
            .optional_payload_ptr_set, .errunion_payload_ptr_set => r = data.ty_op.operand,
            .ptr_add => {
                r = @fromBackingInt(sema.ir_extra.items[data.ty_pl.payload]);
                replayable = false;
            },
            .bitcast, .optional_payload_ptr, .unwrap_errunion_payload_ptr, .unwrap_errunion_err_ptr => {
                r = data.ty_op.operand;
                if (!sema.packed_field_ptrs.contains(i)) replayable = false;
            },
            else => return null,
        }
    }
    return null;
}

/// Records a store of `val` through `ptr` for the `const` local it
/// addresses: one that stays comptime-known must get only comptime-known
/// values, from its own block.
fn trackConstStore(sema: *Sema, block: *Block, ptr: Ref, val: Ref) !void {
    if (sema.const_allocs.count() == 0) return;
    const r = sema.constAllocRoot(ptr) orelse return;
    const root = r.alloc;
    const ca = sema.const_allocs.getPtr(root).?;
    const v = sema.resolveValue(val) orelse return sema.forgetConstAlloc(root);
    if (!r.replayable or sema.refersToComptimeAlloc(v)) return sema.forgetConstAlloc(root);
    // The store must run whenever the local is initialized: from its own
    // block or a labeled block in it, not a branch.
    var b = block;
    while (b != ca.block) {
        if (b.runtime_cond) return sema.forgetConstAlloc(root);
        b = b.parent orelse return sema.forgetConstAlloc(root);
    }
    try ca.stores.append(sema.arena, .{ .ptr = ptr, .val = v });
}

fn forgetConstAlloc(sema: *Sema, root: Ir.Inst.Index) void {
    _ = sema.const_allocs.remove(root);
}

/// Stops tracking the `const` local `ptr` addresses, which something other
/// than a store writes.
fn forgetConstAllocOf(sema: *Sema, ptr: Ref) void {
    if (sema.const_allocs.count() == 0) return;
    if (sema.constAllocRoot(ptr)) |r| sema.forgetConstAlloc(r.alloc);
}

/// `const` local `alloc`, done being initialized, as a pointer to a
/// comptime-known value if every store into it was comptime-known, as
/// upstream does; else null. The runtime stores stay but go unread.
fn foldConstAlloc(sema: *Sema, block: *Block, src: Src, alloc: Ir.Inst.Index) CompileError!?Index {
    const ca = (sema.const_allocs.fetchRemove(alloc) orelse return null).value;
    const ip = sema.ip;
    const ptr_ty = sema.ir_insts.items(.data)[@backingInt(alloc)].ty;
    const child = Type.ptrInfo(ip, ptr_ty).child;
    const id = ip.indexToKey(try sema.createComptimeAlloc(child, false)).ptr.base.comptime_alloc;
    for (ca.stores.items) |st| {
        const p = try sema.constAllocPtr(st.ptr, alloc, id) orelse return null;
        sema.comptimeStore(block, src, p, st.val) catch |err| switch (err) {
            error.AnalysisFail => return null,
            else => return err,
        };
    }
    const val = sema.comptime_allocs.get(id).?.val;
    var info = Type.ptrInfo(ip, ptr_ty);
    info.flags.is_const = true;
    const const_ty = try sema.ptrType(info);
    return try sema.intern(.{ .ptr = .{ .ty = const_ty, .base = .{ .uav = .{ .val = val, .orig_ty = const_ty } } } });
}

/// Runtime pointer `ptr` into `alloc`, as a pointer into comptime alloc
/// `id`; null for derivations zap does not replay.
fn constAllocPtr(sema: *Sema, ptr: Ref, alloc: Ir.Inst.Index, id: u32) !?Index {
    const i = ptr.toIndex().?;
    const ty = sema.typeOf(ptr);
    const data = sema.ir_insts.items(.data)[@backingInt(i)];
    switch (sema.ir_insts.items(.tag)[@backingInt(i)]) {
        .alloc => return try sema.intern(.{ .ptr = .{ .ty = ty, .base = .{ .comptime_alloc = id } } }),
        .struct_field_ptr => {
            const sf = sema.ir_extra.items[data.ty_pl.payload..][0..2];
            const base = try sema.constAllocPtr(@fromBackingInt(sf[0]), alloc, id) orelse return null;
            return try sema.intern(.{ .ptr = .{ .ty = ty, .base = .{ .field = .{ .base = base, .index = sf[1] } } } });
        },
        .ptr_elem_ptr => {
            const bin = sema.ir_extra.items[data.ty_pl.payload..][0..2];
            const base = try sema.constAllocPtr(@fromBackingInt(bin[0]), alloc, id) orelse return null;
            const index = sema.resolveValue(@fromBackingInt(bin[1])) orelse return null;
            return try sema.ptrElemPtrVal(base, sema.ip.intValue(u64, index).?);
        },
        .bitcast => {
            const index = sema.packed_field_ptrs.get(i) orelse return null;
            const base = try sema.constAllocPtr(data.ty_op.operand, alloc, id) orelse return null;
            return try sema.intern(.{ .ptr = .{ .ty = ty, .base = .{ .field = .{ .base = base, .index = index } } } });
        },
        .optional_payload_ptr_set, .errunion_payload_ptr_set => {
            const base = try sema.constAllocPtr(data.ty_op.operand, alloc, id) orelse return null;
            return try sema.intern(.{ .ptr = .{ .ty = ty, .base = .{ .field = .{ .base = base, .index = 0 } } } });
        },
        else => return null,
    }
}

fn allocInferred(sema: *Sema, block: *Block, is_const: bool, force_comptime: bool) CompileError!Ref {
    if (block.is_comptime or force_comptime) return .fromInterned(try sema.createComptimeAlloc(.none, is_const));
    const ref = try sema.addInst(block, .{ .tag = .alloc, .data = .{ .ty = .none } });
    try sema.inferred_allocs.put(sema.gpa, ref.toIndex().?, .{ .is_const = is_const, .block = block });
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
    if (ia.block != block) ia.same_block = false;
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
        if (alloc.alignment != 0) try sema.resolveLayout(block, src, alloc.ty);
        var info = Type.ptrInfo(sema.ip, try sema.allocPtrType(alloc.ty, alloc.alignment));
        info.flags.is_const = alloc.is_const;
        const ptr_ty = try sema.ptrType(info);
        return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = ptr_ty, .base = .{ .comptime_alloc = id } } }));
    }
    const alloc_inst = ptr.toIndex().?;
    const ia = sema.inferred_allocs.getPtr(alloc_inst).?;
    const operands = try sema.arena.alloc(Ref, ia.stores.items.len);
    for (ia.stores.items, operands) |store, *op| op.* = sema.ir_insts.items(.data)[@backingInt(store)].bin_op.rhs;
    const ty = try sema.resolvePeerTypes(block, src, operands);
    if (ty == .noreturn_type) return sema.fail(block, src, "unable to infer variable type", .{});
    if (ia.is_const and ia.same_block and operands.len == 1 and ia.alignment == 0) {
        // A constant initialized once with a comptime-known value is
        // comptime-known, as upstream; the runtime store goes unread.
        const coerced = try sema.coerce(block, ty, operands[0], src);
        if (sema.resolveValue(coerced)) |v| if (!sema.refersToComptimeAlloc(v)) {
            try sema.resolveLayoutIfIdle(block, src, ty);
            const const_ty = try sema.ptrType(.{ .child = ty, .flags = .{ .is_const = true } });
            sema.ir_insts.items(.data)[@backingInt(alloc_inst)] = .{ .ty = try sema.ptrType(.{ .child = ty }) };
            if ((try sema.isComptimeOnlyResolved(block, src, ty))) {
                // The runtime alloc cannot hold it: drop the store.
                const payload = try sema.addExtra(Ir.Block{ .body_len = 0 });
                sema.ir_insts.set(@backingInt(ia.stores.items[0]), .{ .tag = .block, .data = .{ .ty_pl = .{ .ty = .void_type, .payload = payload } } });
            } else try sema.coerceBrOperand(block, ia.stores.items[0], ty, operands[0], src);
            return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = const_ty, .base = .{ .uav = .{ .val = v, .orig_ty = const_ty } } } }));
        };
    }
    if ((try sema.isComptimeOnlyResolved(block, src, ty))) return sema.fail(block, src, "variable of type '{f}' must be const or comptime", .{sema.fmtType(ty)});
    try sema.resolveLayout(block, src, ty);
    const ptr_ty = try sema.allocPtrType(ty, ia.alignment);
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
        if (sema.intoComptimeField(pv)) {
            // A store into a comptime field (or a part of it) only checks
            // that the value matches.
            if (sema.resolveValue(operand) != try sema.comptimeLoadOrNull(block, src, pv))
                return sema.fail(block, src, "value stored in comptime field does not match the default value of the field", .{});
            return;
        }
        if (try sema.comptimePtrRoot(pv) == .comptime_alloc) {
            const val = try sema.resolveConstValue(block, src, operand, "value stored to a comptime variable must be comptime-known");
            return sema.comptimeStore(block, src, pv, val);
        }
    }
    try sema.trackConstStore(block, ptr, operand);
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
        // Under @TypeOf only the type matters, also through a generic
        // function's runtime parameter, which stands as undefined.
        if (block.is_typeof and sema.isUndef(pv)) return .fromInterned(try sema.undefValue(info.child));
        if (try sema.comptimeLoadOrNull(block, src, pv)) |v| return .fromInterned(v);
    }
    try sema.resolveLayout(block, src, info.child);
    const zero_bit = !Type.hasRuntimeBits(ip, info.child) and !Type.isComptimeOnly(ip, info.child);
    // Even at comptime, through a runtime pointer.
    if (zero_bit) if (try sema.onePossibleValue(info.child)) |v| return .fromInterned(v);
    try sema.requireRuntime(block, src);
    if (Type.isComptimeOnly(ip, info.child)) return sema.fail(block, src, "unable to load comptime-only type '{f}' at runtime", .{sema.fmtType(info.child)});
    if (info.packed_offset.host_size != 0) {
        const host_ty = try sema.intType(.unsigned, info.packed_offset.host_size * 8);
        const host_ptr = try sema.addTyOp(block, .bitcast, try sema.ptrType(.{ .child = host_ty, .flags = .{ .is_const = true, .is_volatile = info.flags.is_volatile } }), ptr);
        return sema.packedExtract(block, try sema.addTyOp(block, .load, host_ty, host_ptr), info.packed_offset.bit_offset, info.child);
    }
    return sema.addTyOp(block, .load, info.child, ptr);
}

/// The only value of zero-bit runtime type `ty`, as upstream: loads of it
/// are comptime-known. Null for types zap does not fold (unions, enums).
fn onePossibleValue(sema: *Sema, ty: Index) CompileError!?Index {
    const ip = sema.ip;
    switch (ip.indexToKey(ty)) {
        .simple_type => |s| return if (s == .void) .void_value else null,
        .int_type => |t| return if (t.bits == 0) try sema.intValue(ty, 0) else null,
        // An enum is its tag type, as upstream's Type.classify.
        .enum_type => {
            const tag_ty = ip.structInfo(ty).tag_type;
            if (Type.class(ip, tag_ty) != .int or Type.intInfo(ip, tag_ty).bits != 0) return null;
            return try sema.intern(.{ .enum_tag = .{ .ty = ty, .int = try sema.intValue(tag_ty, 0) } });
        },
        .array_type => |a| {
            if (a.lenIncludingSentinel() == 0) return try sema.intern(.{ .aggregate = .{ .ty = ty, .storage = .{ .elems = &.{} } } });
            const elem = (try sema.onePossibleValue(a.child)) orelse return null;
            return try sema.intern(.{ .aggregate = .{ .ty = ty, .storage = .{ .repeated_elem = elem } } });
        },
        .tuple_type => |t| {
            const elems = try sema.arena.alloc(Index, t.types.len);
            for (elems, t.types, t.values) |*e, ft, fv| e.* = if (fv != .none) fv else (try sema.onePossibleValue(ft)) orelse return null;
            return try sema.intern(.{ .aggregate = .{ .ty = ty, .storage = .{ .elems = elems } } });
        },
        .struct_type => {
            // A `comptime` field has its value, part of the layout.
            const info = ip.structInfo(ty);
            const elems = try sema.arena.alloc(Index, info.field_types.len);
            for (elems, info.field_types, 0..) |*e, ft, i| e.* = if (info.fieldIsComptime(i)) info.field_defaults[i] else (try sema.onePossibleValue(ft)) orelse return null;
            return try sema.intern(.{ .aggregate = .{ .ty = ty, .storage = .{ .elems = elems } } });
        },
        else => return null,
    }
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
        // A reference to a function is a pointer to its declaration.
        if (sema.ip.indexToKey(v) == .func) {
            const f = sema.ip.indexToKey(v).func;
            if (f.generic_owner == .none and sema.ip.getNav(f.owner_nav).val == v) return sema.navRef(block, src, f.owner_nav);
        }
        try sema.resolveLayoutIfIdle(block, src, ty);
        return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = ptr_ty, .base = .{ .uav = .{ .val = v, .orig_ty = ptr_ty } } } }));
    }
    try sema.requireRuntime(block, src);
    try sema.resolveLayout(block, src, ty);
    const alloc = try sema.addInst(block, .{ .tag = .alloc, .data = .{ .ty = ptr_ty } });
    _ = try sema.addBinOp(block, .store, alloc, operand);
    return alloc;
}

/// Dereferencing a C pointer goes through a single pointer, checked for
/// null, as upstream.
fn cPtrToSingle(sema: *Sema, block: *Block, src: Src, ptr: Ref) CompileError!Ref {
    var info = Type.ptrInfo(sema.ip, sema.typeOf(ptr));
    if (info.flags.size != .c) return ptr;
    info.flags.size = .one;
    info.flags.is_allowzero = false;
    const single_ty = try sema.ptrType(info);
    if (sema.resolveValue(ptr)) |v| {
        const k = sema.ip.indexToKey(v);
        // Under `@TypeOf`, only the type matters, as upstream.
        if (k == .ptr and k.ptr.base == .int and k.ptr.byte_offset == 0 and !block.is_typeof) return sema.fail(block, src, "unable to unwrap null", .{});
    } else if (block.want_safety and !block.is_comptime) {
        const ok = try sema.addBinOp(block, .cmp_neq, try sema.addUnOp(block, .int_from_ptr, ptr), .fromInterned(.zero_usize));
        try sema.addSafetyCheck(block, ok, .unwrap_null, .none, .none);
    }
    return sema.coercePtrTo(block, ptr, single_ty);
}

/// `ptr.*` as a single pointer: a C pointer, checked for null, or a
/// comptime-known slice, as a pointer to an array of its length.
fn derefPtr(sema: *Sema, block: *Block, src: Src, ptr: Ref) CompileError!Ref {
    const ty = sema.typeOf(ptr);
    if (Type.class(sema.ip, ty) != .pointer) return sema.fail(block, src, "cannot dereference non-pointer type '{f}'", .{sema.fmtType(ty)});
    if (Type.ptrInfo(sema.ip, ty).flags.size == .many) return sema.fail(block, src, "index syntax required for unknown-length pointer type '{f}'", .{sema.fmtType(ty)});
    if (Type.ptrInfo(sema.ip, ty).flags.size == .slice) {
        const v = sema.resolveValue(ptr) orelse return sema.fail(block, src, "index syntax required to access runtime-known slice", .{});
        if (sema.isUndef(v)) return sema.fail(block, src, "cannot dereference undefined value", .{});
        return sema.sliceToArrayPtr(block, src, v);
    }
    return sema.cPtrToSingle(block, src, ptr);
}

/// A comptime-known slice as a pointer to an array of its length, keeping
/// its sentinel, as upstream's `sliceToArrayPtr`.
fn sliceToArrayPtr(sema: *Sema, block: *Block, src: Src, slice: Index) CompileError!Ref {
    const ip = sema.ip;
    const k = ip.indexToKey(slice).slice;
    if (k.len == .undef_usize) return sema.fail(block, src, "cannot dereference slice with undefined length", .{});
    var info = Type.ptrInfo(ip, ip.typeOf(slice));
    const array_ty = try sema.intern(.{ .array_type = .{ .len = ip.intValue(u64, k.len).?, .child = info.child, .sentinel = info.sentinel } });
    info.flags.size = .one;
    info.child = array_ty;
    info.sentinel = .none;
    const ptr_ty = try sema.ptrType(info);
    const many = try sema.slicePtr(block, .fromInterned(slice));
    const pv = sema.resolveValue(many).?;
    if (sema.isUndef(pv)) return .fromInterned(try sema.undefValue(ptr_ty));
    const p = ip.indexToKey(pv).ptr;
    if (p.base == .elem and p.base.elem.index == 0 and ip.typeOf(p.base.elem.base) == ptr_ty) return .fromInterned(p.base.elem.base);
    return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = ptr_ty, .base = p.base, .byte_offset = p.byte_offset } }));
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
    // The same allocation: compare byte offsets into it, when known.
    const oa = sema.ptrRootOffset(a) orelse return null;
    const ob = sema.ptrRootOffset(b) orelse return null;
    return oa == ob;
}

/// The byte offset of comptime pointer `ptr` into its allocation, or null
/// if a layout on the way is not known (a packed field, or a type whose
/// layout is unresolved).
fn ptrRootOffset(sema: *Sema, ptr: InternPool.Ptr) ?u64 {
    const ip = sema.ip;
    const known = struct {
        fn f(p: *InternPool, ty: Index) bool {
            return switch (p.indexToKey(ty)) {
                .struct_type, .union_type, .enum_type => p.structInfo(ty).status == .have_layout,
                .array_type => |a| f(p, a.child),
                .vector_type => |v| f(p, v.child),
                .opt_type => |c| f(p, c),
                .error_union_type => |e| f(p, e.payload_type),
                .tuple_type => |t| for (t.types) |ft| {
                    if (!f(p, ft)) break false;
                } else true,
                else => true,
            };
        }
    }.f;
    switch (ptr.base) {
        .field => |f| {
            const parent = ip.indexToKey(f.base).ptr;
            const agg = Type.ptrInfo(ip, parent.ty).child;
            if (!known(ip, agg) or Type.isPacked(ip, agg) or Type.isSlice(ip, agg)) return null;
            if (ip.indexToKey(agg) == .struct_type or ip.indexToKey(agg) == .tuple_type) {
                if (Type.comptimeFieldValue(ip, agg, f.index) != .none) return null;
            }
            return (sema.ptrRootOffset(parent) orelse return null) + Type.fieldOffset(ip, agg, f.index) + ptr.byte_offset;
        },
        .elem => |e| {
            const parent = ip.indexToKey(e.base).ptr;
            // The element type is the base's: a pointer cast keeps the base
            // (`@as(*u32, @ptrCast(&bytes[4]))` is 4 bytes in, not 16).
            const base_ty = Type.ptrInfo(ip, parent.ty);
            const elem_ty = switch (ip.indexToKey(base_ty.child)) {
                .array_type => |a| if (base_ty.flags.size == .one) a.child else base_ty.child,
                .vector_type => |v| if (base_ty.flags.size == .one) v.child else base_ty.child,
                else => base_ty.child,
            };
            const size = if (e.index == 0) 0 else if (known(ip, elem_ty)) Type.abiSize(ip, elem_ty) else return null;
            return (sema.ptrRootOffset(parent) orelse return null) + e.index * size + ptr.byte_offset;
        },
        .int => return null,
        else => return ptr.byte_offset,
    }
}

/// The byte offset of comptime pointer `ptr` within its allocation, as
/// CodeGen's `ptrTarget` lays it out. A pointer to a packed struct field
/// points to the struct's backing integer.
fn comptimePtrOffset(sema: *Sema, block: *Block, src: Src, ptr: Index) CompileError!u64 {
    const ip = sema.ip;
    const k = ip.indexToKey(ptr).ptr;
    const base: u64 = switch (k.base) {
        .field => |f| blk: {
            const parent = try sema.comptimePtrOffset(block, src, f.base);
            const container = Type.ptrInfo(ip, ip.typeOf(f.base)).child;
            try sema.resolveLayout(block, src, container);
            break :blk parent + switch (ip.indexToKey(container)) {
                .opt_type => 0,
                .error_union_type => Type.errorUnionLayout(ip, container).payload_offset,
                .ptr_type => f.index * 8,
                else => Type.fieldOffset(ip, container, @intCast(f.index)),
            };
        },
        .elem => |e| blk: {
            const parent = try sema.comptimePtrOffset(block, src, e.base);
            const base_ty = Type.ptrInfo(ip, ip.typeOf(e.base));
            const elem_ty = switch (ip.indexToKey(base_ty.child)) {
                .array_type => |a| if (base_ty.flags.size == .one) a.child else base_ty.child,
                .vector_type => |v| if (base_ty.flags.size == .one) v.child else base_ty.child,
                else => base_ty.child,
            };
            try sema.resolveLayout(block, src, elem_ty);
            break :blk parent + e.index * Type.abiSize(ip, elem_ty);
        },
        else => 0,
    };
    return base +% k.byte_offset;
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
    const load_ty = Type.ptrInfo(ip, ip.typeOf(ptr)).child;
    // Even through an undefined pointer, a zero-bit type has its one value.
    if (sema.isUndef(ptr)) if (try sema.onePossibleValue(load_ty)) |v| return v;
    const v = (try sema.comptimeLoadStructural(block, src, ptr)) orelse return null;
    const v_ty = ip.typeOf(v);
    if (v_ty == load_ty or load_ty == .generic_poison_type or load_ty == .anyopaque_type) return v;
    if (sema.childCoercibleInMemory(v_ty, load_ty)) return try sema.retypeInMemory(v, load_ty);
    // The pointer views the memory as another type.
    return sema.reinterpretLoad(block, src, ptr);
}

/// The value a comptime-known pointer addresses, found by following the
/// pointer's steps through the values; its type may differ from the
/// pointer's child type when the pointer was cast.
fn comptimeLoadStructural(sema: *Sema, block: *Block, src: Src, ptr: Index) CompileError!?Index {
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
            if (key.byte_offset != 0) return sema.reinterpretLoad(block, src, ptr);
            const parent = (try sema.comptimeLoadStructural(block, src, f.base)) orelse break :blk null;
            const parent_ty = Type.ptrInfo(ip, ip.typeOf(f.base)).child;
            if (ip.typeOf(parent) != parent_ty)
                return sema.reinterpretLoad(block, src, ptr);
            // An extern union's inactive field reads its bytes.
            if (Type.class(ip, parent_ty) == .@"union" and ip.structInfo(parent_ty).layout == .@"extern" and ip.indexToKey(parent) == .un and
                ip.indexToKey(parent).un.tag != try sema.unionFieldTagValue(parent_ty, @intCast(f.index)))
            {
                const field_ty = ip.structInfo(parent_ty).field_types[f.index];
                try sema.resolveLayout(block, src, field_ty);
                break :blk try sema.readMem(block, src, parent, 0, field_ty);
            }
            break :blk try sema.fieldValue(parent, @intCast(f.index));
        },
        .elem => |e| blk: {
            if (key.byte_offset != 0) return sema.reinterpretLoad(block, src, ptr);
            const parent = (try sema.comptimeLoadStructural(block, src, e.base)) orelse break :blk null;
            const parent_ty = Type.ptrInfo(ip, ip.typeOf(e.base)).child;
            if (ip.indexToKey(parent_ty) == .vector_type) {
                if (ip.typeOf(parent) != parent_ty or e.index >= ip.indexToKey(parent_ty).vector_type.len)
                    return sema.reinterpretLoad(block, src, ptr);
                break :blk try sema.elemValue(parent, e.index);
            }
            if (ip.indexToKey(parent_ty) != .array_type) break :blk null;
            if (ip.indexToKey(ip.typeOf(parent)) != .array_type) {
                // A single item viewed as a one-element array (`*T` to `*[1]T`).
                if (e.index == 0 and ip.typeOf(parent) == ip.indexToKey(parent_ty).array_type.child) break :blk parent;
                return sema.reinterpretLoad(block, src, ptr);
            }
            if (ip.typeOf(parent) != parent_ty or e.index >= ip.indexToKey(parent_ty).array_type.lenIncludingSentinel())
                return sema.reinterpretLoad(block, src, ptr);
            const elem_ty = ip.indexToKey(parent_ty).array_type.child;
            const load_ty = Type.ptrInfo(ip, key.ty).child;
            if (load_ty != elem_ty and ip.indexToKey(load_ty) == .array_type and ip.indexToKey(load_ty).array_type.child == elem_ty) {
                // A subarray (from slicing with comptime-known bounds).
                const a = ip.indexToKey(load_ty).array_type;
                if (e.index + a.len > ip.indexToKey(parent_ty).array_type.lenIncludingSentinel())
                    return sema.reinterpretLoad(block, src, ptr);
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
    // Elements may be read through a pointer to an in-memory coercible
    // type (`[:0]const u8` elements as `[]const u8`).
    const retype = load_ty != a.child and sema.childCoercibleInMemory(a.child, load_ty);
    if (load_ty != a.child and !retype) return if (key.byte_offset == 0) val else null;
    const size = Type.abiSize(ip, a.child);
    const elem = if (size == 0) try sema.elemValue(val, 0) else blk: {
        if (key.byte_offset % size != 0 or key.byte_offset / size > a.len) return null;
        break :blk try sema.elemValue(val, key.byte_offset / size);
    };
    return if (retype) try sema.retypePtrValue(elem, load_ty) else elem;
}

/// Value `val` as in-memory coercible type `ty` (see
/// `childCoercibleInMemory`).
fn retypeInMemory(sema: *Sema, val: Index, ty: Index) !Index {
    const ip = sema.ip;
    if (sema.isUndef(val)) return sema.undefValue(ty);
    if (Type.class(ip, ty) == .int) return sema.bigToValue(ty, (try sema.bigValue(val)).toConst());
    switch (ip.indexToKey(val)) {
        .ptr, .slice, .opt => {},
        else => return val,
    }
    // `*T` read as `?*T`.
    if (Type.class(ip, ty) == .optional and Type.class(ip, ip.typeOf(val)) != .optional)
        return sema.intern(.{ .opt = .{ .ty = ty, .val = try sema.retypePtrValue(val, Type.childType(ip, ty)) } });
    return sema.retypePtrValue(val, ty);
}

/// Pointer or slice value `val` as in-memory coercible pointer type `ty`.
fn retypePtrValue(sema: *Sema, val: Index, ty: Index) !Index {
    const ip = sema.ip;
    return switch (ip.indexToKey(val)) {
        .slice => |sl| sema.intern(.{ .slice = .{ .ty = ty, .ptr = try sema.retypePtrValue(sl.ptr, try sema.elemValueType(ty)), .len = sl.len } }),
        .ptr => |pk| sema.intern(.{ .ptr = .{ .ty = ty, .base = pk.base, .byte_offset = pk.byte_offset } }),
        .opt => |o| sema.intern(.{ .opt = .{ .ty = ty, .val = if (o.val == .none) .none else try sema.retypePtrValue(o.val, Type.childType(ip, ty)) } }),
        else => sema.undefValue(ty),
    };
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
                // A store through a cast pointer writes the bytes it covers.
                if (alloc.val != .none and !sema.childCoercibleInMemory(sema.ip.typeOf(val), sema.ip.typeOf(alloc.val)))
                    return sema.reinterpretStore(block, src, ptr, val);
                alloc.val = val;
            } else {
                // An element addressed by offset (through a many-pointer).
                const ip = sema.ip;
                const arr_ty = ip.typeOf(alloc.val);
                if (ip.indexToKey(arr_ty) != .array_type) return sema.reinterpretStore(block, src, ptr, val);
                const a = ip.indexToKey(arr_ty).array_type;
                const size = Type.abiSize(ip, a.child);
                if (size == 0 or key.byte_offset % size != 0) return sema.reinterpretStore(block, src, ptr, val);
                if (key.byte_offset / size >= a.len or ip.typeOf(val) != a.child) return sema.reinterpretStore(block, src, ptr, val);
                alloc.val = try sema.withElem(alloc.val, key.byte_offset / size, val);
            }
        },
        .field => |f| {
            if (key.byte_offset != 0) return sema.reinterpretStore(block, src, ptr, val);
            const parent = (try sema.comptimeLoadStructural(block, src, f.base)) orelse return sema.fail(block, src, "unable to evaluate comptime expression: memory is runtime-known", .{});
            if (sema.ip.typeOf(parent) != Type.ptrInfo(sema.ip, sema.ip.typeOf(f.base)).child)
                return sema.reinterpretStore(block, src, ptr, val);
            try sema.comptimeStore(block, src, f.base, try sema.withElem(parent, f.index, val));
        },
        .elem => |e| {
            if (key.byte_offset != 0) return sema.reinterpretStore(block, src, ptr, val);
            const parent = (try sema.comptimeLoadStructural(block, src, e.base)) orelse return sema.fail(block, src, "unable to evaluate comptime expression: memory is runtime-known", .{});
            const parent_ty = sema.ip.typeOf(parent);
            if (sema.ip.indexToKey(parent_ty) == .vector_type) {
                const v = sema.ip.indexToKey(parent_ty).vector_type;
                if (e.index >= v.len or sema.ip.typeOf(val) != v.child) return sema.reinterpretStore(block, src, ptr, val);
                return sema.comptimeStore(block, src, e.base, try sema.withElem(parent, e.index, val));
            }
            if (sema.ip.indexToKey(parent_ty) != .array_type) {
                // A single item viewed as a one-element array.
                if (e.index == 0 and parent_ty == sema.ip.typeOf(val)) return sema.comptimeStore(block, src, e.base, val);
                return sema.reinterpretStore(block, src, ptr, val);
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
            if (e.index >= a.lenIncludingSentinel() or val_ty != a.child) return sema.reinterpretStore(block, src, ptr, val);
            try sema.comptimeStore(block, src, e.base, try sema.withElem(parent, e.index, val));
        },
        else => return sema.fail(block, src, "unable to store to this memory at comptime", .{}),
    }
}

// ---------------------------------------------------------------------------
// Comptime memory reinterpretation
//
// A load or store through a pointer whose type does not match the value it
// addresses (`@as(*i32, @ptrCast(&x))`, an extern struct viewed as bytes)
// works on the memory of the variable or constant it points into, as laid
// out on the target (little-endian). It descends to the smallest field or
// element holding the accessed bytes and turns only that into bytes, so
// pointers to memory elsewhere in the value, which have no bytes at
// comptime, survive.

/// The value at the root of pointer `ptr` (a comptime variable, an
/// anonymous constant, or a declaration) and `ptr`'s byte offset in it, or
/// null if a step of the pointer has no byte offset zap models.
fn ptrMemRoot(sema: *Sema, ptr: Index) ?struct { base: InternPool.Ptr.BaseAddr, offset: u64 } {
    const ip = sema.ip;
    var k = ip.indexToKey(ptr).ptr;
    var offset: u64 = 0;
    while (true) {
        offset +%= k.byte_offset;
        switch (k.base) {
            .field => |f| {
                const parent_ty = Type.ptrInfo(ip, ip.typeOf(f.base)).child;
                switch (ip.indexToKey(parent_ty)) {
                    .struct_type => if (Type.isPacked(ip, parent_ty)) return null,
                    .tuple_type => {},
                    else => return null,
                }
                offset +%= Type.fieldOffset(ip, parent_ty, @intCast(f.index));
                k = ip.indexToKey(f.base).ptr;
            },
            .elem => |e| {
                const elem_ty = sema.memElemType(ip.typeOf(e.base));
                if (Type.class(ip, Type.ptrInfo(ip, ip.typeOf(e.base)).child) == .vector and !sema.memWholeBytes(elem_ty)) return null;
                offset +%= e.index *% Type.abiSize(ip, elem_ty);
                k = ip.indexToKey(e.base).ptr;
            },
            else => return .{ .base = k.base, .offset = offset },
        }
    }
}

/// The type of the elements an element pointer with base pointer type
/// `base_ptr_ty` steps over.
fn memElemType(sema: *Sema, base_ptr_ty: Index) Index {
    const ip = sema.ip;
    const parent_ty = Type.ptrInfo(ip, base_ptr_ty).child;
    return switch (ip.indexToKey(parent_ty)) {
        .array_type => |a| a.child,
        .vector_type => |v| v.child,
        // A single item viewed as an array.
        else => parent_ty,
    };
}

/// Whether `ty`'s values fill their bytes, so that a vector of them is laid
/// out element after element.
fn memWholeBytes(sema: *Sema, ty: Index) bool {
    const bits = sema.bitCastBits(ty) orelse return false;
    return bits == Type.abiSize(sema.ip, ty) * 8;
}

/// The number of fields or elements of `ty` that reinterpretation treats
/// separately: those of arrays (with the sentinel), vectors of whole-byte
/// elements, and structs and tuples that are not packed.
fn memChildCount(sema: *Sema, ty: Index) ?usize {
    const ip = sema.ip;
    return switch (ip.indexToKey(ty)) {
        .array_type => |a| @intCast(a.lenIncludingSentinel()),
        .vector_type => |v| if (sema.memWholeBytes(v.child)) v.len else null,
        .struct_type => if (Type.isPacked(ip, ty)) null else Type.fieldCount(ip, ty),
        .tuple_type => |t| t.types.len,
        else => null,
    };
}

fn memChildOffset(sema: *Sema, ty: Index, i: usize) u64 {
    const ip = sema.ip;
    return switch (ip.indexToKey(ty)) {
        .vector_type => |v| i * Type.abiSize(ip, v.child),
        else => Type.fieldOffset(ip, ty, i),
    };
}

fn memChildType(sema: *Sema, ty: Index, i: usize) Index {
    return switch (sema.ip.indexToKey(ty)) {
        .vector_type => |v| v.child,
        else => Type.fieldType(sema.ip, ty, i),
    };
}

/// Loads a value of `ptr`'s child type from the memory `ptr` points into.
/// Null if that memory is only known at runtime.
fn reinterpretLoad(sema: *Sema, block: *Block, src: Src, ptr: Index) CompileError!?Index {
    const ty = Type.ptrInfo(sema.ip, sema.ip.typeOf(ptr)).child;
    const base = sema.arrayBase(ty);
    if (Type.isComptimeOnly(sema.ip, base.ty)) return sema.restructureLoad(block, src, ptr, ty);
    const root = sema.ptrMemRoot(ptr) orelse {
        // A step without a byte offset (a packed struct field): the parent
        // reinterpreted as a whole, then the field.
        const k = sema.ip.indexToKey(ptr).ptr;
        if (k.byte_offset == 0 and k.base == .field) {
            const parent = (try sema.comptimeLoadOrNull(block, src, k.base.field.base)) orelse return null;
            return try sema.fieldValue(parent, @intCast(k.base.field.index));
        }
        return sema.failUnsupported(block, src, "reinterpreting memory at comptime");
    };
    const root_val = (try sema.memRootValue(block, src, root.base)) orelse return null;
    try sema.resolveLayout(block, src, ty);
    try sema.resolveLayout(block, src, sema.ip.typeOf(root_val));
    return try sema.readMem(block, src, root_val, root.offset, ty);
}

/// The value at the root of a pointer, or null if it is only known at
/// runtime.
fn memRootValue(sema: *Sema, block: *Block, src: Src, base: InternPool.Ptr.BaseAddr) CompileError!?Index {
    return switch (base) {
        .comptime_alloc => |id| (sema.comptime_allocs.get(id) orelse
            return sema.fail(block, src, "comptime variable is not accessible here", .{})).val,
        .uav => |u| u.val,
        .nav => |n| blk: {
            try sema.ensureNavVal(block, src, n);
            const nav = sema.ip.getNav(n);
            if (!nav.is_const) return null;
            break :blk nav.val;
        },
        else => null,
    };
}

/// `ty` seen as nested arrays: the innermost element type and how many of
/// them `ty` holds (sentinels aside).
fn arrayBase(sema: *Sema, ty: Index) struct { ty: Index, len: u64 } {
    var t = ty;
    var len: u64 = 1;
    while (sema.ip.indexToKey(t) == .array_type) {
        const a = sema.ip.indexToKey(t).array_type;
        len *= a.len;
        t = a.child;
    }
    return .{ .ty = t, .len = len };
}

/// Loads a `ty` through `ptr` when its innermost element type is
/// comptime-only, which has no bytes: as upstream, nested arrays of it
/// are restructured element by element (`*const [3][2]comptime_int` read
/// as `*const [2][3]comptime_int`).
fn restructureLoad(sema: *Sema, block: *Block, src: Src, ptr: Index, ty: Index) CompileError!?Index {
    const ip = sema.ip;
    const base = sema.arrayBase(ty);
    var k = ip.indexToKey(ptr).ptr;
    var pos: u64 = 0;
    const root_val = while (true) {
        if (k.byte_offset != 0) return sema.failUnsupported(block, src, "reinterpreting memory at comptime");
        switch (k.base) {
            .elem => |e| {
                const parent_ty = Type.ptrInfo(ip, ip.typeOf(e.base)).child;
                const elem_ty = if (ip.indexToKey(parent_ty) == .array_type) ip.indexToKey(parent_ty).array_type.child else parent_ty;
                pos += e.index * sema.arrayBase(elem_ty).len;
                k = ip.indexToKey(e.base).ptr;
            },
            .field, .int => return sema.failUnsupported(block, src, "reinterpreting memory at comptime"),
            else => break (try sema.memRootValue(block, src, k.base)) orelse return null,
        }
    };
    const root_base = sema.arrayBase(ip.typeOf(root_val));
    if (root_base.ty != base.ty) return sema.failUnsupported(block, src, "reinterpreting memory at comptime");
    if (pos + base.len > root_base.len)
        return sema.fail(block, src, "dereference of '{f}' exceeds bounds of containing decl of type '{f}'", .{ sema.fmtType(ip.typeOf(ptr)), sema.fmtType(ip.typeOf(root_val)) });
    const flat = try sema.arena.alloc(Index, @intCast(root_base.len));
    var n: usize = 0;
    try sema.flattenArray(root_val, flat, &n);
    var i: usize = @intCast(pos);
    return try sema.buildArray(ty, flat, &i);
}

fn flattenArray(sema: *Sema, val: Index, out: []Index, n: *usize) CompileError!void {
    const ty = sema.ip.typeOf(val);
    if (sema.ip.indexToKey(ty) != .array_type) {
        out[n.*] = val;
        n.* += 1;
        return;
    }
    for (0..@intCast(sema.ip.indexToKey(ty).array_type.len)) |i| try sema.flattenArray(try sema.elemValue(val, i), out, n);
}

fn buildArray(sema: *Sema, ty: Index, flat: []const Index, i: *usize) CompileError!Index {
    if (sema.ip.indexToKey(ty) != .array_type) {
        defer i.* += 1;
        return flat[i.*];
    }
    const a = sema.ip.indexToKey(ty).array_type;
    const elems = try sema.arena.alloc(Index, @intCast(a.lenIncludingSentinel()));
    for (elems[0..@intCast(a.len)]) |*e| e.* = try sema.buildArray(a.child, flat, i);
    if (a.sentinel != .none) elems[@intCast(a.len)] = a.sentinel;
    return sema.intern(.{ .aggregate = .{ .ty = ty, .storage = .{ .elems = elems } } });
}

/// The value of type `ty` at byte `offset` of value `val`.
fn readMem(sema: *Sema, block: *Block, src: Src, val: Index, offset: u64, ty: Index) CompileError!Index {
    const ip = sema.ip;
    const val_ty = ip.typeOf(val);
    if (val_ty == ty and offset == 0) return val;
    const size = Type.abiSize(ip, ty);
    if (size == 0) if (try sema.onePossibleValue(ty)) |v| return v;
    if (offset > Type.abiSize(ip, val_ty) or size > Type.abiSize(ip, val_ty) - offset)
        return sema.fail(block, src, "dereference of '{f}' exceeds bounds of containing decl of type '{f}'", .{ sema.fmtType(try sema.ptrType(.{ .child = ty })), sema.fmtType(val_ty) });
    // Descend into the field or element holding all of the bytes.
    if (!sema.isUndef(val)) if (sema.memChildCount(val_ty)) |n| for (0..n) |i| {
        const co = sema.memChildOffset(val_ty, i);
        const cs = Type.abiSize(ip, sema.memChildType(val_ty, i));
        if (offset >= co and offset + size <= co + cs and (cs != 0 or size == 0))
            return sema.readMem(block, src, try sema.elemValue(val, i), offset - co, ty);
    };
    const n: usize = @intCast(Type.abiSize(ip, val_ty));
    const buf = try sema.arena.alloc(u8, n);
    const undef = try sema.arena.alloc(bool, n);
    @memset(buf, 0);
    @memset(undef, true);
    if (!try sema.writeMemBytes(val, buf, undef)) return sema.failUnsupported(block, src, "reinterpreting memory at comptime");
    const o: usize = @intCast(offset);
    return (try sema.readMemBytes(ty, buf[o..][0..@intCast(size)], undef[o..][0..@intCast(size)])) orelse
        sema.failUnsupported(block, src, "reinterpreting memory at comptime");
}

/// Stores `val` to the comptime variable memory `ptr` points into.
fn reinterpretStore(sema: *Sema, block: *Block, src: Src, ptr: Index, val: Index) CompileError!void {
    const root = sema.ptrMemRoot(ptr) orelse return sema.failUnsupported(block, src, "reinterpreting memory at comptime");
    if (root.base != .comptime_alloc) return sema.fail(block, src, "unable to store to this memory at comptime", .{});
    const alloc = sema.comptime_allocs.getPtr(root.base.comptime_alloc) orelse
        return sema.fail(block, src, "comptime variable is not accessible here", .{});
    const ip = sema.ip;
    const val_ty = ip.typeOf(val);
    const dest_ty = ip.typeOf(alloc.val);
    try sema.resolveLayout(block, src, val_ty);
    try sema.resolveLayout(block, src, dest_ty);
    const size = Type.abiSize(ip, val_ty);
    if (size == 0) return; // No bytes to write.
    if (root.offset > Type.abiSize(ip, dest_ty) or size > Type.abiSize(ip, dest_ty) - root.offset)
        return sema.fail(block, src, "dereference of '{f}' exceeds bounds of containing decl of type '{f}'", .{ sema.fmtType(ip.typeOf(ptr)), sema.fmtType(dest_ty) });
    const buf = try sema.arena.alloc(u8, @intCast(size));
    const undef = try sema.arena.alloc(bool, @intCast(size));
    @memset(buf, 0);
    @memset(undef, true);
    if (!try sema.writeMemBytes(val, buf, undef)) return sema.failUnsupported(block, src, "reinterpreting memory at comptime");
    alloc.val = (try sema.spliceMem(alloc.val, @intCast(root.offset), buf, undef)) orelse
        return sema.failUnsupported(block, src, "reinterpreting memory at comptime");
}

/// `val` with the bytes from `offset` (which may start before `val`)
/// replaced by `bytes`, or null if the bytes land in a value that has no
/// byte representation at comptime.
fn spliceMem(sema: *Sema, val: Index, offset: i64, bytes: []const u8, undef: []const bool) CompileError!?Index {
    const ip = sema.ip;
    const ty = ip.typeOf(val);
    const size: i64 = @intCast(Type.abiSize(ip, ty));
    const len: i64 = @intCast(bytes.len);
    if (offset >= size or offset + len <= 0) return val;
    if (sema.memChildCount(ty)) |n| {
        const elems = try sema.aggregateElems(val);
        for (elems[0..n], 0..) |*e, i| {
            e.* = (try sema.spliceMem(e.*, offset - @as(i64, @intCast(sema.memChildOffset(ty, i))), bytes, undef)) orelse return null;
        }
        return try sema.intern(.{ .aggregate = .{ .ty = ty, .storage = .{ .elems = elems } } });
    }
    const n: usize = @intCast(size);
    const buf = try sema.arena.alloc(u8, n);
    const buf_undef = try sema.arena.alloc(bool, n);
    @memset(buf, 0);
    @memset(buf_undef, true);
    // A value written over completely needs no bytes of its own.
    if (offset > 0 or offset + len < size) if (!try sema.writeMemBytes(val, buf, buf_undef)) return null;
    const lo: usize = @intCast(@max(offset, 0));
    const hi: usize = @intCast(@min(offset + len, size));
    const from: usize = @intCast(@as(i64, @intCast(lo)) - offset);
    @memcpy(buf[lo..hi], bytes[from..][0 .. hi - lo]);
    @memcpy(buf_undef[lo..hi], undef[from..][0 .. hi - lo]);
    return sema.readMemBytes(ty, buf, buf_undef);
}

/// Writes the memory of comptime value `v` to `buf` (its `abiSize` bytes),
/// clearing `undef` for the bytes it defines; padding stays undefined.
/// False if `v` has no byte representation at comptime (a pointer to
/// memory, an error).
fn writeMemBytes(sema: *Sema, v: Index, buf: []u8, undef: []bool) CompileError!bool {
    const ip = sema.ip;
    const ty = ip.typeOf(v);
    const size: usize = @intCast(Type.abiSize(ip, ty));
    if (sema.isUndef(v)) return true;
    if (sema.memChildCount(ty)) |n| {
        for (0..n) |i| {
            const o: usize = @intCast(sema.memChildOffset(ty, i));
            if (!try sema.writeMemBytes(try sema.elemValue(v, i), buf[o..], undef[o..])) return false;
        }
        return true;
    }
    var used = size;
    switch (Type.class(ip, ty)) {
        .void => return true,
        .bool => buf[0] = @intFromBool(v == .bool_true),
        .int => (try sema.bigValue(v)).toConst().writeTwosComplement(buf[0..size], .little),
        .float => {
            used = Type.floatBits(ip, ty) / 8;
            var all: [16]u8 = undefined;
            std.mem.writeInt(u128, &all, ip.indexToKey(v).float.bits(), .little);
            @memcpy(buf[0..used], all[0..used]);
        },
        .@"enum" => return sema.writeMemBytes(ip.indexToKey(v).enum_tag.int, buf, undef),
        .pointer => {
            const k = ip.indexToKey(v);
            if (k != .ptr or k.ptr.base != .int) return false;
            std.mem.writeInt(u64, buf[0..8], k.ptr.byte_offset, .little);
        },
        .optional => {
            if (!Type.optionalReprIsPtr(ip, Type.childType(ip, ty))) return false;
            const payload = ip.indexToKey(v).opt.val;
            if (payload != .none) return sema.writeMemBytes(payload, buf, undef);
            @memset(buf[0..size], 0);
        },
        .@"struct", .@"union" => {
            if (Type.isPacked(ip, ty)) {
                var bits = try BigInt.init(sema.arena);
                try sema.valueBits(v, &bits, 0);
                bits.toConst().writeTwosComplement(buf[0..size], .little);
            } else if (ip.structInfo(ty).layout == .@"extern" and Type.class(ip, ty) == .@"union") {
                return sema.writeMemBytes(ip.indexToKey(v).un.val, buf, undef);
            } else return false;
        },
        else => return false,
    }
    @memset(undef[0..used], false);
    return true;
}

/// The value of type `ty` whose memory is `buf`, or null if `ty` has no
/// byte representation at comptime. A scalar with an undefined byte is
/// undefined.
fn readMemBytes(sema: *Sema, ty: Index, buf: []const u8, undef: []const bool) CompileError!?Index {
    const ip = sema.ip;
    if (sema.memChildCount(ty)) |n| {
        const elems = try sema.arena.alloc(Index, n);
        for (elems, 0..) |*e, i| {
            const o: usize = @intCast(sema.memChildOffset(ty, i));
            const ct = sema.memChildType(ty, i);
            const cs: usize = @intCast(Type.abiSize(ip, ct));
            e.* = (try sema.readMemBytes(ct, buf[o..][0..cs], undef[o..][0..cs])) orelse return null;
        }
        // The type's sentinel, whatever the bytes say.
        if (ip.indexToKey(ty) == .array_type and ip.indexToKey(ty).array_type.sentinel != .none)
            elems[n - 1] = ip.indexToKey(ty).array_type.sentinel;
        return try sema.intern(.{ .aggregate = .{ .ty = ty, .storage = .{ .elems = elems } } });
    }
    const class = Type.class(ip, ty);
    const used: usize = if (class == .float) Type.floatBits(ip, ty) / 8 else buf.len;
    if (class == .void) return .void_value;
    if (class == .@"union" and ip.structInfo(ty).layout == .@"extern") {
        // The largest field whose bytes are all defined holds the
        // value; the others read it back through its bytes.
        const info = ip.structInfo(ty);
        var best: ?struct { i: u32, size: u64, val: Index } = null;
        for (info.field_types, 0..) |ft, i| {
            const fs = Type.abiSize(ip, ft);
            if (fs > buf.len or (best != null and fs <= best.?.size)) continue;
            if (std.mem.indexOfScalar(bool, undef[0..@intCast(fs)], true) != null) continue;
            const fv = (try sema.readMemBytes(ft, buf[0..@intCast(fs)], undef[0..@intCast(fs)])) orelse continue;
            best = .{ .i = @intCast(i), .size = fs, .val = fv };
        }
        const b = best orelse return try sema.undefValue(ty);
        return try sema.intern(.{ .un = .{ .ty = ty, .tag = try sema.unionFieldTagValue(ty, b.i), .val = b.val } });
    }
    if (std.mem.indexOfScalar(bool, undef[0..used], true) != null) return try sema.undefValue(ty);
    switch (class) {
        .bool => return boolValue(buf[0] & 1 != 0),
        .int => return try sema.intFromMemBytes(ty, buf),
        .float => {
            var all: [16]u8 = @splat(0);
            @memcpy(all[0..used], buf[0..used]);
            return try sema.floatFromBits(ty, std.mem.readInt(u128, &all, .little));
        },
        .@"enum" => return try sema.intern(.{ .enum_tag = .{ .ty = ty, .int = try sema.intFromMemBytes(ip.structInfo(ty).tag_type, buf) } }),
        .pointer => {
            if (Type.isSlice(ip, ty)) return null;
            return try sema.intern(.{ .ptr = .{ .ty = ty, .base = .int, .byte_offset = std.mem.readInt(u64, buf[0..8], .little) } });
        },
        .optional => {
            const child = Type.childType(ip, ty);
            if (!Type.optionalReprIsPtr(ip, child)) return null;
            const addr = std.mem.readInt(u64, buf[0..8], .little);
            const payload: Index = if (addr == 0) .none else try sema.intern(.{ .ptr = .{ .ty = child, .base = .int, .byte_offset = addr } });
            return try sema.intern(.{ .opt = .{ .ty = ty, .val = payload } });
        },
        .@"struct", .@"union" => {
            if (!Type.isPacked(ip, ty)) return null;
            const backing = ip.structInfo(ty).tag_type;
            const bits = try sema.bigValue(try sema.intFromMemBytes(backing, buf));
            return try sema.bitsValue(ty, bits.toConst(), 0);
        },
        else => return null,
    }
}

/// The integer of type `ty` stored little-endian in `buf`.
fn intFromMemBytes(sema: *Sema, ty: Index, buf: []const u8) !Index {
    const info = Type.intInfo(sema.ip, ty);
    if (info.bits == 0) return sema.intValue(ty, 0);
    const limbs = try sema.arena.alloc(std.math.big.Limb, std.math.big.int.calcTwosCompLimbCount(info.bits));
    var m: std.math.big.int.Mutable = .{ .limbs = limbs, .len = 1, .positive = true };
    m.readTwosComplement(buf[0..@intCast((info.bits + 7) / 8)], info.bits, .little, info.signedness);
    return sema.bigToValue(ty, m.toConst());
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
/// The type of a pointer to element `index` (null if runtime-known) of
/// what a pointer of type `p` points to. As upstream, an explicit
/// alignment carries over as far as the element's offset preserves it.
fn elemPtrType(sema: *Sema, p: InternPool.PtrType, elem_ty: Index, index: ?u64) !Index {
    var flag: u6 = 0;
    if (p.flags.alignment != 0) {
        const ip = sema.ip;
        var a: u64 = @as(u64, 1) << @intCast(p.flags.alignment - 1);
        if (Type.isComptimeOnly(ip, elem_ty)) {
            a = @min(a, Type.abiAlignment(ip, elem_ty));
        } else {
            const size = Type.abiSize(ip, elem_ty);
            const step = if (index) |i| i * size else size;
            if (step != 0) a = @min(a, step & (~step +% 1));
        }
        flag = @intCast(std.math.log2_int(u64, a) + 1);
    }
    return sema.ptrType(.{ .child = elem_ty, .flags = .{ .is_const = p.flags.is_const, .is_volatile = p.flags.is_volatile, .alignment = flag } });
}

fn ptrElemPtrVal(sema: *Sema, ptr: Index, i: u64) !Index {
    const ip = sema.ip;
    const key = ip.indexToKey(ptr).ptr;
    const p = Type.ptrInfo(ip, key.ty);
    const elem_ty = if (p.flags.size == .one) Type.childType(ip, p.child) else p.child;
    const elem_ptr_ty = try sema.elemPtrType(p, elem_ty, i);
    if (p.flags.size == .one) {
        return sema.intern(.{ .ptr = .{ .ty = elem_ptr_ty, .base = .{ .elem = .{ .base = ptr, .index = i } } } });
    }
    if (key.base == .elem) {
        const e = key.base.elem;
        return sema.intern(.{ .ptr = .{ .ty = elem_ptr_ty, .base = .{ .elem = .{ .base = e.base, .index = e.index + i } } } });
    }
    // Byte offsets cannot tell zero-size elements (such as types) apart:
    // index the array the pointer starts.
    if (Type.abiSize(ip, elem_ty) == 0 and key.byte_offset == 0 and key.base == .uav) {
        const arr_ty = ip.typeOf(key.base.uav.val);
        if (ip.indexToKey(arr_ty) == .array_type and Type.childType(ip, arr_ty) == elem_ty) {
            const arr_ptr = try sema.intern(.{ .ptr = .{ .ty = try sema.ptrType(.{ .child = arr_ty, .flags = .{ .is_const = p.flags.is_const } }), .base = key.base } });
            return sema.intern(.{ .ptr = .{ .ty = elem_ptr_ty, .base = .{ .elem = .{ .base = arr_ptr, .index = i } } } });
        }
    }
    return sema.intern(.{ .ptr = .{ .ty = elem_ptr_ty, .base = key.base, .byte_offset = key.byte_offset + i * Type.abiSize(ip, elem_ty) } });
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
    // A runtime variable's union gets its tag set and checked at runtime.
    const runtime_var = if (sema.resolveValue(ptr)) |pv| ip.indexToKey(pv) == .ptr and !block.is_comptime and switch (sema.ptrRootBase(ip.indexToKey(pv).ptr)) {
        .nav => |n| !ip.getNav(n).is_const,
        else => false,
    } else false;
    if (sema.resolveValue(ptr)) |pv| if (!runtime_var and try sema.comptimePtrRoot(pv) != .int) {
        if (!initializing and info.layout == .auto) if (try sema.comptimeLoadOrNull(block, src, pv)) |uv| if (ip.indexToKey(uv) == .un) {
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
            try sema.addSafetyCheck(block, ok, .inactive_union_field, active, tag);
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

/// `ptr.*.name`: a struct with one possible value is read without the
/// pointer, so the field is comptime-known even through a runtime pointer.
fn fieldPtrLoad(sema: *Sema, block: *Block, src: Src, ptr: Ref, name: []const u8) CompileError!Ref {
    const ip = sema.ip;
    const ty = sema.typeOf(ptr);
    if (Type.class(ip, ty) == .pointer) {
        const p = Type.ptrInfo(ip, ty);
        if (p.flags.size == .one and (Type.class(ip, p.child) == .@"struct" or Type.class(ip, p.child) == .tuple)) {
            try sema.resolveLayout(block, src, p.child);
            if (!Type.hasRuntimeBits(ip, p.child) and !Type.isComptimeOnly(ip, p.child))
                if (try sema.onePossibleValue(p.child)) |v| return sema.fieldVal(block, src, .fromInterned(v), name);
        }
        if (p.flags.size == .one and Type.class(ip, p.child) == .@"union" and Type.isPacked(ip, p.child)) {
            // Any field of a packed union may be read.
            try sema.resolveLayout(block, src, p.child);
            const field_ty = ip.structInfo(p.child).field_types[try sema.unionFieldIndex(block, src, p.child, name)];
            if (!Type.hasRuntimeBits(ip, field_ty))
                if (try sema.onePossibleValue(field_ty)) |v| return .fromInterned(v);
        }
    }
    return sema.fieldVal(block, src, ptr, name);
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
                .pointer => {
                    // `ptr.len` of a pointer to an array needs only its type.
                    const cp = Type.ptrInfo(ip, p.child);
                    if (cp.flags.size == .one and ip.indexToKey(cp.child) == .array_type and std.mem.eql(u8, name, "len"))
                        return .fromInterned(try sema.intValue(.usize_type, ip.indexToKey(cp.child).array_type.len));
                    return sema.fieldVal(block, src, try sema.analyzeLoad(block, src, lhs), name);
                },
                .type => return sema.fieldVal(block, src, try sema.analyzeLoad(block, src, lhs), name),
                else => {},
            }
            return sema.fail(block, src, "no member named '{s}' in '{f}'", .{ name, sema.fmtType(p.child) });
        },
        .@"struct", .tuple => {
            if (ip.indexToKey(ty) == .tuple_type and ip.indexToKey(ty).tuple_type.names.len == 0 and std.mem.eql(u8, name, "len"))
                return .fromInterned(try sema.intValue(.comptime_int_type, ip.indexToKey(ty).tuple_type.types.len));
            const i = try sema.structFieldIndex(block, src, ty, name);
            if (ip.indexToKey(ty) == .tuple_type) return sema.tupleField(block, lhs, i);
            try sema.resolveLayout(block, src, ty);
            if (ip.structInfo(ty).fieldIsComptime(i)) return .fromInterned(ip.structInfo(ty).field_defaults[i]);
            const field_ty = Type.fieldType(ip, ty, i);
            if (!Type.hasRuntimeBits(ip, field_ty) and !Type.isComptimeOnly(ip, field_ty))
                if (try sema.onePossibleValue(field_ty)) |v| return .fromInterned(v);
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
                if (u.tag != try sema.unionFieldTagValue(ty, i)) {
                    // An extern union's other fields read its bytes.
                    if (ip.structInfo(ty).layout != .@"extern") return sema.fail(block, src, "access of inactive union field '{s}'", .{name});
                    try sema.resolveLayout(block, src, field_ty);
                    return .fromInterned(try sema.readMem(block, src, v, 0, field_ty));
                }
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
        // `anyerror.Name` is `error.Name`, as upstream.
        if (container == .anyerror_type) {
            _ = try ip.errorValue(n);
            const ty = try sema.intern(.{ .error_set_type = &.{n} });
            return .fromInterned(try sema.intern(.{ .err = .{ .ty = ty, .name = n } }));
        }
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
            // An enum tag or error is a value, referenced like a constant.
            const nav = (try sema.lookupInType(container, name)) orelse
                return sema.analyzeRef(block, src, try sema.namespaceLookupVal(block, src, container, name));
            return sema.navRef(block, src, nav);
        }
        return sema.fail(block, src, "expected pointer, found '{f}'", .{sema.fmtType(ptr_ty)});
    }
    const p = Type.ptrInfo(ip, ptr_ty);
    const child = p.child;
    switch (Type.class(ip, child)) {
        .pointer => if (Type.ptrInfo(ip, child).flags.size == .one) {
            const inner = try sema.analyzeLoad(block, src, ptr);
            // `p.ptr` of a pointer to an array is a value, not a place.
            if (std.mem.eql(u8, name, "ptr") and Type.class(ip, Type.ptrInfo(ip, child).child) == .array)
                return sema.analyzeRef(block, src, try sema.fieldVal(block, src, inner, name));
            return sema.fieldPtr(block, src, inner, name);
        } else if (Type.isSlice(ip, child)) {
            const i: u32 = if (std.mem.eql(u8, name, "ptr")) 0 else if (std.mem.eql(u8, name, "len")) 1 else return sema.fail(block, src, "no member named '{s}' in '{f}'", .{ name, sema.fmtType(child) });
            const field_ty = if (i == 0) try sema.elemValueType(child) else .usize_type;
            return sema.fieldPtrAt(block, src, ptr, field_ty, i);
        },
        .type => return sema.fieldPtr(block, src, try sema.analyzeLoad(block, src, ptr), name),
        .@"struct", .tuple => {
            const i = try sema.structFieldIndex(block, src, child, name);
            if (ip.indexToKey(child) == .struct_type) try sema.resolveLayout(block, src, child);
            const cv = Type.comptimeFieldValue(ip, child, i);
            if (cv != .none) return sema.comptimeFieldPtr(p.flags.is_const, cv);
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
        // As upstream, an enum without fields may have tag type `noreturn`.
        if (Type.class(ip, tag_ty) != .int and !(tag_ty == .noreturn_type and n == 0)) return sema.fail(block, src, "tag type must be an integer type", .{});
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
        const name = try sema.typeName(block, @fromBackingInt(@intCast(ext.small)), inst, kind, &captures);
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
    // Struct fields' explicit alignments and `comptime` flags, as values
    // (they are part of the type's identity).
    const align_vals = try sema.arena.alloc(Index, n);
    const comptime_vals = try sema.arena.alloc(Index, n);
    var any_align = false;
    var any_comptime = false;
    for (attrs, types, defaults, align_vals, comptime_vals) |a, ft, *d, *av, *cv| {
        if (sema.isUndef(a) or sema.isUndef(ft)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
        av.* = try sema.structFieldValue(a, "align");
        cv.* = .bool_false;
        if (ip.indexToKey(av.*).opt.val != .none) {
            const bytes = ip.intValue(u64, ip.indexToKey(av.*).opt.val).?;
            if (bytes == 0 or !std.math.isPowerOfTwo(bytes)) return sema.fail(block, src, "alignment value '{d}' is not a power of two", .{bytes});
            any_align = true;
        }
        d.* = .none;
        if (kind != .@"struct") continue;
        cv.* = try sema.structFieldValue(a, "comptime");
        if (cv.* == .bool_true) any_comptime = true;
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
    if (any_align) try captures.appendSlice(sema.arena, align_vals);
    if (any_comptime) try captures.appendSlice(sema.arena, comptime_vals);
    if (any_comptime) {
        if (layout != .auto) return sema.fail(block, src, "{t} struct fields cannot be marked comptime", .{layout});
        for (comptime_vals, defaults) |c, d| if (c == .bool_true and d == .none)
            return sema.fail(block, src, "comptime field without default initialization value", .{});
    }
    const name = try sema.typeName(block, @fromBackingInt(@intCast(ext.small)), inst, kind, captures.items);
    const ty = try sema.zcu.createContainerType(kind, sema.file, inst, captures.items, name.display, name.key, block.namespace, layout);
    const info = ip.structInfo(ty);
    if (info.status == .none) {
        info.field_names = names;
        info.field_types = try ip.arena(Zcu.tid).dupe(Index, types);
        info.field_defaults = defaults;
        info.defaults_status = .resolved;
        if (any_align) {
            const aligns = try ip.arena(Zcu.tid).alloc(u64, n);
            for (aligns, align_vals) |*al, av| al.* = if (ip.indexToKey(av).opt.val == .none) 0 else ip.intValue(u64, ip.indexToKey(av).opt.val).?;
            info.field_aligns = aligns;
        }
        if (any_comptime) {
            const flags = try ip.arena(Zcu.tid).alloc(bool, n);
            for (flags, comptime_vals) |*f, cv| f.* = cv == .bool_true;
            info.field_is_comptime = flags;
        }
        info.status = .have_field_types;
    }
    return .fromInterned(ty);
}

/// `@Fn(param_types, param_attrs, return_type, attrs)`.
fn zirReifyFn(sema: *Sema, block: *Block, ext: Zir.Inst.Extended.InstData) CompileError!Ref {
    const ip = sema.ip;
    const extra = sema.code.extraData(Zir.Inst.ReifyFn, ext.operand).data;
    const src = block.nodeSrc(extra.node);
    const reason = "function type attributes must be comptime-known";
    const params = try sema.constSliceElems(block, src, try sema.coerce(block, .slice_const_type_type, sema.resolveInst(extra.param_types), src), reason);
    const pattrs_ty = try sema.stdLangType(block, src, "Type.Fn.ParamAttributes");
    const pattrs_ptr_ty = try sema.ptrType(.{ .child = try sema.intern(.{ .array_type = .{ .len = params.len, .child = pattrs_ty } }), .flags = .{ .is_const = true } });
    const pattrs_slice_ty = try sema.ptrType(.{ .child = pattrs_ty, .flags = .{ .size = .slice, .is_const = true } });
    const pattrs_arr = try sema.coerce(block, pattrs_ptr_ty, sema.resolveInst(extra.param_attrs), src);
    const pattrs = try sema.constSliceElems(block, src, try sema.coerce(block, pattrs_slice_ty, pattrs_arr, src), reason);
    const ret_ty = try sema.resolveType(block, src, extra.ret_ty);
    const attrs = try sema.resolveConstValue(block, src, try sema.coerce(block, try sema.stdLangType(block, src, "Type.Fn.Attributes"), sema.resolveInst(extra.fn_attrs), src), reason);
    if (sema.isUndef(attrs)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
    var noalias_bits: u32 = 0;
    for (params, pattrs, 0..) |pt, pa, i| {
        if (sema.isUndef(pt) or sema.isUndef(pa)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
        if (try sema.structFieldValue(pa, "noalias") == .bool_true) {
            if (i > 31) return sema.fail(block, src, "this compiler implementation only supports 'noalias' on the first 32 parameters", .{});
            noalias_bits |= @as(u32, 1) << @intCast(i);
        }
    }
    // `std.builtin.CallingConvention` by its tag, as zap's `fn` types know
    // them (`.c` is `.x86_64_sysv`).
    const cc_val = try sema.structFieldValue(attrs, "callconv");
    const cc: InternPool.CallingConvention = switch (ip.indexToKey(cc_val)) {
        .calling_convention => |c| c,
        .un => |u| blk: {
            const tag = sema.enumTagName(u.tag).?;
            break :blk if (std.mem.eql(u8, tag, "auto")) .auto else if (std.mem.eql(u8, tag, "x86_64_sysv")) .c else if (std.mem.eql(u8, tag, "naked")) .naked else if (std.mem.eql(u8, tag, "inline")) .@"inline" else return sema.fail(block, src, "zap does not support calling convention '{s}' yet", .{tag});
        },
        else => unreachable,
    };
    const is_var_args = try sema.structFieldValue(attrs, "varargs") == .bool_true;
    if (is_var_args and cc != .c) return sema.fail(block, src, "variadic function does not support '.{s}' calling convention", .{@tagName(cc)});
    var is_generic = false;
    for (params) |pt| if ((try sema.isComptimeOnlyResolved(block, src, pt))) {
        is_generic = true;
    };
    return .fromInterned(try sema.intern(.{ .func_type = .{
        .param_types = try sema.arena.dupe(Index, params),
        .return_type = ret_ty,
        .cc = cc,
        .is_var_args = is_var_args,
        .noalias_bits = noalias_bits,
        .is_generic = is_generic or (try sema.isComptimeOnlyResolved(block, src, ret_ty)),
    } }));
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
        alignment = @intCast(std.math.log2_int(u64, a) + 1);
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
    if (!Type.hasRuntimeBits(ip, d.elem) and !(try sema.isComptimeOnlyResolved(block, src, d.elem))) return .void_value;
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
    if ((try sema.isComptimeOnlyResolved(block, src, d.elem))) return sema.fail(block, src, "cannot copy comptime-only type '{f}' at runtime", .{sema.fmtType(d.elem)});

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
    if (!Type.hasRuntimeBits(ip, d.elem) and !(try sema.isComptimeOnlyResolved(block, src, d.elem))) return .void_value;
    const len_val = sema.resolveValue(d.len);
    if (len_val != null and ip.intValue(u64, len_val.?).? == 0) return .void_value;

    if (sema.resolveValue(dest)) |dv| if (len_val) |lv| if (sema.resolveValue(elem)) |ev| {
        const raw_dest = (try sema.memRawPtr(block, .fromInterned(dv))).toInterned().?;
        if (!sema.isUndef(raw_dest) and try sema.comptimePtrRoot(raw_dest) == .comptime_alloc) {
            // One store of the whole array, so that bytes of memory viewed
            // as another type are all defined at once.
            const len = ip.intValue(u64, lv).?;
            const arr_ty = try sema.intern(.{ .array_type = .{ .len = len, .child = d.elem } });
            const elems = try sema.arena.alloc(Index, @intCast(len));
            @memset(elems, ev);
            const k = ip.indexToKey(raw_dest).ptr;
            const arr_ptr = try sema.intern(.{ .ptr = .{ .ty = try sema.ptrType(.{ .child = arr_ty }), .base = k.base, .byte_offset = k.byte_offset } });
            try sema.comptimeStore(block, src, arr_ptr, try sema.intern(.{ .aggregate = .{ .ty = arr_ty, .storage = .{ .elems = elems } } }));
            return .void_value;
        }
    };
    try sema.requireRuntime(block, src);
    if ((try sema.isComptimeOnlyResolved(block, src, d.elem))) return sema.fail(block, src, "cannot store comptime-only element '{f}' at runtime", .{sema.fmtType(d.elem)});
    _ = try sema.addBinOp(block, .memset, dest, elem);
    return .void_value;
}

fn elemValueType(sema: *Sema, slice_ty: Index) !Index {
    const p = Type.ptrInfo(sema.ip, slice_ty);
    return sema.ptrType(.{ .child = p.child, .sentinel = p.sentinel, .flags = .{ .size = .many, .is_const = p.flags.is_const, .is_volatile = p.flags.is_volatile, .is_allowzero = p.flags.is_allowzero, .alignment = p.flags.alignment } });
}

/// `@bitSizeOf(ty)`, as upstream's `Type.bitSize`: the bits of its
/// representation, so a packed type's backing integer and an array's
/// elements times their bits; other types' ABI size in bits.
fn bitSize(ip: *InternPool, ty: Index) u64 {
    switch (ip.indexToKey(ty)) {
        .array_type => |a| return a.lenIncludingSentinel() * bitSize(ip, a.child),
        .vector_type => |v| return v.len * bitSize(ip, v.child),
        else => {},
    }
    if (Type.packedBits(ip, ty)) |bits| return bits;
    return if (Type.hasRuntimeBits(ip, ty)) Type.abiSize(ip, ty) * 8 else 0;
}

/// The alignment flag of a pointer to field `i` of `aggregate_ty`
/// through a pointer whose alignment flag is `ptr_align`, as upstream's
/// `Type.fieldPtrAlign`: an underaligned aggregate passes its alignment
/// on, an extern struct's fields are aligned by their offsets, and an
/// explicit field alignment shows.
fn fieldPtrAlignment(sema: *Sema, block: *Block, src: Src, ptr_align: u6, aggregate_ty: Index, i: u32) CompileError!u6 {
    const ip = sema.ip;
    const flag = struct {
        fn f(bytes: u64) u6 {
            return @intCast(std.math.log2_int(u64, bytes) + 1);
        }
    }.f;
    switch (ip.indexToKey(aggregate_ty)) {
        .struct_type, .union_type, .tuple_type => try sema.resolveLayout(block, src, aggregate_ty),
        // Both fields of a slice are 8 bytes, 8-aligned: an under-aligned
        // slice's fields keep its alignment.
        .ptr_type => return if (ptr_align != 0 and ptr_align < flag(8)) ptr_align else 0,
        else => return 0,
    }
    const aggregate_align: u64 = if (ptr_align != 0) @as(u64, 1) << (ptr_align - 1) else Type.abiAlignment(ip, aggregate_ty);
    const field_ty = Type.fieldType(ip, aggregate_ty, i);
    try sema.resolveLayout(block, src, field_ty);
    var explicit: u64 = 0;
    switch (ip.indexToKey(aggregate_ty)) {
        .struct_type => {
            const info = ip.structInfo(aggregate_ty);
            if (info.field_aligns.len != 0) explicit = info.field_aligns[i];
            if (info.layout == .@"extern") {
                const offset = info.field_offsets[i];
                const field_align = if (offset == 0) aggregate_align else @min(aggregate_align, @as(u64, 1) << @intCast(@ctz(offset)));
                if (ptr_align == 0 and explicit == 0 and field_align == Type.abiAlignment(ip, field_ty)) return 0;
                return flag(field_align);
            }
            if (info.fieldIsComptime(i)) return if (explicit != 0) flag(explicit) else 0;
        },
        .union_type => {
            const info = ip.structInfo(aggregate_ty);
            if (info.layout != .auto) {
                if (ptr_align != 0) return ptr_align;
                return if (Type.abiAlignment(ip, field_ty) == aggregate_align) 0 else flag(aggregate_align);
            }
            if (info.field_aligns.len != 0) explicit = info.field_aligns[i];
        },
        else => {},
    }
    const field_align = if (explicit != 0) explicit else Type.abiAlignment(ip, field_ty);
    if (aggregate_align < field_align) return flag(aggregate_align);
    if (explicit == 0) return 0;
    return if (field_align == Type.abiAlignment(ip, field_ty)) 0 else flag(field_align);
}

/// A pointer to a comptime field's value `val`, through a pointer to its
/// aggregate that is const or not. Stores through a mutable one must store
/// the same value (see `analyzeStore`).
/// Whether comptime-known pointer `ptr` points into a mutable comptime
/// field.
fn intoComptimeField(sema: *Sema, ptr: Index) bool {
    var v = ptr;
    while (true) {
        if (sema.comptime_field_ptrs.contains(v)) return true;
        const k = sema.ip.indexToKey(v);
        if (k != .ptr) return false;
        v = switch (k.ptr.base) {
            .field => |f| f.base,
            .elem => |e| e.base,
            else => return false,
        };
    }
}

fn comptimeFieldPtr(sema: *Sema, is_const: bool, val: Index) CompileError!Ref {
    const ptr_ty = try sema.ptrType(.{ .child = sema.ip.typeOf(val), .flags = .{ .is_const = is_const } });
    const ptr = try sema.intern(.{ .ptr = .{ .ty = ptr_ty, .base = .{ .uav = .{ .val = val, .orig_ty = ptr_ty } } } });
    if (!is_const) try sema.comptime_field_ptrs.put(sema.arena, ptr, {});
    return .fromInterned(ptr);
}

fn fieldPtrAt(sema: *Sema, block: *Block, src: Src, ptr: Ref, field_ty: Index, i: u32) CompileError!Ref {
    const ip = sema.ip;
    const p = Type.ptrInfo(ip, sema.typeOf(ptr));
    if (Type.isPackedStruct(ip, p.child)) {
        // A bit pointer into the struct's backing integer, at the same
        // address as the struct.
        try sema.resolveLayout(block, src, p.child);
        const bit_offset = p.packed_offset.bit_offset + Type.packedFieldBitOffset(ip, p.child, i);
        // The struct pointer's alignment, always explicit, as upstream.
        const alignment: u6 = if (p.flags.alignment != 0) p.flags.alignment else @intCast(std.math.log2_int(u64, Type.abiAlignment(ip, p.child)) + 1);
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
        return sema.packedFieldPtr(block, ptr, result_ty, i);
    }
    if (ip.indexToKey(p.child) == .union_type and Type.isPacked(ip, p.child)) {
        // The union's address, alignment, and bit offset, as upstream.
        try sema.resolveLayout(block, src, p.child);
        var info = p;
        info.child = field_ty;
        if (p.flags.alignment == 0) {
            const align_bytes = Type.abiAlignment(ip, p.child);
            info.flags.alignment = if (sema.naturalAlignment(field_ty) == align_bytes) 0 else @intCast(std.math.log2_int(u64, align_bytes) + 1);
        }
        const result_ty = try sema.ptrType(info);
        if (sema.resolveValue(ptr)) |pv| {
            if (!sema.isUndef(pv) and try sema.comptimePtrRoot(pv) != .int) {
                return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = result_ty, .base = .{ .field = .{ .base = pv, .index = i } } } }));
            }
        }
        try sema.requireRuntime(block, src);
        return sema.packedFieldPtr(block, ptr, result_ty, i);
    }
    const result_ty = try sema.ptrType(.{ .child = field_ty, .flags = .{
        .is_const = p.flags.is_const,
        .is_volatile = p.flags.is_volatile,
        .alignment = try sema.fieldPtrAlignment(block, src, p.flags.alignment, p.child, i),
    } });
    if (sema.resolveValue(ptr)) |pv| {
        if (try sema.comptimePtrRoot(pv) != .int) {
            return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = result_ty, .base = .{ .field = .{ .base = pv, .index = i } } } }));
        }
    }
    try sema.requireRuntime(block, src);
    return sema.addStructField(block, .struct_field_ptr, result_ty, ptr, i);
}

/// A runtime bit pointer to field `i` of the packed struct or union `ptr`
/// addresses: the same address, so a `bitcast`. A const local's field
/// pointers remember `i`, for `constAllocPtr`.
fn packedFieldPtr(sema: *Sema, block: *Block, ptr: Ref, result_ty: Index, i: u32) CompileError!Ref {
    const field_ptr = try sema.addTyOp(block, .bitcast, result_ty, ptr);
    if (sema.const_allocs.count() != 0 and sema.constAllocRoot(ptr) != null)
        try sema.packed_field_ptrs.put(sema.arena, field_ptr.toIndex().?, i);
    return field_ptr;
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
        const ptr = sema.ip.indexToKey(v).slice.ptr;
        // The slice may have been coerced (to a stricter alignment, say)
        // without retyping its pointer.
        if (sema.ip.typeOf(ptr) != many_ty) return sema.coercePtrTo(block, .fromInterned(ptr), many_ty);
        return .fromInterned(ptr);
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
            if (v.child == .bool_type and sema.resolveValue(ptr) == null) {
                // A bit pointer into the vector's bytes, at its address.
                try sema.requireRuntime(block, src);
                const result_ty = try sema.ptrType(.{
                    .child = .bool_type,
                    .flags = .{ .is_const = p.flags.is_const, .is_volatile = p.flags.is_volatile, .alignment = if (p.flags.alignment != 0) p.flags.alignment else @intCast(std.math.log2_int(u64, Type.abiAlignment(ip, child)) + 1) },
                    .packed_offset = .{
                        .host_size = @intCast(Type.abiSize(ip, child)),
                        .bit_offset = @intCast(ip.intValue(u64, sema.resolveValue(index).?).?),
                    },
                });
                return sema.addTyOp(block, .bitcast, result_ty, ptr);
            }
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
    try sema.resolveLayout(block, src, cp.child);
    const iv = sema.resolveValue(index);
    const elem_ptr_ty = try sema.elemPtrType(cp, cp.child, if (iv) |v| sema.ip.intValue(u64, v) else null);
    // As upstream, an undefined slice gives an undefined element pointer
    // (`@TypeOf(&undefined_slice[0])`).
    if (sema.resolveValue(slice)) |sv| if (sema.isUndef(sv)) return .fromInterned(try sema.undefValue(elem_ptr_ty));
    if (safety) try sema.boundsCheck(block, src, index, try sema.sliceLen(block, slice), cp.sentinel != .none);
    if (sema.resolveValue(slice)) |sv| {
        if (iv) |v| return .fromInterned(try sema.ptrElemPtrVal(sema.ip.indexToKey(sv).slice.ptr, sema.ip.intValue(u64, v).?));
    }
    try sema.requireRuntime(block, src);
    return sema.addTyPlBin(block, .slice_elem_ptr, elem_ptr_ty, slice, index);
}

fn elemPtrOfArrayPtr(sema: *Sema, block: *Block, src: Src, ptr: Ref, index: Ref) CompileError!Ref {
    const p = Type.ptrInfo(sema.ip, sema.typeOf(ptr));
    const elem_ty = Type.childType(sema.ip, p.child);
    if (p.flags.alignment != 0) try sema.resolveLayout(block, src, elem_ty);
    const result_ty = try sema.elemPtrType(p, elem_ty, if (sema.resolveValue(index)) |v| sema.ip.intValue(u64, v) else null);
    if (sema.resolveValue(ptr)) |pv| if (sema.resolveValue(index)) |iv| {
        if (try sema.comptimePtrRoot(pv) != .int)
            return .fromInterned(try sema.ptrElemPtrVal(pv, sema.ip.intValue(u64, iv).?));
    };
    try sema.requireRuntime(block, src);
    return sema.addTyPlBin(block, .ptr_elem_ptr, result_ty, ptr, index);
}

fn elemPtrOfManyPtr(sema: *Sema, block: *Block, src: Src, ptr: Ref, index: Ref) CompileError!Ref {
    const p = Type.ptrInfo(sema.ip, sema.typeOf(ptr));
    if (p.flags.alignment != 0) try sema.resolveLayout(block, src, p.child);
    const result_ty = try sema.elemPtrType(p, p.child, if (sema.resolveValue(index)) |v| sema.ip.intValue(u64, v) else null);
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
                if (block.is_comptime) if (try sema.indexedOnePossibleValue(ty)) |v| return .fromInterned(v);
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
            if (!Type.hasRuntimeBits(ip, a.child) and !Type.isComptimeOnly(ip, a.child)) if (try sema.onePossibleValue(a.child)) |v| return .fromInterned(v);
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
    var is_allowzero = false;
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
            var obj = try sema.analyzeLoad(block, src, ptr);
            is_const = cp.flags.is_const;
            ptr_align = cp.flags.alignment;
            // The result is allowzero if the sliced pointer is, as upstream.
            is_allowzero = cp.flags.is_allowzero and cp.flags.size != .c;
            switch (cp.flags.size) {
                .one => {
                    // `*T` slices like `*[1]T`, as upstream.
                    if (ip.indexToKey(cp.child) != .array_type) {
                        const arr_ty = try sema.intern(.{ .array_type = .{ .len = 1, .child = cp.child } });
                        obj = try sema.coerce(block, try sema.ptrType(.{ .child = arr_ty, .flags = .{ .is_const = cp.flags.is_const, .is_volatile = cp.flags.is_volatile, .alignment = cp.flags.alignment } }), obj, src);
                    }
                    const a = ip.indexToKey(Type.ptrInfo(ip, sema.typeOf(obj)).child).array_type;
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
    try sema.resolveLayout(block, src, elem_ty);
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
        // A sentinel must match the pointer's own, as upstream.
        if (sentinel_ref != .none) {
            const casted = try sema.coerce(block, elem_ty, sema.resolveInst(sentinel_ref), src);
            const provided = try sema.resolveConstValue(block, src, casted, "slice sentinel must be comptime-known");
            if (provided != ptr_sentinel) return sema.fail(block, src, "sentinel-terminated slicing of many-item pointer must match existing sentinel", .{});
        }
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
        // As upstream, comptime-known bounds only need `end` within the
        // object; the sentinel check then reads the containing memory.
        const both_known = sema.resolveValue(end) != null and sema.resolveValue(len) != null;
        const end_s = if (slice_sentinel == .none or both_known) end else try sema.analyzeArithmetic(block, src, .add, end, .fromInterned(.one_usize));
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
        // A runtime-known start moves by whole elements.
        const off = if (start_val) |v| ip.intValue(u64, v).? * Type.abiSize(ip, elem_ty) else Type.abiSize(ip, elem_ty);
        const bytes: u64 = @as(u64, 1) << @intCast(ptr_align - 1);
        const al = if (off == 0) bytes else @min(bytes, @as(u64, 1) << @intCast(@ctz(off)));
        break :a @intCast(std.math.log2_int(u64, al) + 1);
    };
    const many_ty = sema.typeOf(base);
    const base_val = sema.resolveValue(base);
    const new_ptr: Ref = if (start_val != null and ip.intValue(u64, start_val.?).? == 0)
        base
    else if (base_val != null and sema.isUndef(base_val.?))
        .fromInterned(try sema.undefValue(many_ty))
    else if (base_val != null and start_val != null and try sema.comptimePtrRoot(base_val.?) != .int)
        try sema.coercePtrToMany(try sema.ptrElemPtrVal(base_val.?, ip.intValue(u64, start_val.?).?), many_ty)
    else if (base_val != null and start_val != null)
        // A comptime-known address: fold the offset.
        try sema.analyzePtrArithmetic(block, src, true, base, start)
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
        const result_ty = try sema.ptrType(.{ .child = array_ty, .flags = .{ .is_const = is_const, .is_allowzero = is_allowzero, .alignment = result_align } });
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
    const slice_ty = try sema.ptrType(.{ .child = elem_ty, .sentinel = result_sentinel, .flags = .{ .size = .slice, .is_const = is_const, .is_allowzero = is_allowzero, .alignment = result_align } });
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
    // As upstream: a comptime-known length wins, many-pointers have none,
    // and the other lengths are checked against it at runtime.
    var len: Ref = .none;
    var len_known = false;
    var runtime_lens: std.ArrayList(Ref) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const a = args[i];
        const b = args[i + 1];
        if (a == .none) continue;
        const this_len = if (b == .none) blk: {
            const obj = sema.resolveInst(a);
            const ty = sema.typeOf(obj);
            if (Type.class(sema.ip, ty) == .pointer) switch (Type.ptrInfo(sema.ip, ty).flags.size) {
                .many, .c => continue,
                .one, .slice => {},
            };
            break :blk try sema.coerce(block, .usize_type, try sema.fieldVal(block, src, obj, "len"), src);
        } else blk: {
            const start = try sema.coerce(block, .usize_type, sema.resolveInst(a), src);
            const end = try sema.coerce(block, .usize_type, sema.resolveInst(b), src);
            if (sema.resolveValue(start) == .zero_usize) break :blk end;
            break :blk try sema.analyzeArithmetic(block, src, .sub, end, start);
        };
        if (try sema.resolveDefinedValue(block, src, this_len)) |v| {
            if (len_known) {
                if (v != sema.resolveValue(len).?) return sema.fail(block, src, "non-matching for loop lengths", .{});
            } else {
                if (len != .none) try runtime_lens.append(sema.arena, len);
                len = this_len;
                len_known = true;
            }
            continue;
        }
        if (len == .none) len = this_len else try runtime_lens.append(sema.arena, this_len);
    }
    if (len == .none) return sema.fail(block, src, "unbounded for loop", .{});
    if (block.want_safety) for (runtime_lens.items) |l| {
        const ok = try sema.analyzeCmp(block, src, .eq, len, l);
        try sema.addSafetyCheck(block, ok, .for_len_mismatch, .none, .none);
    };
    return len;
}

// ---------------------------------------------------------------------------
// Optionals, error unions, and switch

fn analyzeIsNonNull(sema: *Sema, block: *Block, src: Src, operand: Ref) CompileError!Ref {
    const ty = sema.typeOf(operand);
    switch (Type.class(sema.ip, ty)) {
        .null => return .fromInterned(.bool_false),
        .optional => {},
        // A C pointer is optional too.
        .pointer => if (Type.ptrInfo(sema.ip, ty).flags.size == .c) {
            return sema.analyzeCmp(block, src, .neq, operand, .fromInterned(.null_value));
        } else return sema.fail(block, src, "expected optional type, found '{f}'", .{sema.fmtType(ty)}),
        else => return sema.fail(block, src, "expected optional type, found '{f}'", .{sema.fmtType(ty)}),
    }
    // `?noreturn` and `?error{}` hold only null, as upstream.
    const child = Type.childType(sema.ip, ty);
    if (child == .noreturn_type or (Type.class(sema.ip, child) == .error_set and try sema.errSetIsEmpty(block, child))) return .fromInterned(.bool_false);
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(.undef_bool);
        return .fromInterned(boolValue(sema.ip.indexToKey(v).opt.val != .none));
    }
    try sema.requireRuntime(block, src);
    return sema.addUnOp(block, .is_non_null, operand);
}

fn optionalPayload(sema: *Sema, block: *Block, src: Src, operand: Ref, safe: bool) CompileError!Ref {
    const ty = sema.typeOf(operand);
    // A C pointer's payload is itself, checked for null.
    if (Type.class(sema.ip, ty) == .pointer and Type.ptrInfo(sema.ip, ty).flags.size == .c) {
        if (safe and block.want_safety and !block.is_comptime) {
            const ok = try sema.analyzeIsNonNull(block, src, operand);
            if (sema.resolveValue(ok)) |v| {
                if (v == .bool_false) return sema.fail(block, src, "unable to unwrap null", .{});
            } else try sema.addSafetyCheck(block, ok, .unwrap_null, .none, .none);
        }
        return operand;
    }
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
    // The operand pointer's attributes, alignment included, as upstream.
    var info = p;
    info.child = child;
    if (info.flags.alignment != 0 and sema.naturalAlignment(child) == @as(u64, 1) << (info.flags.alignment - 1)) info.flags.alignment = 0;
    const result_ty = try sema.ptrType(info);
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
    // A payload with no possible value (`!noreturn`) is never there.
    const payload = sema.ip.indexToKey(ty).error_union_type.payload_type;
    if (Type.class(sema.ip, payload) == .@"enum") try sema.resolveLayout(block, src, payload);
    if (payload == .noreturn_type or (Type.class(sema.ip, payload) == .@"enum" and Type.hasNoPossibleValue(sema.ip, payload)))
        return .fromInterned(.bool_false);
    if (try sema.errSetIsEmpty(block, sema.ip.indexToKey(ty).error_union_type.error_set_type)) return .fromInterned(.bool_true);
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(.undef_bool);
        return .fromInterned(boolValue(sema.ip.indexToKey(v).error_union.val == .payload));
    }
    try sema.requireRuntime(block, src);
    return sema.addUnOp(block, .is_non_err, operand);
}

/// Whether error set `ty` is known to hold no errors, as upstream's
/// resolveErrSetIsEmpty: an inferred set still being inferred is not.
fn errSetIsEmpty(sema: *Sema, block: *Block, ty: Index) CompileError!bool {
    const names = switch (sema.ip.indexToKey(ty)) {
        .error_set_type => |names| names,
        .inferred_error_set_type => |func| blk: {
            if (func == sema.func) return false;
            if (block.inlining) |inl| if (inl.ret_ty != .none and sema.ip.indexToKey(inl.ret_ty) == .error_union_type and
                sema.ip.indexToKey(inl.ret_ty).error_union_type.error_set_type == ty) return false;
            try sema.declareDependency(.{ .func_ies = func });
            break :blk (sema.zcu.ensureFuncIes(func) catch |err| switch (err) {
                error.DependencyLoop => return false,
                else => |e| return e,
            }) orelse return false;
        },
        else => return false,
    };
    return names.len == 0;
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

/// `try eu`, or with `is_ptr`, `(try eu).field` and the like: the operand
/// is a pointer to the error union, and the result points to its payload.
fn zirTry(sema: *Sema, parent: *Block, inst: Zir.Inst.Index, is_ptr: bool) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Try, data.payload_index);
    const body = sema.code.bodySlice(extra.end, extra.data.body_len);
    const src = parent.nodeSrc(data.src_node);
    const operand = sema.resolveInst(extra.data.operand);
    const eu = if (is_ptr) try sema.analyzeLoad(parent, src, operand) else operand;
    const ty = sema.typeOf(eu);
    if (Type.class(sema.ip, ty) != .error_union) return sema.fail(parent, src, "expected error union type, found '{f}'", .{sema.fmtType(ty)});
    const is_non_err = try sema.analyzeIsNonErr(parent, src, eu);
    if (sema.resolveValue(is_non_err)) |v| {
        if (v == .bool_true) return if (is_ptr) sema.errUnionPayloadPtr(parent, src, operand, false) else sema.errUnionPayload(parent, src, operand);
        try sema.analyzeBodyInner(parent, body);
        return .unreachable_value;
    }
    const block_inst = try sema.reserveInst();
    var ok_block = parent.condChild();
    defer ok_block.instructions.deinit(sema.gpa);
    _ = try sema.addInst(&ok_block, .{ .tag = .br, .data = .{ .br = .{ .block_inst = block_inst, .operand = .void_value } } });
    var err_block = parent.condChild();
    defer err_block.instructions.deinit(sema.gpa);
    try sema.analyzeBodyInner(&err_block, body);
    var inner = parent.child();
    defer inner.instructions.deinit(sema.gpa);
    try sema.addCondBr(&inner, is_non_err, ok_block.instructions.items, err_block.instructions.items);
    try sema.addBlock(parent, block_inst, .void_type, inner.instructions.items);
    if (is_ptr) {
        // As upstream's runtime `try_ptr`, the result keeps the operand
        // pointer's attributes, alignment included.
        var info = Type.ptrInfo(sema.ip, sema.typeOf(operand));
        info.child = sema.ip.indexToKey(ty).error_union_type.payload_type;
        if (info.flags.alignment != 0 and sema.naturalAlignment(info.child) == @as(u64, 1) << (info.flags.alignment - 1)) info.flags.alignment = 0;
        return sema.addTyOp(parent, .unwrap_errunion_payload_ptr, try sema.ptrType(info), operand);
    }
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
    /// The else prong of a switch on a known error set: the errors no
    /// other prong handles, which are the capture's type.
    else_errors: ?[]const InternPool.String = null,
    /// The prong lists `_` besides its items.
    has_under: bool = false,
    /// A pointer to the operand, for captures by reference, or `none`.
    operand_ptr: Ref = .none,
};

/// With `is_ref`, the operand is a pointer, and prongs may capture by
/// reference (`|*payload|`).
fn zirSwitchBlock(sema: *Sema, parent: *Block, inst: Zir.Inst.Index, is_ref: bool) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const src = parent.nodeSrc(data.src_node);
    const sb = sema.code.getSwitchBlock(inst);
    const operand = sema.resolveInst(sb.main_operand);
    if (!is_ref) return sema.analyzeSwitch(parent, src, inst, operand, .none);
    return sema.analyzeSwitch(parent, src, inst, try sema.analyzeLoad(parent, src, operand), operand);
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
    // A pointer to the error union, for a payload capture by reference.
    var eu_ptr: Ref = .none;
    if (non_err.operand_is_ref) {
        eu_ptr = eu;
        eu = try sema.analyzeLoad(parent, src, eu);
    }
    if (Type.class(sema.ip, sema.typeOf(eu)) != .error_union) return sema.fail(parent, src, "expected error union type, found '{f}'", .{sema.fmtType(sema.typeOf(eu))});
    const cond = try sema.analyzeIsNonErr(parent, src, eu);
    if (parent.is_comptime) {
        const v = sema.resolveValue(cond) orelse return sema.fail(parent, src, "unable to evaluate comptime expression", .{});
        if (v == .bool_false) {
            // Prong bodies refer to the error (the switch operand) as `inst`.
            const code = try sema.errUnionCode(parent, src, eu);
            try sema.inst_map.put(gpa, inst, code);
            return sema.analyzeSwitch(parent, src, inst, code, .none);
        }
        if (non_err.capture != .none) try sema.inst_map.put(gpa, inst, try sema.errUnionCapture(parent, src, eu, eu_ptr, non_err.capture));
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
    var then_block = outer.condChild();
    defer then_block.instructions.deinit(gpa);
    if (cond_val != .bool_false) {
        if (non_err.capture != .none) try sema.inst_map.put(gpa, inst, try sema.errUnionCapture(&then_block, src, eu, eu_ptr, non_err.capture));
        if (try sema.analyzeInlineBody(&then_block, non_err.body, inst)) |result| try sema.addBr(&then_block, &label, result);
    }
    var else_block = outer.condChild();
    defer else_block.instructions.deinit(gpa);
    if (cond_val != .bool_true) {
        const code = try sema.errUnionCode(&else_block, src, eu);
        // Prong bodies refer to the error (the switch operand) as `inst`.
        try sema.inst_map.put(gpa, inst, code);
        const result = try sema.analyzeSwitch(&else_block, src, inst, code, .none);
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

fn errUnionCapture(sema: *Sema, block: *Block, src: Src, eu: Ref, eu_ptr: Ref, capture: Zir.Inst.SwitchBlock.ProngInfo.Capture) CompileError!Ref {
    if (capture == .by_ref) return sema.errUnionPayloadPtr(block, src, eu_ptr, false);
    return sema.errUnionPayload(block, src, eu);
}

/// `operand_ptr` points to `operand` in a switch whose prongs may capture
/// by reference, else is `none`.
fn analyzeSwitch(sema: *Sema, parent: *Block, src: Src, inst: Zir.Inst.Index, operand: Ref, operand_ptr: Ref) CompileError!Ref {
    const ip = sema.ip;
    const gpa = sema.gpa;
    const sb = sema.code.getSwitchBlock(inst);
    // A tagged union switches on its tag; prongs capture the payload. A
    // packed struct or union switches on its bits, as upstream.
    const packed_ty: Index = if (Type.isPacked(ip, sema.typeOf(operand))) sema.typeOf(operand) else .none;
    const cond = try sema.switchCond(parent, src, operand);
    const operand_ty = sema.typeOf(cond);
    switch (Type.class(ip, operand_ty)) {
        .int, .comptime_int, .bool, .error_set, .enum_literal, .type, .@"enum" => {},
        .pointer => if (Type.isSlice(ip, operand_ty)) return sema.fail(parent, src, "switch on type '{f}'", .{sema.fmtType(operand_ty)}),
        else => return sema.fail(parent, src, "zap does not support switching on '{f}' yet", .{sema.fmtType(operand_ty)}),
    }
    if (Type.class(ip, operand_ty) == .@"enum") try sema.resolveLayout(parent, src, operand_ty);
    const capture_inst: Zir.Inst.Index = sb.payload_capture_placeholder.unwrap() orelse inst;
    const tag_inst: Zir.Inst.Index = sb.tag_capture_placeholder.unwrap() orelse inst;
    const is_union = Type.class(ip, sema.typeOf(operand)) == .@"union" and packed_ty == .none;

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
            if (packed_ty != .none) {
                // An item of the packed type, compared by its bits.
                const item = try sema.switchItem(&item_block, src, inst, info, packed_ty, &extra_index);
                try items.append(sema.arena, (try sema.reinterpretBits(&item_block, src, operand_ty, .fromInterned(item))).toInterned().?);
                continue;
            }
            // An error outside the switched set may have a prong of
            // `comptime unreachable`, as upstream; it never matches.
            if (case.prong_info.is_comptime_unreach and info.unwrap() == .error_value and Type.class(ip, operand_ty) == .error_set) {
                if (try sema.errorSetNames(parent, src, operand_ty)) |names| {
                    const name = try sema.getString(sema.zirString(info.unwrap().error_value));
                    if (std.mem.indexOfScalar(InternPool.String, names, name) == null) continue;
                }
            }
            try items.append(sema.arena, try sema.switchItem(&item_block, src, inst, info, operand_ty, &extra_index));
        }
        // A prong left with no items is never taken.
        if (items.items.len == 0 and case.range_infos.len == 0 and case.item_infos.len != 0 and
            (under_index == null or under_index.? != cases.items.len)) continue;
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
            .operand_ptr = operand_ptr,
            .has_under = under_index == cases.items.len,
        });
    }
    var else_case: ?SwitchCase = if (sb.else_case) |e| .{
        .items = &.{},
        .ranges = &.{},
        .body = e.body,
        .capture = e.capture,
        .is_inline = e.is_inline,
        .tag_inst = if (e.has_tag_capture) tag_inst.toOptional() else .none,
        .operand_ptr = operand_ptr,
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
        // A union switches over its fields, whatever its tag type.
        if (info.nonexhaustive and !sb.has_under and !is_union) return sema.fail(parent, src, "switch on non-exhaustive enum must include 'else' or '_' prong", .{});
        for (info.field_defaults) |fv| {
            const tv = try sema.intern(.{ .enum_tag = .{ .ty = operand_ty, .int = fv } });
            for (cases.items) |c| {
                if (std.mem.indexOfScalar(Index, c.items, tv) != null) break;
            } else return sema.fail(parent, src, "switch must handle all possibilities", .{});
        }
    } else if (else_case == null and Type.class(ip, operand_ty) == .pointer) {
        return sema.fail(parent, src, "else prong required when switching on type '{f}'", .{sema.fmtType(operand_ty)});
    } else if (else_case == null and Type.class(ip, operand_ty) != .error_set) {
        if (!try sema.switchCoversAllInts(cases.items, operand_ty)) return sema.fail(parent, src, "switch must handle all possibilities", .{});
    }

    // The else capture of an error set switch has the errors the other
    // prongs leave.
    if (else_case) |*e| if (e.capture != .none and !e.is_inline and Type.class(ip, operand_ty) == .error_set) {
        if (try sema.errorSetNames(parent, src, operand_ty)) |names| {
            var rest: std.ArrayList(InternPool.String) = .empty;
            for (names) |n| {
                const handled = outer: for (cases.items) |c| {
                    for (c.items) |item| {
                        if (ip.indexToKey(item).err.name == n) break :outer true;
                    }
                } else false;
                if (!handled) try rest.append(sema.arena, n);
            }
            e.else_errors = rest.items;
        }
    };
    // An else prong whose union fields all have no possible value lists
    // them, so analyzeProng does not analyze its body.
    if (else_case) |*e| if (is_union and !e.is_inline) {
        var rest: std.ArrayList(Index) = .empty;
        const info = ip.structInfo(sema.typeOf(operand));
        for (info.field_types, 0..) |ft, i| {
            const tv = try sema.unionFieldTagValue(sema.typeOf(operand), @intCast(i));
            for (cases.items) |c| {
                if (std.mem.indexOfScalar(Index, c.items, tv) != null) break;
            } else {
                if (!Type.hasNoPossibleValue(ip, ft)) break;
                try rest.append(sema.arena, tv);
            }
        } else if (rest.items.len != 0) {
            e.items = rest.items;
        }
    };
    // A `_` prong is the else prong of a non-exhaustive enum.
    const under_prong: ?SwitchCase = if (under_index) |k| cases.items[k] else null;
    if (under_prong != null) if (else_case) |e| if (!e.is_inline) {
        // With both, `else` handles the named tags no other prong lists.
        var rest: std.ArrayList(Index) = .empty;
        for (ip.structInfo(operand_ty).field_defaults) |fv| {
            const tv = try sema.intern(.{ .enum_tag = .{ .ty = operand_ty, .int = fv } });
            for (cases.items) |c| {
                if (std.mem.indexOfScalar(Index, c.items, tv) != null) break;
            } else try rest.append(sema.arena, tv);
        }
        var c = e;
        c.items = rest.items;
        try cases.append(sema.arena, c);
        else_case = null;
    };
    if (else_case) |e| if (e.is_inline) {
        // `inline else` becomes one inline prong per value no other prong
        // handles.
        const all = try sema.switchAllValues(parent, src, operand_ty, under_prong != null);
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
    if (sema.resolveValue(cond) == null) {
        // Each inline prong after the first counts as a backward branch,
        // as upstream.
        var first = true;
        for (cases.items) |c| if (c.is_inline) {
            if (!first) try sema.emitBackwardBranch(parent, src);
            first = false;
        };
    }
    const under_case = under_prong orelse else_case;
    if (sb.has_continue) return sema.switchLoop(parent, src, inst, operand, operand_ptr, cases.items, under_case, capture_inst);

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

/// Every value of `ty`, for `inline else`; with `named_only`, every named
/// tag of a non-exhaustive enum whose switch has a `_` prong.
fn switchAllValues(sema: *Sema, block: *Block, src: Src, ty: Index, named_only: bool) CompileError![]const Index {
    const ip = sema.ip;
    var vals: std.ArrayList(Index) = .empty;
    switch (Type.class(ip, ty)) {
        .bool => try vals.appendSlice(sema.arena, &.{ .bool_false, .bool_true }),
        .@"enum" => {
            const info = ip.structInfo(ty);
            if (info.nonexhaustive and !named_only) return sema.fail(block, src, "cannot enumerate values of type '{f}' for 'inline else'", .{sema.fmtType(ty)});
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
        // A declaration of the operand type, else an enum literal.
        .enum_literal => |s| try sema.analyzeDeclLiteral(block, src, sema.zirString(s), operand_ty, false),
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
    if (info.bits > 64) return false;
    const ip = sema.ip;
    const Interval = struct {
        lo: i128,
        hi: i128,
        fn lessThan(_: void, x: @This(), y: @This()) bool {
            return x.lo < y.lo;
        }
    };
    var intervals: std.ArrayList(Interval) = .empty;
    for (cases) |c| {
        for (c.items) |item| {
            const v = ip.intValue(i128, item) orelse return false;
            try intervals.append(sema.arena, .{ .lo = v, .hi = v });
        }
        for (c.ranges) |r| try intervals.append(sema.arena, .{ .lo = ip.intValue(i128, r[0]).?, .hi = ip.intValue(i128, r[1]).? });
    }
    std.mem.sort(Interval, intervals.items, {}, Interval.lessThan);
    // Sweep: every value from min to max must be in some interval.
    var next: i128 = ip.intValue(i128, try sema.minIntValue(ty)).?;
    const max = ip.intValue(i128, try sema.maxIntValue(ty)).?;
    for (intervals.items) |iv| {
        if (iv.lo > next) return false;
        next = @max(next, iv.hi + 1);
    }
    return next > max;
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
    // The error switch of `eu catch |err| switch (err) {...}` breaks to the
    // block of the whole expression, so its prongs are peers of the payload.
    const enclosing = labelOf(parent, inst);
    const block_inst = if (enclosing == null) try sema.reserveInst() else undefined;
    var label: Block.Label = .{ .zir_block = inst, .merges = .{ .block_inst = block_inst } };
    defer {
        label.merges.results.deinit(gpa);
        label.merges.brs.deinit(gpa);
    }
    var outer = parent.child();
    if (enclosing == null) outer.label = &label;
    defer outer.instructions.deinit(gpa);
    try sema.emitSwitchProngs(&outer, src, inst, cond, operand, cases, else_case, capture_inst);
    if (enclosing != null) {
        try parent.instructions.appendSlice(gpa, outer.instructions.items);
        return .unreachable_value;
    }
    return sema.resolveBlock(parent, src, &outer, &label.merges);
}

/// A labeled switch with `continue`. At comptime, prongs run until one
/// does not continue. At runtime, the operand lives in a local and the
/// prongs dispatch in a loop that `continue :label x` repeats.
fn switchLoop(sema: *Sema, parent: *Block, src: Src, inst: Zir.Inst.Index, operand: Ref, operand_ptr: Ref, cases_in: []const SwitchCase, else_case_in: ?SwitchCase, capture_inst: Zir.Inst.Index) CompileError!Ref {
    const gpa = sema.gpa;
    const operand_ty = sema.typeOf(operand);
    // With captures by reference the loop carries a pointer to the
    // operand, and `continue :sw x` passes a pointer to `x`.
    const is_ref = operand_ptr != .none;
    const slot_ty = if (is_ref) sema.typeOf(operand_ptr) else operand_ty;
    // `continue :sw x` coerces `x` to the switch instruction, which
    // stands for the operand type (captures use placeholders).
    try sema.inst_map.put(gpa, inst, .fromInterned(operand_ty));
    defer _ = sema.inst_map.remove(inst);
    // The prongs of one iteration, whose by-reference captures point to
    // that iteration's operand.
    const cases = try sema.arena.dupe(SwitchCase, cases_in);
    var else_case = else_case_in;
    const setPtr = struct {
        fn f(cs: []SwitchCase, e: *?SwitchCase, p: Ref) void {
            for (cs) |*c| c.operand_ptr = p;
            if (e.*) |*x| x.operand_ptr = p;
        }
    }.f;
    if (parent.is_comptime) {
        var cur_slot = if (is_ref) operand_ptr else operand;
        while (true) {
            const cur = if (is_ref) try sema.analyzeLoad(parent, src, cur_slot) else cur_slot;
            if (is_ref) setPtr(cases, &else_case, cur_slot);
            const cond = try sema.switchCond(parent, src, cur);
            const v = sema.resolveValue(cond) orelse return sema.fail(parent, src, "unable to evaluate comptime expression", .{});
            const chosen = for (cases) |c| {
                if (try sema.switchCaseMatches(c, v)) break c;
            } else else_case orelse return sema.fail(parent, src, "switch must handle all possibilities", .{});
            try sema.bindSwitchCaptures(parent, src, chosen, cur, capture_inst);
            const result = sema.analyzeInlineBody(parent, chosen.body, inst) catch |err| switch (err) {
                error.ComptimeBreak => {
                    const brk_inst = sema.comptime_break_inst;
                    const brk = sema.code.instructions.items(.data)[@backingInt(brk_inst)].@"break";
                    const extra = sema.code.extraData(Zir.Inst.Break, brk.payload_index).data;
                    if (sema.code.instructions.items(.tag)[@backingInt(brk_inst)] != .switch_continue or extra.block_inst != inst) return err;
                    cur_slot = try sema.coerce(parent, slot_ty, sema.resolveInst(brk.operand), src);
                    try sema.emitBackwardBranch(parent, src);
                    continue;
                },
                else => return err,
            };
            return result orelse .unreachable_value;
        }
    }
    try sema.requireRuntime(parent, src);
    if ((try sema.isComptimeOnlyResolved(parent, src, operand_ty))) return sema.failUnsupported(parent, src, "runtime labeled switches on comptime-only types");
    try sema.resolveLayout(parent, src, operand_ty);
    const block_inst = try sema.reserveInst();
    const loop_inst = try sema.reserveInst();
    var label: Block.Label = .{ .zir_block = inst, .merges = .{ .block_inst = block_inst } };
    defer {
        label.merges.results.deinit(gpa);
        label.merges.brs.deinit(gpa);
    }
    var outer = parent.child();
    outer.label = &label;
    defer outer.instructions.deinit(gpa);
    const ptr = try sema.addInst(&outer, .{ .tag = .alloc, .data = .{ .ty = try sema.ptrType(.{ .child = slot_ty }) } });
    _ = try sema.addBinOp(&outer, .store, ptr, if (is_ref) operand_ptr else operand);
    label.switch_continue = .{ .loop_inst = loop_inst, .operand_ptr = ptr, .operand_ty = slot_ty };
    var loop_block = outer.condChild();
    defer loop_block.instructions.deinit(gpa);
    const slot = try sema.analyzeLoad(&loop_block, src, ptr);
    if (is_ref) setPtr(cases, &else_case, slot);
    const cur = if (is_ref) try sema.analyzeLoad(&loop_block, src, slot) else slot;
    const cond = try sema.switchCond(&loop_block, src, cur);
    try sema.emitSwitchProngs(&loop_block, src, inst, cond, cur, cases, else_case, capture_inst);
    const loop_payload = try sema.addExtra(Ir.Block{ .body_len = @intCast(loop_block.instructions.items.len) });
    try sema.appendBody(loop_block.instructions.items);
    sema.ir_insts.set(@backingInt(loop_inst), .{ .tag = .loop, .data = .{ .ty_pl = .{ .ty = .noreturn_type, .payload = loop_payload } } });
    try outer.instructions.append(gpa, loop_inst);
    return sema.resolveBlock(parent, src, &outer, &label.merges);
}

/// What a switch on `operand` compares: a tagged union's tag, a packed
/// struct's or union's bits, or the operand.
fn switchCond(sema: *Sema, block: *Block, src: Src, operand: Ref) CompileError!Ref {
    const ip = sema.ip;
    const ty = sema.typeOf(operand);
    if (Type.isPacked(ip, ty)) {
        try sema.resolveLayout(block, src, ty);
        return sema.reinterpretBits(block, src, ip.structInfo(ty).tag_type, operand);
    }
    if (Type.class(ip, ty) != .@"union") return operand;
    try sema.resolveLayout(block, src, ty);
    if (ip.indexToKey(ip.structInfo(ty).tag_type) != .enum_type) return sema.fail(block, src, "switch on union with no attached enum", .{});
    return sema.unionTag(block, src, operand);
}

/// The prongs of a runtime switch on `cond`, added to `outer`, whose
/// label the prongs break to.
fn emitSwitchProngs(sema: *Sema, outer: *Block, src: Src, inst: Zir.Inst.Index, cond: Ref, operand: Ref, cases: []const SwitchCase, else_case: ?SwitchCase, capture_inst: Zir.Inst.Index) CompileError!void {
    const gpa = sema.gpa;
    if (cases.len == 1 and else_case == null and sema.resolveValue(cond) != null) {
        // A comptime-known operand selected this prong.
        try sema.analyzeProng(outer, cases[0], operand, capture_inst, inst);
    } else {
        var any_ranges = false;
        for (cases) |c| any_ranges = any_ranges or c.ranges.len != 0;
        if (any_ranges) {
            try sema.switchAsCondBrs(outer, src, cases, else_case, cond, operand, capture_inst, inst);
        } else {
            // switch_br: cases with items, then the else body.
            var bodies: std.ArrayList(u32) = .empty;
            defer bodies.deinit(gpa);
            for (cases) |c| {
                var prong = outer.condChild();
                defer prong.instructions.deinit(gpa);
                try sema.analyzeProng(&prong, c, operand, capture_inst, inst);
                try bodies.append(gpa, @intCast(c.items.len));
                try bodies.append(gpa, @intCast(prong.instructions.items.len));
                for (c.items) |item| try bodies.append(gpa, @backingInt(item));
                try bodies.appendSlice(gpa, @ptrCast(prong.instructions.items));
            }
            var else_block = outer.condChild();
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
            _ = try sema.addInst(outer, .{ .tag = .switch_br, .data = .{ .pl_op = .{ .operand = cond, .payload = payload } } });
        }
    }
}

/// The label of the runtime block of ZIR block `inst` enclosing `block`.
fn labelOf(block: *Block, inst: Zir.Inst.Index) ?*Block.Label {
    var it: ?*Block = block;
    while (it) |cur| : (it = cur.parent) {
        const label = cur.label orelse continue;
        if (label.zir_block == inst) return label;
    }
    return null;
}

/// What a prong captures: the operand, or a union's payload.
fn switchCapture(sema: *Sema, block: *Block, src: Src, c: SwitchCase, operand: Ref) CompileError!Ref {
    const ip = sema.ip;
    const ty = sema.typeOf(operand);
    if (c.capture == .by_ref) {
        // A pointer to the union's payload, else to the operand.
        if (c.operand_ptr == .none) return sema.failUnsupported(block, src, "this switch capture by reference");
        if (Type.class(ip, ty) != .@"union" or c.items.len == 0) return c.operand_ptr;
        const info = ip.structInfo(ty);
        const i = info.fieldIndex(ip, sema.enumTagName(c.items[0]).?).?;
        const ptr = try sema.fieldPtrAt(block, src, c.operand_ptr, info.field_types[i], i);
        if (c.items.len == 1) return ptr;
        // Several fields: the least aligned of their pointers, as upstream.
        var ptr_info = Type.ptrInfo(ip, sema.typeOf(ptr));
        const op_align = Type.ptrInfo(ip, sema.typeOf(c.operand_ptr)).flags.alignment;
        const natural = Type.abiAlignment(ip, ptr_info.child);
        var min: u64 = std.math.maxInt(u64);
        var explicit = false;
        for (c.items) |item| {
            const fi = info.fieldIndex(ip, sema.enumTagName(item).?).?;
            const a = try sema.fieldPtrAlignment(block, src, op_align, ty, fi);
            explicit = explicit or a != 0;
            min = @min(min, if (a == 0) Type.abiAlignment(ip, info.field_types[fi]) else @as(u64, 1) << (a - 1));
        }
        // An explicit alignment stays explicit, even when natural.
        ptr_info.flags.alignment = if (min == natural and !explicit) 0 else @intCast(std.math.log2_int(u64, min) + 1);
        return sema.coercePtrTo(block, ptr, try sema.ptrType(ptr_info));
    }
    if (Type.class(ip, ty) == .error_set and (c.items.len != 0 or c.else_errors != null)) {
        // The capture's type is the set of the prong's errors.
        const names = if (c.else_errors) |ee| try sema.arena.dupe(InternPool.String, ee) else try sema.arena.alloc(InternPool.String, c.items.len);
        if (c.else_errors == null) for (names, c.items) |*n, item| {
            n.* = ip.indexToKey(item).err.name;
        };
        const set = try sema.errorSetType(names);
        // A prong with one item knows its error, as upstream.
        if (c.else_errors == null and names.len == 1) return .fromInterned(try sema.intern(.{ .err = .{ .ty = set, .name = names[0] } }));
        if (sema.resolveValue(operand)) |v| {
            if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(set));
            return .fromInterned(try sema.intern(.{ .err = .{ .ty = set, .name = ip.indexToKey(v).err.name } }));
        }
        return sema.addTyOp(block, .bitcast, set, operand);
    }
    if (Type.isPacked(ip, ty)) return operand;
    // A prong with one item knows its value, as upstream.
    if (Type.class(ip, ty) != .@"union") return if (c.is_inline or (c.items.len == 1 and c.ranges.len == 0 and !c.has_under)) .fromInterned(c.items[0]) else operand;
    if (c.items.len == 0) return operand;
    const info = ip.structInfo(ty);
    const name = sema.enumTagName(c.items[0]).?;
    const i = info.fieldIndex(ip, name).?;
    if (sema.resolveValue(operand)) |v| return .fromInterned(try sema.fieldValue(v, i));
    const differing = for (c.items[1..]) |item| {
        if (info.field_types[info.fieldIndex(ip, sema.enumTagName(item).?).?] != info.field_types[i]) break true;
    } else false;
    if (differing) return sema.peerUnionCapture(block, src, c.items, operand);
    if (!Type.hasRuntimeBits(ip, info.field_types[i]) and !Type.isComptimeOnly(ip, info.field_types[i]))
        if (try sema.onePossibleValue(info.field_types[i])) |v| return .fromInterned(v);
    try sema.requireRuntime(block, src);
    return sema.addStructField(block, .struct_field_val, info.field_types[i], operand, i);
}

/// The payload capture of a prong over union fields of different types:
/// the active field's value as their peer type, read by the tag.
fn peerUnionCapture(sema: *Sema, block: *Block, src: Src, items: []const Index, operand: Ref) CompileError!Ref {
    const ip = sema.ip;
    const ty = sema.typeOf(operand);
    const info = ip.structInfo(ty);
    const fields = try sema.arena.alloc(u32, items.len);
    const samples = try sema.arena.alloc(Ref, items.len);
    for (items, fields, samples) |item, *f, *r| {
        f.* = info.fieldIndex(ip, sema.enumTagName(item).?).?;
        r.* = .fromInterned(try sema.undefValue(info.field_types[f.*]));
    }
    const peer = try sema.resolvePeerTypes(block, src, samples);
    try sema.requireRuntime(block, src);
    const tag = try sema.unionTag(block, src, operand);
    const block_inst = try sema.reserveInst();
    var chain: []const Ir.Inst.Index = &.{};
    {
        var last = block.condChild();
        defer last.instructions.deinit(sema.gpa);
        _ = try sema.addInst(&last, .{ .tag = .unreach, .data = .{ .no_op = {} } });
        chain = try sema.arena.dupe(Ir.Inst.Index, last.instructions.items);
    }
    var k = items.len;
    while (k > 0) {
        k -= 1;
        var b = block.condChild();
        defer b.instructions.deinit(sema.gpa);
        const eq = try sema.addBinOp(&b, .cmp_eq, tag, .fromInterned(items[k]));
        var then = b.condChild();
        defer then.instructions.deinit(sema.gpa);
        const val = try sema.addStructField(&then, .struct_field_val, info.field_types[fields[k]], operand, fields[k]);
        const coerced = try sema.coerce(&then, peer, val, src);
        _ = try sema.addInst(&then, .{ .tag = .br, .data = .{ .br = .{ .block_inst = block_inst, .operand = coerced } } });
        try sema.addCondBr(&b, eq, then.instructions.items, chain);
        chain = try sema.arena.dupe(Ir.Inst.Index, b.instructions.items);
    }
    try sema.addBlock(block, block_inst, peer, chain);
    return block_inst.toRef();
}

fn bindSwitchCaptures(sema: *Sema, block: *Block, src: Src, c: SwitchCase, operand: Ref, capture_inst: Zir.Inst.Index) CompileError!void {
    // Without a capture, `capture_inst` may be the switch itself, which a
    // labeled switch maps to its operand type.
    if (c.capture != .none) try sema.inst_map.put(sema.gpa, capture_inst, try sema.switchCapture(block, src, c, operand));
    if (c.tag_inst.unwrap()) |t| {
        // A prong with one item knows its tag, as upstream.
        const known = c.is_inline or (c.items.len == 1 and c.ranges.len == 0);
        try sema.inst_map.put(sema.gpa, t, if (known) .fromInterned(c.items[0]) else try sema.unionTag(block, src, operand));
    }
}

fn analyzeProng(sema: *Sema, block: *Block, c: SwitchCase, operand: Ref, capture_inst: Zir.Inst.Index, switch_inst: Zir.Inst.Index) CompileError!void {
    const ip = sema.ip;
    const op_ty = sema.typeOf(operand);
    if (Type.class(ip, op_ty) == .@"union" and !Type.isPacked(ip, op_ty) and c.items.len != 0) {
        // A prong whose union fields all have no possible value cannot be
        // taken, so upstream does not analyze its body.
        const info = ip.structInfo(op_ty);
        for (c.items) |item| {
            if (!Type.hasNoPossibleValue(ip, info.field_types[info.fieldIndex(ip, sema.enumTagName(item).?).?])) break;
        } else {
            _ = try sema.addInst(block, .{ .tag = .unreach, .data = .{ .no_op = {} } });
            return;
        }
    }
    try sema.bindSwitchCaptures(block, block.nodeSrc(.zero), c, operand, capture_inst);
    if (c.capture == .by_val and sema.typeOf(sema.inst_map.get(capture_inst).?) == .noreturn_type) {
        // A union payload of type noreturn: the prong cannot be reached.
        _ = try sema.addInst(block, .{ .tag = .unreach, .data = .{ .no_op = {} } });
        return;
    }
    if (try sema.analyzeInlineBody(block, c.body, switch_inst)) |result| {
        // A prong ended with a comptime break to the switch.
        try sema.addBr(block, labelOf(block, switch_inst).?, result);
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
    var then_block = block.condChild();
    defer then_block.instructions.deinit(sema.gpa);
    try sema.analyzeProng(&then_block, c, operand, capture_inst, switch_inst);
    var else_block = block.condChild();
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
    if (ty == .clobbers_type) return .fromInterned(try sema.undefValue(.clobbers_type));
    switch (ip.indexToKey(ty)) {
        .struct_type => {
            try sema.resolveStructFields(block, src, ty);
            if (ip.structInfo(ty).field_types.len != 0) try sema.resolveStructDefaults(block, src, ty);
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
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const src = block.nodeSrc(data.src_node);
    const extra = sema.code.extraData(Zir.Inst.StructInit, data.payload_index);
    const n = extra.data.fields_len;
    var i = extra.end;
    var ty: Index = .none;
    const items = try sema.arena.alloc(StructInitItem, n);
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
    // As upstream, a result type `?T` or `E!T` initializes a `T`.
    const base = sema.unwrapOptEu(ty);
    if (base != ty) return sema.coerce(block, ty, try sema.structInitTyped(block, src, base, items), src);
    return sema.structInitTyped(block, src, ty, items);
}

const StructInitItem = struct { name: []const u8, init: Ref };

fn structInitTyped(sema: *Sema, block: *Block, src: Src, ty: Index, items: []const StructInitItem) CompileError!Ref {
    const ip = sema.ip;
    if (ip.indexToKey(ty) == .union_type) {
        if (items.len != 1) return sema.fail(block, src, "union initialization expects exactly one field", .{});
        const fi = try sema.unionFieldIndex(block, src, ty, items[0].name);
        const init = try sema.coerce(block, ip.structInfo(ty).field_types[fi], items[0].init, src);
        return sema.unionInit(block, src, ty, fi, init);
    }
    if (ip.indexToKey(ty) == .tuple_type) {
        // `Tuple{ .@"0" = a, ... }`: fields by their names; a comptime
        // field keeps its value.
        const t = ip.indexToKey(ty).tuple_type;
        const elems = try sema.arena.alloc(Ref, t.types.len);
        @memset(elems, .none);
        for (items) |item| {
            const idx = try sema.structFieldIndex(block, src, ty, item.name);
            elems[idx] = try sema.coerce(block, t.types[idx], item.init, src);
        }
        for (elems, t.values, 0..) |*e, v, k| {
            if (v != .none) {
                if (e.* != .none and sema.resolveValue(e.*) != v)
                    return sema.fail(block, src, "value stored in comptime field does not match the default value of the field", .{});
                e.* = .fromInterned(v);
            } else if (e.* == .none) return sema.fail(block, src, "missing tuple field with index {d}", .{k});
        }
        return sema.aggregate(block, src, ty, elems);
    }
    if (ip.indexToKey(ty) != .struct_type) return sema.fail(block, src, "type '{f}' does not support struct initialization syntax", .{sema.fmtType(ty)});
    try sema.resolveStructFields(block, src, ty);
    const info = ip.structInfo(ty);
    const elems = try sema.arena.alloc(Ref, info.field_types.len);
    @memset(elems, .none);
    for (items) |item| {
        const idx = try sema.structFieldIndex(block, src, ty, item.name);
        elems[idx] = try sema.coerce(block, info.field_types[idx], item.init, src);
        if (info.fieldIsComptime(idx)) {
            try sema.resolveLayout(block, src, ty);
            if (sema.resolveValue(elems[idx]) != info.field_defaults[idx])
                return sema.fail(block, src, "value stored in comptime field does not match the default value of the field", .{});
        }
    }
    // Omitted fields take their defaults: a `comptime` field's from the
    // layout, the others' from `struct_defaults`.
    for (elems, 0..) |e, k| if (e == .none) {
        if (info.fieldIsComptime(k)) try sema.resolveLayout(block, src, ty) else try sema.resolveStructDefaults(block, src, ty);
    };
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
    for (seen, 0..) |s, k| if (!s) {
        if (info.fieldIsComptime(k)) try sema.resolveLayout(block, src, ty) else try sema.resolveStructDefaults(block, src, ty);
    };
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
            // As for anonymous struct literals: a field referring to
            // comptime-mutable memory is not a comptime field.
            if (v.* != .none and sema.ip.indexToKey(v.*) == .ptr and try sema.comptimePtrRoot(v.*) == .comptime_alloc) v.* = .none;
        }
        const ty = try sema.intern(.{ .tuple_type = .{ .types = types, .values = values } });
        return sema.aggregate(block, src, ty, elems);
    }
    // As upstream, a result type `?T` or `E!T` initializes a `T`.
    if (sema.unwrapOptEu(result_ty) != result_ty) {
        return sema.coerce(block, result_ty, try sema.arrayInitTyped(block, src, sema.unwrapOptEu(result_ty), args[1..]), src);
    }
    return sema.arrayInitTyped(block, src, result_ty, args[1..]);
}

fn arrayInitTyped(sema: *Sema, block: *Block, src: Src, result_ty: Index, inits: []const Zir.Inst.Ref) CompileError!Ref {
    const ip = sema.ip;
    var ty = result_ty;
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
    const dest_ty = try sema.castDestType(block, src, extra.lhs, true);
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
    const dest_ty = try sema.castDestType(block, src, extra.lhs, true);
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
    const dest_ty = try sema.castDestType(block, src, extra.lhs, true);
    var operand = sema.resolveInst(extra.rhs);
    if (ip.indexToKey(sema.typeOf(operand)) == .array_type and ip.indexToKey(sema.typeOf(operand)).array_type.sentinel != .none) {
        // A source array's sentinel is part of its bits, as upstream:
        // cast the `[N:s]T` as the `[N+1]T` ending in `s`.
        const a = ip.indexToKey(sema.typeOf(operand)).array_type;
        const full = try sema.intern(.{ .array_type = .{ .len = a.len + 1, .child = a.child } });
        if (sema.resolveValue(operand)) |v| {
            if (!sema.isUndef(v)) {
                const elems = try sema.arena.alloc(Index, a.len + 1);
                for (elems[0..a.len], 0..) |*e, i| e.* = try sema.elemValue(v, i);
                elems[a.len] = a.sentinel;
                operand = .fromInterned(try sema.intern(.{ .aggregate = .{ .ty = full, .storage = .{ .elems = elems } } }));
            } else operand = .fromInterned(try sema.undefValue(full));
        } else {
            const ref = try sema.analyzeRef(block, src, operand);
            operand = try sema.analyzeLoad(block, src, try sema.coercePtrTo(block, ref, try sema.ptrType(.{ .child = full, .flags = .{ .is_const = true } })));
        }
    }
    return sema.bitCast(block, src, dest_ty, operand);
}

fn bitCast(sema: *Sema, block: *Block, src: Src, dest_ty: Index, operand: Ref) CompileError!Ref {
    const ip = sema.ip;
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
    // Vectors of elements with padding bits (`@Vector(4, f80)`,
    // `@Vector(3, u7)`): each element is stored in its own bytes, and
    // the vector's bits are its elements' bits in order, so equal
    // element widths reinterpret element by element.
    if (sema.vectorLen(dest_ty)) |len| if (sema.vectorLen(src_ty) == len) {
        const d_elem = Type.childType(ip, dest_ty);
        const s_elem = Type.childType(ip, src_ty);
        if (sema.bitCastBits(d_elem)) |d_bits| if (sema.bitCastBits(s_elem) == d_bits and sema.vectorLen(d_elem) == null and sema.vectorLen(s_elem) == null)
            return (try sema.vectorCast(block, src, dest_ty, operand, bitCast)).?;
    };
    // Arrays and vectors of elements with padding bits: their logical bits
    // differ from their memory, so the bits are packed into an integer and
    // unpacked again.
    if (sema.logicalBits(dest_ty)) |d_bits| if (sema.logicalBits(src_ty)) |s_bits| {
        if (d_bits != s_bits) return sema.fail(block, src, "@bitCast size mismatch: destination type '{f}' has {d} bits but source type '{f}' has {d} bits", .{ sema.fmtType(dest_ty), d_bits, sema.fmtType(src_ty), s_bits });
        if (sema.resolveValue(operand)) |v| {
            if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(dest_ty));
            var bits = try BigInt.init(sema.arena);
            try sema.valueBits(v, &bits, 0);
            return .fromInterned(try sema.bitsValue(dest_ty, bits.toConst(), 0));
        }
        try sema.requireRuntime(block, src);
        if (d_bits > std.math.maxInt(u16)) return sema.failUnsupported(block, src, "@bitCast of more than 65535 bits with padded elements");
        const host_ty = try sema.intType(.unsigned, @intCast(d_bits));
        const host = try sema.packLogicalBits(block, src, operand, .fromInterned(try sema.intValue(host_ty, 0)), 0);
        return sema.unpackLogicalBits(block, src, host, dest_ty, 0);
    };
    return sema.failUnsupported(block, src, "@bitCast between these types");
}

/// `operand` as a value of `dest_ty` with the same bits, for a packed type
/// and its backing integer (whose layouts are resolved).
fn reinterpretBits(sema: *Sema, block: *Block, src: Src, dest_ty: Index, operand: Ref) CompileError!Ref {
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(dest_ty));
        var bits = try BigInt.init(sema.arena);
        try sema.valueBits(v, &bits, 0);
        return .fromInterned(try sema.bitsValue(dest_ty, bits.toConst(), 0));
    }
    try sema.requireRuntime(block, src);
    return sema.addTyOp(block, .bitcast, dest_ty, operand);
}

/// The bits of `ty` if `@bitCast` reinterprets it as plain bits: an
/// integer, a float, or an array of them without padding bits.
fn bitCastBits(sema: *Sema, ty: Index) ?u64 {
    const ip = sema.ip;
    // Covers `usize` and the other named integer types too.
    if (Type.isInt(ip, ty)) return Type.intInfo(ip, ty).bits;
    return switch (ip.indexToKey(ty)) {
        // A sentinel is part of the array's bits.
        .array_type => |a| blk: {
            const eb = sema.bitCastBits(a.child) orelse break :blk null;
            if (eb != Type.abiSize(ip, a.child) * 8) break :blk null;
            break :blk eb * (a.len + @intFromBool(a.sentinel != .none));
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
        // An enum by its tag, as upstream.
        .enum_type => Type.intInfo(ip, ip.structInfo(ty).tag_type).bits,
        else => if (Type.class(ip, ty) == .float) Type.floatBits(ip, ty) else if (ty == .bool_type) 1 else null,
    };
}

/// The bits `@bitCast` sees in `ty`, as upstream: arrays and vectors are
/// their elements' bits in order, without the padding each element has in
/// memory. Null for types `@bitCast` does not accept.
fn logicalBits(sema: *Sema, ty: Index) ?u64 {
    const ip = sema.ip;
    if (Type.isInt(ip, ty)) return Type.intInfo(ip, ty).bits;
    return switch (ip.indexToKey(ty)) {
        .array_type => |a| (sema.logicalBits(a.child) orelse return null) * (a.len + @intFromBool(a.sentinel != .none)),
        .vector_type => |v| (sema.logicalBits(v.child) orelse return null) * v.len,
        else => sema.bitCastBits(ty),
    };
}

/// Runtime value `val` (see `logicalBits`) ORed into unsigned integer
/// `host` at bit `offset`, one scalar at a time.
fn packLogicalBits(sema: *Sema, block: *Block, src: Src, val: Ref, host: Ref, offset: u64) CompileError!Ref {
    const ip = sema.ip;
    const ty = sema.typeOf(val);
    const len: u64 = switch (ip.indexToKey(ty)) {
        .array_type => |a| a.len + @intFromBool(a.sentinel != .none),
        .vector_type => |v| v.len,
        else => return sema.packedInsert(block, host, @intCast(offset), val),
    };
    const eb = sema.logicalBits(Type.childType(ip, ty)).?;
    var h = host;
    for (0..len) |i| {
        const elem = try sema.elemVal(block, src, val, .fromInterned(try sema.intValue(.usize_type, i)), false);
        h = try sema.packLogicalBits(block, src, elem, h, offset + i * eb);
    }
    return h;
}

/// The value of type `ty` (see `logicalBits`) whose bits are those of
/// runtime unsigned integer `host` from bit `offset`.
fn unpackLogicalBits(sema: *Sema, block: *Block, src: Src, host: Ref, ty: Index, offset: u64) CompileError!Ref {
    const ip = sema.ip;
    const len: u64 = switch (ip.indexToKey(ty)) {
        .array_type => |a| a.len,
        .vector_type => |v| v.len,
        else => return sema.packedExtract(block, host, @intCast(offset), ty),
    };
    const child = Type.childType(ip, ty);
    const eb = sema.logicalBits(child).?;
    const elems = try sema.arena.alloc(Ref, @intCast(len));
    for (elems, 0..) |*e, i| e.* = try sema.unpackLogicalBits(block, src, host, child, offset + i * eb);
    return sema.aggregate(block, src, ty, elems);
}

/// ORs the bits of value `v` (see `logicalBits`) into `out` at bit `offset`.
fn valueBits(sema: *Sema, v: Index, out: *BigInt, offset: u64) Allocator.Error!void {
    const ip = sema.ip;
    const ty = ip.typeOf(v);
    var part = try BigInt.init(sema.arena);
    switch (Type.class(ip, ty)) {
        .array => {
            const child = Type.childType(ip, ty);
            const eb = sema.logicalBits(child).?;
            const a = ip.indexToKey(ty).array_type;
            // `elemValue` at `len` is the sentinel.
            for (0..a.len + @intFromBool(a.sentinel != .none)) |i| try sema.valueBits(try sema.elemValue(v, i), out, offset + i * eb);
            return;
        },
        .vector => {
            const child = Type.childType(ip, ty);
            const eb = sema.logicalBits(child).?;
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
            const eb = sema.logicalBits(child).?;
            const a = ip.indexToKey(ty).array_type;
            // The sentinel's bits are ignored; the aggregate stores it last.
            const elems = try sema.arena.alloc(Index, @intCast(a.lenIncludingSentinel()));
            for (elems[0..@intCast(a.len)], 0..) |*e, i| e.* = try sema.bitsValue(child, bits, offset + i * eb);
            if (a.sentinel != .none) elems[@intCast(a.len)] = a.sentinel;
            return sema.intern(.{ .aggregate = .{ .ty = ty, .storage = .{ .elems = elems } } });
        },
        .vector => {
            const child = Type.childType(ip, ty);
            const eb = sema.logicalBits(child).?;
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
    const dest_ty = try sema.castDestType(block, src, dest_ref, false);
    var operand = sema.resolveInst(operand_ref);
    const ip = sema.ip;
    const optPtr = struct {
        fn f(p_ip: *InternPool, ty: Index) bool {
            return Type.class(p_ip, ty) == .optional and Type.class(p_ip, Type.childType(p_ip, ty)) == .pointer and
                Type.ptrInfo(p_ip, Type.childType(p_ip, ty)).flags.size != .slice;
        }
    }.f;
    // An optional slice into a plain pointer gives the slice's pointer,
    // whose address is zero for null.
    const op_ty = sema.typeOf(operand);
    if (Type.class(ip, op_ty) == .optional and Type.class(ip, Type.childType(ip, op_ty)) == .pointer and
        Type.ptrInfo(ip, Type.childType(ip, op_ty)).flags.size == .slice and
        Type.class(ip, dest_ty) == .pointer and Type.ptrInfo(ip, dest_ty).flags.size != .slice)
    {
        const az = Type.ptrInfo(ip, dest_ty).flags.is_allowzero;
        if (sema.resolveValue(operand)) |v| {
            if (!sema.isUndef(v) and ip.indexToKey(v).opt.val == .none) {
                if (!az) return sema.fail(block, src, "null pointer casted to type '{f}'", .{sema.fmtType(dest_ty)});
                return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = dest_ty, .base = .int, .byte_offset = 0 } }));
            }
        } else if (block.want_safety and !az) {
            try sema.requireRuntime(block, src);
            try sema.addSafetyCheck(block, try sema.addUnOp(block, .is_non_null, operand), .cast_to_null, .none, .none);
        }
        return sema.ptrCastInner(block, src, flags, dest_ty, try sema.optionalPayload(block, src, operand, false));
    }
    // Optional pointers: null stays null in an optional result; otherwise
    // the pointer must not be null.
    if (optPtr(ip, sema.typeOf(operand))) {
        if (optPtr(ip, dest_ty)) {
            const child = try sema.ptrCastInner(block, src, flags, Type.childType(ip, dest_ty), try sema.addTyOpOrFold(block, Type.childType(ip, sema.typeOf(operand)), operand));
            if (sema.resolveValue(operand)) |v| if (!sema.isUndef(v) and ip.indexToKey(v).opt.val == .none) return .fromInterned(try sema.intern(.{ .opt = .{ .ty = dest_ty, .val = .none } }));
            if (sema.resolveValue(child)) |cv| return .fromInterned(try sema.intern(.{ .opt = .{ .ty = dest_ty, .val = cv } }));
            return sema.addTyOp(block, .bitcast, dest_ty, operand);
        }
        if (sema.resolveValue(operand)) |v| {
            if (!sema.isUndef(v) and ip.indexToKey(v).opt.val == .none) return sema.fail(block, src, "null pointer casted to type '{f}'", .{sema.fmtType(dest_ty)});
        } else if (block.want_safety and Type.class(ip, dest_ty) == .pointer and !Type.ptrInfo(ip, dest_ty).flags.is_allowzero) {
            try sema.requireRuntime(block, src);
            const ok = try sema.addUnOp(block, .is_non_null, operand);
            try sema.addSafetyCheck(block, ok, .cast_to_null, .none, .none);
        }
        operand = try sema.optionalPayload(block, src, operand, false);
    } else if (Type.class(ip, dest_ty) == .optional and Type.class(ip, Type.childType(ip, dest_ty)) == .pointer and Type.class(ip, sema.typeOf(operand)) == .pointer) {
        // Into an optional pointer or slice: cast to the payload and wrap.
        const child = try sema.ptrCastInner(block, src, flags, Type.childType(ip, dest_ty), operand);
        return sema.coerce(block, dest_ty, child, src);
    }
    return sema.ptrCastInner(block, src, flags, dest_ty, operand);
}

/// `ty_op` to `ty` (a bitcast between optional and plain pointers), or the
/// payload of a comptime-known optional pointer.
fn addTyOpOrFold(sema: *Sema, block: *Block, ty: Index, operand: Ref) CompileError!Ref {
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(ty));
        const payload = sema.ip.indexToKey(v).opt.val;
        return .fromInterned(if (payload == .none) try sema.intern(.{ .ptr = .{ .ty = ty, .base = .int, .byte_offset = 0 } }) else payload);
    }
    try sema.requireRuntime(block, block.nodeSrc(.zero));
    return sema.addTyOp(block, .optional_payload, ty, operand);
}

fn ptrCastInner(sema: *Sema, block: *Block, src: Src, flags: Zir.Inst.FullPtrCastFlags, dest_ty: Index, operand: Ref) CompileError!Ref {
    const ip = sema.ip;
    const src_ty = sema.typeOf(operand);
    if (Type.class(sema.ip, dest_ty) != .pointer or Type.class(sema.ip, src_ty) != .pointer)
        return sema.failUnsupported(block, src, "pointer casts involving non-pointer types");
    const d = Type.ptrInfo(sema.ip, dest_ty);
    const s = Type.ptrInfo(sema.ip, src_ty);
    if (s.flags.is_const and !d.flags.is_const and !flags.const_cast) return sema.fail(block, src, "@ptrCast discards const qualifier", .{});
    if (s.flags.size == .slice and d.flags.size != .slice) {
        // The slice's pointer.
        const raw = try sema.slicePtr(block, operand);
        return sema.coercePtrTo(block, raw, dest_ty);
    }
    if (d.flags.size == .slice and s.flags.size != .slice) {
        // A single-item pointer provides a length: that of the bytes it
        // points to.
        if (s.flags.size != .one) return sema.fail(block, src, "cannot infer length of slice from '{f}'", .{sema.fmtType(src_ty)});
        try sema.resolveLayout(block, src, d.child);
        try sema.resolveLayout(block, src, s.child);
        const src_elem: Index, const src_len: u64 = switch (ip.indexToKey(s.child)) {
            .array_type => |a| .{ a.child, a.len }, // not the sentinel
            else => .{ s.child, 1 },
        };
        const many = try sema.coercePtrTo(block, operand, try sema.elemValueType(dest_ty));
        // The same elements, of any size, keep their count.
        if (src_elem == d.child) return sema.makeSlice(block, dest_ty, many, .fromInterned(try sema.intValue(.usize_type, src_len)));
        const bytes = src_len * Type.abiSize(ip, src_elem);
        const dsize = Type.abiSize(ip, d.child);
        if (dsize == 0 or bytes % dsize != 0) return sema.fail(block, src, "type '{f}' does not divide exactly into destination elements", .{sema.fmtType(s.child)});
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
    // `@alignCast` to a stricter alignment is checked at runtime.
    if (flags.align_cast and block.want_safety and !block.is_comptime and sema.resolveValue(operand) == null) {
        try sema.resolveLayout(block, src, d.child);
        const da = sema.ptrAlignment(d) orelse 1;
        const sa = sema.ptrAlignment(s) orelse 1;
        if (da > sa and da > 1) {
            const addr = try sema.addUnOp(block, .int_from_ptr, operand);
            const low = try sema.addBinOp(block, .bit_and, addr, .fromInterned(try sema.intValue(.usize_type, da - 1)));
            const ok = try sema.addBinOp(block, .cmp_eq, low, .fromInterned(.zero_usize));
            try sema.addSafetyCheck(block, ok, .incorrect_alignment, .none, .none);
        }
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
    // Container-level assembly: upstream's self-hosted backends drop it.
    if (sema.func == .none and small.outputs_len == 0 and small.inputs_len == 0) return .void_value;
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
        if ((try sema.isComptimeOnlyResolved(block, src, sema.typeOf(operand)))) return sema.fail(block, src, "inline assembly input of comptime-only type '{f}'", .{sema.fmtType(sema.typeOf(operand))});
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
    var is_var_args = false;
    var noalias_bits: u32 = 0;
    if (tag == .func_fancy) {
        const extra = sema.code.extraData(Zir.Inst.FuncFancy, data.payload_index);
        body_len = extra.data.body_len;
        is_var_args = extra.data.bits.is_var_args;
        if (extra.data.bits.has_any_noalias) {
            var k = extra.end;
            if (extra.data.bits.has_cc_body) k += 1 + sema.code.extra[k] else if (extra.data.bits.has_cc_ref) k += 1;
            if (extra.data.bits.has_ret_ty_body) k += 1 + sema.code.extra[k] else if (extra.data.bits.has_ret_ty_ref) k += 1;
            noalias_bits = sema.code.extra[k];
        }
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
    if (is_var_args) {
        if (cc != .c) return sema.fail(block, src, "variadic function does not support '.{s}' calling convention", .{@tagName(cc)});
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

    // As upstream, a function declaration's parameter and return types
    // have their layouts resolved, which records them as dependencies of
    // the declaration: whether a parameter is comptime-only decides how
    // the function is called. A function type does not, so that it may
    // name a type whose layout is being resolved.
    if (body_len != 0) {
        for (params) |p| try sema.resolveLayout(block, src, p.ty);
        try sema.resolveLayout(block, src, ret_ty);
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
        .is_var_args = is_var_args,
        .comptime_bits = comptime_bits,
        .noalias_bits = noalias_bits,
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
        // A pointer to a type: a call of one of its declarations.
        if (container == .type_type) {
            const callee = try sema.fieldVal(block, src, try sema.analyzeLoad(block, src, self_ptr), name);
            return sema.analyzeCall(block, src, callee, .none, args, modifier);
        }
    }
    if (ip.indexToKey(container) == .struct_type or ip.indexToKey(container) == .union_type) {
        // A field holding a function (pointer) is called.
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
    const by_ptr = first_ty != .generic_poison_type and switch (Type.class(ip, first_ty)) {
        .pointer => true,
        .optional => Type.class(ip, Type.childType(ip, first_ty)) == .pointer,
        else => false,
    };
    const self: Ref = if (by_ptr) self_ptr else try sema.analyzeLoad(block, src, self_ptr);
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
    // An extern function is called through a pointer loaded at runtime.
    var extern_func: Index = .none;
    const fn_ty_index: Index = switch (Type.class(ip, callee_ty)) {
        .@"fn" => blk: {
            const v = try sema.resolveConstValue(block, src, callee, "function value must be comptime-known");
            if (ip.indexToKey(v) == .extern_func) {
                extern_func = v;
                break :blk callee_ty;
            }
            if (ip.indexToKey(v) != .func) return sema.fail(block, src, "type '{f}' not a function", .{sema.fmtType(callee_ty)});
            func = v;
            break :blk callee_ty;
        },
        .pointer => blk: {
            const p = Type.ptrInfo(ip, callee_ty);
            if (p.flags.size != .one or Type.class(ip, p.child) != .@"fn") return sema.fail(block, src, "type '{f}' not a function", .{sema.fmtType(callee_ty)});
            if (sema.resolveValue(callee)) |v| if (ip.indexToKey(v) == .ptr) {
                const k = ip.indexToKey(v).ptr;
                if (k.base == .uav and k.byte_offset == 0 and ip.indexToKey(k.base.uav.val) == .extern_func) extern_func = k.base.uav.val;
                if (k.base == .nav and k.byte_offset == 0) {
                    try sema.ensureNavVal(block, src, k.base.nav);
                    const nv = ip.getNav(k.base.nav).val;
                    // A pointer cast to another function type calls
                    // indirectly.
                    if (ip.indexToKey(nv) == .func and ip.typeOf(nv) == p.child) func = nv;
                    // At comptime, it calls the function and coerces the
                    // result, as upstream.
                    if (ip.indexToKey(nv) == .func and func == .none and (block.is_comptime or modifier == .compile_time)) {
                        const r = try sema.analyzeCall(block, src, .fromInterned(nv), first_arg, call_args_in, modifier);
                        return sema.coerce(block, ip.indexToKey(p.child).func_type.return_type, r, src);
                    }
                    if (ip.indexToKey(nv) == .extern_func) extern_func = nv;
                }
            };
            break :blk p.child;
        },
        else => return sema.fail(block, src, "type '{f}' not a function", .{sema.fmtType(callee_ty)}),
    };
    const fn_ty = ip.indexToKey(fn_ty_index).func_type;
    const total_args = call_args_in.len() + @intFromBool(first_arg != .none);
    if (fn_ty.is_var_args) {
        if (total_args < fn_ty.param_types.len) return sema.fail(block, src, "expected at least {d} argument(s), found {d}", .{ fn_ty.param_types.len, total_args });
        if (block.is_comptime or modifier == .compile_time) return sema.fail(block, src, "unable to call variadic function at comptime", .{});
    } else if (total_args != fn_ty.param_types.len) {
        return sema.fail(block, src, "expected {d} argument(s), found {d}", .{ fn_ty.param_types.len, total_args });
    }
    switch (modifier) {
        .auto, .compile_time, .always_inline, .never_inline, .never_tail, .no_suspend => {},
        // As in upstream's x86_64 backend, only comptime calls can be tail calls.
        .always_tail => if (!block.is_comptime) return sema.failUnsupported(block, src, "runtime tail calls"),
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
                // A variadic argument has no result type.
                if (arg_i >= fn_ty.param_types.len) {
                    try sema.inst_map.put(sema.gpa, zir_args.call_inst, .fromInterned(.generic_poison_type));
                    args[arg_i] = try sema.coerceVarArg(block, src, try sema.resolveInlineBody(block, body, zir_args.call_inst));
                    arg_i += 1;
                    continue;
                }
                // A generic parameter's type can depend on the arguments before it;
                // it is the argument's result type, as upstream.
                const param_ty = if (fn_ty.param_types[arg_i] == .generic_poison_type and func != .none)
                    try sema.genericParamType(block, src, func, args[0..arg_i])
                else
                    fn_ty.param_types[arg_i];
                try sema.inst_map.put(sema.gpa, zir_args.call_inst, .fromInterned(param_ty));
                // As upstream, an argument to a comptime parameter is
                // evaluated at comptime.
                var ct_block = block.child();
                defer ct_block.instructions.deinit(sema.gpa);
                if (arg_i < 32 and (fn_ty.comptime_bits >> @intCast(arg_i)) & 1 != 0) ct_block.is_comptime = true;
                const arg = try sema.resolveInlineBody(if (ct_block.is_comptime) &ct_block else block, body, zir_args.call_inst);
                args[arg_i] = if (param_ty == .generic_poison_type) arg else try sema.coerce(block, param_ty, arg, src);
                arg_i += 1;
            }
        },
        .resolved => |resolved| for (resolved) |arg| {
            if (arg_i >= fn_ty.param_types.len) {
                args[arg_i] = try sema.coerceVarArg(block, src, arg);
                arg_i += 1;
                continue;
            }
            const param_ty = if (fn_ty.param_types[arg_i] == .generic_poison_type and func != .none)
                try sema.genericParamType(block, src, func, args[0..arg_i])
            else
                fn_ty.param_types[arg_i];
            args[arg_i] = if (param_ty == .generic_poison_type) arg else try sema.coerce(block, param_ty, arg, src);
            arg_i += 1;
        },
    }

    // As upstream, the call's statement position (AstGen's `dbg_stmt` just
    // before the call) applies again after its arguments' code, so that a
    // return address maps to the call.
    if (call_args_in == .zir and !block.is_comptime) {
        const dbg: Zir.Inst.Index = @fromBackingInt(@backingInt(call_args_in.zir.call_inst) - 1);
        if (sema.code.instructions.items(.tag)[@backingInt(dbg)] == .dbg_stmt) {
            const d = sema.code.instructions.items(.data)[@backingInt(dbg)].dbg_stmt;
            try sema.addDbgStmt(block, d.line, d.column);
        }
    }

    const ret_ty = fn_ty.return_type;
    // An inline call with a comptime-only return type still runs its body
    // at runtime, as upstream; its result must be comptime-known.
    const is_inline = fn_ty.cc == .@"inline" or modifier == .always_inline;
    const comptime_call = block.is_comptime or modifier == .compile_time or
        (ret_ty != .generic_poison_type and try sema.isComptimeOnlyResolved(block, src, ret_ty) and !is_inline);
    if (func == .none) {
        if (comptime_call) return sema.fail(block, src, "unable to resolve comptime value: function pointer is not comptime-known", .{});
        const callee_ptr = if (extern_func == .none) callee else blk: {
            const ptr_ty = try sema.ptrType(.{ .child = ip.typeOf(extern_func), .flags = .{ .is_const = true } });
            const name = ip.indexToKey(extern_func).extern_func.name;
            break :blk try sema.addInst(block, .{ .tag = .extern_ptr, .data = .{ .ty_pl = .{ .ty = ptr_ty, .payload = @backingInt(name) } } });
        };
        if (fn_ty.is_generic) return sema.fail(block, src, "cannot call a generic function through a pointer", .{});
        try sema.requireRuntime(block, src);
        for (fn_ty.param_types) |pt| try sema.resolveLayout(block, src, pt);
        try sema.resolveLayout(block, src, ret_ty);
        const payload = try sema.addExtra(Ir.Call{ .ret_ty = ret_ty, .args_len = @intCast(args.len) });
        try sema.ir_extra.appendSlice(sema.gpa, @ptrCast(args));
        return sema.addInst(block, .{ .tag = .call, .data = .{ .pl_op = .{ .operand = callee_ptr, .payload = payload } } });
    }
    if (comptime_call) {
        const vals = try sema.arena.alloc(Index, args.len);
        for (args, vals) |a, *v| v.* = try sema.resolveConstValue(block, src, a, "argument to function being called at comptime must be comptime-known");
        // Each comptime or inline call counts as a backward branch, as
        // upstream.
        try sema.emitBackwardBranch(block, src);
        const n = sema.zcu.errors.items.len;
        return .fromInterned(sema.callComptime(block, src, func, vals) catch |err| return sema.noteCallSite(block, src, n, err, "called at comptime here"));
    }

    if (fn_ty.cc == .@"inline" or modifier == .always_inline) {
        try sema.emitBackwardBranch(block, src);
        const n = sema.zcu.errors.items.len;
        return sema.inlineCall(block, src, func, args) catch |err| return sema.noteCallSite(block, src, n, err, "called inline here");
    }

    var callee_func = func;
    var call_args = args;
    if (fn_ty.is_generic) {
        const inst = try sema.instantiate(block, src, func, args);
        callee_func = inst.func;
        call_args = inst.runtime_args;
        if (try sema.isComptimeOnlyResolved(block, src, ip.indexToKey(ip.typeOf(callee_func)).func_type.return_type)) {
            const vals = try sema.arena.alloc(Index, args.len);
            for (args, vals) |a, *v| v.* = try sema.resolveConstValue(block, src, a, "argument to function being called at comptime must be comptime-known");
            try sema.emitBackwardBranch(block, src);
            const n = sema.zcu.errors.items.len;
            return .fromInterned(sema.callComptime(block, src, func, vals) catch |err| return sema.noteCallSite(block, src, n, err, "called at comptime here"));
        }
    }
    try sema.requireRuntime(block, src);
    const callee_fn_ty = ip.indexToKey(ip.typeOf(callee_func)).func_type;
    for (callee_fn_ty.param_types) |pt| {
        if (try sema.isComptimeOnlyResolved(block, src, pt)) return sema.fail(block, src, "parameter of comptime-only type '{f}' must be declared comptime", .{sema.fmtType(pt)});
    }
    if (callee_fn_ty.cc == .naked) return sema.fail(block, src, "unable to call function with naked calling convention", .{});
    try sema.declareDependency(.{ .nav_val = ip.indexToKey(callee_func).func.owner_nav });
    try sema.zcu.queueFuncFrom(sema.owner, callee_func);
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

fn vaListPtr(sema: *Sema, block: *Block, src: Src, ref: Zir.Inst.Ref) CompileError!Ref {
    const ty = try sema.ptrType(.{ .child = try sema.stdLangType(block, src, "VaList") });
    return sema.coerce(block, ty, sema.resolveInst(ref), src);
}

/// An argument passed for a C function's `...`, promoted as upstream's
/// `coerceVarArgParam`: small integers to c_int or c_uint, f32 to f64, and
/// a function to a pointer to it.
fn coerceVarArg(sema: *Sema, block: *Block, src: Src, arg: Ref) CompileError!Ref {
    if (block.is_typeof) return arg;
    const ip = sema.ip;
    const ty = sema.typeOf(arg);
    const coerced = switch (Type.class(ip, ty)) {
        .comptime_int, .comptime_float => return sema.fail(block, src, "integer and float literals passed to variadic function must be casted to a fixed-size number type", .{}),
        .array => return sema.fail(block, src, "arrays must be passed by reference to variadic function", .{}),
        .@"fn" => try sema.analyzeRef(block, src, arg),
        .float => if (Type.floatBits(ip, ty) < 64) try sema.coerce(block, .f64_type, arg, src) else arg,
        .int => int: {
            const info = Type.intInfo(ip, ty);
            if (info.bits <= 32) break :int try sema.coerce(block, if (info.signedness == .signed) .c_int_type else .c_uint_type, arg, src);
            if (info.bits <= 64) break :int try sema.coerce(block, if (info.signedness == .signed) .c_long_type else .c_ulong_type, arg, src);
            break :int arg;
        },
        else => arg,
    };
    try sema.resolveLayout(block, src, sema.typeOf(coerced));
    return coerced;
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
        const is_comptime = tag == .param_comptime or tag == .param_anytype_comptime or (try sema.isComptimeOnlyResolved(caller, src, sema.typeOf(args[i])));
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
    // For debug info, the body is marked as an inlined call from the
    // current statement; its statements are relative to the callee.
    const call_line = sema.dbg_line;
    const call_column = sema.dbg_column;
    defer {
        sema.dbg_line = call_line;
        sema.dbg_column = call_column;
    }
    _ = try sema.addInst(&child, .{ .tag = .dbg_inline_begin, .data = .{ .dbg_inline = .{
        .func = func,
        .payload = try sema.addExtra(Ir.DbgInline{ .line = call_line, .column = call_column }),
    } } });
    sema.analyzeBodyInner(&child, fn_info.body) catch |err| switch (err) {
        error.ComptimeReturn => {
            // Reached unconditionally (no earlier return), so the body's
            // runtime instructions run straight into the result.
            if (merges.results.items.len != 0) return sema.failUnsupported(caller, src, "a comptime return after a runtime return in an inline call");
            try sema.endDbgInline(&child);
            try caller.instructions.appendSlice(gpa, child.instructions.items);
            return inlining.result;
        },
        else => return err,
    };
    try sema.endDbgInline(&child);
    return sema.resolveBlock(caller, src, &child, &merges);
}

/// Closes the `dbg_inline_begin` that starts `child`, dropping both if the
/// body has no instructions. The end goes before a final jump or trap, so
/// that the body still ends in it (`resolveBlock` and `noreturn` checks
/// look at the last instruction).
fn endDbgInline(sema: *Sema, child: *Block) !void {
    const insts = &child.instructions;
    if (insts.items.len == 1) {
        insts.items.len = 0;
        return;
    }
    const end = try sema.reserveInst();
    sema.ir_insts.set(@backingInt(end), .{ .tag = .dbg_inline_end, .data = .{ .no_op = {} } });
    const last = insts.getLast();
    const before_last = switch (sema.ir_insts.items(.tag)[@backingInt(last)]) {
        .br, .repeat, .ret, .unreach, .trap => true,
        else => false,
    };
    try insts.insert(sema.gpa, if (before_last) insts.items.len - 1 else insts.items.len, end);
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
        // Also through a constant holding such a pointer (`&ptr` where
        // `const ptr = &comptime_var`).
        .ptr => |k| switch (sema.ptrRootBase(k)) {
            .comptime_alloc => true,
            .uav => |u| sema.refersToComptimeAlloc(u.val),
            else => false,
        },
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
        if ((k < 32 and (generic_ty.comptime_bits >> @intCast(k)) & 1 != 0) or (try sema.isComptimeOnlyResolved(caller, src, sema.typeOf(a)))) {
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
    // As upstream, an instance's body runs with the largest branch quota
    // of its callers at instantiation (an order dependence upstream also
    // has; see Zcu.branch_quotas).
    const gop = try sema.zcu.branch_quotas.getOrPut(sema.gpa, instance);
    gop.value_ptr.* = if (gop.found_existing) @max(gop.value_ptr.*, sema.branch_quota) else sema.branch_quota;
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

/// The one possible value of the elements that indexing through pointer
/// type `ty` (to an array or vector, or a slice or many-pointer) reads.
fn indexedOnePossibleValue(sema: *Sema, ty: Index) CompileError!?Index {
    const ip = sema.ip;
    if (Type.class(ip, ty) != .pointer) return null;
    const p = Type.ptrInfo(ip, ty);
    const elem = switch (p.flags.size) {
        .one => switch (ip.indexToKey(p.child)) {
            .array_type, .vector_type => Type.childType(ip, p.child),
            // A pointer to the slice or pointer being indexed.
            .ptr_type => |cp| if (cp.flags.size != .one) cp.child else return null,
            else => return null,
        },
        else => p.child,
    };
    if (Type.hasRuntimeBits(ip, elem) or Type.isComptimeOnly(ip, elem)) return null;
    return sema.onePossibleValue(elem);
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
    if (len >= vector_loop_min_len and !block.is_comptime and sema.vectorLoopable(operands))
        return sema.vectorMapLoop(block, src, len, result_ty, operands, op);
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

/// Runtime vectors at least this long are mapped with a loop instead of
/// one copy of the scalar operation per element. Below it, the loop's
/// bookkeeping costs more than unrolling.
const vector_loop_min_len = 4;

/// Whether a vector operation on `operands` runs at runtime on elements
/// with runtime bits (zero-bit elements fold to their only value).
fn vectorLoopable(sema: *Sema, operands: []const Ref) bool {
    var runtime = false;
    for (operands) |o| {
        const ty = sema.typeOf(o);
        if (sema.vectorLen(ty) == null) continue;
        if (!Type.hasRuntimeBits(sema.ip, Type.childType(sema.ip, ty))) return false;
        if (sema.resolveValue(o) == null) runtime = true;
    }
    return runtime;
}

/// `vectorMap` as a runtime loop:
///
///     res: @Vector(len, R) = undefined; i: usize = 0;
///     while (i < len) : (i += 1) res[i] = op(a[i], b[i]);
///
/// The scalar operation is analyzed once, on elements at a runtime index,
/// so its safety checks are emitted once instead of per element.
fn vectorMapLoop(sema: *Sema, block: *Block, src: Src, len: u32, result_ty: Index, operands: []const Ref, op: anytype) CompileError!Ref {
    const gpa = sema.gpa;
    const idx_ptr = try sema.analyzeAlloc(block, src, .usize_type, false, false);
    try sema.analyzeStore(block, src, idx_ptr, .fromInterned(.zero_usize));
    // The result's element type is known once the operation is analyzed.
    const res_inst = try sema.reserveInst();
    const block_inst = try sema.reserveInst();
    const loop_inst = try sema.reserveInst();

    var loop_block = block.child();
    defer loop_block.instructions.deinit(gpa);
    const i = try sema.analyzeLoad(&loop_block, src, idx_ptr);
    const in_range = try sema.addBinOp(&loop_block, .cmp_lt, i, .fromInterned(try sema.intValue(.usize_type, len)));

    var then_block = block.child();
    defer then_block.instructions.deinit(gpa);
    const scalars = try sema.arena.alloc(Ref, operands.len);
    for (operands, scalars) |o, *sc| sc.* = if (sema.vectorLen(sema.typeOf(o)) != null) try sema.addBinOp(&then_block, .array_elem_val, o, i) else o;
    const r = try op.call(sema, &then_block, src, scalars);
    const ty = if (result_ty != .none) result_ty else try sema.vectorType(len, sema.typeOf(r));
    try sema.resolveLayout(block, src, ty);
    const payload = try sema.addExtra(Ir.Bin{ .lhs = i, .rhs = r });
    _ = try sema.addInst(&then_block, .{ .tag = .vector_store_elem, .data = .{ .pl_op = .{ .operand = res_inst.toRef(), .payload = payload } } });
    const next = try sema.addBinOp(&then_block, .add_wrap, i, .fromInterned(try sema.intValue(.usize_type, 1)));
    try sema.analyzeStore(&then_block, src, idx_ptr, next);
    _ = try sema.addInst(&then_block, .{ .tag = .repeat, .data = .{ .repeat = .{ .loop_inst = loop_inst } } });

    var else_block = block.child();
    defer else_block.instructions.deinit(gpa);
    _ = try sema.addInst(&else_block, .{ .tag = .br, .data = .{ .br = .{ .block_inst = block_inst, .operand = .void_value } } });
    try sema.addCondBr(&loop_block, in_range, then_block.instructions.items, else_block.instructions.items);

    const loop_payload = try sema.addExtra(Ir.Block{ .body_len = @intCast(loop_block.instructions.items.len) });
    try sema.appendBody(loop_block.instructions.items);
    sema.ir_insts.set(@backingInt(loop_inst), .{ .tag = .loop, .data = .{ .ty_pl = .{ .ty = .noreturn_type, .payload = loop_payload } } });
    sema.ir_insts.set(@backingInt(res_inst), .{ .tag = .alloc, .data = .{ .ty = try sema.ptrType(.{ .child = ty }) } });
    try block.instructions.append(gpa, res_inst);
    try sema.addBlock(block, block_inst, .void_type, &.{loop_inst});
    return sema.analyzeLoad(block, src, res_inst.toRef());
}

/// Whether every value of `src` coerces to `dest`, both integers or both
/// floats (as upstream's vector coercion fast path).
fn elemCoercionWidens(sema: *Sema, dest: Index, src: Index) bool {
    const ip = sema.ip;
    if (Type.isInt(ip, dest) and Type.isInt(ip, src)) {
        const d = Type.intInfo(ip, dest);
        const s = Type.intInfo(ip, src);
        return (d.signedness == s.signedness and d.bits >= s.bits) or (d.signedness == .signed and d.bits > s.bits);
    }
    return Type.class(ip, dest) == .float and Type.class(ip, src) == .float and Type.floatBits(ip, dest) >= Type.floatBits(ip, src);
}

fn coerceElem(sema: *Sema, block: *Block, src: Src, dest_ty: Index, operand: Ref) CompileError!Ref {
    return sema.coerce(block, dest_ty, operand, src);
}

/// An operand of a vector operation of type `vec_ty`. A vector of another
/// element type stays as is: its elements coerce one at a time inside the
/// operation, instead of in a separate pass over the vector.
/// As upstream, only an array may stand in for a vector operand.
fn vectorOperand(sema: *Sema, block: *Block, src: Src, vec_ty: Index, operand: Ref) CompileError!Ref {
    const ty = sema.typeOf(operand);
    if (sema.vectorLen(ty) != null) return operand;
    if (Type.class(sema.ip, ty) != .array)
        return sema.fail(block, src, "mixed scalar and vector operands: '{f}' and '{f}'", .{ sema.fmtType(vec_ty), sema.fmtType(ty) });
    return sema.coerce(block, vec_ty, operand, src);
}

/// A binary operation, with the scalars first coerced to `elem_ty` unless
/// it is `.none`.
const VectorArith = struct {
    tag: Zir.Inst.Tag,
    elem_ty: Index = .none,
    fn call(op: VectorArith, sema: *Sema, block: *Block, src: Src, s: []const Ref) CompileError!Ref {
        if (op.elem_ty == .none) return sema.analyzeArithmetic(block, src, op.tag, s[0], s[1]);
        return sema.analyzeArithmetic(block, src, op.tag, try sema.coerce(block, op.elem_ty, s[0], src), try sema.coerce(block, op.elem_ty, s[1], src));
    }
};

const VectorCmp = struct {
    op: std.math.CompareOperator,
    elem_ty: Index,
    fn call(op: VectorCmp, sema: *Sema, block: *Block, src: Src, s: []const Ref) CompileError!Ref {
        return sema.analyzeCmp(block, src, op.op, try sema.coerce(block, op.elem_ty, s[0], src), try sema.coerce(block, op.elem_ty, s[1], src));
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
    if (len >= vector_loop_min_len and !block.is_comptime and sema.vectorLoopable(&.{operand}))
        return sema.reduceLoop(block, src, tag, operand, len);
    // A left fold, in element order.
    var acc = try sema.vectorElem(block, operand, 0);
    for (1..len) |i| acc = try sema.analyzeArithmetic(block, src, tag, acc, try sema.vectorElem(block, operand, @intCast(i)));
    return acc;
}

/// `@reduce` of a runtime vector as a loop:
///
///     acc = v[0]; i = 1; while (i < len) : (i += 1) acc = op(acc, v[i]);
fn reduceLoop(sema: *Sema, block: *Block, src: Src, tag: Zir.Inst.Tag, operand: Ref, len: u32) CompileError!Ref {
    const gpa = sema.gpa;
    const elem_ty = Type.childType(sema.ip, sema.typeOf(operand));
    const acc_ptr = try sema.analyzeAlloc(block, src, elem_ty, false, false);
    try sema.analyzeStore(block, src, acc_ptr, try sema.vectorElem(block, operand, 0));
    const idx_ptr = try sema.analyzeAlloc(block, src, .usize_type, false, false);
    try sema.analyzeStore(block, src, idx_ptr, .fromInterned(try sema.intValue(.usize_type, 1)));
    const block_inst = try sema.reserveInst();
    const loop_inst = try sema.reserveInst();

    var loop_block = block.child();
    defer loop_block.instructions.deinit(gpa);
    const i = try sema.analyzeLoad(&loop_block, src, idx_ptr);
    const in_range = try sema.addBinOp(&loop_block, .cmp_lt, i, .fromInterned(try sema.intValue(.usize_type, len)));

    var then_block = block.child();
    defer then_block.instructions.deinit(gpa);
    const acc = try sema.analyzeLoad(&then_block, src, acc_ptr);
    const elem = try sema.addBinOp(&then_block, .array_elem_val, operand, i);
    try sema.analyzeStore(&then_block, src, acc_ptr, try sema.analyzeArithmetic(&then_block, src, tag, acc, elem));
    try sema.analyzeStore(&then_block, src, idx_ptr, try sema.addBinOp(&then_block, .add_wrap, i, .fromInterned(try sema.intValue(.usize_type, 1))));
    _ = try sema.addInst(&then_block, .{ .tag = .repeat, .data = .{ .repeat = .{ .loop_inst = loop_inst } } });

    var else_block = block.child();
    defer else_block.instructions.deinit(gpa);
    _ = try sema.addInst(&else_block, .{ .tag = .br, .data = .{ .br = .{ .block_inst = block_inst, .operand = .void_value } } });
    try sema.addCondBr(&loop_block, in_range, then_block.instructions.items, else_block.instructions.items);

    const loop_payload = try sema.addExtra(Ir.Block{ .body_len = @intCast(loop_block.instructions.items.len) });
    try sema.appendBody(loop_block.instructions.items);
    sema.ir_insts.set(@backingInt(loop_inst), .{ .tag = .loop, .data = .{ .ty_pl = .{ .ty = .noreturn_type, .payload = loop_payload } } });
    try sema.addBlock(block, block_inst, .void_type, &.{loop_inst});
    return sema.analyzeLoad(block, src, acc_ptr);
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

/// Appended to test sources: these tests have no std, so safety checks
/// call these handlers, as a root `panic` namespace overrides std's.
const test_panic =
    \\
    \\pub const panic = struct {
    \\    pub fn integerOverflow() noreturn {
    \\        @trap();
    \\    }
    \\    pub fn outOfBounds(_: usize, _: usize) noreturn {
    \\        @trap();
    \\    }
    \\    pub fn startGreaterThanEnd(_: usize, _: usize) noreturn {
    \\        @trap();
    \\    }
    \\    pub fn corruptSwitch() noreturn {
    \\        @trap();
    \\    }
    \\};
    \\
;

fn testAnalyze(source: []const u8) ![]u8 {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const full = try std.mem.concat(gpa, u8, &.{ source, test_panic });
    defer gpa.free(full);
    try tmp.dir.writeFile(io, .{ .sub_path = "t.zig", .data = full });
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/t.zig", .{tmp.sub_path});
    defer gpa.free(root);
    var fe: Frontend = try .init(gpa, io, "/nonexistent", .{ .root_src_path = root, .builtin_dir = "/nonexistent", .load_std = false });
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
        \\  %8 = block(void, {
        \\    %10 = cond_br(%5, {
        \\      %9 = br(%8, <void, void>)
        \\    }, {
        \\      %6 = call(<fn () noreturn, t.panic.integerOverflow>, [])
        \\      %7 = unreach()
        \\    })
        \\  })
        \\  %11 = dbg_stmt(2:5)
        \\  %12 = ret(%3)
        \\}
        \\fn t.panic.integerOverflow() noreturn {
        \\  %0 = dbg_stmt(2:9)
        \\  %1 = trap()
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
        \\  %10 = block(void, {
        \\    %12 = cond_br(%7, {
        \\      %11 = br(%10, <void, void>)
        \\    }, {
        \\      %8 = call(<fn (usize, usize) noreturn, t.panic.startGreaterThanEnd>, [<usize, 0>, %1])
        \\      %9 = unreach()
        \\    })
        \\  })
        \\  %13 = sub_wrap(%1, <usize, 0>)
        \\  %14 = slice([]const u8, %6, %13)
        \\  %15 = alloc(*const []const u8)
        \\  %16 = store(%15, %14)
        \\  %17 = dbg_stmt(2:19)
        \\  %18 = load([]const u8, %15)
        \\  %19 = slice_len(usize, %18)
        \\  %20 = cmp_lt(%2, %19)
        \\  %23 = block(void, {
        \\    %25 = cond_br(%20, {
        \\      %24 = br(%23, <void, void>)
        \\    }, {
        \\      %21 = call(<fn (usize, usize) noreturn, t.panic.outOfBounds>, [%2, %19])
        \\      %22 = unreach()
        \\    })
        \\  })
        \\  %26 = slice_elem_ptr(*const u8, %18, %2)
        \\  %27 = load(u8, %26)
        \\  %28 = dbg_stmt(2:5)
        \\  %29 = ret(%27)
        \\}
        \\fn t.panic.startGreaterThanEnd(usize, usize) noreturn {
        \\  %0 = arg(usize, 0)
        \\  %1 = arg(usize, 1)
        \\  %2 = dbg_stmt(2:9)
        \\  %3 = trap()
        \\}
        \\fn t.panic.outOfBounds(usize, usize) noreturn {
        \\  %0 = arg(usize, 0)
        \\  %1 = arg(usize, 1)
        \\  %2 = dbg_stmt(2:9)
        \\  %3 = trap()
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
        \\  %12 = block(void, {
        \\    %14 = cond_br(%9, {
        \\      %13 = br(%12, <void, void>)
        \\    }, {
        \\      %10 = call(<fn () noreturn, t.panic.integerOverflow>, [])
        \\      %11 = unreach()
        \\    })
        \\  })
        \\  %15 = dbg_stmt(2:5)
        \\  %16 = ret(%7)
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
        \\fn t.panic.integerOverflow() noreturn {
        \\  %0 = dbg_stmt(2:9)
        \\  %1 = trap()
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
        \\  %4 = dbg_stmt(2:13)
        \\  %5 = call(%1, [%3])
        \\  %6 = dbg_stmt(2:5)
        \\  %7 = intcast(u16, %5)
        \\  %8 = ret(%7)
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
        \\    %13 = cond_br(%4, {
        \\      %6 = unwrap_errunion_payload(u8, %2)
        \\      %7 = br(%5, %6)
        \\    }, {
        \\      %8 = unwrap_errunion_err(@typeInfo(@typeInfo(@TypeOf(t.g)).@"fn".return_type.?).error_union.error_set, %2)
        \\      %12 = switch_br(%8, [<@typeInfo(@typeInfo(@TypeOf(t.g)).@"fn".return_type.?).error_union.error_set, error.Zero>] => {
        \\        %9 = br(%5, <u8, 1>)
        \\      }, else => {
        \\        %10 = call(<fn () noreturn, t.panic.corruptSwitch>, [])
        \\        %11 = unreach()
        \\      })
        \\    })
        \\  })
        \\  %14 = dbg_stmt(2:5)
        \\  %15 = ret(%5)
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
        \\fn t.panic.corruptSwitch() noreturn {
        \\  %0 = dbg_stmt(2:9)
        \\  %1 = trap()
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
    var fe: Frontend = try .init(gpa, io, "/nonexistent", .{ .root_src_path = root, .builtin_dir = "/nonexistent", .load_std = false });
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
