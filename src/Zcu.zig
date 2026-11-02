//! Semantic analysis state for one compilation: analysis units, their
//! dependencies, namespaces, and diagnostics. Drives Sema over the units
//! reachable from the root file.
//!
//! The skeleton analyzes on one thread. Units resolve on demand through the
//! `ensure*` functions, which are also where a unit's state lives; that state
//! is the synchronization point once function bodies run in parallel.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Ast = std.zig.Ast;
const Zir = std.zig.Zir;

const Frontend = @import("Frontend.zig");
const InternPool = @import("InternPool.zig");
const Ir = @import("Ir.zig");
const Sema = @import("Sema.zig");

const Zcu = @This();

gpa: Allocator,
io: Io,
fe: *const Frontend,
ip: InternPool,
/// Root struct type of each file, `.none` until imported.
file_root_types: std.ArrayList(InternPool.Index) = .empty,
namespaces: std.ArrayList(Namespace) = .empty,
/// Dependencies recorded per unit by `Sema.declareDependency`. Nothing
/// persists them yet; the on-disk cache (milestone 6) will.
deps: std.AutoArrayHashMapUnmanaged(AnalUnit, []const Dependee) = .empty,
/// Analysis state of runtime function bodies.
funcs: std.AutoArrayHashMapUnmanaged(InternPool.Index, FuncState) = .empty,
func_queue: std.ArrayList(InternPool.Index) = .empty,
/// `comptime` declarations, analyzed once each.
comptime_decls: std.AutoArrayHashMapUnmanaged(ComptimeDecl, enum { queued, done }) = .empty,
/// Memoized comptime calls, keyed by `Sema.comptimeCallKey`.
comptime_memo: std.AutoHashMapUnmanaged(InternPool.Hash, InternPool.Index) = .empty,
/// Errors each function instance returns, for inferred error sets.
inferred_errors: std.AutoHashMapUnmanaged(InternPool.Index, std.ArrayList(InternPool.String)) = .empty,
exports: std.ArrayList(Export) = .empty,
errors: std.ArrayList(ErrorMsg) = .empty,
/// Owns diagnostic text and namespace tables.
arena: std.heap.ArenaAllocator,

pub const Export = struct {
    nav: InternPool.NavIndex,
    name: InternPool.String,
};

pub const FuncState = enum { queued, in_progress, done, failed };

pub const ComptimeDecl = struct {
    file: u32,
    inst: Zir.Inst.Index,
    namespace: u32,
};

/// Sema's unit of work, caching, and parallelism.
pub const AnalUnit = union(enum) {
    nav_val: InternPool.NavIndex,
    type_layout: InternPool.Index,
    func: InternPool.Index,
    comptime_decl: struct { file: u32, inst: Zir.Inst.Index },
};

/// What a unit read from another unit. Recorded only through
/// `Sema.declareDependency`.
pub const Dependee = union(enum) {
    /// The value of a declaration (for a function: its signature, since the
    /// function value does not depend on its body).
    nav_val: InternPool.NavIndex,
    /// The type of a declaration.
    nav_ty: InternPool.NavIndex,
    /// The fields and layout of a struct type.
    type_layout: InternPool.Index,
    /// The body of a function, read by comptime calls.
    func_body: InternPool.Index,
    /// The resolved inferred error set of a function instance.
    func_ies: InternPool.Index,
    /// Whether namespace `namespace` has a declaration named `name`. Recorded
    /// by name lookups and `@hasDecl`, so adding an unrelated declaration
    /// does not invalidate the unit.
    namespace_name: struct { namespace: u32, name: InternPool.String },
};

pub const Namespace = struct {
    file: u32,
    /// Lexically enclosing namespace, or `none`.
    parent: u32,
    owner_type: InternPool.Index,
    /// Fully qualified name prefix of declarations in this namespace.
    fqn: []const u8,
    decls: std.AutoArrayHashMapUnmanaged(InternPool.String, InternPool.NavIndex) = .empty,

    pub const none = std.math.maxInt(u32);
};

pub const ErrorMsg = struct {
    file: u32,
    span: Ast.Span,
    msg: []const u8,
};

pub fn init(gpa: Allocator, io: Io, fe: *const Frontend) !Zcu {
    var zcu: Zcu = .{
        .gpa = gpa,
        .io = io,
        .fe = fe,
        .ip = try .init(gpa, io, 1),
        .arena = .init(gpa),
    };
    errdefer zcu.deinit();
    try zcu.file_root_types.appendNTimes(gpa, .none, fe.files.items.len);
    return zcu;
}

