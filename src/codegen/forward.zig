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
//! followed by a read of `self.index`, or `self.len` read twice. A load
//! that no write in its loop may change moves before the loop:
//! `self.buf.len` in a tokenizer's loop. Runs on
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
/// `run`'s mark of a local stored more than once, a `Ref` no function has.
const multi = none - 1;

/// Forwards the copies or the loads that qualify; returns how many.
pub fn run(gpa: Allocator, ip: *const InternPool, ir: *Ir, scratch: *std.ArrayList(u32)) Allocator.Error!u32 {
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    // A function with nothing to forward costs two passes to find that.
    // There is no load to forward unless a load goes through the same
    // base pointer as another load or store, or the same pointer stored
    // once into a local and reloaded (`self.x`, also through an inline
    // call's copy of `self`); a hash of each base finds that, also when
    // two bases share a hash, in any order, so the decision does not
    // depend on how instructions or interned values are numbered. Loads
    // and stores straight through a local are left to `Ssa.plan`.
    const n = ir.instructions.len;
    scratch.clearRetainingCapacity();
    const words = try scratch.addManyAsSlice(gpa, 16 * n + 1);
    const stored_once = words[0..n];
    @memset(stored_once, none);
    for (tags, datas) |tag, data| if (tag == .store) if (data.bin_op.lhs.toIndex()) |a| if (tags[@backingInt(a)] == .alloc) {
        const v = &stored_once[@backingInt(a)];
        v.* = if (v.* == none) @backingInt(data.bin_op.rhs) else multi;
    };
    var copies = false;
    var loaded: u256 = 0;
    var loaded_twice: u256 = 0;
    var stored: u256 = 0;
    for (tags, datas) |tag, data| switch (tag) {
        .load => if (baseHash(ir, stored_once, data.ty_op.operand)) |h| {
            loaded_twice |= loaded & h;
            loaded |= h;
        },
        .store => if (baseHash(ir, stored_once, data.bin_op.lhs)) |h| {
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
    const reloads = loaded_twice | (loaded & stored) != 0;
    if (!copies and !reloads) return 0;

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
        .alias = words[12 * n .. 13 * n],
        .last_load = words[13 * n .. 14 * n],
        .dom_end = words[14 * n .. 15 * n],
        .early = words[15 * n .. 16 * n],
    };
    // Read for any operand; the rest is set as the walk reaches it.
    @memset(w.root, none);
    @memset(w.subst, none);
    @memset(w.alias, none);
    @memset(w.last_load, none);
    if (copies) {
        @memset(w.uses, 0);
        w.count_uses = true;
    }
    w.body(ir.mainBody());
    w.straight();

    var count: u32 = if (copies) w.forwardCopies(words[10 * n ..][0 .. w.next + 1]) else 0;
    if (reloads) {
        // The loads in loops not forwarded, for `hoistLoads`, in room
        // `forwardCopies` is done with.
        const cands = words[10 * n .. 11 * n];
        var ncands: u32 = 0;
        const loads_forwarded = w.forwardLoads(cands, &ncands);
        const hoisted = if (ncands != 0) try w.hoistLoads(gpa, cands[0..ncands]) else 0;
        if (loads_forwarded != 0 or hoisted != 0) {
            const Subst = struct {
                subst: []const u32,
                const Self = @This();
                pub fn use(s: Self, ref: *Inst.Ref) void {
                    const i = ref.toIndex() orelse return;
                    if (@backingInt(i) >= s.subst.len) return;
                    var to = s.subst[@backingInt(i)];
                    if (to == none) return;
                    // A load forwarded to one that was hoisted, or to one
                    // hoisted with it.
                    while (@as(Inst.Ref, @fromBackingInt(to)).toIndex()) |j| {
                        if (@backingInt(j) >= s.subst.len or s.subst[@backingInt(j)] == none) break;
                        to = s.subst[@backingInt(j)];
                    }
                    ref.* = @fromBackingInt(to);
                }
            };
            for (w.order[0..w.next]) |i| Ssa.forEachOperandPtr(ir, @fromBackingInt(i), Subst{ .subst = w.subst });
            // The moved loads' addresses: an inner loop's may be an outer
            // loop's load that moved too.
            for (n..ir.instructions.len) |i| Ssa.forEachOperandPtr(ir, @fromBackingInt(@as(u32, @intCast(i))), Subst{ .subst = w.subst });
        }
        count += loads_forwarded + hoisted;
    }
    return count;
}

/// One bit of 256 for the memory a load or store through `ptr` reaches,
/// by its base pointer (what `Walk.keyOf` reads, before `Walk.canon`), or
/// null for a local's own memory, which `Ssa.plan` forwards.
fn baseHash(ir: *const Ir, stored_once: []const u32, ptr: Inst.Ref) ?u256 {
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    var base = ptr;
    if (base.toIndex()) |i| switch (tags[@backingInt(i)]) {
        .alloc => return null,
        .struct_field_ptr => base = ir.extraData(Ir.StructField, datas[@backingInt(i)].ty_pl.payload).data.operand,
        else => {},
    };
    // Elements of one base, which `Walk.canon` folds by base and index,
    // also of an element (`a[i][j]`), and a pointer loaded from a local:
    // the pointer stored there, when it was stored once (`Walk.canon`
    // folds no other), else the local, which `Walk.canon` folds as an
    // earlier load of it. Every address `Walk.canon` folds together must
    // hash the same, or whether two of them meet would depend on another
    // pair of bases sharing a hash.
    while (base.toIndex()) |i| switch (tags[@backingInt(i)]) {
        .ptr_elem_ptr => base = ir.extraData(Ir.Bin, datas[@backingInt(i)].ty_pl.payload).data.lhs,
        // A pointer with `const` added (`Walk.constOnly`), as an inline
        // callee's copy of a by-value parameter becomes, or any other
        // cast: hashing more together only walks more.
        .bitcast => base = datas[@backingInt(i)].ty_op.operand,
        .load => {
            const a = datas[@backingInt(i)].ty_op.operand.toIndex() orelse break;
            if (tags[@backingInt(a)] != .alloc) break;
            const v = stored_once[@backingInt(a)];
            if (v == none or v == multi) {
                base = a.toRef();
                break;
            }
            base = @fromBackingInt(v);
        },
        else => break,
    };
    return @as(u256, 1) << @intCast(std.hash.int(@backingInt(base)) % 256);
}

/// Whether `ref` is a local's own pointer.
fn isAlloc(ir: *const Ir, ref: Inst.Ref) bool {
    const i = ref.toIndex() orelse return false;
    return ir.instructions.items(.tag)[@backingInt(i)] == .alloc;
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

/// A value a load may read from a load or store of it that already ran
/// (`forwardLoads`), though `hoistLoads` moves none: a scalar, a packed
/// struct of at most 8 bytes (its backing integer, as hash maps'
/// `Metadata`), or an optional pointer whose null is 0 (`self.metadata`).
fn forwardable(ip: *const InternPool, ty: Index) bool {
    if (scalar(ip, ty)) return true;
    return switch (Type.class(ip, ty)) {
        .@"struct" => Type.isPackedStruct(ip, ty) and Type.abiSize(ip, ty) <= 8,
        .optional => {
            const child = ip.keyPayload(.opt_type, ty);
            return ip.keyTag(child) == .ptr_type and Type.optionalReprIsPayload(ip, child);
        },
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
    /// Each local's store; each loop's slot in the body that holds it;
    /// each block's last position.
    store: []u32,
    /// The instruction at each position.
    order: []u32,
    /// Each instruction's uses by the instructions walked, counted when
    /// `count_uses` is set.
    uses: []u32,
    flags: []Flags,
    /// Per load, the value it was found to read, or `none`.
    subst: []u32,
    /// Per `block`, the position of the first `br` that exits it, or
    /// `none`.
    exits: []u32,
    /// Per load of a local's value, an earlier load of it that reads the
    /// same value, per element pointer an earlier one of the same
    /// element, and per cast that only adds `const` its operand, as a
    /// ref, or `none` (`canon`).
    alias: []u32,
    /// Per local, its last load with no store to it since.
    last_load: []u32,
    /// Per instruction, the last position it dominates: `scope_end`, and
    /// past the blocks it runs in before they are left (`dominated`).
    /// Filled the first time `scope_end` does not decide (`dominates`).
    dom_end: []u32,
    dom_ready: bool = false,
    /// The blocks left before their end, inner ones first: only they
    /// make an instruction dominate past its scope.
    early: []u32,
    early_len: u32 = 0,
    /// The pointers `ptr_elem_ptr` derived, by base and index (`canon`).
    elems: [max_known][3]Inst.Ref = undefined,
    elems_len: u32 = 0,
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
            // A local whose address does not escape is written only
            // through it. A local forwarded already is the memory it
            // copies, whose writes count from here to the last read.
            const end = @max(w.last[ii], w.pos[store]);
            var r = w.rootOf(src) orelse none;
            while (r != none and w.flags[r].forwarded) r = w.rootOf(datas[r].ty_op.operand) orelse none;
            if (r == none or w.flags[r].escaped) {
                if (prefix[end + 1] - prefix[w.pos[l] + 1] != 0) continue;
            }
            if (r != none) {
                if (for (w.order[w.pos[l] + 1 .. end + 1]) |i| {
                    if (w.writes(i, r)) break true;
                } else false) continue;
            }
            const ty = datas[ii].ty;
            tags[ii] = .bitcast;
            datas[ii] = .{ .ty_op = .{ .ty = ty, .operand = src } };
            // The initializing store goes; the loaded value is left for dead
            // code.
            tags[store] = .bitcast;
            datas[store] = .{ .ty_op = .{ .ty = ty, .operand = src } };
            w.flags[ii].forwarded = true;
            if (w.constOnly(datas[ii].ty_op)) w.alias[ii] = @backingInt(src);
            count += 1;
        }
        return count;
    }

    /// Store-to-load forwarding and load reuse: a load of a `forwardable`
    /// value from memory that a dominating store wrote, or a dominating
    /// load read, with no write in between that may reach it, becomes
    /// that value (`subst`). Only a value computed on every path to the
    /// load is reused: nothing is loaded where the program did not load,
    /// and volatile pointers (`plainPtr`) and atomic loads (their own
    /// instruction) are left alone. Positions are scanned in order, so a
    /// write anywhere between the two, also in a branch not taken,
    /// forgets what was known: a store, or a returning call, atomic write
    /// or inline assembly for all memory but locals whose address does
    /// not escape. Across a loop, no write in the loop may reach it
    /// either (`sameAcrossLoops`). A panic does not return, so the safety
    /// checks between them forget nothing.
    fn forwardLoads(w: *Walk, cands: []u32, ncands: *u32) u32 {
        const ir = w.ir;
        const subst = w.subst;
        const ip = w.ip;
        const tags = ir.instructions.items(.tag);
        const datas = ir.instructions.items(.data);
        var known: [max_known]Known = undefined;
        var len: u32 = 0;
        var count: u32 = 0;
        var loop_writes: CachedLoopWrites = .{};
        for (w.order[0..w.next]) |i| {
            const data = datas[i];
            switch (tags[i]) {
                .load => {
                    const ty = data.ty_op.ty;
                    // A load straight through a local is left alone:
                    // `Ssa.plan` forwards one whose address does not
                    // escape, and `run`'s filter looks for no other. It
                    // stands for the local's value in addresses (`canon`).
                    if (isAlloc(ir, data.ty_op.operand)) {
                        const a = @backingInt(data.ty_op.operand.toIndex().?);
                        // Only `store`s write a scalar local whose address
                        // does not escape.
                        if (w.flags[a].escaped or !forwardable(ip, ty)) continue;
                        const j = w.last_load[a];
                        if (j != none and w.pos[j] < w.pos[i] and w.loop_of[j] == w.loop_of[i] and w.dominates(j, i)) {
                            w.alias[i] = @backingInt(Inst.Index.toRef(@fromBackingInt(j)));
                        } else w.last_load[a] = i;
                        continue;
                    }
                    if (!forwardable(ip, ty)) continue;
                    const key = w.keyOf(data.ty_op.operand) orelse continue;
                    if (w.promoted(key)) continue;
                    const match: ?Known = for (known[0..len]) |k| {
                        if (k.key.base == key.base and k.key.field == key.field) break k;
                    } else null;
                    if (match) |k| {
                        const s = k.inst;
                        if (k.ty == ty and w.pos[s] < w.pos[i] and w.dominates(s, i) and w.sameAcrossLoops(key, s, i, &loop_writes)) {
                            subst[i] = @backingInt(k.value);
                            count += 1;
                            continue;
                        }
                    }
                    // Only a scalar's load moves before its loop; the
                    // others are only forwarded.
                    if (w.loop_of[i] != none and scalar(ip, ty)) {
                        cands[ncands.*] = i;
                        ncands.* += 1;
                    }
                    len = remember(&known, len, .{ .key = key, .value = Inst.Index.toRef(@fromBackingInt(i)), .ty = ty, .inst = i });
                },
                .ptr_elem_ptr => {
                    // The same element of the same base, as the same
                    // values, is the same pointer when its type is.
                    const bin = ir.extraData(Ir.Bin, data.ty_pl.payload).data;
                    const e: [3]Inst.Ref = .{ w.canon(bin.lhs), w.canon(bin.rhs), Inst.Index.toRef(@fromBackingInt(i)) };
                    for (w.elems[0..w.elems_len]) |x| {
                        if (x[0] == e[0] and x[1] == e[1] and datas[@backingInt(x[2].toIndex().?)].ty_pl.ty == data.ty_pl.ty) {
                            w.alias[i] = @backingInt(x[2]);
                            break;
                        }
                    } else if (w.elems_len < max_known) {
                        w.elems[w.elems_len] = e;
                        w.elems_len += 1;
                    }
                },
                .store => {
                    const ptr = data.bin_op.lhs;
                    // Also through a field pointer, as into a packed
                    // struct.
                    if (w.rootOf(ptr)) |r| w.last_load[r] = none;
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
                    if (forwardable(ip, ty)) len = remember(&known, len, .{ .key = key, .value = value, .ty = ty, .inst = i });
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

    /// Loop-invariant loads (`cands`: loads in loops that `forwardLoads`
    /// did not forward, in position order): a load of a scalar whose
    /// address is computed before its innermost loop, or is a field of a
    /// pointer that is, or of a load that moves too, moves to before the
    /// loop when no write in the loop may reach its memory (`loopWrites`),
    /// and when that memory was already read or written through the same
    /// base before the loop, or is first in the loop, with no call
    /// between that might free it (`accessedBefore`): the load then
    /// cannot fault where the original might not have run. The loop
    /// becomes `block { loads; loop }` in its slot, and the load's users
    /// read the moved load (`subst`). The moved loads run on the line of
    /// the statement before the loop. Safety checks stay where they are.
    /// Returns how many loads moved.
    fn hoistLoads(w: *Walk, gpa: Allocator, cands: []const u32) Allocator.Error!u32 {
        const ir = w.ir;
        const ip = w.ip;
        const datas = ir.instructions.items(.data);
        const Hoist = struct { load: u32, loop: u32, addr: Inst.Ref, field: u32, key: Key, ty: Index, ptr_ty: Index };
        var hoists: [max_known]Hoist = undefined;
        var nh: u32 = 0;
        var cur_loop: u32 = none;
        var loop_writes: LoopWrites = .{};
        for (cands) |l| {
            if (nh == hoists.len) break;
            const lp = w.loop_of[l];
            const ptr = w.resolve(datas[l].ty_op.operand);
            const key = w.keyOf(ptr) orelse continue;
            // The address, computed before the loop or by a load that
            // moves before it first (`self.in.buf.len`).
            const Moved = struct {
                fn in(hs: []const Hoist, ref: Inst.Ref, loop: u32) bool {
                    const i = ref.toIndex() orelse return false;
                    for (hs) |h| if (h.load == @backingInt(i) and h.loop == loop) return true;
                    return false;
                }
            };
            var addr = ptr;
            var field: u32 = 0;
            if (!w.dominatesLoop(ptr, lp) and !Moved.in(hoists[0..nh], ptr, lp)) {
                if (key.field == 0 or !(w.dominatesLoop(key.base, lp) or Moved.in(hoists[0..nh], key.base, lp))) continue;
                addr = key.base;
                field = key.field;
            }
            if (!w.accessedBefore(key.base, lp)) continue;
            if (cur_loop != lp) {
                cur_loop = lp;
                loop_writes = w.loopWrites(lp);
            }
            if (loop_writes.reach(w, key, l)) continue;
            // The same memory loaded twice in the loop moves once.
            const same = for (hoists[0..nh]) |h| {
                if (h.loop == lp and h.key.base == key.base and h.key.field == key.field and datas[h.load].ty_op.ty == datas[l].ty_op.ty) break h.load;
            } else none;
            if (same != none) {
                w.subst[l] = @backingInt(Inst.Index.toRef(@fromBackingInt(same)));
                continue;
            }
            hoists[nh] = .{ .load = l, .loop = lp, .addr = addr, .field = field, .key = key, .ty = datas[l].ty_op.ty, .ptr_ty = ir.typeOf(ptr, ip) };
            nh += 1;
        }
        if (nh == 0) return 0;
        // By loop, keeping position order within each.
        std.sort.insertion(Hoist, hoists[0..nh], {}, struct {
            fn lt(_: void, a: Hoist, b: Hoist) bool {
                return a.loop < b.loop;
            }
        }.lt);

        // New instructions: per loop a `block`, and per load its field
        // pointer if needed and the load. New bodies go after `extra`.
        var list = ir.instructions.toMultiArrayList();
        defer ir.instructions = list.slice();
        // The whole allocation, which `Ir.deinit` frees; what lies past
        // the last body is never read.
        var extra: std.ArrayList(u32) = .fromOwnedSlice(@constCast(ir.extra));
        defer ir.extra = extra.allocatedSlice();
        var count: u32 = 0;
        var k: u32 = 0;
        while (k < nh) {
            const lp = hoists[k].loop;
            var end = k;
            while (end < nh and hoists[end].loop == lp) end += 1;
            // The field pointers and loads, whose payloads go before the
            // block's body.
            const first: u32 = @intCast(list.len);
            for (hoists[k..end]) |h| {
                var addr = h.addr;
                if (h.field != 0) {
                    const sf: u32 = @intCast(list.len);
                    const payload: u32 = @intCast(extra.items.len);
                    try extra.appendSlice(gpa, &.{ @backingInt(h.key.base), h.field - 1 });
                    try list.append(gpa, .{ .tag = .struct_field_ptr, .data = .{ .ty_pl = .{ .ty = h.ptr_ty, .payload = payload } } });
                    addr = Inst.Index.toRef(@fromBackingInt(sf));
                }
                const nl: u32 = @intCast(list.len);
                try list.append(gpa, .{ .tag = .load, .data = .{ .ty_op = .{ .ty = h.ty, .operand = addr } } });
                w.subst[h.load] = @backingInt(Inst.Index.toRef(@fromBackingInt(nl)));
                count += 1;
            }
            // The block: those, then the loop.
            const blk: u32 = @intCast(list.len);
            const body_len: u32 = @intCast(list.len - first + 1);
            try list.append(gpa, .{ .tag = .block, .data = .{ .ty_pl = .{ .ty = list.items(.data)[lp].ty_pl.ty, .payload = @intCast(extra.items.len) } } });
            try extra.append(gpa, body_len);
            for (first..blk) |i| try extra.append(gpa, @intCast(i));
            try extra.append(gpa, lp);
            extra.items[w.store[lp]] = blk;
            k = end;
        }
        return count;
    }

    /// Whether `ref` is a constant or computed before loop `lp`, on every
    /// path to it.
    fn dominatesLoop(w: *const Walk, ref: Inst.Ref, lp: u32) bool {
        const d = @backingInt(ref.toIndex() orelse return true);
        if (d >= w.pos.len) return false;
        return w.pos[d] < w.pos[lp] and w.pos[lp] <= w.scope_end[d];
    }

    /// Whether a load or store through `base` runs on every path to loop
    /// `lp`, shortly before it, with no call or inline assembly between
    /// that might free its memory.
    fn accessedBefore(w: *Walk, base: Inst.Ref, lp: u32) bool {
        const ir = w.ir;
        const tags = ir.instructions.items(.tag);
        const datas = ir.instructions.items(.data);
        var p = w.pos[lp];
        const stop = p -| 64;
        while (p > stop) {
            p -= 1;
            const i = w.order[p];
            const ptr = switch (tags[i]) {
                .load => datas[i].ty_op.operand,
                .store => datas[i].bin_op.lhs,
                .call => if (ir.extraData(Ir.Call, datas[i].pl_op.payload).data.ret_ty != .noreturn_type) return false else continue,
                // Inline assembly may unmap memory as a call may free it.
                .assembly => return false,
                else => continue,
            };
            if (!(w.pos[lp] <= w.scope_end[i])) continue;
            const key = w.keyOf(w.resolve(ptr)) orelse continue;
            if (key.base == base) return true;
        }
        // Or first in the loop, which always runs its body once: in
        // position order before the first branch, or anything else that
        // might leave the body or free the memory (entering a block, as a
        // `while` condition's, is not a branch).
        const insts = blockBody(ir, @fromBackingInt(lp));
        if (insts.len == 0) return false;
        p = w.pos[lp] + 1;
        const end = @min(w.scope_end[@backingInt(insts[0])] + 1, p + 64);
        while (p < end) : (p += 1) {
            const i = w.order[p];
            const ptr = switch (tags[i]) {
                .load => datas[i].ty_op.operand,
                .store => datas[i].bin_op.lhs,
                .cond_br, .switch_br, .call, .br, .repeat, .ret, .unreach, .trap, .assembly => return false,
                else => continue,
            };
            const key = w.keyOf(w.resolve(ptr)) orelse continue;
            if (key.base == base) return true;
        }
        return false;
    }

    /// The writes in loop `lp`, its body's positions.
    fn loopWrites(w: *Walk, lp: u32) LoopWrites {
        const ir = w.ir;
        const tags = ir.instructions.items(.tag);
        const datas = ir.instructions.items(.data);
        var lw: LoopWrites = .{};
        const insts = blockBody(ir, @fromBackingInt(lp));
        if (insts.len == 0) return lw;
        const end = w.scope_end[@backingInt(insts[0])];
        for (w.pos[lp] + 1..end + 1) |p| {
            const i = w.order[p];
            const data = datas[i];
            const key: Key = switch (tags[i]) {
                .store => if (w.direct(data.bin_op.lhs)) w.unknownKey(data.bin_op.lhs) else w.keyOf(data.bin_op.lhs) orelse w.unknownKey(data.bin_op.lhs),
                .memset, .memcpy, .memmove, .set_union_tag => w.unknownKey(data.bin_op.lhs),
                .optional_payload_ptr_set, .errunion_payload_ptr_set => w.unknownKey(data.ty_op.operand),
                // Any memory but locals whose address does not escape.
                .call, .atomic_store, .atomic_rmw, .cmpxchg, .assembly, .vector_store_elem, .c_va_start, .c_va_arg, .c_va_copy => if (w.writes(i, none))
                    .{ .base = .none, .field = 0, .disjoint = false, .root = none }
                else
                    continue,
                else => continue,
            };
            // Who may see the write: the rest of the path that leaves the
            // loop, or the whole loop when it may repeat.
            const seen_to = w.exitPath(lp, @intCast(p)) orelse end;
            const seen_from: u32 = if (seen_to == end) w.pos[lp] + 1 else @intCast(p + 1);
            // The same memory again: one entry, seen where either is, when
            // their ranges overlap or no room is left.
            const same = for (lw.writes[0..lw.len]) |*x| {
                if (!std.meta.eql(x.key, key)) continue;
                if (lw.len == lw.writes.len or (seen_from <= x.to and x.from <= seen_to)) break x;
            } else null;
            if (same) |x| {
                x.from = @min(x.from, seen_from);
                x.to = @max(x.to, seen_to);
                continue;
            }
            if (lw.len == lw.writes.len) {
                lw.all = true;
                return lw;
            }
            lw.writes[lw.len] = .{ .key = key, .from = seen_from, .to = seen_to };
            lw.len += 1;
        }
        return lw;
    }

    /// When what runs after position `p` in loop `lp` leaves the loop
    /// without repeating it, the last position of that path: the rest of
    /// the body holding `p`, and after each `br` on it to a block in the
    /// loop that holds `p`, what follows that block.
    fn exitPath(w: *const Walk, lp: u32, p: u32) ?u32 {
        const ir = w.ir;
        const tags = ir.instructions.items(.tag);
        const datas = ir.instructions.items(.data);
        var to = w.scope_end[w.order[p]];
        // The blocks left: what follows each is scanned once.
        var left: [8]u32 = undefined;
        var nleft: u32 = 0;
        var next: u32 = 0;
        var from = p + 1;
        var end = to;
        var scanned: u32 = 0;
        while (true) {
            scanned += end + 1 -| from;
            if (scanned > 512) return null;
            var q = from;
            while (q <= end) : (q += 1) {
                const j = w.order[q];
                switch (tags[j]) {
                    .repeat => if (w.pos[@backingInt(datas[j].repeat.loop_inst)] <= p) return null,
                    .br => {
                        const b = @backingInt(datas[j].br.block_inst);
                        if (w.pos[b] <= w.pos[lp] or w.pos[b] >= p) continue;
                        if (std.mem.findScalar(u32, left[0..nleft], b) != null) continue;
                        if (nleft == left.len) return null;
                        left[nleft] = b;
                        nleft += 1;
                    },
                    else => {},
                }
            }
            if (next == nleft) return to;
            // After the block's body (its last position, `store`), to the
            // end of the body holding it.
            const b = left[next];
            next += 1;
            from = w.store[b] + 1;
            end = w.scope_end[b];
            to = @max(to, end);
        }
    }

    const LoopWrites = struct {
        /// What each write may reach, and the positions of the loads that
        /// may see it.
        writes: [2 * max_known]struct { key: Key, from: u32, to: u32 } = undefined,
        len: u32 = 0,
        /// Too many writes to tell: they may write anything.
        all: bool = false,

        /// Whether a write in the loop may change what load `l` reads
        /// through `key`.
        fn reach(lw: *const LoopWrites, w: *const Walk, key: Key, l: u32) bool {
            if (lw.all) return true;
            const p = w.pos[l];
            for (lw.writes[0..lw.len]) |x| {
                if (p >= x.from and p <= x.to and w.mayOverlap(x.key, key)) return true;
            }
            return false;
        }
    };

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

    const CachedLoopWrites = struct { loop: u32 = none, writes: LoopWrites = .{} };

    /// Whether load `i` may read what load or store `s`, which dominates
    /// it, found through `key`, as far as loops go: in position order,
    /// the scan forgets the writes between them, but a loop around `i`
    /// that does not hold `s` may repeat after a write later in its body.
    /// The value is one `s` computed on every path to `i`; nothing is
    /// loaded where the program did not load it.
    fn sameAcrossLoops(w: *Walk, key: Key, s: u32, i: u32, cache: *CachedLoopWrites) bool {
        var lp = w.loop_of[i];
        while (lp != w.loop_of[s]) : (lp = w.loop_of[lp]) {
            if (lp == none) return false;
            if (cache.loop != lp) cache.* = .{ .loop = lp, .writes = w.loopWrites(lp) };
            if (cache.writes.reach(w, key, i)) return false;
        }
        return true;
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
        @memmove(known[0 .. max_known - 1], known[1..]);
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
        // A parameter points to memory that was there before any local.
        if (w.isArg(if (a.root != none) b.base else a.base)) return false;
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
    /// from its parameter's slot. A cast that only adds `const` is its
    /// operand (`alias`): an inline callee's copy of a by-value parameter becomes
    /// one of the caller's local (`forwardCopies`), and so does a copy of
    /// that copy.
    fn canon(w: *const Walk, ref: Inst.Ref) Inst.Ref {
        const ir = w.ir;
        const tags = ir.instructions.items(.tag);
        const datas = ir.instructions.items(.data);
        var r = w.resolve(ref);
        while (r.toIndex()) |idx| {
            const i = @backingInt(idx);
            if (w.alias[i] != none) {
                r = @fromBackingInt(w.alias[i]);
                continue;
            }
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

    /// Whether pointer cast `op` only adds `const`: the same pointee,
    /// alignment, address space and size, so a field of it is the same
    /// field of its operand.
    fn constOnly(w: *const Walk, op: @FieldType(Inst.Data, "ty_op")) bool {
        if (w.ip.keyTag(op.ty) != .ptr_type) return false;
        const from_ty = w.ir.typeOf(op.operand, w.ip);
        if (w.ip.keyTag(from_ty) != .ptr_type) return false;
        var from = Type.ptrInfo(w.ip, from_ty);
        const to = Type.ptrInfo(w.ip, op.ty);
        if (!to.flags.is_const) return false;
        from.flags.is_const = true;
        return std.meta.eql(from, to);
    }

    fn isArg(w: *const Walk, ref: Inst.Ref) bool {
        if (ref == .none) return false;
        const i = ref.toIndex() orelse return false;
        return w.ir.instructions.items(.tag)[@backingInt(i)] == .arg;
    }

    /// The value `ref` was found to be (`forwardLoads`).
    fn resolve(w: *const Walk, ref: Inst.Ref) Inst.Ref {
        const i = ref.toIndex() orelse return ref;
        const to = w.subst[@backingInt(i)];
        return if (to == none) ref else @fromBackingInt(to);
    }

    fn body(w: *Walk, insts: []const Inst.Index) void {
        // Where the body lies in `extra`, for a loop's slot (`store`).
        const at: u32 = @intCast(@as([*]const u32, @ptrCast(insts.ptr)) - w.ir.extra.ptr);
        for (insts, at..) |inst, slot| w.instruction(inst, @intCast(slot));
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
            if (tags[b] != .block or w.exits[b] == none) continue;
            const insts = blockBody(ir, @fromBackingInt(b));
            const last = @backingInt(insts[insts.len - 1]);
            // Its first exit is its last instruction: its only one.
            if (w.exits[b] != w.pos[last] or tags[last] != .br) continue;
            for (insts) |i| w.scope_end[@backingInt(i)] = w.scope_end[b];
        }
    }

    /// Whether `d`, at a position before `i`, dominates `i`: `i` is in
    /// its scope, or past blocks `d` runs in before they are left
    /// (`dom_end`). That is filled on the first question `scope_end`
    /// does not answer, from the blocks left before their end, outer ones
    /// first, so a block's own reach is known before its body's.
    fn dominates(w: *Walk, d: u32, i: u32) bool {
        if (w.pos[i] <= w.scope_end[d]) return true;
        if (w.early_len == 0) return false;
        if (!w.dom_ready) {
            w.dom_ready = true;
            @memcpy(w.dom_end, w.scope_end);
            var k = w.early_len;
            while (k > 0) {
                k -= 1;
                const b = w.early[k];
                w.dominated(blockBody(w.ir, @fromBackingInt(b)), w.exits[b], w.dom_end[b]);
            }
        }
        return w.pos[i] <= w.dom_end[d];
    }

    /// The instructions of `insts` that run on every path to position
    /// `exit`, the first `br` that leaves an enclosing block, dominate
    /// what follows that block, up to `to`: those before the instruction
    /// holding `exit`, and in it, when it is a block, those of its body
    /// before both `exit` and the block's own first `br`. Not those in a
    /// branch or a loop. A `br` is the only way out of a block that does
    /// not leave the function, so its positions are where that block's
    /// successors are entered from. Nothing is loaded where the program
    /// did not load: a load is only read where one it dominates runs.
    fn dominated(w: *Walk, insts: []const Inst.Index, exit: u32, to: u32) void {
        const tags = w.ir.instructions.items(.tag);
        for (insts, 0..) |inst, k| {
            const i = @backingInt(inst);
            if (k + 1 < insts.len and w.pos[@backingInt(insts[k + 1])] <= exit) {
                w.dom_end[i] = @max(w.dom_end[i], to);
                // A block left before `exit`: so are those of its body
                // that run before it is left.
                if (tags[i] == .block and w.exits[i] != none) w.dominated(blockBody(w.ir, inst), w.exits[i], to);
                continue;
            }
            if (tags[i] == .block) w.dominated(blockBody(w.ir, inst), @min(exit, w.exits[i]), to);
            return;
        }
    }

    fn instruction(w: *Walk, inst: Inst.Index, slot: u32) void {
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
                const first = &w.exits[@backingInt(data.br.block_inst)];
                if (first.* == none) first.* = w.pos[i];
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
                w.exits[i] = none;
                const insts = blockBody(ir, inst);
                w.body(insts);
                w.store[i] = w.next - 1;
                if (w.exits[i] != none and w.exits[i] != w.pos[@backingInt(insts[insts.len - 1])]) {
                    w.early[w.early_len] = i;
                    w.early_len += 1;
                }
            },
            // Its operand, to `canon`, as are the casts `forwardCopies`
            // makes.
            .bitcast => if (w.constOnly(data.ty_op)) {
                w.alias[i] = @backingInt(data.ty_op.operand);
            },
            .loop => {
                w.store[i] = slot;
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

    /// Whether an instruction that writes through pointers it was given or
    /// loaded may write `local` (any memory, for `none`): only if its
    /// address escapes, since every pointer derived from it is an operand
    /// that escapes it.
    fn reaches(w: *const Walk, local: u32) bool {
        return local == none or w.flags[local].escaped;
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
            .call => return ir.extraData(Ir.Call, data.pl_op.payload).data.ret_ty != .noreturn_type and w.reaches(local),
            .atomic_store, .atomic_rmw, .cmpxchg, .assembly, .vector_store_elem, .c_va_start, .c_va_arg, .c_va_copy => return w.reaches(local),
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
