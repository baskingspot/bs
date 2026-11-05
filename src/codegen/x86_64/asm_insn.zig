//! x86_64 inline assembly's general-purpose instructions, taken as
//! upstream's assembler takes them (`airAsm` in upstream's
//! src/codegen/x86_64/CodeGen.zig, with its encodings.zon): an Intel
//! mnemonic, optionally with an AT&T size suffix (b, w, l, q) that sizes
//! every operand, so that a register must have that size, a `%[name]`
//! register takes it, and a memory operand needs it (or the instruction's
//! fixed size); an optional `lock` or `rep` prefix, emitted first; and an
//! encoding only on a CPU with its features. Where several encodings fit
//! (the accumulator forms of `xchg` and of the ALU instructions, `d1` for a
//! shift by 1, `6b` for a small `imul` immediate), it picks upstream's, so
//! the bytes match upstream's. CodeGen's `asmInst` assembles the rest
//! (`mov`, `lea`, `push`, `pop`, branches, `crc32`, SSE).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Encoder = @import("Encoder.zig");
const Reg = Encoder.Reg;
const Size = Encoder.Size;
const Mem = Encoder.Mem;
const Cond = Encoder.Cond;
const Rm = Encoder.Rm;
const Feature = std.Target.x86.Feature;

pub const Operand = union(enum) {
    /// `named` for a `%[name]` operand, which a size suffix resizes.
    reg: struct { reg: Reg, size: Size, named: bool = false },
    /// A memory operand, optionally relative to the fs segment.
    mem: struct { mem: Mem, fs: bool = false },
    imm: i64,
};

pub const Prefix = enum { none, lock, rep, repe, repz, repne, repnz };

/// Why an instruction was not assembled.
pub const Fail = union(enum) {
    /// The mnemonic is not one of this file's.
    unknown,
    /// GNU as's name for an instruction upstream names this way.
    alias: []const u8,
    /// This operand is a memory operand and the mnemonic has no size.
    unknown_size: usize,
    /// This operand is a register of another size than the suffix's.
    register_size: usize,
    /// A size suffix on an instruction of another fixed size.
    invalid_size,
    /// No form of the instruction takes these operands.
    operands,
    /// The prefix cannot prefix this instruction.
    prefix,
    /// The instruction needs this CPU feature (`-mcpu`).
    feature: Feature,
    /// An SSE instruction with a memory operand, which upstream cannot
    /// size (`asm_sse`).
    xmm_memory,
};

const Kind = enum {
    /// No operands: the bytes `ops`.
    zo,
    /// `popf` (word) or `popfq`.
    popf,
    /// A string instruction (`movs`, `cmps`, `stos`, `lods`, `scas`):
    /// opcode `op` for bytes, `op + 1` otherwise; `rep_cmp` for those
    /// that compare (any `rep` prefix), else `rep` only.
    string,
    int,
    /// `inc` ... `idiv`: `op` (`0xfe` or `0xf6`, `+ 1` unless bytes) /`ext`.
    unary,
    imul,
    /// `add` ... `cmp`: ALU operation `ext`.
    alu,
    @"test",
    /// Group 2 shift or rotate `ext`.
    shift,
    /// `shld` (`op` 0xa4) or `shrd` (0xac), `op + 1` by cl.
    shiftd,
    /// `bt` (`ext` 4) ... `btc` (7): 0f ba /ext ib, or 0f `op` /r.
    bt,
    /// `xadd` (0f c0) or `cmpxchg` (0f b0): 0f `op` for bytes, else `op + 1`.
    xadd,
    xchg,
    cmov,
    setcc,
    bswap,
    /// `src, dst` with dst a register: `prefix` 0f `op` /r (bsf, popcnt, ...).
    rm_reg,
    movbe,
    /// `movzx` (0f b6) or `movsx` (0f be), `op + 1` from a word.
    movx,
    movsxd,
    /// One memory operand: `prefix` `ops` /`ext`, of size `fixed` or of
    /// the suffix's byte size when `fixed` is null.
    mem,
    /// `rdrand` (/6) or `rdseed` (/7) of a register.
    rdrand,
    rdpid,
};

const FixedSize = enum(u3) { none, byte, word, dword, qword };

