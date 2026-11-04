//! x86_64 atomics on 16-byte values (`u128`, `i128`, 128-bit enums and
//! packed structs, `f80`, `f128`) with `lock cmpxchg16b`, which CPUs with
//! cx16 have. Sema allows them only then, as upstream's
//! `atomicPtrAlignment` does; their ABI alignment is 16, as cmpxchg16b
//! requires.
//!
//! cmpxchg16b compares rdx:rax with the 16 bytes at its operand; if they
//! are equal it stores rcx:rbx there and sets ZF, else it loads them into
//! rdx:rax. A load is a cmpxchg16b of zero with zero, a store and every
//! `@atomicRmw` a cmpxchg16b loop (upstream lowers the read-modify-write
//! operations the same way; its 0.17.0 backend fails on 128-bit loads and
//! stores, where zap does what LLVM does).
//!
//! These instructions are clobber points (`CodeGen.clobbers`), so the
//! caller-saved registers are free. rbx is callee-saved and may hold a
//! value, so it is pushed and popped around its use: frame slots are
//! rbp-relative, and no outgoing arguments are being set up. Operands are
//! read into registers before rbx is written, and put in memory
//! (`memOf`, which may copy through rax, xmm0, r10 and r11) before any
//! register is loaded. 16-byte values live in
//! memory (wide integers; f80 and f128).

const std = @import("std");
const Ir = @import("../../Ir.zig");
const Inst = Ir.Inst;
const InternPool = @import("../../InternPool.zig");
const Type = @import("../../Type.zig");
const Encoder = @import("Encoder.zig");
const CodeGen = @import("CodeGen.zig");
const Mem = Encoder.Mem;
const Reg = Encoder.Reg;
const Error = CodeGen.Error;
const offsetMem = CodeGen.offsetMem;

/// The pointer register: not one cmpxchg16b uses.
const ptr_reg: Reg = .r10;

/// Whether atomic operations on `ty` are lowered here.
pub fn is128(cg: *CodeGen, ty: InternPool.Index) bool {
    return Type.abiSize(cg.ip, ty) == 16;
}

/// Loads the 16-byte value at `m` into `lo` and `hi`.
fn loadValue(cg: *CodeGen, lo: Reg, hi: Reg, m: Mem) Error!void {
    try cg.e.mov(.qword, .{ .reg = lo }, .{ .mem = m });
    try cg.e.mov(.qword, .{ .reg = hi }, .{ .mem = offsetMem(m, 8) });
}

/// Stores rdx:rax, the value cmpxchg16b found, as `inst`'s result.
fn storeOld(cg: *CodeGen, inst: Inst.Index, ty: InternPool.Index) Error!void {
    const dst = try cg.resultMem(inst, ty) orelse return;
    try cg.e.mov(.qword, .{ .mem = dst }, .{ .reg = .rax });
    try cg.e.mov(.qword, .{ .mem = offsetMem(dst, 8) }, .{ .reg = .rdx });
}

/// `@atomicLoad`: cmpxchg16b with rdx:rax = rcx:rbx = 0 stores 0 over 0
/// or loads the value.
pub fn load(cg: *CodeGen, inst: Inst.Index, data: Inst.Data) Error!void {
    const e = &cg.e;
    try cg.load(ptr_reg, data.ty_op.operand);
    try e.push(.rbx);
    for ([_]Reg{ .rax, .rdx, .rbx, .rcx }) |r| try e.alu(.xor, .dword, .{ .reg = r }, .{ .reg = r });
    try e.lockCmpxchg16b(Mem.at(ptr_reg, 0));
    try e.pop(.rbx);
    try storeOld(cg, inst, data.ty_op.ty);
}

/// `@atomicStore`: a cmpxchg16b loop until the new value is stored over
/// the one found.
pub fn store(cg: *CodeGen, data: Inst.Data) Error!void {
    const e = &cg.e;
    const v = try cg.memOf(data.bin_op.rhs);
    try cg.load(ptr_reg, data.bin_op.lhs);
    try loadValue(cg, .rsi, .rdi, v);
    const m = Mem.at(ptr_reg, 0);
    try e.mov(.qword, .{ .reg = .rax }, .{ .mem = m });
    try e.mov(.qword, .{ .reg = .rdx }, .{ .mem = offsetMem(m, 8) });
    try e.push(.rbx);
    try e.mov(.qword, .{ .reg = .rbx }, .{ .reg = .rsi });
    try e.mov(.qword, .{ .reg = .rcx }, .{ .reg = .rdi });
    const top = try e.newLabel();
    e.bind(top);
    try e.lockCmpxchg16b(m);
    try e.jcc(.ne, .{ .label = top });
    try e.pop(.rbx);
}

