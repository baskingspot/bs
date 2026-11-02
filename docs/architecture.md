# zap architecture

This document fixes the boundaries between zap's stages so that the speed
features in AGENTS.md (the on-disk per-declaration cache, parallel analysis of
function bodies, the bytecode comptime evaluator, single-pass backends and
linkers) can land later without redesigning the stages. AGENTS.md holds the
scope and the settled decisions; this file says how they fit together. Change
it when a boundary changes.

## Pipeline

```
source ──Ast.parse──▶ AST ──AstGen──▶ ZIR            (std.zig, per file, parallel, cached)
ZIR ──Sema──▶ InternPool (types, values)             (zap, per analysis unit)
            └▶ typed IR (one function at a time)
typed IR ──CodeGen──▶ Atom (machine code + symbolic relocations)   (per function, parallel, cached)
Atoms ──Linker──▶ ELF / Mach-O, written once
```

### Frontend (`src/Frontend.zig`)

- Uses `std.zig.Ast.parse` and `std.zig.AstGen.generate` unchanged.
- Like upstream, lowers every file reachable through `@import` eagerly, so
  syntax errors in unreferenced files are reported the same way upstream
  reports them.
- Measured cost (2026-11-02, orb, 4 vCPU Xeon 2.6 GHz, zap ReleaseFast):
  hello world reaches 559 files and takes 0.55 s to parse and lower on one
  thread. That alone is too slow for Go-class builds, so ZIR is cached on disk
  per file (keyed by file content hash, with a stat fast path) and lowered in
  parallel on a miss. Upstream does the same; zap must not be slower here.

### Analysis units

Sema's unit of work, of caching, and of parallelism is the *analysis unit*:

- the value (and type) of a container-level declaration;
- the layout of a struct, union, enum, or opaque type;
- the body of a runtime function instance (a non-generic function, or one
  instantiation of a generic function with its comptime arguments);
- a `comptime` block, a `test` declaration, an `export`.

Every unit has a **stable key** that does not depend on analysis order or on
in-memory indices: module name + file path within the module + the
declaration's name path (for example `std:array_list.zig:Aligned.append`), plus
the hashes of comptime arguments and captured values for instantiations and
anonymous types. The same key, rendered, becomes the linker symbol name.

Anonymous types (a `struct {}` expression inside a declaration or function
body) are keyed by the enclosing unit's key plus the type's ordinal among the
anonymous types that unit creates, never by a ZIR index: ZIR indices shift when
unrelated code above changes. The ordinal only shifts when the enclosing
declaration's own source changes, and then that unit is re-analyzed anyway.
The *display name* is separate from the key and follows upstream exactly
(`Parent__struct_<n>`), because `@typeName` results are observable and
`test/behavior` checks them.

When a unit reads another unit's result (a declaration's value, a type's
layout, a function's signature) it goes through one Sema function that records
the dependency. Sema records dependencies from the first skeleton onward, even
before anything persists them.

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
  across runs uses stable hashes or unit keys.
- Designed for concurrent use from the start: per-thread shards for appends
  and lock-free reads of published items. The skeleton can run one thread, but
  its API takes the per-thread handle so parallelism is not a retrofit.
- Error codes. `anyerror` integers are assigned per compilation and live only
  in memory; IR and Atoms refer to errors by name, and machine code gets the
  integers through link-time value relocations. A unit whose result depends on
  an integer (comptime `@intFromError`, or an error integer folded into a
  constant) records an `error_code(name)` dependency. The per-project manifest
  keeps last build's name-to-code assignment and only appends new names, so
  existing codes, and units that depend on them, stay stable across rebuilds.
- Pointers into comptime-mutable memory (`comptime var`, comptime
  allocations) are local to the unit that created them. They are excluded from
  stable hashing and persistence and must not escape a unit's result; an
  escape is upstream's "runtime value contains reference to comptime var"
  error. Memoized comptime calls don't memoize when an argument or the result
  points into comptime-mutable memory.

### Typed IR (`Ir`)

- One function at a time, flat arrays of instructions in SSA form, operands
  are instruction indices or InternPool indices (like upstream AIR).
- Produced by Sema for one function instance, consumed immediately by
  CodeGen, then freed. It is **never persisted**: the cache stores the Atom
  that CodeGen produces, so a cache hit skips both Sema and CodeGen.
- Debug semantics: Sema emits safety checks (overflow, bounds, unwrap,
  unreachable) as explicit IR, as upstream does. No optimization passes.
- Target-independent, and precise enough to interpret. The bytecode comptime
  evaluator (milestone 6) runs lowered function bodies; it may run this IR
  directly or a denser encoding derived from it, but it does not get a second
  semantic lowering.

### Comptime

- Skeleton and milestone 3: Sema evaluates comptime code by walking ZIR, as
  upstream does, with a comptime memory model (comptime allocations, mutable
  comptime values, comptime pointers) owned by Sema, not smeared across it.
- All comptime calls go through one entry point that memoizes by (function,
  stable hashes of arguments). Milestone 6 replaces the hot path behind this
  entry point with compiled bytecode for function instances whose types are
  fully known, falling back to ZIR walking for type-constructing code.

