//! signal: ABRT
//! stderr-contains: "panic: reached unreachable code\n"
//! stderr-contains: "std/debug.zig:442:14: 0x"
//! stderr-contains: " in assert (std.zig)\n"
//! stderr-contains: "panic_module_nested.zig:23:21: 0x"
//! stderr-contains: " in lessThan (panic_module_nested.zig)\n"
//! stderr-contains: "std/sort.zig:958:21: 0x"
//! stderr-contains: " (std.zig)\n"
//! stderr-contains: "panic_module_nested.zig:30:48: 0x"
//! stderr-contains: " in main (panic_module_nested.zig)\n"

// The modules of frames inlined across modules and back: the backend
// inlines this module's `lessThan` into std's `isSorted`, and std's
// `assert` into `lessThan` there, so std's function holds this module's
// code, which holds std's again. Each frame's module is that of its
// function, as in upstream's trace and bs's without inlining, which `zig
// build test` compares with this one; upstream names `isSorted`'s frame
// after the generic instance (`isSorted__func_789`), which is why only its
// module is checked.
const std = @import("std");

fn lessThan(_: void, a: u8, b: u8) bool {
    std.debug.assert(a != 7);
    return a < b;
}

pub fn main() void {
    var a = [_]u8{ 1, 7, 3 };
    _ = &a;
    std.debug.print("{}\n", .{std.sort.isSorted(u8, &a, {}, lessThan)});
}
