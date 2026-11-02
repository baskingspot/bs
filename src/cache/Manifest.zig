//! One compilation's state after its last build: the units and other
//! dependees with their result hashes, the units' own source hashes,
//! forward and reverse dependency edges, the Atoms each unit produced (as
//! references into the `Pack`), the input files' stats, and the error-code
//! assignment.
//!
//! It is two files. `manifest` is the base: mapped, pointer-free, written
//! whole by `Builder` and atomically replaced. `manifest.log` holds the
//! changes of the builds since, one record per build, appended by `Delta`;
//! `open` reads it into a small in-memory overlay. Rewriting a 9 MB base
//! cost about 25 ms on the orb, more than relinking; appending a record
//! costs tens of microseconds. When the log grows past a quarter of the
//! base (`shouldFold`), the next build writes a new base instead.
//!
//! A rebuild maps the manifest and stats the inputs (`changedInputs`); with
//! no change that is the whole cost, because nothing in the base is touched
//! but its header and the input records. After an edit it compares changed
//! declarations' `src_hash`es with their nodes and walks reverse edges from
//! those alone (`rdeps`). Reverse edges are a superset: when a log record
//! replaces a node's dependencies, the base's reverse edges from its old
//! dependencies stay until the next base, so a walk may visit a unit that no
//! longer depends on the changed node. Visiting it only re-checks it.
//!
//! The store does not interpret nodes: a node is anything a unit can depend
//! on (a declaration's value or type, a type's layout, a function body or
//! inferred error set, a namespace name lookup, an error code), keyed by a
//! 128-bit stable hash, with an opaque `tag` for Sema. Units are the nodes
//! that have dependencies, a source hash, or Atoms. A node keeps its index
//! and key for as long as the base lasts.
//!
//! Base file: `Header`, then each section at a 16-byte aligned offset.
//! Log file: `LogHeader`, then records (`RecordHeader` and its body), each
//! checksummed; a torn record at the end is ignored and overwritten.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cache = @import("../cache.zig");
const Pack = @import("Pack.zig");
const Hash = cache.Hash;

const Manifest = @This();

map: Io.File.MemoryMap,
/// Random, new for each base; a log applies only to the base it names.
id: Hash,
/// The pack whose offsets the atom references hold.
pack_id: Hash,
nodes: []const Node,
/// Open-addressing table from `Node.key` to node index + 1 (0: empty),
/// a power of two long, at most half full.
table: []const u32,
/// Node indices: each node's dependencies at `deps_start`, its dependents
/// in `redges` at `rdeps_start`.
edges: []const u32,
redges: []const u32,
atom_refs: []const Pack.AtomRef,
inputs: []const Input,
/// Error names in code order: the error with code `c` is `c - 1`.
error_names: []const StrRef,
strings: []const u8,
overlay: Overlay,

pub const Node = extern struct {
    key: Hash,
    result_hash: Hash,
    /// A unit's own source hash (its declaration's `src_hash`), else 0.
    src_hash: Hash,
    deps_start: u32,
    deps_len: u32,
    rdeps_start: u32,
    rdeps_len: u32,
    atoms_start: u32,
    atoms_len: u32,
    /// Opaque to the store.
    tag: u8,
    unused: [7]u8 = @splat(0),
};

pub const StrRef = extern struct { off: u32, len: u32 };

pub const Input = extern struct {
    content_hash: Hash,
    inode: u64,
    size: u64,
    /// Nanoseconds, or `racy_mtime` (see `Builder.addInput`).
    mtime: i64,
    path: StrRef,

    pub const racy_mtime = std.math.minInt(i64);

    pub fn matches(in: Input, stat: Io.File.Stat) bool {
        return in.mtime != racy_mtime and in.inode == stat.inode and in.size == stat.size and
            in.mtime == stat.mtime.toNanoseconds();
    }

    fn init(stat: Io.File.Stat, content_hash: Hash, build_start: Io.Timestamp, path: StrRef) Input {
        // A file modified within 2 s of the build's start could change again
        // within the timestamp granularity without changing its stat, so it
        // is recorded to be rehashed next time.
        const mtime: i64 = @intCast(stat.mtime.toNanoseconds());
        const racy = mtime >= build_start.toNanoseconds() - 2 * std.time.ns_per_s;
        return .{
            .content_hash = content_hash,
            .inode = @intCast(stat.inode),
            .size = stat.size,
            .mtime = if (racy) racy_mtime else mtime,
            .path = path,
        };
    }
};

const Section = enum { nodes, table, edges, redges, atom_refs, inputs, error_names, strings };
const SectionRange = extern struct { offset: u64, len: u64 };

const magic = "ZAPMAN02".*;
const log_magic = "ZAPMLG01".*;
const record_magic: u32 = 0x5a524543;
const log_name = "manifest.log";

const Header = extern struct {
    magic: [8]u8 = magic,
    unused: [8]u8 = @splat(0),
    id: Hash,
    pack_id: Hash,
    sections: [std.enums.values(Section).len]SectionRange,
};

const LogHeader = extern struct {
    magic: [8]u8 = log_magic,
    unused: [8]u8 = @splat(0),
    base_id: Hash,
};

