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
    rt.exit(if (b) 3 else 4);
}
