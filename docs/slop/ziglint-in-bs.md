# ziglint's rules as bs compile errors

Status: design note (2026-11-07), for the owner's review. Nothing is
built. Written from main 457f2c4 and ziglint v0.8.1
(rockorager/ziglint f6a3fc2).

The owner's request: bs reads `.ziglint.zon` and enforces ziglint's
rules as compile errors. There is no escape hatch: no flag or environment
variable reports findings without failing. `// ziglint-ignore:` comments
still apply, because they are part of the config language. Rules apply
only when a `.ziglint.zon` is present, and only to the files its `paths`
cover, never to std or to dependencies. A program without a config
compiles exactly as upstream accepts it.

This note says where each rule runs, how the config is found and enters
the cache, what a finding looks like, how parity with ziglint is
measured, what it may cost, and what changes in AGENTS.md and in bs's CI.
Open questions for the owner are collected at the end.

## What ziglint is, in the terms that matter here

Facts from ziglint v0.8.1's source (file and line references are at
f6a3fc2):

- 34 rules, Z001 through Z035. Z008 (comment divider lines) was removed in
  0.2.0, and its number stays retired. Every rule is on by default except
  Z033. One rule takes an option: Z024's `max_length` (default 120).
- A `.ziglint.zon` has two fields: `paths` (a list of files and
  directories) and `rules` (per rule `.enabled`, plus Z024's
  `.max_length`). Unknown fields fail the parse. ziglint then warns and
  falls back to defaults.
- ziglint walks each path as a directory tree. It takes only regular files
  ending in `.zig`. It skips any path with a component starting with `.`,
  or a component named `zig-cache` or `zig-out`. It also skips matches of
  the root `.gitignore`. Its pattern matching is simple: a component, a
  prefix, or a substring, with no globs or negation.
- Every rule reports through one `report` function. That function drops a
  finding when its line, or the run of `//` comment lines directly above
  it, contains `// ziglint-ignore:` followed somewhere by the rule's ID
  (`Linter.isIgnored`, Linter.zig L3723-3765). There is no block form and
  no file form.
- A parse error (Z003) stops all other rules for that file.
- ziglint resolves types with its own `TypeResolver`, a heuristic over
  the ASTs of the project's files and of std (TypeResolver.zig).
  - It resolves identifiers against root declarations only. Locals and
    parameters are `.unknown`.
  - It drops pointer and optional child types.
  - It resolves call return types only for root functions and for methods
    of user types.
  - It resolves only relative `@import`s, so build-system modules are
    unknown.
  - Where it answers `.unknown`, each rule falls back to syntax or says
    nothing.
- Two rules need the resolver: Z011 (deprecated calls) and Z027 (a
  declaration accessed through an instance).
- Nine use it as an assist over a syntactic fallback: Z006, Z010, Z012,
  Z015, Z023, Z029, Z032, Z033, Z034.
- Z011 also reads std's doc comments, and Z010 and Z029 read std's
  function signatures.
- The other 23 are syntax only. Z009 and Z021 also read the file name, and
  Z024 reads the raw lines.
- Output is `Z011: path:line: message` on stderr, with no column. The
  message text comes from one table (`Rule.writeMessage`, rules.zig
  L85-265). ziglint has no autofix. Some messages contain a suggested
  rewrite.
- `zig build test` runs 372 tests:

  | File | Tests | What they cover |
  |---|---:|---|
  | Linter.zig | 305 | 295 named by rule, 8 for ignore comments, 2 more |
  | TypeResolver.zig | 34 | |
  | rules.zig | 11 | |
  | Config.zig | 6 | |
  | main.zig | 5 | |
  | doc_comments.zig | 5 | |
  | ModuleGraph.zig | 4 | |
  | doc_tests.zig | 2 | One of these runs the 146 `zig` blocks in `docs/rules/*.md` against their `// expect: ZNNN` lines |

## The shape of the design

Each rule is placed in one of three ways:

- **Syntax pass.** It runs on a file's AST in the frontend's lowering
  worker, right after `AstGen.generate`, while the AST still exists.
  bs keeps no ASTs after lowering. The pass writes per-file *lint facts*,
  keyed by the file's content hash like its ZIR. An unchanged file
  therefore costs nothing on any later build.
