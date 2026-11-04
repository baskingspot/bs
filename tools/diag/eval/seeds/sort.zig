const std = @import("std");

const Person = struct {
    name: []const u8,
    age: u32,

    fn lessThan(_: void, a: Person, b: Person) bool {
        return a.age < b.age;
    }
};

pub fn main() void {
    var nums = [_]i32{ 5, -2, 9, 0 };
    std.mem.sort(i32, &nums, {}, std.sort.asc(i32));
    var people = [_]Person{ .{ .name = "b", .age = 40 }, .{ .name = "a", .age = 30 } };
    std.mem.sort(Person, &people, {}, Person.lessThan);
    const max = std.mem.max(i32, &nums);
    std.debug.print("{any} {s} {d}\n", .{ nums, people[0].name, max });
}
