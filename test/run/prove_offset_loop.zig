//! signal: ABRT
//! stderr: "panic: index out of bounds: index 76, len 64\n"
//! Proving checks (docs/architecture.md, "Proving checks"): `i + 32 <
//! len` before the loop holds at its start only if it holds again at
//! the back edge. The exit test there gives only `i < len`, so
//! `s[i..][0..16]` keeps its checks, and the fourth iteration (`i` 60)
//! fails them.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var start: usize = 0;
var n: usize = 64;

fn main() callconv(.c) noreturn {
    const a: [64]u8 = @splat(1);
    const s: []const u8 = a[0..n];
    var i: usize = start;
    var sum: u32 = 0;
    if (i + 32 < s.len) while (true) {
        sum += s[i..][0..16][15];
        i += 20;
        if (i >= s.len) break;
    };
    rt.exit(@truncate(sum));
}
