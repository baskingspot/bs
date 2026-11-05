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
//! that stored it. A `*const` alloc is the value stored to it, a load of
//! one of its fields that field of the value, and
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
    exact: std.bit_set.Dynamic = .{},
    /// The loop walked with candidate facts at its start (`Walker.spec`):
    /// the candidates, the instructions its decisions changed, and the
    /// enclosing blocks' exits before it.
    cands: std.ArrayList(Cand) = .empty,
    undo: std.ArrayList(Undo) = .empty,
    saved_exits: std.ArrayList(Exit) = .empty,
    /// Per instruction numbered (`Walker.number`): the term of the first
    /// instruction that computed the same value (`Term.none` if none).
    canon: std.ArrayList(Term) = .empty,
    /// The first instruction per value computed (`Key`), among those
    /// that run on every path to the point walked (`Walker.number`).
    numbers: std.AutoHashMapUnmanaged(Key, Term) = .empty,
    /// The keys of `numbers` in the order added, for `Walker.dropNumbers`.
    nlog: std.ArrayList(Key) = .empty,
    /// What `numbers` added in a block held at its first `br`
    /// (`Exit.nsnap`).
    nsnaps: std.ArrayList(NumberSnap) = .empty,
    /// Per `bool` block: what held at each of its exits with a value that
    /// may be true, and with one that may be false (`cond_exit_facts`),
    /// then, once walked, both (`block_facts`, from `start`).
    cond_exit_facts: std.ArrayList(Fact) = .empty,
    snaps: std.ArrayList(Snap) = .empty,
    /// What `Walker.setVar` changed: each variable's version and value
    /// before.
    vlog: std.ArrayList(VarState) = .empty,
    block_facts: std.ArrayList(Fact) = .empty,
    bool_blocks: std.AutoHashMapUnmanaged(u32, BoolFacts) = .empty,
    /// Per load of a slice whose length a store just before wrote
    /// (`Walker.forwardStore`): that length.
    load_lens: std.AutoHashMapUnmanaged(u32, Term) = .empty,

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        s.load_lens.deinit(gpa);
        s.canon.deinit(gpa);
        s.numbers.deinit(gpa);
        s.nlog.deinit(gpa);
        s.nsnaps.deinit(gpa);
        s.cond_exit_facts.deinit(gpa);
        s.snaps.deinit(gpa);
        s.vlog.deinit(gpa);
        s.block_facts.deinit(gpa);
        s.bool_blocks.deinit(gpa);
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
        s.* = undefined;
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
/// (`exit_facts[facts.start..][0..facts.len]`, with `facts.count` the
/// number of `br`s).
const Exit = struct {
    block: Inst.Index,
    depth: u32,
    facts: Span = .{},
    /// The value of the last `br` (the block's value when `count` is 1).
    operand: Inst.Ref = undefined,
    /// For a `bool` block: per truth, how many `br`s may exit it with
    /// that value, and the facts that held at all of them, the value's
    /// own included (`cond_exit_facts[start..][0..len]`).
    is_bool: bool = false,
    cond: [2]Span = .{ .{}, .{} },
    /// `stored`'s length at the block's start, and for its first `br`,
    /// when at most 32 variables were stored since: what they held there
    /// (`snaps[snap.start..][0..snap.len]`, with `snap.count` 1), and
    /// the memory version.
    from: u32 = 0,
    snap: Span = .{},
    snap_mem: u32 = 0,
    /// `nlog`'s length at the block's start, and for its first `br`, when
    /// `numbers` added at most 64 values since: those values
    /// (`nsnaps[nsnap.start..][0..nsnap.len]`, with `nsnap.count` 1).
    nfrom: u32 = 0,
    nsnap: Span = .{},
};

const NumberSnap = struct { key: Key, value: Term };

const VarState = struct { v: u32, version: u32, value: Term };

/// What variable or `*const` alloc `v` held at a block's first `br`
/// (`Exit.snap`).
const Snap = struct { v: u32, value: Term };

const Span = struct { count: u32 = 0, start: u32 = 0, len: u32 = 0 };

/// What held where a walked `bool` block's value was false (`[0]`) and
/// true (`[1]`): `block_facts[start..]`, the false facts first.
const BoolFacts = struct { start: u32, len: [2]u32 };

/// A value an instruction computes, from what it computes it from: the
/// operation, its result type, its operands' terms, and a field index,
/// or for a load the memory version it reads (`Walker.mem`).
const Key = struct {
    tag: Inst.Tag,
    ty: Index,
    x: u32,
    a: Term,
    b: Term,
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

/// `fuzz`: under `-ffuzz`, branches the user wrote are coverage points
/// and stay.
pub fn run(gpa: Allocator, ip: *const InternPool, ir: *Ir, scratch: *Scratch, fuzz: bool) Allocator.Error!Stats {
    // No branch, no check.
    if (std.mem.findScalar(Inst.Tag, ir.instructions.items(.tag), .cond_br) == null) return .{};
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
    try scratch.canon.resize(gpa, n);
    @memset(scratch.canon.items, .none);
    scratch.numbers.clearRetainingCapacity();
    scratch.nlog.clearRetainingCapacity();
    scratch.nsnaps.clearRetainingCapacity();
    scratch.cond_exit_facts.clearRetainingCapacity();
    scratch.snaps.clearRetainingCapacity();
    scratch.vlog.clearRetainingCapacity();
    scratch.block_facts.clearRetainingCapacity();
    scratch.bool_blocks.clearRetainingCapacity();
    scratch.load_lens.clearRetainingCapacity();
    classify(ip, ir, scratch.kind.items);
    var w: Walker = .{ .gpa = gpa, .ip = ip, .ir = ir, .s = scratch, .fuzz = fuzz };
    try w.body(ir.mainBody());
    return w.stats;
}

/// Which allocs are variables (only loaded from and stored to, never
/// volatile) and which `*const` allocs hold one value, read also through
/// field pointers and casts to their own type (`allocOf`). Any other use
/// of an alloc (an address taken, passed, cast, or stored) makes it `other`,
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
        ir: *const Ir,
        ip: *const InternPool,
        kind: []Kind,
        const Self = @This();
        pub fn use(e: Self, r: Inst.Ref) void {
            const a = allocOf(e.ir, e.ip, r, true) orelse return;
            e.kind[a] = .other;
        }
    };
    const e: Escape = .{ .ir = ir, .ip = ip, .kind = kind };
    for (tags, datas, 0..) |tag, data, i| switch (tag) {
        .load => {},
        .store => {
            // A pointer into a `*const` alloc stored as a value (an
            // inlined `*const` parameter) reads it only: what loads it
            // back is a `*const` pointer, and writing through one is
            // illegal. Only initializing stores write a `*const` alloc,
            // through the alloc or its field pointers themselves.
            if (!constPtr(ir, ip, data.bin_op.rhs)) e.use(data.bin_op.rhs);
            const p = data.bin_op.lhs.toIndex() orelse continue;
            // A store into a field of a `*const` alloc (an initialization
            // field by field) makes it `other`.
            if (tags[@backingInt(p)] != .alloc) {
                e.use(data.bin_op.lhs);
                continue;
            }
            // A `*const` alloc stored twice (on two paths) is a variable.
            const k = &kind[@backingInt(p)];
            k.* = switch (k.*) {
                .constant => .stored_once,
                .stored_once => .variable,
                else => k.*,
            };
        },
        // A field pointer into a `*const` alloc, or the alloc cast to its
        // own type (a copy `forward.run` forwarded), reads it only through
        // its own loads; any other use of it is a use of the alloc.
        .struct_field_ptr, .bitcast => if (allocOf(ir, ip, @as(Inst.Index, @fromBackingInt(@intCast(i))).toRef(), false) == null)
            Ssa.forEachOperand(ir, @fromBackingInt(@intCast(i)), e),
        else => Ssa.forEachOperand(ir, @fromBackingInt(@intCast(i)), e),
    };
    for (kind) |*k| if (k.* == .stored_once) {
        k.* = .constant;
    };
}

/// The alloc `r` is, or a field pointer into, through casts to its own
/// type: with `all`, of any kind, else only a `*const` one when `r` is
/// derived from it (a variable's field pointer is a use of it).
fn allocOf(ir: *const Ir, ip: *const InternPool, r: Inst.Ref, all: bool) ?u32 {
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    var cur = r;
    var derived = false;
    while (cur.toIndex()) |idx| {
        const i = @backingInt(idx);
        switch (tags[i]) {
            .alloc => {
                if (derived and !Type.ptrInfo(ip, datas[i].ty).flags.is_const) return if (all) i else null;
                return i;
            },
            .struct_field_ptr => cur = ir.extraData(Ir.StructField, datas[i].ty_pl.payload).data.operand,
            .bitcast => {
                if (datas[i].ty_op.ty != ir.typeOf(datas[i].ty_op.operand, ip)) return null;
                cur = datas[i].ty_op.operand;
            },
            else => return null,
        }
        derived = true;
    }
    return null;
}

