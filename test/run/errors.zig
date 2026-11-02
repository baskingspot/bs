const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const ParseError = error{ Empty, BadDigit, Overflow };

fn parse(s: []const u8) ParseError!u8 {
    if (s.len == 0) return error.Empty;
    var v: u8 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return error.BadDigit;
        v = @mulWithOverflow(v, 10)[0];
        v = v +% (c - '0');
    }
    return v;
}

fn doubled(s: []const u8) !u16 {
    const v = try parse(s);
    return @as(u16, v) * 2;
}

var cleanups: u32 = 0;

fn withErrdefer(fail: bool) !u32 {
    errdefer cleanups += 1;
    defer cleanups += 10;
    if (fail) return error.Failed;
    return 5;
}

fn find(xs: []const u8, x: u8) ?usize {
    for (xs, 0..) |y, i| {
        if (y == x) return i;
    }
    return null;
}

fn firstChar(s: ?[]const u8) u8 {
    const str = s orelse return '?';
    return str[0];
}

fn main() callconv(.c) noreturn {
    rt.printInt(parse("42") catch 0);
    rt.printInt(parse("") catch 1);
    rt.printInt(parse("4x") catch |err| if (err == error.BadDigit) 2 else 3);
    rt.printInt(doubled("21") catch 0);
    if (doubled("")) |v| {
        rt.printInt(v);
    } else |err| switch (err) {
        error.Empty => rt.print("empty\n"),
        error.BadDigit, error.Overflow => rt.print("bad\n"),
    }

    _ = withErrdefer(false) catch 0;
    _ = withErrdefer(true) catch 0;
    rt.printInt(cleanups);

    const xs = [_]u8{ 5, 7, 9 };
    rt.printInt(find(&xs, 9) orelse 100);
    rt.printInt(find(&xs, 4) orelse 100);
    if (find(&xs, 7)) |i| rt.printInt(i);
    var maybe: ?u32 = null;
    rt.printInt(@intFromBool(maybe == null));
    maybe = 12;
    rt.printInt(maybe.? + 1);
    if (maybe) |*p| p.* += 1;
    rt.printInt(maybe.?);
    rt.printInt(firstChar("hey"));
    rt.printInt(firstChar(null));

    var ptr: ?*u32 = null;
    var target: u32 = 3;
    ptr = &target;
    ptr.?.* = 4;
    rt.printInt(target);

    const e: anyerror!u8 = error.Empty;
    rt.exit(if (e) |_| 1 else |err| if (err == error.Empty) 0 else 2);
}
