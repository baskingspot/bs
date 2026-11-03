//! The project `zig build test-build` builds with `zap build` (check.sh).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "greet", .module = b.createModule(.{ .root_source_file = b.path("src/greet.zig") }) }},
    });
    // A Debug step that asks for LLVM, as uucode's table generator does:
    // zap builds it with its own backend.
    const exe = b.addExecutable(.{ .name = "hello", .root_module = mod, .use_llvm = true });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addArgs(&.{ "a", "b" });
    b.step("run", "Run hello").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run hello's tests").dependOn(&b.addRunArtifact(tests).step);
}
