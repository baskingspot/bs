// aarch64 inline assembly rejects the shifted and extended register
// operands that upstream's assembler (LLVM) rejects: ror on an add, a
// shift past the register's width, an extension of the wrong register
// width, and sp where the instruction writes zr instead.
fn rotated(a: u64, b: u64) u64 {
    return asm ("add %[o], %[a], %[b], ror #8"
        : [o] "=r" (-> u64),
        : [a] "r" (a),
          [b] "r" (b),
    );
}

fn wide(a: u32, b: u32) u32 {
    return asm ("orr %[o:w], %[a:w], %[b:w], lsl #32"
        : [o] "=r" (-> u32),
        : [a] "r" (a),
          [b] "r" (b),
    );
}

fn extended(a: u64, b: u64) u64 {
    return asm ("add %[o], %[a], %[b], uxtw #2"
        : [o] "=r" (-> u64),
        : [a] "r" (a),
          [b] "r" (b),
    );
}

fn flags(b: u64) void {
    asm volatile ("adds sp, sp, %[b], lsl #2"
        :
        : [b] "r" (b),
        : .{ .nzcv = true });
}

pub fn main() void {
    _ = rotated(1, 2);
    _ = wide(1, 2);
    _ = extended(1, 2);
    flags(0);
}

// error
// args: -target aarch64-linux
// bs-only: upstream assembles inline assembly only when it emits code, which -fno-emit-bin skips, and then with LLVM, which rejects all four
// asm_shift_aarch64.zig:6:17: error[unsupported]: bs codegen (aarch64): inline assembly: an add or sub register shifts by 'lsl', 'lsr' or 'asr' 0 to 63: 'add %[o], %[a], %[b], ror #8'
//   | return asm ("add %[o], %[a], %[b], ror #8"
// asm_shift_aarch64.zig:14:17: error[unsupported]: bs codegen (aarch64): inline assembly: a logical instruction's register shifts by 'lsl', 'lsr', 'asr' or 'ror' 0 to 31: 'orr %[o:w], %[a:w], %[b:w], lsl #32'
//   | return asm ("orr %[o:w], %[a:w], %[b:w], lsl #32"
// asm_shift_aarch64.zig:22:17: error[unsupported]: bs codegen (aarch64): inline assembly: 'uxtw' here extends a w register, shifted left by 0 to 4: 'add %[o], %[a], %[b], uxtw #2'
//   | return asm ("add %[o], %[a], %[b], uxtw #2"
// asm_shift_aarch64.zig:30:19: error[unsupported]: bs codegen (aarch64): inline assembly: sp is not a valid operand there (register 31 is zr in that position): 'adds sp, sp, %[b], lsl #2'
//   | asm volatile ("adds sp, sp, %[b], lsl #2"
// 4 errors
