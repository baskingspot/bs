const builtin = @import("builtin");

// aarch64 inline assembly errors point at the failing instruction: its
// line in a multiline template, in an inlined function, or in a switch
// prong, also when an operand's expression has a position of its own;
// once, also when the inliner copied the function into its callers.
fn reverse(x: u64) u64 {
    var r: u64 = x;
    asm volatile (
        \\ nop
        \\ udiv %[r], %[r], sp
        : [r] "+r" (r),
    );
    return r;
}

inline fn add(p: *u64) void {
    asm volatile ("ldadd x1, x1, [%[p]]"
        :
        : [p] "r" (p),
        : .{ .x1 = true, .memory = true });
}

fn fused() void {
    var x: u64 = 0;
    x += 1;
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile ("fmov d0, #0.1" ::: .{ .v0 = true }),
        else => {},
    }
}

fn indexed(x: [2]u64) u64 {
    return asm ("ubfx %[r], %[a], #60, #8"
        : [r] "=r" (-> u64),
        : [a] "r" (x[1]),
    );
}

pub fn main() void {
    _ = reverse(3);
    _ = reverse(4);
    var x: u64 = 0;
    add(&x);
    fused();
    _ = indexed(.{ 1, 2 });
}

// error
// args: -target aarch64-linux
// bs-only: upstream assembles inline assembly only when it emits code, which -fno-emit-bin skips; then LLVM rejects the same lines
// asm_insn_aarch64.zig:11:9: error[unsupported]: bs codegen (aarch64): inline assembly: sp is not a valid operand there (register 31 is zr in that position): 'udiv %[r], %[r], sp'
//   | \\ udiv %[r], %[r], sp
// asm_insn_aarch64.zig:18:19: error[unsupported]: bs codegen (aarch64): inline assembly instruction 'ldadd x1, x1, [%[p]]' needs the target CPU feature 'lse', as upstream's assembler does
//   | asm volatile ("ldadd x1, x1, [%[p]]"
// asm_insn_aarch64.zig:28:35: error[unsupported]: bs codegen (aarch64): inline assembly: 'fmov' takes #0.0 or plus or minus 16 to 31 sixteenths times a power of two from 1/8 to 16: 'fmov d0, #0.1'
//   | .aarch64 => asm volatile ("fmov d0, #0.1" ::: .{ .v0 = true }),
// asm_insn_aarch64.zig:34:17: error[unsupported]: bs codegen (aarch64): inline assembly: the field's width here is 1 to 4: 'ubfx %[r], %[a], #60, #8'
//   | return asm ("ubfx %[r], %[a], #60, #8"
// 4 errors