- **Sema.** It runs where Sema already resolves the thing the rule asks
  about, with real types. Its findings travel with the unit's manifest
  node, so a unit that loads green replays them without being analyzed.
- **Report time.** The final step filters findings. It applies the
  config's rule switches and Z024's limit, and evaluates the few rules
  that depend on the file's path rather than its content. Then it removes
  findings covered by an ignore comment. This step is cheap, so editing a
  rule switch in `.ziglint.zon` re-analyzes nothing.

Findings are compile errors. They fail the build, and no output is
emitted, as with any error. They do not fail the unit that has them,
because the code means what it meant. Dependents are still analyzed, and
every finding of the build is reported in one run, after AstGen's errors
and alongside Sema's. An agent fixes all of them in one cycle.

### Lint facts (the syntax pass's output)

Facts must not depend on the config or on the file's path. ZIR is shared
by content across every project and worktree on the machine, and the
same bytes can live under two names. So the pass records:

- The candidate findings of every syntax rule, with all rules on. Each
  carries its span and its message arguments.
- For Z024, every line longer than 80 bytes with its length. A config
  with `max_length` below 80 makes the report step scan the file's
  source, which is rare.
- The path-dependent rules' inputs:
  - for Z009, whether the file has top-level fields;
  - for Z021, the top-level `@This()` aliases;
  - for Z012 and Z015, the type names a `pub fn` signature names, which
    are compared with the file stem.
- The ignore table: for each line that an ignore comment covers, the set
  of rule IDs it names. The table is built from the raw source with
  ziglint's exact rule: the line itself, plus the run of `//` lines
  directly above it, stopping at the first other line. It is empty for a
  file without the text `ziglint-ignore`, which one `memmem` decides.
- The per-file inputs of the Sema rules that read syntax. These are the
  syntactic verdicts of the hybrid rules (below), and the root-level path
  aliases Z035 matches against. One rule reads doc comments: a
  declaration's `Deprecated` message for Z011.

Facts go in `<global cache>/bs/zir/<hash>.lint`, beside the ZIR file
with the same content hash. They follow the same mtime renewal and the
same trimming and superseding rules. A lint version salts the name, so a
new rule invalidates facts and not ZIR.

When the pass runs:

- It is written on demand. A covered file that is lowered in this build
  gets its facts from the same AST.
- A covered file whose ZIR came from the cache but which has no facts yet
  is parsed once to make them. This happens once per content. Afterwards
  every project shares the file.
- std and dependencies never get facts. There is one exception, the
  deprecation table, below.

A build without a config never runs the pass and never opens a `.lint`
file.

### The deprecation table (Z011's view of std)

ZIR has no doc comments, so Z011 cannot be answered from ZIR. A file's
deprecation table maps each declaration (its ZIR declaration
instruction, which is stable for given content) to the text of its doc
comment when that comment marks it deprecated. "Deprecated" uses
ziglint's `containsDeprecated` rule: a line starting `deprecated`,
case-insensitive, followed by end of line, `:`, `;`, `,`, `.` or a
space; or a line starting `this function is deprecated`.

The table is a lint fact like the others, kept in the same `.lint` file.
It is built for any file whose declaration a covered unit calls,
including std's files. Building it parses that file once per content,
the first time a covered build calls into it. Every project shares the
result. Std is not being linted here; Sema is reading a fact about the
callee.

## 1. Where each rule runs

"S" is the syntax pass, "Sema" is Sema, and "H" (hybrid) means the
syntax pass records a verdict and Sema replaces it for code it analyzes.
"Difference" says whether bs's answer can differ from ziglint 0.8.1's,
and which way.

A difference common to every Sema and H rule: Sema analyzes only
referenced code. A function nothing references gets no type-based
findings. ziglint lints every declaration in a file, so on unreferenced
code bs reports fewer findings. Code in an untaken comptime branch (`if
(builtin.os.tag == .windows)` on Linux) is the same. The syntax rules see
everything. Open question 1 asks whether to analyze unreferenced code in
covered files.

