// A comptime call that a body lowered for the comptime evaluator folds
// is a memo hit on every run, which counts the branches the call took as
// the walker counts them: f's seventh run exceeds the quota, as upstream.
fn helper(b: u32) u32 {
    var i: u32 = 0;
    while (i < b * 6) : (i += 1) {}
    return i;
}
fn f(x: u32) u32 {
    var s = x;
    for (0..3) |_| s +%= comptime helper(8);
    return s;
}
const t = blk: {
    var s: u32 = 0;
    for (0..7) |i| s +%= f(@intCast(i));
    break :blk s;
};

pub fn main() void {
    _ = t;
}

// error
// branch_quota_lowered.zig:6:5: error[eval-limit]: evaluation exceeded 1000 backwards branches
//   | while (i < b * 6) : (i += 1) {}
//   note branch_quota_lowered.zig:6:5: use @setEvalBranchQuota() to raise the branch limit from 1000
//   call: branch_quota_lowered.zig:11:41 comptime, branch_quota_lowered.zig:16:27 comptime
//   ref: main branch_quota_lowered.zig:21:9 (+3 std frames)
// 1 error
