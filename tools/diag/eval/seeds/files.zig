const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const dir = std.Io.Dir.cwd();
    try dir.writeFile(io, .{ .sub_path = "eval-out.txt", .data = "line one\nline two\n" });
    const file = try dir.openFile(io, "eval-out.txt", .{});
    defer file.close(io);
    const stat = try file.stat(io);
    std.debug.print("size: {d}\n", .{stat.size});
    const contents = try dir.readFileAlloc(io, "eval-out.txt", gpa, .limited(1 << 20));
    defer gpa.free(contents);
    std.debug.print("{s}", .{contents});
    try dir.deleteFile(io, "eval-out.txt");
}
