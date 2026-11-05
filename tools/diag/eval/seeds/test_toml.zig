// Adapted from zig-toml's src/parser.zig, spaces.zig, string.zig, integer.zig
// and key.zig (https://github.com/sam701/zig-toml), MIT License,
// Copyright (c) 2022-present Alexei Samokvalov & Contributors.
const std = @import("std");
const testing = std.testing;

pub const Position = struct {
    pos: usize,
    line: usize,

    fn next(self: *Position, current_char: u8) void {
        if (current_char == '\n') {
            self.line += 1;
            self.pos = 1;
        } else {
            self.pos += 1;
        }
    }
};

pub const Context = struct {
    input: []const u8,
    alloc: std.mem.Allocator,
    position: Position = Position{ .pos = 1, .line = 1 },

    pub fn current(self: *const Context) ?u8 {
        if (self.input.len == 0) {
            return null;
        } else {
            return self.input[0];
        }
    }

    pub fn next(self: *Context) ?u8 {
        if (self.input.len == 0) return null;
        self.position.next(self.input[0]);
        self.input = self.input[1..];
        if (self.input.len == 0) return null;
        return self.input[0];
    }
};

pub fn takeWhile(ctx: *Context, comptime tester: fn (u8) bool) []const u8 {
    const origin = ctx.input;
    var copt = ctx.current();
    while (copt) |c| {
        if (tester(c)) {
            copt = ctx.next();
        } else {
            break;
        }
    }
    return origin[0 .. origin.len - ctx.input.len];
}

pub fn testInput(input: []const u8) Context {
    return Context{
        .input = input,
        .alloc = testing.allocator,
    };
}

pub const String = struct {
    content: []const u8,
    allocated: bool,

    pub fn fromSlice(s: []const u8) String {
        return String{
            .content = s,
            .allocated = false,
        };
    }

    pub fn deinit(self: String, alloc: std.mem.Allocator) void {
        if (self.allocated) {
            alloc.free(self.content);
        }
    }
};

pub fn takeBuffer(ctx: *Context, buf: []u8) !void {
    var ix: usize = 0;
    while (ix < buf.len) : (ix += 1) {
        buf[ix] = ctx.current() orelse return error.UnexpectedEOF;
        _ = ctx.next();
    }
}

fn contains(c: u8, allowed: []const u8) bool {
    for (allowed) |a| {
        if (a == c) return true;
    }
    return false;
}

fn skipAny(ctx: *Context, chars: []const u8) void {
    while (ctx.current()) |c| {
        if (!contains(c, chars)) return;
        _ = ctx.next();
    }
}

pub fn skipSpaces(ctx: *Context) void {
    skipAny(ctx, " \t");
}

pub fn skipSpacesAndLineBreaks(ctx: *Context) void {
    skipAny(ctx, " \t\r\n");
}

pub fn consumeNewLine(ctx: *Context) !void {
    var cnt: usize = 0;
    while (ctx.current()) |cur| {
        switch (cur) {
            '\r' => {
                if (cnt > 0) return error.UnexpectedToken;
                _ = ctx.next();
                cnt += 1;
            },
            '\n' => return,
            else => return error.UnexpectedToken,
        }
    }
    return error.UnexpectedToken;
}

const Buffer = std.ArrayList(u8);

const Delimiter = struct {
    char: u8,
    multiline: bool = false,
};

// Returned string is allocated
pub fn parseStr(ctx: *Context) !?[]const u8 {
    var delimiter = parseOpeningDelimiter(ctx) orelse return null;
    return parseString(ctx, &delimiter);
}

pub fn parseSingleLine(ctx: *Context) !?[]const u8 {
    var ctx2 = ctx.*;
    var delimiter = parseOpeningDelimiter(&ctx2) orelse return null;
    if (delimiter.multiline) return error.UnexpectedMultilineString;

    ctx.* = ctx2;
    return parseString(ctx, &delimiter);
}

