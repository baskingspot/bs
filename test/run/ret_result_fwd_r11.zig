//! exit: 0
//! stderr: "36 648 36\n8\n"
//! A function returning `![]Rect` in memory keeps the call's result in
//! its own (`Home.result`), read through r11. A load forwarded from the
//! payload (`Live.fwd`) takes that home only when emitted, so `usesR11`
//! has to see through it at planning time: the loop index used to get r11
//! and was overwritten by the result pointer (teru's accordion layout;
//! astroz's Screening refine indexed with the pointer the same way).
const std = @import("std");
const Rect = struct { x: u16, y: u16, width: u16, height: u16 };

noinline fn accordion(allocator: std.mem.Allocator, count: usize, screen: Rect, active: usize) ![]Rect {
    const rects = try allocator.alloc(Rect, count);
    if (count == 1) {
        rects[0] = screen;
        return rects;
    }
    const cnt_u16: u16 = @intCast(count);
    const per_collapsed: u16 = (screen.height / 2) / (cnt_u16 - 1);
    const min_h: u16 = @max(@min(36, per_collapsed), 8);
    const active_h: u16 = screen.height -| min_h * (cnt_u16 - 1);
    const clamped_active = @min(active, count - 1);
    var y: u16 = screen.y;
    for (0..count) |i| {
        const h: u16 = if (i == clamped_active) active_h else min_h;
        rects[i] = .{ .x = screen.x, .y = y, .width = screen.width, .height = h };
        y +|= h;
    }
    return rects;
}

const Job = struct { cands: []const u32, events: []u64, jd0: f64, dt: f64 };
fn getMax() usize {
    return 16;
}

noinline fn refine(gpa: std.mem.Allocator, cands: []const u32, jd0: f64, dt: f64) ![]u64 {
    const events = try gpa.alloc(u64, cands.len);
    if (cands.len == 0) return events;
    var jobs: [64]Job = undefined;
    const nt = @max(@min(getMax(), cands.len), 1);
    const per = @divCeil(cands.len, nt);
    for (jobs[0..nt], 0..) |*job, t| job.* = .{
        .cands = cands[@min(t * per, cands.len)..@min((t + 1) * per, cands.len)],
        .events = events[@min(t * per, cands.len)..@min((t + 1) * per, cands.len)],
        .jd0 = jd0,
        .dt = dt,
    };
    var s: usize = 0;
    for (jobs[0..nt]) |j| s += j.cands.len + j.events.len;
    std.debug.print("{d}\n", .{s});
    return events;
}

pub fn main() !void {
    var buf: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const r = try accordion(fba.allocator(), 3, .{ .x = 0, .y = 0, .width = 1280, .height = 720 }, 0);
    std.debug.print("{d} {d} {d}\n", .{ r[1].height, r[0].height, r[2].height });
    const c = [_]u32{ 1, 2, 3, 4 };
    _ = try refine(fba.allocator(), &c, 1.0, 2.0);
}