| Rule | What it checks | Where | Difference from ziglint |
|---|---|---|---|
| Z001 | fn names camelCase | S | none (same code) |
| Z002 | initialized `_x` named discard | S | none |
| Z003 | parse error | (already an error) | bs reports a parse error as it does today, with no separate Z003 finding. Parse errors stop the file in both |
| Z004 | `const x = T{...}` → annotation plus anonymous init | S | none |
| Z005 | type-function names PascalCase | S | none |
| Z006 | var names snake_case unless type or fn alias | H | ziglint exempts a name when `typeOf` says "type", else when the syntax looks like a type (PascalCase callee, ...). Sema knows whether an analyzed declaration's value is a type. bs reports more where the syntax guesses "type" wrongly (`const MyThing = makeValue();`, a PascalCase function that returns a value), and fewer where it misses a type (`const handle_t = c.SomeAlias;` through a module ziglint cannot resolve). Unanalyzed declarations keep the syntactic verdict |
| Z007 | duplicate `@import` literal | S | none |
| Z009 | file with top-level fields named PascalCase | S plus report (file name) | none |
| Z010 | explicit `T{...}` or `T.x` where the type is known | Sema (call arguments, return), S for the rest | ziglint flags any returned `T{...}` or `PascalCase.x` without reading the return type, exempting only error sets, and compares argument types as source text. Sema compares the result type with `T`. bs reports fewer: a returned `T{...}` whose function returns something else (an `anytype` or a union coerced from it) is not redundant. bs reports more: equal types spelled differently (an alias), and method calls through locals, parameters and pointers, which ziglint cannot resolve. Sema also fixes ziglint's argument offset for `Type.staticFn(x)`, which skips the first parameter as if it were a receiver |
| Z011 | call to a deprecated declaration | Sema | ziglint resolves the callee for root declarations, std paths and simple aliases. Sema resolves every call it analyzes. bs reports more: calls through locals, parameters, pointers, generic instances, `@This()` receivers, build-system modules, and tagged unions and `enum(u8)` (whose methods ziglint's `findMethodInType` misses). bs reports fewer in unanalyzed code. The message (the doc comment) is the same text |
| Z012 | `pub fn` exposes a private type | H | ziglint's "type" is a PascalCase identifier, its "private" is not a root or enclosing `pub` declaration, and it skips generic arguments. Sema knows the named type's declaration and its visibility. bs reports more: a private type inside a generic argument (`List(Private)`) or behind an alias. bs reports fewer: a PascalCase identifier that is a value or a public import. Unanalyzed signatures keep the syntactic verdict |
| Z013 | unused import | S | none (same name-set test, no scoping) |
| Z014 | error set names PascalCase | S | none |
| Z015 | `pub fn` exposes a private error set | H | as Z012 |
| Z016 | `assert(a and b)` | S | none. Sema could recognize `std.debug.assert` through any alias, but the rule does not use the resolver today, so it stays syntactic for parity |
| Z017 | `return try` | S | none |
| Z018 | redundant `@as(T, x)` in a var decl or return | S | none. It compares identifier text. Moving it to Sema would find more (aliases, non-identifier types) and is listed under later work |
| Z019 | `const X = @This()` in a named struct | S | none |
| Z020 | inline `@This()` | S | none |
| Z021 | file-struct `@This()` alias named after the file or `Self` | S plus report (file name) | none |
| Z022 | `@This()` alias in an anonymous struct is `Self` | S | none |
| Z023 | parameter order: type, comptime, Allocator, Io | H | ziglint classifies by `typeOf`, falling back to the spellings `Allocator`, `mem.Allocator`, `std.mem.Allocator`, `Io`, `std.Io`. Sema compares the parameter's type with `std.mem.Allocator` and `std.Io`. bs reports more: an aliased allocator type (`const Gpa = std.mem.Allocator`). bs reports fewer: a local type that happens to be named `Allocator` or `Io`. Receiver detection becomes exact |
| Z024 | line longer than `max_length` | S plus report (limit) | none |
| Z025 | `catch \|e\| return e` | S | none |
| Z026 | empty `catch {}` outside `defer` | S | none |
| Z027 | declaration accessed through an instance | Sema | ziglint needs `typeOf(lhs)` to be a user type, which fails for locals, parameters and pointers. Sema sees every field access on a value whose name resolves to a declaration and not a field (`fieldVal`, `zirFieldCall`). bs reports more: locals, parameters, pointers, std types. bs reports fewer in unanalyzed code |
| Z028 | inline `@import` | S | none |
| Z029 | redundant `@as(T, x)` in a call argument, array or struct init | Sema (call arguments), S for array and struct init | as Z010's argument form: real types instead of identifier text, the callee resolved through any receiver. ziglint looks struct fields up only in the file's root containers. The init forms stay syntactic for parity, and moving them to Sema is later work |
| Z030 | `deinit` sets `self.* = undefined` | S | none |
| Z031 | identifier with an underscore prefix | S | none |
| Z032 | acronym casing | H (type-alias verdict) | as Z006's type-alias verdict. Function names are syntax only |
| Z033 | redundant words in type names (off by default) | H (type-alias verdict) | as Z006 |
| Z034 | `print("literal", .{})` on `std.Io.Writer` | Sema | ziglint needs an explicitly typed receiver, as its docs say: `const w = foo.init();` is skipped. Sema sees the receiver's type at the call. bs reports more: inferred, returned and field receivers, `*std.Io.Writer` through any alias. bs reports fewer in unanalyzed code |
| Z035 | qualified path where a root alias exists | S | none. ziglint compares path text and does not resolve shadowing, and bs keeps that. Sema could drop the false positive on a shadowed root, which is later work |

Totals:
- 22 rules run in the syntax pass only.
- Five are Sema: Z010 and Z029 for call arguments, Z011, Z027, Z034.
- Six are hybrid: Z006, Z012, Z015, Z023, Z032, Z033.
- Z003 is the existing parse error.

### How the Sema rules hook in

All of these hooks run only in a unit whose file is covered (a bit set
when the unit starts). Every other unit pays one predictable branch.

- **Calls** (`analyzeCall`, reached from `zirCall` and `zirFieldCall`):
  - Z011 looks the callee declaration up in its file's deprecation table.
    It also looks up the namespaces on the path to it, which gives
    ziglint's `std.fs.path` form.
  - Z010 and Z029 compare an explicit `T{...}` or `@as(T, x)` argument
    with the parameter's type, after the receiver.
  - Z034 checks the receiver's type and the format string.
- **Field access on a value** (`fieldVal`, and `zirFieldCall`'s
  declaration lookup): Z027.
- **Returns** (the `ret` paths): Z010's return form, against the
  function's return type.
- **Declaration values**: Z006, Z032 and Z033's type-alias verdict, from
  whether the value is a type. **Function signatures**: Z012 and Z015's
  private-type verdict, and Z023's parameter classification.

Each hook writes a finding into the unit's list (span, rule, message
arguments).

