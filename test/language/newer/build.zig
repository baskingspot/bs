//! A project whose build.zig.zon's minimum_zig_version is newer than any
//! Zig release bs knows, with no .bs.zon: bs builds it as Zig 0.17, as
//! upstream zig 0.17.1 does, and its failure notes the minimum
//! (build.zig's language test).
const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b;
}
