// @bitSizeOf takes only types with a bit representation, as upstream
// (plus enums and error sets, which upstream still allows).
const P = packed struct { a: u3, b: u5 };
const S = struct { a: u8 };

comptime {
    _ = @bitSizeOf(P) + @bitSizeOf([2]P) + @bitSizeOf(?*u8) + @bitSizeOf(enum { a, b }) + @bitSizeOf(error{A});
}
comptime {
    _ = @bitSizeOf(S);
}
comptime {
    _ = @bitSizeOf(?u8);
}
comptime {
    _ = @bitSizeOf([]u8);
}

pub fn main() void {}

// error
// bit_size_of.zig:10:20: error[bad-type]: no bit size available for type 'bit_size_of.S'
//   | _ = @bitSizeOf(S);
//   note bit_size_of.zig:4:11: struct declared here: const S = struct { a: u8 };
// bit_size_of.zig:13:20: error[bad-type]: no bit size available for type '?u8'
//   | _ = @bitSizeOf(?u8);
// bit_size_of.zig:16:20: error[bad-type]: no bit size available for type '[]u8'
//   | _ = @bitSizeOf([]u8);
// 3 errors
