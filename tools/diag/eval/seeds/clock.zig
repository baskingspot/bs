const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const start = std.Io.Clock.now(.awake, io);
    var seed_bytes: [8]u8 = undefined;
    io.random(&seed_bytes);
    const seed = std.mem.readInt(u64, &seed_bytes, .little);
    const elapsed = start.durationTo(std.Io.Clock.now(.awake, io));
    const wall = std.Io.Clock.now(.real, io).toSeconds();
    std.debug.print("{d} {d} {d}\n", .{ seed % 10, elapsed.toNanoseconds(), wall });
}
