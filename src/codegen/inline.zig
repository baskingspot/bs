//! Inlining within a budget (docs/slop/architecture.md): which calls of a
//! function's IR are candidates, whether the function can itself be
//! inlined, and splicing callee bodies into a caller's IR in the shape
//! Sema gives inline calls. Target-independent; Emit schedules it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const Index = InternPool.Index;
const Ir = @import("../Ir.zig");
const Inst = Ir.Inst;
const Type = @import("../Type.zig");
const Zcu = @import("../Zcu.zig");
const Incremental = @import("../Incremental.zig");
const Zir = std.zig.Zir;

/// The most instructions with hot code (`Scan.size`) a body inlined at a
/// call outside loops has, after its own callees are inlined.
pub const budget = 24;
/// A call inside a loop inlines callees up to this many times the budget:
/// its cost is paid once per iteration, the code once.
pub const loop_factor = 2;
/// A callee without loops, at a call inside a loop inside a loop, which
/// runs the most often: tls's Montgomery multiplication calls
/// `ct_protected.mulWide` (size 63, whose checks prove then removes) in
/// its inner loop. A callee's own loop would add its registers to the
/// caller's hottest code (sort's `blockSwap` in `block`: +0.9%).
pub const nested_loop_factor = 3;

/// How many times the budget a callee of a call `loops` loops deep may
/// have; `straight` is whether the callee has no loop.
pub fn factor(loops: u32, straight: bool) u32 {
    return switch (loops) {
        0 => 1,
        1 => loop_factor,
        else => if (straight) nested_loop_factor else loop_factor,
    };
}
/// Elements an `aggregate_init` may have and still count as one
/// instruction: a struct literal sroa splits into registers, or a short
/// array.
const small_aggregate = 8;

/// A call that may be inlined: a direct call of an `.auto` function, not
/// `never_inline`, outside cold code. `line:column` is the call's statement
/// position.
pub const Site = struct {
    call: Inst.Index,
    /// How many `loop`s of the caller it is inside (`factor`).
    loops: u32,
    callee: Index,
    line: u32,
    column: u32,
};

pub const Scan = struct {
    /// Instructions with code outside cold bodies (those ending in
    /// `unreach` or `trap`: safety checks, `unreachable`), but for the
    /// ones `Scanner.free` leaves out.
    size: u32 = 0,
    /// Whether the function could be spliced into a caller once its
    /// candidate calls are inlined: an `.auto`, non-`noinline` function
    /// whose IR uses only instructions `splice` maps, and that calls
    /// nothing else but cold `noreturn` functions and `returnError`.
    inlinable: bool = true,
    /// Whether the function can start a panic: it calls a cold `noreturn`
    /// function (a safety check's handler, `unreachable`, `@panic`) or
    /// traps. A panic in inlined code loses its callers' frames from the
    /// stack trace.
    panics: bool = false,
    /// Whether the function has no `loop` (`nested_loop_factor`).
    straight: bool = true,
};

/// Finds the candidate calls of `ir` (into `sites`, in IR order) and
/// whether `ir`'s function could be inlined.
pub fn scan(gpa: Allocator, zcu: *const Zcu, ir: *const Ir, sites: *std.ArrayList(Site)) Allocator.Error!Scan {
    const start = sites.items.len;
    var s: Scanner = .{ .gpa = gpa, .ip = &zcu.ip, .ir = ir, .sites = sites, .return_error = zcu.return_error };
    s.out.inlinable = selfInlinable(zcu, ir.func);
    try s.body(ir.mainBody(), false);
    if (sites.items.len != start) {
        // A recursive call stays a call.
        var i = start;
        for (sites.items[start..]) |site| {
            if (site.callee == ir.func) {
                s.out.inlinable = false;
            } else {
                sites.items[i] = site;
                i += 1;
            }
        }
        sites.shrinkRetainingCapacity(i);
    }
    return s.out;
}

/// The callee-side rules that do not depend on the body.
fn selfInlinable(zcu: *const Zcu, func: Index) bool {
    const ip = &zcu.ip;
    const f = ip.keyPayload(.func, func);
    const fn_ty = ip.keyPayload(.func_type, f.ty);
    if (fn_ty.cc != .auto or fn_ty.is_var_args) return false;
    // A call's result type names the callee's inferred error set, its
    // `ret`s the function's own; keep those calls.
    if (ip.keyTag(fn_ty.return_type) == .error_union_type and
        ip.keyPayload(.error_union_type, fn_ty.return_type).error_set_type == .adhoc_inferred_error_set_type) return false;
    const owner = ip.getNav(f.owner_nav);
    const zir = &zcu.file(owner.file).zir;
    if (zir.instructions.items(.tag)[@backingInt(f.zir_inst)] == .func_fancy) {
        const data = zir.instructions.items(.data)[@backingInt(f.zir_inst)];
        if (zir.extraData(Zir.Inst.FuncFancy, data.pl_node.payload_index).data.bits.is_noinline) return false;
    }
    return true;
}

