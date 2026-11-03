//! exit: 0
//! stderr: "donor 42 6765 Odd\n"
//! donor-without: "    const e = if (check(3)) |_| \"ok\" else |err| @errorName(err);\n    std.debug.print(\"donor {d} {d} {s}\\n\", .{ answer, fib(20), e });\n"
//! A first build that replays another program's graph (a donor): the
//! donor lacks the print, so std's formatting is partly new, and std's
//! `@import("root")` names this program's root file, not the donor's.
const std = @import("std");

const answer = 42;

fn fib(n: u32) u32 {
    return if (n < 2) n else fib(n - 1) + fib(n - 2);
}

fn check(n: u32) error{ Odd, Big }!void {
    if (n > 100) return error.Big;
    if (n % 2 == 1) return error.Odd;
}

pub fn main() void {
    const e = if (check(3)) |_| "ok" else |err| @errorName(err);
    std.debug.print("donor {d} {d} {s}\n", .{ answer, fib(20), e });
}
