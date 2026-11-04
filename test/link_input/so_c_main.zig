//! Loads the shared library of C only that `bs build-lib -dynamic -lc`
//! links from so_libc.c.
const std = @import("std");
extern fn c_format(out: [*]u8, len: usize, v: c_int) c_int;

pub fn main() void {
    var buf: [32]u8 = undefined;
    for ([_]c_int{ 3, 4 }) |v| {
        const n = c_format(&buf, buf.len, v);
        std.debug.print("{s}\n", .{buf[0..@intCast(n)]});
    }
}
