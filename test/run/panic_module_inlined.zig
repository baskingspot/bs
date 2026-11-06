//! signal: ABRT
//! stderr-contains: "panic: reached unreachable code\n"
//! stderr-contains: "std/debug.zig:442:14: 0x"
//! stderr-contains: " in assert (std.zig)\n"
//! stderr-contains: "panic_module_inlined.zig:23:21: 0x"
//! stderr-contains: " in main (panic_module_inlined.zig)\n"
//! stderr-contains: " in callMain (std.zig)\n"

// A panic in std code the backend inlines into the root module's `main`,
// which stays a function of its own:
// the trace names each frame's module as upstream's does, which compiles
// `assert` as a call of a function in std's compile unit. std's traces
// take the module from the unit whose ranges hold the address, so the
// inlined code is in std's unit (docs/slop/architecture.md, "Synthetic
// panic frames"); `zig build test` also compares the whole trace with
// bs's of the program built without inlining.
const std = @import("std");
pub fn main() void {
    var a = [_]u8{ 1, 2, 3 };
    var n: usize = 1;
    _ = &n;
    std.mem.reverse(u8, a[0..n]);
    std.debug.assert(a[0] == 2);
}
