const E = enum { a, b };

fn cold() void {
    @setCold(true);
}

pub fn main() void {
    const e: E = @intToEnum(E, 1);
    _ = e;
    cold();
}

// error
// builtin_rename.zig:4:5: error[unknown-builtin]: invalid builtin function: '@setCold'
//   | @setCold(true);
//   hint: use `@branchHint(.cold);` as the first statement of the function
//   fix builtin_rename.zig:4:5-4:19: "@branchHint(.cold)"
// builtin_rename.zig:8:18: error[unknown-builtin]: invalid builtin function: '@intToEnum'
//   | const e: E = @intToEnum(E, 1);
//   hint: renamed to @enumFromInt, which takes its type from the result: `@as(E, @enumFromInt(x))`
//   fix builtin_rename.zig:8:18-8:34: "@as(E, @enumFromInt(1))"
// 2 errors
