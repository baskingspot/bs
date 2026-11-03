//! exit: 0
//! stderr: "edit_std 42\n"
//! rebuild-lib-without: "std/debug.zig" "/// Uses a 64-byte buffer for formatted printing which is flushed before this\n/// function returns.\n///\n"
//! An edit in std that moves `std.debug.print` and what follows it up three
//! lines, checked against a full build both ways.
const std = @import("std");

pub fn main() void {
    std.debug.print("edit_std {d}\n", .{42});
}
