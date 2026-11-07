//! A config naming a rule bs does not know fails the build.

test {}

// error
// .ziglint.zon:1:17: error[lint-config]: unexpected field 'Z036'; bs enforces ziglint 0.8.1's rules, and its config must parse
//   | .{ .rules = .{ .Z036 = .{ .enabled = false } } }
// 1 error
