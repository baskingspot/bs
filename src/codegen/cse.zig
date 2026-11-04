//! Common subexpressions (docs/architecture.md, "Common subexpressions"):
//! one forward walk over a function's IR that replaces a pure operation
//! by an earlier one with the same operation and operands that executes
//! on every path to it. The replaced instruction stays in place and the
//! dead-code pass drops it; nothing moves.
//!
//! Earlier means: in the same body before it, or in a body around it
//! before the construct holding it, and inside the same loops: a value
//! from outside a loop stays a register through the whole loop, which the
//! allocator (no splitting) pays for in spills. A load of a variable (an
//! alloc only loaded from and stored to) is such an operation until the
//! variable's next store; a load through any other pointer until the
//! next write to memory (a store, a call, an atomic operation).
//!
//! Left alone, since computing them twice is cheaper than keeping them
//! live: compares and the other conditions a branch reads from the
//! flags, operations whose result is not one register, and cold code.
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
    /// Instructions replaced by an earlier one.
    removed: u32 = 0,
};

/// An operation and its operands.
const Key = struct { tag: Inst.Tag, ty: u32, l: u32, r: u32 };

/// Arrays kept from one function to the next on a worker.
pub const Scratch = struct {
    /// Per instruction: what replaces it, or `.none`; per alloc, whether
    /// it is a variable (`variable`).
    subst: std.ArrayList(Inst.Ref) = .empty,
    variable: std.ArrayList(bool) = .empty,
    /// The operations available, and each one's instruction.
    table: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    /// The keys added, in walk order, so a scope can remove its own.
    added: std.ArrayList(Key) = .empty,
    /// The keys of reads of memory other than variables in `table`, for
    /// writes to memory.
    reads: std.ArrayList(Key) = .empty,

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        s.subst.deinit(gpa);
        s.variable.deinit(gpa);
        s.table.deinit(gpa);
        s.added.deinit(gpa);
        s.reads.deinit(gpa);
    }
};

/// An available operation: its instruction, and the loops around it.
const Entry = struct { inst: Inst.Index, loops: u32 };

pub fn run(gpa: Allocator, ip: *const InternPool, ir: *Ir, scratch: *Scratch) Allocator.Error!Stats {
    const n = ir.instructions.len;
    try scratch.subst.resize(gpa, n);
    @memset(scratch.subst.items, .none);
    try scratch.variable.resize(gpa, n);
    classify(ip, ir, scratch.variable.items);
    scratch.table.clearRetainingCapacity();
    scratch.added.clearRetainingCapacity();
    scratch.reads.clearRetainingCapacity();
    var w: Walker = .{ .gpa = gpa, .ip = ip, .ir = ir, .s = scratch };
    try w.scoped(ir.mainBody(), false);
    return w.stats;
}

/// Which allocs are variables: never volatile, only loaded from and
/// stored to. Any other use (an address taken, passed, cast, or stored)
/// disqualifies one, so only its own stores change it.
fn classify(ip: *const InternPool, ir: *const Ir, variable: []bool) void {
    const tags = ir.instructions.items(.tag);
    const datas = ir.instructions.items(.data);
    for (tags, datas, variable) |tag, data, *v| {
        v.* = tag == .alloc and data.ty != .none and !Type.ptrInfo(ip, data.ty).flags.is_volatile;
    }
    const Escape = struct {
        variable: []bool,
        pub fn use(e: @This(), r: Inst.Ref) void {
            const i = r.toIndex() orelse return;
            e.variable[@backingInt(i)] = false;
        }
    };
    const e: Escape = .{ .variable = variable };
    for (tags, datas, 0..) |tag, data, i| switch (tag) {
        .load => {},
        .store => e.use(data.bin_op.rhs),
        else => Ssa.forEachOperand(ir, @enumFromInt(i), e),
    };
}