pub fn parseString(ctx: *Context, delimiter: *const Delimiter) !?[]const u8 {
    var output: Buffer = .empty;
    errdefer output.deinit(ctx.alloc);

    while (ctx.current()) |c| {
        switch (c) {
            '\'', '\"' => {
                if (try parseClosingDelimiter(ctx, delimiter)) {
                    return try output.toOwnedSlice(ctx.alloc);
                }
            },
            '\r', '\n' => if (!delimiter.multiline) return error.InvalidCharacter,
            '\\' => if (delimiter.char == '\"') {
                try parseEscaped(ctx, delimiter, &output);
                continue;
            },
            else => {},
        }
        try output.append(ctx.alloc, c);
        _ = ctx.next();
    }
    return error.UnexpectedEOF;
}

fn parseClosingDelimiter(ctx: *Context, delimiter: *const Delimiter) !bool {
    const c = ctx.current() orelse unreachable;
    if (delimiter.char != c) return false;
    if (!delimiter.multiline) {
        _ = ctx.next();
        return true;
    }
    if (ctx.input.len < 3) return error.UnexpectedEOF;
    const success = ctx.input[1] == c and ctx.input[2] == c;
    if (success) {
        _ = ctx.next();
        _ = ctx.next();
        _ = ctx.next();
    }
    return success;
}

fn parseEscaped(ctx: *Context, delimiter: *const Delimiter, output: *Buffer) !void {
    const c = ctx.next() orelse return error.UnexpectedEOF;
    _ = ctx.next() orelse return error.UnexpectedEOF;
    switch (c) {
        'x' => try parseUnicode(ctx, 2, output),
        'u' => try parseUnicode(ctx, 4, output),
        'U' => try parseUnicode(ctx, 8, output),
        'b' => try output.append(ctx.alloc, 0x08),
        'e' => try output.append(ctx.alloc, 0x1b),
        't' => try output.append(ctx.alloc, '\t'),
        'n' => try output.append(ctx.alloc, '\n'),
        '\"' => try output.append(ctx.alloc, '\"'),
        '\\' => try output.append(ctx.alloc, '\\'),
        '\r', '\n' => {
            if (delimiter.multiline) {
                skipSpacesAndLineBreaks(ctx);
            } else {
                return error.InvalidCharacter;
            }
        },
        else => return error.InvalidEscape,
    }
}

fn parseUnicode(ctx: *Context, size: u8, output: *Buffer) !void {
    var unicode_buf: [8]u8 = undefined;
    const ub = unicode_buf[0..size];
    takeBuffer(ctx, ub) catch return error.InvalidUnicode;

    const codepoint = std.fmt.parseInt(u21, ub, 16) catch return error.InvalidUnicode;

    var buf: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(codepoint, buf[0..]);
    try output.appendSlice(ctx.alloc, buf[0..len]);
}

fn parseOpeningDelimiter(ctx: *Context) ?Delimiter {
    if (ctx.current()) |c| {
        if (c == '\'' or c == '\"') {
            _ = ctx.next();
            const ml = ctx.input.len >= 2 and ctx.input[0] == c and ctx.input[1] == c;
            if (ml) {
                _ = ctx.next();
                _ = ctx.next();
                if (c == '\"') skipNewLine(ctx);
            }
            return Delimiter{ .char = c, .multiline = ml };
        }
    }
    return null;
}

fn skipNewLine(ctx: *Context) void {
    while (ctx.current()) |c| {
        if (c != '\n' and c != '\r') break;
        _ = ctx.next();
    }
}

pub fn interpret(txt: []const u8) ?i64 {
    return std.fmt.parseInt(i64, txt, 0) catch return null;
}

fn isBareKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn parseBareKey(ctx: *Context) !String {
    if (try parseSingleLine(ctx)) |v| {
        return String{ .content = v, .allocated = true };
    } else {
        const v = takeWhile(ctx, isBareKeyChar);
        return String.fromSlice(v);
    }
}

pub const Key = union(enum) {
    bare: String,
    dotted: []const String,

    pub fn deinit(self: *const Key, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .bare => |x| x.deinit(alloc),
            .dotted => |ar| {
                for (ar) |x| x.deinit(alloc);
                alloc.free(ar);
            },
        }
    }

    pub fn asChain(self: *const Key, one: *[1]String) []const String {
        switch (self.*) {
            .bare => |str| {
                one[0] = str;
                return one[0..1];
            },
            .dotted => |chain| return chain,
        }
    }
};

