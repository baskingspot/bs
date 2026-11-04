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
//! but its header and the input records. After an edit, the nodes' sources
//! (`Source`) find the nodes the edited files change directly
//! (`seeds.zig`), and it walks reverse edges from those alone (`rdeps`). Reverse edges are a superset: when a log record
//! replaces a node's dependencies, the base's reverse edges from its old
//! dependencies stay until the next base, so a walk may visit a unit that no
//! longer depends on the changed node. Visiting it only re-checks it.
//!
//! A node also lists its references (`Ref`): what the unit requested that
//! is not a dependency (functions it queued, declarations' data, error
//! codes, external symbols, compiler_rt helpers), so that a unit loaded
//! from the cache requests the same and the build reaches the same units.
//! The base also holds the reverse of the references a walk follows
//! (`rrefs`, a superset as `rdeps` is), and each node's flags say whether
//! a walk from the roots reaches it (`Flags.reached`), so that an edit
//! build walks only what its edits can change (`Replay.assumeReached`).
//!
//! The store does not interpret nodes: a node is anything a unit can depend
//! on (a declaration's value or type, a type's layout, a function body or
//! inferred error set, a namespace name lookup, an error code), keyed by a
//! 128-bit stable hash, with an opaque `tag` for Sema. Units are the nodes
//! that have dependencies, a source hash, or Atoms. A node keeps its index
//! and key for as long as the base lasts.
//!
//! The manifest also numbers the link's symbols, so that a relink passes
//! `Elf.Options.symbols` straight from the mapping and the linker hashes
//! no keys: a table from every key a live atom defines or references
//! (error-code keys and the entry included) to a dense number, a
//! `NumberedAtom` per atom reference, and the atoms' target numbers, one
//! contiguous run per atom, a node's runs in its atoms' order. A log record
//! numbers only its new keys, after the existing ones, and appends its
//! runs; writing a base renumbers in link order (atoms first, as they are
//! linked, then the targets nothing defines, then error codes) and drops
//! the keys nothing uses. It also interns the atoms' debug source paths,
//! so that every function of a file shares one path and the linker
//! matches them by address (the table also lists the compile units and
//! inlined callees' files the records name, so that it holds every path
//! the atoms do), and lists the atoms that have debug info, so
//! that a relink reads the records in place (`Pack.LinkAtoms`) and decodes
//! nothing.
//!
//! A node also keeps its unit's result (`result`), so that an edit build
//! can load a green unit's result instead of analyzing it, and its subject
//! (`subject`: the declaration, type, function, or namespace it is about),
//! so that an edit build can find the live dependee behind a dependency:
//! words in the format of `results.zig`, whose InternPool items are in one
//! table for the whole manifest (`items`, `item_starts`). Only a base
//! stores them.
//!
//! Base file: `Header`, then each section at a 16-byte aligned offset.
//! Log file: `LogHeader`, then records (`RecordHeader` and its body), each
//! checksummed; a torn record at the end is ignored and overwritten.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cache = @import("../cache.zig");
const Pack = @import("Pack.zig");
const result_codec = @import("results.zig");
const Hash = cache.Hash;
pub const NumberedAtom = @import("../link/Elf.zig").NumberedAtom;

const Manifest = @This();

map: Io.File.MemoryMap,
/// Random, new for each base; a log applies only to the base it names.
id: Hash,
/// The pack whose offsets the atom references hold.
pack_id: Hash,
/// The link's entry symbol (an `Atom.SymbolKey`), or 0.
entry: Hash,
/// What the build linked.
output: Output,
/// The entry's number, and how many numbers the base uses.
entry_symbol: u32,
/// How many base nodes are `unlinked`.
base_unlinked: u32,
symbol_len: u32,
/// Open-addressing table from symbol key to number, about 80% full (see
/// `symbolSlot`); empty slots have number `no_symbol`.
symbols: []const Symbol,
/// One per atom reference, indexed the same way.
numbered: []const NumberedAtom,
/// The atoms' target numbers (see the file's doc comment).
targets: []const u32,
/// The number of each error's key, by code - 1.
error_symbols: []const u32,
/// Each atom reference's debug source path, an index into `files`, or
/// `no_file`.
debug_files: []const u32,
/// The atom references whose `debug_files` entry is not `no_file`,
/// ascending.
debug_atoms: []const u32,
/// Each atom reference's symbol name, parallel to `atom_refs`: the
/// records keep none, so that a loaded atom takes its type's final name
/// (docs/architecture.md, "Type names").
atom_names: []const AtomName,
atom_name_bytes: []const u8,
files: []const StrRef,
/// Each node's references are `refs[ref_starts[i]..ref_starts[i + 1]]`.
ref_starts: []const u32,
refs: []const Ref,
/// Names that `ext`, `ext_weak`, `import`, and `rt`
/// references index.
ref_names: []const StrRef,
/// An object's or a library's exports, then its imports, each sorted by
/// name (empty for an executable).
link_symbols: []const LinkSymbol,
nodes: []const Node,
/// Where each base node's source is, parallel to `nodes` (see `Source`).
sources: []const Source,
/// The names of `namespace_name` nodes' sources, by node, ascending.
source_names: []const SourceName,
/// Open-addressing table from `Node.key` to node index + 1 (0: empty),
/// a power of two long, at most half full.
table: []const u32,
/// Each node's dependencies at `deps_start` (edge words: see `Edge`), its
/// dependents in `redges` at `rdeps_start` (node indices).
edges: []const u32,
redges: []const u32,
/// The nodes whose references a walk follows (`reachRef`) name node `i`:
/// `rref_nodes[rref_starts[i]..rref_starts[i + 1]]`, ascending.
rref_starts: []const u32,
rref_nodes: []const u32,
atom_refs: []const Pack.AtomRef,
inputs: []const Input,
/// Error names in code order: the error with code `c` is `c - 1`.
error_names: []const StrRef,
/// The file names of the pack's base packs (see `Pack`), in pack index
/// order from 1.
bases: []const StrRef,
/// The item table of the results (see `results.zig`): item `i` is at
/// `items[item_starts[i]..]`.
items: []const u32,
item_starts: []const u32,
/// Each base node's result is `results[result_starts[i]..result_starts[i + 1]]`,
/// empty if it has none.
results: []const u32,
result_starts: []const u32,
/// Each base node's subject, the same way.
subjects: []const u32,
subject_starts: []const u32,
/// Each base node's type name offers and reads (`results.Names`), the same
/// way.
type_names: []const u32,
type_name_starts: []const u32,
/// The base nodes' type name offers (`typeNameNodes`), sorted by type and
/// creator, so that an edit build finds a type's least creator without
/// reading every node that offers it.
type_name_index: []const TypeNameRef,
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
    flags: Flags = .{},
    unused: [2]u8 = @splat(0),
    /// Length of the node's target run, which starts at its first atom's.
    targets_len: u32,
};

/// A node's state across edit builds that do not visit every node
/// (`Delta`).
pub const Flags = packed struct(u8) {
    /// Its atoms are not linked: nothing live reaches it any more.
    unlinked: bool = false,
    /// It may be out of date: an edit reached it over reverse edges, and
    /// no build has checked it since. An edit build treats it as edited.
    stale: bool = false,
    /// A walk of the graph from the roots reaches it (`Incremental.
    /// reachNext`): the build that left it analyzed or kept it. An edit
    /// build takes the nodes no edit can affect as reached without walking
    /// them (`Replay.create`).
    reached: bool = false,
    unused: u5 = 0,
};

pub const StrRef = extern struct { off: u32, len: u32 };

/// An atom's symbol name: `len` bytes at `off` in `atom_name_bytes` (in
/// its log record's strings, for a node the log changed), the first
/// `prefix_len` of which are the final name of the type with stable hash
/// `parent` (0: none), after which an edit build renames it when that
/// type's name changes.
pub const AtomName = extern struct {
    parent: [2]u64 = .{ 0, 0 },
    off: u32,
    len: u32,
    prefix_len: u32 = 0,
    unused: u32 = 0,

    pub fn parentHash(an: AtomName) Hash {
        return @bitCast(an.parent);
    }
};

/// A node's atoms' names (`Manifest.atomNames`).
pub const AtomNames = struct {
    names: []const AtomName,
    bytes: []const u8,

    /// Atom `k`'s name; empty if it lies outside the bytes (a damaged
    /// manifest).
    pub fn name(an: AtomNames, k: usize) []const u8 {
        const n = an.names[k];
        if (n.off > an.bytes.len or n.len > an.bytes.len - n.off) return "";
        return an.bytes[n.off..][0..n.len];
    }
};

/// A dependency edge as stored in `edges` and passed in `NodeInit.deps`:
/// the node depended on, and how. Replay brings only plain dependencies up
/// to date before deciding whether a unit is green; a conditional one is
/// a read that only the comptime evaluator's lowering made (Sema's
/// `deps_conditional`), which the unit's result does not depend on. Both
/// propagate when an edit build walks reverse edges, which may visit more
/// than it must.
pub const Edge = packed struct(u32) {
    node: u30,
    kind: Kind = .plain,

    pub const Kind = enum(u2) { plain, conditional, _ };

    pub fn init(node_index: u32, kind: Kind) u32 {
        return @bitCast(Edge{ .node = @intCast(node_index), .kind = kind });
    }

    pub fn nodeOf(word: u32) u32 {
        return @as(Edge, @bitCast(word)).node;
    }
};

/// Where a node's result comes from in the sources, so that an edit build
/// finds the nodes an edited file can change without analyzing anything
/// (`seeds.zig`): an input (an index into `inputs`; for a Zig source file,
/// its `Frontend` file index in the build that wrote the manifest) and a
/// ZIR instruction in the ZIR of that input's recorded content (a
/// declaration, a container type, a `comptime` block), or none for an
/// embedded file. Opaque to the store, like `Node.tag`.
pub const Source = extern struct {
    input: u32,
    inst: u32,

    pub const none: Source = .{ .input = no_input, .inst = no_inst };
    pub const no_input = std.math.maxInt(u32);
    pub const no_inst = std.math.maxInt(u32);
};

pub const SourceName = extern struct { node: u32, name: StrRef };

/// The kind of file a build links: an executable, a relocatable object
/// (`build-obj`), or a static library holding one (`build-lib`).
pub const Output = enum(u32) { exe, obj, lib, _ };

/// A symbol an object defines for other objects, or one it leaves to them,
/// by name (`ElfObject.Export`, `ElfObject.Import`). An export's `key` is
/// the atom's; an import's is the key relocations name it by.
pub const LinkSymbol = extern struct {
    key: Hash,
    name: StrRef,
    kind: Kind,
    /// An import's `Emit.ImportFlags.bits`; 0 for an export.
    flags: u32 = 0,

    pub const Kind = enum(u32) { @"export", import, _ };
};

/// A node's offer of a name to a type (`type_name_index`), by the type's
/// stable hash and the creator.
pub const TypeNameRef = extern struct {
    ty: Hash,
    creator: Hash,
    node: u32,
    /// Whether the offer won: it has the type's recorded name.
    won: u32,
    unused: [2]u32 = @splat(0),

    fn lessThan(_: void, a: TypeNameRef, b: TypeNameRef) bool {
        if (a.ty != b.ty) return a.ty < b.ty;
        if (a.creator != b.creator) return a.creator < b.creator;
        return a.node < b.node;
    }
};

/// Something a unit requested that is not a dependency: what loading the
/// unit from the cache must request again so that the build reaches the
/// same units and emits the same data.
pub const Ref = extern struct {
    kind: Kind,
    /// A node index (`func`, `nav`), an error code (`err`), an index for
    /// `refName` (`ext`, `ext_weak`, `rt`, `import`), or 0. An `import`'s
    /// name ends in NUL and its `Emit.ImportFlags.bits` as an ASCII digit.
    value: u32,

    pub const Kind = enum(u32) {
        /// A function the unit queued.
        func,
        /// A declaration whose data the unit's code refers to.
        nav,
        /// An error code the unit's code uses.
        err,
        /// An external symbol the unit's code reads the address of.
        ext,
        ext_weak,
        /// A compiler_rt function, by its declaration's key.
        rt,
        /// The error name table.
        error_names,
        /// An edit build must analyze the unit rather than load it: its
        /// analysis had effects outside its result (an `@export`, or a new
        /// namespace with `comptime`, exported or test declarations).
        analyze,
        /// The branch quota (`value`) a generic instance's callers gave it
        /// (`Zcu.branch_quotas`), which it keeps when they are loaded.
        quota,
        /// The unit evaluated a file's root type, or a container type
        /// whose namespace has `comptime`, exported or test declarations:
        /// the `namespace` node `value`, whose `root` references those
        /// declarations' units.
        effects,
        /// On a `namespace` node: a `comptime`, exported or test
        /// declaration's unit (`value`), which a build that makes the
        /// container analyzes.
        root,
        /// In an object, a symbol another object defines, which the unit's
        /// code refers to (`Emit.useImport`).
        import,
        /// On a struct's `type_layout` node: its `struct_defaults` unit
        /// (`value`), which a build that resolves the layout analyzes
        /// (`Zcu.queueDefaults`).
        defaults,
    };
};

pub const Symbol = extern struct {
    key: [2]u64,
    number: u32,
    unused: u32 = 0,

    fn init(key: Hash, number: u32) Symbol {
        return .{ .key = @bitCast(key), .number = number };
    }

    fn keyHash(s: Symbol) Hash {
        return @bitCast(s.key);
    }
};

pub const no_symbol = std.math.maxInt(u32);
pub const no_file = std.math.maxInt(u32);

/// Where a key's probe starts in a symbol table of `len` slots. The table
/// need not be a power of two long, so it stays about 30 bytes per key;
/// only an edit's new keys are looked up in it.
fn symbolSlot(key: Hash, len: usize) usize {
    return @intCast((@as(u128, @as(u64, @truncate(key))) * len) >> 64);
}

