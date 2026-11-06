//! exit: 0
//! stderr: "11449893\n"
//! targets: x86_64-linux aarch64-macos
//! upstream-llvm: true
//! A fully covered switch on a `u3` takes the low bits of what it reads,
//! as LLVM does, and never indexes its jump table, which has no bounds
//! check, out of range: a `u3` loaded from a byte above 7, and an
//! undefined `u3` (0xaa read as 2). Upstream's self-hosted backend
//! panics on both instead.
const std = @import("std");
noinline fn sw3(x: u3) u32 {
    return switch (x) {
        0 => 10,
        1 => 11,
        2 => 12,
        3 => 13,
        4 => 14,
        5 => 15,
        6 => 16,
        7 => 17,
    };
}
noinline fn undef3(c: bool) u32 {
    var x: u3 = undefined;
    if (c) x = 5;
    return switch (x) {
        0 => 10,
        1 => 11,
        2 => 12,
        3 => 13,
        4 => 14,
        5 => 15,
        6 => 16,
        7 => 17,
    };
}
pub fn main() void {
    var c = false;
    std.mem.doNotOptimizeAway(&c);
    var bytes = [_]u8{ 0xfa, 0x08, 0x7f, 0xaa };
    std.mem.doNotOptimizeAway(&bytes);
    var s: u32 = undef3(c);
    for (&bytes) |*b| s = s *% 31 +% sw3(@as(*const u3, @ptrCast(b)).*);
    std.debug.print("{d}\n", .{s});
}