/// Whether `r` is a `*const` pointer to a `*const` alloc or into one
/// (`allocOf`).
fn constPtr(ir: *const Ir, ip: *const InternPool, r: Inst.Ref) bool {
    const a = allocOf(ir, ip, r, false) orelse return false;
    const alloc_ty = ir.instructions.items(.data)[a].ty;
    if (!Type.ptrInfo(ip, alloc_ty).flags.is_const) return false;
    return Type.ptrInfo(ip, ir.typeOf(r, ip)).flags.is_const;
}

/// The alloc `r` is, through casts to its own type, but not a field
/// pointer into one.
fn allocCast(ir: *const Ir, ip: *const InternPool, r: Inst.Ref) ?u32 {
    var cur = r;
    while (cur.toIndex()) |idx| {
        const i = @backingInt(idx);
        const data = ir.instructions.items(.data)[i];
        switch (ir.instructions.items(.tag)[i]) {
            .alloc => return i,
            .bitcast => {
                if (data.ty_op.ty != ir.typeOf(data.ty_op.operand, ip)) return null;
                cur = data.ty_op.operand;
            },
            else => return null,
        }
    }
    return null;
}

const Walker = struct {
    gpa: Allocator,
    ip: *const InternPool,
    ir: *Ir,
    s: *Scratch,
    fuzz: bool,
    /// Numbers versions and loop entries.
    clock: u32 = 1,
    /// The entry of the innermost loop being walked: a variable not stored
    /// since may hold what the loop's last iteration stored.
    stamp: u32 = 0,
    stats: Stats = .{},
    /// The overflow operation of the overflow check `decide` decided.
    checked_op: ?Inst.Index = null,
    /// `step`'s count, and how deep in `assume` and `decide` it is.
    steps: u32 = 0,
    nest: u32 = 0,
    /// The loop being walked with candidate facts at its start
    /// (`Scratch.cands`), and whether they held at each `repeat` so far.
    spec: ?struct { loop: Inst.Index, ok: bool } = null,
    /// The version of memory (all but variables and `*const` allocs, which
    /// only their own loads and stores reach) that a load reads here: it
    /// changes at each instruction that may write memory or let another
    /// thread's writes be seen (`writesMemory`), at each loop entry, and
    /// after each merge of paths one of which changed it. Between two
    /// changes no write happens on the path walked, so two loads of one
    /// address read one value (a write by another thread in between
    /// would be a data race, which is illegal; volatile loads are never
    /// numbered).
    mem: u32 = 1,
    /// When `mem` last changed, on any path walked.
    mem_changed: u32 = 0,

    fn tick(w: *Walker) u32 {
        w.clock += 1;
        return w.clock;
    }

    fn changeMem(w: *Walker) void {
        w.mem = w.tick();
        w.mem_changed = w.mem;
    }

    /// After paths that started at clock `from` merge: if one changed
    /// memory, what a load reads here is a new version.
    fn mergeMem(w: *Walker, from: u32) void {
        if (w.mem_changed > from) w.changeMem();
    }

    /// Walks a check's failing side, which only calls a `noreturn`
    /// handler (nothing in it reaches past it), without its memory
    /// changes.
    fn coldBody(w: *Walker, insts: []const Inst.Index) Allocator.Error!void {
        for (insts) |inst| switch (w.ir.instructions.items(.tag)[@backingInt(inst)]) {
            .block, .loop, .cond_br, .switch_br, .br, .repeat => return w.body(insts),
            else => {},
        };
        const mem = w.mem;
        const changed = w.mem_changed;
        try w.body(insts);
        w.mem = mem;
        w.mem_changed = changed;
    }

    fn body(w: *Walker, insts: []const Inst.Index) Allocator.Error!void {
        for (insts) |inst| try w.instruction(inst);
    }

    /// Forgets the values of the variables stored since `from` in
    /// `stored`: paths that stored them merge here, so after this point a
    /// variable may hold any of their values, and gets a version no fact
    /// names.
    fn merge(w: *Walker, from: usize) Allocator.Error!void {
        const s = w.s;
        if (s.stored.items.len == from) return;
        const v = w.tick();
        for (s.stored.items[from..]) |a| try w.setVar(a, v, .none);
        // Still stored, for an enclosing merge.
    }

    /// Sets what variable (or `*const` alloc) `a` holds, logging what it
    /// held for `rollback`.
    fn setVar(w: *Walker, a: u32, version: u32, value: Term) Allocator.Error!void {
        const s = w.s;
        try s.vlog.append(w.gpa, .{ .v = a, .version = s.version.items[a], .value = s.value.items[a] });
        s.version.items[a] = version;
        s.value.items[a] = value;
    }

    /// Undoes `setVar`s back to `vlog`'s length `log`: what the variables
    /// held where another side of a branch starts.
    fn rollback(w: *Walker, log: usize) void {
        const s = w.s;
        while (s.vlog.items.len > log) {
            const e = s.vlog.pop().?;
            s.version.items[e.v] = e.version;
            s.value.items[e.v] = e.value;
        }
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
                const p = data.bin_op.lhs.toIndex() orelse {
                    w.changeMem();
                    return w.forwardStore(data.bin_op.lhs, data.bin_op.rhs);
                };
                const pi = @backingInt(p);
                const v: Term = if (w.isUndef(data.bin_op.rhs)) .none else w.term(data.bin_op.rhs);
                switch (s.kind.items[pi]) {
                    .variable => {
                        try w.setVar(pi, w.tick(), v);
                        try s.stored.append(w.gpa, pi);
                    },
                    // Stored on one path, read after paths merge, it holds
                    // nothing known there (`merge`).
                    .constant => {
                        try w.setVar(pi, s.version.items[pi], v);
                        try s.stored.append(w.gpa, pi);
                    },
                    .other, .stored_once => {
                        w.changeMem();
                        try w.forwardStore(data.bin_op.lhs, data.bin_op.rhs);
                    },
                }
            },
            .load => {
                s.loads.items[ii] = try w.loadTerm(inst, data);
                // The length a store wrote into the slice loaded.
                const t = s.loads.items[ii];
                if (t.tag == .inst and Type.isSlice(w.ip, data.ty_op.ty)) {
                    const key: Key = .{ .tag = .slice_len, .ty = .none, .x = w.mem, .a = w.term(data.ty_op.operand), .b = .none };
                    if (s.numbers.get(key)) |len| try s.load_lens.put(w.gpa, t.a, len) else _ = s.load_lens.remove(t.a);
                }
            },
            .block => {
                const x = ir.extraData(Ir.Block, data.ty_pl.payload);
                const insts = ir.bodySlice(x.end, x.data.body_len);
                const depth = s.facts.items.len;
                const from = s.stored.items.len;
                const clock = w.clock;
                try s.exits.append(w.gpa, .{
                    .block = inst,
                    .depth = @intCast(depth),
                    .is_bool = data.ty_pl.ty == .bool_type,
                    .from = @intCast(from),
                    .nfrom = @intCast(s.nlog.items.len),
                });
                try w.body(insts);
                const exit = s.exits.pop().?;
                s.facts.shrinkRetainingCapacity(depth);
                // A block exited by one `br` has its value.
                if (exit.facts.count == 1 and data.ty_pl.ty != .void_type and data.ty_pl.ty != .noreturn_type)
                    s.canon.items[ii] = w.term(exit.operand);
                if (exit.is_bool) {
                    const start: u32 = @intCast(s.block_facts.items.len);
                    for (exit.cond) |c| try s.block_facts.appendSlice(w.gpa, s.cond_exit_facts.items[c.start..][0..c.len]);
                    try s.bool_blocks.put(w.gpa, ii, .{ .start = start, .len = .{ exit.cond[0].len, exit.cond[1].len } });
                }
                // A body whose only exit is the `br` to this block that ends
                // it ran every store at its top level before leaving, so
                // they hold after it; stores in nested bodies were merged
                // there. Any other shape merges.
                const last: ?Inst.Index = if (insts.len == 0) null else insts[insts.len - 1];
                const straight = exit.facts.count == 1 and last != null and
                    ir.instructions.items(.tag)[@backingInt(last.?)] == .br and
                    ir.instructions.items(.data)[@backingInt(last.?)].br.block_inst == inst;
                const closed = last != null and ir.typeOfIndex(last.?, w.ip) == .noreturn_type;
                if (exit.facts.count == 1 and exit.snap.count == 1 and closed and !straight) {
                    // Left only by its one `br` (the body does not end
                    // continuing): what held there holds after it, as a
                    // new version (a variable loaded in a loop there was
                    // the variable at the loop's entry, which a value
                    // names, not its version).
                    // Stores after it in the walk were on other paths.
                    try w.merge(from);
                    const v = w.tick();
                    for (s.snaps.items[exit.snap.start..][0..exit.snap.len]) |sn| try w.setVar(sn.v, v, sn.value);
                    w.mem = exit.snap_mem;
                } else if (!straight) {
                    try w.merge(from);
                    w.mergeMem(clock);
                }
                // Values numbered in the body: a straight body ran its own
                // (those of the bodies nested in it are forgotten there);
                // a body left by one `br` ran those numbered on the way to
                // it; else none is known to have run.
                if (!straight) {
                    w.dropNumbers(exit.nfrom);
                    if (exit.facts.count == 1 and exit.nsnap.count == 1 and closed)
                        for (s.nsnaps.items[exit.nsnap.start..][0..exit.nsnap.len]) |n| {
                            _ = try w.numberOf(n.key, n.value);
                        };
                }
                // What held at every `br` to the block holds after it,
                // when those are its only exits: its body ends in an
                // instruction that does not continue.
                if (exit.facts.count != 0 and closed) try s.facts.appendSlice(w.gpa, s.exit_facts.items[exit.facts.start..][0..exit.facts.len]);
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
                const nlen = s.nlog.items.len;
                // A write later in the loop reaches its start.
                w.changeMem();
                if (w.spec == null and try w.speculate(inst, insts)) {
                    s.facts.shrinkRetainingCapacity(depth);
                    w.dropNumbers(nlen);
                    try w.merge(from);
                    w.changeMem();
                    return;
                }
                w.stamp = w.tick();
                try w.body(insts);
                w.stamp = outer;
                s.facts.shrinkRetainingCapacity(depth);
                w.dropNumbers(nlen);
                try w.merge(from);
                w.changeMem();
            },
            // A back edge of the loop walked with candidates: each must
            // hold for the variable's value here, the next iteration's
            // start (`repeatHolds`).
            .repeat => if (w.spec) |*sp| if (sp.loop == data.repeat.loop_inst and sp.ok) {
                sp.ok = w.repeatHolds();
            },
            .br => {
                try w.exitTo(data.br.block_inst, data.br.operand);
                try w.result(data.br.block_inst, data.br.operand);
            },
            .cond_br => {
                const x = ir.extraData(Ir.CondBr, data.pl_op.payload);
                const then_body = ir.bodySlice(x.end, x.data.then_body_len);
                const else_body = ir.bodySlice(x.end + then_body.len, x.data.else_body_len);
                const cond = data.pl_op.operand;
                // Sema's own branches, and the user's (`if (!ok)
                // unreachable`, `std.debug.assert`) but under `-ffuzz`,
                // where they are coverage points.
                const check = cond.toIndex() != null and (!w.fuzz or @as(u32, @bitCast(x.data.cover)) == 0) and (isCold(ir, then_body) or isCold(ir, else_body));
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
                const mem = w.mem;
                const clock = w.clock;
                const log = s.vlog.items.len;
                const nlen = s.nlog.items.len;
                try w.assume(cond, true);
                try w.side(then_body);
                s.facts.shrinkRetainingCapacity(depth);
                w.dropNumbers(nlen);
                // The other side does not see the stores of this one.
                w.rollback(log);
                w.mem = mem;
                try w.assume(cond, false);
                try w.side(else_body);
                s.facts.shrinkRetainingCapacity(depth);
                w.dropNumbers(nlen);
                try w.merge(from);
                w.mergeMem(clock);
            },
            // Each case, like each side of a `cond_br`, sees neither the
            // facts nor the stores of the others. A case of one item or one
            // range knows the operand is it or in it; the else body, that
            // it is none of the items and outside the ranges that reach an
            // end of its type.
            .switch_br => {
                const from = s.stored.items.len;
                const depth = s.facts.items.len;
                const mem = w.mem;
                const clock = w.clock;
                const log = s.vlog.items.len;
                const nlen = s.nlog.items.len;
                const op = data.pl_op.operand;
                // A switch on an undefined value decides nothing.
                const info = if (w.isUndef(op)) null else w.intInfo(op);
                const t = w.term(op);
                var it = ir.switchCases(data.pl_op.payload);
                while (it.next()) |c| {
                    if (info != null) if (c.items.len + c.ranges.len / 2 == 1) {
                        if (c.items.len == 1) {
                            try s.facts.append(w.gpa, fact(.cmp_eq, t, w.term(c.items[0]), info.?));
                        } else {
                            try s.facts.append(w.gpa, fact(.cmp_gte, t, w.term(c.ranges[0]), info.?));
                            try s.facts.append(w.gpa, fact(.cmp_lte, t, w.term(c.ranges[1]), info.?));
                        }
                    };
                    try w.side(c.body);
                    s.facts.shrinkRetainingCapacity(depth);
                    w.dropNumbers(nlen);
                    w.rollback(log);
                    w.mem = mem;
                }
                if (info) |i| {
                    const signed = i.signedness == .signed;
                    const min: i128 = if (signed) -(@as(i128, 1) << @intCast(i.bits - 1)) else 0;
                    const max: i128 = (@as(i128, 1) << @intCast(i.bits - @intFromBool(signed))) - 1;
                    var cases = ir.switchCases(data.pl_op.payload);
                    // At most 16, as few as an `else` usually needs.
                    while (cases.next()) |c| {
                        if (s.facts.items.len - depth >= 16) break;
                        for (c.items[0..@min(c.items.len, 16)]) |item| try s.facts.append(w.gpa, fact(.cmp_neq, t, w.term(item), i));
                        var k: usize = 0;
                        while (k < c.ranges.len) : (k += 2) {
                            const lo = w.term(c.ranges[k]);
                            const hi = w.term(c.ranges[k + 1]);
                            if (lo.isConst() and lo.value() == min) try s.facts.append(w.gpa, fact(.cmp_gt, t, hi, i));
                            if (hi.isConst() and hi.value() == max) try s.facts.append(w.gpa, fact(.cmp_lt, t, lo, i));
                        }
                    }
                }
                try w.side(it.elseBody());
                s.facts.shrinkRetainingCapacity(depth);
                w.dropNumbers(nlen);
                try w.merge(from);
                w.mergeMem(clock);
            },
            else => |tag| if (writesMemory(tag)) w.changeMem() else try w.number(inst, tag, data),
        }
    }

    /// One side of a branch: a check's failing side without its memory
    /// changes (`coldBody`).
    fn side(w: *Walker, insts: []const Inst.Index) Allocator.Error!void {
        return if (isCold(w.ir, insts)) w.coldBody(insts) else w.body(insts);
    }

    /// Numbers a value an instruction that writes no memory computes: an
    /// instruction computing the same operation on equal operands (and
    /// for a load, from memory of the same version) computes the same
    /// value, so its term is the first one's. Rules that read an
    /// instruction's operands (`offset`, `plusOne`) then read the first
    /// one's, which are equal. Some values are simpler terms: `(a + b) -
    /// a` is `b` and `(x - c) + c` is `x`, wrapping or not, in one type.
    fn number(w: *Walker, inst: Inst.Index, tag: Inst.Tag, data: Inst.Data) Allocator.Error!void {
        const ir = w.ir;
        const ii = @backingInt(inst);
        var key: Key = .{ .tag = tag, .ty = .none, .x = 0, .a = .none, .b = .none };
        switch (tag) {
            .add_wrap, .sub_wrap, .mul_wrap, .bit_and, .bit_or, .xor, .shl, .shr, .rem, .mod, .div_trunc, .div_floor, .array_elem_val, .min_int, .max_int => {
                key.ty = ir.typeOfIndex(inst, w.ip);
                key.a = w.term(data.bin_op.lhs);
                key.b = w.term(data.bin_op.rhs);
                if (w.simplify(tag, key.ty, key.a, key.b)) |t| {
                    w.s.canon.items[ii] = t;
                    return;
                }
            },
            // The operands' type decides what a compare compares.
            .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => {
                key.ty = ir.typeOf(data.bin_op.lhs, w.ip);
                key.a = w.term(data.bin_op.lhs);
                key.b = w.term(data.bin_op.rhs);
            },
            .is_null, .is_non_null, .is_err, .is_non_err, .int_from_ptr, .int_from_bool => {
                key.ty = ir.typeOf(data.un_op, w.ip);
                key.a = w.term(data.un_op);
            },
            // Loads of memory: of the same version.
            .ptr_elem_val, .slice_elem_val => {
                if (Type.ptrInfo(w.ip, ir.typeOf(data.bin_op.lhs, w.ip)).flags.is_volatile) return;
                key.ty = ir.typeOfIndex(inst, w.ip);
                key.a = w.term(data.bin_op.lhs);
                key.b = w.term(data.bin_op.rhs);
                key.x = w.mem;
            },
            .struct_field_ptr, .struct_field_val => {
                const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
                key.ty = data.ty_pl.ty;
                key.a = w.term(sf.operand);
                key.x = sf.index;
                // `(x - c) + c` is `x`.
                if (tag == .struct_field_val and sf.index == 0) if (sf.operand.toIndex()) |op| {
                    const otag = ir.instructions.items(.tag)[@backingInt(op)];
                    if (otag == .add_with_overflow or otag == .sub_with_overflow) {
                        const bin = ir.extraData(Ir.Bin, ir.instructions.items(.data)[@backingInt(op)].ty_pl.payload).data;
                        if (w.simplify(if (otag == .add_with_overflow) .add_wrap else .sub_wrap, data.ty_pl.ty, w.term(bin.lhs), w.term(bin.rhs))) |t| {
                            w.s.canon.items[ii] = t;
                            return;
                        }
                    }
                };
            },
            .add_with_overflow, .sub_with_overflow, .mul_with_overflow, .slice, .ptr_add, .ptr_elem_ptr, .slice_elem_ptr => {
                const bin = ir.extraData(Ir.Bin, data.ty_pl.payload).data;
                key.ty = data.ty_pl.ty;
                key.a = w.term(bin.lhs);
                key.b = w.term(bin.rhs);
            },
            .slice_ptr, .optional_payload, .optional_payload_ptr, .unwrap_errunion_payload, .unwrap_errunion_err, .unwrap_errunion_payload_ptr, .bitcast, .trunc, .intcast, .not, .get_union_tag, .wrap_optional => {
                // A widening `intcast` is its operand (`term`).
                if (tag == .intcast and w.widens(inst.toRef(), data.ty_op.operand)) return;
                // A `bitcast` to the operand's own type is the operand (a
                // copy `forward.run` turned into the memory it copies).
                if (tag == .bitcast and data.ty_op.ty == ir.typeOf(data.ty_op.operand, w.ip)) {
                    w.s.canon.items[ii] = w.term(data.ty_op.operand);
                    return;
                }
                key.ty = data.ty_op.ty;
                key.a = w.term(data.ty_op.operand);
            },
            else => return,
        }
        // Two undefined values need not be equal.
        for ([2]Term{ key.a, key.b }) |t| if (t.tag == .interned and w.ip.keyTag(@fromBackingInt(t.a)) == .undef) return;
        const own: Term = .{ .tag = .inst, .a = ii };
        const first = try w.numberOf(key, own);
        w.s.canon.items[ii] = if (first.eql(own)) .none else first;
    }

    /// The term of the first instruction that computed the value `key`
    /// names on every path here, else `own`, which is then that first one.
    fn numberOf(w: *Walker, key: Key, own: Term) Allocator.Error!Term {
        const s = w.s;
        const gop = try s.numbers.getOrPut(w.gpa, key);
        if (gop.found_existing) return gop.value_ptr.*;
        gop.value_ptr.* = own;
        try s.nlog.append(w.gpa, key);
        return own;
    }

    /// Forgets the values `numbers` added since `nlog` had length `len`:
    /// where the walk goes next, their instructions may not have run.
    /// Knowledge about an instruction that holds only where it ran (an
    /// overflow operation's `exact`, its checked overflow bit) is then
    /// read only where it did: a later instruction is numbered as the
    /// first one only where the first one ran.
    fn dropNumbers(w: *Walker, len: usize) void {
        const s = w.s;
        while (s.nlog.items.len > len) _ = s.numbers.remove(s.nlog.pop().?);
    }

    /// `a op b` (wrapping, in type `ty`) as a simpler term: `(a +% b) -% a`
    /// is `b`, and `(x -% c) +% c` is `x`, in two's complement, when the
    /// inner operation is of the same type (an overflow operation's value
    /// is the wrapped result).
    fn simplify(w: *const Walker, tag: Inst.Tag, ty: Index, a: Term, b: Term) ?Term {
        if (tag != .add_wrap and tag != .sub_wrap) return null;
        const inner = w.wrapOperands(a, ty) orelse return null;
        if (tag == .sub_wrap and inner.tag == .add_wrap) {
            if (inner.a.eql(b)) return inner.b;
            if (inner.b.eql(b)) return inner.a;
        }
        if (tag == .add_wrap and inner.tag == .sub_wrap and inner.b.eql(b)) return inner.a;
        return null;
    }

    /// For `t` the value of an overflow operation `tag` (or the wrapping
    /// operation `wrap` made of one) that cannot have wrapped (its check
    /// passed: `exact`), its operands' terms.
    fn exactOperands(w: *const Walker, t: Term, tag: Inst.Tag) ?[2]Term {
        if (t.tag != .inst) return null;
        const ir = w.ir;
        const data = ir.instructions.items(.data)[t.a];
        switch (ir.instructions.items(.tag)[t.a]) {
            .add_wrap, .sub_wrap, .mul_wrap => |wt| {
                const want: Inst.Tag = switch (tag) {
                    .add_with_overflow => .add_wrap,
                    .sub_with_overflow => .sub_wrap,
                    else => .mul_wrap,
                };
                if (!w.s.exact.isSet(t.a) or wt != want) return null;
                return .{ w.term(data.bin_op.lhs), w.term(data.bin_op.rhs) };
            },
            .struct_field_val => {
                const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
                const op = sf.operand.toIndex() orelse return null;
                if (sf.index != 0 or ir.instructions.items(.tag)[@backingInt(op)] != tag or !w.s.exact.isSet(@backingInt(op))) return null;
                const bin = ir.extraData(Ir.Bin, ir.instructions.items(.data)[@backingInt(op)].ty_pl.payload).data;
                return .{ w.term(bin.lhs), w.term(bin.rhs) };
            },
            else => return null,
        }
    }

    const WrapOp = struct { tag: Inst.Tag, a: Term, b: Term };

    /// For a term computed by an addition or subtraction of type `ty`
    /// (wrapping, or an overflow operation's value), the operation as
    /// wrapping and its operands' terms.
    fn wrapOperands(w: *const Walker, t: Term, ty: Index) ?WrapOp {
        if (t.tag != .inst) return null;
        const ir = w.ir;
        const data = ir.instructions.items(.data)[t.a];
        switch (ir.instructions.items(.tag)[t.a]) {
            .add_wrap, .sub_wrap => |tag| {
                if (ir.typeOf(data.bin_op.lhs, w.ip) != ty) return null;
                return .{ .tag = tag, .a = w.term(data.bin_op.lhs), .b = w.term(data.bin_op.rhs) };
            },
            .struct_field_val => {
                const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
                if (sf.index != 0 or data.ty_pl.ty != ty) return null;
                const op = sf.operand.toIndex() orelse return null;
                const tag: Inst.Tag = switch (ir.instructions.items(.tag)[@backingInt(op)]) {
                    .add_with_overflow => .add_wrap,
                    .sub_with_overflow => .sub_wrap,
                    else => return null,
                };
                const bin = ir.extraData(Ir.Bin, ir.instructions.items(.data)[@backingInt(op)].ty_pl.payload).data;
                return .{ .tag = tag, .a = w.term(bin.lhs), .b = w.term(bin.rhs) };
            },
            else => return null,
        }
    }

    /// A `br` to `block`: the facts that hold here hold after it, if they
    /// hold at its other `br`s too. Facts name values, not places (a
    /// variable's term has its version), so one that held at every `br`
    /// still holds after the block; a store after it makes a new version
    /// no fact names.
    fn exitTo(w: *Walker, block: Inst.Index, operand: Inst.Ref) Allocator.Error!void {
        const s = w.s;
        var k = s.exits.items.len;
        while (k > 0) {
            k -= 1;
            const e = &s.exits.items[k];
            if (e.block != block) continue;
            e.operand = operand;
            if (e.facts.count == 0 and s.stored.items.len - e.from <= 32) {
                e.snap = .{ .count = 1, .start = @intCast(s.snaps.items.len) };
                for (s.stored.items[e.from..]) |v| try s.snaps.append(w.gpa, .{
                    .v = v,
                    .value = if (s.kind.items[v] == .variable) w.varTerm(v) else s.value.items[v],
                });
                e.snap.len = @intCast(s.snaps.items.len - e.snap.start);
                e.snap_mem = w.mem;
            }
            if (e.facts.count == 0 and s.nlog.items.len - e.nfrom <= 64) {
                e.nsnap = .{ .count = 1, .start = @intCast(s.nsnaps.items.len) };
                for (s.nlog.items[e.nfrom..]) |key| try s.nsnaps.append(w.gpa, .{ .key = key, .value = s.numbers.get(key).? });
                e.nsnap.len = @intCast(s.nsnaps.items.len - e.nsnap.start);
            }
            // A `bool` block: what held here, and what its value being
            // true (or false) adds, holds after it where it is true (or
            // false), if it held at every `br` that may exit it so.
            if (e.is_bool) {
                const truth = w.boolValue(operand);
                for ([2]bool{ false, true }) |t| if (truth == null or truth == t) {
                    const depth = s.facts.items.len;
                    try w.assume(operand, t);
                    const all = s.facts.items[e.depth..];
                    try w.meet(&s.cond_exit_facts, &s.exits.items[k].cond[@intFromBool(t)], all[all.len -| 16..]);
                    s.facts.shrinkRetainingCapacity(depth);
                };
            }
            // Only the facts found inside the block (those from before it
            // hold after it anyway), at most the 16 most recent.
            const all = s.facts.items[e.depth..];
            const inside = all[all.len -| 16..];
            try w.meet(&s.exit_facts, &e.facts, inside);
            return;
        }
    }

    /// Sets `sp` to the facts that held at every exit counted in it and at
    /// this one (`inside`). The list only grows within a function: a span
    /// is never written once made, so a failed speculation restores the
    /// spans alone, and an exit from any enclosing block can make one.
    fn meet(w: *Walker, list: *std.ArrayList(Fact), sp: *Span, inside: []const Fact) Allocator.Error!void {
        const start = list.items.len;
        if (sp.count == 0) {
            try list.appendSlice(w.gpa, inside);
        } else {
            for (sp.start..sp.start + sp.len) |i| {
                const f = list.items[i];
                for (inside) |g| if (std.meta.eql(f, g)) {
                    try list.append(w.gpa, f);
                    break;
                };
            }
        }
        sp.start = @intCast(start);
        sp.len = @intCast(list.items.len - start);
        sp.count += 1;
    }

    /// The value of `bool` `r` if known: a constant, or decided by the facts.
    fn boolValue(w: *Walker, r: Inst.Ref) ?bool {
        if (r.toInterned()) |v| return if (v == .bool_true) true else if (v == .bool_false) false else null;
        return w.decide(r);
    }

    /// A `br` exiting `block` with `operand`: the bounds of the block's
    /// value.
    fn result(w: *Walker, block: Inst.Index, operand: Inst.Ref) Allocator.Error!void {
        // A `bool` value is 0 or 1, decided or not.
        const t: Term = if (w.ir.typeOfIndex(block, w.ip) == .bool_type)
            if (w.boolValue(operand)) |b| .konst(@intFromBool(b)) else .none
        else if (w.intInfo(block.toRef()) != null) w.term(operand) else return;
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
                // The length a callee returns: its argument (`Ir.ret_lens`).
                if (w.retLenArg(t)) |arg| return w.term(arg);
                // The length a store wrote (`forwardStore`).
                if (t.tag == .inst) if (w.s.load_lens.get(t.a)) |len| return len;
                return switch (t.tag) {
                    .inst => .{ .tag = .len_inst, .a = t.a },
                    .variable => .{ .tag = .len_variable, .a = t.a, .b = t.b },
                    .interned => .{ .tag = .len_interned, .a = t.a },
                    else => .{ .tag = .inst, .a = @backingInt(i) },
                };
            },
            // A widening cast of the same signedness keeps the value (terms
            // are values, not bit patterns; `Fact.bits` bounds them).
            .intcast => if (w.widens(r, data.ty_op.operand)) return w.term(data.ty_op.operand),
            else => {},
        }
        // As the first instruction that computed the same value (`number`).
        const c = w.s.canon.items[@backingInt(i)];
        if (c.tag != .none) return c;
        return .{ .tag = .inst, .a = @backingInt(i) };
    }

    /// After a store of `val` through `ptr`, which changed memory: when
    /// `ptr` is a slice's `len` field, a load of the slice has length
    /// `val` until memory changes again (`self.items.len = n` then
    /// `self.items[old..][0..k]`). In `numbers`, under the new memory
    /// version, so it goes where the store's path ends (`dropNumbers`).
    /// Other stores are not forwarded: recording every store cost 0.2-0.45%
    /// more compile instructions for no measured run-time win.
    fn forwardStore(w: *Walker, ptr: Inst.Ref, val: Inst.Ref) Allocator.Error!void {
        if (w.isUndef(val)) return;
        const ir = w.ir;
        const ip = w.ip;
        if (Type.ptrInfo(ip, ir.typeOf(ptr, ip)).flags.is_volatile) return;
        // The slice pointer whose `len` field `ptr` is: a field pointer
        // instruction, or a constant field address (`&global.items.len`).
        const slice_ptr: Inst.Ref = if (ptr.toIndex()) |pi| blk: {
            if (ir.instructions.items(.tag)[@backingInt(pi)] != .struct_field_ptr) return;
            const sf = ir.extraData(Ir.StructField, ir.instructions.items(.data)[@backingInt(pi)].ty_pl.payload).data;
            if (sf.index != 1) return;
            break :blk sf.operand;
        } else blk: {
            const c = ptr.toInterned().?;
            if (ip.keyTag(c) != .ptr) return;
            const k = ip.keyPayload(.ptr, c);
            if (k.byte_offset != 0 or k.base != .field or k.base.field.index != 1) return;
            break :blk .fromInterned(k.base.field.base);
        };
        if (!Type.isSlice(ip, Type.childType(ip, ir.typeOf(slice_ptr, ip)))) return;
        _ = try w.numberOf(.{ .tag = .slice_len, .ty = .none, .x = w.mem, .a = w.term(slice_ptr), .b = .none }, w.term(val));
    }

    /// For `t` a call's result, or its error union's payload, where the
    /// callee returns slices of an argument's length (`Ir.ret_lens`):
    /// that argument at the call.
    fn retLenArg(w: *const Walker, t: Term) ?Inst.Ref {
        const ir = w.ir;
        if (ir.ret_lens.len == 0 or t.tag != .inst) return null;
        const tags = ir.instructions.items(.tag);
        const datas = ir.instructions.items(.data);
        var c = t.a;
        if (tags[c] == .unwrap_errunion_payload) {
            const u = w.term(datas[c].ty_op.operand);
            if (u.tag != .inst) return null;
            c = u.a;
        }
        if (tags[c] != .call) return null;
        const callee = datas[c].pl_op.operand.toInterned() orelse return null;
        for (ir.ret_lens) |r| if (r.callee == callee) {
            const x = ir.extraData(Ir.Call, datas[c].pl_op.payload);
            if (r.arg >= x.data.args_len) return null;
            return ir.refSlice(x.end, x.data.args_len)[r.arg];
        };
        return null;
    }

    /// Whether `intcast` `r` of `operand` widens it keeping its sign.
    fn widens(w: *const Walker, r: Inst.Ref, operand: Inst.Ref) bool {
        const from = w.intInfo(operand) orelse return false;
        const to = w.intInfo(r) orelse return false;
        return from.signedness == to.signedness and from.bits <= to.bits;
    }

    /// The term of load `inst` where the walk reaches it: a variable's
    /// value is its last store's when that store is in this iteration of
    /// the innermost loop and known; else the variable at its version,
    /// which changes at every store and merge; else, if no store reached
    /// it since the innermost loop's entry, the variable at that entry
    /// (`stamp`), since a store later in the loop reaches the entry through
    /// the back edge. A `*const` alloc holds the value stored, while no
    /// merge forgot it.
    fn loadTerm(w: *Walker, inst: Inst.Index, data: Inst.Data) Allocator.Error!Term {
        const s = w.s;
        const own: Term = .{ .tag = .inst, .a = @backingInt(inst) };
        if (data.ty_op.operand.toIndex()) |p| {
            const pi = @backingInt(p);
            switch (s.kind.items[pi]) {
                .variable => return w.varTerm(pi),
                // Only its own stores write it, which do not change `mem`.
                .constant => {
                    const v = s.value.items[pi];
                    return if (v.tag != .none) v else own;
                },
                .other, .stored_once => {},
            }
            if (w.ir.instructions.items(.tag)[pi] == .struct_field_ptr) {
                if (try w.constField(p, own)) |t| return t;
            }
        }
        // Other memory: a load of the same address and type from the same
        // version of memory (`mem`) reads the same value.
        if (Type.ptrInfo(w.ip, w.ir.typeOf(data.ty_op.operand, w.ip)).flags.is_volatile) return own;
        return w.numberOf(.{ .tag = .load, .ty = data.ty_op.ty, .x = w.mem, .a = w.term(data.ty_op.operand), .b = .none }, own);
    }

    /// What the field `sfp` points to holds, as `own` when first seen:
    /// in a `*const` alloc stored once, at any depth of fields, that field
    /// of the value stored to it, as `struct_field_val` numbers it, since
    /// nothing writes the alloc after its store. A field of a field is
    /// numbered through the inner field pointer, which stands for the
    /// inner field's value in the `struct_field_val` key only.
    fn constField(w: *Walker, sfp: Inst.Index, own: Term) Allocator.Error!?Term {
        const ir = w.ir;
        const data = ir.instructions.items(.data)[@backingInt(sfp)];
        const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
        const ty = Type.ptrInfo(w.ip, data.ty_pl.ty).child;
        // The pointer the field is in, as numbered: a pointer to it
        // stored to an alloc and loaded back (an inlined `*const`
        // parameter) is the same pointer.
        const base = w.term(sf.operand);
        if (base.tag != .inst) return null;
        const v: Term = v: {
            if (ir.instructions.items(.tag)[base.a] == .struct_field_ptr)
                break :v (try w.constField(@fromBackingInt(base.a), base)) orelse return null;
            const a = allocCast(ir, w.ip, @as(Inst.Index, @fromBackingInt(base.a)).toRef()) orelse return null;
            if (w.s.kind.items[a] != .constant) return null;
            break :v w.s.value.items[a];
        };
        if (v.tag == .none) return null;
        const t = try w.numberOf(.{ .tag = .struct_field_val, .ty = ty, .x = sf.index, .a = v, .b = .none }, own);
        return t;
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
    /// `x + d < x + c` when `d < c`.
    /// The fact's right side may be `y - k`, exact, which adds `k` to `c`. Only facts of types at most `bits`
    /// wide (any when 0) count, so `x + d` is at most `y`, at most the
    /// maximum of `bits`.
    fn bound(w: *const Walker, x: Term, d: u64, y: ?Term, bits: u16) ?Op {
        var best: ?Op = null;
        for (w.recent()) |g| {
            if (g.signed or (g.op != .lt and g.op != .le) or (bits != 0 and g.bits > bits)) continue;
            // `x + c < y - k`, the subtraction exact, is `x + c + k < y`
            // (`for (1..n) |j|` counts to `n - 1`, and `j` is that count
            // plus one).
            var k: u64 = 0;
            if (y) |b| if (!g.b.eql(b)) {
                if (g.b.tag != .inst) continue;
                const bt = w.ir.instructions.items(.tag)[g.b.a];
                if (bt != .struct_field_val and bt != .sub_wrap) continue;
                const p = w.exactOperands(g.b, .sub_with_overflow) orelse continue;
                if (!p[0].eql(b) or p[1].tag != .konst) continue;
                k = @intCast(p[1].value());
            };
            if (g.a.tag != .inst and !g.a.eql(x)) continue;
            const o = w.offset(g.a, true);
            if (!o.x.eql(x)) continue;
            const c = std.math.add(u64, o.c, k) catch continue;
            if (c < d) continue;
            if (g.op == .lt or c > d) return .lt;
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
        // An unsigned variable's largest value before the loop, when the
        // loop only stores to it what is likely no larger (`shrinks`): a
        // count down (`index -= 2`) or a mask (`idx & mask`).
        const st = s.stored.items;
        for (0..@min(st.len, 16)) |j| {
            if (s.cands.items.len >= 12) break;
            const v = st[st.len - 1 - j];
            if (s.kind.items[v] != .variable) continue;
            if (for (s.cands.items) |g| (if (g.v == v) break true) else false) continue;
            const info = w.varInfo(v) orelse continue;
            if (info.signedness == .signed) continue;
            const hi = w.range(w.varTerm(v), info).hi;
            if (hi >= limits(info).hi or !w.shrinks(insts, v, hi)) continue;
            try s.cands.append(gpa, .{ .v = v, .base = .{ .tag = .variable, .a = v, .b = stamp }, .c = 0, .op = .le, .bits = @intCast(info.bits), .y = .konst(@intCast(hi)) });
        }
        if (s.cands.items.len == 0) return false;
        // What a failed walk must restore.
        const depth = s.facts.items.len;
        const stats = w.stats;
        const from = s.stored.items.len;
        s.undo.clearRetainingCapacity();
        s.saved_exits.clearRetainingCapacity();
        try s.saved_exits.appendSlice(gpa, s.exits.items);
        const log = s.vlog.items.len;
        const nlen = s.nlog.items.len;
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
        // The variables hold again what they held before the loop (the
        // exits' snapshots the walk took stay unused in `snaps`).
        w.rollback(log);
        w.dropNumbers(nlen);
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
            // Within a constant bound by the value's own bounds.
            if (g.c == 0 and g.y.isConst()) {
                const hi = w.range(now, .{ .signedness = .unsigned, .bits = g.bits }).hi;
                if (hi < g.y.value() or (g.op == .le and hi == g.y.value())) continue;
            }
            // A fact on the value itself.
            if (w.bound(now, g.c, g.y, 0)) |op| if (g.op == .le or op == .lt) continue;
            const o = w.offset(now, false);
            const c = std.math.add(u64, o.c, g.c) catch return false;
            const op = w.bound(o.x, c, g.y, o.bits) orelse return false;
            if (g.op == .lt and op != .lt) return false;
        }
        return true;
    }

    /// The integer type variable `v` (an alloc) holds, if at most 64 bits.
    fn varInfo(w: *const Walker, v: u32) ?Type.IntInfo {
        const child = Type.ptrInfo(w.ip, w.ir.instructions.items(.data)[v].ty).child;
        if (Type.class(w.ip, child) != .int) return null;
        const info = Type.intInfo(w.ip, child);
        return if (info.bits <= 64 and info.bits > 0) info else null;
    }

    /// Whether every store in `insts` (and the bodies in them) to variable
    /// `v` stores a constant at most `hi`, or a value no larger than one
    /// of its operands: a difference from `v` that did not wrap, a
    /// remainder, a mask, a minimum. Only a guess, which `repeatHolds`
    /// checks.
    fn shrinks(w: *const Walker, insts: []const Inst.Index, v: u32, hi: i128) bool {
        const ir = w.ir;
        for (insts) |inst| {
            const ii = @backingInt(inst);
            const data = ir.instructions.items(.data)[ii];
            switch (ir.instructions.items(.tag)[ii]) {
                .store => if (data.bin_op.lhs.toIndex()) |p| if (@backingInt(p) == v) {
                    const t = w.term(data.bin_op.rhs);
                    if (t.isConst()) {
                        if (t.value() > hi) return false;
                        continue;
                    }
                    const r = data.bin_op.rhs.toIndex() orelse return false;
                    switch (ir.instructions.items(.tag)[@backingInt(r)]) {
                        .bit_and, .rem, .min_int => {},
                        .struct_field_val => {
                            const sf = ir.extraData(Ir.StructField, ir.instructions.items(.data)[@backingInt(r)].ty_pl.payload).data;
                            const op = sf.operand.toIndex() orelse return false;
                            if (sf.index != 0 or ir.instructions.items(.tag)[@backingInt(op)] != .sub_with_overflow) return false;
                        },
                        else => return false,
                    }
                },
                .block, .loop => {
                    const x = ir.extraData(Ir.Block, data.ty_pl.payload);
                    if (!w.shrinks(ir.bodySlice(x.end, x.data.body_len), v, hi)) return false;
                },
                .cond_br => {
                    const x = ir.extraData(Ir.CondBr, data.pl_op.payload);
                    if (!w.shrinks(ir.bodySlice(x.end, x.data.then_body_len + x.data.else_body_len), v, hi)) return false;
                },
                .switch_br => {
                    var it = ir.switchCases(data.pl_op.payload);
                    while (it.next()) |c| if (!w.shrinks(c.body, v, hi)) return false;
                    if (!w.shrinks(it.elseBody(), v, hi)) return false;
                },
                else => {},
            }
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
        if (!w.step()) return;
        defer w.nest -= 1;
        return w.assumeStep(cond, truth);
    }

    /// Counts one step of `assume` or `decide`, which walk conditions as
    /// trees: one shared by many `and`s and `or`s would take exponential
    /// time. A top-level call gets `max_steps`; past them, nothing more is
    /// assumed or decided.
    fn step(w: *Walker) bool {
        if (w.nest == 0) w.steps = max_steps;
        if (w.steps == 0) return false;
        w.steps -= 1;
        w.nest += 1;
        return true;
    }

    const max_steps = 256;

    fn assumeStep(w: *Walker, cond: Inst.Ref, truth: bool) Allocator.Error!void {
        if (cond.toIndex() == null) return;
        const ir = w.ir;
        // The instruction that computed the value first (`number`) has
        // equal operands.
        const c = w.term(cond);
        if (c.tag != .inst) return;
        const data = ir.instructions.items(.data)[c.a];
        switch (ir.instructions.items(.tag)[c.a]) {
            .not => return w.assume(data.ty_op.operand, !truth),
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
                return w.s.facts.append(w.gpa, f);
            },
            // What held at every exit of a `bool` block (`a and b`, an
            // inlined call) with this value.
            .block => if (w.s.bool_blocks.get(c.a)) |b| {
                const start = b.start + if (truth) b.len[0] else 0;
                try w.s.facts.appendSlice(w.gpa, w.s.block_facts.items[start..][0..b.len[@intFromBool(truth)]]);
            },
            else => {},
        }
        // Any other `bool` value is `truth` (`decide` reads it back).
        if (ir.typeOfIndex(@fromBackingInt(c.a), w.ip) == .bool_type)
            try w.s.facts.append(w.gpa, .{ .op = .eq, .signed = false, .bits = 1, .a = c, .b = .konst(@intFromBool(truth)) });
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
        switch (ir.instructions.items(.tag)[@backingInt(op)]) {
            .add_with_overflow, .sub_with_overflow, .mul_with_overflow => {},
            else => return,
        }
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
        if (!w.step()) {
            w.checked_op = null;
            return null;
        }
        defer w.nest -= 1;
        return w.decideStep(cond);
    }

    fn decideStep(w: *Walker, cond: Inst.Ref) ?bool {
        w.checked_op = null;
        const i = cond.toIndex() orelse return null;
        const ir = w.ir;
        switch (ir.instructions.items(.tag)[@backingInt(i)]) {
            .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => |tag| {
                const data = ir.instructions.items(.data)[@backingInt(i)];
                const lhs = data.bin_op.lhs;
                const rhs = data.bin_op.rhs;
                const info = w.intInfo(lhs) orelse return null;
                // An overflow check: `cmp_eq(bit, 0)` and the like. Proven
                // by the bounds of its operands, or by a fact on the bit
                // (the same operation's check passed before).
                if (lhs.toIndex()) |bit| if (ir.instructions.items(.tag)[@backingInt(bit)] == .struct_field_val) {
                    const sf = ir.extraData(Ir.StructField, ir.instructions.items(.data)[@backingInt(bit)].ty_pl.payload).data;
                    if (sf.index == 1) if (sf.operand.toIndex()) |op| if (Ssa.ovfBitCmp(ir, w.ip, i, @backingInt(bit))) |true_if_ovf| {
                        if (w.noOverflow(op)) {
                            w.checked_op = op;
                            return !true_if_ovf;
                        }
                        const r = w.proves(fact(tag, w.term(lhs), w.term(rhs), info), info) orelse return null;
                        if (r != true_if_ovf) w.checked_op = op;
                        return r;
                    };
                };
                if (w.isUndef(lhs) or w.isUndef(rhs)) return null;
                return w.proves(fact(tag, w.term(lhs), w.term(rhs), info), info);
            },
            else => {},
        }
        // Through the instruction that computed the value first.
        const c = w.term(cond);
        if (c.tag != .inst) return null;
        const data = ir.instructions.items(.data)[c.a];
        switch (ir.instructions.items(.tag)[c.a]) {
            .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => if (c.a != @backingInt(i)) {
                // Its overflow operation is not this one to `wrap`.
                const b = w.decide(@as(Inst.Index, @fromBackingInt(c.a)).toRef());
                w.checked_op = null;
                return b;
            },
            // `a and b` is false also when `b` is false wherever `a` is
            // true (`!(lt and gt)`), and `a or b` true when `b` is true
            // wherever `a` is false.
            .bit_and, .bit_or => |tag| {
                const l = w.decide(data.bin_op.lhs);
                const r = w.decide(data.bin_op.rhs);
                w.checked_op = null;
                const absorb = tag == .bit_or;
                if (l == absorb or r == absorb) return absorb;
                if (l == !absorb and r == !absorb) return !absorb;
                if (l != null) return null;
                const depth = w.s.facts.items.len;
                defer w.s.facts.shrinkRetainingCapacity(depth);
                w.assume(data.bin_op.lhs, !absorb) catch return null;
                const b = w.decide(data.bin_op.rhs);
                w.checked_op = null;
                if (b == absorb) return absorb;
            },
            .not => {
                const b = w.decide(data.ty_op.operand);
                w.checked_op = null;
                if (b) |v| return !v;
            },
            // Exited only with one value (`result`).
            .block => if (w.s.results.get(c.a)) |r| if (r.lo == r.hi and ir.typeOfIndex(@fromBackingInt(c.a), w.ip) == .bool_type) return r.lo != 0,
            else => {},
        }
        if (ir.typeOfIndex(@fromBackingInt(c.a), w.ip) != .bool_type) return null;
        const b = w.proves(.{ .op = .eq, .signed = false, .bits = 1, .a = c, .b = .konst(1) }, .{ .signedness = .unsigned, .bits = 1 });
        w.checked_op = null;
        return b;
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
        if (tag == .mul_with_overflow) if (w.wideProduct(bin.lhs, bin.rhs)) |fits| return fits;
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
                // `(x - k) + k` when `x - k` did not wrap: the sum is `x`.
                if (w.exactOperands(a, .sub_with_overflow)) |p| if (p[1].eql(b)) return true;
                if (w.exactOperands(b, .sub_with_overflow)) |p| if (p[1].eql(a)) return true;
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

    /// For a product of unsigned integers wider than 64 bits (at most
    /// 128), whether it fits its type, when both operands are values of
    /// at most 64 bits widened (`intcast`, or constants): from their
    /// bounds, whose product fits a `u128`. Null for other products.
    fn wideProduct(w: *const Walker, lhs: Inst.Ref, rhs: Inst.Ref) ?bool {
        const ty = w.ir.typeOf(lhs, w.ip);
        if (Type.class(w.ip, ty) != .int) return null;
        const info = Type.intInfo(w.ip, ty);
        if (info.signedness != .unsigned or info.bits <= 64 or info.bits > 128) return null;
        const a = w.narrowMax(lhs) orelse return null;
        const b = w.narrowMax(rhs) orelse return null;
        const max = @as(u128, std.math.maxInt(u128)) >> @intCast(128 - info.bits);
        return @as(u128, a) * b <= max;
    }

    /// The largest value of `r`, an unsigned integer wider than 64 bits,
    /// when it is a constant or a widened value of at most 64 bits.
    fn narrowMax(w: *const Walker, r: Inst.Ref) ?u64 {
        const t = w.term(r);
        if (t.isConst()) return if (t.value() >= 0) @intCast(t.value()) else null;
        // The value's term (a variable's stored value) is the `intcast`.
        if (t.tag != .inst or w.ir.instructions.items(.tag)[t.a] != .intcast) return null;
        const operand = w.ir.instructions.items(.data)[t.a].ty_op.operand;
        const from = w.intInfo(operand) orelse return null;
        if (from.signedness != .unsigned) return null;
        return @intCast(w.range(w.term(operand), from).hi);
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
            // A value is within its own type's bounds (a widening cast's
            // term is its narrower operand).
            if (w.intInfo(@as(Inst.Index, @fromBackingInt(@intCast(t.a))).toRef())) |own| {
                const lim = limits(own);
                r = .{ .lo = @max(r.lo, lim.lo), .hi = @min(r.hi, lim.hi) };
            }
            blk_none: switch (ir.instructions.items(.tag)[t.a]) {
                .block => if (w.s.results.get(t.a)) |b| if (b.lo <= b.hi) {
                    r = .{ .lo = @max(r.lo, b.lo), .hi = @min(r.hi, b.hi) };
                },
                .add_wrap, .sub_wrap, .mul_wrap => |tag| if (depth > 0) if (w.intInfo(@as(Inst.Index, @fromBackingInt(@intCast(t.a))).toRef())) |own| {
                    const a = w.rangeIn(w.term(data.bin_op.lhs), own, depth - 1);
                    const b = w.rangeIn(w.term(data.bin_op.rhs), own, depth - 1);
                    const exact: Range = switch (tag) {
                        .add_wrap => .{ .lo = a.lo + b.lo, .hi = a.hi + b.hi },
                        .sub_wrap => .{ .lo = a.lo - b.hi, .hi = a.hi - b.lo },
                        // Unsigned operands only (a product's bounds are
                        // its operands' then). Two 64-bit operands' sum
                        // fits an i128, but even their smallest product
                        // may not.
                        else => if (a.lo >= 0 and b.lo >= 0) .{
                            .lo = std.math.mul(i128, a.lo, b.lo) catch break :blk_none,
                            .hi = std.math.mul(i128, a.hi, b.hi) catch break :blk_none,
                        } else break :blk_none,
                    };
                    const lim = limits(own);
                    if (exact.lo >= lim.lo and exact.hi <= lim.hi) r = .{ .lo = @max(r.lo, exact.lo), .hi = @min(r.hi, exact.hi) };
                },
                // An addition or subtraction that did not wrap computed
                // the exact result.
                .struct_field_val => if (depth > 0) {
                    const add = w.exactOperands(t, .add_with_overflow);
                    const sub = if (add == null) w.exactOperands(t, .sub_with_overflow) else null;
                    const p = add orelse sub orelse w.exactOperands(t, .mul_with_overflow) orelse break :blk_none;
                    const own = w.intInfo(@as(Inst.Index, @fromBackingInt(@intCast(t.a))).toRef()) orelse break :blk_none;
                    const a = w.rangeIn(p[0], own, depth - 1);
                    const b = w.rangeIn(p[1], own, depth - 1);
                    const exact: Range = if (add != null)
                        .{ .lo = a.lo + b.lo, .hi = a.hi + b.hi }
                    else if (sub != null)
                        .{ .lo = a.lo - b.hi, .hi = a.hi - b.lo }
                    else if (a.lo >= 0 and b.lo >= 0)
                        .{ .lo = a.lo * b.lo, .hi = std.math.mul(i128, a.hi, b.hi) catch break :blk_none }
                    else
                        break :blk_none;
                    r = .{ .lo = @max(r.lo, exact.lo), .hi = @min(r.hi, exact.hi) };
                },
                // A value-preserving `intcast` keeps its operand's bounds,
                // and so does a `trunc` whose operand fits.
                .intcast, .trunc => if (depth > 0) {
                    const from = w.intInfo(data.ty_op.operand) orelse break :blk_none;
                    const own = w.intInfo(@as(Inst.Index, @fromBackingInt(@intCast(t.a))).toRef()) orelse break :blk_none;
                    const a = w.rangeIn(w.term(data.ty_op.operand), from, depth - 1);
                    const lim = limits(own);
                    if (ir.instructions.items(.tag)[t.a] == .intcast or (a.lo >= lim.lo and a.hi <= lim.hi)) r = .{ .lo = @max(r.lo, a.lo), .hi = @min(r.hi, a.hi) };
                },
                .min_int, .max_int => |tag| if (depth > 0) if (w.intInfo(@as(Inst.Index, @fromBackingInt(@intCast(t.a))).toRef())) |own| {
                    const a = w.rangeIn(w.term(data.bin_op.lhs), own, depth - 1);
                    const b = w.rangeIn(w.term(data.bin_op.rhs), own, depth - 1);
                    const m: Range = if (tag == .min_int) .{ .lo = @min(a.lo, b.lo), .hi = @min(a.hi, b.hi) } else .{ .lo = @max(a.lo, b.lo), .hi = @max(a.hi, b.hi) };
                    r = .{ .lo = @max(r.lo, m.lo), .hi = @min(r.hi, m.hi) };
                },
                // Unsigned (or not negative) `a % b` is below `b` and at
                // most `a`; `a & b` at most either; `a >> b` at most `a`
                // shifted by `b`'s least value.
                .rem, .mod, .bit_and, .shr => |tag| if (depth > 0) if (w.intInfo(@as(Inst.Index, @fromBackingInt(@intCast(t.a))).toRef())) |own| {
                    const a = w.rangeIn(w.term(data.bin_op.lhs), own, depth - 1);
                    const b = if (tag == .shr)
                        w.rangeIn(w.term(data.bin_op.rhs), w.intInfo(data.bin_op.rhs) orelse break :blk_none, depth - 1)
                    else
                        w.rangeIn(w.term(data.bin_op.rhs), own, depth - 1);
                    if (a.lo < 0 or b.lo < 0) break :blk_none;
                    const hi: i128 = switch (tag) {
                        .rem, .mod => if (b.lo >= 1) @min(a.hi, b.hi - 1) else break :blk_none,
                        .bit_and => @min(a.hi, b.hi),
                        else => if (b.lo < 128) a.hi >> @intCast(b.lo) else 0,
                    };
                    r = .{ .lo = @max(r.lo, 0), .hi = @min(r.hi, hi) };
                },
                else => {},
            }
        }
        for (w.recent()) |f| {
            if (f.signed != signed) continue;
            const lim = limits(.{ .signedness = info.signedness, .bits = f.bits });
            if (f.a.eql(t)) {
                // `t < u` bounds `t` by one less than `u`'s largest value.
                const k: ?i128 = if (f.b.isConst()) f.b.value() else if (depth > 0 and (f.op == .lt or f.op == .le))
                    w.rangeIn(f.b, .{ .signedness = info.signedness, .bits = f.bits }, depth - 1).hi
                else
                    null;
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
                const k: ?i128 = if (f.a.isConst()) f.a.value() else if (depth > 0 and (f.op == .lt or f.op == .le))
                    w.rangeIn(f.a, .{ .signedness = info.signedness, .bits = f.bits }, depth - 1).lo
                else
                    null;
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
        // `t != k` at an end of the bounds moves that end (`limit != 0`
        // makes `limit - 1` not wrap).
        for (w.recent()) |f| {
            if (f.signed != signed or f.op != .ne) continue;
            const k = if (f.a.eql(t) and f.b.isConst()) f.b.value() else if (f.b.eql(t) and f.a.isConst()) f.a.value() else continue;
            if (r.lo == k) r.lo += 1;
            if (r.hi == k) r.hi -= 1;
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
    /// type `info`: directly, or for `<` and `<=` from facts on operands
    /// the facts make equal to `f`'s (`equals`), as `j < s.len` from `j <
    /// n` when `s.len == n` was asserted, or from `j < m` when `s.len == n`
    /// and `n == m` were. Facts name values, not places: a load after a
    /// store or a call is another value, which the facts before it do not
    /// name.
    fn proves(w: *const Walker, f: Fact, info: Type.IntInfo) ?bool {
        if (w.provesDirect(f, info)) |r| return r;
        if (f.op != .lt and f.op != .le) return null;
        // The recent equalities of two values, usually none.
        var eqs: [max_equal]Fact = undefined;
        var ne: usize = 0;
        for (w.recent()) |g| {
            if (g.op != .eq or g.signed != f.signed or g.a.isConst() or g.b.isConst()) continue;
            eqs[ne] = g;
            ne += 1;
            if (ne == max_equal) break;
        }
        if (ne == 0) return null;
        var as: [max_equal]Term = undefined;
        var bs: [max_equal]Term = undefined;
        const na = equals(eqs[0..ne], f.a, &as);
        const nb = equals(eqs[0..ne], f.b, &bs);
        for (as[0..na], 0..) |a, i| for (bs[0..nb], 0..) |b, j| {
            if (i == 0 and j == 0) continue;
            if (w.provesFacts(with(f, f.op, a, b))) |r| return r;
        };
        return null;
    }

    const max_equal = 6;

    /// `t`, then the values `eqs` make equal to it, directly and through
    /// one more equality, at most `max_equal` in all; returns how many.
    fn equals(eqs: []const Fact, t: Term, out: *[max_equal]Term) usize {
        out[0] = t;
        var n: usize = 1;
        var k: usize = 0;
        // `out[0]`, then the values equal to it.
        var expand: usize = 1;
        while (k < expand) : (k += 1) {
            for (eqs) |g| {
                const other = if (g.a.eql(out[k])) g.b else if (g.b.eql(out[k])) g.a else continue;
                if (for (out[0..n]) |o| (if (o.eql(other)) break true) else false) continue;
                out[n] = other;
                n += 1;
                if (n == max_equal) return n;
            }
            if (k == 0) expand = n;
        }
        return n;
    }

    /// `proves` from the facts on the operands alone, without their
    /// bounds: a fact on them or on an offset of them (`offsetHolds`),
    /// also for an exact `x - b` as `x` (`provesDirect`).
    fn provesFacts(w: *const Walker, f: Fact) ?bool {
        if (f.a.eql(f.b)) return f.op == .le;
        if (!f.signed) if (w.exactOperands(f.a, .sub_with_overflow)) |p| {
            if (w.holds(with(f, f.op, p[0], f.b)) or w.offsetHolds(with(f, f.op, p[0], f.b))) return true;
        };
        if (w.holds(f) or w.offsetHolds(f)) return true;
        if (w.holds(negate(f)) or w.offsetHolds(negate(f))) return false;
        return null;
    }

    /// `proves` without replacing operands.
    fn provesDirect(w: *const Walker, f: Fact, info: Type.IntInfo) ?bool {
        // Equal terms are one value.
        if (f.a.eql(f.b)) return f.op == .le or f.op == .eq;
        if (!f.signed and (f.op == .le or f.op == .lt)) {
            // Unsigned `a <= a + b` when the addition did not wrap
            // (`start <= end` of `s[start..][0..len]`).
            if (f.op == .le) if (w.exactOperands(f.b, .add_with_overflow)) |p| if (p[0].eql(f.a) or p[1].eql(f.a)) return true;
            // Unsigned `x - b <= y` from `x <= y`, and `x - b < y` from
            // `x < y`, or from `x <= y` when `b >= 1`, when the
            // subtraction did not wrap: then `x - b <= x`, and `< x` when
            // `b >= 1` (`s[j - 1]` after `s[j]`).
            if (w.exactOperands(f.a, .sub_with_overflow)) |p| {
                if (w.holds(with(f, f.op, p[0], f.b)) or w.offsetHolds(with(f, f.op, p[0], f.b))) return true;
                if (f.op == .lt and w.range(p[1], info).lo >= 1 and
                    (w.holds(with(f, .le, p[0], f.b)) or w.offsetHolds(with(f, .le, p[0], f.b)))) return true;
            }
        }
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

/// Whether an instruction (other than those `Walker.instruction` handles
/// itself) may write memory, or let writes of another thread be seen
/// (atomics). Any tag not known to do neither may.
fn writesMemory(tag: Inst.Tag) bool {
    return switch (tag) {
        .arg, .alloc, .load, .add_wrap, .sub_wrap, .mul_wrap, .add_with_overflow, .sub_with_overflow, .mul_with_overflow, .add_float, .sub_float, .mul_float, .div_float, .div_trunc, .div_floor, .div_ceil, .rem, .mod, .min_float, .max_float, .neg_float, .sqrt, .sin, .cos, .tan, .exp, .exp2, .log, .log2, .log10, .abs_float, .floor, .ceil, .round, .trunc_float, .mul_add, .bit_and, .bit_or, .xor, .shl, .shr, .not, .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq, .cmp_vector, .reduce, .min_int, .max_int, .select, .shuffle, .intcast, .trunc, .float_cast, .float_from_int, .int_from_float, .bitcast, .clz, .ctz, .popcount, .byte_swap, .bit_reverse, .int_from_bool, .int_from_ptr, .ptr_from_int, .ret_addr, .frame_addr, .extern_ptr, .extern_pcrel, .extern_tls, .tls_ptr, .save_err_return_trace_index, .ret, .unreach, .trap, .struct_field_ptr, .struct_field_val, .ptr_elem_ptr, .ptr_elem_val, .slice_elem_ptr, .slice_elem_val, .array_elem_val, .slice_ptr, .slice_len, .slice, .ptr_add, .is_null, .is_non_null, .optional_payload, .optional_payload_ptr, .wrap_optional, .is_err, .is_non_err, .unwrap_errunion_payload, .unwrap_errunion_err, .unwrap_errunion_payload_ptr, .unwrap_errunion_err_ptr, .wrap_errunion_payload, .wrap_errunion_err, .aggregate_init, .union_init, .get_union_tag, .dbg_stmt, .dbg_inline_begin, .dbg_inline_end => false,
        else => true,
    };
}

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
