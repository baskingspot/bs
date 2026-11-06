//! exit: 0
//! stderr: "panic at 2: 1 1 1\n"
//! A callee that returns in memory and panics after writing part of its
//! result: the destination, which the panic handler reads, still holds
//! the previous result. The result memory is the destination only for a
//! fresh `var`, which nothing can read after the panic.
const std = @import("std");

const N = 4096;
const Big = struct { a: [N]u8, b: u64 };

var G: Big = undefined;
var step: u8 = 0;

pub const panic = std.debug.FullPanic(onPanic);
fn onPanic(msg: []const u8, ra: ?usize) noreturn {
    _ = msg;
    _ = ra;
    std.debug.print("panic at {}: {} {} {}\n", .{ step, G.a[0], G.a[N - 1], G.b });
    std.process.exit(0);
}

noinline fn mk(n: u8, limit: []const u8) Big {
    var r: Big = undefined;
    @memset(&r.a, n + 10);
    r.b = limit[n];
    return r;
}

pub fn main() void {
    const limits: []const u8 = &.{ 1, 1 };
    var i: u8 = 0;
    while (i < 3) : (i += 1) {
        step = i;
        G = mk(i, limits);
        var x = mk(i, limits);
        x.b +%= 0;
        @memset(&G.a, @truncate(G.b));
    }
}
