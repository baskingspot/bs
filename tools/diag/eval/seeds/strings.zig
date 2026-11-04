const std = @import("std");

pub fn main() void {
    const text = "  alpha beta,gamma  ";
    const trimmed = std.mem.trim(u8, text, " ");
    var words = std.mem.tokenizeScalar(u8, trimmed, ' ');
    while (words.next()) |w| {
        var parts = std.mem.splitScalar(u8, w, ',');
        while (parts.next()) |p| std.debug.print("[{s}]\n", .{p});
    }
    const pos = std.mem.find(u8, text, "beta") orelse 0;
    const comma = std.mem.findScalar(u8, text, ',') orelse 0;
    const right = std.mem.trimEnd(u8, text, " ");
    std.debug.print("{d} {d} {d} {}\n", .{ pos, comma, right.len, std.mem.startsWith(u8, trimmed, "alpha") });
    std.debug.print("{}\n", .{std.mem.eql(u8, "a", "a")});
}
