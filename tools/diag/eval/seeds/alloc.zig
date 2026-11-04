const std = @import("std");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const buf = try arena.alloc(u8, 16);
    @memset(buf, 'z');
    const page = try std.heap.page_allocator.alloc(u8, 8);
    defer std.heap.page_allocator.free(page);
    @memcpy(page, buf[0..8]);
    std.debug.print("{s}\n", .{page});
}
