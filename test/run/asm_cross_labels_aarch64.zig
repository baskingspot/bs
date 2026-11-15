//! exit: 0
//! stderr: "1 2 100 2\n"
//! targets: aarch64-linux
//! aarch64 inline assembly that branches to labels another function's
//! assembly defines, as fastmem's SVE move entry branches into its copy
//! entry: a conditional branch and a `tbz` reach them, the two functions
//! stay together in their `linksection`, and a `.globl` label is a symbol
//! Zig code calls through `@extern`. upstream prints the same. Other
//! targets print the same text without running the assembly.
const std = @import("std");
const builtin = @import("builtin");

fn head() linksection(".text.pair") callconv(.naked) void {
    asm volatile (
        \\    cmp x0, #5
        \\    b.hi .Lbig
        \\    tbz x0, #0, .Leven
        \\    mov x0, #1
        \\    ret
    );
}

fn tail() linksection(".text.pair") callconv(.naked) void {
    asm volatile (
        \\    .globl cross_mid
        \\    .hidden cross_mid
        \\.Lbig:
        \\    mov x0, #100
        \\    ret
        \\.Leven:
        \\cross_mid:
        \\    mov x0, #2
        \\    ret
    );
}

// A reference alone does not keep `tail` in an optimized upstream build.
comptime {
    if (builtin.cpu.arch == .aarch64) @export(&tail, .{ .name = "cross_tail", .visibility = .hidden });
}

const F = *const fn (u64) callconv(.c) u64;
const mid = @extern(F, .{ .name = "cross_mid", .visibility = .hidden });

pub fn main() void {
    if (builtin.cpu.arch != .aarch64) {
        std.debug.print("1 2 100 2\n", .{});
        return;
    }
    const f: F = @ptrCast(&head);
    std.debug.print("{d} {d} {d} {d}\n", .{ f(1), f(2), f(9), mid(7) });
}
