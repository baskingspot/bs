//! exit: 0
//! stderr: "138 82c40b6d 138 82c40b6d 42cbb07d75903031\n138 1fd 138 1fd 98d1\n2c40b6d -2c408fd 138 2c40b6d\n-82c408fd 82c40b6d 138 -82c408fd 136\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux

// 128-bit overflow operations on values widened from 64 bits or fewer,
// which live in one register holding the low half, while enough other
// values are live that the operation's clobbers save those registers to
// 8-byte slots: the high half is still zero, not the next slot's
// contents, for unsigned and signed results.
const std = @import("std");

var g: [11]u64 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
var ua: u64 = 0;
var ub: u32 = 0x82c40a35;
var uc: u8 = 0xc5;
var sa: i64 = 0;
var sb: i32 = -0x2c40a35;

fn pressure(comptime T: type, x: T) T {
    const v0 = g[0] *% g[3];
    const v1 = g[1] *% g[4];
    const v2 = g[2] *% g[5];
    const v3 = g[3] *% g[6];
    const v4 = g[4] *% g[7];
    const v5 = g[5] *% g[8];
    const v6 = g[6] *% g[9];
    const v7 = g[7] *% g[10];
    return x +% v0 +% v1 +% v2 +% v3 +% v4 +% v5 +% v6 +% v7;
}

noinline fn unsigned(comptime op: u8, comptime B: type, bv: *const B) u128 {
    const v0 = g[0] *% g[3];
    const v1 = g[1] *% g[4];
    const v2 = g[2] *% g[5];
    const v3 = g[3] *% g[6];
    const v4 = g[4] *% g[7];
    const v5 = g[5] *% g[8];
    const v6 = g[6] *% g[9];
    const v7 = g[7] *% g[10];
    const a: u128 = ua;
    const b: u128 = bv.*;
    const d = switch (op) {
        0 => @subWithOverflow(a, b),
        1 => @addWithOverflow(a, b),
        2 => @mulWithOverflow(a, b),
        3 => @subWithOverflow(b, a),
        else => @mulWithOverflow(b, b),
    };
    const r: u128 = if (d[1] == 1) 0 else d[0];
    return r +% v0 +% v1 +% v2 +% v3 +% v4 +% v5 +% v6 +% v7;
}

noinline fn signed(comptime op: u8, comptime B: type, bv: *const B) i128 {
    const v0 = g[0] *% g[3];
    const v1 = g[1] *% g[4];
    const v2 = g[2] *% g[5];
    const v3 = g[3] *% g[6];
    const v4 = g[4] *% g[7];
    const v5 = g[5] *% g[8];
    const v6 = g[6] *% g[9];
    const v7 = g[7] *% g[10];
    const a: i128 = sa;
    const b: i128 = bv.*;
    const d = switch (op) {
        0 => @subWithOverflow(a, b),
        1 => @addWithOverflow(a, b),
        2 => @mulWithOverflow(a, b),
        else => @subWithOverflow(b, b +% b),
    };
    const r: i128 = if (d[1] == 1) 0 else d[0];
    return r +% v0 +% v1 +% v2 +% v3 +% v4 +% v5 +% v6 +% v7;
}

noinline fn wrapping() u128 {
    // The same operands through the wrapping operations.
    const a: u128 = ua;
    const b: u128 = ub;
    return pressure(u128, (a -% b) ^ (a *% b) ^ (a +% b));
}

pub fn main() void {
    std.debug.print("{x} {x} {x} {x} {x}\n", .{ unsigned(0, u32, &ub), unsigned(1, u32, &ub), unsigned(2, u32, &ub), unsigned(3, u32, &ub), unsigned(4, u32, &ub) });
    std.debug.print("{x} {x} {x} {x} {x}\n", .{ unsigned(0, u8, &uc), unsigned(1, u8, &uc), unsigned(2, u8, &uc), unsigned(3, u8, &uc), unsigned(4, u8, &uc) });
    std.debug.print("{x} {x} {x} {x}\n", .{ signed(0, i32, &sb), signed(1, i32, &sb), signed(2, i32, &sb), signed(3, i32, &sb) });
    std.debug.print("{x} {x} {x} {x} {x}\n", .{ signed(0, u32, &ub), signed(1, u32, &ub), signed(2, u32, &ub), signed(3, u32, &ub), wrapping() });
}