/// One build's changes. The body: `n_nodes` node changes (each a
/// `NodeDelta`, then its dependencies and atom references, each padded to
/// 16 bytes), `n_inputs` `InputDelta`s, `n_errors` `StrRef`s (padded), and
/// `strings_len` string bytes (padded) that the inputs and errors refer to.
const RecordHeader = extern struct {
    magic: u32 = record_magic,
    /// Of the whole record, a multiple of 16.
    len: u32,
    /// Wyhash of the body.
    hash: u64,
    n_nodes: u32,
    n_inputs: u32,
    n_errors: u32,
    strings_len: u32,
};

/// A node's new state. `index` is an existing node, or the next new one.
const NodeDelta = extern struct {
    key: Hash,
    result_hash: Hash,
    src_hash: Hash,
    index: u32,
    deps_len: u32,
    atoms_len: u32,
    tag: u8,
    unused: [3]u8 = @splat(0),
};

/// An input's new stat. `index` is an existing input, or the next new one.
const InputDelta = extern struct {
    input: Input,
    index: u32,
    unused: [12]u8 = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(Node) == 80);
    std.debug.assert(@sizeOf(Input) == 48);
    std.debug.assert(@sizeOf(RecordHeader) == 32);
    std.debug.assert(@sizeOf(NodeDelta) == 64);
    std.debug.assert(@sizeOf(InputDelta) == 64);
}

/// The log, applied. Slices point into `buf`.
const Overlay = struct {
    buf: []align(16) u8 = &.{},
    /// Length of the log's valid prefix; 0 if there is no log for this base.
    len: u64 = 0,
    /// Each changed or added node's latest state.
    nodes: std.AutoHashMapUnmanaged(u32, NodeState) = .empty,
    added_nodes: u32 = 0,
    added_keys: std.AutoHashMapUnmanaged(Hash, u32) = .empty,
    /// Reverse edges of dependencies set in the log.
    rdeps: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty,
    inputs: std.AutoHashMapUnmanaged(u32, InputState) = .empty,
    added_inputs: u32 = 0,
    error_names: std.ArrayList([]const u8) = .empty,
    /// Every live atom reference in node order, built on first use when
    /// nodes changed.
    all_refs: ?[]Pack.AtomRef = null,

    const NodeState = struct {
        delta: *const NodeDelta,
        deps: []const u32,
        atoms: []const Pack.AtomRef,
    };
    const InputState = struct { input: Input, path: []const u8 };

    fn deinit(o: *Overlay, gpa: Allocator) void {
        gpa.free(o.buf);
        o.nodes.deinit(gpa);
        o.added_keys.deinit(gpa);
        var it = o.rdeps.valueIterator();
        while (it.next()) |l| l.deinit(gpa);
        o.rdeps.deinit(gpa);
        o.inputs.deinit(gpa);
        o.error_names.deinit(gpa);
        if (o.all_refs) |r| gpa.free(r);
    }
};

fn SectionType(comptime s: Section) type {
    return switch (s) {
        .nodes => Node,
        .table, .edges, .redges => u32,
        .atom_refs => Pack.AtomRef,
        .inputs => Input,
        .error_names => StrRef,
        .strings => u8,
    };
}

/// Maps the manifest in `dir` and applies its log, or returns null if
/// there is none or it is not one this zap wrote.
pub fn open(gpa: Allocator, io: Io, dir: Io.Dir) !?Manifest {
    var map = try cache.mapFile(io, dir, "manifest") orelse return null;
    errdefer map.destroy(io);
    const bytes = map.memory;
    if (bytes.len < @sizeOf(Header)) return corrupt(io, &map);
    const h: *const Header = @ptrCast(bytes.ptr);
    if (!std.mem.eql(u8, &h.magic, &magic)) return corrupt(io, &map);
    var m: Manifest = undefined;
    m.map = map;
    m.id = h.id;
    m.pack_id = h.pack_id;
    m.overlay = .{};
    inline for (comptime std.enums.values(Section)) |s| {
        const T = SectionType(s);
        const r = h.sections[@backingInt(s)];
        if (r.offset % 16 != 0 or r.offset > bytes.len or r.len > (bytes.len - r.offset) / @sizeOf(T))
            return corrupt(io, &map);
        @field(m, @tagName(s)) = @as([*]const T, @ptrCast(@alignCast(bytes.ptr + r.offset)))[0..r.len];
    }
    if (m.table.len == 0 or !std.math.isPowerOfTwo(m.table.len)) return corrupt(io, &map);
    errdefer m.overlay.deinit(gpa);
    try m.readLog(gpa, io, dir);
    return m;
}

fn corrupt(io: Io, map: *Io.File.MemoryMap) ?Manifest {
    map.destroy(io);
    return null;
}

pub fn close(m: *Manifest, gpa: Allocator, io: Io) void {
    m.overlay.deinit(gpa);
    m.map.destroy(io);
}

