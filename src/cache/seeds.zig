//! The seeds of an edit build: the nodes of a manifest whose results an
//! edit to some inputs can change directly, found from the inputs' old and
//! new ZIR alone, before anything is analyzed. Everything else an edit can
//! change is reachable from them over reverse edges.
//!
//! A node's `Manifest.Source` names a ZIR instruction in the ZIR of its
//! input's recorded content. That ZIR is still in the frontend's cache
//! (named by the content hash; `Frontend.trimCaches` keeps a day of edits),
//! so the old instruction maps to the new ZIR as upstream maps them
//! (`mapOldZirToNew`: declarations by name, `comptime` blocks and unnamed
//! tests by order, the containers inside a declaration by order). Then:
//!
//! - a declaration, container, or `comptime` block whose instruction no
//!   longer maps, or whose `src_hash` changed, is a seed (its units:
//!   `nav_val`, `func`, `type_layout`, `struct_defaults`, `comptime_decl`,
//!   and `func_body`, whose result is that hash);
//! - a `namespace` node is a seed if its container's declaration names, or
//!   which of them are `pub`, changed (in order, as its result hashes
//!   them); a `namespace_name`
//!   node, if the name it looks up appeared, disappeared, or changed
//!   `pub`;
//! - an embedded file's node is a seed if the file changed;
//! - without the old ZIR, every node of the input is a seed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Zir = std.zig.Zir;
const Frontend = @import("../Frontend.zig");
const Manifest = @import("Manifest.zig");
const Tag = @import("../Incremental.zig").Tag;

/// An input whose content changed since the manifest was written.
pub const Changed = struct {
    /// Index into the manifest's inputs.
    input: u32,
    /// The file loaded from that input's path in this build, or null (an
    /// embedded file, or a file no longer imported).
    file: ?Frontend.File.Index,
};

pub const Stats = struct {
    /// Changed inputs whose old ZIR the cache no longer had.
    without_old_zir: u32 = 0,
};

pub const InstMap = std.AutoHashMapUnmanaged(Zir.Inst.Index, Zir.Inst.Index);

/// For each changed input, by input index: the map from the instructions
/// of its recorded ZIR to the new ZIR's (`mapOldZirToNew`), or null if
/// there is none (no old ZIR, or the file is no longer loaded). An edit
/// build resolves the instructions that cached results name with it.
pub const InstMaps = struct {
    maps: std.AutoHashMapUnmanaged(u32, ?InstMap) = .empty,

    pub fn deinit(im: *InstMaps, gpa: Allocator) void {
        var it = im.maps.valueIterator();
        while (it.next()) |m| if (m.*) |*map| map.deinit(gpa);
        im.maps.deinit(gpa);
    }
};

/// Appends the seeds of `changed` to `seeds`, in node order, and if `maps`
/// is not null, puts each changed input's map there.
pub fn compute(gpa: Allocator, m: *const Manifest, fe: *const Frontend, changed: []const Changed, seeds: *std.ArrayList(u32), maps: ?*InstMaps) !Stats {
    var stats: Stats = .{};
    const Ctx = struct {
        old: ?Frontend.OldZir = null,
        new: ?*const Zir = null,
        map: std.AutoHashMapUnmanaged(Zir.Inst.Index, Zir.Inst.Index) = .empty,
        names: NameIndex = .{},
    };
    const ctxs = try gpa.alloc(Ctx, changed.len);
    defer {
        for (ctxs) |*c| {
            if (c.old) |*o| o.deinit(fe);
            c.map.deinit(gpa);
            c.names.deinit(gpa);
        }
        gpa.free(ctxs);
    }
    var by_input: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer by_input.deinit(gpa);
    for (changed, ctxs, 0..) |c, *ctx, i| {
        ctx.* = .{};
        try by_input.put(gpa, c.input, @intCast(i));
        const file = c.file orelse continue;
        const in, _ = m.input(c.input);
        ctx.old = try fe.loadOldZir(file, @bitCast(in.content_hash));
        if (ctx.old == null) {
            stats.without_old_zir += 1;
            continue;
        }
        ctx.new = &fe.file(file).zir;
        try mapOldZirToNew(gpa, &ctx.old.?.zir, ctx.new.?, &ctx.map);
    }
    if (changed.len == 0) return stats;

    for (0..m.nodeCount()) |i_usize| {
        const i: u32 = @intCast(i_usize);
        const src = m.source(i);
        if (src.input == Manifest.Source.no_input) continue;
        const ctx = &ctxs[by_input.get(src.input) orelse continue];
        if (try isSeed(gpa, m, i, src, ctx.old, ctx.new, &ctx.map, &ctx.names)) try seeds.append(gpa, i);
    }
    if (maps) |out| for (changed, ctxs) |c, *ctx| {
        try out.maps.put(gpa, c.input, if (ctx.old != null and ctx.new != null) ctx.map else null);
        if (ctx.old != null and ctx.new != null) ctx.map = .empty;
    };
    return stats;
}

