//! exit: 0
//! stderr: "15 E1 E2 3 11 Overflow 7 E1 9 E2 v E3 1 2 E1 30 Overflow\n"
//! A `try` or `catch` of an inlined call branches from each of the call's
//! returns straight to the side its result selects when the result is known
//! to be an error or a payload, and through the test when it is not (an
//! error union passed in, `pick`'s `else`). Each side still reads the
//! result the `br` wrote.
const std = @import("std");

const E = error{ E1, E2, E3 };

fn add(a: u64, b: u64) error{Overflow}!u64 {
    const r, const o = @addWithOverflow(a, b);
    if (o != 0) return error.Overflow;
    return r;
}

fn classify(x: u64) E!u64 {
    if (x == 1) return error.E1;
    if (x == 2) return error.E2;
    return x * 3;
}

fn pick(x: u64, other: E!u64) E!u64 {
    if (x == 0) return error.E1;
    if (x == 1) return x + 8;
    return other;
}

noinline fn viaTry(x: u64) E!u64 {
    return try classify(x) + 0;
}

noinline fn viaCatch(x: u64) u64 {
    return classify(x) catch |e| switch (e) {
        error.E1 => 100,
        error.E2 => 200,
        error.E3 => 300,
    };
}

noinline fn viaIf(x: u64, other: E!u64) []const u8 {
    if (pick(x, other)) |v| {
        return if (v == 9) "9" else "v";
    } else |e| return @errorName(e);
}

noinline fn sum(xs: []const u64) error{Overflow}!u64 {
    var s: u64 = 0;
    for (xs) |x| s = try add(s, x);
    return s;
}

fn name(r: anytype) []const u8 {
    return if (r) |_| "ok" else |e| @errorName(e);
}

pub fn main() void {
    var five: u64 = 5;
    _ = &five;
    const a = viaTry(five) catch unreachable;
    const b = viaTry(1);
    const c = viaTry(2);
    std.debug.print("{d} {s} {s} ", .{ a, name(b), name(c) });
    std.debug.print("{d} ", .{viaCatch(1) / 100 + viaCatch(2) / 100});
    std.debug.print("{d} ", .{sum(&.{ 1, 2, 8 }) catch unreachable});
    std.debug.print("{s} ", .{name(sum(&.{ 1, std.math.maxInt(u64) }))});
    std.debug.print("{d} {s} ", .{ viaCatch(five) / 2 - 0, viaIf(0, 4) });
    std.debug.print("{s} {s} ", .{ viaIf(1, 4), viaIf(2, error.E2) });
    std.debug.print("{s} {s} ", .{ viaIf(2, 4), viaIf(3, error.E3) });
    var one: u64 = 1;
    _ = &one;
    const d = viaTry(one);
    std.debug.print("{d} {d} {s} ", .{ one, one + one, name(d) });
    std.debug.print("{d} {s}\n", .{ viaCatch(10), name(sum(&.{ std.math.maxInt(u64), 1, 1 })) });
}
