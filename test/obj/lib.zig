// Built by bs with build-obj and linked into main.zig by upstream zig:
// exported functions and data, an import from the other object (also in a
// constant table), thread-locals, and debug info a panic's trace reads.
var counter: u32 = 10;
export var shared: u64 = 7;
threadlocal var calls: u32 = 3;

fn helper(x: u32) u32 {
    counter += x;
    calls += 1;
    return counter + calls;
}

export fn bs_add(a: u32, b: u32) u32 {
    return helper(a) + b;
}

extern fn c_twice(x: u32) u32;

export fn bs_call_c(x: u32) u32 {
    return viaTable(x) + 1;
}

export fn bs_overflow(x: u8) u8 {
    return x + 250;
}

// Copied by value in a loop that is not unrolled, the table is a constant
// lowered during analysis: its relocations must still reach c_twice.
const Op = struct { bit: u32, f: *const fn (u32) callconv(.c) u32 };
const ops = [_]Op{
    .{ .bit = 1 << 0, .f = c_twice }, .{ .bit = 1 << 1, .f = c_twice }, .{ .bit = 1 << 2, .f = c_twice },
    .{ .bit = 1 << 3, .f = c_twice }, .{ .bit = 1 << 4, .f = c_twice }, .{ .bit = 1 << 5, .f = c_twice },
    .{ .bit = 1 << 6, .f = c_twice }, .{ .bit = 1 << 7, .f = c_twice }, .{ .bit = 1 << 8, .f = c_twice },
};
var want: u32 = 1 << 4;

fn viaTable(x: u32) u32 {
    var r: u32 = 0;
    for (ops) |op| if (want & op.bit != 0) {
        r += op.f(x);
    };
    return r;
}
