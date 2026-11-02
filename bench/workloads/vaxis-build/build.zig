//! `zig build` reference for the libvaxis text_input example.
//!
//! libvaxis's own build.zig forces the LLVM backend by default (`-Dllvm`) and
//! its install step also compiles the library's test binary. This wrapper
//! compiles only the example, from the same sources and module graph, with
//! the default backend (self-hosted x86_64 for Debug on x86_64-linux), so it
//! does the same compiler work as the timed `zig build-exe` command plus what
//! the build system adds on top (configure, uucode table generation, caching).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "example-text_input",
        .root_module = b.createModule(.{
            .root_source_file = vaxis.path("examples/text_input.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vaxis", .module = vaxis.module("vaxis") }},
        }),
    });
    b.installArtifact(exe);
}
