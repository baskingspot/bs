//! aarch64-macos code generation: lowers a function's typed IR, in the
//! block order the shared SSA layer chooses (`Ssa.build`, `Ssa.place`), to
//! machine code and an `Atom`.
//!
//! `Ssa.plan` decides which values are not emitted, which conditions their
//! branch computes, and which overflow results write their fields
//! directly. Scalars in general-purpose registers (`inGpr`), including
//! promoted variables, get one of the callee-saved x19-x28 from linear
//! scan (`Ssa.allocate`); f32 and f64 (`inFloat`) one of d8-d15, whose
//! low halves calls preserve, or of v20-v29; and vectors of up to 16
//! bytes (`inVec`) one of v20-v29. Calls clobber v20-v29, so a value lives
//! in one only when no instruction that may call (`callFree`) lies in its
//! interval. The rest, and those the allocator leaves out, live in stack
//! slots shared by lifetime (`Ssa.liveness`). Each instruction loads its
//! operands into scratch registers, computes, and writes its result, to
//! its register only after reading every operand (results through
//! `resultMem` are moved there once the instruction's code is done). No
//! lowering uses an allocated register as scratch, so no value is
//! spilled around a call.
//! Functions with inline assembly, which names registers itself, keep
//! every value in a slot.
//!
//! Frame (every non-naked function keeps a frame record, so compact
//! unwind's frame mode and std's frame-pointer walk cover it):
//!
//!     fp + 16 ...   incoming stack arguments
//!     fp + 8        saved lr
//!     fp            saved fp
//!     fp - 16 ...   the used pairs of x19-x28: x19 at fp - 8, x20 at
//!                   fp - 16, then the next used pair (compact unwind's
//!                   frame mode, `saved`)
//!     ...           value slots, growing up from sp + out_args_size
//!     sp            outgoing stack arguments
//!
//! Slots are addressed from sp, whose offset is fixed after the prologue,
//! so loads and stores use the scaled 12-bit offset forms.
//!
//! Registers: x9-x14 are scratch within one instruction's lowering; x16 and
//! x17 legalize addresses (and x16 holds indirect call targets); x8 is the
//! result pointer and x15 the error return trace pointer at `.auto` calls.
//! A scalar in a register is extended to 64 bits as its type's load extends
//! it.

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
const vector = @import("vector.zig");
const Ssa = @import("../Ssa.zig");
const switch_br = @import("../switch_br.zig");
const Reg = Encoder.Reg;
const VReg = Encoder.VReg;
const Size = Encoder.Size;
const Cond = Encoder.Cond;
const Float = Encoder.Float;

const CodeGen = @This();

emit: *Emit,
gpa: Allocator,
ip: *InternPool,
ir: *const Ir,
e: Encoder,
fn_ty: InternPool.FuncType,
homes: []Home,
ssa: *const Ssa,
/// Each SSA block's label, by block index.
labels: []Encoder.Label,
/// Bytes of value slots, above the outgoing argument area.
slots_size: u32 = 0,
/// Bytes of the outgoing argument area at sp, a multiple of 16, fixed
/// before emission (`outgoingArgsSize`).
out_args_size: u32 = 0,
/// The slot holding the result pointer, for results returned in memory.
ret_ptr_slot: ?Mem = null,
/// The slot holding the error return trace pointer: an `.auto` function's
/// from x15, another's from `set_err_return_trace`. Null in a function
/// that has none, whose `.auto` calls pass null.
trace_slot: ?Mem = null,
/// `Ssa.liveness` ran, so value slots are shared by lifetime.
live: bool = false,
/// The condition under which the last overflow operation whose bit its
/// block's branch reads from the flags (`fate == .fused`) overflowed.
ovf_cc: Cond = .vs,
/// Emitting the cold blocks, after the others.
in_cold: bool = false,
/// The block being emitted.
block: Ssa.Block.Index = .none,
/// Per cold block, in `Ssa.order`, the debug state where it would have
/// been emitted in place (as in the x86_64 backend).
cold_starts: std.ArrayList(ColdStart) = .empty,
cold_open: std.ArrayList(OpenInline) = .empty,
/// The pairs of x19-x28 the prologue saves, as `Atom.Unwind.saved` holds
/// them: x19/x20 0x1 through x27/x28 0x10.
saved: u16 = 0,
/// Scratch slots for register values an instruction needs in memory,
/// reused by each instruction from `tmp_next` on (`tempSlot`).
tmp_slots: std.ArrayList(Mem) = .empty,
tmp_next: u32 = 0,
/// Some value lives in v20-v29 (`allocateRegs`).
vregs: bool = false,
/// As `tmp_slots`, of 16 bytes (`tempSlot16`).
tmp16_slots: std.ArrayList(Mem) = .empty,
tmp16_next: u32 = 0,
/// Results in a register written to a scratch slot (`resultMem`), moved
/// to the register when the instruction's code is done (`flushResults`).
pending: std.ArrayList(Pending) = .empty,
/// Inline assembly marked the return address undefined (`.cfi_undefined
/// lr`): this is the outermost frame.
outermost_frame: bool = false,
/// Assembling container-level assembly (`GlobalAsm`): where errors go.
global_asm: ?GlobalAsm.Src = null,
/// In a variadic C function: the stack bytes the named parameters use.
va_stack: u32 = 0,
/// Debug info, as in the x86_64 backend.
dbg_line: u32 = 0,
dbg_column: u32 = 0,
dbg_inlines: std.ArrayList(Atom.Debug.Inline) = .empty,
dbg_inline_names: std.ArrayList(u8) = .empty,
dbg_inline_callees: std.ArrayList(SymbolKey) = .empty,
dbg_files: std.ArrayList(u32) = .empty,
dbg_open: std.ArrayList(OpenInline) = .empty,
/// Panic calls in code the backend inlined, which call a chain of stubs
/// emitted after the blocks instead of the handler (`panicThroughStubs`),
/// with the inlined calls open at each (`stub_open`), and the stubs'
/// bytes so far (as in the x86_64 backend).
stub_chains: std.ArrayList(StubChain) = .empty,
stub_open: std.ArrayList(OpenInline) = .empty,
stub_bytes: u32 = 0,

/// An inlined call whose end is not reached yet, and the caller's row to
/// resume after it.
const OpenInline = struct { index: u32, line: u32, column: u32, backend: bool = false };

/// A panic call through stubs: the stubs' first label, the handler, the
/// inlined calls open at the call (`stub_open[open_start..][0..open_len]`),
/// and the row of the check, relative to the innermost.
const StubChain = struct { label: Encoder.Label, target: SymbolKey, open_start: u32, open_len: u32, line: u32, column: u32 };

const Pending = struct { inst: Inst.Index, mem: Mem };

const ColdStart = struct { line: u32, column: u32, open_start: u32, open_len: u32 };

pub const Error = Allocator.Error || error{CodegenFail};

/// A memory location: a register (sp, fp, or a scratch register holding a
/// pointer) or a symbol's address, plus an offset.
pub const Mem = struct {
    base: Base,
    off: i32,

    const Base = union(enum) { reg: Reg, sym: SymbolKey };

    pub fn at(r: Reg, off: i32) Mem {
        return .{ .base = .{ .reg = r }, .off = off };
    }

    pub fn sym(key: SymbolKey, off: i32) Mem {
        return .{ .base = .{ .sym = key }, .off = off };
    }

    /// The offset from sp of a slot.
    fn base_off(m: Mem) i32 {
        assert(m.base == .reg and m.base.reg == .sp);
        return m.off;
    }

    pub fn plus(m: Mem, d: u64) Mem {
        var r = m;
        r.off += @intCast(d);
        return r;
    }
};

/// Where an instruction's value lives.
const Home = union(enum) {
    none,
    /// The value is stored here.
    slot: Mem,
    /// The value is this address (an `alloc`).
    frame_addr: Mem,
    /// The value is in this register; for an `alloc`, a promoted
    /// variable (`Ssa.plan`), the variable's value is.
    reg: Reg,
    /// The value is in this register: an f32 or f64 in one of d8-d15 or
    /// v20-v29, or a vector (`inVec`) in one of v20-v29.
    vreg: VReg,
    /// The memory this many bytes into the function's own result, through
    /// the pointer the caller passed, read through x8: a call whose result
    /// a `ret` returns (`planRetCalls`) writes it there, and its users read
    /// it there. Such values are larger than 16 bytes, which the lowerings
    /// that use x8 as scratch (`atomicRmw16`) never read.
    result: u32,
};

/// Where an operand's value can be read.
pub const Loc = union(enum) {
    none,
    /// The value is stored in memory.
    mem: Mem,
    /// The value is in this register (x19-x28).
    reg: Reg,
    /// The f32, f64 or vector is in this register (d8-d15, v20-v29).
    vreg: VReg,
    /// The value is the address of this memory.
    addr: Mem,
    /// A scalar constant, already extended to 64 bits.
    imm: u64,
    /// The code of an error, resolved at link time.
    err: InternPool.String,
};

/// A value as an operand: its type and where it can be read.
const Val = struct { ty: Index, loc: Loc };

pub fn generate(emit: *Emit, ir: *const Ir) Error!void {
    const ip = &emit.zcu.ip;
    const func = ip.keyPayload(.func, ir.func);
    const gpa = emit.gpa;
    try emit.ssa.build(gpa, ir);
    // No coverage points: main.zig refuses -ffuzz for aarch64-macos.
    try emit.ssa.place(gpa, ir, ip, false);
    var cg: CodeGen = .{
        .emit = emit,
        .gpa = gpa,
        .ip = ip,
        .ir = ir,
        .e = .init(gpa),
        .fn_ty = ip.keyPayload(.func_type, func.ty),
        .homes = try gpa.alloc(Home, ir.instructions.len),
        .ssa = &emit.ssa,
        .labels = try gpa.alloc(Encoder.Label, emit.ssa.blocks.items.len),
    };
    defer {
        cg.e.deinit();
        gpa.free(cg.homes);
        gpa.free(cg.labels);
        cg.dbg_inlines.deinit(gpa);
        cg.dbg_inline_names.deinit(gpa);
        cg.dbg_inline_callees.deinit(gpa);
        cg.dbg_files.deinit(gpa);
        cg.dbg_open.deinit(gpa);
        cg.cold_starts.deinit(gpa);
        cg.cold_open.deinit(gpa);
        cg.tmp_slots.deinit(gpa);
        cg.tmp16_slots.deinit(gpa);
        cg.pending.deinit(gpa);
        cg.stub_chains.deinit(gpa);
        cg.stub_open.deinit(gpa);
    }
    @memset(cg.homes, .none);
    const naked = cg.fn_ty.cc == .naked;
    const f = &emit.ssa;
    try f.live.resize(gpa, ir.instructions.len);
    @memset(f.live.items(.reg), Ssa.no_reg);
    if (!naked) {
        // preserve_none passes arguments in x20-x28, where values live, and
        // its callee clobbers them all, so such functions get no registers,
        // as with inline assembly.
        if (cg.fn_ty.cc == .aarch64_preserve_none or cg.callsPreserveNone()) f.has_asm = true;
        // `clobbers` marks the values that want a register.
        try f.liveness(gpa, ir, &cg);
        try f.plan(gpa, ir, ip, &cg);
        f.bypassUnread(ir);
        cg.live = true;
        if (!f.has_asm) {
            try cg.allocateRegs();
            try cg.planRetCalls();
        }
    } else @memset(f.live.items(.fate), .normal);

    // The prologue belongs to the declaration's line.
    try cg.e.line(0, 0);
    var frame_at: u32 = 0;
    var body: Encoder.Label = undefined;
    if (!naked) {
        cg.out_args_size = cg.outgoingArgsSize();
        try cg.e.stp(.dword, .fp, .lr, .{ .base = .sp, .offset = .{ .pre = -16 } });
        try cg.e.mov(.x, .fp, .sp);
        for (0..5) |k| if (cg.saved >> @intCast(k) & 1 != 0) {
            try cg.e.stp(.dword, pairReg(k, 1), pairReg(k, 0), .{ .base = .sp, .offset = .{ .pre = -16 } });
        };
        for (0..4) |k| if (cg.saved >> @intCast(8 + k) & 1 != 0) {
            try cg.e.stpFp(.f64, float_regs[2 * k + 1], float_regs[2 * k], .{ .base = .sp, .offset = .{ .pre = -16 } });
        };
        // Two instructions that allocate the frame, written once its size
        // is known (`allocFrame`).
        frame_at = @intCast(cg.e.code.items.len);
        try cg.e.nop();
        try cg.e.nop();
        body = try cg.e.newLabel();
        cg.e.bind(body);
        try cg.setupParams();
    }
    try cg.emitBlocks();
    const stubs_at: u32 = @intCast(cg.e.code.items.len);
    try cg.emitStubs();
    const probes_at = if (!naked) try cg.allocFrame(frame_at, body) else null;
    cg.e.finish() catch |err| switch (err) {
        error.BranchOutOfRange => return cg.fail("function too large for its branches", .{}),
        else => |x| return x,
    };
    // The stubs, then the probes, end the code (`Atom.Unwind.epilogue`).
    var unwind: Atom.Unwind = .{ .kind = .frame_pointer, .saved = cg.saved };
    if (cg.stub_chains.items.len != 0) {
        const size = cg.e.code.items.len;
        unwind.epilogue = @intCast(size - cg.e.finalOffset(stubs_at));
        if (probes_at) |at| unwind.probes = @intCast(size - cg.e.finalOffset(at));
    }
    for (cg.dbg_inlines.items) |*in| {
        in.low = cg.e.finalOffset(in.low);
        in.high = cg.e.finalOffset(in.high);
    }

    emit.codegen_stats.functions += 1;
    emit.codegen_stats.ir_insts += ir.instructions.len;
    emit.codegen_stats.code_bytes += cg.e.code.items.len;
    emit.codegen_stats.frame_bytes += cg.slots_size + cg.out_args_size;

    const arena = emit.allocator();
    const nav = ip.getNav(func.owner_nav);
    const file = emit.zcu.file(nav.file);
    const module = emit.zcu.fe.module(file.module);
    var files: std.ArrayList(u8) = .empty;
    for (cg.dbg_files.items) |fname| {
        try files.appendSlice(arena, emit.zcu.file(fname).display_path);
        try files.append(arena, 0);
    }
    const debug: Atom.Debug = .{
        .file = file.display_path,
        .name = ip.stringSlice(nav.name),
        .base_line = file.zir.getDeclaration(nav.zir_inst).src_line,
        .lines = try arena.dupe(u8, cg.e.lines.bytes.items),
        .unit = try std.Io.Dir.path.join(arena, &.{ module.root_dir, module.root_file }),
        .files = files.items,
        .inlines = try arena.dupe(Atom.Debug.Inline, cg.dbg_inlines.items),
        .inline_names = try arena.dupe(u8, cg.dbg_inline_names.items),
        .inline_callees = try arena.dupe(SymbolKey, cg.dbg_inline_callees.items),
        .patches = try arena.dupe(u32, cg.e.lines.patches.items),
    };
    try emit.addFunction(.{
        .key = try emit.funcKey(ir.func),
        // Names can change until analysis ends (`Emit.nameAtoms`).
        .name = Emit.name_later,
        .section = .text,
        .alignment = .fromByteUnits(@max(4, nav.alignment)),
        .bytes = try arena.dupe(u8, cg.e.code.items),
        .targets = try arena.dupe(Atom.SymbolKey, cg.e.refs.targets.keys()),
        .relocs = try arena.dupe(Atom.Reloc, cg.e.refs.relocs.items),
        .unwind = if (cg.outermost_frame) .outermost else if (naked) .none else unwind,
    }, debug);
}

/// Writes the frame allocation at `frame_at`: `sub sp` of the frame size.
/// On macOS, a frame over 4 KiB probes its pages first, as clang does, out of line:
/// the prologue branches to `mov x9, #size; blr ___chkstk_darwin; sub sp`
/// after the body, which branches back to `body`. A frame of 2^24 bytes or
/// more takes the same out-of-line path, since its `sub sp` needs the size
/// in x17. Returns where that code starts, if there is any.
fn allocFrame(cg: *CodeGen, frame_at: u32, body: Encoder.Label) Error!?u32 {
    const frame = std.mem.alignForward(u32, cg.out_args_size + cg.slots_size, 16);
    // Upstream's LLVM backend probes the stack only on x86 off Darwin
    // (`supportsStackProbing`), so aarch64-linux frames are not probed.
    const probe = frame > 4096 and cg.ip.target != .aarch64_linux;
    if (!probe and frame < 1 << 24) {
        var tmp: Encoder = .init(cg.gpa);
        defer tmp.deinit();
        try subSp(&tmp, frame);
        @memcpy(cg.e.code.items[frame_at..][0..tmp.code.items.len], tmp.code.items);
        return null;
    }
    const at: u32 = @intCast(cg.e.code.items.len);
    const stub = try cg.e.newLabel();
    cg.e.bind(stub);
    try cg.e.line(0, 0);
    if (probe) {
        try cg.e.movImm(.x, .x9, frame);
        try cg.callExtern("__chkstk_darwin");
    }
    try subSp(&cg.e, frame);
    try cg.e.b(.{ .label = body });
    try cg.e.branchFrom(frame_at, stub);
    return at;
}

/// `sub sp, sp, #size`: at most two immediate instructions below 2^24, else
/// the size moved into x17 (free in a prologue) and subtracted.
fn subSp(e: *Encoder, size: u32) !void {
    if (size >= 1 << 24) {
        try e.movImm(.x, .x17, size);
        return e.addSub(.sub, .x, .sp, .sp, .r(.x17));
    }
    if (size >> 12 != 0) try e.addSub(.sub, .x, .sp, .sp, .{ .imm = size & 0xfff000 });
    if (size & 0xfff != 0) try e.addSub(.sub, .x, .sp, .sp, .{ .imm = size & 0xfff });
}

/// Starts the code of a call of `func` inlined at `site` (as the x86_64
/// backend).
fn beginInline(cg: *CodeGen, func: Index, site: Ir.DbgInline) Error!void {
    const ip = cg.ip;
    const zcu = cg.emit.zcu;
    const nav = ip.getNav(ip.keyPayload(.func, func).owner_nav);
    const own_file = ip.getNav(ip.keyPayload(.func, cg.ir.func).owner_nav).file;
    const file: u32 = if (nav.file == own_file) 0 else for (cg.dbg_files.items, 1..) |f, i| {
        if (f == nav.file) break @intCast(i);
    } else blk: {
        try cg.dbg_files.append(cg.gpa, nav.file);
        break :blk @intCast(cg.dbg_files.items.len);
    };
    const index: u32 = @intCast(cg.dbg_inlines.items.len);
    const name = ip.stringSlice(nav.name);
    const callee: SymbolKey = .fromName(ip.stringSlice(nav.key));
    const name_off: u32 = for (cg.dbg_inline_callees.items, cg.dbg_inlines.items) |c, prev| {
        if (c == callee) break prev.name_off;
    } else off: {
        const off: u32 = @intCast(cg.dbg_inline_names.items.len);
        try cg.dbg_inline_names.appendSlice(cg.gpa, name);
        break :off off;
    };
    try cg.dbg_inline_callees.append(cg.gpa, callee);
    try cg.dbg_inlines.append(cg.gpa, .{
        .name_off = name_off,
        .name_len = @intCast(name.len),
        .file = file,
        .base_line = zcu.file(nav.file).zir.getDeclaration(nav.zir_inst).src_line,
        .call_line = site.line,
        .call_column = site.column,
        .low = @intCast(cg.e.code.items.len),
        .high = @intCast(cg.e.code.items.len),
        .parent = if (cg.dbg_open.getLastOrNull()) |o| o.index else Atom.Debug.Inline.none,
    });
    try cg.dbg_open.append(cg.gpa, .{ .index = index, .line = cg.dbg_line, .column = cg.dbg_column, .backend = site.flags.backend });
    try cg.e.switchLines(file, index + 1);
}

/// Ends the innermost inlined call.
fn endInline(cg: *CodeGen) Error!void {
    const open = cg.dbg_open.pop().?;
    cg.dbg_inlines.items[open.index].high = @intCast(cg.e.code.items.len);
    if (cg.dbg_open.getLastOrNull()) |parent| {
        try cg.e.switchLines(cg.dbg_inlines.items[parent.index].file, parent.index + 1);
    } else {
        try cg.e.switchLines(0, 0);
    }
    cg.dbg_line = open.line;
    cg.dbg_column = open.column;
    try cg.e.line(open.line, open.column);
}

fn fail(cg: *CodeGen, comptime fmt: []const u8, args: anytype) Error {
    if (cg.global_asm) |src| {
        try cg.emit.addError(src.file, src.span, fmt, args);
        return error.CodegenFail;
    }
    const ip = cg.ip;
    const nav = ip.getNav(ip.keyPayload(.func, cg.ir.func).owner_nav);
    const tree = try cg.emit.zcu.fe.tree(@fromBackingInt(nav.file));
    const decl = cg.emit.zcu.file(nav.file).zir.getDeclaration(nav.zir_inst);
    try cg.emit.addError(nav.file, tree.nodeToSpan(decl.src_node), "bs codegen (aarch64): " ++ fmt, args);
    return error.CodegenFail;
}

// ---------------------------------------------------------------------------
// Frame and homes

fn allocSlot(cg: *CodeGen, size: u64, alignment: u64) Error!Mem {
    if (alignment > 16) return cg.fail("stack values aligned to more than 16 bytes", .{});
    const off = std.mem.alignForward(u32, cg.slots_size, @intCast(@max(alignment, 1)));
    cg.slots_size = off + @as(u32, @intCast(size));
    return .at(.sp, @intCast(cg.out_args_size + off));
}

/// An 8-byte scratch slot for the current instruction, which the next
/// instruction reuses.
fn tempSlot(cg: *CodeGen) Error!Mem {
    if (cg.tmp_next == cg.tmp_slots.items.len) try cg.tmp_slots.append(cg.gpa, try cg.allocSlot(8, 8));
    cg.tmp_next += 1;
    return cg.tmp_slots.items[cg.tmp_next - 1];
}

/// As `tempSlot`, 16 bytes for a vector register's value.
fn tempSlot16(cg: *CodeGen) Error!Mem {
    if (cg.tmp16_next == cg.tmp16_slots.items.len) try cg.tmp16_slots.append(cg.gpa, try cg.allocSlot(16, 16));
    cg.tmp16_next += 1;
    return cg.tmp16_slots.items[cg.tmp16_next - 1];
}

/// Moves the results `resultMem` put in scratch slots to their registers,
/// and frees the scratch slots for the next instruction.
fn flushResults(cg: *CodeGen) Error!void {
    for (cg.pending.items) |p| switch (cg.homes[@backingInt(p.inst)]) {
        .reg => |r| try cg.loadMem(r, p.mem, cg.ir.typeOfIndex(p.inst, cg.ip)),
        .vreg => |v| {
            const ty = cg.ir.typeOfIndex(p.inst, cg.ip);
            if (cg.inVec(ty)) {
                try vector.loadMem(cg, v, p.mem, @intCast(Type.abiSize(cg.ip, ty)));
            } else try cg.loadFp(v, memVal(ty, p.mem));
        },
        else => unreachable,
    };
    cg.pending.clearRetainingCapacity();
    cg.tmp_next = 0;
    cg.tmp16_next = 0;
}

fn slotFor(cg: *CodeGen, inst: Inst.Index, ty: Index) Error!Home {
    if (!Type.hasRuntimeBits(cg.ip, ty)) {
        cg.homes[@backingInt(inst)] = .none;
        return .none;
    }
    // Values are only copied from and to, never addressed as a `*T`, so 16
    // bytes of alignment suffice (as in the x86_64 backend).
    const size = Type.abiSize(cg.ip, ty);
    const alignment = @min(Type.abiAlignment(cg.ip, ty), 16);
    // Values are emitted in layout order, so a slot whose value's interval
    // has ended can be shared; cold blocks' values get their own.
    const class = if (cg.live and !cg.in_cold) Ssa.slotClass(size, alignment) else null;
    const home: Home = .{ .slot = if (class) |c| blk: {
        const f = &cg.emit.ssa;
        const off = try f.takeSlot(cg.gpa, inst, c) orelse (try cg.allocSlot(c.size, c.alignment)).base_off();
        try f.holdSlot(cg.gpa, inst, off, c);
        break :blk .at(.sp, off);
    } else try cg.allocSlot(size, alignment) };
    cg.homes[@backingInt(inst)] = home;
    return home;
}

pub fn fate(cg: *const CodeGen, inst: Inst.Index) Ssa.Fate {
    return cg.ssa.live.items(.fate)[@backingInt(inst)];
}

// ---------------------------------------------------------------------------
// Registers

/// The registers the allocator hands out: the callee-saved x19-x28, which
/// no lowering uses as scratch and every call preserves.
const alloc_regs = [_]Reg{ .x19, .x20, .x21, .x22, .x23, .x24, .x25, .x26, .x27, .x28 };

/// The floating-point registers the allocator hands out, after
/// `alloc_regs`: d8-d15, whose low 64 bits every call preserves, enough
/// for the f32 and f64 values that have them.
const float_regs = [_]VReg{ .v8, .v9, .v10, .v11, .v12, .v13, .v14, .v15 };

/// Register `half` (0 the lower-numbered) of saved pair `k` (x19/x20 is 0).
fn pairReg(k: usize, half: u1) Reg {
    return @fromBackingInt(@intCast(19 + 2 * k + half));
}

/// The registers the allocator hands out after `float_regs`, to vectors
/// (`inVec`) and to floats that cross no call: v20-v29, which no lowering
/// uses as scratch (vector.zig's are v0-v7, v16-v19, v30 and v31) but
/// every call clobbers.
const vreg_first = 20;
const vreg_count = 10;

/// Gives the values `clobbers` marked their registers (`Ssa.allocate`)
/// and records the pairs the prologue saves: x19/x20 through x27/x28 in
/// bits 0-4 and d8/d9 through d14/d15 in bits 8-11 of `saved`, compact
/// unwind's frame-mode bits.
fn allocateRegs(cg: *CodeGen) Error!void {
    const f = &cg.emit.ssa;
    const live = f.live.slice();
    const reg = live.items(.reg);
    const fates = live.items(.fate);
    @memset(live.items(.hint), .{ Ssa.no_reg, Ssa.no_reg });
    // x19-x28 and d8-d15 survive the clobber points, the instructions
    // that may call (`callFree`); v20-v29 do not, so a value in one never
    // crosses a clobber point, and a vector that crosses one stays in
    // memory (`Ssa.want_vec`). None is split.
    var split = try std.bit_set.Dynamic.initEmpty(cg.gpa, cg.ir.instructions.len);
    defer split.deinit(cg.gpa);
    const survive = alloc_regs.len + float_regs.len;
    const n = survive + vreg_count;
    const used = f.allocate(alloc_regs.len, float_regs.len + vreg_count, (1 << survive) - 1, &.{}, &split, 0, &.{});
    for (0..5) |k| if (used >> @intCast(2 * k) & 3 != 0) {
        cg.saved |= @as(u16, 1) << @intCast(k);
    };
    for (0..4) |k| if (used >> @intCast(alloc_regs.len + 2 * k) & 3 != 0) {
        cg.saved |= @as(u16, 0x100) << @intCast(k);
    };
    for (f.values.items(.inst)) |inst| {
        const i = @backingInt(inst);
        if (fates[i] != .normal or reg[i] >= n) continue;
        cg.homes[i] = if (reg[i] < alloc_regs.len)
            .{ .reg = alloc_regs[reg[i]] }
        else if (reg[i] < survive)
            .{ .vreg = float_regs[reg[i] - alloc_regs.len] }
        else
            .{ .vreg = @fromBackingInt(@intCast(vreg_first + reg[i] - survive)) };
        if (reg[i] >= survive) cg.vregs = true;
    }
}

// `Ssa.liveness` and `Ssa.plan` hooks.

/// Whether value `inst`'s lowering may write a register a value holds:
/// one that may call (`callFree`), which clobbers v20-v29; nothing
/// clobbers x19-x28 or d8-d15. Also marks the values that want a
/// register: scalars in general-purpose registers, f32 and f64 in
/// floating-point ones, and vectors in v20-v29 (`inVec`), other than
/// allocs (`Ssa.plan` promotes variables) and block results.
pub fn clobbers(cg: *CodeGen, inst: Inst.Index) bool {
    if (cg.emit.ssa.has_asm) return false;
    switch (cg.ir.instructions.items(.tag)[@backingInt(inst)]) {
        .alloc, .block => return false,
        else => {},
    }
    const ty = cg.ir.typeOfIndex(inst, cg.ip);
    const live = cg.emit.ssa.live.slice();
    if (cg.inGpr(ty) or cg.inFloat(ty)) {
        live.items(.reg)[@backingInt(inst)] = if (cg.inGpr(ty)) Ssa.want_reg else Ssa.want_float;
        live.items(.tie)[@backingInt(inst)] = cg.tiedOperand(inst);
    } else if (cg.inVec(ty)) {
        live.items(.reg)[@backingInt(inst)] = Ssa.want_vec;
        live.items(.tie)[@backingInt(inst)] = Ssa.no_tie;
    }
    return !cg.callFree(inst);
}

/// Whether `inst`'s lowering certainly makes no call (`bl`, `blr`), so
/// values in v20-v29 survive it. Instructions not known to be call-free
/// count as calls; `genBlock` asserts that the others call nothing.
fn callFree(cg: *CodeGen, inst: Inst.Index) bool {
    const ir = cg.ir;
    const data = ir.instructions.items(.data)[@backingInt(inst)];
    if (vector.lowers(cg, inst)) return true;
    return switch (ir.instructions.items(.tag)[@backingInt(inst)]) {
        .arg, .alloc, .block, .loop, .repeat, .br, .cond_br, .switch_br, .dbg_stmt, .dbg_inline_begin, .dbg_inline_end => true,
        .load, .store, .struct_field_ptr, .struct_field_val, .ptr_elem_ptr, .slice_elem_ptr, .ptr_add => true,
        .ptr_elem_val, .slice_elem_val, .array_elem_val, .slice_ptr, .slice_len, .slice, .vector_store_elem => true,
        .is_null, .is_non_null, .is_err, .is_non_err, .optional_payload, .optional_payload_ptr, .optional_payload_ptr_set, .wrap_optional => true,
        .unwrap_errunion_payload, .unwrap_errunion_err, .unwrap_errunion_payload_ptr, .unwrap_errunion_err_ptr, .errunion_payload_ptr_set => true,
        .wrap_errunion_payload, .wrap_errunion_err, .aggregate_init, .union_init, .get_union_tag, .set_union_tag => true,
        .memcpy, .memmove, .memset, .int_from_bool, .int_from_ptr, .ret_addr, .frame_addr => true,
        .save_err_return_trace_index, .err_return_trace, .set_err_return_trace => true,
        // Integers in a register, and f32 and f64, have instructions.
        .add_wrap, .sub_wrap, .mul_wrap, .bit_and, .bit_or, .xor, .shl, .shr, .div_trunc, .div_floor, .div_ceil => cg.nativeScalar(cg.typeOf(data.bin_op.lhs)),
        // A float remainder calls fmod.
        .rem, .mod => cg.inGpr(cg.typeOf(data.bin_op.lhs)),
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => cg.nativeScalar(cg.typeOf(data.bin_op.lhs)),
        .add_float, .sub_float, .mul_float, .div_float, .min_float, .max_float => cg.nativeScalar(cg.typeOf(data.bin_op.lhs)),
        .neg_float, .abs_float, .sqrt => cg.nativeScalar(cg.typeOf(data.un_op)),
        .add_with_overflow, .sub_with_overflow, .mul_with_overflow => cg.nativeScalar(cg.typeOf(ir.extraData(Ir.Bin, data.ty_pl.payload).data.lhs)),
        .not, .intcast, .trunc => cg.nativeScalar(data.ty_op.ty) and cg.nativeScalar(cg.typeOf(data.ty_op.operand)),
        // Bitcasts copy.
        .bitcast => true,
        .floor, .ceil, .round, .trunc_float => cg.fpType(cg.typeOf(data.un_op)) != null,
        .mul_add => cg.fpType(cg.typeOf(data.pl_op.operand)) != null,
        .float_cast => cvtType(Type.floatBits(cg.ip, data.ty_op.ty)) != null and cvtType(Type.floatBits(cg.ip, cg.typeOf(data.ty_op.operand))) != null,
        .float_from_int => cg.fpType(data.ty_op.ty) != null and Type.intInfo(cg.ip, cg.typeOf(data.ty_op.operand)).bits <= 64,
        .int_from_float => cg.fpType(cg.typeOf(data.ty_op.operand)) != null and Type.intInfo(cg.ip, data.ty_op.ty).bits <= 64,
        else => false,
    };
}

/// Whether `ty`'s scalar operations lower to instructions (`callFree`):
/// integers in a general-purpose register, f32, and f64.
fn nativeScalar(cg: *CodeGen, ty: Index) bool {
    if (cg.isFloat(ty)) return Type.floatBits(cg.ip, ty) == 32 or Type.floatBits(cg.ip, ty) == 64;
    return cg.inGpr(ty);
}

/// As `inFloat`, for a vector only call-clobbered registers hold
/// (`Ssa.want_vec`): 16 bytes or fewer of lanes (`vector.Shape`), not
/// bool vectors, which are bits.
pub fn inVec(cg: *CodeGen, ty: Index) bool {
    return vector.inVreg(cg.ip, ty);
}

/// The operand whose register value `inst` may take when the operand dies
/// there (`Live.tie`): the first of the lowerings that read every operand
/// before they write the result register, or write it once from all of
/// them (`binOp`, `condFlags`, loads, `elemAddrTo`, the float
/// instructions with native registers).
fn tiedOperand(cg: *CodeGen, inst: Inst.Index) u32 {
    const data = cg.ir.instructions.items(.data)[@backingInt(inst)];
    const ref: Ref = switch (cg.ir.instructions.items(.tag)[@backingInt(inst)]) {
        .add_wrap, .sub_wrap, .mul_wrap, .bit_and, .bit_or, .xor, .shl, .shr, .div_trunc, .div_floor, .div_ceil, .rem, .mod => data.bin_op.lhs,
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => data.bin_op.lhs,
        .not, .load, .float_cast => data.ty_op.operand,
        .add_float, .sub_float, .mul_float, .div_float, .min_float, .max_float => data.bin_op.lhs,
        .neg_float, .abs_float, .sqrt => data.un_op,
        .ptr_elem_ptr, .ptr_add => cg.ir.extraData(Ir.Bin, data.ty_pl.payload).data.lhs,
        else => return Ssa.no_tie,
    };
    return if (ref.toIndex()) |i| @backingInt(i) else Ssa.no_tie;
}

pub fn termClobbers(_: *CodeGen, _: Ssa.Block.Index) bool {
    return false;
}

/// Whether variables of type `ty` are promoted to two registers
/// (`Ssa.plan`): never, as no value has two registers yet.
pub fn inPair(_: *CodeGen, _: Index) bool {
    return false;
}

/// As `inPair`, for one floating-point register: f32 and f64.
pub fn inFloat(cg: *CodeGen, ty: Index) bool {
    if (Type.class(cg.ip, ty) != .float) return false;
    const bits = Type.floatBits(cg.ip, ty);
    return bits == 32 or bits == 64;
}

/// `Ssa.plan`'s hook for intervals the architecture lengthens: none
/// here, since no address is folded into its users yet.
pub fn lengthenIntervals(_: *CodeGen) void {}

/// Whether `ty`'s values fit a general-purpose register.
pub fn inGpr(cg: *CodeGen, ty: Index) bool {
    const ip = cg.ip;
    return switch (Type.class(ip, ty)) {
        .bool => true,
        .int => Type.intInfo(ip, ty).bits -% 1 < 64,
        .pointer => !Type.isSlice(ip, ty),
        .optional => Type.optionalReprIsPtr(ip, Type.childType(ip, ty)),
        .error_set, .@"enum" => cg.passInRegs(ty),
        else => false,
    };
}

/// Whether condition `inst` can be computed by the branch it decides.
pub fn fusable(cg: *CodeGen, inst: Inst.Index) bool {
    const data = cg.ir.instructions.items(.data)[@backingInt(inst)];
    return switch (cg.ir.instructions.items(.tag)[@backingInt(inst)]) {
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => blk: {
            const ty = cg.typeOf(data.bin_op.lhs);
            break :blk !cg.isFloat(ty) and !cg.isWideInt(ty) and cg.passInRegs(ty);
        },
        .is_err, .is_non_err, .is_null, .is_non_null, .cmp_lt_errors_len => true,
        .reduce => vector.fusable(cg, inst),
        else => false,
    };
}

/// Whether an overflow operation on integers of `bits` bits leaves its
/// overflow in one condition of the flags (`overflowOp`): adds and subs,
/// a compare of the truncated result, or of a 64-bit product's high half.
pub fn ovfFlagsOnly(_: *CodeGen, tag: Inst.Tag, bits: u16) bool {
    return tag != .mul_with_overflow or bits <= 32 or bits == 64;
}

