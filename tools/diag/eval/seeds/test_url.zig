// Adapted from httpz's src/url.zig
// (https://github.com/karlseguin/http.zig), MIT License, Copyright (c) 2024 Karl Seguin.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Url = struct {
    raw: []const u8 = "",
    path: []const u8 = "",
    query: []const u8 = "",

    pub fn parse(raw: []const u8) Url {
        var path = raw;
        var query: []const u8 = "";

        if (std.mem.findScalar(u8, raw, '?')) |index| {
            path = raw[0..index];
            query = raw[index + 1 ..];
        }

        return .{
            .raw = raw,
            .path = path,
            .query = query,
        };
    }

    pub const UnescapeResult = struct {
        // Set to the value, whether or not it required unescaped.
        value: []const u8,

        // true if the value WAS unescaped AND placed in buffer
        buffered: bool,
    };

    // When we _have_ to unescape a key or value, we'll try to store the new
    // value in our static buffer (if we have space), else we'll fallback to
    // allocating memory in the arena.
    pub fn unescape(allocator: Allocator, buffer: []u8, input: []const u8) !UnescapeResult {
        var has_plus = false;
        var unescaped_len = input.len;

        var in_i: usize = 0;
        while (in_i < input.len) {
            const b = input[in_i];
            if (b == '%') {
                if (in_i + 2 >= input.len or !std.ascii.isHex(input[in_i + 1]) or !std.ascii.isHex(input[in_i + 2])) {
                    return error.InvalidEscapeSequence;
                }
                in_i += 3;
                unescaped_len -= 2;
            } else if (b == '+') {
                has_plus = true;
                in_i += 1;
            } else {
                in_i += 1;
            }
        }

        // no encoding, and no plus. nothing to unescape
        if (unescaped_len == input.len and !has_plus) {
            return .{ .value = input, .buffered = false };
        }

        var out = buffer;
        var buffered = true;
        if (buffer.len < unescaped_len) {
            out = try allocator.alloc(u8, unescaped_len);
            buffered = false;
        }

        in_i = 0;
        for (0..unescaped_len) |i| {
            const b = input[in_i];
            if (b == '%') {
                out[i] = decodeHex(input[in_i + 1]) << 4 | decodeHex(input[in_i + 2]);
                in_i += 3;
            } else if (b == '+') {
                out[i] = ' ';
                in_i += 1;
            } else {
                out[i] = b;
                in_i += 1;
            }
        }

        return .{ .value = out[0..unescaped_len], .buffered = buffered };
    }

    pub fn isValid(url: []const u8) bool {
        for (url) |c| {
            if (c < 32 or c > 126) {
                return false;
            }
        }
        return true;
    }
};

fn decodeHex(char: u8) u8 {
    return std.fmt.charToDigit(char, 16) catch unreachable;
}

const t = std.testing;
test "url: parse" {
    {
        // absolute root with query
        const url = Url.parse("/?over=9000");
        try t.expectEqualStrings("/?over=9000", url.raw);
        try t.expectEqualStrings("/", url.path);
        try t.expectEqualStrings("over=9000", url.query);
    }

    {
        // absolute path with query
        const url = Url.parse("/hello/teg?duncan=idaho&ghanima=atreides");
        try t.expectEqualStrings("/hello/teg", url.path);
        try t.expectEqualStrings("duncan=idaho&ghanima=atreides", url.query);
    }
}

test "url: unescape" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var buffer: [10]u8 = undefined;

    try t.expectError(error.InvalidEscapeSequence, Url.unescape(t.allocator, &buffer, "%"));
    try t.expectError(error.InvalidEscapeSequence, Url.unescape(t.allocator, &buffer, "%zzzzz"));

    var res = try Url.unescape(allocator, &buffer, "a+b");
    try t.expectEqualStrings("a b", res.value);
    try t.expectEqual(true, res.buffered);

    const input = "%5C%C3%B6%2F%20%C3%A4%C3%B6%C3%9F%20~~.adas-https%3A%2F%2Fcanvas%3A123%2F%23ads%26%26sad";
    const expected = "\\ö/ äöß ~~.adas-https://canvas:123/#ads&&sad";
    res = try Url.unescape(allocator, &buffer, input);
    try t.expectEqualStrings(expected, res.value);
    try t.expectEqual(false, res.buffered);
}

test "url: isValid" {
    try t.expectEqual(true, Url.isValid("/a b~"));
    try t.expectEqual(false, Url.isValid("/a\x7fb"));
}
