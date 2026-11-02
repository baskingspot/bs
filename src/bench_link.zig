//! Link throughput benchmark: `zig build bench-link`. Builds a synthetic set
//! of about 100k atoms shaped like a Debug build (mostly functions, each
//! calling others and referencing constants; some data and bss), links it
//! with `Elf.emit` several times, and compares against copying the same bytes
//! into a fresh buffer, which is the floor for a memcpy-dominated linker.

const std = @import("std");
const Atom = @import("link/Atom.zig");
const Elf = @import("link/Elf.zig");

const n_text = 80_000;
const n_rodata = 15_000;
const n_data = 4_000;
const n_bss = 1_000;
const runs = 15;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rand = prng.random();

    // Each atom gets its own bytes, allocated next to its relocations as
    // CodeGen or the cache would, so the copy floor below reads real memory.
    const keys = try arena.alloc(Atom.SymbolKey, n_text + n_rodata + n_data + n_bss);
    const names = try arena.alloc([]const u8, keys.len);
    for (keys, names, 0..) |*k, *n, i| {
        n.* = try std.fmt.allocPrint(arena, "bench:file{d}.zig:decl{d}", .{ i % 500, i });
        k.* = .fromName(n.*);
    }

    var atoms: std.ArrayList(Atom) = .empty;
    var n_relocs: usize = 0;
    // Functions: 32..512 bytes, one call or constant reference per 32 bytes.
    for (0..n_text) |i| {
        const len = rand.intRangeAtMost(u32, 32, 512);
        const bytes = try arena.alloc(u8, len);
        rand.bytes(bytes);
        const relocs = try arena.alloc(Atom.Reloc, len / 32);
        for (relocs, 0..) |*r, j| {
            const call = rand.boolean();
            r.* = .{
                .offset = @intCast(j * 32 + 1),
                .kind = .x86_64_pc32,
                .target = if (call) keys[rand.uintLessThan(usize, n_text)] else keys[n_text + rand.uintLessThan(usize, n_rodata)],
                .addend = -4,
            };
        }
        n_relocs += relocs.len;
        try atoms.append(arena, .{ .key = keys[i], .name = names[i], .section = .text, .alignment = .@"16", .bytes = bytes, .relocs = relocs });
    }
    // Constants: 8..128 bytes; every fourth one is emitted twice, as two
    // functions producing the same content-addressed constant would.
    for (0..n_rodata) |i| {
        const bytes = try arena.alloc(u8, rand.intRangeAtMost(u32, 8, 128));
        rand.bytes(bytes);
        const a: Atom = .{ .key = keys[n_text + i], .name = names[n_text + i], .section = .rodata, .alignment = .@"8", .bytes = bytes };
        try atoms.append(arena, a);
        if (i % 4 == 0) try atoms.append(arena, a);
    }
    for (0..n_data) |i| {
        const bytes = try arena.alloc(u8, 32);
        rand.bytes(bytes);
        const relocs = try arena.alloc(Atom.Reloc, 2);
        for (relocs, 0..) |*r, j| r.* = .{ .offset = @intCast(j * 8), .kind = .x86_64_abs64, .target = keys[rand.uintLessThan(usize, keys.len - n_bss)], .addend = 0 };
        n_relocs += 2;
        const k = n_text + n_rodata + i;
        try atoms.append(arena, .{ .key = keys[k], .name = names[k], .section = .data, .alignment = .@"8", .bytes = bytes, .relocs = relocs });
    }
    for (0..n_bss) |i| {
        const k = n_text + n_rodata + n_data + i;
        try atoms.append(arena, .{ .key = keys[k], .name = names[k], .section = .bss, .alignment = .@"8", .zero_fill = 64 });
    }
    // Shuffle so that sections are interleaved in the input, as they are when
    // parallel CodeGen workers finish in arbitrary order.
    rand.shuffle(Atom, atoms.items);

    var content_bytes: usize = 0;
    for (atoms.items) |a| content_bytes += a.bytes.len;
    const options: Elf.Options = .{ .entry = keys[0] };

    var best_link: u64 = std.math.maxInt(u64);
    var best_copy: u64 = std.math.maxInt(u64);
    var out_len: usize = 0;
    for (0..runs) |_| {
        {
            const t = std.Io.Timestamp.now(io, .awake);
            const out = try Elf.emit(gpa, atoms.items, options);
            best_link = @min(best_link, elapsed(io, t));
            out_len = out.len;
            gpa.free(out);
        }
        {
            // Floor: copy every atom's bytes once into a fresh buffer.
            const t = std.Io.Timestamp.now(io, .awake);
            const out = try gpa.alloc(u8, content_bytes);
            var at: usize = 0;
            for (atoms.items) |a| {
                @memcpy(out[at..][0..a.bytes.len], a.bytes);
                at += a.bytes.len;
            }
            std.mem.doNotOptimizeAway(out.ptr);
            best_copy = @min(best_copy, elapsed(io, t));
            gpa.free(out);
        }
    }

    var with_write: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const t = std.Io.Timestamp.now(io, .awake);
        try Elf.link(gpa, io, std.Io.Dir.cwd(), "/tmp/zap-bench-link.out", atoms.items, options);
        with_write = @min(with_write, elapsed(io, t));
    }

    const ms = struct {
        fn f(ns: u64) f64 {
            return @as(f64, @floatFromInt(ns)) / 1e6;
        }
    }.f;
    std.debug.print(
        \\atoms: {d} ({d} after dedup), relocations: {d}, atom bytes: {d:.1} MiB, output: {d:.1} MiB
        \\emit (best of {d}):        {d:.2} ms  ({d:.0} atoms/s, {d:.0} MiB/s of output)
        \\memcpy floor (best of {d}): {d:.2} ms
        \\emit / memcpy floor:       {d:.2}x
        \\link incl. file write:     {d:.2} ms (best of 5, /tmp/zap-bench-link.out)
        \\
    , .{
        atoms.items.len,                      keys.len,
        n_relocs,                             mib(content_bytes),
        mib(out_len),                         runs,
        ms(best_link),                        @as(f64, @floatFromInt(atoms.items.len)) / (ms(best_link) / 1e3),
        mib(out_len) / (ms(best_link) / 1e3), runs,
        ms(best_copy),                        ms(best_link) / ms(best_copy),
        ms(with_write),
    });
}

fn elapsed(io: std.Io, start: std.Io.Timestamp) u64 {
    return @intCast(start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);
}

fn mib(n: usize) f64 {
    return @as(f64, @floatFromInt(n)) / (1 << 20);
}
