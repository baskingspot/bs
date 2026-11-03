//! signal: ABRT
//! stderr-contains: "panic: boom\n"
//! stderr-contains: "panic_trace.zig:16:16: 0x"
//! stderr-contains: " in inner ("
//! stderr-contains: "    if (x > 2) @panic(\"boom\");\n               ^\n"
//! stderr-contains: "panic_trace.zig:20:17: 0x"
//! stderr-contains: " in outer ("
//! stderr-contains: "panic_trace.zig:26:14: 0x"
//! stderr-contains: " in main ("
//! stderr-contains: " in _start ("

// Through std.start and std's default panic handler: the message, then a
// stack trace that unwinds through every frame to `_start`, as upstream.
const std = @import("std");
fn inner(x: u32) u32 {
    if (x > 2) @panic("boom");
    return x;
}
fn outer(x: u32) u32 {
    return inner(x + 1) * 2;
}
pub fn main() void {
    var v: u32 = 5;
    _ = &v;
    var r: u32 = 0;
    r = outer(v);
    std.debug.print("{d}\n", .{r});
}
