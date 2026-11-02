//! Debug code generation for x86_64: one function's IR to one Atom, in a
//! single pass. The strategy is the one in docs/architecture.md: every IR
//! value with runtime bits lives in a stack slot, and each instruction loads
//! its operands into scratch registers, computes, and stores its result.
//! No value stays in a register across instructions.
//!
//! Frame: `push rbp; mov rbp, rsp; sub rsp, N`. Slots are at negative
//! offsets from rbp; outgoing call arguments are at the bottom of the frame
//! (positive offsets from rsp).
//!
//! Calling conventions:
//! - `.auto` (zap to zap): every argument is passed in memory, at 8-byte
//!   aligned offsets of the outgoing area, read by the callee at rbp+16.
//!   A result whose size is 1, 2, 4, or 8 bytes returns in rax; any other
//!   result is written through a pointer the caller passes in rdi.
//! - `.c`: SysV for integer, bool, and pointer parameters and results.
//! - `.naked`: no frame; only inline assembly and traps.
//!
//! Integers are kept normalized in memory: a value of a type narrower than
//! its ABI size is stored zero- or sign-extended, and arithmetic happens on
//! 64-bit extended values that are truncated back.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const InternPool = @import("../../InternPool.zig");
const Index = InternPool.Index;
const Ir = @import("../../Ir.zig");
const Inst = Ir.Inst;
const Ref = Inst.Ref;
const Type = @import("../../Type.zig");
const Emit = @import("../../Emit.zig");
const Atom = @import("../../link/Atom.zig");
const SymbolKey = Atom.SymbolKey;
const Encoder = @import("Encoder.zig");
const Reg = Encoder.Reg;
const Mem = Encoder.Mem;
const Size = Encoder.Size;

const CodeGen = @This();

emit: *Emit,
gpa: Allocator,
ip: *InternPool,
ir: *const Ir,
e: Encoder,
fn_ty: InternPool.FuncType,
homes: []Home,
/// Bytes of stack slots below rbp.
slots_size: u32 = 0,
/// Largest outgoing argument area of any call.
out_args_size: u32 = 0,
blocks: std.AutoHashMapUnmanaged(Inst.Index, Encoder.Label) = .empty,
/// rbp offset of the slot holding the result pointer (for results returned
/// in memory).
ret_ptr_slot: ?i32 = null,

pub const Error = Allocator.Error || error{CodegenFail};

/// Where an instruction's value lives.
const Home = union(enum) {
    none,
    /// The value is stored at `[rbp + off]`.
    slot: i32,
    /// The value is the address `rbp + off` (an `alloc`).
    frame_addr: i32,
};

/// Where an operand's value can be read.
const Loc = union(enum) {
    none,
    /// The value is stored in memory.
    mem: Mem,
    /// The value is the address of this memory.
    addr: Mem,
    /// A scalar constant, already extended to 64 bits.
    imm: u64,
    /// The code of an error, resolved at link time.
    err: InternPool.String,
};

pub fn generate(emit: *Emit, ir: *const Ir) Error!void {
    const ip = &emit.zcu.ip;
    const func = ip.indexToKey(ir.func).func;
    const gpa = emit.gpa;
    var cg: CodeGen = .{
        .emit = emit,
        .gpa = gpa,
        .ip = ip,
        .ir = ir,
        .e = .init(gpa),
        .fn_ty = ip.indexToKey(func.ty).func_type,
        .homes = try gpa.alloc(Home, ir.instructions.len),
    };
    defer {
        cg.e.deinit();
        gpa.free(cg.homes);
        cg.blocks.deinit(gpa);
    }
    @memset(cg.homes, .none);

    // The prologue belongs to the declaration's line.
    try cg.e.line(0, 0);
    const naked = cg.fn_ty.cc == .naked;
    var frame_patch: usize = 0;
    if (!naked) {
        try cg.e.push(.rbp);
        try cg.e.mov(.qword, .{ .reg = .rbp }, .{ .reg = .rsp });
        // Placeholder large enough for the imm32 form; patched below.
        try cg.e.alu(.sub, .qword, .{ .reg = .rsp }, .{ .imm = 0x10000 });
        frame_patch = cg.e.code.items.len;
        try cg.setupParams();
    }
    try cg.genBody(ir.mainBody());
    cg.e.finish();

    if (!naked) {
        const frame = std.mem.alignForward(u32, cg.slots_size + cg.out_args_size, 16);
        std.mem.writeInt(u32, cg.e.code.items[frame_patch - 4 ..][0..4], frame, .little);
    }

    const arena = emit.allocator();
    const nav = ip.getNav(func.owner_nav);
    var name = try emit.unitName(.{ .func = ir.func });
    for (emit.zcu.exports.items) |x| {
        if (x.nav == func.owner_nav and func.generic_owner == .none) name = ip.stringSlice(x.name);
    }
    const file = emit.zcu.file(nav.file);
    const debug: Atom.Debug = .{
        .file = file.display_path,
        .name = ip.stringSlice(nav.name),
        .base_line = file.zir.getDeclaration(nav.zir_inst).src_line,
        .lines = try arena.dupe(u8, cg.e.lines.bytes.items),
    };
    try emit.addFunction(.{
        .key = try emit.funcKey(ir.func),
        .name = name,
        .section = .text,
        .alignment = .@"16",
        .bytes = try arena.dupe(u8, cg.e.code.items),
        .targets = try arena.dupe(Atom.SymbolKey, cg.e.refs.targets.keys()),
        .relocs = try arena.dupe(Atom.Reloc, cg.e.refs.relocs.items),
    }, debug);
}

fn fail(cg: *CodeGen, comptime fmt: []const u8, args: anytype) Error {
    const ip = cg.ip;
    const nav = ip.getNav(ip.indexToKey(cg.ir.func).func.owner_nav);
    const tree = try cg.emit.zcu.fe.tree(@fromBackingInt(nav.file));
    const decl = cg.emit.zcu.file(nav.file).zir.getDeclaration(nav.zir_inst);
    try cg.emit.zcu.addError(nav.file, tree.nodeToSpan(decl.src_node), "zap codegen: " ++ fmt, args);
    return error.CodegenFail;
}

// ---------------------------------------------------------------------------
// Frame and homes

fn allocSlot(cg: *CodeGen, size: u64, alignment: u64) Error!i32 {
    if (alignment > 16) return cg.fail("stack values aligned to more than 16 bytes", .{});
    cg.slots_size = std.mem.alignForward(u32, cg.slots_size + @as(u32, @intCast(size)), @intCast(@max(alignment, 1)));
    return -@as(i32, @intCast(cg.slots_size));
}

fn slotFor(cg: *CodeGen, inst: Inst.Index, ty: Index) Error!Home {
    if (!Type.hasRuntimeBits(cg.ip, ty)) {
        cg.homes[@backingInt(inst)] = .none;
        return .none;
    }
    const home: Home = .{ .slot = try cg.allocSlot(Type.abiSize(cg.ip, ty), Type.abiAlignment(cg.ip, ty)) };
    cg.homes[@backingInt(inst)] = home;
    return home;
}

/// The memory of a result slot.
fn resultMem(cg: *CodeGen, inst: Inst.Index, ty: Index) Error!?Mem {
    return switch (try cg.slotFor(inst, ty)) {
        .slot => |off| Mem.at(.rbp, off),
        else => null,
    };
}

fn passInRegs(cg: *CodeGen, ty: Index) bool {
    const size = Type.abiSize(cg.ip, ty);
    return size == 1 or size == 2 or size == 4 or size == 8;
}

const c_arg_regs = [_]Reg{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };

fn setupParams(cg: *CodeGen) Error!void {
    const ip = cg.ip;
    const ret_ty = cg.fn_ty.return_type;
    if (Type.hasRuntimeBits(ip, ret_ty) and !cg.passInRegs(ret_ty)) {
        if (cg.fn_ty.cc == .c) return cg.fail("C calling convention results of type '{f}'", .{cg.fmtType(ret_ty)});
        const off = try cg.allocSlot(8, 8);
        try cg.e.mov(.qword, .{ .mem = Mem.at(.rbp, off) }, .{ .reg = .rdi });
        cg.ret_ptr_slot = off;
    }
    // `arg` instructions are at the start of the main body.
    var stack_off: i32 = 16;
    var reg_i: usize = 0;
    for (cg.ir.mainBody()) |inst| {
        if (cg.ir.instructions.items(.tag)[@backingInt(inst)] != .arg) break;
        const ty = cg.ir.instructions.items(.data)[@backingInt(inst)].arg.ty;
        if (!Type.hasRuntimeBits(ip, ty)) continue;
        const size = Type.abiSize(ip, ty);
        if (cg.fn_ty.cc == .c) {
            if (!cg.passInRegs(ty) or reg_i == c_arg_regs.len) return cg.fail("C calling convention parameters of type '{f}'", .{cg.fmtType(ty)});
            const off = try cg.allocSlot(size, Type.abiAlignment(ip, ty));
            try cg.e.mov(sizeOf(size), .{ .mem = Mem.at(.rbp, off) }, .{ .reg = c_arg_regs[reg_i] });
            reg_i += 1;
            cg.homes[@backingInt(inst)] = .{ .slot = off };
        } else {
            cg.homes[@backingInt(inst)] = .{ .slot = stack_off };
            stack_off += @intCast(std.mem.alignForward(u64, size, 8));
        }
    }
}

fn sizeOf(bytes: u64) Size {
    return switch (bytes) {
        1 => .byte,
        2 => .word,
        4 => .dword,
        8 => .qword,
        else => unreachable,
    };
}

// ---------------------------------------------------------------------------
// Operands

