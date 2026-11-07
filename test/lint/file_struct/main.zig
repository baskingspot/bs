//! The rules that read the file's name: `point.zig` has fields, so its
//! name should be PascalCase (Z009) and its `@This()` alias `Point` or
//! `Self` (Z021).

test {
    _ = @import("point.zig");
}

// error
// point.zig:1:1: error[style, Z009]: file 'point.zig' has top-level fields and should be PascalCase
//   | x: i32,
// point.zig:4:14: error[style, Z021]: @This() alias 'Here' should match filename 'point' or be 'Self'
//   | const Here = @This();
// 2 errors
