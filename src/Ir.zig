//! The typed IR of one function instance, produced by Sema and consumed by
//! CodeGen, then freed. Never persisted (see docs/slop/architecture.md).
//!
//! Flat arrays in SSA form, like upstream AIR: an instruction's operands are
//! other instructions or InternPool values. Control flow is structured:
//! `block`/`br`, `loop`/`repeat`, `cond_br`, and `switch_br` nest bodies, and
//! every body ends with a `noreturn` instruction. Safety checks are explicit
//! (`cond_br` to a call of a `std.lang.panic` handler), so CodeGen never decides semantics. The IR is
//! target-independent and precise enough to interpret.

const std = @import("std");
const assert = std.debug.assert;
const InternPool = @import("InternPool.zig");

const Ir = @This();

instructions: std.MultiArrayList(Inst).Slice,
extra: []const u32,
/// The function instance this IR is the body of.
func: InternPool.Index,
/// Index into `extra` of the main body's `Block` payload.
main_block: u32,
/// The function's closing brace, relative to its declaration like
/// `dbg_stmt`, for the epilogue's line row.
rbrace_line: u32 = 0,
rbrace_column: u32 = 0,
/// The body called `@disableInstrumentation()`: no coverage points under
/// `-ffuzz`.
disable_instrumentation: bool = false,

pub fn deinit(ir: *Ir, gpa: std.mem.Allocator) void {
    ir.instructions.deinit(gpa);
    gpa.free(ir.extra);
    ir.* = undefined;
}

pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Index = enum(u32) {
        _,

        pub fn toRef(i: Index) Ref {
            return @fromBackingInt(@backingInt(i) | ref_inst_bit);
        }
    };

    /// An instruction result or an interned value. The top bit selects an
    /// instruction; InternPool indices use only 31 bits.
    pub const Ref = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn toIndex(r: Ref) ?Index {
            assert(r != .none);
            const raw = @backingInt(r);
            return if (raw & ref_inst_bit != 0) @fromBackingInt(raw & ~ref_inst_bit) else null;
        }

        pub fn toInterned(r: Ref) ?InternPool.Index {
            assert(r != .none);
            const raw = @backingInt(r);
            return if (raw & ref_inst_bit == 0) @fromBackingInt(raw) else null;
        }

        pub fn fromInterned(i: InternPool.Index) Ref {
            assert(@backingInt(i) & ref_inst_bit == 0);
            return @fromBackingInt(@backingInt(i));
        }

        pub const void_value: Ref = .fromInterned(.void_value);
        pub const unreachable_value: Ref = .fromInterned(.unreachable_value);
        pub const zero: Ref = .fromInterned(.zero);
        pub const zero_u1: Ref = .fromInterned(.zero_u1);
    };

    const ref_inst_bit: u32 = 1 << 31;

    pub const Tag = enum(u8) {
        /// Function parameter `arg.index` of type `arg.ty`. Only at the start
        /// of the main body.
        arg,
        /// A stack allocation. `ty` is the resulting pointer type.
        alloc,
        /// `ty_op`: load a `ty` from pointer `operand`.
        load,
        /// `bin_op`: store `rhs` through pointer `lhs`. An undefined `rhs`
        /// fills the memory with 0xaa, as upstream does in Debug builds.
        store,

        /// `bin_op`: two's complement wrapping arithmetic on integers of the
        /// operand type.
        add_wrap,
        sub_wrap,
        mul_wrap,
        /// `ty_pl` with `Bin`: result is a tuple `{ T, u1 }` of the wrapped
        /// result and whether the operation overflowed.
        add_with_overflow,
        sub_with_overflow,
        mul_with_overflow,
        /// `bin_op`: IEEE float arithmetic, rounding to nearest even.
        add_float,
        sub_float,
        mul_float,
        div_float,
        /// `bin_op`: division and remainder of integers or floats. For
        /// integers, the divisor is non-zero and the quotient fits; Sema
        /// emits the checks. For floats, `div_trunc`/`div_floor`/`div_ceil`
        /// round the IEEE quotient, `rem` has the sign of the dividend
        /// (C `fmod`), and `mod` the sign of the divisor.
        div_trunc,
        div_floor,
        /// Rounds toward positive infinity.
        div_ceil,
        rem,
        mod,
        /// `bin_op`: `@min` and `@max` of floats: a NaN operand yields the
        /// other operand (C `fmin`/`fmax`).
        min_float,
        max_float,
        /// `un_op`: unary float math on an operand of float type: negation
        /// (sign flip), the `@sqrt`... `@round` builtins, and `@abs`.
        neg_float,
        sqrt,
        sin,
        cos,
        tan,
        exp,
        exp2,
        log,
        log2,
        log10,
        abs_float,
        floor,
        ceil,
        round,
        trunc_float,
        /// `pl_op` with `Bin`: `@mulAdd(lhs, rhs, operand)`, fused.
        mul_add,
        /// `bin_op`: bitwise operations on integers or bools.
        bit_and,
        bit_or,
        xor,
        /// `bin_op`: shifts. `rhs` is less than the bit width of `lhs`'s type.
        /// `shr` is arithmetic for signed types.
        shl,
        shr,
        /// `ty_op`: bitwise NOT for integers, logical NOT for bools.
        not,
        /// `bin_op`: comparisons of integers, floats, bools, or pointers;
        /// result `bool`. Float comparisons with a NaN are false, except
        /// `cmp_neq`.
        cmp_lt,
        cmp_lte,
        cmp_eq,
        cmp_gte,
        cmp_gt,
        cmp_neq,

        // Vectors. Where `codegen/vector.zig` says the target's backend
        // lowers an operation natively, Sema emits it on whole vectors:
        // `add_wrap`, `sub_wrap`, `mul_wrap`, `bit_and`, `bit_or`, `xor`,
        // `not`, and the float arithmetic (`add_float` ... `max_float`,
        // `neg_float`, `abs_float`, `sqrt`) element by element on operands
        // of one vector type, `load`, `store`, and `bitcast` on the whole
        // value, and the instructions below. Other vector operations are
        // scalarized by Sema.

        /// `ty_pl` with `VectorCmp`: compares two vectors element by
        /// element; the result, of bool vector type `ty`, has element `i`
        /// set if `lhs[i] op rhs[i]` (with float NaNs as for `cmp_*`).
        cmp_vector,
        /// `ty_pl` with `Reduce`: the vector's elements folded with `op`,
        /// of element type `ty`, left to right in element order (which
        /// float `add` and `mul` observe; float `min` and `max` are
        /// `min_float` and `max_float`).
        reduce,
        /// `bin_op`: `@min` and `@max` of integer vectors, element by
        /// element. (Sema lowers scalar integer `@min` and `@max` to a
        /// compare and a select.)
        min_int,
        max_int,
        /// `ty_pl` with `Select`: the vector of type `ty` whose element `i`
        /// is `a[i]` where bool vector `pred` has element `i` set, else
        /// `b[i]`.
        select,
        /// `ty_pl` with `Shuffle`: the vector of type `ty` whose element
        /// `i` is `a[m]` for a mask element `m >= 0`, `b[~m]` for `m < 0`,
        /// and undefined for an undefined mask element.
        shuffle,

        /// `ty_op`: integer conversion that preserves the value (checked by
        /// Sema when it might not).
        intcast,
        /// `ty_op`: keep the low bits of an integer.
        trunc,
        /// `ty_op`: convert a float to another float type, rounding to
        /// nearest even when narrowing.
        float_cast,
        /// `ty_op`: integer to float, rounding to nearest even.
        float_from_int,
        /// `ty_op`: float to integer, truncating toward zero. The truncated
        /// value fits the integer type; Sema emits the check.
        int_from_float,
        /// `ty_op`: reinterpret the bits of a value of the same size.
        bitcast,
        /// `ty_op`: count leading / trailing zeros, count ones, of integer
        /// `operand`; the result has type `ty`.
        clz,
        ctz,
        popcount,
        /// `ty_op`: reverse the bytes / bits of integer `operand`.
        byte_swap,
        bit_reverse,
        /// `un_op`: `bool` to `u1`.
        int_from_bool,
        /// `un_op`: pointer to `usize`.
        int_from_ptr,
        /// `un_op`: an error's name, a `[:0]const u8`, from the table the
        /// linker gets once every error code is assigned.
        error_name,
        /// `ty_op`: `usize` to pointer.
        ptr_from_int,
        /// `ty_op`: atomically load a `ty` from pointer `operand`.
        atomic_load,
        /// `bin_op`: atomically store `rhs` through pointer `lhs`
        /// (sequentially consistent, which covers every ordering).
        atomic_store,
        /// `ty_pl` with `AtomicRmw`: atomically replace `*ptr` with
        /// `op(*ptr, operand)`; the result is the old value, of type `ty`.
        atomic_rmw,
        /// `ty_pl` with `Cmpxchg`: if `*ptr == expected`, store `new`. The
        /// result, of optional type `ty`, is null on success, else the value
        /// found. Strong (x86's cmpxchg never fails spuriously).
        cmpxchg,
        /// `no_op`: `@returnAddress()` and `@frameAddress()` of the
        /// function, as `usize`.
        ret_addr,
        frame_addr,
        /// `ty_pl`: the address of the external symbol whose name is the
        /// `InternPool.String` `payload`, as a pointer (or optional pointer,
        /// null for an undefined weak symbol) of type `ty`.
        extern_ptr,
        /// `ty_pl`: as `extern_ptr`, for `@extern` with `.relocation =
        /// .pcrel`: the address computed relative to the instruction, with
        /// no slot and no load-time relocation, so it is right before a
        /// static PIE has relocated itself (std.pie reads `_DYNAMIC` so).
        /// The symbol must be defined in the module the final link makes.
        extern_pcrel,
        /// `ty_pl`: as `extern_ptr`, for a thread-local symbol (`extern
        /// threadlocal var`, `@extern` with `.is_thread_local`): the
        /// address of this thread's copy. Never weak.
        extern_tls,
        /// `ty_pl`: the address of this thread's copy of the threadlocal
        /// variable whose `InternPool.NavIndex` is `payload`.
        tls_ptr,
        /// `ty`: the function's error return trace, a `*StackTrace` or
        /// `?*StackTrace` of type `ty`. An `.auto` function receives it from
        /// its caller; another function sets it with `set_err_return_trace`.
        err_return_trace,
        /// `un_op`: make pointer `operand` the function's error return
        /// trace (at the entry of a non-`.auto` function that needs one).
        set_err_return_trace,
        /// `ty_pl`: the `usize` field `payload` (`index`) of the error return
        /// trace, whose type is the `StackTrace` `ty`. Sema creates these
        /// before it knows whether a restore uses them: `ty` is `.none` for
        /// an unused one, which has no code.
        save_err_return_trace_index,

        /// `ty_pl` with `Block`: a body that `br` instructions exit with a
        /// value of type `ty`.
        block,
        /// `ty_pl` with `Block`: a body that `repeat` restarts. Exits only
        /// through `br` to an enclosing block, `ret`, or other `noreturn`.
        loop,
        /// `repeat`: jump back to the start of `loop_inst`.
        repeat,
        /// `br`: exit `block_inst` with `operand`.
        br,
        /// `pl_op` with `CondBr`: `operand` is a `bool`.
        cond_br,
        /// `pl_op` with `SwitchBr`: `operand` is an integer or bool.
        switch_br,
        /// `un_op`: return from the function.
        ret,
        /// `no_op`: reaching this is undefined behavior (no safety check).
        unreach,
        /// `no_op`: `@trap()`.
        trap,
        /// `no_op`: `@breakpoint()`, which returns.
        breakpoint,
        /// `ty`: `@cVaStart()` in a variadic C function, a `VaList` of type
        /// `ty` for the arguments after the named ones.
        c_va_start,
        /// `ty_op`: `@cVaArg`, the next variadic argument, of type `ty`, from
        /// the `VaList` that `operand` points to.
        c_va_arg,
        /// `ty_op`: `@cVaCopy`, a copy of the `VaList` `operand` points to.
        c_va_copy,

        /// `pl_op` with `Call`: `operand` is the callee function value, or a
        /// function pointer for an indirect call.
        call,

        /// `ty_pl` with `StructField`: pointer to a field of the struct (or
        /// tuple) `operand` points to.
        struct_field_ptr,
        /// `ty_pl` with `StructField`: a field of struct value `operand`.
        struct_field_val,
        /// `ty_pl` with `Bin`: pointer to element `rhs` of what pointer `lhs`
        /// points to (`*[N]T` or `[*]T`).
        ptr_elem_ptr,
        /// `pl_op` with `Bin`: store `rhs` as element `lhs` (a `usize`) of
        /// the vector `operand` points to. Elements of bool vectors are
        /// bits and have no pointers; Sema's vector loops use this for all
        /// vectors (as upstream's `legalize_vec_store_elem`).
        vector_store_elem,
        /// `bin_op`: load element `rhs` through `*[N]T` or `[*]T` `lhs`.
        ptr_elem_val,
        /// `ty_pl` with `Bin`: pointer to element `rhs` of slice `lhs`.
        slice_elem_ptr,
        /// `bin_op`: element `rhs` of slice `lhs`.
        slice_elem_val,
        /// `bin_op`: element `rhs` of array value `lhs`.
        array_elem_val,
        /// `ty_op`: the pointer of a slice.
        slice_ptr,
        /// `ty_op`: the length of a slice.
        slice_len,
        /// `ty_pl` with `Bin`: build a slice from pointer `lhs` and length `rhs`.
        slice,
        /// `ty_pl` with `Bin`: advance pointer `lhs` by `rhs` elements.
        ptr_add,

        /// `un_op`: whether an optional is null / non-null.
        is_null,
        is_non_null,
        /// `ty_op`: the payload of a non-null optional.
        optional_payload,
        /// `ty_op`: pointer to the payload of the optional `operand` points to.
        optional_payload_ptr,
        /// `ty_op`: like `optional_payload_ptr`, also marking it non-null.
        optional_payload_ptr_set,
        /// `ty_op`: wrap a payload into a non-null optional.
        wrap_optional,
        /// `un_op`: whether an error union holds an error / a payload.
        is_err,
        is_non_err,
        /// `ty_op`: the payload of an error union holding a payload.
        unwrap_errunion_payload,
        /// `ty_op`: the error of an error union.
        unwrap_errunion_err,
        /// `ty_op`: pointer to the payload / error of what `operand` points to.
        unwrap_errunion_payload_ptr,
        unwrap_errunion_err_ptr,
        /// `ty_op`: like `unwrap_errunion_payload_ptr`, also clearing the error.
        errunion_payload_ptr_set,
        /// `ty_op`: build an error union from a payload / an error.
        wrap_errunion_payload,
        wrap_errunion_err,

        /// `ty_pl` with `Aggregate`: build an array, struct, or tuple value.
        aggregate_init,
        /// `ty_pl` with `StructField`: a union value with field `index`
        /// active, holding `operand`. (`struct_field_ptr`/`struct_field_val`
        /// also address union payloads.)
        union_init,
        /// `ty_op`: the tag of union value `operand`.
        get_union_tag,
        /// `bin_op`: store tag `rhs` into the union `lhs` points to.
        set_union_tag,
        /// `bin_op`: copy the elements `rhs` points to into `lhs`. `lhs` is a
        /// slice or `*[N]T` and gives the length; `rhs` is a many-pointer or
        /// `*[N]T` of the same element type. A comptime-known length is not 0.
        /// For `memcpy` the regions do not overlap; for `memmove` they may.
        memcpy,
        memmove,
        /// `bin_op`: store element `rhs` to every element of slice or `*[N]T`
        /// `lhs`. A comptime-known length is not 0.
        memset,
        /// `ty_op`: the name (`[:0]const u8`) of enum value `operand`, which
        /// is one of its type's named tags.
        tag_name,
        /// `ty_pl` with `Asm`: inline assembly.
        assembly,
        /// `dbg_stmt`: a statement starts at this line and column, relative
        /// to the function's declaration.
        dbg_stmt,
        /// `dbg_inline` with `DbgInline`: the code up to the matching
        /// `dbg_inline_end` is a call of `func` inlined at the statement
        /// position `line:column`, relative to the enclosing function's (or
        /// inline call's) declaration. `dbg_stmt`s up to there are relative
        /// to `func`'s declaration. Debug info only.
        dbg_inline_begin,
        /// `no_op`: ends the innermost `dbg_inline_begin`.
        dbg_inline_end,

        /// Only in a body lowered for the comptime evaluator (see
        /// docs/slop/architecture.md, "Comptime"), never in CodeGen's IR.
        /// `no_op`: one backward branch against the evaluation's branch
        /// quota, where the ZIR walker counts one (an inline call, an
        /// `inline` loop iteration, a comptime call made while lowering).
        comptime_tick,
        /// `quota`: `@setEvalBranchQuota(quota)`.
        comptime_quota,
        /// `dep`: the code the walker would run here reads dependee `dep`
        /// (an index into the lowered body's dependencies), which the
        /// running unit then declares.
        comptime_dep,
        /// `dep`: the code the walker would run here evaluates a container
        /// type with effects (an index into the lowered body's `effects`),
        /// which the running unit then notes (`Zcu.effect_uses`).
        comptime_effect,
        /// `pl_op`: leave the lowered loop of an on-stack replacement with
        /// `operand` through the ZIR `break` (or `break_inline`)
        /// instruction `payload`, whose target the walker runs.
        comptime_exit,
    };

    pub const Data = union {
        no_op: void,
        un_op: Ref,
        bin_op: struct { lhs: Ref, rhs: Ref },
        ty: InternPool.Index,
        arg: struct { ty: InternPool.Index, index: u32 },
        ty_op: struct { ty: InternPool.Index, operand: Ref },
        ty_pl: struct { ty: InternPool.Index, payload: u32 },
        pl_op: struct { operand: Ref, payload: u32 },
        br: struct { block_inst: Index, operand: Ref },
        repeat: struct { loop_inst: Index },
        dbg_stmt: struct { line: u32, column: u32 },
        dbg_inline: struct { func: InternPool.Index, payload: u32 },
        quota: u32,
        dep: u32,
    };
};

