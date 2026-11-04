//! Inlining within a budget (docs/architecture.md): which calls of a
//! function's IR are candidates, whether the function can itself be
//! inlined, and splicing callee bodies into a caller's IR in the shape
//! Sema gives inline calls. Target-independent; Emit schedules it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const Index = InternPool.Index;
const Ir = @import("../Ir.zig");
const Inst = Ir.Inst;
const Zcu = @import("../Zcu.zig");
const Zir = std.zig.Zir;
const Type = @import("../Type.zig");

/// The most instructions with hot code (`Scan.size`) a call inlines, after
/// the callee's own callees are inlined and less what its constant
/// arguments fold (`Site.cost`). A comptime callback's call (`Site.callback`)
/// gets twice as many.
pub const budget = 30;

/// The largest body that is inlinable at all, whatever its arguments fold.
pub fn cap(b: u32) u32 {
    return 4 * b;
}

/// The parameters whose constant arguments are weighed (`Scan.folds`).
pub const max_params = 8;
pub const Folds = [max_params]u8;

/// A call that may be inlined: a direct call of an `.auto` function, not
/// `never_inline`, outside cold code. `line:column` is the call's statement
/// position.
pub const Site = struct {
    call: Inst.Index,
    callee: Index,
    line: u32,
    column: u32,
    /// Bit k: argument k is a constant.
    consts: u8 = 0,
    /// Whether comptime parameters chose the callee (`chosen`).
    callback: bool = false,
    /// Per argument: the caller's parameter it is (as `Scanner.dep`), so
    /// the callee's folds become the caller's when it is inlined.
    params: [max_params]u8 = @splat(none),

    /// The callee's size here: less what the constant arguments fold, but
    /// never under 1 (its `ret`).
    pub fn cost(site: Site, size: u32, folds: Folds) u32 {
        var saved: u32 = 0;
        for (folds, 0..) |f, k| {
            if (site.consts >> @intCast(k) & 1 != 0) saved += f;
        }
        return @max(1, size -| saved);
    }

    pub fn limit(site: Site, b: u32) u32 {
        return if (site.callback) 2 * b else b;
    }
};

/// `Scanner.dep` of a value that depends on no parameter (or on more than
/// one, or on something that does not fold).
const none: u8 = 0xff;

pub const Scan = struct {
    /// Instructions with code outside cold bodies (those ending in
    /// `unreach` or `trap`: safety checks, `unreachable`).
    size: u32 = 0,
    /// Per parameter: the hot instructions the rewrite rules remove when
    /// the argument is a constant: the operations on it that fold, and
    /// the smaller side of each branch on them (saturating). Inlined
    /// callees add theirs for the arguments that are parameters.
    folds: Folds = @splat(0),
    /// Whether the function could be spliced into a caller once its
    /// candidate calls are inlined: an `.auto`, non-`noinline` function
    /// whose IR uses only instructions `splice` maps, and that calls
    /// nothing else but cold `noreturn` functions.
    inlinable: bool = true,
    /// Whether the function can start a panic: it calls a cold `noreturn`
    /// function (a safety check's handler, `unreachable`, `@panic`) or
    /// traps. A panic in inlined code loses its callers' frames from the
    /// stack trace.
    panics: bool = false,
};

