//! Source to ZIR. Loads the root file, parses it with `std.zig.Ast`, lowers it
//! with `std.zig.AstGen`, and follows its `@import`s until every reachable
//! file has ZIR. Like upstream, this happens eagerly for all reachable files;
//! semantic analysis later touches only what it references.
//!
//! Files live in one flat table indexed by `File.Index` so that later stages
//! (Sema, the on-disk cache) can refer to them by a stable u32.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Zir = std.zig.Zir;
const AstGen = std.zig.AstGen;

const Frontend = @This();

gpa: Allocator,
io: Io,
/// Directory containing `std/std.zig` for the pinned Zig release.
zig_lib_dir: []const u8,
files: std.ArrayList(File) = .empty,
/// Maps a canonical (module-relative) path to its file.
file_map: std.StringHashMapUnmanaged(File.Index) = .empty,
modules: std.ArrayList(Module) = .empty,

pub const Module = struct {
    /// Name used in `@import("name")`.
    name: []const u8,
    /// Directory that the module's root file and its relative imports live in.
    root_dir: []const u8,
    /// Root file path, relative to `root_dir`.
    root_file: []const u8,

    pub const Index = enum(u32) {
        root,
        std,
        _,
    };
};

pub const File = struct {
    module: Module.Index,
    /// Path relative to the module's `root_dir`.
    sub_path: []const u8,
    /// Path shown in diagnostics.
    display_path: []const u8,
    source: [:0]const u8,
    tree: Ast,
    zir: Zir,

    pub const Index = enum(u32) { _ };
};

pub fn init(gpa: Allocator, io: Io, zig_lib_dir: []const u8, root_src_path: []const u8) !Frontend {
    var fe: Frontend = .{ .gpa = gpa, .io = io, .zig_lib_dir = zig_lib_dir };
    errdefer fe.deinit();
    const root_dir = std.fs.path.dirname(root_src_path) orelse ".";
    try fe.modules.append(gpa, .{
        .name = "root",
        .root_dir = try gpa.dupe(u8, root_dir),
        .root_file = try gpa.dupe(u8, std.fs.path.basename(root_src_path)),
    });
    try fe.modules.append(gpa, .{
        .name = "std",
        .root_dir = try std.fs.path.join(gpa, &.{ zig_lib_dir, "std" }),
        .root_file = try gpa.dupe(u8, "std.zig"),
    });
    return fe;
}

pub fn deinit(fe: *Frontend) void {
    const gpa = fe.gpa;
    for (fe.files.items) |*f| {
        f.zir.deinit(gpa);
        f.tree.deinit(gpa);
        gpa.free(f.source);
        gpa.free(f.sub_path);
        gpa.free(f.display_path);
    }
    fe.files.deinit(gpa);
    var it = fe.file_map.keyIterator();
    while (it.next()) |key| gpa.free(key.*);
    fe.file_map.deinit(gpa);
    for (fe.modules.items) |m| {
        gpa.free(m.root_dir);
        gpa.free(m.root_file);
    }
    fe.modules.deinit(gpa);
}

pub fn file(fe: *const Frontend, index: File.Index) *const File {
    return &fe.files.items[@backingInt(index)];
}

pub fn module(fe: *const Frontend, index: Module.Index) *const Module {
    return &fe.modules.items[@backingInt(index)];
}