fn readLog(m: *Manifest, gpa: Allocator, io: Io, dir: Io.Dir) !void {
    const f = dir.openFile(io, log_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer f.close(io);
    const len = try f.length(io);
    if (len < @sizeOf(LogHeader)) return;
    const o = &m.overlay;
    o.buf = try gpa.alignedAlloc(u8, .@"16", len);
    if (try f.readPositionalAll(io, o.buf, 0) != len) return;
    const lh: *const LogHeader = @ptrCast(o.buf.ptr);
    if (!std.mem.eql(u8, &lh.magic, &log_magic) or lh.base_id != m.id) return;
    var off: usize = @sizeOf(LogHeader);
    while (try m.applyRecord(gpa, @alignCast(o.buf[off..]))) |rec_len| off += rec_len;
    o.len = off;
}

/// Applies the record at the start of `rest`, or returns null if there is
/// no complete, intact one.
fn applyRecord(m: *Manifest, gpa: Allocator, rest: []align(16) const u8) !?usize {
    if (rest.len < @sizeOf(RecordHeader)) return null;
    const rh: *const RecordHeader = @ptrCast(rest.ptr);
    if (rh.magic != record_magic or rh.len % 16 != 0 or rh.len < @sizeOf(RecordHeader) or rh.len > rest.len) return null;
    const body = rest[@sizeOf(RecordHeader)..rh.len];
    if (std.hash.Wyhash.hash(0, body) != rh.hash) return null;
    // The checksum covers the body, so lengths inside it are trusted from
    // here on, as in the base.
    const o = &m.overlay;
    var r: Reader = .{ .bytes = @alignCast(body) };
    for (0..rh.n_nodes) |_| {
        const d = r.take(NodeDelta, 1);
        const node_deps = r.take(u32, d[0].deps_len);
        const node_atoms = r.take(Pack.AtomRef, d[0].atoms_len);
        const index = d[0].index;
        if (index == m.nodeCount()) {
            o.added_nodes += 1;
            try o.added_keys.put(gpa, d[0].key, index);
        }
        try o.nodes.put(gpa, index, .{ .delta = &d[0], .deps = node_deps, .atoms = node_atoms });
        for (node_deps) |dep| {
            const gop = try o.rdeps.getOrPut(gpa, dep);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(gpa, index);
        }
    }
    const input_deltas = r.take(InputDelta, rh.n_inputs);
    const errors = r.take(StrRef, rh.n_errors);
    const strings = r.take(u8, rh.strings_len);
    for (input_deltas) |*d| {
        if (d.index == m.inputCount()) o.added_inputs += 1;
        try o.inputs.put(gpa, d.index, .{ .input = d.input, .path = strings[d.input.path.off..][0..d.input.path.len] });
    }
    for (errors) |e| try o.error_names.append(gpa, strings[e.off..][0..e.len]);
    return rh.len;
}

const Reader = struct {
    bytes: []align(16) const u8,
    off: usize = 0,

    fn take(r: *Reader, comptime T: type, n: usize) []const T {
        const s: []const T = @ptrCast(@alignCast(r.bytes[r.off..][0 .. n * @sizeOf(T)]));
        r.off = std.mem.alignForward(usize, r.off + n * @sizeOf(T), 16);
        return s;
    }
};

pub fn nodeCount(m: *const Manifest) u32 {
    return @intCast(m.nodes.len + m.overlay.added_nodes);
}

pub fn find(m: *const Manifest, key: Hash) ?u32 {
    if (findIn(m.nodes, m.table, key)) |i| return i;
    return m.overlay.added_keys.get(key);
}

fn findIn(nodes: []const Node, table: []const u32, key: Hash) ?u32 {
    const mask = table.len - 1;
    var i: usize = @as(usize, @truncate(key)) & mask;
    while (true) : (i = (i + 1) & mask) {
        const v = table[i];
        if (v == 0) return null;
        if (nodes[v - 1].key == key) return v - 1;
    }
}

/// A node's key, result, source hash, and tag.
pub const NodeInfo = struct { key: Hash, result_hash: Hash, src_hash: Hash, tag: u8 };

pub fn node(m: *const Manifest, index: u32) NodeInfo {
    if (m.overlay.nodes.get(index)) |s| return .{ .key = s.delta.key, .result_hash = s.delta.result_hash, .src_hash = s.delta.src_hash, .tag = s.delta.tag };
    const n = &m.nodes[index];
    return .{ .key = n.key, .result_hash = n.result_hash, .src_hash = n.src_hash, .tag = n.tag };
}

pub fn deps(m: *const Manifest, index: u32) []const u32 {
    if (m.overlay.nodes.get(index)) |s| return s.deps;
    const n = m.nodes[index];
    return m.edges[n.deps_start..][0..n.deps_len];
}

/// The nodes that depend on `index`, possibly with extras (see the file's
/// doc comment), in two parts: from the base and from the log.
pub fn rdeps(m: *const Manifest, index: u32) [2][]const u32 {
    const base: []const u32 = if (index < m.nodes.len) b: {
        const n = m.nodes[index];
        break :b m.redges[n.rdeps_start..][0..n.rdeps_len];
    } else &.{};
    const logged: []const u32 = if (m.overlay.rdeps.get(index)) |l| l.items else &.{};
    return .{ base, logged };
}

pub fn atoms(m: *const Manifest, index: u32) []const Pack.AtomRef {
    if (m.overlay.nodes.get(index)) |s| return s.atoms;
    const n = m.nodes[index];
    return m.atom_refs[n.atoms_start..][0..n.atoms_len];
}

/// Every live atom reference, in node order: what to link.
pub fn allAtomRefs(m: *Manifest, gpa: Allocator) ![]const Pack.AtomRef {
    if (m.overlay.nodes.count() == 0) return m.atom_refs;
    if (m.overlay.all_refs) |r| return r;
    // The base's references are in node order: copy the runs between
    // changed nodes whole instead of visiting every node.
    const changed = try gpa.alloc(u32, m.overlay.nodes.count());
    defer gpa.free(changed);
    var it = m.overlay.nodes.keyIterator();
    for (changed) |*c| c.* = it.next().?.*;
    std.mem.sortUnstable(u32, changed, {}, std.sort.asc(u32));
    var refs: std.ArrayList(Pack.AtomRef) = try .initCapacity(gpa, m.atom_refs.len);
    errdefer refs.deinit(gpa);
    var base_done: usize = 0;
    for (changed) |i| {
        if (i < m.nodes.len) {
            const n = m.nodes[i];
            try refs.appendSlice(gpa, m.atom_refs[base_done..n.atoms_start]);
            base_done = n.atoms_start + n.atoms_len;
        } else if (base_done < m.atom_refs.len) {
            try refs.appendSlice(gpa, m.atom_refs[base_done..]);
            base_done = m.atom_refs.len;
        }
        try refs.appendSlice(gpa, m.overlay.nodes.get(i).?.atoms);
    }
    try refs.appendSlice(gpa, m.atom_refs[base_done..]);
    m.overlay.all_refs = try refs.toOwnedSlice(gpa);
    return m.overlay.all_refs.?;
}

pub fn string(m: *const Manifest, s: StrRef) []const u8 {
    return m.strings[s.off..][0..s.len];
}

pub fn inputCount(m: *const Manifest) u32 {
    return @intCast(m.inputs.len + m.overlay.added_inputs);
}

pub fn input(m: *const Manifest, index: u32) struct { Input, []const u8 } {
    if (m.overlay.inputs.get(index)) |s| return .{ s.input, s.path };
    const in = m.inputs[index];
    return .{ in, m.string(in.path) };
}

pub fn errorCount(m: *const Manifest) u32 {
    return @intCast(m.error_names.len + m.overlay.error_names.items.len);
}

pub fn errorName(m: *const Manifest, code: u32) []const u8 {
    if (code - 1 < m.error_names.len) return m.string(m.error_names[code - 1]);
    return m.overlay.error_names.items[code - 1 - m.error_names.len];
}

/// Stats every input and appends the indices of those that changed, or no
/// longer exist, to `changed`. Paths are absolute or relative to the
/// working directory, as recorded.
pub fn changedInputs(m: *const Manifest, gpa: Allocator, io: Io, changed: *std.ArrayList(u32)) !void {
    for (0..m.inputCount()) |i| {
        const in, const path = m.input(@intCast(i));
        const stat = Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                try changed.append(gpa, @intCast(i));
                continue;
            },
            else => |e| return e,
        };
        if (!in.matches(stat)) try changed.append(gpa, @intCast(i));
    }
}

