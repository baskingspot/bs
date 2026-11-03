//! Text dump of the typed IR, for tests and `--debug-dump-ir`.
//!
//! ```
//! fn root:main.zig:add(i32, i32) i32 {
//!   %0 = arg(i32, 0)
//!   %2 = add_with_overflow(struct { i32, u1 }, %0, %1)
//!   ...
//! }
//! ```

const std = @import("std");
const Writer = std.Io.Writer;
const InternPool = @import("../InternPool.zig");
const Ir = @import("../Ir.zig");
const Inst = Ir.Inst;

pub fn dump(ir: *const Ir, ip: *const InternPool, w: *Writer) Writer.Error!void {
    const func = ip.indexToKey(ir.func).func;
    const fn_ty = ip.indexToKey(func.ty).func_type;
    try w.writeAll("fn ");
    try printFuncName(ip, ir.func, w);
    try w.writeAll("(");
    for (fn_ty.param_types, 0..) |p, i| {
        if (i != 0) try w.writeAll(", ");
        try printType(ip, p, w);
    }
    try w.writeAll(") ");
    try printType(ip, fn_ty.return_type, w);
    if (fn_ty.cc != .auto) try w.print(" callconv(.{s})", .{@tagName(fn_ty.cc)});
    try w.writeAll(" {\n");
    const p: Printer = .{ .ir = ir, .ip = ip, .w = w };
    try p.body(ir.mainBody(), 1);
    try w.writeAll("}\n");
}

