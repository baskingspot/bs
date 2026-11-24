//! `bs doc <symbol>`: prints the documentation of a public declaration,
//! such as `std.ArrayList` or `vaxis.Window`, from its source, as
//! rockorager's zigdoc does and in its format: where it is, the aliases
//! it goes through, its category and signature, its doc comments, and
//! its members.
//!
//! It reads syntax, not types: files are parsed with bs's frontend in the
//! project's language as a path reaches them, and a declaration's value
//! is classified the way upstream's autodocs classify it
//! (lib/docs/wasm/Walk.zig, `categorize_expr`): containers, aliases
//! through identifiers, field accesses, `@import` and `@This()`, and
//! functions that return types, whose members are those of the container
//! they return. Copyright (c) Zig contributors. MIT licensed (see
//! LICENSE-ZIG).
//!
//! `std` is the zig lib directory's. The other modules are those of
//! build.zig's compile steps, from the configuration bs's build runner
//! serializes (`bs build --print-configuration-path`): each import under
//! its import name, and each step's root module under the step's name.

const Doc = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const frontend = @import("frontend");
const Ast = frontend.Ast;
const Configuration = std.Build.Configuration;
const main = @import("main.zig");
const Frontend = @import("Frontend.zig");
const language = @import("language.zig");
const toolchain = @import("toolchain.zig");

arena: Allocator,
io: Io,
lang: language.Language,
/// Parsed files by absolute path, each where it stays while more load.
files: std.array_hash_map.String(*const Ast) = .empty,
/// Module names to the absolute paths of their root files.
modules: std.array_hash_map.String([]const u8) = .empty,
/// The names of build.zig's modules whose root files the build generates.
generated: std.array_hash_map.String(void) = .empty,
/// How deep `categorize` is in itself, which only a cycle of aliases
/// through field accesses (`const a = a.b;`) takes past `max_hops`.
depth: u32 = 0,

/// A declaration: a container member (`node` a variable or function
/// declaration) or a file's root (`node` `.root`).
const Decl = struct {
    file: u32,
    node: Ast.Node.Index,
    /// The declarations whose containers enclose this one, the file's
    /// root first; empty for a file's root. Identifiers in the
    /// declaration resolve in these containers, innermost first.
    scope: []const Scope,
};

const Scope = struct {
    decl: Ast.Node.Index,
    container: Ast.Node.Index,
};

/// What a declaration's value is, as autodocs' `Walk.Category`.
const Category = union(enum) {
    /// A struct without fields, used to group declarations.
    namespace: Ast.Node.Index,
    /// A struct with fields, or an enum, union or opaque.
    container: Ast.Node.Index,
    global_variable,
    /// A function not seen to return a type.
    function,
    /// A function that returns a type.
    type_function,
    primitive,
    error_set,
    global_const,
    alias: Decl,
    /// A type that is not a container, such as `u8` or `[]const u8`.
    type,
    /// The type `type`.
    type_type,
};

/// The members of a container, with the scope their declarations see.
const Members = struct {
    file: u32,
    container: Ast.Node.Index,
    scope: []const Scope,
};

/// Alias chains longer than this are taken to be cycles.
const max_hops = 64;

const usage =
    \\Usage: bs doc [options] <symbol>
    \\
    \\Prints the documentation of a public declaration of std or of a module
    \\that build.zig's compile steps import: where it is, the aliases it goes
    \\through, its category and signature, its doc comments, and its members.
    \\
    \\Examples:
    \\  bs doc std.ArrayList
    \\  bs doc std.mem.Allocator
    \\  bs doc vaxis.Window
    \\
    \\Options:
    \\  --zig-version [ver]   The language (0.16 or 0.17), else .bs.zon's, else 0.17
    \\  --zig-lib-dir [path]  The zig lib directory whose std to read
    \\  -h, --help            Print this help and exit
    \\
