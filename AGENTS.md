# bs

bs is an independent Zig compiler aimed at Go-class compile speed. It does
not track upstream: it compiles two pinned Zig releases, the current one
and the one before it (today 0.17.1 and 0.16.0), each with the std
library shipped with it. When a new release ships, bs adds it and drops
the oldest.

## Scope

- Language version: each compilation is in exactly one of the supported
  languages. `bs build` takes it from the root package's `build.zig.zon`
  `minimum_zig_version` (0.16.x → 0.16, 0.17.x or none → 0.17; anything
  else is an error), and dependencies use the root's language.
  `build-exe`, `test` and `run` take `--zig-version`, else the
  `build.zig.zon` beside the nearest `build.zig` above the root source
  file, else the newest. Each language is complete: its syntax, ZIR,
  semantics, std, compile errors and build system, all through bs's own
  Sema, backends and linkers; C and C++ go through the matching release's
  `zig cc`. 0.16 is being built in phases (`docs/slop/zig-0.16.md`); until
  it compiles, `build.zig.zon` selects a language only with
  `BS_ZON_SELECTS` set, and selecting 0.16 stops with an error.
- Targets: `x86_64-linux` (static ELF first), `aarch64-macos` (Mach-O,
  dynamically linked against libSystem, ad-hoc code signed), and
  `aarch64-linux` (static ELF, reusing the aarch64 backend and the ELF
  linker; started 2026-11-05).
- One optimization level, as in Go: no `-O` modes. Every build has Debug
  semantics (safety checks on, `builtin.mode == .debug`) and always-on
  optimization sized to compile fast (SSA, register allocation, inlining
  within a budget). Output stays debuggable: line tables, frame pointers,
  inlined frames; a request to omit frame pointers (`-fomit-frame-pointer`)
  is accepted and changes nothing. LLVM-class optimization (auto-vectorization, scheduling,
  heavy loop work) stays upstream's job; users run upstream
  `zig` for ReleaseFast and friends. Explicit `@Vector` code is lowered to
  SIMD registers (SSE/NEON), as upstream's Debug backend does, not
  scalarized. Cheap analyses that remove provably redundant work (bounds
  checks proven true, common subexpressions, invariant loads) are allowed
  within the compile-time budget; safety checks are never removed unless
  proven, and never move across source lines. Loop unrolling is allowed
  where its measured run-time gain on real programs justifies its
  compile-time and code-size cost (owner, 2026-11-05); report both.
- bs's x86_64 code uses instructions up to x86-64-v2 (SSE4.2). An explicit
  `-mcpu` past that (AVX models, which per-CPU kernel objects ask for) is
  accepted as upstream resolves it: `builtin.cpu` reports it, so the
  program's comptime choices are upstream's, and bs's SSE code runs on that
  CPU. What AVX would change in meaning is refused: vectors over 16 bytes
  passed by value in the C ABI, and YMM or ZMM operands in inline assembly
  (2026-11-05). The native target's host CPU stays clamped to x86-64-v2.
- One exception: `-OReleaseSafe` (which `zig build` steps such as Ghostty's
  tool executables pass) is accepted and compiled with the same code
  generation, with `builtin.mode == .safe` and upstream's
  ReleaseSafe defaults (safety on, no error return traces), so std and the
  program take the same paths as upstream's ReleaseSafe build. ReleaseFast
  and ReleaseSmall stay refused on the command line; in `bs build` steps
  they get the same treatment (their `builtin.mode`, safety off, same code
  generation) once a real project's build needs it.
