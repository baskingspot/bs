//! exit: 0
//! stdout: "42\n1\n2\n42\nempty\n21\n2\n100\n1\n1\n13\n13\n104\n63\n4\n4\n7\n1\n0\n1\nBadDigit\nEmpty\n0\n7\n99\n23\n3\n98\n97\n4\nB\n5\n9\n5\n100\nY\n200\n"
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

fn halfUp(comptime T: type, x: T) !T {
    if (x == 0) return error.Zero;
    return (x + 1) / 2;
}

inline fn checked(x: u32) !u32 {
    if (x > 100) return error.TooBig;
    return x;
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

    // A generic function returning `!T`, called with runtime arguments.
    var seven: u32 = 7;
    _ = &seven;
    rt.printInt(halfUp(u32, seven) catch 0);
    // An inline function with an inferred error set.
    rt.printInt(checked(seven) catch 0);
    rt.printInt(@intFromBool(checked(seven + 200) == error.TooBig));
    // Optionals compared at runtime.
    var none: ?u32 = null;
    _ = &none;
    rt.printInt(@intFromBool(none == seven));
    rt.printInt(@intFromBool(@as(?u32, seven) == seven));

    // Error names at runtime come from a table built at link time.
    var errs = [_]anyerror{ error.BadDigit, error.Empty };
    _ = &errs;
    for (errs) |err| {
        rt.print(@errorName(err));
        rt.print("\n");
    }
    const name = @errorName(errs[1]);
    rt.printInt(name[name.len]);

    // `(try x).field` goes through a pointer to the error union.
    rt.printInt(tryField(false) catch 99);
    rt.printInt(tryField(true) catch 99);

    // The prongs of a catch's error switch are peers of the payload; a
    // branch that returns leaves a comptime-known value; a noreturn union
    // payload's prong is unreachable.
    rt.printInt(sum(3, 2) catch 99);
    rt.printInt(sum(3, 0) catch 99);
    rt.printInt(sum(0, 0) catch 98);
    rt.printInt(sum(3, 1) catch 97);
    rt.printInt(mode(.{ .plain = 4 }));

    // @errorCast of error sets and error unions.
    var any_err: anyerror = error.B;
    _ = &any_err;
    rt.print(@errorName(narrowSet(any_err)));
    rt.print("\n");
    var any_eu: anyerror!u8 = 5;
    _ = &any_eu;
    rt.printInt(narrowEu(any_eu) catch 0);
    any_eu = error.B;
    rt.printInt(narrowEu(any_eu) catch 9);

    // In `if (x) |payload| ... else |err| switch (err)`, prongs see `err`.
    rt.printInt(useBig(5));
    rt.printInt(useBig(0));
    rt.printInt(useBig(1));

    const e: anyerror!u8 = error.Empty;
    rt.exit(if (e) |_| 1 else |err| if (err == error.Empty) 0 else 2);
}

const Pair = struct { a: u32, b: [3]u8 };
fn getPair(fail: bool) error{Bad}!Pair {
    if (fail) return error.Bad;
    return .{ .a = 4, .b = .{ 1, 2, 3 } };
}
fn tryField(fail: bool) error{Bad}!u32 {
    return (try getPair(fail)).a + (try getPair(fail)).b[2];
}

fn read(k: u32) error{ End, Fail }!usize {
    return switch (k) {
        0 => error.End,
        1 => error.Fail,
        else => k * 10,
    };
}
fn sum(n: usize, k: u32) error{ End, Fail }!usize {
    return n + (read(k) catch |err| switch (err) {
        error.End => if (n == 0) return error.End else 0,
        error.Fail => |e| return e,
    });
}
const Mode = union(enum) { plain: u8, never: noreturn };
fn mode(m: Mode) u8 {
    return switch (m) {
        .plain => |p| p,
        .never => |w| w.missing,
    };
}

fn narrowSet(e: anyerror) error{ A, B } {
    return @errorCast(e);
}
fn narrowEu(x: anyerror!u8) error{B}!u8 {
    return @errorCast(x);
}

const Big = struct { a: u64, b: u64 };
fn makeBig(k: u32) error{ X, Y }!Big {
    if (k == 0) return error.X;
    if (k == 1) return error.Y;
    return .{ .a = k, .b = 1 };
}
fn useBig(k: u32) u64 {
    if (makeBig(k)) |r| {
        return r.a;
    } else |err| switch (err) {
        error.X => return 100,
        else => {
            rt.print(@errorName(err));
            rt.print("\n");
            return 200;
        },
    }
}
