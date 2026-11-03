//! Units' results, serialized so that an edit build can load a green
//! unit's result instead of analyzing it (see "Serialized results" in
//! docs/architecture.md). Unlike the rest of `cache/`, this part knows the
//! InternPool.
//!
//! A manifest holds one item table for all its results: every InternPool
//! item some result refers to, once, children before parents. An item is
//! its stable hash, its `Key` tag, and the key's operands, with every
//! `Index` replaced by a `Ref`: a static index, `none_ref`, or
//! `static_len` + the id of an earlier item. Items that name source refer
//! to it by ZIR instruction, which an edit build maps from the old ZIR to
//! the new as `seeds.zig` does: container types by (file, instruction,
//! captures, names, parent namespace), functions by (owner declaration,
//! instruction, generic owner, comptime arguments), and declarations by
//! (the type that owns their namespace, name). A result is a short list of
//! words per unit kind (`encodeNav` and the rest) whose `Index` fields are
//! `Ref`s into the table.
//!
//! Everything is `u32` words, so the table and the results are slices of
//! the mapped manifest and decoding parses nothing else. Strings are
//! inline: a length word, then the bytes, padded to a word.
//!
//! What has no stable identity cannot be encoded: pointers into comptime
//! memory (`comptime_alloc`), and anything that refers to one. A result
//! that needs such an item is not stored, and an edit build analyzes its
//! unit again (`Encoder.fallbacks` counts them by kind).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Zir = std.zig.Zir;
const InternPool = @import("../InternPool.zig");
const Zcu = @import("../Zcu.zig");
const Index = InternPool.Index;
const Hash = InternPool.Hash;

/// An operand: a static index (below `InternPool.static_len`), `none_ref`,
/// or `InternPool.static_len` + an item id.
pub const Ref = u32;
pub const none_ref: Ref = std.math.maxInt(u32);

pub const KeyTag = std.meta.Tag(InternPool.Key);

/// Items nested deeper than this are not encoded (the encoder and decoder
/// recurse).
const max_depth = 1000;

