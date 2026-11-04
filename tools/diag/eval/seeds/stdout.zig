const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buffer: [1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &file_writer.interface;
    try out.print("hello, {s}!\n", .{"world"});
    try out.writeAll("done\n");
    try out.flush();
}
