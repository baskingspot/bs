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
next_func: usize = 0,
/// Function bodies analyzed out of queue order (to resolve an inferred
/// error set), waiting to be passed to the sink.
ready_irs: std.ArrayList(Ir) = .empty,
/// `comptime` declarations, analyzed once each.
comptime_decls: std.AutoArrayHashMapUnmanaged(ComptimeDecl, enum { queued, done }) = .empty,
/// Memoized comptime calls, keyed by `Sema.comptimeCallKey`.
comptime_memo: std.AutoHashMapUnmanaged(InternPool.Hash, InternPool.Index) = .empty,
/// Errors each function instance returns, for inferred error sets.
inferred_errors: std.AutoHashMapUnmanaged(InternPool.Index, std.ArrayList(InternPool.String)) = .empty,
exports: std.ArrayList(Export) = .empty,
/// compiler_rt functions that CodeGen calls, by the stable key of their
/// declaration; `analyzeAll` resolves each and queues its body.
rt_helpers: std.StringArrayHashMapUnmanaged(void) = .empty,
/// `zap test`: collect the main module's tests into `builtin.test_functions`.
is_test: bool = false,
/// `zap test --test-filter`: keep only named tests whose fqn contains one.
test_filters: []const []const u8 = &.{},
/// Test declarations to run, in discovery order.
test_functions: std.ArrayList(InternPool.NavIndex) = .empty,
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
    /// Position among the namespace's `comptime` declarations; with the
    /// namespace's key, the unit's stable key.
    ordinal: u32,
};

/// Sema's unit of work, caching, and parallelism.
pub const AnalUnit = union(enum) {
    nav_val: InternPool.NavIndex,
    type_layout: InternPool.Index,
    func: InternPool.Index,
    comptime_decl: ComptimeDecl,
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
    /// The names of all declarations of namespace `namespace` (`@typeInfo`
    /// lists them).
    namespace: u32,
};

