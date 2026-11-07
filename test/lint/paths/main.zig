const a = @import("covered/a.zig");
const b = @import("uncovered.zig");
const hidden = @import("covered/.hidden.zig");

test {
    _ = &a.Bad;
    _ = &b.Bad;
    _ = &hidden.Bad;
}

// error
// covered/a.zig:1:8: error[style, Z001]: function 'Bad' should be camelCase
//   | pub fn Bad() void {}
// 1 error
