//! `frontend_hash <dir> <out.zig> <out.d>`: writes `pub const hash: u64`,
//! a hash of every .zig file under `dir` (bs's vendored parser and AstGen),
//! and a dep file naming them, so the build reruns it when one changes.
//! The ZIR cache salts its keys with it (src/Frontend.zig): ZIR that one
//! AstGen wrote is not reused by a bs with another.

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const root = args[1];
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var paths: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".zig")) try paths.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sortUnstable([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var h: std.hash.Wyhash = .init(0);
    var dep: std.ArrayList(u8) = .empty;
    try dep.print(arena, "{s}:", .{args[2]});
    for (paths.items) |p| {
        const data = try dir.readFileAlloc(io, p, arena, .unlimited);
        h.update(p);
        h.update(std.mem.asBytes(&data.len));
        h.update(data);
        try dep.print(arena, " {s}/{s}", .{ root, p });
    }
    try dep.append(arena, '\n');
    const cwd = Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = try std.fmt.allocPrint(arena, "pub const hash: u64 = 0x{x:0>16};\n", .{h.final()}) });
    try cwd.writeFile(io, .{ .sub_path = args[3], .data = dep.items });
}
