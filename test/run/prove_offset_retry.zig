//! signal: ABRT
//! stderr: "panic: index out of bounds: index 49, len 48\n"
//! Proving checks (docs/architecture.md, "Proving checks"): the walk
//! assuming `i < len` at the loop's start fails at the back edge, where
//! the exit test gives only `i <= len`, and the body is walked again
//! without it. Facts from the failed walk must not survive into the
//! second: they name loads whose values the second walk changes, and
//! kept, they removed `s[i + 3]`'s check, which fails at `i` 46.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var start: usize = 30;
var n: usize = 48;

fn main() callconv(.c) noreturn {
    var buf: [128]u8 = undefined;
    for (&buf, 0..) |*c, k| c.* = @truncate(k *% 7 + 1);
    const s: []const u8 = buf[0..n];
    var i: usize = start;
    var sum: u8 = 0;
    if (i + 0 < s.len) while (true) {
        sum +%= s[i + 3];
        i += 4;
        if (i + 0 > s.len) break;
    };
    rt.exit(sum);
}
