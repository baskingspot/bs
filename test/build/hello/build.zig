//! The project `zig build test-build` builds with `zap build` (check.sh).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // As ghostty's: zap accepts it and says so in builtin.unwind_tables.
        .unwind_tables = .sync,
        .imports = &.{.{ .name = "greet", .module = b.createModule(.{
            .root_source_file = b.path("src/greet.zig"),
            // `zig build --fuzz` instruments the tests but not this module.
            .fuzz = false,
        }) }},
    });
    // A Debug step that asks for LLVM and PIE: zap builds it with its
    // own backend, static and non-PIE.
    const exe = b.addExecutable(.{ .name = "hello", .root_module = mod, .use_llvm = true });
    exe.pie = true;
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addArgs(&.{ "a", "b" });
    b.step("run", "Run hello").dependOn(&run.step);
    // A static library: its object in an archive.
    b.installArtifact(b.addLibrary(.{ .name = "answer", .root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    }) }));
    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run hello's tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // `zig fmt --check`, run by the compiler.
    test_step.dependOn(&b.addFmt(.{ .paths = &.{b.path("src")}, .check = true }).step);
    // As zig-clap's: the test compile also emits docs, for every step.
    const docs = b.addInstallDirectory(.{ .source_dir = tests.getEmittedDocs(), .install_dir = .prefix, .install_subdir = "docs" });
    b.step("docs", "Install hello's docs").dependOn(&docs.step);
}
