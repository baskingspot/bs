//! A C object whose undefined behavior and smashed stack reach the
//! runtimes zap links for C (ubsan_rt, compiler_rt's stack protector).
const std = @import("std");
extern fn c_overflow(x: c_int) c_int;
extern fn c_smash(s: [*:0]const u8) void;
pub fn main(init: std.process.Init) !void {
    var it = init.minimal.args.iterate();
    _ = it.skip();
    const which = it.next() orelse "o";
    if (which[0] == 'o') std.debug.print("{d}\n", .{c_overflow(5)}) else c_smash("this string is far too long for eight bytes");
}
