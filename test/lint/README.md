# The ziglint rules' conformance suite

ziglint 0.8.1 (rockorager/ziglint f6a3fc2) is the oracle for the rules
bs enforces with a project's `.ziglint.zon` (docs/slop/ziglint-in-bs.md).
Its 372 tests, and the 146 examples in its rules' docs, are ported here
and in `src/lint/` as follows. `zig build test` runs all of them.

| ziglint | Tests | In bs |
|---|---:|---|
| `src/Linter.zig` | 305 | 276 ported unchanged as unit tests at the end of `src/lint/Linter.zig`, through `TestLinter`, which gives them ziglint's API over the syntax pass. 28 test ziglint's semantic mode: the 12 of Z011 are adapted as the case `deprecated/` (below), but for one that does nothing on Zig 0.16 and later, and 16 wait for the rest of the Sema rules. 1 tests a helper bs does not have (`getContainerMembers: members outlive the call`). |
| `src/rules.zig` | 11 | Ported unchanged, in `src/lint/rules.zig`. |
| `src/doc_tests.zig` | 2 | `doc tests` is ported in `src/lint/Linter.zig`: 144 of the 146 `zig` blocks of `docs/rules/*.md` (copied to `src/lint/docs/` with ziglint's license) run; the Z011 example is in the case `deprecated/`, and the Z027 one waits for that rule. The `compile-test` probes, which check that a documented replacement compiles, and `parse compile test probe` are not ported. |
| `src/Config.zig` | 6 | Replaced by the cases here: the defaults (`rules.zig`), `max_length` and rule switches (`switches/`, `short_lines/`), `paths` (`paths/`). `runtime rule check` and `set rule enabled` test ziglint's `Config` API, which bs does not have. A config error is `bad_config/`. |
| `src/TypeResolver.zig` | 34 | Not ported: bs answers type questions with Sema. |
| `src/ModuleGraph.zig` | 4 | Not ported: bs's frontend loads the modules. |
| `src/main.zig` | 5 | Not ported: they test ziglint's command line. |

## The cases

Each `*.zig` file here is a case under `test/lint/.ziglint.zon`, and each
directory one under its own config, with `main.zig` as its root. The root
file ends with a `// error` block of bs's exact standard error, which
`zig build test` checks with `bs build-obj -fno-emit-bin`;
`zig build test-upstream` checks that upstream zig accepts the case.
Cases that need a whole program cover what unit tests cannot: discovery
and coverage, the config's switches, the rules that read the file's name,
ignore comments, the report's output, and the cache (`lint config added
and removed`, in build.zig).

## The Sema rules

Sema answers Z011 (deprecated calls) in the code it analyzes. ziglint's
Z011 tests build a fake std in a temporary directory, which bs cannot
compile against, so `deprecated/` adapts them: a deprecated declaration
in a module of the project, or a real 0.17.1 deprecation in std. The case
covers these tests, and the Z011 doc example (`src/lint/docs/Z011.md`):

| ziglint test | In `deprecated/` |
|---|---|
| `Z011: detect deprecated method call` | `instance.oldMethod()`, as the doc example |
| `Z011: no warning for non-deprecated method` | `instance.goodMethod()` |
| `Z011: detect deprecated direct function call` | `oldFunc()` |
| `Z011: detect deprecated function alias` | `aliasFunc()` |
| `Z011: detect deprecated type function` | `OldList(u8)` |
| `Z011: detect deprecated type function alias` | `DeprecatedAlias(u8)` |
| `Z011: detect deprecated stdlib function (ArrayListUnmanaged)` | unchanged, with the real std |
| `Z011: detect deprecated stdlib namespace` | `std.fs.path.basename`, deprecated in 0.17.1 |
| `Z011: detect deprecated stdlib function alias` | `const find = std.mem.indexOfScalar;` for the fake `copyForwards` |
| `Z011: detect deprecated method on a stdlib type declared in an imported module` | `lib.Color.get()`, the fake std's `zig.zig` as `lib.zig` |
| `Z011: detect deprecated type function in type positions` | `OldList(u8)` in a field, parameter, return and array type; `std.meta.fieldInfo` for the fake `std.meta.Int` |
| `Z011: deprecated stdlib corpus - real Zig 0.15.2 deprecations` | Not ported: it returns early on Zig 0.16 and later. |

The case also shows the two ways bs's answer differs from ziglint's
(docs/slop/ziglint-in-bs.md, section 1): a call through a parameter
(`throughPointer`), which ziglint's resolver cannot follow, is reported,
and a call in a function nothing references (`unreferenced`) is not.

## Waiting for the Sema rules

These ziglint tests build a module graph and need its `TypeResolver`.
They become cases with the rest of the Sema rules (Z027, and the
type-aware parts of Z006, Z010, Z012, Z023 and Z029):

- `Z012: member-of-module type alias is imported, not private`
- `Z012: bare module-name import falls back to syntax`
- `Z006: resolver sees camelCase type-fn call as type alias`
- `Z010: allow merged error set members in return`
- `Z023: argument order - aliased Allocator`
- `Z023: argument order - aliased Io`
- `Z023: receiver param with struct name is ok (semantic)`
- `Z023: file-as-struct receiver is ok (semantic)`
- `Z027: flag instance accessing const`
- `Z027: flag instance accessing static fn`
- `Z027: allow instance method call`
- `Z027: allow field access`
- `Z027: allow type-level access`
- `Z027: allow method with Self receiver`
- `Z027: allow method with named type receiver`
- `Z029: detect redundant @as in method call arg`
