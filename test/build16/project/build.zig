//! A Zig 0.16 project for `bs build` (test/build16/check.sh): a path
//! dependency's module, and a lazy dependency fetched from a tarball only
//! when `-Dlazy` asks for it.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const dep = b.dependency("dep", .{});
    const exe = b.addExecutable(.{
        .name = "hello16",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .imports = &.{.{ .name = "greet", .module = dep.module("greet") }},
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run hello16").dependOn(&run.step);
    if (b.option(bool, "lazy", "Use the lazy dependency") orelse false) {
        if (b.lazyDependency("lazy", .{})) |l| {
            const lazy_run = b.addRunArtifact(b.addExecutable(.{
                .name = "lazy16",
                .root_module = l.module("lazy"),
            }));
            b.step("lazy", "Run the lazy dependency's program").dependOn(&lazy_run.step);
        }
    }
}
