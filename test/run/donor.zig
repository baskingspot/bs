//! exit: 0
//! stderr: "donor 42 6765 Odd hi 8\n"
//! donor-without: "    const e = if (check(3)) |_| \"ok\" else |err| @errorName(err);\n    var c = std.Io.Writer.Allocating.initCapacity(std.heap.page_allocator, 8) catch return;\n    defer c.deinit();\n    std.debug.print(\"donor {d} {d} {s} {s} {d}\\n\", .{ answer, fib(20), e, a.written(), c.writer.buffer.len });\n"
//! A first build that replays another program's graph (a donor): the
//! donor lacks the print, so std's formatting is partly new, and std's
//! `@import("root")` names this program's root file, not the donor's.
//! `initCapacity` takes `&vtable`, whose value the donor resolved
//! (`init`): it must still depend on `VTable`'s layout, as in a full
//! build, which analyzes it first.
const std = @import("std");

const answer = 42;

fn fib(n: u32) u32 {
    return if (n < 2) n else fib(n - 1) + fib(n - 2);
}

fn check(n: u32) error{ Odd, Big }!void {
    if (n > 100) return error.Big;
    if (n % 2 == 1) return error.Odd;
}

pub fn main() void {
    var a: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer a.deinit();
    a.writer.writeAll("hi") catch return;
    const e = if (check(3)) |_| "ok" else |err| @errorName(err);
    var c = std.Io.Writer.Allocating.initCapacity(std.heap.page_allocator, 8) catch return;
    defer c.deinit();
    std.debug.print("donor {d} {d} {s} {s} {d}\n", .{ answer, fib(20), e, a.written(), c.writer.buffer.len });
}
