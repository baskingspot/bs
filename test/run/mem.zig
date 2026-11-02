//! exit: 0
//! stdout: "hello\n3\nxxxxxhello\n4\n9\n0\nabcabcdefg\nbcdefgg\n10\n"
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const Pair = struct { a: u32, b: u16 };

fn comptimeSum() u32 {
    var buf: [4]u32 = undefined;
    @memset(&buf, 2);
    var src = [_]u32{ 1, 2, 3 };
    @memcpy(buf[1..], &src);
    @memmove(buf[0..3], buf[1..4]);
    return buf[0] + buf[1] + buf[2] + buf[3];
}

fn main() callconv(.c) noreturn {
    var dst: [10]u8 = undefined;
    const msg = "hello";
    var n: usize = 5;
    _ = &n;
    // Runtime length through a slice; a many-pointer source.
    @memcpy(dst[0..n], msg.ptr);
    rt.print(dst[0..5]);
    rt.print("\n");

    // Multi-byte elements with a runtime count.
    var pairs: [6]Pair = undefined;
    @memset(pairs[0..n], .{ .a = 3, .b = 4 });
    rt.printInt(pairs[4].a);

    @memset(dst[0..5], 'x');
    @memcpy(dst[5..], msg);
    rt.print(&dst);
    rt.print("\n");
    rt.printInt(pairs[0].b);

    rt.printInt(comptime comptimeSum());
    var empty: [0]u8 = .{};
    @memset(&empty, 1);
    rt.printInt(empty.len);

    // Overlapping moves in both directions.
    var m = "abcdefg_____".*;
    @memmove(m[3..10], m[0..7]);
    rt.print(m[0..10]);
    rt.print("\n");
    var k = "abcdefg".*;
    @memmove(k[0..6], k[1..7]);
    rt.print(&k);
    rt.print("\n");

    var big: [300]u8 = undefined;
    @memset(&big, 7);
    var big2: [300]u8 = undefined;
    big2 = big;
    rt.printInt(big2[299] + big2[0] - 4);
    rt.exit(0);
}
