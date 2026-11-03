//! x86_64 machine code encoder for the Debug CodeGen. Appends one instruction
//! per call to `code`; references to other symbols become `Atom.Reloc`s and
//! branches to local labels are resolved by `finish`, which shortens the
//! ones whose target is in reach to rel8. Otherwise it picks one encoding
//! per form and does no instruction selection: invalid operand combinations
//! are caller bugs and trip assertions.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Atom = @import("../../link/Atom.zig");
const SymbolKey = Atom.SymbolKey;

const Encoder = @This();

gpa: Allocator,
code: std.ArrayList(u8) = .empty,
/// The atom's `targets` (`refs.targets.keys()`) and `relocs` (`refs.relocs.items`).
refs: Atom.RelocList = .{},
/// The atom's `Debug.lines` (`lines.bytes.items`).
lines: Atom.LineProgram = .{},
/// Offset each label is bound to, or `unbound`.
labels: std.ArrayList(u32) = .empty,
/// With `shorten`: per label, the number of `branches` before it, which
/// are those emitted before it was bound.
label_branches: std.ArrayList(u32) = .empty,
/// rel32 fields that branch to a label not yet bound when they were emitted.
fixups: std.ArrayList(struct { at: u32, label: Label }) = .empty,
/// Whether `finishShortened` may shorten branches: set before emitting.
/// Code that computes its own offsets, such as inline assembly, must not.
shorten: bool = false,
/// With `shorten`: `jmp` and `jcc` instructions to labels, by offset,
/// candidates for the short form.
branches: std.ArrayList(struct { at: u32, label: Label }) = .empty,
/// After `finish` shortened branches: per branch, the bytes saved by the
/// branches before it (one more entry for the total), for `mapOffset`.
saved: std.ArrayList(u32) = .empty,
/// With `shorten`: line rows and file switches until `finishShortened`,
/// which writes them to `lines` at their final offsets; afterwards they go
/// there directly.
line_events: std.ArrayList(LineEvent) = .empty,
finished: bool = false,

const LineEvent = struct { offset: u32, kind: enum { row, switch_to }, a: u32, b: u32 };

const unbound = std.math.maxInt(u32);

pub const Reg = enum(u4) {
    rax,
    rcx,
    rdx,
    rbx,
    rsp,
    rbp,
    rsi,
    rdi,
    r8,
    r9,
    r10,
    r11,
    r12,
    r13,
    r14,
    r15,

    fn low(r: Reg) u3 {
        return @truncate(@backingInt(r));
    }
    /// spl, bpl, sil, and dil need a REX prefix to be addressed as bytes.
    fn needsRexAsByte(r: Reg) bool {
        return @backingInt(r) >= 4 and @backingInt(r) < 8;
    }
};

pub const Xmm = enum(u4) {
    xmm0,
    xmm1,
    xmm2,
    xmm3,
    xmm4,
    xmm5,
    xmm6,
    xmm7,
    xmm8,
    xmm9,
    xmm10,
    xmm11,
    xmm12,
    xmm13,
    xmm14,
    xmm15,
};

/// Operand size of a GPR instruction.
pub const Size = enum(u2) {
    byte,
    word,
    dword,
    qword,

    pub fn bytes(s: Size) u8 {
        return @as(u8, 1) << @backingInt(s);
    }
};

pub const Float = enum { f32, f64 };

/// Condition codes, numbered as in the opcode.
pub const Cond = enum(u4) {
    o,
    no,
    b,
    ae,
    e,
    ne,
    be,
    a,
    s,
    ns,
    p,
    np,
    l,
    ge,
    le,
    g,

    pub fn negate(c: Cond) Cond {
        return @fromBackingInt(@intCast(@backingInt(c) ^ 1));
    }
};

pub const Mem = struct {
    base: Base = .none,
    index: ?Index = null,
    disp: i32 = 0,

    pub const Base = union(enum) {
        /// Absolute `[index*scale + disp]`.
        none,
        reg: Reg,
        /// RIP-relative `[rip + sym + disp]`; becomes a PC32 relocation.
        /// Cannot have an index.
        sym: SymbolKey,
        /// `[rip + disp]`, relative to the end of the instruction.
        /// Cannot have an index.
        rip,
    };
    pub const Index = struct { reg: Reg, scale: Scale = .@"1" };
    pub const Scale = enum(u2) { @"1", @"2", @"4", @"8" };

    /// `[base + disp]`
    pub fn at(base: Reg, disp: i32) Mem {
        return .{ .base = .{ .reg = base }, .disp = disp };
    }
    /// `[rip + sym + disp]`
    pub fn sym(key: SymbolKey, disp: i32) Mem {
        return .{ .base = .{ .sym = key }, .disp = disp };
    }
};

/// A GPR or memory operand.
pub const Rm = union(enum) { reg: Reg, mem: Mem };
/// An XMM or memory operand.
pub const XmmRm = union(enum) { reg: Xmm, mem: Mem };
/// Source operand of `mov`, ALU instructions, and `test`.
pub const Operand = union(enum) { reg: Reg, mem: Mem, imm: i64 };

pub const Label = enum(u32) { _ };
pub const Target = union(enum) { label: Label, sym: SymbolKey };

pub fn init(gpa: Allocator) Encoder {
    return .{ .gpa = gpa };
}

pub fn deinit(e: *Encoder) void {
    e.code.deinit(e.gpa);
    e.refs.deinit(e.gpa);
    e.lines.deinit(e.gpa);
    e.labels.deinit(e.gpa);
    e.label_branches.deinit(e.gpa);
    e.fixups.deinit(e.gpa);
    e.branches.deinit(e.gpa);
    e.saved.deinit(e.gpa);
    e.line_events.deinit(e.gpa);
}

/// Patches branches to labels. Every label must be bound.
pub fn finish(e: *Encoder) void {
    for (e.fixups.items) |f| e.patchRel32(f.at, e.labels.items[@backingInt(f.label)]);
    e.fixups.clearRetainingCapacity();
}

/// `finish`, and with `shorten`, a `jmp` or `jcc` whose target is within
/// rel8 reach takes the short form. Shortening only ever lengthens a
/// branch back, so it ends after a few rounds. Relocations, labels, and
/// line rows move with the code; `mapOffset` moves other offsets taken
/// before.
pub fn finishShortened(e: *Encoder) Allocator.Error!void {
    e.finish();
    if (e.branches.items.len != 0) try e.shortenBranches();
    e.finished = true;
    var cursor: usize = 0;
    for (e.line_events.items) |ev| switch (ev.kind) {
        .row => try e.lines.addRow(e.gpa, e.mapAscending(&cursor, ev.offset), ev.a, ev.b),
        .switch_to => try e.lines.switchTo(e.gpa, ev.a, ev.b),
    };
}

/// `mapOffset` for offsets that only grow from one call to the next,
/// with `cursor` (starting at 0) kept between them.
fn mapAscending(e: *const Encoder, cursor: *usize, off: u32) u32 {
    if (e.saved.items.len == 0) return off;
    const br = e.branches.items;
    while (cursor.* < br.len and br[cursor.*].at < off) cursor.* += 1;
    return off - e.saved.items[cursor.*];
}

/// Where code at offset `off` before `finish` is after it.
pub fn mapOffset(e: *const Encoder, off: u32) u32 {
    if (e.saved.items.len == 0) return off;
    // The branches that start before `off`.
    var lo: usize = 0;
    var hi: usize = e.branches.items.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (e.branches.items[mid].at < off) lo = mid + 1 else hi = mid;
    }
    return off - e.saved.items[lo];
}

