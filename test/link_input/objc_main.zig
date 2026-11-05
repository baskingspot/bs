extern fn f() c_int;

pub fn main() u8 {
    return @intCast(f());
}
