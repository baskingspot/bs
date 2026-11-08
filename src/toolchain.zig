//! Upstream zig as bs finds it at run time, one release per language bs
//! compiles (`language.Language`): the zig whose lib directory bs
//! compiles against (std, compiler_rt, the build runner, translate-c,
//! libc's sources), and whose `zig clang` compiles C (`CSource`). A
//! released bs has no build tree, so the only build-time path here is the
//! last fallback, for development builds of the newest language (see
//! "Finding upstream zig" in docs/slop/architecture.md).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const build_options = @import("build_options");
const cache = @import("cache.zig");
const main = @import("main.zig");
const Language = @import("language.zig").Language;

pub const Found = struct { found: ?[]const u8, looked: []const u8 };

/// Upstream zig 0.17.1 (`findZigFor`).
pub fn findZig(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) Found {
    return findZigFor(arena, io, environ, .zig_0_17);
}

/// The environment variable that names the upstream zig of `language`.
pub fn envVar(language: Language) []const u8 {
    return switch (language) {
        .zig_0_16 => "BS_ZIG_0_16",
        .zig_0_17 => "BS_ZIG",
    };
}

/// The upstream zig of `language`. For the newest: `BS_ZIG`, else `zig`
/// on PATH, else where `.agents/setup` installs it. For 0.16:
/// `BS_ZIG_0_16`, else where `.agents/setup` installs it, else `zig` on
/// PATH, which is usually the newest release's.
pub fn findZigFor(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, language: Language) Found {
    if (environ.get(envVar(language))) |p| return .{ .found = p, .looked = p };
    return switch (language) {
        .zig_0_17 => onPath(arena, io, environ) orelse installed(arena, io, environ, language),
        .zig_0_16 => blk: {
            const in_cache = installed(arena, io, environ, language);
            break :blk if (in_cache.found != null) in_cache else onPath(arena, io, environ) orelse in_cache;
        },
    };
}

fn onPath(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) ?Found {
    const path = environ.get("PATH") orelse return null;
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |dir| {
        const p = Io.Dir.path.join(arena, &.{ dir, "zig" }) catch continue;
        if (Io.Dir.cwd().access(io, p, .{ .execute = true })) |_| return .{ .found = p, .looked = p } else |_| {}
    }
    return null;
}

fn installed(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, language: Language) Found {
    const version = language.versionString();
    const home = environ.get("HOME") orelse return .{ .found = null, .looked = "~/.cache/bs" };
    const host = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);
    const subs = [_][]const u8{
        arena.print("zig-{s}", .{version}) catch "",
        arena.print("zig-{s}-{s}", .{ host, version }) catch "",
    };
    for (subs) |sub| {
        const p = Io.Dir.path.join(arena, &.{ home, ".cache", "bs", sub, "zig" }) catch continue;
        if (Io.Dir.cwd().access(io, p, .{ .execute = true })) |_| return .{ .found = p, .looked = p } else |_| {}
    }
    return .{ .found = null, .looked = Io.Dir.path.join(arena, &.{ home, ".cache", "bs", subs[1] }) catch "~/.cache/bs" };
}

/// `zig`'s lib directory if it is upstream's `version`, else why not.
const Check = union(enum) { lib_dir: []const u8, bad: []const u8 };

/// Asks `zig` for its version and lib directory (`zig version`, then
/// `zig env`), once per binary and version: its lib directory is kept in
/// `<global cache>/bs/zig/<hash>`, keyed by the binary's real path, inode,
/// size, mtime and ctime, and the version for any but the newest, so that
/// a build reads one small file instead of running zig (2–5 ms).
fn check(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, global_cache: []const u8, zig: []const u8, version: []const u8) !Check {
    const cwd = Io.Dir.cwd();
    const memo: ?[]const u8 = memo: {
        const real = cwd.realPathFileAlloc(io, zig, arena) catch break :memo null;
        const st = cwd.statFile(io, real, .{}) catch break :memo null;
        const key = try arena.print("{s}\x00{d}\x00{d}\x00{d}\x00{d}{s}", .{ real, st.inode, st.size, st.mtime.toNanoseconds(), st.ctime.toNanoseconds(), if (std.mem.eql(u8, version, Language.newest.versionString())) "" else version });
        break :memo try arena.print("{s}/bs/zig/{x:0>32}", .{ global_cache, cache.hash(0, key) });
    };
    // `zig` may be a version manager's shim that picks another zig later,
    // but the lib directory it named is still `version`'s while it exists.
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
pub fn libDir(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, global_cache: []const u8, override: ?[]const u8, language: Language) !LibDir {
    const explicit = override orelse environ.get("ZIG_LIB_DIR") orelse return switch (try defaultLibDir(arena, io, environ, global_cache, language)) {
        .path => |p| .{ .path = p, .trusted = true },
        .missing => |msg| main.fatal("{s}", .{msg}),
    };
    const default = switch (try defaultLibDir(arena, io, environ, global_cache, language)) {
        .path => |p| p,
        .missing => return .{ .path = explicit, .trusted = false },
    };
    const cwd = Io.Dir.cwd();
    const a = cwd.realPathFileAlloc(io, explicit, arena) catch return .{ .path = explicit, .trusted = false };
    const b = cwd.realPathFileAlloc(io, default, arena) catch return .{ .path = explicit, .trusted = false };
    return .{ .path = explicit, .trusted = std.mem.eql(u8, a, b) };
}

/// The lib directory of `language`'s upstream zig (`findZigFor`), else, in
/// a development build of the newest, the one bs was built with, if it is
/// still there. Otherwise why there is none, for the user.
fn defaultLibDir(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, global_cache: []const u8, language: Language) !union(enum) { path: []const u8, missing: []const u8 } {
    const version = language.versionString();
    const zig = findZigFor(arena, io, environ, language);
    const bad: ?[]const u8 = if (zig.found) |p| switch (try check(arena, io, environ, global_cache, p, version)) {
        .lib_dir => |lib| return .{ .path = lib },
        .bad => |why| why,
    } else null;
    if (language == Language.newest) {
        const built = try Io.Dir.path.join(arena, &.{ build_options.zig_lib_dir, "std", "std.zig" });
        if (Io.Dir.cwd().access(io, built, .{})) |_| return .{ .path = build_options.zig_lib_dir } else |_| {}
    }
    const need = try arena.print("bs needs upstream zig {s}, whose std library it compiles", .{version});
    const fix = switch (language) {
        .zig_0_17 => try arena.print("install zig {s} and put it on PATH (or set BS_ZIG to it), or pass --zig-lib-dir <its lib directory>", .{version}),
        .zig_0_16 => try arena.print("install zig {s} in ~/.cache/bs/zig-{s}-{s} (or set BS_ZIG_0_16 to it), or pass --zig-lib-dir <its lib directory>", .{ version, @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag), version }),
    };
    return .{ .missing = if (bad) |why|
        try arena.print("{s}, and {s}; {s}", .{ need, why, fix })
    else
        try arena.print("{s}, and found no zig in {s}, on PATH, or at {s}; {s}", .{ need, envVar(language), zig.looked, fix }) };
}
