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
const cache = @import("cache.zig");
const InternPool = @import("InternPool.zig");
const Ir = @import("Ir.zig");
const Sema = @import("Sema.zig");
const diag = @import("diag.zig");

const Zcu = @This();

gpa: Allocator,
io: Io,
fe: *Frontend,
ip: InternPool,
/// Root struct type of each file, `.none` until imported.
file_root_types: std.ArrayList(InternPool.Index) = .empty,
namespaces: std.ArrayList(Namespace) = .empty,
/// Dependencies recorded per unit by `Sema.declareDependency`. Nothing
/// persists them yet; the on-disk cache (milestone 6) will.
deps: std.AutoArrayHashMapUnmanaged(AnalUnit, []const Dependee) = .empty,
/// For units some of whose `deps` only the comptime evaluator's lowering
/// read (see "Comptime evaluator" in docs/architecture.md): the indices of
/// those, ascending. Such an edge counts for invalidation, but the unit
/// does not resolve its dependee itself. Arena-allocated.
conditional_deps: std.AutoHashMapUnmanaged(AnalUnit, []const u32) = .empty,
/// Analysis state of runtime function bodies.
funcs: std.AutoArrayHashMapUnmanaged(InternPool.Index, FuncState) = .empty,
func_queue: std.ArrayList(InternPool.Index) = .empty,
/// Which unit queued which function (`queueFuncFrom`), for the on-disk
/// cache: a unit loaded from it queues them again.
func_refs: std.AutoArrayHashMapUnmanaged(FuncRef, void) = .empty,
next_func: usize = 0,
/// Function bodies analyzed out of queue order (to resolve an inferred
/// error set), waiting to be passed to the sink.
ready_irs: std.ArrayList(Ir) = .empty,
/// `comptime` declarations, analyzed once each.
comptime_decls: std.AutoArrayHashMapUnmanaged(ComptimeDecl, enum { queued, done }) = .empty,
/// Memoized comptime calls, keyed by `Sema.comptimeCallKey`.
comptime_memo: std.AutoHashMapUnmanaged(InternPool.Hash, Memo) = .empty,
/// The comptime evaluator's state of each function called at comptime,
/// and of each generic function per specialization (see `Sema.bcCall`).
/// In memory only, like function IR.
comptime_bodies: std.AutoHashMapUnmanaged(InternPool.Hash, ComptimeBody) = .empty,
/// Comptime loops the evaluator does not take over from the walker (see
/// `Sema.bcOsr`), by file and the first instruction of the loop body.
comptime_osr_off: std.AutoHashMapUnmanaged(OsrLoop, void) = .empty,
/// Whether an aggregate value refers to a comptime allocation, cached for
/// `Sema.refersToComptimeAlloc`: comptime calls check every argument, and
/// large tables are passed again and again. A pure function of the value.
comptime_alloc_refs: std.AutoHashMapUnmanaged(InternPool.Index, bool) = .empty,
/// Walker runs of a function before it is lowered for the comptime
/// evaluator; 0 turns the evaluator off (`ZAP_COMPTIME_EVAL`).
comptime_eval_threshold: u32 = 4,
/// `ZAP_UNIT_TIMING=n`: analysis time per unit, for `printUnitTiming`.
unit_timing: ?UnitTiming = null,
/// Errors each function instance returns, for inferred error sets.
/// Arena-allocated.
inferred_errors: std.AutoHashMapUnmanaged(InternPool.Index, []const InternPool.String) = .empty,
/// Function instances whose inferred error set is `anyerror`.
anyerror_ies: std.AutoHashMapUnmanaged(InternPool.Index, void) = .empty,
/// The largest `@setEvalBranchQuota` of the callers that instantiated each
/// generic function instance, which its body runs with, as upstream.
/// Not a recorded dependency: an edit that lowers a caller's quota leaves
/// a cached instance green (upstream's order dependence, ziglang/zig#22410).
branch_quotas: std.AutoHashMapUnmanaged(InternPool.Index, u32) = .empty,
exports: std.ArrayList(Export) = .empty,
/// Files read by `@embedFile`, each once; `Dependee.embed_file` indexes it.
embed_files: std.StringArrayHashMapUnmanaged(EmbedFile) = .empty,
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
    target: union(enum) {
        nav: InternPool.NavIndex,
        /// An anonymous constant, as in `@export(&comptime_value, ...)`.
        uav: InternPool.Index,
    },
    name: InternPool.String,
    /// The unit whose analysis made the export (`@export`), or null for an
    /// `export` declaration, which the namespace scan makes.
    unit: ?AnalUnit,
};

