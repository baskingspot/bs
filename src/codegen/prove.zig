//! Removing checks that facts prove (docs/architecture.md, "Proving
//! checks"), as Go's `prove`: one walk over a function's IR that keeps the
//! comparisons known to hold at each point, from the branches that lead
//! there and from the checks already passed, and turns a safety check
//! whose condition they prove into an unconditional branch, which
//! `Ssa.build` then builds without its failing side. Only checks proven
//! true go, and nothing moves: the walk changes a `cond_br`'s condition to
//! a constant and nothing else.
//!
//! Values are compared by what they are, not by instruction: a load of a
//! variable (an alloc only loaded and stored) is the value its last store
//! stored when that store is known, else the variable at a version that
//! changes at each store, at each loop entry (a later store in the loop
//! reaches the loop's start), and after each merge of paths that stored
//! it. A `*const` alloc is the value stored to it, and `slice_len` of
//! equal slices are equal.
//!
//! Proven: compares (bounds checks `i < len`, `start <= end`) from facts on
//! the same values or constant bounds, and the overflow checks of
//! additions, subtractions, and multiplications whose operands' bounds
//! exclude overflow (`i + 1` after `i < len`, `n - 1` after `n >= 2`).
//! Runs on the CodeGen worker, before `CodeGen.generate`; reads the
//! InternPool only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const Index = InternPool.Index;
const Ir = @import("../Ir.zig");
const Inst = Ir.Inst;
const Type = @import("../Type.zig");
const Ssa = @import("Ssa.zig");

pub const Stats = struct {
    /// Safety checks (Sema's branches with a failing side), and those
    /// whose condition was proven.
    checks: u32 = 0,
    proven: u32 = 0,
};

/// Arrays kept from one function to the next on a worker.
pub const Scratch = struct {
    kind: std.ArrayList(Kind) = .empty,
    /// Per variable: its version, and the value its last store stored
    /// (`Term.none` when not known); per `*const` alloc, the value.
    version: std.ArrayList(u32) = .empty,
    value: std.ArrayList(Term) = .empty,
    facts: std.ArrayList(Fact) = .empty,
    exits: std.ArrayList(Exit) = .empty,
    exit_facts: std.ArrayList(Fact) = .empty,
    /// Variables stored, in walk order, so a merge can forget them.
    stored: std.ArrayList(u32) = .empty,

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        s.kind.deinit(gpa);
        s.version.deinit(gpa);
        s.value.deinit(gpa);
        s.facts.deinit(gpa);
        s.exits.deinit(gpa);
        s.exit_facts.deinit(gpa);
        s.stored.deinit(gpa);
    }
};

/// `constant`: a `*const` alloc stored at most once (`stored_once` while
/// `classify` counts).
const Kind = enum(u8) { other, variable, constant, stored_once };

/// A value, compared exactly.
const Term = struct {
    tag: enum(u8) { none, konst, inst, variable, interned, len_inst, len_variable, len_interned },
    a: u32 = 0,
    b: u32 = 0,

    const none: Term = .{ .tag = .none };

    fn eql(x: Term, y: Term) bool {
        return x.tag == y.tag and x.a == y.a and x.b == y.b;
    }

    fn konst(v: u64) Term {
        return .{ .tag = .konst, .a = @truncate(v), .b = @truncate(v >> 32) };
    }

    fn bits(t: Term) u64 {
        return @as(u64, t.b) << 32 | t.a;
    }
};

/// `a op b` holds, with the operands' signedness.
const Fact = struct {
    op: Op,
    signed: bool,
    a: Term,
    b: Term,
};

const Op = enum(u8) { lt, le, eq, ne };

/// A `block` being walked: how many `br`s exit it so far, and the facts
/// found inside it (above `depth`) that held at all of them
/// (`exit_facts[start..][0..len]`).
const Exit = struct {
    block: Inst.Index,
    depth: u32,
    count: u32 = 0,
    start: u32,
    len: u32 = 0,
};

