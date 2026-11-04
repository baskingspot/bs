//! Compile errors as zap reports them: a record with a stable code,
//! resolved locations and notes, rendered as text (the default) or as JSON
//! lines (`--error-format=json`). See "Diagnostics" in
//! docs/architecture.md for the output form and its rules.

const std = @import("std");
const Writer = std.Io.Writer;

/// A kind of error, stable once released: never renamed or reused. Text
/// output shows it as `error[<name>]`; `unclassified` is not shown.
pub const Code = enum(u16) {
    unclassified,

    // AstGen and the parser (`classifyAstGen`).
    syntax,
    unused,
    @"unused-label",
    @"pointless-discard",
    @"never-mutated",
    undeclared,
    shadow,
    redeclared,
    @"ambiguous-reference",
    @"unreachable-code",
    @"unknown-builtin",
    @"arg-count",
    @"bad-number",
    @"outside-function",
    @"not-accessible",
    @"bad-break",
    @"control-in-defer",
    redundant,
    @"no-result-type",
    uninitialized,
    @"dangling-address",
    @"bad-assignment",
    @"unbounded-for",
    @"bad-capture",
    @"string-compare",
    @"bad-container",
    @"bad-fn-type",
    @"bad-asm",
    @"bad-import",
    @"bad-name",
    @"bad-destructure",
    @"bad-var-decl",
    @"bad-pointer-type",
    @"bad-int-type",
    @"misplaced-builtin",
    @"bad-suspend",
    @"bad-decltest",
    @"bad-switch",
    @"bad-init",

    // Sema, the linker and the backends (`formatCode`).
    unsupported,
    @"not-pub",
    @"no-member",
    @"no-field",
    @"type-mismatch",
    @"operand-type",
    @"bad-operands",
    @"bad-access",
    @"bad-call",
    @"bad-cast",
    @"bad-type",
    @"bad-return",
    @"bad-export",
    @"assign-to-const",
    @"ignored-value",
    @"switch-incomplete",
    @"length-mismatch",
    @"unknown-length",
    @"comptime-required",
    @"comptime-only",
    @"comptime-var-escape",
    @"eval-limit",
    @"dependency-loop",
    @"undefined-value",
    @"division-by-zero",
    @"integer-overflow",
    @"lossy-conversion",
    @"out-of-bounds",
    @"sentinel-mismatch",
    @"inactive-field",
    @"inexact-division",
    @"null-value",
    @"reached-unreachable",
    @"caught-error",
    @"comptime-trap",
    @"compile-error",
    @"undefined-symbol",
};

/// A location, resolved for rendering.
pub const Loc = struct {
    /// As displayed: relative to the working directory, or to the zig lib
    /// directory for files under it (`std/start.zig`).
    path: []const u8,
    /// 1-based line and byte column, as upstream.
    line: u32,
    col: u32,
    /// Byte offsets of the span in the file, end exclusive, and of its
    /// main token (where `line` and `col` point; ErrorBundle's span_main).
    start: u32,
    end: u32,
    main: u32,
    /// The whole source line of `line`, without its newline.
    source_line: []const u8,
    /// In std, `builtin`, compiler_rt or another file under the zig lib
    /// directory, rather than in a user module.
    in_lib: bool,
};

pub const Note = struct {
    loc: ?Loc,
    msg: []const u8,
    /// Repeats of the same note in a row (a recursive call's frames).
    count: u32 = 1,
    /// A call-site frame of the comptime or inline call chain rather than
    /// a note; frames render together on one `call:` line.
    call: ?CallKind = null,
    /// Points at a declaration, whose source line the note shows (token
    /// efficiency rule 1).
    decl: bool = false,
};

pub const CallKind = enum { @"inline", @"comptime" };

pub const Diagnostic = struct {
    code: Code = .unclassified,
    loc: ?Loc,
    msg: []const u8,
    /// Identical messages counted together (ErrorBundle's `count`).
    count: u32 = 1,
    notes: []const Note = &.{},
    /// The reference trace: who referred to the failed unit, nearest first.
    refs: []const Ref = &.{},
    /// Names close to the one a failed lookup asked for, closest first.
    candidates: []const []const u8 = &.{},
    /// One line on what replaced an API or builtin that 0.17 lacks
    /// (`migrationHint`, `builtinHint`).
    hint: ?[]const u8 = null,
    fixes: []const Fix = &.{},
};

/// How safely a fix applies (rustc's applicability).
pub const Applicability = enum {
    /// Apply as is: the program then compiles past this error and means
    /// what its author wrote.
    exact,
    /// Valid code that may not be what the author meant (a cast that can
    /// trap, a rename to the closest name).
    maybe,
    /// Valid code with a placeholder to replace (`@panic("TODO")`).
    placeholder,
};

/// A source change that fixes an error: its edits apply together.
pub const Fix = struct { applicability: Applicability, edits: []const Edit };

/// Replace the bytes `start..end` (end exclusive) of `path` with `text`.
pub const Edit = struct {
    /// As `Loc.path`.
    path: []const u8,
    /// 1-based lines and byte columns of `start` and `end`.
    line: u32,
    col: u32,
    end_line: u32,
    end_col: u32,
    start: u32,
    end: u32,
    text: []const u8,
};

/// A fix as Sema and AstGen make it: byte offsets into the error's file.
pub const RawFix = struct { applicability: Applicability, edits: []const RawEdit };
pub const RawEdit = struct { start: u32, end: u32, text: []const u8 };

/// A frame of the reference trace: unit `name` referred onward at `loc`.
pub const Ref = struct { name: []const u8, loc: ?Loc };

pub const Format = enum { text, json };

/// Turns raw file paths into displayed ones (`Loc.path`, `Loc.in_lib`).
pub const Paths = struct {
    /// Absolute and resolved.
    lib_dir: []const u8,
    cwd: []const u8,
    /// Reads a failing file again for facts about its error (candidates).
    io: std.Io,

    pub fn init(arena: std.mem.Allocator, io: std.Io, zig_lib_dir: []const u8) !Paths {
        const cwd = try std.process.currentPathAlloc(io, arena);
        return .{ .lib_dir = try std.fs.path.resolve(arena, &.{ cwd, zig_lib_dir }), .cwd = cwd, .io = io };
    }

    pub fn display(p: Paths, arena: std.mem.Allocator, raw: []const u8) !struct { []const u8, bool } {
        const abs = try std.fs.path.resolve(arena, &.{ p.cwd, raw });
        if (under(abs, p.lib_dir)) |rel| return .{ rel, true };
        if (under(abs, p.cwd)) |rel| return .{ rel, false };
        return .{ abs, false };
    }

    fn under(path: []const u8, dir: []const u8) ?[]const u8 {
        if (path.len <= dir.len or !std.mem.startsWith(u8, path, dir) or path[dir.len] != '/') return null;
        return path[dir.len + 1 ..];
    }

    /// The location of byte span `start..end` (main at `main`) in `source`.
    pub fn loc(p: Paths, arena: std.mem.Allocator, raw_path: []const u8, source: []const u8, start: u32, main: u32, end: u32, force_lib: bool) !Loc {
        const path, const in_lib = try p.display(arena, raw_path);
        const lc = std.zig.findLineColumn(source, main);
        return .{
            .path = path,
            .line = @intCast(lc.line + 1),
            .col = @intCast(lc.column + 1),
            .start = start,
            .end = end,
            .main = main,
            .source_line = lc.source_line,
            .in_lib = in_lib or force_lib,
        };
    }

    /// `raw`, made against `source` of `raw_path`, with its edits located.
    pub fn fix(p: Paths, arena: std.mem.Allocator, raw_path: []const u8, source: []const u8, raw: RawFix) !Fix {
        const path, _ = try p.display(arena, raw_path);
        const edits = try arena.alloc(Edit, raw.edits.len);
        for (edits, raw.edits) |*e, r| {
            const a = std.zig.findLineColumn(source, r.start);
            const b = std.zig.findLineColumn(source, r.end);
            e.* = .{
                .path = path,
                .line = @intCast(a.line + 1),
                .col = @intCast(a.column + 1),
                .end_line = @intCast(b.line + 1),
                .end_col = @intCast(b.column + 1),
                .start = r.start,
                .end = r.end,
                .text = r.text,
            };
        }
        return .{ .applicability = raw.applicability, .edits = edits };
    }
};

/// The most candidates a failed lookup lists.
pub const max_candidates = 5;

/// Appends to `out` the names of `names` close to `name`, a name a lookup
/// did not find, closest first and at most `max_candidates`: a
/// case-insensitive match (`io` → `Io`), or a Damerau-Levenshtein
/// distance of at most 2, and at most a third of the name's length so
/// that short names do not match everything (rustc's rule). With
/// `all_if_few`, a list of at most 8 names is returned whole, in order.
pub fn closeNames(arena: std.mem.Allocator, name: []const u8, names: []const []const u8, all_if_few: bool, out: *std.ArrayList([]const u8)) !void {
    if (all_if_few and names.len <= 8) {
        for (names) |n| if (!std.mem.eql(u8, n, name)) try out.append(arena, n);
        return;
    }
    const limit: usize = @min(2, @max(1, name.len / 3));
    const Scored = struct { name: []const u8, dist: usize };
    var found: std.ArrayList(Scored) = .empty;
    names: for (names) |n| {
        if (std.mem.eql(u8, n, name)) continue;
        for (found.items) |f| if (std.mem.eql(u8, f.name, n)) continue :names;
        const dist: usize = if (std.ascii.eqlIgnoreCase(n, name)) 0 else editDistance(name, n, limit) orelse continue;
        try found.append(arena, .{ .name = n, .dist = dist });
    }
    std.mem.sort(Scored, found.items, {}, struct {
        fn lessThan(_: void, a: Scored, b: Scored) bool {
            return a.dist < b.dist or (a.dist == b.dist and std.mem.order(u8, a.name, b.name) == .lt);
        }
    }.lessThan);
    for (found.items[0..@min(found.items.len, max_candidates)]) |f| try out.append(arena, f.name);
}

/// The optimal-string-alignment distance between `a` and `b` (edits are
/// insertions, deletions, substitutions and swaps of adjacent bytes), or
/// null when it is more than `limit`.
fn editDistance(a: []const u8, b: []const u8, limit: usize) ?usize {
    if (@max(a.len, b.len) - @min(a.len, b.len) > limit) return null;
    const max_len = 64;
    if (b.len >= max_len) return null;
    var rows: [3][max_len]usize = undefined;
    var prev2 = &rows[0];
    var prev = &rows[1];
    var cur = &rows[2];
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 1..) |ca, i| {
        cur[0] = i;
        var row_min = cur[0];
        for (b, 1..) |cb, j| {
            var d = @min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + @intFromBool(ca != cb));
            if (i > 1 and j > 1 and ca == b[j - 2] and a[i - 2] == cb) d = @min(d, prev2[j - 2] + 1);
            cur[j] = d;
            row_min = @min(row_min, d);
        }
        if (row_min > limit) return null;
        const t = prev2;
        prev2 = prev;
        prev = cur;
        cur = t;
    }
    return if (prev[b.len] <= limit) prev[b.len] else null;
}

test closeNames {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList([]const u8) = .empty;
    // Case, then a swap, and short names do not match far ones.
    try closeNames(arena, "io", &.{ "os", "Io", "fs", "c", "mem" }, false, &out);
    try std.testing.expectEqualSlices(u8, "Io", out.items[0]);
    try std.testing.expectEqual(1, out.items.len);
    out.clearRetainingCapacity();
    try closeNames(arena, "tow", &.{ "one", "two", "three" }, false, &out);
    try std.testing.expectEqual(1, out.items.len);
    try std.testing.expectEqualSlices(u8, "two", out.items[0]);
    out.clearRetainingCapacity();
    // Length 5 allows one edit: "prepend" is three away, "appendSlice" more.
    try closeNames(arena, "apend", &.{ "prepend", "pend", "appendSlice", "append" }, false, &out);
    try std.testing.expectEqual(2, out.items.len);
    try std.testing.expectEqualSlices(u8, "append", out.items[0]);
    try std.testing.expectEqualSlices(u8, "pend", out.items[1]);
    out.clearRetainingCapacity();
    // A few fields are listed whole, in order, without the asked name.
    try closeNames(arena, "z", &.{ "x", "y" }, true, &out);
    try std.testing.expectEqual(2, out.items.len);
    try std.testing.expectEqualSlices(u8, "x", out.items[0]);
}