const Insn = struct {
    kind: Kind,
    op: u8 = 0,
    ext: u3 = 0,
    ops: []const u8 = &.{},
    prefix: u8 = 0,
    feature: ?Feature = null,
    fixed: ?FixedSize = null,
    lockable: bool = false,
    rep_cmp: bool = false,
    /// `mem`: REX.W (`fxsave64`).
    w: bool = false,
    cond: Cond = .o,
    /// `string`: the size the name implies (`movsd`).
    size: ?Size = null,
};

const table = std.StaticStringMap(Insn).initComptime(.{
    .{ "mfence", Insn{ .kind = .zo, .ops = &.{ 0x0f, 0xae, 0xf0 } } },
    .{ "lfence", Insn{ .kind = .zo, .ops = &.{ 0x0f, 0xae, 0xe8 } } },
    .{ "sfence", Insn{ .kind = .zo, .ops = &.{ 0x0f, 0xae, 0xf8 } } },
    .{ "rdtsc", Insn{ .kind = .zo, .ops = &.{ 0x0f, 0x31 } } },
    .{ "rdtscp", Insn{ .kind = .zo, .ops = &.{ 0x0f, 0x01, 0xf9 } } },
    .{ "cpuid", Insn{ .kind = .zo, .ops = &.{ 0x0f, 0xa2 } } },
    .{ "xgetbv", Insn{ .kind = .zo, .ops = &.{ 0x0f, 0x01, 0xd0 } } },
    .{ "syscall", Insn{ .kind = .zo, .ops = &.{ 0x0f, 0x05 } } },
    .{ "ud2", Insn{ .kind = .zo, .ops = &.{ 0x0f, 0x0b } } },
    .{ "int3", Insn{ .kind = .zo, .ops = &.{0xcc} } },
    .{ "pause", Insn{ .kind = .zo, .ops = &.{ 0xf3, 0x90 } } },
    .{ "emms", Insn{ .kind = .zo, .ops = &.{ 0x0f, 0x77 } } },
    .{ "nop", Insn{ .kind = .zo, .ops = &.{0x90} } },
    .{ "hlt", Insn{ .kind = .zo, .ops = &.{0xf4} } },
    .{ "ret", Insn{ .kind = .zo, .ops = &.{0xc3} } },
    .{ "leave", Insn{ .kind = .zo, .ops = &.{0xc9} } },
    .{ "cld", Insn{ .kind = .zo, .ops = &.{0xfc} } },
    .{ "std", Insn{ .kind = .zo, .ops = &.{0xfd} } },
    .{ "clc", Insn{ .kind = .zo, .ops = &.{0xf8} } },
    .{ "stc", Insn{ .kind = .zo, .ops = &.{0xf9} } },
    .{ "cmc", Insn{ .kind = .zo, .ops = &.{0xf5} } },
    .{ "cli", Insn{ .kind = .zo, .ops = &.{0xfa} } },
    .{ "sti", Insn{ .kind = .zo, .ops = &.{0xfb} } },
    .{ "lahf", Insn{ .kind = .zo, .ops = &.{0x9f}, .feature = .sahf } },
    .{ "sahf", Insn{ .kind = .zo, .ops = &.{0x9e}, .feature = .sahf } },
    .{ "pushfq", Insn{ .kind = .zo, .ops = &.{0x9c} } },
    .{ "popfq", Insn{ .kind = .zo, .ops = &.{0x9d} } },
    .{ "popf", Insn{ .kind = .popf } },
    .{ "cbw", Insn{ .kind = .zo, .ops = &.{ 0x66, 0x98 } } },
    .{ "cwde", Insn{ .kind = .zo, .ops = &.{0x98} } },
    .{ "cdqe", Insn{ .kind = .zo, .ops = &.{ 0x48, 0x98 } } },
    .{ "cwd", Insn{ .kind = .zo, .ops = &.{ 0x66, 0x99 } } },
    .{ "cdq", Insn{ .kind = .zo, .ops = &.{0x99} } },
    .{ "cqo", Insn{ .kind = .zo, .ops = &.{ 0x48, 0x99 } } },
    .{ "endbr64", Insn{ .kind = .zo, .ops = &.{ 0xf3, 0x0f, 0x1e, 0xfa } } },
    .{ "fninit", Insn{ .kind = .zo, .ops = &.{ 0xdb, 0xe3 } } },
    .{ "fnclex", Insn{ .kind = .zo, .ops = &.{ 0xdb, 0xe2 } } },
    .{ "fwait", Insn{ .kind = .zo, .ops = &.{0x9b} } },
    .{ "wait", Insn{ .kind = .zo, .ops = &.{0x9b} } },
    .{ "movs", Insn{ .kind = .string, .op = 0xa4 } },
    .{ "movsd", Insn{ .kind = .string, .op = 0xa4, .size = .dword } },
    .{ "cmps", Insn{ .kind = .string, .op = 0xa6, .rep_cmp = true } },
    .{ "cmpsd", Insn{ .kind = .string, .op = 0xa6, .rep_cmp = true, .size = .dword } },
    .{ "stos", Insn{ .kind = .string, .op = 0xaa } },
    .{ "lods", Insn{ .kind = .string, .op = 0xac } },
    .{ "scas", Insn{ .kind = .string, .op = 0xae, .rep_cmp = true } },
    .{ "int", Insn{ .kind = .int } },
    .{ "inc", Insn{ .kind = .unary, .op = 0xfe, .ext = 0, .lockable = true } },
    .{ "dec", Insn{ .kind = .unary, .op = 0xfe, .ext = 1, .lockable = true } },
    .{ "not", Insn{ .kind = .unary, .op = 0xf6, .ext = 2, .lockable = true } },
    .{ "neg", Insn{ .kind = .unary, .op = 0xf6, .ext = 3, .lockable = true } },
    .{ "mul", Insn{ .kind = .unary, .op = 0xf6, .ext = 4 } },
    .{ "imul", Insn{ .kind = .imul, .op = 0xf6, .ext = 5 } },
    .{ "div", Insn{ .kind = .unary, .op = 0xf6, .ext = 6 } },
    .{ "idiv", Insn{ .kind = .unary, .op = 0xf6, .ext = 7 } },
    .{ "add", Insn{ .kind = .alu, .ext = 0, .lockable = true } },
    .{ "or", Insn{ .kind = .alu, .ext = 1, .lockable = true } },
    .{ "adc", Insn{ .kind = .alu, .ext = 2, .lockable = true } },
    .{ "sbb", Insn{ .kind = .alu, .ext = 3, .lockable = true } },
    .{ "and", Insn{ .kind = .alu, .ext = 4, .lockable = true } },
    .{ "sub", Insn{ .kind = .alu, .ext = 5, .lockable = true } },
    .{ "xor", Insn{ .kind = .alu, .ext = 6, .lockable = true } },
    .{ "cmp", Insn{ .kind = .alu, .ext = 7 } },
    .{ "test", Insn{ .kind = .@"test" } },
    .{ "rol", Insn{ .kind = .shift, .ext = 0 } },
    .{ "ror", Insn{ .kind = .shift, .ext = 1 } },
    .{ "rcl", Insn{ .kind = .shift, .ext = 2 } },
    .{ "rcr", Insn{ .kind = .shift, .ext = 3 } },
    .{ "shl", Insn{ .kind = .shift, .ext = 4 } },
    .{ "sal", Insn{ .kind = .shift, .ext = 4 } },
    .{ "shr", Insn{ .kind = .shift, .ext = 5 } },
    .{ "sar", Insn{ .kind = .shift, .ext = 7 } },
    .{ "shld", Insn{ .kind = .shiftd, .op = 0xa4 } },
    .{ "shrd", Insn{ .kind = .shiftd, .op = 0xac } },
    .{ "bt", Insn{ .kind = .bt, .op = 0xa3, .ext = 4 } },
    .{ "bts", Insn{ .kind = .bt, .op = 0xab, .ext = 5, .lockable = true } },
    .{ "btr", Insn{ .kind = .bt, .op = 0xb3, .ext = 6, .lockable = true } },
    .{ "btc", Insn{ .kind = .bt, .op = 0xbb, .ext = 7, .lockable = true } },
    .{ "xadd", Insn{ .kind = .xadd, .op = 0xc0, .lockable = true } },
    .{ "cmpxchg", Insn{ .kind = .xadd, .op = 0xb0, .lockable = true } },
    .{ "xchg", Insn{ .kind = .xchg, .lockable = true } },
    .{ "bswap", Insn{ .kind = .bswap } },
    .{ "bsf", Insn{ .kind = .rm_reg, .op = 0xbc } },
    .{ "bsr", Insn{ .kind = .rm_reg, .op = 0xbd } },
    .{ "popcnt", Insn{ .kind = .rm_reg, .op = 0xb8, .prefix = 0xf3, .feature = .popcnt } },
    .{ "lzcnt", Insn{ .kind = .rm_reg, .op = 0xbd, .prefix = 0xf3, .feature = .lzcnt } },
    .{ "tzcnt", Insn{ .kind = .rm_reg, .op = 0xbc, .prefix = 0xf3, .feature = .bmi } },
    .{ "movbe", Insn{ .kind = .movbe, .feature = .movbe } },
    .{ "movzx", Insn{ .kind = .movx, .op = 0xb6 } },
    .{ "movsx", Insn{ .kind = .movx, .op = 0xbe } },
    .{ "movsxd", Insn{ .kind = .movsxd } },
    .{ "clflush", Insn{ .kind = .mem, .ops = &.{ 0x0f, 0xae }, .ext = 7, .fixed = .byte } },
    .{ "clflushopt", Insn{ .kind = .mem, .ops = &.{ 0x0f, 0xae }, .ext = 7, .prefix = 0x66, .feature = .clflushopt } },
    .{ "stmxcsr", Insn{ .kind = .mem, .ops = &.{ 0x0f, 0xae }, .ext = 3, .fixed = .dword } },
    .{ "ldmxcsr", Insn{ .kind = .mem, .ops = &.{ 0x0f, 0xae }, .ext = 2, .fixed = .dword } },
    .{ "fxsave", Insn{ .kind = .mem, .ops = &.{ 0x0f, 0xae }, .ext = 0, .fixed = .none } },
    .{ "fxrstor", Insn{ .kind = .mem, .ops = &.{ 0x0f, 0xae }, .ext = 1, .fixed = .none } },
    .{ "fxsave64", Insn{ .kind = .mem, .ops = &.{ 0x0f, 0xae }, .ext = 0, .fixed = .none, .w = true } },
    .{ "fxrstor64", Insn{ .kind = .mem, .ops = &.{ 0x0f, 0xae }, .ext = 1, .fixed = .none, .w = true } },
    .{ "fnstcw", Insn{ .kind = .mem, .ops = &.{0xd9}, .ext = 7, .fixed = .word } },
    .{ "fldcw", Insn{ .kind = .mem, .ops = &.{0xd9}, .ext = 5, .fixed = .word } },
    .{ "prefetchnta", Insn{ .kind = .mem, .ops = &.{ 0x0f, 0x18 }, .ext = 0 } },
    .{ "prefetcht0", Insn{ .kind = .mem, .ops = &.{ 0x0f, 0x18 }, .ext = 1 } },
    .{ "prefetcht1", Insn{ .kind = .mem, .ops = &.{ 0x0f, 0x18 }, .ext = 2 } },
    .{ "prefetcht2", Insn{ .kind = .mem, .ops = &.{ 0x0f, 0x18 }, .ext = 3 } },
    .{ "prefetchw", Insn{ .kind = .mem, .ops = &.{ 0x0f, 0x0d }, .ext = 1, .feature = .prfchw } },
    .{ "rdrand", Insn{ .kind = .rdrand, .ext = 6, .feature = .rdrnd } },
    .{ "rdseed", Insn{ .kind = .rdrand, .ext = 7, .feature = .rdseed } },
    .{ "rdpid", Insn{ .kind = .rdpid, .feature = .rdpid } },
});

