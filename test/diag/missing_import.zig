const missing = @import("does_not_exist.zig");
// Named by its base name, at its path, as upstream.
const nested = @import("sub/also_missing.zig");
// A ZON file too, as upstream, though nothing reads `config`.
const config = @import("missing.zon");

pub fn main() void {
    _ = missing;
    _ = nested;
}

// error
// missing.zon:1:1: error[bad-import]: unable to load "missing.zon": FileNotFound
//   note missing_import.zig:5:24: file imported here
// does_not_exist.zig:1:1: error[bad-import]: unable to load "does_not_exist.zig": FileNotFound
//   note missing_import.zig:1:25: file imported here
// sub/also_missing.zig:1:1: error[bad-import]: unable to load "also_missing.zig": FileNotFound
//   note missing_import.zig:3:24: file imported here
// 3 errors