### CodeGen (`src/codegen/<arch>/`)

- Single pass per function, from IR to machine code. Debug strategy: every IR
  value that outlives its instruction gets a stack slot; instructions load
  operands into scratch registers, compute, and store. Variables are always in
  memory, which is also what debuggers expect in Debug builds. A small
  per-basic-block register cache may avoid redundant loads. No global
  register allocation.
- Calling conventions: `.c` follows SysV for integer, bool, and pointer
  parameters and results. Zap-to-zap calls (`.auto`) pass every argument in
  memory at 8-byte aligned offsets of the caller's outgoing area, return
  1-, 2-, 4-, and 8-byte results in rax, and return anything else through a
  result pointer in rdi. Nothing outside zap observes `.auto`, so this can
  change when a register allocator wants a different one.
- Until milestone 3 routes safety panics to `std.builtin.panic`, a failed
  check writes `panic: <upstream message>` to stderr through small runtime
  helper Atoms and raises SIGABRT.
- Output is an **Atom**, defined in `src/link/Atom.zig`:
  - stable symbol key and name, section kind, alignment;
  - code or data bytes (or a size for zero-fill sections);
  - relocations: offset, kind, target symbol key, addend;
  - line table and debug info fragments, relative to the declaration's first
    line, so that moving a declaration only patches its base line.
- The symbol key is 128 bits: a hash of the rendered unit key for
  declarations, or of the contents for anonymous constants. Atoms with equal
  keys are one symbol; the linker keeps one and rejects a key whose atoms
  differ.
- Relocation kinds are either target-specific addresses (x86_64: absolute
  64-bit, PC-relative 32-bit) or link-time values: an integer of 1, 2, 4, or
  8 bytes that the whole compilation assigns to the target key, such as an
  error code, passed to the linker rather than stored in any Atom.
- Atoms contain no InternPool indices. Constants a function needs (string
  literals, anonymous values) become their own Atoms with content-hash symbol
  keys, deduplicated by the linker.
- The x86_64 encoder (`src/codegen/x86_64/Encoder.zig`) appends instructions
  and produces an Atom's bytes and relocations; branches to local labels are
  patched in place and never become relocations.

### Linkers (`src/link/`)

- Take the set of Atoms, lay out sections, resolve relocations, and write the
  output file once. No incremental patching of output files; a full relink is
  a memcpy-dominated pass over cached Atoms.
- x86_64-linux: static ELF first. aarch64-macos: Mach-O against libSystem,
  ad-hoc code signature.
- The ELF linker (`src/link/Elf.zig`) builds the whole file in one buffer,
  walking the Atoms in input order: deduplicate and place, assign addresses,
  copy bytes and apply relocations, write the symbol table. Segments: R
  (headers, .rodata), RX (.text), RW (.data, .bss). TLS will add .tdata and
  .tbss at the start of RW with a PT_TLS header.
- Measured link throughput (2026-11-02, orb, `zig build bench-link`): 100k
  synthetic atoms (22 MiB of bytes, 650k relocations, uniformly random
  targets) link in about 3.4x the time of copying their bytes into a fresh
  buffer. Copying and page faults on the output take under half of it;
  relocation records (32 bytes each, as large in total as the code) and
  symbol-table lookups take most of the rest. Shrinking relocation records
  is the lever if relinks need to get closer to memcpy speed.

### compiler_rt (decided 2026-11-02)

- Upstream compiles all of `lib/compiler_rt.zig` as a separate compilation
  and links it into every binary (about 5,400 symbols even in a no-std
  program); it is 3.9 s of upstream's cold hello world, and editing any std
  file it imports rebuilds it.
- zap makes compiler_rt a module of the same compilation instead, analyzed
  lazily like everything else: when CodeGen or Sema needs a helper (for
  example `__udivti3`, float conversions, f128 arithmetic), it references the
  helper's declaration in the compiler_rt module, and only that function and
  what it reaches are analyzed, generated, and cached. compiler_rt's
  `comptime` export blocks are not analyzed; zap maps helper symbol names to
  their declarations (upstream names the function after its symbol, e.g.
  `pub fn __udivti3` in `compiler_rt/udivmod.zig`).
- `@memcpy`, `@memset`, and `@memmove` are inlined by CodeGen
  (`rep movsb`, `rep stosb`, and a direction check for overlap), not calls.
- Consequence: zap binaries contain only the compiler_rt symbols they use.
  Code that calls compiler_rt or `memcpy` by name gets them through the same
  lazy reference, so it still links.

## The on-disk cache (milestone 6, designed now)

Decided (2026-11-02): a Go-style content-addressed cache at declaration
granularity.

- **Unit cache key** = hash(zap version, target and options, the unit's
  stable key, its declaration's `src_hash`, and for instantiations the stable
  hashes of its comptime arguments).
- **Entry** = the unit's result (serialized canonically, referencing other
  items by stable hash) plus the list of dependencies with the result hash
  each had when the entry was made.