pub const Encoder = struct {
    gpa: Allocator,
    zcu: *Zcu,
    /// The item table: `words[starts[id]..]` is item `id`.
    words: std.ArrayList(u32) = .empty,
    starts: std.ArrayList(u32) = .empty,
    /// Each item seen: its id, or `failed`, or `in_progress`.
    ids: std.AutoHashMapUnmanaged(Index, u32) = .empty,
    /// The items being built, innermost last.
    scratch: std.ArrayList(u32) = .empty,
    depth: u32 = 0,
    /// Why items could not be encoded (their parents are not counted):
    /// pointers into comptime memory, items that refer to themselves, and
    /// items nested too deeply.
    fallbacks: struct { comptime_alloc: u32 = 0, cycle: u32 = 0, too_deep: u32 = 0 } = .{},

    const failed = std.math.maxInt(u32);
    const in_progress = std.math.maxInt(u32) - 1;

    pub fn deinit(e: *Encoder) void {
        e.words.deinit(e.gpa);
        e.starts.deinit(e.gpa);
        e.ids.deinit(e.gpa);
        e.scratch.deinit(e.gpa);
    }

    /// The ref of `index`, encoding its closure first; null if it cannot be
    /// encoded.
    pub fn ref(e: *Encoder, index: Index) Allocator.Error!?Ref {
        if (index == .none) return none_ref;
        const raw = @backingInt(index);
        if (raw < InternPool.static_len) return raw;
        const gop = try e.ids.getOrPut(e.gpa, index);
        if (gop.found_existing) return switch (gop.value_ptr.*) {
            failed => null,
            in_progress => {
                e.fallbacks.cycle += 1;
                return null;
            },
            else => |id| InternPool.static_len + id,
        };
        gop.value_ptr.* = in_progress;
        const ok = try e.item(index);
        const id: u32 = if (ok) @intCast(e.starts.items.len - 1) else failed;
        e.ids.getPtr(index).?.* = id;
        return if (ok) InternPool.static_len + id else null;
    }

    fn push(e: *Encoder, w: u32) !void {
        try e.scratch.append(e.gpa, w);
    }

    fn push64(e: *Encoder, v: u64) !void {
        try e.scratch.appendSlice(e.gpa, &.{ @truncate(v), @truncate(v >> 32) });
    }

    fn pushBytes(e: *Encoder, bytes: []const u8) !void {
        try e.push(@intCast(bytes.len));
        const n = (bytes.len + 3) / 4;
        try e.scratch.ensureUnusedCapacity(e.gpa, n);
        const at = e.scratch.items.len;
        e.scratch.items.len += n;
        const dest = std.mem.sliceAsBytes(e.scratch.items[at..][0..n]);
        @memcpy(dest[0..bytes.len], bytes);
        @memset(dest[bytes.len..], 0);
    }

    fn pushString(e: *Encoder, s: InternPool.String) !void {
        try e.pushBytes(e.zcu.ip.stringSlice(s));
    }

    /// Pushes `index`'s ref; false if it cannot be encoded.
    fn pushRef(e: *Encoder, index: Index) !bool {
        const r = try e.ref(index) orelse return false;
        try e.push(r);
        return true;
    }

    fn pushRefs(e: *Encoder, list: []const Index) !bool {
        try e.push(@intCast(list.len));
        for (list) |i| if (!try e.pushRef(i)) return false;
        return true;
    }

    /// A declaration: the type whose namespace holds it, and its name.
    fn pushNav(e: *Encoder, nav_index: InternPool.NavIndex) !bool {
        const nav = e.zcu.ip.getNav(nav_index);
        if (!try e.pushRef(e.zcu.namespacePtr(nav.namespace).owner_type)) return false;
        try e.pushString(nav.name);
        return true;
    }

    /// Encodes item `index` after its operands; false if it cannot be.
    fn item(e: *Encoder, index: Index) !bool {
        if (e.depth == max_depth) {
            e.fallbacks.too_deep += 1;
            return false;
        }
        e.depth += 1;
        defer e.depth -= 1;
        const ip = &e.zcu.ip;
        const base = e.scratch.items.len;
        defer e.scratch.shrinkRetainingCapacity(base);
        const key = ip.indexToKey(index);
        const h = ip.stableHash(index);
        try e.scratch.appendSlice(e.gpa, &@as([4]u32, @bitCast(h)));
        try e.push(@backingInt(std.meta.activeTag(key)));
        const ok = switch (key) {
            .int_type => |t| blk: {
                try e.push(@backingInt(t.signedness));
                try e.push(t.bits);
                break :blk true;
            },
            .ptr_type => |t| blk: {
                if (!try e.pushRef(t.child) or !try e.pushRef(t.sentinel)) break :blk false;
                try e.push(@bitCast(t.flags));
                try e.push(@bitCast(t.packed_offset));
                break :blk true;
            },
            .array_type => |t| blk: {
                try e.push64(t.len);
                break :blk try e.pushRef(t.child) and try e.pushRef(t.sentinel);
            },
            .vector_type => |t| blk: {
                try e.push(t.len);
                break :blk try e.pushRef(t.child);
            },
            .opt_type, .anyframe_type, .inferred_error_set_type, .undef, .runtime_capture => |i| try e.pushRef(i),
            .error_union_type => |t| try e.pushRef(t.error_set_type) and try e.pushRef(t.payload_type),
            .simple_type => |t| blk: {
                try e.push(@backingInt(t));
                break :blk true;
            },
            .struct_type, .enum_type, .union_type, .opaque_type => |c| try e.container(index, c),
            .tuple_type => |t| blk: {
                if (!try e.pushRefs(t.types) or !try e.pushRefs(t.values)) break :blk false;
                try e.push(@intCast(t.names.len));
                for (t.names) |n| try e.pushString(n);
                try e.pushString(t.site);
                try e.pushString(t.name);
                break :blk true;
            },
            .error_set_type => |names| blk: {
                try e.push(@intCast(names.len));
                for (names) |n| try e.pushString(n);
                break :blk true;
            },
            .func_type => |t| blk: {
                if (!try e.pushRefs(t.param_types) or !try e.pushRef(t.return_type)) break :blk false;
                try e.push(@as(u32, @backingInt(t.cc)) | @as(u32, @intFromBool(t.is_var_args)) << 8 | @as(u32, @intFromBool(t.is_generic)) << 9);
                try e.push(t.comptime_bits);
                try e.push(t.noalias_bits);
                break :blk true;
            },
            .simple_value => |v| blk: {
                try e.push(@backingInt(v));
                break :blk true;
            },
            .int => |int| blk: {
                if (!try e.pushRef(int.ty)) break :blk false;
                switch (int.storage) {
                    .u64 => |v| {
                        try e.push(0);
                        try e.push64(v);
                    },
                    .i64 => |v| {
                        try e.push(1);
                        try e.push64(@bitCast(v));
                    },
                    .big => |big| {
                        try e.push(2);
                        try e.push(@intFromBool(big.positive));
                        try e.push(@intCast(big.limbs.len));
                        for (big.limbs) |l| try e.push64(l);
                    },
                }
                break :blk true;
            },
            .float => |f| blk: {
                if (!try e.pushRef(f.ty)) break :blk false;
                try e.push(@backingInt(std.meta.activeTag(f.storage)));
                try e.scratch.appendSlice(e.gpa, &@as([4]u32, @bitCast(f.bits())));
                break :blk true;
            },
            .err => |x| blk: {
                if (!try e.pushRef(x.ty)) break :blk false;
                try e.pushString(x.name);
                break :blk true;
            },
            .error_union => |x| blk: {
                if (!try e.pushRef(x.ty)) break :blk false;
                switch (x.val) {
                    .err_name => |n| {
                        try e.push(0);
                        try e.pushString(n);
                    },
                    .payload => |p| {
                        try e.push(1);
                        if (!try e.pushRef(p)) break :blk false;
                    },
                }
                break :blk true;
            },
            .enum_literal => |s| blk: {
                try e.pushString(s);
                break :blk true;
            },
            .enum_tag => |x| try e.pushRef(x.ty) and try e.pushRef(x.int),
            .un => |x| try e.pushRef(x.ty) and try e.pushRef(x.tag) and try e.pushRef(x.val),
            .ptr => |p| blk: {
                if (p.base == .comptime_alloc) {
                    e.fallbacks.comptime_alloc += 1;
                    break :blk false;
                }
                if (!try e.pushRef(p.ty)) break :blk false;
                try e.push64(p.byte_offset);
                try e.push(@backingInt(std.meta.activeTag(p.base)));
                switch (p.base) {
                    .nav => |n| if (!try e.pushNav(n)) break :blk false,
                    .uav => |u| if (!try e.pushRef(u.val) or !try e.pushRef(u.orig_ty)) break :blk false,
                    .comptime_alloc => unreachable,
                    .int => {},
                    inline .field, .elem => |f| {
                        if (!try e.pushRef(f.base)) break :blk false;
                        try e.push64(f.index);
                    },
                }
                break :blk true;
            },
            .slice => |s| try e.pushRef(s.ty) and try e.pushRef(s.ptr) and try e.pushRef(s.len),
            .opt => |o| try e.pushRef(o.ty) and try e.pushRef(o.val),
            .aggregate => |a| blk: {
                if (!try e.pushRef(a.ty)) break :blk false;
                try e.push(@backingInt(std.meta.activeTag(a.storage)));
                switch (a.storage) {
                    .elems => |elems| if (!try e.pushRefs(elems)) break :blk false,
                    .bytes => |s| try e.pushString(s),
                    .repeated_elem => |r| if (!try e.pushRef(r)) break :blk false,
                }
                break :blk true;
            },
            .func => |f| blk: {
                if (!try e.pushNav(f.owner_nav) or !try e.pushRef(f.ty)) break :blk false;
                try e.push(@backingInt(f.zir_inst));
                break :blk try e.pushRef(f.generic_owner) and try e.pushRefs(f.comptime_args);
            },
            .extern_func => |f| blk: {
                try e.pushString(f.name);
                if (!try e.pushRef(f.ty)) break :blk false;
                try e.push(@intFromBool(f.is_weak));
                break :blk true;
            },
            .calling_convention => |cc| blk: {
                try e.push(@backingInt(cc));
                break :blk true;
            },
            .nav_capture => |c| blk: {
                if (!try e.pushNav(c.nav)) break :blk false;
                try e.push(@intFromBool(c.by_ref));
                break :blk true;
            },
        };
        if (!ok) return false;
        try e.starts.append(e.gpa, @intCast(e.words.items.len));
        try e.words.appendSlice(e.gpa, e.scratch.items[base..]);
        return true;
    }

    /// A declared container type: (file, instruction, reified layout,
    /// parent namespace's type, captures, display name, stable key).
    fn container(e: *Encoder, index: Index, c: InternPool.ContainerType) !bool {
        const ip = &e.zcu.ip;
        const info = ip.structInfo(index);
        const zir = &e.zcu.file(c.file).zir;
        const reified = zir.instructions.items(.tag)[@backingInt(c.zir_inst)] == .extended and
            switch (zir.instructions.items(.data)[@backingInt(c.zir_inst)].extended.opcode) {
                .reify_struct, .reify_union, .reify_enum => true,
                else => false,
            };
        try e.push(c.file);
        try e.push(@backingInt(c.zir_inst));
        try e.push(@as(u32, @intFromBool(reified)) | @as(u32, @backingInt(info.layout)) << 1);
        const parent = e.zcu.namespacePtr(info.namespace).parent;
        if (!try e.pushRef(if (parent == Zcu.Namespace.none) .none else e.zcu.namespacePtr(parent).owner_type)) return false;
        if (!try e.pushRefs(c.captures)) return false;
        try e.pushString(c.name);
        try e.pushString(c.key);
        return true;
    }
};

