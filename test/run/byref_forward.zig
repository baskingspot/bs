//! exit: 0
//! stderr: "8 5 6\n"
//! A by-value struct parameter passed on to a method (`self.f()`) is the
//! caller's memory, passed without a copy; a global's value passed by
//! value is still a copy that the callee's writes to the global do not
//! change.
const std = @import("std");
const T = struct {
    len: u64,
    cap: u64,
    p: [*]const u8,
    noinline fn capacity(t: T) u64 {
        if (t.len == 0) return 0;
        return t.cap + t.p[0];
    }
    noinline fn viaMethod(self: T) u64 {
        return self.capacity() + 1;
    }
    noinline fn clobber(t: T) u64 {
        g.len = 99;
        return t.len;
    }
    noinline fn viaClobber(self: T) u64 {
        return self.clobber();
    }
};
var g: T = .{ .len = 5, .cap = 1, .p = "\x00" };
pub fn main() void {
    const t: T = .{ .len = 3, .cap = 7, .p = "\x00" };
    const a = T.viaMethod(t);
    const b = T.viaClobber(g);
    g.len = 6;
    const c = g.clobber();
    std.debug.print("{d} {d} {d}\n", .{ a, b, c });
}
