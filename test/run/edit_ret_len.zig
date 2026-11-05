//! signal: ABRT
//! stderr: "panic: index out of bounds: index 3, len 3\n"
//! rebuild-replace: "_ = len;\n    return s[0..other];" "_ = other;\n    return s[0..len];"
//! An edit build after an edit to `take`, which `main` calls and does
//! not inline. Before it, `take` returns `len` elements, so `main`'s
//! `a[j]` after `j < len` has no check ("Proving checks"); after it,
//! `take` returns `other` elements. The edit must reach `main` through
//! `take`'s `func_inline` result, which carries what `take` returns, and
//! give its check back.
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

noinline fn take(s: []u8, len: usize, other: usize) []u8 {
    _ = len;
    return s[0..other];
}

fn main() callconv(.c) noreturn {
    const len = n;
    const a = take(&buf, len, m);
    var t: u8 = 0;
    var j: usize = 0;
    while (j < len) : (j += 1) t +%= a[j];
    rt.exit(t);
}
