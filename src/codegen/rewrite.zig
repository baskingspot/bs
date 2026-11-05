//! Peephole rewrites of a function's IR before CodeGen
//! (docs/slop/architecture.md, "Rewrite rules"): a table of rules, pattern →
//! replacement over the IR's operations, applied in one forward walk.
//! An instruction's operands are rewritten before the instruction itself
//! is matched, so a chain of folds (`n - 1` of a constant `n`, then its
//! overflow check) resolves in the same walk. A matched instruction is
//! replaced by an operand or a constant in every later use; it keeps its
//! place in the IR, and the dead-code pass drops it once nothing uses it.
//! A `cond_br` whose condition became constant is left for `Ssa.build`,
//! which builds only the taken body.
//!
//! Inlining makes most of the opportunities: a callee's parameters become
//! the caller's constants. Runs on the Sema thread, which may intern.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const Index = InternPool.Index;
const Ir = @import("../Ir.zig");
const Inst = Ir.Inst;
const Tag = Inst.Tag;
const Type = @import("../Type.zig");
const Ssa = @import("Ssa.zig");
const sroa = @import("sroa.zig");

/// What an operand must be for a rule to match.
const Pat = enum {
    any,
    /// A constant integer or bool.
    k,
    zero,
    one,
    /// All bits set.
    ones,
    /// The same value as the other operand (only on `r`).
    same,
};

/// What a matched instruction becomes.
const Out = enum { lhs, rhs, zero, false, true, eval };

const Rule = struct {
    tags: []const Tag,
    l: Pat = .any,
    r: Pat = .any,
    /// Only for unsigned operands.
    unsigned: bool = false,
    out: Out,
};

const arith = [_]Tag{ .add_wrap, .sub_wrap, .mul_wrap, .bit_and, .bit_or, .xor, .shl, .shr, .div_trunc, .div_floor, .div_ceil, .rem, .mod };
const cmps = [_]Tag{ .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq };
const casts = [_]Tag{ .not, .intcast, .trunc, .int_from_bool };

/// Binary operations take `l` and `r`; unary ones (`casts`) only `l`.
const rules = [_]Rule{
    .{ .tags = &(arith ++ cmps), .l = .k, .r = .k, .out = .eval },
    .{ .tags = &casts, .l = .k, .out = .eval },
    // Identities (slicing from 0, `sliceAsBytes` of bytes, inlined
    // arithmetic on constant arguments).
    .{ .tags = &.{ .add_wrap, .sub_wrap, .bit_or, .xor, .shl, .shr }, .r = .zero, .out = .lhs },
    .{ .tags = &.{ .add_wrap, .bit_or, .xor }, .l = .zero, .out = .rhs },
    .{ .tags = &.{ .mul_wrap, .div_trunc, .div_floor, .div_ceil }, .r = .one, .out = .lhs },
    .{ .tags = &.{.mul_wrap}, .l = .one, .out = .rhs },
    .{ .tags = &.{ .mul_wrap, .bit_and }, .r = .zero, .out = .zero },
    .{ .tags = &.{ .mul_wrap, .bit_and, .shl, .shr }, .l = .zero, .out = .zero },
    .{ .tags = &.{.bit_and}, .r = .ones, .out = .lhs },
    .{ .tags = &.{.bit_and}, .l = .ones, .out = .rhs },
    .{ .tags = &.{ .bit_and, .bit_or }, .r = .same, .out = .lhs },
    .{ .tags = &.{ .xor, .sub_wrap }, .r = .same, .out = .zero },
    .{ .tags = &.{ .cmp_eq, .cmp_lte, .cmp_gte }, .r = .same, .out = .true },
    .{ .tags = &.{ .cmp_neq, .cmp_lt, .cmp_gt }, .r = .same, .out = .false },
    // An unsigned value is at least 0.
    .{ .tags = &.{.cmp_gte}, .r = .zero, .unsigned = true, .out = .true },
    .{ .tags = &.{.cmp_lt}, .r = .zero, .unsigned = true, .out = .false },
    .{ .tags = &.{.cmp_lte}, .l = .zero, .unsigned = true, .out = .true },
    .{ .tags = &.{.cmp_gt}, .l = .zero, .unsigned = true, .out = .false },
};