/// The memory of a result slot. For a value in a register, a scratch slot
/// that `flushResults` moves to the register when the instruction's code
/// is done, after it read its operands.
pub fn resultMem(cg: *CodeGen, inst: Inst.Index, ty: Index) Error!?Mem {
    if (cg.homes[@backingInt(inst)] == .reg or cg.homes[@backingInt(inst)] == .vreg) {
        if (!Type.hasRuntimeBits(cg.ip, ty)) return null;
        const m = if (cg.homes[@backingInt(inst)] == .vreg) try cg.tempSlot16() else try cg.tempSlot();
        try cg.pending.append(cg.gpa, .{ .inst = inst, .mem = m });
        return m;
    }
    return switch (try cg.slotFor(inst, ty)) {
        .slot => |m| m,
        else => null,
    };
}

fn passInRegs(cg: *CodeGen, ty: Index) bool {
    const size = Type.abiSize(cg.ip, ty);
    return size == 1 or size == 2 or size == 4 or size == 8;
}

fn callsPreserveNone(cg: *CodeGen) bool {
    const ir = cg.ir;
    for (cg.ssa.values.items(.inst)) |inst| {
        if (ir.instructions.items(.tag)[@backingInt(inst)] != .call) continue;
        const callee = ir.instructions.items(.data)[@backingInt(inst)].pl_op.operand;
        if (cg.calleeType(callee).cc == .aarch64_preserve_none) return true;
    }
    return false;
}

/// The size of the outgoing argument area: the most any call's stack
/// arguments need.
fn outgoingArgsSize(cg: *CodeGen) u32 {
    const ip = cg.ip;
    const ir = cg.ir;
    var max: u32 = 0;
    var tys: [32]Index = undefined;
    for (cg.ssa.values.items(.inst)) |inst| {
        if (ir.instructions.items(.tag)[@backingInt(inst)] != .call) continue;
        const data = ir.instructions.items(.data)[@backingInt(inst)];
        const extra = ir.extraData(Ir.Call, data.pl_op.payload);
        const args = ir.refSlice(extra.end, extra.data.args_len);
        const callee_ty = cg.calleeType(data.pl_op.operand);
        var stack: u32 = 0;
        var i: usize = 0;
        while (i < args.len) {
            const n = @min(args.len - i, tys.len);
            for (args[i..][0..n], tys[0..n]) |a, *t| t.* = cg.typeOf(a);
            // Arguments past the first 32 all go on the stack: count them
            // at their largest.
            if (i == 0) {
                stack = if (isC(callee_ty.cc)) cg.cArgs(callee_ty.cc, tys[0..n], if (callee_ty.is_var_args) callee_ty.param_types.len else null, null) else cg.autoArgs(tys[0..n], null);
            } else for (tys[0..n]) |t| {
                stack = std.mem.alignForward(u32, stack, 16) + @as(u32, @intCast(std.mem.alignForward(u64, Type.abiSize(ip, t), 16)));
            }
            i += n;
        }
        max = @max(max, stack);
    }
    return std.mem.alignForward(u32, max, 16);
}

/// The call whose result `ret` operand `v` is, as in the x86_64 backend's
/// `retCall`: a call of an `.auto` function that returns it in memory, as
/// it is, through bitcasts between error unions of one payload type, or as
/// the payload of an error union.
fn retCall(cg: *CodeGen, v0: Inst.Index) ?Inst.Index {
    const ir = cg.ir;
    const ip = cg.ip;
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    var v = v0;
    while (true) switch (tags[@backingInt(v)]) {
        .call => {
            const extra = ir.extraData(Ir.Call, datas[@backingInt(v)].pl_op.payload);
            if (extra.data.flags.always_tail) return null;
            if (cg.calleeType(datas[@backingInt(v)].pl_op.operand).cc != .auto or cg.autoClass(ir.typeOfIndex(v, ip)) != .memory) return null;
            return v;
        },
        .bitcast => {
            const src = datas[@backingInt(v)].ty_op.operand.toIndex() orelse return null;
            const a = ir.typeOfIndex(src, ip);
            const b = datas[@backingInt(v)].ty_op.ty;
            if (a != b and (ip.keyTag(a) != .error_union_type or ip.keyTag(b) != .error_union_type or
                ip.keyPayload(.error_union_type, a).payload_type != ip.keyPayload(.error_union_type, b).payload_type)) return null;
            v = src;
        },
        // `return try f(x)`: the payload is unwrapped where it is wrapped.
        .wrap_errunion_payload, .unwrap_errunion_payload => v = datas[@backingInt(v)].ty_op.operand.toIndex() orelse return null,
        else => return null,
    };
}

/// After allocation, in an `.auto` function that returns in memory: a
/// call whose result a `ret` returns (`retCall`) gets the function's own
/// result memory as its result (`Home.result`), and so do the values
/// between them, as in the x86_64 backend's `planRetCalls`: each level of
/// `return f(x)` held one more copy of a large result. The result's memory
/// holds one such value at a time.
fn planRetCalls(cg: *CodeGen) Error!void {
    if (cg.fn_ty.cc != .auto or cg.autoClass(cg.fn_ty.return_type) != .memory) return;
    const f = cg.ssa;
    const ir = cg.ir;
    const ip = cg.ip;
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    const live = f.live.slice();
    const def = live.items(.def);
    const end = live.items(.end);
    const fates = live.items(.fate);
    const Chain = struct { ret_val: Inst.Index, call: Inst.Index, lo: u32, hi: u32, ok: bool };
    var chains: std.ArrayList(Chain) = .empty;
    defer chains.deinit(cg.gpa);
    for (f.layout.items) |block| {
        const b = f.blocks.items[@backingInt(block)];
        if (b.term.tag != .ret) continue;
        const o = datas[@backingInt(b.term.inst)].un_op.toIndex() orelse continue;
        const c = cg.retCall(o) orelse continue;
        var v = o;
        var hi: u32 = 0;
        var off: u32 = 0;
        const ok = while (true) {
            const vi = @backingInt(v);
            if (tags[vi] == .wrap_errunion_payload) off += @intCast(Type.errorUnionLayout(ip, datas[vi].ty_op.ty).payload_offset);
            if (tags[vi] == .unwrap_errunion_payload) {
                const p: u32 = @intCast(Type.errorUnionLayout(ip, ir.typeOf(datas[vi].ty_op.operand, ip)).payload_offset);
                if (off < p) break false;
                off -= p;
            }
            if (fates[vi] != .normal or cg.homes[vi] != .none) break false;
            hi = @max(hi, end[vi]);
            if (v == c) break true;
            v = datas[vi].ty_op.operand.toIndex().?;
        };
        if (ok) try chains.append(cg.gpa, .{ .ret_val = o, .call = c, .lo = def[@backingInt(c)], .hi = hi, .ok = true });
    }
    for (chains.items, 0..) |*x, i| for (chains.items[i + 1 ..]) |*y| {
        if (x.call != y.call and x.lo <= y.hi and y.lo <= x.hi) {
            x.ok = false;
            y.ok = false;
        }
    };
    for (chains.items) |x| {
        if (!x.ok) continue;
        var v = x.ret_val;
        var off: u32 = 0;
        while (true) {
            cg.homes[@backingInt(v)] = .{ .result = off };
            if (v == x.call) break;
            if (tags[@backingInt(v)] == .wrap_errunion_payload) off += @intCast(Type.errorUnionLayout(ip, datas[@backingInt(v)].ty_op.ty).payload_offset);
            if (tags[@backingInt(v)] == .unwrap_errunion_payload) off -= @intCast(Type.errorUnionLayout(ip, ir.typeOf(datas[@backingInt(v)].ty_op.operand, ip)).payload_offset);
            v = datas[@backingInt(v)].ty_op.operand.toIndex().?;
        }
    }
}

fn calleeType(cg: *CodeGen, callee: Ref) InternPool.FuncType {
    const ip = cg.ip;
    const ty = cg.typeOf(callee);
    return ip.keyPayload(.func_type, if (Type.class(ip, ty) == .pointer) Type.ptrInfo(ip, ty).child else ty);
}

// ---------------------------------------------------------------- `.auto`

/// How `.auto` passes a value: in one or two general registers (x0-x7,
/// the value's bytes; one register holds a value of 1, 2, 4, or 8 bytes
/// extended like a load), in a vector register (v0-v7: floats of 16, 32,
/// and 64 bits, and vectors of 2 to 16 bytes, `autoVec`), or in memory
/// (arguments in the outgoing area, in 8-byte aligned slots; results
/// through the pointer in x8).
const AutoClass = enum { none, gpr, gpr_pair, fpr, memory };

fn autoClass(cg: *CodeGen, ty: Index) AutoClass {
    const ip = cg.ip;
    if (Type.class(ip, ty) == .float) return switch (Type.floatBits(ip, ty)) {
        16, 32, 64 => .fpr,
        else => .memory,
    };
    if (cg.autoVec(ty)) return .fpr;
    const size = Type.abiSize(ip, ty);
    return if (size == 0) .none else if (size <= 8) .gpr else if (size <= 16) .gpr_pair else .memory;
}

/// Whether `.auto` passes `ty` in a vector register as its bytes: a
/// vector of 2 bytes or more that the vector registers hold (`inVec`),
/// or a struct whose one runtime field is such a vector, as `crypto.aes`
/// wraps its blocks.
fn autoVec(cg: *CodeGen, ty: Index) bool {
    const ip = cg.ip;
    const size = Type.abiSize(ip, ty);
    if (size < 2) return false;
    if (cg.inVec(ty)) return true;
    if (ip.keyTag(ty) != .struct_type or Type.isPacked(ip, ty)) return false;
    const info = ip.structInfo(ty);
    var only: ?Index = null;
    for (info.field_types, 0..) |ft, i| {
        if (info.fieldIsComptime(i) or !Type.hasRuntimeBits(ip, ft)) continue;
        if (only != null) return false;
        only = ft;
    }
    const f = only orelse return false;
    return Type.abiSize(ip, f) == size and cg.autoVec(f);
}

const ArgLoc = union(enum) {
    none,
    gpr: u8,
    gpr_pair: u8,
    fpr: u8,
    /// C: a homogeneous float aggregate's members in v`first`... (`Hfa`).
    fpr_run: struct { first: u8, n: u8, size: u8 },
    /// C: a vector's `n` bools (`CClass.bool_split`), in x`gp` to x7, then
    /// in stack slots of `slot` bytes from `stack`.
    bool_split: BoolSplit,
    stack: u32,
    /// C: a copy of the value, passed by its address in a register or on
    /// the stack.
    gpr_indirect: u8,
    stack_indirect: u32,
};

const BoolSplit = struct {
    n: u8,
    gp: u8,
    slot: u8,
    stack: u32,

    fn inRegs(b: BoolSplit) u8 {
        return @min(b.n, 8 - b.gp);
    }
};

/// Where `.auto` passes each argument; returns the stack bytes used.
/// `locs` may be null to only count.
fn autoArgs(cg: *CodeGen, tys: []const Index, locs: ?[]ArgLoc) u32 {
    var gp: u8 = 0;
    var fp: u8 = 0;
    var stack: u32 = 0;
    for (tys, 0..) |ty, i| {
        var l: ArgLoc = switch (cg.autoClass(ty)) {
            .none => .none,
            .gpr => if (gp < 8) blk: {
                gp += 1;
                break :blk .{ .gpr = gp - 1 };
            } else .{ .stack = 0 },
            .gpr_pair => if (gp < 7) blk: {
                gp += 2;
                break :blk .{ .gpr_pair = gp - 2 };
            } else .{ .stack = 0 },
            .fpr => if (fp < 8) blk: {
                fp += 1;
                break :blk .{ .fpr = fp - 1 };
            } else .{ .stack = 0 },
            .memory => .{ .stack = 0 },
        };
        if (l == .stack) {
            l = .{ .stack = stack };
            stack += @intCast(std.mem.alignForward(u64, Type.abiSize(cg.ip, ty), 8));
        }
        if (locs) |ls| ls[i] = l;
    }
    return stack;
}

// ---------------------------------------------------------------- C (AAPCS64: Apple's, and Linux's)

/// How the C convention passes a value: integers, pointers, and
/// aggregates of at most 8 bytes in a general register; of at most 16 in
/// two; f16, f32, and f64 in a vector register; larger aggregates by the
/// address of a copy (and results through x8). f128 is Linux's `long
/// double`, in a q register there; on Apple's, where C does not have it,
/// it goes as 16 bytes in two general registers, and so does f80 on both.
/// A homogeneous floating-point aggregate (`cHfa`) goes in consecutive
/// vector registers, one member each (`fpr_run`), and a vector of at most
/// 16 bytes in one, as upstream's `aarch64/abi.zig` classifies them; a
/// larger vector by the address of a copy.
/// A vector of 32 to 128 bools is passed as that many bools, each as an
/// argument of its own (`bool_split`), and returned in memory, as LLVM
/// lowers `<N x i1>` (upstream's c_abi tests and Clang's `ext_vector_type`
/// bools agree).
const CClass = enum { none, int, int_pair, fpr, fpr_run, bool_split, indirect, unsupported };

fn cClass(cg: *CodeGen, ty: Index) CClass {
    const ip = cg.ip;
    if (!Type.hasRuntimeBits(ip, ty)) return .none;
    const size = Type.abiSize(ip, ty);
    switch (Type.class(ip, ty)) {
        .float => return switch (Type.floatBits(ip, ty)) {
            16, 32, 64 => .fpr,
            128 => if (ip.target == .aarch64_linux) .fpr else .int_pair,
            // No C type here (`long double` is a double): compiler_rt's
            // soft-float ABI takes these as 16-byte structs
            // (`compilerRtFloatAbi`).
            else => .int_pair,
        },
        // A vector register holds 2 to 16 bytes; a 1-byte vector (of up
        // to 8 bools) goes as an integer.
        .vector => {
            const v = ip.keyPayload(.vector_type, ty);
            if (v.child == .bool_type and v.len >= 32 and v.len <= 128) return .bool_split;
            return if (size > 16) .indirect else if (size >= 2) .fpr else .int;
        },
        .@"struct", .@"union" => if (cg.cHfa(ty) != null) return .fpr_run,
        else => {},
    }
    return if (size <= 8) .int else if (size <= 16) .int_pair else .indirect;
}

/// `cClass` for a result: a split bool vector is returned in memory.
fn cRetClass(cg: *CodeGen, ty: Index) CClass {
    const c = cg.cClass(ty);
    return if (c == .bool_split) .indirect else c;
}

/// A homogeneous floating-point aggregate: `n` (1 to 4) floats of `size`
/// bytes each, laid out back to back.
const Hfa = struct { n: u8, size: u8 };

/// `ty` as a homogeneous floating-point aggregate, or null: a non-packed
/// struct or union of floats of one width (f16, f32, f64, f128), nested
/// structs and unions of them included, as upstream's `countFloats`:
/// each struct field at the offset the members before it fill, at most 4
/// members, and no padding. Arrays are not members, as upstream's.
fn cHfa(cg: *CodeGen, ty: Index) ?Hfa {
    const ip = cg.ip;
    if (!Type.hasRuntimeBits(ip, ty)) return .{ .n = 0, .size = 0 };
    switch (Type.class(ip, ty)) {
        .float => return switch (Type.floatBits(ip, ty)) {
            16, 32, 64, 128 => |bits| .{ .n = 1, .size = @intCast(bits / 8) },
            else => null,
        },
        .@"struct", .@"union" => {},
        else => return null,
    }
    if (Type.isPacked(ip, ty)) return null;
    const is_union = Type.class(ip, ty) == .@"union";
    const info = ip.structInfo(ty);
    var r: Hfa = .{ .n = 0, .size = 0 };
    for (info.field_types, 0..) |ft, i| {
        if (!is_union and Type.fieldOffset(ip, ty, i) != @as(u64, r.size) * r.n) return null;
        const f = cg.cHfa(ft) orelse return null;
        if (r.n == 0 and r.size == 0) {
            r.size = f.size;
        } else if (r.size != f.size) return null;
        if (is_union) {
            r.n = @max(r.n, f.n);
        } else {
            if (f.n > 4 - r.n) return null;
            r.n += f.n;
        }
    }
    if (Type.abiSize(ip, ty) != @as(u64, r.size) * r.n) return null;
    return r;
}

/// Where the C convention passes each argument; returns the stack bytes
/// used. Arguments from index `var_from` on are variadic, which Apple
/// passes on the stack in 8-byte slots. Apple packs other stack arguments
/// at their natural alignment (aggregates at 8). Linux passes variadic
/// arguments as named ones, and each stack argument in its own slot of a
/// multiple of 8 bytes, aligned to 8 or to 16 for 16-byte aligned values.
/// `locs` may be null.
fn cArgs(cg: *CodeGen, cc: InternPool.CallingConvention, tys: []const Index, var_from: ?usize, locs: ?[]ArgLoc) u32 {
    const ip = cg.ip;
    const linux = ip.target == .aarch64_linux;
    const n_gpr = cGprs(cc).len;
    var gp: u8 = 0;
    var fp: u8 = 0;
    var stack: u32 = 0;
    for (tys, 0..) |ty, i| {
        const class = cg.cClass(ty);
        const size: u32 = @intCast(Type.abiSize(ip, ty));
        const alignment: u32 = @intCast(Type.abiAlignment(ip, ty));
        var l: ArgLoc = .none;
        if (linux) {
            const slot = std.mem.alignForward(u32, stack, @max(8, @min(alignment, 16)));
            switch (class) {
                .none, .unsupported => {},
                .int, .indirect => if (gp < n_gpr) {
                    l = if (class == .int) .{ .gpr = cGprs(cc)[gp] } else .{ .gpr_indirect = cGprs(cc)[gp] };
                    gp += 1;
                } else {
                    l = if (class == .int) .{ .stack = slot } else .{ .stack_indirect = slot };
                    stack = slot + if (class == .int) std.mem.alignForward(u32, size, 8) else 8;
                },
                .int_pair => {
                    if (alignment == 16 and Type.class(ip, ty) != .float) gp = std.mem.alignForward(u8, gp, 2);
                    if (gp + 2 <= 8) {
                        l = .{ .gpr_pair = gp };
                        gp += 2;
                    } else {
                        gp = 8;
                        l = .{ .stack = slot };
                        stack = slot + 16;
                    }
                },
                .fpr => if (fp < 8) {
                    l = .{ .fpr = fp };
                    fp += 1;
                } else {
                    l = .{ .stack = slot };
                    stack = slot + std.mem.alignForward(u32, size, 8);
                },
                .fpr_run => {
                    const h = cg.cHfa(ty).?;
                    if (fp + h.n <= 8) {
                        l = .{ .fpr_run = .{ .first = fp, .n = h.n, .size = h.size } };
                        fp += h.n;
                    } else {
                        fp = 8;
                        l = .{ .stack = slot };
                        stack = slot + std.mem.alignForward(u32, size, 8);
                    }
                },
                .bool_split => {
                    const b: BoolSplit = .{ .n = @intCast(ip.keyPayload(.vector_type, ty).len), .gp = gp, .slot = 8, .stack = std.mem.alignForward(u32, stack, 8) };
                    l = .{ .bool_split = b };
                    gp += b.inRegs();
                    if (b.n > b.inRegs()) stack = b.stack + 8 * @as(u32, b.n - b.inRegs());
                },
            }
        } else if (var_from != null and i >= var_from.?) {
            if (class != .none) {
                const slot_size: u32 = if (class == .indirect) 8 else size;
                stack = std.mem.alignForward(u32, stack, @max(8, @min(alignment, 16)));
                l = if (class == .indirect) .{ .stack_indirect = stack } else .{ .stack = stack };
                stack += std.mem.alignForward(u32, slot_size, 8);
            }
        } else switch (class) {
            .none, .unsupported => {},
            .int => if (gp < n_gpr) {
                l = .{ .gpr = cGprs(cc)[gp] };
                gp += 1;
            } else {
                const a = if (Type.isInt(ip, ty) or Type.class(ip, ty) == .pointer) alignment else 8;
                stack = std.mem.alignForward(u32, stack, a);
                l = .{ .stack = stack };
                stack += if (a == 8) std.mem.alignForward(u32, size, 8) else size;
            },
            .int_pair => {
                // A 16-byte aligned integer starts at an even register; a
                // float's struct (`cClass`) is 8-byte aligned.
                const even = alignment == 16 and Type.class(ip, ty) != .float;
                if (even) gp = std.mem.alignForward(u8, gp, 2);
                if (gp + 2 <= 8) {
                    l = .{ .gpr_pair = gp };
                    gp += 2;
                } else {
                    gp = 8;
                    stack = std.mem.alignForward(u32, stack, if (even) 16 else 8);
                    l = .{ .stack = stack };
                    stack += 16;
                }
            },
            .fpr => if (fp < 8) {
                l = .{ .fpr = fp };
                fp += 1;
            } else {
                stack = std.mem.alignForward(u32, stack, alignment);
                l = .{ .stack = stack };
                stack += size;
            },
            // Darwin's stack bools take 4 bytes each, as Clang passes them.
            .bool_split => {
                const b: BoolSplit = .{ .n = @intCast(ip.keyPayload(.vector_type, ty).len), .gp = gp, .slot = 4, .stack = std.mem.alignForward(u32, stack, 4) };
                l = .{ .bool_split = b };
                gp += b.inRegs();
                stack = b.stack + 4 * @as(u32, b.n - b.inRegs());
            },
            // An aggregate, at 8 on the stack, as `.int`'s.
            .fpr_run => {
                const h = cg.cHfa(ty).?;
                if (fp + h.n <= 8) {
                    l = .{ .fpr_run = .{ .first = fp, .n = h.n, .size = h.size } };
                    fp += h.n;
                } else {
                    fp = 8;
                    stack = std.mem.alignForward(u32, stack, @max(8, @min(alignment, 16)));
                    l = .{ .stack = stack };
                    stack += std.mem.alignForward(u32, size, 8);
                }
            },
            .indirect => if (gp < n_gpr) {
                l = .{ .gpr_indirect = cGprs(cc)[gp] };
                gp += 1;
            } else {
                stack = std.mem.alignForward(u32, stack, 8);
                l = .{ .stack_indirect = stack };
                stack += 8;
            },
        }
        if (locs) |ls| ls[i] = l;
    }
    return std.mem.alignForward(u32, stack, 8);
}

/// The C conventions: the target's, and `aarch64_preserve_none`.
fn isC(cc: InternPool.CallingConvention) bool {
    return cc == .c or cc == .aarch64_preserve_none;
}

/// The general registers convention `cc` passes integer arguments in, in
/// order. LLVM's preserve_none takes x9-x14 after x0-x7 too, which bs's
/// argument moves use as scratch registers, so bs passes at most 17
/// integers in registers with it (`cArgsSupported`).
fn cGprs(cc: InternPool.CallingConvention) []const u8 {
    return if (cc == .aarch64_preserve_none) &.{ 20, 21, 22, 23, 24, 25, 26, 27, 28, 0, 1, 2, 3, 4, 5, 6, 7 } else &.{ 0, 1, 2, 3, 4, 5, 6, 7 };
}

/// Fails for the arguments of convention `cc` that bs cannot pass yet:
/// with `aarch64_preserve_none`, values in two general registers or many
/// bools, more than 17 integers, and variadic arguments.
fn cArgsSupported(cg: *CodeGen, cc: InternPool.CallingConvention, tys: []const Index, var_args: bool) Error!void {
    if (cc != .aarch64_preserve_none) return;
    if (var_args) return cg.fail("variadic functions with calling convention 'aarch64_preserve_none'", .{});
    var n: usize = 0;
    for (tys) |ty| switch (cg.cClass(ty)) {
        .int, .indirect => n += 1,
        .int_pair, .bool_split => return cg.fail("passing '{f}' with calling convention 'aarch64_preserve_none'", .{cg.fmtType(ty)}),
        else => {},
    };
    if (n > 17) return cg.fail("more than 17 integer arguments with calling convention 'aarch64_preserve_none'", .{});
}

fn argReg(i: u8) Reg {
    return @fromBackingInt(@intCast(i));
}

fn argVReg(i: u8) VReg {
    return @fromBackingInt(@intCast(i));
}

