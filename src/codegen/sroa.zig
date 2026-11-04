//! Scalar replacement of aggregates (docs/slop/architecture.md, "Rewrite
//! rules"): a local struct whose address never escapes, used only through
//! its fields' pointers and whole loads and stores, becomes one local per
//! field, which CodeGen then keeps in registers. Inlining makes most of
//! them: a callee's struct parameters and result become the caller's
//! temporaries (nbody's `Vec` arithmetic).
//!
//! A field pointer becomes its field's local (through the rewrite walk's
//! substitutions); a whole load becomes the fields' loads and an
//! `aggregate_init` of them, which the rewrite rules fold into each field
//! read; a whole store becomes a store per field. Runs on the Sema thread
//! before the rewrite rules, and may intern.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const Index = InternPool.Index;
const Ir = @import("../Ir.zig");
const Inst = Ir.Inst;
const Type = @import("../Type.zig");
const Ssa = @import("Ssa.zig");

/// The most fields a split struct has.
const max_fields = 8;

/// An instruction the rewrite walk replaces with another value.
pub const Seed = struct { inst: Inst.Index, ref: Inst.Ref };

pub const Scratch = struct {
    words: std.ArrayList(u32) = .empty,
    /// Instructions `run` inserts, grouped by the instruction they precede.
    ins: std.ArrayList(Inst.Index) = .empty,
    /// The loads, stores, and field pointers of candidate structs.
    events: std.ArrayList(Inst.Index) = .empty,
    seeds: std.ArrayList(Seed) = .empty,
    /// Stores to other memory of blocks' or loads' values (`Scan.scan`).
    stores: std.ArrayList(Inst.Index) = .empty,

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        s.stores.deinit(gpa);
        s.words.deinit(gpa);
        s.ins.deinit(gpa);
        s.events.deinit(gpa);
        s.seeds.deinit(gpa);
    }
};

const none = std.math.maxInt(u32);
/// `Editor.group` of an instruction to leave out of its body.
const dropped = none - 1;

