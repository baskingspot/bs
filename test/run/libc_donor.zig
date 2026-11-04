//! exit: 0
//! libc: true
//! donor-libc: true
//! stderr: "copied 4096 libc true\n"
//! The same program built with and without -lc into one global cache
//! (build.zig): CodeGen calls glibc's memcpy and memset with -lc and
//! compiler_rt's without, so neither build may replay the other as a
//! donor.
const std = @import("std");
const builtin = @import("builtin");

pub fn main() void {
    var src: [4096]u8 = undefined;
    var dst: [4096]u8 = undefined;
    @memset(&src, 7);
    @memcpy(&dst, &src);
    var n: usize = 0;
    for (dst) |c| n += @intFromBool(c == 7);
    std.debug.print("copied {d} libc {}\n", .{ n, builtin.link_libc });
}