fn shortenBranches(e: *Encoder) Allocator.Error!void {
    const gpa = e.gpa;
    const br = e.branches.items;
    const code = e.code.items;
    const short = try gpa.alloc(bool, br.len);
    defer gpa.free(short);
    @memset(short, true);
    try e.saved.resize(gpa, br.len + 1);
    const saved = e.saved.items;
    const before = e.label_branches.items;
    // The long forms are `e9 rel32` (5 bytes) and `0f 8x rel32` (6); the
    // short ones 2 bytes.
    while (true) {
        var total: u32 = 0;
        for (br, short, 0..) |b, s, i| {
            saved[i] = total;
            if (s) total += if (code[b.at] == 0xe9) 3 else 4;
        }
        saved[br.len] = total;
        var changed = false;
        for (br, short, 0..) |b, *s, i| {
            if (!s.*) continue;
            const from: i64 = b.at - saved[i] + 2;
            const l = @backingInt(b.label);
            const to: i64 = e.labels.items[l] - saved[before[l]];
            if (std.math.cast(i8, to - from) == null) {
                s.* = false;
                changed = true;
            }
        }
        if (!changed) break;
    }
    if (saved[br.len] == 0) {
        e.saved.clearRetainingCapacity();
        return;
    }
    var out: std.ArrayList(u8) = try .initCapacity(gpa, code.len - saved[br.len]);
    errdefer out.deinit(gpa);
    var prev: u32 = 0;
    for (br, short) |b, s| {
        out.appendSliceAssumeCapacity(code[prev..b.at]);
        const is_jmp = code[b.at] == 0xe9;
        const l = @backingInt(b.label);
        const to: i64 = e.labels.items[l] - saved[before[l]];
        const at: i64 = @intCast(out.items.len);
        if (s) {
            out.appendAssumeCapacity(if (is_jmp) 0xeb else 0x70 | (code[b.at + 1] & 0xf));
            out.appendAssumeCapacity(@bitCast(@as(i8, @intCast(to - (at + 2)))));
        } else {
            const len: u32 = if (is_jmp) 5 else 6;
            out.appendSliceAssumeCapacity(code[b.at..][0 .. len - 4]);
            var rel: [4]u8 = undefined;
            std.mem.writeInt(i32, &rel, @intCast(to - (at + len)), .little);
            out.appendSliceAssumeCapacity(&rel);
        }
        prev = b.at + if (is_jmp) @as(u32, 5) else 6;
    }
    out.appendSliceAssumeCapacity(code[prev..]);
    e.code.deinit(gpa);
    e.code = out;
    var cursor: usize = 0;
    for (e.refs.relocs.items) |*r| r.offset = e.mapAscending(&cursor, r.offset);
    for (e.labels.items, before) |*l, n| l.* -= saved[n];
}

pub fn newLabel(e: *Encoder) Allocator.Error!Label {
    try e.labels.append(e.gpa, unbound);
    if (e.shorten) try e.label_branches.append(e.gpa, 0);
    return @fromBackingInt(@intCast(e.labels.items.len - 1));
}

/// Binds `label` to the current offset.
pub fn bind(e: *Encoder, label: Label) void {
    assert(e.labels.items[@backingInt(label)] == unbound);
    e.labels.items[@backingInt(label)] = @intCast(e.code.items.len);
    if (e.shorten) e.label_branches.items[@backingInt(label)] = @intCast(e.branches.items.len);
}

// ---------------------------------------------------------------- data movement

pub fn mov(e: *Encoder, size: Size, dst: Rm, src: Operand) !void {
    try e.reserve();
    switch (src) {
        .reg => |s| try e.gprRm(size, 0x88, 0x89, .{ .reg = s }, dst, 0),
        .mem => |s| try e.gprRm(size, 0x8a, 0x8b, .{ .reg = dst.reg }, .{ .mem = s }, 0),
        .imm => |imm| switch (dst) {
            .reg => |d| if (size == .qword and imm < 0 and imm >= std.math.minInt(i32)) {
                // Sign-extended imm32; shorter than movabs.
                try e.gprRm(.qword, 0xc6, 0xc7, .{ .ext = 0 }, dst, 4);
                e.immediate(.dword, imm);
            } else if (size == .qword and imm >= 0 and imm <= std.math.maxInt(u32)) {
                // `mov r32, imm32` zero-extends.
                e.prefixes(.{ .b = ext(@backingInt(d)) }, .{});
                e.byte(0xb8 | @as(u8, d.low()));
                e.immediate(.dword, imm);
            } else {
                e.prefixes(.{ .w = size == .qword, .b = ext(@backingInt(d)) }, .{
                    .op16 = size == .word,
                    .force_rex = size == .byte and d.needsRexAsByte(),
                });
                e.byte((if (size == .byte) @as(u8, 0xb0) else 0xb8) | @as(u8, d.low()));
                if (size == .qword) e.int(i64, imm) else e.immediate(size, imm);
            },
            .mem => {
                try e.gprRm(size, 0xc6, 0xc7, .{ .ext = 0 }, dst, immLen(size));
                e.immediate(size, imm);
            },
        },
    }
}

/// `movabs dst, sym + addend`: loads a symbol's absolute address.
pub fn movAbsSym(e: *Encoder, dst: Reg, sym: SymbolKey, addend: i64) !void {
    try e.reserve();
    e.prefixes(.{ .w = true, .b = ext(@backingInt(dst)) }, .{});
    e.byte(0xb8 | @as(u8, dst.low()));
    try e.reloc(.x86_64_abs64, sym, addend);
    e.int(u64, 0);
}

/// Records that the code from here on comes from zero-based `line_`,
/// relative to the declaration, and zero-based `column`.
pub fn line(e: *Encoder, line_: u32, column: u32) !void {
    if (!e.shorten or e.finished) return e.lines.addRow(e.gpa, @intCast(e.code.items.len), line_, column);
    try e.line_events.append(e.gpa, .{ .offset = @intCast(e.code.items.len), .kind = .row, .a = line_, .b = column });
}

/// `Atom.LineProgram.switchTo` at the current offset.
pub fn switchLines(e: *Encoder, file: u32, base: u32) !void {
    if (!e.shorten or e.finished) return e.lines.switchTo(e.gpa, file, base);
    try e.line_events.append(e.gpa, .{ .offset = @intCast(e.code.items.len), .kind = .switch_to, .a = file, .b = base });
}

/// `mov r32, imm32` with the immediate set at link time to the 32-bit
/// value of `key` (a `.value32` relocation), zero-extended into `dst`.
pub fn movImmValue(e: *Encoder, dst: Reg, key: SymbolKey) !void {
    try e.reserve();
    e.prefixes(.{ .b = ext(@backingInt(dst)) }, .{});
    e.byte(0xb8 | @as(u8, dst.low()));
    try e.reloc(.value32, key, 0);
    e.int(u32, 0);
}

/// Loads the address of the thread-local `sym` (in `.tdata` or `.tbss`),
/// local-exec model, as upstream emits it: `mov dst, qword ptr fs:[0]`
/// (the thread pointer, which points to itself on x86_64), then
/// `lea dst, [dst + sym@tpoff]` with a 32-bit displacement that an
/// `x86_64_tpoff32` relocation fills.
pub fn leaThreadLocal(e: *Encoder, dst: Reg, sym: SymbolKey) !void {
    try e.reserve();
    e.byte(0x64);
    e.prefixes(.{ .w = true, .r = ext(@backingInt(dst)) }, .{});
    e.byte(0x8b);
    e.byte(modrmByte(0b00, dst.low(), 0b100));
    e.byte(sibByte(0, 0b100, 0b101)); // no base, no index: [disp32]
    e.int(u32, 0);
    try e.reserve();
    e.prefixes(.{ .w = true, .r = ext(@backingInt(dst)), .b = ext(@backingInt(dst)) }, .{});
    e.byte(0x8d);
    e.byte(modrmByte(0b10, dst.low(), if (dst.low() == 0b100) 0b100 else dst.low()));
    if (dst.low() == 0b100) e.byte(sibByte(0, 0b100, 0b100));
    try e.reloc(.x86_64_tpoff32, sym, 0);
    e.int(u32, 0);
}

