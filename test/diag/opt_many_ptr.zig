// An optional pointer to an array does not coerce to an optional many
// pointer, as upstream, though the pointer itself does.
var a: [2]u8 = .{ 1, 2 };

pub fn main() void {
    const plain: ?[*]u8 = &a;
    const p: ?*[2]u8 = &a;
    const q: ?[*]u8 = p;
    _ = .{ plain, q };
}

// error
// opt_many_ptr.zig:8:23: error[type-mismatch]: expected type '?[*]u8', found '?*[2]u8'
//   | const q: ?[*]u8 = p;
//   note opt_many_ptr.zig:8:23: a single pointer cannot cast into a many pointer
// 1 error
