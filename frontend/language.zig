//! The Zig languages bs compiles: the current release and the one before
//! it (docs/slop/zig-0.16.md). src/language.zig chooses one per
//! compilation; the frontend parses and lowers each with its own grammar
//! and AstGen.

const std = @import("std");

pub const Language = enum(u8) {
    zig_0_16,
    zig_0_17,

    pub const newest: Language = .zig_0_17;

    /// The release whose std and `zig cc` a compilation in this language
    /// uses, as upstream's `zig version` prints it.
    pub fn versionString(l: Language) []const u8 {
        return switch (l) {
            .zig_0_16 => "0.16.0",
            .zig_0_17 => "0.17.1",
        };
    }

    /// The language as users name it, `0.16` or `0.17`.
    pub fn name(l: Language) []const u8 {
        return switch (l) {
            .zig_0_16 => "0.16",
            .zig_0_17 => "0.17",
        };
    }

    /// The language of a version: a `minimum_zig_version`, `--zig-version`
    /// or `BS_ZIG_VERSION`, as `0.16`, `0.16.0` or `0.16.0-dev.123+abc`.
    pub fn fromVersion(v: []const u8) ?Language {
        // `0.16` is short for `0.16.0`.
        var buf: [32]u8 = undefined;
        const full = if (std.mem.countScalar(u8, v, '.') == 1) std.mem.print(&buf, "{s}.0", .{v}) catch return null else v;
        const sv = std.SemanticVersion.parse(full) catch return null;
        if (sv.major != 0) return null;
        return switch (sv.minor) {
            16 => .zig_0_16,
            17 => .zig_0_17,
            else => null,
        };
    }
};