/// Finds the candidate calls of `ir` (into `sites`, in IR order) and
/// whether `ir`'s function could be inlined. Folds are found while the
/// size is at most `max_size` (past it the function is not inlinable).
/// `scratch` is kept for the next function.
pub fn scan(gpa: Allocator, zcu: *const Zcu, ir: *const Ir, sites: *std.ArrayList(Site), max_size: u32, scratch: *std.ArrayList(u8)) Allocator.Error!Scan {
    const start = sites.items.len;
    try scratch.resize(gpa, ir.instructions.len);
    @memset(scratch.items, none);
    var s: Scanner = .{ .gpa = gpa, .ip = &zcu.ip, .ir = ir, .sites = sites, .deps = scratch.items, .max_size = max_size };
    defer s.chosen.deinit(gpa);
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

/// The values comptime parameters of `func` chose: its instance's
/// comptime arguments, the values its type captured (a function or type
/// passed to the generic function that made it, as `std.sort`'s
/// `lessThanFn`), and the types of parameters whose type the instance
/// chose (`context: anytype`), or that they point to. A call of one of
/// them, or of a function one of these types declares, is a comptime
/// callback's (`Site.callback`): a generic function's hot operations,
/// such as comparators, hash and equality contexts, and `swap`.
fn chosen(ip: *const InternPool, func: Index, out: *std.ArrayList(Index), gpa: Allocator) Allocator.Error!void {
    const f = ip.keyPayload(.func, func);
    for (f.comptime_args) |a| if (a != .none) try out.append(gpa, a);
    const parent = ip.getNav(f.owner_nav).parent;
    if (parent != .none) try out.appendSlice(gpa, switch (ip.keyTag(parent)) {
        .struct_type => ip.keyPayload(.struct_type, parent).captures,
        .union_type => ip.keyPayload(.union_type, parent).captures,
        .enum_type => ip.keyPayload(.enum_type, parent).captures,
        .opaque_type => ip.keyPayload(.opaque_type, parent).captures,
        else => &.{},
    });
    if (f.generic_owner == .none) return;
    const generic = ip.keyPayload(.func_type, ip.keyPayload(.func, f.generic_owner).ty).param_types;
    const params = ip.keyPayload(.func_type, f.ty).param_types;
    if (generic.len != params.len) return;
    for (generic, params) |g, p| {
        if (g == p) continue;
        try out.append(gpa, if (ip.keyTag(p) == .ptr_type) ip.keyPayload(.ptr_type, p).child else p);
    }
}

/// `Scanner.dep` of a constant operand.
const konst: u8 = 0xfe;
/// Or'ed into `Scanner.dep` of a pointer into a `*const` alloc, which
/// loads read the parameter through.
const in_alloc: u8 = 0x40;

const Scanner = struct {
    gpa: Allocator,
    ip: *const InternPool,
    ir: *const Ir,
    sites: *std.ArrayList(Site),
    /// Per instruction: the parameter (below `max_params`) its value is
    /// computed from, with constants, by operations the rewrite rules fold;
    /// with `in_alloc` for a `*const` alloc that parameter initialized, and
    /// field pointers into it; else `none`.
    deps: []u8,
    max_size: u32,
    /// `chosen` of the function, found at its first candidate call.
    chosen: std.ArrayList(Index) = .empty,
    chosen_found: bool = false,
    out: Scan = .{},
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
                .arg => {
                    if (data.arg.index < max_params) s.deps[@backingInt(inst)] = @intCast(data.arg.index);
                    continue;
                },
                .dbg_inline_begin, .dbg_inline_end => continue,
                .save_err_return_trace_index => if (data.ty_pl.ty == .none) continue else {
                    s.out.inlinable = false;
                },
                .ret_addr, .frame_addr, .err_return_trace, .set_err_return_trace, .assembly, .c_va_start, .c_va_arg, .c_va_copy => s.out.inlinable = false,
                .comptime_tick, .comptime_quota, .comptime_dep, .comptime_effect, .comptime_exit => unreachable,
                .block, .loop => {
                    const extra = ir.extraData(Ir.Block, data.ty_pl.payload);
                    try s.body(ir.bodySlice(extra.end, extra.data.body_len), cold);
                },
                .cond_br => {
                    const extra = ir.extraData(Ir.CondBr, data.pl_op.payload);
                    const then_body = ir.bodySlice(extra.end, extra.data.then_body_len);
                    const else_body = ir.bodySlice(extra.end + then_body.len, extra.data.else_body_len);
                    const before = s.out.size;
                    try s.body(then_body, cold or isCold(ir, then_body));
                    const then_size = s.out.size - before;
                    try s.body(else_body, cold or isCold(ir, else_body));
                    const else_size = s.out.size - before - then_size;
                    // A constant condition keeps one side (`Ssa.build`).
                    const d = s.dep(data.pl_op.operand);
                    if (!cold and d < max_params) s.fold(d, 1 + @min(then_size, else_size));
                },
                .switch_br => {
                    const extra = ir.extraData(Ir.SwitchBr, data.pl_op.payload);
                    var i = extra.end;
                    for (0..extra.data.cases_len) |_| {
                        const items_len = ir.extra[i];
                        const body_len = ir.extra[i + 1];
                        i += 2 + items_len;
                        const case = ir.bodySlice(i, body_len);
                        try s.body(case, cold or isCold(ir, case));
                        i += body_len;
                    }
                    const else_body = ir.bodySlice(i, extra.data.else_body_len);
                    try s.body(else_body, cold or isCold(ir, else_body));
                },
                .call => try s.call(inst, cold),
                // A trap has no return address for synthetic frames.
                .trap => {
                    s.out.panics = true;
                    s.out.inlinable = false;
                },
                .store => if (!cold and s.out.inlinable and s.out.size <= s.max_size) if (data.bin_op.lhs.toIndex()) |p| {
                    // The initializing store of a `*const` alloc.
                    if (tags[@backingInt(p)] == .alloc and datas[@backingInt(p)].ty != .none and
                        s.ip.keyPayload(.ptr_type, datas[@backingInt(p)].ty).flags.is_const)
                    {
                        const d = s.dep(data.bin_op.rhs);
                        if (d < max_params) s.deps[@backingInt(p)] = d | in_alloc;
                    }
                },
                // Only while the function may still be inlinable.
                else => if (!cold and s.out.inlinable and s.out.size <= s.max_size) {
                    const d = s.foldDep(tag, data);
                    s.deps[@backingInt(inst)] = d;
                    if (d < max_params) s.fold(d, 1);
                },
            }
            if (!cold) s.out.size += 1;
        }
    }

    fn fold(s: *Scanner, d: u8, n: u32) void {
        const f = &s.out.folds[d];
        f.* = @intCast(@min(255, @as(u32, f.*) + n));
    }

    fn dep(s: *const Scanner, r: Inst.Ref) u8 {
        if (r == .none) return none;
        if (r.toIndex()) |i| return s.deps[@backingInt(i)];
        return konst;
    }

    /// Of operands that fold together: the one parameter they depend on.
    fn both(s: *const Scanner, a: Inst.Ref, b: Inst.Ref) u8 {
        const x = s.dep(a);
        const y = s.dep(b);
        if (x == konst) return y;
        if (y == konst or x == y) return x;
        return none;
    }

    /// Whether the rewrite rules evaluate operations on constants of `r`'s
    /// type: integers up to 64 bits and bools.
    fn evaluable(s: *const Scanner, r: Inst.Ref) bool {
        const ty = s.ir.typeOf(r, s.ip);
        return switch (Type.class(s.ip, ty)) {
            .bool => true,
            .int => Type.intInfo(s.ip, ty).bits <= 64,
            else => false,
        };
    }

    /// The parameter an instruction's value folds from (`deps`), as
    /// `rewrite.zig` folds it once that parameter's argument is constant.
    fn foldDep(s: *const Scanner, tag: Inst.Tag, data: Inst.Data) u8 {
        const ir = s.ir;
        const d: u8, const ref: Inst.Ref = switch (tag) {
            // Vector and wide operands, which do not fold, are rare enough
            // not to look up.
            .add_wrap, .sub_wrap, .mul_wrap, .bit_and, .bit_or, .xor, .shl, .shr, .div_trunc, .div_floor, .div_ceil, .rem, .mod => .{ s.both(data.bin_op.lhs, data.bin_op.rhs), .none },
            .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => .{ s.both(data.bin_op.lhs, data.bin_op.rhs), data.bin_op.lhs },
            .not, .intcast, .trunc => .{ s.dep(data.ty_op.operand), data.ty_op.operand },
            .int_from_bool => .{ s.dep(data.un_op), .none },
            .add_with_overflow, .sub_with_overflow, .mul_with_overflow => blk: {
                const bin = ir.extraData(Ir.Bin, data.ty_pl.payload).data;
                break :blk .{ s.both(bin.lhs, bin.rhs), .none };
            },
            .struct_field_val => .{ s.dep(ir.extraData(Ir.StructField, data.ty_pl.payload).data.operand), .none },
            // A field of the alloc is the field of the parameter.
            .struct_field_ptr => {
                const p = s.dep(ir.extraData(Ir.StructField, data.ty_pl.payload).data.operand);
                return if (p != none and p & in_alloc != 0 and p != konst) p else none;
            },
            .load => {
                const p = s.dep(data.ty_op.operand);
                return if (p != none and p & in_alloc != 0 and p != konst) p & ~in_alloc else none;
            },
            .slice_ptr, .slice_len, .optional_payload, .unwrap_errunion_payload => .{ s.dep(data.ty_op.operand), .none },
            .is_null, .is_non_null, .is_err, .is_non_err => .{ s.dep(data.un_op), .none },
            .array_elem_val => .{ s.both(data.bin_op.lhs, data.bin_op.rhs), .none },
            else => return none,
        };
        if (d >= max_params) return none;
        if (ref != .none and !s.evaluable(ref)) return none;
        return d;
    }

    fn call(s: *Scanner, inst: Inst.Index, cold: bool) Allocator.Error!void {
        const ip = s.ip;
        const data = s.ir.instructions.items(.data)[@backingInt(inst)].pl_op;
        const extra = s.ir.extraData(Ir.Call, data.payload);
        if (extra.data.ret_ty == .noreturn_type) {
            s.out.panics = true;
            return;
        }
        const callee = data.operand.toInterned() orelse {
            s.out.inlinable = false;
            return;
        };
        if (cold or extra.data.flags.never_inline or ip.keyTag(callee) != .func or
            ip.keyPayload(.func_type, ip.typeOf(callee)).cc != .auto)
        {
            s.out.inlinable = false;
            return;
        }
        var site: Site = .{ .call = inst, .callee = callee, .line = s.line, .column = s.column };
        if (!s.chosen_found) {
            try chosen(ip, s.ir.func, &s.chosen, s.gpa);
            s.chosen_found = true;
        }
        if (s.chosen.items.len != 0) {
            const parent = ip.getNav(ip.keyPayload(.func, callee).owner_nav).parent;
            for (s.chosen.items) |c| if (c == callee or c == parent) {
                site.callback = true;
                break;
            };
        }
        const args = s.ir.refSlice(extra.end, extra.data.args_len);
        for (args[0..@min(args.len, max_params)], 0..) |a, k| switch (s.dep(a)) {
            konst => site.consts |= @as(u8, 1) << @intCast(k),
            else => |d| site.params[k] = d,
        };
        try s.sites.append(s.gpa, site);
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

/// Copies a callee's instructions to `base +` their index in the caller.
const Copier = struct {
    gpa: Allocator,
    from: *const Ir,
    insts: *std.MultiArrayList(Inst),
    extra: *std.ArrayList(u32),
    base: u32,
    args: []const Inst.Ref,
    /// The call, now the block the callee's `ret`s exit.
    block: Inst.Index,

    fn ref(c: *const Copier, r: Inst.Ref) Inst.Ref {
        if (r == .none) return r;
        const i = r.toIndex() orelse return r;
        const data = c.from.instructions.items(.data)[@backingInt(i)];
        if (c.from.instructions.items(.tag)[@backingInt(i)] == .arg) return c.args[data.arg.index];
        return c.index(i).toRef();
    }

    fn index(c: *const Copier, i: Inst.Index) Inst.Index {
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

    fn bodyIndices(c: *Copier, body_insts: []const Inst.Index) Allocator.Error!void {
        for (body_insts) |i| try c.extra.append(c.gpa, @backingInt(c.index(i)));
    }

    fn refs(c: *Copier, list: []const Inst.Ref) Allocator.Error!void {
        for (list) |r| try c.extra.append(c.gpa, @backingInt(c.ref(r)));
    }

    fn body(c: *Copier, body_insts: []const Inst.Index) Allocator.Error!void {
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
            .ret => {
                tag = .br;
                const operand = c.ref(data.un_op);
                data = .{ .br = .{ .block_inst = c.block, .operand = operand } };
            },
            .br => {
                const operand = c.ref(data.br.operand);
                data.br = .{ .block_inst = c.index(data.br.block_inst), .operand = operand };
            },
            .repeat => data.repeat.loop_inst = c.index(data.repeat.loop_inst),
            .error_name, .int_from_bool, .int_from_ptr, .is_null, .is_non_null, .is_err, .is_non_err => data.un_op = c.ref(data.un_op),
            .neg_float, .sqrt, .sin, .cos, .tan, .exp, .exp2, .log, .log2, .log10, .abs_float, .floor, .ceil, .round, .trunc_float => data.un_op = c.ref(data.un_op),
            .load, .not, .intcast, .trunc, .float_cast, .float_from_int, .int_from_float, .bitcast, .clz, .ctz, .popcount, .byte_swap, .bit_reverse => data.ty_op.operand = c.ref(data.ty_op.operand),
            .ptr_from_int, .atomic_load, .slice_ptr, .slice_len, .optional_payload, .optional_payload_ptr, .optional_payload_ptr_set, .wrap_optional => data.ty_op.operand = c.ref(data.ty_op.operand),
            .unwrap_errunion_payload, .unwrap_errunion_err, .unwrap_errunion_payload_ptr, .unwrap_errunion_err_ptr, .errunion_payload_ptr_set => data.ty_op.operand = c.ref(data.ty_op.operand),
            .wrap_errunion_payload, .wrap_errunion_err, .get_union_tag, .tag_name => data.ty_op.operand = c.ref(data.ty_op.operand),
            .store, .add_wrap, .sub_wrap, .mul_wrap, .add_float, .sub_float, .mul_float, .div_float, .div_trunc, .div_floor, .div_ceil, .rem, .mod => data.bin_op = .{ .lhs = c.ref(data.bin_op.lhs), .rhs = c.ref(data.bin_op.rhs) },
            .min_float, .max_float, .bit_and, .bit_or, .xor, .shl, .shr, .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq => data.bin_op = .{ .lhs = c.ref(data.bin_op.lhs), .rhs = c.ref(data.bin_op.rhs) },
            .atomic_store, .ptr_elem_val, .slice_elem_val, .array_elem_val, .set_union_tag, .memcpy, .memmove, .memset => data.bin_op = .{ .lhs = c.ref(data.bin_op.lhs), .rhs = c.ref(data.bin_op.rhs) },
            .add_with_overflow, .sub_with_overflow, .mul_with_overflow, .ptr_elem_ptr, .slice_elem_ptr, .slice, .ptr_add => data.ty_pl.payload = try c.payload(Ir.Bin, data.ty_pl.payload),
            .mul_add, .vector_store_elem => data.pl_op = .{ .operand = c.ref(data.pl_op.operand), .payload = try c.payload(Ir.Bin, data.pl_op.payload) },
            .struct_field_ptr, .struct_field_val, .union_init => data.ty_pl.payload = try c.payload(Ir.StructField, data.ty_pl.payload),
            .atomic_rmw => data.ty_pl.payload = try c.payload(Ir.AtomicRmw, data.ty_pl.payload),
            .cmpxchg => data.ty_pl.payload = try c.payload(Ir.Cmpxchg, data.ty_pl.payload),
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
                const extra = from.extraData(Ir.SwitchBr, data.pl_op.payload);
                data.pl_op = .{ .operand = c.ref(data.pl_op.operand), .payload = try c.payload(Ir.SwitchBr, data.pl_op.payload) };
                var at = extra.end;
                for (0..extra.data.cases_len) |_| {
                    const items_len = from.extra[at];
                    const body_len = from.extra[at + 1];
                    try c.extra.appendSlice(c.gpa, &.{ items_len, body_len });
                    try c.refs(from.refSlice(at + 2, items_len));
                    try c.bodyIndices(from.bodySlice(at + 2 + items_len, body_len));
                    at += 2 + items_len + body_len;
                }
                try c.bodyIndices(from.bodySlice(at, extra.data.else_body_len));
                at = extra.end;
                for (0..extra.data.cases_len) |_| {
                    const items_len = from.extra[at];
                    const body_len = from.extra[at + 1];
                    try c.body(from.bodySlice(at + 2 + items_len, body_len));
                    at += 2 + items_len + body_len;
                }
                try c.body(from.bodySlice(at, extra.data.else_body_len));
            },
        }
        c.insts.set(@backingInt(c.index(i)), .{ .tag = tag, .data = data });
    }
};

