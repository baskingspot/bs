//! signal: ABRT
//! stderr: "panic: index out of bounds: index 2, len 1\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): a store
//! to a slice's `len` field gives the slice loaded next that length only
//! while nothing else writes memory. After `list.items.len = n`,
//! `list.items[j]` under `j < n` needs no check; after a store through
//! `other`, which points to the same list, its length is 1 and the check
//! stays.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const List = struct { items: []u8 };
var buf: [8]u8 = @splat(1);
var list: List = .{ .items = buf[0..0] };
var other: *List = &list;
var len: usize = 3;
var at: usize = 2;

fn main() callconv(.c) noreturn {
    const l = &list;
    const n = len;
    const j = at;
    var t: u8 = 0;
    l.items.len = n;
    if (j < n) t +%= l.items[j];
    if (t != 1) rt.exit(1);
    l.items.len = n;
    other.items.len = 1;
    if (j < n) t +%= l.items[j];
    rt.exit(t);
}
