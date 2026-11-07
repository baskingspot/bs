x: i32,
y: i32,

const Here = @This();

pub fn sum(p: Here) i32 {
    return p.x + p.y;
}