/// `rules` by tag, in table order.
const by_tag: [@typeInfo(Tag).@"enum".field_names.len][]const Rule = blk: {
    @setEvalBranchQuota(10_000);
    var lists: [@typeInfo(Tag).@"enum".field_names.len][]const Rule = @splat(&.{});
    for (rules) |rule| for (rule.tags) |t| {
        lists[@backingInt(t)] = lists[@backingInt(t)] ++ .{rule};
    };
    break :blk lists;
};

pub const Stats = struct {
    /// Instructions replaced, and `cond_br`s whose condition became
    /// constant.
    folds: u32 = 0,
    branches: u32 = 0,
};

pub const Scratch = struct {
    words: std.ArrayList(u32) = .empty,
    brs: std.ArrayList(Inst.Index) = .empty,

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        s.words.deinit(gpa);
        s.brs.deinit(gpa);
        s.* = undefined;
    }
};

/// Applies `rules` to `ir`, interning new constants on `tid`. `scratch`
/// is kept for the next function. `seeds` are instructions already
/// replaced (`sroa.run`).
pub fn run(gpa: Allocator, ip: *InternPool, tid: InternPool.Tid, ir: *Ir, scratch: *Scratch, seeds: []const sroa.Seed) Allocator.Error!Stats {
    const n = ir.instructions.len;
    try scratch.words.resize(gpa, 4 * n);
    scratch.brs.clearRetainingCapacity();
    const words = scratch.words.items;
    var w: Walker = .{
        .gpa = gpa,
        .brs = &scratch.brs,
        .ip = ip,
        .tid = tid,
        .ir = ir,
        .info = @ptrCast(words[0 .. 2 * n]),
        .pos = words[2 * n ..][0..n],
        .val = @ptrCast(words[3 * n ..][0..n]),
    };
    @memset(w.info, .{ .subst = .none, .root = no_root });
    for (seeds) |seed| w.info[@backingInt(seed.inst)].subst = seed.ref;
    try w.body(ir.mainBody());
    // A replaced block's `br`s write no result: its value no longer keeps
    // theirs alive.
    const datas = ir.instructions.items(.data);
    for (scratch.brs.items) |br| {
        const b = &datas[@backingInt(br)].br;
        if (w.info[@backingInt(b.block_inst)].subst != .none) b.operand = .void_value;
    }
    return w.stats;
}

const no_root = std.math.maxInt(u32);
/// `Info.subst` of a block exited with different values.
const mixed: Inst.Ref = @fromBackingInt(std.math.maxInt(u32) - 1);
/// `Walker.val` of a constant alloc that something else may write.
const poisoned: Index = .unreachable_value;

const Info = extern struct {
    /// What replaces the instruction, or `.none`. For a `block` until its
    /// body is walked: the value its `br`s exit with so far, or `mixed`.
    subst: Inst.Ref,
    /// For a pointer into a `*const` alloc (the alloc, and the
    /// `struct_field_ptr`s and `ptr_elem_ptr`s of such pointers): the
    /// alloc, else `no_root`.
    root: u32,
};

/// An operand's constant value: its bits, and its type's.
const Const = struct { bits: u64, info: Type.IntInfo };