fn isSeed(
    gpa: Allocator,
    m: *const Manifest,
    i: u32,
    src: Manifest.Source,
    old_zir: ?Frontend.OldZir,
    new_zir: ?*const Zir,
    map: *const std.AutoHashMapUnmanaged(Zir.Inst.Index, Zir.Inst.Index),
    names: *NameIndex,
) !bool {
    const old = &(old_zir orelse return true).zir;
    const new = new_zir orelse return true;
    if (src.inst == Manifest.Source.no_inst or src.inst >= old.instructions.len) return true;
    const old_inst: Zir.Inst.Index = @fromBackingInt(src.inst);
    const new_inst = map.get(old_inst) orelse return true;
    const n = m.node(i);
    const tag = std.enums.fromInt(Tag, n.tag) orelse return true;
    switch (tag) {
        .nav_val, .type_layout, .struct_defaults, .func, .comptime_decl => return srcHash(new, new_inst) != n.src_hash,
        .func_body => return srcHash(new, new_inst) != n.result_hash,
        .namespace => {
            if (!isContainer(old, old_inst) or !isContainer(new, new_inst)) return true;
            const old_decls = old.typeDecls(old_inst);
            const new_decls = new.typeDecls(new_inst);
            var oi: usize = 0;
            var ni: usize = 0;
            while (true) {
                const o = nextNamed(old, old_decls, &oi);
                const w = nextNamed(new, new_decls, &ni);
                if (o == null or w == null) return (o == null) != (w == null);
                if (!std.mem.eql(u8, o.?.name, w.?.name) or o.?.is_pub != w.?.is_pub) return true;
            }
        },
        .namespace_name => {
            if (!isContainer(old, old_inst) or !isContainer(new, new_inst)) return true;
            const name = m.sourceName(i) orelse return true;
            const o = (try names.get(gpa, old, old_inst)).get(name);
            const w = (try names.get(gpa, new, new_inst)).get(name);
            if (o == null or w == null) return (o == null) != (w == null);
            return o.? != w.?;
        },
        .nav_ty, .func_ies, .func_inline, .content, .link, .embed_file => return true,
    }
}

fn srcHash(zir: *const Zir, inst: Zir.Inst.Index) u128 {
    return @bitCast(zir.getAssociatedSrcHash(inst) orelse return 0);
}

fn isContainer(zir: *const Zir, inst: Zir.Inst.Index) bool {
    if (zir.instructions.items(.tag)[@backingInt(inst)] != .extended) return false;
    return switch (zir.instructions.items(.data)[@backingInt(inst)].extended.opcode) {
        .struct_decl, .union_decl, .enum_decl, .opaque_decl => true,
        else => false,
    };
}

const Named = struct { name: []const u8, is_pub: bool };

/// The next `const` or `var` declaration in `decls` from `index`: the
/// declarations a namespace's names come from (`Zcu`'s scan).
fn nextNamed(zir: *const Zir, decls: []const Zir.Inst.Index, index: *usize) ?Named {
    while (index.* < decls.len) {
        defer index.* += 1;
        const d = zir.getDeclaration(decls[index.*]);
        switch (d.kind) {
            .@"const", .@"var" => return .{ .name = zir.nullTerminatedString(d.name), .is_pub = d.is_pub },
            else => {},
        }
    }
    return null;
}

