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
- Files are discovered and lowered from a work queue: lowering a file
  reveals its imports. File indices are assigned afterwards, breadth-first
  in import order from the root, so they do not depend on thread timing.
- ZIR is cached on disk per file, in `<cache>/zap/zir/` of the local cache
  (the root module) and the global cache (std, shared by every project).
  The directories are resolved like `zig build-exe`: `--cache-dir`,
  `ZIG_LOCAL_CACHE_DIR`, or the `.zig-cache` next to the nearest `build.zig`,
  else the global cache (always for `run`); `--global-cache-dir`,
  `ZIG_GLOBAL_CACHE_DIR`, or `~/.cache/zig`.
  - `<32 hex digits>`: one source text's ZIR, named by a 128-bit hash of
    the source salted with the Zig version. A header and the file's import
    names and error flag come first, then the ZIR arrays at their natural
    alignment, so the file is mapped and used in place. Written to an
    unnamed temporary file and linked into place; never modified.
  - `index`: sorted fixed-size records (path hash, inode, size, mtime,
    content hash), read whole at startup and replaced through a temporary
    file when a build learns new stats. Concurrent builds lose at most
    each other's new records, which costs a rehash, not correctness.
    A file modified within 2 s of the build's start is recorded with an
    mtime that never matches, so a same-tick edit cannot hide behind an
    unchanged stat.
- A file is first *probed*: stat it and, if the index matches, read the
  blob's header with one `pread` and map the rest without touching it. A
  probe miss reads and hashes the source; a known content hash is mapped,
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
- Measured (2026-11-02, orb: 2 cores / 4 threads Xeon 2.6 GHz, zap
  ReleaseFast, hello world, 559 files, `ZAP_FRONTEND_TIMING=1`): before the
  cache, every build spent 0.56–0.66 s here on one thread. Now a cold build
  (empty caches) takes 0.22–0.25 s, a warm build 5–6 ms, and a build after a
  one-line edit to `std/debug.zig` about 7.5 ms (9.7 ms before the guesses,
  breadth-first probing, and on-demand helpers). Cold is bounded by the two
  physical cores (the same build on one CPU takes as long as before). In an
  edit build the edited file's own lowering (about 5 ms for `debug.zig`) is
  the critical path. std's
  cached ZIR takes 41 MB.

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
- Float values are stored as the IEEE bits of their type (c_longdouble as
  f80, comptime_float as f128) and hashed and compared by those bits, as
  upstream: -0.0 and 0.0 are distinct values, and so are NaNs with
  different payloads. Comptime float arithmetic computes in the host type
  of the same precision, as upstream does.
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
- Calling conventions: `.c` follows SysV for scalars: integers, bools, and
  pointers in GPRs (16-byte integers in register pairs), f16, f32, f64, and
  f128 in XMM registers, f80 in memory and returned in st0, and other values
  in memory. Zap-to-zap calls (`.auto`) pass every argument in
  memory at 8-byte aligned offsets of the caller's outgoing area, return
  1-, 2-, 4-, and 8-byte results in rax, and return anything else through a
  result pointer in rdi. Nothing outside zap observes `.auto`, so this can
  change when a register allocator wants a different one.
- Numerics: f32 and f64 use scalar SSE2 and f80 uses x87, as upstream
  does. f16 and f128 arithmetic, operations SSE2 lacks (rounding, fmod,
  transcendental functions, fma, fmin/fmax), and conversions SSE2 cannot do
  call compiler_rt (see below). Integers wider than 64 bits live in memory
  as 64-bit limbs, normalized like narrow integers (the bits above the width
  are sign or zero copies); CodeGen operates on them limb by limb, inline
  except for 128-bit division (`__udivti3` and friends).
- Until milestone 3 routes safety panics to `std.builtin.panic`, a failed
  check writes `panic: <upstream message>` to stderr through small runtime
  helper Atoms and raises SIGABRT.
- Output is an **Atom**, defined in `src/link/Atom.zig`:
  - stable symbol key and name, section kind, alignment;
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
- The symbol key is 128 bits: a hash of the rendered unit key for
  declarations, or of the contents for anonymous constants. Atoms with equal
  keys are one symbol; the linker keeps one and rejects a key whose atoms
  differ.
- Relocation kinds are either target-specific addresses or link-time
  values: an integer of 1, 2, 4, or 8 bytes that the whole compilation
  assigns to the target key, such as an error code, passed to the linker
  rather than stored in any Atom. x86_64 addresses: absolute 64-bit,
  PC-relative 32-bit. aarch64 addresses: absolute 64-bit (data only; Mach-O
  turns it into a fixup), branch26 (b, bl), page21 (adrp) with pageoff12
  (add, or a load or store whose access size the linker reads from the
  instruction), and their GOT forms, which reach an import's GOT slot and
  are relaxed to the symbol itself when it is defined in the image. aarch64
  instructions have no 32-bit immediate field, so aarch64 CodeGen loads
  link-time values from a constant Atom instead of patching code.