fn typeOf(cg: *CodeGen, ref: Ref) Index {
    return cg.ir.typeOf(ref, cg.ip);
}

fn locOf(cg: *CodeGen, ref: Ref) Error!Loc {
    if (ref.toIndex()) |inst| return switch (cg.homes[@backingInt(inst)]) {
        .none => .none,
        .slot => |off| .{ .mem = Mem.at(.rbp, off) },
        .frame_addr => |off| .{ .addr = Mem.at(.rbp, off) },
    };
    return cg.constLoc(ref.toInterned().?);
}

fn constLoc(cg: *CodeGen, val: Index) Error!Loc {
    const ip = cg.ip;
    const ty = ip.typeOf(val);
    if (!Type.hasRuntimeBits(ip, ty)) return .none;
    switch (ip.indexToKey(val)) {
        .undef => if (cg.passInRegs(ty)) return .{ .imm = 0xaaaa_aaaa_aaaa_aaaa },
        .int => if (cg.passInRegs(ty)) return .{ .imm = intBits(ip, val) },
        .simple_value => |s| switch (s) {
            .true => return .{ .imm = 1 },
            .false => return .{ .imm = 0 },
            else => {},
        },
        .err => |e| return .{ .err = e.name },
        .enum_tag => |e| if (cg.passInRegs(ty)) return .{ .imm = intBits(ip, e.int) },
        .ptr => |p| if (!Type.isSlice(ip, ty)) {
            if (p.base == .int) return .{ .imm = p.byte_offset };
            const t = try ptrTarget(cg.emit, val);
            return .{ .addr = Mem.sym(t.key, @intCast(t.off)) };
        },
        .opt => |o| if (Type.optionalReprIsPtr(ip, Type.childType(ip, ty))) {
            if (o.val == .none) return .{ .imm = 0 };
            return cg.constLoc(o.val);
        },
        else => {},
    }
    return .{ .mem = Mem.sym(try cg.emit.uavKey(val), 0) };
}

/// The 64-bit extended bits of an integer value.
fn intBits(ip: *const InternPool, val: Index) u64 {
    if (ip.intValue(u64, val)) |v| return v;
    if (ip.intValue(i64, val)) |v| return @bitCast(v);
    unreachable; // wider than 64 bits; rejected before codegen
}

fn signed(cg: *CodeGen, ty: Index) bool {
    return switch (Type.class(cg.ip, ty)) {
        .int, .@"enum" => Type.intInfo(cg.ip, ty).signedness == .signed,
        else => false,
    };
}

/// Loads a value of at most 8 bytes into `reg`, zero- or sign-extended to 64
/// bits by its type.
fn load(cg: *CodeGen, reg: Reg, ref: Ref) Error!void {
    const ty = cg.typeOf(ref);
    switch (try cg.locOf(ref)) {
        .none => try cg.e.mov(.dword, .{ .reg = reg }, .{ .imm = 0 }),
        .imm => |v| try cg.e.mov(.qword, .{ .reg = reg }, .{ .imm = @bitCast(v) }),
        .addr => |m| try cg.e.lea(.qword, reg, m),
        .err => |name| try cg.loadError(reg, name),
        .mem => |m| try cg.loadMem(reg, m, ty),
    }
}

fn loadMem(cg: *CodeGen, reg: Reg, m: Mem, ty: Index) Error!void {
    const size = Type.abiSize(cg.ip, ty);
    switch (size) {
        8 => try cg.e.mov(.qword, .{ .reg = reg }, .{ .mem = m }),
        1, 2, 4 => if (cg.signed(ty))
            try cg.e.movsx(.qword, reg, sizeOf(size), .{ .mem = m })
        else
            try cg.e.movzx(.qword, reg, sizeOf(size), .{ .mem = m }),
        else => return cg.fail("loading a {d}-byte value into a register", .{size}),
    }
}

fn loadError(cg: *CodeGen, reg: Reg, name: InternPool.String) Error!void {
    const key = try cg.emit.useError(name);
    try cg.e.movImmValue(reg, key);
}

/// Stores the low `size` bytes of `reg` to `m`.
fn storeReg(cg: *CodeGen, m: Mem, reg: Reg, size: u64) Error!void {
    switch (size) {
        0 => {},
        1, 2, 4, 8 => try cg.e.mov(sizeOf(size), .{ .mem = m }, .{ .reg = reg }),
        else => unreachable,
    }
}

fn offsetMem(m: Mem, off: u64) Mem {
    var r = m;
    r.disp += @intCast(off);
    return r;
}

/// Copies the value `ref` (of `size` bytes) to `dst`. Uses rax, and for
/// large values rsi, rdi, and rcx; `dst` must not be based on those.
fn copyTo(cg: *CodeGen, dst: Mem, ref: Ref) Error!void {
    const ty = cg.typeOf(ref);
    const size = Type.abiSize(cg.ip, ty);
    if (size == 0) return;
    const loc = try cg.locOf(ref);
    switch (loc) {
        .none => {},
        .mem => |src| try cg.copyMem(dst, src, size),
        .imm => |v| if (cg.passInRegs(ty)) {
            try cg.e.mov(.qword, .{ .reg = .rax }, .{ .imm = @bitCast(v) });
            try cg.storeReg(dst, .rax, size);
        } else {
            // An undefined aggregate.
            try cg.fillMem(dst, size, 0xaa);
        },
        .addr, .err => {
            try cg.load(.rax, ref);
            try cg.storeReg(dst, .rax, size);
        },
    }
}

fn copyMem(cg: *CodeGen, dst: Mem, src: Mem, size: u64) Error!void {
    if (size > 128) {
        try cg.e.lea(.qword, .rsi, src);
        try cg.e.lea(.qword, .rdi, dst);
        try cg.e.mov(.qword, .{ .reg = .rcx }, .{ .imm = @intCast(size / 8) });
        const top = try cg.e.newLabel();
        cg.e.bind(top);
        try cg.e.mov(.qword, .{ .reg = .rax }, .{ .mem = Mem.at(.rsi, 0) });
        try cg.e.mov(.qword, .{ .mem = Mem.at(.rdi, 0) }, .{ .reg = .rax });
        try cg.e.alu(.add, .qword, .{ .reg = .rsi }, .{ .imm = 8 });
        try cg.e.alu(.add, .qword, .{ .reg = .rdi }, .{ .imm = 8 });
        try cg.e.alu(.sub, .qword, .{ .reg = .rcx }, .{ .imm = 1 });
        try cg.e.jcc(.ne, .{ .label = top });
        return cg.copyTail(Mem.at(.rdi, 0), Mem.at(.rsi, 0), size % 8);
    }
    try cg.copyTail(dst, src, size);
}

fn copyTail(cg: *CodeGen, dst: Mem, src: Mem, size: u64) Error!void {
    var off: u64 = 0;
    while (off < size) {
        const left = size - off;
        const chunk: u64 = if (left >= 8) 8 else if (left >= 4) 4 else if (left >= 2) 2 else 1;
        try cg.e.mov(sizeOf(chunk), .{ .reg = .rax }, .{ .mem = offsetMem(src, off) });
        try cg.e.mov(sizeOf(chunk), .{ .mem = offsetMem(dst, off) }, .{ .reg = .rax });
        off += chunk;
    }
}

fn fillMem(cg: *CodeGen, dst: Mem, size: u64, byte: u8) Error!void {
    var pattern: u64 = byte;
    pattern *%= 0x0101_0101_0101_0101;
    try cg.e.mov(.qword, .{ .reg = .rax }, .{ .imm = @bitCast(pattern) });
    var off: u64 = 0;
    while (off < size) {
        const left = size - off;
        const chunk: u64 = if (left >= 8) 8 else if (left >= 4) 4 else if (left >= 2) 2 else 1;
        try cg.e.mov(sizeOf(chunk), .{ .mem = offsetMem(dst, off) }, .{ .reg = .rax });
        off += chunk;
    }
}

/// The memory holding value `ref`, materializing a register-only constant
/// into a scratch slot if needed.
fn memOf(cg: *CodeGen, ref: Ref) Error!Mem {
    switch (try cg.locOf(ref)) {
        .mem => |m| return m,
        else => {
            const ty = cg.typeOf(ref);
            const off = try cg.allocSlot(Type.abiSize(cg.ip, ty), Type.abiAlignment(cg.ip, ty));
            try cg.copyTo(Mem.at(.rbp, off), ref);
            return Mem.at(.rbp, off);
        },
    }
}

/// Truncates the 64-bit value in `reg` to integer type `ty` and extends it
/// back, so it is normalized.
fn normalize(cg: *CodeGen, reg: Reg, ty: Index) Error!void {
    if (!Type.isInt(cg.ip, ty)) return; // bools stay 0 or 1
    const info = Type.intInfo(cg.ip, ty);
    if (info.bits >= 64) return;
    const shift: u8 = @intCast(64 - info.bits);
    try cg.e.shift(.shl, .qword, .{ .reg = reg }, shift);
    try cg.e.shift(if (info.signedness == .signed) .sar else .shr, .qword, .{ .reg = reg }, shift);
}

// ---------------------------------------------------------------------------
// Instructions

fn genBody(cg: *CodeGen, body: []const Inst.Index) Error!void {
    for (body) |inst| try cg.genInst(inst);
}

