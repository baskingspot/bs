//! exit: 0
//! stdout: "4 20 5 401 104 15 4\n"
//! targets: aarch64-linux aarch64-macos

// A by-value parameter passed in the caller's outgoing area is the memory
// of the `const` local Sema copies it into, when nothing but that copy
// and reads, also through a pointer cast, uses the local's address
// (`planArgAliases` on aarch64). A local whose address goes to a call
// keeps the copy. A tail call rewrites the parameters' slots, but only
// after it has read every argument: `swapTail` passes its locals back
// swapped.
const std = @import("std");
const builtin = @import("builtin");

const Arr = struct { v: [5]u64 };

noinline fn pick(x: Arr, i: usize) u64 {
    const c = x;
    return c.v[i];
}

noinline fn cast(x: Arr, i: usize) u64 {
    const c = x;
    return @as(*const u32, @ptrCast(&c.v[i])).*;
}

noinline fn read(p: *const Arr) u64 {
    return p.v[0] * 10 + p.v[1];
}

noinline fn escapes(x: Arr, i: usize) u64 {
    const c = x;
    return read(&c) - c.v[i];
}

noinline fn swapTail(x: Arr, y: Arr, n: u64, i: usize) u64 {
    const c = y;
    const d = x;
    if (n == 0) return d.v[i] * 100 + c.v[i];
    // Upstream's x86_64 backend has no tail calls.
    return @call(if (builtin.cpu.arch == .aarch64) .always_tail else .auto, swapTail, .{ c, d, n - 1, i });
}

noinline fn loop(x: Arr, n: usize) u64 {
    const c = x;
    var t: u64 = 0;
    for (0..n) |i| t += c.v[i % 5];
    return t;
}

pub fn main() void {
    var a: Arr = .{ .v = .{ 1, 2, 3, 4, 5 } };
    var b: Arr = .{ .v = .{ 4, 3, 2, 1, 0 } };
    var i: usize = 3;
    std.mem.doNotOptimizeAway(&a);
    std.mem.doNotOptimizeAway(&b);
    std.mem.doNotOptimizeAway(&i);
    var out: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    w.print("{} {} {} {} {} {} {}\n", .{
        pick(a, i),
        escapes(a, 0) + 9,
        pick(a, i + 1),
        swapTail(b, a, 2, 0),
        swapTail(b, a, 1, 0),
        loop(a, 5),
        cast(a, i),
    }) catch unreachable;
    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, w.buffered()) catch {};
}