/// Appends the messages of an ErrorBundle (AstGen and parse errors) as
/// diagnostics, classifying each message's code. Some errors read their
/// file again for candidates and fixes.
pub fn fromBundle(arena: std.mem.Allocator, paths: Paths, bundle: std.zig.ErrorBundle, out: *std.ArrayList(Diagnostic)) !void {
    // The file read again most recently: a file's errors come together.
    var reread: ?struct { path: []const u8, tree: std.zig.Ast } = null;
    for (bundle.getMessages()) |idx| {
        const m = bundle.getErrorMessage(idx);
        const notes = try arena.alloc(Note, m.notes_len);
        for (notes, bundle.getNotes(idx)) |*n, ni| {
            const nm = bundle.getErrorMessage(ni);
            n.* = .{ .loc = try bundleLoc(arena, paths, bundle, nm.src_loc), .msg = bundle.nullTerminatedString(nm.msg), .count = nm.count };
        }
        const msg = bundle.nullTerminatedString(m.msg);
        const code = classifyAstGen(msg);
        var candidates: []const []const u8 = &.{};
        var fixes: []const Fix = &.{};
        const needs_file = switch (code) {
            .undeclared, .unused, .@"unused-label", .@"never-mutated", .@"pointless-discard", .@"unknown-builtin" => true,
            else => false,
        };
        if (needs_file and m.src_loc != .none) facts: {
            const sl = bundle.getSourceLocation(m.src_loc);
            const path = bundle.nullTerminatedString(sl.src_path);
            if (reread == null or !std.mem.eql(u8, reread.?.path, path)) {
                reread = null;
                const source = std.Io.Dir.cwd().readFileAllocOptions(paths.io, path, arena, .unlimited, .of(u8), 0) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // The file vanished since: no facts.
                    else => break :facts,
                };
                reread = .{ .path = path, .tree = try std.zig.Ast.parse(arena, source, .{ .mode = .zig }) };
            }
            const tree = &reread.?.tree;
            // The file changed since AstGen read it: its offsets mean nothing.
            if (sl.span_main > tree.source.len or !std.mem.eql(u8, std.zig.findLineColumn(tree.source, sl.span_main).source_line, bundle.nullTerminatedString(sl.source_line))) break :facts;
            if (code == .undeclared) if (quoted(msg)) |name| {
                var names: std.ArrayList([]const u8) = .empty;
                try scopeNames(arena, tree, sl.span_main, &names);
                var close: std.ArrayList([]const u8) = .empty;
                try closeNames(arena, name, names.items, false, &close);
                candidates = close.items;
            };
            if (try astGenFix(arena, tree, code, msg, sl.span_main, candidates)) |raw|
                fixes = try arena.dupe(Fix, &.{try paths.fix(arena, path, tree.source, raw)});
        }
        const hint: ?[]const u8 = if (code == .@"unknown-builtin") if (quoted(msg)) |name| builtinHint(name) else null else null;
        try out.append(arena, .{ .code = code, .loc = try bundleLoc(arena, paths, bundle, m.src_loc), .msg = msg, .count = m.count, .notes = notes, .candidates = candidates, .hint = hint, .fixes = fixes });
    }
}

/// The text between the first and last `'` of `msg`, if any.
fn quoted(msg: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, msg, '\'') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, msg, '\'') orelse return null;
    if (close <= open + 1) return null;
    return msg[open + 1 .. close];
}

// ---------------------------------------------------------------------------
// Migration and pattern hints (step 4)

/// What replaced std APIs that models still write from older releases, by
/// (container, missing name). The container is named as zap prints it,
/// without generic arguments (`array_list.Aligned`); a name of `*` covers
/// every missing name of the container. Seeded from
/// `tools/diag/std_removed.py` (0.11 to 0.15 against 0.17, most used
/// first); every replacement is checked against 0.17's std.
const migrations = [_]struct { []const u8, []const u8, []const u8 }{
    .{ "std", "io", "std.io is now std.Io: take `init: std.process.Init` in main, then `var w = std.Io.File.stdout().writer(init.io, &buffer);`, print with `w.interface.print(...)` and `w.interface.flush()`; std.debug.print writes to stderr without io" },
    .{ "std", "rand", "std.rand is now std.Random" },
    .{ "std", "net", "std.net is now std.Io.net" },
    .{ "std", "ChildProcess", "std.ChildProcess is now std.process.Child" },
    .{ "std", "StringArrayHashMap", "managed array hash maps were removed: use std.StringArrayHashMapUnmanaged (`= .empty`) and pass the allocator to each call" },
    .{ "std", "BoundedArray", "std.BoundedArray was removed: use `std.ArrayList(T).initBuffer(&buffer)` with appendBounded and appendSliceBounded" },
    .{ "std", "fifo", "std.fifo was removed: use std.Deque, or std.Io.Reader and std.Io.Writer for byte streams" },
    .{ "std", "event", "std.event was removed: concurrency goes through std.Io" },
    .{ "fs", "cwd", "std.fs.cwd() is now std.Io.Dir.cwd(), and its methods take io: `std.Io.Dir.cwd().openFile(io, path, .{})`" },
    .{ "fs", "Dir", "std.fs.Dir is now std.Io.Dir; its methods take io" },
    .{ "fs", "File", "std.fs.File is now std.Io.File; its methods take io (`file.close(io)`)" },
    .{ "fs", "realpathAlloc", "use `std.Io.Dir.cwd().realPathFileAlloc(io, path, gpa)`" },
    .{ "fs", "openFileAbsolute", "use `std.Io.Dir.openFileAbsolute(io, path, .{})`" },
    .{ "fs", "createFileAbsolute", "use `std.Io.Dir.createFileAbsolute(io, path, .{})`" },
    .{ "fs", "openDirAbsolute", "use `std.Io.Dir.openDirAbsolute(io, path, .{})`" },
    .{ "fs", "renameAbsolute", "use `std.Io.Dir.renameAbsolute(old_path, new_path, io)`" },
    .{ "fs", "MAX_PATH_BYTES", "std.fs.MAX_PATH_BYTES is now std.fs.max_path_bytes" },
    .{ "mem", "page_size", "use std.heap.pageSize() at run time, or std.heap.page_size_min / page_size_max at comptime" },
    .{ "mem", "readIntLittle", "use `std.mem.readInt(T, bytes, .little)`" },
    .{ "mem", "readIntBig", "use `std.mem.readInt(T, bytes, .big)`" },
    .{ "mem", "readIntNative", "use `std.mem.readInt(T, bytes, builtin.cpu.arch.endian())`" },
    .{ "mem", "writeIntLittle", "use `std.mem.writeInt(T, buffer, value, .little)`" },
    .{ "mem", "writeIntBig", "use `std.mem.writeInt(T, buffer, value, .big)`" },
    .{ "mem", "trimRight", "std.mem.trimRight is now std.mem.trimEnd" },
    .{ "mem", "trimLeft", "std.mem.trimLeft is now std.mem.trimStart" },
    .{ "mem", "copy", "use @memcpy for non-overlapping slices, or std.mem.copyForwards" },
    .{ "mem", "set", "use `@memset(slice, value)`" },
    .{ "meta", "Int", "use the builtin `@Int(.unsigned, bits)`" },
    .{ "crypto", "random", "std.crypto.random was replaced by std.Io: `io.random(&buffer)`" },
    .{ "heap", "GeneralPurposeAllocator", "std.heap.GeneralPurposeAllocator is now std.heap.DebugAllocator(.{}); in main, init.gpa from std.process.Init is one already" },
    .{ "time", "sleep", "use `io.sleep(.fromMilliseconds(ms), .awake)` (std.Io.sleep)" },
    .{ "process", "argsAlloc", "arguments come from main: take `init: std.process.Init`, then `var it = init.minimal.args.iterate();`" },
    .{ "process", "args", "arguments come from main: take `init: std.process.Init`, then `var it = init.minimal.args.iterate();`" },
    .{ "fmt", "format", "print through a writer (`w.print(fmt, args)`, std.Io.Writer), or use std.fmt.bufPrint or std.fmt.allocPrint" },
    .{ "json", "stringify", "use `std.json.Stringify.value(value, .{}, writer)`" },
    .{ "json", "stringifyAlloc", "use `std.json.Stringify.valueAlloc(gpa, value, .{})`" },
    .{ "debug", "warn", "std.debug.warn is now std.debug.print" },
    .{ "os", "exit", "use std.process.exit" },
    .{ "os", "*", "std.os keeps only OS-specific APIs (std.os.linux, std.os.windows): POSIX wrappers moved to std.posix, files and sockets to std.Io" },
    .{ "posix", "close", "close files with `file.close(io)` (std.Io.File) and directories with `dir.close(io)`" },
    .{ "posix", "*", "std.posix lost its file and socket functions to std.Io: files are std.Io.File and std.Io.Dir, sockets std.Io.net; raw Linux syscalls are in std.os.linux" },
    .{ "array_list.Aligned", "init", "std.ArrayList is unmanaged: `var list: std.ArrayList(T) = .empty;`, then pass the allocator to each call (`list.append(gpa, x)`, `list.deinit(gpa)`); std.array_list.Managed keeps the old API" },
    .{ "lang.Type", "*", "@typeInfo's fields are lowercase: .int, .pointer, .@\"struct\", .@\"enum\", .@\"union\", .@\"fn\"" },
};

const migration_map = std.StaticStringMap([]const u8).initComptime(kvs: {
    @setEvalBranchQuota(100_000);
    var kvs: [migrations.len]struct { []const u8, []const u8 } = undefined;
    for (migrations, &kvs) |m, *kv| kv.* = .{ m[0] ++ "\x00" ++ m[1], m[2] };
    break :kvs kvs;
});

/// The migration hint for a failed lookup of `name` in the container
/// zap prints as `container` (generic arguments are ignored).
pub fn migrationHint(container: []const u8, name: []const u8) ?[]const u8 {
    const base = container[0 .. std.mem.indexOfScalar(u8, container, '(') orelse container.len];
    var buf: [256]u8 = undefined;
    const exact = std.fmt.bufPrint(&buf, "{s}\x00{s}", .{ base, name }) catch return null;
    if (migration_map.get(exact)) |h| return h;
    const any = std.fmt.bufPrint(&buf, "{s}\x00*", .{base}) catch return null;
    return migration_map.get(any);
}

/// What replaced builtins of older releases (`@intToEnum`), by name with
/// its `@`; checked against 0.17's builtin list.
const builtin_hints = std.StaticStringMap([]const u8).initComptime(.{
    .{ "@intToEnum", "renamed to @enumFromInt, which takes its type from the result: `@as(E, @enumFromInt(x))`" },
    .{ "@enumToInt", "renamed to @intFromEnum: `@intFromEnum(e)`" },
    .{ "@intToFloat", "renamed to @floatFromInt, which takes its type from the result: `@as(f64, @floatFromInt(x))`" },
    .{ "@floatToInt", "renamed to @intFromFloat, which takes its type from the result: `@as(i32, @intFromFloat(x))`" },
    .{ "@ptrToInt", "renamed to @intFromPtr: `@intFromPtr(p)`" },
    .{ "@intToPtr", "renamed to @ptrFromInt, which takes its type from the result: `@as(*T, @ptrFromInt(x))`" },
    .{ "@boolToInt", "renamed to @intFromBool: `@intFromBool(b)`" },
    .{ "@errorToInt", "renamed to @intFromError: `@intFromError(err)`" },
    .{ "@intToError", "renamed to @errorFromInt: `@errorFromInt(x)`" },
    .{ "@errSetCast", "renamed to @errorCast, which takes its type from the result: `@as(E, @errorCast(err))`" },
    .{ "@Type", "@Type was split into @Int, @Struct, @Union, @Enum, @Pointer, @Fn, @Tuple and @EnumLiteral" },
    .{ "@setCold", "use `@branchHint(.cold);` as the first statement of the function" },
    .{ "@fence", "@fence was removed: give the atomic operations themselves the ordering" },
    .{ "@cImport", "@cImport was removed: translate the C headers in build.zig (b.addTranslateC) and import the result as a module" },
});

pub fn builtinHint(name: []const u8) ?[]const u8 {
    return builtin_hints.get(name);
}

test migrationHint {
    try std.testing.expect(migrationHint("std", "io") != null);
    // Generic arguments are ignored, and `*` covers a container.
    try std.testing.expect(std.mem.startsWith(u8, migrationHint("array_list.Aligned(u8,null)", "init").?, "std.ArrayList is unmanaged"));
    try std.testing.expect(std.mem.startsWith(u8, migrationHint("os", "fd_t").?, "std.os keeps"));
    try std.testing.expectEqual(null, migrationHint("mem", "eql"));
    try std.testing.expectEqual(null, migrationHint("array_list.Alignedd", "init"));
}

/// Primitive names an identifier can mean without a declaration.
const primitive_names = [_][]const u8{
    "u8",           "u16",            "u32",         "u64",       "u128",     "usize",
    "i8",           "i16",            "i32",         "i64",       "i128",     "isize",
    "f16",          "f32",            "f64",         "f80",       "f128",     "bool",
    "void",         "type",           "anyerror",    "anyopaque", "noreturn", "comptime_int",
    "comptime_float", "c_int",        "c_uint",      "c_long",    "c_ulong",  "c_char",
    "true",         "false",          "null",        "undefined",
};