fn genInst(cg: *CodeGen, inst: Inst.Index) Error!void {
    const ip = cg.ip;
    const ir = cg.ir;
    const tag = ir.instructions.items(.tag)[@backingInt(inst)];
    const data = ir.instructions.items(.data)[@backingInt(inst)];
    if (cg.fn_ty.cc == .naked) switch (tag) {
        .assembly, .trap, .unreach, .dbg_stmt => {},
        else => return cg.fail("'{t}' in a naked function", .{tag}),
    };
    switch (tag) {
        .arg => {},
        .dbg_stmt => try cg.e.line(data.dbg_stmt.line, data.dbg_stmt.column),
        .alloc => {
            // An inferred alloc whose initializer never completes.
            if (data.ty == .none) return;
            const child = Type.ptrInfo(ip, data.ty).child;
            const off = try cg.allocSlot(@max(Type.abiSize(ip, child), 1), Type.abiAlignment(ip, child));
            cg.homes[@backingInt(inst)] = .{ .frame_addr = off };
        },
        .load => {
            const dst = try cg.resultMem(inst, data.ty_op.ty) orelse return;
            try cg.load(.r10, data.ty_op.operand);
            try cg.copyMem(dst, Mem.at(.r10, 0), Type.abiSize(ip, data.ty_op.ty));
        },
        .store => {
            const val = data.bin_op.rhs;
            const size = Type.abiSize(ip, cg.typeOf(val));
            if (size == 0) return;
            try cg.load(.r10, data.bin_op.lhs);
            if (val.toInterned()) |v| if (ip.indexToKey(v) == .undef) return cg.fillMem(Mem.at(.r10, 0), size, 0xaa);
            try cg.copyTo(Mem.at(.r10, 0), val);
        },

        .add_wrap, .sub_wrap, .mul_wrap, .bit_and, .bit_or, .xor, .shl, .shr, .div_trunc, .div_floor, .div_ceil, .rem, .mod => {
            const ty = cg.typeOf(data.bin_op.lhs);
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.binOp(tag, ty, data.bin_op.lhs, data.bin_op.rhs);
            try cg.storeReg(dst, .rax, Type.abiSize(ip, ty));
        },
        .add_with_overflow, .sub_with_overflow, .mul_with_overflow => try cg.overflowOp(inst, tag, data),
        .not => {
            const ty = data.ty_op.ty;
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.load(.rax, data.ty_op.operand);
            if (ty == .bool_type) {
                try cg.e.alu(.xor, .dword, .{ .reg = .rax }, .{ .imm = 1 });
            } else {
                try cg.e.unary(.not, .qword, .{ .reg = .rax });
                try cg.normalize(.rax, ty);
            }
            try cg.storeReg(dst, .rax, Type.abiSize(ip, ty));
        },
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => {
            const dst = try cg.resultMem(inst, .bool_type) orelse return;
            const ty = cg.typeOf(data.bin_op.lhs);
            try cg.load(.rax, data.bin_op.lhs);
            try cg.load(.rcx, data.bin_op.rhs);
            try cg.e.alu(.cmp, .qword, .{ .reg = .rax }, .{ .reg = .rcx });
            const s = cg.signed(ty);
            const cond: Encoder.Cond = switch (tag) {
                .cmp_lt => if (s) .l else .b,
                .cmp_lte => if (s) .le else .be,
                .cmp_eq => .e,
                .cmp_gte => if (s) .ge else .ae,
                .cmp_gt => if (s) .g else .a,
                .cmp_neq => .ne,
                else => unreachable,
            };
            try cg.e.setcc(cond, .{ .mem = dst });
        },
        .intcast, .trunc, .bitcast, .ptr_from_int => {
            const ty = data.ty_op.ty;
            const dst = try cg.resultMem(inst, ty) orelse return;
            const size = Type.abiSize(ip, ty);
            if (cg.passInRegs(ty) and cg.passInRegs(cg.typeOf(data.ty_op.operand))) {
                try cg.load(.rax, data.ty_op.operand);
                if (Type.isInt(ip, ty)) try cg.normalize(.rax, ty);
                try cg.storeReg(dst, .rax, size);
            } else {
                try cg.copyTo(dst, data.ty_op.operand);
            }
        },
        .int_from_bool, .int_from_ptr => {
            const ty = ir.typeOfIndex(inst, ip);
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.load(.rax, data.un_op);
            try cg.storeReg(dst, .rax, Type.abiSize(ip, ty));
        },

        .block => {
            const extra = ir.extraData(Ir.Block, data.ty_pl.payload);
            _ = try cg.slotFor(inst, data.ty_pl.ty);
            const label = try cg.e.newLabel();
            try cg.blocks.put(cg.gpa, inst, label);
            try cg.genBody(ir.bodySlice(extra.end, extra.data.body_len));
            cg.e.bind(label);
        },
        .loop => {
            const extra = ir.extraData(Ir.Block, data.ty_pl.payload);
            const label = try cg.e.newLabel();
            cg.e.bind(label);
            try cg.blocks.put(cg.gpa, inst, label);
            try cg.genBody(ir.bodySlice(extra.end, extra.data.body_len));
        },
        .repeat => try cg.e.jmp(.{ .label = cg.blocks.get(data.repeat.loop_inst).? }),
        .br => {
            const target = data.br.block_inst;
            switch (cg.homes[@backingInt(target)]) {
                .slot => |off| try cg.copyTo(Mem.at(.rbp, off), data.br.operand),
                else => {},
            }
            try cg.e.jmp(.{ .label = cg.blocks.get(target).? });
        },
        .cond_br => {
            const extra = ir.extraData(Ir.CondBr, data.pl_op.payload);
            const then_body = ir.bodySlice(extra.end, extra.data.then_body_len);
            const else_body = ir.bodySlice(extra.end + then_body.len, extra.data.else_body_len);
            try cg.load(.rax, data.pl_op.operand);
            try cg.e.@"test"(.byte, .{ .reg = .rax }, .{ .reg = .rax });
            const else_label = try cg.e.newLabel();
            try cg.e.jcc(.e, .{ .label = else_label });
            try cg.genBody(then_body);
            cg.e.bind(else_label);
            try cg.genBody(else_body);
        },
        .switch_br => try cg.switchBr(data),
        .ret => try cg.ret(data.un_op),
        .unreach, .trap => try cg.e.ud2(),
        .panic => try cg.panic(data.panic.id, data.panic.payload),
        .call => try cg.call(inst, data),

        .struct_field_ptr => {
            const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
            const dst = try cg.resultMem(inst, data.ty_pl.ty) orelse return;
            const container = Type.ptrInfo(ip, cg.typeOf(sf.operand)).child;
            try cg.load(.rax, sf.operand);
            const off = Type.fieldOffset(ip, container, sf.index);
            if (off != 0) try cg.e.alu(.add, .qword, .{ .reg = .rax }, .{ .imm = @intCast(off) });
            try cg.storeReg(dst, .rax, 8);
        },
        .struct_field_val => {
            const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
            const dst = try cg.resultMem(inst, data.ty_pl.ty) orelse return;
            const src = try cg.memOf(sf.operand);
            const off = Type.fieldOffset(ip, cg.typeOf(sf.operand), sf.index);
            try cg.copyMem(dst, offsetMem(src, off), Type.abiSize(ip, data.ty_pl.ty));
        },
        .ptr_elem_ptr, .slice_elem_ptr, .ptr_add => {
            const bin = ir.extraData(Ir.Bin, data.ty_pl.payload).data;
            const dst = try cg.resultMem(inst, data.ty_pl.ty) orelse return;
            const elem_ty = if (tag == .ptr_add) Type.ptrInfo(ip, data.ty_pl.ty).child else Type.ptrInfo(ip, data.ty_pl.ty).child;
            try cg.elemAddr(.rax, tag == .slice_elem_ptr, bin.lhs, bin.rhs, Type.abiSize(ip, elem_ty));
            try cg.storeReg(dst, .rax, 8);
        },
        .ptr_elem_val, .slice_elem_val => {
            const ty = ir.typeOfIndex(inst, ip);
            const dst = try cg.resultMem(inst, ty) orelse return;
            const size = Type.abiSize(ip, ty);
            try cg.elemAddr(.r10, tag == .slice_elem_val, data.bin_op.lhs, data.bin_op.rhs, size);
            try cg.copyMem(dst, Mem.at(.r10, 0), size);
        },
        .array_elem_val => {
            const ty = ir.typeOfIndex(inst, ip);
            const dst = try cg.resultMem(inst, ty) orelse return;
            const size = Type.abiSize(ip, ty);
            const src = try cg.memOf(data.bin_op.lhs);
            try cg.e.lea(.qword, .r10, src);
            try cg.load(.rcx, data.bin_op.rhs);
            try cg.scaleAdd(.r10, .rcx, size);
            try cg.copyMem(dst, Mem.at(.r10, 0), size);
        },
        .slice_ptr, .slice_len => {
            const dst = try cg.resultMem(inst, data.ty_op.ty) orelse return;
            const src = try cg.memOf(data.ty_op.operand);
            try cg.copyMem(dst, offsetMem(src, if (tag == .slice_len) 8 else 0), 8);
        },
        .slice => {
            const bin = ir.extraData(Ir.Bin, data.ty_pl.payload).data;
            const dst = try cg.resultMem(inst, data.ty_pl.ty) orelse return;
            try cg.load(.rax, bin.lhs);
            try cg.storeReg(dst, .rax, 8);
            try cg.load(.rax, bin.rhs);
            try cg.storeReg(offsetMem(dst, 8), .rax, 8);
        },

        .is_null, .is_non_null => {
            const dst = try cg.resultMem(inst, .bool_type) orelse return;
            const opt_ty = cg.typeOf(data.un_op);
            const child = Type.childType(ip, opt_ty);
            if (Type.optionalReprIsPtr(ip, child)) {
                try cg.load(.rax, data.un_op);
                try cg.e.@"test"(.qword, .{ .reg = .rax }, .{ .reg = .rax });
            } else {
                const src = try cg.memOf(data.un_op);
                try cg.e.alu(.cmp, .byte, .{ .mem = offsetMem(src, Type.optionalFlagOffset(ip, opt_ty)) }, .{ .imm = 0 });
            }
            try cg.e.setcc(if (tag == .is_null) .e else .ne, .{ .mem = dst });
        },
        .optional_payload => {
            const dst = try cg.resultMem(inst, data.ty_op.ty) orelse return;
            const child = data.ty_op.ty;
            if (Type.optionalReprIsPtr(ip, child)) {
                try cg.copyTo(dst, data.ty_op.operand);
            } else {
                try cg.copyMem(dst, try cg.memOf(data.ty_op.operand), Type.abiSize(ip, child));
            }
        },
        .optional_payload_ptr, .optional_payload_ptr_set => {
            const dst = try cg.resultMem(inst, data.ty_op.ty) orelse return;
            try cg.load(.rax, data.ty_op.operand);
            if (tag == .optional_payload_ptr_set) {
                const opt_ty = Type.ptrInfo(ip, cg.typeOf(data.ty_op.operand)).child;
                if (!Type.optionalReprIsPtr(ip, Type.childType(ip, opt_ty))) {
                    try cg.e.mov(.byte, .{ .mem = Mem.at(.rax, @intCast(Type.optionalFlagOffset(ip, opt_ty))) }, .{ .imm = 1 });
                }
            }
            try cg.storeReg(dst, .rax, 8);
        },
        .wrap_optional => {
            const opt_ty = data.ty_op.ty;
            const dst = try cg.resultMem(inst, opt_ty) orelse return;
            try cg.copyTo(dst, data.ty_op.operand);
            if (!Type.optionalReprIsPtr(ip, Type.childType(ip, opt_ty))) {
                try cg.e.mov(.byte, .{ .mem = offsetMem(dst, Type.optionalFlagOffset(ip, opt_ty)) }, .{ .imm = 1 });
            }
        },
        .is_err, .is_non_err => {
            const dst = try cg.resultMem(inst, .bool_type) orelse return;
            const src = try cg.memOf(data.un_op);
            try cg.e.alu(.cmp, .word, .{ .mem = src }, .{ .imm = 0 });
            try cg.e.setcc(if (tag == .is_err) .ne else .e, .{ .mem = dst });
        },
        .unwrap_errunion_payload, .unwrap_errunion_err => {
            const dst = try cg.resultMem(inst, data.ty_op.ty) orelse return;
            const eu_ty = cg.typeOf(data.ty_op.operand);
            const layout = Type.errorUnionLayout(ip, eu_ty);
            const src = try cg.memOf(data.ty_op.operand);
            const off = if (tag == .unwrap_errunion_err) layout.err_offset else layout.payload_offset;
            try cg.copyMem(dst, offsetMem(src, off), Type.abiSize(ip, data.ty_op.ty));
        },
        .unwrap_errunion_payload_ptr, .unwrap_errunion_err_ptr, .errunion_payload_ptr_set => {
            const dst = try cg.resultMem(inst, data.ty_op.ty) orelse return;
            const eu_ty = Type.ptrInfo(ip, cg.typeOf(data.ty_op.operand)).child;
            const layout = Type.errorUnionLayout(ip, eu_ty);
            try cg.load(.rax, data.ty_op.operand);
            if (tag == .errunion_payload_ptr_set) try cg.e.mov(.word, .{ .mem = Mem.at(.rax, @intCast(layout.err_offset)) }, .{ .imm = 0 });
            const off = if (tag == .unwrap_errunion_err_ptr) layout.err_offset else layout.payload_offset;
            if (off != 0) try cg.e.alu(.add, .qword, .{ .reg = .rax }, .{ .imm = @intCast(off) });
            try cg.storeReg(dst, .rax, 8);
        },
        .wrap_errunion_payload, .wrap_errunion_err => {
            const eu_ty = data.ty_op.ty;
            const dst = try cg.resultMem(inst, eu_ty) orelse return;
            const layout = Type.errorUnionLayout(ip, eu_ty);
            if (tag == .wrap_errunion_payload) {
                try cg.e.mov(.word, .{ .mem = offsetMem(dst, layout.err_offset) }, .{ .imm = 0 });
                try cg.copyTo(offsetMem(dst, layout.payload_offset), data.ty_op.operand);
            } else {
                try cg.copyTo(offsetMem(dst, layout.err_offset), data.ty_op.operand);
            }
        },
        .aggregate_init => {
            const ty = data.ty_pl.ty;
            const dst = try cg.resultMem(inst, ty) orelse return;
            const extra = ir.extraData(Ir.Aggregate, data.ty_pl.payload);
            const elems = ir.refSlice(extra.end, extra.data.len);
            for (elems, 0..) |elem, i| {
                const off = switch (ip.indexToKey(ty)) {
                    .array_type => |a| i * Type.abiSize(ip, a.child),
                    else => Type.fieldOffset(ip, ty, i),
                };
                try cg.copyTo(offsetMem(dst, off), elem);
            }
        },
        .union_init => {
            const ty = data.ty_pl.ty;
            const dst = try cg.resultMem(inst, ty) orelse return;
            const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
            const layout = Type.unionLayout(ip, ty);
            try cg.copyTo(offsetMem(dst, layout.payload_offset), sf.operand);
            if (layout.tag_size != 0) {
                try cg.e.mov(.qword, .{ .reg = .rax }, .{ .imm = @bitCast(Type.unionFieldTag(ip, ty, sf.index)) });
                try cg.storeReg(offsetMem(dst, layout.tag_offset), .rax, layout.tag_size);
            }
        },
        .get_union_tag => {
            const dst = try cg.resultMem(inst, data.ty_op.ty) orelse return;
            const layout = Type.unionLayout(ip, cg.typeOf(data.ty_op.operand));
            const src = try cg.memOf(data.ty_op.operand);
            try cg.copyMem(dst, offsetMem(src, layout.tag_offset), layout.tag_size);
        },
        .set_union_tag => {
            const layout = Type.unionLayout(ip, Type.ptrInfo(ip, cg.typeOf(data.bin_op.lhs)).child);
            if (layout.tag_size == 0) return;
            try cg.load(.r10, data.bin_op.lhs);
            try cg.load(.rax, data.bin_op.rhs);
            try cg.storeReg(Mem.at(.r10, @intCast(layout.tag_offset)), .rax, layout.tag_size);
        },
        .clz, .ctz, .popcount, .byte_swap, .bit_reverse => {
            const ty = data.ty_op.ty;
            const dst = try cg.resultMem(inst, ty) orelse return;
            const bits = Type.intInfo(ip, cg.typeOf(data.ty_op.operand)).bits;
            try cg.bitOp(tag, bits, data.ty_op.operand);
            if (tag == .byte_swap or tag == .bit_reverse) try cg.normalize(.rax, ty);
            try cg.storeReg(dst, .rax, Type.abiSize(ip, ty));
        },
        .tag_name => {
            // A compare chain over the tags; each name is a content atom.
            const dst = try cg.resultMem(inst, data.ty_op.ty) orelse return;
            const enum_ty = cg.typeOf(data.ty_op.operand);
            const info = ip.structInfo(enum_ty);
            try cg.load(.rax, data.ty_op.operand);
            const done = try cg.e.newLabel();
            for (info.field_names, info.field_defaults) |name, v| {
                const next = try cg.e.newLabel();
                try cg.e.mov(.qword, .{ .reg = .rcx }, .{ .imm = @bitCast(intBits(ip, v)) });
                try cg.e.alu(.cmp, .qword, .{ .reg = .rax }, .{ .reg = .rcx });
                try cg.e.jcc(.ne, .{ .label = next });
                const bytes = ip.stringSlice(name);
                const z = try cg.emit.allocator().alloc(u8, bytes.len + 1);
                @memcpy(z[0..bytes.len], bytes);
                z[bytes.len] = 0;
                try cg.e.lea(.qword, .rcx, Mem.sym(try cg.emit.contentAtom(1, z, &.{}, &.{}), 0));
                try cg.e.mov(.qword, .{ .mem = dst }, .{ .reg = .rcx });
                try cg.e.mov(.qword, .{ .mem = offsetMem(dst, 8) }, .{ .imm = @intCast(bytes.len) });
                try cg.e.jmp(.{ .label = done });
                cg.e.bind(next);
            }
            try cg.e.ud2();
            cg.e.bind(done);
        },
        .assembly => try cg.assembly(inst, data),
    }
}

