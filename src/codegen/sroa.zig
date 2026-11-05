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
//!
//! A struct whose address is also passed to calls (a method that was not
//! inlined, SipHash's `self.round`) is split too, and keeps its memory:
//! around each point where other code could read or write that memory,
//! the fields are stored to it before and loaded back after (`Sync`).
//! Those points are the calls and the memory accesses through pointers
//! that may point to it, on any path from the first such call on; before
//! it, no other code has the struct's address.

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
    /// Calls that take a candidate's address, as (alloc, call).
    escapes: std.ArrayList([2]u32) = .empty,
    /// For structs split around calls: (alloc, instruction) per point to
    /// store the fields before and load them after (`Sync`).
    syncs: std.ArrayList([2]u32) = .empty,
    /// `Sync.walk`'s positions, next instructions, loop starts, ends, and
    /// loop weights.
    walk: std.ArrayList(u32) = .empty,

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        s.escapes.deinit(gpa);
        s.syncs.deinit(gpa);
        s.walk.deinit(gpa);
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
    try scratch.words.resize(gpa, 9 * n);
    var s: Scan = .{
        .ir = ir,
        .ip = ip,
        .root = scratch.words.items[0..n],
        .fields = scratch.words.items[n .. 2 * n],
        .agg = @ptrCast(scratch.words.items[4 * n .. 5 * n]),
        .esc = scratch.words.items[5 * n .. 6 * n],
        .alias = scratch.words.items[6 * n .. 7 * n],
        .same = scratch.words.items[7 * n .. 8 * n],
        .arg_copy = scratch.words.items[8 * n .. 9 * n],
        .events = &scratch.events,
        .escapes = &scratch.escapes,
        .gpa = gpa,
    };
    @memset(s.root, none);
    @memset(s.fields, 0);
    @memset(s.esc, 0);
    @memset(s.alias, none);
    @memset(s.same, 0);
    @memset(s.arg_copy, 0);
    scratch.events.clearRetainingCapacity();
    scratch.escapes.clearRetainingCapacity();
    scratch.syncs.clearRetainingCapacity();
    if (!try s.scan(&scratch.stores)) return 0;
    var sync: Sync = .{ .ir = ir, .ip = ip, .same = s.same };
    for (scratch.escapes.items) |esc| {
        if (s.fields[esc[0]] != 0) break;
    } else scratch.escapes.clearRetainingCapacity();
    if (scratch.escapes.items.len != 0) try sync.find(gpa, &s, scratch);

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
                if (s.esc[ii] != 0) {
                    // It keeps its memory for the calls: a new local per
                    // field.
                    const first: u32 = @intCast(e.insts.len);
                    try e.begin(inst);
                    for (0..k) |f| _ = try e.add(.{ .tag = .alloc, .data = .{ .ty = try fieldPtr(ip, tid, agg, f, false) } });
                    s.fields[ii] = first;
                    s.agg[ii] = agg;
                    continue;
                }
                // Field locals 1..k: new allocs before this one, which
                // becomes field 0's. `fields` then holds the first new one.
                const first: u32 = @intCast(e.insts.len);
                try e.begin(inst);
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
                    try e.begin(inst);
                    for (0..k) |f| {
                        const fp = try e.add(.{ .tag = .struct_field_ptr, .data = .{ .ty_pl = .{ .ty = try fieldPtr(ip, tid, agg, f, true), .payload = try fieldPayload(&e, ptr, f) } } });
                        refs[f] = (try e.add(.{ .tag = .load, .data = .{ .ty_op = .{ .ty = Type.fieldType(ip, agg, f), .operand = fp.toRef() } } })).toRef();
                    }
                    break :blk .{ agg, k };
                } else blk: {
                    const r = s.rootOf(@backingInt(ptr.toIndex().?));
                    if (s.fields[r] == 0) continue;
                    const agg = s.agg[r];
                    const k = Type.fieldCount(ip, agg);
                    // The fields' loads, for stores of this load's value
                    // (`expand`).
                    s.fields[ii] = @intCast(e.insts.len);
                    s.agg[ii] = agg;
                    try e.begin(inst);
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
                const r = s.rootOf(@backingInt(data.bin_op.lhs.toIndex().?));
                if (s.root[r] != r) {
                    // A store to other memory of a split struct's load.
                    const l = s.fields[ii];
                    // 0 if the struct was not split.
                    const first = s.fields[l];
                    if (first == 0) continue;
                    const agg = s.agg[l];
                    const k = Type.fieldCount(ip, agg);
                    try e.begin(inst);
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
                try e.begin(inst);
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
    for (scratch.syncs.items) |sy| {
        const r = sy[0];
        const x: Inst.Index = @fromBackingInt(sy[1]);
        const orig: Inst.Ref = @as(Inst.Index, @fromBackingInt(r)).toRef();
        const agg = s.agg[r];
        const k = Type.fieldCount(ip, agg);
        // Store the fields to its memory before `x`...
        try e.begin(x);
        for (0..k) |f| {
            const fv = try e.add(.{ .tag = .load, .data = .{ .ty_op = .{ .ty = Type.fieldType(ip, agg, f), .operand = fieldLocal(&s, r, @intCast(f)).toRef() } } });
            const fp = try e.add(.{ .tag = .struct_field_ptr, .data = .{ .ty_pl = .{ .ty = try fieldPtr(ip, tid, agg, f, false), .payload = try fieldPayload(&e, orig, f) } } });
            _ = try e.add(.{ .tag = .store, .data = .{ .bin_op = .{ .lhs = fp.toRef(), .rhs = fv.toRef() } } });
        }
        // ...and load them back after it, before the next instruction
        // kept, unless it does not return.
        // (`Call.ret_ty` is its first word.)
        if (e.insts.items(.tag)[sy[1]] == .call and e.extra.items[e.insts.items(.data)[sy[1]].pl_op.payload] == @backingInt(Index.noreturn_type)) continue;
        var y = sync.next[sy[1]];
        while (y != none and e.group[y][0] == dropped) y = sync.next[y];
        if (y == none) continue;
        try e.begin(@fromBackingInt(y));
        for (0..k) |f| {
            const fp = try e.add(.{ .tag = .struct_field_ptr, .data = .{ .ty_pl = .{ .ty = try fieldPtr(ip, tid, agg, f, true), .payload = try fieldPayload(&e, orig, f) } } });
            const fv = try e.add(.{ .tag = .load, .data = .{ .ty_op = .{ .ty = Type.fieldType(ip, agg, f), .operand = fp.toRef() } } });
            _ = try e.add(.{ .tag = .store, .data = .{ .bin_op = .{ .lhs = fieldLocal(&s, r, @intCast(f)).toRef(), .rhs = fv.toRef() } } });
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
    if (s.esc[r] != 0) return @fromBackingInt(s.fields[r] + f);
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

/// The load whose value `v` is, directly or as an argument of Sema's
/// inline call (a field of an `aggregate_init`).
fn wholeLoad(ir: *const Ir, v: Inst.Ref) ?u32 {
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    var i = @backingInt(v.toIndex() orelse return null);
    if (tags[i] == .struct_field_val) {
        const sf = ir.extraData(Ir.StructField, datas[i].ty_pl.payload).data;
        const agg = @backingInt(sf.operand.toIndex() orelse return null);
        if (tags[agg] != .aggregate_init) return null;
        const x = ir.extraData(Ir.Aggregate, datas[agg].ty_pl.payload);
        if (sf.index >= x.data.len) return null;
        i = @backingInt(ir.refSlice(x.end, x.data.len)[sf.index].toIndex() orelse return null);
    }
    return if (tags[i] == .load) i else null;
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
    /// For a candidate alloc: 1 if calls take its address.
    esc: []u32,
    /// For a constant local holding a candidate's address (an inline
    /// call's pointer parameter, which Sema stores once), or a tuple of an
    /// inline call's arguments holding it: the candidate, else `none`.
    alias: []u32,
    /// For a load of such a local: 1; it is the candidate's address, and
    /// its `root` the candidate.
    same: []u32,
    /// For a `*const` candidate stored from a parameter: 1. A by-value
    /// call argument of its whole value is then the parameter's memory,
    /// passed without a copy when the backend passes it by reference;
    /// split, it would be rebuilt and copied for the call.
    arg_copy: []u32,
    events: *std.ArrayList(Inst.Index),
    escapes: *std.ArrayList([2]u32),
    /// The candidates the instruction being scanned, a call, passes.
    passed: [4]u32 = undefined,
    passed_len: u8 = 0,
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
        // A tuple holding a candidate's address is read only by its
        // fields' reads.
        if (s.alias[i] != none and s.user != .struct_field_val and s.ir.instructions.items(.tag)[i] == .aggregate_init) {
            s.fields[s.alias[i]] = 0;
        }
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
        const itself = r == i or s.same[i] != 0;
        const ok = switch (s.user) {
            .load => true,
            // As the destination, or the value of an `alias`.
            .store => s.operand == 0 or (itself and s.aliasStore(r)),
            // Of the struct itself; a field's own fields are not split.
            .struct_field_ptr => itself,
            // As an argument (`Sync`), or in a tuple of an inline call's
            // arguments.
            .call => itself and s.operand != 0 and s.passed_len < s.passed.len,
            .aggregate_init => itself and s.passed_len == 0,
            else => false,
        };
        if (!ok) {
            s.fields[r] = 0;
        } else if (s.user == .call or s.user == .aggregate_init) {
            s.passed[s.passed_len] = r;
            s.passed_len += 1;
        }
    }

    /// Whether the store being scanned, of candidate `r`'s address, makes
    /// its destination an `alias` of `r`: the destination is a constant
    /// local of that pointer type, stored once.
    fn aliasStore(s: *Scan, r: u32) bool {
        const ir = s.ir;
        const lhs = ir.instructions.items(.data)[s.cur].bin_op.lhs;
        const p = @backingInt(lhs.toIndex() orelse return false);
        if (ir.instructions.items(.tag)[p] != .alloc or s.alias[p] != none) return false;
        const ty = ir.instructions.items(.data)[p].ty;
        if (ty == .none) return false;
        const info = Type.ptrInfo(s.ip, ty);
        if (!info.flags.is_const or info.child != ir.instructions.items(.data)[r].ty) return false;
        s.alias[p] = r;
        return true;
    }

    /// The candidate `i` is, itself or as a load of its `alias`.
    fn rootOf(s: *const Scan, i: u32) u32 {
        return if (s.same[i] != 0) s.root[i] else i;
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
            s.passed_len = 0;
            Ssa.forEachOperandPtr(ir, inst, s);
            switch (tag) {
                .call => {
                    for (s.passed[0..s.passed_len]) |r| {
                        s.esc[r] = 1;
                        try s.escapes.append(s.gpa, .{ r, ii });
                    }
                    const x = ir.extraData(Ir.Call, data.pl_op.payload);
                    for (ir.refSlice(x.end, x.data.args_len)) |arg| {
                        const l = @backingInt(arg.toIndex() orelse continue);
                        if (tags[l] != .load or !isRoot(s, datas[l].ty_op.operand)) continue;
                        const r = s.rootOf(@backingInt(datas[l].ty_op.operand.toIndex().?));
                        if (s.arg_copy[r] != 0) s.fields[r] = 0;
                    }
                },
                .aggregate_init => if (s.passed_len != 0) {
                    s.alias[i] = s.passed[0];
                },
                .struct_field_val => {
                    // The candidate's address, read from a tuple holding it.
                    const x = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
                    const t = @backingInt(x.operand.toIndex() orelse continue);
                    const r = s.alias[t];
                    if (r == none or tags[t] != .aggregate_init) continue;
                    const elem: Inst.Ref = @fromBackingInt(ir.extra[ir.extraData(Ir.Aggregate, datas[t].ty_pl.payload).end + x.index]);
                    const e = @backingInt(elem.toIndex() orelse continue);
                    if (s.rootOf(e) != r or (e != r and s.same[e] == 0)) continue;
                    s.root[i] = r;
                    s.same[i] = 1;
                },
                .alloc => {
                    const k = candidate(s.ip, data.ty);
                    if (k == 0) continue;
                    s.root[i] = ii;
                    s.fields[i] = k;
                    try s.events.append(s.gpa, inst);
                },
                .struct_field_ptr => {
                    const p = @backingInt(@as(Inst.Ref, @fromBackingInt(ir.extra[data.ty_pl.payload])).toIndex() orelse continue);
                    if (s.root[p] != p and s.same[p] == 0) continue;
                    s.root[i] = s.rootOf(p);
                    try s.events.append(s.gpa, inst);
                },
                .load => if (isRoot(s, data.ty_op.operand)) {
                    try s.events.append(s.gpa, inst);
                } else if (data.ty_op.operand.toIndex() != null and s.alias[@backingInt(data.ty_op.operand.toIndex().?)] != none) {
                    s.root[i] = s.alias[@backingInt(data.ty_op.operand.toIndex().?)];
                    s.same[i] = 1;
                } else if (s.ip.keyTag(data.ty_op.ty) == .struct_type or s.ip.keyTag(data.ty_op.ty) == .tuple_type) {
                    if (!plainPtr(s.ip, ir.typeOf(data.ty_op.operand, s.ip))) continue;
                    const k = candidateType(s.ip, data.ty_op.ty);
                    if (k == 0) continue;
                    s.root[i] = ii | load_bit;
                    s.fields[i] = k;
                    try s.events.append(s.gpa, inst);
                },
                .store => if (isRoot(s, data.bin_op.lhs)) {
                    // A `const` copy of other memory than a candidate's is
                    // left whole: when nothing writes that memory while
                    // the copy is read, `forward` reads it there instead.
                    const r = s.rootOf(@backingInt(data.bin_op.lhs.toIndex().?));
                    if (wholeLoad(ir, data.bin_op.rhs)) |l| if (!isRoot(s, datas[l].ty_op.operand) and Type.ptrInfo(s.ip, datas[r].ty).flags.is_const) {
                        s.fields[r] = 0;
                        if (s.root[l] == l | load_bit) s.fields[l] = 0;
                    };
                    try s.events.append(s.gpa, inst);
                    if (data.bin_op.rhs.toIndex()) |v| if (tags[@backingInt(v)] == .arg and Type.ptrInfo(s.ip, datas[r].ty).flags.is_const) {
                        s.arg_copy[r] = 1;
                    };
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
        return s.root[i] == i or s.same[i] != 0;
    }
};

/// Where a struct split around calls stores its fields to its memory and
/// loads them back (the file's doc comment). Positions number the
/// instructions in body order; a path between instructions goes forward
/// in that order except through a loop's back edge, so the instructions
/// on paths from a call that takes the address are at most those from
/// its position on, or from its outermost loop's start.
const Sync = struct {
    ir: *const Ir,
    ip: *const InternPool,
    /// `Scan.same`.
    same: []const u32,
    /// Per instruction: its position, or `none` outside every body.
    pos: []u32 = &.{},
    /// Per instruction: the next one in its body, or `none`.
    next: []u32 = &.{},
    /// Per instruction: the position of its outermost loop, or its own.
    outer: []u32 = &.{},
    /// Per instruction: the position after its body's last instruction and
    /// theirs; the instructions it dominates are before it.
    end: []u32 = &.{},
    /// Per instruction: 8 to the power of its loop depth (at most 6).
    weight: []u32 = &.{},
    count: u32 = 0,
    loop: u32 = none,
    depth: u5 = 0,

    /// Fills `scratch.syncs` for the candidates in `scratch.escapes`.
    fn find(sy: *Sync, gpa: Allocator, s: *const Scan, scratch: *Scratch) Allocator.Error!void {
        const n = sy.ir.instructions.len;
        try scratch.walk.resize(gpa, 5 * n);
        sy.pos = scratch.walk.items[0..n];
        sy.next = scratch.walk.items[n .. 2 * n];
        sy.outer = scratch.walk.items[2 * n .. 3 * n];
        sy.end = scratch.walk.items[3 * n .. 4 * n];
        sy.weight = scratch.walk.items[4 * n .. 5 * n];
        @memset(sy.pos, none);
        @memset(sy.next, none);
        @memset(sy.end, 0);
        sy.body(sy.ir.mainBody());
        // From where on each candidate's memory may be reached by others:
        // per alloc, the earliest of its escapes, until the end of its
        // scope (a stale pointer to it is illegal to use).
        var from: std.ArrayList([2]u32) = .empty;
        defer from.deinit(gpa);
        for (scratch.escapes.items) |esc| {
            const a = esc[0];
            if (s.fields[a] == 0) continue;
            const t = @max(sy.pos[a] +% 1, if (sy.pos[esc[1]] == none) 0 else sy.outer[esc[1]]);
            for (from.items) |*f| {
                if (f[0] == a) {
                    f[1] = @min(f[1], t);
                    break;
                }
            } else try from.append(gpa, .{ a, t });
        }
        for (0..n) |i| {
            const p = sy.pos[i];
            if (p == none) continue;
            var ok: ?bool = null;
            for (from.items) |f| {
                if (p < f[1] or p >= sy.end[f[0]]) continue;
                if (ok == null) ok = sy.safe(@intCast(i));
                if (!ok.?) try scratch.syncs.append(gpa, .{ f[0], @intCast(i) });
            }
        }
        // A struct is split only where that saves memory accesses: its
        // field accesses, weighted by loop depth, outnumber the stores and
        // loads of its fields at its sync points (block sort's iterator,
        // whose fields are read between calls in its loops, is not).
        const tags = sy.ir.instructions.items(.tag);
        for (from.items) |f| {
            const a = f[0];
            var saved: u64 = 0;
            for (0..n) |i| {
                if (tags[i] == .struct_field_ptr and s.root[i] == a and sy.pos[i] != none) saved += sy.weight[i];
            }
            var cost: u64 = 0;
            for (scratch.syncs.items) |x| {
                if (x[0] == a) cost += 2 * @as(u64, s.fields[a]) * sy.weight[x[1]];
            }
            if (saved <= cost) s.fields[a] = 0;
        }
        var kept: usize = 0;
        for (scratch.syncs.items) |x| {
            if (s.fields[x[0]] == 0) continue;
            scratch.syncs.items[kept] = x;
            kept += 1;
        }
        scratch.syncs.shrinkRetainingCapacity(kept);
    }

    fn body(sy: *Sync, b: []const Inst.Index) void {
        const ir = sy.ir;
        for (b, 0..) |inst, k| {
            const i = @backingInt(inst);
            sy.pos[i] = sy.count;
            sy.count += 1;
            sy.outer[i] = if (sy.loop != none) sy.loop else sy.pos[i];
            sy.weight[i] = @as(u32, 1) << @intCast(3 * @as(u5, @min(sy.depth, 6)));
            sy.next[i] = if (k + 1 < b.len) @backingInt(b[k + 1]) else none;
            defer if (k + 1 == b.len) for (b) |x| {
                sy.end[@backingInt(x)] = sy.count;
            };
            const data = ir.instructions.items(.data)[i];
            switch (ir.instructions.items(.tag)[i]) {
                .block => {
                    const x = ir.extraData(Ir.Block, data.ty_pl.payload);
                    sy.body(ir.bodySlice(x.end, x.data.body_len));
                },
                .loop => {
                    const outer = sy.loop;
                    if (outer == none) sy.loop = sy.pos[i];
                    sy.depth +|= 1;
                    const x = ir.extraData(Ir.Block, data.ty_pl.payload);
                    sy.body(ir.bodySlice(x.end, x.data.body_len));
                    sy.depth -= 1;
                    sy.loop = outer;
                },
                .cond_br => {
                    const p = data.pl_op.payload;
                    const then_len = ir.extra[p];
                    const else_len = ir.extra[p + 1];
                    sy.body(ir.bodySlice(p + 3, then_len));
                    sy.body(ir.bodySlice(p + 3 + then_len, else_len));
                },
                .switch_br => {
                    var cases = ir.switchCases(data.pl_op.payload);
                    while (cases.next()) |c| sy.body(c.body);
                    sy.body(cases.elseBody());
                },
                else => {},
            }
        }
    }

    /// Whether instruction `i` neither calls nor reads or writes memory
    /// that may be a split struct's: memory reached only from a local, a
    /// parameter, or a constant address. A split struct's own field
    /// accesses become its locals'.
    fn safe(sy: *const Sync, i: u32) bool {
        const ir = sy.ir;
        const data = ir.instructions.items(.data)[i];
        return switch (ir.instructions.items(.tag)[i]) {
            .load => sy.known(data.ty_op.operand),
            .store => sy.known(data.bin_op.lhs),
            .ptr_elem_val, .slice_elem_val => sy.known(data.bin_op.lhs),
            .arg, .alloc, .add_wrap, .sub_wrap, .mul_wrap, .add_with_overflow, .sub_with_overflow, .mul_with_overflow => true,
            .add_float, .sub_float, .mul_float, .div_float, .div_trunc, .div_floor, .div_ceil, .rem, .mod => true,
            .min_float, .max_float, .neg_float, .sqrt, .sin, .cos, .tan, .exp, .log, .abs_float, .floor, .ceil, .round, .trunc_float, .mul_add => true,
            .bit_and, .bit_or, .xor, .shl, .shr, .not, .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq, .cmp_vector => true,
            .reduce, .min_int, .max_int, .select, .shuffle, .intcast, .trunc, .float_cast, .float_from_int, .int_from_float, .bitcast => true,
            .clz, .ctz, .popcount, .byte_swap, .bit_reverse, .int_from_bool, .int_from_ptr, .ptr_from_int => true,
            .ret_addr, .frame_addr, .extern_ptr, .extern_pcrel, .extern_tls, .tls_ptr => true,
            .block, .loop, .repeat, .br, .cond_br, .switch_br, .ret, .unreach, .trap, .breakpoint => true,
            .struct_field_ptr, .struct_field_val, .ptr_elem_ptr, .slice_elem_ptr, .array_elem_val, .slice_ptr, .slice_len, .slice, .ptr_add => true,
            .is_null, .is_non_null, .optional_payload, .optional_payload_ptr, .wrap_optional => true,
            .is_err, .is_non_err, .unwrap_errunion_payload, .unwrap_errunion_err, .unwrap_errunion_payload_ptr, .unwrap_errunion_err_ptr => true,
            .wrap_errunion_payload, .wrap_errunion_err, .aggregate_init, .union_init, .get_union_tag => true,
            .dbg_stmt, .dbg_inline_begin, .dbg_inline_end, .save_err_return_trace_index => true,
            else => false,
        };
    }

    /// Whether pointer `ref` is derived from a local, a parameter, or a
    /// constant address: not from a pointer other code may have stored.
    fn known(sy: *const Sync, ref: Inst.Ref) bool {
        const ir = sy.ir;
        var cur = ref;
        for (0..16) |_| {
            const i = @backingInt(cur.toIndex() orelse return true);
            if (sy.same[i] != 0) return true;
            const data = ir.instructions.items(.data)[i];
            cur = switch (ir.instructions.items(.tag)[i]) {
                .alloc, .arg => return true,
                .struct_field_ptr => @fromBackingInt(ir.extra[data.ty_pl.payload]),
                .ptr_elem_ptr, .ptr_add, .slice_elem_ptr, .slice => ir.extraData(Ir.Bin, data.ty_pl.payload).data.lhs,
                .slice_ptr, .optional_payload_ptr, .unwrap_errunion_payload_ptr, .unwrap_errunion_err_ptr => data.ty_op.operand,
                else => return false,
            };
        }
        return false;
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

    /// Starts or continues the group before `before`; a group made
    /// earlier and followed by others moves to the end of `ins`.
    fn begin(e: *Editor, before: Inst.Index) Allocator.Error!void {
        e.cur = @backingInt(before);
        const g = e.group[e.cur];
        const end: u32 = @intCast(e.ins.items.len);
        if (g[0] == none) {
            e.group[e.cur] = .{ end, 0 };
        } else if (g[0] + g[1] != end) {
            for (g[0]..g[0] + g[1]) |k| try e.ins.append(e.gpa, e.ins.items[k]);
            e.group[e.cur] = .{ end, g[1] };
        }
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
                    // Each case: `items_len`, `ranges_len`, `body_len`,
                    // the items and ranges' values, the body (`Ir.SwitchBr`).
                    var at = old + 2;
                    for (0..cases_len) |_| {
                        const values_len = e.extra.items[at] + 2 * e.extra.items[at + 1];
                        const body_len = e.extra.items[at + 2];
                        if (try e.nested(at + 3 + values_len, body_len)) any = true;
                        at += 3 + values_len + body_len;
                    }
                    if (try e.nested(at, else_len)) any = true;
                    if (!any) continue;
                    const p: u32 = @intCast(e.extra.items.len);
                    try e.extra.appendSlice(e.gpa, &.{ cases_len, 0 });
                    at = old + 2;
                    for (0..cases_len) |_| {
                        const values_len = e.extra.items[at] + 2 * e.extra.items[at + 1];
                        const body_len = e.extra.items[at + 2];
                        const h: u32 = @intCast(e.extra.items.len);
                        try e.extra.appendSlice(e.gpa, &.{ e.extra.items[at], e.extra.items[at + 1], 0 });
                        for (0..values_len) |j| try e.extra.append(e.gpa, e.extra.items[at + 3 + j]);
                        const body_new = try e.list(at + 3 + values_len, body_len);
                        e.extra.items[h + 2] = body_new;
                        at += 3 + values_len + body_len;
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