const Walker = struct {
    gpa: Allocator,
    /// The `br`s with a value.
    brs: *std.ArrayList(Inst.Index),
    ip: *InternPool,
    tid: InternPool.Tid,
    ir: *Ir,
    /// Per instruction, read for each use of it.
    info: []Info,
    /// Per instruction, its place in the walk.
    pos: []u32,
    /// Per such alloc: the constant its initializing store stored, `.none`
    /// before that store, or `poisoned`.
    val: []Index,
    next_pos: u32 = 0,
    /// The instruction whose operands `use` sees, and how many it saw.
    user: Tag = undefined,
    operand: u32 = 0,
    stats: Stats = .{},

    pub fn use(w: *Walker, p: *Inst.Ref) void {
        defer w.operand += 1;
        const i = p.toIndex() orelse return;
        const s = w.info[@backingInt(i)].subst;
        // A block's value is used only after its body, once `subst` holds
        // its replacement.
        if (s != .none) p.* = s;
        // A pointer into a constant alloc used other than to read through
        // it or to derive another such pointer: what it points to may
        // change.
        const r = w.info[@backingInt((p.toIndex() orelse return))].root;
        if (r == no_root) return;
        switch (w.user) {
            .load, .struct_field_ptr => return,
            .ptr_elem_ptr => if (w.operand == 0) return,
            // The initializing store (`instruction`).
            .store => if (w.operand == 0) return,
            else => {},
        }
        w.val[r] = poisoned;
    }

    fn body(w: *Walker, insts: []const Inst.Index) Allocator.Error!void {
        for (insts) |inst| try w.instruction(inst);
    }

    fn instruction(w: *Walker, inst: Inst.Index) Allocator.Error!void {
        const ir = w.ir;
        const ii = @backingInt(inst);
        w.pos[ii] = w.next_pos;
        w.next_pos += 1;
        const tag = ir.instructions.items(.tag)[ii];
        w.user = tag;
        w.operand = 0;
        Ssa.forEachOperandPtr(ir, inst, w);
        const data = ir.instructions.items(.data)[ii];
        switch (tag) {
            .block => {
                const x = ir.extraData(Ir.Block, data.ty_pl.payload);
                const insts = ir.bodySlice(x.end, x.data.body_len);
                try w.body(insts);
                // A block every `br` exits with the same value is that
                // value: one defined before it (an inlined call's constant
                // result), or one its body ends exiting with (an inlined
                // call's result), which dominates every `br`.
                const r = w.info[ii].subst;
                w.info[ii].subst = .none;
                if (r == .none or r == mixed or data.ty_pl.ty == .void_type) return;
                if (r.toIndex()) |d| if (w.pos[@backingInt(d)] >= w.pos[ii]) {
                    const last = @backingInt(insts[insts.len - 1]);
                    if (ir.instructions.items(.tag)[last] != .br or ir.instructions.items(.data)[last].br.block_inst != inst) return;
                };
                w.info[ii].subst = r;
                w.stats.folds += 1;
            },
            .loop => {
                const x = ir.extraData(Ir.Block, data.ty_pl.payload);
                try w.body(ir.bodySlice(x.end, x.data.body_len));
            },
            .br => {
                if (data.br.operand.toInterned() == null) try w.brs.append(w.gpa, inst);
                const b = &w.info[@backingInt(data.br.block_inst)].subst;
                if (b.* == .none) b.* = data.br.operand else if (b.* != data.br.operand) b.* = mixed;
            },
            .alloc => if (data.ty != .none and Type.ptrInfo(w.ip, data.ty).flags.is_const) {
                w.info[ii].root = ii;
                w.val[ii] = .none;
            },
            .store => {
                const p = data.bin_op.lhs.toIndex() orelse return;
                const r = w.info[@backingInt(p)].root;
                if (r == no_root) return;
                const v = data.bin_op.rhs.toInterned();
                w.val[r] = if (r == @backingInt(p) and w.val[r] == .none and v != null and w.ip.keyTag(v.?) != .undef) v.? else poisoned;
            },
            // The pointer (`StructField.operand`, `Bin.lhs`) is first.
            .struct_field_ptr, .ptr_elem_ptr => if (@as(Inst.Ref, @fromBackingInt(ir.extra[data.ty_pl.payload])).toIndex()) |p| {
                w.info[ii].root = w.info[@backingInt(p)].root;
            },
            .cond_br => {
                const x = ir.extraData(Ir.CondBr, data.pl_op.payload);
                const then_body = ir.bodySlice(x.end, x.data.then_body_len);
                const else_body = ir.bodySlice(x.end + then_body.len, x.data.else_body_len);
                if (constBool(data.pl_op.operand)) |c| {
                    w.stats.branches += 1;
                    return w.body(if (c) then_body else else_body);
                }
                try w.body(then_body);
                try w.body(else_body);
            },
            .switch_br => {
                var it = ir.switchCases(data.pl_op.payload);
                while (it.next()) |c| try w.body(c.body);
                try w.body(it.elseBody());
            },
            else => if (try w.match(inst, tag, data)) |r| {
                w.info[@backingInt(inst)].subst = r;
                w.stats.folds += 1;
            },
        }
    }

    /// What `inst` becomes under the first rule that matches it, if any.
    fn match(w: *Walker, inst: Inst.Index, tag: Tag, data: Inst.Data) Allocator.Error!?Inst.Ref {
        const ip = w.ip;
        switch (tag) {
            .struct_field_val => return try w.overflowField(data) orelse w.constField(data) orelse w.initField(data),
            .slice_ptr, .slice_len, .optional_payload, .unwrap_errunion_payload => return w.constPart(tag, data.ty_op.operand) orelse w.wrapPart(tag, data.ty_op.operand),
            .unwrap_errunion_err => return w.wrapPart(tag, data.ty_op.operand),
            .is_null, .is_non_null, .is_err, .is_non_err => return w.constPart(tag, data.un_op) orelse w.wrapPart(tag, data.un_op),
            .bitcast => return w.constAlias(data.ty_op),
            .array_elem_val => return w.constElem(data.bin_op.lhs, data.bin_op.rhs),
            .load => return w.loadConst(data.ty_op.operand),
            .add_with_overflow, .sub_with_overflow, .mul_with_overflow => return w.overflowConst(inst, tag, data),
            else => {},
        }
        const list = by_tag[@backingInt(tag)];
        if (list.len == 0) return null;
        const unary = switch (tag) {
            .not, .intcast, .trunc, .int_from_bool => true,
            else => false,
        };
        const lhs: Inst.Ref, const rhs: Inst.Ref = if (unary)
            .{ if (tag == .int_from_bool) data.un_op else data.ty_op.operand, .none }
        else
            .{ data.bin_op.lhs, data.bin_op.rhs };
        // Every rule needs a constant operand or the same one twice; most
        // instructions have neither.
        if (lhs.toInterned() == null and (unary or (rhs.toInterned() == null and rhs != lhs))) return null;
        const ty = w.ir.typeOf(lhs, ip);
        const class = Type.class(ip, ty);
        switch (class) {
            .int, .bool => {},
            // Only `x == x` and the like.
            .pointer, .@"enum" => if (unary or rhs != lhs) return null,
            else => return null,
        }
        if (class == .int and Type.intInfo(ip, ty).bits > 64) return null;
        const lc = w.constOf(lhs);
        const rc = if (unary) null else w.constOf(rhs);
        const unsigned = class == .bool or (class == .int and Type.intInfo(ip, ty).signedness == .unsigned);
        for (list) |rule| {
            if (rule.unsigned and !unsigned) continue;
            if (!matches(rule.l, lc, lhs, rhs) or !matches(rule.r, rc, rhs, lhs)) continue;
            const res_ty = switch (tag) {
                .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => Index.bool_type,
                else => w.ir.typeOfIndex(inst, ip),
            };
            return switch (rule.out) {
                .lhs => lhs,
                .rhs => rhs,
                .zero => try w.intern(res_ty, 0),
                .false => .fromInterned(.bool_false),
                .true => .fromInterned(.bool_true),
                .eval => if (w.resultInfo(res_ty).bits <= 64) if (eval(tag, lc.?, rc, w.resultInfo(res_ty))) |bits| try w.intern(res_ty, bits) else null else null,
            };
        }
        return null;
    }

    /// An overflow operation on constants, as its constant tuple (which
    /// `@addWithOverflow` and the like store to memory).
    fn overflowConst(w: *Walker, inst: Inst.Index, tag: Tag, data: Inst.Data) Allocator.Error!?Inst.Ref {
        const ip = w.ip;
        const bin = w.ir.extraData(Ir.Bin, data.ty_pl.payload).data;
        if (bin.lhs.toInterned() == null or bin.rhs.toInterned() == null) return null;
        const ty = w.ir.typeOf(bin.lhs, ip);
        if (Type.class(ip, ty) != .int or Type.intInfo(ip, ty).bits > 64) return null;
        const l = w.constOf(bin.lhs) orelse return null;
        const r = w.constOf(bin.rhs) orelse return null;
        const a = value(l);
        const b = value(r);
        const exact: i128 = switch (tag) {
            .add_with_overflow => a + b,
            .sub_with_overflow => a - b,
            else => a * b,
        };
        const wrapped = truncate(low64(exact), l.info.bits);
        const elems = [2]Index{
            (try w.intern(ty, wrapped)).toInterned().?,
            (try w.intern(.u1_type, @intFromBool(value(.{ .bits = wrapped, .info = l.info }) != exact))).toInterned().?,
        };
        return .fromInterned(try ip.get(w.tid, .{ .aggregate = .{ .ty = w.ir.typeOfIndex(inst, ip), .storage = .{ .elems = &elems } } }));
    }

    /// A field of an overflow operation that is an identity (`x + 0`,
    /// `x - x`, `x * 1`, `x * 0`).
    fn overflowField(w: *Walker, data: Inst.Data) Allocator.Error!?Inst.Ref {
        const ir = w.ir;
        const ip = w.ip;
        const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
        const op = sf.operand.toIndex() orelse return null;
        const op_tag = ir.instructions.items(.tag)[@backingInt(op)];
        switch (op_tag) {
            .add_with_overflow, .sub_with_overflow, .mul_with_overflow => {},
            else => return null,
        }
        const bin = ir.extraData(Ir.Bin, ir.instructions.items(.data)[@backingInt(op)].ty_pl.payload).data;
        if (bin.lhs.toInterned() == null and bin.rhs.toInterned() == null and bin.lhs != bin.rhs) return null;
        const ty = ir.typeOf(bin.lhs, ip);
        if (Type.class(ip, ty) != .int or Type.intInfo(ip, ty).bits > 64) return null;
        // On constants the operation itself became a constant tuple
        // (`overflowConst`), which `constField` reads.
        const l = w.constOf(bin.lhs);
        const r = w.constOf(bin.rhs);
        const is = struct {
            fn f(c: ?Const, v: i128) bool {
                return if (c) |k| value(k) == v else false;
            }
        }.f;
        // The result, as an operand or 0; then the bit is 0.
        const result: Inst.Ref = switch (op_tag) {
            .add_with_overflow => if (is(r, 0)) bin.lhs else if (is(l, 0)) bin.rhs else return null,
            .sub_with_overflow => if (is(r, 0)) bin.lhs else if (bin.lhs == bin.rhs) try w.intern(ty, 0) else return null,
            else => if (is(r, 1)) bin.lhs else if (is(l, 1)) bin.rhs else if (is(r, 0) or is(l, 0)) try w.intern(ty, 0) else return null,
        };
        return if (sf.index == 0) result else try w.intern(.u1_type, 0);
    }

    /// A load through a pointer into a constant alloc, of what its
    /// initializing store stored.
    fn loadConst(w: *Walker, ptr: Inst.Ref) Allocator.Error!?Inst.Ref {
        const v = try w.pointee(ptr) orelse return null;
        return .fromInterned(v);
    }

    /// The constant pointer `ptr` into a constant alloc points to.
    fn pointee(w: *Walker, ptr: Inst.Ref) Allocator.Error!?Index {
        const ir = w.ir;
        const ip = w.ip;
        const p = ptr.toIndex() orelse return null;
        const pi = @backingInt(p);
        const r = w.info[pi].root;
        if (r == no_root or w.val[r] == .none or w.val[r] == poisoned) return null;
        if (r == pi) return w.val[r];
        const data = ir.instructions.items(.data)[pi];
        switch (ir.instructions.items(.tag)[pi]) {
            .struct_field_ptr => {
                const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
                const agg = try w.pointee(sf.operand) orelse return null;
                if (ip.keyTag(agg) != .aggregate) return null;
                return switch (ip.keyPayload(.aggregate, agg).storage) {
                    .elems => |elems| elems[sf.index],
                    .repeated_elem => |e| e,
                    .bytes => null,
                };
            },
            .ptr_elem_ptr => {
                const bin = ir.extraData(Ir.Bin, data.ty_pl.payload).data;
                const agg = try w.pointee(bin.lhs) orelse return null;
                const e = try w.constElem(.fromInterned(agg), bin.rhs) orelse return null;
                return e.toInterned();
            },
            else => return null,
        }
    }

    /// A field of an `aggregate_init` of a struct or tuple.
    fn initField(w: *Walker, data: Inst.Data) ?Inst.Ref {
        const ir = w.ir;
        const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
        const i = @backingInt(sf.operand.toIndex() orelse return null);
        if (ir.instructions.items(.tag)[i] != .aggregate_init) return null;
        const agg = ir.instructions.items(.data)[i].ty_pl;
        switch (w.ip.keyTag(agg.ty)) {
            .struct_type => if (Type.isPackedStruct(w.ip, agg.ty)) return null,
            .tuple_type => {},
            else => return null,
        }
        const x = ir.extraData(Ir.Aggregate, agg.payload);
        if (x.data.len != Type.fieldCount(w.ip, agg.ty)) return null;
        return ir.refSlice(x.end, x.data.len)[sf.index];
    }

    /// A field of a constant struct or tuple.
    fn constField(w: *Walker, data: Inst.Data) ?Inst.Ref {
        const sf = w.ir.extraData(Ir.StructField, data.ty_pl.payload).data;
        const v = sf.operand.toInterned() orelse return null;
        if (w.ip.keyTag(v) != .aggregate) return null;
        return switch (w.ip.keyPayload(.aggregate, v).storage) {
            .elems => |elems| .fromInterned(elems[sf.index]),
            .repeated_elem => |e| .fromInterned(e),
            .bytes => null,
        };
    }

    /// An element at a constant index of a constant array.
    fn constElem(w: *Walker, array: Inst.Ref, index: Inst.Ref) Allocator.Error!?Inst.Ref {
        const ip = w.ip;
        const v = array.toInterned() orelse return null;
        const i = index.toInterned() orelse return null;
        if (ip.keyTag(v) != .aggregate or ip.keyTag(i) != .int) return null;
        const k = ip.intValue(usize, i) orelse return null;
        const agg = ip.keyPayload(.aggregate, v);
        const arr = ip.keyAs(.array_type, agg.ty) orelse return null;
        if (k >= arr.len) return null;
        return switch (agg.storage) {
            .elems => |elems| .fromInterned(elems[k]),
            .repeated_elem => |e| .fromInterned(e),
            .bytes => |b| try w.intern(arr.child, ip.stringSlice(b)[k]),
        };
    }

    /// What `tag` reads of a constant slice, optional, or error union.
    fn constPart(w: *Walker, tag: Tag, operand: Inst.Ref) ?Inst.Ref {
        const ip = w.ip;
        const v = operand.toInterned() orelse return null;
        const b = struct {
            fn f(x: bool) Inst.Ref {
                return .fromInterned(if (x) .bool_true else .bool_false);
            }
        }.f;
        switch (ip.keyTag(v)) {
            .slice => {
                const sl = ip.keyPayload(.slice, v);
                return switch (tag) {
                    .slice_ptr => .fromInterned(sl.ptr),
                    .slice_len => .fromInterned(sl.len),
                    else => null,
                };
            },
            .opt => {
                const o = ip.keyPayload(.opt, v);
                return switch (tag) {
                    .is_null => b(o.val == .none),
                    .is_non_null => b(o.val != .none),
                    .optional_payload => if (o.val != .none) .fromInterned(o.val) else null,
                    else => null,
                };
            },
            .error_union => {
                const eu = ip.keyPayload(.error_union, v);
                const is_err = eu.val == .err_name;
                return switch (tag) {
                    .is_err => b(is_err),
                    .is_non_err => b(!is_err),
                    .unwrap_errunion_payload => if (is_err) null else .fromInterned(eu.val.payload),
                    else => null,
                };
            },
            else => return null,
        }
    }

    /// What `tag` reads of an optional or error union `operand` wraps:
    /// `return x` in a function that traces errors tests the error union
    /// it just made.
    fn wrapPart(w: *Walker, tag: Tag, operand: Inst.Ref) ?Inst.Ref {
        const i = @backingInt(operand.toIndex() orelse return null);
        const b = struct {
            fn f(x: bool) Inst.Ref {
                return .fromInterned(if (x) .bool_true else .bool_false);
            }
        }.f;
        const wrap = w.ir.instructions.items(.tag)[i];
        switch (wrap) {
            .wrap_optional, .wrap_errunion_payload, .wrap_errunion_err => {},
            else => return null,
        }
        const inner = w.ir.instructions.items(.data)[i].ty_op.operand;
        return switch (wrap) {
            .wrap_optional => switch (tag) {
                .is_null => b(false),
                .is_non_null => b(true),
                .optional_payload => inner,
                else => null,
            },
            .wrap_errunion_payload => switch (tag) {
                .is_err => b(false),
                .is_non_err => b(true),
                .unwrap_errunion_payload => inner,
                else => null,
            },
            .wrap_errunion_err => switch (tag) {
                .is_err => b(true),
                .is_non_err => b(false),
                .unwrap_errunion_err => inner,
                else => null,
            },
            else => null,
        };
    }

    /// A pointer to a local that only adds `const`, which is the local's
    /// own pointer: Sema makes a destructured `const` local that way, and
    /// its loads then read the alloc, which the SSA can promote. No
    /// lowering reads a pointer type's constness.
    fn constAlias(w: *Walker, op: @FieldType(Inst.Data, "ty_op")) ?Inst.Ref {
        const p = op.operand.toIndex() orelse return null;
        if (w.ir.instructions.items(.tag)[@backingInt(p)] != .alloc) return null;
        const from_ty = w.ir.instructions.items(.data)[@backingInt(p)].ty;
        if (from_ty == .none or w.ip.keyTag(op.ty) != .ptr_type) return null;
        var from = Type.ptrInfo(w.ip, from_ty);
        const to = Type.ptrInfo(w.ip, op.ty);
        // Not `@constCast`: a store through the cast would then reach a
        // `const` alloc, which `planConstAliases` may place in rodata.
        if (!to.flags.is_const) return null;
        from.flags.is_const = true;
        if (!std.meta.eql(from, to)) return null;
        return op.operand;
    }

    fn resultInfo(w: *const Walker, ty: Index) Type.IntInfo {
        if (ty == .bool_type) return .{ .signedness = .unsigned, .bits = 1 };
        return Type.intInfo(w.ip, ty);
    }

    fn constOf(w: *const Walker, ref: Inst.Ref) ?Const {
        const v = ref.toInterned() orelse return null;
        const ip = w.ip;
        if (v == .bool_true or v == .bool_false) return .{ .bits = @intFromBool(v == .bool_true), .info = .{ .signedness = .unsigned, .bits = 1 } };
        if (ip.keyTag(v) != .int) return null;
        const ty = ip.typeOf(v);
        if (Type.class(ip, ty) != .int) return null;
        const info = Type.intInfo(ip, ty);
        if (info.bits > 64) return null;
        const x = ip.intValue(i128, v) orelse return null;
        return .{ .bits = truncate(low64(x), info.bits), .info = info };
    }

    /// Interns `bits` as a value of `ty` (a bool or an integer).
    fn intern(w: *Walker, ty: Index, bits: u64) Allocator.Error!Inst.Ref {
        if (ty == .bool_type) return .fromInterned(if (bits != 0) .bool_true else .bool_false);
        const info = Type.intInfo(w.ip, ty);
        const v = value(.{ .bits = bits, .info = info });
        return .fromInterned(if (v >= 0)
            try w.ip.getInt(w.tid, ty, @as(u64, @intCast(v)))
        else
            try w.ip.getInt(w.tid, ty, @as(i64, @intCast(v))));
    }
};