/// What a decoder needs from the run it loads into: the items that name
/// source. `Lookup` finds existing ones; replay's resolver creates them.
pub const Lookup = struct {
    zcu: *Zcu,

    pub fn container(l: Lookup, kind: KeyTag, c: Container) !?Index {
        const ip = &l.zcu.ip;
        const ct: InternPool.ContainerType = .{
            .file = c.file,
            .zir_inst = c.zir_inst,
            .captures = c.captures,
            .name = try ip.getString(Zcu.tid, c.name),
            .key = try ip.getString(Zcu.tid, c.key),
            .info = undefined,
        };
        return ip.find(switch (kind) {
            .struct_type => .{ .struct_type = ct },
            .enum_type => .{ .enum_type = ct },
            .union_type => .{ .union_type = ct },
            .opaque_type => .{ .opaque_type = ct },
            else => unreachable,
        });
    }

    pub fn nav(l: Lookup, owner_type: Index, name: []const u8) !?InternPool.NavIndex {
        const ip = &l.zcu.ip;
        _ = ip.containerType(owner_type) orelse return null;
        const ns_index = ip.structInfo(owner_type).namespace;
        if (ns_index == Zcu.Namespace.none) return null;
        const s = try ip.getString(Zcu.tid, name);
        if (l.zcu.namespacePtr(ns_index).decls.get(s)) |n| return n;
        // Tests are not in `decls`.
        for (l.zcu.test_functions.items) |n| {
            const t = ip.getNav(n);
            if (t.namespace == ns_index and t.name == s) return n;
        }
        return null;
    }

    pub fn func(l: Lookup, f: InternPool.Func) !?Index {
        return l.zcu.ip.find(.{ .func = f });
    }

    /// Lookups intern nothing new but strings.
    pub fn intern(l: Lookup, key: InternPool.Key) !?Index {
        return l.zcu.ip.find(key);
    }
};

