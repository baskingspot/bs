//! bs's Zig frontend: upstream's tokenizer, parser and AstGen, vendored so
//! that bs can compile more than the one release its own std carries
//! (docs/slop/zig-0.16.md). Everything in bs that reads syntax trees or
//! ZIR takes these types, not std.zig's.
//!
//! The types are 0.17.1's, widened to hold Zig 0.16.0 as well: one Ast and
//! one ZIR for both languages. `Ast.parse` takes the `Language`; a 0.16
//! tree comes from 0.16's own parser (v0_16/Parse.zig), and AstGen lowers
//! it with 0.16's meaning into the same ZIR.

pub const Language = @import("language.zig").Language;
pub const tokenizer = @import("tokenizer.zig");
pub const Token = tokenizer.Token;
pub const Tokenizer = tokenizer.Tokenizer;
pub const Ast = @import("Ast.zig");
pub const AstGen = @import("AstGen.zig");
pub const AstRlAnnotate = @import("AstRlAnnotate.zig");
pub const BuiltinFn = @import("BuiltinFn.zig");
pub const Zir = @import("Zir.zig");
pub const SimpleComptimeReason = @import("SimpleComptimeReason.zig").SimpleComptimeReason;
pub const Zoir = @import("Zoir.zig");
pub const ZonGen = @import("ZonGen.zig");
pub const errors = @import("errors.zig");
/// A hash of this module's sources (tools/frontend_hash.zig): ZIR from one
/// version of them is not ZIR from another.
pub const source_hash: u64 = @import("frontend_hash").hash;
/// AstGen's source, whose error formats diag's test checks.
pub const astgen_source = @embedFile("AstGen.zig");

test {
    _ = tokenizer;
}

/// The ZIR of `source` parsed and lowered as `language`, with any errors
/// rendered, for the tests below.
fn testLower(language: Language, source: [:0]const u8) !struct { Zir, []const u8 } {
    const std = @import("std");
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, source, .{ .language = language });
    defer tree.deinit(gpa);
    const zir = try AstGen.generate(gpa, tree);
    var wip: std.zig.ErrorBundle.Wip = try .init(gpa);
    defer wip.deinit();
    if (zir.hasCompileErrors()) try errors.addZirErrorMessages(&wip, zir, tree, source, "t.zig");
    var bundle = try wip.toOwnedBundle("");
    defer bundle.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try bundle.renderToWriter(.{ .include_source_line = false }, &aw.writer);
    return .{ zir, try aw.toOwnedSlice() };
}

fn countExtended(zir: Zir, opcode: Zir.Inst.Extended) usize {
    var n: usize = 0;
    for (zir.instructions.items(.tag), zir.instructions.items(.data)) |tag, data| {
        if (tag == .extended and data.extended.opcode == opcode) n += 1;
    }
    return n;
}

test "Zig 0.16 syntax lowers to 0.16's instructions, and 0.17 rejects it" {
    const std = @import("std");
    const gpa = std.testing.allocator;
    const source =
        \\const a = [_]u8{1} ** 2;
        \\fn f(p: *const u8, x: i0) !u8 {
        \\    _ = x;
        \\    errdefer |e| @compileLog(e);
        \\    if (p.* == 0) return error.A;
        \\    return p.*;
        \\}
        \\comptime {
        \\    _ = @cImport(@cInclude("stdio.h"));
        \\}
        \\
    ;
    var z16, const e16 = try testLower(.zig_0_16, source);
    defer z16.deinit(gpa);
    defer gpa.free(e16);
    try std.testing.expectEqualStrings("", e16);
    try std.testing.expectEqual(1, countExtended(z16, .array_mul));
    try std.testing.expectEqual(2, countExtended(z16, .validate_deref));
    try std.testing.expectEqual(1, countExtended(z16, .c_import));
    try std.testing.expectEqual(1, countExtended(z16, .c_include));
    // `return error.A` gives the capture its code. Upstream 0.16 emits
    // the same counts.
    try std.testing.expectEqual(1, countExtended(z16, .ret_err_value_code));
    try std.testing.expectEqual(2, countExtended(z16, .defer_err_code));

    var z17, const e17 = try testLower(.zig_0_17, source);
    defer z17.deinit(gpa);
    defer gpa.free(e17);
    try std.testing.expect(std.mem.indexOf(u8, e17, "error:") != null);
}

test "Zig 0.16 meanings: `i0` and a discarded pointer capture" {
    const std = @import("std");
    const gpa = std.testing.allocator;
    const cases = [_]struct { [:0]const u8, []const u8 }{
        .{ "const T = i0;", "signed integer cannot have bit width 0" },
        .{ "fn f(e: anyerror!u8) void { if (e) |*_| {} else |err| switch (err) { else => {} } }", "pointer modifier invalid on discard" },
    };
    for (cases) |c| {
        var z16, const e16 = try testLower(.zig_0_16, c[0]);
        defer z16.deinit(gpa);
        defer gpa.free(e16);
        try std.testing.expectEqualStrings("", e16);
        var z17, const e17 = try testLower(.zig_0_17, c[0]);
        defer z17.deinit(gpa);
        defer gpa.free(e17);
        try std.testing.expect(std.mem.indexOf(u8, e17, c[1]) != null);
    }
}
