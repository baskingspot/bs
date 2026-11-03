//! `-femit-docs`: the autodocs directory upstream's compiler writes
//! (`docsCopyFallible` and `workerDocsWasm` in upstream's
//! src/Compilation.zig): `index.html` and `main.js` from the zig lib
//! directory's `docs/`, `sources.tar` with the .zig files of every module
//! in the compilation's graph, and `main.wasm`, the viewer.
//!
//! The viewer is the same for every project: lib/docs/wasm compiled for
//! wasm32 in ReleaseSmall. zap has no wasm backend, so zap's build compiles
//! it with the upstream zig that builds zap, from zap's default zig lib
//! directory, and embeds it (`docs_wasm`). With another lib directory
//! (`--zig-lib-dir`), the html and js come from that directory and the
//! viewer stays the embedded one.
//!
//! Copyright (c) Zig contributors. MIT licensed (see upstream/LICENSE).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const main = @import("main.zig");

const viewer = @embedFile("docs_wasm");

/// Writes the docs of the compilation `opts` describes, whose root module
/// is named `root_name`, into the directory `out_path`.
pub fn emit(gpa: Allocator, io: Io, zig_lib_dir: []const u8, out_path: []const u8, root_name: []const u8, opts: *const main.Options) !void {
    var out_dir = try Io.Dir.cwd().createDirPathOpen(io, out_path, .{});
    defer out_dir.close(io);
    var lib_dir = try Io.Dir.cwd().openDir(io, zig_lib_dir, .{});
    defer lib_dir.close(io);
    for ([_][]const u8{ "docs/main.js", "docs/index.html" }) |sub_path|
        try lib_dir.copyFile(sub_path, out_dir, std.fs.path.basename(sub_path), io, .{});
    try out_dir.writeFile(io, .{ .sub_path = "main.wasm", .data = viewer });

    // The modules, breadth-first from the root, as upstream: the root
    // module under the compilation's name, std, then each module's
    // dependencies under their names. Ids: 0 the root, 1 std, 2 + i
    // `opts.modules[i]`.
    const Seen = struct { id: usize, name: []const u8, dir: []const u8 };
    var seen: std.ArrayList(Seen) = .empty;
    defer seen.deinit(gpa);
    const std_dir = try std.fs.path.join(gpa, &.{ zig_lib_dir, "std" });
    defer gpa.free(std_dir);
    const std_root = try std.fs.path.resolve(gpa, &.{ zig_lib_dir, "std", "std.zig" });
    defer gpa.free(std_root);
    const root = try std.fs.path.resolve(gpa, &.{opts.root_src_path});
    defer gpa.free(root);
    if (!std.mem.eql(u8, root, std_root))
        try seen.append(gpa, .{ .id = 0, .name = root_name, .dir = std.fs.path.dirname(opts.root_src_path) orelse "." });
    try seen.append(gpa, .{ .id = 1, .name = "std", .dir = std_dir });

    var tar_file = try out_dir.createFile(io, "sources.tar", .{});
    defer tar_file.close(io);
    var buffer: [4096]u8 = undefined;
    var tar_writer = tar_file.writer(io, &buffer);
    var i: usize = 0;
    while (i < seen.items.len) : (i += 1) {
        const m = seen.items[i];
        try archiveModule(gpa, io, m.dir, m.name, &tar_writer);
        const deps = switch (m.id) {
            0 => opts.root_deps,
            1 => &.{},
            else => opts.modules[m.id - 2].deps,
        };
        for (deps) |spec| {
            const eq = std.mem.indexOfScalar(u8, spec, '=');
            const target = if (eq) |e| spec[e + 1 ..] else spec;
            const k = for (opts.modules, 0..) |om, k| {
                if (std.mem.eql(u8, om.name, target)) break k;
            } else continue;
            for (seen.items) |s| {
                if (s.id == k + 2) break;
            } else try seen.append(gpa, .{ .id = k + 2, .name = target, .dir = std.fs.path.dirname(opts.modules[k].path) orelse "." });
        }
    }
    try tar_writer.end();
}

/// Archives every .zig file under `dir` except tests (`test.zig`,
/// `*_test.zig`) as `<name>/<path>`.
fn archiveModule(gpa: Allocator, io: Io, dir: []const u8, name: []const u8, tar_writer: *Io.File.Writer) !void {
    var mod_dir = try Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer mod_dir.close(io);
    var walker = try mod_dir.walk(gpa);
    defer walker.deinit();
    var archiver: std.tar.Writer = .{ .underlying_writer = &tar_writer.interface, .prefix = name };
    var buffer: [4096]u8 = undefined;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.basename, "test.zig") or std.mem.endsWith(u8, entry.basename, "_test.zig")) continue;
        var file = try mod_dir.openFile(io, entry.path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        var reader: Io.File.Reader = .initSize(file, io, &buffer, stat.size);
        try archiver.writeFileTimestamp(entry.path, &reader, stat.mtime);
    }
}
