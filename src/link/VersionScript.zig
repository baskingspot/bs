//! An ld version script (`--version-script`), as lld reads it: version
//! nodes (`NAME { global: ...; local: ...; } PARENT;`) or one anonymous
//! node (`{ ... };`), whose patterns name a shared object's exports or
//! match them with shell wildcards (`*`, `?`, `[...]`). A quoted pattern
//! is a name. `extern "C"` blocks are plain patterns; `extern "C++"`
//! needs demangling and is refused. Parents are read and ignored, as lld
//! ignores them (its .gnu.version_d has no parent entries).
//!
//! `assign` gives each export its version as lld's `scanVersionScript`
//! does: exact names first, in node order, the first assignment winning;
//! then wildcards other than `*`, later nodes first; then `*`, later nodes
//! first. What nothing matches stays global and unversioned.

const std = @import("std");
const Allocator = std.mem.Allocator;
const VersionScript = @This();

/// The script's file, for messages.
path: []const u8,
source: []const u8,
/// The named nodes in order, or one anonymous node (name "").
nodes: []const Node,
/// The place of each exact (not wildcard) pattern's name: the first
/// node's to list it, its globals before its locals.
exact: std.StringHashMapUnmanaged(u16),

pub const Node = struct {
    name: []const u8,
    globals: []const Pattern,
    locals: []const Pattern,
};

pub const Pattern = struct {
    text: []const u8,
    /// Has wildcards: unquoted, with `*`, `?` or `[`.
    wildcard: bool,
    /// Byte offset in the source, for messages.
    offset: u32,
};

/// Where the script is wrong, and how.
pub const Error = struct { offset: u32, msg: []const u8 };

/// An export's place after `assign`: local (not exported), global
/// unversioned, or `named + i` for node `i` of a script with named nodes,
/// as their .gnu.version indices.
pub const local: u16 = 0;
pub const global: u16 = 1;
pub const named: u16 = 2;

/// The named nodes' names, for .gnu.version_d (none for an anonymous
/// node).
pub fn names(vs: *const VersionScript, arena: Allocator) Allocator.Error![]const []const u8 {
    if (vs.nodes.len == 1 and vs.nodes[0].name.len == 0) return &.{};
    const out = try arena.alloc([]const u8, vs.nodes.len);
    for (out, vs.nodes) |*n, node| n.* = node.name;
    return out;
}

pub fn parse(arena: Allocator, path: []const u8, source: []const u8) Allocator.Error!union(enum) { ok: VersionScript, err: Error } {
    var p: Parser = .{ .src = source };
    var nodes: std.ArrayList(Node) = .empty;
    while (true) {
        const tok = p.next() orelse break;
        if (tok.err) |msg| return .{ .err = .{ .offset = tok.offset, .msg = msg } };
        const anonymous = std.mem.eql(u8, tok.text, "{");
        if (anonymous and nodes.items.len != 0 or !anonymous and nodes.items.len == 1 and nodes.items[0].name.len == 0)
            return .{ .err = .{ .offset = tok.offset, .msg = "an anonymous version node must be the script's only node" } };
        if (!anonymous) {
            if (tok.quoted or isPunct(tok.text)) return .{ .err = .{ .offset = tok.offset, .msg = try std.fmt.allocPrint(arena, "expected a version node name or '{{', found '{s}'", .{tok.text}) } };
            for (nodes.items) |n| if (std.mem.eql(u8, n.name, tok.text))
                return .{ .err = .{ .offset = tok.offset, .msg = try std.fmt.allocPrint(arena, "version node '{s}' is defined twice", .{tok.text}) } };
            if (p.expect("{")) |e| return .{ .err = e };
        }
        var globals: std.ArrayList(Pattern) = .empty;
        var locals: std.ArrayList(Pattern) = .empty;
        if (try p.body(arena, &globals, &locals)) |e| return .{ .err = e };
        // `}` read; then parents, and `;`.
        while (true) {
            const t = p.next() orelse return .{ .err = .{ .offset = @intCast(source.len), .msg = "expected ';' after the version node" } };
            if (t.err) |msg| return .{ .err = .{ .offset = t.offset, .msg = msg } };
            if (std.mem.eql(u8, t.text, ";") and !t.quoted) break;
            if (anonymous or t.quoted or isPunct(t.text)) return .{ .err = .{ .offset = t.offset, .msg = try std.fmt.allocPrint(arena, "expected ';' after the version node, found '{s}'", .{t.text}) } };
        }
        try nodes.append(arena, .{ .name = if (anonymous) "" else tok.text, .globals = globals.items, .locals = locals.items });
    }
    var vs: VersionScript = .{ .path = path, .source = source, .nodes = nodes.items, .exact = .empty };
    for (vs.nodes, 0..) |node, n| {
        for ([_][]const Pattern{ node.globals, node.locals }, [_]u16{ vs.nodeId(n), local }) |pats, v| for (pats) |pat| {
            if (!pat.wildcard) _ = try vs.exact.getOrPutValue(arena, pat.text, v);
        };
    }
    return .{ .ok = vs };
}

