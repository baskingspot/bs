//! exit: 0
//! stderr: "4321\n"
//! donor-here-without: "// Only in this program.\n"
//! A first build that replays a donor, here the same program built at
//! the same path, loads the functions that use `@extern` in another
//! order than a full build analyzes them: the externs' slots must still
//! be linked in the same order, by name.
const std = @import("std");

export fn ea() callconv(.c) u32 {
    return 1;
}
export fn eb() callconv(.c) u32 {
    return 2;
}
export fn ec() callconv(.c) u32 {
    return 3;
}
export fn ed() callconv(.c) u32 {
    return 4;
}

fn fd() u32 {
    return @extern(*const fn () callconv(.c) u32, .{ .name = "ed" })();
}
fn fc() u32 {
    return @extern(*const fn () callconv(.c) u32, .{ .name = "ec" })();
}
fn fb() u32 {
    return @extern(*const fn () callconv(.c) u32, .{ .name = "eb" })();
}
fn fa() u32 {
    return @extern(*const fn () callconv(.c) u32, .{ .name = "ea" })();
}

pub fn main() void {
    std.debug.print("{d}\n", .{fa() + fb() * 10 + fc() * 100 + fd() * 1000});
}

// Only in this program.
