//! `// ziglint-ignore:` comments drop a finding of the rules they name,
//! on their own line or on the run of `//` lines right above it.

fn Inline() void {} // ziglint-ignore: Z001

// ziglint-ignore: Z001 -- the comment run above a line covers it
// and so does a line further up the same run.
fn Above() void {}

// ziglint-ignore: Z001

fn NotAdjacent() void {}

fn WrongRule() void {} // ziglint-ignore: Z026

// ziglint-ignore: Z031, Z001
fn _Both() void {}

test {
    _ = &Inline;
    _ = &Above;
    _ = &NotAdjacent;
    _ = &WrongRule;
    _ = &_Both;
}

// error
// ignore.zig:12:4: error[style, Z001]: function 'NotAdjacent' should be camelCase
//   | fn NotAdjacent() void {}
// ignore.zig:14:4: error[style, Z001]: function 'WrongRule' should be camelCase
//   | fn WrongRule() void {} // ziglint-ignore: Z026
// 2 errors
