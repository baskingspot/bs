//! Full unrolling of tiny constant-trip loops (docs/slop/architecture.md,
//! "Unrolling"): a `for` over comptime-known arrays or a constant range,
//! in the shape Sema gives it, whose body runs at most `max_trips` times,
//! becomes one copy of the body per iteration with the counter a
//! constant, before the rewrite rules fold what the constant makes
//! constant (elements of constant arrays, the bounds checks against the
//! arrays' lengths). Safety checks are copied, never removed or moved:
//! each copy keeps its own, on the copied lines. Target-independent; Emit
//! runs it on the Sema thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const Index = InternPool.Index;
const Ir = @import("../Ir.zig");
const Inst = Ir.Inst;
const Ssa = @import("Ssa.zig");
const inline_ir = @import("inline.zig");

/// The most iterations a loop is unrolled for.
pub const max_trips = 8;
/// The most instructions all copies of a body have together.
pub const max_copied = 256;

/// A loop to unroll:
///   %outer = block(void, { %loop = loop(noreturn, {
///     %i = load(%ctr)
///     %cont = block(void, {
///       %c = cmp_lt(%i, <N>)
///       cond_br(%c, { body..., br(%cont) }, { br(%outer) })
///     })
///     %next = add_wrap(%i, <1>)
///     store(%ctr, %next)
///     repeat(%loop)
///   }) })
/// with `store(%ctr, <start>)` before `%outer` in the same body and no
/// other use of `%ctr`.
const Loop = struct {
    outer: Inst.Index,
    counter: Inst.Index,
    cont: Inst.Index,
    /// The body, in `extra`.
    body_start: usize,
    body_len: u32,
    start: u64,
    trips: u32,
    /// The body is a byte swap (`std.mem.swap`): done in words instead.
    swap: ?Swap = null,
};

/// `std.mem.swap`'s loop over two constant-length byte slices of its
/// `*T`s, unrolled:
///   %ea = slice_elem_ptr(%sa, %i); %eb = slice_elem_ptr(%sb, %i)
///   %x = load(u8, %ea); %y = load(u8, %eb); store(%ea, %y); store(%eb, %x)
/// moves `chunk`-byte words instead of bytes, `chunks` of them in order.
/// Both slices start `chunk`-aligned, so the loop's byte swaps within one
/// word touch distinct residues mod `chunk` and commute, and a word of
/// `a` and one of `b` either coincide or are disjoint: swapping a word at
/// once is swapping its bytes in turn, even when `*a` and `*b` overlap.
const Swap = struct {
    /// The slices' `[*]u8` pointers.
    a: Inst.Ref,
    b: Inst.Ref,
    ea: Inst.Index,
    chunk_ty: Index,
    chunks: u32,
};

