//! exit: 0
//! stderr: "false true true false\n"
//! A block's result (a short-circuit `and`) that a later block returns
//! lives in a register of its own across what comes between, here a call
//! whose argument setup writes rax; only a result its own exit returns
//! with nothing between is computed in rax.
const std = @import("std");
noinline fn g(x: usize) ?usize {
    return if (x > 100) x else null;
}
noinline fn f(pat: []const u8, n: usize) bool {
    const glob_all = pat.len > 0 and pat[pat.len - 1] == '*';
    const e = g(n) orelse n;
    if (e > 1000) return true;
    return glob_all;
}
noinline fn direct(pat: []const u8) bool {
    return pat.len > 0 and pat[pat.len - 1] == '*';
}
pub fn main() void {
    std.debug.print("{} {} {} {}\n", .{ f("ab", 101), f("a*", 101), direct("x*"), direct("") });
}
