//! exit: 0
//! stderr: "twin -2 -2 1\nunion -2 -2 -2 -2\nbitcast -3 -3 -3\nbytes 7 -1 3 3 -2 2\nwide -4294967295 1099511627775 -1\nenum -2 3\nstruct -2 3 -2\nelem -1 3 -2\n"
//! upstream-llvm: true
//! targets: x86_64-linux aarch64-macos aarch64-linux

// A load of an integer narrower than its bytes extends from its own width:
// memory written through another type of its size (an unsigned twin, a
// packed union's other field, raw bytes) may hold other bits above it.
// (Upstream checks it with LLVM: its x86_64 backend trusts those bits too.)
const std = @import("std");

const U2 = packed union { r: u2, s: i2 };
const U33 = packed union { a: u33, b: i33 };
const E = enum(i3) { neg2 = -2, three = 3, _ };
const S = struct { a: i3, b: u8 };
const SU = struct { a: u3, b: u8 };

noinline fn twinLoad(p: *const i2) i2 {
    return p.*;
}

noinline fn unionField(u: *const U2) i2 {
    return u.s;
}

noinline fn fromBits(x: i33) U33 {
    return @bitCast(x);
}

pub fn main() void {
    // An unsigned twin through a pointer cast.
    var r: u2 = 2;
    const p: *i2 = @ptrCast(&r);
    var four: u2 = 0;
    const q: *const i1 = @ptrCast(&four);
    four = 1;
    std.debug.print("twin {d} {d} {d}\n", .{ p.*, twinLoad(p), @as(i8, q.*) + 2 });

    // A packed union read through its other field: a variable, through a
    // pointer, a comptime-known value copied to a variable, and an array
    // element.
    var u: U2 = .{ .r = 2 };
    _ = &u;
    const c: U2 = comptime .{ .r = 2 };
    var w = c;
    _ = &w;
    var us = [_]U2{ .{ .r = 1 }, .{ .r = 2 } };
    var i: usize = 1;
    _ = .{ &i, &us };
    std.debug.print("union {d} {d} {d} {d}\n", .{ u.s, unionField(&u), w.s, us[i].s });

    // A packed union built by @bitCast, at run time and at comptime.
    var x: i33 = -3;
    _ = &x;
    const y: U33 = @bitCast(x);
    const ct: U33 = comptime @bitCast(@as(i33, -3));
    var ctv = ct;
    _ = &ctv;
    std.debug.print("bitcast {d} {d} {d}\n", .{ y.b, fromBits(x).b, ctv.b });

    // Raw bytes read as narrow integers: the bits above are ignored.
    var bytes = [_]u8{ 0xff, 0x0b, 0x06 };
    const b0u: *const u3 = @ptrCast(&bytes[0]);
    const b0i: *const i3 = @ptrCast(&bytes[0]);
    const b1u: *const u3 = @ptrCast(&bytes[1]);
    const b1i: *const i3 = @ptrCast(&bytes[1]);
    const b2i: *const i2 = @ptrCast(&bytes[2]);
    const b2u: *const u2 = @ptrCast(&bytes[2]);
    std.debug.print("bytes {d} {d} {d} {d} {d} {d}\n", .{ b0u.*, b0i.*, b1u.*, b1i.*, b2i.*, b2u.* });

    // Wider than 32 bits, in an 8-byte slot.
    var qw: u64 = 0x1_0000_0001;
    const qi: *const i33 = @ptrCast(&qw);
    var ones: u64 = std.math.maxInt(u64);
    const ou: *const u40 = @ptrCast(&ones);
    const oi: *const i40 = @ptrCast(&ones);
    _ = .{ &qw, &ones };
    std.debug.print("wide {d} {d} {d}\n", .{ qi.*, ou.*, oi.* });

    // An enum with a narrow signed tag.
    var tag: u8 = 0x06;
    const e: *const E = @ptrCast(&tag);
    var tag3: u8 = 0xf3;
    const e3: *const E = @ptrCast(&tag3);
    _ = .{ &tag, &tag3 };
    std.debug.print("enum {d} {d}\n", .{ @intFromEnum(e.*), @intFromEnum(e3.*) });

    // A struct written as its unsigned twin, loaded whole and by field.
    var su: SU = .{ .a = 6, .b = 3 };
    _ = &su;
    const sp: *const S = @ptrCast(&su);
    const whole = sp.*;
    std.debug.print("struct {d} {d} {d}\n", .{ whole.a, whole.b, sp.a });

    // Elements of an array of narrow integers, indexed at run time.
    var raw = [_]u8{ 0x07, 0x03, 0x0e };
    const arr: *const [3]i3 = @ptrCast(&raw);
    var j: usize = 0;
    _ = &j;
    std.debug.print("elem {d} {d} {d}\n", .{ arr[j], arr[j + 1], arr[j + 2] });
}