/// GNU as's names that upstream's assembler does not take, and the
/// names it takes for them.
const aliases = std.StaticStringMap([]const u8).initComptime(.{
    .{ "movzbw", "movzx" }, .{ "movzbl", "movzx" }, .{ "movzbq", "movzx" },  .{ "movzwl", "movzx" },
    .{ "movzwq", "movzx" }, .{ "movsbw", "movsx" }, .{ "movsbl", "movsx" },  .{ "movsbq", "movsx" },
    .{ "movswl", "movsx" }, .{ "movswq", "movsx" }, .{ "movslq", "movsxd" }, .{ "cbtw", "cbw" },
    .{ "cwtl", "cwde" },    .{ "cltq", "cdqe" },    .{ "cwtd", "cwd" },      .{ "cltd", "cdq" },
    .{ "cqto", "cqo" },     .{ "pushf", "pushfq" }, .{ "pushfw", "pushfq" },
});

/// The condition named `name`, as `j`, `set` and `cmov` suffixes.
pub fn cond(name: []const u8) ?Cond {
    const conds = std.StaticStringMap(Cond).initComptime(.{
        .{ "o", .o },   .{ "no", .no }, .{ "b", .b },   .{ "c", .b },   .{ "nae", .b }, .{ "ae", .ae },
        .{ "nb", .ae }, .{ "nc", .ae }, .{ "e", .e },   .{ "z", .e },   .{ "ne", .ne }, .{ "nz", .ne },
        .{ "be", .be }, .{ "na", .be }, .{ "a", .a },   .{ "nbe", .a }, .{ "s", .s },   .{ "ns", .ns },
        .{ "p", .p },   .{ "pe", .p },  .{ "np", .np }, .{ "po", .np }, .{ "l", .l },   .{ "nge", .l },
        .{ "ge", .ge }, .{ "nl", .ge }, .{ "le", .le }, .{ "ng", .le }, .{ "g", .g },   .{ "nle", .g },
    });
    return conds.get(name);
}

