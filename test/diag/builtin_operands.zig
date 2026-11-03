const S = extern struct { x: u32 };
const E = enum(u8) { a, b, _ };
const U = union(E) { a, b };

fn copy(dest: [*]u8, source: [*]const u8) void {
    @memcpy(dest, source);
}

fn backing(s: S) u32 {
    return @backingInt(s);
}

fn toUnion() U {
    const e: E = @enumFromInt(15);
    return e;
}

fn reify() type {
    return @Int(0, 8);
}

pub fn main() void {
    var buf: [4]u8 = undefined;
    copy(&buf, &buf);
    _ = backing(.{ .x = 1 });
    _ = toUnion();
    _ = reify();
}

// error
// builtin_operands.zig:19:17: error[type-mismatch]: expected type 'lang.Signedness', found 'comptime_int'
//   | return @Int(0, 8);
//   note std/lang.zig:967:24: enum declared here: pub const Signedness = enum(u1) {
//   call: builtin_operands.zig:27:14 comptime
// builtin_operands.zig:6:5: error[unknown-length]: unknown copy length
//   | @memcpy(dest, source);
//   note builtin_operands.zig:6:13: destination type '[*]u8' provides no length
//   note builtin_operands.zig:6:19: source type '[*]const u8' provides no length
//   ref: main builtin_operands.zig:24:9 (+3 std frames)
// builtin_operands.zig:10:24: error[bad-cast]: non-packed struct 'builtin_operands.S' does not have a backing integer
//   | return @backingInt(s);
//   note builtin_operands.zig:1:18: struct declared here: const S = extern struct { x: u32 };
//   ref: main builtin_operands.zig:25:16 (+3 std frames)
// builtin_operands.zig:15:12: error[lossy-conversion]: union 'builtin_operands.U' has no tag with value '@fromBackingInt(15)'
//   | return e;
//   note builtin_operands.zig:3:11: union declared here: const U = union(E) { a, b };
//   ref: main builtin_operands.zig:26:16 (+3 std frames)
// 4 errors