/// The bit operations into rax, with loops over the bits (the baseline
/// x86_64 CPU has no lzcnt, tzcnt, or popcnt). Uses rcx, rdx, r11.
fn bitOp(cg: *CodeGen, tag: Inst.Tag, bits: u16, operand: Ref) Error!void {
    const e = &cg.e;
    try cg.load(.rdx, operand);
    if (bits < 64) {
        // Only the operand's own bits.
        try e.mov(.qword, .{ .reg = .r11 }, .{ .imm = @bitCast((@as(u64, 1) << @intCast(bits)) - 1) });
        try e.alu(.@"and", .qword, .{ .reg = .rdx }, .{ .reg = .r11 });
    }
    try e.alu(.xor, .dword, .{ .reg = .rax }, .{ .reg = .rax });
    const top = try e.newLabel();
    const done = try e.newLabel();
    switch (tag) {
        .popcount => {
            // while (x != 0) { x &= x - 1; n += 1; }
            e.bind(top);
            try e.@"test"(.qword, .{ .reg = .rdx }, .{ .reg = .rdx });
            try e.jcc(.e, .{ .label = done });
            try e.mov(.qword, .{ .reg = .rcx }, .{ .reg = .rdx });
            try e.alu(.sub, .qword, .{ .reg = .rcx }, .{ .imm = 1 });
            try e.alu(.@"and", .qword, .{ .reg = .rdx }, .{ .reg = .rcx });
            try e.alu(.add, .qword, .{ .reg = .rax }, .{ .imm = 1 });
            try e.jmp(.{ .label = top });
        },
        .ctz => {
            // while (n < bits and x & 1 == 0) { x >>= 1; n += 1; }
            e.bind(top);
            try e.alu(.cmp, .qword, .{ .reg = .rax }, .{ .imm = bits });
            try e.jcc(.e, .{ .label = done });
            try e.@"test"(.qword, .{ .reg = .rdx }, .{ .imm = 1 });
            try e.jcc(.ne, .{ .label = done });
            try e.shift(.shr, .qword, .{ .reg = .rdx }, 1);
            try e.alu(.add, .qword, .{ .reg = .rax }, .{ .imm = 1 });
            try e.jmp(.{ .label = top });
        },
        .clz => {
            // Align the operand's top bit with bit 63, then count.
            if (bits != 64 and bits != 0) try e.shift(.shl, .qword, .{ .reg = .rdx }, @intCast(64 - bits));
            e.bind(top);
            try e.alu(.cmp, .qword, .{ .reg = .rax }, .{ .imm = bits });
            try e.jcc(.e, .{ .label = done });
            try e.@"test"(.qword, .{ .reg = .rdx }, .{ .reg = .rdx });
            try e.jcc(.s, .{ .label = done });
            try e.shift(.shl, .qword, .{ .reg = .rdx }, 1);
            try e.alu(.add, .qword, .{ .reg = .rax }, .{ .imm = 1 });
            try e.jmp(.{ .label = top });
        },
        .byte_swap, .bit_reverse => {
            // Move the low unit of x to the bottom of n, `bits / unit` times.
            const unit: u8 = if (tag == .byte_swap) 8 else 1;
            try e.mov(.dword, .{ .reg = .rcx }, .{ .imm = bits / unit });
            e.bind(top);
            try e.@"test"(.dword, .{ .reg = .rcx }, .{ .reg = .rcx });
            try e.jcc(.e, .{ .label = done });
            try e.shift(.shl, .qword, .{ .reg = .rax }, unit);
            try e.mov(.qword, .{ .reg = .r11 }, .{ .reg = .rdx });
            try e.alu(.@"and", .qword, .{ .reg = .r11 }, .{ .imm = if (unit == 8) 0xff else 1 });
            try e.alu(.@"or", .qword, .{ .reg = .rax }, .{ .reg = .r11 });
            try e.shift(.shr, .qword, .{ .reg = .rdx }, unit);
            try e.alu(.sub, .dword, .{ .reg = .rcx }, .{ .imm = 1 });
            try e.jmp(.{ .label = top });
        },
        else => unreachable,
    }
    e.bind(done);
}

