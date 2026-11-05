// `f80` is extern compatible only where compiler-rt's float ABI for it is
// the hardware's, as upstream: on x86_64, not on aarch64, where
// `c_longdouble` is `f128`.
const S = extern struct { a: c_longdouble, b: f80 };

export fn give(x: c_longdouble) f80 {
    return @floatCast(x);
}

pub fn main() void {
    var s: S = undefined;
    _ = &s;
}

// error
// args: -target aarch64-linux
// extern_f80.zig:4:47: error[bad-type]: extern structs cannot contain fields of type 'f80'
//   | const S = extern struct { a: c_longdouble, b: f80 };
//   note extern_f80.zig:4:47: 'f80' is not extern compatible on this target
//   ref: main extern_f80.zig:11:5 (+3 std frames)
// extern_f80.zig:6:33: error[bad-fn-type]: return type 'f80' not allowed in function with calling convention 'aarch64_aapcs'
//   | export fn give(x: c_longdouble) f80 {
//   note extern_f80.zig:6:33: 'f80' is not extern compatible on this target
// 2 errors
