const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const msg = try std.fmt.allocPrint(gpa, "{d}-{s}", .{ 42, "x" });
    defer gpa.free(msg);
    var buf: [32]u8 = undefined;
    const small = try std.fmt.bufPrint(&buf, "{x}", .{255});
    const n = try std.fmt.parseInt(i32, "-17", 10);
    const f = try std.fmt.parseFloat(f64, "2.5");
    std.debug.print("{s} {s} {d} {d}\n", .{ msg, small, n, f });
}
