//! exit: 101
//! rebuild-replace: "return heavy(x) +% 1;" "return heavy(x +% 1);"
//! An edit build after the body of a wrapper changes: `caller` inlines
//! `wrap`, which keeps its call of `heavy` (too big to inline), so it reads
//! `wrap`'s inline result and is generated again with the new body.
fn heavy(x: u32) u32 {
    var h: u32 = x;
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        h = (h ^ (h >> 3)) *% 0x9e3779b1 +% i;
        h ^= h << 7;
        h = h +% (h >> 11) *% 5;
    }
    return h & 0x3f;
}

fn wrap(x: u32) u32 {
    return heavy(x) +% 1;
}

noinline fn caller(x: u32) u32 {
    return wrap(x) *% 3 +% wrap(x +% 2);
}

pub fn main() u8 {
    var x: u32 = 5;
    _ = &x;
    return @truncate(caller(x));
}
