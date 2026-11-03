//! exit: 3
//! stdout: "84\n14\n10\n137\n28\n30\n8\n3\n11\n9\n6\n1\n213\n20\n99\n20\n0\n"
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var counter: u32 = 0;

fn bump(n: u32) void {
    counter += n;
}

/// An `inline for` left by a break inside runtime control flow yields the
/// runtime-selected value, not the first iteration's.
fn pickTen(x: u32) u32 {
    return inline for (.{ 1, 2, 3 }) |v| {
        if (x == v) break v * 10;
    } else 99;
}
fn pickOrNull(x: u32) ?u32 {
    const r: u32 = inline for (.{ 1, 2, 3 }) |v| {
        if (x == v) break v * 10;
    } else return null;
    return r;
}

/// A 32-bit switch whose ranges cover every value needs no else.
fn unitKind(x: u32) u8 {
    return switch (x) {
        0...0xfffffff0 - 1 => 1,
        0xfffffff0...0xffffffff - 1 => 2,
        0xffffffff => 3,
    };
}

fn classify(x: u8) u8 {
    return switch (x) {
        0 => 10,
        1, 2 => 20,
        3...9 => |v| v + 100,
        else => 0,
    };
}

fn deferOrder() u32 {
    var r: u32 = 1;
    {
        defer r = r * 10;
        defer r += 2;
    }
    return r;
}

fn main() callconv(.c) noreturn {
    // while with continue expression and labeled loops
    var total: u32 = 0;
    var i: u32 = 0;
    outer: while (i < 10) : (i += 1) {
        var j: u32 = 0;
        while (j < 10) : (j += 1) {
            if (j > i) continue :outer;
            if (i == 8) break :outer;
            total += j;
        }
    }
    rt.printInt(total);

    // for over arrays, slices and ranges with index captures
    const arr = [_]u16{ 3, 1, 4, 1, 5, 9, 2, 6 };
    var sum: u32 = 0;
    for (arr, 0..) |x, idx| {
        if (idx % 2 == 0) sum += x;
    }
    rt.printInt(sum);
    for (0..5) |k| bump(@intCast(k));
    rt.printInt(counter);

    // switch
    rt.printInt(classify(0) + classify(2) + classify(7) + classify(200));

    // labeled block
    const v = blk: {
        if (sum > 5) break :blk sum * 2;
        break :blk 0;
    };
    rt.printInt(v);

    // defer runs at scope exit in reverse order
    rt.printInt(deferOrder());

    // while with else, for with break value
    var n: u32 = 0;
    const found = while (n < 100) : (n += 1) {
        if (n * n > 50) break n;
    } else 0;
    rt.printInt(found);
    const firstOdd = for (arr) |x| {
        if (x % 2 == 1) break x;
    } else 0;
    rt.printInt(firstOdd);

    var b = false;
    if (!b and total > 3) b = true;

    // Switch prongs capturing by reference.
    var us = [_]RefU{ .{ .a = 1 }, .{ .b = .{ 1, 2 } }, .c };
    for (&us) |*u| bumpRef(u);
    rt.printInt(us[0].a);
    rt.printInt(us[1].b[1]);
    var sn: u8 = 3;
    switch (sn) {
        0...5 => |*p| p.* *= 2,
        else => |*p| p.* = 0,
    }
    rt.printInt(sn);
    // A const destructured from a comptime-selected prong stays
    // comptime-known.
    rt.printInt(leb(false, 9));
    var unit_len: u32 = 0xffffffff;
    _ = &unit_len;
    rt.printInt(unitKind(unit_len) + unitKind(5) * 10 + unitKind(0xfffffff5) * 100);
    var two: u32 = 2;
    _ = &two;
    rt.printInt(pickTen(two));
    rt.printInt(pickTen(7));
    rt.printInt(pickOrNull(two) orelse 0);
    rt.printInt(pickOrNull(7) orelse 0);
    rt.exit(if (b) 3 else 4);
}

const RefU = union(enum) { a: u32, b: [2]u8, c: void };
fn bumpRef(u: *RefU) void {
    switch (u.*) {
        .a => |*x| x.* += 10,
        .b => |*arr| arr[1] = 9,
        .c => {},
    }
}

fn leb(comptime signed: bool, b: u8) u32 {
    const allowed: u7, var fits: bool = switch (signed) {
        false => blk: {
            const ok = b >> 3 == 0;
            break :blk .{ 0, ok };
        },
        true => .{ 5, b == 1 },
    };
    if (!signed) comptime {
        if (allowed != 0) unreachable;
    };
    fits = !fits;
    return @intFromBool(fits) + allowed;
}