/// `reg = base + index * size`, where `base` is a pointer or, if `is_slice`,
/// the pointer of a slice. Uses rcx.
fn elemAddr(cg: *CodeGen, reg: Reg, is_slice: bool, base: Ref, index: Ref, size: u64) Error!void {
    if (is_slice) {
        const m = try cg.memOf(base);
        try cg.e.mov(.qword, .{ .reg = reg }, .{ .mem = m });
    } else {
        try cg.load(reg, base);
    }
    try cg.load(.rcx, index);
    try cg.scaleAdd(reg, .rcx, size);
}

fn scaleAdd(cg: *CodeGen, reg: Reg, index: Reg, size: u64) Error!void {
    if (size == 0) return;
    if (size != 1) try cg.e.imul(.qword, index, .{ .reg = index }, @intCast(size));
    try cg.e.alu(.add, .qword, .{ .reg = reg }, .{ .reg = index });
}

/// Computes `lhs op rhs` on 64-bit extended operands into rax, normalized
/// to `ty`. Uses rcx and rdx.
fn binOp(cg: *CodeGen, tag: Inst.Tag, ty: Index, lhs: Ref, rhs: Ref) Error!void {
    const s = cg.signed(ty);
    try cg.load(.rax, lhs);
    try cg.load(.rcx, rhs);
    switch (tag) {
        .add_wrap => try cg.e.alu(.add, .qword, .{ .reg = .rax }, .{ .reg = .rcx }),
        .sub_wrap => try cg.e.alu(.sub, .qword, .{ .reg = .rax }, .{ .reg = .rcx }),
        .mul_wrap => try cg.e.imul(.qword, .rax, .{ .reg = .rcx }, null),
        .bit_and => try cg.e.alu(.@"and", .qword, .{ .reg = .rax }, .{ .reg = .rcx }),
        .bit_or => try cg.e.alu(.@"or", .qword, .{ .reg = .rax }, .{ .reg = .rcx }),
        .xor => try cg.e.alu(.xor, .qword, .{ .reg = .rax }, .{ .reg = .rcx }),
        .shl => try cg.e.shift(.shl, .qword, .{ .reg = .rax }, null),
        .shr => try cg.e.shift(if (s) .sar else .shr, .qword, .{ .reg = .rax }, null),
        .div_trunc, .div_floor, .div_ceil, .rem, .mod => {
            if (s) {
                try cg.e.cqo(.qword);
                try cg.e.unary(.idiv, .qword, .{ .reg = .rcx });
            } else {
                try cg.e.alu(.xor, .dword, .{ .reg = .rdx }, .{ .reg = .rdx });
                try cg.e.unary(.div, .qword, .{ .reg = .rcx });
            }
            // rax = quotient, rdx = remainder.
            if (s and (tag == .div_floor or tag == .mod)) {
                // Adjust when the remainder is non-zero and its sign differs
                // from the divisor's.
                const done = try cg.e.newLabel();
                try cg.e.@"test"(.qword, .{ .reg = .rdx }, .{ .reg = .rdx });
                try cg.e.jcc(.e, .{ .label = done });
                try cg.e.mov(.qword, .{ .reg = .r11 }, .{ .reg = .rdx });
                try cg.e.alu(.xor, .qword, .{ .reg = .r11 }, .{ .reg = .rcx });
                try cg.e.jcc(.ns, .{ .label = done });
                if (tag == .div_floor) {
                    try cg.e.alu(.sub, .qword, .{ .reg = .rax }, .{ .imm = 1 });
                } else {
                    try cg.e.alu(.add, .qword, .{ .reg = .rdx }, .{ .reg = .rcx });
                }
                cg.e.bind(done);
            }
            if (tag == .div_ceil) {
                // Round up when the remainder is non-zero and the exact
                // quotient is positive (dividend and divisor signs agree).
                const done = try cg.e.newLabel();
                try cg.e.@"test"(.qword, .{ .reg = .rdx }, .{ .reg = .rdx });
                try cg.e.jcc(.e, .{ .label = done });
                if (s) {
                    try cg.e.mov(.qword, .{ .reg = .r11 }, .{ .reg = .rdx });
                    try cg.e.alu(.xor, .qword, .{ .reg = .r11 }, .{ .reg = .rcx });
                    try cg.e.jcc(.s, .{ .label = done });
                }
                try cg.e.alu(.add, .qword, .{ .reg = .rax }, .{ .imm = 1 });
                cg.e.bind(done);
            }
            if (tag == .rem or tag == .mod) try cg.e.mov(.qword, .{ .reg = .rax }, .{ .reg = .rdx });
        },
        else => unreachable,
    }
    try cg.normalize(.rax, ty);
}

/// `{ T, u1 }` results: the wrapped value and whether it overflowed `T`.
fn overflowOp(cg: *CodeGen, inst: Inst.Index, tag: Inst.Tag, data: Inst.Data) Error!void {
    const ip = cg.ip;
    const bin = cg.ir.extraData(Ir.Bin, data.ty_pl.payload).data;
    const tuple_ty = data.ty_pl.ty;
    const ty = cg.typeOf(bin.lhs);
    const dst = try cg.resultMem(inst, tuple_ty) orelse return;
    const info = Type.intInfo(ip, ty);
    const s = info.signedness == .signed;
    try cg.load(.rax, bin.lhs);
    try cg.load(.rcx, bin.rhs);
    switch (tag) {
        .add_with_overflow => try cg.e.alu(.add, .qword, .{ .reg = .rax }, .{ .reg = .rcx }),
        .sub_with_overflow => try cg.e.alu(.sub, .qword, .{ .reg = .rax }, .{ .reg = .rcx }),
        .mul_with_overflow => if (s) {
            try cg.e.imul(.qword, .rax, .{ .reg = .rcx }, null);
        } else {
            try cg.e.unary(.mul, .qword, .{ .reg = .rcx });
        },
        else => unreachable,
    }
    // Flag from the 64-bit operation: only meaningful at 64 bits, or for
    // multiplications wider than 32 bits whose product can exceed 64 bits.
    const cpu_flag = info.bits == 64 or (tag == .mul_with_overflow and info.bits > 32);
    if (cpu_flag) {
        const cond: Encoder.Cond = if (s or tag == .mul_with_overflow) .o else .b;
        try cg.e.setcc(cond, .{ .reg = .r11 });
        try cg.e.movzx(.qword, .r11, .byte, .{ .reg = .r11 });
    } else {
        try cg.e.alu(.xor, .dword, .{ .reg = .r11 }, .{ .reg = .r11 });
    }
    if (info.bits < 64) {
        // Overflowed if truncating to `bits` changes the value.
        try cg.e.mov(.qword, .{ .reg = .rdx }, .{ .reg = .rax });
        try cg.normalize(.rax, ty);
        try cg.e.alu(.cmp, .qword, .{ .reg = .rax }, .{ .reg = .rdx });
        try cg.e.setcc(.ne, .{ .reg = .rdx });
        try cg.e.alu(.@"or", .byte, .{ .reg = .r11 }, .{ .reg = .rdx });
    }
    const size = Type.abiSize(ip, ty);
    try cg.storeReg(dst, .rax, size);
    try cg.storeReg(offsetMem(dst, Type.fieldOffset(ip, tuple_ty, 1)), .r11, 1);
}

