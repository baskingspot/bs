const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const Vec = struct {
    x: i32,
    y: i32,
    tag: u8 = 'v',

    fn add(a: Vec, b: Vec) Vec {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    fn scale(self: *Vec, k: i32) void {
        self.x *= k;
        self.y *= k;
    }

    fn len2(self: Vec) i32 {
        return self.x * self.x + self.y * self.y;
    }
};

const Rect = struct { min: Vec, max: Vec };

fn sumSlice(xs: []const u32) u32 {
    var s: u32 = 0;
    for (xs) |x| s += x;
    return s;
}

fn fill(p: [*]u8, n: usize, c: u8) void {
    var i: usize = 0;
    while (i < n) : (i += 1) p[i] = c;
}

fn swap(a: *u32, b: *u32) void {
    const t = a.*;
    a.* = b.*;
    b.* = t;
}

fn main() callconv(.c) noreturn {
    var v: Vec = .{ .x = 1, .y = 2 };
    v.scale(3);
    const w = v.add(.{ .x = 1, .y = 1 });
    rt.printInt(@intCast(w.len2()));
    rt.printInt(w.tag);

    var r: Rect = .{ .min = .{ .x = 0, .y = 0 }, .max = w };
    r.max.y += 10;
    rt.printInt(@intCast(r.max.y - r.min.y));

    var arr = [_]u32{ 1, 2, 3, 4, 5 };
    arr[2] = 30;
    rt.printInt(sumSlice(&arr));
    rt.printInt(sumSlice(arr[1..3]));
    const s: []u32 = arr[0..];
    s[4] += 100;
    rt.printInt(arr[4]);
    rt.printInt(s.len);
    swap(&arr[0], &arr[1]);
    rt.printInt(arr[0] * 10 + arr[1]);

    var buf: [8]u8 = undefined;
    fill(&buf, buf.len, 'z');
    buf[7] = '\n';
    rt.print(&buf);
    const msg = "abc\n";
    rt.print(msg[1..]);

    var grid: [2][3]u8 = .{ .{ 1, 2, 3 }, .{ 4, 5, 6 } };
    grid[1][2] = 60;
    var t: u32 = 0;
    for (grid) |row| {
        for (row) |c| t += c;
    }
    rt.printInt(t);

    const p: *const [5]u32 = &arr;
    const mp: [*]const u32 = p;
    rt.printInt(mp[3] + p.len);
    rt.exit(@intCast(arr.len));
}
