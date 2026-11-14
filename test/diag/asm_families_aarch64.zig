// aarch64 inline assembly's integer, atomic, memory and floating-point
// families where upstream's assembler (LLVM) rejects the operands, or
// where it accepts what the architecture calls unpredictable: a bitfield
// past its register, a status register that is also stored, a pair
// loaded into one register, a write-back base that is also loaded, an
// atomic instruction without its CPU feature, a byte loaded into an x
// register, an offset out of an unscaled load's range, and
// floating-point immediates `fmov` and `fcmp` cannot encode.
fn field() void {
    asm volatile ("ubfx w9, w10, #20, #13" ::: .{ .x9 = true });
}

fn status(p: *u64) void {
    asm volatile ("stxr w9, x9, [%[p]]"
        :
        : [p] "r" (p),
        : .{ .x9 = true, .memory = true });
}

fn pair(p: *const [2]u64) void {
    asm volatile ("ldp x9, x9, [%[p]]"
        :
        : [p] "r" (p),
        : .{ .x9 = true });
}

fn writeback() void {
    asm volatile ("ldr x9, [x9], #8" ::: .{ .x9 = true });
}

fn swap(p: *u64) void {
    asm volatile ("swp x9, x10, [%[p]]"
        :
        : [p] "r" (p),
        : .{ .x9 = true, .x10 = true, .memory = true });
}

fn byte(p: *const u8) void {
    asm volatile ("ldrb x9, [%[p]]"
        :
        : [p] "r" (p),
        : .{ .x9 = true });
}

fn unscaled(p: *const [512]u8) void {
    asm volatile ("ldurb w9, [%[p], #256]"
        :
        : [p] "r" (p),
        : .{ .x9 = true });
}

fn tenth() void {
    asm volatile ("fmov d0, #0.1" ::: .{ .v0 = true });
}

fn one() void {
    asm volatile ("fcmp d0, #1.0" ::: .{ .nzcv = true });
}

fn bits() void {
    asm volatile ("fcvtzs w9, d0, #33" ::: .{ .x9 = true });
}

pub fn main() void {
    field();
    var word: u64 = 0;
    status(&word);
    pair(&.{ 1, 2 });
    writeback();
    swap(&word);
    byte(&1);
    unscaled(&@splat(0));
    tenth();
    one();
    bits();
}

// error
// args: -target aarch64-linux
// bs-only: upstream assembles inline assembly only when it emits code, which -fno-emit-bin skips; then LLVM rejects the same lines, but for the unpredictable 'ldp', which it assembles
// asm_families_aarch64.zig:10:19: error[unsupported]: bs codegen (aarch64): inline assembly: the field's width here is 1 to 12: 'ubfx w9, w10, #20, #13'
//   | asm volatile ("ubfx w9, w10, #20, #13" ::: .{ .x9 = true });
// asm_families_aarch64.zig:14:19: error[unsupported]: bs codegen (aarch64): inline assembly: the status register is also a source or the base, which is unpredictable: 'stxr w9, x9, [%[p]]'
//   | asm volatile ("stxr w9, x9, [%[p]]"
// asm_families_aarch64.zig:21:19: error[unsupported]: bs codegen (aarch64): inline assembly: the two registers loaded are the same, which is unpredictable: 'ldp x9, x9, [%[p]]'
//   | asm volatile ("ldp x9, x9, [%[p]]"
// asm_families_aarch64.zig:28:19: error[unsupported]: bs codegen (aarch64): inline assembly: the base register written back is also loaded or stored, which is unpredictable: 'ldr x9, [x9], #8'
//   | asm volatile ("ldr x9, [x9], #8" ::: .{ .x9 = true });
// asm_families_aarch64.zig:32:19: error[unsupported]: bs codegen (aarch64): inline assembly instruction 'swp x9, x10, [%[p]]' needs the target CPU feature 'lse', as upstream's assembler does
//   | asm volatile ("swp x9, x10, [%[p]]"
// asm_families_aarch64.zig:39:19: error[unsupported]: bs codegen (aarch64): inline assembly: 'ldrb' takes a w register: 'ldrb x9, [%[p]]'
//   | asm volatile ("ldrb x9, [%[p]]"
// asm_families_aarch64.zig:46:19: error[unsupported]: bs codegen (aarch64): inline assembly: the offset is -256 to 255: 'ldurb w9, [%[p], #256]'
//   | asm volatile ("ldurb w9, [%[p], #256]"
// asm_families_aarch64.zig:53:19: error[unsupported]: bs codegen (aarch64): inline assembly: 'fmov' takes #0.0 or plus or minus 16 to 31 sixteenths times a power of two from 1/8 to 16: 'fmov d0, #0.1'
//   | asm volatile ("fmov d0, #0.1" ::: .{ .v0 = true });
// asm_families_aarch64.zig:57:19: error[unsupported]: bs codegen (aarch64): inline assembly: 'fcmp' compares with a register or #0.0: 'fcmp d0, #1.0'
//   | asm volatile ("fcmp d0, #1.0" ::: .{ .nzcv = true });
// asm_families_aarch64.zig:61:19: error[unsupported]: bs codegen (aarch64): inline assembly: the number of fraction bits is 1 to 32: 'fcvtzs w9, d0, #33'
//   | asm volatile ("fcvtzs w9, d0, #33" ::: .{ .x9 = true });
// 10 errors
