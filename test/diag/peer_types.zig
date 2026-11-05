fn typeOf(x: []const u8, y: [*:0]const u8) void {
    _ = @TypeOf(x, y);
}
fn tupleField() void {
    var x = .{ @as(u8, 0), @as(u32, 1) };
    var y = .{ @as(u8, 1), "hello" };
    _ = .{ &x, &y };
    _ = @TypeOf(x, y);
}
fn branches(c: bool) u32 {
    const v = if (c) @as(u32, 1) else "one";
    return v;
}
fn vectorLength(a: @Vector(2, i32), b: @Vector(3, i32)) void {
    _ = a + b;
}
fn mixed(a: @Vector(2, i32)) void {
    _ = a * 2;
}
fn boolOr() bool {
    return true || false;
}
fn sliceMember(s: []i32) void {
    _ = @TypeOf(s).len;
}
pub fn main() void {
    typeOf("a", "b");
    tupleField();
    _ = branches(true);
    vectorLength(@splat(0), @splat(0));
    mixed(@splat(0));
    _ = boolOr();
    sliceMember(&.{});
}

// error
// peer_types.zig:2:9: error[type-mismatch]: incompatible types: '[]const u8' and '[*:0]const u8'
//   | _ = @TypeOf(x, y);
//   note peer_types.zig:2:17: type '[]const u8' here
//   note peer_types.zig:2:20: type '[*:0]const u8' here
//   ref: main peer_types.zig:27:11 (+3 std frames)
// peer_types.zig:8:9: error[type-mismatch]: struct field '1' has conflicting types
//   | _ = @TypeOf(x, y);
//   note peer_types.zig:8:9: incompatible types: 'u32' and '*const [5:0]u8'
//   note peer_types.zig:8:17: type 'u32' here
//   note peer_types.zig:8:20: type '*const [5:0]u8' here
//   ref: main peer_types.zig:28:15 (+3 std frames)
// peer_types.zig:11:15: error[type-mismatch]: incompatible types: 'u32' and '*const [3:0]u8'
//   | const v = if (c) @as(u32, 1) else "one";
//   note peer_types.zig:11:22: type 'u32' here
//   note peer_types.zig:11:39: type '*const [3:0]u8' here
//   ref: main peer_types.zig:29:17 (+3 std frames)
// peer_types.zig:15:11: error[length-mismatch]: vector length mismatch
//   | _ = a + b;
//   note peer_types.zig:15:9: length 2 here
//   note peer_types.zig:15:13: length 3 here
//   ref: main peer_types.zig:30:17 (+3 std frames)
// peer_types.zig:18:11: error[bad-operands]: mixed scalar and vector operands: '@Vector(2, i32)' and 'comptime_int'
//   | _ = a * 2;
//   note peer_types.zig:18:9: vector here
//   note peer_types.zig:18:13: scalar here
//   ref: main peer_types.zig:31:10 (+3 std frames)
// peer_types.zig:21:12: error[operand-type]: expected error set type, found 'bool'
//   | return true || false;
//   note peer_types.zig:21:17: '||' merges error sets; 'or' performs boolean OR
//   fix peer_types.zig:21:17-21:19: "or"
//   ref: main peer_types.zig:32:15 (+3 std frames)
// peer_types.zig:24:19: error[no-member]: type '[]i32' has no members
//   | _ = @TypeOf(s).len;
//   note peer_types.zig:24:19: slice values have 'len' and 'ptr' members
//   ref: main peer_types.zig:33:16 (+3 std frames)
// 7 errors
