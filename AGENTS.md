# bs

bs is an independent Zig compiler aimed at Go-class compile speed. It does
not track upstream: it compiles exactly one pinned Zig release (currently
0.17.1) and the std library shipped with it.

## Scope

- Targets: `x86_64-linux` (static ELF first) and `aarch64-macos` (Mach-O,
  dynamically linked against libSystem, ad-hoc code signed). `aarch64-linux`
  is queued as the third target once the aarch64 backend lands: it reuses
  that backend and the ELF linker.
- One optimization level, as in Go: no `-O` modes. Every build has Debug
  semantics (safety checks on, `builtin.mode == .debug`) and always-on
  optimization sized to compile fast (SSA, register allocation, inlining
  within a budget). Output stays debuggable: line tables, frame pointers,
  inlined frames. LLVM-class optimization (auto-vectorization, general
  loop unrolling, scheduling, heavy loop work) stays upstream's job; users run upstream
  `zig` for ReleaseFast and friends. Explicit `@Vector` code is lowered to
  SIMD registers (SSE/NEON), as upstream's Debug backend does, not
  scalarized. Cheap analyses that remove provably redundant work (bounds
  checks proven true, common subexpressions, invariant loads, full unrolling
  of tiny constant-trip loops) are allowed
  within the compile-time budget; safety checks are never removed unless
  proven, and never move across source lines.
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
- bs may reject more than upstream: extra compile errors that catch real
  mistakes are allowed. Everything else upstream accepts must still mean the
  same, and upstream's std and `test/behavior` must still compile, since
  they are the conformance measure.

## Architecture decisions

- Frontend: reuse `std.zig.Ast` (`Ast.parse`) and `std.zig.AstGen.generate` to
  produce ZIR. Do not fork or reimplement them.
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
  `zig` 0.17.1 Debug builds (self-hosted x86_64 backend), and do not land
  regressions without saying so. Track the speed of the code bs generates
  against upstream Debug and ReleaseSafe builds the same way, and report
  each backend change's compile-time cost next to its run-time win.

## Upstream reference

- `.agents/setup` installs upstream `zig` 0.17.1 on `PATH` in orbs. On a Mac
  satellite it leaves the owner's `zig` alone; use
  `~/.cache/bs/zig-aarch64-macos-0.17.1/zig` there. It also symlinks
  that release's source tree at `upstream/` (gitignored), which contains
  `upstream/src/Sema.zig`, `upstream/test/behavior/` and more.
- Upstream `zig` 0.17.1 is the oracle. When semantics are unclear, write a
  small program and compare bs's behavior and output with upstream's. Do not
  guess from memory.
- Conformance measure: the share of `upstream/test/behavior` that bs compiles
  and passes on each target. Keep that number visible. Measure it with
  `tools/conformance/run.py` (see `docs/slop/architecture.md`).
- Upstream is MIT licensed. Copying upstream code is allowed, but keep the
  upstream copyright notice with the copied code. Never send changes upstream;
  Zig does not accept LLM-authored contributions.

## Development

- bs is written in Zig 0.17.1. Build with `zig build`; test with `zig build test`.
- `docs/slop/architecture.md` fixes the boundaries between stages (analysis units,
  InternPool stable hashes, typed IR, Atoms, cache model). Follow it, and
  update it in the same change when a boundary moves.
- Time bs built with `-Doptimize=ReleaseFast`; a Debug build of bs is about
  10x slower and says nothing about bs's speed.
- Linux work runs in orbs. Verify aarch64-macos output on a real Mac (a Mac
  satellite for this project), not by inspection alone.
