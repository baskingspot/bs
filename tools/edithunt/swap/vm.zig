//! The edit hunter's `swap` project: the module `vm`, or its sibling's
//! root module.
const std = @import("std");
const revo = @import("revo");
const capi = @import("capi");

pub const Op = enum { add, mul, nop };

pub const State = struct {
    acc: u32 = 0,
    steps: u16 = 0,

    pub fn apply(s: *State, op: Op, x: u32) void {
        switch (op) {
            .add => s.acc += x,
            .mul => s.acc *= x,
            .nop => {},
        }
        s.steps += 1;
    }
};

const trace = false;

pub fn run(xs: []const u32) u32 {
    var s: State = .{};
    for (xs) |x| s.apply(.add, x);
    if (trace) std.debug.print("steps {d}\n", .{s.steps});
    return revo.sum(u32, xs[0..0]) + s.acc;
}

test "vm runs through revo" {
    try std.testing.expectEqual(@as(u32, 10), run(&.{ 1, 2, 3, 4 }));
    try std.testing.expectEqual(@as(u32, 12), capi.scaled(4));
    try std.testing.expectEqual(@as(u32, 2), try revo.check(1));
}
