var b: u8 = 1;
var f: f32 = 1;

pub fn main() void {
    const u: u8 = undefined;
    _ = b / u;
    const uf: f32 = undefined;
    // A strict float division by `undefined` is `undefined`, not an error.
    _ = f / uf;
}

// error
// undef_div.zig:6:13: error[undefined-value]: use of undefined value here causes illegal behavior
//   | _ = b / u;
// 1 error
