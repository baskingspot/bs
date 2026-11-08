//! Syntax and AstGen errors into an error bundle, for the vendored
//! frontend's types: upstream Zig 0.17.1's `ErrorBundle.Wip.addZirErrorMessages`,
//! `addZoirErrorMessages` (lib/std/zig/ErrorBundle.zig) and
//! `printAstErrorsToStderr` (lib/std/zig.zig), changed only to take
//! frontend.zig's types. Copyright (c) Zig contributors. MIT licensed (see
//! LICENSE-ZIG).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ErrorBundle = std.zig.ErrorBundle;
const Color = std.zig.Color;
const frontend = @import("frontend.zig");
const Ast = frontend.Ast;
const AstGen = frontend.AstGen;
const Zir = frontend.Zir;
const Zoir = frontend.Zoir;
const ZonGen = frontend.ZonGen;

pub fn addZirErrorMessages(
    eb: *ErrorBundle.Wip,
    zir: Zir,
    tree: Ast,
    source: [:0]const u8,
    src_path: []const u8,
) !void {
    const payload_index = zir.extra[@backingInt(Zir.ExtraIndex.compile_errors)];
    assert(payload_index != 0);

    const header = zir.extraData(Zir.Inst.CompileErrors, payload_index);
    const items_len = header.data.items_len;
    var extra_index = header.end;
    for (0..items_len) |_| {
        const item = zir.extraData(Zir.Inst.CompileErrors.Item, extra_index);
        extra_index = item.end;
        const err_span = blk: {
            if (item.data.node.unwrap()) |node| {
                break :blk tree.nodeToSpan(node);
            } else if (item.data.token.unwrap()) |token| {
                const start = tree.tokenStart(token) + item.data.byte_offset;
                const end = start + @as(u32, @intCast(tree.tokenSlice(token).len)) - item.data.byte_offset;
                break :blk Ast.Span{ .start = start, .end = end, .main = start };
            } else unreachable;
        };
        const err_loc = std.zig.findLineColumn(source, err_span.main);

        {
            const msg = zir.nullTerminatedString(item.data.msg);
            try eb.addRootErrorMessage(.{
                .msg = try eb.addString(msg),
                .src_loc = try eb.addSourceLocation(.{
                    .src_path = try eb.addString(src_path),
                    .span_start = err_span.start,
                    .span_main = err_span.main,
                    .span_end = err_span.end,
                    .line = @intCast(err_loc.line),
                    .column = @intCast(err_loc.column),
                    .source_line = try eb.addString(err_loc.source_line),
                }),
                .notes_len = item.data.notesLen(zir),
            });
        }

        if (item.data.notes != 0) {
            const notes_start = try eb.reserveNotes(item.data.notesLen(zir));
            const block = zir.extraData(Zir.Inst.Block, item.data.notes);
            const body = zir.extra[block.end..][0..block.data.body_len];
            for (notes_start.., body) |note_i, body_elem| {
                const note_item = zir.extraData(Zir.Inst.CompileErrors.Item, body_elem);
                const msg = zir.nullTerminatedString(note_item.data.msg);
                const span = blk: {
                    if (note_item.data.node.unwrap()) |node| {
                        break :blk tree.nodeToSpan(node);
                    } else if (note_item.data.token.unwrap()) |token| {
                        const start = tree.tokenStart(token) + note_item.data.byte_offset;
                        const end = start + @as(u32, @intCast(tree.tokenSlice(token).len)) - item.data.byte_offset;
                        break :blk Ast.Span{ .start = start, .end = end, .main = start };
                    } else unreachable;
                };
                const loc = std.zig.findLineColumn(source, span.main);

                // This line can cause `wip.extra.items` to be resized.
                const note_index = @backingInt(try eb.addErrorMessage(.{
                    .msg = try eb.addString(msg),
                    .src_loc = try eb.addSourceLocation(.{
                        .src_path = try eb.addString(src_path),
                        .span_start = span.start,
                        .span_main = span.main,
                        .span_end = span.end,
                        .line = @intCast(loc.line),
                        .column = @intCast(loc.column),
                        .source_line = if (loc.eql(err_loc))
                            0
                        else
                            try eb.addString(loc.source_line),
                    }),
                    .notes_len = 0, // TODO rework this function to be recursive
                }));
                eb.extra.items[note_i] = note_index;
            }
        }
    }
}

