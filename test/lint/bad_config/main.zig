//! A config naming a rule bs does not know fails the build.

test {}

// error
// .bs.zon:1:28: error[lint-config]: unexpected field 'Z036'; bs enforces ziglint 0.8.1's rules, and its config must parse
//   | .{ .lint = .{ .rules = .{ .Z036 = .{ .enabled = false } } } }
// 1 error
