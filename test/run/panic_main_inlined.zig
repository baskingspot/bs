//! signal: ABRT
//! stderr-contains: "panic: boom\n"
//! stderr-contains: "panic_main_inlined.zig:20:17: 0x"
//! stderr-contains: " in leaf (panic_main_inlined.zig)\n"
//! stderr-contains: "panic_main_inlined.zig:23:6: 0x"
//! stderr-contains: " in apply (panic_main_inlined.zig)\n"
//! stderr-contains: "panic_main_inlined.zig:31:10: 0x"
//! stderr-contains: " in main (panic_main_inlined.zig)\n"
//! stderr-contains: " in callMain (std.zig)\n"

// The modules of the frames of `main` when the backend inlines it into
// std's `callMain`, with `twice` and `leaf` inlined into it and Sema's
// inline call of `apply` between them: every frame of this module is this
// module's, as in upstream's trace and bs's without inlining, which `zig
// build test` compares with this one. Upstream folds `twice` into
// `apply`'s frame, as for any Sema inline call.
const std = @import("std");

fn leaf(a: u32) void {
    if (a == 3) @panic("boom");
}
inline fn apply(comptime f: fn (u32) void, x: u32) void {
    f(x);
}
fn twice(comptime f: fn (u32) void, x: u32) void {
    apply(f, x);
}
pub fn main() void {
    var x: u32 = 3;
    _ = &x;
    twice(leaf, x);
}
