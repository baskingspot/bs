const std = @import("std");

fn render(w: *std.Io.Writer, name: []const u8, n: u32) !void {
    try w.print("{s}={d};", .{ name, n });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var buf: [64]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buf);
    try render(&fixed, "a", 1);
    std.debug.print("{s}\n", .{fixed.buffered()});

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try render(&aw.writer, "b", 2);
    const owned = try aw.toOwnedSlice();
    defer gpa.free(owned);
    std.debug.print("{s}\n", .{owned});
}
