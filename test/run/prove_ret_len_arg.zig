//! signal: ABRT
//! stderr: "panic: index out of bounds: index 3, len 3\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): the
//! argument a callee's result has the length of is counted among the
//! call's runtime arguments, past comptime parameters and through an
//! error union. `make` returns `m` elements, so `s[j]` after `j < n`
//! keeps its check.
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

noinline fn make(s: []u8, comptime T: type, len: usize, other: usize) error{Empty}![]T {
    if (len == 0) return error.Empty;
    return s[0..other];
}

fn main() callconv(.c) noreturn {
    const len = n;
    const s = make(&buf, u8, len, m) catch rt.exit(1);
    var t: u8 = 0;
    var j: usize = 0;
    while (j < len) : (j += 1) t +%= s[j];
    rt.exit(t);
}