pub fn addZoirErrorMessages(
    eb: *ErrorBundle.Wip,
    zoir: Zoir,
    tree: Ast,
    source: [:0]const u8,
    src_path: []const u8,
) !void {
    assert(zoir.hasCompileErrors());

    for (zoir.compile_errors) |err| {
        const err_span: Ast.Span = span: {
            if (err.token.unwrap()) |token| {
                const token_start = tree.tokenStart(token);
                const start = token_start + err.node_or_offset;
                const end = token_start + @as(u32, @intCast(tree.tokenSlice(token).len));
                break :span .{ .start = start, .end = end, .main = start };
            } else {
                break :span tree.nodeToSpan(@fromBackingInt(@intCast(err.node_or_offset)));
            }
        };
        const err_loc = std.zig.findLineColumn(source, err_span.main);

        try eb.addRootErrorMessage(.{
            .msg = try eb.addString(err.msg.get(&zoir)),
            .src_loc = try eb.addSourceLocation(.{
                .src_path = try eb.addString(src_path),
                .span_start = err_span.start,
                .span_main = err_span.main,
                .span_end = err_span.end,
                .line = @intCast(err_loc.line),
                .column = @intCast(err_loc.column),
                .source_line = try eb.addString(err_loc.source_line),
            }),
            .notes_len = err.note_count,
        });

        const notes_start = try eb.reserveNotes(err.note_count);
        for (notes_start.., err.first_note.., 0..err.note_count) |eb_note_idx, zoir_note_idx, _| {
            const note = zoir.error_notes[zoir_note_idx];
            const note_span: Ast.Span = span: {
                if (note.token.unwrap()) |token| {
                    const token_start = tree.tokenStart(token);
                    const start = token_start + note.node_or_offset;
                    const end = token_start + @as(u32, @intCast(tree.tokenSlice(token).len));
                    break :span .{ .start = start, .end = end, .main = start };
                } else {
                    break :span tree.nodeToSpan(@fromBackingInt(@intCast(note.node_or_offset)));
                }
            };
            const note_loc = std.zig.findLineColumn(source, note_span.main);

            // This line can cause `wip.extra.items` to be resized.
            const note_index = @backingInt(try eb.addErrorMessage(.{
                .msg = try eb.addString(note.msg.get(&zoir)),
                .src_loc = try eb.addSourceLocation(.{
                    .src_path = try eb.addString(src_path),
                    .span_start = note_span.start,
                    .span_main = note_span.main,
                    .span_end = note_span.end,
                    .line = @intCast(note_loc.line),
                    .column = @intCast(note_loc.column),
                    .source_line = if (note_loc.eql(err_loc))
                        0
                    else
                        try eb.addString(note_loc.source_line),
                }),
                .notes_len = 0,
            }));
            eb.extra.items[eb_note_idx] = note_index;
        }
    }
}

pub fn printAstErrorsToStderr(gpa: Allocator, io: Io, tree: Ast, path: []const u8, color: Color) !void {
    var wip_errors: ErrorBundle.Wip = try .init(gpa);
    defer wip_errors.deinit();

    try putAstErrorsIntoBundle(gpa, tree, path, &wip_errors);

    var error_bundle = try wip_errors.toOwnedBundle("");
    defer error_bundle.deinit(gpa);
    return error_bundle.renderToStderr(io, .{}, color);
}

pub fn putAstErrorsIntoBundle(
    gpa: Allocator,
    tree: Ast,
    path: []const u8,
    wip_errors: *ErrorBundle.Wip,
) Allocator.Error!void {
    switch (tree.mode) {
        .zig => {
            var zir = try AstGen.generate(gpa, tree);
            defer zir.deinit(gpa);

            try addZirErrorMessages(wip_errors, zir, tree, tree.source, path);
        },
        .zon => {
            var zoir = try ZonGen.generate(gpa, tree, .{});
            defer zoir.deinit(gpa);

            try addZoirErrorMessages(wip_errors, zoir, tree, tree.source, path);
        },
    }
}
