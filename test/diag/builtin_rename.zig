const E = enum { a, b };

pub fn main() void {
    const e: E = @intToEnum(E, 1);
    _ = e;
}

// error
// builtin_rename.zig:4:18: error[unknown-builtin]: invalid builtin function: '@intToEnum'
//   | const e: E = @intToEnum(E, 1);
//   hint: renamed to @enumFromInt, which takes its type from the result: `@as(E, @enumFromInt(x))`
//   fix builtin_rename.zig:4:18-4:34: "@as(E, @enumFromInt(1))"
// 1 error