/// A container type's locator, as decoded.
pub const Container = struct {
    file: u32,
    zir_inst: Zir.Inst.Index,
    reified_layout: ?std.lang.Type.ContainerLayout,
    /// `.none` for a file's root type.
    parent: Index,
    captures: []const Index,
    name: []const u8,
    key: []const u8,
};

/// Why a decode failed, for `ZAP_CACHE_CHECK`.
pub const Miss = struct {
    id: u32 = 0,
    tag: KeyTag = .int_type,
    reason: enum { none, unresolved, hash } = .none,
};

/// Decodes refs of an item table into InternPool indices, memoized per
/// item. `Resolver` provides the items that name source and interns the
/// rest (see `Lookup`). `rebuild` decodes every item from its key even if
/// the run has an item with its hash (the round-trip check); otherwise
/// such an item is taken as it is.
pub fn Decoder(comptime Resolver: type) type {
    return struct {
        const D = @This();

        gpa: Allocator,
        ip: *InternPool,
        words: []const u32,
        starts: []const u32,
        resolver: Resolver,
        rebuild: bool = false,
        /// Per item: its index + 1, or 0 if not decoded yet.
        decoded: []u32,
        scratch: std.ArrayList(Index) = .empty,
        bytes: std.ArrayList(u8) = .empty,
        limbs: std.ArrayList(std.math.big.Limb) = .empty,
        miss: Miss = .{},

        pub fn init(gpa: Allocator, ip: *InternPool, words: []const u32, starts: []const u32, resolver: Resolver) !D {
            const decoded = try gpa.alloc(u32, starts.len);
            @memset(decoded, 0);
            return .{ .gpa = gpa, .ip = ip, .words = words, .starts = starts, .resolver = resolver, .decoded = decoded };
        }

        pub fn deinit(d: *D) void {
            d.gpa.free(d.decoded);
            d.scratch.deinit(d.gpa);
            d.bytes.deinit(d.gpa);
            d.limbs.deinit(d.gpa);
        }

        /// The index `r` refers to, or null (`miss` says why).
        pub fn index(d: *D, r: Ref) anyerror!?Index {
            if (r == none_ref) return .none;
            if (r < InternPool.static_len) return @fromBackingInt(r);
            const id = r - InternPool.static_len;
            if (d.decoded[id] != 0) return @fromBackingInt(d.decoded[id] - 1);
            const at = d.starts[id];
            const h: Hash = @bitCast(d.words[at..][0..4].*);
            if (!d.rebuild) if (try d.ip.indexOfHash(h)) |i| {
                d.decoded[id] = @backingInt(i) + 1;
                return i;
            };
            var c: Cursor = .{ .words = d.words, .at = at + 5 };
            const tag: KeyTag = @fromBackingInt(@intCast(d.words[at + 4]));
            const i = try d.item(tag, &c) orelse {
                if (d.miss.reason == .none) d.miss = .{ .id = id, .tag = tag, .reason = .unresolved };
                return null;
            };
            if (d.ip.stableHash(i) != h or (d.rebuild and try d.ip.indexOfHash(h) != i)) {
                d.miss = .{ .id = id, .tag = tag, .reason = .hash };
                return null;
            }
            d.decoded[id] = @backingInt(i) + 1;
            return i;
        }

        fn ref(d: *D, c: *Cursor) !?Index {
            return d.index(c.next());
        }

        fn string(d: *D, c: *Cursor) !InternPool.String {
            return d.ip.getString(Zcu.tid, c.bytes());
        }

        /// Decodes a counted list of refs onto `scratch`; returns its start.
        fn refs(d: *D, c: *Cursor) !?usize {
            const n = c.next();
            const start = d.scratch.items.len;
            for (0..n) |_| {
                const i = try d.ref(c) orelse return null;
                try d.scratch.append(d.gpa, i);
            }
            return start;
        }

        fn nav(d: *D, c: *Cursor) !?InternPool.NavIndex {
            const owner = try d.ref(c) orelse return null;
            return d.resolver.nav(owner, c.bytes());
        }

        fn item(d: *D, tag: KeyTag, c: *Cursor) !?Index {
            const base = d.scratch.items.len;
            defer d.scratch.shrinkRetainingCapacity(base);
            const key: InternPool.Key = switch (tag) {
                .int_type => .{ .int_type = .{ .signedness = @fromBackingInt(@intCast(c.next())), .bits = @intCast(c.next()) } },
                .ptr_type => .{ .ptr_type = .{
                    .child = try d.ref(c) orelse return null,
                    .sentinel = try d.ref(c) orelse return null,
                    .flags = @bitCast(c.next()),
                    .packed_offset = @bitCast(c.next()),
                } },
                .array_type => blk: {
                    const len = c.next64();
                    break :blk .{ .array_type = .{ .len = len, .child = try d.ref(c) orelse return null, .sentinel = try d.ref(c) orelse return null } };
                },
                .vector_type => blk: {
                    const len = c.next();
                    break :blk .{ .vector_type = .{ .len = len, .child = try d.ref(c) orelse return null } };
                },
                .opt_type => .{ .opt_type = try d.ref(c) orelse return null },
                .anyframe_type => .{ .anyframe_type = try d.ref(c) orelse return null },
                .inferred_error_set_type => .{ .inferred_error_set_type = try d.ref(c) orelse return null },
                .undef => .{ .undef = try d.ref(c) orelse return null },
                .runtime_capture => .{ .runtime_capture = try d.ref(c) orelse return null },
                .error_union_type => .{ .error_union_type = .{
                    .error_set_type = try d.ref(c) orelse return null,
                    .payload_type = try d.ref(c) orelse return null,
                } },
                .simple_type => .{ .simple_type = @fromBackingInt(@intCast(c.next())) },
                .struct_type, .enum_type, .union_type, .opaque_type => {
                    const file = c.next();
                    const zir_inst: Zir.Inst.Index = @fromBackingInt(@intCast(c.next()));
                    const flags = c.next();
                    const parent = try d.ref(c) orelse return null;
                    const start = try d.refs(c) orelse return null;
                    const name = c.bytes();
                    const key = c.bytes();
                    return d.resolver.container(tag, .{
                        .file = file,
                        .zir_inst = zir_inst,
                        .reified_layout = if (flags & 1 != 0) @fromBackingInt(@intCast(flags >> 1)) else null,
                        .parent = parent,
                        .captures = d.scratch.items[start..],
                        .name = name,
                        .key = key,
                    });
                },
                .tuple_type => {
                    const types = try d.refs(c) orelse return null;
                    const values = try d.refs(c) orelse return null;
                    const names = try d.gpa.alloc(InternPool.String, c.next());
                    defer d.gpa.free(names);
                    for (names) |*n| n.* = try d.string(c);
                    const site = try d.string(c);
                    const name = try d.string(c);
                    return d.intern(.{ .tuple_type = .{
                        .types = d.scratch.items[types..values],
                        .values = d.scratch.items[values..],
                        .names = names,
                        .site = site,
                        .name = name,
                    } });
                },
                .error_set_type => {
                    const names = try d.gpa.alloc(InternPool.String, c.next());
                    defer d.gpa.free(names);
                    for (names) |*n| n.* = try d.string(c);
                    return d.intern(.{ .error_set_type = names });
                },
                .func_type => blk: {
                    const params = try d.refs(c) orelse return null;
                    const ret = try d.ref(c) orelse return null;
                    const flags = c.next();
                    break :blk .{ .func_type = .{
                        .param_types = d.scratch.items[params..],
                        .return_type = ret,
                        .cc = @fromBackingInt(@intCast(@as(u8, @truncate(flags)))),
                        .is_var_args = flags & 1 << 8 != 0,
                        .is_generic = flags & 1 << 9 != 0,
                        .comptime_bits = c.next(),
                        .noalias_bits = c.next(),
                    } };
                },
                .simple_value => .{ .simple_value = @fromBackingInt(@intCast(c.next())) },
                .int => blk: {
                    const ty = try d.ref(c) orelse return null;
                    break :blk .{ .int = .{ .ty = ty, .storage = switch (c.next()) {
                        0 => .{ .u64 = c.next64() },
                        1 => .{ .i64 = @bitCast(c.next64()) },
                        else => big: {
                            const positive = c.next() != 0;
                            d.limbs.clearRetainingCapacity();
                            for (0..c.next()) |_| try d.limbs.append(d.gpa, c.next64());
                            break :big .{ .big = .{ .limbs = d.limbs.items, .positive = positive } };
                        },
                    } } };
                },
                .float => blk: {
                    const ty = try d.ref(c) orelse return null;
                    const storage = c.next();
                    const bits: u128 = @bitCast(c.words[c.at..][0..4].*);
                    c.at += 4;
                    break :blk .{ .float = .{ .ty = ty, .storage = switch (storage) {
                        0 => .{ .f16 = @bitCast(@as(u16, @truncate(bits))) },
                        1 => .{ .f32 = @bitCast(@as(u32, @truncate(bits))) },
                        2 => .{ .f64 = @bitCast(@as(u64, @truncate(bits))) },
                        3 => .{ .f80 = @bitCast(@as(u80, @truncate(bits))) },
                        else => .{ .f128 = @bitCast(bits) },
                    } } };
                },
                .err => blk: {
                    const ty = try d.ref(c) orelse return null;
                    break :blk .{ .err = .{ .ty = ty, .name = try d.string(c) } };
                },
                .error_union => blk: {
                    const ty = try d.ref(c) orelse return null;
                    break :blk .{ .error_union = .{ .ty = ty, .val = if (c.next() == 0)
                        .{ .err_name = try d.string(c) }
                    else
                        .{ .payload = try d.ref(c) orelse return null } } };
                },
                .enum_literal => .{ .enum_literal = try d.string(c) },
                .enum_tag => .{ .enum_tag = .{ .ty = try d.ref(c) orelse return null, .int = try d.ref(c) orelse return null } },
                .un => .{ .un = .{
                    .ty = try d.ref(c) orelse return null,
                    .tag = try d.ref(c) orelse return null,
                    .val = try d.ref(c) orelse return null,
                } },
                .ptr => blk: {
                    const ty = try d.ref(c) orelse return null;
                    const byte_offset = c.next64();
                    const base_tag: std.meta.Tag(InternPool.Ptr.BaseAddr) = @fromBackingInt(@intCast(c.next()));
                    break :blk .{ .ptr = .{ .ty = ty, .byte_offset = byte_offset, .base = switch (base_tag) {
                        .nav => .{ .nav = try d.nav(c) orelse return null },
                        .uav => .{ .uav = .{ .val = try d.ref(c) orelse return null, .orig_ty = try d.ref(c) orelse return null } },
                        .comptime_alloc => unreachable,
                        .int => .int,
                        .field => .{ .field = .{ .base = try d.ref(c) orelse return null, .index = c.next64() } },
                        .elem => .{ .elem = .{ .base = try d.ref(c) orelse return null, .index = c.next64() } },
                    } } };
                },
                .slice => .{ .slice = .{
                    .ty = try d.ref(c) orelse return null,
                    .ptr = try d.ref(c) orelse return null,
                    .len = try d.ref(c) orelse return null,
                } },
                .opt => .{ .opt = .{ .ty = try d.ref(c) orelse return null, .val = try d.ref(c) orelse return null } },
                .aggregate => blk: {
                    const ty = try d.ref(c) orelse return null;
                    const storage_tag: std.meta.Tag(InternPool.Aggregate.Storage) = @fromBackingInt(@intCast(c.next()));
                    break :blk .{ .aggregate = .{ .ty = ty, .storage = switch (storage_tag) {
                        .elems => .{ .elems = d.scratch.items[try d.refs(c) orelse return null ..] },
                        .bytes => .{ .bytes = try d.string(c) },
                        .repeated_elem => .{ .repeated_elem = try d.ref(c) orelse return null },
                    } } };
                },
                .func => {
                    const owner_nav = try d.nav(c) orelse return null;
                    const ty = try d.ref(c) orelse return null;
                    const zir_inst: Zir.Inst.Index = @fromBackingInt(@intCast(c.next()));
                    const generic_owner = try d.ref(c) orelse return null;
                    const args = try d.refs(c) orelse return null;
                    return d.resolver.func(.{
                        .owner_nav = owner_nav,
                        .ty = ty,
                        .zir_inst = zir_inst,
                        .generic_owner = generic_owner,
                        .comptime_args = d.scratch.items[args..],
                    });
                },
                .extern_func => blk: {
                    const name = try d.string(c);
                    break :blk .{ .extern_func = .{ .name = name, .ty = try d.ref(c) orelse return null, .is_weak = c.next() != 0 } };
                },
                .calling_convention => .{ .calling_convention = @fromBackingInt(@intCast(@as(u8, @intCast(c.next())))) },
                .nav_capture => .{ .nav_capture = .{ .nav = try d.nav(c) orelse return null, .by_ref = c.next() != 0 } },
            };
            return d.intern(key);
        }

        fn intern(d: *D, key: InternPool.Key) !?Index {
            return d.resolver.intern(key);
        }
    };
}

