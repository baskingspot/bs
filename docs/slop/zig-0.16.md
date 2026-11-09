# Two Zig languages: 0.17.1 and 0.16.0

Status: approved by the owner (2026-11-08) with every recommendation in
"Open questions" taken as decided; being built in the phases below.
Phase 0 (selection and plumbing) is described in docs/slop/architecture.md,
"Finding the zig lib directory at run time". Until 0.16 compiles,
`build.zig.zon` selects a language only with `BS_ZON_SELECTS` set, so
that projects which name another release keep compiling as 0.17; the
branch that makes 0.16 usable drops the variable.

The note was written from main b92b0c65, upstream 0.17.1 (`upstream/`),
and the official 0.16.0 source and x86_64-linux binary tarballs. The cache
and frontend thread contributed the frontend, cache and `bs build` parts,
and the link thread the linker and target-library parts. Their file and
line references are at main f5befc23.

The owner's decision: bs supports two Zig languages, the current release
and the one before it. Today that is 0.17.1 and 0.16.0, chosen per
compilation at run time. When 0.18 ships, bs adds it and drops 0.16. The
switch is the root package's `build.zig.zon` `minimum_zig_version`, and
the newest language when there is none (a lone file, for example). 0.16
is a full second language: its syntax, ZIR, semantics, std, compile errors
and build system, all compiled by bs's own Sema, backends and linkers.
Nothing is handed to upstream zig except what bs hands it today, C and
C++ through `zig cc`.

## Summary

- Today's bs already passes most of 0.16's language. Each 0.16
  `test/behavior` test was compiled on its own by today's bs, against 0.17's std, on
  x86_64-linux. 1756 of the 2108 tests upstream 0.16.0 passes also pass
  in bs (83%). Of the 352 that fail:
  - 157 hit only syntax that 0.17 removed;
  - 51 hit `@typeInfo`'s new shape;
  - 11 hit std APIs that 0.17 removed;
  - about 25 hit a real semantic difference;
  - the rest aren't examined yet.

  On 0.16's compile-error cases, today's bs gets 902/975 messages exactly
  right. See "Measurements".
- The frontend can't be shared as it is. bs takes Ast, AstGen and Zir from
  the std it is built with, and the two releases' ZIR differs in tag
  numbering, static `Ref` numbering and payloads. A 0.16 ZIR and a 0.17
  ZIR of the same file also collide in today's ZIR cache.
- Recommended design: bs owns its frontend.
  - Both releases' tokenizer, Parse and AstGen are vendored.
  - They produce one bs-owned superset Ast (0.17's plus two node tags)
    and one superset ZIR (0.17's, with 0.16's extra instructions as
    extended opcodes).
  - Sema, the Linter, diag and the caches see one Ast type and one ZIR
    type. Sema branches on the language only in the handlers whose meaning
    changed.
  - The cost to 0.17 builds is one field read in cold paths. Each phase
    must show that 0.17 builds stay within noise on the bench.
- The big pieces are:
  - 0.16 Sema semantics: `@typeInfo`/`@Type`, `@cImport`, `@bitCast`,
    std.builtin, switch and coercion details;
  - `bs build` for 0.16, which keeps package fetching and build-runner
    orchestration in the compiler;
  - per-version link inputs, including Mach-O debug info that 0.16's
    std.debug can read;
  - a second conformance matrix.
- Estimate: 11 to 15 agent-weeks, or about 7 to 9 calendar weeks with three
  threads working in parallel. The Sema path (phases 1 to 4) is the
  critical path. Every phase lands on its own, and 0.17 builds are
  unaffected at each step.
- One AGENTS.md rule doesn't survive: "reuse `std.zig.Ast` … and
  `std.zig.AstGen.generate` … Do not fork or reimplement them." With two
  languages, at least one frontend has to be vendored, because bs is built
  by one zig whose std carries one frontend. When 0.18 arrives while bs
  is still built with 0.17.1, the newest frontend has to be vendored too.
  The proposed wording is in "AGENTS.md wording".

## Measurements

All on x86_64-linux with today's bs (main f0dd3c56, ReleaseSafe build),
using `tools/conformance/run.py` from a scratch copy whose `upstream`
points at the 0.16.0 source tree.

- **Upstream 0.16.0 baseline:** 2108 pass and 27 skip of 2135 tests in
  110 files, with the self-hosted x86_64 backend.
  - The harness's `test_runner.zig` is written against 0.17's
    std.testing, so I ported its setup lines to 0.16 (`allocator_instance
    = .{}`, `deinit() == .leak`) for this run. That's a 10-line
    difference, to keep as `test_runner_0_16.zig` in phase 7.
- **Whole files** (as the harness runs them): 498/2108 (23.6%). 45 of the
  110 files don't compile, and in the 65 that do, 498 of 500 tests pass. A file
  fails as a whole as soon as one test uses something 0.16-only, which
  hides the real figure, hence the next measure.
- **Each test in its own file** (every container-level declaration of
  its file, plus the one test): 1756/2108 (83.3%). Of the 352 failures:

  | Cause | Tests | Belongs to |
  |---|---|---|
  | `a ** n` (0.17 reads two `*` and reports the whitespace) | 137 | frontend |
  | `@typeInfo(T).@"struct".fields` and friends (0.17 returns struct-of-arrays) | 51 | Sema: `@typeInfo`/`@Type` |
  | `i0` | 11 | frontend and Sema |
  | std APIs removed in 0.17 (`std.meta.Int`, `std.meta.Tuple`) | 11 | 0.16 std |
  | peer types of error-set supersets (cast.zig) | 10 | Sema, not examined |
  | `void{}` | 5 | frontend |
  | `errdefer \|err\|` | 4 | frontend and Sema |
  | `@bitCast` of extern structs, empty enums, internal linkage, `@bitSizeOf`, C pointer to optional, an asm output type, array coercion to undefined, a std.builtin union name | 20 | Sema |

  The 51 `@typeInfo` failures understate that difference. With 0.16's
  own std, which reads `.fields` throughout std.fmt and std.meta, nothing
  compiles until 0.16's shape exists.
- **Bodies, compared by text:** 1475 of 0.16's 2158 tests are
  byte-identical to a test with the same name in 0.17's tree, and bs
  passes all of those today. Of the 647 that changed, most changed only
  mechanically:
  - a skip on `builtin.zig_backend` dropped (454 removed lines);
  - `@intFromEnum` → `@backingInt`;
  - `.fields` → `field_names`/`field_types`;
  - `**` → `@splat`.
- **0.16's compile-error cases** (`--compile-errors` on 0.16's
  `test/cases/compile_errors`): 902/975 exact and 949/975 at the same
  location. On 0.17's cases it's 974/996 exact.