;

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;
    var version_flag: ?[]const u8 = null;
    var lib_flag: ?[]const u8 = null;
    var symbol: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try Io.File.stdout().writeStreamingAll(io, usage);
            return;
        } else if (std.mem.eql(u8, arg, "--zig-version")) {
            i += 1;
            version_flag = if (i < args.len) args[i] else main.fatal("expected an argument after {s}", .{arg});
        } else if (std.mem.eql(u8, arg, "--zig-lib-dir")) {
            i += 1;
            lib_flag = if (i < args.len) args[i] else main.fatal("expected an argument after {s}", .{arg});
        } else if (std.mem.startsWith(u8, arg, "-")) {
            main.fatal("unrecognized parameter: '{s}'", .{arg});
        } else if (symbol != null) {
            main.fatal("expected one symbol, found '{s}' and '{s}'", .{ symbol.?, arg });
        } else symbol = arg;
    }
    const sym = symbol orelse {
        try Io.File.stderr().writeStreamingAll(io, usage);
        std.process.exit(1);
    };

    const cwd = try std.process.currentPathAlloc(io, arena);
    // As a compilation whose root file is in the working directory.
    const choice = try language.resolve(arena, io, env, version_flag, try Io.Dir.path.join(arena, &.{ cwd, "build.zig" }));
    const dirs = Frontend.resolveCacheDirs(arena, io, env, .{ .local_is_global = true });
    const global = try Io.Dir.path.resolveAlloc(arena, &.{ cwd, dirs.global });
    const lib = try Io.Dir.path.resolveAlloc(arena, &.{ cwd, (try toolchain.libDir(arena, io, env, global, lib_flag, choice.language)).path });

    var d: Doc = .{ .arena = arena, .io = io, .lang = choice.language };
    try d.modules.put(arena, "std", try Io.Dir.path.join(arena, &.{ lib, "std", "std.zig" }));
    var parts = std.mem.splitScalar(u8, sym, '.');
    const module_name = parts.first();
    if (!d.modules.contains(module_name)) try d.addBuildModules(init, cwd);
    const root_path = d.modules.get(module_name) orelse {
        if (d.generated.contains(module_name)) fail("error: build.zig generates the root file of module '{s}' (an options module or another step's output); bs doc reads only source files\n", io, .{module_name});
        const names = try std.mem.join(arena, ", ", d.modules.keys());
        fail("error: no module '{s}'; the modules are {s}\n", io, .{ module_name, names });
    };

    var decl: Decl = .{ .file = try d.load(root_path), .node = .root, .scope = &.{} };
    var path_len = module_name.len;
    while (parts.next()) |name| {
        const parent = sym[0..path_len];
        const view = d.members(decl) orelse fail("error: '{s}' is not a container, so it has no member '{s}'\n", io, .{ parent, name });
        decl = d.child(view, name) orelse d.reportMissing(view, parent, name);
        if (!d.isPub(decl)) fail("error: '{s}' is declared in '{s}' but is not pub\n", io, .{ name, parent });
        path_len += 1 + name.len;
    }

    var buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &buf);
    try d.print(&out.interface, decl, sym);
    try out.interface.flush();
}

/// Writes `fmt` to stderr and exits with status 1.
fn fail(comptime fmt: []const u8, io: Io, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    var w = Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch {}; // ziglint-ignore: Z026 -- exiting with status 1 either way
    w.interface.flush() catch {}; // ziglint-ignore: Z026 -- exiting with status 1 either way
    std.process.exit(1);
}

/// Exits for a member `name` that `parent` lacks, naming the public
/// members whose names are close to it.
fn reportMissing(d: *Doc, view: Members, parent: []const u8, name: []const u8) noreturn {
    var close: std.ArrayList(u8) = .empty;
    const t = d.tree(view.file);
    var buf: [2]Ast.Node.Index = undefined;
    for (containerMembers(t, &buf, view.container)) |member| {
        const member_name = declName(t, member) orelse continue;
        if (!d.isPub(.{ .file = view.file, .node = member, .scope = &.{} })) continue;
        if (!isClose(name, member_name)) continue;
        close.print(d.arena, "\nnote: did you mean '{s}.{s}'?", .{ parent, member_name }) catch break;
    }
    fail("error: '{s}' has no public declaration '{s}'{s}\n", d.io, .{ parent, name, close.items });
}

