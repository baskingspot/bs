//! Why a ZIR operand must be comptime-known: upstream Zig 0.17.1's
//! `std.zig.SimpleComptimeReason` (lib/std/zig.zig), vendored with Zig
//! 0.16.0's extra reasons appended, so that both releases' AstGen emit one
//! enum (docs/slop/zig-0.16.md). Copyright (c) Zig contributors. MIT
//! licensed (see LICENSE-ZIG).

pub const SimpleComptimeReason = enum(u32) {
    // Evaluating at comptime because a builtin operand must be comptime-known.
    // These messages all mention a specific builtin.
    operand_setEvalBranchQuota,
    operand_setFloatMode,
    operand_branchHint,
    operand_setRuntimeSafety,
    operand_embedFile,
    operand_shuffle_mask,
    operand_atomicRmw_operation,
    operand_reduce_operation,

    // Evaluating at comptime because an operand must be comptime-known.
    // These messages do not mention a specific builtin (and may not be about a builtin at all).
    export_target,
    export_options,
    extern_options,
    prefetch_options,
    call_modifier,
    compile_error_string,
    inline_assembly_code,
    atomic_order,
    slice_cat_operand,
    inline_call_target,
    generic_call_target,
    wasm_memory_index,
    work_group_dim_index,
    clobber,

    // Evaluating at comptime because types must be comptime-known.
    // Reasons other than `.type` are just more specific messages.
    type,
    int_signedness,
    int_bit_width,
    array_sentinel,
    array_length,
    pointer_size,
    pointer_attrs,
    pointer_sentinel,
    slice_sentinel,
    vector_length,
    fn_ret_ty,
    fn_param_types,
    fn_param_attrs,
    fn_attrs,
    struct_layout,
    struct_field_names,
    struct_field_types,
    struct_field_attrs,
    union_layout,
    union_field_names,
    union_field_types,
    union_field_attrs,
    tuple_field_types,
    enum_field_names,
    enum_field_values,
    union_enum_tag_type,
    enum_int_tag_type,
    packed_struct_backing_int_type,
    packed_union_backing_int_type,

    // Evaluating at comptime because decl/field name must be comptime-known.
    decl_name,
    field_name,
    tuple_field_index,

    // Evaluating at comptime because it is an attribute of a global declaration.
    container_var_init,
    @"callconv",
    @"align",
    @"addrspace",
    @"linksection",

    // Miscellaneous reasons.
    comptime_keyword,
    comptime_call_modifier,
    inline_loop_operand,
    switch_item,
    tuple_field_default_value,
    struct_field_default_value,
    enum_field_tag_value,
    slice_single_item_ptr_bounds,
    stored_to_comptime_field,
    stored_to_comptime_var,
    casted_to_comptime_int,
    casted_to_comptime_float,
    std_lang_decl,

    // Zig 0.16 only (docs/slop/zig-0.16.md): reasons 0.16's AstGen gives
    // that 0.17's does not. 0.16's `std_builtin_decl` is `std_lang_decl`.
    operand_cImport,
    operand_cDefine_macro_name,
    operand_cDefine_macro_value,
    operand_cInclude_file_name,
    operand_cUndef_macro_name,
    array_mul_factor,
    casted_to_comptime_enum,

    /// The reason as Zig 0.17.1 states it; `messageFor` for a language.
    pub fn message(r: SimpleComptimeReason) []const u8 {
        return switch (r) {
            // zig fmt: off
            .operand_setEvalBranchQuota  => "operand to '@setEvalBranchQuota' must be comptime-known",
            .operand_setFloatMode        => "operand to '@setFloatMode' must be comptime-known",
            .operand_branchHint          => "operand to '@branchHint' must be comptime-known",
            .operand_setRuntimeSafety    => "operand to '@setRuntimeSafety' must be comptime-known",
            .operand_embedFile           => "operand to '@embedFile' must be comptime-known",
            .operand_shuffle_mask        => "'@shuffle' mask must be comptime-known",
            .operand_atomicRmw_operation => "'@atomicRmw' operation must be comptime-known",
            .operand_reduce_operation    => "'@reduce' operation must be comptime-known",

            .export_target        => "export target must be comptime-known",
            .export_options       => "export options must be comptime-known",
            .extern_options       => "extern options must be comptime-known",
            .prefetch_options     => "prefetch options must be comptime-known",
            .call_modifier        => "call modifier must be comptime-known",
            .compile_error_string => "compile error string must be comptime-known",
            .inline_assembly_code => "inline assembly code must be comptime-known",
            .atomic_order         => "atomic order must be comptime-known",
            .slice_cat_operand    => "slice being concatenated must be comptime-known",
            .inline_call_target   => "function being called inline must be comptime-known",
            .generic_call_target  => "generic function being called must be comptime-known",
            .wasm_memory_index    => "wasm memory index must be comptime-known",
            .work_group_dim_index => "work group dimension index must be comptime-known",
            .clobber              => "clobber must be comptime-known",

            .type                => "types must be comptime-known",
            .int_signedness      => "integer signedness must be comptime-known",
            .int_bit_width       => "integer bit width must be comptime-known",
            .array_sentinel      => "array sentinel value must be comptime-known",
            .array_length        => "array length must be comptime-known",
            .pointer_size        => "pointer size must be comptime-known",
            .pointer_attrs       => "pointer attributes must be comptime-known",
            .pointer_sentinel    => "pointer sentinel value must be comptime-known",
            .slice_sentinel      => "slice sentinel value must be comptime-known",
            .vector_length       => "vector length must be comptime-known",
            .fn_ret_ty           => "function return type must be comptime-known",
            .fn_param_types      => "function parameter types must be comptime-known",
            .fn_param_attrs      => "function parameter attributes must be comptime-known",
            .fn_attrs            => "function attributes must be comptime-known",
            .struct_layout       => "struct layout must be comptime-known",
            .struct_field_names  => "struct field names must be comptime-known",
            .struct_field_types  => "struct field types must be comptime-known",
            .struct_field_attrs  => "struct field attributes must be comptime-known",
            .union_layout        => "union layout must be comptime-known",
            .union_field_names   => "union field names must be comptime-known",
            .union_field_types   => "union field types must be comptime-known",
            .union_field_attrs   => "union field attributes must be comptime-known",
            .tuple_field_types   => "tuple field types must be comptime-known",
            .enum_field_names    => "enum field names must be comptime-known",
            .enum_field_values   => "enum field values must be comptime-known",

            .union_enum_tag_type            => "enum tag type of union must be comptime-known",
            .enum_int_tag_type              => "integer tag type of enum must be comptime-known",
            .packed_struct_backing_int_type => "packed struct backing integer type must be comptime-known",
            .packed_union_backing_int_type  => "packed struct backing integer type must be comptime-known",

            .decl_name         => "declaration name must be comptime-known",
            .field_name        => "field name must be comptime-known",
            .tuple_field_index => "tuple field index must be comptime-known",

            .container_var_init => "initializer of container-level variable must be comptime-known",
            .@"callconv"        => "calling convention must be comptime-known",
            .@"align"           => "alignment must be comptime-known",
            .@"addrspace"       => "address space must be comptime-known",
            .@"linksection"     => "linksection must be comptime-known",

            .comptime_keyword             => "'comptime' keyword forces comptime evaluation",
            .comptime_call_modifier       => "'.compile_time' call modifier forces comptime evaluation",
            .inline_loop_operand          => "inline loop condition must be comptime-known",
            .switch_item                  => "switch prong values must be comptime-known",
            .tuple_field_default_value    => "tuple field default value must be comptime-known",
            .struct_field_default_value   => "struct field default value must be comptime-known",
            .enum_field_tag_value         => "enum field tag value must be comptime-known",
            .slice_single_item_ptr_bounds => "slice of single-item pointer must have comptime-known bounds",
            .stored_to_comptime_field     => "value stored to a comptime field must be comptime-known",
            .stored_to_comptime_var       => "value stored to a comptime variable must be comptime-known",
            .casted_to_comptime_int       => "value casted to 'comptime_int' must be comptime-known",
            .casted_to_comptime_float     => "value casted to 'comptime_float' must be comptime-known",
            .std_lang_decl                => "'std.lang' declaration values must be comptime-known",
            .operand_cImport             => "operand to '@cImport' is evaluated at comptime",
            .operand_cDefine_macro_name  => "'@cDefine' macro name must be comptime-known",
            .operand_cDefine_macro_value => "'@cDefine' macro value must be comptime-known",
            .operand_cInclude_file_name  => "'@cInclude' file name must be comptime-known",
            .operand_cUndef_macro_name   => "'@cUndef' macro name must be comptime-known",
            .array_mul_factor     => "array multiplication factor must be comptime-known",
            .casted_to_comptime_enum      => "value casted to enum with 'comptime_int' tag type must be comptime-known",
            // zig fmt: on
        };
    }

    /// The reason as `language`'s release states it.
    pub fn messageFor(r: SimpleComptimeReason, language: Language) []const u8 {
        if (language == .zig_0_16 and r == .std_lang_decl) return "'std.builtin' declaration values must be comptime-known";
        return r.message();
    }
};

const Language = @import("language.zig").Language;
