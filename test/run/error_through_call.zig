//! exit: 1
//! targets: x86_64-linux aarch64-linux aarch64-macos
//! stderr-contains: "error: Bad\n"
//! stderr-contains: "error_through_call.zig:18:16: 0x"
//! stderr-contains: " in parse ("
//! stderr-contains: "error_through_call.zig:23:15: 0x"
//! stderr-contains: " in check ("
//! stderr-contains: "error_through_call.zig:30:32: 0x"
//! stderr-contains: " in main ("
// An error return trace through a function that code the backend inlined
// calls (`check` inlined into `main`, keeping its call of `parse`): the
// entries are those of the program built without inlining, which
// `zig build test` compares, and upstream's.
const std = @import("std");
const Error = error{Bad};

noinline fn parse(x: u32) Error!u32 {
    if (x > 3) return error.Bad;
    return x;
}

fn check(x: u32) Error!u32 {
    const v = try parse(x +% 1);
    return v | 1;
}

pub fn main() Error!void {
    var x: u32 = 5;
    _ = &x;
    std.debug.print("{d}\n", .{try check(x)});
}