const Scanner = struct {
    gpa: Allocator,
    ip: *const InternPool,
    ir: *const Ir,
    sites: *std.ArrayList(Site),
    /// `Zcu.return_error`.
    return_error: Index,
    out: Scan = .{},
    /// `loop`s the scan is inside.
    loops: u32 = 0,
    line: u32 = 0,
    column: u32 = 0,

    fn body(s: *Scanner, insts: []const Inst.Index, cold: bool) Allocator.Error!void {
        const ir = s.ir;
        const tags = ir.instructions.items(.tag);
        const datas = ir.instructions.items(.data);
        for (insts) |inst| {
            const data = datas[@backingInt(inst)];
            const tag = tags[@backingInt(inst)];
            switch (tag) {
                .dbg_stmt => {
                    s.line = data.dbg_stmt.line;
                    s.column = data.dbg_stmt.column;
                    continue;
                },
                .arg, .dbg_inline_begin, .dbg_inline_end => continue,
                .save_err_return_trace_index => if (data.ty_pl.ty == .none) continue else {
                    s.out.inlinable = false;
                },
                .ret_addr, .frame_addr, .err_return_trace, .set_err_return_trace, .assembly, .c_va_start, .c_va_arg, .c_va_copy => s.out.inlinable = false,
                .comptime_tick, .comptime_quota, .comptime_dep, .comptime_effect, .comptime_exit => unreachable,
                .block, .loop => {
                    const extra = ir.extraData(Ir.Block, data.ty_pl.payload);
                    const loop = tag == .loop;
                    s.loops += @intFromBool(loop);
                    if (loop) s.out.straight = false;
                    try s.body(ir.bodySlice(extra.end, extra.data.body_len), cold);
                    s.loops -= @intFromBool(loop);
                },
                .cond_br => {
                    const extra = ir.extraData(Ir.CondBr, data.pl_op.payload);
                    const then_body = ir.bodySlice(extra.end, extra.data.then_body_len);
                    const else_body = ir.bodySlice(extra.end + then_body.len, extra.data.else_body_len);
                    try s.body(then_body, cold or isCold(ir, then_body));
                    try s.body(else_body, cold or isCold(ir, else_body));
                },
                .switch_br => {
                    var it = ir.switchCases(data.pl_op.payload);
                    while (it.next()) |c| try s.body(c.body, cold or isCold(ir, c.body));
                    try s.body(it.elseBody(), cold or isCold(ir, it.elseBody()));
                },
                .call => try s.call(inst, cold),
                // A big array literal or `@splat` has an operand per element
                // (`std.mem.zeroes` of a 1 MiB array has a million), and
                // copying and rewriting it costs as much in every caller.
                .aggregate_init => if (!cold) {
                    const len = ir.extraData(Ir.Aggregate, data.ty_pl.payload).data.len;
                    if (len > small_aggregate) s.out.size +|= len;
                },
                // A trap has no return address for synthetic frames.
                .trap => {
                    s.out.panics = true;
                    s.out.inlinable = false;
                },
                else => {},
            }
            if (!cold and !s.free(tag, data)) s.out.size += 1;
        }
    }

    /// Whether the size leaves an instruction out: `block`s and their
    /// `br`s, which labeled blocks, switches and inline calls add and
    /// which mostly emit no code, and a field of an overflow operation's
    /// result, which reads one of its two registers. With them counted,
    /// leaves such as `std.fmt.digitToChar` measured over the budget on
    /// code that prove mostly removes. Likewise `ret`s, pointer casts and
    /// the slots of `const` locals and parameters, which made accessors
    /// such as `Ast.tokenTag` measure 34.
    fn free(s: *const Scanner, tag: Inst.Tag, data: Inst.Data) bool {
        const ir = s.ir;
        return switch (tag) {
            .block, .br => true,
            // A `ret` becomes a `br` out of the inlined block.
            .ret => true,
            // A `const` local or parameter's slot, which Sema writes once
            // and the SSA promotes to a register.
            .alloc => s.constSlot(data.ty),
            .store => if (data.bin_op.lhs.toIndex()) |p| s.isConstSlot(p) else false,
            .load => if (data.ty_op.operand.toIndex()) |p| s.isConstSlot(p) else false,
            .bitcast => s.ip.keyTag(data.ty_op.ty) == .ptr_type,
            .struct_field_val => {
                const op = ir.extraData(Ir.StructField, data.ty_pl.payload).data.operand.toIndex() orelse return false;
                return switch (ir.instructions.items(.tag)[@backingInt(op)]) {
                    .add_with_overflow, .sub_with_overflow, .mul_with_overflow => true,
                    else => false,
                };
            },
            else => false,
        };
    }

    fn constSlot(s: *const Scanner, ptr_ty: Index) bool {
        // `.none`: an inferred alloc Sema left unused.
        return ptr_ty == .none or s.ip.keyPayload(.ptr_type, ptr_ty).flags.is_const;
    }

    fn isConstSlot(s: *const Scanner, inst: Inst.Index) bool {
        const i = @backingInt(inst);
        return s.ir.instructions.items(.tag)[i] == .alloc and s.constSlot(s.ir.instructions.items(.data)[i].ty);
    }

    fn call(s: *Scanner, inst: Inst.Index, cold: bool) Allocator.Error!void {
        const ip = s.ip;
        const data = s.ir.instructions.items(.data)[@backingInt(inst)].pl_op;
        const extra = s.ir.extraData(Ir.Call, data.payload).data;
        if (extra.ret_ty == .noreturn_type) {
            s.out.panics = true;
            return;
        }
        const callee = data.operand.toInterned() orelse {
            s.out.inlinable = false;
            return;
        };
        // An error return trace's push stays a call and does not keep its
        // caller from inlining: the address it records is in the inlined
        // copy, which maps to the callee's line and name as before
        // (docs/slop/architecture.md, "What users see"), and nothing
        // unwinds through it.
        if (callee == s.return_error) return;
        if (cold or extra.flags.never_inline or ip.keyTag(callee) != .func or
            ip.keyPayload(.func_type, ip.typeOf(callee)).cc != .auto)
        {
            s.out.inlinable = false;
            return;
        }
        try s.sites.append(s.gpa, .{ .call = inst, .loops = s.loops, .callee = callee, .line = s.line, .column = s.column });
    }
};

