//! Removing checks that facts prove (docs/slop/architecture.md, "Proving
//! checks"), as Go's `prove`: one walk over a function's IR that keeps the
//! comparisons known to hold at each point, from the branches that lead
//! there and from the checks already passed, and turns a safety check
//! whose condition they prove into an unconditional branch, which
//! `Ssa.build` then builds without its failing side. Only checks proven
//! true go, and nothing moves: the walk changes a `cond_br`'s condition to
//! a constant and nothing else.
//!
//! Values are compared by what they are, not by instruction: a load of a
//! variable (an alloc only loaded and stored) is, where it runs, the value
//! its last store stored when that store is known, else the variable at a
//! version that changes at each store, at each loop entry (a later store
//! in the loop reaches the loop's start), and after each merge of paths
//! that stored it. A `*const` alloc is the value stored to it, and
//! `slice_len` of equal slices are equal. `BS_PROVE=off` turns the pass
//! off. Each rule says next to it why it holds.
//!
//! Proven: compares (bounds checks `i < len`, `start <= end`) from facts on
//! the same values or constant bounds, and the overflow checks of
//! additions, subtractions, and multiplications whose operands' bounds
//! exclude overflow (`i + 1` after `i < len`, `n - 1` after `n >= 2`),
//! and the same through constant offsets (`s[i..][0..16]` after `i + 32 <
//! s.len`, `offsetHolds`), with facts from before a loop kept at its
//! start when they hold again at its back edges (`speculate`).
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
    /// Per integer `block` exited only with constants so far: their
    /// bounds; `poisoned` once exited with another value.
    results: std.AutoHashMapUnmanaged(u32, Walker.Range) = .empty,
    exit_facts: std.ArrayList(Fact) = .empty,
    /// Variables and `*const` allocs stored, in walk order, so a merge
    /// can forget them.
    stored: std.ArrayList(u32) = .empty,
    /// Per load: its term, taken when the walk reaches it (`Term.none`
    /// before), since what the variable holds changes after.
    loads: std.ArrayList(Term) = .empty,
    /// Additions known not to wrap: overflow operations whose check the
    /// walk passed (`markChecked`), and the value reads `wrap` made
    /// wrapping operations.
    exact: std.DynamicBitSetUnmanaged = .{},
    /// The loop walked with candidate facts at its start (`Walker.spec`):
    /// the candidates, the instructions its decisions changed, and the
    /// enclosing blocks' exits before it.
    cands: std.ArrayList(Cand) = .empty,
    undo: std.ArrayList(Undo) = .empty,
    saved_exits: std.ArrayList(Exit) = .empty,
    saved_exit_facts: std.ArrayList(Fact) = .empty,

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        s.kind.deinit(gpa);
        s.version.deinit(gpa);
        s.value.deinit(gpa);
        s.facts.deinit(gpa);
        s.exits.deinit(gpa);
        s.exit_facts.deinit(gpa);
        s.results.deinit(gpa);
        s.stored.deinit(gpa);
        s.loads.deinit(gpa);
        s.exact.deinit(gpa);
        s.cands.deinit(gpa);
        s.undo.deinit(gpa);
        s.saved_exits.deinit(gpa);
        s.saved_exit_facts.deinit(gpa);
    }
};

/// `constant`: a `*const` alloc stored at most once (`stored_once` while
/// `classify` counts).
const Kind = enum(u8) { other, variable, constant, stored_once };

/// A value, compared exactly. Every term stands for one mathematical
/// integer at the point it is used: a constant for its value (`konst` a
/// `u64`, `neg` a negative `i64`, whatever the type it was written in), an
/// instruction for the value it computed (IR values never change), a
/// variable at a version for what it held then.
const Term = struct {
    tag: enum(u8) { none, konst, neg, inst, variable, interned, len_inst, len_variable, len_interned },
    a: u32 = 0,
    b: u32 = 0,

    const none: Term = .{ .tag = .none };

    fn eql(x: Term, y: Term) bool {
        return x.tag == y.tag and x.a == y.a and x.b == y.b;
    }

    fn konst(v: u64) Term {
        return .{ .tag = .konst, .a = @truncate(v), .b = @truncate(v >> 32) };
    }

    fn neg(v: i64) Term {
        const u: u64 = @bitCast(v);
        return .{ .tag = .neg, .a = @truncate(u), .b = @truncate(u >> 32) };
    }

    fn isConst(t: Term) bool {
        return t.tag == .konst or t.tag == .neg;
    }

    /// A constant's value.
    fn value(t: Term) i128 {
        const u = @as(u64, t.b) << 32 | t.a;
        return if (t.tag == .neg) @as(i64, @bitCast(u)) else u;
    }
};

