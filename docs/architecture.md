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
body, or a type a function returns) are keyed by the key of the declaration
whose code holds the type's ZIR instruction, the instruction's offset from
that declaration's own instruction, and the stable hashes of the type's
captured values: `decl.key#offset(capture hashes)`. Never by an absolute ZIR
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
key and follows upstream exactly (`Parent__struct_<n>`), because `@typeName`
results are observable and `test/behavior` checks them.

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
  integers through link-time value relocations. The per-project manifest
  keeps last build's name-to-code assignment and only appends new names, so
  existing codes, and units whose results depend on one (comptime
  `@intFromError`, an error integer folded into a constant), stay stable
  across rebuilds without a dependency on the code (see "Edit builds"
  below).
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
- Vectors are scalarized in Sema: an element-wise operation extracts each
  element (`array_elem_val`, or folded when comptime-known), applies the
  scalar operation with its usual safety checks, and rebuilds the vector
  with `aggregate_init`. CodeGen sees vectors only as values in memory,
  laid out as upstream's x86_64 backend lays them out without AVX: bool
  vectors bit-packed (element i is bit i % 8 of byte i / 8), other vectors
  like arrays, aligned to 16. No IR instruction is vector-specific, so a
  backend that wants SIMD can recognize the pattern or add instructions
  later without changing Sema's results.
