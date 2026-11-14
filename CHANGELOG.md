# Changelog

Changes a user of bs notices, newest first, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) form.

## [Unreleased]

### Added

- aarch64 inline assembly takes what hand-written kernels use, so a build for aarch64-linux of a project that depends on fastmem 0.2.0 no longer stops at `bs does not support this inline assembly instruction yet: 'b.hi .L…_fm_simd_cpy_long'`, and fastmem's Advanced SIMD memcpy, memmove and memset come out byte for byte as upstream's. New are named labels (`name:`, `.Lname:`) as branch and `adr` targets within one asm; `tbz` and `tbnz`; a conditional branch without the dot (`bhi` for `b.hi`); `.p2align`, `.align` and `.balign` with an optional most padding, which pad with nops and align the function to match; `ldr`, `str`, `ldur`, `stur`, `ldp` and `stp` of the b, h, s, d and q registers; index registers with `lsl`, `uxtw`, `sxtw` and `sxtx`; `dup` from a general register; `dc zva` and the other `dc` and `ic` operations with a register; `mrs` of `dczid_el0`; and constant expressions such as `#(16 * 4)`, with the assembler's operator precedence for the object format. A branch to a label the asm does not define is an error at the branch, as is a fill value other than nops, and a load or store offset that no encoding holds is an error that names the offsets one does.

### Fixed

- aarch64 inline assembly encodes three instructions as upstream's assembler does. `crc32b` to `crc32cx` with `wzr` or `xzr` as an operand assembled another instruction: w0 or x0 in its place with a bit of the next field set, which `crc32cw w0, wzr, w1` ran into as an illegal instruction. `pmull` and `pmull2` on bytes (`pmull v0.8h, v1.8b, v2.8b`) assembled the doubleword form (`.1q`), and another arrangement is now an error. `clrex` without an operand assembled `clrex #0`, not `clrex #15`. And `aese`, `aesd`, `aesmc`, `aesimc`, `pmull` on doublewords and the `sha256` instructions are errors without the CPU's `aes` or `sha2` feature, as they are upstream; bs assembled them for any CPU.
- A program that coerces a generic function to another function type (`const f: fn (anytype, anytype) u32 = foo;`, or `std.math.add` passed as a `fn (comptime type, i32, i32) error{Overflow}!i32`) builds again after an edit, and when bs reuses another program's cache: since 0.1.2 such a build failed with `bs cache: 'foo' is a function of the last build that this one does not have`, and only a build with an empty cache compiled it.
- An edit build after a generic function passed to `std.Thread.spawn` gained a parameter no longer reads past the end of the old function type, which crashed a Debug bs with `index out of bounds`.
- A comptime loop that fills an array a few elements at a time through a subarray (`s[i * 4 ..][0..4].* = "nop\n".*`) takes time in proportion to the array, not to its square: bs made the whole array again at every such store. Filling 36,000 bytes this way took 15 s and 4.6 GiB of memory, and takes 0.2 s and 37 MiB.
- On aarch64-macos, `;` in inline and container-level assembly starts a comment, as it does for upstream's assembler there, and `%%` separates two statements on a line (`%%%%` in an inline template, where `%%` is one `%`). bs took `;` as the separator on every target, so `mov x0, #1 ; mov x0, #2` ran both instructions on a Mac where upstream runs the first. aarch64-linux is unchanged: `;` separates there.
- aarch64 inline assembly's `mrs xzr, <register>` discards the value instead of writing it to x0, and `mrs`, `msr` and `adr` with a w register or sp are errors, as they are upstream; bs assembled them with the x register or xzr of that number, or crashed (`adr sp`).

## [0.1.3] - 2026-11-12

### Fixed

- An edit build after a struct's fields all lost their default values (`choices: []Choice = &.{},` becoming `choices: []Choice,` on the last one) no longer crashes with a segmentation fault. The struct's declarations are then made again, and the build brought a type's field defaults up to date before its layout when the edit reached only the defaults, such as those of the `StaticStringMap` that `std.meta.stringToEnum` makes from an enum in that struct.

