//! The shared SSA form of one function, which every architecture's backend
//! lowers (docs/architecture.md, "Optimizing backend").
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

const Func = @This();

values: std.MultiArrayList(Value) = .empty,
blocks: std.ArrayList(Block) = .empty,
/// Blocks in the order their code is laid out.
layout: std.ArrayList(Block.Index) = .empty,
/// Switch successors: per switch, its case blocks in IR order.
extra: std.ArrayList(Block.Index) = .empty,
/// For each IR instruction that a `br` or `repeat` targets (`block`,
/// `loop`), the block those jump to; indexed by IR instruction.
targets: std.ArrayList(Block.Index) = .empty,
/// Loops, outer ones before the loops they contain, and per block the
/// innermost loop containing it (an index into `loops`, or `no_loop`).
loops: std.ArrayList(Loop) = .empty,
block_loop: std.ArrayList(u32) = .empty,

/// Liveness and register allocation, per IR instruction (values are IR
/// instructions until the SSA gets its own ops). Positions number the
/// values and terminators in layout order: value `i` is at `2 * i + 2`,
/// and the terminator of a block whose values end before value `i` at
/// `2 * i + 1`.
live: std.MultiArrayList(Live) = .empty,
/// Frame-slot sharing, filled as the architecture emits values in layout
/// order (see `takeSlot`).
slots: Slots = .{},

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
};

pub const no_tie = std.math.maxInt(u32);

pub const no_reg: u8 = 0xff;
pub const want_reg: u8 = 0xfe;

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
    f.extra.deinit(gpa);
    f.targets.deinit(gpa);
    f.loops.deinit(gpa);
    f.block_loop.deinit(gpa);
    f.live.deinit(gpa);
    for (&f.slots.free) |*l| l.deinit(gpa);
    f.slots.active.deinit(gpa);
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
}

