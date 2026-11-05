const builtin = @import("builtin");

// Inline assembly errors point at the failing instruction: its line in a
// multiline template, in an inlined function, or in a switch prong.
fn widen(b: u8) u32 {
    var d: u32 = 0;
    asm volatile (
        \\ nop
        \\ movzbl %[b], %[d]
        : [d] "+r" (d),
        : [b] "r" (b),
    );
    return d;
}

inline fn prefetch(p: *const u8) void {
    asm volatile ("prefetcht0 (%%rdi)"
        :
        : [p] "{rdi}" (p),
    );
}

fn bump() void {
    var x: u64 = 0;
    x += 1;
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("incl %%rax" ::: .{ .rax = true }),
        else => {},
    }
}

fn random() u64 {
    return asm volatile ("rdrand %%rax"
        : [r] "={rax}" (-> u64),
    );
}

pub fn main() void {
    _ = widen(3);
    var x: u8 = 0;
    prefetch(&x);
    bump();
    _ = random();
}

// error
// args: -mcpu=baseline
// bs-only: upstream assembles inline assembly only when it emits code, which -fno-emit-bin skips; it rejects all four instructions when it does
// asm_insn.zig:9:9: error[unsupported]: bs codegen: 'movzbl' is GNU as's name for an instruction that upstream zig's assembler calls 'movzx' (it takes Intel mnemonics, with an optional b, w, l or q size suffix): 'movzbl %[b], %[d]'
//   | \\ movzbl %[b], %[d]
// asm_insn.zig:17:19: error[unsupported]: bs codegen: asm memory operand 1 has no size: give 'prefetcht0' a size suffix (b, w, l or q), as upstream zig requires: 'prefetcht0 (%%rdi)'
//   | asm volatile ("prefetcht0 (%%rdi)"
// asm_insn.zig:27:34: error[unsupported]: bs codegen: asm register operand 1 does not have the size of the suffix of 'incl': 'incl %%rax'
//   | .x86_64 => asm volatile ("incl %%rax" ::: .{ .rax = true }),
// asm_insn.zig:33:26: error[unsupported]: bs codegen: 'rdrand' needs the CPU feature rdrnd (-mcpu=native on a CPU that has it, or -mcpu=x86_64_v2+rdrnd): 'rdrand %%rax'
//   | return asm volatile ("rdrand %%rax"
// 4 errors
