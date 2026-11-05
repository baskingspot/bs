//! The shared SSA form of one function, which every architecture's backend
//! lowers (docs/slop/architecture.md, "Optimizing backend").
//!
//! A function is a list of basic blocks in layout order; a block is a list
//! of values followed by a terminator. Step 1 of the design builds the
//! blocks from the structured IR and keeps every IR instruction as one
//! `fallback` value, which the architecture lowers with its
//! per-instruction code; a block's result is the IR `block` value's
//! memory, written by each `br`. Later steps add real ops, type classes,
//! operands, and phis.
//!
//! An `Ssa` is reused for every function a worker compiles: `build` clears
//! it and keeps its capacity, so building allocates only while it grows.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Ir = @import("../Ir.zig");
const Inst = Ir.Inst;
const InternPool = @import("../InternPool.zig");
const Type = @import("../Type.zig");

const Ssa = @This();

values: std.MultiArrayList(Value) = .empty,
blocks: std.ArrayList(Block) = .empty,
/// Blocks in the structured IR's order, which numbers positions for
/// liveness, allocation, and slot sharing.
layout: std.ArrayList(Block.Index) = .empty,
/// Blocks in the order their code is emitted (`place`, passes 3 and 4):
/// `layout` without the bypassed blocks and with the cold blocks moved to
/// the end, `order[cold_start..]`.
order: std.ArrayList(Block.Index) = .empty,
cold_start: u32 = 0,
/// Per block: whether it is cold, and the block a branch to it goes to:
/// itself, or where it jumps if it is bypassed (`place`).
cold: std.ArrayList(bool) = .empty,
fwd: std.ArrayList(Block.Index) = .empty,
/// Per block, from `place`: no branch reaches it after jump threading
/// (`thread`), so it is not emitted.
unreached: std.ArrayList(bool) = .empty,
/// Per block, from `place` with `cover` (`-ffuzz`): whether it is a
/// coverage point, whose code starts by setting its counter.
covered: std.ArrayList(bool) = .empty,
/// Switch successors: per switch, its case blocks in IR order.
extra: std.ArrayList(Block.Index) = .empty,
/// For each IR instruction that a `br` or `repeat` targets (`block`,
/// `loop`), the block those jump to; indexed by IR instruction.
targets: std.ArrayList(Block.Index) = .empty,
/// Loops, outer ones before the loops they contain, and per block the
/// innermost loop containing it (an index into `loops`, or `no_loop`).
loops: std.ArrayList(Loop) = .empty,
block_loop: std.ArrayList(u32) = .empty,
/// No value gets a register and no variable is promoted: aarch64 sets it
/// for functions that use the preserve_none convention.
no_regs: bool = false,

/// Liveness and register allocation, per IR instruction (values are IR
/// instructions until the SSA gets its own ops). Positions number the
/// values and terminators in layout order: value `i` is at `2 * i + 2`,
/// and the terminator of a block whose values end before value `i` at
/// `2 * i + 1`.
live: std.MultiArrayList(Live) = .empty,
/// Frame-slot sharing, filled as the architecture emits values in layout
/// order (see `takeSlot`).
slots: Slots = .{},
/// Clobber points in `liveness`: per position, how many lie at or before
/// it in blocks that continue, and in blocks that do not (`ret`,
/// `unreachable`, a noreturn call).
clobbers: std.ArrayList([2]u32) = .empty,
/// Overflow operations whose results only their `struct_field_val`s read
/// (`Fate.pair`), and those two values (or `no_tie`), from `plan`.
pairs: std.AutoHashMapUnmanaged(u32, [2]u32) = .empty,
/// Scratch for `plan`: the allocs it considers promoting, and their loads.
candidates: std.ArrayList(u32) = .empty,
var_loads: std.ArrayList(u32) = .empty,
/// The innermost loop around each of `var_loads`.
var_load_loops: std.ArrayList(u32) = .empty,
/// Scratch for `deadFills`.
fills: Fills = .{},

pub const no_loop = std.math.maxInt(u32);

/// A loop's blocks are contiguous in the layout: positions `start` (its
/// header's first value) through `end` (its last block's terminator).
pub const Loop = struct { start: u32, end: u32, parent: u32 };

pub const Live = struct {
    /// Uses as an operand, by values and terminators.
    uses: u32,
    /// The interval the value occupies a register for: from its
    /// definition through its last use, and through the end of every loop
    /// that uses it without defining it.
    def: u32,
    end: u32,
    /// Before `allocate`: `want` for a value the architecture would keep in
    /// a register, else `no_reg`. After: the register's index in the
    /// architecture's list, or `no_reg`.
    reg: u8,
    /// Set by the architecture with `want`: the operand (an IR instruction
    /// index, or `no_tie`) whose register the value may take when the
    /// operand's last use is the value's definition, because the lowering
    /// reads the other operands before writing the result over it.
    tie: u32,
    /// A clobber point (`liveness`) lies inside the interval, where the
    /// value is still needed afterwards.
    crosses: bool,
    /// From `liveness`: its uses weighted by loop depth, 8 per level (up
    /// to 6), which `allocate` keeps in registers first.
    weight: u32,
    /// After `allocate`, for a value marked `want_pair` that got registers:
    /// the register of its high eightbyte (`reg` holds the low one); else
    /// `no_reg`.
    reg2: u8,
    /// Set by the architecture before `allocate`: the registers (low and
    /// high eightbyte) the value is best computed in, such as an
    /// argument's, taken when free; else `no_reg`. `allocate` sets
    /// `hint_saved` on its own.
    hint: [2]u8,
    /// How the value is computed, from `plan`.
    fate: Fate,
    /// From `plan`, for a load of a promoted variable: the variable (an IR
    /// instruction index, or `no_tie`), whose register the load may share
    /// for its whole interval: the variable's interval contains it, and no
    /// store to the variable lies in it. The variable then crosses a
    /// clobber point if the load does.
    share: u32,
    /// From `plan`, for a load of a constant that is forwarded: the value
    /// it reads (an IR instruction index), whose home the load shares;
    /// else `no_tie`.
    fwd: u32,
};

/// What `plan` decided for a value, beside its register.
pub const Fate = enum(u8) {
    /// Lowered into its register or its memory.
    normal,
    /// Nothing reads the value and computing it has no effect: it is not
    /// emitted.
    dead,
    /// A condition its block's branch computes, or an overflow bit the
    /// branch reads from the flags its operation set.
    fused,
    /// An overflow result that is not stored: its operation writes its
    /// fields' values (see `pairs`).
    pair,
};

pub const no_tie = std.math.maxInt(u32);

pub const no_reg: u8 = 0xff;
/// A `Live.hint` for a value whose tied user crosses a clobber point: it
/// prefers a register in `survives`.
pub const hint_saved: u8 = 0xfe;
/// A second `Live.hint` for a single-register value that no other value
/// may evict: spilling it would cost far more than a register's value
/// (a by-reference argument, copied in whole).
pub const hint_pinned: u8 = 0xfc;
pub const want_reg: u8 = 0xfe;
/// Like `want_reg`, for a value that needs two registers: a 9- to 16-byte
/// value as its two eightbytes (`reg` the low, `reg2` the high one).
pub const want_pair: u8 = 0xfd;
/// Like `want_reg`, for a value in a floating-point register.
pub const want_float: u8 = 0xfc;
/// Like `want_float`, for a vector, which only a call-clobbered register
/// can hold (one of `allocate`'s floats outside `survives`): it gets none
/// when it crosses a clobber point, unless it is split.
pub const want_vec: u8 = 0xfb;
/// For an address its users may read as an offset from another value
/// (`allocate`'s `fold`): no register if that value has one or is itself
/// folded, else like `want_reg`. Not one of the `want` markers.
pub const want_fold: u8 = 0xfa;
/// What `allocate` leaves for a `want_fold` value that took no register.
pub const folded: u8 = 0xf9;

/// Whether `r` is one of the `want` markers.
pub fn wants(r: u8) bool {
    return r >= want_vec and r != no_reg;
}

pub const Value = struct {
    op: Op,
    /// The IR instruction this value comes from.
    inst: Inst.Index,
};

pub const Op = enum(u8) {
    /// Lowered by the architecture's per-instruction code for `inst`.
    fallback,
};

pub const Block = struct {
    /// The block's values are `values[start..][0..len]`.
    start: u32,
    len: u32,
    term: Term,

    pub const Index = enum(u32) {
        none = std.math.maxInt(u32),
        _,
    };
};

pub const Term = struct {
    tag: Tag,
    /// The IR instruction the terminator lowers, for its operands; for
    /// `fallthrough` and `noreturn`, the instruction that ended the block.
    inst: Inst.Index,
    /// `jump`, `fallthrough`: the target. `branch`: the block taken when
    /// the condition is true (which follows in the layout before jump
    /// threading) and the one taken when it is false. `switch_br`: the
    /// start in `extra` of the case blocks, and the else block (which
    /// follows in the layout).
    succ: [2]u32 = .{ 0, 0 },

    pub const Tag = enum(u8) {
        /// `br` (which also writes the target block's result) or `repeat`.
        /// After jump threading (`thread`), the target may be another
        /// block than the `br`'s or `repeat`'s.
        jump,
        /// Continues into the next block in the layout without code: the
        /// entry of a loop, or the end of an empty body.
        fallthrough,
        /// On a condition (`branchCond`): a `cond_br`'s, or after jump
        /// threading a `br`'s operand, which the `br` also writes to its
        /// block's result.
        branch,
        switch_br,
        ret,
        /// `unreach` or `trap`.
        unreach,
        /// The block's last value does not return (a call of a noreturn
        /// function, or a block or loop that no branch leaves).
        noreturn,
    };
};

pub fn deinit(f: *Ssa, gpa: Allocator) void {
    f.values.deinit(gpa);
    f.blocks.deinit(gpa);
    f.layout.deinit(gpa);
    f.order.deinit(gpa);
    f.cold.deinit(gpa);
    f.fwd.deinit(gpa);
    f.unreached.deinit(gpa);
    f.covered.deinit(gpa);
    f.extra.deinit(gpa);
    f.targets.deinit(gpa);
    f.loops.deinit(gpa);
    f.block_loop.deinit(gpa);
    f.live.deinit(gpa);
    for (&f.slots.free) |*l| l.deinit(gpa);
    f.slots.active.deinit(gpa);
    f.clobbers.deinit(gpa);
    f.pairs.deinit(gpa);
    f.candidates.deinit(gpa);
    f.var_loads.deinit(gpa);
    f.var_load_loops.deinit(gpa);
    f.fills.deinit(gpa);
    f.* = undefined;
}

pub fn blockInsts(f: *const Ssa, block: Block.Index) []const Inst.Index {
    const b = f.blocks.items[@backingInt(block)];
    return f.values.items(.inst)[b.start..][0..b.len];
}

pub fn switchCases(f: *const Ssa, term: Term, len: usize) []const Block.Index {
    return f.extra.items[term.succ[0]..][0..len];
}

/// The condition of a `branch` terminator: its `cond_br`'s, a threaded
/// `br`'s operand, or a threaded branch's value itself (`thread`).
pub fn branchCond(ir: *const Ir, term: Term) Inst.Ref {
    const data = ir.instructions.items(.data)[@backingInt(term.inst)];
    return switch (ir.instructions.items(.tag)[@backingInt(term.inst)]) {
        .br => data.br.operand,
        .cond_br => data.pl_op.operand,
        else => term.inst.toRef(),
    };
}

/// Builds `f` from `ir`, replacing what it held.
pub fn build(f: *Ssa, gpa: Allocator, ir: *const Ir) Allocator.Error!void {
    f.values.clearRetainingCapacity();
    f.blocks.clearRetainingCapacity();
    f.layout.clearRetainingCapacity();
    f.extra.clearRetainingCapacity();
    f.targets.clearRetainingCapacity();
    f.loops.clearRetainingCapacity();
    f.block_loop.clearRetainingCapacity();
    try f.targets.appendNTimes(gpa, .none, ir.instructions.len);
    // At most one value per IR instruction.
    try f.values.ensureTotalCapacity(gpa, ir.instructions.len);
    var b: Builder = .{ .f = f, .gpa = gpa, .ir = ir };
    try b.body(ir.mainBody());
    f.no_regs = false;
}

/// Per position (as `clobbers`), how many inline assembly statements
/// that are not dead come at or before it, for `allocate`'s
/// `Restriction.counts`; null without any.
pub fn asmCounts(f: *const Ssa, gpa: Allocator, ir: *const Ir, out: *std.ArrayList(u32)) Allocator.Error!?[]const u32 {
    const tags = ir.instructions.items(.tag);
    const fate = f.live.items(.fate);
    try out.resize(gpa, 2 * f.values.len + 3);
    const cl = out.items;
    var count: u32 = 0;
    cl[0] = 0;
    cl[1] = 0;
    for (f.layout.items) |block| {
        const b = f.blocks.items[@backingInt(block)];
        for (b.start..b.start + b.len) |i| {
            const inst = f.values.items(.inst)[i];
            if (tags[@backingInt(inst)] == .assembly and fate[@backingInt(inst)] != .dead) count += 1;
            cl[2 * i + 2] = count;
            cl[2 * i + 3] = count;
        }
        cl[2 * (b.start + b.len) + 1] = count;
        cl[2 * (b.start + b.len) + 2] = count;
    }
    return if (count == 0) null else cl;
}

/// Passes 3 and 4: bypasses blocks that only jump (`fwd`) and orders the
/// rest for emission (`order`). A block without values whose terminator
/// only jumps (a `repeat`, a `br` without a result, a fallthrough) is
/// bypassed: branches to it go where it goes. A block that ends with a
/// call of a noreturn function (a failing check's panic, `@panic`) is
/// cold and moves to the end, so the hot path falls through its checks
/// and their branches jump out of line. The entry block stays first.
///
/// Positions stay in `layout` order. A cold block ends the function's
/// execution and defines nothing another block reads, so running it at
/// the end, with the registers `allocate` gave it in place, is the same
/// as running it in place: no value defined after it in `layout` order
/// exists on its path. Slot sharing (`takeSlot`) assumes emission in
/// position order, so the architecture gives the values of cold blocks
/// slots of their own.
///
/// With `cover` (`-ffuzz`), it also picks the coverage points (`covered`;
/// docs/slop/architecture.md, "Fuzzing"): the entry, and each arm of a `branch`
/// that Sema marked (`Ir.CondBr.cover`, the branches the user wrote) and
/// that is not cold. Switch cases get none, as upstream's. A covered block
/// is not bypassed.
pub fn place(f: *Ssa, gpa: Allocator, ir: *const Ir, ip: *const InternPool, cover: bool) Allocator.Error!void {
    const n = f.blocks.items.len;
    f.order.clearRetainingCapacity();
    try f.order.ensureTotalCapacity(gpa, f.layout.items.len);
    try f.unreached.resize(gpa, n);
    @memset(f.unreached.items, false);
    if (!cover) try f.thread(gpa, ir, ip);
    try f.cold.resize(gpa, n);
    @memset(f.cold.items, false);
    try f.fwd.resize(gpa, n);
    for (f.fwd.items, 0..) |*t, i| t.* = @fromBackingInt(@intCast(i));
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    try f.covered.resize(gpa, n);
    @memset(f.covered.items, false);
    if (cover) {
        const covered = f.covered.items;
        covered[@backingInt(f.layout.items[0])] = true;
        for (f.layout.items) |block| {
            const term = f.blocks.items[@backingInt(block)].term;
            switch (term.tag) {
                .branch => {
                    const arms = ir.extraData(Ir.CondBr, datas[@backingInt(term.inst)].pl_op.payload).data.cover;
                    for (term.succ, [2]bool{ arms.then, arms.@"else" }) |succ, on| {
                        if (on and !f.endsCold(ir, succ)) covered[succ] = true;
                    }
                },
                else => {},
            }
        }
    }
    // Each bypassable block points at its successor; then chains are
    // followed, and a block on a cycle of them (an empty endless loop)
    // keeps its code.
    for (f.layout.items[1..]) |block| {
        const b = f.blocks.items[@backingInt(block)];
        if (b.len != 0 or f.covered.items[@backingInt(block)]) continue;
        const only_jumps = switch (b.term.tag) {
            .fallthrough => true,
            .jump => tags[@backingInt(b.term.inst)] == .repeat or datas[@backingInt(b.term.inst)].br.operand == Inst.Ref.void_value,
            else => false,
        };
        if (only_jumps) f.fwd.items[@backingInt(block)] = @fromBackingInt(b.term.succ[0]);
    }
    for (f.layout.items) |block| {
        var t = block;
        var steps: usize = 0;
        while (f.fwd.items[@backingInt(t)] != t and steps <= n) : (steps += 1) t = f.fwd.items[@backingInt(t)];
        f.fwd.items[@backingInt(block)] = if (steps > n) block else t;
    }
    for (f.layout.items, 0..) |block, i| {
        if (!f.emits(i, block)) continue;
        const cold = i != 0 and f.endsCold(ir, @backingInt(block));
        f.cold.items[@backingInt(block)] = cold;
        if (!cold) f.order.appendAssumeCapacity(block);
    }
    f.cold_start = @intCast(f.order.items.len);
    for (f.layout.items) |block| {
        if (f.cold.items[@backingInt(block)]) f.order.appendAssumeCapacity(block);
    }
}

