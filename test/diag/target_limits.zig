// Runtime tail calls and atomics wider than 64 bits are beyond upstream's
// x86_64 backend at the baseline CPU; zap reports both as upstream does.
// Comptime and inline calls are not tail calls.
fn plain(n: u32) u32 {
    return n;
}
inline fn inl(n: u32) u32 {
    return n + 1;
}
fn tail(n: u32) u32 {
    const k = comptime @call(.always_tail, plain, .{3});
    if (n == 0) return @call(.always_tail, inl, .{k});
    return @call(.always_tail, plain, .{n});
}
fn wide() u128 {
    var x: u128 align(16) = 1234;
    return @atomicLoad(u128, &x, .seq_cst);
}

pub fn main() void {
    _ = tail(1);
    _ = wide();
}

// error
// target_limits.zig:13:12: error[unsupported]: unable to perform tail call: compiler backend 'stage2_x86_64' does not support tail calls on target architecture 'x86_64' with the selected CPU feature flags
//   | return @call(.always_tail, plain, .{n});
//   ref: main target_limits.zig:21:13 (+3 std frames)
// target_limits.zig:17:24: error[operand-type]: expected 64-bit integer type or smaller; found 128-bit integer type
//   | return @atomicLoad(u128, &x, .seq_cst);
//   ref: main target_limits.zig:22:13 (+3 std frames)
// 2 errors
