<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="bs" height="48">
  </picture>
</h1>

A fast Debug-mode compiler for Zig 0.17.

bs compiles exactly one Zig release, 0.17.1, and the std library that ships with it, for x86_64 Linux and Apple Silicon macOS. It takes the same commands and flags as `zig build-exe`, `zig build-obj`, `zig run`, `zig test`, and `zig build`, so a project's own `build.zig` builds with it unchanged. Every build has Debug semantics: safety checks stay on, and the output keeps line tables and frame pointers. For ReleaseFast, use upstream `zig`.

Its compile errors are written for coding agents: an exact location, the facts needed to fix the error, and the fix when bs knows it, in a form a program can parse.

bs is incubating. There are no releases yet, so build it from source.

## Build it

bs builds with upstream Zig 0.17.1:

```sh
zig build -Doptimize=ReleaseFast
```

The compiler is `zig-out/bin/bs`. A Debug build of bs is about ten times slower, so time only a ReleaseFast one.

C and C++ sources, `-lc`, and `@cImport` go through upstream's `zig cc` and translate-c. bs looks for upstream `zig` in `BS_ZIG`, then on `PATH`. bs compiles the std library of that zig, which must be 0.17.1; a bs built from source falls back to the lib directory of the zig that built it.

## Use it

```sh
bs build-exe main.zig
bs run main.zig -- arg
bs test lib.zig
bs build            # in a project with a build.zig
```

`bs help` lists every command. A flag that upstream accepts and bs cannot honor yet, such as a release mode or the LLVM backend, fails with a message that says so.

## Work on it

`nix develop` provides the toolchain, and `just ci` runs what CI runs. `just` lists the recipes, including `just conformance`, which measures the share of upstream's `test/behavior` that bs passes. In an Amp orb, `.agents/setup` installs the same toolchain without Nix. [`AGENTS.md`](AGENTS.md) has the scope, the architecture decisions, and the working conventions.

## License

MIT. See [`LICENSE`](LICENSE). Code copied from upstream Zig keeps its own MIT notice, in [`LICENSE-ZIG`](LICENSE-ZIG). The logo files in `docs/static/` are baskingspot marks and are not covered by either. See [`docs/static/LICENSE`](docs/static/LICENSE).
