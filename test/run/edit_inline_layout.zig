//! exit: 8
//! rebuild-replace: "a: u64," "a: u8,"
//! An edit build after a field's type changes the offsets of the fields
//! after it. `getB` reads `b`, so it is analyzed again, but its IR names
//! the field by index and `S` by identity: its inline result's hash was
//! the same, so `caller`, which inlines it and reads nothing the edit
//! changed, kept its old code and read `b` at its old offset.
const S = struct { a: u64, b: u32 };

fn getB(s: *const S) u32 {
    return s.b;
}

noinline fn caller(s: *const S) u32 {
    return getB(s) + 1;
}

pub fn main() u8 {
    var s: S = .{ .a = 1, .b = 7 };
    _ = &s;
    return @intCast(caller(&s));
}
