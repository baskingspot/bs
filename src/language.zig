//! The Zig languages bs compiles: the current release and the one before
//! it, each with its own std (docs/slop/zig-0.16.md). A compilation is in
//! exactly one of them, chosen before anything is loaded:
//!
//! 1. `--zig-version`;
//! 2. else `BS_ZIG_VERSION`, which `bs build` sets for the compilations it
//!    runs, so that dependencies take the root package's language;
//! 3. else the `zig_version` of the nearest `.bs.zon` (`.zig_version =
//!    "0.16"`), found as lint finds it (lint/Config.zig);
//! 4. else the newest.
//!
//! `bs build` reads its root package's `.bs.zon` alone (`forBuild`).
//! A `build.zig.zon`'s `minimum_zig_version` selects nothing: it is a
//! lower bound, which upstream zig does not check either. When a build in
//! the newest fails, one of 0.16.x, or one newer than the newest release,
//! is named in a note (`Choice.minimum_zon`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const main = @import("main.zig");

pub const Language = @import("frontend").Language;

/// Where a compilation's language came from, for messages.
pub const Source = union(enum) {
    default,
    flag,
    env,
    /// A `.bs.zon`'s path.
    bs_zon: []const u8,
};

pub const Choice = struct {
    language: Language,
    source: Source,
    /// For a compilation in the newest language by default: the path of
    /// the project's `build.zig.zon` when its `minimum_zig_version` is
    /// 0.16.x or newer than the newest release, which a failed build notes
    /// (`main.noteMinimum`). `bs build` passes its root package's to the
    /// compilations it runs as `BS_ZIG_MINIMUM_ZON`.
    minimum_zon: ?[]const u8 = null,
};

/// The supported versions, for messages.
pub const supported = "Zig 0.16 and 0.17";

/// The environment variable that carries `Choice.minimum_zon` from
/// `bs build` to its compilations.
pub const minimum_zon_env = "BS_ZIG_MINIMUM_ZON";

/// The language of a compilation whose root source file is `root_file`
/// (null for none), with `flag` from `--zig-version`. Exits with an error
/// for an unsupported version.
pub fn resolve(arena: Allocator, io: Io, environ: *const std.process.Environ.Map, flag: ?[]const u8, root_file: ?[]const u8) !Choice {
    if (flag) |v| return .{ .language = Language.fromVersion(v) orelse
        main.fatal("--zig-version '{s}': bs compiles {s}", .{ v, supported }), .source = .flag };
    if (environ.get("BS_ZIG_VERSION")) |v| return .{
        .language = Language.fromVersion(v) orelse main.fatal("BS_ZIG_VERSION '{s}': bs compiles {s}", .{ v, supported }),
        .source = .env,
        .minimum_zon = environ.get(minimum_zon_env),
    };
    const file = root_file orelse return default;
    const cwd = Io.Dir.cwd();
    const start = cwd.realPathFileAlloc(io, Io.Dir.path.dirname(file) orelse ".", arena) catch return default;
    // The nearest directory with a build.zig, as `zig build` finds it.
    var dir: []const u8 = start;
    const project: ?[]const u8 = while (true) {
        if (exists(io, try Io.Dir.path.join(arena, &.{ dir, "build.zig" }))) break dir;
        dir = Io.Dir.path.dirname(dir) orelse break null;
    };
    const minimum_zon = if (project) |p| try checkZon(arena, io, try Io.Dir.path.join(arena, &.{ p, "build.zig.zon" })) else null;
    // The nearest .bs.zon, up to the project's directory (only the file's
    // own without a project), as lint's `Config.discover`.
    dir = start;
    while (true) {
        const bs_zon = try Io.Dir.path.join(arena, &.{ dir, bs_zon_name });
        if (exists(io, bs_zon)) return fromBsZon(arena, io, bs_zon, minimum_zon);
        const top = project orelse break;
        if (std.mem.eql(u8, dir, top)) break;
        dir = Io.Dir.path.dirname(dir) orelse break;
    }
    return .{ .language = .newest, .source = .default, .minimum_zon = minimum_zon };
}

/// The language of `bs build` in `build_root`, the directory of its
/// build.zig: its `.bs.zon`'s, since the root package decides for every
/// compilation of its build, else the newest.
pub fn forBuild(arena: Allocator, io: Io, build_root: []const u8) !Choice {
    const minimum_zon = try checkZon(arena, io, try Io.Dir.path.join(arena, &.{ build_root, "build.zig.zon" }));
    return fromBsZon(arena, io, try Io.Dir.path.join(arena, &.{ build_root, bs_zon_name }), minimum_zon);
}

const default: Choice = .{ .language = .newest, .source = .default };

const bs_zon_name = ".bs.zon";

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn readZon(arena: Allocator, io: Io, path: []const u8) !?[:0]const u8 {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => main.fatal("unable to read '{s}': {t}", .{ path, err }),
    };
    const source = try arena.dupeSentinel(u8, bytes, 0);
    return source;
}