/// `dst` = the address of thread-local `sym` in position-independent
/// code, local-dynamic model, in the form linkers relax to local-exec:
/// `lea rdi, [rip + sym@tlsld]; call get_addr` (`__tls_get_addr`, which
/// returns the module's TLS block in rax), then `lea dst, [rax +
/// sym@dtpoff]`. A call: it clobbers the caller-saved registers.
pub fn leaThreadLocalDynamic(e: *Encoder, dst: Reg, sym: SymbolKey, get_addr: SymbolKey) !void {
    try e.reserve();
    e.bytes(&.{ 0x48, 0x8d, 0x3d }); // lea rdi, [rip + disp32]
    try e.reloc(.x86_64_tlsld, sym, -4);
    e.int(u32, 0);
    try e.call(.{ .sym = get_addr });
    try e.reserve();
    e.prefixes(.{ .w = true, .r = ext(@backingInt(dst)) }, .{});
    e.byte(0x8d);
    e.byte(modrmByte(0b10, dst.low(), 0b000)); // [rax + disp32]
    try e.reloc(.x86_64_dtpoff32, sym, 0);
    e.int(u32, 0);
}

/// `dst` = the address of thread-local `sym`, which another module may
/// define, in position-independent code that ends up in an executable,
/// initial-exec model: `mov dst, fs:0; add dst, [rip + sym@gottpoff]`,
/// the form linkers relax to local-exec when the executable defines it.
pub fn leaThreadLocalInitial(e: *Encoder, dst: Reg, sym: SymbolKey) !void {
    try e.reserve();
    e.byte(0x64);
    e.prefixes(.{ .w = true, .r = ext(@backingInt(dst)) }, .{});
    e.byte(0x8b);
    e.byte(modrmByte(0b00, dst.low(), 0b100));
    e.byte(sibByte(0, 0b100, 0b101)); // no base, no index: [disp32]
    e.int(u32, 0);
    try e.reserve();
    e.prefixes(.{ .w = true, .r = ext(@backingInt(dst)) }, .{});
    e.byte(0x03);
    e.byte(modrmByte(0b00, dst.low(), 0b101)); // [rip + disp32]
    try e.reloc(.x86_64_gottpoff, sym, -4);
    e.int(u32, 0);
}

/// rax = the address of thread-local `sym`, which another module may
/// define, in position-independent code, general-dynamic model:
/// `data16 lea rdi, [rip + sym@tlsgd]; data16 data16 rex.W call
/// get_addr` (`__tls_get_addr`), padded to the 16 bytes linkers relax to
/// initial-exec or local-exec. A call: it clobbers the caller-saved
/// registers.
pub fn leaThreadLocalGeneral(e: *Encoder, sym: SymbolKey, get_addr: SymbolKey) !void {
    try e.reserve();
    e.bytes(&.{ 0x66, 0x48, 0x8d, 0x3d }); // data16 lea rdi, [rip + disp32]
    try e.reloc(.x86_64_tlsgd, sym, -4);
    e.int(u32, 0);
    try e.reserve();
    e.bytes(&.{ 0x66, 0x66, 0x48, 0xe8 }); // data16 data16 rex.W call rel32
    try e.reloc(.x86_64_pc32, get_addr, -4);
    e.int(u32, 0);
}

pub fn lea(e: *Encoder, size: Size, dst: Reg, src: Mem) !void {
    assert(size != .byte);
    try e.reserve();
    try e.gprRm(size, undefined, 0x8d, .{ .reg = dst }, .{ .mem = src }, 0);
}

/// Zero-extends `src` into `dst`. A dword source becomes `mov r32, r/m32`.
pub fn movzx(e: *Encoder, dst_size: Size, dst: Reg, src_size: Size, src: Rm) !void {
    try e.extend(dst_size, dst, src_size, src, 0xb6);
}

/// Sign-extends `src` into `dst`. A dword source becomes `movsxd`.
pub fn movsx(e: *Encoder, dst_size: Size, dst: Reg, src_size: Size, src: Rm) !void {
    try e.extend(dst_size, dst, src_size, src, 0xbe);
}

fn extend(e: *Encoder, dst_size: Size, dst: Reg, src_size: Size, src: Rm, op: u8) !void {
    assert(@backingInt(src_size) < @backingInt(dst_size));
    try e.reserve();
    switch (src_size) {
        .byte, .word => try e.modRm(.{
            .w = dst_size == .qword,
            .op16 = dst_size == .word,
            .force_rex = src_size == .byte and src == .reg and src.reg.needsRexAsByte(),
        }, &.{ 0x0f, op | @backingInt(src_size) }, @backingInt(dst), rmGpr(src), 0),
        .dword => if (op == 0xb6)
            try e.gprRm(.dword, undefined, 0x8b, .{ .reg = dst }, src, 0)
        else
            try e.gprRm(.qword, undefined, 0x63, .{ .reg = dst }, src, 0),
        .qword => unreachable,
    }
}

pub fn push(e: *Encoder, r: Reg) !void {
    try e.reserve();
    e.prefixes(.{ .b = ext(@backingInt(r)) }, .{});
    e.byte(0x50 | @as(u8, r.low()));
}

pub fn pop(e: *Encoder, r: Reg) !void {
    try e.reserve();
    e.prefixes(.{ .b = ext(@backingInt(r)) }, .{});
    e.byte(0x58 | @as(u8, r.low()));
}

pub fn cmov(e: *Encoder, cond: Cond, size: Size, dst: Reg, src: Rm) !void {
    assert(size != .byte);
    try e.reserve();
    try e.modRm(.{ .w = size == .qword, .op16 = size == .word }, &.{ 0x0f, 0x40 | @as(u8, @backingInt(cond)) }, @backingInt(dst), rmGpr(src), 0);
}

/// Sets the byte `dst` to 1 if `cond` holds, else 0.
pub fn setcc(e: *Encoder, cond: Cond, dst: Rm) !void {
    try e.reserve();
    try e.modRm(.{ .force_rex = dst == .reg and dst.reg.needsRexAsByte() }, &.{ 0x0f, 0x90 | @as(u8, @backingInt(cond)) }, 0, rmGpr(dst), 0);
}

// ---------------------------------------------------------------- arithmetic

pub const AluOp = enum(u3) { add, @"or", adc, sbb, @"and", sub, xor, cmp };

/// `op dst, src` for add, or, adc, sbb, and, sub, xor, cmp. A qword
/// immediate must fit in i32.
pub fn alu(e: *Encoder, op: AluOp, size: Size, dst: Rm, src: Operand) !void {
    try e.reserve();
    const base = @as(u8, @backingInt(op)) << 3;
    switch (src) {
        .reg => |s| try e.gprRm(size, base, base | 1, .{ .reg = s }, dst, 0),
        .mem => |s| try e.gprRm(size, base | 2, base | 3, .{ .reg = dst.reg }, .{ .mem = s }, 0),
        .imm => |imm| if (size != .byte and std.math.cast(i8, imm) != null) {
            try e.gprRm(size, undefined, 0x83, .{ .ext = @backingInt(op) }, dst, 1);
            e.immediate(.byte, imm);
        } else if (dst == .reg and dst.reg == .rax) {
            // Accumulator short form, as assemblers emit it.
            e.prefixes(.{ .w = size == .qword }, .{ .op16 = size == .word });
            e.byte(if (size == .byte) base | 4 else base | 5);
            e.immediate(size, imm);
        } else {
            try e.gprRm(size, 0x80, 0x81, .{ .ext = @backingInt(op) }, dst, immLen(size));
            e.immediate(size, imm);
        },
    }
}

