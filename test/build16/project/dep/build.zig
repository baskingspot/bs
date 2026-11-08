const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("greet", .{ .root_source_file = b.path("greet.zig") });
}
