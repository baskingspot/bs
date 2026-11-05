//! signal: ABRT
//! stderr: "panic: index out of bounds: index 3, len 3\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): a call's
//! result has an argument's length only when every slice the callee
//! returns has that argument's length. `same` does, so `s[j]` after
//! `j < n` needs no check; `two` returns `other` elements on one path, so
//! its result's check stays.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var buf: [8]u8 = @splat(1);
var n: usize = 5;
var m: usize = 3;

noinline fn same(s: []u8, len: usize) []u8 {
    return s[0..len];
}

noinline fn two(s: []u8, len: usize, other: usize) []u8 {
    if (len <= 4) return s[0..len];
    return s[0..other];
}

fn main() callconv(.c) noreturn {
    const len = n;
    var t: u8 = 0;
    const a = same(&buf, len);
    var j: usize = 0;
    while (j < len) : (j += 1) t +%= a[j];
    if (t != 5) rt.exit(1);
    const b = two(&buf, len, m);
    j = 0;
    while (j < len) : (j += 1) t +%= b[j];
    rt.exit(t);
}
