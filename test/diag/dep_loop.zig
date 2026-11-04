const Self = struct { s: Self };

const A = struct { b: [@sizeOf(B)]u8 };
const B = struct { a: A };

const a: @TypeOf(b) = 1;
const b: @TypeOf(a) = 2;

comptime {
    _ = @as(Self, undefined);
}

comptime {
    _ = @as(A, undefined);
}

comptime {
    _ = a;
}

pub fn main() void {}

// error
// dep_loop.zig:1:26: error[dependency-loop]: type 'dep_loop.Self' depends on itself for field declared here
//   | const Self = struct { s: Self };
//   ref: comptime dep_loop.zig:10:19
// error[dependency-loop]: dependency loop with length 2
//   note dep_loop.zig:3:32: type 'dep_loop.A' depends on type 'dep_loop.B' for size query here
//   note dep_loop.zig:4:23: type 'dep_loop.B' depends on type 'dep_loop.A' for field declared here
//   note: eliminate any one of these dependencies to break the loop
//   ref: comptime dep_loop.zig:14:16
// error[dependency-loop]: dependency loop with length 4
//   note dep_loop.zig:6:23: value of declaration 'dep_loop.a' uses type of declaration 'dep_loop.a' here
//   note dep_loop.zig:6:18: type of declaration 'dep_loop.a' uses value of declaration 'dep_loop.b' here
//   note dep_loop.zig:7:23: value of declaration 'dep_loop.b' uses type of declaration 'dep_loop.b' here
//   note dep_loop.zig:7:18: type of declaration 'dep_loop.b' uses value of declaration 'dep_loop.a' here
//   note: eliminate any one of these dependencies to break the loop
//   ref: comptime dep_loop.zig:18:9
// 3 errors