/// After `plan`: a block without values whose `br` writes a result
/// nothing reads (after jump threading, a constant for a bool the code
/// only branched on) only jumps, so branches to it go where it goes, as
/// for the blocks `place` bypasses, and it is not emitted.
pub fn bypassUnread(f: *Ssa, ir: *const Ir) void {
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    const uses = f.live.items(.uses);
    var any = false;
    for (f.order.items[1..]) |block| {
        const b = f.blocks.items[@backingInt(block)];
        if (b.len != 0 or b.term.tag != .jump or tags[@backingInt(b.term.inst)] != .br or f.covered.items[@backingInt(block)]) continue;
        if (uses[@backingInt(datas[@backingInt(b.term.inst)].br.block_inst)] != 0) continue;
        f.fwd.items[@backingInt(block)] = @fromBackingInt(b.term.succ[0]);
        any = true;
    }
    if (!any) return;
    const n = f.blocks.items.len;
    for (f.layout.items) |block| {
        var t = block;
        var steps: usize = 0;
        while (f.fwd.items[@backingInt(t)] != t and steps <= n) : (steps += 1) t = f.fwd.items[@backingInt(t)];
        f.fwd.items[@backingInt(block)] = if (steps > n) block else t;
    }
    var kept: u32 = 0;
    var cold_start = f.cold_start;
    for (f.order.items, 0..) |block, i| {
        if (i != 0 and f.fwd.items[@backingInt(block)] != block) {
            if (i < f.cold_start) cold_start -= 1;
            continue;
        }
        f.order.items[kept] = block;
        kept += 1;
    }
    f.order.shrinkRetainingCapacity(kept);
    f.cold_start = cold_start;
}

/// Jump threading (part of pass 3): a branch whose outcome a predecessor
/// already knows goes straight to its target from there.
/// - A block whose result is a bool that the code after it only branches
///   on (`a and b`, `a or b`): each `br` to it with a constant goes to the
///   side the constant selects, and any other `br` becomes a branch on its
///   operand, so the bool is never tested. The `br`s still write the
///   result, which is then dead unless something else reads it, and the
///   block after the body, which nothing reaches any more, is not emitted
///   (`unreached`). That block may hold values without code (the next
///   condition's block in `a and b and c`), and may only pass the result
///   on to an enclosing bool block (`threadExit`).
/// - A loop whose header only loads a local and switches on it (a labeled
///   switch's dispatch, `continue :sw .x`): a `repeat` right after a store
///   of a constant to the local goes to the case holding it, when nothing
///   else reads the load. The store stays.
/// Values are IR instructions with one register each, so a jump may skip
/// only blocks whose values nothing past them reads; liveness then
/// follows the new edges, which stay within the loops of the old ones.
fn thread(f: *Ssa, gpa: Allocator, ir: *const Ir, ip: *const InternPool) Allocator.Error!void {
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    const insts = f.values.items(.inst);
    // Loop headers checked for the switch dispatch, and whether they have it.
    var headers: std.AutoHashMapUnmanaged(u32, bool) = .empty;
    defer headers.deinit(gpa);
    // `countReads`, when a chain first needs it.
    var counts: ?[]u32 = null;
    defer if (counts) |c| gpa.free(c);
    for (f.layout.items) |block| {
        const b = &f.blocks.items[@backingInt(block)];
        if (b.term.tag != .jump) continue;
        const ti = @backingInt(b.term.inst);
        switch (tags[ti]) {
            .br => {
                // An exit threaded through for an earlier `br`.
                if (f.unreached.items[@backingInt(block)]) continue;
                const to = (try f.threadExit(gpa, ir, b.term.inst, &counts)) orelse continue;
                // A constant goes to the side it selects.
                if (to.value.toInterned() == .bool_true) {
                    b.term.succ[0] = to.term.succ[0];
                } else if (to.value.toInterned() == .bool_false) {
                    b.term.succ[0] = to.term.succ[1];
                } else {
                    b.term = to.term;
                }
            },
            .repeat => {
                const h = f.targets.items[@backingInt(datas[ti].repeat.loop_inst)];
                const hb = f.blocks.items[@backingInt(h)];
                if (hb.len != 1 or hb.term.tag != .switch_br) continue;
                const l = insts[hb.start];
                if (tags[@backingInt(l)] != .load or datas[@backingInt(hb.term.inst)].pl_op.operand != l.toRef()) continue;
                const ptr = datas[@backingInt(l)].ty_op.operand;
                // The last value before the `repeat` stores a constant to
                // the local.
                const k: Inst.Index = for (0..b.len) |j| {
                    const v = insts[b.start + b.len - 1 - j];
                    if (tags[@backingInt(v)] != .dbg_stmt) break v;
                } else continue;
                if (tags[@backingInt(k)] != .store or datas[@backingInt(k)].bin_op.lhs != ptr) continue;
                const val = datas[@backingInt(k)].bin_op.rhs.toInterned() orelse continue;
                if (ip.keyTag(val) == .undef) continue;
                const gop = try headers.getOrPut(gpa, @backingInt(h));
                if (!gop.found_existing) gop.value_ptr.* = f.dispatches(ir, ip, @backingInt(h));
                if (!gop.value_ptr.*) continue;
                b.term.succ[0] = f.switchTarget(ir, ip, hb.term, val);
            },
            else => {},
        }
    }
    // Every `br` to a threaded block's exit was threaded: none is left.
    for (f.layout.items) |block| {
        if (f.unreached.items[@backingInt(block)]) f.blocks.items[@backingInt(block)].term.tag = .unreach;
    }
}

/// Where a threaded `br` (`thread`) goes: the branch that tests its
/// block's result, with the value it tests there and the condition
/// (`branchCond`) to branch with: the `br`, whose operand the value is,
/// or the value itself. The way there may pass exits that only pass a
/// result on to an enclosing bool block (an inlined call's
/// `return a < b`), may negate it, and may test a value prove substituted
/// for the result of a block left by one `br`. Each exit passed has no
/// code (`noCode`) but such a negation, and the result its skipped `br`
/// writes is read by nothing but the next exit; so is the `br`'s own
/// block's, when the value replaces the `br`. Marks an exit `unreached`
/// when every `br` to its block is threaded: the rest of the way tests the
/// block's result, or the block has one `br`. Null when there is no such
/// branch.
fn threadExit(f: *Ssa, gpa: Allocator, ir: *const Ir, br_inst: Inst.Index, counts: *?[]u32) Allocator.Error!?struct { term: Term, value: Inst.Ref } {
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    const insts = f.values.items(.inst);
    const br = datas[@backingInt(br_inst)].br;
    // The blocks passed, and whether the way on from each needs the value
    // the `br` writes rather than only its block's result.
    var chain: [8]struct { t: Inst.Index, by_value: bool } = undefined;
    var n: usize = 0;
    var t = br.block_inst;
    // `t`'s result, when known: `value`, negated if `neg`.
    var value: ?Inst.Ref = if (br.operand == Inst.Ref.void_value) null else br.operand;
    var neg = false;
    const exit: Term = while (n < chain.len) : (n += 1) {
        if (tags[@backingInt(t)] != .block or datas[@backingInt(t)].ty_pl.ty != .bool_type) return null;
        const xb = f.blocks.items[@backingInt(f.targets.items[@backingInt(t)])];
        chain[n] = .{ .t = t, .by_value = false };
        var not: ?Inst.Index = null;
        for (insts[xb.start..][0..xb.len]) |v| {
            if (noCode(tags[@backingInt(v)])) continue;
            if (not != null or tags[@backingInt(v)] != .not) return null;
            not = v;
        }
        if (xb.term.tag != .branch and (xb.term.tag != .jump or tags[@backingInt(xb.term.inst)] != .br)) return null;
        // What the exit's terminator reads.
        var r = branchCond(ir, xb.term);
        if (not) |x| {
            if (r != x.toRef() or try f.countsOf(gpa, ir, counts, .reads, x) != 1) return null;
            r = datas[@backingInt(x)].ty_op.operand;
        }
        if (r == t.toRef()) {
            // The result.
        } else if (value != null and r == value.?) {
            neg = false;
            chain[n].by_value = true;
        } else if (r == Inst.Ref.void_value) {
            value = null;
        } else {
            value = r;
            neg = false;
            chain[n].by_value = true;
        }
        if (not != null) neg = !neg;
        if (xb.term.tag == .branch) break xb.term;
        const next = datas[@backingInt(xb.term.inst)].br.block_inst;
        if (!try f.readOnlyByExit(gpa, ir, next, counts)) return null;
        t = next;
    } else return null;
    n += 1;
    const tested = value orelse return null;
    const succ: [2]u32 = if (neg) .{ exit.succ[1], exit.succ[0] } else exit.succ;
    var cond = br_inst;
    if (tested != br.operand) {
        // Available at the `br` unless an exit passed defines it.
        cond = tested.toIndex() orelse return .{ .term = .{ .tag = .branch, .inst = br_inst, .succ = succ }, .value = tested };
        for (chain[0..n]) |e| {
            const xb = f.blocks.items[@backingInt(f.targets.items[@backingInt(e.t)])];
            if (std.mem.findScalar(Inst.Index, insts[xb.start..][0..xb.len], cond) != null) return null;
        }
        if (br.operand != Inst.Ref.void_value and !try f.readOnlyByExit(gpa, ir, br.block_inst, counts)) return null;
    }
    var by_result = true;
    var i = n;
    while (i > 0) {
        i -= 1;
        by_result = by_result and !chain[i].by_value;
        if (by_result or try f.countsOf(gpa, ir, counts, .brs, chain[i].t) == 1)
            f.unreached.items[@backingInt(f.targets.items[@backingInt(chain[i].t)])] = true;
    }
    return .{ .term = .{ .tag = .branch, .inst = cond, .succ = succ }, .value = tested };
}

/// Whether nothing but the terminator of block `t`'s exit reads its
/// result, or a negation of it the terminator reads.
fn readOnlyByExit(f: *Ssa, gpa: Allocator, ir: *const Ir, t: Inst.Index, counts: *?[]u32) Allocator.Error!bool {
    const term = f.blocks.items[@backingInt(f.targets.items[@backingInt(t)])].term;
    const by_exit = switch (term.tag) {
        .branch => cond: {
            const c = branchCond(ir, term);
            const ci = c.toIndex() orelse break :cond false;
            break :cond c == t.toRef() or (ir.instructions.items(.tag)[@backingInt(ci)] == .not and ir.instructions.items(.data)[@backingInt(ci)].ty_op.operand == t.toRef());
        },
        .jump => jump: {
            if (ir.instructions.items(.tag)[@backingInt(term.inst)] != .br) break :jump false;
            const o = ir.instructions.items(.data)[@backingInt(term.inst)].br.operand;
            const oi = o.toIndex() orelse break :jump false;
            break :jump o == t.toRef() or (ir.instructions.items(.tag)[@backingInt(oi)] == .not and ir.instructions.items(.data)[@backingInt(oi)].ty_op.operand == t.toRef());
        },
        else => false,
    };
    return try f.countsOf(gpa, ir, counts, .reads, t) == @intFromBool(by_exit);
}

/// How many values and terminators read IR instruction `inst`, or how
/// many `br`s go to it; counted for all of them at the first call.
fn countsOf(f: *const Ssa, gpa: Allocator, ir: *const Ir, counts: *?[]u32, what: enum { reads, brs }, inst: Inst.Index) Allocator.Error!u32 {
    const n = ir.instructions.len;
    if (counts.* == null) {
        const tags = ir.instructions.items(.tag);
        const datas = ir.instructions.items(.data);
        const all = try gpa.alloc(u32, 2 * n);
        @memset(all, 0);
        const Count = struct {
            reads: []u32,
            const Self = @This();
            pub fn use(c: Self, ref: Inst.Ref) void {
                if (ref.toIndex()) |i| c.reads[@backingInt(i)] += 1;
            }
        };
        const c: Count = .{ .reads = all[0..n] };
        for (f.values.items(.inst)) |v| forEachOperand(ir, v, c);
        for (f.layout.items) |block| {
            const term = f.blocks.items[@backingInt(block)].term;
            switch (term.tag) {
                .jump, .branch => if (tags[@backingInt(term.inst)] == .br) {
                    const br = datas[@backingInt(term.inst)].br;
                    c.use(br.operand);
                    all[n + @backingInt(br.block_inst)] += 1;
                } else if (term.tag == .branch) c.use(branchCond(ir, term)),
                .switch_br => c.use(datas[@backingInt(term.inst)].pl_op.operand),
                .ret => c.use(datas[@backingInt(term.inst)].un_op),
                .fallthrough, .noreturn, .unreach => {},
            }
        }
        counts.* = all;
    }
    return counts.*.?[@as(usize, @backingInt(what)) * n + @backingInt(inst)];
}

/// Whether a value with tag `tag` emits no code: a block's result, which
/// gets its home from the architecture's `emitBlocks` also in a block that
/// is not emitted, or debug state, which it keeps in place there.
pub fn noCode(tag: Inst.Tag) bool {
    return switch (tag) {
        .block, .dbg_stmt, .dbg_inline_end => true,
        else => false,
    };
}

/// Whether loop header `h` (one load and a switch on it, `thread`) loads
/// a local that is not volatile, and nothing but the switch reads the load.
fn dispatches(f: *const Ssa, ir: *const Ir, ip: *const InternPool, h: u32) bool {
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    const hb = f.blocks.items[h];
    const l = f.values.items(.inst)[hb.start];
    const ptr = datas[@backingInt(l)].ty_op.operand.toIndex() orelse return false;
    if (tags[@backingInt(ptr)] != .alloc or Type.ptrInfo(ip, datas[@backingInt(ptr)].ty).flags.is_volatile) return false;
    const Find = struct {
        x: Inst.Ref,
        found: bool = false,
        const Self = @This();
        pub fn use(c: *Self, ref: Inst.Ref) void {
            if (ref == c.x) c.found = true;
        }
    };
    var find: Find = .{ .x = l.toRef() };
    // The load dominates only what follows it in the layout.
    for (f.values.items(.inst)[hb.start + 1 ..]) |v| forEachOperand(ir, v, &find);
    for (f.layout.items) |block| {
        const b = f.blocks.items[@backingInt(block)];
        if (b.start < hb.start or @backingInt(block) == h) continue;
        switch (b.term.tag) {
            .jump => if (tags[@backingInt(b.term.inst)] == .br) find.use(datas[@backingInt(b.term.inst)].br.operand),
            .branch => find.use(branchCond(ir, b.term)),
            .switch_br => find.use(datas[@backingInt(b.term.inst)].pl_op.operand),
            .ret => find.use(datas[@backingInt(b.term.inst)].un_op),
            .fallthrough, .noreturn, .unreach => {},
        }
    }
    return !find.found;
}

/// The block switch `term` goes to for constant `val`.
fn switchTarget(f: *const Ssa, ir: *const Ir, ip: *const InternPool, term: Term, val: InternPool.Index) u32 {
    const payload = ir.instructions.items(.data)[@backingInt(term.inst)].pl_op.payload;
    const x = ir.extraData(Ir.SwitchBr, payload);
    var it = ir.switchCases(payload);
    for (f.switchCases(term, x.data.cases_len)) |case_block| {
        const c = it.next().?;
        for (c.items) |item| {
            if (item.toInterned() == val) return @backingInt(case_block);
        }
        // Ranges hold integers of at most 64 bits (Sema).
        var k: usize = 0;
        while (k < c.ranges.len) : (k += 2) {
            const v = ip.intValue(i128, val).?;
            if (v >= ip.intValue(i128, c.ranges[k].toInterned().?).? and v <= ip.intValue(i128, c.ranges[k + 1].toInterned().?).?) return @backingInt(case_block);
        }
    }
    return term.succ[1];
}

