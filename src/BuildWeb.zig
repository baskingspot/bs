//! The build runner's web UI client, which `zig build --fuzz` without a
//! limit serves. Upstream's runner compiles lib/build-web for wasm32 with
//! the build's compiler (`buildClientWasm` in
//! lib/compiler/Maker/WebServer.zig) over `--listen=-`, and reads the
//! binary from `<cache dir>/o/<digest>/build-web.wasm`. bs has no wasm
//! backend, so bs's build compiles the client with upstream zig from bs's
//! default zig lib directory and embeds it (`build_web_wasm`), as
//! `-femit-docs` embeds the docs viewer (src/Docs.zig), and bs answers
//! that one command with it.

const std = @import("std");
const Io = std.Io;
const main = @import("main.zig");
const cache = @import("cache.zig");

const wasm = @embedFile("build_web_wasm");

/// Whether `opts` is the runner's compile of its web client.
pub fn matches(opts: *const main.Options) bool {
    const target = opts.target orelse return false;
    return opts.command == .build_exe and std.mem.eql(u8, target, "wasm32-freestanding") and
        std.mem.eql(u8, opts.name orelse "", "build-web") and std.mem.endsWith(u8, opts.root_src_path, "build-web/main.zig");
}

/// Answers each update by writing the embedded client where the runner
/// looks for it.
pub fn serve(init: std.process.Init, opts: *const main.Options) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var digest: [16]u8 = undefined;
    std.crypto.hash.Blake3.hash(wasm, &digest, .{});
    const dir = try Io.Dir.path.join(arena, &.{ opts.cache_dir orelse ".zig-cache", "o", &std.fmt.bytesToHex(digest, .lower) });

    var in_buf: [256]u8 = undefined;
    var out_buf: [4096]u8 = undefined;
    var in = Io.File.stdin().readerStreaming(io, &in_buf);
    var out = Io.File.stdout().writerStreaming(io, &out_buf);
    var server: std.zig.Server = .{ .in = &in.interface, .out = &out.interface };
    try server.serveStringMessage(.zig_version, main.zig_version);
    while (true) {
        const hdr = server.receiveMessage() catch |err| switch (err) {
            error.EndOfStream => std.process.exit(0),
            else => |e| return e,
        };
        switch (hdr.tag) {
            .exit => std.process.exit(0),
            .update => {
                try server.in.discardAll(hdr.bytes_len);
                var d = try Io.Dir.cwd().createDirPathOpen(io, dir, .{});
                defer d.close(io);
                const hit = if (d.access(io, "build-web.wasm", .{})) |_| true else |_| false;
                if (!hit) try cache.writeReplace(io, d, "build-web.wasm", &.{wasm});
                try server.serveEmitDigest(&digest, .{ .flags = .{ .cache_hit = hit } });
                try server.serveErrorBundle(.error_bundle, .empty);
            },
            else => main.fatal("unrecognized message from client: 0x{x}", .{@backingInt(hdr.tag)}),
        }
    }
}
