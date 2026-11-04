//! signal: ABRT
//! stderr: "panic: reached unreachable code\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): in
//! `std.fmt.digitToChar`'s `10...35` prong the facts prove `digit >= 10`
//! and the additions, but `digit <= 35` stays checked: 36 reaches the
//! `else => unreachable`.
const std = @import("std");
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var digits = [_]u8{ 3, 11, 35, 36 };

fn main() callconv(.c) noreturn {
    var sum: u8 = 0;
    for (digits) |d| sum +%= std.fmt.digitToChar(d, if (d & 1 == 0) .lower else .upper);
    rt.exit(sum);
}