pub const DbgInline = struct {
    line: u32,
    column: u32,
    flags: Flags = .{},

    pub const Flags = packed struct(u32) {
        /// Inlined by the backend (`codegen/inline.zig`), not by Sema: a
        /// panic in it gets the synthetic frames of an uninlined call.
        backend: bool = false,
        _: u31 = 0,
    };
};

pub const Block = struct {
    body_len: u32,
};

/// Trailing: then body, else body.
pub const CondBr = struct {
    then_body_len: u32,
    else_body_len: u32,
    cover: Cover,

    /// Which arms `-ffuzz` makes coverage points (docs/slop/architecture.md,
    /// "Fuzzing"): those of branches the user wrote, as upstream's
    /// `then_cov`/`else_cov`; none for branches Sema adds itself.
    pub const Cover = packed struct(u32) {
        then: bool = false,
        @"else": bool = false,
        _: u30 = 0,

        pub const both: Cover = .{ .then = true, .@"else" = true };
    };
};

/// Trailing: for each case: `items_len`, `body_len`, items (`Ref`, comptime
/// known), body; then the else body.
pub const SwitchBr = struct {
    cases_len: u32,
    else_body_len: u32,
};

/// Trailing: `args_len` `Ref`s.
pub const Call = struct {
    /// The callee's return type, with an inferred error set resolved to
    /// the callee's own (`inferred_error_set_type`).
    ret_ty: InternPool.Index,
    args_len: u32,
    flags: Flags = .{},

    pub const Flags = packed struct(u32) {
        /// `@call(.never_inline, ...)`: CodeGen must not inline the callee.
        never_inline: bool = false,
        _: u31 = 0,
    };
};

