const builtin = @import("builtin");

// aarch64 inline assembly errors point at the failing instruction: its
// line in a multiline template, in an inlined function, or in a switch
// prong.
fn reverse(x: u64) u64 {
    var r: u64 = x;
    asm volatile (
        \\ nop
        \\ rbit %[r], %[r]
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
        .aarch64 => asm volatile ("fmla v0.4s, v1.4s, v2.4s" ::: .{ .v0 = true }),
        else => {},
    }
}

pub fn main() void {
    _ = reverse(3);
    var x: u64 = 0;
    add(&x);
    fused();
}

// error
// args: -target aarch64-linux
// bs-only: upstream assembles inline assembly only when it emits code, which -fno-emit-bin skips, and then with LLVM, which takes rbit and fmla and rejects only ldadd (generic has no LSE)
// asm_insn_aarch64.zig:10:9: error[unsupported]: bs codegen (aarch64): bs does not support this inline assembly instruction yet: 'rbit %[r], %[r]'
//   | \\ rbit %[r], %[r]
// asm_insn_aarch64.zig:17:19: error[unsupported]: bs codegen (aarch64): bs does not support this inline assembly instruction yet: 'ldadd x1, x1, [%[p]]'
//   | asm volatile ("ldadd x1, x1, [%[p]]"
// asm_insn_aarch64.zig:27:35: error[unsupported]: bs codegen (aarch64): bs does not support this inline assembly instruction yet: 'fmla v0.4s, v1.4s, v2.4s'
//   | .aarch64 => asm volatile ("fmla v0.4s, v1.4s, v2.4s" ::: .{ .v0 = true }),
// 3 errors