/// Whether the `i`th block of the layout, `block`, has code: it is the
/// entry, or neither bypassed nor unreached.
pub fn emits(f: *const Ssa, i: usize, block: Block.Index) bool {
    return i == 0 or (f.fwd.items[@backingInt(block)] == block and !f.unreached.items[@backingInt(block)]);
}

/// Whether block `index` ends with a call of a noreturn function (a
/// failing check's panic, `@panic`).
fn endsCold(f: *const Ssa, ir: *const Ir, index: u32) bool {
    const b = f.blocks.items[index];
    return b.len != 0 and (b.term.tag == .noreturn or b.term.tag == .unreach) and
        ir.instructions.items(.tag)[@backingInt(f.values.items(.inst)[b.start + b.len - 1])] == .call;
}

/// Computes each value's uses and live interval (`live`). A value that is
/// the condition of its own block's `branch` is read at the terminator:
/// the architecture may fuse it into the branch, so its operands live until
/// there.
///
/// `ctx.clobbers(inst)` and `ctx.termClobbers(block)` say which values
/// and terminators may overwrite the registers that do not survive a
/// call; a clobbering value writes its own result last. `live` must have
/// one entry per IR instruction already; `reg` and `tie` are the
/// architecture's, which may mark them in `ctx.clobbers`. A value crosses a
/// clobber point that lies after its definition and at or before its last
/// use, except one in a block that does not continue, which matters only
/// to the uses in that block after it.
pub fn liveness(f: *Ssa, gpa: Allocator, ir: *const Ir, ctx: anytype) Allocator.Error!void {
    assert(f.live.len == ir.instructions.len);
    const s = f.live.slice();
    @memset(s.items(.uses), 0);
    @memset(s.items(.crosses), false);
    @memset(s.items(.weight), 0);
    // Prefix counts of the clobber points by position.
    try f.clobbers.resize(gpa, 2 * f.values.len + 3);
    const cl = f.clobbers.items;
    {
        var counts: [2]u32 = .{ 0, 0 };
        cl[0] = counts;
        cl[1] = counts;
        for (f.layout.items) |block| {
            const b = f.blocks.items[@backingInt(block)];
            const k: usize = @intFromBool(deadEnd(b.term.tag));
            for (b.start..b.start + b.len) |i| {
                if (ctx.clobbers(f.values.items(.inst)[i])) counts[k] += 1;
                cl[2 * i + 2] = counts;
                cl[2 * i + 3] = counts; // until the next value or terminator
            }
            if (ctx.termClobbers(block)) counts[k] += 1;
            cl[2 * (b.start + b.len) + 1] = counts;
            cl[2 * (b.start + b.len) + 2] = counts;
        }
    }
    for (&f.slots.free) |*l| l.clearRetainingCapacity();
    f.slots.active.clearRetainingCapacity();
    var w: LiveWalk = .{ .uses = s.items(.uses), .weight = s.items(.weight), .def = s.items(.def), .end = s.items(.end), .crosses = s.items(.crosses), .clobbers = cl, .loops = f.loops.items, .loop = no_loop, .pos = 0, .dead_start = null };
    const insts = f.values.items(.inst);
    const datas = ir.instructions.items(.data);
    const tags = ir.instructions.items(.tag);
    for (f.layout.items) |block| {
        const b = f.blocks.items[@backingInt(block)];
        w.loop = f.block_loop.items[@backingInt(block)];
        w.dead_start = if (deadEnd(b.term.tag)) 2 * b.start + 1 else null;
        const term_pos = 2 * (b.start + b.len) + 1;
        const term_data = datas[@backingInt(b.term.inst)];
        const cond: ?Inst.Index = if (b.term.tag == .branch) branchCond(ir, b.term).toIndex() else null;
        // The condition a `not` negates may be fused into the branch with
        // it (`plan`).
        const negated: ?Inst.Index = if (cond) |c| if (tags[@backingInt(c)] == .not) datas[@backingInt(c)].ty_op.operand.toIndex() else null else null;
        for (b.start..b.start + b.len) |i| {
            const inst = insts[i];
            const p: u32 = @intCast(2 * i + 2);
            w.def[@backingInt(inst)] = p;
            w.end[@backingInt(inst)] = p;
            w.pos = if ((cond != null and cond.? == inst) or (negated != null and negated.? == inst)) term_pos else p;
            forEachOperand(ir, inst, &w);
        }
        w.pos = term_pos;
        switch (b.term.tag) {
            .jump, .branch => if (tags[@backingInt(b.term.inst)] == .br) {
                w.use(term_data.br.operand);
                // The `br` writes the block's result.
                const blk = @backingInt(term_data.br.block_inst);
                w.end[blk] = @max(w.end[blk], term_pos);
            } else if (b.term.tag == .branch) w.use(branchCond(ir, b.term)),
            .switch_br => w.use(term_data.pl_op.operand),
            .ret => w.use(term_data.un_op),
            .fallthrough, .noreturn, .unreach => {},
        }
    }
    for (f.values.items(.inst)) |inst| {
        const i = @backingInt(inst);
        if (cl[w.end[i]][0] != cl[w.def[i]][0]) w.crosses[i] = true;
    }
}

/// Decisions after `liveness` that are the same on every architecture,
/// recorded in `Live.fate`, `pairs`, and `reg`:
/// - Pass 2: values that nothing reads and whose computation has no effect
///   (`removable`) are `dead`. Their operands lose a use, so chains of them
///   go in the same backward sweep (operands come first in the layout).
///   Intervals stay as `liveness` computed them, which is only longer.
/// - An overflow operation whose fields are read right after it, with
///   nothing between that gets a register, and by nothing else, is a
///   `pair`: the fields' intervals start at the operation, which writes
///   them. Its bit is `fused` when only its block's branch tests it, if
///   nothing between sets the flags and `ctx.ovfFlagsOnly(tag, bits)`.
/// - A condition only its block's branch reads is `fused` if
///   `ctx.fusable(inst)`.
/// - Arguments are all moved at the entry, so an unused one, whose interval
///   ends there, takes no register.
/// - Promotion: a non-volatile alloc whose type is in a general-purpose
///   register (`ctx.inGpr`), two (`ctx.inPair`), a floating-point one
///   (`ctx.inFloat`), or a vector one (`ctx.inVec`) and whose address is
///   only loaded from and stored to, so it is never taken, gets `want_reg`
///   (`want_pair`, `want_float`, `want_vec`), and its loads and
///   stores are moves. This is mem2reg without renaming: the variable
///   keeps one register for its interval, which `liveness` extends over
///   the loops that use it, so it needs no phis. A load may share the
///   variable's register (`Live.share`).
/// With inline assembly only pass 2 runs. `ctx.inGpr(ty)` says whether
/// an overflow operation on `ty` runs in general-purpose registers.
pub fn plan(f: *Ssa, gpa: Allocator, ir: *const Ir, ip: *const InternPool, ctx: anytype) Allocator.Error!void {
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    const insts = f.values.items(.inst);
    const live = f.live.slice();
    const uses = live.items(.uses);
    const reg = live.items(.reg);
    const def = live.items(.def);
    const fate = live.items(.fate);
    const share = live.items(.share);
    @memset(live.items(.reg2), no_reg);
    @memset(fate, .normal);
    @memset(share, no_tie);
    const fwd = live.items(.fwd);
    @memset(fwd, no_tie);
    f.pairs.clearRetainingCapacity();
    try f.deadFills(gpa, ir, ip);
    {
        const Uses = struct {
            uses: []u32,
            const Self = @This();
            pub fn use(c: Self, ref: Inst.Ref) void {
                if (ref.toIndex()) |i| c.uses[@backingInt(i)] -= 1;
            }
        };
        var i = insts.len;
        while (i > 0) {
            i -= 1;
            const inst = insts[i];
            if (uses[@backingInt(inst)] != 0 or !removable(ir, ip, inst)) continue;
            fate[@backingInt(inst)] = .dead;
            reg[@backingInt(inst)] = no_reg;
            forEachOperand(ir, inst, Uses{ .uses = uses });
        }
    }
    if (f.no_regs) return;
    // Promotion counts each candidate's loads and stores in `share`, free
    // until the loads' entries are set.
    const count = share;
    const candidate = no_tie - 1;
    f.candidates.clearRetainingCapacity();
    f.var_loads.clearRetainingCapacity();
    f.var_load_loops.clearRetainingCapacity();
    // A candidate's `fwd` holds its only store while forwarding is
    // possible, then `no_fwd`.
    const no_fwd = no_tie - 1;
    for (f.layout.items) |block| {
        const b = f.blocks.items[@backingInt(block)];
        // A threaded `br` that writes a result something reads needs its
        // condition as a value.
        const cond: ?Inst.Index = if (b.term.tag != .branch) null else if (tags[@backingInt(b.term.inst)] == .br) cond: {
            const br = datas[@backingInt(b.term.inst)].br;
            break :cond if (uses[@backingInt(br.block_inst)] == 0) br.operand.toIndex() else null;
        } else branchCond(ir, b.term).toIndex();
        const values = insts[b.start..][0..b.len];
        for (values, 0..) |inst, k| {
            const i = @backingInt(inst);
            switch (tags[i]) {
                .add_with_overflow, .sub_with_overflow, .mul_with_overflow => {
                    const op_ty = ir.typeOf(ir.extraData(Ir.Bin, datas[i].ty_pl.payload).data.lhs, ip);
                    if (!ctx.inGpr(op_ty)) continue;
                    var fields: [2]u32 = .{ no_tie, no_tie };
                    var n: u32 = 0;
                    for (values[k + 1 ..]) |next| {
                        const j = @backingInt(next);
                        // A destructuring `const r, const o = @addWithOverflow(..)`
                        // stores each field before reading the next.
                        if (tags[j] == .dbg_stmt or tags[j] == .store or fate[j] == .dead) continue;
                        if (tags[j] != .struct_field_val) break;
                        const sf = ir.extraData(Ir.StructField, datas[j].ty_pl.payload).data;
                        if (sf.operand != inst.toRef() or fields[sf.index] != no_tie) break;
                        fields[sf.index] = j;
                        n += 1;
                    }
                    if (n == 0 or n != uses[i]) continue;
                    fate[i] = .pair;
                    for (fields) |j| if (j != no_tie) {
                        // A store between the operation and the field's read
                        // may be a clobber point the field now lives across.
                        const cl = f.clobbers.items;
                        if (cl[def[j]][0] != cl[def[i]][0] or cl[def[j]][1] != cl[def[i]][1]) live.items(.crosses)[j] = true;
                        def[j] = def[i];
                    };
                    try f.pairs.put(gpa, i, fields);
                    const bit = fields[1];
                    if (bit != no_tie and uses[bit] == 1 and cond != null and uses[@backingInt(cond.?)] == 1 and
                        ovfBitCmp(ir, ip, cond.?, bit) != null and ctx.ovfFlagsOnly(tags[i], Type.intInfo(ip, op_ty).bits) and
                        for (values[k + 1 ..]) |next| switch (tags[@backingInt(next)]) {
                            .dbg_stmt, .block => {},
                            .struct_field_val => if (ir.extraData(Ir.StructField, datas[@backingInt(next)].ty_pl.payload).data.operand != inst.toRef()) break false,
                            else => if (next != cond.?) break false,
                        } else true)
                    {
                        fate[bit] = .fused;
                        reg[bit] = no_reg;
                    }
                },
                .arg => if (uses[i] == 0) {
                    reg[i] = no_reg;
                },
                .alloc => {
                    const ty = datas[i].ty;
                    if (ty == .none) continue;
                    const info = Type.ptrInfo(ip, ty);
                    if (info.flags.is_volatile) continue;
                    // Class 3: only forwarded, never promoted.
                    const class: u32 = if (ctx.inGpr(info.child)) 0 else if (ctx.inPair(info.child)) 1 else if (ctx.inFloat(info.child)) 2 else if (ctx.inVec(info.child)) 4 else if (info.flags.is_const) 3 else continue;
                    count[i] = candidate;
                    if (!info.flags.is_const) fwd[i] = no_fwd;
                    try f.candidates.append(gpa, i | class << 29);
                },
                .load => if (fate[i] != .dead) {
                    const v = @backingInt(datas[i].ty_op.operand.toIndex() orelse continue);
                    if (count[v] == no_tie) continue;
                    count[v] -%= 1;
                    try f.var_loads.append(gpa, i);
                    try f.var_load_loops.append(gpa, f.block_loop.items[@backingInt(block)]);
                },
                .store => if (fate[i] != .dead) {
                    const bin = datas[i].bin_op;
                    const v = @backingInt(bin.lhs.toIndex() orelse continue);
                    if (count[v] != no_tie and bin.rhs != bin.lhs) count[v] -%= 1;
                    if (count[v] != no_tie) fwd[v] = if (fwd[v] == no_tie and bin.rhs.toIndex() != null) i else no_fwd;
                },
                else => if (cond != null and cond.? == inst and uses[i] == 1 and ctx.fusable(inst)) {
                    fate[i] = .fused;
                    reg[i] = no_reg;
                    // So is the condition a `not` negates, in this block
                    // and read only by it: the branch tests the negated
                    // flags.
                    if (tags[i] == .not) if (datas[i].ty_op.operand.toIndex()) |x| {
                        const xi = @backingInt(x);
                        if (uses[xi] == 1 and fate[xi] == .normal and tags[xi] != .not and def[xi] > 2 * b.start and ctx.fusable(x)) {
                            fate[xi] = .fused;
                            reg[xi] = no_reg;
                        }
                    };
                },
            }
        }
    }
    // Forwarding needs the store before every load in the layout, as it
    // dominates them.
    for (f.var_loads.items) |l| {
        const v = @backingInt(datas[l].ty_op.operand.toIndex().?);
        if (fwd[v] < no_fwd and def[l] < def[fwd[v]]) fwd[v] = no_fwd;
    }
    // A candidate whose every use is a load or a store's address is
    // forwarded or promoted (see `plan`).
    const tie = live.items(.tie);
    for (f.candidates.items) |c| {
        const v = c & ~(@as(u32, 7) << 29);
        if (candidate - count[v] == uses[v]) {
            if (fwd[v] < no_fwd) {
                fate[v] = .dead;
                fate[fwd[v]] = .dead;
                reg[v] = no_reg;
            } else if (c >> 29 != 3) {
                reg[v] = switch (c >> 29) {
                    0 => want_reg,
                    1 => want_pair,
                    2 => want_float,
                    else => want_vec,
                };
                tie[v] = no_tie;
            }
        }
        count[v] = no_tie;
        // Only a forwarded alloc keeps its store (read below); `fwd` of
        // any other value is a forwarded load's.
        if (fate[v] != .dead) fwd[v] = no_tie;
    }
    const crosses = live.items(.crosses);
    const end = live.items(.end);
    const cl = f.clobbers.items;
    for (f.var_loads.items, f.var_load_loops.items) |l, loop| {
        const v = datas[l].ty_op.operand.toIndex().?;
        if (fate[@backingInt(v)] == .dead and fwd[@backingInt(v)] < no_fwd) {
            // The load is the value stored, which lives through the
            // load's interval and every loop around the load that does
            // not contain its definition.
            var w = @backingInt(datas[fwd[@backingInt(v)]].bin_op.rhs.toIndex().?);
            if (fwd[w] != no_tie and tags[w] == .load) w = fwd[w];
            fwd[l] = w;
            reg[l] = no_reg;
            var e = end[l];
            var lp = loop;
            while (lp != no_loop and f.loops.items[lp].start > def[w]) : (lp = f.loops.items[lp].parent) e = @max(e, f.loops.items[lp].end);
            end[w] = @max(end[w], e);
            // The load's `crosses` covers its uses; a clobber point between
            // the definition and the load counts too, also in a block that
            // does not continue.
            crosses[w] = crosses[w] or crosses[l] or cl[end[w]][0] != cl[def[w]][0] or cl[def[l]][1] != cl[def[w]][1];
        }
    }
    // The architecture may lengthen intervals too, before they decide
    // what may share a register.
    ctx.lengthenIntervals();
    // After forwarding, which lengthens the intervals of values stored.
    for (f.var_loads.items) |l| {
        const v = datas[l].ty_op.operand.toIndex().?;
        if (reg[@backingInt(v)] != reg[l] or !wants(reg[l])) continue;
        share[l] = f.shareable(ir, @fromBackingInt(l), v);
        // The load may cross a clobber point the variable does not: one in
        // a block that does not continue, with the load read after it.
        if (share[l] != no_tie and crosses[l]) crosses[@backingInt(v)] = true;
    }
    // A value whose only use stores it to a promoted variable may be
    // computed in the variable's register (`Live.share`), so the store is
    // no move. The store is in the value's block, or in an arm of its
    // block's branch that follows past dead ends (the failing check of an
    // overflowing `+=`). So may a value whose only use is its block's
    // `br`, in the register of the block's result, which nothing reads
    // before the block ends.
    for (f.layout.items, 0..) |block, k| {
        const b = f.blocks.items[@backingInt(block)];
        if (b.term.tag == .jump and tags[@backingInt(b.term.inst)] == .br) br: {
            const br = datas[@backingInt(b.term.inst)].br;
            const v = @backingInt(br.block_inst);
            const w = @backingInt(br.operand.toIndex() orelse break :br);
            if (reg[v] != reg[w] or (reg[w] != want_reg and reg[w] != want_float and reg[w] != want_vec)) break :br;
            if (uses[w] != 1 or fate[w] != .normal or share[w] != no_tie or end[w] != valuePos(b.start + b.len) - 1) break :br;
            if (tags[w] == .block or def[w] < valuePos(b.start)) break :br;
            f.shareTies(ir, @fromBackingInt(w), @fromBackingInt(v), valuePos(b.start));
        }
        if (f.var_loads.items.len != 0) for (insts[b.start..][0..b.len], b.start..) |inst, idx| {
            const i = @backingInt(inst);
            if (tags[i] != .store) continue;
            const bin = datas[i].bin_op;
            const v = @backingInt(bin.lhs.toIndex() orelse continue);
            const w = @backingInt(bin.rhs.toIndex() orelse continue);
            if (tags[v] != .alloc or reg[v] != reg[w] or (reg[w] != want_reg and reg[w] != want_float and reg[w] != want_vec)) continue;
            if (uses[w] != 1 or fate[w] != .normal or share[w] != no_tie or end[w] != valuePos(idx) or def[w] <= def[v]) continue;
            if (tags[w] == .block) continue;
            var start = valuePos(b.start);
            if (def[w] < start) {
                // Every block between runs no further or only jumps here,
                // and no terminator on the way reads the variable's
                // register. The branch leaves for this block or for a dead
                // end between.
                var j = k;
                const ok = while (j > 0 and k - j < 4) {
                    j -= 1;
                    const pi = f.layout.items[j];
                    const pb = f.blocks.items[@backingInt(pi)];
                    if (f.termReadsShared(ir, pb.term, @fromBackingInt(v))) break false;
                    if (def[w] >= valuePos(pb.start)) {
                        start = valuePos(pb.start);
                        if (pb.term.tag != .branch) break false;
                        var here = false;
                        for (pb.term.succ) |succ| {
                            const t = f.fwd.items[succ];
                            if (t == block) {
                                here = true;
                            } else {
                                const tb = f.blocks.items[@backingInt(t)];
                                if (!deadEnd(tb.term.tag) or valuePos(tb.start) < def[w] or tb.start >= b.start) break;
                            }
                        } else break here;
                        break false;
                    }
                    if (!deadEnd(pb.term.tag) and f.fwd.items[@backingInt(pi)] != block) break false;
                } else false;
                if (!ok) continue;
            }
            if (f.storeShares(ir, @fromBackingInt(w), @fromBackingInt(v), idx)) f.shareTies(ir, @fromBackingInt(w), @fromBackingInt(v), start);
        };
    }
    for (f.candidates.items) |c| fwd[c & ~(@as(u32, 7) << 29)] = no_tie;
}