## [0.1.2] - 2026-11-12

### Fixed

- An edit build after a function passed to `std.Thread.spawn` or `io.concurrent` gained a parameter no longer reports a false type error in that function, such as `expected type 'bool', found 'i16'` at the new parameter's use. The build reused the old thread entry point's records, whose function had the old type.
- On a native aarch64 Linux host, `translate-c` (and so a `zig build` with `b.addTranslateC`) translates for the native target instead of refusing with `bs translates C only for x86_64-linux and aarch64-macos so far ('native')`. It resolves the native target as `build-exe` does, so a native musl host's `-lc` now takes musl's headers on x86_64 too, as `build-exe` links musl there.

## [0.1.1] - 2026-11-12

### Added

- Nix: `nix run github:baskingspot/bs/v0.1.1` runs the release. `packages.default` in the flake builds bs with the Zig 0.17.1 it compiles std with, ReleaseFast and stripped as the release binaries are, wrapped so that zig is on `PATH` and bs runs on a machine that has none. The org's binary cache serves that build, so `nix run` downloads it instead of compiling: 5 MiB, plus the 365 MiB Zig it wraps on a machine that has no zig. zig 0.16.0 stays a `BS_ZIG_0_16` a 0.16 project supplies. The release notes name the tag, so an install follows the release and not `main`.

### Changed

- The flake's dev shell covers a native aarch64 Linux host, where bs builds and tests natively. `qemu-user` stays on x86_64, where it runs that target's test binaries.

## [0.1.0] - 2026-11-09

The first release.

### Added