/// Appends the names visible at byte `offset` of `tree`, roughly: every
/// container-level declaration of the file, the parameters of the
/// function around `offset`, and its local constants, variables and
/// captures declared before `offset` (block scopes are not tracked: a
/// candidate is a hint), and the primitive names.
fn scopeNames(arena: std.mem.Allocator, tree: *const std.zig.Ast, offset: u32, out: *std.ArrayList([]const u8)) !void {
    try out.appendSlice(arena, &primitive_names);
    const tags = tree.nodes.items(.tag);
    var buf: [2]Ast.Node.Index = undefined;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        const members = if (node == .root) tree.rootDecls() else if (tree.fullContainerDecl(&buf, node)) |c| c.ast.members else continue;
        for (members) |m| {
            var proto_buf: [1]Ast.Node.Index = undefined;
            const name_tok = if (tree.fullVarDecl(m)) |vd| vd.ast.mut_token + 1 else if (tree.fullFnProto(&proto_buf, m)) |fp| fp.name_token orelse continue else continue;
            if (tree.tokenTag(name_tok) == .identifier) try out.append(arena, tree.tokenSlice(name_tok));
        }
    }
    for (0..tree.nodes.len) |i| {
        if (tags[i] != .fn_decl) continue;
        const node: Ast.Node.Index = @enumFromInt(i);
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        if (offset < tree.tokenStart(first) or offset > tree.tokenStart(last)) continue;
        var proto_buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&proto_buf, node).?;
        var it = proto.iterate(tree);
        while (it.next()) |param| if (param.name_token) |t| try out.append(arena, tree.tokenSlice(t));
        // Locals and captures before `offset`, by their tokens.
        var t = first;
        while (t < last and tree.tokenStart(t) < offset) : (t += 1) {
            switch (tree.tokenTag(t)) {
                .keyword_const, .keyword_var => if (tree.tokenTag(t + 1) == .identifier) try out.append(arena, tree.tokenSlice(t + 1)),
                // A capture list follows `)`, `=>`, `catch` or `else`.
                .pipe => if (t > 0) switch (tree.tokenTag(t - 1)) {
                    .r_paren, .equal_angle_bracket_right, .keyword_catch, .keyword_else => {
                        var c = t + 1;
                        while (c < last) : (c += 1) switch (tree.tokenTag(c)) {
                            .identifier => try out.append(arena, tree.tokenSlice(c)),
                            .asterisk, .comma => {},
                            else => break,
                        };
                        t = c;
                    },
                    else => {},
                },
                else => {},
            }
        }
    }
}

fn bundleLoc(arena: std.mem.Allocator, paths: Paths, bundle: std.zig.ErrorBundle, sli: std.zig.ErrorBundle.SourceLocationIndex) !?Loc {
    if (sli == .none) return null;
    const sl = bundle.getSourceLocation(sli);
    const path, const in_lib = try paths.display(arena, bundle.nullTerminatedString(sl.src_path));
    return .{
        .path = path,
        .line = sl.line + 1,
        .col = sl.column + 1,
        .start = sl.span_start,
        .end = sl.span_end,
        .main = sl.span_main,
        .source_line = if (sl.source_line != 0) bundle.nullTerminatedString(sl.source_line) else "",
        .in_lib = in_lib,
    };
}

/// Adds `diags` to `wip` as root messages, for the compiler protocol
/// (`--listen=-`), whose client renders them in upstream's format: the
/// code prefixes the message (`[type-mismatch] ...`), each call frame is
/// a note worded as upstream's, and the reference trace keeps upstream's
/// limit: `ref_limit` frames (`-freference-trace=n`), else 2 for the first
/// error that has a trace and none for the rest, then a frame counting the
/// hidden ones.
pub fn toBundle(wip: *std.zig.ErrorBundle.Wip, diags: []const Diagnostic, ref_limit: ?u32) !void {
    var traced = false;
    for (diags) |d| {
        const limit: u32 = if (d.refs.len == 0) 0 else ref_limit orelse if (traced) 0 else 2;
        if (d.refs.len != 0) traced = true;
        const shown = @min(limit, d.refs.len);
        const hidden = d.refs.len - shown;
        const msg = if (d.code == .unclassified)
            try wip.addString(d.msg)
        else
            try wip.printString("[{t}] {s}", .{ d.code, d.msg });
        // Frames without a location cannot be shown; they count as hidden.
        var refs: std.ArrayList(std.zig.ErrorBundle.ReferenceTrace) = .empty;
        defer refs.deinit(wip.gpa);
        for (d.refs[0..shown]) |r| {
            const l = r.loc orelse continue;
            try refs.append(wip.gpa, .{ .decl_name = try wip.addString(r.name), .src_loc = try bundleSrcLoc(wip, l, 0) });
        }
        const n_hidden: u32 = @intCast(hidden + (shown - refs.items.len));
        if (limit != 0 and n_hidden != 0) try refs.append(wip.gpa, .{ .decl_name = n_hidden, .src_loc = .none });
        const src_loc: std.zig.ErrorBundle.SourceLocationIndex = if (d.loc) |l| try bundleSrcLoc(wip, l, @intCast(refs.items.len)) else .none;
        // The trace trails the message's source location.
        if (d.loc != null) for (refs.items) |r| try wip.addReferenceTrace(r);
        // Candidates and the hint trail the notes as notes without a location.
        var n_edits: u32 = 0;
        for (d.fixes) |f| n_edits += @intCast(f.edits.len);
        const extra_notes = @as(u32, @intFromBool(d.candidates.len != 0)) + @intFromBool(d.hint != null) + n_edits;
        const notes_len: u32 = @intCast(d.notes.len + extra_notes);
        try wip.addRootErrorMessage(.{ .msg = msg, .count = d.count, .src_loc = src_loc, .notes_len = notes_len });
        const notes_start = try wip.reserveNotes(notes_len);
        for (d.notes, notes_start..) |n, i| {
            const note_msg = if (n.call) |kind| try wip.addString(switch (kind) {
                .@"inline" => "called inline here",
                .@"comptime" => "called at comptime here",
            }) else try wip.addString(n.msg);
            const note_loc: std.zig.ErrorBundle.SourceLocationIndex = if (n.loc) |l| try bundleSrcLoc(wip, l, 0) else .none;
            const index = try wip.addErrorMessage(.{ .msg = note_msg, .count = n.count, .src_loc = note_loc });
            wip.extra.items[i] = @backingInt(index);
        }
        var i = notes_start + d.notes.len;
        if (d.candidates.len != 0) {
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(wip.gpa);
            try text.appendSlice(wip.gpa, "candidates:");
            for (d.candidates, 0..) |c, j| try text.print(wip.gpa, "{s} {s}", .{ if (j == 0) "" else ",", c });
            const index = try wip.addErrorMessage(.{ .msg = try wip.addString(text.items), .src_loc = .none });
            wip.extra.items[i] = @backingInt(index);
            i += 1;
        }
        if (d.hint) |h| {
            // Not one statement: adding the message can move `extra`.
            const index = try wip.addErrorMessage(.{ .msg = try wip.printString("hint: {s}", .{h}), .src_loc = .none });
            wip.extra.items[i] = @backingInt(index);
            i += 1;
        }
        for (d.fixes) |f| for (f.edits) |e| {
            const index = try wip.addErrorMessage(.{ .msg = try wip.printString("{f}", .{fmtEdit(f.applicability, e)}), .src_loc = .none });
            wip.extra.items[i] = @backingInt(index);
            i += 1;
        };
    }
}

fn bundleSrcLoc(wip: *std.zig.ErrorBundle.Wip, l: Loc, reference_trace_len: u32) !std.zig.ErrorBundle.SourceLocationIndex {
    return wip.addSourceLocation(.{
        .src_path = try wip.addString(l.path),
        .line = l.line -| 1,
        .column = l.col -| 1,
        .span_start = l.start,
        .span_main = l.main,
        .span_end = l.end,
        .source_line = if (l.source_line.len != 0) try wip.addString(l.source_line) else 0,
        .reference_trace_len = reference_trace_len,
    });
}

pub fn render(w: *Writer, diags: []const Diagnostic, format: Format) Writer.Error!void {
    switch (format) {
        .text => {
            for (diags) |d| try renderText(w, d);
            try w.print("{d} error{s}\n", .{ diags.len, if (diags.len == 1) "" else "s" });
        },
        .json => {
            for (diags) |d| try renderJson(w, d);
            try w.print("{{\"summary\":{{\"errors\":{d}}}}}\n", .{diags.len});
        },
    }
}

/// Source lines longer than this print as a window around the column.
const max_source_line = 160;

fn renderText(w: *Writer, d: Diagnostic) Writer.Error!void {
    if (d.loc) |l| try w.print("{s}:{d}:{d}: ", .{ l.path, l.line, l.col });
    try w.writeAll("error");
    if (d.code != .unclassified) try w.print("[{t}]", .{d.code});
    try w.print(": {s}", .{d.msg});
    if (d.count > 1) try w.print(" ({d} times)", .{d.count});
    try w.writeByte('\n');
    if (d.loc) |l| if (sourceExcerpt(l)) |src| try w.print("  | {s}\n", .{src});
    var user_frames: usize = 0;
    var lib_frames: usize = 0;
    for (d.notes) |n| {
        if (n.call != null) {
            if (n.loc != null and !n.loc.?.in_lib) user_frames += 1 else lib_frames += 1;
            continue;
        }
        try w.writeAll("  note");
        if (n.loc) |l| try w.print(" {s}:{d}:{d}", .{ l.path, l.line, l.col });
        try w.print(": {s}", .{n.msg});
        if (n.count > 1) try w.print(" ({d} times)", .{n.count});
        if (n.decl) if (n.loc) |l| if (sourceExcerpt(l)) |src| try w.print(": {s}", .{src});
        try w.writeByte('\n');
    }
    if (d.candidates.len != 0) {
        try w.writeAll("  candidates:");
        for (d.candidates, 0..) |c, i| try w.print("{s} {s}", .{ if (i == 0) "" else ",", c });
        try w.writeByte('\n');
    }
    if (d.hint) |h| try w.print("  hint: {s}\n", .{h});
    for (d.fixes) |f| for (f.edits) |e| try w.print("  {f}\n", .{fmtEdit(f.applicability, e)});
    // Frames in the zig lib directory carry nothing an agent can change;
    // they print only as a count next to the user's frames.
    if (user_frames != 0) {
        try w.writeAll("  call:");
        var first = true;
        for (d.notes) |n| {
            const kind = n.call orelse continue;
            const l = n.loc orelse continue;
            if (l.in_lib) continue;
            try w.print("{s} {s}:{d}:{d} {t}", .{ if (first) "" else ",", l.path, l.line, l.col, kind });
            if (n.count > 1) try w.print(" ({d} times)", .{n.count});
            first = false;
        }
        if (lib_frames != 0) try w.print(", +{d} std", .{lib_frames});
        try w.writeByte('\n');
    }
    // The reference trace, by the same rule: user frames, then a count.
    var user_refs: usize = 0;
    for (d.refs) |r| {
        if (r.loc != null and !r.loc.?.in_lib) user_refs += 1;
    }
    if (user_refs != 0) {
        try w.writeAll("  ref:");
        var first = true;
        for (d.refs) |r| {
            const l = r.loc orelse continue;
            if (l.in_lib) continue;
            try w.print("{s} {s} {s}:{d}:{d}", .{ if (first) "" else " <-", r.name, l.path, l.line, l.col });
            first = false;
        }
        if (d.refs.len != user_refs) try w.print(" (+{d} std frames)", .{d.refs.len - user_refs});
        try w.writeByte('\n');
    }
}

/// An edit as the text output and error bundles show it:
/// `fix[?] <path>:<line>:<col>-<line>:<col>: "<text>"`, the text as a Zig
/// string literal (an insertion has equal ends, a deletion text "").
fn fmtEdit(applicability: Applicability, e: Edit) std.fmt.Alt(FixEdit, formatEdit) {
    return .{ .data = .{ applicability, e } };
}

const FixEdit = struct { Applicability, Edit };

fn formatEdit(data: FixEdit, w: *Writer) Writer.Error!void {
    const applicability, const e = data;
    try w.print("fix{s} {s}:{d}:{d}-{d}:{d}: \"{f}\"", .{ if (applicability == .exact) "" else "?", e.path, e.line, e.col, e.end_line, e.end_col, std.zig.fmtString(e.text) });
}

/// The primary source line without its indentation, cut to a window around
/// the column when it is long; null when there is nothing to show.
fn sourceExcerpt(l: Loc) ?[]const u8 {
    var line = std.mem.trimEnd(u8, l.source_line, "\r");
    const col0 = @min(l.col -| 1, line.len);
    if (line.len > max_source_line) {
        const start = col0 -| max_source_line / 2;
        line = line[start..@min(line.len, start + max_source_line)];
    }
    line = std.mem.trim(u8, line, " \t");
    return if (line.len == 0) null else line;
}

const JsonLoc = struct { file: []const u8, line: u32, col: u32, span: [2]u32 };

