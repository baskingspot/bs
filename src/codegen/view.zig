//! In-place part reads (docs/slop/architecture.md, "Views"): a load of an
//! aggregate in memory whose every user reads only part of it (an
//! optional's or error union's state, a union's tag, a field, a payload,
//! an error code) is not copied; its users read their parts where the load
//! points. Sema emits such loads for `x.opt == null`, `x.opt.?`,
//! `if (x.eu) |*p|` and `switch (ptr.*)`, and each one copied the whole
//! aggregate to read a byte or a word of it.
//!
//! The users read the memory later than the load did, which reads the same
//! bytes when nothing may write memory in between: every user is in the
//! load's block, or in a successor whose only predecessor that block is,
//! with no value that may write memory before it (a fused condition reads
//! at its block's end). The load's pointer then lives until the last user.
//! Each backend decides which loads it can read in place (`viewable`) and
//! gives those its memory as their home.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const Ir = @import("../Ir.zig");
const Inst = Ir.Inst;
const Type = @import("../Type.zig");
const Ssa = @import("Ssa.zig");

const none = std.math.maxInt(u32);

const Cand = struct {
    load: u32,
    /// Users not yet found.
    pending: u32,
    /// The position of the last user found.
    last: u32,
    bad: bool = false,
    /// A fused condition of the block being scanned reads the load at the
    /// block's end.
    tail: bool = false,
};

/// Appends to `out` the loads whose users read them in place, and extends
/// their pointers' intervals to their last users. `ctx.viewable(load,
/// ty)` says whether the backend can read a load of type `ty` in place:
/// one in memory that is not otherwise planned.
pub fn plan(f: *const Ssa, gpa: Allocator, ir: *const Ir, ip: *const InternPool, ctx: anytype, out: *std.ArrayList(u32)) Allocator.Error!void {
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    const live = f.live.slice();
    // A function without such a load costs one pass to find that.
    const any = for (f.values.items(.inst)) |inst| {
        if (tags[@backingInt(inst)] == .load and live.items(.reg)[@backingInt(inst)] == Ssa.no_reg and
            live.items(.fate)[@backingInt(inst)] == .normal) break true;
    } else false;
    if (!any) return;

    // Each block's only predecessor, after forwarding (`maxInt - 1` when
    // it has several), and its place in the layout.
    const nb = f.blocks.items.len;
    const pred = try gpa.alloc(u32, 2 * nb);
    defer gpa.free(pred);
    const pos = pred[nb..];
    @memset(pred[0..nb], none);
    @memset(pos, none);
    for (f.layout.items, 0..) |block, li| pos[@backingInt(block)] = @intCast(li);
    for (f.blocks.items, 0..) |b, bi| {
        // An empty block forwarded to its target emits nothing.
        if (@backingInt(f.fwd.items[bi]) != bi) continue;
        var it = succs(f, ir, b.term);
        while (it.next()) |s| addPred(f, pred, s, @intCast(bi));
    }

    var cands: std.ArrayList(Cand) = .empty;
    defer cands.deinit(gpa);
    for (f.layout.items, 0..) |block, li| {
        cands.clearRetainingCapacity();
        const b = f.blocks.items[@backingInt(block)];
        const term_pos = Ssa.valuePos(b.start + b.len) - 1;
        for (f.blockInsts(block)) |v| {
            scanValue(f, ir, ip, cands.items, v, term_pos, null);
            const vi = @backingInt(v);
            if (tags[vi] == .load and candidate(f, ir, ip, v) and ctx.viewable(v, datas[vi].ty_op.ty))
                try cands.append(gpa, .{ .load = vi, .pending = live.items(.uses)[vi], .last = 0 });
        }
        termUses(ir, cands.items, b.term);
        // The users left may be at the head of a successor that only this
        // block reaches, later in the layout.
        if (for (cands.items) |c| {
            if (!c.bad and c.pending != 0) break true;
        } else false) {
            var it = succs(f, ir, b.term);
            var seen: [2]u32 = .{ none, none };
            while (it.next()) |s0| {
                const s = @backingInt(f.fwd.items[s0]);
                if (pred[s] != @backingInt(block) or pos[s] == none or pos[s] <= li) continue;
                // A switch may reach one block from several cases; a
                // branch from both of its arms.
                if (s == seen[0] or s == seen[1]) continue;
                seen = .{ seen[1], s };
                const sb = f.blocks.items[s];
                const s_term = Ssa.valuePos(sb.start + sb.len) - 1;
                for (cands.items) |*c| c.tail = false;
                var wrote = false;
                for (f.blockInsts(@fromBackingInt(s))) |v| {
                    scanValue(f, ir, ip, cands.items, v, s_term, &wrote);
                }
                termUses(ir, cands.items, sb.term);
            }
        }
        for (cands.items) |c| {
            if (c.bad or c.pending != 0) continue;
            extend(f, ir, @fromBackingInt(c.load), c.last);
            try out.append(gpa, c.load);
        }
    }
}

