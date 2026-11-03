var cond = true;

fn branch() u32 {
    const x = if (cond) 1 else 2;
    return x;
}

fn loop() void {
    comptime var i = 0;
    while (i < 3) : (i += 1) {}
}

const S = struct { T: type, n: u32 };

fn init(n: u32) void {
    const s: S = .{ .T = u8, .n = n };
    _ = s;
}

pub fn main() void {
    _ = branch();
    loop();
    init(1);
}

// error
// comptime_runtime.zig:4:15: error[comptime-only]: value with comptime-only type 'comptime_int' depends on runtime control flow
//   | const x = if (cond) 1 else 2;
//   note comptime_runtime.zig:4:19: runtime control flow here
//   ref: main comptime_runtime.zig:21:15 (+3 std frames)
// comptime_runtime.zig:10:24: error[comptime-var-escape]: cannot store to comptime variable in non-inline loop
//   | while (i < 3) : (i += 1) {}
//   note comptime_runtime.zig:10:5: non-inline loop here
//   ref: main comptime_runtime.zig:22:9 (+3 std frames)
// comptime_runtime.zig:16:35: error[comptime-required]: unable to resolve comptime value
//   | const s: S = .{ .T = u8, .n = n };
//   note comptime_runtime.zig:16:35: value stored to a comptime variable must be comptime-known
//   ref: main comptime_runtime.zig:23:9 (+3 std frames)
// 3 errors
