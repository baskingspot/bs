const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    try io.sleep(.fromMilliseconds(1), .awake);
    var mutex: std.Io.Mutex = .init;
    try mutex.lock(io);
    mutex.unlock(io);
    std.debug.print("slept\n", .{});
}
