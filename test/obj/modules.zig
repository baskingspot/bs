// Modules rooted at files other than Zig source, as `zig build` passes them
// (`-Mname=file`): `@import` of a ZON module (superhtml's
// language-tag-registry) and `@embedFile` of a module's root file by the
// module's name (zls's lsp-codegen, anyzig's version).
const std = @import("std");
const config = @import("config");

pub fn main(init: std.process.Init) !void {
    const Config = struct { name: []const u8, level: u32 };
    const c: Config = @import("config");
    var buf: [256]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);
    try out.interface.print("{s} {d} {s} {d}\n", .{ config.name, c.level, @embedFile("version"), @embedFile("config").len });
    try out.interface.flush();
}
