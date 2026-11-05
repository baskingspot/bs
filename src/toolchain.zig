//! Upstream zig 0.17.1 as bs finds it at run time: the zig whose lib
//! directory bs compiles against (std, compiler_rt, the build runner,
//! translate-c, libc's sources), and whose `zig clang` compiles C
//! (`CSource`). A released bs has no build tree, so the only build-time
//! path here is the last fallback, for development builds (see "Finding
//! upstream zig" in docs/slop/architecture.md).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const build_options = @import("build_options");
const cache = @import("cache.zig");
const main = @import("main.zig");

const version = main.zig_version;

pub const Found = struct { found: ?[]const u8, looked: []const u8 };

/// Upstream zig: `BS_ZIG`, else `zig` on PATH, else where `.agents/setup`
/// installs it.
pub fn findZig(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) Found {
    const cwd = Io.Dir.cwd();
    if (environ.get("BS_ZIG")) |p| return .{ .found = p, .looked = p };
    if (environ.get("PATH")) |path| {
        var it = std.mem.tokenizeScalar(u8, path, ':');
        while (it.next()) |dir| {
            const p = Io.Dir.path.join(arena, &.{ dir, "zig" }) catch continue;
            if (cwd.access(io, p, .{ .execute = true })) |_| return .{ .found = p, .looked = p } else |_| {}
        }
    }
    const home = environ.get("HOME") orelse return .{ .found = null, .looked = "~/.cache/bs" };
    const host = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);
    for ([_][]const u8{ "zig-" ++ version, "zig-" ++ host ++ "-" ++ version }) |sub| {
        const p = Io.Dir.path.join(arena, &.{ home, ".cache", "bs", sub, "zig" }) catch continue;
        if (cwd.access(io, p, .{ .execute = true })) |_| return .{ .found = p, .looked = p } else |_| {}
    }
    return .{ .found = null, .looked = Io.Dir.path.join(arena, &.{ home, ".cache", "bs", "zig-" ++ host ++ "-" ++ version }) catch "~/.cache/bs" };
}

/// `zig`'s lib directory if it is upstream's 0.17.1, else why not.
const Check = union(enum) { lib_dir: []const u8, bad: []const u8 };