/// `v` if load `load` of promoted variable `v` may share its register
/// (`Live.share`), else `no_tie`. A store of the load itself writes back
/// what the register holds.
fn shareable(f: *const Ssa, ir: *const Ir, load: Inst.Index, v: Inst.Index) u32 {
    const live = f.live.slice();
    const def = live.items(.def);
    const end = live.items(.end);
    const l = @backingInt(load);
    if (end[l] > end[@backingInt(v)]) return no_tie;
    // Value `i` is at position `2 * i + 2`: scan the values after the load
    // up to its interval's end, which is usually close.
    const first = (def[l] - 2) / 2 + 1;
    const stop = @min(end[l] / 2, f.values.len);
    if (stop > first + 64) return no_tie;
    const insts = f.values.items(.inst);
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    for (insts[@min(first, stop)..stop]) |inst| {
        if (tags[@backingInt(inst)] != .store) continue;
        const bin = datas[@backingInt(inst)].bin_op;
        if (bin.lhs == v.toRef() and bin.rhs != load.toRef()) return no_tie;
    }
    return @backingInt(v);
}

/// Lets value `w` share `v`'s register (`Live.share`), and so the chain
/// of tied operands that compute it from position `start` on, each read
/// only by the next, while nothing between reads the register.
fn shareTies(f: *Ssa, ir: *const Ir, w: Inst.Index, v: Inst.Index, start: u32) void {
    const live = f.live.slice();
    const share = live.items(.share);
    const uses = live.items(.uses);
    const def = live.items(.def);
    const end = live.items(.end);
    const reg = live.items(.reg);
    const tie = live.items(.tie);
    const fate = live.items(.fate);
    share[@backingInt(w)] = @backingInt(v);
    var x = @backingInt(w);
    while (true) {
        const u = tie[x];
        if (u == no_tie or uses[u] != 1 or end[u] != def[x] or def[u] < start or fate[u] != .normal) break;
        if (reg[u] != reg[@backingInt(w)] or share[u] != no_tie or ir.instructions.items(.tag)[u] == .block) break;
        if (!f.storeShares(ir, @fromBackingInt(u), v, (def[x] - 2) / 2)) break;
        // `u` holds the register when `x` reads its other operands (a
        // call's arguments, with `u` its callee), so none may share it.
        var c: SharedReads = .{ .f = f, .ir = ir, .v = v, .tie = u };
        forEachOperand(ir, @fromBackingInt(x), &c);
        if (c.other) break;
        share[u] = @backingInt(v);
        x = u;
    }
}

/// Whether value `w`, stored to promoted variable `v` by the value at
/// index `store` and by nothing else, may be computed in `v`'s register:
/// nothing from `w`'s definition up to the store reads that register (a
/// load of `v`, or a use of a load that shares it), except an operand that
/// `w`'s lowering reads before writing its result (its tied operand, a
/// call's arguments, an overflow operation's operands for its fields).
/// The terminators on the way are the caller's.
fn storeShares(f: *const Ssa, ir: *const Ir, w: Inst.Index, v: Inst.Index, store: usize) bool {
    const live = f.live.slice();
    const def = live.items(.def);
    const fate = live.items(.fate);
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    const first = (def[@backingInt(w)] - 2) / 2 + 1;
    if (store > first + 64) return false;
    const reads_all = switch (tags[@backingInt(w)]) {
        .call => true,
        .struct_field_val => blk: {
            const op = ir.extraData(Ir.StructField, datas[@backingInt(w)].ty_pl.payload).data.operand.toIndex() orelse break :blk false;
            break :blk fate[@backingInt(op)] == .pair;
        },
        else => false,
    };
    // With its tied operand in the register too, the lowering writes the
    // register only after reading every operand.
    const t = live.items(.tie)[@backingInt(w)];
    if (!reads_all and (t == no_tie or live.items(.share)[t] != @backingInt(v))) {
        var c: SharedReads = .{ .f = f, .ir = ir, .v = v, .tie = t };
        forEachOperand(ir, w, &c);
        if (c.other) return false;
    }
    for (f.values.items(.inst)[first..store]) |inst| {
        const i = @backingInt(inst);
        if (fate[i] == .dead) continue;
        if (tags[i] == .load and datas[i].ty_op.operand == v.toRef()) return false;
        var c: SharedReads = .{ .f = f, .ir = ir, .v = v, .tie = no_tie };
        forEachOperand(ir, inst, &c);
        if (c.other) return false;
    }
    return true;
}

/// Whether terminator `term` reads a load that shares promoted variable
/// `v`'s register.
fn termReadsShared(f: *const Ssa, ir: *const Ir, term: Term, v: Inst.Index) bool {
    const data = ir.instructions.items(.data)[@backingInt(term.inst)];
    var c: SharedReads = .{ .f = f, .ir = ir, .v = v, .tie = no_tie };
    switch (term.tag) {
        .jump => if (ir.instructions.items(.tag)[@backingInt(term.inst)] == .br) c.use(data.br.operand),
        .branch => c.use(branchCond(ir, term)),
        .switch_br => c.use(data.pl_op.operand),
        .ret => c.use(data.un_op),
        .fallthrough, .noreturn, .unreach => {},
    }
    return c.other;
}

/// For `forEachOperand`: finds operands that are loads sharing promoted
/// variable `v`'s register, other than `tie`.
const SharedReads = struct {
    f: *const Ssa,
    ir: *const Ir,
    v: Inst.Index,
    tie: u32,
    other: bool = false,

    fn use(c: *SharedReads, ref: Inst.Ref) void {
        const l = @backingInt(ref.toIndex() orelse return);
        // A forwarded load reads the value stored (`Live.fwd`), which may
        // be a load sharing the register: `temp.b` of `const temp = gcd`
        // reads `gcd.b`'s register.
        const fwd = c.f.live.items(.fwd)[l];
        const r = if (fwd != no_tie and c.ir.instructions.items(.tag)[l] == .load) fwd else l;
        if (c.f.live.items(.share)[r] != @backingInt(c.v)) return;
        if (l != c.tie) c.other = true;
    }
};

/// The most allocs `deadFills` considers in one function.
const max_fill_allocs = 16;
/// The most sweeps its dataflow takes before it keeps every fill.
const max_fill_sweeps = 16;

/// Scratch for `deadFills`, reused for the next function.
pub const Fills = struct {
    allocs: std.ArrayList(FillAlloc) = .empty,
    /// Per IR instruction: the candidate alloc a pointer points into, and
    /// where (`FillPtr.none` for any other, which every entry is again
    /// once `deadFills` returns).
    ptrs: std.ArrayList(FillPtr) = .empty,
    /// The pointers into candidates (`FillPtr.slot`), and how many of
    /// their uses `deadFills` followed: a pointer with another use
    /// escapes.
    family: std.ArrayList(u32) = .empty,
    seen: std.ArrayList(u32) = .empty,
    /// The candidates' reads and writes in layout order, and per block its
    /// range of them.
    events: std.ArrayList(FillEvent) = .empty,
    spans: std.ArrayList([2]u32) = .empty,
    /// What `for` loops write (`loopWrites`), as writes at the start of
    /// the blocks their exit branches go to.
    pending: std.ArrayList(Pending) = .empty,
    /// Per block and candidate (`ok[block * n + c]`): the chunks that every
    /// path from the block's start writes before it reads them.
    ok: std.ArrayList(u64) = .empty,

    fn deinit(s: *Fills, gpa: Allocator) void {
        s.allocs.deinit(gpa);
        s.ptrs.deinit(gpa);
        s.family.deinit(gpa);
        s.seen.deinit(gpa);
        s.events.deinit(gpa);
        s.spans.deinit(gpa);
        s.pending.deinit(gpa);
        s.ok.deinit(gpa);
        s.* = undefined;
    }

    const Pending = struct { block: u32, event: FillEvent };

    /// The pointer `ref` is, if it points into a candidate; counts the
    /// use.
    fn ptrOf(s: *Fills, ref: Inst.Ref) ?FillPtr {
        const i = ref.toIndex() orelse return null;
        const p = s.ptrs.items[@backingInt(i)];
        if (p.cand == FillPtr.none.cand) return null;
        s.seen.items[p.slot] += 1;
        return p;
    }

    /// Records `p` as the pointer instruction `inst` computes.
    fn derive(s: *Fills, gpa: Allocator, inst: u32, p: FillPtr) Allocator.Error!void {
        var q = p;
        q.slot = @intCast(s.family.items.len);
        try s.family.append(gpa, inst);
        try s.seen.append(gpa, 0);
        s.ptrs.items[inst] = q;
    }

    fn add(s: *Fills, gpa: Allocator, p: FillPtr, kind: FillEvent.Kind, mask: u64, inst: Inst.Index) Allocator.Error!void {
        if (mask == 0) return;
        try s.events.append(gpa, .{ .mask = mask, .cover = mask, .inst = @backingInt(inst), .cand = p.cand, .kind = kind });
    }
};

/// An alloc a fill stores into. Its bytes are tracked in up to 64 chunks
/// of `chunk` bytes each.
const FillAlloc = struct {
    alloc: u32,
    size: u64,
    chunk: u64,
    escaped: bool,

    fn bits(lo: u64, hi: u64) u64 {
        if (hi <= lo) return 0;
        const ones: u64 = if (hi - lo == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(hi - lo)) - 1;
        return ones << @intCast(lo);
    }

    /// The chunks that lie wholly inside bytes `lo..hi`.
    fn cover(a: FillAlloc, lo: u64, hi_in: u64) u64 {
        const hi = @min(hi_in, a.size);
        if (lo >= hi) return 0;
        const end = if (hi == a.size) std.math.divCeil(u64, a.size, a.chunk) catch unreachable else hi / a.chunk;
        return bits(std.math.divCeil(u64, lo, a.chunk) catch unreachable, end);
    }

    /// The chunks that bytes `lo..hi` touch.
    fn touch(a: FillAlloc, lo: u64, hi_in: u64) u64 {
        const hi = @min(hi_in, a.size);
        if (lo >= hi) return 0;
        return bits(lo / a.chunk, std.math.divCeil(u64, hi, a.chunk) catch unreachable);
    }

    fn all(a: FillAlloc) u64 {
        return a.touch(0, a.size);
    }

    /// The chunks a store of a `ty` at `off` surely writes (`write`), or
    /// that a load of one may read: the bytes of its value, not its
    /// padding. Unknown layouts write nothing and read everything.
    fn typeMask(a: FillAlloc, ip: *const InternPool, ty: InternPool.Index, off: u64, comptime write: bool, budget: *u32) u64 {
        const size = Type.abiSize(ip, ty);
        if (size == 0) return 0;
        const full = if (write) a.cover(off, off + size) else a.touch(off, off + size);
        if (budget.* == 0) return if (write) 0 else full;
        budget.* -= 1;
        switch (Type.class(ip, ty)) {
            .@"struct" => if (!Type.isPacked(ip, ty)) {
                var m: u64 = 0;
                const info = ip.structInfo(ty);
                for (info.field_types, 0..) |ft, i| {
                    if (info.fieldIsComptime(i) or !Type.hasRuntimeBits(ip, ft)) continue;
                    m |= a.typeMask(ip, ft, off + info.field_offsets[i], write, budget);
                }
                return m;
            } else if (write) {
                return a.cover(off, off + (@as(u64, Type.intInfo(ip, ip.structInfo(ty).tag_type).bits) + 7) / 8);
            },
            .tuple => {
                var m: u64 = 0;
                const t = ip.keyPayload(.tuple_type, ty);
                for (t.types, t.values, 0..) |ft, fv, i| {
                    if (fv != .none or !Type.hasRuntimeBits(ip, ft)) continue;
                    m |= a.typeMask(ip, ft, off + Type.tupleLayout(ip, ty, i).field_offset, write, budget);
                }
                return m;
            },
            else => if (!write) return full,
        }
        // What a store surely writes of the rest.
        return switch (Type.class(ip, ty)) {
            .int, .@"enum", .error_set => a.cover(off, off + (@as(u64, Type.intInfo(ip, ty).bits) + 7) / 8),
            .float => a.cover(off, off + Type.floatBits(ip, ty) / 8),
            .bool, .pointer => full,
            .array => blk: {
                const arr = ip.keyPayload(.array_type, ty);
                if (arr.len > 64) break :blk 0;
                const es = Type.abiSize(ip, arr.child);
                var m: u64 = 0;
                for (0..arr.len) |i| m |= a.typeMask(ip, arr.child, off + i * es, true, budget);
                break :blk m;
            },
            .vector => blk: {
                const v = ip.keyPayload(.vector_type, ty);
                if (v.child == .bool_type) break :blk 0;
                const es = Type.abiSize(ip, v.child);
                if (Type.class(ip, v.child) == .float and Type.floatBits(ip, v.child) != es * 8) break :blk 0;
                if (Type.class(ip, v.child) == .int and Type.intInfo(ip, v.child).bits != es * 8) break :blk 0;
                break :blk a.cover(off, off + v.len * es);
            },
            .optional => blk: {
                const child = Type.childType(ip, ty);
                if (Type.optionalReprIsPayload(ip, child)) break :blk a.typeMask(ip, child, off, true, budget);
                const flag = Type.optionalFlagOffset(ip, ty);
                break :blk a.typeMask(ip, child, off, true, budget) | a.cover(off + flag, off + flag + 1);
            },
            .error_union => blk: {
                const l = Type.errorUnionLayout(ip, ty);
                const payload = ip.keyPayload(.error_union_type, ty).payload_type;
                break :blk a.cover(off + l.err_offset, off + l.err_offset + 2) | a.typeMask(ip, payload, off + l.payload_offset, true, budget);
            },
            else => 0,
        };
    }
};