/// Splits the structs of `ir` that qualify; the field pointers to replace
/// are left in `scratch.seeds`. Returns how many structs were split.
pub fn run(gpa: Allocator, ip: *InternPool, tid: InternPool.Tid, ir: *Ir, scratch: *Scratch) Allocator.Error!u32 {
    scratch.seeds.clearRetainingCapacity();
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    // Most functions have no candidate; finding none costs one pass over
    // the tags.
    for (tags, datas) |tag, data| {
        if (tag == .alloc and candidate(ip, data.ty) != 0) break;
    } else return 0;

    const n = ir.instructions.len;
    try scratch.words.resize(gpa, 5 * n);
    var s: Scan = .{
        .ir = ir,
        .ip = ip,
        .root = scratch.words.items[0..n],
        .fields = scratch.words.items[n .. 2 * n],
        .agg = @ptrCast(scratch.words.items[4 * n .. 5 * n]),
        .events = &scratch.events,
        .gpa = gpa,
    };
    @memset(s.root, none);
    @memset(s.fields, 0);
    scratch.events.clearRetainingCapacity();
    if (!try s.scan(&scratch.stores)) return 0;

    var e: Editor = .{
        .gpa = gpa,
        .insts = ir.instructions.toMultiArrayList(),
        .extra = .fromOwnedSlice(@constCast(ir.extra)),
        .group = @ptrCast(scratch.words.items[2 * n .. 4 * n]),
        .ins = &scratch.ins,
        .n = @intCast(n),
    };
    defer {
        ir.instructions = e.insts.slice();
        ir.extra = e.extra.allocatedSlice();
    }
    @memset(e.group, .{ none, 0 });
    scratch.ins.clearRetainingCapacity();
    var split: u32 = 0;
    var changed = false;
    for (scratch.events.items) |inst| {
        const ii = @backingInt(inst);
        const tag = e.insts.items(.tag)[ii];
        const data = e.insts.items(.data)[ii];
        switch (tag) {
            .alloc => {
                if (s.fields[ii] == 0) continue;
                split += 1;
                changed = true;
                const info = Type.ptrInfo(ip, data.ty);
                const agg = info.child;
                const k = s.fields[ii];
                // Field locals 1..k: new allocs before this one, which
                // becomes field 0's. `fields` then holds the first new one.
                const first: u32 = @intCast(e.insts.len);
                e.begin(inst);
                for (1..k) |f| _ = try e.add(.{ .tag = .alloc, .data = .{ .ty = try fieldPtr(ip, tid, agg, f, info.flags.is_const) } });
                e.insts.items(.data)[ii].ty = try fieldPtr(ip, tid, agg, 0, info.flags.is_const);
                s.fields[ii] = first;
                s.agg[ii] = agg;
            },
            .struct_field_ptr => {
                const r = s.root[ii];
                if (s.fields[r] == 0) continue;
                // `StructField.index` follows the operand.
                const f = e.extra.items[data.ty_pl.payload + 1];
                try scratch.seeds.append(gpa, .{ .inst = inst, .ref = fieldLocal(&s, r, f).toRef() });
                // Its uses take the field's local; it would point past it.
                e.group[ii][0] = dropped;
            },
            .load => {
                const ptr = data.ty_op.operand;
                var refs: [max_fields]Inst.Ref = undefined;
                const agg, const k = if (s.root[ii] == ii | load_bit) blk: {
                    // A load from other memory: its fields' loads.
                    if (s.fields[ii] == 0) continue;
                    const agg = data.ty_op.ty;
                    const k = s.fields[ii];
                    e.begin(inst);
                    for (0..k) |f| {
                        const fp = try e.add(.{ .tag = .struct_field_ptr, .data = .{ .ty_pl = .{ .ty = try fieldPtr(ip, tid, agg, f, true), .payload = try fieldPayload(&e, ptr, f) } } });
                        refs[f] = (try e.add(.{ .tag = .load, .data = .{ .ty_op = .{ .ty = Type.fieldType(ip, agg, f), .operand = fp.toRef() } } })).toRef();
                    }
                    break :blk .{ agg, k };
                } else blk: {
                    const r = @backingInt(ptr.toIndex().?);
                    if (s.fields[r] == 0) continue;
                    const agg = s.agg[r];
                    const k = Type.fieldCount(ip, agg);
                    // The fields' loads, for stores of this load's value
                    // (`expand`).
                    s.fields[ii] = @intCast(e.insts.len);
                    s.agg[ii] = agg;
                    e.begin(inst);
                    for (0..k) |f| refs[f] = (try e.add(.{ .tag = .load, .data = .{ .ty_op = .{ .ty = Type.fieldType(ip, agg, f), .operand = fieldLocal(&s, r, @intCast(f)).toRef() } } })).toRef();
                    break :blk .{ agg, k };
                };
                changed = true;
                const payload: u32 = @intCast(e.extra.items.len);
                try e.extra.append(gpa, @intCast(k));
                try e.extra.appendSlice(gpa, @ptrCast(refs[0..k]));
                e.insts.set(ii, .{ .tag = .aggregate_init, .data = .{ .ty_pl = .{ .ty = agg, .payload = payload } } });
            },
            .store => {
                const r = @backingInt(data.bin_op.lhs.toIndex().?);
                if (s.root[r] != r) {
                    // A store to other memory of a split struct's load.
                    const l = s.fields[ii];
                    // 0 if the struct was not split.
                    const first = s.fields[l];
                    if (first == 0) continue;
                    const agg = s.agg[l];
                    const k = Type.fieldCount(ip, agg);
                    e.begin(inst);
                    for (0..k) |f| {
                        const fp = try e.add(.{ .tag = .struct_field_ptr, .data = .{ .ty_pl = .{ .ty = try fieldPtr(ip, tid, agg, f, false), .payload = try fieldPayload(&e, data.bin_op.lhs, f) } } });
                        const store: Inst = .{ .tag = .store, .data = .{ .bin_op = .{ .lhs = fp.toRef(), .rhs = @as(Inst.Index, @fromBackingInt(first + @as(u32, @intCast(f)))).toRef() } } };
                        if (f + 1 < k) _ = try e.add(store) else e.insts.set(ii, store);
                    }
                    changed = true;
                    continue;
                }
                if (s.fields[r] == 0) continue;
                changed = true;
                const agg = s.agg[r];
                const k = Type.fieldCount(ip, agg);
                const v = data.bin_op.rhs;
                const undef = if (v.toInterned()) |c| ip.keyTag(c) == .undef else false;
                e.begin(inst);
                for (0..k) |f| {
                    const fty = Type.fieldType(ip, agg, f);
                    const fv: Inst.Ref = if (undef)
                        .fromInterned(try ip.get(tid, .{ .undef = fty }))
                    else
                        (try e.add(.{ .tag = .struct_field_val, .data = .{ .ty_pl = .{ .ty = fty, .payload = try fieldPayload(&e, v, f) } } })).toRef();
                    const store: Inst = .{ .tag = .store, .data = .{ .bin_op = .{ .lhs = fieldLocal(&s, r, @intCast(f)).toRef(), .rhs = fv } } };
                    if (f + 1 < k) _ = try e.add(store) else e.insts.set(ii, store);
                }
            },
            else => unreachable,
        }
    }
    if (!changed) return 0;
    try e.rebuild(ir);
    return split;
}

