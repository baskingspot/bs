//! exit: 0
//! stdout: "1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;
pub export fn _start() callconv(.naked) noreturn { asm volatile ("call %[main:P]" : : [main] "X" (&main)); }
fn ok(b: bool) void { rt.printInt(@intFromBool(b)); }
fn asBytes(p: anytype) *[@sizeOf(@TypeOf(p.*))]u8 { return @ptrCast(p); }
const U = extern union { x: u32, y: u8 };
const U2 = extern union { foo: u8, bar: u32 };
const bytes = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd };
const S = extern struct { u: U = @as(*align(1) const U, @ptrCast(&bytes)).* };
const PU = packed union { a: u32, b: packed struct(u32) { a: u8, b: u24 } };
const PS = packed struct { u: PU = @as(*align(1) const PU, @ptrCast(&bytes)).* };
const Outer = extern struct { u: Middle = zeroes(Middle) };
const Middle = extern union { outer: ?*Outer, inner: ?*u32 };
fn zeroes(comptime T: type) T {
    var item: T = undefined;
    @memset(asBytes(&item), 0);
    return item;
}
fn memsetTest() bool {
    var u: U2 = undefined;
    @memset(asBytes(&u), 0);
    return u.foo == 0 and u.bar == 0;
}
fn partial() u8 {
    var u: U2 = undefined;
    asBytes(&u)[0] = 7;
    return u.foo;
}
fn main() callconv(.c) noreturn {
    const x = U{ .x = 0x55AAAA55 };
    ok(comptime x.y == 0x55);
    ok(comptime memsetTest());
    ok(memsetTest());
    ok(comptime partial() == 7);
    const s: S = .{};
    ok(s.u.x == 0xddccbbaa);
    ok(s.u.y == 0xaa);
    var ps: PS = .{};
    _ = &ps;
    ok(ps.u.a == 0xddccbbaa);
    ok(ps.u.b.a == 0xaa);
    const re = comptime b: {
        var u: U = undefined;
        u = @as(*align(1) const U, @ptrCast(&bytes)).*;
        break :b u;
    };
    var u: U = re;
    _ = &u;
    ok(u.x == 0xddccbbaa);
    ok(u.y == 0xaa);
    var o: Outer = .{};
    _ = &o;
    ok(o.u.outer == null);
    ok(o.u.inner == null);
    const cb = comptime asBytes(@constCast(&U{ .y = 3 }))[0];
    ok(cb == 3);
    globalUnion();
    rt.exit(0);
}

const TU = union(enum) {
    a: u16,
    b: u32,
    var global: @This() = undefined;
};
fn globalUnion() void {
    TU.global = .{ .a = 123 };
    ok(TU.global == .a);
    ok(TU.global != .b);
    ok(TU.global.a == 123);
    TU.global = .{ .b = 123456 };
    ok(TU.global != .a);
    ok(TU.global == .b);
    ok(TU.global.b == 123456);
}