const Printer = struct {
    ir: *const Ir,
    ip: *const InternPool,
    w: *Writer,

    fn body(p: Printer, insts: []const Inst.Index, indent: usize) Writer.Error!void {
        for (insts) |i| {
            try p.w.splatByteAll(' ', indent * 2);
            try p.w.print("%{d} = ", .{@backingInt(i)});
            try p.inst(i, indent);
            try p.w.writeAll("\n");
        }
    }

    fn ref(p: Printer, r: Inst.Ref) Writer.Error!void {
        if (r == .none) return p.w.writeAll("none");
        if (r.toIndex()) |i| return p.w.print("%{d}", .{@backingInt(i)});
        const val = r.toInterned().?;
        try p.w.writeAll("<");
        try printType(p.ip, p.ip.typeOf(val), p.w);
        try p.w.writeAll(", ");
        try printValue(p.ip, val, p.w);
        try p.w.writeAll(">");
    }

    fn ty(p: Printer, t: InternPool.Index) Writer.Error!void {
        try printType(p.ip, t, p.w);
    }

    fn inst(p: Printer, index: Inst.Index, indent: usize) Writer.Error!void {
        const ir = p.ir;
        const w = p.w;
        const tag = ir.instructions.items(.tag)[@backingInt(index)];
        const data = ir.instructions.items(.data)[@backingInt(index)];
        try w.print("{s}(", .{@tagName(tag)});
        switch (tag) {
            .arg => {
                try p.ty(data.arg.ty);
                try w.print(", {d}", .{data.arg.index});
            },
            .alloc => try p.ty(data.ty),
            .unreach, .trap, .ret_addr, .frame_addr => {},
            .dbg_stmt => try w.print("{d}:{d}", .{ data.dbg_stmt.line + 1, data.dbg_stmt.column + 1 }),
            .ret, .int_from_bool, .int_from_ptr, .error_name, .is_null, .is_non_null, .is_err, .is_non_err, .neg_float, .sqrt, .sin, .cos, .tan, .exp, .exp2, .log, .log2, .log10, .abs_float, .floor, .ceil, .round, .trunc_float => try p.ref(data.un_op),
            .store, .atomic_store, .set_union_tag, .memcpy, .memmove, .memset, .add_wrap, .sub_wrap, .mul_wrap, .add_float, .sub_float, .mul_float, .div_float, .min_float, .max_float, .div_trunc, .div_floor, .div_ceil, .rem, .mod, .bit_and, .bit_or, .xor, .shl, .shr, .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq, .ptr_elem_val, .slice_elem_val, .array_elem_val => {
                try p.ref(data.bin_op.lhs);
                try w.writeAll(", ");
                try p.ref(data.bin_op.rhs);
            },
            .load, .atomic_load, .not, .intcast, .trunc, .float_cast, .float_from_int, .int_from_float, .bitcast, .ptr_from_int, .slice_ptr, .slice_len, .optional_payload, .optional_payload_ptr, .optional_payload_ptr_set, .wrap_optional, .unwrap_errunion_payload, .unwrap_errunion_err, .unwrap_errunion_payload_ptr, .unwrap_errunion_err_ptr, .errunion_payload_ptr_set, .wrap_errunion_payload, .wrap_errunion_err, .get_union_tag, .tag_name, .clz, .ctz, .popcount, .byte_swap, .bit_reverse => {
                try p.ty(data.ty_op.ty);
                try w.writeAll(", ");
                try p.ref(data.ty_op.operand);
            },
            .add_with_overflow, .sub_with_overflow, .mul_with_overflow, .ptr_elem_ptr, .slice_elem_ptr, .slice, .ptr_add => {
                const bin = ir.extraData(Ir.Bin, data.ty_pl.payload).data;
                try p.ty(data.ty_pl.ty);
                try w.writeAll(", ");
                try p.ref(bin.lhs);
                try w.writeAll(", ");
                try p.ref(bin.rhs);
            },
            .mul_add => {
                const bin = ir.extraData(Ir.Bin, data.pl_op.payload).data;
                try p.ref(bin.lhs);
                try w.writeAll(", ");
                try p.ref(bin.rhs);
                try w.writeAll(", ");
                try p.ref(data.pl_op.operand);
            },
            .struct_field_ptr, .struct_field_val, .union_init => {
                const sf = ir.extraData(Ir.StructField, data.ty_pl.payload).data;
                try p.ty(data.ty_pl.ty);
                try w.writeAll(", ");
                try p.ref(sf.operand);
                try w.print(", {d}", .{sf.index});
            },
            .block, .loop => {
                const b = ir.extraData(Ir.Block, data.ty_pl.payload);
                try p.ty(data.ty_pl.ty);
                try w.writeAll(", ");
                try p.braced(ir.bodySlice(b.end, b.data.body_len), indent);
            },
            .atomic_rmw => {
                const x = ir.extraData(Ir.AtomicRmw, data.ty_pl.payload).data;
                try p.ty(data.ty_pl.ty);
                try w.print(", {t}, ", .{x.operation()});
                try p.ref(x.ptr);
                try w.writeAll(", ");
                try p.ref(x.operand);
            },
            .cmpxchg => {
                const x = ir.extraData(Ir.Cmpxchg, data.ty_pl.payload).data;
                try p.ty(data.ty_pl.ty);
                try w.writeAll(", ");
                try p.ref(x.ptr);
                try w.writeAll(", ");
                try p.ref(x.expected);
                try w.writeAll(", ");
                try p.ref(x.new);
            },
            .extern_ptr => {
                try p.ty(data.ty_pl.ty);
                try w.print(", \"{s}\"", .{p.ip.stringSlice(@fromBackingInt(data.ty_pl.payload))});
            },
            .repeat => try w.print("%{d}", .{@backingInt(data.repeat.loop_inst)}),
            .br => {
                try w.print("%{d}, ", .{@backingInt(data.br.block_inst)});
                try p.ref(data.br.operand);
            },
            .cond_br => {
                const cb = ir.extraData(Ir.CondBr, data.pl_op.payload);
                try p.ref(data.pl_op.operand);
                try w.writeAll(", ");
                try p.braced(ir.bodySlice(cb.end, cb.data.then_body_len), indent);
                try w.writeAll(", ");
                try p.braced(ir.bodySlice(cb.end + cb.data.then_body_len, cb.data.else_body_len), indent);
            },
            .switch_br => {
                const sb = ir.extraData(Ir.SwitchBr, data.pl_op.payload);
                try p.ref(data.pl_op.operand);
                var i = sb.end;
                for (0..sb.data.cases_len) |_| {
                    const items_len = ir.extra[i];
                    const body_len = ir.extra[i + 1];
                    i += 2;
                    try w.writeAll(", [");
                    for (ir.refSlice(i, items_len), 0..) |item, j| {
                        if (j != 0) try w.writeAll(", ");
                        try p.ref(item);
                    }
                    i += items_len;
                    try w.writeAll("] => ");
                    try p.braced(ir.bodySlice(i, body_len), indent);
                    i += body_len;
                }
                try w.writeAll(", else => ");
                try p.braced(ir.bodySlice(i, sb.data.else_body_len), indent);
            },
            .panic => {
                try w.print("{s}", .{@tagName(data.panic.id)});
                switch (data.panic.id) {
                    .out_of_bounds, .start_greater_than_end, .unwrap_error, .explicit => {
                        const bin = ir.extraData(Ir.Bin, data.panic.payload).data;
                        try w.writeAll(", ");
                        try p.ref(bin.lhs);
                        if (bin.rhs != .none) {
                            try w.writeAll(", ");
                            try p.ref(bin.rhs);
                        }
                    },
                    else => {},
                }
            },
            .call => {
                const c = ir.extraData(Ir.Call, data.pl_op.payload);
                try p.ref(data.pl_op.operand);
                try w.writeAll(", [");
                for (ir.refSlice(c.end, c.data.args_len), 0..) |arg, i| {
                    if (i != 0) try w.writeAll(", ");
                    try p.ref(arg);
                }
                try w.writeAll("]");
            },
            .aggregate_init => {
                const a = ir.extraData(Ir.Aggregate, data.ty_pl.payload);
                try p.ty(data.ty_pl.ty);
                try w.writeAll(", [");
                for (ir.refSlice(a.end, a.data.len), 0..) |e, i| {
                    if (i != 0) try w.writeAll(", ");
                    try p.ref(e);
                }
                try w.writeAll("]");
            },
            .assembly => {
                const a = ir.extraData(Ir.Asm, data.ty_pl.payload);
                try p.ty(data.ty_pl.ty);
                if (a.data.is_volatile != 0) try w.writeAll(", volatile");
                try w.print(", \"{f}\"", .{std.zig.fmtString(p.ip.stringSlice(a.data.source))});
                var i = a.end;
                for (0..a.data.outputs_len + a.data.inputs_len) |n| {
                    const o = ir.extraData(Ir.Asm.Operand, i);
                    i = o.end;
                    try w.print(", {s} [{s}] \"{s}\" ", .{
                        if (n < a.data.outputs_len) "out" else "in",
                        p.ip.stringSlice(o.data.name),
                        p.ip.stringSlice(o.data.constraint),
                    });
                    if (o.data.operand == .none) try w.writeAll("->") else try p.ref(o.data.operand);
                }
            },
        }
        try w.writeAll(")");
    }

    fn braced(p: Printer, insts: []const Inst.Index, indent: usize) Writer.Error!void {
        if (insts.len == 0) return p.w.writeAll("{}");
        try p.w.writeAll("{\n");
        try p.body(insts, indent + 1);
        try p.w.splatByteAll(' ', indent * 2);
        try p.w.writeAll("}");
    }
};

