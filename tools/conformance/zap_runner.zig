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

/// A minimal panic handler, like upstream's API but without formatting:
/// writes `panic: <message>` to stderr and raises SIGABRT. As the root, the
/// runner chooses it for every test.
pub const panic = struct {
    pub fn call(msg: []const u8, _: ?usize) noreturn {
        _ = syscall3(1, 2, @intFromPtr("panic: ".ptr), "panic: ".len);
        _ = syscall3(1, 2, @intFromPtr(msg.ptr), msg.len);
        _ = syscall3(1, 2, @intFromPtr("\n".ptr), 1);
        _ = syscall3(62, syscall3(39, 0, 0, 0), 6, 0); // kill(getpid(), SIGABRT)
        exit(134);
    }
    pub fn sentinelMismatch(expected: anytype, found: @TypeOf(expected)) noreturn {
        _ = .{ expected, found };
        call("sentinel mismatch", null);
    }
    pub fn unwrapError(err: anyerror) noreturn {
        call(@errorName(err), null);
    }
    pub fn outOfBounds(index: usize, len: usize) noreturn {
        _ = .{ index, len };
        call("index out of bounds", null);
    }
    pub fn startGreaterThanEnd(start: usize, end: usize) noreturn {
        _ = .{ start, end };
        call("start index is larger than end index", null);
    }
    pub fn inactiveUnionField(active: anytype, accessed: @TypeOf(active)) noreturn {
        _ = .{ active, accessed };
        call("access of inactive union field", null);
    }
    pub fn sliceCastLenRemainder(src_len: usize) noreturn {
        _ = src_len;
        call("slice length does not divide exactly into destination elements", null);
    }
    pub fn reachedUnreachable() noreturn {
        call("reached unreachable code", null);
    }
    pub fn unwrapNull() noreturn {
        call("attempt to use null value", null);
    }
    pub fn castToNull() noreturn {
        call("cast causes pointer to be null", null);
    }
    pub fn incorrectAlignment() noreturn {
        call("incorrect alignment", null);
    }
    pub fn invalidErrorCode() noreturn {
        call("invalid error code", null);
    }
    pub fn unexpectedErrorCode(err: anyerror) noreturn {
        call(@errorName(err), null);
    }
    pub fn integerOutOfBounds() noreturn {
        call("integer does not fit in destination type", null);
    }
    pub fn integerOverflow() noreturn {
        call("integer overflow", null);
    }
    pub fn shlOverflow() noreturn {
        call("left shift overflowed bits", null);
    }
    pub fn shrOverflow() noreturn {
        call("right shift overflowed bits", null);
    }
    pub fn divideByZero() noreturn {
        call("division by zero", null);
    }
    pub fn exactDivisionRemainder() noreturn {
        call("exact division produced remainder", null);
    }
    pub fn integerPartOutOfBounds() noreturn {
        call("integer part of floating point value out of bounds", null);
    }
    pub fn corruptSwitch() noreturn {
        call("switch on corrupt value", null);
    }
    pub fn shiftRhsTooBig() noreturn {
        call("shift amount is greater than the type size", null);
    }
    pub fn invalidEnumValue() noreturn {
        call("invalid enum value", null);
    }
    pub fn forLenMismatch() noreturn {
        call("for loop over objects with non-equal lengths", null);
    }
    pub fn copyLenMismatch() noreturn {
        call("source and destination arguments have non-equal lengths", null);
    }
    pub fn memcpyAlias() noreturn {
        call("@memcpy arguments alias", null);
    }
    pub fn noreturnReturned() noreturn {
        call("'noreturn' function returned", null);
    }
    pub fn loadUninstantiableType() noreturn {
        call("attempt to load uninstantiable type", null);
    }
};

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
