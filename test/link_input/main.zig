//! Calls into C objects and archives that zap links (build.zig,
//! `addLinkInputTests`), and is called back from them; upstream's link of
//! the same inputs prints the same.
const std = @import("std");
extern fn c_sum_pairs() c_int;
extern fn c_call_zig(x: c_int) c_int;
extern fn c_len(s: [*:0]const u8) usize;
extern fn c_str(i: c_int) [*:0]const u8;
extern fn c_has_hook() c_int;
extern fn c_zig_name_len() c_int;
extern fn c_copy(d: [*]u8, s: [*]const u8, n: usize) void;
extern fn c_tls() c_int;
extern fn c_tls_ie2() c_int;
extern fn a1(x: c_int) c_int;
extern var c_greeting: [*:0]const u8;
extern var c_common_var: c_int;
// As translate-c declares `extern const char c_msg[];`: comptime-known
// addresses the link binds to the object's definitions, read through
// slots in code and written directly in a variable's data.
const c_msg: [*c]const u8 = @extern([*c]const u8, .{ .name = "c_msg" });
const c_arr2: *c_int = &@extern(*[4]c_int, .{ .name = "c_arr" })[2];
var c_refs: struct { msg: [*c]const u8, arr: *c_int } = .{ .msg = c_msg + 7, .arr = c_arr2 };
const fn_table = [_]*const fn (c_int) callconv(.c) c_int{&a1};
export fn zig_add(a: c_int, b: c_int) c_int {
    return a + b;
}
export const zig_name: [*:0]const u8 = "zig!";

pub fn main() void {
    c_common_var = 9;
    var buf: [300]u8 = undefined;
    c_copy(&buf, "copied", 7);
    std.debug.print("{d} {d} {d} {s} {s} {d} {d} {d} {s}\n", .{ c_sum_pairs(), c_call_zig(3), c_len(c_greeting), c_str(2), c_greeting, c_has_hook(), c_zig_name_len(), c_common_var, std.mem.sliceTo(&buf, 0) });
    // Each thread its own thread-locals, through the relaxed sequences.
    const t = std.Thread.spawn(.{}, struct {
        fn f() void {
            std.debug.print("thread {d}\n", .{c_tls()});
        }
    }.f, .{}) catch unreachable;
    t.join();
    std.debug.print("{d} {d} {d}\n", .{ c_tls(), c_tls_ie2(), a1(5) });
    std.debug.print("{s} {s} {d} {d}\n", .{ c_msg, c_refs.msg, c_arr2.*, c_refs.arr.* });
    // Constants a function reads, which CodeGen writes while analysis
    // runs: the link binds their addresses as the symbols' slots.
    var i: usize = 0;
    _ = &i;
    const strs = [_][*c]const u8{ c_msg, c_msg + 7 };
    const fns = [_]*const fn (c_int) callconv(.c) c_int{ &a1, &c_call_zig };
    std.debug.print("{s} {s} {d} {d} {d}\n", .{ strs[i], strs[i + 1], fns[i](5), fns[i + 1](3), fn_table[i](1) });
}
