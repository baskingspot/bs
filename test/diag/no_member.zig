const std = @import("std");

pub fn main() void {
    const out = std.io.getStdOut();
    _ = out;
}

// error
// no_member.zig:4:20: error[no-member]: 'std' has no member named 'io'
//   | const out = std.io.getStdOut();
// 1 error