fn nodeId(vs: *const VersionScript, n: usize) u16 {
    return if (vs.nodes.len == 1 and vs.nodes[0].name.len == 0) global else named + @as(u16, @intCast(n));
}

/// The place of export `name`: `local`, `global`, or `named + i`.
pub fn place(vs: *const VersionScript, name: []const u8) u16 {
    if (vs.exact.get(name)) |v| return v;
    for ([_]bool{ false, true }) |asterisk| {
        var n = vs.nodes.len;
        while (n > 0) {
            n -= 1;
            const node = vs.nodes[n];
            for ([_][]const Pattern{ node.globals, node.locals }, [_]u16{ vs.nodeId(n), local }) |pats, v| for (pats) |pat| {
                if (pat.wildcard and std.mem.eql(u8, pat.text, "*") == asterisk and glob(pat.text, name)) return v;
            };
        }
    }
    return global;
}

/// Assigns `exports` their places (`place`) in `out`. Returns the exact
/// patterns that name neither an export nor one of `also_defined` (names
/// defined but not exported), which lld refuses without
/// `--undefined-version`.
pub fn assign(vs: *const VersionScript, arena: Allocator, exports: []const []const u8, also_defined: []const []const u8, out: []u16) Allocator.Error![]const Pattern {
    var defined: std.StringHashMapUnmanaged(void) = .empty;
    try defined.ensureTotalCapacity(arena, @intCast(exports.len + also_defined.len));
    for ([_][]const []const u8{ exports, also_defined }) |list| for (list) |name| defined.putAssumeCapacity(name, {});
    for (exports, out) |name, *v| v.* = vs.place(name);
    var unmatched: std.ArrayList(Pattern) = .empty;
    for (vs.nodes) |node| for ([_][]const Pattern{ node.globals, node.locals }) |pats| for (pats) |pat| {
        if (!pat.wildcard and !defined.contains(pat.text)) try unmatched.append(arena, pat);
    };
    return unmatched.items;
}