fn lookup(name: []const u8) ?Insn {
    if (table.get(name)) |i| return i;
    if (std.mem.startsWith(u8, name, "set")) if (cond(name[3..])) |c| return .{ .kind = .setcc, .cond = c };
    if (std.mem.startsWith(u8, name, "cmov")) if (cond(name[4..])) |c| return .{ .kind = .cmov, .cond = c };
    return null;
}

/// The instruction `mnemonic` names and its size suffix's size: as
/// upstream, the name without a last b, w, l or q first, then the whole.
fn resolve(mnemonic: []const u8) ?struct { Insn, ?Size } {
    if (mnemonic.len > 1) {
        const suffix: ?Size = switch (mnemonic[mnemonic.len - 1]) {
            'b' => .byte,
            'w' => .word,
            'l' => .dword,
            'q' => .qword,
            else => null,
        };
        if (suffix) |s| if (lookup(mnemonic[0 .. mnemonic.len - 1])) |i| return .{ i, s };
    }
    return .{ lookup(mnemonic) orelse return null, null };
}

/// Assembles `prefix mnemonic ops` (in AT&T order) into `e` for `cpu`,
/// or returns why not.
pub fn assemble(e: *Encoder, cpu: std.Target.Cpu, prefix: Prefix, mnemonic: []const u8, ops_in: []const Operand) Allocator.Error!?Fail {
    const insn, var suffix = resolve(mnemonic) orelse {
        if (aliases.get(mnemonic)) |name| return .{ .alias = name };
        return .unknown;
    };
    // A fixed size: a suffix must agree, and memory operands have it.
    var mem_sized = suffix != null;
    if (insn.fixed) |f| {
        if (suffix) |s| if (f == .none or @backingInt(f) - 1 != @backingInt(s)) return .invalid_size;
        mem_sized = true;
        suffix = null;
    }
    var buf: [4]Operand = undefined;
    const ops = buf[0..ops_in.len];
    for (ops_in, ops, 0..) |in, *op, i| {
        op.* = in;
        switch (op.*) {
            .reg => |*r| if (suffix) |s| {
                if (r.named) r.size = s else if (r.size != s) return .{ .register_size = i };
            },
            .mem => if (!mem_sized) return .{ .unknown_size = i },
            .imm => {},
        }
    }
    if (insn.feature) |f| if (!cpu.has(.x86, f)) return .{ .feature = f };
    // The operands' size: the suffix's, else the last register's (a
    // shift's count is cl whatever the size).
    var size: ?Size = suffix orelse insn.size;
    if (size == null) for (ops) |op| {
        if (op == .reg) size = op.reg.size;
    };
    const last_mem = ops.len != 0 and ops[ops.len - 1] == .mem;
    switch (prefix) {
        .none => {},
        .lock => if (!insn.lockable or !(last_mem or (insn.kind == .xchg and ops.len == 2 and ops[0] == .mem))) return .prefix,
        .rep => if (insn.kind != .string) return .prefix,
        .repe, .repz, .repne, .repnz => if (!insn.rep_cmp) return .prefix,
    }
    // Check the form first: nothing is emitted for an instruction that fails.
    const start = e.code.items.len;
    errdefer e.code.items.len = start;
    try e.raw(switch (prefix) {
        .none => &.{},
        .lock => &.{0xf0},
        .rep, .repe, .repz => &.{0xf3},
        .repne, .repnz => &.{0xf2},
    });
    for (ops) |op| if (op == .mem and op.mem.fs) {
        try e.raw(&.{0x64});
        break;
    };
    if (try encode(e, insn, size, ops)) |fail| {
        e.code.items.len = start;
        return fail;
    }
    return null;
}