- Panics are calls, as upstream: `@panic` and each failed safety check
  call the matching function of `std.lang.panic` (`integerOverflow`,
  `outOfBounds(index, len)`, `call(msg, null)`, ...), then `unreach`.
  `std.lang.panic` is the root file's `panic` namespace if it declares one
  (read directly, so it needs no std code), else std's
  `FullPanic(defaultPanic)`. std is always loaded, as upstream analyzes
  it; `Frontend.Options.load_std` is off only in tests without a lib
  directory. std-free test programs declare a minimal root `panic`
  (`test/run/rt.zig`, `tools/conformance/zap_runner.zig`).
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
  thread's block from; .tbss takes room in the image (zeros in the file)
  so no other section overlaps the TLS segment's addresses. TPOFF32
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
  ascends and is in range before calling `debug(j)`.
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
- Debug info (`src/link/Dwarf.zig`, shared with the Mach-O linker) is
  DWARF 5: .debug_abbrev; in .debug_info a compile unit per
  `Debug.unit` (the path of the module's root file; as upstream does, the
  unit is named after its basename, which std.debug prints as "in main
  (hello.zig)", with its directory as comp_dir), holding a
  subprogram entry per function with `debug` (name, low_pc, high_pc,
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
- Call frame information: std.debug unwinds x86_64-linux stacks with DWARF
  CFI (frame-pointer walking counts as unsafe there and is used only for
  panics), looking first for PT_GNU_EH_FRAME. So each `Debug` entry whose
  `frame` is `.frame_pointer` or `.outermost` gets a fixed 32-byte FDE.
  `.outermost` (std.start's `_start`, `.cfi_undefined rip`) keeps the
  CIE's CFA of rsp+8 and marks rip undefined, which ends std.debug's
  unwind (SelfUnwinder returns 0). `.frame_pointer` describes CodeGen's
  `push rbp; mov rbp, rsp` prologue (CFA rsp+8, then rsp+16 with rbp at
  CFA-16, then rbp+16), all sharing one CIE in an allocated .eh_frame, and
  an entry in .eh_frame_hdr's sorted search table; naked functions
  (`.none`) get none. Both sections are sized for every entry before the
  entries are read, so they need no pass before section placement, and
  the FDEs are written by the same chunked debug tasks as the rest; the
  room of skipped entries stays zero after each section. Not described:
  the `ret` after each epilogue's `pop rbp` (CodeGen returns from several
  places; gdb's epilogue sniffer covers it), functions without `Debug`
  (runtime helpers), and naked functions other than an outermost one.
  Verified with gdb (its dwarf2 unwinder, at
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
  `.outermost` get no encoding (dyld calls `main`, so no zap frame is
  outermost). Entries are regular second-level pages, one per chunk of
  2048 debug entries: an entry where a function starts unless it
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
  frame should get a frameless `Atom.Debug.Frame` kind, encoded
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
  calls no helper loads none of compiler_rt (measured before std was
  always loaded: a std-free hello took 2 files instead of 701; 0.6 ms
  cold instead of 180–190 ms, 0.3–0.5 ms warm instead of 5.6–5.8 ms). AstGen errors in files loaded this way are
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

The storage layer knows keys, hashes, dependency edges, and Atoms, not
Sema: nodes carry an opaque `tag`, and a store entry's result is an opaque
payload until Sema serializes one. `src/Incremental.zig` connects it to a
compilation (see "Integration" below).

```
<global cache>/zap/store/<32 hex>.zsp       Store packs (shared by all projects)
<global cache>/zap/store/lock               flock held by maintenance (merging, trimming)
<global cache>/zap/store/trim               when packs were last trimmed
<local cache>/zap/c/trim                    when compilation directories were last scanned
<local cache>/zap/c/<32 hex>/               one compilation, keyed by root, target, options, output
    lock          flock held by the build that owns the directory; its mtime is the last use
    <32 hex>.zsp  base packs: hard links to the store packs holding the last build's Atoms
    manifest      base: mapped, pointer-free, replaced whole
    manifest.log  one checksummed record per build since the base
    pack          every Atom the last build linked, append-only
```

- **Atom records** (`cache/atoms.zig`): 16-byte aligned, a 64-byte header,
  then targets, relocations, an optional debug header, then bytes, name, and
  debug strings. `check` validates a record once (lengths within it,
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
  order when dead bytes (unreferenced records, and the base packs' other
  entries, headers, and dependencies) exceed live ones. The manifest names
  its base packs and the own pack's id.
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

- **Compilation key**: the zap binary's identity (inode, size, mtime), the
  target, the working directory, the zig lib directory, and the command
  line. The store seed, part of every store key, is the binary's identity
  and the target only, so store entries are shared across projects.
- **No-edit builds** (`relinkIfUnchanged`, before the frontend): lock the
  compilation, map the manifest, stat its inputs (every file the frontend
  loaded, with content hashes and the racy-mtime rule); if none changed,
  link the records in place from the packs (`Pack.LinkAtoms`) with the manifest's
  numbered symbols, entry, and error codes. Frontend, Sema, and CodeGen do not run. A
  conformance unit loading 562 files (std in test mode): 0.64–0.9 ms in
  zap (0.4–0.6 of it the stats), 2 ms wall, against 14–19 ms for a full build.
  The generated 24.5k-atom program below relinks in 5.2–7.6 ms (5.3 ms
  steady), against 7.4–9.5 (7.9 steady) when it decoded first.
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
  manifest replays: Emit tracks, as atoms are added, whether each owner's
  atoms are still adjacent (one hash insert per unit), and if not,
  `finish` regroups them, owners in the order of their first atom, and
  drops later atoms with a key already seen (`Emit.groupByOwner`). A
  relink then reproduces the fresh build byte for byte for any
  alignments; the test in `src/Emit.zig` mixes alignments, duplicate
  constants, and a unit whose atoms are split.
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
- **Error codes**: the last build's names are assigned first
  (`seedErrors`), so codes stay stable across builds.
- **Prediction check** (`ZAP_CACHE_CHECK=1`): compares a build's nodes with
  the last manifest. The seeds are the nodes whose `src_hash` changed and
  the source-computed nodes whose result changed; every node whose result
  changed must be reachable from them over the last manifest's reverse
  edges. This is the set an edit build will re-analyze.
- `ZAP_CACHE_TIMING=1` prints the cache's time; `ZAP_CACHE=off` disables
  it.
- **Size limits and trimming**. `ZAP_CACHE_MAX_SIZE` (bytes, or a number
  with K, M, G, or T; default 4G) limits the global store's packs and,
  separately, the local cache's compilation directories, each counted
  once per inode. Past it, the least recently used go, down to three
  quarters: store packs by mtime in `commit`'s maintenance, compilation
  directories by their lock's mtime in `cache.maintainCompilations`,
  skipping those a build holds. Store packs that this zap cannot read
  (another zap's pack format, or damaged) count and go by mtime like the
  rest, but are not deleted for being unreadable: two zap versions can
  share a store. A store pack that a compilation directory
  links keeps its space until the directory goes, which is why the local
  limit counts the links. The local scan runs after a build that started
  a directory (that is how the local cache grows) and otherwise at most
  once a minute, once the build's new pack is in its directory, so that
  the pack counts, while `record` writes the manifest; it stats the
  directories on up to 16 threads (600 directories: 5–6 ms on this
  4-core orb, overlapping the manifest's 8 ms). Directories unused for 5
  days go regardless. The cache can pass the limit only by the packs of
  builds still in flight (and by directories in use, which are never
  deleted). Measured with conformance runs by successive zap builds (a
  new identity each, `-j 16`), sampling `du` every second: with the
  default 4G, six runs peak at 3.85 GB (before, when the scan ran before
  the build's own pack was written: 4.47 GB after six); with 1G and two
  such runs at a time, three rounds peak at 1.01 GB (before: 1.50 GB). A
  limit below the working set cannot hold: two x86_64 units in use at
  once are 1.1 GB. The ZIR caches are kept to the
  sources their index names (one version per path) plus a day of edits
  (`Frontend.trimCaches`, daily, also beside the store work).
- **Why the cache grew without bound** (measured 2026-11-03): a
  conformance run with an empty cache writes 696 MB that stays (653 MB in
  114 compilation directories, of which the x86_64 unit's are a 555 MB
  store pack and a 79 MB manifest; 56 MB of ZIR), and zap writes 1.36 GB
  in all with the test binaries. A warm run writes 0 bytes to the cache.
  But the store seed and compilation keys include zap's own identity,
  so every rebuilt zap writes everything again under new names, and
  nothing was deleted for 5 days: 650 MB per rebuild-and-run, about 40 GB
  over a few days of compiler work. Merges could rewrite the large pack
  (above), and the old compilation directories' hard links kept merged and
  trimmed packs' space in use.
- **Caches that still filled disks after the limit landed** (42–43 GB,
  with 1.1 and 2.3 GB packs in compilation directories, linked up to 27
  times): every one of those builds ran a zap built from a tree without
  the limit (bases 775ce0b and 08a7029, before 7c31921). The 2.3 GB packs
  were store merges of several zap builds' x86_64 packs, which the limit
  now bounds, and their many links were directories pinning a big pack
  for a few entries, which re-putting entries (above) now prevents.
- **Writes that fail** (a full disk, say) cost reuse, not the build: a
  cache that cannot be opened is skipped with a warning; a recording that
  fails is discarded with a warning, as a damaged pack falls back; a ZIR
  cache write failure is reported once. The generated `builtin.zig` is the
  exception: it must exist on disk to be compiled, as upstream's must.
- **Reuse means identical records**: `record` reuses a store entry when
  its result hash, counts, and atom-record length match, and the hash it
  compares covers everything a record holds (symbol key, name, debug
  file, name, and base line), not only the contents. Until 2026-11-03 it
  covered contents and line numbers only, so an entry written by another
  compilation whose atoms had other names was reused, the manifest's atom
  references took this build's lengths, and the next relink failed its
  record check and rebuilt from scratch: the conformance x86_64 unit (204k
  atoms) took 15 s on every warm run instead of 0.5 s. `ZAP_CACHE_TIMING`
  now says why a build does not relink.
- **Touched but unchanged inputs**: when inputs' stats changed but their
  contents' hashes did not (a touch, a checkout, or an input too new to
  trust when recorded), the build still relinks, and their new stats go
  into the manifest's log (not past the fold size). Before, that was a
  full rebuild and a full manifest rewrite.
- Not yet: re-analyzing only the predicted units after an edit (designed
  below); recording comptime side effects.

### Edit builds: replaying cached results (designed 2026-11-03, for review)

Not built yet: Sema's set of types and values is still growing, and this
waits until hello world through `std.debug.print` compiles. What an edit
build does, and what it needs from Sema, Zcu, and the InternPool:

**Flow.** The no-edit check finds changed inputs. The frontend loads every
file as today (unchanged files are ZIR cache hits). Before Sema runs,
`Incremental` computes the *seeds* from the changed files alone: for each
node the manifest lists for a changed file (a new `sources` section: per
input, its nodes and a locator for each: declaration name path, plus the
ZIR offset relative to the declaration for container types and the ordinal
for `comptime` blocks), it resolves the locator in the new ZIR and compares
`src_hash`; `namespace_name`, `namespace`, and `func_body` nodes are
recomputed from ZIR, as `record` computes them, and a changed embedded
file's `embed_file` node is a seed. A missing locator is a
seed. The *possibly outdated* set is everything reachable from the seeds
over reverse edges (`Manifest.rdeps`, already fast: 2 ms for 30k nodes).
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
  `func_ies` dependency the same way. `ZAP_CACHE_CHECK` verifies that
  the recorded graph reaches every function the build analyzed from the
  analysis roots (comptime declarations, exports, tests); every recorded
  conformance unit passes, including x86_64's 184k functions. Function
  pointers in a declaration's data are queued by the coercion that made
  them, in Sema, so lowering values (`funcKey`) needs no reference.
- **Result hashes at runtime**: `Replay` compares a re-analyzed unit's new
  result with the manifest's before its dependents decide, so the hashing
  `record` does today moves to one function both use.

**Serialized results.** A result is the closure of InternPool items it
references, encoded canonically in a store entry's payload (the opaque
`payload` field `Store.Batch.put` already has), plus a small header naming
the result's items:

- Items in post-order (children first), each its stable hash and its `Key`
  with every `Index` operand replaced by a reference: a static index (below
  `static_len`), or the stable hash of an item earlier in the closure.
  Identical results encode to identical bytes, so the entry's result hash
  and the payload agree.
- Loading walks the closure: an item whose stable hash the InternPool
  already has (a new `ip.indexOfHash`, which needs a stable-hash index
  next to the deduplication maps) is skipped; otherwise its `Key` is built
  with resolved operands and interned with `ip.get`. After interning,
  `ip.stableHash(index)` must equal the recorded hash; a mismatch is a bug,
  reported as a cache miss that re-analyzes the unit.
- Key kinds, all by contents: `int_type`, `ptr_type`, `array_type`,
  `vector_type`, `opt_type`, `anyframe_type`, `error_union_type`,
  `simple_type`, `tuple_type`, `error_set_type` (names inline),
  `func_type`, `simple_value`, `undef`, `int` (big limbs inline), `float`
  (exact bits), `err`, `error_union`, `enum_literal`, `enum_tag`, `un`,
  `slice`, `opt`, `aggregate` (`bytes` inline), `calling_convention`.
  Strings are inline.
- Key kinds that name source, by locator instead of ZIR index (indices
  shift when unrelated code above changes): `struct_type`, `enum_type`,
  `union_type`, `opaque_type` as (owning declaration's key, ZIR offset of
  the container instruction relative to that declaration, captures, display
  name, stable key); the owning declaration's `src_hash` is unchanged
  whenever the type is green, so the relative offset still finds the same
  instruction. Interning one goes through a Zcu function that creates the
  type and scans its namespace as analysis does (Sema thread). `func` as
  (owner declaration's key, relative ZIR offset, generic owner, comptime
  arguments); `inferred_error_set_type` as its function; `ptr` with a
  `nav` base as the declaration's key, resolved to a `NavIndex` by
  namespace lookup alone; `nav_capture` (a container type's capture of a
  declaration from an enclosing generic namespace, ZIR's
  `decl_val`/`decl_ref` captures, by value or by reference) the same way.
  Such a capture stays unresolved until the type's body reads it, as
  upstream, because the type may be that declaration's own value.
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
  is not a dependency, and replay does not reproduce it.
- Per unit kind: `nav_val` stores ty, val, `is_const`, `linkage`,
  `alignment` (the explicit `align(n)`, 0 if none);
  `type_layout` stores the `ContainerInfo` fields (names, field types and
  defaults by reference, offsets, which fields are `comptime`, explicit
  field alignments, tag type, flags, size, alignment);
  `func` stores its references (its Atoms are in the pack, its IR is
  never stored); `func_ies` stores the error names; `comptime_decl` stores
  its exports.
- `builtin.test_functions` is filled outside unit analysis
  (`populateTestFunctions`, after all tests are known), so the test list is
  its own node, and adding or removing a test changes it.

**Error codes and inferred error sets.** Codes stay append-only per
compilation (`seedErrors` assigns the manifest's names first), so a name's
code never changes while the compilation directory lives, including names
only a skipped unit uses. That makes an `error_code(name)` dependency
unnecessary: a comptime `@intFromError` result cannot go stale, and the
dependency kind proposed earlier is dropped. New names from re-analyzed
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
encoding above (field names, field types' and defaults' stable hashes,
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
- Sema and CodeGen run on one thread today; the design below makes them
  parallel.

### Where a cold build's time goes (measured 2026-11-03)

`ZAP_TIMING=1` prints wall time per stage. CodeGen runs inside
`Zcu.analyzeAll` (Emit times `CodeGen.generate`); "Sema" is the rest of
`analyzeAll`. "Record" is the wait for the cache after the link. ReleaseFast
zap, 4-core orb, page cache warm; "ZIR warm" means std's ZIR was in the
global cache but the compilation's directory was empty.

| Program | Frontend | Sema | CodeGen | Emit | Link | Record | Total in zap |
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

### Parallel function bodies (designed 2026-11-03, for review)

Not built yet; two threads change Sema daily. Three steps, each useful
alone, sharing one hook.

**Step 1: CodeGen on a pool, behind one Sema thread.** CodeGen reads the
InternPool and Zcu without interning (it requests compiler_rt functions
and declarations' data, which become locked appends). Sema stays serial;
`sink.function` hands each IR, owned, to a pool of CodeGen workers, each
with its own Emit output (below). Expected: Sema plus CodeGen goes from
the sum to about Sema alone: 155 → ~120 ms on hello, 470 → ~310 ms on the
generated program, 10 → ~6.3 s on binary.zig.

**Step 2: function bodies on a pool.** Workers take queued function
bodies; each worker runs Sema and then CodeGen on the same body while the
IR is hot in cache, and anything a body needs (a declaration's value, a
type's layout, a callee's inferred error set) is resolved by that worker
on demand, as today, unless another worker holds it. With bodies at
93–97% of Sema, 4 cores would take hello to roughly 50 ms of Sema plus
CodeGen, the generated program to ~140 ms (its single-file frontend then
dominates), and binary.zig to ~2.7 s.

**Step 3: record each unit as it completes**, on the worker that finished
it (below), so that `record`'s graph and store work overlap analysis and
only numbering and the manifest write remain after the link.

**Claiming units.** A unit's state is where workers synchronize, as the
current `ensure*` functions already are (Nav `status`, `ContainerInfo.status`,
`Zcu.funcs`, `comptime_decls`, the root types of files). Each state becomes
an atomic word holding unresolved, in progress by worker N, done, or
failed. `ensure*` claims an unresolved unit with a compare-and-swap and
analyzes it on the calling worker; a done unit is read after an acquire
load (its result fields are written before the release store that marks
it done); a unit in progress on another worker is waited for. Before
waiting, a worker records which unit it waits on and follows the chain
owner → the unit that owner waits on → ...; reaching itself is a
dependency loop. The chain is the same cycle a serial stack would find,
but which unit reports it depends on timing, so the units on the cycle
are marked and re-analyzed on one thread at the end, in the serial order,
to report upstream's diagnostic. Waiting blocks the worker (a futex per
state word), so a pool needs more workers than cores only if waits get
long; measure first.

**What is per function, and what is shared.**

| State | Today | In parallel |
|---|---|---|
| `Sema` instance: arena, `ir_insts`, `inst_map`, `deps`, comptime allocations, `ies_names`, inline and branch counters, anonymous-type ordinals | per unit | per unit, unchanged |
| InternPool items and strings | one thread (`Zcu.tid = .main`) | per-worker `Tid`, already sharded (below) |
| Nav and `ContainerInfo` result fields | written by their unit | written by the claiming worker before marking done |
| `Zcu.funcs`, `func_queue` | map and list | sharded state map; a work queue (per-worker deques with stealing) |
| `Zcu.inferred_errors` | map | written by the body's worker before marking done; read after done |
| `Zcu.deps` | map per unit | per-worker lists of (unit, dependees), merged and sorted by unit key at the end |
| `Zcu.comptime_memo` | map | sharded map; two workers may compute the same call, the first insert wins, and both results are equal (memo keys and anonymous types inside are keyed by callee key and argument hashes) |
| `Zcu.namespaces` | list, pointers into it | per-worker lists with the owner in the index, as InternPool does, so a namespace pointer stays valid; `decls` is fixed once the namespace is created |
| `Zcu.errors`, `exports`, `test_functions`, `rt_helpers` | lists | locked appends; sorted at the end by unit key and source position (errors), declaration key (exports, tests), and key (compiler_rt requests), so their order does not depend on scheduling |
| `Zcu.arena` | one arena | one per worker |
| `ip.next_comptime_alloc` | counter | stays atomic: comptime allocations never escape their unit (see InternPool) |
| Frontend files | loaded before analysis, compiler_rt on demand | `loadFile` takes a lock |

**InternPool writes.** The pool is already built for this: each worker
appends to its own `Local` shard (its `Tid` is in every new index), the
deduplication maps are sharded by hash with a mutex per shard, and
published items are immutable and read without locks. Two workers
interning the same key race on the shard lock; the loser gets the
winner's index. Indices therefore differ from run to run, which is fine
because nothing persisted or ordered uses them (stable hashes and unit
keys do). Work needed: `Zcu.tid` becomes a per-worker field passed through
Sema; error values (below); and measuring shard-lock contention on the
hottest keys (pointer and integer types), which may want per-worker
lookup caches in front of the shards.

**Inferred error sets.** A caller that needs a callee's resolved set calls
`ensureFuncIes`, which is a unit claim like the others: done, read the
set; queued and unclaimed, claim it and analyze the body on this worker
(today's nested analysis); in progress elsewhere, wait, with the cycle
check. A body that needs its own set while analyzing itself is the
recursion case that is a dependency loop today, and stays one. On
binary.zig most bodies are reached this way, so work stealing must not
assume bodies come from the queue: a nested body's CodeGen runs right
after its Sema on the worker that claimed it.

**Emit and output order.** Each worker has an Emit output: its atoms,
debug entries, owners, content-atom uses, and the declarations, error
names, externs, and compiler_rt functions its code requested.
Content-addressed atoms are deduplicated per worker and again at `finish`.
The link order must not depend on scheduling, and today it is the order
of discovery on one thread. In parallel, `finish` sorts owner groups by
the node key the manifest uses (a unit's stable key hash; a content atom's
key), with the link's own atoms last, then deduplicates as
`groupByOwner` does now. Sorting 100k groups costs a few ms. It also keeps
an edited unit's atoms in place, which a future in-place relink wants.
Callers no longer sit next to their callees, which costs nothing
measurable in a Debug build. Error codes for value relocations are
assigned in that same order (below), and data for requested declarations
is lowered at `finish` in declaration key order.

**Error codes.** Codes are the one order-dependent value Sema computes:
`ip.errorValue` numbers names in the order they are first interned. Runtime
code only names errors (value relocations), so only comptime uses
(`@intFromError`, an error integer folded into a constant) need a code
during analysis. Codes come first from the last build's manifest
(`seedErrors`). A name without one gets a provisional code when a unit
first needs it, and the unit records that it read the code (the error
node the manifest already has). At the end, the final assignment
numbers the remaining names in the deterministic order above. Units whose
provisional codes differ from the final ones, which happens only for new
names read at comptime, are re-analyzed on one thread before Emit
finishes. Their dependents follow over the recorded edges, which is
the edit-build machinery.

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

**What stays serial.** AstGen of a single file; the roots
(`analyzeAll`'s comptime declarations, exports, and tests until bodies
are queued, which is cheap); `finish`'s data lowering (5 ms on the
generated program); and the re-analysis of dependency loops and of units
that read provisional error codes.

**Checking it.** `ZAP_THREADS=1` runs everything inline. The output
binary and the manifest's atom order must be byte-identical across thread
counts and runs, and conformance must not change. A debug option that
shuffles the work queue and adds random yields at claim points exposes
order dependence, and ThreadSanitizer builds of zap check the shared
state.

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
