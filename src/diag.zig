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
};

/// A location, resolved for rendering.
pub const Loc = struct {
    /// As displayed: relative to the working directory, or to the zig lib
    /// directory for files under it (`std/start.zig`).
    path: []const u8,
    /// 1-based line and byte column, as upstream.
    line: u32,
    col: u32,
    /// Byte offsets of the span in the file, end exclusive.
    start: u32,
    end: u32,
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
};

pub const CallKind = enum { @"inline", @"comptime" };

pub const Diagnostic = struct {
    code: Code = .unclassified,
    loc: ?Loc,
    msg: []const u8,
    /// Identical messages counted together (ErrorBundle's `count`).
    count: u32 = 1,
    notes: []const Note = &.{},
};

pub const Format = enum { text, json };

/// Turns raw file paths into displayed ones (`Loc.path`, `Loc.in_lib`).
pub const Paths = struct {
    /// Absolute and resolved.
    lib_dir: []const u8,
    cwd: []const u8,

    pub fn init(arena: std.mem.Allocator, io: std.Io, zig_lib_dir: []const u8) !Paths {
        const cwd = try std.process.currentPathAlloc(io, arena);
        return .{ .lib_dir = try std.fs.path.resolve(arena, &.{ cwd, zig_lib_dir }), .cwd = cwd };
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
            .source_line = lc.source_line,
            .in_lib = in_lib or force_lib,
        };
    }
};

/// Appends the messages of an ErrorBundle (AstGen and parse errors) as
/// diagnostics, classifying each message's code.
pub fn fromBundle(arena: std.mem.Allocator, paths: Paths, bundle: std.zig.ErrorBundle, out: *std.ArrayList(Diagnostic)) !void {
    for (bundle.getMessages()) |idx| {
        const m = bundle.getErrorMessage(idx);
        const notes = try arena.alloc(Note, m.notes_len);
        for (notes, bundle.getNotes(idx)) |*n, ni| {
            const nm = bundle.getErrorMessage(ni);
            n.* = .{ .loc = try bundleLoc(arena, paths, bundle, nm.src_loc), .msg = bundle.nullTerminatedString(nm.msg), .count = nm.count };
        }
        const msg = bundle.nullTerminatedString(m.msg);
        try out.append(arena, .{ .code = classifyAstGen(msg), .loc = try bundleLoc(arena, paths, bundle, m.src_loc), .msg = msg, .count = m.count, .notes = notes });
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
        .source_line = if (sl.source_line != 0) bundle.nullTerminatedString(sl.source_line) else "",
        .in_lib = in_lib,
    };
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
        try w.writeByte('\n');
    }
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
    const JsonNote = struct { file: ?[]const u8 = null, line: ?u32 = null, col: ?u32 = null, span: ?[2]u32 = null, msg: []const u8, count: ?u32 = null };
    const JsonCall = struct { file: []const u8, line: u32, col: u32, kind: CallKind, count: ?u32 = null };
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
            }
            n_notes += 1;
        }
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
        calls: ?[]const JsonCall,
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
        .calls = if (n_calls != 0) calls_buf[0..n_calls] else null,
    };
    try std.json.Stringify.value(obj, .{ .emit_null_optional_fields = false }, w);
    try w.writeByte('\n');
}

// ---------------------------------------------------------------------------
// AstGen codes

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
