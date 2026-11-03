inline fn half(x: u32) u32 {
    return @divExact(x, 2);
}

inline fn quarter(x: u32) u32 {
    return half(half(x));
}

fn twice(comptime n: u32) u32 {
    return quarter(n);
}

pub fn main() void {
    _ = comptime twice(6);
}

// error
// call_frames.zig:2:12: error: exact division produced remainder
//   | return @divExact(x, 2);
//   call: call_frames.zig:6:16 comptime, call_frames.zig:10:19 comptime, call_frames.zig:14:23 comptime
// 1 error
