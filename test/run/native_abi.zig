//! The native target is this system's, as upstream resolves it: the ABI,
//! kernel and glibc versions and dynamic linker that
//! `std.zig.system.resolveTargetQuery` detects at run time are the ones
//! builtin states (gnu on a glibc system, not none).
//! flags: -target native
//! exit: 0
const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !u8 {
    const host = try std.zig.system.resolveTargetQuery(init.io, .{});
    const want = host.os.version_range.linux;
    const got = builtin.os.version_range.linux;
    if (builtin.abi != host.abi) return 1;
    if (got.range.min.order(want.range.min) != .eq or got.range.max.order(want.range.max) != .eq) return 2;
    if (got.glibc.order(want.glibc) != .eq) return 3;
    if (!std.mem.eql(u8, builtin.target.dynamic_linker.get() orelse "", host.dynamic_linker.get() orelse "")) return 4;
    return 0;
}