pub const Bin = struct {
    lhs: Inst.Ref,
    rhs: Inst.Ref,
};

pub const VectorCmp = struct {
    lhs: Inst.Ref,
    rhs: Inst.Ref,
    /// A `std.math.CompareOperator`.
    op: u32,

    pub fn operator(x: VectorCmp) std.math.CompareOperator {
        return @fromBackingInt(@intCast(x.op));
    }
};

pub const ReduceOp = enum(u32) { @"and", @"or", xor, min, max, add, mul };

pub const Reduce = struct {
    operand: Inst.Ref,
    /// A `ReduceOp`.
    op: u32,

    pub fn operation(x: Reduce) ReduceOp {
        return @fromBackingInt(x.op);
    }
};

pub const Select = struct {
    pred: Inst.Ref,
    a: Inst.Ref,
    b: Inst.Ref,
};

pub const Shuffle = struct {
    a: Inst.Ref,
    /// May be an undefined value when the mask only selects from `a`.
    b: Inst.Ref,
    /// The mask: a comptime-known `@Vector(n, i32)`.
    mask: InternPool.Index,
};

pub const AtomicRmw = struct {
    ptr: Inst.Ref,
    operand: Inst.Ref,
    /// A `std.lang.AtomicRmwOp`.
    op: u32,

    pub fn operation(x: AtomicRmw) std.lang.AtomicRmwOp {
        return @fromBackingInt(@intCast(x.op));
    }
};