/// The language the `.bs.zon` at `path` selects with its `zig_version`,
/// else the newest, noting `minimum_zon`.
fn fromBsZon(arena: Allocator, io: Io, path: []const u8, minimum_zon: ?[]const u8) !Choice {
    const source = try readZon(arena, io, path) orelse return .{ .language = .newest, .source = .default, .minimum_zon = minimum_zon };
    const found = topField(source, "zig_version") orelse return .{ .language = .newest, .source = .default, .minimum_zon = minimum_zon };
    const l = Language.fromVersion(found.value) orelse {
        const loc = std.zig.findLineColumn(source, found.offset);
        main.fatal("{s}:{d}:{d}: zig_version '{s}' is not supported: bs compiles {s}", .{ path, loc.line + 1, loc.column + 1, found.value, supported });
    };
    return .{ .language = l, .source = .{ .bs_zon = path } };
}

/// `path` when the `minimum_zig_version` of the `build.zig.zon` there is
/// one a failed build in the newest notes (`Minimum.kind`).
fn checkZon(arena: Allocator, io: Io, path: []const u8) !?[]const u8 {
    const source = try readZon(arena, io, path) orelse return null;
    const found = topField(source, "minimum_zig_version") orelse return null;
    return if (kind(found.value) != null) path else null;
}

/// What a failed build in the newest notes about a `minimum_zig_version`.
pub const MinimumKind = enum {
    /// 0.16.x: the `.bs.zon` that builds the project as 0.16.
    zig_0_16,
    /// Newer than the newest release: bs does not know that release.
    newer,
};

fn kind(minimum: []const u8) ?MinimumKind {
    if (Language.fromVersion(minimum) == .zig_0_16) return .zig_0_16;
    const v = std.SemanticVersion.parse(minimum) catch return null;
    const newest = std.SemanticVersion.parse(Language.newest.versionString()) catch unreachable;
    return if (v.major > newest.major or (v.major == newest.major and v.minor > newest.minor)) .newer else null;
}

/// Where the `minimum_zig_version` of the `build.zig.zon` at `path` is,
/// for `main.noteMinimum`: its source, the field's string's offset, and
/// what to note, if anything.
pub fn minimumField(arena: Allocator, io: Io, path: []const u8) !?struct { source: [:0]const u8, value: []const u8, offset: usize, kind: MinimumKind } {
    const source = try readZon(arena, io, path) orelse return null;
    const found = topField(source, "minimum_zig_version") orelse return null;
    return .{ .source = source, .value = found.value, .offset = found.offset, .kind = kind(found.value) orelse return null };
}

/// The value of a ZON source's top-level string field `name` and its byte
/// offset, or null when it has none. Only the root struct's own field
/// counts: a dependency's table may not shadow it.
fn topField(source: [:0]const u8, name: []const u8) ?struct { value: []const u8, offset: usize } {
    // A tokenizer pass, nesting by braces, so that the field is read from
    // the root struct only.
    const buf = source;
    var tok: std.zig.Tokenizer = .init(buf);
    var depth: u32 = 0;
    var prev: [2]std.zig.Token.Tag = .{ .invalid, .invalid };
    var prev_name: []const u8 = "";
    while (true) {
        const tk = tok.next();
        switch (tk.tag) {
            .eof => return null,
            .l_brace => depth += 1,
            .r_brace => depth -|= 1,
            .string_literal => if (depth == 1 and prev[1] == .equal and prev[0] == .identifier and std.mem.eql(u8, prev_name, name)) {
                const lit = buf[tk.loc.start..tk.loc.end];
                return .{ .value = source[tk.loc.start + 1 .. tk.loc.start + lit.len - 1], .offset = tk.loc.start };
            },
            else => {},
        }
        if (tk.tag == .identifier) prev_name = buf[tk.loc.start..tk.loc.end];
        prev = .{ prev[1], tk.tag };
    }
}

test topField {
    const src =
        \\.{
        \\    .name = .x,
        \\    .dependencies = .{ .d = .{ .minimum_zig_version = "0.15.1" } },
        \\    .minimum_zig_version = "0.16.0",
        \\}
    ;
    const got = topField(src, "minimum_zig_version").?;
    try std.testing.expectEqualStrings("0.16.0", got.value);
    try std.testing.expectEqual(std.mem.find(u8, src, "\"0.16.0\"").?, got.offset);
    try std.testing.expect(topField(".{ .name = .x }", "minimum_zig_version") == null);
}

test "Language.fromVersion" {
    try std.testing.expectEqual(Language.zig_0_16, Language.fromVersion("0.16.0").?);
    try std.testing.expectEqual(Language.zig_0_16, Language.fromVersion("0.16").?);
    try std.testing.expectEqual(Language.zig_0_16, Language.fromVersion("0.16.0-dev.2+abc").?);
    try std.testing.expectEqual(Language.zig_0_17, Language.fromVersion("0.17.1").?);
    try std.testing.expect(Language.fromVersion("0.15.2") == null);
    try std.testing.expect(Language.fromVersion("0.18.0") == null);
    try std.testing.expect(Language.fromVersion("1.0.0") == null);
    try std.testing.expect(Language.fromVersion("x") == null);
}
