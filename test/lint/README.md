# The ziglint rules' conformance suite

ziglint 0.8.1 (rockorager/ziglint f6a3fc2) is the oracle for the rules
bs enforces with a project's `.ziglint.zon` (docs/slop/ziglint-in-bs.md).
Its 372 tests, and the 146 examples in its rules' docs, are ported here
and in `src/lint/` as follows. `zig build test` runs all of them.

| ziglint | Tests | In bs |
|---|---:|---|
| `src/Linter.zig` | 305 | 276 ported unchanged as unit tests at the end of `src/lint/Linter.zig`, through `TestLinter`, which gives them ziglint's API over the syntax pass. 28 test ziglint's semantic mode and wait for the Sema rules (below). 1 tests a helper bs does not have (`getContainerMembers: members outlive the call`). |
| `src/rules.zig` | 11 | Ported unchanged, in `src/lint/rules.zig`. |
| `src/doc_tests.zig` | 2 | `doc tests` is ported in `src/lint/Linter.zig`: 144 of the 146 `zig` blocks of `docs/rules/*.md` (copied to `src/lint/docs/` with ziglint's license) run; the Z011 and Z027 examples wait for the Sema rules. The `compile-test` probes, which check that a documented replacement compiles, and `parse compile test probe` are not ported. |
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

## Waiting for the Sema rules

These ziglint tests build a module graph and need its `TypeResolver`.
They become cases with the Sema rules (Z011, Z027, and the type-aware
parts of Z006, Z010, Z012, Z023 and Z029):

- `Z012: member-of-module type alias is imported, not private`
- `Z012: bare module-name import falls back to syntax`
- `Z006: resolver sees camelCase type-fn call as type alias`
- `Z010: allow merged error set members in return`
- `Z011: detect deprecated method call`
- `Z011: no warning for non-deprecated method`
- `Z011: detect deprecated direct function call`
- `Z011: detect deprecated function alias`
- `Z011: detect deprecated type function`
- `Z011: detect deprecated type function alias`
- `Z011: detect deprecated stdlib function (ArrayListUnmanaged)`
- `Z011: detect deprecated stdlib namespace`
- `Z011: detect deprecated stdlib function alias`
- `Z011: detect deprecated method on a stdlib type declared in an imported module`
- `Z011: detect deprecated type function in type positions`
- `Z011: deprecated stdlib corpus - real Zig 0.15.2 deprecations`
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