/// Whether load `l` may be read in place, by its own properties: not
/// volatile, of an aggregate that is not packed, read by something, and
/// through a pointer that is not a register variable or a folded address
/// and can live until its users.
fn candidate(f: *const Ssa, ir: *const Ir, ip: *const InternPool, l: Inst.Index) bool {
    const live = f.live.slice();
    const li = @backingInt(l);
    if (live.items(.fate)[li] != .normal or live.items(.uses)[li] == 0 or live.items(.fwd)[li] != Ssa.no_tie) return false;
    if (live.items(.reg)[li] != Ssa.no_reg) return false;
    if (!Ssa.removable(ir, ip, l)) return false; // volatile
    const ty = ir.instructions.items(.data)[li].ty_op.ty;
    if (Type.abiSize(ip, ty) == 0 or Type.isPacked(ip, ty)) return false;
    const p0 = ir.instructions.items(.data)[li].ty_op.operand.toIndex() orelse return true;
    var p = @backingInt(p0);
    // A variable `Ssa.plan` keeps in a register has no memory to read.
    if (ir.instructions.items(.tag)[p] == .alloc and Ssa.wants(live.items(.reg)[p])) return false;
    if (live.items(.reg)[p] == Ssa.want_fold) return false;
    if (live.items(.fwd)[p] != Ssa.no_tie) p = live.items(.fwd)[p];
    return live.items(.share)[p] == Ssa.no_tie and live.items(.fate)[p] == .normal;
}

/// Counts value `v`'s reads of the candidates: a part read is a user
/// found (at its position, or at `term_pos` when its block's branch
/// computes it); any other read disqualifies the candidate. In the
/// candidates' own block, a value that may write memory disqualifies
/// those with users still to come; in a successor (`wrote`, whether
/// one came before in it), it disqualifies the users after it. Either way
/// it disqualifies those a fused condition reads at the block's end.
fn scanValue(f: *const Ssa, ir: *const Ir, ip: *const InternPool, cands: []Cand, v: Inst.Index, term_pos: u32, wrote: ?*bool) void {
    if (cands.len == 0) return;
    const live = f.live.slice();
    const vi = @backingInt(v);
    if (live.items(.fate)[vi] != .dead) {
        if (partOperand(ir, v)) |op| {
            if (find(cands, op)) |c| {
                if (wrote) |w| if (w.*) {
                    c.bad = true;
                };
                c.pending -|= 1;
                const fused = live.items(.fate)[vi] == .fused;
                c.last = @max(c.last, if (fused) term_pos else live.items(.def)[vi]);
                c.tail = c.tail or fused;
            }
        } else {
            const Reads = struct {
                cands: []Cand,
                const Self = @This();
                pub fn use(r: Self, ref: Inst.Ref) void {
                    if (find(r.cands, ref)) |c| c.bad = true;
                }
            };
            Ssa.forEachOperand(ir, v, Reads{ .cands = cands });
        }
    }
    if (!writes(ir, ip, v)) return;
    if (wrote) |w| w.* = true;
    for (cands) |*c| {
        if ((wrote == null and c.pending != 0) or c.tail) c.bad = true;
    }
}