fn switchBr(cg: *CodeGen, data: Inst.Data) Error!void {
    const ir = cg.ir;
    const extra = ir.extraData(Ir.SwitchBr, data.pl_op.payload);
    try cg.load(.rax, data.pl_op.operand);
    const Case = struct { label: Encoder.Label, body: []const Inst.Index };
    var cases: std.ArrayList(Case) = .empty;
    defer cases.deinit(cg.gpa);
    var i = extra.end;
    for (0..extra.data.cases_len) |_| {
        const items_len = ir.extra[i];
        const body_len = ir.extra[i + 1];
        const items = ir.refSlice(i + 2, items_len);
        const body = ir.bodySlice(i + 2 + items_len, body_len);
        i += 2 + items_len + body_len;
        const label = try cg.e.newLabel();
        for (items) |item| {
            try cg.load(.rcx, item);
            try cg.e.alu(.cmp, .qword, .{ .reg = .rax }, .{ .reg = .rcx });
            try cg.e.jcc(.e, .{ .label = label });
        }
        try cases.append(cg.gpa, .{ .label = label, .body = body });
    }
    try cg.genBody(ir.bodySlice(i, extra.data.else_body_len));
    for (cases.items) |c| {
        cg.e.bind(c.label);
        try cg.genBody(c.body);
    }
}

fn ret(cg: *CodeGen, operand: Ref) Error!void {
    const ty = cg.fn_ty.return_type;
    if (Type.hasRuntimeBits(cg.ip, ty)) {
        if (cg.ret_ptr_slot) |off| {
            try cg.e.mov(.qword, .{ .reg = .r10 }, .{ .mem = Mem.at(.rbp, off) });
            try cg.copyTo(Mem.at(.r10, 0), operand);
        } else {
            try cg.load(.rax, operand);
        }
    }
    try cg.e.mov(.qword, .{ .reg = .rsp }, .{ .reg = .rbp });
    try cg.e.pop(.rbp);
    try cg.e.ret();
}

fn call(cg: *CodeGen, inst: Inst.Index, data: Inst.Data) Error!void {
    const ip = cg.ip;
    const ir = cg.ir;
    const extra = ir.extraData(Ir.Call, data.pl_op.payload);
    const args = ir.refSlice(extra.end, extra.data.args_len);
    const callee_ref = data.pl_op.operand;
    const callee_val: ?Index = if (callee_ref.toInterned()) |v| switch (ip.indexToKey(v)) {
        .func => v,
        .ptr => |p| if (p.base == .nav and p.byte_offset == 0) ip.getNav(p.base.nav).val else null,
        else => null,
    } else null;
    const callee_fn_ty = cg.typeOf(callee_ref);
    const callee_ty = ip.indexToKey(if (Type.class(ip, callee_fn_ty) == .pointer) Type.ptrInfo(ip, callee_fn_ty).child else callee_fn_ty).func_type;
    const ret_ty = extra.data.ret_ty;
    const dst = try cg.resultMem(inst, ret_ty);
    if (callee_ty.cc == .c) {
        var reg_i: usize = 0;
        for (args) |arg| {
            const ty = cg.typeOf(arg);
            if (!Type.hasRuntimeBits(ip, ty)) continue;
            if (!cg.passInRegs(ty) or reg_i == c_arg_regs.len) return cg.fail("C calling convention arguments of type '{f}'", .{cg.fmtType(ty)});
            try cg.load(c_arg_regs[reg_i], arg);
            reg_i += 1;
        }
        if (dst != null and !cg.passInRegs(ret_ty)) return cg.fail("C calling convention results of type '{f}'", .{cg.fmtType(ret_ty)});
    } else {
        var off: u32 = 0;
        for (args) |arg| {
            const ty = cg.typeOf(arg);
            if (!Type.hasRuntimeBits(ip, ty)) continue;
            try cg.copyTo(Mem.at(.rsp, @intCast(off)), arg);
            off += @intCast(std.mem.alignForward(u64, Type.abiSize(ip, ty), 8));
        }
        cg.out_args_size = @max(cg.out_args_size, off);
        if (dst) |m| if (!cg.passInRegs(ret_ty)) try cg.e.lea(.qword, .rdi, m);
    }
    if (callee_val) |f| {
        try cg.e.call(.{ .sym = try cg.emit.funcKey(f) });
    } else {
        // r11 is not an argument register in either convention.
        try cg.load(.r11, callee_ref);
        try cg.e.callIndirect(.{ .reg = .r11 });
    }
    if (dst) |m| if (cg.passInRegs(ret_ty)) try cg.storeReg(m, .rax, Type.abiSize(ip, ret_ty));
}

// ---------------------------------------------------------------------------
// Panics
//
// A failed safety check writes `panic: <message>` to stderr and raises
// SIGABRT. The message matches upstream's default panic handler; upstream
// also prints the thread id and a stack trace. Milestone 3 calls
// `std.builtin.panic` instead.

const panic_write = "__zap_panic_write";
const panic_write_dec = "__zap_panic_write_dec";
const panic_abort = "__zap_panic_abort";

fn panicWriteStr(cg: *CodeGen, s: []const u8) Error!void {
    const key = try cg.emit.contentAtom(1, s, &.{}, &.{});
    try cg.e.lea(.qword, .rdi, Mem.sym(key, 0));
    try cg.e.mov(.qword, .{ .reg = .rsi }, .{ .imm = @intCast(s.len) });
    try cg.e.call(.{ .sym = .fromName(panic_write) });
}

fn panicWriteDec(cg: *CodeGen, ref: Ref) Error!void {
    try cg.load(.rdi, ref);
    try cg.e.call(.{ .sym = .fromName(panic_write_dec) });
}

fn panic(cg: *CodeGen, id: Ir.PanicId, payload: u32) Error!void {
    cg.emit.uses_panic = true;
    // Keep the stack aligned for the helpers even in a frame that has no
    // slots yet.
    switch (id) {
        .out_of_bounds => {
            const bin = cg.ir.extraData(Ir.Bin, payload).data;
            try cg.panicWriteStr("panic: index out of bounds: index ");
            try cg.panicWriteDec(bin.lhs);
            try cg.panicWriteStr(", len ");
            try cg.panicWriteDec(bin.rhs);
            try cg.panicWriteStr("\n");
        },
        .start_greater_than_end => {
            const bin = cg.ir.extraData(Ir.Bin, payload).data;
            try cg.panicWriteStr("panic: start index ");
            try cg.panicWriteDec(bin.lhs);
            try cg.panicWriteStr(" is larger than end index ");
            try cg.panicWriteDec(bin.rhs);
            try cg.panicWriteStr("\n");
        },
        .unwrap_error => return cg.fail("panics that print error names", .{}),
        else => {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "panic: {s}\n", .{id.message()}) catch unreachable;
            try cg.panicWriteStr(msg);
        },
    }
    try cg.e.call(.{ .sym = .fromName(panic_abort) });
}

/// The runtime helpers the panic code calls, written directly with the
/// encoder: write a string to stderr, write an unsigned decimal, abort.
pub fn emitPanicHelpers(emit: *Emit) Error!void {
    const gpa = emit.gpa;
    const arena = emit.allocator();
    {
        // (rdi = ptr, rsi = len): write(2, ptr, len)
        var e: Encoder = .init(gpa);
        defer e.deinit();
        try e.mov(.qword, .{ .reg = .rdx }, .{ .reg = .rsi });
        try e.mov(.qword, .{ .reg = .rsi }, .{ .reg = .rdi });
        try e.mov(.dword, .{ .reg = .rdi }, .{ .imm = 2 });
        try e.mov(.dword, .{ .reg = .rax }, .{ .imm = 1 });
        try e.syscall();
        try e.ret();
        e.finish();
        try emit.addAtom(.{ .key = .fromName(panic_write), .name = panic_write, .section = .text, .alignment = .@"16", .bytes = try arena.dupe(u8, e.code.items) });
    }
    {
        // (rdi = value): format into a buffer on the stack, then write it.
        var e: Encoder = .init(gpa);
        defer e.deinit();
        try e.push(.rbp);
        try e.mov(.qword, .{ .reg = .rbp }, .{ .reg = .rsp });
        try e.alu(.sub, .qword, .{ .reg = .rsp }, .{ .imm = 32 });
        try e.mov(.qword, .{ .reg = .rsi }, .{ .reg = .rbp });
        try e.mov(.qword, .{ .reg = .rax }, .{ .reg = .rdi });
        try e.mov(.dword, .{ .reg = .rcx }, .{ .imm = 10 });
        const top = try e.newLabel();
        e.bind(top);
        try e.alu(.xor, .dword, .{ .reg = .rdx }, .{ .reg = .rdx });
        try e.unary(.div, .qword, .{ .reg = .rcx });
        try e.alu(.add, .byte, .{ .reg = .rdx }, .{ .imm = '0' });
        try e.alu(.sub, .qword, .{ .reg = .rsi }, .{ .imm = 1 });
        try e.mov(.byte, .{ .mem = Mem.at(.rsi, 0) }, .{ .reg = .rdx });
        try e.@"test"(.qword, .{ .reg = .rax }, .{ .reg = .rax });
        try e.jcc(.ne, .{ .label = top });
        try e.mov(.qword, .{ .reg = .rdx }, .{ .reg = .rbp });
        try e.alu(.sub, .qword, .{ .reg = .rdx }, .{ .reg = .rsi });
        try e.mov(.dword, .{ .reg = .rdi }, .{ .imm = 2 });
        try e.mov(.dword, .{ .reg = .rax }, .{ .imm = 1 });
        try e.syscall();
        try e.mov(.qword, .{ .reg = .rsp }, .{ .reg = .rbp });
        try e.pop(.rbp);
        try e.ret();
        e.finish();
        try emit.addAtom(.{ .key = .fromName(panic_write_dec), .name = panic_write_dec, .section = .text, .alignment = .@"16", .bytes = try arena.dupe(u8, e.code.items) });
    }
    {
        // kill(getpid(), SIGABRT), then trap if that returns.
        var e: Encoder = .init(gpa);
        defer e.deinit();
        try e.mov(.dword, .{ .reg = .rax }, .{ .imm = 39 });
        try e.syscall();
        try e.mov(.qword, .{ .reg = .rdi }, .{ .reg = .rax });
        try e.mov(.dword, .{ .reg = .rsi }, .{ .imm = 6 });
        try e.mov(.dword, .{ .reg = .rax }, .{ .imm = 62 });
        try e.syscall();
        try e.ud2();
        e.finish();
        try emit.addAtom(.{ .key = .fromName(panic_abort), .name = panic_abort, .section = .text, .alignment = .@"16", .bytes = try arena.dupe(u8, e.code.items) });
    }
}

