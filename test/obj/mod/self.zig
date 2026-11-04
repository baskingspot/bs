// Under `zig test`, `--dep self=root` names the module under test, not
// the test runner that `@import("root")` is (zigimg's tests).
const std = @import("std");

pub const answer: u32 = 42;

test "a module imports itself by name" {
    try std.testing.expectEqual(42, @import("self").answer);
}

test "a module is named main" {
    try std.testing.expectEqual(7, @import("main").seven);
}