pub fn run(gpa: Allocator, ip: *const InternPool, ir: *Ir, scratch: *Scratch) Allocator.Error!Stats {
    // No branch, no check.
    if (std.mem.indexOfScalar(Inst.Tag, ir.instructions.items(.tag), .cond_br) == null) return .{};
    const n = ir.instructions.len;
    try scratch.kind.resize(gpa, n);
    try scratch.version.resize(gpa, n);
    try scratch.value.resize(gpa, n);
    scratch.facts.clearRetainingCapacity();
    scratch.exits.clearRetainingCapacity();
    scratch.exit_facts.clearRetainingCapacity();
    scratch.stored.clearRetainingCapacity();
    classify(ip, ir, scratch.kind.items);
    var w: Walker = .{ .gpa = gpa, .ip = ip, .ir = ir, .s = scratch };
    try w.body(ir.mainBody());
    return w.stats;
}

/// Which allocs are variables (only loaded from and stored to, never
/// volatile) and which `*const` allocs hold one value.
fn classify(ip: *const InternPool, ir: *const Ir, kind: []Kind) void {
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    for (tags, datas, kind) |tag, data, *k| {
        k.* = .other;
        if (tag != .alloc or data.ty == .none) continue;
        const p = Type.ptrInfo(ip, data.ty);
        if (p.flags.is_volatile) continue;
        k.* = if (p.flags.is_const) .constant else .variable;
    }
    const Escape = struct {
        kind: []Kind,
        tags: []const Inst.Tag,
        pub fn use(e: @This(), r: Inst.Ref) void {
            const i = r.toIndex() orelse return;
            if (e.tags[@backingInt(i)] == .alloc) e.kind[@backingInt(i)] = .other;
        }
    };
    const e: Escape = .{ .kind = kind, .tags = tags };
    for (tags, datas, 0..) |tag, data, i| switch (tag) {
        .load => {},
        .store => {
            e.use(data.bin_op.rhs);
            // A `*const` alloc stored twice (on two paths) is a variable.
            const p = data.bin_op.lhs.toIndex() orelse continue;
            const k = &kind[@backingInt(p)];
            k.* = switch (k.*) {
                .constant => .stored_once,
                .stored_once => .variable,
                else => k.*,
            };
        },
        else => Ssa.forEachOperand(ir, @enumFromInt(i), e),
    };
    for (kind) |*k| if (k.* == .stored_once) {
        k.* = .constant;
    };
}