// ---------------------------------------------------------------------------
// Inline assembly
//
// Templates use AT&T syntax, as upstream's x86_64 backend parses them. zap
// assembles the instructions that system-call stubs and entry points use.
// Operands with `{reg}` constraints are loaded into (or stored from) that
// register; `X`, `i`, and `n` inputs are substituted into the template as
// symbols or immediates.

const AsmArg = union(enum) { sym: struct { key: SymbolKey, off: i32 }, imm: i64 };

fn assembly(cg: *CodeGen, inst: Inst.Index, data: Inst.Data) Error!void {
    const ip = cg.ip;
    const ir = cg.ir;
    const extra = ir.extraData(Ir.Asm, data.ty_pl.payload);
    var i = extra.end;
    const Operand = Ir.Asm.Operand;
    const n_ops = extra.data.outputs_len + extra.data.inputs_len;
    const ops = try cg.gpa.alloc(Operand, n_ops);
    defer cg.gpa.free(ops);
    for (ops) |*op| {
        op.* = ir.extraData(Operand, i).data;
        i += 3;
    }
    const outputs = ops[0..extra.data.outputs_len];
    const inputs = ops[extra.data.outputs_len..];

    var names: std.StringHashMapUnmanaged(AsmArg) = .empty;
    defer names.deinit(cg.gpa);
    for (inputs) |in| {
        const constraint = ip.stringSlice(in.constraint);
        if (regConstraint(constraint)) |reg_name| {
            const reg = parseReg(reg_name) orelse return cg.fail("unknown register '{s}' in asm constraint", .{reg_name});
            try cg.load(reg.reg, in.operand);
        } else if (std.mem.eql(u8, constraint, "X") or std.mem.eql(u8, constraint, "i") or std.mem.eql(u8, constraint, "n")) {
            const arg: AsmArg = switch (try cg.locOf(in.operand)) {
                .imm => |v| .{ .imm = @bitCast(v) },
                .addr => |m| if (m.base == .sym) .{ .sym = .{ .key = m.base.sym, .off = m.disp } } else return cg.fail("asm input '{s}' must be comptime-known", .{constraint}),
                else => return cg.fail("asm input '{s}' must be comptime-known", .{constraint}),
            };
            try names.put(cg.gpa, ip.stringSlice(in.name), arg);
        } else return cg.fail("asm input constraint '{s}'", .{constraint});
    }
    for (outputs) |out| {
        const constraint = ip.stringSlice(out.constraint);
        if (!std.mem.startsWith(u8, constraint, "=") or regConstraint(constraint[1..]) == null)
            return cg.fail("asm output constraint '{s}'", .{constraint});
    }

    try cg.assemble(ip.stringSlice(extra.data.source), &names);

    for (outputs) |out| {
        const constraint = ip.stringSlice(out.constraint);
        const reg = (parseReg(regConstraint(constraint[1..]).?) orelse return cg.fail("unknown register in asm constraint '{s}'", .{constraint})).reg;
        if (out.operand == .none) {
            const ty = data.ty_pl.ty;
            const dst = try cg.resultMem(inst, ty) orelse continue;
            try cg.storeReg(dst, reg, Type.abiSize(ip, ty));
        } else {
            const ty = Type.ptrInfo(ip, cg.typeOf(out.operand)).child;
            const tmp: Reg = if (reg == .r10) .r11 else .r10;
            try cg.load(tmp, out.operand);
            try cg.storeReg(Mem.at(tmp, 0), reg, Type.abiSize(ip, ty));
        }
    }
}

fn regConstraint(c: []const u8) ?[]const u8 {
    if (c.len < 3 or c[0] != '{' or c[c.len - 1] != '}') return null;
    return c[1 .. c.len - 1];
}

const ParsedReg = struct { reg: Reg, size: Size };

fn parseReg(name: []const u8) ?ParsedReg {
    const n = if (name.len > 0 and name[0] == '%') name[1..] else name;
    const tables = [_]struct { size: Size, names: [16][]const u8 }{
        .{ .size = .qword, .names = .{ "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" } },
        .{ .size = .dword, .names = .{ "eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi", "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d" } },
        .{ .size = .word, .names = .{ "ax", "cx", "dx", "bx", "sp", "bp", "si", "di", "r8w", "r9w", "r10w", "r11w", "r12w", "r13w", "r14w", "r15w" } },
        .{ .size = .byte, .names = .{ "al", "cl", "dl", "bl", "spl", "bpl", "sil", "dil", "r8b", "r9b", "r10b", "r11b", "r12b", "r13b", "r14b", "r15b" } },
    };
    for (tables) |t| {
        for (t.names, 0..) |rn, i| if (std.mem.eql(u8, rn, n)) return .{ .reg = @fromBackingInt(@intCast(i)), .size = t.size };
    }
    return null;
}

const AsmOperand = union(enum) { reg: ParsedReg, imm: i64, sym: struct { key: SymbolKey, off: i32 } };

fn assemble(cg: *CodeGen, source: []const u8, names: *const std.StringHashMapUnmanaged(AsmArg)) Error!void {
    var lines = std.mem.tokenizeAny(u8, source, "\n;");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        const mnemonic = line[0..sp];
        var operands: [2]AsmOperand = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeScalar(u8, line[sp..], ',');
        while (it.next()) |tok| {
            if (n == 2) return cg.fail("asm instruction with more than two operands: '{s}'", .{line});
            operands[n] = try cg.asmOperand(std.mem.trim(u8, tok, " \t"), names, line);
            n += 1;
        }
        try cg.asmInst(mnemonic, operands[0..n], line);
    }
}

fn asmOperand(cg: *CodeGen, tok: []const u8, names: *const std.StringHashMapUnmanaged(AsmArg), line: []const u8) Error!AsmOperand {
    if (std.mem.startsWith(u8, tok, "%[")) {
        const close = std.mem.indexOfScalar(u8, tok, ']') orelse return cg.fail("bad asm operand '{s}'", .{tok});
        var name = tok[2..close];
        if (std.mem.indexOfScalar(u8, name, ':')) |colon| name = name[0..colon];
        const arg = names.get(name) orelse return cg.fail("asm operand '{s}' is not an 'X' input", .{name});
        return switch (arg) {
            .imm => |v| .{ .imm = v },
            .sym => |s| .{ .sym = .{ .key = s.key, .off = s.off } },
        };
    }
    if (std.mem.startsWith(u8, tok, "%%") or std.mem.startsWith(u8, tok, "%")) {
        const name = std.mem.trimStart(u8, tok, "%");
        const reg = parseReg(name) orelse return cg.fail("unknown register '{s}' in '{s}'", .{ name, line });
        return .{ .reg = reg };
    }
    if (std.mem.startsWith(u8, tok, "$")) {
        const v = std.fmt.parseInt(i64, tok[1..], 0) catch return cg.fail("bad asm immediate '{s}'", .{tok});
        return .{ .imm = v };
    }
    return cg.fail("zap does not support asm operand '{s}' yet", .{tok});
}

