const In = struct { k: u8, arr: [2]i64 };
fn parentOfK(kp: *u8) *In {
    return @fieldParentPtr("k", kp);
}
fn parentOfKCast(kp: *u8) *In {
    return @alignCast(@fieldParentPtr("k", kp));
}
pub fn main() void {
    var in: In = .{ .k = 1, .arr = .{ 2, 3 } };
    _ = parentOfK(&in.k);
    _ = parentOfKCast(&in.k);
}

// error
// field_parent_align.zig:3:12: error[bad-cast]: @fieldParentPtr increases pointer alignment
//   | return @fieldParentPtr("k", kp);
//   note field_parent_align.zig:3:12: parent pointer type '*field_parent_align.In' has alignment '8'; field 'k' limits it to '1'
//   note field_parent_align.zig:3:12: use @alignCast to assert pointer alignment
//   ref: main field_parent_align.zig:10:18 (+3 std frames)
// 1 error