/// Whether `a` and `b` differ only in case or by at most a third of
/// their length in edits (at least one).
fn isClose(a: []const u8, b: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(a, b)) return true;
    if (a.len > 64 or b.len > 64) return false;
    var row: [65]usize = undefined;
    for (0..b.len + 1) |j| row[j] = j;
    for (a, 1..) |ca, ii| {
        var diag = row[0];
        row[0] = ii;
        for (b, 1..) |cb, j| {
            const next = @min(@min(row[j], row[j - 1]) + 1, diag + @intFromBool(std.ascii.toLower(ca) != std.ascii.toLower(cb)));
            diag = row[j];
            row[j] = next;
        }
    }
    return row[b.len] <= @max(1, @max(a.len, b.len) / 3);
}

/// Adds the modules of build.zig's compile steps, from the configuration
/// `bs build` serializes, when there is a build.zig. Generated root files
/// (options modules) are left out: they exist only once a build makes them.
fn addBuildModules(d: *Doc, init: std.process.Init, cwd: []const u8) !void {
    const arena = d.arena;
    const io = d.io;
    var dir: []const u8 = cwd;
    while (true) {
        if (Io.Dir.cwd().access(io, try Io.Dir.path.join(arena, &.{ dir, std.zig.build_zig_basename }), .{})) |_| break else |_| {}
        dir = Io.Dir.path.dirname(dir) orelse return;
    }
    if (d.lang == .zig_0_16) {
        try Io.File.stderr().writeStreamingAll(io, "note: bs doc reads build.zig's modules in Zig 0.17 projects only\n");
        return;
    }
    const self_exe = try std.process.executablePathAlloc(io, arena);
    const result = std.process.run(arena, io, .{
        .argv = &.{ self_exe, "build", "--print-configuration-path" },
        .environ_map = init.environ_map,
    }) catch |err| main.fatal("failed to run bs build: {t}", .{err});
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        try Io.File.stderr().writeStreamingAll(io, result.stderr);
        try Io.File.stderr().writeStreamingAll(io, "note: bs doc could not configure build.zig, so only std is available\n");
        return;
    }
    const conf_path = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    var file = try Io.Dir.cwd().openFile(io, conf_path, .{});
    defer file.close(io);
    const c = try Configuration.loadFile(arena, io, file);

    var seen: std.array_hash_map.Auto(Configuration.Module.Index, void) = .empty;
    for (c.steps) |*step| {
        if (step.flags(&c).tag != .compile) continue;
        const comp = step.extended.get(c.extra).compile;
        try d.addModule(&c, cwd, dir, comp.root_name.slice(&c), comp.root_module);
        try seen.put(arena, comp.root_module, {});
        // Breadth-first through the imports, each module once.
        var next = seen.count() - 1;
        while (next < seen.count()) : (next += 1) {
            const imports = seen.keys()[next].get(&c).import_table.get(&c).imports.mal;
            for (imports.items(.name), imports.items(.module)) |name, module| {
                try d.addModule(&c, cwd, dir, name.slice(&c), module);
                try seen.put(arena, module, {});
            }
        }
    }
}

/// Adds `module` as `name` unless a module has that name, if its root is
/// a Zig source file whose path the configuration fixes. As the runner
/// resolves them (`Maker.resolveLazyPath`): a package's root path is
/// relative to the working directory, `cwd`.
fn addModule(d: *Doc, c: *const Configuration, cwd: []const u8, build_root: []const u8, name: []const u8, module: Configuration.Module.Index) !void {
    if (d.modules.contains(name)) return;
    const lazy = (module.get(c).root_source_file.unwrap() orelse return).get(c);
    const path = switch (lazy) {
        .source_path => |sp| if (sp.owner.get(c)) |pkg|
            try Io.Dir.path.resolveAlloc(d.arena, &.{ cwd, pkg.root_path.slice(c), sp.sub_path.slice(c) })
        else
            try Io.Dir.path.resolveAlloc(d.arena, &.{ build_root, sp.sub_path.slice(c) }),
        .relative => |rel| switch (rel.flags.base) {
            .cwd => try Io.Dir.path.resolveAlloc(d.arena, &.{ cwd, rel.sub_path.slice(c) }),
            else => return,
        },
        .generated => return d.generated.put(d.arena, name, {}),
    };
    if (!std.mem.endsWith(u8, path, ".zig")) return;
    try d.modules.put(d.arena, name, path);
}

