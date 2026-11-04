//! Links copy.c with -lc; glibc, the C code and the Zig code all use the
//! executable's copy of `stdout`. Upstream prints the same.
const std = @import("std");
extern fn c_stdout_addr() *anyopaque;
extern fn c_copy_test() c_int;
extern var stdout: *anyopaque;
pub fn main() void {
    const env = c_copy_test();
    std.debug.print("{d} {}\n", .{ env, @intFromPtr(&stdout) == @intFromPtr(c_stdout_addr()) });
}