**Generic functions.** A generic function's instances report once per
source location, as the diagnostics design specifies for errors (`in <n>
instances`, not built yet).

**Inlined code.** A finding belongs to the file its span is in, so an
inline call into std from a covered file checks the call site, not std's
body.

**Comptime and inline code.** Sema reports what it analyzes, including
comptime calls.

**Hybrid rules.** The syntax pass records the candidate and its
syntactic verdict. For a declaration Sema analyzed, Sema's verdict
replaces it. Otherwise the syntactic verdict stands. That verdict is
ziglint's simple-mode answer, so bs never reports a hybrid finding on
code it did not analyze that ziglint's syntax would not also report.

### Edits that change a Sema rule's answer without changing the unit

A covered unit records a new dependee kind, `deprecation`, for each
declaration it calls. Its result hash is the hash of that declaration's
deprecation text, or zero for none. Adding `/// Deprecated: ...` above a
declaration then re-analyzes exactly its callers in covered files.

The existing `nav_ty` edge is not enough. AstGen's `src_hash` hashes
`tree.getNodeSource(decl_node)` (AstGen.zig L4120). That span starts at
`Ast.firstToken`, which steps back over `pub`, `extern`, `export` and
`inline` but not over doc comments. So editing a doc comment changes no
`src_hash`.

The other Sema rules read only types, which the unit already depends on.

## 2. Finding the config

**Discovery.** bs looks for `.ziglint.zon` starting in the root
module's root source file's directory and walking up, stopping at the
nearest directory that holds a `build.zig` (that directory is searched
too). A file outside any project (no `build.zig` above it) searches only
its own directory.

- With `build-exe`, `build-obj`, `build-lib`, `test` and `run` this
  happens once per compilation.
- Under `bs build`, each compile step does the same from its root
  module's file. The root package's steps find the build root's config.
- A step whose root file is in a dependency (in the global package cache
  `<global cache>/p/`, or in the project's `zig-pkg/` directory where
  0.17 fetches packages) finds none, because discovery never reads a
  config inside those directories.

