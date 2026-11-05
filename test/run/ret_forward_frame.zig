//! exit: 0
//! stderr: "n=3 m=4 w=5 t=6 s=8 err=Bad trace=3 ok\n"
//! upstream-stderr: "n=3 m=4 w=5 t=6 s=8 err=Bad trace=3 BIG FRAMES\n"
//! `return f(x)` of a large result in memory passes the function's own
//! result pointer on to the call (`planRetCalls`), through an inferred
//! error set's bitcast and an error union's payload, so no level of the
//! chain holds a copy: sandopolis's 64 MiB test stack overflowed when each
//! held one. `return try f(x)` does the same through the payload's unwrap,
//! and `p.* = try f(x)` copies the payload from the call's result straight
//! to `p.*` (x86_64's `storeInPlace`). The error path still records the error
//! return trace's entries (one per `return` of an error).
const std = @import("std");
const builtin = @import("builtin");
const Big = struct { b: [1 << 18]u8, n: u32 };
var fa: [5]usize = undefined;

noinline fn inner(x: u32) !Big {
    fa[4] = @frameAddress();
    if (x == 7) return error.Bad;
    var v: Big = undefined;
    @memset(&v.b, @truncate(x));
    v.n = x;
    return v;
}
noinline fn mid(x: u32) !Big {
    fa[3] = @frameAddress();
    return inner(x);
}
noinline fn load(x: u32) !Big {
    fa[2] = @frameAddress();
    return mid(x);
}

noinline fn plain(x: u32) Big {
    fa[4] = @frameAddress();
    var v: Big = undefined;
    @memset(&v.b, @truncate(x));
    v.n = x;
    return v;
}
noinline fn wrapped(x: u32) !Big {
    fa[3] = @frameAddress();
    if (x == 0) return error.Zero;
    return plain(x);
}

noinline fn tried(x: u32) !Big {
    fa[2] = @frameAddress();
    return try mid(x);
}
var stored: Big = undefined;
noinline fn store(p: *Big, x: u32) !void {
    fa[2] = @frameAddress();
    p.* = try mid(x);
}

fn kib(a: usize, b: usize) usize {
    return (a - b) >> 10;
}

pub fn main() void {
    fa[0] = @frameAddress();
    const b = load(3) catch unreachable;
    // Each level's frame holds no Big.
    const ok1 = kib(fa[2], fa[3]) < 64 and kib(fa[3], fa[4]) < 64;
    const m = (load(4) catch unreachable).n;
    const w = wrapped(5) catch unreachable;
    const ok2 = kib(fa[3], fa[4]) < 64 and w.b[1 << 17] == 5;
    const t = tried(6) catch unreachable;
    // `tried` holds an error union for its own error path.
    const ok3 = kib(fa[2], fa[3]) < 300 and t.b[77] == 6;
    store(&stored, 8) catch unreachable;
    // aarch64 copies it to the payload's own slot first.
    const ok4 = kib(fa[2], fa[3]) < @as(usize, if (builtin.cpu.arch == .aarch64) 560 else 300) and stored.b[99] == 8;
    const e = load(7);
    const trace = @errorReturnTrace().?;
    std.debug.print("n={} m={} w={} t={} s={} err={s} trace={} {s}\n", .{
        b.n,
        m,
        w.n,
        t.n,
        stored.n,
        if (e) |_| "none" else |err| @errorName(err),
        trace.index,
        if (ok1 and ok2 and ok3 and ok4 and b.b[12345] == 3) "ok" else "BIG FRAMES",
    });
}
