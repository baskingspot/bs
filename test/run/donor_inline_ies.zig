//! exit: 0
//! stderr: "5 Seven\n"
//! donor-here-without: "// Only in this program.\n"
//! A replay checks a function's `func_inline` edges while the function is
//! in progress, analyzing a callee out of order if it cannot be loaded.
//! `x` calls `y` (an explicit error set), which calls `w`, whose inferred
//! error set reads `x`'s: analyzing `w` while `x` is in progress is a loop
//! no full build meets, so it must end the out-of-order analysis, not
//! fail with "unable to resolve inferred error set".
const std = @import("std");

const E = error{ Seven, Big };

fn x(n: u32) !u32 {
    if (n == 7) return error.Seven;
    if (n == 0) return 0;
    return (try y(n - 1)) + 1;
}

fn y(n: u32) E!u32 {
    return w(n);
}

fn w(n: u32) !u32 {
    if (n > 100) return error.Big;
    return try x(n);
}

pub fn main() void {
    // Only in this program.
    const r = x(5) catch 99;
    const e = if (x(9)) |_| "ok" else |err| @errorName(err);
    std.debug.print("{d} {s}\n", .{ r, e });
}