/// The callee side: gives each `arg` a home, storing register arguments
/// to slots.
fn setupParams(cg: *CodeGen) Error!void {
    const ip = cg.ip;
    const ir = cg.ir;
    const tags = ir.instructions.items(.tag);
    const is_c = isC(cg.fn_ty.cc);
    if (!is_c) {
        // The error return trace pointer arrives in x15; a function that
        // neither reads it nor calls drops it.
        const needs_trace = for (cg.ssa.values.items(.inst)) |inst| switch (tags[@backingInt(inst)]) {
            .call, .err_return_trace, .save_err_return_trace_index => break true,
            else => {},
        } else false;
        if (needs_trace) {
            cg.trace_slot = try cg.allocSlot(8, 8);
            try cg.storeReg(cg.trace_slot.?, .x15, 8);
        }
    }
    const ret_ty = cg.fn_ty.return_type;
    if (if (is_c) cg.cRetClass(ret_ty) == .indirect else cg.autoClass(ret_ty) == .memory) {
        cg.ret_ptr_slot = try cg.allocSlot(8, 8);
        try cg.storeReg(cg.ret_ptr_slot.?, .x8, 8);
    }
    if (is_c and cg.cClass(ret_ty) == .unsupported) return cg.fail("returning '{f}' from a C function", .{cg.fmtType(ret_ty)});
    // `arg` instructions are at the start of the main body.
    var n: usize = 0;
    for (ir.mainBody()) |inst| {
        if (tags[@backingInt(inst)] != .arg) break;
        n += 1;
    }
    const args = ir.mainBody()[0..n];
    const tys = try cg.gpa.alloc(Index, n);
    defer cg.gpa.free(tys);
    const locs = try cg.gpa.alloc(ArgLoc, n);
    defer cg.gpa.free(locs);
    for (args, tys) |inst, *ty| ty.* = ir.instructions.items(.data)[@backingInt(inst)].arg.ty;
    if (is_c) {
        for (tys) |ty| if (cg.cClass(ty) == .unsupported) return cg.fail("C parameter of type '{f}'", .{cg.fmtType(ty)});
        try cg.cArgsSupported(cg.fn_ty.cc, tys, false);
        cg.va_stack = cg.cArgs(cg.fn_ty.cc, tys, null, locs);
    } else _ = cg.autoArgs(tys, locs);
    for (args, tys, locs) |inst, ty, l| {
        const size = Type.abiSize(ip, ty);
        // Only scalars of 1, 2, 4, or 8 bytes have registers.
        if (cg.homes[@backingInt(inst)] == .reg) switch (l) {
            .gpr => |r| {
                try cg.setResult(inst, ty, argReg(r));
                continue;
            },
            .stack => |off| {
                try cg.loadKnown(cg.homes[@backingInt(inst)].reg, .at(.fp, @intCast(16 + off)), ty);
                continue;
            },
            else => unreachable,
        };
        if (cg.homes[@backingInt(inst)] == .vreg and cg.inVec(ty)) {
            const v = cg.homes[@backingInt(inst)].vreg;
            switch (l) {
                .fpr => |a| {
                    try vector.move(cg, v, argVReg(a));
                    continue;
                },
                .stack => |off| {
                    try vector.loadMem(cg, v, .at(.fp, @intCast(16 + off)), @intCast(size));
                    continue;
                },
                // A 1-byte vector, in a general register.
                else => {},
            }
        } else if (cg.homes[@backingInt(inst)] == .vreg) {
            const v = cg.homes[@backingInt(inst)].vreg;
            switch (l) {
                .fpr => |a| try cg.loadFp(v, .{ .ty = ty, .loc = .{ .vreg = argVReg(a) } }),
                .gpr => |r| try cg.setResult(inst, ty, argReg(r)),
                .stack => |off| try cg.loadFp(v, memVal(ty, .at(.fp, @intCast(16 + off)))),
                else => unreachable,
            }
            continue;
        }
        switch (l) {
            .none => {},
            .gpr => |r| try cg.storeBytes((try cg.resultMem(inst, ty)).?, argReg(r), size),
            .gpr_pair => |r| {
                const m = (try cg.resultMem(inst, ty)).?;
                try cg.storeReg(m, argReg(r), 8);
                try cg.storeBytes(m.plus(8), argReg(r + 1), size - 8);
            },
            .fpr => |v| try cg.storeFp((try cg.resultMem(inst, ty)).?, argVReg(v), size),
            .fpr_run => |run| try cg.storeFpRun((try cg.resultMem(inst, ty)).?, run.first, run.n, run.size),
            .bool_split => |b| try cg.gatherBools((try cg.resultMem(inst, ty)).?, b, size),
            .stack => |off| cg.homes[@backingInt(inst)] = .{ .slot = .at(.fp, @intCast(16 + off)) },
            .gpr_indirect => |r| {
                // The callee owns the caller's copy, but a slot keeps every
                // home sp- or fp-based.
                try cg.e.mov(.x, .x12, argReg(r));
                try cg.copyMem((try cg.resultMem(inst, ty)).?, .at(.x12, 0), size);
            },
            .stack_indirect => |off| {
                try cg.loadMem(.x12, .at(.fp, @intCast(16 + off)), .usize_type);
                try cg.copyMem((try cg.resultMem(inst, ty)).?, .at(.x12, 0), size);
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Operands

pub fn typeOf(cg: *CodeGen, ref: Ref) Index {
    return cg.ir.typeOf(ref, cg.ip);
}

pub fn locOf(cg: *CodeGen, ref: Ref) Error!Loc {
    if (ref.toIndex()) |inst| return switch (cg.homes[@backingInt(inst)]) {
        .none => .none,
        .slot => |m| .{ .mem = m },
        .frame_addr => |m| .{ .addr = m },
        .reg => |r| .{ .reg = r },
        .vreg => |v| .{ .vreg = v },
        .result => |off| blk: {
            try cg.loadMem(.x8, cg.ret_ptr_slot.?, .usize_type);
            break :blk .{ .mem = .at(.x8, @intCast(off)) };
        },
    };
    return cg.constLoc(ref.toInterned().?);
}

fn valOf(cg: *CodeGen, ref: Ref) Error!Val {
    return .{ .ty = cg.typeOf(ref), .loc = try cg.locOf(ref) };
}

fn memVal(ty: Index, m: Mem) Val {
    return .{ .ty = ty, .loc = .{ .mem = m } };
}

fn constLoc(cg: *CodeGen, val: Index) Error!Loc {
    const ip = cg.ip;
    const ty = ip.typeOf(val);
    if (!Type.hasRuntimeBits(ip, ty)) return .none;
    switch (ip.indexToKey(val)) {
        .undef => if (cg.passInRegs(ty)) {
            // The 0xaa bytes of its size, extended as a load extends them.
            const bits: u6 = @intCast(Type.abiSize(ip, ty) * 8 % 64);
            const v: u64 = 0xaaaa_aaaa_aaaa_aaaa;
            if (bits == 0) return .{ .imm = v };
            if (cg.signed(ty)) return .{ .imm = @bitCast(@as(i64, @bitCast(v << @intCast(64 - @as(u7, bits)))) >> @intCast(64 - @as(u7, bits))) };
            return .{ .imm = v >> @intCast(64 - @as(u7, bits)) };
        },
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
            // The address of an extern function is in its link slot.
            if (p.base == .uav and ip.keyTag(p.base.uav.val) == .extern_func and p.byte_offset == 0) {
                const f = ip.keyPayload(.extern_func, p.base.uav.val);
                const name = ip.stringSlice(f.name);
                _ = try cg.emit.requestCompilerRtExport(name);
                return .{ .mem = .sym(try cg.emit.useExtern(name, f.is_weak), 0) };
            }
            if (ptrToZeroBit(ip, val)) return .{ .imm = 0xaaaaaaaaaaaaaaaa };
            const t = try Emit.ptrTarget(cg.emit, val);
            // The address of extern data, or into it, is in its link slot.
            if (t.ext) |n| {
                const name = ip.stringSlice(n);
                _ = try cg.emit.requestCompilerRtExport(name);
                return .{ .mem = .sym(try cg.emit.useExtern(try cg.emit.externSlotName(name, t.off), false), 0) };
            }
            return .{ .addr = .sym(t.key, @intCast(t.off)) };
        },
        .opt => |o| if (Type.optionalReprIsPtr(ip, Type.childType(ip, ty))) {
            if (o.val == .none) return .{ .imm = 0 };
            return cg.constLoc(o.val);
        },
        else => {},
    }
    return .{ .mem = .sym(try cg.emit.uavKey(val, 0), 0) };
}

/// Whether pointer value `ptr` points into a declaration or constant
/// without runtime bits (not a function or extern), which has no symbol:
/// such a pointer is undefined bytes (as in the x86_64 backend).
fn ptrToZeroBit(ip: *const InternPool, ptr: Index) bool {
    var v = ptr;
    while (true) {
        const p = ip.keyPayload(.ptr, v);
        switch (p.base) {
            .field => |f| v = f.base,
            .elem => |e| v = e.base,
            .nav => |n| {
                const nav = ip.getNav(n);
                if (nav.linkage == .@"extern") return false;
                // By its type: a declaration whose address code took may
                // have only its type resolved (`Zcu.ensureNavTy`) until
                // `analyzeAll` resolves its value.
                return Type.class(ip, nav.ty) != .@"fn" and !Type.hasRuntimeBits(ip, nav.ty);
            },
            .uav => |u| return switch (ip.keyTag(u.val)) {
                .func, .extern_func, .extern_var => false,
                else => !Type.hasRuntimeBits(ip, ip.typeOf(u.val)),
            },
            else => return false,
        }
    }
}

/// The 64-bit extended bits of an integer value.
pub fn intBits(ip: *const InternPool, val: Index) u64 {
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

fn sizeOf(bytes: u64) Size {
    return switch (bytes) {
        1 => .byte,
        2 => .half,
        4 => .word,
        8 => .dword,
        else => unreachable,
    };
}

/// Whether `[base, #off]` encodes for an access of `bytes` bytes: the
/// unscaled signed 9-bit form or the scaled unsigned 12-bit one.
fn fitsOffset(off: i64, bytes: u32) bool {
    if (off >= -256 and off < 256) return true;
    return off >= 0 and @rem(off, bytes) == 0 and @divExact(off, bytes) < 4096;
}

/// `m` as the operand of an access of `bytes` bytes, computing its address
/// into `scratch` if no addressing form reaches it.
pub fn access(cg: *CodeGen, m: Mem, bytes: u32, scratch: Reg) Error!Encoder.Mem {
    switch (m.base) {
        .sym => |k| {
            try cg.e.loadAddr(scratch, k, m.off);
            return .at(scratch, 0);
        },
        .reg => |r| {
            if (fitsOffset(m.off, bytes)) return .at(r, m.off);
            try cg.addImm(scratch, r, m.off);
            return .at(scratch, 0);
        },
    }
}

/// `d = base + off`. Uses x17 for offsets of 2^24 or more.
fn addImm(cg: *CodeGen, d: Reg, base: Reg, off: i64) Error!void {
    const op: Encoder.AddOp = if (off < 0) .sub else .add;
    const mag: u64 = @abs(off);
    if (mag >= 1 << 24) {
        assert(base != .x17);
        try cg.e.movImm(.x, .x17, mag);
        return cg.e.addSub(op, .x, d, base, .r(.x17));
    }
    if (mag == 0) {
        if (d != base) try cg.e.mov(.x, d, base);
        return;
    }
    var src = base;
    if (mag >> 12 != 0) {
        try cg.e.addSub(op, .x, d, src, .{ .imm = @intCast(mag & 0xfff000) });
        src = d;
    }
    if (mag & 0xfff != 0) try cg.e.addSub(op, .x, d, src, .{ .imm = @intCast(mag & 0xfff) });
}

/// `reg = &m`.
fn addrTo(cg: *CodeGen, reg: Reg, m: Mem) Error!void {
    switch (m.base) {
        .sym => |k| try cg.e.loadAddr(reg, k, m.off),
        .reg => |r| try cg.addImm(reg, r, m.off),
    }
}

pub fn load(cg: *CodeGen, reg: Reg, ref: Ref) Error!void {
    try cg.loadVal(reg, try cg.valOf(ref));
}

/// The register holding scalar `ref`: its own, or `scratch` loaded with it.
fn use(cg: *CodeGen, ref: Ref, scratch: Reg) Error!Reg {
    const v = try cg.valOf(ref);
    if (v.loc == .reg) return v.loc.reg;
    try cg.loadVal(scratch, v);
    return scratch;
}

/// The register value `inst` is computed in: its own, or `scratch` for
/// `setResult` to store.
fn resultReg(cg: *CodeGen, inst: Inst.Index, scratch: Reg) Reg {
    return switch (cg.homes[@backingInt(inst)]) {
        .reg => |r| r,
        else => scratch,
    };
}

/// Loads a value of at most 8 bytes into `reg`, extended to 64 bits by its
/// type. Uses only `reg`.
fn loadVal(cg: *CodeGen, reg: Reg, v: Val) Error!void {
    switch (v.loc) {
        .none => try cg.e.movImm(.x, reg, 0),
        .imm => |x| try cg.e.movImm(.x, reg, x),
        .addr => |m| try cg.addrTo(reg, m),
        .err => |name| try cg.e.movWideValue(.movz, .x, reg, try cg.emit.useError(name), 0),
        .mem => |m| try cg.loadKnown(reg, m, v.ty),
        .reg => |r| if (r != reg) try cg.e.mov(.x, reg, r),
        .vreg => |r| if (cg.inVec(v.ty))
            try cg.loadMem(reg, try cg.valMem(v), v.ty)
        else if (Type.abiSize(cg.ip, v.ty) == 8)
            try cg.e.fmovToGpr(.x, reg, .f64, r)
        else
            try cg.e.fmovToGpr(.w, reg, .f32, r),
    }
}

/// Loads a value of type `ty` from memory that may have been written as
/// another type. An integer whose width is not a whole number of bytes is
/// extended from its width: memory written as another type of its size (an
/// unsigned twin through a pointer cast, a packed union's other field, raw
/// bytes) may hold other bits above it, which the value does not include,
/// as upstream's LLVM loads.
fn loadMem(cg: *CodeGen, reg: Reg, m: Mem, ty: Index) Error!void {
    const size = Type.abiSize(cg.ip, ty);
    const c = Type.class(cg.ip, ty);
    const bits = if (c == .int or c == .@"enum") Type.intInfo(cg.ip, ty).bits else 0;
    if (bits == 0 or bits >= 64 or bits == size * 8) return cg.loadKnown(reg, m, ty);
    try cg.e.ldr(sizeOf(size), reg, try cg.access(m, @intCast(size), reg));
    try cg.e.bitfield(if (cg.signed(ty)) .sbfm else .ubfm, .x, reg, reg, 0, @intCast(bits - 1));
}

/// Loads a value of type `ty` from memory that a register of that type
/// wrote, extended (a value's slot or an argument slot), so a narrow
/// integer needs no extending from its width.
fn loadKnown(cg: *CodeGen, reg: Reg, m: Mem, ty: Index) Error!void {
    const size = Type.abiSize(cg.ip, ty);
    switch (size) {
        1, 2, 4, 8 => {
            const a = try cg.access(m, @intCast(size), reg);
            if (size < 8 and cg.signed(ty)) {
                try cg.e.ldrs(sizeOf(size), .x, reg, a);
            } else {
                try cg.e.ldr(sizeOf(size), reg, a);
            }
        },
        else => return cg.fail("loading a {d}-byte value into a register", .{size}),
    }
}

/// Stores the low `size` (1, 2, 4, or 8) bytes of `reg` to `m`. Uses x16.
pub fn storeReg(cg: *CodeGen, m: Mem, reg: Reg, size: u64) Error!void {
    if (size == 0) return;
    assert(reg != .x16);
    try cg.e.str(sizeOf(size), reg, try cg.access(m, @intCast(size), .x16));
}

/// Loads the `n` bytes (1 to 8) at `m` into `reg`, zero-extended. Uses x13
/// for sizes that take more than one load.
fn loadBytes(cg: *CodeGen, reg: Reg, m: Mem, n: u64) Error!void {
    switch (n) {
        1, 2, 4, 8 => return cg.e.ldr(sizeOf(n), reg, try cg.access(m, @intCast(n), reg)),
        else => {},
    }
    var off: u64 = 0;
    while (off < n) {
        const chunk: u64 = if (n - off >= 4) 4 else if (n - off >= 2) 2 else 1;
        const dst: Reg = if (off == 0) reg else .x13;
        try cg.e.ldr(sizeOf(chunk), dst, try cg.access(m.plus(off), @intCast(chunk), .x16));
        if (off != 0) try cg.e.logic(.orr, .x, reg, reg, .{ .reg = .{ .reg = .x13, .amount = @intCast(off * 8) } });
        off += chunk;
    }
}

/// Stores the low `n` bytes (1 to 8) of `reg` to `m`. Uses x13 and x16.
fn storeBytes(cg: *CodeGen, m: Mem, reg: Reg, n: u64) Error!void {
    switch (n) {
        0 => return,
        1, 2, 4, 8 => return cg.storeReg(m, reg, n),
        else => {},
    }
    try cg.e.mov(.x, .x13, reg);
    var off: u64 = 0;
    while (off < n) {
        const chunk: u64 = if (n - off >= 4) 4 else if (n - off >= 2) 2 else 1;
        try cg.storeReg(m.plus(off), .x13, chunk);
        off += chunk;
        if (off < n) try cg.e.shiftImm(.lsr, .x, .x13, .x13, @intCast(chunk * 8));
    }
}

/// Copies the value `ref` to `dst`. Uses x9, x10, x16, x17, v30, and v31;
/// `dst` must not be based on those.
fn copyTo(cg: *CodeGen, dst: Mem, ref: Ref) Error!void {
    try cg.copyVal(dst, try cg.valOf(ref));
}

fn copyVal(cg: *CodeGen, dst: Mem, v: Val) Error!void {
    const size = Type.abiSize(cg.ip, v.ty);
    if (size == 0) return;
    switch (v.loc) {
        .none => {},
        .mem => |src| try cg.copyMem(dst, src, size),
        .reg => |r| try cg.storeReg(dst, r, size),
        .vreg => |r| try vector.storeMem(cg, dst, r, @intCast(size)),
        .imm => |x| if (cg.passInRegs(v.ty)) {
            if (x == 0) return cg.storeReg(dst, .zr, size);
            try cg.e.movImm(.x, .x9, x);
            try cg.storeReg(dst, .x9, size);
        } else {
            // An undefined aggregate.
            try cg.fillMem(dst, size, 0xaa);
        },
        .addr, .err => {
            try cg.loadVal(.x9, v);
            try cg.storeReg(dst, .x9, size);
        },
    }
}

/// Copies `size` bytes. Uses x9, x10, x16, x17, v30, and v31: 16 bytes
/// at a time through q registers, the rest through x10.
fn copyMem(cg: *CodeGen, dst: Mem, src: Mem, size: u64) Error!void {
    if (size == 0) return;
    var s = src;
    var d = dst;
    if (s.base == .sym) {
        try cg.e.loadAddr(.x16, s.base.sym, s.off);
        s = .at(.x16, 0);
    }
    if (d.base == .sym) {
        try cg.e.loadAddr(.x17, d.base.sym, d.off);
        d = .at(.x17, 0);
    }
    var left = size;
    if (size > 128) {
        try cg.addrTo(.x16, s);
        try cg.addrTo(.x17, d);
        try cg.e.movImm(.x, .x9, size / 32);
        const top = try cg.e.newLabel();
        cg.e.bind(top);
        try cg.e.ldpQ(.v30, .v31, .{ .base = .x16, .offset = .{ .post = 32 } });
        try cg.e.stpQ(.v30, .v31, .{ .base = .x17, .offset = .{ .post = 32 } });
        try cg.e.addSub(.subs, .x, .x9, .x9, .{ .imm = 1 });
        try cg.e.bcond(.ne, top);
        s = .at(.x16, 0);
        d = .at(.x17, 0);
        left = size % 32;
    }
    var off: u64 = 0;
    while (left - off >= 16) : (off += 16) {
        try cg.e.ldrQ(.v31, try cg.access(s.plus(off), 16, .x16));
        try cg.e.strQ(.v31, try cg.access(d.plus(off), 16, .x17));
    }
    while (off < left) {
        const chunk: u64 = if (left - off >= 8) 8 else if (left - off >= 4) 4 else if (left - off >= 2) 2 else 1;
        try cg.e.ldr(sizeOf(chunk), .x10, try cg.access(s.plus(off), @intCast(chunk), .x16));
        try cg.e.str(sizeOf(chunk), .x10, try cg.access(d.plus(off), @intCast(chunk), .x17));
        off += chunk;
    }
}

/// Fills `size` bytes with `byte`. Uses x9, x10, x16, x17, and v31: 16
/// bytes at a time from a q register, the rest from x10.
fn fillMem(cg: *CodeGen, dst: Mem, size: u64, byte: u8) Error!void {
    if (size == 0) return;
    var d = dst;
    if (d.base == .sym) {
        try cg.e.loadAddr(.x17, d.base.sym, d.off);
        d = .at(.x17, 0);
    }
    var pattern: u64 = byte;
    pattern *%= 0x0101_0101_0101_0101;
    const r: Reg = if (pattern == 0) .zr else .x10;
    if (pattern != 0) try cg.e.movImm(.x, .x10, pattern);
    if (size >= 16) {
        if (pattern == 0) {
            try cg.e.raw(0x6f00e400 | 31); // movi v31.2d, #0
        } else {
            try cg.e.raw(0x4e010c00 | 10 << 5 | 31); // dup v31.16b, w10
        }
    }
    var left = size;
    if (size > 128) {
        try cg.addrTo(.x17, d);
        try cg.e.movImm(.x, .x9, size / 32);
        const top = try cg.e.newLabel();
        cg.e.bind(top);
        try cg.e.stpQ(.v31, .v31, .{ .base = .x17, .offset = .{ .post = 32 } });
        try cg.e.addSub(.subs, .x, .x9, .x9, .{ .imm = 1 });
        try cg.e.bcond(.ne, top);
        d = .at(.x17, 0);
        left = size % 32;
    }
    var off: u64 = 0;
    while (left - off >= 16) : (off += 16) {
        try cg.e.strQ(.v31, try cg.access(d.plus(off), 16, .x16));
    }
    while (off < left) {
        const chunk: u64 = if (left - off >= 8) 8 else if (left - off >= 4) 4 else if (left - off >= 2) 2 else 1;
        try cg.e.str(sizeOf(chunk), r, try cg.access(d.plus(off), @intCast(chunk), .x16));
        off += chunk;
    }
}

/// The memory holding value `ref`, materializing a constant into a
/// scratch slot if needed.
pub fn memOf(cg: *CodeGen, ref: Ref) Error!Mem {
    return cg.valMem(try cg.valOf(ref));
}

fn valMem(cg: *CodeGen, v: Val) Error!Mem {
    if (v.loc == .mem) return v.loc.mem;
    if (v.loc == .reg) {
        const m = try cg.tempSlot();
        try cg.copyVal(m, v);
        return m;
    }
    if (v.loc == .vreg) {
        const m = try cg.tempSlot16();
        try vector.storeMem(cg, m, v.loc.vreg, @intCast(Type.abiSize(cg.ip, v.ty)));
        return m;
    }
    const m = try cg.allocSlot(Type.abiSize(cg.ip, v.ty), Type.abiAlignment(cg.ip, v.ty));
    try cg.copyVal(m, v);
    return m;
}

/// Truncates the 64-bit value in `reg` to integer type `ty` and extends it
/// back, so it is normalized.
pub fn normalize(cg: *CodeGen, reg: Reg, ty: Index) Error!void {
    if (!Type.isInt(cg.ip, ty)) return; // bools stay 0 or 1
    const info = Type.intInfo(cg.ip, ty);
    if (info.bits >= 64) return;
    // A zero-bit integer's only value.
    if (info.bits == 0) return cg.e.movImm(.x, reg, 0);
    try cg.e.bitfield(if (info.signedness == .signed) .sbfm else .ubfm, .x, reg, reg, 0, @intCast(info.bits - 1));
}

/// Stores value `inst` of type `ty`, computed in `reg`, to its slot, or
/// moves it to its register, extended as a load of its type extends it.
pub fn setResult(cg: *CodeGen, inst: Inst.Index, ty: Index, reg: Reg) Error!void {
    if (cg.homes[@backingInt(inst)] == .vreg) {
        const v = cg.homes[@backingInt(inst)].vreg;
        if (Type.abiSize(cg.ip, ty) == 8) return cg.e.fmovFromGpr(.f64, v, .x, reg);
        return cg.e.fmovFromGpr(.f32, v, .w, reg);
    }
    if (cg.homes[@backingInt(inst)] == .reg) {
        const home = cg.homes[@backingInt(inst)].reg;
        // Computed in its register (`resultReg`), already extended.
        if (home == reg) return;
        const vty = cg.ir.typeOfIndex(inst, cg.ip);
        const size = Type.abiSize(cg.ip, vty);
        if (size == 8) {
            if (home != reg) try cg.e.mov(.x, home, reg);
        } else {
            try cg.e.bitfield(if (cg.signed(vty)) .sbfm else .ubfm, .x, home, reg, 0, @intCast(size * 8 - 1));
        }
        return;
    }
    const m = try cg.resultMem(inst, ty) orelse return;
    try cg.storeReg(m, reg, Type.abiSize(cg.ip, ty));
}

/// The memory pointer `ptr` points to. May use x12.
fn ptrMem(cg: *CodeGen, ptr: Ref) Error!Mem {
    switch (try cg.locOf(ptr)) {
        .addr => |m| return m,
        .reg => |r| return .at(r, 0),
        else => {
            try cg.load(.x12, ptr);
            return .at(.x12, 0);
        },
    }
}

/// The register of promoted variable `ptr` (`Ssa.plan`), if it is one
/// that has a register.
fn promoted(cg: *CodeGen, ptr: Ref) ?Reg {
    const p = ptr.toIndex() orelse return null;
    if (cg.ir.instructions.items(.tag)[@backingInt(p)] != .alloc) return null;
    return switch (cg.homes[@backingInt(p)]) {
        .reg => |r| r,
        else => null,
    };
}

/// As `promoted`, for a variable in a floating-point or vector register.
fn promotedV(cg: *CodeGen, ptr: Ref) ?VReg {
    const p = ptr.toIndex() orelse return null;
    if (cg.ir.instructions.items(.tag)[@backingInt(p)] != .alloc) return null;
    return switch (cg.homes[@backingInt(p)]) {
        .vreg => |v| v,
        else => null,
    };
}

/// `d = ptr + off`.
fn addrPlus(cg: *CodeGen, d: Reg, ptr: Ref, off: u64) Error!void {
    switch (try cg.locOf(ptr)) {
        .addr => |m| try cg.addrTo(d, m.plus(off)),
        else => {
            try cg.load(d, ptr);
            try cg.addImm(d, d, @intCast(off));
        },
    }
}

/// `d = base + index * size`, where `base` is a pointer or, if `is_slice`,
/// a slice. Uses x10 and x11; `d` is not one of them.
fn elemAddrTo(cg: *CodeGen, d: Reg, is_slice: bool, base: Ref, index: Ref, size: u64) Error!void {
    const b = if (is_slice) b: {
        try cg.loadMem(d, try cg.memOf(base), .usize_type);
        break :b d;
    } else try cg.use(base, d);
    if (size == 0) {
        if (b != d) try cg.e.mov(.x, d, b);
        return;
    }
    switch (try cg.locOf(index)) {
        .imm => |v| if (std.math.cast(i32, @as(i64, @bitCast(v)) *% @as(i64, @intCast(size)))) |off| return cg.addImm(d, b, off),
        else => {},
    }
    const i = try cg.use(index, .x10);
    if (std.math.isPowerOfTwo(size) and size <= 1 << 32) {
        return cg.e.addSub(.add, .x, d, b, .{ .reg = .{ .reg = i, .amount = @intCast(std.math.log2_int(u64, size)) } });
    }
    try cg.e.movImm(.x, .x11, size);
    try cg.e.mulAdd(.madd, .x, d, i, .x11, b);
}

/// `reg += index * size`. Uses x11.
fn scaleAdd(cg: *CodeGen, reg: Reg, index: Reg, size: u64) Error!void {
    if (size == 0) return;
    if (std.math.isPowerOfTwo(size) and size <= 1 << 32) {
        return cg.e.addSub(.add, .x, reg, reg, .{ .reg = .{ .reg = index, .amount = @intCast(std.math.log2_int(u64, size)) } });
    }
    try cg.e.movImm(.x, .x11, size);
    try cg.e.mulAdd(.madd, .x, reg, index, .x11, reg);
}

// ---------------------------------------------------------------------------
// Instructions

/// Emits the SSA blocks in `Ssa.order`: the others in layout order, then
/// the cold ones, each with the debug state it has in place.
fn emitBlocks(cg: *CodeGen) Error!void {
    const f = cg.ssa;
    const order = f.order.items;
    for (cg.labels) |*l| l.* = try cg.e.newLabel();
    var k: usize = 0;
    for (f.layout.items, 0..) |block, i| {
        if (!f.emits(i, block)) continue;
        if (f.cold.items[@backingInt(block)]) {
            try cg.cold_starts.append(cg.gpa, .{ .line = cg.dbg_line, .column = cg.dbg_column, .open_start = @intCast(cg.cold_open.items.len), .open_len = @intCast(cg.dbg_open.items.len) });
            try cg.cold_open.appendSlice(cg.gpa, cg.dbg_open.items);
            continue;
        }
        k += 1;
        try cg.genBlock(block, if (k < order.len) order[k] else .none);
    }
    if (k == order.len) return;
    cg.in_cold = true;
    cg.dbg_open.clearRetainingCapacity();
    for (order[k..], cg.cold_starts.items, k..) |block, s, i| {
        const pc: u32 = @intCast(cg.e.code.items.len);
        for (cg.cold_open.items[s.open_start..][0..s.open_len]) |o| {
            var copy = cg.dbg_inlines.items[o.index];
            copy.low = pc;
            copy.high = pc;
            copy.parent = if (cg.dbg_open.getLastOrNull()) |p| p.index else Atom.Debug.Inline.none;
            try cg.dbg_inline_callees.append(cg.gpa, cg.dbg_inline_callees.items[o.index]);
            try cg.dbg_open.append(cg.gpa, .{ .index = @intCast(cg.dbg_inlines.items.len), .line = o.line, .column = o.column, .backend = o.backend });
            try cg.dbg_inlines.append(cg.gpa, copy);
        }
        if (cg.dbg_open.getLastOrNull()) |o| {
            try cg.e.switchLines(cg.dbg_inlines.items[o.index].file, o.index + 1);
        } else {
            try cg.e.switchLines(0, 0);
        }
        cg.dbg_line = s.line;
        cg.dbg_column = s.column;
        try cg.e.line(s.line, s.column);
        try cg.genBlock(block, if (i + 1 < order.len) order[i + 1] else .none);
        const end: u32 = @intCast(cg.e.code.items.len);
        for (cg.dbg_open.items) |o| cg.dbg_inlines.items[o.index].high = end;
        cg.dbg_open.clearRetainingCapacity();
    }
}

/// Requests the declarations and external symbols that the constant
/// operands of `inst`, which the SSA removed, point to, as if the code
/// were generated (as in the x86_64 backend).
fn keepSymbols(cg: *CodeGen, inst: Inst.Index) Error!void {
    var refs: std.ArrayList(Ref) = .empty;
    defer refs.deinit(cg.gpa);
    const Collect = struct {
        refs: *std.ArrayList(Ref),
        gpa: Allocator,
        failed: *bool,
        pub fn use(c: @This(), ref: Ref) void {
            if (ref.toInterned() != null) c.refs.append(c.gpa, ref) catch {
                c.failed.* = true;
            };
        }
    };
    var failed = false;
    Ssa.forEachOperand(cg.ir, inst, Collect{ .refs = &refs, .gpa = cg.gpa, .failed = &failed });
    if (failed) return error.OutOfMemory;
    const ip = cg.ip;
    for (refs.items) |ref| {
        var v = ref.toInterned().?;
        if (ip.keyTag(v) == .opt) v = ip.keyPayload(.opt, v).val;
        if (v == .none or ip.keyTag(v) != .ptr or Type.isSlice(ip, ip.typeOf(v)) or ptrToZeroBit(ip, v)) continue;
        var root = v;
        while (true) switch (ip.keyPayload(.ptr, root).base) {
            .field => |f| root = f.base,
            .elem => |e| root = e.base,
            else => break,
        };
        switch (ip.keyPayload(.ptr, root).base) {
            .nav => |n| if (ip.getNav(n).linkage != .@"extern") {
                _ = try Emit.ptrTarget(cg.emit, v);
            },
            .uav => |u| switch (ip.keyTag(u.val)) {
                .extern_var => _ = try cg.emit.useExtern(ip.stringSlice(ip.keyPayload(.extern_var, u.val).name), false),
                .extern_func => {
                    const f = ip.keyPayload(.extern_func, u.val);
                    _ = try cg.emit.useExtern(ip.stringSlice(f.name), f.is_weak);
                },
                else => {},
            },
            else => {},
        }
    }
}

fn genBlock(cg: *CodeGen, block: Ssa.Block.Index, next: Ssa.Block.Index) Error!void {
    cg.e.bind(cg.labels[@backingInt(block)]);
    cg.block = block;
    cg.tmp_next = 0;
    cg.tmp16_next = 0;
    for (cg.ssa.blockInsts(block)) |inst| {
        if (cg.fate(inst) != .dead) {
            const calls = cg.e.calls;
            try cg.genInst(inst);
            // A call clobbers v20-v29: only clobber points may make one.
            assert(!cg.vregs or cg.e.calls == calls or !cg.callFree(inst));
            try cg.flushResults();
        } else try cg.keepSymbols(inst);
    }
    try cg.genTerm(cg.ssa.blocks.items[@backingInt(block)].term, next);
}

fn checkNaked(cg: *CodeGen, tag: Inst.Tag) Error!void {
    if (cg.fn_ty.cc == .naked) switch (tag) {
        .assembly, .trap, .unreach, .dbg_stmt, .dbg_inline_begin, .dbg_inline_end => {},
        else => return cg.fail("'{t}' in a naked function", .{tag}),
    };
}

/// Emits a block's terminator; `next` is the block after it in the layout.
fn genTerm(cg: *CodeGen, term: Ssa.Term, next: Ssa.Block.Index) Error!void {
    const ir = cg.ir;
    const tag = ir.instructions.items(.tag)[@backingInt(term.inst)];
    const data = ir.instructions.items(.data)[@backingInt(term.inst)];
    switch (term.tag) {
        .noreturn => {},
        .fallthrough => try cg.jumpTo(term.succ[0], next),
        .jump => {
            try cg.checkNaked(tag);
            if (tag == .br) try cg.brResult(data.br);
            try cg.jumpTo(term.succ[0], next);
        },
        .branch => {
            try cg.checkNaked(tag);
            // A threaded `br` writes its block's result first.
            if (tag == .br) try cg.brResult(data.br);
            const cond = Ssa.branchCond(ir, term);
            const fused = if (cond.toIndex()) |c| cg.fate(c) == .fused else false;
            const fall = cg.ssa.fwd.items[term.succ[1]] == next;
            if (fused) {
                const cc = try cg.condFlags(cond.toIndex().?);
                if (fall) return cg.e.bcond(cc, cg.blockLabel(term.succ[0]));
                try cg.e.bcond(cc.negate(), cg.blockLabel(term.succ[1]));
            } else {
                const c = try cg.use(cond, .x9);
                if (fall) return cg.e.cbz(true, .x, c, cg.blockLabel(term.succ[0]));
                try cg.e.cbz(false, .x, c, cg.blockLabel(term.succ[1]));
            }
            try cg.jumpTo(term.succ[0], next);
        },
        .switch_br => {
            try cg.checkNaked(tag);
            if (try cg.switchBr(data, term)) try cg.jumpTo(term.succ[1], next);
        },
        .ret => {
            try cg.checkNaked(tag);
            try cg.ret(data.un_op);
        },
        // As LLVM lowers `@trap` and `unreachable` on arm64.
        .unreach => try cg.e.brk(1),
    }
}

/// Writes a `br`'s operand to its block's result.
fn brResult(cg: *CodeGen, br: @FieldType(Inst.Data, "br")) Error!void {
    switch (cg.homes[@backingInt(br.block_inst)]) {
        .slot => |m| try cg.copyTo(m, br.operand),
        else => {},
    }
}

fn jumpTo(cg: *CodeGen, target: u32, next: Ssa.Block.Index) Error!void {
    if (cg.ssa.fwd.items[target] != next) try cg.e.b(.{ .label = cg.blockLabel(target) });
}

fn blockLabel(cg: *CodeGen, target: u32) Encoder.Label {
    return cg.labels[@backingInt(cg.ssa.fwd.items[target])];
}

/// Branches to the case holding the operand's value; the else block
/// follows. Cases with constant values are sorted and lowered as a binary
/// search over them, with a jump table for each dense enough run and
/// compares with immediates at the leaves (`switch_br.lower`). Items whose
/// values only the linker knows (error codes) and wide integers get a
/// compare and branch per item, in order. Returns whether the code falls
/// through to what follows, the jump to the else block.
fn switchBr(cg: *CodeGen, data: Inst.Data, term: Ssa.Term) Error!bool {
    const ir = cg.ir;
    const extra = ir.extraData(Ir.SwitchBr, data.pl_op.payload);
    const op_ty = cg.typeOf(data.pl_op.operand);
    const wide = cg.isWideInt(op_ty);
    const blocks = cg.ssa.switchCases(term, extra.data.cases_len);
    if (!wide) sorted: {
        var cases: std.ArrayList(switch_br.Case) = .empty;
        defer cases.deinit(cg.gpa);
        const flip: u64 = if (cg.signed(op_ty)) @as(u64, 1) << 63 else 0;
        var it = ir.switchCases(data.pl_op.payload);
        for (blocks) |case_block| {
            const c = it.next().?;
            const label = cg.blockLabel(@backingInt(case_block));
            for (c.items) |item| {
                const v = switch (try cg.locOf(item)) {
                    .imm => |v| v,
                    else => break :sorted,
                };
                try cases.append(cg.gpa, .{ .lo = v ^ flip, .hi = v ^ flip, .label = @backingInt(label) });
            }
            var k: usize = 0;
            while (k < c.ranges.len) : (k += 2) {
                const lo = (try cg.locOf(c.ranges[k])).imm;
                const hi = (try cg.locOf(c.ranges[k + 1])).imm;
                try cases.append(cg.gpa, .{ .lo = lo ^ flip, .hi = hi ^ flip, .label = @backingInt(label) });
            }
        }
        try cg.load(.x9, data.pl_op.operand);
        const else_label = cg.blockLabel(term.succ[1]);
        const em: SwitchEmit = .{ .cg = cg, .flip = flip, .else_label = else_label };
        const b = switch_br.bounds(Type.abiSize(cg.ip, op_ty), flip != 0);
        return switch_br.lower(cg.gpa, em, switch_br.prepare(cases.items), b[0], b[1], @backingInt(else_label));
    }
    if (!wide) try cg.load(.x9, data.pl_op.operand);
    // Ranges only on integers of at most 64 bits, sorted above.
    var it = ir.switchCases(data.pl_op.payload);
    for (blocks) |case_block| {
        const c = it.next().?;
        const label = cg.blockLabel(@backingInt(case_block));
        for (c.items) |item| {
            if (wide) {
                try cg.wideEq(data.pl_op.operand, item);
                try cg.e.cbz(false, .x, .x9, label);
                continue;
            }
            try cg.cmpOperand(.x9, item);
            try cg.e.bcond(.eq, label);
        }
    }
    return true;
}

/// Emits `switch_br.lower`'s steps for a switch on the value in x9. Uses
/// x10, x11, x16, and x17.
const SwitchEmit = struct {
    cg: *CodeGen,
    /// The sign bit, for a signed operand: a key is the value with it
    /// flipped.
    flip: u64,
    else_label: Encoder.Label,

    pub fn newLabel(s: SwitchEmit) Error!u32 {
        return @backingInt(try s.cg.e.newLabel());
    }

    pub fn bind(s: SwitchEmit, l: u32) void {
        s.cg.e.bind(@fromBackingInt(l));
    }

    pub fn jump(s: SwitchEmit, l: u32) Error!void {
        try s.cg.e.b(.{ .label = @fromBackingInt(l) });
    }

    /// `cmp r, #v`, through x10 when `v` is no immediate.
    fn cmpImm(s: SwitchEmit, r: Reg, v: u64) Error!void {
        const cg = s.cg;
        if (v < 4096) return cg.e.cmp(.x, r, .{ .imm = @intCast(v) });
        if (-%v < 4096) return cg.e.cmn(.x, r, .{ .imm = @intCast(-%v) });
        try cg.e.movImm(.x, .x10, v);
        try cg.e.cmp(.x, r, .r(.x10));
    }

    pub fn branch(s: SwitchEmit, key: u64, cond: std.math.CompareOperator, l: u32, again: bool) Error!void {
        if (!again) try s.cmpImm(.x9, key ^ s.flip);
        const is_signed = s.flip != 0;
        const cc: Encoder.Cond = switch (cond) {
            .lt => if (is_signed) .lt else .lo,
            .lte => if (is_signed) .le else .ls,
            .eq => .eq,
            .gte => if (is_signed) .ge else .hs,
            else => unreachable,
        };
        try s.cg.e.bcond(cc, @fromBackingInt(l));
    }

    /// The register holding the key minus `lo` (as values), whose keys
    /// `lo` through `lo + n` are then 0 through n unsigned: x9 itself when
    /// `lo` is 0, else x11.
    fn offset(s: SwitchEmit, lo: u64) Error!Reg {
        const cg = s.cg;
        const v = lo ^ s.flip;
        if (v == 0) return .x9;
        if (v < 4096) {
            try cg.e.addSub(.sub, .x, .x11, .x9, .{ .imm = @intCast(v) });
        } else if (-%v < 4096) {
            try cg.e.addSub(.add, .x, .x11, .x9, .{ .imm = @intCast(-%v) });
        } else {
            try cg.e.movImm(.x, .x11, v);
            try cg.e.addSub(.sub, .x, .x11, .x9, .r(.x11));
        }
        return .x11;
    }

    pub fn branchIn(s: SwitchEmit, lo: u64, hi: u64, l: u32) Error!void {
        const r = try s.offset(lo);
        try s.cmpImm(r, hi - lo);
        try s.cg.e.bcond(.ls, @fromBackingInt(l));
    }

    /// 32-bit offsets of the targets from the table, which follows the
    /// indirect branch.
    pub fn table(s: SwitchEmit, cases: []const switch_br.Case, lo: u64, hi: u64, check: bool, out: u32) Error!void {
        const cg = s.cg;
        const r = try s.offset(lo);
        if (check) {
            try s.cmpImm(r, hi - lo);
            try cg.e.bcond(.hi, @fromBackingInt(out));
        }
        const tab = try cg.e.newLabel();
        try cg.e.adr(.x16, tab);
        try cg.e.ldrs(.word, .x, .x17, .{ .base = .x16, .offset = .{ .index = .{ .reg = r, .scaled = true } } });
        try cg.e.addSub(.add, .x, .x16, .x16, .r(.x17));
        try cg.e.br(.x16);
        cg.e.bind(tab);
        var k = lo;
        for (cases) |c| {
            while (k < c.lo) : (k += 1) try cg.e.labelDelta(s.else_label, tab);
            while (true) : (k += 1) {
                try cg.e.labelDelta(@fromBackingInt(c.label), tab);
                if (k == c.hi) break;
            }
            k += 1;
        }
    }
};

/// `cmp lhs, ref`, with `ref` as an immediate when it fits. Uses x10.
fn cmpOperand(cg: *CodeGen, lhs: Reg, ref: Ref) Error!void {
    switch (try cg.locOf(ref)) {
        .imm => |v| {
            if (v < 4096) return cg.e.cmp(.x, lhs, .{ .imm = @intCast(v) });
            const neg = -%v;
            if (neg < 4096) return cg.e.cmn(.x, lhs, .{ .imm = @intCast(neg) });
        },
        else => {},
    }
    try cg.e.cmp(.x, lhs, .r(try cg.use(ref, .x10)));
}

/// Emits a value, from its IR instruction.
fn genInst(cg: *CodeGen, inst: Inst.Index) Error!void {
    const ip = cg.ip;
    const ir = cg.ir;
    const tag = ir.instructions.items(.tag)[@backingInt(inst)];
    const data = ir.instructions.items(.data)[@backingInt(inst)];
    try cg.checkNaked(tag);
    if (vector.lowers(cg, inst)) return vector.gen(cg, inst, tag, data);
    switch (tag) {
        .arg => {},
        .comptime_tick, .comptime_quota, .comptime_dep, .comptime_effect, .comptime_exit => unreachable,
        // Vector-only, lowered in vector.zig.
        .cmp_vector, .reduce, .min_int, .max_int, .select, .shuffle => unreachable,
        .dbg_stmt => {
            cg.dbg_line = data.dbg_stmt.line;
            cg.dbg_column = data.dbg_stmt.column;
            try cg.e.line(data.dbg_stmt.line, data.dbg_stmt.column);
        },
        .dbg_inline_begin => try cg.beginInline(data.dbg_inline.func, ir.extraData(Ir.DbgInline, data.dbg_inline.payload).data),
        .dbg_inline_end => try cg.endInline(),
        .alloc => {
            // A promoted variable in a register needs no memory.
            if (data.ty == .none or cg.homes[@backingInt(inst)] == .reg or cg.homes[@backingInt(inst)] == .vreg) return;
            const info = Type.ptrInfo(ip, data.ty);
            const size = @max(Type.abiSize(ip, info.child), 1);
            const alignment = @max(Type.abiAlignment(ip, info.child), if (info.flags.alignment == 0) 1 else @as(u64, 1) << @intCast(info.flags.alignment - 1));
            if (alignment <= 16) {
                cg.homes[@backingInt(inst)] = .{ .frame_addr = try cg.allocSlot(size, alignment) };
                return;
            }
            // sp is only 16-byte aligned: align the address at run time
            // within a buffer large enough for any sp, and keep it in a slot.
            const buf = try cg.allocSlot(size + alignment - 16, 16);
            const home = try cg.allocSlot(8, 8);
            try cg.addrTo(.x9, buf.plus(alignment - 16));
            try cg.e.logic(.@"and", .x, .x9, .x9, .{ .imm = -%alignment });
            try cg.storeReg(home, .x9, 8);
            cg.homes[@backingInt(inst)] = .{ .slot = home };
        },
        .load => {
            const ty = data.ty_op.ty;
            // A forwarded constant is the value stored (`Live.fwd`), whose
            // interval `Ssa.plan` extended over the load's.
            if (cg.live) {
                const w = cg.ssa.live.items(.fwd)[@backingInt(inst)];
                if (w != Ssa.no_tie) {
                    cg.homes[@backingInt(inst)] = cg.homes[w];
                    return;
                }
            }
            // A load of a promoted variable is a move, or nothing when it
            // shares the variable's register (`Live.share`).
            if (cg.promotedV(data.ty_op.operand)) |v| {
                if (cg.inVec(ty)) {
                    if (cg.homes[@backingInt(inst)] == .vreg) return vector.move(cg, cg.homes[@backingInt(inst)].vreg, v);
                    return vector.storeMem(cg, (try cg.resultMem(inst, ty)) orelse return, v, @intCast(Type.abiSize(ip, ty)));
                }
                if (cg.homes[@backingInt(inst)] == .vreg and cg.homes[@backingInt(inst)].vreg == v) return;
                return cg.setFpResult(inst, ty, v);
            }
            if (cg.promoted(data.ty_op.operand)) |v| {
                if (cg.homes[@backingInt(inst)] == .reg and cg.homes[@backingInt(inst)].reg == v) return;
                return cg.setResult(inst, ty, v);
            }
            if (cg.homes[@backingInt(inst)] == .vreg and cg.inVec(ty))
                return vector.loadMem(cg, cg.homes[@backingInt(inst)].vreg, try cg.ptrMem(data.ty_op.operand), @intCast(Type.abiSize(ip, ty)));
            if (cg.passInRegs(ty)) {
                const m = try cg.ptrMem(data.ty_op.operand);
                if (cg.homes[@backingInt(inst)] == .reg) return cg.loadMem(cg.homes[@backingInt(inst)].reg, m, ty);
                if (cg.homes[@backingInt(inst)] == .vreg) return cg.loadFp(cg.homes[@backingInt(inst)].vreg, memVal(ty, m));
                const d = cg.resultReg(inst, .x9);
                try cg.loadMem(d, m, ty);
                return cg.setResult(inst, ty, d);
            }
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.load(.x12, data.ty_op.operand);
            try cg.copyMem(dst, .at(.x12, 0), Type.abiSize(ip, ty));
        },
        .store => {
            const val = vector.stored(cg, data.bin_op.rhs);
            const size = Type.abiSize(ip, cg.typeOf(val));
            if (size == 0) return;
            if (cg.promoted(data.bin_op.lhs)) |v| return cg.load(v, val);
            if (cg.promotedV(data.bin_op.lhs)) |v| return if (cg.inVec(cg.typeOf(val))) vector.loadVec(cg, v, val) else cg.loadFp(v, try cg.valOf(val));
            const m = try cg.ptrMem(data.bin_op.lhs);
            if (val.toInterned()) |v| if (ip.keyTag(v) == .undef and !cg.passInRegs(cg.typeOf(val))) return cg.fillMem(m, size, 0xaa);
            try cg.copyTo(m, val);
        },

        .add_wrap, .sub_wrap, .mul_wrap, .bit_and, .bit_or, .xor, .shl, .shr, .div_trunc, .div_floor, .div_ceil, .rem, .mod => {
            const ty = cg.typeOf(data.bin_op.lhs);
            if (cg.isFloat(ty)) return cg.genFloat(inst, tag, data);
            if (cg.isWideInt(ty)) return cg.genWide(inst, tag, data);
            const d = cg.resultReg(inst, .x9);
            try cg.binOp(tag, ty, data.bin_op.lhs, data.bin_op.rhs, d);
            try cg.setResult(inst, ty, d);
        },
        .add_with_overflow, .sub_with_overflow, .mul_with_overflow => try cg.overflowOp(inst, tag, data),
        .add_float, .sub_float, .mul_float, .div_float, .min_float, .max_float, .neg_float, .abs_float => try cg.genFloat(inst, tag, data),
        .sqrt, .sin, .cos, .tan, .exp, .exp2, .log, .log2, .log10, .floor, .ceil, .round, .trunc_float => try cg.genFloat(inst, tag, data),
        .mul_add, .float_cast, .float_from_int, .int_from_float => try cg.genFloat(inst, tag, data),
        .not => {
            const ty = data.ty_op.ty;
            if (cg.isWideInt(ty)) return cg.genWide(inst, tag, data);
            const a = try cg.use(data.ty_op.operand, .x9);
            const d = cg.resultReg(inst, .x9);
            if (ty == .bool_type) {
                try cg.e.logic(.eor, .x, d, a, .{ .imm = 1 });
            } else {
                try cg.e.mvn(.x, d, a);
                try cg.normalize(d, ty);
            }
            try cg.setResult(inst, ty, d);
        },
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => {
            const ty = cg.typeOf(data.bin_op.lhs);
            if (cg.isFloat(ty)) return cg.genFloat(inst, tag, data);
            if (cg.isWideInt(ty)) return cg.genWide(inst, tag, data);
            try cg.genCond(inst);
        },
        .atomic_load => {
            const ty = data.ty_op.ty;
            const size = Type.abiSize(ip, ty);
            if (size == 0) return;
            if (size == 16) return cg.atomicLoad16(inst, ty, data.ty_op.operand);
            if (!cg.passInRegs(ty)) return cg.fail("atomic load of {d} bytes", .{size});
            try cg.load(.x12, data.ty_op.operand);
            try cg.e.ldar(sizeOf(size), .x9, .x12);
            try cg.setResult(inst, ty, .x9);
        },
        .atomic_store => {
            const size = Type.abiSize(ip, cg.typeOf(data.bin_op.rhs));
            if (size == 0) return;
            if (size == 16) return cg.atomicStore16(data.bin_op.lhs, data.bin_op.rhs);
            if (!cg.passInRegs(cg.typeOf(data.bin_op.rhs))) return cg.fail("atomic store of {d} bytes", .{size});
            try cg.load(.x12, data.bin_op.lhs);
            try cg.load(.x9, data.bin_op.rhs);
            try cg.e.stlr(sizeOf(size), .x9, .x12);
        },
        .atomic_rmw => try cg.atomicRmw(inst, data),
        .cmpxchg => {
            const x = ir.extraData(Ir.Cmpxchg, data.ty_pl.payload).data;
            const elem_ty = cg.typeOf(x.expected);
            const bytes = Type.abiSize(ip, elem_ty);
            if (bytes == 16) return cg.cmpxchg16(inst, data.ty_pl.ty, x);
            if (!cg.passInRegs(elem_ty)) return cg.fail("cmpxchg of {d} bytes", .{bytes});
            const size = sizeOf(bytes);
            try cg.load(.x12, x.ptr);
            try cg.load(.x9, x.expected);
            try cg.load(.x10, x.new);
            // cas zero-extends the value it loads: compare at its width.
            if (bytes < 8) try cg.e.uxt(size, .x9, .x9);
            try cg.e.mov(.x, .x11, .x9);
            try cg.atomicCas(size, .x9, .x10, .x12);
            try cg.e.cmp(.x, .x9, .r(.x11));
            const dst = try cg.resultMem(inst, data.ty_pl.ty) orelse return;
            if (Type.optionalReprIsPtr(ip, elem_ty)) {
                // Null (0) on success, else the pointer found.
                try cg.e.csel(.csel, .x, .x13, .x9, .zr, .ne);
                try cg.storeReg(dst, .x13, 8);
            } else {
                try cg.e.cset(.x, .x13, .ne);
                try cg.storeReg(dst.plus(Type.optionalFlagOffset(ip, data.ty_pl.ty)), .x13, 1);
                try cg.storeReg(dst, .x9, bytes);
            }
        },
        .ret_addr, .frame_addr => {
            if (tag == .ret_addr) {
                try cg.e.ldr(.dword, .x9, .at(.fp, 8));
            } else {
                try cg.e.mov(.x, .x9, .fp);
            }
            try cg.setResult(inst, .usize_type, .x9);
        },
        .extern_ptr => {
            const name = ip.stringSlice(@fromBackingInt(data.ty_pl.payload));
            const weak = Type.class(ip, data.ty_pl.ty) == .optional;
            _ = try cg.emit.requestCompilerRtExport(name);
            const slot = try cg.emit.useExtern(name, weak);
            try cg.loadMem(.x9, .sym(slot, 0), .usize_type);
            try cg.setResult(inst, data.ty_pl.ty, .x9);
        },
        .extern_pcrel => return cg.fail("@extern with '.relocation = .pcrel' on aarch64-macos", .{}),
        .extern_tls => {
            if (cg.ip.target != .aarch64_linux) return cg.fail("thread-local externs on aarch64-macos", .{});
            try cg.linuxThreadLocal(try cg.emit.tlsTarget(ip.stringSlice(@fromBackingInt(data.ty_pl.payload))));
            try cg.setResult(inst, data.ty_pl.ty, .x9);
        },
        .c_va_start => {
            // Apple's `va_list` is the address of the next variadic
            // argument, all of which are on the stack.
            try cg.addImm(.x9, .fp, 16 + cg.va_stack);
            try cg.setResult(inst, data.ty, .x9);
        },
        .c_va_arg => try cg.cVaArg(inst, data.ty_op.ty, data.ty_op.operand),
        .c_va_copy => {
            try cg.load(.x12, data.ty_op.operand);
            try cg.e.ldr(.dword, .x9, .at(.x12, 0));
            try cg.setResult(inst, data.ty_op.ty, .x9);
        },
        .err_return_trace => {
            try cg.loadTrace(.x9);
            try cg.setResult(inst, data.ty, .x9);
        },
        .set_err_return_trace => {
            if (cg.trace_slot == null) cg.trace_slot = try cg.allocSlot(8, 8);
            try cg.load(.x9, data.un_op);
            try cg.storeReg(cg.trace_slot.?, .x9, 8);
        },
        .save_err_return_trace_index => {
            if (data.ty_pl.ty == .none) return;
            if (cg.trace_slot) |m| {
                try cg.loadMem(.x9, m, .usize_type);
                try cg.loadMem(.x9, .at(.x9, @intCast(Type.fieldOffset(ip, data.ty_pl.ty, data.ty_pl.payload))), .usize_type);
            } else {
                try cg.e.movImm(.x, .x9, 0);
            }
            try cg.setResult(inst, .usize_type, .x9);
        },
        .tls_ptr => {
            const key = try cg.emit.navKey(@fromBackingInt(data.ty_pl.payload));
            if (cg.ip.target == .aarch64_linux) {
                try cg.linuxThreadLocal(.{ .key = key, .local = true });
                return cg.setResult(inst, data.ty_pl.ty, .x9);
            }
            try cg.e.threadLocalAddr(key);
            try cg.setResult(inst, data.ty_pl.ty, .x0);
        },
        .intcast, .trunc, .bitcast, .ptr_from_int => {
            const ty = data.ty_op.ty;
            const src_ty = cg.typeOf(data.ty_op.operand);
            // Its operand's memory (`Home.result`).
            if (cg.homes[@backingInt(inst)] == .result) return;
            if (tag != .ptr_from_int and (cg.isWideInt(ty) or cg.isWideInt(src_ty)) and Type.isInt(ip, ty)) return cg.genWide(inst, tag, data);
            const size = Type.abiSize(ip, ty);
            const src_size = Type.abiSize(ip, src_ty);
            // A vector in a register from an array or vector of its size.
            if (vector.bitcastToVreg(cg, inst)) {
                const v = cg.homes[@backingInt(inst)].vreg;
                if (vector.loaded(cg, data.ty_op.operand)) |ptr| return vector.loadMem(cg, v, try cg.ptrMem(ptr), @intCast(size));
                return vector.loadVec(cg, v, data.ty_op.operand);
            }
            if (cg.passInRegs(ty) and cg.passInRegs(src_ty)) {
                try cg.load(.x9, data.ty_op.operand);
                if (Type.isInt(ip, ty)) try cg.normalize(.x9, ty);
                // A bool from an i1 (a lane of a vector bitcast): its
                // register holds -1 as all ones.
                if (ty == .bool_type and src_ty != .bool_type) try cg.e.logic(.@"and", .x, .x9, .x9, .{ .imm = 1 });
                return cg.setResult(inst, ty, .x9);
            }
            const dst = try cg.resultMem(inst, ty) orelse return;
            if (src_size != size) {
                // A bitcast between a vector and an array or integer
                // without its padding: the low bytes.
                try cg.fillMem(dst, size, 0);
                try cg.copyMem(dst, try cg.memOf(data.ty_op.operand), @min(size, src_size));
                if (Type.isInt(ip, ty) and cg.passInRegs(ty)) {
                    try cg.loadKnown(.x9, dst, ty);
                    try cg.normalize(.x9, ty);
                    try cg.storeReg(dst, .x9, size);
                }
            } else {
                try cg.copyTo(dst, data.ty_op.operand);
            }
        },
        .error_name => {
            // The table holds a slice per error code.
            try cg.emit.useErrorNames();
            const dst = try cg.resultMem(inst, .slice_const_u8_sentinel_0_type) orelse return;
            try cg.load(.x9, data.un_op);
            try cg.e.uxt(.half, .x9, .x9);
            try cg.e.loadAddr(.x12, Emit.error_name_table, 0);
            try cg.e.addSub(.add, .x, .x12, .x12, .{ .reg = .{ .reg = .x9, .amount = 4 } });
            try cg.copyMem(dst, .at(.x12, 0), 16);
        },
        .int_from_bool, .int_from_ptr => {
            try cg.load(.x9, data.un_op);
            try cg.setResult(inst, ir.typeOfIndex(inst, ip), .x9);
        },

        // The block's result, which each `br` writes (see `genTerm`).
        .block => _ = try cg.slotFor(inst, data.ty_pl.ty),
        .loop => {},
        .repeat, .br, .cond_br, .switch_br, .ret, .unreach, .trap => unreachable,
        // As LLVM lowers `@breakpoint` on Darwin.
        .breakpoint => try cg.e.brk(0xf000),
        .call => try cg.call(inst, data),

        .struct_field_ptr => {
            const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
            const container = Type.ptrInfo(ip, cg.typeOf(sf.operand)).child;
            try cg.addrPlus(.x9, sf.operand, Type.fieldOffset(ip, container, sf.index));
            try cg.setResult(inst, data.ty_pl.ty, .x9);
        },
        .struct_field_val => {
            const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
            // Written by the overflow operation.
            if (sf.operand.toIndex()) |op| if (cg.fate(op) == .pair) return;
            const ty = data.ty_pl.ty;
            const off = Type.fieldOffset(ip, cg.typeOf(sf.operand), sf.index);
            const src = try cg.memOf(sf.operand);
            if (cg.passInRegs(ty)) {
                const d = cg.resultReg(inst, .x9);
                try cg.loadMem(d, src.plus(off), ty);
                return cg.setResult(inst, ty, d);
            }
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.copyMem(dst, src.plus(off), Type.abiSize(ip, ty));
        },
        .ptr_elem_ptr, .slice_elem_ptr, .ptr_add => {
            const bin = ir.extraData(Ir.Bin, data.ty_pl.payload).data;
            const elem_ty = Type.ptrInfo(ip, data.ty_pl.ty).child;
            const d = cg.resultReg(inst, .x9);
            try cg.elemAddrTo(d, tag == .slice_elem_ptr, bin.lhs, bin.rhs, Type.abiSize(ip, elem_ty));
            try cg.setResult(inst, data.ty_pl.ty, d);
        },
        .vector_store_elem => {
            const bin = ir.extraData(Ir.Bin, data.pl_op.payload).data;
            const elem_ty = Type.childType(ip, Type.ptrInfo(ip, cg.typeOf(data.pl_op.operand)).child);
            try cg.load(.x12, data.pl_op.operand);
            try cg.load(.x10, bin.lhs);
            if (elem_ty == .bool_type) {
                // Bit x10 % 8 of byte x10 / 8: clear it, then or in the value.
                try cg.e.addSub(.add, .x, .x12, .x12, .{ .reg = .{ .reg = .x10, .shift = .lsr, .amount = 3 } });
                try cg.e.logic(.@"and", .x, .x10, .x10, .{ .imm = 7 });
                try cg.e.movImm(.x, .x11, 1);
                try cg.e.shiftReg(.lsl, .x, .x11, .x11, .x10);
                try cg.e.ldr(.byte, .x13, .at(.x12, 0));
                try cg.e.logic(.bic, .x, .x13, .x13, .r(.x11));
                try cg.load(.x9, bin.rhs);
                try cg.e.shiftReg(.lsl, .x, .x9, .x9, .x10);
                try cg.e.logic(.orr, .x, .x13, .x13, .r(.x9));
                try cg.e.str(.byte, .x13, .at(.x12, 0));
                return;
            }
            try cg.scaleAdd(.x12, .x10, Type.abiSize(ip, elem_ty));
            try cg.copyTo(.at(.x12, 0), bin.rhs);
        },
        .ptr_elem_val, .slice_elem_val => {
            const ty = ir.typeOfIndex(inst, ip);
            const size = Type.abiSize(ip, ty);
            try cg.elemAddrTo(.x12, tag == .slice_elem_val, data.bin_op.lhs, data.bin_op.rhs, size);
            if (cg.passInRegs(ty)) {
                const d = cg.resultReg(inst, .x9);
                try cg.loadMem(d, .at(.x12, 0), ty);
                return cg.setResult(inst, ty, d);
            }
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.copyMem(dst, .at(.x12, 0), size);
        },
        .array_elem_val => {
            const ty = ir.typeOfIndex(inst, ip);
            const dst = try cg.resultMem(inst, ty) orelse return;
            const size = Type.abiSize(ip, ty);
            try cg.addrTo(.x12, try cg.memOf(data.bin_op.lhs));
            try cg.load(.x10, data.bin_op.rhs);
            if (ip.keyTag(cg.typeOf(data.bin_op.lhs)) == .vector_type and ty == .bool_type) {
                // Bit-packed bool vector: bit x10 % 8 of byte x10 / 8.
                try cg.e.addSub(.add, .x, .x12, .x12, .{ .reg = .{ .reg = .x10, .shift = .lsr, .amount = 3 } });
                try cg.e.ldr(.byte, .x9, .at(.x12, 0));
                try cg.e.logic(.@"and", .x, .x10, .x10, .{ .imm = 7 });
                try cg.e.shiftReg(.lsr, .x, .x9, .x9, .x10);
                try cg.e.logic(.@"and", .x, .x9, .x9, .{ .imm = 1 });
                return cg.storeReg(dst, .x9, 1);
            }
            try cg.scaleAdd(.x12, .x10, size);
            try cg.copyMem(dst, .at(.x12, 0), size);
        },
        .slice_ptr, .slice_len => {
            const src = try cg.memOf(data.ty_op.operand);
            const d = cg.resultReg(inst, .x9);
            try cg.loadMem(d, src.plus(if (tag == .slice_len) 8 else 0), .usize_type);
            try cg.setResult(inst, data.ty_op.ty, d);
        },
        .slice => {
            const bin = ir.extraData(Ir.Bin, data.ty_pl.payload).data;
            const dst = try cg.resultMem(inst, data.ty_pl.ty) orelse return;
            try cg.load(.x9, bin.lhs);
            try cg.storeReg(dst, .x9, 8);
            try cg.load(.x9, bin.rhs);
            try cg.storeReg(dst.plus(8), .x9, 8);
        },

        .is_null, .is_non_null, .is_err, .is_non_err, .cmp_lt_errors_len => try cg.genCond(inst),
        .optional_payload => {
            const child = data.ty_op.ty;
            if (Type.optionalReprIsPtr(ip, child)) {
                try cg.load(.x9, data.ty_op.operand);
                return cg.setResult(inst, child, .x9);
            }
            const src = try cg.memOf(data.ty_op.operand);
            if (cg.passInRegs(child)) {
                const d = cg.resultReg(inst, .x9);
                try cg.loadMem(d, src, child);
                return cg.setResult(inst, child, d);
            }
            const dst = try cg.resultMem(inst, child) orelse return;
            try cg.copyMem(dst, src, Type.abiSize(ip, child));
        },
        .optional_payload_ptr, .optional_payload_ptr_set => {
            try cg.load(.x9, data.ty_op.operand);
            if (tag == .optional_payload_ptr_set) {
                const opt_ty = Type.ptrInfo(ip, cg.typeOf(data.ty_op.operand)).child;
                if (!Type.optionalReprIsPayload(ip, Type.childType(ip, opt_ty))) {
                    try cg.e.movImm(.x, .x10, 1);
                    try cg.storeReg(.at(.x9, @intCast(Type.optionalFlagOffset(ip, opt_ty))), .x10, 1);
                }
            }
            try cg.setResult(inst, data.ty_op.ty, .x9);
        },
        .wrap_optional => {
            const opt_ty = data.ty_op.ty;
            const dst = try cg.resultMem(inst, opt_ty) orelse return;
            try cg.copyTo(dst, data.ty_op.operand);
            if (!Type.optionalReprIsPayload(ip, Type.childType(ip, opt_ty))) {
                try cg.e.movImm(.x, .x10, 1);
                try cg.storeReg(dst.plus(Type.optionalFlagOffset(ip, opt_ty)), .x10, 1);
            }
        },
        .unwrap_errunion_payload, .unwrap_errunion_err => {
            // Read in place in the function's result (`planRetCalls`).
            if (cg.homes[@backingInt(inst)] == .result) return;
            const ty = data.ty_op.ty;
            const layout = Type.errorUnionLayout(ip, cg.typeOf(data.ty_op.operand));
            const off = if (tag == .unwrap_errunion_err) layout.err_offset else layout.payload_offset;
            const src = try cg.memOf(data.ty_op.operand);
            if (cg.passInRegs(ty)) {
                const d = cg.resultReg(inst, .x9);
                try cg.loadMem(d, src.plus(off), ty);
                return cg.setResult(inst, ty, d);
            }
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.copyMem(dst, src.plus(off), Type.abiSize(ip, ty));
        },
        .unwrap_errunion_payload_ptr, .unwrap_errunion_err_ptr, .errunion_payload_ptr_set => {
            const eu_ty = Type.ptrInfo(ip, cg.typeOf(data.ty_op.operand)).child;
            const layout = Type.errorUnionLayout(ip, eu_ty);
            const off = if (tag == .unwrap_errunion_err_ptr) layout.err_offset else layout.payload_offset;
            if (tag == .errunion_payload_ptr_set) {
                try cg.load(.x9, data.ty_op.operand);
                try cg.storeReg(.at(.x9, @intCast(layout.err_offset)), .zr, 2);
                try cg.addImm(.x9, .x9, @intCast(off));
            } else try cg.addrPlus(.x9, data.ty_op.operand, off);
            try cg.setResult(inst, data.ty_op.ty, .x9);
        },
        .wrap_errunion_payload, .wrap_errunion_err => {
            const eu_ty = data.ty_op.ty;
            const layout = Type.errorUnionLayout(ip, eu_ty);
            if (cg.homes[@backingInt(inst)] == .result) {
                // Its payload is already there (`planRetCalls`).
                const m = (try cg.locOf(inst.toRef())).mem;
                return cg.storeReg(m.plus(layout.err_offset), .zr, 2);
            }
            const dst = try cg.resultMem(inst, eu_ty) orelse return;
            if (tag == .wrap_errunion_payload) {
                try cg.storeReg(dst.plus(layout.err_offset), .zr, 2);
                try cg.copyTo(dst.plus(layout.payload_offset), data.ty_op.operand);
            } else {
                try cg.load(.x9, data.ty_op.operand);
                try cg.storeReg(dst.plus(layout.err_offset), .x9, 2);
            }
        },
        .aggregate_init => {
            const ty = data.ty_pl.ty;
            const dst = try cg.resultMem(inst, ty) orelse return;
            const extra = ir.extraData(Ir.Aggregate, data.ty_pl.payload);
            const elems = ir.refSlice(extra.end, extra.data.len);
            if (ip.keyTag(ty) == .vector_type and ip.keyPayload(.vector_type, ty).child == .bool_type) {
                // Bit-packed: element i is bit i % 8 of byte i / 8.
                const size = Type.abiSize(ip, ty);
                try cg.fillMem(dst, size, 0);
                var byte: u64 = 0;
                while (byte * 8 < elems.len) : (byte += 1) {
                    try cg.e.movImm(.x, .x11, 0);
                    for (elems[byte * 8 .. @min(elems.len, byte * 8 + 8)], 0..) |elem, bit| {
                        // An undefined lane's bits (0xaa) would spill into its neighbors'.
                        if (elem.toInterned()) |v| if (ip.keyTag(v) == .undef) continue;
                        try cg.load(.x9, elem);
                        try cg.e.logic(.orr, .x, .x11, .x11, .{ .reg = .{ .reg = .x9, .amount = @intCast(bit) } });
                    }
                    try cg.storeReg(dst.plus(byte), .x11, 1);
                }
                return;
            }
            // A run of one element over 128 bytes (a `@splat`), as the
            // x86_64 backend: copies of the element until they span 64
            // bytes, then one forward copy of what is written repeats it
            // (`copyMem` reads 32 bytes behind its writes at most).
            var first: usize = 0;
            if (elems.len > 1 and ip.keyTag(ty) != .struct_type and ip.keyTag(ty) != .tuple_type) {
                const elem_size = Type.abiSize(ip, cg.typeOf(elems[0]));
                const run = for (elems, 0..) |elem, i| {
                    if (elem != elems[0]) break i;
                } else elems.len;
                const total = run * elem_size;
                if (total > 128) {
                    var span: u64 = 0;
                    while (span < 64) : (span += elem_size) try cg.copyTo(dst.plus(span), elems[0]);
                    try cg.copyMem(dst.plus(span), dst, total - span);
                    first = run;
                }
            }
            for (elems[first..], first..) |elem, i| {
                const off = switch (ip.indexToKey(ty)) {
                    .array_type => |a| i * Type.abiSize(ip, a.child),
                    .vector_type => |v| i * Type.abiSize(ip, v.child),
                    else => if (Type.comptimeFieldValue(ip, ty, i) != .none) continue else Type.fieldOffset(ip, ty, i),
                };
                try cg.copyTo(dst.plus(off), elem);
            }
        },
        .union_init => {
            const ty = data.ty_pl.ty;
            const dst = try cg.resultMem(inst, ty) orelse return;
            const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
            const layout = Type.unionLayout(ip, ty);
            try cg.copyTo(dst.plus(layout.payload_offset), sf.operand);
            if (layout.tag_size != 0) {
                try cg.e.movImm(.x, .x9, Type.unionFieldTag(ip, ty, sf.index));
                try cg.storeBytes(dst.plus(layout.tag_offset), .x9, layout.tag_size);
            }
        },
        .get_union_tag => {
            const ty = data.ty_op.ty;
            const layout = Type.unionLayout(ip, cg.typeOf(data.ty_op.operand));
            const src = try cg.memOf(data.ty_op.operand);
            if (cg.passInRegs(ty)) {
                const d = cg.resultReg(inst, .x9);
                try cg.loadMem(d, src.plus(layout.tag_offset), ty);
                return cg.setResult(inst, ty, d);
            }
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.copyMem(dst, src.plus(layout.tag_offset), layout.tag_size);
        },
        .set_union_tag => {
            const layout = Type.unionLayout(ip, Type.ptrInfo(ip, cg.typeOf(data.bin_op.lhs)).child);
            if (layout.tag_size == 0) return;
            try cg.load(.x12, data.bin_op.lhs);
            try cg.load(.x9, data.bin_op.rhs);
            try cg.storeBytes(.at(.x12, @intCast(layout.tag_offset)), .x9, layout.tag_size);
        },
        .memcpy, .memmove => {
            const elem_size = try cg.memDest(.x13, .x11, data.bin_op.lhs);
            if (elem_size != 1) {
                try cg.e.movImm(.x, .x9, elem_size);
                try cg.e.mul(.x, .x11, .x11, .x9);
            }
            try cg.load(.x14, data.bin_op.rhs);
            try cg.copyBytes(tag == .memmove);
        },
        .memset => try cg.memset(data),
        .clz, .ctz, .popcount, .byte_swap, .bit_reverse => {
            const ty = data.ty_op.ty;
            const src_ty = cg.typeOf(data.ty_op.operand);
            if (cg.isWideInt(src_ty)) return cg.wideBitOp(inst, tag, data);
            const bits = Type.intInfo(ip, src_ty).bits;
            try cg.bitOp(tag, bits, data.ty_op.operand);
            if (tag == .byte_swap or tag == .bit_reverse) try cg.normalize(.x9, ty);
            try cg.setResult(inst, ty, .x9);
        },
        .tag_name => {
            // A compare chain over the tags; each name is a content atom.
            const dst = try cg.resultMem(inst, data.ty_op.ty) orelse return;
            const enum_ty = cg.typeOf(data.ty_op.operand);
            const wide = cg.isWideInt(enum_ty);
            const info = ip.structInfo(enum_ty);
            if (!wide) try cg.load(.x9, data.ty_op.operand);
            const done = try cg.e.newLabel();
            for (info.field_names, info.field_defaults) |name, v| {
                const next = try cg.e.newLabel();
                if (wide) {
                    try cg.wideEq(data.ty_op.operand, .fromInterned(v));
                    try cg.e.cbz(true, .x, .x9, next);
                } else {
                    try cg.cmpOperand(.x9, .fromInterned(v));
                    try cg.e.bcond(.ne, next);
                }
                const bytes = ip.stringSlice(name);
                const z = try cg.emit.allocator().alloc(u8, bytes.len + 1);
                @memcpy(z[0..bytes.len], bytes);
                z[bytes.len] = 0;
                try cg.e.loadAddr(.x10, try cg.emit.contentAtom(1, z, &.{}, &.{}), 0);
                try cg.storeReg(dst, .x10, 8);
                try cg.e.movImm(.x, .x10, bytes.len);
                try cg.storeReg(dst.plus(8), .x10, 8);
                try cg.e.b(.{ .label = done });
                cg.e.bind(next);
            }
            try cg.e.brk(1);
            cg.e.bind(done);
        },
        .assembly => try cg.assembly(inst, data),
    }
}

/// Loads the pointer of `@memcpy`/`@memset` destination `dest` (a slice
/// or `*[N]T`) into `ptr` and its length in elements into `len`, and
/// returns the element size.
fn memDest(cg: *CodeGen, ptr: Reg, len: Reg, dest: Ref) Error!u64 {
    const ip = cg.ip;
    const p = Type.ptrInfo(ip, cg.typeOf(dest));
    if (p.flags.size == .slice) {
        const m = try cg.memOf(dest);
        try cg.loadMem(ptr, m, .usize_type);
        try cg.loadMem(len, m.plus(8), .usize_type);
        return Type.abiSize(ip, p.child);
    }
    const a = ip.keyPayload(.array_type, p.child);
    try cg.load(ptr, dest);
    try cg.e.movImm(.x, len, a.len);
    return Type.abiSize(ip, a.child);
}

/// Copies x11 bytes from x14 to x13: forward, or for `memmove` backward
/// when the destination is above the source. Uses x9.
fn copyBytes(cg: *CodeGen, memmove: bool) Error!void {
    const e = &cg.e;
    const done = try e.newLabel();
    const forward = try e.newLabel();
    if (memmove) {
        // Backward, a byte at a time, when x14 < x13 < x14 + x11.
        try e.cmp(.x, .x13, .r(.x14));
        try e.bcond(.ls, forward);
        try e.addSub(.add, .x, .x9, .x14, .r(.x11));
        try e.cmp(.x, .x13, .r(.x9));
        try e.bcond(.hs, forward);
        try e.addSub(.add, .x, .x13, .x13, .r(.x11));
        try e.mov(.x, .x14, .x9);
        try e.cbz(false, .x, .x11, done);
        const back = try e.newLabel();
        e.bind(back);
        try e.ldr(.byte, .x9, .{ .base = .x14, .offset = .{ .pre = -1 } });
        try e.str(.byte, .x9, .{ .base = .x13, .offset = .{ .pre = -1 } });
        try e.addSub(.subs, .x, .x11, .x11, .{ .imm = 1 });
        try e.bcond(.ne, back);
        try e.b(.{ .label = done });
    }
    e.bind(forward);
    const tail = try e.newLabel();
    const words = try e.newLabel();
    try e.addSub(.subs, .x, .x11, .x11, .{ .imm = 8 });
    try e.bcond(.lo, tail);
    e.bind(words);
    try e.ldr(.dword, .x9, .{ .base = .x14, .offset = .{ .post = 8 } });
    try e.str(.dword, .x9, .{ .base = .x13, .offset = .{ .post = 8 } });
    try e.addSub(.subs, .x, .x11, .x11, .{ .imm = 8 });
    try e.bcond(.hs, words);
    e.bind(tail);
    try e.addSub(.adds, .x, .x11, .x11, .{ .imm = 8 });
    try e.bcond(.eq, done);
    const bytes = try e.newLabel();
    e.bind(bytes);
    try e.ldr(.byte, .x9, .{ .base = .x14, .offset = .{ .post = 1 } });
    try e.str(.byte, .x9, .{ .base = .x13, .offset = .{ .post = 1 } });
    try e.addSub(.subs, .x, .x11, .x11, .{ .imm = 1 });
    try e.bcond(.ne, bytes);
    e.bind(done);
}

fn memset(cg: *CodeGen, data: Inst.Data) Error!void {
    const ip = cg.ip;
    const elem = data.bin_op.rhs;
    const elem_size = try cg.memDest(.x13, .x11, data.bin_op.lhs);
    const e = &cg.e;
    const done = try e.newLabel();
    if (elem_size == 1) {
        // The byte in every byte of x10, then words and a byte tail.
        try cg.load(.x10, elem);
        try e.uxt(.byte, .x10, .x10);
        try e.movImm(.x, .x9, 0x0101_0101_0101_0101);
        try e.mul(.x, .x10, .x10, .x9);
        const tail = try e.newLabel();
        const words = try e.newLabel();
        try e.addSub(.subs, .x, .x11, .x11, .{ .imm = 8 });
        try e.bcond(.lo, tail);
        e.bind(words);
        try e.str(.dword, .x10, .{ .base = .x13, .offset = .{ .post = 8 } });
        try e.addSub(.subs, .x, .x11, .x11, .{ .imm = 8 });
        try e.bcond(.hs, words);
        e.bind(tail);
        try e.addSub(.adds, .x, .x11, .x11, .{ .imm = 8 });
        try e.bcond(.eq, done);
        const bytes = try e.newLabel();
        e.bind(bytes);
        try e.str(.byte, .x10, .{ .base = .x13, .offset = .{ .post = 1 } });
        try e.addSub(.subs, .x, .x11, .x11, .{ .imm = 1 });
        try e.bcond(.ne, bytes);
        e.bind(done);
        return;
    }
    // An element at a time; the copy uses x9, x10, x16, and x17 (and x11
    // only for 3-byte and larger copies, so the count goes in x14).
    try e.mov(.x, .x14, .x11);
    try e.cbz(false, .x, .x14, done);
    const top = try e.newLabel();
    e.bind(top);
    if (elem.toInterned()) |v| if (ip.keyTag(v) == .undef) {
        try cg.fillMem(.at(.x13, 0), elem_size, 0xaa);
    } else try cg.copyTo(.at(.x13, 0), elem) else try cg.copyTo(.at(.x13, 0), elem);
    try cg.addImm(.x13, .x13, @intCast(elem_size));
    try e.addSub(.subs, .x, .x14, .x14, .{ .imm = 1 });
    try e.bcond(.ne, top);
    e.bind(done);
}

/// The bit operations into x9.
fn bitOp(cg: *CodeGen, tag: Inst.Tag, bits: u16, operand: Ref) Error!void {
    const e = &cg.e;
    // A u0 at run time (`std.mem.writeInt` of no bytes): every result is
    // 0.
    if (bits == 0) return e.movImm(.x, .x9, 0);
    try cg.load(.x9, operand);
    // Only the operand's own bits.
    if (bits < 64) try e.bitfield(.ubfm, .x, .x9, .x9, 0, @intCast(bits - 1));
    switch (tag) {
        .clz => {
            try e.bitOp(.clz, .x, .x9, .x9);
            if (bits < 64) try e.addSub(.sub, .x, .x9, .x9, .{ .imm = 64 - bits });
        },
        .ctz => {
            // A bit above the operand's makes 0 count `bits`.
            if (bits < 64) try e.logic(.orr, .x, .x9, .x9, .{ .imm = @as(u64, 1) << @intCast(bits) });
            try e.bitOp(.rbit, .x, .x9, .x9);
            try e.bitOp(.clz, .x, .x9, .x9);
        },
        .popcount => {
            try e.fmovFromGpr(.f64, .v0, .x, .x9);
            try e.cnt(.v0, .v0);
            try e.addv(.v0, .v0);
            try e.fmovToGpr(.w, .x9, .f32, .v0);
        },
        .byte_swap => if (bits > 8) {
            try e.bitOp(.rev, .x, .x9, .x9);
            if (bits < 64) try e.shiftImm(.lsr, .x, .x9, .x9, @intCast(64 - bits));
        },
        .bit_reverse => {
            try e.bitOp(.rbit, .x, .x9, .x9);
            if (bits < 64) try e.shiftImm(.lsr, .x, .x9, .x9, @intCast(64 - bits));
        },
        else => unreachable,
    }
}

/// A condition as a bool.
fn genCond(cg: *CodeGen, inst: Inst.Index) Error!void {
    if (cg.fate(inst) == .fused) return;
    const cond = try cg.condFlags(inst);
    const d = cg.resultReg(inst, .x9);
    try cg.e.cset(.x, d, cond);
    try cg.setResult(inst, .bool_type, d);
}

/// Sets the flags for condition `inst` (a compare, `is_err`, or `is_null`
/// and their negations) and returns the condition code that holds when it
/// is true.
fn condFlags(cg: *CodeGen, inst: Inst.Index) Error!Cond {
    const ip = cg.ip;
    const tag = cg.ir.instructions.items(.tag)[@backingInt(inst)];
    const data = cg.ir.instructions.items(.data)[@backingInt(inst)];
    switch (tag) {
        .reduce => return vector.condFlags(cg, inst),
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => {
            if (data.bin_op.lhs.toIndex()) |bit| if (cg.fate(bit) == .fused) {
                // An overflow bit left in the flags.
                return if (Ssa.ovfBitCmp(cg.ir, ip, inst, @backingInt(bit)).?) cg.ovf_cc else cg.ovf_cc.negate();
            };
            const s = cg.signed(cg.typeOf(data.bin_op.lhs));
            try cg.cmpOperand(try cg.use(data.bin_op.lhs, .x9), data.bin_op.rhs);
            return switch (tag) {
                .cmp_lt => if (s) .lt else .lo,
                .cmp_lte => if (s) .le else .ls,
                .cmp_eq => .eq,
                .cmp_gte => if (s) .ge else .hs,
                .cmp_gt => if (s) .gt else .hi,
                .cmp_neq => .ne,
                else => unreachable,
            };
        },
        .cmp_lt_errors_len => {
            // The count of codes is a link-time value; a code is below it
            // plus one.
            try cg.load(.x9, data.un_op);
            try cg.e.movWideValue(.movz, .x, .x10, Emit.errors_len, 0);
            try cg.e.cmp(.x, .x9, .{ .reg = .{ .reg = .x10 } });
            return .ls;
        },
        .is_err, .is_non_err => {
            const layout = Type.errorUnionLayout(ip, cg.typeOf(data.un_op));
            try cg.loadMem(.x9, (try cg.memOf(data.un_op)).plus(layout.err_offset), .u16_type);
            try cg.e.cmp(.x, .x9, .{ .imm = 0 });
            return if (tag == .is_err) .ne else .eq;
        },
        .is_null, .is_non_null => {
            const opt_ty = cg.typeOf(data.un_op);
            const child = Type.childType(ip, opt_ty);
            if (Type.optionalReprIsPtr(ip, child)) {
                try cg.load(.x9, data.un_op);
            } else if (Type.optionalReprIsPayload(ip, child)) {
                // A slice's `ptr` or an error code; zero is null.
                try cg.loadMem(.x9, try cg.memOf(data.un_op), if (Type.isSlice(ip, child)) .usize_type else .u16_type);
            } else {
                try cg.loadMem(.x9, (try cg.memOf(data.un_op)).plus(Type.optionalFlagOffset(ip, opt_ty)), .u8_type);
            }
            try cg.e.cmp(.x, .x9, .{ .imm = 0 });
            return if (tag == .is_null) .eq else .ne;
        },
        else => unreachable,
    }
}

/// Computes `lhs op rhs` on 64-bit extended operands into `d`, normalized
/// to `ty`, writing `d` after reading both. Uses x9, x10, x11, x13, and
/// x14; `d` is x9 or none of those.
fn binOp(cg: *CodeGen, tag: Inst.Tag, ty: Index, lhs: Ref, rhs: Ref, d: Reg) Error!void {
    const e = &cg.e;
    const s = cg.signed(ty);
    const a = try cg.use(lhs, .x9);
    // Immediate forms of the operations that have them.
    const imm: ?u64 = switch (try cg.locOf(rhs)) {
        .imm => |v| v,
        else => null,
    };
    switch (tag) {
        .add_wrap, .sub_wrap => if (imm) |v| if (v < 4096) {
            try e.addSub(if (tag == .add_wrap) .add else .sub, .x, d, a, .{ .imm = @intCast(v) });
            return cg.normalize(d, ty);
        },
        .bit_and, .bit_or, .xor => if (imm) |v| if (Encoder.bitmaskImm(.x, v) != null) {
            return e.logic(switch (tag) {
                .bit_and => .@"and",
                .bit_or => .orr,
                else => .eor,
            }, .x, d, a, .{ .imm = v });
        },
        .shl, .shr => if (imm) |v| {
            try e.shiftImm(if (tag == .shl) .lsl else if (s) .asr else .lsr, .x, d, a, @intCast(v & 63));
            return cg.normalize(d, ty);
        },
        // The results are at most the dividend: they stay normalized.
        .div_trunc, .div_floor, .div_ceil, .rem, .mod => if (imm) |v| {
            const bits = Type.intInfo(cg.ip, ty).bits;
            if (!s and v != 0) return cg.divConst(tag, a, v, bits, d);
            if (s and @as(i64, @bitCast(v)) >= 1 and tag != .div_ceil) return cg.divConstSigned(tag, a, v, bits, d);
        },
        else => {},
    }
    const b = try cg.use(rhs, .x10);
    switch (tag) {
        .add_wrap => try e.addSub(.add, .x, d, a, .r(b)),
        .sub_wrap => try e.addSub(.sub, .x, d, a, .r(b)),
        .mul_wrap => try e.mul(.x, d, a, b),
        .bit_and => return e.logic(.@"and", .x, d, a, .r(b)),
        .bit_or => return e.logic(.orr, .x, d, a, .r(b)),
        .xor => return e.logic(.eor, .x, d, a, .r(b)),
        .shl => try e.shiftReg(.lsl, .x, d, a, b),
        .shr => try e.shiftReg(if (s) .asr else .lsr, .x, d, a, b),
        .div_trunc, .div_floor, .div_ceil, .rem, .mod => try cg.divide(tag, s, a, b, d),
        else => unreachable,
    }
    try cg.normalize(d, ty);
}

/// `d = a op b` for division `tag` of 64-bit extended registers, signed
/// or not by `s`, writing `d` after reading both. Uses x11, x13, and x14.
fn divide(cg: *CodeGen, tag: Inst.Tag, s: bool, a: Reg, b: Reg, d: Reg) Error!void {
    const e = &cg.e;
    // x11 = quotient, x13 = remainder. Safety checks before this
    // rule out division by zero and minInt / -1.
    try e.div(s, .x, .x11, a, b);
    try e.mulAdd(.msub, .x, .x13, .x11, b, a);
    if (s and (tag == .div_floor or tag == .mod)) {
        // Adjust when the remainder is non-zero and its sign
        // differs from the divisor's.
        const done = try e.newLabel();
        try e.cbz(false, .x, .x13, done);
        try e.logic(.eor, .x, .x14, .x13, .r(b));
        try e.tbz(false, .x14, 63, done);
        if (tag == .div_floor) {
            try e.addSub(.sub, .x, .x11, .x11, .{ .imm = 1 });
        } else {
            try e.addSub(.add, .x, .x13, .x13, .r(b));
        }
        e.bind(done);
    }
    if (tag == .div_ceil) {
        // Round up when the remainder is non-zero and the exact
        // quotient is positive (dividend and divisor signs agree).
        const done = try e.newLabel();
        try e.cbz(false, .x, .x13, done);
        if (s) {
            try e.logic(.eor, .x, .x14, .x13, .r(b));
            try e.tbz(true, .x14, 63, done);
        }
        try e.addSub(.add, .x, .x11, .x11, .{ .imm = 1 });
        e.bind(done);
    }
    try e.mov(.x, d, if (tag == .rem or tag == .mod) .x13 else .x11);
}

/// x11 = `x / c` for the `bits`-bit unsigned value in `x` and constant `c`
/// (not zero) without a divide: a shift for a power of two, a compare when
/// the quotient is 0 or 1, else a multiply by `Ssa.divMagic`'s number.
/// Uses x10.
fn udivConst(cg: *CodeGen, x: Reg, c: u64, bits: u16) Error!void {
    const e = &cg.e;
    if (std.math.isPowerOfTwo(c)) {
        const k: u6 = @intCast(@ctz(c));
        if (k == 0) return e.mov(.x, .x11, x);
        return e.shiftImm(.lsr, .x, .x11, x, k);
    }
    if (c > @as(u64, 1) << @intCast(bits - 1)) {
        try e.movImm(.x, .x10, c);
        try e.cmp(.x, x, .r(.x10));
        return e.csel(.csinc, .x, .x11, .zr, .zr, .lo);
    }
    const magic = Ssa.divMagic(c, bits);
    try e.movImm(.x, .x10, @truncate(magic.m));
    try e.mulHigh(false, .x11, x, .x10);
    if (magic.m >> 64 == 0) {
        if (magic.p > 64) try e.shiftImm(.lsr, .x, .x11, .x11, @intCast(magic.p - 64));
        return;
    }
    try e.addSub(.sub, .x, .x10, x, .r(.x11));
    try e.addSub(.add, .x, .x11, .x11, .{ .reg = .{ .reg = .x10, .shift = .lsr, .amount = 1 } });
    if (magic.p > 65) try e.shiftImm(.lsr, .x, .x11, .x11, @intCast(magic.p - 65));
}

/// `d = a op c` for unsigned division `tag` of the `bits`-bit value in `a`
/// by constant `c` (not zero), writing `d` last. Uses x10, x11, and x13.
fn divConst(cg: *CodeGen, tag: Inst.Tag, a: Reg, c: u64, bits: u16, d: Reg) Error!void {
    const e = &cg.e;
    const want_q = tag == .div_trunc or tag == .div_floor;
    if (!want_q and tag != .div_ceil and std.math.isPowerOfTwo(c)) {
        if (c == 1) return e.movImm(.x, d, 0);
        return e.logic(.@"and", .x, d, a, .{ .imm = c - 1 });
    }
    try cg.udivConst(a, c, bits);
    if (want_q) return e.mov(.x, d, .x11);
    try e.movImm(.x, .x10, c);
    if (tag != .div_ceil) return e.mulAdd(.msub, .x, d, .x11, .x10, a);
    // Up by one when the remainder is not zero.
    try e.mulAdd(.msub, .x, .x13, .x11, .x10, a);
    try e.cmp(.x, .x13, .{ .imm = 0 });
    try e.csel(.csinc, .x, d, .x11, .x11, .eq);
}

/// `d = a op c` for signed division `tag` (not ceil) of the `bits`-bit
/// value in `a`, extended to 64 bits, by positive constant `c`, through
/// `udivConst` on a non-negative value: with `s = a >> 63`, floor's
/// quotient is `((a ^ s) / c) ^ s`, and trunc's is `((|a| / c) ^ s) - s`;
/// the remainder is `a - q * c`. Writes `d` last. Uses x10, x11, x13, and
/// x14.
fn divConstSigned(cg: *CodeGen, tag: Inst.Tag, a: Reg, c: u64, bits: u16, d: Reg) Error!void {
    const e = &cg.e;
    const floor = tag == .div_floor or tag == .mod;
    if (floor and std.math.isPowerOfTwo(c)) {
        // Two's complement shifts and masks round toward minus infinity.
        if (c == 1) return if (tag == .mod) e.movImm(.x, d, 0) else e.mov(.x, d, a);
        if (tag == .mod) return e.logic(.@"and", .x, d, a, .{ .imm = c - 1 });
        return e.shiftImm(.asr, .x, d, a, @intCast(@ctz(c)));
    }
    try e.shiftImm(.asr, .x, .x14, a, 63);
    try e.logic(.eor, .x, .x13, a, .r(.x14));
    if (!floor) try e.addSub(.sub, .x, .x13, .x13, .r(.x14));
    // `a ^ s` has `bits - 1` bits; `|a|` has `bits` (|minInt|).
    try cg.udivConst(.x13, c, if (floor) bits - 1 else bits);
    try e.logic(.eor, .x, .x11, .x11, .r(.x14));
    if (!floor) try e.addSub(.sub, .x, .x11, .x11, .r(.x14));
    if (tag == .div_trunc or tag == .div_floor) return e.mov(.x, d, .x11);
    try e.movImm(.x, .x10, c);
    try e.mulAdd(.msub, .x, d, .x11, .x10, a);
}

/// `{ T, u1 }` results: the wrapped value and whether it overflowed `T`.
/// A `pair` writes its fields' homes instead of the tuple, and a fused bit
/// stays in the flags for the branch (`ovf_cc`).
fn overflowOp(cg: *CodeGen, inst: Inst.Index, tag: Inst.Tag, data: Inst.Data) Error!void {
    const ip = cg.ip;
    const e = &cg.e;
    const bin = cg.ir.extraData(Ir.Bin, data.ty_pl.payload).data;
    const tuple_ty = data.ty_pl.ty;
    const ty = cg.typeOf(bin.lhs);
    if (cg.isWideInt(ty)) return cg.genWide(inst, tag, data);
    const pair = cg.fate(inst) == .pair;
    const dst = if (pair) undefined else try cg.resultMem(inst, tuple_ty) orelse return;
    const fields = if (pair) cg.ssa.pairs.get(@backingInt(inst)).? else .{ Ssa.no_tie, Ssa.no_tie };
    const in_flags = fields[1] != Ssa.no_tie and cg.fate(@fromBackingInt(fields[1])) == .fused;
    const info = Type.intInfo(ip, ty);
    const s = info.signedness == .signed;
    const a = try cg.use(bin.lhs, .x9);
    const b = try cg.use(bin.rhs, .x10);
    // The condition under which the flags say it overflowed, or null when
    // x11 holds the bit.
    const cc: ?Cond = switch (tag) {
        .add_with_overflow, .sub_with_overflow => cc: {
            const add = tag == .add_with_overflow;
            if (info.bits == 32 or info.bits == 64) {
                // The flags of the operation at the type's width; the
                // extension after it keeps them.
                try e.addSub(if (add) .adds else .subs, if (info.bits == 64) .x else .w, .x9, a, .r(b));
                if (info.bits == 32 and s) try e.sxt(.word, .x, .x9, .x9);
                break :cc if (s) .vs else if (add) .hs else .lo;
            }
            try e.addSub(if (add) .add else .sub, .x, .x9, a, .r(b));
            break :cc try cg.truncCheck(ty);
        },
        .mul_with_overflow => if (info.bits <= 32) cc: {
            // The product of extended operands is exact in 64 bits.
            try e.mul(.x, .x9, a, b);
            break :cc try cg.truncCheck(ty);
        } else cc: {
            // The high half must extend the low one.
            try e.mulHigh(s, .x11, a, b);
            try e.mul(.x, .x9, a, b);
            if (s) {
                try e.cmp(.x, .x11, .{ .reg = .{ .reg = .x9, .shift = .asr, .amount = 63 } });
            } else {
                try e.cmp(.x, .x11, .{ .imm = 0 });
            }
            if (info.bits == 64) break :cc .ne;
            try e.cset(.x, .x14, .ne);
            try e.cset(.x, .x11, try cg.truncCheck(ty));
            try e.logic(.orr, .x, .x11, .x11, .r(.x14));
            break :cc null;
        },
        else => unreachable,
    };
    if (cc) |c| {
        if (in_flags) cg.ovf_cc = c else try e.cset(.x, .x11, c);
    } else assert(!in_flags);
    // Only stores from here on, which keep the flags.
    if (pair) {
        if (fields[0] != Ssa.no_tie) try cg.setResult(@fromBackingInt(fields[0]), ty, .x9);
        if (fields[1] != Ssa.no_tie and !in_flags) try cg.setResult(@fromBackingInt(fields[1]), .u1_type, .x11);
        return;
    }
    try cg.storeReg(dst, .x9, Type.abiSize(ip, ty));
    try cg.storeReg(dst.plus(Type.fieldOffset(ip, tuple_ty, 1)), .x11, 1);
}

/// Normalizes x9 to `ty` and compares it with its value before: `ne` if
/// that changed it. Uses x13.
fn truncCheck(cg: *CodeGen, ty: Index) Error!Cond {
    try cg.e.mov(.x, .x13, .x9);
    try cg.normalize(.x9, ty);
    try cg.e.cmp(.x, .x9, .r(.x13));
    return .ne;
}

/// `@atomicRmw` with the LSE instructions, acquire-release, or a cas loop
/// for nand and floats. The old value goes to x9.
fn atomicRmw(cg: *CodeGen, inst: Inst.Index, data: Inst.Data) Error!void {
    const ip = cg.ip;
    const e = &cg.e;
    const x = cg.ir.extraData(Ir.AtomicRmw, data.ty_pl.payload).data;
    const ty = data.ty_pl.ty;
    const bytes = Type.abiSize(ip, ty);
    if (bytes == 16) return cg.atomicRmw16(inst, ty, x);
    if (!cg.passInRegs(ty)) return cg.fail("atomic read-modify-write of {d} bytes", .{bytes});
    const size = sizeOf(bytes);
    const is_signed = Type.isInt(ip, ty) and Type.intInfo(ip, ty).signedness == .signed;
    try cg.load(.x12, x.ptr);
    try cg.load(.x10, x.operand);
    const float = x.operation() != .Xchg and cg.isFloat(ty);
    if (float or x.operation() == .Nand) {
        // A cas loop computing the new value in x11 from the old in x9.
        const ft: Float = if (float) cg.fpType(ty) orelse return cg.fail("atomic float operation on '{f}'", .{cg.fmtType(ty)}) else .f64;
        try e.ldr(size, .x9, .at(.x12, 0));
        const top = try e.newLabel();
        e.bind(top);
        if (float) {
            try e.fmovFromGpr(ft, .v0, if (bytes == 8) .x else .w, .x9);
            try e.fmovFromGpr(ft, .v1, if (bytes == 8) .x else .w, .x10);
            try e.fp(switch (x.operation()) {
                .Add => .add,
                .Sub => .sub,
                .Max => .maxnm,
                .Min => .minnm,
                else => unreachable,
            }, ft, .v0, .v0, .v1);
            try e.fmovToGpr(if (bytes == 8) .x else .w, .x11, ft, .v0);
        } else {
            try e.logic(.@"and", .x, .x11, .x9, .r(.x10));
            try e.mvn(.x, .x11, .x11);
            if (ty == .bool_type) try e.logic(.@"and", .x, .x11, .x11, .{ .imm = 1 });
        }
        try e.mov(.x, .x13, .x9);
        try cg.atomicCas(size, .x9, .x11, .x12);
        try e.cmp(if (bytes == 8) .x else .w, .x9, .r(.x13));
        try e.bcond(.ne, top);
    } else switch (x.operation()) {
        .Xchg => try cg.atomicOp(.swp, size, .x10, .x9, .x12),
        .Add => try cg.atomicOp(.add, size, .x10, .x9, .x12),
        .Sub => {
            try e.addSub(.sub, .x, .x10, .zr, .r(.x10));
            try cg.atomicOp(.add, size, .x10, .x9, .x12);
        },
        .And => {
            try e.mvn(.x, .x10, .x10);
            try cg.atomicOp(.clr, size, .x10, .x9, .x12);
        },
        .Or => try cg.atomicOp(.set, size, .x10, .x9, .x12),
        .Xor => try cg.atomicOp(.eor, size, .x10, .x9, .x12),
        .Max => try cg.atomicOp(if (is_signed) .smax else .umax, size, .x10, .x9, .x12),
        .Min => try cg.atomicOp(if (is_signed) .smin else .umin, size, .x10, .x9, .x12),
        .Nand => unreachable,
    }
    try cg.setResult(inst, ty, .x9);
}

// 16-byte atomics (u128, f128, packed structs backed by u128) work on
// register pairs, as LLVM lowers them for Apple Silicon: FEAT_LSE2 makes an
// aligned `ldp` or `stp` single-copy atomic, with `dmb ish` for sequential
// consistency, and `caspal` (whose pairs start at even registers) does the
// rest. A CPU without them (aarch64-linux's ARMv8.0 baseline) gets LLVM's
// `ldaxp`/`stlxp` loops instead, where a pair load is atomic only once
// the store-exclusive after it succeeds.

/// Whether an aligned `ldp` or `stp` is single-copy atomic (FEAT_LSE2).
fn hasLse2(cg: *const CodeGen) bool {
    return cg.emit.zcu.cpu.has(.aarch64, .lse2);
}

/// Stores x10:x11 back to [x12] with `stlxp`, repeating from `top` (whose
/// `ldaxp` reloads them) until it succeeds. Uses x7.
fn storePairExclusive(cg: *CodeGen, lo: Reg, hi: Reg, top: Encoder.Label) Error!void {
    try cg.e.stlxp(.x7, lo, hi, .x12);
    try cg.e.cbz(true, .w, .x7, top);
}

/// `ldp`, `stp` and `caspal` need 16-byte alignment, which f80 and f128
/// lack under LLVM's layout (upstream's LLVM build fails to compile their
/// atomics on aarch64-macos too).
fn atomic16Aligned(cg: *CodeGen, ty: Index) Error!void {
    if (Type.abiAlignment(cg.ip, ty) < 16) return cg.fail("atomic operation on '{f}', which is aligned to fewer than 16 bytes", .{cg.fmtType(ty)});
}

fn atomicLoad16(cg: *CodeGen, inst: Inst.Index, ty: Index, ptr: Ref) Error!void {
    try cg.atomic16Aligned(ty);
    try cg.load(.x12, ptr);
    if (cg.hasLse2()) {
        try cg.e.ldp(.dword, .x10, .x11, .at(.x12, 0));
        try cg.e.dmb(.ish);
    } else {
        const top = try cg.e.newLabel();
        cg.e.bind(top);
        try cg.e.ldaxp(.x10, .x11, .x12);
        try cg.storePairExclusive(.x10, .x11, top);
    }
    const dst = try cg.resultMem(inst, ty) orelse return;
    try cg.storePair16(dst, .x10, .x11);
}

fn atomicStore16(cg: *CodeGen, ptr: Ref, operand: Ref) Error!void {
    try cg.atomic16Aligned(cg.typeOf(operand));
    const v = try cg.pairVal(operand);
    try cg.load(.x12, ptr);
    try cg.loadPair(.x10, .x11, v);
    if (!cg.hasLse2()) {
        const top = try cg.e.newLabel();
        cg.e.bind(top);
        try cg.e.ldaxp(.x4, .x5, .x12);
        return cg.storePairExclusive(.x10, .x11, top);
    }
    try cg.e.dmb(.ish);
    try cg.e.stp(.dword, .x10, .x11, .at(.x12, 0));
    try cg.e.dmb(.ish);
}

/// `ref`'s value in memory, which `loadPair` then loads with x16 alone.
fn pairVal(cg: *CodeGen, ref: Ref) Error!Val {
    const v = try cg.valOf(ref);
    return memVal(v.ty, try cg.valMem(v));
}

fn storePair16(cg: *CodeGen, dst: Mem, lo: Reg, hi: Reg) Error!void {
    try cg.storeReg(dst, lo, 8);
    try cg.storeReg(dst.plus(8), hi, 8);
}

/// `caspal` of x10:x11 (the expected value, then the old one) and x2:x3
/// (the new value) at [x12]; sets `ne` if it failed. Uses x4-x7.
/// Without LSE, an exclusive loop that stores the old value back when it
/// differs, as LLVM's, so the old value read is atomic.
fn casPair(cg: *CodeGen) Error!void {
    const e = &cg.e;
    try e.mov(.x, .x4, .x10);
    try e.mov(.x, .x5, .x11);
    if (!cg.hasLse()) {
        const top = try e.newLabel();
        const differ = try e.newLabel();
        const done = try e.newLabel();
        e.bind(top);
        try e.ldaxp(.x10, .x11, .x12);
        try e.logic(.eor, .x, .x6, .x10, .r(.x4));
        try e.logic(.eor, .x, .x7, .x11, .r(.x5));
        try e.logic(.orr, .x, .x6, .x6, .r(.x7));
        try e.cbz(true, .x, .x6, differ);
        try cg.storePairExclusive(.x2, .x3, top);
        try e.b(.{ .label = done });
        e.bind(differ);
        try cg.storePairExclusive(.x10, .x11, top);
        e.bind(done);
        return e.cmp(.x, .x6, .{ .imm = 0 });
    }
    try e.casp(.dword, .acq_rel, .x10, .x2, .x12);
    try e.logic(.eor, .x, .x6, .x10, .r(.x4));
    try e.logic(.eor, .x, .x7, .x11, .r(.x5));
    try e.logic(.orr, .x, .x6, .x6, .r(.x7));
    try e.cmp(.x, .x6, .{ .imm = 0 });
}

fn cmpxchg16(cg: *CodeGen, inst: Inst.Index, ty: Index, x: Ir.Cmpxchg) Error!void {
    try cg.atomic16Aligned(cg.typeOf(x.expected));
    const expected = try cg.pairVal(x.expected);
    const new = try cg.pairVal(x.new);
    try cg.load(.x12, x.ptr);
    try cg.loadPair(.x10, .x11, expected);
    try cg.loadPair(.x2, .x3, new);
    try cg.casPair();
    const dst = try cg.resultMem(inst, ty) orelse return;
    try cg.e.cset(.x, .x13, .ne);
    try cg.storeReg(dst.plus(Type.optionalFlagOffset(cg.ip, ty)), .x13, 1);
    try cg.storePair16(dst, .x10, .x11);
}

/// A `caspal` loop computing the new value in x2:x3 from the old in
/// x10:x11 and the operand in x8:x9.
fn atomicRmw16(cg: *CodeGen, inst: Inst.Index, ty: Index, x: Ir.AtomicRmw) Error!void {
    const e = &cg.e;
    try cg.atomic16Aligned(ty);
    const op = x.operation();
    if (op != .Xchg and cg.isFloat(ty)) return cg.fail("atomic float operation on '{f}'", .{cg.fmtType(ty)});
    const operand = try cg.pairVal(x.operand);
    try cg.load(.x12, x.ptr);
    try cg.loadPair(.x8, .x9, operand);
    try e.ldp(.dword, .x10, .x11, .at(.x12, 0));
    const top = try e.newLabel();
    e.bind(top);
    switch (op) {
        .Xchg => {
            try e.mov(.x, .x2, .x8);
            try e.mov(.x, .x3, .x9);
        },
        .Add => {
            try e.addSub(.adds, .x, .x2, .x10, .r(.x8));
            try e.carry(.adc, .x, .x3, .x11, .x9);
        },
        .Sub => {
            try e.addSub(.subs, .x, .x2, .x10, .r(.x8));
            try e.carry(.sbc, .x, .x3, .x11, .x9);
        },
        .And, .Nand, .Or, .Xor => {
            const l: Encoder.LogicOp = switch (op) {
                .Or => .orr,
                .Xor => .eor,
                else => .@"and",
            };
            try e.logic(l, .x, .x2, .x10, .r(.x8));
            try e.logic(l, .x, .x3, .x11, .r(.x9));
            if (op == .Nand) {
                try e.mvn(.x, .x2, .x2);
                try e.mvn(.x, .x3, .x3);
            }
        },
        .Max, .Min => {
            // Flags of old - operand; the old value stays where it wins.
            try e.cmp(.x, .x10, .r(.x8));
            try e.carry(.sbcs, .x, .zr, .x11, .x9);
            const keep: Cond = if (op == .Max) (if (cg.signed(ty)) .ge else .hs) else (if (cg.signed(ty)) .lt else .lo);
            try e.csel(.csel, .x, .x2, .x10, .x8, keep);
            try e.csel(.csel, .x, .x3, .x11, .x9, keep);
        },
    }
    try cg.casPair();
    try e.bcond(.ne, top);
    const dst = try cg.resultMem(inst, ty) orelse return;
    try cg.storePair16(dst, .x10, .x11);
}

/// Whether the CPU has the ARMv8.1 atomics (LSE). aarch64-linux's
/// baseline, ARMv8.0, does not: its atomics are exclusive load and
/// store loops, as upstream's LLVM backend emits for it.
fn hasLse(cg: *const CodeGen) bool {
    return cg.emit.zcu.cpu.has(.aarch64, .lse);
}

/// `cas` acquire-release: compares the `size` bytes at `[base]` with
/// `expected`, zero-extended, stores `new` if they are equal, and leaves
/// the old value in `expected`. Without LSE, a loop that uses x14 and x17.
fn atomicCas(cg: *CodeGen, size: Size, expected: Reg, new: Reg, base: Reg) Error!void {
    const e = &cg.e;
    if (cg.hasLse()) return e.cas(size, .acq_rel, expected, new, base);
    const width: Encoder.Width = if (size == .dword) .x else .w;
    const top = try e.newLabel();
    const done = try e.newLabel();
    try e.mov(.x, .x14, expected);
    e.bind(top);
    try e.ldaxr(size, expected, base);
    try e.cmp(width, expected, .r(.x14));
    try e.bcond(.ne, done);
    try e.stlxr(size, .x17, new, base);
    try e.cbz(true, .w, .x17, top);
    e.bind(done);
}

/// The LSE read-modify-write `op` acquire-release (`Encoder.atomic`):
/// `dst` gets the old `size` bytes at `[base]`, zero-extended, and memory
/// gets `old op src`, where `src` is extended as its type loads. Without
/// LSE, a loop that uses x11, x13, and x17.
fn atomicOp(cg: *CodeGen, op: Encoder.AtomicOp, size: Size, src: Reg, dst: Reg, base: Reg) Error!void {
    const e = &cg.e;
    if (cg.hasLse()) return e.atomic(op, size, .acq_rel, src, dst, base);
    assert(dst != .x11 and dst != .x13 and src != .x11 and src != .x13);
    const width: Encoder.Width = if (size == .dword) .x else .w;
    const top = try e.newLabel();
    e.bind(top);
    try e.ldaxr(size, dst, base);
    switch (op) {
        .swp => try e.mov(.x, .x11, src),
        .add => try e.addSub(.add, .x, .x11, dst, .r(src)),
        .clr => try e.logic(.bic, .x, .x11, dst, .r(src)),
        .eor => try e.logic(.eor, .x, .x11, dst, .r(src)),
        .set => try e.logic(.orr, .x, .x11, dst, .r(src)),
        .smax, .smin, .umax, .umin => {
            const is_signed = op == .smax or op == .smin;
            // The old value is zero-extended and `src` sign-extended: a
            // signed byte or halfword compares sign-extended.
            if (is_signed and (size == .byte or size == .half)) {
                try e.sxt(size, .x, .x13, dst);
                try e.cmp(.x, .x13, .r(src));
            } else try e.cmp(width, dst, .r(src));
            const keep_old: Cond = switch (op) {
                .smax => .gt,
                .smin => .lt,
                .umax => .hi,
                .umin => .lo,
                else => unreachable,
            };
            try e.csel(.csel, .x, .x11, dst, src, keep_old);
        },
    }
    try e.stlxr(size, .x17, .x11, base);
    try e.cbz(true, .w, .x17, top);
}

fn ret(cg: *CodeGen, operand: Ref) Error!void {
    const ty = cg.fn_ty.return_type;
    if (isC(cg.fn_ty.cc)) {
        try cg.cRet(operand);
    } else switch (cg.autoClass(ty)) {
        .none => {},
        .gpr => try cg.loadGpr(.x0, operand),
        .gpr_pair => try cg.loadPair(.x0, .x1, try cg.valOf(operand)),
        .fpr => try cg.loadFp(.v0, try cg.valOf(operand)),
        .memory => {
            // Already there (`planRetCalls`).
            if (operand.toIndex()) |v| if (cg.homes[@backingInt(v)] == .result) return cg.epilogue();
            try cg.loadMem(.x12, cg.ret_ptr_slot.?, .usize_type);
            try cg.copyTo(.at(.x12, 0), operand);
        },
    }
    try cg.epilogue();
}

fn cRet(cg: *CodeGen, operand: Ref) Error!void {
    const ty = cg.fn_ty.return_type;
    switch (cg.cRetClass(ty)) {
        .none => {},
        .int => try cg.loadGpr(.x0, operand),
        .int_pair => try cg.loadPair(.x0, .x1, try cg.valOf(operand)),
        .fpr => try cg.loadFp(.v0, try cg.valOf(operand)),
        .fpr_run => {
            const h = cg.cHfa(ty).?;
            try cg.loadFpRun(try cg.valMem(try cg.valOf(operand)), 0, h.n, h.size);
        },
        .indirect => {
            try cg.loadMem(.x12, cg.ret_ptr_slot.?, .usize_type);
            try cg.copyTo(.at(.x12, 0), operand);
        },
        .unsupported, .bool_split => unreachable, // rejected by `setupParams`
    }
}

/// Calls panic handler `target` from cold code through a chain of stubs,
/// one per call the backend inlined that is open here, so that the stack
/// trace shows the frames those calls would have had (docs/slop/architecture.md,
/// "Synthetic panic frames"), as the x86_64 backend does: the `bl` itself
/// is at the outermost such call's site, in its caller, and the stubs
/// after the blocks (`emitStubs`) are at each next site inward, the last
/// at the check. Without such calls open, or past the stubs' room, calls
/// `target`.
fn panicThroughStubs(cg: *CodeGen, target: SymbolKey) Error!void {
    const open = cg.dbg_open.items;
    var first: ?usize = null;
    var depth: u32 = 0;
    for (open, 0..) |o, i| if (o.backend) {
        if (first == null) first = i;
        depth += 1;
    };
    // `Atom.Unwind.epilogue` counts the stubs and probes in 16 bits.
    if (first == null or cg.stub_bytes + stub_size * depth > 0xfe00) return cg.e.bl(.{ .sym = target });
    cg.stub_bytes += stub_size * depth;
    const b = first.?;
    const label = try cg.e.newLabel();
    try cg.stub_chains.append(cg.gpa, .{ .label = label, .target = target, .open_start = @intCast(cg.stub_open.items.len), .open_len = @intCast(open.len), .line = cg.dbg_line, .column = cg.dbg_column });
    try cg.stub_open.appendSlice(cg.gpa, open);
    // The call is the outermost inlined call's caller's: the inlined calls
    // from there in end before it. No code that runs follows it.
    const pc: u32 = @intCast(cg.e.code.items.len);
    for (open[b..]) |o| cg.dbg_inlines.items[o.index].high = pc;
    const site = cg.dbg_inlines.items[open[b].index];
    if (b != 0) {
        try cg.e.switchLines(cg.dbg_inlines.items[open[b - 1].index].file, open[b - 1].index + 1);
    } else try cg.e.switchLines(0, 0);
    cg.dbg_open.shrinkRetainingCapacity(b);
    cg.dbg_line = site.call_line;
    cg.dbg_column = site.call_column;
    try cg.e.line(site.call_line, site.call_column);
    try cg.e.bl(.{ .label = label });
}

/// The bytes of a stub: `stp x29, x30, [sp, #-16]!; mov x29, sp; bl`.
const stub_size = 12;

/// The stubs of the panic calls `panicThroughStubs` made, after the
/// blocks. Each makes a frame record, as a prologue does, so the frame
/// pointer chain and the stubs' unwind info (the frame record's rule with
/// no saved registers, `Atom.Unwind.epilogue`) step through it. Stub k is
/// in entries copying the inlined calls open from the k-th backend-inlined
/// call to the next one (from the function's own for the first), at the
/// next one's site, and calls stub k + 1, which follows; the last is at
/// the check and calls the handler.
fn emitStubs(cg: *CodeGen) Error!void {
    for (cg.stub_chains.items) |ch| {
        cg.e.bind(ch.label);
        const open = cg.stub_open.items[ch.open_start..][0..ch.open_len];
        const clones_start = cg.dbg_inlines.items.len;
        var parent: u32 = Atom.Debug.Inline.none;
        var i: usize = 0;
        while (i < open.len) {
            // The entries up to the next backend-inlined call after `i`.
            var end = i + 1;
            while (end < open.len and !open[end].backend) end += 1;
            if (i == 0) {
                // The first stub's: those up to the second backend call.
                end = 0;
                var seen: u32 = 0;
                while (end < open.len) : (end += 1) {
                    if (open[end].backend) {
                        seen += 1;
                        if (seen == 2) break;
                    }
                }
            }
            const pc: u32 = @intCast(cg.e.code.items.len);
            for (open[i..end]) |o| {
                var copy = cg.dbg_inlines.items[o.index];
                copy.low = pc;
                copy.parent = parent;
                parent = @intCast(cg.dbg_inlines.items.len);
                try cg.dbg_inline_callees.append(cg.gpa, cg.dbg_inline_callees.items[o.index]);
                try cg.dbg_inlines.append(cg.gpa, copy);
            }
            try cg.e.switchLines(cg.dbg_inlines.items[parent].file, parent + 1);
            if (end < open.len) {
                const site = cg.dbg_inlines.items[open[end].index];
                try cg.e.line(site.call_line, site.call_column);
            } else try cg.e.line(ch.line, ch.column);
            try cg.e.stp(.dword, .fp, .lr, .{ .base = .sp, .offset = .{ .pre = -16 } });
            try cg.e.mov(.x, .fp, .sp);
            if (end < open.len) {
                const next = try cg.e.newLabel();
                try cg.e.bl(.{ .label = next });
                cg.e.bind(next);
            } else try cg.e.bl(.{ .sym = ch.target });
            i = end;
        }
        const end_pc: u32 = @intCast(cg.e.code.items.len);
        for (cg.dbg_inlines.items[clones_start..]) |*in| in.high = end_pc;
    }
    if (cg.stub_chains.items.len != 0) try cg.e.switchLines(0, 0);
}

/// The epilogue: `popFrame`, then `ret`.
fn epilogue(cg: *CodeGen) Error!void {
    // The epilogue belongs to the closing brace, as in upstream's line tables.
    try cg.e.line(cg.ir.rbrace_line, cg.ir.rbrace_column);
    try cg.popFrame();
    try cg.e.ret();
}

/// Pops the frame: `mov sp, fp` (or `sub sp, fp, #16n` above `n` saved
/// pairs), the saved pairs' `ldp`s in reverse, and `ldp fp, lr, [sp], #16`.
fn popFrame(cg: *CodeGen) Error!void {
    const n = @popCount(cg.saved);
    if (n == 0) {
        try cg.e.mov(.x, .sp, .fp);
    } else {
        try cg.e.addSub(.sub, .x, .sp, .fp, .{ .imm = 16 * @as(u12, n) });
        var j: usize = 4;
        while (j > 0) {
            j -= 1;
            if (cg.saved >> @intCast(8 + j) & 1 != 0) try cg.e.ldpFp(.f64, float_regs[2 * j + 1], float_regs[2 * j], .{ .base = .sp, .offset = .{ .post = 16 } });
        }
        var k: usize = 5;
        while (k > 0) {
            k -= 1;
            if (cg.saved >> @intCast(k) & 1 != 0) try cg.e.ldp(.dword, pairReg(k, 1), pairReg(k, 0), .{ .base = .sp, .offset = .{ .post = 16 } });
        }
    }
    try cg.e.ldp(.dword, .fp, .lr, .{ .base = .sp, .offset = .{ .post = 16 } });
}

/// Loads a value of class `gpr` (at most 8 bytes) into `reg`.
fn loadGpr(cg: *CodeGen, reg: Reg, ref: Ref) Error!void {
    try cg.loadGprVal(reg, try cg.valOf(ref));
}

fn loadGprVal(cg: *CodeGen, reg: Reg, v: Val) Error!void {
    const size = Type.abiSize(cg.ip, v.ty);
    switch (size) {
        1, 2, 4, 8 => try cg.loadVal(reg, v),
        else => try cg.loadBytes(reg, try cg.valMem(v), size),
    }
}

/// Loads a value of 9 to 16 bytes into `lo` and `hi`.
fn loadPair(cg: *CodeGen, lo: Reg, hi: Reg, v: Val) Error!void {
    const size = Type.abiSize(cg.ip, v.ty);
    const m = try cg.valMem(v);
    try cg.e.ldr(.dword, lo, try cg.access(m, 8, .x16));
    try cg.loadBytes(hi, m.plus(8), size - 8);
}

/// Loads the error return trace pointer, or null if the function has none.
fn loadTrace(cg: *CodeGen, reg: Reg) Error!void {
    if (cg.trace_slot) |m| {
        try cg.loadMem(reg, m, .usize_type);
    } else {
        try cg.e.movImm(.x, reg, 0);
    }
}

/// x9 = the address of thread-local `t` on aarch64-linux. An executable
/// has its own in its static block (local-exec) and a shared library's
/// through the slot of its offset, which the loader writes
/// (initial-exec); so does other code than position-independent code for
/// its own, and an object reaches another module's initial-exec.
/// Position-independent code calls the variable's TLS descriptor, which
/// a shared object holds itself (`aarch64_tlsdesc`) and a pic object
/// leaves to the final link, as upstream's code does. The descriptor
/// call clobbers only x0, x1 and lr, which hold no values.
fn linuxThreadLocal(cg: *CodeGen, t: Emit.TlsTarget) Error!void {
    const emit = cg.emit;
    if (t.slot) {
        try cg.loadMem(.x9, .sym(t.key, 0), .usize_type);
    } else if (emit.pic == .pic) {
        if (emit.shared) {
            const zeros: [16]u8 = @splat(0);
            try cg.e.threadLocalDesc(try emit.contentAtom(8, &zeros, &.{t.key}, &.{.init(0, .aarch64_tlsdesc, 0, 0)}), false);
        } else try cg.e.threadLocalDesc(t.key, true);
        try cg.e.mov(.x, .x9, .x0);
    } else if (t.local) {
        return cg.e.threadLocalOffset(.x9, t.key);
    } else try cg.e.threadLocalInitial(.x9, t.key);
    try cg.e.raw(Encoder.System.mrs_tpidr_el0 | 10); // mrs x10, tpidr_el0
    try cg.e.addSub(.add, .x, .x9, .x10, .{ .reg = .{ .reg = .x9 } });
}

/// Calls the function in extern slot `name` (`Emit.useExtern`), which the
/// linker binds to libSystem's or compiler_rt's definition. Uses x16.
fn callExtern(cg: *CodeGen, name: []const u8) Error!void {
    _ = try cg.emit.requestCompilerRtExport(name);
    const slot = try cg.emit.useExtern(name, false);
    try cg.loadMem(.x16, .sym(slot, 0), .usize_type);
    try cg.e.blr(.x16);
}

fn call(cg: *CodeGen, inst: Inst.Index, data: Inst.Data) Error!void {
    const ip = cg.ip;
    const ir = cg.ir;
    const extra = ir.extraData(Ir.Call, data.pl_op.payload);
    // `@call(.always_tail, ...)`: Sema made the callee's type the
    // caller's, so its arguments go where the caller's own came, and its
    // result where the caller's goes; the caller's frame is popped and the
    // callee branched to.
    const tail = extra.data.flags.always_tail;
    const args = ir.refSlice(extra.end, extra.data.args_len);
    const callee_ref = data.pl_op.operand;
    const callee_val: ?Index = if (callee_ref.toInterned()) |v| switch (ip.indexToKey(v)) {
        .func => v,
        .ptr => |p| if (p.base == .nav and p.byte_offset == 0 and ip.keyTag(ip.getNav(p.base.nav).val) == .func) ip.getNav(p.base.nav).val else null,
        else => null,
    } else null;
    const callee_ty = cg.calleeType(callee_ref);
    const ret_ty = extra.data.ret_ty;
    const is_c = isC(callee_ty.cc);
    // A scalar result in a register is moved there from x0 (or v0), and
    // so is a vector returned in v0.
    const vec_in_v0 = cg.inVec(ret_ty) and (if (is_c) cg.cRetClass(ret_ty) == .fpr else cg.autoClass(ret_ty) == .fpr);
    const in_reg = !tail and (cg.homes[@backingInt(inst)] == .reg or (cg.homes[@backingInt(inst)] == .vreg and (vec_in_v0 or !cg.inVec(ret_ty))));
    // Written straight into this function's result (`planRetCalls`).
    const to_result: ?u32 = switch (cg.homes[@backingInt(inst)]) {
        .result => |off| off,
        else => null,
    };
    const dst = if (tail or in_reg or to_result != null) null else try cg.resultMem(inst, ret_ty);
    var pn_save: ?Mem = null;
    var stack_args = false;

    const vals = try cg.gpa.alloc(Val, args.len);
    defer cg.gpa.free(vals);
    for (args, vals) |arg, *v| v.* = try cg.valOf(arg);
    if (is_c) {
        if (cg.cClass(ret_ty) == .unsupported) return cg.fail("C call returning '{f}'", .{cg.fmtType(ret_ty)});
        if (tail and callee_ty.is_var_args) return cg.fail("tail call to a variadic function", .{});
        if (callee_ty.cc == .aarch64_preserve_none and cg.fn_ty.cc != .aarch64_preserve_none) {
            if (tail) return cg.fail("tail call with calling convention 'aarch64_preserve_none'", .{});
            // The callee preserves none of x19-x28, which this function's
            // callers expect kept, and its arguments use x20-x28.
            pn_save = try cg.allocSlot(80, 16);
            for (0..10) |k| try cg.storeReg(pn_save.?.plus(@intCast(8 * k)), @fromBackingInt(@intCast(19 + k)), 8);
        }
        try cg.cCallArgs(callee_ty.cc, vals, if (callee_ty.is_var_args) callee_ty.param_types.len else null, tail);
        if (cg.cRetClass(ret_ty) == .indirect) try cg.resultPtrTo(dst, tail);
    } else {
        const tys = try cg.gpa.alloc(Index, args.len);
        defer cg.gpa.free(tys);
        const locs = try cg.gpa.alloc(ArgLoc, args.len);
        defer cg.gpa.free(locs);
        for (vals, tys) |v, *t| t.* = v.ty;
        _ = cg.autoArgs(tys, locs);
        for (locs) |l| switch (l) {
            .stack, .stack_indirect => stack_args = true,
            else => {},
        };
        try cg.placeArgs(vals, locs, tail);
        if (cg.autoClass(ret_ty) == .memory) try cg.resultPtrTo(dst, tail);
        if (to_result) |off| {
            try cg.loadMem(.x8, cg.ret_ptr_slot.?, .usize_type);
            if (off != 0) try cg.e.addSub(.add, .x, .x8, .x8, .{ .imm = @intCast(off) });
        }
        try cg.loadTrace(.x15);
    }
    if (callee_val == null) try cg.load(.x16, callee_ref);
    if (tail) {
        try cg.popFrame();
        if (callee_val) |f| try cg.e.b(.{ .sym = try cg.emit.funcKey(f) }) else try cg.e.br(.x16);
        return;
    }
    if (callee_val) |f| {
        // A panic in code the backend inlined, with its arguments in
        // registers, gets the frames of the calls it was inlined from.
        if (ret_ty == .noreturn_type and cg.in_cold and !is_c and !stack_args and !cg.outermost_frame) {
            try cg.panicThroughStubs(try cg.emit.funcKey(f));
        } else try cg.e.bl(.{ .sym = try cg.emit.funcKey(f) });
    } else try cg.e.blr(.x16);
    if (pn_save) |save| for (0..10) |k| try cg.loadMem(@fromBackingInt(@intCast(19 + k)), save.plus(@intCast(8 * k)), .usize_type);
    if (in_reg) {
        // f32 and f64 results come back in v0 in every convention.
        if (vec_in_v0) return vector.move(cg, cg.homes[@backingInt(inst)].vreg, .v0);
        if (cg.homes[@backingInt(inst)] == .vreg) return cg.setFpResult(inst, ret_ty, .v0);
        return cg.setResult(inst, ret_ty, .x0);
    }
    const m = dst orelse return;
    if (is_c) return cg.cCallResult(ret_ty, m);
    const size = Type.abiSize(ip, ret_ty);
    switch (cg.autoClass(ret_ty)) {
        .gpr => try cg.storeBytes(m, .x0, size),
        .gpr_pair => {
            try cg.storeReg(m, .x0, 8);
            try cg.storeBytes(m.plus(8), .x1, size - 8);
        },
        .fpr => try cg.storeFp(m, .v0, size),
        .none, .memory => {},
    }
}

/// Puts x8, the address a call's result returned in memory goes to: `dst`,
/// or for a tail call the caller's own result pointer.
fn resultPtrTo(cg: *CodeGen, dst: ?Mem, tail: bool) Error!void {
    if (tail) return cg.loadMem(.x8, cg.ret_ptr_slot.?, .usize_type);
    if (dst) |m| try cg.addrTo(.x8, m);
}

/// Puts call arguments where `locs` says. Only general registers that are
/// arguments and v0-v7 are written besides the scratch registers, and each
/// argument register is written once, after the copies that use scratch
/// registers. A tail call's stack arguments replace the caller's incoming
/// ones (at fp + 16), which they may be computed from, so they are copied
/// to slots first.
fn placeArgs(cg: *CodeGen, vals: []const Val, locs: []const ArgLoc, tail: bool) Error!void {
    const ip = cg.ip;
    const temps = try cg.gpa.alloc(Mem, if (tail) vals.len else 0);
    defer cg.gpa.free(temps);
    for (vals, locs, 0..) |v, l, i| switch (l) {
        .stack => |off| if (tail) {
            temps[i] = try cg.allocSlot(Type.abiSize(ip, v.ty), @min(Type.abiAlignment(ip, v.ty), 16));
            try cg.copyVal(temps[i], v);
        } else try cg.copyVal(.at(.sp, @intCast(off)), v),
        .bool_split => |b| if (b.n > b.inRegs()) {
            if (tail) return cg.fail("tail call passing '{f}' on the stack", .{cg.fmtType(v.ty)});
            const m = try cg.valMem(v);
            for (b.inRegs()..b.n) |k| {
                try cg.extractBool(.x9, m, @intCast(k));
                try cg.e.str(.byte, .x9, try cg.access(.at(.sp, @intCast(b.stack + (k - b.inRegs()) * b.slot)), 1, .x16));
            }
        },
        .gpr_indirect, .stack_indirect => {
            // The copy lives in the caller's frame, which a tail call pops.
            if (tail) return cg.fail("tail call passing '{f}' by reference", .{cg.fmtType(v.ty)});
            // A copy the callee may modify.
            const size = Type.abiSize(ip, v.ty);
            const copy = try cg.allocSlot(size, @min(Type.abiAlignment(ip, v.ty), 16));
            try cg.copyVal(copy, v);
            if (l == .stack_indirect) {
                try cg.addrTo(.x9, copy);
                try cg.storeReg(.at(.sp, @intCast(l.stack_indirect)), .x9, 8);
            } else {
                try cg.addrTo(argReg(l.gpr_indirect), copy);
            }
        },
        else => {},
    };
    if (tail) for (vals, locs, 0..) |v, l, i| switch (l) {
        .stack => |off| try cg.copyVal(.at(.fp, @intCast(16 + off)), memVal(v.ty, temps[i])),
        else => {},
    };
    for (vals, locs) |v, l| switch (l) {
        .gpr => |r| try cg.loadGprVal(argReg(r), v),
        .gpr_pair => |r| try cg.loadPair(argReg(r), argReg(r + 1), v),
        .fpr => |r| try cg.loadFp(argVReg(r), v),
        .fpr_run => |run| try cg.loadFpRun(try cg.valMem(v), run.first, run.n, run.size),
        .bool_split => |b| {
            const m = try cg.valMem(v);
            for (0..b.inRegs()) |k| try cg.extractBool(argReg(b.gp + @as(u8, @intCast(k))), m, @intCast(k));
        },
        else => {},
    };
}

/// Loads bool `k` of the bit-packed bool vector at `m` into `reg`.
fn extractBool(cg: *CodeGen, reg: Reg, m: Mem, k: u8) Error!void {
    try cg.e.ldr(.byte, reg, try cg.access(m.plus(k / 8), 1, .x16));
    const bit: u6 = @intCast(k % 8);
    try cg.e.bitfield(.ubfm, .w, reg, reg, bit, bit); // ubfx reg, reg, #bit, #1
}

/// Packs the bools of `b`, arguments of this function, into the
/// `size`-byte bool vector at `dst`.
fn gatherBools(cg: *CodeGen, dst: Mem, b: BoolSplit, size: u64) Error!void {
    for (0..size) |byte| {
        try cg.e.movImm(.x, .x9, 0);
        for (0..8) |j| {
            const k = byte * 8 + j;
            if (k >= b.n) break;
            if (k < b.inRegs()) {
                try cg.e.logic(.@"and", .w, .x10, argReg(b.gp + @as(u8, @intCast(k))), .{ .imm = 1 });
            } else {
                try cg.e.ldr(.byte, .x10, try cg.access(.at(.fp, @intCast(16 + b.stack + (k - b.inRegs()) * b.slot)), 1, .x16));
                try cg.e.logic(.@"and", .w, .x10, .x10, .{ .imm = 1 });
            }
            try cg.e.logic(.orr, .w, .x9, .x9, .{ .reg = .{ .reg = .x10, .amount = @intCast(j) } });
        }
        try cg.storeReg(dst.plus(@intCast(byte)), .x9, 1);
    }
}

/// Places the arguments of a call to a C function, as `placeArgs`.
fn cCallArgs(cg: *CodeGen, cc: InternPool.CallingConvention, vals: []const Val, var_from: ?usize, tail: bool) Error!void {
    const tys = try cg.gpa.alloc(Index, vals.len);
    defer cg.gpa.free(tys);
    const locs = try cg.gpa.alloc(ArgLoc, vals.len);
    defer cg.gpa.free(locs);
    for (vals, tys) |v, *t| {
        t.* = v.ty;
        if (cg.cClass(v.ty) == .unsupported) return cg.fail("C argument of type '{f}'", .{cg.fmtType(v.ty)});
    }
    try cg.cArgsSupported(cc, tys, var_from != null);
    _ = cg.cArgs(cc, tys, var_from, locs);
    try cg.placeArgs(vals, locs, tail);
}

/// Stores the result of a C call, of type `ret_ty`, to `dst`.
fn cCallResult(cg: *CodeGen, ret_ty: Index, dst: Mem) Error!void {
    const size = Type.abiSize(cg.ip, ret_ty);
    switch (cg.cRetClass(ret_ty)) {
        .none, .indirect, .unsupported, .bool_split => {},
        .int => try cg.storeBytes(dst, .x0, size),
        .int_pair => {
            try cg.storeReg(dst, .x0, 8);
            try cg.storeBytes(dst.plus(8), .x1, size - 8);
        },
        .fpr => try cg.storeFp(dst, .v0, size),
        .fpr_run => {
            const h = cg.cHfa(ret_ty).?;
            try cg.storeFpRun(dst, 0, h.n, h.size);
        },
    }
}

/// `@cVaArg(list, T)`: the value at Apple's `va_list` pointer, which
/// advances by the value's 8-byte slot.
fn cVaArg(cg: *CodeGen, inst: Inst.Index, ty: Index, list: Ref) Error!void {
    const ip = cg.ip;
    const size = Type.abiSize(ip, ty);
    try cg.load(.x12, list);
    try cg.e.ldr(.dword, .x13, .at(.x12, 0));
    if (Type.abiAlignment(ip, ty) >= 16) {
        try cg.e.addSub(.add, .x, .x13, .x13, .{ .imm = 15 });
        try cg.e.logic(.@"and", .x, .x13, .x13, .{ .imm = ~@as(u64, 15) });
    }
    const indirect = cg.cClass(ty) == .indirect;
    try cg.e.addSub(.add, .x, .x14, .x13, .{ .imm = if (indirect) 8 else @intCast(std.mem.alignForward(u64, size, 8)) });
    try cg.e.str(.dword, .x14, .at(.x12, 0));
    if (indirect) try cg.e.ldr(.dword, .x13, .at(.x13, 0));
    const dst = try cg.resultMem(inst, ty) orelse return;
    // Callers promote a variadic f32 to f64, as C does.
    if (ty == .f32_type) {
        try cg.e.ldrFp(.f64, .v0, .at(.x13, 0));
        try cg.e.fcvt(.f32, .v0, .f64, .v0);
        return cg.storeFp(dst, .v0, 4);
    }
    try cg.copyMem(dst, .at(.x13, 0), size);
}

// ---------------------------------------------------------------- inline assembly
//
// Templates use the GNU/LLVM aarch64 syntax. bs assembles the loads,
// stores, moves, arithmetic, branches, and system instructions that std
// and system-call stubs use, and the NEON instructions of std's crypto
// (AES, PMULL, SHA-256). Every value lives in memory, so operands get
// scratch registers: `{xN}` constraints that register, `r` a free one of
// x0-x15, `w` a free SIMD register and `x` one of v0-v15; a digit ties an
// input to that output's register. `X`, `i`, `n`, and `N` inputs are
// substituted as symbols or immediates. Callee-saved registers the
// template names or the operands get are saved around it.

const AsmArg = union(enum) { sym: struct { key: SymbolKey, off: i32 }, imm: i64, reg: Reg, vreg: VReg };

/// The register an output is in.
const AsmOut = union(enum) { gpr: Reg, fpr: VReg };

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
    const source = ip.stringSlice(extra.data.source);

    var names: std.StringHashMapUnmanaged(AsmArg) = .empty;
    defer names.deinit(cg.gpa);
    // Registers named by constraints; `r` operands get others.
    var used: u64 = 0;
    for (ops) |op| {
        const c = asmAlternative(std.mem.trimStart(u8, ip.stringSlice(op.constraint), "=+&"));
        if (regConstraint(c)) |rn| if (parseReg(rn)) |r| {
            used |= @as(u64, 1) << @backingInt(r.reg);
        };
    }
    // SIMD registers the template names; `w` and `x` operands get others.
    var vused: u32 = 0;
    for (0..32) |r| {
        if (mentionsVReg(source, @intCast(r))) vused |= @as(u32, 1) << @intCast(r);
    }
    const free_regs = [_]Reg{ .x9, .x10, .x11, .x12, .x13, .x14, .x15, .x0, .x1, .x2, .x3, .x4, .x5, .x6, .x7, .x8 };
    // Callee-saved registers the template mentions or the clobbers name,
    // saved to slots first. A context switch (zio's) names them only as
    // clobbers, and its caller's values live in them. A naked function
    // has no frame to save them in, and saves nothing, as upstream.
    const clobbered = extra.data.callee_saved_clobbers;
    const naked = cg.fn_ty.cc == .naked;
    var saved: [10]?Mem = @splat(null);
    if (!naked) for (19..29) |r| {
        if (mentionsReg(source, @intCast(r)) or used & (@as(u64, 1) << @intCast(r)) != 0 or clobbered >> @intCast(Ir.Asm.aarch64_x19_bit + r - 19) & 1 != 0) {
            const m = try cg.allocSlot(8, 8);
            try cg.storeReg(m, @fromBackingInt(@intCast(r)), 8);
            saved[r - 19] = m;
        }
    };
    // v8-v15, whose low halves are callee-saved (and hold f32 and f64
    // values): saved whole when the template names them, the clobbers do,
    // or an operand gets one.
    var vsaved: [8]?Mem = @splat(null);
    for (8..16) |r| {
        if (vused >> @intCast(r) & 1 != 0 or clobbered >> @intCast(Ir.Asm.aarch64_v8_bit + r - 8) & 1 != 0) try cg.saveVReg(&vsaved, @intCast(r));
    }
    const out_regs = try cg.gpa.alloc(AsmOut, outputs.len);
    defer cg.gpa.free(out_regs);
    for (outputs, out_regs) |out, *out_reg| {
        const full = ip.stringSlice(out.constraint);
        if (full.len == 0 or (full[0] != '=' and full[0] != '+')) return cg.fail("asm output constraint '{s}'", .{full});
        const read = full[0] == '+';
        // Early clobbers need nothing more: each operand has a register of
        // its own.
        const constraint = asmAlternative(std.mem.trimStart(u8, full[1..], "&"));
        const ty = if (out.operand == .none) data.ty_pl.ty else Type.ptrInfo(ip, cg.typeOf(out.operand)).child;
        if (std.mem.eql(u8, constraint, "r")) {
            const reg = for (free_regs) |r| {
                if (used & (@as(u64, 1) << @backingInt(r)) == 0) break r;
            } else return cg.fail("asm with too many register operands", .{});
            used |= @as(u64, 1) << @backingInt(reg);
            out_reg.* = .{ .gpr = reg };
            try names.put(cg.gpa, ip.stringSlice(out.name), .{ .reg = reg });
        } else if (vecConstraint(constraint)) |low| {
            const v = try cg.asmVReg(&vused, &vsaved, low);
            out_reg.* = .{ .fpr = v };
            try names.put(cg.gpa, ip.stringSlice(out.name), .{ .vreg = v });
        } else {
            const reg_name = regConstraint(constraint) orelse return cg.fail("asm output constraint '{s}'", .{full});
            out_reg.* = .{ .gpr = (parseReg(reg_name) orelse return cg.fail("unknown register in asm constraint '{s}'", .{full})).reg };
            try names.put(cg.gpa, ip.stringSlice(out.name), .{ .reg = out_reg.gpr });
        }
        if (read) {
            if (out.operand == .none) return cg.fail("asm output constraint '{s}'", .{full});
            switch (out_reg.*) {
                .gpr => |r| {
                    try cg.load(r, out.operand);
                    try cg.loadMem(r, .at(r, 0), ty);
                },
                .fpr => |v| {
                    try cg.load(.x17, out.operand);
                    try cg.loadFp(v, .{ .ty = ty, .loc = .{ .mem = .at(.x17, 0) } });
                },
            }
        }
    }
    // SIMD inputs first: loading one uses x9 and x16, which may be `r`
    // operands.
    for (inputs) |in| {
        const constraint = asmAlternative(ip.stringSlice(in.constraint));
        if (vecConstraint(constraint)) |low| {
            const v = try cg.asmVReg(&vused, &vsaved, low);
            try cg.loadFp(v, try cg.valOf(in.operand));
            try names.put(cg.gpa, ip.stringSlice(in.name), .{ .vreg = v });
        } else if (tiedOutput(constraint, outputs.len)) |k| switch (out_regs[k]) {
            .fpr => |v| try cg.loadFp(v, try cg.valOf(in.operand)),
            .gpr => {},
        };
    }
    for (inputs) |in| {
        const constraint = asmAlternative(ip.stringSlice(in.constraint));
        const is_r = std.mem.eql(u8, constraint, "r") or (std.mem.eql(u8, constraint, "rm") and cg.passInRegs(cg.typeOf(in.operand)));
        if (vecConstraint(constraint) != null) {
            // Loaded above.
        } else if (tiedOutput(constraint, outputs.len)) |k| switch (out_regs[k]) {
            .gpr => |r| try cg.load(r, in.operand),
            .fpr => {},
        } else if (is_r) {
            const reg = for (free_regs) |r| {
                if (used & (@as(u64, 1) << @backingInt(r)) == 0) break r;
            } else return cg.fail("asm with too many register operands", .{});
            used |= @as(u64, 1) << @backingInt(reg);
            try cg.load(reg, in.operand);
            try names.put(cg.gpa, ip.stringSlice(in.name), .{ .reg = reg });
        } else if (regConstraint(constraint)) |reg_name| {
            const reg = parseReg(reg_name) orelse return cg.fail("unknown register '{s}' in asm constraint", .{reg_name});
            try cg.load(reg.reg, in.operand);
            try names.put(cg.gpa, ip.stringSlice(in.name), .{ .reg = reg.reg });
        } else if (std.mem.eql(u8, constraint, "X") or std.mem.eql(u8, constraint, "i") or std.mem.eql(u8, constraint, "n") or std.mem.eql(u8, constraint, "N")) {
            const arg: AsmArg = switch (try cg.locOf(in.operand)) {
                .imm => |v| .{ .imm = @bitCast(v) },
                .addr => |m| if (m.base == .sym) .{ .sym = .{ .key = m.base.sym, .off = m.off } } else return cg.fail("asm input '{s}' must be comptime-known", .{constraint}),
                else => return cg.fail("asm input '{s}' must be comptime-known", .{constraint}),
            };
            try names.put(cg.gpa, ip.stringSlice(in.name), arg);
        } else if (std.mem.eql(u8, constraint, "m") or std.mem.eql(u8, constraint, "rm")) {
            // Only for templates that do not name the operand.
        } else return cg.fail("asm input constraint '{s}'", .{constraint});
    }
    try cg.assemble(source, &names);

    for (outputs, out_regs) |out, reg| {
        const ty = if (out.operand == .none) data.ty_pl.ty else Type.ptrInfo(ip, cg.typeOf(out.operand)).child;
        const dst: Mem = if (out.operand == .none) try cg.resultMem(inst, ty) orelse continue else dst: {
            try cg.load(.x17, out.operand);
            break :dst .at(.x17, 0);
        };
        switch (reg) {
            .gpr => |r| try cg.storeReg(dst, r, Type.abiSize(ip, ty)),
            .fpr => |v| try cg.storeFp(dst, v, Type.abiSize(ip, ty)),
        }
    }
    for (saved, 19..) |m, r| if (m) |slot| try cg.loadMem(@fromBackingInt(@intCast(r)), slot, .usize_type);
    for (vsaved, 8..) |m, r| if (m) |slot| try cg.e.ldrQ(@fromBackingInt(@intCast(r)), try cg.access(slot, 16, .x16));
}

/// The SIMD register constraints: `w`, any of v0-v31, and `x`, one of
/// v0-v15 (whether only those).
fn vecConstraint(c: []const u8) ?bool {
    if (std.mem.eql(u8, c, "w")) return false;
    if (std.mem.eql(u8, c, "x")) return true;
    return null;
}

/// The output a digit constraint ties an input to.
fn tiedOutput(c: []const u8, outputs: usize) ?usize {
    const k = std.fmt.parseInt(usize, c, 10) catch return null;
    return if (k < outputs) k else null;
}

/// A SIMD register for an asm operand that `used` does not have, of
/// v0-v15 if `low`: v16-v31 first, then v0-v7, then v8-v15, which are
/// saved to `vsaved` first.
fn asmVReg(cg: *CodeGen, used: *u32, vsaved: *[8]?Mem, low: bool) Error!VReg {
    const order = [_]u5{ 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    for (order) |r| {
        if (low and r >= 16) continue;
        if (used.* & (@as(u32, 1) << r) != 0) continue;
        used.* |= @as(u32, 1) << r;
        if (r >= 8 and r < 16) try cg.saveVReg(vsaved, r);
        return @fromBackingInt(r);
    }
    return cg.fail("asm with too many SIMD register operands", .{});
}

/// Saves v`r`, one of v8-v15, to a slot in `vsaved` unless it is saved
/// or the function is naked.
fn saveVReg(cg: *CodeGen, vsaved: *[8]?Mem, r: u5) Error!void {
    if (vsaved[r - 8] != null or cg.fn_ty.cc == .naked) return;
    const m = try cg.allocSlot(16, 16);
    try cg.e.strQ(@fromBackingInt(r), try cg.access(m, 16, .x16));
    vsaved[r - 8] = m;
}

/// Whether template `source` names SIMD register `r` (`v3`, `q3.4s`,
/// `d3`, ...), outside `%[name]` operand references.
fn mentionsVReg(source: []const u8, r: u8) bool {
    var k: usize = 0;
    while (k < source.len) {
        if (source[k] == '%') {
            k = (std.mem.findScalarPos(u8, source, k, ']') orelse return false) + 1;
            continue;
        }
        if (std.mem.findScalar(u8, "vqdshb", source[k]) != null and (k == 0 or !std.ascii.isAlphanumeric(source[k - 1]) and source[k - 1] != '_')) {
            var end = k + 1;
            while (end < source.len and std.ascii.isDigit(source[end])) end += 1;
            if (end > k + 1 and (end == source.len or !std.ascii.isAlphanumeric(source[end]) and source[end] != '_')) {
                if ((std.fmt.parseInt(u8, source[k + 1 .. end], 10) catch 255) == r) return true;
            }
            k = end;
            continue;
        }
        k += 1;
    }
    return false;
}

/// Whether template `source` names register x`r` or w`r`.
fn mentionsReg(source: []const u8, r: u8) bool {
    var it = std.mem.tokenizeAny(u8, source, " \t\n,[]!;{}");
    while (it.next()) |tok| {
        if (tok.len < 2 or (tok[0] != 'x' and tok[0] != 'w')) continue;
        if ((std.fmt.parseInt(u8, tok[1..], 10) catch continue) == r) return true;
    }
    return false;
}

/// Of comma-separated alternative constraints, the register one if there
/// is one, else the first.
fn asmAlternative(c: []const u8) []const u8 {
    if (std.mem.findScalar(u8, c, ',') == null) return c;
    var it = std.mem.splitScalar(u8, c, ',');
    while (it.next()) |alt| if (std.mem.eql(u8, alt, "r")) return alt;
    return c[0..std.mem.findScalar(u8, c, ',').?];
}

fn regConstraint(c: []const u8) ?[]const u8 {
    if (c.len < 3 or c[0] != '{' or c[c.len - 1] != '}') return null;
    return c[1 .. c.len - 1];
}

const ParsedReg = struct { reg: Reg, width: Encoder.Width };

fn parseReg(name: []const u8) ?ParsedReg {
    if (std.mem.eql(u8, name, "sp")) return .{ .reg = .sp, .width = .x };
    if (std.mem.eql(u8, name, "xzr")) return .{ .reg = .zr, .width = .x };
    if (std.mem.eql(u8, name, "wzr")) return .{ .reg = .zr, .width = .w };
    if (std.mem.eql(u8, name, "fp")) return .{ .reg = .fp, .width = .x };
    if (std.mem.eql(u8, name, "lr")) return .{ .reg = .lr, .width = .x };
    if (name.len < 2 or (name[0] != 'x' and name[0] != 'w')) return null;
    const n = std.fmt.parseInt(u8, name[1..], 10) catch return null;
    if (n > 30) return null;
    return .{ .reg = @fromBackingInt(@intCast(n)), .width = if (name[0] == 'x') .x else .w };
}

/// Container-level assembly (`comptime { asm (...); }`), which
/// src/codegen/global_asm.zig drives one statement at a time: the inline
/// assembler without a function, on a CodeGen with only `emit`, `gpa`, `e`,
/// `outermost_frame` and `global_asm` set, which is all it reads.
pub const GlobalAsm = struct {
    cg: CodeGen,
    locals: LocalLabels = .{},

    pub const Src = struct { file: u32, span: std.zig.Ast.Span };

    pub fn init(emit: *Emit, src: Src) GlobalAsm {
        var cg: CodeGen = undefined;
        cg.emit = emit;
        cg.gpa = emit.gpa;
        cg.e = .init(emit.gpa);
        cg.outermost_frame = false;
        cg.global_asm = src;
        return .{ .cg = cg };
    }

    pub fn deinit(g: *GlobalAsm) void {
        g.cg.e.deinit();
    }

    pub fn statement(g: *GlobalAsm, line: []const u8) Error!void {
        return g.cg.assembleStatement(line, &.empty, &g.locals);
    }

    pub fn fail(g: *GlobalAsm, comptime fmt: []const u8, args: anytype) Error {
        return g.cg.fail(fmt, args);
    }

    pub fn finish(g: *GlobalAsm) Error!void {
        for (g.locals.fwd) |l| if (l != null) return g.cg.fail("asm refers to an undefined local label", .{});
        g.cg.e.finish() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BranchOutOfRange => return g.cg.fail("asm branch out of range", .{}),
        };
    }
};

/// GNU as local labels `0:` to `9:`, referenced as `1f` (the next) and
/// `1b` (the previous).
const LocalLabels = struct {
    fwd: [10]?Encoder.Label = @splat(null),
    back: [10]?Encoder.Label = @splat(null),
};

fn assemble(cg: *CodeGen, source: []const u8, names: *const std.StringHashMapUnmanaged(AsmArg)) Error!void {
    var locals: LocalLabels = .{};
    var source_lines = std.mem.tokenizeScalar(u8, source, '\n');
    while (source_lines.next()) |source_line| {
        var code = source_line;
        if (std.mem.find(u8, code, "//")) |i| code = code[0..i];
        var statements = std.mem.tokenizeScalar(u8, code, ';');
        while (statements.next()) |raw| try cg.assembleStatement(std.mem.trim(u8, raw, " \t\r"), names, &locals);
    }
    for (locals.fwd) |l| if (l != null) return cg.fail("asm refers to an undefined local label", .{});
}

const AsmOperand = union(enum) {
    reg: ParsedReg,
    imm: i64,
    sym: struct { key: SymbolKey, off: i32 },
    label: Encoder.Label,
    mem: Encoder.Mem,
    /// A bare word: a barrier option or system register.
    name: []const u8,
    /// A SIMD register (`v3.16b`, `q3`, `%[name].4s`), with the
    /// arrangement it is written with.
    vreg: struct { reg: VReg, arr: ?Arrangement },
    /// A list of consecutive SIMD registers (`{v3.16b}`).
    vlist: struct { first: VReg, len: u3, arr: ?Arrangement },
};

/// A vector register's arrangement suffix (`.16b`, `.4s`, ...).
const Arrangement = enum {
    @"8b",
    @"16b",
    @"4h",
    @"8h",
    @"2s",
    @"4s",
    @"1d",
    @"2d",
    @"1q",

    /// The Q bit of an instruction on whole vectors of this arrangement.
    fn q(a: Arrangement) u32 {
        return switch (a) {
            .@"8b", .@"4h", .@"2s", .@"1d" => 0,
            .@"16b", .@"8h", .@"4s", .@"2d", .@"1q" => 1,
        };
    }
};

/// A SIMD register written as `v3`, `q3`, `d3`, `s3`, `h3` or `b3`,
/// optionally with an arrangement (`v3.4s`).
fn parseVReg(tok: []const u8) ?AsmOperand {
    if (tok.len < 2 or std.mem.findScalar(u8, "vqdshb", tok[0]) == null) return null;
    const dot = std.mem.findScalar(u8, tok, '.') orelse tok.len;
    const n = std.fmt.parseInt(u5, tok[1..dot], 10) catch return null;
    const arr: ?Arrangement = if (dot == tok.len) null else std.meta.stringToEnum(Arrangement, tok[dot + 1 ..]) orelse return null;
    return .{ .vreg = .{ .reg = @fromBackingInt(n), .arr = arr } };
}

fn assembleStatement(cg: *CodeGen, line_in: []const u8, names: *const std.StringHashMapUnmanaged(AsmArg), locals: *LocalLabels) Error!void {
    var line = line_in;
    if (line.len >= 2 and std.ascii.isDigit(line[0]) and line[1] == ':') {
        const n = line[0] - '0';
        const label = locals.fwd[n] orelse try cg.e.newLabel();
        cg.e.bind(label);
        locals.fwd[n] = null;
        locals.back[n] = label;
        line = std.mem.trim(u8, line[2..], " \t");
    }
    if (line.len == 0) return;
    if (line[0] == '.') {
        if (std.mem.eql(u8, line, ".cfi_undefined lr") or std.mem.eql(u8, line, ".cfi_undefined x30")) {
            cg.outermost_frame = true;
            return;
        }
        return cg.fail("bs does not support the assembler directive '{s}' yet", .{line});
    }
    const sp = std.mem.findAny(u8, line, " \t") orelse line.len;
    const mnemonic = line[0..sp];
    var operands: [4]AsmOperand = undefined;
    var n: usize = 0;
    // Split at commas outside brackets.
    const rest = line[sp..];
    var depth: u32 = 0;
    var start: usize = 0;
    for (rest, 0..) |c, k| {
        switch (c) {
            '[', '{' => depth += 1,
            ']', '}' => depth -|= 1,
            else => {},
        }
        if ((c == ',' and depth == 0) or k == rest.len - 1) {
            const end = if (c == ',' and depth == 0) k else k + 1;
            const tok = std.mem.trim(u8, rest[start..end], " \t");
            start = k + 1;
            if (tok.len == 0) continue;
            if (n == operands.len) return cg.fail("asm instruction with too many operands: '{s}'", .{line});
            operands[n] = try cg.asmOperand(tok, names, locals, line);
            n += 1;
        }
    }
    // A post-index immediate follows the memory operand.
    if (n >= 2 and operands[n - 2] == .mem and operands[n - 1] == .imm and std.mem.find(u8, line, "]!") == null) {
        const m = operands[n - 2].mem;
        if (m.offset != .imm or m.offset.imm != 0) return cg.fail("bad post-indexed operand: '{s}'", .{line});
        operands[n - 2] = .{ .mem = .{ .base = m.base, .offset = .{ .post = @intCast(operands[n - 1].imm) } } };
        n -= 1;
    }
    try cg.asmInst(mnemonic, operands[0..n], line);
}

fn asmOperand(cg: *CodeGen, tok: []const u8, names: *const std.StringHashMapUnmanaged(AsmArg), locals: *LocalLabels, line: []const u8) Error!AsmOperand {
    if (tok[0] == '[') {
        const close = std.mem.findScalarLast(u8, tok, ']') orelse return cg.fail("bad asm memory operand: '{s}'", .{line});
        const inner = tok[1..close];
        const pre = std.mem.endsWith(u8, tok, "!");
        var it = std.mem.tokenizeScalar(u8, inner, ',');
        const base_tok = std.mem.trim(u8, it.next() orelse return cg.fail("bad asm memory operand: '{s}'", .{line}), " \t");
        const base = switch (try cg.asmOperand(base_tok, names, locals, line)) {
            .reg => |r| r.reg,
            else => return cg.fail("bad asm memory base: '{s}'", .{line}),
        };
        var off: i64 = 0;
        if (it.next()) |off_tok| switch (try cg.asmOperand(std.mem.trim(u8, off_tok, " \t"), names, locals, line)) {
            .imm => |v| off = v,
            .reg => |r| {
                if (it.next() != null) return cg.fail("bs does not support this asm memory operand yet: '{s}'", .{line});
                return .{ .mem = .{ .base = base, .offset = .{ .index = .{ .reg = r.reg } } } };
            },
            else => return cg.fail("bad asm memory offset: '{s}'", .{line}),
        };
        const o: i32 = std.math.cast(i32, off) orelse return cg.fail("asm memory offset out of range: '{s}'", .{line});
        return .{ .mem = .{ .base = base, .offset = if (pre) .{ .pre = o } else .{ .imm = o } } };
    }
    if (tok[0] == '#') return cg.asmOperand(tok[1..], names, locals, line);
    if (tok[0] == '{') {
        // A register list: `{v1.16b}`, `{v1.16b, v2.16b}`, `{%[t].16b}`.
        if (tok[tok.len - 1] != '}') return cg.fail("bad asm register list: '{s}'", .{line});
        var it = std.mem.tokenizeAny(u8, tok[1 .. tok.len - 1], ", \t");
        var list: ?AsmOperand = null;
        while (it.next()) |r| {
            const v = switch (try cg.asmOperand(r, names, locals, line)) {
                .vreg => |v| v,
                else => return cg.fail("bad asm register list: '{s}'", .{line}),
            };
            if (list) |*l| {
                if (@backingInt(v.reg) != (@as(u32, @backingInt(l.vlist.first)) + l.vlist.len) % 32 or l.vlist.len == 4)
                    return cg.fail("bad asm register list: '{s}'", .{line});
                l.vlist.len += 1;
            } else list = .{ .vlist = .{ .first = v.reg, .len = 1, .arr = v.arr } };
        }
        return list orelse cg.fail("bad asm register list: '{s}'", .{line});
    }
    if (tok[0] == '%') {
        // `%[name]`, `%x[name]`, `%w[name]`, `%q[name]`, and a SIMD
        // operand's arrangement after it (`%[name].16b`).
        var t = tok[1..];
        var width: ?Encoder.Width = null;
        if (t.len > 0 and (t[0] == 'x' or t[0] == 'w')) {
            width = if (t[0] == 'x') .x else .w;
            t = t[1..];
        } else if (t.len > 0 and std.mem.findScalar(u8, "qdshb", t[0]) != null) {
            t = t[1..];
        }
        var arr: ?Arrangement = null;
        if (std.mem.findScalarLast(u8, t, ']')) |close| if (close + 1 < t.len) {
            if (t[close + 1] != '.') return cg.fail("bad asm operand '{s}'", .{tok});
            arr = std.meta.stringToEnum(Arrangement, t[close + 2 ..]) orelse return cg.fail("bad asm operand '{s}'", .{tok});
            t = t[0 .. close + 1];
        };
        if (t.len < 3 or t[0] != '[' or t[t.len - 1] != ']') return cg.fail("bad asm operand '{s}'", .{tok});
        var name = t[1 .. t.len - 1];
        // LLVM's `%[name:w]` form of the modifier.
        if (std.mem.findScalar(u8, name, ':')) |colon| {
            const m = name[colon + 1 ..];
            if (m.len != 1 or (m[0] != 'x' and m[0] != 'w')) return cg.fail("asm operand modifier '{s}'", .{tok});
            width = if (m[0] == 'x') .x else .w;
            name = name[0..colon];
        }
        const arg = names.get(name) orelse return cg.fail("unknown asm operand '{s}'", .{tok});
        if (arg != .vreg and arr != null) return cg.fail("bad asm operand '{s}'", .{tok});
        return switch (arg) {
            .reg => |r| .{ .reg = .{ .reg = r, .width = width orelse .x } },
            .imm => |v| .{ .imm = v },
            .sym => |s| .{ .sym = .{ .key = s.key, .off = s.off } },
            .vreg => |v| if (width != null) cg.fail("asm operand modifier '{s}' on a SIMD register", .{tok}) else .{ .vreg = .{ .reg = v, .arr = arr } },
        };
    }
    if (std.mem.eql(u8, tok, ".")) {
        const l = try cg.e.newLabel();
        cg.e.bind(l);
        return .{ .label = l };
    }
    if (tok.len == 2 and std.ascii.isDigit(tok[0]) and (tok[1] == 'f' or tok[1] == 'b')) {
        const n = tok[0] - '0';
        if (tok[1] == 'b') return .{ .label = locals.back[n] orelse return cg.fail("asm refers to an undefined local label: '{s}'", .{line}) };
        if (locals.fwd[n] == null) locals.fwd[n] = try cg.e.newLabel();
        return .{ .label = locals.fwd[n].? };
    }
    if (parseReg(tok)) |r| return .{ .reg = r };
    if (parseVReg(tok)) |v| return v;
    if (tok[0] == '-' or std.ascii.isDigit(tok[0])) {
        return .{ .imm = std.fmt.parseInt(i64, tok, 0) catch return cg.fail("bad asm immediate '{s}'", .{tok}) };
    }
    return .{ .name = tok };
}

fn asmUnsupported(cg: *CodeGen, line: []const u8) Error {
    return cg.fail("bs does not support this inline assembly instruction yet: '{s}'", .{line});
}

fn asmInst(cg: *CodeGen, mnemonic: []const u8, ops: []const AsmOperand, line: []const u8) Error!void {
    const e = &cg.e;
    const eql = std.mem.eql;
    const System = Encoder.System;
    if (try cg.asmNeon(mnemonic, ops, line)) return;
    if (ops.len == 0) {
        const word: ?u32 = if (eql(u8, mnemonic, "nop")) System.nop else if (eql(u8, mnemonic, "yield")) System.yield else if (eql(u8, mnemonic, "wfe")) System.wfe else if (eql(u8, mnemonic, "wfi")) System.wfi else if (eql(u8, mnemonic, "sev")) System.sev else if (eql(u8, mnemonic, "sevl")) System.sevl else if (eql(u8, mnemonic, "isb")) System.isb else if (eql(u8, mnemonic, "clrex")) System.clrex else null;
        if (word) |w| return e.raw(w);
        if (eql(u8, mnemonic, "ret")) return e.ret();
        return cg.asmUnsupported(line);
    }
    // The register operands' and immediates' shapes.
    const reg = struct {
        fn at(o: []const AsmOperand, i: usize) ?ParsedReg {
            return if (i < o.len and o[i] == .reg) o[i].reg else null;
        }
    }.at;
    if (eql(u8, mnemonic, "svc") or eql(u8, mnemonic, "brk") or eql(u8, mnemonic, "udf")) {
        if (ops[0] != .imm) return cg.asmUnsupported(line);
        const imm: u16 = @intCast(ops[0].imm);
        if (eql(u8, mnemonic, "svc")) return e.svc(imm);
        if (eql(u8, mnemonic, "brk")) return e.brk(imm);
        return e.udf(imm);
    }
    if (eql(u8, mnemonic, "hint")) {
        if (ops[0] != .imm or ops[0].imm < 0 or ops[0].imm > 127) return cg.asmUnsupported(line);
        return e.raw(System.nop | (@as(u32, @intCast(ops[0].imm)) << 5));
    }
    if (eql(u8, mnemonic, "dmb") or eql(u8, mnemonic, "dsb")) {
        if (ops[0] != .name) return cg.asmUnsupported(line);
        const opt = std.meta.stringToEnum(Encoder.Barrier, ops[0].name) orelse return cg.asmUnsupported(line);
        if (eql(u8, mnemonic, "dmb")) return e.dmb(opt);
        return e.raw(System.dsb | (@as(u32, @backingInt(opt)) << 8));
    }
    if (eql(u8, mnemonic, "mrs")) {
        const rt = reg(ops, 0) orelse return cg.asmUnsupported(line);
        if (ops.len != 2 or ops[1] != .name) return cg.asmUnsupported(line);
        const base = System.mrs(ops[1].name) orelse return cg.asmUnsupported(line);
        return e.raw(base | @backingInt(rt.reg));
    }
    if (eql(u8, mnemonic, "msr")) {
        if (ops.len != 2 or ops[0] != .name or !eql(u8, ops[0].name, "tpidr_el0")) return cg.asmUnsupported(line);
        const rt = reg(ops, 1) orelse return cg.asmUnsupported(line);
        return e.raw(System.msr_tpidr_el0 | @backingInt(rt.reg));
    }
    if (eql(u8, mnemonic, "ret")) {
        const r = reg(ops, 0) orelse return cg.asmUnsupported(line);
        if (r.reg != Reg.lr) return cg.asmUnsupported(line);
        return e.ret();
    }
    if (eql(u8, mnemonic, "br") or eql(u8, mnemonic, "blr")) {
        const r = reg(ops, 0) orelse return cg.asmUnsupported(line);
        return if (mnemonic[1] == 'r') e.br(r.reg) else e.blr(r.reg);
    }
    if (eql(u8, mnemonic, "b") or eql(u8, mnemonic, "bl")) {
        const target: Encoder.Target = switch (ops[0]) {
            .label => |l| .{ .label = l },
            .sym => |s| if (s.off == 0) .{ .sym = s.key } else return cg.asmUnsupported(line),
            else => return cg.asmUnsupported(line),
        };
        return if (mnemonic.len == 1) e.b(target) else e.bl(target);
    }
    if (mnemonic.len > 2 and mnemonic[0] == 'b' and mnemonic[1] == '.') {
        const cond = std.meta.stringToEnum(Cond, mnemonic[2..]) orelse (if (eql(u8, mnemonic[2..], "cs")) Cond.hs else if (eql(u8, mnemonic[2..], "cc")) Cond.lo else return cg.asmUnsupported(line));
        if (ops[0] != .label) return cg.asmUnsupported(line);
        return e.bcond(cond, ops[0].label);
    }
    if (eql(u8, mnemonic, "cbz") or eql(u8, mnemonic, "cbnz")) {
        const r = reg(ops, 0) orelse return cg.asmUnsupported(line);
        if (ops.len != 2 or ops[1] != .label) return cg.asmUnsupported(line);
        return e.cbz(mnemonic.len == 4, r.width, r.reg, ops[1].label);
    }
    if (eql(u8, mnemonic, "adr")) {
        const r = reg(ops, 0) orelse return cg.asmUnsupported(line);
        if (ops.len != 2 or ops[1] != .label) return cg.asmUnsupported(line);
        return e.adr(r.reg, ops[1].label);
    }
    if (eql(u8, mnemonic, "mov")) {
        const d = reg(ops, 0) orelse return cg.asmUnsupported(line);
        if (ops.len != 2) return cg.asmUnsupported(line);
        return switch (ops[1]) {
            .reg => |s| e.mov(d.width, d.reg, s.reg),
            .imm => |v| e.movImm(d.width, d.reg, @bitCast(v)),
            else => cg.asmUnsupported(line),
        };
    }
    if (std.mem.startsWith(u8, mnemonic, "crc32")) crc: {
        // crc32{,c}{b,h,w,x} wd, wn, (wm or xm for x)
        if (!cg.emit.zcu.cpu.has(.aarch64, .crc)) return cg.fail("inline assembly instruction '{s}' needs the target CPU feature 'crc', as upstream's assembler does", .{line});
        const rest = mnemonic[5..];
        const c = rest.len == 2 and rest[0] == 'c';
        if (rest.len != @as(usize, 1) + @intFromBool(c)) break :crc;
        const sz: u32 = switch (rest[rest.len - 1]) {
            'b' => 0,
            'h' => 1,
            'w' => 2,
            'x' => 3,
            else => break :crc,
        };
        const d = reg(ops, 0) orelse return cg.asmUnsupported(line);
        const n = reg(ops, 1) orelse return cg.asmUnsupported(line);
        const m = reg(ops, 2) orelse return cg.asmUnsupported(line);
        if (ops.len != 3 or d.width != .w or n.width != .w or m.width != (if (sz == 3) Encoder.Width.x else Encoder.Width.w)) return cg.asmUnsupported(line);
        const sf: u32 = if (sz == 3) 1 << 31 else 0;
        return e.raw(sf | 0x1ac04000 | @as(u32, @intFromBool(c)) << 12 | sz << 10 | @as(u32, @backingInt(m.reg)) << 16 | @as(u32, @backingInt(n.reg)) << 5 | @backingInt(d.reg));
    }
    if (eql(u8, mnemonic, "stp") or eql(u8, mnemonic, "ldp")) {
        const r1 = reg(ops, 0) orelse return cg.asmUnsupported(line);
        const r2 = reg(ops, 1) orelse return cg.asmUnsupported(line);
        if (ops.len != 3 or ops[2] != .mem) return cg.asmUnsupported(line);
        const size: Size = if (r1.width == .x) .dword else .word;
        return if (mnemonic[0] == 's') e.stp(size, r1.reg, r2.reg, ops[2].mem) else e.ldp(size, r1.reg, r2.reg, ops[2].mem);
    }
    const loads_stores = [_]struct { []const u8, ?Size, enum { load, store, load_signed } }{
        .{ "ldr", null, .load },           .{ "str", null, .store },          .{ "ldur", null, .load },
        .{ "stur", null, .store },         .{ "ldrb", .byte, .load },         .{ "strb", .byte, .store },
        .{ "ldrh", .half, .load },         .{ "strh", .half, .store },        .{ "ldrsb", .byte, .load_signed },
        .{ "ldrsh", .half, .load_signed }, .{ "ldrsw", .word, .load_signed },
    };
    for (loads_stores) |ls| if (eql(u8, mnemonic, ls[0])) {
        const r = reg(ops, 0) orelse return cg.asmUnsupported(line);
        if (ops.len != 2 or ops[1] != .mem) return cg.asmUnsupported(line);
        const size = ls[1] orelse if (r.width == .x) Size.dword else Size.word;
        return switch (ls[2]) {
            .load => e.ldr(size, r.reg, ops[1].mem),
            .store => e.str(size, r.reg, ops[1].mem),
            .load_signed => e.ldrs(size, r.width, r.reg, ops[1].mem),
        };
    };
    const arith = [_]struct { []const u8, Encoder.AddOp }{ .{ "add", .add }, .{ "adds", .adds }, .{ "sub", .sub }, .{ "subs", .subs } };
    for (arith) |a| if (eql(u8, mnemonic, a[0])) {
        const d = reg(ops, 0) orelse return cg.asmUnsupported(line);
        const n = reg(ops, 1) orelse return cg.asmUnsupported(line);
        if (ops.len != 3) return cg.asmUnsupported(line);
        return switch (ops[2]) {
            .reg => |m| e.addSub(a[1], d.width, d.reg, n.reg, .r(m.reg)),
            .imm => |v| if (v >= 0 and v < 4096) e.addSub(a[1], d.width, d.reg, n.reg, .{ .imm = @intCast(v) }) else cg.asmUnsupported(line),
            else => cg.asmUnsupported(line),
        };
    };
    if (eql(u8, mnemonic, "cmp") or eql(u8, mnemonic, "cmn")) {
        const n = reg(ops, 0) orelse return cg.asmUnsupported(line);
        if (ops.len != 2) return cg.asmUnsupported(line);
        const rhs: Encoder.AddOperand = switch (ops[1]) {
            .reg => |m| .r(m.reg),
            .imm => |v| if (v >= 0 and v < 4096) .{ .imm = @intCast(v) } else return cg.asmUnsupported(line),
            else => return cg.asmUnsupported(line),
        };
        return if (mnemonic[2] == 'p') e.cmp(n.width, n.reg, rhs) else e.cmn(n.width, n.reg, rhs);
    }
    if (std.meta.stringToEnum(Encoder.Shift, mnemonic)) |op| {
        const d = reg(ops, 0) orelse return cg.asmUnsupported(line);
        const n = reg(ops, 1) orelse return cg.asmUnsupported(line);
        if (ops.len != 3) return cg.asmUnsupported(line);
        return switch (ops[2]) {
            .reg => |m| e.shiftReg(op, d.width, d.reg, n.reg, m.reg),
            .imm => |v| if (v >= 0 and v < d.width.bits()) e.shiftImm(op, d.width, d.reg, n.reg, @intCast(v)) else cg.asmUnsupported(line),
            else => cg.asmUnsupported(line),
        };
    }
    const extends = [_]struct { []const u8, Size, bool }{ .{ "uxtb", .byte, false }, .{ "uxth", .half, false }, .{ "uxtw", .word, false }, .{ "sxtb", .byte, true }, .{ "sxth", .half, true }, .{ "sxtw", .word, true } };
    for (extends) |x| if (eql(u8, mnemonic, x[0])) {
        const d = reg(ops, 0) orelse return cg.asmUnsupported(line);
        const n = reg(ops, 1) orelse return cg.asmUnsupported(line);
        if (ops.len != 2) return cg.asmUnsupported(line);
        return if (x[2]) e.sxt(x[1], d.width, d.reg, n.reg) else e.uxt(x[1], d.reg, n.reg);
    };
    const logic = [_]struct { []const u8, Encoder.LogicOp }{ .{ "and", .@"and" }, .{ "orr", .orr }, .{ "eor", .eor }, .{ "ands", .ands } };
    for (logic) |l| if (eql(u8, mnemonic, l[0])) {
        const d = reg(ops, 0) orelse return cg.asmUnsupported(line);
        const n = reg(ops, 1) orelse return cg.asmUnsupported(line);
        if (ops.len != 3) return cg.asmUnsupported(line);
        return switch (ops[2]) {
            .reg => |m| e.logic(l[1], d.width, d.reg, n.reg, .r(m.reg)),
            .imm => |v| if (Encoder.bitmaskImm(d.width, @bitCast(v)) != null) e.logic(l[1], d.width, d.reg, n.reg, .{ .imm = @bitCast(v) }) else cg.asmUnsupported(line),
            else => cg.asmUnsupported(line),
        };
    };
    return cg.asmUnsupported(line);
}

/// The NEON instructions std's crypto uses on whole vectors, in the
/// standard syntax (`eor v0.16b, v1.16b, v2.16b`) and Apple's
/// (`sha256su0.4s v0, v1`, the arrangement on the mnemonic). Returns false
/// for an instruction that is not one of them.
fn asmNeon(cg: *CodeGen, mnemonic_in: []const u8, ops: []const AsmOperand, line: []const u8) Error!bool {
    if (ops.len == 0 or (ops[0] != .vreg)) return false;
    const dot = std.mem.findScalar(u8, mnemonic_in, '.') orelse mnemonic_in.len;
    const mnemonic = mnemonic_in[0..dot];
    const suffix: ?Arrangement = if (dot == mnemonic_in.len) null else std.meta.stringToEnum(Arrangement, mnemonic_in[dot + 1 ..]) orelse return cg.asmUnsupported(line);
    const Shape = enum { two, three, ext, tbl, movi };
    const Insn = struct { []const u8, Shape, u32 };
    // Base encodings with Q clear (or fixed) and the registers zero.
    const table = [_]Insn{
        .{ "mov", .two, 0x0EA01C00 }, // orr Vd, Vn, Vn
        .{ "aese", .two, 0x4E284800 },
        .{ "aesd", .two, 0x4E285800 },
        .{ "aesmc", .two, 0x4E286800 },
        .{ "aesimc", .two, 0x4E287800 },
        .{ "sha256su0", .two, 0x5E282800 },
        .{ "eor", .three, 0x2E201C00 },
        .{ "and", .three, 0x0E201C00 },
        .{ "orr", .three, 0x0EA01C00 },
        .{ "pmull", .three, 0x0EE0E000 }, // Vd.1q, Vn.1d, Vm.1d
        .{ "pmull2", .three, 0x4EE0E000 }, // Vd.1q, Vn.2d, Vm.2d
        .{ "sha256h", .three, 0x5E004000 },
        .{ "sha256h2", .three, 0x5E005000 },
        .{ "sha256su1", .three, 0x5E006000 },
        .{ "ext", .ext, 0x2E000000 },
        .{ "tbl", .tbl, 0x0E000000 },
        .{ "movi", .movi, 0x0F000400 },
    };
    const insn = for (table) |t| {
        if (std.mem.eql(u8, t[0], mnemonic)) break t;
    } else return false;
    const d = ops[0].vreg;
    const arr = d.arr orelse suffix;
    // The Q bit of the instructions whose encoding above leaves it clear.
    const q: u32 = switch (insn[2] >> 30 & 1) {
        0 => if (std.mem.eql(u8, mnemonic, "pmull")) 0 else (arr orelse return cg.asmUnsupported(line)).q(),
        else => 0,
    };
    const v = struct {
        fn at(o: []const AsmOperand, k: usize) ?u32 {
            return if (k < o.len and o[k] == .vreg) @backingInt(o[k].vreg.reg) else null;
        }
    }.at;
    const rd: u32 = @backingInt(d.reg);
    const word: u32 = switch (insn[1]) {
        .two => w: {
            const rn = v(ops, 1) orelse return cg.asmUnsupported(line);
            if (ops.len != 2) return cg.asmUnsupported(line);
            const rm: u32 = if (std.mem.eql(u8, mnemonic, "mov")) rn << 16 else 0;
            break :w insn[2] | q << 30 | rm | rn << 5 | rd;
        },
        .three => w: {
            const rn = v(ops, 1) orelse return cg.asmUnsupported(line);
            const rm = v(ops, 2) orelse return cg.asmUnsupported(line);
            if (ops.len != 3) return cg.asmUnsupported(line);
            break :w insn[2] | q << 30 | rm << 16 | rn << 5 | rd;
        },
        .ext => w: {
            const rn = v(ops, 1) orelse return cg.asmUnsupported(line);
            const rm = v(ops, 2) orelse return cg.asmUnsupported(line);
            if (ops.len != 4 or ops[3] != .imm or ops[3].imm < 0 or ops[3].imm > (@as(i64, 8) << @intCast(q)) - 1) return cg.asmUnsupported(line);
            break :w insn[2] | q << 30 | rm << 16 | @as(u32, @intCast(ops[3].imm)) << 11 | rn << 5 | rd;
        },
        .tbl => w: {
            if (ops.len != 3 or ops[1] != .vlist) return cg.asmUnsupported(line);
            const rm = v(ops, 2) orelse return cg.asmUnsupported(line);
            const l = ops[1].vlist;
            break :w insn[2] | q << 30 | rm << 16 | @as(u32, l.len - 1) << 13 | @as(u32, @backingInt(l.first)) << 5 | rd;
        },
        .movi => w: {
            // An 8-bit immediate in each byte (`.16b`, `.8b`) or each
            // word, unshifted (`.4s`, `.2s`).
            if (ops.len != 2 or ops[1] != .imm or ops[1].imm < 0 or ops[1].imm > 255) return cg.asmUnsupported(line);
            const cmode: u32 = switch (arr.?) {
                .@"8b", .@"16b" => 0b1110,
                .@"2s", .@"4s" => 0b0000,
                else => return cg.asmUnsupported(line),
            };
            const imm: u32 = @intCast(ops[1].imm);
            break :w insn[2] | q << 30 | (imm >> 5) << 16 | cmode << 12 | (imm & 31) << 5 | rd;
        },
    };
    try cg.e.raw(word);
    return true;
}

// ---------------------------------------------------------------- floats

fn isFloat(cg: *CodeGen, ty: Index) bool {
    return Type.class(cg.ip, ty) == .float;
}

/// The scalar register type of f16, f32, and f64; other floats go through
/// compiler_rt, and so does f16 on a CPU without half-precision
/// arithmetic (FEAT_FP16, which aarch64-linux's baseline lacks).
fn fpType(cg: *CodeGen, ty: Index) ?Float {
    return switch (Type.floatBits(cg.ip, ty)) {
        16 => if (cg.emit.zcu.cpu.has(.aarch64, .fullfp16)) .f16 else null,
        32 => .f32,
        64 => .f64,
        else => null,
    };
}

/// The register type `fcvt` converts floats of `bits` bits to and from.
fn cvtType(bits: u16) ?Float {
    return switch (bits) {
        16 => .f16,
        32 => .f32,
        64 => .f64,
        else => null,
    };
}

/// Loads a float (or a 16-byte value, into a q register) into `v`. Uses
/// x9 and x16.
fn loadFp(cg: *CodeGen, v: VReg, val: Val) Error!void {
    const size = Type.abiSize(cg.ip, val.ty);
    if (val.loc == .vreg) return vector.move(cg, v, val.loc.vreg);
    if (size == 16) return cg.e.ldrQ(v, try cg.access(try cg.valMem(val), 16, .x16));
    const ft: Float = switch (size) {
        2 => .f16,
        4 => .f32,
        8 => .f64,
        else => unreachable,
    };
    if (val.loc == .mem) return cg.e.ldrFp(ft, v, try cg.access(val.loc.mem, @intCast(size), .x16));
    try cg.loadVal(.x9, val);
    // `fmov h, w` needs FEAT_FP16; `fmov s, w` sets the h register too,
    // and moves a 2-byte vector.
    const via: Float = if (ft == .f16 and (!cg.isFloat(val.ty) or cg.fpType(val.ty) == null)) .f32 else ft;
    try cg.e.fmovFromGpr(via, v, if (size == 8) .x else .w, .x9);
}

/// The register holding float `val`: its own, or `scratch` loaded with
/// it.
fn fpUse(cg: *CodeGen, val: Val, scratch: VReg) Error!VReg {
    if (val.loc == .vreg) return val.loc.vreg;
    try cg.loadFp(scratch, val);
    return scratch;
}

/// The register float `inst` is computed in: its own, or `scratch` for
/// `setFpResult` to store.
fn fpResult(cg: *CodeGen, inst: Inst.Index, scratch: VReg) VReg {
    return switch (cg.homes[@backingInt(inst)]) {
        .vreg => |r| r,
        else => scratch,
    };
}

/// Stores float `inst` of type `ty`, computed in `v`, to its slot, or
/// moves it to its register.
fn setFpResult(cg: *CodeGen, inst: Inst.Index, ty: Index, v: VReg) Error!void {
    switch (cg.homes[@backingInt(inst)]) {
        .vreg => |r| if (r != v) try cg.e.fmov(if (Type.abiSize(cg.ip, ty) == 8) .f64 else .f32, r, v),
        else => {
            const m = try cg.resultMem(inst, ty) orelse return;
            try cg.storeFp(m, v, Type.abiSize(cg.ip, ty));
        },
    }
}

/// Stores the low `size` bytes of `v`. Uses x16.
fn storeFp(cg: *CodeGen, dst: Mem, v: VReg, size: u64) Error!void {
    const a = try cg.access(dst, @intCast(size), .x16);
    switch (size) {
        2 => try cg.e.strFp(.f16, v, a),
        4 => try cg.e.strFp(.f32, v, a),
        8 => try cg.e.strFp(.f64, v, a),
        16 => try cg.e.strQ(v, a),
        else => unreachable,
    }
}

/// Loads `n` floats of `size` bytes, back to back at `src`, into v`first`
/// and the registers after it.
fn loadFpRun(cg: *CodeGen, src: Mem, first: u8, n: u8, size: u8) Error!void {
    for (0..n) |k| {
        const v = argVReg(first + @as(u8, @intCast(k)));
        const a = try cg.access(src.plus(@intCast(k * size)), size, .x16);
        if (size == 16) try cg.e.ldrQ(v, a) else try cg.e.ldrFp(switch (size) {
            2 => .f16,
            4 => .f32,
            8 => .f64,
            else => unreachable,
        }, v, a);
    }
}

/// Stores v`first` and the `n - 1` registers after it, floats of `size`
/// bytes, back to back to `dst`.
fn storeFpRun(cg: *CodeGen, dst: Mem, first: u8, n: u8, size: u8) Error!void {
    for (0..n) |k| try cg.storeFp(dst.plus(@intCast(k * size)), argVReg(first + @as(u8, @intCast(k))), size);
}

/// libm's name for operation `op` on floats of `bits` bits.
fn libmName(cg: *CodeGen, op: []const u8, bits: u16) Error![]const u8 {
    const arena = cg.emit.allocator();
    return switch (bits) {
        16 => arena.print("__{s}h", .{op}),
        32 => arena.print("{s}f", .{op}),
        64 => op,
        80 => arena.print("__{s}x", .{op}),
        128 => arena.print("{s}q", .{op}),
        else => unreachable,
    };
}

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

/// Calls compiler_rt function `name`, declared in `lib/compiler_rt/<file>`,
/// with the C convention.
fn rtCall(cg: *CodeGen, file: []const u8, name: []const u8, args: []const Val, ret_ty: Index, dst: Mem) Error!void {
    for (args) |a| if (cg.cClass(a.ty) == .unsupported) return cg.fail("compiler_rt call with an argument of type '{f}'", .{cg.fmtType(a.ty)});
    if (cg.cClass(ret_ty) == .unsupported) return cg.fail("compiler_rt call returning '{f}'", .{cg.fmtType(ret_ty)});
    const key: SymbolKey = .fromName(try cg.emit.requestCompilerRt(file, name));
    try cg.cCallArgs(.c, args, null, false);
    if (cg.cRetClass(ret_ty) == .indirect) try cg.addrTo(.x8, dst);
    try cg.e.bl(.{ .sym = key });
    try cg.cCallResult(ret_ty, dst);
}

fn libmCall(cg: *CodeGen, op: []const u8, file: ?[]const u8, ty: Index, args: []const Val, dst: Mem) Error!void {
    const f = file orelse try cg.emit.allocator().print("{s}.zig", .{op});
    try cg.rtCall(f, try cg.libmName(op, Type.floatBits(cg.ip, ty)), args, ty, dst);
}

/// The instruction of a float arithmetic tag.
fn fpOp(tag: Inst.Tag) Encoder.FpOp {
    return switch (tag) {
        .add_float => .add,
        .sub_float => .sub,
        .mul_float => .mul,
        .div_float => .div,
        .min_float => .minnm,
        .max_float => .maxnm,
        else => unreachable,
    };
}

fn floatArith(cg: *CodeGen, tag: Inst.Tag, ty: Index, lhs: Val, rhs: Val, dst: Mem) Error!void {
    if (cg.fpType(ty)) |ft| {
        try cg.loadFp(.v0, lhs);
        try cg.loadFp(.v1, rhs);
        try cg.e.fp(fpOp(tag), ft, .v0, .v0, .v1);
        return cg.storeFp(dst, .v0, Type.abiSize(cg.ip, ty));
    }
    const bits = Type.floatBits(cg.ip, ty);
    if (tag == .min_float or tag == .max_float) return cg.libmCall(if (tag == .min_float) "fmin" else "fmax", null, ty, &.{ lhs, rhs }, dst);
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
    const name = try cg.emit.allocator().print("__{s}{s}3", .{ op, rtFloatAbbrev(bits) });
    try cg.rtCall(file, name, &.{ lhs, rhs }, ty, dst);
}

/// A rounding of the float at `m` in place: native frint, else compiler_rt.
fn floatRound(cg: *CodeGen, op: []const u8, ty: Index, m: Mem) Error!void {
    if (cg.fpType(ty)) |ft| {
        try cg.loadFp(.v0, memVal(ty, m));
        try cg.e.fpUnary(if (std.mem.eql(u8, op, "trunc")) .rintz else if (std.mem.eql(u8, op, "floor")) .rintm else if (std.mem.eql(u8, op, "ceil")) .rintp else .rinta, ft, .v0, .v0);
        return cg.storeFp(m, .v0, Type.abiSize(cg.ip, ty));
    }
    const file: ?[]const u8 = if (std.mem.eql(u8, op, "floor") or std.mem.eql(u8, op, "ceil")) "floor_ceil.zig" else null;
    try cg.libmCall(op, file, ty, &.{memVal(ty, m)}, m);
}

/// Instructions on floats.
fn genFloat(cg: *CodeGen, inst: Inst.Index, tag: Inst.Tag, data: Inst.Data) Error!void {
    const ip = cg.ip;
    const e = &cg.e;
    switch (tag) {
        .add_float, .sub_float, .mul_float, .div_float, .min_float, .max_float => {
            const ty = cg.typeOf(data.bin_op.lhs);
            if (cg.fpType(ty)) |ft| {
                const l = try cg.fpUse(try cg.valOf(data.bin_op.lhs), .v0);
                const r = try cg.fpUse(try cg.valOf(data.bin_op.rhs), .v1);
                const d = cg.fpResult(inst, .v0);
                try e.fp(fpOp(tag), ft, d, l, r);
                return cg.setFpResult(inst, ty, d);
            }
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.floatArith(tag, ty, try cg.valOf(data.bin_op.lhs), try cg.valOf(data.bin_op.rhs), dst);
        },
        .div_trunc, .div_floor, .div_ceil => {
            const ty = cg.typeOf(data.bin_op.lhs);
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.floatArith(.div_float, ty, try cg.valOf(data.bin_op.lhs), try cg.valOf(data.bin_op.rhs), dst);
            try cg.floatRound(switch (tag) {
                .div_trunc => "trunc",
                .div_floor => "floor",
                else => "ceil",
            }, ty, dst);
        },
        .rem, .mod => {
            const ty = cg.typeOf(data.bin_op.lhs);
            const dst = try cg.resultMem(inst, ty) orelse return;
            const rhs = try cg.valOf(data.bin_op.rhs);
            try cg.libmCall("fmod", null, ty, &.{ try cg.valOf(data.bin_op.lhs), rhs }, dst);
            if (tag == .rem) return;
            // As upstream: a non-zero remainder whose sign differs from the
            // divisor's gets the divisor added.
            const done = try e.newLabel();
            const rhs_m = try cg.valMem(rhs);
            const bits = Type.floatBits(ip, ty);
            const top: u64 = (bits - 1) / 8;
            try cg.loadMem(.x9, dst.plus(top), .u8_type);
            try cg.loadMem(.x10, rhs_m.plus(top), .u8_type);
            try e.logic(.eor, .x, .x9, .x9, .r(.x10));
            try e.tbz(false, .x9, 7, done);
            // Zero of either sign: every bit but the sign is clear.
            switch (bits) {
                16, 32, 64 => {
                    try cg.loadMem(.x9, dst, switch (bits) {
                        16 => .u16_type,
                        32 => .u32_type,
                        else => .u64_type,
                    });
                    try e.shiftImm(.lsl, .x, .x9, .x9, @intCast(65 - bits));
                },
                else => {
                    // f80: the 15 exponent bits above the sign in bytes
                    // 8-9 (padding follows); f128: the high limb's.
                    if (bits == 80) {
                        try cg.loadMem(.x9, dst.plus(8), .u16_type);
                        try e.shiftImm(.lsl, .x, .x9, .x9, 49);
                    } else {
                        try cg.loadMem(.x9, dst.plus(8), .u64_type);
                        try e.shiftImm(.lsl, .x, .x9, .x9, 1);
                    }
                    try cg.loadMem(.x10, dst, .u64_type);
                    try e.logic(.orr, .x, .x9, .x9, .r(.x10));
                },
            }
            try e.cbz(false, .x, .x9, done);
            try cg.floatArith(.add_float, ty, memVal(ty, dst), memVal(ty, rhs_m), dst);
            e.bind(done);
        },
        .neg_float, .abs_float => {
            const ty = cg.typeOf(data.un_op);
            if (cg.fpType(ty)) |ft| {
                const s = try cg.fpUse(try cg.valOf(data.un_op), .v0);
                const d = cg.fpResult(inst, .v0);
                try e.fpUnary(if (tag == .neg_float) .neg else .abs, ft, d, s);
                return cg.setFpResult(inst, ty, d);
            }
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.copyTo(dst, data.un_op);
            const top = dst.plus((Type.floatBits(ip, ty) - 1) / 8);
            try cg.loadMem(.x9, top, .u8_type);
            if (tag == .neg_float) {
                try e.logic(.eor, .x, .x9, .x9, .{ .imm = 0x80 });
            } else {
                try e.logic(.@"and", .x, .x9, .x9, .{ .imm = 0x7f });
            }
            try cg.storeReg(top, .x9, 1);
        },
        .sqrt, .sin, .cos, .tan, .exp, .exp2, .log, .log2, .log10, .floor, .ceil, .round, .trunc_float => {
            const ty = cg.typeOf(data.un_op);
            const operand = try cg.valOf(data.un_op);
            if (cg.fpType(ty)) |ft| {
                const op: ?Encoder.FpUnaryOp = switch (tag) {
                    .sqrt => .sqrt,
                    .floor => .rintm,
                    .ceil => .rintp,
                    .round => .rinta,
                    .trunc_float => .rintz,
                    else => null,
                };
                if (op) |o| {
                    const s = try cg.fpUse(operand, .v0);
                    const d = cg.fpResult(inst, .v0);
                    try e.fpUnary(o, ft, d, s);
                    return cg.setFpResult(inst, ty, d);
                }
            }
            const dst = try cg.resultMem(inst, ty) orelse return;
            switch (tag) {
                .floor, .ceil, .round, .trunc_float => {
                    try cg.copyVal(dst, operand);
                    return cg.floatRound(if (tag == .trunc_float) "trunc" else @tagName(tag), ty, dst);
                },
                else => {},
            }
            try cg.libmCall(@tagName(tag), null, ty, &.{operand}, dst);
        },
        .mul_add => {
            const ty = cg.typeOf(data.pl_op.operand);
            const bin = cg.ir.extraData(Ir.Bin, data.pl_op.payload).data;
            if (cg.fpType(ty)) |ft| {
                const a = try cg.fpUse(try cg.valOf(bin.lhs), .v0);
                const b = try cg.fpUse(try cg.valOf(bin.rhs), .v1);
                const c = try cg.fpUse(try cg.valOf(data.pl_op.operand), .v2);
                const d = cg.fpResult(inst, .v0);
                try e.fma(.madd, ft, d, a, b, c);
                return cg.setFpResult(inst, ty, d);
            }
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.libmCall("fma", null, ty, &.{ try cg.valOf(bin.lhs), try cg.valOf(bin.rhs), try cg.valOf(data.pl_op.operand) }, dst);
        },
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => {
            const ty = cg.typeOf(data.bin_op.lhs);
            const lhs = try cg.valOf(data.bin_op.lhs);
            const rhs = try cg.valOf(data.bin_op.rhs);
            if (cg.fpType(ty)) |ft| {
                try e.fcmp(ft, try cg.fpUse(lhs, .v0), try cg.fpUse(rhs, .v1));
                const d = cg.resultReg(inst, .x9);
                // Unordered sets C and V: these are all false for NaN but
                // `ne`.
                try e.cset(.x, d, switch (tag) {
                    .cmp_lt => .mi,
                    .cmp_lte => .ls,
                    .cmp_eq => .eq,
                    .cmp_gte => .ge,
                    .cmp_gt => .gt,
                    .cmp_neq => .ne,
                    else => unreachable,
                });
                return cg.setResult(inst, .bool_type, d);
            }
            const dst = try cg.resultMem(inst, .bool_type) orelse return;
            // `__cmp*f2` is 1 for unordered operands and `__ge*f2` is -1, so
            // each comparison is false for NaN.
            const bits = Type.floatBits(ip, ty);
            const ge = tag == .cmp_gt or tag == .cmp_gte;
            const name = try cg.emit.allocator().print("__{s}{s}2", .{ if (ge) "ge" else "cmp", rtFloatAbbrev(bits) });
            const res = try cg.allocSlot(4, 4);
            try cg.rtCall("comparef.zig", name, &.{ lhs, rhs }, .i32_type, res);
            try cg.loadMem(.x9, res, .i32_type);
            try e.cmp(.x, .x9, .{ .imm = 0 });
            try e.cset(.x, .x9, switch (tag) {
                .cmp_lt => .lt,
                .cmp_lte => .le,
                .cmp_eq => .eq,
                .cmp_neq => .ne,
                .cmp_gt => .gt,
                .cmp_gte => .ge,
                else => unreachable,
            });
            try cg.storeReg(dst, .x9, 1);
        },
        .float_cast => {
            const ty = data.ty_op.ty;
            const src_ty = cg.typeOf(data.ty_op.operand);
            const operand = try cg.valOf(data.ty_op.operand);
            const from = Type.floatBits(ip, src_ty);
            const to = Type.floatBits(ip, ty);
            // fcvt converts halves without FEAT_FP16.
            if (from != to and cvtType(to) != null and cvtType(from) != null) {
                const s = try cg.fpUse(operand, .v0);
                const d = cg.fpResult(inst, .v0);
                try e.fcvt(cvtType(to).?, d, cvtType(from).?, s);
                return cg.setFpResult(inst, ty, d);
            }
            const dst = try cg.resultMem(inst, ty) orelse return;
            if (from == to) return cg.copyTo(dst, data.ty_op.operand);
            const widen = to > from;
            const name = try cg.emit.allocator().print("__{s}{s}{s}2", .{ if (widen) "extend" else "trunc", rtFloatAbbrev(from), rtFloatAbbrev(to) });
            try cg.rtCall(if (widen) "extendf.zig" else "truncf.zig", name, &.{operand}, ty, dst);
        },
        .float_from_int => {
            const ty = data.ty_op.ty;
            const info = Type.intInfo(ip, cg.typeOf(data.ty_op.operand));
            const operand = try cg.valOf(data.ty_op.operand);
            if (cg.fpType(ty)) |ft| if (info.bits <= 64) {
                // The operand is extended to 64 bits.
                const s = try cg.use(data.ty_op.operand, .x9);
                const d = cg.fpResult(inst, .v0);
                try e.cvtf(info.signedness == .signed, ft, d, .x, s);
                return cg.setFpResult(inst, ty, d);
            };
            const dst = try cg.resultMem(inst, ty) orelse return;
            if (info.bits > 128) return cg.fail("@floatFromInt of integers wider than 128 bits", .{});
            const abbrev = if (info.bits <= 32) "si" else if (info.bits <= 64) "di" else "ti";
            const name = try cg.emit.allocator().print("__float{s}{s}{s}", .{ if (info.signedness == .unsigned) "un" else "", abbrev, rtFloatAbbrev(Type.floatBits(ip, ty)) });
            try cg.rtCall("float_from_int.zig", name, &.{operand}, ty, dst);
        },
        .int_from_float => {
            const ty = data.ty_op.ty;
            const float_ty = cg.typeOf(data.ty_op.operand);
            const info = Type.intInfo(ip, ty);
            const operand = try cg.valOf(data.ty_op.operand);
            const size = Type.abiSize(ip, ty);
            if (cg.fpType(float_ty)) |ft| if (info.bits <= 64) {
                // Safety checks before this keep the value in range.
                const d = cg.resultReg(inst, .x9);
                try e.fcvtz(info.signedness == .signed, .x, d, ft, try cg.fpUse(operand, .v0));
                return cg.setResult(inst, ty, d);
            };
            const dst = try cg.resultMem(inst, ty) orelse return;
            if (info.bits > 128) return cg.fail("@intFromFloat to integers wider than 128 bits", .{});
            const abbrev = if (info.bits <= 32) "si" else if (info.bits <= 64) "di" else "ti";
            const name = try cg.emit.allocator().print("__fix{s}{s}{s}", .{ if (info.signedness == .unsigned) "uns" else "", rtFloatAbbrev(Type.floatBits(ip, float_ty)), abbrev });
            const s = info.signedness == .signed;
            const rt_ty: Index = if (info.bits <= 32) (if (s) .i32_type else .u32_type) else if (info.bits <= 64) (if (s) .i64_type else .u64_type) else if (s) .i128_type else .u128_type;
            if (Type.abiSize(ip, rt_ty) == size) return cg.rtCall("int_from_float.zig", name, &.{operand}, rt_ty, dst);
            const tmp = try cg.allocSlot(Type.abiSize(ip, rt_ty), Type.abiAlignment(ip, rt_ty));
            try cg.rtCall("int_from_float.zig", name, &.{operand}, rt_ty, tmp);
            try cg.copyMem(dst, tmp, size);
        },
        else => unreachable,
    }
}

// ---------------------------------------------------------------- wide integers

fn isWideInt(cg: *CodeGen, ty: Index) bool {
    // An enum is its integer tag.
    const c = Type.class(cg.ip, ty);
    return (c == .int or c == .@"enum") and Type.abiSize(cg.ip, ty) > 8;
}

fn limbCount(cg: *CodeGen, ty: Index) u32 {
    return @intCast(Type.abiSize(cg.ip, ty) / 8);
}

fn limb(m: Mem, i: u32) Mem {
    return m.plus(@as(u64, i) * 8);
}

/// Loads limb `i` of integer `v` into `reg`; limbs past `v`'s own are its
/// extension. Changes no flags.
fn loadLimb(cg: *CodeGen, reg: Reg, v: Val, i: u32) Error!void {
    const n = if (cg.passInRegs(v.ty)) 1 else cg.limbCount(v.ty);
    if (i < n) {
        if (n == 1) return cg.loadVal(reg, v);
        return cg.e.ldr(.dword, reg, try cg.access(limb(v.loc.mem, i), 8, reg));
    }
    if (!cg.signed(v.ty)) return cg.e.movImm(.x, reg, 0);
    try cg.loadLimb(reg, v, n - 1);
    try cg.e.shiftImm(.asr, .x, reg, reg, 63);
}

/// Loads limb `i` of the wide integer at `m`. Changes no flags.
fn ldrLimb(cg: *CodeGen, reg: Reg, m: Mem, i: u32) Error!void {
    try cg.e.ldr(.dword, reg, try cg.access(limb(m, i), 8, reg));
}

/// Stores `reg` to limb `i` of the wide integer at `m`. Changes no flags.
fn strLimb(cg: *CodeGen, m: Mem, i: u32, reg: Reg) Error!void {
    try cg.storeReg(limb(m, i), reg, 8);
}

/// The fast path of a 2-limb division `lhs op rhs` into `dst`: when both
/// operands fit in 64 bits (and, signed, the divisor is not -1, whose
/// quotient of `minInt(i64)` does not), divides them as 64-bit integers
/// and branches to `end`; otherwise falls through to the compiler_rt call
/// after it. A constant divisor is checked here and divided by without a
/// divide where it can be. Uses x9, x10, x11, x13, and x14.
fn wideDivFast(cg: *CodeGen, tag: Inst.Tag, s: bool, lhs: Mem, rhs: Mem, rhs_ref: Ref, dst: Mem, end: Encoder.Label) Error!void {
    const e = &cg.e;
    const d: ?u64 = if (rhs_ref.toInterned()) |v| blk: {
        const d = if (s) @as(u64, @bitCast(cg.ip.intValue(i64, v) orelse return)) else cg.ip.intValue(u64, v) orelse return;
        if (d == 0 or (s and d == std.math.maxInt(u64))) return;
        break :blk d;
    } else null;
    const slow = try e.newLabel();
    const sign_of_x9: Encoder.AddOperand = .{ .reg = .{ .reg = .x9, .shift = .asr, .amount = 63 } };
    if (s) {
        try cg.ldrLimb(.x9, lhs, 0);
        try cg.ldrLimb(.x10, lhs, 1);
        try e.cmp(.x, .x10, sign_of_x9);
        try e.bcond(.ne, slow);
        if (d == null) {
            try cg.ldrLimb(.x10, rhs, 0);
            try cg.ldrLimb(.x11, rhs, 1);
            try e.cmp(.x, .x11, .{ .reg = .{ .reg = .x10, .shift = .asr, .amount = 63 } });
            try e.bcond(.ne, slow);
            // Divisors -1 and 0 (unsigned x10 + 1 <= 1) take the call.
            try e.addSub(.add, .x, .x11, .x10, .{ .imm = 1 });
            try e.cmp(.x, .x11, .{ .imm = 1 });
            try e.bcond(.ls, slow);
        }
    } else {
        try cg.ldrLimb(.x10, lhs, 1);
        if (d == null) {
            try cg.ldrLimb(.x11, rhs, 1);
            try e.logic(.orr, .x, .x10, .x10, .r(.x11));
        }
        try e.cbz(true, .x, .x10, slow);
        try cg.ldrLimb(.x9, lhs, 0);
        if (d == null) try cg.ldrLimb(.x10, rhs, 0);
    }
    if (d) |c| {
        if (!s) {
            try cg.divConst(tag, .x9, c, 64, .x9);
        } else if (@as(i64, @bitCast(c)) >= 1 and tag != .div_ceil) {
            try cg.divConstSigned(tag, .x9, c, 64, .x9);
        } else {
            try e.movImm(.x, .x10, c);
            try cg.divide(tag, s, .x9, .x10, .x9);
        }
    } else try cg.divide(tag, s, .x9, .x10, .x9);
    try cg.strLimb(dst, 0, .x9);
    if (s) {
        try e.shiftImm(.asr, .x, .x9, .x9, 63);
        try cg.strLimb(dst, 1, .x9);
    } else try cg.strLimb(dst, 1, .zr);
    try e.b(.{ .label = end });
    e.bind(slow);
}

/// Sets x9 to zero when wide integers `a` and `b` of the same type are
/// equal: the OR of every limb's XOR. Uses x10.
fn wideEq(cg: *CodeGen, a_ref: Ref, b_ref: Ref) Error!void {
    const a = (try cg.wideVal(a_ref)).loc.mem;
    const b = (try cg.wideVal(b_ref)).loc.mem;
    try cg.ldrLimb(.x9, a, 0);
    try cg.ldrLimb(.x10, b, 0);
    try cg.e.logic(.eor, .x, .x9, .x9, .r(.x10));
    for (1..cg.limbCount(cg.typeOf(a_ref))) |i| {
        try cg.ldrLimb(.x10, a, @intCast(i));
        try cg.e.logic(.eor, .x, .x10, .x10, .r(.x9));
        try cg.ldrLimb(.x9, b, @intCast(i));
        try cg.e.logic(.eor, .x, .x9, .x9, .r(.x10));
    }
    // x9 now holds a ^ b's limbs folded with XOR, which can cancel: redo
    // it with OR.
    try cg.ldrLimb(.x9, a, 0);
    try cg.ldrLimb(.x10, b, 0);
    try cg.e.logic(.eor, .x, .x9, .x9, .r(.x10));
    for (1..cg.limbCount(cg.typeOf(a_ref))) |i| {
        try cg.ldrLimb(.x10, a, @intCast(i));
        try cg.ldrLimb(.x11, b, @intCast(i));
        try cg.e.logic(.eor, .x, .x10, .x10, .r(.x11));
        try cg.e.logic(.orr, .x, .x9, .x9, .r(.x10));
    }
}

/// `v` with a wide integer in memory (materializing a constant).
fn wideVal(cg: *CodeGen, ref: Ref) Error!Val {
    const v = try cg.valOf(ref);
    if (v.loc == .mem or cg.passInRegs(v.ty)) return v;
    return memVal(v.ty, try cg.valMem(v));
}

/// Re-normalizes the wide integer of type `ty` at `m` after an operation
/// that may have changed the bits above its width. Uses x9.
fn normalizeWide(cg: *CodeGen, m: Mem, ty: Index) Error!void {
    const info = Type.intInfo(cg.ip, ty);
    const n = cg.limbCount(ty);
    const top: u32 = (info.bits - 1) / 64;
    const r: u8 = @intCast(info.bits % 64);
    const s = info.signedness == .signed;
    if (r == 0 and top == n - 1) return;
    try cg.ldrLimb(.x9, m, top);
    if (r != 0) {
        try cg.e.bitfield(if (s) .sbfm else .ubfm, .x, .x9, .x9, 0, @intCast(r - 1));
        try cg.strLimb(m, top, .x9);
    }
    if (top + 1 == n) return;
    if (s) try cg.e.shiftImm(.asr, .x, .x9, .x9, 63) else try cg.e.movImm(.x, .x9, 0);
    for (top + 1..n) |i| try cg.strLimb(m, @intCast(i), .x9);
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
        try cg.loadLimb(.x9, v, 0);
        try cg.normalize(.x9, ty);
        return cg.storeReg(dst, .x9, Type.abiSize(cg.ip, ty));
    }
    for (0..cg.limbCount(ty)) |i| {
        try cg.loadLimb(.x9, v, @intCast(i));
        try cg.strLimb(dst, @intCast(i), .x9);
    }
    try cg.normalizeWide(dst, ty);
}

/// `dst = lhs * rhs` over `n` limbs, wrapping. `dst` must not overlap the
/// operands. Uses x0-x7 and x9-x14 past 4 limbs.
fn mulLimbs(cg: *CodeGen, dst: Mem, lhs: Mem, rhs: Mem, n: u32) Error!void {
    const e = &cg.e;
    for (0..n) |i| try cg.strLimb(dst, @intCast(i), .zr);
    // Unrolled, the schoolbook product is n^2/2 multiply steps of code;
    // past a few limbs, loop over the columns instead.
    if (n > 4) return cg.mulLimbsLoop(dst, lhs, rhs, n);
    for (0..n) |i| {
        // x14 carries the high half into the next column.
        try e.movImm(.x, .x14, 0);
        for (0..n - i) |j| {
            const k: u32 = @intCast(i + j);
            try cg.ldrLimb(.x9, lhs, @intCast(i));
            try cg.ldrLimb(.x10, rhs, @intCast(j));
            try e.mul(.x, .x11, .x9, .x10);
            try cg.ldrLimb(.x13, dst, k);
            if (k == n - 1) {
                // The last column keeps only the low half.
                try e.addSub(.add, .x, .x11, .x11, .r(.x14));
                try e.addSub(.add, .x, .x13, .x13, .r(.x11));
                try cg.strLimb(dst, k, .x13);
                continue;
            }
            try e.mulHigh(false, .x12, .x9, .x10);
            try e.addSub(.adds, .x, .x11, .x11, .r(.x14));
            try e.carry(.adc, .x, .x12, .x12, .zr);
            try e.addSub(.adds, .x, .x13, .x13, .r(.x11));
            try e.carry(.adc, .x, .x14, .x12, .zr);
            try cg.strLimb(dst, k, .x13);
        }
    }
}

fn mulLimbsLoop(cg: *CodeGen, dst: Mem, lhs: Mem, rhs: Mem, n: u32) Error!void {
    const e = &cg.e;
    const indexed = struct {
        fn f(base: Reg, index: Reg) Encoder.Mem {
            return .{ .base = base, .offset = .{ .index = .{ .reg = index, .scaled = true } } };
        }
    }.f;
    // x0, x1, x2 address lhs, rhs, and dst; x3 = i (lhs limb), x5 = j
    // (rhs limb), x4 = carry, x6 = n - 1 - i (the column that keeps only
    // the low half), x7 = i + j.
    try cg.addrTo(.x0, lhs);
    try cg.addrTo(.x1, rhs);
    try cg.addrTo(.x2, dst);
    const outer = try e.newLabel();
    const inner = try e.newLabel();
    const last = try e.newLabel();
    try e.movImm(.x, .x3, 0);
    e.bind(outer);
    try e.movImm(.x, .x4, 0);
    try e.movImm(.x, .x5, 0);
    try e.movImm(.x, .x6, n - 1);
    try e.addSub(.sub, .x, .x6, .x6, .r(.x3));
    e.bind(inner);
    try e.cmp(.x, .x5, .r(.x6));
    try e.bcond(.hs, last);
    try e.ldr(.dword, .x9, indexed(.x0, .x3));
    try e.ldr(.dword, .x10, indexed(.x1, .x5));
    try e.mul(.x, .x11, .x9, .x10);
    try e.mulHigh(false, .x12, .x9, .x10);
    try e.addSub(.adds, .x, .x11, .x11, .r(.x4));
    try e.carry(.adc, .x, .x12, .x12, .zr);
    try e.addSub(.add, .x, .x7, .x3, .r(.x5));
    try e.ldr(.dword, .x13, indexed(.x2, .x7));
    try e.addSub(.adds, .x, .x13, .x13, .r(.x11));
    try e.carry(.adc, .x, .x4, .x12, .zr);
    try e.str(.dword, .x13, indexed(.x2, .x7));
    try e.addSub(.add, .x, .x5, .x5, .{ .imm = 1 });
    try e.b(.{ .label = inner });
    e.bind(last);
    try e.ldr(.dword, .x9, indexed(.x0, .x3));
    try e.ldr(.dword, .x10, indexed(.x1, .x5));
    try e.mulAdd(.madd, .x, .x11, .x9, .x10, .x4);
    try e.addSub(.add, .x, .x7, .x3, .r(.x5));
    try e.ldr(.dword, .x13, indexed(.x2, .x7));
    try e.addSub(.add, .x, .x13, .x13, .r(.x11));
    try e.str(.dword, .x13, indexed(.x2, .x7));
    try e.addSub(.add, .x, .x3, .x3, .{ .imm = 1 });
    try e.movImm(.x, .x9, n);
    try e.cmp(.x, .x3, .r(.x9));
    try e.bcond(.lo, outer);
}

/// Shifts the wide integer `v` of type `ty` by `amount` (less than its
/// width) into `dst`, through a buffer that pads it with zeros (left) or
/// its extension (right), so that each result limb combines two limbs.
fn shiftWide(cg: *CodeGen, left: bool, dst: Mem, ty: Index, v: Val, amount: Val) Error!void {
    const e = &cg.e;
    const n = cg.limbCount(ty);
    const buf = try cg.allocSlot(@as(u64, n) * 16, 8);
    const src_half = if (left) limb(buf, n) else buf;
    const pad_half = if (left) buf else limb(buf, n);
    try cg.copyMem(src_half, v.loc.mem, @as(u64, n) * 8);
    if (left) try e.movImm(.x, .x9, 0) else try cg.loadLimb(.x9, v, n);
    for (0..n) |i| try cg.strLimb(pad_half, @intCast(i), .x9);
    // x12 = the limb the result starts from; x10 = the bit shift, x11 =
    // 63 - x10.
    try cg.loadVal(.x10, amount);
    try e.shiftImm(.lsr, .x, .x13, .x10, 6);
    try cg.addrTo(.x12, src_half);
    try e.addSub(if (left) .sub else .add, .x, .x12, .x12, .{ .reg = .{ .reg = .x13, .amount = 3 } });
    try e.logic(.@"and", .x, .x10, .x10, .{ .imm = 63 });
    try e.logic(.eor, .x, .x11, .x10, .{ .imm = 63 });
    for (0..n) |i| {
        const d: i32 = @intCast(i * 8);
        // left: (a << c) | ((b >> 1) >> (63 - c)), b the limb below;
        // right: (a >> c) | ((b << 1) << (63 - c)), b the limb above.
        try e.ldr(.dword, .x9, .at(.x12, d));
        try e.ldr(.dword, .x13, .at(.x12, if (left) d - 8 else d + 8));
        try e.shiftReg(if (left) .lsl else .lsr, .x, .x9, .x9, .x10);
        try e.shiftImm(if (left) .lsr else .lsl, .x, .x13, .x13, 1);
        try e.shiftReg(if (left) .lsr else .lsl, .x, .x13, .x13, .x11);
        try e.logic(.orr, .x, .x9, .x9, .r(.x13));
        try cg.strLimb(dst, @intCast(i), .x9);
    }
    try cg.normalizeWide(dst, ty);
}

/// Calls `name(dst, u, v, bits)`, one of compiler_rt's division helpers for
/// integers of `ty`. The signed helpers clobber `u` and `v`, so they get
/// copies.
fn divEi4(cg: *CodeGen, file: []const u8, name: []const u8, dst: Mem, u: Mem, v: Mem, ty: Index) Error!void {
    const key: SymbolKey = .fromName(try cg.emit.requestCompilerRt(file, name));
    var u_arg = u;
    var v_arg = v;
    if (cg.signed(ty)) {
        const size = Type.abiSize(cg.ip, ty);
        u_arg = try cg.allocSlot(size, 16);
        v_arg = try cg.allocSlot(size, 16);
        try cg.copyMem(u_arg, u, size);
        try cg.copyMem(v_arg, v, size);
    }
    try cg.addrTo(.x0, dst);
    try cg.addrTo(.x1, u_arg);
    try cg.addrTo(.x2, v_arg);
    try cg.e.movImm(.x, .x3, Type.intInfo(cg.ip, ty).bits);
    try cg.e.bl(.{ .sym = key });
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
                try cg.ldrLimb(.x9, lhs, i);
                try cg.ldrLimb(.x10, rhs, i);
                switch (tag) {
                    .add_wrap => if (i == 0) try e.addSub(.adds, .x, .x9, .x9, .r(.x10)) else try e.carry(.adcs, .x, .x9, .x9, .x10),
                    .sub_wrap => if (i == 0) try e.addSub(.subs, .x, .x9, .x9, .r(.x10)) else try e.carry(.sbcs, .x, .x9, .x9, .x10),
                    .bit_and => try e.logic(.@"and", .x, .x9, .x9, .r(.x10)),
                    .bit_or => try e.logic(.orr, .x, .x9, .x9, .r(.x10)),
                    else => try e.logic(.eor, .x, .x9, .x9, .r(.x10)),
                }
                try cg.strLimb(dst, i, .x9);
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
                try cg.ldrLimb(.x9, src, @intCast(i));
                try e.mvn(.x, .x9, .x9);
                try cg.strLimb(dst, @intCast(i), .x9);
            }
            try cg.normalizeWide(dst, ty);
        },
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => {
            const dst = try cg.resultMem(inst, .bool_type) orelse return;
            const ty = cg.typeOf(data.bin_op.lhs);
            const n = cg.limbCount(ty);
            if (tag == .cmp_eq or tag == .cmp_neq) {
                try cg.wideEq(data.bin_op.lhs, data.bin_op.rhs);
                try e.cmp(.x, .x9, .{ .imm = 0 });
                try e.cset(.x, .x9, if (tag == .cmp_eq) .eq else .ne);
                return cg.storeReg(dst, .x9, 1);
            }
            var a = (try cg.wideVal(data.bin_op.lhs)).loc.mem;
            var b = (try cg.wideVal(data.bin_op.rhs)).loc.mem;
            // The flags of `a - b` over all limbs: `>` and `<=` swap.
            if (tag == .cmp_gt or tag == .cmp_lte) std.mem.swap(Mem, &a, &b);
            for (0..n) |i| {
                try cg.ldrLimb(.x9, a, @intCast(i));
                try cg.ldrLimb(.x10, b, @intCast(i));
                if (i == 0) try e.cmp(.x, .x9, .r(.x10)) else try e.carry(.sbcs, .x, .zr, .x9, .x10);
            }
            const s = cg.signed(ty);
            try e.cset(.x, .x9, switch (tag) {
                .cmp_lt, .cmp_gt => if (s) .lt else .lo,
                else => if (s) .ge else .hs,
            });
            try cg.storeReg(dst, .x9, 1);
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
            const rem = if (want_q and adjust) try cg.allocSlot(@as(u64, n) * 8, 16) else dst;
            const end = try e.newLabel();
            if (n == 2) {
                try cg.wideDivFast(tag, s, lhs.loc.mem, rhs.loc.mem, data.bin_op.rhs, dst, end);
                const rt_ty: Index = if (s) .i128_type else .u128_type;
                const l: Val = .{ .ty = rt_ty, .loc = lhs.loc };
                const r: Val = .{ .ty = rt_ty, .loc = rhs.loc };
                if (want_q and adjust and s) {
                    // One call for the quotient; the remainder is `a - q * b`
                    // (`__divmodti4` would bring in all of int.zig).
                    try cg.rtCall("udivmod.zig", "__divti3", &.{ l, r }, rt_ty, dst);
                    try cg.mulLimbs(rem, dst, rhs.loc.mem, 2);
                    try cg.ldrLimb(.x9, lhs.loc.mem, 0);
                    try cg.ldrLimb(.x10, rem, 0);
                    try e.addSub(.subs, .x, .x9, .x9, .r(.x10));
                    try cg.strLimb(rem, 0, .x9);
                    try cg.ldrLimb(.x9, lhs.loc.mem, 1);
                    try cg.ldrLimb(.x10, rem, 1);
                    try e.carry(.sbcs, .x, .x9, .x9, .x10);
                    try cg.strLimb(rem, 1, .x9);
                } else if (want_q and adjust) {
                    // One call for both the quotient and the remainder.
                    const rem_ptr: Val = .{ .ty = .usize_type, .loc = .{ .addr = rem } };
                    try cg.rtCall("udivmod.zig", "__udivmodti4", &.{ l, r, rem_ptr }, rt_ty, dst);
                } else if (want_q) {
                    try cg.rtCall("udivmod.zig", if (s) "__divti3" else "__udivti3", &.{ l, r }, rt_ty, dst);
                } else try cg.rtCall("udivmod.zig", if (s) "__modti3" else "__umodti3", &.{ l, r }, rt_ty, rem);
            } else {
                const file = if (s) "divmodei4.zig" else "udivmodei4.zig";
                const q_name = if (s) "__divei4" else "__udivei4";
                const r_name = if (s) "__modei4" else "__umodei4";
                if (adjust or !want_q) try cg.divEi4(file, r_name, rem, lhs.loc.mem, rhs.loc.mem, ty);
                if (want_q) try cg.divEi4(file, q_name, dst, lhs.loc.mem, rhs.loc.mem, ty);
            }
            if (!adjust) return e.bind(end);
            // Adjust when the remainder is non-zero and, for floor and mod,
            // its sign differs from the divisor's; for ceil, when the exact
            // quotient is positive.
            const done = try e.newLabel();
            try cg.ldrLimb(.x9, rem, 0);
            for (1..n) |i| {
                try cg.ldrLimb(.x10, rem, @intCast(i));
                try e.logic(.orr, .x, .x9, .x9, .r(.x10));
            }
            try e.cbz(false, .x, .x9, done);
            if (s) {
                try cg.ldrLimb(.x9, rem, n - 1);
                try cg.ldrLimb(.x10, rhs.loc.mem, n - 1);
                try e.logic(.eor, .x, .x9, .x9, .r(.x10));
                try e.tbz(tag == .div_ceil, .x9, 63, done);
            }
            for (0..n) |i_| {
                const i: u32 = @intCast(i_);
                try cg.ldrLimb(.x9, dst, i);
                switch (tag) {
                    .div_floor => if (i == 0) try e.addSub(.subs, .x, .x9, .x9, .{ .imm = 1 }) else try e.carry(.sbcs, .x, .x9, .x9, .zr),
                    .div_ceil => if (i == 0) try e.addSub(.adds, .x, .x9, .x9, .{ .imm = 1 }) else try e.carry(.adcs, .x, .x9, .x9, .zr),
                    else => {
                        try cg.ldrLimb(.x10, rhs.loc.mem, i);
                        if (i == 0) try e.addSub(.adds, .x, .x9, .x9, .r(.x10)) else try e.carry(.adcs, .x, .x9, .x9, .x10);
                    },
                }
                try cg.strLimb(dst, i, .x9);
            }
            e.bind(done);
            e.bind(end);
        },
        .add_with_overflow, .sub_with_overflow, .mul_with_overflow => {
            const bin = cg.ir.extraData(Ir.Bin, data.ty_pl.payload).data;
            const tuple_ty = data.ty_pl.ty;
            const ty = cg.typeOf(bin.lhs);
            const dst = try cg.resultMem(inst, tuple_ty) orelse return;
            const flag = dst.plus(Type.fieldOffset(ip, tuple_ty, 1));
            const n = cg.limbCount(ty);
            const lhs = try cg.wideVal(bin.lhs);
            const rhs = try cg.wideVal(bin.rhs);
            const info = Type.intInfo(ip, ty);
            const s = info.signedness == .signed;
            // The exact result, in `n` limbs (add, sub) or `2n` (mul).
            const wide_n = if (tag == .mul_with_overflow) 2 * n else n;
            const raw = try cg.allocSlot(@as(u64, wide_n) * 8, 8);
            if (tag == .mul_with_overflow) {
                // Products of the operands extended to 2n limbs are exact.
                const a = try cg.allocSlot(@as(u64, wide_n) * 8, 8);
                const b = try cg.allocSlot(@as(u64, wide_n) * 8, 8);
                for (0..wide_n) |i| {
                    try cg.loadLimb(.x9, lhs, @intCast(i));
                    try cg.strLimb(a, @intCast(i), .x9);
                    try cg.loadLimb(.x9, rhs, @intCast(i));
                    try cg.strLimb(b, @intCast(i), .x9);
                }
                try cg.mulLimbs(raw, a, b, wide_n);
            } else {
                const add = tag == .add_with_overflow;
                for (0..n) |i_| {
                    const i: u32 = @intCast(i_);
                    try cg.ldrLimb(.x9, lhs.loc.mem, i);
                    try cg.ldrLimb(.x10, rhs.loc.mem, i);
                    if (i == 0) {
                        try e.addSub(if (add) .adds else .subs, .x, .x9, .x9, .r(.x10));
                    } else {
                        try e.carry(if (add) .adcs else .sbcs, .x, .x9, .x9, .x10);
                    }
                    try cg.strLimb(raw, i, .x9);
                }
                if (info.bits == 64 * n) {
                    // Full limbs: the carry or overflow flag of the top limb.
                    try e.cset(.x, .x9, if (s) .vs else if (add) .hs else .lo);
                    try cg.storeReg(flag, .x9, 1);
                    return cg.copyMem(dst, raw, @as(u64, n) * 8);
                }
            }
            // Overflowed iff the exact result differs from the truncated
            // result extended back.
            try cg.copyMem(dst, raw, @as(u64, n) * 8);
            try cg.normalizeWide(dst, ty);
            try e.movImm(.x, .x11, 0);
            const res: Val = memVal(ty, dst);
            for (0..wide_n) |i| {
                try cg.loadLimb(.x9, res, @intCast(i));
                try cg.ldrLimb(.x10, raw, @intCast(i));
                try e.logic(.eor, .x, .x9, .x9, .r(.x10));
                try e.logic(.orr, .x, .x11, .x11, .r(.x9));
            }
            try e.cmp(.x, .x11, .{ .imm = 0 });
            try e.cset(.x, .x9, .ne);
            try cg.storeReg(flag, .x9, 1);
        },
        else => unreachable,
    }
}