/// Whether a body is cold code: a safety check's failure or `unreachable`.
fn isCold(ir: *const Ir, body: []const Inst.Index) bool {
    if (body.len == 0) return false;
    return switch (ir.instructions.items(.tag)[@backingInt(body[body.len - 1])]) {
        .unreach, .trap => true,
        else => false,
    };
}

/// A call to replace with the inlinable `body` of its callee.
pub const Splice = struct {
    site: Site,
    body: *const Ir,
};

/// Returns `ir` with each of `splices` (in IR order) inlined: the call
/// becomes a `block` of the call's type holding the callee's body, its
/// `arg`s replaced by the call's arguments and its `ret`s by `br`s out of
/// the block, between `dbg_inline_begin` and `dbg_inline_end`, as Sema
/// emits an inline call. The caller's instructions keep their indices.
/// Grows `ir`'s arrays in place.
pub fn splice(gpa: Allocator, ir: *Ir, splices: []const Splice) Allocator.Error!void {
    var insts = ir.instructions.toMultiArrayList();
    var extra: std.ArrayList(u32) = .fromOwnedSlice(@constCast(ir.extra));
    var args: std.ArrayList(Inst.Ref) = .empty;
    defer args.deinit(gpa);
    errdefer {
        ir.instructions = insts.slice();
        ir.extra = extra.allocatedSlice();
    }
    var total: usize = 0;
    for (splices) |sp| total += sp.body.instructions.len + 2;
    try insts.ensureTotalCapacity(gpa, insts.len + total);
    for (splices) |sp| {
        const callee = sp.body;
        const base: u32 = @intCast(insts.len);
        const n: u32 = @intCast(callee.instructions.len);
        insts.len += n + 2;
        // The callee's `arg`s and the instructions in no body stay unused.
        @memset(insts.items(.tag)[base..], .unreach);
        @memset(insts.items(.data)[base..], .{ .no_op = {} });
        const call_payload = insts.items(.data)[@backingInt(sp.site.call)].pl_op.payload;
        const call: Ir.Call = .{ .ret_ty = @fromBackingInt(extra.items[call_payload]), .args_len = extra.items[call_payload + 1] };
        const args_start = call_payload + @typeInfo(Ir.Call).@"struct".field_names.len;
        args.clearRetainingCapacity();
        try args.appendSlice(gpa, @ptrCast(extra.items[args_start..][0..call.args_len]));
        var c: Copier = .{
            .gpa = gpa,
            .from = callee,
            .insts = &insts,
            .extra = &extra,
            .base = base,
            .args = args.items,
            .block = sp.site.call,
        };
        const main = callee.mainBody();
        try c.body(main);
        const begin: Inst.Index = @fromBackingInt(base + n);
        const end: Inst.Index = @fromBackingInt(base + n + 1);
        const pos: u32 = @intCast(extra.items.len);
        try extra.appendSlice(gpa, &.{ sp.site.line, sp.site.column, @bitCast(Ir.DbgInline.Flags{ .backend = true }) });
        insts.set(@backingInt(begin), .{ .tag = .dbg_inline_begin, .data = .{ .dbg_inline = .{ .func = sp.site.callee, .payload = pos } } });
        insts.set(@backingInt(end), .{ .tag = .dbg_inline_end, .data = .{ .no_op = {} } });
        const payload: u32 = @intCast(extra.items.len);
        try extra.append(gpa, 0);
        try extra.append(gpa, @backingInt(begin));
        var len: u32 = 1;
        const tags = callee.instructions.items(.tag);
        for (main, 0..) |inst, i| {
            if (tags[@backingInt(inst)] == .arg) continue;
            // As `Sema.endDbgInline`: before the body's final terminator.
            if (i == main.len - 1) {
                try extra.append(gpa, @backingInt(end));
                len += 1;
            }
            try extra.append(gpa, base + @backingInt(inst));
            len += 1;
        }
        extra.items[payload] = len;
        insts.set(@backingInt(sp.site.call), .{ .tag = .block, .data = .{ .ty_pl = .{ .ty = call.ret_ty, .payload = payload } } });
    }
    ir.extra = try extra.toOwnedSlice(gpa);
    ir.instructions = insts.slice();
}