/// Whether `name` matches shell pattern `pat`: `*` any run, `?` any byte,
/// `[...]` a set (ranges, `!` or `^` to negate), `\` escaping the next.
pub fn glob(pat: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    // Where to resume after the last `*`: its pattern position and the
    // name position it now covers up to.
    var star: ?struct { p: usize, n: usize } = null;
    while (n < name.len) {
        if (p < pat.len) switch (pat[p]) {
            '*' => {
                star = .{ .p = p + 1, .n = n };
                p += 1;
                continue;
            },
            '?' => {
                p += 1;
                n += 1;
                continue;
            },
            '[' => if (matchSet(pat[p..], name[n])) |len| {
                if (len.matched) {
                    p += len.len;
                    n += 1;
                    continue;
                }
            } else if (name[n] == '[') {
                p += 1;
                n += 1;
                continue;
            },
            '\\' => if (p + 1 < pat.len and pat[p + 1] == name[n]) {
                p += 2;
                n += 1;
                continue;
            },
            else => |c| if (c == name[n]) {
                p += 1;
                n += 1;
                continue;
            },
        };
        const s = star orelse return false;
        star = .{ .p = s.p, .n = s.n + 1 };
        p = s.p;
        n = s.n + 1;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

/// The set at the start of `pat` (`[...]`) against `c`: its length and
/// whether `c` is in it, or null if it does not close.
fn matchSet(pat: []const u8, c: u8) ?struct { len: usize, matched: bool } {
    var i: usize = 1;
    const negate = i < pat.len and (pat[i] == '!' or pat[i] == '^');
    if (negate) i += 1;
    var in = false;
    var first = true;
    while (i < pat.len) : (first = false) {
        if (pat[i] == ']' and !first) return .{ .len = i + 1, .matched = in != negate };
        const lo = pat[i];
        if (i + 2 < pat.len and pat[i + 1] == '-' and pat[i + 2] != ']') {
            in = in or (c >= lo and c <= pat[i + 2]);
            i += 3;
        } else {
            in = in or c == lo;
            i += 1;
        }
    }
    return null;
}

fn isPunct(t: []const u8) bool {
    return t.len == 1 and std.mem.indexOfScalar(u8, "{};:", t[0]) != null;
}

const Parser = struct {
    src: []const u8,
    at: usize = 0,

    const Token = struct { text: []const u8, offset: u32, quoted: bool = false, err: ?[]const u8 = null };

    fn next(p: *Parser) ?Token {
        const s = p.src;
        while (p.at < s.len) {
            const c = s[p.at];
            if (std.ascii.isWhitespace(c)) {
                p.at += 1;
            } else if (c == '#') {
                while (p.at < s.len and s[p.at] != '\n') p.at += 1;
            } else if (c == '/' and p.at + 1 < s.len and s[p.at + 1] == '*') {
                const end = std.mem.indexOfPos(u8, s, p.at + 2, "*/") orelse {
                    const at = p.at;
                    p.at = s.len;
                    return .{ .text = "", .offset = @intCast(at), .err = "unterminated comment" };
                };
                p.at = end + 2;
            } else break;
        }
        if (p.at >= s.len) return null;
        const start = p.at;
        if (s[start] == '"') {
            const end = std.mem.indexOfScalarPos(u8, s, start + 1, '"') orelse {
                p.at = s.len;
                return .{ .text = "", .offset = @intCast(start), .err = "unterminated quoted pattern" };
            };
            p.at = end + 1;
            return .{ .text = s[start + 1 .. end], .offset = @intCast(start), .quoted = true };
        }
        if (isPunct(s[start .. start + 1])) {
            p.at += 1;
            return .{ .text = s[start .. start + 1], .offset = @intCast(start) };
        }
        while (p.at < s.len and !std.ascii.isWhitespace(s[p.at]) and std.mem.indexOfScalar(u8, "{};:\"", s[p.at]) == null and
            !(s[p.at] == '/' and p.at + 1 < s.len and s[p.at + 1] == '*')) p.at += 1;
        return .{ .text = s[start..p.at], .offset = @intCast(start) };
    }

    fn expect(p: *Parser, want: []const u8) ?Error {
        const t = p.next() orelse return .{ .offset = @intCast(p.src.len), .msg = if (want[0] == '{') "expected '{' after the version node name" else "expected ';'" };
        if (t.err) |msg| return .{ .offset = t.offset, .msg = msg };
        if (t.quoted or !std.mem.eql(u8, t.text, want)) return .{ .offset = t.offset, .msg = if (want[0] == '{') "expected '{' after the version node name" else "expected ';'" };
        return null;
    }

    /// A node's or an `extern` block's patterns, through its `}`.
    fn body(p: *Parser, arena: Allocator, globals: *std.ArrayList(Pattern), locals: *std.ArrayList(Pattern)) Allocator.Error!?Error {
        var into = globals;
        while (true) {
            const t = p.next() orelse return .{ .offset = @intCast(p.src.len), .msg = "expected '}' to close the version node" };
            if (t.err) |msg| return .{ .offset = t.offset, .msg = msg };
            if (!t.quoted) {
                if (std.mem.eql(u8, t.text, "}")) return null;
                if (std.mem.eql(u8, t.text, "global") or std.mem.eql(u8, t.text, "local")) {
                    const save = p.at;
                    if (p.next()) |colon| if (!colon.quoted and std.mem.eql(u8, colon.text, ":")) {
                        into = if (t.text[0] == 'g') globals else locals;
                        continue;
                    };
                    p.at = save;
                } else if (std.mem.eql(u8, t.text, "extern")) {
                    const lang = p.next() orelse return .{ .offset = t.offset, .msg = "expected a language after 'extern'" };
                    if (!lang.quoted) return .{ .offset = lang.offset, .msg = "expected a quoted language after 'extern', such as \"C\"" };
                    if (!std.mem.eql(u8, lang.text, "C"))
                        return .{ .offset = lang.offset, .msg = try std.fmt.allocPrint(arena, "bs does not support extern \"{s}\" blocks in version scripts, which need demangled names; list the mangled names instead", .{lang.text}) };
                    if (p.expect("{")) |e| return e;
                    // The block's patterns go where its node's are.
                    const block = if (into == globals) try p.body(arena, globals, globals) else try p.body(arena, locals, locals);
                    if (block) |e| return e;
                    if (p.expect(";")) |e| return e;
                    continue;
                } else if (isPunct(t.text)) {
                    return .{ .offset = t.offset, .msg = try std.fmt.allocPrint(arena, "expected a symbol pattern, found '{s}'", .{t.text}) };
                }
            }
            const wildcard = !t.quoted and std.mem.indexOfAny(u8, t.text, "*?[") != null;
            try into.append(arena, .{ .text = t.text, .wildcard = wildcard, .offset = t.offset });
            // A pattern ends at `;`, or at the `}` closing an `extern`
            // block, as in lld.
            const save = p.at;
            const end = p.next() orelse return .{ .offset = @intCast(p.src.len), .msg = "expected ';' after the symbol pattern" };
            if (end.err) |msg| return .{ .offset = end.offset, .msg = msg };
            if (end.quoted or !std.mem.eql(u8, end.text, ";")) {
                if (!end.quoted and std.mem.eql(u8, end.text, "}") and globals == locals) {
                    p.at = save;
                    continue;
                }
                return .{ .offset = end.offset, .msg = try std.fmt.allocPrint(arena, "expected ';' after the symbol pattern '{s}'", .{t.text}) };
            }
        }
    }
};

test "versions as lld assigns them: exact names, then wildcards by later node, then '*'" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\/* siv's shape, plus the cases that order decides. */
        \\V_1.0 {
        \\  global:
        \\    a_old;      # exact beats V_1.1's a_*
        \\    "b_*";      # quoted: the name b_*, not a wildcard
        \\    e_*;        # V_1.1's e_[0-9]* wins where both match
        \\  local:
        \\    *;
        \\    hide_*;
        \\};
        \\V_1.1 {
        \\  global: a_*; c?; extern "C" { d_exact; e_[0-9]* };
        \\} V_1.0;
    ;
    const vs = switch (try parse(arena, "t.map", src)) {
        .ok => |v| v,
        .err => |e| return std.debug.panic("{d}: {s}", .{ e.offset, e.msg }),
    };
    const node_names = try vs.names(arena);
    try std.testing.expectEqual(2, node_names.len);
    try std.testing.expectEqualStrings("V_1.0", node_names[0]);
    try std.testing.expectEqualStrings("V_1.1", node_names[1]);
    const exports = [_][]const u8{ "a_old", "a_new", "b_*", "b_x", "c1", "c12", "hide_me", "d_exact", "e_7z", "e_x", "other" };
    var out: [exports.len]u16 = undefined;
    const unmatched = try vs.assign(arena, &exports, &.{}, &out);
    const v0 = named;
    const v1 = named + 1;
    // a_old: exact in V_1.0 though V_1.1's a_* matches; b_x: only '*'
    // (local); c12: '?' is one byte; hide_me: hide_* (local) beats '*'
    // only by order, both local; e_7z: the later node's wildcard; e_x:
    // only V_1.0's.
    try std.testing.expectEqualSlices(u16, &.{ v0, v1, v0, local, v1, local, local, v1, v1, v0, local }, &out);
    try std.testing.expectEqual(0, unmatched.len);

    // An exact name nothing defines is reported; a wildcard is not.
    const few = [_][]const u8{"a_new"};
    var few_out: [1]u16 = undefined;
    const missing = try vs.assign(arena, &few, &.{"b_*"}, &few_out);
    try std.testing.expectEqual(2, missing.len);
    try std.testing.expectEqualStrings("a_old", missing[0].text);
    try std.testing.expectEqualStrings("a_old;", src[missing[0].offset..][0..6]);
}

test "an anonymous node only sets visibility, and wildcard sets" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const vs = (try parse(arena, "t.map", "{ global: siv_webview_*; [!x]y?; local: *; };")).ok;
    try std.testing.expectEqual(0, (try vs.names(arena)).len);
    const exports = [_][]const u8{ "siv_webview_new", "ay1", "xy1", "siv_other" };
    var out: [exports.len]u16 = undefined;
    _ = try vs.assign(arena, &exports, &.{}, &out);
    try std.testing.expectEqualSlices(u16, &.{ global, global, local, local }, &out);
    try std.testing.expect(glob("a\\*b", "a*b") and !glob("a\\*b", "axb"));
    try std.testing.expect(glob("[a-c]*[!z]", "b-y") and !glob("[a-c]*[!z]", "d-y") and !glob("[a-c]*[!z]", "b-z"));
    try std.testing.expect(glob("*a*a", "banana") and !glob("*a*a", "bananas"));
}

test "a malformed script fails at the offending token" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]struct { []const u8, []const u8, []const u8 }{
        .{ "V { global: f g; };", "g", "expected ';' after the symbol pattern 'f'" },
        .{ "V { global: f; }", "", "expected ';' after the version node" },
        .{ "{ f; }; W { g; };", "W", "an anonymous version node must be the script's only node" },
        .{ "V { extern \"C++\" { ns::f; }; };", "\"C++\"", "bs does not support extern \"C++\" blocks in version scripts, which need demangled names; list the mangled names instead" },
        .{ "V { f; }; V { g; };", "V {", "version node 'V' is defined twice" },
    }) |case| {
        const src, const at, const msg = case;
        const e = (try parse(arena, "t.map", src)).err;
        try std.testing.expectEqualStrings(msg, e.msg);
        try std.testing.expectEqual(if (at.len == 0) src.len else std.mem.lastIndexOf(u8, src, at).?, e.offset);
    }
}