fn rmOf(op: Operand) ?Rm {
    return switch (op) {
        .reg => |r| .{ .reg = r.reg },
        .mem => |m| .{ .mem = m.mem },
        .imm => null,
    };
}

fn regOf(op: Operand) ?Reg {
    return if (op == .reg) op.reg.reg else null;
}

/// Whether `v` fits an immediate of `size` bytes, signed or unsigned
/// (qwords take a sign-extended dword).
fn fitsImm(v: i64, size: Size) bool {
    return switch (size) {
        .byte => v >= -0x80 and v <= 0xff,
        .word => v >= -0x8000 and v <= 0xffff,
        .dword => v >= -0x8000_0000 and v <= 0xffff_ffff,
        .qword => std.math.cast(i32, v) != null,
    };
}

fn encode(e: *Encoder, insn: Insn, size_in: ?Size, ops: []const Operand) Allocator.Error!?Fail {
    const n = ops.len;
    switch (insn.kind) {
        .zo => {
            if (n != 0) return .operands;
            try e.raw(insn.ops);
        },
        .popf => {
            if (n != 0) return .operands;
            try e.raw(if (size_in == .qword) &.{0x9d} else &.{ 0x66, 0x9d });
        },
        .string => {
            const size = size_in orelse return .operands;
            if (n != 0) return .operands;
            switch (size) {
                .byte => try e.raw(&.{insn.op}),
                .word => try e.raw(&.{ 0x66, insn.op + 1 }),
                .dword => try e.raw(&.{insn.op + 1}),
                .qword => try e.raw(&.{ 0x48, insn.op + 1 }),
            }
        },
        .int => {
            if (n != 1 or ops[0] != .imm or ops[0].imm < 0 or ops[0].imm > 0xff) return .operands;
            try e.raw(&.{ 0xcd, @intCast(ops[0].imm) });
        },
        .unary => return unary(e, insn, size_in, ops),
        .imul => {
            if (n == 1) return unary(e, insn, size_in, ops);
            const size = size_in orelse return .operands;
            const dst = regOf(ops[n - 1]) orelse return .operands;
            const src = rmOf(ops[n - 2]) orelse return .operands;
            if (size == .byte) return .operands;
            if (n == 2) {
                try e.asmModRm(size, 0, &.{ 0x0f, 0xaf }, .{ .reg = dst }, src, 0, 0);
            } else if (n == 3 and ops[0] == .imm) {
                const v = ops[0].imm;
                if (std.math.cast(i8, v) != null) {
                    try e.asmModRm(size, 0, &.{0x6b}, .{ .reg = dst }, src, v, 1);
                } else {
                    if (!fitsImm(v, size)) return .operands;
                    try e.asmModRm(size, 0, &.{0x69}, .{ .reg = dst }, src, v, if (size == .word) 2 else 4);
                }
            } else return .operands;
        },
        .alu => {
            if (n != 2) return .operands;
            const size = size_in orelse return .operands;
            const dst = rmOf(ops[1]) orelse return .operands;
            const src: Encoder.Operand = switch (ops[0]) {
                .reg => |r| .{ .reg = r.reg },
                .mem => |m| if (dst == .reg) .{ .mem = m.mem } else return .operands,
                .imm => |v| if (fitsImm(v, size)) .{ .imm = v } else return .operands,
            };
            try e.alu(@fromBackingInt(insn.ext), size, dst, src);
        },
        .@"test" => {
            if (n != 2) return .operands;
            const size = size_in orelse return .operands;
            const dst = rmOf(ops[1]) orelse return .operands;
            const src: Encoder.Operand = switch (ops[0]) {
                .reg => |r| .{ .reg = r.reg },
                .imm => |v| if (fitsImm(v, size)) .{ .imm = v } else return .operands,
                .mem => return .operands,
            };
            try e.@"test"(size, dst, src);
        },
        .shift => {
            if (n != 2) return .operands;
            const size = size_in orelse return .operands;
            const dst = rmOf(ops[1]) orelse return .operands;
            const wide: u8 = @intFromBool(size != .byte);
            switch (ops[0]) {
                .imm => |v| {
                    if (v < 0 or v > 0xff) return .operands;
                    if (v == 1) {
                        try e.asmModRm(size, 0, &.{0xd0 + wide}, .{ .ext = insn.ext }, dst, 0, 0);
                    } else {
                        try e.asmModRm(size, 0, &.{0xc0 + wide}, .{ .ext = insn.ext }, dst, v, 1);
                    }
                },
                .reg => |r| {
                    if (r.reg != .rcx or r.size != .byte) return .operands;
                    try e.asmModRm(size, 0, &.{0xd2 + wide}, .{ .ext = insn.ext }, dst, 0, 0);
                },
                .mem => return .operands,
            }
        },
        .shiftd => {
            if (n != 3) return .operands;
            const dst = rmOf(ops[2]) orelse return .operands;
            const src = ops[1];
            if (src != .reg) return .operands;
            const size = size_in orelse src.reg.size;
            if (size == .byte) return .operands;
            switch (ops[0]) {
                .imm => |v| {
                    if (v < 0 or v > 0xff) return .operands;
                    try e.asmModRm(size, 0, &.{ 0x0f, insn.op }, .{ .reg = src.reg.reg }, dst, v, 1);
                },
                .reg => |r| {
                    if (r.reg != .rcx or r.size != .byte) return .operands;
                    try e.asmModRm(size, 0, &.{ 0x0f, insn.op + 1 }, .{ .reg = src.reg.reg }, dst, 0, 0);
                },
                .mem => return .operands,
            }
        },
        .bt => {
            if (n != 2) return .operands;
            const size = size_in orelse return .operands;
            if (size == .byte) return .operands;
            const dst = rmOf(ops[1]) orelse return .operands;
            switch (ops[0]) {
                .imm => |v| {
                    if (v < 0 or v > 0xff) return .operands;
                    try e.asmModRm(size, 0, &.{ 0x0f, 0xba }, .{ .ext = insn.ext }, dst, v, 1);
                },
                .reg => |r| try e.asmModRm(size, 0, &.{ 0x0f, insn.op }, .{ .reg = r.reg }, dst, 0, 0),
                .mem => return .operands,
            }
        },
        .xadd => {
            if (n != 2) return .operands;
            const size = size_in orelse return .operands;
            const src = regOf(ops[0]) orelse return .operands;
            const dst = rmOf(ops[1]) orelse return .operands;
            try e.asmModRm(size, 0, &.{ 0x0f, if (size == .byte) insn.op else insn.op + 1 }, .{ .reg = src }, dst, 0, 0);
        },
        .xchg => {
            if (n != 2) return .operands;
            const size = size_in orelse return .operands;
            const a = ops[0];
            const b = ops[1];
            if (a == .reg and b == .reg) {
                // The accumulator forms first, as upstream: `xchg rax, r`
                // (b is rax), then `xchg r, rax`.
                if (size != .byte and (b.reg.reg == .rax or a.reg.reg == .rax)) {
                    try e.asmO(size, &.{0x90}, if (b.reg.reg == .rax) a.reg.reg else b.reg.reg);
                    return null;
                }
                try e.asmModRm(size, 0, &.{if (size == .byte) 0x86 else 0x87}, .{ .reg = a.reg.reg }, .{ .reg = b.reg.reg }, 0, 0);
            } else {
                const reg = regOf(a) orelse regOf(b) orelse return .operands;
                const mem = rmOf(if (a == .mem) a else b).?;
                if (mem != .mem) return .operands;
                try e.asmModRm(size, 0, &.{if (size == .byte) 0x86 else 0x87}, .{ .reg = reg }, mem, 0, 0);
            }
        },
        .cmov => {
            if (n != 2) return .operands;
            const size = size_in orelse return .operands;
            if (size == .byte) return .operands;
            const dst = regOf(ops[1]) orelse return .operands;
            const src = rmOf(ops[0]) orelse return .operands;
            try e.asmModRm(size, 0, &.{ 0x0f, 0x40 | @as(u8, @backingInt(insn.cond)) }, .{ .reg = dst }, src, 0, 0);
        },
        .setcc => {
            if (n != 1 or (size_in orelse .byte) != .byte) return .operands;
            const dst = rmOf(ops[0]) orelse return .operands;
            try e.asmModRm(.byte, 0, &.{ 0x0f, 0x90 | @as(u8, @backingInt(insn.cond)) }, .{ .ext = 0 }, dst, 0, 0);
        },
        .bswap => {
            if (n != 1) return .operands;
            const size = size_in orelse return .operands;
            const r = regOf(ops[0]) orelse return .operands;
            if (size != .dword and size != .qword) return .operands;
            try e.asmO(size, &.{ 0x0f, 0xc8 }, r);
        },
        .rm_reg => {
            if (n != 2) return .operands;
            const size = size_in orelse return .operands;
            if (size == .byte) return .operands;
            const dst = regOf(ops[1]) orelse return .operands;
            const src = rmOf(ops[0]) orelse return .operands;
            try e.asmModRm(size, insn.prefix, &.{ 0x0f, insn.op }, .{ .reg = dst }, src, 0, 0);
        },
        .movbe => {
            if (n != 2) return .operands;
            const size = size_in orelse return .operands;
            if (size == .byte) return .operands;
            if (ops[0] == .mem and ops[1] == .reg) {
                try e.asmModRm(size, 0, &.{ 0x0f, 0x38, 0xf0 }, .{ .reg = ops[1].reg.reg }, .{ .mem = ops[0].mem.mem }, 0, 0);
            } else if (ops[0] == .reg and ops[1] == .mem) {
                try e.asmModRm(size, 0, &.{ 0x0f, 0x38, 0xf1 }, .{ .reg = ops[0].reg.reg }, .{ .mem = ops[1].mem.mem }, 0, 0);
            } else return .operands;
        },
        .movx => {
            if (n != 2 or ops[0] != .reg or ops[1] != .reg) return .operands;
            const src = ops[0].reg;
            const dst = ops[1].reg;
            if (@backingInt(src.size) >= @backingInt(dst.size) or src.size == .dword or src.size == .qword) return .operands;
            try e.asmModRm(dst.size, 0, &.{ 0x0f, insn.op + @intFromBool(src.size == .word) }, .{ .reg = dst.reg }, .{ .reg = src.reg }, 0, 0);
        },
        .movsxd => {
            if (n != 2 or ops[0] != .reg or ops[1] != .reg or ops[0].reg.size != .dword or ops[1].reg.size != .qword) return .operands;
            try e.asmModRm(.qword, 0, &.{0x63}, .{ .reg = ops[1].reg.reg }, .{ .reg = ops[0].reg.reg }, 0, 0);
        },
        .mem => {
            if (n != 1 or ops[0] != .mem) return .operands;
            if (insn.fixed == null and size_in != .byte) return .operands;
            try e.asmModRm(if (insn.w) .qword else null, insn.prefix, insn.ops, .{ .ext = insn.ext }, .{ .mem = ops[0].mem.mem }, 0, 0);
        },
        .rdrand => {
            if (n != 1) return .operands;
            const size = size_in orelse return .operands;
            const r = regOf(ops[0]) orelse return .operands;
            if (size == .byte) return .operands;
            try e.asmModRm(size, 0, &.{ 0x0f, 0xc7 }, .{ .ext = insn.ext }, .{ .reg = r }, 0, 0);
        },
        .rdpid => {
            if (n != 1 or ops[0] != .reg or ops[0].reg.size != .qword) return .operands;
            try e.asmModRm(null, 0xf3, &.{ 0x0f, 0xc7 }, .{ .ext = 7 }, .{ .reg = ops[0].reg.reg }, 0, 0);
        },
    }
    return null;
}

fn unary(e: *Encoder, insn: Insn, size_in: ?Size, ops: []const Operand) Allocator.Error!?Fail {
    if (ops.len != 1) return .operands;
    const size = size_in orelse return .operands;
    const dst = rmOf(ops[0]) orelse return .operands;
    try e.asmModRm(size, 0, &.{insn.op + @intFromBool(size != .byte)}, .{ .ext = insn.ext }, dst, 0, 0);
    return null;
}
