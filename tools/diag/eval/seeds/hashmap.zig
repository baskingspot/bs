const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    defer counts.deinit(gpa);
    const words = [_][]const u8{ "a", "b", "a", "c", "a" };
    for (words) |w| {
        const entry = try counts.getOrPut(gpa, w);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }
    var it = counts.iterator();
    while (it.next()) |kv| {
        std.debug.print("{s}: {d}\n", .{ kv.key_ptr.*, kv.value_ptr.* });
    }
    const a = counts.get("a") orelse 0;
    std.debug.print("a = {d}\n", .{a});
}
