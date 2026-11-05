//! signal: ABRT
//! stderr: "panic: index out of bounds: index 249, len 249\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): a
//! switch's else body knows the operand is below a range that reaches the
//! type's end, `x < 250` here, which does not prove an index below 249.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var big: [249]u8 = @splat(7);

fn pick(x: u8) u8 {
    switch (x) {
        250...255 => return 1,
        else => return big[x],
    }
}

var sel: u8 = 249;

fn main() callconv(.c) noreturn {
    rt.exit(pick(sel));
}