pub const FuncState = enum { queued, in_progress, done, failed };

pub const FuncRef = struct { from: AnalUnit, func: InternPool.Index };

/// A function body lowered to IR for the comptime evaluator, with the
/// dependencies its lowering declared, which every unit that runs it
/// declares too.
/// A memoized comptime call's result, with the dependencies the call
/// declared, which a unit that reuses the result declares too.
/// Arena-allocated.
pub const Memo = struct {
    result: InternPool.Index,
    deps: []const MemoDep,
};

pub const MemoDep = struct {
    dependee: Dependee,
    /// Read only by a lowering for the comptime evaluator.
    conditional: bool,
};

pub const Bytecode = struct {
    ir: Ir,
    /// Every unit that runs the body declares these as conditional
    /// dependencies; its `comptime_dep` instructions declare the ones the
    /// run reaches as plain dependencies.
    deps: []const Dependee,
    /// The indices of the `deps` no `comptime_dep` instruction marks (read
    /// outside any runtime block of the body), which every run declares as
    /// plain dependencies.
    entry_deps: []const u32,
    /// For a generic function's specialization, per parameter: its type,
    /// and its value if the body has it comptime-known. Empty otherwise.
    params: []const BytecodeParam,
    /// Instructions whose values the evaluator keeps in its frame: an
    /// `alloc` used only by `load` and `store` to it, which stays out of
    /// comptime memory, and an `*_with_overflow` read only by
    /// `struct_field_val`, which is never interned as a tuple.
    in_frame: std.DynamicBitSetUnmanaged,
    /// Per instruction: the integer type of up to 64 bits its value has
    /// (for a frame-kept `alloc`, the value it holds; for a frame-kept
    /// `*_with_overflow`, the wrapped result), which the evaluator holds
    /// unboxed; `ty == .none` for other values.
    ints: []const BcInt,

    pub fn destroy(b: *Bytecode, gpa: Allocator) void {
        b.ir.deinit(gpa);
        gpa.free(b.ints);
        gpa.free(b.deps);
        gpa.free(b.entry_deps);
        gpa.free(b.params);
        b.in_frame.deinit(gpa);
        gpa.destroy(b);
    }
};

pub const OsrLoop = struct { file: u32, inst: u32 };

/// An integer type of 1 to 64 bits, for the evaluator's unboxed integers.
pub const BcInt = struct {
    ty: InternPool.Index = .none,
    bits: u8 = 0,
    signed: bool = false,

    /// The value whose two's complement's low 64 bits are `raw`.
    pub fn value(t: BcInt, raw: u64) i128 {
        return if (t.signed) @as(i64, @bitCast(raw)) else raw;
    }

    /// `x` wrapped to the type.
    pub fn wrap(t: BcInt, x: i128) i128 {
        const shift: u7 = @intCast(128 - @as(u8, t.bits));
        const low = @as(u128, @bitCast(x)) << shift;
        return if (t.signed) @as(i128, @bitCast(low)) >> shift else @intCast(low >> shift);
    }
};

pub const BytecodeParam = struct {
    ty: InternPool.Index,
    /// `.none` for a parameter the body takes as an `arg`.
    val: InternPool.Index,
};

pub const ComptimeBody = union(enum) {
    /// Not lowered yet: the walker ran the function `runs` times, and
    /// lowering is (re)tried at `next_try` runs, or once declaration
    /// `blocker` is resolved.
    cold: struct { runs: u32, next_try: u32, blocker: InternPool.NavIndex = .none },
    ready: *Bytecode,
    /// The evaluator does not run this function (any more: a run aborted
    /// where the walker succeeded; runs still in progress keep the body).
    off: ?*Bytecode,
};

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
    /// The default values of a declared struct's non-`comptime` fields,
    /// evaluated after its layout, which they may read.
    struct_defaults: InternPool.Index,
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
    /// The contents of `embed_files[index]` (`@embedFile`).
    embed_file: u32,
    /// The default values of a struct's non-`comptime` fields.
    struct_defaults: InternPool.Index,
};