fn renderJson(w: *Writer, d: Diagnostic) Writer.Error!void {
    const JsonNote = struct { file: ?[]const u8 = null, line: ?u32 = null, col: ?u32 = null, span: ?[2]u32 = null, msg: []const u8, count: ?u32 = null, src: ?[]const u8 = null };
    const JsonCall = struct { file: []const u8, line: u32, col: u32, kind: CallKind, count: ?u32 = null };
    const JsonRef = struct { @"fn": []const u8, file: ?[]const u8 = null, line: ?u32 = null, col: ?u32 = null };
    var refs_buf: [64]JsonRef = undefined;
    var n_refs: usize = 0;
    for (d.refs) |r| {
        if (n_refs == refs_buf.len) break;
        refs_buf[n_refs] = .{ .@"fn" = r.name };
        if (r.loc) |l| {
            refs_buf[n_refs].file = l.path;
            refs_buf[n_refs].line = l.line;
            refs_buf[n_refs].col = l.col;
        }
        n_refs += 1;
    }
    var notes_buf: [64]JsonNote = undefined;
    var calls_buf: [64]JsonCall = undefined;
    var n_notes: usize = 0;
    var n_calls: usize = 0;
    for (d.notes) |n| {
        if (n.call) |kind| {
            const l = n.loc orelse continue;
            if (n_calls == calls_buf.len) continue;
            calls_buf[n_calls] = .{ .file = l.path, .line = l.line, .col = l.col, .kind = kind, .count = if (n.count > 1) n.count else null };
            n_calls += 1;
        } else if (n_notes < notes_buf.len) {
            notes_buf[n_notes] = .{ .msg = n.msg, .count = if (n.count > 1) n.count else null };
            if (n.loc) |l| {
                notes_buf[n_notes].file = l.path;
                notes_buf[n_notes].line = l.line;
                notes_buf[n_notes].col = l.col;
                notes_buf[n_notes].span = .{ l.start, l.end };
                if (n.decl) notes_buf[n_notes].src = sourceExcerpt(l);
            }
            n_notes += 1;
        }
    }
    const JsonEdit = struct { file: []const u8, span: [2]u32, text: []const u8 };
    const JsonFix = struct { applicability: Applicability, edits: []const JsonEdit };
    var fixes_buf: [8]JsonFix = undefined;
    var edits_buf: [16]JsonEdit = undefined;
    var n_fixes: usize = 0;
    var n_edits: usize = 0;
    for (d.fixes) |f| {
        if (n_fixes == fixes_buf.len or n_edits + f.edits.len > edits_buf.len) break;
        for (f.edits, edits_buf[n_edits..][0..f.edits.len]) |e, *je| je.* = .{ .file = e.path, .span = .{ e.start, e.end }, .text = e.text };
        fixes_buf[n_fixes] = .{ .applicability = f.applicability, .edits = edits_buf[n_edits..][0..f.edits.len] };
        n_fixes += 1;
        n_edits += f.edits.len;
    }
    const obj: struct {
        code: ?Code,
        file: ?[]const u8 = null,
        line: ?u32 = null,
        col: ?u32 = null,
        span: ?[2]u32 = null,
        msg: []const u8,
        count: ?u32,
        src: ?[]const u8 = null,
        notes: ?[]const JsonNote,
        candidates: ?[]const []const u8,
        hint: ?[]const u8,
        fixes: ?[]const JsonFix,
        calls: ?[]const JsonCall,
        ref: ?[]const JsonRef,
    } = .{
        .code = if (d.code == .unclassified) null else d.code,
        .file = if (d.loc) |l| l.path else null,
        .line = if (d.loc) |l| l.line else null,
        .col = if (d.loc) |l| l.col else null,
        .span = if (d.loc) |l| .{ l.start, l.end } else null,
        .msg = d.msg,
        .count = if (d.count > 1) d.count else null,
        .src = if (d.loc) |l| sourceExcerpt(l) else null,
        .notes = if (n_notes != 0) notes_buf[0..n_notes] else null,
        .candidates = if (d.candidates.len != 0) d.candidates else null,
        .hint = d.hint,
        .fixes = if (n_fixes != 0) fixes_buf[0..n_fixes] else null,
        .calls = if (n_calls != 0) calls_buf[0..n_calls] else null,
        .ref = if (n_refs != 0) refs_buf[0..n_refs] else null,
    };
    try std.json.Stringify.value(obj, .{ .emit_null_optional_fields = false }, w);
    try w.writeByte('\n');
}

// ---------------------------------------------------------------------------
// Fixes (step 5)

const Ast = std.zig.Ast;

/// The fix for AstGen error `code` with message `msg` at byte `main` of
/// `tree`'s source, if zap knows one.
fn astGenFix(arena: std.mem.Allocator, tree: *const Ast, code: Code, msg: []const u8, main: u32, candidates: []const []const u8) !?RawFix {
    const tok = tokenAt(tree, main) orelse return null;
    switch (code) {
        .unused => {
            const name = tree.tokenSlice(tok);
            if (std.mem.startsWith(u8, msg, "unused local ")) {
                const semi = statementEnd(tree, tok) orelse return null;
                const discard = try statementAfter(arena, tree, semi, indentOf(tree.source, tree.tokenStart(tok)), try std.fmt.allocPrint(arena, "_ = {s};", .{name}));
                // An unused variable is never mutated either.
                if (tok > 0 and tree.tokenTag(tok - 1) == .keyword_var)
                    return try rawFix(arena, .exact, &.{ replaceToken(tree, tok - 1, "const"), discard });
                return try rawFix(arena, .exact, &.{discard});
            }
            if (std.mem.eql(u8, msg, "unused function parameter")) {
                const body = enclosingFnBody(tree, tok) orelse return null;
                const lbrace = tree.firstToken(body);
                const indent = try std.fmt.allocPrint(arena, "{s}    ", .{indentOf(tree.source, tree.tokenStart(lbrace))});
                return try rawFix(arena, .exact, &.{try statementAfter(arena, tree, lbrace, indent, try std.fmt.allocPrint(arena, "_ = {s};", .{name}))});
            }
            if (std.mem.eql(u8, msg, "unused capture") or std.mem.eql(u8, msg, "unused switch tag capture"))
                return captureFix(arena, tree, tok, msg[7] == 's');
            return null;
        },
        .@"unused-label" => {
            // `blk: ` goes, up to what follows it.
            if (tree.tokenTag(tok) != .identifier or tree.tokenTag(tok + 1) != .colon) return null;
            return try rawFix(arena, .exact, &.{.{ .start = tree.tokenStart(tok), .end = tree.tokenStart(tok + 2), .text = "" }});
        },
        .@"never-mutated" => {
            if (tok == 0 or tree.tokenTag(tok - 1) != .keyword_var) return null;
            return try rawFix(arena, .exact, &.{replaceToken(tree, tok - 1, "const")});
        },
        .@"pointless-discard" => {
            // `_ = name;`, at `name`.
            if (tok < 2 or tree.tokenTag(tok - 1) != .equal or !std.mem.eql(u8, tree.tokenSlice(tok - 2), "_") or tree.tokenTag(tok + 1) != .semicolon) return null;
            const source = tree.source;
            const start = tree.tokenStart(tok - 2);
            const end = tokenEnd(tree, tok + 1);
            const line_start = lineStart(source, start);
            const line_end = lineEnd(source, end);
            // Alone on its line: the line goes.
            if (std.mem.trim(u8, source[line_start..start], " \t").len == 0 and std.mem.trim(u8, source[end..line_end], " \t\r").len == 0 and line_end < source.len)
                return try rawFix(arena, .exact, &.{.{ .start = line_start, .end = line_end + 1, .text = "" }});
            return try rawFix(arena, .exact, &.{.{ .start = start, .end = end, .text = "" }});
        },
        .@"unknown-builtin" => return builtinFix(arena, tree, tok),
        .undeclared => return renameFix(arena, tree.source, tree.tokenStart(tok), tokenEnd(tree, tok), candidates),
        else => return null,
    }
}

fn rawFix(arena: std.mem.Allocator, applicability: Applicability, edits: []const RawEdit) !RawFix {
    return .{ .applicability = applicability, .edits = try arena.dupe(RawEdit, edits) };
}

/// Renames the name at `start..end` to the only candidate, when it is one
/// edit or a change of case away (a typo, not another name).
pub fn renameFix(arena: std.mem.Allocator, source: []const u8, start: u32, end: u32, candidates: []const []const u8) !?RawFix {
    if (candidates.len != 1 or end > source.len) return null;
    const name = source[start..end];
    const c = candidates[0];
    if (!std.ascii.eqlIgnoreCase(name, c) and editDistance(name, c, 1) == null) return null;
    return try rawFix(arena, .maybe, &.{.{ .start = start, .end = end, .text = c }});
}

/// Wraps the expression at `start..end` as `<before><expression><after>`
/// (a cast). Null when the span is not exactly one expression's.
pub fn wrapFix(arena: std.mem.Allocator, tree: *const Ast, start: u32, end: u32, before: []const u8, after: []const u8) !?RawFix {
    if (!isExpression(tree, start, end)) return null;
    return try rawFix(arena, .maybe, &.{.{ .start = start, .end = end, .text = try std.mem.concat(arena, u8, &.{ before, tree.source[start..end], after }) }});
}

/// Puts `try ` before the expression at `start..end`, an ignored error
/// union, and `_ = ` before that if its payload is not `void` and the
/// expression is a statement. Null outside an expression or in a `defer`,
/// where `try` is not allowed.
pub fn tryFix(arena: std.mem.Allocator, tree: *const Ast, start: u32, end: u32, payload_void: bool) !?RawFix {
    if (!isExpression(tree, start, end)) return null;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        switch (tree.nodeTag(node)) {
            .@"defer", .@"errdefer" => {
                if (tree.tokenStart(tree.firstToken(node)) <= start and end <= tokenEnd(tree, tree.lastToken(node))) return null;
            },
            else => {},
        }
    }
    const tok = tokenAt(tree, start).?;
    const statement = tok == 0 or switch (tree.tokenTag(tok - 1)) {
        .semicolon, .l_brace, .r_brace => true,
        else => false,
    };
    const text = if (statement and !payload_void) "_ = try " else "try ";
    return try rawFix(arena, .maybe, &.{.{ .start = start, .end = start, .text = text }});
}

/// Whether `start..end` is exactly the span of an expression node.
fn isExpression(tree: *const Ast, start: u32, end: u32) bool {
    const first = tokenAt(tree, start) orelse return false;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        if (tree.firstToken(node) != first or tokenEnd(tree, tree.lastToken(node)) != end) continue;
        switch (tree.nodeTag(node)) {
            .root, .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl, .container_field, .container_field_init, .container_field_align, .fn_decl, .test_decl => {},
            else => return true,
        }
    }
    return false;
}

/// Adds prongs `prongs` (`.b => @panic("TODO"),`) to the switch whose
/// `switch` keyword starts at byte `offset`: each on its own line before
/// the closing brace, or on the brace's line when the switch is on one.
pub fn prongsFix(arena: std.mem.Allocator, tree: *const Ast, offset: u32, prongs: []const []const u8) !?RawFix {
    const tok = tokenAt(tree, offset) orelse return null;
    if (tree.tokenTag(tok) != .keyword_switch) return null;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        switch (tree.nodeTag(node)) {
            .@"switch", .switch_comma => {},
            else => continue,
        }
        if (tree.nodeMainToken(node) != tok) continue;
        const rbrace = tree.lastToken(node);
        const prev = rbrace - 1;
        const comma = tree.tokenTag(prev) != .comma and tree.tokenTag(prev) != .l_brace;
        const source = tree.source;
        const rbrace_start = tree.tokenStart(rbrace);
        const line_start = lineStart(source, rbrace_start);
        var text: std.ArrayList(u8) = .empty;
        var edits: std.ArrayList(RawEdit) = .empty;
        if (rbrace_start - line_start == indentOf(source, rbrace_start).len and tree.tokenStart(prev) < line_start) {
            const indent = indentOf(source, rbrace_start);
            for (prongs) |p| try text.print(arena, "{s}    {s}\n", .{ indent, p });
            if (comma) try edits.append(arena, .{ .start = tokenEnd(tree, prev), .end = tokenEnd(tree, prev), .text = "," });
            try edits.append(arena, .{ .start = line_start, .end = line_start, .text = text.items });
        } else {
            if (comma) try text.append(arena, ',');
            for (prongs) |p| try text.print(arena, " {s}", .{p});
            try edits.append(arena, .{ .start = tokenEnd(tree, prev), .end = tokenEnd(tree, prev), .text = text.items });
        }
        return .{ .applicability = .placeholder, .edits = edits.items };
    }
    return null;
}

/// The offset of the last whole-identifier occurrence of `name` in `text`
/// (the name in `s.name` or `s.name()`).
pub fn nameIn(text: []const u8, name: []const u8) ?u32 {
    var end = text.len;
    while (std.mem.lastIndexOf(u8, text[0..end], name)) |at| : (end = at) {
        const after = at + name.len;
        const ident = struct {
            fn f(c: u8) bool {
                return std.ascii.isAlphanumeric(c) or c == '_';
            }
        }.f;
        if ((at == 0 or !ident(text[at - 1])) and (after == text.len or !ident(text[after]))) return @intCast(at);
        if (at == 0) break;
    }
    return null;
}

