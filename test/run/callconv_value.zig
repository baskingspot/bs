//! exit: 0
//! stdout: "7\n"
const std = @import("std");
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

/// `callconv` takes a value of std's `CallingConvention` computed at
/// comptime, not only a literal (upstream's c_abi tests pick one this way).
const picked: ?std.builtin.CallingConvention = .{ .x86_64_sysv = .{} };

fn add(a: u32, b: u32) callconv(picked orelse .c) u32 {
    return a + b;
}

fn main() callconv(.c) noreturn {
    var a: u32 = 3;
    _ = &a;
    rt.printInt(add(a, 4));
    rt.exit(0);
}
