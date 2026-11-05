//! signal: ABRT
//! stderr: "panic: start index 5 is larger than end index 4\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): `start <=
//! start + n` holds only for an addition that cannot have wrapped. `+%`
//! wraps here, so `a[start..end]` keeps its check.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var start: usize = 5;
var n: usize = ~@as(usize, 0);

fn main() callconv(.c) noreturn {
    const a: [8]u8 = @splat(1);
    const end = start +% n;
    rt.exit(@intCast(a[start..end].len));
}
