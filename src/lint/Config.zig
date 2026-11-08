//! A project's `.ziglint.zon`, which opts it in to ziglint's rules as
//! compile errors: finding it, reading it, the files it covers, and the
//! report step, which turns the syntax pass's findings (`Linter`) into
//! diagnostics by the config's rule switches. See "ziglint's rules" in
//! docs/slop/architecture.md.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const diag = @import("../diag.zig");
const Rule = @import("rules.zig").Rule;
const Linter = @import("Linter.zig");

const Config = @This();

/// Absolute path of the `.ziglint.zon`, and of its directory, which
/// `paths` are relative to.
path: []const u8,
dir: []const u8,
/// Its contents, which the cache compares (`Incremental`'s lint state).
source: [:0]const u8,
paths: []const Path,
rules: Rule.Config,
/// Absolute directories whose files are never covered: the zig lib
/// directory and the global package cache's packages.
excluded: []const []const u8,

/// An entry of `paths`, made absolute. A directory covers the `.zig` files
/// under it as ziglint walks it: no path component starting with `.` or
/// named `zig-cache` or `zig-out`, and none its own `.gitignore` matches.
const Path = struct { abs: []const u8, dir: bool, gitignore: ?[]const u8 };

pub const file_name = ".ziglint.zon";

/// The `.ziglint.zon` that covers a compilation whose root source file is
/// `root_file`, if any: the nearest one in its directory or above, up to
/// the nearest directory that holds a `build.zig`. Without a `build.zig`
/// above it, only the file's own directory is searched. A root file in an
/// `excluded` directory or a `zig-pkg` directory (a dependency) has none.
pub fn discover(arena: Allocator, io: Io, root_file: []const u8, excluded: []const []const u8) !?[]const u8 {
    const cwd = Io.Dir.cwd();
    const start = cwd.realPathFileAlloc(io, Io.Dir.path.dirname(root_file) orelse ".", arena) catch return null;
    if (isExcluded(start, excluded)) return null;
    var dir: []const u8 = start;
    // The nearest directory with a `build.zig`, at or above `start`.
    const project: ?[]const u8 = while (true) {
        if (exists(io, try Io.Dir.path.join(arena, &.{ dir, "build.zig" }))) break dir;
        dir = Io.Dir.path.dirname(dir) orelse break null;
    };
    dir = start;
    while (true) {
        const path = try Io.Dir.path.join(arena, &.{ dir, file_name });
        if (exists(io, path)) return path;
        const top = project orelse return null;
        if (std.mem.eql(u8, dir, top)) return null;
        dir = Io.Dir.path.dirname(dir) orelse return null;
    }
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn isExcluded(path: []const u8, excluded: []const []const u8) bool {
    for (excluded) |e| if (under(path, e) != null) return true;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |c| if (std.mem.eql(u8, c, "zig-pkg")) return true;
    return false;
}

/// `path` relative to `dir` if it is `dir` or under it.
fn under(path: []const u8, dir: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, dir)) return "";
    if (path.len <= dir.len or !std.mem.startsWith(u8, path, dir) or path[dir.len] != '/') return null;
    return path[dir.len + 1 ..];
}

/// The schema of `.ziglint.zon`, as ziglint's (`Config.ZonConfig`).
const Zon = struct {
    paths: ?[]const []const u8 = null,
    rules: ?Rule.Config = null,
};

/// Reads the config at `path` (from `discover`). A config bs cannot read,
/// with an unknown field or rule ID among others, is a compile error
/// rather than ziglint's warning and defaults: with no other way to turn a
/// rule off, a config ignored silently would be one.
pub fn read(arena: Allocator, io: Io, path: []const u8, excluded: []const []const u8, paths: diag.Paths) !union(enum) { ok: Config, err: diag.Diagnostic } {
    const cwd = Io.Dir.cwd();
    const source = cwd.readFileAllocOptions(io, path, arena, .limited(1 << 20), .of(u8), 0) catch |err| return .{ .err = .{
        .code = .@"lint-config",
        .loc = null,
        .msg = try arena.print("unable to read '{s}': {t}", .{ (try paths.display(arena, path))[0], err }),
    } };
    var zon_diag: std.zon.parse.Diagnostics = undefined;
    const zon = std.zon.parse.fromSlice(Zon, .{ .gpa = arena, .arena = arena, .source = source, .diagnostics = &zon_diag }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.ParseZon => {
            const e = zon_diag.errors[0];
            const offset: u32 = @intCast(e.loc.line_start + e.loc.column);
            return .{ .err = .{
                .code = .@"lint-config",
                .loc = try paths.loc(arena, path, source, offset, offset, offset, false),
                .msg = try arena.print("{s}; bs enforces ziglint 0.8.1's rules, and its config must parse", .{e.msg}),
            } };
        },
    };
    const dir = Io.Dir.path.dirname(path).?;
    // ziglint lints its working directory when the config names no paths.
    const names: []const []const u8 = zon.paths orelse &.{"."};
    var list: std.ArrayList(Path) = .empty;
    for (names) |name| {
        const abs = try Io.Dir.path.resolveAlloc(arena, &.{ dir, name });
        // ziglint reports a path it cannot access and lints the others.
        const stat = cwd.statFile(io, abs, .{}) catch continue;
        const is_dir = stat.kind == .directory;
        const gitignore = if (is_dir) cwd.readFileAlloc(io, try Io.Dir.path.join(arena, &.{ abs, ".gitignore" }), arena, .limited(1024 * 64)) catch null else null;
        try list.append(arena, .{ .abs = abs, .dir = is_dir, .gitignore = gitignore });
    }
    return .{ .ok = .{
        .path = path,
        .dir = dir,
        .source = source,
        .paths = list.items,
        .rules = zon.rules orelse .{},
        .excluded = excluded,
    } };
}

