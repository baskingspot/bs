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
inferred_allocs: std.AutoHashMapUnmanaged(Ir.Inst.Index, InferredAlloc) = .empty,
branch_quota: u32 = 1000,
branch_count: u32 = 0,
last_dbg_stmt: ?Ir.Inst.Index = null,

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
    /// Collects parameters while a function prototype is analyzed.
    params: ?*std.ArrayList(Param) = null,
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

    /// A comptime call being evaluated.
    pub const Inlining = struct {
        func: Index,
        ret_ty: Index,
        result: Ref = .none,
        /// Comptime arguments, for naming types the call returns.
        args: []const Index,
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
    },

    fn span(src: Src, tree: *const Ast) Ast.Span {
        return switch (src.loc) {
            .node => |off| tree.nodeToSpan(off.toAbsolute(src.base)),
            .node_abs => |n| tree.nodeToSpan(n),
            .token => |off| tree.tokenToSpan(off.toAbsolute(tree.firstToken(src.base))),
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
    var params: std.ArrayList(Block.Param) = .empty;
    block.params = &params;
    const src = block.nodeSrc(.zero);

    if (decl.linkage == .@"extern") return sema.fail(&block, src, "zap does not support extern declarations yet", .{});
    const decl_ty: Index = if (decl.type_body) |body| blk: {
        const ref = try sema.resolveInlineBody(&block, body, nav.zir_inst);
        break :blk try sema.analyzeAsType(&block, src, ref);
    } else .none;
    // Within the value body, the `declaration` instruction refers to the type.
    if (decl_ty != .none) try sema.inst_map.put(sema.gpa, nav.zir_inst, .fromInterned(decl_ty));
    var val_ref = try sema.resolveInlineBody(&block, decl.value_body.?, nav.zir_inst);
    if (decl_ty != .none) val_ref = try sema.coerce(&block, decl_ty, val_ref, src);
    const val = try sema.resolveConstValue(&block, src, val_ref, "global variable initializer must be comptime-known");
    nav.val = val;
    nav.ty = sema.ip.typeOf(val);
    try sema.finish();
}

pub fn analyzeComptimeDecl(zcu: *Zcu, c: Zcu.ComptimeDecl) CompileError!void {
    var arena_state: std.heap.ArenaAllocator = .init(zcu.gpa);
    defer arena_state.deinit();
    var sema = create(zcu, arena_state.allocator(), c.file, .{ .comptime_decl = .{ .file = c.file, .inst = c.inst } });
    defer sema.destroy();
    const decl = sema.code.getDeclaration(c.inst);
    var block = sema.rootBlock(c.namespace, decl.src_node, true);
    defer block.instructions.deinit(zcu.gpa);
    _ = try sema.resolveInlineBody(&block, decl.value_body.?, c.inst);
    try sema.finish();
}

pub fn analyzeStructLayout(zcu: *Zcu, ty: Index) CompileError!void {
    const ip = &zcu.ip;
    const key = ip.indexToKey(ty).struct_type;
    const info = ip.structInfo(ty);
    var arena_state: std.heap.ArenaAllocator = .init(zcu.gpa);
    defer arena_state.deinit();
    var sema = create(zcu, arena_state.allocator(), key.file, .{ .type_layout = ty });
    defer sema.destroy();
    const decl = sema.code.getStructDecl(key.zir_inst);
    var block = sema.rootBlock(info.namespace, decl.fields_baseline_src_node, true);
    defer block.instructions.deinit(zcu.gpa);

    if (decl.layout == .@"packed") return sema.fail(&block, block.nodeSrc(.zero), "zap does not support packed structs yet", .{});
    info.status = .field_types_wip;
    const n = decl.field_names.len;
    const names = try ip.arena(Zcu.tid).alloc(InternPool.String, n);
    const types = try ip.arena(Zcu.tid).alloc(Index, n);
    const defaults = try ip.arena(Zcu.tid).alloc(Index, n);
    const offsets = try ip.arena(Zcu.tid).alloc(u64, n);
    var it = decl.iterateFields();
    while (it.next()) |field| {
        const i = field.idx;
        names[i] = try ip.getString(Zcu.tid, sema.code.nullTerminatedString(field.name));
        if (field.is_comptime) return sema.fail(&block, block.nodeSrc(.zero), "zap does not support comptime fields yet", .{});
        if (field.align_body != null) return sema.fail(&block, block.nodeSrc(.zero), "zap does not support field alignment yet", .{});
        const ty_ref = try sema.resolveInlineBody(&block, field.type_body, key.zir_inst);
        types[i] = try sema.analyzeAsType(&block, block.nodeSrc(.zero), ty_ref);
        defaults[i] = .none;
    }
    info.field_names = names;
    info.field_types = types;
    info.status = .have_field_types;

    // Defaults may refer to the struct itself (for example its size), so
    // they are evaluated after the field types.
    it = decl.iterateFields();
    while (it.next()) |field| {
        const body = field.default_body orelse continue;
        const ref = try sema.resolveInlineBody(&block, body, key.zir_inst);
        const coerced = try sema.coerce(&block, types[field.idx], ref, block.nodeSrc(.zero));
        defaults[field.idx] = try sema.resolveConstValue(&block, block.nodeSrc(.zero), coerced, "struct field default value must be comptime-known");
    }
    info.field_defaults = defaults;

    info.status = .layout_wip;
    var offset: u64 = 0;
    var alignment: u64 = 1;
    for (types, 0..) |ft, i| {
        try sema.resolveLayout(&block, block.nodeSrc(.zero), ft);
        if (!Type.hasRuntimeBits(ip, ft)) {
            offsets[i] = offset;
            continue;
        }
        const a = Type.abiAlignment(ip, ft);
        offset = std.mem.alignForward(u64, offset, a);
        offsets[i] = offset;
        offset += Type.abiSize(ip, ft);
        alignment = @max(alignment, a);
    }
    info.field_offsets = offsets;
    info.size = std.mem.alignForward(u64, offset, alignment);
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

    const main_block: u32 = @intCast(sema.ir_extra.items.len);
    try sema.ir_extra.append(gpa, @intCast(block.instructions.items.len));
    try sema.ir_extra.appendSlice(gpa, @ptrCast(block.instructions.items));
    try sema.finish();
    var ir: Ir = .{
        .instructions = sema.ir_insts.toOwnedSlice(),
        .extra = try sema.ir_extra.toOwnedSlice(gpa),
        .func = func_index,
        .main_block = main_block,
    };
    _ = &ir;
    return ir;
}

// ---------------------------------------------------------------------------
// Diagnostics

pub fn fail(sema: *Sema, block: *const Block, src: Src, comptime fmt: []const u8, args: anytype) CompileError {
    _ = block;
    const tree = &sema.zcu.file(sema.file).tree;
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
        .struct_type => {
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

/// Resolves the field types (not necessarily the layout) of a struct.
fn resolveStructFields(sema: *Sema, block: *Block, src: Src, ty: Index) CompileError!void {
    const info = sema.ip.structInfo(ty);
    if (info.status == .layout_wip or info.status == .have_field_types) return;
    try sema.resolveLayout(block, src, ty);
}

// ---------------------------------------------------------------------------
// IR construction

fn addInst(sema: *Sema, block: *Block, inst: Ir.Inst) !Ref {
    assert(!block.is_comptime);
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
                if (block.is_comptime) return sema.fail(block, src, "encountered @panic at comptime", .{});
                return sema.failUnsupported(block, src, "@panic");
            },
            .compile_error => {
                const src = block.nodeSrc(data.un_node.src_node);
                const msg = try sema.resolveConstString(block, src, sema.resolveInst(data.un_node.operand));
                return sema.fail(block, src, "{s}", .{msg});
            },

            // Instructions with no result.
            .dbg_stmt => {
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
            .validate_destructure => return sema.failUnsupported(block, block.nodeSrc(.zero), "destructuring"),
            .set_runtime_safety => {
                const src = block.nodeSrc(data.un_node.src_node);
                block.want_safety = try sema.resolveBool(block, src, sema.resolveInst(data.un_node.operand), "operand to @setRuntimeSafety must be comptime-known");
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
        inlining.result = try sema.coerce(b, inlining.ret_ty, operand, src);
        return error.ComptimeReturn;
    }
    if (b.is_comptime) return sema.fail(b, src, "function called at runtime cannot return value at comptime", .{});
    try sema.recordInferredErrors(operand);
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
            const limb_bytes = data.str.get(sema.code.*);
            const limbs = try sema.arena.alloc(std.math.big.Limb, limb_bytes.len / @sizeOf(std.math.big.Limb));
            @memcpy(std.mem.sliceAsBytes(limbs), limb_bytes);
            break :blk .fromInterned(try sema.bigToValue(.comptime_int_type, .{ .limbs = limbs, .positive = true }));
        },
        .float, .float128 => sema.failUnsupported(block, block.nodeSrc(.zero), "floating point"),
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
        .splat_op_result_ty, .from_backing_int_arg_ty, .vector_type, .reify_int, .anyframe_type => sema.failUnsupported(block, block.nodeSrc(.zero), @tagName(tag)),
        .typeof => .fromInterned(sema.typeOf(sema.resolveInst(data.un_node.operand))),
        .typeof_builtin => blk: {
            const extra = sema.code.extraData(Zir.Inst.Block, data.pl_node.payload_index);
            const body = sema.code.bodySlice(extra.end, extra.data.body_len);
            var child = block.child();
            defer child.instructions.deinit(sema.gpa);
            // The operand is analyzed for its type only; any IR it emits is
            // never referenced by a body.
            child.is_comptime = false;
            if (block.is_comptime) child.is_comptime = true;
            const operand = try sema.resolveInlineBody(&child, body, inst);
            break :blk .fromInterned(sema.typeOf(operand));
        },
        .typeof_log2_int_type => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const ty = sema.typeOf(sema.resolveInst(data.un_node.operand));
            if (ty == .comptime_int_type) break :blk .fromInterned(.comptime_int_type);
            if (!Type.isInt(sema.ip, ty)) return sema.fail(block, src, "bit shifting operation expected integer type, found '{f}'", .{sema.fmtType(ty)});
            break :blk .fromInterned(try sema.intType(.unsigned, Type.log2IntBits(Type.intInfo(sema.ip, ty).bits)));
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
        .add, .addwrap, .add_unsafe, .sub, .subwrap, .mul, .mulwrap, .div, .div_trunc, .div_floor, .div_exact, .mod, .rem, .mod_rem, .shl, .shr, .bit_and, .bit_or, .xor, .min, .max => blk: {
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            break :blk sema.analyzeArithmetic(block, src, tag, sema.resolveInst(extra.lhs), sema.resolveInst(extra.rhs));
        },
        .add_sat, .sub_sat, .mul_sat, .shl_sat, .shl_exact, .shr_exact, .div_ceil => sema.failUnsupported(block, block.nodeSrc(data.pl_node.src_node), @tagName(tag)),
        .negate, .negate_wrap => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const operand = sema.resolveInst(data.un_node.operand);
            const ty = sema.typeOf(operand);
            const zero: Ref = if (ty == .comptime_int_type) .zero else .fromInterned(try sema.intValue(ty, 0));
            if (Type.class(sema.ip, ty) == .int and Type.intInfo(sema.ip, ty).signedness == .unsigned and tag == .negate)
                return sema.fail(block, src, "negation of type '{f}'", .{sema.fmtType(ty)});
            break :blk sema.analyzeArithmetic(block, src, if (tag == .negate) .sub else .subwrap, zero, operand);
        },
        .bit_not => sema.analyzeBitNot(block, block.nodeSrc(data.un_node.src_node), sema.resolveInst(data.un_node.operand)),
        .bool_not => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const operand = try sema.coerce(block, .bool_type, sema.resolveInst(data.un_node.operand), src);
            if (sema.resolveValue(operand)) |v| {
                if (sema.isUndef(v)) break :blk .fromInterned(v);
                break :blk .fromInterned(boolValue(v != .bool_true));
            }
            break :blk sema.addTyOp(block, .not, .bool_type, operand);
        },
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
        .builtin_call => sema.failUnsupported(block, block.nodeSrc(data.pl_node.src_node), "@call"),
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
                .elem_ptr_node, .elem_ptr => sema.elemPtr(block, src, lhs, index, safety),
                .elem_ptr_load => sema.analyzeLoad(block, src, try sema.elemPtr(block, src, lhs, index, safety)),
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
        .slice_sentinel_ty => sema.failUnsupported(block, block.nodeSrc(data.un_node.src_node), "slice sentinels"),
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
        .switch_block_ref => sema.failUnsupported(block, block.nodeSrc(data.pl_node.src_node), @tagName(tag)),

        // Initialization.
        .struct_init_empty, .struct_init_empty_result, .struct_init_empty_ref_result => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            var ty = try sema.resolveType(block, src, data.un_node.operand);
            if (tag == .struct_init_empty_ref_result) ty = Type.childType(sema.ip, ty);
            const val = try sema.structInitEmpty(block, src, ty);
            break :blk if (tag == .struct_init_empty_ref_result) sema.analyzeRef(block, src, val) else val;
        },
        .struct_init, .struct_init_ref => blk: {
            const val = try sema.zirStructInit(block, inst);
            break :blk if (tag == .struct_init_ref) sema.analyzeRef(block, block.nodeSrc(data.pl_node.src_node), val) else val;
        },
        .struct_init_anon => sema.failUnsupported(block, block.nodeSrc(data.pl_node.src_node), "anonymous struct literals without a result type"),
        .struct_init_field_type => blk: {
            const extra = sema.code.extraData(Zir.Inst.FieldType, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const ty = try sema.resolveType(block, src, extra.container_type);
            break :blk .fromInterned(try sema.fieldTypeByName(block, src, ty, sema.zirString(extra.name_start)));
        },
        .struct_init_field_ptr => blk: {
            const extra = sema.code.extraData(Zir.Inst.Field, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            break :blk sema.fieldPtr(block, src, sema.resolveInst(extra.lhs), sema.zirString(extra.field_name_start));
        },
        .array_init, .array_init_ref, .array_init_anon => blk: {
            const val = try sema.zirArrayInit(block, inst);
            break :blk if (tag == .array_init_ref) sema.analyzeRef(block, block.nodeSrc(data.pl_node.src_node), val) else val;
        },
        .validate_array_init_ref_ty => blk: {
            const extra = sema.code.extraData(Zir.Inst.ArrayInitRefTy, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const ptr_ty = try sema.resolveType(block, src, extra.ptr_ty);
            if (ptr_ty == .generic_poison_type) break :blk .fromInterned(.generic_poison_type);
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
                .tuple_type => |t| t.types[idx],
                .struct_type => sema.ip.structInfo(ty).field_types[idx],
                else => .generic_poison_type,
            });
        },
        .array_init_elem_ptr => blk: {
            const extra = sema.code.extraData(Zir.Inst.ElemPtrImm, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const index: Ref = .fromInterned(try sema.intValue(.usize_type, extra.index));
            break :blk sema.elemPtr(block, src, sema.resolveInst(extra.ptr), index, false);
        },
        .opt_eu_base_ptr_init => sema.zirOptEuBasePtrInit(block, inst),
        .coerce_ptr_elem_ty => blk: {
            const extra = sema.code.extraData(Zir.Inst.Bin, data.pl_node.payload_index).data;
            const src = block.nodeSrc(data.pl_node.src_node);
            const ptr_ty = try sema.resolveType(block, src, extra.lhs);
            const p = Type.ptrInfo(sema.ip, ptr_ty);
            const elem = if (p.flags.size == .slice) p.child else p.child;
            const operand = sema.resolveInst(extra.rhs);
            if (p.flags.size == .slice) {
                // `&.{...}` coerced to a slice: the operand becomes an array.
                break :blk operand;
            }
            break :blk sema.coerce(block, elem, operand, src);
        },

        // Casts and type queries.
        .int_cast => sema.zirIntCast(block, inst),
        .truncate => sema.zirTruncate(block, inst),
        .bitcast => sema.zirBitCast(block, inst),
        .int_from_bool => blk: {
            const src = block.nodeSrc(data.un_node.src_node);
            const operand = try sema.coerce(block, .bool_type, sema.resolveInst(data.un_node.operand), src);
            if (sema.resolveValue(operand)) |v| {
                if (sema.isUndef(v)) break :blk .fromInterned(.undef_u1);
                break :blk .fromInterned(if (v == .bool_true) .one_u1 else .zero_u1);
            }
            break :blk sema.addUnOp(block, .int_from_bool, operand);
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
            const bits = if (tag == .size_of) size else if (Type.isInt(sema.ip, ty)) Type.intInfo(sema.ip, ty).bits else if (ty == .bool_type) 1 else size * 8;
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
            if (sema.ip.indexToKey(ty) != .struct_type) return sema.failUnsupported(block, src, "@hasField on this type");
            try sema.resolveStructFields(block, src, ty);
            break :blk .fromInterned(boolValue(sema.ip.structInfo(ty).fieldIndex(sema.ip, name) != null));
        },
        else => sema.failUnsupported(block, block.nodeSrc(.zero), @tagName(tag)),
    };
}