/// Unrolls the loops that qualify; returns how many.
pub fn run(gpa: Allocator, ip: *InternPool, tid: InternPool.Tid, ir: *Ir) Allocator.Error!u32 {
    const tags = ir.instructions.items(.tag);
    if (std.mem.findScalar(Inst.Tag, tags, .loop) == null) return 0;
    const uses = try gpa.alloc(u32, ir.instructions.len);
    defer gpa.free(uses);
    @memset(uses, 0);
    for (0..ir.instructions.len) |i| Ssa.forEachOperand(ir, @fromBackingInt(@intCast(i)), Counter{ .uses = uses });

    var loops: std.ArrayList(Loop) = .empty;
    defer loops.deinit(gpa);
    var f: Finder = .{ .gpa = gpa, .ip = ip, .ir = ir, .uses = uses, .loops = &loops };
    try f.body(ir.mainBody());
    if (loops.items.len == 0) return 0;

    // The copies read the IR as it was: `from` is a copy of it, since the
    // arrays grow as the copies go in.
    var from_list = try ir.instructions.toMultiArrayList().clone(gpa);
    defer from_list.deinit(gpa);
    const from_extra = try gpa.dupe(u32, ir.extra);
    defer gpa.free(from_extra);
    var from = ir.*;
    from.instructions = from_list.slice();
    from.extra = from_extra;

    var insts = ir.instructions.toMultiArrayList();
    var extra: std.ArrayList(u32) = .fromOwnedSlice(@constCast(ir.extra));
    errdefer {
        ir.instructions = insts.slice();
        ir.extra = extra.allocatedSlice();
    }
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    var copied: std.ArrayList(Inst.Index) = .empty;
    defer copied.deinit(gpa);
    for (loops.items) |l| {
        const body = from.bodySlice(l.body_start, l.body_len);
        if (l.swap) |sw| {
            try swapWords(gpa, ip, tid, &from, &insts, &extra, l, sw, body);
            continue;
        }
        copied.clearRetainingCapacity();
        try collect(gpa, &from, body, &copied);
        const ty = from.instructions.items(.data)[@backingInt(l.counter)].ty;
        const counter_ty = ip.keyPayload(.ptr_type, ty).child;
        const load = loadOf(&from, l);
        const outer_body = try gpa.alloc(u32, l.trips + 1);
        defer gpa.free(outer_body);
        for (0..l.trips) |k| {
            map.clearRetainingCapacity();
            const cont: u32 = @intCast(insts.len);
            try insts.append(gpa, .{ .tag = .unreach, .data = .{ .no_op = {} } });
            try map.put(gpa, @backingInt(l.cont), cont);
            for (copied.items) |i| {
                try map.put(gpa, @backingInt(i), @intCast(insts.len));
                try insts.append(gpa, .{ .tag = .unreach, .data = .{ .no_op = {} } });
            }
            var c: inline_ir.Copier = .{
                .gpa = gpa,
                .from = &from,
                .insts = &insts,
                .extra = &extra,
                .map = &map,
                .subst_from = load,
                .subst_to = .fromInterned(try ip.getInt(tid, counter_ty, l.start + k)),
            };
            const payload: u32 = @intCast(extra.items.len);
            try extra.append(gpa, l.body_len);
            try c.bodyIndices(body);
            try c.body(body);
            insts.set(cont, .{ .tag = .block, .data = .{ .ty_pl = .{ .ty = .void_type, .payload = payload } } });
            outer_body[k] = cont;
        }
        const exit: u32 = @intCast(insts.len);
        try insts.append(gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = l.outer, .operand = .void_value } } });
        outer_body[l.trips] = exit;
        const payload: u32 = @intCast(extra.items.len);
        try extra.append(gpa, l.trips + 1);
        try extra.appendSlice(gpa, outer_body);
        insts.items(.data)[@backingInt(l.outer)].ty_pl.payload = payload;
    }
    ir.extra = try extra.toOwnedSlice(gpa);
    ir.instructions = insts.slice();
    return @intCast(loops.items.len);
}

