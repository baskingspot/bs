const std = @import("std");

extern fn bs_add(a: u32, b: u32) u32;
extern fn bs_call_c(x: u32) u32;
extern fn bs_overflow(x: u8) u8;
extern var shared: u64;

export fn c_twice(x: u32) u32 {
    return 2 * x;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1) _ = bs_overflow(10);
    var buf: [64]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);
    try out.interface.print("{d} {d} {d}\n", .{ bs_add(5, 1), shared, bs_call_c(20) });
    try out.interface.flush();
}