/// Each container's `const` and `var` names, built on first use, so that
/// looking up the many `namespace_name` nodes of a container with many
/// declarations stays linear.
const NameIndex = struct {
    /// By ZIR (old or new) and container instruction: name to `is_pub`.
    by: std.AutoHashMapUnmanaged(struct { *const Zir, Zir.Inst.Index }, std.StringHashMapUnmanaged(bool)) = .empty,

    fn deinit(ni: *NameIndex, gpa: Allocator) void {
        var it = ni.by.valueIterator();
        while (it.next()) |v| v.deinit(gpa);
        ni.by.deinit(gpa);
    }

    fn get(ni: *NameIndex, gpa: Allocator, zir: *const Zir, container: Zir.Inst.Index) !*const std.StringHashMapUnmanaged(bool) {
        const gop = try ni.by.getOrPut(gpa, .{ zir, container });
        if (gop.found_existing) return gop.value_ptr;
        gop.value_ptr.* = .empty;
        errdefer {
            gop.value_ptr.deinit(gpa);
            _ = ni.by.remove(.{ zir, container });
        }
        const decls = zir.typeDecls(container);
        var i: usize = 0;
        while (nextNamed(zir, decls, &i)) |d| {
            const e = try gop.value_ptr.getOrPut(gpa, d.name);
            if (!e.found_existing) e.value_ptr.* = d.is_pub;
        }
        return gop.value_ptr;
    }
};

