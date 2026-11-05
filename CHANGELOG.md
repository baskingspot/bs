# Changelog

Changes a user of bs notices, newest first, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) form.

## [Unreleased]

### Added

- Binary releases for x86_64 Linux, aarch64 Linux, and Apple Silicon macOS, on GitHub and in the Homebrew tap (`brew install --cask baskingspot/tap/bs`); mise installs them as `github:baskingspot/bs`.
- `--version-script` for ELF shared libraries (`bs build-lib -dynamic`, and `setVersionScript` in `bs build`), as lld reads it: version nodes and anonymous nodes, `global:` and `local:` patterns with `*`, `?` and `[...]` wildcards, quoted names, and `extern "C"` blocks, with lld's precedence. Versioned exports get `.gnu.version` entries and the nodes `.gnu.version_d`; `local:` symbols leave `.dynsym`, and C objects reach them directly rather than through the loader. A name the script versions that nothing defines is an `error[version-script]` at it unless `--undefined-version`. `extern "C++"` blocks are refused, as are version scripts on aarch64-macos.
- `-rdynamic` on a dynamically linked executable (`-lc` with glibc) exports all its global definitions, Zig's and its C objects', so the shared objects it loads with `dlopen` bind to them, as upstream does. A stock Lua interpreter built with `-rdynamic` loads C modules (siv's `test-lua`).
- musl: `-lc` with `-target x86_64-linux-musl` or `aarch64-linux-musl`, and with plain `x86_64-linux` and `aarch64-linux`, whose default ABI is musl, builds static executables and tests against musl. libc.a and crt1.o are built once from the zig lib directory's sources with upstream's Clang and kept in the global cache. C and C++ sources (`-lc++`) and `bs translate-c` take musl's headers, and `bs build` steps that target musl build as upstream's do. `-dynamic` with musl is refused.
- `-target aarch64-linux` for `bs build-exe`, `bs build-obj`, `bs build-lib`, `bs test`, and `bs run`: static executables, objects, and static libraries for the generic ARMv8.0 CPU, with C sources, objects, and archives, and `bs translate-c -target aarch64-linux`. Executables and tests link glibc with `-lc -target aarch64-linux-gnu[.version]`, shared libraries, and libc++ with `-lc++`. `bs build-lib -dynamic` builds shared libraries, with or without `-lc`, and `-fPIC`, `-fPIE` and `-lc` build position-independent objects and libraries. They use the on-disk cache as x86_64-linux builds do.
- Container-level assembly (`comptime { asm (...); }`) is assembled into the program on all targets, so its `.global` labels satisfy `extern fn` declarations and C references, as with upstream's LLVM backend (upstream's self-hosted backends drop it). What bs cannot assemble is a compile error at the `asm`.
- On aarch64-linux and aarch64-macos, C calls pass homogeneous float aggregates, vectors, and bool vectors as Clang does, and `callconv(.{ .aarch64_preserve_none = .{} })` works; upstream's C ABI tests pass.
- On aarch64-macos, `-framework X`, `-needed_framework X` and `-F<dir>` link frameworks, and `-l` finds the macOS SDK's text-based stubs (`-lz`, `-lobjc`), as upstream does.
- On aarch64-macos, C objects compiled as Objective-C link: classes, protocols, selector references and constant CFStrings work as with upstream (raylib-zig's GLFW backend), and libraries that linked frameworks re-export, such as libobjc and CoreFoundation, are linked in their own right, as upstream does.

### Changed

- bs finds Zig 0.17.1's lib directory when it runs, not where it was built: `--zig-lib-dir`, then `ZIG_LIB_DIR`, then the lib directory of upstream zig (`BS_ZIG`, else `zig` on `PATH`), which must be 0.17.1. Without one, bs fails with an error that names the version it needs.
- C sources for `-target x86_64-linux` and `aarch64-linux` compile for the musl ABI those targets resolve to, as upstream's do, and `bs translate-c` uses it in the target triple.
- On aarch64, a call whose target is beyond the ±128 MiB branch range is an `error[branch-range]` that names the caller and the target (bs adds no range-extension thunks), instead of `link failed: RelocationOverflow`.
- zap is now bs. The binary is `bs`, the environment variables are `BS_*`, and the caches are `<global cache>/bs`, `.zig-cache/bs`, and `~/.cache/bs`. Old `ZAP_*` variables are ignored; delete `~/.cache/zig/zap`, `.zig-cache/zap`, and `~/.cache/zap`.

### Fixed

- In `bs build`, the first build after a cold one no longer compiles shared libraries and `-fPIC` objects again when they link other steps' outputs, nor reruns every step that depends on them.
- In an ELF object (`bs build-obj`), a constant table of extern function pointers that code copies, such as `const libs = [_]Lib{ .{ .open = c.luaopen_base }, ... }` read in a `for` loop, keeps its relocations to those functions, instead of leaving null pointers that crash when called.
- On aarch64-macos, `__unwind_info`'s second-level pages are at most 4 KiB, as ld64 writes them, so `objdump --unwind-info` and lldb read them without "attempt to read past end of buffer" warnings.
- On ELF targets, a global absolute symbol an object defines (`.globl sym; .set sym, 0x1234`) binds from other objects and from Zig `extern` declarations, as upstream's, instead of being an undefined symbol.
- On aarch64-macos, a global absolute symbol an object defines (`.globl _sym; .set _sym, 0x1234`) binds from other objects and from Zig `extern` declarations instead of becoming a libSystem import that dyld cannot find, and pointers to it hold the value unslid, as ld64 links them.
- x86_64 inline assembly accepts memory operands with an index register, such as `lea (%rdi,%rsi,1), %eax`.
- On aarch64, functions with stack frames of 16 MiB or more compile, and a large `@splat` (such as `std.mem.zeroes` of a big array) is written by one copy loop instead of one store per element, which made such a function hundreds of times larger than upstream's.
- A pointer to an array coerces to a pointer to a one-element array of it, such as `*[3]u8` to `*[1][3]u8`, as upstream allows.
- A C object's strong definition now replaces a weak export of the Zig code, as in ld, instead of failing with a duplicate symbol.
- Copying a struct that the optimizer splits into a global variable no longer crashes bs (upstream's `lib/c.zig` `drand48` does).
- `callconv` takes a `std.builtin.CallingConvention` value computed at comptime, such as `callconv(cc orelse .c)`.
