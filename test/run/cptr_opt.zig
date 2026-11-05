//! A C pointer and an optional pointer share a representation, as
//! upstream: a null C pointer coerces to a null optional pointer at run
//! time, not a failed cast (zfetch walks getifaddrs's list with
//! `ifa = a.ifa_next`, a `[*c]struct_ifaddrs` field, into
//! `ifa: ?*struct_ifaddrs`), and an array pointer that drops its
//! sentinel coerces when its elements do.
//! exit: 0
const S = extern struct { x: c_int, next: [*c]S = null };

var global: S = .{ .x = 42 };

fn fillPair(out: *[2][*c]S) void {
    out[1] = &global;
}

pub fn main() u8 {
    var n: u8 = 0;
    var it: ?*S = &global;
    while (it) |a| : (it = a.next) n += 1;
    if (n != 1) return 1;
    var c: [*c]S = null;
    _ = &c;
    const q: ?*S = c;
    if (q != null) return 2;
    var pair: [2:null]?*S = .{ null, null };
    fillPair(&pair);
    if (pair[0] != null or pair[1].?.x != 42) return 3;
    return 0;
}