pub fn deinit(zcu: *Zcu) void {
    const gpa = zcu.gpa;
    for (zcu.namespaces.items) |*ns| ns.decls.deinit(gpa);
    zcu.namespaces.deinit(gpa);
    for (zcu.deps.values()) |d| gpa.free(d);
    zcu.deps.deinit(gpa);
    zcu.funcs.deinit(gpa);
    zcu.func_queue.deinit(gpa);
    zcu.comptime_decls.deinit(gpa);
    zcu.comptime_memo.deinit(gpa);
    var it = zcu.inferred_errors.valueIterator();
    while (it.next()) |list| list.deinit(gpa);
    zcu.inferred_errors.deinit(gpa);
    zcu.exports.deinit(gpa);
    zcu.errors.deinit(gpa);
    zcu.file_root_types.deinit(gpa);
    zcu.ip.deinit();
    zcu.arena.deinit();
}

pub const tid: InternPool.Tid = .main;

pub fn file(zcu: *const Zcu, index: u32) *const Frontend.File {
    return zcu.fe.file(@fromBackingInt(index));
}

/// The stable unit-key prefix of a file: module name and path within it.
pub fn fileFqn(zcu: *Zcu, index: u32) ![]const u8 {
    const f = zcu.file(index);
    const mod = zcu.fe.module(f.module);
    return std.fmt.allocPrint(zcu.arena.allocator(), "{s}:{s}", .{ mod.name, f.sub_path });
}

// ---------------------------------------------------------------------------
// Diagnostics

pub fn addError(zcu: *Zcu, file_index: u32, span: Ast.Span, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(zcu.arena.allocator(), fmt, args);
    try zcu.errors.append(zcu.gpa, .{ .file = file_index, .span = span, .msg = msg });
}

pub fn renderErrors(zcu: *const Zcu, wip: *std.zig.ErrorBundle.Wip) !void {
    for (zcu.errors.items) |e| {
        const f = zcu.file(e.file);
        const loc = std.zig.findLineColumn(f.source, e.span.main);
        try wip.addRootErrorMessage(.{
            .msg = try wip.addString(e.msg),
            .src_loc = try wip.addSourceLocation(.{
                .src_path = try wip.addString(f.display_path),
                .span_start = e.span.start,
                .span_main = e.span.main,
                .span_end = e.span.end,
                .line = @intCast(loc.line),
                .column = @intCast(loc.column),
                .source_line = try wip.addString(loc.source_line),
            }),
        });
    }
}

// ---------------------------------------------------------------------------
// Files and namespaces

/// The root struct type of a file, creating it (and its namespace) on first use.
pub fn fileRootType(zcu: *Zcu, file_index: u32) !InternPool.Index {
    if (zcu.file_root_types.items[file_index] != .none) return zcu.file_root_types.items[file_index];
    const fqn = try zcu.fileFqn(file_index);
    const ty = try zcu.createStructType(file_index, .main_struct_inst, &.{}, fqn, Namespace.none);
    zcu.file_root_types.items[file_index] = ty;
    return ty;
}

/// Interns a declared struct type. If it is new, creates its namespace and
/// declarations and queues its `comptime` and exported declarations.
pub fn createStructType(
    zcu: *Zcu,
    file_index: u32,
    inst: Zir.Inst.Index,
    captures: []const InternPool.Index,
    fqn: []const u8,
    parent_ns: u32,
) !InternPool.Index {
    const ip = &zcu.ip;
    const zir = &zcu.file(file_index).zir;
    const decl = zir.getStructDecl(inst);
    const name = try ip.getString(tid, fqn);
    // Look up first so an existing type keeps its namespace.
    const info = try ip.createStructInfo(tid, .{ .namespace = Namespace.none, .layout = decl.layout });
    const ty = try ip.get(tid, .{ .struct_type = .{
        .file = file_index,
        .zir_inst = inst,
        .captures = captures,
        .name = name,
        .info = info,
    } });
    const si = ip.structInfo(ty);
    if (si.namespace != Namespace.none) return ty;

    const ns_index: u32 = @intCast(zcu.namespaces.items.len);
    si.namespace = ns_index;
    try zcu.namespaces.append(zcu.gpa, .{
        .file = file_index,
        .parent = parent_ns,
        .owner_type = ty,
        .fqn = fqn,
    });
    for (decl.decls) |decl_inst| {
        const d = zir.getDeclaration(decl_inst);
        switch (d.kind) {
            .@"comptime" => try zcu.comptime_decls.put(zcu.gpa, .{ .file = file_index, .inst = decl_inst, .namespace = ns_index }, .queued),
            .unnamed_test, .@"test", .decltest => {},
            .@"const", .@"var" => {
                const simple = zir.nullTerminatedString(d.name);
                const decl_fqn = try std.fmt.allocPrint(zcu.arena.allocator(), "{s}{s}{s}", .{
                    fqn, if (parent_ns == Namespace.none) ":" else ".", simple,
                });
                const fqn_str = try ip.getString(tid, decl_fqn);
                var hasher: InternPool.Hasher = .init("nav");
                hasher.bytes(decl_fqn);
                const nav = try ip.createNav(tid, .{
                    .name = try ip.getString(tid, simple),
                    .fqn = fqn_str,
                    .file = file_index,
                    .zir_inst = decl_inst,
                    .namespace = ns_index,
                    .hash = hasher.final(),
                    .is_pub = d.is_pub,
                    .linkage = d.linkage,
                    .is_const = d.kind == .@"const",
                });
                try zcu.namespaces.items[ns_index].decls.put(zcu.gpa, ip.getNav(nav).name, nav);
                if (d.linkage == .@"export") try zcu.exports.append(zcu.gpa, .{ .nav = nav, .name = ip.getNav(nav).name });
            },
        }
    }
    return ty;
}

