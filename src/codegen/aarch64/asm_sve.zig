//! aarch64 inline assembly's SVE instructions, as upstream's assembler
//! (LLVM) encodes them: the predicated contiguous loads and stores
//! (`ld1b` to `ld1d`, `st1b` to `st1d`, scalar base and vector-length
//! immediate, widening included), the element counts (`cntb` to `cntd`), the `while`
//! comparisons (`whilelo`, `whilels`, `whilelt`, `whilele`) and `ptrue`:
//! those of Arm's optimized-routines string functions, which fastmem
//! ports. bs's own code generation stays NEON; SVE reaches the output only
//! through assembly written for it. An instruction here needs the CPU's
//! `sve` feature or `.arch ...+sve` earlier in the block, as upstream.

const std = @import("std");

pub const Error = error{ AsmInvalid, AsmUnsupported };

/// Assembles SVE instruction `mnemonic` with operands `text` (as written
/// after the mnemonic), or returns null when `mnemonic` is not one of
/// SVE's that bs assembles. `sve` says whether SVE is available. On an
/// error, `msg.*` says why (for `AsmInvalid`).
pub fn encode(mnemonic: []const u8, text: []const u8, sve: bool, msg: *[]const u8) Error!?u32 {
    const kind = Kind.of(mnemonic) orelse return null;
    if (!sve) {
        msg.* = "instruction requires: sve or sme";
        return error.AsmInvalid;
    }
    if (std.mem.findScalar(u8, text, '%') != null) return error.AsmUnsupported;
    var ops: [4][]const u8 = undefined;
    const n = split(text, &ops) orelse return error.AsmUnsupported;
    msg.* = "invalid operand for instruction";
    switch (kind) {
        .cnt => |size| {
            if (n < 1 or n > 3) return error.AsmInvalid;
            const rd = xReg(ops[0], false) orelse return error.AsmInvalid;
            const pattern: u32 = if (n >= 2) patternOf(ops[1]) orelse return error.AsmInvalid else 31;
            var mul: u32 = 1;
            if (n == 3) {
                const m = ops[2];
                if (!std.ascii.startsWithIgnoreCase(m, "mul")) return error.AsmInvalid;
                const v = imm(std.mem.trim(u8, m[3..], " \t")) orelse return error.AsmInvalid;
                if (v < 1 or v > 16) return error.AsmInvalid;
                mul = @intCast(v);
            }
            return 0x0420e000 | @as(u32, size) << 22 | (mul - 1) << 16 | pattern << 5 | rd;
        },
        .@"while" => |base| {
            if (n != 3) return error.AsmInvalid;
            const pd = pReg(ops[0]) orelse return error.AsmInvalid;
            if (pd.size == null) return error.AsmInvalid;
            const x = xReg(ops[1], true);
            const w = wReg(ops[1]);
            const sf: u32 = if (x != null) 1 else if (w != null) 0 else return error.AsmInvalid;
            const rn = x orelse w.?;
            const rm = (if (sf == 1) xReg(ops[2], true) else wReg(ops[2])) orelse return error.AsmInvalid;
            return base | @as(u32, pd.size.?) << 22 | rm << 16 | sf << 12 | rn << 5 | pd.num;
        },
        .ptrue => {
            if (n < 1 or n > 2) return error.AsmInvalid;
            const pd = pReg(ops[0]) orelse return error.AsmInvalid;
            if (pd.size == null) return error.AsmInvalid;
            const pattern: u32 = if (n == 2) patternOf(ops[1]) orelse return error.AsmInvalid else 31;
            return 0x2518e000 | @as(u32, pd.size.?) << 22 | pattern << 5 | pd.num;
        },
        .ldst => |l| {
            if (n != 3) return error.AsmInvalid;
            var zt_tok = ops[0];
            if (zt_tok.len > 2 and zt_tok[0] == '{' and zt_tok[zt_tok.len - 1] == '}') zt_tok = std.mem.trim(u8, zt_tok[1 .. zt_tok.len - 1], " \t");
            const zt = zReg(zt_tok) orelse return error.AsmInvalid;
            // Elements as wide as memory's or wider (`ld1b z0.h`, which
            // zero-extends each byte).
            if (zt.size.? < l.size) {
                msg.* = "invalid element width";
                return error.AsmInvalid;
            }
            // A load's governing predicate zeroes (`p0/z`), a store's
            // does not; either is p0-p7.
            var pg_tok = ops[1];
            if (l.load) {
                if (!std.ascii.endsWithIgnoreCase(pg_tok, "/z")) return error.AsmInvalid;
                pg_tok = pg_tok[0 .. pg_tok.len - 2];
            }
            const pg = pReg(pg_tok) orelse return error.AsmInvalid;
            if (pg.size != null or pg.num > 7) return error.AsmInvalid;
            const m = ops[2];
            if (m.len < 3 or m[0] != '[' or m[m.len - 1] != ']') return error.AsmInvalid;
            var parts: [3][]const u8 = undefined;
            const k = splitComma(m[1 .. m.len - 1], &parts) orelse return error.AsmInvalid;
            const rn = spReg(parts[0]) orelse return error.AsmInvalid;
            var offset: i64 = 0;
            if (k == 2 or k > 3) return error.AsmInvalid;
            if (k == 3) {
                offset = imm(parts[1]) orelse return error.AsmInvalid;
                var words = std.mem.tokenizeAny(u8, parts[2], " \t");
                const w1 = words.next() orelse "";
                const w2 = words.next() orelse "";
                if (!std.ascii.eqlIgnoreCase(w1, "mul") or !std.ascii.eqlIgnoreCase(w2, "vl") or words.next() != null) return error.AsmInvalid;
                if (offset < -8 or offset > 7) {
                    msg.* = "index must be an integer in range [-8, 7].";
                    return error.AsmInvalid;
                }
            }
            const imm4: u32 = @as(u4, @bitCast(@as(i4, @intCast(offset))));
            const base: u32 = if (l.load) 0xa400a000 else 0xe400e000;
            const dtype = (@as(u32, l.size) << 2 | zt.size.?) << 21;
            return base | dtype | imm4 << 16 | @as(u32, pg.num) << 10 | rn << 5 | zt.num;
        },
    }
}

