//! edithunt's view of a Zig source file, from std.zig.Ast, for hunt.py's
//! edits. Byte offsets throughout.
//!
//!   scan FILE             JSON: the file's declarations, containers,
//!                         error sets and the literals in function bodies
//!   rename FILE OLD NEW   FILE with every use of the declaration OLD
//!                         renamed, `.OLD` member accesses included, on
//!                         stdout; exit 2 if OLD also names a field
const std = @import("std");
const Io = std.Io;
const Ast = std.zig.Ast;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) return error.Usage;
    const bytes = try Io.Dir.cwd().readFileAlloc(io, args[2], arena, .unlimited);
    const source = try arena.dupeSentinel(u8, bytes, 0);
    var tree = try Ast.parse(arena, source, .{});
    var out_buf: [1 << 16]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &out.interface;
    if (std.mem.eql(u8, args[1], "rename")) {
        if (args.len != 5) return error.Usage;
        if (!try rename(&tree, w, args[3], args[4])) std.process.exit(2);
    } else if (std.mem.eql(u8, args[1], "scan")) {
        try scan(arena, &tree, w);
    } else return error.Usage;
    try w.flush();
}

fn rename(tree: *const Ast, w: *Io.Writer, old: []const u8, new: []const u8) !bool {
    const n_tokens: Ast.TokenIndex = @intCast(tree.tokens.len);
    // A field of that name would be renamed with it. A `.old` member
    // access is renamed: a method call of the declaration, most likely.
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (tree.fullContainerField(node)) |f| if (std.mem.eql(u8, tree.tokenSlice(f.ast.main_token), old)) return false;
    }
    var pos: usize = 0;
    for (0..n_tokens) |t| {
        const tok: Ast.TokenIndex = @intCast(t);
        if (tree.tokenTag(tok) != .identifier or !std.mem.eql(u8, tree.tokenSlice(tok), old)) continue;
        const start = tree.tokenStart(tok);
        try w.writeAll(tree.source[pos..start]);
        try w.writeAll(new);
        pos = start + old.len;
    }
    try w.writeAll(tree.source[pos..]);
    return true;
}

const Body = struct { start: u32, end: u32, generic: bool, name: []const u8 };

