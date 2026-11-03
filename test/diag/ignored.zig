fn mayFail() !u8 {
    return 1;
}
fn mayFailVoid() !void {}
fn value() u8 {
    return 1;
}
fn statement() !void {
    mayFail();
}
fn discarded() !void {
    _ = mayFail();
}
fn voidPayload() !void {
    mayFailVoid();
}
fn notError() void {
    value();
}
fn cannotTry() void {
    mayFailVoid();
}
pub fn main() void {
    _ = &statement;
    _ = &discarded;
    _ = &voidPayload;
    notError();
    cannotTry();
}

// error
// ignored.zig:9:12: error[ignored-value]: error union of type '@typeInfo(@typeInfo(@TypeOf(ignored.mayFail)).@"fn".return_type.?).error_union.error_set!u8' is ignored
//   | mayFail();
//   note ignored.zig:9:12: consider using 'try', 'catch', or 'if'
//   ref: main ignored.zig:24:10 (+3 std frames)
// ignored.zig:12:16: error[ignored-value]: error union is discarded
//   | _ = mayFail();
//   note ignored.zig:12:16: consider using 'try', 'catch', or 'if'
//   ref: main ignored.zig:25:10 (+3 std frames)
// ignored.zig:15:16: error[ignored-value]: error union of type '@typeInfo(@typeInfo(@TypeOf(ignored.mayFailVoid)).@"fn".return_type.?).error_union.error_set!void' is ignored
//   | mayFailVoid();
//   note ignored.zig:15:16: consider using 'try', 'catch', or 'if'
//   ref: main ignored.zig:26:10 (+3 std frames)
// ignored.zig:18:10: error[ignored-value]: value of type 'u8' ignored
//   | value();
//   note ignored.zig:18:10: all non-void values must be used
//   note ignored.zig:18:10: to discard the value, assign it to '_'
//   ref: main ignored.zig:27:13 (+3 std frames)
// ignored.zig:21:16: error[ignored-value]: error union of type '@typeInfo(@typeInfo(@TypeOf(ignored.mayFailVoid)).@"fn".return_type.?).error_union.error_set!void' is ignored
//   | mayFailVoid();
//   note ignored.zig:21:16: consider using 'try', 'catch', or 'if'
//   ref: main ignored.zig:28:14 (+3 std frames)
// 5 errors
