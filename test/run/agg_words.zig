//! exit: 0
//! stderr: "c 7 2.5 1 | b 255 65535 4294967295 | t 3 4 5 | a 9 10 | n -1 -2 -3 7 | d 1.25 42 | o 1 5 | q 7 | m 3 6 9 12 | a3 1 2 3 | s -1 -2 -3 | u 5 8 2 1\n"
//! Aggregates of up to 64 bytes built from scalars are written an
//! eightbyte at a time (`composeWords`), then passed in registers, copied,
//! and read by field: each field must land at its offset with its own
//! bytes, whatever the register holding it had above them (a negative
//! narrow integer is sign-extended there, a float lives in an SSE
//! register). A last eightbyte narrower than 8 bytes is written as wide
//! as it is: alone by its one element (`[3]u32`), or composed with the
//! highest element's upper bits left unmasked (`Six`).
const std = @import("std");

const Caret = struct { offset: u32, x: f32, affinity: enum(u8) { up, down } };
const Bytes = struct { a: u8, b: u16, c: u32 };
const Three = struct { a: u8, b: u8, c: u8 };
const Neg = struct { a: i8, b: i16, c: i32, d: u8 };
const Dbl = struct { x: f64, n: u32 };
const Opt = struct { p: ?*const u32, ok: bool };
const WithComptime = struct { a: u32, comptime k: u32 = 7, b: u32 };
const Mixed = extern struct { a: u16, b: u8, c: u8, d: u32, e: u32 };
const Six = struct { a: i16, b: i16, c: i16 };

noinline fn caret(c: Caret) void {
    std.debug.print("c {} {d} {} | ", .{ c.offset, c.x, @backingInt(c.affinity) });
}
noinline fn bytes(b: Bytes) void {
    std.debug.print("b {} {} {} | ", .{ b.a, b.b, b.c });
}
noinline fn three(t: Three) void {
    std.debug.print("t {} {} {} | ", .{ t.a, t.b, t.c });
}
noinline fn arr(a: [2]u32) void {
    std.debug.print("a {} {} | ", .{ a[0], a[1] });
}
noinline fn neg(n: Neg) void {
    std.debug.print("n {} {} {} {} | ", .{ n.a, n.b, n.c, n.d });
}
noinline fn dbl(d: Dbl) void {
    std.debug.print("d {d} {} | ", .{ d.x, d.n });
}
noinline fn opt(o: Opt) void {
    std.debug.print("o {} {} | ", .{ @intFromBool(o.ok), o.p.?.* });
}
noinline fn withComptime(w: WithComptime) void {
    std.debug.print("q {} | ", .{w.k + w.a - w.b});
}
noinline fn mixed(m: Mixed) void {
    std.debug.print("m {} {} {} {} | ", .{ m.a, m.b, m.c, m.d + m.e - m.e });
}
noinline fn arr3(a: [3]u32) void {
    std.debug.print("a3 {} {} {} | ", .{ a[0], a[1], a[2] });
}
noinline fn six(s: Six) void {
    std.debug.print("s {} {} {} | ", .{ s.a, s.b, s.c });
}
const Unit = struct { start: usize, end: usize, property: enum(u8) { a, b, c }, pict: bool };
noinline fn unitAt(start: usize, n: usize) Unit {
    return .{ .start = start, .end = start + n, .property = if (n > 1) .c else .a, .pict = n == 3 };
}
noinline fn get(comptime T: type, v: T) T {
    return v;
}

pub fn main() void {
    var x: f32 = 2.5;
    var i: u32 = 7;
    _ = .{ &x, &i };
    caret(.{ .offset = i, .x = x, .affinity = if (i & 1 == 0) .up else .down });
    const ff: u8 = get(u8, 255);
    bytes(.{ .a = ff, .b = get(u16, 0xffff), .c = get(u32, 0xffff_ffff) });
    var t: Three = .{ .a = get(u8, 3), .b = get(u8, 4), .c = get(u8, 5) };
    _ = &t;
    three(t);
    arr(.{ get(u32, 9), get(u32, 10) });
    neg(.{ .a = get(i8, -1), .b = get(i16, -2), .c = get(i32, -3), .d = get(u8, 7) });
    dbl(.{ .x = get(f64, 1.25), .n = get(u32, 42) });
    const five: u32 = 5;
    opt(.{ .p = get(?*const u32, &five), .ok = get(bool, true) });
    withComptime(.{ .a = get(u32, 3), .b = get(u32, 3) });
    mixed(.{ .a = get(u16, 3), .b = get(u8, 6), .c = get(u8, 9), .d = get(u32, 12), .e = get(u32, 1) });
    arr3(.{ get(u32, 1), get(u32, 2), get(u32, 3) });
    six(.{ .a = get(i16, -1), .b = get(i16, -2), .c = get(i16, -3) });
    const u = unitAt(get(usize, 5), get(usize, 3));
    std.debug.print("u {} {} {} {}\n", .{ u.start, u.end, @backingInt(u.property), @intFromBool(u.pict) });
}
