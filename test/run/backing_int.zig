//! exit: 0
//! stdout: "179\n7\n5\n33\n255\n7\n9\n0\n3\n"
//! @backingInt and @fromBackingInt of packed types and tagged unions,
//! @bitCast to an enum, and @unionInit.
const rt = @import("rt.zig");
pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}
const S = packed struct(u16) { a: u4, b: bool, c: u11 };
const U = packed union(u8) { x: u8, y: i8 };
const E = enum(i32) { _ };
const TE = enum(u8) { p, q };
const T = union(TE) { p: u8, q: []const u8 };
fn back(s: S) u16 {
    return @backingInt(s);
}
fn front(x: u16) S {
    return @fromBackingInt(x);
}
fn main() callconv(.c) noreturn {
    var s: S = .{ .a = 3, .b = true, .c = 5 };
    _ = &s;
    rt.printInt(back(s));
    const f = front(0x00b7);
    rt.printInt(f.a);
    rt.printInt(f.c);
    rt.printInt(comptime @backingInt(S{ .a = 1, .b = false, .c = 1 }));
    var u: U = .{ .y = -1 };
    _ = &u;
    rt.printInt(@backingInt(u));
    const e: E = @bitCast(@as(i32, 7));
    rt.printInt(@intCast(@backingInt(e)));
    var n: u8 = 9;
    _ = &n;
    const t = @unionInit(T, "p", n);
    rt.printInt(t.p);
    rt.printInt(@backingInt(t));
    const t2 = comptime @unionInit(T, "q", "hey");
    rt.printInt(t2.q.len);
    rt.exit(0);
}
