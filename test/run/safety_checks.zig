//! exit: 3
//! stderr: "attempt to unwrap error: Whatever\n"
//! Safety checks that pass must not panic, and each fails with upstream's
//! message (test/cases/safety covers the failures one by one): switches
//! on enums and unions with an else prong, @tagName, @bitCast to an enum,
//! @ptrFromInt, @errorCast, @errorFromInt, a C pointer coerced, sliced
//! and dereferenced, a slice cast that changes the length, an untagged
//! union's field, and finally `catch unreachable` on an error, which
//! reports the error.
const std = @import("std");

pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, _: ?usize) noreturn {
        std.debug.print("{s}\n", .{msg});
        std.process.exit(3);
    }
}.f);

const E = enum(u8) { a, b, c };
const T = union(enum) { x: u8, y: u16 };
const U = union { int: u32, float: f32 };
const Err = error{ Whatever, Other };

noinline fn get(comptime V: type, v: V) V {
    return v;
}

noinline fn fail(e: Err) Err!void {
    return e;
}

pub fn main() !void {
    var e = get(E, .b);
    switch (e) {
        .a => return error.Wrong,
        else => {},
    }
    const t = get(T, .{ .y = 7 });
    switch (t) {
        .x => return error.Wrong,
        else => {},
    }
    if (!std.mem.eql(u8, @tagName(e), "b")) return error.Wrong;
    e = @bitCast(get(u8, 2));
    if (e != .c) return error.Wrong;
    var x: u32 = 0x1234;
    const p: *align(4) u32 = @ptrFromInt(@intFromPtr(&x));
    if (p.* != 0x1234) return error.Wrong;
    const narrow: error{Whatever}!void = @errorCast(get(Err!void, {}));
    try narrow;
    if (@errorFromInt(get(u16, @intFromError(error.Other))) != error.Other) return error.Wrong;
    var bytes align(2) = [_]u8{ 1, 2, 3, 4 };
    const c: [*c]u8 = get([*c]u8, &bytes);
    const one: *u8 = c;
    if (one.* != 1 or c.* != 1 or c[1..3][1] != 3) return error.Wrong;
    const words: []const u16 = @ptrCast(get([]align(2) u8, &bytes));
    if (words.len != 2) return error.Wrong;
    var u: U = .{ .int = 5 };
    u.int += 1;
    if (u.int != 6) return error.Wrong;
    fail(error.Whatever) catch unreachable;
}