fn constBool(ref: Inst.Ref) ?bool {
    const v = ref.toInterned() orelse return null;
    return switch (v) {
        .bool_true => true,
        .bool_false => false,
        else => null,
    };
}

fn matches(pat: Pat, c: ?Const, ref: Inst.Ref, other: Inst.Ref) bool {
    return switch (pat) {
        .any => true,
        .k => c != null,
        .zero => if (c) |k| k.bits == 0 else false,
        // The value 1: an i1's only set bit is -1.
        .one => if (c) |k| value(k) == 1 else false,
        .ones => if (c) |k| k.bits == truncate(std.math.maxInt(u64), k.info.bits) else false,
        .same => ref == other and ref.toIndex() != null,
    };
}

/// The low 64 bits of `x`'s two's complement.
fn low64(x: i128) u64 {
    return @truncate(@as(u128, @bitCast(x)));
}

/// The low `bits` bits of `x`.
fn truncate(x: u64, bits: u16) u64 {
    return if (bits >= 64) x else x & ((@as(u64, 1) << @intCast(bits)) - 1);
}

/// The value of `c`'s bits in its type.
fn value(c: Const) i128 {
    if (c.info.signedness == .unsigned or c.info.bits == 0) return c.bits;
    const sh: u7 = @intCast(128 - @as(u8, @intCast(c.info.bits)));
    return @as(i128, @bitCast(@as(u128, c.bits) << sh)) >> sh;
}