/// A `StructField` payload for field `f` of `operand`.
fn fieldPayload(e: *Editor, operand: Inst.Ref, f: usize) Allocator.Error!u32 {
    const payload: u32 = @intCast(e.extra.items.len);
    try e.extra.appendSlice(e.gpa, &.{ @backingInt(operand), @intCast(f) });
    return payload;
}

/// Field `f`'s local of the split struct allocated by `r`.
fn fieldLocal(s: *const Scan, r: u32, f: u32) Inst.Index {
    return @fromBackingInt(if (f == 0) r else s.fields[r] + f - 1);
}

fn fieldPtr(ip: *InternPool, tid: InternPool.Tid, agg: Index, f: usize, is_const: bool) Allocator.Error!Index {
    return ip.get(tid, .{ .ptr_type = .{ .child = Type.fieldType(ip, agg, f), .flags = .{ .is_const = is_const } } });
}

/// The number of fields of the struct an alloc of type `ptr_ty` holds, if
/// it may be split, else 0: a struct or tuple of at most `max_fields`
/// runtime scalar fields (integers and enums up to 64 bits, `f32`, `f64`,
/// `bool`, pointers, slices), not packed, at their natural alignment.
fn candidate(ip: *const InternPool, ptr_ty: Index) u32 {
    if (ptr_ty == .none) return 0;
    return if (plainPtr(ip, ptr_ty)) candidateType(ip, Type.ptrInfo(ip, ptr_ty).child) else 0;
}

/// Whether a pointer to a struct also points to each field as a pointer of
/// the field's type does.
fn plainPtr(ip: *const InternPool, ptr_ty: Index) bool {
    const info = Type.ptrInfo(ip, ptr_ty);
    return info.flags.size == .one and !info.flags.is_volatile and !info.flags.is_allowzero and info.flags.alignment == 0 and info.packed_offset.host_size == 0;
}

fn candidateType(ip: *const InternPool, agg: Index) u32 {
    switch (ip.keyTag(agg)) {
        .struct_type => {
            const si = ip.structInfo(agg);
            if (si.layout == .@"packed" or si.status != .have_layout or si.field_aligns.len != 0) return 0;
        },
        .tuple_type => {},
        else => return 0,
    }
    const k = Type.fieldCount(ip, agg);
    if (k == 0 or k > max_fields) return 0;
    for (0..k) |f| {
        if (Type.comptimeFieldValue(ip, agg, f) != .none) return 0;
        const fty = Type.fieldType(ip, agg, f);
        switch (Type.class(ip, fty)) {
            .bool => {},
            .int => if (Type.intInfo(ip, fty).bits > 64 or Type.intInfo(ip, fty).bits == 0) return 0,
            .@"enum" => if (Type.abiSize(ip, fty) == 0 or Type.abiSize(ip, fty) > 8) return 0,
            .float => if (fty != .f32_type and fty != .f64_type) return 0,
            .pointer => {
                const pi = Type.ptrInfo(ip, fty);
                if (pi.flags.size == .c or pi.packed_offset.host_size != 0) return 0;
            },
            else => return 0,
        }
    }
    return @intCast(k);
}