/// Builtins of older releases that 0.17 renamed, as calls of the new
/// ones: the old argument count and the replacement, where `{0}` and `{1}`
/// stand for the old arguments.
const builtin_rewrites = std.StaticStringMap(struct { u8, []const u8 }).initComptime(.{
    .{ "@intToEnum", .{ 2, "@as({0}, @enumFromInt({1}))" } },
    .{ "@enumToInt", .{ 1, "@intFromEnum({0})" } },
    .{ "@intToFloat", .{ 2, "@as({0}, @floatFromInt({1}))" } },
    .{ "@floatToInt", .{ 2, "@as({0}, @intFromFloat({1}))" } },
    .{ "@ptrToInt", .{ 1, "@intFromPtr({0})" } },
    .{ "@intToPtr", .{ 2, "@as({0}, @ptrFromInt({1}))" } },
    .{ "@boolToInt", .{ 1, "@intFromBool({0})" } },
    .{ "@errorToInt", .{ 1, "@intFromError({0})" } },
    .{ "@intToError", .{ 1, "@errorFromInt({0})" } },
    .{ "@errSetCast", .{ 2, "@as({0}, @errorCast({1}))" } },
});

/// Rewrites a call of a renamed builtin (`builtin_rewrites`) at `tok`.
fn builtinFix(arena: std.mem.Allocator, tree: *const Ast, tok: Ast.TokenIndex) !?RawFix {
    const n_args, const template = builtin_rewrites.get(tree.tokenSlice(tok)) orelse return null;
    if (tree.tokenTag(tok + 1) != .l_paren) return null;
    // The arguments' byte ranges, split at top-level commas.
    var args: [2][2]u32 = undefined;
    var n: usize = 0;
    var depth: u32 = 0;
    var t = tok + 2;
    var arg_start = t;
    while (true) : (t += 1) switch (tree.tokenTag(t)) {
        .l_paren, .l_brace, .l_bracket => depth += 1,
        .r_paren, .r_brace, .r_bracket => {
            if (depth > 0) {
                depth -= 1;
                continue;
            }
            if (tree.tokenTag(t) != .r_paren) return null;
            // A trailing comma ends no argument.
            if (t > arg_start) {
                if (n == args.len) return null;
                args[n] = .{ tree.tokenStart(arg_start), tokenEnd(tree, t - 1) };
                n += 1;
            }
            break;
        },
        .comma => if (depth == 0) {
            if (n == args.len or t == arg_start) return null;
            args[n] = .{ tree.tokenStart(arg_start), tokenEnd(tree, t - 1) };
            n += 1;
            arg_start = t + 1;
        },
        .eof => return null,
        else => {},
    };
    if (n != n_args) return null;
    var text: std.ArrayList(u8) = .empty;
    var rest: []const u8 = template;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        try text.appendSlice(arena, rest[0..open]);
        const a = args[rest[open + 1] - '0'];
        try text.appendSlice(arena, tree.source[a[0]..a[1]]);
        rest = rest[open + 3 ..];
    }
    try text.appendSlice(arena, rest);
    return try rawFix(arena, .exact, &.{.{ .start = tree.tokenStart(tok), .end = tokenEnd(tree, t), .text = text.items }});
}

/// Discards an unused capture at `tok` (`tag`: a switch prong's tag
/// capture) the way AstGen allows: no capture where `_` would be "discard
/// of capture" (a switch prong's only capture, `catch |err|`), else `_`
/// (an `if`'s `else |err|` must stay to keep the operand an error union).
/// An unused `for` counter goes with its `0..` input.
fn captureFix(arena: std.mem.Allocator, tree: *const Ast, tok: Ast.TokenIndex, tag: bool) !?RawFix {
    // The capture list `|...|` around `tok`.
    var open = tok;
    while (open > 0) : (open -= 1) switch (tree.tokenTag(open - 1)) {
        .comma, .identifier, .asterisk => {},
        else => break,
    };
    if (open == 0 or tree.tokenTag(open - 1) != .pipe) return null;
    open -= 1;
    var close = tok + 1;
    while (tree.tokenTag(close) != .pipe) : (close += 1) switch (tree.tokenTag(close)) {
        .comma, .identifier, .asterisk => {},
        else => return null,
    };
    // `*x` is discarded whole.
    const name_start = if (tree.tokenTag(tok - 1) == .asterisk) tok - 1 else tok;
    const only = name_start == open + 1 and close == tok + 1;
    const before = tree.tokenTag(open -| 1);
    if (tag) {
        // `|payload, tag|`: drop `, tag`.
        if (tree.tokenTag(tok - 1) != .comma) return null;
        return try rawFix(arena, .exact, &.{.{ .start = tokenEnd(tree, tok - 2), .end = tokenEnd(tree, tok), .text = "" }});
    }
    if (only and (before == .equal_angle_bracket_right or before == .keyword_catch)) {
        // `|x| ` goes, up to what follows it.
        return try rawFix(arena, .exact, &.{.{ .start = tree.tokenStart(open), .end = tree.tokenStart(close + 1), .text = "" }});
    }
    if (forCounter(tree, open, name_start)) |input| {
        const index = captureIndex(tree, open, name_start);
        var edits: [2]RawEdit = undefined;
        // With its comma: the one before it, or after it when it is first.
        edits[0] = if (index > 0)
            .{ .start = tokenEnd(tree, tree.lastToken(input.prev.unwrap().?)), .end = tokenEnd(tree, tree.lastToken(input.node)), .text = "" }
        else
            .{ .start = tree.tokenStart(tree.firstToken(input.node)), .end = tree.tokenStart(tree.lastToken(input.node) + 2), .text = "" };
        edits[1] = if (index > 0)
            .{ .start = tokenEnd(tree, name_start - 2), .end = tokenEnd(tree, tok), .text = "" }
        else
            .{ .start = tree.tokenStart(name_start), .end = tree.tokenStart(tok + 2), .text = "" };
        return try rawFix(arena, .exact, &edits);
    }
    return try rawFix(arena, .exact, &.{.{ .start = tree.tokenStart(name_start), .end = tokenEnd(tree, tok), .text = "_" }});
}

/// The position of the capture starting at `name_start` in the list
/// opened by `open`.
fn captureIndex(tree: *const Ast, open: Ast.TokenIndex, name_start: Ast.TokenIndex) usize {
    var index: usize = 0;
    for (open + 1..name_start) |t| index += @intFromBool(tree.tokenTag(@intCast(t)) == .comma);
    return index;
}

/// When the capture at `name_start` of the list opened by `open` is a
/// `for` loop's counter (its input an unbounded range, `0..`), that input
/// and the one before it.
fn forCounter(tree: *const Ast, open: Ast.TokenIndex, name_start: Ast.TokenIndex) ?struct { node: Ast.Node.Index, prev: Ast.Node.OptionalIndex } {
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        const f = tree.fullFor(node) orelse continue;
        if (f.payload_token != open + 1 and f.payload_token != open + 2) continue;
        const index = captureIndex(tree, open, name_start);
        if (index >= f.ast.inputs.len or f.ast.inputs.len < 2) return null;
        const input = f.ast.inputs[index];
        if (tree.nodeTag(input) != .for_range or tree.nodeData(input).node_and_opt_node[1] != .none) return null;
        return .{ .node = input, .prev = if (index > 0) f.ast.inputs[index - 1].toOptional() else .none };
    }
    return null;
}

/// The body of the innermost function declaration around `tok`.
fn enclosingFnBody(tree: *const Ast, tok: Ast.TokenIndex) ?Ast.Node.Index {
    var best: ?Ast.Node.Index = null;
    var best_len: u32 = std.math.maxInt(u32);
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        if (tree.nodeTag(node) != .fn_decl) continue;
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        if (tok < first or tok > last or last - first >= best_len) continue;
        best = tree.nodeData(node).node_and_node[1];
        best_len = last - first;
    }
    return best;
}

/// The `;` ending the statement that contains `tok`.
fn statementEnd(tree: *const Ast, tok: Ast.TokenIndex) ?Ast.TokenIndex {
    var depth: u32 = 0;
    var t = tok;
    while (true) : (t += 1) switch (tree.tokenTag(t)) {
        .l_paren, .l_brace, .l_bracket => depth += 1,
        .r_paren, .r_brace, .r_bracket => depth = std.math.sub(u32, depth, 1) catch return null,
        .semicolon => if (depth == 0) return t,
        .eof => return null,
        else => {},
    };
}

/// Inserts statement `stmt` after token `tok`: on the next line with
/// `indent` when `tok` ends its line, else on the same line.
fn statementAfter(arena: std.mem.Allocator, tree: *const Ast, tok: Ast.TokenIndex, indent: []const u8, stmt: []const u8) !RawEdit {
    const source = tree.source;
    const end = tokenEnd(tree, tok);
    const line_end = lineEnd(source, end);
    if (line_end == source.len or tree.tokenStart(tok + 1) < line_end)
        return .{ .start = end, .end = end, .text = try std.fmt.allocPrint(arena, " {s}", .{stmt}) };
    return .{ .start = line_end + 1, .end = line_end + 1, .text = try std.fmt.allocPrint(arena, "{s}{s}\n", .{ indent, stmt }) };
}

fn replaceToken(tree: *const Ast, tok: Ast.TokenIndex, text: []const u8) RawEdit {
    return .{ .start = tree.tokenStart(tok), .end = tokenEnd(tree, tok), .text = text };
}

/// The token starting at byte `offset`, if one does.
fn tokenAt(tree: *const Ast, offset: u32) ?Ast.TokenIndex {
    const starts = tree.tokens.items(.start);
    var lo: usize = 0;
    var hi: usize = starts.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (starts[mid] < offset) lo = mid + 1 else hi = mid;
    }
    return if (lo < starts.len and starts[lo] == offset) @intCast(lo) else null;
}

fn tokenEnd(tree: *const Ast, tok: Ast.TokenIndex) u32 {
    return tree.tokenStart(tok) + @as(u32, @intCast(tree.tokenSlice(tok).len));
}

fn lineStart(source: []const u8, offset: u32) u32 {
    return if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |i| @intCast(i + 1) else 0;
}

fn lineEnd(source: []const u8, offset: u32) u32 {
    return @intCast(std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse source.len);
}

/// The indentation of the line holding byte `offset`.
pub fn indentOf(source: []const u8, offset: u32) []const u8 {
    const start = lineStart(source, offset);
    var end = start;
    while (end < source.len and (source[end] == ' ' or source[end] == '\t')) end += 1;
    return source[start..end];
}

// ---------------------------------------------------------------------------
// AstGen codes

/// The code of a Sema, linker or backend error, by the format string it is
/// made from (`Zcu.addError`, `Sema.fail`): an error's kind follows from
/// its wording, so call sites name no code. Formats zap invents for what it
/// does not support yet start with "zap ". Unknown formats are
/// `unclassified`; a test checks that none remain.
pub fn formatCode(fmt: []const u8) Code {
    if (std.mem.startsWith(u8, fmt, "zap ")) return .unsupported;
    return format_codes.get(fmt) orelse .unclassified;
}

