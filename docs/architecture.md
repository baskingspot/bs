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

When a unit reads another unit's result (a declaration's value, a type's
layout, a function's signature) it goes through one Sema function that records
the dependency. Sema records dependencies from the first skeleton onward, even
before anything persists them.

Function bodies depend on the *signatures* of the functions they call, not on
their bodies. Editing a function body therefore re-analyzes and re-generates
only that function.

### InternPool

- Types and comptime values are interned and deduplicated, as upstream does.
- Every item carries a 128-bit **stable hash** computed from its contents and
  the stable hashes of the items it references (never from indices). Indices
  are an in-memory detail; anything persisted or shared between threads
  across runs uses stable hashes or unit keys.
- Designed for concurrent use from the start: per-thread shards for appends
  and lock-free reads of published items. The skeleton can run one thread, but
  its API takes the per-thread handle so parallelism is not a retrofit.

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
- Output is an **Atom**, defined in `src/link/`:
  - stable symbol key and name, section kind, alignment;
  - code or data bytes (or a size for zero-fill sections);
  - relocations: offset, target-specific kind, target symbol key, addend;
  - line table and debug info fragments, relative to the declaration's first
    line, so that moving a declaration only patches its base line.
- Atoms contain no InternPool indices. Constants a function needs (string
  literals, anonymous values) become their own Atoms with content-hash symbol
  keys, deduplicated by the linker.

### Linkers (`src/link/`)

- Take the set of Atoms, lay out sections, resolve relocations, and write the
  output file once. No incremental patching of output files; a full relink is
  a memcpy-dominated pass over cached Atoms.
- x86_64-linux: static ELF first. aarch64-macos: Mach-O against libSystem,
  ad-hoc code signature.

## The on-disk cache (milestone 6, designed now)

Decided (2026-11-02): a Go-style content-addressed cache at declaration
granularity.

- **Unit cache key** = hash(zap version, target and options, the unit's ZIR
  bytes made position-independent, the stable hashes of its inputs).
- **Entry** = the unit's result (serialized canonically, referencing other
  items by stable hash) plus the list of dependencies with the result hash
  each had when the entry was made.
- **Validation** is red-green: a unit whose ZIR is unchanged is green if every
  recorded dependency is still green with the same result hash; otherwise it
  is re-analyzed, and if its new result hash equals the old one its dependents
  stay green (early cutoff).
- Entries live in a global cache directory shared across projects, so std's
  functions compiled for one project are cache hits for the next one, the way
  Go reuses compiled std packages. A small per-project manifest lists the
  units the last build used, so a warm build starts validation without
  re-deriving the reachable set.
- InternPool contents are rebuilt lazily on a warm build: only units that
  must be re-analyzed load the types and values they reference.

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
