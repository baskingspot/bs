//! exit: 0
//! stderr: "107 107 17\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux
//! upstream-llvm: true

// An assembly statement's register operands get no register its clobbers
// name: a statement that writes a clobbered register before it reads an
// operand still reads the operand. Upstream's self-hosted x86_64 backend
// gives a `+r` output a clobbered register too, so its LLVM build is the
// oracle.
const std = @import("std");
const builtin = @import("builtin");
const a64 = builtin.cpu.arch == .aarch64;

/// a + 7, after the template writes the registers `r` inputs get first.
noinline fn inClobbered(a: u64) u64 {
    return if (a64)
        asm volatile (
            \\ mov x9, #6
            \\ add %[r], %[a], #7
            : [r] "={x0}" (-> u64),
            : [a] "r" (a),
            : .{ .x9 = true })
    else
        asm volatile (
            \\ movq $7, %%rbx
            \\ movq $9, %%r12
            \\ movq $2, %%rsi
            \\ movq $4, %%rdi
            \\ movl $6, %%r8d
            \\ movq %[a], %[r]
            \\ addq %%rbx, %[r]
            : [r] "=r" (-> u64),
            : [a] "r" (a),
            : .{ .rbx = true, .r12 = true, .rsi = true, .rdi = true, .r8d = true });
}

/// The result of a `+r` output, which the template computes after writing
/// the registers outputs get first.
noinline fn outClobbered(a: u64) u64 {
    var x = a;
    if (a64) {
        asm volatile (
            \\ mov x9, #1
            \\ add %[x], %[x], #7
            : [x] "+r" (x),
            :
            : .{ .x9 = true });
    } else {
        asm volatile (
            \\ movl $1, %%eax
            \\ addq $7, %[x]
            : [x] "+r" (x),
            :
            : .{ .eax = true });
    }
    return x;
}

pub fn main() void {
    var a: u64 = 100;
    var b: u64 = 10;
    _ = .{ &a, &b };
    std.debug.print("{d} {d} {d}\n", .{ inClobbered(a), outClobbered(a), outClobbered(b) });
}
