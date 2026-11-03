const S = struct { x: u64, n: noreturn };
const U = union { a: S, b: u32 };
const V = union { a: S, b: noreturn };

comptime {
    _ = @sizeOf(S);
}

comptime {
    _ = @alignOf(V);
}

comptime {
    _ = [2]noreturn;
}

comptime {
    _ = @sizeOf(enum(u8) {});
}

comptime {
    const s: S = undefined;
    _ = s;
}

comptime {
    _ = @unionInit(U, "a", undefined);
}

pub fn main() void {}

// error
// uninstantiable.zig:6:17: error[bad-type]: no size available for uninstantiable type 'uninstantiable.S'
//   | _ = @sizeOf(S);
//   note uninstantiable.zig:1:11: struct declared here: const S = struct { x: u64, n: noreturn };
// uninstantiable.zig:10:18: error[bad-type]: no align available for uninstantiable type 'uninstantiable.V'
//   | _ = @alignOf(V);
//   note uninstantiable.zig:3:11: union declared here: const V = union { a: S, b: noreturn };
// uninstantiable.zig:14:12: error[bad-type]: array of 'noreturn' not allowed
//   | _ = [2]noreturn;
// uninstantiable.zig:18:22: error[bad-container]: empty exhaustive enums must be backed by 'noreturn'
//   | _ = @sizeOf(enum(u8) {});
//   ref: comptime uninstantiable.zig:18:9
// uninstantiable.zig:22:18: error[type-mismatch]: expected type 'uninstantiable.S', found '@TypeOf(undefined)'
//   | const s: S = undefined;
//   note uninstantiable.zig:22:18: cannot coerce to uninstantiable type 'uninstantiable.S'
//   note uninstantiable.zig:1:11: struct declared here: const S = struct { x: u64, n: noreturn };
// uninstantiable.zig:27:28: error[type-mismatch]: expected type 'uninstantiable.S', found '@TypeOf(undefined)'
//   | _ = @unionInit(U, "a", undefined);
//   note uninstantiable.zig:27:28: cannot coerce to uninstantiable type 'uninstantiable.S'
//   note uninstantiable.zig:1:11: struct declared here: const S = struct { x: u64, n: noreturn };
// 6 errors
