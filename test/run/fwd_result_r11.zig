//! exit: 0
//! stdout: "4\n"

// A slice the function returns, written in place in its result
// (`planRetCalls`), and read back through a local that forwards it
// (`Live.fwd`): the read goes through r11, so the minimum computed just
// before it, which lives across the read, must not be in r11 (astroz's
// Screening.refine got a stack address as the slice's end).
const std = @import("std");

const Job = struct { p: []const u8, cands: []const u32, events: []u64 };

noinline fn split(gpa: std.mem.Allocator, p: []const u8, cands: []const u32) ![]u64 {
    const events = try gpa.alloc(u64, cands.len);
    var jobs: [16]Job = undefined;
    const per = cands.len / 3 + 1;
    for (jobs[0..3], 0..) |*job, t| job.* = .{
        .p = p,
        .cands = cands[@min(t * per, cands.len)..@min((t + 1) * per, cands.len)],
        .events = events[@min(t * per, cands.len)..@min((t + 1) * per, cands.len)],
    };
    var n: usize = 0;
    for (jobs[0..3]) |j| n += j.events.len + j.cands.len;
    std.debug.assert(n == 8);
    return events;
}

pub fn main(init: std.process.Init) !void {
    var buf: [64]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    const cands: [4]u32 = @splat(1);
    const events = try split(std.heap.page_allocator, "ab", &cands);
    try w.interface.print("{d}\n", .{events.len});
    try w.interface.flush();
}
