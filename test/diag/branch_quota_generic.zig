// A generic parameter's type is evaluated once a call against the
// branch quota, as upstream, though bs also evaluates it for the
// argument's result type: each call below counts 20 (the call to F and
// the loop's 19 iterations, which its memo hits add), so 50 calls fit in
// 1000 and 51 do not.
fn F(comptime n: u32) type {
    var s: u32 = 0;
    for (0..19) |i| s += i;
    return *[n + s - 171]u8;
}
noinline fn create(comptime n: u32, d: F(n)) void {
    d[0] +%= 1;
}
fn fits(x: *[1]u8) void {
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
    create(1, x);
}
fn exceeds(x: *[2]u8) void {
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
    create(2, x);
}

pub fn main() void {
    var a: [1]u8 = .{0};
    var b: [2]u8 = .{ 0, 0 };
    fits(&a);
    exceeds(&b);
}

// error
// branch_quota_generic.zig:11:41: error[eval-limit]: evaluation exceeded 1000 backwards branches
//   | noinline fn create(comptime n: u32, d: F(n)) void {
//   note branch_quota_generic.zig:11:41: use @setEvalBranchQuota() to raise the branch limit from 1000
//   call: branch_quota_generic.zig:117:11 generic
//   ref: main branch_quota_generic.zig:124:12 (+3 std frames)
// 1 error