- C interop is in scope: `-lc`, `@cImport`, and C and C++ source files.
  translate-c (upstream's Aro-based Zig program in `lib/compiler/translate-c`)
  is built by bs itself, so `@cImport` needs no LLVM. C and C++ source files
  are compiled by the user's upstream `zig cc`/`zig c++` (Clang), and C++
  links against libc++ and libc++abi built from the zig lib directory's
  sources as upstream builds them; bs never compiles C or C++ itself.
  musl (`-target x86_64-linux-musl -lc`, libc built from the zig lib
  directory's sources through upstream Clang) follows when a target needs
  it.
- Out of scope unless the user asks: other targets, ReleaseFast and
  ReleaseSmall, LLVM, the C backend, a C or C++ compiler inside bs.
- CLI: drop-in for `zig build-exe`, `zig build-obj`, `zig run`, `zig test`, and `zig build`
  (bs compiles and runs the build runner and serves its compile steps over the
  `--listen=-` compiler protocol).
- bs's main users are coding agents. Shape compile errors for them, not for
  humans: exact locations, the facts an agent needs to fix the error, and
  fixes where bs knows them, in a form a program can parse.
- bs may reject more than upstream in two ways. Extra compile errors that
  catch real mistakes are allowed. And bs enforces ziglint's rules as
  compile errors on a project's own files, never on std or on
  dependencies. ziglint 0.8.1's defaults apply: every rule but Z033 is
  on. A project configures them, or turns them off, with a `lint` section
  in `.bs.zon` (the schema of `.ziglint.zon`), or with a `.ziglint.zon`
  when it has no `.bs.zon`. `// ziglint-ignore:` comments are the only
  per-line exception, and no flag or environment variable reports a
  finding without failing. ziglint 0.8.1 is the oracle for those rules,
  as upstream zig is for the language. With lint turned off, everything
  a supported release accepts must still compile and mean the same in
  that language, and each release's std and `test/behavior` must
  compile, since they are the conformance measure.

## Architecture decisions

- Frontend: upstream's tokenizer, Parse, AstGen and Zir for each
  supported release, vendored under `frontend/` (the `frontend` module,
  outside `src/` so that ziglint does not hold upstream's code to bs's
  rules) with upstream's notice, ported only as far as compiling under
  bs's own Zig needs, plus one bs-owned superset Ast and superset ZIR that
  both releases' AstGen produce (see `docs/slop/zig-0.16.md`). Do not
  reimplement them. Sema branches on the language only where meaning
  differs.
- Everything after ZIR is bs's own code: semantic analysis and comptime
  (Sema), the typed IR, the backends, and the linkers.
- Speed comes from architecture, not micro-tuning:
  - a per-declaration cache persisted on disk across runs, keyed by ZIR
    content and dependencies;
  - analyzing runtime function bodies in parallel;
  - a comptime evaluator that runs compiled bytecode instead of walking ZIR;
  - fast backends: one shared SSA layer with a short, fixed pass list and
    linear-scan register allocation, lowered per architecture;
  - linkers that write their output once.
- Don't defer performance. When a measurable win is available, take it,
  especially in formats and interfaces (Atoms, cache entries, IR) that get
  harder to change once other code depends on them.
- Compile-time speed is a feature. Track it with benchmarks against upstream
  `zig` Debug builds of the same release (self-hosted x86_64 backend), and do not land
  regressions without saying so. Track the speed of the code bs generates
  against upstream Debug and ReleaseSafe builds the same way, and report
  each backend change's compile-time cost next to its run-time win.

## Upstream reference

- `.agents/setup` installs upstream `zig` 0.17.1 on `PATH` and zig 0.16.0
  at `~/.cache/bs/zig-<host>-0.16.0` in orbs, and symlinks their source
  trees at `upstream/` and `upstream-0.16/` (gitignored), which contain
  `src/Sema.zig`, `test/behavior/` and more. On a Mac satellite it leaves
  the owner's `zig` alone; use `~/.cache/bs/zig-aarch64-macos-0.17.1/zig`
  there.
- Upstream `zig` of the same release is the oracle for each language.
  When semantics are unclear, write a small program and compare bs's
  behavior and output with that release's. Do not guess from memory.
- Conformance measure: per language, the share of that release's
  `test/behavior` (and std, compile errors, cases, langref, c-abi) that bs
  compiles and passes on each target. Keep both languages' numbers
  visible. Measure them with `tools/conformance/run.py` (see
  `docs/slop/architecture.md`).
- Upstream is MIT licensed. Copying upstream code is allowed, but keep the
  upstream copyright notice with the copied code. Never send changes upstream;
  Zig does not accept LLM-authored contributions.

## Development

- bs is written in Zig 0.17.1, independently of the languages it
  compiles; its own Zig moves to the newest supported release when that
  release is added. Build with `zig build`; test with `zig build test`.
- A change to Sema, the frontend or the caches runs the check chain in
  both languages, once 0.16 has numbers, and reports 0.17 compile-time
  numbers.
- `docs/slop/architecture.md` fixes the boundaries between stages (analysis units,
  InternPool stable hashes, typed IR, Atoms, cache model). Follow it, and
  update it in the same change when a boundary moves.
- Time bs built with `-Doptimize=ReleaseFast`; a Debug build of bs is about
  10x slower and says nothing about bs's speed.
- The ziglint rules have their own conformance measure: ziglint 0.8.1's
  test suite, ported in `test/lint/`. Keep it visible. A ziglint release
  with new rules is ported deliberately, with its tests, by bumping the
  oracle version.
- Linux work runs in orbs. Verify aarch64-macos output on a real Mac (a Mac
  satellite for this project), not by inspection alone.
- The justfile is the command interface: `just test`, `just lint`,
  `just ziglint`, `just conformance`, and `just ci`, which runs what CI
  blocks on. Outside an orb, `nix develop` provides the toolchain (the flake
  fetches the same official Zig build as `.agents/setup`; keep the two in
  step). Run `just fmt` before you commit.

## House conventions

bs lives in the baskingspot org and follows its shape, with these
exceptions, which are deliberate:

- It is a program, not a library: the README does not follow the library
  template, and there is no docs site yet.
- The README has no LLM-disclosure footer.
- It does not use the org's `zig` Nix module, because bs pins one exact Zig
  release and nixpkgs may not carry it.
- The org's ast-grep house rules (`baskingspot-lint`) are library-API rules
  and do not run here. ziglint runs with line length (Z024) off, and CI
  blocks on it.

The rest is the org's:

- Commits are signed, and the subject is one line, `area: summary`. A body
  says why when the subject cannot. Do not rewrite pushed history. GitHub
  rejects an unsigned commit on `main`.
- Format and lint every language that ships or that CI depends on: `zig fmt`
  for Zig, ruff for Python, shellcheck for shell. `just lint` runs them.
  `tools/mchunt/` is a test driver and is exempt.
- Pin every GitHub Action by SHA with a version comment. The workflows call
  the shared ones in `baskingspot/gh-actions`.
- Design notes, research, and analysis written by agents go in
  `docs/slop/`. The README is for people and does not link there.
- The repository's GitHub settings come from `baskingspot/.github`. Do not
  change them by hand.
