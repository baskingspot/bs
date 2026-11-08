//! test_runner.zig for upstream 0.16.0's std (`run.py --zig-version 0.16`):
//! the same `@bs-test` line protocol and per-test setup, with 0.16's
//! `std.testing` (`DebugAllocator`'s `.{}` and `.leak`) as 0.16's
//! lib/compiler/test_runner.zig sets it up. See test_runner.zig.

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;

pub fn main(init: std.process.Init.Minimal) void {
    var start: usize = 0;
    for (init.args.vector[1..]) |arg_z| {
        const arg = std.mem.sliceTo(arg_z, 0);
        if (std.mem.startsWith(u8, arg, "--start=")) {
            start = parseIndex(arg["--start=".len..]);
        }
    }

    const tests = builtin.test_functions;
    var buf: [32]u8 = undefined;
    line(&.{ "v1 ", fmtIndex(&buf, tests.len), " ", @tagName(builtin.zig_backend) });
    var i = start;
    while (i < tests.len) : (i += 1) {
        const test_fn = tests[i];
        const index = fmtIndex(&buf, i);
        line(&.{ "start ", index, " ", test_fn.name });
        // Also on stderr, so the harness can cut out a crashing test's panic message.
        lineTo(2, &.{ "start ", index, " ", test_fn.name });

        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        testing.log_level = .warn;
        testing.environ = init.environ;

        const result = test_fn.func();

        testing.io_instance.deinit();
        const leaked = testing.allocator_instance.deinit() == .leak;

        if (result) |_| {
            line(&.{ if (leaked) "leak " else "pass ", index });
        } else |err| switch (err) {
            error.SkipZigTest => line(&.{ "skip ", index }),
            else => line(&.{ "fail ", index, " ", @errorName(err) }),
        }
    }
    line(&.{"done"});
}

fn line(parts: []const []const u8) void {
    lineTo(1, parts);
}

fn lineTo(fd: std.posix.fd_t, parts: []const []const u8) void {
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    append(&buf, &len, "@bs-test ");
    for (parts) |part| append(&buf, &len, part);
    // Keep the newline even if a long test name was truncated.
    if (len == buf.len) len -= 1;
    append(&buf, &len, "\n");
    writeAll(fd, buf[0..len]);
}

fn append(buf: *[4096]u8, len: *usize, part: []const u8) void {
    const n = @min(part.len, buf.len - len.*);
    @memcpy(buf[len.*..][0..n], part[0..n]);
    len.* += n;
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const rc = std.posix.system.write(fd, rest.ptr, rest.len);
        const n: isize = @bitCast(rc);
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}

fn fmtIndex(buf: *[32]u8, value: usize) []const u8 {
    var i: usize = buf.len;
    var v = value;
    while (true) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
        if (v == 0) break;
    }
    return buf[i..];
}

fn parseIndex(s: []const u8) usize {
    var v: usize = 0;
    for (s) |c| v = v * 10 + (c - '0');
    return v;
}
