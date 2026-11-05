//! exit: 46
//! targets: aarch64-linux aarch64-macos
//! upstream-llvm: true
//! rebuild-replace: "return @intCast(sum);" "return @intCast(sum - 1);"
//! Container-level assembly, which bs assembles into the module's code
//! (upstream's self-hosted backends drop it; its LLVM backend assembles
//! it): the langref's `my_func`, a second global after the start of its
//! block, a local label, and a template that is a comptime string
//! expression. The edit leaves the comptime block green, so an edit
//! build takes its atom from the cache.
const builtin = @import("builtin");

/// On macOS, C names carry a leading underscore.
const prefix = if (builtin.os.tag == .macos) "_" else "";

comptime {
    switch (builtin.cpu.arch) {
        .x86_64 => asm (
            \\.global my_func;
            \\.type my_func, @function;
            \\my_func:
            \\  lea (%rdi,%rsi,1),%eax
            \\  retq
            \\.globl clamp10
            \\clamp10:
            \\  mov %edi, %eax
            \\  cmp $10, %edi
            \\  jle 1f
            \\  mov $10, %eax
            \\1: ret
        ),
        .aarch64 => asm (".p2align 2\n.global " ++ prefix ++ "my_func\n" ++ prefix ++ "my_func:\n" ++
                \\  add w0, w0, w1
                \\  ret
                \\
            ++ ".globl " ++ prefix ++ "clamp10\n" ++ prefix ++ "clamp10:\n" ++
                \\  cmp w0, #10
                \\  b.le 1f
                \\  mov w0, #10
                \\1: ret
            ),
        else => unreachable,
    }
}

extern fn my_func(a: i32, b: i32) i32;
extern fn clamp10(a: i32) i32;

pub fn main() u8 {
    const sum = my_func(12, 24) + clamp10(40) + clamp10(4) - 4;
    return @intCast(sum);
}