pub fn printType(ip: *const InternPool, ty: InternPool.Index, w: *Writer) Writer.Error!void {
    if (ty == .none) return w.writeAll("<none>");
    switch (ip.indexToKey(ty)) {
        .int_type => |t| try w.print("{c}{d}", .{ @as(u8, if (t.signedness == .signed) 'i' else 'u'), t.bits }),
        .simple_type => |t| try w.writeAll(switch (t) {
            .calling_convention => "std.lang.CallingConvention",
            .clobbers => "std.lang.Clobbers",
            .null => "@TypeOf(null)",
            .undefined => "@TypeOf(undefined)",
            .enum_literal => "@EnumLiteral()",
            .generic_poison => "(generic poison)",
            .adhoc_inferred_error_set => "(inferred error set)",
            else => @tagName(t),
        }),
        .ptr_type => |p| {
            switch (p.flags.size) {
                .one => try w.writeAll("*"),
                .many => try w.writeAll("[*"),
                .slice => try w.writeAll("["),
                .c => try w.writeAll("[*c"),
            }
            if (p.flags.size != .one) {
                if (p.sentinel != .none) {
                    try w.writeAll(":");
                    try printValue(ip, p.sentinel, w);
                }
                try w.writeAll("]");
            }
            if (p.flags.alignment != 0) try w.print("align({d}) ", .{@as(u64, 1) << (p.flags.alignment - 1)});
            if (p.flags.is_allowzero) try w.writeAll("allowzero ");
            if (p.flags.is_const) try w.writeAll("const ");
            if (p.flags.is_volatile) try w.writeAll("volatile ");
            try printType(ip, p.child, w);
        },
        .array_type => |a| {
            try w.print("[{d}", .{a.len});
            if (a.sentinel != .none) {
                try w.writeAll(":");
                try printValue(ip, a.sentinel, w);
            }
            try w.writeAll("]");
            try printType(ip, a.child, w);
        },
        .vector_type => |v| {
            try w.print("@Vector({d}, ", .{v.len});
            try printType(ip, v.child, w);
            try w.writeAll(")");
        },
        .opt_type => |c| {
            try w.writeAll("?");
            try printType(ip, c, w);
        },
        .anyframe_type => |c| {
            try w.writeAll("anyframe");
            if (c != .none) {
                try w.writeAll("->");
                try printType(ip, c, w);
            }
        },
        .error_union_type => |e| {
            try printType(ip, e.error_set_type, w);
            try w.writeAll("!");
            try printType(ip, e.payload_type, w);
        },
        .error_set_type => |names| {
            try w.writeAll("error{");
            for (names, 0..) |n, i| {
                if (i != 0) try w.writeAll(",");
                try w.writeAll(ip.stringSlice(n));
            }
            try w.writeAll("}");
        },
        .inferred_error_set_type => |f| {
            try w.print("@typeInfo(@typeInfo(@TypeOf({s})).@\"fn\".return_type.?).error_union.error_set", .{
                ip.stringSlice(ip.getNav(ip.indexToKey(f).func.owner_nav).fqn),
            });
        },
        .struct_type, .enum_type, .union_type, .opaque_type => |s| try w.writeAll(ip.stringSlice(s.name)),
        .tuple_type => |t| {
            if (t.names.len != 0) return w.writeAll(ip.stringSlice(t.name));
            try w.writeAll("struct {");
            for (t.types, t.values, 0..) |ft, fv, i| {
                try w.writeAll(if (i == 0) " " else ", ");
                if (fv != .none) try w.writeAll("comptime ");
                try printType(ip, ft, w);
                if (fv != .none) {
                    try w.writeAll(" = ");
                    try printValue(ip, fv, w);
                }
            }
            try w.writeAll(if (t.types.len == 0) "}" else " }");
        },
        .func_type => |f| {
            try w.writeAll("fn (");
            for (f.param_types, 0..) |pt, i| {
                if (i != 0) try w.writeAll(", ");
                if ((f.comptime_bits >> @intCast(i)) & 1 != 0) try w.writeAll("comptime ");
                try printType(ip, pt, w);
            }
            try w.writeAll(") ");
            if (f.cc != .auto) try w.print("callconv(.{s}) ", .{@tagName(f.cc)});
            try printType(ip, f.return_type, w);
        },
        else => try w.writeAll("<not a type>"),
    }
}

