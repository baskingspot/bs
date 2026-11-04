//! exit: 71
//! The memory and string functions compiler_rt exports, which a program
//! without libc gets through externs (and C objects call): each must be
//! defined, and behave as upstream's (exit 71 there too).
const std = @import("std");
extern fn memcpy(d: ?[*]u8, s: ?[*]const u8, n: usize) ?[*]u8;
extern fn memmove(d: ?[*]u8, s: ?[*]const u8, n: usize) ?[*]u8;
extern fn memset(d: ?[*]u8, c: c_int, n: usize) ?[*]u8;
extern fn memcmp(a: [*]const u8, b: [*]const u8, n: usize) c_int;
extern fn bcmp(a: [*]const u8, b: [*]const u8, n: usize) c_int;
extern fn strlen(s: [*:0]const u8) usize;
pub fn main() u8 {
    var buf: [16]u8 = undefined;
    _ = memset(&buf, 'x', buf.len);
    _ = memcpy(&buf, "hello", 5);
    _ = memmove(buf[1..].ptr, &buf, 5);
    var r: u8 = 0;
    if (memcmp(&buf, "hhellox", 7) == 0) r += 1;
    if (bcmp(&buf, "hhellox", 7) == 0) r += 2;
    if (memcmp(&buf, "hz", 2) < 0) r += 4;
    r += @intCast(strlen("abcdefgh") * 8);
    return r;
}
