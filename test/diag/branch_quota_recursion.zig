// A memoized recursion whose memo hits exceed the branch quota fails as
// upstream's, at the branch that exceeds it, without running every level
// once lowered and again in the walker.
fn rec(n: u32) error{Big}!u64 {
    if (n > 60) return error.Big;
    if (n < 2) return n;
    return (try rec(n - 1)) +% (try rec(n - 2)) +% 1;
}

const r = blk: {
    @setEvalBranchQuota(50000);
    break :blk rec(57) catch 0;
};

pub fn main() void {
    _ = r;
}

// error
// branch_quota_recursion.zig:7:40: error[eval-limit]: evaluation exceeded 50000 backwards branches
//   | return (try rec(n - 1)) +% (try rec(n - 2)) +% 1;
//   note branch_quota_recursion.zig:7:40: use @setEvalBranchQuota() to raise the branch limit from 50000
//   call: branch_quota_recursion.zig:7:20 comptime (4 times), branch_quota_recursion.zig:7:40 comptime (2 times), branch_quota_recursion.zig:7:20 comptime, branch_quota_recursion.zig:7:40 comptime, branch_quota_recursion.zig:7:20 comptime (4 times), branch_quota_recursion.zig:7:40 comptime (2 times), branch_quota_recursion.zig:7:20 comptime (35 times), branch_quota_recursion.zig:12:19 comptime
//   ref: main branch_quota_recursion.zig:16:9 (+3 std frames)
// 1 error
