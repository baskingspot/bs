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

pub fn main() void {
    store();
    _ = merge();
    field(1);
    _ = decl;
}

// error
// comptime_var.zig:20:25: error[comptime-var-escape]: global variable contains reference to comptime var
//   | const decl: *u32 = blk: {
//   ref: main comptime_var.zig:29:9 (+3 std frames)
// comptime_var.zig:6:14: error[comptime-var-escape]: runtime value contains reference to comptime var
//   | global = &x;
//   note comptime_var.zig:6:14: comptime var pointers are not available at runtime
//   ref: main comptime_var.zig:26:10 (+3 std frames)
// comptime_var.zig:11:22: error[comptime-var-escape]: runtime value contains reference to comptime var
//   | return if (cond) &x else global;
//   note comptime_var.zig:11:22: comptime var pointers are not available at runtime
//   ref: main comptime_var.zig:27:14 (+3 std frames)
// comptime_var.zig:16:27: error[comptime-var-escape]: runtime value contains reference to comptime var
//   | const s = .{ .i = i, .p = &x };
//   note comptime_var.zig:16:27: comptime var pointers are not available at runtime
//   ref: main comptime_var.zig:28:10 (+3 std frames)
// 4 errors
