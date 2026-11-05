//! signal: ABRT
//! stderr: "panic: index out of bounds: index 5, len 3\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): a branch
//! on `i < a.len or j < b.len` goes to its parts directly, and the true
//! side knows only one of them, so `a[i]` keeps its check.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn get(a: []const u8, b: []const u8, i: usize, j: usize) u8 {
    if (i < a.len and j < b.len) return a[i] +% b[j];
    if (i < a.len or j < b.len) return a[i];
    return 0;
}

var idx: usize = 5;
var jdx: usize = 1;

fn main() callconv(.c) noreturn {
    const bytes = [_]u8{ 1, 2, 3, 9, 9, 9, 9, 9 };
    rt.exit(get(bytes[0..3], bytes[0..3], idx, jdx));
}
