//! signal: ABRT
//! stderr-contains: "panic: boom\n"
//! stderr-contains: "panic_trace_generic.zig:20:17: 0x"
//! stderr-contains: " in small__func_"
//! stderr-contains: "panic_trace_generic.zig:27:19: 0x"
//! stderr-contains: " in apply__func_"
//! stderr-contains: "panic_trace_generic.zig:32:17: 0x"
//! stderr-contains: " in main (panic_trace_generic.zig)\n"

// A frame of an instance of a generic function is named as the instance's
// symbol is: the declaration's name, `__func_` and a number, as upstream
// names it (`apply__func_789`). Upstream's number counts instances and
// anonymous types in analysis order; bs's is a stable hash. An instance
// the backend inlines (`small`) names its inlined frame the same way.
// The hunter's repro passed a function as the comptime argument; so does
// `apply`.
const std = @import("std");
var sink: u32 = 0;
fn small(comptime n: u32, x: u32) u32 {
    if (x == n) @panic("boom");
    return x + n;
}
fn twice(x: u32) u32 {
    return x * 2;
}
noinline fn apply(comptime f: fn (u32) u32, x: u32) u32 {
    return f(small(3, x));
}
pub fn main() void {
    var x: u32 = 3;
    _ = &x;
    sink = apply(twice, x);
}
