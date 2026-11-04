const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buffer: [256]u8 = undefined;
    var file_reader: std.Io.File.Reader = .init(.stdin(), io, &buffer);
    const in = &file_reader.interface;
    var lines: usize = 0;
    while (try in.takeDelimiter('\n')) |line| {
        if (line.len == 0) break;
        lines += 1;
    }
    std.debug.print("{d} lines\n", .{lines});
}
