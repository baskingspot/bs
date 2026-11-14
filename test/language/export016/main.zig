//! Zig 0.16 reports two exports of one name whatever their linkage: 0.17
//! reports two strong ones only, and builds this program.

fn first() callconv(.c) void {}

fn second() callconv(.c) void {}

comptime {
    // Not a collision in either language: one function, two names.
    @export(&first, .{ .name = "one_name", .linkage = .weak });
    @export(&first, .{ .name = "other_name", .linkage = .weak });
}

comptime {
    @export(&first, .{ .name = "weak_twice", .linkage = .weak });
    @export(&second, .{ .name = "weak_twice", .linkage = .weak });
    @export(&first, .{ .name = "weak_and_strong", .linkage = .weak });
    @export(&second, .{ .name = "weak_and_strong" });
}

pub fn main() void {}
