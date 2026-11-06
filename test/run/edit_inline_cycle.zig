//! exit: 30
//! rebuild-without: "if (x > 100) return a(x / 2);"
//! An edit build that adds and removes a call closing a cycle of wrappers:
//! with it, `a` and `b` are on a cycle of candidate calls, so neither is
//! inlinable and no body keeps a call of either; without it, `b` keeps its
//! call of `heavy` and inlines into `a`, which inlines into `caller`.
//! Either way the edit build's fates are a full build's.
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

fn a(x: u32) u32 {
    if (x == 0) return 0;
    return b(x - 1) +% 1;
}

fn b(x: u32) u32 {
    if (x > 100) return a(x / 2);
    return heavy(x);
}

noinline fn caller(x: u32) u32 {
    return a(x) *% 3;
}

pub fn main() u8 {
    var x: u32 = 5;
    _ = &x;
    return @truncate(caller(x));
}
