const E = enum(u32) { a, b, c };
const Empty = enum {};

export fn backing(x: u64) E {
    return @fromBackingInt(x);
}

export fn undef() void {
    const e: E = @enumFromInt(@as(u8, undefined));
    _ = e;
}

export fn empty() void {
    const e: Empty = @enumFromInt(0);
    _ = e;
}

pub fn main() void {}

// error
// enum_from_int.zig:5:28: error[type-mismatch]: expected type 'u32', found 'u64'
//   | return @fromBackingInt(x);
//   note enum_from_int.zig:5:28: unsigned 32-bit int cannot represent all possible unsigned 64-bit values
//   fix? enum_from_int.zig:5:28-5:29: "@intCast(x)"
// enum_from_int.zig:9:31: error[undefined-value]: use of undefined value here causes illegal behavior
//   | const e: E = @enumFromInt(@as(u8, undefined));
// enum_from_int.zig:14:22: error[lossy-conversion]: enum 'enum_from_int.Empty' has no tag with value '0'
//   | const e: Empty = @enumFromInt(0);
//   note enum_from_int.zig:2:15: enum declared here: const Empty = enum {};
// 3 errors
