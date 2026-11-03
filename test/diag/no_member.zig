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
//   hint: std.io is now std.Io: take `init: std.process.Init` in main, then `var w = std.Io.File.stdout().writer(init.io, &buffer);`, print with `w.interface.print(...)` and `w.interface.flush()`; std.debug.print writes to stderr without io
// 1 error
