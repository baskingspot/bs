//! exit: 0
//! stdout: "p 5 1 133 | v 7 9 | e 3 8 4 | o 1 2 3 | b 10 31 52 | z 0 0 | h 500 0 1\n"

// Forwarding reads packed structs of at most 8 bytes and optional
// pointers from a dominating load or store, and treats a pointer reloaded
// from a `var` local, or the same element pointer built again, as one
// address (`codegen/forward.zig`). Each case writes the memory between
// two reads, or after the read in a loop that repeats, and must see the
// write; the zero-trip loops read through an invalid pointer and must
// not fault, as nothing is loaded where the program did not load.
const std = @import("std");

const Meta = packed struct(u8) { fp: u7, used: u1 };

// A store through a packed field's bit pointer between two loads.
noinline fn packed_(m: *Meta) [3]u32 {
    const a = m.*;
    const used = &m.used;
    used.* = 1;
    const b = m.*;
    return .{ a.fp, b.used, @as(u8, @bitCast(b)) };
}

// The `var` pointer local reassigned between two `p[0]`s.
noinline fn varPtr(x: [*]const u32, y: [*]const u32) [2]u32 {
    var p = x;
    const a = p[0];
    p = y;
    const b = p[0];
    return .{ a, b };
}

// `s[i]`, a store to `s[j]` with `j == i`, then `s[i]` again.
noinline fn elems(s: []u32, i: usize, j: usize) [3]u32 {
    const a = s[i];
    s[j] = 8;
    const b = s[i];
    return .{ a, b, s[i + 1] };
}

const Node = struct { next: ?*Node, v: u32 };
const Holder = struct { cur: ?*Node };

// An optional pointer read before the loop and in it, written after the
// read in the loop body: each iteration reads the latest.
noinline fn optLoop(h: *Holder, out: *[3]u32) void {
    var n: usize = 0;
    const start = h.cur;
    if (start == null) return;
    while (n < 3) : (n += 1) {
        const cur = h.cur;
        const c = cur orelse return;
        out[n] = c.v;
        h.cur = c.next;
    }
}

// A field read before the loop, written in the loop after its read.
noinline fn backEdge(s: *[2]u32, n: usize, out: *[3]u32) void {
    const first = s[0];
    var k: usize = 0;
    while (k < n) : (k += 1) {
        out[k] = s[0] + first * @as(u32, @intCast(k));
        s[0] += 11;
    }
}

// Loops that run zero times, the only loads in them through an invalid
// pointer: an optional pointer and a packed struct.
noinline fn zeroTrip(p: *const ?*u32, m: *const Meta, n: usize) [2]u32 {
    var a: u32 = 0;
    var b: u32 = 0;
    var k: usize = 0;
    while (k < n) : (k += 1) a += p.*.?.*;
    k = 0;
    while (k < n) : (k += 1) b += m.*.fp;
    return .{ a, b };
}

noinline fn hashMap() [3]u32 {
    var buf: [64 * 1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const gpa = fba.allocator();
    var m: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var k: u32 = 0;
    while (k < 1000) : (k += 1) m.put(gpa, k *% 2654435761, k) catch unreachable;
    var found: u32 = 0;
    var missed: u32 = 0;
    k = 0;
    while (k < 1000) : (k += 1) {
        if (m.get(k *% 2654435761)) |v| found += @intFromBool(v == k) else missed += 1;
        if (k % 2 == 0) _ = m.remove(k *% 2654435761);
    }
    return .{ m.count(), @intFromBool(found != 1000) + missed, @intFromBool(m.get(1 *% 2654435761) != null) };
}

pub fn main() void {
    var meta: Meta = .{ .fp = 5, .used = 0 };
    const pk = packed_(&meta);
    const xs = [_]u32{7};
    const ys = [_]u32{9};
    const vp = varPtr(&xs, &ys);
    var arr = [_]u32{ 3, 4 };
    const el = elems(&arr, 0, 0);
    var nodes: [3]Node = undefined;
    nodes[2] = .{ .next = null, .v = 3 };
    nodes[1] = .{ .next = &nodes[2], .v = 2 };
    nodes[0] = .{ .next = &nodes[1], .v = 1 };
    var h: Holder = .{ .cur = &nodes[0] };
    var ol: [3]u32 = undefined;
    optLoop(&h, &ol);
    var s2 = [_]u32{ 10, 0 };
    var be: [3]u32 = undefined;
    backEdge(&s2, 3, &be);
    const bad_p: *const ?*u32 = @ptrFromInt(0x1000);
    const bad_m: *const Meta = @ptrFromInt(0x1000);
    const zt = zeroTrip(bad_p, bad_m, 0);
    const hm = hashMap();
    var out: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    w.print("p {} {} {} | v {} {} | e {} {} {} | o {} {} {} | b {} {} {} | z {} {} | h {} {} {}\n", .{
        pk[0], pk[1], pk[2], vp[0], vp[1], el[0], el[1], el[2], ol[0], ol[1], ol[2],
        be[0], be[1], be[2], zt[0], zt[1], hm[0], hm[1], hm[2],
    }) catch unreachable;
    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, w.buffered()) catch {};
}