This differs from ziglint, which walks up without limit from its first
argument, or reads only `./.ziglint.zon` when it has no arguments. The
`build.zig` boundary keeps a stray `~/.ziglint.zon` from covering every
project under `~`. Open question 3.

**Coverage.** A file is covered when all of the following hold:

1. it is under the config's directory;
2. it is in the file set ziglint computes from `paths`, using ziglint's
   own walk rules (dot components, `zig-cache`, `zig-out`, the root
   `.gitignore` with ziglint's matching);
3. it is not under the zig lib directory, the global package cache, or a
   `zig-pkg/` directory;
4. the build reaches it.

`paths` are taken relative to the config file's directory. ziglint takes
them relative to the working directory, which is the same thing for a
config at the root, where every config in the org sits. Open question 2.

**Dependencies.** No config applies to a dependency's files, neither the
root package's nor the dependency's own.

**Reached files only.** bs lints the files the build reaches. A covered
file that no compilation reaches (a stray script, a tool with its own
`main` that nothing builds) is never checked. ziglint checks it. Under
`bs build`, the union of all steps is what counts. Open question 4 asks
whether bs needs a way to check unreached covered files.

**A config bs cannot read is a compile error.** That covers a parse
error, an unknown field, or a rule ID bs does not know. The error points
into the `.ziglint.zon` as ZON errors already do. ziglint warns and falls
back to defaults, but with no escape hatch a silently ignored config
would be one. Under `bs build`, every step of the root package reports
the same error.

**The config in the cache.** The config is not part of the compilation
key, so editing it never makes a cold build.

- It is a manifest input like a source file, with a content hash. The
  manifest also records the parsed config's coverage: the set of covered
  files the build reached.
- The directories discovery searched are recorded as absent inputs, so
  creating a `.ziglint.zon` is seen. The no-edit check stats them, which
  is a few stats.
- When the config's hash changes, the edit build compares the new
  coverage with the recorded one:
  - **Rule switches and `max_length`:** nothing is re-analyzed. The
    report step filters the recorded findings again.
  - **A file that leaves coverage:** its findings are dropped. Nothing is
    re-analyzed.
  - **A file that joins coverage:** its syntax facts come from its
    `.lint` file, or one parse. Its units are seeded red, as for an edit
    to that file, so Sema runs their hooks.
  - **Adding a config:** every reached file joins coverage. **Removing
    it:** every file leaves.
- A unit's findings live in its manifest node, with locations relative to
  the declaration (the Diagnostics section anticipated this for bs-only
  checks). They do not live in the shared store entry, whose key has no
  coverage in it. A node recorded while its file was uncovered is red in
  a build where it is covered.
- Findings do not enter the result hash, so they never wake dependents.
- A build with findings fails. It commits its manifest as a failing build
  does (Diagnostics, "Errors and the cache"). Its units are green, so the
  next build replays their findings and re-analyzes nothing that did not
  change. It never relinks the last good output while findings remain.
- `BS_CACHE_CHECK` compares replayed findings with a fresh build's,
  byte for byte, as it does for errors.

## 3. What a finding looks like

A finding is a `diag.Diagnostic` and renders like every other error. The
message is ziglint's text unchanged, from its `writeMessage` table. bs
adds the rule ID, the exact location, the facts, and a fix where it can
make one. Illustrative (the bs locations are invented; the std one is
real):

```
src/fmt.zig:212:13: error[style, Z026]: empty catch block suppresses errors: `catch {}`
  | w.flush() catch {};
  hint: handle the error, or say why it is ignored: `// ziglint-ignore: Z026 -- <reason>`
src/Sema.zig:4410:28: error[deprecated, Z011]: 'indexOfScalar' is deprecated: Deprecated in favor of `findScalar`.
  | const i = std.mem.indexOfScalar(u8, s, '/') orelse return;
  note std/mem.zig:1284:11: declared here: pub const indexOfScalar = findScalar;
  fix? src/Sema.zig:4410:28-4410:41: "findScalar"
src/link/Elf.zig:88:5: error[style, Z017]: avoid try in return; hoist it to preserve payload coercion: `const value = try self.alloc(n); return value;`
  | return try self.alloc(n);
  fix? src/link/Elf.zig:88:5-88:30: "const value = try self.alloc(n);\n    return value"
```

- **The code.** The bracket holds a kebab-case code, a comma, and the
  rule ID, as the bs-only checks proposal did (`error[leak-on-error,
  bs-only]`). Z011 is `deprecated`. Every other rule is `style`. An agent
  grepping `Z026` finds the rule, and the ignore comment needs the ID.
  JSON lines gain `"rule": "Z026"`, with `"code": "style"`. Over
  `--listen=-` the prefix is `[style Z026]`. Open question 5 asks about
  the code names.
- **The location** is the span ziglint reports at, with its column. ziglint
  prints no column.
- **The facts:**
  - Z011 adds the deprecated declaration's location and line as a note.
  - Z010 and Z029 add the parameter or result type that makes the type
    known.
  - Z012 and Z015 add the private type's declaration.
  - Z027 adds the declaration's container.
  - Z007 adds the first import's location.
  - Z035 adds the alias declaration's location.
- **The hint** says how to ignore the finding, once per rule per build,
  because an agent needs to know the escape that does exist. The other
  rules' hints are the rewrite their message already names.
- **Fixes**, where ziglint's message names a rewrite, using
  `exact` when the rewrite cannot change meaning and `maybe` otherwise:

  | Rule | Fix | Applicability |
  |---|---|---|
  | Z011 | rename to the replacement when the doc comment names one identifier (`in favor of \`X\``, `use \`X\``) | maybe |
  | Z013 | delete the import line | exact |
  | Z016 | `assert(a); assert(b);` | exact |
  | Z017 | hoist to `const value = try ...; return value;` | maybe (the name `value` may be taken) |
  | Z025 | `x catch \|e\| return e` → `try x` | exact |
  | Z034 | `print("lit", .{})` → `writeAll("lit")` | exact |
  | Z035 | replace the path with the alias | exact |
  | Z010, Z029 | drop the type: `.{...}` or `.x`, or unwrap `@as` | exact (Sema confirmed the type) |
  | Z018 | unwrap `@as` | exact |
  | Z019, Z020, Z021, Z022 | rename the alias, and its uses in the file | maybe |
  | Z030 | insert `<p>.* = undefined;` at the end of `deinit` | maybe |
  | Z004 | move the type into the annotation | exact |

  The naming rules (Z001, Z005, Z006, Z014, Z031, Z032) have no fix:
  renaming a declaration can break other files. Z032's message already
  carries the suggested name.
