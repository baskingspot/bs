//! exit: 0
//! stderr: "13 0 false true\n"
//! targets: x86_64-linux aarch64-linux aarch64-macos
//! An optional `allowzero` slice is not represented by its payload: its
//! null flag follows the slice, so its values do not fit a register pair.
const std = @import("std");
noinline fn get(b: bool) ?[]allowzero const u8 {
    if (b) return @as([]allowzero const u8, "abc");
    return null;
}
noinline fn len(p: ?[]allowzero const u8) usize {
    if (p) |s| return s.len + 10;
    return 0;
}
pub fn main() void {
    var x = get(true);
    var y = get(false);
    _ = .{ &x, &y };
    const a = x;
    const b = y;
    std.debug.print("{d} {d} {} {}\n", .{ len(a), len(b), a == null, b == null });
}