- **Change detection.** AstGen already computes a 128-bit hash per
  declaration from its source bytes and starting column, independent of its
  line (`Zir.Inst.Declaration.src_hash`; `fields_hash` for container fields).
  That is each unit's own-code hash; zap does not hash ZIR itself.
- **Edit-rebuilds are push-based.** A per-project manifest, one mmap-able
  file, holds last build's units, their result hashes, and the dependency
  graph with reverse edges. A rebuild stats the input files, re-lowers only
  the changed ones, compares their declarations' `src_hash` with the
  manifest to find changed units, and walks reverse edges from those alone.
  A re-analyzed unit whose result hash is unchanged stops the walk (early
  cutoff). The cost is proportional to the edit, not to the program; a
  rebuild with no edit costs the stats and the manifest load.
- **The global store is pull-based.** Entries live in a global cache
  directory shared across projects, so std's functions compiled for one
  project are hits for the next, the way Go reuses compiled std packages.
  With no manifest (a project's first build), Sema looks up each unit it
  reaches; an entry is valid if its `src_hash` matches and each recorded
  dependency still has the recorded result hash (red-green). That build pays
  per reached unit, which is acceptable because it would otherwise analyze
  them all.
- **Storage.** Two layers, split by who reads them:
  - The global store holds one file per entry, named by its key, written to a
    temporary name and renamed into place, like Go's build cache. Concurrent
    zap processes need no locks, and old entries are removed by age. Only a
    project's first build and units re-analyzed after an edit touch it.
  - The project's local cache holds the manifest and a pack: one file with
    every Atom the last build linked. A rebuild maps the pack, appends the
    Atoms it regenerated, and links from it, so the link reads one file. The
    pack is compacted when its dead space grows past its live size.
  - Measured on the orb (2026-11-02, warm page cache): reading 30k 2 KB files
    took 70–84 ms; mapping and touching one 60 MB file took 2–3 ms. One file
    per entry is fine for occasional lookups and too slow for every link.
  - Not per-module packs: a build reads a slice of many modules, a std pack
    would mix entries from every project on the machine, and concurrent
    builds appending to it would need cross-process locking.
- InternPool contents are rebuilt lazily on a warm build: only units that
  must be re-analyzed load the types and values they reference.

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

## Parallelism (milestone 6, designed now)

- Frontend: files lower in parallel.
- Sema: container-level units resolve on demand; runtime function bodies are
  queued and analyzed by a pool of workers, each with its own Sema instance and
  arena. A unit's state (unresolved, in progress by worker N, done) is the only
  synchronization point; a worker that needs a unit another worker holds
  waits, and a wait cycle is reported as a dependency loop, as upstream does.
- Resolving an inferred error set is one such synchronization point: a
  worker that needs a callee's resolved set waits on the worker analyzing that
  body, or analyzes it itself if nobody has started it.
- CodeGen runs on the worker that analyzed the function, right after Sema,
  while the IR is hot in cache.
- Linking starts when all Atoms exist.

## `builtin` and conformance

- zap generates the `builtin` module itself. It reports
  `zig_backend = .stage2_x86_64` on x86_64-linux so std and
  `test/behavior` take the same paths they take for upstream's self-hosted
  backend, which is also the benchmark baseline. The aarch64-macos choice is
  made at milestone 5.
- Conformance is measured per test: the number of `upstream/test/behavior`
  tests zap compiles and passes, divided by the number upstream 0.17.0 passes
  on the same target with the same backend.
- `tools/conformance/run.py` measures it: it builds zap, prints one summary
  line per target, and writes a per-file, per-test JSON breakdown to
  `.zig-cache/conformance/<target>.json`. `run.py --upstream` recomputes the
  committed upstream baseline, `tools/conformance/baseline/<target>.json`.
  The `-target` is upstream's test-matrix entry: `x86_64-linux-none` (no libc,
  baseline CPU, self-hosted backend) and `aarch64-macos-none` (Debug default
  there is LLVM).
- Each file `behavior.zig` imports is its own unit: one `zap test` compile and
  one run, in parallel with the others, so a compile error, crash, or timeout
  costs only that file. The root is a generated `behavior.zig` wrapper next to
  a `behavior` symlink, so namespaces and test names (`behavior.basic.test.x`)
  equal those of upstream's full build (`typename.zig` and
  `string_literals.zig` check `@typeName` results that include the
  namespace). `behavior.zig`'s own tests run from the real file with
  `--test-filter behavior.test`. The baseline run also builds all of
  `behavior.zig` at once and checks that the per-file results are identical.
- The harness passes the compiler a test runner with `--test-runner`
  (default `tools/conformance/test_runner.zig`) and parses only the runner's
  `@zap-test` line protocol on stdout, documented in that file. A test that
  crashes or times out is recorded and the binary is rerun with
  `--start=<next>`. Until zap compiles the default runner, which mirrors
  upstream's per-test setup (`testing.allocator`, `testing.io`), it can use a
  smaller runner that speaks the same protocol; tests are matched to the
  baseline by name, so zap must produce upstream's test names.