/// `tag` on constants `l` and `r` (unary operations ignore `r`), as the
/// IR defines it, in the bits of a result of `res`; null where the IR
/// leaves the result undefined (a division by zero, an oversized shift)
/// or a cast's value does not fit.
fn eval(tag: Tag, l: Const, r: ?Const, res: Type.IntInfo) ?u64 {
    const a = value(l);
    const bits = l.info.bits;
    if (r) |rc| {
        const b = value(rc);
        const out: i128 = switch (tag) {
            .add_wrap => a +% b,
            .sub_wrap => a -% b,
            .mul_wrap => a *% b,
            .bit_and => return l.bits & rc.bits,
            .bit_or => return l.bits | rc.bits,
            .xor => return l.bits ^ rc.bits,
            .shl => if (rc.bits >= bits) return null else return truncate(l.bits << @intCast(rc.bits), bits),
            .shr => if (rc.bits >= bits) return null else a >> @intCast(rc.bits),
            .div_trunc, .div_floor, .div_ceil, .rem, .mod => blk: {
                if (b == 0) return null;
                const q = @divTrunc(a, b);
                // minInt / -1.
                if (value(.{ .bits = truncate(low64(q), bits), .info = l.info }) != q) return null;
                break :blk switch (tag) {
                    .div_trunc => q,
                    .div_floor => @divFloor(a, b),
                    .div_ceil => if (@rem(a, b) != 0 and (a < 0) == (b < 0)) q + 1 else q,
                    .rem => @rem(a, b),
                    else => @mod(a, b),
                };
            },
            .cmp_lt => return @intFromBool(a < b),
            .cmp_lte => return @intFromBool(a <= b),
            .cmp_eq => return @intFromBool(a == b),
            .cmp_gte => return @intFromBool(a >= b),
            .cmp_gt => return @intFromBool(a > b),
            .cmp_neq => return @intFromBool(a != b),
            else => unreachable,
        };
        return truncate(low64(out), bits);
    }
    return switch (tag) {
        .not => truncate(~l.bits, bits),
        .int_from_bool => l.bits,
        .trunc => truncate(l.bits, res.bits),
        .intcast => {
            const out = truncate(low64(a), res.bits);
            return if (value(.{ .bits = out, .info = res }) == a) out else null;
        },
        else => unreachable,
    };
}

