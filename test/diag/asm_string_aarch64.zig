// aarch64 inline assembly's string-routine instructions where upstream's
// assembler (LLVM) rejects the operands: an alias of conditional select
// has no 'al' condition, a conditional compare's immediate and a
// move-wide shift have their ranges, 'ld1' steps its base by the bytes it
// loads, and a crypto instruction needs its CPU feature.
fn always() void {
    asm volatile ("cset w9, al" ::: .{ .x9 = true });
}

fn wide() void {
    asm volatile (
        \\ cmp x9, #1
        \\ ccmp w9, #32, #0, eq
        ::: .{ .x9 = true, .nzcv = true });
}

fn shifted() void {
    asm volatile ("movz w9, #1, lsl #32" ::: .{ .x9 = true });
}

fn step(p: *const [16]u8) void {
    asm volatile ("ld1 {v0.16b}, [%[p]], #8"
        :
        : [p] "r" (p),
        : .{ .v0 = true });
}

fn round() void {
    asm volatile ("aese v0.16b, v1.16b" ::: .{ .v0 = true });
}

pub fn main() void {
    always();
    wide();
    shifted();
    step(&@splat(0));
    round();
}

// error
// args: -target aarch64-linux
// bs-only: upstream assembles inline assembly only when it emits code, which -fno-emit-bin skips; then LLVM rejects the same lines
// asm_string_aarch64.zig:7:19: error[unsupported]: bs codegen (aarch64): inline assembly: 'cset' takes no condition 'al' or 'nv': 'cset w9, al'
//   | asm volatile ("cset w9, al" ::: .{ .x9 = true });
// asm_string_aarch64.zig:13:9: error[unsupported]: bs codegen (aarch64): inline assembly: 'ccmp' compares with a register or an immediate from 0 to 31: 'ccmp w9, #32, #0, eq'
//   | \\ ccmp w9, #32, #0, eq
// asm_string_aarch64.zig:18:19: error[unsupported]: bs codegen (aarch64): inline assembly: 'movz' shifts its immediate left by 0 or 16: 'movz w9, #1, lsl #32'
//   | asm volatile ("movz w9, #1, lsl #32" ::: .{ .x9 = true });
// asm_string_aarch64.zig:22:19: error[unsupported]: bs codegen (aarch64): inline assembly: the post-index immediate is the bytes moved, #16: 'ld1 {v0.16b}, [%[p]], #8'
//   | asm volatile ("ld1 {v0.16b}, [%[p]], #8"
// asm_string_aarch64.zig:29:19: error[unsupported]: bs codegen (aarch64): inline assembly instruction 'aese v0.16b, v1.16b' needs the target CPU feature 'aes', as upstream's assembler does
//   | asm volatile ("aese v0.16b, v1.16b" ::: .{ .v0 = true });
// 5 errors