/// `@clz`, `@ctz`, `@popCount`, `@byteSwap`, and `@bitReverse` of a wide
/// integer, limb by limb.
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
    switch (tag) {
        .clz, .ctz => {
            // x9 = the count so far; stop at the first limb with a set bit.
            const done = try e.newLabel();
            try e.movImm(.x, .x9, 0);
            for (0..n) |k| {
                const i: u32 = @intCast(if (tag == .clz) n - 1 - k else k);
                try cg.ldrLimb(.x10, src, i);
                const own: u8 = if (i == n - 1) r else 64;
                if (tag == .clz) {
                    // The top limb's bits, at the top of the register.
                    if (own != 64) try e.shiftImm(.lsl, .x, .x10, .x10, @intCast(64 - own));
                    try e.bitOp(.clz, .x, .x11, .x10);
                } else {
                    if (own != 64) try e.bitfield(.ubfm, .x, .x10, .x10, 0, @intCast(own - 1));
                    try e.bitOp(.rbit, .x, .x11, .x10);
                    try e.bitOp(.clz, .x, .x11, .x11);
                }
                if (own != 64) {
                    // An empty top limb counts its own bits only.
                    try e.movImm(.x, .x12, own);
                    try e.cmp(.x, .x10, .{ .imm = 0 });
                    try e.csel(.csel, .x, .x11, .x12, .x11, .eq);
                }
                try e.addSub(.add, .x, .x9, .x9, .r(.x11));
                try e.cbz(true, .x, .x10, done);
            }
            e.bind(done);
            try cg.storeReg(dst, .x9, Type.abiSize(cg.ip, ty));
        },
        .popcount => {
            try e.movImm(.x, .x9, 0);
            for (0..n) |i| {
                try cg.ldrLimb(.x10, src, @intCast(i));
                if (i == n - 1 and r != 64) try e.bitfield(.ubfm, .x, .x10, .x10, 0, @intCast(r - 1));
                try e.fmovFromGpr(.f64, .v0, .x, .x10);
                try e.cnt(.v0, .v0);
                try e.addv(.v0, .v0);
                try e.fmovToGpr(.w, .x10, .f32, .v0);
                try e.addSub(.add, .x, .x9, .x9, .r(.x10));
            }
            try cg.storeReg(dst, .x9, Type.abiSize(cg.ip, ty));
        },
        .byte_swap, .bit_reverse => {
            // Reverse the n limbs, each reversed in itself, then shift the
            // result down by the bits above the operand's width.
            for (0..n) |i| {
                try cg.ldrLimb(.x9, src, @intCast(n - 1 - i));
                try e.bitOp(if (tag == .byte_swap) .rev else .rbit, .x, .x9, .x9);
                try cg.strLimb(dst, @intCast(i), .x9);
            }
            if (r != 64) {
                const sh: u6 = @intCast(64 - r);
                for (0..n) |i| {
                    try cg.ldrLimb(.x9, dst, @intCast(i));
                    try e.shiftImm(.lsr, .x, .x9, .x9, sh);
                    if (i + 1 < n) {
                        try cg.ldrLimb(.x10, dst, @intCast(i + 1));
                        try e.logic(.orr, .x, .x9, .x9, .{ .reg = .{ .reg = .x10, .amount = @intCast(64 - @as(u7, sh)) } });
                    }
                    try cg.strLimb(dst, @intCast(i), .x9);
                }
            }
            try cg.normalizeWide(dst, ty);
        },
        else => unreachable,
    }
}

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
