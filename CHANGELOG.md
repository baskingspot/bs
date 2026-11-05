# Changelog

Changes a user of bs notices, newest first, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) form.

## [Unreleased]

### Added

- `-target aarch64-linux` for `bs build-exe`, `bs build-obj`, `bs build-lib`, `bs test`, and `bs run`: static executables, objects, and static libraries for the generic ARMv8.0 CPU, with C sources, objects, and archives, and `bs translate-c -target aarch64-linux`. Executables and tests link glibc with `-lc -target aarch64-linux-gnu[.version]`, shared libraries, and libc++ with `-lc++`. `bs build-lib -dynamic` builds shared libraries, with or without `-lc`, and `-fPIC`, `-fPIE` and `-lc` build position-independent objects and libraries. They use the on-disk cache as x86_64-linux builds do.
- Container-level assembly (`comptime { asm (...); }`) is assembled into the program on all targets, so its `.global` labels satisfy `extern fn` declarations and C references, as with upstream's LLVM backend (upstream's self-hosted backends drop it). What bs cannot assemble is a compile error at the `asm`.
- On aarch64-linux and aarch64-macos, C calls pass homogeneous float aggregates, vectors, and bool vectors as Clang does, and `callconv(.{ .aarch64_preserve_none = .{} })` works; upstream's C ABI tests pass.
- On aarch64-macos, `-framework X`, `-needed_framework X` and `-F<dir>` link frameworks, and `-l` finds the macOS SDK's text-based stubs (`-lz`, `-lobjc`), as upstream does.

### Changed

- zap is now bs. The binary is `bs`, the environment variables are `BS_*`, and the caches are `<global cache>/bs`, `.zig-cache/bs`, and `~/.cache/bs`. Old `ZAP_*` variables are ignored; delete `~/.cache/zig/zap`, `.zig-cache/zap`, and `~/.cache/zap`.

### Fixed

- x86_64 inline assembly accepts memory operands with an index register, such as `lea (%rdi,%rsi,1), %eax`.
- On aarch64, functions with stack frames of 16 MiB or more compile, and a large `@splat` (such as `std.mem.zeroes` of a big array) is written by one copy loop instead of one store per element, which made such a function hundreds of times larger than upstream's.
- `callconv` takes a `std.builtin.CallingConvention` value computed at comptime, such as `callconv(cc orelse .c)`.
