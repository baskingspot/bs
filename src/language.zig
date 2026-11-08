//! The Zig languages bs compiles: the current release and the one before
//! it, each with its own std (docs/slop/zig-0.16.md). A compilation is in
//! exactly one of them, chosen before anything is loaded:
//!
//! 1. `--zig-version`;
//! 2. else `BS_ZIG_VERSION`, which `bs build` sets for the compilations it
//!    runs, so that dependencies take the root package's language;
//! 3. else the `minimum_zig_version` of the nearest `build.zig.zon`
//!    (`discover`): 0.16.x selects 0.16, 0.17.x or none selects 0.17, and
//!    any other version is an error;
//! 4. else the newest.
//!
//! Until 0.16 compiles, step 3 applies only with `BS_ZON_SELECTS` set, so
//! that projects which declare another version keep compiling as 0.17.

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
    /// A `build.zig.zon`'s path.
    zon: []const u8,
};

pub const Choice = struct { language: Language, source: Source };

/// The supported versions, for messages.
pub const supported = "Zig 0.16 and 0.17";

/// The language of a compilation whose root source file is `root_file`
/// (null for none), with `flag` from `--zig-version`. Exits with an error
/// for an unsupported version.
pub fn resolve(arena: Allocator, io: Io, environ: *const std.process.Environ.Map, flag: ?[]const u8, root_file: ?[]const u8) !Choice {
    if (flag) |v| return .{ .language = Language.fromVersion(v) orelse
        main.fatal("--zig-version '{s}': bs compiles {s}", .{ v, supported }), .source = .flag };
    if (environ.get("BS_ZIG_VERSION")) |v| return .{ .language = Language.fromVersion(v) orelse
        main.fatal("BS_ZIG_VERSION '{s}': bs compiles {s}", .{ v, supported }), .source = .env };
    if (environ.get("BS_ZON_SELECTS") == null) return default;
    const zon = try discover(arena, io, root_file orelse return default) orelse return default;
    return fromZon(arena, io, zon);
}

/// The language of `bs build` in `build_root`, the directory of its
/// build.zig: its build.zig.zon's, whatever the environment says, since
/// the root package decides for every compilation of its build.
pub fn forBuild(arena: Allocator, io: Io, environ: *const std.process.Environ.Map, build_root: []const u8) !Choice {
    if (environ.get("BS_ZON_SELECTS") == null) return default;
    return fromZon(arena, io, try Io.Dir.path.join(arena, &.{ build_root, "build.zig.zon" }));
}

const default: Choice = .{ .language = .newest, .source = .default };

/// The language `zon`'s `minimum_zig_version` selects.
fn fromZon(arena: Allocator, io: Io, zon: []const u8) !Choice {
    const bytes = Io.Dir.cwd().readFileAlloc(io, zon, arena, .limited(16 << 20)) catch |err| switch (err) {
        error.FileNotFound => return default,
        else => main.fatal("unable to read '{s}': {t}", .{ zon, err }),
    };
    const source = try arena.dupeSentinel(u8, bytes, 0);
    const found = minimumZigVersion(source) orelse return .{ .language = .newest, .source = .{ .zon = zon } };
    const l = Language.fromVersion(found.value) orelse {
        const loc = std.zig.findLineColumn(source, found.offset);
        main.fatal("{s}:{d}:{d}: minimum_zig_version '{s}' is not supported: bs compiles {s} (0.16.x selects 0.16; 0.17.x, or no minimum_zig_version, selects 0.17)", .{ zon, loc.line + 1, loc.column + 1, found.value, supported });
    };
    return .{ .language = l, .source = .{ .zon = zon } };
}

/// The `build.zig.zon` that covers a root source file: the one beside the
/// nearest `build.zig` at or above the file's directory, as `zig build`
/// finds its build.zig from the working directory. None without a
/// `build.zig` above the file, as for a lone file.
pub fn discover(arena: Allocator, io: Io, root_file: []const u8) !?[]const u8 {
    const cwd = Io.Dir.cwd();
    var dir: []const u8 = cwd.realPathFileAlloc(io, Io.Dir.path.dirname(root_file) orelse ".", arena) catch return null;
    while (true) {
        if (cwd.access(io, try Io.Dir.path.join(arena, &.{ dir, "build.zig" }), .{})) |_| {
            const zon = try Io.Dir.path.join(arena, &.{ dir, "build.zig.zon" });
            return zon;
        } else |_| {}
        dir = Io.Dir.path.dirname(dir) orelse return null;
    }
}

/// The value of a ZON source's top-level `.minimum_zig_version` string and
/// its byte offset, or null when it has none. Only the root struct's own
/// field counts: a dependency's table may not shadow it.
fn minimumZigVersion(source: [:0]const u8) ?struct { value: []const u8, offset: usize } {
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
            .string_literal => if (depth == 1 and prev[1] == .equal and prev[0] == .identifier and std.mem.eql(u8, prev_name, "minimum_zig_version")) {
                const lit = buf[tk.loc.start..tk.loc.end];
                return .{ .value = source[tk.loc.start + 1 .. tk.loc.start + lit.len - 1], .offset = tk.loc.start };
            },
            else => {},
        }
        if (tk.tag == .identifier) prev_name = buf[tk.loc.start..tk.loc.end];
        prev = .{ prev[1], tk.tag };
    }
}

test minimumZigVersion {
    const src =
        \\.{
        \\    .name = .x,
        \\    .dependencies = .{ .d = .{ .minimum_zig_version = "0.15.1" } },
        \\    .minimum_zig_version = "0.16.0",
        \\}
    ;
    const got = minimumZigVersion(src).?;
    try std.testing.expectEqualStrings("0.16.0", got.value);
    try std.testing.expectEqual(std.mem.find(u8, src, "\"0.16.0\"").?, got.offset);
    try std.testing.expect(minimumZigVersion(".{ .name = .x }") == null);
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