/// The index of the file at the absolute `path`, parsed on first use.
fn load(d: *Doc, path: []const u8) !u32 {
    if (d.files.getIndex(path)) |index| return @intCast(index);
    const bytes = try Io.Dir.cwd().readFileAlloc(d.io, path, d.arena, .limited(64 << 20));
    const source = try d.arena.dupeSentinel(u8, bytes, 0);
    const parsed = try d.arena.create(Ast);
    parsed.* = try Ast.parse(d.arena, source, .{ .mode = .zig, .language = d.lang });
    try d.files.put(d.arena, path, parsed);
    return @intCast(d.files.count() - 1);
}

fn tree(d: *const Doc, file: u32) *const Ast {
    return d.files.values()[file];
}

/// The member nodes of `container`, which may point into `buf`.
fn containerMembers(t: *const Ast, buf: *[2]Ast.Node.Index, container: Ast.Node.Index) []const Ast.Node.Index {
    if (container == .root) return t.rootDecls();
    return (t.fullContainerDecl(buf, container) orelse return &.{}).ast.members;
}

/// The name of the variable or function declaration `node`, else null.
fn declName(t: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    if (t.fullVarDecl(node)) |v| return t.tokenSlice(v.ast.mut_token + 1);
    var buf: [1]Ast.Node.Index = undefined;
    if (t.fullFnProto(&buf, node)) |f| return t.tokenSlice(f.name_token orelse return null);
    return null;
}

fn isPub(d: *const Doc, decl: Decl) bool {
    const t = d.tree(decl.file);
    if (decl.node == .root) return true;
    if (t.fullVarDecl(decl.node)) |v| return v.visib_token != null;
    var buf: [1]Ast.Node.Index = undefined;
    if (t.fullFnProto(&buf, decl.node)) |f| return f.visib_token != null;
    return false;
}

/// The member declaration `name` of `view`, public or not.
fn child(d: *Doc, view: Members, name: []const u8) ?Decl {
    const t = d.tree(view.file);
    var buf: [2]Ast.Node.Index = undefined;
    for (containerMembers(t, &buf, view.container)) |member| {
        const member_name = declName(t, member) orelse continue;
        if (std.mem.eql(u8, member_name, name)) return .{ .file = view.file, .node = member, .scope = view.scope };
    }
    return null;
}

/// The scope that declarations in `container`, the value of `decl`, see.
fn inner(d: *Doc, decl: Decl, container: Ast.Node.Index) []const Scope {
    const scope = d.arena.alloc(Scope, decl.scope.len + 1) catch @panic("OOM");
    @memcpy(scope[0..decl.scope.len], decl.scope);
    scope[decl.scope.len] = .{ .decl = decl.node, .container = container };
    return scope;
}

/// The members `decl` has, through aliases: its container's, or for a
/// type function those of the container it returns. Null for others.
fn members(d: *Doc, start: Decl) ?Members {
    var decl = start;
    for (0..max_hops) |_| {
        switch (d.categorize(decl)) {
            .alias => |target| decl = target,
            .namespace, .container => |node| return .{ .file = decl.file, .container = node, .scope = d.inner(decl, node) },
            .type_function => {
                const t = d.tree(decl.file);
                const ret = returnExpr(t, decl.node) orelse return null;
                if (containerKind(t, ret) != null) return .{ .file = decl.file, .container = ret, .scope = d.inner(decl, ret) };
                // `return Other(T, ...)`: the members of the type function
                // it calls.
                var buf: [1]Ast.Node.Index = undefined;
                const call = t.fullCall(&buf, ret) orelse return null;
                switch (d.categorizeExpr(decl.file, decl.scope, call.ast.fn_expr)) {
                    .alias => |target| decl = target,
                    else => return null,
                }
            },
            else => return null,
        }
    }
    return null;
}

