const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("lazy", .{ .root_source_file = b.path("lazy.zig"), .target = b.graph.host });
}
