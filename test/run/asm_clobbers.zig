//! exit: 0
//! stderr: "34 5\n"
//! targets: aarch64-macos aarch64-linux

// A context switch (zio's coroutines) names the callee-saved registers it
// changes only as clobbers, x19-x28 and v8-v15 (or their other names,
// w25, d9, z10), not in its template: the asm saves them for its caller,
// whose integers and floats live there across the call. Elsewhere the
// switch does nothing.
const std = @import("std");
const builtin = @import("builtin");

fn trash() callconv(.naked) void {
    asm volatile (
        \\ mov x19, #0
        \\ mov x20, #0
        \\ mov x21, #0
        \\ mov x22, #0
        \\ mov x23, #0
        \\ mov x24, #0
        \\ mov x25, #0
        \\ mov x26, #0
        \\ mov x27, #0
        \\ mov x28, #0
        \\ movi v8.16b, #0
        \\ movi v9.16b, #0
        \\ movi v10.16b, #0
        \\ movi v11.16b, #0
        \\ movi v12.16b, #0
        \\ movi v13.16b, #0
        \\ movi v14.16b, #0
        \\ movi v15.16b, #0
        \\ ret
    );
}

noinline fn switchLike(f: *const fn () callconv(.naked) void) void {
    if (builtin.cpu.arch != .aarch64) return;
    asm volatile ("blr %[f]"
        :
        : [f] "r" (f),
        : .{ .x19 = true, .x20 = true, .x21 = true, .x22 = true, .x23 = true, .x24 = true, .w25 = true, .x26 = true, .x27 = true, .x28 = true, .lr = true, .v8 = true, .d9 = true, .z10 = true, .v11 = true, .v12 = true, .v13 = true, .v14 = true, .v15 = true, .memory = true });
}

noinline fn live(x: u64, y: f64) void {
    const a = x *% 3;
    const b = x +% 11;
    const c = x ^ 6;
    const p = y * 2;
    const q = y + 0.5;
    switchLike(if (builtin.cpu.arch == .aarch64) &trash else undefined);
    std.debug.print("{d} {d}\n", .{ a +% b +% c, p + q });
}

pub fn main() void {
    live(5, 1.5);
}