pub const Cmpxchg = struct {
    ptr: Inst.Ref,
    expected: Inst.Ref,
    new: Inst.Ref,
};

pub const StructField = struct {
    operand: Inst.Ref,
    index: u32,
};

/// Trailing: `len` `Ref`s.
pub const Aggregate = struct {
    len: u32,
};

/// Trailing: `outputs_len` `Asm.Operand`s, then `inputs_len` `Asm.Operand`s.
/// An output whose `operand` is `.none` is the result of the instruction
/// (`-> T`); otherwise `operand` is a pointer to store the output to.
pub const Asm = struct {
    source: InternPool.String,
    outputs_len: u32,
    inputs_len: u32,
    is_volatile: u32,
    /// The callee-saved registers the clobbers name, as bits in the order
    /// of `callee_saved_names`, which the function must save.
    callee_saved_clobbers: u32,

    pub const callee_saved_names = [_][]const u8{ "rbx", "r12", "r13", "r14", "r15" };

    pub const Operand = struct {
        name: InternPool.String,
        constraint: InternPool.String,
        operand: Inst.Ref,
    };
};

pub fn extraData(ir: *const Ir, comptime T: type, index: usize) struct { data: T, end: usize } {
    const info = @typeInfo(T).@"struct";
    var result: T = undefined;
    inline for (info.field_names, info.field_types, 0..) |name, Field, i| {
        const word = ir.extra[index + i];
        @field(result, name) = switch (Field) {
            u32 => word,
            else => @fromBackingInt(word),
        };
    }
    return .{ .data = result, .end = index + info.field_names.len };
}