/// A pointer into candidate alloc `cand`, `off` bytes in (`unknown` when
/// not constant).
const FillPtr = packed struct(u64) {
    cand: u8,
    /// Its index in `Fills.family`.
    slot: u24 = 0,
    off: u32,

    const unknown = std.math.maxInt(u32);
    const none: FillPtr = .{ .cand = 0xff, .off = 0 };

    fn plus(p: FillPtr, n: ?u64) FillPtr {
        const k = n orelse return .{ .cand = p.cand, .off = unknown };
        if (p.off == unknown or k >= unknown - p.off) return .{ .cand = p.cand, .off = unknown };
        return .{ .cand = p.cand, .off = @intCast(p.off + k) };
    }
};

/// A read of the chunks `mask`, a write of them, or a fill of bytes that
/// touch `mask` and wholly write `cover`.
const FillEvent = struct {
    mask: u64,
    cover: u64,
    inst: u32,
    cand: u8,
    kind: Kind,

    const Kind = enum(u8) { read, write, fill };
};

/// An address: alloc `root`, plus `off` bytes, plus each term's index
/// times its stride (innermost first).
const FillAddr = struct {
    root: u32,
    off: u64,
    terms: [3]Index = undefined,
    n: u8 = 0,

    const Index = struct { idx: Inst.Ref, stride: u64 };

    fn of(ir: *const Ir, ip: *const InternPool, ptr: Inst.Ref) ?FillAddr {
        const tags = ir.instructions.items(.tag);
        const datas = ir.instructions.items(.data);
        var a: FillAddr = .{ .root = undefined, .off = 0 };
        var r = ptr;
        while (true) {
            const i = @backingInt(r.toIndex() orelse return null);
            switch (tags[i]) {
                .alloc => {
                    a.root = i;
                    return a;
                },
                .ptr_elem_ptr => {
                    const bin = ir.extraData(Ir.Bin, datas[i].ty_pl.payload).data;
                    const stride = Type.abiSize(ip, Type.ptrInfo(ip, datas[i].ty_pl.ty).child);
                    if (bin.rhs.toInterned()) |k| {
                        a.off = std.math.add(u64, a.off, std.math.mul(u64, ip.intValue(u64, k) orelse return null, stride) catch return null) catch return null;
                    } else {
                        if (a.n == a.terms.len) return null;
                        a.terms[a.n] = .{ .idx = bin.rhs, .stride = stride };
                        a.n += 1;
                    }
                    r = bin.lhs;
                },
                .struct_field_ptr => {
                    const sf = ir.extraData(Ir.StructField, datas[i].ty_pl.payload).data;
                    const container = Type.ptrInfo(ip, ir.typeOf(sf.operand, ip)).child;
                    switch (ip.keyTag(container)) {
                        .struct_type, .tuple_type => {},
                        else => return null,
                    }
                    if (Type.isPacked(ip, container)) return null;
                    a.off = std.math.add(u64, a.off, Type.fieldOffset(ip, container, sf.index)) catch return null;
                    r = sf.operand;
                },
                .bitcast => {
                    if (ip.keyTag(datas[i].ty_op.ty) != .ptr_type or Type.isSlice(ip, datas[i].ty_op.ty)) return null;
                    r = datas[i].ty_op.operand;
                },
                else => return null,
            }
        }
    }
};

/// Bytes `lo..hi` of `addr` (and its terms, which outer loops index).
const FillSpan = struct { addr: FillAddr, lo: u64, hi: u64 };

/// Whether a store of a `ty` writes all of its bytes: it has no padding.
fn denseType(ip: *const InternPool, ty: InternPool.Index) bool {
    const size = Type.abiSize(ip, ty);
    return switch (Type.class(ip, ty)) {
        .int, .@"enum", .error_set => @as(u64, Type.intInfo(ip, ty).bits) == size * 8,
        .float => @as(u64, Type.floatBits(ip, ty)) == size * 8,
        .bool, .pointer => true,
        .array => denseType(ip, ip.keyPayload(.array_type, ty).child) and ip.keyPayload(.array_type, ty).sentinel == .none,
        .vector => blk: {
            const v = ip.keyPayload(.vector_type, ty);
            break :blk v.child != .bool_type and denseType(ip, v.child) and v.len * Type.abiSize(ip, v.child) == size;
        },
        else => false,
    };
}

/// What `block` `x` surely writes when control leaves it normally, if it
/// is a `for` loop over a counter that writes one element per iteration:
///
///     store(c, lo)                    // `init`
///     x = block { loop {
///         h = load(c)
///         block { cond_br(cmp_lt(h, hi), { ...; W; ... }, { br x }) }
///         store(c, add_wrap(h, 1))
///         repeat
///     } }
///
/// where counter `c` has no other use, nothing before `W` in the body
/// leaves it but by returning or not returning, `W` writes element `h` of
/// an alloc wholly (a store of a type without padding, or an inner such
/// loop over its bytes), and only the exit branch goes to `x`. Every
/// iteration that reaches the increment passed `W`, so leaving through
/// `x` follows the iterations of `lo` through `hi - 1`.
fn loopWrites(ir: *const Ir, ip: *const InternPool, uses: []const u32, x: Inst.Index, init: Inst.Index, depth: u32) ?FillSpan {
    if (depth > 3) return null;
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    const Body = struct {
        insts: []const Inst.Index,
        i: usize = 0,
        const Self = @This();
        fn next(b: *Self, t: []const Inst.Tag) ?Inst.Index {
            while (b.i < b.insts.len) {
                const inst = b.insts[b.i];
                b.i += 1;
                if (t[@backingInt(inst)] != .dbg_stmt) return inst;
            }
            return null;
        }
        fn of(irr: *const Ir, inst: Inst.Index) Self {
            const e = irr.extraData(Ir.Block, irr.instructions.items(.data)[@backingInt(inst)].ty_pl.payload);
            return .{ .insts = irr.bodySlice(e.end, e.data.body_len) };
        }
    };
    var xb: Body = .of(ir, x);
    const l = xb.next(tags) orelse return null;
    if (tags[@backingInt(l)] != .loop or xb.next(tags) != null) return null;
    var lb: Body = .of(ir, l);
    const h = lb.next(tags) orelse return null;
    if (tags[@backingInt(h)] != .load) return null;
    const c = datas[@backingInt(h)].ty_op.operand.toIndex() orelse return null;
    if (tags[@backingInt(c)] != .alloc or uses[@backingInt(c)] != 3) return null;
    const y = lb.next(tags) orelse return null;
    const inc = lb.next(tags) orelse return null;
    const st = lb.next(tags) orelse return null;
    const rep = lb.next(tags) orelse return null;
    if (tags[@backingInt(y)] != .block or tags[@backingInt(inc)] != .add_wrap or tags[@backingInt(st)] != .store or tags[@backingInt(rep)] != .repeat) return null;
    if (datas[@backingInt(inc)].bin_op.lhs != h.toRef() or datas[@backingInt(inc)].bin_op.rhs.toInterned() == null) return null;
    if (ip.intValue(u64, datas[@backingInt(inc)].bin_op.rhs.toInterned().?) != 1) return null;
    if (datas[@backingInt(st)].bin_op.lhs != c.toRef() or datas[@backingInt(st)].bin_op.rhs != inc.toRef()) return null;
    if (tags[@backingInt(init)] != .store or datas[@backingInt(init)].bin_op.lhs != c.toRef()) return null;
    const lo = ip.intValue(u64, datas[@backingInt(init)].bin_op.rhs.toInterned() orelse return null) orelse return null;

    var yb: Body = .of(ir, y);
    const cmp = yb.next(tags) orelse return null;
    const cb = yb.next(tags) orelse return null;
    if (tags[@backingInt(cmp)] != .cmp_lt or tags[@backingInt(cb)] != .cond_br or yb.next(tags) != null) return null;
    if (datas[@backingInt(cmp)].bin_op.lhs != h.toRef() or datas[@backingInt(cb)].pl_op.operand != cmp.toRef()) return null;
    const hi = ip.intValue(u64, datas[@backingInt(cmp)].bin_op.rhs.toInterned() orelse return null) orelse return null;
    if (lo >= hi) return null;
    const cx = ir.extraData(Ir.CondBr, datas[@backingInt(cb)].pl_op.payload);
    const then_body = ir.bodySlice(cx.end, cx.data.then_body_len);
    var eb: Body = .{ .insts = ir.bodySlice(cx.end + then_body.len, cx.data.else_body_len) };
    const exit = eb.next(tags) orelse return null;
    if (tags[@backingInt(exit)] != .br or datas[@backingInt(exit)].br.block_inst != x or eb.next(tags) != null) return null;
    if (brsTo(ir, then_body, x)) return null;

    // `W`, and what one iteration writes: `span` of the address with
    // term `h` at 0.
    var prev: ?Inst.Index = null;
    const w: FillSpan = for (then_body) |t| {
        const ti = @backingInt(t);
        switch (tags[ti]) {
            .dbg_stmt => continue,
            .store => if (FillAddr.of(ir, ip, datas[ti].bin_op.lhs)) |a| {
                const rhs = datas[ti].bin_op.rhs;
                const ty = ir.typeOf(rhs, ip);
                const undef = if (rhs.toInterned()) |v| ip.keyTag(v) == .undef else false;
                if (!undef and a.n != 0 and a.terms[0].idx == h.toRef() and denseType(ip, ty))
                    break .{ .addr = a, .lo = a.off, .hi = a.off + Type.abiSize(ip, ty) };
            },
            .block => if (prev) |p| if (loopWrites(ir, ip, uses, t, p, depth + 1)) |inner| {
                if (inner.addr.n != 0 and inner.addr.terms[0].idx == h.toRef()) break inner;
            },
            else => {},
        }
        if (!staysInside(ir, t)) return null;
        prev = t;
    } else return null;
    const stride = w.addr.terms[0].stride;
    if (w.hi - w.lo < stride) return null;
    var addr = w.addr;
    @memmove(addr.terms[0 .. addr.n - 1], addr.terms[1..addr.n]);
    addr.n -= 1;
    const first = std.math.mul(u64, lo, stride) catch return null;
    const last = std.math.mul(u64, hi - 1, stride) catch return null;
    return .{ .addr = addr, .lo = std.math.add(u64, w.lo, first) catch return null, .hi = std.math.add(u64, w.hi, last) catch return null };
}

/// Whether every `br` and `repeat` in the bodies `inst` holds goes to a
/// block or loop among them: control leaves `inst` only by finishing it,
/// by returning, or by not returning.
fn staysInside(ir: *const Ir, inst: Inst.Index) bool {
    var stack: [16]Inst.Index = undefined;
    return switch (ir.instructions.items(.tag)[@backingInt(inst)]) {
        .br, .repeat => false,
        .block, .loop, .cond_br, .switch_br => scanInside(ir, inst, &stack, 0),
        else => true,
    };
}

fn scanInside(ir: *const Ir, inst: Inst.Index, stack: *[16]Inst.Index, depth: usize) bool {
    var d = depth;
    switch (ir.instructions.items(.tag)[@backingInt(inst)]) {
        .block, .loop => {
            if (d == stack.len) return false;
            stack[d] = inst;
            d += 1;
        },
        else => {},
    }
    var ok = true;
    forEachBody(ir, inst, struct {
        stack: *[16]Inst.Index,
        d: usize,
        ok: *bool,
        const Self = @This();
        fn visit(c: Self, irr: *const Ir, body: []const Inst.Index) void {
            const datas = irr.instructions.items(.data);
            for (body) |b| {
                const target = switch (irr.instructions.items(.tag)[@backingInt(b)]) {
                    .br => datas[@backingInt(b)].br.block_inst,
                    .repeat => datas[@backingInt(b)].repeat.loop_inst,
                    .block, .loop, .cond_br, .switch_br => {
                        if (!scanInside(irr, b, c.stack, c.d)) c.ok.* = false;
                        continue;
                    },
                    else => continue,
                };
                if (std.mem.findScalar(Inst.Index, c.stack[0..c.d], target) == null) c.ok.* = false;
            }
        }
    }{ .stack = stack, .d = d, .ok = &ok });
    return ok;
}

/// Whether a `br` in `body` (or the bodies it holds) goes to block `x`.
fn brsTo(ir: *const Ir, body: []const Inst.Index, x: Inst.Index) bool {
    const datas = ir.instructions.items(.data);
    for (body) |b| switch (ir.instructions.items(.tag)[@backingInt(b)]) {
        .br => if (datas[@backingInt(b)].br.block_inst == x) return true,
        .block, .loop, .cond_br, .switch_br => {
            var found = false;
            forEachBody(ir, b, struct {
                x: Inst.Index,
                found: *bool,
                const Self = @This();
                fn visit(c: Self, irr: *const Ir, inner: []const Inst.Index) void {
                    if (brsTo(irr, inner, c.x)) c.found.* = true;
                }
            }{ .x = x, .found = &found });
            if (found) return true;
        },
        else => {},
    };
    return false;
}

/// Calls `ctx.visit(ir, body)` for each body instruction `inst` holds.
fn forEachBody(ir: *const Ir, inst: Inst.Index, ctx: anytype) void {
    const data = ir.instructions.items(.data)[@backingInt(inst)];
    switch (ir.instructions.items(.tag)[@backingInt(inst)]) {
        .block, .loop => {
            const extra = ir.extraData(Ir.Block, data.ty_pl.payload);
            ctx.visit(ir, ir.bodySlice(extra.end, extra.data.body_len));
        },
        .cond_br => {
            const extra = ir.extraData(Ir.CondBr, data.pl_op.payload);
            ctx.visit(ir, ir.bodySlice(extra.end, extra.data.then_body_len));
            ctx.visit(ir, ir.bodySlice(extra.end + extra.data.then_body_len, extra.data.else_body_len));
        },
        .switch_br => {
            var it = ir.switchCases(data.pl_op.payload);
            while (it.next()) |c| ctx.visit(ir, c.body);
            ctx.visit(ir, it.elseBody());
        },
        else => {},
    }
}

/// The alloc a fill's pointer points into, through field and element
/// pointers and pointer casts, if the pointer is not volatile.
fn fillBase(ir: *const Ir, ip: *const InternPool, ptr: Inst.Ref) ?u32 {
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    if (Type.ptrInfo(ip, ir.typeOf(ptr, ip)).flags.is_volatile) return null;
    var r = ptr;
    while (true) {
        const i = @backingInt(r.toIndex() orelse return null);
        r = switch (tags[i]) {
            .alloc => return if (datas[i].ty == .none) null else i,
            .struct_field_ptr => ir.extraData(Ir.StructField, datas[i].ty_pl.payload).data.operand,
            .ptr_elem_ptr, .ptr_add => ir.extraData(Ir.Bin, datas[i].ty_pl.payload).data.lhs,
            .bitcast => datas[i].ty_op.operand,
            else => return null,
        };
    }
}

