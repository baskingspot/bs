//! A project whose build.zig.zon's minimum_zig_version is 0.16.0, with no
//! .bs.zon: bs builds it as Zig 0.17, and its failure notes the .bs.zon
//! that chooses 0.16 (build.zig's language test).
const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b;
}