pub fn bodySlice(ir: *const Ir, start: usize, len: usize) []const Inst.Index {
    return @ptrCast(ir.extra[start..][0..len]);
}

pub fn refSlice(ir: *const Ir, start: usize, len: usize) []const Inst.Ref {
    return @ptrCast(ir.extra[start..][0..len]);
}

pub fn mainBody(ir: *const Ir) []const Inst.Index {
    const block = ir.extraData(Block, ir.main_block);
    return ir.bodySlice(block.end, block.data.body_len);
}

/// The type of an instruction's result or of an interned value.
pub fn typeOf(ir: *const Ir, ref: Inst.Ref, ip: *const InternPool) InternPool.Index {
    if (ref.toInterned()) |i| return ip.typeOf(i);
    return ir.typeOfIndex(ref.toIndex().?, ip);
}

pub fn typeOfIndex(ir: *const Ir, inst: Inst.Index, ip: *const InternPool) InternPool.Index {
    const data = ir.instructions.items(.data)[@backingInt(inst)];
    return switch (ir.instructions.items(.tag)[@backingInt(inst)]) {
        .arg => data.arg.ty,
        .alloc, .c_va_start, .err_return_trace => data.ty,
        .c_va_arg,
        .c_va_copy,
        .load,
        .not,
        .intcast,
        .trunc,
        .float_cast,
        .float_from_int,
        .int_from_float,
        .bitcast,
        .ptr_from_int,
        .slice_ptr,
        .slice_len,
        .optional_payload,
        .optional_payload_ptr,
        .optional_payload_ptr_set,
        .wrap_optional,
        .unwrap_errunion_payload,
        .unwrap_errunion_err,
        .unwrap_errunion_payload_ptr,
        .unwrap_errunion_err_ptr,
        .errunion_payload_ptr_set,
        .wrap_errunion_payload,
        .wrap_errunion_err,
        .atomic_load,
        .get_union_tag,
        .tag_name,
        .clz,
        .ctz,
        .popcount,
        .byte_swap,
        .bit_reverse,
        => data.ty_op.ty,
        .add_with_overflow,
        .sub_with_overflow,
        .mul_with_overflow,
        .block,
        .loop,
        .struct_field_ptr,
        .struct_field_val,
        .ptr_elem_ptr,
        .slice_elem_ptr,
        .slice,
        .ptr_add,
        .aggregate_init,
        .union_init,
        .assembly,
        .extern_ptr,
        .extern_pcrel,
        .extern_tls,
        .tls_ptr,
        .atomic_rmw,
        .cmpxchg,
        .cmp_vector,
        .reduce,
        .select,
        .shuffle,
        => data.ty_pl.ty,
        .store, .atomic_store, .set_union_tag, .set_err_return_trace, .memcpy, .memmove, .memset, .dbg_stmt, .dbg_inline_begin, .dbg_inline_end, .vector_store_elem, .breakpoint, .comptime_tick, .comptime_quota, .comptime_dep, .comptime_effect => .void_type,
        .comptime_exit => .noreturn_type,
        .add_wrap, .sub_wrap, .mul_wrap, .div_trunc, .div_floor, .div_ceil, .rem, .mod, .bit_and, .bit_or, .xor, .shl, .shr => ir.typeOf(data.bin_op.lhs, ip),
        .add_float, .sub_float, .mul_float, .div_float, .min_float, .max_float, .min_int, .max_int => ir.typeOf(data.bin_op.lhs, ip),
        .neg_float, .sqrt, .sin, .cos, .tan, .exp, .exp2, .log, .log2, .log10, .abs_float, .floor, .ceil, .round, .trunc_float => ir.typeOf(data.un_op, ip),
        .mul_add => ir.typeOf(data.pl_op.operand, ip),
        .cmp_lt, .cmp_lte, .cmp_eq, .cmp_gte, .cmp_gt, .cmp_neq, .is_null, .is_non_null, .is_err, .is_non_err => .bool_type,
        .int_from_bool => .u1_type,
        .int_from_ptr, .ret_addr, .frame_addr, .save_err_return_trace_index => .usize_type,
        .error_name => .slice_const_u8_sentinel_0_type,
        .repeat, .br, .cond_br, .switch_br, .ret, .unreach, .trap => .noreturn_type,
        .call => ir.extraData(Call, data.pl_op.payload).data.ret_ty,
        .ptr_elem_val => blk: {
            const ptr = ip.keyPayload(.ptr_type, ir.typeOf(data.bin_op.lhs, ip));
            break :blk switch (ptr.flags.size) {
                .one => switch (ip.indexToKey(ptr.child)) {
                    .vector_type => |v| v.child,
                    else => |k| k.array_type.child,
                },
                else => ptr.child,
            };
        },
        .slice_elem_val => ip.keyPayload(.ptr_type, ir.typeOf(data.bin_op.lhs, ip)).child,
        .array_elem_val => switch (ip.indexToKey(ir.typeOf(data.bin_op.lhs, ip))) {
            .vector_type => |v| v.child,
            else => |k| k.array_type.child,
        },
    };
}

pub const dump = @import("Ir/print.zig").dump;