const Kind = union(enum) {
    cnt: u2,
    @"while": u32,
    ptrue,
    ldst: struct { load: bool, size: u2 },

    fn of(m: []const u8) ?Kind {
        const map = std.StaticStringMap(Kind).initComptime(.{
            .{ "cntb", Kind{ .cnt = 0 } },                              .{ "cnth", Kind{ .cnt = 1 } },
            .{ "cntw", Kind{ .cnt = 2 } },                              .{ "cntd", Kind{ .cnt = 3 } },
            .{ "whilelt", Kind{ .@"while" = 0x25200400 } },             .{ "whilele", Kind{ .@"while" = 0x25200410 } },
            .{ "whilelo", Kind{ .@"while" = 0x25200c00 } },             .{ "whilels", Kind{ .@"while" = 0x25200c10 } },
            .{ "ptrue", Kind.ptrue },                                   .{ "ld1b", Kind{ .ldst = .{ .load = true, .size = 0 } } },
            .{ "ld1h", Kind{ .ldst = .{ .load = true, .size = 1 } } },  .{ "ld1w", Kind{ .ldst = .{ .load = true, .size = 2 } } },
            .{ "ld1d", Kind{ .ldst = .{ .load = true, .size = 3 } } },  .{ "st1b", Kind{ .ldst = .{ .load = false, .size = 0 } } },
            .{ "st1h", Kind{ .ldst = .{ .load = false, .size = 1 } } }, .{ "st1w", Kind{ .ldst = .{ .load = false, .size = 2 } } },
            .{ "st1d", Kind{ .ldst = .{ .load = false, .size = 3 } } },
        });
        var buf: [8]u8 = undefined;
        if (m.len > buf.len) return null;
        return map.get(std.ascii.lowerString(&buf, m));
    }
};

