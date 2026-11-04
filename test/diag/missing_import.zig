const missing = @import("does_not_exist.zig");

pub fn main() void {
    _ = missing;
}

// error
// does_not_exist.zig:1:1: error[bad-import]: unable to load "does_not_exist.zig": FileNotFound
//   note missing_import.zig:1:25: file imported here
// 1 error
