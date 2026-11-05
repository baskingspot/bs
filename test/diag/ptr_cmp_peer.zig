var a: [2]u16 = .{ 1, 2 };
const at_comptime = blk: {
    var b: [2]u16 = .{ 1, 2 };
    const m: [*]u16 = &b;
    break :blk m == &b[0];
};
pub fn main() void {
    _ = at_comptime;
    const m: [*]u16 = &a;
    _ = m == &a[0];
}

// error
// ptr_cmp_peer.zig:5:18: error[type-mismatch]: incompatible types: '[*]u16' and '*u16'
//   | break :blk m == &b[0];
//   note ptr_cmp_peer.zig:5:16: type '[*]u16' here
//   note ptr_cmp_peer.zig:5:21: type '*u16' here
//   ref: main ptr_cmp_peer.zig:8:9 (+3 std frames)
// 1 error
