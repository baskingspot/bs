//! exit: 0
//! stderr: "302 300\n"
//! A load of a loop variable that shares the variable's register, read
//! after a call in a block that returns, keeps its value across the call:
//! that call does not make the variable cross a clobber point by itself,
//! as the variable is not read after it on any path that continues.
const std = @import("std");
var sink: usize = 0;
noinline fn touch(x: usize) void {
    sink +%= x;
}
noinline fn check(n: usize, index: usize) usize {
    return index + n * 100;
}
noinline fn remove(locks: []const []const u32, w: u32) usize {
    for (locks, 0..) |lock, lock_index| {
        for (lock, 0..) |candidate, j| {
            if (candidate != w) continue;
            touch(j);
            return check(locks.len, lock_index);
        }
    }
    unreachable;
}
pub fn main() !void {
    const locks = [3][]const u32{ &.{10}, &.{11}, &.{12} };
    std.debug.print("{d} {d}\n", .{ remove(&locks, 12), remove(&locks, 10) });
}