/// Copies a callee's instructions to `base +` their index in the caller
/// (splicing), or a body of a function into the same function, each
/// instruction to its index in `map` (`unroll.zig`).
pub const Copier = struct {
    gpa: Allocator,
    from: *const Ir,
    insts: *std.MultiArrayList(Inst),
    extra: *std.ArrayList(u32),
    base: u32 = 0,
    /// Copying within a function: the new index of each copied
    /// instruction. Others keep theirs.
    map: ?*const std.AutoHashMapUnmanaged(u32, u32) = null,
    args: []const Inst.Ref = &.{},
    /// Splicing: the call, now the block the callee's `ret`s exit. Copying
    /// within a function keeps `ret`s.
    block: ?Inst.Index = null,
    /// An instruction whose uses read `subst_to` in the copy (a loop
    /// counter's load, the iteration's constant).
    subst_from: ?Inst.Index = null,
    subst_to: Inst.Ref = .none,

    fn ref(c: *const Copier, r: Inst.Ref) Inst.Ref {
        if (r == .none) return r;
        const i = r.toIndex() orelse return r;
        if (c.subst_from == i) return c.subst_to;
        if (c.map != null) return c.index(i).toRef();
        const data = c.from.instructions.items(.data)[@backingInt(i)];
        if (c.from.instructions.items(.tag)[@backingInt(i)] == .arg) return c.args[data.arg.index];
        return c.index(i).toRef();
    }

    fn index(c: *const Copier, i: Inst.Index) Inst.Index {
        if (c.map) |m| return if (m.get(@backingInt(i))) |n| @fromBackingInt(n) else i;
        return @fromBackingInt(c.base + @backingInt(i));
    }

    /// Copies payload `T` at `at`, mapping its `Ref`s; returns where.
    fn payload(c: *Copier, comptime T: type, at: u32) Allocator.Error!u32 {
        const pos: u32 = @intCast(c.extra.items.len);
        const info = @typeInfo(T).@"struct";
        inline for (info.field_types, 0..) |Field, k| {
            const word = c.from.extra[at + k];
            try c.extra.append(c.gpa, if (Field == Inst.Ref) @backingInt(c.ref(@fromBackingInt(word))) else word);
        }
        return pos;
    }

    pub fn bodyIndices(c: *Copier, body_insts: []const Inst.Index) Allocator.Error!void {
        for (body_insts) |i| try c.extra.append(c.gpa, @backingInt(c.index(i)));
    }

    fn refs(c: *Copier, list: []const Inst.Ref) Allocator.Error!void {
        for (list) |r| try c.extra.append(c.gpa, @backingInt(c.ref(r)));
    }

    pub fn body(c: *Copier, body_insts: []const Inst.Index) Allocator.Error!void {
        for (body_insts) |i| try c.inst(i);
    }

    fn inst(c: *Copier, i: Inst.Index) Allocator.Error!void {
        const from = c.from;
        var data = from.instructions.items(.data)[@backingInt(i)];
        var tag = from.instructions.items(.tag)[@backingInt(i)];
        switch (tag) {
            .arg => return,
            .alloc, .dbg_stmt, .dbg_inline_end, .extern_ptr, .extern_pcrel, .extern_tls, .tls_ptr, .save_err_return_trace_index, .unreach, .trap, .breakpoint => {},
            .ret_addr, .frame_addr, .err_return_trace, .set_err_return_trace, .assembly, .c_va_start, .c_va_arg, .c_va_copy => unreachable,
            .comptime_tick, .comptime_quota, .comptime_dep, .comptime_effect, .comptime_exit => unreachable,
            .dbg_inline_begin => data.dbg_inline.payload = try c.payload(Ir.DbgInline, data.dbg_inline.payload),
            .ret => if (c.block) |b| {
                tag = .br;
                const operand = c.ref(data.un_op);
                data = .{ .br = .{ .block_inst = b, .operand = operand } };
            } else {
                data.un_op = c.ref(data.un_op);
            },
            .br => {
                const operand = c.ref(data.br.operand);
                data.br = .{ .block_inst = c.index(data.br.block_inst), .operand = operand };
            },
            .repeat => data.repeat.loop_inst = c.index(data.repeat.loop_inst),
            .error_name, .cmp_lt_errors_len, .int_from_bool, .int_from_ptr, .is_null, .is_non_null, .is_err, .is_non_err => data.un_op = c.ref(data.un_op),
            .neg_float, .sqrt, .sin, .cos, .tan, .exp, .exp2, .log, .log2, .log10, .abs_float, .floor, .ceil, .round, .trunc_float => data.un_op = c.ref(data.un_op),
            .load, .not, .intcast, .trunc, .float_cast, .float_from_int, .int_from_float, .bitcast, .clz, .ctz, .popcount, .byte_swap, .bit_reverse => data.ty_op.operand = c.ref(data.ty_op.operand),
            .ptr_from_int, .atomic_load, .slice_ptr, .slice_len, .optional_payload, .optional_payload_ptr, .optional_payload_ptr_set, .wrap_optional => data.ty_op.operand = c.ref(data.ty_op.operand),
            .unwrap_errunion_payload, .unwrap_errunion_err, .unwrap_errunion_payload_ptr, .unwrap_errunion_err_ptr, .errunion_payload_ptr_set => data.ty_op.operand = c.ref(data.ty_op.operand),
            .wrap_errunion_payload, .wrap_errunion_err, .get_union_tag, .tag_name => data.ty_op.operand = c.ref(data.ty_op.operand),
            .store, .add_wrap, .sub_wrap, .mul_wrap, .add_float, .sub_float, .mul_float, .div_float, .div_trunc, .div_floor, .div_ceil, .rem, .mod => data.bin_op = .{ .lhs = c.ref(data.bin_op.lhs), .rhs = c.ref(data.bin_op.rhs) },
            .min_float, .max_float, .min_int, .max_int, .bit_and, .bit_or, .xor, .shl, .shr, .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => data.bin_op = .{ .lhs = c.ref(data.bin_op.lhs), .rhs = c.ref(data.bin_op.rhs) },
            .atomic_store, .ptr_elem_val, .slice_elem_val, .array_elem_val, .set_union_tag, .memcpy, .memmove, .memset => data.bin_op = .{ .lhs = c.ref(data.bin_op.lhs), .rhs = c.ref(data.bin_op.rhs) },
            .add_with_overflow, .sub_with_overflow, .mul_with_overflow, .ptr_elem_ptr, .slice_elem_ptr, .slice, .ptr_add => data.ty_pl.payload = try c.payload(Ir.Bin, data.ty_pl.payload),
            .mul_add, .vector_store_elem => data.pl_op = .{ .operand = c.ref(data.pl_op.operand), .payload = try c.payload(Ir.Bin, data.pl_op.payload) },
            .struct_field_ptr, .struct_field_val, .union_init => data.ty_pl.payload = try c.payload(Ir.StructField, data.ty_pl.payload),
            .atomic_rmw => data.ty_pl.payload = try c.payload(Ir.AtomicRmw, data.ty_pl.payload),
            .cmpxchg => data.ty_pl.payload = try c.payload(Ir.Cmpxchg, data.ty_pl.payload),
            .cmp_vector => data.ty_pl.payload = try c.payload(Ir.VectorCmp, data.ty_pl.payload),
            .reduce => data.ty_pl.payload = try c.payload(Ir.Reduce, data.ty_pl.payload),
            .select => data.ty_pl.payload = try c.payload(Ir.Select, data.ty_pl.payload),
            .shuffle => data.ty_pl.payload = try c.payload(Ir.Shuffle, data.ty_pl.payload),
            .aggregate_init => {
                const extra = from.extraData(Ir.Aggregate, data.ty_pl.payload);
                data.ty_pl.payload = try c.payload(Ir.Aggregate, data.ty_pl.payload);
                try c.refs(from.refSlice(extra.end, extra.data.len));
            },
            .call => {
                const extra = from.extraData(Ir.Call, data.pl_op.payload);
                data.pl_op = .{ .operand = c.ref(data.pl_op.operand), .payload = try c.payload(Ir.Call, data.pl_op.payload) };
                try c.refs(from.refSlice(extra.end, extra.data.args_len));
            },
            .block, .loop => {
                const extra = from.extraData(Ir.Block, data.ty_pl.payload);
                const insts = from.bodySlice(extra.end, extra.data.body_len);
                data.ty_pl.payload = try c.payload(Ir.Block, data.ty_pl.payload);
                try c.bodyIndices(insts);
                try c.body(insts);
            },
            .cond_br => {
                const extra = from.extraData(Ir.CondBr, data.pl_op.payload);
                const insts = from.bodySlice(extra.end, extra.data.then_body_len + extra.data.else_body_len);
                data.pl_op = .{ .operand = c.ref(data.pl_op.operand), .payload = try c.payload(Ir.CondBr, data.pl_op.payload) };
                try c.bodyIndices(insts);
                try c.body(insts);
            },
            .switch_br => {
                const old = data.pl_op.payload;
                data.pl_op = .{ .operand = c.ref(data.pl_op.operand), .payload = try c.payload(Ir.SwitchBr, old) };
                var it = from.switchCases(old);
                while (it.next()) |case| {
                    try c.extra.appendSlice(c.gpa, from.extra[case.at..][0..3]);
                    try c.refs(case.items);
                    try c.refs(case.ranges);
                    try c.bodyIndices(case.body);
                }
                try c.bodyIndices(it.elseBody());
                it = from.switchCases(old);
                while (it.next()) |case| try c.body(case.body);
                try c.body(it.elseBody());
            },
        }
        c.insts.set(@backingInt(c.index(i)), .{ .tag = tag, .data = data });
    }
};

