//! Lowering a `switch_br` with constant case values, shared by the
//! architectures (docs/slop/architecture.md, "Switches"): the cases are
//! sorted, dense runs become jump tables, and the rest is a binary search
//! with compares at its leaves. The architecture emits each step through
//! a context (`lower`).
//!
//! Values are keys: the operand's 64-bit extended bits, with the sign bit
//! flipped for a signed operand, so that keys order as the values do when
//! compared unsigned.

const std = @import("std");

/// Keys `lo` through `hi` go to `label`.
pub const Case = struct { lo: u64, hi: u64, label: u32 };

/// At most this many runs are tested one by one; more are searched.
const linear_max = 3;
/// A jump table needs at least this many cases, covering at least this
/// share (in percent) of its span, LLVM's thresholds, and at most
/// `table_max` entries, and at most `table_per_target` per block it goes
/// to: a big table of few targets (wide ranges to one block) is code a
/// search over the ranges does in a few compares.
const table_min = 4;
const table_density = 40;
const table_max = 4096;
const table_per_target = 64;

/// Sorts `cases` by key and merges neighbors that go to the same label;
/// returns the cases left.
pub fn prepare(cases: []Case) []Case {
    std.mem.sort(Case, cases, {}, struct {
        fn lt(_: void, a: Case, b: Case) bool {
            return a.lo < b.lo;
        }
    }.lt);
    var n: usize = 0;
    for (cases) |c| {
        if (n != 0 and cases[n - 1].label == c.label and cases[n - 1].hi != std.math.maxInt(u64) and cases[n - 1].hi + 1 == c.lo) {
            cases[n - 1].hi = c.hi;
            continue;
        }
        cases[n] = c;
        n += 1;
    }
    return cases[0..n];
}

/// The keys an operand of `abi_size` bytes can hold, extended as
/// registers and memory hold it (a value is extended from its ABI size,
/// not its bits: an undefined `u4` is 0xaa).
pub fn bounds(abi_size: u64, signed: bool) [2]u64 {
    const bytes: u64 = @min(abi_size, 8);
    const bits: u7 = @intCast(bytes * 8);
    const top: u64 = if (bits == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(bits)) - 1;
    if (!signed) return .{ 0, top };
    const half = top >> 1;
    const flip = @as(u64, 1) << 63;
    return .{ flip - half - 1, flip + half };
}

/// A run of cases lowered as one: a jump table, or a single case.
const Run = struct { start: u32, end: u32, table: bool };

/// Emits the dispatch of the sorted, merged `cases` (`prepare`) for an
/// operand whose key lies in `lo`...`hi` (`bounds`). Returns whether the
/// code may fall through, which it does for a key no case holds.
///
/// `ctx` emits code; its labels are `u32`s:
/// - `branch(key, cond, label, again)`: jumps to `label` if the operand
///   compares to `key` by `cond` (`.lt`, `.lte`, `.eq`, `.gte`, as keys);
///   with `again`, the flags already hold that compare;
/// - `branchIn(lo, hi, label)`: jumps to `label` if the key is in `lo`...`hi`;
/// - `table(cases, lo, hi, check, out)`: jumps through a table indexed by
///   key minus `lo`, over `lo`...`hi`, to each key's case or to
///   `else_label` between cases; with `check`, a key outside `lo`...`hi`
///   jumps to `out` instead;
/// - `jump(label)`, `newLabel()`, `bind(label)`.
pub fn lower(gpa: std.mem.Allocator, ctx: anytype, cases: []const Case, lo: u64, hi: u64, else_label: u32) !bool {
    if (cases.len == 0) return true;
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(gpa);
    try runs.ensureTotalCapacity(gpa, cases.len);
    // Greedy: from each case, the longest dense run of at least
    // `table_min` cases, else the case alone.
    var i: u32 = 0;
    while (i < cases.len) {
        var best = i;
        var covered: u64 = 0;
        // The run's distinct labels, up to as many as `table_max` needs.
        var labels: [table_max / table_per_target]u32 = undefined;
        var distinct: usize = 0;
        var j = i;
        while (j < cases.len) : (j += 1) {
            const span = cases[j].hi - cases[i].lo;
            if (span >= table_max) break;
            covered += cases[j].hi - cases[j].lo + 1;
            if (distinct < labels.len and std.mem.indexOfScalar(u32, labels[0..distinct], cases[j].label) == null) {
                labels[distinct] = cases[j].label;
                distinct += 1;
            }
            // Keys between the cases go to the else block.
            const targets = distinct + @intFromBool(covered != span + 1);
            if (j - i + 1 >= table_min and covered * 100 >= (span + 1) * table_density and span + 1 <= targets * table_per_target) best = j;
        }
        const table = best - i + 1 >= table_min;
        runs.appendAssumeCapacity(.{ .start = i, .end = best + 1, .table = table });
        i = best + 1;
    }
    var l: Lowering(@TypeOf(ctx)) = .{ .ctx = ctx, .cases = cases, .else_label = else_label };
    return l.search(runs.items, lo, hi);
}

