//! Where the inline assembly a backend is assembling is in its source, so
//! that its errors point at the failing template line rather than at the
//! function (both backends' `fail`).

const std = @import("std");
const frontend = @import("frontend");
const Allocator = std.mem.Allocator;
const Ast = frontend.Ast;
const InternPool = @import("../InternPool.zig");
const Zcu = @import("../Zcu.zig");
const Atom = @import("../link/Atom.zig");

pub const Loc = struct { file: u32, span: Ast.Span };

/// The `asm` whose operands hold the last statement's position, else the
/// first `asm` from it (the position: `dbg_line` and
/// `dbg_column`, relative to the declaration of the innermost open inlined
/// call `inl` if any, whose file is `files[inl.file - 1]` unless 0, else to
/// function `func`'s), at its template's line `line` when the template is
/// a multiline string, else at the template's string or the `asm` keyword.
pub fn find(zcu: *Zcu, func: InternPool.Index, inl: ?Atom.Debug.Inline, files: []const u32, dbg_line: u32, dbg_column: u32, line: u32) Allocator.Error!?Loc {
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
    offset += dbg_column;
    const tags = tree.tokens.items(.tag);
    const starts = tree.tokens.items(.start);
    const len: u32 = @intCast(tags.len);
    var first: u32 = 0;
    while (first < len and starts[first] < offset) first += 1;
    // The statement whose operands the position is in (an operand's
    // expression has a statement of its own), else the next one.
    var t: u32 = first;
    while (t > 0) {
        t -= 1;
        if (tags[t] != .keyword_asm) continue;
        if (closes(tags, t) >= first) break;
    } else t = len;
    if (t == len) {
        t = first;
        while (t < len and tags[t] != .keyword_asm) t += 1;
    }
    if (t == len) return null;
    var k = t + 1;
    if (k < tags.len and tags[k] == .keyword_volatile) k += 1;
    if (k < tags.len and tags[k] == .l_paren) k += 1;
    const at = if (k + line < tags.len and tags[k] == .multiline_string_literal_line and tags[k + line] == .multiline_string_literal_line)
        k + line
    else if (k < tags.len and (tags[k] == .string_literal or tags[k] == .multiline_string_literal_line)) k else t;
    return .{ .file = file, .span = tree.tokenToSpan(at) };
}

/// The token that closes the parentheses after `asm` token `t`.
fn closes(tags: []const frontend.Token.Tag, t: u32) u32 {
    var k = t + 1;
    if (k < tags.len and tags[k] == .keyword_volatile) k += 1;
    var depth: u32 = 0;
    while (k < tags.len) : (k += 1) switch (tags[k]) {
        .l_paren => depth += 1,
        .r_paren => {
            depth -= 1;
            if (depth == 0) return k;
        },
        else => if (depth == 0) return k,
    };
    return k;
}
