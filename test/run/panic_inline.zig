//! signal: ABRT
//! targets: x86_64-linux aarch64-linux aarch64-macos
//! rebuild-without: "// Moved down by the edit.\n"
//! stderr-contains: "panic: boom\n"
//! stderr-contains: "panic_inline.zig:23:16: 0x"
//! stderr-contains: " in check ("
//! stderr-contains: "    if (x > 2) @panic(\"boom\");\n               ^\n"
//! stderr-contains: "start.zig:788:64: 0x"
//! stderr-contains: " in callMain ("

// A panic in an inlined call names the callee and its line, as upstream.
// bs first builds this without the marked line, then rebuilds with it:
// `check` moves down a line but `main`, which it is inlined into, does
// not change, so a reused `main` must still report `check`'s new line.
const std = @import("std");
pub fn main() void {
    var v: u32 = 5;
    _ = &v;
    std.debug.print("{d}\n", .{check(v)});
}
// Moved down by the edit.
inline fn check(x: u32) u32 {
    if (x > 2) @panic("boom");
    return x;
}
