//! signal: ABRT
//! stderr: "panic: index out of bounds: index 1, len 1\n"
//! Proving checks (docs/architecture.md, "Proving checks"): a load is the
//! value the variable held where it runs. `v +%= 1` reads `v` before the
//! store; read as `v`'s later value, `v + 1` would be `v` itself and
//! `j <= a.len` would prove `j < a.len`.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var g: u16 = 0;

fn main() callconv(.c) noreturn {
    var v: u16 = g;
    v +%= 1;
    const a: [1]u16 = @splat(v);
    const j: usize = @as(usize, v);
    if (j <= a.len) rt.exit(@truncate(a[j]));
    rt.exit(0);
}