fn scan(arena: std.mem.Allocator, tree: *const Ast, w: *Io.Writer) !void {
    var s: std.json.Stringify = .{ .writer = w };
    const src = tree.source;
    var bodies: std.ArrayList(Body) = .empty;
    var top_names: std.StringHashMapUnmanaged(void) = .empty;
    for (tree.rootDecls()) |d| if (declName(tree, d)) |n| try top_names.put(arena, n, {});

    try s.beginObject();
    try s.objectField("parse_errors");
    try s.write(tree.errors.len);

    // Every container (the file itself is the first), with its members.
    try s.objectField("containers");
    try s.beginArray();
    var buf2: [2]Ast.Node.Index = undefined;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const c = if (node == .root) tree.containerDeclRoot() else tree.fullContainerDecl(&buf2, node) orelse continue;
        try s.beginObject();
        try s.objectField("root");
        try s.write(node == .root);
        try s.objectField("kind");
        try s.write(if (node == .root) "struct" else tree.tokenSlice(c.ast.main_token));
        try s.objectField("layout");
        try s.write(if (c.layout_token) |t| tree.tokenSlice(t) else "auto");
        try s.objectField("arg");
        try s.write(c.ast.arg != .none or c.ast.enum_token != null);
        // Where members go: after the `{` (the start of the file for the root).
        try s.objectField("open");
        if (node == .root) try s.write(0) else {
            var t = c.ast.main_token;
            while (tree.tokenTag(t) != .l_brace) t += 1;
            try s.write(tree.tokenStart(t) + 1);
        }
        try s.objectField("close");
        try s.write(if (node == .root) src.len else tree.tokenStart(tree.lastToken(node)));
        try s.objectField("fields");
        try s.beginArray();
        for (c.ast.members) |m| if (tree.fullContainerField(m)) |f| {
            try s.beginObject();
            try s.objectField("name");
            try s.write(tree.tokenSlice(f.ast.main_token));
            const start, const end = memberRange(tree, m);
            try s.objectField("start");
            try s.write(start);
            try s.objectField("end");
            try s.write(end);
            try s.endObject();
        };
        try s.endArray();
        try s.objectField("decls");
        try s.beginArray();
        for (c.ast.members) |m| {
            const name = declName(tree, m) orelse continue;
            try writeDecl(arena, tree, &s, m, name, if (node == .root) &top_names else null, &bodies);
        }
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();

    // Function bodies of declarations in containers below the root.
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .fn_decl) continue;
        const start = tree.tokenStart(tree.firstToken(tree.nodeData(node).node_and_node[1]));
        for (bodies.items) |b| {
            if (b.start == start) break;
        } else {
            var buf1: [1]Ast.Node.Index = undefined;
            const proto = tree.fullFnProto(&buf1, node).?;
            try bodies.append(arena, bodyOf(tree, node, &proto));
        }
    }
    try s.objectField("bodies");
    try s.beginArray();
    for (bodies.items) |b| {
        try s.beginObject();
        try s.objectField("start");
        try s.write(b.start);
        try s.objectField("end");
        try s.write(b.end);
        try s.objectField("generic");
        try s.write(b.generic);
        try s.objectField("name");
        try s.write(b.name);
        try s.endObject();
    }
    try s.endArray();

    try s.objectField("error_sets");
    try s.beginArray();
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .error_set_decl) continue;
        const rbrace = tree.nodeData(node).token_and_token[1];
        try s.beginObject();
        try s.objectField("open");
        try s.write(tree.tokenStart(tree.nodeMainToken(node) + 1) + 1);
        try s.objectField("close");
        try s.write(tree.tokenStart(rbrace));
        try s.objectField("names");
        try s.beginArray();
        var t = tree.nodeMainToken(node) + 2;
        while (t < rbrace) : (t += 1) if (tree.tokenTag(t) == .identifier) try s.write(tree.tokenSlice(t));
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();

    // Literals in function bodies: numbers, strings that no builtin reads
    // as a name or a path, and `true` and `false`.
    try s.objectField("literals");
    try s.beginArray();
    for (0..tree.tokens.len) |t| {
        const tok: Ast.TokenIndex = @intCast(t);
        const tag = tree.tokenTag(tok);
        const kind = switch (tag) {
            .number_literal => "int",
            .string_literal => "string",
            .identifier => if (std.mem.eql(u8, tree.tokenSlice(tok), "true") or std.mem.eql(u8, tree.tokenSlice(tok), "false")) "bool" else continue,
            else => continue,
        };
        if (tag == .number_literal) {
            const text = tree.tokenSlice(tok);
            if (std.mem.indexOfAny(u8, text, ".eEpP") != null and !std.mem.startsWith(u8, text, "0x")) continue;
            if (std.mem.indexOfAny(u8, text, ".pP") != null) continue;
        }
        if (tag == .string_literal and tok >= 2 and tree.tokenTag(tok - 1) == .l_paren and tree.tokenTag(tok - 2) == .builtin) continue;
        if (tag == .string_literal and tok >= 1 and tree.tokenTag(tok - 1) == .keyword_extern) continue;
        const start = tree.tokenStart(tok);
        const body = for (bodies.items) |b| {
            if (start > b.start and start < b.end) break b;
        } else null;
        try s.beginObject();
        try s.objectField("kind");
        try s.write(kind);
        try s.objectField("start");
        try s.write(start);
        try s.objectField("end");
        try s.write(start + tree.tokenSlice(tok).len);
        try s.objectField("body");
        try s.write(if (body) |b| b.name else null);
        try s.objectField("generic");
        try s.write(if (body) |b| b.generic else false);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try w.writeByte('\n');
}

fn declName(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    var buf1: [1]Ast.Node.Index = undefined;
    switch (tree.nodeTag(node)) {
        .fn_decl => return if (tree.fullFnProto(&buf1, tree.nodeData(node).node_and_node[0]).?.name_token) |t| tree.tokenSlice(t) else null,
        .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
            return tree.tokenSlice(tree.fullVarDecl(node).?.ast.mut_token + 1);
        },
        else => return null,
    }
}

/// A member's bytes: its doc comments, through its `;` or `,`.
fn memberRange(tree: *const Ast, node: Ast.Node.Index) struct { u32, u32 } {
    var first = tree.firstToken(node);
    while (first > 0 and tree.tokenTag(first - 1) == .doc_comment) first -= 1;
    var last = tree.lastToken(node);
    if (last + 1 < tree.tokens.len and (tree.tokenTag(last + 1) == .semicolon or tree.tokenTag(last + 1) == .comma)) last += 1;
    return .{ tree.tokenStart(first), @intCast(tree.tokenStart(last) + tree.tokenSlice(last).len) };
}

