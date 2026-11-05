// A type named by the error is noted once, as upstream.
const S = struct { a: u8 };
const E = error{ A, B };

fn tryStruct() u8 {
    const s = try S{ .a = 1 };
    return s.a;
}

fn unwrapStruct() u8 {
    return (S{ .a = 2 }).?.a;
}

fn unwrapTypeInfo() void {
    _ = @typeInfo(E).error_set.?;
}

pub fn main() void {
    _ = tryStruct();
    _ = unwrapStruct();
    unwrapTypeInfo();
}

// error
// declared_once.zig:6:20: error[operand-type]: expected error union type, found 'declared_once.S'
//   | const s = try S{ .a = 1 };
//   note declared_once.zig:2:11: struct declared here: const S = struct { a: u8 };
//   note declared_once.zig:6:20: consider omitting 'try'
//   fix? declared_once.zig:6:15-6:19: ""
//   ref: main declared_once.zig:19:18 (+3 std frames)
// declared_once.zig:11:25: error[operand-type]: expected optional type, found 'declared_once.S'
//   | return (S{ .a = 2 }).?.a;
//   note declared_once.zig:2:11: struct declared here: const S = struct { a: u8 };
//   ref: main declared_once.zig:20:21 (+3 std frames)
// declared_once.zig:15:31: error[operand-type]: expected optional type, found 'lang.Type.ErrorSet'
//   | _ = @typeInfo(E).error_set.?;
//   note std/lang.zig:801:26: struct declared here: pub const ErrorSet = struct {
//   ref: main declared_once.zig:21:19 (+3 std frames)
// 3 errors