/// For a function that returns a slice or an error union of one, the
/// parameter whose value is the length of every slice it returns, when
/// each `ret` returns an error or `ptr[0..n]` with `n` that parameter
/// (`Allocator.alloc`'s `n`), through `wrap_errunion_payload`, `bitcast`s
/// (which keep the length), and blocks whose every `br` does. From `ir`'s
/// own body, before its callees are inlined, so the same in every build
/// and schedule. Prove reads it at the calls that stay calls
/// (`Ir.ret_lens`). Instructions are scanned whether reachable or not,
/// which can only lose the summary.
pub fn retLen(ip: *const InternPool, ir: *const Ir) ?u32 {
    const f = ip.keyPayload(.func, ir.func);
    if (!sliceResult(ip, ip.keyPayload(.func_type, f.ty).return_type)) return null;
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    // The values the function may return, resolved one at a time.
    var stack: [16]Inst.Ref = undefined;
    var len: usize = 0;
    for (tags, datas) |tag, data| if (tag == .ret) {
        if (len == stack.len) return null;
        stack[len] = data.un_op;
        len += 1;
    };
    var arg: ?u32 = null;
    var blocks: u32 = 0;
    while (len > 0) {
        len -= 1;
        const r = stack[len];
        const i = r.toIndex() orelse {
            // An error constant returns no slice.
            const v = r.toInterned().?;
            if (ip.keyTag(v) == .error_union and ip.keyPayload(.error_union, v).val == .err_name) continue;
            return null;
        };
        const data = datas[@backingInt(i)];
        switch (tags[@backingInt(i)]) {
            .wrap_errunion_err => {},
            .wrap_errunion_payload, .bitcast => {
                if (!sliceResult(ip, ir.typeOf(data.ty_op.operand, ip))) return null;
                if (len == stack.len) return null;
                stack[len] = data.ty_op.operand;
                len += 1;
            },
            .block => {
                blocks += 1;
                if (blocks > 4) return null;
                for (tags, datas) |t, d| if (t == .br and d.br.block_inst == i) {
                    if (len == stack.len) return null;
                    stack[len] = d.br.operand;
                    len += 1;
                };
            },
            .slice => {
                const n = ir.extraData(Ir.Bin, data.ty_pl.payload).data.rhs.toIndex() orelse return null;
                if (tags[@backingInt(n)] != .arg) return null;
                const k = datas[@backingInt(n)].arg.index;
                if (arg != null and arg.? != k) return null;
                arg = k;
            },
            else => return null,
        }
    }
    return arg;
}

