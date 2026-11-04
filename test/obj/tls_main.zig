const std = @import("std");

extern fn bs_tls_bump() u32;
export threadlocal var host_tls: u32 = 4;

fn bump(out: *u32) void {
    out.* = bs_tls_bump();
}

// Each thread has its own copy: this thread's two bumps give 5 and 6,
// another thread's first gives 5.
pub fn main(init: std.process.Init) !void {
    const a = bs_tls_bump();
    const b = bs_tls_bump();
    var c: u32 = 0;
    const t = try std.Thread.spawn(.{}, bump, .{&c});
    t.join();
    var buf: [64]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);
    try out.interface.print("{d} {d} {d} {d}\n", .{ a, b, c, host_tls });
    try out.interface.flush();
}
