//! A program with Zig code, which upstream links with its own linker: it
//! lists glibc's libraries before dup_lib.c's, so getpid is glibc's.
const std = @import("std");
extern "c" fn getpid() c_int;
pub fn main() void {
    std.debug.print("{}\n", .{getpid() == 4242});
}