/// Loads, parses, and lowers the root file and every file reachable from it
/// through `@import`. Returns false and adds messages to `errors` if any file
/// failed to lower.
pub fn loadAll(fe: *Frontend, errors: *std.zig.ErrorBundle.Wip) !bool {
    var ok = true;
    _ = try fe.ensureFile(.root, fe.module(.root).root_file);
    var i: usize = 0;
    while (i < fe.files.items.len) : (i += 1) {
        const f = &fe.files.items[i];
        if (f.zir.hasCompileErrors()) {
            try errors.addZirErrorMessages(f.zir, f.tree, f.source, f.display_path);
            if (f.zir.loweringFailed()) {
                ok = false;
                continue;
            }
        }
        const zir = f.zir;
        const importer_module = f.module;
        const importer_sub_path = f.sub_path;
        const imports_index = zir.extra[@backingInt(Zir.ExtraIndex.imports)];
        if (imports_index == 0) continue;
        const header = zir.extraData(Zir.Inst.Imports, imports_index);
        var extra_index = header.end;
        for (0..header.data.imports_len) |_| {
            const item = zir.extraData(Zir.Inst.Imports.Item, extra_index);
            extra_index = item.end;
            const name = zir.nullTerminatedString(item.data.name);
            if (std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".zon")) {
                // TODO: ZON imports go through ZonGen, not AstGen.
                if (std.mem.endsWith(u8, name, ".zon")) continue;
                const dir = std.fs.path.dirname(importer_sub_path) orelse "";
                const sub_path = try std.fs.path.resolvePosix(fe.gpa, &.{ dir, name });
                defer fe.gpa.free(sub_path);
                _ = try fe.ensureFile(importer_module, sub_path);
            } else if (std.mem.eql(u8, name, "std")) {
                _ = try fe.ensureFile(.std, fe.module(.std).root_file);
            } else if (std.mem.eql(u8, name, "root")) {
                _ = try fe.ensureFile(.root, fe.module(.root).root_file);
            } else {
                // `builtin` is generated from the target by Sema's driver;
                // unknown modules are reported by Sema only if the import is
                // actually analyzed, matching upstream.
            }
        }
    }
    return ok;
}

fn ensureFile(fe: *Frontend, mod_index: Module.Index, sub_path: []const u8) !File.Index {
    const gpa = fe.gpa;
    const mod = fe.module(mod_index);
    const key = try std.fmt.allocPrint(gpa, "{d}:{s}", .{ @backingInt(mod_index), sub_path });
    const gop = try fe.file_map.getOrPut(gpa, key);
    if (gop.found_existing) {
        gpa.free(key);
        return gop.value_ptr.*;
    }
    errdefer {
        _ = fe.file_map.remove(key);
        gpa.free(key);
    }

    const display_path = try std.fs.path.join(gpa, &.{ mod.root_dir, sub_path });
    errdefer gpa.free(display_path);
    const source = Io.Dir.cwd().readFileAllocOptions(fe.io, display_path, gpa, .unlimited, .of(u8), 0) catch |err|
        return fatalFile(display_path, err);
    errdefer gpa.free(source);
    var tree = try Ast.parse(gpa, source, .{ .mode = .zig });
    errdefer tree.deinit(gpa);
    const zir = try AstGen.generate(gpa, tree);

    const index: File.Index = @fromBackingInt(@intCast(fe.files.items.len));
    try fe.files.append(gpa, .{
        .module = mod_index,
        .sub_path = try gpa.dupe(u8, sub_path),
        .display_path = display_path,
        .source = source,
        .tree = tree,
        .zir = zir,
    });
    gop.value_ptr.* = index;
    return index;
}

fn fatalFile(path: []const u8, err: anyerror) noreturn {
    std.process.fatal("unable to load '{s}': {t}", .{ path, err });
}

test "loads a file and its imports" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "const a = @import(\"a.zig\");\npub fn main() void { a.f(); }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "pub fn f() void {}\n" });
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/main.zig", .{tmp.sub_path});
    defer gpa.free(root);

    var fe: Frontend = try .init(gpa, io, "/nonexistent", root);
    defer fe.deinit();
    var errors: std.zig.ErrorBundle.Wip = try .init(gpa);
    defer errors.deinit();
    try std.testing.expect(try fe.loadAll(&errors));
    try std.testing.expectEqual(2, fe.files.items.len);
    try std.testing.expectEqualStrings("a.zig", fe.file(@fromBackingInt(@intCast(1))).sub_path);
}
