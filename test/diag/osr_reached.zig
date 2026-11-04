// A `try` in a long comptime loop of a function that returns no error:
// the evaluator takes the loop over, so the error is reported when the
// walker runs the iteration that reaches it, as upstream reports it.
fn nextByte(it: *[]const u8) error{Short}!u8 {
    if (it.len == 0) return error.Short;
    const b = it.*[0];
    it.* = it.*[1..];
    return b;
}

fn sum() u32 {
    @setEvalBranchQuota(100000);
    const data: [600]u8 = @splat(3);
    var it: []const u8 = &data;
    var total: u32 = 0;
    var n = it.len + 1;
    while (n > 0) : (n -= 1) total += try nextByte(&it);
    return total;
}

const s = sum();

pub fn main() void {
    _ = s;
}

// error
// osr_reached.zig:17:39: error[type-mismatch]: expected type 'u32', found 'error{Short}'
//   | while (n > 0) : (n -= 1) total += try nextByte(&it);
//   note osr_reached.zig:11:10: function cannot return an error: fn sum() u32 {
//   hint: return type '!u32' lets the function return errors
//   fix? osr_reached.zig:11:10-11:10: "!"
//   call: osr_reached.zig:21:14 comptime
//   ref: main osr_reached.zig:24:9 (+3 std frames)
// 1 error