/// Whether the next build should write a new base (`Builder.initFrom`)
/// rather than append to the log.
pub fn shouldFold(m: *const Manifest) bool {
    return m.overlay.len > m.map.memory.len / 4;
}

pub const NodeInit = struct {
    key: Hash,
    result_hash: Hash,
    src_hash: Hash = 0,
    tag: u8 = 0,
    /// Indices of nodes, which may be added later.
    deps: []const u32 = &.{},
    atoms: []const Pack.AtomRef = &.{},
};

/// One build's changes to a manifest, appended to its log.
pub const Delta = struct {
    gpa: Allocator,
    base: *const Manifest,
    nodes: std.ArrayList(u8) = .empty,
    n_nodes: u32 = 0,
    added_nodes: u32 = 0,
    inputs: std.ArrayList(InputDelta) = .empty,
    added_inputs: u32 = 0,
    errors: std.ArrayList(StrRef) = .empty,
    strings: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator, base: *const Manifest) Delta {
        return .{ .gpa = gpa, .base = base };
    }

    pub fn deinit(d: *Delta) void {
        d.nodes.deinit(d.gpa);
        d.inputs.deinit(d.gpa);
        d.errors.deinit(d.gpa);
        d.strings.deinit(d.gpa);
    }

    /// Replaces a node's state after it was analyzed again. Its key stays.
    pub fn update(d: *Delta, index: u32, n: NodeInit) !void {
        std.debug.assert(index < d.base.nodeCount() and d.base.node(index).key == n.key);
        try d.appendNode(index, n);
    }

    /// Adds a node whose key is not in the manifest yet.
    pub fn addNode(d: *Delta, n: NodeInit) !u32 {
        const index = d.base.nodeCount() + d.added_nodes;
        try d.appendNode(index, n);
        d.added_nodes += 1;
        return index;
    }

    fn appendNode(d: *Delta, index: u32, n: NodeInit) !void {
        const delta: NodeDelta = .{
            .key = n.key,
            .result_hash = n.result_hash,
            .src_hash = n.src_hash,
            .index = index,
            .deps_len = @intCast(n.deps.len),
            .atoms_len = @intCast(n.atoms.len),
            .tag = n.tag,
        };
        try appendPadded(d.gpa, &d.nodes, std.mem.asBytes(&delta));
        try appendPadded(d.gpa, &d.nodes, @ptrCast(n.deps));
        try appendPadded(d.gpa, &d.nodes, @ptrCast(n.atoms));
        d.n_nodes += 1;
    }

    /// Records an input's new stat; `index` null adds an input.
    pub fn setInput(d: *Delta, index: ?u32, path: []const u8, stat: Io.File.Stat, content_hash: Hash, build_start: Io.Timestamp) !void {
        const i = index orelse i: {
            d.added_inputs += 1;
            break :i d.base.inputCount() + d.added_inputs - 1;
        };
        try d.inputs.append(d.gpa, .{ .input = .init(stat, content_hash, build_start, try d.addString(path)), .index = i });
    }

    /// Assigns the next error code to `name`.
    pub fn addErrorName(d: *Delta, name: []const u8) !u32 {
        try d.errors.append(d.gpa, try d.addString(name));
        return d.base.errorCount() + @as(u32, @intCast(d.errors.items.len));
    }

    fn addString(d: *Delta, s: []const u8) !StrRef {
        const off: u32 = @intCast(d.strings.items.len);
        try d.strings.appendSlice(d.gpa, s);
        return .{ .off = off, .len = @intCast(s.len) };
    }

    /// Appends the changes to the log in `dir` as one record. The manifest
    /// must be the one in `dir`, opened under the compilation's lock.
    pub fn append(d: *Delta, io: Io, dir: Io.Dir) !void {
        const gpa = d.gpa;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        try body.appendSlice(gpa, d.nodes.items);
        try appendPadded(gpa, &body, @ptrCast(d.inputs.items));
        try appendPadded(gpa, &body, @ptrCast(d.errors.items));
        try appendPadded(gpa, &body, d.strings.items);
        const header: RecordHeader = .{
            .len = @intCast(@sizeOf(RecordHeader) + body.items.len),
            .hash = std.hash.Wyhash.hash(0, body.items),
            .n_nodes = d.n_nodes,
            .n_inputs = @intCast(d.inputs.items.len),
            .n_errors = @intCast(d.errors.items.len),
            .strings_len = @intCast(d.strings.items.len),
        };
        var offset = d.base.overlay.len;
        if (offset == 0) {
            // No log for this base yet: start one.
            const lh: LogHeader = .{ .base_id = d.base.id };
            try cache.writeReplace(io, dir, log_name, &.{std.mem.asBytes(&lh)});
            offset = @sizeOf(LogHeader);
        }
        const f = try dir.openFile(io, log_name, .{ .mode = .write_only });
        defer f.close(io);
        // Drop a torn record left by an interrupted build.
        try f.setLength(io, offset);
        try f.writePositionalAll(io, std.mem.asBytes(&header), offset);
        try f.writePositionalAll(io, body.items, offset + @sizeOf(RecordHeader));
    }
};

