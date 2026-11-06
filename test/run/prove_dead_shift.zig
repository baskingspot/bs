//! exit: 0
//! stderr: "3\n"
//! Under `s < n` with `n` 0, `s` has an empty range, so the branch never
//! runs. The bounds of the shift `(g & 1) << s` must not come from that
//! range (prove crashed casting its `hi = -1` to a shift amount).
const std = @import("std");
var g: u64 = 7;
var k: u6 = 3;
var arr = [4]u8{ 1, 2, 3, 4 };

pub fn main() void {
    var n: u6 = 0;
    _ = &n;
    const s = k;
    if (s < n) {
        const t = (g & 1) << s;
        std.debug.print("{}\n", .{arr[t]});
    }
    std.debug.print("{}\n", .{s});
}
