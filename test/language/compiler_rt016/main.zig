//! In Zig 0.16, an object built with -fcompiler-rt analyzes compiler_rt
//! with the program, so a program export of a name compiler_rt exports
//! collides with it, whatever the linkage. Without -fcompiler-rt, in an
//! executable, or in Zig 0.17, this builds.

fn copy() callconv(.c) void {}

comptime {
    @export(&copy, .{ .name = "memcpy", .linkage = .weak });
    @export(&copy, .{ .name = "not_in_compiler_rt" });
}