- Atoms contain no InternPool indices. Constants a function needs (string
  literals, anonymous values) become their own Atoms with content-hash symbol
  keys, deduplicated by the linker.
- The encoders (`src/codegen/x86_64/Encoder.zig`,
  `src/codegen/aarch64/Encoder.zig`) append instructions and produce an
  Atom's bytes and relocations; branches to local labels are patched in
  place and never become relocations. On aarch64, conditional branches and
  cbz/tbz reach only labels (±1 MiB, tbz ±32 KiB; `finish` reports a
  branch that does not fit), calls to other symbols are `bl`, and addresses
  are adrp pairs. Both were checked against the system assembler (GNU as
  for x86_64; clang's for aarch64, 32,771 instructions byte-identical,
  including every encodable logical immediate).

### Linkers (`src/link/`)

- Take the set of Atoms, lay out sections, resolve relocations, and write the
  output file once. No incremental patching of output files; a full relink is
  a memcpy-dominated pass over cached Atoms.
- x86_64-linux: static ELF first. aarch64-macos: Mach-O against libSystem,
  ad-hoc code signature. The Mach-O linker (`src/link/MachO.zig`) has the
  same phases as the ELF linker and shares its thread pool, symbol table,
  and output buffers.
- The ELF linker (`src/link/Elf.zig`) builds the whole file in one buffer
  (for `link`, a shared mapping of the new file, which replaces any old file
  instead of truncating it). Segments: R (headers, .rodata, and with debug info
  .eh_frame and .eh_frame_hdr), RX (.text), RW
  (.data, .bss). TLS will add .tdata and .tbss at the start of RW with a
  PT_TLS header.
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
  5 ms of dedup, layout, and address resolution. Keys resolved to dense
  indices once in the on-disk cache (milestone 6) could remove the probes.
- Debug info (`src/link/Dwarf.zig`, shared with the Mach-O linker later) is
  DWARF 5 with one compile unit for the whole output: .debug_abbrev, a
  .debug_info subprogram entry per function with `debug` (name, low_pc,
  high_pc, decl_file, decl_line), and one .debug_line sequence per such
  function. Per-entry sizes depend only on the entry (the file index is a
  padded ULEB128), so a pass over chunks of 2048 `Debug` entries, run in
  the same parallel step as address resolution, sizes them and dedups their
  file paths; a serial step merges the paths into the file table, whose
  directories are resolved against `comp_dir`; the debug chunks are then
  written in place as extra tasks of the copy step. Entries whose atom lost
  to a duplicate are skipped. gdb (`break file.zig:N`, `break fn`, `bt`) and
  std.debug's ElfFile/Dwarf read it; std.debug requires a .debug_str, so
  it holds the producer string. Per-module compile units, types,
  variables, and rbrace (epilogue) rows come later.
