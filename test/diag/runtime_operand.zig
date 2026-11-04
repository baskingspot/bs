// A runtime-known value in a comptime context is reported where the
// value is needed comptime-known, as upstream: at the struct literal
// (with the operand), and at the comptime argument. And upstream's limit
// on a type's size.
var n: u8 = 5;
const S = struct { a: u8 };
var a: S = .{ .a = n };

fn takesComptime(comptime _: []const u8) void {}
fn runtimeByte() u8 {
    return n;
}

const Big = struct { data: [1 << 32]u8 };

export fn readA() void {
    _ = a;
}

export fn passRuntime() void {
    const y = runtimeByte();
    takesComptime(&.{y});
}

export fn makeBig() void {
    _ = @as(Big, undefined);
}

pub fn main() void {}

// error
// runtime_operand.zig:7:13: error[comptime-required]: unable to evaluate comptime expression
//   | var a: S = .{ .a = n };
//   note runtime_operand.zig:7:16: operation is runtime due to this operand
//   note runtime_operand.zig:7:13: initializer of container-level variable must be comptime-known
//   ref: readA runtime_operand.zig:17:9
// runtime_operand.zig:14:13: error[bad-container]: struct layout requires size 4294967296, this compiler implementation supports up to 4294967295
//   | const Big = struct { data: [1 << 32]u8 };
//   ref: makeBig runtime_operand.zig:26:18
// runtime_operand.zig:22:19: error[comptime-required]: unable to resolve comptime value
//   | takesComptime(&.{y});
//   note runtime_operand.zig:22:19: argument to comptime parameter must be comptime-known
//   note runtime_operand.zig:9:18: parameter declared comptime here
// 3 errors