/// Asks `zig` for its version and lib directory (`zig version`, then
/// `zig env`), once per binary: a 0.17.1's lib directory is kept in
/// `<global cache>/bs/zig/<hash>`, keyed by the binary's real path, inode,
/// size, mtime and ctime, so that a build reads one small file instead of
/// running zig (2–5 ms).
fn check(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, global_cache: []const u8, zig: []const u8) !Check {
    const cwd = Io.Dir.cwd();
    const memo: ?[]const u8 = memo: {
        const real = cwd.realPathFileAlloc(io, zig, arena) catch break :memo null;
        const st = cwd.statFile(io, real, .{}) catch break :memo null;
        const key = try arena.print("{s}\x00{d}\x00{d}\x00{d}\x00{d}", .{ real, st.inode, st.size, st.mtime.toNanoseconds(), st.ctime.toNanoseconds() });
        break :memo try arena.print("{s}/bs/zig/{x:0>32}", .{ global_cache, cache.hash(0, key) });
    };
    // `zig` may be a version manager's shim that picks another zig later,
    // but the lib directory it named is still 0.17.1's while it exists.
    if (memo) |m| if (cwd.readFileAlloc(io, m, arena, .limited(4096))) |lib| {
        if (cwd.access(io, try Io.Dir.path.join(arena, &.{ lib, "std", "std.zig" }), .{})) |_| return .{ .lib_dir = lib } else |_| {}
    } else |_| {};

    const ver = std.process.run(arena, io, .{ .argv = &.{ zig, "version" } }) catch |err|
        return .{ .bad = try arena.print("unable to run '{s}': {t}", .{ zig, err }) };
    const got = std.mem.trim(u8, ver.stdout, " \r\n");
    if (!ver.term.success() or !std.mem.eql(u8, got, version))
        return .{ .bad = try arena.print("'{s}' is version '{s}'", .{ zig, got }) };
    // Its own lib directory, not one ZIG_LIB_DIR names.
    var env = try environ.clone(arena);
    _ = env.swapRemove("ZIG_LIB_DIR");
    const res = std.process.run(arena, io, .{ .argv = &.{ zig, "env" }, .environ_map = &env }) catch |err|
        return .{ .bad = try arena.print("unable to run '{s} env': {t}", .{ zig, err }) };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const parsed = std.zon.parse.fromSlice(struct { lib_dir: []const u8 }, .{
        .gpa = arena,
        .arena = arena,
        .source = try arena.dupeSentinel(u8, res.stdout, 0),
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch return .{ .bad = try arena.print("'{s} env' printed no lib directory", .{zig}) };
    if (memo) |m| write: {
        cwd.createDirPath(io, Io.Dir.path.dirname(m).?) catch break :write;
        var atomic = cwd.createFileAtomic(io, m, .{ .replace = true }) catch break :write;
        defer atomic.deinit(io);
        atomic.file.writeStreamingAll(io, parsed.lib_dir) catch break :write;
        atomic.replace(io) catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
    }
    return .{ .lib_dir = parsed.lib_dir };
}

/// The zig lib directory a compilation uses, and whether it is trusted:
/// the default one (`defaultLibDir`), which nobody edits, so that cached
/// builds need not stat its files (`Incremental.trusted_lib`, the build
/// runner's stamp, `main.prefixInputs`).
pub const LibDir = struct { path: []const u8, trusted: bool };

/// `override` (`--zig-lib-dir`, `--zig-lib=`), else ZIG_LIB_DIR, else the
/// default. One given explicitly is trusted if it is the default too, as
/// under `bs build`, which passes the default to every step. Exits with an
/// error when the default is needed and there is none.
pub fn libDir(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, global_cache: []const u8, override: ?[]const u8) !LibDir {
    const explicit = override orelse environ.get("ZIG_LIB_DIR") orelse return switch (try defaultLibDir(arena, io, environ, global_cache)) {
        .path => |p| .{ .path = p, .trusted = true },
        .missing => |msg| main.fatal("{s}", .{msg}),
    };
    const default = switch (try defaultLibDir(arena, io, environ, global_cache)) {
        .path => |p| p,
        .missing => return .{ .path = explicit, .trusted = false },
    };
    const cwd = Io.Dir.cwd();
    const a = cwd.realPathFileAlloc(io, explicit, arena) catch return .{ .path = explicit, .trusted = false };
    const b = cwd.realPathFileAlloc(io, default, arena) catch return .{ .path = explicit, .trusted = false };
    return .{ .path = explicit, .trusted = std.mem.eql(u8, a, b) };
}

/// The lib directory of upstream zig 0.17.1 (`findZig`), else, in a
/// development build, the one bs was built with, if it is still there.
/// Otherwise why there is none, for the user.
fn defaultLibDir(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, global_cache: []const u8) !union(enum) { path: []const u8, missing: []const u8 } {
    const zig = findZig(arena, io, environ);
    const bad: ?[]const u8 = if (zig.found) |p| switch (try check(arena, io, environ, global_cache, p)) {
        .lib_dir => |lib| return .{ .path = lib },
        .bad => |why| why,
    } else null;
    const built = try Io.Dir.path.join(arena, &.{ build_options.zig_lib_dir, "std", "std.zig" });
    if (Io.Dir.cwd().access(io, built, .{})) |_| return .{ .path = build_options.zig_lib_dir } else |_| {}
    const need = "bs needs upstream zig " ++ version ++ ", whose std library it compiles";
    const fix = "install zig " ++ version ++ " and put it on PATH (or set BS_ZIG to it), or pass --zig-lib-dir <its lib directory>";
    return .{ .missing = if (bad) |why|
        try arena.print("{s}, and {s}; {s}", .{ need, why, fix })
    else
        try arena.print("{s}, and found no zig in BS_ZIG, on PATH, or at {s}; {s}", .{ need, zig.looked, fix }) };
}
