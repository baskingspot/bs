//! exit: 120
//! stdout: "2432902008176640000\n1245\n15\n10\nnull\n5\nodd\n-3\n-4\n-1\n1\n-4\n-1\n2\n-16\n281474976645119\n1\n127\n0\n8\n123\nbXd\n706\n"
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const Big = struct { a: u64, b: u64, c: u32, d: u8 };

var global: Big = .{ .a = 1, .b = 2, .c = 3, .d = 4 };
var table = [_]i16{ -5, 7, -9, 11 };

fn fact(n: u64) u64 {
    return if (n <= 1) 1 else n * fact(n - 1);
}

fn makeBig(x: u64) Big {
    return .{ .a = x, .b = x * 2, .c = @intCast(x + 1), .d = @truncate(x) };
}

fn maybeBig(x: u64) ?Big {
    return if (x == 0) null else makeBig(x);
}

const E = error{Odd};

fn halve(x: u32) E!struct { q: u32, r: u32 } {
    if (x % 2 == 1) return error.Odd;
    return .{ .q = x / 2, .r = 0 };
}

const Node = struct { val: u32, next: ?*const Node };

fn sumList(head: ?*const Node) u32 {
    var total: u32 = 0;
    var it = head;
    while (it) |n| : (it = n.next) total += n.val;
    return total;
}

fn printSigned(x: i64) void {
    if (x < 0) {
        rt.print("-");
        rt.printInt(@intCast(-x));
    } else rt.printInt(@intCast(x));
}

fn main() callconv(.c) noreturn {
    rt.printInt(fact(20));
    const big = makeBig(300);
    rt.printInt(big.a + big.b + big.c + big.d);
    global.c += 10;
    global = .{ .a = global.a + 1, .b = global.b, .c = global.c, .d = global.d };
    rt.printInt(global.a + global.c);
    if (maybeBig(5)) |m| rt.printInt(m.b);
    if (maybeBig(0) == null) rt.print("null\n");
    if (halve(10)) |h| rt.printInt(h.q) else |_| rt.print("odd\n");
    _ = halve(7) catch |err| {
        if (err == error.Odd) rt.print("odd\n");
    };

    var a: i32 = -7;
    var b: i32 = 2;
    _ = &a;
    _ = &b;
    printSigned(@divTrunc(a, b));
    printSigned(@divFloor(a, b));
    printSigned(@rem(a, b));
    printSigned(@mod(a, b));
    printSigned(@divFloor(-a, -b));
    printSigned(@mod(-a, -b));

    var s7: u7 = 120;
    s7 +%= 10;
    rt.printInt(s7);
    var v5: i5 = 15;
    v5 +%= 1;
    printSigned(v5);
    var w: u64 = 0xffff_ffff_ffff;
    _ = &w;
    rt.printInt(w *% 0x10001);
    const ov = @mulWithOverflow(@as(u64, 1) << 40, w);
    rt.printInt(ov[1]);
    const ov2 = @addWithOverflow(@as(i8, 100), @as(i8, 27));
    printSigned(ov2[0]);
    rt.printInt(ov2[1]);

    for (&table) |*t| t.* *= 2;
    var acc: i64 = 0;
    for (table) |t| acc += t;
    printSigned(acc);

    const n3: Node = .{ .val = 3, .next = null };
    const n2: Node = .{ .val = 20, .next = &n3 };
    var n1: Node = .{ .val = 100, .next = &n2 };
    _ = &n1;
    rt.printInt(sumList(&n1));

    var bytes = [_]u8{ 'a', 'b', 'c', 'd', 'e' };
    const mp: [*]u8 = &bytes;
    const addr = @intFromPtr(mp);
    const p2: *u8 = @ptrFromInt(addr + 2);
    p2.* = 'X';
    rt.print(mp[1..4]);
    rt.print("\n");

    const r = outer: {
        var i: u32 = 0;
        while (true) : (i += 1) {
            var j: u32 = 0;
            while (j < i) : (j += 1) {
                if (i * j == 42) break :outer i * 100 + j;
            }
        }
    };
    rt.printInt(r);
    rt.exit(@truncate(fact(5)));
}
