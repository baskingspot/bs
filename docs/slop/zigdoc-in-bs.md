# zigdoc as `bs doc`

Status: proposed (2026-11-08), for the owner's review. Nothing is built.
Written from main f5befc2 and zigdoc 4e8aabc (rockorager/zigdoc HEAD,
which is also baskingspot/zigdoc-wip's `main`; v0.5.1 plus five
commits). The owner's decisions so far are at the end. Agent skills, which
the owner added to this request, have a note of their own:
docs/slop/bs-skills.md.

The owner's request: fold zigdoc into bs, as ziglint's rules were folded
in. zigdoc prints documentation for a symbol, in a form agents already
use: `zigdoc std.ArrayList`, `zigdoc vaxis.Window`. bs already has the
build graph, the ASTs, ZIR and Sema's types, so docs from the compiler
can be faster and more exact than a separate tool's.

This note covers:

- the command and how it finds modules;
- what comes from the AST and what from Sema, and what each costs and
  caches;
- the output;
- what happens to zigdoc's `@init`, and the state of `bs init`;
- the oracle and the conformance measure;
- the cost on bs's tree, on std and on a corpus project;
- the AGENTS.md wording;
- the open questions, each with a recommendation.

## What zigdoc is, in the terms that matter here

These facts come from zigdoc's source at 4e8aabc and from running it. It
was built with upstream zig 0.16.0, ReleaseFast, and run on this orb
against 0.17.1's std.

- **Size.** 3,926 lines.
  - `main.zig` (1,024): the CLI, module discovery and the printer.
  - `Walk.zig` (1,163) and `Decl.zig` (286): upstream's autodocs walker,
    `lib/docs/wasm/Walk.zig` and `Decl.zig`, adapted to run natively. The
    `Category` union, "keep in sync with CAT_ constants in main.js", is
    upstream's.
  - Three custom build runners (0.14, 0.15 and 0.16, about 330 lines
    each).
  - `test_symbol_resolution.zig` (297).
  - Templates for `@init`.
- **Finding std.** It runs `zig version` and then `zig env`, and reads
  `std_dir`.
  - A symbol that starts with `std` reads and parses every `.zig` file
    under std, except those ending in `test.zig`, on every run. That is
    538 files and 17.2 MB in 0.17.1.
  - It does not read build.zig for such a symbol.
- **Finding modules.** For any other symbol it writes the runner for the
  installed zig's minor version into `.zig-cache/zigdoc_build_runner.zig`
  and runs `zig build --build-runner` on it.
  - The runner calls the user's `build()` and collects modules:
    `b.modules` (the `addModule` names), plus the direct imports of each
    compile step's root module, found through every top-level step's
    dependencies.
  - Since 4e8aabc it also makes the steps that generate a module's root
    file (`materializeGeneratedRoots`).
  - It prints `{"modules": {name: {root, imports}}}` as JSON. `main.zig`
    puts every name into one flat table, so of two modules with the same
    import name in different steps, the last one wins.
  - Roots that are not `.zig` files are skipped.
  - zigdoc has no 0.17 runner. On any 0.17 project, every symbol that is
    not under `std` fails with `error: UnsupportedZigVersion`. I checked
    this on bs's tree with `build_options.zig_lib_dir` and with
    `--dump-imports`.
- **Resolution.** `resolveHierarchical` splits on `.`. It finds the first
  part among public declarations by fully qualified name. It follows
  aliases (at most 64 hops) and then finds each further part among the
  public children.
  - If that fails, it falls back to a linear search by fully qualified
    name.
  - Private declarations are never shown.
  - Categories come from the AST alone: `namespace`, `container`,
    `function`, `type_function`, `global_const`, `global_variable`,
    `alias`, `error_set`, `primitive`, `type`, `type_type`. A struct with
    fields is a `container`, and one without is a `namespace`.
- **Output.** Plain text on stdout, with these labeled sections in this
  order:
  - `Symbol:` and `Location: <absolute path>:<line>`;
  - for each alias hop, `Alias Target:` and `Target Location:`;
  - `Category:`, then one of `Signature:` (functions), `Declaration:`
    (constants and variables) or `Type:` (containers and namespaces);
  - `Documentation:` (doc comments, each line indented one space);
  - `Fields:` (name, the type as source text, doc comments indented six
    spaces);
  - `Type Functions:`, `Types:`, `Functions:` and `Constants:`, which
    list names only;
  - `Source:` for a type function that has no members of its own.

  A miss prints `Symbol not found: '<symbol>'`. It then lists the
  available modules, or gives three possible reasons, and exits 1.
