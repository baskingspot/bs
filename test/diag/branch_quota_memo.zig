// A memoized comptime call counts the backward branches it took, as
// upstream: inner(1) and inner(2) run their loops on every call.
fn inner(x: u32) u32 {
    var i: u32 = 0;
    var s: u32 = 0;
    while (i < x) : (i += 1) s +%= i;
    return s;
}

const a = blk: {
    var s: u32 = 0;
    for (0..334) |i| s +%= inner(@intCast(i % 3));
    break :blk s;
};

pub fn main() void {
    _ = a;
}

// error
// branch_quota_memo.zig:12:5: error[eval-limit]: evaluation exceeded 1000 backwards branches
//   | for (0..334) |i| s +%= inner(@intCast(i % 3));
//   note branch_quota_memo.zig:12:5: use @setEvalBranchQuota() to raise the branch limit from 1000
//   ref: main branch_quota_memo.zig:17:9 (+3 std frames)
// 1 error
