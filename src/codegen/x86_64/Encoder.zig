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
/// With `shorten`: the rel32 fields of `leaLabel`s and of `call`s to
/// labels, which shortening patches again.
label_addrs: std.ArrayList(struct { at: u32, label: Label }) = .empty,
/// After `finish` shortened branches: per branch, the bytes saved by the
/// branches before it (one more entry for the total), for `mapOffset`.
saved: std.ArrayList(u32) = .empty,
/// Jump table entries (`labelDelta`): the 4 bytes at `at` hold `label`'s
/// offset minus `base`'s, written once the labels' offsets are final.
deltas: std.ArrayList(struct { at: u32, label: Label, base: Label }) = .empty,
/// With `shorten`: line rows and file switches until `finishShortened`,
/// which writes them to `lines` at their final offsets; afterwards they go
/// there directly.
line_events: std.ArrayList(LineEvent) = .empty,
finished: bool = false,
/// The general-purpose registers the instructions encoded since it was
/// last cleared write, by bit (`Reg`): their destinations and the ones
/// they write implicitly. A call writes every caller-saved one. CodeGen
/// checks it against the scratch registers each value may use.
written: u16 = 0,

const LineEvent = struct { offset: u32, kind: enum { row, switch_to }, a: u32, b: u32 };

const unbound = std.math.maxInt(u32);

/// The registers a call does not preserve.
pub const caller_saved: u16 = Reg.bit(.rax) | Reg.bit(.rcx) | Reg.bit(.rdx) | Reg.bit(.rsi) | Reg.bit(.rdi) |
    Reg.bit(.r8) | Reg.bit(.r9) | Reg.bit(.r10) | Reg.bit(.r11);

fn writes(e: *Encoder, r: Reg) void {
    e.written |= r.bit();
}

fn writesRm(e: *Encoder, rm: Rm) void {
    if (rm == .reg) e.writes(rm.reg);
}

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
    pub fn bit(r: Reg) u16 {
        return @as(u16, 1) << @backingInt(r);
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
    e.label_addrs.deinit(e.gpa);
    e.saved.deinit(e.gpa);
    e.deltas.deinit(e.gpa);
    e.line_events.deinit(e.gpa);
    e.* = undefined;
}

/// Patches branches to labels and jump table entries. Every label must be
/// bound.
pub fn finish(e: *Encoder) void {
    for (e.fixups.items) |f| e.patchRel32(f.at, e.labels.items[@backingInt(f.label)]);
    e.fixups.clearRetainingCapacity();
    e.patchDeltas();
}

fn patchDeltas(e: *Encoder) void {
    for (e.deltas.items) |d| {
        const v: i32 = @intCast(@as(i64, e.labels.items[@backingInt(d.label)]) - e.labels.items[@backingInt(d.base)]);
        std.mem.writeInt(i32, e.code.items[e.mapOffset(d.at)..][0..4], v, .little);
    }
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
    for (e.label_addrs.items) |a| e.patchRel32(e.mapOffset(a.at), e.labels.items[@backingInt(a.label)]);
    e.patchDeltas();
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
    e.writesRm(dst);
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
    e.writes(dst);
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
    e.writes(dst);
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
    e.writes(dst);
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
    e.writes(dst);
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
    return e.threadLocalFromSlot(dst, sym, .x86_64_gottpoff);
}

/// `leaThreadLocalInitial` through `slot`, an executable's own atom
/// holding the variable's offset from the thread pointer: `mov dst, fs:0;
/// add dst, [rip + slot]`.
pub fn leaThreadLocalSlot(e: *Encoder, dst: Reg, slot: SymbolKey) !void {
    return e.threadLocalFromSlot(dst, slot, .x86_64_pc32);
}

