//! Calls functions glibc keeps in libc_nonshared.a: atexit, and before
//! glibc 2.33 stat and fstatat. Linked with -lc for glibc 2.17.
const std = @import("std");

extern "c" fn atexit(f: *const fn () callconv(.c) void) c_int;
extern "c" fn stat(noalias path: [*:0]const u8, noalias buf: *[256]u8) c_int;
extern "c" fn fstatat(dirfd: c_int, path: [*:0]const u8, buf: *[256]u8, flags: c_int) c_int;

fn bye() callconv(.c) void {
    _ = std.c.write(1, "bye\n", 4);
}

pub fn main() u8 {
    var buf: [256]u8 = undefined;
    const missing = "/nonexistent/bs-nonshared";
    var line: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&line, "stat {d} {d}\n", .{ stat(missing, &buf), fstatat(std.c.AT.FDCWD, missing, &buf, 0) }) catch unreachable;
    _ = std.c.write(1, s.ptr, s.len);
    return @intCast(atexit(bye));
}