/// The expression of the first `return` statement in the body of the
/// function declaration `node`.
fn returnExpr(t: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    if (t.nodeTag(node) != .fn_decl) return null;
    const body = t.nodeData(node).node_and_node[1];
    var buf: [2]Ast.Node.Index = undefined;
    for (t.blockStatements(&buf, body) orelse return null) |stmt| {
        if (t.nodeTag(stmt) == .@"return") return t.nodeData(stmt).opt_node.unwrap();
    }
    return null;
}

/// `.namespace` or `.container` for a container expression, else null.
fn containerKind(t: *const Ast, node: Ast.Node.Index) ?std.meta.Tag(Category) {
    if (node == .root) return if (hasFields(t, t.rootDecls())) .container else .namespace;
    var buf: [2]Ast.Node.Index = undefined;
    const full = t.fullContainerDecl(&buf, node) orelse return null;
    if (t.tokenTag(full.ast.main_token) != .keyword_struct) return .container;
    return if (hasFields(t, full.ast.members)) .container else .namespace;
}

fn hasFields(t: *const Ast, member_nodes: []const Ast.Node.Index) bool {
    for (member_nodes) |m| if (t.fullContainerField(m) != null) return true;
    return false;
}

fn categorize(d: *Doc, decl: Decl) Category {
    if (d.depth == max_hops) return .global_const;
    d.depth += 1;
    defer d.depth -= 1;
    const t = d.tree(decl.file);
    if (decl.node == .root) return if (containerKind(t, .root).? == .container) .{ .container = .root } else .{ .namespace = .root };
    if (t.fullVarDecl(decl.node)) |v| {
        if (t.tokenTag(v.ast.mut_token) == .keyword_var) return .global_variable;
        return d.categorizeExpr(decl.file, decl.scope, v.ast.init_node.unwrap() orelse return .global_const);
    }
    var buf: [1]Ast.Node.Index = undefined;
    const f = t.fullFnProto(&buf, decl.node) orelse return .global_const;
    const ret = f.ast.return_type.unwrap() orelse return .function;
    return switch (d.categorizeExpr(decl.file, decl.scope, ret)) {
        .namespace, .container, .error_set, .type_type => .type_function,
        else => .function,
    };
}

/// The category of `decl`, following aliases.
fn categorizeDeep(d: *Doc, start: Decl) Category {
    var decl = start;
    for (0..max_hops) |_| switch (d.categorize(decl)) {
        .alias => |target| decl = target,
        else => |cat| return cat,
    };
    return .global_const;
}

