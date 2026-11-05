//! A C pointer and an optional pointer share a representation, as
//! upstream: a null C pointer coerces to a null optional pointer at run
//! time, not a failed cast (zfetch walks getifaddrs's list with
//! `ifa = a.ifa_next`, a `[*c]struct_ifaddrs` field, into
//! `ifa: ?*struct_ifaddrs`), and an array pointer that drops its
//! sentinel coerces when its elements do. A plain pointer `@ptrCast` to an
//! optional one keeps its bits, so address zero is null, at comptime and at
//! run time (revo checks a `std.mem.zeroes` entry of a comptime-built table
//! this way).
//! exit: 0
const S = extern struct { x: c_int, next: [*c]S = null };

var global: S = .{ .x = 42 };

fn fillPair(out: *[2][*c]S) void {
    out[1] = &global;
}

const Entry = extern struct { name: [*:0]const u8, f: *const anyopaque, n: u8 };

fn nothing() void {}

fn table() [2]Entry {
    var out: [2]Entry = undefined;
    out[0] = .{ .name = "add", .f = @ptrCast(&nothing), .n = 2 };
    out[1] = @import("std").mem.zeroes(Entry);
    return out;
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
    const t = comptime table();
    const end: ?[*:0]const u8 = @ptrCast(t[1].name);
    const add: ?[*:0]const u8 = @ptrCast(t[0].name);
    if (end != null or add == null) return 4;
    var rt = t;
    _ = &rt;
    const rt_end: ?*const anyopaque = @ptrCast(rt[1].f);
    const rt_add: ?*const anyopaque = @ptrCast(rt[0].f);
    if (rt_end != null or rt_add == null) return 5;
    var s: []const u8 = @as([*]const u8, @ptrCast(rt[1].name))[0..0];
    _ = &s;
    const opt_s: ?[]const u8 = @ptrCast(s);
    if (opt_s != null) return 6;
    // The optional allows zero, so a null C pointer is not a failed cast.
    var cn: [*c]const u8 = null;
    _ = &cn;
    const cn_opt: ?[*]const u8 = @ptrCast(cn);
    if (cn_opt != null) return 7;
    return 0;
}
