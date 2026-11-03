# zap architecture

This document fixes the boundaries between zap's stages so that the speed
features in AGENTS.md (the on-disk per-declaration cache, parallel analysis of
function bodies, the bytecode comptime evaluator, fast SSA backends, and write-once
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
- Error return traces are explicit IR too, as upstream: a return of a
  possible error calls `std.lang.returnError`, which pushes the return
  address; handling an error (`catch`, `if`/`else`, a call whose error
  result is discarded) restores the index saved before it
  (`save_err_return_trace_index`, then a store through
  `err_return_trace`). `.auto` functions share the caller's trace; a
  non-`.auto` function that calls one creates its own at entry
  (`set_err_return_trace`). With no liveness pass, a save that no restore
  uses is marked unused by Sema and has no code. Off in compiler_rt (built in
  a release mode upstream) and without std.
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
- All comptime calls go through one entry point that memoizes by (function,
  stable hashes of arguments). A memo entry keeps the dependencies its call
  declared, and a unit that reuses the result declares them too, as if it
  had made the call. Milestone 6 replaces the hot path behind this
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
`ZAP_COMPTIME_EVAL=n` sets it, 0 turns the evaluator off), so code that
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
  (a `comptime` loop's iterations, an inline call's) as a
  `comptime_tick` instruction, and `@setEvalBranchQuota` as
  `comptime_quota`; both exist only in evaluator bodies;
- keeps packed struct accesses as `struct_field_ptr`/`struct_field_val`
  rather than bit arithmetic, which comptime memory addresses directly;
- does not queue runtime analysis of callees;
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
may load D for a green U. Lowering reads what other units resolved
(`bcRequire`), on every branch, so its reads are not plain edges of the
units that run the body. They are *conditional* edges (`Sema.deps_conditional`,
recorded in `Zcu.conditional_deps`): they count for invalidation (a changed
D reaches U) but replay does not load them. Where the code the walker
would run reads D, lowering places a `comptime_dep` instruction in the
innermost runtime block, and a run that reaches it declares the plain edge,
once per memoizable call in progress; a read outside any runtime block of
the body (or in instructions lowering discards) is declared plain by every
run (`Bytecode.entry_deps`). A plain declaration wins over a conditional
one, and memo entries keep the flag. A unit's edges therefore cover what
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

**Next steps**, in order of measured payoff: large aggregate literals
(outside the evaluator); deoptimization stubs for references the walker
has not resolved yet; generic calls whose comptime arguments are
run-time values in the lowered code (uucode's `selectFieldIndexes` loop,
refused today); then a denser encoding.

### CodeGen (`src/codegen/<arch>/`)

- Today: a single pass per function, from IR to machine code. Every IR
  value that outlives its instruction gets a stack slot; instructions load
  operands into scratch registers, compute, and store. No register
  allocation. "Optimizing backend" below replaces this with one shared SSA
  layer (accepted 2026-11-03, being built); the bullets here describe the
  code as it is until that lands.
- Calling conventions: `.c` follows SysV for scalars: integers, bools, and
  pointers in GPRs (16-byte integers in register pairs), f16, f32, f64, and
  f128 in XMM registers, f80 in memory and returned in st0, and other values
  in memory. Zap-to-zap calls (`.auto`) pass every argument in
  memory at 8-byte aligned offsets of the caller's outgoing area, return
  1-, 2-, 4-, and 8-byte results in rax, and return anything else through a
  result pointer in rdi. The caller's error return trace pointer goes in
  r9 (as upstream's last argument register); the callee keeps it in a
  frame slot. Nothing outside zap observes `.auto`, so this can
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

### Optimizing backend (designed 2026-11-03, accepted by the owner; being built)

Step 1 is built (see "Landing it"). AGENTS.md fixes the goal: one optimization level, Debug
semantics, debuggable output, and optimization sized to compile fast. This
section fixes how: one shared SSA layer per function, a short fixed list of
passes, linear-scan register allocation, and a lowering per architecture.
It replaces CodeGen's internals, not its boundaries: the input is still
one function's typed IR, and the output is still one Atom and one
`Atom.Debug`, per function, cached as today.

**What the current backend costs.** Measured on libvaxis's text_input
(main 8fe40fe, ReleaseFast zap): 2,432 functions, 295k IR instructions,
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
(`Vaxis.render`, `Parser.parse`, `sort.block.block`) and zap's binaries
run 0.83–1.28× as long as upstream Debug's, 2.6–21.6× as long as
upstream ReleaseSafe's (`bench/runtime.py`, below).

#### Principles

- **Per function, no interprocedural facts.** Every decision reads only
  the function's own IR (and, once inlining lands, the bodies it inlines,
  each through a recorded cache edge). Nothing reads a callee's register
  usage or frame size. That keeps each Atom a function of its unit's
  inputs, which the cache and parallel CodeGen both require.