/// `a op b` holds between the operands' values, compared as integers of
/// `signed` and `bits` (the compare's operand type), which bound a value
/// that only the fact bounds.
const Fact = struct {
    op: Op,
    signed: bool,
    bits: u8,
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

/// A candidate fact at a loop's start: `v + c op y`, with `v` variable
/// `v`'s value there (`base`, the variable at the loop's entry stamp), `c`
/// added exactly, and `y` and `bits` as in a `Fact` (unsigned).
const Cand = struct {
    v: u32,
    base: Term,
    c: u64,
    op: Op,
    bits: u8,
    y: Term,
};

/// An instruction as it was before a speculative walk changed it.
const Undo = struct {
    i: u32,
    tag: Inst.Tag,
    data: Inst.Data,
    exact: bool,
};

/// `x + c`, through additions of constants to unsigned values of `bits`
/// (0 when there is no addition).
const Offset = struct { x: Term, c: u64, bits: u16 };

pub fn run(gpa: Allocator, ip: *const InternPool, ir: *Ir, scratch: *Scratch) Allocator.Error!Stats {
    // No branch, no check.
    if (std.mem.indexOfScalar(Inst.Tag, ir.instructions.items(.tag), .cond_br) == null) return .{};
    const n = ir.instructions.len;
    try scratch.kind.resize(gpa, n);
    try scratch.version.resize(gpa, n);
    try scratch.value.resize(gpa, n);
    scratch.facts.clearRetainingCapacity();
    scratch.exits.clearRetainingCapacity();
    scratch.results.clearRetainingCapacity();
    scratch.exit_facts.clearRetainingCapacity();
    scratch.stored.clearRetainingCapacity();
    try scratch.loads.resize(gpa, n);
    @memset(scratch.loads.items, .none);
    try scratch.exact.resize(gpa, n, false);
    scratch.exact.unsetAll();
    classify(ip, ir, scratch.kind.items);
    var w: Walker = .{ .gpa = gpa, .ip = ip, .ir = ir, .s = scratch };
    try w.body(ir.mainBody());
    return w.stats;
}

/// Which allocs are variables (only loaded from and stored to, never
/// volatile) and which `*const` allocs hold one value. Any other use of
/// an alloc (an address taken, passed, cast, or stored) makes it `other`,
/// so nothing but its own loads and stores can read or write a variable:
/// no call, store through a pointer, or other thread reaches it.
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
        else => Ssa.forEachOperand(ir, @fromBackingInt(@intCast(i)), e),
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
    /// The loop being walked with candidate facts at its start
    /// (`Scratch.cands`), and whether they held at each `repeat` so far.
    spec: ?struct { loop: Inst.Index, ok: bool } = null,

    fn tick(w: *Walker) u32 {
        w.clock += 1;
        return w.clock;
    }

    fn body(w: *Walker, insts: []const Inst.Index) Allocator.Error!void {
        for (insts) |inst| try w.instruction(inst);
    }

    /// Forgets the values of the variables stored since `from` in
    /// `stored`: paths that stored them merge here, so after this point a
    /// variable may hold any of their values, and gets a version no fact
    /// names.
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
            // A store changes only its own alloc: a variable's address
            // goes nowhere else (`classify`), so no other store, call, or
            // write through a pointer reaches it. The variable's next
            // version holds the stored value; an undefined value is
            // unknown, since two undefined values need not be equal.
            .store => {
                const p = data.bin_op.lhs.toIndex() orelse return;
                const pi = @backingInt(p);
                const v: Term = if (w.isUndef(data.bin_op.rhs)) .none else w.term(data.bin_op.rhs);
                switch (s.kind.items[pi]) {
                    .variable => {
                        s.version.items[pi] = w.tick();
                        s.value.items[pi] = v;
                        try s.stored.append(w.gpa, pi);
                    },
                    // Stored on one path, read after paths merge, it holds
                    // nothing known there (`merge`).
                    .constant => {
                        s.value.items[pi] = v;
                        try s.stored.append(w.gpa, pi);
                    },
                    .other, .stored_once => {},
                }
            },
            .load => s.loads.items[ii] = w.loadTerm(inst, data),
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
                // A body whose only exit is the `br` to this block that ends
                // it ran every store at its top level before leaving, so
                // they hold after it; stores in nested bodies were merged
                // there. Any other shape merges.
                const last: ?Inst.Index = if (insts.len == 0) null else insts[insts.len - 1];
                const straight = exit.count == 1 and last != null and
                    ir.instructions.items(.tag)[@backingInt(last.?)] == .br and
                    ir.instructions.items(.data)[@backingInt(last.?)].br.block_inst == inst;
                if (!straight) w.merge(from);
                // What held at every `br` to the block holds after it,
                // when those are its only exits: its body ends in an
                // instruction that does not continue.
                const closed = last != null and ir.typeOfIndex(last.?, w.ip) == .noreturn_type;
                if (exit.count != 0 and closed) try s.facts.appendSlice(w.gpa, s.exit_facts.items[exit.start..][0..exit.len]);
                s.exit_facts.shrinkRetainingCapacity(exit_start);
            },
            // The body is walked once. Facts found in it are dropped at its
            // end: they held in one iteration, not before the next. Loads
            // in it of variables not stored since its entry are the
            // variable at the entry stamp, which no fact from before the
            // loop names, since a later store reaches them through the
            // back edge.
            //
            // Facts from before the loop on a variable it loads become
            // candidates at its start (`speculate`): the body is walked
            // assuming them, and they are kept if they hold again at every
            // `repeat`, by induction over the iterations. Otherwise every
            // decision of that walk is undone and the body walked again
            // without them.
            .loop => {
                const x = ir.extraData(Ir.Block, data.ty_pl.payload);
                const insts = ir.bodySlice(x.end, x.data.body_len);
                const depth = s.facts.items.len;
                const from = s.stored.items.len;
                const outer = w.stamp;
                if (w.spec == null and try w.speculate(inst, insts)) {
                    s.facts.shrinkRetainingCapacity(depth);
                    w.merge(from);
                    return;
                }
                w.stamp = w.tick();
                try w.body(insts);
                w.stamp = outer;
                s.facts.shrinkRetainingCapacity(depth);
                w.merge(from);
            },
            // A back edge of the loop walked with candidates: each must
            // hold for the variable's value here, the next iteration's
            // start (`repeatHolds`).
            .repeat => if (w.spec) |*sp| if (sp.loop == data.repeat.loop_inst and sp.ok) {
                sp.ok = w.repeatHolds();
            },
            .br => {
                try w.exitTo(data.br.block_inst);
                try w.result(data.br.block_inst, data.br.operand);
            },
            .cond_br => {
                const x = ir.extraData(Ir.CondBr, data.pl_op.payload);
                const then_body = ir.bodySlice(x.end, x.data.then_body_len);
                const else_body = ir.bodySlice(x.end + then_body.len, x.data.else_body_len);
                const cond = data.pl_op.operand;
                // Only Sema's own branches: those the user wrote are
                // `-ffuzz` coverage points.
                const check = cond.toIndex() != null and @as(u32, @bitCast(x.data.cover)) == 0 and (isCold(ir, then_body) or isCold(ir, else_body));
                // A check is decided only when a fact proves which side
                // runs, and only toward the side that passes: the failing
                // side never becomes the only one. Otherwise each side
                // learns its condition (and the negation), and the stores
                // of the then side are forgotten before the else side.
                if (check) w.stats.checks += 1;
                if (check) w.markChecked(cond, isCold(ir, then_body));
                if (check) if (w.decide(cond)) |c| if (!isCold(ir, if (c) then_body else else_body)) {
                    // The check passes (never decided toward its failure).
                    w.stats.proven += 1;
                    if (w.checked_op) |op| try w.wrap(op);
                    try w.changing(ii);
                    ir.instructions.items(.data)[ii].pl_op.operand = .fromInterned(if (c) .bool_true else .bool_false);
                    return w.body(if (c) then_body else else_body);
                };
                // A check of `a and b` (a switch prong's range) with `a`
                // proven checks `b` alone.
                if (check) if (cond.toIndex()) |ci| if (ir.instructions.items(.tag)[@backingInt(ci)] == .bit_and) {
                    const both = ir.instructions.items(.data)[@backingInt(ci)].bin_op;
                    if (w.decide(both.lhs) == true) {
                        try w.changing(ii);
                        ir.instructions.items(.data)[ii].pl_op.operand = both.rhs;
                    } else if (w.decide(both.rhs) == true) {
                        try w.changing(ii);
                        ir.instructions.items(.data)[ii].pl_op.operand = both.lhs;
                    }
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
    /// hold at its other `br`s too. Facts name values, not places (a
    /// variable's term has its version), so one that held at every `br`
    /// still holds after the block; a store after it makes a new version
    /// no fact names.
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

    /// A `br` exiting `block` with `operand`: the bounds of the block's
    /// value.
    fn result(w: *Walker, block: Inst.Index, operand: Inst.Ref) Allocator.Error!void {
        _ = w.intInfo(block.toRef()) orelse return;
        const t = w.term(operand);
        const gop = try w.s.results.getOrPut(w.gpa, @backingInt(block));
        if (!t.isConst()) {
            gop.value_ptr.* = poisoned;
            return;
        }
        const v = t.value();
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .lo = v, .hi = v };
        } else if (gop.value_ptr.lo <= gop.value_ptr.hi) {
            gop.value_ptr.lo = @min(gop.value_ptr.lo, v);
            gop.value_ptr.hi = @max(gop.value_ptr.hi, v);
        }
    }

    const poisoned: Range = .{ .lo = 1, .hi = 0 };

    /// The value `r` is, as a term.
    fn term(w: *const Walker, r: Inst.Ref) Term {
        const ip = w.ip;
        if (r.toInterned()) |v| {
            if (ip.keyTag(v) == .int) {
                if (ip.intValue(u64, v)) |k| return .konst(k);
                if (ip.intValue(i64, v)) |k| return .neg(k);
            }
            return .{ .tag = .interned, .a = @backingInt(v) };
        }
        const ir = w.ir;
        const i = r.toIndex().?;
        const data = ir.instructions.items(.data)[@backingInt(i)];
        switch (ir.instructions.items(.tag)[@backingInt(i)]) {
            // As the walk found it there (`loadTerm`).
            .load => {
                const t = w.s.loads.items[@backingInt(i)];
                if (t.tag != .none) return t;
            },
            // Equal slices have equal lengths; a `slice` has the length
            // it was made with.
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
            // A widening cast of the same signedness keeps the value (terms
            // are values, not bit patterns; `Fact.bits` bounds them).
            .intcast => if (w.intInfo(data.ty_op.operand)) |from| if (w.intInfo(r)) |to| {
                if (from.signedness == to.signedness and from.bits <= to.bits) return w.term(data.ty_op.operand);
            },
            else => {},
        }
        return .{ .tag = .inst, .a = @backingInt(i) };
    }

    /// The term of load `inst` where the walk reaches it: a variable's
    /// value is its last store's when that store is in this iteration of
    /// the innermost loop and known; else the variable at its version,
    /// which changes at every store and merge; else, if no store reached
    /// it since the innermost loop's entry, the variable at that entry
    /// (`stamp`), since a store later in the loop reaches the entry through
    /// the back edge. A `*const` alloc holds the value stored, while no
    /// merge forgot it.
    fn loadTerm(w: *const Walker, inst: Inst.Index, data: Inst.Data) Term {
        const s = w.s;
        if (data.ty_op.operand.toIndex()) |p| {
            const pi = @backingInt(p);
            switch (s.kind.items[pi]) {
                .variable => return w.varTerm(pi),
                .constant => {
                    const v = s.value.items[pi];
                    if (v.tag != .none) return v;
                },
                .other, .stored_once => {},
            }
        }
        return .{ .tag = .inst, .a = @backingInt(inst) };
    }

    /// What variable `pi` holds here (`loadTerm`).
    fn varTerm(w: *const Walker, pi: u32) Term {
        const s = w.s;
        const ver = s.version.items[pi];
        if (ver > w.stamp) {
            const v = s.value.items[pi];
            return if (v.tag != .none) v else .{ .tag = .variable, .a = pi, .b = ver };
        }
        return .{ .tag = .variable, .a = pi, .b = w.stamp };
    }

    fn isUndef(w: *const Walker, r: Inst.Ref) bool {
        const v = r.toInterned() orelse return false;
        return w.ip.keyTag(v) == .undef;
    }

    /// For `x + 1`, `x`. With `exact`, only an addition that cannot have
    /// wrapped: an overflow operation's value, which is read only after
    /// its check passed (or without safety, where overflow is illegal), or
    /// one `wrap` made from such. Without, also `+%`: `x + 1 <= y` from
    /// `x < y` needs no more, since `x < y <= max` keeps `x + 1` exact.
    fn plusOne(w: *const Walker, t: Term, exact: bool) ?Term {
        if (t.tag != .inst) return null;
        const ir = w.ir;
        const data = ir.instructions.items(.data)[t.a];
        const bin: Ir.Bin = switch (ir.instructions.items(.tag)[t.a]) {
            .add_wrap => if (exact and !w.s.exact.isSet(t.a)) return null else .{ .lhs = data.bin_op.lhs, .rhs = data.bin_op.rhs },
            .struct_field_val => blk: {
                const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
                const op = sf.operand.toIndex() orelse return null;
                if (sf.index != 0 or ir.instructions.items(.tag)[@backingInt(op)] != .add_with_overflow) return null;
                // `@addWithOverflow(x, 1)[0]` without a check wraps.
                if (exact and !w.s.exact.isSet(@backingInt(op))) return null;
                break :blk ir.extraData(Ir.Bin, ir.instructions.items(.data)[@backingInt(op)].ty_pl.payload).data;
            },
            else => return null,
        };
        const l = w.term(bin.lhs);
        const r = w.term(bin.rhs);
        if (r.isConst() and r.value() == 1) return l;
        if (l.isConst() and l.value() == 1) return r;
        return null;
    }

    /// `t` as `x + c`, through additions of a constant to an unsigned value
    /// of one type, at most 8 deep. With `exact`, only through additions
    /// that cannot have wrapped (as `plusOne`), so `t` is `x + c`. Without,
    /// also through `+%`: `t` is then `x + c` only where the caller shows
    /// `x + c` at most the maximum of `bits`, since every partial sum is
    /// at most the whole (the constants are not negative) and so none
    /// wrapped.
    fn offset(w: *const Walker, t: Term, exact: bool) Offset {
        const ir = w.ir;
        var o: Offset = .{ .x = t, .c = 0, .bits = 0 };
        for (0..8) |_| {
            if (o.x.tag != .inst) break;
            const data = ir.instructions.items(.data)[o.x.a];
            const bin: Ir.Bin = switch (ir.instructions.items(.tag)[o.x.a]) {
                .add_wrap => if (exact and !w.s.exact.isSet(o.x.a)) break else .{ .lhs = data.bin_op.lhs, .rhs = data.bin_op.rhs },
                .struct_field_val => blk: {
                    const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
                    const op = sf.operand.toIndex() orelse break;
                    if (sf.index != 0 or ir.instructions.items(.tag)[@backingInt(op)] != .add_with_overflow) break;
                    if (exact and !w.s.exact.isSet(@backingInt(op))) break;
                    break :blk ir.extraData(Ir.Bin, ir.instructions.items(.data)[@backingInt(op)].ty_pl.payload).data;
                },
                else => break,
            };
            const info = w.intInfo(bin.lhs) orelse break;
            if (info.signedness == .signed or (o.bits != 0 and info.bits != o.bits)) break;
            const l = w.term(bin.lhs);
            const r = w.term(bin.rhs);
            const k: u64, const rest = if (r.tag == .konst) .{ @intCast(r.value()), l } else if (l.tag == .konst) .{ @intCast(l.value()), r } else break;
            o.c = std.math.add(u64, o.c, k) catch break;
            o.bits = info.bits;
            o.x = rest;
        }
        return o;
    }

    /// Whether `x + d < y` (`.lt`) or `x + d <= y` (`.le`, when not the
    /// first) follows from a fact or loop candidate, for any `y` when
    /// null. From an unsigned `x + c < y` or `x + c <= y` whose left side
    /// is exactly `x + c` (`offset`) and `d <= c`: `x + d <= x + c`, and
    /// `x + d < x + c` when `d < c`. Only facts of types at most `bits`
    /// wide (any when 0) count, so `x + d` is at most `y`, at most the
    /// maximum of `bits`.
    fn bound(w: *const Walker, x: Term, d: u64, y: ?Term, bits: u16) ?Op {
        var best: ?Op = null;
        for (w.recent()) |g| {
            if (g.signed or (g.op != .lt and g.op != .le) or (bits != 0 and g.bits > bits)) continue;
            if (y) |b| if (!g.b.eql(b)) continue;
            if (g.a.tag != .inst and !g.a.eql(x)) continue;
            const o = w.offset(g.a, true);
            if (!o.x.eql(x) or o.c < d) continue;
            if (g.op == .lt or o.c > d) return .lt;
            best = .le;
        }
        for (w.s.cands.items) |g| {
            if ((bits != 0 and g.bits > bits) or !g.base.eql(x) or g.c < d) continue;
            if (y) |b| if (!g.y.eql(b)) continue;
            if (g.op == .lt or g.c > d) return .lt;
            best = .le;
        }
        return best;
    }

    /// Whether unsigned `f`, `a < b` or `a <= b`, follows by `bound` from
    /// `a` as `x + d` (`offset`; no addition in it wrapped, since `bound`
    /// shows `x + d` within its type), or holds as `x + c <= x + d` (`<`
    /// when `c < d`) with `a` and `b` exactly those (`isExact`).
    fn offsetHolds(w: *const Walker, f: Fact) bool {
        if (f.signed or (f.op != .lt and f.op != .le)) return false;
        const a = w.offset(f.a, false);
        if (w.bound(a.x, a.c, f.b, a.bits)) |op| if (f.op == .le or op == .lt) return true;
        const b = w.offset(f.b, false);
        if (!a.x.eql(b.x) or a.c > b.c or (f.op == .lt and a.c == b.c)) return false;
        return w.isExact(f.a, a) and w.isExact(f.b, b);
    }

    /// Whether `t` is exactly `o`, its `offset`: no addition in it can have
    /// wrapped, or `bound` shows the sum within its type.
    fn isExact(w: *const Walker, t: Term, o: Offset) bool {
        if (o.c == 0) return true;
        const e = w.offset(t, true);
        return (e.x.eql(o.x) and e.c == o.c) or w.bound(o.x, o.c, null, o.bits) != null;
    }

    /// For a loop about to be walked, candidate facts at its start: each
    /// unsigned `x + c < y` (or `<=`) before it, its left side exactly `x +
    /// c` (`offset`), with `x` what a variable holds there. In the body,
    /// loads of the variable not after a store are the variable at the
    /// loop's entry stamp, which the candidate names. Walks the body
    /// assuming them (`spec`); returns whether they held at every
    /// `repeat`, and else undoes what that walk changed.
    fn speculate(w: *Walker, loop: Inst.Index, insts: []const Inst.Index) Allocator.Error!bool {
        const s = w.s;
        const gpa = w.gpa;
        const stamp = w.tick();
        s.cands.clearRetainingCapacity();
        for (w.recent()) |g| {
            if (g.signed or (g.op != .lt and g.op != .le)) continue;
            const o = w.offset(g.a, true);
            const v = w.variableOf(o.x) orelse continue;
            try s.cands.append(gpa, .{ .v = v, .base = .{ .tag = .variable, .a = v, .b = stamp }, .c = o.c, .op = g.op, .bits = g.bits, .y = g.b });
            if (s.cands.items.len == 8) break;
        }
        if (s.cands.items.len == 0) return false;
        // What a failed walk must restore.
        const depth = s.facts.items.len;
        const stats = w.stats;
        const from = s.stored.items.len;
        s.undo.clearRetainingCapacity();
        s.saved_exits.clearRetainingCapacity();
        try s.saved_exits.appendSlice(gpa, s.exits.items);
        s.saved_exit_facts.clearRetainingCapacity();
        try s.saved_exit_facts.appendSlice(gpa, s.exit_facts.items);
        // A candidate with no offset is a fact, which every rule reads.
        for (s.cands.items) |g| if (g.c == 0)
            try s.facts.append(gpa, .{ .op = g.op, .signed = false, .bits = g.bits, .a = g.base, .b = g.y });
        const outer = w.stamp;
        w.stamp = stamp;
        w.spec = .{ .loop = loop, .ok = true };
        try w.body(insts);
        const ok = w.spec.?.ok;
        w.spec = null;
        w.stamp = outer;
        s.cands.clearRetainingCapacity();
        if (ok) return true;
        const ir = w.ir;
        var k = s.undo.items.len;
        while (k > 0) {
            k -= 1;
            const u = s.undo.items[k];
            ir.instructions.items(.tag)[u.i] = u.tag;
            ir.instructions.items(.data)[u.i] = u.data;
            s.exact.setValue(u.i, u.exact);
        }
        w.stats = stats;
        s.facts.shrinkRetainingCapacity(depth);
        // Blocks push and pop their exits in balance.
        std.debug.assert(s.exits.items.len == s.saved_exits.items.len);
        @memcpy(s.exits.items, s.saved_exits.items);
        s.exit_facts.clearRetainingCapacity();
        try s.exit_facts.appendSlice(gpa, s.saved_exit_facts.items);
        // The walk again sees the variables at a new stamp; a `*const`
        // alloc stored in the loop was not stored before it.
        for (s.stored.items[from..]) |a| if (s.kind.items[a] == .constant) {
            s.value.items[a] = .none;
        };
        s.stored.shrinkRetainingCapacity(from);
        return false;
    }

    /// The variable that holds `x` here: `x` itself, or a known value of
    /// one of the last 32 variables stored.
    fn variableOf(w: *const Walker, x: Term) ?u32 {
        const s = w.s;
        if (x.tag == .variable) return if (w.varTerm(x.a).eql(x)) x.a else null;
        if (x.tag == .none) return null;
        const st = s.stored.items;
        for (0..@min(st.len, 32)) |j| {
            const v = st[st.len - 1 - j];
            if (s.kind.items[v] == .variable and w.varTerm(v).eql(x)) return v;
        }
        return null;
    }

    /// Whether every candidate holds at a `repeat`, for what its variable
    /// holds here: unchanged since the loop's start, by `bound` on the
    /// value itself, or as `x + c0` (`offset`) with `x + c0 + c op y` from
    /// `bound`, which also shows no addition in `x + c0` wrapped.
    fn repeatHolds(w: *const Walker) bool {
        for (w.s.cands.items) |g| {
            const now = w.varTerm(g.v);
            if (now.eql(g.base)) continue;
            // A fact on the value itself.
            if (w.bound(now, g.c, g.y, 0)) |op| if (g.op == .le or op == .lt) continue;
            const o = w.offset(now, false);
            const c = std.math.add(u64, o.c, g.c) catch return false;
            const op = w.bound(o.x, c, g.y, o.bits) orelse return false;
            if (g.op == .lt and op != .lt) return false;
        }
        return true;
    }

    /// Records instruction `i` before a speculative walk changes it.
    fn changing(w: *Walker, i: u32) Allocator.Error!void {
        if (w.spec == null) return;
        const ir = w.ir;
        try w.s.undo.append(w.gpa, .{ .i = i, .tag = ir.instructions.items(.tag)[i], .data = ir.instructions.items(.data)[i], .exact = w.s.exact.isSet(i) });
    }

    /// The integer type of `r`, if at most 64 bits.
    fn intInfo(w: *const Walker, r: Inst.Ref) ?Type.IntInfo {
        const ty = w.ir.typeOf(r, w.ip);
        if (Type.class(w.ip, ty) != .int) return null;
        const info = Type.intInfo(w.ip, ty);
        return if (info.bits <= 64 and info.bits > 0) info else null;
    }

    /// Records what holds where `cond` is `truth`: `!a` is `a` false, `a
    /// and b` true is both true, `a or b` false is both false, and a
    /// compare of integers is its fact, or the negation.
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
            // A compare of undefined values decides nothing.
            .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => |tag| {
                const info = w.intInfo(data.bin_op.lhs) orelse return;
                if (w.isUndef(data.bin_op.lhs) or w.isUndef(data.bin_op.rhs)) return;
                var f = fact(tag, w.term(data.bin_op.lhs), w.term(data.bin_op.rhs), info);
                if (!truth) f = negate(f);
                try w.s.facts.append(w.gpa, f);
            },
            else => {},
        }
    }

    /// A check whose failing side (the then side if `then_cold`) is where
    /// an overflow operation overflowed: past it, the operation's value
    /// did not wrap.
    fn markChecked(w: *Walker, cond: Inst.Ref, then_cold: bool) void {
        const ir = w.ir;
        const i = cond.toIndex() orelse return;
        switch (ir.instructions.items(.tag)[@backingInt(i)]) {
            .cmp_eq, .cmp_neq, .cmp_lt, .cmp_lte, .cmp_gt, .cmp_gte => {},
            else => return,
        }
        const bit = ir.instructions.items(.data)[@backingInt(i)].bin_op.lhs.toIndex() orelse return;
        if (ir.instructions.items(.tag)[@backingInt(bit)] != .struct_field_val) return;
        const sf = ir.extraData(Ir.StructField, ir.instructions.items(.data)[@backingInt(bit)].ty_pl.payload).data;
        if (sf.index != 1) return;
        const op = sf.operand.toIndex() orelse return;
        if (ir.instructions.items(.tag)[@backingInt(op)] != .add_with_overflow) return;
        const true_if_ovf = Ssa.ovfBitCmp(ir, w.ip, i, @backingInt(bit)) orelse return;
        if (true_if_ovf == then_cold) w.s.exact.set(@backingInt(op));
    }

    /// An overflow operation proven not to overflow: its value field,
    /// which Sema reads right after it, becomes the wrapping operation, so
    /// the overflow bit is not computed.
    fn wrap(w: *Walker, op: Inst.Index) Allocator.Error!void {
        const ir = w.ir;
        const next = @backingInt(op) + 1;
        if (next >= ir.instructions.len or ir.instructions.items(.tag)[next] != .struct_field_val) return;
        const sf = ir.extraData(Ir.StructField, ir.instructions.items(.data)[next].ty_pl.payload).data;
        if (sf.index != 0 or sf.operand != op.toRef()) return;
        try w.changing(next);
        const bin = ir.extraData(Ir.Bin, ir.instructions.items(.data)[@backingInt(op)].ty_pl.payload).data;
        ir.instructions.items(.tag)[next] = switch (ir.instructions.items(.tag)[@backingInt(op)]) {
            .add_with_overflow => .add_wrap,
            .sub_with_overflow => .sub_wrap,
            else => .mul_wrap,
        };
        ir.instructions.items(.data)[next] = .{ .bin_op = .{ .lhs = bin.lhs, .rhs = bin.rhs } };
        w.s.exact.set(next);
    }

    /// Whether the facts decide condition `cond`.
    fn decide(w: *Walker, cond: Inst.Ref) ?bool {
        w.checked_op = null;
        const i = cond.toIndex() orelse return null;
        const ir = w.ir;
        const data = ir.instructions.items(.data)[@backingInt(i)];
        switch (ir.instructions.items(.tag)[@backingInt(i)]) {
            .bit_and => {
                const both = w.decide(data.bin_op.lhs) == true and w.decide(data.bin_op.rhs) == true;
                w.checked_op = null;
                return if (both) true else null;
            },
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
                if (w.isUndef(lhs) or w.isUndef(rhs)) return null;
                return w.proves(fact(tag, w.term(lhs), w.term(rhs), info), info);
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
        // The exact result's bounds, from the operands' (in i128, which
        // holds any sum, difference, or product of 64-bit values but the
        // largest products, which `mul` rejects), within the type's.
        switch (tag) {
            .add_with_overflow => {
                if (ra.hi + rb.hi <= lim.hi and ra.lo + rb.lo >= lim.lo) return true;
                // `t + k`, `t` as `x + c` (`offset`), when `bound` gives `x +
                // c + k <= y` from a fact of a type no wider than this one
                // (or the chain's), so the sum is at most its maximum.
                if (!signed) if (if (b.tag == .konst) .{ a, b } else if (a.tag == .konst) .{ b, a } else null) |p| {
                    const o = w.offset(p[0], false);
                    const c = std.math.add(u64, o.c, @intCast(p[1].value())) catch return false;
                    const bits: u16 = if (o.bits == 0) info.bits else @min(o.bits, info.bits);
                    if (w.bound(o.x, c, null, bits) != null) return true;
                };
                return false;
            },
            .sub_with_overflow => {
                if (ra.lo - rb.hi >= lim.lo and ra.hi - rb.lo <= lim.hi) return true;
                // `a - b` with `b <= a`, unsigned: `0 <= a - b <= a`.
                if (!signed and w.holds(.{ .op = .le, .signed = false, .bits = @intCast(info.bits), .a = b, .b = a })) return true;
                return false;
            },
            else => {
                // Unsigned, so both operands are at least 0.
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

    /// The bounds of the value of `t`, an operand of type `info`: those
    /// of the type (a term shared with a narrower value through a widening
    /// cast has a value within them too), narrowed by each fact on `t` with
    /// a constant on the other side, and by `t < u` to one less than the
    /// largest value of `u`'s type (the fact's, not `info`), and `u < t`
    /// likewise. A block exited only with constants (all its `br`s are
    /// walked before its value is used) has their bounds. A wrapping
    /// addition or subtraction whose operands' bounds keep the exact
    /// result within its own type (not `info`, which may be wider) computed
    /// the exact result, so it has the exact result's bounds.
    fn range(w: *const Walker, t: Term, info: Type.IntInfo) Range {
        return w.rangeIn(t, info, 2);
    }

    fn rangeIn(w: *const Walker, t: Term, info: Type.IntInfo, depth: u8) Range {
        if (t.isConst()) {
            const v = t.value();
            return .{ .lo = v, .hi = v };
        }
        const signed = info.signedness == .signed;
        var r = limits(info);
        if (t.tag == .inst) {
            const ir = w.ir;
            const data = ir.instructions.items(.data)[t.a];
            switch (ir.instructions.items(.tag)[t.a]) {
                .block => if (w.s.results.get(t.a)) |b| if (b.lo <= b.hi) {
                    r = .{ .lo = @max(r.lo, b.lo), .hi = @min(r.hi, b.hi) };
                },
                .add_wrap, .sub_wrap => |tag| if (depth > 0) if (w.intInfo(@as(Inst.Index, @fromBackingInt(@intCast(t.a))).toRef())) |own| {
                    const a = w.rangeIn(w.term(data.bin_op.lhs), own, depth - 1);
                    const b = w.rangeIn(w.term(data.bin_op.rhs), own, depth - 1);
                    const exact: Range = if (tag == .add_wrap)
                        .{ .lo = a.lo + b.lo, .hi = a.hi + b.hi }
                    else
                        .{ .lo = a.lo - b.hi, .hi = a.hi - b.lo };
                    const lim = limits(own);
                    if (exact.lo >= lim.lo and exact.hi <= lim.hi) r = .{ .lo = @max(r.lo, exact.lo), .hi = @min(r.hi, exact.hi) };
                },
                else => {},
            }
        }
        for (w.recent()) |f| {
            if (f.signed != signed) continue;
            const lim = limits(.{ .signedness = info.signedness, .bits = f.bits });
            if (f.a.eql(t)) {
                const k: ?i128 = if (f.b.isConst()) f.b.value() else null;
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
                const k: ?i128 = if (f.a.isConst()) f.a.value() else null;
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

    /// Whether a fact implies `f`.
    fn holds(w: *const Walker, f: Fact) bool {
        for (w.recent()) |g| {
            if (g.signed != f.signed) continue;
            if (implies(g, f)) return true;
        }
        return false;
    }

    /// True or false if the facts decide `f`, a compare of operands of
    /// type `info`.
    fn proves(w: *const Walker, f: Fact, info: Type.IntInfo) ?bool {
        if (w.holds(f) or w.offsetHolds(f)) return true;
        if (w.holds(negate(f)) or w.offsetHolds(negate(f))) return false;
        // `x + 1 <= y` from `x < y`: then `x + 1 <= y <= max`, so even a
        // wrapping `+%` computed `x + 1` exactly.
        if (f.op == .le) if (w.plusOne(f.a, false)) |x| {
            if (w.holds(with(f, .lt, x, f.b))) return true;
        };
        // `x < y` from `x + 1 <= y` (an earlier slice end check), only for
        // an addition that did not wrap: `maxInt +% 1` is 0.
        if (f.op == .lt) for (w.recent()) |g| {
            if (g.op != .le or g.signed != f.signed or !g.b.eql(f.b)) continue;
            if (w.plusOne(g.a, true)) |x| if (x.eql(f.a)) return true;
        };
        // Bounds: `a < b` when every value of `a` is below every value of
        // `b`, false when none is, and so on.
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

/// `a tag b` as a fact, for operands of type `info`. `>` and `>=` swap
/// their operands into `<` and `<=`.
fn fact(tag: Inst.Tag, a: Term, b: Term, info: Type.IntInfo) Fact {
    const f: Fact = .{ .op = undefined, .signed = info.signedness == .signed, .bits = @intCast(info.bits), .a = a, .b = b };
    return switch (tag) {
        .cmp_lt => with(f, .lt, a, b),
        .cmp_lte => with(f, .le, a, b),
        .cmp_gt => with(f, .lt, b, a),
        .cmp_gte => with(f, .le, b, a),
        .cmp_eq => with(f, .eq, a, b),
        .cmp_neq => with(f, .ne, a, b),
        else => unreachable,
    };
}

fn with(f: Fact, op: Op, a: Term, b: Term) Fact {
    var g = f;
    g.op = op;
    g.a = a;
    g.b = b;
    return g;
}

/// The fact that holds where `f` does not: integers are totally ordered.
fn negate(f: Fact) Fact {
    return switch (f.op) {
        .lt => with(f, .le, f.b, f.a),
        .le => with(f, .lt, f.b, f.a),
        .eq => with(f, .ne, f.a, f.b),
        .ne => with(f, .eq, f.a, f.b),
    };
}

/// Whether fact `g` alone implies `f` (same operands): `a < b` gives
/// `a <= b` and `a != b` both ways, `a == b` gives `a <= b` both ways.
/// Facts compare values, so this holds whatever their types' widths.
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
    const lt: Fact = .{ .op = .lt, .signed = false, .bits = 64, .a = x, .b = y };
    try std.testing.expect(implies(lt, .{ .op = .le, .signed = false, .bits = 64, .a = x, .b = y }));
    try std.testing.expect(implies(lt, .{ .op = .ne, .signed = false, .bits = 64, .a = y, .b = x }));
    try std.testing.expect(!implies(lt, .{ .op = .lt, .signed = false, .bits = 64, .a = y, .b = x }));
    try std.testing.expect(implies(negate(lt), .{ .op = .le, .signed = false, .bits = 64, .a = y, .b = x }));
}