- **Tests.** `test_symbol_resolution.zig` has 10 tests:
  - simple, nested and private members;
  - a missing symbol;
  - alias chains, including a deep one;
  - container versus namespace;
  - type functions and functions.

  None of them runs. The `test` step's root is `main.zig`, which never
  imports the file, so `zig build test` reports `run test success` with
  zero tests. The file does not compile at 4e8aabc either:
  `test_symbol_resolution.zig:10:9: error: expected 2 argument(s), found
  1` (`Walk.init` now takes an `Io`). In practice zigdoc's suite is
  empty, and its oracle is its output.
- **Speed.** Median of 7 runs on 0.17.1's std: 0.30 s for
  `std.mem.Allocator.alloc`, 0.30 s for `std.Io.Writer` and 0.32 s for
  `std.ArrayList`, at 92.7 MB maximum RSS. Parsing std with `Ast.parse`
  alone takes 113–116 ms on one thread. The rest is reading 17 MB, the
  walk, and the `zig version` and `zig env` subprocesses.

**zigdoc's output is wrong in places** (0.17.1's std, 2026-11-08):

1. The return type in a signature is cut to its first token.
   `std.mem.Allocator.alloc` prints `pub fn alloc(self: Allocator,
   comptime T: type, n: usize) Error`, where the source says
   `Error![]T`. `std.fmt.allocPrint` prints `Allocator` for
   `Allocator.Error![]u8`, and `std.Io.Writer.print` prints `Error` for
   `Error!void`. `printSignature` stops at the first token after the
   closing parenthesis.
2. Constants print no `Declaration:` line (`std.heap.page_size_min`,
   `std.posix.fd_t`).
3. A `Documentation:` header with nothing under it (`std.posix.fd_t`,
   `std.c.fd_t`).
4. `std.c.fd_t`, a `switch (native_os)`, is categorized `type`.
5. `zigdoc std` warns `import target 'std/root' could not be read`.
6. `zigdoc std.ArrayList` prints the function's three-line source and no
   members. `ArrayList(T)` returns `array_list.Aligned(T, null)`, whose
   methods are what an agent asked for.
7. Declarations computed at comptime print nothing useful:
   - `std.posix.fd_t` is `system.fd_t`, through a comptime switch on the
     OS, which is `i32` on x86_64-linux;
   - `std.heap.page_size_min` is 4096 there.

   An AST alone cannot say either.

Items 1 to 5 are bugs. Items 6 and 7 are what Sema is for.

## The shape of the design

```
bs doc [options] <symbol>
```

Four steps, each reusing a part of bs that exists:

1. **Modules.** From `bs build`'s build graph, through the build runner
   bs already compiles and runs. bs writes no custom runner (section 1).
2. **Declarations, from the AST.** zigdoc's walker, ported. It runs on
   per-file *doc facts*, which are cached by content hash next to the
   file's ZIR, like the lint facts. A warm query parses nothing (section
   2).
3. **Facts only Sema has.** Resolved types, generic instances,
   comptime-computed declarations and constant values. They come from a
   *doc compilation*: the step's own compilation with the query added as
   one extra analysis root, replayed from the per-declaration cache. It
   runs only when the query or the AST walk needs it (section 3).
4. **Output.** zigdoc's text, with bs's extra facts on extra labeled
   lines, or one JSON object (section 4).

A build never computes doc facts and never runs a doc compilation, so
`bs build`, `build-exe` and the rest cost exactly what they cost today.

## 1. The command, and how it finds modules

**Symbols.**
- `bs doc std.ArrayList`, `bs doc vaxis.Window`: zigdoc's form, resolved
  as zigdoc resolves it.
- `bs doc 'std.ArrayList(u8)'`, `bs doc 'std.ArrayList(u8).append'`: a
  call with comptime arguments. bs documents the instance, which needs
  Sema.
- `bs doc src/Sema.zig:analyzeCall`: a file, then a declaration path.
  This shows private declarations too, because the agent named the file.
  (Open question 6.)
