//! signal: ABRT
//! stderr-contains: "Segmentation fault at address 0x"
//! stderr-contains: " in big ("
//! stderr-contains: " in thread ("

// A frame larger than a page touches each page as it grows the stack, as
// upstream: a spawned thread whose frame is larger than its whole stack
// faults on the guard page instead of stepping over it. Memory mapped
// right below the thread's stack makes the difference visible: without
// probes, the frame would land in it and the thread would return.
const std = @import("std");

var go: std.atomic.Value(bool) = .init(false);
var touch = false;

/// Its frame holds `buf` even when `touch` is false; then the only access
/// to it is the call's return address, at the bottom. `noinline`: inlined
/// into `thread`, keeping its call of `doNotOptimizeAway`, its frame would
/// be `thread`'s, and a fault there has no frame of its own
/// (docs/slop/architecture.md, "Synthetic frames").
noinline fn big() void {
    if (touch) {
        var buf: [128 * 1024]u8 = undefined;
        std.mem.doNotOptimizeAway(&buf);
    }
    leaf();
}

fn leaf() void {}

fn thread() void {
    while (!go.load(.acquire)) std.atomic.spinLoopHint();
    big();
}

pub fn main() !void {
    const t = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, thread, .{});
    // The next mapping goes right below the thread's.
    const below = try std.posix.mmap(null, 4 << 20, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    _ = below;
    go.store(true, .release);
    t.join();
    std.debug.print("the thread returned\n", .{});
}