fn zirExtended(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ext = sema.code.instructions.items(.data)[@backingInt(inst)].extended;
    return switch (ext.opcode) {
        .struct_decl => sema.zirStructDecl(block, inst),
        .this => blk: {
            const ns = sema.zcu.namespacePtr(block.namespace);
            break :blk .fromInterned(ns.owner_type);
        },
        .closure_get => blk: {
            const ns = sema.zcu.namespacePtr(block.namespace);
            const captures = sema.ip.indexToKey(ns.owner_type).struct_type.captures;
            break :blk .fromInterned(captures[ext.small]);
        },
        .@"asm" => sema.zirAsm(block, inst),
        .alloc => blk: {
            const extra = sema.code.extraData(Zir.Inst.AllocExtended, ext.operand);
            const small: Zir.Inst.AllocExtended.Small = @bitCast(ext.small);
            const src = block.nodeSrc(extra.data.src_node);
            if (small.has_align) return sema.failUnsupported(block, src, "aligned local variables");
            if (!small.has_type) break :blk sema.allocInferred(block, small.is_const, small.is_comptime);
            const ty = try sema.resolveType(block, src, @fromBackingInt(sema.code.extra[extra.end]));
            break :blk sema.analyzeAlloc(block, src, ty, small.is_const, small.is_comptime);
        },
        .add_with_overflow, .sub_with_overflow, .mul_with_overflow => blk: {
            const extra = sema.code.extraData(Zir.Inst.BinNode, ext.operand).data;
            const src = block.nodeSrc(extra.node);
            break :blk sema.analyzeOverflowBuiltin(block, src, ext.opcode, sema.resolveInst(extra.lhs), sema.resolveInst(extra.rhs));
        },
        .std_lang_value => blk: {
            const which: Zir.Inst.StdLangValue = @fromBackingInt(ext.small);
            const src = block.nodeSrc(@fromBackingInt(@as(i32, @bitCast(ext.operand))));
            break :blk switch (which) {
                .calling_convention => .fromInterned(.calling_convention_type),
                .clobbers => .fromInterned(.clobbers_type),
                .calling_convention_c => .fromInterned(try sema.intern(.{ .calling_convention = .c })),
                .calling_convention_inline => .fromInterned(try sema.intern(.{ .calling_convention = .@"inline" })),
                else => sema.fail(block, src, "zap does not support std.lang.{s} yet", .{@tagName(which)}),
            };
        },
        .inplace_arith_result_ty => blk: {
            const lhs = sema.resolveInst(@fromBackingInt(ext.operand));
            const ty = sema.typeOf(lhs);
            break :blk .fromInterned(if (Type.class(sema.ip, ty) == .pointer) .usize_type else ty);
        },
        .in_comptime => .fromInterned(boolValue(block.is_comptime)),
        .ptr_cast_full => blk: {
            const flags: Zir.Inst.FullPtrCastFlags = @bitCast(@as(u5, @truncate(ext.small)));
            break :blk sema.analyzePtrCast(block, inst, flags);
        },
        .ptr_cast_no_dest => blk: {
            const extra = sema.code.extraData(Zir.Inst.UnNode, ext.operand).data;
            const src = block.nodeSrc(extra.node);
            const operand = sema.resolveInst(extra.operand);
            var info = Type.ptrInfo(sema.ip, sema.typeOf(operand));
            const flags: Zir.Inst.FullPtrCastFlags = @bitCast(@as(u5, @truncate(ext.small)));
            if (flags.const_cast) info.flags.is_const = false;
            if (flags.volatile_cast) info.flags.is_volatile = false;
            _ = src;
            break :blk sema.coercePtrTo(block, operand, try sema.ptrType(info));
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
    if (sema.ip.indexToKey(ty) != .struct_type) return null;
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
        break :blk try std.fmt.allocPrint(sema.arena, "{d}:{s}", .{ @backingInt(this_file.module), sub });
    } else if (std.mem.eql(u8, path, "std"))
        try std.fmt.allocPrint(sema.arena, "{d}:{s}", .{ @backingInt(@import("Frontend.zig").Module.Index.std), fe.module(.std).root_file })
    else if (std.mem.eql(u8, path, "root"))
        try std.fmt.allocPrint(sema.arena, "{d}:{s}", .{ @backingInt(@import("Frontend.zig").Module.Index.root), fe.module(.root).root_file })
    else
        return sema.fail(block, src, "zap does not support importing '{s}' yet", .{path});
    const file_index = fe.file_map.get(key) orelse return sema.fail(block, src, "unable to find '{s}'", .{path});
    return .fromInterned(try sema.zcu.fileRootType(@backingInt(file_index)));
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
    const nav = (try sema.lookupInType(ty, name)) orelse
        return sema.fail(block, src, "type '{f}' has no declaration named '{s}'", .{ sema.fmtType(ty), name });
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

fn zirStructDecl(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const decl = sema.code.getStructDecl(inst);
    const src: Src = .{ .base = decl.src_node, .loc = .{ .node_abs = decl.src_node } };
    const captures = try sema.arena.alloc(Index, decl.captures.len);
    for (decl.captures, captures) |cap, *out| {
        out.* = switch (cap.unwrap()) {
            .nested => |i| sema.ip.indexToKey(sema.zcu.namespacePtr(block.namespace).owner_type).struct_type.captures[i],
            .instruction => |i| try sema.resolveConstValue(block, src, sema.resolveInst(i.toRef()), "captured value must be comptime-known"),
            .instruction_load => |i| blk: {
                const loaded = try sema.analyzeLoad(block, src, sema.resolveInst(i.toRef()));
                break :blk try sema.resolveConstValue(block, src, loaded, "captured value must be comptime-known");
            },
            .decl_val => |name| try sema.resolveConstValue(block, src, try sema.navVal(block, src, try sema.lookupName(block, src, sema.zirString(name))), "captured value must be comptime-known"),
            .decl_ref => |name| try sema.resolveConstValue(block, src, try sema.navRef(block, src, try sema.lookupName(block, src, sema.zirString(name))), "captured value must be comptime-known"),
        };
    }
    const fqn = try sema.typeName(block, decl.name_strategy, inst);
    const ty = try sema.zcu.createStructType(sema.file, inst, captures, fqn, block.namespace);
    return .fromInterned(ty);
}

/// The fully qualified name of a new type, following `strategy`.
fn typeName(sema: *Sema, block: *Block, strategy: Zir.Inst.NameStrategy, inst: Zir.Inst.Index) Allocator.Error![]const u8 {
    switch (strategy) {
        .parent => if (sema.owner_nav != .none and block.inlining == null) {
            return sema.ip.stringSlice(sema.ip.getNav(sema.owner_nav).fqn);
        },
        .func => if (block.inlining) |inlining| {
            var aw: std.Io.Writer.Allocating = .init(sema.arena);
            const func = sema.ip.indexToKey(inlining.func).func;
            const w = &aw.writer;
            w.print("{s}(", .{sema.ip.stringSlice(sema.ip.getNav(func.owner_nav).fqn)}) catch return error.OutOfMemory;
            var first = true;
            for (inlining.args) |arg| {
                if (arg == .none) continue;
                if (!first) w.writeAll(",") catch return error.OutOfMemory;
                first = false;
                (if (sema.ip.isType(arg)) print.printType(sema.ip, arg, w) else print.printValue(sema.ip, arg, w)) catch return error.OutOfMemory;
            }
            w.writeAll(")") catch return error.OutOfMemory;
            return aw.written();
        },
        .anon, .dbg_var => {},
    }
    const parent = sema.zcu.namespacePtr(block.namespace).fqn;
    return std.fmt.allocPrint(sema.arena, "{s}__struct_{d}", .{ parent, @backingInt(inst) });
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
    }
    if (data.flags.has_addrspace) return sema.failUnsupported(block, src, "address spaces");
    if (data.flags.has_bit_range) return sema.failUnsupported(block, src, "bit-pointers");
    return .fromInterned(try sema.ptrType(.{
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
fn errorSetNames(sema: *Sema, ty: Index) ?[]const InternPool.String {
    return switch (sema.ip.indexToKey(ty)) {
        .error_set_type => |names| names,
        else => null,
    };
}

fn mergeErrorSets(sema: *Sema, block: *Block, src: Src, a: Index, b: Index) CompileError!Index {
    const an = sema.errorSetNames(a) orelse return if (a == .anyerror_type) .anyerror_type else sema.failUnsupported(block, src, "merging inferred error sets");
    const bn = sema.errorSetNames(b) orelse return if (b == .anyerror_type) .anyerror_type else sema.failUnsupported(block, src, "merging inferred error sets");
    const names = try sema.arena.alloc(InternPool.String, an.len + bn.len);
    @memcpy(names[0..an.len], an);
    @memcpy(names[an.len..], bn);
    return sema.errorSetType(names);
}

fn currentRetTy(sema: *Sema, block: *Block) Index {
    if (block.inlining) |inlining| return inlining.ret_ty;
    return sema.fn_ret_ty;
}

fn recordInferredErrors(sema: *Sema, operand: Ref) !void {
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
    try sema.addInferredErrors(set);
}

/// Adds the errors of `set` to the current function's inferred error set.
fn addInferredErrors(sema: *Sema, set: Index) !void {
    const names = sema.errorSetNames(set) orelse return;
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
            if (dc == .comptime_int) return sema.fail(block, src, "unable to resolve comptime value", .{});
            const s = Type.intInfo(ip, src_ty);
            const d = Type.intInfo(ip, dest_ty);
            const fits = if (s.signedness == d.signedness) d.bits >= s.bits else s.signedness == .unsigned and d.bits > s.bits;
            if (fits) return try sema.addTyOp(block, .intcast, dest_ty, inst);
            return null;
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
        .pointer => if (sc == .pointer) return sema.coercePtr(block, dest_ty, inst),
        .array => if (sc == .tuple) {
            const a = ip.indexToKey(dest_ty).array_type;
            const t = ip.indexToKey(src_ty).tuple_type;
            if (t.types.len != a.len) return null;
            const elems = try sema.arena.alloc(Ref, a.lenIncludingSentinel());
            for (0..t.types.len) |k| {
                const field = try sema.tupleField(block, inst, @intCast(k));
                elems[k] = (try sema.coerceInner(block, a.child, field, src)) orelse return null;
            }
            if (a.sentinel != .none) elems[a.len] = .fromInterned(a.sentinel);
            return try sema.aggregate(block, src, dest_ty, elems);
        },
        .special => if (dest_ty == .calling_convention_type and sc == .enum_literal) {
            return null;
        },
        else => {},
    }
    return null;
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
                if (sema.errorSetNames(src_ty)) |_| try sema.addInferredErrors(src_ty) else if (ip.indexToKey(src_ty) != .inferred_error_set_type) {
                    return sema.fail(block, src, "zap does not support coercing '{f}' into an inferred error set yet", .{sema.fmtType(src_ty)});
                }
            }
            return true;
        },
        else => {},
    }
    const dest_names = sema.errorSetNames(dest_ty).?;
    if (val != .none and ip.indexToKey(val) == .err) {
        const name = ip.indexToKey(val).err.name;
        for (dest_names) |n| if (n == name) return true;
        return false;
    }
    const src_names = sema.errorSetNames(src_ty) orelse return false;
    outer: for (src_names) |s| {
        for (dest_names) |d| if (d == s) continue :outer;
        return false;
    }
    return true;
}

/// Whether a pointer of type `src_ty` can be used as `dest_ty` without
/// changing its representation.
fn ptrCoercibleInPlace(sema: *Sema, src_ty: Index, dest_ty: Index) bool {
    const ip = sema.ip;
    const s = Type.ptrInfo(ip, src_ty);
    const d = Type.ptrInfo(ip, dest_ty);
    if (s.flags.is_const and !d.flags.is_const) return false;
    if (s.flags.is_volatile and !d.flags.is_volatile) return false;
    if (d.flags.alignment != 0 and d.flags.alignment != s.flags.alignment) return false;
    if (d.sentinel != .none and d.sentinel != s.sentinel) return false;
    if (s.flags.size == d.flags.size) {
        if (s.child == d.child) return true;
        if (d.child == .anyopaque_type and s.flags.size != .slice) return true;
        // `*[N]T` to `*const [N]T` children differ only by qualifiers above.
        return false;
    }
    // `*[N]T` to `[*]T`.
    if (s.flags.size == .one and d.flags.size == .many) {
        if (ip.indexToKey(s.child) == .array_type) {
            const a = ip.indexToKey(s.child).array_type;
            return a.child == d.child and (d.sentinel == .none or d.sentinel == a.sentinel);
        }
    }
    if ((s.flags.size == .one or s.flags.size == .many) and d.flags.size == .c) return s.child == d.child;
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
        if (s.flags.is_const and !d.flags.is_const) return null;
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
                if (s.flags.size == .one and d.flags.size != .one and ip.indexToKey(s.child) == .array_type) {
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
    if (ca == .comptime_int and cb == .int) return b;
    if (cb == .comptime_int and ca == .int) return a;
    if (ca == .int and cb == .int) {
        const ia = Type.intInfo(ip, a);
        const ib = Type.intInfo(ip, b);
        if (ia.signedness == ib.signedness) return if (ia.bits >= ib.bits) a else b;
        if (ia.signedness == .unsigned and ib.bits > ia.bits) return b;
        if (ib.signedness == .unsigned and ia.bits > ib.bits) return a;
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
    if (tag == .shl or tag == .shr) return sema.analyzeShift(block, src, tag, uncasted_lhs, uncasted_rhs);
    const ty = try sema.resolvePeerTypes(block, src, &.{ uncasted_lhs, uncasted_rhs });
    const is_bool = ty == .bool_type;
    const class = Type.class(ip, ty);
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
        .div, .div_trunc, .div_floor, .div_exact, .rem, .mod, .mod_rem => {
            if (safety) {
                const rv = sema.resolveValue(rhs);
                if (rv == null) {
                    const zero: Ref = .fromInterned(try sema.intValue(ty, 0));
                    const ok = try sema.addBinOp(block, .cmp_neq, rhs, zero);
                    try sema.addSafetyCheck(block, ok, .divide_by_zero, .none, .none);
                } else if (sema.intSign(rv.?) == 0) {
                    return sema.fail(block, src, "division by zero here causes illegal behavior", .{});
                }
                const is_div = tag == .div_trunc or tag == .div_floor or tag == .div_exact;
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
                .rem, .mod_rem => .rem,
                .mod => if (signed) .mod else .rem,
                else => unreachable,
            }, lhs, rhs);
        },
        else => unreachable,
    }
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
        .add, .addwrap, .add_unsafe => try r.add(&a, &b),
        .sub, .subwrap => try r.sub(&a, &b),
        .mul, .mulwrap => try r.mul(&a, &b),
        .bit_and => try r.bitAnd(&a, &b),
        .bit_or => try r.bitOr(&a, &b),
        .xor => try r.bitXor(&a, &b),
        .min => return if (a.order(b) == .gt) rv else lv,
        .max => return if (a.order(b) == .lt) rv else lv,
        .div, .div_trunc, .div_floor, .div_exact, .rem, .mod, .mod_rem => {
            if (b.eqlZero()) return sema.fail(block, src, "division by zero here causes illegal behavior", .{});
            var q = try BigInt.init(sema.arena);
            var rem = try BigInt.init(sema.arena);
            switch (tag) {
                .div_floor, .mod => try q.divFloor(&rem, &a, &b),
                else => try q.divTrunc(&rem, &a, &b),
            }
            switch (tag) {
                .div, .div_trunc, .div_floor => r = q,
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
        } else if (!r.fitsInTwosComp(info.signedness, info.bits)) {
            return sema.fail(block, src, "overflow of integer type '{f}' with value '{f}'", .{ sema.fmtType(ty), r.toConst() });
        }
    }
    return sema.bigToValue(ty, r.toConst());
}

fn analyzeShift(sema: *Sema, block: *Block, src: Src, tag: Zir.Inst.Tag, lhs: Ref, uncasted_rhs: Ref) CompileError!Ref {
    const ip = sema.ip;
    const ty = sema.typeOf(lhs);
    const class = Type.class(ip, ty);
    if (class != .int and class != .comptime_int) return sema.fail(block, src, "bit shifting operation expected integer type, found '{f}'", .{sema.fmtType(ty)});
    const rv = sema.resolveValue(uncasted_rhs);
    if (rv) |v| {
        if (sema.isUndef(v)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
        if (sema.intSign(v) < 0) return sema.fail(block, src, "shift by negative amount '{f}'", .{sema.fmtValue(v)});
        if (class == .int and (sema.ip.intValue(u64, v) orelse std.math.maxInt(u64)) >= Type.intInfo(ip, ty).bits)
            return sema.fail(block, src, "shift amount '{f}' is too large for operand type '{f}'", .{ sema.fmtValue(v), sema.fmtType(ty) });
    }
    if (sema.resolveValue(lhs)) |lv| if (rv) |v| {
        if (sema.isUndef(lv)) return sema.fail(block, src, "use of undefined value here causes illegal behavior", .{});
        const a = try sema.bigValue(lv);
        const amount: usize = @intCast(sema.ip.intValue(u64, v).?);
        var r = try BigInt.init(sema.arena);
        if (tag == .shl) try r.shiftLeft(&a, amount) else try r.shiftRight(&a, amount);
        if (class == .int) {
            const info = Type.intInfo(ip, ty);
            try r.truncate(&r, info.signedness, info.bits);
        }
        return .fromInterned(try sema.bigToValue(ty, r.toConst()));
    };
    if (class == .comptime_int) return sema.fail(block, src, "LHS of shift must be a fixed-width integer type, or RHS must be comptime-known", .{});
    try sema.requireRuntime(block, src);
    const shift_ty = try sema.intType(.unsigned, Type.log2IntBits(Type.intInfo(ip, ty).bits));
    const rhs = try sema.coerce(block, shift_ty, uncasted_rhs, src);
    return sema.addBinOp(block, if (tag == .shl) .shl else .shr, lhs, rhs);
}

fn analyzeBitNot(sema: *Sema, block: *Block, src: Src, operand: Ref) CompileError!Ref {
    const ty = sema.typeOf(operand);
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

fn analyzeCmp(sema: *Sema, block: *Block, src: Src, op: std.math.CompareOperator, lhs: Ref, rhs: Ref) CompileError!Ref {
    const ip = sema.ip;
    const lt = sema.typeOf(lhs);
    const rt = sema.typeOf(rhs);
    const lc = Type.class(ip, lt);
    const rc = Type.class(ip, rt);
    const is_eq = op == .eq or op == .neq;

    // Comparison with `null`.
    if (lc == .null or rc == .null) {
        if (!is_eq) return sema.fail(block, src, "operator {s} not allowed for type '{f}'", .{ @tagName(op), sema.fmtType(if (lc == .null) rt else lt) });
        const other = if (lc == .null) rhs else lhs;
        if (Type.class(ip, sema.typeOf(other)) == .null) return .fromInterned(boolValue(op == .eq));
        const non_null = try sema.analyzeIsNonNull(block, src, other);
        if (op == .neq) return non_null;
        if (sema.resolveValue(non_null)) |v| return .fromInterned(boolValue(v != .bool_true));
        return sema.addTyOp(block, .not, .bool_type, non_null);
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
        try sema.requireRuntime(block, src);
        const ty = try sema.resolvePeerTypes(block, src, &.{ lhs, rhs });
        return sema.addBinOp(block, if (op == .eq) .cmp_eq else .cmp_neq, try sema.coerce(block, ty, lhs, src), try sema.coerce(block, ty, rhs, src));
    }
    const l_int = lc == .int or lc == .comptime_int;
    const r_int = rc == .int or rc == .comptime_int;
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
    if (!Type.hasRuntimeBits(ip, info.child)) return;
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
    if (!Type.hasRuntimeBits(ip, info.child)) {
        if (info.child == .void_type) return .void_value;
        if (Type.isComptimeOnly(ip, info.child)) return sema.fail(block, src, "unable to load comptime-only type '{f}' at runtime", .{sema.fmtType(info.child)});
    }
    try sema.resolveLayout(block, src, info.child);
    return sema.addTyOp(block, .load, info.child, ptr);
}

fn analyzeRef(sema: *Sema, block: *Block, src: Src, operand: Ref) CompileError!Ref {
    const ty = sema.typeOf(operand);
    const ptr_ty = try sema.ptrType(.{ .child = ty, .flags = .{ .is_const = true } });
    if (sema.resolveValue(operand)) |v| {
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
            break :blk alloc.val;
        },
        .uav => |u| u.val,
        .nav => |n| blk: {
            try sema.ensureNavVal(block, src, n);
            const nav = ip.getNav(n);
            if (!nav.is_const) break :blk null;
            break :blk nav.val;
        },
        .int => null,
        .field => |f| blk: {
            const parent = (try sema.comptimeLoadOrNull(block, src, f.base)) orelse break :blk null;
            break :blk try sema.fieldValue(parent, @intCast(f.index));
        },
        .elem => |e| blk: {
            const parent = (try sema.comptimeLoadOrNull(block, src, e.base)) orelse break :blk null;
            const parent_ty = Type.ptrInfo(ip, ip.typeOf(e.base)).child;
            if (ip.indexToKey(parent_ty) != .array_type) break :blk null;
            const elem_ty = ip.indexToKey(parent_ty).array_type.child;
            const load_ty = Type.ptrInfo(ip, key.ty).child;
            if (load_ty != elem_ty and ip.indexToKey(load_ty) == .array_type and ip.indexToKey(load_ty).array_type.child == elem_ty) {
                // A subarray (from slicing with comptime-known bounds).
                const a = ip.indexToKey(load_ty).array_type;
                const elems = try sema.arena.alloc(Index, @intCast(a.lenIncludingSentinel()));
                for (elems, 0..) |*x, i| x.* = if (i == a.len) a.sentinel else try sema.elemValue(parent, e.index + i);
                break :blk try sema.intern(.{ .aggregate = .{ .ty = load_ty, .storage = .{ .elems = elems } } });
            }
            break :blk try sema.elemValue(parent, e.index);
        },
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
            alloc.val = val;
        },
        .field => |f| {
            const parent = try sema.comptimeLoad(block, src, f.base);
            try sema.comptimeStore(block, src, f.base, try sema.withElem(parent, f.index, val));
        },
        .elem => |e| {
            const parent = try sema.comptimeLoad(block, src, e.base);
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
fn elemValue(sema: *Sema, val: Index, index: u64) !Index {
    const ip = sema.ip;
    const ty = ip.typeOf(val);
    const elem_ty: Index = switch (ip.indexToKey(ty)) {
        .array_type => |a| if (a.sentinel != .none and index == a.len) return a.sentinel else a.child,
        .struct_type => ip.structInfo(ty).field_types[@intCast(index)],
        .tuple_type => |t| t.types[@intCast(index)],
        .opt_type => |c| c,
        .error_union_type => |e| e.payload_type,
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
        .tuple_type => |t| {
            const i = std.fmt.parseInt(u32, name, 10) catch return sema.fail(block, src, "no field named '{s}' in tuple '{f}'", .{ name, sema.fmtType(ty) });
            if (i >= t.types.len) return sema.fail(block, src, "index {d} outside tuple of length {d}", .{ i, t.types.len });
            return t.types[i];
        },
        else => return sema.fail(block, src, "type '{f}' does not support struct initialization syntax", .{sema.fmtType(ty)}),
    }
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
                .array => if (std.mem.eql(u8, name, "len")) return .fromInterned(try sema.intValue(.usize_type, ip.indexToKey(p.child).array_type.len)),
                .@"struct", .tuple => return sema.analyzeLoad(block, src, try sema.fieldPtr(block, src, lhs, name)),
                .pointer, .type => return sema.fieldVal(block, src, try sema.analyzeLoad(block, src, lhs), name),
                else => {},
            }
            return sema.fail(block, src, "no member named '{s}' in '{f}'", .{ name, sema.fmtType(p.child) });
        },
        .@"struct", .tuple => {
            const i = try sema.structFieldIndex(block, src, ty, name);
            if (ip.indexToKey(ty) == .tuple_type) return sema.tupleField(block, lhs, i);
            if (sema.resolveValue(lhs)) |v| return .fromInterned(try sema.fieldValue(v, i));
            try sema.requireRuntime(block, src);
            return sema.addStructField(block, .struct_field_val, Type.fieldType(ip, ty, i), lhs, i);
        },
        .array => if (std.mem.eql(u8, name, "len")) return .fromInterned(try sema.intValue(.usize_type, ip.indexToKey(ty).array_type.len)),
        else => {},
    }
    return sema.fail(block, src, "type '{f}' does not support field access", .{sema.fmtType(ty)});
}

fn namespaceLookupVal(sema: *Sema, block: *Block, src: Src, container: Index, name: []const u8) CompileError!Ref {
    const ip = sema.ip;
    if (Type.class(ip, container) == .error_set) {
        const n = try sema.getString(name);
        if (sema.errorSetNames(container)) |names| {
            for (names) |x| if (x == n) return .fromInterned(try sema.intern(.{ .err = .{ .ty = container, .name = n } }));
            return sema.fail(block, src, "no error named '{s}' in '{f}'", .{ name, sema.fmtType(container) });
        }
    }
    const nav = (try sema.lookupInType(container, name)) orelse
        return sema.fail(block, src, "'{f}' has no member named '{s}'", .{ sema.fmtType(container), name });
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
        else => {},
    }
    return sema.fail(block, src, "type '{f}' does not support field access", .{sema.fmtType(child)});
}