// Copied from upstream `src/Zcu.zig` (Copyright (c) Zig contributors, MIT;
// see upstream/LICENSE), unchanged but for this file's names.
fn mapOldZirToNew(
    gpa: Allocator,
    old_zir: *const Zir,
    new_zir: *const Zir,
    inst_map: *std.AutoHashMapUnmanaged(Zir.Inst.Index, Zir.Inst.Index),
) Allocator.Error!void {
    // Contain ZIR indexes of namespace declaration instructions, e.g. struct_decl, union_decl, etc.
    // Not `declaration`, as this does not create a namespace.
    const MatchedZirDecl = struct {
        old_inst: Zir.Inst.Index,
        new_inst: Zir.Inst.Index,
    };
    var pending_matched_type_decls: std.ArrayList(MatchedZirDecl) = .empty;
    defer pending_matched_type_decls.deinit(gpa);

    // Used as temporary buffers for namespace declaration instructions
    var old_contents: Zir.DeclContents = .init;
    defer old_contents.deinit(gpa);
    var new_contents: Zir.DeclContents = .init;
    defer new_contents.deinit(gpa);

    // Map the main struct inst to start off with.
    try pending_matched_type_decls.append(gpa, .{
        .old_inst = .main_struct_inst,
        .new_inst = .main_struct_inst,
    });

    while (pending_matched_type_decls.pop()) |match_item| {
        // There are some properties of type declarations which cannot change across incremental
        // updates. If they have, we need to ignore this mapping. These properties are essentially
        // everything passed into `InternPool.getDeclaredStructType` (likewise for unions, enums,
        // and opaques).
        const old_tag = old_zir.instructions.items(.data)[@backingInt(match_item.old_inst)].extended.opcode;
        const new_tag = new_zir.instructions.items(.data)[@backingInt(match_item.new_inst)].extended.opcode;
        if (old_tag != new_tag) continue;
        switch (old_tag) {
            .struct_decl => {
                const old = old_zir.getStructDecl(match_item.old_inst);
                const new = new_zir.getStructDecl(match_item.new_inst);
                if (old.captures.len != new.captures.len) continue;
                if (old.field_names.len != new.field_names.len) continue;
                if (old.layout != new.layout) continue;
                const old_any_field_aligns = old.field_align_body_lens != null;
                const old_any_field_defaults = old.field_default_body_lens != null;
                const old_any_comptime_fields = old.field_comptime_bits != null;
                const old_explicit_backing_int = old.backing_int_type_body != null;
                const new_any_field_aligns = new.field_align_body_lens != null;
                const new_any_field_defaults = new.field_default_body_lens != null;
                const new_any_comptime_fields = new.field_comptime_bits != null;
                const new_explicit_backing_int = new.backing_int_type_body != null;
                if (old_any_field_aligns != new_any_field_aligns) continue;
                if (old_any_field_defaults != new_any_field_defaults) continue;
                if (old_any_comptime_fields != new_any_comptime_fields) continue;
                if (old_explicit_backing_int != new_explicit_backing_int) continue;
            },
            .union_decl => {
                const old = old_zir.getUnionDecl(match_item.old_inst);
                const new = new_zir.getUnionDecl(match_item.new_inst);
                if (old.captures.len != new.captures.len) continue;
                if (old.field_names.len != new.field_names.len) continue;
                if (old.kind != new.kind) continue;
                const old_any_field_aligns = old.field_align_body_lens != null;
                const new_any_field_aligns = new.field_align_body_lens != null;
                if (old_any_field_aligns != new_any_field_aligns) continue;
            },
            .enum_decl => {
                const old = old_zir.getEnumDecl(match_item.old_inst);
                const new = new_zir.getEnumDecl(match_item.new_inst);
                if (old.captures.len != new.captures.len) continue;
                if (old.field_names.len != new.field_names.len) continue;
                if (old.nonexhaustive != new.nonexhaustive) continue;
                const old_explicit_tag_type = old.tag_type_body != null;
                const new_explicit_tag_type = new.tag_type_body != null;
                if (old_explicit_tag_type != new_explicit_tag_type) continue;
            },
            .opaque_decl => {
                const old = old_zir.getOpaqueDecl(match_item.old_inst);
                const new = new_zir.getOpaqueDecl(match_item.new_inst);
                if (old.captures.len != new.captures.len) continue;
            },
            else => unreachable,
        }

        // Match the container declaration itself
        try inst_map.put(gpa, match_item.old_inst, match_item.new_inst);

        {
            // First, map the fields...
            try old_zir.findTrackableFields(gpa, &old_contents, match_item.old_inst);
            try new_zir.findTrackableFields(gpa, &new_contents, match_item.new_inst);

            // This isn't a `.declaration`, so we shouldn't see a function declaration.
            std.debug.assert(old_contents.func_decl == null);
            std.debug.assert(new_contents.func_decl == null);

            // We don't have any smart way of matching up these instructions, so we correlate them based on source order
            // in their respective arrays.

            const num_type_decls = @min(old_contents.type_decls.items.len, new_contents.type_decls.items.len);
            try pending_matched_type_decls.ensureUnusedCapacity(gpa, @intCast(num_type_decls));
            for (
                old_contents.type_decls.items[0..num_type_decls],
                new_contents.type_decls.items[0..num_type_decls],
            ) |old_inst, new_inst| {
                pending_matched_type_decls.appendAssumeCapacity(.{ .old_inst = old_inst, .new_inst = new_inst });
            }

            const num_other = @min(old_contents.other.items.len, new_contents.other.items.len);
            try inst_map.ensureUnusedCapacity(gpa, @intCast(num_other));
            for (
                old_contents.other.items[0..num_other],
                new_contents.other.items[0..num_other],
            ) |old_inst_index, new_inst_index| {
                // These instructions don't have declarations, so we just modify `inst_map` directly.

                // But first: a mapping must not change an instruction's tag, so ignore any
                // candidates which would.
                const old_inst = old_zir.instructions.get(@backingInt(old_inst_index));
                const new_inst = new_zir.instructions.get(@backingInt(new_inst_index));
                if (old_inst.tag != new_inst.tag) {
                    continue;
                }
                if (old_inst.tag == .extended and
                    old_inst.data.extended.opcode != new_inst.data.extended.opcode)
                {
                    continue;
                }

                inst_map.putAssumeCapacity(old_inst_index, new_inst_index);
            }
        }

        // Maps decl name to `declaration` instruction.
        var named_decls: std.StringHashMapUnmanaged(Zir.Inst.Index) = .empty;
        defer named_decls.deinit(gpa);
        // Maps test name to `declaration` instruction.
        var named_tests: std.StringHashMapUnmanaged(Zir.Inst.Index) = .empty;
        defer named_tests.deinit(gpa);
        // Maps test name to `declaration` instruction.
        var named_decltests: std.StringHashMapUnmanaged(Zir.Inst.Index) = .empty;
        defer named_decltests.deinit(gpa);
        // All unnamed tests, in order, for a best-effort match.
        var unnamed_tests: std.ArrayList(Zir.Inst.Index) = .empty;
        defer unnamed_tests.deinit(gpa);
        // All comptime declarations, in order, for a best-effort match.
        var comptime_decls: std.ArrayList(Zir.Inst.Index) = .empty;
        defer comptime_decls.deinit(gpa);

        for (old_zir.typeDecls(match_item.old_inst)) |old_decl_inst| {
            const old_decl = old_zir.getDeclaration(old_decl_inst);
            switch (old_decl.kind) {
                .@"comptime" => try comptime_decls.append(gpa, old_decl_inst),
                .unnamed_test => try unnamed_tests.append(gpa, old_decl_inst),
                .@"test" => try named_tests.put(gpa, old_zir.nullTerminatedString(old_decl.name), old_decl_inst),
                .decltest => try named_decltests.put(gpa, old_zir.nullTerminatedString(old_decl.name), old_decl_inst),
                .@"const", .@"var" => try named_decls.put(gpa, old_zir.nullTerminatedString(old_decl.name), old_decl_inst),
            }
        }

        var unnamed_test_idx: u32 = 0;
        var comptime_decl_idx: u32 = 0;

        for (new_zir.typeDecls(match_item.new_inst)) |new_decl_inst| {
            const new_decl = new_zir.getDeclaration(new_decl_inst);
            // Attempt to match this to a declaration in the old ZIR:
            // * For named declarations (`const`/`var`/`fn`), we match based on name.
            // * For named tests (`test "foo"`) and decltests (`test foo`), we also match based on name.
            // * For unnamed tests, we match based on order.
            // * For comptime blocks, we match based on order.
            // If we cannot match this declaration, we can't match anything nested inside of it either, so we just `continue`.
            const old_decl_inst = switch (new_decl.kind) {
                .@"comptime" => inst: {
                    if (comptime_decl_idx == comptime_decls.items.len) continue;
                    defer comptime_decl_idx += 1;
                    break :inst comptime_decls.items[comptime_decl_idx];
                },
                .unnamed_test => inst: {
                    if (unnamed_test_idx == unnamed_tests.items.len) continue;
                    defer unnamed_test_idx += 1;
                    break :inst unnamed_tests.items[unnamed_test_idx];
                },
                .@"test" => inst: {
                    const name = new_zir.nullTerminatedString(new_decl.name);
                    break :inst named_tests.get(name) orelse continue;
                },
                .decltest => inst: {
                    const name = new_zir.nullTerminatedString(new_decl.name);
                    break :inst named_decltests.get(name) orelse continue;
                },
                .@"const", .@"var" => inst: {
                    const name = new_zir.nullTerminatedString(new_decl.name);
                    break :inst named_decls.get(name) orelse continue;
                },
            };

            // Match the `declaration` instruction
            try inst_map.put(gpa, old_decl_inst, new_decl_inst);

            // Find trackable instructions within this declaration
            try old_zir.findTrackable(gpa, &old_contents, old_decl_inst);
            try new_zir.findTrackable(gpa, &new_contents, new_decl_inst);

            // We don't have any smart way of matching up these instructions, so we correlate them based on source order
            // in their respective arrays.

            const num_type_decls = @min(old_contents.type_decls.items.len, new_contents.type_decls.items.len);
            try pending_matched_type_decls.ensureUnusedCapacity(gpa, @intCast(num_type_decls));
            for (
                old_contents.type_decls.items[0..num_type_decls],
                new_contents.type_decls.items[0..num_type_decls],
            ) |old_inst, new_inst| {
                pending_matched_type_decls.appendAssumeCapacity(.{ .old_inst = old_inst, .new_inst = new_inst });
            }

            const num_other = @min(old_contents.other.items.len, new_contents.other.items.len);
            try inst_map.ensureUnusedCapacity(gpa, @intCast(num_other));
            for (
                old_contents.other.items[0..num_other],
                new_contents.other.items[0..num_other],
            ) |old_inst_index, new_inst_index| {
                // These instructions don't have declarations, so we just modify `inst_map` directly.

                // But first: a mapping must not change an instruction's tag, so ignore any
                // candidates which would.
                const old_inst = old_zir.instructions.get(@backingInt(old_inst_index));
                const new_inst = new_zir.instructions.get(@backingInt(new_inst_index));
                if (old_inst.tag != new_inst.tag) {
                    continue;
                }
                if (old_inst.tag == .extended and
                    old_inst.data.extended.opcode != new_inst.data.extended.opcode)
                {
                    continue;
                }

                inst_map.putAssumeCapacity(old_inst_index, new_inst_index);
            }

            if (old_contents.func_decl) |old_func_inst| {
                if (new_contents.func_decl) |new_func_inst| {
                    // There are no declarations on a function either, so again, we just directly add it to `inst_map`.
                    try inst_map.put(gpa, old_func_inst, new_func_inst);
                }
            }
        }
    }
}
