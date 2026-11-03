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
};

/// A frame of the reference trace: unit `name` referred onward at `loc`.
pub const Ref = struct { name: []const u8, loc: ?Loc };

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
        if (n.decl) if (n.loc) |l| if (sourceExcerpt(l)) |src| try w.print(": {s}", .{src});
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
        .calls = if (n_calls != 0) calls_buf[0..n_calls] else null,
        .ref = if (n_refs != 0) refs_buf[0..n_refs] else null,
    };
    try std.json.Stringify.value(obj, .{ .emit_null_optional_fields = false }, w);
    try w.writeByte('\n');
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
    .{ "error set is ignored", .@"ignored-value" },
    .{ "error union is ignored", .@"ignored-value" },
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
    .{ "enum '{f}' has no field named '{s}'", .@"no-field" },
    .{ "no field named '{s}' in enum '{f}'", .@"no-field" },
    .{ "no field named '{s}' in struct '{f}'", .@"no-field" },
    .{ "no field named '{s}' in tuple '{f}'", .@"no-field" },
    .{ "no field named '{s}' in union '{f}'", .@"no-field" },
    .{ "no field or member function named '{s}' in '{f}'", .@"no-field" },
    .{ "'error.{s}' not a member of error set '{f}'", .@"no-member" },
    .{ "'{f}' has no member named '{s}'", .@"no-member" },
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