/// `test dst, src`. A qword immediate must fit in i32.
pub fn @"test"(e: *Encoder, size: Size, dst: Rm, src: Operand) !void {
    try e.reserve();
    switch (src) {
        .reg => |s| try e.gprRm(size, 0x84, 0x85, .{ .reg = s }, dst, 0),
        // `test` is symmetric; only the r/m, reg form exists.
        .mem => |s| try e.gprRm(size, 0x84, 0x85, .{ .reg = dst.reg }, .{ .mem = s }, 0),
        .imm => |imm| {
            if (dst == .reg and dst.reg == .rax) {
                e.prefixes(.{ .w = size == .qword }, .{ .op16 = size == .word });
                e.byte(if (size == .byte) 0xa8 else 0xa9);
            } else {
                try e.gprRm(size, 0xf6, 0xf7, .{ .ext = 0 }, dst, immLen(size));
            }
            e.immediate(size, imm);
        },
    }
}

/// One-operand group 3 instructions. `mul`, `imul`, `div`, and `idiv`
/// operate on rdx:rax (ax for bytes) as usual.
pub const UnaryOp = enum(u3) { not = 2, neg = 3, mul = 4, imul = 5, div = 6, idiv = 7 };

pub fn unary(e: *Encoder, op: UnaryOp, size: Size, dst: Rm) !void {
    try e.reserve();
    try e.gprRm(size, 0xf6, 0xf7, .{ .ext = @backingInt(op) }, dst, 0);
}

/// `imul dst, src` or, with `imm`, `imul dst, src, imm`.
pub fn imul(e: *Encoder, size: Size, dst: Reg, src: Rm, imm: ?i32) !void {
    assert(size != .byte);
    try e.reserve();
    const i = imm orelse return e.modRm(.{ .w = size == .qword, .op16 = size == .word }, &.{ 0x0f, 0xaf }, @backingInt(dst), rmGpr(src), 0);
    if (std.math.cast(i8, i) != null) {
        try e.gprRm(size, undefined, 0x6b, .{ .reg = dst }, src, 1);
        e.immediate(.byte, i);
    } else {
        try e.gprRm(size, undefined, 0x69, .{ .reg = dst }, src, immLen(size));
        e.immediate(size, i);
    }
}

/// Sign-extends the accumulator into the high half of the dividend before
/// `idiv`: cbw (al into ah), cwd, cdq, cqo.
pub fn cqo(e: *Encoder, size: Size) !void {
    try e.reserve();
    switch (size) {
        .byte => e.bytes(&.{ 0x66, 0x98 }),
        .word => e.bytes(&.{ 0x66, 0x99 }),
        .dword => e.byte(0x99),
        .qword => e.bytes(&.{ 0x48, 0x99 }),
    }
}

pub const ShiftOp = enum(u3) { rol = 0, ror = 1, shl = 4, shr = 5, sar = 7 };

/// Shifts `dst` by `count`, or by cl when `count` is null.
pub fn shift(e: *Encoder, op: ShiftOp, size: Size, dst: Rm, count: ?u8) !void {
    try e.reserve();
    if (count) |c| {
        if (c == 1) return e.gprRm(size, 0xd0, 0xd1, .{ .ext = @backingInt(op) }, dst, 0);
        try e.gprRm(size, 0xc0, 0xc1, .{ .ext = @backingInt(op) }, dst, 1);
        e.byte(c);
    } else {
        try e.gprRm(size, 0xd2, 0xd3, .{ .ext = @backingInt(op) }, dst, 0);
    }
}

/// `shld dst, src, cl` (`left`) or `shrd dst, src, cl` on qwords: shifts
/// `dst` by cl, filling with bits of `src`.
pub fn shiftDouble(e: *Encoder, left: bool, dst: Rm, src: Reg) !void {
    try e.reserve();
    try e.modRm(.{ .w = true }, &.{ 0x0f, if (left) 0xa5 else 0xad }, @backingInt(src), rmGpr(dst), 0);
}

/// `bsf dst, src` (forward) or `bsr dst, src` (reverse): index of the lowest
/// or highest set bit. Sets ZF and leaves `dst` undefined when `src` is 0.
pub fn bitScan(e: *Encoder, reverse: bool, size: Size, dst: Reg, src: Rm) !void {
    assert(size != .byte);
    try e.reserve();
    try e.modRm(.{ .w = size == .qword, .op16 = size == .word }, &.{ 0x0f, if (reverse) 0xbd else 0xbc }, @backingInt(dst), rmGpr(src), 0);
}

/// Reverses the bytes of a dword or qword register.
pub fn bswap(e: *Encoder, size: Size, r: Reg) !void {
    assert(size == .dword or size == .qword);
    try e.reserve();
    e.prefixes(.{ .w = size == .qword, .b = ext(@backingInt(r)) }, .{});
    e.bytes(&.{ 0x0f, 0xc8 | @as(u8, r.low()) });
}

/// Exchanges `a` with register `b`.
pub fn xchg(e: *Encoder, size: Size, a: Rm, b: Reg) !void {
    try e.reserve();
    try e.gprRm(size, 0x86, 0x87, .{ .reg = b }, a, 0);
}

/// `lock cmpxchg [dst], src`: if [dst] equals al/ax/eax/rax, stores `src`
/// there (ZF set); else loads [dst] into it (ZF clear).
pub fn lockCmpxchg(e: *Encoder, size: Size, dst: Mem, src: Reg) !void {
    try e.lock0f(size, 0xb0, 0xb1, dst, src);
}

/// `lock xadd [dst], src`: adds `src` to [dst] and leaves the old value
/// in `src`.
pub fn lockXadd(e: *Encoder, size: Size, dst: Mem, src: Reg) !void {
    try e.lock0f(size, 0xc0, 0xc1, dst, src);
}

fn lock0f(e: *Encoder, size: Size, op8: u8, op: u8, dst: Mem, src: Reg) !void {
    try e.reserve();
    e.byte(0xf0);
    try e.modRm(.{
        .op16 = size == .word,
        .w = size == .qword,
        .force_rex = size == .byte and src.needsRexAsByte(),
    }, &.{ 0x0f, if (size == .byte) op8 else op }, @backingInt(src), rmGpr(.{ .mem = dst }), 0);
}

// ---------------------------------------------------------------- strings

/// `rep movsb`: copies rcx bytes from [rsi] to [rdi], backwards if DF is set.
pub fn repMovsb(e: *Encoder) !void {
    try e.code.appendSlice(e.gpa, &.{ 0xf3, 0xa4 });
}

/// `rep stosb`: stores al to rcx bytes at [rdi].
pub fn repStosb(e: *Encoder) !void {
    try e.code.appendSlice(e.gpa, &.{ 0xf3, 0xaa });
}

/// `std` (true) or `cld` (false): sets or clears the direction flag.
pub fn setDirection(e: *Encoder, backward: bool) !void {
    try e.code.append(e.gpa, if (backward) 0xfd else 0xfc);
}

// ---------------------------------------------------------------- control flow

pub fn jmp(e: *Encoder, target: Target) !void {
    try e.reserve();
    if (e.shorten and target == .label) try e.branches.append(e.gpa, .{ .at = @intCast(e.code.items.len), .label = target.label });
    e.byte(0xe9);
    try e.rel32(target);
}

pub fn jcc(e: *Encoder, cond: Cond, target: Target) !void {
    try e.reserve();
    if (e.shorten and target == .label) try e.branches.append(e.gpa, .{ .at = @intCast(e.code.items.len), .label = target.label });
    e.bytes(&.{ 0x0f, 0x80 | @as(u8, @backingInt(cond)) });
    try e.rel32(target);
}

pub fn call(e: *Encoder, target: Target) !void {
    try e.reserve();
    e.byte(0xe8);
    try e.rel32(target);
}

