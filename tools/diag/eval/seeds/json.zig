const std = @import("std");

const Point = struct { x: i32, y: i32, label: []const u8 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const parsed = try std.json.parseFromSlice(Point, gpa, "{\"x\":1,\"y\":2,\"label\":\"p\"}", .{});
    defer parsed.deinit();
    const p = parsed.value;
    const text = try std.json.Stringify.valueAlloc(gpa, p, .{});
    defer gpa.free(text);
    std.debug.print("{d} {s}\n", .{ p.x + p.y, text });
}