- `tools/diag/roundtrip.py` covers the exact fixes, as it does AstGen's.

## 4. The conformance measure

ziglint 0.8.1 is the oracle for these rules, as upstream zig is for the
language. Three measures, kept visible like the behavior share:

**The suite.** ziglint's tests, ported to `test/lint/`, one case per
test. Each case is a source file with a `.ziglint.zon` and bs's expected
stderr, run by `zig build test` the way `test/diag` runs.

- **Ported as cases:**
  - Linter.zig's 305 tests, minus the few that test helpers, not rules;
  - the 146 doc-comment examples in `docs/rules`;
  - rules.zig's 11 message tests;
  - Config.zig's 6 config tests.
- **Not ported:**
  - TypeResolver.zig's 34 and ModuleGraph.zig's 4, which test machinery
    bs replaces with Sema and its frontend;
  - main.zig's 5, which test ziglint's CLI.

  The suite reports, for each of the 372, whether it was ported, adapted,
  or replaced, and why.
- **Cases that need adapting:**
  - ziglint lints text that need not compile, while bs's Sema rules see
    only code that compiles and is referenced. Such a case gets
    the smallest change that makes it compile, plus a reference (`test {
    _ = &f; }`).
  - The Z011 tests build a fake std in a temporary directory. bs cannot
    compile against a fake std, so those cases deprecate a declaration
    in a user module, or call a real 0.17 deprecation.
  - The adapted cases are listed in the suite's README with ziglint's
    original test name.

**Identical findings on real trees.** `tools/lint/parity.py` runs
ziglint 0.8.1 and bs on a tree, matches findings by rule, file and line,
and classifies every difference:

- `sema-type`: Sema's real types. bs is more precise, by the per-rule
  reasons above. Logged as improvements.
- `unanalyzed`: code bs did not analyze.
- `unreached`: files no compilation reaches.
- `ziglint-walk`: ziglint's walk does not descend there, as for a switch
  prong or a return expression; its own comments name the gaps.
