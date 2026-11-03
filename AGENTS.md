# zap

zap is an independent Zig compiler aimed at Go-class compile speed. It does
not track upstream: it compiles exactly one pinned Zig release (currently
0.17.0) and the std library shipped with it.

## Scope

- Targets: `x86_64-linux` (static ELF first) and `aarch64-macos` (Mach-O,
  dynamically linked against libSystem, ad-hoc code signed).
- One optimization level, as in Go: no `-O` modes. Every build has Debug
  semantics (safety checks on, `builtin.mode == .Debug`) and always-on
  optimization sized to compile fast (SSA, register allocation, inlining
  within a budget). Output stays debuggable: line tables, frame pointers,
  inlined frames. LLVM-class optimization (vectorization, heavy loop work)
  stays upstream's job; users run upstream `zig` for ReleaseFast and friends.
- Out of scope unless the user asks: other targets, release modes, LLVM,
  `@cImport`/translate-c, the C backend, compiling C sources.
- CLI: drop-in for `zig build-exe`, `zig build-obj`, `zig run`, `zig test`, and `zig build`
  (zap compiles and runs the build runner and serves its compile steps over the
  `--listen=-` compiler protocol).
- zap's main users are coding agents. Shape compile errors for them, not for
  humans: exact locations, the facts an agent needs to fix the error, and
  fixes where zap knows them, in a form a program can parse.
- zap may reject more than upstream: extra compile errors that catch real
  mistakes are allowed. Everything else upstream accepts must still mean the
  same, and upstream's std and `test/behavior` must still compile, since
  they are the conformance measure.

## Architecture decisions

- Frontend: reuse `std.zig.Ast` (`Ast.parse`) and `std.zig.AstGen.generate` to
  produce ZIR. Do not fork or reimplement them.
- Everything after ZIR is zap's own code: semantic analysis and comptime
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
  `zig` 0.17.0 Debug builds (self-hosted x86_64 backend), and do not land
  regressions without saying so. Track the speed of the code zap generates
  against upstream Debug and ReleaseSafe builds the same way, and report
  each backend change's compile-time cost next to its run-time win.

## Upstream reference

- `.agents/setup` installs upstream `zig` 0.17.0 on `PATH` in orbs. On a Mac
  satellite it leaves the owner's `zig` alone; use
  `~/.cache/zap/zig-aarch64-macos-0.17.0/zig` there. It also symlinks
  that release's source tree at `upstream/` (gitignored), which contains
  `upstream/src/Sema.zig`, `upstream/test/behavior/` and more.
- Upstream `zig` 0.17.0 is the oracle. When semantics are unclear, write a
  small program and compare zap's behavior and output with upstream's. Do not
  guess from memory.
- Conformance measure: the share of `upstream/test/behavior` that zap compiles
  and passes on each target. Keep that number visible. Measure it with
  `tools/conformance/run.py` (see `docs/architecture.md`).
- Upstream is MIT licensed. Copying upstream code is allowed, but keep the
  upstream copyright notice with the copied code. Never send changes upstream;
  Zig does not accept LLM-authored contributions.

## Development

- zap is written in Zig 0.17.0. Build with `zig build`; test with `zig build test`.
- `docs/architecture.md` fixes the boundaries between stages (analysis units,
  InternPool stable hashes, typed IR, Atoms, cache model). Follow it, and
  update it in the same change when a boundary moves.
- Time zap built with `-Doptimize=ReleaseFast`; a Debug build of zap is about
  10x slower and says nothing about zap's speed.
- Linux work runs in orbs. Verify aarch64-macos output on a real Mac (a Mac
  satellite for this project), not by inspection alone.