/// Replaces the body of swap loop `l`'s outer block with `sw.chunks`
/// copies of `body` on words: the same instructions on the same lines.
fn swapWords(gpa: Allocator, ip: *InternPool, tid: InternPool.Tid, from: *const Ir, insts: *std.MultiArrayList(Inst), extra: *std.ArrayList(u32), l: Loop, sw: Swap, body: []const Inst.Index) Allocator.Error!void {
    const many = try ip.get(tid, .{ .ptr_type = .{ .child = sw.chunk_ty, .flags = .{ .size = .many } } });
    const one = try ip.get(tid, .{ .ptr_type = .{ .child = sw.chunk_ty } });
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    const pa = (@as(Inst.Index, @fromBackingInt(@intCast(insts.len)))).toRef();
    try insts.append(gpa, .{ .tag = .bitcast, .data = .{ .ty_op = .{ .ty = many, .operand = sw.a } } });
    const pb = (@as(Inst.Index, @fromBackingInt(@intCast(insts.len)))).toRef();
    try insts.append(gpa, .{ .tag = .bitcast, .data = .{ .ty_op = .{ .ty = many, .operand = sw.b } } });
    try out.appendSlice(gpa, &.{ @backingInt(pa.toIndex().?), @backingInt(pb.toIndex().?) });
    const datas = from.instructions.items(.data);
    for (0..sw.chunks) |m| {
        const index: Inst.Ref = .fromInterned(try ip.getInt(tid, .usize_type, m));
        // The body's instructions, in order, at their copies' indices.
        const base: u32 = @intCast(insts.len);
        const at = struct {
            fn at(b: []const Inst.Index, x: Inst.Ref, base_: u32) Inst.Ref {
                const k = std.mem.findScalar(Inst.Index, b, x.toIndex().?).?;
                return (@as(Inst.Index, @fromBackingInt(base_ + @as(u32, @intCast(k))))).toRef();
            }
        }.at;
        for (body) |i| {
            const d = datas[@backingInt(i)];
            const tag = from.instructions.items(.tag)[@backingInt(i)];
            // The loop's `br` to its next iteration, last: the copies
            // follow each other.
            if (tag == .br) break;
            try out.append(gpa, @intCast(insts.len));
            switch (tag) {
                .slice_elem_ptr => {
                    const payload: u32 = @intCast(extra.items.len);
                    try extra.appendSlice(gpa, &.{ @backingInt(if (i == sw.ea) pa else pb), @backingInt(index) });
                    try insts.append(gpa, .{ .tag = .ptr_elem_ptr, .data = .{ .ty_pl = .{ .ty = one, .payload = payload } } });
                },
                .load => try insts.append(gpa, .{ .tag = .load, .data = .{ .ty_op = .{ .ty = sw.chunk_ty, .operand = at(body, d.ty_op.operand, base) } } }),
                .store => try insts.append(gpa, .{ .tag = .store, .data = .{ .bin_op = .{ .lhs = at(body, d.bin_op.lhs, base), .rhs = at(body, d.bin_op.rhs, base) } } }),
                else => try insts.append(gpa, .{ .tag = tag, .data = d }),
            }
        }
    }
    try out.append(gpa, @intCast(insts.len));
    try insts.append(gpa, .{ .tag = .br, .data = .{ .br = .{ .block_inst = l.outer, .operand = .void_value } } });
    const payload: u32 = @intCast(extra.items.len);
    try extra.append(gpa, @intCast(out.items.len));
    try extra.appendSlice(gpa, out.items);
    insts.items(.data)[@backingInt(l.outer)].ty_pl.payload = payload;
}

const Counter = struct {
    uses: []u32,
    pub fn use(c: Counter, ref: Inst.Ref) void {
        if (ref.toIndex()) |i| c.uses[@backingInt(i)] += 1;
    }
};

/// The loop's `load` of its counter.
fn loadOf(ir: *const Ir, l: Loop) Inst.Index {
    const loop_inst = ir.bodySlice(ir.extraData(Ir.Block, ir.instructions.items(.data)[@backingInt(l.outer)].ty_pl.payload).end, 1)[0];
    const body = blockBody(ir, loop_inst);
    for (body) |i| if (ir.instructions.items(.tag)[@backingInt(i)] == .load) return i;
    unreachable;
}

fn blockBody(ir: *const Ir, inst: Inst.Index) []const Inst.Index {
    const x = ir.extraData(Ir.Block, ir.instructions.items(.data)[@backingInt(inst)].ty_pl.payload);
    return ir.bodySlice(x.end, x.data.body_len);
}

/// Every instruction in `body` and the bodies nested in it, into `out`.
fn collect(gpa: Allocator, ir: *const Ir, body: []const Inst.Index, out: *std.ArrayList(Inst.Index)) Allocator.Error!void {
    var it: Nested = .{ .gpa = gpa, .ir = ir, .out = out };
    try it.body(body);
}