const format_codes: std.StaticStringMap(Code) = .initComptime(.{
    .{ "expected at least {d} argument(s), found {d}", .@"arg-count" },
    .{ "expected {d} argument(s), found {d}", .@"arg-count" },
    .{ "cannot assign to constant", .@"assign-to-const" },
    .{ "cannot copy to constant pointer", .@"assign-to-const" },
    .{ "cannot memset constant pointer", .@"assign-to-const" },
    .{ "cannot dereference non-pointer type '{f}'", .@"bad-access" },
    .{ "expected indexable; found '{f}'", .@"bad-access" },
    .{ "expected pointer to an indexable object, found '{f}'", .@"bad-access" },
    .{ "index syntax required for unknown-length pointer type '{f}'", .@"bad-access" },
    .{ "index syntax required to access runtime-known slice", .@"bad-access" },
    .{ "pointer capture of non pointer type '{f}'", .@"bad-access" },
    .{ "slice of non-array type '{f}'", .@"bad-access" },
    .{ "slice of single-item pointer cannot have sentinel", .@"bad-access" },
    .{ "type '{f}' does not support field access", .@"bad-access" },
    .{ "type '{f}' does not support indexing", .@"bad-access" },
    .{ "type '{f}' is not an indexable pointer", .@"bad-access" },
    .{ "invalid inline assembly output type '{f}'", .@"bad-asm" },
    .{ "'@cVaStart' only allowed in variadic functions", .@"bad-call" },
    .{ "arrays must be passed by reference to variadic function", .@"bad-call" },
    .{ "cannot call a generic function through a pointer", .@"bad-call" },
    .{ "integer and float literals passed to variadic function must be casted to a fixed-size number type", .@"bad-call" },
    .{ "member function '{s}' has no parameters", .@"bad-call" },
    .{ "type '{f}' not a function", .@"bad-call" },
    .{ "unable to call function with naked calling convention", .@"bad-call" },
    .{ "variadic function does not support '.{s}' calling convention", .@"bad-call" },
    .{ "@bitCast size mismatch: destination type '{f}' has {d} bits but source type '{f}' has {d} bits", .@"bad-cast" },
    .{ "@ptrCast discards const qualifier", .@"bad-cast" },
    .{ "bit-pointer cannot refer to value of type '{f}'", .@"bad-cast" },
    .{ "cannot cast an error union type to error set", .@"bad-cast" },
    .{ "expected backing integer type, found '{f}'", .@"bad-cast" },
    .{ "non-packed struct '{f}' does not have a backing integer", .@"bad-cast" },
    .{ "non-packed union '{f}' does not have a backing integer", .@"bad-cast" },
    .{ "packed type '{f}' at bit offset {d} ends {d} bits after the end of a {d} byte host integer", .@"bad-cast" },
    .{ "packed type '{f}' at bit offset {d} starts {d} bits after the end of a {d} byte host integer", .@"bad-cast" },
    .{ "pointer type '{f}' does not allow address zero", .@"bad-cast" },
    .{ "pointer type '{f}' is not a pointer to field '{s}' of '{f}'", .@"bad-cast" },
    .{ "slice length does not divide exactly into destination elements", .@"bad-cast" },
    .{ "type '{f}' does not divide exactly into destination elements", .@"bad-cast" },
    .{ "untagged union '{f}' cannot be converted to integer", .@"bad-cast" },
    .{ "backing integer type '{f}' has bit size {d} but the struct fields have a total bit size of {d}", .@"bad-container" },
    .{ "duplicate {t} field name '{s}'", .@"bad-container" },
    .{ "enum tag value {f} already taken", .@"bad-container" },
    .{ "enum tag value {f} already taken by field '{s}'", .@"bad-container" },
    .{ "explicitly valued enum requires an integer tag type", .@"bad-container" },
    .{ "field bit width does not match backing integer", .@"bad-container" },
    .{ "field bit width does not match earlier field", .@"bad-container" },
    .{ "non-exhaustive enum missing integer tag type", .@"bad-container" },
    .{ "opaque types have unknown size and therefore cannot be directly embedded in tuples", .@"bad-container" },
    .{ "packed structs cannot contain fields of type '{f}'", .@"bad-container" },
    .{ "packed union has no fields", .@"bad-container" },
    .{ "packed unions cannot contain fields of type '{f}'", .@"bad-container" },
    .{ "size of packed struct '{d}' exceeds maximum bit width of 65535", .@"bad-container" },
    .{ "tag type must be an integer type", .@"bad-container" },
    .{ "empty exhaustive enums must be backed by 'noreturn'", .@"bad-container" },
    .{ "non-empty enums cannot be backed by 'noreturn'", .@"bad-container" },
    .{ "no size available for uninstantiable type '{f}'", .@"bad-type" },
    .{ "no align available for uninstantiable type '{f}'", .@"bad-type" },
    .{ "array of opaque type '{f}' not allowed", .@"bad-type" },
    .{ "array of 'noreturn' not allowed", .@"bad-type" },
    .{ "cannot initialize union field with uninstantiable type '{f}'", .@"bad-type" },
    .{ "unable to override alignment of packed struct fields", .@"bad-container" },
    .{ "union fields do not match tag type '{f}'", .@"bad-container" },
    .{ "{d} enum field names but {d} values", .@"bad-container" },
    .{ "{d} field names but {d} field attributes", .@"bad-container" },
    .{ "{d} field names but {d} field types", .@"bad-container" },
    .{ "{t} struct fields cannot be marked comptime", .@"bad-container" },
    .{ "expected {d} elements for destructure, found {d}", .@"bad-destructure" },
    .{ "type '{f}' cannot be destructured", .@"bad-destructure" },
    .{ "export target cannot be slice", .@"bad-export" },
    .{ "export target must be a global variable or a comptime-known constant", .@"bad-export" },
    .{ "compiler_rt file '{s}' not found", .@"bad-import" },
    .{ "compiler_rt has no function '{s}'", .@"bad-import" },
    .{ "embed of file outside package path: '{s}'", .@"bad-import" },
    .{ "file path name cannot be empty", .@"bad-import" },
    .{ "import of file outside module path: '{s}'", .@"bad-import" },
    .{ "no module named '{s}' available within module '{s}'", .@"bad-import" },
    .{ "std.lang.{s} requires the std module", .@"bad-import" },
    .{ "unable to find '{s}'", .@"bad-import" },
    .{ "unable to load compiler_rt file '{s}': {t}", .@"bad-import" },
    .{ "unable to open '{s}': {t}", .@"bad-import" },
    .{ "unable to resolve module directory '{s}': {t}", .@"bad-import" },
    .{ "comptime field without default initialization value", .@"bad-init" },
    .{ "duplicate field name '{s}'", .@"bad-init" },
    .{ "expected {d} array elements; found 0", .@"bad-init" },
    .{ "expected {d} array elements; found {d}", .@"bad-init" },
    .{ "expected {d} tuple elements; found {d}", .@"bad-init" },
    .{ "expected {d} vector elements; found 0", .@"bad-init" },
    .{ "expected {d} vector elements; found {d}", .@"bad-init" },
    .{ "missing field '{s}'", .@"bad-init" },
    .{ "missing struct field: {s}", .@"bad-init" },
    .{ "missing tuple field with index {d}", .@"bad-init" },
    .{ "type '{f}' does not support array initialization syntax", .@"bad-init" },
    .{ "type '{f}' does not support struct initialization syntax", .@"bad-init" },
    .{ "unexpected field '{f}'", .@"bad-init" },
    .{ "union initialization expects exactly one field", .@"bad-init" },
    .{ "value stored in comptime field does not match the default value of the field", .@"bad-init" },
    .{ "@atomicRmw with bool only allowed with .Xchg", .@"bad-operands" },
    .{ "@atomicRmw with enum only allowed with .Xchg", .@"bad-operands" },
    .{ "@atomicRmw with float only allowed with .Xchg, .Add, .Sub, .Max, and .Min", .@"bad-operands" },
    .{ "@byteSwap requires the number of bits to be evenly divisible by 8, but '{f}' has {d} bits", .@"bad-operands" },
    .{ "@reduce operation '{s}' requires integer or boolean operand; found '{f}'", .@"bad-operands" },
    .{ "@reduce operation requires a vector with nonzero length", .@"bad-operands" },
    .{ "bit shifting operation expected integer type, found '{f}'", .@"bad-operands" },
    .{ "comparison of union and enum literal is only valid for tagged union types", .@"bad-operands" },
    .{ "division with '{f}' and '{f}': signed integers must use @divTrunc, @divFloor, or @divExact", .@"bad-operands" },
    .{ "incompatible pointer arithmetic operands '{f}' and '{f}'", .@"bad-operands" },
    .{ "invalid operands to binary expression: '{f}' and '{f}'", .@"bad-operands" },
    .{ "invalid operands to binary expression: '{t}' and '{t}'", .@"bad-operands" },
    .{ "invalid pointer arithmetic operand: '{f}'", .@"bad-operands" },
    .{ "mixed scalar and vector operands: '{f}' and '{f}'", .@"bad-operands" },
    .{ "negation of type '{f}'", .@"bad-operands" },
    .{ "operator {s} not allowed for type '{f}'", .@"bad-operands" },
    .{ "operator {s} not allowed for types '{f}' and '{f}'", .@"bad-operands" },
    .{ "remainder division with '{f}' and '{f}': signed integers and floats must use @rem or @mod", .@"bad-operands" },
    .{ "shift by signed type '{f}'", .@"bad-operands" },
    .{ "unable to perform binary not operation on type '{f}'", .@"bad-operands" },
    .{ "function declared 'noreturn' implicitly returns", .@"bad-return" },
    .{ "'_' prong only allowed when switching on non-exhaustive enums", .@"bad-switch" },
    .{ "cannot capture tag of non-union type '{f}'", .@"bad-switch" },
    .{ "cannot enumerate values of type '{f}' for 'inline else'", .@"bad-switch" },
    .{ "switch on non-exhaustive enum must include 'else' or '_' prong", .@"bad-switch" },
    .{ "switch on type '{f}'", .@"bad-switch" },
    .{ "switch on union with no attached enum", .@"bad-switch" },
    .{ "alignment value '{d}' is not a power of two", .@"bad-type" },
    .{ "cannot reify pointer to '@TypeOf(null)'", .@"bad-type" },
    .{ "function pointers must be single pointers", .@"bad-type" },
    .{ "indexable pointer to opaque type '{f}' not allowed", .@"bad-type" },
    .{ "pointer to noreturn not allowed", .@"bad-type" },
    .{ "sentinels are only allowed on slices and unknown-length pointers", .@"bad-type" },
    .{ "type '{f}' is not available in ZON", .@"bad-type" },
    .{ "type '{f}' is not available in ZON: ZON does not allow mutable pointers", .@"bad-type" },
    .{ "type '{f}' not available in ZON", .@"bad-type" },
    .{ "{d} exceeds maximum integer bit count", .@"bad-type" },
    .{ "caught unexpected error 'error.{s}'", .@"caught-error" },
    .{ "{s}", .@"compile-error" },
    .{ "cannot copy comptime-only type '{f}' at runtime", .@"comptime-only" },
    .{ "cannot store comptime-only element '{f}' at runtime", .@"comptime-only" },
    .{ "inline assembly input of comptime-only type '{f}'", .@"comptime-only" },
    .{ "parameter of comptime-only type '{f}' must be declared comptime", .@"comptime-only" },
    .{ "unable to load comptime-only type '{f}' at runtime", .@"comptime-only" },
    .{ "variable of type '{f}' must be const or comptime", .@"comptime-only" },
    .{ "LHS of shift must be a fixed-width integer type, or RHS must be comptime-known", .@"comptime-required" },
    .{ "function called at runtime cannot return value at comptime", .@"comptime-required" },
    .{ "no offset available for comptime field", .@"comptime-required" },
    .{ "string must be comptime-known", .@"comptime-required" },
    .{ "tuple index must be comptime-known", .@"comptime-required" },
    .{ "unable to call variadic function at comptime", .@"comptime-required" },
    .{ "unable to cast runtime value to 'comptime_float'", .@"comptime-required" },
    .{ "unable to cast runtime value to 'comptime_int'", .@"comptime-required" },
    .{ "unable to evaluate comptime expression", .@"comptime-required" },
    .{ "unable to evaluate comptime expression: inline assembly", .@"comptime-required" },
    .{ "unable to evaluate comptime expression: memory is runtime-known", .@"comptime-required" },
    .{ "unable to evaluate comptime expression: pointer address is not known until link time", .@"comptime-required" },
    .{ "unable to evaluate comptime expression: zap resolves extern symbols at link time", .@"comptime-required" },
    .{ "unable to resolve comptime value", .@"comptime-required" },
    .{ "unable to resolve comptime value: argument to comptime parameter must be comptime-known", .@"comptime-required" },
    .{ "unable to resolve comptime value: default value must be comptime-known", .@"comptime-required" },
    .{ "unable to resolve comptime value: function pointer is not comptime-known", .@"comptime-required" },
    .{ "unable to resolve comptime value: tuple field default value must be comptime-known", .@"comptime-required" },
    .{ "unable to resolve comptime value: {s}", .@"comptime-required" },
    .{ "unable to store to this memory at comptime", .@"comptime-required" },
    .{ "values of type '{f}' must be comptime-known, but index value is runtime-known", .@"comptime-required" },
    .{ "vector index not comptime known", .@"comptime-required" },
    .{ "encountered @breakpoint at comptime", .@"comptime-trap" },
    .{ "encountered @panic at comptime", .@"comptime-trap" },
    .{ "encountered @trap at comptime", .@"comptime-trap" },
    .{ "assembly input contains reference to comptime var", .@"comptime-var-escape" },
    .{ "assembly output contains reference to comptime var", .@"comptime-var-escape" },
    .{ "comptime variable is not accessible here", .@"comptime-var-escape" },
    .{ "global variable contains reference to comptime var", .@"comptime-var-escape" },
    .{ "runtime value contains reference to comptime var", .@"comptime-var-escape" },
    .{ "dependency loop detected", .@"dependency-loop" },
    .{ "unable to resolve inferred error set", .@"dependency-loop" },
    .{ "division by zero here causes illegal behavior", .@"division-by-zero" },
    .{ "evaluation exceeded {d} backwards branches", .@"eval-limit" },
    .{ "inline call depth exceeded", .@"eval-limit" },
    .{ "error set of type '{f}' is ignored", .@"ignored-value" },
    .{ "error union of type '{f}' is ignored", .@"ignored-value" },
    .{ "error set is discarded", .@"ignored-value" },
    .{ "error union is discarded", .@"ignored-value" },
    .{ "error union payload is ignored", .@"ignored-value" },
    .{ "value of type '{f}' ignored", .@"ignored-value" },
    .{ "access of inactive union field '{s}'", .@"inactive-field" },
    .{ "access of union field '{s}' while field '{s}' is active", .@"inactive-field" },
    .{ "ambiguous coercion of division operands '{f}' and '{f}'; non-zero remainder '{f}'", .@"inexact-division" },
    .{ "exact division produced remainder", .@"inexact-division" },
    .{ "exact shift shifted out 1 bits", .@"integer-overflow" },
    .{ "overflow of integer type '{f}' with value '{f}'", .@"integer-overflow" },
    .{ "shift amount '{f}' is too large for operand type '{f}'", .@"integer-overflow" },
    .{ "shift by negative amount '{f}'", .@"integer-overflow" },
    .{ "expected vector of length '{d}', found '{f}'", .@"length-mismatch" },
    .{ "expected vector of length {d}, found '{f}'", .@"length-mismatch" },
    .{ "non-matching copy lengths", .@"length-mismatch" },
    .{ "non-matching for loop lengths", .@"length-mismatch" },
    .{ "vector length mismatch", .@"length-mismatch" },
    .{ "vector length mismatch: {d} and {d}", .@"length-mismatch" },
    .{ "enum '{f}' has no tag with value '{f}'", .@"lossy-conversion" },
    .{ "enumeration value '{f}' too large for type '{f}'", .@"lossy-conversion" },
    .{ "float value '{f}' cannot be stored in integer type '{f}'", .@"lossy-conversion" },
    .{ "float value Inf cannot be stored in integer type '{f}'", .@"lossy-conversion" },
    .{ "float value NaN cannot be stored in integer type '{f}'", .@"lossy-conversion" },
    .{ "fractional component prevents float value '{d}' from coercion to type '{f}'", .@"lossy-conversion" },
    .{ "fractional component prevents float value '{f}' from coercion to type '{f}'", .@"lossy-conversion" },
    .{ "integer value '{d}' represents no error", .@"lossy-conversion" },
    .{ "integer value out of range", .@"lossy-conversion" },
    .{ "no field with value '{f}' in enum '{f}'", .@"lossy-conversion" },
    .{ "type '{f}' cannot represent float value '{f}'", .@"lossy-conversion" },
    .{ "type '{f}' cannot represent integer value '{d}'", .@"lossy-conversion" },
    .{ "type '{f}' cannot represent integer value '{f}'", .@"lossy-conversion" },
    .{ "union '{f}' has no tag with value '{f}'", .@"lossy-conversion" },
    .{ "no field named '{s}' in enum '{f}'", .@"no-field" },
    .{ "no field named '{s}' in struct '{f}'", .@"no-field" },
    .{ "no field named '{s}' in tuple '{f}'", .@"no-field" },
    .{ "no field named '{s}' in union '{f}'", .@"no-field" },
    .{ "no field or member function named '{s}' in '{f}'", .@"no-field" },
    .{ "'error.{s}' not a member of error set '{f}'", .@"no-member" },
    .{ "'{f}' has no member named '{s}'", .@"no-member" },
    .{ "{s} '{f}' has no member named '{s}'", .@"no-member" },
    .{ "root source file struct '{f}' has no member named '{s}'", .@"no-member" },
    .{ "enum {f} has no member named '{f}'", .@"no-member" },
    .{ "no error named '{s}' in '{f}'", .@"no-member" },
    .{ "no member named '{s}' in '{f}'", .@"no-member" },
    .{ "type '{f}' has no member named '{s}'", .@"no-member" },
    .{ "NaN requires a known result type", .@"no-result-type" },
    .{ "infinity requires a known result type", .@"no-result-type" },
    .{ "negative infinity requires a known result type", .@"no-result-type" },
    .{ "unable to infer variable type", .@"no-result-type" },
    .{ "variable not accessible from inner function", .@"not-accessible" },
    .{ "'{s}' is not marked 'pub'", .@"not-pub" },
    .{ "null pointer casted to type '{f}'", .@"null-value" },
    .{ "unable to unwrap null", .@"null-value" },
    .{ "expected (optional) pointer", .@"operand-type" },
    .{ "expected a tuple, found '{f}'", .@"operand-type" },
    .{ "expected array or vector result type for @splat, found '{f}'", .@"operand-type" },
    .{ "expected bool, integer, enum, packed struct, or pointer type; found '{f}'", .@"operand-type" },
    .{ "expected bool, integer, float, enum, packed struct, or pointer type; found '{f}'", .@"operand-type" },
    .{ "expected calling convention, found '{f}'", .@"operand-type" },
    .{ "expected enum or packed type, found '{f}'", .@"operand-type" },
    .{ "expected enum or tagged union, found '{f}'", .@"operand-type" },
    .{ "expected enum or union; found '{f}'", .@"operand-type" },
    .{ "expected enum tag type, found '{f}'", .@"operand-type" },
    .{ "expected enum, found '{f}'", .@"operand-type" },
    .{ "expected enum, tagged union, packed union or packed struct, found '{f}'", .@"operand-type" },
    .{ "expected error set or error union type, found '{f}'", .@"operand-type" },
    .{ "expected error set type, found '{f}'", .@"operand-type" },
    .{ "expected error union type, found '{f}'", .@"operand-type" },
    .{ "expected float or vector type, found '{f}'", .@"operand-type" },
    .{ "expected float result type, found '{f}'", .@"operand-type" },
    .{ "expected float type, found '{f}'", .@"operand-type" },
    .{ "expected integer result type, found '{f}'", .@"operand-type" },
    .{ "expected integer tag type, found '{f}'", .@"operand-type" },
    .{ "expected integer type, found '{f}'", .@"operand-type" },
    .{ "expected integer, float, bool, or pointer for the vector element type; found '{f}'", .@"operand-type" },
    .{ "expected integer, float, or vector of either integers or floats, found '{f}'", .@"operand-type" },
    .{ "expected number, found '{f}'", .@"operand-type" },
    .{ "expected optional type, found '{f}'", .@"operand-type" },
    .{ "expected pointer type, found '{f}'", .@"operand-type" },
    .{ "expected pointer, found '{f}'", .@"operand-type" },
    .{ "expected single pointer type, found '{f}'", .@"operand-type" },
    .{ "expected single pointer, found '{f}'", .@"operand-type" },
    .{ "expected struct or union type, found '{f}'", .@"operand-type" },
    .{ "expected struct type, found '{f}'", .@"operand-type" },
    .{ "expected union type, found '{f}'", .@"operand-type" },
    .{ "expected vector of floats or float type, found '{f}'", .@"operand-type" },
    .{ "expected vector or array, found '{f}'", .@"operand-type" },
    .{ "expected vector, found '{f}'", .@"operand-type" },
    .{ "expected {t} integer type, found '{f}'", .@"operand-type" },
    .{ "type '{f}' does not support '@hasField'", .@"operand-type" },
    .{ "union '{f}' is untagged", .@"operand-type" },
    .{ "cannot index into empty vector", .@"out-of-bounds" },
    .{ "dereference of '{f}' exceeds bounds of containing decl of type '{f}'", .@"out-of-bounds" },
    .{ "index '{d}' out of bounds of tuple '{f}'", .@"out-of-bounds" },
    .{ "index {d} outside array of length {d}", .@"out-of-bounds" },
    .{ "index {d} outside tuple of length {d}", .@"out-of-bounds" },
    .{ "mask index '{d}' has out-of-bounds selection", .@"out-of-bounds" },
    .{ "start index {d} is larger than end index {d}", .@"out-of-bounds" },
    .{ "@src outside function", .@"outside-function" },
    .{ "function declared outside of a declaration", .@"outside-function" },
    .{ "reached unreachable code", .@"reached-unreachable" },
    .{ "sentinel-terminated slicing of many-item pointer must match existing sentinel", .@"sentinel-mismatch" },
    .{ "value in memory does not match slice sentinel", .@"sentinel-mismatch" },
    .{ "else prong required when switching on type '{f}'", .@"switch-incomplete" },
    .{ "switch must handle all possibilities", .@"switch-incomplete" },
    .{ "{s}: {s}", .syntax },
    .{ "{s}:{d}:{d}: {s}", .syntax },
    .{ "coercion from enum '{f}' to union '{f}' must initialize '{f}' field '{s}'", .@"type-mismatch" },
    .{ "expected array of '{f}', found '{f}'", .@"type-mismatch" },
    .{ "expected error, found payload", .@"type-mismatch" },
    .{ "expected type 'void'", .@"type-mismatch" },
    .{ "expected type '{f}'", .@"type-mismatch" },
    .{ "expected type '{f}', found '{f}'", .@"type-mismatch" },
    .{ "expected type '{f}', found pointer", .@"type-mismatch" },
    .{ "incompatible types: '{f}' and '{f}'", .@"type-mismatch" },
    .{ "payload types of error unions must match", .@"type-mismatch" },
    .{ "pointer element type '{f}' cannot coerce into element type '{f}'", .@"type-mismatch" },
    .{ "runtime coercion to union '{f}' from non-exhaustive enum", .@"type-mismatch" },
    .{ "unbounded for loop", .@"unbounded-for" },
    .{ "use of undeclared identifier '{s}'", .undeclared },
    .{ "undefined symbol: {s}", .@"undefined-symbol" },
    .{ "PC-relative reference to imported symbol {s}, which glibc defines; reach it through an extern slot (drop '.relocation = .pcrel')", .@"undefined-symbol" },
    .{ "cannot dereference slice with undefined length", .@"undefined-value" },
    .{ "cannot dereference undefined value", .@"undefined-value" },
    .{ "use of slice with undefined length here causes illegal behavior", .@"undefined-value" },
    .{ "use of undefined value here causes illegal behavior", .@"undefined-value" },
    .{ "cannot infer length of slice from '{f}'", .@"unknown-length" },
    .{ "unknown @memset length", .@"unknown-length" },
    .{ "unknown copy length", .@"unknown-length" },
    .{ "this compiler implementation only supports 'noalias' on the first 32 parameters", .unsupported },
});

