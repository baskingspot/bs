//! Scratch demo for verifying Mach-O debug info on a Mac (not for merge).
//! `zig test src/zz_macho_debug_demo.zig` writes, into $DEMO_DIR (default
//! /tmp/zap-demo): `demo` with demo.dSYM, and `demo-stripped`, linked
//! without debug info. Both call _Unwind_Backtrace from c (main -> a -> b ->
//! c) and exit with the number of frames libunwind walked. The test also
//! symbolizes the call in c through std.debug.MachOFile and prints it.

const std = @import("std");
const MachO = @import("link/MachO.zig");
const Atom = @import("link/Atom.zig");
const Encoder = @import("codegen/aarch64/Encoder.zig");
const SymbolKey = Atom.SymbolKey;

test "macho debug demo" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const main: SymbolKey = .fromName("_main");
    const a: SymbolKey = .fromName("a");
    const b: SymbolKey = .fromName("b");
    const c: SymbolKey = .fromName("c");
    const cb: SymbolKey = .fromName("cb");
    const counter: SymbolKey = .fromName("counter");
    const backtrace: SymbolKey = .fromName("__Unwind_Backtrace");

    var atoms: std.ArrayList(Atom) = .empty;
    var debug: std.ArrayList(Atom.Debug) = .empty;
    // Each instruction of a function is a row on its own line: function at
    // base line L (zero-based) has instruction k on line L + 1 + k.
    const Fn = struct { key: SymbolKey, name: []const u8, base_line: u32, frame: Atom.Debug.Frame };
    const fns = [_]Fn{
        .{ .key = main, .name = "main", .base_line = 0, .frame = .frame_pointer },
        .{ .key = a, .name = "a", .base_line = 10, .frame = .frame_pointer },
        .{ .key = b, .name = "b", .base_line = 20, .frame = .frame_pointer },
        .{ .key = c, .name = "c", .base_line = 30, .frame = .frame_pointer },
        .{ .key = cb, .name = "cb", .base_line = 40, .frame = .none },
    };
    for (fns, 0..) |f, i| {
        var e: Encoder = .init(arena);
        if (f.frame == .frame_pointer) {
            try e.stp(.dword, .fp, .lr, .{ .base = .sp, .offset = .{ .pre = -16 } });
            try e.mov(.x, .fp, .sp);
        }
        switch (i) {
            0 => {
                try e.bl(.{ .sym = a });
                try e.loadAddr(.x8, counter, 0);
                try e.ldr(.word, .x0, .at(.x8, 0));
            },
            1 => try e.bl(.{ .sym = b }),
            2 => try e.bl(.{ .sym = c }),
            3 => {
                try e.loadAddr(.x0, cb, 0);
                try e.loadAddr(.x1, counter, 0);
                try e.bl(.{ .sym = backtrace });
            },
            4 => {
                try e.ldr(.word, .x8, .at(.x1, 0));
                try e.addSub(.add, .w, .x8, .x8, .{ .imm = 1 });
                try e.str(.word, .x8, .at(.x1, 0));
                try e.movz(.w, .x0, 0, 0);
            },
            else => unreachable,
        }
        if (f.frame == .frame_pointer) try e.ldp(.dword, .fp, .lr, .{ .base = .sp, .offset = .{ .post = 16 } });
        try e.ret();
        try e.finish();
        var lines: Atom.LineProgram = .{};
        var off: u32 = 0;
        while (off < e.code.items.len) : (off += 4) try lines.addRow(arena, off, off / 4, 4);
        try debug.append(arena, .{ .atom = @intCast(atoms.items.len), .file = "demo.zig", .name = f.name, .base_line = f.base_line, .lines = lines.bytes.items, .frame = f.frame });
        try atoms.append(arena, .{ .key = f.key, .name = if (i == 0) "_main" else f.name, .section = .text, .alignment = .@"4", .bytes = e.code.items, .targets = e.refs.targets.keys(), .relocs = e.refs.relocs.items });
    }
    try atoms.append(arena, .{ .key = counter, .name = "counter", .section = .bss, .alignment = .@"4", .zero_fill = 4 });

    const dir_path = std.testing.environ.getAlloc(arena, "DEMO_DIR") catch "/tmp/zap-demo";
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    defer dir.close(io);
    const options: MachO.Options = .{
        .entry = main,
        .imports = &.{.{ .key = backtrace, .name = "__Unwind_Backtrace" }},
        .debug = debug.items,
        .comp_dir = dir_path,
    };
    try MachO.link(gpa, io, dir, "demo", atoms.items, options);
    var stripped = options;
    stripped.debug = &.{};
    try MachO.link(gpa, io, dir, "demo-stripped", atoms.items, stripped);

    // Symbolize the call in c (its fifth instruction) the way std.debug's
    // stack traces do.
    const path = try std.fs.path.join(arena, &.{ dir_path, "demo" });
    const di_gpa = std.debug.getDebugInfoAllocator();
    var mf = try std.debug.MachOFile.load(di_gpa, io, path, .aarch64);
    defer mf.deinit(di_gpa);
    var c_addr: u64 = 0;
    for (mf.symbols) |s| {
        if (std.mem.eql(u8, std.mem.sliceTo(mf.strings[s.strx..], 0), "c")) c_addr = s.addr;
    }
    const call = c_addr + 6 * 4;
    const dwarf, const vaddr = try mf.getDwarfForAddress(di_gpa, io, call);
    var symbols: std.ArrayList(std.debug.Symbol) = .empty;
    try dwarf.getSymbols(arena, arena, .little, vaddr, false, &symbols);
    const loc = symbols.items[0].source_location.?;
    std.debug.print("std.debug: 0x{x} is {s} at {s}:{d}:{d}\n", .{ call, symbols.items[0].name.?, loc.file_name, loc.line, loc.column });
}