pub fn printValue(ip: *const InternPool, val: InternPool.Index, w: *Writer) Writer.Error!void {
    if (val == .none) return w.writeAll("<none>");
    switch (ip.indexToKey(val)) {
        .simple_value => |v| try w.writeAll(@tagName(v)),
        .undef => try w.writeAll("undefined"),
        .int => |int| switch (int.storage) {
            .u64 => |v| try w.print("{d}", .{v}),
            .i64 => |v| try w.print("{d}", .{v}),
            .big => |b| try w.print("{f}", .{b}),
        },
        // As upstream prints them: through f64.
        .float => |f| switch (f.storage) {
            inline else => |x| try w.print("{d}", .{@as(f64, @floatCast(x))}),
        },
        .err => |e| try w.print("error.{s}", .{ip.stringSlice(e.name)}),
        .error_union => |e| switch (e.val) {
            .err_name => |n| try w.print("error.{s}", .{ip.stringSlice(n)}),
            .payload => |p| try printValue(ip, p, w),
        },
        .enum_literal => |s| try w.print(".{s}", .{ip.stringSlice(s)}),
        .calling_convention => |cc| try w.print(".{s}", .{@tagName(cc)}),
        .ptr => |p| {
            switch (p.base) {
                .nav => |n| try w.print("&{s}", .{ip.stringSlice(ip.getNav(n).fqn)}),
                .uav => |u| {
                    try w.writeAll("&");
                    try printValue(ip, u.val, w);
                },
                .comptime_alloc => |c| try w.print("&(comptime alloc {d})", .{c}),
                .int => try w.writeAll("@ptrFromInt(0)"),
                .field => |f| {
                    try w.writeAll("&(");
                    try printValue(ip, f.base, w);
                    try w.print(").field[{d}]", .{f.index});
                },
                .elem => |e| {
                    try w.writeAll("&(");
                    try printValue(ip, e.base, w);
                    try w.print(")[{d}]", .{e.index});
                },
            }
            if (p.byte_offset != 0) try w.print(" + {d}", .{p.byte_offset});
        },
        .slice => |s| {
            try printValue(ip, s.ptr, w);
            try w.writeAll("[0..");
            try printValue(ip, s.len, w);
            try w.writeAll("]");
        },
        .opt => |o| if (o.val == .none) try w.writeAll("null") else try printValue(ip, o.val, w),
        .aggregate => |a| switch (a.storage) {
            .bytes => |s| try w.print("\"{f}\"", .{std.zig.fmtString(ip.stringSlice(s))}),
            .repeated_elem => |e| {
                try w.writeAll(".{ ");
                try printValue(ip, e, w);
                try w.writeAll("** }");
            },
            .elems => |elems| {
                try w.writeAll(".{");
                for (elems, 0..) |e, i| {
                    try w.writeAll(if (i == 0) " " else ", ");
                    try printValue(ip, e, w);
                }
                try w.writeAll(if (elems.len == 0) "}" else " }");
            },
        },
        .func => try printFuncName(ip, val, w),
        else => try printType(ip, val, w),
    }
}

/// A function's declaration name, followed by the comptime arguments of a
/// generic instance in brackets.
fn printFuncName(ip: *const InternPool, func_index: InternPool.Index, w: *Writer) Writer.Error!void {
    const func = ip.indexToKey(func_index).func;
    try w.writeAll(ip.stringSlice(ip.getNav(func.owner_nav).fqn));
    if (func.comptime_args.len == 0) return;
    try w.writeAll("[");
    var first = true;
    for (func.comptime_args) |arg| {
        if (arg == .none) continue;
        if (!first) try w.writeAll(", ");
        first = false;
        try printValue(ip, arg, w);
    }
    try w.writeAll("]");
}