/// The code of an AstGen message, by the upstream 0.17.0 format string it
/// was made from. Parse errors, which AstGen passes through as `{f}` or
/// `{s}`, match none and are `syntax`.
pub fn classifyAstGen(msg: []const u8) Code {
    for (astgen_codes) |entry| if (matchFormat(entry[0], msg)) return entry[1];
    return .syntax;
}

/// Whether `msg` could have been printed by format string `fmt`: its
/// literal parts in order, each `{...}` placeholder matching any text.
fn matchFormat(fmt: []const u8, msg: []const u8) bool {
    var rest = msg;
    var f = fmt;
    var first = true;
    while (true) {
        const open = std.mem.indexOfScalar(u8, f, '{') orelse {
            return if (first) std.mem.eql(u8, rest, f) else std.mem.endsWith(u8, rest, f);
        };
        const lit = f[0..open];
        if (first) {
            if (!std.mem.startsWith(u8, rest, lit)) return false;
            rest = rest[lit.len..];
        } else {
            const at = std.mem.indexOf(u8, rest, lit) orelse return false;
            rest = rest[at + lit.len ..];
        }
        const close = std.mem.indexOfScalarPos(u8, f, open, '}') orelse return false;
        f = f[close + 1 ..];
        first = false;
    }
}

/// Upstream 0.17.0 AstGen's error format strings and their codes, the
/// specific ones before the general ones they also match. The
/// "every AstGen error format has a code" test checks this list against
/// AstGen.zig itself.
const astgen_codes = [_]struct { []const u8, Code }{
    .{ "unused block label", .@"unused-label" },
    .{ "unused for loop label", .@"unused-label" },
    .{ "unused switch label", .@"unused-label" },
    .{ "unused while loop label", .@"unused-label" },
    .{ "unused {s}", .unused },
    .{ "pointless discard of {s}", .@"pointless-discard" },
    .{ "discard of capture; omit it instead", .@"pointless-discard" },
    .{ "discard of error capture; omit it instead", .@"pointless-discard" },
    .{ "discard of tag capture; omit it instead", .@"pointless-discard" },
    .{ "discard of unbounded counter", .@"pointless-discard" },
    .{ "local variable is never mutated", .@"never-mutated" },
    .{ "use of undeclared identifier '{s}'", .undeclared },
    .{ "declaration '{s}' shadows {s} from outer scope", .shadow },
    .{ "{s} '{s}' shadows {s} from outer scope", .shadow },
    .{ "{s} shadows declaration of '{s}'", .shadow },
    .{ "name shadows primitive '{s}'", .shadow },
    .{ "redeclaration of {s} '{s}'", .redeclared },
    .{ "duplicate {s} member name '{s}'", .redeclared },
    .{ "duplicate test name '{s}'", .redeclared },
    .{ "duplicate decltest '{s}'", .redeclared },
    .{ "redefinition of label '{s}'", .redeclared },
    .{ "ambiguous reference", .@"ambiguous-reference" },
    .{ "unreachable code", .@"unreachable-code" },
    .{ "invalid builtin function: '{s}'", .@"unknown-builtin" },
    .{ "expected {d} argument{s}, found {d}", .@"arg-count" },
    .{ "expected at least 1 argument, found 0", .@"arg-count" },
    .{ "expected at least 2 arguments, found {}", .@"arg-count" },
    .{ "base prefix must be lowercase", .@"bad-number" },
    .{ "duplicate exponent", .@"bad-number" },
    .{ "expected a digit after base prefix", .@"bad-number" },
    .{ "expected digit after '{c}'", .@"bad-number" },
    .{ "expected digit before '{c}'", .@"bad-number" },
    .{ "expected digit before digit separator", .@"bad-number" },
    .{ "expected digit before exponent", .@"bad-number" },
    .{ "invalid base for float literal", .@"bad-number" },
    .{ "invalid digit '{c}' for {s} base", .@"bad-number" },
    .{ "invalid digit '{c}' in exponent", .@"bad-number" },
    .{ "number '{s}' has leading zero", .@"bad-number" },
    .{ "repeated digit separator", .@"bad-number" },
    .{ "sign '{c}' cannot follow digit '{c}' in hex base", .@"bad-number" },
    .{ "trailing digit separator", .@"bad-number" },
    .{ "unexpected period after exponent", .@"bad-number" },
    .{ "'return' outside function scope", .@"outside-function" },
    .{ "'try' outside function scope", .@"outside-function" },
    .{ "'{s}' outside function scope", .@"outside-function" },
    .{ "mutable '{s}' not accessible from here", .@"not-accessible" },
    .{ "break expression outside loop", .@"bad-break" },
    .{ "continue expression outside loop", .@"bad-break" },
    .{ "continue outside of loop or labeled switch expression", .@"bad-break" },
    .{ "cannot continue loop with operand", .@"bad-break" },
    .{ "cannot continue switch without operand", .@"bad-break" },
    .{ "cannot continue with operand without label", .@"bad-break" },
    .{ "label not found: '{s}'", .@"bad-break" },
    .{ "cannot break out of defer expression", .@"control-in-defer" },
    .{ "cannot continue out of defer expression", .@"control-in-defer" },
    .{ "cannot return from defer expression", .@"control-in-defer" },
    .{ "'try' not allowed inside defer expression", .@"control-in-defer" },
    .{ "'comptime const' is redundant; instead wrap the initialization expression with 'comptime'", .redundant },
    .{ "'comptime var' is redundant in comptime scope", .redundant },
    .{ "redundant '@inComptime' in comptime scope", .redundant },
    .{ "redundant comptime keyword in already comptime scope", .redundant },
    .{ "redundant inline keyword in comptime scope", .redundant },
    .{ "redundant non-exhaustive enum mark", .redundant },
    .{ "redundant nosuspend block", .redundant },
    .{ "redundant {s}", .redundant },
    .{ "{s} must have a known result type", .@"no-result-type" },
    .{ "unable to infer array size", .@"no-result-type" },
    .{ "unable to infer variable type", .@"no-result-type" },
    .{ "variables must be initialized", .uninitialized },
    .{ "returning address of expired local variable '{s}'", .@"dangling-address" },
    .{ "invalid left-hand side to assignment", .@"bad-assignment" },
    .{ "unbounded for loop", .@"unbounded-for" },
    .{ "extra capture in for loop", .@"bad-capture" },
    .{ "for input is not captured", .@"bad-capture" },
    .{ "cannot capture reference to range", .@"bad-capture" },
    .{ "cannot capture tag of error union", .@"bad-capture" },
    .{ "error set cannot be captured by reference", .@"bad-capture" },
    .{ "cannot compare strings with {s}", .@"string-compare" },
    .{ "cannot switch on strings", .@"string-compare" },
    .{ "'_' field of non-exhaustive enum must be last", .@"bad-container" },
    .{ "'_' is used to mark an enum as non-exhaustive and cannot be assigned a value", .@"bad-container" },
    .{ "enum field missing name", .@"bad-container" },
    .{ "enum fields cannot be aligned", .@"bad-container" },
    .{ "enum fields cannot be marked comptime", .@"bad-container" },
    .{ "enum fields do not have types", .@"bad-container" },
    .{ "enums do not support 'packed' or 'extern'; instead provide an explicit integer tag type", .@"bad-container" },
    .{ "explicitly valued enum missing integer tag type", .@"bad-container" },
    .{ "non-exhaustive enum missing integer tag type", .@"bad-container" },
    .{ "opaque types cannot have fields", .@"bad-container" },
    .{ "opaque types do not support 'packed' or 'extern'", .@"bad-container" },
    .{ "struct field missing type", .@"bad-container" },
    .{ "comptime field without default initialization value", .@"bad-container" },
    .{ "non-comptime tuple field has default initialization value", .@"bad-container" },
    .{ "tuple does not support backing integer type", .@"bad-container" },
    .{ "tuple field has a name", .@"bad-container" },
    .{ "tuple field has alignment", .@"bad-container" },
    .{ "union field missing name", .@"bad-container" },
    .{ "union field missing type", .@"bad-container" },
    .{ "union fields cannot be marked comptime", .@"bad-container" },
    .{ "unable to override alignment of packed struct fields", .@"bad-container" },
    .{ "unable to override alignment of packed union fields", .@"bad-container" },
    .{ "{s} struct fields cannot be marked comptime", .@"bad-container" },
    .{ "{s} tuples are not supported", .@"bad-container" },
    .{ "{s} union does not support enum tag type", .@"bad-container" },
    .{ "file cannot be a tuple", .@"bad-container" },
    .{ "this compiler implementation only supports 65535 tuple fields", .@"bad-container" },
    .{ "function prototype may not have inferred error set", .@"bad-fn-type" },
    .{ "function type cannot have a linksection", .@"bad-fn-type" },
    .{ "function type cannot have a name", .@"bad-fn-type" },
    .{ "function type cannot have an addrspace", .@"bad-fn-type" },
    .{ "function type cannot have an alignment", .@"bad-fn-type" },
    .{ "function type cannot have an inferred error set", .@"bad-fn-type" },
    .{ "missing function name", .@"bad-fn-type" },
    .{ "missing parameter name", .@"bad-fn-type" },
    .{ "non-extern function has no body", .@"bad-fn-type" },
    .{ "this compiler implementation only supports 'noalias' on the first 32 parameters", .@"bad-fn-type" },
    .{ "assembly expression with no output must be marked volatile", .@"bad-asm" },
    .{ "global assembly cannot have inputs, outputs, or clobbers", .@"bad-asm" },
    .{ "inline assembly allows up to one output value", .@"bad-asm" },
    .{ "too many asm inputs", .@"bad-asm" },
    .{ "too many asm outputs", .@"bad-asm" },
    .{ "volatile is meaningless on global assembly", .@"bad-asm" },
    .{ "@import operand must be a string literal", .@"bad-import" },
    .{ "import path cannot be empty", .@"bad-import" },
    .{ "import path cannot contain null bytes", .@"bad-import" },
    .{ "library name cannot be empty", .@"bad-name" },
    .{ "library name cannot contain null bytes", .@"bad-name" },
    .{ "identifier cannot be empty", .@"bad-name" },
    .{ "identifier cannot contain null bytes", .@"bad-name" },
    .{ "test name cannot contain null bytes", .@"bad-name" },
    .{ "empty test name must be omitted", .@"bad-name" },
    .{ "'_' used as an identifier without @\"_\" syntax", .@"bad-name" },
    .{ "empty initializer cannot be destructured", .@"bad-destructure" },
    .{ "expected {} elements for destructure, found {}", .@"bad-destructure" },
    .{ "struct value cannot be destructured", .@"bad-destructure" },
    .{ "cannot set address space of local variable '{s}'", .@"bad-var-decl" },
    .{ "cannot set section of local variable '{s}'", .@"bad-var-decl" },
    .{ "threadlocal variable cannot be constant", .@"bad-var-decl" },
    .{ "C pointers always allow address zero", .@"bad-pointer-type" },
    .{ "Extra pointer qualifier", .@"bad-pointer-type" },
    .{ "pointer modifier invalid on discard", .@"bad-pointer-type" },
    .{ "signed integer cannot have bit width 0", .@"bad-int-type" },
    .{ "'@branchHint' must appear as the first statement in a function or conditional branch", .@"misplaced-builtin" },
    .{ "'@cVaStart' in a non-variadic function", .@"misplaced-builtin" },
    .{ "cannot suspend inside suspend block", .@"bad-suspend" },
    .{ "suspend inside nosuspend block", .@"bad-suspend" },
    .{ "cannot test a primitive", .@"bad-decltest" },
    .{ "cannot test a {s}", .@"bad-decltest" },
    .{ "cannot inline '_' prong", .@"bad-switch" },
    .{ "'_' prong is not allowed when switching on errors", .@"bad-switch" },
    .{ "multiple '_' prongs in switch expression", .@"bad-switch" },
    .{ "multiple else prongs in switch expression", .@"bad-switch" },
    .{ "duplicate error set field '{s}'", .redeclared },
    .{ "duplicate struct field name", .redeclared },
    .{ "explicit callconv incompatible with inline keyword", .@"bad-fn-type" },
    .{ "missing parameter name or type", .@"bad-fn-type" },
    .{ "explicitly valued tagged union missing integer tag type", .@"bad-container" },
    .{ "explicitly valued tagged union requires inferred enum tag type", .@"bad-container" },
    .{ "non-packed struct does not support backing integer type", .@"bad-container" },
    .{ "this compiler implementation only supports up to 65536 captures per namespace", .@"bad-container" },
    .{ "tuple declarations cannot contain declarations", .@"bad-container" },
    .{ "extern variables have no initializers", .@"bad-var-decl" },
    .{ "initializing array with struct syntax", .@"bad-init" },
    .{ "integer literal '-0' is ambiguous", .@"bad-number" },
    .{ "primitive integer type '{s}' exceeds maximum bit width of 65535", .@"bad-int-type" },
    .{ "primitive integer type '{s}' has leading zero", .@"bad-int-type" },
};