fn asmInst(cg: *CodeGen, mnemonic: []const u8, ops: []const AsmOperand, line: []const u8) Error!void {
    const e = &cg.e;
    const eql = std.mem.eql;
    if (ops.len == 0) {
        if (eql(u8, mnemonic, "syscall")) return e.syscall();
        if (eql(u8, mnemonic, "ud2")) return e.ud2();
        if (eql(u8, mnemonic, "int3")) return e.int3();
        if (eql(u8, mnemonic, "ret")) return e.ret();
    } else if (ops.len == 1) {
        if (eql(u8, mnemonic, "call") or eql(u8, mnemonic, "callq") or eql(u8, mnemonic, "jmp")) switch (ops[0]) {
            .sym => |s| {
                if (s.off != 0) return cg.fail("asm call with an offset: '{s}'", .{line});
                return if (mnemonic[0] == 'c') e.call(.{ .sym = s.key }) else e.jmp(.{ .sym = s.key });
            },
            .reg => |r| return if (mnemonic[0] == 'c') e.callIndirect(.{ .reg = r.reg }) else e.jmpIndirect(.{ .reg = r.reg }),
            .imm => {},
        };
        if ((eql(u8, mnemonic, "push") or eql(u8, mnemonic, "pushq")) and ops[0] == .reg) return e.push(ops[0].reg.reg);
        if ((eql(u8, mnemonic, "pop") or eql(u8, mnemonic, "popq")) and ops[0] == .reg) return e.pop(ops[0].reg.reg);
    } else if (ops[1] == .reg) {
        // AT&T order: source, destination.
        const dst = ops[1].reg;
        const base = std.mem.trimEnd(u8, mnemonic, "bwlq");
        const suffix_size: ?Size = if (mnemonic.len > base.len) switch (mnemonic[mnemonic.len - 1]) {
            'b' => .byte,
            'w' => .word,
            'l' => .dword,
            'q' => .qword,
            else => null,
        } else null;
        const size = suffix_size orelse dst.size;
        const src: Encoder.Operand = switch (ops[0]) {
            .reg => |r| .{ .reg = r.reg },
            .imm => |v| .{ .imm = v },
            .sym => return cg.fail("symbol operand in '{s}'", .{line}),
        };
        if (eql(u8, base, "mov") or eql(u8, mnemonic, "movabs")) return e.mov(size, .{ .reg = dst.reg }, src);
        const alu_ops = [_]struct { []const u8, Encoder.AluOp }{
            .{ "add", .add }, .{ "or", .@"or" }, .{ "and", .@"and" }, .{ "sub", .sub }, .{ "xor", .xor }, .{ "cmp", .cmp },
        };
        for (alu_ops) |op| if (eql(u8, base, op[0])) return e.alu(op[1], size, .{ .reg = dst.reg }, src);
    }
    return cg.fail("zap does not support this inline assembly instruction yet: '{s}'", .{line});
}

// ---------------------------------------------------------------------------
// Constants

const PtrTarget = struct { key: SymbolKey, off: i64 };

/// The symbol and offset a comptime-known pointer refers to.
pub fn ptrTarget(emit: *Emit, ptr: Index) Error!PtrTarget {
    const ip = &emit.zcu.ip;
    const p = ip.indexToKey(ptr).ptr;
    var t: PtrTarget = switch (p.base) {
        .nav => |n| blk: {
            const nav = ip.getNav(n);
            if (ip.indexToKey(nav.val) == .func) break :blk .{ .key = try emit.funcKey(nav.val), .off = 0 };
            break :blk .{ .key = try emit.navKey(n), .off = 0 };
        },
        .uav => |u| .{ .key = try emit.uavKey(u.val), .off = 0 },
        .field => |f| blk: {
            var parent = try ptrTarget(emit, f.base);
            const container = Type.ptrInfo(ip, ip.typeOf(f.base)).child;
            parent.off += @intCast(switch (ip.indexToKey(container)) {
                .opt_type => 0,
                .error_union_type => Type.errorUnionLayout(ip, container).payload_offset,
                .ptr_type => f.index * 8,
                else => Type.fieldOffset(ip, container, @intCast(f.index)),
            });
            break :blk parent;
        },
        .elem => |el| blk: {
            var parent = try ptrTarget(emit, el.base);
            const base_ty = Type.ptrInfo(ip, ip.typeOf(el.base));
            const elem_ty = switch (ip.indexToKey(base_ty.child)) {
                .array_type => |a| if (base_ty.flags.size == .one) a.child else base_ty.child,
                else => base_ty.child,
            };
            parent.off += @intCast(el.index * Type.abiSize(ip, elem_ty));
            break :blk parent;
        },
        .int, .comptime_alloc => unreachable, // handled by callers / rejected by Sema
    };
    t.off += @intCast(p.byte_offset);
    return t;
}

/// Writes the bytes of comptime-known `val` into `out` (its ABI size), with
/// relocations at `base_off + offset`.
pub fn lowerValue(emit: *Emit, val: Index, out: []u8, relocs: *Atom.RelocList, base_off: u32) Error!void {
    const ip = &emit.zcu.ip;
    const gpa = emit.gpa;
    const ty = ip.typeOf(val);
    if (!Type.hasRuntimeBits(ip, ty)) return;
    switch (ip.indexToKey(val)) {
        .undef => @memset(out, 0xaa),
        .int => {
            // Two's complement, little-endian, sign- or zero-extended to the
            // ABI size.
            var space: [2]std.math.big.Limb = undefined;
            const big = ip.intToBig(val, &space);
            var m = try std.math.big.int.Managed.init(gpa);
            defer m.deinit();
            try m.ensureTwosCompCapacity(@intCast(out.len * 8));
            var mut = m.toMutable();
            mut.truncate(big, .unsigned, @intCast(out.len * 8));
            mut.toConst().writeTwosComplement(out, .little);
        },
        .simple_value => |s| out[0] = @intFromBool(s == .true),
        .enum_tag => |e| try lowerValue(emit, e.int, out, relocs, base_off),
        .un => |u| {
            @memset(out, 0);
            const layout = Type.unionLayout(ip, ty);
            if (layout.tag_size != 0) {
                const tag_int = if (ip.indexToKey(u.tag) == .enum_tag) ip.indexToKey(u.tag).enum_tag.int else u.tag;
                try lowerValue(emit, tag_int, out[@intCast(layout.tag_offset)..][0..@intCast(layout.tag_size)], relocs, base_off + @as(u32, @intCast(layout.tag_offset)));
            }
            const pt = ip.typeOf(u.val);
            if (Type.hasRuntimeBits(ip, pt)) {
                const off: u32 = @intCast(layout.payload_offset);
                try lowerValue(emit, u.val, out[off..][0..@intCast(Type.abiSize(ip, pt))], relocs, base_off + off);
            }
        },
        .err => |e| {
            @memset(out, 0);
            try relocs.append(gpa, base_off, .value16, try emit.useError(e.name), 0);
        },
        .ptr => |p| {
            if (p.base == .int) {
                std.mem.writeInt(u64, out[0..8], p.byte_offset, .little);
            } else {
                const t = try ptrTarget(emit, val);
                @memset(out[0..8], 0);
                try relocs.append(gpa, base_off, .x86_64_abs64, t.key, t.off);
            }
        },
        .slice => |s| {
            try lowerValue(emit, s.ptr, out[0..8], relocs, base_off);
            try lowerValue(emit, s.len, out[8..16], relocs, base_off + 8);
        },
        .opt => |o| {
            const child = Type.childType(ip, ty);
            @memset(out, 0);
            if (o.val == .none) return;
            if (Type.optionalReprIsPtr(ip, child)) return lowerValue(emit, o.val, out, relocs, base_off);
            const size = Type.abiSize(ip, child);
            try lowerValue(emit, o.val, out[0..size], relocs, base_off);
            out[size] = 1;
        },
        .error_union => |eu| {
            const layout = Type.errorUnionLayout(ip, ty);
            @memset(out, 0);
            switch (eu.val) {
                .err_name => |name| try relocs.append(gpa, base_off + @as(u32, @intCast(layout.err_offset)), .value16, try emit.useError(name), 0),
                .payload => |pl| {
                    const size = Type.abiSize(ip, ip.typeOf(pl));
                    const off: u32 = @intCast(layout.payload_offset);
                    try lowerValue(emit, pl, out[off..][0..size], relocs, base_off + off);
                },
            }
        },
        .aggregate => |a| {
            @memset(out, 0);
            switch (ip.indexToKey(ty)) {
                .array_type => |at| {
                    const esize = Type.abiSize(ip, at.child);
                    const n = at.lenIncludingSentinel();
                    switch (a.storage) {
                        .bytes => |s| @memcpy(out, ip.stringSlice(s)[0..out.len]),
                        .elems => |elems| for (elems[0..n], 0..) |el, i| {
                            const off: u32 = @intCast(i * esize);
                            try lowerValue(emit, el, out[off..][0..esize], relocs, base_off + off);
                        },
                        .repeated_elem => |el| for (0..n) |i| {
                            const elem = if (i == at.len and at.sentinel != .none) at.sentinel else el;
                            const off: u32 = @intCast(i * esize);
                            try lowerValue(emit, elem, out[off..][0..esize], relocs, base_off + off);
                        },
                    }
                },
                .struct_type, .tuple_type => {
                    const n = Type.fieldCount(ip, ty);
                    for (0..n) |i| {
                        const ft = Type.fieldType(ip, ty, i);
                        if (!Type.hasRuntimeBits(ip, ft)) continue;
                        if (ip.indexToKey(ty) == .tuple_type and ip.indexToKey(ty).tuple_type.values[i] != .none) continue;
                        const el = switch (a.storage) {
                            .elems => |elems| elems[i],
                            .repeated_elem => |el| el,
                            .bytes => unreachable,
                        };
                        const off: u32 = @intCast(Type.fieldOffset(ip, ty, i));
                        const size = Type.abiSize(ip, ft);
                        try lowerValue(emit, el, out[off..][0..size], relocs, base_off + off);
                    }
                },
                else => unreachable,
            }
        },
        else => @memset(out, 0),
    }
}

// ---------------------------------------------------------------------------

const FmtType = struct {
    ip: *const InternPool,
    ty: Index,
    pub fn format(f: FmtType, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try @import("../../Ir/print.zig").printType(f.ip, f.ty, w);
    }
};

fn fmtType(cg: *CodeGen, ty: Index) FmtType {
    return .{ .ip = cg.ip, .ty = ty };
}
