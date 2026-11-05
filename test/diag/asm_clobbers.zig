const anon = .{ .rbx = true };

fn unknownField() void {
    asm volatile ("" ::: .{ .bogus = true });
}

fn otherStruct() void {
    asm volatile ("" ::: anon);
}

fn runtime(b: bool) void {
    asm volatile ("" ::: .{ .rbx = b });
}

pub fn main() void {
    _ = &unknownField;
    _ = &otherStruct;
    _ = &runtime;
}

// error
// asm_clobbers.zig:4:30: error[no-field]: no field named 'bogus' in struct 'lang.assembly.Clobbers__struct_7'
//   | asm volatile ("" ::: .{ .bogus = true });
//   note std/lang/assembly.zig:2:38: struct declared here: .x86_16, .x86, .x86_64 => packed struct {
//   ref: main asm_clobbers.zig:16:10 (+3 std frames)
// asm_clobbers.zig:8:26: error[type-mismatch]: expected type 'std.lang.Clobbers', found 'asm_clobbers.anon__struct_1'
//   | asm volatile ("" ::: anon);
//   ref: main asm_clobbers.zig:17:10 (+3 std frames)
// asm_clobbers.zig:12:27: error[comptime-required]: unable to resolve comptime value
//   | asm volatile ("" ::: .{ .rbx = b });
//   note asm_clobbers.zig:12:27: clobber must be comptime-known
//   ref: main asm_clobbers.zig:18:10 (+3 std frames)
// 3 errors