/// Reads an item's or a result's words.
pub const Cursor = struct {
    words: []const u32,
    at: usize,

    pub fn next(c: *Cursor) u32 {
        defer c.at += 1;
        return c.words[c.at];
    }

    pub fn next64(c: *Cursor) u64 {
        const lo = c.next();
        return @as(u64, c.next()) << 32 | lo;
    }

    pub fn bytes(c: *Cursor) []const u8 {
        const len = c.next();
        const n = (len + 3) / 4;
        defer c.at += n;
        return std.mem.sliceAsBytes(c.words[c.at..][0..n])[0..len];
    }
};

// ---------------------------------------------------------------------------
// Results by unit kind. Each `encode*` appends a result's words to `out`
// and returns false, leaving `out` as it was, if some item cannot be
// encoded. Each `decode*` takes a `Decoder` and returns null if some item
// cannot be resolved.

fn finish(out: *std.ArrayList(u32), start: usize, ok: bool) bool {
    if (!ok) out.shrinkRetainingCapacity(start);
    return ok;
}

fn appendRef(e: *Encoder, out: *std.ArrayList(u32), index: Index) !bool {
    const r = try e.ref(index) orelse return false;
    try out.append(e.gpa, r);
    return true;
}

fn append64(gpa: Allocator, out: *std.ArrayList(u32), v: u64) !void {
    try out.appendSlice(gpa, &.{ @truncate(v), @truncate(v >> 32) });
}

