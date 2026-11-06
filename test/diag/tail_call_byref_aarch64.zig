// aarch64's `.auto` passes an argument larger than 16 bytes by reference,
// so a tail call may pass on its by-reference parameters, in any position,
// and constants, but not a value in the frame it pops.
const Big = struct { v: [6]u64 };

fn swap(x: Big, y: Big, n: u64) u64 {
    if (n == 0) return x.v[0];
    return @call(.always_tail, swap, .{ y, x, n - 1 });
}

fn bump(x: Big, n: u64) u64 {
    if (n == 0) return x.v[0];
    var y = x;
    y.v[0] += 1;
    return @call(.always_tail, bump, .{ y, n - 1 });
}

pub fn main() void {
    _ = swap(.{ .v = @splat(1) }, .{ .v = @splat(2) }, 3);
    _ = bump(.{ .v = @splat(1) }, 3);
}

// error
// args: -target aarch64-linux
// bs-only: upstream's aarch64 backend is LLVM, which emits the tail call; bs passes the argument a pointer into the frame the call pops
// tail_call_byref_aarch64.zig:15:5: error[unsupported]: bs codegen (aarch64): unable to perform tail call: argument 1 of type 'tail_call_byref_aarch64.Big' is passed by reference, and its value lives in the frame the tail call pops; pass a parameter or a constant instead
//   | return @call(.always_tail, bump, .{ y, n - 1 });
// 1 error
