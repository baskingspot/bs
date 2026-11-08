//! A project whose build.zig.zon names a Zig release bs does not
//! compile (build.zig's language test).
const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b;
}
