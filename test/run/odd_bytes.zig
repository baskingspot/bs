//! exit: 0
//! stderr: "197 1 0 1 1\n"
//! A 7-byte struct passed or returned in a register is read and written
//! a few bytes at a time (`loadBytes`, `storeBytes`). Read through a
//! pointer kept in memory, which `deferredMem` loads into r11, the pieces
//! must not overwrite the pointer.
const std = @import("std");
const Flags = struct { a: bool = false, b: bool = false, c: bool = false, d: bool = false, e: bool = false, f: bool = false, g: bool = false };
noinline fn space(flags: Flags) u32 {
    return @intFromBool(flags.g);
}
noinline fn other(x: u32) u32 {
    return x +% 1;
}
noinline fn make(x: u32) Flags {
    return .{ .a = x & 1 != 0, .g = x & 2 != 0 };
}
noinline fn concat(flags: *Flags, x0: u32) u32 {
    var v1 = other(x0);
    var v2 = other(v1);
    var v3 = other(v2);
    var v4 = other(v3);
    var v5 = other(v4);
    var v6 = other(v5);
    var v7 = other(v6);
    v1 +%= other(v7);
    v2 +%= other(v1);
    v3 +%= other(v2);
    v4 +%= other(v3);
    v5 +%= other(v4);
    v6 +%= other(v5);
    v7 +%= other(v6);
    const s = v1 +% v2 +% v3 +% v4 +% v5 +% v6 +% v7;
    return s +% space(flags.*);
}
noinline fn store(flags: *Flags, x0: u32) u32 {
    var v1 = other(x0);
    var v2 = other(v1);
    var v3 = other(v2);
    var v4 = other(v3);
    var v5 = other(v4);
    var v6 = other(v5);
    var v7 = other(v6);
    flags.* = make(x0);
    v1 +%= other(v7);
    v2 +%= other(v1);
    v3 +%= other(v2);
    v4 +%= other(v3);
    v5 +%= other(v4);
    v6 +%= other(v5);
    v7 +%= other(v6);
    return v1 +% v2 +% v3 +% v4 +% v5 +% v6 +% v7;
}
pub fn main() void {
    var f: Flags = .{ .a = true, .g = true };
    const r = concat(&f, 1);
    var h: Flags = .{ .b = true };
    _ = store(&h, 3);
    std.debug.print("{d} {d} {d} {d} {d}\n", .{ r, @intFromBool(h.a), @intFromBool(h.b), @intFromBool(h.g), space(h) });
}
