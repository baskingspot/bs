// For `zap run`: prints its arguments and exits with their count + 40.
const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var buf: [256]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);
    for (args[1..]) |a| try out.interface.print("[{s}]", .{a});
    try out.interface.print("\n", .{});
    try out.interface.flush();
    return @intCast(args.len - 1 + 40);
}
