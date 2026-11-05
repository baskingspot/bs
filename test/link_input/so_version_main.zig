// Loads the library so_version.map versioned (its path in argv[1]) and
// asks glibc's loader for its symbols by version, as programs bind them.
const std = @import("std");

extern "c" fn dlvsym(handle: ?*anyopaque, name: [*:0]const u8, version: [*:0]const u8) ?*anyopaque;

const Fn = *const fn () callconv(.c) c_int;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const h = std.c.dlopen(args[1], .{ .NOW = true }) orelse return error.DlopenFailed;
    const cases = [_]struct { []const u8, [:0]const u8, [:0]const u8 }{
        .{ "ver_old@VER_1.0", "ver_old", "VER_1.0" },
        .{ "ver_new@VER_1.1", "ver_new", "VER_1.1" },
        .{ "ver_new@VER_1.0", "ver_new", "VER_1.0" },
        .{ "ver_c_one@VER_1.0", "ver_c_one", "VER_1.0" },
    };
    for (cases) |c| {
        const label, const name, const version = c;
        if (dlvsym(h, name, version)) |p| {
            std.debug.print("{s} {d}\n", .{ label, @as(Fn, @ptrCast(@alignCast(p)))() });
        } else std.debug.print("{s} none\n", .{label});
    }
    for ([_][:0]const u8{ "ver_hidden", "c_local_fn", "c_local_ptr" }) |name|
        std.debug.print("{s} {s}\n", .{ name, if (std.c.dlsym(h, name) == null) "none" else "exported" });
}
