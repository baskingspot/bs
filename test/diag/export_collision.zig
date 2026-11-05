// Two strong exports of one name collide, as upstream reports it: at the
// later export, with a note at the other.
export fn foo() void {}

const bar: u32 = 123;

comptime {
    @export(&bar, .{ .name = "foo" });
}

pub fn main() void {}

// error
// export_collision.zig:8:5: error[bad-export]: exported symbol collision: foo
//   | @export(&bar, .{ .name = "foo" });
//   note export_collision.zig:3:1: other symbol here
// 1 error
