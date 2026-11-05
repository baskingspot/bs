//! exit: 0
//! stdout: "1\n1\n1\n1\n1\n1\n1\n1\n1\n"
//! Loop-invariant loads (docs/slop/architecture.md, "Forwarding"): a load
//! whose memory no write in the loop may reach moves before the loop and
//! reads the same value; one that a write, a call, or an aliasing store
//! in the loop may change stays and sees each new value.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const Tok = struct {
    buf: []const u8,
    index: usize,
    count: u32,
};

/// `t.buf` moves before the loop; `t.index` and `t.count` change in it.
noinline fn scan(t: *Tok) u32 {
    const start = t.index;
    while (t.index < t.buf.len) {
        if (t.buf[t.index] == 'a') t.count += 1;
        t.index += 1;
    }
    return t.count + @as(u32, @intCast(start));
}

/// A store through another pointer may be to the same memory: the length
/// is read again each time.
noinline fn aliased(t: *Tok, len: *usize) usize {
    var n: usize = 0;
    _ = t.index;
    while (n < t.buf.len) {
        len.* -= 1;
        n += 1;
    }
    return n;
}

var bump_target: *Tok = undefined;

noinline fn bump() void {
    bump_target.count += 10;
}

/// A call may write anything: the count is read after each.
noinline fn called(t: *Tok) u32 {
    var sum: u32 = 0;
    _ = t.index;
    for (0..3) |_| {
        bump();
        sum += t.count;
    }
    return sum;
}

/// A store after the load, in a branch, changes what the next iteration
/// reads.
noinline fn later(t: *Tok) u32 {
    var sum: u32 = 0;
    _ = t.index;
    for (0..3) |_| {
        sum += t.count;
        if (sum < 100) t.count += 1;
    }
    return sum;
}

const Holder = struct { ptr: *u32 };

/// A pointer loaded from memory may point to a local whose address
/// escaped (unlike a parameter): a store to the local changes what it
/// reads.
noinline fn viaStored(h: *Holder) u32 {
    var local: u32 = 1;
    h.ptr = &local;
    const q = h.ptr;
    var sum: u32 = q.*;
    for (0..3) |_| {
        local += 1;
        sum += q.*;
    }
    return sum;
}

/// A pointer loaded through a parameter is not the parameter: it may
/// point to a local.
noinline fn throughParam(p: **u32) u32 {
    var x: u32 = 0;
    p.* = &x;
    p.*.* = 5;
    return x;
}

/// The loop's body never runs: nothing reads through `p` before it, so its
/// load stays in the loop and does not fault.
noinline fn neverRuns(p: *const Tok, n: usize) usize {
    var sum: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) sum += p.buf.len;
    return sum;
}

fn main() callconv(.c) noreturn {
    var t: Tok = .{ .buf = "banana", .index = 1, .count = 0 };
    rt.printInt(@intFromBool(scan(&t) == 3 + 1));

    var s: Tok = .{ .buf = undefined, .index = 0, .count = 0 };
    const backing = "abcdef";
    s.buf = backing;
    rt.printInt(@intFromBool(aliased(&s, &s.buf.len) == 3));
    rt.printInt(@intFromBool(s.buf.len == 3));

    var c: Tok = .{ .buf = "", .index = 0, .count = 1 };
    bump_target = &c;
    rt.printInt(@intFromBool(called(&c) == 11 + 21 + 31));

    var l: Tok = .{ .buf = "", .index = 0, .count = 1 };
    rt.printInt(@intFromBool(later(&l) == 1 + 2 + 3));

    var dummy: u32 = 0;
    var h: Holder = .{ .ptr = &dummy };
    rt.printInt(@intFromBool(viaStored(&h) == 1 + 2 + 3 + 4));

    var pp: *u32 = &dummy;
    rt.printInt(@intFromBool(throughParam(&pp) == 5));

    const bad: *const Tok = @ptrFromInt(0x10);
    rt.printInt(@intFromBool(neverRuns(bad, 0) == 0));

    var u: Tok = .{ .buf = "aaaa", .index = 0, .count = 0 };
    rt.printInt(@intFromBool(scan(&u) == 4));
    rt.exit(0);
}
