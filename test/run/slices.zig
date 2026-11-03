//! exit: 0
//! stdout: "3\n0\n1\n9\n6\n2\n98\n12\n4\n7\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;
// For `std.lang.CallModifier`; std.start sees `_start` and stays out.
const std = @import("std");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const S = struct { a: u32 };

fn sum(xs: []S) u32 {
    var t: u32 = 0;
    for (xs) |*x| {
        x.a += 1;
        t += x.a;
    }
    return t;
}

fn add(a: u32, b: u32) u32 {
    return a + b;
}

fn main() callconv(.c) noreturn {
    // Sentinel slicing, with runtime and comptime-known bounds.
    var buf: [6]u8 = .{ 'a', 'b', 'c', 0, 'e', 'f' };
    var n: u32 = 3;
    _ = &n;
    const z: [:0]u8 = buf[0..n :0];
    rt.printInt(z.len);
    rt.printInt(z[z.len]);
    const arr: *[3:0]u8 = buf[0..3 :0];
    rt.printInt(@intFromBool(@TypeOf(arr) == *[3:0]u8));
    // Slicing a sentinel-terminated slice to its end keeps the sentinel.
    const tail = z[1..];
    rt.printInt(@as(u32, @intFromBool(@TypeOf(tail) == [:0]u8)) * 9);
    // Pointer captures of a slice.
    var items: [2]S = .{ .{ .a = 1 }, .{ .a = 2 } };
    rt.printInt(sum(&items) + @as(u32, @intFromBool(items[1].a == 3)));
    // `p[a..]` of a many-pointer.
    const p: [*]u8 = &buf;
    const q = p[2..];
    rt.printInt(@as(u32, @intFromBool(@TypeOf(q) == [*]u8)) + @intFromBool(q[0] == 'c'));
    // ... including a slice's `ptr` field.
    var sl: []u8 = &buf;
    _ = &sl;
    rt.printInt(sl.ptr[1..][0]);
    // `@call`.
    rt.printInt(@call(.auto, add, .{ 5, 7 }));
    rt.printInt(@call(.always_inline, add, .{ n, 1 }));
    // A slice's .ptr keeps its alignment.
    const aligned: []align(8) u8 = &words;
    const aligned_ptr: [*]align(8) u8 = aligned.ptr;
    rt.printInt(aligned_ptr[1]);
    rt.exit(0);
}

var words: [4]u8 align(8) = .{ 5, 7, 9, 11 };
