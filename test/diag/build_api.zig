const std = @import("std");
fn includePath(b: *std.Build, exe: *std.Build.Step.Compile) void {
    exe.addIncludePath(b.path("include"));
}
fn libc(exe: *std.Build.Step.Compile) void {
    exe.linkLibC();
}
fn release(b: *std.Build) void {
    _ = b.standardReleaseOptions();
}
fn options(b: *std.Build) void {
    _ = b.addExecutable(.{ .name = "app", .root_source_file = b.path("src/main.zig") });
}
pub fn main() void {
    _ = &includePath;
    _ = &libc;
    _ = &release;
    _ = &options;
}

// error
// build_api.zig:3:8: error[no-field]: no field or member function named 'addIncludePath' in 'Build.Step.Compile'
//   | exe.addIncludePath(b.path("include"));
//   note std/Build/Step/Compile.zig:1:1: struct declared here
//   hint: moved to the compile step's module: `exe.root_module.addIncludePath(b.path("include"))`
//   fix build_api.zig:3:9-3:23: "root_module.addIncludePath"
//   ref: main build_api.zig:15:10 (+3 std frames)
// build_api.zig:6:8: error[no-field]: no field or member function named 'linkLibC' in 'Build.Step.Compile'
//   | exe.linkLibC();
//   note std/Build/Step/Compile.zig:1:1: struct declared here
//   hint: moved to the compile step's module: `exe.root_module.link_libc = true;` (or `.link_libc = true` in createModule)
//   fix build_api.zig:6:9-6:19: "root_module.link_libc = true"
//   ref: main build_api.zig:16:10 (+3 std frames)
// build_api.zig:9:10: error[no-field]: no field or member function named 'standardReleaseOptions' in 'Build'
//   | _ = b.standardReleaseOptions();
//   note std/Build.zig:1:1: struct declared here
//   hint: use `b.standardOptimizeOption(.{})`
//   fix build_api.zig:9:11-9:35: "standardOptimizeOption(.{})"
//   ref: main build_api.zig:17:10 (+3 std frames)
// build_api.zig:12:44: error[no-field]: no field named 'root_source_file' in struct 'Build.ExecutableOptions'
//   | _ = b.addExecutable(.{ .name = "app", .root_source_file = b.path("src/main.zig") });
//   note std/Build.zig:559:31: struct declared here: pub const ExecutableOptions = struct {
//   hint: since 0.15, a compile step takes its source, target and optimize mode from a module: `.root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize })`; link_libc, strip and the other code options moved to the module too
//   ref: main build_api.zig:18:10 (+3 std frames)
// 4 errors
