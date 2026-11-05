// Adapted from zigcli's src/bin/cowsay.zig and src/bin/util.zig
// (https://github.com/jiacai2050/zigcli), MIT License, Copyright (c) Jiacai Liu.
const std = @import("std");
const builtin = @import("builtin");
const Writer = std.Io.Writer;
const mem = std.mem;

// The default ASCII cow art.
const cow_art: []const u8 =
    \\        \   ^__^
    \\         \  (oo)\_______
    \\            (__)\       )\/\
    \\                ||----w |
    \\                ||     ||
    \\
;

// The Tux (Linux penguin) ASCII art.
const tux_art: []const u8 =
    \\   \
    \\    \
    \\        .--.
    \\       |o_o |
    \\       |:_/ |
    \\      //   \ \
    \\     (|     | )
    \\    /'\_   _/`\
    \\    \___)=(___/
    \\
;

const CowFace = enum {
    cow,
    tux,
};

const Allocator = struct {
    debug_allocator: std.heap.DebugAllocator(.{}),
    is_debug: bool,

    pub const instance: Allocator = .{
        .debug_allocator = .init,
        .is_debug = switch (builtin.mode) {
            .Debug, .ReleaseSafe => true,
            .ReleaseFast, .ReleaseSmall => false,
        },
    };

    pub fn allocator(self: *Allocator) mem.Allocator {
        return switch (builtin.mode) {
            .Debug, .ReleaseSafe => self.debug_allocator.allocator(),
            .ReleaseFast, .ReleaseSmall => std.heap.smp_allocator,
        };
    }

    pub fn deinit(self: *Allocator) void {
        if (self.is_debug and self.debug_allocator.deinit() != .ok) {
            @panic("mem leaked");
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var gpa = Allocator.instance;
    defer gpa.deinit();
    const allocator = gpa.allocator();

    var face: CowFace = .cow;
    var words: std.ArrayList([]const u8) = .empty;
    defer words.deinit(allocator);
    var it = init.minimal.args.iterate();
    _ = it.skip();
    while (it.next()) |arg| {
        if (mem.startsWith(u8, arg, "--face=")) {
            face = std.meta.stringToEnum(CowFace, arg["--face=".len..]) orelse return error.InvalidFace;
        } else {
            try words.append(allocator, arg);
        }
    }

    // Join all positional arguments with spaces to form the message.
    var message_parts_buf: [4096]u8 = undefined;
    const message: []const u8 = if (words.items.len == 0)
        ""
    else blk: {
        var fbs: std.Io.Writer = .fixed(&message_parts_buf);
        for (words.items, 0..) |arg, i| {
            if (i > 0) try fbs.writeByte(' ');
            try fbs.writeAll(arg);
        }
        break :blk fbs.buffered();
    };

    const stdout = std.Io.File.stdout();
    var output_buf: [8192]u8 = undefined;
    var writer = stdout.writer(init.io, &output_buf);

    try writeSpeechBubble(&writer.interface, message);

    const art = switch (face) {
        .cow => cow_art,
        .tux => tux_art,
    };
    try writer.interface.writeAll(art);
    try writer.interface.flush();
}

/// Renders a speech bubble around the given message to the writer.
/// Single-line messages use `< text >` borders.
/// Multi-line messages use `/`, `|`, `\` borders on the sides.
fn writeSpeechBubble(writer: *Writer, message: []const u8) !void {
    // Collect lines and find the maximum line width.
    var lines_buf: [64][]const u8 = undefined;
    var line_count: usize = 0;
    var max_width: usize = 0;

    var iter = mem.splitScalar(u8, message, '\n');
    while (iter.next()) |line| {
        if (line_count >= lines_buf.len) break;
        lines_buf[line_count] = line;
        line_count += 1;
        if (line.len > max_width) {
            max_width = line.len;
        }
    }

    const lines = lines_buf[0..line_count];
    // The border width includes one space of padding on each side.
    const border_width = max_width + 2;

    // Write the top border: a space then `border_width` underscores.
    try writer.writeAll(" ");
    for (0..border_width) |_| try writer.writeAll("_");
    try writer.writeAll("\n");

    // Write message lines with box-drawing characters.
    if (lines.len == 1) {
        // Single line: use angle brackets.
        try writer.writeAll("< ");
        try writer.writeAll(lines[0]);
        try writer.writeAll(" >\n");
    } else {
        for (lines, 0..) |line, i| {
            const left = if (i == 0) "/ " else if (i == lines.len - 1) "\\ " else "| ";
            const right = if (i == 0) " \\" else if (i == lines.len - 1) " /" else " |";
            try writer.writeAll(left);
            try writer.writeAll(line);
            // Pad shorter lines to the maximum width so all borders align.
            for (0..max_width - line.len) |_| try writer.writeAll(" ");
            try writer.writeAll(right);
            try writer.writeAll("\n");
        }
    }

    // Write the bottom border: a space then `border_width` dashes.
    try writer.writeAll(" ");
    for (0..border_width) |_| try writer.writeAll("-");
    try writer.writeAll("\n");
}
