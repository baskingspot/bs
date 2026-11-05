# bs architecture

This document fixes the boundaries between bs's stages so that the speed
features in AGENTS.md (the on-disk per-declaration cache, parallel analysis of
function bodies, the bytecode comptime evaluator, fast SSA backends, and write-once
linkers) can land later without redesigning the stages. AGENTS.md holds the
scope and the settled decisions; this file says how they fit together. Change
it when a boundary changes.

## Pipeline

```
source ──Ast.parse──▶ AST ──AstGen──▶ ZIR            (std.zig, per file, parallel, cached)
ZIR ──Sema──▶ InternPool (types, values)             (bs, per analysis unit)
            └▶ typed IR (one function at a time)
typed IR ──CodeGen──▶ Atom (machine code + symbolic relocations)   (per function, parallel, cached)
Atoms ──Linker──▶ ELF / Mach-O, written once
```

### Frontend (`src/Frontend.zig`)

- Uses `std.zig.Ast.parse` and `std.zig.AstGen.generate` unchanged.
- Like upstream, lowers every file reachable through `@import` eagerly, so
  syntax errors in unreferenced files are reported the same way upstream
  reports them.
- Files are discovered and lowered from a work queue: lowering a file
  reveals its imports. File indices are assigned afterwards, breadth-first
  in import order from the root, so they do not depend on thread timing.
- ZIR is cached on disk per file, in `<cache>/bs/zir/`. Every file's
  ZIR is in the global cache, keyed by content, so that a project's ZIR
  outlives its local cache and its worktrees and copies share it; each
  cache's index holds the stats of its own files: the local cache's the
  project's modules', the global cache's std's (shared by every project).
  The directories are resolved like `zig build-exe`: `--cache-dir`,
  `ZIG_LOCAL_CACHE_DIR`, or the `.zig-cache` next to the nearest `build.zig`,
  else the global cache (always for `run`); `--global-cache-dir`,
  `ZIG_GLOBAL_CACHE_DIR`, or `~/.cache/zig`.
  - `<32 hex digits>` (global cache): one source text's ZIR, named by a
    128-bit hash of the source salted with the Zig version. A header and
    the file's import names and error flag come first, then the ZIR arrays
    at their natural alignment, so the file is mapped and used in place.
    Written to an unnamed temporary file and linked into place; never
    modified but for its mtime, which a build that maps it renews once a
    day (the `fstat` the mapping needs anyway tells when). The local cache
    holds ZIR only if the global one cannot be opened.
  - `index` (both caches): sorted fixed-size records (path hash, inode,
    size, mtime, content hash), read whole at startup and replaced through
    a temporary file when a build learns new stats. Concurrent builds lose
    at most each other's new records, which costs a rehash, not
    correctness. A file modified within 2 s of the build's start is
    recorded with an mtime that never matches, so a same-tick edit cannot
    hide behind an unchanged stat. A record whose ZIR is gone (trimmed, or
    in a local cache from before ZIR moved to the global one) is a probe
    miss: the file is hashed, and lowered if no ZIR has its content.
  - Trimming: the global cache's ZIR counts toward `BS_CACHE_MAX_SIZE`
    and goes with the store's packs (`Store.maintain`): unused for 5 days
    by its mtime, or least recently used first past the limit. The
    store's maintenance runs daily, whenever its packs alone pass the
    limit, and at least every 10 minutes from any build, one that commits
    no pack too (`Store.maintainStale`), so new ZIR and donors count
    within minutes.
  - Superseded ZIR goes sooner (`CacheDir.sweepSuperseded`): when a build's
    index update replaces a file's content hash, the old ZIR file's mtime
    is set two days back and its hash goes on that cache's `superseded`
    list. Any build that maps it afterwards renews the mtime, as for any
    use. A later index update (or the daily trim) deletes a listed file
    whose mark is still there an hour after it was superseded, and drops
    renewed, missing and reindexed ones from the list. A worktree that
    still has that source but did not build within the hour lowers it
    again: a cost, not a wrong result. Comparing an edited file's old ZIR
    with its new (`loadOldZir`, the seeds) does not renew it. The marked
    mtime also makes superseded ZIR the first to go past the size limit.
  - `superseded` (both caches): `Superseded` records (content hash,
    when), replaced whole.
- A file is first *probed*: stat it and, if the index matches, take its
  imports and whether it has AstGen errors from the index (each entry
  keeps its summary, ZAPZIX02), without opening its ZIR. The ZIR is mapped
  on first use (`Frontend.file`, once per file under its mutex): most files
  a build reaches are never analyzed, or replay from the cache without
  their ZIR (a zls body edit uses the ZIR of 59 of its 610 files). A file
  with errors is mapped at once, for its messages. A stat hit renews its
  ZIR's mtime once a day (`IndexEntry.renewed_ns`), as mapping it would,
  so the global cache's maintenance keeps it; ZIR that is gone by its
  first use (trimmed, or superseded by another worktree's edit) is
  lowered again from the source, which must still have the indexed
  content, and cached again. Measured on the zls body edit (2026-11-04,
  ReleaseFast, median of 15, two rounds): frontend 6.1 / 6.2 → 4.5 /
  4.7 ms, sema 35.2 / 37.3 → 37.1 / 37.7 ms (the 59 files are now mapped
  there), wall 71.5 / 73.9 → 69.7 / 71.3 ms; the rest of the frontend's
  time is lowering the edited file. A probe miss reads and hashes the source; a known content hash is mapped,
  otherwise the file is parsed and lowered into a per-thread arena, written
  to the cache, and mapped. Only the main thread probes (mapping files from
  several threads contended on the address-space lock and made a warm build
  3x slower), breadth-first so a changed file near the root is found early;
  helper threads start one at a time when a file needs lowering and none is
  idle, and lower largest file first. While a changed file is lowered, the
  imports of its previous content (from its old cached summary) are probed
  as guesses; guessed files it no longer imports are dropped when files are
  numbered, and a missing file is an error only if it is reachable. Sources and ASTs are not kept: `Frontend.tree`/`source` reload and
  reparse a file when an error in it is rendered.
- Measured (2026-11-02, orb: 2 cores / 4 threads Xeon 2.6 GHz, bs
  ReleaseFast, hello world, 559 files, `BS_FRONTEND_TIMING=1`): before the
  cache, every build spent 0.56–0.66 s here on one thread. Now a cold build
  (empty caches) takes 0.22–0.25 s, a warm build 5–6 ms, and a build after a
  one-line edit to `std/debug.zig` about 7.5 ms (9.7 ms before the guesses,
  breadth-first probing, and on-demand helpers). Cold is bounded by the two
  physical cores (the same build on one CPU takes as long as before). In an
  edit build the edited file's own lowering (about 5 ms for `debug.zig`) is
  the critical path. std's
  cached ZIR takes 41 MB.
- Project ZIR in the global cache (2026-11-04, `bench/bench.py`, bs
  ReleaseFast, median of 10, cold 5): a cold-local build (empty local
  cache) no longer lowers the project's files. Before → after: vaxis
  226 → 98 ms, the zig workload 3.95 → 3.32 s; with lazy donor builds,
  hello 14 ms, vaxis 23 ms, the zig workload 155 ms and a fresh zls
  worktree 31 ms. Cold builds (hello 374 / 368 ms, vaxis 618 / 585 ms,
  zig 10.01 / 10.02 s), warm builds and edit builds of the root and of a
  library file stay within noise. The global cache grows by the
  project's ZIR: 70 MB for the zig workload (184 files, the largest
  35 MB), 20 MB for vaxis, on 408 and 55 MB before.
- ZON imports (`@import("x.zon")`) are not frontend files. Sema reads the
  file through the `@embedFile` path, so the importing unit depends on its
  bytes (`embed_file`), parses it with `Ast.parse(.zon)` and std's
  `ZonGen`, and lowers the `Zoir` to a value of the import's result type,
  or to anonymous structs and tuples of comptime fields without one (as
  upstream's `Sema/LowerZon.zig`). As upstream, errors point into the ZON
  file (`Zcu.ErrorMsg.embed`: `file` is then an `embed_files` index):
  syntax and ZonGen errors with ZonGen's notes, lowering errors with an
  "imported here" note at the import. A result type ZON cannot express is
  an error at the import, checked before any value is lowered (upstream's
  `checkType`). As upstream, a ZON file the files import by path must
  exist even if no import is analyzed: the frontend checks each
  (`Frontend.zon_imports`), and the cache records those Sema did not
  read as inputs with no nodes, keyed as embedded files, so that the
  up-to-date check sees one deleted (test/run/edit_zon_unreferenced.sh).

### Analysis units

Sema's unit of work, of caching, and of parallelism is the *analysis unit*:

- the value (and type) of a container-level declaration;
- the layout of a struct, union, enum, or opaque type;
- the default values of a struct's non-`comptime` fields, evaluated after
  its layout (they may read it, or a containing type's: an inner struct's
  `x: u32 = @alignOf(Outer)`), as upstream's `struct_defaults` unit;
- the body of a runtime function instance (a non-generic function, or one
  instantiation of a generic function with its comptime arguments);
- a `comptime` block, a `test` declaration, an `export`.

Every unit has a **stable key** that does not depend on analysis order or on
in-memory indices: module name + file path within the module + the
declaration's name path (for example `std:array_list.zig:Aligned.append`), plus
the hashes of comptime arguments and captured values for instantiations and
anonymous types. The same key, rendered, becomes the linker symbol name.

Anonymous types (a `struct {}` expression inside a declaration or function
body, or a type a function returns) are keyed by the *path* of the
declaration whose code holds the type's ZIR instruction, the instruction's
offset from that declaration's own instruction, and the stable hashes of
the type's captured values: `decl.path#offset(capture hashes)`, with no
parentheses when it captures nothing. A declaration's path is its key
without the captures of the types around it (`Namespace.path`), so all
instances of a generic type give one path: `MultiArrayList`'s `sizes`
makes `MultiArrayList#4.sizes#2`, whichever instance makes it first, since
that struct captures nothing and is one type for all of them. A type
named after its declaration (`const S = struct {...};`) is keyed by the
declaration's path and its captures in the same way. Keys built on the
declaration's key instead named the type after its first creator, so a
unit loaded from one build recorded other keys than a full build that
created it from another instance. Never by an absolute ZIR
index, which shifts when unrelated code above changes; the relative offset
only shifts when the declaration's own source changes, and then it is
re-analyzed anyway. The key follows the type's identity, which is upstream's:
the same instruction with equal captures is the same type (two comptime calls
`F(u8)` and `F(i8)` whose struct captures only `@typeInfo(T).int.bits` return
one type, as behavior/struct.zig checks), and two identical `struct {}` texts
are distinct instructions. So the key does not include a comptime call's
arguments or an ordinal among the types a unit creates: either would give one
type two keys, or two types one. (It must still tell distinct types apart:
their declarations' keys extend it.) The *display name* is separate from the
key and follows upstream's form (`Parent__struct_<n>`), because `@typeName`
results are observable and `test/behavior` checks them. Upstream's `n` counts
anonymous types in analysis order; bs's is the type's instruction (an
anonymous struct literal's too) relative to the declaration, like the key, so
that an edit above a declaration renames none of its types: nothing that
reads a type's name records a dependency on it. A `comptime` block's types
share the parent name `<namespace>.comptime` with the namespace's other
blocks, so their `n` is `<ordinal>_<offset>`, the block's ordinal and the
offset from it, as their key has both. (Absolute instructions renamed them
on an edit above the block while their key stayed: the block is analyzed
again in every edit build, but a function of the type is loaded with its
old symbol name.)
The types a container's layout or defaults make in a member's body (a
field's type, alignment, default or enum value, or the backing or tag
type) are numbered the same way from that body's start, under the body's
ordinal (`Sema.resolveMemberBody`: 3 times the field's index, plus 1 for
the alignment and 2 for the default or value): `S@layout#3#2` is the type
of instruction 2 of `S`'s second field's type. The container's
declarations come before its fields in the ZIR, and an edit to one of
them leaves the layout green, so numbering from the container's own
instruction kept the old key of a field's anonymous type
(`f: std.ArrayList(struct {...})`) in an edit build where a full build
gave a new one, and with it the keys of every instance the type reaches.

#### Type names

A type's identity can be shared by creators that would name it
differently: a type that captures nothing that tells them apart (`fn
F(comptime T: type) type { return struct { const S = struct {}; const t:
T = 0; }; }` makes one `S` for `F(u8)` and `F(u16)`), or one made by an
inline or comptime call whose uncaptured arguments differ. Upstream names
such a type after its first creator, so the name depends on analysis
order. bs names it after the *least* creator by key, so that every build,
in any order, names it the same, clean or edit (built 2026-11-04, in
three parts):

- *Candidates.* Every container type and named tuple (an anonymous struct
  literal's type) has a mutable name slot (`InternPool.TypeName`, the
  `name` of `ContainerType` and `TupleType`). Each creation offers a
  candidate (`Zcu.offerName`): its creator, the stable hash of what names
  the type (the declaration's `Nav.hash` for `.parent` names and for
  anonymous types in a non-generic function, inline call, signature, or
  declaration; `stableHash(func)` of a generic instance; the callee's
  hash and the arguments' for `.func` names; the type's for field
  expressions; the namespace owner's for `comptime` blocks), and a
  *template*: the name with holes where other types' names go. The slot
  keeps the candidate with the least creator.
- *Rendering.* Names are rendered when read (`print.writeTypeName`,
  `writeNavName`), not stored: `Nav.parent` replaces `Nav.fqn`, a
  declaration's name is its parent type's and its own, and a nested
  type's template has a hole for its parent's name. So when `S` is
  renamed, its declarations, its nested types and their functions'
  symbols follow. `Namespace.fqn` is gone.
- *Reads.* Analysis reads a name when it renders it into a value
  (`@typeName`) or into an error message (`print.Names.read`, Sema's
  `fmtType`, and test filters). A read marks the slots it rendered. If a
  marked slot's name changes afterwards, `Zcu.finalizeNames` returns the
  final names, keyed by stable hash, and main redoes the build with them
  pinned (`TypeName.pinned`); a pinned slot renders its pin. A type that
  only the second attempt makes and reads is not pinned. Measured on main
  459e1fe: types with conflicting creators number 56 on the std tests,
  108 on the zig workload and 5 on libvaxis, and no `@typeName` read
  is of one, so a build is redone essentially never
  (test/run/type_names.zig forces one).
- *Atom names.* CodeGen runs while names can still change, on workers,
  so a function's or declaration's atom is named in `Emit.finish`
  (`Emit.nameAtoms`), after `finalizeNames`, and so is a unit's atom that
  an eager edit build loaded. `Emit.atom_names` keeps, for the cache,
  which type's name each atom's name starts with (`nav.parent`; none for
  an export's name).
- *Parents.* A type's namespace's parent is the nearest enclosing
  namespace that is not inside a function (`Namespace.parent`,
  `Namespace.in_fn`). AstGen tunnels every reference to a declaration of
  a namespace inside a function through a capture (`found_needs_tunnel =
  ns.maybe_generic`), so a lookup from a nested type never finds a name in
  such a namespace, and skipping them makes the parent the same for every
  creator, with the `namespace_name` dependencies lookups record. Nothing
  about parents depends on creators any more.
- *The cache* (part 2, built 2026-11-04). Sema records each unit's
  offers (`Zcu.name_offers`) and the types whose names it rendered into
  a value (`Zcu.name_reads`), and memo entries carry both
  (`Zcu.Memo.names`, `name_reads`), offered and noted again on a hit.
  - *Records.* Each unit's node keeps them in its `type_names`
    (`Manifest.typeNames`, ZAPMAN13; `results.Names`): per offer the
    type's stable hash, the creator, the template with each hole as the
    stable hash of the type named there, and the type's final name if
    the offer was the least creator's (it *won*); per read the type's
    stable hash and rendered name. Types go by stable hash, not by
    result item, so a record stands alone and an eager edit build or a
    donor's replay copies a loaded unit's record as it is: the unit
    offered nothing in this build, and would offer the same if
    analyzed.
    The manifest also indexes the base's offers by type and creator
    (`type_name_index`, rebuilt when it is written), so that replay
    reads only the records it needs: for each type the build has, and
    each type whose winning offer is in a node it did not keep, the
    least kept creator's record and the winning one's.
    Which unit offers a candidate can depend on analysis order, as
    for `effects` references: a memoized call offers again on a hit,
    but a body that the comptime evaluator lowered has folded the
    call away. The creator, and so the name, does not, so
    `BS_CACHE_VERIFY` checks names through the atoms' names, not each
    node's offers.
  - *Replay* (`Replay.contributeNames`, first in `finalizeNames`). The
    nodes a build *keeps* are the live ones whose units it did not
    analyze: those an eager build loaded, or those a lazy build's walk
    reached and did not analyze. For each type this build has, the
    least creator among the kept nodes' offers is offered again, with
    each hole's type if this build has it and its recorded name
    otherwise. A type made from a result starts with its recorded name
    and the greatest creator, so any offer replaces it. Analyzed units
    offered as they ran, so every creator a full build would have
    counts, whatever this build loaded.
  - *Names that change* (part 3, built 2026-11-04). Replay lists the
    types whose name, or the creator that gives it, differs from the
    recorded one (the name in a won offer): one this build has under
    another creator, or with another template from a unit it analyzed
    (an anonymous type's name numbers its instruction, so an edit above
    it renames it), or one absent whose least kept creator's offer did
    not win last time (the one that did left) (`Replay.renamed`). A type
    whose holes were renamed is not listed: they are. Then the atoms
    named after any type whose final name changed, and the recorded
    winners of the listed types' offers, are out of date. An eager build
    names every unit atom from the final names, and writes each loaded
    unit's `type_names` again with this build's winners
    (`results.Names.rewriteWon`, `Replay.wonName`). A lazy build stays
    lazy: it compares every node's atoms' names with their parent types'
    final names (`Replay.finalTypeName`) and rewrites the nodes whose
    names or listed offers changed, linked or not, so that a node that
    comes back to life later is right too (`Incremental.rewriteKept`,
    which also refreshes moved lines); records stay. So the manifest's
    won offers stay one per type. An absent type's final name is its
    least kept creator's template with each hole's final name; a file's
    root type, which no unit offers a name, is named from its file
    (`Replay.finalName`, `InternPool.rootStructHash`). A kept unit that
    read a name that changed has an out-of-date result: if one did (for
    a type the build does not have: if the name it read contains a
    listed type's old name), the build is built again in full
    (`error.NamesFullBuild`, `BS_CACHE_REPLAY=off` for that build).
    Adding `F(u16)` back above renames `S` (test/run/edit_type_names.zig);
    an edit above an anonymous struct renames the type its generic
    instance makes (test/run/edit_type_rename.zig, ghostty's unigen
    edits): both edit builds stay lazy.
  - `offerName` compares a read name by its rendering, not its
    template: a type made from a result has its recorded name without
    holes until its creators' offers arrive.
- *Names in the manifest* (part 3). Atom records keep no symbol names
  (`cache/atoms.zig` writes none); the manifest keeps each atom
  reference's (`Manifest.atom_names`, `AtomName`, ZAPMAN14/ZAPMLG07):
  the name, in `atom_name_bytes` (in its record's strings, for a node
  the log changed; a written base keeps only live atoms' bytes), and the
  stable hash of the type its first `prefix_len` bytes name. A relink
  passes them to the linker beside the records (`LinkInput.names`,
  `Pack.LinkAtoms.names`), as it passes debug paths. So the store
  reuses an entry whatever its atoms are called, and an edit that
  renames a type rewrites nodes, not records. `BS_CACHE_VERIFY`
  compares each atom's name and parent with a full build's.

When a unit reads another unit's result (a declaration's value, a type's
layout, a function's signature) it goes through one Sema function that records
the dependency. Sema records dependencies from the first skeleton onward, even
before anything persists them.

One unit has a first phase that other code may need on its own, as
upstream has a separate unit for it. It does not read a unit that is
still in progress: a declaration that states its type (`Nav.has_type`)
resolves its type and alignment before its value (`Zcu.ensureNavTy`,
`Nav.ty_status`). Taking its address (`Sema.navRef`) needs only that,
and records the `nav_ty` dependency; its value is queued for
`analyzeAll` (`nav_queue`), as upstream's `ensureNavValAnalysisQueued`.
So `var x: S = .{ .p = &y }; var y = &x;` resolves from either end, as
upstream. A declaration without a stated type, a function, or an extern
needs its value.

A function type reads nothing about its parameter types, so it may name
a type whose layout is being resolved (`const FnPtr = ?*const fn
(@This()) void;` read by its own struct's field). Its key, as
upstream's, holds only the parameters declared `comptime`
(`comptime_bits`); whether a call instantiates the function
(`Type.fnIsGeneric`: a `comptime` parameter, a generic or comptime-only
parameter type, or a generic return type) and whether it has runtime
bits (`Sema.fnHasRuntimeBits`, which a comptime-only return type also
denies) are derived where they are used. Those read the parameter and
return types' layouts: a declaration resolves them (`Sema.funcCommon`),
and a call through a pointer or a coercion between function types
resolves them first, as upstream's `ensureLayoutResolved`.

When the phase runs on its own, its Sema keeps the dependencies it
recorded (`Zcu.phase_deps`), and the unit, when it runs, declares them
first and starts after the phase instead of analyzing it again: a second
analysis could see other units in different states and give a different
type than the one code already used.

Within one unit, a repeated read may skip the lookup: a unit's dependencies
are a set, so the dependencies the first read declared are already the
unit's. Sema keeps two such caches, both per unit (per `Sema`) and in
memory only. `dep_cache` returns early from declaring a dependency the unit
declared recently (a direct-mapped table over `deps`), unless the new
declaration makes a conditional edge plain. `name_cache` remembers what a
ZIR string (by file and string index) resolved to in a type, after a lookup
that succeeded: a decl literal's coerced value (`.default`, an enum
literal), and a struct field's type and index in a struct literal. A large
literal (uucode's 47 k-row tables) looks up the same few names in every
row. Both are off while a memoizable comptime call
or a lowering for the comptime evaluator is in progress, because those
record their own dependency lists (the memo entry's, the lowered body's),
which must not miss a read.

Function bodies depend on the *signatures* of the functions they call, not on
their bodies. Editing a function body therefore re-analyzes and re-generates
only that function. The one exception is an inferred error set: a caller
that needs the callee's resolved set (to switch on it or coerce it to an
explicit set) depends on it (`Dependee.func_ies`), and resolving it analyzes
the callee's body first. Early cutoff on the set keeps such callers green.

### InternPool

- Types and comptime values are interned and deduplicated, as upstream does.
- Every item carries a 128-bit **stable hash** computed from its contents and
  the stable hashes of the items it references (never from indices). Indices
  are an in-memory detail; anything persisted or shared between threads
  across runs uses stable hashes or unit keys. Deduplication does not need
  it: a lookup hashes the key's indices and string indices (what equality
  compares), mixing each field in as a 64-bit word with one multiply, and
  only an item that is new computes its stable hash. Integers, the most
  common keys, first look in a small direct-mapped cache of the calling
  thread's (`Local.int_cache`), which needs no key hash. Most lookups
  find an existing item. Other keys first look in the thread's
  `Local.recent`, direct-mapped by the lookup hash and checked against
  the item, which skips the shard's lock and map on a hit. Items never
  change, so neither cache needs invalidating, and an index another
  thread created enters a thread's cache only after its lookup found it
  under the shard lock. `get` itself stays small: aggregates (canonical
  storage) and inserts (encoding and the stable hash) are out of line.
  Field names are interned too, so a lookup by
  name in a container of more than a few fields
  compares string indices, not bytes.
- Reads decode only what the caller uses. `indexToKey` builds a whole
  `Key`; hot code asks for the key's tag (`keyTag`, from the item tag
  alone) and then one payload (`keyPayload(.ptr, i)`, or `keyAs` for an
  optional one), which share `indexToKey`'s decoder instantiated per item
  tag. Equality in `get` compares against the payload of the entry's own
  tag the same way. An index's top bits select the owning thread's list;
  with one thread the shift gives 0 without a branch.
- Designed for concurrent use from the start: per-thread shards for appends
  and lock-free reads of published items. The skeleton can run one thread, but
  its API takes the per-thread handle so parallelism is not a retrofit.
- Float values are stored as the IEEE bits of their type (c_longdouble as
  f80, comptime_float as f128) and hashed and compared by those bits, as
  upstream: -0.0 and 0.0 are distinct values, and so are NaNs with
  different payloads. Comptime float arithmetic computes in the host type
  of the same precision, as upstream does.
- Error codes. `anyerror` integers are assigned per compilation and live only
  in memory; IR and Atoms refer to errors by name, and machine code gets the
  integers through link-time value relocations. The per-project manifest
  keeps last build's name-to-code assignment and only appends new names, so
  existing codes, and units whose results depend on one (comptime
  `@intFromError`, an error integer folded into a constant), stay stable
  across rebuilds without a dependency on the code (see "Edit builds"
  below). The number of codes is a link-time value too
  (`Emit.errors_len`), which `@errorFromInt`'s safety check
  (`cmp_lt_errors_len`) compares with, so an edit build that adds an
  error relinks with the new count without lowering the check again.
- Pointers into comptime-mutable memory (`comptime var`, comptime
  allocations) are local to the unit that created them. They are excluded from
  stable hashing and persistence and must not escape a unit's result; an
  escape is upstream's "runtime value contains reference to comptime var"
  error. Memoized comptime calls don't memoize when an argument or the result
  points into comptime-mutable memory.
- Declarations (`Nav`s) are made when first looked up. Creating a
  container type lists its named declarations in its namespace
  (`Namespace.decls`, in ZIR order, `.none` for one not made yet, with
  `decl_insts`) and makes only the exported and test ones, which are
  effects; `Zcu.declNav` makes the others when a lookup or a cache
  subject names them. A lazy zls edit build resolves 897 of the 8207
  declarations its namespaces list. A nav's identity is its key
  (`Namespace.decl_prefix` and its name), so the order navs are made in
  changes no result. Readers that need only a declaration's name, key or
  `pub` take them from the namespace and the ZIR without making it
  (`Zcu.declKey`, `Zcu.declIsPub`): `@typeInfo`'s `decl_names`, the
  `namespace` and `namespace_name` dependees' result hashes, and
  `Replay.navByKey`.

### Typed IR (`Ir`)

- One function at a time, flat arrays of instructions in SSA form, operands
  are instruction indices or InternPool indices (like upstream AIR).
- Produced by Sema for one function instance, consumed immediately by
  CodeGen, then freed. It is **never persisted**: the cache stores the Atom
  that CodeGen produces, so a cache hit skips both Sema and CodeGen.
- Debug semantics: Sema emits safety checks (overflow, bounds, unwrap,
  unreachable) as explicit IR, as upstream does. No optimization passes.
- Error return traces are explicit IR too, as upstream: a return of a
  possible error calls `std.lang.returnError`, which pushes the return
  address; handling an error (`catch`, `if`/`else`, a call whose error
  result is discarded) restores the index saved before it
  (`save_err_return_trace_index`, then a store through
  `err_return_trace`). `.auto` functions share the caller's trace; a
  non-`.auto` function that calls one creates its own at entry
  (`set_err_return_trace`). With no liveness pass, a save that no restore
  uses is marked unused by Sema and has no code. Off in compiler_rt (built in
  a release mode upstream) and without std. Per module, as upstream's
  (`Frontend.Module.error_tracing`: `-fno-error-tracing`, and ReleaseSafe's
  default): returns push in every module once any module traces
  (`any_error_tracing`, `Sema.pushes_traces`), while saving, restoring
  and `@errorReturnTrace` follow the module of the code being analyzed,
  in an inline call the callee's (`Sema.error_tracing`). When no module
  traces, nothing pushes and non-`.auto` functions set up no trace.
- Target-independent, and precise enough to interpret. The bytecode comptime
  evaluator (milestone 6) runs lowered function bodies; it runs this IR
  directly (it may move to a denser encoding derived from it), and it does
  not get a second semantic lowering (see "Comptime evaluator").

### Comptime

- Skeleton and milestone 3: Sema evaluates comptime code by walking ZIR, as
  upstream does, with a comptime memory model (comptime allocations, mutable
  comptime values, comptime pointers) owned by Sema, not smeared across it.
  Like upstream's `MutableValue`, a comptime allocation that code stores into
  field by field or element by element holds a mutable tree that those
  stores write in place; it is interned only when read as a whole, so
  filling an n-element array costs O(n), not O(n²) interned aggregates.
- Comptime strings stay bytes. A defined `[n]u8` value interns with
  `bytes` storage (one InternPool string), and `++`, slicing at
  comptime-known bounds, and reading a `[]const u8` as a name (`@field`,
  `@hasField`, `@hasDecl`) copy those bytes instead of going element by
  element. Upstream's compiler builds its x86_64 `mnemonic_table` from
  about 100 k such concatenations.
- All comptime calls go through one entry point that memoizes by (function,
  stable hashes of arguments). A memo entry keeps the dependencies its call
  declared and the functions it referred to (an `Io` vtable's), and a unit
  that reuses the result declares and refers to them too, as if it had made
  the call. `@typeInfo(T)` goes through the same memo table,
  keyed by `T`'s stable hash: its result depends only on `T` (and the
  declarations of `std.builtin` it reads, which the entry's dependencies
  record), and std.fmt and std.meta ask for the same types over and over.
  Error sets are not memoized: the function whose inferred error set it is
  sees it unresolved. Milestone 6 replaces the hot path behind this
  entry point with compiled bytecode for function instances whose types are
  fully known, falling back to ZIR walking for type-constructing code (see
  "Comptime evaluator" below).

### Comptime evaluator (designed 2026-11-03, accepted; being built)

The evaluator runs a function called at comptime from its lowered typed IR
instead of walking its ZIR on every call. It changes speed only: every
result, error, note, and branch-quota outcome is the walker's, because
anything the evaluator does not reproduce exactly sends the call back to
the walker.

**What is compiled, and when.** Function bodies, one per function (not per
call site), and one per specialization of a generic function: the values
of its comptime arguments (and of arguments of comptime-only types) and
the types of the others, the parts of a call `instantiate` would key an
instance by. A specialization's body is that instance's, with the
parameter types `Bytecode.params` records; a run coerces the arguments to
them as the walker does. Bodies are lowered on the comptime call path only. `Sema.callComptime` checks the
memo first, then asks the evaluator (`bcCall`), then walks
(`walkComptimeCall`). Each function has a state in `Zcu.comptime_bodies`:
`cold` (counting walker runs), `ready` (a lowered `Zcu.Bytecode`), or `off`,
keyed by the function's stable hash or the specialization's.
A function is lowered after `Zcu.comptime_eval_threshold` walker runs (4;
`BS_COMPTIME_EVAL=n` sets it, 0 turns the evaluator off), so code that
runs once at comptime (most of it) never pays for lowering. `comptime`
blocks, declaration initializers, and functions called once run once
each and stay with the walker, except for their long loops, which the
evaluator takes over midway (on-stack replacement, below); a `comptime`
block inside a lowered function is evaluated by the lowering, as runtime
analysis does, and its branches replay as ticks (below). Not lowered,
for now: instances called by value, inferred error sets, `noreturn`,
naked, and comptime-only parameters (other than a specialization's
comptime ones) and results, and bodies whose lowering creates a container
type, instantiates a generic, embeds a file, exports, takes a function's
address, or makes a non-memoizable comptime call.

**Lowering is runtime analysis with a few switches**, as the "Typed IR"
section requires (no second semantic lowering): `bcLower` runs
`analyzeFuncBody`'s steps on a fresh Sema with `sema.bc` set, which:

- makes `@inComptime()` true and keeps safety checks on regardless of
  `@setRuntimeSafety`; a failed check lowers to `unreach` (no panic
  handler is resolved);
- records each backward branch the walker would count in that body
  (a `comptime` loop's iterations, an inline call's, and those a
  comptime call folded while lowering took, which the walker's memo hit
  adds on every run) as a `comptime_tick` instruction with a count, and
  `@setEvalBranchQuota` as `comptime_quota`; both exist only in
  evaluator bodies;
- keeps packed struct accesses as `struct_field_ptr`/`struct_field_val`
  rather than bit arithmetic, which comptime memory addresses directly;
- does not queue runtime analysis of callees;
- lowers a `@compileError` reached outside a `comptime` block, and a
  return whose operand does not coerce to the return type (a `try` in a
  function that returns no error), to `unreach`: comptime analysis
  reaches only the paths an evaluation takes, so the error is the
  walker's to report if a run gets there (the run aborts, and the walker
  runs the code again);
- refuses a runtime block that merges results of different types: the
  walker keeps the type of the branch it takes, where runtime analysis
  would resolve the peer type (`if (c) @as(u8, 1) else @as(u16, 2)` is a
  `u8` or a `u16` at comptime, never a `u16` for both).

**On-stack replacement (OSR).** When a comptime loop has taken
`bc_osr_branches` (256) backward branches, counting nested loops and
calls, the walker hands it to the evaluator at the loop head
(`Sema.bcOsr`, from the `repeat` in `analyzeBodyInner`). `bcLowerLoop`
lowers the loop body as a runtime `loop` on a fresh Sema, as `bcLower`
lowers a function body, except:

- the walker's current values (its `inst_map`) are constants, which the
  next iteration's code may use;
- the walker's comptime variables are *foreign*: a pointer into a comptime
  allocation the lowering Sema does not own lowers to run-time `load` and
  `store` (`bcForeign`), which the evaluator executes against the walker's
  memory, logged for undo as a call's are;
- a comptime `var` declared in the body becomes a run-time one
  (`bcOsrVar`), since the whole body is comptime code; a use that needs its
  value comptime-known fails the lowering;
- a `break` to a block outside the body (one lowering has not entered)
  lowers to `comptime_exit`, which ends the run with the ZIR break and its
  value; the walker continues from that break as if it had run it, and a
  `return` lowers to `ret`, which ends the call the loop is in.

Every value the evaluator sees is one the walker would know at comptime,
so lowering also accepts two things runtime analysis rejects, both
checked by the run: an integer coercion that only a known value allows
(`var crc: u32 = i` with `i: usize`) lowers to `intcast`, which aborts if
the value does not fit, and a comptime_int element read at a run-time
index or address (`for (field_values) |v|`) is allowed when only
`@intCast` takes it (`resolveInst` refuses any other use). A run that
aborts restores memory, the branch counter, and the quota to their
state at the loop head, and the walker runs the loop on from there; a loop
whose lowering is refused or whose run aborted is not tried again
(`Zcu.comptime_osr_off`, by file and loop instruction), and a
`not_ready` lowering is retried after 1024 more branches. Dependencies
follow the same rules as a function's bytecode: the lowering's reads are
conditional, the reached `comptime_dep`s and `entry_deps` plain. A
lowered loop is used for one run only (the constants are the walker's
state at that point), so it is not cached.

**The laziness rule.** Lowering analyzes every branch of the body; the
walker analyzes only the branches it takes. Analysis has effects beyond
the IR (resolving a declaration can fail, records dependencies, and
assigns error codes), so lowering must not analyze anything the walker
has not: it may read a declaration, layout, defaults, inferred error set,
file root, or error code only once the walker has resolved it
(`bcRequire`). Otherwise the lowering is `not_ready`, and is retried once
the first unresolved declaration (`blocker`) resolves, or else after
twice as many walker runs. uucode's `computeGraphemeBreak` reads
`isIndicConjunctBreakExtend` on a rarely taken path, so it is lowered
after about 380 of its 2205 calls. The fix is deoptimization stubs (an
unresolved reference lowers to an instruction that aborts the run, below)
wherever the reference's type does not feed type resolution of the code
around it.

**The bytecode is the lowered IR.** `Zcu.Bytecode` holds the function's
`Ir` (main body as for CodeGen), the dependencies its lowering declared,
and `in_frame`, a bitset of the instructions whose values live in the
frame: an `alloc` used only by `load`/`store` (a local `var`, which then
never enters comptime memory) and an `*_with_overflow` used only by
`struct_field_val` (never interned as a tuple). The interpreter
(`bcExec`) walks the IR's structured bodies: `block`/`loop` recurse,
`br`/`repeat`/`ret` unwind as exits, and each instruction's value goes in
a per-run frame array indexed by instruction. Values are InternPool
indices, the walker's representation, so arguments, results, and memory
pass between the two without conversion; a frame value may also be
"garbage" (the payload of a null optional or the inactive error-union
side), which runtime IR computes and masks (`opt == x` is
`is_non_null(opt) and payload == x`) and which aborts the run if used
otherwise.

**Unboxed integers.** `Bytecode.ints` records, per instruction, the
integer type of 1 to 64 bits its value has (for a frame-kept `alloc`, the
value it holds; for a frame-kept `*_with_overflow`, the wrapped result).
Such a value lives in the frame as `bc_unboxed` plus the low 64 bits of
its two's complement in `BcFrame.ints`: wrapping and overflow-checked
arithmetic, casts, bitwise operations, shifts, non-negative division,
and comparisons compute on `i128`s without interning, and frame-kept
loads and stores copy the representation. A value is boxed (interned)
only where it leaves those operations: into comptime memory, a call, an
aggregate, a result, or an instruction without a fast path. Every fast
path covers only the cases whose result the walker's folding routines
also give without an error (no division by zero, no negative remainder,
no shift past the width); anything else takes the general path, which
folds as the walker does. A denser encoding (a flat instruction stream
with jump offsets and decoded operands) can replace the IR walk without
touching Sema. `bcExec` itself, dispatch together with the inlined fast
paths, is now about a quarter of the evaluator's instructions in the
grapheme tables, so the encoding becomes the next evaluator step once
comptime memory and the per-call overhead are cheaper, and only while
the evaluator is a large share of Sema (about 9% of libvaxis's build
instructions).

**Comptime memory.** Loads and stores go through Sema's comptime memory
functions (`comptimeStore`, `comptimeLoadOrNull`, the `MutValue` trees),
so a pointer argument into the caller's `comptime var` works, and a run's
allocations are ordinary comptime allocations. Calls from bytecode go
back through `callComptime` (memo, then evaluator, then walker), so
lowered and walked functions call each other freely.

**Falling back.** A run aborts (`error.BcAbort`) wherever the evaluator is
not sure to match the walker: a failed safety check, `unreachable`, an
exceeded branch quota, any error from a folding routine, a call through a
function pointer or to a `noreturn` function, an undefined branch
condition, a value shape it does not fold, or garbage used as a value.
Before each run `bcCall` notes the undo log length, the branch counter and
quota, and the error count; every first write to a comptime allocation
created before the run, and every `MutValue` node it changes, is logged.
An abort restores all of it, the walker runs the call again from the same
state, and the function goes `off` if the walker succeeded (a run that
needs the walker once likely will again). So an error is always reported
by the walker, with its message, its "called at comptime here" notes, and
the quota note, identical to an evaluator-free build; a failing call
costs one extra partial run, and only on the way to a compile error.

**Branch quota.** The evaluator counts exactly what the walker counts:
each `loop` repeat, each call, and each `comptime_tick`; `comptime_quota`
raises the quota as `@setEvalBranchQuota` does. Exceeding it aborts, and
the walker re-runs the call and reports it.

**Memoization.** The evaluator sits behind the memo: memoizable calls are
memoized as before, whichever tier ran them. The lowering itself runs the
memoizable comptime calls in the body (it refuses non-memoizable ones),
including ones on branches the walker has not taken, under the laziness
rule (they cannot resolve a declaration, number an error, or report an
error either). A later walker call of the same arguments then hits the
memo and counts no branches: an accepted order dependence of the branch
count, which is already memo-order-dependent, as upstream's is. A memo
entry's dependencies (see "Comptime") keep their conditional flags,
below.

**Dependencies.** A plain edge U → D means U resolves D itself, so replay
may load D for a green U. A function's body also depends on its own
declaration's value (`Incremental.Graph.addOwnNav`), which is the
function item: an error set its type names that gains a name makes it
another item under the same key, and the body (a return value coerced
to that set) reads the type without an edge of its own
(test/run/edit_error_set_type.zig). Lowering reads what other units resolved
(`bcRequire`), on every branch, so its reads are not plain edges of the
units that run the body. They are *conditional* edges (`Sema.deps_conditional`,
recorded in `Zcu.conditional_deps`): they count for invalidation (a changed
D reaches U) but replay does not load them. Where the code the walker
would run reads D, lowering places a `comptime_dep` instruction in the
innermost runtime block, and a run that reaches it declares the plain edge,
once per memoizable call in progress; a read outside any runtime block of
the body (or in instructions lowering discards) is declared plain by every
run (`Bytecode.entry_deps`). A call that lowering compiles as a run-time
call is a comptime call to the walker (`callComptime`), which reads only
the callee's `func_body` and types the result with the ad hoc error set.
So the run-time call's own reads are conditional: the callee's owner
`nav_val`, and the `func_ies` of an inferred error set that only such a
call introduced (`BcLowering.call_ies`). If they were plain, a unit's
plain edges would depend on which tier ran a call. A plain declaration
wins over a conditional one, and memo entries keep the flag. The
walker keeps the body's locals as comptime allocations, which read no
layout to make, load or store, while lowering makes them run-time locals
that do: those layout reads are conditional too (`Sema.localLayout`,
`bcLocal`; not an aligned variable's, which the walker reads, nor one
through a reinterpreting pointer). Before, std's `featureSet(&.{})`
(`var x = Set.empty; ...; return x;`) gave memo entries the evaluator
made a plain `type_layout` of `Cpu.Feature.Set` that the walker's lacked,
so `cpu.generic`'s edges followed analysis order
(test/run/edit_eval_tier.zig; `run.py --std --sched-check`, or `just
sched-check`, builds std with `BS_COMPTIME_EVAL=0`, then `=1`, then `=0`,
each checked with `BS_CACHE_VERIFY=full` against the one before, which
shows such a read whichever tier lacks it).
A unit's edges therefore cover what
the walker would have read (plain) plus the lowering's other reads
(conditional), whichever tier ran its calls; since call counts differ
between an edit build and a full build, so can where lowering happens and
the recorded edge sets, which is sound because both cover the walker's
reads.

**The cache.** Bytecode is in memory only, like all IR, and is not a cache
artifact. A warm or edit build reuses the results of the units that made
comptime calls, so it runs few of them, and a lowering is one analysis of
the body, done after four walker runs. If edit builds ever show lowering cost,
bytecode could become its own node kind keyed like `func_body` (the
function's source hash) plus the results its lowering read (its recorded
dependencies), which is the same check replay already does for a unit.

**Parallel analysis.** A `Bytecode` is immutable once `ready` and shared
read-only; `off` keeps it alive for runs in progress. With function bodies
on a pool, `comptime_bodies` becomes a sharded map whose state changes by
compare-and-swap, one worker lowers while others keep walking (no one
waits on a lowering), and everything a run mutates (its frame, undo log,
branch counter, comptime allocations) is per Sema, hence per worker. An
OSR lowering and its run are per Sema too; `Zcu.comptime_osr_off` is a hint
(a loop missing from it is only tried again), so it can be a sharded set
that workers add to without ordering.

**Measured (prototype, ReleaseFast, Sema only, minimum of 7–10 runs on a
noisy orb; the spread between batches was ±10%).** libvaxis text_input:
286 → 260–277 ms. hello (94–100 ms) and binary.zig (4.5 s): unchanged
within noise, as they repeat little comptime code. uucode's grapheme break
table built 8 times (each table calls `computeGraphemeBreak` 2205 times,
non-memoizable): 600 → 370–400 ms, of which 95 ms is that file's Sema
outside the tables. What remains is the walker running
`buildGraphemeBreakTable`'s own loop (a generic function called once:
about 40 ms of libvaxis's Sema), the walker runs before lowering, and the
evaluator's interning of integers.

**Measured (OSR, callgrind instructions for the whole build, ReleaseFast
`-Dcpu=x86_64_v3`, against generic specializations).** libvaxis
text_input 3.113 G → 3.024 G (−2.9%; it takes over uucode's
`buildGraphemeBreakTable` loops and std's CRC table loop); hello
925 M → 891 M (−3.7%); uucode's grapheme break table built 8 times
3.369 G → 2.890 G (−14%); binary.zig 45.15 G → 45.37 G (+0.5%): no loop
there reaches the threshold, and the cost is code layout of
`analyzeBodyInner` around the new checks. What remains in the tables is
the evaluator itself, mostly interning integers and the per-call
overhead of `computeGraphemeBreak` (about 80 k instructions a call).

**Measured (unboxed integers and the 64-bit `@bitCast` fast path,
callgrind instructions for the whole build, against origin/main
10e4219).** libvaxis text_input 2.636 G → 2.588 G (−1.8%); hello
883 M → 869 M (−1.6%); the grapheme break table built 8 times
2.790 G → 2.511 G (−10%). What remains in the tables' evaluator time is
comptime memory (`comptimeLoadOrNull`, `comptimeStore`,
`ptrElemPtrVal`, about a sixth), packed-struct `@bitCast`s (about an
eighth), and per-call overhead (dependency declaration, argument
checks). On libvaxis the evaluator is now about 9% of the build's
instructions, while one unit, uucode's generated `table_0_stage2` (a
47 k-row array of struct literals), takes about 40% of Sema: a literal
costs about 21 k instructions a row, most of it repeated layout
dependency declarations, field name lookups, and enum literal coercion.

**Measured (large aggregate literals: `dep_cache` and `name_cache`, see
"Analysis units"; callgrind instructions for the whole build, against
origin/main 9d936c3).** libvaxis text_input 2.606 G → 1.901 G (−27%);
`table_0_stage2` alone 102–110 → 41–51 ms (`BS_UNIT_TIMING`, 5 runs),
and libvaxis's Sema 319–450 → 216–267 ms; a synthetic 47 k-row table of
the same shape 21.8 k → 7.4 k instructions a row; hello 883 M → 871 M
(−1.4%); binary.zig unchanged within noise (Sema 5.49–5.81 s before,
5.34–5.87 s after; callgrind needs `--aspace-minaddr` on it, see
bench/README.md).
A row's remaining cost is the walker's generic per-instruction work (about
16 ZIR instructions a row: four field types, four decl literals, four
coercions, the struct init) and interning the row's aggregate.

**Next steps** (later), in order of measured payoff: deoptimization stubs
for references the walker has not resolved yet; generic calls whose
comptime arguments are run-time values in the lowered code (uucode's
`selectFieldIndexes` loop, refused today); then a denser encoding.

### CodeGen (`src/codegen/<arch>/`)

- Today: the IR is built into the shared SSA form, and each instruction
  is lowered by per-instruction code; scalar values get registers from
  linear scan and other values share stack slots by lifetime (steps 1 and
  2 of "Optimizing backend" below, accepted 2026-11-03, being built). The
  bullets here describe the code as it is until the rest lands.
- Calling conventions: `.c` follows the SysV psABI (`cClass` in
  CodeGen.zig, a port of upstream's `classifySystemV`, which follows
  Clang): integers, bools, and pointers in GPRs (16-byte integers in
  register pairs), f16, f32, f64, and f128 in XMM registers, f80 in
  memory and returned in st0. Structs, unions, arrays, and vectors of up
  to 16 bytes are classified per eightbyte (INTEGER or SSE, merged over
  their fields; a packed container is its backing integer; an f16 field
  or an x87 one puts the value in memory) and travel in the
  next GPR or XMM register of each class, rax:rdx, xmm0:xmm1, or mixed as
  results; a value that does not fit the registers left goes on the
  stack whole. Vectors are classified by their elements' bytes, not
  their 16-byte aligned size (up to 4 bytes INTEGER, up to 8 SSE, up to
  16 one XMM register, `<1 x double>` arguments in memory); without AVX,
  larger vector results come back as Clang returns them (32 and 64 bytes
  in xmm0 and on, three 8-byte elements in rax, rdx, rcx or xmm0, xmm1,
  st0), larger vector arguments in memory. Everything else is MEMORY: on
  the stack as an argument, through a result pointer in rdi (returned in
  rax). `va_arg` gathers a register-class aggregate from the register
  save area, which keeps all 16 bytes of each XMM register. A bool
  vector of 65 to 128 elements as an argument goes as Clang passes it:
  each element, 0 or 1, in the next GPR while any are left, the rest in
  8-byte slots on the stack (as a result it is MEMORY). `.x86_64_win` (C's ms_abi,
  `winClass`, after upstream's `classifyWindows`) passes each argument by
  position in rcx, rdx, r8, r9 or xmm0-3, the rest on the stack above
  the caller's 32-byte shadow space; values not of size 1, 2, 4, or 8
  (and f80, f128, 16-byte integers) go by reference to a caller-owned
  copy; results of those sizes come back in rax or xmm0 (f128, 16-byte
  integers and vectors in xmm0), others through a result pointer in rcx,
  returned in rax. A variadic callee also gets each float argument in
  its position's GPR. Functions bs defines with it save rsi, rdi, and
  xmm6-15 in frame slots with plain moves (they are not in the unwind
  info, which only records pushed GPRs). A variadic one stores rcx,
  rdx, r8, and r9 in its caller's home area, so its arguments are in
  order in 8-byte slots: its `va_list` (the first field of the
  target's `VaList`, as upstream) points past the named ones, and
  `@cVaArg` reads the next slot (through the pointer for a value passed
  by reference, which upstream does not support yet; an f32 as the f64
  C promotes it to). Measured by upstream's test/c_abi (`run.py --c-abi`).
  Bs-to-bs calls (`.auto`) pass every argument in
  memory at 8-byte aligned offsets of the caller's outgoing area, return
  1-, 2-, 4-, and 8-byte results in rax, and return anything else through a
  result pointer in rdi. The caller's error return trace pointer goes in
  r9 (as upstream's last argument register); the callee keeps it in a
  frame slot. Nothing outside bs observes `.auto`, so this can
  change when a register allocator wants a different one.
- Numerics: f32 and f64 use scalar SSE2 and f80 uses x87, as upstream
  does. f16 and f128 arithmetic, operations SSE2 lacks (rounding, fmod,
  transcendental functions, fma, fmin/fmax), and conversions SSE2 cannot do
  call compiler_rt (see below). Integers wider than 64 bits live in memory
  as 64-bit limbs, normalized like narrow integers (the bits above the width
  are sign or zero copies); CodeGen operates on them limb by limb, inline
  except for 128-bit division (`__udivti3` and friends). On x86_64,
  exactly 128-bit integers are register-allocated as pairs instead
  (`want_pair`, low half in `reg`, high half in `reg2`; `int128.zig`
  lowers addition, subtraction, bitwise operations, multiplication,
  constant shifts, casts, comparisons and their overflow forms there),
  and the rest reads them from memory.
- Vector operations that the backend lowers in SIMD registers stay whole
  vectors in the IR; Sema scalarizes the rest (see "Vectors" below). In
  memory, vectors are laid out as upstream's x86_64 backend lays them
  out without AVX: bool vectors bit-packed (element i is bit i % 8 of
  byte i / 8), other vectors like arrays, aligned to 16.
  aarch64-macos lowers the same operations with NEON (see "Vectors")
  and uses the same layout, except that, as LLVM's layout
  there, a vector is aligned to its bits in bytes rounded up to a power
  of two, at most 16, and its size rounds up to a power of two bytes
  (vectors of f80 or f128, soft floats there, are aligned and sized as
  arrays; f80 and f128 themselves are 8-byte aligned). aarch64-linux
  follows the same rules, except that f128 is not a soft float there
  (`long double`): it is 16-byte aligned and its vectors round up as
  the others do; f80 stays 8-byte aligned. LLVM also
  bit-packs the elements of integer vectors whose width is not a whole
  number of bytes (`@Vector(4, u7)`), so those sizes still differ.
- aarch64-macos (`src/codegen/aarch64/CodeGen.zig`) lowers the same SSA
  form with the same per-instruction structure. It runs `Ssa.liveness`
  and `Ssa.plan` (dead values, fused branch conditions, overflow pairs
  and bits left in the flags, promoted variables), then `Ssa.allocate`
  over the callee-saved x19-x28 and d8-d15 and the caller-saved
  v20-v29: scalars that fit a general register (`inGpr`) get one of
  x19-x28; f32 and f64 (`inFloat`, `want_float`) one of d8-d15, or of
  v20-v29 when they cross no call; vectors of at most 16 bytes
  (`inVec`, `want_vec`, which takes only allocate's floats outside
  `survives`) one of v20-v29; promoted variables likewise; the rest live
  in stack slots shared by lifetime. Floats and vectors share one home,
  `.vreg`. No lowering uses an allocated register as scratch. Calls
  preserve x19-x28 and d8-d15 (only their low 64 bits, all an f64
  needs) but clobber v20-v29, so every instruction not known to be
  call-free (`callFree`, a conservative whitelist that genBlock checks
  against the calls the encoder emits) is a clobber point, and a value
  that crosses one keeps d8-d15 or memory; no value is spilled or split
  around a call, and both conventions (Apple's and Linux's AAPCS64) only
  move arguments into their homes at entry and results out of x0 or
  v0. Each lowering writes its result register after reading every
  operand (results it writes through `resultMem` go to a scratch slot
  and are moved to the register after the instruction), so a result may
  take the register of an operand that dies there (`tiedOperand`).
  Slices, optional slices, and error unions with an 8-byte payload
  (`inPair`) take two of x19-x28 (`want_pair`, `Home.regs`) when
  computed by a load, `slice`, an element or field read, an optional's
  or error union's wrapping or unwrapping, an `.auto` argument or call
  result (`pairResult`), or a promoted variable; their users that read
  memory get a copy (`valMem`), and a `slice_ptr` or `slice_len` of a
  slice in registers takes none of its own but reads the slice's
  (`lengthenIntervals`, as x86_64's `pairFoldable`). Block results
  stay in slots. A value that meets an inline assembly statement (an operand,
  its result, or a value live across it) takes none of the x19-x28 and
  v8-v15 an assembly statement in the function names in its template,
  pins or clobbers (`asmRegs`, an `Ssa.allocate` restriction); the
  statement saves those it names around itself, for its caller's
  values (a context switch names them only as clobbers), except in a
  naked function. The prologue saves the used pairs right below the frame record (x19 at fp
  - 8, x20 at fp - 16, then the next used pair, the d pairs after the x
  pairs), which compact unwind's frame mode reads from
  `Atom.Unwind.saved` (d8/d9 is 0x100) and the aarch64-linux FDE
  describes with `DW_CFA_offset` rules after the last push
  (`DW_CFA_offset_extended` for d8, DWARF register 72, and up; an FDE
  with d pairs can exceed `Dwarf.max_short_fde_size`); the epilogue and
  tail calls restore them (`popFrame`). Measured on an M-series Mac
  (2026-11-05), against slots only: bench/runtime fib 103 → 87 ms,
  sieve 328 → 52, sort 459 → 154, hash 444 → 187, nbody 310 → 208,
  fmt 138 → 57 (sieve, sort, hash and fmt now beat upstream's LLVM
  Debug); std's tests run in 7.3 s instead of 12.6, with 9% less code;
  compile time unchanged. d8-d15 for f32 and f64, against x19-x28
  only (mac.large): nbody 208 → 38 ms (0.22x upstream's LLVM Debug);
  fib, fmt and the other programs without floats, and the hpke, zigimg
  and qr corpus tests, unchanged; std's tests compile in the same 2.3 s
  with 32 KB less code. A load that `plan` forwards
  shares the stored value's home, and a removed instruction's constant
  pointers still request their symbols (`keepSymbols`), as on x86_64. aarch64-macos builds use no cache yet:
  a relink would need the Mach-O linker's inputs in the manifest. Until
  then a build that changed nothing answers from its inputs record, as
  -fPIC builds do (`InputsRecord`).
  Each function keeps a frame record (`stp x29, x30, [sp, #-16]!; mov
  x29, sp`), so compact unwind's frame mode covers it, and addresses its
  slots from sp above a fixed outgoing argument area (the most any call
  needs, computed before emission). Frames over 4 KiB call
  `___chkstk_darwin` from code after the body that the prologue branches
  to; a frame of 2^24 bytes or more (beyond `sub sp, sp, #imm`'s reach)
  takes the same out-of-line path on every OS and subtracts its size
  from x17. x9-x14 are per-instruction scratch, x16/x17 legalize addresses and
  hold call targets. `.auto` passes values of up to 8 bytes in one of
  x0-x7, up to 16 in two, f16/f32/f64 in v0-v7, the rest in the outgoing
  area; results come back the same way or through x8, and the error
  return trace pointer goes in x15. `.c` is Apple's AAPCS64: aggregates
  over 16 bytes by the address of a caller's copy, stack arguments packed
  at natural alignment, variadic arguments all on the stack in 8-byte
  slots (`va_list` is a pointer); f80 and f128, which C lacks here, go in
  two GPRs as compiler_rt's soft-float ABI declares them. Both
  conventions classify as upstream's `aarch64/abi.zig`: a homogeneous
  float aggregate (up to four members of one float type or one short
  vector type, `cHfa`) goes one member per v register, or whole on the
  stack once v0-v7 run out; a vector of at most 16 bytes goes in one v
  register, a larger one by reference; a vector of 32 to 128 bools goes
  as that many bool arguments (`bool_split`: x registers, then stack
  slots of 8 bytes on Linux and 4 on Darwin) and returns in memory, as
  LLVM lowers `<N x i1>` and Clang's `ext_vector_type` bools agree.
  `aarch64_preserve_none` passes integers in x20-x28 then x0-x7; its
  callers save and restore x19-x28 around the call, and a function using
  it gets no allocated registers (`Ssa.no_regs`). f16 arithmetic is
  native (FEAT_FP16); f80 and f128 call compiler_rt. Atomics use LSE
  (`ldadd`, `swp`, `cas`, ...) with acquire-release, `ldar`/`stlr` for
  loads and stores; 16-byte ones load and store with `ldp`/`stp` and
  `dmb ish` (FEAT_LSE2) and exchange in `caspal` loops, as LLVM lowers
  them for Apple Silicon (the float operations other than `.Xchg` on f80
  and f128 are refused). `@call(.always_tail, ...)` places the arguments
  where the caller's own came (Sema made the two function types equal),
  stack ones through slots since they may read the caller's, passes the
  caller's result pointer in x8, pops the frame and branches; an
  argument passed by reference is refused, as its copy lives in the
  popped frame. Inline assembly is parsed from GNU/LLVM syntax: the
  loads, stores, moves, arithmetic, branches, barriers, hints, and `mrs`
  of the thread registers that std uses, and the NEON instructions of
  std's AES, GHASH/POLYVAL and SHA-256 code (`aese`/`aesmc`, `pmull`,
  `sha256h`, `ext`, `tbl`, `movi`, ...), in both `v0.16b` and Apple's
  `sha256h.4s` suffix spelling. `w` and `x` operands (v0-v31, v0-v15)
  take v16-v31 first, then v0-v7, then v8-v15, whose low halves are
  callee-saved and so are saved whole around the template, as are the
  callee-saved registers the template names; `%q[x]` and `%[x].4s`
  pick the register's form. A digit constraint ties an input to an
  output's register.
  Vector-typed asm operands load and store through memory, since
  vector values themselves stay scalarized.
- aarch64-linux (started 2026-11-05) runs the same CodeGen and links
  static, non-PIE executables with the ELF linker (`Elf.Options.arch`),
  and position-independent objects and shared objects ("Position-
  independent code and shared libraries").
  What differs from aarch64-macos is keyed on `ip.target ==
  .aarch64_linux` or on the CPU's features, so aarch64-macos output
  does not change. `.c` is Linux's AAPCS64: f128, which is `long double`
  there, travels in a q register; each stack argument takes its own slot
  of a multiple of 8 bytes, aligned to 8 (16 for 16-byte aligned values);
  variadic arguments go where named ones would (`va_list` is a struct
  there, but std's `VaList` is a compile error with upstream's LLVM
  backend on this target, so `@cVaStart` never reaches CodeGen); `char`
  is unsigned. An executable's thread-locals are local-exec: `mrs xN, tpidr_el0` and two
  adds with the `aarch64_tprel_hi12`/`lo12_nc` relocations. Frames are
  not probed (upstream's LLVM probes only on x86 off Darwin). The CPU is
  upstream's baseline for `-target aarch64-linux`, the generic ARMv8.0
  core, so atomics without LSE are `ldaxr`/`stlxr` loops (`atomicCas`,
  `atomicOp`), as LLVM emits for it (16-byte ones `ldaxp`/`stlxp`
  loops, which store the old value back after a failed compare so that
  the read is atomic), and f16 arithmetic without
  FEAT_FP16 calls compiler_rt (`fpType`), where `fcvt` still converts
  halves. Builds use the cache as x86_64-linux's do (`Job.cacheable`
  keys on the OS): the manifest's numbered link is the ELF linker's, with
  `Elf.Options.arch` from `Incremental.arch`, and records already carry
  aarch64's relocation kinds and unwind records. A no-change build of
  std's tests relinks in 0.2 s against 9 s cold. The inline assembly
  std's Linux code needs adds `msr tpidr_el0`, the shifts, and the
  extension aliases. C sources, objects and archives link without libc
  ("Object, archive and shared-library inputs"), and thread-local
  externs that a C object defines are local-exec too.
- Panics are calls, as upstream: `@panic` and each failed safety check
  call the matching function of `std.lang.panic` (`integerOverflow`,
  `outOfBounds(index, len)`, `call(msg, null)`, ...), then `unreach`.
  `std.lang.panic` is the root file's `panic` namespace if it declares one
  (read directly, so it needs no std code), else std's
  `FullPanic(defaultPanic)`. std is always loaded, as upstream analyzes
  it; `Frontend.Options.load_std` is off only in tests without a lib
  directory. std-free test programs declare a minimal root `panic`
  (`test/run/rt.zig`, `tools/conformance/bs_runner.zig`).
- Output is an **Atom**, defined in `src/link/Atom.zig`:
  - stable symbol key and name, section kind, alignment. The key is the
    identity; the name is for the symbol table, upstream's qualified
    name (`widgets.TextInput.update`), and may repeat;
  - code or data bytes (or a size for zero-fill sections);
  - a target table listing each symbol key the atom references once, and
    relocations of 12 bytes each: offset (u32), addend (i32), and a u32
    holding the kind and the index of the target in that table. The record
    is a third of the 32 bytes a full key would need, and the linker
    resolves each distinct key once per atom instead of once per use;
  - debug info is not part of the Atom. For functions, CodeGen produces an
    `Atom.Debug` next to it: source path, simple name, the declaration's
    base line, and the function's DWARF line-number program fragment,
    already encoded from the IR's `dbg_stmt` rows with lines relative to
    the base line. Moving a declaration changes only the base line; the
    linker copies the fragment unchanged and only writes the sequence
    around it (start address, file index, base line, end address). The
    linker takes these as a separate slice (`Options.debug`) sorted by the
    index of their atom (`Debug.atom`, set by `Emit.addFunction`), so
    layout, which walks every Atom, never loads debug data, and the debug
    passes stream the slice in order without a pointer chase per atom.
    Its fields are byte, `u32`, or extern-struct slices with no pointers
    inside (extra file paths are 0-terminated in one byte slice; inline
    calls name themselves by offset into another), so cached records
    hand them out in place. Inlined calls come from IR markers: Sema puts
    `dbg_inline_begin` (callee, call position) and `dbg_inline_end` around
    each runtime inline body, whose `dbg_stmt`s are relative to the
    callee's declaration; CodeGen turns them into `Debug.inlines` records
    and `LineProgram.switchTo` patches, and gives each the callee's stable
    key (`Debug.inline_callees`, for the cache only). A function's unit is
    its module's root file path.
- The symbol key is 128 bits: a hash of the rendered unit key for
  declarations, or of the contents for anonymous constants. Atoms with equal
  keys are one symbol; the linker keeps one and rejects a key whose atoms
  differ.
- Relocation kinds are either target-specific addresses or link-time
  values: an integer of 1, 2, 4, or 8 bytes that the whole compilation
  assigns to the target key, such as an error code, passed to the linker
  rather than stored in any Atom. x86_64 addresses: absolute 64-bit,
  PC-relative 32-bit, and TPOFF32, a thread-local's offset from the
  thread pointer (local-exec; `Encoder.leaThreadLocal` emits upstream's
  `mov r, fs:0; lea r, [r + sym@tpoff]`). New kinds are appended, since
  the cache stores kinds by number. Sections: text, rodata, data, bss,
  and thread-local tdata and tbss. aarch64 addresses: absolute 64-bit (data only; Mach-O
  turns it into a fixup), branch26 (b, bl; a target beyond its ±128 MiB
  is an `error[branch-range]` that names the caller and the target, since
  bs adds no range-extension thunks: the largest program measured, the
  zig compiler, has 48 MiB of aarch64 .text), page21 (adrp) with pageoff12
  (add, or a load or store whose access size the linker reads from the
  instruction), and their GOT forms, which reach an import's GOT slot and
  are relaxed to the symbol itself when it is defined in the image, and
  tlvp page21/pageoff12, which reach a thread-local's descriptor (Mach-O
  TLV, whose thunk returns the variable's address), and for
  aarch64-linux's ELF output tprel hi12/lo12, a thread-local's offset
  from the thread pointer in two `add` immediates (local-exec, TLS
  variant 1). aarch64
  link-time values that fit 16 bits, such as error codes, go into a `movz`
  or `movk` imm16 field (`aarch64_movw_value16`, Mach-O only, since bs
  links its own output); wider ones are loaded from a constant Atom.
- Atoms contain no InternPool indices. Constants a function needs (string
  literals, anonymous values) become their own Atoms with content-hash symbol
  keys, deduplicated by the linker.
- The encoders (`src/codegen/x86_64/Encoder.zig`,
  `src/codegen/aarch64/Encoder.zig`) append instructions and produce an
  Atom's bytes and relocations; branches to local labels are patched in
  place and never become relocations. On aarch64, conditional branches and
  cbz/tbz reach only labels (±1 MiB, tbz ±32 KiB), calls to other symbols
  are `bl`, and addresses are adrp pairs. aarch64's `finish` patches every
  label reference at once and relaxes a conditional branch that does not
  reach into the inverted branch over a `b`, repeating until all reach;
  labels and relocations move with the code, and CodeGen maps the offsets
  it recorded (line rows, inline ranges, the code size) through
  `Encoder.finalOffset` afterwards, so it builds its `LineProgram` after
  `finish`. `adr` to a label and label-difference words (`labelDelta`)
  serve jump tables, as x86_64's `leaLabel` and `labelDelta` do (written
  after branch shortening, so a table needs no relocation; see
  "Switches"). Both were checked against the system assembler (GNU
  as for x86_64; clang's for aarch64, 32,771 instructions byte-identical,
  including every encodable logical immediate, plus 2,748 for the
  step-5 additions: LSE atomics, ldar/stlr, dmb, ccmp, clz/rbit/rev, cnt,
  fused multiply-add, every fmov immediate, q-register loads and stores,
  udf, adr, and a 1 MiB relaxation case).

#### x86_64 inline assembly (built 2026-11-05)

Templates are taken as upstream's self-hosted assembler takes them
(`airAsm`), so that a template assembles with both or neither, to the
same bytes. The general-purpose instructions go through
`codegen/x86_64/asm_insn.zig`, a table of instruction kinds:

- An Intel mnemonic with an optional AT&T size suffix (b, w, l, q),
  which sizes every operand: a register must have that size, a
  `%[name]` register takes it, and a memory operand needs it unless the
  instruction's size is fixed (`clflush`, `stmxcsr`, `fnstcw`).
- `lock` (on a memory destination of an instruction that takes it) and
  `rep`, `repe` or `repne` (on string instructions), on the
  instruction's line, emitted before 0x66 as upstream does.
- Condition families (`setcc`, `cmovcc`, `jcc`) with upstream's
  condition names, and instructions of CPU features (`popcnt`,
  `lzcnt`, `rdrand`, ...) only when `-mcpu` has them.
- Where encodings differ, upstream's: the accumulator forms of `xchg`
  and the ALU instructions, `d1` for a shift by 1, `cd 03` for
  `int $3`.

GNU as names upstream does not take (`movzbl`, `cltq`) and unsized
memory operands are refused with the name or suffix to use. bs also
refuses what upstream accepts but would fault or silently drop: `lock`
on a register destination or a `mov`, and a prefix alone on its line.
SSE through SSE4.2 and SHA go through `codegen/x86_64/asm_sse.zig`, a
table of forms (mandatory prefix, opcode, operand shape, the
general-purpose register sizes upstream's encodings take, feature):
register forms only, since upstream sizes no 128-bit memory operand (no
AT&T suffix names 128 bits, and a suffix would size the xmm registers
too), so a memory operand is refused with that reason, and `movq` and
the other names upstream refuses (`pavgb`, `pcmpistri`, `mpsadbw`) are
absent. `x` operands take xmm0-xmm7 and `{xmm0}`-`{xmm7}` constraints
pin one (std's `sha256rnds2`); xmm8-xmm15 hold the function's values.
`test/run/asm_x86_insns.zig` assembles 476 forms with both compilers
and compares each with upstream's bytes; a probe of 2012 SSE forms at
five CPUs (baseline, v2, +sha, +aes+pclmul, v3) matched upstream's
choice and bytes, which are GNU as's. `mov`, `lea`, `push`, `pop`,
branches, `crc32`, AES-NI, PCLMULQDQ and the VEX forms std uses stay in
CodeGen's `asmInst` (`asmSimd`), each on a CPU with its features. Errors point at the failing line of the template, found from
the last statement's position (`codegen/asm_src.zig`, which aarch64's
errors use too).

#### Container-level assembly (built 2026-11-05)

`comptime { asm (...); }` at container level, which upstream's
self-hosted backends drop (only its LLVM backend assembles it, so
upstream's langref `test_global_assembly` needs `-fllvm`), is assembled
into the module's code, on all three targets.

- Sema records each block as an effect of the unit that ran it
  (`Zcu.global_asm`: unit, source, and the `asm`'s location), where it
  used to return. Emit's `finish` (`codegen/global_asm.zig`) assembles
  each block into one `.text` atom owned by that unit, before the
  extern slots: x86_64 aligned to 1, aarch64 to 4, more with `.p2align`
  or `.balign` at the block's start. Its key is the unit's stable key and
  the block's place among the unit's blocks, so edit, eager and full
  builds give the same atoms.
- Instructions go through the target's inline assembler, one statement
  at a time (`CodeGen.GlobalAsm`: a CodeGen with only `emit`, `gpa`, `e`,
  `outermost_frame` and `global_asm` set, which is all the assembler
  reads; `fail` then reports at the `asm`). The driver adds what inline
  templates lack: named labels (`name:`), `.global`/`.globl`, `.set`
  and `.equ` with a symbol (an alias, which upstream's
  test/behavior/asm.zig makes of a Zig export), and accepts `.type`,
  `.text` and `.section .text`. Labels, globals and aliases are the
  module's, as LLVM assembles all of a module's blocks as one: a `.globl`
  in one block may name a label or alias of another, and a block of
  directives alone has no atom. Anything else, such as
  an unknown directive, instruction or operand, a named label or an
  external symbol as an operand, a `.set` of a number or of a symbol the
  module does not define, or alignment after the start, is a
  compile error at the `asm` (test/diag/global_asm.zig), never dropped
  code. Like other code generation errors, these errors need an output:
  `-fno-emit-bin` does not assemble.
- A `.global` label is a symbol at an offset in the atom
  (`Emit.asm_symbols`). `externTarget` binds external names to it first,
  so the extern slots of `extern fn` declarations carry the atom and
  offset, which a relink from the manifest restores
  (`externAliases`). C objects reach the labels at offset 0
  (`InputResolver.zigExport`), and objects and shared objects export
  those; a global label after the start is an error there. On
  aarch64-macos, `_name` is the C name `name`, as LLVM's assembler has
  it. Defining a name that a Zig export also defines, or one name twice,
  is an error. The atom is named after its first label: later labels
  are not in `.symtab` yet, since local symbols at offsets reach the
  link only from converted inputs, and a relink would lose them.
- The cache treats it like an `@export`: the unit gets an `analyze`
  reference, so an eager edit build analyzes it again rather than load
  it, and a lazy build that runs it again falls back ("container-level
  assembly ran again"). A lazy build that leaves the unit green takes its
  atom from the pack. Checked by test/run/global_asm.zig on x86_64-linux
  and aarch64-linux (edit builds with the block green, a relink equal to
  a full build) and run on a Mac satellite for aarch64-macos. A removed
  block's unit is outdated but never analyzed again (its namespace's
  scan no longer makes it), so a lazy build takes such `comptime`
  units for gone (`Replay.dropGoneComptime`), with their effects;
  before, it linked the assembly still (test/run/edit_global_asm_gone.zig,
  found by tools/edithunt's assembly edits).

### Optimizing backend (designed 2026-11-03, accepted by the owner; being built)

Step 1 is built (see "Landing it"). AGENTS.md fixes the goal: one optimization level, Debug
semantics, debuggable output, and optimization sized to compile fast. This
section fixes how: one shared SSA layer per function, a short fixed list of
passes, linear-scan register allocation, and a lowering per architecture.
It replaces CodeGen's internals, not its boundaries: the input is still
one function's typed IR, and the output is still one Atom and one
`Atom.Debug`, per function, cached as today.

**What the current backend costs.** Measured on libvaxis's text_input
(main 8fe40fe, ReleaseFast bs): 2,432 functions, 295k IR instructions,
3.09 MB of code, and 48–51 ms in `CodeGen.generate` with ZIR warm (the
lead measured about 92 ms of backend in a full build). That is about
170 ns and 10.5 bytes of code per IR instruction. Function sizes, in IR
instructions: 493 have 4–15, 990 have 16–63, 675 have 64–255, 254 have
256–1023, 20 have more. `Vaxis.render` is 138 KB (upstream Debug: 71
KB), 25k instructions, and its frame is 34 KB. In it:

| Pattern in `Vaxis.render` | Count | Fixed by |
|---|---:|---|
| a store to a slot followed by a load of the same slot | 1,033 | registers (pass 6) |
| `setcc` to a slot, `movzx` back, `test`, `jcc` | 702 | compare/branch fusion (pass 5) |
| `mov $imm, %ecx` and then an ALU op on rcx | 570 | immediates (pass 5) |
| calls to a panic handler (of 636 calls) | 374 | cold-block layout (pass 4) |
| `je` immediately followed by `jmp` | 607 | layout (pass 4) |
| `jmp` to the next instruction | 345 | layout (pass 4) |
| overflow bit materialized with `setb`/`seto` | 347 | overflow from flags (pass 5) |

Upstream Debug's code is 1.9–2.2× smaller on the largest functions
(`Vaxis.render`, `Parser.parse`, `sort.block.block`) and bs's binaries
run 0.83–1.28× as long as upstream Debug's, 2.6–21.6× as long as
upstream ReleaseSafe's (`bench/runtime.py`, below).

#### Principles

- **Per function, no interprocedural facts.** Every decision reads only
  the function's own IR (and, once inlining lands, the bodies it inlines,
  each through a recorded cache edge). Nothing reads a callee's register
  usage or frame size. That keeps each Atom a function of its unit's
  inputs, which the cache and parallel CodeGen both require.
- **Little code motion of memory operations.** Stores, calls, atomics,
  and inline assembly stay in IR order within their block, and so do
  loads, with one exception: a scalar load no write in its loop may change
  moves to just before the loop, under the alias rules of Forwarding
  (forward.zig), which also lets a load read a dominating store's or
  load's value. Pure values may be folded into their user (an immediate,
  an address, a compare into a branch) or removed when dead, but are not
  hoisted or sunk across blocks. There is no memory SSA, no general alias
  analysis, no GVN, and no LICM beyond those loads. Line tables stay in
  source order, which is what a debugger stepping a Debug build expects. This is a rule of the default mode's pass list,
  not of the SSA form or the allocator: nothing below assumes memory
  operations stay put, so a later mode can relax it.
- **A pass list per mode.** The driver runs the pass list of the build's
  mode. There is one pass list today, which ReleaseSafe builds
  (`builtin.mode == .safe`) share; ReleaseSafe may get its own after
  milestone 7, with more passes, including ones that move code. Passes read and write only
  the SSA, so a mode adds or drops passes without changing the others.
- **Room for facts.** The default mode's longer-term target is Go-level
  code, about 1.2–2× behind GCC and Clang, after inlining and a few more
  of Go's passes (bounds-check elimination, `prove`). So the SSA can carry
  facts that such passes use and produce, beside the values rather than
  in their ops: a value's known range, a block that is a failing check's
  cold path (the cold marks below), and that an operation cannot overflow
  after a check. Step 4's cold marks are the first such fact.
- **Safety checks stay.** Sema's checks are semantics; the backend keeps
  every one. It only makes them cheap: the failing path moves out of line,
  and the check reads the flags its operation set.
- **Fixed pass list, linear time.** Each pass is one walk over the
  function (layout and liveness walk blocks once in a precomputed order).
  No pass iterates to a fixpoint except branch shortening, which is
  bounded (below).
- **One layer, two architectures.** Construction, the passes, liveness,
  register allocation, frame layout, and debug bookkeeping are shared.
  Instruction selection, the ABI, register sets, and encoding are per
  architecture, behind tables and a few hooks (see "What is per
  architecture").

#### The SSA form

A function is a list of basic blocks in layout order; a block is a list
of values, then a terminator (`jump`, `branch`, `switch`, `ret`,
`unreachable`, or `noreturn_call`, which ends the block after an
ordinary call: it emits `call`/`bl`, never a jump, because a panic
handler prints the trace from its return address and needs the caller's
frame). A value has an op, a type class, up to three inline operands (more in an extra array), and a source
position. Operands are value indices or constants. Phis sit at the start
of a block, one operand per predecessor in predecessor order. All arrays
are flat (`std.MultiArrayList`), indices are `u32`, and a function's SSA
is allocated in one arena that is reset for the next function on the same
worker.

Type classes, chosen once per IR type by the shared layer, with the
architecture deciding the floating-point cases:

- **scalar**: integers up to 64 bits, bools, pointers, f32, f64, and an
  error code (`u16`). One SSA value, one register. f16 is a scalar on
  both, with native arithmetic on aarch64 (Apple Silicon has FEAT_FP16,
  in h registers) and compiler_rt calls on x86_64 (which take f16 in
  xmm registers). `c_longdouble` is f64 on Apple arm64.
- **pair**: values whose ABI layout is two scalars and that the IR takes
  apart field by field: slices, `{ T, u1 }` from the overflow
  instructions, error unions whose payload is a scalar (or void),
  optionals with a scalar payload and a flag (later, 128-bit integers).
  Two SSA values; `slice_ptr`, `slice_len`, `struct_field_val` of a pair,
  `unwrap_errunion_*`, and `optional_payload` become free renames.
- **memory**: everything else: larger structs, arrays, unions, f80,
  f128 (whose compiler_rt calls take it in xmm or q registers, loaded
  from and stored to the slot by the C ABI module), vectors other than
  those of up to 16 bytes of lanes (which are float class, in an XMM
  register, see "Vectors") and bool vectors of up to 64 elements (which
  are general, their bits), and integers over 128 bits. The SSA value is the address of a frame slot holding the value, which is written once by the instruction
  that defines it and read by its users; field reads are loads from that
  address. Wide integers and f80/f128 keep today's limb-wise and
  compiler_rt lowerings, and longer vectors are processed 16 bytes at a
  time, operating on these addresses.

**Narrow integers.** A register holding an integer narrower than the
register (u3, i7, u8, u16, and u32 on 64-bit registers) has unspecified
bits above the type's width. The lowering extends where the bits matter:
compares (aarch64 folds the extend into `cmp w, w, uxtb`), division,
right shifts, widening casts, overflow checks, and stores to memory. At
every boundary a value is normalized (zero- or sign-extended to its ABI
size, as today's invariant for memory): in memory, in call arguments and
results of both conventions (Apple's C convention requires callers to
extend arguments narrower than 32 bits), and in returns. So a value's own
slots (spills, results) and incoming arguments are known extended, and
lowering tracks that to skip redundant extensions. Memory the program
reads is not: memory written as another type of the same size (an
unsigned twin through `@ptrCast`, a packed union's other field, a union
built by `@bitCast`, raw bytes) may hold other bits above an integer's
width, so a load of an integer or enum whose width is not a whole number
of bytes extends from its width (`loadMem`; spill and argument reloads
use `loadKnown`), as upstream's LLVM build does (its x86_64 backend
trusts the bits). That costs one `and` or shift pair per such load:
callgrind Ir +0.6% on `zig fmt --check std` (Token.Tag is a u7 enum),
+0.16% on bench/runtime's fmt, within 0.02% on the others. x86_64 may use
8- and 16-bit forms where they give the same result.

The position is the IR's statement position (line, column) and the
innermost open inline call (an index into the function's inline table),
copied from the last `dbg_stmt` and `dbg_inline_begin`/`end` seen.

**Construction** is one forward walk over the structured IR, using Braun
et al.'s on-the-fly SSA construction (2013). The IR is structured, so the
walk always knows when a block's predecessors are complete: a `block`'s
exit is sealed when the walk leaves the block, a loop header when it
leaves the loop (after the last `repeat`). In the same walk:

- **Promoted allocs (mem2reg).** An `alloc` of a scalar or pair type
  whose pointer is used only as the address operand of `load` and
  `store` (never stored, passed, offset, or compared) becomes an SSA
  variable: each store defines it, each load reads it, and phis appear at
  merges. A store of `undefined` defines it as the 0xaa pattern, so a
  read of an undefined variable still sees what Debug semantics promise.
  (Without runtime safety Sema emits no store or `memset` of `undefined`
  at all, as upstream's backends make an unsafe one a no-op, so such a
  read sees whatever the variable held.)
  Which allocs qualify is found by one scan of the IR before the walk
  (per alloc: any use other than load/store address disqualifies it).
  Other allocs keep their frame slot, as today.
- **Trivial phis** (all operands the same value, or the phi itself) are
  removed as Braun et al. describe; this is also copy propagation.
- **Constant folding** of an operation whose operands are all constants
  (now possible after promotion), with the IR's exact semantics: wrapping
  arithmetic, shifts, compares, casts. A folded overflow check folds its
  branch, which leaves the panic block unreachable.
- **Conditions stay virtual.** A compare, `is_null`, `is_err`, or an
  overflow bit is a value of class *flags* when its only user is the
  terminator of its block, or a select in it; lowering then fuses it.
  Any other use materializes it as a bool (`setcc`), as today.
- **Cold blocks.** A block whose terminator is a call to a noreturn
  function (the panic handlers, `@panic`, `unreachable` in safe mode) is
  marked cold.

#### The pass list

In this order, each with the measured reason it is there:

1. **Build** (above): promotion, trivial phis, folding, conditions,
   cold marks. Removes the bulk of the store/reload traffic before
   register allocation sees it, because most of render's 1,033
   store-reload pairs are named variables and IR temporaries, not spills.
2. **Dead code.** One backward sweep with use counts: values without
   side effects and without uses go, and a dead value's operands lose a
   use, so chains go in the same sweep. Removes the unused halves of
   pairs (a `slice_len` nobody reads), loads whose result is dropped, and
   the code of unused `save_err_return_trace_index`.
3. **Block cleanup.** Blocks that only jump are bypassed (jump
   threading of empty blocks) and unreachable blocks (after folding) are
   dropped. One walk in reverse postorder. Before it, `Ssa.thread`
   (2026-11-05, not under `-ffuzz`, whose coverage points are these
   branches) threads two shapes. An `and`/`or` is a bool block whose
   exit only branches on its result: each `br` to it with a constant
   jumps to the branch's side, and each other `br` becomes that branch,
   on the `br`'s operand (the `br` still writes the result when the
   result has other uses). A labeled switch's `continue` that stores a
   constant to the switched local right before its `repeat` jumps to the
   case that constant selects, when the loop header is only the load
   and the `switch_br` and nothing else reads the load (a capture does,
   so a switch with captures keeps its dispatch). The store stays. No
   source line moves: the skipped code is the bool block's exit and the
   loop header, which hold no statements. `prove` sees the same edges:
   it keeps the facts known at each `br` to a bool block, per result,
   and a branch on the block assumes the facts of the matching exits.
4. **Layout.** Blocks are placed in reverse postorder of the hot
   successors, with each branch's cold side (the panic call, which in
   render is 374 of 636 calls) moved to the end of the function. A
   branch whose taken side is the next block inverts its condition so it
   falls through. This removes jumps to the next instruction (345 in
   render) and `je` + `jmp` pairs (607), and keeps hot loops dense. The
   order is fixed here; later passes do not reorder blocks.
5. **Lowering** (per architecture): instruction selection from SSA ops
   to machine ops with virtual registers. It folds what the architecture
   allows, asking hooks rather than assuming x86 shapes: an immediate
   that fits the instruction (570 immediate loads in render), an address
   into a load or store (x86_64 base + index·scale + disp; aarch64 only
   the forms it has), a flags value into its branch, select, or `setcc`
   user (702 materialize-and-test sequences), and an overflow bit into
   `jo`/`jc` (347 materialized bits in render). Flags give overflow only
   at the architecture's native widths: x86_64 8, 16, 32, and 64 bits,
   aarch64 32 and 64 (`adds`/`subs` and `b.vs`/`b.cs`). Other widths
   compare the result with its own extension (aarch64 `cmp w, w, uxtb`,
   or a `tst` of the high bits) and branch on that; aarch64 32-bit
   multiplication is `smull`/`umull` and `cmp x, w, sxtw`/`uxtw`, 64-bit
   `smulh`/`umulh` and a compare. The (value, flag) pair from
   construction covers all of them. Calls, divisions, shifts by a
   register, and string instructions get their fixed-register constraints
   and clobber sets here. A frame slot's address is "frame base plus an
   offset known after pass 7", not a constant, so folding it into a load
   or store is decided at emission (below). Constants are
   rematerialized instead of spilled when the architecture says
   recomputing costs no more than a reload (one load): most constants on
   x86_64; on aarch64 a 64-bit constant can take four `movz`/`movk` and an
   FP constant `adrp` + `ldr`, which spill like other values. A flags value is never
   spilled; if something clobbers the flags between a compare and its
   user, the compare is recomputed.
6. **Liveness and linear-scan register allocation** (below).
7. **Frame layout.** Spill slots, memory-class values, and the outgoing
   argument area share the frame by lifetime: two slots whose live
   ranges do not overlap get the same bytes (slots are assigned by the
   same linear scan, by interval end, and each slot has its own
   alignment: aarch64 q-register spills need 16 for the scaled form).
   Allocs that were not promoted keep
   their own slot for the whole function, because the IR does not mark
   where a variable's lifetime ends and its address may escape. Today
   every IR temporary has its own slot, which is how render's frame
   reaches 34 KB. The frame shape is fixed: the frame record at the top
   (x86_64 `push rbp`; aarch64 `stp x29, x30` first, fp = CFA − 16), the
   saved callee-saved registers right below it, then spills and slots,
   and the outgoing argument area at the bottom, at sp. x86_64 addresses
   slots from rbp (disp32 always fits). aarch64 addresses them from sp
   with positive scaled offsets, as clang does (sp stays fixed after the
   prologue, since the outgoing area is part of the frame), places small
   and hot slots nearest sp so their offsets fit `[sp, #uimm12 × size]`,
   and reads incoming stack arguments at `[fp, #16 + n]`.
8. **Emission.** Machine ops are encoded in layout order. Frame-slot
   offsets are resolved here; an aarch64 offset that does not fit its
   access becomes `add x16, sp, #hi, lsl 12` and `[x16, #lo]` (x16 is the
   in-instruction scratch). Line rows are written when a value's position
   changes, as today. Branches start in
   their short form (rel8 on x86_64; aarch64's ranges are fixed per form)
   and are lengthened when their target is out of range; each round only
   lengthens, so it ends after at most a few rounds (bounded by the
   number of branches, and in practice one or two). Because that moves
   code, line rows, `Debug.Inline` ranges, and unwind offsets are recorded
   against instruction indices and turned into byte offsets after the
   last round, on both architectures. The prologue, the
   epilogue, the stack probes (`___chkstk_darwin` on macOS), and the
   unwind record come last, once the frame size and saved registers are
   known.

Not in the list, on purpose: global value numbering, loop-invariant code
motion, strength reduction beyond what lowering's folding does, and
scheduling. (Bounds-check elimination by proof, which moves nothing, is
its own pass before the SSA: "Proving checks" below.) Each needs either analysis
that does not fit the budget or code motion that hurts debugging; they
can be measured later against the same benchmarks.

#### Register allocation

Linear scan on SSA form (Wimmer and Franz, 2010), over the blocks in the
layout order of pass 4:

- **Liveness** is one backward walk over the blocks in reverse layout
  order. The layout keeps each loop's blocks contiguous and puts every
  block after its dominator (cold blocks, at the end, have no
  successors), so only loops need more:
  a value live at a loop header is extended over the whole loop (to the
  end of its last block), which the walk does when it reaches the header,
  without iterating. Intervals have holes (a value live into one branch
  and not the other), which keeps registers free in cold paths.
- **Allocation** walks intervals by start. A value gets a register of its
  class (general or float/vector), preferring a hint: the register of a
  phi operand, a fixed argument or result register it is moved to, or the
  register of the operand an x86 two-address instruction overwrites. When
  none is free, the interval that ends last is split and its rest
  spilled; a constant is rematerialized at its next use instead. Values
  live across a call prefer callee-saved registers; others prefer
  caller-saved ones, so short functions save nothing.
- **Resolution.** Phis and split intervals become moves at block edges,
  sequenced as parallel moves (cycles broken with a swap on x86_64, a
  scratch register on aarch64). A critical edge that needs moves gets a
  block.
- **Callee-saved registers** that the function uses are saved in the
  prologue in a fixed layout per architecture, and restored in the
  epilogue: on x86_64 pushed right after `push rbp; mov rbp, rsp`, in
  register order; on aarch64 in whole pairs right below the frame record,
  in register order (what compact unwind's MODE_FRAME requires). The set
  is the unwind record's saved mask (below).
- **Registers.** x86_64: general rax, rcx, rdx, rsi, rdi, r8–r11
  (caller-saved) and rbx, r12–r15 (callee-saved); float xmm0–xmm15, all
  caller-saved. rbp is the frame pointer and rsp the stack pointer; neither
  is allocated. aarch64 (from the Mac thread's constraints): general
  x0–x15 (caller-saved, x8 the indirect result register) and x19–x28
  (callee-saved); never x18 (platform), x29 (frame pointer), x30 (link
  register), or x16/x17 (clobbered by bs's import stubs and by
  `___chkstk_darwin`; usable only as scratch inside one lowered
  instruction); float/vector v0–v31, of which only the low 64 bits of
  v8–v15 are callee-saved, so a 128-bit value live across a call is
  spilled even there.
- **Clobbers per call kind** are written out in the architecture's table.
  x86_64: a plain call clobbers rax, rcx, rdx, rsi, rdi, r8–r11, xmm0–15,
  and the flags. aarch64: a plain call clobbers x0–x17, x30, NZCV, v0–v7,
  v16–v31, and the high halves of v8–v15; a thread-local access through
  `tlv_get_addr` clobbers only x0, x16, x17, x30, and NZCV, provided the
  lowering loads the thunk into x16 (`ldr x16, [x0]; blr x16`; clang uses
  x9 and so clobbers it); `___chkstk_darwin` (prologue only) clobbers x9,
  x16, x17, and NZCV. compiler_rt calls follow the C convention.
- **Inline assembly** keeps values in registers around it.
  `Ssa.allocate` takes restrictions, each a register mask and per
  position a count of the lowerings that write those registers; a value
  takes none of a restriction's registers when such a lowering lies in
  its interval, at its definition, or at its last use. x86_64 has two:
  r11 (`usesR11`), and the registers inline assembly pins or clobbers
  plus rsi, rdi, r8, r9 and r11, which its `r` operands and output
  addresses may get. An asm statement is also an x86_64 clobber point.
  aarch64 restricts the registers an asm statement names; an asm
  statement is a clobber point there too (`callFree`), so the values
  that meet it keep out of v20-v29, which its SIMD operands get first.
  Sema records every register the clobbers name, by any of its names,
  as two masks by register number (`Ir.Asm.gpr_clobbers` and
  `vec_clobbers`, `Ir.Asm.clobberReg`); an asm statement's `r`, `w` and
  `x` operands take none of them, and the function saves the
  callee-saved ones.

**The `.auto` calling convention** follows from this, and stays private
to bs (nothing outside bs calls an `.auto` function, so it changes
freely; every caller and callee is regenerated together because bs's
identity is in every cache key):

- Arguments are classified like the C convention's register part:
  scalars and pairs in general registers (x86_64 rdi, rsi, rdx, rcx, r8,
  r9; aarch64 x0–x7) and floats and vectors of at most 16 bytes of lanes
  in vector registers (xmm0–xmm7; v0–v7, for vectors of 2 bytes or more),
  in order; a pair takes two consecutive general registers, and a pair that
  does not fit entirely in registers goes on the stack, never split.
  Arguments that
  do not fit go in the outgoing stack area. On x86_64, a memory-class
  argument (over 16 bytes) goes by reference, as one more pointer
  argument: memory holding the value that nothing writes during the call,
  which the callee reads in place (`Home.ind`; a `*const` copy Sema makes
  of the parameter is that memory too). Parameters are immutable, so this
  is the same as a copy: the caller passes a constant's own memory (a
  comptime table passed by value is not copied at all), a by-reference
  parameter's pointer, or a value's slot (values have no address anything
  could write through, and a slot is reused only after the call), and
  copies anything else, such as a load whose memory the callee might
  write, to its outgoing area. A parameter that gets no register is
  copied in at entry. `test/run/byref.zig` checks the aliasing cases
  (`f(g.*)` writing `g`, `s = f(s)`) against upstream's ReleaseSafe.
- Results: scalars and pairs in rax/rdx (x0/x1), floats and those
  vectors in xmm0 (v0);
  others through a result pointer passed in rdi (x8, the indirect result
  register, as Apple's C convention). Large aggregates stay in the
  outgoing stack area on aarch64 too (the callee reads them at
  `[fp, #16 + n]`); only the C ABI module passes aggregates over 16 bytes
  by reference to a caller copy, and HFAs in v registers.
- The error return trace pointer goes in a fixed register outside the
  argument registers: rax on x86_64 (free at a call: only variadic C
  calls use al) and x15 on aarch64, instead of today's r9. Not x9:
  `___chkstk_darwin` takes the frame size in x9 and counts it down, so a
  function with a frame over 4 KiB would lose the pointer in its
  prologue. The callee keeps
  it as a normal SSA value (an argument), so a function that never reads
  it frees the register at once.
- No registers are callee-saved beyond the platform's, so `.auto` and C
  share the clobber table and C calls (to libSystem, or exported
  functions) need no special casing beyond argument classification. The
  C convention stays exactly SysV / Apple arm64 (including Apple's
  deviations: callers extend arguments narrower than 32 bits, stack
  arguments packed at natural alignment, variadic arguments on the stack
  in 8-byte slots), and is the architecture's ABI module's job.

Today's `.auto` passes every argument in memory and returns most values
through memory; fib, which is almost only calls, runs 1.22× as long as
upstream Debug's.

#### Vectors (built 2026-11-04, x86_64 SSE2 to SSE4.2)

Explicit `@Vector` code is lowered to SIMD registers, as upstream's Debug
backend does, not scalarized. The split has three parts:

- **Which operations** (`src/codegen/vector.zig`, target-neutral):
  `native(cpu, ip, op, ty)` says whether the backend for `cpu` lowers
  `op` on vectors of type `ty` in SIMD registers. Lanes are integers of
  8, 16, 32 or 64 bits, f32 and f64; bool vectors are bits. Sema asks it
  before emitting an operation on whole vectors (`vectorNative`: runtime
  code only, not comptime blocks or bodies for the comptime evaluator, at
  least one runtime operand, no undefined elements, which the scalar
  path folds). Everything it answers false for is scalarized as before:
  each element is extracted (`array_elem_val`, or folded when
  comptime-known), the scalar operation is analyzed with its usual
  safety checks, and the results are reassembled with `aggregate_init`.
  So an answer may change only together with the backend. Sema asks
  for `Zcu.cpu`, the compilation's CPU (`main.resolveCpu`). On aarch64 it answers by architecture alone,
  since every ARMv8 core has NEON (f16 lanes, which need FEAT_FP16, are
  not lanes).
- **The IR**: the existing element-wise tags (`add_wrap`, `sub_wrap`,
  `mul_wrap`, `bit_and`, `bit_or`, `xor`, `not`, `add_float` ...
  `max_float`, `neg_float`, `abs_float`, `sqrt`, and `shl`/`shr` with a
  vector amount) carry vector operands,
  and six tags are vector-only: `min_int` and `max_int`, `cmp_vector`
  (a bool vector), `reduce`, `select`, and `shuffle` (whose mask is a
  comptime `@Vector(n, i32)`, negative lanes taken from `b`).
  Loads, stores, bitcasts and `aggregate_init` (a splat) are the usual
  tags on vector types.
- **x86_64 lowering** (`src/codegen/x86_64/vector.zig`, called from
  CodeGen's `genInst` and `planDeferred`): a vector of up to 16 bytes of
  lanes is float class, so it lives in an XMM register like an f64
  (spilled to a 16-byte slot) and is passed in one in `.auto` calls
  (`autoClass`); longer ones, up to 128 bytes, live in memory and each
  operation processes them 16 bytes at a time in xmm0–xmm5. A bool
  vector of up to 64 elements is its bits in a general register (in
  memory the bit-packed layout is the same bits). A load whose only user
  is a vector operation, or a bitcast of one, is read in place by that
  operation (`Home.deferred`, `Home.view`), so
  `@as(@Vector(64, u8), @splat(0)) != p[0..64].*` is four
  `movdqu`/`pcmpeqb`/`pmovmskb` triples and no copies. A bitcast between a
  16-byte vector and a 16-byte array, wide integer or f128 is one
  `movdqu` (`vector.lowers`), so `@as(V, @bitCast(p[i..][0..16].*))`
  loads straight into an XMM register, and the bitcast is no clobber
  point. The lowerings
  use only rax, rcx, rdx, r10, r11 and xmm0–xmm5, so none is a clobber
  point: a vector variable stays in xmm8–xmm15 across them, as a loop's
  accumulator does.

What the x86_64 backend lowers natively, at baseline SSE2: wrapping
add, subtract and negate and bitwise ops on integer lanes, multiply on
16- and 32-bit lanes (`pmullw`; `pmuludq` twice), `@min`/`@max` on 8- to 32-bit lanes
(`pminub`, `pminsw`, the other signedness with sign bits flipped,
32-bit lanes compare and blend), float add, subtract, multiply, divide,
negate, `@abs` and `@sqrt`, float `@min`/`@max` (`minps` with the
scalar lowering's NaN rule: `rhs` where `lhs` is NaN), compares to bool
vectors (unsigned through sign-flipped `pcmpgt`; floats with `cmpps`;
64-bit lanes only `==`/`!=`, which SSE2 lacks the ordering compare for),
`@select` (the predicate's bits spread to a lane mask), `@shuffle`
(`pshufd` when one operand's 32- or 64-bit lanes are permuted, else lane
by lane through memory), `@reduce` on integer lanes with `and`, `or`,
`xor`, `+`, `min` and `max` (not 64-bit lanes) and `*` (16- and 32-bit
lanes), as a tree of halves with the padding lanes set to the
identity, `@splat` (a constant one, which the rewrite rules may fold
from a call, loaded from read-only data), `@intCast` that widens
(`punpckl` with zeros or the lanes' sign masks, once per doubling; a
narrowing one keeps its per-lane checks and stays scalar) and
`@truncate` (pairs of chunks packed with `packuswb`, `packssdw` after
clearing or sign-extending what saturation would change, or `pshufd`),
bitwise ops and `and`/`or`/`xor` reductions on bool vectors, and `<<`
and `>>` by an amount that is the same in every lane (a constant splat,
or a runtime `@splat`, which Sema checks in `vectorShift`, since SSE
takes one count): `psll`/`psrl`/`psra` with an immediate or a count
register, bytes as masked words or, signed, as the high bytes of words,
and signed 64-bit lanes logically with their sign shifted in. So
`std.math.rotr` on vectors (BLAKE3's rounds) is four instructions and
inlines. A
compare against a constant that splits the lanes at their sign bit
(unsigned `x >= 0x80`, signed `x < 0`, their negations) is the sign
bits themselves, one `pmovmskb` or `movmskps`. Upstream's Debug backend scalarizes compares, selects and
shuffles; doing them here keeps results bit for bit (the same lanes,
padding never observable). Still scalarized: shifts by per-lane amounts
(AVX2's `vpsllvd`, past the SSE4.2 bs generates), overflow and
saturating arithmetic, division and remainder of integers, 64-bit
`@min`/`@max`, float reductions (a left fold, in element order, as
upstream; a tree would change the rounding and which zero `@min`
returns), integers wider than 64 bits, f16, f80 and f128, and anything
longer than 128 bytes or 64 bools.

With `-mcpu` features (`src/cpu.zig`; up to x86-64-v2, see "Deliberate
differences from upstream") CodeGen reads `Zcu.cpu` and uses: SSSE3
`pshufb` for every `@shuffle` of up to 16 bytes (one per operand with a
constant byte mask, `por`ed); SSE4.1 `pmulld`, the byte, word and dword
`@min`/`@max` SSE2 lacks (`pminsb`, `pminuw`, `pminsd`, `pminud` and
their `max`), so no sign flipping, and `pcmpeqq`; SSE4.2 `pcmpgtq`,
which makes 64-bit ordering compares, `@min`/`@max` and their
reductions native (`vector.native` answers by `cpu`). Features past
SSE4.2 (an explicit AVX CPU) change nothing here: the code stays SSE,
and the C ABI cases AVX would change are refused ("Where upstream
supports more"). Results are the same bits at every level; `-mcpu` is
part of the cache key (`cacheTarget`).

Compare bs with upstream bit for bit at a pinned CPU: `zig run
-fno-llvm -mcpu=baseline` (or `x86_64_v2`) against bs at the same
level. Upstream's default is the native CPU, and with AVX its Debug
backend lowers some vector operations differently: on an AVX host the
f64 `@reduce(.Min/.Max/.Add/.Mul)` of 16 lanes in a mixed NaN, infinity
and signed-zero test gives other bits than its own baseline build, which
bs matches.

**aarch64 NEON.** `vector.native`'s aarch64 arm answers as x86_64's at
SSE4.2 and adds `*` and `@reduce(.Mul)` on 8-bit lanes;
`src/codegen/aarch64/vector.zig` lowers them behind one check at the top
of `genInst` (`vector.lowers`, `vector.gen`) and the branch-fusion hooks
(`fusable`, `condFlags`). The IR and memory layout are the same as on
x86_64; bool vectors are bits in memory or a general register. Every
value still lives in a stack slot there, and vectors stay memory class,
so each operation loads its operands' 16-byte chunks into scratch V
registers (v0–v7, v16–v19) with `ldr q` (a shorter vector with the load
of its size, which zeroes the rest of the register), computes, and
stores the result's chunks. Lanes: `add`, `sub`, `mul` (no 64-bit),
`and`/`orr`/`eor`/`mvn`, `smin`/`umin` and `smax`/`umax` (64-bit lanes
through `cmgt`/`cmhi` and `bsl`), `fadd` ... `fdiv`, `fneg`, `fabs`,
`fsqrt`, and `fminnm`/`fmaxnm` (the scalar lowering's NaN rule).
Compares (`cmeq`, `cmgt`, `cmhi`, `cmge`, `cmhs`, `fcmeq`, `fcmgt`,
`fcmge`, operands swapped for `<`) give lane masks, gathered to bits by
an `and` with each lane's bit and `addp`/`addv`; `@select` broadcasts the
predicate's bits (`dup`), tests them (`cmtst`) and picks with `bsl`.
`@reduce` sets the lanes past the length to the identity and uses
`addv`, `umaxv`/`sminv`..., or halves combined with `ext`; `@shuffle` is
`tbl` (then `tbx`) over at most four source chunks at a time with a
constant byte index; `@splat` is `dup`; widening `@intCast` is
`ushll`/`sshll` per doubling and `@truncate` a tree of `uzp1`; shifts by
a splat are `shl`/`ushr`/`sshr` by an immediate, or `ushl`/`sshl` by the
broadcast (negated) count. Fusions, when the operand is the reduce's
only use and the value right before it in its block (no slot is taken
between): `@reduce(.Or/.And)` of a compare reads the lane masks with
`umaxv`/`uminv` and makes no bits, and the select of `firstTrue` and
`lastTrue` (below) becomes `rbit`/`clz` of the predicate's bits. A
reduce of bits that only its block's branch reads is fused into the
branch, as on x86_64. Not yet: deferred (in-place) loads, and keeping
vectors in V registers, which waits for register allocation there.

Measured on a Mac satellite (Apple M-series, mac.medium; ReleaseFast bs
against the scalarizing parent, 64 MiB inputs, best of 5;
2026-11-05), in ms: the ASCII decoder 46 against 690 (upstream Debug
53, ReleaseSafe 4.3), `utf16LeToUtf8` 41 against 398 (39, 1.4),
`mem.eql` 23 against 314 (285, 1.5), BLAKE3 1297 against 7368 (463,
32), four `splitScalar` passes 271 against 2668 (242, 44), eight
`indexOfScalarPos` passes 129 against 2691 (218, 10). What is left is
mostly the slots: each operation's loads and stores, and vector copies
through general registers. Compile time does not change (behavior, cache
off: 0.33 s both).

Narrow integers (`u4`, `i24`) sit in their ABI-size lane, extended as
in memory, so the operations that keep lanes extended treat them as
that lane: bitwise ops, compares, `@select`, `@shuffle`, `@min`/`@max`
and their reductions, and `~` of signed lanes (`vector.narrow`). Their
vectors stay memory class, so their ABI and bitcasts do not change.
`std.simd.firstTrue` relies on this: it selects from an iota of the
index type (`@Vector(16, u4)` for 16 lanes) and reduces with `.Min`;
CodeGen fuses that pair (`fuseIndexSelect`: an iota and a splat of at
least the last index) into a `bsf` of the predicate's bits, and
`lastTrue`'s `.Max` with 0 into `bsr`. So `mem.indexOfScalarPos` and
`splitScalar`, on `bs build`'s hot path, scan 16 bytes with
`pcmpeqb`, `pmovmskb` and `bsf`, as upstream's Debug backend does.

Measured (orb, 4 vCPU, ReleaseFast bs against main e89b24b,
2026-11-04; best of 3):

- The fuzzer's `PcBitsetIterator.next` takes 68 instructions per call
  on its 64-byte path, against 253; the compare itself is 23. A loop of
  25.6 M calls runs 3.1 ns per call against 11.3 (upstream Debug: 197).
  `bs build test --fuzz=3M --seed=1` of a `key=` parser test runs 6.2 s
  against 10.6 s (upstream LLVM, its build cached: 6.4 s).
- `splitScalar` over 64 MiB of 40- to 120-byte lines: 26 ms per pass
  against 137 (upstream Debug 238, ReleaseSafe 15).
  `indexOfScalarPos` over 64 MiB: 6.4 ms against 62 (Debug 138,
  ReleaseSafe 2.1). `indexOfScalar` and `eql` over 4 KiB: 4x.
- An f32x4 multiply-add loop with a u32x4 accumulator: 0.08 s against
  2.85 s (upstream Debug 0.19 s, ReleaseSafe 0.035 s).
- Of the behavior files, only x86_64.zig runs long enough to measure:
  178 ms against 195 ms.
- Compile time does not change (cache off, medians of 5): std's tests
  5.12 s against 5.16 s, x86_64.zig 8.66 s against 8.72 s, vector.zig
  0.174 s both.

#### What is per architecture

Shared (in `src/codegen/`): the SSA types, construction, passes 1–4,
liveness, linear scan, parallel-move sequencing, frame-slot assignment,
line rows and inline records, and the driver that runs them and fills
the Atom. Per architecture (`src/codegen/<arch>/`):

- **Register info**: classes, allocatable, callee-saved and reserved
  sets, argument and result registers per convention, clobber sets per
  call kind, and the callee-save layout (x86_64 pushes, aarch64 pairs).
- **ABI**: classification of parameters and results for C and `.auto`
  (SysV; Apple arm64 with its deviations and HFAs), variadic calls, and
  `va_list`.
- **Lowering**: the machine op set, as a table giving each op's operand
  constraints (defined and used registers, fixed registers, tied operands
  for x86 two-address forms, clobbers), so the allocator is shared; and
  the folding hooks: `immFits(op, value)`, `foldAddress(load or store,
  address value)`, and how a flags value lowers (x86 flags and `jcc`;
  aarch64 NZCV, `b.cond`, `cbz`/`cbnz`, `tbnz w, #0` for bools, `csel`,
  `cset`). `immFits(op, width, value)` returns the form that encodes
  the value, or none: aarch64 `add` against `sub` of the negation, `cmp`
  against `cmn`, the `lsl 12` form, bitmask immediates (which differ
  between 32 and 64 bits); `csel` takes no immediate (`csinc`, `csinv`,
  `csneg` cover 0 and ±1). The rematerialization cost of a constant.
  Globals: x86_64 RIP-relative; aarch64 `adrp` + `add`, or
  `adrp` + a load or store with `pageoff12` folded in only when the
  global's alignment is at least the access size (the linker rejects the
  rest).
- **Encoding**, branch shortening and relaxation (aarch64 `b.cond` and
  `cbz` reach ±1 MiB, `tbz` ±32 KiB, so the encoder relaxes an
  out-of-range one into an inverted branch over an unconditional one),
  prologue and epilogue, stack probes, and the unwind record. Encoder
  additions such as aarch64's LSE atomics (`cas`, `ldadd`, `swp`,
  `ldar`/`stlr`, on every Apple Silicon chip, so no LL/SC loops) do not
  touch the shared layer.
- **Switches** lower to compare chains in the first version, as today
  (a binary search over sorted cases when there are many). Jump tables
  come later: they need data inside the text atom (x86_64 a RIP-relative
  table of offsets; aarch64 `adr` to a label and label-difference words,
  `adr x, T; ldrsw x, [x, idx, lsl 2]; add; br`), which only the aarch64
  encoder has yet.

Flags are one implicit value on both architectures, never allocatable,
never spilled (see pass 5). Link-time values (error codes): x86_64 patches
them into an instruction's immediate field (`value16`/`value32`); aarch64 needs an instruction form for
them, and the cheapest is a new relocation kind that writes a link-time
value into a `movz` imm16 field (bs links its own output, so no external
linker must understand it), which makes an error compare `movz` + `cmp`
instead of `adrp` + `ldr` + `cmp`. Decide before aarch64 lowering depends
on either (relocation kinds are append-only). Decided and built as
`aarch64_movw_value16` (`Encoder.movWideValue`): the kind writes a link-time value into imm16 (bits 5–20) of a `movz`
(or a `movk`, with the shift taken from its `hw` field), and the linker
checks the opcode and that the value fits 16 bits. Error codes are u16,
so an error compare is `movz w16, #code; cmp wN, w16`, with x16 as the
in-instruction scratch; a `movk lsl 16` kind can follow if a 32-bit
link-time value is ever needed in code.

#### Debug info

- **Line rows** come from value positions, emitted in layout order when
  the position changes, as `Encoder.line` does today. Cold blocks keep
  their positions, so a panic call still maps to its check's line.
- **Inlined frames.** `dbg_inline_begin`/`end` (Sema's runtime inline
  calls, and the backend's inlining, which splices calls into that
  shape) set the position's inline
  index. Layout can split an inline call's code (its cold blocks move to
  the end), so emission writes one `Debug.Inline` entry per contiguous
  range, all with the same call information, as the link thread's
  contract already allows.
- **CFI and unwinding.** Frame pointers stay in every function that is
  not naked, so std.debug's frame-pointer walk and every debugger keep
  working. Saved callee-saved registers need more than today's
  `Atom.Debug.Frame` could say, so the function's unwind information
  became a small record (built 2026-11-03: `Atom.unwind`, an
  `Atom.Unwind` of `kind`, `saved`, `epilogue`, and `probes`; Mach-O ORs `saved`
  into UNWIND_ARM64_MODE_FRAME): frame kind (none, frame pointer, outermost),
  where the epilogue's `ret` is (u16, its distance from the end of the
  code, so the record stays 6 bytes and `Atom` 96; 0 for none), the
  length of the stack probes that end the code (u8; 0 for none), and a
  saved-register mask whose bits and layout each architecture fixes
  (x86_64: rbx, r12–r15, pushed in that order below rbp, giving each a
  `DW_CFA_offset`; aarch64: compact unwind's pair bits, x19/x20 = 0x1
  through x27/x28 = 0x10 and d8/d9 = 0x100 through d14/d15 = 0x800, which
  `__unwind_info` stores as is and which also give the DWARF offsets).
  Unwind information describes the code, not its debug info, and the Mac
  thread notes ld64 keeps `__unwind_info` in stripped links, so the
  record moves from `Atom.Debug` into the Atom itself. Whether stripped
  links write it is the linkers' decision. In the cache (reviewed by the
  cache thread): the kind takes `debug_frame`'s byte in the atom record
  header, and the mask and stack size two `u16`s of its unused bytes, so
  records stay 64 bytes; it is written for every atom (data atoms: kind none, mask 0),
  hashed by `contentsHash` (Incremental's function result hash stops
  mixing in `Atom.Debug.frame`), validated by `check` (a known kind, and
  only mask bits the architecture allows), and the pack magics are
  bumped. The field shape is the link thread's.
- **Variable locations** come later. Sema would emit a debug-variable
  marker (name, value) where a variable is declared; the SSA keeps it as
  a use that does not extend liveness; after allocation, each variable's
  intervals give a location list (register, or frame slot), stored in a
  new append-only `Atom.Debug` run and written as `DW_AT_location`
  loclists by the linker. Promoted variables then stay visible in a
  debugger; until then they are not (unpromoted ones keep their slot).
  This is the one debuggability regression the design accepts in the
  meantime (accepted by the owner, 2026-11-03), and it argues for landing
  locations soon after registers.

#### Inlining within a budget

Built on the IR, before the SSA: Emit splices small callees' IR into the
caller's IR in the shape Sema gives runtime inline calls, so the SSA
build, the passes, and the debug info treat them as Sema's inline calls
(`src/codegen/inline.zig`; Emit schedules it).

- **What inlines.** A direct call of an `.auto` function, not
  `never_inline`, not inside a cold body (one ending in `unreach` or
  `trap`: safety checks, `unreachable`), of a callee that is not
  recursive, not `noinline`, not variadic, has no inferred error set, and
  uses only instructions the splice maps (no `@returnAddress`,
  `@frameAddress`, inline assembly, error return trace access). Its size is its instructions with code
  outside cold bodies, less `block`s, their `br`s, `ret`s (a `br` once
  inlined), the fields of an overflow operation's result, pointer
  `bitcast`s, and the `alloc`s of `const` locals and parameters with the
  loads and stores through them, which the SSA promotes to registers
  (`Scanner.free`), plus each element of an
  `aggregate_init` with more than 8 (`@splat` of a runtime value has an
  operand per element: `std.mem.zeroes` of a 1 MiB array counted as one
  instruction, and its inlined copies cost 22 ms each in rewrite and
  sroa), plus the sizes of the
  callees inlined into it (mid-stack inlining); the budget is 24, and
  twice that for a call inside a loop of the caller (`loop_factor`: its
  cost is paid each iteration, its code once), and three times for a
  callee with no loop (`straight`, recorded in its `func_inline` result
  word) at a call inside a loop inside a loop (`nested_loop_factor`):
  tls's `ct_protected.mulWide` (63) in the Montgomery inner loop, −5.8%
  of tls-test's instructions. A callee with a loop of its own stays at
  twice: sort's `blockSwap` inlined into `block` was +0.9%. A function whose callees are
  not all inlined is not inlinable itself, so only leaves and functions
  that become leaves inline, but for calls of `std.lang.returnError` (an
  error return trace's push): the address it records is in the inlined
  copy, which maps to the callee's line and name as before (see "What
  users see"), so `std.math.add`, `sub` and ArrayList's `addOrOom`
  inline; every decision reads the callee's own IR, the same in every
  build and schedule.
- **Variants.** *Full*, the default, inlines any such callee; synthetic
  panic frames (below) keep its panic traces complete. *Safe* also
  requires that the callee can start no panic: no call of a cold
  `noreturn` function (safety checks, `@panic`, `unreachable`), which
  also excludes `try` adding to an error return trace, so every function
  on a panic stack keeps its own frame without synthetic frames. A
  function with `@trap` never inlines. `BS_INLINE=<budget>` sets the
  budget (`0` turns inlining off) and `BS_INLINE_SAFE=1` selects safe; a
  non-default setting gets its own cache target (`main.cacheTarget`).
- **When.** On the Sema thread, as Sema hands a function to the sink
  (`Emit.functionOwned`), before CodeGen gets it: `inline.scan` finds the
  candidate sites and the size, and `Emit.inlineFate` decides each
  callee, depth first. A callee not analyzed yet is analyzed out of queue
  order (`Zcu.takeFuncBody`, as `ensureFuncIes` does), and its own fate
  is decided and its IR handed to CodeGen in turn. A cycle of calls makes
  the call stay a call, for every function on the cycle. A callee whose
  analysis is in progress or waits on a speculation defers the caller to
  `ready_irs` (or, for a body made from the cache, leaves it without one
  for now) and never makes the call stay a call, so each decision reads
  only decided fates and depends on the program, not on the order
  functions finish in (edit builds analyze in another order). Each
  inlinable function keeps its body, already inlined into itself, for the
  rest of the build (`Emit.inline_bodies`); there is no waiting on other
  threads.
- **Splicing.** Each inlined call becomes a `block` with
  `dbg_inline_begin`/`end`, the arguments substituted for the callee's
  `arg`s, and each `ret` a `br` out of the block; the callee's `dbg_stmt`s
  are already relative to its declaration, as inline records want. In
  CodeGen, a memory-class block with exactly one `br` computes its value
  in the block's own slot (`planCopies`, `slot_alias`); without that,
  inlining made nbody 26% slower. The rule is general and stays on with
  inlining off. Likewise a `*const` alloc whose first use is its only
  store, of a constant in memory, is the constant's own memory
  (`planConstAliases`): a spliced callee's copy of a constant argument
  is then free, as the call's by-reference argument was (a 2205-byte
  comptime table, copied per call, made vaxis 30% slower). Any other use
  of a pointer into the alloc than loads, field and element addresses,
  and call arguments keeps the copy, so a write through `@constCast`
  writes a copy as it does upstream (`test/run/inline_const_arg.zig`).
- **The cache edge.** A dependee `func_inline: f`, appended to the
  dependee and manifest `Tag`s, with its producer edge to `f`'s `func`
  unit as `func_ies` has:
  - **Who records it.** Emit adds one for every candidate site's callee,
    inlined or not, to the caller's dependencies (`Zcu.addDeps`, after the
    ones Sema recorded). Otherwise an edit that makes `f` inlinable would
    leave a green caller with its call while a full build inlines.
  - **Its result.** `Zcu.inline_results` holds every inlinable function's
    size and hash; the hash mixes `f`'s canonical IR hash (`inline.
    hashBody`: instructions numbered by first appearance, InternPool
    indices by stable hash, names by their bytes, positions relative to
    `f`'s declaration, and the layout results of the containers whose
    values it holds or whose fields or elements it addresses: the IR
    names a type by identity and a field by index, and a caller lays out
    the fields as they are now, test/run/edit_inline_layout.zig; taken
    from the IR, not from `f`'s `type_layout` dependencies, which differ
    with the comptime tier that ran its calls), its inlined callees'
    hashes, its size, and the variant (`Emit.inlineSalt`: budget and full/safe). A function that is
    not inlinable has the result `salt ^ 1`, so edits to a large `f` do
    not touch its callers. The size is the node's one result word, and
    every inlinable function's node is recorded, as an inferred error
    set's is, so a loaded function without one is not inlinable.
  - **Returned lengths.** The edge also carries `ret_len`, which prove
    reads at calls that stay calls ("Proving checks"): when every slice
    `f` returns has an argument's length (`inline.retLen`, from `f`'s own
    body before its callees are inlined, recorded before its callees are
    decided so a cycle of calls reads it too), that argument plus one is
    the node's second result word and is mixed into the result hash. A
    function that is not inlinable but has one keeps a node too, with
    the size `not_inlinable`, and its result is `salt ^ 1` mixed with it.
  - **Replay.** Loading a function reads its `func_inline` node back into
    `inline_results`. When a caller's `func_inline` dependee is outdated,
    replay decides it with `Emit.inlineFate`, which loads or analyzes `f`
    first; if `f` cannot be decided now the caller is analyzed again. A
    caller that is red only through `func_inline` re-runs Sema, since IR
    is not cached. `BS_CACHE_CHECK` covers the edge without changes.
- **Getting the body on an edit build.** When a caller is analyzed and an
  inlinable `f` was loaded from the cache, Sema analyzes `f` again
  (`Emit.inlineBody`) and its own callees are inlined into it, without
  generating it: its atom, references, and dependencies stay the
  manifest's (the dependencies Sema records again are put back, since a
  lazy build takes a unit's from the manifest only when it has none).
  When a loaded caller's inlined callee moved and its declaration is not
  in this build (a struct in a test), the caller is analyzed again
  (`Replay.refreshInlines`).
  Storing IR in the cache instead would freeze an IR encoding and add
  store bytes for every inlinable function; it is the fallback if
  edit-build profiles ever show the re-analysis.
- **Cost and win** (4-core orb, ReleaseFast bs, cache off, medians):
  run time against inlining off, safe / full: sort −10% / −23%, hash −7% /
  −15%, nbody −13% / −12%, fmt 0 / +6%, fib and sieve unchanged. The zig
  workload's cold build costs +3.3% / +4.8% (9.29 s off), std's test
  build is within noise (7.2–7.4 s), and std's test binary grows 6% /
  19%. On the Sema thread the scan costs 90 ms on the zig workload, the
  body hashes 44 ms, and splicing 37 ms; the rest is CodeGen's 7% / 20%
  more IR. A call list from Sema would not save the scan: whether a call
  is in cold code and the hot size both need the body structure. With
  synthetic panic frames, full costs +5.3% on the zig workload (9.13 s
  off) and std's test binary grows 24%; run times are unchanged.
- **The size measure** (against counting every hot instruction, on
  main with the m7 backend stack and `planConstAliases`; run time in
  callgrind Ir, compile time as the median of per-round ratios over
  interleaved cold builds): leaving out blocks, `br`s and overflow fields
  lets leaves that measured big only on code prove removes inline
  (`std.fmt.digitToChar` measured 36). vaxis −1.7%, zig fmt −1.6%, the
  zls tests −1.5% outside std's unwinder (+1.3% in all: its stack
  captures miss SelfUnwinder's cache more), fmt +1.9% (the inlined
  `digitToChar` spills the other loop's variables in `printIntAny`), the
  other runtime benchmarks 0; std's test build +0.5–1%, the zig workload
  0, IR +5%, binaries +4% (std tests) and +9% (zig). A lower budget under
  this measure drops inlines that matter (at 24 nbody +27%, at 20 sort
  +15%).
- **The loop budget** (the same way, against the size measure alone):
  60 for calls inside loops gives sort −3.2%, vaxis −1.7%, hash −0.7%,
  zig fmt −0.4%, the zls tests −0.2% outside the unwinder (+2.5% in
  all), the other runtime benchmarks 0; std's test build +0.3% and the
  zig workload 0, IR +3%, binaries +3%. 100 adds little more (sort and
  hash within 0.1%).
- **Free slots and returns** (against the size measure above at budget
  30, with the loop budget; the same way): most small accessors measured
  over 30 on Sema's boilerplate, not on code (`Ast.tokenTag` 34 is 16
  instructions plus `MultiArrayList.Slice.items`' 18, half of them the
  `alloc`/`store`/`load` of `const` parameters and locals and `ret`s).
  Counting those free at budget 24 inlines `tokenTag`, `tokenStart`,
  `nodeTag`, hash_map's `capacity` and `Wyhash.init` (all 32–38 before):
  hash −4.0%, zig fmt −2.6%, sort −0.9%, vaxis and the other runtime
  benchmarks 0, the zls tests +2.0% (the unwinder, as above); std's test
  build 0.0% and the zig workload +0.1%, IR +1.8% (std tests) and +2.1%
  (zig), binaries +1.8% and +2.7%. At budget 30 the same measure adds
  hash and zig fmt −0.5% more, vaxis −0.6% and zls +1.9% for binaries
  +4.5% / +7%; at 20 sort loses its loop inlines (+7.5%).
- **Error-returning helpers** (against the measure above): letting a
  `returnError` call stay in an inlined body inlines `std.math.add` and
  `sub` (size 12) and `addOrOom` (14): the zls tests −3.3%, vaxis −1.3%,
  zig fmt −0.7%, the runtime benchmarks 0; std's test build +0.6% and
  the zig workload −0.1%, IR +0.8% / +0.5%, binaries +1.3% / +0.7%.
  `test/run/error_inlined.zig` compares the error return trace with
  `BS_INLINE=0`'s.
- **What users see.** std 0.17's stack traces print one frame per return
  address, named after the innermost inline range (`Dwarf.getSymbols`
  ignores inline callers, and `resolve_inline_callers` cannot help on
  ELF), so a panic inside an inlined function would show the callee's
  line and lose its callers' frames. Debuggers show both (they read
  `DW_TAG_inlined_subroutine`). Upstream Debug never inlines. Synthetic
  panic frames remove the loss.
  Error return traces are unaffected: their return-site addresses
  already map to the callee's lines.
- **Non-leaf callees (measured, not taken; branch `m7-inline-stubs`).**
  Letting a body that keeps direct `.auto` register-argument calls
  inline within a budget n, each kept call going through returning
  stubs (`call next; ret`, one per open backend-inlined call) so traces
  stay complete, measured against main 3a3fca3 (run time in callgrind
  Ir, compile time as medians of 11 interleaved cold builds): at n = 16, std's test build +1.1% and the
  zig workload +0.1%, IR +5–6%, binaries +9% (std tests) and +13% (zig);
  hash −1.1%, fmt and the other runtime benchmarks 0, vaxis −0.25%, zig
  fmt −1.2%, zls tests +2.8%. n = 20 costs +2% compile for −1.5% at best.
  A prototype's n = 30 win (vaxis −1.8%, zls −5.4%, zig fmt −5%, hash and
  fmt −4–5%) was illusory: it also inlined bodies with indirect (vtable)
  and other-convention calls, whose traces lost the inlined frames, and
  zls's share came from shorter traces, since its tests spend ~17% in
  DebugAllocator's stack captures; with complete traces, each inlined
  copy's stubs add distinct return pcs that miss SelfUnwinder's cache
  (`computeRules`, `CacheEntry.populate`). fmt's hot callees are over any
  budget (`Io.Writer.write` measures 114). What would change the answer:
  a size measure under which small hot callees fit (one that discounts
  the checks prove removes, for leaves like `std.fmt.digitToChar` at
  36), indirect
  calls through stubs (the stub calls r11) if vtable-heavy code shows a
  win, or an unwinder whose cost does not grow with distinct pcs.
- **Synthetic panic frames.** Only cold code changes. A panic call in
  cold code inside calls the backend inlined (`DbgInline.flags.backend`;
  Sema's inline calls lose their frame as upstream's do) calls a chain of
  stubs after the function's epilogue instead of the handler
  (`CodeGen.panicThroughStubs`, `emitStubs`): one stub per backend call
  open there, `call next` each, the last calling the handler. The call in
  the cold block is at the outermost such call's site, in its caller;
  stub k is at the site of backend call k + 1, inside copies of the
  inline entries open from call k up to it, and the last stub is at the
  check, so each return address maps to the line and name the uninlined
  program's frame has. The copies nest, so the debug info stays a tree.
  The stubs are frameless: `Atom.Unwind.epilogue` counts them after the
  `ret`, where the CFA is rsp + 8 and rbp and the saved registers hold the
  physical frame's values, so std's `SelfUnwinder` steps through them
  into the physical frame. The cold block does `sub rsp, 8` first when
  the depth is odd, so the handler is entered with an aligned stack. A
  function with stubs and no return gets an epilogue for its frame
  description. The hot path is untouched; the cost is 5 bytes per stub.
  A panic call with arguments passed in memory keeps the direct call
  (std's handlers take theirs in registers), and the stubs stop growing
  near `epilogue`'s 16 bits. `zig build test` compares
  `test/run/panic_inlined.zig`'s and `panic_trace.zig`'s traces with
  those of the same programs built with `BS_INLINE=0`. Limit: a hardware
  fault (a segfault from a bad pointer, a division trap) in inlined code
  has no stub, so the signal handler's trace shows the callee's line
  under the caller's name and loses the inlined callers. aarch64's
  variant: the stubs follow the blocks (aarch64 has an epilogue at each
  return) and each makes a frame record, `stp x29, x30, [sp, #-16]!;
  mov x29, sp; bl next` (12 bytes), so the frame-pointer chain and the
  frame record's unwind rule (CFA = x29 + 16) step through them, and the
  stack stays 16-byte aligned. `Atom.Unwind.epilogue` is the distance
  from the stubs to the end (the probes after them, on macOS, are
  `probes`). The FDE (aarch64-linux) restores the saved pairs' rules at
  the stubs (`Dwarf.stubsAdvance`; up to 104 bytes,
  `max_fde_size_aarch64`), and Mach-O gives the stubs a compact unwind
  entry of their own, frame mode without saved pairs, and the probes the
  function's again (`MachO.unwindParts`, in `__unwind_info` and objects'
  `__compact_unwind`). `zig build test` compares the traces with
  `BS_INLINE=0`'s for aarch64-linux (under qemu) and, on a Mac,
  aarch64-macos.

#### Unrolling

Built on the IR, after inlining and before scalar replacement and the
rewrite rules (`src/codegen/unroll.zig`, from `Emit.submit`): a `for`
loop in the shape Sema gives a loop over comptime-known arrays or a
constant range (a `usize` counter alloc set to a constant before the
loop, `i < N` against a constant, `i +% 1`, and no other use of the
counter) runs at most 8 times and copies at most 256 instructions in
all, becomes one copy of its body per iteration, each in a block that
`continue` exits, with the counter's load replaced by the iteration's
constant. `N` may also be the length of a slice built with a constant
length, directly or through a `const` local stored once, as
`std.mem.swap`'s loop over `@ptrCast` byte slices of `*T`. The copies reuse the inliner's `Copier`. The rewrite rules
then fold what the constants make constant: elements of the constant
arrays, and the bounds checks against their lengths, which are copied
like every other check and fold only where the constant proves them.
`MultiArrayList.slice` (2–5 iterations over its fields' sizes) is the
case that matters: zig fmt −2.9%, the zls tests −4.1% outside std's
unwinder.

#### Forwarding

Built on the IR, on the CodeGen workers before proving checks
(`src/codegen/forward.zig`, from `Emit.generateFunction`), so its cost
is off the Sema thread. Two passes over the tags skip functions with
neither a copy (a store of a load, or of an inline call's argument, into
a `const` aggregate local) nor two accesses through one base pointer, one
of them a load, by a 256-bit hash of bases. A pointer loaded from a local
stored once hashes as the pointer stored there, as the walk folds it
(each inline call's copy of `self` is such a local), and the order of the
accesses does not matter: the filter passes every function the walk
would forward a load in, so hash collisions, which depend on how
instructions and interned values are numbered, cost only a walk and
never change the output (a build that walks every function writes the
same std and zig binaries). One walk numbers the
instructions in body order and records, per local, whether its address
escapes (is used other than to load, store, or derive a field or element
pointer), its stores and its last use. Dominance is by position: an
instruction reaches the end of the body holding it, and a `block` left
only by the `br` ending its body passes that reach to its body. Three
rewrites use it:

- Copies. A `const` local of an aggregate, stored once with a whole load
  `p.*` (also through Sema's inline-call argument tuple) and only read,
  becomes `p` itself when the load dominates the local in the same loop
  and nothing may write `*p` from the load to the local's last read:
  when `p` points into a local whose address does not escape, no store
  into it (a call, atomic or assembly reaches it only through its
  address, so the by-value `ctx` of AES's `encrypt` keeps no copy of
  its key schedule across the round calls); otherwise also no store
  through an escaped or unknown pointer, returning call, atomic or
  assembly. A local forwarded already counts as the memory it copies.
  This removes the frame copy of `const x = p.*`, `const x = buf[i]`, and
  by-value parameters of inline calls whose callee only reads them.
  Scalar replacement leaves such copies of other memory whole for this
  (see Rewrite rules); splitting them loaded every field at the copy,
  which lengthened intervals (nbody +12% Ir).
- Loads. A load of a scalar (an integer or enum of at most 8 bytes,
  `f32`, `f64`, an error code, `bool`, or a pointer, slices included) through an ordinary pointer
  reads the value of a dominating store or load in the same loop through
  the same address: the same pointer value, or the same field of it,
  where a pointer loaded from a `const` local stored once counts as the
  pointer stored (each `self.x` reloads `self` from its parameter's
  slot). Positions are scanned in order, so any write in between, also
  in a branch not taken, forgets what it may overlap: a store forgets
  other fields of the same struct only if the struct's fields do not
  overlap, two locals never overlap, a local whose address does not
  escape overlaps nothing reached otherwise, a pointer parameter itself
  (not one loaded through it) never points into a local, and a
  returning call forgets all but those locals. Panics do not return, so safety checks forget
  nothing. Values do not flow around loop back edges. Loads straight
  through a local are left alone: `Ssa.plan` forwards and promotes those
  of scalar locals whose address does not escape (forwarding them first
  only lengthened intervals, fmt +3%), and the filter does not look for
  those of locals whose address escapes, which would walk nearly every
  function (96% of the zig workload's IR against 66%) for about 200
  loads.
- Loop-invariant loads. A load of such a scalar in a loop that the
  previous rule did not forward moves to just before its innermost loop
  (which becomes `block { loads; loop }` in its place) when three things
  hold. Its address, or the base of its field pointer, is computed before
  the loop or is a load that moves too (`self.in.buf.len`). No write
  anywhere in the loop's body, before or after the load, may overlap its
  memory by the rules above, and no returning call is in the loop unless
  the memory is a non-escaping local's; a write (or call) after which the
  path leaves the loop without repeating it counts only for loads later
  on that path (a tokenizer's keyword lookup as it returns a token). And
  a load or store through the same base runs on every path to the loop,
  at most 64 positions before it with no returning call or inline
  assembly between, or in the loop body before its first branch, call or
  assembly, so the moved load cannot fault where the loop body might not
  have run. Two loads of the same memory in a loop move as one. The moved
  loads take the line of the statement before the loop; safety checks do
  not move. This keeps `self.buf.ptr` and `self.buf.len` in registers
  across a tokenizer's loop, and lets prove see the bound of every
  `buf[i]` as the same value.

`BS_FORWARD=off` turns the pass off (its own cache entries, as
`+noforward`), to compare a program's behavior with and without it;
scalar replacement still leaves the copies whole.

#### Rewrite rules

Built on the IR, after inlining (`src/codegen/rewrite.zig`): a table of
peephole rules, pattern → replacement, as Go's generic `.rules`, applied
in one forward walk on the Sema thread as Emit hands a function to
CodeGen (`Emit.submit`). Each instruction's operands are rewritten
before it is matched, so chains fold in the same walk; a matched
instruction is replaced in every later use by an operand or a constant
(interned there, which only the Sema thread may do) and left for dead
code. Rules are matched per tag (a comptime index of the table):

- operations on constants, with the IR's exact semantics (wrapping
  arithmetic, shifts, division rounding, compares, `not`, `intcast`,
  `trunc`, `int_from_bool`); an undefined result (division by zero, an
  oversized shift, `minInt / -1`, an `intcast` that does not fit) is not
  folded;
- identities: `x + 0`, `x * 1`, `x & ~0`, `x | x`, `x - x`, `x ^ x`,
  `x * 0`, and the like;
- compares of a value with itself, and of an unsigned value with 0;
- reads of constants: a field of a constant struct, an element of a
  constant array at a constant index, a constant slice's `ptr` and
  `len`, a constant optional's or error union's state and payload, and
  the fields of an overflow operation on constants (so a check of `n - 1`
  for a constant `n` folds);
- reads through a wrapper: an optional's or error union's state, payload
  or error code read from the `wrap_optional`/`wrap_errunion_*` that made
  it (`return x` in a function that traces errors tests the error union
  it just built);
- a `bitcast` that only adds `const` to a local's pointer is the local's
  pointer: Sema makes a destructured `const` local that way, and its loads
  then read the alloc directly, which `Ssa.plan` can promote (with the
  bitcast in between, `const r, const o = @addWithOverflow(a, b)` kept
  both in memory);
- `!(a < b)` of integers, bools, enums or pointers is `a >= b` (and the
  other five compares likewise; not floats, where NaN makes both
  false): the `not` becomes the inverted compare in place, so the
  compare it read can die and the new one fuse into its branch
  (`if (!lessThan(a, b))` after inlining was `setb; movzx; test; jne`).

A `cond_br` whose condition became constant keeps only the taken body
(`Ssa.build`), in a block of its own, so a panic that now always runs
stays a cold block. Integers over 64 bits and floats are left alone (a
float compare of `x` with itself is false for NaN). Most matches come
from inlining, where a parameter becomes the caller's constant.

Before the rules, scalar replacement (`src/codegen/sroa.zig`, Go's
"decompose") splits each local struct or tuple of at most 8 scalar
fields (integers and enums up to 64 bits, `f32`, `f64`, `bool`,
pointers, slices) whose address is used only for field pointers, whole
loads, and whole stores into one local per field, which CodeGen then
keeps in a register. A field pointer becomes its field's local (as a
substitution the rule walk applies); a whole store becomes a store of
each field; a whole load becomes the fields' loads and an
`aggregate_init`, whose field reads a rule folds. Two neighbors make the
split structs' values flow without memory: a load of such a struct from
other memory, used only by field reads and stores, becomes its fields'
loads; and a store of a split struct's load to other memory (directly, or
as the result of an inlined call's block) becomes a store per field. A
`const` local stored with a whole load of other memory (or Sema's
inline-call argument holding one) is not split: forwarding (above)
reads that memory instead. A
block exited by one `br` that ends it is that `br`'s value, and its `br`
then writes nothing. Instructions are inserted by appending them and
rebuilding the bodies once, only in functions with something to split.

#### Switches

A `switch_br` whose case values are constants (`src/codegen/switch_br.zig`,
shared; built 2026-11-05) is lowered from its cases sorted by value, with
neighbors that go to one block merged: a greedy scan picks dense runs (at
least 4 cases covering at least 40% of a span of under 4096 values,
LLVM's thresholds, and at most 64 entries per block the table reaches,
so wide ranges to few blocks, as in Aro's `codepointWidth`, are searched
instead of filling kilobytes of table) as jump tables, and a binary search over the runs
reaches them, ending in compares with immediates when 3 or fewer runs are
left. The search tracks the values still possible, from the operand's ABI
size (an undefined `u4` is 0xaa) and the compares made, so a case at an
end of that range is one compare (`<= hi`), a table that covers it needs
no bounds check, and a compare already in the flags is not repeated. A
table is 32-bit offsets of the targets from the table itself, in the
code right after the indirect jump (x86_64 `lea r11, [rip + T]; movsxd
rcx, [r11 + idx*4]; add rcx, r11; jmp rcx`; aarch64 `adr x16, T; ldrsw
x17, [x16, idx, lsl #2]; add x16, x16, x17; br x16`); the encoder writes
the offsets once the code's layout is final, so the table is position
independent and no linker sees it. A value no case holds goes to the
else block, which keeps a corrupt or out-of-range operand on the safety
check's path. Items whose values the linker assigns (error codes) and
integers over 64 bits keep a compare per item, in order.

A case holds items and inclusive ranges (`Ir.SwitchBr`, read with
`Ir.switchCases`; ranges since 2026-11-05). Sema keeps range prongs in
the `switch_br` when the operand is an integer of at most 64 bits, and
only wider operands become `cond_br` chains (`switchAsCondBrs`). The
lowering takes a range as one case over its keys, so a range in a dense
run fills table entries and a range elsewhere is one `branchIn` (x86_64
`lea ecx, [rax - lo]; cmp ecx, hi - lo; jbe`) or one compare at an end
of the possible values; `prove` learns `>= lo` and `<= hi` in a range's
case like `==` in an item's.

#### Proving checks

Built on the IR, after the rewrite rules (`src/codegen/prove.zig`), as
Go's `prove` and `loopbce`: one forward walk per function on its CodeGen
worker (`Emit.generateFunction`, before `CodeGen.generate`) keeps the
integer comparisons known to hold at each point and removes a safety
check whose condition they prove, by making its `cond_br`'s condition a
constant (`Ssa.build` then builds only the passing side). Only branches
with a failing side (`unreach` or `trap`) are decided, and only toward
the passing side; nothing moves. Those include the user's own (`if
(!ok) unreachable`, `std.debug.assert`), except under `-ffuzz`, where
user branches are coverage points and are only learned from.

- **Values.** Facts relate values, not instructions. A load of a
  variable (an alloc only loaded from and stored to, found by one scan
  of the function first) is the value its last store stored when that is
  known, else the variable at a version. The version changes at each
  store, at each loop entry (a later store in the loop reaches the
  loop's start through the back edge), and where paths that stored it
  merge (after a `cond_br`, a `switch_br`, a loop, or a block not left
  only by the `br` to it that ends its body). A load's term is taken
  where the walk reaches it, not when a later compare asks: by then the
  variable may hold a later store. A `*const` alloc stored once is its
  value until paths merge, and a load of one of its fields that field of
  the value (numbered as `struct_field_val`, so whatever memory does in
  between): a field pointer into it, or the alloc cast to its own type
  (a copy forwarding turned into the memory it copied), reads it only
  through its loads, and a store through one, or any other use, makes
  it other memory. So each inlined helper's `self.metadata.?` on a
  by-value `self` checks the same value, and the facts of the first
  check that dominates decide the rest, in place: the checks that stay
  keep their lines, as all checks do. `slice_len` of equal slices are equal and of a
  `slice` its length operand, and of a call's result (or its error
  union's payload) the argument at the call that every slice the callee
  returns has as its length (`Allocator.alloc(T, n)` returns `n`
  elements; `Ir.ret_lens`, from the `func_inline` edge's `ret_len`; a
  callee that is inlined needs none), and a widening `intcast` of the same
  signedness is its operand. Terms are mathematical integers: a constant
  is its value whatever type it was written in, and each fact records
  its compare's type, which bounds an operand only the fact bounds. An
  undefined value is no term: a store of one forgets the variable, and a
  compare with one gives no fact.
- **Value numbering.** An instruction that writes no memory and computes
  the operation of an earlier one on equal terms (same result type, or
  for a compare the operands' type) is that one's term, so a fact on
  `s.len - i` or on `(a + b) & mask` holds where the same expression is
  computed again. `(a + b) - a` is `b` and `(x - c) + c` is `x` in one
  type, wrapping or not. Loads of other memory (`load`, `ptr_elem_val`,
  `slice_elem_val`, never volatile) are numbered by address term, type,
  and memory version: it changes at every instruction that may write
  memory or publish another thread's writes (all but a list of pure
  tags; calls, atomics, `memcpy`, `memset`, stores through pointers other
  than variables), at each loop entry and exit, and after a merge of
  paths one of which changed it. A check's failing side (only a call of
  its `noreturn` handler) does not change it, since nothing after it
  runs. Loading `self.len` twice with no write between is one value.
  A store to a slice's `len` field forwards to the next load of that
  slice, with no other write between (a store is a write, so it starts
  a new version, under which it records the length): after
  `self.items.len = n`, the slice `self.items` loaded next has length
  `n`, which proves `appendSliceAssumeCapacity`'s
  `self.items[old_len..][0..items.len]`. Other stores are not forwarded;
  recording them all cost 0.2-0.45% more compile instructions (tls.zig's
  and zls's tests) for no measured run-time win.
  The table of first instructions holds only those that ran on every
  path to the point walked: what a branch side, a switch case, a loop
  body, or a block body adds is dropped at its end, except a straight
  block's own and, for a block left by one `br`, what was in the table
  at that `br`. Knowledge that holds only where an instruction ran (an
  overflow operation's `exact`, read through the term of a later equal
  one) so never reaches a path where it did not.
- **Facts.** A branch's condition (a compare, `not`, the `and` of two
  in its true side, the `or` of two in its false side) holds in the
  side it leads to, negated in the other. What held at every `br` that
  leaves a block holds after it, so a check passed holds for the rest of
  its block (`s[i]` twice checks once) and an early return's negation
  holds after it (`if (n < 2) return n;`). The facts of a block's exits
  live in a list that only grows within the function, so a `br` to any
  enclosing block (a loop's `break`) carries them, and a failed loop
  walk restores the exits alone. A block left by a single `br` with a
  body that ends in `noreturn` (a loop's exit block) also keeps what the
  variables held at that `br` (at most 32 stored in it), as a new
  version naming the same values, and the memory version there, instead
  of forgetting them. A `bool` block (`a and b`, an inlined call
  returning `bool`) keeps what held at its exits per value: assuming it
  true adds what held at every `br` that may exit it true. Other `bool`
  values give the fact `b == 1` or `b == 0`. Deciding a `bool`
  condition handles `not`, `bool` blocks, and `a & b` / `a | b` by
  assuming one side and deciding the other. The 64 most recent facts are
  searched, which keeps functions with thousands of checks linear.
- **Step budget.** Assuming a condition and deciding one walk it as a
  tree (`not`, `and`, `or`, and through value numbering to the first
  equal instruction), so a condition reached along many paths is walked
  once per path: the zig workload spent 2.9 s of CPU in prove. Each
  top-level assume or decide takes at most 256 steps and then assumes or
  decides nothing more; it proves the same checks in 1.3 s.
- **Proofs.** A compare follows from a fact on the same operands, from
  constant bounds the facts give each operand (with `x < y` bounding
  `x` by the maximum of the fact's type less one), from `x < y` for
  `x + 1 <= y`, and back from `x + 1 <= y` for `x < y` only when the
  addition cannot have wrapped (an overflow operation whose check the
  walk passed, not `+%`). A block exited only with constants is bounded
  by them, a value by its own type's limits (a `u32` widened to `u64`
  stays below 2^32), and a wrapping addition, subtraction, or unsigned
  multiplication whose operands' bounds keep the result within its own
  type by the sum, difference, or product of theirs (two levels deep).
  An unsigned product wider than 64 bits (at most 128) of two widened
  values of at most 64 bits, or constants, cannot overflow when the
  product of their bounds fits, so `@as(u128, a) * b` for `u64`s loses
  its check and CodeGen's `mulWide` lowers the wrapping product left
  behind to one `mul`. A check of `a and b` (a switch prong's
  range) holds when both do; when only `a` is proven, the check tests
  `b` alone (`digitToChar`'s `10...35` prong after `0...9` checks
  `digit <= 35`). An overflow check of an addition, subtraction, or
  unsigned multiplication goes when its operands' bounds exclude
  overflow, or for `a - b` when `b <= a` holds (`i + 1` after `i < len`,
  `n - 1` after `n >= 2`); the operation's value read then becomes the
  wrapping operation, so the overflow bit is not computed. An overflow
  check whose overflow bit (by value number) was checked before goes
  too. `x - b <= y` follows from `x <= y` and `x - b < y` from `x < y`,
  or from `x <= y` when `b >= 1`, for an exact subtraction; `a <= a + b`
  for an exact unsigned addition; and `(x - k) + k` after an exact `x -
  k` cannot overflow. Constant bounds come from exact additions and
  subtractions, `%`, `@mod`, `&`, `>>` of unsigned values, `@intCast`,
  `@truncate`, `@min`, `@max`, exact unsigned products, from facts whose other side has bounds
  (transitively, depth-limited), and `t != k` at an end of `t`'s range
  moves that end. A compare the facts leave undecided is tried again
  with an operand replaced by a value a fact makes equal to it, directly
  or through one more equality (at most four others, never a constant,
  which bounds already read): after `assert(d.len == m.len)` and
  `assert(y.len == d.len)`, a loop to `m.len` indexes `y` without
  checks (`std.crypto.ff`'s `montgomeryLoop`). Facts name values, so a
  length loaded after a store or call is another value and no fact
  before it applies.
- **Offsets.** An unsigned value that is a chain of constant additions
  is `x + c`. From `x + c < y` (or `<=`), when no addition in `x + c`
  can have wrapped (each an overflow operation whose check passed, or
  one made wrapping by a proof, never `+%`), follow `x + d < y` for `d
  <= c` (`<=` when `d == c` and the fact is `<=`), and the same from `x
  + c' < y - k` for an exact `y - k` with `c = c' + k` (`for (1..n)
  |j|` counts to `n - 1`, and `j` is the count plus one), so `x <= y`, `x + d`
  cannot overflow, and a `+%` chain bounded so computes `x + d`; and `x +
  c <= x + d` for `c <= d` when both sums are exact. So `s[i..][0..16]`
  after `i + 32 < s.len` keeps none of its three checks, nor does the
  next block's at `i + 16`, derived from the exact `i += 16` that made
  the new `i`, not from a later load.
- **Loops.** A fact from before a loop on a variable the loop loads,
  `v + c < y`, is a candidate at the loop's start, where loads of `v`
  before any store name the variable at the loop's entry. The body is
  walked assuming the candidates; at every `repeat` each must hold for
  what `v` holds there (from the exit test before it, such as
  findScalarPos's `if (i + 32 >= s.len) break`), which by induction makes
  them hold at every iteration's start. If one does not, every decision
  of that walk is undone and the body walked again without them, so a
  loop is walked at most twice, and loops nested in a walk with
  candidates take none. An unsigned variable stored before the loop
  whose stores in it are each a constant within its bound, a difference
  that did not wrap, a remainder, a mask, or a minimum
  (`index -= 2`, `i = (i + 1) & mask`) is a candidate `v <= hi` for its
  largest value before the loop; `repeat` also accepts a value whose
  own bounds keep it within. Variables changed in a failed walk are
  restored from an undo log of their versions, which also restores them
  between a `cond_br`'s or `switch_br`'s sides.
- **Dead blocks after it** (`src/codegen/deadblock.zig`, after
  `prove.run`, in functions where it proved a check whose condition is
  not a compare). A decided check
  can leave a block whose value nothing reads: std's sort wraps the
  comparator as `lt = f(a, b); gt = f(b, a); assert(!(lt and gt));
  return lt` in Debug, and once the assert is
  decided the `lt and gt` block still built its diamond (`test; jne` to
  the next instruction), kept `gt`'s compare alive through its `br`, and
  gave `lt` a second reader, so it was materialized instead of fused.
  Such a block, when its body only computes values read inside it and
  branches within it (no call, store, check, or loop, at most 64
  instructions), becomes a void block with a single `br`; its body's
  values and the compares only it read are dropped, and `dbg_stmt`s go
  only with that code. sort −3.2% Ir; with the `not` rule in "Rewrite
  rules", −5.4%.
- **Turning it off.** `BS_PROVE=off` keeps every check (its own cache
  target, `+noprove`). A program whose output or panic differs between
  on and off has found a bug in a proof, with no oracle needed. The
  soundness argument for each rule is next to it in `prove.zig`; the run
  tests `prove_wrap`, `prove_load`, `prove_width`, and `prove_exit`
  each hold a program whose check a rule once removed unproven, and
  `prove_offset_wrap`, `prove_offset_store`, `prove_offset_loop`,
  `prove_offset_retry`, `prove_mem`, `prove_mem_merge`,
  `prove_mem_loop`, `prove_wrap_end`, `prove_sub`, `prove_bool`,
  `prove_assert`, `prove_rem`, `prove_mul_narrow`, `prove_mul_wide`,
  `prove_ret_len`, `prove_ret_len_arg`, and `prove_store_len` one that
  a wrong offset, loop, memory, range, product, returned-length,
  forwarding, or `bool` rule would remove.

#### Compile-time budget and how it is measured

The backend is budgeted per IR instruction, single-threaded, on libvaxis
text_input (295k IR instructions; today 170 ns each):

| Stage | Budget per IR instruction | On libvaxis |
|---|---:|---:|
| Build (construction, promotion, folding) | 40 ns | 12 ms |
| Passes 2–4 (dead code, cleanup, layout) | 20 ns | 6 ms |
| Lowering | 40 ns | 12 ms |
| Liveness and allocation | 60 ns | 18 ms |
| Frame layout and emission | 40 ns | 12 ms |
| Total | 200 ns | 59 ms |

That is about 1.2× today's backend on one thread, for code that should
be roughly half the size. The other half of the bill shrinks with the
code: half the bytes to hash into content keys, store in the cache, and
link. Parallel CodeGen (step 1 of "Parallel function bodies") takes the
backend off Sema's critical path; this budget keeps it from becoming the
long pole afterwards.

Measuring it:

- `BS_TIMING=1` prints a second line with each stage that exists so far,
  summed over functions, per IR instruction (`Emit.CodeGenStats`).
- `BS_BENCH_CODEGEN=n` makes bs keep a copy of every function's IR
  during analysis and then run the backend over all of it n more times,
  each into a fresh Emit, printing the fastest run's stages, code bytes
  per IR instruction, and frame bytes per function. `zig build
  bench-codegen` does that for the hello workload with a ReleaseFast bs;
  for libvaxis, set the variable on bench.py's build-exe command line.
  Deterministic enough for A/B comparisons in one session, and callgrind
  instruction counts of the same binary are exact.
- `bench/runtime.py` times the generated code (below). Every backend
  change reports its compile-time cost next to its run-time win, as
  AGENTS.md asks.

Generated-code baseline (main 8fe40fe, `python3 bench/runtime.py`,
medians of 5 runs on the 4-core orb):

| Program | bs | upstream Debug | upstream ReleaseSafe | bs / Debug | bs / ReleaseSafe |
|---|---:|---:|---:|---:|---:|
| fib | 188 ms | 154 ms | 72 ms | 1.22× | 2.6× |
| sieve | 497 ms | 417 ms | 117 ms | 1.19× | 4.2× |
| sort | 613 ms | 480 ms | 82 ms | 1.28× | 7.5× |
| hash | 384 ms | 463 ms | 39 ms | 0.83× | 9.9× |
| nbody | 418 ms | 442 ms | 19 ms | 0.94× | 21.6× |
| fmt | 205 ms | 160 ms | 17 ms | 1.28× | 12.1× |

Targets for the first version (registers, layout, fusion, `.auto` in
registers, no inlining): faster than upstream Debug on every program, and
within 3× of ReleaseSafe on fib and sieve. hash, nbody, and fmt are
dominated by small std functions (hashing, vector arithmetic, the
`Writer` interface) and need inlining to get closer.

#### Landing it

Each step keeps conformance at 2170/2170 and `BS_CACHE_CHECK` clean:

1. SSA construction and emission with no optimization: every op lowers
   through a fallback that is today's per-instruction code (operands in
   frame slots, scratch registers clobbered), so the output matches
   today's in behavior. This lands the data structures and the driver.
   Built: `src/codegen/Ssa.zig` builds blocks from the structured IR (a
   `block`'s exit, a loop header, both sides of a `cond_br`, a switch's
   else and cases) with every IR instruction as one `fallback` value, and
   x86_64 CodeGen emits the blocks in layout order, lowering terminators
   itself. A block's result stays the `block` value's memory, written by
   each `br`, until phis arrive with promotion; a loop's entry is a
   `fallthrough` terminator until layout (pass 4) owns block order. The
   output is byte-identical to the single-pass backend's (libvaxis
   text_input, hello), and the build costs 10 ns per IR instruction.
2. Lowering for scalar ops, the allocator, and frame-slot sharing; the
   fallback remains for wide integers, f80, f128, and inline assembly
   (which gets its constraints from the allocator later).
   Built, as an interim form of the design that keeps the per-instruction
   lowering: values are still IR instructions, and `Ssa.liveness` gives
   each one an interval in layout positions (extended over every loop that
   reads it without defining it) and counts clobber points. `Ssa.allocate`
   is linear scan without splitting: a value that does not fit is kept in
   memory for its whole life. When no register is free, the value that
   ends last goes to memory, unless the uses of one, weighted by loop
   depth (8 per level, `Live.weight`), weigh at most an eighth of the
   others': a value used a loop level less often goes first, so an inner
   loop's values keep their registers (SipHash's state). x86_64 values of scalar types (integers up
   to 64 bits, bools, pointers, error codes, optional pointers) that the
   lowering leaves in a register get one of rbx, r12–r15, which every
   lowering leaves alone and calls preserve, or, when their interval
   contains no clobber point, of rsi, rdi, r8, r9 (the scalar lowerings use
   only rax, rcx, rdx, r10, r11 as scratch; calls, string instructions,
   and the fallback clobber the rest). r11 is allocated too, to a value
   whose interval, definition and last use contain no lowering that may
   write it: `CodeGen.usesR11` and `termUsesR11` decide that before
   allocation (deferred loads and values in the function's result read
   through r11, as do loads forwarded from them, which take their home
   only when emitted, so the check looks through `Live.fwd`; division, bit counting,
   wide integers, odd-sized moves, calls, overflow bits, vector masks), and
   every lowering names r11 through `CodeGen.r11`, so emission fails the
   function where one does where they said it does not. A clobber point in a
   doomed block, one from which every path ends the function (a return,
   the panic call of a failing check, an error return's `returnError`
   call, or in a function without loops every block), matters only to
   the uses it can reach: later uses in doomed blocks that follow it,
   unless its block reaches no block that far in the layout
   (`Ssa.DeadArms`). A value used on a `try`'s success path does not
   cross the error path's call. A block's result crosses only the clobber
   points after its first `br`. Registers hold values extended to 64
   bits, a stronger rule than the narrow-integer rule above, which the
   lowering may relax later. A result may take its first operand's
   register when that operand dies there. Three pieces of later passes
   came along because they fall out of the intervals: a compare,
   `is_err`, or `is_null` used only by its block's branch is computed by
   the branch, an overflow operation whose tuple only its two field reads
   use writes the fields' registers directly, and values kept in memory
   share slots by interval (size classes rounded to 8 bytes up to 512).
   Functions with inline assembly keep every value in memory. The
   callee-saved registers a function uses are pushed after `mov rbp,
   rsp`, as the design fixes; until step 3's unwind record, the CFI did
   not describe them.
   On libvaxis text_input (`BS_BENCH_CODEGEN=10`): 10.46 → 6.49 code
   bytes per IR instruction, 992 → 708 frame bytes per function, and
   146–151 → 184–190 ns per IR instruction (liveness and allocation 49,
   emission 124 instead of 137). Callgrind on hello: `CodeGen.generate`
   271 M → 262 M instructions, of which planning (liveness, allocation,
   and the register classes) is 55 M. `bench/runtime.py`, step 1 against
   step 2, medians of 5 (upstream Debug and ReleaseSafe as measured with
   step 2): fib 199 → 124 ms (Debug 157, ReleaseSafe 70), sieve 559 →
   291 (383, 119), sort 614 → 410 (453, 85), hash 379 → 247 (438, 37),
   nbody 428 → 384 (468, 20), fmt 201 → 145 (167, 17): faster than
   upstream Debug on all six, and within 3× of ReleaseSafe on fib and
   sieve.
3. `.auto` in registers, and the unwind record in the Atom (with the
   link thread).
   Built. The link thread's `Atom.unwind` (kind, saved mask, stack size)
   replaces `Atom.Debug.frame`, is written for every atom and cached in
   the atom record header, and gives each pushed register a
   `DW_CFA_offset` after its push in .eh_frame. `.auto` passes values of
   up to 8 bytes in rdi, rsi, rdx, rcx, r8, r9, values of 9 to 16 bytes
   in two consecutive ones (their bytes as eightbytes; a pair never splits
   with the stack), f16, f32, and f64 in xmm0–xmm7, larger values by
   reference (a pointer; see the `.auto` calling convention above), and the rest in the
   outgoing area; results in rax (and rdx) or xmm0, larger ones through a
   pointer in rdi, which then takes the first argument register. The
   error return trace pointer is in rax; a function that neither reads it
   nor calls does not store it. The prologue moves arguments that got a
   register there with a parallel move. Pairs (slices, error unions) still
   live in memory inside a function until the SSA has a pair class.
4. Layout, fusion, overflow from flags, dead code, and branch shortening.
   Built. Functions start on a 64-byte boundary (a cache line), so a
   function's speed does not depend on the sizes of the functions placed
   before it; this costs about 4% of .text. `Ssa.place` (passes 3 and
   4) bypasses blocks without values
   that only jump (a `repeat`, a `br` without a result, a fallthrough)
   and orders the rest for emission (`Ssa.order`): a block ending in a
   call of a noreturn function is cold and goes to the end, and a branch
   falls through to whichever side follows. Positions for liveness,
   allocation, and slot sharing stay in the structured IR's order rather
   than the emission order: a cold block ends the function and defines
   nothing others read, so it runs the same at the end with the registers
   it has in place, and its values get slots of their own (slot sharing
   assumes emission in position order). Each cold block starts with the
   row and the inlined calls open where it was (new `Debug.Inline`
   entries with the same call information). An overflow operation whose
   bit only its block's branch tests leaves it in the flags: at 8, 16,
   32, and 64 bits the operation runs at that width and the branch reads
   its carry or overflow flag (8-bit multiplication excepted), other
   widths compare against the truncation. Pass 2 leaves out values
   without uses whose computation has no effect, in one backward sweep
   after liveness. The encoder shortens `jmp`/`jcc` to rel8 when in reach
   (not in functions with inline assembly), re-encoding once and moving
   relocations, labels, line rows, inline ranges, and the frame patch.
   Error unions get their error code written through the padding before
   the payload (up to 8 bytes), so whole-word reads forward from the
   store. Against step 3 (main 4a5232b), libvaxis text_input
   (`BS_BENCH_CODEGEN=10`, two runs): 6.26 → 5.58 code bytes per IR
   instruction, 210–218 → 234–238 ns per IR instruction (build +4 for
   `place`, liveness and allocation +4 for the dead-code sweep, emission
   +12, of which shortening is about half); std's tests (`bs test
   upstream/lib/std/std.zig --test-no-exec`, `BS_CACHE=off`): 7.8–8.3 →
   8.0–8.4 s, 6.70 → 6.03 code bytes per IR instruction.
   `bench/runtime.py`, same session: fib 135 → 128 ms, sieve 316 → 303,
   sort 448 → 421, hash 300 → 297, nbody 457 → 456, fmt 155 → 149. What
   remains is mostly memory traffic: block results and loop variables
   through slots, slices and floats through memory (promotion, step 4's
   successor). The decisions that do not depend on the architecture (dead
   values, overflow pairs and bits left in the flags, branch-condition
   fusion, unused arguments) are `Ssa.plan`, run after `liveness` and
   recorded per value as a `Live.fate` beside its register; the
   architecture answers `inGpr`, `fusable`, and `ovfFlagsOnly`.
   Promotion, the next piece, is built in an interim form without
   renaming: `Ssa.plan` promotes a non-volatile alloc whose type is in a
   register (`inGpr`) or two (`inPair`) and whose address is only loaded
   from and stored to (one count per candidate in the pass `plan` already
   makes), and the variable keeps one register, or pair, for its whole
   interval, which liveness already extends over the loops that use it,
   so no phis are needed; a block's result is likewise one register that
   each `br` writes. A load shares its variable's register when the
   variable's interval contains the load's and no store to the variable
   lies inside it (`Live.share`); `allocate` keeps such a variable from
   being evicted while loads share it. A pair class (`want_pair`,
   `Live.reg2`) holds 16-byte values as their two eightbytes: on x86_64,
   slices, optional slices, and error unions with an 8-byte payload
   (error code low, payload high), which loads, `slice`, element reads,
   `.auto` arguments and results, and the error-union and optional
   operations produce and read in registers; other code reads a pair
   from a spill slot written at the read. A pair gets two free registers
   or none, and is neither evicted nor tied. Error unions of up to 8
   bytes are in one register (error code in the low 16 bits). So are
   loads and block results of other aggregates of 1, 2, 4, or 8 bytes
   (`inGprBytes`: their bytes, extended like a load); code that reads
   one from memory takes a copy (`memOf`). Against
   main 40b29a8, libvaxis text_input (`BS_BENCH_CODEGEN=10`, three
   runs, idle): 5.58 → 5.15 code bytes per IR instruction, 698 → 687
   frame bytes per function, 210–211 → 212–224 ns per IR instruction
   (allocation 54.5 → 64–68, emission 139–140 → 132–139); the encoder
   now counts the branches before each label when binding it instead of
   searching for them, which pays back part of shortening. std's tests
   (`BS_CACHE=off`, `BS_TIMING=1`): 292 → 285 ns per IR instruction
   (allocation 63 → 71, emission 211 → 197), 6.03 → 5.63 code bytes per
   IR instruction, wall time 6.53–6.58 → 6.55–6.60 s. `bench/runtime.py`,
   same session: fib 123 → 118 ms, sieve 268 → 137, sort 370 → 291,
   hash 239 → 239, nbody 405–410 → 407–449 (noise), fmt 134 → 114.
   Still to come: renaming (a variable in different registers on
   different paths), floats in registers (below), and copy elision for
   larger aggregates.
   Dead fills, first in `plan` (`Ssa.deadFills`): a store of `undefined`
   (the 0xaa fill) into a local whose address only loads, stores, and
   field and element pointers see is `dead` when every byte it
   fills is written again before any read on every path from it, or not
   read before the function ends; nothing can observe it then. A
   backward dataflow per local (up to 16) over the blocks, to the greatest
   fixpoint, of the bytes written before they are read, in up to 64
   chunks; a load reads its value's bytes, not padding. A `for` loop over
   a counter whose every iteration writes element `i` wholly (`for (0..16)
   |j| a[j] = ...`, nested too: blake3's `transposeMsg`) counts as a
   write of the elements it covers where it exits. Upstream's
   ReleaseSafe drops the same fills through LLVM; heap fills (`alloc`,
   `free`) and fills of locals whose address escapes stay.
   Division, after it: unsigned division by a constant divides without
   `div` (a shift and mask for a power of two; else a multiply by a magic
   number, Granlund and Montgomery 1994, with the add-and-halve fixup when
   the multiplier needs 65 bits; a quotient of 0 or 1 by compare for
   divisors above half the range), and unsigned division by a variable
   uses the 32-bit `div`, always up to 32 bits and, as LLVM's slow-divide
   bypass, when both 64-bit operands fit (2.0 against 3.4 ns per divide on
   the bench machine). Signed division keeps the 64-bit `idiv`: Sema
   guards only `minInt / -1`, and a 32-bit `idiv` traps on `minInt % -1`.
   A `/` and `%` of the same operands still divide twice; Sema's
   divide-by-zero checks put them in different blocks, so merging them
   needs value numbering across blocks. Against main 31f715c: fmt 107–112
   → 97–108 ms (its hex digits divide by a runtime base), the other
   benchmarks within noise; libvaxis 5.02 → 5.03 code bytes per IR
   instruction and CodeGen ns per IR instruction within noise; std's
   tests the same wall time, binary +8 KB.
   Floats in registers, after it: f32 and f64 are a third register class
   (`want_float`; `Ssa.allocate` takes `n_float` registers numbered after
   the general ones, and `plan` promotes variables of `ctx.inFloat`
   types). On x86_64 the class is xmm8–xmm15: lowerings use xmm0 and xmm1
   as scratch and calls pass arguments in xmm0–xmm7, so homes never
   overlap either, and since every XMM register is caller-saved, only a
   value whose interval crosses no clobber point gets one (no `.auto`
   callee-saved XMM registers yet). In registers: arithmetic, min/max,
   negation and `@abs` (a sign mask), `@sqrt`, f32↔f64 casts,
   integer-to-float conversions, loads, field and element reads, `.auto`
   arguments, call results, block results, and promoted variables. The
   ordered comparisons (`<`, `<=`, `>`, `>=`) fuse into their branch
   (`ucomis` and `a`/`ae`, with the operands swapped for `<` and `<=`,
   so NaN is false); `==` and `!=` need two flags and give a bool in a
   register. A float operation is no longer a clobber point, and neither
   is a float `ret`. Other code reads a float in a register from a
   spill slot written at the read (`spillXmm`), or through `movq`.
   Against main 8d05200: nbody 421–448 → 312–313 ms, the other
   benchmarks within noise (`bench/runtime.py`, two interleaved runs);
   libvaxis code bytes per IR instruction unchanged (5.03) and CodeGen
   ns per IR instruction within noise (229–235 for both, allocation
   about +2); std's tests 6.65/6.39 → 6.68/6.51 s, allocation 69–75 →
   74–77 ns per IR instruction, binary −26 KB.
   Copy elision, after it, in six parts:
   - Forwarding (`Ssa.plan`, shared): a `*const` alloc whose uses are
     loads and one store of an instruction's value, which comes before
     the loads in the layout, is not emitted, nor is its store; each load
     is that value (`Live.fwd`) and shares its home, so the value's
     interval grows over the loads' intervals and the loops around them.
     Sema makes such an alloc for every `const` local and capture, which
     promotion gave a register and a move of their own.
   - Frame addresses: a field pointer, or an element pointer with a
     constant index, of an alloc in the frame is itself a frame address
     (`Home.frame_addr`): no register, no code. Of a pointer that wants
     a general-purpose register, it is a register address
     (`Home.reg_addr`, `addrFoldable`): its users address `[base + off]`,
     and the base's interval grows over theirs (and crosses what they
     cross) right after liveness; if the base gets no register, the
     pointer is computed as before. A slice's `.ptr` or `.len` of a slice
     that wants two registers is that register the same way
     (`pairFoldable`): no move into a register of its own before each
     bounds check.
   - Initializers and results (`planCopies`, before liveness): a `*const`
     alloc stored to once with a value that always lives in memory is that
     memory when the value is in place first (an argument in the incoming
     area, or a slot that is then not shared); a value initializes at most
     one alloc, so addresses stay distinct. In a function returning
     through memory, a non-const alloc of the result type whose load every
     `ret` returns as its block's last value is the result memory: its home
     is the caller's pointer, and the load and the copy go. Other `ret`s
     may return a constant or an error (`wrap_errunion_err`), copied as
     usual, and the load may come before the `ret`'s block, where an error
     union's check for the error return trace reads it, when it is in no
     loop, its other users only test it for an error, and the alloc's
     address is only loaded from, or stored to before the load
     (`rvoEarlyLoad`); then the load reads the result in place. An error
     is copied as its code alone, without its undefined payload. A
     variable initialized once, outside loops, by `f() catch unreachable`
     (a block whose only `br` passes the payload of a call's error union
     in memory, which is otherwise only tested for an error), with every
     other use after that store, shares one frame region with the call's
     result and the block (`payload_region`): the error union, of which
     the variable is the payload. flate's `Compress.init`, a 230 KB
     result: its frame 0xa88f8 → 0x38348 bytes (upstream 0x383f0), and a
     `var c = Compress.init(...) catch unreachable` caller's 0xb8928 →
     0x48388 (upstream 0xb8990).
   - Call arguments and results (`planDeferred`, before allocation): a
     load of a value in memory whose only user is a later `.auto` call, or
     the `ret` of a function returning through memory, in the same block,
     with nothing between that writes memory, is read in place by the call
     or `ret` (`Home.deferred`), and its pointer lives until then.
   - Stored aggregates (`planDeferred`): an `aggregate_init` or
     `union_init` in memory whose only user is the store right after it
     is built in the stored-to memory (`in_place`); no element is read
     from memory lazily, so writing it early changes nothing. So is the
     payload of a call's error union (`p.* = try f()`), copied straight
     from the call's result.
   - Returned calls (`planRetCalls`, before allocation, both backends):
     in a function returning through memory, a call of an `.auto`
     function returning in memory whose value a `ret` returns, as it is,
     through an inferred error set's bitcast, or as an error union's
     payload (`return try f()` unwraps and rewraps it), gets the caller's
     result pointer, and the values between them read the result in
     place (`Home.result`). The result holds one such value at a time:
     calls whose chains' intervals overlap another's, or the result
     alloc's, keep their slots. Each level of `return f(x)` held one more
     copy (sandopolis's 64 MiB test stack overflowed).
     With them, a `@splat` (an `aggregate_init` of one repeated element)
     over 128 bytes writes the element until it spans 64 bytes, doubles
     that by copies up to 512, and repeats it with one overlapping
     `rep movsb` (below a 512-byte distance that leaves the fast-string
     path). A 16 KB splat of a 128-byte struct into a result, returned
     through an over-aligned alloc: 28,915 → 647 code bytes, 4,125 → 91
     movs, frame 0xc210 → 0x4190 bytes, 21.0 → 3.4–4.8 s for 10M calls
     (upstream Debug 3.4–3.7 s; the spread is the 16-aligned frame's
     placement against 64-byte lines). Compile time within noise on std
     and the zig workload; std's binary −87 KB. aarch64 writes the
     element until it spans 64 bytes and repeats it with one forward
     `copyMem` (32 bytes a loop iteration): `std.mem.zeroes` of an 8 MiB
     array went from 8 million `strb`s (a 100 MB function) to a loop.
     A splat of a scalar of 1, 2, 4 or 8 bytes is now one `rep stos`
     (`fillSplat`), except from 129 bytes to 1 KB, where it, an undefined
     fill (`fillMem`) and an `@memset` of an array are a loop of 64-byte
     blocks of `movups` stores of the element repeated in xmm0
     (`fillLoop`): `rep stos` takes about 8 ns to start, and the loop
     fills 129 bytes in 2.7 ns and 1 KB in 10.1 (13.5 for `rep stosb`).
     An `@memset` of such an element (`memsetScalar`) into an array of up
     to 128 bytes is straight stores; into a slice it branches on the
     length in bytes: two overlapping stores up to 16, 16-byte stores from
     both ends up to 64, a loop of 64-byte blocks and an overlapping last
     block up to 1 KB, and `rep stos` above. `rep stosb` takes 3 to 4 ns
     up to 128 bytes and about 8 from there; `rep stosw`, `stosd` and
     `stosq` take 10 to 20 ns at any small size.
   nbody's `Vec.sub` went from 64 instructions to 26. Against main
   2cc5b3e (`bench/runtime.py`, two interleaved runs): nbody 279–283 →
   158–174 ms, hash 224–236 → 185–191, fmt 100–103 → 92–93, sieve and
   sort within noise; fib 117–123 → 139–141 with byte-identical code for
   `fib`, only placed at another address. libvaxis: 5.03 → 4.49 code
   bytes and 687 → 377 frame bytes per function, CodeGen 214–222 →
   218–220 ns per IR instruction (allocation +9, emission −5). std's
   tests: wall time within noise (6.50/5.98 → 6.23/6.27 s), allocation
   +11–17 ns per IR instruction, 5.50 → 4.88 code bytes per IR
   instruction, binary 52.2 → 49.1 MB.
   Copy coalescing, after inlining: values computed straight into the
   register a move would take them to.
   - A value whose only use stores it to a promoted variable shares the
     variable's register (`Live.share`, as a load does), and so does the
     chain of tied operands computing it, when nothing from its
     definition to the store reads the variable's old value: no load of
     the variable, no use of a load sharing its register other than the
     value's tied operand (a call reads all its arguments, and an
     overflow operation all its operands, before writing the result),
     and no terminator on the way. The store is in the value's block, or
     in the arm its block's branch takes when the other arm, between
     them in the layout, ends the function (the failing check of
     `i += 1`). A value whose only use is its block's `br` shares the
     block result's register the same way; nothing reads that register
     before the block ends.
   - An overflow operation at a native width adds or subtracts in its
     value field's register.
   - Hints (`Live.hint`): an `.auto` argument prefers the register it
     arrives in, which the values allocated before it avoid while they
     can; a value whose tied user crosses a clobber point prefers a
     callee-saved register, which the user then takes over. On x86_64
     the value a `ret` returns in one register, when it is the block's
     last value, is computed in rax; so is a block result that the `ret`
     of an otherwise empty block returns, and a value only a `br` to such
     a block reads, computed last.
   - Call arguments (`exemptArgs`): a value whose interval ends at an
     `.auto` call that passes it in a register, with no stack arguments,
     does not cross that call, and prefers the register that passes it;
     the call orders the argument moves so that no register is written
     before every argument left to load has read it, breaking cycles
     with `xchg` (`loadArgRegs`).
   - Splitting at clobber points (`planSplits`, `genSplit`): when more
     values cross clobber points than callee-saved registers hold them,
     a value may take a caller-saved register instead of memory for its
     whole life if its clobber points, two moves each, cost less than its
     uses read from memory, both weighted by 8 per enclosing loop (a cold
     block's clobber points weigh nothing). Each
     clobber point it crosses stores it to its slot first, reads it from
     there (as do loads sharing its register), and reloads it after,
     unless the clobbering value's result is computed in its register
     (`Live.share`). Not across clobbering terminators, and not for
     bases of folded addresses.
   - The value field of an addition or subtraction with overflow that
     writes its fields is tied to the left operand.
   - Lowering: narrowing to 8, 16, or 32 bits is one `movzx`/`movsx`
     (from the operand's register for a cast) instead of a shift pair; a
     cast that cannot change the bits is a move, and of a constant the
     narrowed constant; `x + 0`, `x - 0`, `x * 1`, `x / 1`, `x | 0`,
     `x ^ 0`, and shifts by 0 are `x` (slicing from 0, `sliceAsBytes`);
     a remainder by a constant goes to rax directly.
   Against main 23e407f (`bench/runtime.py`, 9 runs): sieve 160 → 154
   ms, hash 229 → 223, fmt 103 → 100, sort and nbody within noise; fib
   137 → 152 with fewer instructions in `fib`, which starts 48 bytes
   into a 64-byte line instead of at one (the placement noise above).
   fmt's binary: 284,537 → 273,549 instructions, register-to-register
   moves 41,306 → 33,511. The zig workload: 3.92 → 3.83 code bytes per
   IR instruction, allocation 114–117 → 128–135 ns per IR instruction,
   emission and wall time within noise (10.33/10.33 → 10.35/10.24 s).
   std's tests: 4.62 → 4.49 code bytes per IR instruction, allocation
   106 → 113–116, wall time within noise, binary 60.7 → 59.9 MB.
5. aarch64 lowering, ABI, and encoder relaxation on the same layer (Mac
   thread). Lowering, ABIs, inline assembly, liveness, `Ssa.plan` and
   register allocation over x19-x28 are in (aarch64-macos conformance
   100% of upstream); float registers (d8-d15) and pairs next.
   bench/realworld.py on an M-series Mac (mac.large, 2026-11-05,
   stage-next 9c9c845 with register allocation; upstream Debug is LLVM
   there), as bs / Debug and bs / ReleaseSafe: vaxis 1.11x / 6.11x,
   zig-fmt 0.65x / 6.06x, zig-sema 0.69x / 8.44x, zls-test 0.37x /
   2.70x; corpus uucode-gen 0.55x / 10.2x, vulkan-gen 0.55x / 6.2x,
   zigimg-test 0.49x / 3.8x, json-zig-test 0.46x / 6.1x, msgpack-test
   0.28x / 54x, tls-test 0.82x / 19x, hpke-test 1.30x / 32x, yaml-test
   0.60x / 6.9x, json5-test 0.23x / 51x, ini-test 0.30x / 31x, tar-test
   0.30x / 16x, trie-test 0.31x / 12x, qr-test 0.54x / 3.3x, loc 0.45x
   / 2.1x. Not built by bs: zedis-test (`&.{}` to `[*]Kevent` in zio's
   kqueue backend), the zwasm runs (a C call returning `@Vector(16,
   u8)`). translate-c and jinja-test fail in every mode on a Mac.
6. DWARF variable locations; then leaf inlining with the cache edge.
   *DWARF types and variables: paused by the owner, 2026-11-03.* bs
   keeps line tables, CFI, function names and inlined frames, the
   debuggability the scope asks for; types and variables mostly serve
   interactive debugger sessions, which agents rarely use, and would
   cost compile time. The design, approved before the pause, for
   whoever picks it up:
   - Types: content-addressed type atoms in a `debug_type` section, not
     loaded, built on the CodeGen workers from the InternPool alone
     (like `contentAtom`, owner `.content` plus a content use). The
     linkers place them all in one types CU (gdb handles cross-CU
     references; lldb in a dSYM was not yet checked) and resolve a
     4-byte DIE-reference relocation: `DW_FORM_ref4` inside the types
     unit, `DW_FORM_ref_addr` from subprograms. Base and composite
     types as upstream emits; a pointer to a container references a
     name-only stub, so recursive types need no cycle. No
     `decl_file`/`decl_line` in type DIE bytes (a file index is per-CU
     and a line would go stale in green functions); if wanted, a
     relocation or linker side table. Two types with the same display
     name share a stub; a vendor attribute with the stable hash would
     separate them.
   - Variables: Sema emits `dbg_var_ptr`/`dbg_var_val` markers. CodeGen
     reports, per marker after emission, ranges `{start, end, loc}` in
     final atom pcs, cut per emitted block (cold blocks move), with
     `loc` one of `reg`, `regs[2]` (pieces), `frame` (fbreg, frame base
     rbp), `frame_addr`, `ptr_in` (then deref), or a comptime constant
     (`implicit_value`). Markers do not count as uses for promotion or
     the dead-value sweep; a value used only by markers stays alive
     without extending intervals (gdb shows "optimized out" after its
     last use; upstream's scope-long extent would be a flag). The
     ranges become loclists. `Atom.Debug` gains runs for type keys,
     variables, names and locations; variable decl lines are relative
     to `base_line` (or the enclosing inline's base line) so
     `refreshDebug` moves them, columns absolute, `exact_hash`
     unchanged; ZAPPACK and ZAPSTP bump.
   - Before landing: measure CodeGen ns per IR instruction, debug emit,
     the number of type atoms (manifest nodes) and the change in
     `record` time and manifest size on the zig workload; if type atoms
     run to tens of thousands, share one node per owning unit.

### Linkers (`src/link/`)

- Take the set of Atoms, lay out sections, resolve relocations, and write the
  output file once. No incremental patching of output files; a full relink is
  a memcpy-dominated pass over cached Atoms.
- x86_64-linux: static ELF first. aarch64-linux: static ELF, from the
  same linker (`Options.arch = .aarch64`): EM_AARCH64; segments aligned to
  64 KiB, the largest page an aarch64 Linux kernel may use, as lld's
  aarch64 output; zero padding in .text; TLS variant 1 (the thread pointer
  is 16 bytes, rounded up to the TLS alignment, below the TLS segment);
  the aarch64 instruction relocations patched with the Mach-O linker's
  helpers (`src/link/aarch64.zig`), GOT loads relaxed to the symbol, since
  every target is defined; and an aarch64 CIE (return address x30, CFA
  sp) with FDEs for the frame record (`stp x29, x30, [sp, #-16]!; mov
  x29, sp`) or the outermost frame. The aarch64 code saves no other
  registers and records no epilogue yet, so the FDEs describe neither.
  aarch64-macos: Mach-O against libSystem,
  ad-hoc code signature. The Mach-O linker (`src/link/MachO.zig`) has the
  same phases as the ELF linker and shares its thread pool, symbol table,
  and output buffers. Atom names are platform-neutral; the Mach-O linker
  adds Darwin's leading underscore to the names it writes in the symbol
  table and chained fixups, and not to DW_AT_linkage_name, as LLVM does.
- The ELF linker (`src/link/Elf.zig`) writes every byte of the output once:
  into one buffer (for `emit`, memory; for `link`, a shared mapping of the
  output file), or for `link`, with pwrite: each copy task builds its
  file-contiguous parts (its chunk's run of each section with the padding
  before it, its symbols, their names; a debug chunk's .debug_info,
  .debug_line, FDE, and search-table runs) in a buffer of its thread's and
  writes each with one pwrite. The old output is
  overwritten in place when it is a regular executable with one link, not
  running (Linux refuses to open a running executable for writing), and at
  least 7/8 in the page cache (mincore), resizing with ftruncate but never
  through 0 (ext4 flushes a file truncated to 0 and rewritten on close);
  otherwise it is replaced by a new file, so a running old binary keeps its
  inode. Reuse skips allocating and zeroing every page cache page again:
  on the orb, writing 38 MiB into a new file takes 31 ms, in place 11–15
  ms, into fresh anonymous memory 10 ms. Mach-O keeps replacing, since
  macOS kills signed binaries modified in place. `link` writes with
  pwrite (see the numbers below); the mapping stays as an option, and
  Mach-O writes through one. Segments: R (headers,
  .rodata, and with debug info .eh_frame and .eh_frame_hdr), RX (.text),
  RW (.tdata, .tbss, .data, .bss). Thread-locals start RW, covered by
  PT_TLS (filesz the .tdata bytes, memsz through .tbss, align the larger
  section alignment), which std.os.linux.tls.initStatic copies each
  thread's block from. .tbss takes no room in the image or the file:
  the sections after it overlap its addresses, as with lld (2026-11-05;
  until then it took room, zeros in the file, which cost every program
  std's 256 KiB signal stack). Only TLS offsets use those addresses, so
  the TLS relocations' check that their target lies in the TLS segment
  no longer catches a non-thread-local target that lands among .tbss's
  addresses. TPOFF32
  resolves to S + A - (TLS start + memsz rounded up to the alignment),
  x86_64 variant 2, and TLS symbols' values are segment offsets. A
  hand-built program with .tdata and .tbss variables of mixed alignments,
  doing initStatic's setup itself, reads and writes them correctly; ld
  -static on the same variables produces the same PT_TLS, symbol values,
  and TP offsets. The section headers stay in address order, and outputs
  without thread-locals are byte-identical to before.
- Phases, each split into tasks over a thread pool: insert every key into a
  symbol table partitioned by the key's top bits (one thread per partition,
  first occurrence in input order wins); lay out chunks of 2048 atoms
  relative to the chunk; place chunks per section serially; replace atom
  indices in the table with addresses; fault in the output once; then per
  chunk copy bytes, resolve the atom's targets, apply its relocations, and
  write its symbol-table entries. The output is byte-identical for any
  thread count, and errors report the lowest failing atom.
- Measured link throughput (2026-11-02, orb with 4 CPUs, `zig build
  bench-link`, best of 15): 100k synthetic atoms (22 MiB of bytes, 650k
  relocations). Floors copy the same bytes into a fresh buffer.

  | | before (32-byte relocs, serial) | after |
  |---|---|---|
  | emit, 1 thread, random targets | 46–48 ms (3.9–4.3x floor) | 37 ms (3.4x) |
  | emit, 4 threads, random targets | 46 ms | 14.6 ms (1.35x the 1-thread floor, 3.3x the 4-thread floor) |
  | emit, 4 threads, mixed targets | 46–51 ms | 14.7 ms |
  | link to a file, 4 threads | 111–119 ms | 28–33 ms |

  "Mixed" sends half the references to 512 hot symbols, a fifth to nearby
  constants, and the rest to random atoms; it is an assumption, not a
  measured distribution. What remains in single-thread emit, beyond the
  roughly 11 ms of copying and first-touch faults the floor also pays: about
  9 ms of symbol-table probes (cache misses on random keys), about 6 ms of
  stalls loading each atom's scattered targets, relocations, and name, about
  4 ms applying relocations, about 5 ms of symbol-table output, and about
  5 ms of dedup, layout, and address resolution.
- Numbered symbols (`Options.symbols`): the caller, the cache's manifest,
  numbers every symbol densely and passes per atom its number and the
  start of its targets' numbers in one u32 array (`NumberedAtom`, 8 bytes,
  extern so a mapped manifest can be passed as is). The link then hashes
  nothing: no key gathering, dedup, or probes; a chunked pass writes each
  atom's address into a table indexed by number (u32 offsets from the base,
  so 4 bytes per symbol: relocations index it at random), and the copy
  pass reads targets from it. The atoms must have distinct keys; the output
  is the same bytes as the key-based link of the same atoms, which
  bench-link and the Mach-O unit test check. It need not match the
  key-based link of a list that still has duplicates: layout works in
  chunks of 2048 input atoms, each aligned to its largest alignment, so
  dropping duplicates moves chunk boundaries and can change padding.
  Values (error codes) are numbers too. Mach-O (`MachO.Symbols`) numbers
  its imports as well; the address table marks values and imports apart
  from addresses, atoms take precedence over imports and imports over
  values, as with keys. On the orb (Mach-O emitted, not run), 4 threads:
  keys 25–26 ms, numbered scattered 21.7 ms, packed 19.1 ms; the rest is
  Mach-O's serial fixup chains and code-signature hashing.
  Runs of target numbers can sit anywhere in the array, so a cache can
  append the runs of an edit's new atoms and keep the rest. Measured
  (2026-11-03, same session, best of 15; "packed" lays each atom's
  targets, relocations, bytes, name, and line program out back to back in
  link order, as a compacted pack does; "scattered" is the generator's
  memory, atoms shuffled):

  | random targets | 1 thread, debug / stripped | 4 threads, debug / stripped | link to a file |
  |---|---|---|---|
  | memcpy floor | 8.6–8.8 | 3.1–5.0 | |
  | keys (current path) | 42.9–44.8 / 34.1–35.5 | 15.3–20.0 / 12.5–15.7 | 24.3–26.9 (40.5–42.1 before reuse) |
  | numbered, scattered | 33.3–33.7 / 23.5–23.7 | 13.3–13.4 / 9.1–9.4 | 18.5–20.3 |
  | numbered, packed | 22.2–23.2 / 15.2–15.3 | 9.8–10.0 / 6.3 | 14.3–15.4 |

  Mixed targets give the same within noise. In a single-thread stripped
  numbered packed emit, what remains is about 30% kernel time zeroing and
  mapping fresh output pages (the floor pays it too), 23% copying atom
  bytes, 31% the copy loop (relocations, reading the address table, symbol
  table and string table output, prefetching), 6% layout, and 5% address
  resolution and setup. Linking to a file adds page cache work per page
  (page_mkwrite, dirtying, and tearing down the mapping). Against the
  key-based path, the numbered code costs that path 0.5% more instructions
  under callgrind (312.1M → 313.7M for three stripped emits), from code
  layout; wall-clock time does not show it.
- Input without `Atom` structs (`Elf.linkInput`/`emitInput`): the linker
  reads atoms through a comptime-duck-typed input with `AtomSlice`'s
  declarations (`len`, `check(i)`, `atom(i)`, `debugLen`, `debugAtom(j)`,
  `debug(j)`, `prefetch`, `prefetchDebug`), so a cache can hand it its
  mapped pack records without decoding them into Atoms. `atom` and `debug`
  may return a value, built from a record header with arithmetic, or a
  pointer; the linker takes the address either way, so the slice input
  (what `link`/`emit` wrap) copies nothing. `check(i)` validates atom
  `i`'s record, and its debug record, wholly (bounds, section, alignment,
  frame kind, header lengths), in the first pass that reads it
  (gatherKeys for keys, layout for numbers); a false result fails the link
  with `error.InvalidInput`, reporting the lowest such atom in
  `Diagnostic.index`. The linker itself checks that `debugAtom(j)`
  ascends and is in range before calling `debug(j)`. A relink from the
  cache checks each record once: after a link checked every record of a
  base manifest (its id and pack id, recorded in the compilation's
  `checked` file), later links of that base check only the bounds of the
  base's records (`Pack.LinkAtoms.trusted`) and wholly check the log's
  (`Manifest.LinkInput.fresh`). Packs are append-only and base packs are
  never rewritten, so a record once well-formed stays so; a new base
  (fold, compaction, full build) is checked whole again. On zls this
  saves about 1.1 ms of each edit build's 17 ms relink.
  `Symbols.targets_tail` continues `targets` (index k ≥ targets.len reads
  `targets_tail[k - targets.len]`; no run may straddle), so a manifest's
  base runs and its log's runs are passed without joining them. Cost to
  the slice path (2026-11-03, callgrind, three single-thread key-path
  emits): stripped 319.3M → 320.8M instructions (+0.49%), debug 424.1M →
  426.8M (+0.62%), from code layout in layout and the debug-copy loop;
  wall clock is within noise (interleaved best of 40, 1 / 4 threads:
  stripped 35.8 / 12.4 → 36.5 / 12.4 ms, debug 45.8 / 15.9 → 47.0 / 16.0
  ms). The cache's prototype measured a numbered 100k-atom relink at 8.1
  ms instead of 10.3 with decoding.
- Writing the file through the mapping or with pwrite (2026-11-03, same
  session, best of 15, ms; `Options.file_writes` forces either). Through
  the mapping, each page costs a fault and page_mkwrite, a new file's
  pages are zeroed first, and munmap tears the mapping down. pwrite skips
  the faults and the zeroing (whole pages are written) but copies every
  byte once more, from the thread's buffer, and ext4 holds the inode lock
  for each write, so threads' writes do not overlap (on 4 threads, perf
  shows a fifth of the CPU spinning on it). Both mark every page dirty,
  which neither avoids.

  | map / pwrite, random targets | in place, 1 thread | in place, 4 threads | new file, 1 thread | 2 threads | 4 threads |
  |---|---|---|---|---|---|
  | keys, debug | 54.7 / 52.5 | 26.6 / 26.2 | 71.3 / 62.3 | 54.7 / 43.4 | 38.2 / 38.2 |
  | numbered, scattered, debug | 43.7 / 42.2 | 21.8 / 22.6 | 62.4 / 49.9 | 45.3 / 38.3 | 34.8 / 34.4 |
  | numbered, packed, debug | 32.2 / 31.6 | 18.2 / 19.6 | 47.9 / 39.4 | | 27.8 / 29.3 |

  (The 2-thread column is a separate run with the process limited to 2
  CPUs.) Mixed targets give the same picture. So in place, the common
  case of an edit-rebuild, the two tie on 1 thread and the mapping wins
  on 4; into a new file (first build, a running or uncached old output),
  pwrite wins by 15–20% on 1 and 2 threads and they tie on 4, where the
  inode lock caps pwrite as threads grow. Later sessions (2026-11-03)
  disagree on 4 threads. On one orb, three runs of bench-link: in place,
  numbered packed, the mapping wins by 0.7–2.6 ms (14.3–17.1 against
  16.1–18.0 ms) and the key and scattered paths tie; into a new file the
  two are within 1 ms. On another, right after a full test run: into a
  new file, map 31.0 against pwrite 20.1 ms; in place, map 14.9 against
  pwrite 12.3.
  With the writeback slowdown of the mapping seen earlier (3–4x, not
  reproduced on demand), the mapping's worst case outweighs its best, so
  `auto` is pwrite everywhere. A
  small program links on 1 thread (fewer than 2048 atoms is one chunk).
- Relinking in place (2026-11-04). An edit build's relink lays out what
  the last one did with one function changed, so most of the output's
  pages come out as they were. When the old output is reused, each
  pwrite reads its range back with pread, compares it page by page, and
  writes only the runs that differ (`Link.writeChanged`): the pages left
  alone are not dirtied, and the threads no longer queue on the inode
  lock for them. pread rather than a mapping of the old file, whose
  faults and teardown cost 2 ms on zls. The copy phase starts the debug
  chunks, which take longer each, before the atom chunks; the copy
  threads' scratch is 2 MiB-aligned and advised for huge pages; and a
  debug chunk records the file-table index of each entry's local files
  when `layOutChunk` inserts them (`Chunk.locals`), so writing it
  hashes no paths. Bytes and layout are unchanged: relinks after
  same-size and size-changing edits that add no atoms equal a fresh
  full build (an edit that adds one appends it, as `verifyNodes`
  notes, before and after this change). zls lazy
  body edit (src/Server.zig:1529), median of 10, same tree with and
  without: link 18.3 → 14.1 ms, of which after gathering the inputs
  14.9 → 11.4 (layout 2.4, address resolution and debug layout 2.1,
  copy 3.7); vaxis (src/Vaxis.zig:407) link 7.0 → 6.1 ms. The copy
  phase's pread costs one more read of the output, which a new file or
  an edit that changes everything pays for nothing; on zls it is a
  fraction of a millisecond across the threads.
- Debug info (`src/link/Dwarf.zig`, shared with the Mach-O linker) is
  DWARF 5: .debug_abbrev; in .debug_info a compile unit per
  `Debug.unit` (the path of the module's root file; as upstream does, the
  unit is named after its basename, which std.debug prints as "in main
  (hello.zig)", with its directory as comp_dir), holding a
  subprogram entry per function with `debug` (name; linkage_name, the
  atom's name, which is upstream's qualified name and what gdb's `break
  widgets.TextInput.update` and backtraces use; low_pc, high_pc,
  decl_file, decl_line) and an inlined_subroutine entry per
  `Debug.inlines` call (name, low_pc, high_pc, call_file, call_line,
  call_column; nested by `parent`); a .debug_line program per unit
  (debuggers and `dwarfdump --verify` expect each unit's own), whose
  directory 0 is the unit's directory and file 0 its root file, with a
  sequence per function of the unit; and each
  unit's address ranges in .debug_rnglists, as DW_RLE_offset_pair entries
  with offsets padded to 5 bytes, one per run of consecutive entries of
  the unit within a chunk. A run also covers code without `Debug`
  between its functions; code before the first or after the last
  function of a run is in no unit. Per-entry sizes depend only on the
  entry (file indices and range offsets are padded LEB128s), so a pass
  over chunks of 2048 `Debug` entries, run in the same parallel step as
  address resolution, sizes them, checks their inline calls and patches,
  and dedups their (unit, file path) pairs and units (both first by
  address: a chunk's entries usually share the same path and unit
  bytes); a serial step merges the paths into each unit's file table,
  whose directories are resolved against `comp_dir`, and places each
  unit's header, line program header, and range list, each followed by
  the chunks' parts of it in chunk order; the debug
  chunks are then written in place as extra tasks of the copy step, each
  entry into its unit's part. A fragment is copied unchanged unless it
  has `Debug.patches`: a `set_file` operand (padded to 3 bytes) becomes
  the unit's file index, and an `advance_line` operand (padded to 5
  bytes) naming a base (the function's or an inline call's) becomes the
  difference from the previous base, so rows of inlined code stay
  relative to the callee's declaration and moving any declaration
  changes only a base line (`LineProgram.switchTo` writes the pair).
  Entries whose atom lost to a duplicate are skipped. gdb (`break
  file.zig:N`, `break fn`, `bt`, which shows inlined frames with their
  call sites) and std.debug's ElfFile/Dwarf read it; std.debug requires a
  .debug_str, so it holds the producer string. Types, variables, and
  rbrace (epilogue) rows come later. Cost under callgrind (three
  single-thread emits of bench-link, one unit, no inline calls): stripped
  links unchanged (+465 instructions), debug links +19.3M (6.4M per emit,
  about 80 per function, against 35M per emit for all debug info);
  with 20 units interleaved entry by entry, the worst case for runs,
  another 10M per emit. Linking hello (std) takes about 3 ms before and
  after; x86_64/binary.zig (117k functions, 285 MB) takes 110–115 ms
  before and after into tmpfs, and is dominated by writeback on disk.
  Debug info's share of real links: hello, 0.93 → 1.10 ms on 1 thread
  (in memory), about 0.94M instructions per link, which resolving each
  line program directory spelling once cut by 75k; binary.zig, 118 →
  135 ms on 1 thread and 38.0 → 42.6 ms on 4, and about 62M of a cached
  relink's 269M instructions (530 per function): about 18M decoding
  each entry from its cache record (once for layout, once for writing),
  7M in compiler_rt memcpy calls for names and fragments, and the rest
  spread over sizing, unit and file lookups, FDEs, and sequence
  wrappers, with no single hot spot.
- Call frame information: std.debug unwinds x86_64-linux stacks with DWARF
  CFI (frame-pointer walking counts as unsafe there and is used only for
  panics), looking first for PT_GNU_EH_FRAME. So each `Debug` entry whose
  atom's `unwind` (`Atom.Unwind`) is `.frame_pointer` or `.outermost`
  gets an FDE: 32 bytes for one that saves at most one register (and
  is under 64 KiB), up to 48 for one that saves all five.
  `.outermost` (std.start's `_start`, `.cfi_undefined rip`) keeps the
  CIE's CFA of rsp+8 and marks rip undefined, which ends std.debug's
  unwind (SelfUnwinder returns 0). `.frame_pointer` describes CodeGen's
  `push rbp; mov rbp, rsp` prologue (CFA rsp+8, then rsp+16 with rbp at
  CFA-16, then rbp+16), then the callee-saved registers it pushes
  (`Unwind.saved`: rbx, r12–r15, in that order), each with a
  `DW_CFA_offset` at CFA − 24 − 8k from the end of its push, so every
  instruction of the prologue unwinds right, and with `Unwind.epilogue`
  (x86_64 CodeGen has one epilogue per function, at the end of its code,
  which other returns jump to, as upstream's backend does) a
  `DW_CFA_def_cfa rsp, 8` row at its `ret`, upstream's epilogue row. At
  the `ret` the saved registers' rules stay: their slots below rsp keep
  the values the pops restored, in the red zone that signal delivery
  skips. Code may follow the `ret` (`Unwind.epilogue` is its distance
  from the end): first frameless stubs (CodeGen's synthetic inline
  frames, 5-byte `call`s with the CFA at rsp+8 and rbp and the saved
  registers holding the physical frame's values), for which the FDE adds
  `DW_CFA_restore` of rbp and each saved register after the `def_cfa`, since
  their slots are no longer just below rsp, and the CIE's unspecified rule
  is the same-value one std and gdb apply; then the out-of-line stack
  probes (`Unwind.probes` bytes), which run in the body's frame, so a
  `DW_CFA_remember_state` before the `def_cfa` and a
  `DW_CFA_restore_state` at the probes' start bring the body's rules
  back. A function with neither keeps its FDE as before (built
  2026-11-04; an FDE with stubs or probes takes up to 64 bytes, the
  others up to 48 as before). All FDEs share one CIE in an
  allocated .eh_frame, with an entry each in .eh_frame_hdr's sorted
  search table; naked functions (`.none`) get none. Both sections are
  sized for every entry, at the largest FDE (48 bytes, or 64 for as many
  entries as layOut counted atoms with code after their `ret`), before the entries are read,
  so they need no pass before section placement; the debug layout pass
  sizes each chunk's FDEs, and the same chunked debug tasks as the rest
  write them; the room FDEs do not use stays zero after each section. Not described:
  the `ret` of a function whose frame exceeds a page, until CodeGen sets
  `probes` (it leaves `epilogue` 0 there for now; gdb's epilogue sniffer
  covers it), functions without `Debug` (runtime
  helpers), and naked functions other than an outermost one.
  Verified with gdb (its dwarf2 unwinder, at
  entry, after the push, in the body, and at the epilogue's `ret`), `readelf
  --debug-dump=frames-interp` (the same rows as upstream's FDEs), and
  std.debug's own unwinder
  (`Dwarf.SelfUnwinder` through PT_GNU_EH_FRAME, both its search-table and
  sorted-FDE lookups) walking a trapped bs process's stack from a ptrace
  harness, and on a synthetic stack in a unit test. Cost on bench-link:
  about 3M more instructions per debug emit (40 bytes per function; 406.4M
  → 415.5M for three single-thread emits), within wall-clock noise; none
  for stripped emits (312.1M). The epilogue row adds about 8.5 ns per
  FDE on one thread (writing 100k FDEs: 0.44 → 1.29 ms, in the link's
  parallel debug chunks); bench-link's functions take that path since
  then. Cost (bench-link with a line row every
  8..40 bytes, 3.4 MiB of fragments, output 27.4 → 35.7 MiB): emit
  +10–11 ms on one thread and +3.5–4.5 ms on four in the session below
  (+6.5–8 and +2.3–3.3 ms on a quieter orb); about 2–5 µs of the 55–90 µs
  link of each run test. Keeping `Debug` out of the 96-byte Atom (it was
  inline, making Atoms 160 bytes) removed the 1.5–2 ms that debug info had
  cost stripped links. Wall-clock differences this small drown in orb
  noise, so the comparison uses instructions counted by callgrind for three
  single-thread emits (random targets) next to interleaved best-of-15
  timings from one session (medians of 4 rounds, ms):

  | | before DWARF (e17b8b7) | `Debug` inline (7d78d66) | `Debug` slice |
  |---|---|---|---|
  | stripped, instructions | 316.0M | 320.7M | 312.6M |
  | with debug, instructions | | 424.0M | 406.4M |
  | stripped, random, 1 / 4 threads | 38.5 / 17.3 | 41.0 / 18.9 | 38.9 / 18.3 |
  | stripped, mixed, 1 / 4 threads | 37.4 / 17.3 | 39.5 / 18.3 | 37.7 / 17.6 |
  | debug, random, 1 / 4 threads | | 49.9 / 22.8 | 50.3 / 22.6 |
  | debug, mixed, 1 / 4 threads | | 48.2 / 21.6 | 47.5 / 21.1 |

  (The e17b8b7 bench predates the debug variant; the new code runs that
  bench at 312.3M instructions and 38.1 / 17.7, 36.8 / 17.7 ms. Part of
  the gain is applying each relocation with one dispatch on its kind
  instead of two, which the aarch64 kinds had made slower.)
- Mach-O output is a PIE: __PAGEZERO, __TEXT (header, __text, __stubs,
  __const), __DATA_CONST (__got, and __const for `.rodata` atoms holding
  absolute addresses), __DATA (__data, __thread_vars, __thread_data,
  __thread_bss, __bss, ld64's order), __LINKEDIT, all on 16 KiB pages.
  LC_MAIN carries `Options.stack_size` (16 MiB unless `-stack` says
  otherwise), as upstream writes it: the kernel gives the main thread
  that stack instead of RLIMIT_STACK's 8 MiB, as PT_GNU_STACK does
  through std's start code on Linux. The entry may be an alias, as in
  ELF: C's `main` inside its object's `__text` atom (`bs.entry`, which
  `Emit.finish` makes when `main` is not at offset 0, as in a
  `-fsanitize-c=trap` or ReleaseSafe object) starts at the target's
  address plus the addend, keyed or numbered (2026-11-05; before, such
  a C-only aarch64-macos link failed with UndefinedSymbol).
  Thread-locals follow ld64: `.tdata` and `.tbss` atoms make up the
  template dyld copies per thread (__thread_data, then the zero-fill
  __thread_bss, its start aligned for both), and each gets a 24-byte
  descriptor in __thread_vars whose thunk is a chained bind to
  libSystem's `__tlv_bootstrap` (an import the linker adds, with no GOT
  slot or stub) and whose offset is the atom's in the template;
  MH_HAS_TLV_DESCRIPTORS is set. A thread-local's symbol is its
  descriptor, so placement gives the atom the descriptor's place and the
  copy pass places its bytes in the template again in the same order.
  Code reaches it with the tlvp kinds (`Encoder.threadLocalAddr`: `adrp
  x0; add x0, x0; ldr x16, [x0]; blr x16`, x0 = the address). Imports (`Options.imports`, all from libSystem) each get a GOT
  slot and a stub; branch26 to an import goes to the stub, the GOT forms
  load the slot, and absolute addresses of imports in data are binds.
  A pointer to an absolute symbol's value is written as is, with no
  fixup, as ld64 writes it (upstream's linker rebases it, so its value
  moves with the slide); layout counted a fixup for it, and the serial
  pass drops that slot before linking the chains.
  Rebases and binds are chained fixups (`DYLD_CHAINED_PTR_64_OFFSET`, as
  ld64 emits for arm64 since macOS 12), linked into per-page chains in one
  serial pass; there are no dyld opcodes. The file ends in an ld64-style
  "linker-signed" ad-hoc signature: one CodeDirectory with a SHA-256 hash
  per 4 KiB page, hashed in parallel; the UUID comes from the same hashes,
  so the file is read once for both. `link` builds and signs the output in
  memory and pwrites it into a new file (never the old inode: the kernel
  caches the signature of a file it has run). Building in a shared mapping
  of the file took twice as long: first-touch faults on file pages cost
  about 5 ms more than anonymous memory, and the mapping then needs
  msync(MS_INVALIDATE) before exec (another 4 ms), or macOS kills every
  run despite a valid signature (golang/go#42684). F_PREALLOCATE and
  parallel pwrite gained nothing; close absorbs it. `MachO.linkInput`/`emitInput` read
  atoms through the same input as ELF's (its debug declarations unused),
  with the same `check`/`InvalidInput` contract, and `MachO.Symbols` has
  `targets_tail`. Cost to the slice path on the orb (callgrind, three
  single-thread emits, excluding the 3594M instructions of software
  SHA-256 that are the same in both): 463.1M → 464.5M (+0.31%), from code
  layout; wall clock within noise.
- Mach-O debug info (`Options.debug`) goes where macOS's tools look. The
  DWARF is ELF's (from the same `Dwarf.zig` passes) in a dSYM bundle,
  `<exe>.dSYM/Contents/Resources/DWARF/<exe>`: an MH_DSYM file with the
  executable's UUID, its segment and section commands without contents
  (as dsymutil and upstream Zig write them), and a __DWARF segment, which
  also holds a .debug_aranges set per unit with its ranges: lldb trusts a dSYM's
  aranges to be complete (dsymutil always writes them) and maps no address
  to a unit without them. lldb shows no Function, inlined frames, or
  breakpoint file:line for DW_LANG_Zig units (it has no Zig type system),
  so dSYM units are DW_LANG_C99, as upstream's macOS Debug default (the
  LLVM backend) writes them; ELF units stay DW_LANG_Zig, as upstream's
  Linux default (the self-hosted backend) writes them, and gdb reads.
  std.debug (MachOFile looks for exactly this path and checks the UUID)
  and lldb read it; neither reads DWARF inside the executable, and a debug
  map of N_OSO stabs would need object files. The dSYM is a new file each
  link, written with pwrite from per-thread buffers: a debugger may have
  the old one mapped. Unwinding uses `__TEXT,__unwind_info`, which
  std.debug's Mach-O unwinder requires (it reads __eh_frame only for
  entries whose compact encoding defers to DWARF), as do libunwind and
  lldb. `.frame_pointer` is UNWIND_ARM64_MODE_FRAME (`stp x29, x30, [sp,
  #-16]!; mov x29, sp`), as LLVM encodes such functions; `.none` and
  `.outermost` get no encoding (dyld calls `main`, so no bs frame is
  outermost). Entries are regular second-level pages, each chunk of
  2048 debug entries filling as many 4 KiB pages (511 entries each) as
  it needs, every one indexed, since objdump and lldb read pages as
  4 KiB as ld64 writes them: an entry where a function starts unless it
  continues the previous encoding, and an encoding-0 entry where a run of
  functions ends, a run continuing while the next function is the next
  kept code in __text (padding takes the encoding before it, as with
  ld64). The entries depend only on where atoms went within their chunks,
  so a pass right after layout counts them exactly before sections are
  placed, and the copy step writes them; a serial step writes the index.
  Without debug info there is no __unwind_info and the output is unchanged.
  Verified on an M4 Max (macOS 26): std.debug's MachOFile symbolizes from
  the dSYM; lldb resolves `breakpoint set --file demo.zig --line 37` and
  `image lookup` to the compile unit and line entry (no Function, as
  above); `dwarfdump --verify` is clean and the UUIDs match; objdump reads
  the unwind info, with clang's encoding for frame-pointer functions; and
  libunwind's `_Unwind_Backtrace` walks the same 4 frames through a
  hand-built main -> a -> b -> c as through the same program built by
  clang, and none without __unwind_info. Cost (bench-link -- macho, same
  session, alternating with main): stripped emit unchanged (22.0–23.3 ms
  on 1 thread); with debug info and the dSYM, +3.2 ms on 1 thread and
  +0.6 ms on 16; linking to a file 6.8–7.1 ms against 5.7–5.9, so writing
  the dSYM costs about 1.1 ms. Under callgrind on the orb, stripped emits
  cost 0.05% more instructions outside SHA-256 (464.5M → 464.8M), from
  code layout. A leaf function that keeps lr in its register and needs no
  frame should get a frameless `Atom.Unwind` kind, encoded
  UNWIND_ARM64_MODE_FRAMELESS (0x02000000 with no stack), as clang does,
  so that unwinders step through a fault in a leaf. It comes with the
  aarch64 CodeGen, which knows which functions those are; until then
  such functions get `.none`.
- Every Mach-O link, with or without debug info, has LC_FUNCTION_STARTS
  in __LINKEDIT after the exports trie (as ld64 places it): ULEB128 deltas
  between the file offsets of successive functions (atoms with code in
  __text), from 0, then a 0 and padding to 8 bytes. ld64 writes it unless
  told not to (`-no_function_starts`), and `strip` keeps it. lldb takes a
  user binary without function starts or __eh_frame for stripped and turns
  off unwinding by emulating instructions, so a fault in a prologue unwinds
  through the caller's frame pointer and skips a frame. The deltas
  between a chunk's functions depend only on where atoms went within the
  chunk, so layout sizes them, a serial step places the chunks', and the
  copy step writes them. The load commands are followed by 32 free bytes
  before __text, as ld64's default -headerpad leaves, so tools such as
  `install_name_tool -add_rpath` can add a command. Cost under callgrind on
  the orb (three single-thread stripped key-path emits of bench-link --
  macho): 464.8M → 477.5M instructions outside SHA-256 (+2.7%, about 50
  per function), and 3593.8M → 3612.6M in SHA-256 for the 0.14 MiB more
  that is signed.
- Measured Mach-O link throughput (2026-11-02, Apple M4 Max, 12+4 cores,
  `zig build bench-link -- macho`, best of 15): the same 100k atoms with
  aarch64 relocations (970k: a constant reference is an adrp/add pair) and
  64 imports; output 26.9 MiB. Emit takes 22.5 ms on one thread (7.3x the
  1-thread floor of 3.1 ms; stripped ELF on the same machine: 11.0 ms) and
  3.1 ms on 16 (ELF: 2.0 ms); linking to a file takes 5.8 ms on 16
  (2026-11-03; 12.4 ms with the shared mapping; ELF, with DWARF:
  13.3 ms). SHA-256 of the 27 MiB output alone takes 8.8 ms on one thread,
  most of the gap to stripped ELF; the rest is the extra relocations.
- Relocatable objects (`bs build-obj`, x86_64-linux and aarch64-linux;
  `src/link/ElfObject.zig`, built 2026-11-03) come from the same Atoms.
  The object is the executable image `Elf.emit` lays out (with no entry,
  and imports resolved to 0), kept at the same file offsets, plus a new
  tail: a RELA section per section with relocations, and the object's
  symbol table. The executable link path is unchanged; an object costs the
  image plus one serial pass over the atoms and debug info. ET_REL, no
  program headers, section addresses 0; .eh_frame_hdr is dropped (the
  final link writes its own), and an empty .note.GNU-stack is added.
  .debug_str is SHF_MERGE|SHF_STRINGS as compilers write it (upstream's
  linker mis-sizes the output's .debug_str otherwise).
  - Symbols: a section symbol per section; a LOCAL symbol per atom, valued
    at its section offset; a GLOBAL symbol per export (`Emit` collects
    `Zcu.exports`; one per name; bs has no export linkage yet, so all are
    strong), which replaces the atom's local symbol when the names match;
    an undefined GLOBAL or WEAK symbol per import. In an object, an
    `extern` that the compilation does not export is imported
    (`Emit.useImport`) instead of resolved against compiler_rt or
    rejected, as upstream leaves it to the final link; compiler_rt helpers
    CodeGen calls are still compiled in, as local symbols. As upstream,
    a root with `pub fn main` gets std.start's `_start` in an object too.
  - Relocations against the target atom's symbol: R_X86_64_64, PC32,
    TPOFF32 (local-exec, so the final link must be an executable), and
    8/16/32/64 for `value*` relocations naming a symbol; targets with a
    link-time value (error codes) stay resolved. Debug info: addresses in
    .debug_info and .debug_line become R_X86_64_64 against .text, the units'
    offsets into .debug_abbrev, .debug_str, .debug_line, and
    .debug_rnglists R_X86_64_32 against those sections, found by walking
    the sections as `Dwarf` wrote them (`Dwarf.relocatableFields`); each
    FDE's pc_begin becomes R_X86_64_PC32 against .text.
  - aarch64-linux (2026-11-05): the same object with EM_AARCH64 and
    R_AARCH64_ABS64 (ABS32 and ABS16 for `value*`), CALL26 or JUMP26 by
    the branch's link bit, ADR_PREL_PG_HI21, ADD_ABS_LO12_NC or the
    LDST{8,16,32,64,128}_ABS_LO12_NC matching the instruction's access
    size, ADR_GOT_PAGE and LD64_GOT_LO12_NC (the image relaxed the `ldr`
    to an `add`, so the object puts the atom's `ldr` back), and
    TLSLE_ADD_TPREL_HI12/LO12_NC; debug info uses ABS64/ABS32 and FDEs
    PREL32. `ElfMerge` merges aarch64 objects too (`.eh_frame` stays
    PROGBITS there). Checked: upstream's aarch64-linux link (LLD) of
    test/obj's object and of its static library runs and prints a
    panic's trace through the object's debug info, under qemu.
  - Without `-fPIC`/`-fPIE`, code is not position-independent (absolute
    addresses in .rodata): link with upstream `zig build-exe` (static,
    non-PIE), `ld`, or `cc -no-pie`; a PIE link works with text
    relocations and warnings. With them, see "Position-independent code
    and shared libraries" below.
  - Checked (2026-11-03): an object exporting functions and data,
    importing a function, and using a thread-local links with upstream
    `zig build-exe` (self-hosted linker and `-fllvm -flld`), `cc -no-pie`,
    and `ld` (with its own `_start`), alongside an upstream-built object,
    and runs correctly; gdb breaks on its functions by qualified name,
    shows inlined frames and source lines, and unwinds through its FDEs;
    a panic in its code prints upstream-style stack traces through both
    objects' frames. `zig build test` checks the upstream link and the
    panic trace (test/obj).
  - Cost (ReleaseFast bs, orb, cache off, a copy of the program whose
    code an export reaches): hello, link stage 6.5–8.3 ms for the object
    against 3.1–4.3 ms for the executable, in a 230 ms build; libvaxis
    text_input, 8.7–10.1 ms against 4.6–6.0 ms, in a 560 ms build.
  - build-obj and build-lib use the on-disk cache as build-exe does
    ("Roots and output kinds" below). An object's exports and imports are
    sorted by name, so that the object is a function of its atoms, as the
    link order is.
- `bs run` builds the executable into `<cache>/bs/o/<hash>/<name>`, the
  hash of the working directory, std's directory, and the command line
  before `--`, so a rerun relinks in place through the cache, then
  replaces itself with the program (execve, as upstream does) with the
  arguments after `--` and `ZIG_EXE` set: exit status and signals are the
  program's own.

### Position-independent code and shared libraries (milestone 8; designed and built 2026-11-03)

Scope: x86_64-linux (aarch64-linux at the end of this section). `build-obj -fPIC`/`-fPIE` and `build-lib -fPIC`
(archives) produce objects that link into PIEs and shared objects with
upstream zig, `cc` and `ld`; `build-lib -dynamic` produces a shared
object that a C program and an upstream-built program load. `build-exe`
stays static and non-PIE whatever `-fPIE` says (decided 2026-11-03,
above), so bs's own executable link sees none of this.

**What is position-dependent today** (surveyed 2026-11-03):
- Code reaches every symbol RIP-relative (`x86_64_pc32`). No code atom
  has an absolute relocation: `Encoder.movAbsSym` is used only by linker
  tests, and inline assembly has no symbol operands.
- An `extern` is read from an 8-byte slot (`Emit.lowerExternSlots`: a
  .rodata atom holding an `x86_64_abs64` to the definition, or in an
  object to an import). The slots are bs's GOT already: code loads a
  slot RIP-relative and calls through it, so no PLT is needed for them.
- Imports are the only symbols another module can preempt. Every
  reference from Zig code to Zig code, exported functions and variables
  included, binds inside the image, as upstream's: an upstream `-dynamic`
  library calls its own `export fn foo` with a direct `call foo` and
  reads its exported variable with `lea exported_data(%rip)`, and
  reaches only `extern` functions through the PLT. bs does the same, so
  exports need no GOT entries and cannot be interposed from inside.
- Data pointers are `x86_64_abs64` in .rodata and .data atoms.
- Thread-locals use local-exec (`x86_64_tpoff32`) only.

So making code position-independent is a matter of thread-locals and of
where data with absolute relocations goes. Everything else is the
linkers'.

**Modes.** As upstream (checked with `--show-builtin`): `-fPIC` on
`build-obj`/`build-lib` sets `position_independent_code`; `-fPIE` on
`build-obj` sets both it and `position_independent_executable`;
`build-lib -dynamic` forces PIC and sets `link_mode = .dynamic`. Below,
*pic* means position-independent code that may end up in a shared
object (`-fPIC`, `-dynamic`), *pie* code that ends up in an executable.

**Thread-locals in code** (CodeGen and Encoder; the only change in code):
- Not pic, or pie: local-exec, as today. An executable's thread-locals
  are in its static TLS block, so `-fPIE` keeps `TPOFF32`, as `gcc
  -fPIE` does for variables the object defines.
- pic: local-dynamic, upstream's sequence for pic code,
  `lea rdi, [rip + x@tlsld]; call __tls_get_addr@plt; lea dst, [rax +
  x@dtpoff]`. It is the canonical form linkers relax to local-exec
  (`mov rax, fs:0`, padded) when the object lands in an executable.
  A thread-local the compilation defines (its own, or an export that an
  `extern threadlocal` names) always uses these two models.
- Thread-local externs (`extern threadlocal var`, `@extern` with
  `.is_thread_local`; IR `extern_tls`, built 2026-11-03). Before, Sema
  rejected the `@extern` form, but lowered `extern threadlocal var` to
  an ordinary extern, so code reached the variable's initial image
  instead of the thread's copy. Now the name resolves to the
  compilation's export, as above, or in an object to an import of type
  STT_TLS, reached by the model the final link needs: local-exec
  (TPOFF32) in a non-pic object, which needs an executable, as upstream's
  do; initial-exec in a pie object (`mov dst, fs:0; add dst, [rip +
  x@gottpoff]`, R_X86_64_GOTTPOFF); general-dynamic in a pic object
  (`data16 lea rdi, [rip + x@tlsgd]; data16 data16 rex.W call
  __tls_get_addr@plt`, R_X86_64_TLSGD, the padded 16 bytes linkers
  relax), a call like local-dynamic's. Weak thread-local externs stay
  `[unsupported]`, and so do imports into bs's shared objects, which
  would need a GOT pair with DTPMOD64/DTPOFF64 against the symbol.
  In an executable with object, archive or C inputs (`Emit.has_inputs`,
  built 2026-11-04), a name no export has binds to an input object's
  definition, as a constant's address of extern data does: the code
  relocates to `externAddrKey(name)` (local-exec), and the unit requests
  the name's slot, which the link binds and aliases (archive pulls,
  replay and relinks as for other externs). A definition that is not a
  thread-local fails the link's TPOFF32 range check. A name a shared
  library defines as a thread-local is imported, and the code reads its
  offset initial-exec from the same slot C objects use (`mov dst, fs:0;
  add dst, [rip + slot]`, `Encoder.leaThreadLocalSlot`).
- The sequence is a call: in pic mode `CodeGen.clobbers` returns true for
  `tls_ptr`, so the allocator keeps nothing in rsi, rdi, r8 or r9 across
  it, as for calls; rax, rcx, rdx, r10 and r11 are scratch already, and no
  value lives in an xmm register across instructions yet (when floats get
  registers, `tls_ptr` counts as a call there too). The stack is 16-byte
  aligned at every instruction of a body (fixed frames), as calls need.
- Rejected: TLS descriptors, which preserve every register but rax:
  upstream's new linker (`Elf2`) rejects `GOTPC32_TLSDESC`, while it
  links TLSLD (without relaxing; std exports `__tls_get_addr` in a
  static executable for such links). A helper that
  saves the caller-saved registers around `__tls_get_addr`: 30 or more
  saves per access, for no gain over treating the access as a call.
- `@extern` with `.relocation = .pcrel` (IR `extern_pcrel`, built
  2026-11-03): `lea dst, [rip + sym]`, with no slot. std.pie reads
  `_DYNAMIC` so (bs reports `zig_backend = .stage2_x86_64`, so std.pie
  takes upstream's self-hosted path, not its inline assembly), in the
  start code of a `-fPIE` object whose root has `main`: a static PIE
  relocates itself, and the slot's own RELATIVE relocation is not yet
  applied when it looks for `_DYNAMIC`, so reading through the slot
  crashed. In an object the symbol, unless exported, is an import marked
  STV_HIDDEN and reached with R_X86_64_PC32 (not PLT32), as GNU as
  writes `.weak _DYNAMIC; .hidden _DYNAMIC; lea _DYNAMIC(%rip)`; a
  shared object resolves `_DYNAMIC` itself; an executable resolves the
  name to an export or compiler_rt, and an undefined weak one is null.
  Inline assembly needs no symbol operands for this, so it has none yet.
- Non-pic code is byte-identical to today's.

**Atoms.** Two relocation kinds, appended so stored numbers stay put:
`x86_64_tlsld` (the variable's module, R_X86_64_TLSLD: PC-relative to
the module's TLS GOT pair, A = -4) and `x86_64_dtpoff32` (S + A minus the
start of the TLS segment, R_X86_64_DTPOFF32). The call names the import
`__tls_get_addr`. Thread-local externs add `x86_64_gottpoff` and
`x86_64_tlsgd`, which only objects take (to imports); an image's link
rejects them, and an object's image pass leaves every thread-local
relocation to an import alone (`Elf.Options.object`), since the object's
RELA records replace those fields. Nothing else changes: whether an atom needs dynamic
relocations follows from its relocations, so neither `Atom.Section` nor
the atom gains a field.

**Data with absolute addresses.** In a pic or pie image, a .rodata atom
with an `x86_64_abs64` goes to
`.data.rel.ro` instead; extern slots are such atoms. A loader must write
those words, and `lld` refuses dynamic relocations in a read-only
segment (`ld` writes DT_TEXTREL, which hardened loaders refuse). Elf's
layout decides it per atom, only for pic and pie images. In a shared
object `.data.rel.ro` is under PT_GNU_RELRO, so it is read-only once
relocated.

**Objects** (`ElfObject`): `x86_64_pc32` to an import becomes
R_X86_64_PLT32 (the call to `__tls_get_addr`; other imports are reached
through slots, or are hidden `extern_pcrel` targets, which stay PC32),
any other `x86_64_pc32` PC32,
`x86_64_abs64` R_X86_64_64 (the final link turns it into RELATIVE or a
symbol relocation), `x86_64_tlsld` TLSLD against the variable's symbol,
`x86_64_dtpoff32` DTPOFF32, `x86_64_gottpoff` GOTTPOFF, `x86_64_tlsgd`
TLSGD. A pic object has no TPOFF32 and no absolute
relocation outside .data, .data.rel.ro and the debug sections. Archives
wrap the same object, as now. A pic object keeps each exported atom's
local symbol next to the export's global one, and its relocations name
the local symbol: a shared object's link refuses PC32 against a global
symbol of default visibility, which could be preempted, and the object's
code binds to its own definitions anyway.

**Exports.** `Zcu.Export` gains linkage and visibility from `@export`'s
options (an `export` declaration is strong and default). Today only the
name is honored. Objects then bind weak exports STB_WEAK and mark hidden
and protected ones; a shared object leaves hidden exports out of
`.dynsym` (0.17's `GlobalLinkage` has only strong and weak). This is a small change to
Sema (written here, reviewed by the Sema thread).

**Shared objects** (`build-lib -dynamic`, built 2026-11-03): `Elf.emit`
with `Options.dynamic` (`ElfDynamic.Options`: exports, imports, soname).
ET_DYN at base 0, written once like the executable;
`src/link/ElfDynamic.zig` builds the dynamic tables, which depend only on
names, before layout, and Elf fills in the exports' values after it.
- Layout. R: ELF header, program headers, .dynsym, .dynstr, .hash,
  .gnu.hash, .rela.dyn, .rodata, .eh_frame, .eh_frame_hdr. RX: .plt,
  .text. RW: .tdata, .tbss (no room), .data.rel.ro, .dynamic,
  .got, the end of PT_GNU_RELRO (page-aligned, so the loader protects all
  of it), .data, .bss. Program headers: PT_PHDR, three PT_LOADs,
  PT_DYNAMIC, PT_TLS, PT_GNU_RELRO, PT_GNU_EH_FRAME, PT_GNU_STACK. The
  dynamic sections' headers come after the other allocated sections',
  so `shndxOf` is unchanged.
- `.dynsym`: the imports, undefined, GLOBAL or WEAK, in input order; then
  the exports with default or protected visibility (the atom's symbol
  type and size), ordered by GNU hash bucket. Both `.gnu.hash` and
  `.hash`, as upstream writes them; glibc reads either (checked by hiding
  DT_GNU_HASH: dlsym still finds every export through DT_HASH).
- Imports: each has a GOT slot (R_X86_64_GLOB_DAT) and an 8-byte PLT stub
  (`jmp [rip + slot]`, nop) that relocations to it resolve to, so an
  `x86_64_pc32` to an import (the call to `__tls_get_addr`) calls the
  stub, and an `x86_64_abs64` to one, recognized by its stub address,
  becomes an R_X86_64_64 against the symbol. Libraries import few
  symbols, so every import gets both rather than only the ones each use
  needs. Binding is eager (DF_BIND_NOW, DF_1_NOW, no DT_JMPREL), as
  upstream's libraries are.
- `.rela.dyn`: one record per `x86_64_abs64` in atom order, RELATIVE or
  R_X86_64_64 as above; then R_X86_64_DTPMOD64 for the module's TLS GOT
  pair (if the image has thread-locals); then the GLOB_DATs. RELATIVE
  records are not first, so there is no DT_RELACOUNT (upstream writes
  none either). An `x86_64_abs64` in .text fails the link: code must not
  need the loader to write it.
- `.dynamic`: DT_SONAME (`lib<name>.so` by default, `lib<name>.so.<major>`
  with `--version`, which also names the file
  `lib<name>.so.<major>.<minor>.<patch>`, as upstream's; `-fsoname=`,
  `-fno-soname`), HASH, GNU_HASH, SYMTAB, SYMENT, STRTAB, STRSZ, RELA,
  RELASZ, RELAENT, FLAGS, FLAGS_1. There is no DT_NEEDED: imports resolve
  against what the loader has already loaded (the host program, its
  libc, and the dynamic linker's `__tls_get_addr`), as for upstream's
  libraries that do not link libc. `_DYNAMIC`, which std.dynamic_library
  reads through a weak hidden extern, is linker-defined
  (`ElfDynamic.dynamic_key`).
- Version scripts (`--version-script`, `link/VersionScript.zig`), as
  lld reads them: named nodes (parents read and ignored, as lld ignores
  them) or one anonymous node; `global:` and `local:` patterns, names or
  shell wildcards (`*`, `?`, `[...]`), a quoted pattern being a name;
  `extern "C"` blocks. `extern "C++"` is refused (it needs demangled
  names). Names with `@` versions (`.symver` in C objects) match as
  plain names, without lld's handling of `name@node`. Each export gets its place as lld's
  `scanVersionScript` gives it (exact names in node order, first wins;
  then other wildcards, later nodes first; then `*`); unmatched exports
  stay global and unversioned. A local one is hidden (out of .dynsym); a
  versioned one gets its node's index in `.gnu.version`, and the named
  nodes become `.gnu.version_d` (DT_VERDEF, DT_VERDEFNUM): the base
  definition (VER_FLG_BASE, the soname, else the file name) at index 1,
  then each node with one Verdaux, as lld writes it; needed versions
  number after them. An exact name nothing exports fails the link with
  `error[version-script]` at the pattern, unless `--undefined-version`.
  Only shared objects apply a script; a bs executable or static library
  exports nothing for one to change, and aarch64-macos refuses it (ld64
  has none). The script is an input of the inputs record, so editing it
  relinks.
- TLS: `x86_64_tlsld` is PC-relative to the GOT pair (DTPMOD64, 0);
  `x86_64_dtpoff32` is the offset in the PT_TLS block.
- Externs resolve to the compilation's exports, then to compiler_rt (a
  shared object links compiler_rt in, as upstream's), and are imported
  otherwise (std's `getauxval`, as upstream's library imports it).
- Written once: layout counts each chunk's absolute relocations, a prefix
  sum gives each chunk its first .rela.dyn record, and each copy task
  writes its records while it resolves its chunk (`Link.copyDynamic`,
  the copy loop instantiated with a comptime flag); the rest of the
  dynamic sections are written serially.
- `.symtab`, debug info and unwind tables are as in the executable.
- Checked (2026-11-03): test/obj/lib.zig as bs's shared object, loaded
  by test/obj/main.zig linked against it by upstream (`-lc -rdynamic`)
  and by a C program with dlopen/dlsym (test/obj/dl.c), both in `zig
  build test`; by hand, a library with thread-locals written from two
  threads, data pointers, exported data, and an import from the host,
  loaded by a C program linked against it, by dlopen, and by
  `std.DynLib`. A panic in the library prints the same partial trace as
  upstream's library (neither finds the library's unwind info).

**Objects, checked** (2026-11-03): a bs `-fPIC` object links into
shared objects with `cc -shared`, `ld -shared` and upstream `zig
build-lib -dynamic`, and into PIEs with `cc -pie` (which relaxes the
local-dynamic sequences to `mov rax, fs:0`) and upstream `zig build-exe
-fPIE`, with and without `-fllvm -flld`; the same `-fPIC` archive with
`cc -shared -Wl,--whole-archive`. Thread-locals, data pointers, exported
data, imports and panic traces work in each. A `-fPIE` object links into
PIEs and is refused by `cc -shared` (TPOFF32), as `gcc -fPIE` objects
are. A `-fPIE` object whose root has `main` (std's start code and
std.pie) links into a static PIE with upstream `zig build-exe -fPIE`,
with its self-hosted linker and with `-fllvm -flld`, and runs. `zig
build test` keeps the upstream PIE (with a panic trace), the upstream
shared object and the static PIE of test/obj/args.zig. Thread-local
externs: test/obj/tls.zig, whose thread-local test/obj/tls_main.zig
defines, linked by upstream as a non-pic object into an executable, as
a pie object into a PIE, and as a pic object into a shared object that
the host loads, each checked from two threads (`zig build test`); by
hand also with `cc -no-pie`, `cc -pie` (pie and pic objects) and `cc
-shared` with a C host's `__thread` variable. test/run/extern_tls.zig
covers an executable's own export.

**Executables do not slow down.** bs's own executable link never sees
the new kinds, since `build-exe` is not pic. The `.data.rel.ro` decision
and the dynamic records run only for pic and pie images. The relocation
loop takes a comptime flag for them, so the static loop compiles as
before. `zig build bench-link` and std's tests (compile time) must not
move. Measured (2026-11-03, 4-core orb, ReleaseFast, against main
b90d615): hello's and std's test binaries are byte-identical; std's test
compile takes 7.22–7.59 s before and 7.08–7.15 s after; bench-link, best
of six runs of 15 each, moves −8% to +8% by measurement (random targets
+4–8%, mixed targets −8% to 0%), which is this orb's run-to-run noise:
the static path gained one branch per chunk and one per atom.

**Cache.** `-fPIC` and `-dynamic` exist only on `build-obj` and
`build-lib`. Those commands use the cache ("Roots and output kinds"),
but pic builds still skip it (main's `openCache`) because `Elf`'s
numbered link has no position-independent layout yet, so no pic atom
reaches the store. When they are cached, pic and non-pic atoms are kept
apart by both keys: the compilation key holds the
arguments, and the donor key gains the options that change code
(`-fPIC`, `-dynamic`, the output kind; the cache thread adds them). The
donor key matters because a first build replays another compilation's
manifest, and a differing builtin.zig turns most units red but not those
that do not read it, whose function atoms would otherwise load from a
non-pic donor. The manifest's output kind gains `shared`. The numbered
link (`Elf.Symbols`, what a relink passes) takes pic and shared images
(2026-11-04): what the key-based link finds by key comes as numbers, the
imports' (parallel to `ElfDynamic.Options.imports`, set to their PLT
stubs after layout), the exports' atoms' (parallel to `.exports`, found
in one pass over the numbered atoms) and `_DYNAMIC`'s; names, flags and
the soname still come as `ElfDynamic.Options`. The output is the same
bytes as the key-based link's (a unit test checks a shared object with
an import call, an import's address in data, `.data.rel.ro`,
local-dynamic TLS and `_DYNAMIC`). The manifest and `linkFrom` side is
the cache thread's, with `build-lib -dynamic` as its first user, then
`-lc` executables. The new
relocation kinds need no format bump: the store seed and the compilation
key include the bs binary's identity, and `atoms.check` rejects unknown
kinds.

**Checks.**
- A bs `-fPIC` object: exported functions and data, a table of data
  pointers, a thread-local written from two threads, an extern the host
  defines, and a panic trace through its frames. It is linked into
  shared objects with `cc -shared`, `ld -shared` and upstream `zig
  build-lib -dynamic`, and into PIEs with `cc -pie` and upstream `zig
  build-exe -fPIE`, then loaded and run. The same `-fPIC` archive is
  linked with `cc -shared -Wl,--whole-archive`.
- A bs shared object, loaded by a C program (`-l` at link time, and
  `dlopen`/`dlsym`) and by an upstream-built Zig program. readelf finds
  no TEXTREL, no relocation kinds other than the four above, and RELRO
  covering `.data.rel.ro`, `.dynamic` and `.got`.
- `zig build test` keeps them (test/pic, next to test/obj).

**Steps.** 1: pic objects and archives (thread-locals, `.data.rel.ro`,
PLT32, export linkage; built 2026-11-03). 2: shared objects (built
2026-11-03). 3: `-fPIE` objects whose root has `main` (inline assembly
symbols; not built yet: such an object fails to compile on std.pie's
`lea _DYNAMIC(%rip)`). Ownership: this thread owns the
encoder, the atom kinds, `Emit`'s output kinds and the linkers. The two
CodeGen edits (`tls_ptr`'s lowering and `clobbers`) are written here and
reviewed by the hello thread, which owns CodeGen; the Sema thread
reviews export linkage; the cache thread is consulted on the relocation
kinds.

**aarch64-linux** (built 2026-11-05): `build-obj -fPIC`/`-fPIE`,
`build-lib -fPIC`, `build-lib -dynamic`, and `-lc` objects and
libraries (PIC, as on x86_64), with C sources, objects, archives and
`-lc++`. Code already reaches every symbol PC-relative (`adrp` with an
add or a load) and externs through slots, so as on x86_64 only
thread-locals change in code (`CodeGen.linuxThreadLocal`):
- Position-independent code calls the variable's TLS descriptor, as
  LLVM's aarch64 code does for every dynamic model (it turns
  local-dynamic into general-dynamic): `adrp x0, desc; ldr x1, [x0,
  :lo12:desc]; add x0, x0, :lo12:desc; blr x1`, then `mrs` and an add.
  The descriptor's function preserves every register but x0 (and lr,
  which every frame saves), so no value is disturbed: values live in
  slots or x19-x28. In a shared object the descriptor is an atom of the
  image (`Emit.contentAtom` with `aarch64_tlsdesc`, R_AARCH64_TLSDESC
  with no symbol and the offset in the block as addend, in
  `.data.rel.ro`), reached with plain page relocations; a pic object
  names the variable with the TLSDESC relocations (`aarch64_tlsdesc_*`,
  objects only), which the final link relaxes or completes.
- Other code keeps local-exec for its own thread-locals; an object
  reaches another module's initial-exec (`aarch64_gottprel_*`,
  R_AARCH64_TLSIE_*), which non-PIC objects could not do before.
- The shared object's layout is x86_64's with the arch's relocation
  types (RELATIVE, ABS64, GLOB_DAT, TLSDESC) and 16-byte PLT stubs
  (`adrp x16; ldr x17; br x17; nop`, `ElfDynamic.pltEntry`); there is
  no module TLS GOT pair, which only x86_64's local-dynamic code uses.
- C inputs (`ElfInput.relocA64`) in a shared object: TLS descriptor
  sequences address the variable's descriptor (`tlsPair` with
  `aarch64_tlsdesc`, or `_sym` for an export an executable may preempt)
  and keep their call; initial-exec and local-exec relocations are
  refused ("recompile with -fPIC"), as x86_64's; absolute addresses,
  calls and GOT loads of exports with default visibility go through the
  loader (`aarch64_abs64_sym`, as `preemptReloc`).
- Checked under qemu (`addAarch64LinuxSharedTests` in build.zig): the
  x86_64 tests' programs, linked by upstream for aarch64-linux-gnu,
  load bs's shared objects (Zig; -lc; C sources, objects and an archive
  with TLS descriptors, preempted by an executable; libc++, versioned)
  and dlopen one; upstream links -fPIC and -lc objects into PIEs and a
  -fPIC object into a shared object; and an extern thread-local works in
  all three models. pic builds skip the cache, as on x86_64.

### Object, archive and shared-library inputs (milestone 9, linker side; designed 2026-11-04, for review)

Scope: x86_64-linux. ELF relocatable objects (`.o`) and archives (`.a`)
become link inputs of bs's executables, objects and shared objects,
alongside Zig's atoms. Shared libraries (`.so`) as inputs come last.
Mach-O inputs get a design of their own later. The C thread's design
("C interop") produces the objects (upstream `zig cc` per C source) and
owns `-lc`, the start file and abilists. This section is what the
linkers do with the objects. Today main.zig rejects `.o`, `.a` and `.so`
arguments as `[unsupported]`.

**Where conversion happens.** A new `src/link/ElfInput.zig` reads an
object, or an archive member, mapped and zero-copy, and turns it into
Atoms. The link stays one pass over atoms: nothing downstream knows an
atom came from C. `Emit.finish` loads the inputs after analysis, resolves
names across Zig and the objects (below), converts, and appends the
atoms before the link. The cache's relink does the same from the input
paths (the cache thread owns that part; see Cache).

**Atoms: one per allocated input section.** Code within a section
calls its static functions with no relocation, so a section cannot be
split, and it is the unit. Upstream's Debug C flags include
`-fno-function-sections -fno-data-sections` (checked with
`--verbose-cc`), so an object's `.text` is one atom holding all of the
translation unit's functions. The atom is named after a global symbol
at its start that covers the whole section, else after the section; an
atom named after its section, or with no name, has no .symtab entry of
its own (2026-11-04: `.text` and `.data` entries overlapped the
functions and objects, and a `.data` named after its first object had
the section's size). Every function and object
symbol of the input still gets its own entry in the output's .symtab,
which debuggers and profilers read: through a side list in
`Elf.Options` (name, atom key, offset, size, type), not through `Atom`,
whose format stays as it is. The key is `fromName("obj:"
++ the file's content hash ++ ":" ++ section index)`: stable across paths
and worktrees, so the store and donors can dedup. Input sections map to
`Atom.Section` by flags:
- SHF_EXECINSTR → text;
- SHF_TLS → tdata, or tbss if NOBITS;
- NOBITS and COMMON symbols → bss (a COMMON symbol is one zero-fill atom
  of its size and alignment; the largest wins, as ld);
- SHF_WRITE → data (`.data.rel.ro*` too: correct, if less hardened);
- other SHF_ALLOC → rodata;
- `.init_array*`, `.fini_array*`, `.preinit_array` → three new
  `Atom.Section` values (appended; built, see below). They are RW
  with `x86_64_abs64` entries, ordered by their priority suffix as ld orders them. The
  linker defines `__init_array_start`/`__init_array_end` and the others
  as section bounds, as for the sancov sections, and dynamic executables
  get DT_INIT_ARRAY/DT_FINI_ARRAY and their sizes from
  `ElfDynamic.writeDynamic`: from glibc 2.34 on, ld.so runs an
  executable's init arrays from .dynamic, and the C thread's start file
  passes null init and fini to `__libc_start_main`, as glibc's own crt1.o
  does.
- Non-allocated sections are dropped (`.comment`, `.note.*`, `.group`,
  `.llvm_addrsig`), except `.eh_frame` and `.debug_*`, which are copied
  (see "Unwind and debug info" below). An
  object without `.note.GNU-stack` does not make bs's stack executable.

**Symbols and resolution.** An object's global symbol is a name for
(section atom, offset). One table maps names to definitions: Zig's
exports, the loaded objects' globals, then archive members pulled on
demand. It lives in Emit, next to `userExport`/`rtExport`, which already
resolve externs by name. Rules, as ld's:
- Two strong definitions of a name are an error that names both inputs.
- A strong definition beats weak ones; among weak ones, the first in
  input order wins.
- An undefined name pulls the archive member whose symbol index defines
  it. Pulling repeats over all archives until nothing changes (lld's
  semantics, so archive order and cycles do not matter).
- `--force_undefined <name>` (the build API's `forceUndefinedSymbol`;
  2026-11-05, for zig-graph-compiler) adds a name to what the link
  wants, in `Emit.pullInputs` and in Incremental's relink, so the member
  defining it loads, as lld's and ld64's `-u` load it. A forced name
  nothing defines is fine on ELF, as with lld, and an `undefined-symbol`
  error on Mach-O, as upstream's Mach-O linker reports it (the Zig
  exports, the objects and the libraries' exports count). On Mach-O
  the name is a symbol name, as ld64's `-u` and upstream take it:
  `_keep_me` for C's `keep_me`, so `keep_me` is undefined there, with
  a hint naming `_keep_me` when that is defined. Upstream's
  own ELF linker ignores the flag (it keeps Zig exports anyway and
  pulls no member for it); bs follows lld, which upstream uses with
  `-fllvm -flld`.
- Then compiler_rt, as upstream links libcompiler_rt after the inputs.
- Then shared libraries (abilists for `-lc`, `.so` inputs in stage C),
  which give imports.
- An undefined weak name is 0. In a C-only executable the loader
  relocates (upstream links it with lld), GOT loads and calls of one
  import it instead, weak and unversioned with no library needed
  (`weakImport`, in `Emit.InputResolver` and Incremental's resolver), so
  a library loaded at run time such as an LD_PRELOAD one defines it;
  its absolute addresses in data stay 0, as lld resolves them
  (test/link_input/weak_main.c; 2026-11-05). Upstream's own linker,
  which links programs with Zig code, imports none. A strong name still
  undefined is the usual "undefined symbol" error, now saying which
  input referenced it.

Zig externs keep their 8-byte slots. A slot's target becomes the object
symbol's (atom key, offset), with the offset in the addend.

**Relocations.** These are the kinds that upstream's C objects carry,
and system `cc`'s (GCC, `-fPIE` by default on Debian). Without `-lc`, upstream
compiles C as non-PIC: extern data comes through R_X86_64_32S and
thread-locals through TPOFF32 (checked). With `-lc` it compiles C as
`-fPIC`, because glibc requires PIC. Targets are atom keys plus addends; a reference to a section
symbol or a local becomes (section atom, value + addend).
- R_X86_64_64 → `x86_64_abs64`. PC32 → `x86_64_pc32`. New appended
  kinds `x86_64_abs32` (32, checked to fit u32) and `x86_64_abs32s` (32S,
  i32) are for non-PIE code in bs's non-PIE executables. PC64 → new
  `x86_64_pc64`.
- PLT32 → `x86_64_pc32` to the definition when there is one. To an
  import, it goes to a *PLT stub atom*: an 8-byte `jmp [rip + slot]`
  (text, content-addressed by the import's slot key) whose pc32 targets
  the import's extern slot. PLT stubs are then ordinary atoms, and the
  executable needs no linker-made PLT (the C thread's no-PLT rule holds
  for Zig code; C calls to imports get stubs).
- GOTPCREL, GOTPCRELX, REX_GOTPCRELX: the GOT entry is the target's
  slot atom, the same kind of 8-byte rodata atom with an `x86_64_abs64`
  that Zig externs use, content-addressed by (target, offset). So C and
  Zig share one GOT entry per symbol, and an import's gets its GLOB_DAT
  as Zig's do. When the target is defined in the image (always, except
  imports) and the form is relaxable, ElfInput relaxes as ld does instead:
  `mov reg, [rip + x@GOTPCREL]` becomes `lea reg, [rip + x]`, and `call`
  or `jmp` through the GOT becomes `addr32 call x` or `jmp x; nop`. The
  relocation is then `x86_64_pc32`.
- TLS. In an executable every thread-local is the image's own, so
  ElfInput relaxes the canonical sequences to local-exec as ld does:
  GD's 16 bytes to `mov rax, fs:0; lea rax, [rax + x@tpoff]`; LD's
  `lea rdi, [rip + x@tlsld]; call __tls_get_addr` to the 12-byte padded
  `mov rax, fs:0`, with each DTPOFF32 becoming `x86_64_tpoff32` on the
  offset; IE's `mov reg, [rip + x@gottpoff]` to `mov reg, imm32`
  (`x86_64_tpoff32`); TPOFF32 as is. TLS descriptors
  (`-mtls-dialect=gnu2`, GCC's default in nixpkgs; built 2026-11-04):
  GOTPC32_TLSDESC's `lea rax, [rip + x@tlsdesc]` becomes `mov rax,
  imm32` (`x86_64_tpoff32`) and TLSDESC_CALL's `call [rax]` the nop
  `xchg ax, ax`, in static and dynamic executables alike;
  `_TLS_MODULE_BASE_` (Clang's local-dynamic base) becomes `mov rax, 0`,
  so its DTPOFF32 offsets become TPOFF32 ones, as after LD. Upstream's
  own linker leaves `_TLS_MODULE_BASE_` undefined; LLD links it. In a
  shared object, GD and LD stay
  (`x86_64_tlsgd`/`x86_64_tlsld`, the GOT pairs made by ElfDynamic). IE
  in a shared object is `[unsupported]` until something needs it.
- GNU indirect functions (STT_GNU_IFUNC, from `__attribute__((ifunc))`
  and `target_clones`; built 2026-11-04), as upstream's: each resolver
  gets an 8-byte slot in .data whose `x86_64_irelative` relocation
  becomes R_X86_64_IRELATIVE (no symbol, addend the resolver's address),
  which the loader applies after the image's other relocations, and an
  8-byte stub `jmp [rip + slot]` in .text, content-addressed
  (`ElfInput.ifuncAtoms`). The function's symbol is the stub
  (`symTarget`): calls, addresses taken by C and by Zig, and a shared
  library's export all use it, so a pointer compares equal whoever took
  it, as upstream's canonical PLT entry. Only images the loader
  relocates take them (`Inputs.dynamic`: an executable linking glibc,
  or a shared library); a static executable has no startup code that
  would call the resolvers (glibc's static `apply_irel` is not linked),
  so there they are an error naming each one.
- Thread-locals imported from shared libraries (built 2026-11-04;
  ElfShared keeps STT_TLS symbols, and the import is STT_TLS in
  .dynsym): initial-exec through a content-addressed 8-byte slot
  (`tlsSlot`) whose `x86_64_tpoff64` relocation becomes R_X86_64_TPOFF64
  against the import, so the loader writes the offset (the slot moves
  to .data.rel.ro, as other loader-written slots). IE's `mov/add reg,
  [rip + x@gottpoff]` reads the slot as is; GD's 16 bytes become `mov
  rax, fs:0; add rax, [rip + slot]`; TLSDESC's lea becomes `mov rax,
  [rip + slot]` and its call the nop, as ld relaxes them in an
  executable. Upstream's own linker keeps GD (DTPMOD64/DTPOFF64) and
  TLSDESC (R_X86_64_TLSDESC) dynamic and turns IE into TPOFF64; its
  self-hosted backend miscompiles a Zig `extern threadlocal` such a
  library defines (LLVM's IE code works). No corpus project needs this
  yet; libstdc++'s `__once_callable` is one such variable.
- GOTPC32/GOTOFF64 (large model), SIZE32/64 and the rest fail with an
  error naming the object, section and kind.
- Copy relocations: code that reads an import's data with PC32 or 32S
  needs them. Upstream's C flags under `-lc` (`-fPIC`) produce none, but
  GCC's `-fPIE`, Debian `cc`'s default, does: it reads `stdout` with
  R_X86_64_PC32 and relies on a copy relocation (checked 2026-11-04; the
  design first said it read through the GOT). bs makes them for glibc's
  data objects (abilists gives their sizes): a zero-fill .bss atom of the
  object's size takes the import's key, so every reference to the import,
  Zig's extern slot included, uses the copy; the import leaves the
  dynamic imports and becomes a versioned, defined .dynsym entry
  (`ElfDynamic.Export.copy`) with an R_X86_64_COPY. abilists does not say
  which names share an address, so `Glibc.dataAliases` lists glibc's
  (`environ`, `_environ`, `__environ` and a few more): the executable
  defines them at the copy too, since glibc's start code sets
  `__environ`. Upstream's link against its abilists stubs (`-target
  x86_64-linux-gnu`) misses those aliases and leaves `environ` null; its
  native link against the system's libc.so.6 gets them, as bs does. A
  function's address taken without the GOT (R_X86_64_32 in non-PIC code)
  would need a canonical PLT entry and is still an error.

**Merged sections.** SHF_MERGE|SHF_STRINGS sections (`.rodata.str1.1`,
which clang always emits) split into one content-addressed atom per
string (`SymbolKey.fromContents`). The linker's existing dedup then
merges equal strings across objects, and with Zig's string constants
when the section and alignment match. Fixed-size SHF_MERGE sections
(`.rodata.cst8`/`cst16`) split per entry the same way. A relocation into
a merged section's middle maps its offset to (the containing entry, the
offset within it) by binary search.

**COMDAT groups.** The first group with a given signature, in input
order, is kept. Later groups' sections are dropped before conversion,
and their symbols resolve to the kept group's by name. No "identical
contents" check is made, as ld makes none.

**Archives.** `Archive.zig` gains a reader: GNU and BSD `ar`, the `/` and
`/SYM64/` symbol index, `//` long names. A member is parsed only when
pulled. Thin archives are `[unsupported]`. `-l<name>` searches `-L`
directories for `lib<name>.a` (and `.so` in stage C).

**Unwind and debug info (stage B; built 2026-11-04).** The inputs'
`.eh_frame` and `.debug_*` sections are not atoms: `ElfInput.convert`
turns each into an `Elf.InputSection` (kind, bytes, relocations), and
Elf copies them after bs's own part of each output section, in input
order, applying their relocations, one parallel task per section. So
C frames get file:line in std's traces and gdb, and std's unwinder steps
through them.
- Relocations (`Elf.InputReloc`): `abs32`/`abs64` against atoms
  (addresses), `offset32`/`offset64` against another input section of
  the same object (its offset in its output section: bs's part, the
  sections of that kind before it, plus the addend), `dtpoff32`/
  `dtpoff64` for thread-locals' DWARF locations, `pc32` in .eh_frame,
  and constants. A reference to what the link dropped (a later COMDAT
  copy) or to an undefined name becomes lld's tombstone: 1 in
  .debug_ranges and .debug_loc, where 0 would end a DWARF 4 list, else
  0.
- `.eh_frame`: CIEs are copied as they are, not merged. An FDE whose
  section was dropped is dropped, and the CIE pointers of the FDEs after
  it shrink by the records dropped in between; without drops the section
  is copied in place. Every FDE's initial location must be a PC32
  relocation at offset 8 (pcrel sdata4, as GCC and Clang write on
  x86_64), from which the linker takes the function's address for
  .eh_frame_hdr. The input records go after bs's FDEs, before the
  terminator, and their search-table entries after bs's; with any,
  the linker gathers the whole table after the copy and sorts it, since
  C functions can lie among bs's.
- `.debug_*`: bs writes .debug_abbrev, .debug_info, .debug_rnglists,
  .debug_line and .debug_str; each input section of those kinds follows
  bs's part, and the kinds only inputs bring (.debug_ranges, .debug_loc,
  .debug_loclists, .debug_str_offsets, .debug_addr, .debug_line_str,
  .debug_aranges, .debug_frame, .debug_names, .debug_macro, the pubnames
  kinds) get headers and names of their own after .debug_str, only when
  present, so outputs without inputs stay byte-identical. Units of any
  DWARF version mix: each input unit keeps its own header, abbreviations
  and string offsets. Strings are not merged. Compressed sections (`-gz`)
  are an error.
- C++ exceptions: a CIE's personality pointer (indirect pcrel through
  the COMDAT `DW.ref.__gxx_personality_v0`) and an FDE's LSDA pointer
  are ordinary `pc32` relocations; `.gcc_except_table` is a rodata atom
  like any allocated section. libunwind finds the FDEs through
  PT_GNU_EH_FRAME as std's unwinder does. Checked by hand with a Zig
  main, a `zig c++` object and upstream's libc++.a, libc++abi.a and
  libunwind.a (`-lc`): a throw through three frames with a cleanup,
  `throw 5`, a static constructor and `thread_local` with a dynamic
  initializer give upstream's result. The C thread keeps the committed
  test with its `-lc++`.
- `__dso_handle`, which C++ passes to `__cxa_atexit`: crtbegin.o defines
  it, which bs does not link, so when nothing else does, the
  resolution (after compiler_rt, before shared libraries) defines it as
  an 8-byte rodata atom, as lld defines it; only its address in the
  image matters. The `-lc` C object test registers an exit handler with
  it.
- Keyed links only, like `local_symbols`; builds with inputs do not
  relink from the manifest.
- Tests: the C object test (test/link_input/ub.c) checks the trace's
  `ub.c:2:34` line and the Zig caller's frame below it; the COMDAT test's
  assembly has FDEs, so the dropped copy's FDE is dropped; an Elf unit
  test places a C function between two of bs's and checks the sorted
  search table and the relocated debug sections.

**Shared libraries as inputs (stage C; built 2026-11-04).** A `.so`
contributes names, with their versions (`.dynsym`, `.gnu.version`,
`.gnu.version_d`) and its DT_SONAME for DT_NEEDED, to the same
resolution step as abilists. They become imports exactly like the C
thread's abilists imports. No bytes come from it.
- `link/ElfShared.zig` reads an ET_DYN: each defined, global or weak,
  default or protected, non-TLS `.dynsym` entry whose version is not
  hidden becomes a name with its version (null for the base version, so
  the import is unversioned, as ld writes zlib's), type, size and value.
  `aliases` finds the objects at one address. The soname falls back to
  the name main.zig gives (below). A linker script (`libc.so`-style text) is an error.
  main.zig and `loadShared` map the library unpopulated, never read it
  whole, so the parse faults in only the headers, `.dynsym`, `.dynstr`,
  the version sections and `.dynamic`: 4.4 MB of LLVM 15's 117 MB
  (2026-11-05; reading it whole cost 60–90 ms of a 0.3 s build).
- Resolution order: Zig exports, then objects, then compiler_rt, then
  the shared libraries in input order, then glibc (`Emit.libraryDefines`
  answers for the last two; `exportTarget`, `InputResolver.importSym`
  and the PC-relative import error use it). Archive members are pulled
  before that, except that the C++ runtime's archives (libc++,
  libc++abi, libunwind, libc_nonshared.a: `ElfInput.addArchive`'s
  `runtime`) supply no name a given `.so` defines, since upstream's lld
  sees them after every input (2026-11-04: an executable took libc++'s
  operator new and exported it over fmt's libfmt.so's). User archives
  still pull before any `.so`, whatever their order on the command
  line; lld's order would let an earlier `.so` win there too.
- `Glibc.dynamicOptions` puts the given `.so` files that are alive in
  DT_NEEDED, in input order, as upstream's linker keeps them. In a
  program with Zig code, which upstream links with its own linker,
  libm.so.6, libc.so.6 and ld-linux-x86-64.so.2 always come first, so
  the loader finds glibc's definitions before the given libraries'
  (`zig build-exe -lc` lists them so even for hello world); in a program
  of C only (`Emit.lld`), which upstream links with lld, glibc's
  libraries come after, as needed (2026-11-04: bs listed glibc's last
  and only libc, so a library defining `getpid` won over glibc in a Zig
  program). A library without DT_SONAME is needed by its file name if
  `-l` found it, else by its path as given, as both linkers name it
  (bs wrote the `-L` path, `./libx.so`, which only resolves from the
  build's directory). Liveness is upstream's (`Object.markLive`, `SharedObject.markLive`; fixed
  2026-11-04, when bs listed every one): a library is alive when a
  strong reference resolves to it, from the compilation's imports and
  copies or from a live library's undefined symbols (`ElfShared.undefs`),
  transitively. Glibc's libraries are needed the same way: a live
  library's strong `__tls_get_addr` needs ld-linux-x86-64.so.2 (fixed
  2026-11-04, from fmt's shared build). Weak references from C keep no library alive, and a weak
  import of a library that is not alive is unversioned; a Zig `@extern`
  with weak linkage is imported strong in an executable, as upstream's
  linker binds it, and keeps its library. A library's reference to a
  name the compilation defines binds to the compilation's definition and
  keeps no other library alive; the executable exports each of its
  definitions, Zig's and its objects', that a needed library names
  (references or defines), unless hidden, as upstream's
  `SharedObject.markImportExports`, so the loader binds the library to
  it (fixed with the liveness: bs exported none, and a library
  calling back into the program failed at run time). glibc's libraries,
  which bs knows only from abilists, name nothing here. `-rdynamic`
  exports every definition, Zig's and its objects' (crt1.o's `_start`
  and `_IO_stdin_used` among them), unless hidden, as upstream's: the C
  modules a Lua interpreter loads bind to it (siv's `lua`). Upstream
  also exports ubsan_rt's weak handlers and crt1.o's `data_start`, which
  bs keeps local or leaves out.
  `-needed-l`, which would keep a library regardless, is `[unsupported]`. Upstream's native link lists libm, libc
  and ld-linux first; its `-target x86_64-linux-gnu` link lists them
  last, as bs does.
- Copy relocations: a non-PIC or PIE C object reading `.so` data gets a
  copy like glibc's `stdout`, sized from the `.so`'s symbol; the
  library's other names at that address (its aliases) are defined at
  the copy too, so the library's own references bind to it.
- `.so` inputs need `-lc` (`[unsupported]` otherwise): only the glibc
  path writes a dynamic executable. Thread-locals from a `.so` are not
  imported yet; such a name stays undefined.
- Search: positional `.so` and `.so.N` paths are inputs. For `-l` names
  on the native target without `--sysroot`, the directories of
  `std.zig.system.NativePaths` follow the `-L` ones, as upstream's
  `want_native_include_dirs`. `-L` directories that do not exist are
  dropped (upstream warns). A name found nowhere is a fatal error, as
  upstream's. An object or static library still finds its `-l` names but
  links none of them (raylib's `build-lib -lGL -lX11 ... -static`). As
  in upstream's `Config.resolve` (`any_dyn_libs`), a library that links
  a shared library without `-static` is a shared library, which is
  `[unsupported]` with `-l` for now.
- DT_RUNPATH: the `-rpath` arguments, then, on the native target, the
  `-L` directories, deduplicated and joined with `:` (upstream's rule).
  No RUNPATH without either, so other `-lc` outputs stay byte-identical.
  The cache writes the same RUNPATH (`Incremental.runpath`).
- Cached (2026-11-04): `.so` files are link-only manifest inputs after
  the objects (`Incremental.link_shared`, keyed `:link:<path>`, in the
  compilation key as `--bs-link-input=`). CodeGen depends on them only
  through `exportTarget`, whose `importKey(name)` is the same whichever
  library defines a name, so atoms depend on whether some library
  defines a name, not which. A relink, numbered or keyed with objects,
  maps and parses them again (`loadShared`, an mmap and a .dynsym walk)
  for the import versions, DT_NEEDED and copy sizes; a lazy edit build
  uses main.zig's parse, which every build makes for CodeGen. A changed
  `.so` makes the edit build eager (`linkInputsChanged`), so Emit.finish
  binds the externs again; a loaded unit's import that the new library
  no longer defines is an error ("undefined symbol: X (no shared library
  or glibc defines it)"), and a relink that meets one builds instead.
  test/link_input/cache.sh checks a `-lc -lshared` program without and
  with a `-fPIE` C object: cold, unchanged, a deleted output, a Zig edit
  (lazy), a relink from a lazy build's log, a rebuilt library with the
  same symbols (eager), and a library that drops an imported name.
- Test: `run bs link of a shared library` builds `libshared.so` with
  upstream `zig cc -shared` and a version script, and links a Zig main
  and a `-fPIE` C object against it with `-lc -lshared -L`; it checks
  versioned calls, a copy relocation and its alias.

**Cache** (agreed with the cache thread, 2026-11-04).
- Object files never influence analysis or CodeGen. Their paths are in
  the compilation key but their contents are not, so nothing before the
  link may look at their symbols. For example, whether an extern binds
  to an object or to compiler_rt is decided in the link (Emit.finish and
  the relink), never in CodeGen. Otherwise an edited object would change
  atoms whose keys stay the same. Zig code reaches every extern through
  its slot, whose atom the link writes, so this holds by construction.
- Objects and archives are link-only manifest inputs: hashed by
  content, with the same stat and racy-mtime rule as source files, and
  no node depends on them. A link-only input of 1 MiB or more
  (objects, archives and shared libraries alike) is recorded by a hash
  of its stat instead (inode, size, mtime: `Incremental.hashedByStat`),
  unless it is racy, so a build never reads a large library whole to
  hash it (2026-11-05: LLVM 15's 117 MB cost 89 ms per full record).
  That is as sound as the stat check, which trusts a matching stat
  anyway; a stat-hashed input whose stat changed counts as changed even
  if only touched (`sameContents` tells the two kinds apart by the
  recorded size and racy mtime). A racy one is hashed by content,
  mapped rather than copied (`contentHash`; siv's 76 MB libsiv.so, linked
  just before the programs that use it, costs 26 ms instead of 60). Changing one invalidates nothing, but it
  blocks the skip-the-link fast path and forces a relink (built: see
  below).
- The conversion reruns on every build and relink: it is a scan plus
  slicing, with copies only for relaxed sequences. Its atoms are not
  stored in the pack.
- A relink with inputs links by key, not by the manifest's numbers (as
  built, step 2 below): C objects' local symbols need a keyed link, and
  the manifest's extern slots already name the objects' atoms by key.
  That needs the extern keys to stay a pure function of the name.
- The donor key is unchanged: object arguments do not change Zig code.
- If profiles show the conversion, store the converted atoms keyed by
  the inputs' hashes and the resolution.

**Cost.** Nothing runs without object or library arguments: the reader,
the name table and the conversion are all behind them. A link with
inputs must stay dominated by copying bytes. Measure linking SQLite's
amalgamation (one 9 MB object) and zlib's 15 objects, with a small Zig
main, against upstream's link of the same objects.

**Built so far (stage A, 2026-11-04).** `src/link/ElfInput.zig` and
`Archive.Reader`; `build-exe`, `run` and `test` take `.o` and `.a`
arguments (objects and libraries do not yet). Sections, merged strings
and constants, COMMON, weak undefined names (a link-time value 0),
absolute symbols (a global one, `.set sym, 0x1234`, binds from every
object and from Zig externs, through `lookup`, so `convert` lists the
values of all of them), R_X86_64_64/PC32/PLT32/32/32S (`x86_64_abs32` and
`x86_64_abs32s`, which pic links reject), GOTPCREL with ld's mov, call
and jmp relaxations and a content-addressed slot otherwise, the TLS
relaxations, COMDAT dropping, and lld-style archive pulling. Where it
differs from the design above:
- compiler_rt functions that only the objects call must be generated, so
  `Emit.sync` pulls archive members for the objects' and the Zig
  externs' names as analysis goes, and requests compiler_rt for what
  stays undefined. Object contents therefore do influence analysis.
  The cache's first step (2026-11-04): the objects and archives are
  link-only manifest inputs (`Incremental.link_objects`, keyed
  `:link:<path>`, with their resolved paths in the compilation key as
  `--bs-link-input=`), which no node depends on and replay ignores.
  Their atoms and glibc data copies are owned by `Emit.Owner.input`,
  which `groupByOwner` puts after the link's own atoms and the record
  leaves out. Step 2 (2026-11-04): an edit build whose objects and
  archives did not change is lazy, and a deleted output relinks, both
  from the manifest (`Incremental.linkWithInputs`): the link's own node
  keeps the extern slots, compiler_rt requests (`rt` references) and
  imports the last full build gave the same objects, and exports are
  link symbols for such executables too, so the relink reads the
  objects again, pulls archive members for the live nodes' externs,
  converts them with the manifest's exports, compiler_rt keys and glibc,
  and appends their atoms and copies to the manifest's, in a keyed link
  (C objects' local symbols need one). An edited object or archive,
  with every other input unchanged, relinks the same way
  (`relinkIfUnchanged` with changed link objects, 2026-11-04): the
  extern slots are bound again as `Emit.lowerExternSlots` binds them
  (`reboundSlots`: the compilation's export, the objects' definition at
  its section atom's key and offset, which an object's contents name,
  then a section bound, compiler_rt, an import, or 0 for a weak extern).
  It builds instead when a slot would move to or from anything but an
  object's definition; when the objects ask for other compiler_rt
  functions or imports than the last build's did (`sameObjectRequests`:
  the manifest's imports and live compiler_rt functions that no linked
  Zig atom references or unit requested), since a full build would
  generate more, or drop what the old objects needed and the manifest
  would keep recording; or when a declaration's data names an object's
  atom without a slot (its old key is then undefined). Otherwise an edited
  object, or a Zig edit together with it, makes the edit build eager
  (`linkInputsChanged`), which binds the externs again and generates any
  compiler_rt function the object now needs. A lazy build does not load the objects, so one that writes a
  declaration's data with the address of a symbol they may define
  (`Emit.externDataTarget`) builds again eagerly. A relink pulls members once with every extern, where a build
  pulls as externs arrive; the two agree while every extern reaches the
  first sync, which only a compiler_rt function that references an
  extern could break. test/link_input/cache.sh checks it: cold,
  unchanged, a deleted output, an edited object (eager), an edited
  archive member, a Zig edit (lazy), a relink from a lazy build's log,
  and a `-lc` program with a C object calling glibc and a Zig export,
  and copying glibc data: each byte-identical to a build without the
  cache, with `BS_CACHE_VERIFY` and `BS_CACHE_CHECK`.
- A C GOT slot is content-addressed by its target, not shared with the
  Zig extern slot of the same name.
- With `-lc`, names nothing else defines are glibc's imports
  (`InputResolver.importSym`, after compiler_rt). A C call to one goes
  through a content-addressed stub atom named `<symbol>@plt` in .symtab
  (the name tools give lld's PLT entries, so a disassembly or profile
  shows `call <printf@plt>`), `jmp [rip + slot]`, whose slot
  is the content-addressed 8-byte atom GOT references use, with an
  `x86_64_abs64` that the executable's link turns into R_X86_64_64.
- The C runtimes: with inputs, `<lib>/ubsan_rt.zig` (a module of its
  own, `Frontend.ubsan_rt`, sharing the main std and builtin) and
  compiler_rt's `ssp.zig` become roots for their exports
  (`Zcu.rootFiles`; compiler_rt's other export blocks stay unanalyzed),
  as upstream links ubsan_rt and compiler_rt for C. `zig cc`'s Debug
  objects call `__ubsan_handle_*` and `__stack_chk_fail`, which then
  resolve as Zig exports, before compiler_rt and glibc, as upstream's
  order has them. One difference: upstream builds compiler_rt with the
  trapping panic, so its `__stack_chk_fail` stops on an illegal
  instruction, where bs's, analyzed in the program, panics with
  "stack smashing detected".
- Init and fini arrays: `.preinit_array*`, `.init_array*` and
  `.fini_array*` sections (by type) become atoms of three new
  `Atom.Section` values, ordered by priority (`.init_array.<n>` by `n`,
  then the plain ones, stable, as ld's SORT_BY_INIT_PRIORITY), laid out
  after .data.rel.ro inside RELRO. The linker defines their bounds
  (`Elf.bound_sections`); Emit resolves `__init_array_start` and the
  others to them only with inputs, so std.start's weak references stay
  null and other outputs stay byte-identical. Dynamic executables get
  DT_INIT_ARRAY, DT_FINI_ARRAY, DT_PREINIT_ARRAY and their sizes. As
  upstream, a static executable's std.start runs the init array and
  nothing runs the fini array; with `-lc`, ld.so runs both. `.ctors` and
  `.dtors` are an error.
- .symtab: each input function, object, thread-local and assembly
  label (STT_NOTYPE, without `.L` labels) gets an entry
  (`Elf.Options.local_symbols`: name, atom key, offset, size; type and
  section from the atom's place), except the one that names its atom.
  Entries are local, as upstream's own linker lists them in programs
  with Zig code; in a C-only program (`ElfInput.lld`), which upstream
  links with lld, the globals of default or protected visibility that
  the link keeps are STB_GLOBAL or STB_WEAK as lld lists them
  (`LocalSymbol.bind`), after every local entry (sh_info), and one at
  offset 0 replaces its atom's own symbol (2026-11-05). Keyed links only;
  a numbered link rejects them until the cache relinks inputs.
- .dynsym: an import of a library's function (STT_FUNC or
  STT_GNU_IFUNC there, or not data in glibc's abilists) is STT_FUNC, as
  both of upstream's linkers write it; an import of data (glibc's
  `stderr`) is STT_OBJECT, as lld writes it; others are STT_NOTYPE, or
  STT_TLS (2026-11-05).
- `-l<name>`/`-L<dir>` find `lib<name>.so` or `lib<name>.a` in the `-L`
  directories (and the native ones; see stage C above) by upstream's
  search strategies (`-search_*`, `-static`, `-dynamic`).
- Tests: a constructor test (priorities across two objects, a
  destructor, with and without `-lc`), a COMDAT pair written in
  assembly (in both orders), GCC `-fPIE` code reading `stdout` and
  `environ`, and an archive passed with `-l`/`-L`.
- Timing (2026-11-04, ReleaseFast bs, `BS_CACHE=off`, against
  upstream with a fresh local cache; objects from upstream `zig cc -c`,
  linked with `-lc` and a small Zig main that calls them): SQLite
  3.50.4's amalgamation, one 18 MB object with 148k relocations in
  .text, builds in 0.21 s against upstream's 0.62 to 0.74 s, of which
  emit (loading and converting the object included) is 21 ms and the
  link 11 to 12 ms for a 10 MB output. zlib 1.3.1's 15 objects build in
  0.18 s against 0.44 to 0.47 s, with emit 5 to 6 ms and the link 5 ms.
  Hashing each object with std's XxHash3 cost SQLite 40 ms until it
  became Wyhash.

**Stages and checks.**
1. A: objects and archives into bs's static and `-lc` executables (the
   latter once the C thread's step 1 lands): sections, symbols,
   relocations with GOT and PLT atoms and the relaxations, merged
   strings, COMDAT, COMMON, init/fini arrays. Tests, each run and
   compared with upstream's link of the same inputs: C objects from
   upstream `zig cc -c` and from system `cc -c`, called from Zig and
   calling Zig; a constructor; equal strings from two objects merged; an
   archive whose members pull each other in a cycle; `-fPIC` C
   thread-locals (GD, LD and IE relaxed); a COMDAT pair written in
   assembly; a Zig panic in a callback the C code calls.
2. B: `.eh_frame` and DWARF pass-through. Checks: gdb's `bt` and line
   numbers through C frames, and std's stack trace through them. Built
   2026-11-04.
3. C: `.so` inputs (`-l<name>` against a library upstream built), and
   copy relocations if an input needs them. Built 2026-11-04.

**aarch64-linux** (built 2026-11-05): objects, archives and C sources
link into static executables without libc (`ElfInput.arch`; C sources
compile for `aarch64-linux-none` and the generic CPU, as translate-c
translates for them). `relocA64` maps R_AARCH64_ABS64, ABS32, PREL32,
CALL26/JUMP26, ADR_PREL_PG_HI21, the ADD and LDST ABS_LO12_NC forms, the
TLSLE adds and movs, and ADR_GOT_PAGE/LD64_GOT_LO12_NC, which keep their
GOT kinds for the linker to relax to the target's address, as the Zig
code's. -fPIC code reaches thread-locals through TLS descriptors and
initial-exec GOT loads, which a static executable relaxes to local-exec
as lld does: the descriptor's `adrp` and `ldr` become nops, its `add`
and `blr` `movz x0, #g1, lsl #16; movk x0, #g0_nc`
(`aarch64_tprel_g1`/`g0_nc`), and the initial-exec `adrp` and `ldr` the
same pair into their register. `.eh_frame`'s FDEs are PREL32, and the
debug sections' ABS32/ABS64 map onto the input-section kinds. Objects
with other relocations are reported by name. Checked by
`addLinkInputTests` under qemu: upstream `zig cc` objects, non-PIC and
-fPIC, and the same files as sources print what the x86_64 link prints.

**aarch64-linux-gnu** (built 2026-11-05): `-lc` with `-target
aarch64-linux-gnu[.version]` links executables and tests against glibc
as x86_64-linux-gnu's: abilists' aarch64-linux-gnu symbols (`Glibc.arch`;
the oldest version is 2.17), the loader `/lib/ld-linux-aarch64.so.1` as
interpreter and DT_NEEDED soname, bs's start code
(`Builtin.glibc_start_aarch64`, sysdeps/aarch64/start.S: the
destructors' function arrives in x0), and libc_nonshared.a built with
glibc's aarch64 include directories. The Zig code's extern slots to
imports become R_AARCH64_ABS64 against the symbol, and copies
R_AARCH64_COPY. C objects' references to imports (`importA64`): ABS64
stays one; CALL26/JUMP26 go through a stub `adrp x16; ldr x16; br x16`
of the import's slot; GOT loads read the slot (page21 and pageoff12
relocations of the `adrp` and `ldr`); PC-relative data references use
the executable's copy. Shared library inputs (`-l<name>`, `.so`) are
read for EM_AARCH64 (`ElfShared.parse`'s `arch`). A shared library's
thread-local is reached initial-exec through one slot the loader writes
(`aarch64_tprel64`, R_AARCH64_TLS_TPREL64): the Zig code loads it and
adds `tpidr_el0`; C's TLS descriptors become `adrp x0, slot; ldr x0,
[x0, :lo12:slot]; nop; nop` as lld relaxes them (`tlsImportA64`), and
initial-exec GOT loads read the slot as is. GNU indirect functions get
an `aarch64_irelative` slot (R_AARCH64_IRELATIVE) and an x16 stub, and
a C-only executable imports weak names nothing defines for its GOT
loads and calls, as x86_64's. `-lc++` builds libc++, libc++abi and
libunwind for aarch64-linux-gnu as x86_64's; Clang's `.eh_frame` and
`.gcc_except_table` there use R_AARCH64_PREL64 (`pc64`,
`aarch64_prel64`). Not yet: objects and libraries with `-lc`, and bs's
own shared libraries. Checked under
qemu with the aarch64 glibc as sysroot (`qemu-aarch64 -L
/usr/aarch64-linux-gnu`, libc6-arm64-cross from .agents/setup): libc.zig
and libc_edit.zig in test/run, the -fPIC C object and source of
link_input/libc.c, a C-only executable, a shared library that Zig calls
and a non-PIC object copies data from, a shared library's thread-local
from Zig, descriptor and initial-exec code, GNU indirect functions, weak
references a preloaded library defines, a -lc++ build with exceptions,
and std's tests with `--libc`.

### Comptime pointers to extern data (built 2026-11-04)

translate-c turns `extern const char x[];` into a container-level
`pub const x: [*c]const u8 = @extern([*c]const u8, .{ .name = "x" });`
(wuffs has 97, which ghostty compares against at run time). Upstream
makes the address a comptime-known pointer to an extern Nav. bs's
value model:
- InternPool `extern_var { name, ty, site }`, which appears only as a
  pointer's `uav` base, as `extern_func` does. `site` is a stable string:
  `siteKey` (the declaration's key, `#ext` and the ZIR node offset, as
  anonymous struct literals' `#lit`) for `@extern`, the declaration's key
  for `&` of an `extern var`. So, as upstream's (whose Extern key has the
  ZIR instruction), two `@extern` sites of one name compare unequal at
  comptime, and one site equals itself.
- Sema gives it, in comptime blocks only, for `@extern` of a non-weak,
  non-thread-local, non-pcrel data pointer (or optional pointer) and for
  `&` of an `extern var` that is not thread-local; run-time code keeps
  `extern_ptr`. As upstream: field and element pointers, pointer
  arithmetic, comparisons (with each other, `null`, and other pointers)
  work; loads ("unable to resolve comptime value"), stores and
  `@intFromPtr` at comptime are errors; `@export` of one is "export
  target cannot be extern". `comptimeLoadStructuralKey` and
  `memRootValue` treat the base as run-time memory. `@extern` now
  checks its type as upstream does ("extern symbol cannot have type",
  for a type that is not extern-compatible or a non-const pointer to a
  function), and a thread-local or DLL import at comptime is upstream's
  "unable to resolve comptime value".
- Code (`constLoc`) reads the address from the symbol's extern slot, as
  for `extern_func`. An address `off` bytes into the symbol has its own
  slot, `useExtern("<name>\x00<off>")`: the name no symbol has carries
  the offset through `Emit.externs`, the `ext` references and the
  manifest unchanged, and `lowerExternSlots` adds it to the addend
  (`pullInputs` wants the symbol's name).
- Data (`lowerValue` in `lowerNav`, after analysis and the slots)
  relocates directly to where the slots bind the name
  (`Emit.externTarget`: an export, an input object's definition at its
  offset, a section bound, compiler_rt's, a library's import, or in an
  object an import). A declaration's data is then no longer a function
  of its value alone: an edited object moves the definition, so a
  `nav_val` node's store entry (`exact_hash`) mixes in its atoms'
  relocations, and an eager build with inputs writes the new record.
  Since 2026-11-05 it mixes in the whole records, as a function's does
  (contents, section, alignment, zero-fill size, debug info): its type's
  layout can differ under the same key, source and value in another
  compilation of the same store seed. std.testing's `io_instance`, an
  undefined `Io.Threaded`, is 880 bytes without libc and 1136 with it
  (`posix.Sigaction`), and a `-lc` test reused a libc-less test's entry,
  so its relink, and a donor build from its manifest, gave the variable
  880 bytes (test/run/store_layout.sh). A
  lazy build keeps the data it does not lower, as the last build bound
  it (its inputs are unchanged, else it is eager, and it falls back when
  the exports change). It does not load link inputs, so one that lowers
  data naming an extern symbol builds again eagerly
  (`Emit.inputs_deferred`). An undefined symbol in data is a compile
  error (`lowerNav` records it as `Emit.failed`).
- A variable whose value is wholly undefined, or lowers to zeros with
  no relocations, is a zero-filled atom, as LLVM places it: `.bss`
  (`__bss` on Mach-O), or for a thread-local `.tbss` (`__thread_bss`),
  instead of `.data` or `.tdata` bytes. std's 256 KiB
  `Thread.maybeAttachSignalStack` stack left every executable's file
  (2026-11-05). Sizes (x86_64-linux, before → thread-locals only → all
  variables): hello 2,672,792 → 2,406,552 → 2,399,376 bytes; the zig
  compiler workload 110.74 → 110.40 → 110.38 MB; std's tests 58.78 →
  58.52 → 51.93 MB, whose RW segment's file bytes drop from 6.5 MB to
  19 KB. Constants keep their bytes in `.rodata`, as LLVM keeps them,
  and other data its bytes, undefined as 0xaa.
- A constant that a function reads is a content atom CodeGen writes
  while analysis runs, before the exports and inputs are complete. Its
  address of extern symbol `name` relocates to `Emit.externAddrKey`
  (`extaddr.<name>`) with the pointer's offset as addend, so its content
  does not depend on where `name` is defined and the pack stores it as
  is; the unit requests `name`'s slot (`useExtern`), so the `ext`
  reference carries it through replay, archive pulls and
  `checkLinkInputs`. The link binds each such key through an alias
  (`Elf.Options.aliases`, `Symbols.aliases`) to what `name`'s slot binds
  it to: the target and addend of the slot atom's one relocation. A
  build gets them from `lowerExternSlots`, a relink from the manifest
  (`Incremental.externAliases`) from the slot atoms it links, for each
  reference name whose `extaddr` key the manifest numbers, so a manifest
  without any costs one lookup per name. A new extern symbol in such a
  constant changes the externs, which a lazy build falls back on.
- `&f` of an `extern fn`, and its coercion to a function pointer, is the
  pointer `@extern` gives (an `extern_func` uav base), in run-time code
  too, as upstream: an inner function may read a local array of them
  (siv's `luaopen_*` table). In data it binds as extern data does, so an
  input object's definition counts (it went to `exportTarget`, which
  saw only exports, compiler_rt and libraries).
- `@extern` of a weak function gives the same value with `extern_func`'s
  `is_weak` set, so a container-level constant holds it (siv's
  `__cxa_thread_atexit_impl`). Comptime sees it non-null, as upstream.
  Run-time `orelse`, `if`, `.?` and `== null` test the address the link
  gives instead (Sema's `runtimeWeakExtern` reads it with `extern_ptr`),
  so an undefined weak symbol is null, where upstream folds the test to
  non-null (its ELF linker refuses the undefined symbol). CodeGen
  requests the slot weak (`useExtern(name, is_weak)`). Stored in data,
  an undefined one is still "undefined symbol".
- A data-only reference to a symbol that only an unpulled archive member
  defines is "undefined symbol": archive members are pulled from the
  slots' names during analysis. Weak and thread-local extern data at
  comptime keep their old error.
- Linker aliases (built 2026-11-04, for the content-atom case above):
  `Elf.Options.aliases` and `MachO.Options.aliases` name keys that
  resolve as another key does, plus an addend (`Elf.Alias`), so a
  content atom can relocate to a stable `extaddr.<name>` key whose
  binding the link supplies. An alias of an atom is its address plus the
  addend; of an import (addend 0 only) it is the import, with the same
  dynamic relocation, bind or stand-in a direct reference gets, which an
  ELF executable's import list (`exe_imports`) records for the layout's
  counts; of a value the value (with an addend only in keyed ELF links); Mach-O
  data cannot hold a value's abs64, as for direct references. Aliases
  resolve after addresses (`resolveAliases`), all targets first, so an
  alias of an alias is undefined. Numbered links number them in
  `Symbols.aliases`, parallel to `Options.aliases`. A link without
  aliases does no extra work. Checks: each linker's "an alias links as a
  reference to its target" test, keyed and numbered, byte for byte.
- Checks: test/run/extern_data.zig (exports as the definitions, two
  chained edits, upstream the same), test/link_input/main.zig (C
  objects' definitions, in code, declarations' data and functions'
  constants), and cache.sh's edits: one that moves the definitions in
  their section, a lazy edit of a function's constant, one that adds a
  new symbol to it (eager), and -lc alone, relinked by number.

### Mach-O object and archive inputs (aarch64-macos; designed 2026-11-04, for review)

The ELF design above, for `zig cc -target aarch64-macos -c` objects and
Darwin archives linked into bs's aarch64-macos executables. Facts below
are from clang 22's objects (`zig cc`, Debug: ubsan on, DWARF 4) and
from upstream's link of a Zig main with such an object.

**Reader.** `src/link/MachOInput.zig`, with ElfInput's shape and
entry points (`addObject`, `addArchive`, `pull`, `lookup`, `convert`
returning atoms, values, local symbols and input sections), so Emit's
resolution order and the cache's link-only inputs carry over unchanged:
Zig exports, then objects, then compiler_rt, then libSystem's imports.
The writer stays in MachO.zig; the Mac thread's dylib output
(milestone 8) touches the writer's dylib parts, and the two meet only
at `MachO.link`'s entry and `Options`.
- MH_OBJECT, CPU_TYPE_ARM64 only; a universal (fat) file contributes
  its arm64 slice. `Archive.Reader` gains Darwin's format: BSD `#1/<n>`
  long names and a `__.SYMDEF` / `__.SYMDEF SORTED` / `__.SYMDEF_64`
  symbol table (`zig ar` and upstream's static libraries write it).
- Names: Darwin's leading underscore is stripped on reading, since
  atom and import names are platform-neutral and the writer adds it.

**Sections to atoms.** One atom per section, keyed as ELF's, except
where noted. bs does not dead-strip, so MH_SUBSECTIONS_VIA_SYMBOLS
splits only what must be split.
- `__TEXT,__text` and other S_ATTR_PURE_INSTRUCTIONS → `.text`;
  `__TEXT,__const`, `__DATA,__const` → `.rodata` (the writer already
  moves atoms with absolute addresses to `__DATA_CONST`); `__DATA,__data`
  → `.data`; S_ZEROFILL → `.bss`.
- S_CSTRING_LITERALS (`__cstring`) and S_4/8/16BYTE_LITERALS:
  content-addressed pieces, as ELF's merged sections, so equal strings
  merge across objects.
- S_MOD_INIT_FUNC_POINTERS (`__mod_init_func`) → `.init_array`; the
  writer gains `__DATA_CONST,__mod_init_func` (8-byte pointers, chained
  rebases), which dyld runs. S_MOD_TERM_FUNC_POINTERS is an error, as
  ld64's.
- Thread-locals: S_THREAD_LOCAL_REGULAR/ZEROFILL (`__thread_data`,
  `__thread_bss`) → `.tdata`/`.tbss`, split at their symbols
  (`_x$tlv$init`), since the writer makes one descriptor per thread-local
  atom. The object's own descriptors (S_THREAD_LOCAL_VARIABLES,
  `__thread_vars`: thunk → `__tlv_bootstrap`, key, init → `_x$tlv$init`)
  are not copied: a descriptor's symbol (`_x`) resolves to its init
  atom, and the TLVP relocations to it become `aarch64_tlvp_*`, so C's
  and Zig's thread-locals share the writer's descriptors.
- Dropped: `__DWARF` (see debug info), `__LD,__compact_unwind` (read
  into unwind records, see unwind), `__LLVM`, `__llvm_addrsig`,
  `__apple_*` accelerator tables. `__TEXT,__eh_frame` is copied (see
  unwind).
- Objective-C (decided 2026-11-05). The sections libobjc finds by name
  (`__objc_classlist`, `__objc_nlclslist`, `__objc_catlist`,
  `__objc_nlcatlist`, `__objc_protolist`, `__objc_imageinfo`,
  `__objc_selrefs`, `__objc_classrefs`, `__objc_superrefs`,
  `__objc_protorefs`) become `Atom.Section.objc` atoms named
  `.<section>`, and MachO.zig gives each its own output section where
  ld64 puts it: the lists and image info in __DATA_CONST, the
  references the runtime rewrites (selector uniquing, class remapping)
  in __DATA. One `Atom.Section` kind and the name, rather than a kind
  per section, keeps ELF's per-section arrays (one output section per
  kind) from growing. The objects' `__objc_imageinfo` merge into one
  atom, as ld64 merges them: the class-properties and signed-class_ro
  flags only if every object has them, the Swift bits from the first
  object with any. What the runtime reaches only through those
  pointers goes where its kind does: `__objc_const`, `__objc_data`,
  `__objc_ivar` and `__cfstring` to `__data` (the runtime writes class
  and method data), the name strings to merged C strings. Upstream
  keeps those under their own names; nothing finds them by name.
  Other `__objc_*` sections are an error, and so are references to
  `objc_msgSend$<selector>` stubs (Clang's
  `-fobjc-msgsend-selector-stubs`), which bs does not synthesize.

**Symbols.** N_SECT (external, private external, local), N_UNDF (COMMON
when n_value > 0), N_ABS (an external one binds from every object and
from Zig externs through `lookup`, as ELF's), N_WEAK_DEF and N_WEAK_REF (`n_desc`), and
N_ALT_ENTRY (a second name inside its section's atom). N_INDR is an
error. Local `l`/`ltmp` symbols are relocation anchors only; external
and private-external functions and objects get `local_symbols` entries,
as ELF's.

**Relocations (ARM64).** A target is a symbol (`r_extern`) or a section
ordinal, whose address is in the object's own section addresses (the
offset into the target section's atom is `address - section.addr`).
`ARM64_RELOC_ADDEND` carries the addend of the PAGE21, PAGEOFF12 or
BRANCH26 after it; UNSIGNED keeps its addend in the field.
- UNSIGNED, 8 bytes → `aarch64_abs64` (a chained rebase, or a bind for
  an import); 4 bytes → an error until something needs it.
- BRANCH26 → `aarch64_branch26` (an import goes to its stub, as
  bs's own calls do); PAGE21/PAGEOFF12 → `aarch64_page21`/
  `aarch64_pageoff12`; GOT_LOAD_PAGE21/PAGEOFF12 →
  `aarch64_got_load_*` (the writer already relaxes an image's own
  targets); TLVP_LOAD_PAGE21/PAGEOFF12 → `aarch64_tlvp_*`.
- SUBTRACTOR + UNSIGNED (A - B): within one atom it is a constant the
  converter writes; with B the section's own atom (a section without
  pieces, such as `__eh_frame`'s FDE pc_begin and LSDA fields) and A
  elsewhere it is `aarch64_prel64` or `aarch64_prel32` to A; elsewhere
  an error.
- POINTER_TO_GOT (4-byte pcrel; the personality pointers of
  `__eh_frame` CIEs and of `__gcc_except_tab`'s type tables) →
  `aarch64_prel32` to a content-addressed 8-byte slot atom (rodata
  with a pointer, so `__DATA_CONST,__const`) holding the target (`gotSlot`, as ELF's C GOT slots;
  a bind for an import, a rebase otherwise), with addend 0: the field
  holds minus its own offset from the assembler, not an addend, and
  ld64 and upstream compute G − P. MachO.zig applies `aarch64_prel32`
  and `aarch64_prel64` (S + A − P) to image addresses, which no slide
  changes.
- AUTHENTICATED_POINTER (arm64e) is an error.
- C reaches libSystem data through the GOT (`___stderrp`), and calls it
  through stubs; a direct PAGE21 to an import is an error, as ld64's.

**Unwind (stage A2).** zig cc's Debug functions mostly use DWARF mode
(compact encoding 0x03000000), and Objective-C `@try` and C++ `try`
need their LSDAs, so `__eh_frame` is needed, unlike for bs's own frames.
libunwind looks a pc up in `__unwind_info` first and treats an entry
with encoding 0 as "no unwind info" (it does not fall back to
`__eh_frame` then); `__eh_frame` alone serves only a stripped
executable, which has no `__unwind_info`.
- `__eh_frame` is copied whole per object as an `.objc` atom named
  `.__eh_frame` into a new `__TEXT,__eh_frame` after `__unwind_info`
  (ld64's flags), 4-byte aligned so no zero padding between objects
  reads as libunwind's terminator. pc_begin and LSDA are SUBTRACTOR
  pairs (above), CIE personalities POINTER_TO_GOT. FDEs of functions
  the link drops stay (their pc_begin still resolves: input atoms are
  not garbage-collected).
- Each `__LD,__compact_unwind` entry (function, length, encoding,
  personality, LSDA) becomes a `MachO.UnwindRecord`: function atom key
  and offset, length, encoding, and for DWARF mode the FDE's
  `__eh_frame` atom and offset, found from the FDE's pc_begin
  relocation (its personality and LSDA are the FDE's), and otherwise
  its personality's GOT slot (`gotSlot`) and its LSDA (a
  `__gcc_except_tab` target). Clang gives a function with a personality
  a compact encoding and no FDE whenever compact unwind describes its
  frame (libc++'s inline `__throw_*` helpers), so those need
  `__unwind_info`'s personality array and LSDA index, as ld64 writes
  them. The converter returns the records in `Converted.unwind`, Emit
  passes them as `MachO.Options.unwind` (keyed links only).
- The link resolves each record's atom through the symbol table (a
  deduplicated atom's record describes the kept copy) and sorts them by
  atom and offset, and drops one past its atom's end or overlapping
  the one before (so both walk passes list every record). It numbers
  the personalities' slot atoms in that order (the first three; a
  record with a fourth gets encoding 0) and sets each record's
  UNWIND_PERSONALITY_MASK bits and, if it has an LSDA,
  UNWIND_HAS_LSDA. The section is the header, the personality array
  (the slots' offsets from __TEXT), the first-level index, the LSDA
  array (function offset, LSDA offset), the leading page and the
  chunks' pages. Each chunk's first LSDA entry is the count of LSDA
  records before its atom range, so chunks write their LSDA entries in
  parallel, in address order; `writeUnwindIndex` finds each index
  entry's first LSDA by binary search. When there are any records,
  each debug chunk's `walkDebug` also lists the kept text between its functions, by atom
  range (from its first entry's atom to the next chunk's, so no chunk
  reads another's `file_of`): each record's encoding over its range and
  0 over the rest, merging runs of 0. A DWARF-mode encoding gets its
  FDE's offset in `__eh_frame` in the low 24 bits in the write pass;
  the count pass uses the bare mode, which takes the same branches, so
  both passes count the same entries. Without records the pages are
  as before.
- Checked on the Mac: an Objective-C `@throw` caught by `@catch` in the
  same C function returns, as upstream's (exit 3), stripped and not;
  with `-lc++`, a C++ program that throws through libc++'s helpers and
  rethrows prints and returns what upstream's does.

**Debug info (stage A3; decided 2026-11-04: rewrite into the dSYM).**
A Mach-O object's DWARF has no relocations for offsets into its own
debug sections (DW_FORM_strp, the abbreviation offset, DW_AT_stmt_list,
range and location offsets are relative to the object's sections; only
addresses are relocated), so it cannot be concatenated as ELF's is.
Two ways to give C frames lines were compared:
- *Debug map.* ld64's way, and upstream's: the executable's symbol
  table gets N_SO/N_OSO/N_FUN stabs naming each C object, and
  debuggers read the DWARF from the objects at run time. std.debug
  (MachOFile.zig, `load` and `getDwarfForAddress`) follows N_OSO only
  when no dSYM sits next to the executable, so bs's own DWARF would
  move into a sidecar object with a symbol per function (std.debug's
  `loadOFile` rejects a whole object over one duplicate name), and
  every build with C inputs would write that second container. The
  link copies no C DWARF at all. But lines then need the objects at
  their recorded paths when the program runs: bs's C records live in
  the cache, which trims entries unused for 5 days, a copied or
  installed executable loses them, and lldb skips an object whose
  mtime moved.
- *Rewrite into the dSYM.* Each input unit is copied after bs's own
  units with its section-offset fields rebased, which needs a DIE walk
  over its abbreviations to find them (strp, sec_offset, ref_addr,
  line_strp; DWARF 5 adds str_offsets tables and the line header's
  forms). The walk produces sites to patch, which are applied as
  relocations against the output's debug section starts, so the copy
  is ELF stage B's input-section copy, and the sites can be cached per
  object with the link-only inputs. Measured with a prototype walker
  (ReleaseFast) over SQLite's amalgamation built with `zig cc -target
  aarch64-macos -g`: 443 KB of __debug_info, 20,867 sites, 0.35 ms per
  walk (1.26 GB/s); its __debug_line (2.9 MB) and __debug_str (96 KB)
  are copied unchanged. The walk costs less than copying the bytes.
Choice: the rewrite. The output stays self-contained like ELF's (the
executable and its dSYM, nothing in the cache), builds without inputs
keep their byte-identical dSYM, there is one DWARF container, and the
link stays dominated by copying. Its risk is a form or vendor attribute
the walker does not know; such a unit is dropped from the dSYM (its
frames keep their symbols, without lines) rather than failing the link.
Until A3, C frames unwind (stage A2) and show their symbols without
lines. `__apple_*` accelerator tables are dropped either way.

**Stages.**
1. A1: objects and archives, sections, symbols, relocations, cstrings,
   thread-locals, init funcs; C calling libSystem and Zig and back.
   Tests on the Mac satellite, compared with upstream's link of the
   same objects: test/link_input's lib.c-style objects built for
   aarch64-macos, an archive, a constructor, a thread-local, a panic
   in a callback.
2. A2: unwind, as above, with C++ exceptions (with the C thread's
   libc++ for the target).
3. A3: debug info into the dSYM.
The input code is verifiable in the orb up to the link (objects come
from `zig cc -target aarch64-macos`, and upstream links them for
comparison); running needs the Mac.

**A1 so far (2026-11-04).** `Archive.Reader` reads Darwin archives;
`MachOInput` converts objects as above; MachO.zig gains
`__DATA_CONST,__mod_init_func` and `Options.local_symbols`. A C-only
program (a main and test/link_input-style lib.c: a constructor, a
thread-local, cstrings, a table of pointers, printf and strlen) links
through them in the orb. Emit and the command line take the inputs once
the aarch64 backend is on main. The unit tests read real inputs:
build.zig's `addMachOInputs` has upstream's Clang compile
test/link_input/macho_*.c for aarch64-macos and `zig ar
--format=darwin` archive two of them, and Archive.zig's and
MachOInput.zig's tests embed the results (BSD names, the `__.SYMDEF`
table, a constructor, a static function, and GOT loads of a symbol 4
bytes into another member's data atom). The test module adds those
imports, so bs itself does not depend on them. Differences from the
design above:
- A thread-local template's atom is named after its descriptor's
  symbol (`_x`, not `_x$tlv$init`), since the writer puts the atom's
  symbol at its own descriptor, as ld64 does.
- C++ on Mach-O keeps weak inline functions in `__text` (no COMDAT
  sections), so whole-section atoms keep one copy per object; the
  first definition wins and the others are dead code. Splitting
  sections at their symbols (MH_SUBSECTIONS_VIA_SYMBOLS) would drop
  them, when output size matters.

**Wired in (2026-11-05).** Emit's `inputs` is a union of an `ElfInput`
and a `MachOInput`, picked by the target, so `pullInputs`, the
resolver and `externTarget` serve both; on aarch64-macos every name
nothing defines is a libSystem import, as ld64 binds it. C sources on
aarch64-macos compile through upstream's Clang with upstream's flags
(`CSource.Options.macos`: the `aarch64-macos` triple and bs's CPU,
`-mmacos-version-min`, `-fPIE -fPIC`, libSystem's headers from
`any-darwin-any`, libc always on; for the native target the SDK's, as
decision 1's *as built* says). A C `main` with no Zig entry is the
executable's entry, through an alias when it sits inside its section's
atom. translate-c takes aarch64-macos too (the same query, headers and
`link_libc`); its output matches upstream's byte for byte.

The other direction, bs's own relocatable output, is new:
- `src/link/MachOObject.zig` writes MH_OBJECT for `build-obj` and
  static libraries from the same Atoms as an executable (its header
  comment has the sections, symbols and relocations). Objects carry no
  DWARF yet, so Zig frames in a library linked from them have symbols
  but no lines.
- `Archive.writeDarwin` writes the static library as upstream's
  `build-lib` does: a `__.SYMDEF` index (every external symbol that is
  defined or COMMON, private externals too) and `#1/<n>` member names padded
  so that every member's contents start 8-aligned, which ld64 requires.
- ld64 (through clang), upstream zig and bs itself link both and run
  the result on the Mac; libvaxis's `bs build test` runs all 48 steps
  and the same 232 of 237 tests as upstream.
- `build-lib -dynamic` links an MH_DYLIB through MachO.zig
  (`Options.dylib`): the executable's layout without __PAGEZERO, LC_MAIN
  and LC_LOAD_DYLINKER, an LC_ID_DYLIB from `-install_name` (else the
  output path, as upstream's) and `--version`, and an exports trie of
  the non-hidden exports, Zig's and the C inputs' (`MachOInput.
  dynamicExports`). It is named `lib<name>.dylib` (`lib<name>.<version>
  .dylib`), as upstream's, and keeps the executable's preferred base,
  which dyld slides (upstream's starts at 0). Its dSYM symbolizes panics
  inside it. One difference from upstream: std's weak
  `_mh_execute_header` is exported as it is, where upstream's linker
  drops it.
- Executables link against Mach-O dylibs given by path
  (`zig build`'s `linkLibrary` of a dynamic library passes its path and
  `-rpath`): `MachODylib` reads the install name, versions and exports
  trie; each gets an LC_LOAD_DYLIB after libSystem's, an import binds to
  the first one exporting its name (two-level ordinal), else to
  libSystem, and `-rpath` directories become LC_RPATHs.
- Frameworks and SDK libraries (decided 2026-11-05). On a macOS host
  with a native target, the library and framework search paths are the
  SDK's (`CSource.darwinSdk`, the C thread's cached `xcrun` answer):
  `<sdk>/usr/lib` and `<sdk>/System/Library/Frameworks`, plus
  Homebrew's prefix, as upstream's. `-l` there prefers `.tbd`, `.dylib`
  and `.so` over `.a`; `-framework X` (and `-needed_framework`) finds
  `<dir>/X.framework/X.tbd`, `.dylib` or bare `X` in the `-F`
  directories and then the SDK's, as upstream's `resolveFrameworkInput`.
  A text-based stub becomes a `MachODylib` through `Tbd.dylib` (install
  name, versions, arm64 exports including the ObjC class, metaclass,
  ehtype and ivar symbols). Its re-exported libraries are read from
  their own stubs, found as upstream's `parseDependentDylibs` finds
  them: by name in the `-F` and `-L` directories (and the native SDK's)
  first, then at the install name under the same SDK root. The first
  serves a vendored SDK, a package of stubs passed with `-F` (zine's
  CoreServices re-exports CoreFoundation by its system path, which holds
  no stub). A public one (in /usr/lib,
  or a framework's own library: upstream's `isHoisted`) is linked in
  its own right, as ld64's implicit linking and upstream do: a
  `MachODylib` marked `implicit`, after the linked ones, which gets an
  LC_LOAD_DYLIB only if an import binds to it. So Foundation's
  `objc_msgSend` binds to libobjc and AppKit's CF names to
  CoreFoundation. A private one's names merge into the stub that
  re-exports it. Each import binds to the first library exporting its
  name. Differences from upstream: LC_LOAD_DYLIB order is the command
  line's, then the implicit libraries' in first-use order (upstream
  sorts), and libSystem's current version stays 1.0.0.
  `-weak_framework` is refused.
`build-obj` with C sources or objects merges them (`MachOMerge`, see
"Relocatable links"), and `-lc++` links libc++ and libc++abi.

### compiler_rt (decided 2026-11-02)

- Upstream compiles all of `lib/compiler_rt.zig` as a separate compilation
  and links it into every binary (about 5,400 symbols even in a no-std
  program); it is 3.9 s of upstream's cold hello world, and editing any std
  file it imports rebuilds it.
- bs makes compiler_rt a module of the same compilation instead, analyzed
  lazily like everything else: when CodeGen or Sema needs a helper (for
  example `__udivti3`, float conversions, f128 arithmetic), it references the
  helper's declaration in the compiler_rt module, and only that function and
  what it reaches are analyzed, generated, and cached. compiler_rt's
  `comptime` export blocks are not analyzed; bs maps helper symbol names to
  their declarations (upstream names the function after its symbol, e.g.
  `pub fn __udivti3` in `compiler_rt/udivmod.zig`).
- Mechanism: `compiler_rt` is a module rooted at `lib/compiler_rt.zig`
  (ZIR in the global cache), but `loadAll` does not load it: when
  `Zcu.analyzeAll` resolves a request, `Frontend.loadFile` loads the
  helper's file and the files it reaches that are not loaded yet, with the
  same work queue, and numbers them after the loaded ones. A program that
  calls no helper loads none of compiler_rt (measured before std was
  always loaded: a std-free hello took 2 files instead of 701; 0.6 ms
  cold instead of 180–190 ms, 0.3–0.5 ms warm instead of 5.6–5.8 ms). AstGen errors in files loaded this way are
  reported with Sema's (`Frontend.late_errors`). CodeGen calls a helper
  through `Emit.requestCompilerRt(file, name)`, which returns the stable key
  of the helper's function unit, `compiler_rt:compiler_rt/<file>:<name>`;
  that key is also the call's symbol. Emit hands the requests to the Zcu
  (`Zcu.requestCompilerRtKey`) when `analyzeAll`'s function queue is empty
  (`sink.sync`), in the order they were made, so when Sema learns of a
  helper does not depend on when CodeGen ran (see "Parallel function
  bodies"); it also keeps file loads away from running CodeGen workers,
  which read `Frontend.files`. `Zcu.analyzeAll` resolves each new request
  (the file's root type, the declaration by name, its value) and queues
  the function like any other. A recorded unit that requested a helper
  also reaches the helper's declaration (a `root` reference: the request
  analyzes it, and a lazy build that requests again visits it, so a
  full build must reach it too, or the lazy build fell back), its
  function, and its file's root namespace (`addRtReach`). Replay skips
  the function and namespace references while the helper's
  file is not loaded yet, since only analysis may load it: the replayed
  request brings them back. A lazy edit build does the same for kept
  units: a helper node that the edit outdates (or whose file is a changed
  input) waits until its file loads (`Replay.rt_waiting`), the kept
  requester requests its helpers again (`Emit.requestRtKey`) and, once
  the file is loaded, marks the namespaces it used as used (`rt_effects`),
  and the file's old instructions are mapped to its new ones when it
  loads. A compiler_rt file that is not loaded yet counts as changed only
  if the last build's input for it changed (`isChangedPath`), so an
  inlined helper (`generic_fmod` in `fmod`) does not force an eager
  replay when the edit is elsewhere. Helpers are named by declaration,
  not by exported symbol (`__cmptf2` serves `__lttf2`, `fmodq` is exported
  as `fmodf128`).
- Externs and the link resolve names compiler_rt exports to its functions
  and variables (`Zcu.compilerRtExport`): every one upstream's
  compiler_rt exports for x86_64-linux, from src/compiler_rt_exports.zig,
  which tools/compiler_rt_exports.py generates by compiling upstream's
  compiler_rt in Debug and pairing each exported name with the
  declaration's symbol at its section and address. That covers what C objects call (soft float such
  as `__eqtf2` and `__extendhfsf2`, 128-bit division, `__atomic_*`), the
  libm functions, and, as upstream defines them in every binary,
  `memcpy`, `memmove`, `memset`, `memcmp`, `bcmp` and `strlen` (the Debug
  variants, `memcpyFast` and so on). The last four live in
  `lib/compiler_rt.zig` itself, whose key has an empty file part
  (`compiler_rt::memcmp`, as `Zcu.fileKey` names a module root). The
  stack protector's functions are left out: builds with C objects root
  compiler_rt/ssp.zig, so they are the compilation's own exports.
  Function multiversioning's CPU model (fmv.zig, which
  `__builtin_cpu_init` and `__builtin_cpu_supports` use) is declared in
  a nested struct, which its key names
  (`compiler_rt:compiler_rt/fmv.zig:x86.__cpu_model`) and
  `resolveCompilerRt` walks; its variables `__cpu_model` and
  `__cpu_features2` are lowered as declarations' data (`Emit.finish`)
  and reached from their requesters as a function is.
  aarch64-macos exports the same set but for three x86 names
  (`__gnu_h2f_ieee`, `__gnu_f2h_ieee`, `__zig_probe_stack`), which its
  objects do not call.
- compiler_rt bodies are analyzed without runtime safety, ignoring
  `@setRuntimeSafety`, because upstream builds compiler_rt in a release mode
  and its code relies on that (for example wrapping `-=` in `fmodq`).
  `builtin.is_test` is shared with the program, so under `bs test`
  compiler_rt sees `is_test = true`; it reads it only in declarations bs
  does not analyze (exports, its panic handler) and in `@setRuntimeSafety`
  arguments, which bs ignores there.
- `@memcpy`, `@memset`, and `@memmove` are inlined by CodeGen, not
  calls. On x86_64 a copy of known size (a struct copy, or `@memcpy` into
  a `*[N]T`) is straight 16-byte moves up to 256 bytes, a loop of 64-byte
  blocks and an overlapping last block up to 1 KB, and `rep movsb` above,
  where its start (about 8 ns) stops mattering. A runtime-length
  `@memcpy` branches on the length: two overlapping moves up to 16 bytes,
  a loop of 16-byte moves and an overlapping last one up to 256, `rep
  movsb` above. `@memset` is `rep stosb` and `@memmove` `rep movsb` with
  a direction check for overlap. aarch64 copies of known size are a loop
  of 32-byte `ldp`/`stp` blocks above 128 bytes, and runtime-length ones
  a loop of 8-byte words and a loop of bytes.
- Consequence: bs binaries contain only the compiler_rt symbols they use.
  Code that calls compiler_rt or `memcpy` by name gets them through the same
  lazy reference, so it still links.
- x86_64's runtime-length `@memcpy` dispatch is about 120 bytes at each
  site (1335 in std's test binary), most of the copy lowering's .text growth
  (std's test binary +305 KB, +1.4%; the zig workload +363 KB, +0.8%).
  An out-of-line routine, one content-addressed .text atom per output
  that each site calls (rsi, rdi, rcx in; rax and xmm0 clobbered; no
  frame), was measured and parked. Runtime copies through it, known
  sizes inline: std +151 KB, zig +93 KB. Everything from 257 bytes
  through it, with a 64-byte loop up to 1 KB for runtime lengths too:
  std +17 KB, zig +16 KB. Ir without capture tied (zigsema −3.44%
  inline, −3.46% and −3.37%; zls within 0.05 points) and wall was within
  noise; the routine cost known-size copies 1–2 ns (257 bytes 2.9 →
  5.1 ns) and tiny runtime ones 0.2–0.6 ns, and saved runtime copies of
  64 bytes to 1 KB 3–6 ns (257 bytes 11.4 → 5.6). The blocker is
  unwinding: on x86_64 std's unwinder ends the trace at a pc without an
  FDE (frame-pointer unwinding is unsafe there), so a fault in the
  routine, such as a copy from a bad slice, would lose its caller. The
  linkers write FDEs only for debug entries, so the routine would need a
  frameless `Atom.Unwind` kind and a debug entry carried with its content
  atom through the cache (`Replay` drops content atoms' debug entries,
  `knowsDebugPaths` wants a real file, and `Emit.mergeOut` skips a
  deduplicated content atom without its entry), a linker and cache
  change for a size-only win.

## The on-disk cache (milestone 6, designed now)

Decided (2026-11-02): a Go-style content-addressed cache at declaration
granularity.

- **Unit cache key** = hash(bs version, target and options, the unit's
  stable key, its declaration's `src_hash`, and for instantiations the stable
  hashes of its comptime arguments).
- **Entry** = the unit's result (serialized canonically, referencing other
  items by stable hash) plus the list of dependencies with the result hash
  each had when the entry was made.
- **Change detection.** AstGen already computes a 128-bit hash per
  declaration from its source bytes and starting column, independent of its
  line (`Zir.Inst.Declaration.src_hash`; `fields_hash` for container fields).
  That is each unit's own-code hash; bs does not hash ZIR itself.
- **Edit-rebuilds are push-based.** A per-project manifest, one mmap-able
  file, holds last build's units, their result hashes, and the dependency
  graph with reverse edges. A rebuild stats the input files, re-lowers only
  the changed ones, compares their declarations' `src_hash` with the
  manifest to find changed units, and walks reverse edges from those alone.
  A re-analyzed unit whose result hash is unchanged stops the walk (early
  cutoff). The cost is proportional to the edit, not to the program; a
  rebuild with no edit costs the stats and the manifest load.
- **First builds reuse other projects' graphs.** Entries live in a global
  cache directory shared across projects, so std's functions compiled for
  one project are reused by the next, the way Go reuses compiled std
  packages. As built (2026-11-03, "First builds: donors" below), a first
  build does not look units up one by one: it replays a whole manifest
  that another compilation published, a donor, as an edit build in which
  the donor's other files are changed inputs, and the replay's red-green
  decides what is reused. The store's entries only deduplicate Atoms.
- **Storage.** Two layers, split by who reads them:
  - The global store holds entries in immutable packs, git-style: each
    build writes its new entries as one pack file with a sorted key index,
    and lookups binary-search the mapped indexes of all packs. Concurrent
    bs processes need no locks to write, and old packs are removed by age.
    Only a project's first build and units re-analyzed after an edit touch
    it. (Go's one file per entry was measured and rejected, below.)
  - The project's local cache holds the manifest and a pack: one file with
    every Atom the last build linked. A rebuild maps the pack, appends the
    Atoms it regenerated, and links from it, so the link reads one file.
    When a lazy build folds the manifest's log, it rewrites the pack's own
    records if their dead bytes exceed the live ones (`compactOwn`); a full
    or eager build, whose atoms are all in store packs, names a new empty
    pack.
  - Measured on the orb (2026-11-02, warm page cache): reading 30k 2 KB files
    took 70–84 ms; mapping and touching one 60 MB file took 2–3 ms. One file
    per entry is fine for occasional lookups and too slow for every link.
  - Not per-module packs: a build reads a slice of many modules, a std pack
    would mix entries from every project on the machine, and concurrent
    builds appending to it would need cross-process locking.
- InternPool contents are rebuilt lazily on a warm build: only units that
  must be re-analyzed load the types and values they reference.

### Storage layer (`src/cache.zig`, `src/cache/`; built 2026-11-02)

The storage layer knows keys, hashes, dependency edges, and Atoms, not
Sema: nodes carry an opaque `tag`, and a store entry's result is an opaque
payload until Sema serializes one. `src/Incremental.zig` connects it to a
compilation (see "Integration" below).

```
<global cache>/bs/store/<32 hex>.zsp       Store packs (shared by all projects)
<global cache>/bs/store/lock               flock held by maintenance (merging, trimming)
<global cache>/bs/store/trim               when packs were last trimmed
<global cache>/bs/zir/<32 hex>             every file's ZIR, by content (Frontend); trimmed with the packs
<local cache>/bs/c/trim                    when compilation directories were last scanned
<local cache>/bs/c/<32 hex>/               one compilation, keyed by root, target, options, output
    lock          flock held by the build that owns the directory; its mtime is the last use
    <32 hex>.zsp  base packs: hard links to the store packs holding the last build's Atoms
    manifest      base: mapped, pointer-free, replaced whole
    manifest.log  one checksummed record per build since the base
    pack          every Atom the last build linked, append-only
    inputs        instead of all the above, for a -fPIC or aarch64-macos build,
                  which the cache does not take: the files the last successful
                  build read, its link inputs and output, with stats and content
                  hashes; a build that finds them unchanged compiles nothing
                  (`InputsRecord`, main.zig), unless BS_CACHE_VERIFY asks for a build
```

- **Atom records** (`cache/atoms.zig`): 16-byte aligned, a 64-byte header,
  then targets, relocations, an optional debug header, then bytes and
  debug strings (no symbol name: the manifest keeps those, "Type
  names"). `check` validates a record once (lengths within it,
  section, alignment, frame kind, debug header lengths); `view` then builds
  the `Atom` and its `Atom.Debug` from the header without checks, their
  slices pointing into the record. A function's debug info is the record's
  tail, so an Atom and its debug info are cached and replaced together.
  Nothing decodes records into `Atom` arrays for a link: the linker reads
  them in place through `Pack.LinkAtoms` (below).
- **Store** (`cache/Store.zig`): each worker fills a `Batch`
  (`put(key, {src_hash, result_hash, deps, atoms, debug, payload})`), and
  `commit` writes all of a build's batches as one pack: a 64-byte header,
  the entries (`Header`, `[]Dep{key, result_hash}`, atom records, payload),
  then the keys sorted, their locations, and a 257-entry fan-out table on
  the keys' top byte. Large packs are written from several threads. A
  caller that lays out its entries itself writes them in place instead
  (`beginPack`, `PackWriter.writeAt`, `commitPack`, with `entryLen` and
  `encodeEntry`), so that a build's entries are never in memory at once:
  `record` does, since a batch holding every Atom again cost 350–400 MB at
  peak on a 282 MB binary. The
  file is placed with O_TMPFILE and link under a random name, so concurrent
  writers never collide. `open` maps every pack; `get` searches them in
  decreasing `order` (when their newest entry was written) without a
  system call, so a key's newest entry wins, and `Entry.isValid` is the
  red-green check. Past 16 packs, `commit` merges, under a non-blocking
  lock, the smallest packs, down to 8, into one that takes the lookup
  position of the newest of them; an entry is dropped where an unmerged
  pack newer than the entry's own holds the same key, so lookups still
  find every key's newest copy. Large packs are never rewritten to merge
  small ones: an earlier policy merged the cheapest run of adjacent packs,
  which could include a 555 MB pack, and the rewrite cost its size again
  in writes and, while compilation directories still linked the old
  inode, in disk. A pack records its last use in its mtime (refreshed at
  most hourly) and is deleted after 5 days unused, and while the packs
  total more than the size limit (below) the least recently used are
  deleted down to three quarters of it; a hit in a pack older than 2.5
  days is written again by the build's `commit`, so live entries move to
  young packs and one used entry does not keep an old pack alive.
- **Manifest** (`cache/Manifest.zig`): nodes (80 bytes: key, result hash,
  `src_hash`, ranges into the edge, reverse-edge, and atom-reference
  arrays, `tag`), an open-addressing key table, edges, reverse edges, atom
  references, input stat records (path, size, mtime, inode, content hash,
  with a sentinel for racy mtimes), error names in code order, and each
  node's references (`refs`, indexed by a per-node `ref_starts` array,
  with the names they use in `ref_names`). Rewriting
  the base costs ~20–35 ms here, so an edit build appends a log record
  instead (`Delta`): the changed and added nodes, inputs, and error names.
  `open` applies the log into a small in-memory overlay; a torn record at
  the end is dropped and overwritten. When the log passes a quarter of the
  base, the next build writes a new base (`Builder.initFrom`, `write`).
  Reverse edges are a superset while a log exists: a node's old reverse
  edges stay until the next base, so a walk may re-check a unit that no
  longer depends on the edit, never miss one.
- **Symbol numbering** (in the manifest, for `Elf.Options.symbols`): a
  table from every key a live atom defines or references (error-code keys
  and the entry included) to a dense number (24-byte slots, about 80%
  full, so ~30 bytes per key; only an edit's new keys are looked up in it),
  a `NumberedAtom` (own number, start of its target run) per atom
  reference, the target numbers (one run per atom, a node's runs
  contiguous in its atoms' order), each error's number, and the entry's.
  A relink passes these slices straight from the mapping, and the linker
  hashes no keys. A log record numbers only its new keys, after the
  existing ones, and appends its runs, which the linker reads as
  `Symbols.targets_tail` after the base's runs; while a log exists,
  `linkInput` gathers the atom arrays once (~1 ms at 100k atoms and 15
  records). Writing a base renumbers in link order (the atoms as they
  are linked, then targets no atom defines, then error codes and the
  entry) with array lookups, not key hashing, and drops keys nothing uses;
  a manifest written after pack compaction (`Builder.setAtomRefs`)
  therefore numbers the packed atoms 0..n. The link needs each key defined
  once, so `write` rejects a duplicate. The manifest also interns debug
  source paths (`files`, and a file index per atom reference), and
  `LinkAtoms.debug` hands every debug entry its file's one copy, so the
  linker matches files by address. It lists the atom references that
  have debug info (`debug_atoms`, ascending), the linker's `debugAtom`.
- **Pack** (`cache/Pack.zig`): the compilation's own append-only pack plus
  base packs, store packs hard-linked into the compilation's directory. An
  `AtomRef` is 12 bytes: pack (0 for the own pack, else a base), offset in
  16-byte units (up to 64 GiB), and length; atom records inside store
  entries are referenced in place. A first build therefore writes its Atoms
  once, into the store pack it commits, and the hard link keeps the inode
  alive when the store merges or trims that pack. On another file system
  (`EXDEV`) the pack is copied instead. `append` writes the regenerated
  Atoms with one `pwrite` and remaps; old records stay put, so the manifest
  stays valid across appends. `LinkAtoms` is the linker's input
  (`Elf.linkInput`) read straight from the mappings: `check(i)` bounds the
  record in its pack and runs `atoms.check`, once per atom in the linker's
  first pass over it (a failure is `error.InvalidInput`, and the build
  starts over without the cache), and `atom(i)` and `debug(j)` return
  values built by `atoms.view`. `compact`
  moves the live records, from every pack, into a new own pack in link
  order (`bench_cache` only: copying a big build's store records into the
  own pack would store them twice). `compactOwn` rewrites only the own
  pack's live records, in manifest order, and leaves refs into base packs
  alone; `finishLazy` runs it when it folds the log and the own pack's
  dead bytes exceed its live ones, then writes the base with the new id.
  A full or eager build records every atom in store packs, so `record`
  names a fresh id and `finishRecord` writes the empty pack with it once
  the manifest is placed. Either way a crash in between leaves a manifest
  whose pack id does not match, which costs a rebuild from the store, not
  a wrong link. The manifest names its base packs and the own pack's id.
- File contents are trusted once their lengths check out: indices inside
  them are not bounds-checked on each access. Records are host-endian (both
  targets are little-endian).

Measured with `zig build bench-cache` (ReleaseFast, 4-core orb, warm page
cache; the orb varies ±40% run to run) on a synthetic compilation of 30k
units plus 30k other nodes, 300k edges, 600 inputs, 2000 error names, and
100,000 Atoms with distinct keys (22 MiB of code and data, 650k
relocations): manifest 14.9 MiB, pack 55 MiB.

| Step | Time |
|---|---|
| No-edit rebuild: lock, map manifest, stat 600 inputs | 0.29–0.57 ms |
| Open manifest with 15 log records, gather link input | 0.96–1.05 ms |
| Edit storage work: append one unit's Atoms, log record | 0.1 ms |
| Dependents walk over 29,978 nodes (no early cutoff) | 1.9–2.5 ms |
| Relink, numbered: map, `Elf.emitInput` reading 100,000 records in place | 8.0–10.5 ms (gather 0.01; 10.2–11.7 decoding first) |
| Relink with 15 log records (gather 1.0–1.2, log runs as `targets_tail`) | 8.5–9.5 ms (11.0–12.9 decoding first) |
| Relink by keys, as before numbering | 11.2–14.2 ms (15.5–17.2 decoding first) |
| Relink, numbered, after compaction (packed in link order) | 8.0–8.7 ms (10.4–11.8 decoding first) |
| Cold save: pack append, manifest base | 80–120 ms, 70–107 ms (numbering the keys 47–74 of it) |
| Fold log into a new base (renumbers) | 41–71 ms |
| Compaction, 164 → 55 MiB; manifest renumbered after it | 156–230 ms; 41–54 ms |
| Store, first build: 30k puts on 4 threads, then commit (68 MiB) | 17–23 ms, 43–48 ms |
| Store get, validate, decode, per entry, with 1 / 8 / 64 packs | 0.25 / 0.3–0.5 / 0.7–0.9 µs |
| Store miss, per key, with 1 / 8 / 64 packs | 0.06 / 0.2 / 1.0 µs |
| Store open with 1 / 8 / 64 packs | 0.02 / 0.08 / 0.5 ms |
| Store trim scan of 8 packs; of 64 with a merge of 57 | 0.14 ms; 95–109 ms |
| Store, 4 concurrent builds each writing 30k entries | 163–203 ms |

The no-edit target (10 ms beyond process start) holds with room to spare.
An edit rebuild's storage cost is the walk plus the relink, and the relink
is `Elf.emit`, the linker's own cost, not the cache's.

Rejected (measured 2026-11-02): one store file per entry, like Go's. Creating
a file costs ~25–30 µs on this ext4 orb whichever way it is placed (O_TMPFILE
and link, or create and rename), so a first build's 30k puts took 650–740 ms
on one thread and 215–390 ms on four, four concurrent builds 1.4–1.9 s (the
journal serializes them), a lookup 2.8–3.6 µs (open, read, close), and a trim
scan of 60k entries 65–77 ms. Packs need one file per build.

Also rejected: a first build writing its Atoms twice, to the store and to
the project's pack (83 ms of pack append on top of the 42 ms store commit
in `bench-cache`), and project packs naming store packs, which would depend
on files other builds merge and delete. With hard-linked base packs the
commit (written into the compilation's directory, then linked into the
store) takes 42 ms, the relink reads it as fast as an own pack with
byte-identical output, and the cross-file-system fallback (store on tmpfs)
takes 136 ms.

Decoding before the link (replaced 2026-11-03; the "decoding first"
numbers above are from the same session): `Pack.decodeAll` built `[]Atom`
and `[]Atom.Debug` on 4 threads, 4.2–4.7 ms at 100k atoms, and a log's
target runs were joined into one array. Reading records in place moves
their page faults and header reads into the linker's passes (emit +1.5–2
ms) and removes the decode.

Also rejected: faulting the packs in before the link with
`MADV_POPULATE_READ` in 4 MiB chunks on every core, as the linker
populates its output. The relink got 0.6–0.8 ms slower (8.6–9.8 against
8.0–8.9 ms in one session): populating a 68 MiB page-cached file takes 0.9–1.2 ms on 4
threads, the same as touching each page, and file read faults are already
cheap (fault-around maps 16 pages each) and spread over the linker's
threads. The output's case differs: a fresh page's first write fault zeroes
it and can flush every CPU's TLB.

### Integration (`src/Incremental.zig`; built 2026-11-02)

- **Compilation key**: the bs binary's identity (inode, size, mtime), the
  target, the working directory, the zig lib directory, and the command
  line. The store seed, part of every store key, is the binary's identity
  and the target only, so store entries are shared across projects.
- **No-edit builds** (`relinkIfUnchanged`, before the frontend): lock the
  compilation, map the manifest, stat its inputs (every file the frontend
  loaded, with content hashes and the racy-mtime rule); if none changed,
  link the records in place from the packs (`Pack.LinkAtoms`) with the manifest's
  numbered symbols, entry, and error codes. Frontend, Sema, and CodeGen do not run. A
  conformance unit loading 562 files (std in test mode): 0.64–0.9 ms in
  bs (0.4–0.6 of it the stats), 2 ms wall, against 14–19 ms for a full build.
  Inputs in the default lib directory (`Incremental.trusted_lib`: the
  compilation's `zig_lib_dir` is upstream zig 0.17.1's, see "Finding the
  zig lib directory at run time") are not statted: that is the trust the build
  runner's stamp and `main.prefixInputs` place in it, and it saves a
  cached compile step of libvaxis's example 700 of its 860 stats. Edit builds
  still see a changed file there (Replay compares the frontend's content
  hashes, and its check of unloaded inputs stats every one); any other
  lib directory is checked in full.
  The generated 24.5k-atom program below relinks in 5.2–7.6 ms (5.3 ms
  steady), against 7.4–9.5 (7.9 steady) when it decoded first.
  If the output still has the inode, size, and mtime the last link left
  it with (the compilation directory's `output` file, written after each
  successful link and deleted before each link starts), the build does
  not link at all and leaves the output untouched, so a `zig build`
  runner neither copies nor rehashes it: hello takes 0.8 ms in the cache.
  `bs run` (`renew_output`) still renews its program's mtime, which
  trimming reads as its last use.
- **Recording** (`startRecord` once Emit has its atoms, alongside the
  link; `finishRecord` places the manifest only if the link succeeded, so
  a failed link leaves the last successful build's; the store pack it
  wrote stays, its entries being valid results either way): Emit tags each atom
  with its owner (a unit, a content-addressed constant, or the link's own
  code) and each unit's uses of constants. The manifest gets one node per
  unit and per dependee kind (`nav_ty`, `func_body`, `func_ies`,
  `namespace_name`, `namespace`, `embed_file`), with edges from
  `Zcu.deps`, each node's `src_hash` (its declaration's, from ZIR) and
  result hash (InternPool stable hashes; function and constant atoms'
  contents; inferred error set names; which declaration a name finds; a
  namespace's names; an embedded file's contents, keyed by its module and
  path), the error names in code order, the entry, and the inputs
  (source files and `@embedFile`d files). Each node with Atoms is a
  store entry keyed by (store seed, node key, `src_hash`); an entry already
  in the store with the same result hash is referenced where it is,
  otherwise it goes into the build's new store pack. Nodes are written in
  the order of their first Atom, each with its Atoms grouped.
  Keys and hashes of the distinct units and dependees are computed on
  every core first (they only read the Zcu), then nodes are made in order;
  store lookups run on every core, the misses are laid out in node order,
  and their entries are encoded straight into the new pack on other
  threads while this one fills and writes the manifest, which names the
  pack before it exists (`Store.reserveName`).
- **Link order**: the linker lays out atoms in chunks of input positions,
  so its output depends on the input order and on duplicates, not just on
  the set of atoms. A fresh build therefore links exactly the list the
  manifest replays: `finish` groups each owner's atoms, sorts the owners
  by their atoms' symbol keys (the first atom's, then the next ones'; the
  link's own atoms last), and drops later atoms with a key already seen
  (`Emit.groupByOwner`). The order is a function of the atoms and their
  owners, not of the order units were analyzed or loaded in, so a build
  that loads units from the cache (a donor's first build, an eager edit
  build) links the bytes a full build does, given the same error codes.
  Sorting by symbol key rather than by the manifest's node key costs no
  keying (2026-11-03). A relink then reproduces the fresh build byte for
  byte for any alignments; the test in `src/Emit.zig` mixes alignments,
  duplicate constants, and a unit whose atoms are split.
- **Cost of recording**: on a generated std-free program of 20k functions
  and 5k globals (24.5k atoms, 68.6k nodes, 196k edges; 0.7 s to build),
  the build waits 65–80 ms for `record` after the link (wall 665–720 ms,
  against 725–777 ms and 109–129 ms of `record` when it ran after the link
  on one thread). The link is only ~10 ms of that overlap; the rest is
  `record` using the other cores: the graph 39–47 (collecting items
  11–15, keys and hashes on every core 9–13), lookups 2, then the manifest
  30–37 while the store writes. On x86_64/binary.zig (128.7k atoms, 256k
  nodes, a 282 MB binary) the wait after the link is 230–420 ms against
  1.09–1.26 s, and peak RSS 975–980 MB against 1.33 GB (837 MB without the
  cache). Before, on one thread: the graph 45–49, store puts 20–21, commit
  20–22, manifest 30–33 (nodes and symbols 16–17, write 14–17). Numbering
  the symbols is 4–6 ms of the manifest's share (the nodes loop takes
  13 ms without it). The graph took 116–125 ms before each unit's and
  dependee's node was memoized (its key string was rendered and hashed
  once per edge), the maps hashed their small keys with a multiply instead
  of byte-wise Wyhash, edges and atoms went to two flat arrays grouped by
  counting sort instead of two lists per node, and atom contents were
  hashed with Wyhash instead of SipHash. 630 nodes take 1.3–1.9 ms.
- **Memory of recording** (2026-11-04, the `zig` workload, ReleaseFast,
  peak RSS): analysis ends near 990 MB and `BS_CACHE=off` peaks at
  1.04 GB. Recording peaked at 1.46 GB with an empty store and 1.68 GB
  with a warm one: the store lookup read every node's entry header through
  the pack mappings, which kept 230 MB of pack pages resident, and the
  graph's tables and the words the manifest had copied lived until the
  record ended, through the manifest's write. Now `Store.peek` reads the
  headers with `pread` (lookups 38 → 93 ms on a warm store, all 135k
  atoms' nodes hits; an empty store finds no key and reads nothing),
  `collect` frees its item maps once every item is listed, `makeNodes`
  frees the pairs and item arrays `group` consumed, and `freeTables`
  frees the rest but the nodes before the manifest is written: 1.32 GB
  empty, 1.33 GB warm. Build time is unchanged within noise (empty store
  10.94 → 10.91 s, warm store without a donor 10.85 → 10.95 s, median of
  5). What remains above analysis is the graph's nodes and per-item info
  (about 150 MB) and the manifest builder (about 105 MB, the 134 MB
  manifest's sections), which the store's writer and the write need.
- **Error codes**: the last build's names are assigned first
  (`seedErrors`), so codes stay stable across builds.
- **Prediction check** (`BS_CACHE_CHECK=1`): compares a build's nodes with
  the last manifest. The seeds are the nodes whose `src_hash` changed and
  the source-computed nodes whose result changed; every node whose result
  changed must be reachable from them over the last manifest's reverse
  edges. This is the set an edit build will re-analyze.
- `BS_CACHE_TIMING=1` prints the cache's time; `BS_CACHE=off` disables
  it.
- **Size limits and trimming**. `BS_CACHE_MAX_SIZE` (bytes, or a number
  with K, M, G, or T; default 4G) limits the global cache and, separately,
  a project's local cache, each counted once per inode. The global cache
  shares its limit (`cache.globalShares`): the store (packs, donors and
  ZIR) gets three quarters, and its compilation directories (those of
  `bs run` and of builds outside a project, whose local cache is the
  global one), `bs run`'s programs and the tools in `bs/o` (the
  translate-c and build runner executables, one per bs identity, and
  the C++ runtime libraries) a quarter. Before, each had the whole limit,
  and the tools none: an orb's global cache reached 5.8 GB against 4 GB.
  Every build applies the global limits when they are due (a stat each
  otherwise, `Incremental.maintainGlobal`): the compilation directories
  at most once a minute, the store at least every 10 minutes. Past it, the least recently used go, down to three
  quarters: store packs by mtime in `commit`'s maintenance, compilation
  directories by their lock's mtime in `cache.maintainCompilations`,
  skipping those a build holds, with their two output directories
  (`o/<digest>`, `Incremental.outputDigests`), which count with them.
  Store packs that this bs cannot read
  (another bs's pack format, or damaged) count and go by mtime like the
  rest, but are not deleted for being unreadable: two bs versions can
  share a store. `bs run`'s program directories (`bs/o/<hash>`) count
  and go with the compilation directories, by the program's mtime, which
  every run renews by relinking it, so a program run daily stays. `bs
  translate-c`'s records (`bs/tc/<key>`) count with their outputs
  (`o/<key>/`) and go the same way, by the record's mtime, which every
  hit renews; eviction deletes the record first, so that a half-deleted
  translation is a miss. Tools in `bs/o` (the C++ runtime libraries,
  libc_nonshared.a, the build runner, translate-c) are marked in use by a
  `used` file (`cache.useTool`): a build that finds one takes a shared
  lock on it before checking that the tool is there and holds it while it
  may read the tool (a C batch until `destroy`, translate-c while it runs,
  the build runner until it replaces the process), renewing its mtime.
  Maintenance deletes a tool only after taking that lock exclusively, and
  ranks tools a day later than their last use (`tool_bias_ns`), since
  rebuilding one takes tens of seconds. Programs and translation records,
  which have no lock, are kept over the limit while used within the last
  hour (`in_use_grace_ns`). Before this (2026-11-04), a concurrent build's
  maintenance deleted libc++abi.a and libunwind.a between another build's
  check and its read: tools were never renewed, so they ranked as old as
  their first build. `bs
  test` deletes its binary (`bs/tmp`) once it ran; ones a killed build
  left go after a day. A store pack that a compilation directory
  links keeps its space until the directory goes, which is why the local
  limit counts the links. The local scan runs after a build that started
  a directory (that is how the local cache grows) and otherwise at most
  once a minute, once the build's new pack is in its directory, so that
  the pack counts, while `record` writes the manifest; it stats the
  directories on up to 16 threads (600 directories: 5–6 ms on this
  4-core orb, overlapping the manifest's 8 ms). Directories unused for 5
  days go regardless. The cache can pass the limit only by the packs of
  builds still in flight (and by directories in use, which are never
  deleted). Measured with conformance runs by successive bs builds (a
  new identity each, `-j 16`), sampling `du` every second: with the
  default 4G, six runs peak at 3.85 GB (before, when the scan ran before
  the build's own pack was written: 4.47 GB after six); with 1G and two
  such runs at a time, three rounds peak at 1.01 GB (before: 1.50 GB). A
  limit below the working set cannot hold: two x86_64 units in use at
  once are 1.1 GB. The global cache's ZIR is
  trimmed and evicted with the store's packs (the Frontend section); a
  local cache's ZIR (written only when the global cache cannot be opened)
  is kept to the sources its index names (one version per path) plus a
  day of edits (`Frontend.trimCaches`, daily, also beside the store
  work), which also deletes both caches' stale temporary files.
- **Why the cache grew without bound** (measured 2026-11-03): a
  conformance run with an empty cache writes 696 MB that stays (653 MB in
  114 compilation directories, of which the x86_64 unit's are a 555 MB
  store pack and a 79 MB manifest; 56 MB of ZIR), and bs writes 1.36 GB
  in all with the test binaries. A warm run writes 0 bytes to the cache.
  But the store seed and compilation keys include bs's own identity,
  so every rebuilt bs writes everything again under new names, and
  nothing was deleted for 5 days: 650 MB per rebuild-and-run, about 40 GB
  over a few days of compiler work. Merges could rewrite the large pack
  (above), and the old compilation directories' hard links kept merged and
  trimmed packs' space in use.
- **Caches that still filled disks after the limit landed** (42–43 GB,
  with 1.1 and 2.3 GB packs in compilation directories, linked up to 27
  times): every one of those builds ran a bs built from a tree without
  the limit (bases 775ce0b and 08a7029, before 7c31921). The 2.3 GB packs
  were store merges of several bs builds' x86_64 packs, which the limit
  now bounds, and their many links were directories pinning a big pack
  for a few entries, which re-putting entries (above) now prevents.
- **Writes that fail** (a full disk, say) cost reuse, not the build: a
  cache that cannot be opened is skipped with a warning; a recording that
  fails is discarded with a warning, as a damaged pack falls back; a ZIR
  cache write failure is reported once. The generated `builtin.zig` is the
  exception: it must exist on disk to be compiled, as upstream's must.
- **Reuse means identical records**: `record` reuses a store entry when
  its result hash, counts, and atom-record length match, and the hash it
  compares covers everything a record holds (symbol key, debug file,
  name, and base line; records keep no symbol names since 2026-11-04),
  not only the contents. Until 2026-11-03 it
  covered contents and line numbers only, so an entry written by another
  compilation whose atoms had other names was reused, the manifest's atom
  references took this build's lengths, and the next relink failed its
  record check and rebuilt from scratch: the conformance x86_64 unit (204k
  atoms) took 15 s on every warm run instead of 0.5 s. `BS_CACHE_TIMING`
  now says why a build does not relink.
- **Touched but unchanged inputs**: when inputs' stats changed but their
  contents' hashes did not (a touch, a checkout, or an input too new to
  trust when recorded), the build still relinks, and their new stats go
  into the manifest's log (not past the fold size). Before, that was a
  full rebuild and a full manifest rewrite.
- Not yet: re-analyzing only the predicted units after an edit (designed
  below); recording comptime side effects.

### Edit builds: replaying cached results (designed 2026-11-03, for review)

Being built in steps (each mergeable, full builds unchanged): result
hashes (done), references (2a, done), seeds from ZIR (2b, done), result
closures (3, done), the hook and the verify mode (4a, done; see "Step 4a
as built" below), and lazy edit builds with a Delta and a relink from the
manifest (4b, done; see "Step 4b as built"). What an edit
build does, and what it needs from Sema, Zcu, and the InternPool:

**Flow.** The no-edit check finds changed inputs. The frontend loads every
file as today (unchanged files are ZIR cache hits). Before Sema runs,
`Incremental` computes the *seeds* from the changed files alone
(`src/cache/seeds.zig`). Each node records its source
(`Manifest.Source`, a `sources` section parallel to the nodes): an input
(for a Zig file, its file index in the recording build, which equals its
input index) and a ZIR instruction in the ZIR of that input's recorded
content: the declaration of a `nav_val`, `func`, or `func_body` node, the
container of a `type_layout`, `struct_defaults`, `namespace`, or
`namespace_name` node (with the name it looks up, in `source_names`),
the block of a `comptime_decl`; an `embed_file` node names its input
only. The old ZIR is still in the frontend's cache, named by the
recorded content hash (the global cache keeps ZIR used within 5 days), so upstream's
`mapOldZirToNew` (declarations by name, `comptime` blocks and unnamed
tests by order, the containers inside a declaration by order) maps each
recorded instruction to the new ZIR. A node is a seed if its instruction
no longer maps, if its `src_hash` changed (for `func_body`, its result,
which is that hash), if its container's declaration names changed, in
order (`namespace`), or if the name it looks up appeared, disappeared,
or changed `pub` (`namespace_name`); a changed embedded file's node is a
seed, and without the old ZIR every node of the input is. Recording the
sources costs nothing measurable and 8 bytes a node plus the looked-up
names (libvaxis: manifest 2.94 to 3.22 MB). `BS_CACHE_CHECK` computes
the seeds this way and checks that they reach every changed result:
conformance after edits to three std files (a body in `mem.zig`, a
comment in `debug.zig`, a new declaration and a default in `fmt.zig`)
reports 0 missed in all 113 units; mapping `mem.zig` takes 1.2 ms.
The *possibly outdated* set is everything reachable from the seeds over
reverse edges (`Manifest.rdeps`, already fast: 2 ms for 30k nodes).
Sema then runs from the usual roots, and every unit it reaches is either
re-analyzed or loaded:

- not possibly outdated: **load** its cached result;
- possibly outdated: bring its dependencies up to date first (recursively,
  in manifest order, loading or analyzing each); if every dependency's new
  result hash equals the manifest's and its own `src_hash` is unchanged,
  load it (early cutoff), else **re-analyze** it and compute its new result
  hash.

Only re-analyzed functions reach CodeGen. The link takes green nodes'
Atoms from the pack, appends the new ones (`Pack.append`), writes a
`Manifest.Delta` (new atoms numbered with only their targets looked up),
and links the numbered input.

**The hook** is in Zcu, in the functions that already own unit state, so
Sema itself does not change:

```zig
// Zcu: set by Incremental for an edit build, null otherwise.
replay: ?*Replay = null,

// ensureNavVal, ensureStructLayout, ensureFuncIes, before calling Sema:
if (zcu.replay) |r| if (try r.load(zcu, unit)) { mark resolved; return; }
// analyzeAll, for a queued function: a loaded function is `done` without
// IR; its recorded references are queued instead of analyzing its body.
// analyzeAll, for a comptime declaration: a loaded one replays its exports.
```

`Replay.load` (cache side, in `src/Incremental.zig`) decides green or red
as above, and for green units writes the result into Zcu state: `nav.ty`,
`nav.val`, `is_const`, `linkage`, `alignment`; a container's
`ContainerInfo`; a function's inferred error names (`inferred_errors`); a
function's references. It returns false for red units, and Zcu analyzes as today.
Two things Sema must add, both narrow:

- **References** (recorded since 2026-11-03): which functions a unit
  queued (`Zcu.queueFuncFrom`, from `navRef`, calls, coercions of a
  function to a function pointer, and `@export`), and what its code
  requested from Emit during CodeGen (`Emit.unit_refs`): declarations'
  data (`navKey`), error codes (`useError`), external symbols
  (`useExtern`), compiler_rt helpers (`Emit.requestCompilerRt`,
  `requestCompilerRtExport`), and the error name table
  (`useErrorNames`). The manifest stores them per node (`Manifest.Ref`:
  a node for functions and data, an error code, or a name), in the base
  and in log records. Loading a function replays them, so the set of
  linked units is the set reachable this build, and functions no longer
  referenced drop out of the link instead of lingering in the pack. A
  function is also reached when a unit resolves its inferred error set,
  which analyzes and emits its body: replay reaches it through the
  `func_ies` dependency the same way. `BS_CACHE_CHECK` verifies that
  the recorded graph reaches every function the build analyzed from the
  analysis roots (comptime declarations, exports, tests); every recorded
  conformance unit passes, including x86_64's 184k functions. Function
  pointers in a declaration's data are queued by the coercion that made
  them, in Sema, so lowering values (`funcKey`) needs no reference.
- **Result hashes at runtime**: `Replay` compares a re-analyzed unit's new
  result with the manifest's before its dependents decide, so the hashing
  `record` does today moves to one function both use.

**Serialized results** (`src/cache/results.zig`, recorded since
2026-11-03). A result is the closure of InternPool items it references
plus a few scalars. The manifest stores them, not the store: replay
loads the previous build's results of the same compilation, which the
manifest already maps, and one item table per manifest stores each item
once, where store payloads would repeat `[]const u8` in every entry.

- The item table (`items`, `item_starts` sections): every item some
  result references, children first, each its stable hash, its `Key` tag,
  and the key's operands as `u32` words, with every `Index` replaced by a
  reference: a static index (below `static_len`), `none`, or
  `static_len` + the id of an earlier item. Strings are inline (a length
  word, then the bytes, padded); big ints' limbs, floats' bits, and
  `aggregate` bytes are inline too.
- Each node's result (`results`, `result_starts`): a short list of words
  per unit kind, its `Index` fields references into the table. Empty for
  a node without one: a log record's nodes (until step 4's Delta stores
  them), unresolved declarations, and results that cannot be encoded.
- Loading walks a result's references, memoized per item: an item whose
  stable hash the run already has (`ip.indexOfHash`, a map built on first
  use) is taken as it is; otherwise its
  `Key` is rebuilt from the decoded operands and interned with `ip.get`,
  and `ip.stableHash` of the result must equal the recorded hash. A
  mismatch is a bug, treated as a cache miss that re-analyzes the unit.
- Key kinds, all by contents: `int_type`, `ptr_type`, `array_type`,
  `vector_type`, `opt_type`, `anyframe_type`, `error_union_type`,
  `simple_type`, `tuple_type`, `error_set_type`, `func_type`,
  `simple_value`, `undef`, `int`, `float` (exact bits), `err`,
  `error_union`, `enum_literal`, `enum_tag`, `un`, `slice`, `opt`,
  `aggregate`, `extern_func`, `extern_var` (its site is a string),
  `calling_convention`, `runtime_capture`.
- Key kinds that name source, by ZIR instruction: the absolute
  instruction in the ZIR of the recorded input, which an edit build maps
  to the new ZIR with the same `mapOldZirToNew` map that computes the
  seeds (it tracks declarations, containers including `@Struct`-style
  reifications, and function declarations); an instruction that no
  longer maps is a miss. `struct_type`, `enum_type`, `union_type`,
  `opaque_type` as (file, instruction, reified layout or none, the type
  that owns the parent namespace, captures, display name, stable key),
  everything `Zcu.createContainerType` takes. Interning one goes through
  a Zcu function that creates the type and scans its namespace as
  analysis does (Sema thread); a reified type's fields come from its
  captures, which hold all of `@Struct`'s arguments, through
  `Sema.fillReifiedInfo`, the function `zirReify` also uses, so the two
  cannot drift. `func` as (owner
  declaration, instruction, generic owner, comptime arguments);
  `inferred_error_set_type` as its function. A declaration, in `ptr`'s
  `nav` base, `func`'s owner, and `nav_capture`, is (the type that owns
  its namespace, its name), resolved by namespace lookup alone (tests,
  which are not in `decls`, by a scan of the test list). A capture stays
  unresolved until the type's body reads it, as upstream, because the
  type may be that declaration's own value.
- Not encodable: `comptime_alloc` pointers (an escape is a compile error,
  but a type's capture can name comptime memory), anything that refers
  to one, cycles, and items nested deeper than 1000. Such a result is not
  stored and its unit is re-analyzed in every edit build that reaches it.
  None occur in conformance or the std tests.
- `BS_CACHE_CHECK` decodes every recorded result from its words alone,
  rebuilding each item from its key (`ip.find` instead of the hash
  shortcut, container types, functions, and declarations found by their
  locators), and checks that it yields this build's exact indices and
  scalars, and that `ip.indexOfHash` finds each item. All 113 conformance
  units (714k results, 849k items) and the std tests (38k results, 130k
  items) round-trip with none unencodable.
- Cost: encoding runs on its own thread while `record` builds the graph
  and looks up the store, so a full build does not wait for it. The
  `zig` workload (upstream's compiler) has 70k results over 188k items,
  15 MB of words, encoded in 60 to 80 ms; its manifest grows from 75 to
  93 MB and its peak RSS by about 45 MB (1.355 to 1.40 GB). Hello: 4.6k
  results, 7.1k items, 610 KB, 2 ms.
- Interning a closure never calls `Zcu.ensure*`: container types come
  from `createContainerType` and a namespace scan, which need no
  declaration's value, and a `nav` pointer needs only the `NavIndex`.
  Otherwise `const Node = struct { next: ?*Node }` would report a false
  dependency loop: loading Node's layout interns `*Node`, which would load
  `nav_val(Node)` while it is in progress.
- `Replay.load` does call back into `Zcu.ensure*` to bring a possibly
  outdated unit's dependencies up to date, but only along the edges the
  manifest recorded for it, in their order, with the unit marked in
  progress exactly as analysis marks it. Those edges were taken while the
  unit was in progress, so they are acyclic, and a real loop introduced by
  an edit shows up the way it does in analysis.
- Anonymous types keep their recorded stable keys when loaded. A key is
  the declaration's key, the relative ZIR offset, and the capture hashes
  (see "Analysis units"), all of which a green unit reproduces; an edit
  that moves a type within a red declaration changes its key, so the
  declaration's result hash changes and its dependents re-analyze.
  Captures that refer to comptime-mutable memory have no stable hash;
  types with such captures stay out of results.
- Never in a result: `comptime_alloc` pointers (already excluded from
  stable hashing; an escape is a compile error), and Zcu's per-run maps
  (`comptime_memo` starts empty; memoizing comptime calls across builds
  would be its own node kind later).
- Accepted, unrecorded order dependence: a generic instance runs with
  the largest `@setEvalBranchQuota` among its callers analyzed so far
  (`Zcu.branch_quotas`), as upstream, so whether a deep comptime loop in
  an instance passes can depend on which callers were analyzed first. It
  is not a dependency. Its node records the quota (a `quota` reference),
  which an edit build restores before it analyzes or loads the instance,
  so loaded callers still count.
- Per unit kind: `nav_val` stores ty, val, `is_const`,
  `is_threadlocal`, `linkage`, `alignment` (the explicit `align(n)`, 0
  if none);
  `type_layout` stores the `ContainerInfo` fields (status, names, field
  types and `comptime` field values by reference, offsets, which fields
  are `comptime`, explicit field alignments, tag type, flags, size,
  alignment, `comptime_only`); `struct_defaults` stores whether the
  defaults were resolved and the other fields' default values by
  reference (reified structs get theirs with the type, so the unit has
  nothing to do);
  `func` stores its references (its Atoms are in the pack, its IR is
  never stored); the `func_ies` node stores whether the set is `anyerror`
  and the error names in the order they were found, and every non-empty
  set has one, read or not, so a loaded function without one has an empty
  set (an edit build can add the first reader); `comptime_decl` has
  no result, only its dependencies and references. A unit that `@export`s (`Zcu.Export.unit`; null
  for `export` declarations, which the namespace scan recreates) has an
  `analyze` reference, so an eager edit build analyzes it rather than
  load it. A lazy one leaves it green like any other unit (its exports
  stay in the manifest), unless it is outdated and a dependency's result
  changed: std.start's `@export(&main, ...)` under `-lc` depends on the
  root's `main`, so without this every edit there would run it again
  and fall back.
- `builtin.test_functions` is filled outside unit analysis
  (`populateTestFunctions`, after all tests are known), so the test list is
  its own node, and adding or removing a test changes it.
- Test order: `populateTestFunctions` sorts the list, so it does not
  depend on when each namespace was created (an edit build creates them in
  load order, a full build in analysis order). The main module's root file
  comes first, then the other files by module name and path; within a file,
  a container's tests come before those of the containers it holds
  (ordered by the container's ZIR instruction), each in source order.
  Within a file this matches upstream, which lists a file's top-level tests
  when it scans the file and a nested container's when it scans that
  namespace. Across files upstream follows its scan order, which comes from
  its work set, not a rule: `findOutdatedToAnalyze` takes functions first
  and then the first ready unit, and `clearOutdatedState` swap-removes it,
  so the most recently queued unit moves to the front. bs does not
  reproduce that, so file order can differ (libvaxis's `widgets.Table`
  tests run before `vxfw.vxfw`'s in bs and last in upstream).

**Error codes and inferred error sets.** Codes stay append-only per
compilation (`seedErrors` assigns the manifest's names first), so a name's
code never changes while the compilation directory lives, including names
only a skipped unit uses. That makes an `error_code(name)` dependency
unnecessary: a comptime `@intFromError` result cannot go stale, and the
dependency kind proposed earlier is dropped. An error set type lists its names in
code order (upstream's is string intern order; both put
`error{ One, Two } || error{Three}` as One, Two, Three, which
`@typeInfo` and `@typeName` show), so seeded codes also keep that order
stable across edit builds. New names from re-analyzed
units take the next codes and go to the Delta. A function's inferred error
set is the `func_ies` node: a green function's names come from its payload,
so `ensureFuncIes` on a skipped function does not analyze its body; a
re-analyzed function whose set is unchanged keeps callers green, and a
changed set re-analyzes exactly the callers that resolved it. With
parallel Sema the codes of names first seen in the same build depend on
scheduling; outputs stay correct, but byte-identical output across cold
builds would need sorting new names before assigning them at the end of
analysis.

**`type_layout` result hash** (built 2026-11-03 in `record`; the eager
`comptime_only` and its recorded walk are Sema's). A layout
node's result used to be the type's identity, which is wrong under early
cutoff: when a field's type grows,
the field type's layout result changes, ours is re-analyzed, and its
unchanged identity would stop the walk before the functions that use our
offsets. The result hash becomes the hash of the canonical `ContainerInfo`
encoding above (field names, field types' and `comptime` field values'
stable hashes (an enum's tag values; other struct defaults are the
`struct_defaults` node's result, so editing one re-analyzes only the
struct inits that omit the field and `@typeInfo`, not code that reads
offsets),
offsets, tag type and its values, non-exhaustiveness, runtime tag, size,
alignment, and `comptime_only`), computed once the status reaches
`have_layout`. Types reached only through pointers keep their identity:
pointer types hash by the child type's identity, so self-referential types
need no recursion. `comptime_only` must be in the hash: if `F` gains a
`type` field, its size and offsets can stay the same, and a struct `S` with
a field of type `F` would keep its hash while becoming comptime-only,
leaving functions that take `S` at runtime green. As in upstream 0.17
(`Type.classify`), a pointer is a runtime type whatever it points to, so
`*F` never makes `S` comptime-only; a struct with both runtime and
comptime-only fields is "partially comptime": comptime-only, yet with
runtime bits, its comptime-only fields taking no space, so a pointer to it
can reach runtime code. Whether a type is comptime-only therefore depends
only on the types it contains by value, which are exactly the layouts
`resolveLayout` resolves and records as `type_layout` dependencies. Sema
sets `comptime_only` when a struct's or union's layout reaches
`have_layout` (`setComptimeOnly`), from its fields' answers, which are
final by then; no walk through pointers, so no cycles. Every other Sema
read goes through `isComptimeOnlyResolved`, which resolves (and records)
those layouts first, and a function declaration resolves its parameter
and return types' layouts, as upstream's `funcCommon` does, since whether
a parameter is comptime-only decides how the function is called. So
`nav_val(f)` depends on `type_layout(S)` for `fn f(s: S)`.
`nav_val`'s result hash adds
`is_const`, `is_threadlocal`, `linkage`, and `alignment` to the value's
stable hash, since dependents read those too. `record` reads
`comptime_only` from the types, on every core: Sema has set it for every
struct and union at `have_layout` (debug-asserted), so reading it writes
nothing.

**`struct_defaults`** (built 2026-11-03). A struct's non-`comptime` field
defaults are their own unit, as upstream's: a default may read the
struct's layout or a containing type's, which, evaluated inside the
layout unit, was a dependency loop (`union { a: struct { x: u32 =
@alignOf(@This()) } }`, behavior/union.zig). The unit depends on
`type_layout(S)`; Sema reads defaults only after
`resolveStructDefaults`, which records `Dependee.struct_defaults`: struct
inits that omit a field, `@typeInfo`, and std.lang values Sema builds.
As upstream, the unit also runs once the struct's layout is resolved
(through `Zcu.ensureStructLayout`), whether or not anything reads a
default, so a bad default is an error (`Zcu.queueDefaults`, drained by
`analyzeAll`; upstream's `exported_function_uses_invalid_type`). Only
declared structs with a non-`comptime` default are queued, and the
layout unit is the first reference in the trace. The layout's node
references the defaults' node (`defaults`), so that an edit build's
walk reaches defaults whose own dependencies changed while the layout
did not. `comptime` field values stay in the layout (a struct's one possible value
and field reads need them, never the other defaults). The node's source
hash is the container's, and its result hash is the defaults' stable
hashes, 0 for a field without one, or the type's identity before they are
resolved.

**Edge kinds.** Every recorded dependency edge carries a kind, so that
the format replay freezes can grow without a new graph:

- *plain*: U resolves D itself. Replay.load enters it, in order, with U
  marked in progress.
- *conditional*: comptime lowering read D because something else had
  already resolved it (`Zcu.conditional_deps`; see "Comptime evaluator").
  It invalidates (a changed D makes U possibly outdated) but Replay.load
  does not enter it: a green U never needs D to intern its result. Green
  units skip lowering, which has no effect on the output except through
  memo entries: a red unit near the branch quota can succeed or fail
  differently in an edit build than in a full build, the memo's existing
  order dependence (as upstream's), which `BS_CACHE_VERIFY` may flag
  only at the quota. Call counts differ between edit and full builds
  (green units make no calls), so lowering happens at different points and
  the recorded edge sets differ; both cover what the walker read.

The optimizer's inlining (see "Optimizing backend") needs no third kind:
a caller depends on the dependee `func_inline: f`, whose tag already says
that it invalidates the caller's CodeGen, not its Sema. Its producer is
`f`'s `func` unit (as `func_ies`'s), its result hash is the canonical
hash of `f`'s inlinable SSA (positions relative to `f`'s base line;
types and constants by stable hash, callees by Nav key), or a constant
"not inlinable" marker, and every call site that passes the caller-side
rules records it whether or not `f` was inlined, so that an edit that
makes `f` inlinable reaches callers that call it. CodeGen records these
edges (a per-caller list beside `Emit.unit_refs`). A caller red only
through them still re-runs Sema, since IR is not cached; a green `f`
whose body a red caller needs is re-analyzed without being emitted, its
manifest data kept (option (a) there).

The manifest stores the kind in the top 2 bits of each edge's word
(`Manifest.Edge`: a 30-bit node index, two values spare; 2^30 nodes is
ample). `record` takes it from `Zcu.conditional_deps`, and a plain edge
to the same node wins. Reverse edges are plain node indices: both kinds
invalidate.

**Roots and output kinds** (`bs build-obj` and `build-lib`, built
2026-11-03). Reach already starts from what `record` gathers (namespace
roots, exports, tests, `comptime` declarations), not from the entry, so
an object's exports are its roots with no change there. What the relink
needs besides the atoms is in the manifest (ZAPMAN12):

- The header's output kind (`Manifest.Output`: exe, obj, lib). The
  compilation key holds the arguments, so the kind cannot change within a
  compilation directory; a mismatch only declines the relink. The entry is
  0 for an object.
- `link_symbols`: the exports (atom key and name) and then the imports
  (key, name and `Emit.ImportFlags`: weak, hidden, tls), each sorted by
  name, as `Emit.finish` orders them for `ElfObject`.
- Imports are references, like externs: `Emit.useImport` records an
  `import` reference for the current unit, which a worker's merge carries
  over and which a loaded unit requests again (`Replay`), so an eager
  build's import list is a full build's. The reference's name is the
  symbol's, a NUL and the flags as a digit, so a change in flags alone is
  a changed reference. A lazy build falls back when the imports of the
  live nodes change, flags included (`checkLinkInputs`, as for externs),
  or exports change (as before), so the manifest's lists stay right
  without a log record for them.
- `ElfObject.linkInput` takes the numbered input `Elf.linkInput` takes;
  an import's number gets the value 0. With no entry, `Elf` ignores
  `Symbols.entry`. A library relinks by building the object in memory and
  writing the archive (`Archive.write`) with the member named after the
  root source file.
- Donor keys include whether the build links an object: CodeGen makes an
  object's unresolved symbols imports instead of compiler_rt calls, so an
  executable's atoms are not an object's.
- `-fPIC`, `-fPIE` and `-dynamic` builds skip the cache for now (see
  "Position-independent code and shared libraries").
- Checked by test/obj/cache.sh: cold, relink, lazy edit, an import that
  goes (eager fallback), an export that comes back, and an import that
  becomes weak (fallback, then a relink), for build-obj and build-lib, each byte-identical to a build without the cache and checked
  with `BS_CACHE_VERIFY` and `BS_CACHE_CHECK`.

**Step 4a as built** (2026-11-03). An edit build is a full build in which
green units are loaded instead of analyzed; `record` then writes a whole
new manifest and pack from the Zcu and Emit, as a full build does. That
leaves the Delta, instruction maps across log records, and the numbered
relink to step 4b, which makes the edit build lazy as well; 4a's output
and manifest are a full build's, which `BS_CACHE_VERIFY` checks.

- `src/Replay.zig` owns it. `Incremental.beginReplay` creates it after
  `seedErrors` if the compilation has a manifest (`BS_CACHE_REPLAY=off`
  turns it off): changed inputs, the seeds and their instruction maps
  (`seeds.compute`), and the outdated set. The Zcu hook is as above:
  `ensureNavVal`, `ensureStructLayout`, `ensureStructDefaults`,
  `ensureFuncIes`, and `analyzeAll`'s function queue and `comptime`
  declarations ask `Replay.load*` with the unit marked in progress.
- A unit is green if its node exists with a result (a function or
  `comptime` declaration needs none), its source hash is
  unchanged, it has no `analyze` reference, and every plain dependency
  can be made (its node's *subject*, below) and brought up to date with
  `Zcu.ensure*`; if the unit is outdated, each dependency's result hash
  must also equal the recorded one. Then the dependencies are recorded
  as the unit's (`Zcu.recordDeps`), its result is decoded into the Zcu,
  and its references are replayed through the APIs analysis and CodeGen
  use (`queueFuncFrom`, `Emit.navKey`, `useError`, `useExtern`,
  `requestCompilerRt`, `useErrorNames`). A function's atoms come from the
  pack and go to Emit with the unit as owner, with its constants'
  content atoms (once each, with their `content_uses`); its inferred
  error set comes from its `func_ies` node. Conditional edges are not
  entered and not recorded again. A `nav_ty` dependency is brought up
  to date with `ensureNavTy`, so loading a unit that took an address
  does not need the declaration's value.
- *Subjects* (a `subjects` section beside the results): each node's live
  unit or dependee, so that a green unit's dependencies are made from the
  manifest alone: a declaration, a type, a function, a namespace with the
  name looked up, an embedded file's key. Decoding one makes the types
  it names as analysis would (`results.zig`'s resolver:
  `createContainerType`, `fileRootType`, `Sema.fillReifiedInfo`, and a
  union's generated tag enum, whose item carries its fields since no
  unit has it as a result). A function is interned with its instruction
  mapped to the new ZIR.
- Debug info: a green function in a changed file gets `base_line` from the
  new ZIR, and each inlined call's base line is refreshed through its
  callee's key (`inline_callees`) if the callee's file changed.
- Effects outside a unit's result: a namespace whose creation queued
  `comptime`, exported or test declarations has `Namespace.effects`. A
  unit whose analysis evaluated such a type's declaration or `@import`
  (`Zcu.effect_uses`, noted by `Sema.createContainerType` and
  `Sema.fileRootType`) gets an `analyze` reference
  unless loading it makes the type anyway: the type is its value, or the
  subject of one of its plain dependencies. Otherwise a green unit that
  made such a type would skip its `comptime` blocks and exports. Noted on
  every evaluation, not only the one that created the namespace, so that
  the references do not depend on analysis order. That includes reusing
  the type without evaluating its code again, as dependencies are
  declared: a memo entry keeps the types its call noted
  (`Zcu.Memo.effects`) and a hit notes them, and a lowering for the
  comptime evaluator, which folds the comptime calls it makes or reuses,
  marks where the walker would note one (`comptime_effect`,
  `Zcu.Bytecode.effects`) for the units whose runs reach it.
- Anonymous types are named `Parent__struct_<n>` with `n` relative to
  their declaration (`<ordinal>_<offset>` in `comptime` blocks, see
  "Analysis units"): with absolute instructions,
  a green unit's result kept the old name of a type in an edited file,
  and code reading `@typeName` went stale.
- The error name table is written in code order, not use order, so that
  its atom does not depend on which units were loaded.
- `bs test` replays too: the test list is sorted (above).
- Known limits: a unit is red, not loaded, if a result or dependency
  cannot be made (`BS_CACHE_CHECK` prints each one; none in hello or
  conformance). Two declarations that take each other's addresses, one
  of them outdated and red while the other loads, can report a false
  dependency loop, since the loading one has no type yet.
- `BS_CACHE_VERIFY=1`: after an edit build that replayed, bs builds the
  same command again in full in a child (`BS_CACHE_VERIFY=full`: no
  relink, no replay), whose `record` compares its nodes with the edit
  build's manifest (set by hand with an input changed since that
  manifest, `full` fails saying so rather than compare with an older
  build; only inputs the full build reads count, since an edit build
  leaves one it no longer reads as it was, such as an `@embedFile`d
  file deleted after its last reference went): the same nodes with the same kinds, source hashes,
  results, dependencies (by key and kind), references, and atom records
  byte for byte (so `base_line`s too). Not the output's bytes: a lazy
  build links in manifest order with its new nodes last. A difference
  fails the build. `zig build test` runs it in test/run's edit scripts
  (`rebuild-without`, `rebuild-replace`, `rebuild-lib-without` headers:
  each edit is built forward and back, verified, then relinked):
  test/run/edit.zig (a body, a signature, a field type, a defaulted and a
  comptime-only field, a new declaration, an `@embedFile` of itself),
  test/run/edit_std.zig (lines moved in a copy of std's debug.zig), and
  test/run/panic_inline.zig (an inlined callee moves).
  `tools/conformance/run.py --edit-verify` does it for every behavior
  unit: after the unit's build it prepends a line to its file, adds a
  statement to its first test, and appends a declaration, builds,
  restores the file and builds again, both verified with
  `BS_CACHE_CHECK` on. The unit's first build is verified too: with
  donors it is an edit build of another unit's graph.

**Step 4b as built** (2026-11-03). An edit build is lazy by default
(`BS_CACHE_REPLAY=eager` selects 4a): it loads only what analysis reads,
records only what changed, and links from the manifest.

- *The walk.* `Zcu.analyzeAll` starts `Replay.startWalk` from the root
  files' namespace nodes and the link node, and follows what a full
  build's analysis would reach (`Incremental.reachNext`: plain
  dependencies, and the `func`, `nav`, `effects`, `root` and `defaults`
  references). Record adds the edges reach needs: `effects` (a unit to
  the namespace it evaluated), `root` (a namespace to its `comptime`,
  exported and test declarations), `defaults` (a struct's layout to its
  defaults, which analysis queues), `func` from exported, test and compiler_rt declarations
  to their functions, and the link's own requests on the link node.
  `BS_CACHE_CHECK` checks that reach finds every node with atoms. A node
  the walk reaches that no edit reached is live and is not loaded. An
  outdated one goes to analysis (`ensure*`, `queueFunc`, a namespace's
  scan), which decides it, and the walk goes on from it if it is green.
  A namespace whose container or roots an edit reached is made again, so
  that its scan queues the roots as they are now, and its node is
  recorded with its names as they are now (`Replay.made_namespaces`):
  the green unit that evaluated the container is not loaded, so without
  it nothing would list the namespace, and an edit that only adds or
  removes a public declaration in an imported file left the node
  undecided with its old names (`BS_CACHE_VERIFY` on zls's Server.zig;
  test/run/edit_ns_decl.zig).
  A function an edit reached that turns out green decides its inferred
  error set and inline result as recorded (`Replay.commitLazy`): a
  non-empty set has a node whether or not a unit reads it, so the walk
  may never reach it, and std's tests left seven `Io.Future` sets
  undecided after a body edit in `std.debug.print`.
- *Walking only the edits' cone* (2026-11-04). Every node records
  whether a walk from the roots reaches it (`Flags.reached`: a full
  build's record sets it from reach, a lazy one's from `reachedNow`),
  and the base holds the reverse of the references reach follows
  (`rrefs`, beside the dependencies' `rdeps`). A lazy build walks only
  the *cone* (`Replay.assumeReached`): the reached nodes that are
  outdated or in a changed input, the functions that inline one of
  those (whose lines the walk refreshes), the namespaces with roots in
  it, and the requesters of compiler_rt helpers in it. Every other
  reached node is *assumed*: marked visited without being walked; it is
  neither outdated nor moved, so walking it would only follow its
  recorded edges. The walk starts at the roots and at the cone's nodes
  that an assumed node names (`entries`), as if that node had been
  walked; a red declaration that an assumed node refers to has its data
  lowered again as before (`data_refs`). On zls with a body edit in
  Server.zig, 465 of 72,210 nodes are walked. Recording finds what is
  reached now (`Incremental.reachedNow`): what the walk visited, plus
  what the nodes it left to analysis and the written nodes reach over
  their new edges; then the assumed nodes the cone's nodes reached
  before but no longer do, and what they reach among the assumed, are
  candidates, and those that a remaining assumed node or a walked node
  still reaches stay. The rest are no longer reached and not linked. A
  build falls back to eager if one that goes offered or read type names
  (`contributeNames` counted it). A walked node may have been entered
  only from an assumed node that goes, so the record also finds the
  walked nodes still reached: from the roots and from the entries an
  assumed node that stays names, over the edges as they are now. Those
  it does not reach go too, and the assumed nodes only they reached
  become candidates; this repeats until nothing more goes, and the build
  falls back only if the walk analyzed, wrote or took a type name from a
  node that goes. (On vaxis, an edit in Vaxis.zig makes a struct type
  declared in the edited function, its function and that function's
  inferred error set new each time, and the old ones go; that had made
  every such edit build eager, 140 against 28 ms.)
  With the cone past half the
  reached nodes, or in a donor's build, it walks everything as before.
  `BS_CACHE_CHECK` walks the graph the build leaves in full
  (`checkLiveReach`) and requires the same `reached` flags and linked
  nodes, and fails the build, as for an eager one, if they differ. It
  checks only a delta the record will write, after `checkLinkInputs`;
  a lazy attempt that falls back clears what its checks found, since
  the eager build checks itself. (Until 2026-11-05 a lazy build that
  recorded such gaps succeeded, and a later fallback failed the eager
  build with the lazy attempt's finding: the edit hunter's first sign of
  compiler_rt declarations a lazy build visited but a full build did not
  reach, see `addRtReach`.)
- *Touching only the cone's part of the manifest* (2026-11-04). The
  setup and the record around the cone walk cost per edit, not per
  node: the overlay keeps a bitset of the nodes the log touched, so
  `node`, `nodeRefs`, `flags` and the other accessors read an untouched
  node straight from the base without a hash lookup; the base stores
  the reached flags as words (`reached_bits`, `Manifest.reachedSet`)
  and the stale nodes as a list (`stale_nodes`, `Manifest.staleNodes`);
  `Replay.create` stats only the inputs the frontend did not load, and
  lists the nodes in changed inputs once, in one pass over the base's
  sources (`Manifest.nodesOfInputs`), for the seeds, the cone and the
  record's source rewrites. The record
  updates flags only for nodes whose flags can differ (the cone, the
  outdated, the analyzed, what reach gained or lost, and every node in
  a build that assumed nothing), finds exported nodes through `rrefs`,
  and skips `checkLinkInputs` unless a checked or written node has
  external or error-name references, or the build made new error names
  (whose table an unchanged node, a test runner's `@errorName`, may
  link). zls Server.zig edit: setup 10.4 → 4.2 ms.
- *Loading on demand.* A green unit's result is decoded only when
  analysis reads it (`ensureNavVal` and the rest). Writing a result into
  the Zcu first brings the unit's plain dependencies up to date, as
  analysis would have: CodeGen reads the declarations a value points to.
  A green function is never decoded: its atoms stay in the pack, and only
  its inferred error set is set. Emit lowers only the data of this
  build's declarations (`Replay.keepsNavData`).
- *Recording* (`Incremental.finishLazy`, in place of `startRecord`, the
  link, and `finishRecord`): `recordDelta` builds the same graph as
  `record` (`Graph`), from this build's analysis only, and appends one log
  record. It holds the nodes of the units analyzed, every new node, and
  the dependees whose results, references or subjects changed. A
  subject is compared by its item's stable hash (`sameSubject`): a
  function whose type changes keeps its dependees' keys, and a subject
  left naming the old function item, its instruction remapped to the
  new ZIR, interned a function of the old type with the new body for
  the next build (a crash in `analyzeFuncBody` after `main` gained a
  parameter, from upstream's test/incremental with donors; any lazy
  build after such an edit). `BS_CACHE_VERIFY` compares dependees'
  subjects the same way. Their atoms are
  appended to the local pack. It also holds the changed and new inputs,
  this build's result items after the manifest's (items it decoded keep
  their ids), and new error names. For the changed inputs, it rewrites
  every node source and result item that names an instruction to the new
  ZIR (`SourceDelta`, `ItemOverride`, `results.remapSource`), or to none
  if the instruction is gone. Items carry their length beside their tag
  for this. It refreshes the lines of green functions that are, or that
  inline a function, in a changed input (`refreshDebug`; the walk makes
  the inlined callees' declarations). A function loaded green whose
  recorded declaration does not map, as in a container whose fields
  changed (which maps none of its declarations), takes its line from its
  declaration now (`Replay.decl_insts`). Node flags record what is linked:
  `unlinked` for nodes with atoms that the walk and this build's nodes do
  not reach. `stale` marks nodes an edit reached that the build left
  undecided, which the next lazy build seeds again. The link then reads
  the manifest with the record applied (`linkFrom`, shared with the
  no-edit relink), and a log past a quarter of the base is folded into a
  new base.
- *Falling back.* A build whose changes the log cannot express builds
  again in the same process as an eager edit build, with the log
  untouched (`error.LazyFallback`, which `main.compile` catches, so that
  the `--listen=-` server falls back too):
  an `@export` that ran again, a function generated again that an
  `@export` left green names (`Emit.nameAtoms` would name its atom after
  the declaration), exported or test declarations added or
  removed, a declaration's data lowered for the first time without its
  unit being analyzed, data with the address of a link input's symbol
  (`Emit.inputs_deferred`), or a change in the link's inputs outside the atoms
  (external symbols, whether the error name table is written, and new
  error names while it is). `BS_CACHE_TIMING` says why.
- `BS_CACHE_VERIFY` compares a full build with the edit build's manifest
  as before, and also requires the full build's nodes to be neither
  `stale` nor, with atoms, `unlinked` there. Nodes only in the edit
  build's manifest count only if they are linked.
- Known gaps: `bs test` skips `populateTestFunctions` in a lazy build,
  since the test list is as linked (adding or removing a test falls
  back). Inputs touched without a change are rehashed until the next
  build that records them. The own pack grows with each record until the
  log folds, which compacts it when dead records dominate.

**Debug info of green functions.** `src_hash` ignores a declaration's
line, so lines added above a green function move its `base_line`
without re-analysis. For green functions in changed files, the relink
takes `base_line` from the new AST, the way it takes debug paths from the
manifest's file table, and the manifest records the new value. Calls
inlined into a function hold their callees' base lines too (in
`Debug.inlines`), which move when only the callee's file changes: the
exact hash includes them, so a store entry with old ones is not reused,
and each carries the callee's key (`inline_callees`, the `SymbolKey` of
its `Nav.key`) so a relink can refresh them the same way.
test/run/panic_inline.zig rebuilds after such an edit and checks the
trace. The verify
edit scripts include moving an inlined callee's lines.

**First builds: donors** (built 2026-11-03). A compilation's first build
(no manifest in its directory: a new project, a new git worktree, a new
command line) replays another compilation's manifest, a donor, instead of
analyzing everything.

- *Publishing.* After every full record (a cold or eager build), once the
  manifest is placed, `publishDonor` hard-links it and the store packs it
  names into `<global cache>/bs/store/donors/<donor key>-<random>/`,
  built under a `tmp-` name and renamed into place, so readers see only
  complete donors. Every atom of a full record is in a store pack, so the
  donor needs nothing from the compilation's directory, and its links keep
  the packs alive when the store merges or trims them. A donor's name
  carries its program's tag (`donorTag`): a hash of the subcommand,
  `--name`, and the main module's and every module's name and absolute
  root file. A program's new donor replaces its older ones, so that a
  project that records often does not take other projects' slots; the
  newest 128 per donor key are kept, and the store's cap and trim bound
  their space as they do the packs'. A lazy build does not publish: its
  atoms are in the compilation's own pack. (With 4 per key, a corpus run
  of 80 programs, most sharing one key, evicted every program's own
  donor, so each next first build replayed a neighbour's eagerly:
  ghostty-vt-test 11.4 s instead of 0.18 s lazily.)
- *The donor key* (`donorKey`): the store seed (bs and the target), the
  std directory, and the options Zcu reads without recording a dependency
  (`-fsingle-threaded`, which decides whether declarations are
  threadlocal, test filters, and the root module's `-M` name, which
  `@src()` and messages show while its files are keyed `=root:` or
  `=main:` in every compilation), whether the build links an object,
  which CodeGen reads (an object imports what it does not define), and
  whether a test build tests std itself (`bs test <lib>/std/std.zig`,
  `Frontend.testsStd`). Only the module under test has tests among its
  roots, so that decides which of std's containers have effects
  (`Sema.noteEffects`): a std container that a `bs test main.zig` donor
  evaluated has no `effects` reference, and a std test build that loaded
  it green would record a graph that misses the container's tests
  (`BS_CACHE_CHECK` reports them as not reached).
  Everything else (the builtin module, root and modules, every file) is
  an input the replay checks. Options that change code without changing
  builtin.zig (`-fPIC`, `-ffuzz`) must join the key, or the store seed as
  `-ffuzz` does, when they land.
- *Choosing.* `useDonor` runs after the frontend: among the donors of
  this compilation's key, it takes the one whose builtin module is this
  build's, then one it can replay lazily (below), then the program's own
  (same tag), then the one sharing the most input files (same path, same
  key, same content), then the newest. The program's own donor is read
  first; if it has this build's builtin and can be replayed lazily, the
  others are not opened. It links the donor's packs into
  the compilation's directory from the donor's own links; if that fails
  (trimmed concurrently), it tries the next, and without one the build is
  cold. Ranking reads each candidate's input and path tables, well under
  1 ms.
- *Replaying.* The build is an edit build against the donor, lazy where
  it can be (below) and otherwise eager, so that it records a full
  manifest of its own and publishes it in turn. Error codes
  are seeded from the donor (`seedErrors`). Inputs now carry their file's
  key (`Manifest.Input.key`, `<module>:<path in it>`), and `Replay.create`
  matches files to inputs by key, which is what nodes name files by:
  within one compilation keys and paths correspond, and a donor's file is
  this build's file with the same key wherever it is, so a git worktree
  matches its donor's files and compares their contents. A donor's input
  whose key names no file here and does not hold here (`inputKeyHolds`:
  its module is missing, or puts the key at another path) is a changed
  input with no new ZIR, so all its nodes are seeds: another project's
  files, the same file under another module name. The root module and
  the module under test are named by role, `=root` and `=main`, which no
  `-M` name can spell (`--dep` and diagnostics use the `-M` name), so a
  `bs test` of a file never matches the `bs build-exe` of it as its
  root module, and no other module's keys are theirs. A module's root file is
  keyed `<module>:` without its path (`Zcu.fileKey`), so the donor's root
  file is this build's root file, changed, and std's `@import("root")` in
  a donor's result names this build's root struct; whether its
  declarations match is decided by the namespace dependencies, as in any
  edit. A module with `--dep`s puts `#` and a hash of them (each import
  name and the module it gives) after its name in its files' input keys
  (`Incremental.inputKey`, not in unit keys): an `@import` reads which
  module the name gives, which no source hash covers. A donor whose
  program maps the names to other modules (revo's two test programs
  swap `root` and `revo`, so capi's `@import("revo")` gives another
  module in each) then has that file as a changed input with no new ZIR
  whose key does not hold, and its units are analyzed again however
  their sources compare (`Replay.rebound`): before, they loaded green
  and named the donor's module by its name. Its embedded files' input
  keys carry the same tag (`Incremental.embedKey`); without it, every
  edit build took them for a donor's, changed, and a donor of the same
  program replayed eagerly (test/run/edit_embed_dep_key.sh). In an eager replay, a function's atom is loaded only if its debug
  info names paths this build's would (`Replay.debug_paths`): source paths
  are as the compiler opened them, so with relative paths a worktree's
  functions load, and with absolute ones only std's do.
- *Lazy donor builds* (built 2026-11-04). A donor build is a lazy edit
  build against the donor's manifest: it walks from the roots, loads only
  what analysis reads, and links from the manifest. `finishLazy`
  hard-links the donor's manifest into the compilation's directory as its
  base (`installDonorBase`; bases are replaced, never written in place,
  as `publishDonor` already relies on) and appends the build's log to
  it, under an empty own pack with the id the donor's manifest names
  (`Pack.writeEmpty`; a donor's atoms are all in store packs). The log
  also records each file that has this build's contents but another path
  or stat than the donor's input (another worktree), so the next build's
  stat check passes. Like any lazy build it does not publish a donor.
  `Replay.donorEager` keeps a donor build eager in three cases:
  - the donor has inputs whose key names no file here (another
    project's files): a log keeps the donor's inputs, and those would stay
    changed inputs in every later build;
  - the donor's debug info names a path this build does not write (a
    worktree built with absolute paths, or another working directory):
    the walk links green functions as recorded, so their paths must be
    this build's. A manifest's path table lists every path its atoms name,
    compile units and inlined callees' files included
    (`Manifest.AtomSymbols.other_files`), so this reads the table, not
    the records (scanning 135 k records' debug info took 31 ms on the zig
    workload); `useDonor` ranks donors that pass right after the builtin
    match;
  - the build has object, archive or shared library inputs, whose paths
    the log would keep.

  Cold-local (empty local cache, a donor of the same program in the
  global cache), ReleaseFast, median of 10, eager → lazy: hello 71 → 14
  ms, zig workload 3710 → 673 ms, a fresh zls worktree 459 → 54 ms,
  vaxis 223 → 130 ms. Each output is byte-identical to a build without the
  cache, and BS_CACHE_VERIFY reports 0 differences. What remains on the
  zig workload is mostly the frontend (584 ms): cold-local empties the
  local cache, which holds the project files' ZIR.
- *Output.* The link order is a function of the atoms (`groupByOwner`), so
  the output is the bytes of a full build with the same error codes. A
  full build without a donor numbers codes by first use, which can differ
  from the donor's: then the error values differ, and so do the names of
  generic instances whose comptime arguments include error set types,
  which list names in code order. Making those canonical is determinism
  rule 5 of parallel Sema (names ordered by name, codes assigned at the
  end).
- *Bounds.* `Store.maintain` counts each donor as its manifest plus the
  linked packs the store no longer has, trims donors by last use (the
  manifest's mtime, renewed at most hourly when used) and age with the
  packs, and deletes `tmp-` directories older than an hour.
  `BS_CACHE_DONOR=off` turns publishing and use off.
- *Why a whole graph, not per-unit lookups.* A unit's result names other
  items by the manifest's item table, so an entry per unit would have to
  carry its items' closure, and a first build would look up and check
  each of thousands of units against the store. A donor is one mapped
  file, red-green is the replay's, and nothing new is serialized.
- *What it cannot reuse.* Knowledge spread over several projects: a build
  replays one donor, so std units that only a third project analyzed are
  analyzed again, and a donor with another builtin module (`bs test`
  after `build-exe`) turns most of std red. Whatever reads codes or other
  build-wide state through a path the graph does not record.
- *What first builds found.* A donor replays a history that a full build
  of this program never had, so it shows recordings that depend on
  analysis order. `BS_CACHE_VERIFY` on first builds found two, both
  fixed in Sema: anonymous types keyed under the generic instance that
  made them first (above), and memo hits that did not refer to the
  functions the memoized call referred to (`Zcu.Memo.funcs`), so only the
  first caller's `func_refs` had them. That also broke lazy edit builds
  without donors ("not linked"). And `builtin.test_functions` is set
  after analysis from the build's tests, so `checkPrediction` exempts it
  like the link node.

Reviewed by the Sema thread (2026-11-03); its answers to the two open
questions (calling back into `Zcu.ensure*`, anonymous types' ordinals) and
its corrections (`comptime_only` in the layout hash, Emit-side references,
the test list) are folded in above.

What the cache must get right, or edit-rebuilds will not be Go-class:

- **Validation cost.** Go re-checks hundreds of packages per build; checking
  tens of thousands of declarations the same way would put a floor of tens of
  milliseconds under every rebuild, which is why edit-rebuilds walk from the
  edit instead. Target: a no-edit rebuild of the libvaxis
  example in under 10 ms beyond process start.
- **Namespace-level dependencies.** Adding or removing a declaration must
  invalidate the units that looked that name up or reflected over the whole
  namespace (`@typeInfo(T).decls`), and no others.
- **Fine-grained dependencies.** Comptime reflection must record exactly what
  it observed: `@hasDecl(root, "x")` depends on whether `root` has `x`, not
  on all of `root`'s declarations; `root.std_options` depends on that value.
  Otherwise adding a function to the root file invalidates much of std.
- **Nothing order-dependent in Atoms.** Values the whole compilation assigns,
  such as error codes in the global error set, are symbolic in Atoms and
  resolved at link time, so one new error name does not invalidate every
  function that returns an error.
- **Inferred error sets** are part of a function's signature but come from
  its body; early cutoff keeps callers green when an edit leaves the set
  unchanged.

The cache makes warm and edit-rebuild builds fast, and makes a new project
fast when its std code is already cached. It does not make a build with an
empty cache fast; that depends on Sema and comptime throughput, parallel
analysis, and the single-pass backend.

Rejected alternative: upstream-style persistence of the whole InternPool and
dependency graph as one mmap-able snapshot per project. It loads faster but
shares nothing across projects and ties the file format to in-memory layout.

## Parallelism

- Frontend: files lower in parallel (see Frontend above).
- The cache records a build alongside the link, on every core (see
  "Integration").
- Linking is parallel within the linker.
- CodeGen runs on a pool behind one Sema thread (step 1 below); step 2
  below, designed, makes Sema parallel too.

### Where a cold build's time goes (measured 2026-11-03)

`BS_TIMING=1` prints wall time per stage. `BS_UNIT_TIMING=n` prints the
n analysis units that took longest, each without the units it analyzed in
turn (timed from `Sema.create` to `Sema.destroy`). CodeGen runs inside
`Zcu.analyzeAll` (Emit times `CodeGen.generate`); "Sema" is the rest of
`analyzeAll`. (The table predates parallel CodeGen: since then "CodeGen"
is the Sema thread's time waiting for and merging the workers' output,
and with `BS_THREADS=1` the same as before.) "Record" is the wait for the cache after the link. ReleaseFast
bs, 4-core orb, page cache warm; "ZIR warm" means std's ZIR was in the
global cache but the compilation's directory was empty.

| Program | Frontend | Sema | CodeGen | Emit | Link | Record | Total in bs |
|---|---|---|---|---|---|---|---|
| hello (std), ZIR warm | 4.8–5.0 | 114–119 | 41–43 | 1.1 | 3.2–3.7 | 10.5–14 | 175–183 ms |
| hello (std), all cold | 173–196 | 150–163 | 45–50 | 1.1–1.2 | 3.5–3.9 | 12–13 | 389–419 ms |
| behavior/floatop.zig (test mode), ZIR warm | 6.6–11 | 74–77 | 9.3–9.5 | 0.4 | 1.1 | 3.1–3.7 | 96–102 ms |
| behavior/floatop.zig, all cold | 179–221 | 104–112 | 8.8–11 | 0.5 | 1.1–1.3 | 3.8–4.7 | 298–351 ms |
| generated, 20k functions, 24.5k atoms (std-free) | 165–203 | 289–316 | 160–179 | 4.6–5.3 | 8.4–12 | 65–79 | 696–753 ms |
| behavior/x86_64/binary.zig, ZIR warm | 33 | 6222 | 3753 | 0.3 | 330–690 | 230–490 | 10.8 s |

- Function bodies are nearly all of Sema. The bodies analyzed from
  `analyzeAll`'s queue loop, including the declarations and the nested
  bodies (inferred error sets) they reach, are 128 of 132 ms of Sema on
  hello (1660 bodies), 76 of 81 on floatop (507), 327 of 352 on the
  generated program (19.6k), and 6.05 of 6.22 s on binary.zig. On
  binary.zig only 545 of its 117k function instances come from the queue;
  the rest are analyzed nested, when a caller needs their inferred error
  set.
- CodeGen is 26–37% of Sema plus CodeGen everywhere but floatop (11%).
- The frontend is the largest cold stage for small programs: std's 560
  files lower in parallel, but they are lowered and written to the cache
  once. On the generated program it is one 20k-function file, which
  AstGen lowers on one thread (165–200 ms), as upstream does.
- For scale: upstream `zig build-exe` takes 383–418 ms for hello with a
  warm global cache, and 1.64–1.73 s for the generated program (6.1 s
  with an empty global cache, which builds compiler_rt).

So the target is Sema's function bodies plus CodeGen: 155 of 180 ms on
hello with ZIR warm, 470 of 720 ms on the generated program, and 10 of 10.8 s
on binary.zig.

### Sema on upstream's compiler (measured 2026-11-03)

bench.py's `zig` workload (upstream's src/main.zig without LLVM) is the
largest program bs builds: 144 k units, of which 80 k are function bodies
(6.9 s of 9.1 s of Sema, `BS_UNIT_TIMING=0`) and 51 k declarations
(2.0 s). One declaration, x86_64 `Lower.zig`'s `mnemonic_table`, took
1.1 s; the next largest units are 0.1–0.2 s (x86_64 CodeGen's 170 k-line
`genBody`, `Encoding.mnemonic_to_encodings_map`, aarch64's instruction
tables, std.meta.stringToEnum's comptime maps for large enums). The rest
is a long tail, so whole-build costs matter more than any unit.

Callgrind over the whole build (ReleaseFast `-Dcpu=x86_64_v3`, against
origin/main 8cb47a5): 78.2 G → 62.8 G instructions (−20%). Wall time
(ReleaseFast native, 3 runs): Sema 9.5–9.8 → 7.3–7.8 s. What changed:

- `InternPool.get` hashed every lookup with the 128-bit stable hash (6.5 G,
  8%); lookups now use `lookupHash` (see "InternPool"), and get fell from
  13.5 G to 6.5 G inclusive.
- `@typeInfo` was 52 k evaluations at 100 k instructions each (5.2 G); it
  is memoized now (see "Comptime").
- `mnemonic_table` (9.5 → 4.5 G for that unit alone): `@hasField` on a
  1500-tag enum compared bytes against every tag (2.2 G), and comptime
  strings were concatenated, sliced and read element by element (3.7 G).
- 64-bit comptime arithmetic and integer bounds no longer go through big
  integers.

libvaxis text_input 1.900 G → 1.770 G instructions (−6.9%); hello 872 M
→ 805 M (−7.7%); behavior/x86_64/binary.zig 72.7 G → 69.6 G (−4.3%,
under valgrind with `--aspace-minaddr`, see bench/README.md).

What remains, by inclusive instructions on the zig workload:

- CodeGen's constant lowering, not Sema: `Emit.uavKey` 10.3 G (16%), and
  `Type.unionLayout` (3.7 G) and `Type.tupleLayout` (2.3 G, through
  `Type.fieldOffset`) called from `CodeGen.lowerValue`, which recompute a
  type's whole layout for each union constant or tuple field. Done: a
  tagged union's layout records its tag and payload offsets in
  `field_offsets`, so `unionLayout` reads them, and `lowerValue`
  accumulates a tuple's offsets in one pass. The zig workload went from
  76.4 G to 61.2 G instructions (−20%), wall time 11.50 → 10.96 s, with
  identical output. `uavKey` is 3.8 G now (27 k constants lowered, about
  140 values each); what remains is spread over `hasRuntimeBits` (0.9 G),
  `abiSize` and key decodes.
- `InternPool.indexToKey` 10 G self (15%): about 270 M decodes, many to
  read one field or the tag of a type. Done in the next round (below).
- Each unit's dependency set (`deps_set`): 1.2 G in its lookups and
  growth.
- Evaluator-shaped work: `mnemonic_table`'s remaining 0.6 s is a 100 k
  iteration comptime loop of `++`, `@tagName` and `@hasField` that the
  walker runs. OSR cannot take it over: in the lowered body the loop
  counter is a run-time value, and `prefix ++ @tagName(tag) ++ suffix`
  needs comptime-known operands because their lengths fix the result's
  type (the outer loop also calls generic `std.mem.findScalar`, which
  lowering refuses). Only an evaluator with value-dependent types could
  run it; see the next round for the walker side. `stringToEnum`'s
  comptime maps are similar.

Next round (against origin/main 990d930, same measures): zig workload
63.39 G → 51.39 G instructions (−18.9%; Sema wall time 7.2–8.8 → 6.1–7.1 s,
noisy), libvaxis 1.781 G → 1.515 G (−14.9%), hello 809 M → 713 M
(−12.0%), binary.zig 69.7 G → 62.6 G (−10.2%). What changed:

- Typed reads (see "InternPool"): about 460 `indexToKey(x).tag` sites and
  every switch that captures no payload now decode only what they read;
  `structInfo` reads the info word alone. `indexToKey` fell from 16% to
  about 3% of the zig workload; the rest is mostly `get`'s equality,
  which now decodes only the matching payload.
- `unwrapIndex`, under every item read, computed its shift and branched
  on the thread count; both are precomputed now.
- `refersToComptimeAlloc` (every argument of every comptime call) caches
  its answer per aggregate value: libvaxis passes uucode's tables again
  and again.
- On the `mnemonic_table` loop (a 1500-tag repro: 530 → 379 M
  instructions): an enum tag's index tries its value as the index before
  scanning the tags, and `@hasField`/`@field` read a constant byte array's
  name without coercing and loading it. What remains is the walker's
  per-operation interning (`InternPool.get` is 40% of the loop).

Interning round (against origin/main 9a99323, same measures): zig
workload 51.61 G → 48.67 G instructions (−5.7%), libvaxis 1.508 G →
1.443 G (−4.3%), hello 707 M → 683 M (−3.4%), binary.zig 64.67 G →
63.22 G (−2.2%), the `mnemonic_table` repro 364 M → 323 M (−11%).
`InternPool.get` fell from 12.4% to below 10% of the zig workload,
inclusive:

- The lookup hash mixes each key field as a word (see "InternPool"); it
  cost about 108 instructions per lookup, mostly in buffering for wyhash.
- Integer keys hit a per-thread direct-mapped cache in `get`.
- Comparisons of a runtime integer with a comptime-known one (`i < n`)
  interned the type's minimum and maximum to rule out the trivial cases;
  64-bit types compare in `i128` now. Coercing a comptime-known integer
  to another integer type, and `intFits`, skip big integers when the
  value fits 64 bits.
- `Sema.stringLiteral` keeps each literal's value (`Zcu.string_literals`);
  the walker evaluated the same literals about a million times, four
  interns each.
- Inside a memoizable comptime call, a repeated dependency declaration
  now stops at a direct-mapped cache, as outside one.

What remains of interning is mostly new pointer values (`ptrElemPtrVal`,
`fieldPtrAt`, `analyzeRef`, `elemPtrType`, `navRef`): about 1 M each on
the zig workload, each a real new or reused value. Beyond that the
walker's cost is spread thin; the next structural step is fewer
intermediate values per operation, not cheaper ones.

Dependency-set round (against origin/main 8990f04, same measures): zig
workload 47.79 G → 46.30 G instructions (−3.1%), libvaxis 1.511 G →
1.473 G (−2.5%); output identical. Declaring dependencies cost 2.9 G
inclusive (about 9% of Sema): 15.6 M declarations, of which 8.5 M stopped
at `dep_cache`, 2.7 M found the dependee already in `deps`, and 3.3 M were
new. What changed:

- Each unit grew its `deps_set` (and each memoizable call its `memo_pos`,
  and `memoDeps` a scratch map) from empty: 366 k rehashing grows, 0.8 G.
  Emptied maps now go back to a pool in the Zcu (`Zcu.dep_maps`, per
  analysis thread once Sema is parallel) and keep their capacity; a map
  grown past 4096 entries is freed instead, since clearing costs its
  capacity.
- `dep_cache` and `memo_dep_cache` have 256 entries instead of 64, which
  halves the declarations that reach `deps` only to find their dependee.
- `InternPool.getString` hashed its bytes twice (once for the shard), and
  its map rehashed every string's bytes on growth. String map entries now
  carry a 32-bit hash, as item entries carry `lookupHash`.

Pointer and name round (against origin/main 40b29a8, same measures): zig
workload 46.50 G → 45.44 G instructions (−2.3%), libvaxis 1.478 G →
1.455 G (−1.6%); output identical. What changed, with each change's
share on the zig workload:

- Comptime loads through a pointer key (−0.46 G). Reading a field or an
  element of a comptime-known aggregate (`a.f` through a pointer, `a[i]`
  through an array or slice pointer, ZIR `elem_ptr_load`) built and
  interned the field or element pointer only to load through it at once.
  `loadField`, `loadElem` and `elemVal` now make its `InternPool.Ptr`
  key, after the same checks `fieldPtr` and `elemPtr` make, and load
  through the key (`comptimeLoadKey`, `mutLoadKey`). A load that would
  need reinterpreting memory falls back to the pointer path, and so
  does anything under the bytecode lowering (`sema.bc`), whose
  dependency and memo records are left as they were.
- `Sema.getString` keeps a 4096-entry direct-mapped cache in the Zcu
  keyed by the address of the bytes and checked against the string
  (−0.24 G): most names come from ZIR, and a unit interns the same few
  over and over.
- `navRef` keeps the pointer it made to a resolved, non-extern
  declaration (`Zcu.nav_ptrs`, −0.29 G). The cache sits after
  `ensureNavVal` and function queueing, so dependencies are unchanged.
- Child blocks take their instruction list from a per-Sema pool and give
  it back emptied (`Block.deinitInsts`, −0.06 G).
- `analyzeRef` keeps the pointer it made to each comptime-known value
  (`Zcu.uav_refs`) and `*const T` for each type (`Zcu.ref_ptr_types`):
  code evaluated again and again references the same values (zig
  workload −0.11 G, −0.24%). `resolveLayoutIfIdle` still runs on every
  reference, so dependencies are unchanged.

All three caches are written and read by Sema only, so CodeGen workers
never see them; once Sema is parallel they become per analysis thread,
as `Zcu.dep_maps` does. What remains of new pointer values is `analyzeRef`
(about 0.9 M calls: ZIR `ref` and `++` operands) and `fieldPtrAt` for
stores and real references (about 0.45 M); after those come
`instantiate`, `foldArithmetic` and aggregate interning.

Measuring note: valgrind runs x87 arithmetic at 64-bit precision, so
binaries a callgrind run emits can differ from native ones in `f80`
constants that comptime computed (compiler_rt's `rem_pio2l`); compare
outputs from native runs.

### Parallel function bodies (designed 2026-11-03; step 1 built 2026-11-03)

Three steps, each useful alone, sharing one hook. Step 1 is built (below);
steps 2 and 3 are designs.

**Step 1: CodeGen on a pool, behind one Sema thread (built).** Sema stays
serial and unchanged. `Zcu.analyzeAll` hands each function's IR, owned, to
`Emit.functionOwned`, which queues it as a job for a pool of CodeGen
workers (`Emit.Pool`), each generating into its own worker Emit: its own
arena, atoms, debug entries, owners, content-atom uses, unit references,
SSA scratch, constant memo, and content-atom set. `BS_THREADS=n` runs
Sema plus n−1 workers (default: one per CPU); `BS_THREADS=1` generates
each function on the Sema thread into the same worker Emit, with the
same merge, which is the serial path for A/B runs. The output is
byte-identical for every n.

- *Order.* Workers take jobs in hand-over order, so each worker's jobs are
  ascending. `Emit.mergeJobs` waits for every job handed over and moves
  each job's output into the main Emit in job order (`mergeOut`), as if
  the function had been generated right after its analysis: atoms with
  their owners (which keeps the manifest's node order as it was), debug
  entries renumbered, content uses, and
  unit references, whose effects (declarations to lower, error names,
  extern slots, the error name table) are applied as `navKey` and friends
  would have. A content-addressed atom is kept unless the main Emit has
  its key already; since the first job to use a constant is the first
  job of its worker to use it, its atom is in that job's output. A
  constant a worker finds in its memo was lowered by an earlier job of the
  same worker, which already made the requests the memo repeats.
- *When it merges.* Before anything else writes to the main Emit: at
  `analyzeAll`'s `sink.sync` when the function queue is empty, before
  `lowerNavs` and at `finish`. Whether jobs are pending is a count, not
  timing, so merges happen at the same points for every n.
- *Loaded units are jobs.* A unit the cache loads (`Replay.loadFunc`'s
  atoms and constants, `Replay.commit`'s requests) writes into the pool's
  last Emit, `loads`, between `Emit.beginLoad` and `endLoad`, which
  queue its output as a job that is done already: workers skip it and the
  merge moves it into the main Emit in job order, as it does a worker's.
  It used to merge first, which in a build that loads and analyzes in
  turn generated nearly every analyzed function on the Sema thread
  (`mergeJobs` runs the jobs not handed over yet): an eager replay of
  another program's donor spent 70–90 ms in that tail, against 1–4 ms
  cold, and lost to a build without the donor. A load with no function
  waiting for CodeGen merges at once, since that merge waits for nothing
  and `loads` then never holds more than one window's atoms.
- *What a worker must not change.* A worker reads the InternPool (items
  are published before the job is queued, and arrays retire rather than
  free), resolved declarations and layouts, ZIR and file paths. What would
  change shared state is logged in its Emit and applied at the merge:
  compiler_rt requests and object imports (`Emit.side`), compile errors
  (`Emit.addError`). compiler_rt requests reach the Zcu only at
  `sink.sync`, so the Sema thread learns of them at the same point
  whatever the timing, and loading a helper's files (which grows
  `Frontend.files`) happens with every worker idle. Exports, which
  CodeGen reads for symbol names and `@extern` targets and which analysis
  keeps adding to, come from a snapshot taken when the job was queued
  (`Emit.exportsSnapshot`: the list and which declarations were resolved,
  copied only when either changed). `Type.isComptimeOnly` caches its
  answer in the type's info; on a worker (`Type.codegen_worker`) it reads
  only final answers and writes nothing.
- *Handing over.* The Sema thread queues jobs in batches of 16
  (`batch_len`) under one lock: waking a worker per function cost about
  as much as the CodeGen it moved (7 ms of hello's 150). A merge runs the
  jobs not handed over yet on the Sema thread, into its own Emit, while
  the workers finish theirs: before loads were jobs, an edit build merged
  after nearly every function it generated (the next loaded unit), and
  waking a worker for each one made vaxis's edit-lib build 118 → 174 ms.
- *Measured* (ReleaseFast bs, this orb: 4 vCPUs on 2 cores, default 3
  workers, against origin/main b30a515 in the same session; bench.py
  medians):

  | Build | before | after |
  |---|---:|---:|
  | hello, cold-local | 234 ms | 186 ms |
  | hello, cold | 483 ms | 429 ms |
  | vaxis, cold-local | 549–561 ms | 485–493 ms |
  | vaxis, cold | 716 ms | 677 ms |
  | zig workload, cold | 13.73 s | 10.89 s |
  | std tests (`bs test lib/std/std.zig --test-no-exec`, cache off) | 8.31 s | 7.22 s |
  | vaxis, edit-root / edit-lib | 111 / 109–112 ms | 104 / 107–114 ms |

  `BS_TIMING`: on hello the Sema thread spends 1.4 ms in CodeGen
  instead of 74 ms; on the zig workload, Sema plus CodeGen goes from
  11.5 s (8.65 + 2.89) to 8.7 s (CodeGen 45 ms). What is left is Sema
  itself, which runs a few percent slower next to busy workers (std:
  7.42 → 7.65 s), since two of the four vCPUs share its core. Peak RSS
  grows by 4–5% (std 601 → 624 MB, zig workload 1232 → 1296 MB): each
  worker keeps its own SSA scratch and constant memo, and IR waits in
  the queue.
- *ReleaseSafe.* std.start gives a ReleaseSafe program SafeAllocator over
  the page allocator, which reuses no memory: every freed bucket and
  large block (a job's IR, CodeGen's scratch) is unmapped, and with
  workers running, each unmap interrupts the other cores to flush their
  TLBs, while page faults and unmaps contend on the address space's
  lock: munmap was a quarter of the samples. `main` therefore gives a
  ReleaseSafe bs SafeAllocator over SmpAllocator, which keeps the
  double-free, mismatch and footer checks but lets freed memory be
  reused; a write after free no longer faults. std's tests
  (`BS_CACHE=off`, 4-core orb, two runs each), ReleaseSafe bs: one
  thread 14.1–14.3 → 10.5 s, four threads 16.9–17.1 → 8.9–9.3 s, system
  time at four threads 10.3–10.4 → 0.9 s, RSS unchanged (761 → 764 MB).
  A ReleaseFast bs compiles the same allocator choice as before: one
  thread 7.75–7.80 vs 7.78–8.26 s, four 6.73–6.83 vs 6.64–7.24 s (noise).
- *Debug.* std.start's SafeAllocator also records a 7-frame stack trace
  per allocation in Debug, which was three quarters of a Debug bs's
  time (a link-input build 5.4 → 1.8 s), and `zig build test` runs a
  Debug bs. `main` gives a Debug bs the same SafeAllocator over the
  page allocator, so a write after free still faults, without the
  traces; `BS_ALLOC_TRACES=<frames>` records them again to find where a
  leaked or doubly freed block came from. Over SmpAllocator, as
  ReleaseSafe, would save another 13% of `zig build test` (174 → 151 s
  after an edit, system time 114 → 64 s) at the cost of that fault.

Step 1 orders output by hand-over, not by the node key sort below: with
one Sema thread, hand-over order is deterministic and keeps the serial
order byte for byte. Step 2, where hand-over order depends on timing,
needs the sort.

**Step 2: Sema of function bodies on a pool (designed 2026-11-03, for
review; no code yet).** Workers analyze function bodies in parallel. Each
body's CodeGen runs right after its Sema, on the same worker, while the
IR is hot in cache. Whatever a body needs (a declaration's value, a
type's field types, layout or defaults, a callee's inferred error set, a
comptime call) is resolved on demand, as today, by the worker that needs
it, through a claim on the unit (below). The coordinating thread keeps
`analyzeAll`'s roots and the serial points. The output, the cache's
records and every diagnostic must be the same for every thread count and
every schedule. The design is in the paragraphs after step 3: units and
claims, the logical stack and dependency loops, determinism, shared
state, replay, the stages, and what stays serial. The expected gains
follow here.

**Step 2, expected gains.** Measured after step 1 (2026-11-03,
ReleaseFast bs, cold, `BS_THREADS=4` on the 4-vCPU orb, with temporary
timers around each `analyzeAll` category). "Bodies" is
`Sema.analyzeFuncBody` together with the
declarations and types resolved from inside it, which is the work step 2
spreads over workers. "Serial" is everything else on the critical path:
the frontend, comptime declarations and roots, compiler_rt resolution,
hand-over, emit, link, and the cache record. "CodeGen" is the workers'
summed CPU time.

| workload | wall | bodies | serial | CodeGen (workers) |
|---|---|---|---|---|
| hello | 166 ms | 143 ms (86%) | 23 ms | 86 ms |
| libvaxis text_input (cold-local) | 458 ms | 268 ms (59%) | 190 ms (frontend 135, record 30) | 102 ms |
| zig workload | 8.85 s | 8.28 s (94%) | 0.57 s | 3.9 s |
| std tests (`--test-no-exec`) | 7.46 s | 7.19 s (96%) | 0.27 s | 1.5 s |

The Sema thread is busy for the whole wall time apart from the frontend,
emit, link and the record, so with step 1 the pool keeps CodeGen off
the critical path, and bodies are the critical path. If step 2 spreads
bodies plus CodeGen perfectly over the effective capacity of this orb
(2 physical cores with SMT, roughly 2.5 workers' worth; CodeGen runs
15–30% slower per IR instruction at 4 threads than at 1), the bound is
serial + (bodies + CodeGen) / 2.5: hello 166 → ~115 ms, libvaxis 458 →
~340 ms, the zig workload 8.85 → ~5.4 s, std 7.46 → ~3.7 s. On 8 real
cores the bound is hello ~50 ms, the zig workload ~2.1 s and std ~1.4 s.
These are upper bounds: waits on units another worker holds, and
contention on the InternPool, lower them.

**Step 3: record each unit as it completes**, on the worker that finished
it (below), so that `record`'s graph and store work overlap analysis and
only numbering and the manifest write remain after the link.

**Step 2, units and claims.** A unit is analyzed once, by whichever
thread claims it first. Its state word is where threads synchronize. The
words already exist as plain enums, and `ensure*` checks them and then
sets them:

| Unit | State today | Claim word in step 2 |
|---|---|---|
| Declaration value | `Nav.status`: unresolved, resolving, resolved, failed | the same field, atomic, in the Nav (per-tid arena, stable address) |
| Field types and layout | `ContainerInfo.status`: none, field_types_wip, have_field_types, layout_wip, have_layout, failed | the same field, atomic, in the ContainerInfo |
| Struct defaults | `ContainerInfo.defaults_status` | the same field, atomic |
| Function body and its inferred error set | `Zcu.funcs`: queued, in_progress, done, failed | a sharded map from function to a state word in per-worker chunked storage, so map growth never moves a word |
| A container's namespace | `createContainerType` checks `si.namespace` and then creates it | a namespace phase in the ContainerInfo, claimed the same way. The ContainerInfo a losing creator made before its lookup is dropped |
| A declaration's nav | `Zcu.declNav` checks the `decls` slot for `.none` and then makes it | CAS on the slot from `.none` to the new NavIndex; a losing creator's nav is left unused |
| A file's root type | `file_root_types` slot, create-once | CAS on the slot. The array grows only at serial points (compiler_rt file loads) |
| `comptime` declarations | `comptime_decls` (only `.queued` is written) and `analyzeAll`'s cursor | unchanged: only the coordinator analyzes them, still through claims for what they reach |

A word holds the phase (today's enum values) and, in a work-in-progress
phase, the claiming worker. To claim, a thread CASes an idle phase to
the matching work-in-progress phase with itself as owner, and analyzes
the unit. It writes the result fields with plain stores, then stores the
final phase with release semantics. A reader acquire-loads the word, so
a done or failed unit costs one load, as now. Three orderings must be
fixed first:
- `setComptimeOnly` writes `comptime_only` after `status = .have_layout`.
- The union analyzer stores `.have_layout` in two places; both must come
  after its last result field.
- `analyzeNavVal` writes `nav.ty` and `nav.alignment` before the value
  resolves, for `navRef`. Prerequisite 1 below removes that partial read.

Two Sema changes come before step 2. Both fix bugs today, and the Sema
thread can land them on their own:
1. *A `nav_ty` unit*, as upstream has. A declaration with a type
   annotation resolves its type without its value, and `navRef` claims
   only that unit. This removes the partial read of a resolving
   declaration (and with it any "type known" bit), and makes legal
   address-of cycles acyclic. A repro that fails today:
   `const S = struct { p: *const anyopaque }; var x: S = .{ .p =
   @ptrCast(&y) }; var y = &x;` with `export fn f() usize { return
   @intFromPtr(&x); }` and `export fn g() usize { return @intFromPtr(&y);
   }`. bs accepts it when f's export comes first and reports
   "dependency loop detected" when g's comes first. Upstream accepts both.
   It also removes a result difference: the partial path drops an
   explicit alignment equal to the natural one, while the full path keeps
   it, so `&x` got a different pointer type inside a cycle.
2. *Function types resolve the field types of by-value parameter types*,
   under a claim, as upstream's `comptimeOnlySema` does. They skip only a
   type that is truly on the logical stack. Today `zirFunc`'s
   function-type path calls `Type.isComptimeOnly` on unresolved parameter
   types, and `Type.comptimeOnly` then reads `info.field_types` at status
   `none` or `field_types_wip`. In parallel that is a data race. It is
   also a bug now: with `const S = struct { t: type }; const F = fn (S)
   void;`, `F == fn (S) void` is false in bs if F was interned before S's
   fields resolved, and true upstream. All of the `comptimeOnly` cycles
   measured below come from this site.

`Type` queries then read only published phases. Stage A adds a checked
build that asserts a ContainerInfo or Nav field is read only after its
phase is published, or while the unit is held on the reader's logical
stack.

A thread that finds a unit in progress on another worker waits on the
word (a futex wait on its value), after registering the wait (below).

**Step 2, inferred error sets.** A caller that needs a callee's resolved
set calls `ensureFuncIes`, which is a unit claim like the others: done,
read the set; queued and unclaimed, claim it and analyze the body on
this worker (today's nested analysis); in progress elsewhere, wait, with
the cycle check. A body that needs its own set while analyzing itself is
the recursion case that is a dependency loop today, and stays one
(reported by the serial rerun below). `ready_irs` goes away. On
binary.zig most bodies are reached this way, so work stealing must not
assume bodies come from the queue: a nested body's CodeGen runs right
after its Sema on the worker that claimed it.

**Step 2, the logical stack and dependency loops.** Today "in progress"
means "on my native stack", and code relies on that in these places:
- `ensure*` returns `error.DependencyLoop`, which `Sema.depLoop` reports
  at the innermost requester. Its error lists the loop's requests from
  `Zcu.dep_stack`, which is per compilation. In parallel it becomes per
  worker; a loop is a hit on the logical stack, reported by the serial
  rerun below, so the report never needs another worker's stack.
- `errorSetNames` turns a `DependencyLoop` from `ensureFuncIes` into its
  own error, "unable to resolve inferred error set" (a failing reader).
- `navRef` reads `nav.ty` of a resolving declaration (gone with
  prerequisite 1).
- `resolveLayoutIfIdle` and `resolveStructFields` skip a layout in
  progress. After such a skip, `noPossibleValue` and
  `isComptimeOnlyResolved` answer from partial state ("taken to have
  values", "the fields known so far").
- `errSetIsEmpty` answers "not empty" on an inferred-error-set loop.
- `Type.comptimeOnly` reads `.computing` as a cycle (`hit_cycle`).
- Replay's `greenNode` accepts a resolving `nav_val` dependency.
- `ensureStructLayout` sets `layout_wip` around `loadLayout`.

Measured on main (ced55dc, ReleaseFast, a counter on every path), on the
zig workload, the std tests, libvaxis and all of behavior: `navRef`
partial reads 0, 0, 0 and 4; `IfIdle` skips, `resolveStructFields`
skips, inferred-error-set loop answers and loop reports 0 everywhere;
`comptimeOnly` cycles 143, 64 and 23 on the first three, every one the
incomplete case at status `none`, from the `zirFunc` site that
prerequisite 2 fixes.

In parallel, a unit in progress may belong to another worker. The rule:
a unit held by worker W is *on my logical stack* if W is me, or if W is
waiting, directly or through other waiting workers, on a unit I hold.
That is exactly when the serial build would have analyzed my current
unit nested inside it. Otherwise, I wait until the unit is done or
failed, which gives me the state the serial build would have found
after analyzing the unit itself. On my logical stack, the outcome
depends on which member of the cycle the schedule entered first, and
skipping changes results: an answer-returning reader answers
differently, an `IfIdle` skip records no `type_layout` edge where a
resolve does, and a partial read can decide success versus a loop. So
every hit on the logical stack (a loop, a failing reader, or a
tolerating one) triggers a serial rerun (below). With the prerequisites
in, the measurements above say that almost never happens.

- *The wait graph.* Each worker has one `waiting_on` slot. Registering a
  wait and walking the chain both happen under one global mutex,
  `wait_lock`. That mutex is only taken when a claim fails because
  another worker holds the unit, so claims and done reads never touch it.
  Under the lock, the waiter reads the unit's owner and follows owner →
  its `waiting_on` → that unit's owner, and so on.
  - Reaching itself: the unit is on its logical stack.
  - Reaching a running worker or a finished unit: it sets `waiting_on`,
    drops the lock, waits, and clears the slot under the lock when it
    wakes.
- *Why the walk is exact.* Every edge of a chain that ends at me is a
  blocked worker waiting on a unit whose holder is blocked in turn, ending
  at a unit I hold. None of them can finish while I hold the lock, so the
  chain cannot dissolve under the walk. Walks are serialized, so of two
  workers closing a cycle exactly one sees it, and the other blocks. A
  deadlock is impossible: a wait that would close a cycle never blocks.
- *Reruns instead of undo.* Nothing can undo a unit inside a build: its
  nav values, interned items, memo entries and the units that read them
  stay. (Replay invalidates against the previous build's graph, in a new
  build.) So where a parallel build's outcome could depend on the
  schedule, it reruns the whole compilation in process, as `main.compile`
  already reruns `compileReplaying` on `LazyFallback`. There are two
  kinds:
  - *Serial reruns.* Any hit on the logical stack (above), or an
    "evaluation exceeded" failure (rule 7). Which unit finds a loop, and
    where, depends on where the cycle was entered, and a tolerating
    reader's answer depends on the same thing. So a parallel build stops
    at the first such event and reruns with one Sema thread. With one
    worker the native stack is the logical stack and the queue order is
    fixed, so that run gives exactly what a `BS_SEMA_THREADS=1` build
    gives, including whether a cycle that a partial read could resolve
    succeeds. A one-thread build never needs this rerun. Discarding the
    parallel run also discards what a unit did before it failed:
    functions it queued, `func_refs` and `referenced_by` entries, which a
    rollback inside the build would otherwise have to undo.
  - *Code reruns.* A unit read a provisional error code at comptime
    (rule 5). The build reruns with the final codes seeded first, at
    every thread count, one thread included.
- *"Resolved yet?" reads.* A separate class: no cycle, just a check of
  whether another unit is done.
  - Some only choose a tier and may stay timing-dependent: the comptime
    body key's `layoutResolved`, `bcRequire`, and the status of
    `c.blocker`.
  - Others change the result and must claim first or be made canonical:
    `ptrCoercibleInPlace` and `peerAlignment` (through `ptrAlignment` and
    `naturalAlignment`, so coercion legality and peer types),
    `optionalPayloadPtr`, the `try_ptr` and packed-union field pointer
    types, `comptimePtrsEqual` and `ptrRootOffset` (which can return
    null, "can't tell"), and `failTypeMismatch`'s uninstantiable note.
- *`Type.comptimeOnly`.* The `.computing` marker moves into a per-worker
  set. Only final answers are written to `ContainerInfo.comptime_only`,
  by a CAS from `.unknown`, and any thread that wins writes the same
  answer. Answers that hit a cycle stay uncached, as today.

**Step 2, determinism.** Raw InternPool indices, namespace indices,
embed-file indices and comptime allocation ids come to depend on timing.
That is allowed only where they reach nothing persisted, ordered or
printed. Stable hashes and unit keys already are what reaches those.
Every record whose order today is discovery order becomes either sorted
by a stable key at a serial point or a function of one unit's own
analysis:

1. *Output.* `groupByOwner` sorts owner groups by their atoms' symbol
   keys (the first atom's, then the next ones'), so `finish` needs no unit
   keys; ties are broken by a hash of the owner. The link's own atoms go
   last. Duplicates are then dropped by key, as now. Data for
   requested declarations is lowered in declaration-key order. Error
   codes are final by then (rule 5), so the error-name table follows from
   them. Callers no longer sit next to their callees; `bench/runtime.py`
   should show nothing in a Debug build, and stage A checks that.
2. *The cache's records.* Node numbering follows the sorted link order
   for atom nodes. After that come the units of `zcu.deps`, then content
   uses, references, roots and inferred-error-set nodes, each sorted by
   key. These follow from the sorted order:
   - per-node edges, which are sorted by node index;
   - references, whose values are node indices;
   - the result item table (`unit_list` and `dependee_list`);
   - pack offsets;
   - symbol numbering;
   - a lazy delta's new nodes, numbered in key order instead of Recorder
     order.

   The manifest and the pack are then byte-identical for every schedule.
   Step 3 later lets pack placement vary, but never references. A lazy
   relink lays out the base's nodes followed by the delta's new ones,
   not a full build's key order. That is fine for the manifest, which
   verification matches by key. If lazy relinks must be byte-identical
   to full builds, `linkInput` can merge the base's key-ordered atom
   nodes with the log's new nodes by key, a cheap merge of two sorted
   lists. Rule 1 lands on its own before the rest, on the cache thread's
   donor branch: loading green units instead of analyzing them changed
   atom order, and with the sort an eager edit build of hello, and a
   donor first build, are byte-identical to a full build.
3. *Dependency records.* `deps`, `conditional_deps`, `func_refs` and
   `effect_uses` become per-worker logs, merged and sorted by unit key.
   A unit's own dependee list keeps the order that unit read them in. That
   order is a function of its analysis, as long as its inputs are. Two
   inputs are not today:
   - *Comptime memo entries.* An entry's conditional flags depend on
     whether the walker or the evaluator computed the call, and shared run
     counts in `comptime_bodies` decide that. In parallel, two workers may
     also compute one call concurrently, and the first insert wins. Plain
     edges already don't depend on the tier, by construction:
     `comptime_dep` covers the reads on the executed path and
     `entry_deps` everything else, and `--edit-verify` checks it, since
     tiers differ between edit and full builds. Conditional edges cannot
     match without lowering every memoizable body, which costs as much as
     analyzing it. They are a safety net only: the evaluator computes
     exactly what the walker would, and every read on the executed path is
     plain, so no result depends on a dependee reached only through a
     conditional edge. The rule: stop persisting conditional edges.
     Stage A drops them, runs `--edit-verify`, and asserts under
     `BS_CACHE_VERIFY` that an executed read is never only conditional.
     Memo entries where the first insert wins then differ only in
     conditional flags, which nothing reads. The lowering trigger may stay
     timing-dependent.
   - *`branch_quotas`* (rule 7).
4. *Anonymous type names.* Names come from ZIR offsets and comptime
   ordinals (`typeName`, `anonTypeNumber`), not counters. A type two
   creators would name differently is named after the least creator by
   key, and a read of a name that then changes redoes the build with
   names pinned: see "Type names" under "Analysis units" (part 1 built
   2026-11-04). The parent namespace no longer depends on creators.
   Parts 2 (the cache) and 3 (link-time names) remain.
5. *Error codes and error sets.*
   - *Codes.* The last build's codes are seeded first (`seedErrors`,
     unchanged). A name with no seeded code gets a provisional code when
     first used. When analysis ends, the final assignment keeps the seeded
     codes and numbers the new names in the global error-name order
     (below).
   - *Comptime reads of codes.* A unit that reads a provisional code at
     comptime (`@intFromError` or `@errorFromInt` folding, `error_value`
     in the evaluator, `anyerror` name reads) marks the build. If any
     final code differs from the provisional one it read, the build makes
     a code rerun (above). Stage A first counts such units on std and the
     zig workload. If the evaluator holds error values as codes, every
     comptime use of an error would count, and reruns would be common:
     that is the risk to measure before relying on this rule.
   - *`.err` references.* They still carry codes (`Ref.value` is the
     code). Edit-verify compares them only because its full-build child
     seeds from the same manifest, and the rule keeps that true. Only
     error set types stop reading codes.
   - *Error-set order.* `errorSetType` sorts a set's names by code, so an
     error set type's key, stable hash, layout and `@typeInfo` order all
     follow code order. Upstream's order is an interning artifact: for
     `const E = error{ Zeta, Alpha, Mid }; const F = error{ Mid, Beta };`,
     upstream's `@typeInfo(…).error_set` gives Alpha Mid Zeta for E and Mid
     Beta for F, and bs today gives Mid Zeta Alpha (code order).
     Conformance does depend on it, though: sorting by name bytes breaks
     behavior's type_info.zig (`error{ One, Two } || error{Three}` must
     list One, Two, Three) and cast.zig's peer-type sets with Three.
   - *The global error-name order.* Before Sema, the frontend scans the
     ZIR of all loaded files in its fixed file order and orders names by
     first textual occurrence, which tracks upstream's interning order.
     Files loaded later (compiler_rt, at serial points) append in key
     order; reified names, which are rare, go last in name order. Error
     set types sort by this order and never read codes, so codes can stay
     seeded or provisional. A change to the order is a real input change:
     it is one input node, the order's hash. This also removes today's
     `--edit-verify` sensitivity of error set types to code order.
   - The lead accepted location-sorted errors (rule 6) and the one-time
     change in codes and link order (2026-11-03, pending the owner's
     approval of stage A). The lead had also accepted name-sorted error
     sets, on the belief that conformance did not depend on the order;
     the global order above replaces that.
   - One worker uses the same rules, so the codes of new names change
     once from today's first-use numbering.
6. *Compile errors.*
   - Each unit appends to its worker's list, tagged with the unit. Notes,
     fixes and candidates attach to a handle the error call returns,
     instead of `errors.items[len - 1]`.
   - The evaluator's rollback (`bcRollback` and `bcFinish` shrinking
     `zcu.errors`) becomes a rollback of the Sema's own list.
   - At the end, errors are sorted by source location: file path, byte
     offset, then message, as upstream's `ErrorMsg.order` sorts
     `failed_analysis`, then unit key (the same failing comptime call
     reached from two callers gives equal location and message with
     different notes, since failed calls are not memoized). The first
     error is the first in that order, and it gets the reference-trace
     frames.
   - Which errors exist does not depend on order: analysis does not stop
     at an error, every referenced unit is analyzed, and loops go through
     the serial rerun.
   - `referenced_by` keeps the smallest referrer by unit key (a CAS-min)
     instead of the first one, so reference traces change once.
7. *Branch quotas.* A generic instance's quota is the largest any
   instantiating caller set, known only when all of them have run
   (upstream has the same order dependence, ziglang/zig#22410). Memo
   hits do not add one: as upstream's memoized calls, a memo entry
   records the branches its computation counted and the largest
   `@setEvalBranchQuota` it ran, and a hit adds the count and raises the
   quota (a hit that would pass the quota runs the call instead, which
   fails at the branch that does). A hit and a miss count the same, so
   which calls another worker memoized first does not change whether a
   unit passes its quota. (This replaces the shadow counter the lead
   decided on 2026-11-03, written when bs's hits charged nothing.)
8. *Exports, tests and compiler_rt requests.* They become locked
   appends, sorted at the end: exports by declaration key, tests by file
   and source position (`populateTestFunctions` already does this), and
   compiler_rt keys at the `sync` point, as today. `isTestFunc` scans
   `test_functions` while it grows. It becomes a flag set when the
   namespace is created, which is before any reference to the function.

**Step 2, shared state.** Survey of origin/main 9c65ff1. Sema has no
globals: no `threadlocal` and no container-level `var` in Sema.zig,
Zcu.zig, InternPool.zig or Type.zig apart from `Type.codegen_worker`.

*InternPool.*

| State | Today | Step 2 |
|---|---|---|
| Item and string storage (`Local` lists) | One writer per tid, lock-free readers (release/acquire `ptr`/`len`); old buffers retired, not freed. Only `.main` writes (`Zcu.tid`, `init(…, 1)`), and two OS threads have never written | Ready. `init` with workers + 1 locals, `Tid` per worker. Add `assert(tid < locals.len)` |
| Dedup maps (`Shard`) | A mutex per shard, taken on every lookup that misses `Local.recent`; inserts encode the item under the lock | Correct now. Contention on hot keys (pointer and integer types) is measured in stage E |
| `Local.int_cache`, `Local.recent` (the direct-mapped intern caches) | A 512-entry and a 1024-entry array per tid, plain reads and writes | Ready: per worker |
| `Local.arena` | Per tid | Ready |
| Stable hashes | Computed when an item is interned; never written after | Ready |
| `errorValue`, `error_names` | `errors_mutex`; numbered by first use | Provisional codes (determinism rule 5) |
| `next_comptime_alloc` | Atomic `fetchAdd` | Ids depend on timing but never leave their unit. `bc_first_alloc`'s "older than this run" test stays exact, because no other unit's id reaches this Sema. Per-worker id blocks avoid sharing the cache line |
| `Nav` and `ContainerInfo` fields | Written in place through the pointers `getNav` and `structInfo` return, by Sema and Replay | Only under the unit's claim, published by the release store of its phase (above). `comptime_only` as above |

*Zcu.*

| State | Kind | Step 2 |
|---|---|---|
| `deps`, `conditional_deps`, `func_refs`, `effect_uses` | order-dependent records | per-worker logs; sorted by key (rule 3) |
| `dep_maps` | scratch pool | per worker |
| `funcs` | unit state | claim words (above) |
| `func_queue`, `next_func` | queue | per-worker deques with stealing; `queueFunc` pushes onto the caller's deque |
| `ready_irs` | queue | removed |
| `comptime_decls` | roots | coordinator only |
| `comptime_memo` | cache | sharded; first insert wins; entries in the inserting worker's arena; path-independent deps (rule 3) |
| `comptime_bodies` | cache with order-dependent run counts | sharded; atomic run counter; lowering claimed by CAS while other threads keep walking (no wait). `Bytecode` is immutable once `.ready` |
| `comptime_osr_off` | cache, insert-only | sharded set |
| `comptime_alloc_refs`, `string_literals`, `string_cache`, `nav_ptrs`, `uav_refs`, `ref_ptr_types` | pure caches (`string_cache` and `nav_ptrs` came with m6-ptr; `nav_ptrs` is written only after the nav's done load) | per worker |
| `inferred_errors`, `anyerror_ies` | unit results | written before the body's done store |
| `namespaces` | list; indices stored in Navs, ContainerInfos, dependees | per-worker chunked lists with the owner in the index, as InternPool does, so `namespacePtr` stays valid. Indices are not persisted (`ns.key` is) |
| `file_root_types` | create-once | CAS on the slot (above) |
| `embed_files` | list; index in `Dependee.embed_file` | locked; the index is valid within one build and persisted by key |
| `exports`, `test_functions`, `rt_helpers`, `errors` | order-dependent records | rules 6 and 8 |
| `referenced_by` | first referrer | CAS-min by key (rule 6) |
| `branch_quotas` | read-max-write | locked; rule 7 |
| `arena` | allocator | per worker |
| `unit_timing` | debug; one nested stack | per worker; summed when printed |
| `fe` | read-only during analysis | `loadFile` only at serial points; `tree`/`source` are already behind `syntax_mutex` |
| `replay` | edit builds | below |
| `Type.codegen_worker` | threadlocal "may not write" | removed: every worker writes final answers only |
| Worker stacks | step 1's pool uses default thread stacks | Sema-sized stacks: nested `ensure` chains (binary.zig's inferred-error-set nesting) plus CodeGen right after a nested body run deep |

**Step 2, replay and lazy edit builds.** Lazy replay (step 4b, the
default) already loads units inside the `ensure*` hooks, which become
claims. A unit is loaded or checked green on the worker that claims it,
and `greenNode`'s recursive `ensure` of each plain edge becomes ordinary
claims. Green checks of independent units then run in parallel.

- *Single-thread state in `Replay`.* Each piece needs its own change:
  - The `deps` stack, with each `Green`'s `deps_start`, becomes per worker.
  - Per-node `state[]` is written under the unit's claim, so it gets a
    release store.
  - The `loaded`, `dead`, `data_refs` and `refresh` bitsets get atomic
    ORs.
  - `visited` is also cleared: when the walk hands a node to analysis it
    clears the node's bit, so a node that turns out green is walked again.
    Either the clear stays on the coordinator while no worker can set that
    bit, or a worker that finishes a handed-over node re-queues the walk
    itself.
  - `dependees`, a per-node cache that `greenNode` fills lazily, needs a
    write-once publish, or is filled when `Replay.create` runs.
  - `unit_nodes`, `input_files`/`file_inputs` and `navs_by_key` are filled
    lazily today. They become concurrent maps, or are filled when
    `Replay.create` runs. `outdated` is fixed after `create`.
  - The decoder's memo becomes one shared write-once map (item id →
    Index, set by CAS). Racing writers store the same Index, since
    interning dedups across tids. Per-worker memos would have every worker
    decode the shared items (std's types, say) again. Its single `miss`
    slot, `keyer`'s buffers and `stats` become per worker.
  - `InternPool.indexOfHash`, which Resolver uses, already takes a mutex
    and indexes every local. Stage E measures its contention.
  - Resolver loads and type creation take the worker's tid and arena.
  - `greenNode`'s `quota` refs raise `branch_quotas` under its lock.
- *The walk.* `startWalk`, `walk` and `settle` stay on the coordinator.
  The walk hands outdated nodes to the pool: `ensure` for declarations
  and layouts, `queueFunc` for bodies. `settle` runs when the pool
  drains, and with it the lazy Emit work (`lowerNavs`, `link_refs`, and
  the `ensureNavVal` that `keepsNavData` calls). `recordDelta` and
  `refreshDebug` append to the pack serially at the end, as now.
- *Eager replay (4a).* `loadFunc` and `commit` write into the pool's
  `loads` Emit as done jobs (`Emit.beginLoad`). In step 2 they
  write into the worker's Emit output with its own owner. The key sort
  at `finish` makes their position irrelevant.
- *Record and verification.* `record` reads frozen Zcu and Emit state
  after analysis, and its inputs are sorted (rule 2), so a schedule
  cannot change the manifest. `--edit-verify` (which matches nodes by
  key) and `BS_CACHE_CHECK` work unchanged. Error set types stop
  depending on code order (rule 5); `.err` refs still carry codes, which
  the verify child seeds from the same manifest.
- *Global first-build reuse* (the cache thread's next step, a donor
  model). Every full record publishes its manifest, whose atoms are all
  in store packs, to the global cache. A build with no manifest picks a
  donor (same store seed and lib dir, ranked by builtin match, then by
  shared inputs) and replays it like an edit build. Its "lookup" is
  `greenNode` against the donor's graph on the claiming worker, which is
  stage D, with no extra store reads. Until D, a donor build analyzes on
  one thread, and a poorly matching donor (a different builtin, say)
  would lose to a parallel cold build. So either D follows C closely, or
  in stage C a build skips its donor when the expected coverage (the
  outdated or seeded share, which the cache exposes) is low.
- *Lazy fallback.* `LazyFallback` reruns the build eagerly on one thread
  today, which took 13–15 s on the zig workload. From stage C, with more
  than one Sema thread, the fallback reruns as a cold parallel build
  (replay mode off).
- *Failed builds committing their manifest* (diagnostics step 6). Errors
  are sorted (rule 6), and failed units are always red, so nothing
  changes for step 2.

**Step 2, stages.** Each stage lands on its own and must meet these
checks:
- the output and the cache's records are byte-identical across
  `BS_THREADS` values and `BS_SCHED_FUZZ` seeds;
- conformance is unchanged with `BS_CACHE_CHECK=1`: behavior with
  `--edit-verify` and with `--default-runner`, and `--std`;
- the ThreadSanitizer build reports nothing with fuzzing on;
- bench.py cold, cold-local and edit numbers before and after.

0. *Prerequisites (Sema).* The `nav_ty` unit (above), on main
   (459e1fe), and function types keyed as upstream's, with genericity
   derived where it is used (above), so making one reads nothing about
   its parameter types and no result depends on the order a cycle is
   entered in. Both done.
A. *Determinism, serially.* Rules 1–8 and the reruns they need, on one
   thread. Rule 1 may land first, alone. Before relying on reruns, count
   on std and the zig workload: units that read provisional codes, and
   types that two creators name differently. Drop conditional edges
   (rule 3).
   - *Creator-independent type names* (item 4), in three parts:
     (1) Sema/Zcu, built 2026-11-04 (see "Type names"). (2) The cache,
     built 2026-11-04: each unit's offers and name reads persist, and
     replay offers the kept units' candidates. (3) Link: atom records
     stop carrying names, and loaded atoms are named from final names
     at link time.
   - `BS_SCHED_FUZZ` gains two Sema modes. One shuffles the function
     queue and the order in which roots are queued. The other eagerly
     resolves random idle units at random points, as another worker
     would. A fuzzed serial build exposes the order dependences that
     parallel analysis would, except interleaving inside a unit, and
     must produce identical bytes. The queue shuffle alone does not
     expose the "resolved yet?" reads; the eager mode does.
   - The checked build asserts published-only reads (above).
   - Serial output changes once: link order, codes of new names, error
     order and reference traces.
B. *Thread identity, still one analysis thread.* `Zcu.tid` becomes a
   per-worker field passed through Sema, Replay and Incremental.
   InternPool gets one local per worker. Caches, arenas, `dep_maps`,
   namespace lists and record logs become per worker. Measure the cost
   of passing the tid (expected: none).
C. *Bodies on the pool, cold builds.* Claim words, the wait graph and
   the logical stack, deques with stealing, and Sema followed by CodeGen
   on one worker. Enabled by `BS_SEMA_THREADS` (default 1). A build with
   a manifest still analyzes on one thread. The fuzzer adds yields and
   sleeps at claims, waits and steals. TSan runs over conformance. Serial
   reruns (loops, quota failures) come with this stage. So does the
   donor-coverage cut-off and the cold fallback above.
D. *Replay.* Replay's state as above. Edit builds and lazy loads use the
   pool.
E. *Default on and tuning.* Shard-lock contention and per-worker lookup
   caches, stealing granularity, memory (per-worker arenas and duplicated
   cache entries). Then step 3.

**Step 2, costs to watch.** On the zig workload:
- *Claims.* A done unit costs one acquire load, as now. A claim is one
  CAS per analyzed unit, about 144 k in total.
- *Waits.* They happen only on contention, and two workers may
  duplicate a comptime call, which costs time, not correctness.
- *Shard locks.* Every intern takes one. With one shard today it is
  uncontended; the stage E measurements show whether hot keys need
  per-worker caches.
- *Sorting.* Owner groups, dependency logs and errors take a few
  milliseconds at the end.
- *Memory.* Per-worker arenas, caches and namespace chunks grow peak
  RSS. Step 1 added 4–5%, and step 2 should add about as much again.

**Open questions for review.**
Answered in review (2026-11-03):
1. Walker and evaluator dependencies: plain edges already match;
   conditional edges stop being persisted (rule 3).
2. Two creators, one key: yes, as upstream; CAS-min name with recorded
   reads (rule 4).
3. Error-set order: conformance depends on it; the global error-name
   order (rule 5).
4. (Cache) Key-ordered numbering is acceptable, and donor reuse goes
   through `greenNode`. The cache review also replaced in-build
   re-analysis with whole reruns, added Replay's `dependees`, `visited`
   clears and a shared decoder memo, and set the lazy fallback for
   stage C.
5. More "on my stack" readers: `errorSetNames`, `errSetIsEmpty`, and the
   partial answers after an `IfIdle` skip; and skipping does change
   results, so every hit on the logical stack reruns serially. The
   "resolved yet?" reads are classified above.

6. Branch quotas and memo hits: a hit charges the branches its entry
   recorded, as a miss counts them (rule 7).

**The completion hook, and recording as units complete.** When a unit's
result is final (a declaration resolved, a layout resolved, a `comptime`
block done, a function body analyzed and generated), its worker calls
`sink.unitDone(zcu, unit)`. Step 3 records the unit there, on that
worker:
- its node key, `src_hash`, and result hash (InternPool stable hashes,
  or its atoms' contents once CodeGen has run);
- its dependency edges as keys with their result hashes, all final
  because a unit completes only after everything it read did;
- its store lookup, and on a miss its entry, encoded into the build's new
  pack at an offset taken from an atomic counter.

At the end, `record` only sorts the recorded nodes into the canonical
order, numbers the symbols, writes the manifest alongside the link, and
places it after a successful link. On the generated program that moves
the graph (39–47 ms) and the store lookups off the critical path, leaving
the manifest (30–37 ms, itself parallelizable). Placement in the pack then
depends on timing, so pack bytes differ between runs while every
reference stays correct. The same hook is where an edit build loads a
skipped unit's cached result (see "Edit builds").

**What stays serial.** AstGen of a single file. The roots
(`analyzeAll`'s comptime declarations, exports and tests) are walked on
the coordinator, cheaply, though what they reach is claimed like
anything else. compiler_rt resolution and the file loads it causes
happen when the pool drains. Also serial: `finish`'s data lowering (5 ms
on the generated program), emit, the link, and today's `record`.
Reruns (loops, quota failures, provisional codes) repeat the whole
compilation rather than a serial tail.

**Checking it.** `BS_THREADS=1` runs everything inline (built for step
1, where it means CodeGen on the Sema thread). The output
binary and the manifest's atom order must be byte-identical across thread
counts and runs, and conformance must not change. A debug option that
shuffles the work queue and adds random yields at claim points exposes
order dependence, and ThreadSanitizer builds of bs check the shared
state. Built for step 1:

- `BS_SCHED_FUZZ=<seed>` (`Emit.Pool.fuzz`): random sleeps (up to 0.5
  ms) and yields where workers take jobs and after the Sema thread hands
  one over, a random batch length (1–32), and merges that randomly wait
  for workers instead of generating the jobs not handed over yet. Which
  worker generates which job varies; each worker's jobs stay ascending,
  which `mergeOut`'s deduplication relies on, so step 1 does not shuffle
  the queue itself.
- `BS_SCHED_FUZZ=late` (`Emit.Pool.late`, 2026-11-05): no job is
  handed over until analysis waits for CodeGen (`mergeJobs`), where the
  Sema thread runs them, so CodeGen sees everything analysis resolved
  meanwhile; `BS_THREADS=1` generates each function as soon as it is
  analyzed and sees the least. Sleeps cannot reach that far: the
  test runner's `mainServer` stored into a global whose value
  `ptrRoot` read before the Sema thread had resolved it, 70 bytes
  longer than when it had, which only load showed (a `BS_CACHE_VERIFY`
  difference in about one behavior unit in a hundred). run.py's
  `--sched-check` builds every unit both ways with the cache off and
  requires the same bytes; it names the symbols whose size differs.
- `BS_SCHED_FUZZ=sema:<seed>` (`Zcu.sched_rng`, 2026-11-05): the queue
  shuffle of step 2's stage A. `Zcu.analyzeAll` keeps its work in
  `Queues`, one queue per kind (comptime declarations, exports, tests,
  declarations, deferred defaults, runtime units, ready IRs, functions),
  and each step takes one item from the first kind that has work. With a
  seed, the root files are queued in random order, the kinds are tried
  in a new random order every step, and the declaration, defaults,
  ready-IR and function queues hand out a random item instead of the
  oldest. Comptime declarations, exports and tests keep source order
  (the last export of a name wins; `comptime` blocks' effects are
  ordered). Without a seed the order is the one before. `--sched-check`
  builds every unit a third way with it (seed `--sched-seed` plus the
  unit name's CRC-32), and a fourth with `BS_COMPTIME_EVAL=1`, where the
  evaluator runs every comptime call the walker ran in the other three.
  Each of its four builds is a full build on one thread checked node by
  node against the unit's last build (`BS_CACHE_VERIFY=full`), so the
  cache's dependencies, references and atom records must not depend on
  the order or the tier either, and the four binaries must be identical.
  With `--std` or `--c-abi`, `--sched-check` builds the suite again with
  `BS_COMPTIME_EVAL=0`, `=1` and `=0` instead (the tier swap), checked
  the same way; since `BS_CACHE_VERIFY` only flags what the previous
  build's manifest lacks, the swap runs both ways. `just sched-check`
  runs both. The check needs the cache on: error codes
  are numbered as names are first used (rule 5's global order is not
  built), so with the cache off a shuffled build numbers them
  differently (behavior's fn_delegation.zig: two entries of the error
  name table swap), while `BS_CACHE_VERIFY=full` seeds them from the
  last build as edit builds do. aarch64-macos does not use the cache
  yet (`Job.cacheable`), so there `--sched-check` drops the shuffle
  for four threads with random delays (`BS_SCHED_FUZZ=<seed>`) and
  compares binaries only, as std's tier swap there does (baseline
  `std-aarch64-macos.json`); `--edit-verify` checks nothing beyond the
  builds and their tests. aarch64-linux uses the cache, so its checks
  are x86_64-linux's. The eager-resolve mode stays planned.
- `zig build -Dsanitize-thread -Doptimize=ReleaseFast`: a
  ThreadSanitizer build of bs, linked with libc so that the allocator is
  malloc, which ThreadSanitizer intercepts. (std's SafeAllocator, the
  ReleaseSafe default, hands freed memory to other threads in ways it
  cannot see: a ReleaseSafe build reported about 460 false races on
  libvaxis, every one a new allocation reusing memory another thread
  freed.)
- Results (2026-11-03, origin/main 40b29a8 plus these options): the
  ThreadSanitizer build with `BS_THREADS=4` and `BS_SCHED_FUZZ`
  reported no race on hello, libvaxis text_input, the zig workload, std's
  tests (3351/3351), and behavior with `--edit-verify` and
  `BS_CACHE_CHECK=1` (2067/2067 in 112 files). The x86_64 file's
  edit-verify run needs about 8.1 GB under ThreadSanitizer (the edit
  build and its `BS_CACHE_VERIFY=full` child together; 7.65 GB for the
  larger), so it ran on a 31 GB orb against origin/main 9c65ff1: 103/103,
  no race, no edit-verify difference. With a ReleaseFast bs, all
  113 behavior test binaries and the four workloads' outputs are
  byte-identical between `BS_THREADS=1` and `BS_THREADS=4` with
  `BS_SCHED_FUZZ` (several seeds).
- For step 2 (see its stages): `BS_SCHED_FUZZ` also shuffles Sema's
  function queue and root order (stage A, serially), then yields and
  sleeps at claims, waits and steals (stage C). Every stage compares the
  output and the cache's records across thread counts and seeds.

## The command line and `bs build` (built 2026-11-03)

- bs is a drop-in for `zig build-exe`, `build-obj`, `build-lib`, `run`,
  `test` and `build`, and for the two commands build steps and tools run
  on the compiler: `fmt` (`b.addFmt`; upstream's src/fmt.zig, copied) and
  `env` (zls's tests read the lib directory from it). `main.parseOptions` sorts every option upstream accepts, and
  every one upstream's build runner passes, into four classes:
  implemented (`-M`/`--dep`, `--name`, `-femit-bin`, `--cache-dir`,
  `-fsingle-threaded`, `-freference-trace`, `--listen=-`, ...); ignored,
  because it changes nothing bs does (link layout, C-only settings,
  settings bs always has: `-static`, `-fno-PIE`, ...);
  unsupported, which makes the compile fail with an `[unsupported]`
  diagnostic naming the option and the way out; and unknown, also
  `[unsupported]`. Response files (`@file`, which the runner writes for
  long command lines) are expanded where an option is expected.
- **ReleaseSafe.** `-O` (`-ODebug`, `-OReleaseSafe`, `-Osafe`, `-O safe`,
  ...), `-ferror-tracing` and `-fvalgrind` with their `-fno-` forms are
  per module, as upstream's: each `-M` takes those given since the last
  one, a module without its own takes them from the module that first
  depends on it (`main.inheritFlags`), and std, builtin and the test
  runner take the root module's. ReleaseSafe compiles with bs's one code
  generation, safety checks included; it changes what upstream's
  ReleaseSafe changes in meaning: `builtin.mode == .safe`, and error
  tracing and Valgrind client requests off unless asked for. A module
  whose three settings differ from the root module's gets a builtin of its
  own, `=builtin@<dir>` (`Frontend.ModuleArg.builtin_dir`), as upstream
  gives each set of module options one. Error tracing changes IR with no
  dependency recording it, so it salts the store seed (`cacheTarget`:
  `=notrace`, and `=<module>:<mode><t|n><v|n>` for each module with a
  builtin of its own).
  C sources of a ReleaseSafe module get upstream's flags for the mode
  (`-O2`, `-D_FORTIFY_SOURCE=2`, `-Werror=date-time`, UBSan in trap mode;
  `CSource.Flags.optimize`), taken like the other C module options from
  the module or else the root module.
- **ReleaseFast and ReleaseSmall** are `[unsupported]` on the command
  line, and accepted in `bs build`'s steps (`--listen=-`), whose build
  scripts may ask for them (supermd builds its translate-c tool
  ReleaseFast). They compile with the same code generation, with
  `builtin.mode` `.fast` or `.small`, error tracing and Valgrind off, and
  no safety checks in the module's functions (`Frontend.Module.safety`;
  `@setRuntimeSafety(true)` still adds them) and no hidden safety tag in
  the untagged unions it declares, as upstream's. That changes
  IR with no dependency recording it, so a root module without them
  salts the store seed with `=nosafety`. Their C sources get `-DNDEBUG`,
  `-O2` or `-Os`, and no UBSan, as upstream's.
- **Backend flags.** bs generates the same code in Debug and ReleaseSafe,
  where upstream's choice of backend changes nothing a program means. So `-fllvm`, `-flld` and their
  `-fno-` forms are accepted without a word and bs compiles with its own
  backend and linker. `builtin.zig_backend` is upstream's Debug default for
  the target, whatever the flags say: `.stage2_x86_64` on x86_64-linux,
  `.stage2_llvm` on aarch64-macos. Example: uucode's `build.zig` builds its
  Unicode table generator with `.use_llvm = true` in Debug; under `bs
  build` that step compiles with bs, and libvaxis needs no `-Dllvm=false`.
  The same rule covers `-fPIE` and `-fPIC` on executables (linuxwave's
  `.pie = true`): bs links them static and non-PIE, which changes no
  program meaning, only address randomization, and
  `builtin.position_independent_code`/`_executable` stay false (true would
  make std's start code relocate a binary that has no relocations). On
  `build-obj` and `build-lib` they produce position-independent code, as
  upstream (see "Position-independent code and shared libraries").
  `-fomit-frame-pointer` (fastmem's modules ask for it) is accepted and
  bs keeps frame pointers, as it always does: omitting them frees a
  register and changes no result. `builtin.omit_frame_pointer` stays
  false, which describes the code (std's stack iterator may then walk
  the frames, which are there).
  `-funwind-tables`,
  `-fasync-unwind-tables` and `-fno-unwind-tables` set
  `builtin.unwind_tables` as upstream does (ghostty asks for `.sync`);
  bs emits asynchronous tables for each, which serve every request.
  ReleaseFast and ReleaseSmall, C, C++ and assembly sources,
  and system libraries stay `[unsupported]`; `-lc` links glibc and `bs
  translate-c` translates headers (see "C interop"). bs never hands a step to upstream zig.
- **`bs build`** (`src/BuildRunner.zig`) does what upstream's `zig build`
  does, with bs as the compiler. It compiles upstream's build runner,
  `<zig lib>/compiler/Maker.zig`, with bs in ReleaseSafe as upstream
  does, into `<global cache>/bs/o/<hash>/maker`, the hash taken from
  bs's identity (`Incremental.compilationKey`'s store seed), the zig lib
  directory and the mode. ReleaseSafe is bs's one code generation, but
  std takes its ReleaseSafe paths: the runner's `SafeAllocator` captures
  no stack trace per allocation (in Debug, DWARF unwinding on every
  allocation was the largest item of a no-change build's runner time),
  no error return traces, and upstream's `.info` log level. The compile runs from that directory so
  its key, which includes the working directory, is the same for every
  project, and a build that changed nothing reuses it without relinking.
  bs then replaces itself with `maker build --zig-lib=<lib> --zig=<bs>
  --global-cache=<global> --seed=<random> <user args>`. The runner
  compiles `build.zig` (with `configurer.zig`) and every compile step by
  running bs with `--listen=-`.
- **The compiler protocol** (`main.serve`, std's `std.zig.Server`): bs
  sends `zig_version` and the step's `config` (static, no libc), then
  answers each `update` with `file_system_inputs` (every file the build
  read, as `PathPrefix` + sub path relative to the zig lib dir, local or
  global cache, build root or working directory), then either
  `emit_digest` (with `cache_hit` when nothing was compiled) and an empty
  error bundle, or the errors as an error bundle. The output is
  `<local cache>/o/<digest>/<name>`, where the runner looks for it; the
  digest is `Incremental.outputDigest`, a salted hash of the compilation's
  key without `--listen=-`. It does not change with edits, so an edited
  build relinks in place, and when the output's stat is unchanged
  (`Incremental.noteOutput`) a no-change build does not touch it, so the
  runner's InstallArtifact sees nothing to copy. The output directory
  belongs to the compilation's cache directory, which can recompute its
  digest: trimming the compilation is to delete it too (cache owner, not
  built yet; nothing scans `o/`, which upstream's outputs share).
  bs also creates `<local cache>/tmp`, which upstream's compiler creates
  and the runner writes into.
- **Inputs under the default lib directory are not reported.** Of the
  `file_system_inputs`, files of the default lib directory (upstream zig
  0.17.1's) are left out (`main.prefixInputs`); they are
  about 700 of a configure script's 720 (std and std.Build). The runner
  records the configure script's inputs in its configuration cache
  manifest: it stats them on every build, and when the build script
  cannot be cached (it runs a process, such as ziggy's `git describe` or
  monstar's pkg-config) it hashes every one of them again on every build.
  It also records each compile step's inputs for `--watch`. Nobody edits
  the default lib directory, so the runner gains nothing from them: with
  them, the runner's own time in a no-change `bs build` of ziggy was
  58 ms, without them 8 ms (bench/README.md). This is the
  trust the runner's stamp already places in that directory (an edit
  there needs `--zig-lib`, ZIG_LIB_DIR, or a cleared cache to be seen);
  with another lib directory, every input is reported, as upstream does.
- **Errors over the protocol** travel as std's `ErrorBundle`, built by
  `diag.toBundle` from bs's diagnostic records, and the runner renders
  them in upstream's format: the message is prefixed with the code
  (`[type-mismatch] ...`), notes keep their source lines, call frames are
  notes worded as upstream's ("called inline here"), and the reference
  trace keeps upstream's limit (`-freference-trace=n`, else two frames for
  the first error that has a trace) and its hidden-frame count. A step bs
  cannot build answers every update with one `[unsupported]` error, so the
  runner reports it as that step's failure and builds the rest; commands
  bs does not implement (`cc`, `test-obj`, ...) are
  served the same way. Without `--listen=-`, bs renders with its own
  renderer (`--error-format`).
- **Libraries and docs.** `build-lib` (static, upstream's default) writes
  a GNU ar archive of the library's object with a `/SYM64/` index of its
  defined globals, as upstream does (`src/link/Archive.zig`); `-dynamic`
  writes a shared object (see "Position-independent code and shared
  libraries"). `-femit-docs` writes upstream's autodocs directory
  (`src/Docs.zig`; `<name>-docs` next to the output under `--listen=-`,
  `docs/` otherwise): `index.html` and `main.js` from the zig lib
  directory, `sources.tar` with the .zig files of the module graph (byte
  for byte upstream's), and the viewer `main.wasm`. The viewer is
  lib/docs/wasm compiled for wasm32 in ReleaseSmall, the same for every
  project, and bs has no wasm backend: bs's `build.zig` compiles it once
  with the upstream zig that builds bs, from that zig's lib directory,
  and bs embeds it (identical to upstream's). A build with
  another `--zig-lib-dir` takes the html and js from that directory and
  keeps the embedded viewer. zig-clap needs it: its test compile emits
  docs (`getEmittedDocs`) for every step.
- **`--watch`** is upstream's runner keeping each compile step's bs alive
  and sending an `update` per rebuild; each update compiles as a CLI build
  does, through the on-disk cache. There is no in-memory session (owner's
  decision, 2026-11-03): replay's lazy edit builds are as fast one-shot as
  upstream's in-process session. `zig build --watch` panics on Linux older
  than 6.5 (bench/README.md), for the runner bs builds too, so it is not
  tested on the orbs.
- Measured (2026-11-03, orb, bs ReleaseFast, bench.py vaxis `zig-build`,
  details in bench/README.md): first build of a project with the runner
  cached 2.37 s (upstream 6.51 s), edit 139–144 ms (1.19–1.20 s), no edit
  38 ms (24 ms: the Debug runner is slower than upstream's ReleaseSafe
  one); the build.zig compile 0.69 s first, 1.7 ms unchanged, 0.21 s
  after an edit (upstream 1.2 s, 6.7 ms, 1.2 s). Compiling the runner is
  once per bs binary, about 3 s (upstream: once per global cache, 75 s
  with LLVM). bs's own repository builds with `bs build`, and
  `bs build test` passes the same 169 steps and 47 of 48 unit tests (1
  skipped) as `zig build test`; its oracle steps find upstream zig on
  PATH when the build's compiler is not a zig release.

### Finding the zig lib directory at run time (built 2026-11-05)

A released bs (`just release-build`, shipped by the org's release
workflow) runs where its build tree is not, so the lib directory it
compiles against (std, compiler_rt, the build runner, translate-c,
libc's and libc++'s sources) is found when it runs (`src/toolchain.zig`):

- `--zig-lib-dir` (`--zig-lib=` for `bs build`), else `ZIG_LIB_DIR`,
  else the lib directory of upstream zig: `BS_ZIG`, else `zig` on PATH,
  else `~/.cache/bs/zig-<host>-0.17.1/zig` (`toolchain.findZig`, which
  C compiles use too). That zig must report 0.17.1 (`zig version`), and
  `zig env`, run without ZIG_LIB_DIR, names its lib directory, which
  copes with every install layout (release tarball, Homebrew, mise, Nix).
  The answer is kept in `<global cache>/bs/zig/<hash>`, keyed by the
  binary's real path, inode, size, mtime and ctime, so a build reads one
  small file instead of running zig twice (about 5 ms).
- Only then the lib directory bs was built with
  (`build_options.zig_lib_dir`), if it is still there: a development
  build keeps working with no zig, or another version, on PATH.
- Otherwise bs exits with one error that says it needs upstream zig
  0.17.1, what it found (no zig, and where it looked; or the version of
  the one it found), and the fix.
- The default lib directory is the trusted one (`toolchain.LibDir`):
  `Incremental.trusted_lib`, the build runner's stamp, translate-c's
  binary, and `main.prefixInputs` skip its files. A lib directory given
  explicitly is trusted when it resolves to the default, as under
  `bs build`, which passes the default to the runner and every step.

Nothing else in a bs binary depends on where it was built: C and C++
compiles find upstream zig as above, and the docs viewer and build web
UI wasm are embedded.

## Fuzzing (designed and built 2026-11-03; x86_64-linux)

Goal: upstream 0.17.1's built-in fuzzer works with bs on x86_64-linux:
`-ffuzz`, `std.testing.fuzz`, and `zig build test --fuzz` under `bs
build`. Agents fuzz to find a crash, then minimize and fix it.

**How upstream does it.** `zig build test --fuzz[=n]` runs the tests
once, learns which call `std.testing.fuzz`, rebuilds those test binaries
with `-ffuzz`, and runs them with `--listen=-`; the test runner hands
each fuzz test to the fuzzer (`std.Build.abi.fuzz`), which mutates
inputs and keeps the ones that reach new code. Only the LLVM backend
instruments (`codegen/llvm/FuncGen.zig`, `.poi`): per function, an array
of 8-bit counters in section `__sancov_cntrs`, bumped at the function's
entry and at both arms of most branches, and a parallel array of the
points' addresses in `__sancov_pcs1`. The fuzzer finds both arrays
through the linker's `__start_`/`__stop_` symbols, resets the counters
before each run, and reads them as hit or not hit. `lib/fuzzer.zig` is a
separate compilation (a static library, ReleaseFast, uninstrumented, with
its own root, `std_options`, and copy of std), so its own work never
shows as coverage. Upstream's self-hosted x86_64 backend, its Linux Debug
default, does not instrument: `--fuzz` there fails with "pcs_len was
zero". Measured (orb, `zig build test --fuzz=30M -Dllvm`, fresh cache):
upstream's LLVM build finds a planted out-of-bounds write behind a
`key=bs!` prefix after 6.7 M runs, about 20 s.

**bs's design.**

- **Command line.** `-ffuzz` and `-fno-fuzz` are per module, as
  upstream's: each `-M` takes the last one before it, and a root file
  given by position the last one left. A module without either takes the
  flag of the module that first depends on it, depth first from the main
  module (upstream's `Module.create` parent); std, builtin and the test
  runner take the main module's. CodeGen instruments the functions of
  modules with the flag (never compiler_rt or the fuzzer's family). If
  any module has it, a test links the fuzzer. A non-test executable is
  instrumented but links no fuzzer, as upstream's default backend builds
  one (its ELF linker leaves libfuzzer.a out; upstream's LLVM build pulls
  it in for `__sancov_lowest_stack`, which LLVM's stack-depth
  instrumentation names, and then fails on the
  `runner_*` callbacks only the test runner defines). One difference:
  bs has one `builtin` per family, so `builtin.fuzz` is the main
  module's in every module, where upstream gives each module its own.
  `zig build --fuzz` passes `-ffuzz` ahead of the root module and a
  module's `.fuzz` ahead of its `-M`. `-ffuzz` on `build-obj` and
  `build-lib`, and for aarch64-macos, is `[unsupported]` for now.
- **The fuzzer is a module family, not a second compilation.** bs
  compiles `<zig lib>/fuzzer.zig` in the same compilation as the program,
  but as its own *module family*: the root `=root@fuzzer` (fuzzer.zig), its
  own `=std@fuzzer` (std's files again) and `=builtin@fuzzer` (output mode
  `Lib`, `is_test` and `fuzz` false, ReleaseFast without error tracing
  or valgrind, as upstream builds it with `compilerRtOptMode`). Every
  module names the modules that
  `@import("std")`, `@import("root")` and `@import("builtin")` resolve to
  (`Frontend.Module.std_mod`, `root_mod`, `builtin_mod`; the main ones
  for every module but the fuzzer's). So fuzzer.zig gets what upstream's
  separate compilation gives it: its `std_options` (its log goes to its
  own file), its panic handler, `std.lang` types of its own std, and std
  code that is not instrumented. As in compiler_rt, Sema adds no safety
  checks to the family's functions (`@setRuntimeSafety(true)` still adds
  them) and pushes no error return traces there. Sema reads the family wherever it names
  std, root or builtin itself: imports, `@embedFile` of a module name,
  `std.lang` lookups (`stdLangDecl`), the panic handler's namespace, and
  the `@typeInfo` memo key (each family's `std.lang.Type` differs).
  Exports and externs still meet by name across families, as with
  compiler_rt: the test runner's `extern fn fuzzer_init` resolves to
  fuzzer.zig's `export fn`, and fuzzer.zig's `extern fn runner_test_run`
  to the test runner's. Unit keys stay unique because module names do:
  the family's names hold an '=', which no `-M` name can.
  Why not a separate compilation linked in: bs's linker does not read
  objects, and a second Zcu would need its own cache manifest, relink
  path, error numbering and symbol-key salt. As a family, the fuzzer gets
  the per-declaration cache, parallel CodeGen, edit builds and debug info
  for free; the cost is analyzing the std code fuzzer.zig reaches a
  second time, once per project (it is cached like any other unit).
- **Coverage points**, upstream's set. Sema marks the arms of the
  branches the user wrote (`Ir.CondBr.cover`, upstream's
  `then_cov`/`else_cov`): both arms of a ZIR `condbr` (`if`, `while`,
  `orelse`, `catch`), of `and`/`or`, and of the error check of
  `catch |e| switch`, and the error arm of `try`. Branches Sema adds
  itself (safety checks, error-trace bookkeeping, `select`, switches
  lowered as chains, vector loops) and switch cases get none, as
  upstream's. The shared SSA layer turns the marks into points
  (`Ssa.place` with `cover`), so aarch64 reuses them: the function's
  entry, and each marked arm that is not cold. A cold arm (a call of a
  noreturn function, such as `@panic`) ends the run, so its counter
  would tell the fuzzer nothing. A covered block is never bypassed by
  pass 3 (an empty arm keeps a block of its own). Not
  instrumented: compiler_rt, the fuzzer's family, naked functions, and
  functions that call `@disableInstrumentation()` (the test runner's,
  `std.testing.Smith`'s helpers), which Sema records on the IR
  (`Ir.disable_instrumentation`, never persisted, like the IR).
- **Counters.** Each point is `mov byte [rip + counters + i], 1` (7
  bytes) at the start of its block: it sets the counter rather than
  adding to it, which is all the fuzzer reads (zero or not), cannot wrap
  to zero after 256 hits as an 8-bit add does, needs no load, and touches
  no register and no flag, so it goes anywhere without the allocator's
  knowledge. On aarch64 it will be `adrp`/`strb` with a scratch register.
- **Atoms.** An instrumented function's unit gets two more atoms, keyed
  from its function key: the counters (section `sancov_cntrs`, zero-fill,
  alignment 1, one byte per point) and the PC table (section
  `sancov_pcs`, alignment 8, one `x86_64_abs64` relocation per point to
  the function at the point's offset; the entry's is offset 0, the
  function's address, as upstream's, which the build runner matches to a
  test's entry). Offsets are taken after branch shortening. Both have
  empty names. Because the linker keeps atoms in input order within a
  section and the two atoms are added together, the two arrays line up
  index for index, as the fuzzer requires; their sizes (n and 8n bytes)
  need no padding between atoms.
- **Format changes** (append-only): `Atom.Section` gains `sancov_cntrs`
  and `sancov_pcs` (the cache stores the section as a byte and checks it
  with `std.enums.fromInt`; `Elf.Place.section` has 4 bits, for
  these eight and `.data.rel.ro`, taken from the 38-bit offset). The ELF linker places `__sancov_pcs1` after `.rodata`
  in the R segment and `__sancov_cntrs` (NOBITS) after `.bss`, and
  writes their section headers only when they are not empty, so a build
  without `-ffuzz` links exactly as before. It defines the four
  boundary symbols as link-time addresses (`Atom.SymbolKey.sectionBound`),
  which the extern slots of `@extern("__start___sancov_cntrs")` and the
  others name; the cached relink passes their symbol numbers
  (`Elf.Symbols.bounds`). Objects do not get the sections yet.
- **Cache.** Instrumented atoms differ from plain ones, so the store
  seed and the compilation key include the flag (the target string gets
  `+fuzz`). No node key holds a module's flag, so the target string also
  names each module whose effective flag differs from the main module's
  (`+lib`, `-lib`, `-root`): builds with different sets of fuzzing
  modules share no store entries and never donate to each other. The
  donor key hashes the store seed, so fuzz and plain builds
  never donate to each other. The fuzzer's `=std@fuzzer` files have the
  same paths as `std`'s; the replay tells them apart because it matches
  inputs by key (`<module>:<path>`), so an edit of a std file outdates
  both copies.
- **Cost when off**: one flag test per function in CodeGen and per
  `place`, and the linker's per-section arrays grow from 6 to 8 entries;
  no extra atoms, sections, analysis or format bytes.
- **`bs build`.** The runner's fuzz rebuild passes `-ffuzz` and bs
  builds it; the test binary runs as upstream's does. `--fuzz` without a
  limit also serves upstream's web UI, whose wasm client (lib/build-web)
  the runner compiles with the build's compiler for wasm32
  (`buildClientWasm`), which bs does not target. As with the docs
  viewer, bs's build compiles the client with upstream zig
  (ReleaseFast, stripped: 0.4 MB) and embeds it; bs answers that one
  command (`build-exe -target wasm32-freestanding --name build-web`
  with root `build-web/main.zig`, over `--listen=-`) by writing it to
  `<cache dir>/o/<digest>/build-web.wasm` (src/BuildWeb.zig). With
  another `--zig-lib-dir` the client stays the embedded one.
- **The fuzzer's hot loop.** Each run, the fuzzer reads the counters 64
  at a time (`PcBitsetIterator.next`:
  `@as(@Vector(64, u8), @splat(0)) != counters[0..64].*`). Sema maps a
  runtime vector operation with a loop over the elements, about 25
  instructions per element, which made that line 95% of the fuzzer's
  time. Sema now lowers `==` and `!=` on byte vectors of 8 to 64
  elements (multiples of 8) as u64 words (`cmpBytes`: xor, a carry-free
  "byte is nonzero" test, and a multiply that gathers the eight top bits),
  in every build: std's `mem.eql`, `indexOfScalar` and `countScalar` use
  the same compare. Since the backend lowers vectors in XMM registers
  ("Vectors" above), runtime compares go there instead (`pcmpeqb`/
  `pmovmskb`, four of each for 64 bytes); `cmpBytes` remains for
  targets whose backend does not (aarch64, until NEON lowering).

**Measured** (orb, 4 vCPU, ReleaseFast bs, 2026-11-04):

- Finding bugs: `bs build test --fuzz=60M` finds the `key=bs!`
  overflow above in 3 tries out of 3, after 14.0 M, 13.7 M and 3.3 M runs
  (131, 107 and 25 s); upstream LLVM finds it after 6.7 M, 8.5 M and
  6.2 M runs, 18 to 27 s. A `bs` prefix (test/build/hello,
  `zig build test-build`) falls after 0.14 M to 1.8 M runs, a few
  seconds (upstream LLVM: 0.28 M). The test has 9 522 points, against
  upstream's 10 172 (19 787 before Sema marked user branches). bs runs
  about 130 k inputs/s against upstream LLVM's 335 k/s (90 k/s with
  twice the points, 10 k/s before `cmpBytes`). The rest is backend code
  quality: `PcBitsetIterator.next` still takes 43% of the fuzzer's time,
  `SafeAllocator.init` 18% and `isFresh` 9%. Re-measured 2026-11-04 on
  main 5d9b337 (`key=` test, `--fuzz=3M --seed=1`, 10 725 points, runner
  start included): 15.3 s, about 210 k/s, after the backend's `@splat`
  and copy work; 14.2 s (about 227 k/s) with the fuzzer's family built
  ReleaseFast, as upstream's; upstream LLVM 8.3 s. `PcBitsetIterator.next`
  is 54% of the fuzzer process's time, `SafeAllocator.init` (two 16 KiB
  copies of the allocator per input) 11%, `isFresh` 10%.
- Compile time, `bs test` of that test, cache off: 0.16 s plain, 0.34 s
  with `-ffuzz` (the fuzzer's family analyzes std's code a second time;
  86 MB against 48 MB peak). A rebuild with nothing changed takes 0.00 s
  either way, and an edit of a function body 0.01 to 0.03 s. Upstream
  `zig test -ffuzz -fllvm`, fresh cache: 27.9 s (7.6 s without
  `-ffuzz`).
- Run time of instrumented code (bench/runtime as tests, plain against
  `-ffuzz`): fib 0.11 to 0.12 s, sieve 0.14 to 0.24 s, sort 0.38 to
  0.40 s, hash and nbody within noise, fmt 0.12 to 0.13 s. Upstream LLVM
  Debug pays more for its atomic adds: fib 0.14 to 0.70 s, sieve 0.51 to
  1.00 s.
- Off: std's tests compile in the same time as on main (median of 6,
  6.76 s against 6.75 s), and in a hello world only the functions with
  byte-vector compares change (`cmpBytes`: `mem.indexOfScalar` and
  `mem.eql` over 4 KiB run 2.7x faster).

## C interop (milestone 9; designed 2026-11-03, for review)

Goal, in order: `-lc` (dynamically linked executables against glibc on
x86_64-linux, `builtin.link_libc` on both targets, std's tests with `-lc`
as a conformance number); C headers translated to Zig; C sources, objects
and archives. Programs that use none of them must not get slower to
compile.

### What upstream 0.17.0 does (checked on the orb, 2026-11-03)

- **`@cImport` no longer exists.** 0.17.0's AstGen has no `c_import`,
  and `const c = @cImport(@cInclude("stdio.h"));` fails with `error:
  invalid builtin function: '@cImport'`. Headers become Zig through `zig
  translate-c` (Aro, `lib/compiler/translate-c`), which `b.addTranslateC`
  runs as `zig translate-c <flags> <file.h> --listen=-`: the step's output
  is `<local cache>/o/<digest>/<name>.zig`, and the compile steps that use
  it import it as an ordinary module (`-M<name>=<that path>`). So the
  second goal is `bs translate-c`, not a Sema feature: Sema does not
  change, and bs keeps its migration hint for `@cImport`. Upstream builds
  translate-c with LLVM in ReleaseFast the first time it runs (53 s on
  the orb); bs builds it in Debug in 1.35 s (corpus, cold local cache).
- **`-lc`, native target** (no `-target`; `--verbose-link`): upstream asks
  the system C compiler (`LibCInstallation.findNative`, which runs `cc`)
  and links the system's `crt1.o crti.o crtbegin.o crtend.o crtn.o`,
  `libm.so`, `libc.so` (a linker script: `libc.so.6`, `libc_nonshared.a`,
  `ld-linux-x86-64.so.2`) and the empty `libpthread.a libdl.a librt.a
  libutil.a`, with C headers from `/usr/include`. Without a system C
  compiler it falls back to the next case.
- **`-lc -target x86_64-linux-gnu[.version]`** (and native without `cc`):
  upstream provides glibc itself. It compiles `crt1.o` and
  `libc_nonshared.a` from glibc sources bundled in `lib/libc/glibc` with
  Clang, generates stub `libc.so.6`, `libm.so.6`, `libpthread.so.0`,
  `libdl.so.2`, `librt.so.1`, `libutil.so.1`, `libresolv.so.2` and
  `ld-linux-x86-64.so.2` from `lib/libc/glibc/abilists` (every exported
  symbol of every glibc version, with its library, kind, size and symbol
  versions), and takes headers from `lib/libc/include`
  (`std.zig.LibCDirs.detectFromBuilding`). No crti/crtn/crtbegin/crtend.
  Its crt1.o for glibc 2.31 defines `_start` (calling
  `__libc_start_main(main, argc, argv, __libc_csu_init, __libc_csu_fini,
  rtld_fini, stack_end)`), `_IO_stdin_used`, `__data_start`; its
  libc_nonshared.a has `atexit`, `at_quick_exit`, `__pthread_atfork`,
  `__stack_chk_fail_local`, the stat and mknod wrappers of glibc ≤ 2.32,
  and `__libc_csu_init`/`__libc_csu_fini` (glibc ≤ 2.33).
- **The output** in both cases: ET_EXEC, not PIE, base 16 MiB, PT_INTERP
  `/lib64/ld-linux-x86-64.so.2`, DT_NEEDED for libc and ld-linux (and
  libm with the system's files, libpthread with the bundled 2.31 stubs
  for a hello world), `.gnu.version` and
  `.gnu.version_r` (each import bound to the version it had in the
  target's glibc: `GLIBC_2.2.5`, `GLIBC_2.34`, ...), BIND_NOW.
- **`builtin`** for `-lc` on glibc (`--show-builtin`): `link_mode =
  .dynamic`, `abi = .gnu`, the target's glibc version (native: the
  system's, 2.36 on the orb; `x86_64-linux-gnu`: 2.31), `dynamic_linker =
  "/lib64/ld-linux-x86-64.so.2"`, `link_libc = true`, and
  `position_independent_code = true` (upstream's `requiresPic`: linking
  glibc), `position_independent_executable = false`. Without `-lc` the
  native target's `abi` is `.gnu` too and `link_mode` static.
  `-target x86_64-linux -lc` is static musl (the default ABI of
  `x86_64-linux` is musl) and `x86_64-linux-none -lc` fails ("unable to
  provide libc"). On aarch64-macos `link_libc` is always true (Darwin
  requires libc), which the aarch64-codegen branch's builtin already says.
- **C in Debug**: upstream runs `zig clang` per C source with
  `-fsanitize=undefined` (recoverable, so it links its Zig `ubsan_rt`),
  `-O0 -fno-omit-frame-pointer -mred-zone -fno-stack-protector -fPIC
  -fno-PIE -gdwarf-4 -fasynchronous-unwind-tables`, the target and CPU
  features, `-nostdinc` and `-isystem` for the libc headers,
  `-D__GLIBC_MINOR__=N`, and `-MD -MV -MF <depfile>`, whose header list
  goes into its cache manifest (`man.addDiscoveredDepFile`). translate-c
  gets the same include and target flags (`addCommonCCArgs(.aro)`) and the
  same depfile.

### Decision 1: where crt1.o, libc_nonshared.a and libc.so come from

Options:

1. *The system* (upstream's native default): find the files with `cc`,
   read `crt*.o` and `libc_nonshared.a` as relocatable objects, parse the
   `libc.so` linker script, and read `libc.so.6`'s `.dynsym` and version
   definitions. Needs a C compiler and libc6-dev on the host (and option 3
   anyway as the fallback upstream has), and an ELF object, archive and
   linker-script reader in step 1.
2. *Upstream zig*: have upstream produce its crt1.o, libc_nonshared.a and
   stubs (there is no command for it; scraping `--verbose-link` of a dummy
   build). Needs upstream zig for every `-lc` program, even pure Zig ones,
   and a full upstream compile the first time.
3. *bs, from the zig lib directory* (recommended): what upstream does for
   `-target x86_64-linux-gnu`, without Clang:
   - **No libc.so.** The linker resolves imports against `abilists` (the
     data upstream generates its stubs from; the parser is upstream's
     `src/libs/glibc.zig`, copied with its notice): a name neither the
     compilation nor compiler_rt exports is looked up in the target's
     glibc version, giving its library and the newest symbol version at
     or below the target's (upstream's `-lc` executables keep compiler_rt's
     `fmod` too). The library gets a DT_NEEDED (libc.so.6 always, others
     when used) and the import its `.gnu.version_r` entry. Strong names in
     none of them are undefined, as today.
   - **No crt1.o, crti.o, crtn.o.** bs's own glibc start file, Zig with
     inline assembly in std.start's style (`.cfi_undefined %rip`, `%[x:P]`
     symbol operands), generated like `builtin.zig` and added as an
     analysis root when linking glibc: it exports `_start`, which does what
     glibc's `sysdeps/x86_64/start.S` does (clear rbp, argc, argv, align the
     stack, `__libc_start_main(main, argc, argv, init, fini, rtld_fini =
     rdx, stack_end)`, hlt), and `_IO_stdin_used`. For glibc ≥ 2.34, init
     and fini are null, as glibc's own crt1.o passes; for older targets
     they are the file's `__libc_csu_init`/`__libc_csu_fini`, which run
     the preinit, init and fini arrays as libc_nonshared.a's did. std's
     start code then exports `main`, as upstream.
   - **libc_nonshared.a** members are Zig functions in a second file,
     resolved by name only when something references them (the
     compiler_rt mechanism, `Zcu.requestCompilerRtKey`): `atexit` and
     `at_quick_exit` (calling `__cxa_atexit`/`__cxa_at_quick_exit` with
     `__dso_handle`, which the file defines hidden), `__pthread_atfork`,
     `__stack_chk_fail_local`, and the stat/mknod wrappers for glibc ≤
     2.32. std references none of them; C objects may. *As built*
     (C++ milestone): bs compiles libc_nonshared.a from upstream's own
     glibc sources with upstream `zig cc`, as it does libc++, and links
     it into every glibc executable and shared library, as upstream (see
     "Runtime libraries" in the C++ section).
   - **Headers** for translate-c and C sources: `lib/libc/include` for the
     target (`std.zig.LibCDirs.detectFromBuilding`, which bs calls as it
     is) and `-D__GLIBC_MINOR__=N`, as upstream's bundled glibc. System
     headers of other libraries still come from the native include and
     library paths (`std.zig.system.NativePaths.detect`, as upstream does
     when a step links system libraries). *As built* (native-libc): for
     the native ABI (no `-target`, or `native`), libc's headers are the
     system's, as upstream's `LibCDirs.detect` takes them from
     `LibCInstallation.findNative`: `CSource.libcIncludeDirs` runs `$CC`
     (else `cc`) with `-E -Wp,-v -xc /dev/null` and, from the last search
     directory back, takes the first with `stdlib.h` and the first with
     `sys/errno.h` (on the orb `/usr/include` and
     `/usr/include/x86_64-linux-gnu`). It asks `-print-file-name` for
     `crt1.o` and `crtbeginS.o` too and fails as upstream does
     ("failed to find libc installation") without them, though bs links
     neither. A compiler that cannot run or lists no directories falls
     back to the lib directory's headers, as upstream's. The answer is
     kept in `<global>/bs/libc/<key>`, keyed by the compiler's argv and
     its file's stat and by `PATH`, `CPATH`, `C_INCLUDE_PATH`,
     `GCC_EXEC_PREFIX`, `COMPILER_PATH`, `NIX_CFLAGS_COMPILE` and
     `NIX_CC`, so that a build runs no compiler (a 0.1 ms read); the
     directories go into the arguments, hence into every C record's and
     translation record's key, and the headers read under them into
     their file lists, as before. `-target x86_64-linux-gnu[.version]`
     keeps the lib directory's headers, as upstream's. On macOS the
     native libc installation is the SDK (upstream's `findNative` and
     `std.zig.system.darwin`): when `xcode-select --print-path` answers
     (so that no Command Line Tools prompt opens), `xcrun --sdk macosx
     --show-sdk-path` names it, and the headers are `<sdk>/usr/include`
     with `-iframework <sdk>/System/Library/Frameworks`; without either,
     `any-darwin-any`, as upstream. The SDK path is kept in the same
     records, keyed by `xcode-select -s`'s link, `DEVELOPER_DIR`,
     `SDKROOT` and `PATH`. The native target's macOS version is the
     running system's, as upstream's, so the translations match
     upstream's byte for byte. Linking does not
     change: crt code, libc_nonshared.a and the glibc imports stay this
     option's.
   - **glibc version**: `-target x86_64-linux-gnu.2.28` says it; for the
     native target, upstream's detection (`std.zig.system`, which reads
     the system's `libc.so.6`). It is part of the compilation key.

   Native `-lc` then builds what upstream builds for
   `-target x86_64-linux-gnu.<the system's version>`: the same libraries,
   symbols and versions at run time; crt code and headers from the zig
   lib directory instead of `/usr`. It needs no C compiler and no files
   from the system, cross-compiles from macOS, and step 1 needs no object
   reader. The cost: bs owns about a hundred lines of start code, and
   musl stays `[unsupported]`. If the owner prefers option 1, step 1
   grows by the object, archive, script and shared-object readers that
   step 3 needs anyway, and option 3 remains its fallback.

**`builtin`** follows upstream's text for the target (`abi`, `link_mode`,
glibc version, `dynamic_linker`, `link_libc`,
`position_independent_code = true`). bs's code stays executable code
(local-exec thread-locals, absolute addresses), as it is for
`build-exe -fPIE`: the output is a non-PIE executable, where that changes
nothing a program means. `-lc` on aarch64-macos changes nothing (libSystem
is always linked); `-target x86_64-linux[-musl] -lc` links musl
statically (step 5), and `x86_64-linux-none -lc` is `[unsupported]`,
naming the gnu and musl targets.

**The link** (`Elf.Options.dynamic` with an executable kind, on the `pic`
branch's `ElfDynamic`): ET_EXEC at bs's usual base (upstream's 16 MiB
changes nothing a program means); PT_PHDR, PT_INTERP,
the three PT_LOADs, PT_DYNAMIC, PT_TLS, PT_GNU_RELRO, PT_GNU_EH_FRAME,
PT_GNU_STACK. Zig code reaches every extern through an 8-byte slot
(`Emit.lowerExternSlots`), so an import needs only a `R_X86_64_GLOB_DAT`
on its slot: no PLT, no copy relocations. Slots, and any `.rodata` atom
with an absolute relocation to an import, go to `.data.rel.ro` under
RELRO, the `pic` branch's rule. `.dynsym` holds the imports (versioned
through `.gnu.version`, `.gnu.version_r` per library) and no exports
(upstream exports none without `-rdynamic`, which exports all, as bs
does); `.dynamic` gets DT_NEEDED,
DT_VERSYM, DT_VERNEED(NUM), DT_DEBUG (for debuggers; upstream's
self-hosted linker leaves it out), DT_FLAGS BIND_NOW, DT_FLAGS_1 NOW, and
the tables `ElfDynamic` writes for shared objects (no DT_INIT/DT_FINI
without crti/crtn).
The executable's own thread-locals stay local-exec, in the static TLS
block the loader sets up; std's start code no longer sets up TLS itself
(it does not run `_start`). The relocation loop keeps its comptime flag,
so static links compile as before.

### Decision 2: how translated files and headers enter the cache

- **The translate-c binary** is built by bs like the build runner:
  `<zig lib>/compiler/translate-c/main.zig` with the `aro` module, Debug,
  into `<global cache>/bs/o/<hash>/translate-c`, the hash taken from
  bs's identity and the zig lib directory, compiled through bs's own
  cache from a fixed directory, so every project shares it and a later
  use costs a stat. It runs as a child, `--zig-integration` (errors come
  back as an ErrorBundle on stdout), with upstream's arguments.
- **A translation record** per translation, `<local cache>/bs/tc/<key>`
  (small, one file; written through a temporary file and renamed). The
  key hashes the translate-c binary's contents (not bs's identity: a
  new bs that builds the same binary keeps the records), the source path and the arguments that reach Aro (target, glibc version,
  include directories, defines, flags, in order); file contents are not
  in it. The record holds every file Aro read (the source and each header
  from its `-MD` depfile) with its stat (inode, size, mtime, under the
  frontend index's racy-mtime rule) and content hash, and the output's
  content hash.
- **The output** is `<local cache>/o/<key>/<name>.zig` and the digest
  bs reports is the key, so it does not move when a header changes. The
  compile step that imports it keeps its command line, hence its
  compilation key, and builds an edit build of one changed file (upstream
  reports a digest of the contents; its compile step then sees a new
  path).
- **A build of the step**: stat every recorded file; if all match, answer
  with the digest and `cache_hit` without running translate-c. If stats
  changed but contents did not, update the record and hit. Otherwise run
  translate-c; if the output's bytes are unchanged, leave the file alone
  (its stat stays, so the compile step's no-edit check holds), else
  replace it atomically. `file_system_inputs` lists the source and every
  header, so `--watch` and the runner see header edits.
- **In the Zig compilation** the translated file is an ordinary input:
  its ZIR is cached by content, its declarations have `src_hash`es, and a
  header edit that changes one macro re-analyzes the declarations that
  use it. Nothing new in the manifest, the store or the donor key: a
  donor's translated module is matched by its file key (`<module>:` for a
  root) and compared by content like any file.
- **C objects** (step 3) use the same record shape (`<local cache>/bs/cc/
  <key>` with the object next to it), keyed by the upstream zig binary's
  identity instead of translate-c's. The compilation's manifest lists the
  objects among its inputs (path and content hash), so a no-edit build
  stats them like sources; how a relink reads their sections is the
  linker's (step 3).
- **For the cache thread** (it owns the formats): the manifest must keep
  a dynamic executable's imports with their library and version, its
  DT_NEEDED list and interpreter, so a relink without Sema writes the same
  dynamic tables; the compilation key gains the glibc version (native:
  detected, cached by the stat of the system's `libc.so.6`). The donor key
  needs nothing: `-lc` changes `builtin.zig`, which replay checks like
  any input, and import resolution happens at link time.

### Decision 3: how `bs build` routes C

- **Compile steps stay bs's.** A step whose command line has C sources
  (`-cflags ... --`, `.c`, `.S`, `.s` files, modules without a Zig root),
  objects or archives (`.o`, `.a`), or libraries (`-lc`, `-l<name>`) is
  built by the same `bs build-*`: Zig through bs, each C source by
  spawning upstream `zig clang` with the flags upstream's `addCCArgs`
  builds (copied: the list above, for bs's target and baseline CPU), up
  to the job count at once and while Sema runs, then one link by bs.
  Debug C calls `__ubsan_handle_*`, which bs provides from upstream's
  `lib/ubsan_rt.zig`, analyzed lazily as a module like compiler_rt.
  Libraries of C only (libyaml, BearSSL, cmark-gfm) are `build-lib`
  steps: bs compiles their sources and writes the archive with
  `Archive.zig`, indexing the objects' global symbols.
- **TranslateC steps** run `bs translate-c ... --listen=-`, served as
  above. The CLI form prints the file to stdout, as upstream.
- **`bs cc`, `bs c++`, `bs ar`, `bs ranlib`** (build scripts run them
  as `b.graph.zig_exe`, which is bs under `bs build`) exec upstream
  `zig` with the same arguments: they are Clang and LLVM tools, which bs
  never runs itself. `objcopy` stays `[unsupported]` until needed.
- **Finding upstream zig**: `BS_ZIG`, else `zig` on PATH, else
  `~/.cache/bs/zig-<host>-0.17.1/zig` (`toolchain.findZig`), accepted
  only if it reports 0.17.1 (`zig version`, when something must
  compile). Without
  one, a step with C fails with one `[unsupported]` diagnostic saying C
  sources need upstream zig 0.17.1 and where bs looked. Pure Zig and
  `-lc`-only programs never look.
- **The config message** reports `link_libc` and `link_mode = .dynamic`
  for such steps, as upstream.
- **System libraries** (`-l<name>` other than glibc's) follow upstream's
  search: `-L` directories and the native library paths, `lib<name>.so`
  before `lib<name>.a`. Shared ones need a reader of `.dynsym` and version
  definitions; static ones are archives of objects (step 3). C++
  (`-lc++`, `.cpp` sources; upstream builds libc++ from source with
  Clang) stays `[unsupported]` until an acceptance target needs it.

### Linker split

This thread builds step 1's link (dynamic executables on `ElfDynamic`:
the executable kind, abilists imports with versions, PT_INTERP, DT_NEEDED,
`.gnu.version*`) on top of the `pic` branch, with the link thread
reviewing. The link thread takes, after its PIE work, the input side of
step 3: ELF relocatable objects and archives as link inputs (their
sections become atoms; their relocations, including GOTPCREL(X), PLT32
and TLS models, against bs's and other objects' symbols; PLT stubs and
copy relocations for C code that calls or reads imports directly;
`.init_array`, COMDAT groups, mergeable strings, `.eh_frame`), and shared
libraries as inputs. To be agreed with that thread.

### Cost

- Nothing runs unless the command line has `-lc`, C sources, objects or
  libraries: the builtin text, the start file, abilists and the dynamic
  link are all behind that, and the static relocation loop compiles as
  before (comptime flag). Each step reports std's compile time against
  main (`BS_CACHE=off bs test lib/std/std.zig --zig-lib-dir upstream/lib
  --test-no-exec`, interleaved runs) and the compile time of `-lc`
  programs against upstream (on the orb, upstream's native `-lc` hello:
  4.3 s with an empty global cache, 0.38 s warm).
- abilists is 247 KiB; parsing it for one target is a one-time cost per
  build that links glibc, cached per (zig lib, version) in the global
  cache as the resolved name table if it shows in profiles.

### Step 1 as built (2026-11-04)

- **Options** (`main.parseOptions`): `-lc`, `-lm`, `-lpthread`, `-ldl`,
  `-lrt`, `-lutil` and `-lresolv` (upstream's `isLibCLibName` for glibc)
  set `link_libc`; `-target x86_64-linux-gnu[.version]` names the glibc
  version (2.31 by default, as upstream), the native target detects the
  system's (`std.zig.system.resolveTargetQuery`, only for `-lc`); other
  targets with `-lc` are `[unsupported]`. `-dynamic` on an executable is
  accepted with `-lc`. Objects and static libraries with `-lc` are
  ordinary ones, as upstream's (static `link_mode`, no start code, externs
  left to the final link), but position-independent (upstream's
  `requiresPIC` for glibc), as their builtin says. `build-lib -dynamic
  -lc` (built 2026-11-04) links glibc as an executable does, as an
  ET_DYN: DT_NEEDED libc.so.6 and the other glibc libraries it uses,
  imports versioned through .gnu.version and .gnu.version_r
  (`Glibc.sharedObjectOptions`), no PT_INTERP or DT_DEBUG, no copies
  (data goes through the GOT), and imports through PLT stubs and GOT
  slots as in any bs shared object; a name neither its shared libraries
  nor glibc define is imported unversioned, for the program that loads
  it. A glibc newer than abilists' newest links against the newest,
  with upstream's warning. Over `--listen=-`, the config message reports
  `link_libc` and a dynamic link mode.
- **`builtin`** (`Builtin.generate` with `glibc`): upstream's text for
  `x86_64-linux-gnu.<version> -lc` (checked line by line against
  `--show-builtin`), plus one line, `comptime { _ = @import
  ("glibc_start.zig"); }`, which is not a declaration, so
  `@typeInfo(builtin)` stays upstream's. The start file sits next to
  builtin.zig in its content-addressed directory, whose hash covers both.
  With or without `-lc`, a Linux target (x86_64 or aarch64) resolves as upstream's
  (`main.checkTarget` calls `std.zig.system.resolveTargetQuery`), and
  builtin states its ABI (the system's for the native target, musl for
  `x86_64-linux`, none for `x86_64-linux-none`), kernel and glibc
  versions and dynamic linker. A native OS's resolved values go into the
  compilation's key (`--bs-native=`), since the arguments do not spell
  them.
- **Start code** (`Builtin.glibc_start`): a naked `_start` (CFI
  undefined rip) passes the stack pointer and rdx to `startMain`, which
  calls `__libc_start_main(main, argc, argv, null, null, rtld_fini,
  sp)`; it also exports `_IO_stdin_used`. Init and fini are null for
  every glibc version: no Zig code needs init arrays, and C objects
  (step 3) bring the question back for targets before 2.34.
- **Imports** (`src/link/Glibc.zig`, `Emit.exportTarget`): the abilists
  parser keeps, per name, the first library in upstream's link order
  (m, c, ld, resolv, then the libraries merged into libc in 2.34, only
  for older targets) with a version at or below the target's, and its
  newest such version. A name neither the compilation nor compiler_rt
  exports resolves to it, as upstream's order (its `fmod` stays in the
  executable). `Emit.link` sorts the imports by name, lists
  libc.so.6 and the libraries used in DT_NEEDED, and gives each import
  its version. A hello world's 96 imports bind to the same versions as
  upstream's native `-lc` build on the orb (upstream imports three more:
  `__tls_get_addr`, `getrandom`, `sendfile`, which bs's lazy analysis
  does not reach).
- **Elf** (`Options.dynamic` with `interp`): imports take stand-in
  addresses outside the image (`exe_import_base`), so an absolute
  relocation to one becomes `R_X86_64_64` against its symbol and a
  PC-relative one overflows. Layout counts and the copy pass write
  .rela.dyn records only for absolute relocations to imports (a sorted
  key list, binary-searched per absolute relocation), and only .rodata
  atoms with one go to .data.rel.ro. No PLT, no GOT; .interp,
  .gnu.version and .gnu.version_r get section headers after the shared
  object's, and their names extend the section name table, whose
  shorter prefixes the other outputs keep.
- **Cached (step 1b).** A `-lc` executable uses the on-disk cache like
  any other; `-lc` objects and libraries are position-independent and
  skip it as other pic builds do. The manifest needs nothing new: it
  already lists every import with its flags (`.import` link symbols), and
  the dynamic tables follow from their names and the glibc version, so a
  relink (`Incremental.linkFrom`) rebuilds them with the function
  `Emit.link` uses (`Glibc.dynamicOptions`: imports sorted by name, each
  with its library and version; DT_NEEDED; the interpreter) and numbers
  the imports for the numbered link (`Elf.Symbols.dynamic_imports`; the
  i-th import's address-table entry is `import_tag + i`, standing for the
  key-based stand-in address outside the image, and which absolute
  relocations need the loader is still decided by the targets' keys,
  which numbered atoms keep; a unit test links an executable keyed and
  numbered, compares the bytes and runs it under ld.so). It
  takes the glibc the build loaded, or reads abilists (0.6 ms) for a
  relink without CodeGen. `Job.compile_args` gains `--bs-glibc=<version>`
  (not `full_args`), so the compilation key covers the native version,
  and `donorKey` hashes it: CodeGen resolves names glibc defines to
  imports. The store seed stays: store entries match by their atoms'
  hashes. Tests: test/run/libc_edit.zig (edit builds with
  `BS_CACHE_VERIFY`, then a relink from the manifest after the output
  is deleted, which reads abilists, compared byte for byte with a full
  build) and test/run/libc_donor.zig (`donor-libc`: static and `-lc`
  builds of one program into one global cache, in both orders, and
  neither replays the other). Edit builds of the corpus thread's `-lc`
  projects (`bs build test`, a one-line body edit, compile step):
  libxev 0.20 → 0.03 s, zio 0.69 → 0.06 s, zedis 0.31–0.38 → 0.05 s,
  tokamak 1.0 → 0.035 s (upstream 0.7, 1, 1 and 2 s).
- **Checks**: `run.py --std --libc` 3350/3350 (upstream 3350 pass, 37
  skip; compiled in 8.5 s against upstream's 17.8 s);
  test/run/libc.zig (functions, a variadic call, libm, `environ` and
  `stdout`, a callback, malloc, threads and thread-locals, an exit
  status), compared with upstream's `-target x86_64-linux-gnu -lc`
  build; a panic's stack trace through libc's frames matches upstream's,
  with bs's start code as the outermost frame.
- **Found on the way**: bs passes a slice to a variadic function, which
  upstream rejects ("cannot pass '[:0]const u8' to variadic function"):
  bs has no extern-type validation (`validateExtern`) for variadic
  arguments or C-callconv parameters. It accepts more than upstream;
  it is Sema's to fix.

### Step 2 as built (2026-11-04)

- **`bs translate-c`** (`src/TranslateC.zig`): the CLI prints the
  translation, as upstream; `--listen=-` answers each update with
  `file_system_inputs` (the source and every header) and `emit_digest`,
  or with translate-c's ErrorBundle, passed through as it came. Options:
  `-target`, `-lc` and glibc's other `-l` names, `-I`/`-isystem`/
  `-iquote`/`-idirafter`/`-D`/`-U` and the like (passed to Aro in order),
  the cache and lib directories; `-O` is ignored (headers see Debug's
  macros, as the code they go into), `-cflags ... --` too, as upstream.
  Targets: an x86_64-linux host only, since bs builds the translate-c
  binary with its x86_64 backend; it translates for x86_64-linux and
  aarch64-linux (`aarch64-linux-none`, or `aarch64-linux-gnu` with
  `-lc`; the generic CPU), whose output matches upstream's.
- **Aro's arguments** are upstream's (`Compilation.translateC`, read from
  the argv upstream's zig passes its translate-c binary) for bs's
  target: `-mcpu` is bs's CPU (`main.resolveCpu`: the clamped host CPU
  for the native target, else the target's default, unless `-mcpu` says
  otherwise),
  so CPU feature macros are its; the triple is the native
  one without `-target` (glibc's
  ABI and detected version, with or without `-lc`, as upstream's native
  target), `x86_64-linux-none` for `-target x86_64-linux`. `-lc` adds
  `-fPIC`, `-D__GLIBC_MINOR__` and libc's headers: the system's for the
  native ABI, else glibc's from the zig lib directory (decision 1,
  `CSource.libcIncludeDirs`); the binary itself still adds
  the native include paths (`/usr/include`) after all of these, as
  upstream's does. A native `-l<name>` other than libc's and libc++'s
  also puts them right after libc's headers, ahead of the user's flags
  (upstream's `native_system_include_paths`), so a system header shadows
  one of the same name in a user's `-isystem` directory, as upstream.
  Output
  matches upstream's byte for byte for `-mcpu=baseline` (tokamak's
  `c.h` without `-lc`) and for `-target x86_64-linux-gnu.2.36 -lc`
  (stdio.h).
- **The binary**: `<zig lib>/compiler/translate-c/main.zig` with `aro`,
  Debug, compiled by bs from `<global cache>/bs/o/<hash>/` like the
  build runner (`BuildRunner.compileTool`, `toolUnchanged`).
- **Records** (`<local cache>/bs/tc/<key>`): a header (magic
  `ZAPTC002`, the output's hash, counts), one 48-byte entry per file
  (inode, size, mtime or racy, path length, content hash), then the
  absolute paths. The key (`ToolRecord.key` over the binary's content
  hash, kept in `translate-c.hash` beside it and recomputed when the
  binary's stat stamp changes, Aro's arguments and the source's absolute
  path, the working directory and the zig lib directory; not bs's
  identity, since bs's code generation reaches the output only through
  the binary) names the output,
  `<local cache>/o/<key>/<stem>.zig`, and is the digest. A hit stats the
  files, rehashes those whose stats changed, and rewrites the record when
  only stats changed, else touches it (its mtime is its last use, for
  trimming). A miss translates into `bs/tmp`, moves the output into
  place only when its bytes changed, then replaces the record. Trimming
  `bs/tc` and `o/<key>` under the local cache's cap is the cache
  thread's (maintain), by the record's mtime.
- **Checks**: test/build/hello's `shape` step (a `b.addTranslateC` with
  `-lc`, an include directory and a macro, imported by a `-lc`
  program): a header edit translates again, a touched header is
  `translate-c cached`.

### Step 3, C sources, as built (2026-11-04)

- **Options** (`main.parseOptions`), as upstream's: `-I`, `-isystem`,
  `-idirafter`, `-iwithsysroot`, `--embed-dir=` (each directory once per
  group and module, as `ClangSearchSanitizer`) and `-D` collect in
  `cc_argv`, which the next `-M` takes together with the `.c` files given
  since the last `-M` and the module's C options (`-fsanitize-c[=trap|
  full]`, `-fno-sanitize-c`, `-m[no-]red-zone`, `-f[no-]builtin`,
  `-f[no-]PIC`; unset ones take the root module's, then Debug's
  default). A root file given by position takes what is left; else what
  is left is `global_cc_argv`. `-cflags ... --` applies to the C files
  after it. `-ffunction-sections`, `-fdata-sections`, `-fPIE` and
  `--verbose-cc` are global.
- **Relocatable links** (`build-obj` with object inputs or C sources,
  built 2026-11-04; `link/ElfMerge.zig`), as upstream's `flushObject`:
  the Zig object (written by `ElfObject` as before), then the object
  inputs, then the C objects, merged as `ld -r` merges them. Inputs stay
  ELF, not Atoms: sections with the same name (and COMDAT group) are
  concatenated in input order at their alignment, symbols and RELA
  relocations are renumbered and moved by each piece's offset, and a
  relocation against an input's section symbol names the output
  section's with the piece's offset added. COMDAT groups repeat only
  once (the first input's), with a `.group` section listing the members
  and their relocation sections; the FDEs of dropped members go too,
  and debug relocations against them point at 0. Globals: one per name,
  a strong definition over a weak one over COMMON over references, two
  strong definitions an error, the most restrictive visibility. .eh_frame
  pieces follow each other without padding or zero terminators, which
  LLD reads as the end of the section. `.llvm_addrsig` is dropped. A C
  object only (no Zig module) is merged the same way. Upstream also
  dedupes merged strings and rebuilds .eh_frame; bs's output links to
  the same program (test/link_input/merge*: upstream's linker, LLD with
  C++ COMDATs and exceptions, and bs's) and keeps C and Zig lines in
  traces. The cache relinks the Zig object and merges again
  (`Incremental.linkFrom`; test/obj/cache.sh).
- **Mach-O relocatable links** (2026-11-05, for zine's 400+ C-only
  tree-sitter `build-obj` steps; `link/MachOMerge.zig`), as upstream's
  `MachO/relocatable.zig`: a single input (one C source, no Zig code) is
  copied as it is, debug info included, as upstream copies it, since
  merging drops `__DWARF`. Several are merged as ElfMerge merges them:
  sections by segment and section name in input order at their
  alignment, zero-fill last, symbols renumbered (locals, then the
  defined globals and the undefined and COMMON ones, each by name, as
  LC_DYSYMTAB groups them; the same rules for duplicates), relocations
  moved and renumbered in their order so ADDEND and SUBTRACTOR pairs
  stay together. A section-relative UNSIGNED (`__compact_unwind`'s
  function field) names its target by address, so its field moves with
  the target section; Clang emits no other section-relative arm64
  relocation. `__compact_unwind` and `__eh_frame` are concatenated,
  which ld64 and `MachOInput` read as they read the inputs' (upstream
  regenerates both); `__eh_frame` pieces must need no padding.
  S_ATTR_DEBUG sections other than `__compact_unwind` are dropped, as
  upstream drops them: Mach-O DWARF has no relocations for its offsets
  into its own sections, so it cannot be concatenated. The inputs'
  `__objc_imageinfo` merge into one (`MachOInput.mergeImageInfo`).
  LC_BUILD_VERSION and LC_LINKER_OPTIONs are kept; linker optimization
  hints and data-in-code, which are hints, are dropped;
  MH_SUBSECTIONS_VIA_SYMBOLS only if every input has it (bs's own
  objects do not set it).
- **Shared libraries with inputs** (`build-lib -dynamic` with object or
  archive inputs or C sources, built 2026-11-04), as upstream's: the
  objects are converted and linked as an executable's are
  (`ElfInput.Inputs.shared`), archive members pulled as for an
  executable, C sources compiled `-fPIC` (`CSource.Options.pic`), and
  ubsan_rt linked in for them. Shared library inputs, given as paths or
  `-l` names, are linked as an executable links them (pcre2's
  libpcre2-posix.so links libpcre2-8.so; test/link_input/so_chain.c):
  DT_NEEDED by soname and their definitions imported; a library given
  one without `-static` or `-dynamic` is shared, as upstream's. The objects' default and protected
  globals and commons are exported next to the Zig code's
  (`ElfInput.dynamicExports`, at their offsets in their sections'
  atoms), and names nothing defines are imported, as the Zig code's
  are. A name's visibility is the most constraining one any object's
  symbol gives it, reference or definition (`Inputs.visibility`, the
  gABI's rule and lld's): libc++'s inline functions are hidden in its
  archive and default in the user's objects, so they stay unexported
  and bind locally (test/link_input/so_hidref.c; 2026-11-05).
  Thread-locals keep the dynamic models: TLSGD addresses a 16-byte
  (module, offset) pair the loader completes (R_X86_64_DTPMOD64,
  `x86_64_dtpmod64`), TLSLD the module's pair, and a TLS descriptor
  (GCC's `-mtls-dialect=gnu2`) a 16-byte descriptor (R_X86_64_TLSDESC
  with no symbol, `x86_64_tlsdesc`) whose call stays. A thread-local
  the library exports with default visibility binds through its export
  instead, as upstream's (`x86_64_dtpmod64_sym`, `x86_64_dtpoff64_sym`,
  `x86_64_tlsdesc_sym`: DTPMOD64/DTPOFF64 or TLSDESC against the
  .dynsym symbol), so an executable that defines the same thread-local
  preempts it (test/link_input/so_preempt.c); hidden, protected and
  static ones bind the library's own. The objects' functions and data
  of default visibility bind through their exports the same way (lld's
  default, no -Bsymbolic; 2026-11-04, fmt's exceptions, whose typeinfo
  the executable defines too): a PLT32 call goes through a stub and a
  slot, a GOT load reads a slot, unrelaxed, and an R_X86_64_64 in data
  stays one against the symbol (`x86_64_abs64_sym`, the addend in the
  field), so an executable's definition wins
  (test/link_input/so_interpose.c). Zig exports and indirect functions
  bind locally, as do PC32 references, which lld refuses against such
  symbols. The relocation names the export at the target's address, so
  of two names at one address (C++'s C1/C2 constructors, `alias`) it may
  name the other one; only an executable that defines one of them and
  not the other can tell. Refused with a diagnostic: non-PIC relocations
  (R_X86_64_32, 32S, TPOFF32, GOTTPOFF), Clang's `_TLS_MODULE_BASE_`
  descriptors, and another module's thread-locals. Upstream also
  exports ubsan_rt's handlers (weak); bs does not. Shared libraries
  are not cached, so there is no relink (test/link_input/so_*).
- **Assembly sources** (2026-11-04, libsodium's `addAssemblyFile`), as
  upstream's `FileExt`: `.S` (`assembly_with_cpp`) takes C's arguments
  up to the code generation flags, without the C-only ones
  (`-fno-caret-diagnostics`, `-fno-spell-checking`, the sanitizer, `-O`),
  and both the compiler's and the assembler's CPU features; `.s`
  (`assembly`) takes only the target, PIC, debug-info and LTO flags and
  the assembler's CPU features, and writes no depfile, so its record
  holds the source alone (an `.include` it reads is not an input, as
  upstream's cache has none either). The command lines equal upstream's
  `--verbose-cc` apart from the CPU (bs's baseline).
- **LLVM IR sources** (2026-11-05, evm.zig's mcl `.ll` files), as
  upstream's `FileExt` `.ll` and `.bc`: C's arguments without the
  preprocessor's (no defines, `-isystem` directories,
  `-fno-spell-checking` or `-Werror=date-time`) but with the sanitizer,
  `-O` and the CPU features, and no depfile, so the record holds the
  source alone. `-cflags` still apply (Clang accepts `-std=c++20` on
  IR). The command lines equal upstream's `--verbose-cc` apart from the
  CPU.
- **Static libraries** (2026-11-04), as upstream's: the archive holds
  the Zig object (`<root stem>.o`), then the object inputs (named after
  their files, as given), then one member per C source (`<stem>.o`),
  with one symbol index over all of them (`Archive.write` takes the
  members). Archive inputs of `build-lib` and `build-obj` are left out,
  as upstream leaves them (a missing one is an error). Object inputs
  and C sources of `build-obj` are merged into the object (above). A
  cached library relinks as its Zig object plus the
  other members read again (`Incremental.linkFrom`); it does not link
  them as an executable's inputs (built 2026-11-04). A module without a root source
  file (`-M<name>`, which `zig build` passes for a library of C only)
  holds C sources and no Zig module, and `--dep`s on it are dropped; as
  the root module, or with C files and no module at all, it makes a
  library of C only (`Options.c_only`): bs compiles the C, analyzes no
  Zig, and writes the archive of the objects, named after `--name` or
  the first C file. Object inputs alone, with no root and no C (libvaxis's
  C API library, 2026-11-04), make the same kind of library or object:
  the archive holds them, or the object merges them, named after the
  first object, and every build writes it again from them, so there is
  no cache entry to relink (test/obj/cache.sh). Libraries do not root ubsan_rt or ssp; an executable
  that links them does. The member headers' mode is `0` and odd sizes are
  padded with a zero byte, as upstream's (bs wrote `644` and `\n`
  before), so an archive of C is upstream's byte for
  byte for the same CPU with upstream's own linker (`-fno-llvm
  -fno-lld`); a library of C only under `zig build` links with LLD by
  default, which writes llvm-ar's format (a 32-bit `/` index) and names
  each member after its object's path in upstream's cache
  (`.zig-cache/o/<hash>/altsvc.o`, curl's libcurl.a), where bs keeps
  the basename. The paths could not match: bs's cache lays its objects
  out differently. A rootless module other than the root
  contributes its C files to any build. A rootless root module of
  `build-lib -dynamic` (libsodium's shared library) makes a shared
  library of C, linked from bs's root file as an executable of C only
  is (below, `Options.c_root`), for compiler_rt and ubsan_rt; it is
  position-independent, so it has no cache entry, and each build links
  it again from the C objects' records (built 2026-11-04).
- **Executables of C only** (libxml2's xmllint): a rootless root
  module, or C files and no module, in `build-exe` or `run` with `-lc`
  (`Options.c_root`). Upstream analyzes no Zig and links glibc's crt1.o;
  bs's start code is Zig (`Builtin.glibc_start`), so the root file is
  bs's `Builtin.c_main` (`<global>/bs/c_main/<hash>/c_main.zig`),
  which declares `_start` so that std's start code exports neither
  `_start` nor `main`. glibc_start.zig calls C's `main`, and the build
  roots compiler_rt and ubsan_rt as any executable with C does, and
  caches like one. When no C source's object references a `__ubsan_*`
  handler (none has `-fsanitize-c=full`, or its code has nothing UBSan
  checks, such as calls to `sin` and `cos`) and there are no object
  inputs, nothing reports through a panic handler (`main.plainC`: the
  build waits for the C objects, ELF or Mach-O, before analysis to read
  their undefined symbols, as upstream's archive of ubsan_rt is pulled
  only by a reference). On aarch64-macos such plain C roots neither
  ubsan_rt nor ssp either (libSystem has `__stack_chk_fail`): hello
  is 33 KB instead of 1.29 MB, a dylib of `sin` and `cos` 34 KB instead
  of 1.31 MB. Its names bind to libSystem before compiler_rt as glibc's
  do (`Emit.libsystem`: the names lib/libc/darwin/libSystem.tbd, upstream's
  stub, exports to arm64, read by link/Tbd.zig; matched as spelled, so
  `reallocarray$DARWIN_EXTSN` and not `reallocarray`), so the dylib
  imports `_sin` and `_cos` as upstream's does (2026-11-05). The root then
  sets `panic = std.debug.no_panic`: upstream's crt1.o and compiler_rt
  (built with no safety) have none either. Otherwise compiler_rt's
  `__stack_chk_fail` and the std functions it shares with the program
  reach std's default handler, whose I/O imports glibc functions that
  glibc before 2.16 lacks (`accept4`, `sendmmsg`), and the program
  grows from 275 KB to 2.4 MB (a shared library of `sin` and `cos`:
  2.4 MB and 92 imports, against 14.6 KB and 2 when plain). Either way the root's std options are
  upstream's ubsan_rt.zig root's, the only Zig upstream links into C:
  no networking, so std's I/O imports no socket functions (`accept4`,
  `getaddrinfo`, `sendmmsg`), and no segfault handler, which crt1.o
  does not install either.
  Such plain C (`main.plainC`) against glibc also links the way
  upstream's lld link does, where compiler_rt is an archive of one
  member after `-lc` and no ubsan_rt is linked: names glibc defines
  (`memset`, `memcpy`, `strlen`, libm's functions) are imported before
  compiler_rt's (`Emit.libc_first`), and neither ubsan_rt nor ssp is a
  root, so `__stack_chk_fail` is glibc's ("*** stack smashing detected
  ***") except before glibc 2.4, which lacks it. One difference is
  deliberate: when a name glibc lacks (`__udivti3`, or
  `__stack_chk_fail` before 2.4) pulls upstream's member in, all of
  its functions override glibc's, and bs keeps importing glibc's,
  which are faster than bs's compiler_rt (memset 25 GB/s against 2.5,
  2026-11-05). Without `-lc` it stays `[unsupported]`, since C has no
  `_start` of its own.
- **Clang's arguments** (`CSource.zig`) are upstream's `addCCArgs` for
  bs's target and the baseline CPU, in Debug: the triple from the glibc
  version (native: detected, with or without `-lc`, as upstream's native
  target; `x86_64-linux`: no libc), `-fPIC` with `-lc`
  (`requiresPic`), libc's headers as translate-c's (decision 1: the
  system's for the native ABI), `-fno-stack-protector` (upstream's Debug
  backend for Zig has none, which turns it off for the compilation's C
  too; step 4 has the exceptions), the sanitizer flags of `sanitize_c`, every CPU feature, then
  `global_cc_argv`, the module's `cc_argv` and the file's `-cflags`.
  bs leaves out `--serialize-diagnostics` and reads Clang's text
  errors instead (`-fno-caret-diagnostics`: `path:line:col: error:`,
  with notes), which become ordinary diagnostics. The objects are byte
  for byte upstream's for `-target x86_64-linux-gnu.2.36 -lc
  -mcpu=baseline` and for the native target with and without `-lc`
  (with `-mcpu=baseline`, since the native target's CPU is the host's,
  which bs clamps).
- **Running**: upstream zig is `BS_ZIG`, else `zig` on PATH, else
  `~/.cache/bs/zig-0.17.1/zig` or `zig-<host>-0.17.1/zig`; its
  version is checked (`zig version`, 5 ms) only when something must
  compile. The compiles start before the frontend, on up to the CPU
  count of tasks (`Io.Group.concurrent`, each running `zig clang`), and
  the first `Emit.sync` (the end of the main analysis) waits for them
  and adds their objects to `ElfInput`, so archive members and
  compiler_rt are pulled for them as for `.o` inputs.
- **Records**: as translate-c's (`ToolRecord.zig`, shared): the key
  covers upstream zig's path and stat, Clang's arguments without the
  depfile and output paths, the source's absolute path, the working
  directory and the zig lib directory, and not bs's identity, so a new
  bs keeps the objects (SDL3's 473 took 37 s to compile again). bs
  writes no file Clang reads: everything else Clang reads (the source,
  every header, libc's and libc++'s from the lib directory included) is
  in the depfile, so in the record by content. The runtime libraries
  (libc++, libunwind, libc_nonshared) have no records: their archives
  are keyed by upstream zig's identity and their compiles' arguments,
  trusting the lib directory's sources by path as the build runner does;
  the object
  is `<local cache>/o/<key>/<stem>.o`, the record `bs/tc/<key>`, so the
  cache's trimming covers both. A build whose C files and headers all
  stat as recorded runs no Clang; a header edit recompiles the files
  that read it.
- **Cached**: the records' objects are link-only manifest inputs
  (`Incremental.link_objects`), after the `.o`/`.a` arguments, as
  `ElfInput` takes them; their paths stay out of the compilation key,
  since a record's object path is not part of the program. An edited
  source keeps its object's path, so while any record missed
  (`Batch.misses`) the build cannot take its object for the last
  build's. When nothing but link objects changed
  (`onlyLinkInputsMayChange`), the build waits for Clang and relinks
  with the last build's atoms, as after an edited object (googletest's
  C++ edit: 0.23 s to 0.15 s, a comment-only one to 0.05 s since the
  object keeps its bytes; upstream 0.15–0.17 s); else Clang runs while the
  Zig code replays eagerly (`Incremental.link_objects_pending`). A build
  whose records all hit and whose inputs are unchanged skips the link, and a Zig edit can then build lazily. On a hit the build
  reports the C sources and headers as its inputs, not the objects.
  A library of C only (`c_only`) has no Zig to cache and stays outside
  `Incremental`; when no source compiles, it keeps its archive if the
  archive and every object stat as when it was written (a stamp of
  their paths, inodes, sizes and mtimes at `<local>/bs/car/<key>`),
  as upstream's cache hit does: SDL3's unchanged `bs build` went from
  0.85 s to 0.07 s (upstream 0.06 s), since writing its 70 MB archive
  dominated. The records' checks share one stat per file
  (`ToolRecord.Stats`; SDL3's 473 records list 190k headers), and a
  build reports each file the C read once.
- **Batch summary** (`CSource.Summary`, `<local>/bs/cb/<key>`): when
  every source's object is done, the build writes the objects' paths
  and the distinct files all records list, each with its stat. The key
  covers bs's identity (bs turns the options into the records' keys),
  upstream zig's, the working and lib directories, the target's common
  Clang arguments, the options and every source. A build whose files
  all stat as summarized takes the objects without computing Clang's
  arguments or reading a record; any difference falls back to the
  records. Input files newer than the racy window keep the summary
  from being written (objects are renamed into place, so their inodes
  change), and a summary older than an hour is ignored, so that the
  records' mtimes, by which the cache trims, get renewed. An executable
  whose link is unchanged reports the records' inputs without reading
  the objects. SDL3's lib step went from 47 ms to 13 ms, and its
  unchanged `bs build example` from 0.09 s to 0.023 s (upstream
  0.042 s). test/link_input/cache.sh checks a `-lc` program with a C
  source: cold, unchanged, a C edit, a touched source and a Zig edit;
  and a library of C only: unchanged (from the summary), a header edit,
  a deleted archive.
- **Runtime**: Debug C calls `__ubsan_handle_*` and, with `-lc`,
  glibc; C sources root ubsan_rt and ssp (`Frontend.Options.c_runtimes`)
  as object inputs do, and their glibc references resolve as an object's
  (the link thread's `obj-inputs2`).
- **Cost** (ReleaseFast, test/link_input's `libc_main.zig` with
  `libc.c` and `-lc`), medians against upstream's with warm global
  caches: unchanged 0.003 s (upstream 0.35 s); a C edit 0.085 s (0.35 s),
  since Clang runs while the Zig code replays; a Zig edit 0.084 s
  (0.33 s); a new local cache 0.086 s (0.35 s), from a donor. Before
  the cache took C objects these were 0.14 to 0.19 s, full Zig builds.
  A build with empty caches pays the recording, 0.33 s against 0.29 s
  without it. std's compile time does not change (5.93 s against main's
  5.83 s, within noise).
- **Checks**: build.zig's `addLinkInputTests` builds test/link_input's
  `lib.c`, `tls.c` and `tlsie.c` as C sources (`-cflags`, `-fPIC`) with
  the archives of the `zig cc` variant, and `libc.c` as the C source of
  a `-lc` program, with ubsan on, and expects the output of upstream's
  link of the same inputs.

### Step 4: C++, as built (2026-11-04; approved in AGENTS.md aba67e5)

bs compiles no C++ either: `.C`, `.cc`, `.cpp`, `.cxx`, `.c++` and
`.stub` sources (upstream's `FileExt.cpp`) go to upstream `zig clang`
like C sources (`CSource.Lang`), with the same records, cache inputs and
diagnostics. Objective-C (`.m`) and Objective-C++ (`.mm`, `.M`; added
2026-11-05 for fizzy's macOS platform code) go the same way and take C's
arguments: as upstream, clang picks the language from the extension (no
`-x`), and only C++ proper adds `-nostdinc++`. The Objective-C runtime
and frameworks come from the step's own `-lobjc` and `-framework`
options, as upstream's.

- **Arguments** (`CSource.appendArgs`, one function for C, C++ and
  libunwind's assembly, in upstream's `addCCArgs` order): C++ adds
  `-nostdinc++`; with `-lc++`, every source (C too, as upstream) gets
  `-isystem` libcxx/include and libcxxabi/include and libc++'s
  configuration (`libcxx.addCxxArgs`: ABI version and namespace,
  threads, `_LIBCPP_PSTL_BACKEND_SERIAL`, and the runtime libraries'
  hardening, `_LIBCPP_HARDENING_MODE_NONE` with the `IGNORE` assertion
  semantic, since upstream derives it from `compilerRtOptMode`, which is
  ReleaseFast on this target even in Debug), then libunwind's include
  directory after libc's. All 83 command lines of a `-lc++` executable
  (libc++, libc++abi, libunwind and the user's source) equal upstream's
  `--verbose-cc` for `-target x86_64-linux-gnu -lc++` apart from the
  CPU features (bs's baseline) and, natively, the libc include
  directories (decision 1); monstar's simdutf, highway and ghostty-vt's
  `src/simd/*.cpp` match the same way.
- **Stack protector**: as upstream's `Module.create`, a C or C++ source
  gets `-fstack-protector-strong --param ssp-buffer-size=4` when the
  compilation links libc and its Zig code has no self-hosted backend: a
  library of C only (`c_only`), an executable or shared library of C only
  (`c_root`: upstream has no Zig for it), or `-fllvm`, which bs
  otherwise ignores; a module's `-fstack-protector`/`-fno-stack-protector` wins.
  Otherwise `-fno-stack-protector`, as before.
- **Native include directories** (upstream's
  `native_system_include_paths`): a native build without `--sysroot`
  that names system libraries (`-l<name>` other than libc's and libc++'s)
  gives its C and C++ sources the `std.zig.system.NativePaths` include
  directories after libc's, as it already searched their library
  directories. This was a gap of step 3's C sources too.
- **`-lc++`**, and `-lstdc++`, `-lc++abi`, `-lsupc++` (upstream's
  `is_libcpp_lib_name`), imply `-lc` and set `builtin.link_libcpp` and
  the `--listen=-` configuration's `link_libcpp`/`link_libunwind`. An
  executable (and `bs test`/`run`) and a shared library (fmt's libfmt.so,
  test/link_input/so_cxx.cpp, 2026-11-04) link libc++.a, libc++abi.a and
  libunwind.a; a static library or object only takes the flags, as
  upstream links the runtime libraries only into executables and shared
  libraries. Like C sources, `-lc++` roots ubsan_rt and ssp.
- **Runtime libraries** (`CSource.runtime_libs`, copied from upstream's
  `src/libs/libcxx.zig` and `libunwind.zig` with their MIT notice): each
  source with upstream's sub-compilation flags (ReleaseFast, PIC, no
  sanitizer, function and data sections, asynchronous unwind tables,
  then the library's own defines and visibility). They compile in the
  same Clang batch as the user's sources, at
  `<global>/bs/tmp/<lib>-<random>/`, and `Batch.wait` writes
  `<global>/bs/o/<key>/lib<name>.a` (`Archive.write`, atomically) and
  removes the directory. The key hashes upstream zig's identity, the
  library name and every compile's arguments, not bs's identity (a new
  bs builds the same library), and trusts the lib directory, as the
  build runner's translate-c does. A build whose archives exist runs
  nothing for them. The archives follow the C objects as link inputs
  (`ElfInput.addArchive`; `Emit.sync`) and as the cache's
  `link_objects`, so an unchanged rebuild stats them and skips the link.
  Upstream links them as `libunwind libc++ <objects> libc++abi`; bs's
  archives resolve as one group (`ElfInput.pull` loops until nothing more
  is pulled), so the order does not change which members load.
- **aarch64-macos** (2026-11-05, for fizzy): `-lc++` builds libc++ and
  libc++abi the same way, without libunwind, which is libSystem's
  (upstream's `libCxxNeedsLibUnwind`), and without
  `_LIBCPP_HAS_TIME_ZONE_DATABASE` (Linux only in `addCxxArgs`); a
  user source gets no libunwind include directory. The archives are
  Darwin's (`Archive.writeDarwin`), and MachOInput pulls their members.
  libc++ is built with `-fvisibility=hidden`, so its definitions are
  private externals: `writeDarwin` indexes them, as upstream's
  `Object.updateArSymtab` and ranlib do (it indexed only plain externals
  before, so a hidden definition could not be pulled). The throws need
  `__unwind_info`'s personalities and LSDAs (see "Unwind (stage A2)").
  Checked on the Mac against upstream: a Zig program calling C++ that
  throws through four frames with destructors, catches by type, catches
  `vector::at`'s `out_of_range` with `catch (...)` and rethrows it, and
  prints with iostream and stringstream gives the same output and exit
  status, and so does a C++-only `main`.
- **libc_nonshared.a** (`CSource.nonshared_lib`, from upstream's
  `src/libs/glibc.zig`): `atexit`, `at_quick_exit`, `pthread_atfork`,
  `__stack_chk_fail_local`, and for older glibc the stat and mknod
  wrappers (≤ 2.32) and `__libc_csu_init`/`__libc_csu_fini` (≤ 2.33),
  compiled from `lib/libc/glibc` with upstream's flags and include
  directories, built and cached like the runtime libraries above. Every
  glibc executable and shared library links it, as upstream: Zig externs
  name its functions too (`atexit`, and before glibc 2.33 `stat` and
  `fstatat`; upstream's test/standalone/glibc_compat). A build of Zig
  only whose upstream zig is missing or not 0.17.1 links without it
  rather than failing. It is a link input, and a first build that
  replays a donor with link inputs does so eagerly and records in full,
  since a log keeps the donor's paths: hello with `-lc` from a fresh
  local cache took about 80 ms instead of 25. The runtime libraries are
  the exception (`Incremental.donorSharesLinkInputs`, 2026-11-05): their
  paths under `<global>/bs/o/` name their contents, so a donor that
  links the same ones (the C++ runtime's three and libc_nonshared.a)
  and nothing else replays lazily. Hello with `-lc` takes 15–19 ms
  again, Zig with `-lc++` 24–31 ms instead of 96–108; a project's
  objects, archives and shared libraries, and C objects, which are in
  the local cache, keep the donor eager. SDL's
  `libSDL3.a` calls `atexit`;
  a shared library whose C calls `atexit` imported it unversioned
  before, which no loader resolves (test/link_input/so_libc.c).
- **Exceptions** need the objects' `.eh_frame` and `.gcc_except_table`
  and `__dso_handle`, which are the link thread's stage B (`c-frames`).
  test/link_input/cxx.cpp throws through three frames with a
  `std::string` cleanup, catches by type, reads `typeid(...).name()`,
  and has a static constructor and `thread_local` values with dynamic
  initializers; build.zig's "bs build-exe -lc++ with a C++ source"
  expects upstream's output.
- **Cost** (ReleaseFast, test/link_input's `cxx_main.zig` with `cxx.cpp`,
  `-lc++ -target x86_64-linux-gnu`, against upstream): empty caches
  11.7 s (upstream 41.7 s, which also builds compiler_rt, glibc's stubs
  and its own Zig); a new local cache with a warm global one 0.75 s
  (1.04 s); unchanged 0.007 s (0.39 s); a `.cpp` edit 0.62–0.68 s
  (0.90–1.07 s), nearly all of it Clang on libc++'s headers; a Zig edit
  0.12 s (0.39 s). Builds without C++ do not change.

### Step 5: musl, as built (2026-11-05)

`-lc` with a musl target (`-target x86_64-linux-musl`, and plain
`x86_64-linux` and `aarch64-linux`, whose default ABI is musl) links
musl statically, as upstream does; flow (neurocyte's editor) defaults
to it. `-dynamic` with musl is `[unsupported]`. The glibc paths do not
change.

- **libc.a and crt1.o** (`src/Musl.zig`, copied from upstream's
  `src/libs/musl.zig` with its notice): the source list (1053 files on
  x86_64, where an architecture's directory replaces the generic source
  of the same name), compiled by upstream's Clang as runtime libraries
  (`CSource.musl_crt1`, `musl_libc`). They use the flags of upstream's
  sub-compilation: ReleaseFast `-O2 -DNDEBUG`, no PIC, `-fno-builtin`,
  function and data sections, no stack protector or sanitizer, then
  musl's `addCcArgs`, with `-O3` for `src/string` and `src/internal`
  and `-Os` elsewhere, and `-DCRT` for crt1. They are cached under
  `<global>/bs/o/<key>/` like libc_nonshared.a, keyed by upstream zig and
  every command line. Two sources that share a stem (`clone`) compile in
  numbered directories. There are no crti/crtn objects, as upstream.
- **zigc**: upstream's `lib/c.zig` replaces the musl sources that libc.a
  leaves out (`memcpy`, `malloc`, much of math and string). It is a
  module of the compilation (`Frontend.zigc`, an analysis root,
  `Zcu.rootFiles`), as upstream's `wantsZigC` makes it.
- **Link**: user objects, C objects, crt1.o, the C++ runtime libraries,
  libc.a, compiler_rt. crt1.o comes after the C objects rather than
  first as in upstream's command line. It is a link input of the cache
  in `CSource.objectPaths` order, so `Emit.sync` and the relink lay out
  the same bytes, and the order changes nothing a program means (no
  `.init` pieces). The output is a static non-PIE ET_EXEC, and builtin
  says `link_libc`, `.static` and `abi = .musl`.
- **Cache**: musl executables use the on-disk cache like glibc ones,
  with libc.a and crt1.o as link inputs, and donors: one whose builtin
  differs only in musl's `link_libc` (`-target x86_64-linux-musl`
  against `-target x86_64-linux-musl -lc`, or the native target against
  either) shares the donor key. Before two fixes it replayed wrong code:
  `Io.Threaded.addBuf` kept its `usize` iovlen where musl's is `u32`
  (a function's body now depends on its declaration's value,
  `Graph.addOwnNav`), and std's `Syscall.fail` instances kept the
  donor's offset into `Thread` from their inlined `finish` (an inline
  result now covers the layouts the body read, `Emit.layoutsHash`), so
  every write to stderr panicked (test/run/donor_musl_libc.sh).
- **C and C++ sources** target `<arch>-linux-musl` without `-fPIC`.
  libc++ adds `-D_LIBCPP_HAS_MUSL_LIBC=1` and, as upstream, no
  `HAVE___CXA_THREAD_ATEXIT_IMPL`, which glibc gets only from 2.18.
- **translate-c** takes the triple's ABI (`x86_64-linux` is musl, with
  or without `-lc`), and with `-lc` musl's headers from the lib
  directory and `-fno-PIC`, without `__GLIBC_MINOR__`. Output matches
  upstream's for stdio, pthread, errno and socket on both targets.
- **Conformance**: `run.py --std --musl` builds std's tests with
  `-lc -target <arch>-linux-musl` against `baseline/std-<arch>-linux-musl-libc.json`:
  3369/3369 on x86_64, and 3330/3331 on aarch64 under qemu, where bs
  skips `process.lockMemoryAll`, whose `mlockall` upstream's test
  binary passes (a small program passes with both). `--cases` no longer maps `link_libc` cases to
  gnu, so hello_world links musl, as upstream's does.
- **flow** builds with its default target, renders the same screens
  as upstream's build in a terminal (tmux captures with colors, before
  and after editing and searching), and passes its tests (658/660, 2
  skipped, as upstream).
- **Cost** (ReleaseFast bs, against upstream 0.17.1, x86_64): hello
  in Zig with `-lc -target x86_64-linux-musl`, empty caches: 6.1 s
  (upstream 21.3 s, which also builds compiler_rt and its own zigc).
  With a warm global cache and a new local one: 0.25 s (0.42 s), since
  without a donor the build analyzes zigc and std in full. Unchanged:
  0.027 s (0.37 s). A Zig edit: 0.045 s (0.43 s). std's tests with
  `--musl`: 16.6 s cold (41.2 s). flow (`zig build`, its default
  `<native>-linux-musl`, a warm global cache): new local cache 137 s
  (161 s), unchanged 1.6 s (2.2 s), a Zig edit 1.8 s (11.8 s), a `.cpp`
  edit in thespian 3.0 s (13.6 s). Builds without musl do not change:
  std without libc took 6.12 s against main's 6.05 s, within the noise.

### Steps and checks

1. `-lc`: builtin, start file, abilists imports, dynamic executable link,
   `run.py --std --libc` (std's tests built with `-lc -target
   x86_64-linux-gnu`, upstream's test-matrix entry, against a new baseline
   `baseline/std-x86_64-linux-gnu-libc.json`). Tests: a `-lc` program
   calling libc functions and reading `environ` and `stdout`, under
   `test/run`, compared with upstream.
2. `bs translate-c` (CLI and `--listen=-`), the translate-c binary, the
   translation records; a `b.addTranslateC` project under `bs build`,
   including a header edit (one rebuild, no rebuild when unchanged).
3. C sources through upstream `zig clang`, ubsan_rt, `.o`/`.a` inputs
   (with the link thread), system libraries, C-only libraries,
   forwarded `cc`/`ar`; the excluded corpus projects (http.zig, libxev,
   zzz, zio, tokamak, zig-json, zigmod, Avalanche, zedis, supermd, buzz,
   Ghostty's app) move into the corpus as they build.

Each step's branch passes `zig build test test-upstream test-build`,
conformance with `BS_CACHE_CHECK=1` (behavior `--edit-verify`, std, and
from step 1 std with `-lc`), the std compile-time comparison with main,
and `zig build -Dtarget=aarch64-macos`.

## `builtin` and conformance

- bs generates the `builtin` module itself (`src/Builtin.zig`).
  `zig_backend` is upstream's Debug default for the target, whatever
  `-fllvm` says: `.stage2_x86_64` on x86_64-linux, `.stage2_llvm` on
  aarch64-macos (decided 2026-11-03) and aarch64-linux. std and `test/behavior` then take
  the paths they take upstream, and the conformance baseline stays
  comparable. Where upstream's semantics depend on the backend, Sema
  follows the target's (a packed field pointer's host size, for one); the
  rest of aarch64-macos's `builtin` is upstream's `--show-builtin` for
  `-target aarch64-macos` (apple_m1, macOS 15.0, libc linked, PIE), and
  aarch64-linux's is x86_64-linux's with upstream's generic aarch64 CPU.
  The macOS versions are the target's (`aarch64-macos.13.0`, a
  `...` maximum) over the 15.0–27.0 default, and a native build on a Mac
  resolves the host through `std.zig.system.resolveTargetQuery`, as
  upstream: the running system's version as both minimum and maximum
  (`main.checkTarget`, `Options.macos_version`, part of the cache key).
  The same versions reach builtin, LC_BUILD_VERSION's minos, C's
  `-mmacos-version-min` and translate-c's target (`CSource.macosTarget`).
  LC_BUILD_VERSION's sdk is the `SDKSettings.json` version of the SDK the
  build links against, as upstream's linker reads it: the system SDK's
  for a native build when Xcode or the Command Line Tools are installed,
  else the zig lib directory's (27.0) (`CSource.darwinSdkVersion`);
  objects record none, as upstream's.
- Conformance is measured per test: the number of `upstream/test/behavior`
  tests bs compiles and passes, divided by the number upstream 0.17.1 passes
  on the same target with the same backend.
- `tools/conformance/run.py` measures it: it builds bs, prints one summary
  line per target, and writes a per-file, per-test JSON breakdown to
  `.zig-cache/conformance/<target>.json`. `run.py --upstream` recomputes the
  committed upstream baseline, `tools/conformance/baseline/<target>.json`.
  The `-target` is upstream's test-matrix entry: `x86_64-linux-none` (no libc,
  baseline CPU, self-hosted backend), `aarch64-macos-none` and
  `aarch64-linux-none` (Debug default there is LLVM). An x86_64-linux host
  runs aarch64-linux binaries under qemu's user-mode emulator as a
  Cortex-A53, an ARMv8.0 core like the generic baseline, so instructions
  past it trap; `zig build test` does the same for the run tests that list
  aarch64-linux, when qemu is on PATH. Binaries linking glibc (`--libc`,
  run tests with `libc: true`) run with the aarch64 glibc as qemu's
  sysroot (`-L /usr/aarch64-linux-gnu`), and are not run without it.
- Each file `behavior.zig` imports is its own unit: one `bs test` compile and
  one run, in parallel with the others, so a compile error, crash, or timeout
  costs only that file. The root is a generated `behavior.zig` wrapper next to
  a `behavior` symlink, so namespaces and test names (`behavior.basic.test.x`)
  equal those of upstream's full build (`typename.zig` and
  `string_literals.zig` check `@typeName` results that include the
  namespace). `behavior.zig`'s own tests run from the real file with
  `--test-filter behavior.test`. The baseline run also builds all of
  `behavior.zig` at once and checks that the per-file results are identical.
- The harness passes the compiler a test runner with `--test-runner`
  (default `tools/conformance/test_runner.zig`; for bs on x86_64-linux,
  `bs_runner.zig`, which has its own `_start` and system calls) and parses only the runner's
  `@bs-test` line protocol on stdout, documented in that file. A test that
  crashes or times out is recorded and the binary is rerun with
  `--start=<next>`. Until bs compiles the default runner, which mirrors
  upstream's per-test setup (`testing.allocator`, `testing.io`), it can use a
  smaller runner that speaks the same protocol; tests are matched to the
  baseline by name, so bs must produce upstream's test names.
- `run.py --default-runner` measures `bs test` as a drop-in for `zig test`:
  no `--test-runner`, so bs builds upstream's own
  `lib/compiler/test_runner.zig`. The binary runs as `zig test` runs it and
  its terminal output (`1/9 name...OK`, leak reports, the summary line) is
  parsed; after a crash or timeout, the remaining tests run one at a time
  through the runner's `--listen=-` protocol (`std.zig.Server`, as
  `zig build test` drives it). Report both numbers.
- `run.py --std` is the next measure: upstream's std tests,
  `upstream/lib/std/std.zig` built as one `bs test` unit with the default
  runner, `--zig-lib-dir upstream/lib` (the source tree; the binary
  release's `lib/` lacks std's testdata), and the same `-target`, as
  `zig build test-std` builds its Debug entry. When the root is
  `<zig_lib_dir>/std/std.zig`, the root module is std itself (upstream's
  `main_mod_is_std`), not a second copy of it. Results are parsed as with
  `--default-runner` and compared per test with the committed
  `baseline/std-<target>.json`; `run.py --upstream --std` recomputes it,
  including a cold compile time from a fresh zig cache. The baseline CPU
  matters: upstream built for the host CPU runs two fewer tests (the
  bitsliced AES cross-checks) and runs `math.lerp`, which it skips without
  FMA.
- `run.py --cases` measures the rest of upstream's `test/cases`: the run
  cases (with `test/cases/safety`, whose panic handlers exit 0 only for
  the expected panic message), the compile cases, and the few error
  cases outside `compile_errors`, those whose targets include bs's and
  whose backends include the self-hosted one (170 on x86_64-linux). Each
  is built as upstream's case harness (test/src/Cases.zig) builds it:
  root `tmp.zig` in module `root`, Debug, the manifest's `-target`
  verbatim (`native` when it names none; with `link_libc` and
  `x86_64-linux`, musl, as upstream). A run case passes when its binary exits 0 with the
  manifest's stdout, a compile case when it builds, an error case when
  `--compile-errors` would call it exact. `run.py --upstream --cases`
  records upstream's results in `baseline/cases-<target>.json`, and the
  measure is the share of upstream's passes that bs passes.
- `run.py --standalone` measures upstream's `test/standalone`: each
  project (63) is copied to the workdir and built there with `build`, its
  default step, which is what upstream's standalone step runs, so its
  cache stays inside it as in upstream's tree. A project passes when the
  build succeeds. It is unsupported when every failed step failed on a
  bs `[unsupported]` diagnostic (another target or libc, LLVM, shared
  libraries, `-femit-asm`, `-fstrip`, linker scripts), and fails
  otherwise. `run.py --upstream --standalone` records upstream's results
  in `baseline/standalone-<target>.json` (ios needs an iOS SDK and tsan
  does not build there), and the measure is the share of upstream's
  passes that bs passes, with the unsupported ones counted apart.
- `run.py --langref` measures upstream's language reference examples
  (`doc/langref`, 290 with a manifest; 286 on x86_64-linux, the rest
  wasm or windows; 283 on aarch64-linux and aarch64-macos, which also
  skip the three that name x86_64-linux). Each is built from the workdir
  as upstream's tools/doctest.zig builds it, from its manifest's kind and
  options, and a built exe is run. Under an emulator (aarch64-linux on an
  x86_64 host) a test is built with `--test-no-exec` and its binary run
  under the emulator, as `test` would run it. bs matches upstream when the outcome is the same:
  both build or both fail, a failure's first error (file, line, column,
  message), an exe's exit status, stdout and normalized stderr (addresses
  and anonymous type numbers taken out), a test's exit status, summary
  and first panic line. `run.py --upstream --langref` records upstream's
  outcomes in `baseline/langref-<target>.json`; the measure is the share
  that matches, with the examples bs refuses (`-OReleaseFast`) counted
  apart.
- `run.py --incremental` runs upstream's `test/incremental` cases (49):
  each is a sequence of updates (files written or deleted) with the
  stdout or compile errors expected after each. bs builds the updates in
  turn in one directory with its own cache and no donors (unless
  `BS_CACHE_DONOR` is set), each after the first an edit
  build that `BS_CACHE_VERIFY=1` and `BS_CACHE_CHECK=1` check against a
  full build; errors are compared as upstream's harness renders them (no
  source lines or reference traces). With `BS_CACHE=off` every update is
  a full build, which tells analysis failures from the cache's.

## Diagnostics (designed 2026-11-03, accepted by the owner; being built)

Two owner decisions (AGENTS.md) shape this section: bs's main users are
coding agents, so compile errors are shaped for them; and bs may reject
more than upstream, as long as everything else upstream accepts keeps its
meaning and upstream's std and `test/behavior` still compile. `zig build`
integration comes after it.

The owner's review (2026-11-03) settled:

1. Text by default, JSON lines with `--error-format=json`.
2. Upstream's wording stays where it's clear; the code, candidates,
   hints, notes and fixes are added around it.
3. Fail early, as upstream: no recovery. A failed unit still fails its
   dependents silently. More compile cycles are fine because bs is
   fast, and the cache change below makes each cycle cheap. (AstGen
   errors first stopped the build before Sema. Upstream does that only
   when a file cannot be lowered, so since 2026-11-04 bs analyzes
   after the others too, with replay; see "AstGen" below.)
4. No error limit.
5. No bs-only checks and no `-fanalyze-unreferenced` for now. Their
   measurements stay below as background, marked not adopted.
6. A failing build commits the manifest for the units that succeeded, so
   the build after an error isn't cold.

### What agents get today (measured)

A three-function program with three independent mistakes an agent makes in
0.17 (`std.io`, `std.ArrayList(u8).init(gpa)`, returning a `usize` as
`u32`) shows the problems. Both upstream and bs:

- **report one error per build.** `main` calls `try greet()`, so `main`
  depends on `greet`'s inferred error set. `greet` fails, so `main` fails,
  and `collect` and `count` are never analyzed. The agent needs three
  compile cycles for three independent errors. Likewise, any AstGen error,
  even "unused function parameter", stops the build before Sema, so no
  semantic error is shown with it. (The owner kept this fail-early
  behavior; see decision 3.)
- **spend tokens on noise.** Upstream adds a reference trace through
  `std/start.zig` (four frames plus "2 reference(s) hidden"), a caret line
  per location, and a note "struct declared here" pointing at
  `std.zig:1:1`, whose source line is `pub const AutoHashMap = ...`. bs
  prints three "called inline here" notes through `start.zig` instead.
  Upstream's output for the three errors (one build each) is 642 tokens
  (o200k tokenizer).
- **omit the facts the agent goes looking for.** "has no member named
  'io'" gives no candidate (`Io`). The rename of `std.ascii.indexOfIgnoreCase`
  to `findIgnoreCase` gives none either, and neither says what replaced a
  removed API. A type mismatch prints an inferred error set as
  `@typeInfo(@typeInfo(@TypeOf(a2.leak)).@"fn".return_type.?).error_union.error_set!u32`.

API drift is likely the largest class of agent mistakes in Zig, since
models are trained on several std versions. That's not measured across
agents; the corpus below should track it. Writing this section's scratch
tools hit three drift errors (`Ast.parse` options,
`std.ascii.indexOfIgnoreCase`, `std.fs.cwd`), and none of the messages
named the replacement.

The accepted form carries more facts (candidates, a migration hint, the
declaration of `n`, a fix, a user-code reference) in 304 tokens for the
same three errors. Since bs fails early as upstream does, they still
take three builds; the listing shows them together:

```
e.zig:4:21: error[no-member]: 'std' has no member named 'io'
  | const out = std.io.getStdOut().writer();
  candidates: Io
  hint: std.io was replaced by std.Io; stdout is std.Io.File.stdout().writer(io, &buffer)
  ref: main e.zig:20:14
e.zig:9:33: error[no-member]: 'std.ArrayList(u8)' has no member named 'init'
  | var list = std.ArrayList(u8).init(gpa);
  candidates: initCapacity, initBuffer, empty
  hint: std.ArrayList is unmanaged: `var list: std.ArrayList(u8) = .empty;`, then pass the allocator to each call (`list.append(gpa, x)`, `list.deinit(gpa)`)
  ref: main e.zig:21:16
e.zig:16:12: error[type-mismatch]: expected 'u32', found 'usize'
  | return n;
  note: u32 cannot represent all usize values
  note e.zig:13:29: return type declared here
  note e.zig:14:9: 'n' declared here: var n: usize = 0;
  fix? e.zig:16:12-16:13: "@intCast(n)"
  ref: main e.zig:22:14
3 errors
```

The same three records as JSON lines are 428 tokens (cl100k: 633, 301 and
414 for upstream, text and JSON).

### Lessons from other compilers

- **rustc**: a stable code per error (`E0308`, lint names such as
  `unused_variables`), a primary span plus labeled secondary spans,
  `help`/`note` children, `rustc --explain` for long explanations, and
  `--error-format=json` with byte and line/column spans and suggestions
  graded by applicability (`MachineApplicable`, `MaybeIncorrect`,
  `HasPlaceholders`, `Unspecified`); `cargo fix` applies only the first
  kind. bs takes all of this. The human rendering (ASCII art,
  multi-line labels) costs tokens without adding facts.
- **Go**: compiler errors are one `file:line:col: message` line each, and
  the compiler rejects some things other languages only warn about
  (unused imports and variables), which is the precedent for bs's extra
  errors. `go vet` analyzers report `Diagnostic{Pos, End, Category,
  Message, SuggestedFixes []{Message, TextEdits}, Related}`, and `go
  test` runs only a high-confidence subset of vet automatically. Checks
  that fail a build must be nearly free of false positives.
- **Elm**: every error says what it found, what it expected, and what to
  try ("These names seem close though:" with candidates, plus "Hint:" lines
  that teach the language), and `--report=json` exposes the same content.
  bs takes the candidates and hints, not the conversational prose.
- **TypeScript**: numeric codes (`TS2322`), a compact non-pretty mode
  (`file(3,5): error TS2322: ...`), an elaboration chain for nested type
  mismatches ("Type 'X' is not assignable to type 'Y'. Property 'z' is
  missing..."), `relatedInformation` locations, and code fixes served
  by the language service. bs takes the chain for nested mismatches
  (a field of a struct literal, a parameter of a function type) and the
  related locations.

Codes are mnemonic names (`no-member`, `type-mismatch`), as rustc's lint
names and Go's analyzer names are, rather than numbers. An agent can read a
name without looking it up, and the name costs one to three tokens.

### Output form

**Recommendation: text by default, JSON lines with
`--error-format=json`.** Both render from the same record, so neither form
has a fact the other lacks; JSON adds byte offsets. Text is the default
because:

- an agent reads the compiler's stderr directly in a shell tool, and
  measured on the example above, text costs 29% fewer tokens than the
  same JSON;
- models read compiler text well, trained on rustc, gcc and upstream zig
  output;
- the first line of each error keeps the universal
  `path:line:col: error...:` shape, so editors' problem matchers, `grep`,
  and agent harnesses that parse upstream's output keep working.

JSON is for programs: harnesses that apply fixes, editors, and a later
`bs fix`.

**Text grammar.** One error is a header line followed by indented detail
lines, each starting with a keyword:

```
<path>:<line>:<col>: error[<code>]: <message>
  | <primary source line, indentation trimmed>
  note[ <path>:<line>:<col>]: <message>[: <declaration source line>]
  candidates: <name>, <name>, ...
  hint: <one line>
  fix[?] <path>:<line>:<col>-<line>:<col>: "<replacement text>"
  call: <path>:<line>:<col> inline|comptime|generic, ..., +<n> std
  ref: <fn> <path>:<line>:<col> <- <fn> <path>:<line>:<col> (+<n> std frames)
  in <n> instances: <comptime args of the first ones>
```

The output ends with `<n> errors`; there is no limit. Lines and columns are 1-based, and columns count
bytes, as upstream. `fix` is exact (apply as is); `fix?` is valid code
that may not be what the author meant, or has a placeholder
(`@panic("TODO")`). The replacement is a Zig string literal, so
insertions of whole lines (`"    _ = x;\n"`) and deletions (`""`) read
unambiguously; equal ends mean an insertion. A fix with several edits
prints one `fix` line per edit, and they apply together. Each edit names
its file, which need not be the error's: an error raised in std about a
user's argument (a `print` argument or `free`'s slice that is an error
union) carries a note at the argument's origin in the user's file and
the fix there (`Zcu.argumentOrigin`). No fix edits a file under the zig
lib directory.

**JSON lines.** One object per error, with short keys:
`{"code", "file", "line", "col", "span": [start, end], "msg", "src",
"notes": [{"file", "line", "col", "span", "msg", "src"}], "candidates",
"hint", "fixes": [{"applicability": "exact"|"maybe"|"placeholder",
"edits": [{"file", "span", "text"}]}], "calls": [{"file", "line", "col",
"kind"}], "ref": [{"fn", "file", "line", "col"}], "instances"}`. `calls`
lists every frame, the lib directory's included. Spans are 0-based byte offsets, end exclusive.
Absent fields are omitted, not null. The last line is
`{"summary": {"errors": n}}`. As with rustc, consumers must
ignore unknown keys.

**Token efficiency rules**, each checked by the corpus tests below:

1. The primary location's source line is printed once, without a caret
   line. The column is in the header, and models misread caret alignment.
   Notes print their source line only when it is a declaration (one line,
   trimmed).
2. Paths are relative to the working directory. Files under the zig lib
   directory print as `std/...` (or `compiler_rt/...`, `lib/...`), not as
   an absolute cache path (about 15 tokens each).
3. Frames in std, `builtin` and compiler_rt collapse into a count. The
   nearest frame in a user module (a module given on the command line
   whose files are not under the zig lib directory) is always shown. When an error's own location is inside std
   (a `std.fmt` format-string error, a comptime `assert`) and the call
   chain reaches user code, the innermost user frame becomes the header
   location, and the std location becomes a note `raised at std/...`.
   That changes only the rendering.
4. Identical errors from several generic instances of one source location
   render once, with `in <n> instances:`.
5. Cascades are not reported: a failed unit fails its dependents
   silently, as upstream.
6. Types print in full, as fully qualified names with generic arguments,
   but an inferred error set prints as its names when it has at most six
   (`error{A,B}!u32`), else as `<fn>'s error set (<n> names)`. A type
   printed in full once may be referred to by name in the same error.
7. No color unless stderr is a terminal (upstream's `.auto` already does
   this).
8. Long explanations live behind `bs explain <code>` (a paragraph, an
   example, the usual fix), not in the output.

### The diagnostic record

`src/diag.zig` holds the record, the codes, and the text and JSON
renderers. Sema keeps recording `Zcu.ErrorMsg` (file, absolute
`Ast.Span`, message, notes), which gains a `code`, and notes gain `call`,
which marks a call-site frame (`Zcu.addCallFrame`, from `noteCallSite`).
An error or note with `embed` set is located in an embedded file (an
imported ZON file) instead of a frontend file. `@compileLog` output is
`Zcu.compile_logs`, one line per call with its unit; it fails the build
like an error (`Zcu.failed`) and renders after the diagnostics as
upstream's "Compile Log Output:" block (`Diagnostic.log`), with a "found
compile log statement" error and an "also here" note per other logging
unit when nothing else failed.
At the end, `Zcu.diagnostics` resolves every error, AstGen's included
(`diag.fromBundle`), into the record that is rendered:

```zig
pub const Diagnostic = struct {
    code: Code = .unclassified, // enum(u16) with kebab-case tag names
    loc: ?Loc,
    msg: []const u8,
    count: u32 = 1,
    notes: []const Note = &.{},
    refs: []const Ref = &.{}, // the reference trace
    candidates: []const []const u8 = &.{},
    hint: ?[]const u8 = null,
    fixes: []const Fix = &.{},
    log: []const []const u8 = &.{}, // compile log lines, after the diagnostics
    // Later: instances.
};
pub const Loc = struct {
    path: []const u8, // displayed: relative to the cwd, or to the zig lib directory
    line: u32,
    col: u32, // 1-based, bytes
    start: u32,
    end: u32, // byte span, end exclusive
    source_line: []const u8,
    in_lib: bool, // std, builtin, compiler_rt: frames here collapse to a count
};
pub const Note = struct { loc: ?Loc, msg: []const u8, count: u32 = 1, call: ?CallKind = null };
pub const Fix = struct { applicability: enum { exact, maybe, placeholder }, edits: []const Edit };
pub const Edit = struct { path: []const u8, line: u32, col: u32, end_line: u32, end_col: u32, start: u32, end: u32, text: []const u8 };
```

Locations stay absolute spans until rendered. Declaration-relative
locations would matter only for diagnostics loaded from the cache, and the
accepted design caches none: a failed unit is always re-analyzed.

The call line (`call:`) collects the comptime and inline call-site frames,
and the calls whose generic instantiation failed in its parameter or
return types (`generic`, upstream's "generic function instantiated here").
Frames in the zig lib directory print only as a count, and the line is
omitted when every frame is in the lib directory.

The reference trace (`ref:`) is computed when rendering from
`Zcu.referenced_by`: for each analyzed unit, the first unit that referred
to it and where (a call, a function's address or export, a declaration's
value, a type's layout). Sema records it in `noteReference` only for a
unit not yet analyzed or queued (a function's first queueing, which
`Zcu.queueFunc` reports from its existing lookup), so the hot path pays
nothing new; the map costs about 8 MB on the std test build. The site
is a lazy `Src` resolved only when an error is rendered. Each error records its failed unit, and the trace follows
first references from it until a unit nothing referred to. It prints by
the call line's rule (`ref: main ret.zig:6:12 (+3 std frames)`); JSON
lists every frame. First references are deterministic because analysis
order is; parallel function bodies will need the smallest unit key
instead. Gap: in an edit build, a referrer loaded green from the cache
records nothing, so its frame is missing. Closing it needs the manifest
to keep each unit's first reference site, alongside step 6.

Notes that point at declarations (`decl` in the record) show the
declaration's source line after the message: `function return type
declared here: fn len(n: usize) u32 {`. As upstream's `fail`, every
declared type an error's message names gets a "struct declared here"
note.

**Codes.** Each code is a kebab-case name, never renamed or reused once
released; a retired code stays reserved. A code names a kind of error, not
a call site. Sema, the linker and the backends make about 470 errors from
about 300 distinct formats, which group into 50 codes (`diag.Code`).
An error's kind follows from its wording, so the code comes from the
format string, not the call site: `Zcu.addError` and `Sema.fail` look it
up at comptime in `diag.format_codes` (`diag.formatCode`), which costs
nothing at run time and leaves the call sites unchanged. Formats starting
with "bs " (what bs does not support yet) are `unsupported`. The rare
format that needs another code passes it explicitly (`Sema.failCode`,
`Zcu.addErrorCode`); ZON's errors take their inner message's code that
way. A unit test tokenizes Sema.zig, Zcu.zig and Emit.zig and fails on any
error format without a code, so a new format needs a table entry.
AstGen has 186 error sites with 118 distinct formats; its codes come from
a table of upstream's message formats (pinned at 0.17.1, so the table is
complete), matched against the rendered message, and a test extracts
every format string from `AstGen.zig` and checks that each one maps to a
code.

**Facts**, computed only on the error path from data Sema already has:

- *Failed lookups* (`no-member`, `undeclared`, `no-field`): candidates
  with Damerau-Levenshtein distance at most 2, and at most a third of the
  name's length so that short names do not match everything (rustc's
  rule), or a case-insensitive match (`io` → `Io`); restricted to `pub`
  names across files, closest first, at most 5; all field names when a
  type has at most 8; and the migration hint below. A member lookup
  considers declarations and an enum's or tagged union's tags, a field
  lookup the fields, a method call both (`diag.closeNames`,
  `Sema.addCandidates`). They read the whole namespace, so the failing
  unit declares a `namespace` dependency.
- *Type mismatches*: both types in full, the declaration that fixed the
  expected type (return type, parameter, variable type) and the
  declaration of the value's origin (a local or parameter, with its source
  line). Nested mismatches (a field of a struct literal, a parameter of a
  function type) are an elaboration chain of notes, as in TypeScript.
- *Calls*: the callee's signature line and location on argument-count and
  argument-type errors.
- *Switches*: the missing tags (and a placeholder fix adding their prongs).
- *Comptime*: the comptime call chain, compressed as in the token
  efficiency rules.
- *Migration and pattern hints*: a curated table keyed by (container,
  missing name) or by builtin name, holding the 0.17 replacement for APIs
  and syntax models still emit (`std.io`, `ArrayList.init`,
  `std.fs.cwd`, `std.mem.indexOf*` to `find*`, `@intToEnum` and the other
  pre-0.11 builtin names, `usingnamespace`, `async`). It's seeded by
  diffing the `pub` declaration sets of std between upstream releases 0.11
  and 0.17 (a script in `tools/diag/`), with the replacement text written
  by hand and checked against 0.17's std. Expect a few hundred entries.
  `tools/diag/std_removed.py` takes the lib/std directories of older
  releases and 0.17's and lists what 0.17 lacks, collapsed to the
  outermost missing container and ranked by how often the old std used
  it. Over 0.11, 0.13, 0.14.1 and 0.15.2 it lists about 5300 entries,
  most of them internal (std.os.windows, Build internals); `std.io`
  leads by far (1305 uses), then `posix.close`, `crypto.random`,
  `fs.cwd`, `mem.page_size`. The table (`diag.migrations`) starts with
  the most used public ones: 43 API entries, a `*` entry per container
  whose misses share one answer (`os`, `posix`, `lang.Type`), and 14
  builtins. Every replacement was compiled with upstream 0.17 and bs.
  Not yet covered: `usingnamespace` and `async`, which are parse errors,
  and arity-change patterns such as `list.append(x)` on an unmanaged
  list.

**Fixes bs knows**, first set (step 5, built):

| error | fix | applicability |
|---|---|---|
| unused local constant (AstGen) | insert `_ = name;` after the statement: on the next line, or on the same line when more follows it there (`{ const w = 5; }`) | exact |
| unused local variable (AstGen) | the same, plus `var` → `const` (unused means never mutated too) | exact |
| unused function parameter (AstGen) | insert `_ = name;` at the start of the body | exact |
| unused capture (AstGen) | a switch prong's only capture and `catch \|err\|` go (`\|_\|` there is "discard of capture"); an `if`/`while` `else \|err\|` becomes `\|_\|`, since dropping it makes the operand an optional; a `for` counter goes with its `0..` input; other captures become `_` | exact |
| unused switch tag capture (AstGen) | drop `, tag` | exact |
| unused block, loop or switch label (AstGen) | drop `label: ` | exact |
| local variable is never mutated (AstGen) | `var` → `const` | exact |
| pointless discard (AstGen) | delete the `_ = name;` statement, and its line when it is alone there | exact |
| invalid builtin `@intToEnum(T, x)` and the other renamed builtins with a direct replacement (10) | `@as(T, @enumFromInt(x))`, `@intFromEnum(e)`, ... | exact |
| error union ignored or discarded, where the function returns an error union | insert `try ` (`_ = try ` for a statement whose payload is not void); none inside `defer` | maybe |
| integer or float mismatch | wrap in `@intCast`, `@floatCast`, `@floatFromInt` or `@intFromFloat` | maybe |
| failed lookup (undeclared, member, field, method) with one candidate at distance 1 or differing in case, and no migration hint | rename | maybe |
| switch must handle all possibilities (enum, tagged union, error set) | add `.tag => @panic("TODO"),` or `error.X => @panic("TODO"),` prongs | placeholder |

AstGen's fixes are computed in `diag.fromBundle` from the failing file
read and parsed again (as for its candidates), and only when the line
AstGen reported is unchanged in it. Sema's are computed when the error is
made, from the file's AST, and travel in `Zcu.ErrorMsg.fix`; each one
checks that its span is exactly one expression (`diag.isExpression`)
before wrapping it. Under `bs build` every edit becomes a location-less
note in the error bundle, worded as the text line.

Reaching upstream's messages for these errors also took four checks bs
lacked, all upstream's: a call statement's ignored result (`f();` with
an error union or a non-void value; bs checked only non-call
expressions), `_ = f();` on an error union ("error union is discarded"),
`if (x) {} else |err|` with a non-void payload ("error union payload is
ignored"), and error-set switches without `else` ("unhandled error value"
notes; `anyerror` needs `else`). The enum case gained upstream's
"unhandled enumeration value" notes at each field.

### Where errors come from, and what changes

- **AstGen** errors are upstream's AstGen unchanged. Frontend collects them
  as ErrorBundles (`loadAll`'s bundle and `late_errors`). bs converts each
  message into a Diagnostic: its code from the format table, its fix from
  the table above. As upstream, the build stops before Sema only when a
  file could not be lowered (`Zir.loweringFailed`: a syntax error, an
  unreadable import). Otherwise Sema runs and its errors follow
  AstGen's: an agent gets "unused local constant" and the type errors
  in one build. A declaration AstGen could not generate is an
  `astgen_error` instruction, which fails the declaration and the units
  that read it with no error of their own. Such a build replays like any
  failing build and emits and records nothing. A one-line edit that adds
  an unused variable to a std.debug.print program builds in 18–22 ms
  (the stop-after-AstGen build took 15–19 ms); without a cache it is a
  full analysis.
- **Sema** errors go through `sema.fail`/`addNote` into `zcu.errors`,
  which are sorted by unit key and position at the end (see "Parallel
  function bodies"). `Zcu.renderErrors` and `main.renderErrors` turn them
  into an ErrorBundle. They become `Diagnostic`s, and
  `src/diag/render.zig` renders text or JSON. `noteCallSite`'s "called
  inline here" notes become `ref` frames, so the collapsing rules apply to
  them.
- **ErrorBundle is not enough** as the record: it has no code, no fixes,
  and only strings for facts, and it bakes absolute line and column in at
  creation. It stays as the input format for AstGen's errors, and it
  becomes the output for `--listen` (`std.zig.Server`, which `zig build`
  uses) when bs gets that mode with `zig build` integration. In that
  output the code becomes a message prefix (`[no-member] ...`), and facts
  and fixes become notes.
- **No recovery.** A failed function fails its dependents silently, as
  upstream (owner decision). A proposed poison error set for failed
  callees, which would have shown independent errors in one build, is not
  adopted.

### Errors and the cache

Today a failing build records nothing: `exitOnErrors` exits before
`Incremental` records the manifest, so the build after a compile error is
cold. An agent's loop is edit, compile, read errors, so this is the build
an agent waits for most. The change:

- **A failing build commits its manifest** for every unit that succeeded,
  and records failed units as failed nodes with no result. A failed node
  is always red: an edit build re-analyzes it, which regenerates its full
  diagnostics by construction. Its dependents that failed with it are red
  too. Failed units are few, so this costs little and needs no serialized
  form for failures.
- **A unit that succeeded has no diagnostics**, so no result entry stores
  any. (If bs-only checks are adopted later, their diagnostics would be
  stored in the unit's result entry with declaration-relative `Loc`s and
  replayed when it loads green.)
- **A no-edit rebuild of a failing build** is an edit build with no seeds.
  It loads every green unit, re-analyzes only the failed ones, and prints
  the same diagnostics. There is no relink.
- **AstGen errors** are already in the ZIR cache entry, keyed by content.
- `BS_CACHE_CHECK` also compares replayed diagnostics with a fresh
  build's, as rendered text, byte for byte.

**How it meets replay step 4b** (agreed with the cache thread; to be
built after 4b lands):

- *Emit, then record as usual.* After Sema errors, Emit finishes partly:
  merge the jobs, stop the workers, lower the declarations and group the
  atoms, but skip extern slots, the error table and the entry check. If
  lowering itself fails, nothing is recorded. Marking green functions as
  still needing codegen does not work: a green function keeps no IR, so
  generating its code means analyzing it again.
- *No link.* Record writes entry 0, no link node, and no `noteOutput`.
  A `failed` bit in `Manifest.Flags` marks failed nodes, counted like
  `base_unlinked`; `relinkIfUnchanged` refuses while the count is not 0,
  so a no-edit build after an error never relinks the last good binary.
- *Failed always loses.* Failed nodes are seeded like `stale` ones, and
  `Replay.greenNode` answers red for a failed node before any other
  check. A failed unit is recorded with its deps and refs and no
  result, so the walk reaches it along the cold build's edges. On a
  failing lazy build, a fallback from `recordDelta` skips the record
  instead of rebuilding eagerly: the diagnostics are already final.
- *The reference trace.* Each node records its first referrer (node and
  span; the file follows from the referrer) in a base section and in
  `NodeDelta`, and Replay supplies `referenced_by` from it for units it
  hands to analysis that nothing in this build referred to. Recording a
  node again keeps its old referrer while that one still refers to it,
  so a lazy build names the same first referrer as a cold build.
- Error order needs nothing: `zcu.errors` is sorted by unit key and
  position, so the same failed set prints in the same order.

### Extra errors: bs-only checks (not adopted; background)

The owner decided against bs-only checks for now (2026-11-03). This
subsection keeps the framework that was proposed and the measurements
behind it, for when the question comes back.

**Framework (proposed).** A check is a pass over a function's typed IR, plus its
file's AST and the InternPool, and runs right after Sema produces that IR,
in the same worker, before CodeGen. Each check lives in its own file in
`src/check/` and reports `Diagnostic`s with its own code. The header
names it as bs-only (`error[leak-on-error, bs-only]`) so that an agent
or a person knows why upstream accepts the program. Checks:

- run only on **checked modules**: modules given on the command line (the
  root and `-M` modules) whose files are not under the zig lib directory.
  Never std, `builtin` or compiler_rt, even when std is the root module
  (`run.py --std`). With `zig build` integration, only the root package's
  modules count, not dependencies from the package cache. `test/behavior`
  files are root modules in conformance runs, so they are in scope, and
  conformance with checks on is the first precision gate.
- run on inlined code only when the inline callee's file is checked, and
  report generic instances once per source location. A check whose answer
  depends on comptime arguments runs only on non-generic functions.
- are part of the unit's cached result (above). Check results depend only
  on the unit's IR and its file, so they need no dependency of their own.
- have a source-level way out that is valid upstream Zig and states the
  intent (listed per check), plus `-fno-check=<code>` for a whole build.
  There are no suppression comments: ZIR doesn't see comments, and
  suppressions rot.
- must cost under 2% of Sema time on the libvaxis workload (a linear
  pass over IR), measured with `BS_TIMING`.

The bar for making a check an error: zero findings on `test/behavior`, on
libvaxis, and on upstream's compiler source (the bench workloads), except
real bugs, and few on std (out of scope, but measured with
`BS_CHECK_ALL=1` as a precision report). Go makes the same choice for
the vet checks `go test` runs.

**Candidates, measured** on std (563 files, 483 k lines), the compiler
source (`upstream/src`, 182 files, 545 k lines), libvaxis `src/` (53
files, 22 k lines) and `test/behavior`. The semantic counts come from a
temporary probe in Sema while building std's tests, the compiler, and
libvaxis's tests. The syntactic ones come from a scratch scanner using
`std.zig.Ast`.

| check | std | compiler | libvaxis | behavior | assessment (not adopted) |
|---|---|---|---|---|---|
| `catch unreachable` on a non-empty error set | 258 sites | 315 | 1 | 44 (30 on `anyerror`) | no: almost all deliberate (writes into fixed buffers, known-valid parses) |
| … narrowed: the operand is a direct call into `std.Io`, `std.fs`, `std.posix`, `std.process` or `std.net`, and its error set names an OS error (`FileNotFound`, `AccessDenied`, ...; not `Canceled`, not `anyerror`) | 0 | 0 | 0 | 0 | **yes** |
| `!T` whose inferred error set is empty | 35 functions | 63 | 3 | — | no: configuration-pruned (`builtin.is_test`, OS switches) or kept for interface symmetry |
| allocation not freed on a later error path | 14 (syntactic) | 1 (syntactic) | 0 | 0 | **yes**, semantic form |
| `@intCast` that can truncate | 2170 lines | 4205 | 157 | — | no: narrowing is what `@intCast` is for; Debug checks it at run time |
| unused `pub` declarations | — | 2641 of 8058 `pub` declarations unreferenced | — | — | no: API surface, debug helpers, other build configurations |
| returning a slice or pointer of a local array | 0 | 0 | 0 | 0 | **yes** |
| `defer` frees or deinits what the function returns | 0 | 0 | 0 | 0 | **yes** |

Notes on the evidence:

- *`catch unreachable`, narrowed*: the probe listed every site with its
  error set. Only seven name an OS error: three `Canceled` sets in std's
  Io and test runner, two compiler-internal sets that include `Canceled`,
  `Compilation.zig:4849` (a `resolveTargetQuery` for a non-native target,
  which never touches the OS), and `link/Dwarf.zig:1044` (a debug check on
  a large inferred set). Excluding `Canceled` and requiring a direct call
  into the OS-facing namespaces removes all seven. That's by inspection;
  the check itself must re-measure. In ReleaseFast, which users run
  upstream for, `openFile(...) catch unreachable` on a missing file is
  undefined behavior, so this is a real bug, and it's the shortcut
  agents take. The way out is `catch |err| std.debug.panic("...: {t}",
  .{err})` or handling the error. Fix: `fix?` replacing `unreachable`
  with `|err| std.debug.panic("<callee> failed: {t}", .{err})`.
- *Empty inferred error sets*: in libvaxis all three are
  configuration-pruned (`Loop.installResizeHandler` on non-Windows,
  `_ttyRun` under `builtin.is_test`, `nextEvent` through a queue whose
  `pop` can't fail). In the compiler they're backend hooks such as
  `Select.prepareReturn`, kept as `!void` for symmetry with siblings that
  fail. Rejecting them would make code depend on the target it's built
  for.
- *Leaks*: the syntactic scan flags `const x = try a.alloc(...)` followed
  by a `try` or `return error` before any `defer`/`errdefer` naming `x`,
  ignoring arenas and stopping at any other use of `x` (a possible
  ownership move). All 14 std hits are allocator self-tests or pool
  allocations freed with the pool, and the compiler's one hit is
  `cg.alloc`, a SPIR-V instruction, not an Allocator. The semantic check
  requires the receiver's type to be `std.mem.Allocator`, skips `test`
  blocks (a failing test leaks harmlessly, and the testing allocator
  reports it), and treats passing `x` anywhere as a move. That removes
  every hit above. Exact fix: insert `errdefer a.free(x);` (or
  `a.destroy(x)` for `create`) after the declaration.
- *Dangling returns*: upstream rejects `return &x` for a runtime local, but
  accepts `return buf[0..n]` and `return s` where `s` came from
  `bufPrint(&buf, ...)` on a local `buf`. Both return dangling stack
  memory, and both compile without complaint (checked with upstream 0.17).
  The check follows the IR from a slice or pointer of a runtime local
  array to `ret`. Comptime functions are excluded (returning a comptime
  local is fine). No exact fix: the way out is a caller-provided buffer or
  an allocation.
- *`defer` frees the returned value*: `defer a.free(b); return b;` compiles
  upstream and returns freed memory. Fix (`fix?`): `defer` → `errdefer`,
  which hands ownership to the caller.

**Not a check, but measured: unreferenced code is never analyzed.**
Forcing analysis of every declaration in libvaxis (`_ = &@field(T,
name)` recursively, with upstream zig) gives 27 errors. Four are real
latent bugs that compile today only because nothing references them:
`std.posix.getenv` (Vaxis.zig:1659), `std.debug.FormattedPanic`
(main.zig:52), `std.io` (widgets/TextView.zig:14), and `readCell` doing
`return;` in a function returning `?Cell` (widgets/ScrollView.zig:125).
The rest are Windows-only code and deliberate `@compileError` guards in
zigimg. Agents write a helper, never call it, and see a clean build, so
this matters. But analyzing everything rejects target-specific code, so
it shouldn't be the default. An opt-in `-fanalyze-unreferenced` for
user modules (non-generic functions only) was proposed and not adopted.

### Testing

- **Corpus**: `test/diag/<case>.zig`, one mistake per file, with bs's
  exact stderr in a trailing comment block (`// error`, an optional
  `// args: --error-format=json`, then the expected lines; see
  `addDiagTests` in build.zig). `zig build test` runs
  `bs build-exe -fno-emit-bin <case>` from `test/diag` and compares
  stderr exactly. `zig build test-upstream` checks that upstream rejects
  every case too.
- **Fixes round-trip**: applying every `exact` fix must give a program
  that compiles, or that fails with the case's next expected error.
  `python3 tools/diag/roundtrip.py [--all] test/diag/*.zig` checks it
  (`--all` adds `maybe` and placeholder fixes): no error may remain or
  appear at an edited place, by bs's and by upstream's account, and no
  syntax error anywhere. New errors elsewhere are ones the fixed errors
  hid, since AstGen errors stop Sema. It needs Python, so `zig build
  test` does not run it yet; `bs fix` (step 8) will let it.
- **Cache**: the corpus runs twice in one cache directory, the second time
  as a no-edit rebuild and then after an edit above each error. Output
  must be byte-identical, with `BS_CACHE_CHECK=1`.
- **Parity with upstream**: `run.py --compile-errors` runs upstream's
  `test/cases/compile_errors` (1017 files; 994 apply to x86_64-linux) and
  counts cases where bs reports the same error lines (location and
  message), and those with the same locations. With a ReleaseSafe bs,
  step 1 (c0f7c7d) gave 338 exact, 431 at the same locations (exact
  included), 416 different, 132 accepted, and 15 crashes. After the crash
  fixes (08d7c40): 365 exact, 466 at the same locations, 397 different,
  131 accepted, and no crashes. The location share is the number to
  raise. Crashes come first: a crash is the worst diagnostic.
  Like upstream's case harness, run.py compiles each case as `tmp.zig`
  (its types are `tmp.T`) and reads bs's JSON lines. Call frames count
  as upstream's "called inline/at comptime here" notes, and notes outside
  the case file compare by message only, as upstream's `:?:?: note:`
  lines do. Measured that way, with the lookup facts of step 3: 404
  exact (336 with notes), 489 at the same locations, 374 different, 131
  accepted, no crashes. Before the harness change, the same bs measured
  373 exact (294 with notes) and 486 at the same locations.

### Steps

Each step is mergeable on its own and keeps today's errors otherwise
unchanged:

1. The record and the text and JSON renderers, AstGen code
   classification, the token-efficiency rules (paths, collapsed std
   frames, no carets), and the `test/diag` corpus. (Done.)
2. Codes for Sema's, the linker's and the backends' errors, from their
   format strings. (Done.)
3. Facts: candidates, declaration sites, user frame first, the reference
   trace from `referenced_by`, and inferred error sets printed by name.
   (Done: upstream's type-mismatch notes, declared-here notes with their
   source lines, the reference trace, and candidates for failed member
   and field lookups and for undeclared identifiers, the latter by
   parsing the failing file again. Not yet: the value's origin on type
   mismatches, and inferred error sets by name.)
4. The migration and pattern table. (Started: the first set above.)
5. Fixes, first set. (Done: the table above, and
   `tools/diag/roundtrip.py`, which applies a file's fixes round after
   round and checks with bs and upstream that no error is left or made
   at an edited place; all 33 corpus fixes pass.)
6. The cache: failing builds commit the manifest for the units that
   succeeded.
7. Alongside: `run.py --compile-errors`, and fixing bs's crashes and
   wrong locations on upstream's compile-error cases. (Harness done; no
   crashes left.)
8. Later: `bs explain` and `bs fix` (applies exact fixes).

## Deliberate differences from upstream

Upstream 0.17.1 is the oracle, but where it computes a wrong value bs
computes the right one instead of copying the bug:

- *Container-level assembly.* Upstream's self-hosted backends drop it,
  so its symbols are undefined at link time; bs assembles it as
  upstream's LLVM backend does ("Container-level assembly").

- *`extern threadlocal` that a shared library defines.* Zig 0.17.0's
  self-hosted x86_64 backend reaches every thread-local of a non-PIC
  executable local-exec, and its linker resolves that reference to the
  undefined import as if the variable were in the executable's own TLS
  block: for test/link_input/so_tls_main.zig's `so_tls` it emits `mov
  rax, fs:0; sub rax, 0x40028; lea rax, [rax - 0x1204200]`, and the read
  segfaults. Upstream with LLVM, and bs, read it initial-exec through a
  slot the loader writes (R_X86_64_TPOFF64; "Thread-locals imported from
  shared libraries"), and print the right values. C objects' accesses to
  the same variable were never affected.

- *128-bit atomics with cx16.* Upstream 0.17.1's Debug backends
  (self-hosted and LLVM) compute `@atomicRmw(.Min)` on 128-bit integers
  wrong: the self-hosted one picks the operand with `cmova`/`cmovg`
  after `cmp`/`sbb`, whose ZF reflects only the high limb, so
  `min(2, 1)` is 2. Its `.Add`, `.Sub` and `.Nand` on 65- to 127-bit
  integers leave the bits above the width unwrapped, and it fails to
  compile 128-bit `@atomicLoad` and `@atomicStore` (an error and a
  crash). bs gives LLVM ReleaseFast's results for all of them: loads
  are a `cmpxchg16b` of zero with zero and stores a `cmpxchg16b` loop,
  as LLVM lowers them. `@atomicRmw` arithmetic on f80 and f128, which
  upstream allows and miscomputes, stays refused.

- *`std.posix.tcgetattr` with glibc overflows its buffer.* With `-lc`
  on x86_64-linux-gnu, `std.c.termios` is `linux.termios` (NCCS 19, 44
  bytes), but `system.tcgetattr` is glibc's, which writes glibc's
  `struct termios` (NCCS 32 plus `c_ispeed`/`c_ospeed`, 60 bytes): 16
  bytes past `term`, an upstream std bug. Upstream's frames happen to
  absorb them: with -fno-llvm `term` sits at `0xb4(%rsp)` and the
  overflow lands on slots already dead (the handle's copy, the return
  value before it is stored, the 0xaa fill byte), and with LLVM on
  padding. In bs's frame the next slot is the spilled result pointer
  (`-0x28(%rbp)`), which becomes `0x7f0000000000` and faults on the
  store of the result: libvaxis's example-c-tty (a forked child in
  `PosixTty.makeRaw`, through the C API) segfaults under bs and passes
  under both upstream backends. bs does not lay out frames to absorb
  an out-of-bounds write; the corpus marks the step as expected to
  fail (tools/corpus/manifest.json).

- *A payload pointer used after its optional became null, at
  comptime.* In upstream's compile-error case
  dereferencing_invalid_payload_ptr_at_comptime.zig, the first block
  takes `&opt_ptr.?`, sets `opt_ptr = null` and loads through the
  payload pointer. Upstream 0.17.1 accepts it (the case marks it as
  regressed by #19630); bs reports "attempt to use null value" there, as
  it and upstream do for the case's other two blocks, so the runner
  counts the case as "different".

Where upstream supports more than bs generates code for, bs narrows
the choice instead of failing:

- *CPU models and features.* bs's own x86_64 code uses instructions up
  to x86-64-v2 (SSE4.2, `src/cpu.zig`'s `isa`); inline assembly
  (`codegen/x86_64/asm_insn.zig`, `asm_sse.zig`) may also use aes and
  pclmul (in their SSE and VEX forms), sha, clflushopt, lzcnt, movbe, prfchw, rdpid, rdrnd,
  rdseed, and any other instruction it encodes whose feature the CPU
  has. An explicit CPU (`-mcpu`, a model and features) is resolved as
  upstream resolves it, whatever its instruction sets, and is what
  `builtin.cpu` reports and the cache keys on: a program's comptime
  choices are the ones upstream makes for that CPU, and bs's SSE code
  runs on it. Per-CPU kernel objects need this: baskingspot/fastmem
  (through siv's image decoders) and astroz build objects with `-mcpu
  x86_64_v3`, `x86_64_v4`, `sapphirerapids` or `znver5`, whose roots
  `@compileError` without AVX2 in `builtin.cpu` and whose kernels (with
  `builtin.zig_backend` the self-hosted one) are `@Vector` code, which
  bs lowers to SSE at the same bits. What would change meaning is
  refused: a C-convention function passing or returning a vector of
  over 16 bytes on a CPU with AVX (Clang and upstream put it in YMM or
  ZMM registers; `checkCVectors`), an asm `x` operand of over 16 bytes
  (std's AES with vaes), and instructions the inline assembler does not
  encode. std's SHA-256 with sha and AVX2 (`-mcpu=x86_64_v3+sha`) is
  its SHA-NI assembly. Features no x86 CPU
  model has (`retpoline`, `lvi_cfi`, `seses`), and `soft_float`, change
  how code is generated rather than add instructions and are refused
  with a message naming them. As upstream, no `-mcpu` means the host's
  CPU for the native target (also what `zig build` passes for its
  native default) and the baseline for an explicit `-target`, which
  tools/conformance and the hunters pass (tools/mchunt pins
  `-mcpu=baseline` without one). The host's CPU (`-mcpu=native`, or no
  `-mcpu` natively) is clamped instead: its model becomes `x86_64_v2`
  when the host has all of its instructions, else `x86_64`, plus the
  host's features bs accepts; std takes its SSE paths, as upstream's on
  a CPU without AVX. Clamping keeps native builds off std's asm paths
  that need YMM registers or instructions the assembler lacks (vaes,
  sha); nothing asked for that CPU, unlike an explicit one. A build
  script that looks at the host's features sees the unclamped CPU;
  fastmem's agrees with its module because it passes its decision in
  an options module rather than recomputing it.
  aarch64 follows upstream the same way: no `-mcpu` means the host's
  CPU for the native target and the target's default for an explicit
  one (`apple_m1` on aarch64-macos, the generic ARMv8.0 core on
  aarch64-linux; `cpu.targetDefault`, which drops apple_m1's fuse_aes as
  upstream's `resolveTargetQuery` does). The host's CPU is clamped by
  removing SVE and SME (`cpu.clampAarch64`), which bs's backend and
  assembler do not handle and with which std would take
  `std.simd`'s 256-bit vector length and the syscalls' z and p register
  clobbers. An explicit model or feature list (upstream's syntax) is
  accepted unless it enables SVE or SME, which is refused with a message
  naming the features. `builtin.cpu`, the C and translate-c targets and
  the cache name (`cpu.cacheName`, against the target's default) come
  from the resolved CPU. The backend tests lse and lse2 (atomics), crc
  (inline assembly) and fullfp16 (native f16 arithmetic). On the Mac no
  std path changes: every M-series model has aes, sha2 and lse, the only
  aarch64 features std and compiler_rt test besides neon and sve. On an
  aarch64-linux host, a CPU instead of generic turns on std's AES, GHASH
  and SHA-256 asm paths and the backend's LSE atomics; conformance and
  the hunters pass an explicit target, so they stay on generic unless
  run with `--mcpu`.
  With `cx16` (x86-64-v2) 128-bit atomics are allowed, as upstream
  (`Sema.atomicElemType`), and lowered with `lock cmpxchg16b`
  (`codegen/x86_64/atomic128.zig`).

## Known regressions and limitations

None at present.
