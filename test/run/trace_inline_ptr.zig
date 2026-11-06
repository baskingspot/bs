//! exit: 0
//! stderr: "3 0\n0\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux
//! Taking an inline function's address gives it a body of its own, of
//! convention `.inline`, which sets up an error return trace of its own
//! (upstream's behavior test "call inline fn through pointer"). It must
//! compile, and the code around it still sees its own trace.
const std = @import("std");

noinline fn fail(n: u32) error{Bad}!u32 {
    if (n > 0) return error.Bad;
    return 1;
}

inline fn viaInline(n: u32) error{Bad}!u32 {
    const a = fail(n) catch 7;
    return try fail(n -% a);
}

noinline fn caller(n: u32) error{Bad}!u32 {
    const f = &viaInline;
    const before = @errorReturnTrace().?.index;
    const r = f(n) catch 3;
    _ = fail(n) catch {};
    const after = @errorReturnTrace().?.index;
    std.debug.print("{} {}\n", .{ r, after - before });
    return try fail(n);
}

pub fn main() void {
    _ = caller(1) catch {};
    std.debug.print("{}\n", .{@errorReturnTrace().?.index});
}