/// `jmp r/m64`
pub fn jmpIndirect(e: *Encoder, target: Rm) !void {
    try e.reserve();
    try e.modRm(.{}, &.{0xff}, 4, rmGpr(target), 0);
}

/// `call r/m64`
pub fn callIndirect(e: *Encoder, target: Rm) !void {
    try e.reserve();
    try e.modRm(.{}, &.{0xff}, 2, rmGpr(target), 0);
}

pub fn ret(e: *Encoder) !void {
    try e.code.append(e.gpa, 0xc3);
}

pub fn syscall(e: *Encoder) !void {
    try e.code.appendSlice(e.gpa, &.{ 0x0f, 0x05 });
}

pub fn ud2(e: *Encoder) !void {
    try e.code.appendSlice(e.gpa, &.{ 0x0f, 0x0b });
}

pub fn int3(e: *Encoder) !void {
    try e.code.append(e.gpa, 0xcc);
}

// ---------------------------------------------------------------- scalar SSE

/// movss/movsd: register to register, load, or store.
pub fn movs(e: *Encoder, ty: Float, dst: XmmRm, src: XmmRm) !void {
    try e.reserve();
    const p = scalarPrefix(ty);
    switch (dst) {
        .reg => |d| try e.modRm(.{ .prefix = p }, &.{ 0x0f, 0x10 }, @backingInt(d), rmXmm(src), 0),
        .mem => try e.modRm(.{ .prefix = p }, &.{ 0x0f, 0x11 }, @backingInt(src.reg), rmXmm(dst), 0),
    }
}

pub const SseOp = enum(u8) { sqrt = 0x51, add = 0x58, mul = 0x59, sub = 0x5c, min = 0x5d, div = 0x5e, max = 0x5f };

/// addss/addsd and friends: `dst = dst op src` (sqrt: `dst = sqrt(src)`).
pub fn sse(e: *Encoder, op: SseOp, ty: Float, dst: Xmm, src: XmmRm) !void {
    try e.reserve();
    try e.modRm(.{ .prefix = scalarPrefix(ty) }, &.{ 0x0f, @backingInt(op) }, @backingInt(dst), rmXmm(src), 0);
}

pub const SseLogicOp = enum(u8) { @"and" = 0x54, andn = 0x55, @"or" = 0x56, xor = 0x57 };

/// andps/andpd, andnps/andnpd, orps/orpd, xorps/xorpd, for sign manipulation
/// and zeroing. Memory operands must be 16-byte aligned.
pub fn sseLogic(e: *Encoder, op: SseLogicOp, ty: Float, dst: Xmm, src: XmmRm) !void {
    try e.reserve();
    try e.modRm(.{ .op16 = ty == .f64 }, &.{ 0x0f, @backingInt(op) }, @backingInt(dst), rmXmm(src), 0);
}

/// ucomiss/ucomisd: compares and sets ZF, PF, CF (unordered sets all three).
pub fn ucomis(e: *Encoder, ty: Float, a: Xmm, b: XmmRm) !void {
    try e.reserve();
    try e.modRm(.{ .op16 = ty == .f64 }, &.{ 0x0f, 0x2e }, @backingInt(a), rmXmm(b), 0);
}

/// cvtsi2ss/cvtsi2sd from a dword or qword integer.
pub fn cvtsi2s(e: *Encoder, ty: Float, dst: Xmm, src_size: Size, src: Rm) !void {
    assert(src_size == .dword or src_size == .qword);
    try e.reserve();
    try e.modRm(.{ .prefix = scalarPrefix(ty), .w = src_size == .qword }, &.{ 0x0f, 0x2a }, @backingInt(dst), rmGpr(src), 0);
}

/// cvttss2si/cvttsd2si (truncating) to a dword or qword integer.
pub fn cvtts2si(e: *Encoder, ty: Float, dst_size: Size, dst: Reg, src: XmmRm) !void {
    assert(dst_size == .dword or dst_size == .qword);
    try e.reserve();
    try e.modRm(.{ .prefix = scalarPrefix(ty), .w = dst_size == .qword }, &.{ 0x0f, 0x2c }, @backingInt(dst), rmXmm(src), 0);
}

/// cvtss2sd (to f64) or cvtsd2ss (to f32).
pub fn cvts2s(e: *Encoder, to: Float, dst: Xmm, src: XmmRm) !void {
    try e.reserve();
    const from: Float = if (to == .f64) .f32 else .f64;
    try e.modRm(.{ .prefix = scalarPrefix(from) }, &.{ 0x0f, 0x5a }, @backingInt(dst), rmXmm(src), 0);
}

/// movd/movq from a GPR or memory into the low lane of an XMM register.
pub fn movToXmm(e: *Encoder, size: Size, dst: Xmm, src: Rm) !void {
    assert(size == .dword or size == .qword);
    try e.reserve();
    try e.modRm(.{ .op16 = true, .w = size == .qword }, &.{ 0x0f, 0x6e }, @backingInt(dst), rmGpr(src), 0);
}

/// movd/movq from the low lane of an XMM register into a GPR or memory.
pub fn movFromXmm(e: *Encoder, size: Size, dst: Rm, src: Xmm) !void {
    assert(size == .dword or size == .qword);
    try e.reserve();
    try e.modRm(.{ .op16 = true, .w = size == .qword }, &.{ 0x0f, 0x7e }, @backingInt(src), rmGpr(dst), 0);
}

/// movups: all 128 bits, register to register, load, or store (unaligned).
pub fn movups(e: *Encoder, dst: XmmRm, src: XmmRm) !void {
    try e.reserve();
    switch (dst) {
        .reg => |d| try e.modRm(.{}, &.{ 0x0f, 0x10 }, @backingInt(d), rmXmm(src), 0),
        .mem => try e.modRm(.{}, &.{ 0x0f, 0x11 }, @backingInt(src.reg), rmXmm(dst), 0),
    }
}

// ---------------------------------------------------------------- x87

/// Memory operand of an x87 load or store: f32, f64, or f80.
pub const X87Mem = enum { m32, m64, m80 };

/// fld: pushes a float from memory onto the x87 stack.
pub fn fld(e: *Encoder, size: X87Mem, src: Mem) !void {
    try e.reserve();
    switch (size) {
        .m32 => try e.modRm(.{}, &.{0xd9}, 0, .{ .mem = src }, 0),
        .m64 => try e.modRm(.{}, &.{0xdd}, 0, .{ .mem = src }, 0),
        .m80 => try e.modRm(.{}, &.{0xdb}, 5, .{ .mem = src }, 0),
    }
}

/// fstp: pops st0 into memory, rounding to the memory format.
pub fn fstp(e: *Encoder, size: X87Mem, dst: Mem) !void {
    try e.reserve();
    switch (size) {
        .m32 => try e.modRm(.{}, &.{0xd9}, 3, .{ .mem = dst }, 0),
        .m64 => try e.modRm(.{}, &.{0xdd}, 3, .{ .mem = dst }, 0),
        .m80 => try e.modRm(.{}, &.{0xdb}, 7, .{ .mem = dst }, 0),
    }
}

pub const X87Op = enum(u8) { add = 0xc1, mul = 0xc9, sub = 0xe9, div = 0xf9 };

/// faddp, fmulp, fsubp, fdivp: `st1 = st1 op st0`, then pops.
pub fn x87ArithPop(e: *Encoder, op: X87Op) !void {
    try e.code.appendSlice(e.gpa, &.{ 0xde, @backingInt(op) });
}

/// fsqrt: `st0 = sqrt(st0)`.
pub fn fsqrt(e: *Encoder) !void {
    try e.code.appendSlice(e.gpa, &.{ 0xd9, 0xfa });
}

/// fucomip: compares st0 with st1, setting ZF, PF, CF as ucomis does, then
/// pops.
pub fn fucomip(e: *Encoder) !void {
    try e.code.appendSlice(e.gpa, &.{ 0xdf, 0xe9 });
}