/// Fill elimination: a store of `undefined` (the 0xaa fill, upstream's
/// Debug aid) into a local whose address only its loads, its stores, and
/// the field and element pointers of these see is `dead` when, on every
/// path from it, each byte it fills is written again before anything
/// reads it (or nothing reads it before the function returns or ends in a
/// panic, which reads no local). Then nothing can observe the fill. A
/// backward dataflow over the blocks, per alloc, of the bytes written
/// before they are read, from the end of each path; loops take sweeps to
/// the greatest fixpoint, so a path through a loop that does not touch
/// the alloc keeps what holds after it. Bytes are tracked in up to 64
/// chunks; a store covers the chunks it writes wholly, a load kills those
/// it touches. A load reads its value's bytes, not its padding, which
/// holds no value in Zig. Removing one dead fill keeps the others dead:
/// the bytes it fills are written again before any read on every path.
fn deadFills(f: *Ssa, gpa: Allocator, ir: *const Ir, ip: *const InternPool) Allocator.Error!void {
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    const insts = f.values.items(.inst);
    const s = &f.fills;
    s.allocs.clearRetainingCapacity();
    for (insts) |inst| {
        const i = @backingInt(inst);
        if (tags[i] != .store) continue;
        const bin = datas[i].bin_op;
        const v = bin.rhs.toInterned() orelse continue;
        if (ip.keyTag(v) != .undef) continue;
        const base = fillBase(ir, ip, bin.lhs) orelse continue;
        if (for (s.allocs.items) |c| {
            if (c.alloc == base) break true;
        } else false) continue;
        const size = Type.abiSize(ip, Type.ptrInfo(ip, datas[base].ty).child);
        if (size == 0) continue;
        try s.allocs.append(gpa, .{ .alloc = base, .size = size, .chunk = std.math.divCeil(u64, size, 64) catch unreachable, .escaped = false });
        if (s.allocs.items.len == max_fill_allocs) break;
    }
    if (s.allocs.items.len == 0) return;

    // The candidates' accesses, in layout order: definitions come before
    // their uses there.
    if (s.ptrs.items.len < ir.instructions.len) {
        const old = s.ptrs.items.len;
        try s.ptrs.resize(gpa, ir.instructions.len);
        @memset(s.ptrs.items[old..], FillPtr.none);
    }
    s.family.clearRetainingCapacity();
    s.seen.clearRetainingCapacity();
    defer for (s.family.items) |i| {
        s.ptrs.items[i] = FillPtr.none;
    };
    for (s.allocs.items, 0..) |c, k| try s.derive(gpa, c.alloc, .{ .cand = @intCast(k), .off = 0 });
    s.events.clearRetainingCapacity();
    s.pending.clearRetainingCapacity();
    // Every block is in the layout, which sets its span.
    try s.spans.resize(gpa, f.blocks.items.len);
    const uses = f.live.items(.uses);
    for (f.layout.items) |block| {
        const b = f.blocks.items[@backingInt(block)];
        const first: u32 = @intCast(s.events.items.len);
        for (s.pending.items) |pe| {
            if (pe.block == @backingInt(block)) try s.events.append(gpa, pe.event);
        }
        var prev: ?Inst.Index = null;
        for (insts[b.start..][0..b.len]) |inst| {
            const i = @backingInt(inst);
            const data = datas[i];
            defer if (tags[i] != .dbg_stmt) {
                prev = inst;
            };
            switch (tags[i]) {
                .block => if (prev) |p| if (loopWrites(ir, ip, uses, inst, p, 0)) |span| {
                    if (span.addr.n != 0) continue;
                    // Not a use: the loop's own stores are counted.
                    const ptr = s.ptrs.items[span.addr.root];
                    if (ptr.cand == FillPtr.none.cand or ptr.off == FillPtr.unknown) continue;
                    const a = s.allocs.items[ptr.cand];
                    const mask = a.cover(std.math.add(u64, ptr.off, span.lo) catch continue, std.math.add(u64, ptr.off, span.hi) catch continue);
                    if (mask == 0) continue;
                    try s.pending.append(gpa, .{ .block = @backingInt(f.targets.items[i]), .event = .{ .mask = mask, .cover = mask, .inst = i, .cand = ptr.cand, .kind = .write } });
                },
                .struct_field_ptr => {
                    const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
                    const p = s.ptrOf(sf.operand) orelse continue;
                    const container = Type.ptrInfo(ip, ir.typeOf(sf.operand, ip)).child;
                    try s.derive(gpa, i, switch (ip.keyTag(container)) {
                        .struct_type, .union_type, .tuple_type => p.plus(Type.fieldOffset(ip, container, sf.index)),
                        else => p.plus(null),
                    });
                },
                .ptr_elem_ptr, .ptr_add => {
                    const bin = ir.extraData(Ir.Bin, data.ty_pl.payload).data;
                    const p = s.ptrOf(bin.lhs) orelse continue;
                    const es = Type.abiSize(ip, Type.ptrInfo(ip, data.ty_pl.ty).child);
                    const idx = if (bin.rhs.toInterned()) |k| ip.intValue(u64, k) else null;
                    try s.derive(gpa, i, p.plus(if (idx) |n| std.math.mul(u64, n, es) catch null else null));
                },
                .bitcast => {
                    // A cast to another kind of value is not followed: it
                    // escapes.
                    if (ip.keyTag(data.ty_op.ty) != .ptr_type or Type.isSlice(ip, data.ty_op.ty)) continue;
                    const p = s.ptrOf(data.ty_op.operand) orelse continue;
                    try s.derive(gpa, i, p);
                },
                .load, .ptr_elem_val => {
                    const ptr = if (tags[i] == .load) data.ty_op.operand else data.bin_op.lhs;
                    var p = s.ptrOf(ptr) orelse continue;
                    if (tags[i] == .ptr_elem_val) {
                        const es = Type.abiSize(ip, ir.typeOfIndex(inst, ip));
                        const idx = if (data.bin_op.rhs.toInterned()) |k| ip.intValue(u64, k) else null;
                        p = p.plus(if (idx) |n| std.math.mul(u64, n, es) catch null else null);
                    }
                    const a = s.allocs.items[p.cand];
                    const info = Type.ptrInfo(ip, ir.typeOf(ptr, ip));
                    var budget: u32 = 256;
                    const mask = if (p.off == FillPtr.unknown or info.packed_offset.host_size != 0 or info.flags.vector_index != 0)
                        a.all()
                    else
                        a.typeMask(ip, ir.typeOfIndex(inst, ip), p.off, false, &budget);
                    try s.add(gpa, p, .read, mask, inst);
                },
                .store => {
                    const bin = data.bin_op;
                    const p = s.ptrOf(bin.lhs) orelse continue;
                    const a = s.allocs.items[p.cand];
                    const info = Type.ptrInfo(ip, ir.typeOf(bin.lhs, ip));
                    // A bit pointer's store reads the rest of its host.
                    if (info.packed_offset.host_size != 0 or info.flags.vector_index != 0) {
                        try s.add(gpa, p, .read, a.all(), inst);
                        continue;
                    }
                    if (p.off == FillPtr.unknown) continue;
                    const ty = ir.typeOf(bin.rhs, ip);
                    const undef = if (bin.rhs.toInterned()) |v| ip.keyTag(v) == .undef else false;
                    const size = Type.abiSize(ip, ty);
                    if (undef and !info.flags.is_volatile and size != 0) {
                        try s.events.append(gpa, .{ .mask = a.touch(p.off, p.off + size), .cover = a.cover(p.off, p.off + size), .inst = i, .cand = p.cand, .kind = .fill });
                    } else {
                        var budget: u32 = 256;
                        try s.add(gpa, p, .write, a.typeMask(ip, ty, p.off, true, &budget), inst);
                    }
                },
                .vector_store_elem => {
                    const bin = ir.extraData(Ir.Bin, data.pl_op.payload).data;
                    const p = s.ptrOf(data.pl_op.operand) orelse continue;
                    // Bools are bits; another element's store leaves the
                    // other elements as they were.
                    const ety = ir.typeOf(bin.rhs, ip);
                    if (ety == .bool_type or p.off == FillPtr.unknown) continue;
                    const es = Type.abiSize(ip, ety);
                    const idx = ip.intValue(u64, bin.lhs.toInterned() orelse continue) orelse continue;
                    const q = p.plus(std.math.mul(u64, idx, es) catch continue);
                    if (q.off == FillPtr.unknown) continue;
                    var budget: u32 = 256;
                    try s.add(gpa, q, .write, s.allocs.items[p.cand].typeMask(ip, ety, q.off, true, &budget), inst);
                },
                else => {},
            }
        }
        s.spans.items[@backingInt(block)] = .{ first, @intCast(s.events.items.len) };
    }
    // Any use of a pointer not followed above (a call's argument, a
    // stored value, a terminator's operand) lets its alloc escape.
    for (s.family.items, s.seen.items) |i, k| {
        if (k != uses[i]) s.allocs.items[s.ptrs.items[i].cand].escaped = true;
    }
    // The dataflow runs for the candidates left with a fill, numbered
    // from 0.
    var remap: [max_fill_allocs]u8 = @splat(0xff);
    var n: u8 = 0;
    for (s.events.items) |e| {
        if (e.kind == .fill and !s.allocs.items[e.cand].escaped and remap[e.cand] == 0xff) {
            remap[e.cand] = n;
            n += 1;
        }
    }
    if (n == 0) return;

    try s.ok.resize(gpa, f.blocks.items.len * n);
    @memset(s.ok.items, ~@as(u64, 0));
    var sweeps: u32 = 0;
    while (true) : (sweeps += 1) {
        if (sweeps == max_fill_sweeps) return;
        var changed = false;
        var li = f.layout.items.len;
        while (li > 0) {
            li -= 1;
            const block = @backingInt(f.layout.items[li]);
            var cur: [max_fill_allocs]u64 = undefined;
            f.fillsOut(ir, block, n, &cur);
            const span = s.spans.items[block];
            var k = span[1];
            while (k > span[0]) {
                k -= 1;
                const e = s.events.items[k];
                const c = remap[e.cand];
                if (c == 0xff) continue;
                if (e.kind == .read) cur[c] &= ~e.mask else cur[c] |= e.cover;
            }
            for (s.ok.items[block * n ..][0..n], cur[0..n]) |*in, c| {
                if (in.* != c) changed = true;
                in.* = c;
            }
        }
        if (!changed) break;
    }

    const live = f.live.slice();
    const fate = live.items(.fate);
    const reg = live.items(.reg);
    for (f.layout.items) |blk| {
        const block = @backingInt(blk);
        var cur: [max_fill_allocs]u64 = undefined;
        f.fillsOut(ir, block, n, &cur);
        const span = s.spans.items[block];
        var k = span[1];
        while (k > span[0]) {
            k -= 1;
            const e = s.events.items[k];
            const c = remap[e.cand];
            if (c == 0xff) continue;
            switch (e.kind) {
                .read => cur[c] &= ~e.mask,
                .write => cur[c] |= e.cover,
                .fill => {
                    if (e.mask & ~cur[c] == 0) {
                        fate[e.inst] = .dead;
                        reg[e.inst] = no_reg;
                        if (datas[e.inst].bin_op.lhs.toIndex()) |p| uses[@backingInt(p)] -= 1;
                    }
                    cur[c] |= e.cover;
                },
            }
        }
    }
}

/// The chunks every path from the end of `block` writes before reading
/// them, per candidate: what holds at the start of all its successors,
/// everything at an end of the function.
fn fillsOut(f: *const Ssa, ir: *const Ir, block: u32, n: usize, out: *[max_fill_allocs]u64) void {
    const ok = f.fills.ok.items;
    for (out[0..n]) |*o| o.* = ~@as(u64, 0);
    const term = f.blocks.items[block].term;
    const meet = struct {
        fn call(o: *[max_fill_allocs]u64, in: []const u64) void {
            for (o[0..in.len], in) |*x, y| x.* &= y;
        }
    }.call;
    switch (term.tag) {
        .jump, .fallthrough => meet(out, ok[term.succ[0] * n ..][0..n]),
        .branch => for (term.succ) |succ| meet(out, ok[succ * n ..][0..n]),
        .switch_br => {
            const cases = ir.extraData(Ir.SwitchBr, ir.instructions.items(.data)[@backingInt(term.inst)].pl_op.payload).data.cases_len;
            for (f.switchCases(term, cases)) |c| meet(out, ok[@backingInt(c) * n ..][0..n]);
            meet(out, ok[term.succ[1] * n ..][0..n]);
        },
        .ret, .unreach, .noreturn => {},
    }
}

/// Whether value `inst` may go unemitted when nothing reads it: it reads
/// no volatile memory, writes nothing but its own result, cannot trap, and
/// requests nothing from the linker that its users would not.
pub fn removable(ir: *const Ir, ip: *const InternPool, inst: Inst.Index) bool {
    const data = ir.instructions.items(.data)[@backingInt(inst)];
    return switch (ir.instructions.items(.tag)[@backingInt(inst)]) {
        .add_wrap, .sub_wrap, .mul_wrap, .bit_and, .bit_or, .xor, .shl, .shr, .not => true,
        // Sema's checks keep integer divisors non-zero and quotients in range.
        .div_trunc, .div_floor, .div_ceil, .rem, .mod => true,
        .add_with_overflow, .sub_with_overflow, .mul_with_overflow => true,
        .add_float, .sub_float, .mul_float, .div_float, .min_float, .max_float, .neg_float, .abs_float, .min_int, .max_int => true,
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => true,
        .intcast, .trunc, .float_cast, .bitcast, .clz, .ctz, .popcount, .byte_swap, .bit_reverse => true,
        .int_from_bool, .int_from_ptr, .ptr_from_int, .ret_addr, .frame_addr, .save_err_return_trace_index => true,
        .struct_field_ptr, .struct_field_val, .ptr_elem_ptr, .slice_elem_ptr, .ptr_add, .slice_ptr, .slice_len, .slice => true,
        .is_null, .is_non_null, .is_err, .is_non_err, .cmp_lt_errors_len, .optional_payload, .wrap_optional => true,
        .unwrap_errunion_payload, .unwrap_errunion_err, .wrap_errunion_payload, .wrap_errunion_err => true,
        .aggregate_init, .union_init, .get_union_tag, .array_elem_val => true,
        .cmp_vector, .reduce, .select, .shuffle => true,
        .load => !Type.ptrInfo(ip, ir.typeOf(data.ty_op.operand, ip)).flags.is_volatile,
        else => false,
    };
}

/// For compare `cmp` of overflow bit `bit` with a constant: whether the
/// compare is true when the operation overflowed (`cmp_eq(bit, 1)`,
/// `cmp_neq(bit, 0)`) or not; null for another compare.
pub fn ovfBitCmp(ir: *const Ir, ip: *const InternPool, cmp: Inst.Index, bit: u32) ?bool {
    const tag = ir.instructions.items(.tag)[@backingInt(cmp)];
    if (tag != .cmp_eq and tag != .cmp_neq) return null;
    const bin = ir.instructions.items(.data)[@backingInt(cmp)].bin_op;
    const lhs = bin.lhs.toIndex() orelse return null;
    if (@backingInt(lhs) != bit) return null;
    const v = ip.intValue(u64, bin.rhs.toInterned() orelse return null) orelse return null;
    return (tag == .cmp_eq) == (v == 1);
}

/// The magic number for unsigned division by constant `d` of every
/// `bits`-bit value, where `d` is not a power of two and at most
/// `2^(bits - 1)` (Granlund and Montgomery, 1994): the smallest `p` from 64
/// with `m = ceil(2^p / d)` and `m * d - 2^p <= 2^(p - bits)` gives
/// `x / d = (x * m) >> p`. An `m` of 65 bits takes the add-and-halve fixup
/// `(t + ((x - t) >> 1)) >> (p - 65)`, `t = (x * (m - 2^64)) >> 64`. Both
/// backends lower division by a constant with it.
pub fn divMagic(d: u64, bits: u16) struct { m: u128, p: u8 } {
    var p: u8 = 64;
    while (true) : (p += 1) {
        const two_p = @as(u128, 1) << @intCast(p);
        const m = (two_p + d - 1) / d;
        if (m * d - two_p <= @as(u128, 1) << @intCast(p - bits)) return .{ .m = m, .p = p };
    }
}

/// Whether a block with this terminator ends the function's execution.
pub fn deadEnd(tag: Term.Tag) bool {
    return switch (tag) {
        .ret, .unreach, .noreturn => true,
        else => false,
    };
}

pub fn valuePos(i: usize) u32 {
    return @intCast(2 * i + 2);
}

