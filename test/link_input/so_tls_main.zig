//! A shared library's thread-local (test/link_input/so_tls.c), read and
//! written from Zig and from C objects of three TLS models
//! (so_tls_user.c), on two threads.
const std = @import("std");

extern threadlocal var so_tls: c_int;
extern fn so_get() c_int;
extern fn get_gd() c_int;
extern fn add_gd(c_int) void;
extern fn get_desc() c_int;
extern fn add_desc(c_int) void;
extern fn get_ie() c_int;
extern fn add_ie(c_int) void;

fn show(tag: []const u8) void {
    std.debug.print("{s}: {d} {d} {d} {d} {d}\n", .{ tag, so_tls, get_gd(), get_desc(), get_ie(), so_get() });
}

pub fn main() !void {
    show("main");
    add_gd(1);
    add_desc(10);
    add_ie(100);
    so_tls += 1000;
    show("set");
    const t = try std.Thread.spawn(.{}, show, .{"thread"});
    t.join();
    show("after");
}
