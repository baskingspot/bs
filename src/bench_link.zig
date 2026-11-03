//! Link throughput benchmark: `zig build bench-link` (ELF, x86_64 atoms) or
//! `zig build bench-link -- macho` (Mach-O, aarch64 atoms). Builds synthetic
//! sets of about 100k atoms shaped like a Debug build (mostly functions, each
//! calling others and referencing constants; some data and bss), links each
//! with `emit` several times, and compares against copying the same bytes
//! into a fresh buffer, which is the floor for a memcpy-dominated linker.
//!
//! The aarch64 atoms reference a constant with an adrp/add pair (two
//! relocations where x86_64 has one), call 64 libSystem imports with 1 in 32
//! of their calls, and their data's absolute addresses become chained
//! fixups. Mach-O output also includes hashing every page for the code
//! signature.
//!
//! Two relocation target distributions:
//! - random: every target uniformly random. Worst case for caches.
//! - mixed: an assumed Debug-build mix. Half the references go to 512 hot
//!   symbols with a skewed distribution (panic and safety-check handlers,
//!   memcpy, common std functions), a fifth to a few constants shared by
//!   neighboring functions (string literals), the rest uniformly random.
//!
//! Every function has debug info: one of 500 files, and a line row every
//! 8..40 bytes. Each emit is also timed without it, to show its cost.
//! Mach-O does not emit debug info yet.
//!
//! Both formats are also linked with numbered symbols (`Options.symbols`),
//! as the cache's manifest would supply them: from the same scattered
//! atoms, and from "packed" atoms whose records lie one after another in
//! link order, as in a compacted pack (targets, relocations, bytes, name).
//! Both must produce the same bytes as the key-based link.
//!
//! ELF links to a file are timed with each `Elf.FileWrites`, overwriting
//! the previous output in place and into a new file, on 1 and all threads.

const std = @import("std");
const Atom = @import("link/Atom.zig");
const Elf = @import("link/Elf.zig");
const MachO = @import("link/MachO.zig");

const n_text = 80_000;
const n_rodata = 15_000;
const n_data = 4_000;
const n_bss = 1_000;
const n_hot = 512;
const runs = 15;
const out_path = "/tmp/zap-bench-link.out";

const n_imports = 64;

const Mode = enum { random, mixed };
const Format = enum { elf, macho };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const format: Format = if (args.len > 1) std.meta.stringToEnum(Format, args[1]) orelse {
        std.debug.print("usage: bench-link [elf|macho]\n", .{});
        std.process.exit(1);
    } else .elf;
    switch (format) {
        inline else => |f| try bench(f, gpa, io, arena),
    }
}

