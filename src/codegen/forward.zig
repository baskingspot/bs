//! Memory forwarding on the IR (docs/slop/architecture.md, "Forwarding"):
//! a `const` local initialized with a whole load of an aggregate, and only
//! read, reads the loaded memory instead when nothing may write that
//! memory while the local is in use. Sema makes such copies for
//! `const x = p.*`, for `const x = buf[i]`, and for the by-value
//! parameters of inline calls (Sema's and the backend inliner's, whose
//! `self: S` receivers are the common case); each one cost a copy into
//! the frame to read a field or two. And a load of a scalar that a
//! dominating store wrote, or a dominating load read, reads that value
//! instead when nothing in between may write the memory: `self.index += 1`
//! followed by a read of `self.index`, or `self.len` read twice. Runs on
//! the CodeGen workers before proving checks, which reads what was
//! forwarded as equal values; scalar replacement leaves the copies whole
//! for it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const Index = InternPool.Index;
const Ir = @import("../Ir.zig");
const Inst = Ir.Inst;
const Type = @import("../Type.zig");
const Ssa = @import("Ssa.zig");

const none = std.math.maxInt(u32);

/// Forwards the copies or the loads that qualify; returns how many.
pub fn run(gpa: Allocator, ip: *const InternPool, ir: *Ir, scratch: *std.ArrayList(u32)) Allocator.Error!u32 {
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    // A function with nothing to forward costs one pass to find that.
    // There is no load to forward unless a load goes through the same
    // base pointer as an earlier load or store, or the same local's
    // pointer reloaded (`self.x`); a hash of each base finds that, also
    // when two bases share a hash. Loads and stores straight through a
    // local are left to `Ssa.plan`.
    var copies = false;
    var loaded: u256 = 0;
    var stored: u256 = 0;
    var reloads = false;
    for (tags, datas) |tag, data| switch (tag) {
        .load => if (baseHash(ir, data.ty_op.operand)) |h| {
            reloads = reloads or (loaded | stored) & h != 0;
            loaded |= h;
        },
        .store => if (baseHash(ir, data.bin_op.lhs)) |h| {
            stored |= h;
        } else if (!copies) {
            // A copy: a store of a load, or of a field of an inline
            // call's argument tuple, into a candidate local.
            const v = data.bin_op.rhs.toIndex() orelse continue;
            switch (tags[@backingInt(v)]) {
                .load, .struct_field_val => {},
                else => continue,
            }
            const a = data.bin_op.lhs.toIndex() orelse continue;
            copies = tags[@backingInt(a)] == .alloc and candidate(ip, datas[@backingInt(a)].ty);
        },
        else => {},
    };
    if (!copies and !reloads) return 0;

    const n = ir.instructions.len;
    scratch.clearRetainingCapacity();
    const words = try scratch.addManyAsSlice(gpa, 12 * n + 1);
    var w: Walk = .{
        .ir = ir,
        .ip = ip,
        .pos = words[0..n],
        .scope_end = words[n .. 2 * n],
        .loop_of = words[2 * n .. 3 * n],
        .root = words[3 * n .. 4 * n],
        .last = words[4 * n .. 5 * n],
        .store = words[5 * n .. 6 * n],
        .order = words[6 * n .. 7 * n],
        .uses = words[7 * n .. 8 * n],
        .flags = @ptrCast(words[8 * n .. 9 * n]),
        .subst = words[9 * n .. 10 * n],
        .exits = words[11 * n .. 12 * n],
    };
    // Read for any operand; the rest is set as the walk reaches it.
    @memset(w.root, none);
    @memset(w.subst, none);
    if (copies) {
        @memset(w.uses, 0);
        w.count_uses = true;
    }
    w.body(ir.mainBody());
    w.straight();

    var count: u32 = if (copies) w.forwardCopies(words[10 * n ..][0 .. w.next + 1]) else 0;
    if (reloads) {
        const loads_forwarded = w.forwardLoads();
        if (loads_forwarded != 0) {
            const Subst = struct {
                subst: []const u32,
                pub fn use(s: @This(), ref: *Inst.Ref) void {
                    const i = ref.toIndex() orelse return;
                    const to = s.subst[@backingInt(i)];
                    if (to != none) ref.* = @fromBackingInt(to);
                }
            };
            for (w.order[0..w.next]) |i| Ssa.forEachOperandPtr(ir, @fromBackingInt(i), Subst{ .subst = w.subst });
        }
        count += loads_forwarded;
    }
    return count;
}

