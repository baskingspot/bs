//! Minimal runtime shared by the run tests: raw Linux syscalls, no std.

pub fn write(fd: usize, buf: []const u8) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (1),
          [arg1] "{rdi}" (fd),
          [arg2] "{rsi}" (@intFromPtr(buf.ptr)),
          [arg3] "{rdx}" (buf.len),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn print(s: []const u8) void {
    _ = write(1, s);
}

/// Prints `n` in decimal followed by a newline.
pub fn printInt(n: u64) void {
    var buf: [21]u8 = undefined;
    var i: usize = buf.len;
    i -= 1;
    buf[i] = '\n';
    var v = n;
    while (true) {
        i -= 1;
        buf[i] = @intCast('0' + v % 10);
        v /= 10;
        if (v == 0) break;
    }
    print(buf[i..]);
}

pub fn exit(code: u8) noreturn {
    asm volatile ("syscall"
        :
        : [number] "{rax}" (231),
          [arg1] "{rdi}" (code),
        : .{ .rcx = true, .r11 = true, .memory = true });
    unreachable;
}

/// A minimal panic handler for programs without std, with the API of
/// `std.debug.FullPanic` and its messages: writes `panic: <message>` to
/// stderr and raises SIGABRT. A program selects it, under bs and upstream
/// alike, with `pub const panic = rt.panic;` in its root file.
pub const panic = struct {
    pub fn call(msg: []const u8, _: ?usize) noreturn {
        fail(&.{msg});
    }
    pub fn sentinelMismatch(expected: anytype, found: @TypeOf(expected)) noreturn {
        const T = @TypeOf(expected);
        if (@typeInfo(T) == .int and @typeInfo(T).int.signedness == .unsigned and @bitSizeOf(T) <= 64) {
            var e: [20]u8 = undefined;
            var f: [20]u8 = undefined;
            fail(&.{ "sentinel mismatch: expected ", dec(&e, expected), ", found ", dec(&f, found) });
        }
        fail(&.{"sentinel mismatch"});
    }
    pub fn unwrapError(err: anyerror) noreturn {
        fail(&.{ "attempt to unwrap error: ", @errorName(err) });
    }
    pub fn outOfBounds(index: usize, len: usize) noreturn {
        var i: [20]u8 = undefined;
        var l: [20]u8 = undefined;
        fail(&.{ "index out of bounds: index ", dec(&i, index), ", len ", dec(&l, len) });
    }
    pub fn startGreaterThanEnd(start: usize, end: usize) noreturn {
        var s: [20]u8 = undefined;
        var e: [20]u8 = undefined;
        fail(&.{ "start index ", dec(&s, start), " is larger than end index ", dec(&e, end) });
    }
    pub fn inactiveUnionField(active: anytype, accessed: @TypeOf(active)) noreturn {
        fail(&.{ "access of union field '", @tagName(accessed), "' while field '", @tagName(active), "' is active" });
    }
    pub fn sliceCastLenRemainder(src_len: usize) noreturn {
        var l: [20]u8 = undefined;
        fail(&.{ "slice length '", dec(&l, src_len), "' does not divide exactly into destination elements" });
    }
    pub fn reachedUnreachable() noreturn {
        fail(&.{"reached unreachable code"});
    }
    pub fn unwrapNull() noreturn {
        fail(&.{"attempt to use null value"});
    }
    pub fn castToNull() noreturn {
        fail(&.{"cast causes pointer to be null"});
    }
    pub fn incorrectAlignment() noreturn {
        fail(&.{"incorrect alignment"});
    }
    pub fn invalidErrorCode() noreturn {
        fail(&.{"invalid error code"});
    }
    pub fn unexpectedErrorCode(err: anyerror) noreturn {
        fail(&.{ "unexpected error code, found error.", @errorName(err) });
    }
    pub fn integerOutOfBounds() noreturn {
        fail(&.{"integer does not fit in destination type"});
    }
    pub fn integerOverflow() noreturn {
        fail(&.{"integer overflow"});
    }
    pub fn shlOverflow() noreturn {
        fail(&.{"left shift overflowed bits"});
    }
    pub fn shrOverflow() noreturn {
        fail(&.{"right shift overflowed bits"});
    }
    pub fn divideByZero() noreturn {
        fail(&.{"division by zero"});
    }
    pub fn exactDivisionRemainder() noreturn {
        fail(&.{"exact division produced remainder"});
    }
    pub fn integerPartOutOfBounds() noreturn {
        fail(&.{"integer part of floating point value out of bounds"});
    }
    pub fn corruptSwitch() noreturn {
        fail(&.{"switch on corrupt value"});
    }
    pub fn shiftRhsTooBig() noreturn {
        fail(&.{"shift amount is greater than the type size"});
    }
    pub fn invalidEnumValue() noreturn {
        fail(&.{"invalid enum value"});
    }
    pub fn forLenMismatch() noreturn {
        fail(&.{"for loop over objects with non-equal lengths"});
    }
    pub fn copyLenMismatch() noreturn {
        fail(&.{"source and destination arguments have non-equal lengths"});
    }
    pub fn memcpyAlias() noreturn {
        fail(&.{"@memcpy arguments alias"});
    }
    pub fn noreturnReturned() noreturn {
        fail(&.{"'noreturn' function returned"});
    }
    pub fn loadUninstantiableType() noreturn {
        fail(&.{"attempt to load uninstantiable type"});
    }

    fn dec(buf: *[20]u8, n: u64) []const u8 {
        var i: usize = buf.len;
        var v = n;
        while (true) {
            i -= 1;
            buf[i] = @intCast('0' + v % 10);
            v /= 10;
            if (v == 0) break;
        }
        return buf[i..];
    }

    fn fail(parts: []const []const u8) noreturn {
        _ = write(2, "panic: ");
        for (parts) |p| _ = write(2, p);
        _ = write(2, "\n");
        // kill(getpid(), SIGABRT)
        const pid = asm volatile ("syscall"
            : [ret] "={rax}" (-> usize),
            : [number] "{rax}" (39),
            : .{ .rcx = true, .r11 = true, .memory = true });
        _ = asm volatile ("syscall"
            : [ret] "={rax}" (-> usize),
            : [number] "{rax}" (62),
              [arg1] "{rdi}" (pid),
              [arg2] "{rsi}" (6),
            : .{ .rcx = true, .r11 = true, .memory = true });
        exit(134);
    }
};
