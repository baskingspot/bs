//! The project `zig build test-build` builds with `bs build` (check.sh).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // As ghostty's: bs accepts it and says so in builtin.unwind_tables.
        .unwind_tables = .sync,
        .imports = &.{.{
            .name = "greet",
            .module = b.createModule(.{
                .root_source_file = b.path("src/greet.zig"),
                // `zig build --fuzz` instruments the tests but not this module.
                .fuzz = false,
            }),
        }},
    });
    // A Debug step that asks for LLVM and PIE: bs builds it with its
    // own backend, static and non-PIE.
    const exe = b.addExecutable(.{ .name = "hello", .root_module = mod, .use_llvm = true });
    exe.pie = true;
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addArgs(&.{ "a", "b" });
    b.step("run", "Run hello").dependOn(&run.step);
    // A static library: its object in an archive.
    const answer = b.addLibrary(.{ .name = "answer", .root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.installArtifact(answer);
    // A shared library: -fPIC, which bs's cache does not take; its
    // inputs record still makes a build with no change a cache hit, also
    // the first after a cold build, which wrote its link input, the
    // archive, moments before it linked, and whose C source includes a
    // header that another step wrote moments before.
    const shared = b.addLibrary(.{ .name = "shared", .linkage = .dynamic, .root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    shared.root_module.linkLibrary(answer);
    const generated = b.addWriteFiles();
    _ = generated.add("generated.h", "#define GENERATED_VALUE 7\n");
    shared.root_module.addIncludePath(generated.getDirectory());
    shared.root_module.addCSourceFile(.{ .file = b.path("c/generated.c") });
    b.installArtifact(shared);
    // A C header translated to Zig, imported by a program that links
    // glibc: `bs translate-c --listen=-`.
    const tc = b.addTranslateC(.{
        .root_source_file = b.path("c/shape.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tc.addIncludePath(b.path("c"));
    tc.defineCMacro("SHAPE_SCALE", "10");
    const shape = b.addExecutable(.{ .name = "shape", .root_module = b.createModule(.{
        .root_source_file = b.path("src/shape.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = tc.createModule() }},
    }) });
    b.step("shape", "Run shape").dependOn(&b.addRunArtifact(shape).step);
    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run hello's tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // `zig fmt --check`, run by the compiler.
    test_step.dependOn(&b.addFmt(.{ .paths = &.{b.path("src")}, .check = true }).step);
    // As zig-clap's: the test compile also emits docs, for every step.
    const docs = b.addInstallDirectory(.{ .source_dir = tests.getEmittedDocs(), .install_dir = .prefix, .install_subdir = "docs" });
    b.step("docs", "Install hello's docs").dependOn(&docs.step);
}