- `bug`: anything else, to be fixed.

The bar is zero `bug`, with every other class counted in the results
file and the improvements spot-checked by hand. The trees:

- **bs's own tree.** On main it has 0 findings (ziglint 0.8.1, 6.5 s,
  with 93 ignore comments), which tests the ignores and little else. So
  the tree as it was before the cleanup, main 84c75e56, also runs: 1269
  findings from 0.8.1 with that tree's own `.ziglint.zon` (measured
  2026-11-07).
- **The corpus.** None of the corpus's 115 projects (tools/corpus) has a
  `.ziglint.zon` at its pinned commit (checked 2026-11-07 for each
  project's commit). 23 baskingspot repositories have one: protobuf, tls,
  quic, http, websocket, image, prometheus, utf, compress, encoding, text,
  aho-corasick, bencode, json5, toml, cli, testingx, stdx, fastmem,
  docgen, html, zigdoc-poc, incubate-probe. The proposal is to add those
  that build with 0.17.1 to the corpus, pinned like the others, as the
  parity set. Open question 6.
- **Wider precision, not a gate.** A synthesized default config
  (`paths = .{"src"}`, every rule on) over every corpus project. It
  reports `bug` differences across far more code than the org writes.

## 5. What it may cost

**Budget.**
- **Cold builds with a config:** at most +1% wall.
- **Edit builds with a config:** no measurable change.
- **Builds without a config:** no change at all, by construction. The
  syntax pass, the `.lint` files and the Sema hooks never run, and the
  only new work is the discovery stats.

**Where the time goes.**
- **The syntax pass.** One walk over a covered file's AST in the
  lowering worker that already holds it, plus the `memmem` for ignore
  comments. ziglint takes 6.5 s on bs's tree, but that time is its
  resolver, not the rules: it makes 444k `realpath` calls (open,
  readlink, close) and re-reads std's ASTs. bs's pass reuses a parse the
  build already does. A single walk with ziglint's per-node checks should
  cost tens of ns per node, so tens of ms over bs's tree, spread over the
  lowering threads. It only runs on a file's first lowering.
- **The deprecation tables.** One parse of each std file a covered build
  calls into, once per machine.
- **The Sema hooks.** A branch on the covered bit everywhere, and a table
  lookup or a type comparison at calls, field accesses and returns in
  covered units.
- **Report time.** Filtering findings and the ignore tables, which is
  proportional to the findings.

**How it is measured.**
- `BS_TIMING=1` gains a `lint` line: syntax-pass time, deprecation-table
  time, hook time (sampled per covered unit), and report time.
- `bench/bench.py` runs A/B on the same binary, with the config present
  and with it renamed away:
  - bs's own tree under `bs build` (cold and edit);
  - the baskingspot parity set (cold and edit);
  - the existing hello, vaxis and zig workloads, which have no config
    and must show no change.
  - Median of 10, and the spread is reported.
- Callgrind instruction counts on the same builds give an exact A/B for
  the no-config case. It must be identical except for the discovery stats.
- `tools/corpus/run.py --samples 3` on the parity set, for the edit
  builds the corpus already defines.
- A unit test checks that a build without a config opens no `.lint` file
  and runs no hook. A counter in `BS_TIMING` must read zero.

If the cold budget is missed, the first lever is to make the
deprecation tables part of std's ZIR summary, computed when std is first
lowered. That makes them free in a project's first build, but costs
every first lowering, with or without a config.

## 6. AGENTS.md

Today's Scope bullet:

> bs may reject more than upstream: extra compile errors that catch real
> mistakes are allowed. Everything else upstream accepts must still mean
> the same, and upstream's std and `test/behavior` must still compile,
> since they are the conformance measure.

Proposed:

> bs may reject more than upstream in two ways. Extra compile errors that
> catch real mistakes are allowed. And a project opts in to ziglint's
> style rules with a `.ziglint.zon`: bs then enforces those rules as
> compile errors on the files the config's `paths` cover, never on std or
> on dependencies. `// ziglint-ignore:` comments, part of the config
> language, are the only exception, and no flag or environment variable
> reports a finding without failing. ziglint 0.8.1 is the oracle for
> those rules, as upstream zig is for the language. Without a
> `.ziglint.zon`, everything upstream accepts must still compile and mean
> the same, and upstream's std and `test/behavior` must still compile,
> since they are the conformance measure.

A new bullet under Development:

> The ziglint rules have their own conformance measure: the ported
> ziglint suite in `test/lint/` and `tools/lint/parity.py` against
> ziglint 0.8.1 on bs's tree and the corpus's configured projects. Keep
> both visible. A ziglint release with new rules is ported deliberately,
> with its tests, by bumping the oracle version.

Two passages of `docs/slop/architecture.md` change with it:

- Diagnostics decision 5 ("No bs-only checks") becomes "no bs-only
  checks other than the opt-in ziglint rules".
- The not-adopted framework's "There are no suppression comments" gains
  the exception for `// ziglint-ignore:`.

## 7. bs's CI ziglint job, and ziglint the tool

**While bs is building toward parity.**
- The `ziglint` CI job stays as it is. It is blocking once
  `ci-block-ziglint` lands, running ziglint 0.8.1 from mattware.
- A non-blocking `lint-parity` job runs `tools/lint/parity.py` on bs's
  tree and on 84c75e56, and reports the counts.

**At parity.** Parity means:
- the suite passes;
- `parity.py` shows zero `bug` differences on bs's tree, on 84c75e56 and
  on the baskingspot set;
- the cost budget holds.

bs's own CI can then enforce the rules with bs. The test job builds bs
with upstream zig, so the check needs a bs compile of bs's own programs:
a `just lint-bs` recipe that runs `bs build` for every program the
config's `paths` cover, with `-fno-emit-bin` where the build allows it.
Two things make the ziglint job redundant:
- that recipe blocks for a release cycle;
- `parity.py` stays at zero `bug` on main for that cycle.

The owner then decides whether to drop the ziglint job.

**ziglint the tool** stays standalone. It is the owner's, it serves
projects that do not build with bs, and it supports Zig 0.16, which bs
never will. bs tracks it:
- each ziglint release is a new oracle version;
- bs ports its new rules and tests, and the suite's version line moves
  with it.

Whether ziglint keeps growing rules independently, or freezes and points
at bs, is the owner's call after parity. This note assumes neither.

## Later work, not in the first version

- Z018 and Z029's init forms in Sema, with real types: more findings, and
  aliases understood.
- Z035 without the false positive on a shadowed path root.
- Z016 recognizing `std.debug.assert` through any alias.

Each of these is a deliberate difference from ziglint and would be
logged in `parity.py` as `sema-type`.

## Open questions for the owner

1. **Unreferenced code and the type rules.** Sema analyzes only what is
   referenced, so Z010, Z011, Z027, Z029 and Z034 miss unreferenced
   functions and untaken comptime branches, which ziglint lints.
   Accepting that keeps the cost at zero. The alternative is to analyze
   unreferenced non-generic functions in covered files in a lint-only
   mode: their semantic errors discarded, no code generated. That is the
   `-fanalyze-unreferenced` idea from the Diagnostics section, which was
   not adopted. On libvaxis it found 4 real latent bugs among 27 errors.
   It would cost a share of a full analysis of the covered files.
   Recommendation: accept the gap for the first version, and measure the
   lint-only mode's cost on bs's tree.
2. **`paths` relative to the config's directory** rather than the working
   directory (ziglint's behavior). It is the same for every config in the
   org today.
3. **The discovery boundary** at the nearest `build.zig`. ziglint has none.
4. **Unreached covered files.** bs lints compilations, not files. Is a
   covered file that no step builds acceptable to leave unchecked? Or
   should bs gain a `bs lint` command that runs the syntax rules on every
   covered file? Such a command only adds checks, so it is not an escape
   hatch.
5. **Codes:** `error[deprecated, Z011]` and `error[style, ZNNN]`, a
   kebab-case code plus the rule ID. Or the bare rule ID
   (`error[Z026]`), or one code per rule (`error[empty-catch, Z026]`).
6. **The parity corpus:** add the baskingspot repositories that have a
   `.ziglint.zon` and build with 0.17.1 to `tools/corpus/manifest.json`.
7. **Configs bs cannot read** fail the build instead of falling back to
   defaults as ziglint does. Should a config with a rule ID from a newer
   ziglint fail too (proposed), or be accepted with that rule
   unenforced?
