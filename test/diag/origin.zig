fn get(ok: bool) !u32 {
    if (!ok) return error.Nope;
    return 3;
}
fn opt(ok: bool) ?u32 {
    return if (ok) 4 else null;
}
const P = struct {
    n: u32,
    fn bump(p: *P) void {
        p.n += 1;
    }
    fn make() !P {
        return .{ .n = 0 };
    }
};
fn errorUnion() anyerror!void {
    const v = get(true);
    const w: u32 = v;
    _ = w;
}
fn optional() u32 {
    const v = opt(true);
    return v + 1;
}
fn receiver() void {
    const p: P = .{ .n = 0 };
    p.bump();
}
fn assign() void {
    const n: u32 = 0;
    n += 1;
}
fn field() anyerror!u32 {
    return P.make().n;
}
pub fn main() !void {
    try errorUnion();
    _ = optional();
    receiver();
    assign();
    _ = try field();
}

// error
// origin.zig:19:20: error[type-mismatch]: expected type 'u32', found '@typeInfo(@typeInfo(@TypeOf(origin.get)).@"fn".return_type.?).error_union.error_set!u32'
//   | const w: u32 = v;
//   note origin.zig:19:20: cannot convert error union to payload type
//   note origin.zig:19:20: consider using 'try', 'catch', or 'if'
//   note origin.zig:18:18: 'v' holds the error union returned by 'get'; consider using 'try' or 'catch' here
//   fix? origin.zig:18:15-18:15: "try "
//   ref: main origin.zig:38:19 (+3 std frames)
// origin.zig:24:14: error[bad-operands]: invalid operands to binary expression: '?u32' and 'comptime_int'
//   | return v + 1;
//   note origin.zig:24:12: consider using '.?', 'orelse', or 'if'
//   note origin.zig:23:18: 'v' holds the optional returned by 'opt'; consider using '.?' or 'orelse' here
//   fix? origin.zig:23:24-23:24: ".?"
//   ref: main origin.zig:39:17 (+3 std frames)
// origin.zig:28:6: error[type-mismatch]: expected type '*origin.P', found '*const origin.P'
//   | p.bump();
//   note origin.zig:28:6: cast discards const qualifier
//   note origin.zig:10:16: parameter type declared here: fn bump(p: *P) void {
//   note origin.zig:27:11: 'p' is declared 'const'; declare it with 'var' to modify it: const p: P = .{ .n = 0 };
//   fix? origin.zig:27:5-27:10: "var"
//   ref: main origin.zig:40:13 (+3 std frames)
// origin.zig:32:5: error[assign-to-const]: cannot assign to constant
//   | n += 1;
//   note origin.zig:31:11: 'n' is declared 'const'; declare it with 'var' to modify it: const n: u32 = 0;
//   fix? origin.zig:31:5-31:10: "var"
//   ref: main origin.zig:41:11 (+3 std frames)
// origin.zig:35:20: error[bad-access]: error union type '@typeInfo(@typeInfo(@TypeOf(origin.P.make)).@"fn".return_type.?).error_union.error_set!origin.P' does not support field access
//   | return P.make().n;
//   note origin.zig:35:20: consider using 'try', 'catch', or 'if'
//   fix? origin.zig:35:12-35:12: "(try "
//   fix? origin.zig:35:20-35:20: ")"
//   ref: main origin.zig:42:18 (+3 std frames)
// 5 errors
