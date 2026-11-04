//! Loads the shared library `bs build-lib -dynamic -lc` links from
//! so_libc.zig and so_libc.c.
const std = @import("std");
extern fn z_describe(v: c_int, out: [*]u8, len: usize) c_int;

pub fn main() void {
    var buf: [64]u8 = undefined;
    for ([_]c_int{ 7, 42 }) |v| {
        const n = z_describe(v, &buf, buf.len);
        std.debug.print("{s}\n", .{buf[0..@intCast(n)]});
    }
}
