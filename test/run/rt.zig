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
