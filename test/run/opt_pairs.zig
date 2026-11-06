//! exit: 0
//! stderr: "find 10 8 3\nvia 2 null one null\npick -3 null true\ncolor 10000000e null\nadd 7 4 null\nbytes 123456789abcdef0 true 123456789abcdef0 dead\niter 55\nlast 3\narr 113 4 3\nstructs 25\n"
//! targets: x86_64-linux aarch64-linux

const std = @import("std");

// Optionals of 8-byte integers and enums (`?usize`, `?u64`, `?i64`) live
// in a register pair on x86_64: the payload low, the flag in the low byte
// of the high register, above it the optional's padding.

const Color = enum(u64) { red = 1, green = 0x1_0000_0000, blue = 0xffff_ffff_ffff_ffff };

noinline fn find(xs: []const u64, k: u64) ?usize {
    for (xs, 0..) |x, i| if (x == k) return i;
    return null;
}

// A call's result returned as it is stays in rax and rdx.
noinline fn findVia(xs: []const u64, k: u64) ?usize {
    return find(xs, k);
}

noinline fn name(n: u64) ?[]const u8 {
    return if (n == 1) "one" else null;
}

noinline fn nameVia(n: u64) ?[]const u8 {
    return name(n);
}

noinline fn pick(c: bool, v: i64) ?i64 {
    return if (c) v else null;
}

noinline fn color(n: u64) ?Color {
    return switch (n) {
        0 => .red,
        1 => .green,
        2 => .blue,
        else => null,
    };
}

noinline fn addOpt(a: ?u64, b: ?u64) ?u64 {
    const x = a orelse return b;
    return x +% (b orelse 0);
}

/// An optional built from bytes: the flag byte as given, garbage in the
/// padding (and in the payload of null).
noinline fn fromBytes(payload: u64, flag: u8) ?u64 {
    var bytes: [16]u8 = @splat(0xa5);
    std.mem.writeInt(u64, bytes[0..8], payload, .little);
    bytes[8] = flag;
    var o: ?u64 = undefined;
    @memcpy(std.mem.asBytes(&o), &bytes);
    return o;
}

const Iter = struct {
    n: u64,
    i: u64 = 0,
    fn next(it: *Iter) ?u64 {
        if (it.i == it.n) return null;
        defer it.i += 1;
        return it.i * it.i;
    }
};

const S = struct { a: ?usize, b: u8, c: ?i64 };

noinline fn sumStructs(ss: []const S) i64 {
    var t: i64 = 0;
    for (ss) |s| {
        if (s.a) |a| t += @intCast(a);
        t += s.c orelse -1;
        t += s.b;
    }
    return t;
}

pub fn main() void {
    const xs = [_]u64{ 5, 9, 2, 7 };
    var found: usize = 0;
    var missing: usize = 0;
    for (0..12) |k| {
        if (find(&xs, k)) |i| found += i + 1 else missing += 1;
    }
    std.debug.print("find {} {} {?}\n", .{ found, missing, find(&xs, 7) });

    std.debug.print("via {?} {?} {?s} {?s}\n", .{ findVia(&xs, 2), findVia(&xs, 3), nameVia(1), nameVia(2) });

    std.debug.print("pick {?} {?} {}\n", .{ pick(true, -3), pick(false, 4), pick(false, 4) == null });

    var cs: u64 = 0;
    for (0..5) |n| cs +%= if (color(n)) |c| @backingInt(c) else 7;
    std.debug.print("color {x} {?}\n", .{ cs, color(3) });

    std.debug.print("add {?} {?} {?}\n", .{ addOpt(3, 4), addOpt(null, 4), addOpt(null, null) });

    const g1 = fromBytes(0x1234_5678_9abc_def0, 1);
    const g0 = fromBytes(0x1234_5678_9abc_def0, 0);
    std.debug.print("bytes {?x} {} {x} {x}\n", .{ g1, g0 == null, g1.?, g0 orelse 0xdead });

    var it: Iter = .{ .n = 6 };
    var squares: u64 = 0;
    while (it.next()) |v| squares += v;
    std.debug.print("iter {}\n", .{squares});

    // Promoted variable: the last match.
    var last: ?usize = null;
    for (xs, 0..) |x, i| {
        if (x > 4) last = i;
    }
    std.debug.print("last {?}\n", .{last});

    // In arrays, slices and auto structs.
    var arr: [5]?u64 = .{ 1, null, 3, null, 5 };
    arr[1] = addOpt(arr[0], arr[2]);
    var present: u64 = 0;
    for (arr) |a| present += a orelse 100;
    const sl: []?u64 = arr[1..4];
    sl[2] = sl[0];
    std.debug.print("arr {} {?} {?}\n", .{ present, arr[3], sl[1] });

    const ss = [_]S{
        .{ .a = 4, .b = 1, .c = null },
        .{ .a = null, .b = 2, .c = -10 },
        .{ .a = 6, .b = 3, .c = 20 },
    };
    std.debug.print("structs {}\n", .{sumStructs(&ss)});
}
