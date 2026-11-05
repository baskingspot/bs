//! exit: 0
//! stderr: "54 10 40 5296\n"
//! sroa splits a local array indexed only at constant indices into one
//! local per element, like a struct. A whole-array load stored to a
//! global (a constant address) is stored element by element.
const std = @import("std");
const V = @Vector(4, u32);
var ga: [3]u32 = undefined;
noinline fn mix(x: u32) u32 {
    var a: [3]u32 = .{ x, x + 1, x + 2 };
    a[1] += 5;
    a[2] = a[0] * a[1];
    ga = a;
    return a[0] + a[1] + a[2];
}
noinline fn vec(x: u32) u32 {
    var v: [4]V = undefined;
    inline for (0..4) |i| v[i] = @splat(x + @as(u32, i));
    inline for (0..4) |i| v[(i + 1) % 4] +%= v[i] *% @as(V, @splat(3));
    var s: u32 = 0;
    inline for (0..4) |i| s +%= @reduce(.Add, v[i]);
    return s;
}
pub fn main() void {
    std.debug.print("{d} {d} {d} {d}\n", .{ mix(4), ga[1], ga[2], vec(7) });
}