test eval {
    const u8_: Type.IntInfo = .{ .signedness = .unsigned, .bits = 8 };
    const i8_: Type.IntInfo = .{ .signedness = .signed, .bits = 8 };
    const u1_: Type.IntInfo = .{ .signedness = .unsigned, .bits = 1 };
    const k = struct {
        fn f(bits: u64, info: Type.IntInfo) Const {
            return .{ .bits = bits, .info = info };
        }
    }.f;
    // Wrapping at the type's width.
    try std.testing.expectEqual(4, eval(.add_wrap, k(250, u8_), k(10, u8_), u8_));
    try std.testing.expectEqual(0x80, eval(.sub_wrap, k(0x7f, i8_), k(0xff, i8_), i8_)); // 127 - -1
    // Arithmetic shift for signed, logical for unsigned; oversized shifts
    // stay.
    try std.testing.expectEqual(0xfc, eval(.shr, k(0xf0, i8_), k(2, i8_), i8_));
    try std.testing.expectEqual(0x3c, eval(.shr, k(0xf0, u8_), k(2, u8_), u8_));
    try std.testing.expectEqual(null, eval(.shl, k(1, u8_), k(8, u8_), u8_));
    // Signed division rounds as each tag says; -128 / -1 and / 0 stay.
    try std.testing.expectEqual(0xfe, eval(.div_trunc, k(0xf9, i8_), k(3, i8_), i8_)); // -7 / 3 = -2
    try std.testing.expectEqual(0xfd, eval(.div_floor, k(0xf9, i8_), k(3, i8_), i8_)); // -3
    try std.testing.expectEqual(3, eval(.div_ceil, k(7, i8_), k(3, i8_), i8_));
    try std.testing.expectEqual(0xfe, eval(.div_ceil, k(0xf9, i8_), k(3, i8_), i8_)); // ceil(-7/3) = -2
    try std.testing.expectEqual(0xff, eval(.rem, k(0xf9, i8_), k(3, i8_), i8_)); // -1
    try std.testing.expectEqual(2, eval(.mod, k(0xf9, i8_), k(3, i8_), i8_));
    try std.testing.expectEqual(null, eval(.div_trunc, k(0x80, i8_), k(0xff, i8_), i8_));
    try std.testing.expectEqual(null, eval(.rem, k(5, u8_), k(0, u8_), u8_));
    // Compares read the operands' signedness.
    try std.testing.expectEqual(1, eval(.cmp_lt, k(0xff, i8_), k(0, i8_), u1_));
    try std.testing.expectEqual(0, eval(.cmp_lt, k(0xff, u8_), k(0, u8_), u1_));
    // Casts: `intcast` keeps the value or does not fold, `trunc` keeps the
    // low bits.
    try std.testing.expectEqual(0xffff, eval(.intcast, k(0xff, i8_), null, .{ .signedness = .signed, .bits = 16 }));
    try std.testing.expectEqual(null, eval(.intcast, k(0xff, i8_), null, .{ .signedness = .unsigned, .bits = 16 }));
    try std.testing.expectEqual(0x34, eval(.trunc, k(0x1234, .{ .signedness = .unsigned, .bits = 16 }), null, u8_));
    try std.testing.expectEqual(0x0f, eval(.not, k(0xf0, u8_), null, u8_));
}
