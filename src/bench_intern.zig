//! InternPool throughput benchmark: `zig build bench-intern`. Interns a mix
//! of keys shaped like what Sema produces (mostly integer values, then
//! pointer types and values, aggregates, slices, optionals, function and
//! array types), first as misses, then looks them all up again as hits, and
//! reports nanoseconds per `get`. Also times the stable-hash function alone
//! on the same keys.

const std = @import("std");
const InternPool = @import("InternPool.zig");
const Index = InternPool.Index;
const Key = InternPool.Key;

const n_keys = 200_000;
const hit_rounds = 5;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rand = prng.random();

    var best_miss: u64 = std.math.maxInt(u64);
    var best_hit: u64 = std.math.maxInt(u64);
    var best_hash: u64 = std.math.maxInt(u64);
    var best_hash_seq: u64 = std.math.maxInt(u64);
    var best_hit_seq: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        // Generate the keys in one pool, recording each new key in creation
        // order, then replay them into a fresh pool: every replayed `get`
        // misses and gets the same index it got the first time.
        const keys = blk: {
            var gen: InternPool = try .init(gpa, io, 1);
            defer gen.deinit();
            var rec: Recorder = .{ .ip = &gen, .arena = arena };
            try makeKeys(&rec, rand);
            break :blk rec.log.items;
        };
        var ip: InternPool = try .init(gpa, io, 1);
        defer ip.deinit();

        // Misses: every key is new.
        var t = std.Io.Timestamp.now(io, .awake);
        for (keys) |k| _ = try ip.get(.main, k);
        best_miss = @min(best_miss, elapsed(io, t));

        // Hits: look every key up again in a shuffled order.
        const order = try arena.alloc(u32, keys.len);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        rand.shuffle(u32, order);
        t = std.Io.Timestamp.now(io, .awake);
        var sink: u32 = 0;
        for (0..hit_rounds) |_| {
            for (order) |i| sink +%= @backingInt(try ip.get(.main, keys[i]));
        }
        best_hit = @min(best_hit, elapsed(io, t));
        std.mem.doNotOptimizeAway(sink);

        t = std.Io.Timestamp.now(io, .awake);
        var acc: InternPool.Hash = 0;
        for (0..hit_rounds) |_| {
            for (order) |i| acc +%= ip.hashKey(keys[i]);
        }
        best_hash = @min(best_hash, elapsed(io, t));
        std.mem.doNotOptimizeAway(acc);

        // The same in creation order, where the data a key references is
        // mostly in cache, as for Sema's lookups of recently used items.
        t = std.Io.Timestamp.now(io, .awake);
        for (0..hit_rounds) |_| {
            for (keys) |k| acc +%= ip.hashKey(k);
        }
        best_hash_seq = @min(best_hash_seq, elapsed(io, t));
        std.mem.doNotOptimizeAway(acc);
        t = std.Io.Timestamp.now(io, .awake);
        for (0..hit_rounds) |_| {
            for (keys) |k| sink +%= @backingInt(try ip.get(.main, k));
        }
        best_hit_seq = @min(best_hit_seq, elapsed(io, t));
        std.mem.doNotOptimizeAway(sink);
    }
    std.debug.print(
        \\{d} keys, best of 5 runs:
        \\  get, miss: {d:.1} ns/op
        \\  get, hit (shuffled):  {d:.1} ns/op
        \\  hash only (shuffled): {d:.1} ns/op
        \\  get, hit (in order):  {d:.1} ns/op
        \\  hash only (in order): {d:.1} ns/op
        \\
    , .{
        n_keys,
        @as(f64, @floatFromInt(best_miss)) / n_keys,
        @as(f64, @floatFromInt(best_hit)) / (n_keys * hit_rounds),
        @as(f64, @floatFromInt(best_hash)) / (n_keys * hit_rounds),
        @as(f64, @floatFromInt(best_hit_seq)) / (n_keys * hit_rounds),
        @as(f64, @floatFromInt(best_hash_seq)) / (n_keys * hit_rounds),
    });
}

