//! Thread-locals of a C object compiled with -mtls-dialect=gnu2, read and
//! written from Zig and C, on two threads (test/link_input/tlsdesc.c).
const std = @import("std");

export threadlocal var z_tls: c_int = 9;
extern threadlocal var c_tls: c_int;
extern fn c_get() c_int;
extern fn c_set(c_int) void;
extern fn c_get_z() c_int;
extern fn c_set_z(c_int) void;
extern fn c_addr() *c_int;

fn show(tag: []const u8) void {
    std.debug.print("{s}: {d} {d} {d} {d} {}\n", .{ tag, c_get(), c_get_z(), c_tls, z_tls, c_addr() == &c_tls });
}

pub fn main() !void {
    show("main");
    c_set(20);
    c_set_z(30);
    c_tls += 1;
    z_tls += 1;
    show("set");
    const t = try std.Thread.spawn(.{}, show, .{"thread"});
    t.join();
    show("after");
}
