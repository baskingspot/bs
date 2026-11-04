//! A shared library that links glibc (`zap build-lib -dynamic -lc`):
//! Zig code using std's C allocator and glibc, with a C source
//! (so_libc.c); so_libc_main.zig loads it.
const std = @import("std");
extern fn c_format(out: [*]u8, len: usize, v: c_int) c_int;
extern fn c_dup(s: [*:0]const u8) ?[*:0]u8;

export fn z_describe(v: c_int, out: [*]u8, len: usize) c_int {
    var buf: [32]u8 = undefined;
    const n = c_format(&buf, buf.len, v);
    if (n < 0) return -1;
    const list = std.fmt.allocPrintSentinel(std.heap.c_allocator, "z[{s}]", .{buf[0..@intCast(n)]}, 0) catch return -1;
    defer std.heap.c_allocator.free(list);
    const copy = c_dup(list.ptr) orelse return -1;
    defer std.c.free(copy);
    const s = std.mem.span(copy);
    if (s.len + 1 > len) return -1;
    @memcpy(out[0 .. s.len + 1], s[0 .. s.len + 1]);
    return @intCast(s.len);
}