/// `@cmpxchgStrong` and `@cmpxchgWeak` (cmpxchg16b does not fail
/// spuriously): null on success, else the value found.
pub fn cmpxchg(cg: *CodeGen, inst: Inst.Index, data: Inst.Data) Error!void {
    const e = &cg.e;
    const x = cg.ir.extraData(Ir.Cmpxchg, data.ty_pl.payload).data;
    const expected = try cg.memOf(x.expected);
    const new = try cg.memOf(x.new);
    try cg.load(ptr_reg, x.ptr);
    try loadValue(cg, .rax, .rdx, expected);
    try loadValue(cg, .rsi, .rdi, new);
    try e.push(.rbx);
    try e.mov(.qword, .{ .reg = .rbx }, .{ .reg = .rsi });
    try e.mov(.qword, .{ .reg = .rcx }, .{ .reg = .rdi });
    try e.lockCmpxchg16b(Mem.at(ptr_reg, 0));
    try e.pop(.rbx);
    try e.setcc(.ne, .{ .reg = .r8 });
    const opt_ty = data.ty_pl.ty;
    const dst = try cg.resultMem(inst, opt_ty) orelse return;
    try e.mov(.qword, .{ .mem = dst }, .{ .reg = .rax });
    try e.mov(.qword, .{ .mem = offsetMem(dst, 8) }, .{ .reg = .rdx });
    try e.mov(.byte, .{ .mem = offsetMem(dst, Type.optionalFlagOffset(cg.ip, opt_ty)) }, .{ .reg = .r8 });
}

/// `@atomicRmw`: the new value computed in rcx:rbx from the old one in
/// rdx:rax and the operand in rdi:rsi, then cmpxchg16b, until no other
/// write came between. The result is the old value.
pub fn rmw(cg: *CodeGen, inst: Inst.Index, data: Inst.Data) Error!void {
    const e = &cg.e;
    const ip = cg.ip;
    const x = cg.ir.extraData(Ir.AtomicRmw, data.ty_pl.payload).data;
    const ty = data.ty_pl.ty;
    const op = x.operation();
    const operand = try cg.memOf(x.operand);
    try cg.load(ptr_reg, x.ptr);
    try loadValue(cg, .rsi, .rdi, operand);
    const m = Mem.at(ptr_reg, 0);
    try e.mov(.qword, .{ .reg = .rax }, .{ .mem = m });
    try e.mov(.qword, .{ .reg = .rdx }, .{ .mem = offsetMem(m, 8) });
    try e.push(.rbx);
    const top = try e.newLabel();
    e.bind(top);
    if (op == .Xchg) {
        try e.mov(.qword, .{ .reg = .rbx }, .{ .reg = .rsi });
        try e.mov(.qword, .{ .reg = .rcx }, .{ .reg = .rdi });
    } else {
        // Arithmetic is on integers (Sema refuses it on f80 and f128).
        const info = Type.intInfo(ip, ty);
        const signed = info.signedness == .signed;
        try e.mov(.qword, .{ .reg = .rbx }, .{ .reg = .rax });
        try e.mov(.qword, .{ .reg = .rcx }, .{ .reg = .rdx });
        switch (op) {
            .Add, .Sub, .And, .Or, .Xor, .Nand => {
                const lo: Encoder.AluOp, const hi: Encoder.AluOp = switch (op) {
                    .Add => .{ .add, .adc },
                    .Sub => .{ .sub, .sbb },
                    .Or => .{ .@"or", .@"or" },
                    .Xor => .{ .xor, .xor },
                    else => .{ .@"and", .@"and" },
                };
                try e.alu(lo, .qword, .{ .reg = .rbx }, .{ .reg = .rsi });
                try e.alu(hi, .qword, .{ .reg = .rcx }, .{ .reg = .rdi });
                if (op == .Nand) {
                    try e.unary(.not, .qword, .{ .reg = .rbx });
                    try e.unary(.not, .qword, .{ .reg = .rcx });
                }
                // Wrapped back to the type's width (`normalizeWide`):
                // the bits above it copy the sign bit or are zero.
                if (info.bits < 128 and (op == .Add or op == .Sub or op == .Nand)) {
                    const sh: u8 = @intCast(128 - info.bits);
                    try e.shift(.shl, .qword, .{ .reg = .rcx }, sh);
                    try e.shift(if (signed) .sar else .shr, .qword, .{ .reg = .rcx }, sh);
                }
            },
            .Max, .Min => {
                // Flags of `a - b` for the 128-bit compare: old - operand
                // for max, operand - old for min; less than takes the
                // operand.
                const a_lo: Reg, const a_hi: Reg, const b_lo: Reg, const b_hi: Reg = if (op == .Max)
                    .{ .rbx, .rcx, .rsi, .rdi }
                else
                    .{ .rsi, .rdi, .rbx, .rcx };
                try e.mov(.qword, .{ .reg = .r8 }, .{ .reg = a_hi });
                try e.alu(.cmp, .qword, .{ .reg = a_lo }, .{ .reg = b_lo });
                try e.alu(.sbb, .qword, .{ .reg = .r8 }, .{ .reg = b_hi });
                const less: Encoder.Cond = if (signed) .l else .b;
                try e.cmov(less, .qword, .rbx, .{ .reg = .rsi });
                try e.cmov(less, .qword, .rcx, .{ .reg = .rdi });
            },
            .Xchg => unreachable,
        }
    }
    try e.lockCmpxchg16b(m);
    try e.jcc(.ne, .{ .label = top });
    try e.pop(.rbx);
    try storeOld(cg, inst, ty);
}
