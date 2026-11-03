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
    try f.targets.appendNTimes(gpa, .none, ir.instructions.len);
    // At most one value per IR instruction.
    try f.values.ensureTotalCapacity(gpa, ir.instructions.len);
    var b: Builder = .{ .f = f, .gpa = gpa, .ir = ir };
    try b.body(ir.mainBody());
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

    fn newBlock(b: *Builder) Allocator.Error!Block.Index {
        try b.f.blocks.append(b.gpa, .{ .start = 0, .len = 0, .term = undefined });
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
                const header = try b.newBlock();
                b.f.targets.items[@backingInt(inst)] = header;
                // Falls through into the header.
                try b.open(header);
                try b.body(ir.bodySlice(extra.end, extra.data.body_len));
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