/// The comma-separated operands of `text`, commas inside brackets and
/// braces kept, into `out`; null if there are more than `out` holds.
fn split(text: []const u8, out: [][]const u8) ?usize {
    var n: usize = 0;
    var depth: u32 = 0;
    var start: usize = 0;
    for (text, 0..) |c, k| {
        switch (c) {
            '[', '{' => depth += 1,
            ']', '}' => depth -|= 1,
            else => {},
        }
        const last = k == text.len - 1;
        if ((c == ',' and depth == 0) or last) {
            const end = if (c == ',' and depth == 0) k else k + 1;
            const tok = std.mem.trim(u8, text[start..end], " \t");
            start = k + 1;
            if (tok.len == 0) continue;
            if (n == out.len) return null;
            out[n] = tok;
            n += 1;
        }
    }
    return n;
}

fn splitComma(text: []const u8, out: [][]const u8) ?usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |p| {
        if (n == out.len) return null;
        out[n] = std.mem.trim(u8, p, " \t");
        n += 1;
    }
    return n;
}

fn imm(tok_in: []const u8) ?i64 {
    var tok = tok_in;
    if (tok.len != 0 and tok[0] == '#') tok = tok[1..];
    return std.fmt.parseInt(i64, tok, 0) catch null;
}

fn regNum(tok: []const u8, prefix: u8) ?u32 {
    if (tok.len < 2 or std.ascii.toLower(tok[0]) != prefix) return null;
    const v = std.fmt.parseInt(u5, tok[1..], 10) catch return null;
    return v;
}

/// x0-x30, and xzr when `zr`.
fn xReg(tok: []const u8, zr: bool) ?u32 {
    if (zr and std.ascii.eqlIgnoreCase(tok, "xzr")) return 31;
    const r = regNum(tok, 'x') orelse return null;
    return if (r == 31) null else r;
}

fn wReg(tok: []const u8) ?u32 {
    if (std.ascii.eqlIgnoreCase(tok, "wzr")) return 31;
    const r = regNum(tok, 'w') orelse return null;
    return if (r == 31) null else r;
}

/// x0-x30 or sp: a base address register.
fn spReg(tok: []const u8) ?u32 {
    if (std.ascii.eqlIgnoreCase(tok, "sp")) return 31;
    return xReg(tok, false);
}

const Sized = struct { num: u5, size: ?u2 };

fn sized(tok: []const u8, prefix: u8, max: u5) ?Sized {
    const dot = std.mem.findScalar(u8, tok, '.') orelse tok.len;
    const num = regNum(tok[0..dot], prefix) orelse return null;
    if (num > max) return null;
    if (dot == tok.len) return .{ .num = @intCast(num), .size = null };
    if (tok.len != dot + 2) return null;
    const s = std.mem.findScalar(u8, "bhsd", std.ascii.toLower(tok[dot + 1])) orelse return null;
    return .{ .num = @intCast(num), .size = @intCast(s) };
}

fn pReg(tok: []const u8) ?Sized {
    return sized(tok, 'p', 15);
}

fn zReg(tok: []const u8) ?Sized {
    const z = sized(tok, 'z', 31) orelse return null;
    return if (z.size == null) null else z;
}

fn patternOf(tok: []const u8) ?u32 {
    const map = std.StaticStringMap(u32).initComptime(.{
        .{ "pow2", 0 },  .{ "vl1", 1 },   .{ "vl2", 2 },    .{ "vl3", 3 },    .{ "vl4", 4 },
        .{ "vl5", 5 },   .{ "vl6", 6 },   .{ "vl7", 7 },    .{ "vl8", 8 },    .{ "vl16", 9 },
        .{ "vl32", 10 }, .{ "vl64", 11 }, .{ "vl128", 12 }, .{ "vl256", 13 }, .{ "mul4", 29 },
        .{ "mul3", 30 }, .{ "all", 31 },
    });
    var buf: [8]u8 = undefined;
    if (tok.len > buf.len) {
        return null;
    }
    if (map.get(std.ascii.lowerString(&buf, tok))) |p| return p;
    // `#n`: the pattern by number.
    const v = imm(tok) orelse return null;
    return if (v >= 0 and v < 32) @intCast(v) else null;
}

