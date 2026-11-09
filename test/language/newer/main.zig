//! Fails to compile when built as Zig 0.17.

const builtin = @import("builtin");

comptime {
    if (builtin.zig_version.minor == 17) @compileError("built as Zig 0.17");
}

pub fn main() void {}
