//! Link throughput benchmark: `zig build bench-link`. Builds synthetic sets
//! of about 100k atoms shaped like a Debug build (mostly functions, each
//! calling others and referencing constants; some data and bss), links each
//! with `Elf.emit` several times, and compares against copying the same bytes
//! into a fresh buffer, which is the floor for a memcpy-dominated linker.
//!
//! Two relocation target distributions:
//! - random: every target uniformly random. Worst case for caches.
//! - mixed: an assumed Debug-build mix. Half the references go to 512 hot
//!   symbols with a skewed distribution (panic and safety-check handlers,
//!   memcpy, common std functions), a fifth to a few constants shared by
//!   neighboring functions (string literals), the rest uniformly random.

const std = @import("std");
const Atom = @import("link/Atom.zig");
const Elf = @import("link/Elf.zig");

const n_text = 80_000;
const n_rodata = 15_000;
const n_data = 4_000;
const n_bss = 1_000;
const n_hot = 512;
const runs = 15;
const out_path = "/tmp/zap-bench-link.out";

const Mode = enum { random, mixed };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const keys = try arena.alloc(Atom.SymbolKey, n_text + n_rodata + n_data + n_bss);
    const names = try arena.alloc([]const u8, keys.len);
    for (keys, names, 0..) |*k, *n, i| {
        n.* = try std.fmt.allocPrint(arena, "bench:file{d}.zig:decl{d}", .{ i % 500, i });
        k.* = .fromName(n.*);
    }

    const cpus = std.Thread.getCpuCount() catch 1;
    for ([_]Mode{ .random, .mixed }) |mode| {
        var prng: std.Random.DefaultPrng = .init(0x5eed);
        const atoms = try generate(arena, prng.random(), keys, names, mode);
        var content_bytes: usize = 0;
        var n_relocs: usize = 0;
        var n_targets: usize = 0;
        for (atoms) |a| {
            content_bytes += a.bytes.len;
            n_relocs += a.relocs.len;
            n_targets += a.targets.len;
        }
        const single: Elf.Options = .{ .entry = keys[0], .threads = 1 };
        const parallel: Elf.Options = .{ .entry = keys[0] };

        // Threads must not change the output.
        const out1 = try Elf.emit(gpa, io, atoms, single);
        defer gpa.free(out1);
        const out_n = try Elf.emit(gpa, io, atoms, parallel);
        defer gpa.free(out_n);
        if (!std.mem.eql(u8, out1, out_n)) @panic("output depends on the thread count");

        var best_single: u64 = std.math.maxInt(u64);
        var best_parallel: u64 = std.math.maxInt(u64);
        var best_copy: u64 = std.math.maxInt(u64);
        var best_copy_n: u64 = std.math.maxInt(u64);
        for (0..runs) |_| {
            best_single = @min(best_single, try timeEmit(gpa, io, atoms, single));
            best_parallel = @min(best_parallel, try timeEmit(gpa, io, atoms, parallel));
            best_copy_n = @min(best_copy_n, try floor(gpa, io, atoms, cpus));
            best_copy = @min(best_copy, try floor(gpa, io, atoms, 1));
        }

        var with_write: u64 = std.math.maxInt(u64);
        for (0..runs) |_| {
            const t = std.Io.Timestamp.now(io, .awake);
            try Elf.link(gpa, io, std.Io.Dir.cwd(), out_path, atoms, parallel);
            with_write = @min(with_write, elapsed(io, t));
        }
        const file = try std.Io.Dir.cwd().readFileAlloc(io, out_path, gpa, .unlimited);
        defer gpa.free(file);
        if (!std.mem.eql(u8, file, out_n)) @panic("link wrote different bytes than emit returned");

        std.debug.print(
            \\{t} targets: {d} atoms ({d} after dedup), {d} relocations to {d} per-atom targets, atom bytes {d:.1} MiB, output {d:.1} MiB
            \\  memcpy floor, 1 thread:    {d:.2} ms
            \\  memcpy floor, {d} threads:   {d:.2} ms
            \\  emit, 1 thread:            {d:.2} ms  {d:.2}x the 1-thread floor  ({d:.0} atoms/s)
            \\  emit, {d} threads:           {d:.2} ms  {d:.2}x the 1-thread floor, {d:.2}x the {d}-thread floor  ({d:.0} atoms/s)
            \\  link to a file, {d} threads: {d:.2} ms
            \\
        , .{
            mode,                                atoms.len,
            keys.len,                            n_relocs,
            n_targets,                           mib(content_bytes),
            mib(out1.len),                       ms(best_copy),
            cpus,                                ms(best_copy_n),
            ms(best_single),                     ms(best_single) / ms(best_copy),
            rate(atoms.len, best_single),        cpus,
            ms(best_parallel),                   ms(best_parallel) / ms(best_copy),
            ms(best_parallel) / ms(best_copy_n), cpus,
            rate(atoms.len, best_parallel),      cpus,
            ms(with_write),
        });
    }
    std.debug.print("(best of {d} runs each)\n", .{runs});
}