/// A file read by `@embedFile`.
pub const EmbedFile = struct {
    /// Stable key: the module's name and the file's path in it,
    /// `module:sub/path`.
    key: []const u8,
    module: Frontend.Module.Index,
    sub_path: []const u8,
    /// `cache.hash` of the contents.
    hash: u128,
    /// Arena-allocated, without a sentinel.
    bytes: []const u8,
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
    code: diag.Code = .unclassified,
    notes: []const Note = &.{},

    /// `count` repeats of the same note in a row (a recursive call's
    /// frames) render once, as upstream. `call` marks a call-site frame of
    /// the comptime or inline call chain.
    pub const Note = struct { file: u32, span: Ast.Span, msg: []const u8, count: u32 = 1, call: ?diag.CallKind = null };
};

pub fn init(gpa: Allocator, io: Io, fe: *Frontend) !Zcu {
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
    zcu.deps.deinit(gpa);
    if (zcu.unit_timing) |*t| t.ns.deinit(gpa);
    zcu.func_refs.deinit(gpa);
    zcu.funcs.deinit(gpa);
    zcu.func_queue.deinit(gpa);
    for (zcu.ready_irs.items) |*ir| ir.deinit(gpa);
    zcu.ready_irs.deinit(gpa);
    zcu.comptime_decls.deinit(gpa);
    zcu.comptime_memo.deinit(gpa);
    zcu.conditional_deps.deinit(gpa);
    var bodies = zcu.comptime_bodies.valueIterator();
    while (bodies.next()) |b| switch (b.*) {
        .ready => |r| r.destroy(gpa),
        .off => |o| if (o) |r| r.destroy(gpa),
        .cold => {},
    };
    zcu.comptime_bodies.deinit(gpa);
    zcu.comptime_alloc_refs.deinit(gpa);
    zcu.comptime_osr_off.deinit(gpa);
    zcu.inferred_errors.deinit(gpa);
    zcu.anyerror_ies.deinit(gpa);
    zcu.branch_quotas.deinit(gpa);
    zcu.exports.deinit(gpa);
    zcu.embed_files.deinit(gpa);
    zcu.rt_helpers.deinit(gpa);
    zcu.test_functions.deinit(gpa);
    zcu.errors.deinit(gpa);
    zcu.file_root_types.deinit(gpa);
    zcu.ip.deinit();
    zcu.arena.deinit();
}

pub const tid: InternPool.Tid = .main;

/// Reads file `sub_path` of module `module` for `@embedFile`, once per
/// compilation; returns its `embed_files` index.
pub fn embedFile(zcu: *Zcu, module: Frontend.Module.Index, sub_path: []const u8) !u32 {
    const arena = zcu.arena.allocator();
    const mod = zcu.fe.module(module);
    const key = try std.fmt.allocPrint(arena, "{s}:{s}", .{ mod.name, sub_path });
    if (zcu.embed_files.getIndex(key)) |i| return @intCast(i);
    const path = try std.fs.path.join(arena, &.{ mod.root_dir, sub_path });
    const bytes = try Io.Dir.cwd().readFileAlloc(zcu.fe.io, path, arena, .unlimited);
    try zcu.embed_files.put(zcu.gpa, key, .{ .key = key, .module = module, .sub_path = key[mod.name.len + 1 ..], .hash = cache.hash(0, bytes), .bytes = bytes });
    return @intCast(zcu.embed_files.count() - 1);
}

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
    return zcu.addErrorCode(file_index, span, comptime diag.formatCode(fmt), fmt, args);
}

/// `addError` with a code other than its format's (`diag.formatCode`).
pub fn addErrorCode(zcu: *Zcu, file_index: u32, span: Ast.Span, code: diag.Code, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(zcu.arena.allocator(), fmt, args);
    try zcu.errors.append(zcu.gpa, .{ .file = file_index, .span = span, .msg = msg, .code = code });
}

/// Adds a note to the most recent error.
pub fn addNote(zcu: *Zcu, file_index: u32, span: Ast.Span, comptime fmt: []const u8, args: anytype) !void {
    try zcu.appendNote(.{ .file = file_index, .span = span, .msg = try std.fmt.allocPrint(zcu.arena.allocator(), fmt, args) });
}

/// Adds a call-site frame of the comptime or inline call chain to the most
/// recent error.
pub fn addCallFrame(zcu: *Zcu, file_index: u32, span: Ast.Span, kind: diag.CallKind) !void {
    try zcu.appendNote(.{ .file = file_index, .span = span, .msg = switch (kind) {
        .@"inline" => "called inline here",
        .@"comptime" => "called at comptime here",
    }, .call = kind });
}

