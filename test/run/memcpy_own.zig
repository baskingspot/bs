//! exit: 0
//! stderr: "memcpy 1 memmove 1 62\n"
//! targets: x86_64-linux aarch64-linux
//! A program that exports its own `memcpy` and `memmove` gets calls of
//! them from runtime-length `@memcpy` and `@memmove`, as upstream's code
//! does; bs used to inline every copy, so fastmem's functions never ran
//! for Zig's. `memmove`'s name is computed, so bs's guess before
//! analysis misses it and the build runs again with it (`Emit.own_mem`).
//! Not on aarch64-macos, where upstream's link refuses a second `memcpy`
//! beside compiler_rt's.
const std = @import("std");

var copies: usize = 0;
var moves: usize = 0;

export fn memcpy(noalias dest: ?[*]u8, noalias src: ?[*]const u8, len: usize) callconv(.c) ?[*]u8 {
    @disableIntrinsics();
    for (0..len) |i| dest.?[i] = src.?[i];
    copies += 1;
    return dest;
}

fn move(dest: ?[*]u8, src: ?[*]const u8, len: usize) callconv(.c) ?[*]u8 {
    @disableIntrinsics();
    if (@intFromPtr(dest) < @intFromPtr(src)) {
        for (0..len) |i| dest.?[i] = src.?[i];
    } else {
        var i = len;
        while (i > 0) {
            i -= 1;
            dest.?[i] = src.?[i];
        }
    }
    moves += 1;
    return dest;
}

comptime {
    @export(&move, .{ .name = "mem" ++ "move" });
}

noinline fn copy(dest: []u8, src: []const u8) void {
    @memcpy(dest, src);
}

noinline fn shift(buf: []u8) void {
    @memmove(buf[1..], buf[0 .. buf.len - 1]);
}

pub fn main() void {
    var a: [64]u8 = undefined;
    for (&a, 0..) |*x, i| x.* = @intCast(i);
    var b: [64]u8 = undefined;
    const c0 = copies;
    copy(&b, &a);
    const m0 = moves;
    shift(&b);
    std.debug.print("memcpy {d} memmove {d} {d}\n", .{ copies - c0, moves - m0, b[63] });
}