- A first part that names no module is looked up as a compile step's
  artifact name (`bs doc bs.main` on bs's tree). Then the message for a
  missing module lists the names that exist.

**Options.**
- `--step <name>` picks the compile step whose module graph and options
  apply.
- The usual target and module flags (`-target`, `-mcpu`, `-O`) apply
  when there is no build.zig.
- `--format=json` gives JSON (section 4).
- `--zig-lib-dir`, `--cache-dir` and `--global-cache-dir` work as in
  `bs build`.

**std and builtin without a project.** `std.*` and `builtin.*` need no
build.zig, as in zigdoc. They compile for the native target (clamped to
x86-64-v2, as always) in Debug, unless `-target` or `-O` says otherwise.

**The build graph.** Zig 0.17 split the build runner in two. The
configurer runs `build()` and serializes the whole graph. The Maker
(`lib/compiler/Maker.zig`, which `bs build` already compiles) reads that
graph and runs it. The Maker has `--print-configuration-path`, which
configures (through its configuration cache) and prints the path of the
serialized graph. std reads that file with
`std.Build.Configuration.loadFile`. So `bs doc`:

1. runs `bs build --print-configuration-path` as a child (the same
   runner, the same compiler identity file, the same configuration cache
   as `bs build`);
2. loads the configuration with std's loader;
3. for each `Compile` step, walks `root_module` and the modules' import
   tables, as the Maker does (`Step/Compile.zig`, `getModuleList`). That
   gives, per step, import name → module → root `LazyPath`, owning
   package, and the module's options. Source paths are relative to their
   package's root (`Package.root_path`).

Zigdoc needed a version-specific custom runner to dump the graph. This
reads the same graph through std, with no runner of bs's own. The shape
of `Configuration` is pinned with 0.17.1, as everything else in bs is.

Measured (2026-11-08, bs ReleaseFast from main f5befc2, a scratch
program that loads the configuration and walks every compile step):

| Tree | `--print-configuration-path` | Load and walk | Compile steps | Modules | Generated roots |
|---|---:|---:|---:|---:|---:|
| bs | 40 ms median (not cached: under bs, build.zig's `upstreamZig` calls `findProgram`, which poisons the configuration cache) | 0.31 ms | 6 | 19 | 13 (`build_options`, plus wasm and `.o` embeds that are not `.zig`) |
| libvaxis 0620b34 | 3.03 s first (compiles build.zig, fetches lazy uucode), then under 10 ms | 0.03 ms | 26 | 39 | 6 (uucode's tables, `build_config`, `build_options`) |

**Differences from zigdoc's module table:**

- **Per step, not flat.** A name that resolves to different roots in
  different steps (in libvaxis, `config.zig` is imported 79 times) is
  resolved in `--step`'s graph. The default is the first compile step
  under the default step that has the name. The output says which step
  answered, and the others that also have the name.
- **Modules no step uses.** Modules from `b.addModule` that no compile
  step imports are not in the serialized graph, so bs does not see them.
  zigdoc reads `b.modules` directly. libvaxis imports its public module
  in its test and example steps. A library with no such step would be
  missing. I have not checked how common that is across the corpus.
  Getting those modules would need a runner of bs's own, which the owner
  ruled out. So this is accepted, and `parity.py` counts it
  (`module-map`).
- **Generated root files** (an Options step's `build_options`, uucode's
  tables, a WriteFile, a translate-c output) exist only after their step
  runs. zigdoc makes those steps itself. bs takes the path from the last
  `bs build`:
  - Every compile step that `main.serve` runs already receives each
    module's real root path in its `-M` arguments.
  - bs records the table (module name, root, owning package) in
    `<local cache>/bs/modules/<output digest>`.
  - When a needed generated root has no record, or its file is gone,
    `bs doc` says which step makes it and gives the command
    (`bs build <step>`). It does not build implicitly, because a build
    runs arbitrary steps and can take minutes. (Open question 3.)

## 2. What comes from the AST

zigdoc's walker, `Walk.zig` and `Decl.zig`, is ported into `src/doc/`
with its MIT notice and with upstream's notice for the autodocs code it
came from, as `src/lint/Linter.zig` carries ziglint's. The printer comes
from `main.zig` the same way. ZIR has no doc comments, field type text
or signature text, so the AST is the source for everything zigdoc
prints. What changes is how often a file is parsed.

**Doc facts.** For each file content, one parse produces:

- each container's declarations: name, `pub`, line, and category as far
  as the file answers it;
- the signature as exact source text (fixing bug 1), and the
  declaration text for constants and variables (fixing bug 2);
- doc comments and container doc comments;
- fields, with type text and doc comments;
- for an alias, the unresolved target: a path of field names from a
  local declaration or an `@import` string;
- for a type function, its `return` expression's path, so the query step
  can follow `ArrayList(T)` to `array_list.Aligned`'s members (fixing
  bug 6 without Sema, for the members' names).

Facts depend only on the contents, never on the path or the module,
since ZIR is shared by content across projects. They go in
`<global cache>/bs/zir/<hash>.doc`. The name is a hash of the contents
and a doc-facts version, so a printer change invalidates facts and not
ZIR. Renewal and trimming follow ZIR's rules, as the `.lint` files do.

**On demand, never in builds.** The facts are written by `bs doc` the
first time it needs a file, from one parse. Builds do not compute them:
doing so in the lowering worker would make every first lowering pay for
something few builds use. (The lint facts are different: they are
produced only for covered files, and their findings fail the build.)

**A query** goes through the module table, the root file's facts, then
the target file's facts, following alias targets across files. Only the
files on that path are read. zigdoc's category for an alias member
(`Types:` versus `Functions:` in a member list) needs the target's
category, which comes from the target file's facts. Listing the members
of `std` itself (about 90 aliases into other files) reads about 90 small
fact files, or parses those files once.

Parse costs, Ast.parse in ReleaseFast on this orb:

| File | Bytes | Parse |
|---|---:|---:|
| std/std.zig | 11,021 | 0.08 ms |
| std/mem/Allocator.zig | 23,439 | 0.19 ms |
| std/array_list.zig | 105,697 | 0.74 ms |
| std/Io/Writer.zig | 120,027 | 1.12 ms |
| std/mem.zig | 202,434 | 1.89 ms |
| bs src/Sema.zig | 1,357,605 | 12.1 ms |
| all of std (538 files) | 17.2 MB | 113–116 ms |
| bs's src/ (80 files) | 6.2 MB | 55 ms |

So a cold `bs doc std.ArrayList` parses std.zig and array_list.zig,
about 1 ms of parsing, where zigdoc parses 113 ms on every run. A warm
query parses nothing.

## 3. What comes from Sema

Sema answers what the AST cannot:

- **Generic instances.** `bs doc 'std.ArrayList(u8)'` lists
  `array_list.Aligned(u8,null)`'s members, with each signature's types
  substituted: `append(self: *Aligned(u8,null), gpa: Allocator, item:
  u8) Allocator.Error!void`.
- **Comptime-computed declarations.**
  - `std.posix.fd_t` → `i32`;
  - `std.heap.page_size_min` → `4096`;
  - `std.c.fd_t`, whatever the target's switch prong gives;
  - any `const X = if (builtin...) A else B`.

  All of these are for the step's target.
- **Constant values** that are comptime-known and print short: integers,
  enum literals, short strings, types.
- **Resolved types** for declarations without an annotation (`const x =
  f();`), and canonical names for field types written through aliases.
- **Error sets**:
  - an explicit set prints its names;
  - an inferred one (`!T`) needs the function's body. bs prints it only
    when the body is already analyzed in the cache, or with `--errors`,
    which analyzes it.

**When Sema runs.**
- When the symbol has a call.
- When the AST walk stops at an expression it cannot follow: a
  `switch`, an `if`, a call, or a field of a value that is not a type.
- When the declaration is a constant whose value is comptime-known and
  short.

The common queries, a type, a function or a namespace with docs, finish
on the AST tier.

**The doc compilation.** Sema needs a compilation: the target, module
options, `builtin`, and the program's own root. std reads `std_options`
from `@import("root")`, and `page_size_min` can be overridden there. So
the query is evaluated *in the step's own compilation*, not in a
synthetic program:

- The query becomes one extra file of the root module (a `pub const q =
  <expression>;` with its imports). bs lowers it with AstGen and analyzes
  it as an extra root unit. Nothing else is a root: no `main`, no
  exports, no tests.
- The key is the step's compilation key salted with `doc`. Its manifest
  lives in `<local cache>/bs/doc/<key>`, apart from the step's, so a
  query never disturbs `bs build`'s edit builds.
- The first query of a step replays the step's manifest as a donor, the
  way a first build replays another compilation. Units the build already
  analyzed load green, and only the query's new units (the instance, its
  member types) are analyzed. Their entries go to the global store like
  any build's, so a second query hits.
- No codegen and no link. Today a `-fno-emit-bin` CLI build bypasses the
  cache: the cache answers an unchanged build only from a linked output
  (main.zig, "A step without a binary"). Measured: a hello world with
  `-fno-emit-bin` takes 0.21–0.28 s on every run, against 0.00 s
  unchanged with output. The doc compilation needs a manifest commit that
  needs no linked output (a check-only commit). That is the one new piece
  of cache machinery here. It is worth having for `check` steps anyway.
  The fallback is the hidden output `--listen=-` steps already link,
  which costs a near-empty link.

Measured (2026-11-08) as an upper bound. These are normal builds of a
root that forces every member type of a new instance (`for
(@typeInfo(T).@"struct".decl_names) |n| _ = @TypeOf(@field(T, n));` with
`T = std.ArrayList(i7)`), in a cache that already had other instances:

- 105–115 ms wall;
- `BS_TIMING`: sema 45–55 ms, codegen 14–16 ms, emit 5 ms, link 4 ms,
  cache record 32–33 ms;
- an unchanged repeat: 0.00 s;
- a fresh local cache with a warm global store: 14 ms (lazy donors).

The doc compilation drops the codegen, emit and link, and analyzes no
`main`. The target for a new instance is under 60 ms, and a repeat under
20 ms.

**Generic instances report once per source location.** A member of a
generic type prints its signature for the instance asked about, never
merged across instances.

## 4. The output

**Text, by default: zigdoc's form.** Agents and skills already read it.
The `zig-016` and `zig-017` skills in baskingspot/skills name zigdoc, and
the zigdoc README's examples are the shape agents expect. bs prints the
same labels in the same order, with three kinds of change:

- **Bug fixes.** Bugs 1 to 5 above are fixed:
  - exact signatures;
  - a `Declaration:` line for constants;
  - no empty `Documentation:` header;
  - categories for switch and if expressions;
  - no spurious warning.

  `parity.py` classifies each as `zigdoc-bug` (section 6).
- **Added lines**, which zigdoc's readers ignore because they are new
  labels:
  - `Step: <name>` when there is a build graph;
  - `Value: 4096` and `Resolved: i32` from Sema;
  - `Instance: array_list.Aligned(u8,null)` for a call;
  - `Errors: error{OutOfMemory}`;
  - `Members of: std.array_list.Aligned` when a type function's members
    come from the type it returns;
  - in member lists, each function's signature after its name (`append:
    pub fn append(...)`). zigdoc lists names only, which costs an agent a
    second query per method. This is the one change to an existing
    section's lines, and it is open question 8.
- **Better misses.**
  - The nearest existing prefix is resolved and its public members are
    listed as `candidates:`, the diagnostics' keyword, with edit-distance
    suggestions first.
  - `std.ArrayList.append` explains that `ArrayList` is a function and
    suggests `std.ArrayList(T).append` or `std.array_list.Aligned.append`.
  - The exit code stays 1, as zigdoc's.

`Location:` keeps zigdoc's absolute path for files under the zig lib
directory, since an agent opens it directly. Project files print
relative to the working directory, as bs's diagnostics do. (Open
question 4.)

**JSON**, with `--format=json`: one object per query, with the same
facts and short keys, following the diagnostics' conventions (absent
fields omitted, consumers ignore unknown keys):

```json
{"symbol":"std.mem.Allocator.alloc","file":"/…/lib/std/mem/Allocator.zig","line":222,
 "category":"function","signature":"pub fn alloc(self: Allocator, comptime T: type, n: usize) Error![]T",
 "doc":"Allocates an array of `n` items…","step":"install"}
```

Members are objects with `name`, `category` and `signature`. A miss is
`{"error":"not-found","candidates":[...]}`. Text stays the default for
the reason the diagnostics design gives: agents read stdout in a shell
tool, and text costs fewer tokens.

## 5. `@init` and `bs init`

**zigdoc's `@init` is dropped (owner's decision 1).** It wrote a
0.16-style build.zig, build.zig.zon, src/main.zig, .gitignore and an
AGENTS.md template, then ran `zig build` to scrape the fingerprint
suggestion. bs carries none of it.

**`bs init` does not exist today.** On main f5befc2, `bs init` prints
`error: unknown command: init` and exits 1. `bs fetch` does the same.
Owner's decision 2 assumes it exists, so this is the one place where
this note contradicts the brief.

**Making it upstream's costs one dispatch line.** In 0.17.1, `zig init`,
`zig fetch`, `zig libc` and `zig cache-cat` are not compiler code.
Upstream's `src/main.zig` compiles `lib/compiler/Maker.zig` and runs it
with the command name first, then `--zig-lib=`, `--zig=`,
`--global-cache=` and `--seed=` (`jitCmd`, `.build, .fetch, .init, .libc,
.@"cache-cat"`). `bs build` already compiles that same Maker with bs into
`<global cache>/bs/o/<hash>/maker` and runs it as `maker build ...`. So
`bs init [-m|--minimal]` is `maker init ...` with the same prefix, which
runs upstream's `cmdInit` (Maker.zig L2135) with upstream's templates
from the lib directory.

**Checked against upstream.** I ran bs's compiled Maker with `init` and
with `init -m` in a directory named `demo-proj`, and `zig init` and `zig
init -m` in another, then diffed the trees:

- `init`: the same four files (build.zig, build.zig.zon, src/main.zig,
  src/root.zig), byte for byte, and the same log lines.
- `init -m`: the same build.zig.zon and stub build.zig, and the same log
  line.
- The only difference is the fingerprint's random half:
  `0xa54541e58beefc51` against `0xa54541e54d390ce3`. The name checksum,
  `0xa54541e5`, is the same in both. Two upstream runs differ the same
  way.
- `minimum_zig_version` is `0.17.1` in both, since the Maker reports
  `builtin.zig_version_string`, which bs keeps as upstream's.

There are two deliberate non-differences. The log says "see `zig build
--help`", upstream's text, even when the user typed `bs`. And the
template's `.minimum_zig_version` names zig, not bs. Both are upstream's
output, which is what decision 2 asks for.

Recommendation (open question 11): wire `init`, `fetch` and `libc` to the
Maker together, since the cost is the same line. `fetch` is what
docs/slop/bs-skills.md builds on, and `zig fetch --save` is part of the
drop-in workflow. `cache-cat` is a debugging command and can come along.

## 6. The oracle and the conformance measure

The oracle is zigdoc 4e8aabc, built with upstream zig 0.16.0, the
version its `build.zig.zon` and `mise.toml` name. It is pinned like
ziglint 0.8.1. A zigdoc release with new behavior is ported deliberately
by bumping the pin. (Open question 7: tag a v0.5.2 at the repository
transfer and pin that instead.)

**Two facts shape the measure:**

1. zigdoc cannot read a 0.17 build graph.
2. zigdoc's own tests do not run.

So the measure is built from zigdoc's behavior, not from its suite.

**The suite: `test/doc/`.** One case per directory: source files,
optionally a build.zig, a query, and the expected stdout, run by
`zig build test` the way `test/lint` runs. Cases:

- zigdoc's 10 resolution tests, ported as cases with their names. Their
  expectations are rewritten as output, since the tests call internal
  functions. The suite's README says this, as test/lint/README.md does
  for ziglint's tests.
- The README's examples. `std.ArrayList`, `std.mem.Allocator` and
  `std.http.Server` work against the real std. `vaxis.Window` and
  `zeit.timezone.Posix` get small fixture projects.
- One case per category and per output section, and the miss messages.
- Each of the five bugs above, with the corrected output.
- bs-only cases: the call form, the file form, `Value:`, `Resolved:`,
  `Instance:`, `Errors:`, `--step`, generated roots, and JSON.

**Parity on real code: `tools/doc/parity.py`.** It runs the oracle and
bs on lists of symbols and compares output section by section.

- **The oracle harness.** Since zigdoc cannot read 0.17 graphs, the
  harness applies a small patch to the pinned zigdoc, kept in
  `tools/doc/zigdoc-oracle.patch`. The patch adds two things and changes
  no resolution or printing code:
  - `ZIGDOC_IMPORTS=<file>`: read the `{"modules": ...}` JSON from a file
    instead of running a runner. bs writes that file from its module
    table, in zigdoc's format.
  - a batch mode, symbols on stdin, so the std sweep parses std once
    instead of once per symbol.

  Without batch mode, a sweep of 20,000 symbols at 0.3 s each is 100
  minutes. With it, the parse happens once and each query is a lookup.
- **Symbol lists:**
  - The std sweep: every public declaration reachable from `std` by
    member listing. std's files hold 27,442 `pub` declarations, not all
    reachable through `std`.
  - The corpus libraries' public modules: libvaxis and zigimg, and the
    18 baskingspot projects in the lint parity set.
  - bs's own modules. These are few: bs's code is its executables' root
    modules, which only the file form reaches, and the oracle has no
    file form.
- **Classes:**
  - `match`.
  - `zigdoc-bug`: one of the five bugs, recognized by rule. For example,
    zigdoc's signature is a token prefix of bs's and ends at the return
    type's first token.
  - `sema`: bs adds lines. zigdoc's lines are all present and unchanged.
  - `members`: bs lists members zigdoc cannot see (a type function's
    returned type).
  - `module-map`: the symbol's module resolved differently (per step
    against flat, or a `b.modules` entry no step uses).
  - `bug`: anything else, to be fixed.
- **The bar:** zero `bug`. Every other class is counted in the results
  file, and the `sema` and `members` lines are spot-checked by hand.
- **CI:** a non-blocking `doc-parity` job, as `lint-parity` is, until the
  owner makes it block.

## 7. What it costs

**Budget:**
- Builds: no change at all, by construction. No doc facts, no doc
  compilation. The only addition is that `main.serve` writes the module
  table, one small file per compile step and only when it changes.
  Measured by callgrind A/B on the bench workloads, as the lint note
  specifies.
- `bs doc` on std, AST tier: under 20 ms warm and under 50 ms cold for
  one declaration, against zigdoc's 0.30–0.32 s.
- `bs doc` in a project, AST tier: the `--print-configuration-path`
  child plus the std numbers. That is 40 ms on bs's tree, whose
  configuration is poisoned (above), and under 10 ms on libvaxis once
  configured. zigdoc cannot answer here at all on 0.17.
- Sema tier: a new instance under 60 ms, a repeat under 20 ms. A step
  `bs build` never built pays its first analysis of std's referenced
  units, 0.2–0.3 s for a hello world, once.

**Where the time goes, per tree (estimates from the numbers above, to be
measured):**

| Query | Work | Estimate |
|---|---|---|
| `bs doc std.mem.Allocator.alloc`, cold facts | parse std.zig, mem.zig, mem/Allocator.zig (2.2 ms) and write 3 fact files | 10–20 ms with process start |
| same, warm | read 3 fact files | under 10 ms |
| `bs doc std`, cold | parse about 90 files (about 40 ms on one thread, spread over workers) | 30–60 ms |
| `bs doc vaxis.Window` on libvaxis | configuration child (under 10 ms), then vaxis's root and Window.zig | 20–30 ms cold, 15 ms warm |
| `bs doc src/Sema.zig:analyzeCall` on bs | no build graph needed for a file path; parse Sema.zig once (12.1 ms) | 20 ms cold, under 10 ms warm |
| `bs doc 'std.ArrayList(u8)'` after a `bs build` | doc compilation, instance units new | 30–60 ms |

**How it is measured.**
- `BS_TIMING=1` gains a `doc` line: configuration child, facts read,
  parses, doc compilation, render.
- `bench/bench.py` gains a doc workload: 20 std symbols, 10 libvaxis
  symbols and 10 file-form queries on bs's tree, with facts cold and
  warm. Median of 10 with the spread, and zigdoc's time next to bs's
  where zigdoc can answer.

## 8. AGENTS.md

Today's CLI bullet:

> CLI: drop-in for `zig build-exe`, `zig build-obj`, `zig run`, `zig
> test`, and `zig build` (bs compiles and runs the build runner and
> serves its compile steps over the `--listen=-` compiler protocol).

Proposed:

> CLI: drop-in for `zig build-exe`, `zig build-obj`, `zig run`, `zig
> test`, `zig build`, `zig init` and `zig fetch` (bs compiles and runs
> upstream's build runner, which also implements `init` and `fetch`, and
> serves its compile steps over the `--listen=-` compiler protocol). bs
> adds commands for agents: `bs doc <symbol>` prints a declaration's
> documentation from the build graph, the ASTs and Sema, and `bs skills`
> installs agent skills (docs/slop/bs-skills.md).

A new Scope bullet, after the ziglint one:

> zigdoc is folded into bs as `bs doc`, as ziglint's rules were. Its
> output is zigdoc's, the form agents already read, and zigdoc (pinned
> at one commit) is the oracle for it, as upstream zig is for the
> language. bs fixes zigdoc's wrong output and adds what only the
> compiler knows (resolved types, generic instances, comptime-computed
> declarations) on lines of its own, and never drops a fact zigdoc
> prints. zigdoc's `@init` is not carried over; `bs init` is upstream's
> `zig init`.

A new Development bullet:

> `bs doc` has its own conformance measure: zigdoc's cases ported to
> `test/doc/`, and `tools/doc/parity.py` against the pinned zigdoc on
> std's public declarations and the corpus's libraries. Keep both
> visible. A zigdoc release is ported deliberately, by bumping the pin.

The "Out of scope unless the user asks" bullet needs no change. Neither
does architecture.md's Diagnostics section: `bs doc` prints no
diagnostics, and its misses reuse only the `candidates:` keyword.
`docs/slop/architecture.md` gains a "`bs doc`" section when the first
branch lands, as the lint work did.

## 9. Steps, once approved

1. **`bs init`, `bs fetch` and `bs libc` through the Maker.** One
   dispatch in `BuildRunner.zig`, plus a test that diffs `bs init` and
   `bs init -m` against upstream's with the fingerprint masked.
2. **The module table.** `bs build --print-configuration-path`, the
   configuration loader, per-step module graphs, and the `serve` record
   for generated roots.
3. **The AST tier.** The walker port, doc facts, the zigdoc-format
   printer and its bug fixes, `test/doc/`.
4. **`parity.py`** with the oracle patch, and the `doc-parity` job.
5. **The check-only commit, then the Sema tier.** The doc compilation,
   `Value:`, `Resolved:`, `Instance:`, `Errors:`.
6. **JSON** and the members-with-signatures change, if approved.

## Open questions for the owner

1. **The command's name.** `bs doc <symbol>`, or `bs zigdoc` for
   recognition. *Recommendation: `bs doc`.* It reads like `go doc`, and
   the output form already says where it comes from.
2. **When Sema runs.** (a) Only when the AST walk stops or the query has
   a call; (b) only with a flag; (c) always. *Recommendation: (a).* The
   common query stays on the cheap tier, and the answers Sema adds are
   exactly the ones the AST gets wrong or cannot give.
3. **Generated module roots.** (a) Use the last `bs build`'s record, and
   name the command when there is none; (b) run `bs build <step>`
   implicitly; (c) skip them, as zigdoc did before September.
   *Recommendation: (a).* A doc query should not run arbitrary build
   steps. The message gives the agent the exact command.
4. **Paths in `Location:`.** Absolute, as zigdoc, or `std/...`, as bs's
   diagnostics. *Recommendation: absolute for lib files, relative for
   project files.* An agent opens the path next; the diagnostics'
   shortening saves tokens on repeated locations, which docs do not
   have.
5. **zigdoc's bugs.** Fix them in bs (classified `zigdoc-bug`), or
   reproduce them for parity. *Recommendation: fix, and send the same
   five fixes to zigdoc-wip,* so the oracle converges and the
   `zigdoc-bug` class shrinks at the next pin.
6. **The file form and private declarations.** `bs doc
   src/Sema.zig:analyzeCall` shows non-`pub` declarations of a named
   file. *Recommendation: yes.* An agent working in its own project
   needs its own code. Executables' code (all of bs's) is unreachable by
   module name, and zigdoc's "public only" rule still holds for module
   paths.
7. **The pin.** zigdoc 4e8aabc, or a release. *Recommendation: tag
   v0.5.2 at 4e8aabc when the repository transfers, and pin the tag.*
8. **Member lists with signatures.** zigdoc lists member names only.
   *Recommendation: print each function member's signature after its
   name in text, and always in JSON.* It is the one change to an existing
   section's content, and it saves a query per method. The parity tool
   compares names only for those sections.
9. **JSON.** *Recommendation: `--format=json`, one object per query,* as
   above. No other machine form.
10. **`b.addModule` modules that no step imports.** *Recommendation:
    accept the gap* and count it in `parity.py`. Covering it needs a
    runner of bs's own, which the brief rules out.
11. **`bs init` and the other Maker commands.** *Recommendation: wire
    `init`, `fetch`, `libc` and `cache-cat` together,* since each is the
    same dispatch to upstream's code, and add `zig init` and `zig fetch`
    to the AGENTS.md CLI bullet.
12. **zigdoc the tool.** *Recommendation: it stays standalone, like
    ziglint.* It serves Zig 0.14 to 0.16, which bs never will. Whether it
    gains a 0.17 runner or points at `bs doc` is the owner's call after
    parity.

## The owner's decisions (2026-11-08)

1. zigdoc's `@init` is dropped. bs does not carry it over.
2. `bs init` starts simple: it does what upstream `zig init` 0.17.1
   does. (It does not exist on main yet; section 5 has the check and the
   way to add it.)
3. Agent skills get a design: docs/slop/bs-skills.md.
