//! exit: 0
//! stderr: "undef lanes 263\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux

// Vector miscompiles found by tools/mchunt's vector programs
// (`hunt.py --kind vector`), one function each.
const std = @import("std");

var in: [8]u64 = .{ 0x9e3779b97f4a7c15, 1, 0, 0xff, 0x80, 7, 0xaaaa, 3 };

noinline fn bools(comptime n: usize, off: usize) @Vector(n, bool) {
    var a: [n]bool = undefined;
    for (&a, 0..) |*x, i| x.* = (in[(off + i) % in.len] >> @intCast(i % 64)) & 1 != 0;
    return a;
}

/// A bool vector built lane by lane (a shuffle Sema scalarizes, over
/// 16 lanes) with undefined lanes: an undefined lane loaded as 0xaa set
/// the bits of the lanes after it in its byte.
fn undefLanes() void {
    const v = bools(32, 0);
    const s: @Vector(24, bool) = @shuffle(bool, v, undefined, @Vector(24, i32){
        3, undefined, 3, 7,  9,  undefined, 12, 3, 0,  1, 2,  3,
        4, 5,         6, 31, 30, 29,        28, 3, 27, 3, 26, 25,
    });
    var bits: u16 = 0;
    inline for ([_]usize{ 0, 2, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17 }, 0..) |lane, i| {
        bits |= @as(u16, @intFromBool(s[lane])) << @intCast(i);
    }
    std.debug.print("undef lanes {x}\n", .{bits});
}

pub fn main() void {
    undefLanes();
}