fn appendNote(zcu: *Zcu, note: ErrorMsg.Note) !void {
    const arena = zcu.arena.allocator();
    const e = &zcu.errors.items[zcu.errors.items.len - 1];
    if (e.notes.len != 0) {
        const last = e.notes[e.notes.len - 1];
        if (last.file == note.file and last.span.main == note.span.main and std.mem.eql(u8, last.msg, note.msg)) {
            @constCast(&e.notes[e.notes.len - 1]).count += 1;
            return;
        }
    }
    const notes = try arena.alloc(ErrorMsg.Note, e.notes.len + 1);
    @memcpy(notes[0..e.notes.len], e.notes);
    notes[e.notes.len] = note;
    e.notes = notes;
}

fn diagLoc(zcu: *const Zcu, arena: Allocator, paths: diag.Paths, file_index: u32, span: Ast.Span) !diag.Loc {
    const f = zcu.file(file_index);
    return paths.loc(arena, f.display_path, try zcu.fe.source(@fromBackingInt(file_index)), span.start, span.main, span.end, f.module == .builtin);
}

/// This compilation's errors as diagnostics: AstGen errors of files loaded
/// during analysis first, then Sema's.
pub fn diagnostics(zcu: *const Zcu, arena: Allocator, paths: diag.Paths) ![]diag.Diagnostic {
    var out: std.ArrayList(diag.Diagnostic) = .empty;
    for (zcu.fe.late_errors.items) |b| try diag.fromBundle(arena, paths, b, &out);
    for (zcu.errors.items) |e| {
        const notes = try arena.alloc(diag.Note, e.notes.len);
        for (notes, e.notes) |*n, en| n.* = .{ .loc = try zcu.diagLoc(arena, paths, en.file, en.span), .msg = en.msg, .count = en.count, .call = en.call };
        try out.append(arena, .{ .code = e.code, .loc = try zcu.diagLoc(arena, paths, e.file, e.span), .msg = e.msg, .notes = notes });
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Files and namespaces

/// The root struct type of a file, creating it (and its namespace) on first use.
pub fn fileRootType(zcu: *Zcu, file_index: u32) !InternPool.Index {
    if (zcu.file_root_types.items[file_index] != .none) return zcu.file_root_types.items[file_index];
    const ty = try zcu.createContainerType(.@"struct", file_index, .main_struct_inst, &.{}, try zcu.fileFqn(file_index), try zcu.fileKey(file_index), Namespace.none, null);
    zcu.file_root_types.items[file_index] = ty;
    return ty;
}

pub const ContainerKind = enum { @"struct", @"enum", @"union", @"opaque" };

/// Interns a declared container type of `kind` with display name `fqn` and
/// stable key `key`. If it is new, creates its namespace and declarations
/// and queues its `comptime` and exported declarations. A type made by
/// `@Struct`, `@Union`, or `@Enum` passes its `reified_layout`; it has no
/// declarations.
pub fn createContainerType(
    zcu: *Zcu,
    kind: ContainerKind,
    file_index: u32,
    inst: Zir.Inst.Index,
    captures: []const InternPool.Index,
    fqn: []const u8,
    key: []const u8,
    parent_ns: u32,
    reified_layout: ?std.lang.Type.ContainerLayout,
) !InternPool.Index {
    const ip = &zcu.ip;
    const zir = &zcu.file(file_index).zir;
    const decls: []const Zir.Inst.Index, const layout: std.lang.Type.ContainerLayout = if (reified_layout) |l| .{ &.{}, l } else switch (kind) {
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
            .is_threadlocal = d.is_threadlocal,
        });
        switch (d.kind) {
            .@"const", .@"var" => {
                try zcu.namespaces.items[ns_index].decls.put(zcu.gpa, ip.getNav(nav).name, nav);
                if (d.linkage == .@"export") try zcu.exports.append(zcu.gpa, .{ .target = .{ .nav = nav }, .name = ip.getNav(nav).name, .unit = null });
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

pub fn recordDeps(zcu: *Zcu, unit: AnalUnit, deps: []const Dependee, conditional: []const u32) !void {
    // In the arena: a small gpa allocation per unit pins allocator pages
    // for the whole compilation.
    try zcu.deps.put(zcu.gpa, unit, try zcu.arena.allocator().dupe(Dependee, deps));
    if (conditional.len != 0) {
        try zcu.conditional_deps.put(zcu.gpa, unit, try zcu.arena.allocator().dupe(u32, conditional));
    } else _ = zcu.conditional_deps.remove(unit);
}

/// Renders a unit's stable key, which does not depend on analysis order or
/// in-memory indices.
pub fn unitKey(zcu: *Zcu, unit: AnalUnit, w: *std.Io.Writer) !void {
    const ip = &zcu.ip;
    switch (unit) {
        .nav_val => |nav| try w.writeAll(ip.stringSlice(ip.getNav(nav).key)),
        .type_layout => |ty| try w.print("{s}@layout", .{ip.stringSlice(ip.containerType(ty).?.key)}),
        .struct_defaults => |ty| try w.print("{s}@defaults", .{ip.stringSlice(ip.containerType(ty).?.key)}),
        .func => |func| {
            const f = ip.keyPayload(.func, func);
            try w.writeAll(ip.stringSlice(ip.getNav(f.owner_nav).key));
            if (f.generic_owner != .none) try w.print("__{x}", .{ip.stableHash(func)});
        },
        .comptime_decl => |c| {
            const ns = &zcu.namespaces.items[c.namespace];
            try w.print("{s}{s}comptime#{d}", .{ ns.key, if (ns.parent == Namespace.none) ":" else ".", c.ordinal });
        },
    }
}

pub const UnitTiming = struct {
    /// How many units `printUnitTiming` prints.
    top: u32,
    /// Time spent in the units the innermost unit in progress analyzed in
    /// turn, which `ns` does not count against it.
    nested_ns: u64 = 0,
    ns: std.AutoArrayHashMapUnmanaged(AnalUnit, u64) = .empty,

    /// Starts timing a unit (`Sema.create`); pass the result to `stop`.
    pub fn start(t: *UnitTiming, io: Io) [2]u64 {
        defer t.nested_ns = 0;
        return .{ @intCast(Io.Timestamp.now(io, .awake).nanoseconds), t.nested_ns };
    }

    pub fn stop(t: *UnitTiming, gpa: Allocator, io: Io, unit: AnalUnit, started: [2]u64) void {
        const ns = @as(u64, @intCast(Io.Timestamp.now(io, .awake).nanoseconds)) - started[0];
        const gop = t.ns.getOrPutValue(gpa, unit, 0) catch return;
        gop.value_ptr.* += ns -| t.nested_ns;
        t.nested_ns = started[1] + ns;
    }
};

/// Prints the `ZAP_UNIT_TIMING` slowest units to stderr.
pub fn printUnitTiming(zcu: *Zcu) void {
    const t = if (zcu.unit_timing) |*t| t else return;
    const C = struct {
        v: []const u64,
        pub fn lessThan(c: @This(), a: usize, b: usize) bool {
            return c.v[a] > c.v[b];
        }
    };
    t.ns.sortUnstable(C{ .v = t.ns.values() });
    var total: u64 = 0;
    var by_kind: std.EnumArray(std.meta.Tag(AnalUnit), [2]u64) = .initFill(.{ 0, 0 });
    for (t.ns.keys(), t.ns.values()) |unit, v| {
        total += v;
        const k = by_kind.getPtr(unit);
        k[0] += 1;
        k[1] += v;
    }
    std.debug.print("unit timing: {d} units, {d:.1} ms", .{ t.ns.count(), @as(f64, @floatFromInt(total)) / 1e6 });
    var it = by_kind.iterator();
    while (it.next()) |k| std.debug.print("; {s} {d}: {d:.1} ms", .{ @tagName(k.key), k.value[0], @as(f64, @floatFromInt(k.value[1])) / 1e6 });
    std.debug.print("\n", .{});
    for (t.ns.keys()[0..@min(t.top, t.ns.count())], t.ns.values()[0..@min(t.top, t.ns.count())]) |unit, ns| {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        zcu.unitKey(unit, &w) catch {};
        std.debug.print("{d:>9.2} ms  {s} {s}\n", .{ @as(f64, @floatFromInt(ns)) / 1e6, @tagName(unit), w.buffered() });
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
    if (nav.linkage == .@"export" and zcu.ip.keyTag(nav.val) == .func) try zcu.queueFunc(nav.val);
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

/// Resolves the default values of a struct whose layout is resolved (its
/// `struct_defaults` unit).
pub fn ensureStructDefaults(zcu: *Zcu, ty: InternPool.Index) Sema.CompileError!void {
    const info = zcu.ip.structInfo(ty);
    switch (info.defaults_status) {
        .resolved => return,
        .failed => return error.AnalysisFail,
        .wip => return error.DependencyLoop,
        .none => {},
    }
    info.defaults_status = .wip;
    Sema.analyzeStructDefaults(zcu, ty) catch |err| {
        info.defaults_status = .failed;
        return err;
    };
    info.defaults_status = .resolved;
}

/// Resolves the inferred error set of function instance `func`, analyzing
/// its body if that has not happened yet; null if it is `anyerror`.
pub fn ensureFuncIes(zcu: *Zcu, func: InternPool.Index) Sema.CompileError!?[]const InternPool.String {
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
    if (zcu.anyerror_ies.contains(func)) return null;
    return zcu.inferred_errors.get(func) orelse &.{};
}

/// Queues `func` on behalf of unit `from`, which refers to it (a call, a
/// reference to its declaration, a coercion to a function pointer, an
/// export), and records the reference.
pub fn queueFuncFrom(zcu: *Zcu, from: AnalUnit, func: InternPool.Index) !void {
    try zcu.func_refs.put(zcu.gpa, .{ .from = from, .func = func }, {});
    try zcu.queueFunc(func);
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

/// The stable key of the compiler_rt function exporting libm symbol `name`
/// (`sinf`, `__floorh`, `sqrtf128`, ...), requesting it like
/// `requestCompilerRt`, or null if compiler_rt does not export `name`.
/// For `@extern` references, which upstream resolves against the
/// compiler_rt it links.
pub fn requestCompilerRtExport(zcu: *Zcu, name: []const u8) !?[]const u8 {
    const RtExport = struct { file: []const u8, decl: []const u8 };
    const map = comptime blk: {
        const ops = .{ "sqrt", "sin", "cos", "tan", "exp", "exp2", "log", "log2", "log10", "fabs", "floor", "ceil", "round", "trunc", "fma", "fmin", "fmax", "fmod" };
        var kvs: [ops.len * 5]struct { []const u8, RtExport } = undefined;
        for (ops, 0..) |op, i| {
            const f = if (std.mem.eql(u8, op, "floor") or std.mem.eql(u8, op, "ceil")) "floor_ceil.zig" else op ++ ".zig";
            kvs[i * 5 ..][0..5].* = .{
                .{ "__" ++ op ++ "h", .{ .file = f, .decl = "__" ++ op ++ "h" } },
                .{ op ++ "f", .{ .file = f, .decl = op ++ "f" } },
                .{ op, .{ .file = f, .decl = op } },
                .{ "__" ++ op ++ "x", .{ .file = f, .decl = "__" ++ op ++ "x" } },
                .{ op ++ "f128", .{ .file = f, .decl = op ++ "q" } },
            };
        }
        break :blk std.StaticStringMap(RtExport).initComptime(kvs);
    };
    const e = map.get(name) orelse return null;
    return try zcu.requestCompilerRt(e.file, e.decl);
}

fn resolveCompilerRt(zcu: *Zcu, key: []const u8) !void {
    const no_span: Ast.Span = .{ .start = 0, .end = 0, .main = 0 };
    const rest = key["compiler_rt:".len..];
    const colon = std.mem.lastIndexOfScalar(u8, rest, ':').?;
    const name = rest[colon + 1 ..];
    // compiler_rt's files load on demand, like its analysis.
    const file_index = zcu.fe.loadFile(.compiler_rt, rest[0..colon]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return zcu.addError(0, no_span, "unable to load compiler_rt file '{s}': {t}", .{ rest[0..colon], err }),
    } orelse return zcu.addError(0, no_span, "compiler_rt file '{s}' not found", .{rest[0..colon]});
    try zcu.file_root_types.appendNTimes(zcu.gpa, .none, zcu.fe.files.items.len - zcu.file_root_types.items.len);
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
            if (e.target != .nav) continue;
            zcu.ensureNavVal(e.target.nav) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            // An exported function is emitted whether or not it is called.
            const val = zcu.ip.getNav(e.target.nav).val;
            if (zcu.ip.keyTag(val) == .func) try zcu.queueFunc(val);
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
