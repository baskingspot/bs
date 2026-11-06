//! signal: ABRT
//! targets: x86_64-linux aarch64-linux aarch64-macos
//! stderr-contains: "panic: index out of bounds: index 7, len 3\n"
//! stderr-contains: "panic_through_call.zig:20:13: 0x"
//! stderr-contains: " in deep ("
//! stderr-contains: "panic_through_call.zig:24:16: 0x"
//! stderr-contains: " in inner ("
//! stderr-contains: "panic_through_call.zig:28:17: 0x"
//! stderr-contains: " in outer ("
//! stderr-contains: "panic_through_call.zig:34:37: 0x"
//! stderr-contains: " in main ("
// A panic in a function that code the backend inlined calls (`inner`
// inlined into `outer` and both into `main`, each keeping the call it
// cannot inline): the call goes through stubs that return, so the stack
// trace has every frame, as upstream's, which `zig build test` also
// compares with bs's trace of the program built without inlining.
const std = @import("std");

noinline fn deep(s: []const u8, i: usize) u8 {
    return s[i];
}

fn inner(s: []const u8, i: usize) u8 {
    return deep(s, i + 1) +% 1;
}

fn outer(s: []const u8, i: usize) u8 {
    return inner(s, i + 1) | 1;
}

pub fn main() void {
    var i: usize = 5;
    _ = &i;
    std.debug.print("{d}\n", .{outer("abc", i)});
}
