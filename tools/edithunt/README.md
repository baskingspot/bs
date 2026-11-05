# edithunt: edit-sequence hunter for the cache

`tools/edithunt` edits a real project the way an editing session does,
20 to 50 edits in a row, and builds after each one with the same cache.
The single-edit checks (`--edit-verify`, the corpus's edit and restore
builds) start every edit from a full build's records. Here each edit
build starts from the records of the edit builds before it, lazy logs
included, so a stale dependency or result that an earlier step left
behind shows in a later one.

```sh
zig build -Doptimize=ReleaseSafe
python3 tools/edithunt/hunt.py libvaxis/test                  # hunt until ^C
python3 tools/edithunt/hunt.py zig --sequences 3              # the zig compiler workload
python3 tools/edithunt/hunt.py zls/test --target aarch64-linux
python3 tools/edithunt/hunt.py --replay tools/edithunt/.work/found/<dir>
python3 tools/edithunt/hunt.py --reduce tools/edithunt/.work/found/<dir>
```

Projects: `zig` (upstream's `src/` with
`bench/workloads/zig/build_options.zig`), `hello`, or a corpus target
`<project>/<target>` from `tools/corpus/manifest.json`, recorded the
first time by `tools/corpus/run.py`'s setup (clone, fetch, generate).
The sources are copied to `.work/run/<project>/tree`; edits go to the
`.zig` files the module roots reach through `@import`, the project's
own three times in four rather than its packages' (`zig-pkg/`).
`--target aarch64-linux` cross-compiles and runs the binaries under
`qemu-aarch64-static`.

## Edits

`scan.zig` (built with upstream zig into `.work/scan`) reads a file with
`std.zig.Ast` and lists its declarations, containers and fields, function
bodies (and whether each is generic), error sets and the literals in
function bodies; `hunt.py` edits at those offsets. Four times in five an
edit inside a function goes to one whose name the last binary holds
(`nm`), since most of a project's functions are never analyzed by a
given build.

- Semantic: change an integer, a string or a `true`/`false` in a
  function; change an integer outside function bodies (a constant, a
  default, an array length); make a function inline or not; make a
  declaration pub or not; add or remove a struct, union or enum field; add a function
  and a call to it, or remove one; change a parameter's integer type;
  add a `const` flag that selects which of two statements is compiled,
  or flip one (or a project's own `const x = true;`); add or remove an
  error in an error set; edit a generic function's body (a literal or a
  new statement); rename a file-private declaration and its uses
  (`scan rename`, which also renames `.name` member accesses and refuses
  names that are also fields); move a file-private declaration that
  names nothing else of its file but `std` and `builtin` to another file
  of its directory, imported back under its name.
- No-ops for the program: a blank line (which moves every line below,
  so debug info and source locations change), a comment line, a touch.
- Breaks: an unused local constant (an AstGen error), a syntax error, or
  a type mismatch in a function (a Sema error when the function is
  analyzed). A step that breaks the build, a semantic edit's compile
  error included, is reverted by a later step (a `fix`), usually the
  next one; until then edits go to other files.

## Checks

Each step builds three times:

1. The edit build, in the session's cache with `BS_CACHE_CHECK=1`.
2. Without the cache (`BS_CACHE=off`).
3. When the edit build compiled: a full build checked node by node
   against the edit build's records (`BS_CACHE_VERIFY=full`), in a copy
   of the local cache, so that the session goes on from the edit build's
   records. With `--verify-every N`, every Nth edit build runs under
   `BS_CACHE_VERIFY=1` instead, whose full build replaces the session's
   records: chains then restart there.

Findings, by class (`.work/found/<class>-<project>-<seed>-<time>/`):

- `edit-build-failed`, `off-build-failed`: a crash, a panic, a cache
  check or verify error, or a failure without a compile error.
- `verify-full`: the full build's nodes differ from the edit build's.
- `outcome`: one of the edit build and the build without the cache
  compiled, the other did not.
- `errors`: both failed, with different compile errors.
- `bytes`: the edit build's binary differs from the full build's. A lazy
  edit build lays out the base's atoms first and the log's after them
  (docs/slop/architecture.md, determinism rule 2), so when the records
  end in a log only the layout may differ: then the symbols and their
  sizes must be the same, and the two binaries must behave the same.
- `behavior`: the binaries run differently (tests: exit status and
  summary line; executables: exit status and stdout).

The full build and the build without the cache may differ in bytes but
not in behavior: the cache keeps the last build's error codes, a build
without it numbers them as it meets them. Such steps are counted as
`bytes_off_only`.

A finding saves `sequence.json` (every step's edit as byte-range
replacements, applied in order to a fresh copy) and `steps.txt`.
`--replay` builds it again from fresh caches. `--reduce` keeps the
fewest intermediate builds that still give the finding at the last step
(ddmin; a step not built folds its edit into the next build) and writes
`reduced.json` and `reduced.diff`, the source changes each kept build
saw.

## Counts

The hunter ends with a line of counts: steps, sequences, findings,
`program_changed` (steps whose full build differs from the step
before's), `compile_error_steps`, `bytes_off_only`, and each edit kind.