test matchFormat {
    try std.testing.expect(matchFormat("unused {s}", "unused local constant"));
    try std.testing.expect(!matchFormat("unused {s}", "unused"));
    try std.testing.expect(matchFormat("expected {d} argument{s}, found {d}", "expected 2 arguments, found 1"));
    try std.testing.expect(matchFormat("{s} '{s}' shadows {s} from outer scope", "capture 'x' shadows local constant from outer scope"));
    try std.testing.expect(!matchFormat("unused block label", "unused block label x"));
    try std.testing.expectEqual(Code.@"unused-label", classifyAstGen("unused while loop label"));
    try std.testing.expectEqual(Code.syntax, classifyAstGen("expected ';' after statement"));
}

test "every AstGen error format has a code" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const path = try std.fs.path.join(gpa, &.{ @import("build_options").zig_lib_dir, "std", "zig", "AstGen.zig" });
    defer gpa.free(path);
    const src = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20));
    defer gpa.free(src);
    // The first string literal of every `fail*(` and `appendError*(` call
    // is an error's format string.
    var checked: usize = 0;
    var missing: usize = 0;
    for ([_][]const u8{ "fail", "appendError" }) |prefix| {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, src, i, prefix)) |at| : (i = at + prefix.len) {
            if (at > 0 and (std.ascii.isAlphanumeric(src[at - 1]) or src[at - 1] == '_' or src[at - 1] == '"')) continue;
            var name_end = at + prefix.len;
            while (std.ascii.isAlphanumeric(src[name_end])) name_end += 1;
            if (src[name_end] != '(') continue;
            const stmt_end = std.mem.indexOfScalarPos(u8, src, name_end, ';') orelse break;
            const q = std.mem.indexOfScalarPos(u8, src[0..stmt_end], name_end, '"') orelse continue;
            var e = q + 1;
            while (src[e] != '"') : (e += 1) {
                if (src[e] == '\\') e += 1;
            }
            const fmt = try std.zig.string_literal.parseAlloc(gpa, src[q .. e + 1]);
            defer gpa.free(fmt);
            checked += 1;
            // Parse errors pass through as `{f}` or `{s}`: `syntax`.
            if (std.mem.eql(u8, fmt, "{f}") or std.mem.eql(u8, fmt, "{s}")) continue;
            if (classifyAstGen(fmt) == .syntax) {
                std.debug.print("AstGen format without a code: \"{s}\"\n", .{fmt});
                missing += 1;
            }
        }
    }
    try std.testing.expectEqual(0, missing);
    try std.testing.expect(checked > 150);
}

test "every Sema, linker and backend error format has a code" {
    const gpa = std.testing.allocator;
    // The first string literal of every `.fail(` and `.addError(` call is
    // an error's format string (`failCode` and `addErrorCode` name theirs).
    var checked: usize = 0;
    var missing: usize = 0;
    inline for (.{ "Sema.zig", "Zcu.zig", "Emit.zig" }) |name| {
        const src: [:0]const u8 = @embedFile(name);
        var tokens: std.ArrayList(std.zig.Token) = .empty;
        defer tokens.deinit(gpa);
        var it: std.zig.Tokenizer = .init(src);
        while (true) {
            const t = it.next();
            if (t.tag == .eof) break;
            try tokens.append(gpa, t);
        }
        const toks = tokens.items;
        for (toks[0 .. toks.len - 2], 0..) |t, i| {
            if (t.tag != .period or toks[i + 1].tag != .identifier or toks[i + 2].tag != .l_paren) continue;
            const callee = src[toks[i + 1].loc.start..toks[i + 1].loc.end];
            if (!std.mem.eql(u8, callee, "fail") and !std.mem.eql(u8, callee, "addError")) continue;
            var depth: usize = 0;
            const fmt_tok = for (toks[i + 2 ..]) |a| switch (a.tag) {
                .l_paren, .l_brace, .l_bracket => depth += 1,
                .r_paren, .r_brace, .r_bracket => {
                    depth -= 1;
                    if (depth == 0) break null;
                },
                .string_literal => if (depth == 1) break a,
                else => {},
            } else null;
            const lit = fmt_tok orelse continue;
            const fmt = try std.zig.string_literal.parseAlloc(gpa, src[lit.loc.start..lit.loc.end]);
            defer gpa.free(fmt);
            checked += 1;
            if (formatCode(fmt) == .unclassified) {
                std.debug.print("{s}: error format without a code: \"{s}\"\n", .{ name, fmt });
                missing += 1;
            }
        }
    }
    try std.testing.expectEqual(0, missing);
    try std.testing.expect(checked > 400);
}