fn bench(comptime format: Format, gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator) !void {
    const L = switch (format) {
        .elf => Elf,
        .macho => MachO,
    };
    const keys = try arena.alloc(Atom.SymbolKey, n_text + n_rodata + n_data + n_bss);
    const names = try arena.alloc([]const u8, keys.len);
    for (keys, names, 0..) |*k, *n, i| {
        n.* = try std.fmt.allocPrint(arena, "bench:file{d}.zig:decl{d}", .{ i % 500, i });
        k.* = .fromName(n.*);
    }

    var imports: [n_imports]MachO.Import = undefined;
    for (&imports, 0..) |*imp, i| {
        imp.name = try std.fmt.allocPrint(arena, "_imp{d}", .{i});
        imp.key = .fromName(imp.name);
    }

    const cpus = std.Thread.getCpuCount() catch 1;
    for ([_]Mode{ .random, .mixed }) |mode| {
        var prng: std.Random.DefaultPrng = .init(0x5eed);
        const atoms, const debug = try generate(arena, prng.random(), keys, names, mode, format, &imports);
        var content_bytes: usize = 0;
        var n_relocs: usize = 0;
        var n_targets: usize = 0;
        for (atoms) |a| {
            content_bytes += a.bytes.len;
            n_relocs += a.relocs.len;
            n_targets += a.targets.len;
        }
        var debug_bytes: usize = 0;
        for (debug) |d| debug_bytes += d.lines.len;
        var single: L.Options = .{ .entry = keys[0], .threads = 1 };
        switch (format) {
            .elf => single.comp_dir = "/bench",
            .macho => {
                single.imports = &imports;
                // As `link` names it, so the file and `emit` match.
                single.identifier = std.fs.path.basename(out_path);
            },
        }
        var parallel = single;
        parallel.threads = null;
        // Mach-O has no debug info yet, so stripping changes nothing.
        const single_strip = single;
        const parallel_strip = parallel;
        if (format == .elf) {
            single.debug = debug;
            parallel.debug = debug;
        }

        // Threads must not change the output.
        const out1 = try L.emit(gpa, io, atoms, single);
        defer gpa.free(out1);
        const out_n = try L.emit(gpa, io, atoms, parallel);
        defer gpa.free(out_n);
        if (!std.mem.eql(u8, out1, out_n)) @panic("output depends on the thread count");
        const stripped = try L.emit(gpa, io, atoms, parallel_strip);
        defer gpa.free(stripped);

        var best_single: u64 = std.math.maxInt(u64);
        var best_parallel: u64 = std.math.maxInt(u64);
        var best_copy: u64 = std.math.maxInt(u64);
        var best_copy_n: u64 = std.math.maxInt(u64);
        var best_single_strip: u64 = std.math.maxInt(u64);
        var best_parallel_strip: u64 = std.math.maxInt(u64);
        for (0..runs) |_| {
            best_single = @min(best_single, try timeEmit(L, gpa, io, atoms, single));
            best_parallel = @min(best_parallel, try timeEmit(L, gpa, io, atoms, parallel));
            best_single_strip = @min(best_single_strip, try timeEmit(L, gpa, io, atoms, single_strip));
            best_parallel_strip = @min(best_parallel_strip, try timeEmit(L, gpa, io, atoms, parallel_strip));
            best_copy_n = @min(best_copy_n, try floor(gpa, io, atoms, cpus));
            best_copy = @min(best_copy, try floor(gpa, io, atoms, 1));
        }

        var with_write: u64 = std.math.maxInt(u64);
        for (0..runs) |_| {
            const t = std.Io.Timestamp.now(io, .awake);
            try L.link(gpa, io, std.Io.Dir.cwd(), out_path, atoms, parallel);
            with_write = @min(with_write, elapsed(io, t));
        }
        const file = try std.Io.Dir.cwd().readFileAlloc(io, out_path, gpa, .unlimited);
        defer gpa.free(file);
        if (!std.mem.eql(u8, file, out_n)) @panic("link wrote different bytes than emit returned");

        std.debug.print(
            \\{t} {t} targets: {d} atoms ({d} after dedup), {d} relocations to {d} per-atom targets, atom bytes {d:.1} MiB, line programs {d:.1} MiB, output {d:.1} MiB ({d:.1} MiB stripped)
            \\  memcpy floor, 1 thread:    {d:.2} ms
            \\  memcpy floor, {d} threads:   {d:.2} ms
            \\  emit, 1 thread:            {d:.2} ms  {d:.2}x the 1-thread floor  ({d:.0} atoms/s); stripped {d:.2} ms
            \\  emit, {d} threads:           {d:.2} ms  {d:.2}x the 1-thread floor, {d:.2}x the {d}-thread floor  ({d:.0} atoms/s); stripped {d:.2} ms
            \\  link to a file, {d} threads: {d:.2} ms
            \\
        , .{
            format,                              mode,
            atoms.len,                           keys.len,
            n_relocs,                            n_targets,
            mib(content_bytes),                  mib(debug_bytes),
            mib(out1.len),                       mib(stripped.len),
            ms(best_copy),                       cpus,
            ms(best_copy_n),                     ms(best_single),
            ms(best_single) / ms(best_copy),     rate(atoms.len, best_single),
            ms(best_single_strip),               cpus,
            ms(best_parallel),                   ms(best_parallel) / ms(best_copy),
            ms(best_parallel) / ms(best_copy_n), cpus,
            rate(atoms.len, best_parallel),      ms(best_parallel_strip),
            cpus,                                ms(with_write),
        });
        if (format == .elf) try linkToFile(gpa, io, atoms, single, parallel, out_n, cpus);
        switch (format) {
            .elf => try benchNumbered(gpa, io, arena, atoms, debug, single, out_n, stripped, cpus),
            .macho => try benchNumberedMachO(gpa, io, arena, atoms, single, cpus),
        }
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

/// Times the numbered-symbol link of the atoms the key-based link keeps,
/// scattered as generated and packed in link order.
fn benchNumbered(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, all: []const Atom, all_debug: []const Atom.Debug, options: Elf.Options, expected: []const u8, expected_stripped: []const u8, cpus: usize) !void {
    // Number the kept atoms in link order, as a first build's manifest would.
    var numbers: std.AutoHashMapUnmanaged(Atom.SymbolKey, u32) = .empty;
    var kept: std.ArrayList(Atom) = .empty;
    const new_index = try arena.alloc(u32, all.len);
    for (all, new_index) |a, *ni| {
        const gop = try numbers.getOrPut(arena, a.key);
        if (gop.found_existing) {
            ni.* = std.math.maxInt(u32);
            continue;
        }
        gop.value_ptr.* = @intCast(kept.items.len);
        ni.* = @intCast(kept.items.len);
        try kept.append(arena, a);
    }
    var debug: std.ArrayList(Atom.Debug) = .empty;
    for (all_debug) |d| if (new_index[d.atom] != std.math.maxInt(u32)) {
        var nd = d;
        nd.atom = new_index[d.atom];
        try debug.append(arena, nd);
    };
    const atom_numbers = try arena.alloc(Elf.NumberedAtom, kept.items.len);
    var targets: std.ArrayList(u32) = .empty;
    for (atom_numbers, kept.items, 0..) |*n, a, i| {
        n.* = .{ .symbol = @intCast(i), .targets = @intCast(targets.items.len) };
        for (a.targets) |t| try targets.append(arena, numbers.get(t).?);
    }
    var single = options;
    single.symbols = .{ .atoms = atom_numbers, .targets = targets.items, .entry = numbers.get(options.entry).?, .len = @intCast(kept.items.len) };
    single.debug = debug.items;

    // The same atoms with their records back to back in link order, debug
    // info last. Source paths stay shared, as if the cache interned them.
    const packed_atoms = try arena.dupe(Atom, kept.items);
    const packed_debug = try arena.dupe(Atom.Debug, debug.items);
    var total: usize = 0;
    for (packed_atoms) |a| total += 16 + 16 * a.targets.len + 12 * a.relocs.len + a.bytes.len + a.name.len;
    for (packed_debug) |d| total += d.name.len + d.lines.len;
    const pack = try arena.alignedAlloc(u8, .@"16", total);
    var at: usize = 0;
    var next_debug: usize = 0;
    for (packed_atoms, 0..) |*a, i| {
        const record = at;
        a.targets = put(Atom.SymbolKey, pack, &at, a.targets);
        a.relocs = put(Atom.Reloc, pack, &at, a.relocs);
        a.bytes = put(u8, pack, &at, a.bytes);
        a.name = put(u8, pack, &at, a.name);
        if (next_debug < packed_debug.len and packed_debug[next_debug].atom == i) {
            const d = &packed_debug[next_debug];
            d.name = put(u8, pack, &at, d.name);
            d.lines = put(u8, pack, &at, d.lines);
            next_debug += 1;
        }
        at = record + std.mem.alignForward(usize, at - record, 16);
    }

    const variants = [_]struct { []const u8, []const Atom, []const Atom.Debug }{ .{ "scattered", kept.items, debug.items }, .{ "packed", packed_atoms, packed_debug } };
    for (variants) |v| {
        const name, const atoms, single.debug = v;
        var parallel = single;
        parallel.threads = null;
        var single_strip = single;
        single_strip.debug = &.{};
        var parallel_strip = parallel;
        parallel_strip.debug = &.{};
        const out1 = try Elf.emit(gpa, io, atoms, single);
        defer gpa.free(out1);
        const out_n = try Elf.emit(gpa, io, atoms, parallel_strip);
        defer gpa.free(out_n);
        if (!std.mem.eql(u8, out1, expected) or !std.mem.eql(u8, out_n, expected_stripped)) @panic("numbered symbols changed the output");
        var best: [4]u64 = @splat(std.math.maxInt(u64));
        for (0..runs) |_| {
            for (&best, [_]Elf.Options{ single, parallel, single_strip, parallel_strip }) |*b, o| b.* = @min(b.*, try timeEmit(Elf, gpa, io, atoms, o));
        }
        std.debug.print(
            \\  numbered, {s}: emit {d:.2} ms on 1 thread, {d:.2} ms on {d}; stripped {d:.2} ms, {d:.2} ms
            \\
        , .{ name, ms(best[0]), ms(best[1]), cpus, ms(best[2]), ms(best[3]) });
        try linkToFile(gpa, io, atoms, single, parallel, expected, cpus);
    }
}

/// Times `Elf.link` on 1 and all threads with each way of writing the
/// file: over the previous output, which it overwrites in place, and into
/// a new file (the old one deleted beforehand, untimed). Checks that each
/// writes `expected`.
fn linkToFile(gpa: std.mem.Allocator, io: std.Io, atoms: []const Atom, single: Elf.Options, parallel: Elf.Options, expected: []const u8, cpus: usize) !void {
    const cwd = std.Io.Dir.cwd();
    for ([_][]const u8{ "in place", "new file" }) |case| {
        const fresh = case[0] == 'n';
        var best: [3][2]u64 = @splat(@splat(std.math.maxInt(u64)));
        for (0..runs) |_| {
            for (&best, [_]Elf.FileWrites{ .auto, .map, .pwrite }) |*b, writes| {
                for (b, [_]Elf.Options{ single, parallel }) |*t_best, options| {
                    var o = options;
                    o.file_writes = writes;
                    if (fresh) cwd.deleteFile(io, out_path) catch {};
                    const t = std.Io.Timestamp.now(io, .awake);
                    try Elf.link(gpa, io, cwd, out_path, atoms, o);
                    t_best.* = @min(t_best.*, elapsed(io, t));
                }
                const file = try cwd.readFileAlloc(io, out_path, gpa, .unlimited);
                defer gpa.free(file);
                if (!std.mem.eql(u8, file, expected)) @panic("link wrote different bytes than emit returned");
            }
        }
        std.debug.print(
            \\    link to a file, {s}: auto {d:.2} ms on 1 thread, {d:.2} ms on {d}; map {d:.2}, {d:.2}; pwrite {d:.2}, {d:.2}
            \\
        , .{ case, ms(best[0][0]), ms(best[0][1]), cpus, ms(best[1][0]), ms(best[1][1]), ms(best[2][0]), ms(best[2][1]) });
    }
}

/// `benchNumbered` for Mach-O, which numbers its imports too and has no
/// debug info. Compares against the key-based link of the kept atoms.
fn benchNumberedMachO(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, all: []const Atom, options: MachO.Options, cpus: usize) !void {
    var numbers: std.AutoHashMapUnmanaged(Atom.SymbolKey, u32) = .empty;
    var kept: std.ArrayList(Atom) = .empty;
    for (all) |a| {
        const gop = try numbers.getOrPut(arena, a.key);
        if (gop.found_existing) continue;
        gop.value_ptr.* = @intCast(kept.items.len);
        try kept.append(arena, a);
    }
    const import_numbers = try arena.alloc(u32, options.imports.len);
    for (options.imports, import_numbers) |imp, *n| {
        const gop = try numbers.getOrPut(arena, imp.key);
        if (!gop.found_existing) gop.value_ptr.* = @intCast(numbers.count() - 1);
        n.* = gop.value_ptr.*;
    }
    const atom_numbers = try arena.alloc(Elf.NumberedAtom, kept.items.len);
    var targets: std.ArrayList(u32) = .empty;
    for (atom_numbers, kept.items, 0..) |*n, a, i| {
        n.* = .{ .symbol = @intCast(i), .targets = @intCast(targets.items.len) };
        for (a.targets) |t| try targets.append(arena, numbers.get(t).?);
    }
    const expected = try MachO.emit(gpa, io, kept.items, options);
    defer gpa.free(expected);
    var single = options;
    single.symbols = .{ .atoms = atom_numbers, .targets = targets.items, .imports = import_numbers, .entry = numbers.get(options.entry).?, .len = numbers.count() };

    const packed_atoms = try arena.dupe(Atom, kept.items);
    var total: usize = 0;
    for (packed_atoms) |a| total += 16 + 16 * a.targets.len + 12 * a.relocs.len + a.bytes.len + a.name.len;
    const pack = try arena.alignedAlloc(u8, .@"16", total);
    var at: usize = 0;
    for (packed_atoms) |*a| {
        const record = at;
        a.targets = put(Atom.SymbolKey, pack, &at, a.targets);
        a.relocs = put(Atom.Reloc, pack, &at, a.relocs);
        a.bytes = put(u8, pack, &at, a.bytes);
        a.name = put(u8, pack, &at, a.name);
        at = record + std.mem.alignForward(usize, at - record, 16);
    }

    const keyed_parallel = blk: {
        var o = options;
        o.threads = null;
        var best: u64 = std.math.maxInt(u64);
        for (0..runs) |_| best = @min(best, try timeEmit(MachO, gpa, io, kept.items, o));
        break :blk best;
    };
    std.debug.print("  keys, deduplicated atoms: emit {d:.2} ms on {d}\n", .{ ms(keyed_parallel), cpus });
    for ([_]struct { []const u8, []const Atom }{ .{ "scattered", kept.items }, .{ "packed", packed_atoms } }) |v| {
        const name, const atoms = v;
        var parallel = single;
        parallel.threads = null;
        for ([_]MachO.Options{ single, parallel }) |o| {
            const out = try MachO.emit(gpa, io, atoms, o);
            defer gpa.free(out);
            if (!std.mem.eql(u8, out, expected)) @panic("numbered symbols changed the output");
        }
        var best: [2]u64 = @splat(std.math.maxInt(u64));
        for (0..runs) |_| {
            for (&best, [_]MachO.Options{ single, parallel }) |*b, o| b.* = @min(b.*, try timeEmit(MachO, gpa, io, atoms, o));
        }
        std.debug.print("  numbered, {s}: emit {d:.2} ms on 1 thread, {d:.2} ms on {d}\n", .{ name, ms(best[0]), ms(best[1]), cpus });
    }
}

fn put(comptime T: type, pack: []align(16) u8, at: *usize, items: []const T) []const T {
    at.* = std.mem.alignForward(usize, at.*, @alignOf(T));
    const bytes = std.mem.sliceAsBytes(items);
    @memcpy(pack[at.*..][0..bytes.len], bytes);
    const out: []const T = @ptrCast(@alignCast(pack[at.*..][0..bytes.len]));
    at.* += bytes.len;
    return out;
}

fn timeEmit(comptime L: type, gpa: std.mem.Allocator, io: std.Io, atoms: []const Atom, options: L.Options) !u64 {
    const t = std.Io.Timestamp.now(io, .awake);
    const out = try L.emit(gpa, io, atoms, options);
    const ns = elapsed(io, t);
    gpa.free(out);
    return ns;
}

fn rate(n: usize, ns: u64) f64 {
    return @as(f64, @floatFromInt(n)) / (@as(f64, @floatFromInt(ns)) / 1e9);
}

fn generate(arena: std.mem.Allocator, rand: std.Random, keys: []const Atom.SymbolKey, names: []const []const u8, mode: Mode, format: Format, imports: []const MachO.Import) !struct { []Atom, []Atom.Debug } {
    var atoms: std.ArrayList(Atom) = .empty;
    // Each function's debug info, by its index in `atoms` before shuffling.
    var debug: std.ArrayList(Atom.Debug) = .empty;
    var targets: std.AutoArrayHashMapUnmanaged(Atom.SymbolKey, void) = .empty;
    // Each atom's name, bytes, relocations, and targets are allocated
    // together, as CodeGen's arena or a cache entry would hold them, and the
    // copy floor reads the same real memory.
    var files: [500][]const u8 = undefined;
    for (&files, 0..) |*f, j| f.* = try std.fmt.allocPrint(arena, "src/dir{d}/file{d}.zig", .{ j % 20, j });
    // Functions: 32..512 bytes, one call or constant reference per 32 bytes.
    for (0..n_text) |i| {
        const name = try arena.dupe(u8, names[i]);
        const len = rand.intRangeAtMost(u32, 32, 512);
        const bytes = try arena.alloc(u8, len);
        rand.bytes(bytes);
        var relocs: std.ArrayList(Atom.Reloc) = .empty;
        targets.clearRetainingCapacity();
        for (0..len / 32) |j| {
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
            switch (format) {
                .elf => {
                    const gop = try targets.getOrPut(arena, keys[target]);
                    try relocs.append(arena, .init(@intCast(j * 32 + 1), .x86_64_pc32, @intCast(gop.index), -4));
                },
                .macho => {
                    // The patched instructions must be real: the linker
                    // reads the access size from adrp's partner.
                    const off: u32 = @intCast(j * 32);
                    if (target < n_text) {
                        const key = if (rand.uintLessThan(u8, 32) == 0) imports[rand.uintLessThan(usize, imports.len)].key else keys[target];
                        const gop = try targets.getOrPut(arena, key);
                        std.mem.writeInt(u32, bytes[off..][0..4], 0x94000000, .little); // bl
                        try relocs.append(arena, .init(off, .aarch64_branch26, @intCast(gop.index), 0));
                    } else {
                        const gop = try targets.getOrPut(arena, keys[target]);
                        std.mem.writeInt(u32, bytes[off..][0..4], 0x90000000, .little); // adrp x0
                        std.mem.writeInt(u32, bytes[off + 4 ..][0..4], 0x91000000, .little); // add x0, x0
                        try relocs.append(arena, .init(off, .aarch64_page21, @intCast(gop.index), 0));
                        try relocs.append(arena, .init(off + 4, .aarch64_pageoff12, @intCast(gop.index), 0));
                    }
                },
            }
        }
        var lines: Atom.LineProgram = .{};
        var offset: u32 = 0;
        var line: u32 = 0;
        while (offset < len) : (offset += rand.intRangeAtMost(u32, 8, 40)) {
            try lines.addRow(arena, offset, line, rand.intRangeAtMost(u32, 4, 40));
            line += rand.intRangeAtMost(u32, 1, 3);
        }
        try debug.append(arena, .{ .atom = @intCast(atoms.items.len), .file = files[i % files.len], .name = name[std.mem.lastIndexOfScalar(u8, name, ':').? + 1 ..], .base_line = rand.uintLessThan(u32, 5000), .lines = lines.bytes.items, .frame = .frame_pointer });
        try atoms.append(arena, .{ .key = keys[i], .name = name, .section = .text, .alignment = .@"16", .bytes = bytes, .targets = try arena.dupe(Atom.SymbolKey, targets.keys()), .relocs = relocs.items });
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
        const abs64: Atom.Reloc.Kind = if (format == .elf) .x86_64_abs64 else .aarch64_abs64;
        const relocs = try arena.dupe(Atom.Reloc, &.{ .init(0, abs64, 0, 0), .init(8, abs64, 1, 0) });
        const k = n_text + n_rodata + i;
        try atoms.append(arena, .{ .key = keys[k], .name = name, .section = .data, .alignment = .@"8", .bytes = bytes, .targets = t, .relocs = relocs });
    }
    for (0..n_bss) |i| {
        const k = n_text + n_rodata + n_data + i;
        try atoms.append(arena, .{ .key = keys[k], .name = names[k], .section = .bss, .alignment = .@"8", .zero_fill = 64 });
    }
    // Shuffle so that sections are interleaved in the input, as they are when
    // parallel CodeGen workers finish in arbitrary order.
    // The debug entries follow their atoms, in the new atom order.
    const order = try arena.alloc(u32, atoms.items.len);
    for (order, 0..) |*o, j| o.* = @intCast(j);
    rand.shuffle(u32, order);
    const shuffled = try arena.alloc(Atom, atoms.items.len);
    const new_index = try arena.alloc(u32, atoms.items.len);
    for (order, shuffled, 0..) |o, *a, j| {
        a.* = atoms.items[o];
        new_index[o] = @intCast(j);
    }
    for (debug.items) |*d| d.atom = new_index[d.atom];
    std.mem.sort(Atom.Debug, debug.items, {}, struct {
        fn lt(_: void, a: Atom.Debug, b: Atom.Debug) bool {
            return a.atom < b.atom;
        }
    }.lt);
    return .{ shuffled, debug.items };
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