/// The many-pointer type of a slice's `ptr` field.
fn elemValueType(sema: *Sema, slice_ty: Index) !Index {
    const p = Type.ptrInfo(sema.ip, slice_ty);
    return sema.ptrType(.{ .child = p.child, .sentinel = p.sentinel, .flags = .{ .size = .many, .is_const = p.flags.is_const, .is_volatile = p.flags.is_volatile } });
}

fn fieldPtrAt(sema: *Sema, block: *Block, src: Src, ptr: Ref, field_ty: Index, i: u32) CompileError!Ref {
    const p = Type.ptrInfo(sema.ip, sema.typeOf(ptr));
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
            if (safety or sema.resolveValue(index) != null) try sema.boundsCheck(block, src, index, len, a.sentinel != .none and sema.resolveValue(index) != null);
            return sema.elemPtrOfArrayPtr(block, src, ptr, index);
        },
        .ptr_type => |cp| switch (cp.flags.size) {
            .one => return sema.elemPtr(block, src, try sema.analyzeLoad(block, src, ptr), uncasted_index, safety),
            .many, .c => {
                const index = try sema.coerce(block, .usize_type, uncasted_index, src);
                return sema.elemPtrOfManyPtr(block, src, try sema.analyzeLoad(block, src, ptr), index);
            },
            .slice => {
                const index = try sema.coerce(block, .usize_type, uncasted_index, src);
                const slice = try sema.analyzeLoad(block, src, ptr);
                if (safety) try sema.boundsCheck(block, src, index, try sema.sliceLen(block, slice), false);
                if (sema.resolveValue(slice)) |sv| if (sema.resolveValue(index)) |iv| {
                    return .fromInterned(try sema.ptrElemPtrVal(sema.ip.indexToKey(sv).slice.ptr, sema.ip.intValue(u64, iv).?));
                };
                try sema.requireRuntime(block, src);
                const elem_ptr_ty = try sema.ptrType(.{ .child = cp.child, .flags = .{ .is_const = cp.flags.is_const, .is_volatile = cp.flags.is_volatile } });
                return sema.addTyPlBin(block, .slice_elem_ptr, elem_ptr_ty, slice, index);
            },
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
        if (sema.ip.indexToKey(pv) == .ptr) return .fromInterned(try sema.ptrElemPtrVal(pv, sema.ip.intValue(u64, iv).?));
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
                if (safety) try sema.boundsCheck(block, src, index, try sema.sliceLen(block, lhs), false);
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
                    if (safety) try sema.boundsCheck(block, src, index, .fromInterned(try sema.intValue(.usize_type, a.len)), false);
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
            if (e.sentinel != .none) return sema.failUnsupported(block, src, "slice sentinels");
            lhs_ref = e.lhs;
            start_ref = e.start;
            len_ref = e.len;
        },
        .slice_sentinel => return sema.failUnsupported(block, src, "slice sentinels"),
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
    var elem_ty: Index = undefined;
    switch (ip.indexToKey(child)) {
        .array_type => |a| {
            elem_ty = a.child;
            len = .fromInterned(try sema.intValue(.usize_type, a.len));
            base = try sema.coercePtrTo(block, ptr, try sema.ptrType(.{ .child = a.child, .flags = .{ .size = .many, .is_const = is_const } }));
        },
        .ptr_type => |cp| {
            const obj = try sema.analyzeLoad(block, src, ptr);
            is_const = cp.flags.is_const;
            switch (cp.flags.size) {
                .one => {
                    const a = ip.indexToKey(cp.child).array_type;
                    elem_ty = a.child;
                    len = .fromInterned(try sema.intValue(.usize_type, a.len));
                    base = try sema.coercePtrTo(block, obj, try sema.ptrType(.{ .child = a.child, .flags = .{ .size = .many, .is_const = is_const } }));
                },
                .slice => {
                    elem_ty = cp.child;
                    len = try sema.sliceLen(block, obj);
                    base = try sema.slicePtr(block, obj);
                    if (cp.sentinel != .none) base = try sema.coercePtrTo(block, base, try sema.ptrType(.{ .child = elem_ty, .flags = .{ .size = .many, .is_const = is_const } }));
                },
                .many, .c => {
                    elem_ty = cp.child;
                    base = obj;
                },
            }
        },
        else => return sema.fail(block, src, "slice of non-array type '{f}'", .{sema.fmtType(child)}),
    }
    const start = try sema.coerce(block, .usize_type, sema.resolveInst(start_ref), src);
    var end: Ref = undefined;
    if (len_ref != .none) {
        const n = try sema.coerce(block, .usize_type, sema.resolveInst(len_ref), src);
        end = try sema.analyzeArithmetic(block, src, .add, start, n);
    } else if (end_ref != .none) {
        end = try sema.coerce(block, .usize_type, sema.resolveInst(end_ref), src);
    } else {
        if (len == .none) return sema.fail(block, src, "slice of pointer must include end value", .{});
        end = len;
    }
    if (len != .none) try sema.boundsCheck(block, src, end, len, true);
    const start_val = sema.resolveValue(start);
    const end_val = sema.resolveValue(end);
    if (start_val != null and end_val != null) {
        const sv = ip.intValue(u64, start_val.?).?;
        const ev = ip.intValue(u64, end_val.?).?;
        if (sv > ev) return sema.fail(block, src, "start index {d} is larger than end index {d}", .{ sv, ev });
    } else if (block.want_safety and !block.is_comptime) {
        const ok = try sema.addBinOp(block, .cmp_lte, start, end);
        try sema.addSafetyCheck(block, ok, .start_greater_than_end, start, end);
    }

    const many_ty = sema.typeOf(base);
    const base_val = sema.resolveValue(base);
    const new_ptr: Ref = if (start_val != null and ip.intValue(u64, start_val.?).? == 0)
        base
    else if (base_val != null and start_val != null)
        try sema.coercePtrToMany(try sema.ptrElemPtrVal(base_val.?, ip.intValue(u64, start_val.?).?), many_ty)
    else
        try sema.addTyPlBin(block, .ptr_add, many_ty, base, start);

    if (sema.resolveValue(start)) |sv| if (sema.resolveValue(end)) |ev| {
        // Comptime-known bounds give a pointer to an array.
        const n = ip.intValue(u64, ev).? - ip.intValue(u64, sv).?;
        const array_ty = try sema.intern(.{ .array_type = .{ .len = n, .child = elem_ty } });
        const result_ty = try sema.ptrType(.{ .child = array_ty, .flags = .{ .is_const = is_const } });
        if (sema.resolveValue(new_ptr)) |pv| {
            const k = ip.indexToKey(pv).ptr;
            switch (k.base) {
                .elem => |e| {
                    if (try sema.isArrayPtrOfLen(e.base, elem_ty, n) and e.index == 0) return .fromInterned(e.base);
                    // A pointer to the subarray starting at element `e.index`.
                    return .fromInterned(try sema.intern(.{ .ptr = .{ .ty = result_ty, .base = k.base } }));
                },
                else => {},
            }
            return sema.failUnsupported(block, src, "comptime slicing of this pointer");
        }
        return sema.addTyOp(block, .bitcast, result_ty, new_ptr);
    };
    const slice_ty = try sema.ptrType(.{ .child = elem_ty, .flags = .{ .size = .slice, .is_const = is_const } });
    const new_len = try sema.analyzeArithmetic(block, src, .subwrap, end, start);
    return sema.makeSlice(block, slice_ty, new_ptr, new_len);
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
    if (parent.is_comptime) {
        // Comptime breaks to `inst` were caught by `analyzeInlineBody`.
        return if (label.merges.results.items.len != 0) label.merges.results.items[0] else .unreachable_value;
    }
    return sema.resolveBlock(parent, src, &outer, &label.merges);
}