/// fstp st0: pops.
pub fn fpop(e: *Encoder) !void {
    try e.code.appendSlice(e.gpa, &.{ 0xdd, 0xd8 });
}

// ---------------------------------------------------------------- encoding core

/// Longest instruction this encoder emits, rounded up.
const max_insn_len = 16;

/// Every instruction reserves capacity first, so the helpers below cannot
/// fail. Only relocations allocate in the middle of an instruction.
/// Appends raw bytes: prefixes (such as the fs segment override, 0x64) and
/// instructions without operands that have no method of their own.
/// Allocates a stack frame of `size` bytes, more than a page, touching each
/// page first, then jumps to `resume_at`: upstream's probe sequences, so a
/// frame cannot step over a guard page. Below 5 pages, unrolled:
///   test [rsp - 4096 * k], esp   (each k with 4096 * k < size)
///   sub rsp, size
/// otherwise a loop, with r10 (upstream's linker scratch register, which
/// carries no argument):
///   mov r10d, size; sub rsp, r10
///   1: test [rsp + r10 - 4096], esp; sub r10, 4096; jae 1b
pub fn probedFrameAlloc(e: *Encoder, size: u32, resume_at: u32) !void {
    const page = 4096;
    assert(size > page);
    try e.code.ensureUnusedCapacity(e.gpa, 4 * 7 + 7 + 5);
    if (size < 5 * page) {
        var off: u32 = page;
        while (off < size) : (off += page) {
            e.bytes(&.{ 0x85, 0xa4, 0x24 });
            e.int(i32, -@as(i32, @intCast(off)));
        }
        e.bytes(&.{ 0x48, 0x81, 0xec });
        e.int(u32, size);
    } else {
        e.bytes(&.{ 0x41, 0xba });
        e.int(u32, size);
        e.bytes(&.{ 0x4c, 0x29, 0xd4 });
        e.bytes(&.{ 0x42, 0x85, 0xa4, 0x14 });
        e.int(i32, -page);
        e.bytes(&.{ 0x49, 0x81, 0xea });
        e.int(u32, page);
        e.bytes(&.{ 0x73, 0xef }); // back over the jae, sub, and test (17 bytes)
    }
    e.byte(0xe9);
    e.int(u32, 0);
    e.patchRel32(@intCast(e.code.items.len - 4), resume_at);
}

pub fn raw(e: *Encoder, bs: []const u8) !void {
    try e.reserve();
    e.bytes(bs);
}

fn reserve(e: *Encoder) !void {
    try e.code.ensureUnusedCapacity(e.gpa, max_insn_len);
}

fn byte(e: *Encoder, b: u8) void {
    e.code.appendAssumeCapacity(b);
}

fn bytes(e: *Encoder, bs: []const u8) void {
    e.code.appendSliceAssumeCapacity(bs);
}

fn int(e: *Encoder, comptime T: type, v: T) void {
    std.mem.writeInt(T, e.code.addManyAsArrayAssumeCapacity(@sizeOf(T)), v, .little);
}

/// Immediate of an instruction with operand size `size`: qword operands take
/// a sign-extended imm32.
fn immediate(e: *Encoder, size: Size, v: i64) void {
    switch (size) {
        .byte => e.int(u8, @bitCast(@as(i8, @truncate(v)))),
        .word => e.int(u16, @bitCast(@as(i16, @truncate(v)))),
        .dword => e.int(u32, @bitCast(@as(i32, @truncate(v)))),
        .qword => e.int(i32, @intCast(v)),
    }
}

fn immLen(size: Size) u8 {
    return @min(size.bytes(), 4);
}

fn ext(n: u4) u1 {
    return @truncate(n >> 3);
}

fn scalarPrefix(ty: Float) u8 {
    return switch (ty) {
        .f32 => 0xf3,
        .f64 => 0xf2,
    };
}

fn reloc(e: *Encoder, kind: Atom.Reloc.Kind, target: SymbolKey, addend: i64) !void {
    try e.refs.append(e.gpa, @intCast(e.code.items.len), kind, target, addend);
}

fn rel32(e: *Encoder, target: Target) !void {
    switch (target) {
        .sym => |s| {
            try e.reloc(.x86_64_pc32, s, -4);
            e.int(u32, 0);
        },
        .label => |l| {
            const at: u32 = @intCast(e.code.items.len);
            const dest = e.labels.items[@backingInt(l)];
            if (dest == unbound) try e.fixups.append(e.gpa, .{ .at = at, .label = l });
            e.int(u32, 0);
            if (dest != unbound) e.patchRel32(at, dest);
        },
    }
}

fn patchRel32(e: *Encoder, at: u32, dest: u32) void {
    assert(dest != unbound);
    const rel: i32 = @intCast(@as(i64, dest) - (@as(i64, at) + 4));
    std.mem.writeInt(i32, e.code.items[at..][0..4], rel, .little);
}

const RmEnc = union(enum) { reg: u4, mem: Mem };

fn rmGpr(rm: Rm) RmEnc {
    return switch (rm) {
        .reg => |r| .{ .reg = @backingInt(r) },
        .mem => |m| .{ .mem = m },
    };
}

fn rmXmm(rm: XmmRm) RmEnc {
    return switch (rm) {
        .reg => |r| .{ .reg = @backingInt(r) },
        .mem => |m| .{ .mem = m },
    };
}

const Rex = struct { w: bool = false, r: u1 = 0, x: u1 = 0, b: u1 = 0 };
const Opts = struct {
    /// Mandatory prefix (0xf2, 0xf3) or 0.
    prefix: u8 = 0,
    /// Operand-size override (0x66), for word operands and packed-double SSE.
    op16: bool = false,
    w: bool = false,
    /// Emit REX even if empty, to reach spl/bpl/sil/dil.
    force_rex: bool = false,
};

fn prefixes(e: *Encoder, rex: Rex, o: Opts) void {
    if (o.op16) e.byte(0x66);
    if (o.prefix != 0) e.byte(o.prefix);
    const bits: u8 = (@as(u8, @intFromBool(rex.w)) << 3) | (@as(u8, rex.r) << 2) | (@as(u8, rex.x) << 1) | rex.b;
    if (bits != 0 or o.force_rex) e.byte(0x40 | bits);
}

const RegField = union(enum) { reg: Reg, ext: u3 };

/// A GPR instruction whose opcode is `op8` for byte operands and `op`
/// otherwise, with ModRM.reg = `reg` and ModRM.rm = `rm`.
fn gprRm(e: *Encoder, size: Size, op8: u8, op: u8, reg: RegField, rm: Rm, imm_len: u8) !void {
    const is_byte = size == .byte;
    const reg_num: u4, const reg_rex = switch (reg) {
        .reg => |r| .{ @backingInt(r), is_byte and r.needsRexAsByte() },
        .ext => |n| .{ n, false },
    };
    try e.modRm(.{
        .op16 = size == .word,
        .w = size == .qword,
        .force_rex = reg_rex or (is_byte and rm == .reg and rm.reg.needsRexAsByte()),
    }, &.{if (is_byte) op8 else op}, reg_num, rmGpr(rm), imm_len);
}