const Recorder = struct {
    ip: *InternPool,
    arena: std.mem.Allocator,
    log: std.ArrayList(Key) = .empty,

    fn get(r: *Recorder, key: Key) !Index {
        if (r.ip.find(key)) |i| return i;
        try r.log.append(r.arena, key);
        return r.ip.get(.main, key);
    }
};

/// Distinct keys in a Sema-like mix, recorded by `rec`.
fn makeKeys(rec: *Recorder, rand: std.Random) !void {
    const arena = rec.arena;
    const int_types = [_]Index{ .u8_type, .u16_type, .u32_type, .u64_type, .usize_type, .i32_type, .i64_type, .comptime_int_type };
    var types: std.ArrayList(Index) = .empty;
    try types.appendSlice(arena, &int_types);
    var ptrs: std.ArrayList(Index) = .empty;
    var n_int: u64 = 0;
    while (rec.log.items.len < n_keys) {
        const pick = rand.uintLessThan(u32, 100);
        const ty = types.items[rand.uintLessThan(usize, types.items.len)];
        const key: Key = if (pick < 40) blk: {
            n_int += 1;
            const it = int_types[rand.uintLessThan(usize, int_types.len)];
            break :blk .{ .int = .{ .ty = it, .storage = .{ .u64 = n_int } } };
        } else if (pick < 55) .{ .ptr_type = .{ .child = ty, .flags = .{
            .size = @fromBackingInt(@intCast(rand.uintLessThan(u2, 3))),
            .is_const = rand.boolean(),
            .alignment = @intCast(rec.log.items.len % 61),
        } } } else if (pick < 65 and ptrs.items.len != 0) blk: {
            const base = ptrs.items[rand.uintLessThan(usize, ptrs.items.len)];
            const pty = try rec.get(.{ .ptr_type = .{ .child = .u8_type } });
            break :blk .{ .ptr = .{ .ty = pty, .base = .{ .elem = .{ .base = base, .index = rec.log.items.len } } } };
        } else if (pick < 75) blk: {
            const n = rand.intRangeAtMost(usize, 2, 8);
            const elems = try arena.alloc(Index, n);
            for (elems) |*e| e.* = try rec.get(.{ .int = .{ .ty = .u32_type, .storage = .{ .u64 = rand.uintLessThan(u64, 1000) } } });
            const aty = try rec.get(.{ .array_type = .{ .len = n, .child = .u32_type } });
            elems[0] = try rec.get(.{ .int = .{ .ty = .u32_type, .storage = .{ .u64 = 1000 + rec.log.items.len } } });
            break :blk .{ .aggregate = .{ .ty = aty, .storage = .{ .elems = elems } } };
        } else if (pick < 80) blk: {
            const sty = try rec.get(.{ .ptr_type = .{ .child = .u8_type, .flags = .{ .size = .slice, .is_const = true } } });
            const mty = try rec.get(.{ .ptr_type = .{ .child = .u8_type, .flags = .{ .size = .many, .is_const = true } } });
            const p = try rec.get(.{ .ptr = .{ .ty = mty, .base = .int, .byte_offset = rec.log.items.len } });
            const len = try rec.get(.{ .int = .{ .ty = .usize_type, .storage = .{ .u64 = rec.log.items.len } } });
            break :blk .{ .slice = .{ .ty = sty, .ptr = p, .len = len } };
        } else if (pick < 85) .{
            .opt_type = ty,
        } else if (pick < 92) blk: {
            const n = rand.uintLessThan(usize, 4);
            const params = try arena.alloc(Index, n);
            for (params) |*p| p.* = types.items[rand.uintLessThan(usize, types.items.len)];
            break :blk .{ .func_type = .{ .param_types = params, .return_type = ty, .cc = .auto } };
        } else .{ .array_type = .{ .len = rec.log.items.len, .child = ty } };
        const index = try rec.get(key);
        switch (key) {
            .ptr_type, .opt_type, .array_type => try types.append(arena, index),
            else => {},
        }
        if (key == .ptr_type) {
            try ptrs.append(arena, try rec.get(.{ .ptr = .{ .ty = index, .base = .int, .byte_offset = rec.log.items.len } }));
        }
    }
}

fn elapsed(io: std.Io, start: std.Io.Timestamp) u64 {
    return @intCast(start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);
}
