//! exit: 0
//! stderr: "5912\n"
//! Proving checks: a wrapping product's bounds come from its operands'
//! only when their product fits, here not even the smallest one (bs
//! overflowed computing it while bounding the loop's variable).
const std = @import("std");
noinline fn f(seed: u64, buf: []const u8) u64 {
    if (seed != 0xED00_0000_0000_00B0) return 0;
    var h = seed *% 0x9E37_79B9_7F4A_7C15;
    var n: u64 = 0;
    while (h > 5) : (h >>= 1) n +%= buf[h & 3];
    return n;
}
pub fn main() void {
    std.debug.print("{d}\n", .{f(0xED00_0000_0000_00B0, "abcd")});
}
