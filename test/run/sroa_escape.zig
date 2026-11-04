//! exit: 0
//! stderr: "3625142886782764 17696002823\nc734dacc7680a2a5\n"
//! Scalar replacement of a local struct whose address is passed to a
//! call (docs/slop/architecture.md, "Rewrite rules"): its fields live in their
//! own locals and are synced with its memory around every call and every
//! access through a pointer of unknown origin. Each read below must see a
//! write made through the escaped address, and each call must see the
//! fields' latest values, also in a loop. SipHash's state escapes into the
//! non-inlined `round` in `final`.
const std = @import("std");
const S = struct { a: u64, b: u64, c: u32 };
var stash: ?*S = null;
noinline fn keep(s: *S) void {
    s.a +%= 100; // reads and writes
    stash = s;
}
noinline fn poke() void {
    if (stash) |p| p.b = 7777;
}
noinline fn peek() u64 {
    return if (stash) |p| p.a *% 3 +% p.c else 0;
}
noinline fn run(n: u32) u64 {
    var s: S = .{ .a = 1, .b = 2, .c = 3 };
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        s.a = s.a *% 31 +% s.b;
        s.b ^= s.a >> 3;
        s.c +%= 1;
    }
    keep(&s);
    var r: u64 = s.a; // sees keep's write
    poke(); // writes s.b through the stash
    r ^= s.b; // must see 7777
    s.c = 99;
    r +%= peek(); // must see s.c == 99 and s.a
    stash.?.a = 5; // store through a loaded pointer
    r +%= s.a; // must see 5
    const q = stash.?;
    s.a = 11;
    r +%= q.a; // load through a loaded pointer must see 11
    return r;
}
noinline fn inLoop(n: u32) u64 {
    var s: S = .{ .a = 1, .b = 2, .c = 3 };
    var r: u64 = 0;
    for (0..n) |_| {
        s.a +%= 1;
        // Enough field work between the calls for the split to pay.
        for (0..4) |_| {
            s.a = s.a *% 3 +% s.c;
            s.c +%= 1;
        }
        keep(&s);
        r +%= s.a;
        poke();
        r ^= s.b;
        s.b = 1;
    }
    return r;
}
pub fn main() void {
    std.debug.print("{} {}\n", .{ run(10), inLoop(5) });
    var key: [16]u8 = @splat(7);
    var buf: [100]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate(i *% 37);
    std.debug.print("{x}\n", .{std.hash.SipHash64(2, 4).toInt(&buf, &key)});
    key[0] = 1;
}