fn analyzeSwitch(sema: *Sema, parent: *Block, src: Src, inst: Zir.Inst.Index, operand: Ref) CompileError!Ref {
    const ip = sema.ip;
    const gpa = sema.gpa;
    const sb = sema.code.getSwitchBlock(inst);
    if (sb.has_continue) return sema.failUnsupported(parent, src, "labeled switch continue");
    if (sb.tag_capture_placeholder != .none) return sema.failUnsupported(parent, src, "switch tag captures");
    const operand_ty = sema.typeOf(operand);
    switch (Type.class(ip, operand_ty)) {
        .int, .comptime_int, .bool, .error_set, .enum_literal, .type => {},
        else => return sema.fail(parent, src, "zap does not support switching on '{f}' yet", .{sema.fmtType(operand_ty)}),
    }
    const capture_inst: Zir.Inst.Index = sb.payload_capture_placeholder.unwrap() orelse inst;

    // Evaluate the case items at comptime.
    var cases: std.ArrayList(SwitchCase) = .empty;
    var item_block = parent.child();
    defer item_block.instructions.deinit(gpa);
    item_block.is_comptime = true;
    var extra_index = sb.end;
    var it = sb.iterateCases();
    while (it.next()) |case| {
        if (case.prong_info.is_inline) return sema.failUnsupported(parent, src, "inline switch prongs");
        const body = sema.code.bodySlice(extra_index, case.prong_info.body_len);
        extra_index += body.len;
        const items = try sema.arena.alloc(Index, case.item_infos.len);
        for (case.item_infos, items) |info, *item| item.* = try sema.switchItem(&item_block, src, inst, info, operand_ty, &extra_index);
        const ranges = try sema.arena.alloc([2]Index, case.range_infos.len);
        for (case.range_infos, ranges) |pair, *range| {
            range[0] = try sema.switchItem(&item_block, src, inst, pair[0], operand_ty, &extra_index);
            range[1] = try sema.switchItem(&item_block, src, inst, pair[1], operand_ty, &extra_index);
        }
        try cases.append(sema.arena, .{ .items = items, .ranges = ranges, .body = body, .capture = case.prong_info.capture });
    }
    if (sb.has_under) return sema.failUnsupported(parent, src, "'_' switch prongs");
    const else_case: ?SwitchCase = if (sb.else_case) |e| .{ .items = &.{}, .ranges = &.{}, .body = e.body, .capture = e.capture } else null;
    if (else_case == null and Type.class(ip, operand_ty) == .bool) {
        var seen_true = false;
        var seen_false = false;
        for (cases.items) |c| for (c.items) |v| {
            if (v == .bool_true) seen_true = true else seen_false = true;
        };
        if (!seen_true or !seen_false) return sema.fail(parent, src, "switch must handle all possibilities", .{});
    } else if (else_case == null and Type.class(ip, operand_ty) != .error_set) {
        if (!try sema.switchCoversAllInts(cases.items, operand_ty)) return sema.fail(parent, src, "switch must handle all possibilities", .{});
    }

    // Comptime-known operand: analyze only the matching prong.
    if (sema.resolveValue(operand)) |v| {
        const chosen = for (cases.items) |c| {
            if (try sema.switchCaseMatches(c, v)) break c;
        } else else_case orelse return sema.fail(parent, src, "switch must handle all possibilities", .{});
        try sema.inst_map.put(gpa, capture_inst, operand);
        if (parent.is_comptime) return sema.resolveInlineBody(parent, chosen.body, inst);
        return sema.switchProngsRuntime(parent, src, inst, operand, &.{chosen}, null, capture_inst);
    }
    try sema.requireRuntime(parent, src);
    return sema.switchProngsRuntime(parent, src, inst, operand, cases.items, else_case, capture_inst);
}