/// Whether the file at absolute path `abs` is covered: one of `paths`,
/// or a `.zig` file under one that ziglint's walk takes, and not in an
/// excluded or `zig-pkg` directory.
pub fn covers(cfg: *const Config, abs: []const u8) bool {
    if (isExcluded(abs, cfg.excluded)) return false;
    for (cfg.paths) |p| {
        if (!p.dir) {
            if (std.mem.eql(u8, abs, p.abs)) return true;
            continue;
        }
        const rel = under(abs, p.abs) orelse continue;
        if (rel.len == 0 or !std.mem.endsWith(u8, rel, ".zig")) continue;
        if (!walkSkips(rel, p.gitignore)) return true;
    }
    return false;
}

/// ziglint's `shouldSkip` (main.zig), for a path relative to the walked
/// directory.
fn walkSkips(path: []const u8, gitignore: ?[]const u8) bool {
    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |component| {
        if (std.mem.startsWith(u8, component, ".")) return true;
        if (std.mem.eql(u8, component, "zig-cache")) return true;
        if (std.mem.eql(u8, component, "zig-out")) return true;
    }
    const patterns = gitignore orelse return false;
    var lines = std.mem.splitScalar(u8, patterns, '\n');
    while (lines.next()) |line| {
        const pattern = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (pattern.len == 0 or pattern[0] == '#') continue;
        if (matchesGitignore(path, pattern)) return true;
    }
    return false;
}

/// ziglint's `matchesGitignore`: a component, a prefix for a pattern
/// starting with `/`, or a substring; no globs or negation.
fn matchesGitignore(path: []const u8, pattern: []const u8) bool {
    const clean = if (std.mem.endsWith(u8, pattern, "/")) pattern[0 .. pattern.len - 1] else pattern;
    if (std.mem.startsWith(u8, clean, "/")) return std.mem.startsWith(u8, path, clean[1..]);
    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |component| {
        if (std.mem.eql(u8, component, clean)) return true;
    }
    return std.mem.find(u8, path, clean) != null;
}

pub fn enabled(cfg: *const Config, rule: Rule) bool {
    switch (rule) {
        inline else => |r| return @field(cfg.rules, @tagName(r)).enabled,
    }
}

/// The rules Sema answers (docs/slop/ziglint-in-bs.md, section 1).
pub const sema_rules = [_]Rule{ .Z010, .Z011, .Z029, .Z034 };

/// Whether any rule Sema answers is on (`Zcu.lint_covered`).
pub fn semaRules(cfg: *const Config) bool {
    for (sema_rules) |r| if (cfg.enabled(r)) return true;
    return false;
}

/// Whether a file's findings (`Linter.run`) need its source to report:
/// any of them is reported, or Z024's limit is below the facts' minimum.
pub fn reportsAny(cfg: *const Config, findings: []const Linter.Diagnostic) bool {
    if (cfg.enabled(.Z024) and cfg.rules.Z024.max_length < Linter.long_line_min) return true;
    for (findings) |f| if (cfg.reports(f)) return true;
    return false;
}

fn reports(cfg: *const Config, f: Linter.Diagnostic) bool {
    if (!cfg.enabled(f.rule)) return false;
    if (f.rule == .Z024) return (std.fmt.parseInt(u32, f.context, 10) catch 0) > cfg.rules.Z024.max_length;
    return true;
}

/// Appends the findings of the file at `raw_path`, whose contents are
/// `source`, that the config reports to `out` as diagnostics.
pub fn report(cfg: *const Config, arena: Allocator, paths: diag.Paths, raw_path: []const u8, source: [:0]const u8, findings: []const Linter.Diagnostic, out: *std.ArrayList(diag.Diagnostic)) !void {
    const max_length = cfg.rules.Z024.max_length;
    // A limit below the facts' minimum takes the long lines from the source.
    const scan = cfg.enabled(.Z024) and max_length < Linter.long_line_min;
    const long_lines: []const Linter.Diagnostic = if (scan) Linter.longLines(arena, source, max_length) else &.{};
    for ([_][]const Linter.Diagnostic{ findings, long_lines }, 0..) |list, i| for (list) |f| {
        if (f.rule == .Z024 and i == 0 and scan) continue;
        if (!cfg.reports(f)) continue;
        var msg: Io.Writer.Allocating = .init(arena);
        if (f.rule == .Z024)
            try msg.writer.print("line exceeds {d} bytes ({s} bytes)", .{ max_length, f.context })
        else
            try f.rule.writeMessage(&msg.writer, f.context, false);
        const line_end = std.mem.findScalarPos(u8, source, f.offset, '\n') orelse source.len;
        // A finding points at a token; Z024 at the column past the limit.
        const main: u32 = if (f.rule == .Z024) @intCast(@min(f.offset + max_length, line_end)) else f.offset;
        const end: u32 = if (f.rule == .Z024) @intCast(line_end) else @intCast(tokenEnd(source, f.offset));
        try out.append(arena, .{
            .code = if (f.rule == .Z011) .deprecated else .style,
            .rule = f.rule.code(),
            .loc = try paths.loc(arena, raw_path, source, f.offset, main, end, false),
            .msg = msg.written(),
        });
    };
}

/// The end of the token at `start`: the run of identifier characters, or
/// one byte.
fn tokenEnd(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_' or source[i] == '@')) i += 1;
    return @max(i, @min(start + 1, source.len));
}
