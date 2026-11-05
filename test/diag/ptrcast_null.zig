// A comptime-known zero C or allowzero pointer cast to a pointer that does
// not allow zero, as upstream refuses it.
const T = extern struct { a: c_int };
fn fromC() *T {
    return comptime @ptrCast(@as([*c]T, null));
}
fn fromAllowzero() *T {
    const az: *allowzero T = comptime @ptrFromInt(0);
    return comptime @ptrCast(az);
}
pub fn main() void {
    _ = .{ fromC(), fromAllowzero() };
}

// error
// ptrcast_null.zig:5:30: error[null-value]: null pointer casted to type '*ptrcast_null.T'
//   | return comptime @ptrCast(@as([*c]T, null));
//   ref: main ptrcast_null.zig:12:17 (+3 std frames)
// ptrcast_null.zig:9:30: error[null-value]: null pointer casted to type '*ptrcast_null.T'
//   | return comptime @ptrCast(az);
//   ref: main ptrcast_null.zig:12:34 (+3 std frames)
// 2 errors