fn Lowering(comptime Ctx: type) type {
    return struct {
        ctx: Ctx,
        cases: []const Case,
        else_label: u32,
        /// The key the flags hold the operand's compare with, if any.
        flags: ?u64 = null,

        const L = @This();

        fn branch(l: *L, key: u64, cond: std.math.CompareOperator, label: u32) !void {
            try l.ctx.branch(key, cond, label, l.flags == key);
            l.flags = key;
        }

        fn runLo(l: *const L, r: Run) u64 {
            return l.cases[r.start].lo;
        }

        fn runHi(l: *const L, r: Run) u64 {
            return l.cases[r.end - 1].hi;
        }

        /// A binary search over `runs` for a key in `lo`...`hi`.
        fn search(l: *L, runs: []const Run, lo: u64, hi: u64) !bool {
            if (runs.len <= linear_max) return l.linear(runs, lo, hi);
            const mid = runs.len / 2;
            const pivot = l.runLo(runs[mid]);
            const left = try l.ctx.newLabel();
            try l.branch(pivot, .lt, left);
            if (try l.search(runs[mid..], pivot, hi)) try l.ctx.jump(l.else_label);
            // Reached only from the compare with the pivot.
            l.ctx.bind(left);
            l.flags = pivot;
            return l.search(runs[0..mid], lo, pivot - 1);
        }

        /// Tests `runs` in order for a key in `lo`...`hi`.
        fn linear(l: *L, runs: []const Run, lo_in: u64, hi_in: u64) !bool {
            var lo = lo_in;
            var hi = hi_in;
            for (runs, 0..) |r, k| {
                const rlo = l.runLo(r);
                const rhi = l.runHi(r);
                const covers = rlo <= lo and rhi >= hi;
                if (r.table) {
                    const last = k == runs.len - 1;
                    const out = if (last or covers) l.else_label else try l.ctx.newLabel();
                    try l.ctx.table(l.cases[r.start..r.end], rlo, rhi, !covers, out);
                    if (last or covers) return false;
                    l.ctx.bind(out);
                    l.flags = null;
                    continue;
                }
                const c = l.cases[r.start];
                if (covers) {
                    try l.ctx.jump(c.label);
                    return false;
                }
                if (c.lo <= lo) {
                    try l.branch(c.hi, .lte, c.label);
                    lo = c.hi + 1;
                } else if (c.hi >= hi) {
                    try l.branch(c.lo, .gte, c.label);
                    hi = c.lo - 1;
                } else if (c.lo == c.hi) {
                    try l.branch(c.lo, .eq, c.label);
                } else {
                    try l.ctx.branchIn(c.lo, c.hi, c.label);
                    l.flags = null;
                }
            }
            return true;
        }
    };
}