/// The floor for `threads` threads: copy every atom's bytes once into a
/// fresh buffer, faulted in the way `emit` faults in its output, each thread
/// a contiguous run of atoms.
fn floor(gpa: std.mem.Allocator, io: std.Io, atoms: []const Atom, threads: usize) !u64 {
    const t = std.Io.Timestamp.now(io, .awake);
    var starts: [64]usize = undefined;
    const n = @min(threads, starts.len - 1);
    var at: usize = 0;
    for (0..n) |i| {
        starts[i] = at;
        for (atoms[i * atoms.len / n .. (i + 1) * atoms.len / n]) |a| at += a.bytes.len;
    }
    starts[n] = at;
    const out = try gpa.alloc(u8, at);
    Elf.adviseHugePages(out);
    const Worker = struct {
        fn work(dst: []u8, part: []const Atom) void {
            Elf.populate(dst);
            var off: usize = 0;
            for (part) |a| {
                @memcpy(dst[off..][0..a.bytes.len], a.bytes);
                off += a.bytes.len;
            }
        }
    };
    var group: std.Io.Group = .init;
    for (1..n) |i| group.async(io, Worker.work, .{ out[starts[i]..starts[i + 1]], atoms[i * atoms.len / n .. (i + 1) * atoms.len / n] });
    Worker.work(out[0..starts[1]], atoms[0 .. atoms.len / n]);
    try group.await(io);
    std.mem.doNotOptimizeAway(out.ptr);
    const ns = elapsed(io, t);
    gpa.free(out);
    return ns;
}

fn timeEmit(gpa: std.mem.Allocator, io: std.Io, atoms: []const Atom, options: Elf.Options) !u64 {
    const t = std.Io.Timestamp.now(io, .awake);
    const out = try Elf.emit(gpa, io, atoms, options);
    const ns = elapsed(io, t);
    gpa.free(out);
    return ns;
}

fn rate(n: usize, ns: u64) f64 {
    return @as(f64, @floatFromInt(n)) / (@as(f64, @floatFromInt(ns)) / 1e9);
}

fn generate(arena: std.mem.Allocator, rand: std.Random, keys: []const Atom.SymbolKey, names: []const []const u8, mode: Mode) ![]Atom {
    var atoms: std.ArrayList(Atom) = .empty;
    var targets: std.AutoArrayHashMapUnmanaged(Atom.SymbolKey, void) = .empty;
    // Each atom's name, bytes, relocations, and targets are allocated
    // together, as CodeGen's arena or a cache entry would hold them, and the
    // copy floor reads the same real memory.
    // Functions: 32..512 bytes, one call or constant reference per 32 bytes.
    for (0..n_text) |i| {
        const name = try arena.dupe(u8, names[i]);
        const len = rand.intRangeAtMost(u32, 32, 512);
        const bytes = try arena.alloc(u8, len);
        rand.bytes(bytes);
        const relocs = try arena.alloc(Atom.Reloc, len / 32);
        targets.clearRetainingCapacity();
        for (relocs, 0..) |*r, j| {
            const call = rand.boolean();
            const target = switch (mode) {
                .random => if (call) rand.uintLessThan(usize, n_text) else n_text + rand.uintLessThan(usize, n_rodata),
                .mixed => switch (rand.uintLessThan(u8, 10)) {
                    0...4 => blk: {
                        const u = rand.float(f64);
                        break :blk @as(usize, @intFromFloat(u * u * u * n_hot));
                    },
                    5, 6 => n_text + i * n_rodata / n_text + rand.uintLessThan(usize, 2),
                    else => if (call) rand.uintLessThan(usize, n_text) else n_text + rand.uintLessThan(usize, n_rodata),
                },
            };
            const gop = try targets.getOrPut(arena, keys[target]);
            r.* = .init(@intCast(j * 32 + 1), .x86_64_pc32, @intCast(gop.index), -4);
        }
        try atoms.append(arena, .{ .key = keys[i], .name = name, .section = .text, .alignment = .@"16", .bytes = bytes, .targets = try arena.dupe(Atom.SymbolKey, targets.keys()), .relocs = relocs });
    }
    // Constants: 8..128 bytes; every fourth one is emitted twice, as two
    // functions producing the same content-addressed constant would.
    for (0..n_rodata) |i| {
        const name = try arena.dupe(u8, names[n_text + i]);
        const bytes = try arena.alloc(u8, rand.intRangeAtMost(u32, 8, 128));
        rand.bytes(bytes);
        const a: Atom = .{ .key = keys[n_text + i], .name = name, .section = .rodata, .alignment = .@"8", .bytes = bytes };
        try atoms.append(arena, a);
        if (i % 4 == 0) try atoms.append(arena, a);
    }
    for (0..n_data) |i| {
        const name = try arena.dupe(u8, names[n_text + n_rodata + i]);
        const bytes = try arena.alloc(u8, 32);
        rand.bytes(bytes);
        const t = try arena.alloc(Atom.SymbolKey, 2);
        for (t) |*k| k.* = keys[rand.uintLessThan(usize, keys.len - n_bss)];
        if (t[0] == t[1]) t[1] = keys[0];
        const relocs = try arena.dupe(Atom.Reloc, &.{ .init(0, .x86_64_abs64, 0, 0), .init(8, .x86_64_abs64, 1, 0) });
        const k = n_text + n_rodata + i;
        try atoms.append(arena, .{ .key = keys[k], .name = name, .section = .data, .alignment = .@"8", .bytes = bytes, .targets = t, .relocs = relocs });
    }
    for (0..n_bss) |i| {
        const k = n_text + n_rodata + n_data + i;
        try atoms.append(arena, .{ .key = keys[k], .name = names[k], .section = .bss, .alignment = .@"8", .zero_fill = 64 });
    }
    // Shuffle so that sections are interleaved in the input, as they are when
    // parallel CodeGen workers finish in arbitrary order.
    rand.shuffle(Atom, atoms.items);
    return atoms.items;
}

fn elapsed(io: std.Io, start: std.Io.Timestamp) u64 {
    return @intCast(start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn mib(n: usize) f64 {
    return @as(f64, @floatFromInt(n)) / (1 << 20);
}
