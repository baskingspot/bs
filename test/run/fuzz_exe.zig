//! exit: 0
//! stdout: "1\n7\n"
//! flags: -ffuzz
//! A non-test executable built with -ffuzz links and runs, as upstream's
//! default build does: bs instruments it but links no fuzzer, whose
//! `runner_*` callbacks only the test runner defines.
const rt = @import("rt.zig");
pub const panic = rt.panic;

fn pick(n: u8) u64 {
    return if (n > 3) 7 else 1;
}

pub fn main() void {
    rt.printInt(@intFromBool(@import("builtin").fuzz));
    var n: u8 = 5;
    _ = &n;
    rt.printInt(pick(n));
}