/// Symbol key to number in memory: open addressing over `Symbol`s, so that
/// a lookup touches one cache line; numbering a build's keys is a lookup
/// per relocation target.
const SymbolMap = struct {
    slots: []Symbol = &.{},
    count: u32 = 0,

    pub const empty: SymbolMap = .{};

    fn deinit(m: *SymbolMap, gpa: Allocator) void {
        gpa.free(m.slots);
    }

    fn get(m: *const SymbolMap, key: Hash) ?u32 {
        if (m.slots.len == 0) return null;
        const mask = m.slots.len - 1;
        var i: usize = @as(usize, @truncate(key)) & mask;
        while (true) : (i = (i + 1) & mask) {
            const s = m.slots[i];
            if (s.number == no_symbol) return null;
            if (s.keyHash() == key) return s.number;
        }
    }

    /// The number of `key`, which becomes `new` if `key` has none.
    fn getOrPut(m: *SymbolMap, gpa: Allocator, key: Hash, new: u32) !struct { u32, bool } {
        if (2 * (m.count + 1) > m.slots.len) try m.grow(gpa);
        const mask = m.slots.len - 1;
        var i: usize = @as(usize, @truncate(key)) & mask;
        while (true) : (i = (i + 1) & mask) {
            const s = &m.slots[i];
            if (s.number == no_symbol) {
                s.* = .init(key, new);
                m.count += 1;
                return .{ new, true };
            }
            if (s.keyHash() == key) return .{ s.number, false };
        }
    }

    fn ensureUnusedCapacity(m: *SymbolMap, gpa: Allocator, n: usize) !void {
        while (2 * (m.count + n) > m.slots.len) try m.grow(gpa);
    }

    fn grow(m: *SymbolMap, gpa: Allocator) !void {
        const old = m.slots;
        m.slots = try gpa.alloc(Symbol, @max(64, 2 * old.len));
        @memset(m.slots, .{ .key = .{ 0, 0 }, .number = no_symbol });
        const mask = m.slots.len - 1;
        for (old) |s| {
            if (s.number == no_symbol) continue;
            var i: usize = @as(usize, @truncate(s.keyHash())) & mask;
            while (m.slots[i].number != no_symbol) i = (i + 1) & mask;
            m.slots[i] = s;
        }
        gpa.free(old);
    }
};

/// A new atom's symbols, for numbering: its key, its targets' keys, its
/// debug source path, if it has debug info, and its name (`AtomName`).
pub const AtomSymbols = struct {
    key: Hash,
    targets: []const Hash,
    file: ?[]const u8 = null,
    /// The atom's other debug source paths: its compile unit's, and the
    /// NUL-separated files of the functions it inlines. Only interned
    /// into `files`, so that the table lists every path the atoms name
    /// (`Replay.donorEager` reads it).
    other_files: [2][]const u8 = .{ "", "" },
    name: []const u8 = "",
    /// The type whose name the first `prefix_len` bytes of `name` are,
    /// by stable hash, or 0.
    parent: Hash = 0,
    prefix_len: u32 = 0,
};

pub const Input = extern struct {
    content_hash: Hash,
    inode: u64,
    size: u64,
    /// Nanoseconds, or `racy_mtime` (see `Builder.addInput`).
    mtime: i64,
    path: StrRef,
    /// The file's unit-key prefix, `<module name>:<path within it>`
    /// (`Zcu.fileKey`): what the nodes' keys name the file by. A build
    /// whose modules map the key to another file must not take the
    /// nodes as its own (a donor's, see `Replay.create`).
    key: StrRef,

    pub const racy_mtime = std.math.minInt(i64);

    pub fn matches(in: Input, stat: Io.File.Stat) bool {
        return in.mtime != racy_mtime and in.inode == stat.inode and in.size == stat.size and
            in.mtime == stat.mtime.toNanoseconds();
    }

    fn init(stat: Io.File.Stat, content_hash: Hash, build_start: Io.Timestamp, path: StrRef, key: StrRef) Input {
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
            .key = key,
        };
    }
};

const Section = enum { nodes, table, edges, redges, rref_starts, rref_nodes, atom_refs, inputs, error_names, bases, symbols, numbered, targets, error_symbols, debug_files, debug_atoms, files, ref_starts, refs, ref_names, sources, source_names, items, item_starts, results, result_starts, subjects, subject_starts, link_symbols, type_names, type_name_starts, type_name_index, atom_names, atom_name_bytes, strings };
const SectionRange = extern struct { offset: u64, len: u64 };

const magic = "ZAPMAN15".*;
const log_magic = "ZAPMLG08".*;
const record_magic: u32 = 0x5a524543;
const log_name = "manifest.log";

const Header = extern struct {
    magic: [8]u8 = magic,
    symbol_len: u32,
    entry_symbol: u32,
    /// How many nodes are `unlinked`.
    unlinked: u32 = 0,
    output: Output = .exe,
    id: Hash,
    pack_id: Hash,
    entry: Hash,
    sections: [std.enums.values(Section).len]SectionRange,
};

const LogHeader = extern struct {
    magic: [8]u8 = log_magic,
    unused: [8]u8 = @splat(0),
    base_id: Hash,
};

/// One build's changes. The body: `n_nodes` node changes (each a
/// `NodeDelta`, then its dependencies, atom references, numbered atoms,
/// debug files, atom names (whose bytes are in the record's strings),
/// target run, references, result, subject and names, each padded to 16
/// bytes), `n_inputs` `InputDelta`s, `n_errors` `StrRef`s and as
/// many error symbols, `n_symbols` new `Symbol`s, `n_files` new debug
/// files' `StrRef`s, `n_ref_names` reference names' `StrRef`s, the
/// starts of `n_items` new result items in the `item_words` words that
/// follow (relative to them), `n_overrides` `ItemOverride`s, whose words
/// are there too, `n_flags` `FlagsDelta`s, `n_sources`
/// `SourceDelta`s, and `strings_len` string bytes that the inputs, errors,
/// files and source names refer to, each padded. Numbered atoms'
/// `targets` index the base's targets followed by the runs of the log so
/// far; item references count the base's items, then the log's.
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
    n_symbols: u32,
    n_files: u32,
    n_ref_names: u32,
    n_items: u32,
    item_words: u32,
    n_flags: u32,
    n_sources: u32,
    n_overrides: u32,
};

/// An existing result item's new words: those of an item that names
/// source in an input whose content changed, with its instruction in the
/// new content (`no_inst` if it has none there).
const ItemOverride = extern struct { id: u32, start: u32 };

/// A node's new state. `index` is an existing node, or the next new one.
const NodeDelta = extern struct {
    key: Hash,
    result_hash: Hash,
    src_hash: Hash,
    index: u32,
    deps_len: u32,
    atoms_len: u32,
    targets_len: u32,
    tag: u8,
    flags: Flags,
    unused: [2]u8 = @splat(0),
    refs_len: u32,
    result_len: u32,
    subject_len: u32,
    source: Source,
    /// `len` 0 if none.
    source_name: StrRef,
    names_len: u32,
    unused2: [12]u8 = @splat(0),
};

/// A node's new flags, the rest of it unchanged.
const FlagsDelta = extern struct { node: u32, flags: Flags, unused: [3]u8 = @splat(0) };

/// A node's source after its input changed, the rest of it unchanged.
const SourceDelta = extern struct { node: u32, source: Source };

/// An input's new stat. `index` is an existing input, or the next new one.
const InputDelta = extern struct {
    input: Input,
    index: u32,
    unused: [12]u8 = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(Node) == 80);
    std.debug.assert(@sizeOf(Input) == 64);
    std.debug.assert(@sizeOf(RecordHeader) == 64);
    std.debug.assert(@sizeOf(NodeDelta) == 112);
    std.debug.assert(@sizeOf(Symbol) == 24);
    std.debug.assert(@sizeOf(InputDelta) == 80);
    std.debug.assert(@sizeOf(LinkSymbol) == 32);
    std.debug.assert(@sizeOf(TypeNameRef) == 48);
    std.debug.assert(@sizeOf(AtomName) == 32);
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
    /// Reverse references set in the log, as `rdeps`.
    rrefs: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty,
    inputs: std.AutoHashMapUnmanaged(u32, InputState) = .empty,
    added_inputs: u32 = 0,
    error_names: std.ArrayList([]const u8) = .empty,
    error_symbols: std.ArrayList(u32) = .empty,
    /// Keys the log numbered.
    added_symbols: SymbolMap = .empty,
    /// The log's target runs, after the base's.
    targets: std.ArrayList(u32) = .empty,
    files: std.ArrayList([]const u8) = .empty,
    ref_names: std.ArrayList([]const u8) = .empty,
    /// Flags and sources changed without the rest of their node.
    flags: std.AutoHashMapUnmanaged(u32, Flags) = .empty,
    sources: std.AutoHashMapUnmanaged(u32, Source) = .empty,
    /// The log's result items, after the base's: item `base items + i` is
    /// at `item_words[item_starts[i]..]`.
    item_words: std.ArrayList(u32) = .empty,
    item_starts: std.ArrayList(u32) = .empty,
    /// Items whose words changed: id to their start in `item_words`.
    item_overrides: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// What `linkInput` returns, gathered on first use when nodes changed.
    gathered: ?LinkInput = null,
    /// `LinkInput.names` when the base is linked as it is (not
    /// `gathered`, which owns its own), made on first use.
    base_link_names: ?[]const []const u8 = null,

    const NodeState = struct {
        delta: *const NodeDelta,
        deps: []const u32,
        atoms: []const Pack.AtomRef,
        numbered: []const NumberedAtom,
        debug_files: []const u32,
        atom_names: []const AtomName,
        /// The record's strings, which `atom_names` index.
        name_bytes: []const u8,
        refs: []const Ref,
        result: []const u32,
        subject: []const u32,
        names: []const u32,
        flags: Flags,
        source: Source,
        source_name: ?[]const u8,
    };
    const InputState = struct { input: Input, path: []const u8, key: []const u8 };

    fn deinit(o: *Overlay, gpa: Allocator) void {
        gpa.free(o.buf);
        o.nodes.deinit(gpa);
        o.added_keys.deinit(gpa);
        var it = o.rdeps.valueIterator();
        while (it.next()) |l| l.deinit(gpa);
        o.rdeps.deinit(gpa);
        var rit = o.rrefs.valueIterator();
        while (rit.next()) |l| l.deinit(gpa);
        o.rrefs.deinit(gpa);
        o.inputs.deinit(gpa);
        o.error_names.deinit(gpa);
        o.error_symbols.deinit(gpa);
        o.added_symbols.deinit(gpa);
        o.targets.deinit(gpa);
        o.files.deinit(gpa);
        o.ref_names.deinit(gpa);
        o.flags.deinit(gpa);
        o.sources.deinit(gpa);
        o.item_words.deinit(gpa);
        o.item_starts.deinit(gpa);
        o.item_overrides.deinit(gpa);
        if (o.gathered) |g| {
            gpa.free(g.refs);
            gpa.free(g.numbered);
            gpa.free(g.debug_files);
            gpa.free(g.debug_atoms);
            gpa.free(g.names);
        }
        if (o.base_link_names) |n| gpa.free(n);
    }
};