const Walker = struct {
    gpa: Allocator,
    ip: *const InternPool,
    ir: *Ir,
    s: *Scratch,
    /// Numbers versions and loop entries.
    clock: u32 = 1,
    /// The entry of the innermost loop being walked: a variable not stored
    /// since may hold what the loop's last iteration stored.
    stamp: u32 = 0,
    stats: Stats = .{},
    /// The overflow operation of the overflow check `decide` decided.
    checked_op: ?Inst.Index = null,

    fn tick(w: *Walker) u32 {
        w.clock += 1;
        return w.clock;
    }

    fn body(w: *Walker, insts: []const Inst.Index) Allocator.Error!void {
        for (insts) |inst| try w.instruction(inst);
    }

    /// Forgets the values of the variables stored since `from` in
    /// `stored`: paths that stored them merge here.
    fn merge(w: *Walker, from: usize) void {
        const s = w.s;
        if (s.stored.items.len == from) return;
        const v = w.tick();
        for (s.stored.items[from..]) |a| {
            s.version.items[a] = v;
            s.value.items[a] = .none;
        }
        // Still stored, for an enclosing merge.
    }

    fn instruction(w: *Walker, inst: Inst.Index) Allocator.Error!void {
        const ir = w.ir;
        const s = w.s;
        const ii = @backingInt(inst);
        const data = ir.instructions.items(.data)[ii];
        switch (ir.instructions.items(.tag)[ii]) {
            .alloc => switch (s.kind.items[ii]) {
                .variable => {
                    s.version.items[ii] = w.tick();
                    s.value.items[ii] = .none;
                },
                .constant => s.value.items[ii] = .none,
                .other, .stored_once => {},
            },
            .store => {
                const p = data.bin_op.lhs.toIndex() orelse return;
                const pi = @backingInt(p);
                switch (s.kind.items[pi]) {
                    .variable => {
                        s.version.items[pi] = w.tick();
                        s.value.items[pi] = w.term(data.bin_op.rhs);
                        try s.stored.append(w.gpa, pi);
                    },
                    .constant => s.value.items[pi] = w.term(data.bin_op.rhs),
                    .other, .stored_once => {},
                }
            },
            .block => {
                const x = ir.extraData(Ir.Block, data.ty_pl.payload);
                const insts = ir.bodySlice(x.end, x.data.body_len);
                const depth = s.facts.items.len;
                const from = s.stored.items.len;
                const exit_start = s.exit_facts.items.len;
                try s.exits.append(w.gpa, .{ .block = inst, .depth = @intCast(depth), .start = @intCast(exit_start) });
                try w.body(insts);
                const exit = s.exits.pop().?;
                s.facts.shrinkRetainingCapacity(depth);
                // Straight-line code that ends in its only `br` merges
                // nothing.
                if (exit.count != 1 or insts.len == 0 or
                    ir.instructions.items(.tag)[@backingInt(insts[insts.len - 1])] != .br) w.merge(from);
                // What held at every exit holds after the block.
                if (exit.count != 0) try s.facts.appendSlice(w.gpa, s.exit_facts.items[exit.start..][0..exit.len]);
                s.exit_facts.shrinkRetainingCapacity(exit_start);
            },
            .loop => {
                const x = ir.extraData(Ir.Block, data.ty_pl.payload);
                const depth = s.facts.items.len;
                const from = s.stored.items.len;
                const outer = w.stamp;
                w.stamp = w.tick();
                try w.body(ir.bodySlice(x.end, x.data.body_len));
                w.stamp = outer;
                s.facts.shrinkRetainingCapacity(depth);
                w.merge(from);
            },
            .br => try w.exitTo(data.br.block_inst),
            .cond_br => {
                const x = ir.extraData(Ir.CondBr, data.pl_op.payload);
                const then_body = ir.bodySlice(x.end, x.data.then_body_len);
                const else_body = ir.bodySlice(x.end + then_body.len, x.data.else_body_len);
                const cond = data.pl_op.operand;
                // Only Sema's own branches: those the user wrote are
                // `-ffuzz` coverage points.
                const check = cond.toIndex() != null and @as(u32, @bitCast(x.data.cover)) == 0 and (isCold(ir, then_body) or isCold(ir, else_body));
                if (check) w.stats.checks += 1;
                if (check) if (w.decide(cond)) |c| if (!isCold(ir, if (c) then_body else else_body)) {
                    // The check passes (never decided toward its failure).
                    w.stats.proven += 1;
                    if (w.checked_op) |op| w.wrap(op);
                    ir.instructions.items(.data)[ii].pl_op.operand = .fromInterned(if (c) .bool_true else .bool_false);
                    return w.body(if (c) then_body else else_body);
                };
                const depth = s.facts.items.len;
                const from = s.stored.items.len;
                try w.assume(cond, true);
                try w.body(then_body);
                s.facts.shrinkRetainingCapacity(depth);
                // The other side does not see the stores of this one.
                w.merge(from);
                try w.assume(cond, false);
                try w.body(else_body);
                s.facts.shrinkRetainingCapacity(depth);
                w.merge(from);
            },
            .switch_br => {
                const x = ir.extraData(Ir.SwitchBr, data.pl_op.payload);
                const from = s.stored.items.len;
                var i = x.end;
                for (0..x.data.cases_len) |_| {
                    const items_len = ir.extra[i];
                    const body_len = ir.extra[i + 1];
                    try w.body(ir.bodySlice(i + 2 + items_len, body_len));
                    w.merge(from);
                    i += 2 + items_len + body_len;
                }
                try w.body(ir.bodySlice(i, x.data.else_body_len));
                w.merge(from);
            },
            else => {},
        }
    }

    /// A `br` to `block`: the facts that hold here hold after it, if they
    /// hold at its other `br`s too.
    fn exitTo(w: *Walker, block: Inst.Index) Allocator.Error!void {
        const s = w.s;
        var k = s.exits.items.len;
        while (k > 0) {
            k -= 1;
            const e = &s.exits.items[k];
            if (e.block != block) continue;
            // Only the facts found inside the block (those from before it
            // hold after it anyway), at most the 16 most recent.
            const all = s.facts.items[e.depth..];
            const inside = all[all.len -| 16..];
            if (e.count == 0) {
                // Only the innermost block's facts can grow at the end of
                // `exit_facts`; an exit from blocks entered since carries
                // none.
                if (k == s.exits.items.len - 1) {
                    try s.exit_facts.appendSlice(w.gpa, inside);
                    e.len = @intCast(inside.len);
                }
            } else {
                // Keep those that hold here too.
                var kept: u32 = 0;
                for (s.exit_facts.items[e.start..][0..e.len]) |f| {
                    for (inside) |g| if (std.meta.eql(f, g)) {
                        s.exit_facts.items[e.start + kept] = f;
                        kept += 1;
                        break;
                    };
                }
                e.len = kept;
            }
            e.count += 1;
            return;
        }
    }

    /// The value `r` is, as a term.
    fn term(w: *const Walker, r: Inst.Ref) Term {
        const ip = w.ip;
        if (r.toInterned()) |v| {
            if (ip.keyTag(v) == .int) if (ip.intValue(u64, v) orelse (if (ip.intValue(i64, v)) |x| @as(u64, @bitCast(x)) else null)) |k| return .konst(k);
            return .{ .tag = .interned, .a = @backingInt(v) };
        }
        const ir = w.ir;
        const s = w.s;
        const i = r.toIndex().?;
        const data = ir.instructions.items(.data)[@backingInt(i)];
        switch (ir.instructions.items(.tag)[@backingInt(i)]) {
            .load => if (data.ty_op.operand.toIndex()) |p| {
                const pi = @backingInt(p);
                switch (s.kind.items[pi]) {
                    .variable => {
                        const ver = s.version.items[pi];
                        // Stored in this iteration of the innermost loop.
                        if (ver > w.stamp) {
                            const v = s.value.items[pi];
                            return if (v.tag != .none) v else .{ .tag = .variable, .a = pi, .b = ver };
                        }
                        return .{ .tag = .variable, .a = pi, .b = w.stamp };
                    },
                    .constant => {
                        const v = s.value.items[pi];
                        if (v.tag != .none) return v;
                    },
                    .other, .stored_once => {},
                }
            },
            .slice_len => {
                const t = w.term(data.ty_op.operand);
                // The length a `slice` was made with (`asBytes`, `@ptrCast`).
                if (t.tag == .inst and ir.instructions.items(.tag)[t.a] == .slice)
                    return w.term(ir.extraData(Ir.Bin, ir.instructions.items(.data)[t.a].ty_pl.payload).data.rhs);
                return switch (t.tag) {
                    .inst => .{ .tag = .len_inst, .a = t.a },
                    .variable => .{ .tag = .len_variable, .a = t.a, .b = t.b },
                    .interned => .{ .tag = .len_interned, .a = t.a },
                    else => .{ .tag = .inst, .a = @backingInt(i) },
                };
            },
            // A widening cast keeps the value.
            .intcast => if (w.intInfo(data.ty_op.operand)) |from| if (w.intInfo(r)) |to| {
                if (from.signedness == to.signedness and from.bits <= to.bits) return w.term(data.ty_op.operand);
            },
            else => {},
        }
        return .{ .tag = .inst, .a = @backingInt(i) };
    }

    /// For `x + 1` (an addition that wraps, or an overflow operation's
    /// value), `x`.
    fn plusOne(w: *const Walker, t: Term) ?Term {
        if (t.tag != .inst) return null;
        const ir = w.ir;
        const data = ir.instructions.items(.data)[t.a];
        const bin: Ir.Bin = switch (ir.instructions.items(.tag)[t.a]) {
            .add_wrap => .{ .lhs = data.bin_op.lhs, .rhs = data.bin_op.rhs },
            .struct_field_val => blk: {
                const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
                const op = sf.operand.toIndex() orelse return null;
                if (sf.index != 0 or ir.instructions.items(.tag)[@backingInt(op)] != .add_with_overflow) return null;
                break :blk ir.extraData(Ir.Bin, ir.instructions.items(.data)[@backingInt(op)].ty_pl.payload).data;
            },
            else => return null,
        };
        const l = w.term(bin.lhs);
        const r = w.term(bin.rhs);
        if (r.tag == .konst and r.bits() == 1) return l;
        if (l.tag == .konst and l.bits() == 1) return r;
        return null;
    }

    /// The integer type of `r`, if at most 64 bits.
    fn intInfo(w: *const Walker, r: Inst.Ref) ?Type.IntInfo {
        const ty = w.ir.typeOf(r, w.ip);
        if (Type.class(w.ip, ty) != .int) return null;
        const info = Type.intInfo(w.ip, ty);
        return if (info.bits <= 64 and info.bits > 0) info else null;
    }

    /// Records what holds where `cond` is `truth`.
    fn assume(w: *Walker, cond: Inst.Ref, truth: bool) Allocator.Error!void {
        const i = cond.toIndex() orelse return;
        const ir = w.ir;
        const data = ir.instructions.items(.data)[@backingInt(i)];
        switch (ir.instructions.items(.tag)[@backingInt(i)]) {
            .not => try w.assume(data.ty_op.operand, !truth),
            .bit_and => if (truth) {
                try w.assume(data.bin_op.lhs, true);
                try w.assume(data.bin_op.rhs, true);
            },
            .bit_or => if (!truth) {
                try w.assume(data.bin_op.lhs, false);
                try w.assume(data.bin_op.rhs, false);
            },
            .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => |tag| {
                const info = w.intInfo(data.bin_op.lhs) orelse return;
                var f = fact(tag, w.term(data.bin_op.lhs), w.term(data.bin_op.rhs), info.signedness == .signed);
                if (!truth) f = negate(f);
                try w.s.facts.append(w.gpa, f);
            },
            else => {},
        }
    }

    /// An overflow operation proven not to overflow: its value field,
    /// which Sema reads right after it, becomes the wrapping operation, so
    /// the overflow bit is not computed.
    fn wrap(w: *Walker, op: Inst.Index) void {
        const ir = w.ir;
        const next = @backingInt(op) + 1;
        if (next >= ir.instructions.len or ir.instructions.items(.tag)[next] != .struct_field_val) return;
        const sf = ir.extraData(Ir.StructField, ir.instructions.items(.data)[next].ty_pl.payload).data;
        if (sf.index != 0 or sf.operand != op.toRef()) return;
        const bin = ir.extraData(Ir.Bin, ir.instructions.items(.data)[@backingInt(op)].ty_pl.payload).data;
        ir.instructions.items(.tag)[next] = switch (ir.instructions.items(.tag)[@backingInt(op)]) {
            .add_with_overflow => .add_wrap,
            .sub_with_overflow => .sub_wrap,
            else => .mul_wrap,
        };
        ir.instructions.items(.data)[next] = .{ .bin_op = .{ .lhs = bin.lhs, .rhs = bin.rhs } };
    }

    /// Whether the facts decide condition `cond`.
    fn decide(w: *Walker, cond: Inst.Ref) ?bool {
        w.checked_op = null;
        const i = cond.toIndex() orelse return null;
        const ir = w.ir;
        const data = ir.instructions.items(.data)[@backingInt(i)];
        switch (ir.instructions.items(.tag)[@backingInt(i)]) {
            .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => |tag| {
                const lhs = data.bin_op.lhs;
                const rhs = data.bin_op.rhs;
                const info = w.intInfo(lhs) orelse return null;
                // An overflow check: `cmp_eq(bit, 0)` and the like.
                if (lhs.toIndex()) |bit| if (ir.instructions.items(.tag)[@backingInt(bit)] == .struct_field_val) {
                    const sf = ir.extraData(Ir.StructField, ir.instructions.items(.data)[@backingInt(bit)].ty_pl.payload).data;
                    if (sf.index == 1) if (sf.operand.toIndex()) |op| if (Ssa.ovfBitCmp(ir, w.ip, i, @backingInt(bit))) |true_if_ovf| {
                        if (w.noOverflow(op)) {
                            w.checked_op = op;
                            return !true_if_ovf;
                        }
                        return null;
                    };
                };
                return w.proves(fact(tag, w.term(lhs), w.term(rhs), info.signedness == .signed), info);
            },
            else => return null,
        }
    }

    /// Whether overflow operation `op` provably does not overflow.
    fn noOverflow(w: *const Walker, op: Inst.Index) bool {
        const ir = w.ir;
        const tag = ir.instructions.items(.tag)[@backingInt(op)];
        switch (tag) {
            .add_with_overflow, .sub_with_overflow, .mul_with_overflow => {},
            else => return false,
        }
        const bin = ir.extraData(Ir.Bin, ir.instructions.items(.data)[@backingInt(op)].ty_pl.payload).data;
        const info = w.intInfo(bin.lhs) orelse return false;
        const signed = info.signedness == .signed;
        const a = w.term(bin.lhs);
        const b = w.term(bin.rhs);
        const ra = w.range(a, info);
        const rb = w.range(b, info);
        const lim = limits(info);
        switch (tag) {
            .add_with_overflow => {
                if (ra.hi + rb.hi <= lim.hi and ra.lo + rb.lo >= lim.lo) return true;
                return false;
            },
            .sub_with_overflow => {
                if (ra.lo - rb.hi >= lim.lo and ra.hi - rb.lo <= lim.hi) return true;
                // `a - b` with `b <= a`.
                if (!signed and w.holds(.{ .op = .le, .signed = false, .a = b, .b = a })) return true;
                return false;
            },
            else => {
                if (signed) return false;
                const p = std.math.mul(i128, ra.hi, rb.hi) catch return false;
                return p <= lim.hi;
            },
        }
    }

    const Range = struct { lo: i128, hi: i128 };

    fn limits(info: Type.IntInfo) Range {
        const bits: u7 = @intCast(info.bits);
        return if (info.signedness == .signed)
            .{ .lo = -(@as(i128, 1) << (bits - 1)), .hi = (@as(i128, 1) << (bits - 1)) - 1 }
        else
            .{ .lo = 0, .hi = (@as(i128, 1) << bits) - 1 };
    }

    fn value(t: Term, info: Type.IntInfo) i128 {
        const v = t.bits();
        if (info.signedness == .unsigned) return v;
        const bits: u7 = @intCast(info.bits);
        const sh: u6 = @intCast(64 - @as(u7, bits));
        return @as(i64, @bitCast(v << sh)) >> sh;
    }

    /// The bounds of `t` the facts give: constant bounds, and one less
    /// than any value of the type for `t < u`.
    fn range(w: *const Walker, t: Term, info: Type.IntInfo) Range {
        if (t.tag == .konst) {
            const v = value(t, info);
            return .{ .lo = v, .hi = v };
        }
        const signed = info.signedness == .signed;
        const lim = limits(info);
        var r = lim;
        for (w.recent()) |f| {
            if (f.signed != signed) continue;
            if (f.a.eql(t)) {
                const k: ?i128 = if (f.b.tag == .konst) value(f.b, info) else null;
                switch (f.op) {
                    .lt => r.hi = @min(r.hi, (k orelse lim.hi) - 1),
                    .le => if (k) |v| {
                        r.hi = @min(r.hi, v);
                    },
                    .eq => if (k) |v| {
                        r.lo = @max(r.lo, v);
                        r.hi = @min(r.hi, v);
                    },
                    .ne => {},
                }
            } else if (f.b.eql(t)) {
                const k: ?i128 = if (f.a.tag == .konst) value(f.a, info) else null;
                switch (f.op) {
                    .lt => r.lo = @max(r.lo, (k orelse lim.lo) + 1),
                    .le => if (k) |v| {
                        r.lo = @max(r.lo, v);
                    },
                    .eq => if (k) |v| {
                        r.lo = @max(r.lo, v);
                        r.hi = @min(r.hi, v);
                    },
                    .ne => {},
                }
            }
        }
        return r;
    }

    /// The facts searched: the most recent, which keeps a function with
    /// thousands of checks linear (fewer facts only prove less).
    fn recent(w: *const Walker) []const Fact {
        const all = w.s.facts.items;
        return all[all.len -| 64..];
    }

    /// Whether `f` holds: a fact says so, or the operands' bounds do.
    fn holds(w: *const Walker, f: Fact) bool {
        for (w.recent()) |g| {
            if (g.signed != f.signed) continue;
            if (implies(g, f)) return true;
        }
        return false;
    }

    /// True or false if the facts decide `f`.
    fn proves(w: *const Walker, f: Fact, info: Type.IntInfo) ?bool {
        if (w.holds(f)) return true;
        if (w.holds(negate(f))) return false;
        // `x + 1 <= y` from `x < y` (so `x + 1` did not wrap), and
        // `x < y` from `x + 1 <= y` (an earlier slice end check).
        if (f.op == .le) if (w.plusOne(f.a)) |x| {
            if (w.holds(.{ .op = .lt, .signed = f.signed, .a = x, .b = f.b })) return true;
        };
        if (f.op == .lt) for (w.recent()) |g| {
            if (g.op != .le or g.signed != f.signed or !g.b.eql(f.b)) continue;
            if (w.plusOne(g.a)) |x| if (x.eql(f.a)) return true;
        };
        const a = w.range(f.a, info);
        const b = w.range(f.b, info);
        return switch (f.op) {
            .lt => if (a.hi < b.lo) true else if (a.lo >= b.hi) false else null,
            .le => if (a.hi <= b.lo) true else if (a.lo > b.hi) false else null,
            .eq => if (a.hi < b.lo or a.lo > b.hi) false else if (a.lo == a.hi and b.lo == b.hi and a.lo == b.lo) true else null,
            .ne => if (a.hi < b.lo or a.lo > b.hi) true else if (a.lo == a.hi and b.lo == b.hi and a.lo == b.lo) false else null,
        };
    }
};

