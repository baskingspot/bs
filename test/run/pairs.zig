//! exit: 0
//! stderr: "old=3 new=5 best=ghij swap=ef/abcd stack=338 eu=42 err=Bad null=true opt=3 cpy=pairs!..\n"
//! targets: aarch64-macos aarch64-linux

// Slices, optional slices, and error unions with an 8-byte payload live in
// two registers (`inPair`), as do promoted variables of those types, and a
// slice's `ptr` and `len` are read from the slice's registers.
const std = @import("std");

/// `len` of the variable's old value, read after the variable changed.
noinline fn oldLen(a: []const u8, b: []const u8) [2]usize {
    var s = a;
    const t = s;
    const n = t.len;
    s = b;
    return .{ n, s.len };
}

noinline fn longest(list: []const []const u8) []const u8 {
    var best: []const u8 = "";
    for (list) |s| {
        if (s.len > best.len) best = s;
    }
    return best;
}

noinline fn swapped(a0: []const u8, b0: []const u8, n: usize) [2][]const u8 {
    var a = a0;
    var b = b0;
    for (0..n) |_| {
        const t = a;
        a = b;
        b = t;
    }
    return .{ a, b };
}

/// `e` and `f` go on the stack: x0-x7 hold four slices.
noinline fn many(a: []const u8, b: []const u8, c: []const u8, d: []const u8, e: []const u8, f: []const u8) usize {
    return a.len + 2 * b.len + 3 * c.len + 5 * d.len + 7 * e.len + 11 * f.len + e[0] + f[f.len - 1];
}

const E = error{ Bad, Worse };

noinline fn parse(s: []const u8) E!u64 {
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return if (c == 'x') E.Worse else E.Bad;
        v = v * 10 + (c - '0');
    }
    return v;
}

noinline fn find(s: []const u8, c: u8) ?[]const u8 {
    for (s, 0..) |x, i| if (x == c) return s[i..];
    return null;
}

noinline fn cpy(dst: []u8, src: []const u8) void {
    @memcpy(dst[0..src.len], src);
}

pub fn main() void {
    const lens = oldLen("abc", "defgh");
    const best = longest(&.{ "a", "bcd", "ef", "ghij", "k" });
    const sw = swapped("abcd", "ef", 3);
    const err = if (parse("12a")) |_| unreachable else |e| e;
    var dst: [8]u8 = @splat('.');
    cpy(&dst, "pairs!");
    std.debug.print("old={d} new={d} best={s} swap={s}/{s} stack={d} eu={d} err={s} null={} opt={d} cpy={s}\n", .{
        lens[0],                  lens[1],
        best,                     sw[0],
        sw[1],                    many("a", "bb", "ccc", "dddd", "eeeee", "ffffff"),
        parse("42") catch 0,      @errorName(err),
        find("abc", 'z') == null, if (find("hello", 'l')) |f| f.len else 0,
        &dst,
    });
}