test encode {
    var msg: []const u8 = "";
    const cases = [_]struct { m: []const u8, ops: []const u8, word: u32 }{
        // llvm-mc 19 -mattr=+sve -show-encoding.
        .{ .m = "cntb", .ops = "x6", .word = 0x0420e3e6 },
        .{ .m = "cntd", .ops = "x6", .word = 0x04e0e3e6 },
        .{ .m = "cntb", .ops = "x6, all, mul #4", .word = 0x0423e3e6 },
        .{ .m = "cntb", .ops = "x6, pow2", .word = 0x0420e006 },
        .{ .m = "whilelo", .ops = "p0.b, xzr, x2", .word = 0x25221fe0 },
        .{ .m = "whilelo", .ops = "p1.h, w6, w2", .word = 0x25620cc1 },
        .{ .m = "whilelo", .ops = "p15.d, x6, x2", .word = 0x25e21ccf },
        .{ .m = "whilelt", .ops = "p1.b, x6, x2", .word = 0x252214c1 },
        .{ .m = "whilels", .ops = "p1.b, x6, x2", .word = 0x25221cd1 },
        .{ .m = "whilele", .ops = "p1.b, x6, x2", .word = 0x252214d1 },
        .{ .m = "ld1b", .ops = "z0.b, p0/z, [x1, 0, mul vl]", .word = 0xa400a020 },
        .{ .m = "ld1b", .ops = "{z1.b}, p1/z, [x1, #1, mul vl]", .word = 0xa401a421 },
        .{ .m = "ld1b", .ops = "z31.b, p7/z, [x30, #-8, mul vl]", .word = 0xa408bfdf },
        .{ .m = "ld1h", .ops = "z1.h, p1/z, [x1, #2, mul vl]", .word = 0xa4a2a421 },
        .{ .m = "ld1w", .ops = "z1.s, p1/z, [x1, #2, mul vl]", .word = 0xa542a421 },
        .{ .m = "ld1d", .ops = "z1.d, p1/z, [x1, #2, mul vl]", .word = 0xa5e2a421 },
        .{ .m = "st1b", .ops = "z0.b, p0, [x0]", .word = 0xe400e000 },
        .{ .m = "st1b", .ops = "z1.b, p1, [x0, 1, mul vl]", .word = 0xe401e401 },
        .{ .m = "st1d", .ops = "z1.d, p1, [x0, #2, mul vl]", .word = 0xe5e2e401 },
        .{ .m = "ld1b", .ops = "z0.h, p0/z, [x1]", .word = 0xa420a020 },
        .{ .m = "st1b", .ops = "z0.d, p0, [x1]", .word = 0xe460e020 },
        .{ .m = "ptrue", .ops = "p0.b", .word = 0x2518e3e0 },
        .{ .m = "ptrue", .ops = "p1.s, vl4", .word = 0x2598e081 },
    };
    for (cases) |c| try std.testing.expectEqual(@as(?u32, c.word), try encode(c.m, c.ops, true, &msg));
    try std.testing.expectEqual(@as(?u32, null), try encode("ldr", "x0, [x1]", true, &msg));
    // Without SVE, elements narrower than memory's, a load without `/z`,
    // p8 governing, and an offset past [-8, 7] are errors, as for llvm-mc.
    try std.testing.expectError(error.AsmInvalid, encode("cntb", "x0", false, &msg));
    try std.testing.expectError(error.AsmInvalid, encode("ld1h", "z0.b, p0/z, [x1]", true, &msg));
    try std.testing.expectError(error.AsmInvalid, encode("ld1b", "z0.b, p0, [x1]", true, &msg));
    try std.testing.expectError(error.AsmInvalid, encode("st1b", "z0.b, p8, [x1]", true, &msg));
    try std.testing.expectError(error.AsmInvalid, encode("st1b", "z0.b, p0, [x1, #8, mul vl]", true, &msg));
}
