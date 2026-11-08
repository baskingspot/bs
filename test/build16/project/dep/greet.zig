const std = @import("std");

pub fn hello() void {
    std.debug.print("hello from a 0.16 dependency\n", .{});
}