/// Prefixes, opcode, ModRM, SIB, and displacement. `imm_len` is the number
/// of immediate bytes the caller appends afterwards, which a RIP-relative
/// relocation must account for.
fn modRm(e: *Encoder, o: Opts, opcode: []const u8, reg: u4, rm: RmEnc, imm_len: u8) !void {
    var rex: Rex = .{ .w = o.w, .r = ext(reg) };
    switch (rm) {
        .reg => |r| rex.b = ext(r),
        .mem => |m| {
            if (m.base == .reg) rex.b = ext(@backingInt(m.base.reg));
            if (m.index) |i| rex.x = ext(@backingInt(i.reg));
        },
    }
    e.prefixes(rex, o);
    e.bytes(opcode);
    const reg3: u3 = @truncate(reg);
    const m = switch (rm) {
        .reg => |r| return e.byte(modrmByte(0b11, reg3, @truncate(r))),
        .mem => |m| m,
    };
    switch (m.base) {
        .sym => |s| {
            assert(m.index == null);
            e.byte(modrmByte(0b00, reg3, 0b101));
            try e.reloc(.x86_64_pc32, s, @as(i64, m.disp) - 4 - imm_len);
            e.int(u32, 0);
        },
        .rip => {
            assert(m.index == null);
            e.byte(modrmByte(0b00, reg3, 0b101));
            e.int(i32, m.disp);
        },
        .none => {
            e.byte(modrmByte(0b00, reg3, 0b100));
            if (m.index) |i| {
                assert(i.reg != .rsp);
                e.byte(sibByte(@backingInt(i.scale), i.reg.low(), 0b101));
            } else e.byte(sibByte(0, 0b100, 0b101));
            e.int(i32, m.disp);
        },
        .reg => |base| {
            // rbp and r13 as base have no disp-less form.
            const mod: u2 = if (m.disp == 0 and base.low() != 0b101)
                0b00
            else if (std.math.cast(i8, m.disp) != null) 0b01 else 0b10;
            if (m.index) |i| {
                assert(i.reg != .rsp);
                e.byte(modrmByte(mod, reg3, 0b100));
                e.byte(sibByte(@backingInt(i.scale), i.reg.low(), base.low()));
            } else if (base.low() == 0b100) {
                // rsp and r12 as base need a SIB byte.
                e.byte(modrmByte(mod, reg3, 0b100));
                e.byte(sibByte(0, 0b100, 0b100));
            } else {
                e.byte(modrmByte(mod, reg3, base.low()));
            }
            switch (mod) {
                0b00 => {},
                0b01 => e.int(i8, @intCast(m.disp)),
                0b10 => e.int(i32, m.disp),
                0b11 => unreachable,
            }
        },
    }
}

fn modrmByte(mod: u2, reg: u3, rm: u3) u8 {
    return (@as(u8, mod) << 6) | (@as(u8, reg) << 3) | rm;
}

fn sibByte(scale: u2, index: u3, base: u3) u8 {
    return (@as(u8, scale) << 6) | (@as(u8, index) << 3) | base;
}

test "encodings with special cases match GNU as" {
    const gpa = std.testing.allocator;
    var e: Encoder = .init(gpa);
    defer e.deinit();
    const foo: SymbolKey = .fromName("foo");
    try e.mov(.qword, .{ .mem = .at(.rsp, 8) }, .{ .reg = .rax }); // 48 89 44 24 08
    try e.mov(.qword, .{ .reg = .rax }, .{ .mem = .at(.r12, 0) }); // 49 8b 04 24
    try e.mov(.qword, .{ .reg = .rax }, .{ .mem = .at(.rbp, 0) }); // 48 8b 45 00
    try e.mov(.dword, .{ .reg = .r11 }, .{ .mem = .{ .base = .{ .reg = .r13 }, .index = .{ .reg = .r12, .scale = .@"8" }, .disp = -4096 } });
    try e.mov(.byte, .{ .reg = .rsi }, .{ .reg = .rdi }); // 40 88 fe
    try e.mov(.byte, .{ .reg = .r8 }, .{ .imm = 1 }); // 41 b0 01
    try e.mov(.qword, .{ .reg = .rax }, .{ .imm = -1 }); // 48 c7 c0 ff ff ff ff
    try e.mov(.qword, .{ .reg = .rax }, .{ .imm = 0xffffffff }); // b8 ff ff ff ff
    try e.mov(.qword, .{ .reg = .rax }, .{ .imm = 0x100000000 }); // movabs
    try e.alu(.add, .qword, .{ .reg = .rax }, .{ .imm = 1000 }); // 48 05 e8 03 00 00
    try e.alu(.add, .dword, .{ .reg = .r9 }, .{ .imm = -128 }); // 41 83 c1 80
    try e.movzx(.dword, .rax, .byte, .{ .reg = .rsi }); // 40 0f b6 c6
    try e.movsx(.qword, .rax, .dword, .{ .reg = .rcx }); // 48 63 c1
    try e.shift(.shl, .qword, .{ .reg = .rcx }, 1); // 48 d1 e1
    try e.setcc(.ne, .{ .reg = .r10 }); // 41 0f 95 c2
    try e.cvtsi2s(.f64, .xmm9, .qword, .{ .reg = .rax }); // f2 4c 0f 2a c8
    try e.movFromXmm(.qword, .{ .reg = .rax }, .xmm8); // 66 4c 0f 7e c0
    try e.mov(.dword, .{ .mem = .sym(foo, 8) }, .{ .imm = 5 }); // c7 05 <pc32 foo+0> 05 00 00 00
    const expected = "48894424" ++ "08" ++ "498b0424" ++ "488b4500" ++ "478b9ce500f0ffff" ++ "4088fe" ++ "41b001" ++
        "48c7c0ffffffff" ++ "b8ffffffff" ++ "48b80000000001000000" ++ "4805e8030000" ++ "4183c180" ++ "400fb6c6" ++
        "4863c1" ++ "48d1e1" ++ "410f95c2" ++ "f24c0f2ac8" ++ "664c0f7ec0" ++ "c705000000000500" ++ "0000";
    var buf: [expected.len / 2]u8 = undefined;
    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&buf, expected), e.code.items);
    // The immediate after the field shifts the addend: 8 - 4 - 4.
    try std.testing.expectEqualSlices(SymbolKey, &.{foo}, e.refs.targets.keys());
    try std.testing.expectEqualDeep(&[_]Atom.Reloc{.init(0x55, .x86_64_pc32, 0, 0)}, e.refs.relocs.items);
    // Further references share the target table entry.
    const bar: SymbolKey = .fromName("bar");
    try e.call(.{ .sym = bar });
    try e.jmp(.{ .sym = foo });
    try e.movImmValue(.r9, bar); // 41 b9 <value32 bar>
    try std.testing.expectEqualSlices(u8, &.{ 0x41, 0xb9, 0, 0, 0, 0 }, e.code.items[0x67..]);
    try std.testing.expectEqualSlices(SymbolKey, &.{ foo, bar }, e.refs.targets.keys());
    try std.testing.expectEqualDeep(&[_]Atom.Reloc{
        .init(0x55, .x86_64_pc32, 0, 0),
        .init(0x5e, .x86_64_pc32, 1, -4),
        .init(0x63, .x86_64_pc32, 0, -4),
        .init(0x69, .value32, 1, 0),
    }, e.refs.relocs.items);
    // As GNU as assembles `mov rax, fs:0; lea rax, [rax + x@tpoff]` and
    // the same with r12, which needs a SIB byte as a base.
    e.code.clearRetainingCapacity();
    e.refs.relocs.clearRetainingCapacity();
    try e.leaThreadLocal(.rax, foo);
    try e.leaThreadLocal(.r12, bar);
    const tls_expected = "64488b042500000000" ++ "488d8000000000" ++ "644c8b242500000000" ++ "4d8da42400000000";
    var tls_buf: [tls_expected.len / 2]u8 = undefined;
    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&tls_buf, tls_expected), e.code.items);
    try std.testing.expectEqualDeep(&[_]Atom.Reloc{
        .init(12, .x86_64_tpoff32, 0, 0),
        .init(29, .x86_64_tpoff32, 1, 0),
    }, e.refs.relocs.items);
    // As GNU as assembles `lea x@tlsld(%rip), %rdi; call
    // __tls_get_addr@PLT; lea x@dtpoff(%rax), %r12`, the form linkers
    // relax.
    e.code.clearRetainingCapacity();
    e.refs.relocs.clearRetainingCapacity();
    try e.leaThreadLocalDynamic(.r12, foo, bar);
    const ld_expected = "488d3d00000000" ++ "e800000000" ++ "4c8da000000000";
    var ld_buf: [ld_expected.len / 2]u8 = undefined;
    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&ld_buf, ld_expected), e.code.items);
    try std.testing.expectEqualDeep(&[_]Atom.Reloc{
        .init(3, .x86_64_tlsld, 0, -4),
        .init(8, .x86_64_pc32, 1, -4),
        .init(15, .x86_64_dtpoff32, 0, 0),
    }, e.refs.relocs.items);
    // As GNU as assembles `mov %fs:0, %r12; add x@gottpoff(%rip), %r12`,
    // the same with rax, and `data16 lea x@tlsgd(%rip), %rdi; .word
    // 0x6666; rex64 call __tls_get_addr@PLT`.
    e.code.clearRetainingCapacity();
    e.refs.relocs.clearRetainingCapacity();
    try e.leaThreadLocalInitial(.r12, foo);
    try e.leaThreadLocalInitial(.rax, foo);
    try e.leaThreadLocalGeneral(foo, bar);
    const ie_expected = "644c8b242500000000" ++ "4c032500000000" ++ "64488b042500000000" ++ "48030500000000" ++
        "66488d3d00000000" ++ "666648e800000000";
    var ie_buf: [ie_expected.len / 2]u8 = undefined;
    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&ie_buf, ie_expected), e.code.items);
    try std.testing.expectEqualDeep(&[_]Atom.Reloc{
        .init(0xc, .x86_64_gottpoff, 0, -4),
        .init(0x1c, .x86_64_gottpoff, 0, -4),
        .init(0x24, .x86_64_tlsgd, 0, -4),
        .init(0x2c, .x86_64_pc32, 1, -4),
    }, e.refs.relocs.items);
}

