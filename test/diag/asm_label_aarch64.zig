// aarch64 inline assembly's labels, alignment directives and SIMD loads:
// a branch reaches only a label its own asm defines, a label is defined
// once, alignment pads with nops, and an offset no encoding holds is an
// error that says which offsets one does.
fn elsewhere() void {
    asm volatile (
        \\ cbz x2, .Lret0
        \\ nop
        ::: .{ .x2 = true });
}

fn twice() void {
    asm volatile (
        \\.Lagain:
        \\ nop
        \\.Lagain:
        \\ b .Lagain
    );
}

fn filled() void {
    asm volatile (
        \\ nop
        \\ .p2align 4, 0
    );
}

fn unpadded() void {
    asm volatile (
        \\ nop
        \\ .p2align 4,,0
    );
}

fn odd(p: *const [32]u8) void {
    asm volatile ("ldp q0, q1, [%[p], #8]"
        :
        : [p] "r" (p),
        : .{ .v0 = true, .v1 = true });
}

fn far(p: *const [32]u8) void {
    asm volatile ("ldur q0, [%[p], #256]"
        :
        : [p] "r" (p),
        : .{ .v0 = true });
}

pub fn main() void {
    elsewhere();
    twice();
    filled();
    unpadded();
    odd(&@splat(0));
    far(&@splat(0));
}

// error
// args: -target aarch64-linux
// bs-only: upstream assembles inline assembly only when it emits code, which -fno-emit-bin skips; then LLVM rejects the same lines, but takes '.Lret0' as a symbol for the linker to find and pads with the fill value
// asm_label_aarch64.zig:7:9: error[unsupported]: bs codegen (aarch64): asm branches to '.Lret0', which is not a label this asm defines; bs resolves a label only in the asm that defines it, and does not resolve a symbol by name (pass it as an operand)
//   | \\ cbz x2, .Lret0
// asm_label_aarch64.zig:16:9: error[unsupported]: bs codegen (aarch64): asm label '.Lagain' is defined twice
//   | \\.Lagain:
// asm_label_aarch64.zig:24:9: error[unsupported]: bs codegen (aarch64): bs pads code with nops only, not with the fill value of '.p2align 4, 0'
//   | \\ .p2align 4, 0
// asm_label_aarch64.zig:31:9: error[unsupported]: bs codegen (aarch64): the most padding '.p2align 4,,0' allows is less than 1 byte, which upstream's assembler (LLVM) rejects
//   | \\ .p2align 4,,0
// asm_label_aarch64.zig:36:19: error[unsupported]: bs codegen (aarch64): inline assembly: the offset is a multiple of 16 from -1024 to 1008: 'ldp q0, q1, [%[p], #8]'
//   | asm volatile ("ldp q0, q1, [%[p], #8]"
// asm_label_aarch64.zig:43:19: error[unsupported]: bs codegen (aarch64): inline assembly: the offset is -256 to 255: 'ldur q0, [%[p], #256]'
//   | asm volatile ("ldur q0, [%[p], #256]"
// 6 errors
