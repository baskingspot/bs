//! exit: 0
//! stderr: "hello ello 5 2 30 5 false hello\n7 llo true true\n"
//! rebuild-without: "    counter_ptr.* += 1;\n"
//! rebuild-replace: "const pr_b: *c_int = &pr.b;" "const pr_b: *c_int = &pr.a;"
//! Comptime-known pointers to data that a symbol defines, from `@extern`
//! and `&` of an `extern var`, as translate-c's container-level `@extern`
//! constants make them: read at run time at their start and at offsets
//! into them, compared at comptime (each `@extern` site its own pointer,
//! as upstream's), and stored in a global variable's data. The program
//! exports the symbols itself. The edits change a function that uses a
//! kept slot, and a pointer whose offset into its symbol moves.
const std = @import("std");

const defs = struct {
    export const msg: [5:0]u8 = "hello".*;
    export var counter: c_int = 5;
    export var pr: Pair = .{ .a = 1, .b = 2 };
    export var arr: [4]c_int = .{ 10, 20, 30, 40 };
};

const msg: [*c]const u8 = @extern([*c]const u8, .{ .name = "msg" });
const msg2: [*c]const u8 = @extern([*c]const u8, .{ .name = "msg" });
const counter_ptr: *c_int = @extern(*c_int, .{ .name = "counter" });
const Pair = extern struct { a: c_int, b: c_int };
const pr: *Pair = @extern(*Pair, .{ .name = "pr" });
const pr_b: *c_int = &pr.b;
const arr: *[4]c_int = @extern(*[4]c_int, .{ .name = "arr" });
const arr2: *c_int = &arr[2];
const msg_plus: [*c]const u8 = msg + 1;
const CV = struct {
    extern var counter: c_int;
};
const cv_ptr: *c_int = &CV.counter;
const same = msg == msg2;
const S = struct { p: *c_int, q: [*c]const u8 };
const s_data: S = .{ .p = counter_ptr, .q = msg };
var s_var: S = .{ .p = &arr[0], .q = msg + 2 };

comptime {
    std.debug.assert(msg == msg and msg != null and msg + 1 == msg_plus and &CV.counter == cv_ptr);
    std.debug.assert(counter_ptr != &defs.counter);
}

pub fn main() void {
    var r: [*c]const u8 = undefined;
    r = msg;
    counter_ptr.* += 1;
    std.debug.print("{s} {s} {d} {d} {d} {d} {} {s}\n", .{ r, msg_plus, s_data.p.* - 1, pr_b.* * 2 - pr.b, arr2.*, cv_ptr.* - 1, same, s_data.q });
    s_var.p.* = 7;
    std.debug.print("{d} {s} {} {}\n", .{ arr[0], s_var.q, @intFromPtr(counter_ptr) == @intFromPtr(cv_ptr), @intFromPtr(pr_b) - @intFromPtr(pr) == @offsetOf(Pair, "b") });
}