fn SectionType(comptime s: Section) type {
    return switch (s) {
        .nodes => Node,
        .table, .edges, .redges, .rref_starts, .rref_nodes => u32,
        .atom_refs => Pack.AtomRef,
        .inputs => Input,
        .error_names, .bases, .files, .ref_names => StrRef,
        .ref_starts, .items, .item_starts, .results, .result_starts, .subjects, .subject_starts, .type_names, .type_name_starts => u32,
        .type_name_index => TypeNameRef,
        .atom_names => AtomName,
        .atom_name_bytes => u8,
        .refs => Ref,
        .sources => Source,
        .source_names => SourceName,
        .symbols => Symbol,
        .numbered => NumberedAtom,
        .targets, .error_symbols, .debug_files, .debug_atoms => u32,
        .link_symbols => LinkSymbol,
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
    m.entry = h.entry;
    m.output = h.output;
    m.entry_symbol = h.entry_symbol;
    m.base_unlinked = h.unlinked;
    m.symbol_len = h.symbol_len;
    m.overlay = .{};
    inline for (comptime std.enums.values(Section)) |s| {
        const T = SectionType(s);
        const r = h.sections[@backingInt(s)];
        if (r.offset % 16 != 0 or r.offset > bytes.len or r.len > (bytes.len - r.offset) / @sizeOf(T))
            return corrupt(io, &map);
        @field(m, @tagName(s)) = @as([*]const T, @ptrCast(@alignCast(bytes.ptr + r.offset)))[0..r.len];
    }
    if (m.table.len == 0 or !std.math.isPowerOfTwo(m.table.len) or
        m.symbols.len <= m.symbol_len or
        m.numbered.len != m.atom_refs.len or m.debug_files.len != m.atom_refs.len or m.atom_names.len != m.atom_refs.len or
        m.error_symbols.len != m.error_names.len or
        m.ref_starts.len != m.nodes.len + 1 or m.ref_starts[m.nodes.len] != m.refs.len or
        m.rref_starts.len != m.nodes.len + 1 or m.rref_starts[m.nodes.len] != m.rref_nodes.len or
        m.sources.len != m.nodes.len or
        m.result_starts.len != m.nodes.len + 1 or m.result_starts[m.nodes.len] != m.results.len or
        m.subject_starts.len != m.nodes.len + 1 or m.subject_starts[m.nodes.len] != m.subjects.len or
        m.type_name_starts.len != m.nodes.len + 1 or m.type_name_starts[m.nodes.len] != m.type_names.len or
        (m.item_starts.len != 0 and m.item_starts[m.item_starts.len - 1] >= m.items.len)) return corrupt(io, &map);
    for (m.type_name_index) |t| if (t.node >= m.nodes.len) return corrupt(io, &map);
    for (m.link_symbols) |ls| {
        if (ls.name.off > m.strings.len or ls.name.len > m.strings.len - ls.name.off or ls.flags > 7) return corrupt(io, &map);
    }
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
    // Source names are in the strings, at the end.
    const NamedState = struct { index: u32, name: StrRef };
    var named: std.ArrayList(NamedState) = .empty;
    defer named.deinit(gpa);
    // So are its atoms' names.
    var with_atoms: std.ArrayList(u32) = .empty;
    defer with_atoms.deinit(gpa);
    for (0..rh.n_nodes) |_| {
        const d = r.take(NodeDelta, 1);
        const node_deps = r.take(u32, d[0].deps_len);
        const node_atoms = r.take(Pack.AtomRef, d[0].atoms_len);
        const node_numbered = r.take(NumberedAtom, d[0].atoms_len);
        const node_files = r.take(u32, d[0].atoms_len);
        const node_atom_names = r.take(AtomName, d[0].atoms_len);
        const node_targets = r.take(u32, d[0].targets_len);
        const node_refs = r.take(Ref, d[0].refs_len);
        const node_result = r.take(u32, d[0].result_len);
        const node_subject = r.take(u32, d[0].subject_len);
        const node_names = r.take(u32, d[0].names_len);
        try o.targets.appendSlice(gpa, node_targets);
        const index = d[0].index;
        if (index == m.nodeCount()) {
            o.added_nodes += 1;
            try o.added_keys.put(gpa, d[0].key, index);
        }
        try o.nodes.put(gpa, index, .{
            .delta = &d[0],
            .deps = node_deps,
            .atoms = node_atoms,
            .numbered = node_numbered,
            .debug_files = node_files,
            .atom_names = node_atom_names,
            .name_bytes = &.{},
            .refs = node_refs,
            .result = node_result,
            .subject = node_subject,
            .names = node_names,
            .flags = d[0].flags,
            .source = d[0].source,
            .source_name = null,
        });
        _ = o.flags.remove(index);
        _ = o.sources.remove(index);
        if (d[0].source_name.len != 0) try named.append(gpa, .{ .index = index, .name = d[0].source_name });
        if (d[0].atoms_len != 0) try with_atoms.append(gpa, index);
        for (node_deps) |dep| {
            const gop = try o.rdeps.getOrPut(gpa, Edge.nodeOf(dep));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(gpa, index);
        }
        for (node_refs) |ref| if (reachRef(ref.kind)) {
            const gop = try o.rrefs.getOrPut(gpa, ref.value);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(gpa, index);
        };
    }
    const input_deltas = r.take(InputDelta, rh.n_inputs);
    const errors = r.take(StrRef, rh.n_errors);
    const error_symbols = r.take(u32, rh.n_errors);
    const symbols = r.take(Symbol, rh.n_symbols);
    const files = r.take(StrRef, rh.n_files);
    const ref_names = r.take(StrRef, rh.n_ref_names);
    const item_starts = r.take(u32, rh.n_items);
    const item_words = r.take(u32, rh.item_words);
    const overrides = r.take(ItemOverride, rh.n_overrides);
    const flag_deltas = r.take(FlagsDelta, rh.n_flags);
    const source_deltas = r.take(SourceDelta, rh.n_sources);
    const strings = r.take(u8, rh.strings_len);
    for (named.items) |n| o.nodes.getPtr(n.index).?.source_name = strings[n.name.off..][0..n.name.len];
    for (with_atoms.items) |n| o.nodes.getPtr(n).?.name_bytes = strings;
    const words_base: u32 = @intCast(o.item_words.items.len);
    for (item_starts) |st| try o.item_starts.append(gpa, words_base + st);
    for (overrides) |ov| try o.item_overrides.put(gpa, ov.id, words_base + ov.start);
    try o.item_words.appendSlice(gpa, item_words);
    for (flag_deltas) |f| {
        if (o.nodes.getPtr(f.node)) |st| st.flags = f.flags else try o.flags.put(gpa, f.node, f.flags);
    }
    for (source_deltas) |sd| {
        if (o.nodes.getPtr(sd.node)) |st| st.source = sd.source else try o.sources.put(gpa, sd.node, sd.source);
    }
    for (input_deltas) |*d| {
        if (d.index == m.inputCount()) o.added_inputs += 1;
        try o.inputs.put(gpa, d.index, .{
            .input = d.input,
            .path = strings[d.input.path.off..][0..d.input.path.len],
            .key = strings[d.input.key.off..][0..d.input.key.len],
        });
    }
    for (errors) |e| try o.error_names.append(gpa, strings[e.off..][0..e.len]);
    try o.error_symbols.appendSlice(gpa, error_symbols);
    for (symbols) |sym| _ = try o.added_symbols.getOrPut(gpa, sym.keyHash(), sym.number);
    for (files) |f| try o.files.append(gpa, strings[f.off..][0..f.len]);
    for (ref_names) |f| try o.ref_names.append(gpa, strings[f.off..][0..f.len]);
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

/// What node `index` requested besides its dependencies (`Ref`).
pub fn nodeRefs(m: *const Manifest, index: u32) []const Ref {
    if (m.overlay.nodes.get(index)) |s| return s.refs;
    if (index >= m.nodes.len) return &.{};
    return m.refs[m.ref_starts[index]..m.ref_starts[index + 1]];
}

/// Node `index`'s source.
pub fn source(m: *const Manifest, index: u32) Source {
    if (m.overlay.nodes.get(index)) |s| return s.source;
    if (m.overlay.sources.get(index)) |s| return s;
    return if (index < m.sources.len) m.sources[index] else .none;
}

/// Node `index`'s flags.
pub fn flags(m: *const Manifest, index: u32) Flags {
    if (m.overlay.nodes.get(index)) |s| return s.flags;
    if (m.overlay.flags.get(index)) |f| return f;
    return if (index < m.nodes.len) m.nodes[index].flags else .{};
}

/// The declaration name a `namespace_name` node looks up, if `index` is
/// one.
pub fn sourceName(m: *const Manifest, index: u32) ?[]const u8 {
    if (m.overlay.nodes.get(index)) |s| return s.source_name;
    if (index >= m.nodes.len) return null;
    var lo: usize = 0;
    var hi: usize = m.source_names.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const n = m.source_names[mid];
        if (n.node < index) lo = mid + 1 else if (n.node > index) hi = mid else {
            if (n.name.off > m.strings.len or n.name.len > m.strings.len - n.name.off) return null;
            return m.string(n.name);
        }
    }
    return null;
}

pub fn refName(m: *const Manifest, value: u32) []const u8 {
    if (value < m.ref_names.len) return m.string(m.ref_names[value]);
    return m.overlay.ref_names.items[value - m.ref_names.len];
}

pub fn refNameCount(m: *const Manifest) u32 {
    return @intCast(m.ref_names.len + m.overlay.ref_names.items.len);
}

/// Node `index`'s dependencies, as `Edge` words.
pub fn deps(m: *const Manifest, index: u32) []const u32 {
    if (m.overlay.nodes.get(index)) |s| return s.deps;
    const n = m.nodes[index];
    return m.edges[n.deps_start..][0..n.deps_len];
}

/// Node `index`'s result in the format of `results.zig`, or empty if it has
/// none.
pub fn result(m: *const Manifest, index: u32) []const u32 {
    if (m.overlay.nodes.get(index)) |s| return s.result;
    if (index >= m.nodes.len) return &.{};
    return m.results[m.result_starts[index]..m.result_starts[index + 1]];
}

/// Node `index`'s subject in the format of `results.zig`, or empty, as
/// `result`.
pub fn subject(m: *const Manifest, index: u32) []const u32 {
    if (m.overlay.nodes.get(index)) |s| return s.subject;
    if (index >= m.nodes.len) return &.{};
    return m.subjects[m.subject_starts[index]..m.subject_starts[index + 1]];
}

/// The base nodes' offers of a name to the type with stable hash `ty`,
/// least creator first; nodes the log changed may be among them, with
/// their old offers.
pub fn typeNameNodes(m: *const Manifest, ty: Hash) []const TypeNameRef {
    const index = m.type_name_index;
    var lo: usize = 0;
    var hi: usize = index.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (index[mid].ty < ty) lo = mid + 1 else hi = mid;
    }
    var end = lo;
    while (end < index.len and index[end].ty == ty) end += 1;
    return index[lo..end];
}

/// Node `index`'s type name offers and reads (`results.Names`), or empty,
/// as `result`.
pub fn typeNames(m: *const Manifest, index: u32) []const u32 {
    if (m.overlay.nodes.get(index)) |s| return s.names;
    if (index >= m.nodes.len) return &.{};
    return m.type_names[m.type_name_starts[index]..m.type_name_starts[index + 1]];
}

/// The result items: the base's, then the log's.
pub const Items = struct {
    base_words: []const u32 = &.{},
    base_starts: []const u32 = &.{},
    log_words: []const u32 = &.{},
    log_starts: []const u32 = &.{},
    overrides: ?*const std.AutoHashMapUnmanaged(u32, u32) = null,

    pub fn count(it: Items) u32 {
        return @intCast(it.base_starts.len + it.log_starts.len);
    }

    /// Item `id`: the words it is in, and where it starts.
    pub fn at(it: Items, id: u32) struct { []const u32, u32 } {
        if (it.overrides) |o| if (o.get(id)) |start| return .{ it.log_words, start };
        if (id < it.base_starts.len) return .{ it.base_words, it.base_starts[id] };
        return .{ it.log_words, it.log_starts[id - it.base_starts.len] };
    }
};

pub fn resultItems(m: *const Manifest) Items {
    return .{
        .base_words = m.items,
        .base_starts = m.item_starts,
        .log_words = m.overlay.item_words.items,
        .log_starts = m.overlay.item_starts.items,
        .overrides = if (m.overlay.item_overrides.count() != 0) &m.overlay.item_overrides else null,
    };
}

