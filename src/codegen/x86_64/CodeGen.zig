//! Code generation for x86_64: one function's IR to one Atom. The IR is
//! first built into the shared SSA form (`../Ssa.zig`), whose blocks this
//! file emits in layout order. Values still lower through per-instruction
//! code, but scalar values get registers from linear scan and the rest
//! share stack slots by lifetime (step 2 of docs/slop/architecture.md,
//! "Optimizing backend"; see "Registers" below).
//!
//! Frame: `push rbp; mov rbp, rsp`, the callee-saved registers the function
//! uses, `sub rsp, N`. Slots are at negative offsets from rbp, below the
//! saved registers; outgoing call arguments are at the bottom of the frame
//! (positive offsets from rsp).
//!
//! Calling conventions:
//! - `.auto` (bs to bs; see `autoClass`): arguments of up to 8 bytes in
//!   rdi, rsi, rdx, rcx, r8, r9, of 9 to 16 bytes in two consecutive ones
//!   (never split with the stack), f16/f32/f64 in xmm0-xmm7; the rest, and
//!   what does not fit, at 8-byte aligned offsets of the outgoing area,
//!   read by the callee at rbp+16. Results likewise in rax (and rdx) or
//!   xmm0; larger ones through a pointer the caller passes in rdi, which
//!   then takes the first argument register. The caller's error return
//!   trace pointer goes in rax.
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
const Ssa = @import("../Ssa.zig");
const vector = @import("vector.zig");
const atomic128 = @import("atomic128.zig");
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
/// Per pointer `base + off` folded into its users' addressing
/// (`addrFoldable`): the value its address is based on, else `no_base`.
addr_base: []u32,
ssa: *const Ssa,
/// Each SSA block's label, by block index.
labels: []Encoder.Label,
/// Bytes of stack slots below rbp.
slots_size: u32 = 0,
/// Largest outgoing argument area of any call.
out_args_size: u32 = 0,
/// rbp offset of the slot holding the result pointer (for results returned
/// in memory).
ret_ptr_slot: ?i32 = null,
/// The `alloc` whose memory is the result's (see `planCopies`).
rvo_alloc: ?Inst.Index = null,
/// rbp offset of the slots a Win64 function saves rsi, rdi, and
/// xmm6-xmm15 in (`setupWinParams`), which that convention preserves.
win_save: ?i32 = null,
/// From `planCopies`: `*const` allocs that may alias the memory of the
/// value they are initialized with, and those values, whose slots are
/// not shared.
copy_of: std.AutoHashMapUnmanaged(u32, u32) = .empty,
copy_private: std.AutoHashMapUnmanaged(u32, void) = .empty,
/// `copy_of` allocs whose initializer is a by-reference argument: the
/// alloc's value is the argument's pointer (`planCopies`).
ref_alias: std.AutoHashMapUnmanaged(u32, void) = .empty,
/// From `planConstAliases`: `*const` allocs initialized with a constant
/// in memory that are that constant's memory.
const_alias: std.AutoHashMapUnmanaged(u32, Index) = .empty,
/// From `planCopies`: values whose slot is that of the block their `br`
/// exits, by value.
slot_alias: std.AutoHashMapUnmanaged(u32, u32) = .empty,
/// From `planPayloadRegions`: allocs that share one frame region with the
/// error union of the call whose payload initializes them, by alloc: the
/// call and the block that unwraps it. The region holds the error union,
/// and the alloc and the block are its payload.
payload_region: std.AutoHashMapUnmanaged(u32, [2]u32) = .empty,
/// From `planDeferred`: aggregates built in the memory of the store that
/// is their only user, with the store's pointer, by value.
in_place: std.AutoHashMapUnmanaged(u32, Ref) = .empty,
/// From `planRotates`: `bit_or`s that are rotates, with what they rotate
/// left and by how much, by value.
rotates: std.AutoHashMapUnmanaged(u32, Rotate) = .empty,
/// From `planMulWide`: factors of 128-bit products computed with one
/// `mul` that `planMulWide` stopped computing (`Home.dead`), by value.
mul_dead: std.AutoHashMapUnmanaged(u32, void) = .empty,
/// rbp offset of the slot holding the error return trace pointer: an
/// `.auto` function's from r9, another's from `set_err_return_trace`.
/// Null in a function that has none, whose `.auto` calls pass null.
trace_slot: ?i32 = null,
/// The callee-saved registers the function's values use (`alloc_regs`
/// bits), which the prologue saves below rbp and every return restores.
saved: u32 = 0,
/// `Ssa.liveness` ran, so value slots are shared by lifetime.
live: bool = false,
/// The function's one epilogue, which ends its code (`Atom.Unwind.epilogue`):
/// returns other than one in the last block emitted jump to it. Null until
/// a return needs it.
ret_label: ?Encoder.Label = null,
/// `ret_label` is bound: the epilogue is emitted.
ret_bound: bool = false,
/// Where the epilogue's `ret` ends, before shortening.
ret_end: u32 = 0,
/// Panic calls in code the backend inlined, which call a chain of stubs
/// emitted after the epilogue instead of the handler (`panicThroughStubs`),
/// with the inlined calls open at each (`stub_open`), and the stubs'
/// bytes so far.
stub_chains: std.ArrayList(StubChain) = .empty,
stub_open: std.ArrayList(OpenInline) = .empty,
stub_bytes: u32 = 0,
/// Emitting the cold blocks, after the others: their values get slots of
/// their own (see `Ssa.place`).
in_cold: bool = false,
/// Per cold block, in `Ssa.order`, the debug state where it would have
/// been emitted in place: its row and the inlined calls open there
/// (`cold_open[open_start..][0..open_len]`).
cold_starts: std.ArrayList(ColdStart) = .empty,
/// `-ffuzz`: the key of the function's coverage counters, and the code
/// offset of each coverage point, in counter order.
cover_key: SymbolKey = undefined,
cover_pcs: std.ArrayList(u32) = .empty,
cold_open: std.ArrayList(OpenInline) = .empty,
/// The function contains inline assembly, so no value gets a register.
has_asm: bool = false,
/// Per value in two registers that code read from memory, or in a
/// register saved around clobber points (`split_vals`): its slot.
pair_spills: std.AutoHashMapUnmanaged(u32, i32) = .empty,
/// The values that may cross a clobber point in a register that does not
/// survive it (`planSplits`), for `Ssa.allocate`.
split: std.DynamicBitSetUnmanaged = .{},
/// The values that got such a register: each clobber point they cross
/// stores them to their slot first, and they are read from there and
/// reloaded after it (`genSplit`). Loads that share such a value's
/// register follow it (`of`, else the value itself). A value that does
/// not change (not a variable or a block result) is stored once per block
/// (`stored`, the last block that stored it).
split_vals: std.ArrayList(struct { v: u32, of: u32, stored: u32 = no_base }) = .empty,
/// The block `genBlock` emits.
cur_block: u32 = 0,
/// Scratch for `genSplit`: the values saved around the current clobber
/// point, with their homes.
split_now: std.ArrayList(struct { v: u32, home: Home, reload: bool }) = .empty,
/// The call arguments that do not cross their call (`exemptArgs`), with
/// the allocator index of the register they are passed in.
arg_hints: std.ArrayList(struct { v: u32, r: u8 }) = .empty,
/// The condition under which the last overflow operation whose bit its
/// block's branch reads from the flags (`Home.fused`) overflowed.
ovf_cc: Encoder.Cond = .o,
/// Scratch for `.auto` argument classification (`argScratch`).
arg_tys: std.ArrayList(Index) = .empty,
arg_locs: std.ArrayList(AutoArg) = .empty,
arg_refs: std.ArrayList(ArgRef) = .empty,
/// Inline assembly marked the return address undefined (`.cfi_undefined
/// %rip`): this is the outermost frame.
outermost_frame: bool = false,
/// In a variadic C function: where the prologue saved the argument
/// registers, and what the named parameters used of them and of the stack.
va: struct { save: i32 = 0, gp: u8 = 0, sse: u8 = 0, stack: u32 = 0 } = .{},
/// Debug info: the last line row (relative to the innermost open inline
/// call's declaration, or the function's), the inlined calls, the source
/// files other than the function's that they come from, and the open
/// calls, innermost last.
dbg_line: u32 = 0,
dbg_column: u32 = 0,
dbg_inlines: std.ArrayList(Atom.Debug.Inline) = .empty,
dbg_inline_names: std.ArrayList(u8) = .empty,
dbg_inline_callees: std.ArrayList(SymbolKey) = .empty,
dbg_files: std.ArrayList(u32) = .empty,
dbg_open: std.ArrayList(OpenInline) = .empty,

/// An inlined call whose end is not reached yet, and the caller's row to
/// resume after it.
const OpenInline = struct { index: u32, line: u32, column: u32, backend: bool = false };

/// A panic call through stubs: the stubs' first label, the handler, the
/// inlined calls open at the call (`stub_open[open_start..][0..open_len]`),
/// and the row of the check, relative to the innermost.
const StubChain = struct { label: Encoder.Label, target: SymbolKey, open_start: u32, open_len: u32, line: u32, column: u32 };

const ColdStart = struct { line: u32, column: u32, open_start: u32, open_len: u32 };

pub const Error = Allocator.Error || error{CodegenFail};

/// Where an instruction's value lives.
const Home = union(enum) {
    none,
    /// The value is in this register (see `planRegisters`).
    reg: Reg,
    /// A 16-byte value (`inPair`) whose eightbytes are in these registers.
    /// Code that reads it from memory gets a copy (`spillPair`).
    regs: Regs,
    /// An f32 or f64 (`inFloat`) in the low lane of this register. Code
    /// that reads it from memory gets a copy (`spillXmm`).
    xmm: Encoder.Xmm,
    /// A condition fused into its block's branch, which computes it.
    fused,
    /// An overflow result that is not stored: its operation writes its
    /// fields' values (see `pairs`).
    pair,
    /// The value is stored at `[rbp + off]`.
    slot: i32,
    /// A memory-class `.auto` argument, passed by reference: the value is
    /// the memory at `[reg]`, which does not change during the call (see
    /// `autoArgs`).
    ind: Reg,
    /// The value is the address `rbp + off` (an `alloc`).
    frame_addr: i32,
    /// The value is the address `base + off`, a register holding another
    /// value (`addrFoldable`).
    reg_addr: struct { base: Reg, off: i32 },
    /// A load read in place by its only user (see `planDeferred`): the
    /// value is the memory its pointer points to.
    deferred,
    /// Nothing reads the value and computing it has no effect: it is not
    /// emitted (pass 2).
    dead,
    /// Read in place by its only user, a vector operation
    /// (`vector.deferOperands`): a bitcast to a vector of a deferred load,
    /// whose value is the load's memory, or a select of indices that its
    /// reduce scans the predicate's bits for.
    view,
};

const Regs = struct { lo: Reg, hi: Reg };

/// Where an operand's value can be read.
const Loc = union(enum) {
    none,
    /// The value is in a register, extended to 64 bits.
    reg: Reg,
    /// The value is stored in memory.
    mem: Mem,
    /// The value is the address of this memory.
    addr: Mem,
    /// A scalar constant, already extended to 64 bits.
    imm: u64,
    /// The code of an error, resolved at link time.
    err: InternPool.String,
    /// An f32 or f64 in an XMM register. Only `valOf` returns it; `locOf`
    /// gives such a value's memory.
    xmm: Encoder.Xmm,
};

pub fn generate(emit: *Emit, ir: *const Ir) Error!void {
    const ip = &emit.zcu.ip;
    const func = ip.keyPayload(.func, ir.func);
    const gpa = emit.gpa;
    const t0 = std.Io.Timestamp.now(emit.zcu.io, .awake);
    try emit.ssa.build(gpa, ir);
    const cover = emit.fuzz and instrumented(emit, ir);
    try emit.ssa.place(gpa, ir, cover);
    const t1 = std.Io.Timestamp.now(emit.zcu.io, .awake);
    var t2 = t1;
    defer {
        const s = &emit.codegen_stats;
        s.build_ns += @intCast(t0.durationTo(t1).nanoseconds);
        s.alloc_ns += @intCast(t1.durationTo(t2).nanoseconds);
        s.emit_ns += @intCast(t2.durationTo(.now(emit.zcu.io, .awake)).nanoseconds);
        s.functions += 1;
        s.ir_insts += ir.instructions.len;
    }
    var cg: CodeGen = .{
        .emit = emit,
        .gpa = gpa,
        .ip = ip,
        .ir = ir,
        .e = .init(gpa),
        .fn_ty = ip.keyPayload(.func_type, func.ty),
        .homes = try gpa.alloc(Home, ir.instructions.len),
        .addr_base = try gpa.alloc(u32, ir.instructions.len),
        .ssa = &emit.ssa,
        .labels = try gpa.alloc(Encoder.Label, emit.ssa.blocks.items.len),
    };
    defer {
        cg.e.deinit();
        gpa.free(cg.homes);
        gpa.free(cg.addr_base);
        gpa.free(cg.labels);
        cg.dbg_inlines.deinit(gpa);
        cg.dbg_inline_names.deinit(gpa);
        cg.dbg_inline_callees.deinit(gpa);
        cg.dbg_files.deinit(gpa);
        cg.dbg_open.deinit(gpa);
        cg.arg_tys.deinit(gpa);
        cg.arg_locs.deinit(gpa);
        cg.arg_refs.deinit(gpa);
        cg.pair_spills.deinit(gpa);
        cg.split.deinit(gpa);
        cg.split_vals.deinit(gpa);
        cg.split_now.deinit(gpa);
        cg.arg_hints.deinit(gpa);
        cg.copy_of.deinit(gpa);
        cg.copy_private.deinit(gpa);
        cg.ref_alias.deinit(gpa);
        cg.const_alias.deinit(gpa);
        cg.slot_alias.deinit(gpa);
        cg.payload_region.deinit(gpa);
        cg.in_place.deinit(gpa);
        cg.rotates.deinit(gpa);
        cg.mul_dead.deinit(gpa);
        cg.cold_starts.deinit(gpa);
        cg.cold_open.deinit(gpa);
        cg.stub_chains.deinit(gpa);
        cg.stub_open.deinit(gpa);
        cg.cover_pcs.deinit(gpa);
    }
    if (cover) cg.cover_key = Emit.coverageKeys(try emit.funcKey(ir.func))[0];
    @memset(cg.homes, .none);
    @memset(cg.addr_base, no_base);
    try cg.planRegisters();
    // Inline assembly may compute offsets in the code itself.
    cg.e.shorten = !cg.has_asm;
    t2 = std.Io.Timestamp.now(emit.zcu.io, .awake);

    // The prologue belongs to the declaration's line.
    try cg.e.line(0, 0);
    const naked = cg.fn_ty.cc == .naked;
    var frame_patch: usize = 0;
    const saved_size = 8 * @popCount(cg.saved);
    if (!naked) {
        try cg.e.push(.rbp);
        try cg.e.mov(.qword, .{ .reg = .rbp }, .{ .reg = .rsp });
        for (alloc_regs, 0..) |r, i| if (cg.saved >> @intCast(i) & 1 != 0) try cg.e.push(r);
        cg.slots_size = saved_size;
        // Placeholder large enough for the imm32 form; patched below.
        try cg.e.alu(.sub, .qword, .{ .reg = .rsp }, .{ .imm = 0x10000 });
        frame_patch = cg.e.code.items.len;
        try cg.setupParams();
    }
    try cg.emitBlocks();
    // Stubs need the epilogue's frame description even in a function
    // that never returns.
    if ((cg.ret_label != null or cg.stub_chains.items.len != 0) and !cg.ret_bound) {
        // The last block does not return: the epilogue follows it, in the
        // function's own line table.
        if (cg.in_cold or cg.dbg_open.items.len != 0) try cg.e.switchLines(0, 0);
        try cg.epilogue();
    }
    try cg.emitStubs();
    try cg.e.finishShortened();
    frame_patch = cg.e.mapOffset(@intCast(frame_patch));
    for (cg.cover_pcs.items) |*pc| pc.* = cg.e.mapOffset(pc.*);
    for (cg.dbg_inlines.items) |*in| {
        in.low = cg.e.mapOffset(in.low);
        in.high = cg.e.mapOffset(in.high);
    }

    // The stack probes after the code, if any (`Atom.Unwind.probes`).
    var probes: u32 = 0;
    if (!naked) {
        // The saved registers are pushed already.
        const frame = std.mem.alignForward(u32, cg.slots_size + cg.out_args_size, 16) - saved_size;
        if (frame <= 4096) {
            std.mem.writeInt(u32, cg.e.code.items[frame_patch - 4 ..][0..4], frame, .little);
        } else {
            // A frame over a page is allocated by probing each page, as
            // upstream, out of line: the prologue's `sub rsp, imm32` becomes
            // a jump to the probes at the end, which jump back. The CFA is
            // rbp-based by then, so the frame info holds throughout.
            const stub: u32 = @intCast(cg.e.code.items.len);
            const sub_at: u32 = @intCast(frame_patch - 7);
            try cg.e.line(0, 0);
            try cg.e.probedFrameAlloc(frame, @intCast(frame_patch));
            cg.e.code.items[sub_at] = 0xe9;
            std.mem.writeInt(i32, cg.e.code.items[sub_at + 1 ..][0..4], @intCast(@as(i64, stub) - @as(i64, sub_at + 5)), .little);
            @memcpy(cg.e.code.items[sub_at + 5 ..][0..2], &[_]u8{ 0x66, 0x90 });
            probes = @intCast(cg.e.code.items.len - stub);
        }
    }

    emit.codegen_stats.code_bytes += cg.e.code.items.len;
    emit.codegen_stats.frame_bytes += cg.slots_size + cg.out_args_size;

    const arena = emit.allocator();
    const nav = ip.getNav(func.owner_nav);
    const file = emit.zcu.file(nav.file);
    // A compile unit per module, named after its root file, as upstream.
    const module = emit.zcu.fe.module(file.module);
    var files: std.ArrayList(u8) = .empty;
    for (cg.dbg_files.items) |f| {
        try files.appendSlice(arena, emit.zcu.file(f).display_path);
        try files.append(arena, 0);
    }
    const debug: Atom.Debug = .{
        .file = file.display_path,
        .name = ip.stringSlice(nav.name),
        .base_line = file.zir.getDeclaration(nav.zir_inst).src_line,
        .lines = try arena.dupe(u8, cg.e.lines.bytes.items),
        .unit = try std.fs.path.join(arena, &.{ module.root_dir, module.root_file }),
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
        // A cache line, so that run time does not depend on the sizes of
        // the functions before this one. `fn f() align(n)` raises it.
        .alignment = .fromByteUnits(@max(64, nav.alignment)),
        .bytes = try arena.dupe(u8, cg.e.code.items),
        .targets = try arena.dupe(Atom.SymbolKey, cg.e.refs.targets.keys()),
        .relocs = try arena.dupe(Atom.Reloc, cg.e.refs.relocs.items),
        // `cg.saved` has `Atom.Unwind.saved`'s x86_64 bits: the prologue
        // pushes `alloc_regs`' callee-saved ones in that order.
        .unwind = if (cg.outermost_frame) .outermost else if (naked) .none else .{
            .kind = .frame_pointer,
            // The `ret`'s distance from the end, past the stubs and probes.
            .epilogue = if (cg.ret_bound) @intCast(cg.e.code.items.len - cg.e.mapOffset(cg.ret_end - 1)) else 0,
            .probes = @intCast(probes),
            .saved = @intCast(cg.saved),
        },
    }, debug);
    if (cover) try emit.addCoverage(try emit.funcKey(ir.func), cg.cover_pcs.items);
}

/// Whether `-ffuzz` instruments the function: in a module with `-ffuzz`
/// (never compiler_rt or the fuzzer's own family), not naked, and not after
/// `@disableInstrumentation()` (docs/slop/architecture.md, "Fuzzing").
fn instrumented(emit: *Emit, ir: *const Ir) bool {
    const ip = &emit.zcu.ip;
    const func = ip.keyPayload(.func, ir.func);
    if (ir.disable_instrumentation or ip.keyPayload(.func_type, func.ty).cc == .naked) return false;
    return emit.zcu.fe.module(emit.zcu.file(ip.getNav(func.owner_nav).file).module).fuzz;
}

/// A coverage point at the start of a covered block: its counter is set
/// (`mov byte [rip + counters + i], 1`, which needs no register and
/// leaves the flags), and its address joins the PC table. The entry's
/// address is the function's own, as upstream's.
fn coverPoint(cg: *CodeGen, entry: bool) Error!void {
    const i: i32 = @intCast(cg.cover_pcs.items.len);
    try cg.cover_pcs.append(cg.gpa, if (entry) 0 else @intCast(cg.e.code.items.len));
    try cg.e.mov(.byte, .{ .mem = .sym(cg.cover_key, i) }, .{ .imm = 1 });
}

/// Starts the code of a call of `func` inlined at `site`, relative to the
/// innermost open call (see `Atom.Debug.inlines`); its rows are relative
/// to `func`'s declaration, in its file.
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
    // A callee inlined again in this function shares its name.
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

/// Ends the innermost inlined call: the code after it is the caller's,
/// from the caller's last statement on.
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
    const ip = cg.ip;
    const nav = ip.getNav(ip.keyPayload(.func, cg.ir.func).owner_nav);
    const tree = try cg.emit.zcu.fe.tree(@fromBackingInt(nav.file));
    const decl = cg.emit.zcu.file(nav.file).zir.getDeclaration(nav.zir_inst);
    try cg.emit.addError(nav.file, tree.nodeToSpan(decl.src_node), "bs codegen: " ++ fmt, args);
    return error.CodegenFail;
}

// ---------------------------------------------------------------------------
// Frame and homes

pub fn allocSlot(cg: *CodeGen, size: u64, alignment: u64) Error!i32 {
    if (alignment > 16) return cg.fail("stack values aligned to more than 16 bytes", .{});
    cg.slots_size = std.mem.alignForward(u32, cg.slots_size + @as(u32, @intCast(size)), @intCast(@max(alignment, 1)));
    return -@as(i32, @intCast(cg.slots_size));
}

fn slotFor(cg: *CodeGen, inst: Inst.Index, ty: Index) Error!Home {
    if (!Type.hasRuntimeBits(cg.ip, ty)) {
        cg.homes[@backingInt(inst)] = .none;
        return .none;
    }
    // Part of an alloc's frame region (`payload_region`), set when the
    // alloc was emitted.
    if (cg.payload_region.count() != 0 and cg.homes[@backingInt(inst)] == .slot) {
        var it = cg.payload_region.valueIterator();
        while (it.next()) |r| {
            if (r[0] == @backingInt(inst) or r[1] == @backingInt(inst)) return cg.homes[@backingInt(inst)];
        }
    }
    // The result of the block it exits (`planCopies`), once that has its slot.
    if (cg.slot_alias.count() != 0) if (cg.slot_alias.get(@backingInt(inst))) |blk| if (cg.homes[blk] == .slot) {
        cg.homes[@backingInt(inst)] = cg.homes[blk];
        return cg.homes[blk];
    };
    // A value's home is only copied from and to, never addressed as a `*T`
    // (Sema takes addresses of `alloc`s, which realign themselves), so 16
    // bytes suffice for any type, as for arguments, which have 8.
    const size = Type.abiSize(cg.ip, ty);
    const alignment = @min(Type.abiAlignment(cg.ip, ty), 16);
    // Values are emitted in layout order, so a slot whose value's interval
    // has ended can be shared (pass 7 of the design).
    const private = cg.copy_private.count() != 0 and cg.copy_private.contains(@backingInt(inst));
    const class = if (cg.live and !cg.in_cold and !private) Ssa.slotClass(size, alignment) else null;
    const home: Home = .{ .slot = if (class) |c| blk: {
        const f = &cg.emit.ssa;
        const off = try f.takeSlot(cg.gpa, inst, c) orelse try cg.allocSlot(c.size, c.alignment);
        try f.holdSlot(cg.gpa, inst, off, c);
        break :blk off;
    } else try cg.allocSlot(size, alignment) };
    cg.homes[@backingInt(inst)] = home;
    return home;
}

/// The memory of a result slot, or of the store that is the value's only
/// user (`in_place`), with r10 as the base if its pointer is not in a
/// register.
pub fn resultMem(cg: *CodeGen, inst: Inst.Index, ty: Index) Error!?Mem {
    if (cg.in_place.count() != 0) if (cg.in_place.get(@backingInt(inst))) |ptr| return try cg.ptrMem(ptr);
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

/// How `.auto` passes a value of a type: in one or two general-purpose
/// registers (the bytes of the value, as eightbytes; one register holds a
/// 1-, 2-, 4-, or 8-byte value extended like a load), in an SSE register,
/// or in memory (arguments by reference, results through a pointer in
/// rdi; see `autoArgs`).
const AutoClass = enum { none, gpr, gpr_pair, sse, memory };

fn autoClass(cg: *CodeGen, ty: Index) AutoClass {
    return autoClassOf(cg.ip, ty);
}

fn autoClassOf(ip: *const InternPool, ty: Index) AutoClass {
    if (Type.class(ip, ty) == .float) return switch (Type.floatBits(ip, ty)) {
        16, 32, 64 => .sse,
        else => .memory,
    };
    if (vector.inXmm(ip, ty)) return .sse;
    // Runtime IR has no comptime-only types, so size 0 means no bits.
    const size = Type.abiSize(ip, ty);
    return if (size == 0) .none else if (size <= 8) .gpr else if (size <= 16) .gpr_pair else .memory;
}

/// Where the `.auto` convention puts each argument, in order, given the
/// result type; the stack offsets are from the start of the outgoing area.
/// A memory-class argument is passed by reference (`ref`, or `ref_stack`
/// when the registers are taken): a pointer to memory that holds the value
/// and does not change during the call. Parameters do not change, so the
/// callee reads the value there (`Home.ind`) instead of copying it. The
/// caller passes a constant's own memory, a by-reference parameter's
/// pointer, or else a copy in its outgoing area (`call`); so a comptime
/// table passed by value is not copied at all.
const AutoArg = union(enum) { none, gpr: u8, gpr_pair: u8, sse: u8, stack: u32, ref: u8, ref_stack: u32 };

fn autoArgs(cg: *CodeGen, ret_ty: Index, tys: []const Index, locs: []AutoArg) u32 {
    var gp: u8 = @intFromBool(cg.autoClass(ret_ty) == .memory);
    var sse: u8 = 0;
    var stack: u32 = 0;
    for (tys, locs) |ty, *l| {
        l.* = switch (cg.autoClass(ty)) {
            .none => .none,
            .gpr => if (gp < 6) blk: {
                gp += 1;
                break :blk .{ .gpr = gp - 1 };
            } else .{ .stack = 0 },
            // A pair never splits between registers and the stack.
            .gpr_pair => if (gp < 5) blk: {
                gp += 2;
                break :blk .{ .gpr_pair = gp - 2 };
            } else .{ .stack = 0 },
            .sse => if (sse < 8) blk: {
                sse += 1;
                break :blk .{ .sse = sse - 1 };
            } else .{ .stack = 0 },
            .memory => if (gp < 6) blk: {
                gp += 1;
                break :blk .{ .ref = gp - 1 };
            } else .{ .ref_stack = 0 },
        };
        switch (l.*) {
            .stack => {
                l.* = .{ .stack = stack };
                stack += @intCast(std.mem.alignForward(u64, Type.abiSize(cg.ip, ty), 8));
            },
            .ref_stack => {
                l.* = .{ .ref_stack = stack };
                stack += 8;
            },
            else => {},
        }
    }
    return stack;
}

/// Whether a call to a function of type `fn_ty` passes every argument in
/// registers: its convention is `.auto` and `autoArgs` puts no argument
/// on the stack (counting rdi for a result returned through memory, and
/// no register for arguments without bits). For the inliner, which lets
/// a callee keep only calls it can route through return stubs, whose
/// pushed return addresses would shift rsp under an outgoing area.
/// Variadic and other conventions give false. A generic instance's type
/// lists exactly its runtime parameters, the arguments `call` passes.
/// Pure: callable from the Sema thread. Counts as `autoArgs` does; change
/// both together.
pub fn argsInRegs(ip: *const InternPool, fn_ty: Index) bool {
    const f = ip.keyPayload(.func_type, fn_ty);
    if (f.cc != .auto or f.is_var_args) return false;
    var gp: u8 = @intFromBool(autoClassOf(ip, f.return_type) == .memory);
    var sse: u8 = 0;
    for (f.param_types) |ty| switch (autoClassOf(ip, ty)) {
        .none => {},
        .gpr => if (gp < 6) {
            gp += 1;
        } else return false,
        .gpr_pair => if (gp < 5) {
            gp += 2;
        } else return false,
        .sse => if (sse < 8) {
            sse += 1;
        } else return false,
        // By reference: the pointer takes a register, or the stack.
        .memory => if (gp < 6) {
            gp += 1;
        } else return false,
    };
    return true;
}

test argsInRegs {
    var ip: InternPool = try .init(std.testing.allocator, std.testing.io, 1);
    defer ip.deinit();
    const big = try ip.get(.main, .{ .array_type = .{ .len = 3, .child = .u64_type } });
    const pair = try ip.get(.main, .{ .array_type = .{ .len = 2, .child = .u64_type } });
    const T = struct {
        fn fits(p: *InternPool, params: []const Index, result: Index, cc: InternPool.CallingConvention) !bool {
            return argsInRegs(p, try p.get(.main, .{ .func_type = .{ .param_types = params, .return_type = result, .cc = cc } }));
        }
    };
    const ints: [7]Index = @splat(.u64_type);
    try std.testing.expect(try T.fits(&ip, ints[0..6], .void_type, .auto));
    try std.testing.expect(!try T.fits(&ip, ints[0..7], .void_type, .auto));
    // A result in memory takes rdi.
    try std.testing.expect(try T.fits(&ip, ints[0..5], big, .auto));
    try std.testing.expect(!try T.fits(&ip, ints[0..6], big, .auto));
    // Arguments without bits take no register; a pair needs two.
    try std.testing.expect(try T.fits(&ip, &([_]Index{.void_type} ++ ints[0..6].*), .void_type, .auto));
    try std.testing.expect(try T.fits(&ip, &([_]Index{pair} ++ ints[0..4].*), .void_type, .auto));
    try std.testing.expect(!try T.fits(&ip, &(ints[0..5].* ++ [_]Index{pair}), .void_type, .auto));
    // Floats take the 8 SSE registers, beside the 6 general ones; an
    // argument over 16 bytes is passed by reference, its pointer in a
    // general register or on the stack.
    const floats: [9]Index = @splat(.f64_type);
    try std.testing.expect(try T.fits(&ip, &(floats[0..8].* ++ ints[0..6].*), .void_type, .auto));
    try std.testing.expect(!try T.fits(&ip, floats[0..9], .void_type, .auto));
    try std.testing.expect(try T.fits(&ip, &(ints[0..5].* ++ [_]Index{big}), .void_type, .auto));
    try std.testing.expect(!try T.fits(&ip, &(ints[0..6].* ++ [_]Index{big}), .void_type, .auto));
    try std.testing.expect(!try T.fits(&ip, &.{}, .void_type, .c));
}

/// Where a by-reference argument's pointer comes from: a register
/// holding it, or an address.
const ArgRef = union(enum) { reg: Reg, addr: Mem };

/// The memory a by-reference argument `ref` may be passed in without a
/// copy, which nothing writes during the call: a constant's, a
/// by-reference parameter's (`Home.ind`), or a value's slot. A value has
/// no address anything else could write through, and its slot is not
/// shared with the call's result (`Ssa.takeSlot` frees a slot only after
/// its interval's end, the call).
fn argRef(cg: *CodeGen, ref: Ref) Error!?ArgRef {
    if (ref.toIndex()) |v| return switch (cg.homes[@backingInt(v)]) {
        .ind => |r| .{ .reg = r },
        .slot => |off| .{ .addr = Mem.at(.rbp, off) },
        else => null,
    };
    return switch (try cg.constLoc(ref.toInterned().?)) {
        .mem => |m| .{ .addr = m },
        else => null,
    };
}

/// Buffers for `n` argument types and locations, reused by every call.
fn argScratch(cg: *CodeGen, n: usize) Error!struct { []Index, []AutoArg } {
    try cg.arg_tys.resize(cg.gpa, n);
    try cg.arg_locs.resize(cg.gpa, n);
    return .{ cg.arg_tys.items, cg.arg_locs.items };
}

/// Loads the `n` bytes (1 to 8) at `m` into `reg`, zero-extended. Uses r11
/// for sizes that take more than one load.
fn loadBytes(cg: *CodeGen, reg: Reg, m: Mem, n: u64) Error!void {
    const e = &cg.e;
    switch (n) {
        8 => return e.mov(.qword, .{ .reg = reg }, .{ .mem = m }),
        4 => return e.movzx(.qword, reg, .dword, .{ .mem = m }),
        2 => return e.movzx(.qword, reg, .word, .{ .mem = m }),
        1 => return e.movzx(.qword, reg, .byte, .{ .mem = m }),
        3 => try e.movzx(.qword, reg, .word, .{ .mem = m }),
        else => try e.movzx(.qword, reg, .dword, .{ .mem = m }),
    }
    var off: u64 = if (n == 3) 2 else 4;
    while (off < n) {
        const chunk: u64 = if (n - off >= 2) 2 else 1;
        try e.movzx(.qword, .r11, if (chunk == 2) .word else .byte, .{ .mem = offsetMem(m, off) });
        try e.shift(.shl, .qword, .{ .reg = .r11 }, @intCast(off * 8));
        try e.alu(.@"or", .qword, .{ .reg = reg }, .{ .reg = .r11 });
        off += chunk;
    }
}

/// Stores the low `n` bytes (1 to 8) of `reg` to `m`. Uses r11.
fn storeBytes(cg: *CodeGen, m: Mem, reg: Reg, n: u64) Error!void {
    switch (n) {
        1, 2, 4, 8 => return cg.storeReg(m, reg, n),
        else => {},
    }
    const e = &cg.e;
    try e.mov(.qword, .{ .reg = .r11 }, .{ .reg = reg });
    var off: u64 = 0;
    while (off < n) {
        const chunk: u64 = if (n - off >= 4) 4 else if (n - off >= 2) 2 else 1;
        try e.mov(sizeOf(chunk), .{ .mem = offsetMem(m, off) }, .{ .reg = .r11 });
        off += chunk;
        if (off < n) try e.shift(.shr, .qword, .{ .reg = .r11 }, @intCast(chunk * 8));
    }
}

/// Loads `.auto` value `ref` of class `gpr` into `reg`.
fn loadGpr(cg: *CodeGen, reg: Reg, ref: Ref, ty: Index) Error!void {
    const size = Type.abiSize(cg.ip, ty);
    switch (size) {
        1, 2, 4, 8 => try cg.load(reg, ref),
        else => try cg.loadBytes(reg, try cg.memOf(ref), size),
    }
}

/// Loads `.auto` value `ref` of class `gpr_pair` into `lo` and `hi`.
fn loadPair(cg: *CodeGen, lo: Reg, hi: Reg, ref: Ref) Error!void {
    if (cg.pairOf(ref) != null) return cg.loadRegs(.{ .lo = lo, .hi = hi }, ref);
    const size = Type.abiSize(cg.ip, cg.typeOf(ref));
    const m = try cg.memOf(ref);
    try cg.e.mov(.qword, .{ .reg = lo }, .{ .mem = m });
    try cg.loadBytes(hi, offsetMem(m, 8), size - 8);
}

fn setupParams(cg: *CodeGen) Error!void {
    const ip = cg.ip;
    if (cg.fn_ty.cc == .c) return cg.setupCParams();
    if (cg.fn_ty.cc == .x86_64_win) return cg.setupWinParams();
    const ir = cg.ir;
    const tags = ir.instructions.items(.tag);
    // The error return trace pointer arrives in rax; a function that
    // neither reads it nor calls passes it on drops it.
    const needs_trace = for (cg.ssa.values.items(.inst)) |inst| switch (tags[@backingInt(inst)]) {
        .call, .err_return_trace, .save_err_return_trace_index => break true,
        else => {},
    } else false;
    if (needs_trace) {
        cg.trace_slot = try cg.allocSlot(8, 8);
        try cg.e.mov(.qword, .{ .mem = Mem.at(.rbp, cg.trace_slot.?) }, .{ .reg = .rax });
    }
    const ret_ty = cg.fn_ty.return_type;
    if (cg.autoClass(ret_ty) == .memory) {
        const off = try cg.allocSlot(8, 8);
        try cg.e.mov(.qword, .{ .mem = Mem.at(.rbp, off) }, .{ .reg = .rdi });
        cg.ret_ptr_slot = off;
    }
    // `arg` instructions are at the start of the main body.
    var n: usize = 0;
    for (ir.mainBody()) |inst| {
        if (tags[@backingInt(inst)] != .arg) break;
        n += 1;
    }
    const args = ir.mainBody()[0..n];
    const tys, const locs = try cg.argScratch(n);
    for (args, tys) |inst, *ty| ty.* = ir.instructions.items(.data)[@backingInt(inst)].arg.ty;
    _ = cg.autoArgs(ret_ty, tys, locs);
    // Arguments that live in memory first, then the moves into registers,
    // which may overwrite argument registers.
    var moves: [6]struct { dst: Reg, src: Reg } = undefined;
    var n_moves: usize = 0;
    for (args, tys, locs) |inst, ty, l| {
        const size = Type.abiSize(ip, ty);
        const home = cg.homes[@backingInt(inst)];
        if (cg.live and cg.ssa.live.items(.uses)[@backingInt(inst)] == 0) continue;
        switch (l) {
            .none => {},
            .gpr => |r| if (home == .reg) {
                moves[n_moves] = .{ .dst = home.reg, .src = c_arg_regs[r] };
                n_moves += 1;
            } else try cg.storeBytes((try cg.resultMem(inst, ty)).?, c_arg_regs[r], size),
            .gpr_pair => |r| if (home == .regs) {
                moves[n_moves] = .{ .dst = home.regs.lo, .src = c_arg_regs[r] };
                moves[n_moves + 1] = .{ .dst = home.regs.hi, .src = c_arg_regs[r + 1] };
                n_moves += 2;
            } else {
                const m = (try cg.resultMem(inst, ty)).?;
                try cg.e.mov(.qword, .{ .mem = m }, .{ .reg = c_arg_regs[r] });
                try cg.storeBytes(offsetMem(m, 8), c_arg_regs[r + 1], size - 8);
            },
            .sse => |x| if (home == .xmm) {
                try cg.e.movups(.{ .reg = home.xmm }, .{ .reg = xmm_args[x] });
            } else try cg.storeXmm((try cg.resultMem(inst, ty)).?, xmm_args[x], size),
            // Loaded into a register after the moves (below).
            .stack => |off| if (home != .reg and home != .regs and home != .xmm) {
                cg.homes[@backingInt(inst)] = .{ .slot = 16 + @as(i32, @intCast(off)) };
            },
            // The pointer stays in the register the argument got; without
            // one, the value is copied in.
            .ref => |r| if (home == .reg) {
                moves[n_moves] = .{ .dst = home.reg, .src = c_arg_regs[r] };
                n_moves += 1;
                cg.homes[@backingInt(inst)] = .{ .ind = home.reg };
            } else try cg.copyArgIn((try cg.resultMem(inst, ty)).?, .{ .reg = c_arg_regs[r] }, size),
            .ref_stack => |off| if (home != .reg) {
                try cg.copyArgIn((try cg.resultMem(inst, ty)).?, .{ .mem = Mem.at(.rbp, 16 + @as(i32, @intCast(off))) }, size);
            },
        }
    }
    // A parallel move: each destination is written once its old value has
    // been read, and a cycle goes through r11.
    while (n_moves != 0) {
        const i = for (moves[0..n_moves], 0..) |mv, i| {
            const read = for (moves[0..n_moves]) |other| {
                if (other.src == mv.dst and other.dst != mv.dst) break true;
            } else false;
            if (!read) break i;
        } else blk: {
            const d = moves[0].dst;
            try cg.e.mov(.qword, .{ .reg = .r11 }, .{ .reg = d });
            for (moves[0..n_moves]) |*other| if (other.src == d) {
                other.src = .r11;
            };
            break :blk 0;
        };
        const mv = moves[i];
        if (mv.dst != mv.src) try cg.e.mov(.qword, .{ .reg = mv.dst }, .{ .reg = mv.src });
        n_moves -= 1;
        moves[i] = moves[n_moves];
    }
    for (args, tys, locs) |inst, ty, l| switch (l) {
        .stack => |off| switch (cg.homes[@backingInt(inst)]) {
            .reg => |r| try cg.loadMem(r, Mem.at(.rbp, 16 + @as(i32, @intCast(off))), ty),
            .regs => |p| {
                const m = Mem.at(.rbp, 16 + @as(i32, @intCast(off)));
                try cg.e.mov(.qword, .{ .reg = p.lo }, .{ .mem = m });
                try cg.e.mov(.qword, .{ .reg = p.hi }, .{ .mem = offsetMem(m, 8) });
            },
            .xmm => |x| try cg.loadXmm(x, memVal(ty, Mem.at(.rbp, 16 + @as(i32, @intCast(off))))),
            else => {},
        },
        .ref_stack => |off| switch (cg.homes[@backingInt(inst)]) {
            .reg => |r| {
                try cg.e.mov(.qword, .{ .reg = r }, .{ .mem = Mem.at(.rbp, 16 + @as(i32, @intCast(off))) });
                cg.homes[@backingInt(inst)] = .{ .ind = r };
            },
            else => {},
        },
        else => {},
    };
}

/// Copies a by-reference argument of `size` bytes from where `ptr` points
/// to `dst`, in the prologue, keeping the argument registers: rsi, rdi,
/// and rcx are saved in r10, r11, and rax, which are free there.
fn copyArgIn(cg: *CodeGen, dst: Mem, ptr: union(enum) { reg: Reg, mem: Mem }, size: u64) Error!void {
    const e = &cg.e;
    try e.mov(.qword, .{ .reg = .r10 }, .{ .reg = .rsi });
    try e.mov(.qword, .{ .reg = .r11 }, .{ .reg = .rdi });
    try e.mov(.qword, .{ .reg = .rax }, .{ .reg = .rcx });
    switch (ptr) {
        .reg => |r| {
            const src: Reg = switch (r) {
                .rsi => .r10,
                .rdi => .r11,
                .rcx => .rax,
                else => r,
            };
            try e.mov(.qword, .{ .reg = .rsi }, .{ .reg = src });
        },
        .mem => |m| try e.mov(.qword, .{ .reg = .rsi }, .{ .mem = m }),
    }
    try e.lea(.qword, .rdi, dst);
    try e.mov(.qword, .{ .reg = .rcx }, .{ .imm = @intCast(size) });
    try e.repMovsb();
    try e.mov(.qword, .{ .reg = .rsi }, .{ .reg = .r10 });
    try e.mov(.qword, .{ .reg = .rdi }, .{ .reg = .r11 });
    try e.mov(.qword, .{ .reg = .rcx }, .{ .reg = .rax });
}

pub fn sizeOf(bytes: u64) Size {
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

pub fn typeOf(cg: *CodeGen, ref: Ref) Index {
    return cg.ir.typeOf(ref, cg.ip);
}

pub fn locOf(cg: *CodeGen, ref: Ref) Error!Loc {
    if (ref.toIndex()) |inst| return switch (cg.homes[@backingInt(inst)]) {
        .none => .none,
        .reg => |r| .{ .reg = r },
        .regs => |p| .{ .mem = try cg.spillPair(inst, p) },
        .xmm => |x| .{ .mem = try cg.spillXmm(inst, x) },
        .deferred => .{ .mem = try cg.deferredMem(cg.ir.instructions.items(.data)[@backingInt(inst)].ty_op.operand) },
        .fused, .pair, .view => unreachable, // read only by their users
        .dead => unreachable,
        .slot => |off| .{ .mem = Mem.at(.rbp, off) },
        .ind => |r| .{ .mem = Mem.at(r, 0) },
        .frame_addr => |off| .{ .addr = Mem.at(.rbp, off) },
        .reg_addr => |a| .{ .addr = Mem.at(a.base, a.off) },
    };
    return cg.constLoc(ref.toInterned().?);
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
                const name = ip.stringSlice(ip.keyPayload(.extern_func, p.base.uav.val).name);
                _ = try cg.emit.requestCompilerRtExport(name);
                return .{ .mem = Mem.sym(try cg.emit.useExtern(name, false), 0) };
            }
            if (ptrToZeroBit(ip, val)) return .{ .imm = 0xaaaaaaaaaaaaaaaa };
            const t = try ptrTarget(cg.emit, val);
            // The address of extern data, or into it, is in its link slot.
            if (t.ext) |n| {
                const name = ip.stringSlice(n);
                _ = try cg.emit.requestCompilerRtExport(name);
                return .{ .mem = Mem.sym(try cg.emit.useExtern(try cg.emit.externSlotName(name, t.off), false), 0) };
            }
            return .{ .addr = Mem.sym(t.key, @intCast(t.off)) };
        },
        .opt => |o| if (Type.optionalReprIsPtr(ip, Type.childType(ip, ty))) {
            if (o.val == .none) return .{ .imm = 0 };
            return cg.constLoc(o.val);
        } else if (o.val == .none and cg.optInGpr(ty)) return .{ .imm = 0 },
        else => {},
    }
    return .{ .mem = Mem.sym(try cg.emit.uavKey(val, 0), 0) };
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

/// Loads a value of at most 8 bytes into `reg`, zero- or sign-extended to 64
/// bits by its type.
pub fn load(cg: *CodeGen, reg: Reg, ref: Ref) Error!void {
    const ty = cg.typeOf(ref);
    if (cg.xmmOf(ref)) |x| return cg.e.movFromXmm(sizeOf(Type.abiSize(cg.ip, ty)), .{ .reg = reg }, x);
    switch (try cg.locOf(ref)) {
        .xmm => unreachable, // `locOf` gives memory
        .none => try cg.e.mov(.dword, .{ .reg = reg }, .{ .imm = 0 }),
        .reg => |r| if (r != reg) try cg.e.mov(.qword, .{ .reg = reg }, .{ .reg = r }),
        .imm => |v| try cg.e.mov(.qword, .{ .reg = reg }, .{ .imm = @bitCast(v) }),
        .addr => |m| if (m.base == .reg and m.index == null and m.disp == 0) {
            if (m.base.reg != reg) try cg.e.mov(.qword, .{ .reg = reg }, .{ .reg = m.base.reg });
        } else try cg.e.lea(.qword, reg, m),
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

pub fn offsetMem(m: Mem, off: u64) Mem {
    var r = m;
    r.disp += @intCast(off);
    return r;
}

/// Copies the value `ref` (of `size` bytes) to `dst`. Uses rax and xmm0,
/// and for large values rsi, rdi, and rcx (`copyMem`); `dst` must not be
/// based on those.
fn copyTo(cg: *CodeGen, dst: Mem, ref: Ref) Error!void {
    const ty = cg.typeOf(ref);
    const size = Type.abiSize(cg.ip, ty);
    if (size == 0) return;
    if (cg.pairOf(ref)) |p| {
        try cg.e.mov(.qword, .{ .mem = dst }, .{ .reg = p.lo });
        return cg.e.mov(.qword, .{ .mem = offsetMem(dst, 8) }, .{ .reg = p.hi });
    }
    if (cg.xmmOf(ref)) |x| return cg.storeXmm(dst, x, size);
    // An error: its code, without the undefined payload, which may be
    // large (a constant `return error.X` of a big result).
    if (ref.toInterned()) |v| if (cg.ip.keyTag(v) == .error_union and !cg.passInRegs(ty)) {
        const eu = cg.ip.keyPayload(.error_union, v);
        if (eu.val == .err_name) {
            const layout = Type.errorUnionLayout(cg.ip, ty);
            try cg.loadError(.rax, eu.val.err_name);
            return cg.e.mov(errFieldSize(layout), .{ .mem = offsetMem(dst, layout.err_offset) }, .{ .reg = .rax });
        }
    };
    const loc = try cg.locOf(ref);
    switch (loc) {
        .xmm => unreachable, // `locOf` gives memory
        .none => {},
        .reg => |r| try cg.storeReg(dst, r, size),
        .mem => |src| {
            const tags = cg.ir.instructions.items(.tag);
            // An error: its code, without the undefined payload.
            if (ref.toIndex()) |i| if (tags[@backingInt(i)] == .wrap_errunion_err) {
                const layout = Type.errorUnionLayout(cg.ip, ty);
                return cg.copyMem(offsetMem(dst, layout.err_offset), offsetMem(src, layout.err_offset), errFieldSize(layout).bytes());
            };
            // A call's result was just stored by the callee 8 bytes at a
            // time, and a 16-byte load of two such stores cannot be
            // forwarded from them: it waits for both to retire.
            const just_stored = if (ref.toIndex()) |i| tags[@backingInt(i)] == .call else false;
            if (just_stored and size <= copy_inline_max) return cg.copyTail(dst, src, size);
            try cg.copyMem(dst, src, size);
        },
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

/// The largest copy `copyMem` makes with moves, without `rep movsb`,
/// which costs about as much as 30 moves to start.
const copy_inline_max = 256;

/// Copies `size` bytes. Uses rax and xmm0, which hold no value between
/// instructions (values live in xmm8-xmm15, and SSE arguments are loaded
/// after the copies a call makes), and above `copy_inline_max` bytes rsi,
/// rdi and rcx.
fn copyMem(cg: *CodeGen, dst: Mem, src: Mem, size: u64) Error!void {
    // A value already in place (`payload_region`).
    if (dst.base == .reg and src.base == .reg and dst.base.reg == .rbp and src.base.reg == .rbp and
        dst.index == null and src.index == null and dst.disp == src.disp) return;
    if (size >= 32 and size <= copy_inline_max) {
        var off: u64 = 0;
        while (size - off >= 16) : (off += 16) {
            try cg.e.movups(.{ .reg = .xmm0 }, .{ .mem = offsetMem(src, off) });
            try cg.e.movups(.{ .mem = offsetMem(dst, off) }, .{ .reg = .xmm0 });
        }
        return cg.copyTail(offsetMem(dst, off), offsetMem(src, off), size - off);
    }
    if (size > copy_inline_max) {
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

/// Above 128 bytes, `rep stosb` (upstream always fills undefined memory
/// with it); its callers allow rdi and rcx to be clobbered there (a store
/// of such a value is a clobber point, see `clobbers`).
fn fillMem(cg: *CodeGen, dst: Mem, size: u64, byte: u8) Error!void {
    if (size > 128) {
        try cg.e.lea(.qword, .rdi, dst);
        try cg.e.mov(.qword, .{ .reg = .rcx }, .{ .imm = @intCast(size) });
        try cg.e.mov(.dword, .{ .reg = .rax }, .{ .imm = byte });
        return cg.e.repStosb();
    }
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
pub fn memOf(cg: *CodeGen, ref: Ref) Error!Mem {
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

/// Stores value `inst`, which is in registers `p`, to its spill slot for
/// code that reads it from memory, and returns the slot. Values do not
/// change, so each read can store it again.
fn spillPair(cg: *CodeGen, inst: Inst.Index, p: Regs) Error!Mem {
    const gop = try cg.pair_spills.getOrPut(cg.gpa, @backingInt(inst));
    if (!gop.found_existing) gop.value_ptr.* = try cg.allocSlot(16, 8);
    const m = Mem.at(.rbp, gop.value_ptr.*);
    try cg.e.mov(.qword, .{ .mem = m }, .{ .reg = p.lo });
    try cg.e.mov(.qword, .{ .mem = offsetMem(m, 8) }, .{ .reg = p.hi });
    return m;
}

/// Stores value `inst`, which is in `r`, to its slot (`genSplit`).
fn spillReg(cg: *CodeGen, inst: Inst.Index, r: Reg) Error!Mem {
    const gop = try cg.pair_spills.getOrPut(cg.gpa, @backingInt(inst));
    if (!gop.found_existing) gop.value_ptr.* = try cg.allocSlot(8, 8);
    const m = Mem.at(.rbp, gop.value_ptr.*);
    try cg.e.mov(.qword, .{ .mem = m }, .{ .reg = r });
    return m;
}

/// Stores value `inst`, which is in `x`, to its spill slot for code that
/// reads it from memory, as `spillPair` does.
fn spillXmm(cg: *CodeGen, inst: Inst.Index, x: Encoder.Xmm) Error!Mem {
    const gop = try cg.pair_spills.getOrPut(cg.gpa, @backingInt(inst));
    const size = Type.abiSize(cg.ip, cg.heldType(inst));
    if (!gop.found_existing) gop.value_ptr.* = try cg.allocSlot(@max(size, 8), @max(size, 8));
    const m = Mem.at(.rbp, gop.value_ptr.*);
    try cg.storeXmm(m, x, size);
    return m;
}

/// The type of the value `inst`'s register holds: a promoted variable's
/// (an `alloc`) is its pointee.
fn heldType(cg: *CodeGen, inst: Inst.Index) Index {
    const ty = cg.ir.typeOfIndex(inst, cg.ip);
    if (cg.ir.instructions.items(.tag)[@backingInt(inst)] != .alloc) return ty;
    return Type.ptrInfo(cg.ip, ty).child;
}

/// The memory pointer `ptr` points to, with r11 as the base if `ptr` is
/// not in a register (`Home.deferred`).
fn deferredMem(cg: *CodeGen, ptr: Ref) Error!Mem {
    switch (try cg.locOf(ptr)) {
        .addr => |m| return m,
        .reg => |r| return Mem.at(r, 0),
        else => {
            try cg.load(.r11, ptr);
            return Mem.at(.r11, 0);
        },
    }
}

/// The register holding `ref` if it is a value in one (`Home.xmm`).
pub fn xmmOf(cg: *CodeGen, ref: Ref) ?Encoder.Xmm {
    const inst = ref.toIndex() orelse return null;
    return switch (cg.homes[@backingInt(inst)]) {
        .xmm => |x| x,
        else => null,
    };
}

/// The register holding `ref` if it is a value in two (`Home.regs`).
fn pairOf(cg: *CodeGen, ref: Ref) ?Regs {
    const inst = ref.toIndex() orelse return null;
    return switch (cg.homes[@backingInt(inst)]) {
        .regs => |p| p,
        else => null,
    };
}

/// Loads 16-byte value `ref` (`inPair`) into `d`: a parallel move from
/// the registers holding it, or two loads.
fn loadRegs(cg: *CodeGen, d: Regs, ref: Ref) Error!void {
    if (cg.pairOf(ref)) |p| {
        if (p.hi == d.lo) {
            if (p.lo == d.hi) return cg.e.xchg(.qword, .{ .reg = d.lo }, d.hi);
            try cg.e.mov(.qword, .{ .reg = d.hi }, .{ .reg = p.hi });
            if (p.lo != d.lo) try cg.e.mov(.qword, .{ .reg = d.lo }, .{ .reg = p.lo });
            return;
        }
        if (p.lo != d.lo) try cg.e.mov(.qword, .{ .reg = d.lo }, .{ .reg = p.lo });
        if (p.hi != d.hi) try cg.e.mov(.qword, .{ .reg = d.hi }, .{ .reg = p.hi });
        return;
    }
    const m = try cg.memOf(ref);
    try cg.e.mov(.qword, .{ .reg = d.lo }, .{ .mem = m });
    try cg.e.mov(.qword, .{ .reg = d.hi }, .{ .mem = offsetMem(m, 8) });
}

/// Whether `ty`'s values live in two general-purpose registers when they
/// get registers: slices, optional slices, and error unions with an
/// 8-byte aligned payload of up to 8 bytes (the error code in the low
/// eightbyte, the payload in the high one); all 16 bytes.
pub fn inPair(cg: *CodeGen, ty: Index) bool {
    const ip = cg.ip;
    return switch (Type.class(ip, ty)) {
        .pointer => Type.isSlice(ip, ty),
        .optional => blk: {
            const child = Type.childType(ip, ty);
            break :blk Type.class(ip, child) == .pointer and Type.isSlice(ip, child);
        },
        // The payload at offset 8 makes the error union 16 bytes.
        .error_union => blk: {
            const payload = ip.keyPayload(.error_union_type, ty).payload_type;
            break :blk Type.abiAlignment(ip, payload) == 8 and Type.abiSize(ip, payload) == 8;
        },
        else => false,
    };
}

/// Whether every value of integer type `src`, extended to 64 bits by its
/// signedness, is the same register contents as type `dst`'s.
fn intFits(src: Type.IntInfo, dst: Type.IntInfo) bool {
    if (src.signedness == dst.signedness) return src.bits <= dst.bits;
    return src.signedness == .unsigned and src.bits < dst.bits;
}

/// Truncates the 64-bit value in `reg` to integer type `ty` and extends it
/// back, so it is normalized.
pub fn normalize(cg: *CodeGen, reg: Reg, ty: Index) Error!void {
    if (!Type.isInt(cg.ip, ty)) return; // bools stay 0 or 1
    const info = Type.intInfo(cg.ip, ty);
    if (info.bits >= 64) return;
    switch (info.bits) {
        8, 16, 32 => |b| {
            const size = sizeOf(b / 8);
            return if (info.signedness == .signed)
                cg.e.movsx(.qword, reg, size, .{ .reg = reg })
            else
                cg.e.movzx(if (b == 32) .qword else .dword, reg, size, .{ .reg = reg });
        },
        else => {},
    }
    const shift: u8 = @intCast(64 - info.bits);
    try cg.e.shift(.shl, .qword, .{ .reg = reg }, shift);
    try cg.e.shift(if (info.signedness == .signed) .sar else .shr, .qword, .{ .reg = reg }, shift);
}

// ---------------------------------------------------------------------------
// Registers
//
// Values of scalar types (integers up to 64 bits, bools, pointers, error
// codes, optional pointers, error unions of up to 8 bytes) that the
// instructions below compute in a register get one from linear scan
// (`Ssa.allocate`), and slices, optional slices, and error unions with an
// 8-byte payload get two (`Home.regs`); so do promoted variables, whose
// loads and stores are moves, and block results, which each `br` writes.
// The rest, and those the allocator spills, live in slots as before. Every lowering, including the
// per-instruction code, uses only caller-saved registers as scratch, and
// calls preserve the callee-saved ones, so a callee-saved register holds a
// value across instructions and calls without constraints; the prologue
// saves the ones the function uses. The scalar lowerings use only rax,
// rcx, rdx, r10, and r11, so rsi, rdi, r8, and r9 also hold values whose
// intervals contain no instruction that may write them (`clobbers`).
// f32 and f64 values get xmm8-xmm15 (`float_regs`) under the same
// condition.
// A register holds its value extended to 64 bits, as `load` leaves it.
// Inline assembly names registers itself, so a function containing some
// keeps every value in memory.

/// The registers the allocator hands out: the callee-saved ones, in the
/// order the prologue saves them, then the caller-saved ones no lowering
/// uses as scratch except the clobbering ones (`clobbers`).
const alloc_regs = [_]Reg{ .rbx, .r12, .r13, .r14, .r15, .rsi, .rdi, .r8, .r9 };
const callee_saved: u32 = 0b11111;

/// A `Live.hint` for the value a `ret` returns that is computed in rax
/// (`planRegisters`), outside `alloc_regs`.
const hint_rax: u8 = 0xfd;

/// `r`'s index in `alloc_regs`, or `Ssa.no_reg`.
fn allocIndex(r: Reg) u8 {
    const i = std.mem.indexOfScalar(Reg, &alloc_regs, r) orelse return Ssa.no_reg;
    return @intCast(i);
}

/// The XMM registers the allocator hands out, after `alloc_regs`. Float
/// lowerings use xmm0 and xmm1 as scratch, and calls pass arguments in
/// xmm0-xmm7. All are caller-saved, so they hold only values whose
/// intervals contain no clobber point (`clobbers`): every lowering that
/// writes xmm8-xmm15 other than through its own result is one.
const float_regs = [_]Encoder.Xmm{ .xmm8, .xmm9, .xmm10, .xmm11, .xmm12, .xmm13, .xmm14, .xmm15 };

/// Whether value `inst`'s lowering may write rsi, rdi, r8, r9, or
/// xmm8-xmm15 (for `Ssa.liveness`). The scalar lowerings use only rax, rcx, rdx, r10,
/// and r11; calls, string instructions, and the C ABI use the others.
/// Also marks the values that want a register (`wantsReg`).
pub fn clobbers(cg: *CodeGen, inst: Inst.Index) bool {
    const ir = cg.ir;
    const data = ir.instructions.items(.data)[@backingInt(inst)];
    const tag = ir.instructions.items(.tag)[@backingInt(inst)];
    switch (tag) {
        // A block's result may get a register; the `br`s that write it are
        // moves. (`Ssa.plan` promotes variables.)
        .block => {
            const ty = data.ty_pl.ty;
            const class: RegClass = if (cg.has_asm) .none else if (cg.inGpr(ty) or cg.inGprBytes(ty)) .gpr else if (cg.inPair(ty)) .pair else if (cg.inFloat(ty)) .float else .none;
            if (class != .none) {
                const live = cg.emit.ssa.live.slice();
                live.items(.reg)[@backingInt(inst)] = class.want();
                live.items(.tie)[@backingInt(inst)] = Ssa.no_tie;
            }
            return false;
        },
        // A copy of a by-reference argument is its pointer, folded into
        // its users' addressing when the argument has a register.
        .alloc => {
            if (!cg.has_asm and cg.const_alias.count() != 0 and cg.const_alias.contains(@backingInt(inst))) {
                const live = cg.emit.ssa.live.slice();
                live.items(.reg)[@backingInt(inst)] = RegClass.gpr.want();
                live.items(.tie)[@backingInt(inst)] = Ssa.no_tie;
            }
            if (!cg.has_asm and cg.ref_alias.count() != 0 and cg.ref_alias.contains(@backingInt(inst))) {
                const live = cg.emit.ssa.live.slice();
                live.items(.reg)[@backingInt(inst)] = RegClass.gpr.want();
                live.items(.tie)[@backingInt(inst)] = Ssa.no_tie;
                const arg = cg.copy_of.get(@backingInt(inst)).?;
                if (live.items(.reg)[arg] == Ssa.want_reg) cg.addr_base[@backingInt(inst)] = arg;
            }
            return false;
        },
        .dbg_stmt, .dbg_inline_begin, .dbg_inline_end, .loop, .breakpoint => return false,
        // A frame address takes no register and emits nothing; nor does
        // an address its users fold into their addressing.
        .struct_field_ptr, .ptr_elem_ptr, .ptr_add => if (cg.frameFoldable(inst.toRef()) or cg.addrFoldable(inst)) return false,
        else => {},
    }
    const class: RegClass = if (cg.has_asm) .none else cg.wantsReg(inst);
    const want = class != .none;
    if (want) {
        const live = cg.emit.ssa.live.slice();
        live.items(.reg)[@backingInt(inst)] = class.want();
        live.items(.tie)[@backingInt(inst)] = if (class == .pair) Ssa.no_tie else cg.tiedOperand(inst);
    }
    return switch (tag) {
        .arg, .ret_addr, .frame_addr, .extern_ptr, .extern_pcrel, .err_return_trace, .save_err_return_trace_index, .set_err_return_trace => false,
        // Local- and general-dynamic TLS call `__tls_get_addr`.
        .tls_ptr, .extern_tls => cg.emit.pic == .pic,
        .add_with_overflow, .sub_with_overflow, .mul_with_overflow => !cg.inGpr(cg.typeOf(ir.extraData(Ir.Bin, data.ty_pl.payload).data.lhs)),
        // A value in an XMM register is stored with one instruction; one
        // in memory is copied through rax and xmm0 up to
        // `copy_inline_max` bytes (`copyMem`), and filled up to 128
        // (`fillMem`).
        .store => store: {
            const ty = cg.typeOf(data.bin_op.rhs);
            if (cg.passInRegs(ty) or cg.inFloat(ty)) break :store false;
            const size = Type.abiSize(cg.ip, ty);
            const undef = if (data.bin_op.rhs.toInterned()) |v| cg.ip.keyTag(v) == .undef else false;
            break :store size > @as(u64, if (undef) 128 else copy_inline_max);
        },
        // A value in memory is copied to its slot (`copyMem`).
        .load => !want and Type.abiSize(cg.ip, data.ty_op.ty) > copy_inline_max,
        .call, .atomic_rmw => true,
        // Its fields are copied through rax.
        .aggregate_init => switch (cg.ip.keyTag(data.ty_pl.ty)) {
            .struct_type, .tuple_type => Type.abiSize(cg.ip, data.ty_pl.ty) > 128,
            else => !want and !vector.lowers(cg, inst),
        },
        else => !want and !vector.lowers(cg, inst),
    };
}

/// Whether block `block`'s terminator may write rsi, rdi, r8, or r9: a
/// `br` copying a large result, a switch on a wide integer, or a return
/// through memory.
pub fn termClobbers(cg: *CodeGen, block: Ssa.Block.Index) bool {
    const ir = cg.ir;
    const term = cg.ssa.blocks.items[@backingInt(block)].term;
    const data = ir.instructions.items(.data)[@backingInt(term.inst)];
    return switch (term.tag) {
        .jump => ir.instructions.items(.tag)[@backingInt(term.inst)] == .br and data.br.operand != Ref.void_value and
            Type.abiSize(cg.ip, ir.typeOfIndex(data.br.block_inst, cg.ip)) > 128,
        .switch_br => cg.isWideInt(cg.typeOf(data.pl_op.operand)),
        .ret => !cg.inGpr(cg.fn_ty.return_type) and !cg.inFloat(cg.fn_ty.return_type),
        .branch, .fallthrough, .noreturn, .unreach => false,
    };
}

fn planRegisters(cg: *CodeGen) Error!void {
    if (cg.fn_ty.cc == .naked) return;
    try cg.planCopies();
    const f = &cg.emit.ssa;
    const ir = cg.ir;
    try f.live.resize(cg.gpa, ir.instructions.len);
    const live = f.live.slice();
    const reg = live.items(.reg);
    @memset(reg, Ssa.no_reg);
    cg.has_asm = f.has_asm;
    // `clobbers` marks the values that want a register.
    try f.liveness(cg.gpa, ir, cg);
    cg.live = true;
    if (!cg.has_asm) try cg.exemptArgs();
    try f.plan(cg.gpa, ir, cg.ip, cg);
    const fate = live.items(.fate);
    if (cg.has_asm) {
        for (f.values.items(.inst)) |inst| {
            if (fate[@backingInt(inst)] == .dead) cg.homes[@backingInt(inst)] = .dead;
        }
        // No value gets a register, but a `{reg}` operand that names a
        // callee-saved register (cpuid's `={ebx}`) or a clobber of one
        // (zio's context switch) writes it, so the prologue saves it.
        comptime for (Ir.Asm.callee_saved_names, alloc_regs[0..@popCount(callee_saved)]) |name, r| {
            std.debug.assert(std.mem.eql(u8, name, @tagName(r)));
        };
        for (f.values.items(.inst)) |inst| {
            if (ir.instructions.items(.tag)[@backingInt(inst)] != .assembly) continue;
            const extra = ir.extraData(Ir.Asm, ir.instructions.items(.data)[@backingInt(inst)].ty_pl.payload);
            cg.saved |= extra.data.callee_saved_clobbers;
            var i = extra.end;
            for (0..extra.data.outputs_len + extra.data.inputs_len) |_| {
                const op = ir.extraData(Ir.Asm.Operand, i).data;
                i += 3;
                const c = asmAlternative(std.mem.trimStart(u8, cg.ip.stringSlice(op.constraint), "=+"));
                const r = parseReg(regConstraint(c) orelse continue) orelse continue;
                for (alloc_regs[0..@popCount(callee_saved)], 0..) |saved, bit| {
                    if (saved == r.reg) cg.saved |= @as(u32, 1) << @intCast(bit);
                }
            }
        }
        return;
    }
    try cg.planDeferred();
    try cg.planRotates();
    try cg.planMulWide();
    @memset(live.items(.hint), .{ Ssa.no_reg, Ssa.no_reg });
    for (cg.arg_hints.items) |h| live.items(.hint)[h.v][0] = h.r;
    if (cg.fn_ty.cc == .auto) {
        // Arguments prefer the registers they arrive in, which saves
        // their moves at the entry.
        const tags = ir.instructions.items(.tag);
        var n: usize = 0;
        for (ir.mainBody()) |inst| {
            if (tags[@backingInt(inst)] != .arg) break;
            n += 1;
        }
        const args = ir.mainBody()[0..n];
        const tys, const locs = try cg.argScratch(n);
        for (args, tys) |inst, *ty| ty.* = ir.instructions.items(.data)[@backingInt(inst)].arg.ty;
        _ = cg.autoArgs(cg.fn_ty.return_type, tys, locs);
        const hint = live.items(.hint);
        for (args, locs) |inst, l| switch (l) {
            .gpr => |r| hint[@backingInt(inst)][0] = allocIndex(c_arg_regs[r]),
            .ref => |r| hint[@backingInt(inst)] = .{ allocIndex(c_arg_regs[r]), Ssa.hint_pinned },
            .ref_stack => hint[@backingInt(inst)][1] = Ssa.hint_pinned,
            .gpr_pair => |r| hint[@backingInt(inst)] = .{ allocIndex(c_arg_regs[r]), allocIndex(c_arg_regs[r + 1]) },
            else => {},
        };
    }
    if (cg.fn_ty.cc == .auto and cg.autoClass(cg.fn_ty.return_type) == .gpr and cg.passInRegs(cg.fn_ty.return_type)) {
        // A value only its block's `ret` reads, computed last, is
        // computed in rax, where it is returned.
        const tags = ir.instructions.items(.tag);
        const hint = live.items(.hint);
        for (f.layout.items) |block| {
            const b = f.blocks.items[@backingInt(block)];
            if (b.term.tag != .ret) continue;
            const w = ir.instructions.items(.data)[@backingInt(b.term.inst)].un_op.toIndex() orelse continue;
            const last = cg.lastValue(block);
            const wi = @backingInt(w);
            if (reg[wi] != Ssa.want_reg or fate[wi] != .normal or live.items(.uses)[wi] != 1) continue;
            if (last == w) {
                reg[wi] = Ssa.no_reg;
                hint[wi][0] = hint_rax;
            } else if (tags[wi] == .block and last == null and f.targets.items[wi] == block) {
                // A block result returned by its own exit, a block with
                // nothing else, is written by the `br`s right before they
                // jump to it. (Returned by a later block, it lives across
                // what comes between.)
                reg[wi] = Ssa.no_reg;
                hint[wi][0] = hint_rax;
            }
        }
        // So is a value only a `br` to such a block reads, computed last.
        for (f.layout.items) |block| {
            const b = f.blocks.items[@backingInt(block)];
            if (b.term.tag != .jump or tags[@backingInt(b.term.inst)] != .br) continue;
            const br = ir.instructions.items(.data)[@backingInt(b.term.inst)].br;
            if (hint[@backingInt(br.block_inst)][0] != hint_rax) continue;
            const w = br.operand.toIndex() orelse continue;
            const wi = @backingInt(w);
            if (reg[wi] != Ssa.want_reg or fate[wi] != .normal or live.items(.uses)[wi] != 1 or tags[wi] == .block) continue;
            if (cg.lastValue(block) != w) continue;
            reg[wi] = Ssa.no_reg;
            hint[wi][0] = hint_rax;
        }
    }
    try cg.planSplits();
    // A by-reference argument's register holds a pointer, which `genSplit`
    // would spill as the value.
    if (cg.fn_ty.cc == .auto) for (ir.mainBody()) |inst| {
        if (ir.instructions.items(.tag)[@backingInt(inst)] != .arg) break;
        if (cg.autoClass(ir.instructions.items(.data)[@backingInt(inst)].arg.ty) == .memory) cg.split.unset(@backingInt(inst));
    };
    var aliases = cg.ref_alias.keyIterator();
    while (aliases.next()) |a| cg.split.unset(a.*);
    var consts = cg.const_alias.keyIterator();
    while (consts.next()) |a| cg.split.unset(a.*);
    cg.saved = f.allocate(alloc_regs.len, float_regs.len, callee_saved, cg.addr_base, &cg.split) & callee_saved;
    const reg2 = live.items(.reg2);
    for (f.values.items(.inst)) |inst| {
        const i = @backingInt(inst);
        switch (fate[i]) {
            .normal => {
                const r = reg[i];
                if (r == Ssa.no_reg or r == Ssa.folded) {
                    if (live.items(.hint)[i][0] == hint_rax) cg.homes[i] = .{ .reg = .rax };
                    continue;
                }
                cg.homes[i] = if (r >= alloc_regs.len) .{ .xmm = float_regs[r - alloc_regs.len] } else if (reg2[i] != Ssa.no_reg) .{ .regs = .{ .lo = alloc_regs[r], .hi = alloc_regs[reg2[i]] } } else .{ .reg = alloc_regs[r] };
            },
            .dead => cg.homes[i] = .dead,
            .fused => cg.homes[i] = .fused,
            .pair => cg.homes[i] = .pair,
        }
        // A value computed or loaded in a split variable's register
        // (`Live.share`) that kept it when the variable was evicted later
        // has no variable to be saved with: it is saved itself.
        const sh = live.items(.share)[i];
        const orphan = sh != Ssa.no_tie and reg[i] < alloc_regs.len + float_regs.len and reg[sh] != reg[i];
        if (!cg.split.isSet(i) and !orphan) continue;
        const keep = live.items(.crosses)[i] and switch (cg.homes[i]) {
            .reg => |r| callee_saved >> @intCast(allocIndex(r)) & 1 == 0,
            .xmm => true,
            else => false,
        };
        if (keep) try cg.split_vals.append(cg.gpa, .{ .v = i, .of = i }) else cg.split.unset(i);
    }
    if (cg.split_vals.items.len == 0) return;
    // A load that shares a promoted variable's register, or one forwarded
    // from a value (whose home it takes when emitted), reads the same
    // register.
    const share = live.items(.share);
    const fwd = live.items(.fwd);
    for (f.values.items(.inst)) |inst| {
        const i = @backingInt(inst);
        if (fate[i] != .normal) continue;
        const of = if (share[i] != Ssa.no_tie and reg[share[i]] == reg[i]) share[i] else if (fwd[i] != Ssa.no_tie) fwd[i] else continue;
        if (cg.split.isSet(of)) try cg.split_vals.append(cg.gpa, .{ .v = i, .of = of });
    }
}

/// The last value of `block` that is not a debug marker, if any.
fn lastValue(cg: *CodeGen, block: Ssa.Block.Index) ?Inst.Index {
    const values = cg.ssa.blockInsts(block);
    const tags = cg.ir.instructions.items(.tag);
    var k = values.len;
    while (k > 0) {
        k -= 1;
        switch (tags[@backingInt(values[k])]) {
            .dbg_stmt, .dbg_inline_begin, .dbg_inline_end => {},
            else => return values[k],
        }
    }
    return null;
}

/// A value in a register whose interval ends at an `.auto` call that
/// passes it in a register, with every argument in a register, does not
/// cross that call if it crosses no other clobber point: `call` reads the
/// arguments before anything else writes the registers that do not
/// survive it, ordering their moves (`loadArgRegs`). Such an argument
/// prefers the register it is passed in (`arg_hints`). For `Ssa.plan`,
/// which reads `crosses`.
fn exemptArgs(cg: *CodeGen) Error!void {
    const ir = cg.ir;
    const ip = cg.ip;
    const f = cg.ssa;
    const live = f.live.slice();
    const reg = live.items(.reg);
    const def = live.items(.def);
    const end = live.items(.end);
    const crosses = live.items(.crosses);
    const cl = f.clobbers.items;
    const tags = ir.instructions.items(.tag);
    cg.arg_hints.clearRetainingCapacity();
    for (f.values.items(.inst)) |inst| {
        if (tags[@backingInt(inst)] != .call) continue;
        const data = ir.instructions.items(.data)[@backingInt(inst)];
        const callee_fn_ty = cg.typeOf(data.pl_op.operand);
        const callee_ty = ip.keyPayload(.func_type, if (Type.class(ip, callee_fn_ty) == .pointer) Type.ptrInfo(ip, callee_fn_ty).child else callee_fn_ty);
        if (callee_ty.cc != .auto) continue;
        const extra = ir.extraData(Ir.Call, data.pl_op.payload);
        const args = ir.refSlice(extra.end, extra.data.args_len);
        const tys, const locs = try cg.argScratch(args.len);
        for (args, tys) |arg, *ty| ty.* = cg.typeOf(arg);
        if (cg.autoArgs(extra.data.ret_ty, tys, locs) != 0) continue;
        // A by-reference argument other than a constant may be copied to
        // the outgoing area, which writes rsi, rdi, and rcx.
        if (for (args, locs) |arg, l| {
            if (l == .ref and arg.toInterned() == null) break true;
        } else false) continue;
        const q = def[@backingInt(inst)];
        const own: [2]u32 = .{ cl[q][0] - cl[q - 1][0], cl[q][1] - cl[q - 1][1] };
        for (args, tys, locs) |arg, ty, l| {
            const v = @backingInt(arg.toIndex() orelse continue);
            if (arg == data.pl_op.operand or end[v] != q or !crosses[v]) continue;
            switch (l) {
                .gpr => if (reg[v] != Ssa.want_reg or !cg.passInRegs(ty)) continue,
                .sse => if (reg[v] != Ssa.want_float) continue,
                else => continue,
            }
            if (cl[q][0] - own[0] != cl[def[v]][0]) continue;
            try cg.arg_hints.append(cg.gpa, .{ .v = v, .r = if (l == .gpr) allocIndex(c_arg_regs[l.gpr]) else Ssa.no_reg });
        }
    }
    if (cg.arg_hints.items.len == 0) return;
    // A use in a block that does not continue crosses the clobber points
    // before it there (`Ssa.liveness`); the call itself does not count.
    const Uses = struct {
        cg: *CodeGen,
        start: u32,
        pos: u32,
        own: u32,
        pub fn use(c: @This(), ref: Ref) void {
            const v = @backingInt(ref.toIndex() orelse return);
            const l = c.cg.ssa.live.slice();
            if (l.items(.reg2)[v] != 0) return;
            const cl2 = c.cg.ssa.clobbers.items;
            const at = if (l.items(.end)[v] == c.pos) cl2[c.pos][1] - c.own else cl2[c.pos][1];
            if (at != cl2[@max(c.start, l.items(.def)[v])][1]) l.items(.reg2)[v] = 1;
        }
    };
    // `reg2` is free until `Ssa.plan`: 0 marks a candidate, 1 one that
    // crosses a clobber point in a block that does not continue.
    const reg2 = live.items(.reg2);
    @memset(reg2, Ssa.no_reg);
    for (cg.arg_hints.items) |h| reg2[h.v] = 0;
    for (f.layout.items) |block| {
        const b = f.blocks.items[@backingInt(block)];
        if (!Ssa.deadEnd(b.term.tag)) continue;
        for (f.blockInsts(block), b.start..) |inst, idx| {
            const q = Ssa.valuePos(idx);
            Ssa.forEachOperand(ir, inst, Uses{ .cg = cg, .start = 2 * b.start + 1, .pos = q, .own = cl[q][1] - cl[q - 1][1] });
        }
    }
    var n: usize = 0;
    for (cg.arg_hints.items) |h| {
        if (reg2[h.v] != 0) continue;
        crosses[h.v] = false;
        if (h.r == Ssa.no_reg) continue;
        cg.arg_hints.items[n] = h;
        n += 1;
    }
    cg.arg_hints.shrinkRetainingCapacity(n);
}

/// Loads the `.auto` arguments `args` that `locs` puts in general-purpose
/// registers. An argument may be in one of those registers
/// (`exemptArgs`), so each register is written once no other argument
/// left to load reads it; a cycle of register moves is broken with
/// `xchg`.
fn loadArgRegs(cg: *CodeGen, args: []const Ref, tys: []const Index, locs: []const AutoArg, refs: []const ArgRef) Error!void {
    // `src`/`src_hi`: registers holding the value; `reads`: registers an
    // address the value is computed from is based on (an argument
    // register that another move may write first).
    // `saved`: where a value routed out of a cycle waits (below).
    const Move = struct { arg: Ref, ty: Index, lo: Reg, hi: ?Reg, src: ?Reg, src_hi: ?Reg = null, addr: ?Mem = null, reads: ?Reg = null, saved: ?Mem = null };
    var moves: [6]Move = undefined;
    var n: usize = 0;
    for (args, tys, locs, refs) |arg, ty, l, ref| switch (l) {
        .ref => |r| {
            moves[n] = switch (ref) {
                .reg => |x| .{ .arg = arg, .ty = ty, .lo = c_arg_regs[r], .hi = null, .src = x },
                .addr => |m| .{ .arg = arg, .ty = ty, .lo = c_arg_regs[r], .hi = null, .src = null, .addr = m },
            };
            n += 1;
        },
        .gpr => |r| {
            moves[n] = .{ .arg = arg, .ty = ty, .lo = c_arg_regs[r], .hi = null, .src = null };
            if (arg.toIndex()) |v| switch (cg.homes[@backingInt(v)]) {
                .reg => |x| moves[n].src = x,
                .reg_addr => |ra| moves[n].reads = ra.base,
                else => {},
            };
            n += 1;
        },
        .gpr_pair => |r| {
            moves[n] = .{ .arg = arg, .ty = ty, .lo = c_arg_regs[r], .hi = c_arg_regs[r + 1], .src = null };
            if (cg.pairOf(arg)) |p| {
                moves[n].src = p.lo;
                moves[n].src_hi = p.hi;
            } else if (arg.toIndex()) |v| if (cg.homes[@backingInt(v)] == .deferred) {
                const ptr = cg.ir.instructions.items(.data)[@backingInt(v)].ty_op.operand;
                if (ptr.toIndex()) |pi| switch (cg.homes[@backingInt(pi)]) {
                    .reg => |x| moves[n].reads = x,
                    .reg_addr => |ra| moves[n].reads = ra.base,
                    else => {},
                };
            };
            n += 1;
        },
        else => {},
    };
    while (n > 0) {
        const k = for (moves[0..n], 0..) |m, k| {
            const blocked = for (moves[0..n], 0..) |o, j| {
                if (j == k) continue;
                const read = [_]?Reg{ o.src, o.src_hi, o.reads };
                if (std.mem.indexOfScalar(?Reg, &read, m.lo) != null) break true;
                if (m.hi != null and std.mem.indexOfScalar(?Reg, &read, m.hi) != null) break true;
            } else false;
            if (!blocked) break k;
        } else {
            // Every move left writes a register another one reads, so
            // some moves form a cycle. Compute a value read through an
            // address first, as its lowering reads the base from the
            // value's home, and keep it in a slot (loading the others may
            // use r11); else swap a register move into place (what read
            // either register reads the other).
            const routed = for (moves[0..n]) |m| {
                if (m.reads != null) break true;
            } else false;
            const swap: ?usize = if (routed) null else for (moves[0..n], 0..) |m, k| {
                if (m.src != null and m.src_hi == null) break k;
            } else null;
            if (swap) |k| {
                const m = moves[k];
                try cg.e.xchg(.qword, .{ .reg = m.lo }, m.src.?);
                moves[k] = moves[n - 1];
                n -= 1;
                for (moves[0..n]) |*o| for ([_]*?Reg{ &o.src, &o.src_hi, &o.reads }) |x| {
                    if (x.* == m.lo) x.* = m.src else if (x.* == m.src) x.* = m.lo;
                };
                continue;
            }
            const m = &moves[
                for (moves[0..n], 0..) |o, k| {
                    if (o.reads != null) break k;
                } else 0
            ];
            const slot = Mem.at(.rbp, try cg.allocSlot(16, 8));
            if (m.hi) |_| {
                try cg.loadPair(.r10, .rax, m.arg);
                try cg.e.mov(.qword, .{ .mem = offsetMem(slot, 8) }, .{ .reg = .rax });
            } else try cg.loadGpr(.r10, m.arg, m.ty);
            try cg.e.mov(.qword, .{ .mem = slot }, .{ .reg = .r10 });
            m.saved = slot;
            m.reads = null;
            continue;
        };
        const m = moves[k];
        if (m.saved) |slot| {
            try cg.e.mov(.qword, .{ .reg = m.lo }, .{ .mem = slot });
            if (m.hi) |hi| try cg.e.mov(.qword, .{ .reg = hi }, .{ .mem = offsetMem(slot, 8) });
        } else if (m.hi) |hi| {
            if (m.src_hi) |sh| {
                if (m.lo != m.src.?) try cg.e.mov(.qword, .{ .reg = m.lo }, .{ .reg = m.src.? });
                if (hi != sh) try cg.e.mov(.qword, .{ .reg = hi }, .{ .reg = sh });
            } else try cg.loadPair(m.lo, hi, m.arg);
        } else if (m.src) |r| {
            if (r != m.lo) try cg.e.mov(.qword, .{ .reg = m.lo }, .{ .reg = r });
        } else if (m.addr) |a| {
            try cg.e.lea(.qword, m.lo, a);
        } else try cg.loadGpr(m.lo, m.arg, m.ty);
        moves[k] = moves[n - 1];
        n -= 1;
    }
}

/// Marks in `split` the values that may cross clobber points in a
/// register that does not survive them, saved to their slot before each
/// and reloaded after it (`genSplit`), when no surviving register is
/// free: single registers, crossing no clobbering terminator (which would
/// need the reload in its successors), no base of an address folded into
/// its users (whose register the clobbering value may overwrite before
/// reading them), and whose clobber points, two moves each, cost less
/// than reading their uses from memory, each weighted by 8 per loop
/// around it. Loads sharing a promoted variable's register ride on the
/// variable. Nothing is marked when the surviving registers fit every
/// crossing value.
fn planSplits(cg: *CodeGen) Error!void {
    const f = cg.ssa;
    const gpa = cg.gpa;
    const live = f.live.slice();
    const reg = live.items(.reg);
    const def = live.items(.def);
    const end = live.items(.end);
    const crosses = live.items(.crosses);
    const cl = f.clobbers.items;
    try cg.split.resize(gpa, cg.ir.instructions.len, false);
    cg.split.unsetAll();
    var n_gpr: u32 = 0;
    var n_float: u32 = 0;
    for (f.values.items(.inst)) |inst| {
        const i = @backingInt(inst);
        if (!crosses[i] or live.items(.fate)[i] != .normal) continue;
        if (reg[i] == Ssa.want_reg) n_gpr += 1;
        if (reg[i] == Ssa.want_float) n_float += 1;
    }
    if (n_gpr <= @popCount(callee_saved) and n_float == 0) return;
    // Loop depths, by block; parents come before their loops.
    const depth = try gpa.alloc(u8, f.loops.items.len);
    defer gpa.free(depth);
    for (f.loops.items, depth) |l, *d| d.* = if (l.parent == Ssa.no_loop) 1 else @min(depth[l.parent] + 1, 6);
    const Weights = struct {
        uses: []u64,
        w: u64 = 0,
        pub fn use(c: *@This(), ref: Ref) void {
            if (ref.toIndex()) |x| c.uses[@backingInt(x)] += c.w;
        }
    };
    var ws: Weights = .{ .uses = try gpa.alloc(u64, cg.ir.instructions.len) };
    defer gpa.free(ws.uses);
    @memset(ws.uses, 0);
    // Prefix sums of the clobber points' weights by position, as
    // `Ssa.Func.clobbers` counts them.
    const wcl = try gpa.alloc(u64, cl.len);
    defer gpa.free(wcl);
    wcl[0] = 0;
    var terms: std.ArrayList(u32) = .empty;
    defer terms.deinit(gpa);
    const datas = cg.ir.instructions.items(.data);
    for (f.layout.items) |block| {
        const b = f.blocks.items[@backingInt(block)];
        const lp = f.block_loop.items[@backingInt(block)];
        ws.w = @as(u64, 1) << @intCast(3 * @as(u32, if (lp == Ssa.no_loop) 0 else depth[lp]));
        for (b.start..b.start + b.len + 1) |idx| {
            const q = Ssa.valuePos(idx) - 1;
            wcl[q] = wcl[q - 1] + if (cl[q][0] != cl[q - 1][0]) ws.w else 0;
            if (idx == b.start + b.len) break;
            wcl[q + 1] = wcl[q] + if (cl[q + 1][0] != cl[q][0]) ws.w else 0;
            Ssa.forEachOperand(cg.ir, f.values.items(.inst)[idx], &ws);
        }
        const q = 2 * (b.start + b.len) + 1;
        if (!std.meta.eql(cl[q], cl[q - 1])) try terms.append(gpa, q);
        const t = datas[@backingInt(b.term.inst)];
        switch (b.term.tag) {
            .jump => if (cg.ir.instructions.items(.tag)[@backingInt(b.term.inst)] == .br) ws.use(t.br.operand),
            .branch, .switch_br => ws.use(t.pl_op.operand),
            .ret => ws.use(t.un_op),
            .fallthrough, .noreturn, .unreach => {},
        }
        wcl[q + 1] = wcl[q];
    }
    var any = false;
    for (f.values.items(.inst)) |inst| {
        const i = @backingInt(inst);
        if (!crosses[i] or live.items(.fate)[i] != .normal or live.items(.share)[i] != Ssa.no_tie) continue;
        if (reg[i] != Ssa.want_reg and reg[i] != Ssa.want_float) continue;
        if (2 * (wcl[end[i]] - wcl[def[i]]) > ws.uses[i] + 1) continue;
        const k = std.sort.lowerBound(u32, terms.items, def[i] + 1, orderU32);
        if (k < terms.items.len and terms.items[k] <= end[i]) continue;
        cg.split.set(i);
        any = true;
    }
    if (!any) return;
    for (cg.addr_base) |b| if (b != no_base) cg.split.unset(b);
}

fn orderU32(a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

/// Emits value `inst`, at position `q`, which may clobber the registers
/// that do not survive calls, saving the values in `split_vals` whose
/// intervals contain it: each is stored to its slot, read from there by
/// `inst`, and reloaded after it unless this was its last use or `inst`
/// does not return.
fn genSplit(cg: *CodeGen, inst: Inst.Index, q: u32) Error!void {
    const live = cg.ssa.live.slice();
    const def = live.items(.def);
    const end = live.items(.end);
    cg.split_now.clearRetainingCapacity();
    const tags = cg.ir.instructions.items(.tag);
    for (cg.split_vals.items) |*sv| {
        const v = sv.v;
        if (def[v] >= q or end[v] < q) continue;
        const home = cg.homes[v];
        if (sv.of != v) {
            // Once emitted, it holds the register of its value, which
            // comes first in `split_vals`.
            const of = for (cg.split_now.items) |o| {
                if (o.v == sv.of) break o;
            } else continue;
            if (!std.meta.eql(home, of.home)) continue;
            cg.homes[v] = cg.homes[sv.of];
            try cg.split_now.append(cg.gpa, .{ .v = v, .home = home, .reload = false });
            continue;
        }
        const fixed = tags[v] != .alloc and tags[v] != .block;
        const m: Mem = if (fixed and sv.stored == cg.cur_block) .at(.rbp, cg.pair_spills.get(v).?) else switch (home) {
            .reg => |r| try cg.spillReg(@fromBackingInt(v), r),
            .xmm => |x| try cg.spillXmm(@fromBackingInt(v), x),
            else => continue,
        };
        if (fixed) sv.stored = cg.cur_block;
        cg.homes[v] = .{ .slot = m.disp };
        try cg.split_now.append(cg.gpa, .{ .v = v, .home = home, .reload = end[v] != q });
    }
    try cg.genInst(inst);
    const returns = cg.ir.typeOfIndex(inst, cg.ip) != .noreturn_type;
    // A result computed in a variable's register (`Live.share`) is the
    // variable's new value.
    const result = cg.homes[@backingInt(inst)];
    for (cg.split_now.items) |s| {
        cg.homes[s.v] = s.home;
        if (!s.reload or !returns or std.meta.eql(s.home, result)) continue;
        const m = Mem.at(.rbp, cg.pair_spills.get(s.v).?);
        switch (s.home) {
            .reg => |r| try cg.e.mov(.qword, .{ .reg = r }, .{ .mem = m }),
            .xmm => |x| try cg.loadXmm(x, memVal(cg.heldType(@fromBackingInt(s.v)), m)),
            else => unreachable,
        }
    }
}

/// Copy elision decided from the IR before liveness (step 2 of the
/// optimizing backend's successors in docs/slop/architecture.md):
/// - Return value: in a function that returns through memory, an `alloc`
///   of the result type whose load every `ret` returns (the load being
///   the last value of the `ret`'s block, so nothing else reads it) is the
///   result's memory: its home is the pointer the caller passed, and the
///   load and the copy at the `ret` go (`rvo_alloc`). The caller's result
///   memory is a slot of its own, which nothing else can reach.
/// - Initializers: a `*const` alloc stored to once, with a value that
///   always lives in memory, is that memory (`copy_of`) if the value is
///   in place when the alloc is emitted; its slot is not shared
///   (`copy_private`), and values do not change, so the memory holds the
///   initializer for as long as the alloc's address is used. A value
///   initializes at most one alloc, so allocs keep distinct addresses.
fn planCopies(cg: *CodeGen) Error!void {
    const ir = cg.ir;
    const ip = cg.ip;
    const f = cg.ssa;
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    const ret_ty = cg.fn_ty.return_type;
    if (cg.fn_ty.cc == .auto and cg.autoClass(ret_ty) == .memory) rvo: {
        var rvo: ?Inst.Index = null;
        for (f.layout.items) |block| {
            const b = f.blocks.items[@backingInt(block)];
            if (b.term.tag != .ret) continue;
            // A constant is copied to the result's memory as usual.
            const l = datas[@backingInt(b.term.inst)].un_op.toIndex() orelse continue;
            const last: ?Inst.Index = for (0..b.len) |k| {
                const v = f.blockInsts(block)[b.len - 1 - k];
                if (tags[@backingInt(v)] != .dbg_stmt) break v;
            } else null;
            // An error in a slot of its own is copied as usual: it does not
            // overlap the result's memory.
            if (tags[@backingInt(l)] == .wrap_errunion_err) continue;
            if (tags[@backingInt(l)] != .load) break :rvo;
            const a = datas[@backingInt(l)].ty_op.operand.toIndex() orelse break :rvo;
            if (tags[@backingInt(a)] != .alloc or datas[@backingInt(a)].ty == .none) break :rvo;
            const a_ty = datas[@backingInt(a)].ty;
            // A `*const` one is forwarded instead (`Ssa.plan`).
            const flags = Type.ptrInfo(ip, a_ty).flags;
            if (Type.ptrInfo(ip, a_ty).child != ret_ty or flags.is_volatile or flags.is_const) break :rvo;
            if (cg.allocAlignment(a_ty) > @min(Type.abiAlignment(ip, ret_ty), 16)) break :rvo;
            if (rvo != null and rvo.? != a) break :rvo;
            if (last != l and !cg.rvoEarlyLoad(l, a)) break :rvo;
            rvo = a;
        }
        const a = rvo orelse break :rvo;
        cg.rvo_alloc = a;
        for (f.layout.items) |block| {
            const b = f.blocks.items[@backingInt(block)];
            if (b.term.tag != .ret) continue;
            const l = datas[@backingInt(b.term.inst)].un_op.toIndex() orelse continue;
            if (tags[@backingInt(l)] != .load) continue;
            // A load read before its block (an error union's check for
            // the error return trace) reads the result's memory.
            const last: ?Inst.Index = for (0..b.len) |k| {
                const v = f.blockInsts(block)[b.len - 1 - k];
                if (tags[@backingInt(v)] != .dbg_stmt) break v;
            } else null;
            if (cg.homes[@backingInt(l)] != .deferred) cg.homes[@backingInt(l)] = if (last == l) .dead else .deferred;
        }
    }
    if (f.has_asm) return;
    const gpa = cg.gpa;
    for (f.values.items(.inst)) |inst| {
        if (tags[@backingInt(inst)] != .store) continue;
        const bin = datas[@backingInt(inst)].bin_op;
        const a = bin.lhs.toIndex() orelse continue;
        if (tags[@backingInt(a)] != .alloc) {
            // A store into part of an alloc: it is not a copy.
            if (cg.frameRoot(bin.lhs)) |root| try cg.copy_of.put(gpa, @backingInt(root), no_copy);
            continue;
        }
        if (datas[@backingInt(a)].ty == .none) continue;
        const info = Type.ptrInfo(ip, datas[@backingInt(a)].ty);
        if (!info.flags.is_const or info.flags.is_volatile or a == cg.rvo_alloc) continue;
        const gop = try cg.copy_of.getOrPut(gpa, @backingInt(a));
        if (gop.found_existing) {
            gop.value_ptr.* = no_copy;
            continue;
        }
        gop.value_ptr.* = no_copy;
        const v = bin.rhs.toIndex() orelse continue;
        const ty = cg.typeOf(bin.rhs);
        const size = Type.abiSize(ip, ty);
        if (size == 0 or cg.passInRegs(ty) or cg.inPair(ty)) continue;
        if ((try cg.copy_private.getOrPut(gpa, @backingInt(v))).found_existing) continue;
        gop.value_ptr.* = @backingInt(v);
    }
    // A copy of a by-reference argument is the argument's memory, which
    // does not change during the call: the alloc is the argument's pointer.
    if (cg.fn_ty.cc == .auto) {
        var it = cg.copy_of.iterator();
        while (it.next()) |e| {
            const v = e.value_ptr.*;
            if (v == no_copy or tags[v] != .arg or cg.autoClass(datas[v].arg.ty) != .memory) continue;
            try cg.ref_alias.put(gpa, e.key_ptr.*, {});
        }
    }
    try cg.planConstAliases();
    // Block results in memory: the value the block's only `br` passes is
    // computed in the block's slot (`slot_alias`), which is not shared.
    var brs: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty;
    defer brs.deinit(gpa);
    for (f.layout.items) |block| {
        const t = f.blocks.items[@backingInt(block)].term;
        if (t.tag != .jump or tags[@backingInt(t.inst)] != .br) continue;
        const br = datas[@backingInt(t.inst)].br;
        const gop = try brs.getOrPut(gpa, @backingInt(br.block_inst));
        gop.value_ptr.* = if (gop.found_existing) no_copy else if (br.operand.toIndex()) |v| @backingInt(v) else no_copy;
    }
    for (brs.keys(), brs.values()) |blk, v| {
        if (v == no_copy) continue;
        const ty = datas[blk].ty_pl.ty;
        if (ir.typeOfIndex(@fromBackingInt(v), ip) != ty) continue;
        if (Type.abiSize(ip, ty) == 0 or cg.passInRegs(ty) or cg.inPair(ty) or cg.inFloat(ty)) continue;
        try cg.copy_private.put(gpa, blk, {});
        try cg.slot_alias.put(gpa, v, blk);
    }
    try cg.planPayloadRegions();
}

/// `var x = f() catch unreachable` and the like, with a result in memory:
/// alloc `x` stored once, outside loops, with a block whose only `br`
/// passes the payload of call `f()`'s error union, which is otherwise only
/// tested for an error. The call's result, the block's and `x` share one
/// frame region (`payload_region`): the error union, whose payload is the
/// block's result and `x`, so neither the unwrap nor the store copies.
/// The call is the block's and the alloc's first writer: every other use of
/// `x` comes after the store in the layout, and outside loops a block
/// comes after the ones that reach it.
fn planPayloadRegions(cg: *CodeGen) Error!void {
    const ir = cg.ir;
    const ip = cg.ip;
    const f = cg.ssa;
    const gpa = cg.gpa;
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    var any = false;
    var it = cg.slot_alias.iterator();
    while (it.next()) |e| {
        const v = e.key_ptr.*;
        if (tags[v] != .unwrap_errunion_payload) continue;
        const w = datas[v].ty_op.operand.toIndex() orelse continue;
        if (tags[@backingInt(w)] == .call) any = true;
    }
    if (!any) return;
    // Uses by instruction, and the one user of those used once (the last
    // one seen otherwise), with the user's layout position.
    const n = ir.instructions.len;
    const scratch = try gpa.alloc(u32, 3 * n);
    defer gpa.free(scratch);
    const uses = scratch[0..n];
    const user = scratch[n .. 2 * n];
    const pos = scratch[2 * n ..];
    @memset(uses, 0);
    @memset(pos, std.math.maxInt(u32));
    const Count = struct {
        uses: []u32,
        user: []u32,
        at: u32,
        pub fn use(c: @This(), r: Ref) void {
            const i = @backingInt(r.toIndex() orelse return);
            c.uses[i] += 1;
            c.user[i] = c.at;
        }
    };
    var p: u32 = 0;
    for (f.layout.items) |block| {
        for (f.blockInsts(block)) |inst| {
            pos[@backingInt(inst)] = p;
            p += 1;
            Ssa.forEachOperand(ir, inst, Count{ .uses = uses, .user = user, .at = @backingInt(inst) });
        }
        const t = f.blocks.items[@backingInt(block)].term;
        if (t.tag != .fallthrough and t.tag != .noreturn) Ssa.forEachOperand(ir, t.inst, Count{ .uses = uses, .user = user, .at = @backingInt(t.inst) });
        p += 1;
    }
    var it2 = cg.slot_alias.iterator();
    while (it2.next()) |e| {
        const v = e.key_ptr.*;
        const blk = e.value_ptr.*;
        if (tags[v] != .unwrap_errunion_payload or uses[v] != 1 or uses[blk] != 1) continue;
        const w = @backingInt(datas[v].ty_op.operand.toIndex() orelse continue);
        if (tags[w] != .call or pos[w] == std.math.maxInt(u32)) continue;
        const eu_ty = ir.typeOfIndex(@fromBackingInt(w), ip);
        if (cg.passInRegs(eu_ty) or cg.inPair(eu_ty) or Type.abiAlignment(ip, eu_ty) > 16) continue;
        const st = user[blk];
        if (tags[st] != .store or datas[st].bin_op.rhs.toIndex() != @as(Inst.Index, @fromBackingInt(blk))) continue;
        const x = @backingInt(datas[st].bin_op.lhs.toIndex() orelse continue);
        if (tags[x] != .alloc or datas[x].ty == .none or pos[x] == std.math.maxInt(u32) or pos[x] > pos[w]) continue;
        if (cg.rvo_alloc) |r| if (@backingInt(r) == x) continue;
        const info = Type.ptrInfo(ip, datas[x].ty);
        if (info.flags.is_volatile or info.child != ir.typeOfIndex(@fromBackingInt(v), ip) or cg.allocAlignment(datas[x].ty) > 16) continue;
        if (cg.copy_of.get(x)) |c| if (c != no_copy) continue;
        if (cg.ref_alias.contains(x) or cg.const_alias.contains(x)) continue;
        // The store is outside loops; the call's other users test it.
        const ok = for (f.layout.items) |block| {
            const values = f.blockInsts(block);
            if (values.len != 0 and pos[@backingInt(values[0])] <= pos[st] and pos[st] <= pos[@backingInt(values[values.len - 1])]) {
                break f.block_loop.items[@backingInt(block)] == Ssa.no_loop;
            }
        } else false;
        if (!ok) continue;
        // Every use of `x` other than the store comes after it, and the
        // call's users are the unwrap and error tests.
        const Check = struct {
            x: u32,
            w: u32,
            v: u32,
            st: u32,
            at: u32,
            pos: []const u32,
            tags: []const Inst.Tag,
            bad: *bool,
            pub fn use(c: @This(), r: Ref) void {
                const i = @backingInt(r.toIndex() orelse return);
                if (i == c.x and c.at != c.st and !(c.pos[c.at] != std.math.maxInt(u32) and c.pos[c.at] > c.pos[c.st])) c.bad.* = true;
                if (i == c.w and c.at != c.v) switch (c.tags[c.at]) {
                    .is_err, .is_non_err, .unwrap_errunion_err => {},
                    else => c.bad.* = true,
                };
            }
        };
        var bad = false;
        for (f.layout.items) |block| {
            for (f.blockInsts(block)) |inst| {
                Ssa.forEachOperand(ir, inst, Check{ .x = x, .w = w, .v = v, .st = st, .at = @backingInt(inst), .pos = pos, .tags = tags, .bad = &bad });
            }
            const t = f.blocks.items[@backingInt(block)].term;
            if (t.tag != .fallthrough and t.tag != .noreturn) {
                // A terminator that reads `x` or the call (other than the
                // unwrap's `br`, which passes `v`) keeps the copies.
                var tr = false;
                const Reads = struct {
                    a: u32,
                    b: u32,
                    found: *bool,
                    pub fn use(c: @This(), r: Ref) void {
                        const i = @backingInt(r.toIndex() orelse return);
                        if (i == c.a or i == c.b) c.found.* = true;
                    }
                };
                Ssa.forEachOperand(ir, t.inst, Reads{ .a = x, .b = w, .found = &tr });
                if (tr) bad = true;
            }
            if (bad) break;
        }
        if (bad) continue;
        try cg.payload_region.put(gpa, x, .{ w, blk });
        try cg.copy_private.put(gpa, w, {});
    }
}

/// Whether load `l` of alloc `a`, returned by a `ret` in a later block,
/// still holds `a`'s memory wherever it is used, so that `a` can be the
/// result's memory (`rvo_alloc`) with `l` read in place: `l` is in no
/// loop, its other users only test it for an error, and `a`'s address
/// (or one derived from it) is only loaded from, or stored to before `l`,
/// in the layout, which puts a block after the ones that reach it outside
/// loops.
fn rvoEarlyLoad(cg: *CodeGen, l: Inst.Index, a: Inst.Index) bool {
    const ir = cg.ir;
    const f = cg.ssa;
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    const Uses = struct {
        target: Inst.Index,
        found: bool = false,
        pub fn use(u: *@This(), r: Ref) void {
            if (r.toIndex() == u.target) u.found = true;
        }
    };
    var before = true;
    // The pointers derived from `a`, by layout position; few.
    var derived: [128]Inst.Index = undefined;
    derived[0] = a;
    var n: usize = 1;
    for (f.layout.items) |block| {
        const values = f.blockInsts(block);
        for (values) |v| {
            const vi = @backingInt(v);
            if (v == l) {
                if (f.block_loop.items[@backingInt(block)] != Ssa.no_loop) return false;
                before = false;
                continue;
            }
            var u: Uses = .{ .target = l };
            Ssa.forEachOperand(ir, v, &u);
            if (u.found) switch (tags[vi]) {
                .is_err, .is_non_err => {},
                else => return false,
            };
            for (derived[0..n]) |d| {
                var du: Uses = .{ .target = d };
                Ssa.forEachOperand(ir, v, &du);
                if (!du.found) continue;
                switch (tags[vi]) {
                    .load => {},
                    .store => if (datas[vi].bin_op.lhs != d.toRef() or datas[vi].bin_op.rhs == d.toRef() or !before) return false,
                    .struct_field_ptr, .errunion_payload_ptr_set, .optional_payload_ptr_set, .ptr_elem_ptr, .ptr_add => {
                        if (tags[vi] == .errunion_payload_ptr_set or tags[vi] == .optional_payload_ptr_set) {
                            if (!before) return false;
                        }
                        if (tags[vi] == .ptr_elem_ptr or tags[vi] == .ptr_add) {
                            if (ir.extraData(Ir.Bin, datas[vi].ty_pl.payload).data.lhs != d.toRef()) return false;
                        }
                        if (n == derived.len) return false;
                        derived[n] = v;
                        n += 1;
                    },
                    else => return false,
                }
                break;
            }
        }
        const t = f.blocks.items[@backingInt(block)].term;
        if (t.tag != .ret) {
            var u: Uses = .{ .target = l };
            Ssa.forEachOperand(ir, t.inst, &u);
            if (u.found and t.tag != .fallthrough and t.tag != .noreturn) return false;
            for (derived[0..n]) |d| {
                var du: Uses = .{ .target = d };
                Ssa.forEachOperand(ir, t.inst, &du);
                if (du.found and t.tag != .fallthrough and t.tag != .noreturn) return false;
            }
        }
    }
    return !before;
}

/// Before allocation, copies decided with liveness:
/// - A load of a value that lives in memory whose only user is a later
///   `.auto` call, a store, or the `ret` of a function that returns
///   through memory, in the same block or the next one on its path (whose
///   only predecessor it is), with nothing between that may write memory,
///   is not copied to a slot of its own: the call, store or `ret` copies
///   the value from where the load points (`Home.deferred`). The pointer
///   then lives until that use. The call copies its arguments one at a
///   time, and neither the outgoing area nor the caller's result memory
///   overlaps the memory read. A store's destination must be the memory
///   read or not overlap it (`sameOrDisjoint`): the copy goes forward,
///   where upstream's ReleaseSafe build copies with `memmove`.
/// - An aggregate or union in memory whose only user is a store right
///   after it is built in the stored-to memory (`in_place`). The store's
///   pointer is live across the aggregate's lowering, which clobbers, so
///   it is not in a register the lowering writes. The elements are values
///   already computed, and none is read from memory lazily (a deferred
///   load's only user is a call or `ret`), so writing the memory early
///   changes nothing.
fn planDeferred(cg: *CodeGen) Error!void {
    const ir = cg.ir;
    const f = cg.ssa;
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    const fate = f.live.items(.fate);
    const ret_deferred = cg.fn_ty.cc == .auto and cg.autoClass(cg.fn_ty.return_type) == .memory;
    // Each block's predecessor when it has exactly one, after forwarding.
    const pred = try cg.gpa.alloc(u32, 2 * f.blocks.items.len);
    defer cg.gpa.free(pred);
    const pos = pred[f.blocks.items.len..];
    const none = std.math.maxInt(u32);
    @memset(pred[0..f.blocks.items.len], none);
    for (f.layout.items, 0..) |block, li| pos[@backingInt(block)] = @intCast(li);
    for (f.blocks.items, 0..) |b, bi| {
        // An empty block forwarded to its target emits nothing.
        if (@backingInt(f.fwd.items[bi]) != bi) continue;
        const t = b.term;
        switch (t.tag) {
            .jump, .fallthrough => cg.addPred(pred, t.succ[0], @intCast(bi)),
            .branch => for (t.succ) |x| cg.addPred(pred, x, @intCast(bi)),
            .switch_br => {
                const extra = ir.extraData(Ir.SwitchBr, datas[@backingInt(t.inst)].pl_op.payload);
                for (f.switchCases(t, extra.data.cases_len)) |c| cg.addPred(pred, @backingInt(c), @intCast(bi));
                cg.addPred(pred, t.succ[1], @intCast(bi));
            },
            .noreturn, .ret, .unreach => {},
        }
    }
    for (f.layout.items, 0..) |block, li| {
        const b = f.blocks.items[@backingInt(block)];
        // A load may also be read where it is used in the next block on
        // its path, if that block's only predecessor, earlier in the
        // layout, branches to it without writing memory.
        const prev: []const Inst.Index = if (pred[@backingInt(block)] < none - 1 and pos[pred[@backingInt(block)]] < li) prev: {
            const p: Ssa.Block.Index = @fromBackingInt(pred[@backingInt(block)]);
            const t = f.blocks.items[@backingInt(p)].term;
            if (t.tag == .jump) {
                if (tags[@backingInt(t.inst)] != .br) break :prev &.{};
                const ty = cg.typeOf(datas[@backingInt(t.inst)].br.operand);
                if (Type.abiSize(cg.ip, ty) != 0 and !cg.passInRegs(ty)) break :prev &.{};
            }
            break :prev f.blockInsts(p);
        } else &.{};
        const values = f.blockInsts(block);
        for (values, 0..) |u, k| {
            if (fate[@backingInt(u)] != .normal) continue;
            switch (tags[@backingInt(u)]) {
                .call => {
                    const data = datas[@backingInt(u)];
                    const callee_fn_ty = cg.typeOf(data.pl_op.operand);
                    const callee_ty = if (Type.class(cg.ip, callee_fn_ty) == .pointer) Type.ptrInfo(cg.ip, callee_fn_ty).child else callee_fn_ty;
                    if (cg.ip.keyPayload(.func_type, callee_ty).cc != .auto) continue;
                    const extra = ir.extraData(Ir.Call, data.pl_op.payload);
                    for (ir.refSlice(extra.end, extra.data.args_len)) |arg| cg.deferLoad(arg, values[0..k], prev, f.live.items(.def)[@backingInt(u)]);
                },
                .store => {
                    const bin = datas[@backingInt(u)].bin_op;
                    // Not the initializer of a `*const` alloc that is its
                    // memory (`planCopies`), which needs a slot.
                    if (bin.rhs.toIndex()) |l| if (tags[@backingInt(l)] == .load and !cg.copy_private.contains(@backingInt(l)) and
                        cg.sameOrDisjoint(datas[@backingInt(l)].ty_op.operand, bin.lhs))
                        cg.deferLoad(bin.rhs, values[0..k], prev, f.live.items(.def)[@backingInt(u)]);
                    try cg.storeInPlace(u, values[0..k]);
                },
                else => vector.deferOperands(cg, u, values[0..k]),
            }
        }
        if (ret_deferred and b.term.tag == .ret and tags[@backingInt(b.term.inst)] == .ret) {
            cg.deferLoad(datas[@backingInt(b.term.inst)].un_op, values, prev, 2 * (b.start + b.len) + 1);
        }
    }
}

const Rotate = struct { x: Ref, k: u8 };

/// Before allocation: a `bit_or` of `x << k` and `x >> (bits - k)` on an
/// unsigned 8-, 16-, 32- or 64-bit integer, with constant `k` (what
/// std.math.rotl and rotr become once inlined with a constant amount), is
/// a `rol` (`rotates`) when the shifts have no other user. The shifts are
/// not emitted (`Home.dead`), so `x` lives until the rotate, which may
/// compute in its register.
fn planRotates(cg: *CodeGen) Error!void {
    const ir = cg.ir;
    const ip = cg.ip;
    const f = cg.ssa;
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    const live = f.live.slice();
    const uses = live.items(.uses);
    const fate = live.items(.fate);
    const reg = live.items(.reg);
    const def = live.items(.def);
    const end = live.items(.end);
    const crosses = live.items(.crosses);
    const cl = f.clobbers.items;
    for (f.values.items(.inst)) |v| {
        const vi = @backingInt(v);
        if (tags[vi] != .bit_or or fate[vi] != .normal or reg[vi] != Ssa.want_reg) continue;
        const ty = ir.typeOfIndex(v, ip);
        if (Type.class(ip, ty) != .int) continue;
        const info = Type.intInfo(ip, ty);
        if (info.signedness != .unsigned) continue;
        switch (info.bits) {
            8, 16, 32, 64 => {},
            else => continue,
        }
        const bin = datas[vi].bin_op;
        const a = bin.lhs.toIndex() orelse continue;
        const b = bin.rhs.toIndex() orelse continue;
        const s, const r = if (tags[@backingInt(a)] == .shl and tags[@backingInt(b)] == .shr)
            .{ a, b }
        else if (tags[@backingInt(a)] == .shr and tags[@backingInt(b)] == .shl)
            .{ b, a }
        else
            continue;
        const sb = datas[@backingInt(s)].bin_op;
        const rb = datas[@backingInt(r)].bin_op;
        if (sb.lhs != rb.lhs) continue;
        // A load sharing a variable's register holds its value only until
        // its end (`Live.share`).
        if (sb.lhs.toIndex()) |x| if (fate[@backingInt(x)] != .normal or live.items(.share)[@backingInt(x)] != Ssa.no_tie) continue;
        for ([_]Inst.Index{ s, r }) |x| {
            if (uses[@backingInt(x)] != 1 or fate[@backingInt(x)] != .normal or cg.homes[@backingInt(x)] != .none) break;
        } else {
            // The amounts' values, not their bits: both are unsigned.
            const k1 = cg.shiftAmount(sb.rhs) orelse continue;
            const k2 = cg.shiftAmount(rb.rhs) orelse continue;
            if (k1 == 0 or k2 == 0 or k1 + k2 != info.bits) continue;
            try cg.rotates.put(cg.gpa, vi, .{ .x = sb.lhs, .k = @intCast(k1) });
            for ([_]Inst.Index{ s, r }) |x| {
                fate[@backingInt(x)] = .dead;
                reg[@backingInt(x)] = Ssa.no_reg;
                cg.homes[@backingInt(x)] = .dead;
            }
            live.items(.tie)[vi] = Ssa.no_tie;
            if (sb.lhs.toIndex()) |x| {
                const xi = @backingInt(x);
                end[xi] = @max(end[xi], def[vi]);
                crosses[xi] = crosses[xi] or cl[def[vi]][0] != cl[def[xi]][0] or cl[def[vi]][1] != cl[def[xi]][1];
                live.items(.tie)[vi] = xi;
            }
            continue;
        }
    }
}

/// A shift amount's value if it is a constant below 64.
fn shiftAmount(cg: *CodeGen, ref: Ref) ?u64 {
    const v = ref.toInterned() orelse return null;
    if (cg.ip.keyTag(v) != .int) return null;
    const k = cg.ip.keyPayload(.int, v);
    return switch (k.storage) {
        .u64 => |u| if (u < 64) u else null,
        .i64 => |i| if (i >= 0 and i < 64) @intCast(i) else null,
        else => null,
    };
}

/// A factor of a `mulWide` product: a value of at most 64 bits, or a
/// constant.
const Factor = union(enum) { ref: Ref, imm: u64 };

/// The factors of `inst` if it is a `mul_wrap` of two unsigned values of
/// at most 64 bits, widened to an unsigned 128-bit integer (Wyhash's
/// `mum`, std.math.mulWide): one `mul` computes it, into rdx:rax, and its
/// value lives in a register pair (`wantsReg`) instead of memory.
fn mulWide(cg: *CodeGen, inst: Inst.Index) ?[2]Factor {
    const ir = cg.ir;
    const ip = cg.ip;
    const ty = ir.typeOfIndex(inst, ip);
    if (Type.class(ip, ty) != .int) return null;
    const info = Type.intInfo(ip, ty);
    if (info.signedness != .unsigned or info.bits != 128) return null;
    const bin = ir.instructions.items(.data)[@backingInt(inst)].bin_op;
    return .{ cg.factor(bin.lhs) orelse return null, cg.factor(bin.rhs) orelse return null };
}

fn factor(cg: *CodeGen, ref: Ref) ?Factor {
    const ir = cg.ir;
    const ip = cg.ip;
    if (ref.toInterned()) |v| {
        if (ip.keyTag(v) != .int) return null;
        return switch (ip.keyPayload(.int, v).storage) {
            .u64 => |u| .{ .imm = u },
            .i64 => |i| if (i >= 0) .{ .imm = @intCast(i) } else null,
            .big => null,
        };
    }
    const i = ref.toIndex().?;
    if (ir.instructions.items(.tag)[@backingInt(i)] != .intcast) return null;
    const src = ir.instructions.items(.data)[@backingInt(i)].ty_op.operand;
    const src_ty = ir.typeOf(src, ip);
    if (Type.class(ip, src_ty) != .int) return null;
    const info = Type.intInfo(ip, src_ty);
    if (info.signedness != .unsigned or info.bits > 64) return null;
    return .{ .ref = ref };
}

/// If `inst` truncates a `mulWide` product, or that product shifted right
/// by 64, to at most 64 bits: the product and whether it reads the high
/// half.
fn mulPart(cg: *CodeGen, inst: Inst.Index) ?struct { m: Inst.Index, hi: bool } {
    const ir = cg.ir;
    const ip = cg.ip;
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    const ty = datas[@backingInt(inst)].ty_op.ty;
    if (Type.class(ip, ty) != .int or Type.intInfo(ip, ty).bits > 64) return null;
    const o = datas[@backingInt(inst)].ty_op.operand.toIndex() orelse return null;
    if (tags[@backingInt(o)] == .mul_wrap) return if (cg.mulWide(o) != null) .{ .m = o, .hi = false } else null;
    if (tags[@backingInt(o)] != .shr) return null;
    return .{ .m = cg.mulHigh(o) orelse return null, .hi = true };
}

/// If shift `inst` moves a `mulWide` product right by 64 bits: the
/// product, whose high half is the low half of the result, so one move
/// computes it and it wants a register pair.
fn mulHigh(cg: *CodeGen, inst: Inst.Index) ?Inst.Index {
    const ip = cg.ip;
    const bin = cg.ir.instructions.items(.data)[@backingInt(inst)].bin_op;
    const m = bin.lhs.toIndex() orelse return null;
    if (cg.ir.instructions.items(.tag)[@backingInt(m)] != .mul_wrap or cg.mulWide(m) == null) return null;
    const k = bin.rhs.toInterned() orelse return null;
    if (ip.keyTag(k) != .int) return null;
    switch (ip.keyPayload(.int, k).storage) {
        .u64 => |u| if (u != 64) return null,
        .i64 => |i| if (i != 64) return null,
        .big => return null,
    }
    return m;
}

/// Before allocation: a `mulWide` product reads its factors' 64-bit
/// values, so a widening `intcast` only it reads is not emitted, and the
/// value cast lives until the product instead. A shift by 64 that only a
/// `mulPart` truncation reads is not emitted either: the truncation reads
/// the product's high half, which lives until it.
fn planMulWide(cg: *CodeGen) Error!void {
    const ir = cg.ir;
    const f = cg.ssa;
    const datas = ir.instructions.items(.data);
    const live = f.live.slice();
    const uses = live.items(.uses);
    const fate = live.items(.fate);
    const reg = live.items(.reg);
    const def = live.items(.def);
    const end = live.items(.end);
    const crosses = live.items(.crosses);
    const share = live.items(.share);
    const cl = f.clobbers.items;
    const extend = struct {
        fn run(e: []u32, d: []const u32, c: []bool, clob: []const [2]u32, x: u32, to: u32) void {
            e[x] = @max(e[x], to);
            c[x] = c[x] or clob[to][0] != clob[d[x]][0] or clob[to][1] != clob[d[x]][1];
        }
    }.run;
    for (f.values.items(.inst)) |v| {
        const vi = @backingInt(v);
        if (fate[vi] != .normal) continue;
        switch (ir.instructions.items(.tag)[vi]) {
            .mul_wrap => {
                if (reg[vi] != Ssa.want_pair) continue;
                const fs = cg.mulWide(v) orelse continue;
                for (fs) |fa| {
                    const c = (switch (fa) {
                        .ref => |r| r,
                        .imm => continue,
                    }).toIndex().?;
                    const ci = @backingInt(c);
                    if (uses[ci] != 1 or fate[ci] != .normal or cg.homes[ci] != .none) continue;
                    const src = datas[ci].ty_op.operand;
                    if (src.toIndex()) |x| {
                        const xi = @backingInt(x);
                        if (fate[xi] != .normal or share[xi] != Ssa.no_tie) continue;
                        extend(end, def, crosses, cl, xi, def[vi]);
                    }
                    fate[ci] = .dead;
                    reg[ci] = Ssa.no_reg;
                    cg.homes[ci] = .dead;
                    try cg.mul_dead.put(cg.gpa, ci, {});
                }
            },
            .trunc => {
                if (reg[vi] != Ssa.want_reg) continue;
                const part = cg.mulPart(v) orelse continue;
                extend(end, def, crosses, cl, @backingInt(part.m), def[vi]);
                if (!part.hi) continue;
                const sh = @backingInt(datas[vi].ty_op.operand.toIndex().?);
                if (uses[sh] != 1 or fate[sh] != .normal or cg.homes[sh] != .none) continue;
                fate[sh] = .dead;
                reg[sh] = Ssa.no_reg;
                cg.homes[sh] = .dead;
            },
            else => {},
        }
    }
}

/// Loads `mulWide` factor `fa` into `r`.
fn loadFactor(cg: *CodeGen, r: Reg, fa: Factor) Error!void {
    switch (fa) {
        .imm => |u| try cg.e.mov(.qword, .{ .reg = r }, .{ .imm = @bitCast(u) }),
        .ref => |ref| {
            const c = ref.toIndex().?;
            // The value cast, if the cast is not emitted; else the low
            // half of the cast.
            if (cg.mul_dead.count() != 0 and cg.mul_dead.contains(@backingInt(c))) return cg.load(r, cg.ir.instructions.items(.data)[@backingInt(c)].ty_op.operand);
            if (cg.pairOf(ref)) |p| return cg.e.mov(.qword, .{ .reg = r }, .{ .reg = p.lo });
            try cg.e.mov(.qword, .{ .reg = r }, .{ .mem = try cg.memOf(ref) });
        },
    }
}

/// Whether pointers `a` and `b` to values of one type point to the same
/// memory or to memory that does not overlap: elements of one array, or
/// memory in different locals or global variables.
fn sameOrDisjoint(cg: *CodeGen, a: Ref, b: Ref) bool {
    if (a == b) return true;
    const ir = cg.ir;
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    if (a.toIndex()) |ai| if (b.toIndex()) |bi| {
        const ta = tags[@backingInt(ai)];
        if ((ta == .ptr_elem_ptr or ta == .slice_elem_ptr) and tags[@backingInt(bi)] == ta and
            ir.extraData(Ir.Bin, datas[@backingInt(ai)].ty_pl.payload).data.lhs == ir.extraData(Ir.Bin, datas[@backingInt(bi)].ty_pl.payload).data.lhs)
            return true;
    };
    const ra = cg.ptrRoot(a);
    const rb = cg.ptrRoot(b);
    if (ra == .none or rb == .none) return false;
    return !std.meta.eql(ra, rb);
}

/// The object pointer `ref` points into, if `sameOrDisjoint` can tell:
/// a local (an `alloc`) or a global variable or constant.
const PtrRoot = union(enum) { none, alloc: u32, nav: InternPool.NavIndex, uav: Index };

fn ptrRoot(cg: *CodeGen, ref: Ref) PtrRoot {
    const ir = cg.ir;
    const ip = cg.ip;
    var cur = ref;
    for (0..8) |_| {
        if (cur.toInterned()) |v0| {
            var v = v0;
            for (0..8) |_| {
                if (ip.keyTag(v) != .ptr) return .none;
                switch (ip.keyPayload(.ptr, v).base) {
                    .nav => |n| {
                        // Extern declarations of one name are one object.
                        // By the declaration, not its value: a variable
                        // whose address code took may have only its type
                        // resolved (see `ptrToZeroBit`), and the Sema
                        // thread resolves the value whenever it gets to
                        // it, so the code must not depend on when.
                        if (ip.getNav(n).linkage == .@"extern") return .none;
                        return .{ .nav = n };
                    },
                    .uav => |u| return if (ip.keyTag(u.val) == .extern_var or ip.keyTag(u.val) == .extern_func) .none else .{ .uav = u.val },
                    .field => |f| v = f.base,
                    .elem => |el| v = el.base,
                    else => return .none,
                }
            }
            return .none;
        }
        const i = cur.toIndex() orelse return .none;
        const data = ir.instructions.items(.data)[@backingInt(i)];
        switch (ir.instructions.items(.tag)[@backingInt(i)]) {
            .alloc => return .{ .alloc = @backingInt(i) },
            .struct_field_ptr => cur = ir.extraData(Ir.StructField, data.ty_pl.payload).data.operand,
            .ptr_elem_ptr, .ptr_add => cur = ir.extraData(Ir.Bin, data.ty_pl.payload).data.lhs,
            else => return .none,
        }
    }
    return .none;
}

/// Records `from` as a predecessor of block `to` (`planDeferred`):
/// `pred` holds the only one, or `maxInt - 1` once there are several.
fn addPred(cg: *CodeGen, pred: []u32, to: u32, from: u32) void {
    const t = @backingInt(cg.ssa.fwd.items[to]);
    pred[t] = if (pred[t] == std.math.maxInt(u32)) from else std.math.maxInt(u32) - 1;
}

/// Defers load `arg` (`planDeferred`) if it is one of the last `before`
/// values, or of the `prev` values that run before them, with only values
/// that write no memory after it, and its only user is at position `at`.
pub fn deferLoad(cg: *CodeGen, arg: Ref, before: []const Inst.Index, prev: []const Inst.Index, at: u32) void {
    const ir = cg.ir;
    const f = cg.ssa;
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    const live = f.live.slice();
    const uses = live.items(.uses);
    const def = live.items(.def);
    const end = live.items(.end);
    const crosses = live.items(.crosses);
    const fate = live.items(.fate);
    const share = live.items(.share);
    const fwd = live.items(.fwd);
    const cl = f.clobbers.items;
    const l = arg.toIndex() orelse return;
    const li = @backingInt(l);
    if (tags[li] != .load or uses[li] != 1 or fate[li] != .normal or fwd[li] != Ssa.no_tie) return;
    if (cg.homes[li] != .none) return; // the result's own alloc (`planCopies`)
    const ty = datas[li].ty_op.ty;
    if (Type.abiSize(cg.ip, ty) == 0 or cg.passInRegs(ty) or cg.inPair(ty)) return;
    if (!Ssa.removable(ir, cg.ip, l)) return; // volatile
    const found = for (0..@min(before.len + prev.len, 32)) |j| {
        const v = if (j < before.len) before[before.len - 1 - j] else prev[prev.len + before.len - 1 - j];
        if (v == l) break true;
        switch (tags[@backingInt(v)]) {
            .dbg_stmt, .dbg_inline_begin, .dbg_inline_end => {},
            // A block's result is written by its `br`s, which are
            // terminators.
            .block => {},
            else => if (!Ssa.removable(ir, cg.ip, v)) break false,
        }
    } else false;
    if (!found) return;
    const ptr = datas[li].ty_op.operand;
    if (ptr.toIndex()) |p0| {
        // A folded address keeps its base, not itself, alive.
        if (cg.addr_base[@backingInt(p0)] != no_base) return;
        var p = @backingInt(p0);
        // A variable `Ssa.plan` may keep in a register (a 16-byte vector)
        // has no memory to read.
        if (tags[p] == .alloc and Ssa.wants(live.items(.reg)[p])) return;
        if (fwd[p] != Ssa.no_tie) p = fwd[p];
        if (share[p] != Ssa.no_tie or fate[p] != .normal) return;
        end[p] = @max(end[p], at);
        crosses[p] = crosses[p] or cl[at][0] != cl[def[p]][0] or cl[at][1] != cl[def[p]][1];
    }
    cg.homes[li] = .deferred;
}

/// Builds the aggregate that store `st` stores in place (`planDeferred`)
/// if it is the last of the `before` values, ignoring debug markers.
fn storeInPlace(cg: *CodeGen, st: Inst.Index, before: []const Inst.Index) Error!void {
    const ir = cg.ir;
    const ip = cg.ip;
    const tags = ir.instructions.items(.tag);
    const live = cg.ssa.live.slice();
    const bin = ir.instructions.items(.data)[@backingInt(st)].bin_op;
    const v = bin.rhs.toIndex() orelse return;
    const vi = @backingInt(v);
    if (tags[vi] != .aggregate_init and tags[vi] != .union_init and !(tags[vi] == .bitcast and vector.bitcastInPlace(cg, v))) return;
    if (live.items(.uses)[vi] != 1 or live.items(.fate)[vi] != .normal) return;
    const prev = for (0..before.len) |j| {
        const x = before[before.len - 1 - j];
        switch (tags[@backingInt(x)]) {
            .dbg_stmt, .dbg_inline_begin, .dbg_inline_end => {},
            else => break x,
        }
    } else return;
    if (prev != v) return;
    const ty = cg.typeOf(bin.rhs);
    if (Type.abiSize(ip, ty) == 0 or cg.passInRegs(ty) or cg.inPair(ty) or cg.inFloat(ty)) return;
    if (Type.ptrInfo(ip, cg.typeOf(bin.lhs)).flags.is_volatile) return;
    // An initializer that is its `*const` alloc's memory (`planCopies`).
    if (cg.copy_private.count() != 0 and cg.copy_private.contains(vi)) return;
    if (cg.homes[vi] != .none) return;
    try cg.in_place.put(cg.gpa, vi, bin.lhs);
}

/// A `copy_of` entry for an alloc that is not a copy.
const no_copy = std.math.maxInt(u32);

/// The `alloc` that pointer `ref` is a field or element of, if any.
fn frameRoot(cg: *CodeGen, ref: Ref) ?Inst.Index {
    var cur = ref;
    for (0..8) |_| {
        const i = cur.toIndex() orelse return null;
        const data = cg.ir.instructions.items(.data)[@backingInt(i)];
        switch (cg.ir.instructions.items(.tag)[@backingInt(i)]) {
            .alloc => return i,
            .struct_field_ptr => cur = cg.ir.extraData(Ir.StructField, data.ty_pl.payload).data.operand,
            .ptr_elem_ptr, .ptr_add => cur = cg.ir.extraData(Ir.Bin, data.ty_pl.payload).data.lhs,
            else => return null,
        }
    }
    return null;
}

/// How wide to write an error union's error code: through the padding
/// before the payload, up to 8 bytes, so that reading the error union as
/// whole words later forwards from the store instead of stalling on it.
fn errFieldSize(layout: Type.ErrorUnionLayout) Size {
    return switch (@min(layout.payload_offset, 8)) {
        0, 2 => .word,
        4 => .dword,
        8 => .qword,
        else => unreachable,
    };
}

/// The register holding `ptr`'s pointee if `ptr` is a promoted variable
/// that got one.
fn varReg(cg: *CodeGen, ptr: Ref) ?Reg {
    const i = ptr.toIndex() orelse return null;
    if (cg.ir.instructions.items(.tag)[@backingInt(i)] != .alloc) return null;
    return switch (cg.homes[@backingInt(i)]) {
        .reg => |r| r,
        else => null,
    };
}

/// The register holding `ptr`'s pointee if `ptr` is a promoted f32 or f64
/// variable that got one.
fn varXmm(cg: *CodeGen, ptr: Ref) ?Encoder.Xmm {
    const i = ptr.toIndex() orelse return null;
    if (cg.ir.instructions.items(.tag)[@backingInt(i)] != .alloc) return null;
    return cg.xmmOf(ptr);
}

/// The alignment of an `alloc` of pointer type `ty`'s memory.
fn allocAlignment(cg: *CodeGen, ty: Index) u64 {
    const info = Type.ptrInfo(cg.ip, ty);
    return @max(Type.abiAlignment(cg.ip, info.child), if (info.flags.alignment == 0) 1 else @as(u64, 1) << @intCast(info.flags.alignment - 1));
}

/// The value of an integer constant operand that fits in 32 bits.
fn constIndex(cg: *CodeGen, ref: Ref) ?u64 {
    const v = ref.toInterned() orelse return null;
    if (cg.ip.keyTag(v) != .int) return null;
    const k = cg.ip.intValue(u64, v) orelse return null;
    return if (k <= std.math.maxInt(i32)) k else null;
}

/// Whether pointer `ref` will be a frame address (`Home.frame_addr`): an
/// `alloc` in the frame, or a field or constant-index element of one.
/// Such a pointer needs no register and no code (`foldFrame`).
fn frameFoldable(cg: *CodeGen, ref: Ref) bool {
    const ip = cg.ip;
    var cur = ref;
    // Bounded: a chain of fields of fields is short.
    for (0..8) |_| {
        const i = cur.toIndex() orelse return false;
        const data = cg.ir.instructions.items(.data)[@backingInt(i)];
        switch (cg.ir.instructions.items(.tag)[@backingInt(i)]) {
            .alloc => return data.ty != .none and cg.allocAlignment(data.ty) <= 16 and i != cg.rvo_alloc and
                !(cg.ref_alias.count() != 0 and cg.ref_alias.contains(@backingInt(i))) and
                !(cg.const_alias.count() != 0 and cg.const_alias.contains(@backingInt(i))),
            .struct_field_ptr => {
                const sf = cg.ir.extraData(Ir.StructField, data.ty_pl.payload).data;
                const container = Type.ptrInfo(ip, cg.typeOf(sf.operand)).child;
                if (Type.fieldOffset(ip, container, sf.index) > std.math.maxInt(i32)) return false;
                cur = sf.operand;
            },
            .ptr_elem_ptr, .ptr_add => {
                const bin = cg.ir.extraData(Ir.Bin, data.ty_pl.payload).data;
                const k = cg.constIndex(bin.rhs) orelse return false;
                if (k * Type.abiSize(ip, Type.ptrInfo(ip, data.ty_pl.ty).child) > std.math.maxInt(i32)) return false;
                cur = bin.lhs;
            },
            else => return false,
        }
    }
    return false;
}

/// Gives pointer `inst`, `base + off`, the frame address it is if `base`
/// is one, or the register address it is if `addrFoldable` chose it and
/// `base` got a register; returns whether it did.
fn foldFrame(cg: *CodeGen, inst: Inst.Index, base: Ref, off: u64) bool {
    const b = base.toIndex() orelse return false;
    switch (cg.homes[@backingInt(b)]) {
        .frame_addr => |o| {
            cg.homes[@backingInt(inst)] = .{ .frame_addr = o + @as(i32, @intCast(off)) };
            return true;
        },
        .reg => |r| if (cg.addr_base[@backingInt(inst)] != no_base and cg.homes[@backingInt(inst)] == .none) {
            cg.homes[@backingInt(inst)] = .{ .reg_addr = .{ .base = r, .off = @intCast(off) } };
            return true;
        },
        .reg_addr => |a| if (cg.addr_base[@backingInt(inst)] != no_base and cg.homes[@backingInt(inst)] == .none) {
            cg.homes[@backingInt(inst)] = .{ .reg_addr = .{ .base = a.base, .off = a.off + @as(i32, @intCast(off)) } };
            return true;
        },
        else => {},
    }
    return false;
}

/// A `*const` alloc whose first use, in its own block, is its only store,
/// of a constant that lives in memory, is that constant's memory
/// (`const_alias`), as a copy of a by-reference argument is the
/// argument's (`ref_alias`): a spliced call's parameter copy of a constant
/// argument costs nothing, as the call itself does. The constant never
/// changes, and the alloc's memory can be written only through a pointer
/// derived from it (a `*const`, so only after a cast: `@constCast`), so
/// any use of the alloc's pointer other than loads, field and element
/// addresses read the same way, and call arguments (whose `*const`
/// parameters are not written either) keeps the copy.
fn planConstAliases(cg: *CodeGen) Error!void {
    const ir = cg.ir;
    const ip = cg.ip;
    const f = cg.ssa;
    const gpa = cg.gpa;
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    // The allocs, and the pointers derived from them, with their alloc;
    // each alloc's initializing store.
    var from: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer from.deinit(gpa);
    var init: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer init.deinit(gpa);
    for (f.layout.items) |block| {
        const insts = f.blockInsts(block);
        for (insts, 0..) |a, k| {
            if (tags[@backingInt(a)] != .alloc or datas[@backingInt(a)].ty == .none or a == cg.rvo_alloc) continue;
            const info = Type.ptrInfo(ip, datas[@backingInt(a)].ty);
            if (!info.flags.is_const or info.flags.is_volatile) continue;
            // The alloc's first use: nothing reads it before the store.
            const st = for (insts[k + 1 ..]) |i| {
                if (tags[@backingInt(i)] != .dbg_stmt) break i;
            } else continue;
            if (tags[@backingInt(st)] != .store) continue;
            const bin = datas[@backingInt(st)].bin_op;
            if (bin.lhs != a.toRef()) continue;
            const v = bin.rhs.toInterned() orelse continue;
            // An `undefined` one is left to its store, which fills 0xaa.
            if (ip.keyTag(v) == .undef) continue;
            const ty = ip.typeOf(v);
            if (Type.abiSize(ip, ty) == 0 or cg.passInRegs(ty) or cg.inPair(ty)) continue;
            if (cg.allocAlignment(datas[@backingInt(a)].ty) > Type.abiAlignment(ip, ty)) continue;
            try from.put(gpa, @backingInt(a), @backingInt(a));
            try init.put(gpa, @backingInt(a), @backingInt(st));
            try cg.const_alias.put(gpa, @backingInt(a), v);
        }
    }
    if (from.count() == 0) return;
    // Any other use of a pointer into the alloc keeps the copy.
    const Check = struct {
        cg: *CodeGen,
        from: *const std.AutoHashMapUnmanaged(u32, u32),
        pub fn use(c: @This(), r: Ref) void {
            const i = r.toIndex() orelse return;
            if (c.from.get(@backingInt(i))) |a| _ = c.cg.const_alias.remove(a);
        }
    };
    const check: Check = .{ .cg = cg, .from = &from };
    for (f.layout.items) |block| {
        for (f.blockInsts(block)) |inst| {
            const data = datas[@backingInt(inst)];
            switch (tags[@backingInt(inst)]) {
                .load, .call, .dbg_stmt => {},
                .struct_field_ptr => {
                    const base = ir.extraData(Ir.StructField, data.ty_pl.payload).data.operand.toIndex() orelse continue;
                    if (from.get(@backingInt(base))) |a| try from.put(gpa, @backingInt(inst), a);
                },
                .ptr_elem_ptr, .ptr_add => {
                    const bin = ir.extraData(Ir.Bin, data.ty_pl.payload).data;
                    check.use(bin.rhs);
                    const base = bin.lhs.toIndex() orelse continue;
                    if (from.get(@backingInt(base))) |a| try from.put(gpa, @backingInt(inst), a);
                },
                .store => {
                    const a = data.bin_op.lhs.toIndex();
                    if (a == null or init.get(@backingInt(a.?)) != @backingInt(inst)) Ssa.forEachOperand(ir, inst, check);
                },
                else => Ssa.forEachOperand(ir, inst, check),
            }
        }
        const t = f.blocks.items[@backingInt(block)].term;
        if (t.tag == .jump or t.tag == .ret) Ssa.forEachOperand(ir, t.inst, check);
    }
}

const no_base = std.math.maxInt(u32);

/// The pointer that address `inst` (a `struct_field_ptr`, `ptr_elem_ptr`,
/// or `ptr_add`, or a copy of a by-reference argument, `ref_alias`) is an
/// offset from.
fn addrOperand(cg: *CodeGen, inst: Inst.Index) Ref {
    if (cg.ir.instructions.items(.tag)[@backingInt(inst)] == .alloc) return Inst.Index.toRef(@fromBackingInt(cg.copy_of.get(@backingInt(inst)).?));
    const data = cg.ir.instructions.items(.data)[@backingInt(inst)];
    // `StructField.operand` and `Bin.lhs` come first.
    return @fromBackingInt(cg.ir.extra[data.ty_pl.payload]);
}

/// Whether pointer `inst`, a constant offset from another pointer in a
/// general-purpose register (or from one such pointer itself folded), is
/// folded into its users' addressing: it takes no register, and its users
/// address `[base + off]`, so the base lives as long as they do
/// (`lengthenIntervals`). Records the base in `addr_base`. For `liveness`,
/// in layout order, where the base's register class is already known. If
/// the base gets no register after all, the pointer is computed as usual.
fn addrFoldable(cg: *CodeGen, inst: Inst.Index) bool {
    if (cg.has_asm) return false;
    const ir = cg.ir;
    const ip = cg.ip;
    const data = ir.instructions.items(.data)[@backingInt(inst)];
    const base: Ref, const off: u64 = switch (ir.instructions.items(.tag)[@backingInt(inst)]) {
        .struct_field_ptr => blk: {
            const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
            const container = Type.ptrInfo(ip, cg.typeOf(sf.operand)).child;
            break :blk .{ sf.operand, Type.fieldOffset(ip, container, sf.index) };
        },
        else => blk: {
            const bin = ir.extraData(Ir.Bin, data.ty_pl.payload).data;
            const k = cg.constIndex(bin.rhs) orelse return false;
            break :blk .{ bin.lhs, k *% Type.abiSize(ip, Type.ptrInfo(ip, data.ty_pl.ty).child) };
        },
    };
    if (off > 1 << 30) return false;
    const b = @backingInt(base.toIndex() orelse return false);
    const root = if (cg.addr_base[b] != no_base) cg.addr_base[b] else b;
    if (cg.emit.ssa.live.items(.reg)[root] != Ssa.want_reg) return false;
    cg.addr_base[@backingInt(inst)] = root;
    return true;
}

/// In `Ssa.plan`, after forwarding: each folded address (`addrFoldable`)
/// gets `want_fold`, and the pointer it is an offset from (or the value
/// that pointer forwards) in `addr_base`, for `Ssa.allocate`; that
/// pointer, and each folded one between it and the register that holds
/// them, lives as long as the address. An address whose register holder
/// would then cross a clobber point it did not cross before wants a
/// register of its own instead: the holder would need one that survives
/// calls, which are few.
pub fn lengthenIntervals(cg: *CodeGen) void {
    const f = cg.ssa;
    const live = f.live.slice();
    const def = live.items(.def);
    const end = live.items(.end);
    const crosses = live.items(.crosses);
    const reg = live.items(.reg);
    const fwd = live.items(.fwd);
    const fate = live.items(.fate);
    const cl = f.clobbers.items;
    for (f.values.items(.inst)) |inst| {
        const v = @backingInt(inst);
        if (cg.addr_base[v] == no_base) continue;
        if (fate[v] == .dead) {
            cg.addr_base[v] = no_base;
            continue;
        }
        const b = @backingInt(cg.addrOperand(inst).toIndex().?);
        // The register holder: the first pointer up the chain that is
        // not folded, through forwarded loads.
        var h = b;
        while (true) {
            if (fwd[h] != Ssa.no_tie) h = fwd[h];
            if (cg.addr_base[h] == no_base) break;
            h = @backingInt(cg.addrOperand(@fromBackingInt(h)).toIndex().?);
        }
        const e = @max(end[h], end[v]);
        if (!crosses[h] and (crosses[v] or cl[e][0] != cl[def[h]][0])) {
            cg.addr_base[v] = no_base;
            reg[v] = Ssa.want_reg;
            live.items(.tie)[v] = cg.tiedOperand(inst);
            continue;
        }
        // A folded link whose own base gets no register holds the
        // address itself (`Ssa.allocate`), so it crosses what the
        // address's users cross.
        var x = b;
        while (true) {
            if (fwd[x] != Ssa.no_tie) x = fwd[x];
            end[x] = @max(end[x], end[v]);
            crosses[x] = crosses[x] or crosses[v] or cl[end[x]][0] != cl[def[x]][0];
            if (cg.addr_base[x] == no_base) break;
            x = @backingInt(cg.addrOperand(@fromBackingInt(x)).toIndex().?);
        }
        reg[v] = Ssa.want_fold;
        // For a register of its own after all.
        live.items(.tie)[v] = cg.tiedOperand(inst);
        cg.addr_base[v] = if (fwd[b] != Ssa.no_tie) fwd[b] else b;
    }
}

/// Whether `ty`'s values fit a general-purpose register.
pub fn inGpr(cg: *CodeGen, ty: Index) bool {
    const ip = cg.ip;
    // Hot: decided by the type's class without computing its size where
    // possible.
    return switch (Type.class(ip, ty)) {
        .bool => true,
        .int => Type.intInfo(ip, ty).bits -% 1 < 64,
        .pointer => !Type.isSlice(ip, ty),
        .optional => Type.optionalReprIsPtr(ip, Type.childType(ip, ty)) or cg.optInGpr(ty),
        // An error union of up to 8 bytes holds its bytes like a load: the
        // error code in the low 16 bits, the payload above.
        .error_set, .@"enum", .error_union => cg.passInRegs(ty),
        // A bool vector of up to 64 elements is its bits (`vector.isBits`).
        .vector => vector.isBits(ip, ty),
        else => false,
    };
}

/// Whether optional type `ty` is a flag after a bool, integer, or enum
/// payload in up to 8 bytes in all, which lives in a general-purpose
/// register as its bytes, zero-extended like a load: the payload in the
/// low bytes, the flag at `Type.optionalFlagOffset`.
fn optInGpr(cg: *CodeGen, ty: Index) bool {
    const ip = cg.ip;
    const child = Type.childType(ip, ty);
    return switch (Type.class(ip, child)) {
        .bool, .int, .@"enum" => !Type.optionalReprIsPayload(ip, child) and Type.hasRuntimeBits(ip, child) and cg.inGpr(child) and cg.passInRegs(ty),
        else => false,
    };
}

/// Whether a value of type `ty` that is not `inGpr` may still live in a
/// general-purpose register as its bytes, extended like a load: a struct,
/// tuple, array, union, or optional of 1, 2, 4, or 8 bytes. Only loads
/// and block results get one; their users that read memory get a copy
/// (`memOf`), as for `Home.regs`.
fn inGprBytes(cg: *CodeGen, ty: Index) bool {
    return switch (Type.class(cg.ip, ty)) {
        .@"struct", .tuple, .array, .@"union", .optional => cg.passInRegs(ty),
        else => false,
    };
}

/// Whether integer, bool, or pointer operand `ref` takes the scalar paths.
fn scalarOperand(cg: *CodeGen, ref: Ref) bool {
    const ty = cg.typeOf(ref);
    return !cg.isFloat(ty) and !cg.isWideInt(ty) and cg.passInRegs(ty);
}

/// Whether condition `inst` can be computed by the branch it decides.
pub fn fusable(cg: *CodeGen, inst: Inst.Index) bool {
    const data = cg.ir.instructions.items(.data)[@backingInt(inst)];
    return switch (cg.ir.instructions.items(.tag)[@backingInt(inst)]) {
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => cg.scalarOperand(data.bin_op.lhs) or
            (cg.inFloat(cg.typeOf(data.bin_op.lhs)) and floatCc(cg.ir.instructions.items(.tag)[@backingInt(inst)]) != null),
        .is_err, .is_non_err, .is_null, .is_non_null => true,
        .reduce => vector.fusable(cg, inst),
        .not => cg.typeOf(data.ty_op.operand) == .bool_type,
        else => false,
    };
}

const RegClass = enum {
    none,
    gpr,
    pair,
    float,

    fn want(c: RegClass) u8 {
        return switch (c) {
            .none => unreachable,
            .gpr => Ssa.want_reg,
            .pair => Ssa.want_pair,
            .float => Ssa.want_float,
        };
    }
};

/// Whether `ty`'s values live in an XMM register when they get one: f32,
/// f64, and vectors of up to 16 bytes of lanes (`vector.inXmm`).
pub fn inFloat(cg: *CodeGen, ty: Index) bool {
    return switch (Type.class(cg.ip, ty)) {
        .float => cg.sseType(ty) != null,
        .vector => vector.inXmm(cg.ip, ty),
        else => false,
    };
}

/// Whether value `inst` is computed by code that leaves it in a register
/// (`setResult`), or in two (`Home.regs`, for the operations that compute
/// those).
fn wantsReg(cg: *CodeGen, inst: Inst.Index) RegClass {
    const ir = cg.ir;
    const data = ir.instructions.items(.data)[@backingInt(inst)];
    const tag = ir.instructions.items(.tag)[@backingInt(inst)];
    // Vector operations compute vectors in XMM registers and bool vectors
    // and reductions in GPRs.
    if (vector.lowers(cg, inst)) {
        const ty = ir.typeOfIndex(inst, cg.ip);
        return if (cg.inFloat(ty)) .float else if (cg.inGpr(ty)) .gpr else .none;
    }
    // f32 and f64 results of the lowerings that compute them in an XMM
    // register (`setXmm`) or a GPR (`setResult`), without calls.
    switch (tag) {
        .add_float, .sub_float, .mul_float, .div_float, .min_float, .max_float, .neg_float, .abs_float, .sqrt => return if (cg.inFloat(ir.typeOfIndex(inst, cg.ip))) .float else .none,
        .float_cast => return if (cg.inFloat(data.ty_op.ty) and cg.inFloat(cg.typeOf(data.ty_op.operand))) .float else .none,
        .float_from_int => return if (cg.inFloat(data.ty_op.ty) and Type.intInfo(cg.ip, cg.typeOf(data.ty_op.operand)).bits <= 64) .float else .none,
        .load, .struct_field_val, .ptr_elem_val, .slice_elem_val, .arg, .call => if (cg.inFloat(ir.typeOfIndex(inst, cg.ip))) {
            if (tag == .arg and cg.fn_ty.cc != .auto) return .none;
            // Vectors: loads, and `.auto` arguments and results.
            if (Type.class(cg.ip, ir.typeOfIndex(inst, cg.ip)) == .vector) return switch (tag) {
                .load, .arg => .float,
                .call => if (cg.calleeCc(data) == .auto) .float else .none,
                else => .none,
            };
            return .float;
        },
        else => {},
    }
    // A 128-bit product of 64-bit values, and its halves (`mulWide`).
    if (tag == .mul_wrap and cg.mulWide(inst) != null) return .pair;
    if (tag == .trunc and cg.mulPart(inst) != null) return .gpr;
    if (tag == .shr and cg.mulHigh(inst) != null) return .pair;
    const wanted = switch (tag) {
        .add_wrap, .sub_wrap, .mul_wrap, .bit_and, .bit_or, .xor, .shl, .shr, .div_trunc, .div_floor, .div_ceil, .rem, .mod => cg.inGpr(cg.typeOf(data.bin_op.lhs)),
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => cg.inGpr(cg.typeOf(data.bin_op.lhs)) or cg.inFloat(cg.typeOf(data.bin_op.lhs)),
        .not, .clz, .ctz, .popcount, .byte_swap, .bit_reverse => !cg.isWideInt(cg.typeOf(data.ty_op.operand)),
        .intcast, .trunc, .bitcast, .ptr_from_int => cg.passInRegs(cg.typeOf(data.ty_op.operand)) and !cg.isWideInt(cg.typeOf(data.ty_op.operand)),
        .load, .int_from_bool, .int_from_ptr, .is_null, .is_non_null, .is_err, .is_non_err => true,
        // `setupParams` moves it from where `.auto` passes it.
        .arg => cg.fn_ty.cc == .auto,
        .struct_field_ptr, .struct_field_val, .ptr_elem_ptr, .slice_elem_ptr, .ptr_add, .ptr_elem_val, .slice_elem_val => true,
        .slice_ptr, .slice_len, .optional_payload, .optional_payload_ptr, .optional_payload_ptr_set => true,
        .wrap_errunion_err => true,
        .wrap_errunion_payload => !Type.hasRuntimeBits(cg.ip, cg.typeOf(data.ty_op.operand)) or cg.passInRegs(cg.typeOf(data.ty_op.operand)),
        .unwrap_errunion_payload, .unwrap_errunion_err, .unwrap_errunion_payload_ptr, .unwrap_errunion_err_ptr, .errunion_payload_ptr_set => true,
        .call, .atomic_load, .atomic_rmw, .ret_addr, .frame_addr, .extern_ptr, .extern_pcrel, .err_return_trace, .save_err_return_trace_index, .tls_ptr, .extern_tls, .get_union_tag => true,
        .slice, .wrap_optional => true,
        else => false,
    };
    if (!wanted) return .none;
    const ty = ir.typeOfIndex(inst, cg.ip);
    if (cg.inGpr(ty) or (tag == .load and cg.inGprBytes(ty))) return .gpr;
    // The register holds the pointer to a by-reference argument
    // (`Home.ind`).
    if (tag == .arg and cg.autoClass(ty) == .memory) return .gpr;
    const pair = switch (tag) {
        .load, .slice, .slice_elem_val, .ptr_elem_val, .optional_payload, .wrap_optional, .wrap_errunion_payload, .wrap_errunion_err, .arg => true,
        // `.auto` returns a pair in rax and rdx.
        .call => blk: {
            const callee_fn_ty = cg.typeOf(data.pl_op.operand);
            const callee_ty = if (Type.class(cg.ip, callee_fn_ty) == .pointer) Type.ptrInfo(cg.ip, callee_fn_ty).child else callee_fn_ty;
            break :blk cg.ip.keyPayload(.func_type, callee_ty).cc == .auto;
        },
        else => false,
    };
    return if (pair and cg.inPair(ty)) .pair else .none;
}

/// The calling convention of call `data`'s callee.
fn calleeCc(cg: *CodeGen, data: Inst.Data) InternPool.CallingConvention {
    const callee_fn_ty = cg.typeOf(data.pl_op.operand);
    const callee_ty = if (Type.class(cg.ip, callee_fn_ty) == .pointer) Type.ptrInfo(cg.ip, callee_fn_ty).child else callee_fn_ty;
    return cg.ip.keyPayload(.func_type, callee_ty).cc;
}

/// The operand whose register value `inst`'s lowering may write its result
/// to: the first, which every lowering reads before it writes the result
/// (it reads the others first, or they are in memory).
fn tiedOperand(cg: *CodeGen, inst: Inst.Index) u32 {
    const T = struct {
        first: ?Ref = null,
        pub fn use(t: *@This(), ref: Ref) void {
            if (t.first == null) t.first = ref;
        }
    };
    const ir = cg.ir;
    if (ir.instructions.items(.tag)[@backingInt(inst)] == .struct_field_val) {
        // The value of an addition or subtraction with overflow that
        // writes its fields (`Ssa.Fate.pair`) is computed over the left
        // operand (`overflowArith`).
        const sf = ir.extraData(Ir.StructField, ir.instructions.items(.data)[@backingInt(inst)].ty_pl.payload).data;
        if (sf.index == 0) if (sf.operand.toIndex()) |op| switch (ir.instructions.items(.tag)[@backingInt(op)]) {
            .add_with_overflow, .sub_with_overflow => {
                const lhs = ir.extraData(Ir.Bin, ir.instructions.items(.data)[@backingInt(op)].ty_pl.payload).data.lhs;
                return if (lhs.toIndex()) |i| @backingInt(i) else Ssa.no_tie;
            },
            else => {},
        };
    }
    var t: T = .{};
    Ssa.forEachOperand(ir, inst, &t);
    const first = t.first orelse return Ssa.no_tie;
    const i = first.toIndex() orelse return Ssa.no_tie;
    // A by-reference argument's register holds its address (`Home.ind`),
    // whose memory the lowering may still read after writing the result.
    if (ir.instructions.items(.tag)[@backingInt(i)] == .arg and cg.fn_ty.cc == .auto and
        cg.autoClass(ir.instructions.items(.data)[@backingInt(i)].arg.ty) == .memory) return Ssa.no_tie;
    return @backingInt(i);
}

/// The register to compute value `inst` in: its home, or rax for a value
/// kept in memory.
pub fn destReg(cg: *CodeGen, inst: Inst.Index) Reg {
    return switch (cg.homes[@backingInt(inst)]) {
        .reg => |r| r,
        else => .rax,
    };
}

/// Moves value `inst` of type `ty`, computed in `reg` and extended to 64
/// bits, to its home.
pub fn setResult(cg: *CodeGen, inst: Inst.Index, ty: Index, reg: Reg) Error!void {
    switch (cg.homes[@backingInt(inst)]) {
        .reg => |r| if (r != reg) try cg.e.mov(.qword, .{ .reg = r }, .{ .reg = reg }),
        .xmm => |x| try cg.e.movToXmm(sizeOf(Type.abiSize(cg.ip, ty)), x, .{ .reg = reg }),
        else => {
            const m = try cg.resultMem(inst, ty) orelse return;
            try cg.storeReg(m, reg, Type.abiSize(cg.ip, ty));
        },
    }
}

/// The XMM register to compute f32 or f64 value `inst` in: its home, or
/// xmm0 for a value kept in memory.
fn destXmm(cg: *CodeGen, inst: Inst.Index) Encoder.Xmm {
    return cg.xmmOf(inst.toRef()) orelse .xmm0;
}

/// Moves f32 or f64 value `inst` of type `ty`, computed in `x`, to its
/// home.
fn setXmm(cg: *CodeGen, inst: Inst.Index, ty: Index, x: Encoder.Xmm) Error!void {
    if (cg.xmmOf(inst.toRef())) |h| {
        if (h != x) try cg.e.movups(.{ .reg = h }, .{ .reg = x });
        return;
    }
    const m = try cg.resultMem(inst, ty) orelse return;
    try cg.storeXmm(m, x, Type.abiSize(cg.ip, ty));
}

/// Loads f32 or f64 value `inst` of type `ty` from `m` into its home.
/// Other values go through `destReg`.
fn loadResult(cg: *CodeGen, inst: Inst.Index, ty: Index, m: Mem) Error!void {
    if (cg.xmmOf(inst.toRef())) |x| return cg.e.movs(cg.sseType(ty).?, .{ .reg = x }, .{ .mem = m });
    const d = cg.destReg(inst);
    try cg.loadMem(d, m, ty);
    try cg.setResult(inst, ty, d);
}

/// A register holding `ref`, extended to 64 bits: its home, or `scratch`
/// loaded with it.
fn regOf(cg: *CodeGen, ref: Ref, scratch: Reg) Error!Reg {
    if (ref.toIndex()) |inst| switch (cg.homes[@backingInt(inst)]) {
        .reg => |r| return r,
        else => {},
    };
    try cg.load(scratch, ref);
    return scratch;
}

/// `ref` as the source of a 64-bit instruction: its register, an immediate
/// that fits sign-extended in 32 bits, its memory if it is 8 bytes, or
/// `scratch` loaded with it.
fn srcOperand(cg: *CodeGen, ref: Ref, scratch: Reg) Error!Encoder.Operand {
    switch (try cg.locOf(ref)) {
        .reg => |r| return .{ .reg = r },
        .imm => |v| if (std.math.cast(i32, @as(i64, @bitCast(v)))) |x| return .{ .imm = x },
        .mem => |m| if (Type.abiSize(cg.ip, cg.typeOf(ref)) == 8) return .{ .mem = m },
        else => {},
    }
    try cg.load(scratch, ref);
    return .{ .reg = scratch };
}

/// The memory pointer `ptr` points to. May use r10.
fn ptrMem(cg: *CodeGen, ptr: Ref) Error!Mem {
    switch (try cg.locOf(ptr)) {
        .addr => |m| return m,
        .reg => |r| return Mem.at(r, 0),
        else => {
            try cg.load(.r10, ptr);
            return Mem.at(.r10, 0);
        },
    }
}

/// `d = ptr + off`.
fn addrPlus(cg: *CodeGen, d: Reg, ptr: Ref, off: u64) Error!void {
    switch (try cg.locOf(ptr)) {
        .addr => |m| try cg.e.lea(.qword, d, offsetMem(m, off)),
        .reg => |r| if (off != 0)
            try cg.e.lea(.qword, d, Mem.at(r, @intCast(off)))
        else if (r != d)
            try cg.e.mov(.qword, .{ .reg = d }, .{ .reg = r }),
        else => {
            try cg.load(d, ptr);
            if (off != 0) try cg.e.alu(.add, .qword, .{ .reg = d }, .{ .imm = @intCast(off) });
        },
    }
}

/// Stores the `size`-byte value `ref` to `m`, which is not based on rax.
fn storeVal(cg: *CodeGen, m: Mem, ref: Ref, size: u64) Error!void {
    if (cg.xmmOf(ref)) |x| return cg.storeXmm(m, x, size);
    switch (try cg.locOf(ref)) {
        .reg => |r| return cg.storeReg(m, r, size),
        .imm => |v| if (size < 8 or std.math.cast(i32, @as(i64, @bitCast(v))) != null)
            return cg.e.mov(sizeOf(size), .{ .mem = m }, .{ .imm = @bitCast(v) }),
        else => {},
    }
    try cg.load(.rax, ref);
    try cg.storeReg(m, .rax, size);
}

/// `d = base + index * size`, where `base` is a pointer or, if `is_slice`,
/// a slice. Uses rcx.
fn elemAddrTo(cg: *CodeGen, d: Reg, is_slice: bool, base: Ref, index: Ref, size: u64) Error!void {
    const base_reg: Reg = if (is_slice) blk: {
        if (cg.pairOf(base)) |p| break :blk p.lo;
        try cg.e.mov(.qword, .{ .reg = d }, .{ .mem = try cg.memOf(base) });
        break :blk d;
    } else try cg.regOf(base, d);
    if (index.toInterned() != null) switch (try cg.locOf(index)) {
        .imm => |v| if (std.math.cast(i32, @as(i64, @bitCast(v)) *% @as(i64, @intCast(size)))) |off| {
            if (off != 0) return cg.e.lea(.qword, d, Mem.at(base_reg, off));
            if (base_reg != d) try cg.e.mov(.qword, .{ .reg = d }, .{ .reg = base_reg });
            return;
        },
        else => {},
    };
    const idx = try cg.regOf(index, .rcx);
    const scale: ?Mem.Scale = switch (size) {
        1 => .@"1",
        2 => .@"2",
        4 => .@"4",
        8 => .@"8",
        else => null,
    };
    if (size == 0) {
        if (base_reg != d) try cg.e.mov(.qword, .{ .reg = d }, .{ .reg = base_reg });
    } else if (scale) |sc| {
        try cg.e.lea(.qword, d, .{ .base = .{ .reg = base_reg }, .index = .{ .reg = idx, .scale = sc } });
    } else {
        try cg.e.imul(.qword, .rcx, .{ .reg = idx }, @intCast(size));
        try cg.e.lea(.qword, d, .{ .base = .{ .reg = base_reg }, .index = .{ .reg = .rcx } });
    }
}

/// Sets the flags for condition `inst` (a compare, `is_err`, or `is_null`
/// and their negations) and returns the condition code that holds when it
/// is true.
fn condFlags(cg: *CodeGen, inst: Inst.Index) Error!Encoder.Cond {
    const ip = cg.ip;
    const tag = cg.ir.instructions.items(.tag)[@backingInt(inst)];
    const data = cg.ir.instructions.items(.data)[@backingInt(inst)];
    switch (tag) {
        .reduce => return vector.condFlags(cg, inst),
        // The negated condition's flags if the branch computes it too
        // (`Ssa.plan`), else a test of the bool.
        .not => {
            const x = data.ty_op.operand;
            if (x.toIndex()) |xi| if (cg.homes[@backingInt(xi)] == .fused) return (try cg.condFlags(xi)).negate();
            const r = try cg.regOf(x, .rax);
            try cg.e.@"test"(.byte, .{ .reg = r }, .{ .reg = r });
            return .e;
        },
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => {
            if (data.bin_op.lhs.toIndex()) |bit| if (cg.homes[@backingInt(bit)] == .fused) {
                // An overflow bit left in the flags.
                return if (Ssa.ovfBitCmp(cg.ir, cg.ip, inst, @backingInt(bit)).?) cg.ovf_cc else cg.ovf_cc.negate();
            };
            if (floatCc(tag)) |cc| if (cg.inFloat(cg.typeOf(data.bin_op.lhs))) {
                try cg.floatCompare(tag, cg.sseType(cg.typeOf(data.bin_op.lhs)).?, data.bin_op.lhs, data.bin_op.rhs);
                return cc;
            };
            const s = cg.signed(cg.typeOf(data.bin_op.lhs));
            const rhs = try cg.srcOperand(data.bin_op.rhs, .rcx);
            const lhs = try cg.regOf(data.bin_op.lhs, .rax);
            try cg.e.alu(.cmp, .qword, .{ .reg = lhs }, rhs);
            return switch (tag) {
                .cmp_lt => if (s) .l else .b,
                .cmp_lte => if (s) .le else .be,
                .cmp_eq => .e,
                .cmp_gte => if (s) .ge else .ae,
                .cmp_gt => if (s) .g else .a,
                .cmp_neq => .ne,
                else => unreachable,
            };
        },
        .is_err, .is_non_err => {
            const lo: ?Reg = if (cg.pairOf(data.un_op)) |p| p.lo else switch (try cg.locOf(data.un_op)) {
                .reg => |r| r,
                else => null,
            };
            if (lo) |r| {
                try cg.e.@"test"(.word, .{ .reg = r }, .{ .reg = r });
                return if (tag == .is_err) .ne else .e;
            }
            const src = try cg.memOf(data.un_op);
            try cg.e.alu(.cmp, .word, .{ .mem = src }, .{ .imm = 0 });
            return if (tag == .is_err) .ne else .e;
        },
        .is_null, .is_non_null => {
            const opt_ty = cg.typeOf(data.un_op);
            const child = Type.childType(ip, opt_ty);
            if (Type.optionalReprIsPtr(ip, child)) {
                const r = try cg.regOf(data.un_op, .rax);
                try cg.e.@"test"(.qword, .{ .reg = r }, .{ .reg = r });
            } else if (cg.pairOf(data.un_op)) |p| {
                // An optional slice: a null `ptr`.
                try cg.e.@"test"(.qword, .{ .reg = p.lo }, .{ .reg = p.lo });
            } else if (cg.optInGpr(opt_ty) and try cg.locOf(data.un_op) == .reg) {
                // The flag above the payload's bytes (`optInGpr`).
                const r = (try cg.locOf(data.un_op)).reg;
                const flag: u6 = @intCast(8 * Type.optionalFlagOffset(ip, opt_ty));
                if (flag < 31) {
                    try cg.e.@"test"(.dword, .{ .reg = r }, .{ .imm = @as(i32, 1) << @intCast(flag) });
                } else {
                    try cg.e.mov(.qword, .{ .reg = .rax }, .{ .reg = r });
                    try cg.e.shift(.shr, .qword, .{ .reg = .rax }, flag);
                    try cg.e.@"test"(.byte, .{ .reg = .rax }, .{ .reg = .rax });
                }
            } else if (Type.optionalReprIsPayload(ip, child)) {
                // A slice's `ptr` or an error code; zero is null.
                const src = try cg.memOf(data.un_op);
                try cg.e.alu(.cmp, if (Type.isSlice(ip, child)) .qword else .word, .{ .mem = src }, .{ .imm = 0 });
            } else {
                const src = try cg.memOf(data.un_op);
                try cg.e.alu(.cmp, .byte, .{ .mem = offsetMem(src, Type.optionalFlagOffset(ip, opt_ty)) }, .{ .imm = 0 });
            }
            return if (tag == .is_null) .e else .ne;
        },
        else => unreachable,
    }
}

/// Calls panic handler `target` from cold code through a chain of stubs,
/// one per call the backend inlined that is open here, so that the stack
/// trace shows the frames those calls would have had (docs/slop/architecture.md,
/// "Synthetic panic frames"): the call itself is at the outermost such
/// call's site, in its caller, and the stubs after the epilogue
/// (`emitStubs`) are at each next site inward, the last at the check.
/// Without such calls open, or past the stubs' room, calls `target`.
fn panicThroughStubs(cg: *CodeGen, target: SymbolKey) Error!void {
    const open = cg.dbg_open.items;
    var first: ?usize = null;
    var depth: u32 = 0;
    for (open, 0..) |o, i| if (o.backend) {
        if (first == null) first = i;
        depth += 1;
    };
    // `Atom.Unwind.epilogue` counts the stubs and probes in 16 bits.
    if (first == null or cg.stub_bytes + 5 * depth > 0xfe00) return cg.e.call(.{ .sym = target });
    cg.stub_bytes += 5 * depth;
    const b = first.?;
    const label = try cg.e.newLabel();
    try cg.stub_chains.append(cg.gpa, .{ .label = label, .target = target, .open_start = @intCast(cg.stub_open.items.len), .open_len = @intCast(open.len), .line = cg.dbg_line, .column = cg.dbg_column });
    try cg.stub_open.appendSlice(cg.gpa, open);
    // Each stub's call pushes 8 bytes; the handler is entered as from an
    // aligned call.
    if (depth % 2 == 1) try cg.e.alu(.sub, .qword, .{ .reg = .rsp }, .{ .imm = 8 });
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
    try cg.e.call(.{ .label = label });
}

/// The stubs of the panic calls `panicThroughStubs` made, after the
/// epilogue: frameless code whose CFA is rsp + 8 (`Atom.Unwind.epilogue`).
/// Stub k is in entries copying the inlined calls open from the k-th
/// backend-inlined call to the next one (from the function's own for the
/// first), at the next one's site, and calls stub k + 1, which follows; the
/// last is at the check and calls the handler.
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
                const next = try cg.e.newLabel();
                try cg.e.call(.{ .label = next });
                cg.e.bind(next);
            } else {
                try cg.e.line(ch.line, ch.column);
                try cg.e.call(.{ .sym = ch.target });
            }
            i = end;
        }
        const end_pc: u32 = @intCast(cg.e.code.items.len);
        for (cg.dbg_inlines.items[clones_start..]) |*in| in.high = end_pc;
    }
    if (cg.stub_chains.items.len != 0) try cg.e.switchLines(0, 0);
}

/// The function's epilogue, at `ret_label`: restores the saved registers
/// and returns.
fn epilogue(cg: *CodeGen) Error!void {
    if (cg.ret_label == null) cg.ret_label = try cg.e.newLabel();
    cg.e.bind(cg.ret_label.?);
    cg.ret_bound = true;
    // The epilogue belongs to the closing brace, as in upstream's line tables.
    try cg.e.line(cg.ir.rbrace_line, cg.ir.rbrace_column);
    if (cg.win_save) |save| {
        try cg.e.mov(.qword, .{ .reg = .rsi }, .{ .mem = Mem.at(.rbp, save) });
        try cg.e.mov(.qword, .{ .reg = .rdi }, .{ .mem = Mem.at(.rbp, save + 8) });
        for (win_saved_xmms, 0..) |x, i| try cg.e.movups(.{ .reg = x }, .{ .mem = Mem.at(.rbp, save + 16 + 16 * @as(i32, @intCast(i))) });
    }
    if (cg.saved != 0) {
        try cg.e.lea(.qword, .rsp, Mem.at(.rbp, -8 * @as(i32, @popCount(cg.saved))));
        var i: usize = alloc_regs.len;
        while (i > 0) {
            i -= 1;
            if (cg.saved >> @intCast(i) & 1 != 0) try cg.e.pop(alloc_regs[i]);
        }
    } else {
        try cg.e.mov(.qword, .{ .reg = .rsp }, .{ .reg = .rbp });
    }
    try cg.e.pop(.rbp);
    try cg.e.ret();
    cg.ret_end = @intCast(cg.e.code.items.len);
}

// ---------------------------------------------------------------------------
// Instructions

/// Emits the SSA blocks in `Ssa.order`: the others in layout order, then
/// the cold ones, each with the debug state it has in place.
fn emitBlocks(cg: *CodeGen) Error!void {
    const f = cg.ssa;
    const order = f.order.items;
    for (cg.labels) |*l| l.* = try cg.e.newLabel();
    var k: usize = 0; // the next block in `order`
    for (f.layout.items, 0..) |block, i| {
        if (i != 0 and f.fwd.items[@backingInt(block)] != block) continue;
        if (f.cold.items[@backingInt(block)]) {
            try cg.cold_starts.append(cg.gpa, .{ .line = cg.dbg_line, .column = cg.dbg_column, .open_start = @intCast(cg.cold_open.items.len), .open_len = @intCast(cg.dbg_open.items.len) });
            try cg.cold_open.appendSlice(cg.gpa, cg.dbg_open.items);
            continue;
        }
        k += 1;
        try cg.genBlock(block, if (k < order.len) order[k] else .none);
    }
    if (k == order.len) return;
    // Inlined calls left open by the code above stay as they are.
    cg.in_cold = true;
    cg.dbg_open.clearRetainingCapacity();
    for (order[k..], cg.cold_starts.items, k..) |block, s, i| {
        // The inlined calls open at the block get entries for its code,
        // with the same call information.
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
/// were generated: upstream's Debug code keeps such a load, so the
/// declaration's data is linked, and an undefined symbol it names is an
/// error (`_ = p.*` for `var p: *u8 = &undefined_extern`).
fn keepSymbols(cg: *CodeGen, inst: Ir.Inst.Index) Error!void {
    var refs: std.ArrayList(Ir.Inst.Ref) = .empty;
    defer refs.deinit(cg.gpa);
    const Collect = struct {
        refs: *std.ArrayList(Ir.Inst.Ref),
        gpa: std.mem.Allocator,
        failed: *bool,
        pub fn use(c: @This(), ref: Ir.Inst.Ref) void {
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
                _ = try ptrTarget(cg.emit, v);
            },
            .uav => |u| switch (ip.keyTag(u.val)) {
                .extern_var => _ = try cg.emit.useExtern(ip.stringSlice(ip.keyPayload(.extern_var, u.val).name), false),
                .extern_func => _ = try cg.emit.useExtern(ip.stringSlice(ip.keyPayload(.extern_func, u.val).name), false),
                else => {},
            },
            else => {},
        }
    }
}

fn genBlock(cg: *CodeGen, block: Ssa.Block.Index, next: Ssa.Block.Index) Error!void {
    cg.e.bind(cg.labels[@backingInt(block)]);
    cg.cur_block = @backingInt(block);
    if (cg.ssa.covered.items[@backingInt(block)]) try cg.coverPoint(block == cg.ssa.layout.items[0]);
    const b = cg.ssa.blocks.items[@backingInt(block)];
    const cl = cg.ssa.clobbers.items;
    for (cg.ssa.blockInsts(block), b.start..) |inst, idx| {
        if (cg.homes[@backingInt(inst)] == .dead) {
            try cg.keepSymbols(inst);
            continue;
        }
        const q = Ssa.valuePos(idx);
        if (cg.split_vals.items.len != 0 and !std.meta.eql(cl[q], cl[q - 1])) try cg.genSplit(inst, q) else try cg.genInst(inst);
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
            // Not for a block nothing reads (one the rewrite rules
            // replaced with its constant result).
            if (tag == .br and cg.ssa.live.items(.uses)[@backingInt(data.br.block_inst)] != 0) switch (cg.homes[@backingInt(data.br.block_inst)]) {
                .slot => |off| if (!cg.inSlot(data.br.operand, off)) try cg.copyTo(Mem.at(.rbp, off), data.br.operand),
                .reg => |r| try cg.load(r, data.br.operand),
                .regs => |p| try cg.loadRegs(p, data.br.operand),
                .xmm => |x| try cg.loadXmm(x, try cg.valOf(data.br.operand)),
                else => {},
            };
            try cg.jumpTo(term.succ[0], next);
        },
        .branch => {
            try cg.checkNaked(tag);
            const cond = data.pl_op.operand;
            const fused = if (cond.toIndex()) |c| cg.homes[@backingInt(c)] == .fused else false;
            const cc: Encoder.Cond = if (fused) try cg.condFlags(cond.toIndex().?) else cc: {
                const r = try cg.regOf(cond, .rax);
                try cg.e.@"test"(.byte, .{ .reg = r }, .{ .reg = r });
                break :cc .ne;
            };
            // Fall through to whichever side follows.
            if (cg.ssa.fwd.items[term.succ[1]] == next) return cg.e.jcc(cc, .{ .label = cg.blockLabel(term.succ[0]) });
            try cg.e.jcc(cc.negate(), .{ .label = cg.blockLabel(term.succ[1]) });
            try cg.jumpTo(term.succ[0], next);
        },
        .switch_br => {
            try cg.checkNaked(tag);
            try cg.switchBr(data, term);
            try cg.jumpTo(term.succ[1], next);
        },
        .ret => {
            try cg.checkNaked(tag);
            try cg.ret(data.un_op, next);
        },
        .unreach => try cg.e.ud2(),
    }
}

/// Whether `ref` is a value whose home is slot `off`.
fn inSlot(cg: *CodeGen, ref: Ref, off: i32) bool {
    const v = ref.toIndex() orelse return false;
    return switch (cg.homes[@backingInt(v)]) {
        .slot => |o| o == off,
        else => false,
    };
}

/// Jumps to block `target` unless it goes to `next`, the block emitted
/// next.
fn jumpTo(cg: *CodeGen, target: u32, next: Ssa.Block.Index) Error!void {
    if (cg.ssa.fwd.items[target] != next) try cg.e.jmp(.{ .label = cg.blockLabel(target) });
}

/// The label of the code a branch to block `target` goes to.
fn blockLabel(cg: *CodeGen, target: u32) Encoder.Label {
    return cg.labels[@backingInt(cg.ssa.fwd.items[target])];
}

/// Emits a value, from its IR instruction.
fn genInst(cg: *CodeGen, inst: Inst.Index) Error!void {
    const ip = cg.ip;
    const ir = cg.ir;
    const tag = ir.instructions.items(.tag)[@backingInt(inst)];
    const data = ir.instructions.items(.data)[@backingInt(inst)];
    try cg.checkNaked(tag);
    switch (tag) {
        .arg => {},
        // Only in bodies lowered for the comptime evaluator.
        .comptime_tick, .comptime_quota, .comptime_dep, .comptime_effect, .comptime_exit => unreachable,
        .dbg_stmt => {
            cg.dbg_line = data.dbg_stmt.line;
            cg.dbg_column = data.dbg_stmt.column;
            try cg.e.line(data.dbg_stmt.line, data.dbg_stmt.column);
        },
        .dbg_inline_begin => try cg.beginInline(data.dbg_inline.func, ir.extraData(Ir.DbgInline, data.dbg_inline.payload).data),
        .dbg_inline_end => try cg.endInline(),
        .alloc => {
            // An inferred alloc whose initializer never completes.
            if (data.ty == .none) return;
            if (cg.const_alias.count() != 0) if (cg.const_alias.get(@backingInt(inst))) |v| {
                // The constant's own memory, as an address in a register
                // (a `.reg` home is a promoted variable's).
                const d = cg.destReg(inst);
                try cg.e.lea(.qword, d, try cg.memOf(.fromInterned(v)));
                if (cg.homes[@backingInt(inst)] == .reg) {
                    cg.homes[@backingInt(inst)] = .{ .reg_addr = .{ .base = d, .off = 0 } };
                    return;
                }
                return cg.setResult(inst, data.ty, d);
            };
            if (cg.ref_alias.count() != 0 and cg.ref_alias.contains(@backingInt(inst))) {
                // In its register as an address (a `.reg` home is a
                // promoted variable's), or in a slot like an over-aligned
                // alloc's.
                const arg = cg.copy_of.get(@backingInt(inst)).?;
                if (cg.addr_base[@backingInt(inst)] != no_base and cg.homes[@backingInt(inst)] == .none and cg.homes[arg] == .ind) {
                    cg.homes[@backingInt(inst)] = .{ .reg_addr = .{ .base = cg.homes[arg].ind, .off = 0 } };
                    return;
                }
                const d = cg.destReg(inst);
                switch (cg.homes[arg]) {
                    .ind => |r| try cg.e.mov(.qword, .{ .reg = d }, .{ .reg = r }),
                    .slot => |off| try cg.e.lea(.qword, d, Mem.at(.rbp, off)),
                    else => unreachable,
                }
                if (cg.homes[@backingInt(inst)] == .reg) {
                    cg.homes[@backingInt(inst)] = .{ .reg_addr = .{ .base = d, .off = 0 } };
                    return;
                }
                return cg.setResult(inst, data.ty, d);
            }
            // A variable in registers.
            switch (cg.homes[@backingInt(inst)]) {
                .reg, .regs, .xmm => return,
                else => {},
            }
            const info = Type.ptrInfo(ip, data.ty);
            const size = @max(Type.abiSize(ip, info.child), 1);
            const alignment = cg.allocAlignment(data.ty);
            if (inst == cg.rvo_alloc) {
                // The result's memory, through the pointer the caller passed.
                cg.homes[@backingInt(inst)] = .{ .slot = cg.ret_ptr_slot.? };
                return;
            }
            if (cg.payload_region.count() != 0) if (cg.payload_region.get(@backingInt(inst))) |r| {
                // The error union its initializer unwraps, around it.
                const eu_ty = ir.typeOfIndex(@fromBackingInt(r[0]), ip);
                const region = try cg.allocSlot(Type.abiSize(ip, eu_ty), Type.abiAlignment(ip, eu_ty));
                const off = region + @as(i32, @intCast(Type.errorUnionLayout(ip, eu_ty).payload_offset));
                cg.homes[r[0]] = .{ .slot = region };
                cg.homes[r[1]] = .{ .slot = off };
                cg.homes[@backingInt(inst)] = .{ .frame_addr = off };
                return;
            };
            if (cg.copy_of.count() != 0) if (cg.copy_of.get(@backingInt(inst))) |v| if (v != no_copy) switch (cg.homes[v]) {
                // The memory of its initializer, already in place.
                .slot => |off| if (@rem(off, @as(i32, @intCast(alignment))) == 0) {
                    cg.homes[@backingInt(inst)] = .{ .frame_addr = off };
                    return;
                },
                else => {},
            };
            if (alignment <= 16) {
                cg.homes[@backingInt(inst)] = .{ .frame_addr = try cg.allocSlot(size, alignment) };
                return;
            }
            // rbp is only 16-byte aligned: align the address at run time
            // within a buffer large enough for any rbp, and keep it in a slot.
            const buf = try cg.allocSlot(size + alignment - 16, 16);
            const home = try cg.allocSlot(8, 8);
            try cg.e.lea(.qword, .rax, Mem.at(.rbp, buf + @as(i32, @intCast(alignment - 16))));
            try cg.e.alu(.@"and", .qword, .{ .reg = .rax }, .{ .imm = -@as(i64, @intCast(alignment)) });
            try cg.e.mov(.qword, .{ .mem = Mem.at(.rbp, home) }, .{ .reg = .rax });
            cg.homes[@backingInt(inst)] = .{ .slot = home };
        },
        .load => {
            const ty = data.ty_op.ty;
            if (cg.homes[@backingInt(inst)] == .deferred) return;
            if (cg.live) {
                // A forwarded constant is the value stored (`Live.fwd`).
                const w = cg.ssa.live.items(.fwd)[@backingInt(inst)];
                if (w != Ssa.no_tie) {
                    cg.homes[@backingInt(inst)] = cg.homes[w];
                    return;
                }
            }
            if (cg.varReg(data.ty_op.operand)) |r| return cg.setResult(inst, ty, r);
            if (cg.varXmm(data.ty_op.operand)) |x| return cg.setXmm(inst, ty, x);
            // A vector.
            if (cg.xmmOf(inst.toRef())) |x| if (!cg.passInRegs(ty)) return cg.e.movups(.{ .reg = x }, .{ .mem = try cg.ptrMem(data.ty_op.operand) });
            if (cg.pairOf(data.ty_op.operand)) |_| {
                // A variable in registers.
                if (cg.pairOf(inst.toRef())) |d| return cg.loadRegs(d, data.ty_op.operand);
                return cg.copyTo((try cg.resultMem(inst, ty)) orelse return, data.ty_op.operand);
            }
            if (cg.pairOf(inst.toRef())) |d| {
                const m = try cg.ptrMem(data.ty_op.operand);
                try cg.e.mov(.qword, .{ .reg = d.lo }, .{ .mem = m });
                return cg.e.mov(.qword, .{ .reg = d.hi }, .{ .mem = offsetMem(m, 8) });
            }
            if (cg.passInRegs(ty)) return cg.loadResult(inst, ty, try cg.ptrMem(data.ty_op.operand));
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.copyMem(dst, try cg.ptrMem(data.ty_op.operand), Type.abiSize(ip, data.ty_op.ty));
        },
        .store => {
            const val = data.bin_op.rhs;
            const size = Type.abiSize(ip, cg.typeOf(val));
            if (size == 0) return;
            // Built in place (`planDeferred`).
            if (cg.in_place.count() != 0) if (val.toIndex()) |v| if (cg.in_place.contains(@backingInt(v))) return;
            // A `*const` alloc that is its initializer's memory (`planCopies`).
            if (cg.ref_alias.count() != 0) if (data.bin_op.lhs.toIndex()) |a| if (cg.ref_alias.contains(@backingInt(a))) return;
            if (cg.const_alias.count() != 0) if (data.bin_op.lhs.toIndex()) |a| if (cg.const_alias.contains(@backingInt(a))) return;
            if (cg.copy_of.count() != 0) if (data.bin_op.lhs.toIndex()) |a| if (val.toIndex()) |v| switch (cg.homes[@backingInt(a)]) {
                .frame_addr => |off| if (cg.homes[@backingInt(v)] == .slot and cg.homes[@backingInt(v)].slot == off) return,
                else => {},
            };
            if (cg.varReg(data.bin_op.lhs)) |r| return cg.load(r, val);
            if (cg.varXmm(data.bin_op.lhs)) |x| return cg.loadXmm(x, try cg.valOf(val));
            if (cg.pairOf(data.bin_op.lhs)) |p| return cg.loadRegs(p, val); // a variable
            if (cg.passInRegs(cg.typeOf(val))) return cg.storeVal(try cg.ptrMem(data.bin_op.lhs), val, size);
            // Not based on a register `copyTo` uses.
            const dst = switch (try cg.locOf(data.bin_op.lhs)) {
                .addr => |m| m,
                else => blk: {
                    try cg.load(.r10, data.bin_op.lhs);
                    break :blk Mem.at(.r10, 0);
                },
            };
            if (val.toInterned()) |v| if (ip.keyTag(v) == .undef) return cg.fillMem(dst, size, 0xaa);
            try cg.copyTo(dst, val);
        },

        .add_wrap, .sub_wrap, .mul_wrap, .bit_and, .bit_or, .xor, .shl, .shr, .div_trunc, .div_floor, .div_ceil, .rem, .mod => {
            const ty = cg.typeOf(data.bin_op.lhs);
            if (tag == .mul_wrap) if (cg.mulWide(inst)) |fs| {
                try cg.loadFactor(.rax, fs[0]);
                try cg.loadFactor(.rcx, fs[1]);
                try cg.e.unary(.mul, .qword, .{ .reg = .rcx });
                if (cg.pairOf(inst.toRef())) |p| {
                    try cg.e.mov(.qword, .{ .reg = p.lo }, .{ .reg = .rax });
                    return cg.e.mov(.qword, .{ .reg = p.hi }, .{ .reg = .rdx });
                }
                const m = try cg.resultMem(inst, ty) orelse return;
                try cg.e.mov(.qword, .{ .mem = m }, .{ .reg = .rax });
                return cg.e.mov(.qword, .{ .mem = offsetMem(m, 8) }, .{ .reg = .rdx });
            };
            if (tag == .shr) if (cg.mulHigh(inst)) |m| {
                if (cg.pairOf(m.toRef())) |p| {
                    try cg.e.mov(.qword, .{ .reg = .rax }, .{ .reg = p.hi });
                } else try cg.e.mov(.qword, .{ .reg = .rax }, .{ .mem = offsetMem(try cg.memOf(m.toRef()), 8) });
                if (cg.pairOf(inst.toRef())) |p| {
                    try cg.e.mov(.qword, .{ .reg = p.lo }, .{ .reg = .rax });
                    return cg.e.alu(.xor, .dword, .{ .reg = p.hi }, .{ .reg = p.hi });
                }
                const d = try cg.resultMem(inst, ty) orelse return;
                try cg.e.mov(.qword, .{ .mem = d }, .{ .reg = .rax });
                return cg.e.mov(.qword, .{ .mem = offsetMem(d, 8) }, .{ .imm = 0 });
            };
            if (ip.keyTag(ty) == .vector_type) return vector.gen(cg, inst, tag, data);
            if (cg.isFloat(ty)) return cg.genFloat(inst, tag, data);
            if (cg.isWideInt(ty)) return cg.genWide(inst, tag, data);
            switch (tag) {
                .add_wrap, .sub_wrap, .mul_wrap, .bit_and, .bit_or, .xor, .shl, .shr => {
                    const d = cg.destReg(inst);
                    if (tag == .bit_or and cg.rotates.count() != 0) if (cg.rotates.get(@backingInt(inst))) |rot| {
                        try cg.load(d, rot.x);
                        try cg.e.shift(.rol, sizeOf(Type.intInfo(ip, ty).bits / 8), .{ .reg = d }, rot.k);
                        return cg.setResult(inst, ty, d);
                    };
                    try cg.intOp(d, tag, ty, data.bin_op.lhs, data.bin_op.rhs);
                    try cg.setResult(inst, ty, d);
                },
                else => {
                    try cg.binOp(tag, ty, data.bin_op.lhs, data.bin_op.rhs);
                    try cg.setResult(inst, ty, .rax);
                },
            }
        },
        .add_with_overflow, .sub_with_overflow, .mul_with_overflow => if (cg.isWideInt(cg.typeOf(ir.extraData(Ir.Bin, data.ty_pl.payload).data.lhs)))
            try cg.genWide(inst, tag, data)
        else
            try cg.overflowOp(inst, tag, data),
        .add_float, .sub_float, .mul_float, .div_float => if (ip.keyTag(cg.typeOf(data.bin_op.lhs)) == .vector_type)
            try vector.gen(cg, inst, tag, data)
        else
            try cg.genFloat(inst, tag, data),
        .cmp_vector, .reduce, .select, .shuffle, .min_int, .max_int => try vector.gen(cg, inst, tag, data),
        .min_float, .max_float, .neg_float, .abs_float, .sqrt => if (vector.lowers(cg, inst))
            try vector.gen(cg, inst, tag, data)
        else
            try cg.genFloat(inst, tag, data),
        .sin, .cos, .tan, .exp, .exp2, .log, .log2, .log10, .floor, .ceil, .round, .trunc_float => try cg.genFloat(inst, tag, data),
        .mul_add, .float_cast, .float_from_int, .int_from_float => try cg.genFloat(inst, tag, data),
        .not => {
            if (cg.homes[@backingInt(inst)] == .fused) return;
            const ty = data.ty_op.ty;
            if (ip.keyTag(ty) == .vector_type) return vector.gen(cg, inst, tag, data);
            if (cg.isWideInt(ty)) return cg.genWide(inst, tag, data);
            const d = cg.destReg(inst);
            try cg.load(d, data.ty_op.operand);
            if (ty == .bool_type) {
                try cg.e.alu(.xor, .dword, .{ .reg = d }, .{ .imm = 1 });
            } else {
                try cg.e.unary(.not, .qword, .{ .reg = d });
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
            if (atomic128.is128(cg, ty)) return atomic128.load(cg, inst, data);
            try cg.load(.rcx, data.ty_op.operand);
            const d = cg.destReg(inst);
            try cg.loadMem(d, Mem.at(.rcx, 0), ty);
            try cg.setResult(inst, ty, d);
        },
        .atomic_store => {
            if (atomic128.is128(cg, cg.typeOf(data.bin_op.rhs))) return atomic128.store(cg, data);
            const size = Type.abiSize(ip, cg.typeOf(data.bin_op.rhs));
            try cg.load(.rcx, data.bin_op.lhs);
            try cg.load(.rax, data.bin_op.rhs);
            try cg.e.xchg(sizeOf(size), .{ .mem = Mem.at(.rcx, 0) }, .rax);
        },
        .atomic_rmw => if (atomic128.is128(cg, data.ty_pl.ty)) try atomic128.rmw(cg, inst, data) else try cg.atomicRmw(inst, data),
        .cmpxchg => {
            const x = ir.extraData(Ir.Cmpxchg, data.ty_pl.payload).data;
            const elem_ty = cg.typeOf(x.expected);
            if (atomic128.is128(cg, elem_ty)) return atomic128.cmpxchg(cg, inst, data);
            const size = sizeOf(Type.abiSize(ip, elem_ty));
            try cg.load(.rcx, x.ptr);
            try cg.load(.rax, x.expected);
            try cg.load(.rdx, x.new);
            try cg.e.lockCmpxchg(size, Mem.at(.rcx, 0), .rdx);
            const dst = try cg.resultMem(inst, data.ty_pl.ty) orelse return;
            if (Type.optionalReprIsPtr(ip, elem_ty)) {
                // Null (0) on success, else the pointer found.
                try cg.e.mov(.dword, .{ .reg = .r8 }, .{ .imm = 0 });
                try cg.e.cmov(.ne, .qword, .r8, .{ .reg = .rax });
                try cg.storeReg(dst, .r8, 8);
            } else {
                try cg.e.setcc(.ne, .{ .mem = offsetMem(dst, Type.optionalFlagOffset(ip, data.ty_pl.ty)) });
                try cg.storeReg(dst, .rax, Type.abiSize(ip, elem_ty));
            }
        },
        .ret_addr, .frame_addr => {
            const d = cg.destReg(inst);
            if (tag == .ret_addr) {
                try cg.e.mov(.qword, .{ .reg = d }, .{ .mem = Mem.at(.rbp, 8) });
            } else {
                try cg.e.mov(.qword, .{ .reg = d }, .{ .reg = .rbp });
            }
            try cg.setResult(inst, .usize_type, d);
        },
        .extern_ptr => {
            const name = ip.stringSlice(@fromBackingInt(data.ty_pl.payload));
            const weak = Type.class(ip, data.ty_pl.ty) == .optional;
            // Analyzes the compiler_rt function the slot will point to.
            _ = try cg.emit.requestCompilerRtExport(name);
            const slot = try cg.emit.useExtern(name, weak);
            const d = cg.destReg(inst);
            try cg.e.mov(.qword, .{ .reg = d }, .{ .mem = Mem.sym(slot, 0) });
            try cg.setResult(inst, data.ty_pl.ty, d);
        },
        .extern_pcrel => {
            const name = ip.stringSlice(@fromBackingInt(data.ty_pl.payload));
            const weak = Type.class(ip, data.ty_pl.ty) == .optional;
            const d = cg.destReg(inst);
            // An undefined weak symbol in an image is null.
            if (try cg.emit.pcrelTarget(name, weak)) |key| try cg.e.lea(.qword, d, Mem.sym(key, 0)) else try cg.e.mov(.dword, .{ .reg = d }, .{ .imm = 0 });
            try cg.setResult(inst, data.ty_pl.ty, d);
        },
        .c_va_start => try cg.cVaStart(inst, data.ty),
        .c_va_arg => try cg.cVaArg(inst, data.ty_op.ty, data.ty_op.operand),
        .c_va_copy => {
            const dst = try cg.resultMem(inst, data.ty_op.ty) orelse return;
            try cg.load(.rdx, data.ty_op.operand);
            try cg.copyMem(dst, Mem.at(.rdx, 0), 24);
        },
        .err_return_trace => {
            const d = cg.destReg(inst);
            try cg.loadTrace(d);
            try cg.setResult(inst, data.ty, d);
        },
        .set_err_return_trace => {
            if (cg.trace_slot == null) cg.trace_slot = try cg.allocSlot(8, 8);
            try cg.load(.rax, data.un_op);
            try cg.e.mov(.qword, .{ .mem = Mem.at(.rbp, cg.trace_slot.?) }, .{ .reg = .rax });
        },
        .save_err_return_trace_index => {
            if (data.ty_pl.ty == .none) return;
            if (cg.trace_slot) |off| {
                try cg.e.mov(.qword, .{ .reg = .rax }, .{ .mem = Mem.at(.rbp, off) });
                try cg.e.mov(.qword, .{ .reg = .rax }, .{ .mem = Mem.at(.rax, @intCast(Type.fieldOffset(ip, data.ty_pl.ty, data.ty_pl.payload))) });
            } else {
                try cg.e.mov(.dword, .{ .reg = .rax }, .{ .imm = 0 });
            }
            try cg.setResult(inst, .usize_type, .rax);
        },
        .tls_ptr, .extern_tls => {
            const t: Emit.TlsTarget = if (tag == .tls_ptr)
                .{ .key = try cg.emit.navKey(@fromBackingInt(data.ty_pl.payload)), .local = true }
            else
                try cg.emit.tlsTarget(ip.stringSlice(@fromBackingInt(data.ty_pl.payload)));
            const d = cg.destReg(inst);
            // Position-independent code that may end up in a shared object
            // asks `__tls_get_addr` for the module's block, or for another
            // module's variable: a call (`clobbers`). An executable has
            // its own variables in its static block, and finds another
            // module's through the GOT.
            if (t.slot) {
                try cg.e.leaThreadLocalSlot(d, t.key);
            } else if (t.local) {
                if (cg.emit.pic == .pic) try cg.e.leaThreadLocalDynamic(d, t.key, try cg.emit.tlsGetAddr()) else try cg.e.leaThreadLocal(d, t.key);
            } else switch (cg.emit.pic) {
                .none => try cg.e.leaThreadLocal(d, t.key),
                .pie => try cg.e.leaThreadLocalInitial(d, t.key),
                .pic => {
                    try cg.e.leaThreadLocalGeneral(t.key, try cg.emit.tlsGetAddr());
                    try cg.e.mov(.qword, .{ .reg = d }, .{ .reg = .rax });
                },
            }
            try cg.setResult(inst, data.ty_pl.ty, d);
        },
        .intcast, .trunc, .bitcast, .ptr_from_int => {
            const ty = data.ty_op.ty;
            if (cg.homes[@backingInt(inst)] == .view) return;
            if (tag == .trunc) if (cg.mulPart(inst)) |part| {
                const d = cg.destReg(inst);
                if (cg.pairOf(part.m.toRef())) |p| {
                    try cg.e.mov(.qword, .{ .reg = d }, .{ .reg = if (part.hi) p.hi else p.lo });
                } else try cg.e.mov(.qword, .{ .reg = d }, .{ .mem = offsetMem(try cg.memOf(part.m.toRef()), if (part.hi) 8 else 0) });
                try cg.normalize(d, ty);
                return cg.setResult(inst, ty, d);
            };
            if (tag != .ptr_from_int and vector.lowers(cg, inst)) return vector.gen(cg, inst, tag, data);
            if (tag != .ptr_from_int and (cg.isWideInt(ty) or cg.isWideInt(cg.typeOf(data.ty_op.operand))) and Type.isInt(ip, ty)) return cg.genWide(inst, tag, data);
            if (cg.passInRegs(ty) and cg.passInRegs(cg.typeOf(data.ty_op.operand))) {
                const d = cg.destReg(inst);
                const src_ty = cg.typeOf(data.ty_op.operand);
                if (!Type.isInt(ip, ty) or (Type.isInt(ip, src_ty) and intFits(Type.intInfo(ip, src_ty), Type.intInfo(ip, ty)))) {
                    try cg.load(d, data.ty_op.operand);
                } else {
                    const info = Type.intInfo(ip, ty);
                    const src = try cg.locOf(data.ty_op.operand);
                    if (src == .reg and (info.bits == 8 or info.bits == 16 or info.bits == 32)) {
                        // Extend straight from the operand's register.
                        if (info.signedness == .signed)
                            try cg.e.movsx(.qword, d, sizeOf(info.bits / 8), .{ .reg = src.reg })
                        else
                            try cg.e.movzx(if (info.bits == 32) .qword else .dword, d, sizeOf(info.bits / 8), .{ .reg = src.reg });
                    } else {
                        try cg.load(d, data.ty_op.operand);
                        try cg.normalize(d, ty);
                    }
                }
                return cg.setResult(inst, ty, d);
            }
            const dst = try cg.resultMem(inst, ty) orelse return;
            const size = Type.abiSize(ip, ty);
            if (Type.abiSize(ip, cg.typeOf(data.ty_op.operand)) != size) {
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
        .error_name => {
            // The table holds a slice per error code.
            try cg.emit.useErrorNames();
            const dst = try cg.resultMem(inst, .slice_const_u8_sentinel_0_type) orelse return;
            try cg.load(.rax, data.un_op);
            try cg.e.movzx(.dword, .rax, .word, .{ .reg = .rax });
            try cg.e.shift(.shl, .qword, .{ .reg = .rax }, 4);
            try cg.e.lea(.qword, .rcx, Mem.sym(Emit.error_name_table, 0));
            try cg.e.alu(.add, .qword, .{ .reg = .rcx }, .{ .reg = .rax });
            try cg.copyMem(dst, Mem.at(.rcx, 0), 16);
        },
        .int_from_bool, .int_from_ptr => {
            const d = cg.destReg(inst);
            try cg.load(d, data.un_op);
            try cg.setResult(inst, ir.typeOfIndex(inst, ip), d);
        },

        // The block's result, which each `br` writes (see `genTerm`). A
        // float result keeps its XMM register: values computed in it
        // (`Live.share`) count on that, and are saved with it around
        // calls (`genSplit`).
        .block => if (cg.homes[@backingInt(inst)] != .reg and cg.homes[@backingInt(inst)] != .regs and cg.homes[@backingInt(inst)] != .xmm) {
            _ = try cg.slotFor(inst, data.ty_pl.ty);
        },
        .loop => {},
        // Terminators (`genTerm`).
        .repeat, .br, .cond_br, .switch_br, .ret, .unreach, .trap => unreachable,
        .breakpoint => try cg.e.int3(),
        .call => try cg.call(inst, data),

        .struct_field_ptr => {
            const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
            const container = Type.ptrInfo(ip, cg.typeOf(sf.operand)).child;
            if (cg.foldFrame(inst, sf.operand, Type.fieldOffset(ip, container, sf.index))) return;
            const d = cg.destReg(inst);
            try cg.addrPlus(d, sf.operand, Type.fieldOffset(ip, container, sf.index));
            try cg.setResult(inst, data.ty_pl.ty, d);
        },
        .struct_field_val => {
            const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
            if (sf.operand.toIndex()) |op| if (cg.homes[@backingInt(op)] == .pair) return; // written by the operation
            const ty = data.ty_pl.ty;
            const off = Type.fieldOffset(ip, cg.typeOf(sf.operand), sf.index);
            if (cg.passInRegs(ty)) return cg.loadResult(inst, ty, offsetMem(try cg.memOf(sf.operand), off));
            const dst = try cg.resultMem(inst, ty) orelse return;
            const src = try cg.memOf(sf.operand);
            try cg.copyMem(dst, offsetMem(src, off), Type.abiSize(ip, ty));
        },
        .ptr_elem_ptr, .slice_elem_ptr, .ptr_add => {
            const bin = ir.extraData(Ir.Bin, data.ty_pl.payload).data;
            const elem_ty = Type.ptrInfo(ip, data.ty_pl.ty).child;
            if (tag != .slice_elem_ptr) if (cg.constIndex(bin.rhs)) |k| {
                if (cg.foldFrame(inst, bin.lhs, k *% Type.abiSize(ip, elem_ty))) return;
            };
            const d = cg.destReg(inst);
            try cg.elemAddrTo(d, tag == .slice_elem_ptr, bin.lhs, bin.rhs, Type.abiSize(ip, elem_ty));
            try cg.setResult(inst, data.ty_pl.ty, d);
        },
        .vector_store_elem => {
            const bin = ir.extraData(Ir.Bin, data.pl_op.payload).data;
            const elem_ty = Type.childType(ip, Type.ptrInfo(ip, cg.typeOf(data.pl_op.operand)).child);
            try cg.load(.r10, data.pl_op.operand);
            try cg.load(.rcx, bin.lhs);
            if (elem_ty == .bool_type) {
                // Bit rcx % 8 of byte rcx / 8: clear it, then or in the value.
                try cg.e.mov(.qword, .{ .reg = .rax }, .{ .reg = .rcx });
                try cg.e.shift(.shr, .qword, .{ .reg = .rax }, 3);
                try cg.e.alu(.add, .qword, .{ .reg = .r10 }, .{ .reg = .rax });
                try cg.e.alu(.@"and", .dword, .{ .reg = .rcx }, .{ .imm = 7 });
                try cg.e.mov(.dword, .{ .reg = .rdx }, .{ .imm = 1 });
                try cg.e.shift(.shl, .dword, .{ .reg = .rdx }, null);
                try cg.e.unary(.not, .dword, .{ .reg = .rdx });
                try cg.e.alu(.@"and", .byte, .{ .mem = Mem.at(.r10, 0) }, .{ .reg = .rdx });
                try cg.load(.rax, bin.rhs);
                try cg.e.shift(.shl, .dword, .{ .reg = .rax }, null);
                try cg.e.alu(.@"or", .byte, .{ .mem = Mem.at(.r10, 0) }, .{ .reg = .rax });
                return;
            }
            try cg.scaleAdd(.r10, .rcx, Type.abiSize(ip, elem_ty));
            try cg.copyTo(Mem.at(.r10, 0), bin.rhs);
        },
        .ptr_elem_val, .slice_elem_val => {
            const ty = ir.typeOfIndex(inst, ip);
            const size = Type.abiSize(ip, ty);
            if (cg.pairOf(inst.toRef())) |d| {
                try cg.elemAddrTo(.r10, tag == .slice_elem_val, data.bin_op.lhs, data.bin_op.rhs, size);
                try cg.e.mov(.qword, .{ .reg = d.lo }, .{ .mem = Mem.at(.r10, 0) });
                return cg.e.mov(.qword, .{ .reg = d.hi }, .{ .mem = Mem.at(.r10, 8) });
            }
            if (cg.passInRegs(ty)) {
                try cg.elemAddrTo(.r10, tag == .slice_elem_val, data.bin_op.lhs, data.bin_op.rhs, size);
                return cg.loadResult(inst, ty, Mem.at(.r10, 0));
            }
            const dst = try cg.resultMem(inst, ty) orelse return;
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
            if (ip.keyTag(cg.typeOf(data.bin_op.lhs)) == .vector_type and ty == .bool_type) {
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
            if (cg.pairOf(data.ty_op.operand)) |p| return cg.setResult(inst, data.ty_op.ty, if (tag == .slice_len) p.hi else p.lo);
            const src = try cg.memOf(data.ty_op.operand);
            const d = cg.destReg(inst);
            try cg.e.mov(.qword, .{ .reg = d }, .{ .mem = offsetMem(src, if (tag == .slice_len) 8 else 0) });
            try cg.setResult(inst, data.ty_op.ty, d);
        },
        .slice => {
            const bin = ir.extraData(Ir.Bin, data.ty_pl.payload).data;
            if (cg.pairOf(inst.toRef())) |d| {
                // Each half straight to its register unless the other half
                // is in it.
                const lhs = try cg.locOf(bin.lhs);
                const rhs = try cg.locOf(bin.rhs);
                if (!(rhs == .reg and rhs.reg == d.lo)) {
                    try cg.load(d.lo, bin.lhs);
                    return cg.load(d.hi, bin.rhs);
                }
                if (!(lhs == .reg and lhs.reg == d.hi)) {
                    try cg.load(d.hi, bin.rhs);
                    return cg.load(d.lo, bin.lhs);
                }
                try cg.load(.rax, bin.lhs);
                try cg.load(d.hi, bin.rhs);
                return cg.e.mov(.qword, .{ .reg = d.lo }, .{ .reg = .rax });
            }
            const dst = try cg.resultMem(inst, data.ty_pl.ty) orelse return;
            try cg.storeVal(dst, bin.lhs, 8);
            try cg.storeVal(offsetMem(dst, 8), bin.rhs, 8);
        },

        .is_null, .is_non_null, .is_err, .is_non_err => try cg.genCond(inst),
        .optional_payload => {
            const child = data.ty_op.ty;
            if (cg.pairOf(inst.toRef())) |d| return cg.loadRegs(d, data.ty_op.operand);
            if (Type.optionalReprIsPtr(ip, child)) {
                const d = cg.destReg(inst);
                try cg.load(d, data.ty_op.operand);
                return cg.setResult(inst, child, d);
            }
            if (cg.optInGpr(cg.typeOf(data.ty_op.operand))) if (try cg.locOf(data.ty_op.operand) == .reg) {
                // An optional in a register (`optInGpr`): its low bytes,
                // extended.
                const r = (try cg.locOf(data.ty_op.operand)).reg;
                const d = cg.destReg(inst);
                const size = Type.abiSize(ip, child);
                if (size == 4 and !cg.signed(child)) {
                    try cg.e.mov(.dword, .{ .reg = d }, .{ .reg = r });
                } else if (cg.signed(child)) {
                    try cg.e.movsx(.qword, d, sizeOf(size), .{ .reg = r });
                } else try cg.e.movzx(.dword, d, sizeOf(size), .{ .reg = r });
                return cg.setResult(inst, child, d);
            };
            if (cg.passInRegs(child)) {
                const src = try cg.memOf(data.ty_op.operand);
                const d = cg.destReg(inst);
                try cg.loadMem(d, src, child);
                return cg.setResult(inst, child, d);
            }
            const dst = try cg.resultMem(inst, child) orelse return;
            try cg.copyMem(dst, try cg.memOf(data.ty_op.operand), Type.abiSize(ip, child));
        },
        .optional_payload_ptr, .optional_payload_ptr_set => {
            const d = cg.destReg(inst);
            try cg.load(d, data.ty_op.operand);
            if (tag == .optional_payload_ptr_set) {
                const opt_ty = Type.ptrInfo(ip, cg.typeOf(data.ty_op.operand)).child;
                if (!Type.optionalReprIsPayload(ip, Type.childType(ip, opt_ty))) {
                    try cg.e.mov(.byte, .{ .mem = Mem.at(d, @intCast(Type.optionalFlagOffset(ip, opt_ty))) }, .{ .imm = 1 });
                }
            }
            try cg.setResult(inst, data.ty_op.ty, d);
        },
        .wrap_optional => {
            const opt_ty = data.ty_op.ty;
            if (cg.pairOf(inst.toRef())) |d| return cg.loadRegs(d, data.ty_op.operand);
            if (cg.inGpr(opt_ty)) {
                // An optional pointer is the pointer; another optional the
                // payload's bytes and the flag above them (`optInGpr`).
                const d = cg.destReg(inst);
                try cg.load(d, data.ty_op.operand);
                if (!Type.optionalReprIsPtr(ip, Type.childType(ip, opt_ty))) {
                    const child = Type.childType(ip, opt_ty);
                    switch (Type.abiSize(ip, child)) {
                        1, 2 => |n| try cg.e.movzx(.dword, d, sizeOf(n), .{ .reg = d }),
                        4 => try cg.e.mov(.dword, .{ .reg = d }, .{ .reg = d }),
                        else => unreachable,
                    }
                    const flag: u6 = @intCast(8 * Type.optionalFlagOffset(ip, opt_ty));
                    if (flag < 31) {
                        try cg.e.alu(.@"or", .qword, .{ .reg = d }, .{ .imm = @as(i32, 1) << @intCast(flag) });
                    } else {
                        try cg.e.mov(.qword, .{ .reg = .rcx }, .{ .imm = @as(i64, 1) << flag });
                        try cg.e.alu(.@"or", .qword, .{ .reg = d }, .{ .reg = .rcx });
                    }
                }
                return cg.setResult(inst, opt_ty, d);
            }
            const dst = try cg.resultMem(inst, opt_ty) orelse return;
            try cg.copyTo(dst, data.ty_op.operand);
            if (!Type.optionalReprIsPayload(ip, Type.childType(ip, opt_ty))) {
                try cg.e.mov(.byte, .{ .mem = offsetMem(dst, Type.optionalFlagOffset(ip, opt_ty)) }, .{ .imm = 1 });
            }
        },
        .unwrap_errunion_payload, .unwrap_errunion_err => {
            const ty = data.ty_op.ty;
            const eu_ty = cg.typeOf(data.ty_op.operand);
            const layout = Type.errorUnionLayout(ip, eu_ty);
            const off = if (tag == .unwrap_errunion_err) layout.err_offset else layout.payload_offset;
            if (cg.pairOf(data.ty_op.operand)) |p| {
                if (tag == .unwrap_errunion_payload) return cg.setResult(inst, ty, p.hi);
                const d = cg.destReg(inst);
                try cg.e.movzx(.qword, d, .word, .{ .reg = p.lo });
                return cg.setResult(inst, ty, d);
            }
            if (cg.passInRegs(ty)) if (try cg.locOf(data.ty_op.operand) == .reg) {
                // An error union in a register (`inGpr`).
                const r = (try cg.locOf(data.ty_op.operand)).reg;
                const d = cg.destReg(inst);
                if (tag == .unwrap_errunion_err) {
                    try cg.e.movzx(.qword, d, .word, .{ .reg = r });
                } else {
                    // Shift the payload to the top, then down extended.
                    const bits: u8 = @intCast(8 * Type.abiSize(ip, ty));
                    if (r != d) try cg.e.mov(.qword, .{ .reg = d }, .{ .reg = r });
                    if (bits + 8 * off < 64) try cg.e.shift(.shl, .qword, .{ .reg = d }, @intCast(64 - bits - 8 * off));
                    try cg.e.shift(if (cg.signed(ty)) .sar else .shr, .qword, .{ .reg = d }, @intCast(64 - bits));
                }
                return cg.setResult(inst, ty, d);
            };
            if (cg.passInRegs(ty)) {
                const src = try cg.memOf(data.ty_op.operand);
                const d = cg.destReg(inst);
                try cg.loadMem(d, offsetMem(src, off), ty);
                return cg.setResult(inst, ty, d);
            }
            const dst = try cg.resultMem(inst, ty) orelse return;
            const src = try cg.memOf(data.ty_op.operand);
            try cg.copyMem(dst, offsetMem(src, off), Type.abiSize(ip, ty));
        },
        .unwrap_errunion_payload_ptr, .unwrap_errunion_err_ptr, .errunion_payload_ptr_set => {
            const eu_ty = Type.ptrInfo(ip, cg.typeOf(data.ty_op.operand)).child;
            const layout = Type.errorUnionLayout(ip, eu_ty);
            const off = if (tag == .unwrap_errunion_err_ptr) layout.err_offset else layout.payload_offset;
            const d = cg.destReg(inst);
            if (tag == .errunion_payload_ptr_set) {
                try cg.load(d, data.ty_op.operand);
                try cg.e.mov(errFieldSize(layout), .{ .mem = Mem.at(d, @intCast(layout.err_offset)) }, .{ .imm = 0 });
                if (off != 0) try cg.e.alu(.add, .qword, .{ .reg = d }, .{ .imm = @intCast(off) });
            } else try cg.addrPlus(d, data.ty_op.operand, off);
            try cg.setResult(inst, data.ty_op.ty, d);
        },
        .wrap_errunion_payload, .wrap_errunion_err => {
            const eu_ty = data.ty_op.ty;
            if (cg.pairOf(inst.toRef())) |d| {
                // The payload is undefined in an error.
                if (tag == .wrap_errunion_payload) {
                    try cg.load(d.hi, data.ty_op.operand);
                    return cg.e.mov(.dword, .{ .reg = d.lo }, .{ .imm = 0 });
                }
                return cg.load(d.lo, data.ty_op.operand);
            }
            const payload_ty = cg.typeOf(data.ty_op.operand);
            if (cg.inGpr(eu_ty) and (!Type.hasRuntimeBits(ip, payload_ty) or cg.passInRegs(payload_ty))) {
                // The error code in the low 16 bits, or the payload above
                // zeros, with the bits above it zero.
                const d = cg.destReg(inst);
                if (tag == .wrap_errunion_err) {
                    try cg.load(d, data.ty_op.operand);
                } else if (!Type.hasRuntimeBits(ip, payload_ty)) {
                    try cg.e.mov(.dword, .{ .reg = d }, .{ .imm = 0 });
                } else {
                    const off: u8 = @intCast(8 * Type.errorUnionLayout(ip, eu_ty).payload_offset);
                    const bits: u8 = @intCast(8 * Type.abiSize(ip, payload_ty));
                    try cg.load(d, data.ty_op.operand);
                    if (bits < 64) try cg.e.shift(.shl, .qword, .{ .reg = d }, @intCast(64 - bits));
                    if (bits + off < 64) try cg.e.shift(.shr, .qword, .{ .reg = d }, @intCast(64 - bits - off));
                }
                return cg.setResult(inst, eu_ty, d);
            }
            const dst = try cg.resultMem(inst, eu_ty) orelse return;
            const layout = Type.errorUnionLayout(ip, eu_ty);
            if (tag == .wrap_errunion_payload) {
                try cg.e.mov(errFieldSize(layout), .{ .mem = offsetMem(dst, layout.err_offset) }, .{ .imm = 0 });
                try cg.copyTo(offsetMem(dst, layout.payload_offset), data.ty_op.operand);
            } else {
                const r = try cg.regOf(data.ty_op.operand, .rax);
                try cg.storeReg(offsetMem(dst, layout.err_offset), r, errFieldSize(layout).bytes());
            }
        },
        .aggregate_init => {
            const ty = data.ty_pl.ty;
            const extra = ir.extraData(Ir.Aggregate, data.ty_pl.payload);
            const elems = ir.refSlice(extra.end, extra.data.len);
            if (elems.len != 0 and vector.lowers(cg, inst)) return vector.gen(cg, inst, tag, data);
            const dst = try cg.resultMem(inst, ty) orelse return;
            if (ip.keyTag(ty) == .vector_type and ip.keyPayload(.vector_type, ty).child == .bool_type) {
                // Bit-packed: element i is bit i % 8 of byte i / 8.
                try cg.fillMem(dst, Type.abiSize(ip, ty), 0);
                for (elems, 0..) |elem, i| {
                    try cg.load(.rax, elem);
                    if (i % 8 != 0) try cg.e.shift(.shl, .byte, .{ .reg = .rax }, @intCast(i % 8));
                    try cg.e.alu(.@"or", .byte, .{ .mem = offsetMem(dst, i / 8) }, .{ .reg = .rax });
                }
                return;
            }
            // A run of one element over 128 bytes (a `@splat`): copies of
            // the element until they span 64 bytes, then copies of what is
            // written until it spans 512, then one overlapping forward
            // `rep movsb` repeats that. (Overlapping at a distance under
            // 512 bytes leaves the fast-string path: 3x slower at 128.)
            var first: usize = 0;
            if (elems.len > 1 and ip.keyTag(ty) != .struct_type and ip.keyTag(ty) != .tuple_type) {
                const elem_size = Type.abiSize(ip, cg.typeOf(elems[0]));
                const run = for (elems, 0..) |elem, i| {
                    if (elem != elems[0]) break i;
                } else elems.len;
                const total = run * elem_size;
                if (total > 128) {
                    var span: u64 = 0;
                    while (span < 64) : (span += elem_size) try cg.copyTo(offsetMem(dst, span), elems[0]);
                    while (span < 512 and span < total) {
                        const n = @min(span, total - span);
                        try cg.copyMem(offsetMem(dst, span), dst, n);
                        span += n;
                    }
                    if (span < total) {
                        try cg.e.lea(.qword, .rsi, dst);
                        try cg.e.lea(.qword, .rdi, offsetMem(dst, span));
                        try cg.e.mov(.qword, .{ .reg = .rcx }, .{ .imm = @intCast(total - span) });
                        try cg.e.repMovsb();
                    }
                    first = run;
                }
            }
            for (elems[first..], first..) |elem, i| {
                const off = switch (ip.indexToKey(ty)) {
                    .array_type => |a| i * Type.abiSize(ip, a.child),
                    .vector_type => |v| i * Type.abiSize(ip, v.child),
                    else => if (Type.comptimeFieldValue(ip, ty, i) != .none) continue else Type.fieldOffset(ip, ty, i),
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
            const ty = data.ty_op.ty;
            const layout = Type.unionLayout(ip, cg.typeOf(data.ty_op.operand));
            const src = try cg.memOf(data.ty_op.operand);
            if (cg.passInRegs(ty)) {
                const d = cg.destReg(inst);
                try cg.loadMem(d, offsetMem(src, layout.tag_offset), ty);
                return cg.setResult(inst, ty, d);
            }
            const dst = try cg.resultMem(inst, ty) orelse return;
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
            switch (Type.abiSize(ip, elem_ty)) {
                2, 4, 8 => |size| {
                    _ = try cg.memDest(.rdi, .rcx, data.bin_op.lhs);
                    try cg.load(.rax, elem);
                    return cg.e.repStos(sizeOf(size));
                },
                else => {},
            }
            // Store the first element, then copy what is stored until it
            // spans 512 bytes, then let one overlapping forward `rep movsb`
            // repeat that. (At a distance under 512 bytes, an overlapping
            // `rep movsb` leaves the fast-string path.)
            const elem_size = try cg.memDest(.r8, .r9, data.bin_op.lhs);
            const done = try cg.e.newLabel();
            const double = try cg.e.newLabel();
            const half = try cg.e.newLabel();
            const rest = try cg.e.newLabel();
            try cg.e.@"test"(.qword, .{ .reg = .r9 }, .{ .reg = .r9 });
            try cg.e.jcc(.e, .{ .label = done });
            if (elem.toInterned()) |v| if (ip.keyTag(v) == .undef) {
                try cg.fillMem(Mem.at(.r8, 0), elem_size, 0xaa);
            } else try cg.copyTo(Mem.at(.r8, 0), elem) else try cg.copyTo(Mem.at(.r8, 0), elem);
            // rdx: the bytes to fill; r10: the bytes stored, a multiple of
            // the element's size.
            try cg.e.imul(.qword, .rdx, .{ .reg = .r9 }, @intCast(elem_size));
            try cg.e.mov(.qword, .{ .reg = .r10 }, .{ .imm = @intCast(elem_size) });
            cg.e.bind(double);
            try cg.e.alu(.cmp, .qword, .{ .reg = .r10 }, .{ .reg = .rdx });
            try cg.e.jcc(.ae, .{ .label = done });
            try cg.e.alu(.cmp, .qword, .{ .reg = .r10 }, .{ .imm = 512 });
            try cg.e.jcc(.ae, .{ .label = rest });
            // min(stored, left) bytes, not overlapping.
            try cg.e.mov(.qword, .{ .reg = .rcx }, .{ .reg = .rdx });
            try cg.e.alu(.sub, .qword, .{ .reg = .rcx }, .{ .reg = .r10 });
            try cg.e.alu(.cmp, .qword, .{ .reg = .rcx }, .{ .reg = .r10 });
            try cg.e.jcc(.be, .{ .label = half });
            try cg.e.mov(.qword, .{ .reg = .rcx }, .{ .reg = .r10 });
            cg.e.bind(half);
            try cg.e.mov(.qword, .{ .reg = .rsi }, .{ .reg = .r8 });
            try cg.e.lea(.qword, .rdi, .{ .base = .{ .reg = .r8 }, .index = .{ .reg = .r10, .scale = .@"1" } });
            try cg.e.repMovsb();
            try cg.e.mov(.qword, .{ .reg = .r10 }, .{ .reg = .rdi });
            try cg.e.alu(.sub, .qword, .{ .reg = .r10 }, .{ .reg = .r8 });
            try cg.e.jmp(.{ .label = double });
            cg.e.bind(rest);
            try cg.e.mov(.qword, .{ .reg = .rsi }, .{ .reg = .r8 });
            try cg.e.lea(.qword, .rdi, .{ .base = .{ .reg = .r8 }, .index = .{ .reg = .r10, .scale = .@"1" } });
            try cg.e.mov(.qword, .{ .reg = .rcx }, .{ .reg = .rdx });
            try cg.e.alu(.sub, .qword, .{ .reg = .rcx }, .{ .reg = .r10 });
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
            const bits = Type.intInfo(ip, cg.typeOf(data.ty_op.operand)).bits;
            try cg.bitOp(tag, bits, data.ty_op.operand);
            if (tag == .byte_swap or tag == .bit_reverse) try cg.normalize(.rax, ty);
            try cg.setResult(inst, ty, .rax);
        },
        .tag_name => {
            // A compare chain over the tags; each name is a content atom.
            const dst = try cg.resultMem(inst, data.ty_op.ty) orelse return;
            const enum_ty = cg.typeOf(data.ty_op.operand);
            const info = ip.structInfo(enum_ty);
            const wide = cg.isWideInt(enum_ty);
            if (!wide) try cg.load(.rax, data.ty_op.operand);
            const done = try cg.e.newLabel();
            for (info.field_names, info.field_defaults) |name, v| {
                const next = try cg.e.newLabel();
                if (wide) {
                    try cg.wideEqFlags(data.ty_op.operand, .fromInterned(v));
                } else {
                    try cg.e.mov(.qword, .{ .reg = .rcx }, .{ .imm = @bitCast(intBits(ip, v)) });
                    try cg.e.alu(.cmp, .qword, .{ .reg = .rax }, .{ .reg = .rcx });
                }
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
    const a = ip.keyPayload(.array_type, p.child);
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
        if (cg.pairOf(base)) |p| {
            try cg.e.mov(.qword, .{ .reg = reg }, .{ .reg = p.lo });
        } else try cg.e.mov(.qword, .{ .reg = reg }, .{ .mem = try cg.memOf(base) });
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

/// A condition as a bool, unless its branch computes it.
fn genCond(cg: *CodeGen, inst: Inst.Index) Error!void {
    if (cg.homes[@backingInt(inst)] == .fused) return;
    const cond = try cg.condFlags(inst);
    const d = cg.destReg(inst);
    try cg.e.setcc(cond, .{ .reg = d });
    try cg.e.movzx(.dword, d, .byte, .{ .reg = d });
    try cg.setResult(inst, .bool_type, d);
}

/// `d = lhs op rhs` for the operations with a two-operand form, normalized
/// to `ty`. `d` is not the register of an operand. Uses rcx.
fn intOp(cg: *CodeGen, d: Reg, tag: Inst.Tag, ty: Index, lhs: Ref, rhs: Ref) Error!void {
    const e = &cg.e;
    // A 32-bit operation zero-extends its result: a u32 needs no
    // normalizing.
    const size: Size = if (Type.class(cg.ip, ty) == .int and !cg.signed(ty) and Type.intInfo(cg.ip, ty).bits == 32) .dword else .qword;
    switch (tag) {
        .shl, .shr => {
            const op: Encoder.ShiftOp = if (tag == .shl) .shl else if (cg.signed(ty)) .sar else .shr;
            const count: ?u8 = switch (try cg.locOf(rhs)) {
                .imm => |v| @intCast(v & 63),
                else => null,
            };
            if (count == null) try cg.load(.rcx, rhs);
            try cg.load(d, lhs);
            try e.shift(op, size, .{ .reg = d }, count);
        },
        .mul_wrap => {
            const src = try cg.srcOperand(rhs, .rcx);
            switch (src) {
                .imm => |v| try e.imul(size, d, .{ .reg = try cg.regOf(lhs, d) }, @intCast(v)),
                .reg => |r| {
                    try cg.load(d, lhs);
                    try e.imul(size, d, .{ .reg = r }, null);
                },
                .mem => |m| {
                    try cg.load(d, lhs);
                    try e.imul(size, d, .{ .mem = m }, null);
                },
            }
        },
        else => {
            const src = try cg.srcOperand(rhs, .rcx);
            try cg.load(d, lhs);
            try e.alu(switch (tag) {
                .add_wrap => .add,
                .sub_wrap => .sub,
                .bit_and => .@"and",
                .bit_or => .@"or",
                .xor => .xor,
                else => unreachable,
            }, size, .{ .reg = d }, src);
        },
    }
    if (size == .dword) return;
    switch (tag) {
        .bit_and, .bit_or, .xor => {}, // stay extended
        else => try cg.normalize(d, ty),
    }
}

/// Computes `lhs op rhs` on 64-bit extended operands into rax, normalized
/// to `ty`. Uses rcx and rdx.
fn binOp(cg: *CodeGen, tag: Inst.Tag, ty: Index, lhs: Ref, rhs: Ref) Error!void {
    const s = cg.signed(ty);
    try cg.load(.rax, lhs);
    if (!s) if (rhs.toInterned()) |v| switch (tag) {
        .div_trunc, .div_floor, .div_ceil, .rem, .mod => if (intBits(cg.ip, v) != 0) {
            // The result is at most the dividend: it stays normalized.
            return cg.divConst(tag, intBits(cg.ip, v), Type.intInfo(cg.ip, ty).bits);
        },
        else => {},
    };
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
                // A 32-bit divide is faster where the operands fit (it
                // zero-extends its results): always for types of up to 32
                // bits, else when both values do, as LLVM bypasses slow
                // divides.
                try cg.e.alu(.xor, .dword, .{ .reg = .rdx }, .{ .reg = .rdx });
                if (Type.intInfo(cg.ip, ty).bits <= 32) {
                    try cg.e.unary(.div, .dword, .{ .reg = .rcx });
                } else {
                    const wide = try cg.e.newLabel();
                    const done = try cg.e.newLabel();
                    try cg.e.mov(.qword, .{ .reg = .r11 }, .{ .reg = .rax });
                    try cg.e.alu(.@"or", .qword, .{ .reg = .r11 }, .{ .reg = .rcx });
                    try cg.e.shift(.shr, .qword, .{ .reg = .r11 }, 32);
                    try cg.e.jcc(.ne, .{ .label = wide });
                    try cg.e.unary(.div, .dword, .{ .reg = .rcx });
                    try cg.e.jmp(.{ .label = done });
                    cg.e.bind(wide);
                    try cg.e.unary(.div, .qword, .{ .reg = .rcx });
                    cg.e.bind(done);
                }
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

/// Unsigned division of the `bits`-bit value in rax by constant `d` (not
/// zero) without a divide: a shift for a power of two, else a multiply by
/// a magic number (Granlund and Montgomery, 1994): the smallest `p` from
/// 64 with `m = ceil(2^p / d)` and `m * d - 2^p <= 2^(p - bits)` gives
/// `x / d = (x * m) >> p` for every `bits`-bit `x`; an `m` of 65 bits
/// takes the add-and-halve fixup. The result, by `tag`, ends in rax. Uses
/// rcx, rdx, and r11.
fn divConst(cg: *CodeGen, tag: Inst.Tag, d: u64, bits: u16) Error!void {
    const e = &cg.e;
    const want_rem = tag == .rem or tag == .mod or tag == .div_ceil;
    if (std.math.isPowerOfTwo(d)) {
        const k: u6 = @intCast(@ctz(d));
        if (want_rem) try e.mov(.qword, .{ .reg = .rdx }, .{ .reg = .rax });
        if (k != 0) try e.shift(.shr, .qword, .{ .reg = .rax }, k);
        if (want_rem) try cg.andImm(.rdx, d - 1);
    } else if (d > @as(u64, 1) << @intCast(bits - 1)) {
        // The quotient is 0 or 1.
        try e.mov(.qword, .{ .reg = .r11 }, .{ .imm = @bitCast(d) });
        try e.mov(.qword, .{ .reg = .rdx }, .{ .reg = .rax });
        try e.alu(.xor, .dword, .{ .reg = .rcx }, .{ .reg = .rcx });
        try e.alu(.cmp, .qword, .{ .reg = .rax }, .{ .reg = .r11 });
        try e.setcc(.ae, .{ .reg = .rcx });
        const done = try e.newLabel();
        try e.jcc(.b, .{ .label = done });
        try e.alu(.sub, .qword, .{ .reg = .rdx }, .{ .reg = .r11 });
        e.bind(done);
        try e.mov(.qword, .{ .reg = .rax }, .{ .reg = .rcx });
    } else {
        var p: u8 = 64;
        const m: u128 = while (true) : (p += 1) {
            const two_p = @as(u128, 1) << @intCast(p);
            const mm = (two_p + d - 1) / d;
            if (mm * d - two_p <= @as(u128, 1) << @intCast(p - bits)) break mm;
        };
        try e.mov(.qword, .{ .reg = .rcx }, .{ .reg = .rax });
        try e.mov(.qword, .{ .reg = .r11 }, .{ .imm = @bitCast(@as(u64, @truncate(m))) });
        try e.unary(.mul, .qword, .{ .reg = .r11 });
        if (m >> 64 == 0) {
            try e.mov(.qword, .{ .reg = .rax }, .{ .reg = .rdx });
            if (p > 64) try e.shift(.shr, .qword, .{ .reg = .rax }, @intCast(p - 64));
        } else {
            // q = (t + ((x - t) >> 1)) >> (p - 65), t = (x * (m - 2^64)) >> 64.
            try e.mov(.qword, .{ .reg = .rax }, .{ .reg = .rcx });
            try e.alu(.sub, .qword, .{ .reg = .rax }, .{ .reg = .rdx });
            try e.shift(.shr, .qword, .{ .reg = .rax }, 1);
            try e.alu(.add, .qword, .{ .reg = .rax }, .{ .reg = .rdx });
            if (p > 65) try e.shift(.shr, .qword, .{ .reg = .rax }, @intCast(p - 65));
        }
        if (want_rem) {
            // r = x - q * d.
            if (std.math.cast(i32, d)) |imm| {
                try e.imul(.qword, .rdx, .{ .reg = .rax }, imm);
            } else {
                try e.mov(.qword, .{ .reg = .rdx }, .{ .imm = @bitCast(d) });
                try e.imul(.qword, .rdx, .{ .reg = .rax }, null);
            }
            try e.alu(.sub, .qword, .{ .reg = .rcx }, .{ .reg = .rdx });
            if (tag != .div_ceil) return e.mov(.qword, .{ .reg = .rax }, .{ .reg = .rcx });
            try e.mov(.qword, .{ .reg = .rdx }, .{ .reg = .rcx });
        }
    }
    switch (tag) {
        .div_trunc, .div_floor => {},
        .rem, .mod => try e.mov(.qword, .{ .reg = .rax }, .{ .reg = .rdx }),
        .div_ceil => {
            // Up by one when the remainder is not zero.
            try e.@"test"(.qword, .{ .reg = .rdx }, .{ .reg = .rdx });
            try e.setcc(.ne, .{ .reg = .rdx });
            try e.movzx(.qword, .rdx, .byte, .{ .reg = .rdx });
            try e.alu(.add, .qword, .{ .reg = .rax }, .{ .reg = .rdx });
        },
        else => unreachable,
    }
}

/// `reg &= mask`.
fn andImm(cg: *CodeGen, reg: Reg, mask: u64) Error!void {
    if (std.math.cast(i32, mask)) |imm| return cg.e.alu(.@"and", .qword, .{ .reg = reg }, .{ .imm = imm });
    try cg.e.mov(.qword, .{ .reg = .r11 }, .{ .imm = @bitCast(mask) });
    try cg.e.alu(.@"and", .qword, .{ .reg = reg }, .{ .reg = .r11 });
}

/// `{ T, u1 }` results: the wrapped value and whether it overflowed `T`.
fn overflowOp(cg: *CodeGen, inst: Inst.Index, tag: Inst.Tag, data: Inst.Data) Error!void {
    const ip = cg.ip;
    const bin = cg.ir.extraData(Ir.Bin, data.ty_pl.payload).data;
    const tuple_ty = data.ty_pl.ty;
    const ty = cg.typeOf(bin.lhs);
    const pair = cg.homes[@backingInt(inst)] == .pair;
    const dst = if (pair) undefined else try cg.resultMem(inst, tuple_ty) orelse return;
    const fields = if (pair) cg.ssa.pairs.get(@backingInt(inst)).? else .{ Ssa.no_tie, Ssa.no_tie };
    const in_flags = fields[1] != Ssa.no_tie and cg.homes[fields[1]] == .fused;
    // The value's field computed in its own register, when it has one.
    const d: Reg = if (pair and fields[0] != Ssa.no_tie and cg.homes[fields[0]] == .reg) cg.homes[fields[0]].reg else .rax;
    const res, const cond = try cg.overflowArith(tag, bin, ty, d);
    if (cond) |cc| {
        if (in_flags) {
            cg.ovf_cc = cc;
        } else if (!pair or fields[1] != Ssa.no_tie) {
            // A bit nothing reads is not computed.
            try cg.e.setcc(cc, .{ .reg = .r11 });
            try cg.e.movzx(.qword, .r11, .byte, .{ .reg = .r11 });
        }
    } else assert(!in_flags);
    // Only moves from here on, which keep the flags.
    if (pair) {
        if (fields[0] != Ssa.no_tie) try cg.setResult(@fromBackingInt(fields[0]), ty, res);
        if (fields[1] != Ssa.no_tie and !in_flags) try cg.setResult(@fromBackingInt(fields[1]), .u1_type, .r11);
        return;
    }
    const size = Type.abiSize(ip, ty);
    try cg.storeReg(dst, .rax, size);
    try cg.storeReg(offsetMem(dst, Type.fieldOffset(ip, tuple_ty, 1)), .r11, 1);
}

/// Computes an overflow operation's result, normalized, into `d` (if it
/// is an addition or subtraction at a native width and `d` does not hold
/// the right operand) or rax, and returns that register and the
/// condition under which it overflowed, or null if it set the bit in r11
/// instead (a multiplication of 33 to 63 bits, which needs
/// both the flag and a truncation check; `ovfFlagsOnly`). Native widths
/// read the flag of an operation at that width; others check whether
/// truncating the 64-bit result changes it.
fn overflowArith(cg: *CodeGen, tag: Inst.Tag, bin: Ir.Bin, ty: Index, d: Reg) Error!struct { Reg, ?Encoder.Cond } {
    const info = Type.intInfo(cg.ip, ty);
    const s = info.signedness == .signed;
    const native: ?Size = switch (info.bits) {
        8 => .byte,
        16 => .word,
        32 => .dword,
        64 => .qword,
        else => null,
    };
    var r: Reg = if (tag == .mul_with_overflow) .rax else d;
    if (native) |size| if (tag != .mul_with_overflow or size != .byte) {
        if (tag == .mul_with_overflow) {
            const rhs = try cg.regOf(bin.rhs, .rcx);
            try cg.load(.rax, bin.lhs);
            if (s) {
                try cg.e.imul(size, .rax, .{ .reg = rhs }, null);
            } else {
                try cg.e.unary(.mul, size, .{ .reg = rhs }); // writes rdx too
            }
        } else {
            // A memory operand is 8 bytes, so only at 64 bits.
            const rhs = try cg.srcOperand(bin.rhs, .rcx);
            if (rhs == .reg and rhs.reg == r) r = .rax;
            try cg.load(r, bin.lhs);
            try cg.e.alu(if (tag == .add_with_overflow) .add else .sub, size, .{ .reg = r }, rhs);
        }
        // Extend without touching the flags; a 32-bit operation
        // zero-extends already.
        switch (size) {
            .byte, .word => if (s) try cg.e.movsx(.qword, r, size, .{ .reg = r }) else try cg.e.movzx(.qword, r, size, .{ .reg = r }),
            .dword => if (s) try cg.e.movsx(.qword, r, .dword, .{ .reg = r }),
            .qword => {},
        }
        return .{ r, if (s or tag == .mul_with_overflow) .o else .b };
    };
    // A 64-bit operation, which overflowed if truncating it to `bits`
    // changes it.
    switch (tag) {
        .add_with_overflow, .sub_with_overflow => {
            const rhs = try cg.srcOperand(bin.rhs, .rcx);
            try cg.load(.rax, bin.lhs);
            try cg.e.alu(if (tag == .add_with_overflow) .add else .sub, .qword, .{ .reg = .rax }, rhs);
        },
        .mul_with_overflow => {
            try cg.load(.rax, bin.lhs);
            try cg.load(.rcx, bin.rhs);
            if (s) {
                try cg.e.imul(.qword, .rax, .{ .reg = .rcx }, null);
            } else {
                try cg.e.unary(.mul, .qword, .{ .reg = .rcx });
            }
        },
        else => unreachable,
    }
    const flag_too = !cg.ovfFlagsOnly(tag, info.bits);
    if (flag_too) {
        // The product can exceed 64 bits too.
        try cg.e.setcc(.o, .{ .reg = .r11 });
        try cg.e.movzx(.qword, .r11, .byte, .{ .reg = .r11 });
    }
    try cg.e.mov(.qword, .{ .reg = .rdx }, .{ .reg = .rax });
    try cg.normalize(.rax, ty);
    try cg.e.alu(.cmp, .qword, .{ .reg = .rax }, .{ .reg = .rdx });
    if (!flag_too) return .{ .rax, .ne };
    try cg.e.setcc(.ne, .{ .reg = .rdx });
    try cg.e.alu(.@"or", .byte, .{ .reg = .r11 }, .{ .reg = .rdx });
    return .{ .rax, null };
}

/// Whether an overflow operation on integers of `bits` bits reports its
/// overflow in one condition (`overflowArith`).
pub fn ovfFlagsOnly(_: *CodeGen, tag: Inst.Tag, bits: u16) bool {
    return tag != .mul_with_overflow or bits <= 32 or bits == 64;
}

/// A compare and branch per case item; the else block follows.
fn switchBr(cg: *CodeGen, data: Inst.Data, term: Ssa.Term) Error!void {
    const ir = cg.ir;
    const extra = ir.extraData(Ir.SwitchBr, data.pl_op.payload);
    const wide = cg.isWideInt(cg.typeOf(data.pl_op.operand));
    if (!wide) try cg.load(.rax, data.pl_op.operand);
    var i = extra.end;
    for (cg.ssa.switchCases(term, extra.data.cases_len)) |case_block| {
        const items_len = ir.extra[i];
        const items = ir.refSlice(i + 2, items_len);
        i += 2 + items_len + ir.extra[i + 1];
        const label = cg.blockLabel(@backingInt(case_block));
        for (items) |item| {
            if (wide) {
                try cg.wideEqFlags(data.pl_op.operand, item);
                try cg.e.jcc(.e, .{ .label = label });
                continue;
            }
            try cg.load(.rcx, item);
            try cg.e.alu(.cmp, .qword, .{ .reg = .rax }, .{ .reg = .rcx });
            try cg.e.jcc(.e, .{ .label = label });
        }
    }
}

/// Returns `operand`: in the block emitted last (`next` is none), through
/// the epilogue in place, and elsewhere by jumping to it.
fn ret(cg: *CodeGen, operand: Ref, next: Ssa.Block.Index) Error!void {
    const ty = cg.fn_ty.return_type;
    if (cg.fn_ty.cc == .c) {
        try cg.cRet(operand);
    } else if (cg.fn_ty.cc == .x86_64_win) {
        try cg.winRet(operand);
    } else switch (cg.autoClass(ty)) {
        .none => {},
        .gpr => try cg.loadGpr(.rax, operand, ty),
        .gpr_pair => try cg.loadPair(.rax, .rdx, operand),
        .sse => try cg.loadXmm(.xmm0, try cg.valOf(operand)),
        .memory => {
            // A load of the result's own alloc is not emitted (`planCopies`).
            const rvo = if (operand.toIndex()) |l| switch (cg.homes[@backingInt(l)]) {
                .dead => true,
                // Read in place from the result's own alloc (`planCopies`),
                // not from a constant address when there is none.
                .deferred => cg.rvo_alloc != null and cg.ir.instructions.items(.data)[@backingInt(l)].ty_op.operand.toIndex() == cg.rvo_alloc,
                else => false,
            } else false;
            if (!rvo) {
                try cg.e.mov(.qword, .{ .reg = .r10 }, .{ .mem = Mem.at(.rbp, cg.ret_ptr_slot.?) });
                try cg.copyTo(Mem.at(.r10, 0), operand);
            }
        },
    }
    if (next == .none) return cg.epilogue();
    if (cg.ret_label == null) cg.ret_label = try cg.e.newLabel();
    try cg.e.jmp(.{ .label = cg.ret_label.? });
}

/// Loads the error return trace pointer, or null if the function has none.
fn loadTrace(cg: *CodeGen, reg: Reg) Error!void {
    if (cg.trace_slot) |off| {
        try cg.e.mov(.qword, .{ .reg = reg }, .{ .mem = Mem.at(.rbp, off) });
    } else {
        try cg.e.mov(.dword, .{ .reg = reg }, .{ .imm = 0 });
    }
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
    const callee_ty = ip.keyPayload(.func_type, if (Type.class(ip, callee_fn_ty) == .pointer) Type.ptrInfo(ip, callee_fn_ty).child else callee_fn_ty);
    const ret_ty = extra.data.ret_ty;
    const is_c = callee_ty.cc == .c;
    const is_win = callee_ty.cc == .x86_64_win;
    const ret_class = cg.autoClass(ret_ty);
    // A result in rax goes to its home after the call.
    const in_rax = cg.passInRegs(ret_ty) and if (is_c) cg.cRetClass(ret_ty) == .int else if (is_win) cg.winClass(ret_ty, true) == .int else ret_class == .gpr;
    const in_pair = cg.pairOf(inst.toRef());
    const in_xmm = cg.xmmOf(inst.toRef());
    const dst = if (in_rax or in_pair != null or in_xmm != null) null else try cg.resultMem(inst, ret_ty);
    var stack_args = false;
    // A variadic callee learns from al how many vector registers hold
    // arguments.
    var va_sse: u8 = 0;
    if (is_c) {
        const vals = try cg.gpa.alloc(Val, args.len);
        defer cg.gpa.free(vals);
        for (args, vals) |arg, *v| v.* = try cg.valOf(arg);
        va_sse = try cg.cCallArgs(vals, ret_ty, dst);
    } else if (is_win) {
        const vals = try cg.gpa.alloc(Val, args.len);
        defer cg.gpa.free(vals);
        for (args, vals) |arg, *v| v.* = try cg.valOf(arg);
        try cg.winCallArgs(vals, ret_ty, dst, callee_ty.is_var_args);
    } else {
        const tys, const locs = try cg.argScratch(args.len);
        for (args, tys) |arg, *ty| ty.* = cg.typeOf(arg);
        // By-reference arguments that need a copy get it after the
        // stack arguments.
        var out = cg.autoArgs(ret_ty, tys, locs);
        try cg.arg_refs.resize(cg.gpa, args.len);
        const refs = cg.arg_refs.items;
        // The outgoing area first (copies use rax, rsi, rdi, and rcx), then
        // SSE registers (rax), then general registers. The arguments are
        // in caller-saved registers only without stack arguments or
        // copies, and then only in those that pass them (`exemptArgs`).
        for (args, tys, locs, refs) |arg, ty, l, *ref| switch (l) {
            .stack => |off| {
                stack_args = true;
                try cg.copyTo(Mem.at(.rsp, @intCast(off)), arg);
            },
            .ref, .ref_stack => {
                ref.* = try cg.argRef(arg) orelse copy: {
                    out = std.mem.alignForward(u32, out, @intCast(@min(16, @max(8, Type.abiAlignment(ip, ty)))));
                    const m = Mem.at(.rsp, @intCast(out));
                    try cg.copyTo(m, arg);
                    out += @intCast(Type.abiSize(ip, ty));
                    break :copy .{ .addr = m };
                };
                if (l == .ref_stack) {
                    stack_args = true;
                    const slot: Mem = .at(.rsp, @intCast(l.ref_stack));
                    switch (ref.*) {
                        .reg => |r| try cg.e.mov(.qword, .{ .mem = slot }, .{ .reg = r }),
                        .addr => |m| {
                            try cg.e.lea(.qword, .rax, m);
                            try cg.e.mov(.qword, .{ .mem = slot }, .{ .reg = .rax });
                        },
                    }
                }
            },
            else => {},
        };
        cg.out_args_size = @max(cg.out_args_size, std.mem.alignForward(u32, out, 8));
        for (args, locs) |arg, l| if (l == .sse) try cg.loadXmm(xmm_args[l.sse], try cg.valOf(arg));
        try cg.loadArgRegs(args, tys, locs, refs);
        if (ret_class == .memory) if (dst) |m| try cg.e.lea(.qword, .rdi, m);
    }
    if (!is_c and !is_win) try cg.loadTrace(.rax);
    if (callee_val) |f| {
        if (is_c and callee_ty.is_var_args) try cg.e.mov(.dword, .{ .reg = .rax }, .{ .imm = va_sse });
        // A panic in code the backend inlined, with its arguments in
        // registers, gets the frames of the calls it was inlined from.
        if (ret_ty == .noreturn_type and cg.in_cold and !is_c and !is_win and !stack_args and !cg.outermost_frame) {
            try cg.panicThroughStubs(try cg.emit.funcKey(f));
        } else try cg.e.call(.{ .sym = try cg.emit.funcKey(f) });
    } else {
        // r11 is not an argument register in either convention.
        try cg.load(.r11, callee_ref);
        if (is_c and callee_ty.is_var_args) try cg.e.mov(.dword, .{ .reg = .rax }, .{ .imm = va_sse });
        try cg.e.callIndirect(.{ .reg = .r11 });
    }
    if (in_rax) {
        // C callees leave the bits above a narrow result unspecified.
        const size = Type.abiSize(ip, ret_ty);
        if ((is_c or is_win) and size < 8) {
            if (cg.signed(ret_ty)) try cg.e.movsx(.qword, .rax, sizeOf(size), .{ .reg = .rax }) else try cg.e.movzx(.qword, .rax, sizeOf(size), .{ .reg = .rax });
        }
        return cg.setResult(inst, ret_ty, .rax);
    }
    // Both conventions return f32 and f64 in xmm0.
    if (in_xmm) |x| return cg.e.movups(.{ .reg = x }, .{ .reg = .xmm0 });
    if (is_c) return cg.cCallResult(ret_ty, dst);
    if (is_win) return cg.winCallResult(ret_ty, dst);
    if (in_pair) |d| {
        // `.auto` pairs come back in rax and rdx, which no value lives in.
        try cg.e.mov(.qword, .{ .reg = d.lo }, .{ .reg = .rax });
        return cg.e.mov(.qword, .{ .reg = d.hi }, .{ .reg = .rdx });
    }
    const m = dst orelse return;
    const size = Type.abiSize(ip, ret_ty);
    switch (ret_class) {
        .gpr => try cg.storeBytes(m, .rax, size),
        .gpr_pair => {
            try cg.e.mov(.qword, .{ .mem = m }, .{ .reg = .rax });
            try cg.storeBytes(offsetMem(m, 8), .rdx, size - 8);
        },
        .sse => try cg.storeXmm(m, .xmm0, size),
        .none, .memory => {},
    }
}

/// `@atomicRmw`: xchg and lock xadd where x86 has them, else a lock
/// cmpxchg loop that computes the new value in r8 from the old one in rax.
fn atomicRmw(cg: *CodeGen, inst: Inst.Index, data: Inst.Data) Error!void {
    const ip = cg.ip;
    const x = cg.ir.extraData(Ir.AtomicRmw, data.ty_pl.payload).data;
    const ty = data.ty_pl.ty;
    const bytes = Type.abiSize(ip, ty);
    const size = sizeOf(bytes);
    const mem = Mem.at(.rcx, 0);
    try cg.load(.rcx, x.ptr);
    try cg.load(.rdx, x.operand);
    if (x.operation() != .Xchg and cg.isFloat(ty)) if (cg.sseType(ty)) |ft| {
        // A compare-exchange loop on the bits, the arithmetic in SSE.
        try cg.e.mov(size, .{ .reg = .rax }, .{ .mem = mem });
        const top = try cg.e.newLabel();
        cg.e.bind(top);
        try cg.e.movToXmm(size, .xmm0, .{ .reg = .rax });
        try cg.e.movToXmm(size, .xmm1, .{ .reg = .rdx });
        switch (x.operation()) {
            .Add => try cg.e.sse(.add, ft, .xmm0, .{ .reg = .xmm1 }),
            .Sub => try cg.e.sse(.sub, ft, .xmm0, .{ .reg = .xmm1 }),
            // As upstream: maxss/minss, which give the operand if either
            // value is NaN.
            .Max => try cg.e.sse(.max, ft, .xmm0, .{ .reg = .xmm1 }),
            .Min => try cg.e.sse(.min, ft, .xmm0, .{ .reg = .xmm1 }),
            else => unreachable,
        }
        try cg.e.movFromXmm(size, .{ .reg = .r8 }, .xmm0);
        try cg.e.lockCmpxchg(size, mem, .r8);
        try cg.e.jcc(.ne, .{ .label = top });
        return cg.setResult(inst, ty, .rax);
    };
    switch (x.operation()) {
        .Xchg => {
            try cg.e.mov(.qword, .{ .reg = .rax }, .{ .reg = .rdx });
            try cg.e.xchg(size, .{ .mem = mem }, .rax);
        },
        .Add, .Sub => {
            try cg.e.mov(.qword, .{ .reg = .rax }, .{ .reg = .rdx });
            if (x.operation() == .Sub) try cg.e.unary(.neg, .qword, .{ .reg = .rax });
            try cg.e.lockXadd(size, mem, .rax);
        },
        .And, .Nand, .Or, .Xor, .Max, .Min => {
            const is_signed = Type.isInt(ip, ty) and Type.intInfo(ip, ty).signedness == .signed;
            try cg.e.mov(size, .{ .reg = .rax }, .{ .mem = mem });
            const top = try cg.e.newLabel();
            cg.e.bind(top);
            // r8 = the old value, extended like `rdx`.
            switch (size) {
                .qword => try cg.e.mov(.qword, .{ .reg = .r8 }, .{ .reg = .rax }),
                else => if (is_signed)
                    try cg.e.movsx(.qword, .r8, size, .{ .reg = .rax })
                else
                    try cg.e.movzx(.qword, .r8, size, .{ .reg = .rax }),
            }
            switch (x.operation()) {
                .And, .Nand => {
                    try cg.e.alu(.@"and", .qword, .{ .reg = .r8 }, .{ .reg = .rdx });
                    if (x.operation() == .Nand) {
                        try cg.e.unary(.not, .qword, .{ .reg = .r8 });
                        if (ty == .bool_type) try cg.e.alu(.@"and", .qword, .{ .reg = .r8 }, .{ .imm = 1 });
                    }
                },
                .Or => try cg.e.alu(.@"or", .qword, .{ .reg = .r8 }, .{ .reg = .rdx }),
                .Xor => try cg.e.alu(.xor, .qword, .{ .reg = .r8 }, .{ .reg = .rdx }),
                .Max, .Min => {
                    try cg.e.alu(.cmp, .qword, .{ .reg = .r8 }, .{ .reg = .rdx });
                    const take_operand: Encoder.Cond = switch (x.operation()) {
                        .Max => if (is_signed) .l else .b,
                        else => if (is_signed) .g else .a,
                    };
                    try cg.e.cmov(take_operand, .qword, .r8, .{ .reg = .rdx });
                },
                else => unreachable,
            }
            try cg.e.lockCmpxchg(size, mem, .r8);
            try cg.e.jcc(.ne, .{ .label = top });
        },
    }
    if (bytes < 8 and Type.hasRuntimeBits(ip, ty)) {
        // The old value in the low bytes of rax, extended like a load.
        if (cg.signed(ty)) try cg.e.movsx(.qword, .rax, size, .{ .reg = .rax }) else try cg.e.movzx(.qword, .rax, size, .{ .reg = .rax });
    }
    try cg.setResult(inst, ty, .rax);
}

// ---------------------------------------------------------------------------
// Inline assembly
//
// Templates use AT&T syntax, as upstream's x86_64 backend parses them. bs
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
        const c = asmAlternative(std.mem.trimStart(u8, ip.stringSlice(op.constraint), "=+"));
        if (regConstraint(c)) |rn| if (parseReg(rn)) |r| {
            used |= @as(u16, 1) << @backingInt(r.reg);
        };
    }
    // `=r` and `+r` outputs get registers that no other operand uses; a
    // `+r` register starts with the operand's value.
    const out_regs = try cg.gpa.alloc(Reg, outputs.len);
    defer cg.gpa.free(out_regs);
    for (outputs, out_regs) |out, *out_reg| {
        const full = ip.stringSlice(out.constraint);
        if (full.len == 0 or (full[0] != '=' and full[0] != '+')) return cg.fail("asm output constraint '{s}'", .{full});
        const read = full[0] == '+';
        const constraint = asmAlternative(full[1..]);
        const ty = if (out.operand == .none) data.ty_pl.ty else Type.ptrInfo(ip, cg.typeOf(out.operand)).child;
        if (std.mem.eql(u8, constraint, "r")) {
            const reg = for ([_]Reg{ .rax, .rcx, .rdx, .rsi, .rdi, .r8, .r9, .r10, .r11 }) |r| {
                if (used & (@as(u16, 1) << @backingInt(r)) == 0) break r;
            } else return cg.fail("asm with too many register operands", .{});
            used |= @as(u16, 1) << @backingInt(reg);
            out_reg.* = reg;
            try names.put(cg.gpa, ip.stringSlice(out.name), .{ .reg = .{ .reg = reg, .size = sizeOf(Type.abiSize(ip, ty)) } });
        } else {
            const reg_name = regConstraint(constraint) orelse return cg.fail("asm output constraint '{s}'", .{full});
            out_reg.* = (parseReg(reg_name) orelse return cg.fail("unknown register in asm constraint '{s}'", .{full})).reg;
            // The template may name it too, at the operand's size.
            const out_size = Type.abiSize(ip, ty);
            if (out_size == 1 or out_size == 2 or out_size == 4 or out_size == 8)
                try names.put(cg.gpa, ip.stringSlice(out.name), .{ .reg = .{ .reg = out_reg.*, .size = sizeOf(out_size) } });
        }
        if (read) {
            if (out.operand == .none) return cg.fail("asm output constraint '{s}'", .{full});
            try cg.load(out_reg.*, out.operand);
            try cg.loadMem(out_reg.*, Mem.at(out_reg.*, 0), ty);
        }
    }
    for (inputs) |in| {
        const constraint = asmAlternative(ip.stringSlice(in.constraint));
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
            // The template may name it too (`callq *%[callee]`), at the
            // operand's size.
            const in_size = Type.abiSize(ip, cg.typeOf(in.operand));
            if (in_size == 1 or in_size == 2 or in_size == 4 or in_size == 8)
                try names.put(cg.gpa, ip.stringSlice(in.name), .{ .reg = .{ .reg = reg.reg, .size = sizeOf(in_size) } });
        } else if (std.mem.eql(u8, constraint, "X") or std.mem.eql(u8, constraint, "i") or std.mem.eql(u8, constraint, "n")) {
            const arg: AsmArg = switch (try cg.locOf(in.operand)) {
                .imm => |v| .{ .imm = @bitCast(v) },
                .addr => |m| if (m.base == .sym) .{ .sym = .{ .key = m.base.sym, .off = m.disp } } else return cg.fail("asm input '{s}' must be comptime-known", .{constraint}),
                else => return cg.fail("asm input '{s}' must be comptime-known", .{constraint}),
            };
            try names.put(cg.gpa, ip.stringSlice(in.name), arg);
        } else return cg.fail("asm input constraint '{s}'", .{constraint});
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

/// Of comma-separated alternative constraints, the register one if there
/// is one, else the first.
fn asmAlternative(c: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, c, ',') == null) return c;
    var it = std.mem.splitScalar(u8, c, ',');
    while (it.next()) |alt| if (std.mem.eql(u8, alt, "r")) return alt;
    return c[0..std.mem.indexOfScalar(u8, c, ',').?];
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
    var locals: LocalLabels = .{};
    var source_lines = std.mem.tokenizeScalar(u8, source, '\n');
    while (source_lines.next()) |source_line| {
        // `#` and `//` start comments.
        var code = source_line;
        if (std.mem.indexOfScalar(u8, code, '#')) |i| code = code[0..i];
        if (std.mem.indexOf(u8, code, "//")) |i| code = code[0..i];
        var statements = std.mem.tokenizeScalar(u8, code, ';');
        while (statements.next()) |raw| try cg.assembleStatement(std.mem.trim(u8, raw, " \t\r"), names, &locals);
    }
    for (locals.fwd) |l| if (l != null) return cg.fail("asm refers to an undefined local label", .{});
}

/// GNU as local labels `0:` to `9:`, referenced as `1f` (the next) and
/// `1b` (the previous).
const LocalLabels = struct {
    fwd: [10]?Encoder.Label = @splat(null),
    back: [10]?Encoder.Label = @splat(null),
};

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
        // The only directive: std.start's `_start` marks the return
        // address undefined so unwinders stop at the outermost frame.
        if (std.mem.eql(u8, line, ".cfi_undefined %rip") or std.mem.eql(u8, line, ".cfi_undefined %%rip")) {
            cg.outermost_frame = true;
            return;
        }
        return cg.fail("bs does not support the assembler directive '{s}' yet", .{line});
    }
    const sp = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    const mnemonic = line[0..sp];
    const arg = std.mem.trim(u8, line[sp..], " \t");
    if (mnemonic[0] == 'j' and isLocalLabelRef(arg)) {
        // A jump to a local label.
        const label = try cg.localLabel(locals, arg, line);
        if (std.mem.eql(u8, mnemonic, "jmp")) return cg.e.jmp(.{ .label = label });
        const cond = asmCond(mnemonic[1..]) orelse return cg.fail("bs does not support this inline assembly instruction yet: '{s}'", .{line});
        return cg.e.jcc(cond, .{ .label = label });
    }
    // The address of a local label: `leaq 0f(%rip), %rdx`.
    if (std.mem.eql(u8, mnemonic, "lea") or std.mem.eql(u8, mnemonic, "leaq")) lea: {
        const comma = std.mem.indexOfScalar(u8, arg, ',') orelse break :lea;
        const mem = std.mem.trim(u8, arg[0..comma], " \t");
        const ref = for ([_][]const u8{ "(%rip)", "(%%rip)" }) |rip| {
            if (std.mem.endsWith(u8, mem, rip)) break mem[0 .. mem.len - rip.len];
        } else break :lea;
        if (!isLocalLabelRef(ref)) break :lea;
        const dst = switch (try cg.asmOperand(std.mem.trim(u8, arg[comma + 1 ..], " \t"), names, line)) {
            .reg => |r| if (r.size == .qword) r.reg else break :lea,
            else => break :lea,
        };
        return cg.e.leaLabel(dst, try cg.localLabel(locals, ref, line));
    }
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

/// `1f` or `1b`: a reference to the next or the previous local label `1:`.
fn isLocalLabelRef(arg: []const u8) bool {
    return arg.len == 2 and std.ascii.isDigit(arg[0]) and (arg[1] == 'f' or arg[1] == 'b');
}

fn localLabel(cg: *CodeGen, locals: *LocalLabels, ref: []const u8, line: []const u8) Error!Encoder.Label {
    const n = ref[0] - '0';
    if (ref[1] == 'b') return locals.back[n] orelse cg.fail("asm refers to an undefined local label: '{s}'", .{line});
    if (locals.fwd[n]) |l| return l;
    const l = try cg.e.newLabel();
    locals.fwd[n] = l;
    return l;
}

fn asmCond(name: []const u8) ?Encoder.Cond {
    const conds = [_]struct { []const u8, Encoder.Cond }{
        .{ "z", .e },   .{ "e", .e },   .{ "nz", .ne }, .{ "ne", .ne }, .{ "b", .b }, .{ "c", .b },
        .{ "ae", .ae }, .{ "nc", .ae }, .{ "be", .be }, .{ "a", .a },   .{ "l", .l }, .{ "ge", .ge },
        .{ "le", .le }, .{ "g", .g },   .{ "s", .s },   .{ "ns", .ns }, .{ "o", .o }, .{ "no", .no },
    };
    for (conds) |c| if (std.mem.eql(u8, name, c[0])) return c[1];
    return null;
}

fn asmOperand(cg: *CodeGen, tok_in: []const u8, names: *const std.StringHashMapUnmanaged(AsmArg), line: []const u8) Error!AsmOperand {
    // `*` marks an indirect call or jump target.
    const tok = if (tok_in.len > 1 and tok_in[0] == '*') tok_in[1..] else tok_in;
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
    return cg.fail("bs does not support asm operand '{s}' yet", .{tok});
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
            if (k == 0 and (std.mem.eql(u8, part, "%rip") or std.mem.eql(u8, part, "%%rip"))) {
                mem.base = .rip;
                continue;
            }
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
        return cg.fail("bs does not support this inline assembly instruction yet: '{s}'", .{line});
    }
    if (ops.len == 0) {
        if (eql(u8, mnemonic, "syscall")) return e.syscall();
        if (eql(u8, mnemonic, "ud2")) return e.ud2();
        if (eql(u8, mnemonic, "int3")) return e.int3();
        if (eql(u8, mnemonic, "pause")) return e.raw(&.{ 0xf3, 0x90 });
        if (eql(u8, mnemonic, "cpuid")) return e.raw(&.{ 0x0f, 0xa2 });
        if (eql(u8, mnemonic, "xgetbv")) return e.raw(&.{ 0x0f, 0x01, 0xd0 });
        if (eql(u8, mnemonic, "ret") or eql(u8, mnemonic, "retq")) return e.ret();
    } else if (ops.len == 1) {
        if (eql(u8, mnemonic, "call") or eql(u8, mnemonic, "callq") or eql(u8, mnemonic, "jmp") or eql(u8, mnemonic, "jmpq")) switch (ops[0]) {
            .sym => |s| {
                if (s.off != 0) return cg.fail("asm call with an offset: '{s}'", .{line});
                return if (mnemonic[0] == 'c') e.call(.{ .sym = s.key }) else e.jmp(.{ .sym = s.key });
            },
            .reg => |r| return if (mnemonic[0] == 'c') e.callIndirect(.{ .reg = r.reg }) else e.jmpIndirect(.{ .reg = r.reg }),
            // `jmpq *16(%rcx)`
            .mem => |m| if (!m.fs) return if (mnemonic[0] == 'c') e.callIndirect(.{ .mem = m.mem }) else e.jmpIndirect(.{ .mem = m.mem }),
            .imm => {},
        };
        if (eql(u8, mnemonic, "push") or eql(u8, mnemonic, "pushq")) switch (ops[0]) {
            .reg => |r| return e.push(r.reg),
            .imm => |v| if (std.math.cast(i32, v)) |imm| return e.pushImm(imm),
            .sym, .mem => {},
        };
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
    } else if (ops[1] == .reg and ops[0] == .mem and !ops[0].mem.fs and (eql(u8, mnemonic, "lea") or eql(u8, mnemonic, "leaq"))) {
        return e.lea(ops[1].reg.size, ops[1].reg.reg, ops[0].mem.mem);
    } else if (ops[1] == .reg) {
        // AT&T order: source, destination.
        const dst = ops[1].reg;
        // std's Crc32c with SSE4.2 (`-mcpu`): `crc32b %[byte], %[crc]`.
        if (mnemonic.len == 6 and std.mem.startsWith(u8, mnemonic, "crc32")) {
            const src_size: Size = switch (mnemonic[5]) {
                'b' => .byte,
                'w' => .word,
                'l' => .dword,
                'q' => .qword,
                else => return cg.fail("bs does not support this inline assembly instruction yet: '{s}'", .{line}),
            };
            const src: Encoder.Rm = switch (ops[0]) {
                .reg => |r| .{ .reg = r.reg },
                .mem => |m| if (m.fs) return cg.fail("bs does not support this inline assembly instruction yet: '{s}'", .{line}) else .{ .mem = m.mem },
                .imm, .sym => return cg.fail("bs does not support this inline assembly instruction yet: '{s}'", .{line}),
            };
            return e.crc32(dst.size, src_size, dst.reg, src);
        }
        // A size suffix, unless it is part of the name (`shl`, `sub`).
        const known = [_][]const u8{ "mov", "add", "or", "and", "sub", "xor", "cmp", "test", "rol", "ror", "shl", "sal", "shr", "sar", "xchg" };
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
        if (eql(u8, base, "test")) return e.@"test"(size, .{ .reg = dst.reg }, src);
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
    return cg.fail("bs does not support this inline assembly instruction yet: '{s}'", .{line});
}

// ---------------------------------------------------------------------------
// Constants

const PtrTarget = struct {
    key: SymbolKey,
    off: i64,
    /// For an external symbol (`extern_var`, `extern_func`), its name, and
    /// `key` is unset: the caller binds it, through a slot in code
    /// (`constLoc`) or directly in data (`lowerValue`).
    ext: ?InternPool.String = null,
};

/// The explicit alignment in bytes of pointer type `ptr_ty`, or 0.
fn explicitAlignment(ip: *const InternPool, ptr_ty: Index) u64 {
    const a = Type.ptrInfo(ip, ptr_ty).flags.alignment;
    return if (a == 0) 0 else @as(u64, 1) << @intCast(a - 1);
}

/// The symbol and offset a comptime-known pointer refers to.
/// Whether pointer value `ptr` points into a declaration or constant
/// without runtime bits (not a function or extern), which has no symbol:
/// as upstream's lowerNavRef and lowerUavRef, such a pointer is undefined
/// bytes.
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

pub fn ptrTarget(emit: *Emit, ptr: Index) Error!PtrTarget {
    const ip = &emit.zcu.ip;
    const p = ip.keyPayload(.ptr, ptr);
    var t: PtrTarget = switch (p.base) {
        .nav => |n| blk: {
            const nav = ip.getNav(n);
            // A data declaration's value may not be resolved yet (see
            // `ptrToZeroBit`); a function's is.
            if (Type.class(ip, nav.ty) == .@"fn" and ip.keyTag(nav.val) == .func) break :blk .{ .key = try emit.funcKey(nav.val), .off = 0 };
            break :blk .{ .key = try emit.navKey(n), .off = 0 };
        },
        .uav => |u| if (ip.keyTag(u.val) == .extern_func)
            .{ .key = undefined, .off = 0, .ext = ip.keyPayload(.extern_func, u.val).name }
        else if (ip.keyTag(u.val) == .extern_var)
            .{ .key = undefined, .off = 0, .ext = ip.keyPayload(.extern_var, u.val).name }
        else
            // A local constant declared `align(n)` keeps its alignment.
            .{ .key = try emit.uavKey(u.val, if (u.orig_ty == .none) 0 else explicitAlignment(ip, u.orig_ty)), .off = 0 },
        .field => |f| blk: {
            var parent = try ptrTarget(emit, f.base);
            const container = Type.ptrInfo(ip, ip.typeOf(f.base)).child;
            parent.off += @intCast(switch (ip.keyTag(container)) {
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
        // Two's complement, little-endian, sign- or zero-extended to the
        // ABI size.
        .int => |int| if (int.storage != .big) {
            const v: u64 = switch (int.storage) {
                .u64 => |x| x,
                .i64 => |x| @bitCast(x),
                .big => unreachable,
            };
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, v, .little);
            const n = @min(out.len, 8);
            @memcpy(out[0..n], bytes[0..n]);
            if (out.len > 8) @memset(out[8..], if (int.storage == .i64 and int.storage.i64 < 0) 0xff else 0);
        } else {
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
                const tag_int = if (ip.keyTag(u.tag) == .enum_tag) ip.keyPayload(.enum_tag, u.tag).int else u.tag;
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
            } else if (ptrToZeroBit(ip, val)) {
                @memset(out[0..8], 0xaa);
            } else {
                const t = try ptrTarget(emit, val);
                @memset(out[0..8], 0);
                if (t.ext) |name| {
                    const b = try emit.externDataTarget(ip.stringSlice(name));
                    try relocs.append(gpa, base_off, emit.abs64Kind(), b.key, t.off + b.addend);
                } else try relocs.append(gpa, base_off, emit.abs64Kind(), t.key, t.off);
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
            if (Type.optionalReprIsPayload(ip, child)) return lowerValue(emit, o.val, out, relocs, base_off);
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
                        .elems => |elems| {
                            // Tables repeat aggregate elements (uucode's
                            // 47,360 rows have 135 distinct values): copy the
                            // bytes of an element lowered before, unless it
                            // needed relocations, whose requests each use
                            // records again.
                            var seen: std.AutoHashMapUnmanaged(Index, u32) = .empty;
                            defer seen.deinit(gpa);
                            const memo = n >= 16 and switch (Type.class(ip, at.child)) {
                                .@"struct", .tuple, .@"union", .array, .optional, .error_union => true,
                                else => false,
                            };
                            for (elems[0..n], 0..) |el, i| {
                                const off: u32 = @intCast(i * esize);
                                if (memo) {
                                    const gop = try seen.getOrPut(gpa, el);
                                    if (gop.found_existing) {
                                        @memcpy(out[off..][0..esize], out[gop.value_ptr.*..][0..esize]);
                                        continue;
                                    }
                                    const relocs_len = relocs.relocs.items.len;
                                    try lowerValue(emit, el, out[off..][0..esize], relocs, base_off + off);
                                    if (relocs.relocs.items.len == relocs_len) gop.value_ptr.* = off else _ = seen.remove(el);
                                } else try lowerValue(emit, el, out[off..][0..esize], relocs, base_off + off);
                            }
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
                .struct_type, .tuple_type => if (Type.isPackedStruct(ip, ty)) {
                    // Each field's low bits at its bit offset in the backing
                    // integer.
                    for (0..Type.fieldCount(ip, ty)) |i| {
                        const ft = Type.fieldType(ip, ty, i);
                        const bits = Type.packedBits(ip, ft).?;
                        if (bits == 0) continue;
                        const el = switch (a.storage) {
                            .elems => |elems| elems[i],
                            .repeated_elem => |el| el,
                            .bytes => unreachable,
                        };
                        const tmp = try gpa.alloc(u8, @intCast(Type.abiSize(ip, ft)));
                        defer gpa.free(tmp);
                        @memset(tmp, 0);
                        const relocs_len = relocs.relocs.items.len;
                        try lowerValue(emit, el, tmp, relocs, 0);
                        assert(relocs.relocs.items.len == relocs_len); // no pointers in packed structs
                        const off = Type.packedFieldBitOffset(ip, ty, i);
                        for (0..bits) |b| {
                            const bit = (tmp[b / 8] >> @intCast(b % 8)) & 1;
                            const ob = off + b;
                            out[ob / 8] |= @as(u8, bit) << @intCast(ob % 8);
                        }
                    }
                } else {
                    const n = Type.fieldCount(ip, ty);
                    // A tuple's offsets, accumulated as `Type.tupleLayout`
                    // does: asking `fieldOffset` per field is quadratic.
                    const is_tuple = ip.keyTag(ty) == .tuple_type;
                    var tuple_off: u64 = 0;
                    for (0..n) |i| {
                        const ft = Type.fieldType(ip, ty, i);
                        if (!Type.hasRuntimeBits(ip, ft)) continue;
                        if (Type.comptimeFieldValue(ip, ty, i) != .none) continue;
                        const el = switch (a.storage) {
                            .elems => |elems| elems[i],
                            .repeated_elem => |el| el,
                            .bytes => unreachable,
                        };
                        const size = Type.abiSize(ip, ft);
                        const off: u32 = @intCast(if (is_tuple) std.mem.alignForward(u64, tuple_off, Type.abiAlignment(ip, ft)) else Type.fieldOffset(ip, ty, i));
                        if (is_tuple) tuple_off = off + size;
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

pub fn valOf(cg: *CodeGen, ref: Ref) Error!Val {
    if (cg.xmmOf(ref)) |x| return .{ .ty = cg.typeOf(ref), .loc = .{ .xmm = x } };
    return .{ .ty = cg.typeOf(ref), .loc = try cg.locOf(ref) };
}

fn memVal(ty: Index, m: Mem) Val {
    return .{ .ty = ty, .loc = .{ .mem = m } };
}

fn loadVal(cg: *CodeGen, reg: Reg, v: Val) Error!void {
    switch (v.loc) {
        .none => try cg.e.mov(.dword, .{ .reg = reg }, .{ .imm = 0 }),
        .reg => |r| if (r != reg) try cg.e.mov(.qword, .{ .reg = reg }, .{ .reg = r }),
        .imm => |x| try cg.e.mov(.qword, .{ .reg = reg }, .{ .imm = @bitCast(x) }),
        .addr => |m| try cg.e.lea(.qword, reg, m),
        .err => |name| try cg.loadError(reg, name),
        .mem => |m| try cg.loadMem(reg, m, v.ty),
        .xmm => |x| try cg.e.movFromXmm(sizeOf(Type.abiSize(cg.ip, v.ty)), .{ .reg = reg }, x),
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
    } else if (v.loc == .xmm) {
        try cg.storeXmm(m, v.loc.xmm, size);
    } else {
        try cg.loadVal(.rax, v);
        try cg.storeReg(m, .rax, size);
    }
    return m;
}

/// Loads a value of 2, 4, 8, or 16 bytes into the low bits of `x`. Uses rax.
pub fn loadXmm(cg: *CodeGen, x: Encoder.Xmm, v: Val) Error!void {
    const size = Type.abiSize(cg.ip, v.ty);
    if (v.loc == .xmm) {
        if (v.loc.xmm != x) try cg.e.movups(.{ .reg = x }, .{ .reg = v.loc.xmm });
        return;
    }
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

/// The SysV class of one eightbyte of a value (the psABI's INTEGER, SSE,
/// SSEUP, X87, X87UP, NO_CLASS, and MEMORY).
const Eb = enum { none, int, sse, sseup, x87, x87up, memory };

/// How the C convention passes a value of a type:
/// - `int`: in one GPR, a 1-, 2-, 4-, or 8-byte value of class INTEGER,
///   extended like a load;
/// - `int_pair`: a 16-byte integer, in two GPRs;
/// - `sse`: a float, or a 16-byte SSE/SSEUP value, in one XMM register;
/// - `agg`: any other value of one or two eightbytes in registers, each
///   `.int` (the next GPR) or `.sse` (the next XMM register), read from and
///   written to the value's memory; the second may be `.none`;
/// - `x87`: an `f80` (or a struct of one), in memory as an argument and in
///   st0 as a result;
/// - `memory`: in the outgoing area as an argument, through a pointer in
///   rdi as a result;
/// - results only (`cRetClass`), vectors over 16 bytes as Clang returns
///   them without AVX: `xwords`, in xmm0 and on, 16 bytes each;
///   `qwords3`, three 8-byte elements in rax, rdx, and rcx (`.int`) or in
///   xmm0, xmm1, and st0 (`.sse`);
/// - arguments only, a bool vector of 65 to 128 elements as Clang passes
///   it: `elems`, one element (0 or 1) per GPR while GPRs are left, the
///   rest in 8-byte slots of the outgoing area.
const CClass = union(enum) { none, int, int_pair, sse, agg: [2]Eb, x87, memory, xwords: u8, qwords3: Eb, elems: u8 };

/// The class of a C argument of type `ty`.
fn cClass(cg: *CodeGen, ty: Index) CClass {
    return cg.cClassCtx(ty, false);
}

/// The class of a C function's result of type `ty`.
fn cRetClass(cg: *CodeGen, ty: Index) CClass {
    return cg.cClassCtx(ty, true);
}

fn cClassCtx(cg: *CodeGen, ty: Index, is_ret: bool) CClass {
    const ip = cg.ip;
    if (!Type.hasRuntimeBits(ip, ty)) return .none;
    switch (Type.class(ip, ty)) {
        .float => return if (Type.floatBits(ip, ty) == 80) .x87 else .sse,
        .vector => return cg.cVectorClass(ty, is_ret),
        .@"struct", .@"union", .array, .tuple => {},
        else => {
            if (cg.passInRegs(ty)) return .int;
            if (Type.isInt(ip, ty) and Type.abiSize(ip, ty) == 16) return .int_pair;
            return .memory;
        },
    }
    // Aggregates and vectors: each eightbyte gets the class of the fields
    // in it (psABI 3.2.3), as upstream's `classifySystemV`. bs's target
    // has no AVX, so anything over two eightbytes is in memory.
    const size = Type.abiSize(ip, ty);
    if (size > 16) return .memory;
    var ebs: [2]Eb = .{ .none, .none };
    if (!cg.cClassify(&ebs, ty, 0, true)) return .memory;
    for (ebs, 0..) |eb, i| switch (eb) {
        .memory => return .memory,
        .x87up => if (i == 0 or ebs[i - 1] != .x87) return .memory,
        else => {},
    };
    if (ebs[0] == .x87) return .x87;
    if (ebs[0] == .sse and ebs[1] == .sseup) return .sse;
    // SSEUP not preceded by SSE is SSE.
    if (ebs[1] == .sseup) ebs[1] = .sse;
    if (ebs[0] == .sseup) ebs[0] = .sse;
    if (ebs[0] == .int and ebs[1] == .none and cg.passInRegs(ty)) return .int;
    return .{ .agg = ebs };
}

/// A vector's class, as upstream's `classifySystemV` (which follows
/// Clang) on a CPU without AVX: by the bytes of its elements, not its
/// 16-byte aligned size.
fn cVectorClass(cg: *CodeGen, ty: Index, is_ret: bool) CClass {
    const ip = cg.ip;
    const v = ip.keyPayload(.vector_type, ty);
    const one_int: CClass = if (cg.passInRegs(ty)) .int else .{ .agg = .{ .int, .none } };
    if (v.child == .bool_type) {
        if (v.len <= 32) return one_int;
        if (v.len <= 64) return .{ .agg = .{ .sse, .none } };
        if (v.len <= 128 and !is_ret) return .{ .elems = @intCast(v.len) };
        return .memory;
    }
    const float = Type.class(ip, v.child) == .float;
    if (float and Type.floatBits(ip, v.child) == 80) return if (v.len == 1) .x87 else .memory;
    const bytes = Type.abiSize(ip, v.child) * v.len;
    if (bytes <= 4) return one_int;
    // GCC passes <1 x double> in memory.
    if (bytes == 8 and v.len == 1 and float and !is_ret) return .memory;
    if (bytes <= 8) return .{ .agg = .{ .sse, .none } };
    if (bytes <= 16) return .sse;
    if (is_ret) {
        if (bytes == 24 and v.len == 3) return .{ .qwords3 = if (float) .sse else .int };
        if (bytes == 32 or bytes == 64) return .{ .xwords = @intCast(bytes / 16) };
    }
    return .memory;
}

/// Merges the classes of the bytes `ty` covers at offset `off` into
/// `ebs`; false if they reach past the second eightbyte or take MEMORY.
/// `top` is whether `ty` is the value itself rather than a field of it.
fn cClassify(cg: *CodeGen, ebs: *[2]Eb, ty: Index, off: u64, top: bool) bool {
    const ip = cg.ip;
    const size = Type.abiSize(ip, ty);
    if (size == 0) return true;
    switch (Type.class(ip, ty)) {
        .float => return switch (Type.floatBits(ip, ty)) {
            // As upstream: an f16 field puts its aggregate in memory.
            16 => if (top) mergeEb(ebs, off, 2, .sse) else false,
            32, 64 => mergeEb(ebs, off, size, .sse),
            80 => mergeEb(ebs, off, 8, .x87) and mergeEb(ebs, off + 8, 8, .x87up),
            128 => mergeEb(ebs, off, 8, .sse) and mergeEb(ebs, off + 8, 8, .sseup),
            else => unreachable,
        },
        .@"struct", .@"union" => {
            // A packed container is its backing integer.
            if (Type.isPacked(ip, ty)) return mergeEb(ebs, off, size, .int);
            for (0..Type.fieldCount(ip, ty)) |i| {
                const f = Type.fieldType(ip, ty, i);
                if (Type.comptimeFieldValue(ip, ty, i) != .none) continue;
                if (!cg.cClassify(ebs, f, off + Type.fieldOffset(ip, ty, i), false)) return false;
            }
            return true;
        },
        .tuple => {
            for (0..Type.fieldCount(ip, ty)) |i| {
                if (Type.comptimeFieldValue(ip, ty, i) != .none) continue;
                if (!cg.cClassify(ebs, Type.fieldType(ip, ty, i), off + Type.fieldOffset(ip, ty, i), false)) return false;
            }
            return true;
        },
        .array => {
            const a = ip.keyPayload(.array_type, ty);
            const elem_size = Type.abiSize(ip, a.child);
            const n = a.len + @intFromBool(a.sentinel != .none);
            for (0..n) |i| if (!cg.cClassify(ebs, a.child, off + i * elem_size, false)) return false;
            return true;
        },
        .vector => {
            // As upstream: bool vectors are bit masks; a vector of up to 4
            // bytes is INTEGER; else SSE, SSEUP for its second eightbyte.
            const v = ip.keyPayload(.vector_type, ty);
            if (v.child == .bool_type) return if (v.len <= 32) mergeEb(ebs, off, 4, .int) else if (v.len <= 64) mergeEb(ebs, off, 8, .sse) else false;
            if (Type.class(ip, v.child) == .float and Type.floatBits(ip, v.child) == 80) return false;
            const bytes = Type.abiSize(ip, v.child) * v.len;
            if (bytes <= 4) return mergeEb(ebs, off, size, .int);
            if (bytes <= 8) return mergeEb(ebs, off, 8, .sse);
            return mergeEb(ebs, off, 8, .sse) and mergeEb(ebs, off + 8, 8, .sseup);
        },
        .optional => {
            if (!Type.optionalReprIsPayload(ip, Type.childType(ip, ty))) return false;
            return mergeEb(ebs, off, size, .int);
        },
        else => return mergeEb(ebs, off, size, .int),
    }
}

/// Merges class `c` into the eightbytes that bytes `off..off + size`
/// touch, as the psABI's merge: equal classes stay, NO_CLASS yields,
/// MEMORY wins, then INTEGER, then X87 classes (MEMORY), else SSE.
fn mergeEb(ebs: *[2]Eb, off: u64, size: u64, c: Eb) bool {
    if (off + size > 16) return false;
    var i = off / 8;
    while (i * 8 < off + size) : (i += 1) {
        const cur = ebs[i];
        ebs[i] = if (cur == c or c == .none) cur else if (cur == .none) c else if (cur == .memory or c == .memory) .memory else if (cur == .int or c == .int) .int else if (cur == .x87 or cur == .x87up or c == .x87 or c == .x87up) .memory else .sse;
    }
    return true;
}

/// The registers a C value of class `c` takes: GPRs and XMM registers.
fn cRegCount(c: CClass) struct { gp: u8, sse: u8 } {
    return switch (c) {
        .int => .{ .gp = 1, .sse = 0 },
        .int_pair => .{ .gp = 2, .sse = 0 },
        .sse => .{ .gp = 0, .sse = 1 },
        .agg => |ebs| .{
            .gp = @as(u8, @intFromBool(ebs[0] == .int)) + @intFromBool(ebs[1] == .int),
            .sse = @as(u8, @intFromBool(ebs[0] == .sse)) + @intFromBool(ebs[1] == .sse),
        },
        .none, .x87, .memory, .xwords, .qwords3, .elems => .{ .gp = 0, .sse = 0 },
    };
}

/// The bytes of eightbyte `i` of a value of `size` bytes.
fn ebBytes(size: u64, i: usize) u64 {
    return @min(8, size - 8 * i);
}

const xmm_args = [_]Encoder.Xmm{ .xmm0, .xmm1, .xmm2, .xmm3, .xmm4, .xmm5, .xmm6, .xmm7 };

/// Where a C argument goes: its first GPR and XMM register (an `agg` takes
/// them in eightbyte order), or its offset in the outgoing area; for an
/// `elems` vector, its first GPR and the offset of its elements that do
/// not fit the GPRs.
const CArgLoc = union(enum) { none, regs: struct { gp: u8, sse: u8 }, stack: u32, elems: struct { gp: u8, stack: u32 } };

/// Loads element `i` of the bool vector at `m`, a bit mask, into `reg`
/// as 0 or 1.
fn loadBoolElem(cg: *CodeGen, reg: Reg, m: Mem, i: u32) Error!void {
    try cg.e.movzx(.dword, reg, .byte, .{ .mem = offsetMem(m, i / 8) });
    if (i % 8 != 0) try cg.e.shift(.shr, .dword, .{ .reg = reg }, @intCast(i % 8));
    try cg.e.alu(.@"and", .dword, .{ .reg = reg }, .{ .imm = 1 });
}

/// Places the arguments of a call to a C function: memory arguments in the
/// outgoing area first (copies use rax, rsi, rdi, rcx), then SSE registers
/// (rax), then GPRs (r11). A result returned in memory goes to `dst`,
/// passed in rdi. Returns how many XMM registers hold arguments.
fn cCallArgs(cg: *CodeGen, args: []const Val, ret_ty: Index, dst: ?Mem) Error!u8 {
    const ip = cg.ip;
    const locs = try cg.gpa.alloc(CArgLoc, args.len);
    defer cg.gpa.free(locs);
    const sret = dst != null and cg.cRetClass(ret_ty) == .memory;
    var gp: u8 = @intFromBool(sret);
    var sse: u8 = 0;
    var stack: u32 = 0;
    for (args, locs) |a, *l| {
        const class = cg.cClass(a.ty);
        if (class == .none) {
            l.* = .none;
            continue;
        }
        if (class == .elems) {
            const regs = @min(class.elems, 6 - gp);
            stack = std.mem.alignForward(u32, stack, 8);
            l.* = .{ .elems = .{ .gp = gp, .stack = stack } };
            gp += regs;
            stack += 8 * @as(u32, class.elems - regs);
            continue;
        }
        const n = cRegCount(class);
        // A value that does not fit the registers left goes in memory
        // whole, and the registers stay for later arguments.
        if ((n.gp != 0 or n.sse != 0) and gp + n.gp <= 6 and sse + n.sse <= 8) {
            l.* = .{ .regs = .{ .gp = gp, .sse = sse } };
            gp += n.gp;
            sse += n.sse;
            continue;
        }
        stack = std.mem.alignForward(u32, stack, if (Type.abiAlignment(ip, a.ty) >= 16) 16 else 8);
        l.* = .{ .stack = stack };
        stack += @intCast(std.mem.alignForward(u64, Type.abiSize(ip, a.ty), 8));
    }
    cg.out_args_size = @max(cg.out_args_size, stack);
    for (args, locs) |a, l| switch (l) {
        .stack => |off| try cg.copyMem(Mem.at(.rsp, @intCast(off)), try cg.valMem(a), Type.abiSize(ip, a.ty)),
        .elems => |e| {
            const m = try cg.valMem(a);
            const len = cg.cClass(a.ty).elems;
            for (@min(len, 6 - e.gp)..len, 0..) |i, j| {
                try cg.loadBoolElem(.rax, m, @intCast(i));
                try cg.e.mov(.qword, .{ .mem = Mem.at(.rsp, @intCast(e.stack + 8 * j)) }, .{ .reg = .rax });
            }
        },
        else => {},
    };
    // The memory of the values read by eightbyte, before any argument
    // register is written (materializing one may use rdi and rcx).
    const mems = try cg.gpa.alloc(Mem, args.len);
    defer cg.gpa.free(mems);
    for (args, locs, mems) |a, l, *m| if (l != .none and l != .stack) switch (cg.cClass(a.ty)) {
        .agg, .int_pair, .elems => m.* = try cg.valMem(a),
        else => {},
    };
    for (args, locs, mems) |a, l, m| if (l == .regs) switch (cg.cClass(a.ty)) {
        .sse => try cg.loadXmm(xmm_args[l.regs.sse], a),
        .agg => |ebs| {
            var x = l.regs.sse;
            for (ebs, 0..) |eb, i| if (eb == .sse) {
                try cg.loadXmmBytes(xmm_args[x], offsetMem(m, 8 * i), ebBytes(Type.abiSize(ip, a.ty), i));
                x += 1;
            };
        },
        else => {},
    };
    for (args, locs, mems) |a, l, m| if (l == .regs) switch (cg.cClass(a.ty)) {
        .int => try cg.loadVal(c_arg_regs[l.regs.gp], a),
        .int_pair => {
            try cg.e.mov(.qword, .{ .reg = c_arg_regs[l.regs.gp] }, .{ .mem = m });
            try cg.e.mov(.qword, .{ .reg = c_arg_regs[l.regs.gp + 1] }, .{ .mem = offsetMem(m, 8) });
        },
        .agg => |ebs| {
            var r = l.regs.gp;
            for (ebs, 0..) |eb, i| if (eb == .int) {
                try cg.loadBytes(c_arg_regs[r], offsetMem(m, 8 * i), ebBytes(Type.abiSize(ip, a.ty), i));
                r += 1;
            };
        },
        else => {},
    };
    for (args, locs, mems) |a, l, m| if (l == .elems) {
        const len = cg.cClass(a.ty).elems;
        for (l.elems.gp..@min(6, l.elems.gp + len), 0..) |r, i| try cg.loadBoolElem(c_arg_regs[r], m, @intCast(i));
    };
    if (sret) try cg.e.lea(.qword, .rdi, dst.?);
    return sse;
}

/// Loads the `n` bytes at `m` (4 or 8 directly, others through rax) into
/// the low bits of `x`.
fn loadXmmBytes(cg: *CodeGen, x: Encoder.Xmm, m: Mem, n: u64) Error!void {
    switch (n) {
        4 => try cg.e.movs(.f32, .{ .reg = x }, .{ .mem = m }),
        8 => try cg.e.movs(.f64, .{ .reg = x }, .{ .mem = m }),
        else => {
            try cg.loadBytes(.rax, m, n);
            try cg.e.movToXmm(.qword, x, .{ .reg = .rax });
        },
    }
}

/// Stores the eightbytes of a C value of class `ebs` and `size` bytes from
/// the registers they arrive in, `gp` and `sse` the first of each, to `m`:
/// the GPRs first (r11), then the XMM registers (rax).
fn storeEbs(cg: *CodeGen, m: Mem, ebs: [2]Eb, size: u64, gps: []const Reg, gp: u8, sse: u8) Error!void {
    var r = gp;
    for (ebs, 0..) |eb, i| if (eb == .int) {
        try cg.storeBytes(offsetMem(m, 8 * i), gps[r], ebBytes(size, i));
        r += 1;
    };
    var x = sse;
    for (ebs, 0..) |eb, i| if (eb == .sse) {
        try cg.storeXmm(offsetMem(m, 8 * i), xmm_args[x], ebBytes(size, i));
        x += 1;
    };
}

/// Loads the eightbytes of a C value of class `ebs` and `size` bytes at
/// `m` into the registers that return it: the XMM registers first (rax),
/// then rax and rdx (r11).
fn loadEbs(cg: *CodeGen, m: Mem, ebs: [2]Eb, size: u64) Error!void {
    var x: u8 = 0;
    for (ebs, 0..) |eb, i| if (eb == .sse) {
        try cg.loadXmmBytes(xmm_args[x], offsetMem(m, 8 * i), ebBytes(size, i));
        x += 1;
    };
    var r: u8 = 0;
    for (ebs, 0..) |eb, i| if (eb == .int) {
        try cg.loadBytes(c_ret_regs[r], offsetMem(m, 8 * i), ebBytes(size, i));
        r += 1;
    };
}

const c_ret_regs = [_]Reg{ .rax, .rdx };

/// Stores the result of a C call, of type `ret_ty`, to `dst`.
fn cCallResult(cg: *CodeGen, ret_ty: Index, dst: ?Mem) Error!void {
    const m = dst orelse return;
    switch (cg.cRetClass(ret_ty)) {
        .none, .memory => {},
        .elems => unreachable,
        .xwords => |n| for (0..n) |i| try cg.e.movups(.{ .mem = offsetMem(m, 16 * i) }, .{ .reg = xmm_args[i] }),
        .qwords3 => |eb| if (eb == .int) {
            for ([_]Reg{ .rax, .rdx, .rcx }, 0..) |reg, i| try cg.e.mov(.qword, .{ .mem = offsetMem(m, 8 * i) }, .{ .reg = reg });
        } else {
            try cg.e.movs(.f64, .{ .mem = m }, .{ .reg = .xmm0 });
            try cg.e.movs(.f64, .{ .mem = offsetMem(m, 8) }, .{ .reg = .xmm1 });
            try cg.e.fstp(.m64, offsetMem(m, 16));
        },
        .int => try cg.storeReg(m, .rax, Type.abiSize(cg.ip, ret_ty)),
        .int_pair => {
            try cg.e.mov(.qword, .{ .mem = m }, .{ .reg = .rax });
            try cg.e.mov(.qword, .{ .mem = offsetMem(m, 8) }, .{ .reg = .rdx });
        },
        .sse => try cg.storeXmm(m, .xmm0, Type.abiSize(cg.ip, ret_ty)),
        .agg => |ebs| try cg.storeEbs(m, ebs, Type.abiSize(cg.ip, ret_ty), &c_ret_regs, 0, 0),
        .x87 => try cg.e.fstp(.m80, m),
    }
}

/// The callee side of the C convention: gives each `arg` a home, spilling
/// register arguments to slots.
fn setupCParams(cg: *CodeGen) Error!void {
    const ip = cg.ip;
    var gp: u8 = 0;
    if (cg.cRetClass(cg.fn_ty.return_type) == .memory) {
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
        const class = cg.cClass(ty);
        if (class == .none) continue;
        if (class == .elems) {
            // Gather the elements into the vector's bit mask.
            const m = Mem.at(.rbp, try cg.allocSlot(size, Type.abiAlignment(ip, ty)));
            cg.homes[@backingInt(inst)] = .{ .slot = m.disp };
            for (0..size / 8) |i| try cg.e.mov(.qword, .{ .mem = offsetMem(m, 8 * i) }, .{ .imm = 0 });
            const regs = @min(class.elems, 6 - gp);
            stack = std.mem.alignForward(u32, stack, 8);
            for (0..class.elems) |i| {
                if (i < regs) {
                    try cg.e.mov(.dword, .{ .reg = .rax }, .{ .reg = c_arg_regs[gp + i] });
                } else {
                    try cg.e.mov(.dword, .{ .reg = .rax }, .{ .mem = Mem.at(.rbp, @intCast(16 + stack)) });
                    stack += 8;
                }
                try cg.e.alu(.@"and", .dword, .{ .reg = .rax }, .{ .imm = 1 });
                if (i % 8 != 0) try cg.e.shift(.shl, .dword, .{ .reg = .rax }, @intCast(i % 8));
                try cg.e.alu(.@"or", .byte, .{ .mem = offsetMem(m, i / 8) }, .{ .reg = .rax });
            }
            gp += regs;
            continue;
        }
        const n = cRegCount(class);
        if ((n.gp == 0 and n.sse == 0) or gp + n.gp > 6 or sse + n.sse > 8) {
            stack = std.mem.alignForward(u32, stack, if (Type.abiAlignment(ip, ty) >= 16) 16 else 8);
            cg.homes[@backingInt(inst)] = .{ .slot = @intCast(16 + stack) };
            stack += @intCast(std.mem.alignForward(u64, size, 8));
            continue;
        }
        const m = Mem.at(.rbp, try cg.allocSlot(size, Type.abiAlignment(ip, ty)));
        cg.homes[@backingInt(inst)] = .{ .slot = m.disp };
        switch (class) {
            .int => try cg.storeReg(m, c_arg_regs[gp], size),
            .int_pair => {
                try cg.e.mov(.qword, .{ .mem = m }, .{ .reg = c_arg_regs[gp] });
                try cg.e.mov(.qword, .{ .mem = offsetMem(m, 8) }, .{ .reg = c_arg_regs[gp + 1] });
            },
            .sse => try cg.storeXmm(m, xmm_args[sse], size),
            .agg => |ebs| try cg.storeEbs(m, ebs, size, &c_arg_regs, gp, sse),
            else => unreachable,
        }
        gp += n.gp;
        sse += n.sse;
    }
    if (cg.fn_ty.is_var_args) {
        // The SysV register save area: the six argument GPRs, then the
        // eight argument XMM registers at 16-byte strides.
        const save = try cg.allocSlot(176, 16);
        for (c_arg_regs, 0..) |r, i| try cg.e.mov(.qword, .{ .mem = Mem.at(.rbp, save + @as(i32, @intCast(i * 8))) }, .{ .reg = r });
        for (xmm_args, 0..) |x, i| try cg.storeXmm(Mem.at(.rbp, save + 48 + @as(i32, @intCast(i * 16))), x, 16);
        cg.va = .{ .save = save, .gp = gp, .sse = sse, .stack = stack };
    }
}

/// `@cVaStart()`: a SysV `va_list` past the named parameters.
fn cVaStart(cg: *CodeGen, inst: Inst.Index, ty: Index) Error!void {
    const dst = try cg.resultMem(inst, ty) orelse return;
    if (cg.fn_ty.cc == .x86_64_win) {
        // Win64's: the address of the first variadic argument, in the
        // first field of the target's `VaList`, as upstream.
        try cg.e.lea(.qword, .rax, Mem.at(.rbp, @intCast(16 + cg.va.stack)));
        return cg.e.mov(.qword, .{ .mem = dst }, .{ .reg = .rax });
    }
    try cg.e.mov(.dword, .{ .mem = dst }, .{ .imm = @as(i32, cg.va.gp) * 8 });
    try cg.e.mov(.dword, .{ .mem = offsetMem(dst, 4) }, .{ .imm = 48 + @as(i32, cg.va.sse) * 16 });
    try cg.e.lea(.qword, .rax, Mem.at(.rbp, @intCast(16 + cg.va.stack)));
    try cg.e.mov(.qword, .{ .mem = offsetMem(dst, 8) }, .{ .reg = .rax });
    try cg.e.lea(.qword, .rax, Mem.at(.rbp, cg.va.save));
    try cg.e.mov(.qword, .{ .mem = offsetMem(dst, 16) }, .{ .reg = .rax });
}

/// `@cVaArg(list, T)`, as the SysV ABI's `va_arg`: from the register save
/// area while enough registers of each of `T`'s classes remain, else from
/// the overflow area. rdx ends up addressing the value's bytes; an
/// aggregate's eightbytes are gathered from the save area into a slot.
fn cVaArg(cg: *CodeGen, inst: Inst.Index, ty: Index, list: Ref) Error!void {
    const ip = cg.ip;
    const size = Type.abiSize(ip, ty);
    try cg.load(.rcx, list);
    if (cg.fn_ty.cc == .x86_64_win) {
        // Win64's: each argument in an 8-byte slot, a value passed by
        // reference through its pointer.
        try cg.e.mov(.qword, .{ .reg = .rdx }, .{ .mem = Mem.at(.rcx, 0) });
        try cg.e.alu(.add, .qword, .{ .mem = Mem.at(.rcx, 0) }, .{ .imm = 8 });
        if (cg.winClass(ty, false) == .ref) try cg.e.mov(.qword, .{ .reg = .rdx }, .{ .mem = Mem.at(.rdx, 0) });
        const dst = try cg.resultMem(inst, ty) orelse return;
        if (ty == .f32_type) {
            try cg.e.cvts2s(.f32, .xmm0, .{ .mem = Mem.at(.rdx, 0) });
            return cg.storeXmm(dst, .xmm0, 4);
        }
        return cg.copyMem(dst, Mem.at(.rdx, 0), size);
    }
    const class = cg.cClass(ty);
    const on_stack = try cg.e.newLabel();
    const done = try cg.e.newLabel();
    // The register class's offset field, its limit, and its stride.
    const reg: ?struct { field: u32, limit: i32, step: i32 } = switch (class) {
        .int => .{ .field = 0, .limit = 48, .step = 8 },
        .int_pair => .{ .field = 0, .limit = 40, .step = 16 },
        .sse => .{ .field = 4, .limit = 176, .step = 16 },
        else => null,
    };
    if (reg) |r| {
        try cg.e.mov(.dword, .{ .reg = .rax }, .{ .mem = Mem.at(.rcx, @intCast(r.field)) });
        try cg.e.alu(.cmp, .dword, .{ .reg = .rax }, .{ .imm = r.limit });
        try cg.e.jcc(.ae, .{ .label = on_stack });
        try cg.e.mov(.qword, .{ .reg = .rdx }, .{ .mem = Mem.at(.rcx, 16) });
        try cg.e.alu(.add, .qword, .{ .reg = .rdx }, .{ .reg = .rax });
        try cg.e.alu(.add, .dword, .{ .reg = .rax }, .{ .imm = r.step });
        try cg.e.mov(.dword, .{ .mem = Mem.at(.rcx, @intCast(r.field)) }, .{ .reg = .rax });
        try cg.e.jmp(.{ .label = done });
    }
    if (class == .agg) {
        const n = cRegCount(class);
        if (n.gp != 0) {
            try cg.e.mov(.dword, .{ .reg = .rax }, .{ .mem = Mem.at(.rcx, 0) });
            try cg.e.alu(.cmp, .dword, .{ .reg = .rax }, .{ .imm = 48 - 8 * @as(i32, n.gp) });
            try cg.e.jcc(.a, .{ .label = on_stack });
        }
        if (n.sse != 0) {
            try cg.e.mov(.dword, .{ .reg = .rax }, .{ .mem = Mem.at(.rcx, 4) });
            try cg.e.alu(.cmp, .dword, .{ .reg = .rax }, .{ .imm = 176 - 16 * @as(i32, n.sse) });
            try cg.e.jcc(.a, .{ .label = on_stack });
        }
        const slot = Mem.at(.rbp, try cg.allocSlot(16, 8));
        for (class.agg, 0..) |eb, i| {
            if (eb == .none) continue;
            const field: u32, const step: i32 = if (eb == .int) .{ 0, 8 } else .{ 4, 16 };
            try cg.e.mov(.dword, .{ .reg = .rax }, .{ .mem = Mem.at(.rcx, @intCast(field)) });
            try cg.e.mov(.qword, .{ .reg = .rdx }, .{ .mem = Mem.at(.rcx, 16) });
            try cg.e.alu(.add, .qword, .{ .reg = .rdx }, .{ .reg = .rax });
            try cg.e.mov(.qword, .{ .reg = .rdx }, .{ .mem = Mem.at(.rdx, 0) });
            try cg.e.mov(.qword, .{ .mem = offsetMem(slot, 8 * i) }, .{ .reg = .rdx });
            try cg.e.alu(.add, .dword, .{ .reg = .rax }, .{ .imm = step });
            try cg.e.mov(.dword, .{ .mem = Mem.at(.rcx, @intCast(field)) }, .{ .reg = .rax });
        }
        try cg.e.lea(.qword, .rdx, slot);
        try cg.e.jmp(.{ .label = done });
    }
    cg.e.bind(on_stack);
    try cg.e.mov(.qword, .{ .reg = .rdx }, .{ .mem = Mem.at(.rcx, 8) });
    if (Type.abiAlignment(ip, ty) >= 16) {
        try cg.e.alu(.add, .qword, .{ .reg = .rdx }, .{ .imm = 15 });
        try cg.e.alu(.@"and", .qword, .{ .reg = .rdx }, .{ .imm = -16 });
    }
    try cg.e.lea(.qword, .rax, Mem.at(.rdx, @intCast(std.mem.alignForward(u64, size, 8))));
    try cg.e.mov(.qword, .{ .mem = Mem.at(.rcx, 8) }, .{ .reg = .rax });
    cg.e.bind(done);
    const dst = try cg.resultMem(inst, ty) orelse return;
    // Callers promote a variadic f32 to f64, as C does.
    if (ty == .f32_type) {
        try cg.e.cvts2s(.f32, .xmm0, .{ .mem = Mem.at(.rdx, 0) });
        return cg.storeXmm(dst, .xmm0, 4);
    }
    try cg.copyMem(dst, Mem.at(.rdx, 0), size);
}

/// Returns `operand` from a C-convention function.
fn cRet(cg: *CodeGen, operand: Ref) Error!void {
    const ty = cg.fn_ty.return_type;
    switch (cg.cRetClass(ty)) {
        .none => {},
        .elems => unreachable,
        .int => try cg.load(.rax, operand),
        .xwords => |n| {
            const m = try cg.memOf(operand);
            for (0..n) |i| try cg.e.movups(.{ .reg = xmm_args[i] }, .{ .mem = offsetMem(m, 16 * i) });
        },
        .qwords3 => |eb| {
            const m = try cg.memOf(operand);
            if (eb == .int) {
                for ([_]Reg{ .rax, .rdx, .rcx }, 0..) |reg, i| try cg.e.mov(.qword, .{ .reg = reg }, .{ .mem = offsetMem(m, 8 * i) });
            } else {
                try cg.e.movs(.f64, .{ .reg = .xmm0 }, .{ .mem = m });
                try cg.e.movs(.f64, .{ .reg = .xmm1 }, .{ .mem = offsetMem(m, 8) });
                try cg.e.fld(.m64, offsetMem(m, 16));
            }
        },
        .int_pair => {
            const m = try cg.memOf(operand);
            try cg.e.mov(.qword, .{ .reg = .rax }, .{ .mem = m });
            try cg.e.mov(.qword, .{ .reg = .rdx }, .{ .mem = offsetMem(m, 8) });
        },
        .sse => try cg.loadXmm(.xmm0, try cg.valOf(operand)),
        .agg => |ebs| try cg.loadEbs(try cg.memOf(operand), ebs, Type.abiSize(cg.ip, ty)),
        .x87 => try cg.e.fld(.m80, try cg.memOf(operand)),
        .memory => {
            try cg.e.mov(.qword, .{ .reg = .r10 }, .{ .mem = Mem.at(.rbp, cg.ret_ptr_slot.?) });
            try cg.copyTo(Mem.at(.r10, 0), operand);
            try cg.e.mov(.qword, .{ .reg = .rax }, .{ .mem = Mem.at(.rbp, cg.ret_ptr_slot.?) });
        },
    }
}

// ---------------------------------------------------------------- Win64 calls

/// How the Win64 convention passes a value, as upstream's
/// `classifyWindows`: in its position's GPR (`int`: a 1-, 2-, 4-, or
/// 8-byte value other than a float), in its position's XMM register
/// (`sse`: f16, f32, f64; as a result, also 16-byte integers and packed
/// containers, f128, and vectors of up to 16 bytes, in xmm0), or by
/// reference (`ref`: as an argument, a pointer to a copy the caller makes;
/// as a result, memory the caller passes a pointer to in the first
/// position and the callee returns in rax).
const WinClass = enum { none, int, sse, ref };

fn winClass(cg: *CodeGen, ty: Index, is_ret: bool) WinClass {
    const ip = cg.ip;
    if (!Type.hasRuntimeBits(ip, ty)) return .none;
    switch (Type.class(ip, ty)) {
        .float => return switch (Type.floatBits(ip, ty)) {
            16, 32, 64 => .sse,
            128 => if (is_ret) .sse else .ref,
            else => .ref,
        },
        .vector => {
            const v = ip.keyPayload(.vector_type, ty);
            if (v.len == 1) return cg.winClass(v.child, is_ret);
            const bytes = Type.abiSize(ip, v.child) * v.len;
            return if (is_ret and v.child != .bool_type and bytes <= 16) .sse else .ref;
        },
        else => {},
    }
    const size = Type.abiSize(ip, ty);
    if (cg.passInRegs(ty)) return .int;
    if (size == 16 and is_ret and (Type.isInt(ip, ty) or Type.isPacked(ip, ty))) return .sse;
    return .ref;
}

const win_arg_regs = [_]Reg{ .rcx, .rdx, .r8, .r9 };
const win_saved_xmms = [_]Encoder.Xmm{ .xmm6, .xmm7, .xmm8, .xmm9, .xmm10, .xmm11, .xmm12, .xmm13, .xmm14, .xmm15 };

/// Places the arguments of a call to a Win64 function: each in its
/// position's register (rcx, rdx, r8, r9, or xmm0-xmm3) or at
/// `rsp + 32 + 8 * (position - 4)`, past the callee's 32-byte shadow
/// space. By-reference arguments are copied to slots first (copies use
/// rax, rsi, rdi, rcx), then stack arguments, then XMM registers (rax),
/// then GPRs. A variadic callee gets a float in its position's GPR too.
fn winCallArgs(cg: *CodeGen, args: []const Val, ret_ty: Index, dst: ?Mem, var_args: bool) Error!void {
    const ip = cg.ip;
    const sret = dst != null and cg.winClass(ret_ty, true) == .ref;
    const pos = try cg.gpa.alloc(u32, args.len);
    defer cg.gpa.free(pos);
    const mems = try cg.gpa.alloc(Mem, args.len);
    defer cg.gpa.free(mems);
    var n: u32 = @intFromBool(sret);
    for (args, pos) |a, *p| {
        p.* = n;
        if (cg.winClass(a.ty, false) != .none) n += 1;
    }
    cg.out_args_size = @max(cg.out_args_size, 32 + 8 * (@max(n, 4) - 4));
    for (args, mems) |a, *m| if (cg.winClass(a.ty, false) == .ref) {
        const size = Type.abiSize(ip, a.ty);
        m.* = Mem.at(.rbp, try cg.allocSlot(size, @max(Type.abiAlignment(ip, a.ty), 16)));
        try cg.copyMem(m.*, try cg.valMem(a), size);
    };
    for (args, pos, mems) |a, p, m| if (p >= 4) {
        const at = Mem.at(.rsp, @intCast(32 + 8 * (p - 4)));
        switch (cg.winClass(a.ty, false)) {
            .none => {},
            .int, .sse => try cg.copyMem(at, try cg.valMem(a), Type.abiSize(ip, a.ty)),
            .ref => {
                try cg.e.lea(.qword, .rax, m);
                try cg.e.mov(.qword, .{ .mem = at }, .{ .reg = .rax });
            },
        }
    };
    for (args, pos) |a, p| if (p < 4 and cg.winClass(a.ty, false) == .sse) try cg.loadXmm(xmm_args[p], a);
    for (args, pos, mems) |a, p, m| if (p < 4) switch (cg.winClass(a.ty, false)) {
        .none => {},
        .int => try cg.loadVal(win_arg_regs[p], a),
        .sse => if (var_args) try cg.e.movFromXmm(.qword, .{ .reg = win_arg_regs[p] }, xmm_args[p]),
        .ref => try cg.e.lea(.qword, win_arg_regs[p], m),
    };
    if (sret) try cg.e.lea(.qword, .rcx, dst.?);
}

/// Stores the result of a Win64 call, of type `ret_ty`, to `dst`.
fn winCallResult(cg: *CodeGen, ret_ty: Index, dst: ?Mem) Error!void {
    const m = dst orelse return;
    switch (cg.winClass(ret_ty, true)) {
        .none, .ref => {},
        .int => try cg.storeReg(m, .rax, Type.abiSize(cg.ip, ret_ty)),
        .sse => try cg.storeXmm(m, .xmm0, Type.abiSize(cg.ip, ret_ty)),
    }
}

/// The callee side of the Win64 convention: saves the registers it
/// preserves that bs's code may use (rsi, rdi, xmm6-xmm15; the others
/// are callee-saved in SysV too), and gives each `arg` a home, spilling
/// register arguments to slots and copying by-reference ones.
fn setupWinParams(cg: *CodeGen) Error!void {
    const ip = cg.ip;
    // A variadic function's register arguments go to the home area its
    // caller reserved, after which all its arguments are in order in
    // memory, where `cVaStart` points.
    if (cg.fn_ty.is_var_args) for (win_arg_regs, 0..) |r, i| try cg.e.mov(.qword, .{ .mem = Mem.at(.rbp, @intCast(16 + 8 * i)) }, .{ .reg = r });
    const save = try cg.allocSlot(16 + 16 * win_saved_xmms.len, 16);
    try cg.e.mov(.qword, .{ .mem = Mem.at(.rbp, save) }, .{ .reg = .rsi });
    try cg.e.mov(.qword, .{ .mem = Mem.at(.rbp, save + 8) }, .{ .reg = .rdi });
    for (win_saved_xmms, 0..) |x, i| try cg.e.movups(.{ .mem = Mem.at(.rbp, save + 16 + 16 * @as(i32, @intCast(i))) }, .{ .reg = x });
    cg.win_save = save;
    var p: u32 = 0;
    if (cg.winClass(cg.fn_ty.return_type, true) == .ref) {
        const off = try cg.allocSlot(8, 8);
        try cg.e.mov(.qword, .{ .mem = Mem.at(.rbp, off) }, .{ .reg = .rcx });
        cg.ret_ptr_slot = off;
        p = 1;
    }
    // By-reference arguments: their pointers' slots, copied from once the
    // registers are spilled.
    var refs: std.ArrayList(struct { inst: Inst.Index, ptr: i32 }) = .empty;
    defer refs.deinit(cg.gpa);
    for (cg.ir.mainBody()) |inst| {
        if (cg.ir.instructions.items(.tag)[@backingInt(inst)] != .arg) break;
        const ty = cg.ir.instructions.items(.data)[@backingInt(inst)].arg.ty;
        const size = Type.abiSize(ip, ty);
        const class = cg.winClass(ty, false);
        if (class == .none) continue;
        defer p += 1;
        if (p >= 4) {
            const off: i32 = @intCast(16 + 32 + 8 * (p - 4));
            if (class == .ref) try refs.append(cg.gpa, .{ .inst = inst, .ptr = off }) else cg.homes[@backingInt(inst)] = .{ .slot = off };
            continue;
        }
        if (class == .ref) {
            const off = try cg.allocSlot(8, 8);
            try cg.e.mov(.qword, .{ .mem = Mem.at(.rbp, off) }, .{ .reg = win_arg_regs[p] });
            try refs.append(cg.gpa, .{ .inst = inst, .ptr = off });
            continue;
        }
        const m = Mem.at(.rbp, try cg.allocSlot(size, Type.abiAlignment(ip, ty)));
        cg.homes[@backingInt(inst)] = .{ .slot = m.disp };
        if (class == .int) try cg.storeReg(m, win_arg_regs[p], size) else try cg.storeXmm(m, xmm_args[p], size);
    }
    for (refs.items) |ref| {
        const ty = cg.ir.instructions.items(.data)[@backingInt(ref.inst)].arg.ty;
        const size = Type.abiSize(ip, ty);
        const m = Mem.at(.rbp, try cg.allocSlot(size, Type.abiAlignment(ip, ty)));
        try cg.e.mov(.qword, .{ .reg = .r11 }, .{ .mem = Mem.at(.rbp, ref.ptr) });
        try cg.copyMem(m, Mem.at(.r11, 0), size);
        cg.homes[@backingInt(ref.inst)] = .{ .slot = m.disp };
    }
    if (cg.fn_ty.is_var_args) cg.va = .{ .stack = 8 * p };
}

/// Returns `operand` from a Win64 function.
fn winRet(cg: *CodeGen, operand: Ref) Error!void {
    switch (cg.winClass(cg.fn_ty.return_type, true)) {
        .none => {},
        .int => try cg.load(.rax, operand),
        .sse => try cg.loadXmm(.xmm0, try cg.valOf(operand)),
        .ref => {
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
    const key: SymbolKey = .fromName(try cg.emit.requestCompilerRt(file, name));
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
    const key: SymbolKey = .fromName(try cg.emit.requestCompilerRt(file, name));
    _ = try cg.cCallArgs(args, ret_ty, dst);
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
        try cg.sseArith(tag, ft, .xmm0, lhs, rhs);
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

/// `d = lhs op rhs` on f32 or f64. `d` is xmm0 or the result's home, which
/// `rhs` is not in. Uses xmm1 and rax.
fn sseArith(cg: *CodeGen, tag: Inst.Tag, ft: Encoder.Float, d: Encoder.Xmm, lhs: Val, rhs: Val) Error!void {
    try cg.loadXmm(d, lhs);
    try cg.e.sse(switch (tag) {
        .add_float => .add,
        .sub_float => .sub,
        .mul_float => .mul,
        .div_float => .div,
        else => unreachable,
    }, ft, d, try cg.xmmOperand(rhs, .xmm1));
}

/// f32 or f64 `v` as the source of an SSE instruction: its register, its
/// memory, or `scratch` loaded with it. Uses rax.
fn xmmOperand(cg: *CodeGen, v: Val, scratch: Encoder.Xmm) Error!Encoder.XmmRm {
    switch (v.loc) {
        .xmm => |x| return .{ .reg = x },
        .mem => |m| return .{ .mem = m },
        else => {
            try cg.loadXmm(scratch, v);
            return .{ .reg = scratch };
        },
    }
}

/// An f32 or f64 operand in a register: its own, or `scratch` loaded with
/// it. Uses rax.
fn xmmReg(cg: *CodeGen, v: Val, scratch: Encoder.Xmm) Error!Encoder.Xmm {
    if (v.loc == .xmm) return v.loc.xmm;
    try cg.loadXmm(scratch, v);
    return scratch;
}

/// Instructions on floats.
fn genFloat(cg: *CodeGen, inst: Inst.Index, tag: Inst.Tag, data: Inst.Data) Error!void {
    const ip = cg.ip;
    switch (tag) {
        .add_float, .sub_float, .mul_float, .div_float => {
            const ty = cg.typeOf(data.bin_op.lhs);
            if (cg.sseType(ty)) |ft| {
                const d = cg.destXmm(inst);
                try cg.sseArith(tag, ft, d, try cg.valOf(data.bin_op.lhs), try cg.valOf(data.bin_op.rhs));
                return cg.setXmm(inst, ty, d);
            }
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
            const lhs = try cg.valOf(data.bin_op.lhs);
            const rhs = try cg.valOf(data.bin_op.rhs);
            if (cg.sseType(ty)) |ft| {
                // As upstream: rhs if lhs is NaN, else minss/maxss with
                // rhs first, which return their second operand, lhs, on
                // ties (+0 and -0) and when rhs is NaN.
                const l = try cg.xmmReg(lhs, .xmm0);
                try cg.loadXmm(.xmm1, rhs);
                const done = try cg.e.newLabel();
                try cg.e.ucomis(ft, l, .{ .reg = l });
                try cg.e.jcc(.p, .{ .label = done });
                try cg.e.sse(if (tag == .min_float) .min else .max, ft, .xmm1, .{ .reg = l });
                cg.e.bind(done);
                return cg.setXmm(inst, ty, .xmm1);
            }
            const dst = try cg.resultMem(inst, ty) orelse return;
            try cg.libmCall(if (tag == .min_float) "fmin" else "fmax", null, ty, &.{ lhs, rhs }, dst);
        },
        .neg_float, .abs_float => {
            const ty = cg.typeOf(data.un_op);
            if (cg.sseType(ty)) |ft| {
                // xor or and with the sign bit's mask.
                const d = cg.destXmm(inst);
                try cg.loadXmm(d, try cg.valOf(data.un_op));
                const sign: u64 = if (ft == .f64) 1 << 63 else 1 << 31;
                try cg.e.mov(.qword, .{ .reg = .rax }, .{ .imm = @bitCast(if (tag == .neg_float) sign else sign - 1) });
                try cg.e.movToXmm(if (ft == .f64) .qword else .dword, .xmm1, .{ .reg = .rax });
                try cg.e.sseLogic(if (tag == .neg_float) .xor else .@"and", ft, d, .{ .reg = .xmm1 });
                return cg.setXmm(inst, ty, d);
            }
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
            const operand = try cg.valOf(data.un_op);
            if (tag == .sqrt) if (cg.sseType(ty)) |ft| {
                const d = cg.destXmm(inst);
                try cg.e.sse(.sqrt, ft, d, try cg.xmmOperand(operand, .xmm1));
                return cg.setXmm(inst, ty, d);
            };
            const dst = try cg.resultMem(inst, ty) orelse return;
            if (tag == .sqrt and Type.floatBits(ip, ty) == 80) {
                try cg.e.fld(.m80, try cg.valMem(operand));
                try cg.e.fsqrt();
                return cg.e.fstp(.m80, dst);
            }
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
            const ty = cg.typeOf(data.bin_op.lhs);
            if (cg.sseType(ty)) |ft| {
                if (floatCc(tag) != null) return cg.genCond(inst);
                try cg.floatCompare(tag, ft, data.bin_op.lhs, data.bin_op.rhs);
                const eq = tag == .cmp_eq;
                const d = cg.destReg(inst);
                try cg.e.setcc(if (eq) .e else .ne, .{ .reg = d });
                try cg.e.setcc(if (eq) .np else .p, .{ .reg = .rcx });
                try cg.e.alu(if (eq) .@"and" else .@"or", .byte, .{ .reg = d }, .{ .reg = .rcx });
                try cg.e.movzx(.dword, d, .byte, .{ .reg = d });
                return cg.setResult(inst, .bool_type, d);
            }
            const dst = try cg.resultMem(inst, .bool_type) orelse return;
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
            const src_ty = cg.typeOf(data.ty_op.operand);
            const operand = try cg.valOf(data.ty_op.operand);
            const from = Type.floatBits(ip, src_ty);
            const to = Type.floatBits(ip, ty);
            if (cg.sseType(ty) != null and cg.sseType(src_ty) != null) {
                const d = cg.destXmm(inst);
                if (from == to) try cg.loadXmm(d, operand) else try cg.e.cvts2s(cg.sseType(ty).?, d, try cg.xmmOperand(operand, .xmm1));
                return cg.setXmm(inst, ty, d);
            }
            const dst = try cg.resultMem(inst, ty) orelse return;
            if (from == to) return cg.copyTo(dst, data.ty_op.operand);
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

/// The condition code that holds after `floatCompare` iff ordered float
/// comparison `tag` is true; null for `==` and `!=`, which need two flags.
fn floatCc(tag: Inst.Tag) ?Encoder.Cond {
    return switch (tag) {
        .cmp_lt, .cmp_gt => .a,
        .cmp_lte, .cmp_gte => .ae,
        else => null,
    };
}

/// ucomiss/ucomisd for comparison `tag` of f32 or f64 operands. Unordered
/// sets ZF, PF, and CF: `a`/`ae` are false for NaN, so `<` and `<=`
/// compare the swapped operands. Uses xmm0, xmm1, and rax.
fn floatCompare(cg: *CodeGen, tag: Inst.Tag, ft: Encoder.Float, lhs: Ref, rhs: Ref) Error!void {
    const swap = tag == .cmp_lt or tag == .cmp_lte;
    const a = try cg.valOf(if (swap) rhs else lhs);
    const b = try cg.valOf(if (swap) lhs else rhs);
    try cg.e.ucomis(ft, try cg.xmmReg(a, .xmm0), try cg.xmmOperand(b, .xmm1));
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
    const int_ty = cg.typeOf(data.ty_op.operand);
    const info = Type.intInfo(ip, int_ty);
    const operand = try cg.valOf(data.ty_op.operand);
    if (cg.sseType(ty)) |ft| if (info.bits <= 64) {
        const e = &cg.e;
        const d = cg.destXmm(inst);
        try cg.loadVal(.rax, operand);
        if (info.bits == 64 and info.signedness == .unsigned) {
            // Halve values with the top bit set, keeping the low bit for
            // rounding, and double the result.
            const big = try e.newLabel();
            const done = try e.newLabel();
            try e.@"test"(.qword, .{ .reg = .rax }, .{ .reg = .rax });
            try e.jcc(.s, .{ .label = big });
            try e.cvtsi2s(ft, d, .qword, .{ .reg = .rax });
            try e.jmp(.{ .label = done });
            e.bind(big);
            try e.mov(.qword, .{ .reg = .rcx }, .{ .reg = .rax });
            try e.shift(.shr, .qword, .{ .reg = .rcx }, 1);
            try e.alu(.@"and", .dword, .{ .reg = .rax }, .{ .imm = 1 });
            try e.alu(.@"or", .qword, .{ .reg = .rcx }, .{ .reg = .rax });
            try e.cvtsi2s(ft, d, .qword, .{ .reg = .rcx });
            try e.sse(.add, ft, d, .{ .reg = d });
            e.bind(done);
        } else {
            try e.cvtsi2s(ft, d, .qword, .{ .reg = .rax });
        }
        return cg.setXmm(inst, ty, d);
    };
    const dst = try cg.resultMem(inst, ty) orelse return;
    const abbrev = rtIntAbbrev(info.bits) orelse {
        // `__floateisf(a, bits)` and friends read the integer from memory.
        const name = try std.fmt.allocPrint(cg.emit.allocator(), "__float{s}ei{s}", .{ if (info.signedness == .unsigned) "un" else "", rtFloatAbbrev(Type.floatBits(ip, ty)) });
        const key: SymbolKey = .fromName(try cg.emit.requestCompilerRt("float_from_int.zig", name));
        try cg.e.lea(.qword, .rdi, try cg.valMem(operand));
        try cg.e.mov(.qword, .{ .reg = .rsi }, .{ .imm = info.bits });
        try cg.e.call(.{ .sym = key });
        return cg.cCallResult(ty, dst);
    };
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
    const abbrev = rtIntAbbrev(info.bits) orelse {
        // `__fixsfei(r, bits, a)` and friends write the integer, of its
        // ABI size, to memory.
        const name = try std.fmt.allocPrint(cg.emit.allocator(), "__fix{s}{s}ei", .{ if (info.signedness == .unsigned) "uns" else "", rtFloatAbbrev(Type.floatBits(ip, float_ty)) });
        const key: SymbolKey = .fromName(try cg.emit.requestCompilerRt("int_from_float.zig", name));
        _ = try cg.cCallArgs(&.{ .{ .ty = .usize_type, .loc = .{ .addr = dst } }, .{ .ty = .usize_type, .loc = .{ .imm = info.bits } }, operand }, .void_type, null);
        try cg.e.call(.{ .sym = key });
        return;
    };
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
    // An enum is its integer tag.
    const c = Type.class(cg.ip, ty);
    return (c == .int or c == .@"enum") and Type.abiSize(cg.ip, ty) > 8;
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

/// Sets ZF when wide integers `a` and `b` of the same type are equal: when
/// every limb XORs to zero. Uses rax and rcx.
fn wideEqFlags(cg: *CodeGen, a_ref: Ref, b_ref: Ref) Error!void {
    const a = (try cg.wideVal(a_ref)).loc.mem;
    const b = (try cg.wideVal(b_ref)).loc.mem;
    try cg.e.mov(.qword, .{ .reg = .rax }, .{ .mem = a });
    try cg.e.alu(.xor, .qword, .{ .reg = .rax }, .{ .mem = b });
    for (1..cg.limbCount(cg.typeOf(a_ref))) |i| {
        try cg.e.mov(.qword, .{ .reg = .rcx }, .{ .mem = limb(a, @intCast(i)) });
        try cg.e.alu(.xor, .qword, .{ .reg = .rcx }, .{ .mem = limb(b, @intCast(i)) });
        try cg.e.alu(.@"or", .qword, .{ .reg = .rax }, .{ .reg = .rcx });
    }
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
/// operands, and must be addressed from rbp. Uses rax, rcx, rdx, rsi,
/// rdi, and r8 through r11.
fn mulLimbs(cg: *CodeGen, dst: Mem, lhs: Mem, rhs: Mem, n: u32) Error!void {
    const e = &cg.e;
    try e.alu(.xor, .dword, .{ .reg = .rax }, .{ .reg = .rax });
    for (0..n) |i| try e.mov(.qword, .{ .mem = limb(dst, @intCast(i)) }, .{ .reg = .rax });
    // Unrolled, the schoolbook product is n^2/2 multiply steps of code;
    // past a few limbs, loop over the columns instead.
    if (n > 4) return cg.mulLimbsLoop(dst, lhs, rhs, n);
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

fn mulLimbsLoop(cg: *CodeGen, dst: Mem, lhs: Mem, rhs: Mem, n: u32) Error!void {
    const e = &cg.e;
    const indexed = struct {
        fn f(m: Mem, reg: Reg) Mem {
            var r = m;
            r.index = .{ .reg = reg, .scale = .@"8" };
            return r;
        }
    }.f;
    // rcx = i (lhs limb), rsi = j (rhs limb), r8 = carry, r9 = n - 1 - i
    // (the column that keeps only the low half); r10 and r11 address the
    // operands, which may be constants.
    try e.lea(.qword, .r10, lhs);
    try e.lea(.qword, .r11, rhs);
    const lhs_at = Mem.at(.r10, 0);
    const rhs_at = Mem.at(.r11, 0);
    const outer = try e.newLabel();
    const inner = try e.newLabel();
    const last = try e.newLabel();
    try e.alu(.xor, .dword, .{ .reg = .rcx }, .{ .reg = .rcx });
    e.bind(outer);
    try e.alu(.xor, .dword, .{ .reg = .r8 }, .{ .reg = .r8 });
    try e.alu(.xor, .dword, .{ .reg = .rsi }, .{ .reg = .rsi });
    try e.mov(.qword, .{ .reg = .r9 }, .{ .imm = n - 1 });
    try e.alu(.sub, .qword, .{ .reg = .r9 }, .{ .reg = .rcx });
    e.bind(inner);
    try e.alu(.cmp, .qword, .{ .reg = .rsi }, .{ .reg = .r9 });
    try e.jcc(.ae, .{ .label = last });
    try e.mov(.qword, .{ .reg = .rax }, .{ .mem = indexed(lhs_at, .rcx) });
    try e.unary(.mul, .qword, .{ .mem = indexed(rhs_at, .rsi) });
    try e.alu(.add, .qword, .{ .reg = .rax }, .{ .reg = .r8 });
    try e.alu(.adc, .qword, .{ .reg = .rdx }, .{ .imm = 0 });
    try e.lea(.qword, .rdi, .{ .base = .{ .reg = .rcx }, .index = .{ .reg = .rsi } });
    try e.alu(.add, .qword, .{ .mem = indexed(dst, .rdi) }, .{ .reg = .rax });
    try e.alu(.adc, .qword, .{ .reg = .rdx }, .{ .imm = 0 });
    try e.mov(.qword, .{ .reg = .r8 }, .{ .reg = .rdx });
    try e.alu(.add, .qword, .{ .reg = .rsi }, .{ .imm = 1 });
    try e.jmp(.{ .label = inner });
    e.bind(last);
    try e.mov(.qword, .{ .reg = .rax }, .{ .mem = indexed(lhs_at, .rcx) });
    try e.imul(.qword, .rax, .{ .mem = indexed(rhs_at, .rsi) }, null);
    try e.alu(.add, .qword, .{ .reg = .rax }, .{ .reg = .r8 });
    try e.alu(.add, .qword, .{ .mem = limb(dst, n - 1) }, .{ .reg = .rax });
    try e.alu(.add, .qword, .{ .reg = .rcx }, .{ .imm = 1 });
    try e.alu(.cmp, .qword, .{ .reg = .rcx }, .{ .imm = n });
    try e.jcc(.b, .{ .label = outer });
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
            if (tag == .cmp_eq or tag == .cmp_neq) {
                try cg.wideEqFlags(data.bin_op.lhs, data.bin_op.rhs);
                return e.setcc(if (tag == .cmp_eq) .e else .ne, .{ .mem = dst });
            }
            var a = (try cg.wideVal(data.bin_op.lhs)).loc.mem;
            var b = (try cg.wideVal(data.bin_op.rhs)).loc.mem;
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
