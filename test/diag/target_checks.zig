// Checks that depend on the target, as upstream makes them on
// aarch64-macos: exported types, calling convention values, clobber
// names, GPU-only builtins, and vector operations.
const s: []const u8 = "abc";
export const bytes = s;

export fn long(x: f80) f80 {
    return x;
}

fn sysv() callconv(.x86_64_sysv) void {}

fn clobber() void {
    asm volatile ("nop" ::: .{ .rax = true });
}

fn group() u32 {
    return @workGroupId(0);
}

fn reduce(v: @Vector(4, bool)) bool {
    return @reduce(.Add, v);
}

fn index(v: @Vector(4, u8)) u8 {
    return v[4];
}

pub fn main() void {
    _ = &clobber;
    _ = &group;
    _ = &reduce;
    _ = &index;
    _ = &sysv;
}

// error
// args: -target aarch64-macos
// target_checks.zig:5:1: error[bad-export]: unable to export type '[]const u8'
//   | export const bytes = s;
//   note target_checks.zig:5:1: slices have no guaranteed in-memory representation
// target_checks.zig:7:16: error[bad-fn-type]: parameter of type 'f80' not allowed in function with calling convention 'aarch64_aapcs_darwin'
//   | export fn long(x: f80) f80 {
//   note target_checks.zig:7:16: 'f80' is not extern compatible on this target
// target_checks.zig:11:21: error[type-mismatch]: coercion from enum '@typeInfo(lang.CallingConvention).@"union".tag_type.?' to union 'lang.CallingConvention' must initialize 'lang.CallingConvention.CommonOptions' field 'x86_64_sysv'
//   | fn sysv() callconv(.x86_64_sysv) void {}
//   note std/lang.zig:204:5: field 'x86_64_sysv' declared here
//   note std/lang.zig:162:31: union declared here: pub const CallingConvention = union(enum(u8)) {
//   fix target_checks.zig:11:20-11:32: ".{ .x86_64_sysv = .{} }"
//   ref: main target_checks.zig:34:10 (+2 std frames)
// target_checks.zig:14:33: error[no-field]: no field named 'rax' in struct 'lang.assembly.Clobbers__struct_399'
//   | asm volatile ("nop" ::: .{ .rax = true });
//   note std/lang/assembly.zig:204:37: struct declared here: .aarch64, .aarch64_be => packed struct {
//   ref: main target_checks.zig:30:10 (+2 std frames)
// target_checks.zig:18:12: error[misplaced-builtin]: builtin only available on GPU targets; targeted architecture is aarch64
//   | return @workGroupId(0);
//   ref: main target_checks.zig:31:10 (+2 std frames)
// target_checks.zig:22:26: error[bad-operands]: @reduce operation 'Add' requires integer or float operand; found '@Vector(4, bool)'
//   | return @reduce(.Add, v);
//   ref: main target_checks.zig:32:10 (+2 std frames)
// target_checks.zig:26:14: error[out-of-bounds]: index 4 outside vector of length 4
//   | return v[4];
//   ref: main target_checks.zig:33:10 (+2 std frames)
// 7 errors
