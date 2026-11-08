//! exit: 0
//! stderr: "39 39 0 | 39 100 1 | 100 39 2 | 39 100 3 | 100 39 4 | r 39 l 100\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux
//! An aggregate stored to memory that its own elements are read from:
//! swapping two fields that live in memory through an initializer whose
//! fields Sema stores one at a time (the second reads the first's new
//! value, as upstream), through a temporary, through a copy of the whole
//! value whose parts are read in place (`view.zig`), through an inlined
//! and a noinline function that build the swapped value, and rewrapping
//! a union's payload in its other field. Building the result in place
//! (`in_place`) must not write a field before its old value is read.
const std = @import("std");

const B = struct { x: u64, y: u64, z: u64 };
const P = struct { a: B, b: B, n: u32 };
const U = union(enum) { l: B, r: B };

fn b(v: u64) B {
    return .{ .x = v, .y = v + 1, .z = v + 2 };
}

inline fn swapped(p: *const P) P {
    return .{ .a = p.b, .b = p.a, .n = p.n + 1 };
}

noinline fn swapRet(p: *const P) P {
    return .{ .a = p.b, .b = p.a, .n = p.n + 1 };
}

noinline fn rewrap(u: *U) void {
    u.* = switch (u.*) {
        .l => |v| .{ .r = v },
        .r => |v| .{ .l = v },
    };
}

noinline fn check(p: *const P) void {
    // Every part of each field moved together.
    if (p.a.y != p.a.x + 1 or p.a.z != p.a.x + 2) @panic("a torn");
    if (p.b.y != p.b.x + 1 or p.b.z != p.b.x + 2) @panic("b torn");
    std.debug.print("{d} {d} {d}", .{ p.a.x, p.b.x, p.n });
}

pub fn main() void {
    var q: P = .{ .a = b(100), .b = b(39), .n = 0 };
    q = .{ .a = q.b, .b = q.a, .n = q.n };
    check(&q);
    std.debug.print(" | ", .{});
    var p: P = .{ .a = b(100), .b = b(39), .n = 0 };
    const t = p.a;
    p.a = p.b;
    p.b = t;
    p.n += 1;
    check(&p);
    std.debug.print(" | ", .{});
    const c = p;
    p = .{ .a = c.b, .b = c.a, .n = c.n + 1 };
    check(&p);
    std.debug.print(" | ", .{});
    p = swapped(&p);
    check(&p);
    std.debug.print(" | ", .{});
    p = swapRet(&p);
    check(&p);
    std.debug.print(" | ", .{});
    var u: U = .{ .l = b(39) };
    rewrap(&u);
    std.debug.print("{s} {d} ", .{ @tagName(u), u.r.x });
    u = .{ .r = b(100) };
    rewrap(&u);
    std.debug.print("{s} {d}\n", .{ @tagName(u), u.l.x });
}
