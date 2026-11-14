// aarch64 inline assembly's Advanced SIMD instructions where upstream's
// assembler (LLVM) rejects the operands: arrangements that do not go
// together, a shift past the element, an element index past the vector,
// a halfword element of a register above v15, immediates no encoding
// holds, a post-index that is not the bytes moved, a register list that
// skips a register, and instructions without their CPU feature. The last
// is undefined to the CPU, though LLVM assembles it: `ext` of eight
// bytes from the ninth.
fn mixed() void {
    asm volatile ("add v0.16b, v1.8b, v2.16b" ::: .{ .v0 = true });
}

fn shift() void {
    asm volatile ("sshr v0.4s, v1.4s, #33" ::: .{ .v0 = true });
}

fn index() void {
    asm volatile ("mov v0.s[4], w9" ::: .{ .v0 = true });
}

fn high() void {
    asm volatile ("mul v0.8h, v1.8h, v16.h[1]" ::: .{ .v0 = true });
}

fn wide() void {
    asm volatile ("movi v0.4s, #256" ::: .{ .v0 = true });
}

fn bytes() void {
    asm volatile ("movi v0.2d, #0x1234" ::: .{ .v0 = true });
}

fn room() void {
    asm volatile ("movi v0.8h, #1, lsl #16" ::: .{ .v0 = true });
}

fn step(p: *const [32]u8) void {
    asm volatile ("ld2 {v0.16b, v1.16b}, [%[p]], #16"
        :
        : [p] "r" (p),
        : .{ .v0 = true, .v1 = true });
}

fn skip() void {
    asm volatile ("tbl v0.16b, {v1.16b, v3.16b}, v2.16b" ::: .{ .v0 = true });
}

fn rounding() void {
    asm volatile ("sqrdmlah v0.4s, v1.4s, v2.4s" ::: .{ .v0 = true });
}

fn half() void {
    asm volatile ("fadd v0.4h, v1.4h, v2.4h" ::: .{ .v0 = true });
}

fn ninth() void {
    asm volatile ("ext v0.8b, v1.8b, v2.8b, #8" ::: .{ .v0 = true });
}

pub fn main() void {
    mixed();
    shift();
    index();
    high();
    wide();
    bytes();
    room();
    step(&@splat(0));
    skip();
    rounding();
    half();
    ninth();
}

// error
// args: -target aarch64-linux
// bs-only: upstream assembles inline assembly only when it emits code, which -fno-emit-bin skips; then LLVM rejects the same lines, but for the 'ext', which it assembles to an undefined instruction
// asm_simd_aarch64.zig:10:19: error[unsupported]: bs codegen (aarch64): inline assembly: 'add' does not take these operands; check each register's arrangement (such as '.16b') and the number of operands: 'add v0.16b, v1.8b, v2.16b'
//   | asm volatile ("add v0.16b, v1.8b, v2.16b" ::: .{ .v0 = true });
// asm_simd_aarch64.zig:14:19: error[unsupported]: bs codegen (aarch64): inline assembly: the shift right is 1 to 32: 'sshr v0.4s, v1.4s, #33'
//   | asm volatile ("sshr v0.4s, v1.4s, #33" ::: .{ .v0 = true });
// asm_simd_aarch64.zig:18:19: error[unsupported]: bs codegen (aarch64): inline assembly: the element index is 0 to 3: 'mov v0.s[4], w9'
//   | asm volatile ("mov v0.s[4], w9" ::: .{ .v0 = true });
// asm_simd_aarch64.zig:22:19: error[unsupported]: bs codegen (aarch64): inline assembly: an element of halfwords is of v0 to v15 here: 'mul v0.8h, v1.8h, v16.h[1]'
//   | asm volatile ("mul v0.8h, v1.8h, v16.h[1]" ::: .{ .v0 = true });
// asm_simd_aarch64.zig:26:19: error[unsupported]: bs codegen (aarch64): inline assembly: the immediate of 'movi' is 0 to 255, with a shift where the elements have room: 'movi v0.4s, #256'
//   | asm volatile ("movi v0.4s, #256" ::: .{ .v0 = true });
// asm_simd_aarch64.zig:30:19: error[unsupported]: bs codegen (aarch64): inline assembly: each byte of this immediate is 0 or 0xff: 'movi v0.2d, #0x1234'
//   | asm volatile ("movi v0.2d, #0x1234" ::: .{ .v0 = true });
// asm_simd_aarch64.zig:34:19: error[unsupported]: bs codegen (aarch64): inline assembly: an immediate in halfwords shifts by 'lsl #0' or 'lsl #8': 'movi v0.8h, #1, lsl #16'
//   | asm volatile ("movi v0.8h, #1, lsl #16" ::: .{ .v0 = true });
// asm_simd_aarch64.zig:38:19: error[unsupported]: bs codegen (aarch64): inline assembly: the post-index immediate is the bytes moved, #32: 'ld2 {v0.16b, v1.16b}, [%[p]], #16'
//   | asm volatile ("ld2 {v0.16b, v1.16b}, [%[p]], #16"
// asm_simd_aarch64.zig:45:19: error[unsupported]: bs codegen (aarch64): inline assembly: a register list is one to four consecutive SIMD registers of one arrangement ('{v1.16b, v2.16b}', '{v1.16b-v4.16b}'), or one element of each ('{v1.b, v2.b}[3]'): 'tbl v0.16b, {v1.16b, v3.16b}, v2.16b'
//   | asm volatile ("tbl v0.16b, {v1.16b, v3.16b}, v2.16b" ::: .{ .v0 = true });
// asm_simd_aarch64.zig:49:19: error[unsupported]: bs codegen (aarch64): inline assembly instruction 'sqrdmlah v0.4s, v1.4s, v2.4s' needs the target CPU feature 'rdm', as upstream's assembler does
//   | asm volatile ("sqrdmlah v0.4s, v1.4s, v2.4s" ::: .{ .v0 = true });
// asm_simd_aarch64.zig:53:19: error[unsupported]: bs codegen (aarch64): inline assembly instruction 'fadd v0.4h, v1.4h, v2.4h' needs the target CPU feature 'fullfp16', as upstream's assembler does
//   | asm volatile ("fadd v0.4h, v1.4h, v2.4h" ::: .{ .v0 = true });
// asm_simd_aarch64.zig:57:19: error[unsupported]: bs codegen (aarch64): inline assembly: the first byte is 0 to 7: 'ext v0.8b, v1.8b, v2.8b, #8'
//   | asm volatile ("ext v0.8b, v1.8b, v2.8b, #8" ::: .{ .v0 = true });
// 12 errors
