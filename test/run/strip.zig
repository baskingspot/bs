//! exit: 0
//! stdout: "1\n42\n"
//! flags: -fstrip
//! -fstrip: the program says it has no debug info and runs without it,
//! as upstream's. Also from upstream's test/standalone/strip_struct_init,
//! an inline call whose return type is comptime-only returns through a
//! comptime result location.
const rt = @import("rt.zig");
pub const panic = rt.panic;

fn Func(comptime Type: type) type {
    return struct { value: Type };
}

inline fn func(value: anytype) Func(@TypeOf(value)) {
    return .{ .value = value };
}

pub fn main() void {
    rt.printInt(@intFromBool(@import("builtin").strip_debug_info));
    const f = func(u64);
    const x: f.value = 42;
    rt.printInt(x);
}