const Walker = struct {
    gpa: Allocator,
    ip: *const InternPool,
    ir: *Ir,
    s: *Scratch,
    stats: Stats = .{},
    /// The loops around the instruction being walked.
    loops: u32 = 0,

    pub fn use(w: *Walker, p: *Inst.Ref) void {
        const i = p.toIndex() orelse return;
        const s = w.s.subst.items[@backingInt(i)];
        if (s != .none) p.* = s;
    }

    /// Walks `insts` in a scope of its own, which forgets what it added:
    /// what follows the body does not always run after all of it.
    fn scoped(w: *Walker, insts: []const Inst.Index, cold: bool) Allocator.Error!void {
        const s = w.s;
        const start = s.added.items.len;
        for (insts) |inst| try w.instruction(inst, cold);
        for (s.added.items[start..]) |k| _ = s.table.remove(k);
        s.added.shrinkRetainingCapacity(start);
    }

    fn instruction(w: *Walker, inst: Inst.Index, cold: bool) Allocator.Error!void {
        const ir = w.ir;
        const s = w.s;
        const tag = ir.instructions.items(.tag)[@backingInt(inst)];
        Ssa.forEachOperandPtr(ir, inst, w);
        const data = ir.instructions.items(.data)[@backingInt(inst)];
        switch (tag) {
            .block => {
                const x = ir.extraData(Ir.Block, data.ty_pl.payload);
                try w.scoped(ir.bodySlice(x.end, x.data.body_len), cold);
                return;
            },
            // Inside, what was computed outside is not reused (`loops`), so
            // nothing from a later iteration can be: a store or write in
            // the body removes what it invalidates, wherever it was added.
            .loop => {
                const x = ir.extraData(Ir.Block, data.ty_pl.payload);
                w.loops += 1;
                try w.scoped(ir.bodySlice(x.end, x.data.body_len), cold);
                w.loops -= 1;
                return;
            },
            .cond_br => {
                const x = ir.extraData(Ir.CondBr, data.pl_op.payload);
                const then_body = ir.bodySlice(x.end, x.data.then_body_len);
                const else_body = ir.bodySlice(x.end + then_body.len, x.data.else_body_len);
                try w.scoped(then_body, cold or isCold(ir, then_body));
                try w.scoped(else_body, cold or isCold(ir, else_body));
                return;
            },
            .switch_br => {
                const x = ir.extraData(Ir.SwitchBr, data.pl_op.payload);
                var i = x.end;
                for (0..x.data.cases_len) |_| {
                    const items_len = ir.extra[i];
                    const body_len = ir.extra[i + 1];
                    i += 2 + items_len;
                    const case = ir.bodySlice(i, body_len);
                    try w.scoped(case, cold or isCold(ir, case));
                    i += body_len;
                }
                const else_body = ir.bodySlice(i, x.data.else_body_len);
                try w.scoped(else_body, cold or isCold(ir, else_body));
                return;
            },
            .store => {
                if (data.bin_op.lhs.toIndex()) |p| if (s.variable.items[@backingInt(p)]) {
                    _ = s.table.remove(.{ .tag = .load, .ty = 0, .l = @backingInt(p), .r = 0 });
                    return;
                };
                w.forget();
                return;
            },
            // Writes to memory (an atomic load orders later reads).
            .call, .memcpy, .memmove, .memset, .atomic_store, .atomic_rmw, .cmpxchg, .atomic_load, .assembly => w.forget(),
            .vector_store_elem, .set_union_tag, .optional_payload_ptr_set, .errunion_payload_ptr_set => w.forget(),
            .c_va_start, .c_va_arg, .c_va_copy, .set_err_return_trace, .breakpoint => w.forget(),
            else => {},
        }
        if (cold) return;
        const k = w.key(inst, tag, data) orelse return;
        const gop = try s.table.getOrPut(w.gpa, k);
        if (gop.found_existing) {
            if (gop.value_ptr.loops != w.loops) return;
            s.subst.items[@backingInt(inst)] = gop.value_ptr.inst.toRef();
            w.stats.removed += 1;
            return;
        }
        gop.value_ptr.* = .{ .inst = inst, .loops = w.loops };
        try s.added.append(w.gpa, k);
        switch (tag) {
            .load => if (k.r != 0) try s.reads.append(w.gpa, k),
            .ptr_elem_val, .slice_elem_val => try s.reads.append(w.gpa, k),
            else => {},
        }
    }

    /// Forgets the reads of memory: something wrote to it.
    fn forget(w: *Walker) void {
        const s = w.s;
        for (s.reads.items) |k| _ = s.table.remove(k);
        s.reads.clearRetainingCapacity();
    }

    /// The operation `inst` computes, if it is one to share.
    fn key(w: *const Walker, inst: Inst.Index, tag: Inst.Tag, data: Inst.Data) ?Key {
        const ir = w.ir;
        switch (tag) {
            .load => {
                if (!w.scalar(data.ty_op.ty)) return null;
                const ptr = data.ty_op.operand;
                if (ptr.toIndex()) |p| if (w.s.variable.items[@backingInt(p)]) {
                    return .{ .tag = .load, .ty = 0, .l = @backingInt(p), .r = 0 };
                };
                if (Type.ptrInfo(w.ip, ir.typeOf(ptr, w.ip)).flags.is_volatile) return null;
                return .{ .tag = .load, .ty = @backingInt(data.ty_op.ty), .l = @backingInt(ptr), .r = 1 };
            },
            .ptr_elem_val, .slice_elem_val => {
                const ty = ir.typeOfIndex(inst, w.ip);
                if (!w.scalar(ty)) return null;
                if (Type.ptrInfo(w.ip, ir.typeOf(data.bin_op.lhs, w.ip)).flags.is_volatile) return null;
                return .{ .tag = tag, .ty = @backingInt(ty), .l = @backingInt(data.bin_op.lhs), .r = @backingInt(data.bin_op.rhs) };
            },
            .add_wrap, .mul_wrap, .bit_and, .bit_or, .xor => {
                if (!w.scalar(ir.typeOfIndex(inst, w.ip))) return null;
                const a = @backingInt(data.bin_op.lhs);
                const b = @backingInt(data.bin_op.rhs);
                return .{ .tag = tag, .ty = 0, .l = @min(a, b), .r = @max(a, b) };
            },
            .sub_wrap, .shl, .shr => {
                if (!w.scalar(ir.typeOfIndex(inst, w.ip))) return null;
                return .{ .tag = tag, .ty = 0, .l = @backingInt(data.bin_op.lhs), .r = @backingInt(data.bin_op.rhs) };
            },
            .intcast, .trunc, .bitcast, .not, .slice_ptr, .slice_len, .optional_payload, .unwrap_errunion_payload, .unwrap_errunion_err => {
                if (!w.scalar(data.ty_op.ty)) return null;
                return .{ .tag = tag, .ty = @backingInt(data.ty_op.ty), .l = @backingInt(data.ty_op.operand), .r = 0 };
            },
            .int_from_ptr, .int_from_bool => return .{ .tag = tag, .ty = 0, .l = @backingInt(data.un_op), .r = 0 },
            .struct_field_val, .struct_field_ptr => {
                if (!w.scalar(data.ty_pl.ty)) return null;
                return .{ .tag = tag, .ty = @backingInt(data.ty_pl.ty), .l = ir.extra[data.ty_pl.payload], .r = ir.extra[data.ty_pl.payload + 1] };
            },
            .ptr_elem_ptr, .slice_elem_ptr, .ptr_add => {
                if (!w.scalar(data.ty_pl.ty)) return null;
                return .{ .tag = tag, .ty = @backingInt(data.ty_pl.ty), .l = ir.extra[data.ty_pl.payload], .r = ir.extra[data.ty_pl.payload + 1] };
            },
            else => return null,
        }
    }

    /// Whether a value of type `ty` is one general-purpose register.
    fn scalar(w: *const Walker, ty: Index) bool {
        return switch (Type.class(w.ip, ty)) {
            .int => Type.intInfo(w.ip, ty).bits <= 64,
            .bool, .@"enum", .error_set => Type.abiSize(w.ip, ty) <= 8,
            .pointer => !Type.isSlice(w.ip, ty),
            else => false,
        };
    }
};

/// Whether a body is cold code: it ends in `unreach` or `trap`.
fn isCold(ir: *const Ir, body: []const Inst.Index) bool {
    if (body.len == 0) return false;
    return switch (ir.instructions.items(.tag)[@backingInt(body[body.len - 1])]) {
        .unreach, .trap => true,
        else => false,
    };
}
