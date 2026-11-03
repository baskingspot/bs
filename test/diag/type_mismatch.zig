fn len(n: usize) u32 {
    return n;
}

fn take(x: u32) void {
    _ = x;
}

fn first(items: []const u8) u8 {
    const p: []u8 = items;
    return p[0];
}

pub fn main() void {
    _ = len(3);
    var big: u64 = 1;
    _ = &big;
    take(big);
    _ = first("a");
}

// error
// type_mismatch.zig:18:10: error[type-mismatch]: expected type 'u32', found 'u64'
//   | take(big);
//   note type_mismatch.zig:18:10: unsigned 32-bit int cannot represent all possible unsigned 64-bit values
//   note type_mismatch.zig:5:12: parameter type declared here: fn take(x: u32) void {
// type_mismatch.zig:2:12: error[type-mismatch]: expected type 'u32', found 'usize'
//   | return n;
//   note type_mismatch.zig:2:12: unsigned 32-bit int cannot represent all possible unsigned 64-bit values
//   note type_mismatch.zig:1:18: function return type declared here: fn len(n: usize) u32 {
//   ref: main type_mismatch.zig:15:12 (+3 std frames)
// 2 errors