/// One bit of 256 for the memory a load or store through `ptr` reaches,
/// by its base pointer (what `Walk.keyOf` reads, before `Walk.canon`), or
/// null for a local's own memory, which `Ssa.plan` forwards.
fn baseHash(ir: *const Ir, ptr: Inst.Ref) ?u256 {
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    var base = ptr;
    if (base.toIndex()) |i| {
        switch (tags[@backingInt(i)]) {
            .alloc => return null,
            .struct_field_ptr => base = ir.extraData(Ir.StructField, datas[@backingInt(i)].ty_pl.payload).data.operand,
            else => {},
        }
    }
    if (base.toIndex()) |i| if (tags[@backingInt(i)] == .load) {
        if (datas[@backingInt(i)].ty_op.operand.toIndex()) |a| if (tags[@backingInt(a)] == .alloc) {
            base = a.toRef();
        };
    };
    return @as(u256, 1) << @intCast(std.hash.int(@backingInt(base)) % 256);
}

/// A `const` local of an aggregate, which CodeGen keeps in memory.
fn candidate(ip: *const InternPool, ptr_ty: Index) bool {
    if (ptr_ty == .none) return false;
    const info = Type.ptrInfo(ip, ptr_ty);
    if (!info.flags.is_const or info.flags.is_volatile) return false;
    return switch (ip.keyTag(info.child)) {
        .struct_type => !Type.isPackedStruct(ip, info.child),
        .tuple_type, .array_type => true,
        else => false,
    };
}

/// A value CodeGen keeps in registers, which may stand in for a load.
fn scalar(ip: *const InternPool, ty: Index) bool {
    return switch (Type.class(ip, ty)) {
        .bool, .error_set => true,
        .int => Type.intInfo(ip, ty).bits <= 64,
        .@"enum" => Type.abiSize(ip, ty) <= 8,
        .float => ty == .f32_type or ty == .f64_type,
        // A slice is a pair of registers.
        .pointer => true,
        else => false,
    };
}

/// An ordinary pointer to one value.
fn plainPtr(ip: *const InternPool, ty: Index) bool {
    if (ip.keyTag(ty) != .ptr_type) return false;
    const info = Type.ptrInfo(ip, ty);
    return info.flags.size == .one and !info.flags.is_volatile and info.flags.address_space == .generic and
        info.flags.vector_index == 0 and info.packed_offset.host_size == 0;
}

/// A pointer to a struct whose fields do not overlap.
fn disjointFields(ip: *const InternPool, ptr_ty: Index) bool {
    const parent = Type.childType(ip, ptr_ty);
    return switch (ip.keyTag(parent)) {
        .struct_type => !Type.isPackedStruct(ip, parent),
        .tuple_type => true,
        else => false,
    };
}

const Cached = struct { ty: Index = .none, yes: bool = false };

/// What a load or store reads or writes: field `field - 1` of the memory
/// `base` points to, or with `field` 0 all of it.
const Key = struct {
    base: Inst.Ref,
    field: u32,
    /// `base` points to a struct whose fields do not overlap.
    disjoint: bool,
    /// The local `base` points into, or `none`.
    root: u32,
};

/// A value known to be in memory: what `inst`, a load or a store,
/// read or wrote there.
const Known = struct {
    key: Key,
    value: Inst.Ref,
    ty: Index,
    inst: u32,
};

const max_known = 32;

const Flags = packed struct(u32) {
    /// The local's address is used other than to read through it, to
    /// derive a pointer into it, or as a store's address.
    escaped: bool = false,
    /// It is used in another loop than the one it is in.
    loop_mismatch: bool = false,
    /// It is stored to more than once, or used before its store.
    multi: bool = false,
    /// It became a pointer to the memory it copied (`forwardCopies`).
    forwarded: bool = false,
    _: u28 = 0,
};