pub fn namespacePtr(zcu: *Zcu, index: u32) *Namespace {
    return &zcu.namespaces.items[index];
}

// ---------------------------------------------------------------------------
// Units

pub fn recordDeps(zcu: *Zcu, unit: AnalUnit, deps: []const Dependee) !void {
    const gop = try zcu.deps.getOrPut(zcu.gpa, unit);
    if (gop.found_existing) zcu.gpa.free(gop.value_ptr.*);
    gop.value_ptr.* = try zcu.gpa.dupe(Dependee, deps);
}

/// Renders a unit's stable key, which does not depend on analysis order or
/// in-memory indices.
pub fn unitKey(zcu: *Zcu, unit: AnalUnit, w: *std.Io.Writer) !void {
    const ip = &zcu.ip;
    switch (unit) {
        .nav_val => |nav| try w.writeAll(ip.stringSlice(ip.getNav(nav).fqn)),
        .type_layout => |ty| try w.print("{s}@layout", .{ip.stringSlice(ip.indexToKey(ty).struct_type.name)}),
        .func => |func| {
            const f = ip.indexToKey(func).func;
            try w.writeAll(ip.stringSlice(ip.getNav(f.owner_nav).fqn));
            if (f.generic_owner != .none) try w.print("__{x}", .{@as(u64, @truncate(ip.stableHash(func)))});
        },
        .comptime_decl => |c| {
            // The ordinal among the namespace's comptime declarations.
            const zir = &zcu.file(c.file).zir;
            const d = zir.getDeclaration(c.inst);
            try w.print("{s}:comptime@{d}", .{ try zcu.fileFqn(c.file), d.src_line });
        },
    }
}

/// Resolves the value of a declaration (its `nav_val` unit).
pub fn ensureNavVal(zcu: *Zcu, nav_index: InternPool.NavIndex) Sema.CompileError!void {
    const nav = zcu.ip.getNav(nav_index);
    switch (nav.status) {
        .resolved => return,
        .failed => return error.AnalysisFail,
        .resolving => return error.DependencyLoop,
        .unresolved => {},
    }
    nav.status = .resolving;
    Sema.analyzeNavVal(zcu, nav_index) catch |err| {
        nav.status = .failed;
        return err;
    };
    nav.status = .resolved;
    if (nav.linkage == .@"export" and zcu.ip.indexToKey(nav.val) == .func) try zcu.queueFunc(nav.val);
}

/// Resolves the fields and layout of a struct type (its `type_layout` unit).
pub fn ensureStructLayout(zcu: *Zcu, ty: InternPool.Index) Sema.CompileError!void {
    const info = zcu.ip.structInfo(ty);
    switch (info.status) {
        .have_layout => return,
        .failed => return error.AnalysisFail,
        .field_types_wip, .layout_wip => return error.DependencyLoop,
        .none, .have_field_types => {},
    }
    Sema.analyzeStructLayout(zcu, ty) catch |err| {
        info.status = .failed;
        return err;
    };
}

pub fn queueFunc(zcu: *Zcu, func: InternPool.Index) !void {
    const gop = try zcu.funcs.getOrPut(zcu.gpa, func);
    if (gop.found_existing) return;
    gop.value_ptr.* = .queued;
    try zcu.func_queue.append(zcu.gpa, func);
}

/// Analyzes the root file's `comptime` and exported declarations and
/// everything they reach. Each runtime function body is passed to
/// `sink.function(ir)` as soon as it is analyzed, then freed.
pub fn analyzeAll(zcu: *Zcu, sink: anytype) !void {
    _ = try zcu.fileRootType(0);
    var done_exports: usize = 0;
    var done_comptime: usize = 0;
    while (true) {
        if (done_comptime < zcu.comptime_decls.count()) {
            const c = zcu.comptime_decls.keys()[done_comptime];
            done_comptime += 1;
            Sema.analyzeComptimeDecl(zcu, c) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
            continue;
        }
        if (done_exports < zcu.exports.items.len) {
            const e = zcu.exports.items[done_exports];
            done_exports += 1;
            zcu.ensureNavVal(e.nav) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
            continue;
        }
        const func = zcu.func_queue.pop() orelse break;
        const state = zcu.funcs.getPtr(func).?;
        if (state.* != .queued) continue;
        state.* = .in_progress;
        var ir = Sema.analyzeFuncBody(zcu, func) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                state.* = .failed;
                continue;
            },
        };
        defer ir.deinit(zcu.gpa);
        state.* = .done;
        try sink.function(zcu, &ir);
    }
}
