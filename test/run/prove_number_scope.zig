//! signal: ABRT
//! stderr: "panic: integer overflow\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): `s.len -
//! x` computed and checked in a switch case did not run on the path
//! that skips the cases, so the equal `s.len - x` after the switch keeps
//! its overflow check (value numbering names an instruction only where
//! it ran).
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var sel: [2]usize = .{ 5, 1 };
var k: u2 = 2;
var sink: usize = 0;

fn main() callconv(.c) noreturn {
    var a: [4]u16 = @splat(7);
    const s: []u16 = a[0..];
    const x = sel[0];
    switch (k) {
        0 => sink = s.len - x,
        1 => sink = s.len - x + 1,
        else => {},
    }
    const t = s.len - x;
    rt.exit(@truncate(t));
}