const Walk = struct {
    ir: *Ir,
    ip: *const InternPool,
    /// Each instruction's position in body order, nested bodies inline.
    pos: []u32,
    /// The last position of the body that holds each instruction.
    scope_end: []u32,
    /// The innermost `loop` around each instruction.
    loop_of: []u32,
    /// The local each pointer points into.
    root: []u32,
    /// Each local's last use, by position.
    last: []u32,
    /// Each local's store.
    store: []u32,
    /// The instruction at each position.
    order: []u32,
    /// Each instruction's uses by the instructions walked, counted when
    /// `count_uses` is set.
    uses: []u32,
    flags: []Flags,
    /// Per load, the value it was found to read, or `none`.
    subst: []u32,
    /// Per `block`, how many `br`s exit it.
    exits: []u32,
    plain_cache: [64]Cached = @splat(.{}),
    disjoint_cache: [64]Cached = @splat(.{}),
    next: u32 = 0,
    count_uses: bool = false,
    loop: u32 = none,
    /// The instruction `use` is called for.
    user: u32 = none,

    /// Turns the copies that qualify into the memory they copy, given
    /// room for a count per position; returns how many.
    fn forwardCopies(w: *Walk, prefix: []u32) u32 {
        const ir = w.ir;
        const ip = w.ip;
        const tags = ir.instructions.items(.tag);
        const datas = ir.instructions.items(.data);
        // Writes up to each position. A store into a local whose address
        // does not escape writes no other memory.
        prefix[0] = 0;
        for (w.order[0..w.next], 0..) |i, p| prefix[p + 1] = prefix[p] + @intFromBool(switch (tags[i]) {
            .store, .memset, .memcpy, .memmove, .set_union_tag, .optional_payload_ptr_set, .errunion_payload_ptr_set, .call, .atomic_store, .atomic_rmw, .cmpxchg, .assembly, .vector_store_elem, .c_va_start, .c_va_arg, .c_va_copy => w.writes(i, none),
            else => false,
        });

        var count: u32 = 0;
        for (w.order[0..w.next]) |ii| {
            if (tags[ii] != .alloc or !candidate(ip, datas[ii].ty)) continue;
            const f = w.flags[ii];
            if (f.escaped or f.loop_mismatch or f.multi or w.store[ii] == none) continue;
            const store = w.store[ii];
            const load = w.sourceLoad(datas[store].bin_op.rhs) orelse continue;
            const l = @backingInt(load);
            const src = datas[l].ty_op.operand;
            if (!w.sameLayout(src, datas[ii].ty)) continue;
            // The load dominates the alloc, in the same loop.
            if (!(w.pos[l] < w.pos[ii] and w.pos[ii] <= w.scope_end[l])) continue;
            if (w.loop_of[l] != w.loop_of[ii]) continue;
            // Nothing may write the source from the load to the local's last
            // read: no write to unknown memory, and when the source is in a
            // local, no store into that local.
            const end = @max(w.last[ii], w.pos[store]);
            if (prefix[end + 1] - prefix[w.pos[l] + 1] != 0) continue;
            if (src.toIndex()) |s| if (w.root[@backingInt(s)] != none) {
                const r = w.root[@backingInt(s)];
                if (for (w.order[w.pos[l] + 1 .. end + 1]) |i| {
                    if (w.writes(i, r)) break true;
                } else false) continue;
            };
            const ty = datas[ii].ty;
            tags[ii] = .bitcast;
            datas[ii] = .{ .ty_op = .{ .ty = ty, .operand = src } };
            // The initializing store goes; the loaded value is left for dead
            // code.
            tags[store] = .bitcast;
            datas[store] = .{ .ty_op = .{ .ty = ty, .operand = src } };
            w.flags[ii].forwarded = true;
            count += 1;
        }
        return count;
    }

    /// Store-to-load forwarding and load reuse: a load of a scalar from
    /// memory that a dominating store in the same loop wrote, or a
    /// dominating load in the same loop read, with no write in between
    /// that may reach it, becomes that value (`subst`). Positions are
    /// scanned in order, so a write anywhere between the two, also in a
    /// branch not taken, forgets what was known. A panic does not return,
    /// so the safety checks between them forget nothing.
    fn forwardLoads(w: *Walk) u32 {
        const ir = w.ir;
        const subst = w.subst;
        const ip = w.ip;
        const tags = ir.instructions.items(.tag);
        const datas = ir.instructions.items(.data);
        var known: [max_known]Known = undefined;
        var len: u32 = 0;
        var count: u32 = 0;
        for (w.order[0..w.next]) |i| {
            const data = datas[i];
            switch (tags[i]) {
                .load => {
                    const ty = data.ty_op.ty;
                    if (w.direct(data.ty_op.operand) or !scalar(ip, ty)) continue;
                    const key = w.keyOf(data.ty_op.operand) orelse continue;
                    if (w.promoted(key)) continue;
                    const match: ?Known = for (known[0..len]) |k| {
                        if (k.key.base == key.base and k.key.field == key.field) break k;
                    } else null;
                    if (match) |k| {
                        const s = k.inst;
                        if (k.ty == ty and w.pos[s] < w.pos[i] and w.pos[i] <= w.scope_end[s] and w.loop_of[s] == w.loop_of[i]) {
                            subst[i] = @backingInt(k.value);
                            count += 1;
                            continue;
                        }
                    }
                    len = remember(&known, len, .{ .key = key, .value = Inst.Index.toRef(@fromBackingInt(i)), .ty = ty, .inst = i });
                },
                .store => {
                    const ptr = data.bin_op.lhs;
                    if (w.direct(ptr)) {
                        // A whole store into an aggregate local.
                        len = w.forget(&known, len, w.unknownKey(ptr));
                        continue;
                    }
                    const key = w.keyOf(ptr) orelse {
                        len = w.forget(&known, len, w.unknownKey(ptr));
                        continue;
                    };
                    if (w.promoted(key)) continue;
                    len = w.forget(&known, len, key);
                    const value = w.resolve(data.bin_op.rhs);
                    const ty = ir.typeOf(value, ip);
                    if (scalar(ip, ty)) len = remember(&known, len, .{ .key = key, .value = value, .ty = ty, .inst = i });
                },
                .memset, .memcpy, .memmove, .set_union_tag => len = w.forget(&known, len, w.unknownKey(data.bin_op.lhs)),
                .optional_payload_ptr_set, .errunion_payload_ptr_set => len = w.forget(&known, len, w.unknownKey(data.ty_op.operand)),
                .call, .atomic_store, .atomic_rmw, .cmpxchg, .assembly, .vector_store_elem, .c_va_start, .c_va_arg, .c_va_copy => {
                    if (!w.writes(i, none)) continue;
                    // Only memory in a local whose address does not
                    // escape stays known.
                    var keep: u32 = 0;
                    for (known[0..len]) |k| {
                        if (k.key.root == none or w.flags[k.key.root].escaped) continue;
                        known[keep] = k;
                        keep += 1;
                    }
                    len = keep;
                },
                else => {},
            }
        }
        return count;
    }

    /// Whether `ptr` is a local whose address does not escape: its loads
    /// and stores are `Ssa.plan`'s, and touch no other memory.
    fn direct(w: *const Walk, ptr: Inst.Ref) bool {
        const i = ptr.toIndex() orelse return false;
        const r = @backingInt(i);
        return w.ir.instructions.items(.tag)[r] == .alloc and !w.flags[r].escaped;
    }

    /// Whether `key` is a scalar local whose address does not escape,
    /// whose loads `Ssa.plan` forwards or promotes to a register itself.
    /// Forwarding them here first only lengthened intervals (fmt +3%).
    fn promoted(w: *const Walk, key: Key) bool {
        if (key.root == none or w.flags[key.root].escaped) return false;
        const alloc_ty = w.ir.instructions.items(.data)[key.root].ty;
        return scalar(w.ip, Type.ptrInfo(w.ip, alloc_ty).child);
    }

    /// Adds `k` to what is known, in place of what it overwrites (same
    /// key), or else dropping the oldest entry when full.
    fn remember(known: *[max_known]Known, len: u32, k: Known) u32 {
        for (known[0..len]) |*e| if (e.key.base == k.key.base and e.key.field == k.key.field) {
            e.* = k;
            return len;
        };
        if (len < max_known) {
            known[len] = k;
            return len + 1;
        }
        std.mem.copyForwards(Known, known[0 .. max_known - 1], known[1..]);
        known[max_known - 1] = k;
        return len;
    }

    /// Drops what a write described by `key` may change.
    fn forget(w: *const Walk, known: *[max_known]Known, len: u32, key: Key) u32 {
        var keep: u32 = 0;
        for (known[0..len]) |k| {
            if (w.mayOverlap(key, k.key)) continue;
            known[keep] = k;
            keep += 1;
        }
        return keep;
    }

    fn mayOverlap(w: *const Walk, a: Key, b: Key) bool {
        if (a.base == b.base and a.base != .none)
            return !(a.disjoint and a.field != 0 and b.field != 0 and a.field != b.field);
        // Two locals never overlap; a local whose address does not escape
        // overlaps no memory reached otherwise.
        if (a.root != none and b.root != none) return a.root == b.root;
        if (a.root == none and b.root == none) return true;
        return w.flags[if (a.root != none) a.root else b.root].escaped;
    }

    /// The local `ref` points into, or `none`; a local whose copy was
    /// forwarded now points into other memory.
    fn rootFor(w: *const Walk, ref: Inst.Ref) u32 {
        const r = w.rootOf(ref) orelse return none;
        return if (w.flags[r].forwarded) none else r;
    }

    /// A write through `ptr` to memory of unknown extent.
    fn unknownKey(w: *const Walk, ptr: Inst.Ref) Key {
        return .{ .base = .none, .field = 0, .disjoint = false, .root = w.rootFor(ptr) };
    }

    /// What a load or store through `ptr` reads or writes, if it is an
    /// ordinary pointer to one value.
    fn keyOf(w: *Walk, ptr: Inst.Ref) ?Key {
        const ir = w.ir;
        if (!w.cached(&w.plain_cache, ir.typeOf(ptr, w.ip), plainPtr)) return null;
        var key: Key = .{ .base = ptr, .field = 0, .disjoint = false, .root = w.rootFor(ptr) };
        if (ptr.toIndex()) |p| if (ir.instructions.items(.tag)[@backingInt(p)] == .struct_field_ptr) {
            const sf = ir.extraData(Ir.StructField, ir.instructions.items(.data)[@backingInt(p)].ty_pl.payload).data;
            key.base = sf.operand;
            key.field = sf.index + 1;
            key.disjoint = w.cached(&w.disjoint_cache, ir.typeOf(sf.operand, w.ip), disjointFields);
        };
        key.base = w.canon(key.base);
        return key;
    }

    /// `test_fn(ty)`, remembered: a function's loads and stores go
    /// through few pointer types.
    fn cached(w: *Walk, c: *[64]Cached, ty: Index, comptime test_fn: fn (*const InternPool, Index) bool) bool {
        const slot = &c[@backingInt(ty) % c.len];
        if (slot.ty == ty) return slot.yes;
        slot.* = .{ .ty = ty, .yes = test_fn(w.ip, ty) };
        return slot.yes;
    }

    /// `ref`, or when it loads a pointer from a `const` local stored once
    /// before, the pointer stored there: every `self.x` reloads `self`
    /// from its parameter's slot.
    fn canon(w: *const Walk, ref: Inst.Ref) Inst.Ref {
        const ir = w.ir;
        const tags = ir.instructions.items(.tag);
        const datas = ir.instructions.items(.data);
        var r = w.resolve(ref);
        while (r.toIndex()) |idx| {
            const i = @backingInt(idx);
            if (tags[i] != .load) break;
            const a = @backingInt(datas[i].ty_op.operand.toIndex() orelse break);
            if (tags[a] != .alloc) break;
            const f = w.flags[a];
            if (f.escaped or f.multi or w.store[a] == none or !Type.ptrInfo(w.ip, datas[a].ty).flags.is_const) break;
            const s = w.store[a];
            if (!(w.pos[s] < w.pos[i] and w.pos[i] <= w.scope_end[s])) break;
            r = w.resolve(datas[s].bin_op.rhs);
        }
        return r;
    }

    /// The value `ref` was found to be (`forwardLoads`).
    fn resolve(w: *const Walk, ref: Inst.Ref) Inst.Ref {
        const i = ref.toIndex() orelse return ref;
        const to = w.subst[@backingInt(i)];
        return if (to == none) ref else @fromBackingInt(to);
    }

    fn body(w: *Walk, insts: []const Inst.Index) void {
        for (insts) |inst| w.instruction(inst);
        for (insts) |inst| w.scope_end[@backingInt(inst)] = w.next - 1;
    }

    /// A `block` left only by the `br` that ends its body runs all of
    /// its body before what follows it, so its body's instructions reach
    /// as far as the block does. In position order a block comes before
    /// its body, so nested blocks pass on the reach they were given.
    fn straight(w: *Walk) void {
        const ir = w.ir;
        const tags = ir.instructions.items(.tag);
        for (w.order[0..w.next]) |b| {
            if (tags[b] != .block or w.exits[b] != 1) continue;
            const insts = blockBody(ir, @fromBackingInt(b));
            const last = @backingInt(insts[insts.len - 1]);
            if (tags[last] != .br or @backingInt(ir.instructions.items(.data)[last].br.block_inst) != b) continue;
            for (insts) |i| w.scope_end[@backingInt(i)] = w.scope_end[b];
        }
    }

    fn instruction(w: *Walk, inst: Inst.Index) void {
        const ir = w.ir;
        const i = @backingInt(inst);
        w.pos[i] = w.next;
        w.order[w.next] = i;
        w.next += 1;
        w.loop_of[i] = w.loop;
        const data = ir.instructions.items(.data)[i];
        const tag = ir.instructions.items(.tag)[i];
        switch (tag) {
            .alloc => {
                w.root[i] = i;
                w.last[i] = none;
                w.store[i] = none;
                w.flags[i] = .{};
            },
            .load => {
                w.countUse(data.ty_op.operand);
                w.touch(data.ty_op.operand);
            },
            .br => {
                w.exits[@backingInt(data.br.block_inst)] += 1;
                w.user = i;
                Ssa.forEachOperand(ir, inst, Escape{ .w = w });
            },
            .store => {
                w.countUse(data.bin_op.lhs);
                w.countUse(data.bin_op.rhs);
                if (w.rootOf(data.bin_op.lhs)) |r| {
                    if (w.store[r] != none or w.last[r] != none) w.flags[r].multi = true;
                    w.store[r] = i;
                    w.touch(data.bin_op.lhs);
                }
                w.escape(data.bin_op.rhs);
            },
            .struct_field_ptr => {
                const base = ir.extraData(Ir.StructField, data.ty_pl.payload).data.operand;
                w.countUse(base);
                if (w.rootOf(base)) |r| {
                    w.root[i] = r;
                    w.touch(base);
                }
            },
            .ptr_elem_ptr => {
                const bin = ir.extraData(Ir.Bin, data.ty_pl.payload).data;
                w.countUse(bin.lhs);
                w.countUse(bin.rhs);
                if (w.rootOf(bin.lhs)) |r| {
                    w.root[i] = r;
                    w.touch(bin.lhs);
                }
                w.escape(bin.rhs);
            },
            else => {
                w.user = i;
                Ssa.forEachOperand(ir, inst, Escape{ .w = w });
            },
        }
        switch (tag) {
            .block => {
                w.exits[i] = 0;
                w.body(blockBody(ir, inst));
            },
            .loop => {
                const outer = w.loop;
                w.loop = i;
                w.body(blockBody(ir, inst));
                w.loop = outer;
            },
            .cond_br => {
                const x = ir.extraData(Ir.CondBr, data.pl_op.payload);
                w.body(ir.bodySlice(x.end, x.data.then_body_len));
                w.body(ir.bodySlice(x.end + x.data.then_body_len, x.data.else_body_len));
            },
            .switch_br => {
                var it = ir.switchCases(data.pl_op.payload);
                while (it.next()) |c| w.body(c.body);
                w.body(it.elseBody());
            },
            else => {},
        }
    }

    const Escape = struct {
        w: *Walk,
        pub fn use(e: Escape, ref: Inst.Ref) void {
            e.w.countUse(ref);
            e.w.escape(ref);
        }
    };

    fn countUse(w: *Walk, ref: Inst.Ref) void {
        if (!w.count_uses) return;
        if (ref.toIndex()) |i| w.uses[@backingInt(i)] += 1;
    }

    fn rootOf(w: *const Walk, ref: Inst.Ref) ?u32 {
        const i = ref.toIndex() orelse return null;
        const r = w.root[@backingInt(i)];
        return if (r == none) null else r;
    }

    /// A read through `ref`, or a pointer derived from it, at the current
    /// position.
    fn touch(w: *Walk, ref: Inst.Ref) void {
        const r = w.rootOf(ref) orelse return;
        const here = w.order[w.next - 1];
        w.last[r] = w.next - 1;
        if (w.loop_of[here] != w.loop_of[r]) w.flags[r].loop_mismatch = true;
    }

    fn escape(w: *Walk, ref: Inst.Ref) void {
        const r = w.rootOf(ref) orelse return;
        w.flags[r].escaped = true;
    }

    /// Whether `i` may write memory a pointer can reach that does not
    /// point into a local whose address does not escape, or, with `local`
    /// set, whether it may write that local.
    fn writes(w: *const Walk, i: u32, local: u32) bool {
        const ir = w.ir;
        const data = ir.instructions.items(.data)[i];
        const target: Inst.Ref = switch (ir.instructions.items(.tag)[i]) {
            .store, .memset, .memcpy, .memmove, .set_union_tag => data.bin_op.lhs,
            .optional_payload_ptr_set, .errunion_payload_ptr_set => data.ty_op.operand,
            // A call that returns may write anything; a panic does not
            // return.
            .call => return ir.extraData(Ir.Call, data.pl_op.payload).data.ret_ty != .noreturn_type,
            .atomic_store, .atomic_rmw, .cmpxchg, .assembly, .vector_store_elem, .c_va_start, .c_va_arg, .c_va_copy => return true,
            else => return false,
        };
        const r = w.rootOf(target) orelse return true;
        if (local != none) return r == local or w.flags[r].escaped;
        return w.flags[r].escaped;
    }

    /// The whole load whose value `v` is, read only there: Sema's inline
    /// calls pass an argument through a tuple (`aggregate_init`, then
    /// `struct_field_val`).
    fn sourceLoad(w: *const Walk, v: Inst.Ref) ?Inst.Index {
        const ir = w.ir;
        const i = v.toIndex() orelse return null;
        if (w.uses[@backingInt(i)] != 1) return null;
        const data = ir.instructions.items(.data)[@backingInt(i)];
        switch (ir.instructions.items(.tag)[@backingInt(i)]) {
            .load => return i,
            .struct_field_val => {
                const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
                const agg = sf.operand.toIndex() orelse return null;
                if (w.uses[@backingInt(agg)] != 1 or ir.instructions.items(.tag)[@backingInt(agg)] != .aggregate_init) return null;
                const a = ir.instructions.items(.data)[@backingInt(agg)].ty_pl;
                switch (w.ip.keyTag(a.ty)) {
                    .struct_type => if (Type.isPackedStruct(w.ip, a.ty)) return null,
                    .tuple_type => {},
                    else => return null,
                }
                const x = ir.extraData(Ir.Aggregate, a.payload);
                if (x.data.len != Type.fieldCount(w.ip, a.ty)) return null;
                return w.sourceLoad(ir.refSlice(x.end, x.data.len)[sf.index]);
            },
            else => return null,
        }
    }

    /// Whether `src`'s pointer reads the local's type at the local's
    /// alignment, as an ordinary pointer.
    fn sameLayout(w: *const Walk, src: Inst.Ref, alloc_ty: Index) bool {
        const ip = w.ip;
        const ty = w.ir.typeOf(src, ip);
        if (ip.keyTag(ty) != .ptr_type) return false;
        const p = Type.ptrInfo(ip, ty);
        const a = Type.ptrInfo(ip, alloc_ty);
        return p.child == a.child and p.flags.size == .one and !p.flags.is_volatile and
            p.flags.alignment == a.flags.alignment and p.flags.address_space == .generic and
            p.flags.vector_index == 0 and p.packed_offset.host_size == 0;
    }
};

fn blockBody(ir: *const Ir, inst: Inst.Index) []const Inst.Index {
    const x = ir.extraData(Ir.Block, ir.instructions.items(.data)[@backingInt(inst)].ty_pl.payload);
    return ir.bodySlice(x.end, x.data.body_len);
}