const LiveWalk = struct {
    uses: []u32,
    weight: []u32,
    def: []u32,
    end: []u32,
    crosses: []bool,
    clobbers: []const [2]u32,
    loops: []const Loop,
    /// The innermost loop around the current block, and the position of
    /// the current use.
    loop: u32,
    pos: u32,
    /// In a block that does not continue: the position before its first
    /// value.
    dead_start: ?u32,

    fn use(w: *LiveWalk, ref: Inst.Ref) void {
        const inst = @backingInt(ref.toIndex() orelse return);
        w.uses[inst] += 1;
        var depth: u32 = 0;
        var q = w.loop;
        while (q != no_loop and depth < 6) : (q = w.loops[q].parent) depth += 1;
        w.weight[inst] +|= @as(u32, 1) << @intCast(3 * depth);
        if (w.dead_start) |start| {
            if (w.clobbers[w.pos][1] != w.clobbers[@max(start, w.def[inst])][1]) w.crosses[inst] = true;
        }
        // Live through the end of every loop around the use that does not
        // contain the definition.
        const d = w.def[inst];
        var end = w.pos;
        var l = w.loop;
        while (l != no_loop and w.loops[l].start > d) : (l = w.loops[l].parent) end = w.loops[l].end;
        w.end[inst] = @max(w.end[inst], end);
    }
};

/// Calls `ctx.use(ref)` for each operand of the value `inst` (not for a
/// terminator's operands, nor for the bodies a `block` or `loop` holds).
pub fn forEachOperand(ir: *const Ir, inst: Inst.Index, ctx: anytype) void {
    const Read = struct {
        ctx: @TypeOf(ctx),
        const Self = @This();
        pub inline fn use(r: Self, p: *Inst.Ref) void {
            r.ctx.use(p.*);
        }
    };
    forEachOperandPtr(ir, inst, Read{ .ctx = ctx });
}

/// As `forEachOperand`, with `ctx.use(ptr)` given where the operand is
/// stored, so that it can be replaced.
pub fn forEachOperandPtr(ir: *const Ir, inst: Inst.Index, ctx: anytype) void {
    const datas = ir.instructions.items(.data);
    const data = &datas[@backingInt(inst)];
    const extra = @constCast(ir.extra);
    const at = struct {
        fn f(x: []u32, i: usize) *Inst.Ref {
            return @ptrCast(&x[i]);
        }
    }.f;
    switch (ir.instructions.items(.tag)[@backingInt(inst)]) {
        .arg, .alloc, .dbg_stmt, .dbg_inline_begin, .dbg_inline_end, .ret_addr, .frame_addr, .extern_ptr, .extern_pcrel, .extern_tls, .tls_ptr => {},
        .err_return_trace, .save_err_return_trace_index, .breakpoint, .c_va_start, .block, .loop => {},
        .repeat, .unreach, .trap, .comptime_tick, .comptime_quota, .comptime_dep, .comptime_effect => {},
        .br => ctx.use(&data.br.operand),
        .ret, .error_name, .cmp_lt_errors_len, .int_from_bool, .int_from_ptr, .is_null, .is_non_null, .is_err, .is_non_err, .set_err_return_trace => ctx.use(&data.un_op),
        .neg_float, .sqrt, .sin, .cos, .tan, .exp, .exp2, .log, .log2, .log10, .abs_float, .floor, .ceil, .round, .trunc_float => ctx.use(&data.un_op),
        .load, .not, .intcast, .trunc, .float_cast, .float_from_int, .int_from_float, .bitcast, .clz, .ctz, .popcount, .byte_swap, .bit_reverse => ctx.use(&data.ty_op.operand),
        .ptr_from_int, .atomic_load, .slice_ptr, .slice_len, .optional_payload, .optional_payload_ptr, .optional_payload_ptr_set, .wrap_optional => ctx.use(&data.ty_op.operand),
        .unwrap_errunion_payload, .unwrap_errunion_err, .unwrap_errunion_payload_ptr, .unwrap_errunion_err_ptr, .errunion_payload_ptr_set => ctx.use(&data.ty_op.operand),
        .wrap_errunion_payload, .wrap_errunion_err, .get_union_tag, .tag_name, .c_va_arg, .c_va_copy => ctx.use(&data.ty_op.operand),
        .store, .add_wrap, .sub_wrap, .mul_wrap, .add_float, .sub_float, .mul_float, .div_float, .div_trunc, .div_floor, .div_ceil, .rem, .mod => {
            ctx.use(&data.bin_op.lhs);
            ctx.use(&data.bin_op.rhs);
        },
        .min_float, .max_float, .min_int, .max_int, .bit_and, .bit_or, .xor, .shl, .shr, .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => {
            ctx.use(&data.bin_op.lhs);
            ctx.use(&data.bin_op.rhs);
        },
        .atomic_store, .ptr_elem_val, .slice_elem_val, .array_elem_val, .set_union_tag, .memcpy, .memmove, .memset => {
            ctx.use(&data.bin_op.lhs);
            ctx.use(&data.bin_op.rhs);
        },
        .add_with_overflow, .sub_with_overflow, .mul_with_overflow, .ptr_elem_ptr, .slice_elem_ptr, .slice, .ptr_add => {
            ctx.use(at(extra, data.ty_pl.payload));
            ctx.use(at(extra, data.ty_pl.payload + 1));
        },
        .mul_add, .vector_store_elem => {
            ctx.use(&data.pl_op.operand);
            ctx.use(at(extra, data.pl_op.payload));
            ctx.use(at(extra, data.pl_op.payload + 1));
        },
        .cond_br, .switch_br, .comptime_exit => ctx.use(&data.pl_op.operand),
        .struct_field_ptr, .struct_field_val, .union_init => ctx.use(at(extra, data.ty_pl.payload)),
        .atomic_rmw => {
            ctx.use(at(extra, data.ty_pl.payload));
            ctx.use(at(extra, data.ty_pl.payload + 1));
        },
        .cmpxchg, .select => for (0..3) |k| ctx.use(at(extra, data.ty_pl.payload + k)),
        .cmp_vector, .shuffle => {
            ctx.use(at(extra, data.ty_pl.payload));
            ctx.use(at(extra, data.ty_pl.payload + 1));
        },
        .reduce => ctx.use(at(extra, data.ty_pl.payload)),
        .aggregate_init => {
            const x = ir.extraData(Ir.Aggregate, data.ty_pl.payload);
            for (0..x.data.len) |k| ctx.use(at(extra, x.end + k));
        },
        .call => {
            const x = ir.extraData(Ir.Call, data.pl_op.payload);
            ctx.use(&data.pl_op.operand);
            for (0..x.data.args_len) |k| ctx.use(at(extra, x.end + k));
        },
        .assembly => {
            const x = ir.extraData(Ir.Asm, data.ty_pl.payload);
            var i = x.end;
            for (0..x.data.outputs_len + x.data.inputs_len) |_| {
                if (@as(Inst.Ref, @fromBackingInt(ir.extra[i + 2])) != .none) ctx.use(at(extra, i + 2));
                i += 3;
            }
        },
    }
}

/// Linear-scan register allocation (Poletto and Sarkar) over the values
/// `liveness` gave intervals and the architecture marked `want_reg` or
/// `want_pair`, with `n` general-purpose registers (indices 0 to n - 1),
/// and `want_float` and `want_vec`, with `n_float` floating-point ones
/// (the next indices, of which `want_vec` takes those outside
/// `survives`), in order of definition. Only the
/// registers in `survives` may hold a value that crosses a clobber point;
/// a value that crosses none prefers the others. When none is free, the
/// value whose interval ends last among those holding a register it could
/// use is kept in memory for its whole life. A pair gets two free
/// registers or stays in memory, and is never evicted. Values stay in
/// their registers through their last use, so a result shares a register
/// only with its tied operand or, for a load of a promoted variable, with
/// the variable (`Live.share`). A free register the value's `hint` names
/// comes before the others. A `want_fold` value takes no register when
/// the value `fold` gives for it has one, which is then never evicted, or
/// is itself folded. A crossing value in `split` may also take a register
/// outside `survives` when none in it is free, which the architecture
/// saves and restores around each clobber point it crosses. Each of
/// `restrictions` keeps a value out of its registers when one of its
/// lowerings lies in the value's interval, at its definition, or at its
/// last use. Returns the mask of registers used.
pub fn allocate(f: *Ssa, n: u8, n_float: u8, survives: u32, fold: []const u32, split: *const std.bit_set.Dynamic, restrictions: []const Restriction) u32 {
    const total = n + n_float;
    assert(total <= max_regs);
    const gprs: u32 = (@as(u32, 1) << @intCast(n)) - 1;
    const floats: u32 = ((@as(u32, 1) << @intCast(n_float)) - 1) << @intCast(n);
    const s = f.live.slice();
    const reg = s.items(.reg);
    const reg2 = s.items(.reg2);
    const def = s.items(.def);
    const end = s.items(.end);
    const tie = s.items(.tie);
    const crosses = s.items(.crosses);
    const share = s.items(.share);
    const hint = s.items(.hint);
    const weight = s.items(.weight);
    var active: [max_regs]u32 = undefined;
    // Per register: the last end of the loads sharing it with its current
    // holder (`Live.share`), which may not be evicted before then. Loads
    // that share are not in `active`; their holder outlives them.
    var held: [max_regs]u32 = @splat(0);
    // A value whose tied user crosses a clobber point prefers a register
    // that survives it, which the user can then take over. The registers
    // values not yet allocated are hinted to (arguments, all at the
    // start) are `pending`, which the others avoid while they can.
    var pending: u32 = 0;
    {
        const insts = f.values.items(.inst);
        var k = insts.len;
        while (k > 0) {
            k -= 1;
            const x = @backingInt(insts[k]);
            if (!wants(reg[x])) continue;
            pending |= regBit(hint[x][0]) | regBit(hint[x][1]);
            if (!(crosses[x] or hint[x][0] == hint_saved)) continue;
            const t = tie[x];
            if (t == no_tie or end[t] != def[x] or crosses[t] or reg[t] != reg[x] or hint[t][0] != no_reg) continue;
            hint[t][0] = hint_saved;
        }
    }
    var active_len: u8 = 0;
    var free: u32 = gprs | floats;
    var used: u32 = 0;
    for (f.values.items(.inst)) |inst_index| {
        const inst = @backingInt(inst_index);
        if (reg[inst] == want_fold) {
            const b = fold[inst];
            if (reg[b] < total) {
                // An evicted value would be in memory for its whole
                // interval, under the folded value's users too.
                held[reg[b]] = @max(held[reg[b]], end[b]);
                reg[inst] = folded;
                continue;
            }
            reg[inst] = if (reg[b] == folded) folded else want_reg;
            if (reg[inst] == folded) continue;
        }
        if (!wants(reg[inst])) continue;
        var j: u8 = 0;
        while (j < active_len) {
            const a = active[j];
            if (end[a] < def[inst]) {
                free |= @as(u32, 1) << @intCast(reg[a]);
                if (reg2[a] != no_reg) free |= @as(u32, 1) << @intCast(reg2[a]);
                active_len -= 1;
                active[j] = active[active_len];
            } else j += 1;
        }
        const h = hint[inst];
        pending &= ~(regBit(h[0]) | regBit(h[1]));
        const splits = crosses[inst] and split.isSet(inst);
        var keep_out: u32 = 0;
        for (restrictions) |r| {
            const rc = r.counts;
            if (rc[end[inst]] != rc[def[inst]] or rc[def[inst]] != rc[def[inst] - 1]) keep_out |= r.regs;
        }
        const class: u32 = switch (reg[inst]) {
            want_float => floats,
            want_vec => floats & ~survives,
            else => gprs,
        };
        const usable: u32 = class & ~keep_out & if (crosses[inst] and !splits) survives else ~@as(u32, 0);
        const v = share[inst];
        if (v != no_tie and reg[v] < total) {
            reg[inst] = reg[v];
            held[reg[v]] = @max(held[reg[v]], end[inst]);
            if (reg2[v] != no_reg) reg2[inst] = reg2[v];
            continue;
        }
        if (reg[inst] == want_pair) {
            // Two registers or none; a pair neither evicts nor is evicted.
            const avail = free & usable;
            if (@popCount(avail) < 2) {
                reg[inst] = no_reg;
                continue;
            }
            const cheap = if (@popCount(avail & ~survives) >= 2 and !crosses[inst]) avail & ~survives else avail;
            const pick = if (@popCount(cheap & ~pending) >= 2) cheap & ~pending else cheap;
            const lo: u8 = if (h[0] < max_regs and avail >> @intCast(h[0]) & 1 != 0) h[0] else @intCast(@ctz(pick & ~regBit(h[1])));
            const rest = avail & ~regBit(lo);
            const hi: u8 = if (h[1] < max_regs and rest >> @intCast(h[1]) & 1 != 0) h[1] else @intCast(@ctz(if (pick & rest != 0) pick & rest else rest));
            const bits = @as(u32, 1) << @intCast(lo) | @as(u32, 1) << @intCast(hi);
            free &= ~bits;
            used |= bits;
            reg[inst] = lo;
            reg2[inst] = hi;
            active[active_len] = inst;
            active_len += 1;
            continue;
        }
        const t = tie[inst];
        // Not a register a load shares, which its variable still holds.
        if (t != no_tie and end[t] == def[inst] and reg[t] < total and usable >> @intCast(reg[t]) & 1 != 0 and
            reg2[t] == no_reg and (share[t] == no_tie or reg[share[t]] != reg[t]))
        {
            // Take over the tied operand's register, which dies here.
            const k = std.mem.findScalar(u32, active[0..active_len], t).?;
            reg[inst] = reg[t];
            active[k] = inst;
            continue;
        }
        if (free & usable != 0) {
            const cheap = if ((h[0] == hint_saved or splits) and free & usable & survives != 0)
                free & usable & survives
            else if (free & usable & ~survives != 0 and !crosses[inst]) free & usable & ~survives else free & usable;
            const pick = if (cheap & ~pending != 0) cheap & ~pending else if (free & usable & ~pending != 0) free & usable & ~pending else cheap;
            const r: u8 = if (h[0] < max_regs and (free & usable) >> @intCast(h[0]) & 1 != 0) h[0] else @intCast(@ctz(pick));
            free &= ~(@as(u32, 1) << @intCast(r));
            used |= @as(u32, 1) << @intCast(r);
            reg[inst] = r;
            active[active_len] = inst;
            active_len += 1;
            continue;
        }
        // Out of registers: a value used a loop level less often than the
        // others goes to memory, else the one that ends last.
        var last: ?u8 = null;
        for (active[0..active_len], 0..) |a, k| {
            if (usable >> @intCast(reg[a]) & 1 == 0 or held[reg[a]] >= def[inst] or reg2[a] != no_reg or hint[a][1] == hint_pinned) continue;
            if (last == null or spillsBefore(weight, end, a, active[last.?])) last = @intCast(k);
        }
        const victim = if (last) |l| active[l] else {
            reg[inst] = no_reg;
            continue;
        };
        if (spillsBefore(weight, end, victim, inst)) {
            reg[inst] = reg[victim];
            reg[victim] = no_reg;
            active[last.?] = inst;
        } else reg[inst] = no_reg;
    }
    return used;
}

/// Whether value `a` goes to memory before value `b` when registers run
/// out: its uses weigh at most an eighth of `b`'s (a loop level less),
/// or, unless `b`'s weigh that little against `a`'s, it ends later.
fn spillsBefore(weight: []const u32, end: []const u32, a: u32, b: u32) bool {
    const wa: u64 = weight[a];
    const wb: u64 = weight[b];
    if (8 * wa <= wb) return true;
    if (8 * wb <= wa) return false;
    return end[a] > end[b];
}

pub const max_regs = 32;

/// Registers that some lowerings write (r11 as x86_64's scratch, the
/// registers inline assembly names or takes for its operands), and per
/// position (as `clobbers`) how many of those lowerings come at or before
/// it.
pub const Restriction = struct { regs: u32, counts: []const u32 };

/// The mask of register `r`, or 0 for `no_reg`.
fn regBit(r: u8) u32 {
    return if (r < max_regs) @as(u32, 1) << @intCast(r) else 0;
}

/// Frame slots shared by lifetime (pass 7): a value's slot is free for
/// another value once the position passes the end of its interval. Slots
/// are classed by size, rounded up to 8 bytes (16 for 16-byte aligned
/// values), up to `max_slot` bytes; larger values get their own.
pub const Slots = struct {
    free: [2 * max_slot / 8]std.ArrayList(i32) = @splat(.empty),
    /// Slots in use, a min-heap by `end`.
    active: std.ArrayList(Active) = .empty,

    const Active = struct { end: u32, off: i32, class: u16 };
};

