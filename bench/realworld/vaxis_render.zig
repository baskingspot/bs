//! libvaxis's render path without a terminal: lays out styled, wrapped
//! text (ASCII, accented, CJK, emoji) into a 200x60 screen each frame and
//! renders the frame's escape sequences into memory. Prints the bytes
//! rendered and a hash of the last frame, so builds can be compared.
const std = @import("std");
const vaxis = @import("vaxis");

/// Exported and mutable, so no compiler treats the problem size as known.
export var frames: usize = 400;

pub const std_options: std.Options = .{ .log_level = .info };

const words = [_][]const u8{
    "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dogs", "café", "naïve", "résumé",
    "漢字", "かな", "한글", "🙂", "👩‍💻", "🚀", "terminal", "render", "cells", "graphemes", "width",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;
    var vx = try vaxis.init(io, alloc, init.environ_map, .{});
    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    defer vx.deinit(alloc, &sink.writer);
    try vx.resize(alloc, &sink.writer, .{ .rows = 60, .cols = 200, .x_pixel = 0, .y_pixel = 0 });
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    var total: usize = 0;
    var rng: u64 = 0x9e3779b97f4a7c15;
    for (0..frames) |f| {
        const win = vx.window();
        win.clear();
        var segs: [48]vaxis.Segment = undefined;
        text.clearRetainingCapacity();
        // Words chosen by a fixed sequence, so every build renders the same.
        var offs: [48][2]usize = undefined;
        for (&offs, 0..) |*o, i| {
            rng = rng *% 6364136223846793005 +% 1442695040888963407;
            const start = text.items.len;
            for (0..8) |_| {
                rng = rng *% 6364136223846793005 +% 1442695040888963407;
                try text.appendSlice(alloc, words[(rng >> 33) % words.len]);
                try text.append(alloc, ' ');
            }
            o.* = .{ start, text.items.len };
            _ = i;
        }
        for (&segs, offs, 0..) |*s, o, i| s.* = .{
            .text = text.items[o[0]..o[1]],
            .style = .{
                .fg = .{ .index = @intCast((i + f) % 16) },
                .bold = i % 3 == 0,
                .italic = i % 5 == 0,
            },
        };
        const left = win.child(.{ .width = 120, .height = 60 });
        const right = win.child(.{ .x_off = 121, .width = 79, .height = 60 });
        _ = left.print(&segs, .{ .wrap = .word });
        _ = right.print(segs[f % 16 ..][0..24], .{ .wrap = .grapheme });
        sink.clearRetainingCapacity();
        try vx.render(&sink.writer);
        total += sink.written().len;
    }
    std.debug.print("{d} {x}\n", .{ total, std.hash.Wyhash.hash(0, sink.written()) });
}