- **No code motion of memory operations.** Loads, stores, calls, atomics,
  and inline assembly stay in IR order within their block. Pure values may
  be folded into their user (an immediate, an address, a compare into a
  branch) or removed when dead, but are not hoisted or sunk across
  blocks. There is no memory SSA, no alias analysis, no GVN, and no LICM.
  Line tables stay in source order, which is what a debugger stepping a
  Debug build expects.
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
  from and stored to the slot by the C ABI module), vectors, and
  integers over 128 bits. The SSA value is the address of a frame slot holding the value, which is written once by the instruction
  that defines it and read by its users; field reads are loads from that
  address. Wide integers, f80/f128, and vectors keep today's limb-wise
  and compiler_rt lowerings, operating on these addresses.

**Narrow integers.** A register holding an integer narrower than the
register (u3, i7, u8, u16, and u32 on 64-bit registers) has unspecified
bits above the type's width. The lowering extends where the bits matter:
compares (aarch64 folds the extend into `cmp w, w, uxtb`), division,
right shifts, widening casts, overflow checks, and stores to memory. At
every boundary a value is normalized (zero- or sign-extended to its ABI
size, as today's invariant for memory): in memory, in call arguments and
results of both conventions (Apple's C convention requires callers to
extend arguments narrower than 32 bits), and in returns. So loads and
incoming arguments are known extended, and lowering tracks that to skip
redundant extensions. x86_64 may use 8- and 16-bit forms where they
give the same result.

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
   dropped. One walk in reverse postorder.
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
motion, bounds-check elimination, strength reduction beyond what
lowering's folding does, and scheduling. Each needs either analysis
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
  prologue in a fixed layout per architecture, and restored in every
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
  register), or x16/x17 (clobbered by zap's import stubs and by
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

**The `.auto` calling convention** follows from this, and stays private
to zap (nothing outside zap calls an `.auto` function, so it changes
freely; every caller and callee is regenerated together because zap's
identity is in every cache key):

- Arguments are classified like the C convention's register part:
  scalars and pairs in general registers (x86_64 rdi, rsi, rdx, rcx, r8,
  r9; aarch64 x0–x7) and floats in vector registers (xmm0–xmm7; v0–v7), in
  order; a pair takes two consecutive general registers, and a pair that
  does not fit entirely in registers goes on the stack, never split.
  Arguments that
  do not fit, and memory-class arguments, go in the outgoing stack area as
  today (the callee reads them in place, so a large struct is copied once
  by the caller, as now).
- Results: scalars and pairs in rax/rdx (x0/x1), floats in xmm0 (v0);
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
  `adr x, T; ldrsw x, [x, idx, lsl 2]; add; br`), which neither encoder
  has yet.

Flags are one implicit value on both architectures, never allocatable,
never spilled (see pass 5). Link-time values (error codes): x86_64 patches
them into an instruction's immediate field (`value16`/`value32`); aarch64 needs an instruction form for
them, and the cheapest is a new relocation kind that writes a link-time
value into a `movz` imm16 field (zap links its own output, so no external
linker must understand it), which makes an error compare `movz` + `cmp`
instead of `adrp` + `ldr` + `cmp`. Decide before aarch64 lowering depends
on either (relocation kinds are append-only). The Mac thread agrees;
the kind writes a link-time value into imm16 (bits 5–20) of a `movz`
(or a `movk`, with the shift taken from its `hw` field), and the linker
checks the opcode and that the value fits 16 bits. Error codes are u16,
so an error compare is `movz w16, #code; cmp wN, w16`, with x16 as the
in-instruction scratch; a `movk lsl 16` kind can follow if a 32-bit
link-time value is ever needed in code. The link thread adds the kind.

