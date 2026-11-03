//! exit: 0
//! stdout: "42\n7\n1\n6\n8\n8\n"
const rt = @import("rt.zig");
// For `std.lang.ExportOptions`; std.start sees `_start` and stays out.
const std = @import("std");

// `@export` of a naked entry point whose template is a comptime string
// expression, marked as the outermost frame like std.start's `_start`.
comptime {
    @export(&_start, .{ .name = "_start" });
}

const call_main = "call %[main:P]";

pub fn _start() callconv(.naked) noreturn {
    asm volatile (".cfi_undefined %%rip");
    asm volatile (call_main
        :
        : [main] "X" (&main),
    );
}

fn load(p: *const [2]u64) u64 {
    // `=r` output and a base+displacement memory operand.
    return asm ("movq 8(%%rdi), %[ret]"
        : [ret] "=r" (-> u64),
        : [p] "{rdi}" (p),
    );
}

fn stackPointer() usize {
    return asm ("movq %%rsp, %[ret]"
        : [ret] "=r" (-> usize),
    );
}

fn main() callconv(.c) noreturn {
    const pair: [2]u64 = .{ 1, 42 };
    rt.printInt(load(&pair));
    var out: u32 = undefined;
    asm volatile ("movl $7, %[o]"
        : [o] "=r" (out),
    );
    rt.printInt(out);
    rt.printInt(@intFromBool(stackPointer() % 8 == 0));
    // Local labels, conditional jumps, test, and indirect calls.
    rt.printInt(pick(1));
    rt.printInt(pick(0));
    rt.printInt(countdown(4));
    rt.exit(0);
}

fn seven() callconv(.c) u64 {
    return 7;
}
fn pick(x: u64) u64 {
    return asm volatile (
        \\ testq %%rdi, %%rdi
        \\ jz 1f
        \\ movq $5, %%rax
        \\ jmp 2f
        \\1:
        \\ callq *%%rsi
        \\2: addq $1, %%rax
        : [ret] "={rax}" (-> u64),
        : [x] "{rdi}" (x),
          [f] "{rsi}" (&seven),
        : .{ .rcx = true, .r11 = true, .memory = true });
}
fn countdown(n: u64) u64 {
    return asm volatile (
        \\ xorl %%eax, %%eax
        \\1: addq $2, %%rax
        \\ subq $1, %%rdi
        \\ jnz 1b
        : [ret] "={rax}" (-> u64),
        : [n] "{rdi}" (n),
    );
}