/// A hash of `ir`'s own body (before its callees are inlined) that is the
/// same in every build that analyzes the function alike: instructions in
/// body order, numbered by first appearance, interned values and types by
/// stable hash, names by their bytes. Positions are relative to the
/// function's declaration already. For the `func_inline` cache edge.
pub fn hashBody(gpa: Allocator, ip: *const InternPool, ir: *const Ir) Allocator.Error!cache.Hash {
    var h: Hasher = .{ .gpa = gpa, .ip = ip, .ir = ir };
    defer h.words.deinit(gpa);
    defer h.numbers.deinit(gpa);
    try h.numbers.appendNTimes(gpa, no_number, ir.instructions.len);
    try h.body(ir.mainBody());
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

    fn word(h: *Hasher, w: u32) Allocator.Error!void {
        try h.words.append(h.gpa, w);
    }

    fn wide(h: *Hasher, x: cache.Hash) Allocator.Error!void {
        try h.words.appendSlice(h.gpa, @ptrCast(&x));
    }

    fn index(h: *Hasher, i: Index) Allocator.Error!void {
        if (i == .none) return h.word(no_number);
        try h.wide(h.ip.stableHash(i));
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
        try h.word(@intFromEnum(tag));
        switch (tag) {
            .unreach, .trap, .breakpoint, .dbg_inline_end, .ret_addr, .frame_addr => {},
            .arg => {
                try h.index(data.arg.ty);
                try h.word(data.arg.index);
            },
            .alloc, .err_return_trace, .c_va_start => try h.index(data.ty),
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
            .ret, .error_name, .int_from_bool, .int_from_ptr, .is_null, .is_non_null, .is_err, .is_non_err, .set_err_return_trace => try h.ref(data.un_op),
            .neg_float, .sqrt, .sin, .cos, .tan, .exp, .exp2, .log, .log2, .log10, .abs_float, .floor, .ceil, .round, .trunc_float => try h.ref(data.un_op),
            .load, .not, .intcast, .trunc, .float_cast, .float_from_int, .int_from_float, .bitcast, .clz, .ctz, .popcount, .byte_swap, .bit_reverse, .ptr_from_int, .atomic_load, .slice_ptr, .slice_len, .optional_payload, .optional_payload_ptr, .optional_payload_ptr_set, .wrap_optional, .unwrap_errunion_payload, .unwrap_errunion_err, .unwrap_errunion_payload_ptr, .unwrap_errunion_err_ptr, .errunion_payload_ptr_set, .wrap_errunion_payload, .wrap_errunion_err, .get_union_tag, .tag_name, .c_va_arg, .c_va_copy => {
                try h.index(data.ty_op.ty);
                try h.ref(data.ty_op.operand);
            },
            .store, .add_wrap, .sub_wrap, .mul_wrap, .add_float, .sub_float, .mul_float, .div_float, .div_trunc, .div_floor, .div_ceil, .rem, .mod, .min_float, .max_float, .bit_and, .bit_or, .xor, .shl, .shr, .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq, .atomic_store, .ptr_elem_val, .slice_elem_val, .array_elem_val, .set_union_tag, .memcpy, .memmove, .memset => {
                try h.ref(data.bin_op.lhs);
                try h.ref(data.bin_op.rhs);
            },
            .add_with_overflow, .sub_with_overflow, .mul_with_overflow, .ptr_elem_ptr, .slice_elem_ptr, .slice, .ptr_add => {
                try h.index(data.ty_pl.ty);
                try h.payload(Ir.Bin, data.ty_pl.payload);
            },
            .mul_add, .vector_store_elem => {
                try h.ref(data.pl_op.operand);
                try h.payload(Ir.Bin, data.pl_op.payload);
            },
            .struct_field_ptr, .struct_field_val, .union_init => {
                try h.index(data.ty_pl.ty);
                try h.payload(Ir.StructField, data.ty_pl.payload);
            },
            .atomic_rmw => {
                try h.index(data.ty_pl.ty);
                try h.payload(Ir.AtomicRmw, data.ty_pl.payload);
            },
            .cmpxchg => {
                try h.index(data.ty_pl.ty);
                try h.payload(Ir.Cmpxchg, data.ty_pl.payload);
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
                const extra = ir.extraData(Ir.SwitchBr, data.pl_op.payload);
                try h.ref(data.pl_op.operand);
                try h.payload(Ir.SwitchBr, data.pl_op.payload);
                var at = extra.end;
                for (0..extra.data.cases_len) |_| {
                    const items_len = ir.extra[at];
                    const body_len = ir.extra[at + 1];
                    try h.refs(ir.refSlice(at + 2, items_len));
                    try h.body(ir.bodySlice(at + 2 + items_len, body_len));
                    at += 2 + items_len + body_len;
                }
                try h.body(ir.bodySlice(at, extra.data.else_body_len));
            },
            .assembly, .comptime_tick, .comptime_quota, .comptime_dep, .comptime_effect, .comptime_exit => unreachable,
        }
    }
};