/// A terminator that reads a candidate (a `br` passing it to a block's
/// result, a `ret`) disqualifies it.
fn termUses(ir: *const Ir, cands: []Cand, term: Ssa.Term) void {
    const data = ir.instructions.items(.data)[@backingInt(term.inst)];
    const ref: Inst.Ref = switch (term.tag) {
        .jump => if (ir.instructions.items(.tag)[@backingInt(term.inst)] == .br) data.br.operand else return,
        .branch => Ssa.branchCond(ir, term),
        .switch_br => data.pl_op.operand,
        .ret => data.un_op,
        .fallthrough, .noreturn, .unreach => return,
    };
    if (find(cands, ref)) |c| c.bad = true;
}

/// The aggregate operand of a part read.
fn partOperand(ir: *const Ir, v: Inst.Index) ?Inst.Ref {
    const data = ir.instructions.items(.data)[@backingInt(v)];
    return switch (ir.instructions.items(.tag)[@backingInt(v)]) {
        .is_null, .is_non_null, .is_err, .is_non_err => data.un_op,
        .get_union_tag, .optional_payload, .unwrap_errunion_payload, .unwrap_errunion_err => data.ty_op.operand,
        .struct_field_val => ir.extraData(Ir.StructField, data.ty_pl.payload).data.operand,
        else => null,
    };
}

fn find(cands: []Cand, ref: Inst.Ref) ?*Cand {
    const i = @backingInt(ref.toIndex() orelse return null);
    for (cands) |*c| if (c.load == i) return c;
    return null;
}

/// Whether value `v` may write memory: anything with an effect but debug
/// markers and blocks, whose results their `br`s write.
fn writes(ir: *const Ir, ip: *const InternPool, v: Inst.Index) bool {
    return switch (ir.instructions.items(.tag)[@backingInt(v)]) {
        .dbg_stmt, .dbg_inline_begin, .dbg_inline_end, .block => false,
        // Volatile or not, a load writes nothing.
        .load => false,
        else => !Ssa.removable(ir, ip, v),
    };
}

/// Keeps load `l`'s pointer live until position `last`, where its last
/// user reads through it.
fn extend(f: *const Ssa, ir: *const Ir, l: Inst.Index, last: u32) void {
    const live = f.live.slice();
    const p0 = ir.instructions.items(.data)[@backingInt(l)].ty_op.operand.toIndex() orelse return;
    var p = @backingInt(p0);
    if (live.items(.fwd)[p] != Ssa.no_tie) p = live.items(.fwd)[p];
    const end = live.items(.end);
    const def = live.items(.def);
    const cl = f.clobbers.items;
    end[p] = @max(end[p], last);
    live.items(.crosses)[p] = live.items(.crosses)[p] or cl[end[p]][0] != cl[def[p]][0] or cl[end[p]][1] != cl[def[p]][1];
}

fn addPred(f: *const Ssa, pred: []u32, to: u32, from: u32) void {
    const t = @backingInt(f.fwd.items[to]);
    pred[t] = if (pred[t] == none) from else none - 1;
}

const Succs = struct {
    list: []const Ssa.Block.Index = &.{},
    extra: [2]u32 = .{ none, none },
    i: usize = 0,

    fn next(s: *Succs) ?u32 {
        if (s.i < s.list.len) {
            s.i += 1;
            return @backingInt(s.list[s.i - 1]);
        }
        const k = s.i - s.list.len;
        if (k >= 2 or s.extra[k] == none) return null;
        s.i += 1;
        return s.extra[k];
    }
};

/// The blocks terminator `t` may continue in.
fn succs(f: *const Ssa, ir: *const Ir, t: Ssa.Term) Succs {
    return switch (t.tag) {
        .jump, .fallthrough => .{ .extra = .{ t.succ[0], none } },
        .branch => .{ .extra = t.succ },
        .switch_br => .{
            .list = f.switchCases(t, ir.extraData(Ir.SwitchBr, ir.instructions.items(.data)[@backingInt(t.inst)].pl_op.payload).data.cases_len),
            .extra = .{ t.succ[1], none },
        },
        .noreturn, .ret, .unreach => .{},
    };
}