/// A slice type, or an error union of one.
fn sliceResult(ip: *const InternPool, ty: Index) bool {
    const t = if (ip.keyTag(ty) == .error_union_type) ip.keyPayload(.error_union_type, ty).payload_type else ty;
    return Type.isSlice(ip, t);
}

/// A hash of `ir`'s own body (before its callees are inlined) that is the
/// same in every build that analyzes the function alike: instructions in
/// body order, numbered by first appearance, interned values and types by
/// stable hash, names by their bytes. Positions are relative to the
/// function's declaration already. For the `func_inline` cache edge.
pub fn hashBody(gpa: Allocator, ip: *const InternPool, ir: *const Ir) Allocator.Error!cache.Hash {
    var h: Hasher = .{ .gpa = gpa, .ip = ip, .ir = ir };
    defer h.words.deinit(gpa);
    defer h.numbers.deinit(gpa);
    defer h.types.deinit(gpa);
    try h.numbers.appendNTimes(gpa, no_number, ir.instructions.len);
    try h.body(ir.mainBody());
    // The layouts of the containers whose values the body holds or whose
    // fields it addresses, named by identity above: a caller the body is
    // inlined into lays them out as they are now. From the IR, not the
    // function's dependencies, which differ with the comptime tier that
    // ran its calls; and only layouts the code needs, which every tier
    // has resolved.
    var i: usize = 0;
    while (i < h.types.count()) : (i += 1) {
        const ty = h.types.keys()[i];
        switch (ip.indexToKey(ty)) {
            .array_type => |a| try h.noteValue(a.child),
            .vector_type => |v| try h.noteValue(v.child),
            .opt_type => |c| try h.noteValue(c),
            .error_union_type => |e| try h.noteValue(e.payload_type),
            .tuple_type => |t| for (t.types) |f| try h.noteValue(f),
            .struct_type, .union_type, .enum_type => try h.wide(Incremental.layoutResultHash(ip, ty)),
            else => {},
        }
    }
    return cache.hash(0x696e6c696e65, @ptrCast(h.words.items));
}

const cache = @import("../cache.zig");
const no_number = std.math.maxInt(u32);

