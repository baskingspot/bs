//! Zig 0.16 meanings that 0.17 changed or removed, each printed so that a
//! wrong one shows: test/language/zig016.sh compares the output with zig
//! 0.16.0's.
const std = @import("std");

const Empty = enum {};
const Full = extern struct { number: u16 };
const Halves = extern struct { lo: u8, hi: u8 };
const S = struct { x: u32 };
const private_decl = 1;
const Self = @This();

fn failing(log: *u32) error{Bad}!void {
    errdefer |err| log.* = @intFromError(err) * 0 + 7;
    return error.Bad;
}

pub fn main() void {
    const rep = [_]u8{ 1, 2 } ** 3;
    const tup = .{ 'a', 'b' } ** 2;
    var log: u32 = 0;
    failing(&log) catch |err| std.debug.assert(err == error.Bad);
    var e: Empty = undefined;
    _ = &e;
    switch (e) {}
    var s: S = .{ .x = 5 };
    const p: [*c]S = &s;
    p.*.x += 1;
    var v: @Vector(2, u32) = .{ 3, 4 };
    const pv = &(&v)[1];
    pv.* += 1;
    var full: Full = .{ .number = 0x1234 };
    _ = &full;
    const halves: Halves = @bitCast(full);
    var f: f32 = -0.5;
    _ = &f;
    const z: i0 = @intFromFloat(f);
    const nothing: void = void{};
    _ = nothing;
    std.debug.print("{any} {any} {d} {d} {} {d} {} {x} {x} {d} {} {d} {}\n", .{
        rep,                                     tup,  log,                            p.*.x,
        @TypeOf(&p.*.x),                         v[1], @TypeOf(pv),                    halves.lo,
        halves.hi,                               z,    @hasDecl(Self, "private_decl"), @bitSizeOf(S),
        @typeInfo(Empty).@"enum".tag_type == u0,
    });
}