/// `Scan.root` of a load from other memory than a candidate's.
const load_bit: u32 = 1 << 31;

/// Finds the candidate structs whose every use allows splitting, the loads
/// of structs used only by field reads and stores, and the stores of
/// candidates' loads to other memory.
const Scan = struct {
    ir: *const Ir,
    ip: *const InternPool,
    gpa: Allocator,
    /// For a candidate alloc, itself; for a field pointer of one, the
    /// alloc; for another load of a struct, itself with `load_bit`; else
    /// `none`.
    root: []u32,
    /// For a candidate alloc or another load of a struct: its field count,
    /// or 0 once a use rules it out. For a block: its `br`s. For a store
    /// of a candidate's load to other memory: the load (`resolve`). Once
    /// split, for an alloc or its load: the first field's new local or
    /// load.
    fields: []u32,
    /// For a split alloc and its loads: its struct type.
    agg: []Index,
    events: *std.ArrayList(Inst.Index),
    user: Inst.Tag = undefined,
    operand: u32 = 0,
    /// The instruction being scanned.
    cur: u32 = 0,
    /// Whether an operand did not come before its user.
    out_of_order: bool = false,

    pub fn use(s: *Scan, p: *Inst.Ref) void {
        defer s.operand += 1;
        const i = @backingInt(p.toIndex() orelse return);
        if (i >= s.cur) s.out_of_order = true;
        const r = s.root[i];
        if (r == none) return;
        if (r == i | load_bit) {
            // As a stored value, or a field read.
            switch (s.user) {
                .store => if (s.operand == 1) return,
                .struct_field_val => return,
                else => {},
            }
            s.fields[i] = 0;
            return;
        }
        const ok = switch (s.user) {
            .load => true,
            // As the destination only.
            .store => s.operand == 0,
            // Of the struct itself; a field's own fields are not split.
            .struct_field_ptr => r == i,
            else => false,
        };
        if (!ok) s.fields[r] = 0;
    }

    /// Scans every instruction once, in index order, where each operand
    /// comes before its user (a function where one does not is left
    /// alone). The events follow the same order, so each struct's alloc
    /// comes before its field pointers, loads, and stores; then the stores
    /// of candidates' loads to other memory, once every block's `br`s are
    /// counted. Returns false if the order does not hold.
    fn scan(s: *Scan, stores: *std.ArrayList(Inst.Index)) Allocator.Error!bool {
        const ir = s.ir;
        const tags = ir.instructions.items(.tag);
        const datas = ir.instructions.items(.data);
        stores.clearRetainingCapacity();
        for (tags, datas, 0..) |tag, data, i| {
            const ii: u32 = @intCast(i);
            const inst: Inst.Index = @fromBackingInt(ii);
            s.user = tag;
            s.operand = 0;
            s.cur = ii;
            Ssa.forEachOperandPtr(ir, inst, s);
            switch (tag) {
                .alloc => {
                    const k = candidate(s.ip, data.ty);
                    if (k == 0) continue;
                    s.root[i] = ii;
                    s.fields[i] = k;
                    try s.events.append(s.gpa, inst);
                },
                .struct_field_ptr => {
                    const p = @backingInt(@as(Inst.Ref, @fromBackingInt(ir.extra[data.ty_pl.payload])).toIndex() orelse continue);
                    if (s.root[p] != p) continue;
                    s.root[i] = p;
                    try s.events.append(s.gpa, inst);
                },
                .load => if (isRoot(s, data.ty_op.operand)) {
                    try s.events.append(s.gpa, inst);
                } else if (s.ip.keyTag(data.ty_op.ty) == .struct_type or s.ip.keyTag(data.ty_op.ty) == .tuple_type) {
                    if (!plainPtr(s.ip, ir.typeOf(data.ty_op.operand, s.ip))) continue;
                    const k = candidateType(s.ip, data.ty_op.ty);
                    if (k == 0) continue;
                    s.root[i] = ii | load_bit;
                    s.fields[i] = k;
                    try s.events.append(s.gpa, inst);
                },
                .store => if (isRoot(s, data.bin_op.lhs)) {
                    try s.events.append(s.gpa, inst);
                } else if (data.bin_op.rhs.toIndex()) |v| switch (tags[@backingInt(v)]) {
                    .block, .load => try stores.append(s.gpa, inst),
                    else => {},
                },
                .br => s.fields[@backingInt(data.br.block_inst)] += 1,
                else => {},
            }
        }
        if (s.out_of_order) return false;
        for (stores.items) |inst| {
            const bin = datas[@backingInt(inst)].bin_op;
            const l = s.resolve(bin.rhs) orelse continue;
            if (!plainPtr(s.ip, ir.typeOf(bin.lhs, s.ip))) continue;
            s.fields[@backingInt(inst)] = l;
            try s.events.append(s.gpa, inst);
        }
        return true;
    }

    /// The load of a candidate alloc that `ref` is, directly or as the
    /// result of blocks exited only by a `br` that ends them.
    fn resolve(s: *const Scan, ref: Inst.Ref) ?u32 {
        const ir = s.ir;
        var cur = ref;
        for (0..8) |_| {
            const i = @backingInt(cur.toIndex() orelse return null);
            const data = ir.instructions.items(.data)[i];
            switch (ir.instructions.items(.tag)[i]) {
                .load => return if (isRoot(s, data.ty_op.operand)) i else null,
                .block => {
                    if (s.fields[i] != 1) return null;
                    const x = ir.extraData(Ir.Block, data.ty_pl.payload);
                    if (x.data.body_len == 0) return null;
                    const last = ir.extra[x.end + x.data.body_len - 1];
                    if (ir.instructions.items(.tag)[last] != .br or @backingInt(ir.instructions.items(.data)[last].br.block_inst) != i) return null;
                    cur = ir.instructions.items(.data)[last].br.operand;
                },
                else => return null,
            }
        }
        return null;
    }

    /// Whether `ref` is a candidate alloc itself.
    fn isRoot(s: *const Scan, ref: Inst.Ref) bool {
        const i = @backingInt(ref.toIndex() orelse return false);
        return s.root[i] == i;
    }
};