fn appendBytes(gpa: Allocator, out: *std.ArrayList(u32), bytes: []const u8) !void {
    try out.append(gpa, @intCast(bytes.len));
    const n = (bytes.len + 3) / 4;
    const at = out.items.len;
    try out.appendNTimes(gpa, 0, n);
    @memcpy(std.mem.sliceAsBytes(out.items[at..][0..n])[0..bytes.len], bytes);
}

/// `nav_val`: the declaration's type, value, `const`, `threadlocal`,
/// linkage, and explicit alignment.
pub const NavResult = struct {
    ty: Index,
    val: Index,
    is_const: bool,
    is_threadlocal: bool,
    linkage: Zir.Inst.Declaration.Unwrapped.Linkage,
    alignment: u64,
};

pub fn encodeNav(e: *Encoder, out: *std.ArrayList(u32), nav: *const InternPool.Nav) !bool {
    const start = out.items.len;
    if (!try appendRef(e, out, nav.ty) or !try appendRef(e, out, nav.val)) return finish(out, start, false);
    try out.append(e.gpa, @as(u32, @intFromBool(nav.is_const)) | @as(u32, @intFromBool(nav.is_threadlocal)) << 1 | @as(u32, @backingInt(nav.linkage)) << 2);
    try append64(e.gpa, out, nav.alignment);
    return true;
}

