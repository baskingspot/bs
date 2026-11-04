//! exit: 0
//! stdout: "90\n2046\n9\n1803\n20\n9\n81\n21\n36\n106\n904\n"
//! `.auto` passes aggregates over 16 bytes by reference: a constant's own
//! memory, a by-reference parameter's pointer, a value's slot, or else a
//! copy. A parameter must keep the value it had at the call even when the
//! callee writes the memory the argument was read from, directly or as
//! its result location (`s = f(s)`), and a forwarded parameter must too.
//! Each case prints what upstream's ReleaseSafe build prints.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn out(v: u64) void {
    rt.printInt(v);
}

const S = struct { a: [8]u64 };

const table: S = .{ .a = .{ 1, 2, 3, 4, 5, 6, 7, 8 } };
var g: S = .{ .a = .{ 10, 20, 30, 40, 50, 60, 70, 80 } };

/// Writes through `p`, then reads `s`.
noinline fn writeThenRead(s: S, p: *S) u64 {
    p.a[0] = 999;
    p.a[7] = 777;
    return s.a[0] + s.a[7];
}

/// Forwards its parameter to a callee that writes the memory the
/// caller's argument came from.
noinline fn forward(s: S, p: *S, depth: u32) u64 {
    if (depth == 0) return writeThenRead(s, p) + s.a[1];
    return forward(s, p, depth - 1) + s.a[2];
}

/// Builds its result in place, reading `s` after writing earlier fields.
noinline fn reverse(s: S) S {
    var r: S = undefined;
    for (0..8) |i| r.a[i] = s.a[7 - i];
    return r;
}

/// Returns a result built from `s` while writing `g`.
noinline fn rotateG(s: S) S {
    g.a[0] = 5;
    return .{ .a = .{ s.a[1], s.a[2], s.a[3], s.a[4], s.a[5], s.a[6], s.a[7], s.a[0] } };
}

/// Takes the parameter's address.
noinline fn sumThroughPointer(s: S, p: *S) u64 {
    const q = &s;
    p.a[3] = 0;
    var t: u64 = 0;
    for (q.a) |x| t += x;
    return t;
}

noinline fn first(s: S) u64 {
    return s.a[0] * 100 + s.a[5];
}

fn sum(s: S) u64 {
    var t: u64 = 0;
    for (s.a) |x| t += x;
    return t;
}

pub fn main() noreturn {
    // `f(g.*)` where f writes g.
    const pg = &g;
    out(writeThenRead(pg.*, pg));
    out(sum(g));
    // A local passed by value and by pointer.
    var l: S = table;
    out(writeThenRead(l, &l));
    out(sum(l));
    // The same through a forwarded parameter.
    l = table;
    out(forward(l, &l, 3));
    // An array element and a pointer to it.
    var arr: [3]S = .{ table, table, table };
    var i: usize = 1;
    _ = &i;
    out(writeThenRead(arr[i], &arr[i]));
    // `s = f(s)`: the argument is also the result location.
    l = table;
    l = reverse(l);
    out(l.a[0] * 10 + l.a[7]);
    g = table;
    g = rotateG(g);
    out(g.a[0] * 10 + g.a[7]);
    // `&param` while the source changes.
    l = table;
    out(sumThroughPointer(l, &l));
    // Constants and temporaries.
    out(first(table));
    out(first(.{ .a = .{ 9, 8, 7, 6, 5, 4, 3, 2 } }));
    rt.exit(0);
}
