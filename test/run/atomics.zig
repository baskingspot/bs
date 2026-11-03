//! exit: 0
//! stdout: "5\n10\n15\n12\n268\n7\n9\n2\n253\n253\n251\n1\n4\n1\n1\n2\n11\n27\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;
// For `std.lang.AtomicOrder` and `AtomicRmwOp`; std.start sees `_start` and stays out.
const std = @import("std");
pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}
var g: u32 = 5;
var s8: i8 = -3;
var p: ?*u32 = null;
// Like std.Io.Threaded's group status: integer operations on a packed
// struct, and @bitCast between it and usize.
const Status = packed struct(usize) { have_awaiter: bool, num_running: u63 };
var status: Status = .{ .have_awaiter = true, .num_running = 2 };
fn main() callconv(.c) noreturn {
    // Loads, stores, xadd, cmpxchg loops (signed and unsigned), and cmpxchg
    // with integer and pointer-like optional results.
    rt.printInt(@atomicLoad(u32, &g, .seq_cst));
    @atomicStore(u32, &g, 10, .release);
    rt.printInt(@atomicRmw(u32, &g, .Add, 5, .monotonic));
    rt.printInt(@atomicRmw(u32, &g, .Sub, 3, .monotonic));
    rt.printInt(@atomicRmw(u32, &g, .Or, 0x100, .monotonic));
    rt.printInt(@atomicRmw(u32, &g, .Xchg, 7, .acq_rel));
    rt.printInt(@atomicRmw(u32, &g, .Max, 9, .acq_rel));
    rt.printInt(@atomicRmw(u32, &g, .Min, 2, .acq_rel));
    rt.printInt(g);
    rt.printInt(@as(u8, @bitCast(@atomicRmw(i8, &s8, .Max, -5, .seq_cst))));
    rt.printInt(@as(u8, @bitCast(@atomicRmw(i8, &s8, .Min, -5, .seq_cst))));
    rt.printInt(@as(u8, @bitCast(s8)));
    rt.printInt(@intFromBool(@cmpxchgStrong(u32, &g, 2, 4, .seq_cst, .seq_cst) == null));
    rt.printInt(@cmpxchgWeak(u32, &g, 2, 6, .seq_cst, .seq_cst).?);
    rt.printInt(@intFromBool(@cmpxchgStrong(?*u32, &p, null, &g, .seq_cst, .seq_cst) == null));
    rt.printInt(@intFromBool(@cmpxchgStrong(?*u32, &p, null, &g, .seq_cst, .seq_cst).? == &g));
    const old = @atomicRmw(Status, &status, .Add, .{ .have_awaiter = false, .num_running = 3 }, .acq_rel);
    rt.printInt(old.num_running);
    rt.printInt(@as(usize, @bitCast(@atomicRmw(Status, &status, .Or, @as(Status, @bitCast(@as(usize, 0x10))), .acq_rel))));
    rt.printInt(@as(usize, @bitCast(status)));
    rt.exit(0);
}