- `bs --version` prints bs's own version. `bs version` still prints the Zig version it compiles, as `zig version` does.
- Zig 0.16.0 next to 0.17.1. A project opts in with `.zig_version = "0.16"` in its `.bs.zon`: `bs build` then builds it as Zig 0.16, with its dependencies and every step, and so do `bs build-exe`, `test` and `run` of a file under it, as does any compilation with `--zig-version 0.16`. Without it, everything builds as Zig 0.17, whatever `minimum_zig_version` says; when such a build fails and the project's `minimum_zig_version` is 0.16.x, the first error gets a note at that field naming the `.bs.zon` fix. Its syntax, semantics, std, build system, `@cImport` and compile errors are 0.16's. It needs a zig 0.16.0 install, found as `BS_ZIG_0_16`, else in `~/.cache/bs/zig-<host>-0.16.0`, else as `zig` on PATH if that is 0.16.0, for its lib directory and its `zig cc`. A build that uses `@cImport` uses the incremental cache: an edit to its Zig code or to a header it includes rebuilds only what the edit reaches.
- A project that asks for it, with a `lint` section in its `.bs.zon` (the schema of `.ziglint.zon`) or with a `.ziglint.zon` (used when the `.bs.zon` has no `lint` section), gets ziglint 0.8.1's rules as compile errors in the files the config's `paths` cover, never in std or dependencies: `error[style, Z026]: empty catch block suppresses errors` and the like, with ziglint's messages, exact locations, and `"rule"` in JSON output. `.lint = true` or `.lint = .{}` means ziglint's defaults (every rule but Z033), and `.lint = false` keeps lint off. bs finds the config from the root source file up to the nearest `build.zig`; `// ziglint-ignore:` comments work as in ziglint, and nothing else turns a finding off. A config bs cannot read, an unknown rule included, is an `error[lint-config]`. This first part covers the rules ziglint checks from the syntax alone; deprecated calls (Z011), declarations used through an instance (Z027) and the type-aware parts of the other rules follow. Builds of a project with neither are unchanged.
- On aarch64-macos, executables and tests (`bs build-exe`, `bs run`, `bs test`, and those `bs build` steps) use the on-disk cache as Linux builds do: an edit build analyzes and generates only what the edit reaches and relinks from the cache, with a fresh ad-hoc code signature and dSYM, so an edit to the zig compiler's sources builds in 0.11–0.17 s instead of 3.8 s, and to hello or libvaxis in 9–20 ms instead of 70–130 ms (mac.large). Executables with object inputs, archives and C sources relink from the cache too, with their objects converted again; a change to an object alone relinks in milliseconds. Objects, static libraries and dylibs build in full when their inputs changed, as before.
- LLVM IR sources, `.ll` and `.bc`, compile through upstream's Clang as upstream compiles them (no preprocessor, no depfile), in `bs build-exe`, `build-obj`, `build-lib`, `test` and `bs build` steps. They were `[unsupported]`; evm.zig's native precompiles pass mcl's `.ll` files.
- On aarch64-macos, `bs build-obj` with C sources or object inputs writes one relocatable Mach-O object of them, as upstream does (a single C object is copied as it is), so zine's tree-sitter steps build.
- `--force_undefined <name>` (`forceUndefinedSymbol` in build.zig) makes the link treat the name as referenced, so the archive member that defines it is linked, as lld's and ld64's `-u` do. On aarch64-macos the name is a Mach-O symbol name (`_keep_me` for C's `keep_me`), and one that nothing defines is an `undefined-symbol` error, as with upstream.
- Binary releases for x86_64 Linux, aarch64 Linux, and Apple Silicon macOS, on GitHub and in the Homebrew tap (`brew install --cask baskingspot/tap/bs`); mise installs them as `github:baskingspot/bs`.
- `bs cc`, `bs c++`, `bs ar` and `bs ranlib` run upstream zig's with the same arguments, so build scripts that run them through `b.graph.zig_exe` under `bs build` work, such as ghostty's `zig ar -M` that combines its archives. They were `[unsupported]` (`cc`, `c++`) or unknown commands.
- `--version-script` for ELF shared libraries (`bs build-lib -dynamic`, and `setVersionScript` in `bs build`), as lld reads it: version nodes and anonymous nodes, `global:` and `local:` patterns with `*`, `?` and `[...]` wildcards, quoted names, and `extern "C"` blocks, with lld's precedence. Versioned exports get `.gnu.version` entries and the nodes `.gnu.version_d`; `local:` symbols leave `.dynsym`, and C objects reach them directly rather than through the loader. A name the script versions that nothing defines is an `error[version-script]` at it unless `--undefined-version`. `extern "C++"` blocks are refused, as are version scripts on aarch64-macos.
- `-rdynamic` on a dynamically linked executable (`-lc` with glibc) exports all its global definitions, Zig's and its C objects', so the shared objects it loads with `dlopen` bind to them, as upstream does. A stock Lua interpreter built with `-rdynamic` loads C modules (siv's `test-lua`).
- musl: `-lc` with `-target x86_64-linux-musl` or `aarch64-linux-musl`, and with plain `x86_64-linux` and `aarch64-linux`, whose default ABI is musl, builds static executables and tests against musl. libc.a and crt1.o are built once from the zig lib directory's sources with upstream's Clang and kept in the global cache. C and C++ sources (`-lc++`) and `bs translate-c` take musl's headers, and `bs build` steps that target musl build as upstream's do. `-dynamic` with musl is refused.
- `-target aarch64-linux` for `bs build-exe`, `bs build-obj`, `bs build-lib`, `bs test`, and `bs run`: static executables, objects, and static libraries for the generic ARMv8.0 CPU, with C sources, objects, and archives, and `bs translate-c -target aarch64-linux`. Executables and tests link glibc with `-lc -target aarch64-linux-gnu[.version]`, shared libraries, and libc++ with `-lc++`. `bs build-lib -dynamic` builds shared libraries, with or without `-lc`, and `-fPIC`, `-fPIE` and `-lc` build position-independent objects and libraries. They use the on-disk cache as x86_64-linux builds do.
- Container-level assembly (`comptime { asm (...); }`) is assembled into the program on all targets, so its `.global` labels satisfy `extern fn` declarations and C references, as with upstream's LLVM backend (upstream's self-hosted backends drop it). What bs cannot assemble is a compile error at the `asm`.
- On aarch64-linux and aarch64-macos, C calls pass homogeneous float aggregates, vectors, and bool vectors as Clang does, and `callconv(.{ .aarch64_preserve_none = .{} })` works; upstream's C ABI tests pass.
- On aarch64-macos, `-framework X`, `-needed_framework X` and `-F<dir>` link frameworks, and `-l` finds the macOS SDK's text-based stubs (`-lz`, `-lobjc`), as upstream does.
- On aarch64-macos, `-lc++` links libc++ and libc++abi, built from the zig lib directory's sources as upstream builds them (libSystem provides libunwind), so C++ sources with exceptions, iostream and the rest of the standard library link and run as with upstream.
- On aarch64-macos, C objects compiled as Objective-C link: classes, protocols, selector references and constant CFStrings work as with upstream (raylib-zig's GLFW backend), and libraries that linked frameworks re-export, such as libobjc and CoreFoundation, are linked in their own right, as upstream does.

### Changed

- A project whose `minimum_zig_version` is newer than 0.17.x still builds as Zig 0.17, as with upstream zig, but when the build fails, the first error gets a note at that field: `bs built this as Zig 0.17: minimum_zig_version '0.18.0' names a release this bs does not know; it knows Zig languages up to 0.17`.
- An explicit x86_64 CPU past x86-64-v2 (`-mcpu x86_64_v3`, `haswell`, `znver5`, and the like, as per-CPU kernel objects ask for) is accepted instead of refused: `builtin.cpu` is that CPU, so the program's comptime choices match upstream's, and bs's own code stays SSE4.2. A C-convention function that passes a vector over 16 bytes by value on a CPU with AVX, and an asm `x` operand over 16 bytes, are `[unsupported]`, since AVX would put them in YMM or ZMM registers. Features no CPU model has (`soft_float`, `retpoline`) stay refused. siv builds and passes its tests under `bs build` with its image decoders' fastmem kernels.
- `-fomit-frame-pointer` (`.omit_frame_pointer = true`) is accepted; bs still keeps frame pointers.
- bs finds Zig 0.17.1's lib directory when it runs, not where it was built: `--zig-lib-dir`, then `ZIG_LIB_DIR`, then the lib directory of upstream zig (`BS_ZIG`, else `zig` on `PATH`), which must be 0.17.1. Without one, bs fails with an error that names the version it needs.
- C sources for `-target x86_64-linux` and `aarch64-linux` compile for the musl ABI those targets resolve to, as upstream's do, and `bs translate-c` uses it in the target triple.
- On aarch64, a call whose target is beyond the ±128 MiB branch range is an `error[branch-range]` that names the caller and the target (bs adds no range-extension thunks), instead of `link failed: RelocationOverflow`.
- zap is now bs. The binary is `bs`, the environment variables are `BS_*`, and the caches are `<global cache>/bs`, `.zig-cache/bs`, and `~/.cache/bs`. Old `ZAP_*` variables are ignored; delete `~/.cache/zig/zap`, `.zig-cache/zap`, and `~/.cache/zap`.

### Fixed

- A stack trace frame of code inlined from another module names that module, as upstream's and `BS_INLINE=0`'s do: `assert (std.zig)`, not `assert (m.zig)`, when std's `assert` is inlined into `m.zig`'s `main`. The inlined code is now in its module's DWARF compile unit, with its line rows repeated there.
- On aarch64-macos, the libraries a linked stub re-exports are looked up by name in the `-F` and `-L` directories before the SDK the stub is in, as upstream does, so a vendored SDK passed with `-F` (zine's) links. bs failed with "re-exports ... whose stub ... cannot be read".
- Without runtime safety (ReleaseFast and ReleaseSmall `bs build` steps, or `@setRuntimeSafety(false)`), `@memset(x, undefined)` and stores of `undefined` write nothing, as upstream's do, instead of filling 0xaa; Debug and ReleaseSafe still fill. Memory fresh from mmap stays zero after std's allocator marks it undefined, which Ghostty's terminal pages rely on: its `terminal-stream`, `terminal-formatter` and `screen-clone` bench tools crashed.
- On x86_64, a slice or other value a function returns through its result pointer, read back through a local after it is written, no longer clobbers a value the register allocator kept in r11: astroz's `Screening.refine` got a stack address as a slice bound and failed its bounds check.
- In `bs build`, the first build after a cold one no longer compiles shared libraries and `-fPIC` objects again when they link other steps' outputs, nor reruns every step that depends on them.
- In `bs build`, the first build after a cold one no longer compiles shared libraries and `-fPIC` objects again when their C sources include a header another step generated, nor reruns every step that depends on them.
- In an ELF object (`bs build-obj`), a constant table of extern function pointers that code copies, such as `const libs = [_]Lib{ .{ .open = c.luaopen_base }, ... }` read in a `for` loop, keeps its relocations to those functions, instead of leaving null pointers that crash when called.
- On aarch64-macos, static libraries index their members' hidden (private external) definitions, as upstream's do, so another member or a program linking the library can pull them.
- On aarch64-macos, C and Objective-C objects whose functions catch exceptions (`@try`/`@catch`, C++ `try`) link: their `__eh_frame` is kept and their compact unwind entries reach `__unwind_info`, and the POINTER_TO_GOT relocations of their personality pointers are resolved, so a throw finds its handler as with upstream, instead of the link refusing the relocations.
- `@ptrCast` of a null optional pointer to a C pointer (or an allowzero pointer) gives a null pointer, as upstream, instead of panicking with "cast causes pointer to be null" at run time or failing with "null pointer casted" at comptime. ghostty's oniguruma binding passes `@ptrCast(err)` with `err == null`. A comptime-known null C or allowzero pointer cast to a pointer that does not allow zero is now that compile error, as upstream, instead of a zero `*T`.
- On aarch64-macos, `__unwind_info`'s second-level pages are at most 4 KiB, as ld64 writes them, so `objdump --unwind-info` and lldb read them without "attempt to read past end of buffer" warnings.
- On ELF targets, a global absolute symbol an object defines (`.globl sym; .set sym, 0x1234`) binds from other objects and from Zig `extern` declarations, as upstream's, instead of being an undefined symbol.
- On aarch64-macos, a global absolute symbol an object defines (`.globl _sym; .set _sym, 0x1234`) binds from other objects and from Zig `extern` declarations instead of becoming a libSystem import that dyld cannot find, and pointers to it hold the value unslid, as ld64 links them.
- x86_64 inline assembly accepts inputs tied to an output (`[_] "0" (a)`) and early-clobber register outputs (`"=&r"`).
- x86_64 inline assembly accepts memory operands with an index register, such as `lea (%rdi,%rsi,1), %eax`.
- On aarch64, functions with stack frames of 16 MiB or more compile, and a large `@splat` (such as `std.mem.zeroes` of a big array) is written by one copy loop instead of one store per element, which made such a function hundreds of times larger than upstream's.
- A pointer to an array coerces to a pointer to a one-element array of it, such as `*[3]u8` to `*[1][3]u8`, as upstream allows.
- A C object's strong definition now replaces a weak export of the Zig code, as in ld, instead of failing with a duplicate symbol.
- Copying a struct that the optimizer splits into a global variable no longer crashes bs (upstream's `lib/c.zig` `drand48` does).
- `callconv` takes a `std.builtin.CallingConvention` value computed at comptime, such as `callconv(cc orelse .c)`.

[Unreleased]: https://github.com/baskingspot/bs/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/baskingspot/bs/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/baskingspot/bs/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/baskingspot/bs/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/baskingspot/bs/releases/tag/v0.1.0
