const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    for (args, 0..) |arg, i| {
        std.debug.print("{d}: {s}\n", .{ i, arg });
    }
    if (args.len > 5) std.process.exit(1);
}