fn switchItem(sema: *Sema, block: *Block, src: Src, switch_inst: Zir.Inst.Index, info: Zir.Inst.SwitchBlock.ItemInfo, operand_ty: Index, extra_index: *usize) CompileError!Index {
    const ref: Ref = switch (info.unwrap()) {
        .body_len => |len| blk: {
            const body = sema.code.bodySlice(extra_index.*, len);
            extra_index.* += len;
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

    if (cases.len == 1 and else_case == null and sema.resolveValue(operand) != null) {
        // A comptime-known operand selected this prong.
        try sema.analyzeProng(&outer, cases[0], operand, capture_inst, inst);
    } else {
        var any_ranges = false;
        for (cases) |c| any_ranges = any_ranges or c.ranges.len != 0;
        if (any_ranges) {
            try sema.switchAsCondBrs(&outer, src, cases, else_case, operand, capture_inst, inst);
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
            _ = try sema.addInst(&outer, .{ .tag = .switch_br, .data = .{ .pl_op = .{ .operand = operand, .payload = payload } } });
        }
    }
    return sema.resolveBlock(parent, src, &outer, &label.merges);
}

fn analyzeProng(sema: *Sema, block: *Block, c: SwitchCase, operand: Ref, capture_inst: Zir.Inst.Index, switch_inst: Zir.Inst.Index) CompileError!void {
    if (c.capture == .by_ref) return sema.failUnsupported(block, block.nodeSrc(.zero), "switch captures by reference");
    try sema.inst_map.put(sema.gpa, capture_inst, operand);
    if (try sema.analyzeInlineBody(block, c.body, switch_inst)) |result| {
        // A prong ended with a comptime break to the switch.
        try sema.addBr(block, block.label.?, result);
    }
}

fn switchAsCondBrs(sema: *Sema, block: *Block, src: Src, cases: []const SwitchCase, else_case: ?SwitchCase, operand: Ref, capture_inst: Zir.Inst.Index, switch_inst: Zir.Inst.Index) CompileError!void {
    if (cases.len == 0) {
        if (else_case) |e| return sema.analyzeProng(block, e, operand, capture_inst, switch_inst);
        if (block.want_safety) return sema.addPanic(block, .corrupt_switch, .none, .none);
        _ = try sema.addInst(block, .{ .tag = .unreach, .data = .{ .no_op = {} } });
        return;
    }
    const c = cases[0];
    var cond: Ref = .fromInterned(.bool_false);
    for (c.items) |item| {
        const eq = try sema.addBinOp(block, .cmp_eq, operand, .fromInterned(item));
        cond = if (cond.toInterned() == .bool_false) eq else try sema.addBinOp(block, .bit_or, cond, eq);
    }
    for (c.ranges) |r| {
        const ge = try sema.addBinOp(block, .cmp_gte, operand, .fromInterned(r[0]));
        const le = try sema.addBinOp(block, .cmp_lte, operand, .fromInterned(r[1]));
        const in = try sema.addBinOp(block, .bit_and, ge, le);
        cond = if (cond.toInterned() == .bool_false) in else try sema.addBinOp(block, .bit_or, cond, in);
    }
    var then_block = block.child();
    defer then_block.instructions.deinit(sema.gpa);
    try sema.analyzeProng(&then_block, c, operand, capture_inst, switch_inst);
    var else_block = block.child();
    defer else_block.instructions.deinit(sema.gpa);
    try sema.switchAsCondBrs(&else_block, src, cases[1..], else_case, operand, capture_inst, switch_inst);
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
    const payload = try sema.addExtra(Ir.Aggregate{ .len = @intCast(elems.len) });
    try sema.ir_extra.appendSlice(sema.gpa, @ptrCast(elems));
    return sema.addInst(block, .{ .tag = .aggregate_init, .data = .{ .ty_pl = .{ .ty = ty, .payload = payload } } });
}

fn structInitEmpty(sema: *Sema, block: *Block, src: Src, ty: Index) CompileError!Ref {
    const ip = sema.ip;
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
    if (ty == .generic_poison_type) return sema.failUnsupported(block, src, "anonymous struct literals without a result type");
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
    if (tag == .array_init_anon) {
        const types = try sema.arena.alloc(Index, args.len);
        const values = try sema.arena.alloc(Index, args.len);
        const elems = try sema.arena.alloc(Ref, args.len);
        for (args, types, values, elems) |a, *t, *v, *e| {
            e.* = sema.resolveInst(a);
            t.* = sema.typeOf(e.*);
            v.* = sema.resolveValue(e.*) orelse .none;
        }
        const ty = try sema.intern(.{ .tuple_type = .{ .types = types, .values = values } });
        return sema.aggregate(block, src, ty, elems);
    }
    var ty = try sema.resolveType(block, src, args[0]);
    if (ty == .generic_poison_type) return sema.failUnsupported(block, src, "array literals without a result type");
    const inits = args[1..];
    switch (ip.indexToKey(ty)) {
        .array_type => |a| {
            if (a.len != inits.len) return sema.fail(block, src, "expected {d} array elements; found {d}", .{ a.len, inits.len });
            const elems = try sema.arena.alloc(Ref, a.lenIncludingSentinel());
            for (inits, 0..) |e, k| elems[k] = try sema.coerce(block, a.child, sema.resolveInst(e), src);
            if (a.sentinel != .none) elems[a.len] = .fromInterned(a.sentinel);
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
    const ip = sema.ip;
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Bin, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    const dest_ty = try sema.resolveType(block, src, extra.lhs);
    const operand = sema.resolveInst(extra.rhs);
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
    const ip = sema.ip;
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Bin, data.payload_index).data;
    const src = block.nodeSrc(data.src_node);
    const dest_ty = try sema.resolveType(block, src, extra.lhs);
    const operand = sema.resolveInst(extra.rhs);
    const src_ty = sema.typeOf(operand);
    if (!Type.isInt(ip, dest_ty)) return sema.fail(block, src, "expected integer type, found '{f}'", .{sema.fmtType(dest_ty)});
    const d = Type.intInfo(ip, dest_ty);
    if (sema.resolveValue(operand)) |v| {
        if (sema.isUndef(v)) return .fromInterned(try sema.undefValue(dest_ty));
        var big = try sema.bigValue(v);
        try big.truncate(&big, d.signedness, d.bits);
        return .fromInterned(try sema.bigToValue(dest_ty, big.toConst()));
    }
    try sema.requireRuntime(block, src);
    const s = Type.intInfo(ip, src_ty);
    if (s.bits < d.bits) return sema.fail(block, src, "destination type '{f}' has more bits than source type '{f}'", .{ sema.fmtType(dest_ty), sema.fmtType(src_ty) });
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
    return sema.failUnsupported(block, src, "@bitCast between these types");
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
    if ((d.flags.size == .slice) != (s.flags.size == .slice)) return sema.failUnsupported(block, src, "pointer casts between slices and other pointers");
    if (d.flags.size == .slice and Type.abiSize(sema.ip, d.child) != Type.abiSize(sema.ip, s.child)) return sema.failUnsupported(block, src, "slice casts that change the element size");
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
        .source = try sema.getString(sema.zirString(extra.data.asm_source)),
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
    const params = block.params orelse return sema.fail(block, block.nodeSrc(.zero), "parameter outside of a function prototype", .{});
    switch (tag) {
        .param, .param_comptime => {
            const extra = sema.code.extraData(Zir.Inst.Param, data.pl_tok.payload_index);
            const body = sema.code.bodySlice(extra.end, extra.data.type.body_len);
            const src = block.tokSrc(data.pl_tok.src_tok);
            const ty: Index = if (extra.data.type.is_generic) .generic_poison_type else blk: {
                const ref = try sema.resolveInlineBody(block, body, inst);
                break :blk try sema.analyzeAsType(block, src, ref);
            };
            try params.append(sema.arena, .{ .ty = ty, .is_comptime = tag == .param_comptime, .name = extra.data.name });
        },
        .param_anytype, .param_anytype_comptime => {
            try params.append(sema.arena, .{ .ty = .generic_poison_type, .is_comptime = tag == .param_anytype_comptime, .name = data.str_tok.start });
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
    const params: []const Block.Param = if (block.params) |p| p.items else &.{};
    defer if (block.params) |p| p.clearRetainingCapacity();

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
    if (cc == .@"inline") cc = .auto; // Called like any other function for now.

    var ret_ty: Index = if (fn_info.ret_ty_body.len != 0) blk: {
        if (fn_info.ret_ty_is_generic) break :blk .generic_poison_type;
        const ref = try sema.resolveInlineBody(block, fn_info.ret_ty_body, inst);
        break :blk try sema.analyzeAsType(block, src, ref);
    } else try sema.resolveType(block, src, fn_info.ret_ty_ref);
    if (fn_info.inferred_error_set) {
        ret_ty = try sema.intern(.{ .error_union_type = .{ .error_set_type = .adhoc_inferred_error_set_type, .payload_type = ret_ty } });
    }

    var is_generic = ret_ty == .generic_poison_type;
    var comptime_bits: u32 = 0;
    const param_types = try sema.arena.alloc(Index, params.len);
    for (params, param_types, 0..) |p, *t, k| {
        t.* = p.ty;
        if (p.is_comptime) comptime_bits |= @as(u32, 1) << @intCast(k);
        if (p.is_comptime or p.ty == .generic_poison_type) is_generic = true;
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
};

fn zirCall(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const src = block.nodeSrc(data.src_node);
    const extra = sema.code.extraData(Zir.Inst.Call, data.payload_index);
    const callee = sema.resolveInst(extra.data.callee);
    const modifier: std.lang.CallModifier = @enumFromInt(extra.data.flags.packed_modifier);
    return sema.analyzeCall(block, src, callee, .none, .{ .call_inst = inst, .extra_end = extra.end, .args_len = extra.data.flags.args_len }, modifier);
}

fn zirFieldCall(sema: *Sema, block: *Block, inst: Zir.Inst.Index) CompileError!Ref {
    const ip = sema.ip;
    const data = sema.code.instructions.items(.data)[@backingInt(inst)].pl_node;
    const src = block.nodeSrc(data.src_node);
    const extra = sema.code.extraData(Zir.Inst.FieldCall, data.payload_index);
    const name = sema.zirString(extra.data.field_name_start);
    const obj = sema.resolveInst(extra.data.obj_ptr);
    const modifier: std.lang.CallModifier = @enumFromInt(extra.data.flags.packed_modifier);
    const args: @FieldType(CallArgs, "zir") = .{ .call_inst = inst, .extra_end = extra.end, .args_len = extra.data.flags.args_len };
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
    zir_args: @FieldType(CallArgs, "zir"),
    modifier: std.lang.CallModifier,
) CompileError!Ref {
    const ip = sema.ip;
    const callee_val = sema.resolveValue(callee) orelse return sema.failUnsupported(block, src, "calls through function pointers");
    const func = switch (ip.indexToKey(callee_val)) {
        .func => callee_val,
        else => return sema.fail(block, src, "type '{f}' not a function", .{sema.fmtType(ip.typeOf(callee_val))}),
    };
    const fn_ty = ip.indexToKey(ip.typeOf(func)).func_type;
    const total_args = zir_args.args_len + @intFromBool(first_arg != .none);
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
    var arg_start: u32 = zir_args.args_len;
    for (0..zir_args.args_len) |k| {
        const arg_end = sema.code.extra[zir_args.extra_end + k];
        const body = sema.code.bodySlice(zir_args.extra_end + arg_start, arg_end - arg_start);
        arg_start = arg_end;
        const param_ty = fn_ty.param_types[arg_i];
        try sema.inst_map.put(sema.gpa, zir_args.call_inst, .fromInterned(param_ty));
        const arg = try sema.resolveInlineBody(block, body, zir_args.call_inst);
        args[arg_i] = if (param_ty == .generic_poison_type) arg else try sema.coerce(block, param_ty, arg, src);
        arg_i += 1;
    }

    const ret_ty = fn_ty.return_type;
    const comptime_call = block.is_comptime or modifier == .compile_time or
        (ret_ty != .generic_poison_type and Type.isComptimeOnly(ip, ret_ty));
    if (comptime_call) {
        const vals = try sema.arena.alloc(Index, args.len);
        for (args, vals) |a, *v| v.* = try sema.resolveConstValue(block, src, a, "argument to function being called at comptime must be comptime-known");
        return .fromInterned(try sema.callComptime(block, src, func, vals));
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
            return .fromInterned(try sema.callComptime(block, src, func, vals));
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
    const payload = try sema.addExtra(Ir.Call{ .args_len = @intCast(call_args.len) });
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

fn calleeRetTy(sema: *Sema, callee_block: *Block, src: Src, func: Index) CompileError!Index {
    const ip = sema.ip;
    const f = ip.indexToKey(func).func;
    const ret = ip.indexToKey(f.ty).func_type.return_type;
    if (ret != .generic_poison_type) return ret;
    const fn_info = sema.code.getFnInfo(f.zir_inst);
    var ty = try sema.analyzeAsType(callee_block, src, try sema.resolveInlineBody(callee_block, fn_info.ret_ty_body, f.zir_inst));
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
        if ((generic_ty.comptime_bits >> @intCast(k)) & 1 != 0) {
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
