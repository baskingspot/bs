//! Fails to compile unless built as Zig 0.16.

const builtin = @import("builtin");

comptime {
    if (builtin.zig_version.minor != 16) @compileError("built as Zig 0.17");
}

pub fn main() void {}