fn bodyOf(tree: *const Ast, node: Ast.Node.Index, proto: *const Ast.full.FnProto) Body {
    const body = tree.nodeData(node).node_and_node[1];
    var generic = false;
    var it = proto.iterate(tree);
    while (it.next()) |p| {
        if (p.comptime_noalias) |t| if (tree.tokenTag(t) == .keyword_comptime) {
            generic = true;
        };
        if (p.anytype_ellipsis3) |t| if (tree.tokenTag(t) == .keyword_anytype) {
            generic = true;
        };
        if (p.type_expr) |te| if (tree.nodeTag(te) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(te)), "type")) {
            generic = true;
        };
    }
    return .{
        .start = tree.tokenStart(tree.firstToken(body)),
        .end = tree.tokenStart(tree.lastToken(body)),
        .generic = generic,
        .name = if (proto.name_token) |t| tree.tokenSlice(t) else "",
    };
}

fn writeDecl(arena: std.mem.Allocator, tree: *const Ast, s: *std.json.Stringify, node: Ast.Node.Index, name: []const u8, top_names: ?*const std.StringHashMapUnmanaged(void), bodies: *std.ArrayList(Body)) !void {
    var buf1: [1]Ast.Node.Index = undefined;
    const start, const end = memberRange(tree, node);
    try s.beginObject();
    try s.objectField("name");
    try s.write(name);
    try s.objectField("start");
    try s.write(start);
    try s.objectField("end");
    try s.write(end);
    const is_fn = tree.nodeTag(node) == .fn_decl;
    try s.objectField("kind");
    try s.write(if (is_fn) "fn" else tree.tokenSlice(tree.fullVarDecl(node).?.ast.mut_token));
    if (is_fn) {
        const proto = tree.fullFnProto(&buf1, tree.nodeData(node).node_and_node[0]).?;
        try s.objectField("pub");
        try s.write(proto.visib_token != null);
        try s.objectField("extern");
        try s.write(proto.extern_export_inline_token != null and tree.tokenTag(proto.extern_export_inline_token.?) != .keyword_inline);
        const b = bodyOf(tree, node, &proto);
        try bodies.append(arena, b);
        try s.objectField("body");
        try s.write(b.start);
        try s.objectField("generic");
        try s.write(b.generic);
        try s.objectField("params");
        try s.beginArray();
        var it = proto.iterate(tree);
        while (it.next()) |p| {
            const te = p.type_expr orelse continue;
            try s.beginObject();
            try s.objectField("type_start");
            try s.write(tree.tokenStart(tree.firstToken(te)));
            const last = tree.lastToken(te);
            try s.objectField("type_end");
            try s.write(tree.tokenStart(last) + tree.tokenSlice(last).len);
            try s.endObject();
        }
        try s.endArray();
    } else {
        const v = tree.fullVarDecl(node).?;
        try s.objectField("pub");
        try s.write(v.visib_token != null);
        try s.objectField("extern");
        try s.write(v.extern_export_token != null);
        // `const name = true;` and the like: the init's only token.
        try s.objectField("init");
        if (v.ast.init_node.unwrap()) |init_node| {
            const f = tree.firstToken(init_node);
            if (f == tree.lastToken(init_node)) try s.write(tree.tokenSlice(f)) else try s.write(null);
        } else try s.write(null);
    }
    // The file's other top-level declarations this one names, and
    // whether its bytes name any identifier at all after a `.`-less
    // reference to something outside it (for moves).
    if (top_names) |names| {
        try s.objectField("uses");
        try s.beginArray();
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var t = tree.firstToken(node);
        while (t <= tree.lastToken(node)) : (t += 1) {
            if (tree.tokenTag(t) != .identifier or (t > 0 and tree.tokenTag(t - 1) == .period)) continue;
            const n = tree.tokenSlice(t);
            if (std.mem.eql(u8, n, name) or !names.contains(n) or seen.contains(n)) continue;
            try seen.put(arena, n, {});
            try s.write(n);
        }
        try s.endArray();
    }
    try s.endObject();
}