- **With 0.16's lib dir** (`ZIG_LIB_DIR`), nothing compiles. 0.16's std
  uses `**` in dozens of files and `i0` in several. So there's no way
  to measure 0.16's std before phase 1.

What I didn't measure: aarch64-linux and aarch64-macos, std tests,
cases, langref and c-abi for 0.16. All of those need the 0.16 frontend
first. Phase 7 adds them.

## What changed between 0.16 and 0.17, as bs sees it

Sources:
- the 0.17.0 release notes ("Language Changes", "Standard Library",
  "Build System");
- a diff of the two trees: Parse.zig +253/−547, AstGen +719/−720, Zir
  +286/−239, upstream Sema.zig +4483/−3562, std 428 files, std.Build
  +1300/−1305, `test/behavior` 97 of 167 files;
- a per-function diff of upstream's Sema.zig: 366 of 605 functions
  changed, 17 removed and 32 added. After normalizing `@intFromEnum`/
  `@backingInt` and `std.builtin`/`std.lang`, 5463 lines changed.

### Syntax and AST

- **0.16 only:**
  - `a ** n` (Ast node `array_mult`);
  - `errdefer |err|` (in 0.16 the `errdefer` node's data is
    `.opt_token_and_node`; in 0.17 it's `.node`);
  - `void{}` (an AstGen rule, not a parse rule);
  - `i0` (a primitive);
  - `@cImport`, `@cInclude`, `@cDefine` and `@cUndef`.
- **0.17 only:** `@backingInt`, `@fromBackingInt`, `@divCeil` and
  `@SpirvType`.
- The tokenizer differs by `**` and `.**`. 0.17's parser also gained a
  `recover` mode.
- Otherwise the node tags are identical: 0.16's set is 0.17's plus
  `array_mult`. The error tags differ by six parse errors that only 0.16
  has.

### ZIR

- Instruction tags (`Zir.Inst.Tag`, `enum(u8)`):
  - 0.16 only: `array_mul`, `c_import`, `defer_err_code`,
    `ret_err_value_code` and `validate_deref`;
  - 0.17 only: `backing_int`, `deref`, `div_ceil`, `from_backing_int`,
    `from_backing_int_arg_ty` and `ref_deref`;
  - because tags are numbered in declaration order, every tag after
    the first difference is renumbered.
- Extended opcodes:
  - 0.16 only: `builtin_value`, `c_define`, `c_include` and `c_undef`;
  - 0.17 only: `std_lang_value` and `reify_spirv_type`.
- Static refs: 0.16's `Zir.Inst.Ref` has `i0_type` at index 2, so every
  static ref after it is off by one between the releases.
- Payloads:
  - 0.17 adds `src_column` to several declaration and type payloads, and
    replaces `abs_line` with `src_line` plus `src_column`;
  - 0.16 has `DeferErrCode` and `ArrayMul`, and a `defer_err_code` data
    variant;
  - `BuiltinValue` became `StdLangValue`, with a new member;
  - `findTrackableRoot` became `findTrackableFields`, and the tracked
    `explicit_types` became `type_decls`.
- Import discovery (`Zir.ExtraIndex.imports`, `Zir.Inst.Imports`) is
  identical in both (cache thread).
- How `.*` lowers: 0.16 emits `validate_deref` plus `load`, and 0.17
  emits `deref`/`ref_deref`.

### Sema

**Real semantic changes.** Both behaviors have to stay, each in its own
language:

- **`@typeInfo` and `@Type` / `@Struct`/`@Union`/`@Enum` reification.**
  0.16 returns `std.builtin.Type` with arrays of `StructField` and
  friends. 0.17 returns `std.lang.Type` in struct-of-arrays style
  (`field_names`, `field_types`, …), with `.attrs.callconv` on functions.
  Upstream's `zirTypeInfo` is the most-changed function (632 lines), and
  the reify functions follow. This is the first blocker for 0.16's std.
- **`@bitCast`.** 0.17 reinterprets the logical bit representation:
  extern structs and unions are rejected, and casting to an enum gets a
  safety check. 0.16 casts the in-memory bytes and allows extern
  aggregates. On bs's little-endian targets the run-time results mostly
  agree. What differs is which casts are accepted, the enum check, and
  comptime casts of arrays and vectors.
- **`@hasDecl`.** In 0.16 it is true for private declarations in the same
  file; in 0.17 it isn't.
- **Slices of comptime-known length.** 0.17 allows `slice.*` and coercion
  to `*[N]T`, and 0.16 rejects both. bs may reject more than upstream, but
  accepting more than 0.16 would change its compile-error results, so this
  gets a gate.
- **Coercion and peer types.** Upstream's `coerceExtra` changed by 560
  lines, `coerceInMemoryAllowed` and `resolvePeerTypes` too. Most is
  restructuring. The measured differences are cast.zig's error-set
  supersets and array coercion to undefined.
- **Switch.** 0.17 reworked switch prongs and captures
  (`validateSwitchBlock`, `analyzeSwitchCaptures`, …). The language-level
  differences have to be found case by case against 0.16's behavior and
  compile-error tests. Most of the code change is internal.
- **Smaller changes:**
  - empty enums must be backed by `noreturn` in 0.17;
  - `internal` and `link_once` linkage exist in 0.16 only;
  - 0.17's `std.lang.panic` handlers add `unexpectedErrorCode` and
    `loadUninstantiableType`, so the panic calls Sema emits follow 0.16's
    handler set;
  - `@bitSizeOf` differs on some types;
  - one inline asm output type differs.

**Renames and reshuffles.** These are cheap, but they reach everywhere:

- std.builtin became std.lang. Every type Sema looks up in std
  (`CallingConvention`, `Type`, `AtomicOrder`, `panic`, `StackTrace`,
  `returnError`, …) goes through `stdLangDecl`/`stdLangType`
  (Sema.zig:7050). For 0.16 that becomes a per-language root name plus a
  short table of paths that moved.
- `OptimizeMode` became `Optimize`, with tags `debug`/`safe`/`fast`/`small`
  instead of `Debug`/`ReleaseSafe`/….
- The `builtin` module's text, generated by Builtin.zig, needs a 0.16
  variant. That includes `zig_version`, and the `cpu`/`os`/`abi`
  constants that 0.17 only deprecated.
- The CPU that builtin names comes from 0.16's own features and models
  (src/cpu016.zig, from src/cpu_tables_0_16.zig, which
  tools/cpu_tables_0_16.py dumps from zig 0.16.0; regenerate with
  `--check` when a release is added). 0.17 renamed, added and dropped
  some (`max_interleave_factor_4`, `apple_a14`), and on a Mac 0.16
  detects a different model from `hw.cpufamily`. One gap remains: on
  an aarch64 Linux host, 0.16 detects a native CPU from its ID
  registers, while bs names 0.17's detected CPU in 0.16's features.
- In 0.16, `@intFromEnum`/`@enumFromInt` are the only spelling. In 0.17
  they are deprecated aliases of `@backingInt`/`@fromBackingInt`. Sema
  already handles both.

**Removed in 0.17 but present in 0.16:**

- `@cImport` (`c_import`, `c_include`, `c_define`, `c_undef`). This
  is a new feature for bs. Sema collects the header, runs translate-c,
  and imports the result as a module.
- `**`, through `array_mul`. Sema already has array concatenation, and
  repeating an array is a small extension of it.
- `errdefer |err|`, through `defer_err_code` and `ret_err_value_code`.
- `i0` and `void{}`. AstGen handles `void{}`.

**Added in 0.17, absent from 0.16:** AstGen16 rejects the new builtins on its own.
Sema features without a builtin need a gate when 0.16 rejects them; the
slice dereference above is one.

## Design

### Selecting the language

- **The type:** `Lang = enum(u8) { v0_16, v0_17 }`, fixed for a whole
  compilation and stored in `Zcu`. Each Sema copies it into a field when
  it starts.
- **`bs build`** reads the root package's `build.zig.zon`:
  - a `minimum_zig_version` of 0.16.x selects 0.16;
  - 0.17.x, or no `minimum_zig_version`, selects 0.17;
  - anything older than 0.16.0 or newer than 0.17.x is an error that names
    the two supported versions.
- **Getting the language to the steps.** `bs build` passes it to every
  compile step it serves. 0.16's std.Build passes no such flag, so `bs
  build` sets an environment variable that its child processes inherit.
- **`build-exe`, `test` and `run`** take an explicit `--zig-version
  0.16|0.17` flag. Without the flag, see open question 1.
- **Dependencies** take the root's language, as upstream has only one
  version per toolchain.

### Frontend

Recommended: bs owns its frontend, with a superset Ast and a superset ZIR.

- **Where it lives:**
  - Vendor 0.17.1's `tokenizer`, `Ast`, `Parse`, `AstGen`,
    `AstRlAnnotate`, `BuiltinFn`, `Zir`, `Zoir` and `ZonGen`, plus
    `string_literal`, `number_literal` and `primitives`, under
    `frontend/`, with upstream's MIT notice.
  - From 0.16.0, vendor only `Parse` (frontend/v0_16/Parse.zig) and
    `BuiltinFn`'s table (frontend/v0_16/BuiltinFn.zig), ported to build
    with zig 0.17.1. The tokenizer, AstRlAnnotate and AstGen are 0.17's
    with 0.16's differences folded in behind a language test (see the
    superset ZIR below); `Ast.parse` takes the language and records it in
    the tree.
- **The superset Ast** is 0.17's Ast plus two appended node tags,
  `array_mult` and `errdefer_payload` (0.16's `errdefer |e|` with
  `.opt_token_and_node` data), plus 0.16's six extra error tags.
  - 0.17's Parse never produces the new tags.
  - 0.16's Parse is ported to produce this Ast. That works because the
    rest of the node tags are identical.
  - The Linter, diag, fmt and ast-check then work on one Ast type, today's
    with its import changed.
- **The superset ZIR** is 0.17's ZIR, with 0.16's extra instructions added
  as extended opcodes. They can't go into the `u8` tag space: 0.17 uses
  254 of its 256 values.
  - The 0.16 additions: `array_mul`, `c_import`, `c_include`, `c_define`,
    `c_undef`, `defer_err_code`, `ret_err_value_code`, `validate_deref`
    and `builtin_value`.
  - One AstGen lowers both languages: 0.17's, where each place 0.16
    means something different tests `tree.language` and does what
    0.16.0's AstGen does. Built while doing phase 1, this replaced the
    plan to port 0.16's AstGen beside 0.17's: diffing the two showed
    about 20 language differences (`**`, `errdefer |e|`, `@cImport`,
    `.*` on slices, `i0`, loop error-trace restores, alignment and
    destructure allocation rules, the slice-length sentinel) against
    many more ZIR shape changes (`src_column`, field baselines,
    `findTrackableFields`, terminating breaks in `callconv`/return-type
    bodies, declaration body order). A port would have had to redo every
    shape change by hand; the merge gets them for free, and a 0.17 tree
    takes exactly today's path.
  - `i0` lowers to an `int_type` instruction, as 0.16 does, so static ref
    numbering stays 0.17's.
- **Selection** happens once per compilation: Frontend parses every file
  with the compilation's language, and AstGen follows the tree. No
  generic lowering loop is needed.
  - Every other Frontend path (`collectImports`, the blob encoding,
    `Zir.Inst.Data` layout) sees the superset types.
  - The per-file cost is nothing.
  - The ZIR blob salt (Frontend.zig:1235, today `"bs zir " ++ bs's own zig
    version`) gains the language. That separates the blobs, the stat
    index and `File.content_hash`.
- **Check:** for each file in 0.16's lib/std and `test/behavior`, the
  vendored 0.16 AstGen gives the same errors and the same instruction
  count by tag as zig 0.16's `ast-check -t`. 0.17's output stays
  byte-identical to today's.

Alternatives I rejected:

- **Two independent Zir types, with Sema generic over them.** That doubles
  a 24k-line Sema in the binary and in bs's build time, and every later
  Sema fix has to keep both instantiations compiling.
- **Translating 0.16 ZIR into 0.17 ZIR after AstGen.** It re-derives
  information AstGen threw away (columns, tracking), so it's more code
  than porting AstGen, for the same result.
- **Keeping `std.zig.*` for 0.17 and vendoring only 0.16.** It's half the
  vendoring, but then the Ast type differs between the languages, so the
  Linter, diag and fmt have to be generic. It also has to be redone when
  0.18 arrives before bs's own zig moves to 0.18.

### Sema: one Sema, branching on the language where meaning differs

- **0.16-only instructions dispatch themselves:** their handlers run only
  in 0.16 compilations, at no cost to 0.17.
- **Shared instructions whose meaning changed** branch on `sema.lang` in
  their handlers. From the per-function diff and the failures, that's
  about 40 to 80 sites:
  - `@typeInfo` and reify (the largest, best kept as separate 0.16 and
    0.17 functions behind one branch);
  - `@bitCast`, `@hasDecl`, and slice dereference and coercion;
  - the error-set peer rules, empty enums, linkage and the panic handler
    set;
  - a handful of switch and coercion details.
- **std lookups** go through `stdLangDecl` with a per-language root
  (`builtin` or `lang`) and a table of the paths that moved.
- **Builtin.zig** emits the 0.16 text for 0.16.
- **diag's fixes are per language.** A fix must never suggest a 0.17-only
  construct to a 0.16 program, such as the `@Int` hint for `std.meta.Int`
  or `@splat` for `**`. Each fix that names a builtin or a std path gets
  a language check, and the compile-error measure checks it.
- **Unchanged:** the bytecode comptime evaluator, the IR, InternPool
  (stable hashes key on content, and the language enters through the cache
  root) and the backends. The one exception is the panic calls Sema emits.
- **`@cImport` for 0.16:**
  - `c_include`, `c_define` and `c_undef` build the header text in the
    `c_import` block, as upstream 0.16's `zirCImport` does.
  - bs then runs 0.16's translate-c, built from
    `lib/compiler/translate-c` of 0.16's lib dir by bs itself in 0.16 mode,
    as bs builds 0.17's today. The tool and its outputs are keyed by
    ToolRecord (tool identity plus lib dir).
  - The output is imported as a module. Builds that import C use the
    inputs record instead of the incremental cache, so header edits
    rebuild them (architecture.md, "Zig 0.16's `@cImport`").

### std and the lib dir

- **Where 0.16's lib dir comes from:** the user's zig 0.16.0 install,
  found as 0.17.1's is today. `toolchain.findZig`/`check` (toolchain.zig)
  look for:
  1. `BS_ZIG_0_16`;
  2. a `zig` on PATH whose `zig version` is 0.16.0;
  3. `~/.cache/bs/zig-<host>-0.16.0`.

  The install has to exist anyway, because 0.16's C and C++ go through its
  `zig cc` (Clang 21 with libc++ 21 headers). Mixing 0.17's Clang 22 with
  0.16's lib dir isn't a combination upstream tests (link thread).
- **Why not fetch it:** bs has no fetcher of its own. The package fetcher
  is upstream's Maker code running inside the build runner, and the source
  tarball (275 MB unpacked) brings no Clang.
- **Later convenience:** `bs` could offer to download the official binary
  tarball for the host into `~/.cache/bs`, checked against a pinned
  sha256, as `.agents/setup` and flake.nix already do.
- **When no 0.16 install is found:** a 0.16 compilation fails with a
  message that says which install to get and where bs looked. 0.17
  builds are unaffected.

### Link inputs and target libraries (link thread)

- **Version-specific tables.** The linkers bind by symbol name, so they
  don't change. Three things in bs's own code are tied to a version:
  - **The compiler_rt export table** (`src/compiler_rt_exports.zig`,
    generated by `tools/compiler_rt_exports.py`). 0.17 merged
    compiler_rt's 270 files into 140, so 0.16 needs a second generated
    table.
  - **The recipes copied from upstream's `src/libs`** (CSource.zig's
    libc_nonshared.a, musl, libc++/libc++abi, libunwind, tsan, ubsan_rt).
    They differ by 7 to 74 lines each, so there's one recipe per version.
    Each table is a value chosen by version, not if-branches, and CI
    generates both from the two source trees so that they can't drift.
  - **Which `zig cc` compiles the C:** the selected language's.
- **Formats that need no change:**
  - glibc abilists keep the same format.
  - 0.16's libSystem.tbd (SDK 26.4) is a subset of 0.17's (27.0).
  - TLS layout, the entry symbol and std.start's expectations are the
    same on x86_64 and aarch64.
- **ELF debug info:** std.debug in 0.16 reads bs's DWARF the same way,
  including the inlined frames.
- **Mach-O debug info is the one real linker gap.** 0.16's std.debug has
  no dSYM support; it finds DWARF only through STABS (`N_SO`, `N_OSO`,
  `N_FUN`) pointing at object files. So a 0.16 program on macOS would
  print traces without file:line. Fix: for 0.16, the Mach-O linker writes
  STABS whose `N_OSO` names an object carrying the DWARF, with the right
  mtime, produced by the dSYM writer, and cache relinks keep that object
  in step with the executable.
- **c_abi:** 0.16's `test/c_abi` is a third the size of 0.17's generated
  suite, effectively a subset. No ABI rule changes on x86_64 or aarch64
  were found.

### `bs build` (cache thread)

- **Serving compile steps** to 0.16's runner takes about 50 lines in
  `serve` (main.zig):
  - send `zig_version` "0.16.0", since 0.16's Step.zig fails the step on a
    mismatch;
  - don't send `serveConfig`, which is 0.17-only;
  - send paths with the `cwd` prefix instead of `build_root`. 0.16's
    PathPrefix has four values, and its runner does
    `@enumFromInt(prefix - 1)`, so a fifth value panics.
  - The `bsp_*` messages and the client `args` message are new in 0.17
    and aren't needed.
- **The large part is what 0.16 keeps in the compiler.** 0.16's `cmdBuild`
  (0.16 src/main.zig:4958, 696 lines):
  - fetches packages (src/Package/Fetch.zig 2260 lines, git.zig 1750,
    Manifest.zig 734);
  - generates `dependencies.zig`;
  - compiles `build_runner.zig` with `@build` and each dependency's
    `build.zig` as modules;
  - runs it, and loops for lazy dependencies through the `-Z` results
    file.

  0.17 moved all of this into the Maker, which bs just compiles
  (BuildRunner.zig, 201 lines). bs would reimplement it for 0.16.
- **Package fetching can be shared.** The package format is unchanged
  between the releases (Manifest.zig differs by 16 lines of renames,
  Fetch.zig by 316, git.zig by 16). So bs can fetch with a tool it
  compiles from 0.17's Maker/Fetch.zig and share `<global>/p`.
- **Web UI:** BuildWeb's embedded wasm is 0.17's client. 0.16's web UI
  (`--webui`) needs its own build, or stays unsupported at first.

### Caches

From the cache thread:

- **The root key** is `compilationKey`'s `id` string (Incremental.zig).
  Adding the language there reaches:
  - the per-decl store, which needs it most. Its `src_hash` is AstGen's
    unsalted per-declaration hash, so without it the same declaration
    would share a key across languages;
  - the donor key, the compilation key and the output digests;
  - the build runner hash and the `bs/compiler` identity file;
  - the translate-c tool directory and CSource's bs key.
- **Keys the root doesn't reach:**
  - the ZIR cache, through its own salt (see "Frontend");
  - `runBinPath` (main.zig), which hashes the lib dir and args but not the
    seed. Add the language there.
  - ToolRecord, on purpose. It keys on the tool's identity and the lib
    dir, which already separates the languages.
- **Artifacts built from lib-dir sources** in the global cache (musl's
  libc.a, libc++, libunwind, libc_nonshared, the C batch summaries) each
  need to be checked for a key that includes the language or the lib dir.
  Some may be keyed by bs's version and flags alone (link thread).
- **Strings that become per-compilation:** `main.zig_version` and
  Builtin.zig's `zig_version_string`.

The root is the language, not a lib-dir digest. Default-lib builds
deliberately skip statting std (`trusted_lib`), and `--zig-lib-dir` can
point anywhere.

### Conformance

- **Per language and per target:**
  - `run.py` gains `--zig-version 0.16|0.17`. It selects
    `upstream-0.16/` (a second symlink, which `.agents/setup` installs
    next to `upstream/` from the official tarballs) and
    `baseline/0.16/`, and passes the language to bs.
  - Baselines are computed with zig 0.16.0 on all three targets, using the
    0.16 test runner. Behavior was computed for x86_64-linux above.
  - The measures: behavior, std, std+libc, compile errors, cases, langref,
    c-abi and incremental (0.16's `test/incremental` has 37 files).
  - The edit-verify and sched-check variants run too.
- **Visibility:** `just conformance` and the chain print both languages
  side by side.
- **CI:** CI blocks on the full 0.17 set as today. It adds 0.16 behavior,
  std and compile errors on x86_64-linux, and runs the full 0.16 matrix
  (aarch64-linux, aarch64-macos, langref, cases, c-abi) nightly. That
  keeps CI time from doubling. The full matrix moves to blocking once
  0.16 is at 100%.
- **The corpus** records each project's `minimum_zig_version` and builds
  0.16 projects in 0.16. Projects that still require 0.16 become
  testable, though I haven't counted how many.

### Lint and the upcoming `.bs.zon`

- **The rules apply as they are to 0.16 projects.** ziglint 0.8.1
  supports 0.16, and none of the 34 rules depends on a 0.17-only
  construct:
  - the naming, style, import and line rules are syntactic, and they run
    on the superset Ast;
  - Z003 reports the selected parser's errors;
  - Z011 reads deprecation doc comments from the selected lib dir's std,
    which is right for 0.16;
  - Z010, Z029 and Z034 take their types from Sema, so they follow once
    Sema runs 0.16.
- **Measure:** run `test/lint`'s ported suite in 0.16 mode, plus the
  corpus's configured 0.16 projects.
- **`.bs.zon`:** I don't know its planned schema. I recommend that it
  doesn't carry the language, since the owner chose `build.zig.zon`, and
  that its lint settings apply to both languages.

### Compile-time cost for 0.17 builds

The design keeps the 0.17 hot path unchanged:

- no extra instruction tags in the `u8` space;
- no new branches in instruction dispatch;
- one per-compilation field read at each of the 40 to 80 branch sites,
  most of them in cold builtins;
- one per-file AstGen choice;
- a cache salt that is longer by a byte.

Expected cost: within noise. Every phase that touches Frontend, Sema or
the caches reports bench's 0.17 numbers (`bench/bench.py`'s workloads,
cold and warm), interleaved before and after, and doesn't land a
regression. The binary grows by 0.16's tokenizer, Parse and AstGen plus
the 0.16 Sema handlers, and bs's own build time by the same code; phase 1
reports both.

## Phases

Each phase lands on its own, with 0.17 builds unchanged and the full
check chain green. The estimates are for one agent thread.

| # | Phase | Lands when | Estimate |
|---|---|---|---|
| 0 | Plumbing: `Lang`, `minimum_zig_version` and `--zig-version`, finding zig 0.16, lib dir per language, the language in every cache key (root, ZIR salt, `runBinPath`, lib-dir artifacts), per-compilation version strings | 0.16 selected gives a clear "not supported yet" error, and the cache keys are proven separate | 3–5 days |
| 1 | Frontend: vendored 0.17 and 0.16 frontends, superset Ast and ZIR, Frontend selection, Linter/diag/fmt on the superset Ast | 0.16 AstGen matches zig 0.16 `ast-check` on 0.16's std and behavior, 0.17 output unchanged, bench in noise | 1–1.5 weeks |
| 2 | Sema core for 0.16: std.builtin lookups, the `builtin` module text, 0.16-only instructions (`array_mul`, `validate_deref`, `defer_err_code`, `ret_err_value_code`, `i0`), `@typeInfo`/`@Type`, `@bitCast`, `@hasDecl`, coercion, switch and peer differences, panic handlers, linkage, empty enums | 0.16 behavior at 100% on x86_64-linux, 0.16 std tests passing, bench in noise | 3–4 weeks |
| 3 | `@cImport` for 0.16: translate-c from 0.16's lib dir built by bs, cached; `c_import` and friends in Sema | 0.16 behavior's and std+libc's `@cImport` users pass | 1 week |
| 4 | Compile errors for 0.16: message shapes and per-language diag fixes | 0.16 compile-errors at 0.17's level; cases | 1 week |
| 5 | Link inputs (link thread): per-version compiler_rt table and CSource recipes, two zigs, Mach-O STABS/OSO for 0.16, cache keys of lib-dir artifacts | 0.16 std+libc, c-abi and the macOS stack traces pass | 2–3 weeks, parallel with 1–4 |
| 6 | `bs build` for 0.16 (cache thread): `cmdBuild` port, fetching through a tool built from 0.17's Fetch.zig, `serve` changes, passing the language to steps | 0.16's standalone builds and the corpus's 0.16 projects build | 1–2 weeks, parallel with 2–4 |
| 7 | Conformance and CI: `--zig-version`, `upstream-0.16`, baselines on three targets, chain and CI | every 0.16 measure visible, with CI blocking on the agreed subset | 1 week, starting with phase 1, then ongoing |
| 8 | Lint on 0.16: test/lint in 0.16 mode, corpus projects | rules match ziglint 0.8.1 on 0.16 projects | 2–3 days |

Total: 11 to 15 agent-weeks. With three threads (Sema: 0, 1, 2, 3, 4, 8;
link: 5; cache/frontend: 6 and 7's cache parts), it takes about 7 to 9
calendar weeks. The Sema path, about 6.5 to 8.5 weeks, sets the end
date.

The largest uncertainty is phase 2. The 83% figure is measured against
0.17's std. 0.16's std will bring its own uses of 0.16-only behavior,
starting with `@typeInfo`. The compile-error and diag work can also grow
once the 0.16 frontend lets the cases run with their real std.

Dropping 0.16 when 0.18 ships is the same work in reverse:
- delete `frontend/v0_16` and the 0.16 handlers;
- the branch sites become 0.17-or-0.18 sites;
- the extended opcodes shrink.

The superset approach is meant to make that rotation routine: each
release adds a vendored frontend and a set of branch sites, and drops
the oldest.

## AGENTS.md wording (for approval)

Intro:

> bs is an independent Zig compiler aimed at Go-class compile speed. It
> does not track upstream: it compiles two pinned Zig releases, the
> current one and the one before it (today 0.17.1 and 0.16.0), each with
> the std library shipped with it. When a new release ships, bs adds it
> and drops the oldest.

Scope, a new first item:

> - Language version: each compilation is in exactly one of the supported
>   languages. `bs build` takes it from the root package's
>   `build.zig.zon` `minimum_zig_version` (0.16.x → 0.16, 0.17.x or none →
>   0.17; anything else is an error). `build-exe`, `test` and `run` take
>   `--zig-version` and otherwise use the newest. Dependencies use the
>   root's language. Each language is complete: its syntax, ZIR,
>   semantics, std, compile errors and build system, all through bs's own
>   Sema, backends and linkers. C and C++ go through the matching
>   release's `zig cc`.

Scope, the rejection item, changed:

> … Without a `.ziglint.zon`, everything a supported release accepts must
> still compile and mean the same in that language, and each release's
> std and `test/behavior` must compile, since they are the conformance
> measure.

Architecture decisions, the frontend item replaced:

> - Frontend: upstream's tokenizer, Parse, AstGen and Zir for each
>   supported release, vendored under `frontend/` with upstream's
>   notice. They are ported only as far as compiling under bs's own Zig
>   needs, plus one bs-owned superset Ast and superset ZIR that both
>   releases' AstGen produce (see `docs/slop/zig-0.16.md`). Do not
>   reimplement them. Sema branches on the language only where meaning
>   differs.

Upstream reference:

> - `.agents/setup` installs upstream `zig` 0.17.1 on `PATH` and zig
>   0.16.0 at `~/.cache/bs/zig-<host>-0.16.0` in orbs, and symlinks their
>   source trees at `upstream/` and `upstream-0.16/` (gitignored). On a
>   Mac satellite it leaves the owner's `zig` alone; use
>   `~/.cache/bs/zig-aarch64-macos-<version>/zig` there.
> - Upstream `zig` of the same release is the oracle for each language.
>   When semantics are unclear, write a small program and compare bs's
>   behavior and output with that release's. Do not guess from memory.
> - Conformance measure: per language, the share of that release's
>   `test/behavior` (and std, compile errors, cases, langref, c-abi) that
>   bs compiles and passes on each target. Keep both languages' numbers
>   visible. Measure them with `tools/conformance/run.py --zig-version`.

Development:

> - bs is written in Zig 0.17.1, independently of the languages it
>   compiles; its own Zig moves to the newest supported release when that
>   release is added. Build with `zig build`; test with `zig build test`.
> - A change to Sema, the frontend or the caches runs the check chain in
>   both languages, and reports 0.17 compile-time numbers.

## Open questions, with recommendations

1. **Plain `build-exe`/`test`/`run` without `--zig-version`.**
   - The owner's rule says the newest. But agents often run `bs test
     src/x.zig` inside a 0.16 project, and would get 0.17 errors.
   - Recommendation: look for the nearest `build.zig.zon` from the root
     source file upwards, stopping at the first directory with a
     `build.zig`, as `.ziglint.zon` discovery already does (Config.zig),
     and use its `minimum_zig_version`. Otherwise use the newest.
     `--zig-version` overrides.
2. **A `minimum_zig_version` outside 0.16.0 to 0.17.x.** Recommendation:
   an error naming the supported versions and the field. Not a silent
   fallback, since a 0.15 or 0.18 program fails confusingly in either
   language.
3. **Dependencies whose own `minimum_zig_version` is newer than the
   root's language.** Recommendation: do what the selected release's
   upstream does for that case, so failures match upstream.
4. **No zig 0.16 installed.** Recommendation: require it for 0.16
   compilations, with a message that says what to install, and offer a
   pinned-sha256 download into `~/.cache/bs` as a later convenience.
5. **CI time.** Recommendation: block on 0.17's full set plus 0.16's
   behavior, std and compile errors on x86_64-linux. Run the rest of 0.16
   nightly until it reaches 100%, then block on it too.
6. **bs's own Zig version.** Recommendation: decouple it from the
   languages bs compiles. Move it to the newest supported release when
   that release is added, as its own change.
7. **0.16's `--webui` and the 0.16 build web client.** Recommendation:
   unsupported at first, with a clear error, and built only if a project
   needs it.
8. **The AGENTS.md "do not fork" rule.** Recommendation: replace it with
   the vendoring rule above. It's the one design rule this change can't
   keep.
