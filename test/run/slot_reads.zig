//! exit: 0
//! stderr: "5105 9009 7 3 7 72340172838076673 9 11 8\n"
//! Variables and loads of them that get no register, among more live
//! values than callee-saved registers across calls: a load reads the
//! variable's slot as its own only while nothing stores to the variable,
//! and a variable just stored is read from the register that stored it
//! only until something else may write it, also in the next block when
//! that block has no other predecessor.
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

noinline fn alias(p: *u64) *u64 {
    return p;
}

/// An address-taken variable stored from a register, then written through
/// an alias of its address that is not known to be it, by a store, a
/// memset, an atomic store and inline assembly that clobbers memory, each
/// between the store and a load of the variable.
noinline fn writtenThroughAlias(n: u64) [4]u64 {
    var x: u64 = 0;
    const q = alias(&x);
    var r: [4]u64 = undefined;
    x = id(n);
    q.* = 7;
    r[0] = id(x);
    x = id(n);
    @memset(std.mem.asBytes(q), 1);
    r[1] = id(x);
    x = id(n);
    @atomicStore(u64, q, 9, .seq_cst);
    r[2] = id(x);
    x = id(n);
    asm volatile ("movq $11, (%%rdi)"
        :
        : [p] "{rdi}" (q),
        : .{ .memory = true });
    r[3] = id(x);
    return r;
}

/// A variable stored just before a loop whose header also continues from
/// the loop's end, where the register no longer holds it.
noinline fn storedBeforeLoop(n: u64) u64 {
    var x: u64 = 0;
    const q = alias(&x);
    x = id(n);
    while (x < n + 5) {
        q.* = x + 1;
        _ = id(1000);
    }
    return x;
}

pub fn main() void {
    const a = storedInInterval(5);
    const b = storedAfter(9);
    const w = writtenThrough(4);
    const v = writtenThroughAlias(4);
    std.debug.print("{d} {d} {d} {d} {d} {d} {d} {d} {d}\n", .{ a, b, w[0], w[1], v[0], v[1], v[2], v[3], storedBeforeLoop(3) });
}