fn threadLocalFromSlot(e: *Encoder, dst: Reg, sym: SymbolKey, kind: Atom.Reloc.Kind) !void {
    try e.reserve();
    e.writes(dst);
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
    try e.reloc(kind, sym, -4);
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
    e.written |= caller_saved;
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
    e.writes(dst);
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
    e.writes(dst);
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

/// `lea dst, [rip + label]` (inline asm's `leaq 0f(%rip)`).
pub fn leaLabel(e: *Encoder, dst: Reg, label: Label) !void {
    try e.reserve();
    e.writes(dst);
    e.prefixes(.{ .w = true, .r = ext(@backingInt(dst)) }, .{});
    e.byte(0x8d);
    e.byte(modrmByte(0b00, dst.low(), 0b101)); // [rip + disp32]
    if (e.shorten) try e.label_addrs.append(e.gpa, .{ .at = @intCast(e.code.items.len), .label = label });
    try e.rel32(.{ .label = label });
}

/// A jump table entry: the 32-bit offset of `label` from `base`, as data in
/// the code (`finish` writes it).
pub fn labelDelta(e: *Encoder, label: Label, base: Label) !void {
    try e.reserve();
    try e.deltas.append(e.gpa, .{ .at = @intCast(e.code.items.len), .label = label, .base = base });
    e.int(u32, 0);
}

/// `push imm32`, sign-extended to 64 bits.
pub fn pushImm(e: *Encoder, v: i32) !void {
    try e.reserve();
    if (std.math.cast(i8, v)) |b| {
        e.bytes(&.{ 0x6a, @bitCast(b) });
    } else {
        e.byte(0x68);
        e.int(i32, v);
    }
}

pub fn push(e: *Encoder, r: Reg) !void {
    try e.reserve();
    e.prefixes(.{ .b = ext(@backingInt(r)) }, .{});
    e.byte(0x50 | @as(u8, r.low()));
}

pub fn pop(e: *Encoder, r: Reg) !void {
    try e.reserve();
    e.writes(r);
    e.prefixes(.{ .b = ext(@backingInt(r)) }, .{});
    e.byte(0x58 | @as(u8, r.low()));
}

pub fn cmov(e: *Encoder, cond: Cond, size: Size, dst: Reg, src: Rm) !void {
    assert(size != .byte);
    try e.reserve();
    e.writes(dst);
    try e.modRm(.{ .w = size == .qword, .op16 = size == .word }, &.{ 0x0f, 0x40 | @as(u8, @backingInt(cond)) }, @backingInt(dst), rmGpr(src), 0);
}

/// Sets the byte `dst` to 1 if `cond` holds, else 0.
pub fn setcc(e: *Encoder, cond: Cond, dst: Rm) !void {
    try e.reserve();
    e.writesRm(dst);
    try e.modRm(.{ .force_rex = dst == .reg and dst.reg.needsRexAsByte() }, &.{ 0x0f, 0x90 | @as(u8, @backingInt(cond)) }, 0, rmGpr(dst), 0);
}

// ---------------------------------------------------------------- arithmetic

pub const AluOp = enum(u3) { add, @"or", adc, sbb, @"and", sub, xor, cmp };

/// `op dst, src` for add, or, adc, sbb, and, sub, xor, cmp. A qword
/// immediate must fit in i32.
pub fn alu(e: *Encoder, op: AluOp, size: Size, dst: Rm, src: Operand) !void {
    try e.reserve();
    if (op != .cmp) e.writesRm(dst);
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
    switch (op) {
        .not, .neg => e.writesRm(dst),
        .mul, .imul, .div, .idiv => e.written |= Reg.bit(.rax) | Reg.bit(.rdx),
    }
    try e.gprRm(size, 0xf6, 0xf7, .{ .ext = @backingInt(op) }, dst, 0);
}

/// `imul dst, src` or, with `imm`, `imul dst, src, imm`.
pub fn imul(e: *Encoder, size: Size, dst: Reg, src: Rm, imm: ?i32) !void {
    assert(size != .byte);
    try e.reserve();
    e.writes(dst);
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
    // cbw writes ah.
    e.writes(if (size == .byte) .rax else .rdx);
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
    e.writesRm(dst);
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
    e.writesRm(dst);
    try e.modRm(.{ .w = true }, &.{ 0x0f, if (left) 0xa5 else 0xad }, @backingInt(src), rmGpr(dst), 0);
}

/// `shld dst, src, count` (`left`) or `shrd dst, src, count` on qwords.
pub fn shiftDoubleImm(e: *Encoder, left: bool, dst: Rm, src: Reg, count: u8) !void {
    try e.reserve();
    e.writesRm(dst);
    try e.modRm(.{ .w = true }, &.{ 0x0f, if (left) 0xa4 else 0xac }, @backingInt(src), rmGpr(dst), 1);
    e.byte(count);
}

/// `bsf dst, src` (forward) or `bsr dst, src` (reverse): index of the lowest
/// or highest set bit. Sets ZF and leaves `dst` undefined when `src` is 0.
pub fn bitScan(e: *Encoder, reverse: bool, size: Size, dst: Reg, src: Rm) !void {
    assert(size != .byte);
    try e.reserve();
    e.writes(dst);
    try e.modRm(.{ .w = size == .qword, .op16 = size == .word }, &.{ 0x0f, if (reverse) 0xbd else 0xbc }, @backingInt(dst), rmGpr(src), 0);
}

/// Reverses the bytes of a dword or qword register.
pub fn bswap(e: *Encoder, size: Size, r: Reg) !void {
    assert(size == .dword or size == .qword);
    try e.reserve();
    e.writes(r);
    e.prefixes(.{ .w = size == .qword, .b = ext(@backingInt(r)) }, .{});
    e.bytes(&.{ 0x0f, 0xc8 | @as(u8, r.low()) });
}

/// Exchanges `a` with register `b`.
pub fn xchg(e: *Encoder, size: Size, a: Rm, b: Reg) !void {
    try e.reserve();
    e.writesRm(a);
    e.writes(b);
    try e.gprRm(size, 0x86, 0x87, .{ .reg = b }, a, 0);
}

/// `lock cmpxchg [dst], src`: if [dst] equals al/ax/eax/rax, stores `src`
/// there (ZF set); else loads [dst] into it (ZF clear).
pub fn lockCmpxchg(e: *Encoder, size: Size, dst: Mem, src: Reg) !void {
    e.writes(.rax);
    try e.lock0f(size, 0xb0, 0xb1, dst, src);
}

/// `lock cmpxchg16b [dst]`: if the 16 bytes at `dst` (16-byte aligned)
/// equal rdx:rax, stores rcx:rbx there (ZF set); else loads them into
/// rdx:rax (ZF clear).
pub fn lockCmpxchg16b(e: *Encoder, dst: Mem) !void {
    try e.reserve();
    e.written |= Reg.bit(.rax) | Reg.bit(.rdx);
    e.byte(0xf0);
    try e.modRm(.{ .w = true }, &.{ 0x0f, 0xc7 }, 1, rmGpr(.{ .mem = dst }), 0);
}

/// `lock xadd [dst], src`: adds `src` to [dst] and leaves the old value
/// in `src`.
pub fn lockXadd(e: *Encoder, size: Size, dst: Mem, src: Reg) !void {
    e.writes(src);
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

/// An instruction from inline assembly (`asm_insn.zig`, which picks the
/// form): legacy prefix `prefix` (0xf2, 0xf3, 0x66 or 0, after the
/// operand-size override), `opcode`, ModRM with `reg` (a register or an
/// opcode extension) and `rm`, then an immediate of `imm_len` bytes.
/// `size` sets the operand-size override (word) and REX.W (qword); null
/// for instructions whose size is fixed. spl, bpl, sil and dil as byte
/// operands get a REX prefix.
pub fn asmModRm(e: *Encoder, size: ?Size, prefix: u8, opcode: []const u8, reg: RegField, rm: Rm, imm: i64, imm_len: u8) !void {
    try e.reserve();
    // Inline assembly's instructions are not modeled.
    e.written |= caller_saved;
    const byte_regs = size == .byte and ((reg == .reg and reg.reg.needsRexAsByte()) or (rm == .reg and rm.reg.needsRexAsByte()));
    const reg_num: u4 = switch (reg) {
        .reg => |r| @backingInt(r),
        .ext => |n| n,
    };
    try e.modRm(.{ .prefix = prefix, .op16 = size == .word, .w = size == .qword, .force_rex = byte_regs }, opcode, reg_num, rmGpr(rm), imm_len);
    switch (imm_len) {
        0 => {},
        1 => e.int(u8, @truncate(@as(u64, @bitCast(imm)))),
        2 => e.int(u16, @truncate(@as(u64, @bitCast(imm)))),
        4 => e.int(u32, @truncate(@as(u64, @bitCast(imm)))),
        else => unreachable,
    }
}

/// An inline assembly instruction that adds register `r` to its last
/// opcode byte (`bswap`, the accumulator `xchg`); `size` as `asmModRm`'s.
pub fn asmO(e: *Encoder, size: Size, opcode: []const u8, r: Reg) !void {
    try e.reserve();
    e.written |= caller_saved;
    e.prefixes(.{ .w = size == .qword, .b = ext(@backingInt(r)) }, .{ .op16 = size == .word });
    e.bytes(opcode[0 .. opcode.len - 1]);
    e.byte(opcode[opcode.len - 1] | r.low());
}

// ---------------------------------------------------------------- strings

/// `rep movsb`: copies rcx bytes from [rsi] to [rdi], backwards if DF is set.
pub fn repMovsb(e: *Encoder) !void {
    e.written |= Reg.bit(.rcx) | Reg.bit(.rsi) | Reg.bit(.rdi);
    try e.code.appendSlice(e.gpa, &.{ 0xf3, 0xa4 });
}

/// `rep stosb`: stores al to rcx bytes at [rdi].
pub fn repStosb(e: *Encoder) !void {
    e.written |= Reg.bit(.rcx) | Reg.bit(.rdi);
    try e.code.appendSlice(e.gpa, &.{ 0xf3, 0xaa });
}

/// `rep stos{w,d,q}`: stores ax, eax or rax to rcx words, dwords or
/// qwords at [rdi].
pub fn repStos(e: *Encoder, size: Size) !void {
    e.written |= Reg.bit(.rcx) | Reg.bit(.rdi);
    try e.code.appendSlice(e.gpa, switch (size) {
        .byte => &.{ 0xf3, 0xaa },
        .word => &.{ 0x66, 0xf3, 0xab },
        .dword => &.{ 0xf3, 0xab },
        .qword => &.{ 0xf3, 0x48, 0xab },
    });
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
    e.written |= caller_saved;
    e.byte(0xe8);
    // Shortening moves the code between the call and its label (the
    // panic stubs after the epilogue).
    if (e.shorten and target == .label) try e.label_addrs.append(e.gpa, .{ .at = @intCast(e.code.items.len), .label = target.label });
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
    e.written |= caller_saved;
    try e.modRm(.{}, &.{0xff}, 2, rmGpr(target), 0);
}

pub fn ret(e: *Encoder) !void {
    try e.code.append(e.gpa, 0xc3);
}

pub fn syscall(e: *Encoder) !void {
    e.written |= Reg.bit(.rax) | Reg.bit(.rcx) | Reg.bit(.r11);
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
    e.writes(dst);
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
    e.writesRm(dst);
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

// ---------------------------------------------------------------- packed SSE

/// Two-operand packed SSE2 instructions, `dst = dst op src`, by their
/// opcode after 0F; all take the 0x66 prefix. A memory `src` must be
/// 16-byte aligned.
pub const PackedOp = enum(u8) {
    punpcklbw = 0x60,
    punpcklwd = 0x61,
    punpckldq = 0x62,
    packsswb = 0x63,
    pcmpgtb = 0x64,
    pcmpgtw = 0x65,
    pcmpgtd = 0x66,
    packuswb = 0x67,
    punpckhbw = 0x68,
    punpckhwd = 0x69,
    punpckhdq = 0x6a,
    packssdw = 0x6b,
    punpcklqdq = 0x6c,
    punpckhqdq = 0x6d,
    pcmpeqb = 0x74,
    pcmpeqw = 0x75,
    pcmpeqd = 0x76,
    // Shifts of every lane by the count in the source's low 64 bits.
    psrlw = 0xd1,
    psrld = 0xd2,
    psrlq = 0xd3,
    paddq = 0xd4,
    pmullw = 0xd5,
    pminub = 0xda,
    pand = 0xdb,
    pmaxub = 0xde,
    pandn = 0xdf,
    psraw = 0xe1,
    psrad = 0xe2,
    pminsw = 0xea,
    por = 0xeb,
    pmaxsw = 0xee,
    pxor = 0xef,
    psllw = 0xf1,
    pslld = 0xf2,
    psllq = 0xf3,
    pmuludq = 0xf4,
    psubb = 0xf8,
    psubw = 0xf9,
    psubd = 0xfa,
    psubq = 0xfb,
    paddb = 0xfc,
    paddw = 0xfd,
    paddd = 0xfe,
};

pub fn pint(e: *Encoder, op: PackedOp, dst: Xmm, src: XmmRm) !void {
    try e.reserve();
    try e.modRm(.{ .op16 = true }, &.{ 0x0f, @backingInt(op) }, @backingInt(dst), rmXmm(src), 0);
}

/// SSSE3 and SSE4.1/4.2 integer ops with the 66 0f 38 xx encoding, for
/// CPUs that have them (`-mcpu`).
pub const PackedOp38 = enum(u8) {
    pshufb = 0x00,
    pcmpeqq = 0x29,
    pcmpgtq = 0x37,
    pminsb = 0x38,
    pminsd = 0x39,
    pminuw = 0x3a,
    pminud = 0x3b,
    pmaxsb = 0x3c,
    pmaxsd = 0x3d,
    pmaxuw = 0x3e,
    pmaxud = 0x3f,
    pmulld = 0x40,
    // AES-NI (`-mcpu` with aes).
    aesimc = 0xdb,
    aesenc = 0xdc,
    aesenclast = 0xdd,
    aesdec = 0xde,
    aesdeclast = 0xdf,
};

pub fn pint38(e: *Encoder, op: PackedOp38, dst: Xmm, src: XmmRm) !void {
    try e.reserve();
    try e.modRm(.{ .op16 = true }, &.{ 0x0f, 0x38, @backingInt(op) }, @backingInt(dst), rmXmm(src), 0);
}

/// The 66 0f 3a xx ib encoding: `aeskeygenassist` (0xdf) and `pclmulqdq`
/// (0x44), for CPUs that have them (`-mcpu`).
pub fn pint3a(e: *Encoder, opcode: u8, dst: Xmm, src: XmmRm, imm: u8) !void {
    try e.reserve();
    try e.modRm(.{ .op16 = true }, &.{ 0x0f, 0x3a, opcode }, @backingInt(dst), rmXmm(src), 1);
    e.byte(imm);
}

/// SSE4.1 pinsrq: qword `src` into lane `lane` of `dst`.
pub fn pinsrq(e: *Encoder, dst: Xmm, src: Rm, lane: u1) !void {
    try e.reserve();
    try e.modRm(.{ .op16 = true, .w = true }, &.{ 0x0f, 0x3a, 0x22 }, @backingInt(dst), rmGpr(src), 1);
    e.byte(lane);
}

/// SSE4.1 pextrq: lane `lane` of `src` into qword `dst`.
pub fn pextrq(e: *Encoder, dst: Rm, src: Xmm, lane: u1) !void {
    try e.reserve();
    e.writesRm(dst);
    try e.modRm(.{ .op16 = true, .w = true }, &.{ 0x0f, 0x3a, 0x16 }, @backingInt(src), rmGpr(dst), 1);
    e.byte(lane);
}

pub const VexMap = enum(u5) { @"0f" = 1, @"0f38" = 2, @"0f3a" = 3 };

/// A VEX.128.66 instruction, AVX's encoding of the SSE integer and AES
/// instructions, which inline assembly names (`vaesenc`): `reg` in
/// ModRM.reg, `vvvv` the extra source register (0 when the instruction
/// has none), then `rm` and the immediate if there is one. bs's own code
/// never uses VEX (`cpu.zig`).
pub fn vex66(e: *Encoder, map: VexMap, opcode: u8, reg: u4, vvvv: u4, rm: XmmRm, imm: ?u8) !void {
    try e.reserve();
    const enc = rmXmm(rm);
    var x: u1 = 0;
    var b: u1 = 0;
    switch (enc) {
        .reg => |r| b = ext(r),
        .mem => |m| {
            if (m.base == .reg) b = ext(@backingInt(m.base.reg));
            if (m.index) |i| x = ext(@backingInt(i.reg));
        },
    }
    // vvvv inverted, L = 0 (128 bits), pp = 01 (66).
    const last: u8 = (@as(u8, ~vvvv & 0xf) << 3) | 0b01;
    if (map == .@"0f" and x == 0 and b == 0) {
        e.byte(0xc5);
        e.byte(@as(u8, ~ext(reg)) << 7 | last);
    } else {
        e.byte(0xc4);
        e.byte(@as(u8, ~ext(reg)) << 7 | @as(u8, ~x) << 6 | @as(u8, ~b) << 5 | @backingInt(map));
        e.byte(last); // W = 0
    }
    e.byte(opcode);
    try e.rmBytes(reg, enc, @intFromBool(imm != null));
    if (imm) |v| e.byte(v);
}

/// SSE4.2 `crc32`: the CRC-32C of `src_size` bytes of `src` folded into
/// the low 32 bits of `dst` (`dst_size` is `.dword` or `.qword`).
pub fn crc32(e: *Encoder, dst_size: Size, src_size: Size, dst: Reg, src: Rm) !void {
    try e.reserve();
    e.writes(dst);
    try e.modRm(.{
        .prefix = 0xf2,
        .op16 = src_size == .word,
        .w = dst_size == .qword,
        .force_rex = src_size == .byte and src == .reg and src.reg.needsRexAsByte(),
    }, &.{ 0x0f, 0x38, if (src_size == .byte) 0xf0 else 0xf1 }, @backingInt(dst), rmGpr(src), 0);
}

/// addps/addpd and friends on all lanes (the scalar ops' opcodes without
/// their prefix). A memory `src` must be 16-byte aligned.
pub fn ps(e: *Encoder, op: SseOp, ty: Float, dst: Xmm, src: XmmRm) !void {
    try e.reserve();
    try e.modRm(.{ .op16 = ty == .f64 }, &.{ 0x0f, @backingInt(op) }, @backingInt(dst), rmXmm(src), 0);
}

/// cmpps/cmppd with predicate `pred` (0 eq, 1 lt, 2 le, 3 unord, 4 neq,
/// 5 nlt, 6 nle, 7 ord): each lane all ones where it holds.
pub fn cmpp(e: *Encoder, ty: Float, dst: Xmm, src: XmmRm, pred: u8) !void {
    try e.reserve();
    try e.modRm(.{ .op16 = ty == .f64 }, &.{ 0x0f, 0xc2 }, @backingInt(dst), rmXmm(src), 1);
    e.byte(pred);
}

pub const Pshuf = enum { d, lw, hw };

/// pshufd (dwords), pshuflw (the low four words; the high qword is
/// copied), pshufhw (the high four words): each lane chosen by two bits
/// of `imm`.
pub fn pshuf(e: *Encoder, kind: Pshuf, dst: Xmm, src: XmmRm, imm: u8) !void {
    try e.reserve();
    const o: Opts = switch (kind) {
        .d => .{ .op16 = true },
        .lw => .{ .prefix = 0xf2 },
        .hw => .{ .prefix = 0xf3 },
    };
    try e.modRm(o, &.{ 0x0f, 0x70 }, @backingInt(dst), rmXmm(src), 1);
    e.byte(imm);
}

pub const PshiftOp = enum { psrlw, psraw, psllw, psrld, psrad, pslld, psrlq, psrldq, psllq, pslldq };

/// Shifts of every lane by `count` bits (psrldq/pslldq: of the whole
/// register by `count` bytes).
pub fn pshift(e: *Encoder, op: PshiftOp, dst: Xmm, count: u8) !void {
    const opcode: u8, const ext_: u4 = switch (op) {
        .psrlw => .{ 0x71, 2 },
        .psraw => .{ 0x71, 4 },
        .psllw => .{ 0x71, 6 },
        .psrld => .{ 0x72, 2 },
        .psrad => .{ 0x72, 4 },
        .pslld => .{ 0x72, 6 },
        .psrlq => .{ 0x73, 2 },
        .psrldq => .{ 0x73, 3 },
        .psllq => .{ 0x73, 6 },
        .pslldq => .{ 0x73, 7 },
    };
    try e.reserve();
    try e.modRm(.{ .op16 = true }, &.{ 0x0f, opcode }, ext_, .{ .reg = @backingInt(dst) }, 1);
    e.byte(count);
}

/// pmovmskb: the top bit of each byte of `src` into the low 16 bits of
/// `dst`, the rest zero.
pub fn pmovmskb(e: *Encoder, dst: Reg, src: Xmm) !void {
    try e.reserve();
    e.writes(dst);
    try e.modRm(.{ .op16 = true }, &.{ 0x0f, 0xd7 }, @backingInt(dst), .{ .reg = @backingInt(src) }, 0);
}

/// movmskps/movmskpd: the sign bit of each lane of `src` into `dst`.
pub fn movmskp(e: *Encoder, ty: Float, dst: Reg, src: Xmm) !void {
    try e.reserve();
    e.writes(dst);
    try e.modRm(.{ .op16 = ty == .f64 }, &.{ 0x0f, 0x50 }, @backingInt(dst), .{ .reg = @backingInt(src) }, 0);
}

/// movdqa (`aligned`) or movdqu: all 128 bits, register to register,
/// load, or store.
pub fn movdq(e: *Encoder, aligned: bool, dst: XmmRm, src: XmmRm) !void {
    try e.reserve();
    const o: Opts = if (aligned) .{ .op16 = true } else .{ .prefix = 0xf3 };
    switch (dst) {
        .reg => |d| try e.modRm(o, &.{ 0x0f, 0x6f }, @backingInt(d), rmXmm(src), 0),
        .mem => try e.modRm(o, &.{ 0x0f, 0x7f }, @backingInt(src.reg), rmXmm(dst), 0),
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
/// page first, then jumps to `resume_at`, so that a frame cannot step over
/// a guard page. Each step moves rsp down a page and then writes the page
/// at rsp, so nothing is written below rsp (Valgrind grows the main
/// thread's stack only for accesses at or above it). The probes write
/// where upstream's `test` reads: a read of an untouched stack page maps
/// the shared zero page, and the frame's first write to it then copies it
/// and flushes every thread's TLB, which a multithreaded program (the
/// build runner's Fetch workers, each with a 64 KiB `undefined` buffer)
/// pays in inter-processor interrupts per page. With n = size / 4096
/// pages, below 5 pages unrolled:
///   sub rsp, 4096; mov [rsp], esp   (n times)
///   sub rsp, size % 4096            (if not 0)
/// otherwise a loop, with r10 (upstream's linker scratch register, which
/// carries no argument):
///   mov r10d, n
///   1: sub rsp, 4096; mov [rsp], esp; dec r10d; jnz 1b
///   sub rsp, size % 4096            (if not 0)
pub fn probedFrameAlloc(e: *Encoder, size: u32, resume_at: u32) !void {
    const page = 4096;
    assert(size > page);
    try e.code.ensureUnusedCapacity(e.gpa, 4 * 10 + 7 + 5);
    const pages = size / page;
    if (size < 5 * page) {
        for (0..pages) |_| {
            e.bytes(&.{ 0x48, 0x81, 0xec });
            e.int(u32, page);
            e.bytes(&.{ 0x89, 0x24, 0x24 });
        }
    } else {
        e.bytes(&.{ 0x41, 0xba });
        e.int(u32, pages);
        e.bytes(&.{ 0x48, 0x81, 0xec });
        e.int(u32, page);
        e.bytes(&.{ 0x89, 0x24, 0x24 });
        e.bytes(&.{ 0x41, 0xff, 0xca });
        e.bytes(&.{ 0x75, 0xf1 }); // back over the jnz, dec, mov, and sub (15 bytes)
    }
    if (size % page != 0) {
        e.bytes(&.{ 0x48, 0x81, 0xec });
        e.int(u32, size % page);
    }
    e.byte(0xe9);
    e.int(u32, 0);
    e.patchRel32(@intCast(e.code.items.len - 4), resume_at);
}

pub fn raw(e: *Encoder, bs: []const u8) !void {
    try e.reserve();
    e.written |= caller_saved;
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

pub const RegField = union(enum) { reg: Reg, ext: u3 };

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
    try e.rmBytes(reg, rm, imm_len);
}

/// The ModRM byte, SIB byte, and displacement of `reg` and `rm`, after
/// the prefixes and opcode; `imm_len` immediate bytes follow them.
fn rmBytes(e: *Encoder, reg: u4, rm: RmEnc, imm_len: u8) !void {
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

test "a call to a label stays on it when branches between them shorten" {
    const gpa = std.testing.allocator;
    var e: Encoder = .init(gpa);
    defer e.deinit();
    e.shorten = true;
    const stub = try e.newLabel();
    const out = try e.newLabel();
    try e.call(.{ .label = stub }); // 0: e8 rel32 -> 12 -> 8
    try e.jcc(.e, .{ .label = out }); // 5: 0f 84 rel32 -> 74 00
    e.bind(out); // 11 -> 7
    try e.int3(); // 11 -> 7
    e.bind(stub); // 12 -> 8
    try e.ret();
    try e.finishShortened();
    try std.testing.expectEqualSlices(u8, &.{ 0xe8, 0x03, 0, 0, 0, 0x74, 0x00, 0xcc, 0xc3 }, e.code.items);
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

test "packed SSE instructions match GNU as" {
    const gpa = std.testing.allocator;
    var e: Encoder = .init(gpa);
    defer e.deinit();
    try e.pint(.paddb, .xmm1, .{ .reg = .xmm2 });
    try e.pint(.pcmpeqb, .xmm9, .{ .mem = .at(.rbp, -32) });
    try e.pint(.pxor, .xmm0, .{ .reg = .xmm15 });
    try e.pint(.psubq, .xmm8, .{ .reg = .xmm3 });
    try e.ps(.add, .f32, .xmm2, .{ .reg = .xmm10 });
    try e.ps(.mul, .f64, .xmm1, .{ .mem = .at(.rax, 0) });
    try e.cmpp(.f32, .xmm3, .{ .reg = .xmm4 }, 1);
    try e.cmpp(.f64, .xmm11, .{ .mem = .at(.r12, 16) }, 4);
    try e.pshuf(.d, .xmm2, .{ .reg = .xmm12 }, 0x4e);
    try e.pshuf(.lw, .xmm2, .{ .reg = .xmm3 }, 0xb1);
    try e.pshuf(.hw, .xmm9, .{ .reg = .xmm3 }, 0);
    try e.pshift(.psrlw, .xmm1, 8);
    try e.pshift(.pslld, .xmm10, 31);
    try e.pshift(.psrldq, .xmm3, 4);
    try e.pshift(.psllq, .xmm2, 1);
    try e.pmovmskb(.rax, .xmm9);
    try e.pmovmskb(.r10, .xmm1);
    try e.movmskp(.f32, .rcx, .xmm2);
    try e.movmskp(.f64, .r11, .xmm14);
    try e.movdq(true, .{ .reg = .xmm1 }, .{ .mem = .at(.rbp, -16) });
    try e.movdq(false, .{ .mem = .at(.r10, 8) }, .{ .reg = .xmm9 });
    try e.movdq(false, .{ .reg = .xmm0 }, .{ .mem = .{ .base = .rip, .disp = 0 } });
    try e.pint38(.pshufb, .xmm1, .{ .reg = .xmm2 });
    try e.pint38(.pmulld, .xmm9, .{ .mem = .at(.rbp, -16) });
    try e.pint38(.pcmpgtq, .xmm0, .{ .reg = .xmm15 });
    try e.pint38(.pmaxud, .xmm12, .{ .reg = .xmm3 });
    try e.crc32(.qword, .byte, .rax, .{ .reg = .rsi });
    try e.crc32(.dword, .word, .rcx, .{ .reg = .r9 });
    try e.crc32(.qword, .qword, .r11, .{ .mem = .at(.rdi, 8) });
    try e.crc32(.dword, .dword, .rdx, .{ .reg = .rbx });
    try e.lockCmpxchg16b(.at(.r10, 0));
    try e.lockCmpxchg16b(.at(.rbp, -32));
    try e.pint(.psrld, .xmm1, .{ .reg = .xmm5 });
    try e.pint(.psllq, .xmm9, .{ .reg = .xmm4 });
    try e.pint(.psraw, .xmm0, .{ .reg = .xmm12 });
    const expected = "660ffcca66440f744de066410fefc766440ffbc3410f58d2660f59080fc2dc0166450fc25c24100466410f70d44ef20f70d3b1f3440f70cb00660f71d10866410f72f21f660f73db04660f73f20166410fd7c166440fd7d10f50ca66450f50de660f6f4df0f3450f7f4a08f30f6f0500000000660f3800ca66440f38404df066410f3837c766440f383fe3f2480f38f0c666f2410f38f1c9f24c0f38f15f08f20f38f1d3f0490fc70af0480fc74de0" ++ "660fd2cd" ++ "66440ff3cc" ++ "66410fe1c4";
    var buf: [expected.len / 2]u8 = undefined;
    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&buf, expected), e.code.items);
}

test "AES-NI, PCLMULQDQ, and their VEX forms match GNU as" {
    const gpa = std.testing.allocator;
    var e: Encoder = .init(gpa);
    defer e.deinit();
    try e.pint38(.aesenc, .xmm1, .{ .reg = .xmm2 });
    try e.pint38(.aesenclast, .xmm9, .{ .mem = .at(.rbp, -16) });
    try e.pint38(.aesdec, .xmm0, .{ .reg = .xmm15 });
    try e.pint38(.aesdeclast, .xmm3, .{ .reg = .xmm4 });
    try e.pint38(.aesimc, .xmm10, .{ .reg = .xmm2 });
    try e.pint3a(0xdf, .xmm1, .{ .reg = .xmm2 }, 1); // aeskeygenassist
    try e.pint3a(0x44, .xmm9, .{ .reg = .xmm10 }, 0x11); // pclmulqdq
    try e.pint3a(0x44, .xmm0, .{ .mem = .at(.rax, 8) }, 0);
    try e.vex66(.@"0f38", 0xdc, 1, 2, .{ .reg = .xmm3 }, null); // vaesenc %xmm3, %xmm2, %xmm1
    try e.vex66(.@"0f38", 0xdd, 9, 10, .{ .reg = .xmm11 }, null);
    try e.vex66(.@"0f38", 0xde, 0, 1, .{ .mem = .at(.r12, 16) }, null);
    try e.vex66(.@"0f38", 0xdb, 2, 0, .{ .reg = .xmm8 }, null); // vaesimc
    try e.vex66(.@"0f3a", 0xdf, 3, 0, .{ .reg = .xmm4 }, 0x1b); // vaeskeygenassist $0x1b
    try e.vex66(.@"0f", 0xef, 1, 2, .{ .reg = .xmm3 }, null); // vpxor, two-byte VEX
    try e.vex66(.@"0f", 0xef, 1, 2, .{ .reg = .xmm9 }, null);
    try e.vex66(.@"0f", 0x73, 7, 5, .{ .reg = .xmm6 }, 4); // vpslldq $4, %xmm6, %xmm5
    try e.vex66(.@"0f", 0x70, 12, 0, .{ .reg = .xmm1 }, 0xff); // vpshufd $0xff, %xmm1, %xmm12
    try e.vex66(.@"0f3a", 0x44, 1, 2, .{ .reg = .xmm3 }, 0x10); // vpclmulqdq $0x10
    const expected = "660f38dcca66440f38dd4df066410f38dec7660f38dfdc66440f38dbd2660f3adfca0166450f3a44ca11660f3a44400800c4e269dccbc44229ddcbc4c271de442410c4c279dbd0c4e379dfdc1bc5e9efcbc4c169efc9c5d173fe04c57970e1ffc4e36944cb10";
    var buf: [expected.len / 2]u8 = undefined;
    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&buf, expected), e.code.items);
}
