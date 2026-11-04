//! exit: 7
//! stderr: "before\n"
//! `pub fn main() noreturn` through std.start, whose `callMain` passes
//! `root.main()` to the inline `wrapMain`: as upstream, an argument that
//! does not return ends the call there, so neither the later arguments
//! (here a `@compileError`) nor the callee are analyzed, and no code
//! follows the call.
const std = @import("std");

inline fn wrap(r: anytype, comptime x: u8) u8 {
    if (@TypeOf(r) == noreturn) @compileError("wrap analyzed with a noreturn argument");
    return x;
}

fn die(code: u8) noreturn {
    std.process.exit(code);
}

fn pick(a: u8, b: u8) u8 {
    return a + b;
}

noinline fn later(code: u8) u8 {
    if (code == 0) return wrap(die(1), 2);
    return pick(die(code), @compileError("argument after a noreturn one analyzed"));
}

pub fn main() noreturn {
    std.debug.print("before\n", .{});
    _ = later(7);
    die(9);
}