const Nested = struct {
    ir: *const Ir,
    out: *std.ArrayList(Inst.Index),
    gpa: Allocator = undefined,
    count_only: bool = false,
    n: u32 = 0,
    ok: bool = true,

    fn body(it: *Nested, insts: []const Inst.Index) Allocator.Error!void {
        const ir = it.ir;
        for (insts) |inst| {
            const data = ir.instructions.items(.data)[@backingInt(inst)];
            const tag = ir.instructions.items(.tag)[@backingInt(inst)];
            if (it.count_only) it.n += 1 else try it.out.append(it.gpa, inst);
            switch (tag) {
                // `Copier` does not copy these.
                .ret_addr, .frame_addr, .err_return_trace, .set_err_return_trace, .assembly, .c_va_start, .c_va_arg, .c_va_copy, .arg => it.ok = false,
                .block, .loop => try it.body(blockBody(ir, inst)),
                .cond_br => {
                    const x = ir.extraData(Ir.CondBr, data.pl_op.payload);
                    try it.body(ir.bodySlice(x.end, x.data.then_body_len + x.data.else_body_len));
                },
                .switch_br => {
                    var cases = ir.switchCases(data.pl_op.payload);
                    while (cases.next()) |c| try it.body(c.body);
                    try it.body(cases.elseBody());
                },
                else => {},
            }
        }
    }
};