pub fn decodeNav(d: anytype, words: []const u32) !?NavResult {
    var c: Cursor = .{ .words = words, .at = 0 };
    const ty = try d.index(c.next()) orelse return null;
    const val = try d.index(c.next()) orelse return null;
    const flags = c.next();
    return .{
        .ty = ty,
        .val = val,
        .is_const = flags & 1 != 0,
        .is_threadlocal = flags & 2 != 0,
        .linkage = @fromBackingInt(@intCast(@as(u8, @truncate(flags >> 2)))),
        .alignment = c.next64(),
    };
}

/// `type_layout`: the `ContainerInfo` fields that the layout produces. A
/// struct's non-`comptime` defaults are `.none` here; they are the
/// `struct_defaults` result.
pub fn encodeLayout(e: *Encoder, out: *std.ArrayList(u32), ty: Index) !bool {
    const ip = &e.zcu.ip;
    const gpa = e.gpa;
    const info = ip.structInfo(ty);
    const is_struct = ip.indexToKey(ty) == .struct_type;
    const start = out.items.len;
    try out.append(gpa, @as(u32, @backingInt(info.status)) | @as(u32, @backingInt(info.layout)) << 8 |
        @as(u32, @intFromBool(info.nonexhaustive)) << 10 | @as(u32, @intFromBool(info.has_runtime_tag)) << 11 |
        @as(u32, @backingInt(info.comptime_only)) << 12);
    try append64(gpa, out, info.size);
    try append64(gpa, out, info.alignment);
    if (!try appendRef(e, out, info.tag_type)) return finish(out, start, false);
    try out.append(gpa, @intCast(info.field_names.len));
    for (info.field_names) |n| try appendBytes(gpa, out, ip.stringSlice(n));
    try out.append(gpa, @intCast(info.field_types.len));
    for (info.field_types) |t| if (!try appendRef(e, out, t)) return finish(out, start, false);
    try out.append(gpa, @intCast(info.field_defaults.len));
    for (info.field_defaults, 0..) |v, i| {
        if (!try appendRef(e, out, if (!is_struct or info.fieldIsComptime(i)) v else .none)) return finish(out, start, false);
    }
    try out.append(gpa, @intCast(info.field_offsets.len));
    for (info.field_offsets) |o| try append64(gpa, out, o);
    try out.append(gpa, @intCast(info.field_is_comptime.len));
    for (info.field_is_comptime) |b| try out.append(gpa, @intFromBool(b));
    try out.append(gpa, @intCast(info.field_aligns.len));
    for (info.field_aligns) |a| try append64(gpa, out, a);
    return true;
}