fn parseDotted(ctx: *Context, first: String) !Key {
    var ar: std.ArrayList(String) = .empty;
    try ar.append(ctx.alloc, first);
    while (ctx.current()) |cur| {
        if (cur != '.') break;

        _ = ctx.next();
        skipSpaces(ctx);
        const next = try parseBareKey(ctx);
        try ar.append(ctx.alloc, next);
        skipSpaces(ctx);
    }
    return Key{ .dotted = try ar.toOwnedSlice(ctx.alloc) };
}

pub fn parseKey(ctx: *Context) !Key {
    const first = try parseBareKey(ctx);
    skipSpaces(ctx);
    if (ctx.current()) |cur| {
        if (cur == '.') {
            return parseDotted(ctx, first);
        } else {
            return Key{ .bare = first };
        }
    } else {
        return error.UnexpectedEOF;
    }
}

test "next" {
    var ctx = Context{
        .input = "ab\ncd",
        .alloc = testing.allocator,
    };

    try testing.expect(ctx.position.pos == 1);
    try testing.expect(ctx.next().? == 'b');
    try testing.expect(ctx.current().? == 'b');
    _ = ctx.next();
    try testing.expect(ctx.current().? == '\n');
    _ = ctx.next();
    try testing.expect(ctx.position.line == 2);
    try testing.expect(ctx.current().? == 'c');
}

fn isA(x: u8) bool {
    return x == 'a';
}

test "takeWhile" {
    var ctx = testInput("aaabc");
    const a3 = takeWhile(&ctx, isA);
    try testing.expect(std.mem.eql(u8, a3, "aaa"));
    try testing.expect(ctx.current().? == 'b');
}

test "new line" {
    var ctx = testInput("\r\n");
    try consumeNewLine(&ctx);

    ctx = testInput("\r\r");
    try testing.expectError(error.UnexpectedToken, consumeNewLine(&ctx));
}

test "skip lines" {
    var ctx = testInput("    \t\n   \r\n  hello ");

    skipSpacesAndLineBreaks(&ctx);
    try testing.expect(ctx.current().? == 'h');
}

test "leading new line" {
    var ctx = testInput(
        \\"""
        \\  hello"""
    );
    var str = try parseStr(&ctx);
    try testing.expect(std.mem.eql(u8, str.?, "  hello"));
    ctx.alloc.free(str.?);

    ctx = testInput(
        \\'''
        \\  hello'''
    );
    str = try parseStr(&ctx);
    try testing.expect(std.mem.eql(u8, str.?, "\n  hello"));
    ctx.alloc.free(str.?);
}

test "invalid escape" {
    var ctx = testInput(
        \\"\ab"=
    );
    try testing.expectError(error.InvalidEscape, parseStr(&ctx));
}

test "unicode" {
    var ctx = testInput("\"b\\u00E4c\"");
    const str = try parseStr(&ctx);
    try testing.expect(std.mem.eql(u8, str.?, "bäc"));
    ctx.alloc.free(str.?);
}

test "empty" {
    var ctx = testInput(
        \\abc"
    );
    const str = try parseStr(&ctx);
    try testing.expect(str == null);
}

test "int" {
    try testing.expect(interpret("-123").? == -123);
    try testing.expect(interpret("0xdead_beef").? == 0xdead_beef);
    try testing.expect(interpret("0b11010110").? == 0b11010110);
}

test "dotted" {
    var ctx = testInput("aa.bb . cc .dd");
    var key = try parseKey(&ctx);
    try testing.expect(key.dotted.len == 4);
    try testing.expect(std.mem.eql(u8, key.dotted[1].content, "bb"));
    try testing.expect(ctx.current() == null);
    var one: [1]String = undefined;
    try testing.expect(key.asChain(&one).len == 4);
    key.deinit(ctx.alloc);
}

test "quoted key" {
    var ctx = testInput(
        \\dd."bb cc" = "aa"
    );
    var key = try parseKey(&ctx);
    try testing.expect(std.mem.eql(u8, key.dotted[1].content, "bb cc"));
    key.deinit(ctx.alloc);
}

test "quoted key error" {
    var ctx = testInput(
        \\"""bb cc""" = "aa"
    );
    try testing.expectError(error.UnexpectedMultilineString, parseKey(&ctx));
}