fn appendPadded(gpa: Allocator, list: *std.ArrayList(u8), bytes: []const u8) !void {
    try list.appendSlice(gpa, bytes);
    try list.appendNTimes(gpa, 0, std.mem.alignForward(usize, bytes.len, 16) - bytes.len);
}

/// Writes a new base.
pub const Builder = struct {
    gpa: Allocator,
    /// `deps_start` and `atoms_start` index `edges` and `atom_refs`; the
    /// reverse edges are computed by `write`.
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(u32) = .empty,
    atom_refs: std.ArrayList(Pack.AtomRef) = .empty,
    inputs: std.ArrayList(Input) = .empty,
    error_names: std.ArrayList(StrRef) = .empty,
    strings: std.ArrayList(u8) = .empty,
    /// The manifest this one started from: finds its nodes, which keep their
    /// indices. Nodes added since are in `added`.
    base: ?*const Manifest = null,
    added: std.AutoHashMapUnmanaged(Hash, u32) = .empty,

    pub fn deinit(b: *Builder) void {
        const gpa = b.gpa;
        b.nodes.deinit(gpa);
        b.edges.deinit(gpa);
        b.atom_refs.deinit(gpa);
        b.inputs.deinit(gpa);
        b.error_names.deinit(gpa);
        b.strings.deinit(gpa);
        b.added.deinit(gpa);
    }

    /// Starts from `base` with its log applied. `base` must stay open while
    /// the builder is used.
    pub fn initFrom(gpa: Allocator, base: *const Manifest) !Builder {
        var b: Builder = .{ .gpa = gpa, .base = base };
        errdefer b.deinit();
        try b.nodes.appendSlice(gpa, base.nodes);
        try b.edges.appendSlice(gpa, base.edges);
        try b.atom_refs.appendSlice(gpa, base.atom_refs);
        try b.inputs.appendSlice(gpa, base.inputs);
        try b.error_names.appendSlice(gpa, base.error_names);
        try b.strings.appendSlice(gpa, base.strings);
        const o = &base.overlay;
        try b.nodes.resize(gpa, base.nodeCount());
        var nit = o.nodes.iterator();
        while (nit.next()) |e| {
            const s = e.value_ptr;
            b.nodes.items[e.key_ptr.*] = .{
                .key = s.delta.key,
                .result_hash = s.delta.result_hash,
                .src_hash = s.delta.src_hash,
                .tag = s.delta.tag,
                .deps_start = @intCast(b.edges.items.len),
                .deps_len = @intCast(s.deps.len),
                .rdeps_start = 0,
                .rdeps_len = 0,
                .atoms_start = @intCast(b.atom_refs.items.len),
                .atoms_len = @intCast(s.atoms.len),
            };
            try b.edges.appendSlice(gpa, s.deps);
            try b.atom_refs.appendSlice(gpa, s.atoms);
        }
        var kit = o.added_keys.iterator();
        while (kit.next()) |e| try b.added.put(gpa, e.key_ptr.*, e.value_ptr.*);
        try b.inputs.resize(gpa, base.inputCount());
        var iit = o.inputs.iterator();
        while (iit.next()) |e| {
            var in = e.value_ptr.input;
            in.path = try b.addString(e.value_ptr.path);
            b.inputs.items[e.key_ptr.*] = in;
        }
        for (o.error_names.items) |name| try b.error_names.append(gpa, try b.addString(name));
        return b;
    }

    /// Adds a node whose key is not in the manifest yet.
    pub fn addNode(b: *Builder, n: NodeInit) !u32 {
        const gpa = b.gpa;
        const index: u32 = @intCast(b.nodes.items.len);
        try b.added.putNoClobber(gpa, n.key, index);
        try b.nodes.append(gpa, .{
            .key = n.key,
            .result_hash = n.result_hash,
            .src_hash = n.src_hash,
            .tag = n.tag,
            .deps_start = @intCast(b.edges.items.len),
            .deps_len = @intCast(n.deps.len),
            .rdeps_start = 0,
            .rdeps_len = 0,
            .atoms_start = @intCast(b.atom_refs.items.len),
            .atoms_len = @intCast(n.atoms.len),
        });
        try b.edges.appendSlice(gpa, n.deps);
        try b.atom_refs.appendSlice(gpa, n.atoms);
        return index;
    }

    pub fn find(b: *const Builder, key: Hash) ?u32 {
        if (b.base) |m| if (findIn(m.nodes, m.table, key)) |i| return i;
        return b.added.get(key);
    }

    /// Replaces a node's state after it was analyzed again. Its old edges
    /// and atom references are dropped by `write`.
    pub fn update(b: *Builder, index: u32, n: NodeInit) !void {
        const node_ptr = &b.nodes.items[index];
        std.debug.assert(node_ptr.key == n.key);
        node_ptr.result_hash = n.result_hash;
        node_ptr.src_hash = n.src_hash;
        node_ptr.tag = n.tag;
        node_ptr.deps_start = @intCast(b.edges.items.len);
        node_ptr.deps_len = @intCast(n.deps.len);
        node_ptr.atoms_start = @intCast(b.atom_refs.items.len);
        node_ptr.atoms_len = @intCast(n.atoms.len);
        try b.edges.appendSlice(b.gpa, n.deps);
        try b.atom_refs.appendSlice(b.gpa, n.atoms);
    }

    /// Records an input file and its stat as of `build_start`.
    pub fn addInput(b: *Builder, path: []const u8, stat: Io.File.Stat, content_hash: Hash, build_start: Io.Timestamp) !void {
        try b.inputs.append(b.gpa, .init(stat, content_hash, build_start, try b.addString(path)));
    }

    /// Assigns the next error code to `name`. Codes are only appended, so
    /// existing errors keep theirs.
    pub fn addErrorName(b: *Builder, name: []const u8) !u32 {
        try b.error_names.append(b.gpa, try b.addString(name));
        return @intCast(b.error_names.items.len);
    }

    fn addString(b: *Builder, s: []const u8) !StrRef {
        const off: u32 = @intCast(b.strings.items.len);
        try b.strings.appendSlice(b.gpa, s);
        return .{ .off = off, .len = @intCast(s.len) };
    }

    /// Writes a new base to `dir`, atomically replacing the old one and
    /// leaving its log behind.
    pub fn write(b: *Builder, io: Io, dir: Io.Dir, pack_id: Hash) !void {
        const gpa = b.gpa;
        const nodes = try gpa.dupe(Node, b.nodes.items);
        defer gpa.free(nodes);

        // Compact edges and atom references, dropping replaced ranges.
        var edge_count: usize = 0;
        var ref_count: usize = 0;
        for (nodes) |n| {
            edge_count += n.deps_len;
            ref_count += n.atoms_len;
        }
        const edges = try gpa.alloc(u32, edge_count);
        defer gpa.free(edges);
        const refs = try gpa.alloc(Pack.AtomRef, ref_count);
        defer gpa.free(refs);
        edge_count = 0;
        ref_count = 0;
        for (nodes) |*n| {
            for (b.edges.items[n.deps_start..][0..n.deps_len]) |d| {
                if (d >= nodes.len) return error.InvalidNodeIndex;
            }
            @memcpy(edges[edge_count..][0..n.deps_len], b.edges.items[n.deps_start..][0..n.deps_len]);
            n.deps_start = @intCast(edge_count);
            edge_count += n.deps_len;
            @memcpy(refs[ref_count..][0..n.atoms_len], b.atom_refs.items[n.atoms_start..][0..n.atoms_len]);
            n.atoms_start = @intCast(ref_count);
            ref_count += n.atoms_len;
        }

        // Reverse edges: count, prefix sums, fill.
        for (nodes) |*n| n.rdeps_len = 0;
        for (edges) |d| nodes[d].rdeps_len += 1;
        var start: u32 = 0;
        for (nodes) |*n| {
            n.rdeps_start = start;
            start += n.rdeps_len;
            n.rdeps_len = 0;
        }
        const redges = try gpa.alloc(u32, edges.len);
        defer gpa.free(redges);
        for (nodes, 0..) |n, i| {
            for (edges[n.deps_start..][0..n.deps_len]) |d| {
                const t = &nodes[d];
                redges[t.rdeps_start + t.rdeps_len] = @intCast(i);
                t.rdeps_len += 1;
            }
        }

        const table = try gpa.alloc(u32, try std.math.ceilPowerOfTwo(usize, @max(16, 2 * nodes.len)));
        defer gpa.free(table);
        @memset(table, 0);
        const mask = table.len - 1;
        for (nodes, 0..) |n, i| {
            var slot: usize = @as(usize, @truncate(n.key)) & mask;
            while (table[slot] != 0) : (slot = (slot + 1) & mask) {
                if (nodes[table[slot] - 1].key == n.key) return error.DuplicateKey;
            }
            table[slot] = @intCast(i + 1);
        }

        var header: Header = .{ .id = undefined, .pack_id = pack_id, .sections = undefined };
        io.random(std.mem.asBytes(&header.id));
        const parts: [std.enums.values(Section).len][]const u8 = .{
            @ptrCast(nodes),
            @ptrCast(table),
            @ptrCast(edges),
            @ptrCast(redges),
            @ptrCast(refs),
            @ptrCast(b.inputs.items),
            @ptrCast(b.error_names.items),
            b.strings.items,
        };
        const zeros: [16]u8 = @splat(0);
        var vecs: [1 + 2 * parts.len][]const u8 = undefined;
        vecs[0] = std.mem.asBytes(&header);
        var off: u64 = @sizeOf(Header);
        for (parts, 0..) |p, i| {
            const pad = std.mem.alignForward(u64, off, 16) - off;
            vecs[1 + 2 * i] = zeros[0..pad];
            off += pad;
            vecs[2 + 2 * i] = p;
            header.sections[i] = .{ .offset = off, .len = 0 };
            off += p.len;
        }
        inline for (comptime std.enums.values(Section), 0..) |s, i| {
            header.sections[i].len = parts[i].len / @sizeOf(SectionType(s));
        }
        var af = try dir.createFileAtomic(io, "manifest", .{ .replace = true });
        defer af.deinit(io);
        var w = af.file.writerStreaming(io, &.{});
        w.interface.writeVecAll(&vecs) catch return w.err.?;
        w.interface.flush() catch return w.err.?;
        try af.replace(io);
        // The new base's id makes the old log inapplicable; this only tidies.
        dir.deleteFile(io, log_name) catch {};
    }
};