fn categorizeExpr(d: *Doc, file: u32, scope: []const Scope, node: Ast.Node.Index) Category {
    const t = d.tree(file);
    if (containerKind(t, node)) |kind| return if (kind == .container) .{ .container = node } else .{ .namespace = node };
    switch (t.nodeTag(node)) {
        .error_set_decl, .merge_error_sets => return .error_set,
        .identifier => {
            const name = t.tokenSlice(t.nodeMainToken(node));
            if (std.mem.eql(u8, name, "type")) return .type_type;
            for ([_][]const u8{ "true", "false", "null", "undefined" }) |p| if (std.mem.eql(u8, name, p)) return .primitive;
            if (std.zig.primitives.isPrimitive(name)) return .type;
            var i = scope.len;
            while (i > 0) {
                i -= 1;
                const view: Members = .{ .file = file, .container = scope[i].container, .scope = scope[0 .. i + 1] };
                if (d.child(view, name)) |decl| return .{ .alias = decl };
            }
            return .global_const;
        },
        .field_access => {
            const object, const field = t.nodeData(node).node_and_token;
            switch (d.categorizeExpr(file, scope, object)) {
                .alias => |target| if (d.members(target)) |view| if (d.child(view, t.tokenSlice(field))) |decl| return .{ .alias = decl },
                else => {},
            }
            return .global_const;
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const name = t.tokenSlice(t.nodeMainToken(node));
            var buf: [2]Ast.Node.Index = undefined;
            const params = t.builtinCallParams(&buf, node).?;
            if (std.mem.eql(u8, name, "@This")) {
                if (scope.len == 0) return .global_const;
                const last = scope[scope.len - 1];
                return .{ .alias = .{ .file = file, .node = last.decl, .scope = scope[0 .. scope.len - 1] } };
            }
            if (std.mem.eql(u8, name, "@import") and params.len != 0 and t.nodeTag(params[0]) == .string_literal) {
                const target = d.resolveImport(file, t.tokenSlice(t.nodeMainToken(params[0]))) orelse return .global_const;
                return .{ .alias = .{ .file = target, .node = .root, .scope = &.{} } };
            }
            return .global_const;
        },
        .call_one, .call_one_comma, .call, .call_comma => {
            var buf: [1]Ast.Node.Index = undefined;
            const call = t.fullCall(&buf, node).?;
            return switch (d.categorizeExpr(file, scope, call.ast.fn_expr)) {
                .type_function => .type,
                .alias => |target| if (d.categorizeDeep(target) == .type_function) .type else .global_const,
                else => .global_const,
            };
        },
        // A choice between types is a type.
        .if_simple, .@"if" => {
            const full = t.fullIf(node).?;
            const else_expr = full.ast.else_expr.unwrap() orelse return .global_const;
            return if (d.isTypeExpr(file, scope, full.ast.then_expr) or d.isTypeExpr(file, scope, else_expr)) .type else .global_const;
        },
        .@"switch", .switch_comma => {
            for (t.fullSwitch(node).?.ast.cases) |case| {
                if (d.isTypeExpr(file, scope, t.fullSwitchCase(case).?.ast.target_expr)) return .type;
            }
            return .global_const;
        },
        .optional_type,
        .array_type,
        .array_type_sentinel,
        .ptr_type_aligned,
        .ptr_type_sentinel,
        .ptr_type,
        .ptr_type_bit_range,
        .anyframe_type,
        .fn_proto,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto_simple,
        => return .type,
        else => return .global_const,
    }
}

fn isTypeExpr(d: *Doc, file: u32, scope: []const Scope, node: Ast.Node.Index) bool {
    const cat = switch (d.categorizeExpr(file, scope, node)) {
        .alias => |target| d.categorizeDeep(target),
        else => |c| c,
    };
    return switch (cat) {
        .namespace, .container, .error_set, .type, .type_type, .type_function => true,
        else => false,
    };
}

/// The file `@import(literal)` in `file` names: a module, or a path
/// relative to `file`. Null for one that cannot be read, such as
/// `builtin`.
fn resolveImport(d: *Doc, file: u32, literal: []const u8) ?u32 {
    const name = std.zig.string_literal.parseAlloc(d.arena, literal) catch return null;
    if (d.modules.get(name)) |path| return d.load(path) catch null;
    if (!std.mem.endsWith(u8, name, ".zig")) return null;
    const dir = Io.Dir.path.dirname(d.files.keys()[file]).?;
    const path = Io.Dir.path.resolveAlloc(d.arena, &.{ dir, name }) catch return null;
    return d.load(path) catch null;
}

