//! exit: 0
//! stderr: "trap after the assembly: true\nnothing after the assembly: true\n"
//! targets: x86_64-linux aarch64-linux
//! What follows a naked function's assembly, read from the sizes of the
//! program's own symbols: with safety, a trap for the function's end, and
//! without it nothing, so that a routine written in assembly is its
//! instructions and no more (fastmem pins its kernels' sizes).
const std = @import("std");
const builtin = @import("builtin");

export fn naked_checked() callconv(.naked) void {
    asm volatile ("ret");
}

export fn naked_unchecked() callconv(.naked) void {
    @setRuntimeSafety(false);
    asm volatile ("ret");
}

/// The size the program's symbol table gives `name`.
fn symbolSize(elf: []const u8, name: []const u8) ?u64 {
    const int = std.mem.readInt;
    const shoff: usize = @intCast(int(u64, elf[0x28..][0..8], .little));
    const shentsize: usize = int(u16, elf[0x3a..][0..2], .little);
    const shnum: usize = int(u16, elf[0x3c..][0..2], .little);
    for (0..shnum) |i| {
        const sh = elf[shoff + i * shentsize ..][0..0x40];
        if (int(u32, sh[4..8], .little) != std.elf.SHT_SYMTAB) continue;
        const symbols = elf[@intCast(int(u64, sh[0x18..0x20], .little))..][0..@intCast(int(u64, sh[0x20..0x28], .little))];
        const strings_sh = elf[shoff + int(u32, sh[0x28..0x2c], .little) * shentsize ..][0..0x40];
        const strings = elf[@intCast(int(u64, strings_sh[0x18..0x20], .little))..];
        var at: usize = 0;
        while (at + 24 <= symbols.len) : (at += 24) {
            const sym = symbols[at..][0..24];
            if (std.mem.eql(u8, std.mem.sliceTo(strings[int(u32, sym[0..4], .little)..], 0), name)) return int(u64, sym[16..24], .little);
        }
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    // Both functions are in the program.
    std.mem.doNotOptimizeAway(&naked_checked);
    std.mem.doNotOptimizeAway(&naked_unchecked);
    const elf = try std.Io.Dir.cwd().readFileAlloc(init.io, "/proc/self/exe", init.gpa, .unlimited);
    defer init.gpa.free(elf);
    // `ret`, and the trap: `ud2`, or `brk #1`.
    const ret: u64, const trap: u64 = if (builtin.cpu.arch == .x86_64) .{ 1, 2 } else .{ 4, 4 };
    std.debug.print("trap after the assembly: {}\n", .{symbolSize(elf, "naked_checked") == ret + trap});
    std.debug.print("nothing after the assembly: {}\n", .{symbolSize(elf, "naked_unchecked") == ret});
}
