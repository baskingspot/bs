const std = @import("std");

test "Allocating" {
    var a: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer a.deinit();
    try a.writer.writeAll("x");
    try std.testing.expectEqualStrings("x", a.written());
}
