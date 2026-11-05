//! exit: 0
//! stderr: "51 3 12586269025\n"
//! `const temp = gcd` forwards `temp.b` to a load of `gcd.b`, which shares
//! `gcd.b`'s register. A value computed in that register for the next
//! store to `gcd.b` (the remainder) must not overwrite it before
//! `gcd.a = temp.b` reads it; std's treap tests looped forever in
//! `SliceIterRandomOrder.init` when it did.
const std = @import("std");
const P = struct { a: usize, b: usize };
noinline fn coPrime(len: usize) usize {
    if (len == 0) return 0;
    var prime = len / 2;
    while (prime < len) : (prime += 1) {
        var gcd: P = .{ .a = prime, .b = len };
        while (gcd.b != 0) {
            const temp = gcd;
            const r = temp.a % temp.b;
            gcd.a = temp.b;
            gcd.b = r;
        }
        if (gcd.a == 1) break;
    }
    return prime;
}
noinline fn fib(n: u32) u64 {
    var s: P = .{ .a = 0, .b = 1 };
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const t = s;
        const next = t.a +% t.b;
        s.a = t.b;
        s.b = next;
    }
    return s.a;
}
pub fn main() void {
    std.debug.print("{d} {d} {d}\n", .{ coPrime(100), coPrime(7), fib(50) });
}
