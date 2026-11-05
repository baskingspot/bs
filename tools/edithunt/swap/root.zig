//! The edit hunter's `swap` project (see hunt.py's `Project`): revo's
//! module layout. Its sibling builds vm.zig as the root module and this
//! file as the module `vm`.
const std = @import("std");
const vm = @import("vm");
const capi = @import("capi");

pub const baselib = struct {
    pub const version: u32 = 3;
    pub const name = "baselib";
    pub fn scale(x: u32) u32 {
        return x * version;
    }
};

pub const Config = struct {
    depth: u8 = 4,
    label: []const u8 = "cfg",
    verbose: bool = false,
};

pub const Error = error{ Bad, Empty };

pub fn check(n: u32) Error!u32 {
    if (n == 0) return error.Empty;
    if (n > 1000) return error.Bad;
    return n + 1;
}

pub fn sum(comptime T: type, xs: []const T) T {
    var total: T = 0;
    for (xs) |x| total += x;
    return total;
}

test "root sees capi and vm" {
    const c: Config = .{};
    try std.testing.expectEqual(@as(u32, 9), capi.scaled(3));
    try std.testing.expectEqual(@as(u32, 5), try check(4));
    try std.testing.expectEqual(@as(u8, 4), c.depth);
    try std.testing.expectEqual(@as(u32, 6), vm.run(&.{ 1, 2, 3 }));
    try std.testing.expectEqualStrings("baselib", capi.libName());
}