/// The name a reader would write for `decl`: its file as a module name, or
/// as a module name and its path in the module's directory, then the
/// declarations around it.
fn qualifiedName(d: *Doc, decl: Decl) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const path = d.files.keys()[decl.file];
    const named = for (d.modules.keys(), d.modules.values()) |name, root| {
        if (std.mem.eql(u8, root, path)) {
            try out.appendSlice(d.arena, name);
            break true;
        }
    } else false;
    if (!named) for (d.modules.keys(), d.modules.values()) |name, root| {
        const root_dir = Io.Dir.path.dirname(root).?;
        if (!std.mem.startsWith(u8, path, root_dir) or path.len <= root_dir.len or path[root_dir.len] != '/') continue;
        const rel = path[root_dir.len + 1 .. path.len - ".zig".len];
        try out.print(d.arena, "{s}.", .{name});
        for (rel) |ch| try out.append(d.arena, if (ch == '/') '.' else ch);
        break;
    } else try out.appendSlice(d.arena, path);
    const t = d.tree(decl.file);
    for (decl.scope) |s| if (s.decl != .root) try out.print(d.arena, ".{s}", .{declName(t, s.decl).?});
    if (decl.node != .root) try out.print(d.arena, ".{s}", .{declName(t, decl.node).?});
    return out.items;
}

fn line(d: *const Doc, decl: Decl) usize {
    if (decl.node == .root) return 1;
    const t = d.tree(decl.file);
    return std.zig.findLineColumn(t.source, t.tokenStart(t.nodeMainToken(decl.node))).line + 1;
}

fn print(d: *Doc, w: *Io.Writer, decl: Decl, symbol: []const u8) !void {
    try w.print("Symbol: {s}\nLocation: {s}:{d}\n", .{ symbol, d.files.keys()[decl.file], d.line(decl) });
    var target = decl;
    var cat = d.categorize(target);
    for (0..max_hops) |_| {
        target = switch (cat) {
            .alias => |next| next,
            else => break,
        };
        cat = d.categorize(target);
        try w.print("Alias Target: {s}\nTarget Location: {s}:{d}\n", .{ try d.qualifiedName(target), d.files.keys()[target.file], d.line(target) });
    }
    try w.print("Category: {t}\n", .{cat});
    const t = d.tree(target.file);
    switch (cat) {
        .function, .type_function => {
            var buf: [1]Ast.Node.Index = undefined;
            const f = t.fullFnProto(&buf, target.node).?;
            const proto = if (t.nodeTag(target.node) == .fn_decl) t.nodeData(target.node).node_and_node[0] else target.node;
            try w.print("Signature: {s}\n", .{try d.sourceText(target.file, f.firstToken(), t.lastToken(proto))});
        },
        .global_const, .global_variable, .primitive, .error_set, .type, .type_type => if (target.node != .root) {
            const v = t.fullVarDecl(target.node).?;
            try w.print("Declaration: {s};\n", .{try d.sourceText(target.file, v.firstToken(), t.lastToken(target.node))});
        },
        .namespace, .container => |node| {
            const kind = if (node == .root) "struct" else t.tokenSlice(t.nodeMainToken(node));
            try w.print("Type: {s}{s}\n", .{ if (cat == .namespace) "namespace" else kind, if (node == .root) " (file root)" else "" });
        },
        .alias => {},
    }

    // The declaration's own doc comments, else its target's; a file's
    // root has its `//!` comments.
    const docs = try d.docComments(decl);
    const target_docs = try d.docComments(target);
    const text = if (target.node == .root or docs.len == 0) target_docs else docs;
    if (text.len != 0) try w.print("\nDocumentation:\n{s}", .{text});

    const has_members = if (d.members(target)) |view| try d.printMembers(w, view) else false;
    if (cat == .type_function and !has_members) {
        try w.writeAll("\nSource:\n");
        var lines = std.mem.splitScalar(u8, try d.sourceText(target.file, t.firstToken(target.node), t.lastToken(target.node)), '\n');
        while (lines.next()) |l| try w.print("  {s}\n", .{l});
    }
}

/// The doc comments of `decl`, one line each, after a space: `///` ones
/// before a member, `//!` ones at the top of a file for a file's root.
fn docComments(d: *Doc, decl: Decl) ![]const u8 {
    const t = d.tree(decl.file);
    var out: std.ArrayList(u8) = .empty;
    var tok: Ast.TokenIndex = if (decl.node == .root) 0 else firstDocComment(t, t.firstToken(decl.node)) orelse return "";
    const tag: frontend.Token.Tag = if (decl.node == .root) .container_doc_comment else .doc_comment;
    while (tok < t.tokens.len and t.tokenTag(tok) == tag) : (tok += 1) try appendDocLine(d.arena, &out, " ", t.tokenSlice(tok));
    return out.items;
}