#### Debug info

- **Line rows** come from value positions, emitted in layout order when
  the position changes, as `Encoder.line` does today. Cold blocks keep
  their positions, so a panic call still maps to its check's line.
- **Inlined frames.** `dbg_inline_begin`/`end` (Sema's runtime inline
  calls today, the backend's inlining later) set the position's inline
  index. Layout can split an inline call's code (its cold blocks move to
  the end), so emission writes one `Debug.Inline` entry per contiguous
  range, all with the same call information, as the link thread's
  contract already allows.
- **CFI and unwinding.** Frame pointers stay in every function that is
  not naked, so std.debug's frame-pointer walk and every debugger keep
  working. Saved callee-saved registers need more than today's
  `Atom.Debug.Frame` can say, so the function's unwind information
  becomes a small record: frame kind (none, frame pointer, outermost), a
  stack size (u16, in 16-byte units, reserved now for aarch64's
  FRAMELESS leaves, `0x02000000 | size / 16 << 12`, which may come
  later), and a saved-register mask whose bits and layout each architecture fixes
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

#### Inlining within a budget (later step)

Not in the first version; the cache edge it needs is fixed now, so the
replay format can carry it.

- **What inlines.** First, leaf functions: `.auto` functions whose SSA,
  after their own passes, has at most a fixed number of values (start
  with 30) and calls nothing except cold noreturn functions (panic
  handlers). Not recursive, not `noinline`, not called through `@call(
  .never_inline, ...)`, no `@returnAddress`/`@frameAddress`, and never
  into a cold block. The decision reads only the callee's own SSA, so it
  is the same in every build and independent of scheduling, and leaf-only
  inlining cannot wait in a cycle. Inlining callees that themselves inline
  (Go's mid-stack inlining) comes after, ordered bottom-up over the
  call graph's strongly connected components.
- **Where.** In the caller's construction (pass 1): the callee's SSA is
  copied in with its arguments substituted, its positions marked with a
  new inline call (`Debug.Inline`, with the callee as `inline_callees`
  already records for Sema's inline calls), and the passes run over the
  result.
- **The cache edge** (reviewed by the cache thread). A new dependee,
  `func_inline: f`, appended to the dependee and manifest `Tag`s, with
  its producer edge to `f`'s `func` unit as `func_ies` has:
  - **Who records it.** Every call site that passes the caller-side
    rules (`.auto`, not `never_inline`, not in a cold block) records it,
    whether or not `f` turned out inlinable. Otherwise an edit that makes
    `f` inlinable would leave a green caller with its call while a full
    build inlines, and the outputs would differ.
  - **Its result hash** is a constant "not inlinable" marker when `f` is
    over the budget or not a leaf, and otherwise the stable hash of `f`'s
    inlinable SSA in a canonical encoding. So edits to a large `f` do not
    touch its callers; only edits that change what would be inlined do.
    Positions in the encoding are relative to `f`'s base line, as
    `Debug.lines` are, so adding a line above `f` does not make its
    callers red (their inline records' base lines are refreshed at relink
    through `inline_callees`, as designed). Types and constants are named
    by stable hash and callees by Nav key, never by InternPool index.
  - **Recording comes from CodeGen**, not Sema: the caller's construction
    pass finds the edges after Sema has recorded its dependencies. Emit
    keeps a per-caller list, as `Emit.unit_refs` does for references,
    deduplicated in first-occurrence (IR) order, and the recorder appends
    it to the caller's dependencies.
  - **Replay.** The result hash is stored per node like any other: a
    green `f` needs no recomputation, and a red `f`'s new hash gives early
    cutoff. In replay step 4, a queued function's green/red decision waits
    on its `func_inline` dependencies as on an inferred-error-set claim
    (`f` is compiled first when it is red). A caller that is red only
    through `func_inline` still re-runs Sema, since IR is not cached.
    Delta records carry dependencies generically. `ZAP_CACHE_CHECK` covers
    the edge without changes: a missing edge shows as a caller whose
    result changed without being predicted, so conformance runs with
    edit-and-verify passes are its test.
- **Getting the body on an edit build.** When a caller is re-analyzed
  and `f` is green, the caller needs `f`'s SSA, which the cache does not
  store (it stores Atoms). zap re-runs Sema and passes 1–3 on `f` without
  emitting it: `f` is under the budget by definition, its dependencies
  are loaded, and no format changes. `f`'s atom, dependencies, and
  references stay the manifest's and nothing is recorded anew; since `f`
  is green its analysis is deterministic and its side effects (error
  names, which atoms name symbolically anyway) are ones a full build has
  too. Each inlinable SSA is kept for the rest of the build, outside the
  per-function arena. Storing `f`'s SSA in its store entry instead would
  freeze an SSA closure encoding while Sema's types and the SSA still
  move, and add store bytes for every inlinable function; it is the
  fallback if edit-build profiles ever show the re-analysis. With
  mid-stack inlining the re-analysis recurses bottom-up, still bounded by
  the budget. In parallel CodeGen a caller waits for its callee's
  inlinable form as it waits for a callee's inferred error set, a claim
  like the others.
- **What users see.** std 0.17's stack traces print one frame per
  return address, named after the innermost inline range
  (`Dwarf.getSymbols` ignores inline callers), so a panic inside an
  inlined function shows the callee's line and loses the caller's frame.
  Debuggers show both (they read `DW_TAG_inlined_subroutine`). Upstream
  Debug never inlines, so this changes zap's panic traces relative to
  upstream's. The owner accepted this (2026-11-03): functions containing
  safety checks inline like any other, since nearly all arithmetic is
  checked; step 6 reports how much inlining such functions buys, to
  confirm the call with numbers.

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

- `ZAP_TIMING=1` prints a second line with each stage that exists so far,
  summed over functions, per IR instruction (`Emit.CodeGenStats`).
- `ZAP_BENCH_CODEGEN=n` makes zap keep a copy of every function's IR
  during analysis and then run the backend over all of it n more times,
  each into a fresh Emit, printing the fastest run's stages, code bytes
  per IR instruction, and frame bytes per function. `zig build
  bench-codegen` does that for the hello workload with a ReleaseFast zap;
  for libvaxis, set the variable on bench.py's build-exe command line.
  Deterministic enough for A/B comparisons in one session, and callgrind
  instruction counts of the same binary are exact.
- `bench/runtime.py` times the generated code (below). Every backend
  change reports its compile-time cost next to its run-time win, as
  AGENTS.md asks.

Generated-code baseline (main 8fe40fe, `python3 bench/runtime.py`,
medians of 5 runs on the 4-core orb):

| Program | zap | upstream Debug | upstream ReleaseSafe | zap / Debug | zap / ReleaseSafe |
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

Each step keeps conformance at 2170/2170 and `ZAP_CACHE_CHECK` clean:

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
3. `.auto` in registers, and the unwind record in the Atom (with the
   link thread).
4. Layout, fusion, overflow from flags, dead code, and branch shortening.
5. aarch64 lowering, ABI, and encoder relaxation on the same layer (Mac
   thread).
6. DWARF variable locations; then leaf inlining with the cache edge.

### Linkers (`src/link/`)

- Take the set of Atoms, lay out sections, resolve relocations, and write the
  output file once. No incremental patching of output files; a full relink is
  a memcpy-dominated pass over cached Atoms.
- x86_64-linux: static ELF first. aarch64-macos: Mach-O against libSystem,
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
- Relocatable objects (`zap build-obj`, x86_64-linux;
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
    `Zcu.exports`; one per name; zap has no export linkage yet, so all are
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
  - Code is not position-independent (absolute addresses in .rodata):
    link with upstream `zig build-exe` (static, non-PIE), `ld`, or `cc
    -no-pie`; a PIE link works with text relocations and warnings.
  - Checked (2026-11-03): an object exporting functions and data,
    importing a function, and using a thread-local links with upstream
    `zig build-exe` (self-hosted linker and `-fllvm -flld`), `cc -no-pie`,
    and `ld` (with its own `_start`), alongside an upstream-built object,
    and runs correctly; gdb breaks on its functions by qualified name,
    shows inlined frames and source lines, and unwinds through its FDEs;
    a panic in its code prints upstream-style stack traces through both
    objects' frames. `zig build test` checks the upstream link and the
    panic trace (test/obj).
  - Cost (ReleaseFast zap, orb, cache off, a copy of the program whose
    code an export reaches): hello, link stage 6.5–8.3 ms for the object
    against 3.1–4.3 ms for the executable, in a 230 ms build; libvaxis
    text_input, 8.7–10.1 ms against 4.6–6.0 ms, in a 560 ms build.
  - build-obj does not use the on-disk cache yet: a relink would need the
    exports, the imports, and the output kind in the manifest, and
    `ElfObject` to take the cache's input with numbered symbols.
- `zap run` builds the executable into `<cache>/zap/o/<hash>/<name>`, the
  hash of the working directory, std's directory, and the command line
  before `--`, so a rerun relinks in place through the cache, then
  replaces itself with the program (execve, as upstream does) with the
  arguments after `--` and `ZIG_EXE` set: exit status and signals are the
  program's own.

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
  share a store. `zap run`'s program directories (`zap/o/<hash>`) count
  and go with the compilation directories, by the program's mtime, which
  every run renews by relinking it, so a program run daily stays. `zap
  test` deletes its binary (`zap/tmp`) once it ran; ones a killed build
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
  `comptime` field values by reference, offsets, which fields are
  `comptime`, explicit field alignments, tag type, flags, size,
  alignment); `struct_defaults` stores the other fields' default values
  by reference (reified structs get theirs with the type, so the unit has
  nothing to do);
  `func` stores its references (its Atoms are in the pack, its IR is
  never stored); `func_ies` stores the error names; `comptime_decl` stores
  its exports.
- `builtin.test_functions` is filled outside unit analysis
  (`populateTestFunctions`, after all tests are known), so the test list is
  its own node, and adding or removing a test changes it.
- Test order: a file's tests are listed in source order when its namespace
  is created, which happens when something first resolves the file's root
  type. `Zcu.analyzeAll` resolves the roots, then queued `comptime`
  declarations, exports, the tests' declarations, and compiler_rt
  requests, all before it analyzes function bodies in FIFO order. So the
  main file's tests come first, then the tests of each file it reaches
  in that order; a file first reached from a test body (`_ = Table;`,
  `refAllDecls`) comes after every file reached without running test bodies.
  Upstream also lists tests by when each file is scanned, but its scan
  order comes from its work set, not a rule: `findOutdatedToAnalyze`
  takes functions first and then the first ready unit, and
  `clearOutdatedState` swap-removes it, so the most recently queued unit
  moves to the front. zap does not reproduce that (it would mean
  reproducing upstream's unit split and recursive analysis exactly), and
  test order can differ between the two (libvaxis's `widgets.Table` tests
  run right after `vxfw.vxfw`'s in zap and last in upstream). Once
  analysis is parallel, the list is sorted by declaration key (see the
  per-function table below), which is a different deterministic rule.

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
`comptime` field values stay in the layout (a struct's one possible value
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
  order dependence (as upstream's), which `ZAP_CACHE_VERIFY` may flag
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

The manifest will store the kind in the top 2 bits of each edge's node
index (two values spare; 2^30 nodes is ample), with the replay format
bump; until conditional edges have a reader, every edge is plain, which
over-predicts but is sound.

**Roots and output kinds** (for `zap build-obj`, which skips the cache
for now). Replay seeds its reference closure from a root list the
manifest stores (comptime declarations, exports, the entry, tests), as
`record` already gathers them, not from the entry; an object's roots are
its exports. The manifest's entry is optional and its header records the
output kind, so the relink picks `Elf` or `ElfObject` (the compilation
key holds the arguments, so the kind cannot change within a compilation
directory). An object's imports come from the recorded `useExtern`
references of the units linked; exports already come from Emit.
`ElfObject` takes the same numbered input as `Elf`, so the pack serves
both. A format version bump and the linker side; no Sema hook.

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
- `run.py --default-runner` measures `zap test` as a drop-in for `zig test`:
  no `--test-runner`, so zap builds upstream's own
  `lib/compiler/test_runner.zig`. The binary runs as `zig test` runs it and
  its terminal output (`1/9 name...OK`, leak reports, the summary line) is
  parsed; after a crash or timeout, the remaining tests run one at a time
  through the runner's `--listen=-` protocol (`std.zig.Server`, as
  `zig build test` drives it). Report both numbers.
- `run.py --std` is the next measure: upstream's std tests,
  `upstream/lib/std/std.zig` built as one `zap test` unit with the default
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