const Finder = struct {
    gpa: Allocator,
    ip: *const InternPool,
    ir: *const Ir,
    uses: []const u32,
    loops: *std.ArrayList(Loop),

    fn body(f: *Finder, insts: []const Inst.Index) Allocator.Error!void {
        const ir = f.ir;
        for (insts, 0..) |inst, k| {
            const data = ir.instructions.items(.data)[@backingInt(inst)];
            switch (ir.instructions.items(.tag)[@backingInt(inst)]) {
                .block => {
                    if (f.match(insts[0..k], inst)) |l| {
                        try f.loops.append(f.gpa, l);
                        continue;
                    }
                    try f.body(blockBody(ir, inst));
                },
                .loop => try f.body(blockBody(ir, inst)),
                .cond_br => {
                    const x = ir.extraData(Ir.CondBr, data.pl_op.payload);
                    try f.body(ir.bodySlice(x.end, x.data.then_body_len));
                    try f.body(ir.bodySlice(x.end + x.data.then_body_len, x.data.else_body_len));
                },
                .switch_br => {
                    var cases = ir.switchCases(data.pl_op.payload);
                    while (cases.next()) |c| try f.body(c.body);
                    try f.body(cases.elseBody());
                },
                else => {},
            }
        }
    }

    /// `outer` as a loop to unroll, with the instructions before it in its
    /// body.
    fn match(f: *Finder, before: []const Inst.Index, outer: Inst.Index) ?Loop {
        const ir = f.ir;
        const tags = ir.instructions.items(.tag);
        const datas = ir.instructions.items(.data);
        if (datas[@backingInt(outer)].ty_pl.ty != .void_type) return null;
        const ob = blockBody(ir, outer);
        if (ob.len != 1 or tags[@backingInt(ob[0])] != .loop) return null;
        const lb = (blockBody(ir, ob[0]));
        if (lb.len != 5) return null;
        // %i = load(%ctr)
        if (tags[@backingInt(lb[0])] != .load) return null;
        const load = lb[0];
        const counter = datas[@backingInt(load)].ty_op.operand.toIndex() orelse return null;
        if (tags[@backingInt(counter)] != .alloc) return null;
        const counter_ty = datas[@backingInt(load)].ty_op.ty;
        if (counter_ty != .usize_type) return null;
        // %cont = block(void, { cmp_lt; cond_br })
        const cont = lb[1];
        if (tags[@backingInt(cont)] != .block or datas[@backingInt(cont)].ty_pl.ty != .void_type) return null;
        const cb = (blockBody(ir, cont));
        if (cb.len != 2 or tags[@backingInt(cb[0])] != .cmp_lt or tags[@backingInt(cb[1])] != .cond_br) return null;
        const cmp = datas[@backingInt(cb[0])].bin_op;
        if (cmp.lhs != load.toRef()) return null;
        const end = f.int(cmp.rhs) orelse f.constLen(cmp.rhs) orelse return null;
        const br = datas[@backingInt(cb[1])].pl_op;
        if (br.operand != cb[0].toRef() or f.uses[@backingInt(cb[0])] != 1) return null;
        const x = ir.extraData(Ir.CondBr, br.payload);
        const then_body = ir.bodySlice(x.end, x.data.then_body_len);
        const else_body = (ir.bodySlice(x.end + then_body.len, x.data.else_body_len));
        if (else_body.len != 1 or tags[@backingInt(else_body[0])] != .br) return null;
        if (datas[@backingInt(else_body[0])].br.block_inst != outer) return null;
        // %next = add_wrap(%i, <1>); store(%ctr, %next); repeat(%loop)
        if (tags[@backingInt(lb[2])] != .add_wrap) return null;
        const add = datas[@backingInt(lb[2])].bin_op;
        if (add.lhs != load.toRef() or (f.int(add.rhs) orelse return null) != 1) return null;
        if (tags[@backingInt(lb[3])] != .store) return null;
        const step = datas[@backingInt(lb[3])].bin_op;
        if (step.lhs != counter.toRef() or step.rhs != lb[2].toRef()) return null;
        if (tags[@backingInt(lb[4])] != .repeat) return null;
        // store(%ctr, <start>) before the loop; the counter's only other
        // uses are the loop's load and step.
        if (f.uses[@backingInt(counter)] != 3) return null;
        const start = for (0..before.len) |j| {
            const s = before[before.len - 1 - j];
            if (tags[@backingInt(s)] != .store or datas[@backingInt(s)].bin_op.lhs != counter.toRef()) continue;
            break f.int(datas[@backingInt(s)].bin_op.rhs) orelse return null;
        } else return null;
        if (start >= end) return null;
        if (start == 0) if (f.swapOf(then_body, load, cont, end)) |sw|
            return .{ .outer = outer, .counter = counter, .cont = cont, .body_start = x.end, .body_len = x.data.then_body_len, .start = 0, .trips = 0, .swap = sw };
        if (end - start > max_trips) return null;
        const trips: u32 = @intCast(end - start);
        var n: Nested = .{ .ir = ir, .out = undefined, .count_only = true };
        n.body(then_body) catch unreachable;
        if (!n.ok or n.n * trips > max_copied) return null;
        return .{ .outer = outer, .counter = counter, .cont = cont, .body_start = x.end, .body_len = x.data.then_body_len, .start = start, .trips = trips };
    }

    /// The length of a slice that is a constant: `std.mem.swap`'s
    /// `@ptrCast` of a `*T` to `[]u8`, which Sema keeps in a `const`
    /// local, so a `for` over it reloads its length.
    fn constLen(f: *const Finder, ref: Inst.Ref) ?u64 {
        const ir = f.ir;
        const tags = ir.instructions.items(.tag);
        const datas = ir.instructions.items(.data);
        const i = @backingInt(ref.toIndex() orelse return null);
        if (tags[i] != .slice_len) return null;
        const s = f.sliceValue(datas[i].ty_op.operand) orelse return null;
        if (s.toInterned()) |v| {
            if (f.ip.keyTag(v) != .slice) return null;
            return f.int(.fromInterned(f.ip.keyPayload(.slice, v).len));
        }
        const si = @backingInt(s.toIndex().?);
        if (tags[si] != .slice) return null;
        return f.int(ir.extraData(Ir.Bin, datas[si].ty_pl.payload).data.rhs);
    }

    /// The slice `s` is: through a `const` local stored once, as Sema keeps
    /// `std.mem.swap`'s.
    fn sliceValue(f: *const Finder, ref: Inst.Ref) ?Inst.Ref {
        const tags = f.ir.instructions.items(.tag);
        const datas = f.ir.instructions.items(.data);
        var s = ref;
        if (s.toIndex()) |l| if (tags[@backingInt(l)] == .load) {
            // A `const` local stored once.
            const a = datas[@backingInt(l)].ty_op.operand.toIndex() orelse return null;
            if (tags[@backingInt(a)] != .alloc or datas[@backingInt(a)].ty == .none or !f.ip.keyPayload(.ptr_type, datas[@backingInt(a)].ty).flags.is_const) return null;
            var stored: ?Inst.Ref = null;
            for (tags, datas) |tag, data| {
                if (tag != .store or data.bin_op.lhs != a.toRef()) continue;
                if (stored != null) return null;
                stored = data.bin_op.rhs;
            }
            s = stored orelse return null;
        };
        return s;
    }

    /// The swap `then_body` (a loop's over `[0, n)`, counter `load`, next
    /// iteration `cont`) does, if it is the byte swap `Swap` describes.
    fn swapOf(f: *const Finder, then_body: []const Inst.Index, load: Inst.Index, cont: Inst.Index, n: u64) ?Swap {
        const tags = f.ir.instructions.items(.tag);
        const datas = f.ir.instructions.items(.data);
        var ops: [7]Inst.Index = undefined;
        var len: usize = 0;
        for (then_body) |i| {
            if (tags[@backingInt(i)] == .dbg_stmt) continue;
            if (len == ops.len) return null;
            ops[len] = i;
            len += 1;
        }
        if (len != ops.len) return null;
        const want = [_]Inst.Tag{ .slice_elem_ptr, .slice_elem_ptr, .load, .load, .store, .store, .br };
        for (ops, want) |i, t| if (tags[@backingInt(i)] != t) return null;
        const ea, const eb, const x, const y, const st_a, const st_b, const br = ops;
        if (datas[@backingInt(x)].ty_op.ty != .u8_type or datas[@backingInt(x)].ty_op.operand != ea.toRef()) return null;
        if (datas[@backingInt(y)].ty_op.ty != .u8_type or datas[@backingInt(y)].ty_op.operand != eb.toRef()) return null;
        if (datas[@backingInt(st_a)].bin_op.lhs != ea.toRef() or datas[@backingInt(st_a)].bin_op.rhs != y.toRef()) return null;
        if (datas[@backingInt(st_b)].bin_op.lhs != eb.toRef() or datas[@backingInt(st_b)].bin_op.rhs != x.toRef()) return null;
        if (datas[@backingInt(br)].br.block_inst != cont) return null;
        var parts: [2]struct { ptr: Inst.Ref, alignment: u64 } = undefined;
        for ([_]Inst.Index{ ea, eb }, &parts) |e, *part| {
            const bin = f.ir.extraData(Ir.Bin, datas[@backingInt(e)].ty_pl.payload).data;
            if (bin.rhs != load.toRef()) return null;
            const s = (f.sliceValue(bin.lhs) orelse return null).toIndex() orelse return null;
            if (tags[@backingInt(s)] != .slice) return null;
            const sl = f.ir.extraData(Ir.Bin, datas[@backingInt(s)].ty_pl.payload).data;
            if ((f.int(sl.rhs) orelse return null) != n) return null;
            const pt = f.ip.keyPayload(.ptr_type, datas[@backingInt(s)].ty_pl.ty);
            if (pt.child != .u8_type or pt.flags.is_volatile or pt.flags.address_space != .generic or pt.packed_offset.host_size != 0) return null;
            part.* = .{ .ptr = sl.lhs, .alignment = if (pt.flags.alignment == 0) 1 else @as(u64, 1) << @intCast(pt.flags.alignment - 1) };
        }
        // The widest word both slices align that divides `n`.
        const chunk = @min(8, parts[0].alignment, parts[1].alignment, n & -%n);
        if (chunk < 2 or n / chunk > max_trips) return null;
        return .{
            .a = parts[0].ptr,
            .b = parts[1].ptr,
            .ea = ea,
            .chunk_ty = switch (chunk) {
                2 => .u16_type,
                4 => .u32_type,
                else => .u64_type,
            },
            .chunks = @intCast(n / chunk),
        };
    }

    fn int(f: *const Finder, ref: Inst.Ref) ?u64 {
        const v = ref.toInterned() orelse return null;
        if (f.ip.keyTag(v) != .int) return null;
        return f.ip.intValue(u64, v);
    }
};
