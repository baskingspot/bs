//! signal: ABRT
//! stdout: "21\n8\n610\n"
//! stderr: "panic: index out of bounds: index 3, len 3\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): the checks
//! in `sum`, `twice`, and `fib` are proven and go, and the results stay.
//! In `grow`, `i < s.len` holds before the loop, but the loop's store to
//! `i` reaches its start again, so the check of `s[i]` stays and fails on
//! the fourth iteration.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn sum(s: []const u32) u64 {
    var t: u64 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) t += s[i];
    return t;
}

fn twice(s: []const u32, i: usize) u32 {
    return s[i] + s[i];
}

fn fib(n: u32) u32 {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

fn grow(s: []const u8, start: usize) u8 {
    var i = start;
    var acc: u8 = 0;
    if (i < s.len) {
        while (true) {
            acc +%= s[i];
            i += 1;
        }
    }
    return acc;
}

var count: usize = 6;
var at: usize = 3;
var fib_n: u32 = 15;

fn main() callconv(.c) noreturn {
    const nums = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    rt.printInt(sum(nums[0..count]));
    rt.printInt(twice(nums[0..count], at));
    rt.printInt(fib(fib_n));
    const bytes = [_]u8{ 1, 2, 3, 9, 9, 9 };
    rt.exit(grow(bytes[0..at], 0));
}