test "manifest round-trip, lookups, reverse edges, log records, and folding" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "b" });
    const base_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(base_path);
    const a_path = try std.fs.path.join(gpa, &.{ base_path, "a.zig" });
    defer gpa.free(a_path);
    const b_path = try std.fs.path.join(gpa, &.{ base_path, "b.zig" });
    defer gpa.free(b_path);
    const old_time: Io.Timestamp = .fromNanoseconds(1_000_000_000 * std.time.ns_per_s);
    try tmp.dir.setTimestamps(io, "a.zig", .{ .modify_timestamp = .{ .new = old_time } });
    try tmp.dir.setTimestamps(io, "b.zig", .{ .modify_timestamp = .{ .new = old_time } });
    const t = std.testing;

    try t.expectEqual(null, try Manifest.open(gpa, io, tmp.dir));
    {
        var b: Builder = .{ .gpa = gpa };
        defer b.deinit();
        // 0 <- 1 <- 2, and 2 also depends on 0 and on node 3, added after it.
        _ = try b.addNode(.{ .key = 100, .result_hash = 1 });
        _ = try b.addNode(.{ .key = 101, .result_hash = 2, .src_hash = 7, .deps = &.{0}, .atoms = &.{.init(32, 64)} });
        _ = try b.addNode(.{ .key = 102, .result_hash = 3, .deps = &.{ 1, 0, 3 } });
        _ = try b.addNode(.{ .key = 103, .result_hash = 4, .atoms = &.{.init(160, 16)} });
        try b.addInput(a_path, try tmp.dir.statFile(io, "a.zig", .{}), 55, Io.Clock.real.now(io));
        try t.expectEqual(1, try b.addErrorName("OutOfMemory"));
        try t.expectEqual(2, try b.addErrorName("Overflow"));
        try b.write(io, tmp.dir, 0xabc);
    }
    var m = (try Manifest.open(gpa, io, tmp.dir)).?;
    defer m.close(gpa, io);
    try t.expectEqual(0xabc, m.pack_id);
    try t.expectEqual(2, m.find(102));
    try t.expectEqual(null, m.find(999));
    try t.expectEqualSlices(u32, &.{ 1, 0, 3 }, m.deps(2));
    try t.expectEqualSlices(u32, &.{ 1, 2 }, m.rdeps(0)[0]);
    try t.expectEqualSlices(u32, &.{2}, m.rdeps(1)[0]);
    try t.expectEqual(64, m.atoms(1)[0].len);
    try t.expectEqualStrings("Overflow", m.errorName(2));
    var changed: std.ArrayList(u32) = .empty;
    defer changed.deinit(gpa);
    try m.changedInputs(gpa, io, &changed);
    try t.expectEqual(0, changed.items.len);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "aa" });
    try m.changedInputs(gpa, io, &changed);
    try t.expectEqualSlices(u32, &.{0}, changed.items);

    // Two edit builds go to the log: node 2 now depends on node 3 only and
    // gets an atom, a node, an input, and an error are added, and a.zig's
    // new stat is recorded.
    {
        var d: Delta = .init(gpa, &m);
        defer d.deinit();
        try d.update(2, .{ .key = 102, .result_hash = 33, .deps = &.{3}, .atoms = &.{.init(96, 48)} });
        try t.expectEqual(4, try d.addNode(.{ .key = 104, .result_hash = 5, .deps = &.{2} }));
        try d.setInput(0, a_path, try tmp.dir.statFile(io, "a.zig", .{}), 56, .fromNanoseconds(std.math.maxInt(i64)));
        try t.expectEqual(3, try d.addErrorName("Unexpected"));
        try d.append(io, tmp.dir);
    }
    var m2 = (try Manifest.open(gpa, io, tmp.dir)).?;
    {
        defer m2.close(gpa, io);
        var d: Delta = .init(gpa, &m2);
        defer d.deinit();
        try d.update(4, .{ .key = 104, .result_hash = 6, .deps = &.{2}, .atoms = &.{.init(208, 16)} });
        try d.setInput(null, b_path, try tmp.dir.statFile(io, "b.zig", .{}), 57, .fromNanoseconds(std.math.maxInt(i64)));
        try d.append(io, tmp.dir);
    }
    // A torn record at the end is ignored, and the next append replaces it.
    {
        const f = try tmp.dir.openFile(io, log_name, .{ .mode = .read_write });
        defer f.close(io);
        try f.writePositionalAll(io, &(@as([48]u8, @splat(0x5a))), try f.length(io));
    }
    const expectLogged = struct {
        fn check(m3: *Manifest) !void {
            try t.expectEqual(5, m3.nodeCount());
            try t.expectEqual(33, m3.node(2).result_hash);
            try t.expectEqual(6, m3.node(4).result_hash);
            try t.expectEqual(4, m3.find(104));
            try t.expectEqualSlices(u32, &.{3}, m3.deps(2));
            try t.expectEqual(96, m3.atoms(2)[0].offset());
            try t.expectEqualStrings("OutOfMemory", m3.errorName(1));
            try t.expectEqualStrings("Unexpected", m3.errorName(3));
            try t.expectEqual(2, m3.inputCount());
            try t.expectEqual(57, m3.input(1)[0].content_hash);
            try t.expectEqual(56, m3.input(0)[0].content_hash);
            var refs: std.ArrayList(u64) = .empty;
            defer refs.deinit(gpa);
            for (try m3.allAtomRefs(gpa)) |r| try refs.append(gpa, r.offset());
            try t.expectEqualSlices(u64, &.{ 32, 96, 160, 208 }, refs.items);
        }
    }.check;
    var m3 = (try Manifest.open(gpa, io, tmp.dir)).?;
    try expectLogged(&m3);
    // The log's reverse edges join the base's, which keep node 2's old
    // dependency on node 0 until the next base.
    try t.expectEqualSlices(u32, &.{ 1, 2 }, m3.rdeps(0)[0]);
    try t.expectEqualSlices(u32, &.{2}, m3.rdeps(3)[1]);
    try t.expectEqualSlices(u32, &.{ 4, 4 }, m3.rdeps(2)[1]);
    {
        var d: Delta = .init(gpa, &m3);
        defer d.deinit();
        try d.append(io, tmp.dir);
    }
    m3.close(gpa, io);
    var m4 = (try Manifest.open(gpa, io, tmp.dir)).?;
    try expectLogged(&m4);

    // Folding writes the same state as a new base, without a log.
    {
        var b: Builder = try .initFrom(gpa, &m4);
        defer b.deinit();
        try t.expectEqual(4, b.find(104));
        try b.write(io, tmp.dir, 0xabc);
    }
    m4.close(gpa, io);
    var m5 = (try Manifest.open(gpa, io, tmp.dir)).?;
    defer m5.close(gpa, io);
    try t.expectEqual(0, m5.overlay.len);
    try expectLogged(&m5);
    try t.expectEqualSlices(u32, &.{1}, m5.rdeps(0)[0]);
    try t.expectEqualSlices(u32, &.{4}, m5.rdeps(2)[0]);
}
