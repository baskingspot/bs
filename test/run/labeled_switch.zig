//! exit: 0
//! stdout: "521\n54\n521\n3\n111\n319\n6765\n212\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;
pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}
var input: []const u8 = "ab1c22d";
const Tok = union(enum) { num: u32, done: void, skip: u8 };
fn countDigits(s: []const u8) u32 {
    var i: usize = 0;
    var n: u32 = 0;
    return state: switch (@as(u8, if (s.len == 0) 0 else s[0])) {
        0 => n,
        '0'...'9' => {
            n += 1;
            i += 1;
            continue :state if (i < s.len) s[i] else 0;
        },
        else => {
            i += 1;
            continue :state if (i < s.len) s[i] else 0;
        },
    };
}
fn collatz(x0: u32) u32 {
    var steps: u32 = 0;
    var x = x0;
    sw: switch (x % 2) {
        0 => {
            if (x == 1) break :sw;
            x /= 2;
            steps += 1;
            continue :sw x % 2;
        },
        else => {
            if (x == 1) break :sw;
            x = 3 * x + 1;
            steps += 1;
            continue :sw x % 2;
        },
    }
    return steps;
}
fn tokens(t0: Tok) u32 {
    var total: u32 = 0;
    var budget: u8 = 3;
    sw: switch (t0) {
        .num => |v| {
            total += v;
            continue :sw .{ .skip = 1 };
        },
        .skip => |k| {
            total += k * 100;
            budget -= 1;
            if (budget == 0) continue :sw .done;
            continue :sw .{ .num = 7 };
        },
        .done => break :sw,
    }
    return total;
}
fn ctFib(comptime n: u32) u32 {
    var a: u32 = 0;
    var b: u32 = 1;
    var i: u32 = 0;
    return s: switch (i < n) {
        true => {
            const t = a + b;
            a = b;
            b = t;
            i += 1;
            continue :s i < n;
        },
        false => a,
    };
}
const E = enum { a, b, c, d };
fn nested(e0: E) u32 {
    var acc: u32 = 0;
    outer: switch (e0) {
        .a => {
            acc += 1;
            inner: switch (acc) {
                1 => continue :inner 2,
                2 => continue :outer .b,
                else => break :inner,
            }
            continue :outer .d;
        },
        .b => {
            acc += 20;
            continue :outer .c;
        },
        inline .c, .d => |t| {
            acc += @as(u32, @backingInt(t)) * 100;
            if (t == .d) break :outer;
            continue :outer .d;
        },
    }
    return acc;
}
fn errLoop(n: u8) u8 {
    var hits: u8 = 0;
    return sw: switch (@as(anyerror, error.A)) {
        error.A => {
            hits += 1;
            if (hits < n) continue :sw error.A;
            continue :sw error.B;
        },
        else => break :sw hits + 50,
    };
}
fn main() callconv(.c) noreturn {
    var e: E = .a;
    _ = &e;
    rt.printInt(nested(e));
    rt.printInt(errLoop(4));
    rt.printInt(comptime nested(.a));
    rt.printInt(countDigits(input));
    rt.printInt(collatz(27));
    var t: Tok = .{ .num = 5 };
    _ = &t;
    rt.printInt(tokens(t));
    rt.printInt(comptime ctFib(20));
    var outer: u32 = 0;
    var k: u32 = 0;
    while (k < 3) : (k += 1) {
        sw: switch (k) {
            1 => {
                outer += 10;
                continue :sw 5;
            },
            5 => continue,
            else => outer += 1,
        }
        outer += 100;
    }
    rt.printInt(outer);
    rt.exit(0);
}
