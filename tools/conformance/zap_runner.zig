//! A smaller test runner for zap's conformance harness (`run.py
//! --test-runner`). It speaks the same `@zap-test` line protocol as
//! `test_runner.zig` (documented there) but needs no std: its own `_start`,
//! raw `write` and `exit` system calls, and `builtin.test_functions`. It does
//! not set up `std.testing.allocator` or `std.testing.io`, so tests that use
//! them crash under it, and it reports a failing test without its error name.
//!
//! Upstream zig 0.17.0 compiles it too, which keeps it honest.

const builtin = @import("builtin");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ xorl %%ebp, %%ebp
        \\ movq %%rsp, %%rdi
        \\ andq $-16, %%rsp
        \\ call %[main:P]
        :
        : [main] "X" (&main),
    );
}

fn main(sp: [*]const usize) callconv(.c) noreturn {
    const argc = sp[0];
    const argv: [*]const [*:0]const u8 = @ptrCast(sp + 1);
    var start: usize = 0;
    var a: usize = 1;
    while (a < argc) : (a += 1) {
        if (parseStart(argv[a])) |n| start = n;
    }

    const tests = builtin.test_functions;
    var l: Line = .{};
    l.add("v1 ");
    l.int(tests.len);
    l.add(" ");
    l.add(@tagName(builtin.zig_backend));
    l.flush(1);
    var i = start;
    while (i < tests.len) : (i += 1) {
        l.add("start ");
        l.int(i);
        l.add(" ");
        l.add(tests[i].name);
        // Also on stderr, so the harness can cut out a crashing test's panic message.
        l.write(2);
        l.flush(1);
        if (tests[i].func()) |_| {
            l.add("pass ");
        } else |err| {
            l.add(if (err == error.SkipZigTest) "skip " else "fail ");
        }
        l.int(i);
        l.flush(1);
    }
    l.add("done");
    l.flush(1);
    exit(0);
}

/// The index in `--start=<index>`, or null for any other argument.
fn parseStart(arg: [*:0]const u8) ?usize {
    const prefix = "--start=";
    var k: usize = 0;
    while (k < prefix.len) : (k += 1) {
        if (arg[k] != prefix[k]) return null;
    }
    var n: usize = 0;
    while (arg[k] != 0) : (k += 1) n = n * 10 + (arg[k] - '0');
    return n;
}

/// One protocol line, written with a single system call.
const Line = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    fn add(l: *Line, s: []const u8) void {
        if (l.len == 0) l.raw("@zap-test ");
        l.raw(s);
    }

    fn raw(l: *Line, s: []const u8) void {
        // Keep room for the newline if a long test name is truncated.
        for (s) |c| {
            if (l.len == l.buf.len - 1) return;
            l.buf[l.len] = c;
            l.len += 1;
        }
    }

    fn int(l: *Line, value: usize) void {
        var digits: [20]u8 = undefined;
        var n: usize = 0;
        var v = value;
        while (true) {
            digits[digits.len - 1 - n] = @intCast('0' + v % 10);
            n += 1;
            v /= 10;
            if (v == 0) break;
        }
        l.add(digits[digits.len - n ..]);
    }

    /// Writes the line to `fd` and keeps it.
    fn write(l: *Line, fd: usize) void {
        l.buf[l.len] = '\n';
        var off: usize = 0;
        while (off < l.len + 1) {
            const rc = syscall3(1, fd, @intFromPtr(&l.buf) + off, l.len + 1 - off);
            if (@as(isize, @bitCast(rc)) <= 0) return;
            off += rc;
        }
    }

    fn flush(l: *Line, fd: usize) void {
        l.write(fd);
        l.len = 0;
    }
};

fn exit(code: usize) noreturn {
    _ = syscall3(231, code, 0, 0);
    unreachable;
}

fn syscall3(number: usize, arg1: usize, arg2: usize, arg3: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
        : .{ .rcx = true, .r11 = true, .memory = true });
}