/// Computes each value's uses and live interval (`live`). A value that is
/// the condition of its own block's `branch` is read at the terminator:
/// the architecture may fuse it into the branch, so its operands live until
/// there.
pub fn liveness(f: *Func, gpa: Allocator, ir: *const Ir) Allocator.Error!void {
    try f.live.resize(gpa, ir.instructions.len);
    const s = f.live.slice();
    @memset(s.items(.uses), 0);
    @memset(s.items(.reg), no_reg);
    for (&f.slots.free) |*l| l.clearRetainingCapacity();
    f.slots.active.clearRetainingCapacity();
    var w: LiveWalk = .{ .uses = s.items(.uses), .def = s.items(.def), .end = s.items(.end), .loops = f.loops.items, .loop = no_loop, .pos = 0 };
    const insts = f.values.items(.inst);
    const datas = ir.instructions.items(.data);
    const tags = ir.instructions.items(.tag);
    for (f.layout.items) |block| {
        const b = f.blocks.items[@backingInt(block)];
        w.loop = f.block_loop.items[@backingInt(block)];
        const term_pos = 2 * (b.start + b.len) + 1;
        const term_data = datas[@backingInt(b.term.inst)];
        const cond: ?Inst.Index = if (b.term.tag == .branch) term_data.pl_op.operand.toIndex() else null;
        for (b.start..b.start + b.len) |i| {
            const inst = insts[i];
            const p: u32 = @intCast(2 * i + 2);
            w.def[@backingInt(inst)] = p;
            w.end[@backingInt(inst)] = p;
            w.pos = if (cond != null and cond.? == inst) term_pos else p;
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
}

const LiveWalk = struct {
    uses: []u32,
    def: []u32,
    end: []u32,
    loops: []const Loop,
    /// The innermost loop around the current block, and the position of
    /// the current use.
    loop: u32,
    pos: u32,

    fn use(w: *LiveWalk, ref: Inst.Ref) void {
        const inst = @backingInt(ref.toIndex() orelse return);
        w.uses[inst] += 1;
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
    const data = ir.instructions.items(.data)[@backingInt(inst)];
    switch (ir.instructions.items(.tag)[@backingInt(inst)]) {
        .arg, .alloc, .dbg_stmt, .dbg_inline_begin, .dbg_inline_end, .ret_addr, .frame_addr, .extern_ptr, .tls_ptr => {},
        .err_return_trace, .save_err_return_trace_index, .breakpoint, .c_va_start, .block, .loop => {},
        .repeat, .unreach, .trap, .comptime_tick, .comptime_quota, .comptime_dep => {},
        .br => ctx.use(data.br.operand),
        .ret, .error_name, .int_from_bool, .int_from_ptr, .is_null, .is_non_null, .is_err, .is_non_err, .set_err_return_trace => ctx.use(data.un_op),
        .neg_float, .sqrt, .sin, .cos, .tan, .exp, .exp2, .log, .log2, .log10, .abs_float, .floor, .ceil, .round, .trunc_float => ctx.use(data.un_op),
        .load, .not, .intcast, .trunc, .float_cast, .float_from_int, .int_from_float, .bitcast, .clz, .ctz, .popcount, .byte_swap, .bit_reverse => ctx.use(data.ty_op.operand),
        .ptr_from_int, .atomic_load, .slice_ptr, .slice_len, .optional_payload, .optional_payload_ptr, .optional_payload_ptr_set, .wrap_optional => ctx.use(data.ty_op.operand),
        .unwrap_errunion_payload, .unwrap_errunion_err, .unwrap_errunion_payload_ptr, .unwrap_errunion_err_ptr, .errunion_payload_ptr_set => ctx.use(data.ty_op.operand),
        .wrap_errunion_payload, .wrap_errunion_err, .get_union_tag, .tag_name, .c_va_arg, .c_va_copy => ctx.use(data.ty_op.operand),
        .store, .add_wrap, .sub_wrap, .mul_wrap, .add_float, .sub_float, .mul_float, .div_float, .div_trunc, .div_floor, .div_ceil, .rem, .mod => {
            ctx.use(data.bin_op.lhs);
            ctx.use(data.bin_op.rhs);
        },
        .min_float, .max_float, .bit_and, .bit_or, .xor, .shl, .shr, .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => {
            ctx.use(data.bin_op.lhs);
            ctx.use(data.bin_op.rhs);
        },
        .atomic_store, .ptr_elem_val, .slice_elem_val, .array_elem_val, .set_union_tag, .memcpy, .memmove, .memset => {
            ctx.use(data.bin_op.lhs);
            ctx.use(data.bin_op.rhs);
        },
        .add_with_overflow, .sub_with_overflow, .mul_with_overflow, .ptr_elem_ptr, .slice_elem_ptr, .slice, .ptr_add => {
            const bin = ir.extraData(Ir.Bin, data.ty_pl.payload).data;
            ctx.use(bin.lhs);
            ctx.use(bin.rhs);
        },
        .mul_add, .vector_store_elem => {
            const bin = ir.extraData(Ir.Bin, data.pl_op.payload).data;
            ctx.use(data.pl_op.operand);
            ctx.use(bin.lhs);
            ctx.use(bin.rhs);
        },
        .cond_br, .switch_br, .comptime_exit => ctx.use(data.pl_op.operand),
        .struct_field_ptr, .struct_field_val, .union_init => ctx.use(ir.extraData(Ir.StructField, data.ty_pl.payload).data.operand),
        .atomic_rmw => {
            const x = ir.extraData(Ir.AtomicRmw, data.ty_pl.payload).data;
            ctx.use(x.ptr);
            ctx.use(x.operand);
        },
        .cmpxchg => {
            const x = ir.extraData(Ir.Cmpxchg, data.ty_pl.payload).data;
            ctx.use(x.ptr);
            ctx.use(x.expected);
            ctx.use(x.new);
        },
        .aggregate_init => {
            const extra = ir.extraData(Ir.Aggregate, data.ty_pl.payload);
            for (ir.refSlice(extra.end, extra.data.len)) |elem| ctx.use(elem);
        },
        .call => {
            const extra = ir.extraData(Ir.Call, data.pl_op.payload);
            ctx.use(data.pl_op.operand);
            for (ir.refSlice(extra.end, extra.data.args_len)) |arg| ctx.use(arg);
        },
        .assembly => {
            const extra = ir.extraData(Ir.Asm, data.ty_pl.payload);
            var i = extra.end;
            for (0..extra.data.outputs_len + extra.data.inputs_len) |_| {
                const operand: Inst.Ref = @fromBackingInt(ir.extra[i + 2]);
                if (operand != .none) ctx.use(operand);
                i += 3;
            }
        },
    }
}

/// Linear-scan register allocation (Poletto and Sarkar) over the values
/// `liveness` gave intervals and the architecture marked `want_reg`, with
/// `n` registers, in order of definition. When none is free, the value
/// whose interval ends last is kept in memory for its whole life. Values
/// stay in their register through their last use, so a result shares a
/// register only with its tied operand. Returns the mask of registers used.
pub fn allocate(f: *Func, n: u8) u32 {
    assert(n <= max_regs);
    const s = f.live.slice();
    const reg = s.items(.reg);
    const def = s.items(.def);
    const end = s.items(.end);
    const tie = s.items(.tie);
    var active: [max_regs]u32 = undefined;
    var active_len: u8 = 0;
    var free: u32 = (@as(u32, 1) << @intCast(n)) - 1;
    var used: u32 = 0;
    for (f.values.items(.inst)) |inst_index| {
        const inst = @backingInt(inst_index);
        if (reg[inst] != want_reg) continue;
        var j: u8 = 0;
        while (j < active_len) {
            const a = active[j];
            if (end[a] < def[inst]) {
                free |= @as(u32, 1) << @intCast(reg[a]);
                active_len -= 1;
                active[j] = active[active_len];
            } else j += 1;
        }
        const t = tie[inst];
        if (t != no_tie and end[t] == def[inst] and reg[t] < n) {
            // Take over the tied operand's register, which dies here.
            const k = std.mem.indexOfScalar(u32, active[0..active_len], t).?;
            reg[inst] = reg[t];
            active[k] = inst;
            continue;
        }
        if (free != 0) {
            const r: u8 = @intCast(@ctz(free));
            free &= free - 1;
            used |= @as(u32, 1) << @intCast(r);
            reg[inst] = r;
            active[active_len] = inst;
            active_len += 1;
            continue;
        }
        var last: u8 = 0;
        for (active[0..active_len], 0..) |a, k| {
            if (end[a] > end[active[last]]) last = @intCast(k);
        }
        const victim = active[last];
        if (end[victim] > end[inst]) {
            reg[inst] = reg[victim];
            reg[victim] = no_reg;
            active[last] = inst;
        } else reg[inst] = no_reg;
    }
    return used;
}

pub const max_regs = 16;

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
        1, 1, 4, 5, // 0: cond_br: then { br }, else { repeat }
        1, 3, // 4: loop body { cond_br }
        1, 2, // 6: block body { loop }
        3, 0, 1, 6, // 8: main body { arg, block, ret }
    };
    const c = Inst.Index.toRef(@fromBackingInt(0));
    try insts.append(gpa, .{ .tag = .arg, .data = .{ .arg = .{ .ty = .bool_type, .index = 0 } } });
    try insts.append(gpa, .{ .tag = .block, .data = .{ .ty_pl = .{ .ty = .void_type, .payload = 6 } } });
    try insts.append(gpa, .{ .tag = .loop, .data = .{ .ty_pl = .{ .ty = .noreturn_type, .payload = 4 } } });
    try insts.append(gpa, .{ .tag = .cond_br, .data = .{ .pl_op = .{ .operand = c, .payload = 0 } } });
    try insts.append(gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = @fromBackingInt(1), .operand = .void_value } } });
    try insts.append(gpa, .{ .tag = .repeat, .data = .{ .repeat = .{ .loop_inst = @fromBackingInt(2) } } });
    try insts.append(gpa, .{ .tag = .ret, .data = .{ .un_op = .void_value } });
    const ir: Ir = .{ .instructions = insts.slice(), .extra = &extra, .func = .none, .main_block = 8 };
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
