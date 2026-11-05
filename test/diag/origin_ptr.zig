// A constant written through a pointer is noted at its declaration when
// the pointer is `&local`: a `for` loop's `|*x|` over `&local`, or a
// constant local `&local`. Through any other pointer the local holding
// the pointer is not the mistake, so there is no note.
const Node = struct { data: i32 };
fn bump(n: *Node) void {
    n.data += 1;
}
fn capture() void {
    const nodes: [4]Node = undefined;
    for (&nodes, 0..) |*n, i| n.* = .{ .data = @intCast(i * 10) };
}
fn passed() void {
    const nodes: [2]Node = .{ .{ .data = 1 }, .{ .data = 2 } };
    for (&nodes) |*n| bump(n);
}
fn local() void {
    const one: Node = .{ .data = 0 };
    const p = &one;
    p.data = 1;
}
fn slice(s: []const Node) void {
    for (s) |*n| n.data = 3;
}
pub fn main() void {
    capture();
    passed();
    local();
    slice(&.{});
}

// error
// origin_ptr.zig:11:48: error[assign-to-const]: cannot assign to constant
//   | for (&nodes, 0..) |*n, i| n.* = .{ .data = @intCast(i * 10) };
//   note origin_ptr.zig:10:11: 'nodes' is declared 'const'; declare it with 'var' to modify it: const nodes: [4]Node = undefined;
//   fix? origin_ptr.zig:10:5-10:10: "var"
//   ref: main origin_ptr.zig:26:12 (+3 std frames)
// origin_ptr.zig:15:28: error[type-mismatch]: expected type '*origin_ptr.Node', found '*const origin_ptr.Node'
//   | for (&nodes) |*n| bump(n);
//   note origin_ptr.zig:15:28: cast discards const qualifier
//   note origin_ptr.zig:6:12: parameter type declared here: fn bump(n: *Node) void {
//   note origin_ptr.zig:14:11: 'nodes' is declared 'const'; declare it with 'var' to modify it: const nodes: [2]Node = .{ .{ .data = 1 }, .{ .data = 2 } };
//   fix? origin_ptr.zig:14:5-14:10: "var"
//   ref: main origin_ptr.zig:27:11 (+3 std frames)
// origin_ptr.zig:20:6: error[assign-to-const]: cannot assign to constant
//   | p.data = 1;
//   note origin_ptr.zig:18:11: 'one' is declared 'const'; declare it with 'var' to modify it: const one: Node = .{ .data = 0 };
//   fix? origin_ptr.zig:18:5-18:10: "var"
//   ref: main origin_ptr.zig:28:10 (+3 std frames)
// origin_ptr.zig:23:19: error[assign-to-const]: cannot assign to constant
//   | for (s) |*n| n.data = 3;
//   ref: main origin_ptr.zig:29:10 (+3 std frames)
// 4 errors
