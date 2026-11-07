//! A rule turned off (Z001), one turned on (Z033, off by default), and
//! Z024's limit set: line 7 is 101 bytes long, line 9 exactly 100. They
//! are indented, so that the expected output's excerpt fits the limit.

fn Off() void {}
const long_line_one =
        "..........................................................................................";
const long_line_two =
        ".........................................................................................";
const UserData = struct {};

test {
    _ = &Off;
    _ = long_line_one;
    _ = long_line_two;
    _ = UserData;
}

// error
// main.zig:7:101: error[style, Z024]: line exceeds 100 bytes (101 bytes)
//   | "..........................................................................................";
// main.zig:10:7: error[style, Z033]: type name 'UserData' contains redundant word 'Data'
//   | const UserData = struct {};
// 2 errors
