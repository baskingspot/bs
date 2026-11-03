const std = @import("std");

pub fn main() void {
    const out = std.io.getStdOut();
    _ = out;
}

// error
// no_member.zig:4:21: error[no-member]: root source file struct 'std' has no member named 'io'
//   | const out = std.io.getStdOut();
//   note std/std.zig:1:1: struct declared here
//   candidates: Io
// 1 error