const Hasher = struct {
    gpa: Allocator,
    ip: *const InternPool,
    ir: *const Ir,
    words: std.ArrayList(u32) = .empty,
    /// Each instruction's number in body order.
    numbers: std.ArrayList(u32) = .empty,
    next: u32 = 0,
    /// The types of the values the body holds and of the memory it
    /// addresses, in order of first appearance, for their layouts
    /// (`hashBody`). Not a pointer's child the code does not address.
    types: std.array_hash_map.Auto(Index, void) = .empty,

    fn word(h: *Hasher, w: u32) Allocator.Error!void {
        try h.words.append(h.gpa, w);
    }

    fn wide(h: *Hasher, x: cache.Hash) Allocator.Error!void {
        try h.words.appendSlice(h.gpa, @ptrCast(&x));
    }

    fn index(h: *Hasher, i: Index) Allocator.Error!void {
        if (i == .none) return h.word(no_number);
        try h.wide(h.ip.stableHash(i));
        try h.noteValue(if (h.ip.isType(i)) i else h.ip.typeOf(i));
    }

    fn noteValue(h: *Hasher, ty: Index) Allocator.Error!void {
        if (ty != .none) try h.types.put(h.gpa, ty, {});
    }

    /// The child of pointer type `ty`, whose memory the code addresses.
    fn notePointee(h: *Hasher, ty: Index) Allocator.Error!void {
        // An `alloc` can have no type (`Ssa.fillBase`).
        if (ty == .none) return;
        switch (h.ip.indexToKey(ty)) {
            .ptr_type => |p| try h.noteValue(p.child),
            else => try h.noteValue(ty),
        }
    }

    fn number(h: *Hasher, i: Inst.Index) u32 {
        const n = &h.numbers.items[@backingInt(i)];
        if (n.* == no_number) {
            n.* = h.next;
            h.next += 1;
        }
        return n.*;
    }

    fn ref(h: *Hasher, r: Inst.Ref) Allocator.Error!void {
        if (r == .none) return h.word(no_number);
        if (r.toIndex()) |i| return h.word(h.number(i));
        try h.word(no_number - 1);
        try h.index(r.toInterned().?);
    }

    fn string(h: *Hasher, s: InternPool.String) Allocator.Error!void {
        try h.wide(cache.hash(0, h.ip.stringSlice(s)));
    }

    fn payload(h: *Hasher, comptime T: type, at: u32) Allocator.Error!void {
        inline for (@typeInfo(T).@"struct".field_types, 0..) |Field, k| {
            const w = h.ir.extra[at + k];
            if (Field == Inst.Ref) try h.ref(@fromBackingInt(w)) else if (Field == Index) try h.index(@fromBackingInt(w)) else try h.word(w);
        }
    }

    fn refs(h: *Hasher, list: []const Inst.Ref) Allocator.Error!void {
        for (list) |r| try h.ref(r);
    }

    fn body(h: *Hasher, insts: []const Inst.Index) Allocator.Error!void {
        try h.word(@intCast(insts.len));
        for (insts) |i| try h.inst(i);
    }

    fn inst(h: *Hasher, i: Inst.Index) Allocator.Error!void {
        const ir = h.ir;
        const data = ir.instructions.items(.data)[@backingInt(i)];
        const tag = ir.instructions.items(.tag)[@backingInt(i)];
        try h.word(h.number(i));
        try h.word(@backingInt(tag));
        switch (tag) {
            .unreach, .trap, .breakpoint, .dbg_inline_end, .ret_addr, .frame_addr => {},
            .arg => {
                try h.index(data.arg.ty);
                try h.word(data.arg.index);
            },
            .alloc, .err_return_trace, .c_va_start => {
                try h.index(data.ty);
                if (tag == .alloc) try h.notePointee(data.ty);
            },
            .dbg_stmt => {
                try h.word(data.dbg_stmt.line);
                try h.word(data.dbg_stmt.column);
            },
            .dbg_inline_begin => {
                try h.index(data.dbg_inline.func);
                try h.payload(Ir.DbgInline, data.dbg_inline.payload);
            },
            .extern_ptr, .extern_pcrel, .extern_tls => {
                try h.index(data.ty_pl.ty);
                try h.string(@fromBackingInt(data.ty_pl.payload));
            },
            .tls_ptr => {
                try h.index(data.ty_pl.ty);
                try h.string(h.ip.getNav(@fromBackingInt(data.ty_pl.payload)).key);
            },
            .save_err_return_trace_index => {
                try h.index(data.ty_pl.ty);
                try h.word(data.ty_pl.payload);
            },
            .br => {
                try h.word(h.number(data.br.block_inst));
                try h.ref(data.br.operand);
            },
            .repeat => try h.word(h.number(data.repeat.loop_inst)),
            .ret, .error_name, .cmp_lt_errors_len, .int_from_bool, .int_from_ptr, .is_null, .is_non_null, .is_err, .is_non_err, .set_err_return_trace => try h.ref(data.un_op),
            .neg_float, .sqrt, .sin, .cos, .tan, .exp, .exp2, .log, .log2, .log10, .abs_float, .floor, .ceil, .round, .trunc_float => try h.ref(data.un_op),
            .load, .not, .intcast, .trunc, .float_cast, .float_from_int, .int_from_float, .bitcast, .clz, .ctz, .popcount, .byte_swap, .bit_reverse, .ptr_from_int, .atomic_load, .slice_ptr, .slice_len, .optional_payload, .optional_payload_ptr, .optional_payload_ptr_set, .wrap_optional, .unwrap_errunion_payload, .unwrap_errunion_err, .unwrap_errunion_payload_ptr, .unwrap_errunion_err_ptr, .errunion_payload_ptr_set, .wrap_errunion_payload, .wrap_errunion_err, .get_union_tag, .tag_name, .c_va_arg, .c_va_copy => {
                try h.index(data.ty_op.ty);
                try h.ref(data.ty_op.operand);
            },
            .store, .add_wrap, .sub_wrap, .mul_wrap, .add_float, .sub_float, .mul_float, .div_float, .div_trunc, .div_floor, .div_ceil, .rem, .mod, .min_float, .max_float, .min_int, .max_int, .bit_and, .bit_or, .xor, .shl, .shr, .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq, .atomic_store, .ptr_elem_val, .slice_elem_val, .array_elem_val, .set_union_tag, .memcpy, .memmove, .memset => {
                try h.ref(data.bin_op.lhs);
                try h.ref(data.bin_op.rhs);
            },
            .add_with_overflow, .sub_with_overflow, .mul_with_overflow, .ptr_elem_ptr, .slice_elem_ptr, .slice, .ptr_add => {
                try h.index(data.ty_pl.ty);
                try h.payload(Ir.Bin, data.ty_pl.payload);
                if (tag == .ptr_elem_ptr or tag == .slice_elem_ptr or tag == .ptr_add) try h.notePointee(data.ty_pl.ty);
            },
            .mul_add, .vector_store_elem => {
                try h.ref(data.pl_op.operand);
                try h.payload(Ir.Bin, data.pl_op.payload);
            },
            .struct_field_ptr, .struct_field_val, .union_init => {
                try h.index(data.ty_pl.ty);
                try h.payload(Ir.StructField, data.ty_pl.payload);
                if (tag != .union_init) try h.notePointee(ir.typeOf(ir.extraData(Ir.StructField, data.ty_pl.payload).data.operand, h.ip));
            },
            .atomic_rmw => {
                try h.index(data.ty_pl.ty);
                try h.payload(Ir.AtomicRmw, data.ty_pl.payload);
            },
            .cmpxchg => {
                try h.index(data.ty_pl.ty);
                try h.payload(Ir.Cmpxchg, data.ty_pl.payload);
            },
            inline .cmp_vector, .reduce, .select, .shuffle => |t| {
                try h.index(data.ty_pl.ty);
                try h.payload(switch (t) {
                    .cmp_vector => Ir.VectorCmp,
                    .reduce => Ir.Reduce,
                    .select => Ir.Select,
                    .shuffle => Ir.Shuffle,
                    else => unreachable,
                }, data.ty_pl.payload);
            },
            .aggregate_init => {
                const extra = ir.extraData(Ir.Aggregate, data.ty_pl.payload);
                try h.index(data.ty_pl.ty);
                try h.word(extra.data.len);
                try h.refs(ir.refSlice(extra.end, extra.data.len));
            },
            .call => {
                const extra = ir.extraData(Ir.Call, data.pl_op.payload);
                try h.ref(data.pl_op.operand);
                try h.payload(Ir.Call, data.pl_op.payload);
                try h.refs(ir.refSlice(extra.end, extra.data.args_len));
            },
            .block, .loop => {
                const extra = ir.extraData(Ir.Block, data.ty_pl.payload);
                try h.index(data.ty_pl.ty);
                try h.body(ir.bodySlice(extra.end, extra.data.body_len));
            },
            .cond_br => {
                const extra = ir.extraData(Ir.CondBr, data.pl_op.payload);
                try h.ref(data.pl_op.operand);
                try h.payload(Ir.CondBr, data.pl_op.payload);
                try h.body(ir.bodySlice(extra.end, extra.data.then_body_len));
                try h.body(ir.bodySlice(extra.end + extra.data.then_body_len, extra.data.else_body_len));
            },
            .switch_br => {
                try h.ref(data.pl_op.operand);
                try h.payload(Ir.SwitchBr, data.pl_op.payload);
                var it = ir.switchCases(data.pl_op.payload);
                while (it.next()) |c| {
                    try h.word(@intCast(c.items.len));
                    try h.word(@intCast(c.ranges.len));
                    try h.refs(c.items);
                    try h.refs(c.ranges);
                    try h.body(c.body);
                }
                try h.body(it.elseBody());
            },
            .assembly, .comptime_tick, .comptime_quota, .comptime_dep, .comptime_effect, .comptime_exit => unreachable,
        }
    }
};
