//! exit: 0
//! stderr: "174\n"
//! rebuild-without: "    total += higherOrder(1, @as(fn (anytype, anytype) u32, ignore));\n"
//! donor-without: "    total += higherOrder(1, @as(fn (anytype, anytype) u32, ignore));\n"
//! Edit and donor builds of a program that coerces generic functions to
//! other function types, as upstream's behavior tests do (cast.zig's
//! "coercing a coerced function", fn.zig's "coerce generic function
//! making concrete parameter generic", generics.zig's "generic function
//! passed as comptime argument"). The coerced function has its
//! declaration's ZIR and another type, and the calls instantiate it, so
//! neither is the declaration's value or an instance of it: a build that
//! replays the last one's records, or another program's, took them for
//! functions of that build and refused their bodies ("bs cache: 'second'
//! is a function of the last build that this one does not have").
const std = @import("std");

fn second(_: anytype, x: u32) u32 {
    return x;
}

fn ignore(_: anytype, _: void) u32 {
    return 40;
}

fn higherOrder(x: anytype, f: fn (@TypeOf(x), void) u32) u32 {
    return f(x, {});
}

fn doMath(comptime f: fn (comptime type, i32, i32) error{Overflow}!i32, a: i32, b: i32) !i32 {
    return f(i32, a, b);
}

pub fn main() !void {
    // A generic function coerced to a function type with more generic
    // parameters, then called.
    const coerced: fn (anytype, anytype) u32 = second;
    var total: u32 = coerced({}, 123);
    // A coerced function coerced again, as an argument.
    total += higherOrder(1, @as(fn (anytype, anytype) u32, ignore));
    // A generic function of std as a comptime argument of a more
    // concrete type.
    total += @intCast(try doMath(std.math.add, 5, 6));
    std.debug.print("{d}\n", .{total});
}
