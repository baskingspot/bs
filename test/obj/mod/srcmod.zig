// Prints the root module's name, which `@src()` shows: its `-M` name, or
// the file's stem without `-M`. A build's donor of another root name
// must not hand it the donor's.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [64]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);
    try out.interface.print("{s}\n", .{@src().module});
    try out.interface.flush();
}