pub const max_slot = 512;

/// A slot's class and its size and alignment, or null if it is not shared.
pub const SlotClass = struct { index: u16, size: u32, alignment: u32 };

pub fn slotClass(size: u64, alignment: u64) ?SlotClass {
    const a: u32 = if (alignment > 8) 16 else 8;
    const rounded = std.mem.alignForward(u64, @max(size, 1), a);
    if (rounded > max_slot) return null;
    return .{ .index = @intCast((rounded / 8 - 1) * 2 + @intFromBool(a == 16)), .size = @intCast(rounded), .alignment = a };
}

/// A free slot of `class` for value `inst`, reusing one whose value's
/// interval ended before `inst`'s definition, or null if there is none
/// (the caller then allocates one and records it with `holdSlot`).
pub fn takeSlot(f: *Ssa, gpa: Allocator, inst: Inst.Index, class: SlotClass) Allocator.Error!?i32 {
    const pos = f.live.items(.def)[@backingInt(inst)];
    const s = &f.slots;
    while (s.active.items.len != 0 and s.active.items[0].end < pos) {
        const top = s.active.items[0];
        try s.free[top.class].append(gpa, top.off);
        const last = s.active.pop().?;
        if (s.active.items.len == 0) break;
        // Sift `last` down from the root.
        const h = s.active.items;
        var i: usize = 0;
        while (true) {
            var c = 2 * i + 1;
            if (c >= h.len) break;
            if (c + 1 < h.len and h[c + 1].end < h[c].end) c += 1;
            if (h[c].end >= last.end) break;
            h[i] = h[c];
            i = c;
        }
        h[i] = last;
    }
    return s.free[class.index].pop();
}

/// Records that value `inst` holds the slot at `off` until its interval
/// ends.
pub fn holdSlot(f: *Ssa, gpa: Allocator, inst: Inst.Index, off: i32, class: SlotClass) Allocator.Error!void {
    const s = &f.slots;
    const end = f.live.items(.end)[@backingInt(inst)];
    try s.active.append(gpa, undefined);
    const h = s.active.items;
    var i = h.len - 1;
    while (i > 0) {
        const parent = (i - 1) / 2;
        if (h[parent].end <= end) break;
        h[i] = h[parent];
        i = parent;
    }
    h[i] = .{ .end = end, .off = off, .class = class.index };
}

const Builder = struct {
    f: *Ssa,
    gpa: Allocator,
    ir: *const Ir,
    /// The block being filled, if any: after a terminator, the next value
    /// starts a new block (code no branch reaches, which is still emitted).
    cur: Block.Index = .none,
    /// The last IR instruction seen.
    last: Inst.Index = undefined,
    /// The innermost loop being built.
    loop: u32 = no_loop,

    fn newBlock(b: *Builder) Allocator.Error!Block.Index {
        try b.f.blocks.append(b.gpa, .{ .start = 0, .len = 0, .term = undefined });
        try b.f.block_loop.append(b.gpa, b.loop);
        return @fromBackingInt(@intCast(b.f.blocks.items.len - 1));
    }

    /// Starts filling `block`, which comes next in the layout. A block
    /// still open (after an empty body) falls through into it.
    fn open(b: *Builder, block: Block.Index) Allocator.Error!void {
        if (b.cur != .none) try b.terminate(.{ .tag = .fallthrough, .inst = b.last, .succ = .{ @backingInt(block), 0 } });
        b.f.blocks.items[@backingInt(block)].start = @intCast(b.f.values.len);
        try b.f.layout.append(b.gpa, block);
        b.cur = block;
    }

    fn value(b: *Builder, inst: Inst.Index) Allocator.Error!void {
        if (b.cur == .none) try b.open(try b.newBlock());
        b.f.values.appendAssumeCapacity(.{ .op = .fallback, .inst = inst });
    }

    fn terminate(b: *Builder, term: Term) Allocator.Error!void {
        if (b.cur == .none) try b.open(try b.newBlock());
        const block = &b.f.blocks.items[@backingInt(b.cur)];
        block.len = @intCast(b.f.values.len - block.start);
        block.term = term;
        b.cur = .none;
    }

    /// A body that is not empty ends with an instruction that does not
    /// return; if that one is a value, it ends its block. An empty body
    /// leaves its block open, to fall through into the next one.
    fn body(b: *Builder, insts: []const Inst.Index) Allocator.Error!void {
        for (insts) |inst| try b.instruction(inst);
        if (insts.len != 0 and b.cur != .none) try b.terminate(.{ .tag = .noreturn, .inst = insts[insts.len - 1] });
    }

    fn instruction(b: *Builder, inst: Inst.Index) Allocator.Error!void {
        b.last = inst;
        const ir = b.ir;
        const data = ir.instructions.items(.data)[@backingInt(inst)];
        switch (ir.instructions.items(.tag)[@backingInt(inst)]) {
            .block => {
                // The value holds the block's result, which each `br` writes.
                try b.value(inst);
                const extra = ir.extraData(Ir.Block, data.ty_pl.payload);
                const exit = try b.newBlock();
                b.f.targets.items[@backingInt(inst)] = exit;
                try b.body(ir.bodySlice(extra.end, extra.data.body_len));
                try b.open(exit);
            },
            .loop => {
                try b.value(inst);
                const extra = ir.extraData(Ir.Block, data.ty_pl.payload);
                const loop: u32 = @intCast(b.f.loops.items.len);
                try b.f.loops.append(b.gpa, .{ .start = undefined, .end = undefined, .parent = b.loop });
                b.loop = loop;
                const header = try b.newBlock();
                b.f.targets.items[@backingInt(inst)] = header;
                // Falls through into the header.
                try b.open(header);
                b.f.loops.items[loop].start = 2 * @as(u32, @intCast(b.f.values.len)) + 2;
                try b.body(ir.bodySlice(extra.end, extra.data.body_len));
                b.f.loops.items[loop].end = 2 * @as(u32, @intCast(b.f.values.len)) + 1;
                b.loop = b.f.loops.items[loop].parent;
            },
            .br => try b.terminate(.{ .tag = .jump, .inst = inst, .succ = .{ @backingInt(b.f.targets.items[@backingInt(data.br.block_inst)]), 0 } }),
            .repeat => try b.terminate(.{ .tag = .jump, .inst = inst, .succ = .{ @backingInt(b.f.targets.items[@backingInt(data.repeat.loop_inst)]), 0 } }),
            .cond_br => {
                const extra = ir.extraData(Ir.CondBr, data.pl_op.payload);
                const then_body = ir.bodySlice(extra.end, extra.data.then_body_len);
                const else_body = ir.bodySlice(extra.end + then_body.len, extra.data.else_body_len);
                // A condition the rewrite rules made constant: only the
                // taken body has code, in a block of its own (cold if it
                // panics).
                if (data.pl_op.operand.toInterned()) |c| if (c == .bool_true or c == .bool_false) {
                    try b.open(try b.newBlock());
                    return b.body(if (c == .bool_true) then_body else else_body);
                };
                const then_block = try b.newBlock();
                const else_block = try b.newBlock();
                try b.terminate(.{ .tag = .branch, .inst = inst, .succ = .{ @backingInt(then_block), @backingInt(else_block) } });
                try b.open(then_block);
                try b.body(then_body);
                try b.open(else_block);
                try b.body(else_body);
            },
            .switch_br => {
                const extra = ir.extraData(Ir.SwitchBr, data.pl_op.payload);
                const cases_start: u32 = @intCast(b.f.extra.items.len);
                for (0..extra.data.cases_len) |_| try b.f.extra.append(b.gpa, try b.newBlock());
                const else_block = try b.newBlock();
                try b.terminate(.{ .tag = .switch_br, .inst = inst, .succ = .{ cases_start, @backingInt(else_block) } });
                // The else body comes first in the layout, then the cases
                // in IR order.
                var it = ir.switchCases(data.pl_op.payload);
                while (it.next()) |_| {}
                try b.open(else_block);
                try b.body(it.elseBody());
                it = ir.switchCases(data.pl_op.payload);
                var c: u32 = 0;
                while (it.next()) |case| : (c += 1) {
                    try b.open(b.f.extra.items[cases_start + c]);
                    try b.body(case.body);
                }
            },
            .ret => try b.terminate(.{ .tag = .ret, .inst = inst }),
            .unreach, .trap => try b.terminate(.{ .tag = .unreach, .inst = inst }),
            else => try b.value(inst),
        }
    }
};

test "blocks follow the structured IR's layout" {
    // fn f(c: bool) void { block { loop { cond_br(c, { br block }, { repeat }) } } ret }
    const gpa = std.testing.allocator;
    var insts: std.MultiArrayList(Inst) = .empty;
    defer insts.deinit(gpa);
    // Instructions: 0 arg, 1 block, 2 loop, 3 cond_br, 4 br, 5 repeat, 6 ret.
    const extra = [_]u32{
        1, 1, 0, 4, 5, // 0: cond_br: then { br }, else { repeat }
        1, 3, // 5: loop body { cond_br }
        1, 2, // 7: block body { loop }
        3, 0, 1, 6, // 9: main body { arg, block, ret }
    };
    const c = Inst.Index.toRef(@fromBackingInt(0));
    try insts.append(gpa, .{ .tag = .arg, .data = .{ .arg = .{ .ty = .bool_type, .index = 0 } } });
    try insts.append(gpa, .{ .tag = .block, .data = .{ .ty_pl = .{ .ty = .void_type, .payload = 7 } } });
    try insts.append(gpa, .{ .tag = .loop, .data = .{ .ty_pl = .{ .ty = .noreturn_type, .payload = 5 } } });
    try insts.append(gpa, .{ .tag = .cond_br, .data = .{ .pl_op = .{ .operand = c, .payload = 0 } } });
    try insts.append(gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = @fromBackingInt(1), .operand = .void_value } } });
    try insts.append(gpa, .{ .tag = .repeat, .data = .{ .repeat = .{ .loop_inst = @fromBackingInt(2) } } });
    try insts.append(gpa, .{ .tag = .ret, .data = .{ .un_op = .void_value } });
    const ir: Ir = .{ .instructions = insts.slice(), .extra = &extra, .func = .none, .main_block = 9 };
    var f: Ssa = .{};
    defer f.deinit(gpa);
    try f.build(gpa, &ir);

    // entry [arg, block, loop] -fallthrough-> header [] -branch-> then
    // [] -jump-> exit, else [] -jump-> header; exit [] ret.
    const L = f.layout.items;
    try std.testing.expectEqual(5, L.len);
    const term = struct {
        fn of(fp: *const Ssa, blk: Block.Index) Term {
            return fp.blocks.items[@backingInt(blk)].term;
        }
    }.of;
    try std.testing.expectEqualSlices(Inst.Index, &.{ @fromBackingInt(0), @fromBackingInt(1), @fromBackingInt(2) }, f.blockInsts(L[0]));
    try std.testing.expectEqual(Term.Tag.fallthrough, term(&f, L[0]).tag);
    try std.testing.expectEqual(@backingInt(L[1]), term(&f, L[0]).succ[0]);
    try std.testing.expectEqual(Term.Tag.branch, term(&f, L[1]).tag);
    try std.testing.expectEqual([2]u32{ @backingInt(L[2]), @backingInt(L[3]) }, term(&f, L[1]).succ);
    // then: br to the block's exit; else: repeat to the loop header.
    try std.testing.expectEqual(@backingInt(L[4]), term(&f, L[2]).succ[0]);
    try std.testing.expectEqual(@backingInt(L[1]), term(&f, L[3]).succ[0]);
    try std.testing.expectEqual(Term.Tag.ret, term(&f, L[4]).tag);
}

test "an empty body falls through" {
    // Sema leaves `block(void, {})` for a comptime block in a runtime body.
    const gpa = std.testing.allocator;
    var insts: std.MultiArrayList(Inst) = .empty;
    defer insts.deinit(gpa);
    const extra = [_]u32{
        0, // 0: block body {}
        2, 0, 1, // 1: main body { block, ret }
    };
    try insts.append(gpa, .{ .tag = .block, .data = .{ .ty_pl = .{ .ty = .void_type, .payload = 0 } } });
    try insts.append(gpa, .{ .tag = .ret, .data = .{ .un_op = .void_value } });
    const ir: Ir = .{ .instructions = insts.slice(), .extra = &extra, .func = .none, .main_block = 1 };
    var f: Ssa = .{};
    defer f.deinit(gpa);
    try f.build(gpa, &ir);

    const L = f.layout.items;
    try std.testing.expectEqual(2, L.len);
    const entry = f.blocks.items[@backingInt(L[0])];
    try std.testing.expectEqualSlices(Inst.Index, &.{@fromBackingInt(0)}, f.blockInsts(L[0]));
    try std.testing.expectEqual(Term.Tag.fallthrough, entry.term.tag);
    try std.testing.expectEqual(@backingInt(L[1]), entry.term.succ[0]);
    try std.testing.expectEqual(Term.Tag.ret, f.blocks.items[@backingInt(L[1])].term.tag);
}

test "liveness extends over loops and ignores clobbers on paths that end" {
    // fn f(c: bool, x: u64) void {
    //     block { loop { cond_br(c, { not(x); br block }, { breakpoint; trap }) } }
    //     ret
    // }
    const gpa = std.testing.allocator;
    var insts: std.MultiArrayList(Inst) = .empty;
    defer insts.deinit(gpa);
    const extra = [_]u32{
        2, 2, 0, 5, 6, 7, 8, // 0: cond_br: then { not, br }, else { breakpoint, trap }
        1, 4, // 7: loop body { cond_br }
        1, 3, // 9: block body { loop }
        4, 0, 1, 2, 9, // 11: main body { arg, arg, block, ret }
    };
    const ref = Inst.Index.toRef;
    try insts.append(gpa, .{ .tag = .arg, .data = .{ .arg = .{ .ty = .bool_type, .index = 0 } } });
    try insts.append(gpa, .{ .tag = .arg, .data = .{ .arg = .{ .ty = .u64_type, .index = 1 } } });
    try insts.append(gpa, .{ .tag = .block, .data = .{ .ty_pl = .{ .ty = .void_type, .payload = 9 } } });
    try insts.append(gpa, .{ .tag = .loop, .data = .{ .ty_pl = .{ .ty = .noreturn_type, .payload = 7 } } });
    try insts.append(gpa, .{ .tag = .cond_br, .data = .{ .pl_op = .{ .operand = ref(@fromBackingInt(0)), .payload = 0 } } });
    try insts.append(gpa, .{ .tag = .not, .data = .{ .ty_op = .{ .ty = .u64_type, .operand = ref(@fromBackingInt(1)) } } });
    try insts.append(gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = @fromBackingInt(2), .operand = .void_value } } });
    try insts.append(gpa, .{ .tag = .breakpoint, .data = .{ .no_op = {} } });
    try insts.append(gpa, .{ .tag = .trap, .data = .{ .no_op = {} } });
    try insts.append(gpa, .{ .tag = .ret, .data = .{ .un_op = .void_value } });
    const ir: Ir = .{ .instructions = insts.slice(), .extra = &extra, .func = .none, .main_block = 11 };
    var f: Ssa = .{};
    defer f.deinit(gpa);
    try f.build(gpa, &ir);
    try f.live.resize(gpa, ir.instructions.len);

    // Clobber points: the breakpoint, which is on the path that traps,
    // and optionally the `not` in the loop.
    const Ctx = struct {
        not_clobbers: bool,
        const Self = @This();
        pub fn clobbers(c: Self, inst: Inst.Index) bool {
            return switch (@backingInt(inst)) {
                7 => true,
                5 => c.not_clobbers,
                else => false,
            };
        }
        pub fn termClobbers(_: Self, _: Block.Index) bool {
            return false;
        }
    };
    try f.liveness(gpa, &ir, Ctx{ .not_clobbers = false });
    const x = 1;
    // x is defined before the loop and read in it: live through the loop's
    // last terminator, not just to its read.
    try std.testing.expectEqual(f.loops.items[0].end, f.live.items(.end)[x]);
    try std.testing.expect(f.live.items(.end)[x] > f.live.items(.def)[5]);
    try std.testing.expect(!f.live.items(.crosses)[x]);
    try f.liveness(gpa, &ir, Ctx{ .not_clobbers = true });
    try std.testing.expect(f.live.items(.crosses)[x]);
}
