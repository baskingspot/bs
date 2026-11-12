<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="bs" height="48">
  </picture>
</h1>

Fast Debug-mode compiler for Zig 0.17 and 0.16.

bs compiles two Zig releases, 0.17.1 and 0.16.0, each with the std library that ships with it, for x86_64 and aarch64 Linux and Apple Silicon macOS. A project builds as 0.17 unless its `.bs.zon` says `.zig_version = "0.16"`. It takes the same commands and flags as `zig build-exe`, `zig build-obj`, `zig run`, `zig test`, and `zig build`, so a project's own `build.zig` builds with it unchanged. Every build has Debug semantics: safety checks stay on, and the output keeps line tables and frame pointers. For ReleaseFast, use upstream `zig`.

Its compile errors are written for coding agents: an exact location, the facts needed to fix the error, and the fix when bs knows it, in a form a program can parse. A project that asks for it, with a `lint` section in `.bs.zon` or a `.ziglint.zon`, also gets [ziglint](https://github.com/rockorager/ziglint)'s rules as compile errors in its own files.

bs is incubating.

## Install

bs needs upstream Zig 0.17.1 on `PATH`: it compiles that release's std library, and hands C and C++ sources to its `zig cc`. Without it, or with another version, bs stops and says so. `--zig-lib-dir` or `ZIG_LIB_DIR` point it at a lib directory instead. A project on Zig 0.16 also needs zig 0.16.0, in `BS_ZIG_0_16` or as `zig` on `PATH`.

With Homebrew, on macOS or Linux:

```sh
brew install --cask baskingspot/tap/bs
```

With [mise](https://mise.jdx.dev), next to the zig it needs, in a project's `mise.toml`:

```toml
[tools]
zig = "0.17.1"
"github:baskingspot/bs" = "latest"
```

With Nix, pinned to a release, which brings the Zig 0.17.1 it needs:

```sh
nix run github:baskingspot/bs/v0.1.2 -- build-exe main.zig
```

Or download `bs-<version>-<platform>.tar.gz` for `linux-x64`, `linux-arm64`, or `macos-arm64` from [the releases](https://github.com/baskingspot/bs/releases), check it against `SHA256SUMS`, and put `bs` on `PATH`.

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

`bs help` lists every command. `bs --version` prints bs's own version; `bs version` prints the Zig version it compiles, as `zig version` does. A flag that upstream accepts and bs cannot honor yet, such as a release mode or the LLVM backend, fails with a message that says so.

## Work on it

`nix develop` provides the toolchain, and `just ci` runs what CI runs. `just` lists the recipes, including `just conformance`, which measures the share of upstream's `test/behavior` that bs passes. In an Amp orb, `.agents/setup` installs the same toolchain without Nix. [`AGENTS.md`](AGENTS.md) has the scope, the architecture decisions, and the working conventions.

## License

MIT. See [`LICENSE`](LICENSE). Code copied from upstream Zig keeps its own MIT notice, in [`LICENSE-ZIG`](LICENSE-ZIG). The logo files in `docs/static/` are baskingspot marks and are not covered by either. See [`docs/static/LICENSE`](docs/static/LICENSE).