- Call frame information: std.debug unwinds x86_64-linux stacks with DWARF
  CFI (frame-pointer walking counts as unsafe there and is used only for
  panics), looking first for PT_GNU_EH_FRAME. So each `Debug` entry whose
  `frame` is `.frame_pointer` gets a fixed 32-byte FDE for CodeGen's
  `push rbp; mov rbp, rsp` prologue (CFA rsp+8, then rsp+16 with rbp at
  CFA-16, then rbp+16), all sharing one CIE in an allocated .eh_frame, and
  an entry in .eh_frame_hdr's sorted search table; naked functions
  (`.none`) get none. Both sections are sized for every entry before the
  entries are read, so they need no pass before section placement, and
  the FDEs are written by the same chunked debug tasks as the rest; the
  room of skipped entries stays zero after each section. Not described:
  the `ret` after each epilogue's `pop rbp` (CodeGen returns from several
  places; gdb's epilogue sniffer covers it), functions without `Debug`
  (runtime helpers), and naked functions, including `_start` (std's
  `_start` marks rip undefined with `.cfi_undefined`; a frame kind for that
  can come with std.start). Verified with gdb (its dwarf2 unwinder, at
  entry, after the push, and in the body), `readelf
  --debug-dump=frames-interp` (same rows as upstream's FDEs, minus
  upstream's epilogue row), and std.debug's own unwinder
  (`Dwarf.SelfUnwinder` through PT_GNU_EH_FRAME, both its search-table and
  sorted-FDE lookups) walking a trapped zap process's stack from a ptrace
  harness, and on a synthetic stack in a unit test. Cost on bench-link:
  about 3M more instructions per debug emit (40 bytes per function; 406.4M
  → 415.5M for three single-thread emits), within wall-clock noise; none
  for stripped emits (312.1M). Cost (bench-link with a line row every
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
  absolute addresses), __DATA (__data, __bss), __LINKEDIT, all on 16 KiB
  pages. Imports (`Options.imports`, all from libSystem) each get a GOT
  slot and a stub; branch26 to an import goes to the stub, the GOT forms
  load the slot, and absolute addresses of imports in data are binds.
  Rebases and binds are chained fixups (`DYLD_CHAINED_PTR_64_OFFSET`, as
  ld64 emits for arm64 since macOS 12), linked into per-page chains in one
  serial pass; there are no dyld opcodes. The file ends in an ld64-style
  "linker-signed" ad-hoc signature: one CodeDirectory with a SHA-256 hash
  per 4 KiB page, hashed in parallel; the UUID comes from the same hashes,
  so the file is read once for both. `link` must invalidate its mapping of
  the output before unmapping it, or macOS kills every run of the file
  despite a valid signature (golang/go#42684). It takes no `Atom.Debug`
  yet; Mach-O debug info comes later.
- Measured Mach-O link throughput (2026-11-02, Apple M4 Max, 12+4 cores,
  `zig build bench-link -- macho`, best of 15): the same 100k atoms with
  aarch64 relocations (970k: a constant reference is an adrp/add pair) and
  64 imports; output 26.9 MiB. Emit takes 22.5 ms on one thread (7.3x the
  1-thread floor of 3.1 ms; stripped ELF on the same machine: 11.0 ms) and
  3.1 ms on 16 (ELF: 2.0 ms); linking to a file takes 12.4 ms (ELF, with
  DWARF: 13.3 ms). SHA-256 of the 27 MiB output alone takes 8.8 ms on one
  thread, most of the gap to stripped ELF; the rest is the extra
  relocations.

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
- Mechanism: `compiler_rt` is a module rooted at `lib/compiler_rt.zig`
  (ZIR in the global cache), but `loadAll` does not load it: when
  `Zcu.analyzeAll` resolves a request, `Frontend.loadFile` loads the
  helper's file and the files it reaches that are not loaded yet, with the
  same work queue, and numbers them after the loaded ones. A program that
  calls no helper loads none of compiler_rt (a std-free hello: 2 files
  instead of 701; 0.6 ms cold instead of 180–190 ms, 0.3–0.5 ms warm
  instead of 5.6–5.8 ms). AstGen errors in files loaded this way are
  reported with Sema's (`Frontend.late_errors`). CodeGen calls a helper
  through `Zcu.requestCompilerRt(file, name)`, which returns the stable key
  of the helper's function unit, `compiler_rt:compiler_rt/<file>:<name>`;
  that key is also the call's symbol. `Zcu.analyzeAll` resolves each new
  request (the file's root type, the declaration by name, its value) and
  queues the function like any other. Helpers are named by declaration,
  not by exported symbol (`__cmptf2` serves `__lttf2`, `fmodq` is exported
  as `fmodf128`).
- compiler_rt bodies are analyzed without runtime safety, ignoring
  `@setRuntimeSafety`, because upstream builds compiler_rt in a release mode
  and its code relies on that (for example wrapping `-=` in `fmodq`).
  `builtin.is_test` is shared with the program, so under `zap test`
  compiler_rt sees `is_test = true`; it reads it only in declarations zap
  does not analyze (exports, its panic handler) and in `@setRuntimeSafety`
  arguments, which zap ignores there.
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
  - The global store holds entries in immutable packs, git-style: each
    build writes its new entries as one pack file with a sorted key index,
    and lookups binary-search the mapped indexes of all packs. Concurrent
    zap processes need no locks to write, and old packs are removed by age.
    Only a project's first build and units re-analyzed after an edit touch
    it. (Go's one file per entry was measured and rejected, below.)
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

### Storage layer (`src/cache.zig`, `src/cache/`; built 2026-11-02)

The storage layer exists; Sema does not use it yet. It knows keys, hashes,
dependency edges, and Atoms, not Sema: nodes carry an opaque `tag`, and a
store entry's result is an opaque payload until Sema serializes one.

```
<global cache>/zap/store/<32 hex>.zsp       Store packs (shared by all projects)
<global cache>/zap/store/lock               flock held by maintenance (merging, trimming)
<global cache>/zap/store/trim               when packs were last trimmed
<local cache>/zap/c/<32 hex>/               one compilation, keyed by root, target, options, output
    lock          flock held by the build that owns the directory
    manifest      base: mapped, pointer-free, replaced whole
    manifest.log  one checksummed record per build since the base
    pack          every Atom the last build linked, append-only
```

- **Atom records** (`cache/atoms.zig`): 16-byte aligned, a 64-byte header,
  then targets, relocations, an optional debug header, then bytes, name, and
  debug strings. `decode` is zero-copy: the `Atom`'s slices point into the
  record. A function's debug info is the record's tail, so an Atom and its
  debug info are cached and replaced together; `decode` returns them
  apart, and `Pack.decodeAll` builds the linker's `[]Atom.Debug`, sorted by
  atom index, alongside the Atoms.
- **Store** (`cache/Store.zig`): each worker fills a `Batch`
  (`put(key, {src_hash, result_hash, deps, atoms, debug, payload})`), and
  `commit` writes all of a build's batches as one pack: a 64-byte header,
  the entries (`Header`, `[]Dep{key, result_hash}`, atom records, payload),
  then the keys sorted, their locations, and a 257-entry fan-out table on
  the keys' top byte. Large packs are written from several threads; the
  file is placed with O_TMPFILE and link under a random name, so concurrent
  writers never collide. `open` maps every pack; `get` searches them in
  decreasing `order` (when their newest entry was written) without a
  system call, so a key's newest entry wins, and `Entry.isValid` is the
  red-green check. Past 16 packs, `commit` merges, under a non-blocking
  lock, the run of packs adjacent in lookup order with the fewest bytes,
  down to 8, so lookup order is kept and large packs are rarely rewritten.
  A pack records its last use in its mtime (refreshed at most hourly) and
  is deleted after 5 days unused; a hit in a pack older than 2.5 days is
  written again by the build's `commit`, so live entries move to young
  packs and one used entry does not keep an old pack alive.
- **Manifest** (`cache/Manifest.zig`): nodes (80 bytes: key, result hash,
  `src_hash`, ranges into the edge, reverse-edge, and atom-reference
  arrays, `tag`), an open-addressing key table, edges, reverse edges, atom
  references, input stat records (path, size, mtime, inode, content hash,
  with a sentinel for racy mtimes), and error names in code order. Rewriting
  the 8 MB base costs ~25–35 ms here, so an edit build appends a log record
  instead (`Delta`): the changed and added nodes, inputs, and error names.
  `open` applies the log into a small in-memory overlay; a torn record at
  the end is dropped and overwritten. When the log passes a quarter of the
  base, the next build writes a new base (`Builder.initFrom`, `write`).
  Reverse edges are a superset while a log exists: a node's old reverse
  edges stay until the next base, so a walk may re-check a unit that no
  longer depends on the edit, never miss one.
- **Pack** (`cache/Pack.zig`): `AtomRef` is 8 bytes (offset in 16-byte
  units, so up to 64 GiB, and length). `append` writes the regenerated
  Atoms with one `pwrite` and remaps; old records stay put, so the manifest
  stays valid across appends. `decodeAll` decodes on every core. `compact`
  rewrites the live records in link order under a new pack id when dead
  bytes exceed live ones; the manifest records which pack id its references
  are for.
- File contents are trusted once their lengths check out: indices inside
  them are not bounds-checked on each access. Records are host-endian (both
  targets are little-endian).

Measured with `zig build bench-cache` (ReleaseFast, 4-core orb, warm page
cache; the orb varies ±40% run to run) on a synthetic compilation of 30k
units plus 30k other nodes, 300k edges, 600 inputs, 2000 error names, and
103,750 Atoms (22 MiB of code and data, 650k relocations): manifest 8.2 MiB,
pack 55 MiB.

| Step | Time |
|---|---|
| No-edit rebuild: lock, map manifest, stat 600 inputs | 0.29–0.56 ms |
| Open manifest with 15 log records, gather atom refs | 0.24 ms |
| Edit storage work: append one unit's Atoms, log record | 0.02 ms |
| Dependents walk over 29,978 nodes (no early cutoff) | 1.9–2.5 ms |
| Relink: map pack, decode 103,750 Atoms and debug on 4 threads | 3.1–5.2 ms |
| `Elf.emit` from the mapped pack (from memory) | 10.8–12.8 ms (10.0–12.2 ms) |
| Cold save: pack append, manifest base | 100–120 ms, 30–44 ms |
| Fold log into a new base | 22–58 ms |
| Compaction, 166 → 55 MiB | 80–164 ms |
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
scan of 60k entries 65–77 ms. Packs need one file per build. A first build
writes its Atoms twice, once in the global store and once in the project's
pack; that costs ~45 ms of the commit, and the project pack could refer to
store packs instead, at the price of depending on files other builds merge
and delete.

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

- Frontend: files lower in parallel (see Frontend above).
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
