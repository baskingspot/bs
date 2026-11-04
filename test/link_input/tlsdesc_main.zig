//! Thread-locals of a C object compiled with -mtls-dialect=gnu2, read and
//! written from Zig and C, on two threads (test/link_input/tlsdesc.c).
//! Zig reaches C's through a pointer: an `extern threadlocal` that a C
//! object defines is not linked yet (`Emit.tlsTarget`).
const std = @import("std");

export threadlocal var z_tls: c_int = 9;
extern fn c_get() c_int;
extern fn c_set(c_int) void;
extern fn c_get_z() c_int;
extern fn c_set_z(c_int) void;
extern fn c_addr() *c_int;

var main_addr: *c_int = undefined;

fn show(tag: []const u8) void {
    std.debug.print("{s}: {d} {d} {d} {d} {}\n", .{ tag, c_get(), c_get_z(), c_addr().*, z_tls, c_addr() == main_addr });
}

pub fn main() !void {
    main_addr = c_addr();
    show("main");
    c_set(20);
    c_set_z(30);
    c_addr().* += 1;
    z_tls += 1;
    show("set");
    const t = try std.Thread.spawn(.{}, show, .{"thread"});
    t.join();
    show("after");
}
