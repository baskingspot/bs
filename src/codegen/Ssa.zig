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
//! A `Func` is reused for every function a worker compiles: `build` clears
//! it and keeps its capacity, so building allocates only while it grows.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Ir = @import("../Ir.zig");
const Inst = Ir.Inst;
const InternPool = @import("../InternPool.zig");
const Type = @import("../Type.zig");

const Func = @This();

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
/// The function contains inline assembly, so no value gets a register
/// (its constraints do not come from the allocator yet).
has_asm: bool = false,

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
    /// store to the variable lies in it.
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
/// For an address its users may read as an offset from another value
/// (`allocate`'s `fold`): no register if that value has one or is itself
/// folded, else like `want_reg`. Not one of the `want` markers.
pub const want_fold: u8 = 0xfb;
/// What `allocate` leaves for a `want_fold` value that took no register.
pub const folded: u8 = 0xfa;

/// Whether `r` is one of the `want` markers.
pub fn wants(r: u8) bool {
    return r >= want_float and r != no_reg;
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
    /// the condition is true (which follows in the layout) and the one
    /// taken when it is false. `switch_br`: the start in `extra` of the
    /// case blocks, and the else block (which follows in the layout).
    succ: [2]u32 = .{ 0, 0 },

    pub const Tag = enum(u8) {
        /// `br` (which also writes the target block's result) or `repeat`.
        jump,
        /// Continues into the next block in the layout without code: the
        /// entry of a loop, or the end of an empty body.
        fallthrough,
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

pub fn deinit(f: *Func, gpa: Allocator) void {
    f.values.deinit(gpa);
    f.blocks.deinit(gpa);
    f.layout.deinit(gpa);
    f.order.deinit(gpa);
    f.cold.deinit(gpa);
    f.fwd.deinit(gpa);
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
}

pub fn blockInsts(f: *const Func, block: Block.Index) []const Inst.Index {
    const b = f.blocks.items[@backingInt(block)];
    return f.values.items(.inst)[b.start..][0..b.len];
}

pub fn switchCases(f: *const Func, term: Term, len: usize) []const Block.Index {
    return f.extra.items[term.succ[0]..][0..len];
}

/// Builds `f` from `ir`, replacing what it held.
pub fn build(f: *Func, gpa: Allocator, ir: *const Ir) Allocator.Error!void {
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
    const tags = ir.instructions.items(.tag);
    f.has_asm = for (f.values.items(.inst)) |inst| {
        if (tags[@backingInt(inst)] == .assembly) break true;
    } else false;
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
pub fn place(f: *Func, gpa: Allocator, ir: *const Ir, cover: bool) Allocator.Error!void {
    const n = f.blocks.items.len;
    f.order.clearRetainingCapacity();
    try f.order.ensureTotalCapacity(gpa, f.layout.items.len);
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
        if (i != 0 and f.fwd.items[@backingInt(block)] != block) continue;
        const cold = i != 0 and f.endsCold(ir, @backingInt(block));
        f.cold.items[@backingInt(block)] = cold;
        if (!cold) f.order.appendAssumeCapacity(block);
    }
    f.cold_start = @intCast(f.order.items.len);
    for (f.layout.items) |block| {
        if (f.cold.items[@backingInt(block)]) f.order.appendAssumeCapacity(block);
    }
}

/// Whether block `index` ends with a call of a noreturn function (a
/// failing check's panic, `@panic`).
fn endsCold(f: *const Func, ir: *const Ir, index: u32) bool {
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
pub fn liveness(f: *Func, gpa: Allocator, ir: *const Ir, ctx: anytype) Allocator.Error!void {
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
        const cond: ?Inst.Index = if (b.term.tag == .branch) term_data.pl_op.operand.toIndex() else null;
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
            .jump => if (tags[@backingInt(b.term.inst)] == .br) {
                w.use(term_data.br.operand);
                // The `br` writes the block's result.
                const blk = @backingInt(term_data.br.block_inst);
                w.end[blk] = @max(w.end[blk], term_pos);
            },
            .branch, .switch_br => w.use(term_data.pl_op.operand),
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
///   register (`ctx.inGpr`), two (`ctx.inPair`), or a floating-point one
///   (`ctx.inFloat`) and whose address is only loaded from and stored to,
///   so it is never taken, gets `want_reg` (`want_pair`, `want_float`), and its loads and
///   stores are moves. This is mem2reg without renaming: the variable
///   keeps one register for its interval, which `liveness` extends over
///   the loops that use it, so it needs no phis. A load may share the
///   variable's register (`Live.share`).
/// With inline assembly only pass 2 runs. `ctx.inGpr(ty)` says whether
/// an overflow operation on `ty` runs in general-purpose registers.
pub fn plan(f: *Func, gpa: Allocator, ir: *const Ir, ip: *const InternPool, ctx: anytype) Allocator.Error!void {
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
    {
        const Uses = struct {
            uses: []u32,
            pub fn use(c: @This(), ref: Inst.Ref) void {
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
    if (f.has_asm) return;
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
        const cond: ?Inst.Index = if (b.term.tag == .branch) datas[@backingInt(b.term.inst)].pl_op.operand.toIndex() else null;
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
                    const class: u32 = if (ctx.inGpr(info.child)) 0 else if (ctx.inPair(info.child)) 1 else if (ctx.inFloat(info.child)) 2 else if (info.flags.is_const) 3 else continue;
                    count[i] = candidate;
                    if (!info.flags.is_const) fwd[i] = no_fwd;
                    try f.candidates.append(gpa, i | class << 30);
                },
                .load => if (fate[i] != .dead) {
                    const v = @backingInt(datas[i].ty_op.operand.toIndex() orelse continue);
                    if (count[v] == no_tie) continue;
                    count[v] -%= 1;
                    try f.var_loads.append(gpa, i);
                    try f.var_load_loops.append(gpa, f.block_loop.items[@backingInt(block)]);
                },
                .store => {
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
        const v = c & ~(@as(u32, 3) << 30);
        if (candidate - count[v] == uses[v]) {
            if (fwd[v] < no_fwd) {
                fate[v] = .dead;
                fate[fwd[v]] = .dead;
                reg[v] = no_reg;
            } else if (c >> 30 != 3) {
                reg[v] = switch (c >> 30) {
                    0 => want_reg,
                    1 => want_pair,
                    else => want_float,
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
        if (reg[@backingInt(v)] == reg[l] and wants(reg[l])) share[l] = f.shareable(ir, @fromBackingInt(l), v);
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
            if (reg[v] != reg[w] or (reg[w] != want_reg and reg[w] != want_float)) break :br;
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
            if (tags[v] != .alloc or reg[v] != reg[w] or (reg[w] != want_reg and reg[w] != want_float)) continue;
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
    for (f.candidates.items) |c| fwd[c & ~(@as(u32, 3) << 30)] = no_tie;
}

/// `v` if load `load` of promoted variable `v` may share its register
/// (`Live.share`), else `no_tie`. A store of the load itself writes back
/// what the register holds.
fn shareable(f: *const Func, ir: *const Ir, load: Inst.Index, v: Inst.Index) u32 {
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
fn shareTies(f: *Func, ir: *const Ir, w: Inst.Index, v: Inst.Index, start: u32) void {
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
fn storeShares(f: *const Func, ir: *const Ir, w: Inst.Index, v: Inst.Index, store: usize) bool {
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
fn termReadsShared(f: *const Func, ir: *const Ir, term: Term, v: Inst.Index) bool {
    const data = ir.instructions.items(.data)[@backingInt(term.inst)];
    var c: SharedReads = .{ .f = f, .ir = ir, .v = v, .tie = no_tie };
    switch (term.tag) {
        .jump => if (ir.instructions.items(.tag)[@backingInt(term.inst)] == .br) c.use(data.br.operand),
        .branch, .switch_br => c.use(data.pl_op.operand),
        .ret => c.use(data.un_op),
        .fallthrough, .noreturn, .unreach => {},
    }
    return c.other;
}

/// For `forEachOperand`: finds operands that are loads sharing promoted
/// variable `v`'s register, other than `tie`.
const SharedReads = struct {
    f: *const Func,
    ir: *const Ir,
    v: Inst.Index,
    tie: u32,
    other: bool = false,

    fn use(c: *SharedReads, ref: Inst.Ref) void {
        const l = @backingInt(ref.toIndex() orelse return);
        if (c.f.live.items(.share)[l] != @backingInt(c.v)) return;
        if (l != c.tie) c.other = true;
    }
};

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
        .is_null, .is_non_null, .is_err, .is_non_err, .optional_payload, .wrap_optional => true,
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
        pub inline fn use(r: @This(), p: *Inst.Ref) void {
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
        .ret, .error_name, .int_from_bool, .int_from_ptr, .is_null, .is_non_null, .is_err, .is_non_err, .set_err_return_trace => ctx.use(&data.un_op),
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
/// and `want_float`, with `n_float` floating-point ones (the next
/// indices), in order of definition. Only the
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
/// saves and restores around each clobber point it crosses. Returns the
/// mask of registers used.
pub fn allocate(f: *Func, n: u8, n_float: u8, survives: u32, fold: []const u32, split: *const std.DynamicBitSetUnmanaged) u32 {
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
        const usable: u32 = (if (reg[inst] == want_float) floats else gprs) & if (crosses[inst] and !splits) survives else ~@as(u32, 0);
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
            const k = std.mem.indexOfScalar(u32, active[0..active_len], t).?;
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
pub fn takeSlot(f: *Func, gpa: Allocator, inst: Inst.Index, class: SlotClass) Allocator.Error!?i32 {
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
pub fn holdSlot(f: *Func, gpa: Allocator, inst: Inst.Index, off: i32, class: SlotClass) Allocator.Error!void {
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
    f: *Func,
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
                var i = extra.end;
                for (0..extra.data.cases_len) |_| i += 2 + ir.extra[i] + ir.extra[i + 1];
                try b.open(else_block);
                try b.body(ir.bodySlice(i, extra.data.else_body_len));
                i = extra.end;
                for (0..extra.data.cases_len) |c| {
                    const items_len = ir.extra[i];
                    const body_len = ir.extra[i + 1];
                    try b.open(b.f.extra.items[cases_start + c]);
                    try b.body(ir.bodySlice(i + 2 + items_len, body_len));
                    i += 2 + items_len + body_len;
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
    var f: Func = .{};
    defer f.deinit(gpa);
    try f.build(gpa, &ir);

    // entry [arg, block, loop] -fallthrough-> header [] -branch-> then
    // [] -jump-> exit, else [] -jump-> header; exit [] ret.
    const L = f.layout.items;
    try std.testing.expectEqual(5, L.len);
    const term = struct {
        fn of(fp: *const Func, blk: Block.Index) Term {
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
    var f: Func = .{};
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
    var f: Func = .{};
    defer f.deinit(gpa);
    try f.build(gpa, &ir);
    try f.live.resize(gpa, ir.instructions.len);

    // Clobber points: the breakpoint, which is on the path that traps,
    // and optionally the `not` in the loop.
    const Ctx = struct {
        not_clobbers: bool,
        pub fn clobbers(c: @This(), inst: Inst.Index) bool {
            return switch (@backingInt(inst)) {
                7 => true,
                5 => c.not_clobbers,
                else => false,
            };
        }
        pub fn termClobbers(_: @This(), _: Block.Index) bool {
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
