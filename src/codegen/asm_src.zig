//! Where the inline assembly a backend is assembling is in its source, so
//! that its errors point at the failing template line rather than at the
//! function (both backends' `fail`); and where the statement it is
//! lowering is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const InternPool = @import("../InternPool.zig");
const Zcu = @import("../Zcu.zig");
const Atom = @import("../link/Atom.zig");

pub const Loc = struct { file: u32, span: Ast.Span };

/// The first `asm` from the last statement's position (`dbg_line` and
/// `dbg_column`, relative to the declaration of the innermost open inlined
/// call `inl` if any, whose file is `files[inl.file - 1]` unless 0, else to
/// function `func`'s), at its template's line `line` when the template is
/// a multiline string, else at the template's string or the `asm` keyword.
pub fn find(zcu: *Zcu, func: InternPool.Index, inl: ?Atom.Debug.Inline, files: []const u32, dbg_line: u32, dbg_column: u32, line: u32) Allocator.Error!?Loc {
    const pos = try position(zcu, func, inl, files, dbg_line, dbg_column) orelse return null;
    const tree = pos.tree;
    const tags = tree.tokens.items(.tag);
    const starts = tree.tokens.items(.start);
    var t: u32 = 0;
    while (t < tags.len and (starts[t] < pos.offset or tags[t] != .keyword_asm)) t += 1;
    if (t == tags.len) return null;
    var k = t + 1;
    if (k < tags.len and tags[k] == .keyword_volatile) k += 1;
    if (k < tags.len and tags[k] == .l_paren) k += 1;
    const at = if (k + line < tags.len and tags[k] == .multiline_string_literal_line and tags[k + line] == .multiline_string_literal_line)
        k + line
    else if (k < tags.len and (tags[k] == .string_literal or tags[k] == .multiline_string_literal_line)) k else t;
    return .{ .file = pos.file, .span = tree.tokenToSpan(at) };
}

/// The first token on the last statement's line, as `find` reads it: for
/// errors about the statement itself, such as a call the backend cannot
/// make, whose position may be one of its operands'.
pub fn stmt(zcu: *Zcu, func: InternPool.Index, inl: ?Atom.Debug.Inline, files: []const u32, dbg_line: u32) Allocator.Error!?Loc {
    const pos = try position(zcu, func, inl, files, dbg_line, 0) orelse return null;
    const starts = pos.tree.tokens.items(.start);
    var t: u32 = 0;
    while (t < starts.len and starts[t] < pos.offset) t += 1;
    if (t == starts.len) return null;
    return .{ .file = pos.file, .span = pos.tree.tokenToSpan(t) };
}

fn position(zcu: *Zcu, func: InternPool.Index, inl: ?Atom.Debug.Inline, files: []const u32, dbg_line: u32, dbg_column: u32) Allocator.Error!?struct { file: u32, tree: *const Ast, offset: usize } {
    const ip = &zcu.ip;
    const nav = ip.getNav(ip.keyPayload(.func, func).owner_nav);
    var file = nav.file;
    var base_line = zcu.file(nav.file).zir.getDeclaration(nav.zir_inst).src_line;
    if (inl) |in| {
        if (in.file != 0) file = files[in.file - 1];
        base_line = in.base_line;
    }
    const tree = try zcu.fe.tree(@fromBackingInt(file));
    var offset: usize = 0;
    for (0..base_line + dbg_line) |_| offset = (std.mem.findScalarPos(u8, tree.source, offset, '\n') orelse return null) + 1;
    return .{ .file = file, .tree = tree, .offset = offset + dbg_column };
}
