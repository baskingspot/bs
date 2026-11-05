// Switch prongs over integers wider than 128 bits cover the type, or
// leave a value out, as for narrower ones.
fn covered(x: i200) u8 {
    return switch (x) {
        -803469022129495137770981046170581301261101496891396417650688...-1 => 0,
        0...803469022129495137770981046170581301261101496891396417650687 => 1,
    };
}
fn redundantElse(x: u256) u8 {
    return switch (x) {
        0...10 => 0,
        11...115792089237316195423570985008687907853269984665640564039457584007913129639935 => 1,
        else => 2,
    };
}
fn gap(x: u256) u8 {
    return switch (x) {
        0...10 => 0,
        12...115792089237316195423570985008687907853269984665640564039457584007913129639935 => 1,
    };
}

pub fn main() void {
    var a: u256 = 5;
    _ = &a;
    _ = covered(@intCast(a));
    _ = redundantElse(a);
    _ = gap(a);
}

// error
// switch_wide.zig:13:14: error[bad-switch]: unreachable else prong; all cases already handled
//   | else => 2,
//   ref: main switch_wide.zig:27:22 (+3 std frames)
// switch_wide.zig:17:12: error[switch-incomplete]: switch must handle all possibilities
//   | return switch (x) {
//   ref: main switch_wide.zig:28:12 (+3 std frames)
// 2 errors
