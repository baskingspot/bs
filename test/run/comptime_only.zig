//! exit: 0
//! A struct with a `type` field is comptime-only, so a parameter of it is
//! implicitly comptime even when the argument is a runtime-looking
//! initializer; a pointer to it is a runtime type, and the struct's runtime
//! fields are in memory.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const F = struct { x: u16, t: type = u8 };
const S = struct { f: F, n: u32 };
fn byValue(s: S) u16 {
    return s.f.x;
}
fn byPtr(s: *const S) u32 {
    return s.f.x + s.n;
}
const Mixed = struct { index: u32, T: type };
fn sum(items: []const Mixed) u32 {
    var total: u32 = 0;
    for (items) |*m| total += m.index;
    return total;
}

fn main() callconv(.c) noreturn {
    if (byValue(.{ .f = .{ .x = 1 }, .n = 2 }) != 1) rt.exit(1);
    const s: S = .{ .f = .{ .x = 3 }, .n = 4 };
    var p: *const S = &s;
    _ = &p;
    if (byPtr(p) != 7) rt.exit(2);
    if (sum(&.{ .{ .index = 10, .T = u8 }, .{ .index = 11, .T = void } }) != 21) rt.exit(3);
    rt.exit(0);
}
