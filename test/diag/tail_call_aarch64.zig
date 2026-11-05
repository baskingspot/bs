// On aarch64-macos, upstream's Debug backend is LLVM, which has tail calls
// and 128-bit atomics. A tail call's callee must have the caller's type,
// whose inferred error set is its own.
fn countdown(n: u32) !void {
    if (n == 0) return error.Done;
    return @call(.always_tail, countdown, .{n - 1});
}
fn other(n: u32) !void {
    return @call(.always_tail, countdown, .{n});
}
fn wide(x: *u128) ?u128 {
    _ = @atomicRmw(u128, x, .Add, 1, .seq_cst);
    return @cmpxchgStrong(u128, x, 1, 2, .seq_cst, .seq_cst);
}
fn wider(x: *u129) u129 {
    return @atomicLoad(u129, x, .seq_cst);
}

pub fn main() void {
    var x: u128 = 1;
    _ = wide(&x);
    var y: u129 = 1;
    _ = wider(&y);
    countdown(3) catch {};
    other(3) catch {};
}

// error
// args: -target aarch64-macos
// tail_call_aarch64.zig:9:12: error[bad-call]: unable to perform tail call: type of function being called 'fn (u32) @typeInfo(@typeInfo(@TypeOf(tail_call_aarch64.countdown)).@"fn".return_type.?).error_union.error_set!void' does not match type of calling function 'fn (u32) @typeInfo(@typeInfo(@TypeOf(tail_call_aarch64.other)).@"fn".return_type.?).error_union.error_set!void'
//   | return @call(.always_tail, countdown, .{n});
//   ref: main tail_call_aarch64.zig:25:10 (+2 std frames)
// tail_call_aarch64.zig:16:24: error[operand-type]: expected 128-bit integer type or smaller; found 129-bit integer type
//   | return @atomicLoad(u129, x, .seq_cst);
//   ref: main tail_call_aarch64.zig:23:14 (+2 std frames)
// 2 errors
