//! Dropping blocks whose code nothing needs (docs/slop/architecture.md,
//! "Proving checks"): a `block` whose value nothing reads and whose body
//! only computes values and branches within itself, such as the `lt and
//! gt` of a check prove decided (`assert(!(lt and gt))` in std's sort
//! wrapper), becomes a block with a single void `br`. Its operands then
//! lose those uses, so the compares only the dropped body read die with
//! it, and a compare left with one reader fuses into its branch. A body
//! with a call, a store, a safety check's failing side or a loop stays:
//! nothing that has an effect or may not end goes, and no check moves.
//! Runs on the CodeGen worker, after `prove.run`; reads the InternPool
//! only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const Ir = @import("../Ir.zig");
const Inst = Ir.Inst;
const Ssa = @import("Ssa.zig");

/// The most instructions a dropped body has, nested bodies included.
const max_body = 64;

/// Arrays kept from one function to the next on a worker.
pub const Scratch = struct {
    /// The instructions in bodies, in walk order (a block before its body).
    order: std.ArrayList(Inst.Index) = .empty,
    /// Per instruction: its place in `order`; for a `block`, also the
    /// place after its body; the readers left, and the last reader's
    /// place.
    pos: std.ArrayList(u32) = .empty,
    end: std.ArrayList(u32) = .empty,
    uses: std.ArrayList(u32) = .empty,
    last_use: std.ArrayList(u32) = .empty,
    gone: std.DynamicBitSetUnmanaged = .{},

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        s.order.deinit(gpa);
        s.pos.deinit(gpa);
        s.end.deinit(gpa);
        s.uses.deinit(gpa);
        s.last_use.deinit(gpa);
        s.gone.deinit(gpa);
        s.* = undefined;
    }
};

/// Drops the blocks that qualify; returns how many.
pub fn run(gpa: Allocator, ip: *const InternPool, ir: *Ir, s: *Scratch) Allocator.Error!u32 {
    const n = ir.instructions.len;
    s.order.clearRetainingCapacity();
    try s.pos.resize(gpa, n);
    try s.end.resize(gpa, n);
    try s.uses.resize(gpa, n);
    try s.last_use.resize(gpa, n);
    @memset(s.uses.items, 0);
    @memset(s.last_use.items, 0);
    try s.gone.resize(gpa, n, false);
    s.gone.unsetAll();
    var w: Walk = .{ .gpa = gpa, .ir = ir, .s = s };
    try w.body(ir.mainBody());

    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    var dropped: u32 = 0;
    var i = s.order.items.len;
    while (i > 0) {
        i -= 1;
        const inst = s.order.items[i];
        const ii = @backingInt(inst);
        if (s.gone.isSet(ii) or s.uses.items[ii] != 0) continue;
        if (tags[ii] == .block) {
            const x = ir.extraData(Ir.Block, datas[ii].ty_pl.payload);
            const insts = ir.bodySlice(x.end, x.data.body_len);
            if (insts.len == 0 or !w.pure(inst, ip)) continue;
            for (s.order.items[i + 1 .. s.end.items[ii]]) |b| w.drop(b);
            // The body's last instruction becomes its only one.
            const last = insts[insts.len - 1];
            tags[@backingInt(last)] = .br;
            datas[@backingInt(last)] = .{ .br = .{ .block_inst = inst, .operand = .void_value } };
            const extra = @constCast(ir.extra);
            extra[datas[ii].ty_pl.payload] = 1;
            extra[x.end] = @backingInt(last);
            datas[ii].ty_pl.ty = .void_type;
            dropped += 1;
        } else if (Ssa.removable(ir, ip, inst)) {
            w.drop(inst);
        }
    }
    return dropped;
}

const Walk = struct {
    gpa: Allocator,
    ir: *const Ir,
    s: *Scratch,

    pub fn use(w: Walk, ref: Inst.Ref) void {
        const i = ref.toIndex() orelse return;
        w.s.uses.items[@backingInt(i)] += 1;
        w.s.last_use.items[@backingInt(i)] = @intCast(w.s.order.items.len - 1);
    }

    const Unuse = struct {
        uses: []u32,
        pub fn use(u: Unuse, ref: Inst.Ref) void {
            if (ref.toIndex()) |i| u.uses[@backingInt(i)] -= 1;
        }
    };

    /// Marks `inst` gone; its operands lose a reader.
    fn drop(w: Walk, inst: Inst.Index) void {
        if (w.s.gone.isSet(@backingInt(inst))) return;
        w.s.gone.set(@backingInt(inst));
        Ssa.forEachOperand(w.ir, inst, Unuse{ .uses = w.s.uses.items });
    }

    fn body(w: *Walk, insts: []const Inst.Index) Allocator.Error!void {
        const ir = w.ir;
        for (insts) |inst| {
            const ii = @backingInt(inst);
            w.s.pos.items[ii] = @intCast(w.s.order.items.len);
            try w.s.order.append(w.gpa, inst);
            Ssa.forEachOperand(ir, inst, w.*);
            const data = ir.instructions.items(.data)[ii];
            switch (ir.instructions.items(.tag)[ii]) {
                .block, .loop => {
                    const x = ir.extraData(Ir.Block, data.ty_pl.payload);
                    try w.body(ir.bodySlice(x.end, x.data.body_len));
                },
                .cond_br => {
                    const x = ir.extraData(Ir.CondBr, data.pl_op.payload);
                    try w.body(ir.bodySlice(x.end, x.data.then_body_len + x.data.else_body_len));
                },
                .switch_br => {
                    var it = ir.switchCases(data.pl_op.payload);
                    while (it.next()) |c| try w.body(c.body);
                    try w.body(it.elseBody());
                },
                else => {},
            }
            w.s.end.items[ii] = @intCast(w.s.order.items.len);
        }
    }

    /// Whether `block`'s body only computes values read inside it and
    /// branches within it.
    fn pure(w: *const Walk, block: Inst.Index, ip: *const InternPool) bool {
        const s = w.s;
        const start = s.pos.items[@backingInt(block)];
        const end = s.end.items[@backingInt(block)];
        if (end - start - 1 > max_body) return false;
        const tags = w.ir.instructions.items(.tag);
        const datas = w.ir.instructions.items(.data);
        for (s.order.items[start + 1 .. end]) |inst| {
            const ii = @backingInt(inst);
            if (s.gone.isSet(ii)) continue;
            if (s.uses.items[ii] != 0 and s.last_use.items[ii] >= end) return false;
            switch (tags[ii]) {
                .dbg_stmt, .cond_br, .switch_br, .block => {},
                // Within the body: to the block or one nested in it.
                .br => {
                    const p = s.pos.items[@backingInt(datas[ii].br.block_inst)];
                    if (p < start or p >= end) return false;
                },
                else => if (!Ssa.removable(w.ir, ip, inst)) return false,
            }
        }
        return true;
    }
};