/// Appends the text of the doc comment `comment` after `indent`, without
/// trailing spaces.
fn appendDocLine(arena: Allocator, out: *std.ArrayList(u8), indent: []const u8, comment: []const u8) !void {
    try out.print(arena, "{s}{s}", .{ indent, comment[3..] });
    while (out.items.len != 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
    try out.append(arena, '\n');
}

/// The first of the `///` comments just before the token `first`.
fn firstDocComment(t: *const Ast, first: Ast.TokenIndex) ?Ast.TokenIndex {
    var tok = first;
    while (tok > 0 and t.tokenTag(tok - 1) == .doc_comment) tok -= 1;
    return if (tok == first) null else tok;
}

/// The source from token `first` through token `last`, with the
/// indentation of `first`'s line taken off the lines after it.
fn sourceText(d: *Doc, file: u32, first: Ast.TokenIndex, last: Ast.TokenIndex) ![]const u8 {
    const t = d.tree(file);
    const start = t.tokenStart(first);
    const end = t.tokenStart(last) + t.tokenSlice(last).len;
    const indent = start - (if (std.mem.findScalarLast(u8, t.source[0..start], '\n')) |nl| nl + 1 else 0);
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, t.source[start..end], '\n');
    try out.appendSlice(d.arena, lines.first());
    while (lines.next()) |l| {
        var cut: usize = 0;
        while (cut < indent and cut < l.len and l[cut] == ' ') cut += 1;
        try out.print(d.arena, "\n{s}", .{l[cut..]});
    }
    return out.items;
}

/// Prints the fields of `view` and its public declarations by kind.
/// Returns whether it printed any.
fn printMembers(d: *Doc, w: *Io.Writer, view: Members) !bool {
    const t = d.tree(view.file);
    const Kind = enum { fields, type_functions, types, functions, constants, variables };
    const headings = [_][]const u8{ "Fields", "Type Functions", "Types", "Functions", "Constants", "Variables" };
    var lists: [headings.len]std.ArrayList(u8) = @splat(.empty);
    var buf: [2]Ast.Node.Index = undefined;
    for (containerMembers(t, &buf, view.container)) |member| {
        if (t.fullContainerField(member)) |field| {
            const list = &lists[@backingInt(Kind.fields)];
            const name = t.tokenSlice(field.ast.main_token);
            if (field.ast.type_expr.unwrap()) |ty| {
                try list.print(d.arena, "  {s}: {s}\n", .{ name, try d.sourceText(view.file, t.firstToken(ty), t.lastToken(ty)) });
            } else try list.print(d.arena, "  {s}\n", .{name});
            if (firstDocComment(t, field.firstToken())) |first| {
                var tok = first;
                while (t.tokenTag(tok) == .doc_comment) : (tok += 1) try appendDocLine(d.arena, list, "      ", t.tokenSlice(tok));
            }
            continue;
        }
        const name = declName(t, member) orelse continue;
        const decl: Decl = .{ .file = view.file, .node = member, .scope = view.scope };
        if (!d.isPub(decl)) continue;
        const kind: Kind = switch (d.categorizeDeep(decl)) {
            .function => .functions,
            .type_function => .type_functions,
            .namespace, .container, .error_set, .type, .type_type => .types,
            .global_variable => .variables,
            .global_const, .primitive, .alias => .constants,
        };
        try lists[@backingInt(kind)].print(d.arena, "  {s}\n", .{name});
    }
    var any = false;
    for (headings, lists) |heading, list| {
        if (list.items.len == 0) continue;
        try w.print("\n{s}:\n{s}", .{ heading, list.items });
        any = true;
    }
    if (any) try w.writeByte('\n');
    return any;
}
