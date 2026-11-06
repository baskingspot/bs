//! exit: 0
//! stderr: "f 21 24 | i 35 68 | w 0 9 | a 0 9 | c 0 9 | n 47 6 | p 16 3 | fw 72 136\n"
//! Copies of slice elements that read the element in place: a `for`
//! capture and `const x = s[i]` of a struct read only by field are the
//! element's memory, unless something may write it before the last read
//! (a store to the element, directly or through another pointer, or a
//! call), when they stay copies.
const std = @import("std");

const Line = struct { start: u32, end: u32, pad: [14]f32 = @splat(0), cs: u32, ce: u32 };

noinline fn find(lines: []const Line, carets: []const u32, off: u32) u32 {
    for (lines, 0..) |line, l| {
        if (off < line.start or off > line.end) continue;
        for (carets[line.cs..line.ce], 0..) |c, i| if (c == off) return @intCast(l * 10 + i);
    }
    return 0;
}

noinline fn last(lines: []const Line, off: u32) u32 {
    var l = lines.len;
    while (l != 0) {
        l -= 1;
        const line = lines[l];
        if (off < line.start) continue;
        return @intCast(l * 10 + line.ce - line.cs);
    }
    return 0;
}

noinline fn writeDirect(lines: []Line, i: usize) u32 {
    const line = lines[i];
    lines[i].start = 99;
    return line.start * 10 + lines[i].start / 11;
}

noinline fn writeAlias(lines: []Line, p: *Line, i: usize) u32 {
    const line = lines[i];
    p.start = 99;
    return line.start * 10 + lines[i].start / 11;
}

var global: ?*Line = null;
noinline fn clobber() void {
    global.?.start = 99;
}
noinline fn callBetween(lines: []Line, i: usize) u32 {
    const line = lines[i];
    clobber();
    return line.start * 10 + lines[i].start / 11;
}

inline fn width(line: Line) u32 {
    return line.end - line.start;
}
noinline fn inlined(lines: []const Line, i: usize) u32 {
    return width(lines[i]) + lines[i].start;
}

noinline fn widths(lines: []const Line) u32 {
    var t: u32 = 0;
    for (lines) |line| t += width(line) + line.cs;
    return t;
}

noinline fn forWrite(lines: []Line) u32 {
    var t: u32 = 0;
    for (lines, 0..) |line, k| {
        lines[k].start += 100;
        t += line.start;
    }
    return t;
}

noinline fn viaPtr(lines: [*]const Line, i: usize) u32 {
    const line = lines[i];
    return line.start + line.ce - line.cs;
}

pub fn main() void {
    var lines: [4]Line = undefined;
    var carets: [16]u32 = undefined;
    for (&carets, 0..) |*c, i| c.* = @intCast(i * 3);
    for (&lines, 0..) |*ln, i| ln.* = .{ .start = @intCast(i * 12), .end = @intCast(i * 12 + 11), .cs = @intCast(i * 4), .ce = @intCast(i * 4 + 4) };
    std.debug.print("f {} {} | ", .{ find(&lines, &carets, 27), last(&lines, 25) });
    std.debug.print("i {} {} | ", .{ inlined(&lines, 2), widths(&lines) });
    lines[1].start = 0;
    std.debug.print("w {} {} | ", .{ writeDirect(&lines, 1) / 10, writeDirect(&lines, 1) % 10 });
    lines[1].start = 0;
    std.debug.print("a {} {} | ", .{ writeAlias(&lines, &lines[1], 1) / 10, writeAlias(&lines, &lines[1], 1) % 10 });
    lines[1].start = 0;
    global = &lines[1];
    std.debug.print("c {} {} | ", .{ callBetween(&lines, 1) / 10, callBetween(&lines, 1) % 10 });
    lines[1].start = 12;
    std.debug.print("n {} {} | ", .{ inlined(&lines, 3), viaPtr(&lines, 0) - 0 + 2 });
    std.debug.print("p {} {} | ", .{ viaPtr(&lines, 3) - 36 + 12, viaPtr(&lines, 2) - 24 - 1 });
    std.debug.print("fw {} {}\n", .{ forWrite(&lines), lines[3].start });
}
