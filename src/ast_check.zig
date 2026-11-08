//! `bs ast-check`: upstream's `zig ast-check`, copied from upstream 0.17.1's
//! src/main.zig (cmdAstCheck) without the `-t` text dump, which upstream
//! also builds only with debug extensions. Tools such as zls run it to get
//! AstGen's errors (unused locals and parameters). Copyright (c) Zig
//! contributors. MIT licensed (see LICENSE-ZIG).

const std = @import("std");
const frontend = @import("frontend");
const Io = std.Io;
const mem = std.mem;
const process = std.process;
const Allocator = std.mem.Allocator;
const Ast = frontend.Ast;
const Color = std.zig.Color;
const fatal = std.process.fatal;

const usage_ast_check =
    \\Usage: zig ast-check [file]
    \\
    \\    Given a .zig source file or .zon file, reports any compile errors
    \\    that can be ascertained on the basis of the source code alone,
    \\    without target information or type checking.
    \\
    \\    If [file] is omitted, stdin is used.
    \\
    \\Options:
    \\  -h, --help            Print this help and exit
    \\  --color [auto|off|on] Enable or disable colored error messages
    \\  --zon                 Treat the input file as ZON, regardless of file extension
    \\  -t                    (debug option) Output ZIR in text form to stdout
    \\
    \\
;

pub fn run(arena: Allocator, io: Io, args: []const []const u8) !void {
    var color: Color = .auto;
    var want_output_text = false;
    var force_zon = false;
    var zig_source_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (mem.startsWith(u8, arg, "-")) {
            if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
                try Io.File.stdout().writeStreamingAll(io, usage_ast_check);
                return;
            } else if (mem.eql(u8, arg, "-t")) {
                want_output_text = true;
            } else if (mem.eql(u8, arg, "--zon")) {
                force_zon = true;
            } else if (mem.eql(u8, arg, "--color")) {
                if (i + 1 >= args.len) {
                    fatal("expected [auto|on|off] after --color", .{});
                }
                i += 1;
                const next_arg = args[i];
                color = std.meta.stringToEnum(Color, next_arg) orelse {
                    fatal("expected [auto|on|off] after --color, found {q}", .{next_arg});
                };
            } else {
                fatal("unrecognized parameter: {q}", .{arg});
            }
        } else if (zig_source_path == null) {
            zig_source_path = arg;
        } else {
            fatal("extra positional parameter: {q}", .{arg});
        }
    }

    const display_path = zig_source_path orelse "<stdin>";
    const source: [:0]const u8 = s: {
        var f = if (zig_source_path) |p| file: {
            break :file Io.Dir.cwd().openFile(io, p, .{}) catch |err| {
                fatal("unable to open file {q} for ast-check: {t}", .{ display_path, err });
            };
        } else Io.File.stdin();
        defer if (zig_source_path != null) f.close(io);
        var buffer: [4096]u8 = undefined;
        var file_reader: Io.File.Reader = f.reader(io, &buffer);
        break :s std.zig.readSourceFileToEndAlloc(arena, &file_reader) catch |err| {
            fatal("unable to load file {q} for ast-check: {t}", .{ display_path, err });
        };
    };

    const mode: Ast.Mode = if (force_zon or mem.endsWith(u8, display_path, ".zon")) .zon else .zig;
    const tree = try Ast.parse(arena, source, .{ .mode = mode });

    var wip_errors: std.zig.ErrorBundle.Wip = try .init(arena);
    switch (mode) {
        .zig => {
            const zir = try frontend.AstGen.generate(arena, tree);
            if (zir.hasCompileErrors())
                try frontend.errors.addZirErrorMessages(&wip_errors, zir, tree, source, display_path);
        },
        .zon => {
            const zoir = try frontend.ZonGen.generate(arena, tree, .{});
            if (zoir.hasCompileErrors())
                try frontend.errors.addZoirErrorMessages(&wip_errors, zoir, tree, source, display_path);
        },
    }
    var error_bundle = try wip_errors.toOwnedBundle("");
    if (error_bundle.errorMessageCount() > 0) {
        error_bundle.renderToStderr(io, .{}, color) catch {}; // ziglint-ignore: Z026 -- stderr is where it would be reported
        process.exit(1);
    }
    if (want_output_text)
        fatal("-t option only available in builds of zig with debug extensions", .{});
}
