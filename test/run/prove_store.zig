//! signal: ABRT
//! stderr: "panic: index out of bounds: index 9, len 4\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): a load
//! reads what a store through the same pointer wrote only while nothing
//! else writes memory. After `p.i = idx`, `s[p.i]` under `idx < 4` needs
//! no check; after a store through `q`, which points to the same box,
//! `p.i` is 9 and the check stays.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const Box = struct { i: usize };
var box: Box = .{ .i = 0 };
var q: *Box = &box;
var idx: usize = 2;
var big: usize = 9;
const arr: [4]u8 = .{ 1, 2, 3, 4 };

fn main() callconv(.c) noreturn {
    const p = &box;
    const s: []const u8 = &arr;
    const i = idx;
    var t: u8 = 0;
    p.i = i;
    if (i < s.len) t +%= s[p.i];
    if (t != 3) rt.exit(1);
    p.i = i;
    if (i < s.len) {
        q.i = big;
        t +%= s[p.i];
    }
    rt.exit(t);
}
