//! signal: ABRT
//! stderr: "panic: index out of bounds: index 3, len 3\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): a range
//! prong's case knows `lo <= x <= hi`, inclusive, so `0...3` does not
//! prove an index below 3.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var arr = [3]u8{ 1, 2, 3 };

fn get(i: usize) u8 {
    switch (i) {
        0...3 => return arr[i],
        else => return 0,
    }
}

var idx: usize = 3;

fn main() callconv(.c) noreturn {
    rt.exit(get(idx));
}