/// Inserts instructions before others: appends them to the IR, then
/// rewrites every body with them in place.
const Editor = struct {
    gpa: Allocator,
    insts: std.MultiArrayList(Inst),
    extra: std.ArrayList(u32),
    /// Per original instruction: the start and length of the group in
    /// `ins` inserted before it; start `none` for none, or `dropped`.
    group: [][2]u32,
    ins: *std.ArrayList(Inst.Index),
    /// The number of original instructions.
    n: u32,
    /// The instruction the next `add`s go before.
    cur: u32 = none,

    fn begin(e: *Editor, before: Inst.Index) void {
        e.cur = @backingInt(before);
        e.group[e.cur] = .{ @intCast(e.ins.items.len), 0 };
    }

    fn add(e: *Editor, inst: Inst) Allocator.Error!Inst.Index {
        const i: Inst.Index = @fromBackingInt(@as(u32, @intCast(e.insts.len)));
        try e.insts.append(e.gpa, inst);
        try e.ins.append(e.gpa, i);
        e.group[e.cur][1] += 1;
        return i;
    }

    fn rebuild(e: *Editor, ir: *Ir) Allocator.Error!void {
        const old = ir.main_block;
        const len = e.extra.items[old];
        if (!try e.nested(old + 1, len)) return;
        const p: u32 = @intCast(e.extra.items.len);
        try e.extra.append(e.gpa, 0);
        const len_new = try e.list(old + 1, len);
        e.extra.items[p] = len_new;
        ir.main_block = p;
    }

    /// Rewrites the payloads of the instructions in the body at
    /// `extra[start..][0..len]` whose bodies change; returns whether this
    /// body changes itself.
    fn nested(e: *Editor, start: u32, len: u32) Allocator.Error!bool {
        var changes = false;
        for (start..start + len) |k| {
            const ii = e.extra.items[k];
            if (ii >= e.n) continue;
            if (e.group[ii][0] != none) changes = true;
            const datas = e.insts.items(.data);
            switch (e.insts.items(.tag)[ii]) {
                .block, .loop => {
                    const old = datas[ii].ty_pl.payload;
                    const body_len = e.extra.items[old];
                    if (!try e.nested(old + 1, body_len)) continue;
                    const p: u32 = @intCast(e.extra.items.len);
                    try e.extra.append(e.gpa, 0);
                    const len_new = try e.list(old + 1, body_len);
                    e.extra.items[p] = len_new;
                    datas[ii].ty_pl.payload = p;
                },
                .cond_br => {
                    const old = datas[ii].pl_op.payload;
                    const then_len = e.extra.items[old];
                    const else_len = e.extra.items[old + 1];
                    const then_changes = try e.nested(old + 3, then_len);
                    if (!try e.nested(old + 3 + then_len, else_len) and !then_changes) continue;
                    const p: u32 = @intCast(e.extra.items.len);
                    try e.extra.appendSlice(e.gpa, &.{ 0, 0, e.extra.items[old + 2] });
                    const then_new = try e.list(old + 3, then_len);
                    e.extra.items[p] = then_new;
                    const else_new = try e.list(old + 3 + then_len, else_len);
                    e.extra.items[p + 1] = else_new;
                    datas[ii].pl_op.payload = p;
                },
                .switch_br => {
                    const old = datas[ii].pl_op.payload;
                    const cases_len = e.extra.items[old];
                    const else_len = e.extra.items[old + 1];
                    var any = false;
                    var at = old + 2;
                    for (0..cases_len) |_| {
                        const items_len = e.extra.items[at];
                        const body_len = e.extra.items[at + 1];
                        if (try e.nested(at + 2 + items_len, body_len)) any = true;
                        at += 2 + items_len + body_len;
                    }
                    if (try e.nested(at, else_len)) any = true;
                    if (!any) continue;
                    const p: u32 = @intCast(e.extra.items.len);
                    try e.extra.appendSlice(e.gpa, &.{ cases_len, 0 });
                    at = old + 2;
                    for (0..cases_len) |_| {
                        const items_len = e.extra.items[at];
                        const body_len = e.extra.items[at + 1];
                        const h: u32 = @intCast(e.extra.items.len);
                        try e.extra.appendSlice(e.gpa, &.{ items_len, 0 });
                        for (0..items_len) |j| try e.extra.append(e.gpa, e.extra.items[at + 2 + j]);
                        const body_new = try e.list(at + 2 + items_len, body_len);
                        e.extra.items[h + 1] = body_new;
                        at += 2 + items_len + body_len;
                    }
                    const else_new = try e.list(at, else_len);
                    e.extra.items[p + 1] = else_new;
                    datas[ii].pl_op.payload = p;
                },
                else => {},
            }
        }
        return changes;
    }

    /// Appends the body at `extra[start..][0..len]` with the inserted
    /// instructions; returns its new length.
    fn list(e: *Editor, start: u32, len: u32) Allocator.Error!u32 {
        var out: u32 = 0;
        for (start..start + len) |k| {
            // `extra` may move while it grows: index it afresh.
            const ii = e.extra.items[k];
            if (ii < e.n and e.group[ii][0] == dropped) continue;
            if (ii < e.n and e.group[ii][0] != none) {
                const g = e.group[ii];
                for (e.ins.items[g[0]..][0..g[1]]) |i| try e.extra.append(e.gpa, @backingInt(i));
                out += g[1];
            }
            try e.extra.append(e.gpa, ii);
            out += 1;
        }
        return out;
    }
};