pub const Namespace = struct {
    file: u32,
    /// Lexically enclosing namespace, or `none`.
    parent: u32,
    owner_type: InternPool.Index,
    /// Display name prefix of declarations in this namespace.
    fqn: []const u8,
    /// Stable key prefix of declarations in this namespace.
    key: []const u8,
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
    for (zcu.ready_irs.items) |*ir| ir.deinit(gpa);
    zcu.ready_irs.deinit(gpa);
    zcu.comptime_decls.deinit(gpa);
    zcu.comptime_memo.deinit(gpa);
    var it = zcu.inferred_errors.valueIterator();
    while (it.next()) |list| list.deinit(gpa);
    zcu.inferred_errors.deinit(gpa);
    zcu.exports.deinit(gpa);
    zcu.rt_helpers.deinit(gpa);
    zcu.test_functions.deinit(gpa);
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
pub fn fileKey(zcu: *Zcu, index: u32) ![]const u8 {
    const f = zcu.file(index);
    const mod = zcu.fe.module(f.module);
    return std.fmt.allocPrint(zcu.arena.allocator(), "{s}:{s}", .{ mod.name, f.sub_path });
}

/// The display name of a file's root struct, as upstream renders it: the path
/// within its module, without extension, with slashes as dots.
pub fn fileFqn(zcu: *Zcu, index: u32) ![]const u8 {
    const sub_path = zcu.file(index).sub_path;
    const noext = sub_path[0 .. sub_path.len - std.fs.path.extension(sub_path).len];
    const fqn = try zcu.arena.allocator().dupe(u8, noext);
    std.mem.replaceScalar(u8, fqn, '/', '.');
    return fqn;
}

/// The root file of module `mod`, if anything loaded it.
pub fn moduleRootFile(zcu: *Zcu, mod: @import("Frontend.zig").Module.Index) ?u32 {
    var buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{d}:{s}", .{ @backingInt(mod), zcu.fe.module(mod).root_file }) catch return null;
    const index = zcu.fe.file_map.get(key) orelse return null;
    return @backingInt(index);
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
        const loc = std.zig.findLineColumn(try zcu.fe.source(@fromBackingInt(e.file)), e.span.main);
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
    const ty = try zcu.createContainerType(.@"struct", file_index, .main_struct_inst, &.{}, try zcu.fileFqn(file_index), try zcu.fileKey(file_index), Namespace.none);
    zcu.file_root_types.items[file_index] = ty;
    return ty;
}

pub const ContainerKind = enum { @"struct", @"enum", @"union", @"opaque" };

/// Interns a declared container type of `kind` with display name `fqn` and
/// stable key `key`. If it is new, creates its namespace and declarations
/// and queues its `comptime` and exported declarations.
pub fn createContainerType(
    zcu: *Zcu,
    kind: ContainerKind,
    file_index: u32,
    inst: Zir.Inst.Index,
    captures: []const InternPool.Index,
    fqn: []const u8,
    key: []const u8,
    parent_ns: u32,
) !InternPool.Index {
    const ip = &zcu.ip;
    const zir = &zcu.file(file_index).zir;
    const decls: []const Zir.Inst.Index, const layout: std.lang.Type.ContainerLayout = switch (kind) {
        .@"struct" => blk: {
            const d = zir.getStructDecl(inst);
            break :blk .{ d.decls, d.layout };
        },
        .@"enum" => .{ zir.getEnumDecl(inst).decls, .auto },
        .@"union" => blk: {
            const d = zir.getUnionDecl(inst);
            break :blk .{ d.decls, d.kind.layout() };
        },
        .@"opaque" => .{ zir.getOpaqueDecl(inst).decls, .auto },
    };
    const name = try ip.getString(tid, fqn);
    // Look up first so an existing type keeps its namespace.
    const info = try ip.createContainerInfo(tid, .{ .namespace = Namespace.none, .layout = layout });
    const container: InternPool.ContainerType = .{
        .file = file_index,
        .zir_inst = inst,
        .captures = captures,
        .name = name,
        .key = try ip.getString(tid, key),
        .info = info,
    };
    const ty = try ip.get(tid, switch (kind) {
        .@"struct" => .{ .struct_type = container },
        .@"enum" => .{ .enum_type = container },
        .@"union" => .{ .union_type = container },
        .@"opaque" => .{ .opaque_type = container },
    });
    const si = ip.structInfo(ty);
    if (si.namespace != Namespace.none) return ty;

    const ns_index: u32 = @intCast(zcu.namespaces.items.len);
    si.namespace = ns_index;
    try zcu.namespaces.append(zcu.gpa, .{
        .file = file_index,
        .parent = parent_ns,
        .owner_type = ty,
        // The caller's names may live in a Sema arena.
        .fqn = try zcu.arena.allocator().dupe(u8, fqn),
        .key = try zcu.arena.allocator().dupe(u8, key),
    });
    const arena = zcu.arena.allocator();
    const key_sep = if (parent_ns == Namespace.none) ":" else ".";
    const collect_tests = zcu.is_test and zcu.file(file_index).module == zcu.fe.main_module;
    var comptime_ordinal: u32 = 0;
    var unnamed_tests: u32 = 0;
    for (decls) |decl_inst| {
        const d = zir.getDeclaration(decl_inst);
        const simple: []const u8 = switch (d.kind) {
            .@"comptime" => {
                if (zcu.file(file_index).module == .compiler_rt) continue;
                try zcu.comptime_decls.put(zcu.gpa, .{ .file = file_index, .inst = decl_inst, .namespace = ns_index, .ordinal = comptime_ordinal }, .queued);
                comptime_ordinal += 1;
                continue;
            },
            .unnamed_test, .@"test", .decltest => blk: {
                if (!collect_tests) continue;
                if (d.kind == .unnamed_test) {
                    defer unnamed_tests += 1;
                    break :blk try std.fmt.allocPrint(arena, "test_{d}", .{unnamed_tests});
                }
                break :blk try std.fmt.allocPrint(arena, "{t}.{s}", .{ d.kind, zir.nullTerminatedString(d.name) });
            },
            .@"const", .@"var" => zir.nullTerminatedString(d.name),
        };
        const decl_fqn = try std.fmt.allocPrint(arena, "{s}.{s}", .{ fqn, simple });
        const decl_key = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ key, key_sep, simple });
        var hasher: InternPool.Hasher = .init("nav");
        hasher.bytes(decl_key);
        const nav = try ip.createNav(tid, .{
            .name = try ip.getString(tid, simple),
            .fqn = try ip.getString(tid, decl_fqn),
            .key = try ip.getString(tid, decl_key),
            .file = file_index,
            .zir_inst = decl_inst,
            .namespace = ns_index,
            .hash = hasher.final(),
            .is_pub = d.is_pub,
            .linkage = d.linkage,
            .is_const = d.kind != .@"var",
        });
        switch (d.kind) {
            .@"const", .@"var" => {
                try zcu.namespaces.items[ns_index].decls.put(zcu.gpa, ip.getNav(nav).name, nav);
                if (d.linkage == .@"export") try zcu.exports.append(zcu.gpa, .{ .nav = nav, .name = ip.getNav(nav).name });
            },
            else => {
                // Upstream's filter semantics: unnamed tests always run;
                // named ones only if their fqn contains some filter.
                if (d.kind != .unnamed_test and zcu.test_filters.len > 0) {
                    for (zcu.test_filters) |filter| {
                        if (std.mem.indexOf(u8, decl_fqn, filter) != null) break;
                    } else continue;
                }
                try zcu.test_functions.append(zcu.gpa, nav);
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
        .nav_val => |nav| try w.writeAll(ip.stringSlice(ip.getNav(nav).key)),
        .type_layout => |ty| try w.print("{s}@layout", .{ip.stringSlice(ip.containerType(ty).?.key)}),
        .func => |func| {
            const f = ip.indexToKey(func).func;
            try w.writeAll(ip.stringSlice(ip.getNav(f.owner_nav).key));
            if (f.generic_owner != .none) try w.print("__{x}", .{ip.stableHash(func)});
        },
        .comptime_decl => |c| {
            const ns = &zcu.namespaces.items[c.namespace];
            try w.print("{s}{s}comptime#{d}", .{ ns.key, if (ns.parent == Namespace.none) ":" else ".", c.ordinal });
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

/// Resolves the inferred error set of function instance `func`, analyzing
/// its body if that has not happened yet.
pub fn ensureFuncIes(zcu: *Zcu, func: InternPool.Index) Sema.CompileError![]const InternPool.String {
    const gop = try zcu.funcs.getOrPut(zcu.gpa, func);
    if (!gop.found_existing) gop.value_ptr.* = .queued;
    switch (gop.value_ptr.*) {
        .done => {},
        .failed => return error.AnalysisFail,
        .in_progress => return error.DependencyLoop,
        .queued => {
            gop.value_ptr.* = .in_progress;
            var ir = Sema.analyzeFuncBody(zcu, func) catch |err| {
                zcu.funcs.getPtr(func).?.* = .failed;
                return err;
            };
            errdefer ir.deinit(zcu.gpa);
            zcu.funcs.getPtr(func).?.* = .done;
            try zcu.ready_irs.append(zcu.gpa, ir);
        },
    }
    return if (zcu.inferred_errors.get(func)) |list| list.items else &.{};
}

pub fn queueFunc(zcu: *Zcu, func: InternPool.Index) !void {
    const gop = try zcu.funcs.getOrPut(zcu.gpa, func);
    if (gop.found_existing) return;
    gop.value_ptr.* = .queued;
    try zcu.func_queue.append(zcu.gpa, func);
}

/// Requests compiler_rt function `name`, declared in `lib/compiler_rt/<file>`,
/// and returns the stable key of its function unit (its symbol). Only that
/// declaration and what it reaches are analyzed, never compiler_rt's
/// `comptime` export blocks.
pub fn requestCompilerRt(zcu: *Zcu, file_name: []const u8, name: []const u8) ![]const u8 {
    var buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "compiler_rt:compiler_rt/{s}:{s}", .{ file_name, name }) catch unreachable;
    const gop = try zcu.rt_helpers.getOrPut(zcu.gpa, key);
    if (!gop.found_existing) gop.key_ptr.* = try zcu.arena.allocator().dupe(u8, key);
    return gop.key_ptr.*;
}

fn resolveCompilerRt(zcu: *Zcu, key: []const u8) !void {
    const no_span: Ast.Span = .{ .start = 0, .end = 0, .main = 0 };
    const rest = key["compiler_rt:".len..];
    const colon = std.mem.lastIndexOfScalar(u8, rest, ':').?;
    const name = rest[colon + 1 ..];
    var buf: [128]u8 = undefined;
    const file_key = std.fmt.bufPrint(&buf, "{d}:{s}", .{ @backingInt(Frontend.Module.Index.compiler_rt), rest[0..colon] }) catch unreachable;
    const file_index = zcu.fe.file_map.get(file_key) orelse
        return zcu.addError(0, no_span, "compiler_rt file '{s}' is not loaded", .{rest[0..colon]});
    const ty = try zcu.fileRootType(@backingInt(file_index));
    const ns = zcu.ip.structInfo(ty).namespace;
    const nav = zcu.namespaces.items[ns].decls.get(try zcu.ip.getString(tid, name)) orelse
        return zcu.addError(@backingInt(file_index), no_span, "compiler_rt has no function '{s}'", .{name});
    zcu.ensureNavVal(nav) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    try zcu.queueFunc(zcu.ip.getNav(nav).val);
}

/// Analyzes the root file's `comptime` and exported declarations and
/// everything they reach. Each runtime function body is passed to
/// `sink.function(ir)` as soon as it is analyzed, then freed.
pub fn analyzeAll(zcu: *Zcu, sink: anytype) !void {
    // Upstream's analysis roots: std (whose start code imports the root
    // module) and, under `zap test`, the module under test.
    _ = try zcu.fileRootType(0);
    if (zcu.moduleRootFile(.std)) |f| _ = try zcu.fileRootType(f);
    if (zcu.moduleRootFile(zcu.fe.main_module)) |f| _ = try zcu.fileRootType(f);
    var done_exports: usize = 0;
    var done_comptime: usize = 0;
    var done_tests: usize = 0;
    var done_rt: usize = 0;
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
        if (done_tests < zcu.test_functions.items.len) {
            const nav = zcu.test_functions.items[done_tests];
            done_tests += 1;
            zcu.ensureNavVal(nav) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            try zcu.queueFunc(zcu.ip.getNav(nav).val);
            continue;
        }
        if (done_rt < zcu.rt_helpers.count()) {
            const key = zcu.rt_helpers.keys()[done_rt];
            done_rt += 1;
            try zcu.resolveCompilerRt(key);
            continue;
        }
        if (zcu.ready_irs.items.len != 0) {
            var ir = zcu.ready_irs.orderedRemove(0);
            defer ir.deinit(zcu.gpa);
            try sink.function(zcu, &ir);
            continue;
        }
        if (zcu.next_func == zcu.func_queue.items.len) break;
        const func = zcu.func_queue.items[zcu.next_func];
        zcu.next_func += 1;
        const state = zcu.funcs.getPtr(func).?;
        if (state.* != .queued) continue;
        state.* = .in_progress;
        // Analysis can grow `funcs`, so the state is looked up again after.
        var ir = Sema.analyzeFuncBody(zcu, func) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                zcu.funcs.getPtr(func).?.* = .failed;
                continue;
            },
        };
        defer ir.deinit(zcu.gpa);
        zcu.funcs.getPtr(func).?.* = .done;
        try sink.function(zcu, &ir);
    }
}