/// The layout as a `ContainerInfo`, its slices allocated with `arena`;
/// `namespace` is not part of it.
pub fn decodeLayout(d: anytype, arena: Allocator, words: []const u32) !?InternPool.ContainerInfo {
    var c: Cursor = .{ .words = words, .at = 0 };
    const flags = c.next();
    var info: InternPool.ContainerInfo = .{
        .namespace = Zcu.Namespace.none,
        .status = @fromBackingInt(@intCast(@as(u8, @truncate(flags)))),
        .layout = @fromBackingInt(@intCast(@as(u2, @truncate(flags >> 8)))),
        .nonexhaustive = flags & 1 << 10 != 0,
        .has_runtime_tag = flags & 1 << 11 != 0,
        .comptime_only = @fromBackingInt(@intCast(@as(u2, @truncate(flags >> 12)))),
        .size = c.next64(),
        .alignment = c.next64(),
        .tag_type = try d.index(c.next()) orelse return null,
    };
    const names = try arena.alloc(InternPool.String, c.next());
    for (names) |*n| n.* = try d.ip.getString(Zcu.tid, c.bytes());
    info.field_names = names;
    const types = try arena.alloc(Index, c.next());
    for (types) |*t| t.* = try d.index(c.next()) orelse return null;
    info.field_types = types;
    const defaults = try arena.alloc(Index, c.next());
    for (defaults) |*v| v.* = try d.index(c.next()) orelse return null;
    info.field_defaults = defaults;
    const offsets = try arena.alloc(u64, c.next());
    for (offsets) |*o| o.* = c.next64();
    info.field_offsets = offsets;
    const is_comptime = try arena.alloc(bool, c.next());
    for (is_comptime) |*b| b.* = c.next() != 0;
    info.field_is_comptime = is_comptime;
    const aligns = try arena.alloc(u64, c.next());
    for (aligns) |*a| a.* = c.next64();
    info.field_aligns = aligns;
    return info;
}

/// `struct_defaults`: whether they were resolved, and each field's default
/// (`.none` for a `comptime` field, whose value is the layout's, or a
/// field without one).
pub const DefaultsResult = struct {
    resolved: bool,
    defaults: []const Index,
};

pub fn encodeDefaults(e: *Encoder, out: *std.ArrayList(u32), ty: Index) !bool {
    const info = e.zcu.ip.structInfo(ty);
    const start = out.items.len;
    try out.append(e.gpa, @intFromBool(info.defaults_status == .resolved));
    try out.append(e.gpa, @intCast(info.field_defaults.len));
    for (info.field_defaults, 0..) |v, i| {
        if (!try appendRef(e, out, if (info.fieldIsComptime(i)) .none else v)) return finish(out, start, false);
    }
    return true;
}

pub fn decodeDefaults(d: anytype, arena: Allocator, words: []const u32) !?DefaultsResult {
    var c: Cursor = .{ .words = words, .at = 0 };
    const resolved = c.next() != 0;
    const defaults = try arena.alloc(Index, c.next());
    for (defaults) |*v| v.* = try d.index(c.next()) orelse return null;
    return .{ .resolved = resolved, .defaults = defaults };
}

/// `func_ies`: whether the function's inferred error set is `anyerror`,
/// and its names in the order they were found.
pub const IesResult = struct {
    is_anyerror: bool,
    names: []const InternPool.String,
};

pub fn encodeIes(gpa: Allocator, zcu: *Zcu, out: *std.ArrayList(u32), func: Index) !void {
    try out.append(gpa, @intFromBool(zcu.anyerror_ies.contains(func)));
    const names = zcu.inferred_errors.get(func) orelse &.{};
    try out.append(gpa, @intCast(names.len));
    for (names) |n| try appendBytes(gpa, out, zcu.ip.stringSlice(n));
}

pub fn decodeIes(ip: *InternPool, arena: Allocator, words: []const u32) !IesResult {
    var c: Cursor = .{ .words = words, .at = 0 };
    const is_anyerror = c.next() != 0;
    const names = try arena.alloc(InternPool.String, c.next());
    for (names) |*n| n.* = try ip.getString(Zcu.tid, c.bytes());
    return .{ .is_anyerror = is_anyerror, .names = names };
}
