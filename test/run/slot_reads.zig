//! exit: 0
//! stderr: "5105 9009 7 3\n"
//! Variables and loads of them that get no register, among more live
//! values than callee-saved registers across calls: a load reads the
//! variable's slot as its own only while nothing stores to the variable,
//! and a variable just stored is read from the register that stored it
//! only until something else may write it.
const std = @import("std");

noinline fn id(x: u64) u64 {
    return x;
}

noinline fn set(p: *u64, v: u64) void {
    p.* = v;
}

/// `x`'s load `a` is read after `x` is stored again, across a hot loop
/// that keeps the other values in registers.
noinline fn storedInInterval(n: u64) u64 {
    var x = id(n);
    var v0 = id(1);
    var v1 = id(2);
    var v2 = id(3);
    var v3 = id(4);
    var v4 = id(5);
    var v5 = id(6);
    const a = x;
    x = id(x +% 100);
    var i: u64 = 0;
    while (i < 3) : (i += 1) {
        var j: u64 = 0;
        while (j < 3) : (j += 1) {
            v0 +%= id(v1 ^ j);
            v1 +%= id(v2 +% v0);
            v2 +%= id(v3 ^ v1);
            v3 +%= id(v4 +% v2);
            v4 +%= id(v5 ^ v3);
            v5 +%= id(v0 ^ v4);
        }
    }
    return a *% 1000 +% x +% (v0 +% v1 +% v2 +% v3 +% v4 +% v5) % 7;
}

/// As above with the store after the load's last read.
noinline fn storedAfter(n: u64) u64 {
    var x = id(n);
    var v0 = id(1);
    var v1 = id(2);
    var v2 = id(3);
    var v3 = id(4);
    var v4 = id(5);
    var v5 = id(6);
    const a = x;
    var i: u64 = 0;
    while (i < 3) : (i += 1) {
        var j: u64 = 0;
        while (j < 3) : (j += 1) {
            v0 +%= id(v1 ^ j);
            v1 +%= id(v2 +% v0);
            v2 +%= id(v3 ^ v1);
            v3 +%= id(v4 +% v2);
            v4 +%= id(v5 ^ v3);
            v5 +%= id(v0 ^ v4);
        }
    }
    const r = a *% 1000 +% (v0 +% v1 +% v2 +% v3 +% v4 +% v5) % 7;
    x = id(r);
    return x +% a;
}

/// A variable stored, then written through a pointer to it, then loaded.
noinline fn writtenThrough(n: u64) [2]u64 {
    var x: u64 = 0;
    const p = &x;
    x = id(n);
    set(p, 7);
    const after_call = x;
    x = id(n);
    p.* = 3;
    return .{ after_call, x };
}

pub fn main() void {
    const a = storedInInterval(5);
    const b = storedAfter(9);
    const w = writtenThrough(4);
    std.debug.print("{d} {d} {d} {d}\n", .{ a, b, w[0], w[1] });
}