/// Whether a body is a check's failure: it ends in `unreach` or `trap`.
fn isCold(ir: *const Ir, body: []const Inst.Index) bool {
    if (body.len == 0) return false;
    return switch (ir.instructions.items(.tag)[@backingInt(body[body.len - 1])]) {
        .unreach, .trap => true,
        else => false,
    };
}

/// `a tag b` as a fact.
fn fact(tag: Inst.Tag, a: Term, b: Term, signed: bool) Fact {
    return switch (tag) {
        .cmp_lt => .{ .op = .lt, .signed = signed, .a = a, .b = b },
        .cmp_lte => .{ .op = .le, .signed = signed, .a = a, .b = b },
        .cmp_gt => .{ .op = .lt, .signed = signed, .a = b, .b = a },
        .cmp_gte => .{ .op = .le, .signed = signed, .a = b, .b = a },
        .cmp_eq => .{ .op = .eq, .signed = signed, .a = a, .b = b },
        .cmp_neq => .{ .op = .ne, .signed = signed, .a = a, .b = b },
        else => unreachable,
    };
}

fn negate(f: Fact) Fact {
    return switch (f.op) {
        .lt => .{ .op = .le, .signed = f.signed, .a = f.b, .b = f.a },
        .le => .{ .op = .lt, .signed = f.signed, .a = f.b, .b = f.a },
        .eq => .{ .op = .ne, .signed = f.signed, .a = f.a, .b = f.b },
        .ne => .{ .op = .eq, .signed = f.signed, .a = f.a, .b = f.b },
    };
}

/// Whether fact `g` alone implies `f` (same operands).
fn implies(g: Fact, f: Fact) bool {
    const same = g.a.eql(f.a) and g.b.eql(f.b);
    const swapped = g.a.eql(f.b) and g.b.eql(f.a);
    return switch (f.op) {
        .lt => same and g.op == .lt,
        .le => (same and (g.op == .le or g.op == .lt or g.op == .eq)) or (swapped and g.op == .eq),
        .eq => (same or swapped) and g.op == .eq,
        .ne => (same or swapped) and (g.op == .ne or (g.op == .lt)),
    };
}

test "implies" {
    const x: Term = .{ .tag = .inst, .a = 1 };
    const y: Term = .{ .tag = .inst, .a = 2 };
    const lt: Fact = .{ .op = .lt, .signed = false, .a = x, .b = y };
    try std.testing.expect(implies(lt, .{ .op = .le, .signed = false, .a = x, .b = y }));
    try std.testing.expect(implies(lt, .{ .op = .ne, .signed = false, .a = y, .b = x }));
    try std.testing.expect(!implies(lt, .{ .op = .lt, .signed = false, .a = y, .b = x }));
    try std.testing.expect(implies(negate(lt), .{ .op = .le, .signed = false, .a = y, .b = x }));
}
