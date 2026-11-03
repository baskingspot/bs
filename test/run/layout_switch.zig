//! exit: 0
//! Optional slices and error sets use the payload's zero as null, auto
//! structs reorder fields by alignment, wide switch and enum operands,
//! `else` with `_`, comptime-known single-item captures, union captures of
//! several payload types, union field alignment, and switches on pointers.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const Err = error{ Foo, Bar };
fn optErr(b: bool) ?Err {
    return if (b) error.Bar else null;
}
fn optSlice(b: bool) ?[]const u8 {
    return if (b) "abc" else null;
}
const S = struct { a: ?anyerror, b: ?[]const u8, c: u8 };
var g: S = .{ .a = error.Foo, .b = "xy", .c = 7 };

const Kdf = enum(u128) {
    aes_kdf = 0xea4f8ac1080d74bf60448a629af3d9c9,
    argon2d = 0x0c0ae303a4a9f7914b44298cdf6d63ef,
};
const E = enum(u8) { a, b, c, _ };
fn nonExhaustive(start: E) u32 {
    return s: switch (start) {
        .a => continue :s .c,
        else => continue :s @fromBackingInt(@intCast(123)),
        .b, _ => |x| break :s @backingInt(x),
    };
}
fn wideSwitch(x: u65) u8 {
    return switch (x) {
        0 => 1,
        1 << 64 => 2,
        else => 3,
    };
}
fn single(e: E) u8 {
    return switch (e) {
        .a => |tag| comptime @intFromEnum(tag) + 10,
        else => 0,
    };
}
const U = union(enum) { a: u32, b: u64, c: u8 align(8) };
fn peer(u: U) u64 {
    return switch (u) {
        .b, .a => |x| x,
        .c => |*p| if (@TypeOf(p) == *align(8) const u8) 5 else 6,
    };
}
const X = struct { field: u32 };
fn ptrSwitch(p: *X) u8 {
    return switch (p) {
        @as(*X, @ptrFromInt(0x400)) => 1,
        else => 2,
    };
}
fn emptyErrors() error{}!u32 {
    return 9;
}
fn tryEmpty() u32 {
    return try emptyErrors();
}
fn emptyFn() void {}

fn main() callconv(.c) noreturn {
    if (@sizeOf(?[]u8) != 16 or @sizeOf(?anyerror) != 2 or @sizeOf(?Err) != 2) rt.exit(1);
    var e: ?anyerror = null;
    if (e != null) rt.exit(2);
    e = error.Foo;
    if (e.? != error.Foo) rt.exit(3);
    if (optErr(false) != null or optErr(true).? != error.Bar) rt.exit(4);
    if (optSlice(false) != null or optSlice(true).?[2] != 'c') rt.exit(5);
    if (@sizeOf(S) != 24 or g.a.? != error.Foo or g.b.?[1] != 'y' or g.c != 7) rt.exit(6);
    var p: *?[]const u8 = &g.b;
    _ = &p;
    p.* = null;
    if (g.b != null) rt.exit(7);

    var kdf: Kdf = .argon2d;
    _ = &kdf;
    if (@tagName(kdf).len != 7 or kdf != .argon2d) rt.exit(8);
    if (nonExhaustive(.a) != 123) rt.exit(9);
    if (wideSwitch(1 << 64) != 2) rt.exit(15);
    if (wideSwitch(5) != 3) rt.exit(16);
    if (wideSwitch(0) != 1) rt.exit(17);
    if (single(.a) != 10) rt.exit(10);
    if (peer(.{ .a = 123 }) != 123 or peer(.{ .b = 1 << 40 }) != 1 << 40 or peer(.{ .c = 1 }) != 5) rt.exit(11);
    if (@alignOf(U) != 8 or ptrSwitch(@ptrFromInt(0x400)) != 1 or ptrSwitch(@ptrFromInt(0x800)) != 2) rt.exit(12);
    if (tryEmpty() != 9) rt.exit(13);
    const alias = emptyFn;
    if (!(comptime emptyFn == alias)) rt.exit(14);

    const P = packed struct { f0: u0 };
    var s: P = .{ .f0 = 0 };
    _ = &s;
    comptime if (s.f0 != 0) unreachable;
    rt.exit(0);
}
