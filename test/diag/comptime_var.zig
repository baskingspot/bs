var global: *u32 = undefined;
var cond = true;

fn store() void {
    comptime var x: u32 = 1;
    global = &x;
}

fn merge() *u32 {
    comptime var x: u32 = 1;
    return if (cond) &x else global;
}

fn field(i: u8) void {
    comptime var x: u32 = 1;
    const s = .{ .i = i, .p = &x };
    _ = s;
}

const decl: *u32 = blk: {
    var x: u32 = 1;
    break :blk &x;
};

// A comptime field is comptime memory too, also a tuple's.
const tuple = .{ @as(u32, 1), @as(u32, 2) };
const field_ptr = &tuple[0];
const S = struct { comptime a: u32 = 5, b: u32 };
noinline fn read(p: *const u32) u32 {
    return p.*;
}
fn globalFieldPtr() void {
    _ = field_ptr;
}
fn comptimeField(s: *S) u32 {
    const known = &tuple[1];
    return read(&s.a) + read(&tuple[1]) + known.*;
}

pub fn main() void {
    var s: S = .{ .b = 1 };
    _ = comptimeField(&s);
    store();
    _ = merge();
    field(1);
    globalFieldPtr();
    _ = decl;
}

// error
// comptime_var.zig:6:14: error[comptime-var-escape]: runtime value contains reference to comptime var
//   | global = &x;
//   note comptime_var.zig:6:14: comptime var pointers are not available at runtime
//   ref: main comptime_var.zig:43:10 (+3 std frames)
// comptime_var.zig:11:22: error[comptime-var-escape]: runtime value contains reference to comptime var
//   | return if (cond) &x else global;
//   note comptime_var.zig:11:22: comptime var pointers are not available at runtime
//   ref: main comptime_var.zig:44:14 (+3 std frames)
// comptime_var.zig:16:27: error[comptime-var-escape]: runtime value contains reference to comptime var
//   | const s = .{ .i = i, .p = &x };
//   note comptime_var.zig:16:27: comptime var pointers are not available at runtime
//   ref: main comptime_var.zig:45:10 (+3 std frames)
// comptime_var.zig:20:25: error[comptime-var-escape]: global variable contains reference to comptime var
//   | const decl: *u32 = blk: {
//   ref: main comptime_var.zig:47:9 (+3 std frames)
// comptime_var.zig:27:19: error[comptime-var-escape]: global variable contains reference to comptime var
//   | const field_ptr = &tuple[0];
//   ref: globalFieldPtr comptime_var.zig:33:9 <- main comptime_var.zig:46:19 (+3 std frames)
// comptime_var.zig:37:17: error[comptime-var-escape]: runtime value contains reference to comptime var
//   | return read(&s.a) + read(&tuple[1]) + known.*;
//   note comptime_var.zig:37:17: comptime var pointers are not available at runtime
//   ref: main comptime_var.zig:42:22 (+3 std frames)
// 6 errors
