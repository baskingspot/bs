//! exit: 0
//! stderr: "707484690\n"
//! targets: x86_64-linux aarch64-macos
//! Switches whose cases cover every value of a narrow integer or enum
//! (`u3`, `i3`, `u5`, `enum(u2)`), which have no bounds check: every value
//! still reaches its own case, whether it comes from a load, a packed
//! field, a truncation, or wrapping arithmetic.
const std = @import("std");
const E2 = enum(u2) { a, b, c, d };
const E3 = enum(u3) { a, b, c, d, e, f, g, h };
const P = packed struct(u8) { x: u3, e: E2, y: u3 };
const Q = packed struct(u16) { lo: u5, e: E3, hi: u8 };

noinline fn sw3(x: u3) u32 {
    return switch (x) {
        0 => 10,
        1 => 11,
        2 => 12,
        3 => 13,
        4 => 14,
        5 => 15,
        6 => 16,
        7 => 17,
    };
}
inline fn swi3(x: i3) u32 {
    return switch (x) {
        -4 => 1,
        -3 => 2,
        -2 => 3,
        -1 => 4,
        0 => 5,
        1 => 6,
        2 => 7,
        3 => 8,
    };
}
inline fn swe2(e: E2) u32 {
    return switch (e) {
        .a => 100,
        .b => 200,
        .c => 300,
        .d => 400,
    };
}
inline fn swe3(e: E3) u32 {
    return switch (e) {
        .a => 1,
        .b => 3,
        .c => 5,
        .d => 7,
        .e => 11,
        .f => 13,
        .g => 17,
        .h => 19,
    };
}
inline fn sw5(x: u5) u32 {
    return switch (x) {
        0...3 => 1,
        4 => 2,
        5...9 => 3,
        10 => 4,
        11 => 5,
        12...20 => 6,
        21 => 7,
        22...31 => 8,
    };
}
inline fn swu2(x: u2) u32 {
    return switch (x) {
        0 => 9,
        1 => 8,
        2 => 7,
        3 => 6,
    };
}
noinline fn mix(s: u32, v: u32) u32 {
    return s *% 31 +% v;
}
pub fn main() void {
    var s: u32 = 0;
    var bytes: [256]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @intCast(i);
    std.mem.doNotOptimizeAway(&bytes);
    for (bytes) |b| {
        const p: P = @bitCast(b);
        s = mix(s, swe2(p.e));
        s = mix(s, sw3(p.x));
        s = mix(s, sw3(p.y));
        s = mix(s, sw3(@truncate(b)));
        s = mix(s, sw3(@truncate(b >> 5)));
        const t: u3 = @truncate(b);
        s = mix(s, sw3(t +% 5));
        s = mix(s, sw3(t -% 6));
        s = mix(s, sw3(t *% 3));
        s = mix(s, sw3(~t));
        s = mix(s, sw3(t << 1));
        s = mix(s, sw3(t >> 1));
        s = mix(s, sw3(t ^ 5));
        s = mix(s, swi3(@bitCast(t)));
        const it: i3 = @bitCast(t);
        s = mix(s, swi3(it +% 3));
        s = mix(s, swi3(-%it));
        s = mix(s, swi3(it >> 1));
        s = mix(s, swe3(@fromBackingInt(@intCast(t))));
        s = mix(s, sw5(@truncate(b)));
        s = mix(s, sw5(@truncate(b *% 7)));
        s = mix(s, swu2(@truncate(b >> 3)));
        s = mix(s, swe2(@fromBackingInt(@intCast(@as(u2, @truncate(b >> 1))))));
        const q: Q = @bitCast(@as(u16, b) *% 0x1234);
        s = mix(s, swe3(q.e));
        s = mix(s, sw5(q.lo));
        if (b < 8) s = mix(s, sw3(@intCast(b)));
        s = mix(s, sw3(@intCast(b & 7)));
    }
    std.debug.print("{d}\n", .{s});
}
