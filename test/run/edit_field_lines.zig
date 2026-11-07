//! signal: ABRT
//! targets: x86_64-linux aarch64-linux aarch64-macos
//! rebuild-without: "y: u16 = 2,\n"
//! stderr-contains: "panic: boom\n"
//! stderr-contains: "edit_field_lines.zig:23:16: 0x"
//! stderr-contains: " in main ("
//! stderr-contains: "    if (v > 2) @panic(\"boom\");\n               ^\n"

// An edit that adds a field to the root struct, above `main`, which does
// not use it. A container whose fields changed maps none of its
// declarations to the old ZIR (as upstream's), so the lazy edit build
// cannot map `main`'s declaration, yet loads `main` green: its body is
// the same. Its lines must still move down with it, as a full build's.
const std = @import("std");
const S = @This();

x: u8,
y: u16 = 2,

pub fn main() void {
    var v: u32 = 5;
    _ = &v;
    if (v > 2) @panic("boom");
    std.debug.print("{d}\n", .{v});
}
