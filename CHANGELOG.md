# Changelog

Changes a user of bs notices, newest first, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) form.

## [Unreleased]

### Added

- musl: `-lc` with `-target x86_64-linux-musl` or `aarch64-linux-musl`, and with plain `x86_64-linux` and `aarch64-linux`, whose default ABI is musl, builds static executables and tests against musl. libc.a and crt1.o are built once from the zig lib directory's sources with upstream's Clang and kept in the global cache. C and C++ sources (`-lc++`) and `bs translate-c` take musl's headers, and `bs build` steps that target musl build as upstream's do. `-dynamic` with musl is refused.
- `-target aarch64-linux` for `bs build-exe`, `bs build-obj`, `bs build-lib`, `bs test`, and `bs run`: static executables, objects, and static libraries for the generic ARMv8.0 CPU, with C sources, objects, and archives, and `bs translate-c -target aarch64-linux`. Executables and tests link glibc with `-lc -target aarch64-linux-gnu[.version]`, shared libraries, and libc++ with `-lc++`. `bs build-lib -dynamic` builds shared libraries, with or without `-lc`, and `-fPIC`, `-fPIE` and `-lc` build position-independent objects and libraries. They use the on-disk cache as x86_64-linux builds do.
- Container-level assembly (`comptime { asm (...); }`) is assembled into the program on all targets, so its `.global` labels satisfy `extern fn` declarations and C references, as with upstream's LLVM backend (upstream's self-hosted backends drop it). What bs cannot assemble is a compile error at the `asm`.
- On aarch64-linux and aarch64-macos, C calls pass homogeneous float aggregates, vectors, and bool vectors as Clang does, and `callconv(.{ .aarch64_preserve_none = .{} })` works; upstream's C ABI tests pass.
- On aarch64-macos, `-framework X`, `-needed_framework X` and `-F<dir>` link frameworks, and `-l` finds the macOS SDK's text-based stubs (`-lz`, `-lobjc`), as upstream does.
- On aarch64-macos, C objects compiled as Objective-C link: classes, protocols, selector references and constant CFStrings work as with upstream (raylib-zig's GLFW backend), and libraries that linked frameworks re-export, such as libobjc and CoreFoundation, are linked in their own right, as upstream does.

### Changed

- C sources for `-target x86_64-linux` and `aarch64-linux` compile for the musl ABI those targets resolve to, as upstream's do, and `bs translate-c` uses it in the target triple.
- On aarch64, a call whose target is beyond the ±128 MiB branch range is an `error[branch-range]` that names the caller and the target (bs adds no range-extension thunks), instead of `link failed: RelocationOverflow`.
- zap is now bs. The binary is `bs`, the environment variables are `BS_*`, and the caches are `<global cache>/bs`, `.zig-cache/bs`, and `~/.cache/bs`. Old `ZAP_*` variables are ignored; delete `~/.cache/zig/zap`, `.zig-cache/zap`, and `~/.cache/zap`.

### Fixed

- x86_64 inline assembly accepts memory operands with an index register, such as `lea (%rdi,%rsi,1), %eax`.
- On aarch64, functions with stack frames of 16 MiB or more compile, and a large `@splat` (such as `std.mem.zeroes` of a big array) is written by one copy loop instead of one store per element, which made such a function hundreds of times larger than upstream's.
- A pointer to an array coerces to a pointer to a one-element array of it, such as `*[3]u8` to `*[1][3]u8`, as upstream allows.
- A C object's strong definition now replaces a weak export of the Zig code, as in ld, instead of failing with a duplicate symbol.
- Copying a struct that the optimizer splits into a global variable no longer crashes bs (upstream's `lib/c.zig` `drand48` does).
- `callconv` takes a `std.builtin.CallingConvention` value computed at comptime, such as `callconv(cc orelse .c)`.