/// How many result items there are.
pub fn itemCount(m: *const Manifest) u32 {
    return @intCast(m.item_starts.len + m.overlay.item_starts.items.len);
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

/// The nodes whose references a walk follows name node `index`: the
/// base's, then the log's. A superset, as `rdeps`.
pub fn rrefs(m: *const Manifest, index: u32) [2][]const u32 {
    const base: []const u32 = if (index < m.nodes.len) m.rref_nodes[m.rref_starts[index]..m.rref_starts[index + 1]] else &.{};
    const logged: []const u32 = if (m.overlay.rrefs.get(index)) |l| l.items else &.{};
    return .{ base, logged };
}

/// Whether a walk of the graph follows references of `kind` (`Incremental.
/// reachNext`): what they name is part of the program if the node is.
pub fn reachRef(kind: Ref.Kind) bool {
    return switch (kind) {
        .func, .nav, .effects, .root, .defaults => true,
        else => false,
    };
}

pub fn atoms(m: *const Manifest, index: u32) []const Pack.AtomRef {
    if (m.overlay.nodes.get(index)) |s| return s.atoms;
    const n = m.nodes[index];
    return m.atom_refs[n.atoms_start..][0..n.atoms_len];
}

/// Node `index`'s atoms' names, parallel to `atoms(index)`.
pub fn atomNames(m: *const Manifest, index: u32) AtomNames {
    if (m.overlay.nodes.get(index)) |s| return .{ .names = s.atom_names, .bytes = s.name_bytes };
    const n = m.nodes[index];
    return .{ .names = m.atom_names[n.atoms_start..][0..n.atoms_len], .bytes = m.atom_name_bytes };
}

/// What to link: every live atom reference in node order, with its
/// numbered atom, debug file and name, the atoms that have debug info,
/// and the target runs they index: the base's, then the log's (as
/// `Elf.Symbols.targets` and `targets_tail`).
pub const LinkInput = struct {
    refs: []const Pack.AtomRef,
    numbered: []const NumberedAtom,
    debug_files: []const u32,
    debug_atoms: []const u32,
    targets: []const u32,
    targets_tail: []const u32,
    names: []const []const u8,
};

/// Slices of the mapping when the log changed no node and no node is
/// `unlinked`; otherwise gathered once and kept until `close`.
pub fn linkInput(m: *Manifest, gpa: Allocator) !LinkInput {
    const o = &m.overlay;
    if (o.nodes.count() == 0 and o.flags.count() == 0 and m.base_unlinked == 0) {
        if (o.base_link_names == null) {
            const names = try gpa.alloc([]const u8, m.atom_names.len);
            const all: AtomNames = .{ .names = m.atom_names, .bytes = m.atom_name_bytes };
            for (names, 0..) |*n, k| n.* = all.name(k);
            o.base_link_names = names;
        }
        return .{
            .refs = m.atom_refs,
            .numbered = m.numbered,
            .debug_files = m.debug_files,
            .debug_atoms = m.debug_atoms,
            .targets = m.targets,
            .targets_tail = o.targets.items,
            .names = o.base_link_names.?,
        };
    }
    if (o.gathered) |g| return g;
    var refs: std.ArrayList(Pack.AtomRef) = try .initCapacity(gpa, m.atom_refs.len);
    defer refs.deinit(gpa);
    var numbered: std.ArrayList(NumberedAtom) = try .initCapacity(gpa, m.atom_refs.len);
    defer numbered.deinit(gpa);
    var debug_files: std.ArrayList(u32) = try .initCapacity(gpa, m.atom_refs.len);
    defer debug_files.deinit(gpa);
    var names: std.ArrayList([]const u8) = try .initCapacity(gpa, m.atom_refs.len);
    defer names.deinit(gpa);
    // The base's references are in node order: copy runs of base nodes
    // whole instead of one node at a time.
    var run_start: usize = 0;
    var run_end: usize = 0;
    for (0..m.nodeCount()) |i_usize| {
        const i: u32 = @intCast(i_usize);
        const st = o.nodes.get(i);
        const linked = !m.flags(i).unlinked;
        if (st == null and i < m.nodes.len and linked) {
            const n = m.nodes[i];
            if (n.atoms_len == 0) continue;
            if (n.atoms_start != run_end) {
                try appendRun(gpa, m, &refs, &numbered, &debug_files, &names, run_start, run_end);
                run_start = n.atoms_start;
            }
            run_end = n.atoms_start + n.atoms_len;
            continue;
        }
        if (st == null or !linked or st.?.atoms.len == 0) continue;
        try appendRun(gpa, m, &refs, &numbered, &debug_files, &names, run_start, run_end);
        run_start = run_end;
        try refs.appendSlice(gpa, st.?.atoms);
        try numbered.appendSlice(gpa, st.?.numbered);
        try debug_files.appendSlice(gpa, st.?.debug_files);
        const node_names: AtomNames = .{ .names = st.?.atom_names, .bytes = st.?.name_bytes };
        for (0..node_names.names.len) |k| try names.append(gpa, node_names.name(k));
    }
    try appendRun(gpa, m, &refs, &numbered, &debug_files, &names, run_start, run_end);
    const debug_atoms = try debugAtoms(gpa, debug_files.items);
    errdefer gpa.free(debug_atoms);
    const g: LinkInput = .{
        .refs = try refs.toOwnedSlice(gpa),
        .numbered = try numbered.toOwnedSlice(gpa),
        .debug_files = try debug_files.toOwnedSlice(gpa),
        .debug_atoms = debug_atoms,
        .targets = m.targets,
        .targets_tail = o.targets.items,
        .names = try names.toOwnedSlice(gpa),
    };
    o.gathered = g;
    return g;
}

fn appendRun(gpa: Allocator, m: *const Manifest, refs: *std.ArrayList(Pack.AtomRef), numbered: *std.ArrayList(NumberedAtom), debug_files: *std.ArrayList(u32), names: *std.ArrayList([]const u8), lo: usize, hi: usize) !void {
    if (lo == hi) return;
    try refs.appendSlice(gpa, m.atom_refs[lo..hi]);
    try numbered.appendSlice(gpa, m.numbered[lo..hi]);
    try debug_files.appendSlice(gpa, m.debug_files[lo..hi]);
    const run: AtomNames = .{ .names = m.atom_names[lo..hi], .bytes = m.atom_name_bytes };
    for (0..hi - lo) |k| try names.append(gpa, run.name(k));
}

/// The indices of `debug_files` that are not `no_file`.
fn debugAtoms(gpa: Allocator, debug_files: []const u32) ![]u32 {
    var n: usize = 0;
    for (debug_files) |f| n += @intFromBool(f != no_file);
    const out = try gpa.alloc(u32, n);
    n = 0;
    for (debug_files, 0..) |f, i| if (f != no_file) {
        out[n] = @intCast(i);
        n += 1;
    };
    return out;
}

/// Every live atom reference, in node order.
pub fn allAtomRefs(m: *Manifest, gpa: Allocator) ![]const Pack.AtomRef {
    return (try m.linkInput(gpa)).refs;
}

/// How many symbol numbers the manifest uses: those it links take numbers
/// below this.
pub fn symbolLen(m: *const Manifest) u32 {
    return m.symbol_len + m.overlay.added_symbols.count;
}

/// The number of a symbol key, if it has one.
pub fn symbol(m: *const Manifest, key: Hash) ?u32 {
    if (findSymbolIn(m.symbols, key)) |n| return n;
    return m.overlay.added_symbols.get(key);
}

fn findSymbolIn(table: []const Symbol, key: Hash) ?u32 {
    var i = symbolSlot(key, table.len);
    while (true) {
        const s = table[i];
        if (s.number == no_symbol) return null;
        if (s.keyHash() == key) return s.number;
        i += 1;
        if (i == table.len) i = 0;
    }
}

/// The number of the key of the error with code `code`.
pub fn errorSymbol(m: *const Manifest, code: u32) u32 {
    if (code - 1 < m.error_symbols.len) return m.error_symbols[code - 1];
    return m.overlay.error_symbols.items[code - 1 - m.error_symbols.len];
}

pub fn fileCount(m: *const Manifest) u32 {
    return @intCast(m.files.len + m.overlay.files.items.len);
}

/// A debug source path, by its index in `debug_files`.
pub fn file(m: *const Manifest, index: u32) []const u8 {
    if (index < m.files.len) return m.string(m.files[index]);
    return m.overlay.files.items[index - m.files.len];
}

fn targetsLen(m: *const Manifest) u32 {
    return @intCast(m.targets.len + m.overlay.targets.items.len);
}

pub fn basePack(m: *const Manifest, i: usize) []const u8 {
    return m.string(m.bases[i]);
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

/// `Input.key` of input `index`.
pub fn inputKey(m: *const Manifest, index: u32) []const u8 {
    if (m.overlay.inputs.get(index)) |s| return s.key;
    return m.string(m.inputs[index].key);
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
    /// `Edge` words; their nodes may be added later.
    deps: []const u32 = &.{},
    atoms: []const Pack.AtomRef = &.{},
    /// One per atom.
    symbols: []const AtomSymbols = &.{},
    /// Node indices in `func` and `nav` references may be added later;
    /// names come from `addRefName`.
    refs: []const Ref = &.{},
    source: Source = .none,
    /// For a `namespace_name` node, the name it looks up.
    source_name: ?[]const u8 = null,
    /// The unit's result and the node's subject, referring to the
    /// manifest's result items.
    result: []const u32 = &.{},
    subject: []const u32 = &.{},
    /// The unit's type name offers and reads (`results.Names`).
    names: []const u32 = &.{},
    flags: Flags = .{},
};

/// Interns debug source paths; owns its keys.
const FileTable = struct {
    map: std.StringHashMapUnmanaged(u32) = .empty,

    fn deinit(ft: *FileTable, gpa: Allocator) void {
        var it = ft.map.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        ft.map.deinit(gpa);
    }

    /// The index of `path`, which becomes `next` if it is new.
    fn intern(ft: *FileTable, gpa: Allocator, path: []const u8, next: u32) !struct { u32, bool } {
        const gop = try ft.map.getOrPut(gpa, path);
        if (gop.found_existing) return .{ gop.value_ptr.*, false };
        gop.key_ptr.* = gpa.dupe(u8, path) catch |err| {
            ft.map.removeByPtr(gop.key_ptr);
            return err;
        };
        gop.value_ptr.* = next;
        return .{ next, true };
    }
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
    error_symbols: std.ArrayList(u32) = .empty,
    /// Keys this delta numbered.
    symbols: std.ArrayList(Symbol) = .empty,
    symbol_map: SymbolMap = .empty,
    /// Target numbers this delta appended.
    targets_len: u32 = 0,
    files: std.ArrayList(StrRef) = .empty,
    /// Every debug file, filled on first use.
    file_table: FileTable = .{},
    ref_names: std.ArrayList(StrRef) = .empty,
    /// Every reference name, filled on first use.
    ref_name_table: FileTable = .{},
    strings: std.ArrayList(u8) = .empty,
    /// New result items (ids from `base.itemCount()`) and overridden ones:
    /// their words, and where each starts in them.
    item_words: std.ArrayList(u32) = .empty,
    item_starts: std.ArrayList(u32) = .empty,
    overrides: std.ArrayList(ItemOverride) = .empty,
    flags: std.ArrayList(FlagsDelta) = .empty,
    sources: std.ArrayList(SourceDelta) = .empty,
    scratch_numbered: std.ArrayList(NumberedAtom) = .empty,
    scratch_files: std.ArrayList(u32) = .empty,
    scratch_names: std.ArrayList(AtomName) = .empty,
    scratch_targets: std.ArrayList(u32) = .empty,

    pub fn init(gpa: Allocator, base: *const Manifest) Delta {
        return .{ .gpa = gpa, .base = base };
    }

    pub fn deinit(d: *Delta) void {
        const gpa = d.gpa;
        d.nodes.deinit(gpa);
        d.inputs.deinit(gpa);
        d.errors.deinit(gpa);
        d.error_symbols.deinit(gpa);
        d.symbols.deinit(gpa);
        d.symbol_map.deinit(gpa);
        d.files.deinit(gpa);
        d.file_table.deinit(gpa);
        d.ref_names.deinit(gpa);
        d.ref_name_table.deinit(gpa);
        d.strings.deinit(gpa);
        d.item_words.deinit(gpa);
        d.item_starts.deinit(gpa);
        d.overrides.deinit(gpa);
        d.flags.deinit(gpa);
        d.sources.deinit(gpa);
        d.scratch_numbered.deinit(gpa);
        d.scratch_files.deinit(gpa);
        d.scratch_names.deinit(gpa);
        d.scratch_targets.deinit(gpa);
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
        std.debug.assert(n.symbols.len == n.atoms.len);
        const gpa = d.gpa;
        d.scratch_numbered.clearRetainingCapacity();
        d.scratch_files.clearRetainingCapacity();
        d.scratch_names.clearRetainingCapacity();
        d.scratch_targets.clearRetainingCapacity();
        const first_target = d.base.targetsLen() + d.targets_len;
        for (n.symbols) |s| {
            try d.scratch_numbered.append(gpa, .{
                .symbol = try d.symbolNumber(s.key),
                .targets = first_target + @as(u32, @intCast(d.scratch_targets.items.len)),
            });
            for (s.targets) |t| try d.scratch_targets.append(gpa, try d.symbolNumber(t));
            try d.scratch_files.append(gpa, if (s.file) |f| try d.fileIndex(f) else no_file);
            for (s.other_files) |list| {
                var it = std.mem.splitScalar(u8, list, 0);
                while (it.next()) |f| {
                    if (f.len != 0) _ = try d.fileIndex(f);
                }
            }
            const name = try d.addString(s.name);
            try d.scratch_names.append(gpa, .{ .parent = @bitCast(s.parent), .off = name.off, .len = name.len, .prefix_len = s.prefix_len });
        }
        const delta: NodeDelta = .{
            .key = n.key,
            .result_hash = n.result_hash,
            .src_hash = n.src_hash,
            .index = index,
            .deps_len = @intCast(n.deps.len),
            .atoms_len = @intCast(n.atoms.len),
            .targets_len = @intCast(d.scratch_targets.items.len),
            .tag = n.tag,
            .flags = n.flags,
            .refs_len = @intCast(n.refs.len),
            .result_len = @intCast(n.result.len),
            .subject_len = @intCast(n.subject.len),
            .source = n.source,
            .source_name = if (n.source_name) |name| try d.addString(name) else .{ .off = 0, .len = 0 },
            .names_len = @intCast(n.names.len),
        };
        try appendPadded(gpa, &d.nodes, std.mem.asBytes(&delta));
        try appendPadded(gpa, &d.nodes, @ptrCast(n.deps));
        try appendPadded(gpa, &d.nodes, @ptrCast(n.atoms));
        try appendPadded(gpa, &d.nodes, @ptrCast(d.scratch_numbered.items));
        try appendPadded(gpa, &d.nodes, @ptrCast(d.scratch_files.items));
        try appendPadded(gpa, &d.nodes, @ptrCast(d.scratch_names.items));
        try appendPadded(gpa, &d.nodes, @ptrCast(d.scratch_targets.items));
        try appendPadded(gpa, &d.nodes, @ptrCast(n.refs));
        try appendPadded(gpa, &d.nodes, @ptrCast(n.result));
        try appendPadded(gpa, &d.nodes, @ptrCast(n.subject));
        try appendPadded(gpa, &d.nodes, @ptrCast(n.names));
        d.targets_len += delta.targets_len;
        d.n_nodes += 1;
    }

    fn symbolNumber(d: *Delta, key: Hash) !u32 {
        if (d.base.symbol(key)) |n| return n;
        const n, const new = try d.symbol_map.getOrPut(d.gpa, key, d.base.symbolLen() + @as(u32, @intCast(d.symbols.items.len)));
        if (new) try d.symbols.append(d.gpa, .init(key, n));
        return n;
    }

    fn fileIndex(d: *Delta, path: []const u8) !u32 {
        const base_files = d.base.fileCount();
        if (d.file_table.map.count() == 0) {
            for (0..base_files) |i| _ = try d.file_table.intern(d.gpa, d.base.file(@intCast(i)), @intCast(i));
        }
        const index, const new = try d.file_table.intern(d.gpa, path, base_files + @as(u32, @intCast(d.files.items.len)));
        if (new) try d.files.append(d.gpa, try d.addString(path));
        return index;
    }

    /// The value of an `ext`, `ext_weak`, or `rt` reference to `name`.
    pub fn addRefName(d: *Delta, name: []const u8) !u32 {
        if (d.ref_name_table.map.count() == 0) {
            for (0..d.base.refNameCount()) |i| _ = try d.ref_name_table.intern(d.gpa, d.base.refName(@intCast(i)), @intCast(i));
        }
        const index, const new = try d.ref_name_table.intern(d.gpa, name, d.base.refNameCount() + @as(u32, @intCast(d.ref_names.items.len)));
        if (new) try d.ref_names.append(d.gpa, try d.addString(name));
        return index;
    }

    /// Records an input's new stat; `index` null adds an input.
    pub fn setInput(d: *Delta, index: ?u32, path: []const u8, key: []const u8, stat: Io.File.Stat, content_hash: Hash, build_start: Io.Timestamp) !void {
        const i = index orelse i: {
            d.added_inputs += 1;
            break :i d.base.inputCount() + d.added_inputs - 1;
        };
        try d.inputs.append(d.gpa, .{ .input = .init(stat, content_hash, build_start, try d.addString(path), try d.addString(key)), .index = i });
    }

    /// Sets a node's flags, the rest of it unchanged.
    pub fn setFlags(d: *Delta, index: u32, f: Flags) !void {
        try d.flags.append(d.gpa, .{ .node = index, .flags = f });
    }

    /// Sets a node's source, the rest of it unchanged.
    pub fn setSource(d: *Delta, index: u32, src: Source) !void {
        try d.sources.append(d.gpa, .{ .node = index, .source = src });
    }

    /// Adds result items, numbered from `base.itemCount()` in order:
    /// `words`, where item `i` starts at `starts[i]`. Call once.
    pub fn addItems(d: *Delta, words: []const u32, starts: []const u32) !void {
        std.debug.assert(d.item_starts.items.len == 0);
        const at: u32 = @intCast(d.item_words.items.len);
        try d.item_words.appendSlice(d.gpa, words);
        for (starts) |st| try d.item_starts.append(d.gpa, at + st);
    }

    /// Replaces existing result item `id`'s words.
    pub fn overrideItem(d: *Delta, id: u32, words: []const u32) !void {
        try d.overrides.append(d.gpa, .{ .id = id, .start = @intCast(d.item_words.items.len) });
        try d.item_words.appendSlice(d.gpa, words);
    }

    /// Assigns the next error code to `name`, whose symbol key is `key`.
    pub fn addErrorName(d: *Delta, name: []const u8, key: Hash) !u32 {
        try d.errors.append(d.gpa, try d.addString(name));
        try d.error_symbols.append(d.gpa, try d.symbolNumber(key));
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
        try appendPadded(gpa, &body, @ptrCast(d.error_symbols.items));
        try appendPadded(gpa, &body, @ptrCast(d.symbols.items));
        try appendPadded(gpa, &body, @ptrCast(d.files.items));
        try appendPadded(gpa, &body, @ptrCast(d.ref_names.items));
        try appendPadded(gpa, &body, @ptrCast(d.item_starts.items));
        try appendPadded(gpa, &body, @ptrCast(d.item_words.items));
        try appendPadded(gpa, &body, @ptrCast(d.overrides.items));
        try appendPadded(gpa, &body, @ptrCast(d.flags.items));
        try appendPadded(gpa, &body, @ptrCast(d.sources.items));
        try appendPadded(gpa, &body, d.strings.items);
        const header: RecordHeader = .{
            .len = @intCast(@sizeOf(RecordHeader) + body.items.len),
            .hash = std.hash.Wyhash.hash(0, body.items),
            .n_nodes = d.n_nodes,
            .n_inputs = @intCast(d.inputs.items.len),
            .n_errors = @intCast(d.errors.items.len),
            .strings_len = @intCast(d.strings.items.len),
            .n_symbols = @intCast(d.symbols.items.len),
            .n_files = @intCast(d.files.items.len),
            .n_ref_names = @intCast(d.ref_names.items.len),
            .n_items = @intCast(d.item_starts.items.len),
            .item_words = @intCast(d.item_words.items.len),
            .n_flags = @intCast(d.flags.items.len),
            .n_sources = @intCast(d.sources.items.len),
            .n_overrides = @intCast(d.overrides.items.len),
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
    /// Parallel to `atom_refs`. Numbers are the builder's own until `write`
    /// renumbers them.
    numbered: std.ArrayList(NumberedAtom) = .empty,
    debug_files: std.ArrayList(u32) = .empty,
    /// Parallel to `atom_refs`, naming bytes in `atom_name_bytes`.
    atom_names: std.ArrayList(AtomName) = .empty,
    atom_name_bytes: std.ArrayList(u8) = .empty,
    targets: std.ArrayList(u32) = .empty,
    inputs: std.ArrayList(Input) = .empty,
    error_names: std.ArrayList(StrRef) = .empty,
    error_symbols: std.ArrayList(u32) = .empty,
    bases: std.ArrayList(StrRef) = .empty,
    files: std.ArrayList(StrRef) = .empty,
    file_table: FileTable = .{},
    /// Each node's range of `refs`, parallel to `nodes`.
    ref_ranges: std.ArrayList([2]u32) = .empty,
    refs: std.ArrayList(Ref) = .empty,
    ref_names: std.ArrayList(StrRef) = .empty,
    ref_name_table: FileTable = .{},
    /// Parallel to `nodes`.
    sources: std.ArrayList(Source) = .empty,
    source_names: std.ArrayList(SourceName) = .empty,
    /// Each node's range of `results`, parallel to `nodes`.
    result_ranges: std.ArrayList([2]u32) = .empty,
    results: std.ArrayList(u32) = .empty,
    subject_ranges: std.ArrayList([2]u32) = .empty,
    subjects: std.ArrayList(u32) = .empty,
    name_ranges: std.ArrayList([2]u32) = .empty,
    names: std.ArrayList(u32) = .empty,
    /// The results' item table, owned by the caller (or the base, or
    /// `owned_items` when the base's log added to it).
    items: []const u32 = &.{},
    item_starts: []const u32 = &.{},
    owned_items: std.ArrayList(u32) = .empty,
    owned_item_starts: std.ArrayList(u32) = .empty,
    strings: std.ArrayList(u8) = .empty,
    entry: Hash = 0,
    output: Output = .exe,
    link_symbols: std.ArrayList(LinkSymbol) = .empty,
    /// Each number's key.
    symbol_keys: std.ArrayList(Hash) = .empty,
    /// Keys numbered since `base`, or all of them without one.
    symbol_map: SymbolMap = .empty,
    /// The manifest this one started from: finds its nodes, which keep their
    /// indices, and its symbols. Nodes added since are in `added`.
    base: ?*const Manifest = null,
    added: std.AutoHashMapUnmanaged(Hash, u32) = .empty,

    pub fn deinit(b: *Builder) void {
        const gpa = b.gpa;
        b.nodes.deinit(gpa);
        b.edges.deinit(gpa);
        b.atom_refs.deinit(gpa);
        b.numbered.deinit(gpa);
        b.debug_files.deinit(gpa);
        b.atom_names.deinit(gpa);
        b.atom_name_bytes.deinit(gpa);
        b.targets.deinit(gpa);
        b.inputs.deinit(gpa);
        b.error_names.deinit(gpa);
        b.error_symbols.deinit(gpa);
        b.bases.deinit(gpa);
        b.files.deinit(gpa);
        b.file_table.deinit(gpa);
        b.ref_ranges.deinit(gpa);
        b.refs.deinit(gpa);
        b.ref_names.deinit(gpa);
        b.ref_name_table.deinit(gpa);
        b.sources.deinit(gpa);
        b.source_names.deinit(gpa);
        b.result_ranges.deinit(gpa);
        b.results.deinit(gpa);
        b.subject_ranges.deinit(gpa);
        b.subjects.deinit(gpa);
        b.name_ranges.deinit(gpa);
        b.names.deinit(gpa);
        b.owned_items.deinit(gpa);
        b.owned_item_starts.deinit(gpa);
        b.strings.deinit(gpa);
        b.link_symbols.deinit(gpa);
        b.symbol_keys.deinit(gpa);
        b.symbol_map.deinit(gpa);
        b.added.deinit(gpa);
    }

    /// Starts from `base` with its log applied. `base` must stay open while
    /// the builder is used.
    pub fn initFrom(gpa: Allocator, base: *const Manifest) !Builder {
        var b: Builder = .{ .gpa = gpa, .base = base, .entry = base.entry, .output = base.output };
        errdefer b.deinit();
        try b.nodes.appendSlice(gpa, base.nodes);
        try b.edges.appendSlice(gpa, base.edges);
        try b.atom_refs.appendSlice(gpa, base.atom_refs);
        try b.numbered.appendSlice(gpa, base.numbered);
        try b.debug_files.appendSlice(gpa, base.debug_files);
        try b.atom_names.appendSlice(gpa, base.atom_names);
        try b.atom_name_bytes.appendSlice(gpa, base.atom_name_bytes);
        try b.inputs.appendSlice(gpa, base.inputs);
        try b.error_names.appendSlice(gpa, base.error_names);
        try b.bases.appendSlice(gpa, base.bases);
        try b.files.appendSlice(gpa, base.files);
        try b.ref_names.appendSlice(gpa, base.ref_names);
        try b.link_symbols.appendSlice(gpa, base.link_symbols);
        try b.refs.appendSlice(gpa, base.refs);
        try b.ref_ranges.ensureTotalCapacity(gpa, base.nodeCount());
        for (0..base.nodes.len) |i| b.ref_ranges.appendAssumeCapacity(.{ base.ref_starts[i], base.ref_starts[i + 1] - base.ref_starts[i] });
        b.ref_ranges.appendNTimesAssumeCapacity(.{ 0, 0 }, base.nodeCount() - base.nodes.len);
        try b.strings.appendSlice(gpa, base.strings);
        try b.sources.appendSlice(gpa, base.sources);
        try b.sources.appendNTimes(gpa, .none, base.nodeCount() - base.nodes.len);
        try b.source_names.appendSlice(gpa, base.source_names);
        try b.results.appendSlice(gpa, base.results);
        try b.subjects.appendSlice(gpa, base.subjects);
        try b.names.appendSlice(gpa, base.type_names);
        try b.result_ranges.ensureTotalCapacity(gpa, base.nodeCount());
        try b.subject_ranges.ensureTotalCapacity(gpa, base.nodeCount());
        try b.name_ranges.ensureTotalCapacity(gpa, base.nodeCount());
        for (0..base.nodes.len) |i| {
            const changed = base.overlay.nodes.contains(@intCast(i));
            const r = base.result_starts[i];
            b.result_ranges.appendAssumeCapacity(.{ r, if (changed) 0 else base.result_starts[i + 1] - r });
            const sj = base.subject_starts[i];
            b.subject_ranges.appendAssumeCapacity(.{ sj, if (changed) 0 else base.subject_starts[i + 1] - sj });
            const nm = base.type_name_starts[i];
            b.name_ranges.appendAssumeCapacity(.{ nm, if (changed) 0 else base.type_name_starts[i + 1] - nm });
        }
        b.result_ranges.appendNTimesAssumeCapacity(.{ 0, 0 }, base.nodeCount() - base.nodes.len);
        b.subject_ranges.appendNTimesAssumeCapacity(.{ 0, 0 }, base.nodeCount() - base.nodes.len);
        b.name_ranges.appendNTimesAssumeCapacity(.{ 0, 0 }, base.nodeCount() - base.nodes.len);
        const o = &base.overlay;
        if (o.item_starts.items.len == 0 and o.item_overrides.count() == 0) {
            b.items = base.items;
            b.item_starts = base.item_starts;
        } else {
            const at: u32 = @intCast(base.items.len);
            try b.owned_items.appendSlice(gpa, base.items);
            try b.owned_items.appendSlice(gpa, o.item_words.items);
            try b.owned_item_starts.appendSlice(gpa, base.item_starts);
            for (o.item_starts.items) |st| try b.owned_item_starts.append(gpa, at + st);
            var ov = o.item_overrides.iterator();
            while (ov.next()) |e| b.owned_item_starts.items[e.key_ptr.*] = at + e.value_ptr.*;
            b.items = b.owned_items.items;
            b.item_starts = b.owned_item_starts.items;
        }
        // Number space: the base's and the log's, as they are.
        try b.targets.appendSlice(gpa, base.targets);
        try b.targets.appendSlice(gpa, o.targets.items);
        try b.error_symbols.appendSlice(gpa, base.error_symbols);
        try b.error_symbols.appendSlice(gpa, o.error_symbols.items);
        try b.symbol_keys.resize(gpa, base.symbolLen());
        @memset(b.symbol_keys.items, 0);
        for (base.symbols) |s| {
            if (s.number != no_symbol) b.symbol_keys.items[s.number] = s.keyHash();
        }
        for (o.added_symbols.slots) |s| {
            if (s.number != no_symbol) b.symbol_keys.items[s.number] = s.keyHash();
        }
        try b.nodes.resize(gpa, base.nodeCount());
        var fit = o.flags.iterator();
        while (fit.next()) |e| b.nodes.items[e.key_ptr.*].flags = e.value_ptr.*;
        var sit = o.sources.iterator();
        while (sit.next()) |e| b.sources.items[e.key_ptr.*] = e.value_ptr.*;
        var added_names: std.ArrayList(SourceName) = .empty;
        defer added_names.deinit(gpa);
        var nit = o.nodes.iterator();
        while (nit.next()) |e| {
            const s = e.value_ptr;
            b.sources.items[e.key_ptr.*] = s.source;
            if (s.source_name) |name| try added_names.append(gpa, .{ .node = e.key_ptr.*, .name = try b.addString(name) });
            b.result_ranges.items[e.key_ptr.*] = .{ @intCast(b.results.items.len), @intCast(s.result.len) };
            try b.results.appendSlice(gpa, s.result);
            b.subject_ranges.items[e.key_ptr.*] = .{ @intCast(b.subjects.items.len), @intCast(s.subject.len) };
            try b.subjects.appendSlice(gpa, s.subject);
            b.name_ranges.items[e.key_ptr.*] = .{ @intCast(b.names.items.len), @intCast(s.names.len) };
            try b.names.appendSlice(gpa, s.names);
            b.nodes.items[e.key_ptr.*] = .{
                .key = s.delta.key,
                .result_hash = s.delta.result_hash,
                .src_hash = s.delta.src_hash,
                .tag = s.delta.tag,
                .flags = s.flags,
                .deps_start = @intCast(b.edges.items.len),
                .deps_len = @intCast(s.deps.len),
                .rdeps_start = 0,
                .rdeps_len = 0,
                .atoms_start = @intCast(b.atom_refs.items.len),
                .atoms_len = @intCast(s.atoms.len),
                .targets_len = s.delta.targets_len,
            };
            try b.edges.appendSlice(gpa, s.deps);
            try b.atom_refs.appendSlice(gpa, s.atoms);
            try b.numbered.appendSlice(gpa, s.numbered);
            try b.debug_files.appendSlice(gpa, s.debug_files);
            const node_names: AtomNames = .{ .names = s.atom_names, .bytes = s.name_bytes };
            for (s.atom_names, 0..) |an, k| try b.atom_names.append(gpa, .{
                .parent = an.parent,
                .off = (try b.addAtomName(node_names.name(k))).off,
                .len = an.len,
                .prefix_len = an.prefix_len,
            });
            b.ref_ranges.items[e.key_ptr.*] = .{ @intCast(b.refs.items.len), @intCast(s.refs.len) };
            try b.refs.appendSlice(gpa, s.refs);
        }
        std.mem.sortUnstable(SourceName, added_names.items, {}, struct {
            fn lessThan(_: void, x: SourceName, y: SourceName) bool {
                return x.node < y.node;
            }
        }.lessThan);
        // The base's names, but those of nodes the log changed, merged
        // with the log's in node order.
        var kept: usize = 0;
        for (b.source_names.items) |sn| {
            if (o.nodes.contains(sn.node)) continue;
            b.source_names.items[kept] = sn;
            kept += 1;
        }
        b.source_names.shrinkRetainingCapacity(kept);
        try b.source_names.appendSlice(gpa, added_names.items);
        std.mem.sortUnstable(SourceName, b.source_names.items, {}, struct {
            fn lessThan(_: void, x: SourceName, y: SourceName) bool {
                return x.node < y.node;
            }
        }.lessThan);
        var kit = o.added_keys.iterator();
        while (kit.next()) |e| try b.added.put(gpa, e.key_ptr.*, e.value_ptr.*);
        try b.inputs.resize(gpa, base.inputCount());
        var iit = o.inputs.iterator();
        while (iit.next()) |e| {
            var in = e.value_ptr.input;
            in.path = try b.addString(e.value_ptr.path);
            in.key = try b.addString(e.value_ptr.key);
            b.inputs.items[e.key_ptr.*] = in;
        }
        for (o.error_names.items) |name| try b.error_names.append(gpa, try b.addString(name));
        for (o.files.items) |f| try b.files.append(gpa, try b.addString(f));
        for (b.files.items, 0..) |f, i| _ = try b.file_table.intern(gpa, b.strings.items[f.off..][0..f.len], @intCast(i));
        for (o.ref_names.items) |n| try b.ref_names.append(gpa, try b.addString(n));
        for (b.ref_names.items, 0..) |n, i| _ = try b.ref_name_table.intern(gpa, b.strings.items[n.off..][0..n.len], @intCast(i));
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
            .flags = n.flags,
            .deps_start = @intCast(b.edges.items.len),
            .deps_len = @intCast(n.deps.len),
            .rdeps_start = 0,
            .rdeps_len = 0,
            .atoms_start = @intCast(b.atom_refs.items.len),
            .atoms_len = @intCast(n.atoms.len),
            .targets_len = undefined,
        });
        try b.edges.appendSlice(gpa, n.deps);
        b.nodes.items[index].targets_len = try b.appendAtoms(n);
        try b.ref_ranges.append(gpa, .{ @intCast(b.refs.items.len), @intCast(n.refs.len) });
        try b.refs.appendSlice(gpa, n.refs);
        try b.sources.append(gpa, n.source);
        if (n.source_name) |name| try b.source_names.append(gpa, .{ .node = index, .name = try b.addString(name) });
        try b.result_ranges.append(gpa, .{ @intCast(b.results.items.len), @intCast(n.result.len) });
        try b.results.appendSlice(gpa, n.result);
        try b.subject_ranges.append(gpa, .{ @intCast(b.subjects.items.len), @intCast(n.subject.len) });
        try b.subjects.appendSlice(gpa, n.subject);
        try b.name_ranges.append(gpa, .{ @intCast(b.names.items.len), @intCast(n.names.len) });
        try b.names.appendSlice(gpa, n.names);
        return index;
    }

    /// The value of an `ext`, `ext_weak`, or `rt` reference to `name`.
    pub fn addRefName(b: *Builder, name: []const u8) !u32 {
        const index, const new = try b.ref_name_table.intern(b.gpa, name, @intCast(b.ref_names.items.len));
        if (new) try b.ref_names.append(b.gpa, try b.addString(name));
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
        node_ptr.flags = n.flags;
        node_ptr.deps_start = @intCast(b.edges.items.len);
        node_ptr.deps_len = @intCast(n.deps.len);
        node_ptr.atoms_start = @intCast(b.atom_refs.items.len);
        node_ptr.atoms_len = @intCast(n.atoms.len);
        try b.edges.appendSlice(b.gpa, n.deps);
        b.nodes.items[index].targets_len = try b.appendAtoms(n);
        b.ref_ranges.items[index] = .{ @intCast(b.refs.items.len), @intCast(n.refs.len) };
        try b.refs.appendSlice(b.gpa, n.refs);
        // A node keeps its key, so its source and name: only the
        // instruction can move.
        b.sources.items[index] = n.source;
        b.result_ranges.items[index] = .{ @intCast(b.results.items.len), @intCast(n.result.len) };
        try b.results.appendSlice(b.gpa, n.result);
        b.subject_ranges.items[index] = .{ @intCast(b.subjects.items.len), @intCast(n.subject.len) };
        try b.subjects.appendSlice(b.gpa, n.subject);
        b.name_ranges.items[index] = .{ @intCast(b.names.items.len), @intCast(n.names.len) };
        try b.names.appendSlice(b.gpa, n.names);
    }

    /// Reserves room for `n_atoms` more atom references with `n_targets` more
    /// target numbers in all, and about as many new symbols as atoms.
    pub fn ensureUnusedCapacity(b: *Builder, n_atoms: usize, n_targets: usize) !void {
        const gpa = b.gpa;
        try b.atom_refs.ensureUnusedCapacity(gpa, n_atoms);
        try b.numbered.ensureUnusedCapacity(gpa, n_atoms);
        try b.debug_files.ensureUnusedCapacity(gpa, n_atoms);
        try b.atom_names.ensureUnusedCapacity(gpa, n_atoms);
        try b.targets.ensureUnusedCapacity(gpa, n_targets);
        try b.symbol_keys.ensureUnusedCapacity(gpa, n_atoms + n_atoms / 8);
        try b.symbol_map.ensureUnusedCapacity(gpa, n_atoms + n_atoms / 8);
    }

    /// Appends a node's atom references and numbers their symbols; returns
    /// the length of its target run.
    fn appendAtoms(b: *Builder, n: NodeInit) !u32 {
        std.debug.assert(n.symbols.len == n.atoms.len);
        const gpa = b.gpa;
        try b.atom_refs.appendSlice(gpa, n.atoms);
        const first: u32 = @intCast(b.targets.items.len);
        for (n.symbols) |s| {
            try b.numbered.append(gpa, .{ .symbol = try b.symbolNumber(s.key), .targets = @intCast(b.targets.items.len) });
            for (s.targets) |t| try b.targets.append(gpa, try b.symbolNumber(t));
            try b.debug_files.append(gpa, if (s.file) |f| try b.fileIndex(f) else no_file);
            for (s.other_files) |list| {
                var it = std.mem.splitScalar(u8, list, 0);
                while (it.next()) |f| {
                    if (f.len != 0) _ = try b.fileIndex(f);
                }
            }
            const name = try b.addAtomName(s.name);
            try b.atom_names.append(gpa, .{ .parent = @bitCast(s.parent), .off = name.off, .len = name.len, .prefix_len = s.prefix_len });
        }
        return @as(u32, @intCast(b.targets.items.len)) - first;
    }

    fn addAtomName(b: *Builder, name: []const u8) !StrRef {
        const off: u32 = @intCast(b.atom_name_bytes.items.len);
        try b.atom_name_bytes.appendSlice(b.gpa, name);
        return .{ .off = off, .len = @intCast(name.len) };
    }

    fn symbolNumber(b: *Builder, key: Hash) !u32 {
        if (b.base) |m| if (m.symbol(key)) |n| return n;
        const n, const new = try b.symbol_map.getOrPut(b.gpa, key, @intCast(b.symbol_keys.items.len));
        if (new) try b.symbol_keys.append(b.gpa, key);
        return n;
    }

    fn fileIndex(b: *Builder, path: []const u8) !u32 {
        const index, const new = try b.file_table.intern(b.gpa, path, @intCast(b.files.items.len));
        if (new) try b.files.append(b.gpa, try b.addString(path));
        return index;
    }

    /// Replaces every live atom reference, given in node order as
    /// `Manifest.linkInput` lists them, and drops the base packs if no
    /// reference names one: for a manifest written after `Pack.compact` or
    /// `Pack.compactOwn`.
    pub fn setAtomRefs(b: *Builder, refs: []const Pack.AtomRef) !void {
        var i: usize = 0;
        for (b.nodes.items) |n| {
            if (i + n.atoms_len > refs.len) return error.InvalidAtomRefs;
            @memcpy(b.atom_refs.items[n.atoms_start..][0..n.atoms_len], refs[i..][0..n.atoms_len]);
            i += n.atoms_len;
        }
        if (i != refs.len) return error.InvalidAtomRefs;
        // After `Pack.compact`; `Pack.compactOwn` keeps refs into the bases.
        for (refs) |r| {
            if (r.pack != 0) break;
        } else b.bases.clearRetainingCapacity();
    }

    /// Every node's atom refs, in node order, for `setAtomRefs`.
    pub fn nodeAtomRefs(b: *const Builder) ![]Pack.AtomRef {
        var n: usize = 0;
        for (b.nodes.items) |nd| n += nd.atoms_len;
        const refs = try b.gpa.alloc(Pack.AtomRef, n);
        var i: usize = 0;
        for (b.nodes.items) |nd| {
            @memcpy(refs[i..][0..nd.atoms_len], b.atom_refs.items[nd.atoms_start..][0..nd.atoms_len]);
            i += nd.atoms_len;
        }
        return refs;
    }

    /// Records an input file and its stat as of `build_start`.
    pub fn addInput(b: *Builder, path: []const u8, key: []const u8, stat: Io.File.Stat, content_hash: Hash, build_start: Io.Timestamp) !void {
        try b.inputs.append(b.gpa, .init(stat, content_hash, build_start, try b.addString(path), try b.addString(key)));
    }

    /// An input whose stat failed: it never matches, so the next build
    /// hashes it again. Keeps input indices equal to the build's file
    /// indices, which `Source.input` relies on.
    pub fn addUnstattedInput(b: *Builder, path: []const u8, key: []const u8, content_hash: Hash) !void {
        try b.inputs.append(b.gpa, .{ .content_hash = content_hash, .inode = 0, .size = 0, .mtime = Input.racy_mtime, .path = try b.addString(path), .key = try b.addString(key) });
    }

    /// Assigns the next error code to `name`, whose symbol key is `key`.
    /// Codes are only appended, so existing errors keep theirs.
    pub fn addErrorName(b: *Builder, name: []const u8, key: Hash) !u32 {
        try b.error_names.append(b.gpa, try b.addString(name));
        try b.error_symbols.append(b.gpa, try b.symbolNumber(key));
        return @intCast(b.error_names.items.len);
    }

    /// Adds an object's export or import (see `Manifest.link_symbols`).
    pub fn addLinkSymbol(b: *Builder, kind: LinkSymbol.Kind, key: Hash, name: []const u8, link_flags: u32) !void {
        try b.link_symbols.append(b.gpa, .{ .key = key, .name = try b.addString(name), .kind = kind, .flags = link_flags });
    }

    /// Adds a base pack by file name; returns its pack index.
    pub fn addBasePack(b: *Builder, name: []const u8) !u32 {
        try b.bases.append(b.gpa, try b.addString(name));
        return @intCast(b.bases.items.len);
    }

    fn addString(b: *Builder, s: []const u8) !StrRef {
        const off: u32 = @intCast(b.strings.items.len);
        try b.strings.appendSlice(b.gpa, s);
        return .{ .off = off, .len = @intCast(s.len) };
    }

    /// Writes a new base to `dir`, atomically replacing the old one and
    /// leaving its log behind.
    pub fn write(b: *Builder, io: Io, dir: Io.Dir, pack_id: Hash) !void {
        var af = try b.writeUnplaced(io, dir, pack_id);
        defer af.deinit(io);
        try place(&af, io, dir);
    }

    /// `write` without placing the file: `place` makes it the manifest,
    /// `deinit` discards it.
    pub fn writeUnplaced(b: *Builder, io: Io, dir: Io.Dir, pack_id: Hash) !Io.File.Atomic {
        const gpa = b.gpa;
        const nodes = try gpa.dupe(Node, b.nodes.items);
        defer gpa.free(nodes);
        const entry_old: u32 = if (b.entry != 0) try b.symbolNumber(b.entry) else no_symbol;

        // Compact edges, atom references, and target runs, dropping
        // replaced ranges, unless there are none and they are in order, as
        // when every node was added to an empty builder.
        var edge_count: usize = 0;
        var ref_count: usize = 0;
        var target_count: usize = 0;
        var in_order = true;
        for (nodes) |n| {
            if (n.deps_start != edge_count or n.atoms_start != ref_count or
                (n.atoms_len != 0 and b.numbered.items[n.atoms_start].targets != target_count)) in_order = false;
            edge_count += n.deps_len;
            ref_count += n.atoms_len;
            target_count += n.targets_len;
        }
        for (b.edges.items) |d| {
            if (Edge.nodeOf(d) >= nodes.len) return error.InvalidNodeIndex;
        }
        // References, in node order.
        const ref_starts = try gpa.alloc(u32, nodes.len + 1);
        defer gpa.free(ref_starts);
        var node_refs: std.ArrayList(Ref) = try .initCapacity(gpa, b.refs.items.len);
        defer node_refs.deinit(gpa);
        for (b.ref_ranges.items, 0..) |range, i| {
            ref_starts[i] = @intCast(node_refs.items.len);
            for (b.refs.items[range[0]..][0..range[1]]) |r| {
                switch (r.kind) {
                    .func, .nav, .effects, .root, .defaults => if (r.value >= nodes.len) return error.InvalidNodeIndex,
                    .ext, .ext_weak, .rt, .import => if (r.value >= b.ref_names.items.len) return error.InvalidRefName,
                    .err, .error_names, .analyze, .quota => {},
                }
                node_refs.appendAssumeCapacity(r);
            }
        }
        ref_starts[nodes.len] = @intCast(node_refs.items.len);
        // Results and subjects, in node order.
        const result_starts = try gpa.alloc(u32, nodes.len + 1);
        defer gpa.free(result_starts);
        var compacted_results: std.ArrayList(u32) = .empty;
        defer compacted_results.deinit(gpa);
        const node_results = try inNodeOrder(gpa, b.result_ranges.items, b.results.items, result_starts, &compacted_results);
        const subject_starts = try gpa.alloc(u32, nodes.len + 1);
        defer gpa.free(subject_starts);
        var compacted_subjects: std.ArrayList(u32) = .empty;
        defer compacted_subjects.deinit(gpa);
        const node_subjects = try inNodeOrder(gpa, b.subject_ranges.items, b.subjects.items, subject_starts, &compacted_subjects);
        const name_starts = try gpa.alloc(u32, nodes.len + 1);
        defer gpa.free(name_starts);
        var compacted_names: std.ArrayList(u32) = .empty;
        defer compacted_names.deinit(gpa);
        const node_names = try inNodeOrder(gpa, b.name_ranges.items, b.names.items, name_starts, &compacted_names);
        var name_index: std.ArrayList(TypeNameRef) = .empty;
        defer name_index.deinit(gpa);
        for (0..nodes.len) |i| {
            var reader: result_codec.Names.Reader = .init(node_names[name_starts[i]..name_starts[i + 1]]);
            while (reader.nextOffer()) |o| try name_index.append(gpa, .{ .ty = o.ty, .creator = o.creator, .node = @intCast(i), .won = @intFromBool(o.won.len != 0) });
        }
        std.mem.sortUnstable(TypeNameRef, name_index.items, {}, TypeNameRef.lessThan);
        const numbered = try gpa.alloc(NumberedAtom, ref_count);
        defer gpa.free(numbered);
        const targets = try gpa.alloc(u32, target_count);
        defer gpa.free(targets);
        var compacted: struct { edges: []u32 = &.{}, refs: []Pack.AtomRef = &.{}, debug_files: []u32 = &.{}, atom_names: []AtomName = &.{}, atom_name_bytes: std.ArrayList(u8) = .empty } = .{};
        defer {
            gpa.free(compacted.edges);
            gpa.free(compacted.refs);
            gpa.free(compacted.debug_files);
            gpa.free(compacted.atom_names);
            compacted.atom_name_bytes.deinit(gpa);
        }
        var edges: []const u32 = b.edges.items;
        var refs: []const Pack.AtomRef = b.atom_refs.items;
        var debug_files: []const u32 = b.debug_files.items;
        var atom_names: []const AtomName = b.atom_names.items;
        var atom_name_bytes: []const u8 = b.atom_name_bytes.items;
        if (in_order and edge_count == edges.len and ref_count == refs.len and target_count == b.targets.items.len) {
            @memcpy(numbered, b.numbered.items);
            @memcpy(targets, b.targets.items);
        } else {
            compacted.edges = try gpa.alloc(u32, edge_count);
            compacted.refs = try gpa.alloc(Pack.AtomRef, ref_count);
            compacted.debug_files = try gpa.alloc(u32, ref_count);
            compacted.atom_names = try gpa.alloc(AtomName, ref_count);
            edge_count = 0;
            ref_count = 0;
            target_count = 0;
            for (nodes) |*n| {
                @memcpy(compacted.edges[edge_count..][0..n.deps_len], b.edges.items[n.deps_start..][0..n.deps_len]);
                n.deps_start = @intCast(edge_count);
                edge_count += n.deps_len;
                const node_numbered = b.numbered.items[n.atoms_start..][0..n.atoms_len];
                @memcpy(compacted.refs[ref_count..][0..n.atoms_len], b.atom_refs.items[n.atoms_start..][0..n.atoms_len]);
                @memcpy(compacted.debug_files[ref_count..][0..n.atoms_len], b.debug_files.items[n.atoms_start..][0..n.atoms_len]);
                // Only live names' bytes: replaced atoms' go.
                const live_names: AtomNames = .{ .names = b.atom_names.items[n.atoms_start..][0..n.atoms_len], .bytes = b.atom_name_bytes.items };
                for (compacted.atom_names[ref_count..][0..n.atoms_len], live_names.names, 0..) |*out, in, k| {
                    out.* = in;
                    out.off = @intCast(compacted.atom_name_bytes.items.len);
                    try compacted.atom_name_bytes.appendSlice(gpa, live_names.name(k));
                }
                if (n.atoms_len != 0) {
                    const old_first = node_numbered[0].targets;
                    @memcpy(targets[target_count..][0..n.targets_len], b.targets.items[old_first..][0..n.targets_len]);
                    for (numbered[ref_count..][0..n.atoms_len], node_numbered) |*out, in| {
                        out.* = .{ .symbol = in.symbol, .targets = @intCast(target_count + (in.targets - old_first)) };
                    }
                }
                n.atoms_start = @intCast(ref_count);
                ref_count += n.atoms_len;
                target_count += n.targets_len;
            }
            edges = compacted.edges;
            refs = compacted.refs;
            debug_files = compacted.debug_files;
            atom_names = compacted.atom_names;
            atom_name_bytes = compacted.atom_name_bytes.items;
        }

        // Renumber in link order: the atoms, then targets no atom defines,
        // then error codes and the entry. Keys nothing uses lose their
        // numbers.
        const new_of = try gpa.alloc(u32, b.symbol_keys.items.len);
        defer gpa.free(new_of);
        @memset(new_of, no_symbol);
        var next: u32 = 0;
        for (numbered) |*na| {
            if (new_of[na.symbol] != no_symbol) return error.DuplicateSymbol;
            new_of[na.symbol] = next;
            na.symbol = next;
            next += 1;
        }
        const renumber = struct {
            fn f(map: []u32, n: *u32, old: u32) u32 {
                if (map[old] == no_symbol) {
                    map[old] = n.*;
                    n.* += 1;
                }
                return map[old];
            }
        }.f;
        for (targets) |*t| t.* = renumber(new_of, &next, t.*);
        const error_symbols = try gpa.alloc(u32, b.error_symbols.items.len);
        defer gpa.free(error_symbols);
        for (error_symbols, b.error_symbols.items) |*out, old| out.* = renumber(new_of, &next, old);
        const entry_symbol = if (entry_old != no_symbol) renumber(new_of, &next, entry_old) else no_symbol;
        const symbols = try gpa.alloc(Symbol, @as(usize, next) + next / 4 + 16);
        defer gpa.free(symbols);
        @memset(symbols, .{ .key = .{ 0, 0 }, .number = no_symbol });
        for (b.symbol_keys.items, new_of) |key, n| {
            if (n == no_symbol) continue;
            var slot = symbolSlot(key, symbols.len);
            while (symbols[slot].number != no_symbol) {
                slot += 1;
                if (slot == symbols.len) slot = 0;
            }
            symbols[slot] = .init(key, n);
        }

        // Reverse edges: count, prefix sums, fill.
        for (nodes) |*n| n.rdeps_len = 0;
        for (edges) |d| nodes[Edge.nodeOf(d)].rdeps_len += 1;
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
                const t = &nodes[Edge.nodeOf(d)];
                redges[t.rdeps_start + t.rdeps_len] = @intCast(i);
                t.rdeps_len += 1;
            }
        }

        // Reverse references, the same way.
        const rref_starts = try gpa.alloc(u32, nodes.len + 1);
        defer gpa.free(rref_starts);
        @memset(rref_starts, 0);
        for (node_refs.items) |r| if (reachRef(r.kind)) {
            rref_starts[r.value + 1] += 1;
        };
        for (1..rref_starts.len) |i| rref_starts[i] += rref_starts[i - 1];
        const rrefs_out = try gpa.alloc(u32, rref_starts[nodes.len]);
        defer gpa.free(rrefs_out);
        {
            const fill = try gpa.dupe(u32, rref_starts[0..nodes.len]);
            defer gpa.free(fill);
            for (0..nodes.len) |i| for (node_refs.items[ref_starts[i]..ref_starts[i + 1]]) |r| if (reachRef(r.kind)) {
                rrefs_out[fill[r.value]] = @intCast(i);
                fill[r.value] += 1;
            };
        }

        const debug_atoms = try debugAtoms(gpa, debug_files);
        defer gpa.free(debug_atoms);

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

        var header: Header = .{
            .id = undefined,
            .pack_id = pack_id,
            .entry = b.entry,
            .output = b.output,
            .symbol_len = next,
            .entry_symbol = entry_symbol,
            .unlinked = n_unlinked: {
                var n: u32 = 0;
                for (nodes) |nd| n += @intFromBool(nd.flags.unlinked);
                break :n_unlinked n;
            },
            .sections = undefined,
        };
        io.random(std.mem.asBytes(&header.id));
        const parts: [std.enums.values(Section).len][]const u8 = .{
            @ptrCast(nodes),
            @ptrCast(table),
            @ptrCast(edges),
            @ptrCast(redges),
            @ptrCast(rref_starts),
            @ptrCast(rrefs_out),
            @ptrCast(refs),
            @ptrCast(b.inputs.items),
            @ptrCast(b.error_names.items),
            @ptrCast(b.bases.items),
            @ptrCast(symbols),
            @ptrCast(numbered),
            @ptrCast(targets),
            @ptrCast(error_symbols),
            @ptrCast(debug_files),
            @ptrCast(debug_atoms),
            @ptrCast(b.files.items),
            @ptrCast(ref_starts),
            @ptrCast(node_refs.items),
            @ptrCast(b.ref_names.items),
            @ptrCast(b.sources.items),
            @ptrCast(b.source_names.items),
            @ptrCast(b.items),
            @ptrCast(b.item_starts),
            @ptrCast(node_results),
            @ptrCast(result_starts),
            @ptrCast(node_subjects),
            @ptrCast(subject_starts),
            @ptrCast(b.link_symbols.items),
            @ptrCast(node_names),
            @ptrCast(name_starts),
            @ptrCast(name_index.items),
            @ptrCast(atom_names),
            atom_name_bytes,
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
        errdefer af.deinit(io);
        var w = af.file.writerStreaming(io, &.{});
        w.interface.writeVecAll(&vecs) catch return w.err.?;
        w.interface.flush() catch return w.err.?;
        return af;
    }

    /// The words of each node's range of `data`, in node order, with each
    /// node's start in `starts` (one more than the nodes): `data` as it is
    /// if every node was added in order to an empty builder, else a copy in
    /// `compacted`.
    fn inNodeOrder(gpa: Allocator, ranges: []const [2]u32, data: []const u32, starts: []u32, compacted: *std.ArrayList(u32)) ![]const u32 {
        var len: u32 = 0;
        const in_order = for (ranges, 0..) |range, i| {
            if (range[0] != len and range[1] != 0) break false;
            starts[i] = len;
            len += range[1];
        } else len == data.len;
        if (in_order) {
            starts[ranges.len] = len;
            return data;
        }
        try compacted.ensureTotalCapacity(gpa, data.len);
        for (ranges, 0..) |range, i| {
            starts[i] = @intCast(compacted.items.len);
            compacted.appendSliceAssumeCapacity(data[range[0]..][0..range[1]]);
        }
        starts[ranges.len] = @intCast(compacted.items.len);
        return compacted.items;
    }

    /// Makes a file from `writeUnplaced` the manifest in `dir`.
    pub fn place(af: *Io.File.Atomic, io: Io, dir: Io.Dir) !void {
        try af.replace(io);
        // The new base's id makes the old log inapplicable; this only tidies.
        dir.deleteFile(io, log_name) catch {};
    }
};

test "manifest round-trip, lookups, reverse edges, log records, and folding" {
    // One offer each for the type with stable hash 0x77 (`results.Names`):
    // creator, no recorded name, the template "S", no holes, no reads.
    const names_1 = [_]u32{ 1, 0x77, 0, 0, 0, 1, 0, 0, 0, 0, 1, 'S', 0, 0 };
    const names_4 = [_]u32{ 1, 0x77, 0, 0, 0, 2, 0, 0, 0, 0, 1, 'S', 0, 0 };
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
        // Symbol keys are 0xa.. for atoms, 0xe.. for errors.
        _ = try b.addNode(.{ .key = 100, .result_hash = 1 });
        const memcpy = try b.addRefName("memcpy");
        _ = try b.addNode(.{ .key = 101, .result_hash = 2, .src_hash = 7, .deps = &.{0}, .atoms = &.{.init(32, 64)}, .symbols = &.{
            .{ .key = 0xa1, .targets = &.{ 0xa3, 0xe1 }, .file = "a.zig", .name = "T.f", .parent = 0x55, .prefix_len = 1 },
        }, .refs = &.{ .{ .kind = .func, .value = 3 }, .{ .kind = .ext, .value = memcpy }, .{ .kind = .err, .value = 2 }, .{ .kind = .error_names, .value = 0 } }, .source = .{ .input = 0, .inst = 12 }, .result = &.{ 7, 8, 9 }, .names = &names_1 });
        // Node 2's dependency on node 0 is conditional.
        _ = try b.addNode(.{ .key = 102, .result_hash = 3, .deps = &.{ 1, Edge.init(0, .conditional), 3 }, .source = .{ .input = 0, .inst = 0 }, .source_name = "x", .result = &.{5} });
        b.items = &.{ 1, 2, 3, 4, 5, 6 };
        b.item_starts = &.{ 0, 5 };
        _ = try b.addNode(.{ .key = 103, .result_hash = 4, .atoms = &.{.init(160, 16)}, .symbols = &.{
            .{ .key = 0xa3, .targets = &.{ 0xa1, 0xb0 }, .name = "c" },
        } });
        try b.addInput(a_path, "root:a.zig", try tmp.dir.statFile(io, "a.zig", .{}), 55, Io.Clock.real.now(io));
        try t.expectEqual(1, try b.addErrorName("OutOfMemory", 0xe1));
        try t.expectEqual(2, try b.addErrorName("Overflow", 0xe2));
        b.entry = 0xa1;
        b.output = .lib;
        try b.addLinkSymbol(.@"export", 0xa1, "zap_add", 0);
        try b.addLinkSymbol(.import, 0xb0, "c_twice", 1);
        try b.write(io, tmp.dir, 0xabc);
    }
    var m = (try Manifest.open(gpa, io, tmp.dir)).?;
    defer m.close(gpa, io);
    try t.expectEqual(0xabc, m.pack_id);
    try t.expectEqual(2, m.find(102));
    try t.expectEqual(null, m.find(999));
    try t.expectEqualSlices(u32, &.{ 1, Edge.init(0, .conditional), 3 }, m.deps(2));
    try t.expectEqual(0, Edge.nodeOf(m.deps(2)[1]));
    try t.expectEqualSlices(u32, &.{ 1, 2 }, m.rdeps(0)[0]);
    try t.expectEqualSlices(u32, &.{}, m.result(0));
    try t.expectEqualSlices(u32, &.{ 7, 8, 9 }, m.result(1));
    try t.expectEqualSlices(u32, &.{5}, m.result(2));
    try t.expectEqualSlices(u32, &.{ 0, 5 }, m.item_starts);
    try t.expectEqualSlices(u32, &.{2}, m.rdeps(1)[0]);
    try t.expectEqual(64, m.atoms(1)[0].len);
    try t.expectEqualStrings("Overflow", m.errorName(2));
    // Numbered in link order: atoms, then other targets, then errors.
    {
        const in = try m.linkInput(gpa);
        try t.expectEqual(5, m.symbolLen());
        try t.expectEqual(0, m.entry_symbol);
        try t.expectEqual(1, m.symbol(0xa3));
        try t.expectEqual(null, m.symbol(0xa2));
        try t.expectEqualSlices(NumberedAtom, &.{ .{ .symbol = 0, .targets = 0 }, .{ .symbol = 1, .targets = 2 } }, in.numbered);
        try t.expectEqualSlices(u32, &.{ 1, 2, 0, 3 }, in.targets);
        try t.expectEqual(4, m.errorSymbol(2));
        try t.expectEqualSlices(u32, &.{ 0, no_file }, in.debug_files);
        try t.expectEqualSlices(u32, &.{0}, in.debug_atoms);
        try t.expectEqualStrings("a.zig", m.file(0));
    }
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
        const rt = try d.addRefName("compiler_rt:x");
        try t.expectEqual(1, rt);
        try d.update(2, .{ .key = 102, .result_hash = 33, .deps = &.{3}, .atoms = &.{.init(96, 48)}, .symbols = &.{
            .{ .key = 0xa2, .targets = &.{ 0xa1, 0xc0 }, .file = "b.zig" },
        }, .refs = &.{ .{ .kind = .rt, .value = rt }, .{ .kind = .nav, .value = 0 } } });
        try t.expectEqual(4, try d.addNode(.{ .key = 104, .result_hash = 5, .deps = &.{2} }));
        try d.setInput(0, a_path, "root:a.zig", try tmp.dir.statFile(io, "a.zig", .{}), 56, .fromNanoseconds(std.math.maxInt(i64)));
        try t.expectEqual(3, try d.addErrorName("Unexpected", 0xe3));
        try d.append(io, tmp.dir);
    }
    var m2 = (try Manifest.open(gpa, io, tmp.dir)).?;
    {
        defer m2.close(gpa, io);
        var d: Delta = .init(gpa, &m2);
        defer d.deinit();
        // Node 2 again, now without its target 0xc0, which no atom uses
        // any more but keeps its number until the next base.
        try t.expectEqual(6, m2.symbol(0xc0));
        try d.update(2, .{ .key = 102, .result_hash = 33, .deps = &.{3}, .atoms = &.{.init(96, 48)}, .symbols = &.{
            .{ .key = 0xa2, .targets = &.{0xa1}, .file = "b.zig", .name = "b2" },
        }, .refs = &.{ .{ .kind = .rt, .value = try d.addRefName("compiler_rt:x") }, .{ .kind = .nav, .value = 0 } } });
        try d.update(4, .{ .key = 104, .result_hash = 6, .deps = &.{2}, .atoms = &.{.init(208, 16)}, .symbols = &.{
            .{ .key = 0xa4, .targets = &.{ 0xa2, 0xe3 }, .file = "a.zig", .name = "d" },
        }, .refs = &.{.{ .kind = .ext_weak, .value = try d.addRefName("memcpy") }}, .result = &.{ 70, 71 }, .subject = &.{72}, .names = &names_4, .source = .{ .input = 1, .inst = 5 }, .flags = .{ .stale = true } });
        // A new result item after the base's two, and the first replaced;
        // a node's source and another's flags, the rest of them as they
        // were.
        try d.addItems(&.{ 20, 21, 22, 23, 24, 25 }, &.{0});
        try d.overrideItem(0, &.{ 30, 31, 32, 33, 34 });
        try d.setSource(1, .{ .input = 0, .inst = 13 });
        try d.setFlags(0, .{ .stale = true });
        try d.setInput(null, b_path, "root:b.zig", try tmp.dir.statFile(io, "b.zig", .{}), 57, .fromNanoseconds(std.math.maxInt(i64)));
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
            try t.expectEqual(Output.lib, m3.output);
            try t.expectEqual(2, m3.link_symbols.len);
            try t.expectEqual(LinkSymbol.Kind.import, m3.link_symbols[1].kind);
            try t.expectEqual(1, m3.link_symbols[1].flags);
            try t.expectEqual(0xb0, m3.link_symbols[1].key);
            try t.expectEqualStrings("c_twice", m3.string(m3.link_symbols[1].name));
            try t.expectEqual(33, m3.node(2).result_hash);
            try t.expectEqual(6, m3.node(4).result_hash);
            try t.expectEqual(4, m3.find(104));
            try t.expectEqualSlices(u32, &.{3}, m3.deps(2));
            // A node the log changed has no result; the others keep theirs.
            try t.expectEqualSlices(u32, &.{ 7, 8, 9 }, m3.result(1));
            try t.expectEqualSlices(u32, &names_1, m3.typeNames(1));
            try t.expectEqualSlices(u32, &.{}, m3.result(2));
            try t.expectEqualSlices(u32, &.{ 70, 71 }, m3.result(4));
            try t.expectEqualSlices(u32, &.{72}, m3.subject(4));
            try t.expectEqualSlices(u32, &names_4, m3.typeNames(4));
            // The index is the base's: node 4 is in the log until a fold.
            const offers = m3.typeNameNodes(0x77);
            try t.expectEqual(@as(usize, if (m3.overlay.len == 0) 2 else 1), offers.len);
            try t.expectEqual(1, offers[0].creator);
            try t.expectEqual(1, offers[0].node);
            if (m3.overlay.len == 0) try t.expectEqual(4, offers[1].node);
            try t.expectEqual(0, m3.typeNameNodes(0x76).len);
            const items = m3.resultItems();
            try t.expectEqual(3, m3.itemCount());
            for ([_]u32{ 30, 6, 20 }, 0..) |first, id| {
                const words, const at = items.at(@intCast(id));
                try t.expectEqual(first, words[at]);
            }
            try t.expectEqual(true, m3.flags(0).stale);
            try t.expectEqual(true, m3.flags(4).stale);
            try t.expectEqual(false, m3.flags(2).stale);
            try t.expectEqual(96, m3.atoms(2)[0].offset());
            try t.expectEqualStrings("OutOfMemory", m3.errorName(1));
            try t.expectEqualStrings("Unexpected", m3.errorName(3));
            try t.expectEqual(2, m3.inputCount());
            try t.expectEqual(57, m3.input(1)[0].content_hash);
            try t.expectEqualStrings("root:b.zig", m3.inputKey(1));
            try t.expectEqual(56, m3.input(0)[0].content_hash);
            // References, with names from the base and the log.
            try t.expectEqual(2, m3.refNameCount());
            const r1 = m3.nodeRefs(1);
            try t.expectEqual(4, r1.len);
            try t.expectEqual(Ref{ .kind = .func, .value = 3 }, r1[0]);
            try t.expectEqualStrings("memcpy", m3.refName(r1[1].value));
            try t.expectEqual(Ref{ .kind = .err, .value = 2 }, r1[2]);
            try t.expectEqual(Ref.Kind.error_names, r1[3].kind);
            const r2 = m3.nodeRefs(2);
            try t.expectEqual(2, r2.len);
            try t.expectEqualStrings("compiler_rt:x", m3.refName(r2[0].value));
            try t.expectEqual(Ref{ .kind = .nav, .value = 0 }, r2[1]);
            try t.expectEqual(0, m3.nodeRefs(3).len);
            try t.expectEqual(Ref.Kind.ext_weak, m3.nodeRefs(4)[0].kind);
            try t.expectEqualStrings("memcpy", m3.refName(m3.nodeRefs(4)[0].value));
            var refs: std.ArrayList(u64) = .empty;
            defer refs.deinit(gpa);
            for (try m3.allAtomRefs(gpa)) |r| try refs.append(gpa, r.offset());
            try t.expectEqualSlices(u64, &.{ 32, 96, 160, 208 }, refs.items);
            // The numbers can change when a base is written; what they
            // stand for cannot.
            const in = try m3.linkInput(gpa);
            const expected = [_]struct { Hash, []const Hash, ?[]const u8, []const u8 }{
                .{ 0xa1, &.{ 0xa3, 0xe1 }, "a.zig", "T.f" },
                .{ 0xa2, &.{0xa1}, "b.zig", "b2" },
                .{ 0xa3, &.{ 0xa1, 0xb0 }, null, "c" },
                .{ 0xa4, &.{ 0xa2, 0xe3 }, "a.zig", "d" },
            };
            try t.expectEqual(expected.len, in.numbered.len);
            // Symbol names, from the base and the log, and what renames
            // them.
            for (expected, in.names) |e, name| try t.expectEqualStrings(e[3], name);
            try t.expectEqualStrings("b2", m3.atomNames(2).name(0));
            try t.expectEqual(0x55, m3.atomNames(1).names[0].parentHash());
            try t.expectEqual(1, m3.atomNames(1).names[0].prefix_len);
            try t.expectEqual(0, m3.atomNames(4).names[0].parentHash());
            for (expected, in.numbered, in.debug_files) |e, na, f| {
                try t.expectEqual(m3.symbol(e[0]).?, na.symbol);
                const runs = if (na.targets < in.targets.len) in.targets[na.targets..] else in.targets_tail[na.targets - in.targets.len ..];
                for (e[1], runs[0..e[1].len]) |key, number| try t.expectEqual(m3.symbol(key).?, number);
                if (e[2]) |name| try t.expectEqualStrings(name, m3.file(f)) else try t.expectEqual(no_file, f);
            }
            try t.expectEqualSlices(u32, &.{ 0, 1, 3 }, in.debug_atoms);
            try t.expectEqual(m3.symbol(0xe3).?, m3.errorSymbol(3));
            try t.expectEqual(m3.symbol(0xe2).?, m3.errorSymbol(2));
            try t.expectEqual(m3.symbol(0xa1).?, m3.entry_symbol);
            // Sources: node 2's update has none.
            try t.expectEqual(Source.none, m3.source(0));
            try t.expectEqual(Source{ .input = 0, .inst = 13 }, m3.source(1));
            try t.expectEqual(Source.none, m3.source(2));
            try t.expectEqual(null, m3.sourceName(2));
            try t.expectEqual(null, m3.sourceName(1));
            try t.expectEqual(Source{ .input = 1, .inst = 5 }, m3.source(4));
        }
    }.check;
    var m3 = (try Manifest.open(gpa, io, tmp.dir)).?;
    try expectLogged(&m3);
    // The log's reverse edges join the base's, which keep node 2's old
    // dependency on node 0 until the next base.
    try t.expectEqualSlices(u32, &.{ 1, 2 }, m3.rdeps(0)[0]);
    try t.expectEqualSlices(u32, &.{ 2, 2 }, m3.rdeps(3)[1]);
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
        try t.expectEqual(9, m4.symbolLen());
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
    // Only live atoms' names.
    try t.expectEqualStrings("T.fb2cd", m5.atom_name_bytes);
    // Renumbered in link order, without 0xc0.
    try t.expectEqual(8, m5.symbolLen());
    try t.expectEqual(null, m5.symbol(0xc0));
    for ((try m5.linkInput(gpa)).numbered, 0..) |na, i| try t.expectEqual(i, na.symbol);
    try t.expectEqualSlices(u32, &.{1}, m5.rdeps(0)[0]);
    try t.expectEqualSlices(u32, &.{4}, m5.rdeps(2)[0]);

    // The link needs each key defined once.
    var b: Builder = .{ .gpa = gpa };
    defer b.deinit();
    _ = try b.addNode(.{ .key = 1, .result_hash = 0, .atoms = &.{.init(0, 16)}, .symbols = &.{.{ .key = 0xa1, .targets = &.{} }} });
    _ = try b.addNode(.{ .key = 2, .result_hash = 0, .atoms = &.{.init(16, 16)}, .symbols = &.{.{ .key = 0xa1, .targets = &.{} }} });
    try t.expectError(error.DuplicateSymbol, b.write(io, tmp.dir, 0xabc));
}
