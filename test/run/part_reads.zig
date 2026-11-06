//! exit: 0
//! stderr: "opt 1 0 7 eu 9 2 tag 3 21 alias 5 4 merge 20 40 field 6 ext 2 7\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux
//! A load of an aggregate whose users only read parts of it (a tag, a
//! field, a payload) is read in place where it points, when nothing may
//! write memory in between; with a write through an alias in between, or
//! a user in a block more than one block reaches, it is still copied.
const std = @import("std");

const Big = struct { a: [12]u64, b: u32 };

const Holder = struct {
    opt: ?Big,
    eu: error{Nope}!Big,
};

noinline fn optState(h: *const Holder) u32 {
    return @intFromBool(h.opt == null);
}

noinline fn optField(h: *const Holder) u64 {
    return h.opt.?.a[3];
}

noinline fn euCapture(h: *Holder) u64 {
    if (h.eu) |*p| {
        p.a[0] += 2;
        return p.a[0];
    } else |_| return 0;
}

noinline fn euErr(h: *const Holder) u16 {
    return if (h.eu) |_| 0 else |e| @intFromError(e);
}

const Node = union(enum) {
    leaf: Big,
    pair: struct { l: u64, r: u64, pad: [10]u64 },
    empty,
};

noinline fn weight(n: *const Node) u64 {
    return switch (n.*) {
        .leaf => |l| l.a[1],
        .pair => |p| p.l + p.r,
        .empty => 3,
    };
}

/// The load happens before the write through `alias`, which may point to
/// the same memory: the read must see the old value.
noinline fn aliasWrite(h: *Holder, alias: *Big) u64 {
    const before = h.opt;
    alias.a[2] = 4;
    return before.?.a[2];
}

/// Two blocks reach the block that reads the tag: the read must not
/// happen after the write on one of the paths.
noinline fn merge(n: *Node, c: bool) u64 {
    const v = n.*;
    if (c) n.* = .{ .pair = .{ .l = 10, .r = 20, .pad = @splat(0) } };
    return switch (v) {
        .leaf => |l| l.a[1] * 10,
        .pair => |p| p.l + p.r,
        .empty => 0,
    };
}

const Ext = extern struct { pad: [20]u8, x: u32, y: u64 };

noinline fn extField(p: *const Ext) u64 {
    const e = p.*;
    return e.x + e.y;
}

pub fn main() void {
    var big: Big = .{ .a = @splat(0), .b = 6 };
    big.a[3] = 7;
    big.a[2] = 5;
    big.a[1] = 2;
    var h: Holder = .{ .opt = big, .eu = big };
    var e: Holder = .{ .opt = null, .eu = error.Nope };
    h.eu = blk: {
        var b2 = big;
        b2.a[0] = 7;
        break :blk b2;
    };
    const s0 = optState(&e);
    const s1 = optState(&h);
    const f = optField(&h);
    const c = euCapture(&h);
    const er = @as(u32, @intFromBool(euErr(&e) != 0)) * 2 + @intFromBool(euErr(&h) != 0);
    var n: Node = .{ .leaf = big };
    var q: Node = .{ .pair = .{ .l = 9, .r = 12, .pad = @splat(0) } };
    var z: Node = .empty;
    _ = &z;
    const w = weight(&n) + weight(&z) - 2;
    const w2 = weight(&q);
    const a0 = aliasWrite(&h, &h.opt.?);
    const a1 = h.opt.?.a[2];
    var m: Node = .{ .leaf = big };
    const m1 = merge(&m, true);
    var m2n: Node = .{ .pair = .{ .l = 15, .r = 25, .pad = @splat(0) } };
    const m2 = merge(&m2n, false);
    var x: Ext = .{ .pad = @splat(0), .x = 2, .y = 5 };
    _ = &x;
    std.debug.print("opt {d} {d} {d} eu {d} {d} tag {d} {d} alias {d} {d} merge {d} {d} field {d} ext {d} {d}\n", .{
        s0, s1, f, c, er, w, w2, a0, a1, m1, m2, h.opt.?.b, x.x, extField(&x),
    });
}
