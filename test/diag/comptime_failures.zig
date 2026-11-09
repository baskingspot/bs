// Comptime failures name what failed, as upstream: an out-of-bounds index
// points at the index and names the indexed array, slice or vector (with
// its sentinel); `catch unreachable` on a comptime-known error names the
// error; `@panic` gives its message.
const array: [5]u8 = "hello".*;
const terminated: [5:0]u8 = "hello".*;
const slice: [:0]const u8 = "hello";
const vector: @Vector(3, u8) = .{ 1, 2, 3 };

fn getNumberOrFail() !i32 {
    return error.UnableToReturnNumber;
}

fn read(e: anyerror!u8) u8 {
    return e catch unreachable;
}

comptime {
    _ = array[5];
}

comptime {
    _ = terminated[6];
}

comptime {
    _ = slice[6];
}

comptime {
    _ = vector[3];
}

comptime {
    var v = vector;
    _ = &v[4];
}

comptime {
    _ = getNumberOrFail() catch unreachable;
}

comptime {
    _ = read(error.Unread);
}

comptime {
    var e: anyerror!u8 = error.ThroughPointer;
    const p = &e;
    _ = p.* catch unreachable;
}

comptime {
    @panic("comptime panic message");
}

const A = struct {};
const B = struct {};
comptime {
    // Zero-bit, but read as another type without a defined layout.
    const val: [1]A = .{.{}};
    const ptr: *const [1]B = @ptrCast(&val);
    _ = ptr ++ ptr;
}

pub fn main() void {}

// error
// comptime_failures.zig:15:20: error[caught-error]: caught unexpected error 'Unread'
//   | return e catch unreachable;
//   call: comptime_failures.zig:44:13 comptime
// comptime_failures.zig:19:15: error[out-of-bounds]: index 5 outside array of length 5
//   | _ = array[5];
// comptime_failures.zig:23:20: error[out-of-bounds]: index 6 outside array of length 5 +1 (sentinel)
//   | _ = terminated[6];
// comptime_failures.zig:27:15: error[out-of-bounds]: index 6 outside slice of length 5 +1 (sentinel)
//   | _ = slice[6];
// comptime_failures.zig:31:16: error[out-of-bounds]: index 3 outside array of length 3
//   | _ = vector[3];
// comptime_failures.zig:36:12: error[out-of-bounds]: index 4 outside vector of length 3
//   | _ = &v[4];
// comptime_failures.zig:40:33: error[caught-error]: caught unexpected error 'UnableToReturnNumber'
//   | _ = getNumberOrFail() catch unreachable;
// comptime_failures.zig:50:19: error[caught-error]: caught unexpected error 'ThroughPointer'
//   | _ = p.* catch unreachable;
// comptime_failures.zig:54:5: error[comptime-trap]: encountered @panic at comptime: comptime panic message
//   | @panic("comptime panic message");
// comptime_failures.zig:63:9: error[bad-type]: comptime dereference requires '[1]comptime_failures.B' to have a well-defined layout
//   | _ = ptr ++ ptr;
// 10 errors
