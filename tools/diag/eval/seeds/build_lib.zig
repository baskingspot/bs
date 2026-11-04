const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const util = b.addModule("util", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lib.root_module.addImport("util", util);
    lib.root_module.addIncludePath(b.path("include"));
    b.installArtifact(lib);

    const options = b.addOptions();
    options.addOption(bool, "verbose", false);
    lib.root_module.addOptions("build_options", options);
}