test "branches to labels bound before and after them" {
    const gpa = std.testing.allocator;
    var e: Encoder = .init(gpa);
    defer e.deinit();
    const top = try e.newLabel();
    const out = try e.newLabel();
    e.bind(top);
    try e.jcc(.e, .{ .label = out }); // 0: 0f 84 rel32 -> 12
    try e.int3(); // 6
    try e.jmp(.{ .label = top }); // 7: e9 rel32 -> 0
    e.bind(out); // 12
    try e.ret();
    e.finish();
    try std.testing.expectEqualSlices(u8, &.{ 0x0f, 0x84, 0x06, 0, 0, 0, 0xcc, 0xe9, 0xf4, 0xff, 0xff, 0xff, 0xc3 }, e.code.items);
    try std.testing.expectEqual(0, e.refs.relocs.items.len);
}

test "branches in reach take the short form and the code after them moves" {
    const gpa = std.testing.allocator;
    var e: Encoder = .init(gpa);
    defer e.deinit();
    e.shorten = true;
    const top = try e.newLabel();
    const out = try e.newLabel();
    const far = try e.newLabel();
    e.bind(top);
    try e.jcc(.e, .{ .label = out }); // 0 -> 0: 74 07
    try e.call(.{ .sym = .fromName("f") }); // 6 -> 2, relocation at 7 -> 3
    try e.jmp(.{ .label = top }); // 11 -> 7: eb f7
    e.bind(out); // 16 -> 9
    try e.line(4, 2);
    try e.ret();
    // 130 bytes away even with the others short: stays long.
    try e.jmp(.{ .label = far }); // 17 -> 10: e9 rel32 -> 145
    for (0..130) |_| try e.int3();
    e.bind(far); // 152 -> 145
    try e.ret();
    try e.finishShortened();
    var want: [146]u8 = undefined;
    @memcpy(want[0..15], &[_]u8{ 0x74, 0x07, 0xe8, 0, 0, 0, 0, 0xeb, 0xf7, 0xc3, 0xe9, 0x82, 0, 0, 0 });
    @memset(want[15..145], 0xcc);
    want[145] = 0xc3;
    try std.testing.expectEqualSlices(u8, &want, e.code.items);
    try std.testing.expectEqual(3, e.refs.relocs.items[0].offset);
    try std.testing.expectEqual(9, e.mapOffset(16));
    try std.testing.expectEqual(9, e.lines.state.offset);
}

test "bit scans, byte swaps, exchanges, and string ops match GNU as" {
    const gpa = std.testing.allocator;
    var e: Encoder = .init(gpa);
    defer e.deinit();
    try e.repMovsb(); // f3 a4
    try e.repStosb(); // f3 aa
    try e.setDirection(true); // fd
    try e.setDirection(false); // fc
    try e.bitScan(true, .qword, .rax, .{ .reg = .rcx }); // 48 0f bd c1
    try e.bitScan(false, .dword, .r9, .{ .mem = .at(.r12, 0) }); // 45 0f bc 0c 24
    try e.bitScan(true, .word, .rdx, .{ .reg = .r10 }); // 66 41 0f bd d2
    try e.bswap(.dword, .rax); // 0f c8
    try e.bswap(.qword, .r11); // 49 0f cb
    try e.bswap(.qword, .rdi); // 48 0f cf
    try e.xchg(.qword, .{ .reg = .rbx }, .rbx); // 48 87 db
    try e.xchg(.dword, .{ .mem = .at(.rax, 8) }, .r10); // 44 87 50 08
    try e.xchg(.byte, .{ .reg = .rsi }, .rcx); // 40 86 ce
    const expected = "f3a4" ++ "f3aa" ++ "fd" ++ "fc" ++ "480fbdc1" ++ "450fbc0c24" ++ "66410fbdd2" ++ "0fc8" ++ "490fcb" ++ "480fcf" ++
        "4887db" ++ "44875008" ++ "4086ce";
    var buf: [expected.len / 2]u8 = undefined;
    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&buf, expected), e.code.items);
}

test "movups, x87 instructions, and double shifts match GNU as" {
    const gpa = std.testing.allocator;
    var e: Encoder = .init(gpa);
    defer e.deinit();
    try e.movups(.{ .reg = .xmm1 }, .{ .mem = .at(.rax, 0) }); // 0f 10 08
    try e.movups(.{ .mem = .at(.rbp, -16) }, .{ .reg = .xmm9 }); // 44 0f 11 4d f0
    try e.movups(.{ .reg = .xmm3 }, .{ .reg = .xmm2 }); // 0f 10 da
    try e.fld(.m80, .at(.rsp, 8)); // db 6c 24 08
    try e.fstp(.m80, .at(.rbp, -32)); // db 7d e0
    try e.fld(.m80, .at(.r10, 0)); // 41 db 2a
    try e.fld(.m32, .at(.rax, 0)); // d9 00
    try e.fstp(.m64, .at(.rsp, 0)); // dd 1c 24
    try e.x87ArithPop(.sub); // de e9
    try e.x87ArithPop(.div); // de f9
    try e.fsqrt(); // d9 fa
    try e.fucomip(); // df e9
    try e.fpop(); // dd d8
    try e.shiftDouble(true, .{ .reg = .rax }, .rdx); // 48 0f a5 d0
    try e.shiftDouble(false, .{ .reg = .r10 }, .r9); // 4d 0f ad ca
    const expected = "0f1008" ++ "440f114df0" ++ "0f10da" ++ "db6c2408" ++ "db7de0" ++ "41db2a" ++ "d900" ++ "dd1c24" ++
        "dee9" ++ "def9" ++ "d9fa" ++ "dfe9" ++ "ddd8" ++ "480fa5d0" ++ "4d0fadca";
    var buf: [expected.len / 2]u8 = undefined;
    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&buf, expected), e.code.items);
}
