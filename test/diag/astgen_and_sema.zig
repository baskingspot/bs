fn half(n: u64) u32 {
    const unused = n;
    return n / 2;
}

const broken = undeclared_name;

pub fn main() void {
    _ = half(4);
    _ = broken;
}

// error
// astgen_and_sema.zig:2:11: error[unused]: unused local constant
//   | const unused = n;
//   fix astgen_and_sema.zig:3:1-3:1: "    _ = unused;\n"
// astgen_and_sema.zig:6:16: error[undeclared]: use of undeclared identifier 'undeclared_name'
//   | const broken = undeclared_name;
// astgen_and_sema.zig:3:14: error[type-mismatch]: expected type 'u32', found 'u64'
//   | return n / 2;
//   note astgen_and_sema.zig:3:14: unsigned 32-bit int cannot represent all possible unsigned 64-bit values
//   note astgen_and_sema.zig:1:17: function return type declared here: fn half(n: u64) u32 {
//   fix? astgen_and_sema.zig:3:12-3:17: "@intCast(n / 2)"
//   ref: main astgen_and_sema.zig:9:13 (+3 std frames)
// 3 errors
