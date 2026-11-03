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
//! - `.c`: SysV for scalars: integers, bools, and pointers in GPRs (16-byte
//!   integers in pairs), f16/f32/f64/f128 in XMM registers, f80 in memory
//!   and returned in st0; other values in memory.
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
/// Inline assembly marked the return address undefined (`.cfi_undefined
/// %rip`): this is the outermost frame.
outermost_frame: bool = false,

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
        .frame = if (naked) .none else .frame_pointer,
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
    if (cg.fn_ty.cc == .c) return cg.setupCParams();
    const ret_ty = cg.fn_ty.return_type;
    if (Type.hasRuntimeBits(ip, ret_ty) and !cg.passInRegs(ret_ty)) {
        const off = try cg.allocSlot(8, 8);
        try cg.e.mov(.qword, .{ .mem = Mem.at(.rbp, off) }, .{ .reg = .rdi });
        cg.ret_ptr_slot = off;
    }
    // `arg` instructions are at the start of the main body.
    var stack_off: i32 = 16;
    for (cg.ir.mainBody()) |inst| {
        if (cg.ir.instructions.items(.tag)[@backingInt(inst)] != .arg) break;
        const ty = cg.ir.instructions.items(.data)[@backingInt(inst)].arg.ty;
        if (!Type.hasRuntimeBits(ip, ty)) continue;
        const size = Type.abiSize(ip, ty);
        cg.homes[@backingInt(inst)] = .{ .slot = stack_off };
        stack_off += @intCast(std.mem.alignForward(u64, size, 8));
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
        .float => |f| if (cg.passInRegs(ty)) return .{ .imm = @truncate(f.bits()) },
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
        try cg.e.mov(.qword, .{ .reg = .rcx }, .{ .imm = @intCast(size) });
        return cg.e.repMovsb();
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
            if (cg.isFloat(ty)) return cg.genFloat(inst, tag, data);
            if (cg.isWideInt(ty)) return cg.genWide(inst, tag, data);
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.binOp(tag, ty, data.bin_op.lhs, data.bin_op.rhs);
            try cg.storeReg(dst, .rax, Type.abiSize(ip, ty));
        },
        .add_with_overflow, .sub_with_overflow, .mul_with_overflow => if (cg.isWideInt(cg.typeOf(ir.extraData(Ir.Bin, data.ty_pl.payload).data.lhs)))
            try cg.genWide(inst, tag, data)
        else
            try cg.overflowOp(inst, tag, data),
        .add_float, .sub_float, .mul_float, .div_float, .min_float, .max_float, .neg_float, .abs_float => try cg.genFloat(inst, tag, data),
        .sqrt, .sin, .cos, .tan, .exp, .exp2, .log, .log2, .log10, .floor, .ceil, .round, .trunc_float => try cg.genFloat(inst, tag, data),
        .mul_add, .float_cast, .float_from_int, .int_from_float => try cg.genFloat(inst, tag, data),
        .not => {
            const ty = data.ty_op.ty;
            if (cg.isWideInt(ty)) return cg.genWide(inst, tag, data);
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
            const ty = cg.typeOf(data.bin_op.lhs);
            if (cg.isFloat(ty)) return cg.genFloat(inst, tag, data);
            if (cg.isWideInt(ty)) return cg.genWide(inst, tag, data);
            const dst = try cg.resultMem(inst, .bool_type) orelse return;
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
            if (tag != .ptr_from_int and (cg.isWideInt(ty) or cg.isWideInt(cg.typeOf(data.ty_op.operand))) and Type.isInt(ip, ty)) return cg.genWide(inst, tag, data);
            const dst = try cg.resultMem(inst, ty) orelse return;
            const size = Type.abiSize(ip, ty);
            if (cg.passInRegs(ty) and cg.passInRegs(cg.typeOf(data.ty_op.operand))) {
                try cg.load(.rax, data.ty_op.operand);
                if (Type.isInt(ip, ty)) try cg.normalize(.rax, ty);
                try cg.storeReg(dst, .rax, size);
            } else if (Type.abiSize(ip, cg.typeOf(data.ty_op.operand)) != size) {
                // A bitcast between a vector and an array or integer
                // without its padding: the low bytes.
                const n = @min(size, Type.abiSize(ip, cg.typeOf(data.ty_op.operand)));
                try cg.fillMem(dst, size, 0);
                try cg.copyMem(dst, try cg.memOf(data.ty_op.operand), n);
                if (Type.isInt(ip, ty) and cg.passInRegs(ty)) {
                    try cg.loadMem(.rax, dst, ty);
                    try cg.normalize(.rax, ty);
                    try cg.storeReg(dst, .rax, size);
                }
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
            if (ip.indexToKey(cg.typeOf(data.bin_op.lhs)) == .vector_type and ty == .bool_type) {
                // Bit-packed bool vector: bit rcx % 8 of byte rcx / 8.
                try cg.e.mov(.qword, .{ .reg = .rax }, .{ .reg = .rcx });
                try cg.e.shift(.shr, .qword, .{ .reg = .rax }, 3);
                try cg.e.alu(.add, .qword, .{ .reg = .r10 }, .{ .reg = .rax });
                try cg.e.movzx(.dword, .rax, .byte, .{ .mem = Mem.at(.r10, 0) });
                try cg.e.alu(.@"and", .dword, .{ .reg = .rcx }, .{ .imm = 7 });
                try cg.e.shift(.shr, .dword, .{ .reg = .rax }, null);
                try cg.e.alu(.@"and", .dword, .{ .reg = .rax }, .{ .imm = 1 });
                return cg.storeReg(dst, .rax, 1);
            }
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
            if (ip.indexToKey(ty) == .vector_type and ip.indexToKey(ty).vector_type.child == .bool_type) {
                // Bit-packed: element i is bit i % 8 of byte i / 8.
                try cg.fillMem(dst, Type.abiSize(ip, ty), 0);
                for (elems, 0..) |elem, i| {
                    try cg.load(.rax, elem);
                    if (i % 8 != 0) try cg.e.shift(.shl, .byte, .{ .reg = .rax }, @intCast(i % 8));
                    try cg.e.alu(.@"or", .byte, .{ .mem = offsetMem(dst, i / 8) }, .{ .reg = .rax });
                }
                return;
            }
            for (elems, 0..) |elem, i| {
                const off = switch (ip.indexToKey(ty)) {
                    .array_type => |a| i * Type.abiSize(ip, a.child),
                    .vector_type => |v| i * Type.abiSize(ip, v.child),
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
        .memcpy, .memmove => {
            const elem_size = try cg.memDest(.rdi, .rcx, data.bin_op.lhs);
            if (elem_size != 1) try cg.e.imul(.qword, .rcx, .{ .reg = .rcx }, @intCast(elem_size));
            try cg.load(.rsi, data.bin_op.rhs);
            if (tag == .memcpy) return cg.e.repMovsb();
            // Copy backwards when the destination is above the source.
            const forward = try cg.e.newLabel();
            const done = try cg.e.newLabel();
            try cg.e.alu(.cmp, .qword, .{ .reg = .rdi }, .{ .reg = .rsi });
            try cg.e.jcc(.be, .{ .label = forward });
            try cg.e.lea(.qword, .rsi, .{ .base = .{ .reg = .rsi }, .index = .{ .reg = .rcx, .scale = .@"1" }, .disp = -1 });
            try cg.e.lea(.qword, .rdi, .{ .base = .{ .reg = .rdi }, .index = .{ .reg = .rcx, .scale = .@"1" }, .disp = -1 });
            try cg.e.setDirection(true);
            try cg.e.repMovsb();
            try cg.e.setDirection(false);
            try cg.e.jmp(.{ .label = done });
            cg.e.bind(forward);
            try cg.e.repMovsb();
            cg.e.bind(done);
        },
        .memset => {
            const elem = data.bin_op.rhs;
            const elem_ty = cg.typeOf(elem);
            if (Type.abiSize(ip, elem_ty) == 1) {
                _ = try cg.memDest(.rdi, .rcx, data.bin_op.lhs);
                try cg.load(.rax, elem);
                return cg.e.repStosb();
            }
            // Store the first element, then let an overlapping forward
            // `rep movsb` replicate it through the rest.
            const elem_size = try cg.memDest(.r8, .r9, data.bin_op.lhs);
            const done = try cg.e.newLabel();
            try cg.e.@"test"(.qword, .{ .reg = .r9 }, .{ .reg = .r9 });
            try cg.e.jcc(.e, .{ .label = done });
            if (elem.toInterned()) |v| if (ip.indexToKey(v) == .undef) {
                try cg.fillMem(Mem.at(.r8, 0), elem_size, 0xaa);
            } else try cg.copyTo(Mem.at(.r8, 0), elem) else try cg.copyTo(Mem.at(.r8, 0), elem);
            try cg.e.mov(.qword, .{ .reg = .rsi }, .{ .reg = .r8 });
            try cg.e.lea(.qword, .rdi, Mem.at(.r8, @intCast(elem_size)));
            try cg.e.lea(.qword, .rcx, Mem.at(.r9, -1));
            try cg.e.imul(.qword, .rcx, .{ .reg = .rcx }, @intCast(elem_size));
            try cg.e.repMovsb();
            cg.e.bind(done);
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
            if (cg.isWideInt(cg.typeOf(data.ty_op.operand))) return cg.wideBitOp(inst, tag, data);
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

/// Loads the pointer of `@memcpy`/`@memset` destination `dest` (a slice
/// or `*[N]T`) into `ptr` and its length in elements into `len`, and
/// returns the element size. May use rax.
fn memDest(cg: *CodeGen, ptr: Reg, len: Reg, dest: Ref) Error!u64 {
    const ip = cg.ip;
    const p = Type.ptrInfo(ip, cg.typeOf(dest));
    if (p.flags.size == .slice) {
        const m = try cg.memOf(dest);
        try cg.e.mov(.qword, .{ .reg = ptr }, .{ .mem = m });
        try cg.e.mov(.qword, .{ .reg = len }, .{ .mem = offsetMem(m, 8) });
        return Type.abiSize(ip, p.child);
    }
    const a = ip.indexToKey(p.child).array_type;
    try cg.load(ptr, dest);
    try cg.e.mov(.qword, .{ .reg = len }, .{ .imm = @intCast(a.len) });
    return Type.abiSize(ip, a.child);
}

/// The bit operations into rax. The baseline x86_64 CPU has no lzcnt,
/// tzcnt, or popcnt, so clz and ctz use bsr and bsf, and popcount and
/// bit_reverse loop over the bits. Uses rcx, rdx, r11.
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
            // bsf leaves ZF set and its destination undefined for 0.
            try e.mov(.dword, .{ .reg = .rax }, .{ .imm = bits });
            try e.bitScan(false, .qword, .rcx, .{ .reg = .rdx });
            try e.cmov(.ne, .qword, .rax, .{ .reg = .rcx });
        },
        .clz => {
            // bits - 1 - (index of the top set bit), or bits for 0.
            try e.mov(.dword, .{ .reg = .rax }, .{ .imm = bits });
            try e.bitScan(true, .qword, .rcx, .{ .reg = .rdx });
            try e.jcc(.e, .{ .label = done });
            try e.mov(.dword, .{ .reg = .rax }, .{ .imm = @as(i64, bits) - 1 });
            try e.alu(.sub, .qword, .{ .reg = .rax }, .{ .reg = .rcx });
        },
        .byte_swap => {
            try e.mov(.qword, .{ .reg = .rax }, .{ .reg = .rdx });
            if (bits > 8) {
                try e.bswap(.qword, .rax);
                if (bits < 64) try e.shift(.shr, .qword, .{ .reg = .rax }, @intCast(64 - bits));
            }
        },
        .bit_reverse => {
            // Move the low unit of x to the bottom of n, `bits / unit` times.
            const unit: u8 = 1;
            try e.mov(.dword, .{ .reg = .rcx }, .{ .imm = bits / unit });
            e.bind(top);
            try e.@"test"(.dword, .{ .reg = .rcx }, .{ .reg = .rcx });
            try e.jcc(.e, .{ .label = done });
            try e.shift(.shl, .qword, .{ .reg = .rax }, unit);
            try e.mov(.qword, .{ .reg = .r11 }, .{ .reg = .rdx });
            try e.alu(.@"and", .qword, .{ .reg = .r11 }, .{ .imm = 1 });
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
    if (cg.fn_ty.cc == .c) {
        try cg.cRet(operand);
    } else if (Type.hasRuntimeBits(cg.ip, ty)) {
        if (cg.ret_ptr_slot) |off| {
            try cg.e.mov(.qword, .{ .reg = .r10 }, .{ .mem = Mem.at(.rbp, off) });
            try cg.copyTo(Mem.at(.r10, 0), operand);
        } else {
            try cg.load(.rax, operand);
        }
    }
    // The epilogue belongs to the closing brace, as in upstream's line tables.
    try cg.e.line(cg.ir.rbrace_line, cg.ir.rbrace_column);
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
        const vals = try cg.gpa.alloc(Val, args.len);
        defer cg.gpa.free(vals);
        for (args, vals) |arg, *v| v.* = try cg.valOf(arg);
        try cg.cCallArgs(vals, ret_ty, dst);
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
    if (callee_ty.cc == .c) return cg.cCallResult(ret_ty, dst);
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

const AsmArg = union(enum) { sym: struct { key: SymbolKey, off: i32 }, imm: i64, reg: ParsedReg };

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
    // `r` inputs get registers that no `{reg}` constraint names.
    var used: u16 = 0;
    for (ops) |op| {
        const c = std.mem.trimStart(u8, ip.stringSlice(op.constraint), "=");
        if (regConstraint(c)) |rn| if (parseReg(rn)) |r| {
            used |= @as(u16, 1) << @backingInt(r.reg);
        };
    }
    for (inputs) |in| {
        const constraint = ip.stringSlice(in.constraint);
        const is_r = std.mem.eql(u8, constraint, "r") or (std.mem.eql(u8, constraint, "rm") and cg.passInRegs(cg.typeOf(in.operand)));
        if (is_r) {
            const in_size = Type.abiSize(ip, cg.typeOf(in.operand));
            const reg = for ([_]Reg{ .r8, .r9, .r10, .r11, .rsi, .rdi, .rcx, .rdx, .rax }) |r| {
                if (used & (@as(u16, 1) << @backingInt(r)) == 0) break r;
            } else return cg.fail("asm with too many register operands", .{});
            used |= @as(u16, 1) << @backingInt(reg);
            try cg.load(reg, in.operand);
            try names.put(cg.gpa, ip.stringSlice(in.name), .{ .reg = .{ .reg = reg, .size = sizeOf(in_size) } });
        } else if (std.mem.eql(u8, constraint, "m") or std.mem.eql(u8, constraint, "rm")) {
            // Only for templates that do not name the operand.
        } else if (regConstraint(constraint)) |reg_name| {
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
    // `=r` outputs get registers that no other operand uses.
    const out_regs = try cg.gpa.alloc(Reg, outputs.len);
    defer cg.gpa.free(out_regs);
    for (outputs, out_regs) |out, *out_reg| {
        const constraint = ip.stringSlice(out.constraint);
        if (std.mem.eql(u8, constraint, "=r")) {
            const ty = if (out.operand == .none) data.ty_pl.ty else Type.ptrInfo(ip, cg.typeOf(out.operand)).child;
            const reg = for ([_]Reg{ .rax, .rcx, .rdx, .rsi, .rdi, .r8, .r9, .r10, .r11 }) |r| {
                if (used & (@as(u16, 1) << @backingInt(r)) == 0) break r;
            } else return cg.fail("asm with too many register operands", .{});
            used |= @as(u16, 1) << @backingInt(reg);
            out_reg.* = reg;
            try names.put(cg.gpa, ip.stringSlice(out.name), .{ .reg = .{ .reg = reg, .size = sizeOf(Type.abiSize(ip, ty)) } });
            continue;
        }
        if (!std.mem.startsWith(u8, constraint, "=") or regConstraint(constraint[1..]) == null)
            return cg.fail("asm output constraint '{s}'", .{constraint});
        out_reg.* = (parseReg(regConstraint(constraint[1..]).?) orelse return cg.fail("unknown register in asm constraint '{s}'", .{constraint})).reg;
    }

    try cg.assemble(ip.stringSlice(extra.data.source), &names);

    for (outputs, out_regs) |out, reg| {
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

const AsmOperand = union(enum) {
    reg: ParsedReg,
    imm: i64,
    sym: struct { key: SymbolKey, off: i32 },
    /// A memory operand, optionally relative to the fs segment.
    mem: struct { mem: Mem, fs: bool = false },
};

fn assemble(cg: *CodeGen, source: []const u8, names: *const std.StringHashMapUnmanaged(AsmArg)) Error!void {
    var lines = std.mem.tokenizeAny(u8, source, "\n;");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '.') {
            // The only directive: std.start's `_start` marks the return
            // address undefined so unwinders stop at the outermost frame.
            if (std.mem.eql(u8, line, ".cfi_undefined %rip") or std.mem.eql(u8, line, ".cfi_undefined %%rip")) {
                cg.outermost_frame = true;
                continue;
            }
            return cg.fail("zap does not support the assembler directive '{s}' yet", .{line});
        }
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
            .reg => |r| .{ .reg = r },
        };
    }
    if (std.mem.indexOfScalar(u8, tok, '(') != null or std.mem.indexOfScalar(u8, tok, ':') != null) return cg.asmMemOperand(tok, names, line);
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

/// An AT&T memory operand: `%fs:disp`, `disp(%base)`, or
/// `disp(%base,%index,scale)`, where registers may be `%[name]` inputs.
fn asmMemOperand(cg: *CodeGen, tok: []const u8, names: *const std.StringHashMapUnmanaged(AsmArg), line: []const u8) Error!AsmOperand {
    var rest = tok;
    var fs = false;
    if (std.mem.startsWith(u8, rest, "%%fs:") or std.mem.startsWith(u8, rest, "%fs:")) {
        fs = true;
        rest = rest[std.mem.indexOfScalar(u8, rest, ':').? + 1 ..];
    }
    const open = std.mem.indexOfScalar(u8, rest, '(') orelse rest.len;
    const disp_text = rest[0..open];
    const disp: i32 = if (disp_text.len == 0) 0 else std.fmt.parseInt(i32, disp_text, 0) catch return cg.fail("bad asm memory operand '{s}' in '{s}'", .{ tok, line });
    var mem: Mem = .{ .disp = disp };
    if (open < rest.len) {
        if (rest[rest.len - 1] != ')') return cg.fail("bad asm memory operand '{s}' in '{s}'", .{ tok, line });
        var parts = std.mem.splitScalar(u8, rest[open + 1 .. rest.len - 1], ',');
        var k: usize = 0;
        while (parts.next()) |raw_part| : (k += 1) {
            const part = std.mem.trim(u8, raw_part, " \t");
            if (k == 2) {
                const scale = std.fmt.parseInt(u8, part, 10) catch return cg.fail("bad asm scale in '{s}'", .{line});
                mem.index.?.scale = switch (scale) {
                    1 => .@"1",
                    2 => .@"2",
                    4 => .@"4",
                    8 => .@"8",
                    else => return cg.fail("bad asm scale in '{s}'", .{line}),
                };
                continue;
            }
            if (part.len == 0) continue;
            const reg = switch (try cg.asmOperand(part, names, line)) {
                .reg => |r| r.reg,
                else => return cg.fail("bad asm memory operand '{s}' in '{s}'", .{ tok, line }),
            };
            if (k == 0) mem.base = .{ .reg = reg } else mem.index = .{ .reg = reg };
        }
    }
    return .{ .mem = .{ .mem = mem, .fs = fs } };
}

fn asmInst(cg: *CodeGen, mnemonic: []const u8, ops: []const AsmOperand, line: []const u8) Error!void {
    const e = &cg.e;
    const eql = std.mem.eql;
    // Memory operands of `mov`.
    if (ops.len == 2 and (ops[0] == .mem or ops[1] == .mem) and std.mem.startsWith(u8, mnemonic, "mov")) {
        const m = if (ops[0] == .mem) ops[0].mem else ops[1].mem;
        const other = if (ops[0] == .mem) ops[1] else ops[0];
        const suffix_size: ?Size = if (mnemonic.len == 4) switch (mnemonic[3]) {
            'b' => .byte,
            'w' => .word,
            'l' => .dword,
            'q' => .qword,
            else => null,
        } else null;
        if (m.fs) try e.raw(&.{0x64});
        switch (other) {
            .reg => |r| {
                const size = suffix_size orelse r.size;
                if (ops[0] == .mem) return e.mov(size, .{ .reg = r.reg }, .{ .mem = m.mem });
                return e.mov(size, .{ .mem = m.mem }, .{ .reg = r.reg });
            },
            .imm => |v| if (ops[1] == .mem) return e.mov(suffix_size orelse return cg.fail("asm 'mov' needs a size suffix: '{s}'", .{line}), .{ .mem = m.mem }, .{ .imm = v }),
            else => {},
        }
        return cg.fail("zap does not support this inline assembly instruction yet: '{s}'", .{line});
    }
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
            .imm, .mem => {},
        };
        if ((eql(u8, mnemonic, "push") or eql(u8, mnemonic, "pushq")) and ops[0] == .reg) return e.push(ops[0].reg.reg);
        if (ops[0] == .reg) {
            const unary_ops = [_]struct { []const u8, Encoder.UnaryOp }{
                .{ "div", .div }, .{ "idiv", .idiv }, .{ "mul", .mul }, .{ "neg", .neg }, .{ "not", .not },
            };
            for (unary_ops) |op| {
                const suffixed = mnemonic.len == op[0].len + 1 and std.mem.indexOfScalar(u8, "bwlq", mnemonic[op[0].len]) != null;
                if (std.mem.startsWith(u8, mnemonic, op[0]) and (mnemonic.len == op[0].len or suffixed))
                    return e.unary(op[1], ops[0].reg.size, .{ .reg = ops[0].reg.reg });
            }
        }
        if ((eql(u8, mnemonic, "pop") or eql(u8, mnemonic, "popq")) and ops[0] == .reg) return e.pop(ops[0].reg.reg);
    } else if (ops[1] == .reg) {
        // AT&T order: source, destination.
        const dst = ops[1].reg;
        // A size suffix, unless it is part of the name (`shl`, `sub`).
        const known = [_][]const u8{ "mov", "add", "or", "and", "sub", "xor", "cmp", "rol", "ror", "shl", "sal", "shr", "sar", "xchg" };
        const base = for (known) |k| {
            if (mnemonic.len == k.len + 1 and std.mem.startsWith(u8, mnemonic, k) and std.mem.indexOfScalar(u8, "bwlq", mnemonic[k.len]) != null) break k;
        } else mnemonic;
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
            .sym, .mem => return cg.fail("symbol or memory operand in '{s}'", .{line}),
        };
        if (eql(u8, base, "mov") or eql(u8, mnemonic, "movabs")) return e.mov(size, .{ .reg = dst.reg }, src);
        const alu_ops = [_]struct { []const u8, Encoder.AluOp }{
            .{ "add", .add }, .{ "or", .@"or" }, .{ "and", .@"and" }, .{ "sub", .sub }, .{ "xor", .xor }, .{ "cmp", .cmp },
        };
        for (alu_ops) |op| if (eql(u8, base, op[0])) return e.alu(op[1], size, .{ .reg = dst.reg }, src);
        const shift_ops = [_]struct { []const u8, Encoder.ShiftOp }{
            .{ "rol", .rol }, .{ "ror", .ror }, .{ "shl", .shl }, .{ "sal", .shl }, .{ "shr", .shr }, .{ "sar", .sar },
        };
        for (shift_ops) |op| if (eql(u8, base, op[0])) switch (ops[0]) {
            .imm => |v| return e.shift(op[1], size, .{ .reg = dst.reg }, @truncate(@as(u64, @bitCast(v)))),
            .reg => |r| if (r.reg == .rcx) return e.shift(op[1], size, .{ .reg = dst.reg }, null),
            .sym, .mem => {},
        };
        if (eql(u8, base, "xchg") and ops[0] == .reg) return e.xchg(size, .{ .reg = dst.reg }, ops[0].reg.reg);
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
                .vector_type => |v| if (base_ty.flags.size == .one) v.child else base_ty.child,
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
        .float => |f| {
            // f80 has 10 bytes of data in its 16-byte slot.
            @memset(out, 0);
            var bytes: [16]u8 = undefined;
            std.mem.writeInt(u128, &bytes, f.bits(), .little);
            const n = Type.floatBits(ip, ty) / 8;
            @memcpy(out[0..n], bytes[0..n]);
        },
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
                .vector_type => |vt| for (0..vt.len) |i| {
                    const el = switch (a.storage) {
                        .elems => |elems| elems[i],
                        .repeated_elem => |el| el,
                        .bytes => |b| break @memcpy(out[0..vt.len], ip.stringSlice(b)[0..vt.len]),
                    };
                    if (vt.child == .bool_type) {
                        if (el == .bool_true) out[i / 8] |= @as(u8, 1) << @intCast(i % 8);
                        continue;
                    }
                    const esize = Type.abiSize(ip, vt.child);
                    const off: u32 = @intCast(i * esize);
                    try lowerValue(emit, el, out[off..][0..esize], relocs, base_off + off);
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

// ---------------------------------------------------------------------------
// Numerics
//
// f32 and f64 use scalar SSE. f16, f80, and f128 arithmetic, the float
// operations SSE2 lacks (rounding, fmod, transcendental functions, fma),
// and conversions that SSE2 cannot do call compiler_rt helpers by their
// declaration, which `Zcu` analyzes lazily (see `rtCall`). Helpers use
// libm's names: `__sinh` (f16), `sinf`, `sin`, `__sinx` (f80), `sinq`.

/// A value as an operand: its type and where it can be read.
const Val = struct { ty: Index, loc: Loc };

fn valOf(cg: *CodeGen, ref: Ref) Error!Val {
    return .{ .ty = cg.typeOf(ref), .loc = try cg.locOf(ref) };
}

fn memVal(ty: Index, m: Mem) Val {
    return .{ .ty = ty, .loc = .{ .mem = m } };
}

fn loadVal(cg: *CodeGen, reg: Reg, v: Val) Error!void {
    switch (v.loc) {
        .none => try cg.e.mov(.dword, .{ .reg = reg }, .{ .imm = 0 }),
        .imm => |x| try cg.e.mov(.qword, .{ .reg = reg }, .{ .imm = @bitCast(x) }),
        .addr => |m| try cg.e.lea(.qword, reg, m),
        .err => |name| try cg.loadError(reg, name),
        .mem => |m| try cg.loadMem(reg, m, v.ty),
    }
}

/// The memory holding `v`, materializing a register-only value into a
/// scratch slot. Uses rax.
fn valMem(cg: *CodeGen, v: Val) Error!Mem {
    if (v.loc == .mem) return v.loc.mem;
    const size = Type.abiSize(cg.ip, v.ty);
    const m = Mem.at(.rbp, try cg.allocSlot(size, Type.abiAlignment(cg.ip, v.ty)));
    if (v.loc == .imm and !cg.passInRegs(v.ty)) {
        try cg.fillMem(m, size, 0xaa);
    } else {
        try cg.loadVal(.rax, v);
        try cg.storeReg(m, .rax, size);
    }
    return m;
}

/// Loads a value of 2, 4, 8, or 16 bytes into the low bits of `x`. Uses rax.
fn loadXmm(cg: *CodeGen, x: Encoder.Xmm, v: Val) Error!void {
    const size = Type.abiSize(cg.ip, v.ty);
    if (size == 16) return cg.e.movups(.{ .reg = x }, .{ .mem = try cg.valMem(v) });
    if (v.loc == .mem and size != 2) return cg.e.movs(if (size == 4) .f32 else .f64, .{ .reg = x }, .{ .mem = v.loc.mem });
    try cg.loadVal(.rax, v);
    try cg.e.movToXmm(if (size == 8) .qword else .dword, x, .{ .reg = .rax });
}

/// Stores the low `size` bytes of `x`. Uses rax.
fn storeXmm(cg: *CodeGen, dst: Mem, x: Encoder.Xmm, size: u64) Error!void {
    switch (size) {
        4 => try cg.e.movs(.f32, .{ .mem = dst }, .{ .reg = x }),
        8 => try cg.e.movs(.f64, .{ .mem = dst }, .{ .reg = x }),
        16 => try cg.e.movups(.{ .mem = dst }, .{ .reg = x }),
        else => {
            try cg.e.movFromXmm(.dword, .{ .reg = .rax }, x);
            try cg.storeReg(dst, .rax, size);
        },
    }
}

// ---------------------------------------------------------------- C calls

/// SysV classes of the values zap passes to and from C functions: scalars,
/// 16-byte integers (two GPRs), and anything else in memory.
const CClass = enum { none, int, int_pair, sse, x87, memory };

fn cClass(cg: *CodeGen, ty: Index) CClass {
    const ip = cg.ip;
    if (!Type.hasRuntimeBits(ip, ty)) return .none;
    if (Type.class(ip, ty) == .float) return if (Type.floatBits(ip, ty) == 80) .x87 else .sse;
    if (cg.passInRegs(ty)) return .int;
    if (Type.isInt(ip, ty) and Type.abiSize(ip, ty) == 16) return .int_pair;
    return .memory;
}

const xmm_args = [_]Encoder.Xmm{ .xmm0, .xmm1, .xmm2, .xmm3, .xmm4, .xmm5, .xmm6, .xmm7 };

const CArgLoc = union(enum) { none, gp: u8, sse: u8, stack: u32 };

/// Places the arguments of a call to a C function: memory arguments in the
/// outgoing area first (copies use rax, rsi, rdi, rcx), then SSE registers
/// (rax), then GPRs. A result returned in memory goes to `dst`, passed in rdi.
fn cCallArgs(cg: *CodeGen, args: []const Val, ret_ty: Index, dst: ?Mem) Error!void {
    const ip = cg.ip;
    const locs = try cg.gpa.alloc(CArgLoc, args.len);
    defer cg.gpa.free(locs);
    const sret = dst != null and cg.cClass(ret_ty) == .memory;
    var gp: u8 = @intFromBool(sret);
    var sse: u8 = 0;
    var stack: u32 = 0;
    for (args, locs) |a, *l| {
        const class = cg.cClass(a.ty);
        l.* = switch (class) {
            .none => .none,
            .int => if (gp < 6) blk: {
                gp += 1;
                break :blk .{ .gp = gp - 1 };
            } else .{ .stack = 0 },
            .int_pair => if (gp < 5) blk: {
                gp += 2;
                break :blk .{ .gp = gp - 2 };
            } else .{ .stack = 0 },
            .sse => if (sse < 8) blk: {
                sse += 1;
                break :blk .{ .sse = sse - 1 };
            } else .{ .stack = 0 },
            .x87, .memory => .{ .stack = 0 },
        };
        if (l.* == .stack) {
            stack = std.mem.alignForward(u32, stack, if (Type.abiAlignment(ip, a.ty) >= 16) 16 else 8);
            l.* = .{ .stack = stack };
            stack += @intCast(std.mem.alignForward(u64, Type.abiSize(ip, a.ty), 8));
        }
    }
    cg.out_args_size = @max(cg.out_args_size, stack);
    for (args, locs) |a, l| if (l == .stack) {
        try cg.copyMem(Mem.at(.rsp, @intCast(l.stack)), try cg.valMem(a), Type.abiSize(ip, a.ty));
    };
    for (args, locs) |a, l| if (l == .sse) try cg.loadXmm(xmm_args[l.sse], a);
    for (args, locs) |a, l| if (l == .gp) {
        if (cg.cClass(a.ty) == .int_pair) {
            const m = try cg.valMem(a);
            try cg.e.mov(.qword, .{ .reg = c_arg_regs[l.gp] }, .{ .mem = m });
            try cg.e.mov(.qword, .{ .reg = c_arg_regs[l.gp + 1] }, .{ .mem = offsetMem(m, 8) });
        } else {
            try cg.loadVal(c_arg_regs[l.gp], a);
        }
    };
    if (sret) try cg.e.lea(.qword, .rdi, dst.?);
}

/// Stores the result of a C call, of type `ret_ty`, to `dst`.
fn cCallResult(cg: *CodeGen, ret_ty: Index, dst: ?Mem) Error!void {
    const m = dst orelse return;
    switch (cg.cClass(ret_ty)) {
        .none, .memory => {},
        .int => try cg.storeReg(m, .rax, Type.abiSize(cg.ip, ret_ty)),
        .int_pair => {
            try cg.e.mov(.qword, .{ .mem = m }, .{ .reg = .rax });
            try cg.e.mov(.qword, .{ .mem = offsetMem(m, 8) }, .{ .reg = .rdx });
        },
        .sse => try cg.storeXmm(m, .xmm0, Type.abiSize(cg.ip, ret_ty)),
        .x87 => try cg.e.fstp(.m80, m),
    }
}

/// The callee side of the C convention: gives each `arg` a home, spilling
/// register arguments to slots.
fn setupCParams(cg: *CodeGen) Error!void {
    const ip = cg.ip;
    var gp: u8 = 0;
    if (cg.cClass(cg.fn_ty.return_type) == .memory) {
        const off = try cg.allocSlot(8, 8);
        try cg.e.mov(.qword, .{ .mem = Mem.at(.rbp, off) }, .{ .reg = .rdi });
        cg.ret_ptr_slot = off;
        gp = 1;
    }
    var sse: u8 = 0;
    var stack: u32 = 0;
    for (cg.ir.mainBody()) |inst| {
        if (cg.ir.instructions.items(.tag)[@backingInt(inst)] != .arg) break;
        const ty = cg.ir.instructions.items(.data)[@backingInt(inst)].arg.ty;
        const size = Type.abiSize(ip, ty);
        const in_reg = switch (cg.cClass(ty)) {
            .none => continue,
            .int => gp < 6,
            .int_pair => gp < 5,
            .sse => sse < 8,
            .x87, .memory => false,
        };
        if (!in_reg) {
            stack = std.mem.alignForward(u32, stack, if (Type.abiAlignment(ip, ty) >= 16) 16 else 8);
            cg.homes[@backingInt(inst)] = .{ .slot = @intCast(16 + stack) };
            stack += @intCast(std.mem.alignForward(u64, size, 8));
            continue;
        }
        const m = Mem.at(.rbp, try cg.allocSlot(size, Type.abiAlignment(ip, ty)));
        cg.homes[@backingInt(inst)] = .{ .slot = m.disp };
        switch (cg.cClass(ty)) {
            .int => {
                try cg.storeReg(m, c_arg_regs[gp], size);
                gp += 1;
            },
            .int_pair => {
                try cg.e.mov(.qword, .{ .mem = m }, .{ .reg = c_arg_regs[gp] });
                try cg.e.mov(.qword, .{ .mem = offsetMem(m, 8) }, .{ .reg = c_arg_regs[gp + 1] });
                gp += 2;
            },
            .sse => {
                try cg.storeXmm(m, xmm_args[sse], size);
                sse += 1;
            },
            else => unreachable,
        }
    }
}

/// Returns `operand` from a C-convention function.
fn cRet(cg: *CodeGen, operand: Ref) Error!void {
    const ty = cg.fn_ty.return_type;
    switch (cg.cClass(ty)) {
        .none => {},
        .int => try cg.load(.rax, operand),
        .int_pair => {
            const m = try cg.memOf(operand);
            try cg.e.mov(.qword, .{ .reg = .rax }, .{ .mem = m });
            try cg.e.mov(.qword, .{ .reg = .rdx }, .{ .mem = offsetMem(m, 8) });
        },
        .sse => try cg.loadXmm(.xmm0, try cg.valOf(operand)),
        .x87 => try cg.e.fld(.m80, try cg.memOf(operand)),
        .memory => {
            try cg.e.mov(.qword, .{ .reg = .r10 }, .{ .mem = Mem.at(.rbp, cg.ret_ptr_slot.?) });
            try cg.copyTo(Mem.at(.r10, 0), operand);
            try cg.e.mov(.qword, .{ .reg = .rax }, .{ .mem = Mem.at(.rbp, cg.ret_ptr_slot.?) });
        },
    }
}

/// Calls the compiler_rt function `name`, declared in
/// `lib/compiler_rt/<file>`, with the C convention. Its symbol is the key of
/// its function unit, which `Zcu` resolves and queues for analysis.
/// Calls `name(dst, u, v, bits)`, one of compiler_rt's division helpers for
/// integers of `ty`. The signed helpers clobber `u` and `v`, so they get
/// copies.
fn divEi4(cg: *CodeGen, file: []const u8, name: []const u8, dst: Mem, u: Mem, v: Mem, ty: Index) Error!void {
    const key: SymbolKey = .fromName(try cg.emit.zcu.requestCompilerRt(file, name));
    var u_arg = u;
    var v_arg = v;
    if (cg.signed(ty)) {
        const size = Type.abiSize(cg.ip, ty);
        u_arg = Mem.at(.rbp, try cg.allocSlot(size, 16));
        v_arg = Mem.at(.rbp, try cg.allocSlot(size, 16));
        try cg.copyMem(u_arg, u, size);
        try cg.copyMem(v_arg, v, size);
    }
    try cg.e.lea(.qword, .rdi, dst);
    try cg.e.lea(.qword, .rsi, u_arg);
    try cg.e.lea(.qword, .rdx, v_arg);
    try cg.e.mov(.qword, .{ .reg = .rcx }, .{ .imm = Type.intInfo(cg.ip, ty).bits });
    try cg.e.call(.{ .sym = key });
}

fn rtCall(cg: *CodeGen, file: []const u8, name: []const u8, args: []const Val, ret_ty: Index, dst: ?Mem) Error!void {
    const key: SymbolKey = .fromName(try cg.emit.zcu.requestCompilerRt(file, name));
    try cg.cCallArgs(args, ret_ty, dst);
    try cg.e.call(.{ .sym = key });
    try cg.cCallResult(ret_ty, dst);
}

// ---------------------------------------------------------------- floats

fn isFloat(cg: *CodeGen, ty: Index) bool {
    return Type.class(cg.ip, ty) == .float;
}

/// The SSE type of f32 and f64; other floats go through compiler_rt.
fn sseType(cg: *CodeGen, ty: Index) ?Encoder.Float {
    return switch (Type.floatBits(cg.ip, ty)) {
        32 => .f32,
        64 => .f64,
        else => null,
    };
}

/// libm's name for operation `op` on floats of `bits` bits.
fn libmName(cg: *CodeGen, op: []const u8, bits: u16) Error![]const u8 {
    const arena = cg.emit.allocator();
    return switch (bits) {
        16 => std.fmt.allocPrint(arena, "__{s}h", .{op}),
        32 => std.fmt.allocPrint(arena, "{s}f", .{op}),
        64 => op,
        80 => std.fmt.allocPrint(arena, "__{s}x", .{op}),
        128 => std.fmt.allocPrint(arena, "{s}q", .{op}),
        else => unreachable,
    };
}

/// compiler_rt's abbreviation of a float type in helper names.
fn rtFloatAbbrev(bits: u16) []const u8 {
    return switch (bits) {
        16 => "hf",
        32 => "sf",
        64 => "df",
        80 => "xf",
        128 => "tf",
        else => unreachable,
    };
}

/// Calls libm-style compiler_rt function `op` (in `file`, default
/// `<op>.zig`) on operands of float type `ty`.
fn libmCall(cg: *CodeGen, op: []const u8, file: ?[]const u8, ty: Index, args: []const Val, dst: Mem) Error!void {
    const f = file orelse try std.fmt.allocPrint(cg.emit.allocator(), "{s}.zig", .{op});
    try cg.rtCall(f, try cg.libmName(op, Type.floatBits(cg.ip, ty)), args, ty, dst);
}

fn floatArith(cg: *CodeGen, tag: Inst.Tag, ty: Index, lhs: Val, rhs: Val, dst: Mem) Error!void {
    if (cg.sseType(ty)) |ft| {
        try cg.loadXmm(.xmm0, lhs);
        try cg.loadXmm(.xmm1, rhs);
        try cg.e.sse(switch (tag) {
            .add_float => .add,
            .sub_float => .sub,
            .mul_float => .mul,
            .div_float => .div,
            else => unreachable,
        }, ft, .xmm0, .{ .reg = .xmm1 });
        return cg.storeXmm(dst, .xmm0, Type.abiSize(cg.ip, ty));
    }
    const bits = Type.floatBits(cg.ip, ty);
    if (bits == 80) {
        // x87, as upstream: f80 is its native format.
        try cg.e.fld(.m80, try cg.valMem(lhs));
        try cg.e.fld(.m80, try cg.valMem(rhs));
        try cg.e.x87ArithPop(switch (tag) {
            .add_float => .add,
            .sub_float => .sub,
            .mul_float => .mul,
            .div_float => .div,
            else => unreachable,
        });
        return cg.e.fstp(.m80, dst);
    }
    const op: []const u8, const file: []const u8 = switch (tag) {
        .add_float => .{ "add", "addf3.zig" },
        .sub_float => .{ "sub", "addf3.zig" },
        .mul_float => .{ "mul", "mulf3.zig" },
        .div_float => .{ "div", switch (bits) {
            16 => "divsf3.zig",
            80 => "divxf3.zig",
            else => "divtf3.zig",
        } },
        else => unreachable,
    };
    const name = try std.fmt.allocPrint(cg.emit.allocator(), "__{s}{s}3", .{ op, rtFloatAbbrev(bits) });
    try cg.rtCall(file, name, &.{ lhs, rhs }, ty, dst);
}

/// Instructions on floats.
fn genFloat(cg: *CodeGen, inst: Inst.Index, tag: Inst.Tag, data: Inst.Data) Error!void {
    const ip = cg.ip;
    switch (tag) {
        .add_float, .sub_float, .mul_float, .div_float => {
            const ty = cg.typeOf(data.bin_op.lhs);
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.floatArith(tag, ty, try cg.valOf(data.bin_op.lhs), try cg.valOf(data.bin_op.rhs), dst);
        },
        .div_trunc, .div_floor, .div_ceil => {
            const ty = cg.typeOf(data.bin_op.lhs);
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.floatArith(.div_float, ty, try cg.valOf(data.bin_op.lhs), try cg.valOf(data.bin_op.rhs), dst);
            const op: []const u8 = switch (tag) {
                .div_trunc => "trunc",
                .div_floor => "floor",
                else => "ceil",
            };
            try cg.libmCall(op, if (tag == .div_trunc) "trunc.zig" else "floor_ceil.zig", ty, &.{memVal(ty, dst)}, dst);
        },
        .rem, .mod => {
            const ty = cg.typeOf(data.bin_op.lhs);
            const dst = try cg.resultMem(inst, ty) orelse return;
            const rhs = try cg.valOf(data.bin_op.rhs);
            try cg.libmCall("fmod", null, ty, &.{ try cg.valOf(data.bin_op.lhs), rhs }, dst);
            if (tag == .rem) return;
            // As upstream: a non-zero remainder whose sign differs from the
            // divisor's gets the divisor added.
            const done = try cg.e.newLabel();
            const rhs_m = try cg.valMem(rhs);
            const top: u64 = (Type.floatBits(ip, ty) - 1) / 8;
            try cg.e.mov(.byte, .{ .reg = .rax }, .{ .mem = offsetMem(dst, top) });
            try cg.e.alu(.xor, .byte, .{ .reg = .rax }, .{ .mem = offsetMem(rhs_m, top) });
            try cg.e.jcc(.ns, .{ .label = done });
            try cg.floatMagnitudeTest(dst, Type.floatBits(ip, ty));
            try cg.e.jcc(.e, .{ .label = done });
            try cg.floatArith(.add_float, ty, memVal(ty, dst), memVal(ty, rhs_m), dst);
            cg.e.bind(done);
        },
        .min_float, .max_float => {
            const ty = cg.typeOf(data.bin_op.lhs);
            const dst = try cg.resultMem(inst, ty) orelse return;
            const lhs = try cg.valOf(data.bin_op.lhs);
            const rhs = try cg.valOf(data.bin_op.rhs);
            if (cg.sseType(ty)) |ft| {
                // minss/maxss return the second operand if either is NaN.
                try cg.loadXmm(.xmm0, lhs);
                try cg.loadXmm(.xmm1, rhs);
                const done = try cg.e.newLabel();
                try cg.e.ucomis(ft, .xmm1, .{ .reg = .xmm1 });
                try cg.e.jcc(.p, .{ .label = done });
                try cg.e.sse(if (tag == .min_float) .min else .max, ft, .xmm0, .{ .reg = .xmm1 });
                cg.e.bind(done);
                return cg.storeXmm(dst, .xmm0, Type.abiSize(ip, ty));
            }
            try cg.libmCall(if (tag == .min_float) "fmin" else "fmax", null, ty, &.{ lhs, rhs }, dst);
        },
        .neg_float, .abs_float => {
            const ty = cg.typeOf(data.un_op);
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.copyTo(dst, data.un_op);
            const top: u64 = (Type.floatBits(ip, ty) - 1) / 8;
            if (tag == .neg_float) {
                try cg.e.alu(.xor, .byte, .{ .mem = offsetMem(dst, top) }, .{ .imm = -0x80 });
            } else {
                try cg.e.alu(.@"and", .byte, .{ .mem = offsetMem(dst, top) }, .{ .imm = 0x7f });
            }
        },
        .sqrt, .sin, .cos, .tan, .exp, .exp2, .log, .log2, .log10, .floor, .ceil, .round, .trunc_float => {
            const ty = cg.typeOf(data.un_op);
            const dst = try cg.resultMem(inst, ty) orelse return;
            const operand = try cg.valOf(data.un_op);
            if (tag == .sqrt) if (cg.sseType(ty)) |ft| {
                try cg.loadXmm(.xmm0, operand);
                try cg.e.sse(.sqrt, ft, .xmm0, .{ .reg = .xmm0 });
                return cg.storeXmm(dst, .xmm0, Type.abiSize(ip, ty));
            } else if (Type.floatBits(ip, ty) == 80) {
                try cg.e.fld(.m80, try cg.valMem(operand));
                try cg.e.fsqrt();
                return cg.e.fstp(.m80, dst);
            };
            const op: []const u8 = if (tag == .trunc_float) "trunc" else @tagName(tag);
            const file: ?[]const u8 = if (tag == .floor or tag == .ceil) "floor_ceil.zig" else null;
            try cg.libmCall(op, file, ty, &.{operand}, dst);
        },
        .mul_add => {
            const ty = cg.typeOf(data.pl_op.operand);
            const dst = try cg.resultMem(inst, ty) orelse return;
            const bin = cg.ir.extraData(Ir.Bin, data.pl_op.payload).data;
            try cg.libmCall("fma", null, ty, &.{ try cg.valOf(bin.lhs), try cg.valOf(bin.rhs), try cg.valOf(data.pl_op.operand) }, dst);
        },
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => {
            const dst = try cg.resultMem(inst, .bool_type) orelse return;
            const ty = cg.typeOf(data.bin_op.lhs);
            const lhs = try cg.valOf(data.bin_op.lhs);
            const rhs = try cg.valOf(data.bin_op.rhs);
            if (cg.sseType(ty) != null or Type.floatBits(ip, ty) == 80) {
                // Unordered sets ZF, PF, and CF: `a`/`ae` are false for NaN,
                // so `<` and `<=` compare the swapped operands.
                const swap = tag == .cmp_lt or tag == .cmp_lte;
                const a = if (swap) rhs else lhs;
                const b = if (swap) lhs else rhs;
                if (cg.sseType(ty)) |ft| {
                    try cg.loadXmm(.xmm0, a);
                    try cg.loadXmm(.xmm1, b);
                    try cg.e.ucomis(ft, .xmm0, .{ .reg = .xmm1 });
                } else {
                    try cg.e.fld(.m80, try cg.valMem(b));
                    try cg.e.fld(.m80, try cg.valMem(a));
                    try cg.e.fucomip();
                    try cg.e.fpop();
                }
                switch (tag) {
                    .cmp_lt, .cmp_gt => try cg.e.setcc(.a, .{ .mem = dst }),
                    .cmp_lte, .cmp_gte => try cg.e.setcc(.ae, .{ .mem = dst }),
                    .cmp_eq, .cmp_neq => {
                        const eq = tag == .cmp_eq;
                        try cg.e.setcc(if (eq) .e else .ne, .{ .reg = .rax });
                        try cg.e.setcc(if (eq) .np else .p, .{ .reg = .rcx });
                        try cg.e.alu(if (eq) .@"and" else .@"or", .byte, .{ .reg = .rax }, .{ .reg = .rcx });
                        try cg.storeReg(dst, .rax, 1);
                    },
                    else => unreachable,
                }
                return;
            }
            // `__cmp*f2` is 1 for unordered operands and `__ge*f2` is -1, so
            // each comparison is false for NaN.
            const bits = Type.floatBits(ip, ty);
            const ge = tag == .cmp_gt or tag == .cmp_gte;
            const name = try std.fmt.allocPrint(cg.emit.allocator(), "__{s}{s}2", .{ if (ge) "ge" else "cmp", rtFloatAbbrev(bits) });
            const res = Mem.at(.rbp, try cg.allocSlot(4, 4));
            try cg.rtCall("comparef.zig", name, &.{ lhs, rhs }, .i32_type, res);
            try cg.e.alu(.cmp, .dword, .{ .mem = res }, .{ .imm = 0 });
            try cg.e.setcc(switch (tag) {
                .cmp_lt => .l,
                .cmp_lte => .le,
                .cmp_eq => .e,
                .cmp_neq => .ne,
                .cmp_gt => .g,
                .cmp_gte => .ge,
                else => unreachable,
            }, .{ .mem = dst });
        },
        .float_cast => {
            const ty = data.ty_op.ty;
            const dst = try cg.resultMem(inst, ty) orelse return;
            const src_ty = cg.typeOf(data.ty_op.operand);
            const operand = try cg.valOf(data.ty_op.operand);
            const from = Type.floatBits(ip, src_ty);
            const to = Type.floatBits(ip, ty);
            if (from == to) return cg.copyTo(dst, data.ty_op.operand);
            if (cg.sseType(ty) != null and cg.sseType(src_ty) != null) {
                try cg.loadXmm(.xmm0, operand);
                try cg.e.cvts2s(cg.sseType(ty).?, .xmm0, .{ .reg = .xmm0 });
                return cg.storeXmm(dst, .xmm0, Type.abiSize(ip, ty));
            }
            // Between f80 and f32 or f64: x87 loads and stores convert.
            const x87_mem = struct {
                fn f(bits: u16) ?Encoder.X87Mem {
                    return switch (bits) {
                        32 => .m32,
                        64 => .m64,
                        80 => .m80,
                        else => null,
                    };
                }
            }.f;
            if ((from == 80 or to == 80) and x87_mem(from) != null and x87_mem(to) != null) {
                try cg.e.fld(x87_mem(from).?, try cg.valMem(operand));
                return cg.e.fstp(x87_mem(to).?, dst);
            }
            const widen = to > from;
            const name = try std.fmt.allocPrint(cg.emit.allocator(), "__{s}{s}{s}2", .{ if (widen) "extend" else "trunc", rtFloatAbbrev(from), rtFloatAbbrev(to) });
            try cg.rtCall(if (widen) "extendf.zig" else "truncf.zig", name, &.{operand}, ty, dst);
        },
        .float_from_int => try cg.floatFromInt(inst, data),
        .int_from_float => try cg.intFromFloat(inst, data),
        else => unreachable,
    }
}

/// Sets ZF iff the float at `m` (of `bits` bits) is a zero of either sign.
/// Uses rax and rcx.
fn floatMagnitudeTest(cg: *CodeGen, m: Mem, bits: u16) Error!void {
    const e = &cg.e;
    switch (bits) {
        16, 32, 64 => {
            try cg.loadMem(.rax, m, switch (bits) {
                16 => .u16_type,
                32 => .u32_type,
                else => .u64_type,
            });
            try e.shift(.shl, .qword, .{ .reg = .rax }, @intCast(65 - bits));
        },
        80 => {
            try e.movzx(.dword, .rax, .word, .{ .mem = offsetMem(m, 8) });
            try e.shift(.shl, .dword, .{ .reg = .rax }, 17);
            try e.alu(.@"or", .qword, .{ .reg = .rax }, .{ .mem = m });
        },
        128 => {
            try e.mov(.qword, .{ .reg = .rax }, .{ .mem = offsetMem(m, 8) });
            try e.shift(.shl, .qword, .{ .reg = .rax }, 1);
            try e.alu(.@"or", .qword, .{ .reg = .rax }, .{ .mem = m });
        },
        else => unreachable,
    }
}

/// compiler_rt's abbreviation of an integer of `bits` bits, widened to the
/// next helper width.
fn rtIntAbbrev(bits: u16) ?[]const u8 {
    if (bits <= 32) return "si";
    if (bits <= 64) return "di";
    if (bits <= 128) return "ti";
    return null;
}

fn rtIntType(bits: u16, signedness: std.lang.Signedness) Index {
    const s = signedness == .signed;
    if (bits <= 32) return if (s) .i32_type else .u32_type;
    if (bits <= 64) return if (s) .i64_type else .u64_type;
    return if (s) .i128_type else .u128_type;
}

fn floatFromInt(cg: *CodeGen, inst: Inst.Index, data: Inst.Data) Error!void {
    const ip = cg.ip;
    const ty = data.ty_op.ty;
    const dst = try cg.resultMem(inst, ty) orelse return;
    const int_ty = cg.typeOf(data.ty_op.operand);
    const info = Type.intInfo(ip, int_ty);
    const operand = try cg.valOf(data.ty_op.operand);
    if (cg.sseType(ty)) |ft| if (info.bits <= 64) {
        const e = &cg.e;
        try cg.loadVal(.rax, operand);
        if (info.bits == 64 and info.signedness == .unsigned) {
            // Halve values with the top bit set, keeping the low bit for
            // rounding, and double the result.
            const big = try e.newLabel();
            const done = try e.newLabel();
            try e.@"test"(.qword, .{ .reg = .rax }, .{ .reg = .rax });
            try e.jcc(.s, .{ .label = big });
            try e.cvtsi2s(ft, .xmm0, .qword, .{ .reg = .rax });
            try e.jmp(.{ .label = done });
            e.bind(big);
            try e.mov(.qword, .{ .reg = .rcx }, .{ .reg = .rax });
            try e.shift(.shr, .qword, .{ .reg = .rcx }, 1);
            try e.alu(.@"and", .dword, .{ .reg = .rax }, .{ .imm = 1 });
            try e.alu(.@"or", .qword, .{ .reg = .rcx }, .{ .reg = .rax });
            try e.cvtsi2s(ft, .xmm0, .qword, .{ .reg = .rcx });
            try e.sse(.add, ft, .xmm0, .{ .reg = .xmm0 });
            e.bind(done);
        } else {
            try e.cvtsi2s(ft, .xmm0, .qword, .{ .reg = .rax });
        }
        return cg.storeXmm(dst, .xmm0, Type.abiSize(ip, ty));
    };
    const abbrev = rtIntAbbrev(info.bits) orelse return cg.fail("converting {d}-bit integers to floats", .{info.bits});
    const name = try std.fmt.allocPrint(cg.emit.allocator(), "__float{s}{s}{s}", .{ if (info.signedness == .unsigned) "un" else "", abbrev, rtFloatAbbrev(Type.floatBits(ip, ty)) });
    // Loading the operand extends it to the helper's width.
    try cg.rtCall("float_from_int.zig", name, &.{operand}, ty, dst);
}

fn intFromFloat(cg: *CodeGen, inst: Inst.Index, data: Inst.Data) Error!void {
    const ip = cg.ip;
    const ty = data.ty_op.ty;
    const dst = try cg.resultMem(inst, ty) orelse return;
    const float_ty = cg.typeOf(data.ty_op.operand);
    const info = Type.intInfo(ip, ty);
    const operand = try cg.valOf(data.ty_op.operand);
    const size = Type.abiSize(ip, ty);
    if (cg.sseType(float_ty)) |ft| if (info.bits <= 64) {
        const e = &cg.e;
        try cg.loadXmm(.xmm0, operand);
        if (info.bits == 64 and info.signedness == .unsigned) {
            // Values from 2^63 convert after subtracting 2^63.
            const big = try e.newLabel();
            const done = try e.newLabel();
            const two63: u64 = if (ft == .f32) @as(u32, @bitCast(@as(f32, 0x1p63))) else @bitCast(@as(f64, 0x1p63));
            try e.mov(.qword, .{ .reg = .rax }, .{ .imm = @bitCast(two63) });
            try e.movToXmm(if (ft == .f32) .dword else .qword, .xmm1, .{ .reg = .rax });
            try e.ucomis(ft, .xmm0, .{ .reg = .xmm1 });
            try e.jcc(.ae, .{ .label = big });
            try e.cvtts2si(ft, .qword, .rax, .{ .reg = .xmm0 });
            try e.jmp(.{ .label = done });
            e.bind(big);
            try e.sse(.sub, ft, .xmm0, .{ .reg = .xmm1 });
            try e.cvtts2si(ft, .qword, .rax, .{ .reg = .xmm0 });
            try e.mov(.qword, .{ .reg = .rcx }, .{ .imm = std.math.minInt(i64) });
            try e.alu(.xor, .qword, .{ .reg = .rax }, .{ .reg = .rcx });
            e.bind(done);
        } else {
            try e.cvtts2si(ft, .qword, .rax, .{ .reg = .xmm0 });
        }
        return cg.storeReg(dst, .rax, size);
    };
    const abbrev = rtIntAbbrev(info.bits) orelse return cg.fail("converting floats to {d}-bit integers", .{info.bits});
    const name = try std.fmt.allocPrint(cg.emit.allocator(), "__fix{s}{s}{s}", .{ if (info.signedness == .unsigned) "uns" else "", rtFloatAbbrev(Type.floatBits(ip, float_ty)), abbrev });
    const rt_ty = rtIntType(info.bits, info.signedness);
    if (Type.abiSize(ip, rt_ty) == size) return cg.rtCall("int_from_float.zig", name, &.{operand}, rt_ty, dst);
    // A narrower result: the value fits, so its low bytes are normalized.
    const tmp = Mem.at(.rbp, try cg.allocSlot(Type.abiSize(ip, rt_ty), Type.abiAlignment(ip, rt_ty)));
    try cg.rtCall("int_from_float.zig", name, &.{operand}, rt_ty, tmp);
    try cg.copyMem(dst, tmp, size);
}

// ---------------------------------------------------------------- wide integers
//
// Integers wider than 64 bits live in memory as little-endian 64-bit limbs,
// `abiSize / 8` of them, normalized like narrow integers: the bits above
// the type's width are copies of the sign bit (signed) or zero. Operations
// run limb by limb in rax, rcx, and rdx.

fn isWideInt(cg: *CodeGen, ty: Index) bool {
    return Type.isInt(cg.ip, ty) and Type.abiSize(cg.ip, ty) > 8;
}

fn limbCount(cg: *CodeGen, ty: Index) u32 {
    return @intCast(Type.abiSize(cg.ip, ty) / 8);
}

fn limb(m: Mem, i: u32) Mem {
    return offsetMem(m, @as(u64, i) * 8);
}

/// Loads limb `i` of integer `v` into `reg`; limbs past `v`'s own are its
/// extension. Does not change the flags when `v` is in memory and `i` is
/// one of its limbs.
fn loadLimb(cg: *CodeGen, reg: Reg, v: Val, i: u32) Error!void {
    const n = if (cg.passInRegs(v.ty)) 1 else cg.limbCount(v.ty);
    if (i < n) {
        if (n == 1) return cg.loadVal(reg, v);
        return cg.e.mov(.qword, .{ .reg = reg }, .{ .mem = limb(v.loc.mem, i) });
    }
    if (!cg.signed(v.ty)) return cg.e.mov(.dword, .{ .reg = reg }, .{ .imm = 0 });
    try cg.loadLimb(reg, v, n - 1);
    try cg.e.shift(.sar, .qword, .{ .reg = reg }, 63);
}

/// `v` with a wide integer in memory (materializing an undefined constant).
fn wideVal(cg: *CodeGen, ref: Ref) Error!Val {
    const v = try cg.valOf(ref);
    if (v.loc == .mem or cg.passInRegs(v.ty)) return v;
    return memVal(v.ty, try cg.valMem(v));
}

/// Re-normalizes the wide integer of type `ty` at `m` after an operation
/// that may have changed the bits above its width. Uses rax.
fn normalizeWide(cg: *CodeGen, m: Mem, ty: Index) Error!void {
    const info = Type.intInfo(cg.ip, ty);
    const n = cg.limbCount(ty);
    const top: u32 = (info.bits - 1) / 64;
    const r: u8 = @intCast(info.bits % 64);
    const s = info.signedness == .signed;
    if (r == 0 and top == n - 1) return;
    try cg.e.mov(.qword, .{ .reg = .rax }, .{ .mem = limb(m, top) });
    if (r != 0) {
        try cg.e.shift(.shl, .qword, .{ .reg = .rax }, 64 - r);
        try cg.e.shift(if (s) .sar else .shr, .qword, .{ .reg = .rax }, 64 - r);
        try cg.e.mov(.qword, .{ .mem = limb(m, top) }, .{ .reg = .rax });
    }
    if (top + 1 == n) return;
    if (s) try cg.e.shift(.sar, .qword, .{ .reg = .rax }, 63) else try cg.e.alu(.xor, .dword, .{ .reg = .rax }, .{ .reg = .rax });
    for (top + 1..n) |i| try cg.e.mov(.qword, .{ .mem = limb(m, @intCast(i)) }, .{ .reg = .rax });
}

/// Integer `v` converted to integer type `ty` at `dst`: truncated or
/// extended.
fn wideCast(cg: *CodeGen, dst: Mem, ty: Index, v: Val) Error!void {
    if (!Type.isInt(cg.ip, v.ty)) {
        // A float's or a vector's bits.
        try cg.copyMem(dst, try cg.valMem(v), @min(Type.abiSize(cg.ip, ty), Type.abiSize(cg.ip, v.ty)));
        return cg.normalizeWide(dst, ty);
    }
    if (cg.passInRegs(ty)) {
        try cg.loadLimb(.rax, v, 0);
        try cg.normalize(.rax, ty);
        return cg.storeReg(dst, .rax, Type.abiSize(cg.ip, ty));
    }
    for (0..cg.limbCount(ty)) |i| {
        try cg.loadLimb(.rax, v, @intCast(i));
        try cg.e.mov(.qword, .{ .mem = limb(dst, @intCast(i)) }, .{ .reg = .rax });
    }
    try cg.normalizeWide(dst, ty);
}

/// `dst = lhs * rhs` over `n` limbs, wrapping. `dst` must not overlap the
/// operands. Uses rax, rcx, rdx, r8.
fn mulLimbs(cg: *CodeGen, dst: Mem, lhs: Mem, rhs: Mem, n: u32) Error!void {
    const e = &cg.e;
    try e.alu(.xor, .dword, .{ .reg = .rax }, .{ .reg = .rax });
    for (0..n) |i| try e.mov(.qword, .{ .mem = limb(dst, @intCast(i)) }, .{ .reg = .rax });
    for (0..n) |i| {
        // r8 carries the high half into the next column.
        try e.alu(.xor, .dword, .{ .reg = .r8 }, .{ .reg = .r8 });
        for (0..n - i) |j| {
            const k: u32 = @intCast(i + j);
            try e.mov(.qword, .{ .reg = .rax }, .{ .mem = limb(lhs, @intCast(i)) });
            if (k == n - 1) {
                // The last column keeps only the low half.
                try e.imul(.qword, .rax, .{ .mem = limb(rhs, @intCast(j)) }, null);
                try e.alu(.add, .qword, .{ .reg = .rax }, .{ .reg = .r8 });
                try e.alu(.add, .qword, .{ .mem = limb(dst, k) }, .{ .reg = .rax });
                continue;
            }
            try e.unary(.mul, .qword, .{ .mem = limb(rhs, @intCast(j)) });
            try e.alu(.add, .qword, .{ .reg = .rax }, .{ .reg = .r8 });
            try e.alu(.adc, .qword, .{ .reg = .rdx }, .{ .imm = 0 });
            try e.alu(.add, .qword, .{ .mem = limb(dst, k) }, .{ .reg = .rax });
            try e.alu(.adc, .qword, .{ .reg = .rdx }, .{ .imm = 0 });
            try e.mov(.qword, .{ .reg = .r8 }, .{ .reg = .rdx });
        }
    }
}

/// Shifts the wide integer `v` of type `ty` by `amount` (less than its
/// width) into `dst`, through a buffer that pads it with zeros (left) or
/// its extension (right), so that each result limb is one double shift.
fn shiftWide(cg: *CodeGen, left: bool, dst: Mem, ty: Index, v: Val, amount: Val) Error!void {
    const e = &cg.e;
    const n = cg.limbCount(ty);
    const buf = Mem.at(.rbp, try cg.allocSlot(@as(u64, n) * 16, 8));
    const src_half = if (left) limb(buf, n) else buf;
    const pad_half = if (left) buf else limb(buf, n);
    try cg.copyMem(src_half, v.loc.mem, @as(u64, n) * 8);
    try cg.loadLimb(.rax, if (left) .{ .ty = .u64_type, .loc = .{ .imm = 0 } } else v, if (left) 0 else n);
    for (0..n) |i| try e.mov(.qword, .{ .mem = limb(pad_half, @intCast(i)) }, .{ .reg = .rax });
    // r10 = the limb the result starts from; cl = the bit shift.
    try cg.loadVal(.rcx, amount);
    try e.mov(.qword, .{ .reg = .rdx }, .{ .reg = .rcx });
    try e.shift(.shr, .qword, .{ .reg = .rdx }, 6);
    try e.shift(.shl, .qword, .{ .reg = .rdx }, 3);
    try e.lea(.qword, .r10, src_half);
    if (left) try e.alu(.sub, .qword, .{ .reg = .r10 }, .{ .reg = .rdx }) else try e.alu(.add, .qword, .{ .reg = .r10 }, .{ .reg = .rdx });
    try e.alu(.@"and", .dword, .{ .reg = .rcx }, .{ .imm = 63 });
    for (0..n) |i| {
        const d: i32 = @intCast(i * 8);
        try e.mov(.qword, .{ .reg = .rax }, .{ .mem = Mem.at(.r10, d) });
        try e.mov(.qword, .{ .reg = .rdx }, .{ .mem = Mem.at(.r10, if (left) d - 8 else d + 8) });
        try e.shiftDouble(left, .{ .reg = .rax }, .rdx);
        try e.mov(.qword, .{ .mem = limb(dst, @intCast(i)) }, .{ .reg = .rax });
    }
    try cg.normalizeWide(dst, ty);
}

/// Instructions on wide integers.
fn genWide(cg: *CodeGen, inst: Inst.Index, tag: Inst.Tag, data: Inst.Data) Error!void {
    const ip = cg.ip;
    const e = &cg.e;
    switch (tag) {
        .add_wrap, .sub_wrap, .bit_and, .bit_or, .xor => {
            const ty = cg.typeOf(data.bin_op.lhs);
            const dst = try cg.resultMem(inst, ty) orelse return;
            const lhs = (try cg.wideVal(data.bin_op.lhs)).loc.mem;
            const rhs = (try cg.wideVal(data.bin_op.rhs)).loc.mem;
            for (0..cg.limbCount(ty)) |i_| {
                const i: u32 = @intCast(i_);
                try e.mov(.qword, .{ .reg = .rax }, .{ .mem = limb(lhs, i) });
                try e.alu(switch (tag) {
                    .add_wrap => if (i == 0) .add else .adc,
                    .sub_wrap => if (i == 0) .sub else .sbb,
                    .bit_and => .@"and",
                    .bit_or => .@"or",
                    else => .xor,
                }, .qword, .{ .reg = .rax }, .{ .mem = limb(rhs, i) });
                try e.mov(.qword, .{ .mem = limb(dst, i) }, .{ .reg = .rax });
            }
            if (tag == .add_wrap or tag == .sub_wrap) try cg.normalizeWide(dst, ty);
        },
        .mul_wrap => {
            const ty = cg.typeOf(data.bin_op.lhs);
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.mulLimbs(dst, (try cg.wideVal(data.bin_op.lhs)).loc.mem, (try cg.wideVal(data.bin_op.rhs)).loc.mem, cg.limbCount(ty));
            try cg.normalizeWide(dst, ty);
        },
        .shl, .shr => {
            const ty = cg.typeOf(data.bin_op.lhs);
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.shiftWide(tag == .shl, dst, ty, try cg.wideVal(data.bin_op.lhs), try cg.valOf(data.bin_op.rhs));
        },
        .not => {
            const ty = data.ty_op.ty;
            const dst = try cg.resultMem(inst, ty) orelse return;
            const src = (try cg.wideVal(data.ty_op.operand)).loc.mem;
            for (0..cg.limbCount(ty)) |i| {
                try e.mov(.qword, .{ .reg = .rax }, .{ .mem = limb(src, @intCast(i)) });
                try e.unary(.not, .qword, .{ .reg = .rax });
                try e.mov(.qword, .{ .mem = limb(dst, @intCast(i)) }, .{ .reg = .rax });
            }
            try cg.normalizeWide(dst, ty);
        },
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => {
            const dst = try cg.resultMem(inst, .bool_type) orelse return;
            const ty = cg.typeOf(data.bin_op.lhs);
            const n = cg.limbCount(ty);
            var a = (try cg.wideVal(data.bin_op.lhs)).loc.mem;
            var b = (try cg.wideVal(data.bin_op.rhs)).loc.mem;
            if (tag == .cmp_eq or tag == .cmp_neq) {
                try e.mov(.qword, .{ .reg = .rax }, .{ .mem = a });
                try e.alu(.xor, .qword, .{ .reg = .rax }, .{ .mem = b });
                for (1..n) |i| {
                    try e.mov(.qword, .{ .reg = .rcx }, .{ .mem = limb(a, @intCast(i)) });
                    try e.alu(.xor, .qword, .{ .reg = .rcx }, .{ .mem = limb(b, @intCast(i)) });
                    try e.alu(.@"or", .qword, .{ .reg = .rax }, .{ .reg = .rcx });
                }
                return e.setcc(if (tag == .cmp_eq) .e else .ne, .{ .mem = dst });
            }
            // The flags of `a - b` over all limbs: `>` and `<=` swap.
            if (tag == .cmp_gt or tag == .cmp_lte) std.mem.swap(Mem, &a, &b);
            for (0..n) |i| {
                try e.mov(.qword, .{ .reg = .rax }, .{ .mem = limb(a, @intCast(i)) });
                try e.alu(if (i == 0) .cmp else .sbb, .qword, .{ .reg = .rax }, .{ .mem = limb(b, @intCast(i)) });
            }
            const s = cg.signed(ty);
            try e.setcc(switch (tag) {
                .cmp_lt, .cmp_gt => if (s) .l else .b,
                else => if (s) .ge else .ae,
            }, .{ .mem = dst });
        },
        .intcast, .trunc, .bitcast => {
            const ty = data.ty_op.ty;
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.wideCast(dst, ty, try cg.wideVal(data.ty_op.operand));
        },
        .div_trunc, .div_floor, .div_ceil, .rem, .mod => {
            const ty = cg.typeOf(data.bin_op.lhs);
            const dst = try cg.resultMem(inst, ty) orelse return;
            const n = cg.limbCount(ty);
            const lhs = try cg.wideVal(data.bin_op.lhs);
            const rhs = try cg.wideVal(data.bin_op.rhs);
            const s = cg.signed(ty);
            const want_q = tag == .div_trunc or tag == .div_floor or tag == .div_ceil;
            const adjust = tag == .div_ceil or (s and (tag == .div_floor or tag == .mod));
            const rem = if (want_q and adjust) Mem.at(.rbp, try cg.allocSlot(@as(u64, n) * 8, 16)) else dst;
            if (n == 2) {
                const rt_ty: Index = if (s) .i128_type else .u128_type;
                const l: Val = .{ .ty = rt_ty, .loc = lhs.loc };
                const r: Val = .{ .ty = rt_ty, .loc = rhs.loc };
                const q_name = if (s) "__divti3" else "__udivti3";
                const r_name = if (s) "__modti3" else "__umodti3";
                if (adjust or !want_q) try cg.rtCall("udivmod.zig", r_name, &.{ l, r }, rt_ty, rem);
                if (want_q) try cg.rtCall("udivmod.zig", q_name, &.{ l, r }, rt_ty, dst);
            } else {
                // `__udivei4(q, u, v, bits)` and friends work on integers of
                // their ABI size in memory; the signed ones clobber u and v.
                const file = if (s) "divmodei4.zig" else "udivmodei4.zig";
                const q_name = if (s) "__divei4" else "__udivei4";
                const r_name = if (s) "__modei4" else "__umodei4";
                if (adjust or !want_q) try cg.divEi4(file, r_name, rem, lhs.loc.mem, rhs.loc.mem, ty);
                if (want_q) try cg.divEi4(file, q_name, dst, lhs.loc.mem, rhs.loc.mem, ty);
            }
            if (!adjust) return;
            // Adjust when the remainder is non-zero and, for floor and mod,
            // its sign differs from the divisor's; for ceil, when the exact
            // quotient is positive.
            const done = try e.newLabel();
            try e.mov(.qword, .{ .reg = .rax }, .{ .mem = rem });
            for (1..n) |i| try e.alu(.@"or", .qword, .{ .reg = .rax }, .{ .mem = limb(rem, @intCast(i)) });
            try e.jcc(.e, .{ .label = done });
            if (s) {
                try e.mov(.qword, .{ .reg = .rax }, .{ .mem = limb(rem, n - 1) });
                try e.alu(.xor, .qword, .{ .reg = .rax }, .{ .mem = limb(rhs.loc.mem, n - 1) });
                try e.jcc(if (tag == .div_ceil) .s else .ns, .{ .label = done });
            }
            switch (tag) {
                .div_floor, .div_ceil => for (0..n) |i| {
                    try e.alu(if (tag == .div_floor)
                        (if (i == 0) .sub else .sbb)
                    else
                        (if (i == 0) .add else .adc), .qword, .{ .mem = limb(dst, @intCast(i)) }, .{ .imm = @intFromBool(i == 0) });
                },
                else => for (0..n) |i| {
                    try e.mov(.qword, .{ .reg = .rax }, .{ .mem = limb(rhs.loc.mem, @intCast(i)) });
                    try e.alu(if (i == 0) .add else .adc, .qword, .{ .mem = limb(dst, @intCast(i)) }, .{ .reg = .rax });
                },
            }
            e.bind(done);
        },
        .add_with_overflow, .sub_with_overflow, .mul_with_overflow => {
            const bin = cg.ir.extraData(Ir.Bin, data.ty_pl.payload).data;
            const tuple_ty = data.ty_pl.ty;
            const ty = cg.typeOf(bin.lhs);
            const dst = try cg.resultMem(inst, tuple_ty) orelse return;
            const flag = offsetMem(dst, Type.fieldOffset(ip, tuple_ty, 1));
            const n = cg.limbCount(ty);
            const lhs = try cg.wideVal(bin.lhs);
            const rhs = try cg.wideVal(bin.rhs);
            const info = Type.intInfo(ip, ty);
            const s = info.signedness == .signed;
            // The exact result, in `n` limbs (add, sub) or `2n` (mul).
            const wide_n = if (tag == .mul_with_overflow) 2 * n else n;
            const raw = Mem.at(.rbp, try cg.allocSlot(@as(u64, wide_n) * 8, 8));
            if (tag == .mul_with_overflow) {
                // Products of the operands extended to 2n limbs are exact.
                const a = Mem.at(.rbp, try cg.allocSlot(@as(u64, wide_n) * 8, 8));
                const b = Mem.at(.rbp, try cg.allocSlot(@as(u64, wide_n) * 8, 8));
                for (0..wide_n) |i| {
                    try cg.loadLimb(.rax, lhs, @intCast(i));
                    try e.mov(.qword, .{ .mem = limb(a, @intCast(i)) }, .{ .reg = .rax });
                    try cg.loadLimb(.rax, rhs, @intCast(i));
                    try e.mov(.qword, .{ .mem = limb(b, @intCast(i)) }, .{ .reg = .rax });
                }
                try cg.mulLimbs(raw, a, b, wide_n);
            } else {
                for (0..n) |i| {
                    try e.mov(.qword, .{ .reg = .rax }, .{ .mem = limb(lhs.loc.mem, @intCast(i)) });
                    try e.alu(if (tag == .add_with_overflow)
                        (if (i == 0) .add else .adc)
                    else
                        (if (i == 0) .sub else .sbb), .qword, .{ .reg = .rax }, .{ .mem = limb(rhs.loc.mem, @intCast(i)) });
                    try e.mov(.qword, .{ .mem = limb(raw, @intCast(i)) }, .{ .reg = .rax });
                }
            }
            if (tag != .mul_with_overflow and info.bits == 64 * n) {
                // Full limbs: the carry or overflow flag of the top limb.
                try e.setcc(if (s) .o else .b, .{ .mem = flag });
                return cg.copyMem(dst, raw, @as(u64, n) * 8);
            }
            // Overflowed iff the exact result differs from the truncated
            // result extended back.
            try cg.copyMem(dst, raw, @as(u64, n) * 8);
            try cg.normalizeWide(dst, ty);
            try e.alu(.xor, .dword, .{ .reg = .rcx }, .{ .reg = .rcx });
            const res: Val = memVal(ty, dst);
            for (0..wide_n) |i| {
                try cg.loadLimb(.rax, res, @intCast(i));
                try e.alu(.xor, .qword, .{ .reg = .rax }, .{ .mem = limb(raw, @intCast(i)) });
                try e.alu(.@"or", .qword, .{ .reg = .rcx }, .{ .reg = .rax });
            }
            try e.setcc(.ne, .{ .mem = flag });
        },
        else => unreachable,
    }
}

/// `@clz`, `@ctz`, `@popCount`, `@byteSwap`, and `@bitReverse` of a wide
/// integer.
fn wideBitOp(cg: *CodeGen, inst: Inst.Index, tag: Inst.Tag, data: Inst.Data) Error!void {
    const e = &cg.e;
    const ty = data.ty_op.ty;
    const dst = try cg.resultMem(inst, ty) orelse return;
    const src_ty = cg.typeOf(data.ty_op.operand);
    const src = (try cg.wideVal(data.ty_op.operand)).loc.mem;
    const bits = Type.intInfo(cg.ip, src_ty).bits;
    // Limbs holding the operand's bits, and the bits of the top one.
    const n: u32 = (bits + 63) / 64;
    const r: u8 = @intCast(bits - (n - 1) * 64);
    const done = try e.newLabel();
    switch (tag) {
        .clz, .ctz => {
            var labels: [64]Encoder.Label = undefined;
            if (n > labels.len) return cg.fail("@clz and @ctz of integers wider than 4096 bits", .{});
            for (0..n) |k| {
                const i: u32 = @intCast(if (tag == .clz) n - 1 - k else k);
                try e.mov(.qword, .{ .reg = .rax }, .{ .mem = limb(src, i) });
                if (tag == .clz and i == n - 1 and r != 64) {
                    try e.shift(.shl, .qword, .{ .reg = .rax }, 64 - r);
                    try e.shift(.shr, .qword, .{ .reg = .rax }, 64 - r);
                }
                labels[k] = try e.newLabel();
                try e.bitScan(tag == .clz, .qword, .rcx, .{ .reg = .rax });
                try e.jcc(.ne, .{ .label = labels[k] });
            }
            try e.mov(.dword, .{ .reg = .rax }, .{ .imm = bits });
            try e.jmp(.{ .label = done });
            for (0..n) |k| {
                const i: u32 = @intCast(if (tag == .clz) n - 1 - k else k);
                e.bind(labels[k]);
                if (tag == .clz) {
                    // bits - 1 - (64 i + bsr)
                    try e.mov(.dword, .{ .reg = .rax }, .{ .imm = bits - 1 - 64 * i });
                    try e.alu(.sub, .qword, .{ .reg = .rax }, .{ .reg = .rcx });
                } else {
                    try e.lea(.qword, .rax, .{ .base = .{ .reg = .rcx }, .disp = @intCast(64 * i) });
                }
                try e.jmp(.{ .label = done });
            }
        },
        .popcount => {
            try e.alu(.xor, .dword, .{ .reg = .rax }, .{ .reg = .rax });
            for (0..n) |i| {
                try e.mov(.qword, .{ .reg = .rdx }, .{ .mem = limb(src, @intCast(i)) });
                if (i == n - 1 and r != 64) {
                    try e.shift(.shl, .qword, .{ .reg = .rdx }, 64 - r);
                    try e.shift(.shr, .qword, .{ .reg = .rdx }, 64 - r);
                }
                // while (x != 0) { x &= x - 1; count += 1; }
                const top = try e.newLabel();
                const next = try e.newLabel();
                e.bind(top);
                try e.@"test"(.qword, .{ .reg = .rdx }, .{ .reg = .rdx });
                try e.jcc(.e, .{ .label = next });
                try e.lea(.qword, .rcx, .{ .base = .{ .reg = .rdx }, .disp = -1 });
                try e.alu(.@"and", .qword, .{ .reg = .rdx }, .{ .reg = .rcx });
                try e.alu(.add, .qword, .{ .reg = .rax }, .{ .imm = 1 });
                try e.jmp(.{ .label = top });
                e.bind(next);
            }
        },
        .byte_swap, .bit_reverse => {
            // Reverse the n limbs, each reversed in itself, then shift the
            // result down by the bits above the operand's width.
            for (0..n) |i| {
                try e.mov(.qword, .{ .reg = .rdx }, .{ .mem = limb(src, @intCast(n - 1 - i)) });
                if (tag == .byte_swap) {
                    try e.bswap(.qword, .rdx);
                    try e.mov(.qword, .{ .reg = .rax }, .{ .reg = .rdx });
                } else {
                    try e.mov(.dword, .{ .reg = .rcx }, .{ .imm = 64 });
                    const top = try e.newLabel();
                    e.bind(top);
                    try e.shift(.shr, .qword, .{ .reg = .rdx }, 1);
                    try e.alu(.adc, .qword, .{ .reg = .rax }, .{ .reg = .rax });
                    try e.alu(.sub, .dword, .{ .reg = .rcx }, .{ .imm = 1 });
                    try e.jcc(.ne, .{ .label = top });
                }
                try e.mov(.qword, .{ .mem = limb(dst, @intCast(i)) }, .{ .reg = .rax });
            }
            if (r != 64) {
                try e.mov(.dword, .{ .reg = .rcx }, .{ .imm = 64 - r });
                for (0..n) |i| {
                    try e.mov(.qword, .{ .reg = .rax }, .{ .mem = limb(dst, @intCast(i)) });
                    if (i + 1 < n) {
                        try e.mov(.qword, .{ .reg = .rdx }, .{ .mem = limb(dst, @intCast(i + 1)) });
                        try e.shiftDouble(false, .{ .reg = .rax }, .rdx);
                    } else {
                        try e.shift(.shr, .qword, .{ .reg = .rax }, null);
                    }
                    try e.mov(.qword, .{ .mem = limb(dst, @intCast(i)) }, .{ .reg = .rax });
                }
            }
            return cg.normalizeWide(dst, ty);
        },
        else => unreachable,
    }
    e.bind(done);
    try cg.storeReg(dst, .rax, Type.abiSize(cg.ip, ty));
}
