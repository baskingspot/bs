//! Loads the shared library `bs build-lib -dynamic` links from
//! so_lib.zig, merge.c, tls.c and so_desc.c: its exports, its C globals,
//! and its thread-locals on two threads.
const std = @import("std");
extern fn z(x: c_int) c_int;
extern fn zd(v: c_int) c_int;
extern fn c_name() [*:0]const u8;
extern var c_counter: c_int;
extern fn c_tls() c_int;

fn thread() void {
    std.debug.print("thread: {d} {d}\n", .{ c_tls(), zd(3) });
}

pub fn main() !void {
    const r = z(20);
    std.debug.print("{d} {s} {d} {d} {d}\n", .{ r, c_name(), c_counter, c_tls(), zd(3) });
    const t = try std.Thread.spawn(.{}, thread, .{});
    t.join();
}
