# Corpus rerun with donors (2026-11-05)

The whole corpus (all four rounds: 93 projects, 379 targets) with bs's
donors on and a run time for every target. bs is ReleaseFast from main
1c792147. The targets of zine, json-zig, zmath, flow, flow-musl, verse,
marionette, knoedel, zigdown, sandopolis, zlob, zigcli, zeit,
zig-blind-rsa-signatures and zio were rerun with bs from main 1a859c51,
after the harness fixes below. Upstream is zig 0.17.1 Debug. The machine is an orb with 4
vCPUs (Intel Xeon @ 2.60GHz), 7 GB of memory (runs capped at 6 GB) and
Linux 6.1.

## Method

- `python3 tools/corpus/run.py --bs <bs> --no-edit --donors --results <name>`.
  Each bs target builds twice from an empty local cache. The first build
  is timed without donors (cold-local). The second build has donors on,
  and its binary is the one that runs. A cold build without donors
  publishes no donor, so that second build takes whatever the global
  store offers. For most targets that is a donor from an earlier target
  of the same project (revo's two test programs, for example), and
  otherwise nothing.
- Run time is one wall-clock sample per target (`run_secs`). The
  outliers were retimed with 3 to 5 samples (below).

## Summary

- 356 of 379 targets match upstream.
- No divergence comes from donors or from the backend changes since the
  last run (copyelide, narrow loads, fill-dse). Every donor build
  compiled, and its binary behaved as upstream's did.
- Cold-local build time, over the 361 targets that both compilers
  build: geomean 1.67x faster than upstream, 320 s against 519 s in
  total. With donors (bs's first build in a fresh checkout), geomean
  2.49x and 234 s in total.
- Run time, over the 101 matching targets whose upstream run takes at
  least 50 ms: geomean 1.83x faster than upstream Debug.
- zls's own target was 0.9x cold. It was the first target after a new bs
  binary, so its build also built bs's global artifacts.

| Project | Target | Verdict | Class |
|---|---|---|---|
| verse | test:src/verse.zig | bs compile error: `inline else` on a comptime-known non-exhaustive enum | bs (Sema), open |
| marionette | 7 targets | bs compile error: `callconv(.withStackAlign(...))` decl literal | bs (Sema), open |
| knoedel | test | bs compile error: a runtime call as an argument to a type-returning function | bs (Sema), open |
| zigdown | zigdown, test | bs compile error: `fn (i32)` to `*const fn (c_int)` | bs (Sema), open |
| sandopolis | test | bs overflows the 64 MiB stack (an extra frame copy in `return f(x)`) | bs (backend), open |
| tokamak | test | bs panics on tokamak's misaligned transmute | tokamak's bug |
| revo | test:src/vm/root.zig | both panic, in different tests (stale threadlocal) | revo's bug |
| zio | coro-demo | upstream overflows the 64 KiB coroutine stack | upstream fails |
| zig-libs | regex | upstream overflows a 512 KiB thread stack | upstream fails |
| buzz | 3 targets | both refuse guaranteed tail calls | upstream fails |
| zmath | 2 targets | upstream's self-hosted backend fails | upstream fails |
| evm.zig | 2 targets | guaranteed tail calls: bs refuses them, upstream crashes | upstream fails |

## Harness fixes

- bf28dfb8 matched `zig build`'s optimize flags only by their long names
  (`-OReleaseFast`), but 0.17.1 prints `-Ofast`, `-Osafe` and `-Osmall`.
  Steps that force a release mode (zine's translate-c and camera,
  json-zig's json-fuzz, zmath, seven flow targets) therefore reached bs
  as `-Ofast`, which bs refuses. All of them pass with the flag matched.
- Test binaries compare each test's outcome by name, in any order,
  instead of their stdout: bs sorts tests, and upstream takes its work
  queue's order.
- A donor build that fails is a verdict, `bs: donor build failed`.
  Before, the run silently used the binary from the build without
  donors.
- flow-musl builds flow's default target, x86_64-linux-musl. All 25
  targets match upstream.

## Donor builds are not byte-identical

A donor build is not byte-identical to a build without donors. revo's
vm test program, built from revo's root test program's donor, has six
extra `__anon_*` constants in .rodata (240 bytes). They look
unreferenced. It behaves the same, and a build that replays its own
donor matches the donor build.

## Run-time outliers, retimed

Median of 5 runs (3 for zio and zig-blind-rsa-signatures), upstream / bs:

- zeit test: 227 / 262 ms, 0.87x. bs is consistently slower here.
- zio test: 11.58 / 12.21 s, 0.95x. The run is mostly waiting.
- zlob test_posix: 965 / 504 ms, 1.9x. The single sample (0.67x) was noise.
- zigcli loc: 161 / 43 ms, 3.7x.
- zig-blind-rsa-signatures test: 11.7 / 12.8 s, min 7.8 / 11.9 s. Its
  RSA key generation is random, so single runs vary 2x.

## Run time, every matching target of at least 50 ms

| Project | Target | upstream Debug | bs | ratio |
|---|---|---:|---:|---:|
| XirAsm | test | 21.62 s | 13.81 s | 1.57x |
| astroz | test | 5.05 s | 2.79 s | 1.81x |
| evm.zig | test:pkg/mpt/test.zig | 1.26 s | 513 ms | 2.46x |
| fizzy | fizzy-diff-tests | 92 ms | 58 ms | 1.60x |
| fizzy | fizzy-remote-tests | 34.49 s | 34.44 s | 1.00x |
| fizzy | fizzy-tape-tests | 991 ms | 542 ms | 1.83x |
| fizzy | fizzy-textcore-tests | 344 ms | 230 ms | 1.50x |
| flow | test-FileStore | 1.63 s | 1.62 s | 1.00x |
| flow | test-edit_set | 132 ms | 58 ms | 2.27x |
| flow | test-flow | 7.36 s | 4.65 s | 1.58x |
| flow | test-gitignore-differential | 217 ms | 193 ms | 1.13x |
| flow | test-keybind | 157 ms | 79 ms | 1.98x |
| flow | test-richdoc | 96 ms | 62 ms | 1.54x |
| flow-musl | test-FileStore | 1.64 s | 1.62 s | 1.01x |
| flow-musl | test-edit_set | 148 ms | 64 ms | 2.30x |
| flow-musl | test-flow | 7.82 s | 4.60 s | 1.70x |
| flow-musl | test-gitignore-differential | 221 ms | 183 ms | 1.21x |
| flow-musl | test-keybind | 200 ms | 79 ms | 2.53x |
| flow-musl | test-richdoc | 94 ms | 77 ms | 1.21x |
| flow-musl | test-terminal_screen | 53 ms | 48 ms | 1.09x |
| ghostty | ghostty-vt-test | 1402.28 s | 482.02 s | 2.91x |
| ghostty | props-unigen | 471 ms | 298 ms | 1.58x |
| ghostty | symbols-unigen | 120 ms | 57 ms | 2.11x |
| ghostty | uucode_generate | 2.23 s | 907 ms | 2.46x |
| http.zig | test | 30.56 s | 29.16 s | 1.05x |
| json-zig | test | 1.57 s | 852 ms | 1.84x |
| libvaxis | example-c-tty | 267 ms | 266 ms | 1.00x |
| libxev | xev-test | 266 ms | 165 ms | 1.61x |
| linuxwave | linuxwave | 152 ms | 117 ms | 1.30x |
| linuxwave | main-tests | 139 ms | 135 ms | 1.03x |
| metrics.zig | test | 88 ms | 67 ms | 1.31x |
| nanoui | test | 14.30 s | 13.95 s | 1.03x |
| nats.zig | test | 230 ms | 219 ms | 1.05x |
| revo | revo | 65 ms | 55 ms | 1.19x |
| revo | test:src/lang/tests/root.zig | 7.22 s | 4.10 s | 1.76x |
| revo | test:src/root.zig | 3.91 s | 2.52 s | 1.55x |
| sandopolis | test:tests/property_tests.zig | 16.01 s | 8.14 s | 1.97x |
| serde.zig | test:src/root.zig | 87 ms | 57 ms | 1.54x |
| serde.zig | test:test/core_regressions_test.zig | 94 ms | 55 ms | 1.71x |
| serde.zig | test:test/json_diagnostics_test.zig | 55 ms | 32 ms | 1.72x |
| teru | test | 215 ms | 143 ms | 1.50x |
| tls.zig | test | 2.84 s | 864 ms | 3.29x |
| vulkan-zig | vulkan-zig-generator | 942 ms | 346 ms | 2.72x |
| wild | test:tests/test_batch_read.zig | 1.12 s | 1.04 s | 1.07x |
| z2d | test | 171 ms | 62 ms | 2.75x |
| zarrow | test | 161 ms | 128 ms | 1.26x |
| zbor | test | 649 ms | 186 ms | 3.49x |
| zedis | test-unit | 3.42 s | 3.12 s | 1.10x |
| zeit | test | 235 ms | 265 ms | 0.89x |
| zeptun | test | 2.77 s | 2.51 s | 1.10x |
| zflecs | zflecs-tests | 1.32 s | 748 ms | 1.76x |
| ziex | test | 6.43 s | 6.09 s | 1.06x |
| zig-blind-rsa-signatures | test | 14.98 s | 9.74 s | 1.54x |
| zig-clap | subcommands | 51 ms | 11 ms | 4.80x |
| zig-compiler | aro-test | 230 ms | 114 ms | 2.02x |
| zig-compiler | translate-c | 4.01 s | 2.39 s | 1.68x |
| zig-ecs | test | 145 ms | 101 ms | 1.43x |
| zig-hpke | test | 1.24 s | 244 ms | 5.08x |
| zig-libs | cbor | 120 ms | 66 ms | 1.81x |
| zig-libs | ini | 6.69 s | 3.23 s | 2.07x |
| zig-libs | jinja | 4.56 s | 2.63 s | 1.73x |
| zig-libs | json5 | 1.63 s | 973 ms | 1.67x |
| zig-libs | protobuf | 571 ms | 243 ms | 2.35x |
| zig-libs | qr | 12.43 s | 4.29 s | 2.90x |
| zig-libs | raft | 57.81 s | 31.97 s | 1.81x |
| zig-libs | tar | 2.88 s | 1.45 s | 1.98x |
| zig-libs | trie | 20.59 s | 9.08 s | 2.27x |
| zig-libs | xml | 955 ms | 319 ms | 2.99x |
| zig-libs | yaml | 3.31 s | 1.30 s | 2.54x |
| zig-msgpack | test | 812 ms | 501 ms | 1.62x |
| zig-regex | test | 61 ms | 35 ms | 1.76x |
| zigcli | loc | 176 ms | 58 ms | 3.04x |
| zigimg | zigimgtest | 1.75 s | 492 ms | 3.57x |
| ziglua | test | 164 ms | 81 ms | 2.03x |
| zignal | zignal:src/root.zig | 26.72 s | 12.41 s | 2.15x |
| zio | ev-demo | 5.00 s | 5.00 s | 1.00x |
| zio | producer-consumer | 766 ms | 762 ms | 1.00x |
| zio | test | 11.68 s | 12.81 s | 0.91x |
| zlaya | test | 97 ms | 79 ms | 1.22x |
| zlob | test:test/test_absolute_paths.zig | 54 ms | 26 ms | 2.07x |
| zlob | test:test/test_brace.zig | 86 ms | 73 ms | 1.18x |
| zlob | test:test/test_match_basename_fuzz.zig | 9.77 s | 6.13 s | 1.59x |
| zlob | test:test/test_posix.zig | 1.02 s | 1.52 s | 0.67x |
| zlob | test:test/test_walk.zig | 877 ms | 756 ms | 1.16x |
| zls | lsp-codegen | 166 ms | 79 ms | 2.09x |
| zls | src test | 4.09 s | 1.38 s | 2.97x |
| zls | test | 1.56 s | 1.06 s | 1.47x |
| zqlite.zig | test | 1.05 s | 961 ms | 1.10x |
| zquic | test | 1.01 s | 204 ms | 4.96x |
| zquic | test:src/quic/connection_test_basic.zig | 3.08 s | 737 ms | 4.18x |
| zquic | test:src/quic/connection_test_corruption.zig | 1.60 s | 380 ms | 4.21x |
| zquic | test:src/quic/connection_test_crypto.zig | 3.63 s | 850 ms | 4.27x |
| zquic | test:src/quic/connection_test_frames.zig | 3.59 s | 990 ms | 3.63x |
| zquic | test:src/quic/connection_test_handshakecorruption.zig | 1.28 s | 304 ms | 4.22x |
| zquic | test:src/quic/connection_test_pmtud.zig | 2.48 s | 585 ms | 4.23x |
| zquic | test:src/quic/connection_test_resumption.zig | 1.45 s | 329 ms | 4.39x |
| zquic | test:src/quic/fuzz.zig | 1.15 s | 240 ms | 4.78x |
| zquic | test:src/quic/integration_test.zig | 4.99 s | 2.44 s | 2.04x |
| zquic | test:src/quic/tls.zig | 992 ms | 206 ms | 4.81x |
| zul | test | 7.26 s | 7.34 s | 0.99x |
| zwasm | test:src/zwasm.zig | 53.81 s | 24.84 s | 2.17x |

## Scoreboard

| Project | Target | Verdict | upstream run | bs run | cold-local zig / bs | cold-local zig / bs with donors | edit zig / bs | run zig / bs |
|---|---|---|---|---|---:|---:|---:|---:|
| zls | zls | ok | exit 0 | exit 0 | 2.81 s / 3.09 s (0.9x) | 2.81 s / 1.93 s (1.5x) | – / – | 22 ms / 6 ms (3.9x) |
| zls | lsp-codegen | ok | exit 0 | exit 0 | 997 ms / 606 ms (1.6x) | 997 ms / 757 ms (1.3x) | – / – | 166 ms / 79 ms (2.1x) |
| zls | test | ok | exit 0, 487 passed; 11 skipped; 0 failed. | exit 0, 487 passed; 11 skipped; 0 failed. | 2.62 s / 1.67 s (1.6x) | 2.62 s / 2.49 s (1.1x) | – / – | 1.56 s / 1.06 s (1.5x) |
| zls | src test | ok | exit 0, All 94 tests passed. | exit 0, All 94 tests passed. | 1.35 s / 768 ms (1.8x) | 1.35 s / 538 ms (2.5x) | – / – | 4.09 s / 1.38 s (3.0x) |
| ghostty | ghostty-vt-test | ok | exit 1, 3004 passed; 102 skipped; 1 failed. | exit 1, 3004 passed; 102 skipped; 1 failed. | 25.13 s / 14.99 s (1.7x) | 25.13 s / 12.90 s (1.9x) | – / – | 1402.28 s / 482.02 s (2.9x) |
| ghostty | props-unigen | ok | exit 0 | exit 0 | 1.03 s / 590 ms (1.7x) | 1.03 s / 782 ms (1.3x) | – / – | 471 ms / 298 ms (1.6x) |
| ghostty | symbols-unigen | ok | exit 0 | exit 0 | 1.00 s / 409 ms (2.4x) | 1.00 s / 132 ms (7.6x) | – / – | 120 ms / 57 ms (2.1x) |
| ghostty | uucode_generate | ok | exit 0 | exit 0 | 1.13 s / 519 ms (2.2x) | 1.13 s / 437 ms (2.6x) | – / – | 2.23 s / 907 ms (2.5x) |
| superhtml | superhtml | ok | exit 1 | exit 1 | 2.95 s / 1.68 s (1.8x) | 2.95 s / 1.60 s (1.8x) | – / – | 13 ms / 3 ms (3.9x) |
| superhtml | test | ok | exit 0, All 85 tests passed. | exit 0, All 85 tests passed. | 2.79 s / 1.40 s (2.0x) | 2.79 s / 1.27 s (2.2x) | – / – | 31 ms / 18 ms (1.8x) |
| superhtml | language-tag-parser | ok | not run | not run | 515 ms / 334 ms (1.5x) | 515 ms / 234 ms (2.2x) | – / – | – / – |
| ziggy | ziggy | ok | exit 1 | exit 1 | 1.35 s / 875 ms (1.5x) | 1.35 s / 773 ms (1.7x) | – / – | 13 ms / 4 ms (3.1x) |
| ziggy | test | ok | exit 0, All 99 tests passed. | exit 0, All 99 tests passed. | 947 ms / 644 ms (1.5x) | 947 ms / 419 ms (2.3x) | – / – | 33 ms / 21 ms (1.6x) |
| z2d | test | ok | exit 0, All 199 tests passed. | exit 0, All 199 tests passed. | 1.43 s / 923 ms (1.5x) | 1.43 s / 768 ms (1.9x) | – / – | 171 ms / 62 ms (2.7x) |
| zf | zf | ok | exit 0 | exit 0 | 1.25 s / 636 ms (2.0x) | 1.25 s / 438 ms (2.8x) | – / – | 7 ms / 2 ms (3.1x) |
| zf | test | ok | exit 0, All 10 tests passed. | exit 0, All 10 tests passed. | 523 ms / 318 ms (1.6x) | 523 ms / 137 ms (3.8x) | – / – | 5 ms / 2 ms (2.5x) |
| zig-clap | test | ok | exit 0, All 27 tests passed. | exit 0, All 27 tests passed. | 619 ms / 376 ms (1.6x) | 619 ms / 211 ms (2.9x) | – / – | 7 ms / 4 ms (2.0x) |
| zig-clap | simple | ok | exit 0 | exit 0 | 483 ms / 284 ms (1.7x) | 483 ms / 269 ms (1.8x) | – / – | 5 ms / 3 ms (1.8x) |
| zig-clap | subcommands | ok | exit 1 | exit 1 | 498 ms / 331 ms (1.5x) | 498 ms / 116 ms (4.3x) | – / – | 51 ms / 11 ms (4.8x) |
| zig-clap | usage | ok | exit 0 | exit 0 | 496 ms / 292 ms (1.7x) | 496 ms / 118 ms (4.2x) | – / – | 5 ms / 2 ms (2.3x) |
| anyzig | zig | ok | not run | not run | 3.08 s / 1.93 s (1.6x) | 3.08 s / 1.78 s (1.7x) | – / – | – / – |
| anyzig | test | ok | not run | not run | 692 ms / 449 ms (1.5x) | 692 ms / 187 ms (3.7x) | – / – | – / – |
| zine | translate-c | ok | exit 0 | exit 0 | 2.84 s / 2.02 s (1.4x) | 2.84 s / 1.82 s (1.6x) | – / – | 13 ms / 5 ms (2.7x) |
| zine | camera | ok | not run | not run | 515 ms / 278 ms (1.9x) | 515 ms / 150 ms (3.4x) | – / – | – / – |
| zig-protobuf | protoc-gen-zig | ok | not run | not run | 1.02 s / 624 ms (1.6x) | 1.02 s / 514 ms (2.0x) | – / – | – / – |
| zig-protobuf | tests | ok | exit 0, All 5 tests passed. | exit 0, All 5 tests passed. | 758 ms / 523 ms (1.4x) | 758 ms / 257 ms (3.0x) | – / – | 6 ms / 2 ms (2.5x) |
| zig-protobuf | protobuf | ok | exit 0, All 26 tests passed. | exit 0, All 26 tests passed. | 685 ms / 378 ms (1.8x) | 685 ms / 218 ms (3.1x) | – / – | 10 ms / 4 ms (2.8x) |
| zig-protobuf | json | ok | exit 0, All 153 tests passed. | exit 0, All 153 tests passed. | 1.13 s / 751 ms (1.5x) | 1.13 s / 509 ms (2.2x) | – / – | 28 ms / 17 ms (1.6x) |
| zig-protobuf | alltypes | ok | exit 0, All 10 tests passed. | exit 0, All 10 tests passed. | 1.31 s / 658 ms (2.0x) | 1.31 s / 474 ms (2.8x) | – / – | 9 ms / 3 ms (2.6x) |
| zig-protobuf | varints | ok | exit 0, All 36 tests passed. | exit 0, All 36 tests passed. | 631 ms / 518 ms (1.2x) | 631 ms / 232 ms (2.7x) | – / – | 11 ms / 5 ms (2.3x) |
| vulkan-zig | vulkan-zig-generator | ok | exit 0 | exit 0 | 787 ms / 530 ms (1.5x) | 787 ms / 375 ms (2.1x) | – / – | 942 ms / 346 ms (2.7x) |
| vulkan-zig | test | ok | exit 0, All 11 tests passed. | exit 0, All 11 tests passed. | 537 ms / 321 ms (1.7x) | 537 ms / 147 ms (3.7x) | – / – | 6 ms / 3 ms (2.0x) |
| tls.zig | test | ok | exit 0, 88 passed; 1 skipped; 0 failed. | exit 0, 88 passed; 1 skipped; 0 failed. | 2.31 s / 1.28 s (1.8x) | 2.31 s / 1.08 s (2.1x) | – / – | 2.84 s / 864 ms (3.3x) |
| tls.zig | http_get | ok | not run | not run | 1.72 s / 942 ms (1.8x) | 1.72 s / 974 ms (1.8x) | – / – | – / – |
| tls.zig | server | ok | not run | not run | 1.66 s / 930 ms (1.8x) | 1.66 s / 168 ms (9.9x) | – / – | – / – |
| zlinter | no_unused_unit_test_coverage | ok | exit 0, All 6 tests passed. | exit 0, All 6 tests passed. | 744 ms / 580 ms (1.3x) | 744 ms / 352 ms (2.1x) | – / – | 18 ms / 10 ms (1.8x) |
| zlinter | require_fmt_unit_test_coverage | ok | exit 0, All 7 tests passed. | exit 0, All 7 tests passed. | 858 ms / 467 ms (1.8x) | 858 ms / 216 ms (4.0x) | – / – | 10 ms / 5 ms (2.1x) |
| zlinter | build_lint_builtin | ok | not run | not run | 477 ms / 259 ms (1.8x) | 477 ms / 164 ms (2.9x) | – / – | – / – |
| zig-ecs | test | ok | exit 0, All 52 tests passed. | exit 0, All 52 tests passed. | 638 ms / 512 ms (1.2x) | 638 ms / 231 ms (2.8x) | – / – | 145 ms / 101 ms (1.4x) |
| zig-minisign | minizign | ok | exit 1 | exit 1 | 624 ms / 391 ms (1.6x) | 624 ms / 235 ms (2.7x) | – / – | 5 ms / 2 ms (2.4x) |
| zig-minisign | test | ok | exit 0, All 15 tests passed. | exit 0, All 15 tests passed. | 614 ms / 327 ms (1.9x) | 614 ms / 169 ms (3.6x) | – / – | 43 ms / 12 ms (3.5x) |
| zalgebra | test | ok | exit 0, All 70 tests passed. | exit 0, All 70 tests passed. | 617 ms / 430 ms (1.4x) | 617 ms / 164 ms (3.8x) | – / – | 6 ms / 2 ms (2.5x) |
| zig-args | test | ok | exit 0, All 15 tests passed. | exit 0, All 15 tests passed. | 624 ms / 387 ms (1.6x) | 624 ms / 328 ms (1.9x) | – / – | 7 ms / 6 ms (1.1x) |
| zig-args | demo | ok | exit 0 | exit 0 | 572 ms / 320 ms (1.8x) | 572 ms / 466 ms (1.2x) | – / – | 5 ms / 2 ms (2.1x) |
| zig-args | demo_verb | ok | exit 1 | exit 1 | 466 ms / 287 ms (1.6x) | 466 ms / 123 ms (3.8x) | – / – | 5 ms / 2 ms (2.0x) |
| zBench | runner | ok | exit 0, All 3 tests passed. | exit 0, All 3 tests passed. | 512 ms / 284 ms (1.8x) | 512 ms / 155 ms (3.3x) | – / – | 5 ms / 2 ms (2.2x) |
| zBench | statistics | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 515 ms / 277 ms (1.9x) | 515 ms / 134 ms (3.9x) | – / – | 5 ms / 3 ms (1.9x) |
| zBench | platform | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 504 ms / 268 ms (1.9x) | 504 ms / 117 ms (4.3x) | – / – | 5 ms / 2 ms (2.3x) |
| zBench | partial | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 469 ms / 273 ms (1.7x) | 469 ms / 128 ms (3.7x) | – / – | 6 ms / 2 ms (2.8x) |
| linuxwave | linuxwave | ok | exit 0 | exit 0 | 551 ms / 302 ms (1.8x) | 551 ms / 175 ms (3.2x) | – / – | 152 ms / 117 ms (1.3x) |
| linuxwave | wav-tests | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 489 ms / 303 ms (1.6x) | 489 ms / 119 ms (4.1x) | – / – | 5 ms / 2 ms (2.3x) |
| linuxwave | gen-tests | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 488 ms / 273 ms (1.8x) | 488 ms / 128 ms (3.8x) | – / – | 8 ms / 4 ms (1.9x) |
| linuxwave | file-tests | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 482 ms / 295 ms (1.6x) | 482 ms / 120 ms (4.0x) | – / – | 5 ms / 2 ms (2.3x) |
| linuxwave | main-tests | ok | exit 0, All 4 tests passed. | exit 0, All 4 tests passed. | 545 ms / 338 ms (1.6x) | 545 ms / 171 ms (3.2x) | – / – | 139 ms / 135 ms (1.0x) |
| zli | test | ok | exit 0, All 32 tests passed. | exit 0, All 32 tests passed. | 549 ms / 343 ms (1.6x) | 549 ms / 166 ms (3.3x) | – / – | 25 ms / 14 ms (1.7x) |
| zig-compiler | translate-c | ok | exit 0 | exit 0 | 2.88 s / 1.77 s (1.6x) | 2.88 s / 1.57 s (1.8x) | – / – | 4.01 s / 2.39 s (1.7x) |
| zig-compiler | resinator | ok | exit 0 | exit 0 | 2.73 s / 1.42 s (1.9x) | 2.73 s / 787 ms (3.5x) | – / – | 29 ms / 101 ms (0.3x) |
| zig-compiler | resinator-test | ok | exit 0, 73 passed; 1 skipped; 0 failed. | exit 0, 73 passed; 1 skipped; 0 failed. | 1.29 s / 692 ms (1.9x) | 1.29 s / 576 ms (2.2x) | – / – | 21 ms / 23 ms (0.9x) |
| zig-compiler | aro-test | ok | exit 0, All 42 tests passed. | exit 0, All 42 tests passed. | 2.10 s / 1.27 s (1.7x) | 2.10 s / 1.18 s (1.8x) | – / – | 230 ms / 114 ms (2.0x) |
| zig-compiler | objcopy | ok | exit 0 | exit 0 | 596 ms / 322 ms (1.9x) | 596 ms / 226 ms (2.6x) | – / – | 9 ms / 13 ms (0.7x) |
| zig-compiler | objdump | ok | exit 0 | exit 0 | 708 ms / 417 ms (1.7x) | 708 ms / 279 ms (2.5x) | – / – | 7 ms / 3 ms (2.7x) |
| zig-compiler | reduce | ok | exit 0 | exit 0 | 1.16 s / 746 ms (1.6x) | 1.16 s / 603 ms (1.9x) | – / – | 12 ms / 3 ms (3.7x) |
| zig-compiler | std-docs | ok | exit 0 | exit 0 | 1.11 s / 704 ms (1.6x) | 1.11 s / 463 ms (2.4x) | – / – | 6 ms / 8 ms (0.8x) |
| zigimg | zigimgtest | ok | exit 0, 347 passed; 170 skipped; 0 failed. | exit 0, 347 passed; 170 skipped; 0 failed. | 1.45 s / 1.05 s (1.4x) | 1.45 s / 747 ms (1.9x) | – / – | 1.75 s / 492 ms (3.6x) |
| zeit | test | ok | exit 0, All 33 tests passed. | exit 0, All 33 tests passed. | 720 ms / 428 ms (1.7x) | 720 ms / 395 ms (1.8x) | – / – | 235 ms / 265 ms (0.9x) |
| zbor | test | ok | exit 1, 97 passed; 0 skipped; 1 failed. | exit 1, 97 passed; 0 skipped; 1 failed. | 1.29 s / 900 ms (1.4x) | 1.29 s / 473 ms (2.7x) | – / – | 649 ms / 186 ms (3.5x) |
| libvaxis | test | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 1.27 s / 550 ms (2.3x) | 1.27 s / 411 ms (3.1x) | – / – | 5 ms / 2 ms (2.5x) |
| libvaxis | example-text_input | ok | not run | not run | 1.24 s / 420 ms (3.0x) | 1.24 s / 395 ms (3.1x) | – / – | – / – |
| libvaxis | example-c-tty | ok | exit 0 | exit 0 | 188 ms / 391 ms (0.5x) | 188 ms / 300 ms (0.6x) | – / – | 267 ms / 266 ms (1.0x) |
| cache.zig | test | ok | exit 0, 20 of 20 tests passed | exit 0, 20 of 20 tests passed | 621 ms / 378 ms (1.6x) | 621 ms / 379 ms (1.6x) | – / – | 9 ms / 5 ms (1.8x) |
| zul | test | ok | exit 0, 86 of 86 tests passed | exit 0, 86 of 86 tests passed | 2.40 s / 1.28 s (1.9x) | 2.40 s / 1.18 s (2.0x) | – / – | 7.26 s / 7.34 s (1.0x) |
| metrics.zig | test | ok | exit 0, 41 of 41 tests passed | exit 0, 41 of 41 tests passed | 748 ms / 461 ms (1.6x) | 748 ms / 362 ms (2.1x) | – / – | 88 ms / 67 ms (1.3x) |
| zig-hpke | test | ok | exit 1, 30 passed; 0 skipped; 1 failed. | exit 1, 30 passed; 0 skipped; 1 failed. | 1.51 s / 860 ms (1.8x) | 1.51 s / 697 ms (2.2x) | – / – | 1.24 s / 244 ms (5.1x) |
| libxev | xev-test | ok | exit 0, 142 passed; 4 skipped; 0 failed. | exit 0, 142 passed; 4 skipped; 0 failed. | 708 ms / 466 ms (1.5x) | 708 ms / 388 ms (1.8x) | – / – | 266 ms / 165 ms (1.6x) |
| libxev | xev | ok | not run | not run | 537 ms / 277 ms (1.9x) | 537 ms / 211 ms (2.6x) | – / – | – / – |
| zio | test | ok | exit 0, 817 of 817 tests passed | exit 0, 817 of 817 tests passed | 2.38 s / 1.36 s (1.8x) | 2.38 s / 1.31 s (1.8x) | – / – | 11.68 s / 12.81 s (0.9x) |
| zio | hello-world | ok | exit 0 | exit 0 | 828 ms / 585 ms (1.4x) | 828 ms / 477 ms (1.7x) | – / – | 14 ms / 7 ms (1.9x) |
| zio | coro-demo | upstream run fails (exit signal 6) | exit signal 6 | exit 0 | 568 ms / 285 ms (2.0x) | 568 ms / 298 ms (1.9x) | – / – | 2 ms / 2 ms (1.2x) |
| zio | mutex-demo | ok | exit 0 | exit 0 | 882 ms / 526 ms (1.7x) | 882 ms / 430 ms (2.0x) | – / – | 16 ms / 9 ms (1.8x) |
| zio | ev-demo | ok | exit 0 | exit 0 | 686 ms / 358 ms (1.9x) | 686 ms / 322 ms (2.1x) | – / – | 5.00 s / 5.00 s (1.0x) |
| zio | producer-consumer | ok | exit 0 | exit 0 | 862 ms / 524 ms (1.6x) | 862 ms / 375 ms (2.3x) | – / – | 766 ms / 762 ms (1.0x) |
| zedis | test-unit | ok | exit 0, All 384 tests passed. | exit 0, All 384 tests passed. | 1.14 s / 792 ms (1.4x) | 1.14 s / 787 ms (1.4x) | – / – | 3.42 s / 3.12 s (1.1x) |
| zedis | zedis | ok | not run | not run | 1.13 s / 643 ms (1.8x) | 1.13 s / 674 ms (1.7x) | – / – | – / – |
| tokamak | test | bs: run differs (exit signal 6, no summary, died in dom.document.test_0 vs exit 1, 88 passed; 0 skipped; 1 failed.) | exit 1, 88 passed; 0 skipped; 1 failed. | exit signal 6, no summary, died in dom.document.test_0 | 2.75 s / 1.55 s (1.8x) | 2.75 s / 1.43 s (1.9x) | – / – | 2.31 s / 1.57 s (1.5x) |
| zig-sqlite | test | ok | exit 0, All 10 tests passed. | exit 0, All 10 tests passed. | 7.62 s / 7.32 s (1.0x) | 7.62 s / 7.59 s (1.0x) | – / – | 24 ms / 17 ms (1.4x) |
| raylib-zig | raylib | ok | not run | not run | 12.47 s / 5.10 s (2.4x) | 12.47 s / 5.26 s (2.4x) | – / – | – / – |
| raylib-zig | test | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 809 ms / 606 ms (1.3x) | 809 ms / 271 ms (3.0x) | – / – | 10 ms / 17 ms (0.6x) |
| raylib-zig | basic_window | ok | not run | not run | 628 ms / 354 ms (1.8x) | 628 ms / 352 ms (1.8x) | – / – | – / – |
| raylib-zig | bunnymark | ok | not run | not run | 569 ms / 476 ms (1.2x) | 569 ms / 220 ms (2.6x) | – / – | – / – |
| raylib-zig | models_heightmap | ok | not run | not run | 588 ms / 348 ms (1.7x) | 588 ms / 197 ms (3.0x) | – / – | – / – |
| raylib-zig | gui_message_box | ok | not run | not run | 572 ms / 347 ms (1.6x) | 572 ms / 217 ms (2.6x) | – / – | – / – |
| raylib-zig | raymarching | ok | not run | not run | 624 ms / 352 ms (1.8x) | 624 ms / 208 ms (3.0x) | – / – | – / – |
| json-zig | test | ok | exit 0, All 348 tests passed. | exit 0, All 348 tests passed. | 1.79 s / 1.16 s (1.5x) | 1.79 s / 1.01 s (1.8x) | – / – | 1.57 s / 852 ms (1.8x) |
| json-zig | json-fuzz | ok | not run | not run | 648 ms / 465 ms (1.4x) | 648 ms / 284 ms (2.3x) | – / – | – / – |
| ziglua | lua | ok | not run | not run | 1.27 s / 495 ms (2.6x) | 1.27 s / 462 ms (2.7x) | – / – | – / – |
| ziglua | test | ok | exit 0, All 99 tests passed. | exit 0, All 99 tests passed. | 738 ms / 527 ms (1.4x) | 738 ms / 281 ms (2.6x) | – / – | 164 ms / 81 ms (2.0x) |
| zqlite.zig | test | ok | exit 0, 20 of 20 tests passed | exit 0, 20 of 20 tests passed | 699 ms / 618 ms (1.1x) | 699 ms / 431 ms (1.6x) | – / – | 1.05 s / 961 ms (1.1x) |
| http.zig | test | ok | exit 0, 131 of 131 tests passed | exit 0, 131 of 131 tests passed | 3.01 s / 1.14 s (2.6x) | 3.01 s / 949 ms (3.2x) | – / – | 30.56 s / 29.16 s (1.0x) |
| http.zig | example_1 | ok | not run | not run | 680 ms / 459 ms (1.5x) | 680 ms / 414 ms (1.6x) | – / – | – / – |
| zigmod | zigmod | ok | not run | not run | 3.59 s / 2.54 s (1.4x) | 3.59 s / 1.34 s (2.7x) | – / – | – / – |
| buzz | test | upstream fails to compile | src/vm.zig:904:9: error: unable to perform tail call: compiler backend 'stage2_x86_64' doe | src/vm.zig:904:9: error[unsupported]: unable to perform tail call: compiler backend 'stage | 3.31 s / 2.33 s (1.4x) | 3.31 s / – | – / – | – / – |
| buzz | buzz_behavior | upstream fails to compile | src/vm.zig:904:9: error: unable to perform tail call: compiler backend 'stage2_x86_64' doe | src/vm.zig:904:9: error[unsupported]: unable to perform tail call: compiler backend 'stage | 3.38 s / 1.84 s (1.8x) | 3.38 s / – | – / – | – / – |
| buzz | buzz_lsp | upstream fails to compile | src/vm.zig:904:9: error: unable to perform tail call: compiler backend 'stage2_x86_64' doe | src/vm.zig:904:9: error[unsupported]: unable to perform tail call: compiler backend 'stage | 3.92 s / 1.95 s (2.0x) | 3.92 s / – | – / – | – / – |
| supermd | test | ok | exit 0, All 3 tests passed. | exit 0, All 3 tests passed. | 2.30 s / 1.47 s (1.6x) | 2.30 s / 1.03 s (2.2x) | – / – | 12 ms / 6 ms (2.2x) |
| supermd | docgen | ok | not run | not run | 524 ms / 320 ms (1.6x) | 524 ms / 328 ms (1.6x) | – / – | – / – |
| zflecs | zflecs-tests | ok | exit 0, All 12 tests passed. | exit 0, All 12 tests passed. | 687 ms / 464 ms (1.5x) | 687 ms / 225 ms (3.1x) | – / – | 1.32 s / 748 ms (1.8x) |
| zmath | zmath-tests | upstream fails to compile | src/root.zig:885:5: error: genSetReg called with a value larger than dst_reg | exit 0, All 78 tests passed. | 546 ms / 465 ms (1.2x) | 546 ms / 186 ms (2.9x) | – / – | – / 3 ms |
| zmath | zmath-benchmarks | upstream fails to compile | src/root.zig:885:5: error: genSetReg called with a value larger than dst_reg | not run | 491 ms / 308 ms (1.6x) | 491 ms / 156 ms (3.1x) | – / – | – / – |
| zig-msgpack | test | ok | exit 0, All 171 tests passed. | exit 0, All 171 tests passed. | 1.42 s / 547 ms (2.6x) | 1.42 s / 416 ms (3.4x) | – / – | 812 ms / 501 ms (1.6x) |
| zig-toml | test | ok | exit 0, All 80 tests passed. | exit 0, All 80 tests passed. | 699 ms / 703 ms (1.0x) | 699 ms / 525 ms (1.3x) | – / – | 14 ms / 8 ms (1.7x) |
| zig-toml | example1 | ok | not run | not run | 494 ms / 286 ms (1.7x) | 494 ms / 166 ms (3.0x) | – / – | – / – |
| zig-regex | test | ok | exit 0, All 13 tests passed. | exit 0, All 13 tests passed. | 887 ms / 503 ms (1.8x) | 887 ms / 328 ms (2.7x) | – / – | 61 ms / 35 ms (1.8x) |
| zig-regex | regex | ok | not run | not run | 877 ms / 461 ms (1.9x) | 877 ms / 389 ms (2.3x) | – / – | – / – |
| zig-libs | xml | ok | exit 0, 86 passed; 1 skipped; 0 failed. | exit 0, 86 passed; 1 skipped; 0 failed. | 732 ms / 571 ms (1.3x) | 732 ms / 297 ms (2.5x) | – / – | 955 ms / 319 ms (3.0x) |
| zig-libs | yaml | ok | exit 0, 77 passed; 2 skipped; 0 failed. | exit 0, 77 passed; 2 skipped; 0 failed. | 818 ms / 667 ms (1.2x) | 818 ms / 331 ms (2.5x) | – / – | 3.31 s / 1.30 s (2.5x) |
| zig-libs | regex | upstream run fails (exit signal 6, no summary, died in root.test.deep nesting compiles (or is refused) on a 512 KiB thread stack) | exit signal 6, no summary, died in root.test.deep nesting compiles (or is refused) on a 51 | exit 0, 54 passed; 2 skipped; 0 failed. | 28.50 s / 2.63 s (10.8x) | 28.50 s / 2.17 s (13.1x) | – / – | 28.82 s / 13.62 s (2.1x) |
| zig-libs | jinja | ok | exit 0, 84 passed; 7 skipped; 0 failed. | exit 0, 84 passed; 7 skipped; 0 failed. | 1.03 s / 660 ms (1.6x) | 1.03 s / 505 ms (2.0x) | – / – | 4.56 s / 2.63 s (1.7x) |
| zig-libs | protobuf | ok | exit 0, 98 passed; 1 skipped; 0 failed. | exit 0, 98 passed; 1 skipped; 0 failed. | 1.10 s / 678 ms (1.6x) | 1.10 s / 515 ms (2.1x) | – / – | 571 ms / 243 ms (2.4x) |
| zig-libs | json5 | ok | exit 0, 99 passed; 1 skipped; 0 failed. | exit 0, 99 passed; 1 skipped; 0 failed. | 877 ms / 644 ms (1.4x) | 877 ms / 483 ms (1.8x) | – / – | 1.63 s / 973 ms (1.7x) |
| zig-libs | raft | ok | exit 0, 88 passed; 6 skipped; 0 failed. | exit 0, 88 passed; 6 skipped; 0 failed. | 775 ms / 538 ms (1.4x) | 775 ms / 320 ms (2.4x) | – / – | 57.81 s / 31.97 s (1.8x) |
| zig-libs | cbor | ok | exit 0, 91 passed; 1 skipped; 0 failed. | exit 0, 91 passed; 1 skipped; 0 failed. | 938 ms / 501 ms (1.9x) | 938 ms / 287 ms (3.3x) | – / – | 120 ms / 66 ms (1.8x) |
| zig-libs | ini | ok | exit 0, 85 passed; 2 skipped; 0 failed. | exit 0, 85 passed; 2 skipped; 0 failed. | 861 ms / 559 ms (1.5x) | 861 ms / 339 ms (2.5x) | – / – | 6.69 s / 3.23 s (2.1x) |
| zig-libs | tar | ok | exit 0, 153 passed; 3 skipped; 0 failed. | exit 0, 153 passed; 3 skipped; 0 failed. | 875 ms / 585 ms (1.5x) | 875 ms / 316 ms (2.8x) | – / – | 2.88 s / 1.45 s (2.0x) |
| zig-libs | trie | ok | exit 0, All 82 tests passed. | exit 0, All 82 tests passed. | 718 ms / 552 ms (1.3x) | 718 ms / 258 ms (2.8x) | – / – | 20.59 s / 9.08 s (2.3x) |
| zig-libs | qr | ok | exit 0, 45 passed; 4 skipped; 0 failed. | exit 0, 45 passed; 4 skipped; 0 failed. | 788 ms / 566 ms (1.4x) | 788 ms / 277 ms (2.8x) | – / – | 12.43 s / 4.29 s (2.9x) |
| zwasm | zwasm | ok | exit 0 | exit 0 | 4.20 s / 2.66 s (1.6x) | 4.20 s / 2.15 s (2.0x) | – / – | 25 ms / 8 ms (3.0x) |
| zwasm | test:src/zwasm.zig | ok | exit 0, 3464 passed; 12 skipped; 0 failed. | exit 0, 3464 passed; 12 skipped; 0 failed. | 6.83 s / 4.04 s (1.7x) | 6.83 s / 4.00 s (1.7x) | – / – | 53.81 s / 24.84 s (2.2x) |
| zwasm | test:src/cli/main.zig | ok | exit 0, All 3 tests passed. | exit 0, All 3 tests passed. | 2.58 s / 1.42 s (1.8x) | 2.58 s / 1.28 s (2.0x) | – / – | 27 ms / 8 ms (3.6x) |
| zwasm | test | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 558 ms / 356 ms (1.6x) | 558 ms / 558 ms (1.0x) | – / – | 5 ms / 2 ms (2.2x) |
| astroz | astroz | ok | not run | not run | 261 ms / 630 ms (0.4x) | 261 ms / 242 ms (1.1x) | – / – | – / – |
| astroz | test | ok | exit 0, All 139 tests passed. | exit 0, All 139 tests passed. | 2.12 s / 1.30 s (1.6x) | 2.12 s / 1.01 s (2.1x) | – / – | 5.05 s / 2.79 s (1.8x) |
| zigcli | test | ok | exit 0, All 68 tests passed. | exit 0, All 68 tests passed. | 742 ms / 418 ms (1.8x) | 742 ms / 256 ms (2.9x) | – / – | 14 ms / 8 ms (1.7x) |
| zigcli | loc | ok | exit 0 | exit 0 | 592 ms / 346 ms (1.7x) | 592 ms / 257 ms (2.3x) | – / – | 176 ms / 58 ms (3.0x) |
| zigcli | hexdump | ok | exit 0 | exit 0 | 546 ms / 324 ms (1.7x) | 546 ms / 214 ms (2.6x) | – / – | 37 ms / 18 ms (2.0x) |
| zigcli | pretty-csv | ok | not run | not run | 586 ms / 334 ms (1.8x) | 586 ms / 159 ms (3.7x) | – / – | – / – |
| zigcli | tree | ok | not run | not run | 547 ms / 324 ms (1.7x) | 547 ms / 150 ms (3.6x) | – / – | – / – |
| zigcli | cowsay | ok | not run | not run | 554 ms / 298 ms (1.9x) | 554 ms / 133 ms (4.2x) | – / – | – / – |
| zigcli | zfetch | ok | not run | not run | 605 ms / 378 ms (1.6x) | 605 ms / 250 ms (2.4x) | – / – | – / – |
| zig-interface | test | ok | exit 0, All 5 tests passed. | exit 0, All 5 tests passed. | 538 ms / 365 ms (1.5x) | 538 ms / 320 ms (1.7x) | – / – | 6 ms / 4 ms (1.7x) |
| nanoui | test | ok | exit 0, 252 passed; 10 skipped; 0 failed. | exit 0, 252 passed; 10 skipped; 0 failed. | 3.28 s / 1.89 s (1.7x) | 3.28 s / 1.64 s (2.0x) | – / – | 14.30 s / 13.95 s (1.0x) |
| nanoui | nui | ok | not run | not run | 581 ms / 311 ms (1.9x) | 581 ms / 188 ms (3.1x) | – / – | – / – |
| nanoui | hello | ok | not run | not run | 1.16 s / 654 ms (1.8x) | 1.16 s / 754 ms (1.5x) | – / – | – / – |
| nanoui | todo | ok | not run | not run | 1.17 s / 678 ms (1.7x) | 1.17 s / 297 ms (3.9x) | – / – | – / – |
| nanoui | browser | ok | not run | not run | 1.12 s / 789 ms (1.4x) | 1.12 s / 286 ms (3.9x) | – / – | – / – |
| dhi | test | ok | exit 0, All 16 tests passed. | exit 0, All 16 tests passed. | 512 ms / 298 ms (1.7x) | 512 ms / 140 ms (3.7x) | – / – | 6 ms / 3 ms (2.1x) |
| dhi | dhi | ok | not run | not run | 452 ms / 233 ms (1.9x) | 452 ms / 232 ms (1.9x) | – / – | – / – |
| dhi | dhi-zig | ok | not run | not run | 42 ms / 18 ms (2.4x) | 42 ms / 7 ms (5.9x) | – / – | – / – |
| merjs | test | ok | exit 0, All 5 tests passed. | exit 0, All 5 tests passed. | 494 ms / 268 ms (1.8x) | 494 ms / 130 ms (3.8x) | – / – | 6 ms / 3 ms (1.9x) |
| merjs | merjs | ok | not run | not run | 2.64 s / 1.54 s (1.7x) | 2.64 s / 1.39 s (1.9x) | – / – | – / – |
| merjs | codegen | ok | not run | not run | 478 ms / 300 ms (1.6x) | 478 ms / 303 ms (1.6x) | – / – | – / – |
| ziex | test | ok | exit 1, no summary | exit 1, no summary | 13.43 s / 7.36 s (1.8x) | 13.43 s / 7.36 s (1.8x) | – / – | 6.43 s / 6.09 s (1.1x) |
| ziex | zx | ok | exit 0 | exit 0 | 5.46 s / 3.54 s (1.5x) | 5.46 s / 2.95 s (1.9x) | – / – | 36 ms / 9 ms (3.9x) |
| ziex | zls_gen | ok | not run | not run | 689 ms / 417 ms (1.7x) | 689 ms / 423 ms (1.6x) | – / – | – / – |
| fizzy | fizzy | ok | not run | not run | 17.24 s / 9.78 s (1.8x) | 17.24 s / 9.11 s (1.9x) | – / – | – / – |
| fizzy | fake-fizzy | ok | not run | not run | 512 ms / 293 ms (1.7x) | 512 ms / 354 ms (1.4x) | – / – | – / – |
| fizzy | text | ok | not run | not run | 5.29 s / 2.28 s (2.3x) | 5.29 s / 1.85 s (2.9x) | – / – | – / – |
| fizzy | fizzy-textcore-tests | ok | exit 0, All 94 tests passed. | exit 0, All 94 tests passed. | 692 ms / 417 ms (1.7x) | 692 ms / 398 ms (1.7x) | – / – | 344 ms / 230 ms (1.5x) |
| fizzy | fizzy-fuzzy-tests | ok | exit 0, All 12 tests passed. | exit 0, All 12 tests passed. | 587 ms / 429 ms (1.4x) | 587 ms / 174 ms (3.4x) | – / – | 8 ms / 2 ms (3.5x) |
| fizzy | fizzy-diff-tests | ok | exit 0, All 21 tests passed. | exit 0, All 21 tests passed. | 550 ms / 450 ms (1.2x) | 550 ms / 178 ms (3.1x) | – / – | 92 ms / 58 ms (1.6x) |
| fizzy | fizzy-lsp-protocol-tests | ok | exit 0, All 4 tests passed. | exit 0, All 4 tests passed. | 612 ms / 405 ms (1.5x) | 612 ms / 206 ms (3.0x) | – / – | 9 ms / 3 ms (2.7x) |
| fizzy | fizzy-keymap-tests | ok | exit 0, All 31 tests passed. | exit 0, All 31 tests passed. | 809 ms / 501 ms (1.6x) | 809 ms / 348 ms (2.3x) | – / – | 15 ms / 8 ms (2.0x) |
| fizzy | fizzy-glass-tests | ok | exit 0, All 30 tests passed. | exit 0, All 30 tests passed. | 3.59 s / 1.55 s (2.3x) | 3.59 s / 1.65 s (2.2x) | – / – | 23 ms / 13 ms (1.7x) |
| fizzy | backend-gpu-tests | ok | exit 0, All 7 tests passed. | exit 0, All 7 tests passed. | 532 ms / 339 ms (1.6x) | 532 ms / 138 ms (3.9x) | – / – | 5 ms / 2 ms (2.3x) |
| fizzy | fizzy-control-json-tests | ok | exit 0, All 3 tests passed. | exit 0, All 3 tests passed. | 788 ms / 452 ms (1.7x) | 788 ms / 338 ms (2.3x) | – / – | 9 ms / 4 ms (2.5x) |
| fizzy | fizzy-md-supermd-tests | ok | exit 0, All 8 tests passed. | exit 0, All 8 tests passed. | 570 ms / 353 ms (1.6x) | 570 ms / 169 ms (3.4x) | – / – | 7 ms / 3 ms (2.2x) |
| fizzy | fizzy-remote-tests | ok | exit 0, All 36 tests passed. | exit 0, All 36 tests passed. | 794 ms / 459 ms (1.7x) | 794 ms / 468 ms (1.7x) | – / – | 34.49 s / 34.44 s (1.0x) |
| fizzy | fizzy-tape-tests | ok | exit 0, All 80 tests passed. | exit 0, All 80 tests passed. | 1.18 s / 740 ms (1.6x) | 1.18 s / 474 ms (2.5x) | – / – | 991 ms / 542 ms (1.8x) |
| fizzy | fizzy-plugin-loader-tests | ok | exit 0, 2 passed; 1 skipped; 0 failed. | exit 0, 2 passed; 1 skipped; 0 failed. | 4.12 s / 1.28 s (3.2x) | 4.12 s / 1.24 s (3.3x) | – / – | 11 ms / 5 ms (2.5x) |
| fizzy | fizzy-liquid-tests | ok | exit 0, All 5 tests passed. | exit 0, All 5 tests passed. | 526 ms / 293 ms (1.8x) | 526 ms / 120 ms (4.4x) | – / – | 7 ms / 3 ms (2.6x) |
| revo | revo | ok | exit 0 | exit 0 | 4.71 s / 2.39 s (2.0x) | 4.71 s / 2.27 s (2.1x) | – / – | 65 ms / 55 ms (1.2x) |
| revo | test | ok | exit 0, All 0 tests passed. | exit 0, All 0 tests passed. | 515 ms / 290 ms (1.8x) | 515 ms / 131 ms (3.9x) | – / – | 5 ms / 2 ms (2.3x) |
| revo | test:src/vm/root.zig | bs: run differs (exit signal 6, no summary, died in tests.test.vm channel buffered send then recv vs exit signal 6, no summary, died in tests.test.vm gc keeps rooted closures and captured tables alive) | exit signal 6, no summary, died in tests.test.vm gc keeps rooted closures and captured tab | exit signal 6, no summary, died in tests.test.vm channel buffered send then recv | 3.38 s / 2.11 s (1.6x) | 3.38 s / 1.82 s (1.9x) | – / – | 2.22 s / 881 ms (2.5x) |
| revo | test:src/lang/tests/root.zig | ok | exit 0, 336 passed; 3 skipped; 0 failed. | exit 0, 336 passed; 3 skipped; 0 failed. | 3.43 s / 1.72 s (2.0x) | 3.43 s / 808 ms (4.2x) | – / – | 7.22 s / 4.10 s (1.8x) |
| revo | test:src/root.zig | ok | exit 0, All 310 tests passed. | exit 0, All 310 tests passed. | 3.55 s / 1.91 s (1.9x) | 3.55 s / 1.03 s (3.4x) | – / – | 3.91 s / 2.52 s (1.5x) |
| revo | test:src/cli.zig | ok | exit 0, All 0 tests passed. | exit 0, All 0 tests passed. | 1.05 s / 667 ms (1.6x) | 1.05 s / 659 ms (1.6x) | – / – | 6 ms / 3 ms (1.8x) |
| revo | test:src/capi/root.zig | ok | exit 0, All 0 tests passed. | exit 0, All 0 tests passed. | 592 ms / 313 ms (1.9x) | 592 ms / 271 ms (2.2x) | – / – | 7 ms / 3 ms (2.2x) |
| zig-extras | test | ok | exit 0, All 1228 tests passed. | exit 0, All 1228 tests passed. | 1.02 s / 598 ms (1.7x) | 1.02 s / 482 ms (2.1x) | – / – | 24 ms / 12 ms (1.9x) |
| StaticHttpFileServer | test | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 2.00 s / 1.01 s (2.0x) | 2.00 s / 928 ms (2.2x) | – / – | 9 ms / 5 ms (1.6x) |
| flash | flash | ok | not run | not run | 642 ms / 434 ms (1.5x) | 642 ms / 239 ms (2.7x) | – / – | – / – |
| flash | test | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 506 ms / 275 ms (1.8x) | 506 ms / 112 ms (4.5x) | – / – | 5 ms / 2 ms (2.3x) |
| flash | test:src/root.zig | ok | exit 0, 237 passed; 2 skipped; 0 failed. | exit 0, 237 passed; 2 skipped; 0 failed. | 1.06 s / 651 ms (1.6x) | 1.06 s / 477 ms (2.2x) | – / – | 42 ms / 39 ms (1.1x) |
| flow | flow | ok | not run | not run | 12.81 s / 5.53 s (2.3x) | 12.81 s / 5.07 s (2.5x) | – / – | – / – |
| flow | test-terminal_icons | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 495 ms / 309 ms (1.6x) | 495 ms / 144 ms (3.4x) | – / – | 5 ms / 2 ms (2.3x) |
| flow | test-syntax_validator | ok | exit 0, All 5 tests passed. | exit 0, All 5 tests passed. | 624 ms / 662 ms (0.9x) | 624 ms / 695 ms (0.9x) | – / – | 14 ms / 14 ms (1.0x) |
| flow | test-stdio_capture | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 507 ms / 389 ms (1.3x) | 507 ms / 416 ms (1.2x) | – / – | 6 ms / 3 ms (1.7x) |
| flow | test-dbus | ok | exit 0, 9 passed; 2 skipped; 0 failed. | exit 0, 9 passed; 2 skipped; 0 failed. | 1.06 s / 493 ms (2.1x) | 1.06 s / 389 ms (2.7x) | – / – | 16 ms / 8 ms (2.1x) |
| flow | test-gitignore | ok | exit 0, All 55 tests passed. | exit 0, All 55 tests passed. | 541 ms / 317 ms (1.7x) | 541 ms / 155 ms (3.5x) | – / – | 26 ms / 18 ms (1.5x) |
| flow | test-terminal_wt_profiles | ok | exit 0, All 10 tests passed. | exit 0, All 10 tests passed. | 545 ms / 311 ms (1.8x) | 545 ms / 180 ms (3.0x) | – / – | 10 ms / 5 ms (2.3x) |
| flow | test-rc | ok | exit 0, All 8 tests passed. | exit 0, All 8 tests passed. | 1.08 s / 541 ms (2.0x) | 1.08 s / 349 ms (3.1x) | – / – | 27 ms / 17 ms (1.5x) |
| flow | test-terminal_key | ok | exit 0, All 13 tests passed. | exit 0, All 13 tests passed. | 594 ms / 295 ms (2.0x) | 594 ms / 141 ms (4.2x) | – / – | 5 ms / 2 ms (2.3x) |
| flow | test-flow | ok | exit 0, All 284 tests passed. | exit 0, All 284 tests passed. | 1.63 s / 948 ms (1.7x) | 1.63 s / 910 ms (1.8x) | – / – | 7.36 s / 4.65 s (1.6x) |
| flow | test-richdoc | ok | exit 0, All 63 tests passed. | exit 0, All 63 tests passed. | 6.27 s / 1.13 s (5.6x) | 6.27 s / 945 ms (6.6x) | – / – | 96 ms / 62 ms (1.5x) |
| flow | test-match | ok | exit 0, All 19 tests passed. | exit 0, All 19 tests passed. | 569 ms / 312 ms (1.8x) | 569 ms / 134 ms (4.2x) | – / – | 8 ms / 2 ms (3.3x) |
| flow | test-FileStore | ok | exit 0, All 5 tests passed. | exit 0, All 5 tests passed. | 1.21 s / 731 ms (1.7x) | 1.21 s / 456 ms (2.7x) | – / – | 1.63 s / 1.62 s (1.0x) |
| flow | test-fetch | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 559 ms / 295 ms (1.9x) | 559 ms / 354 ms (1.6x) | – / – | 7 ms / 2 ms (3.1x) |
| flow | test-chord_key | ok | exit 0, All 4 tests passed. | exit 0, All 4 tests passed. | 537 ms / 314 ms (1.7x) | 537 ms / 148 ms (3.6x) | – / – | 5 ms / 2 ms (2.1x) |
| flow | test-command_line | ok | exit 0, All 13 tests passed. | exit 0, All 13 tests passed. | 551 ms / 290 ms (1.9x) | 551 ms / 146 ms (3.8x) | – / – | 7 ms / 5 ms (1.4x) |
| flow | test-glyph_constraint | ok | exit 0, All 2 tests passed. | exit 0, All 2 tests passed. | 633 ms / 300 ms (2.1x) | 633 ms / 138 ms (4.6x) | – / – | 6 ms / 3 ms (2.1x) |
| flow | test-edit_set | ok | exit 0, All 32 tests passed. | exit 0, All 32 tests passed. | 624 ms / 434 ms (1.4x) | 624 ms / 229 ms (2.7x) | – / – | 132 ms / 58 ms (2.3x) |
| flow | test-double_mapped_ring_buffer | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 534 ms / 345 ms (1.5x) | 534 ms / 416 ms (1.3x) | – / – | 5 ms / 2 ms (2.3x) |
| flow | test-mouse_event | ok | exit 0, All 8 tests passed. | exit 0, All 8 tests passed. | 572 ms / 293 ms (2.0x) | 572 ms / 138 ms (4.2x) | – / – | 5 ms / 2 ms (2.2x) |
| flow | test-terminal_line_store | ok | exit 0, All 8 tests passed. | exit 0, All 8 tests passed. | 524 ms / 305 ms (1.7x) | 524 ms / 151 ms (3.5x) | – / – | 44 ms / 25 ms (1.7x) |
| flow | test-terminal_screen | ok | exit 0, All 25 tests passed. | exit 0, All 25 tests passed. | 637 ms / 331 ms (1.9x) | 637 ms / 173 ms (3.7x) | – / – | 50 ms / 35 ms (1.4x) |
| flow | test-glyph_atlas | ok | exit 0, All 8 tests passed. | exit 0, All 8 tests passed. | 495 ms / 286 ms (1.7x) | 495 ms / 130 ms (3.8x) | – / – | 27 ms / 24 ms (1.1x) |
| flow | test-keybind | ok | exit 0, All 24 tests passed. | exit 0, All 24 tests passed. | 1.27 s / 858 ms (1.5x) | 1.27 s / 717 ms (1.8x) | – / – | 157 ms / 79 ms (2.0x) |
| flow | test-gitignore-differential | ok | exit 0, All 59 tests passed. | exit 0, All 59 tests passed. | 583 ms / 344 ms (1.7x) | 583 ms / 164 ms (3.5x) | – / – | 217 ms / 193 ms (1.1x) |
| flow-musl | flow | ok | not run | not run | 13.81 s / 39.01 s (0.4x) | 13.81 s / 6.06 s (2.3x) | – / – | – / – |
| flow-musl | test-terminal_icons | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 508 ms / 386 ms (1.3x) | 508 ms / 635 ms (0.8x) | – / – | 6 ms / 3 ms (2.5x) |
| flow-musl | test-syntax_validator | ok | exit 0, All 5 tests passed. | exit 0, All 5 tests passed. | 748 ms / 893 ms (0.8x) | 748 ms / 827 ms (0.9x) | – / – | 10 ms / 5 ms (1.9x) |
| flow-musl | test-stdio_capture | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 606 ms / 479 ms (1.3x) | 606 ms / 462 ms (1.3x) | – / – | 5 ms / 2 ms (2.2x) |
| flow-musl | test-dbus | ok | exit 0, 9 passed; 2 skipped; 0 failed. | exit 0, 9 passed; 2 skipped; 0 failed. | 1.14 s / 672 ms (1.7x) | 1.14 s / 683 ms (1.7x) | – / – | 19 ms / 7 ms (2.7x) |
| flow-musl | test-gitignore | ok | exit 0, All 55 tests passed. | exit 0, All 55 tests passed. | 577 ms / 839 ms (0.7x) | 577 ms / 230 ms (2.5x) | – / – | 27 ms / 18 ms (1.5x) |
| flow-musl | test-terminal_wt_profiles | ok | exit 0, All 10 tests passed. | exit 0, All 10 tests passed. | 657 ms / 356 ms (1.8x) | 657 ms / 180 ms (3.6x) | – / – | 12 ms / 9 ms (1.3x) |
| flow-musl | test-rc | ok | exit 0, All 8 tests passed. | exit 0, All 8 tests passed. | 1.16 s / 656 ms (1.8x) | 1.16 s / 693 ms (1.7x) | – / – | 29 ms / 17 ms (1.7x) |
| flow-musl | test-terminal_key | ok | exit 0, All 13 tests passed. | exit 0, All 13 tests passed. | 575 ms / 324 ms (1.8x) | 575 ms / 300 ms (1.9x) | – / – | 5 ms / 2 ms (2.3x) |
| flow-musl | test-flow | ok | exit 0, All 284 tests passed. | exit 0, All 284 tests passed. | 1.89 s / 1.13 s (1.7x) | 1.89 s / 1.30 s (1.5x) | – / – | 7.82 s / 4.60 s (1.7x) |
| flow-musl | test-richdoc | ok | exit 0, All 63 tests passed. | exit 0, All 63 tests passed. | 6.12 s / 1.39 s (4.4x) | 6.12 s / 1.28 s (4.8x) | – / – | 94 ms / 77 ms (1.2x) |
| flow-musl | test-match | ok | exit 0, All 19 tests passed. | exit 0, All 19 tests passed. | 551 ms / 303 ms (1.8x) | 551 ms / 519 ms (1.1x) | – / – | 6 ms / 4 ms (1.5x) |
| flow-musl | test-FileStore | ok | exit 0, All 5 tests passed. | exit 0, All 5 tests passed. | 1.34 s / 774 ms (1.7x) | 1.34 s / 758 ms (1.8x) | – / – | 1.64 s / 1.62 s (1.0x) |
| flow-musl | test-fetch | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 556 ms / 308 ms (1.8x) | 556 ms / 157 ms (3.5x) | – / – | 5 ms / 2 ms (2.1x) |
| flow-musl | test-chord_key | ok | exit 0, All 4 tests passed. | exit 0, All 4 tests passed. | 507 ms / 286 ms (1.8x) | 507 ms / 128 ms (3.9x) | – / – | 5 ms / 2 ms (2.1x) |
| flow-musl | test-command_line | ok | exit 0, All 13 tests passed. | exit 0, All 13 tests passed. | 534 ms / 298 ms (1.8x) | 534 ms / 130 ms (4.1x) | – / – | 7 ms / 3 ms (2.1x) |
| flow-musl | test-glyph_constraint | ok | exit 0, All 2 tests passed. | exit 0, All 2 tests passed. | 509 ms / 306 ms (1.7x) | 509 ms / 518 ms (1.0x) | – / – | 6 ms / 2 ms (2.4x) |
| flow-musl | test-edit_set | ok | exit 0, All 32 tests passed. | exit 0, All 32 tests passed. | 681 ms / 397 ms (1.7x) | 681 ms / 268 ms (2.5x) | – / – | 148 ms / 64 ms (2.3x) |
| flow-musl | test-double_mapped_ring_buffer | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 513 ms / 294 ms (1.7x) | 513 ms / 122 ms (4.2x) | – / – | 6 ms / 2 ms (2.9x) |
| flow-musl | test-mouse_event | ok | exit 0, All 8 tests passed. | exit 0, All 8 tests passed. | 591 ms / 299 ms (2.0x) | 591 ms / 181 ms (3.3x) | – / – | 5 ms / 2 ms (2.0x) |
| flow-musl | test-terminal_line_store | ok | exit 0, All 8 tests passed. | exit 0, All 8 tests passed. | 532 ms / 314 ms (1.7x) | 532 ms / 163 ms (3.3x) | – / – | 44 ms / 25 ms (1.8x) |
| flow-musl | test-terminal_screen | ok | exit 0, All 25 tests passed. | exit 0, All 25 tests passed. | 774 ms / 534 ms (1.4x) | 774 ms / 191 ms (4.1x) | – / – | 53 ms / 48 ms (1.1x) |
| flow-musl | test-glyph_atlas | ok | exit 0, All 8 tests passed. | exit 0, All 8 tests passed. | 554 ms / 347 ms (1.6x) | 554 ms / 142 ms (3.9x) | – / – | 30 ms / 26 ms (1.2x) |
| flow-musl | test-keybind | ok | exit 0, All 24 tests passed. | exit 0, All 24 tests passed. | 1.30 s / 1.05 s (1.2x) | 1.30 s / 935 ms (1.4x) | – / – | 200 ms / 79 ms (2.5x) |
| flow-musl | test-gitignore-differential | ok | exit 0, All 59 tests passed. | exit 0, All 59 tests passed. | 575 ms / 345 ms (1.7x) | 575 ms / 168 ms (3.4x) | – / – | 221 ms / 183 ms (1.2x) |
| lztime | test | ok | exit 0, All 18 tests passed. | exit 0, All 18 tests passed. | 593 ms / 429 ms (1.4x) | 593 ms / 193 ms (3.1x) | – / – | 6 ms / 3 ms (1.9x) |
| nats.zig | example-simple | ok | not run | not run | 1.99 s / 1.07 s (1.9x) | 1.99 s / 943 ms (2.1x) | – / – | – / – |
| nats.zig | test | ok | exit 0, All 556 tests passed. | exit 0, All 556 tests passed. | 1.07 s / 632 ms (1.7x) | 1.07 s / 426 ms (2.5x) | – / – | 230 ms / 219 ms (1.1x) |
| nats.zig | test:src/io_backend.zig | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 496 ms / 295 ms (1.7x) | 496 ms / 132 ms (3.8x) | – / – | 7 ms / 2 ms (3.5x) |
| teru | teru | ok | not run | not run | 1.51 s / 666 ms (2.3x) | 1.51 s / 684 ms (2.2x) | – / – | – / – |
| teru | test | ok | exit 0, All 629 tests passed. | exit 0, All 629 tests passed. | 1.18 s / 663 ms (1.8x) | 1.18 s / 483 ms (2.4x) | – / – | 215 ms / 143 ms (1.5x) |
| zarrow | zarrow_c | ok | not run | not run | 680 ms / 308 ms (2.2x) | 680 ms / 268 ms (2.5x) | – / – | – / – |
| zarrow | test | ok | exit 0, All 341 tests passed. | exit 0, All 341 tests passed. | 9.93 s / 7.70 s (1.3x) | 9.93 s / 7.36 s (1.3x) | – / – | 161 ms / 128 ms (1.3x) |
| zig-blind-rsa-signatures | blind-rsa-signatures | ok | not run | not run | 468 ms / 595 ms (0.8x) | 468 ms / 486 ms (1.0x) | – / – | – / – |
| zig-blind-rsa-signatures | test | ok | exit 0, All 15 tests passed. | exit 0, All 15 tests passed. | 792 ms / 879 ms (0.9x) | 792 ms / 1.14 s (0.7x) | – / – | 14.98 s / 9.74 s (1.5x) |
| zig-cbc | test | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 624 ms / 486 ms (1.3x) | 624 ms / 290 ms (2.2x) | – / – | 6 ms / 16 ms (0.4x) |
| zig-cli | test | ok | exit 0, All 12 tests passed. | exit 0, All 12 tests passed. | 551 ms / 438 ms (1.3x) | 551 ms / 442 ms (1.2x) | – / – | 11 ms / 5 ms (2.1x) |
| zig-gobject | translate-gir | ok | not run | not run | 1.00 s / 682 ms (1.5x) | 1.00 s / 533 ms (1.9x) | – / – | – / – |
| zig-gobject | test | ok | exit 0, All 6 tests passed. | exit 0, All 6 tests passed. | 693 ms / 421 ms (1.6x) | 693 ms / 279 ms (2.5x) | – / – | 10 ms / 5 ms (2.2x) |
| zignal | zignal:src/main.zig | ok | not run | not run | 1.93 s / 1.24 s (1.6x) | 1.93 s / 1.02 s (1.9x) | – / – | – / – |
| zignal | zignal:src/root.zig | ok | exit 1, 851 passed; 3 skipped; 1 failed. | exit 1, 851 passed; 3 skipped; 1 failed. | 3.05 s / 1.76 s (1.7x) | 3.05 s / 1.64 s (1.9x) | – / – | 26.72 s / 12.41 s (2.2x) |
| zlaya | test | ok | exit 0, All 25 tests passed. | exit 0, All 25 tests passed. | 822 ms / 855 ms (1.0x) | 822 ms / 406 ms (2.0x) | – / – | 97 ms / 79 ms (1.2x) |
| zlob | zlob:src/main.zig | ok | not run | not run | 1.03 s / 676 ms (1.5x) | 1.03 s / 501 ms (2.0x) | – / – | – / – |
| zlob | test | ok | exit 0, All 6 tests passed. | exit 0, All 6 tests passed. | 580 ms / 428 ms (1.4x) | 580 ms / 187 ms (3.1x) | – / – | 13 ms / 10 ms (1.3x) |
| zlob | test:test/test_fnmatch.zig | ok | exit 0, All 76 tests passed. | exit 0, All 76 tests passed. | 771 ms / 337 ms (2.3x) | 771 ms / 356 ms (2.2x) | – / – | 11 ms / 6 ms (1.8x) |
| zlob | test:test/test_dlopen_tls.zig | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 529 ms / 321 ms (1.7x) | 529 ms / 111 ms (4.8x) | – / – | 6 ms / 15 ms (0.4x) |
| zlob | test:test/test_glibc.zig | ok | exit 0, All 23 tests passed. | exit 0, All 23 tests passed. | 1.08 s / 533 ms (2.0x) | 1.08 s / 490 ms (2.2x) | – / – | 21 ms / 12 ms (1.8x) |
| zlob | test:test/test_static_tls_budget.zig | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 507 ms / 301 ms (1.7x) | 507 ms / 127 ms (4.0x) | – / – | 50 ms / 46 ms (1.1x) |
| zlob | test:test/test_basic.zig | ok | exit 0, All 19 tests passed. | exit 0, All 19 tests passed. | 1.02 s / 508 ms (2.0x) | 1.02 s / 356 ms (2.9x) | – / – | 35 ms / 14 ms (2.5x) |
| zlob | test:test/test_match_basename.zig | ok | exit 0, All 20 tests passed. | exit 0, All 20 tests passed. | 1.10 s / 562 ms (2.0x) | 1.10 s / 221 ms (5.0x) | – / – | 30 ms / 19 ms (1.6x) |
| zlob | test:src/gitignore.zig | ok | exit 0, All 21 tests passed. | exit 0, All 21 tests passed. | 604 ms / 335 ms (1.8x) | 604 ms / 172 ms (3.5x) | – / – | 20 ms / 7 ms (3.1x) |
| zlob | test:test/test_walker_paths.zig | ok | exit 0, All 8 tests passed. | exit 0, All 8 tests passed. | 671 ms / 476 ms (1.4x) | 671 ms / 180 ms (3.7x) | – / – | 17 ms / 10 ms (1.7x) |
| zlob | test:src/walker.zig | ok | exit 0, All 11 tests passed. | exit 0, All 11 tests passed. | 591 ms / 321 ms (1.8x) | 591 ms / 152 ms (3.9x) | – / – | 11 ms / 5 ms (2.2x) |
| zlob | test:src/sorting.zig | ok | exit 0, All 10 tests passed. | exit 0, All 10 tests passed. | 568 ms / 326 ms (1.7x) | 568 ms / 169 ms (3.4x) | – / – | 6 ms / 3 ms (1.7x) |
| zlob | test:src/brace_optimizer.zig | ok | exit 0, All 8 tests passed. | exit 0, All 8 tests passed. | 624 ms / 299 ms (2.1x) | 624 ms / 190 ms (3.3x) | – / – | 20 ms / 10 ms (1.9x) |
| zlob | test:test/test_brace.zig | ok | exit 0, All 57 tests passed. | exit 0, All 57 tests passed. | 1.09 s / 573 ms (1.9x) | 1.09 s / 792 ms (1.4x) | – / – | 86 ms / 73 ms (1.2x) |
| zlob | test:test/test_path_matcher.zig | ok | exit 0, All 76 tests passed. | exit 0, All 76 tests passed. | 1.13 s / 876 ms (1.3x) | 1.13 s / 1.01 s (1.1x) | – / – | 21 ms / 11 ms (1.8x) |
| zlob | test:test/test_gitignore_e2e.zig | ok | exit 0, All 6 tests passed. | exit 0, All 6 tests passed. | 897 ms / 503 ms (1.8x) | 897 ms / 523 ms (1.7x) | – / – | 17 ms / 12 ms (1.4x) |
| zlob | test:test/test_utils.zig | ok | exit 0, All 0 tests passed. | exit 0, All 0 tests passed. | 529 ms / 286 ms (1.9x) | 529 ms / 149 ms (3.6x) | – / – | 6 ms / 3 ms (1.9x) |
| zlob | test:test/test_extglob.zig | ok | exit 0, All 23 tests passed. | exit 0, All 23 tests passed. | 1.11 s / 490 ms (2.3x) | 1.11 s / 593 ms (1.9x) | – / – | 27 ms / 25 ms (1.1x) |
| zlob | test:test/test_gitignore.zig | ok | exit 0, All 21 tests passed. | exit 0, All 21 tests passed. | 610 ms / 336 ms (1.8x) | 610 ms / 231 ms (2.6x) | – / – | 15 ms / 8 ms (1.9x) |
| zlob | test:src/pattern_context.zig | ok | exit 0, All 2 tests passed. | exit 0, All 2 tests passed. | 601 ms / 326 ms (1.8x) | 601 ms / 200 ms (3.0x) | – / – | 15 ms / 5 ms (2.9x) |
| zlob | test:test/test_walk.zig | ok | exit 0, All 40 tests passed. | exit 0, All 40 tests passed. | 1.33 s / 629 ms (2.1x) | 1.33 s / 847 ms (1.6x) | – / – | 877 ms / 756 ms (1.2x) |
| zlob | test:src/fnmatch.zig | ok | exit 0, All 11 tests passed. | exit 0, All 11 tests passed. | 663 ms / 342 ms (1.9x) | 663 ms / 245 ms (2.7x) | – / – | 15 ms / 5 ms (3.3x) |
| zlob | test:test/test_append.zig | ok | exit 0, All 9 tests passed. | exit 0, All 9 tests passed. | 1.27 s / 569 ms (2.2x) | 1.27 s / 790 ms (1.6x) | – / – | 21 ms / 15 ms (1.4x) |
| zlob | test:test/test_posix.zig | ok | exit 0, All 40 tests passed. | exit 0, All 40 tests passed. | 1.17 s / 570 ms (2.1x) | 1.17 s / 731 ms (1.6x) | – / – | 1.02 s / 1.52 s (0.7x) |
| zlob | test:test/test_rust_glob.zig | ok | exit 0, All 30 tests passed. | exit 0, All 30 tests passed. | 972 ms / 599 ms (1.6x) | 972 ms / 596 ms (1.6x) | – / – | 21 ms / 16 ms (1.3x) |
| zlob | test:test/test_absolute_paths.zig | ok | exit 0, All 37 tests passed. | exit 0, All 37 tests passed. | 1.06 s / 521 ms (2.0x) | 1.06 s / 586 ms (1.8x) | – / – | 54 ms / 26 ms (2.1x) |
| zlob | test:test/test_errfunc.zig | ok | exit 0, All 4 tests passed. | exit 0, All 4 tests passed. | 1.25 s / 624 ms (2.0x) | 1.25 s / 686 ms (1.8x) | – / – | 13 ms / 6 ms (2.0x) |
| zlob | test:test/test_edge_cases.zig | ok | exit 0, All 15 tests passed. | exit 0, All 15 tests passed. | 1.28 s / 575 ms (2.2x) | 1.28 s / 665 ms (1.9x) | – / – | 16 ms / 7 ms (2.4x) |
| zlob | test:test/test_match_basename_fuzz.zig | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 805 ms / 535 ms (1.5x) | 805 ms / 355 ms (2.3x) | – / – | 9.77 s / 6.13 s (1.6x) |
| zlob | test:test/test_internal.zig | ok | exit 0, All 26 tests passed. | exit 0, All 26 tests passed. | 725 ms / 384 ms (1.9x) | 725 ms / 311 ms (2.3x) | – / – | 11 ms / 6 ms (2.0x) |
| zquic | server | ok | not run | not run | 974 ms / 645 ms (1.5x) | 974 ms / 554 ms (1.8x) | – / – | – / – |
| zquic | client | ok | not run | not run | 1.01 s / 589 ms (1.7x) | 1.01 s / 181 ms (5.6x) | – / – | – / – |
| zquic | test | ok | exit 0, All 116 tests passed. | exit 0, All 116 tests passed. | 968 ms / 620 ms (1.6x) | 968 ms / 484 ms (2.0x) | – / – | 1.01 s / 204 ms (5.0x) |
| zquic | test:src/quic/transport_params.zig | ok | exit 0, All 44 tests passed. | exit 0, All 44 tests passed. | 526 ms / 291 ms (1.8x) | 526 ms / 129 ms (4.1x) | – / – | 6 ms / 2 ms (2.4x) |
| zquic | test:src/quic/stream.zig | ok | exit 0, All 62 tests passed. | exit 0, All 62 tests passed. | 519 ms / 293 ms (1.8x) | 519 ms / 139 ms (3.7x) | – / – | 15 ms / 12 ms (1.3x) |
| zquic | test:src/quic/connection_test_handshakecorruption.zig | ok | exit 0, All 327 tests passed. | exit 0, All 327 tests passed. | 1.13 s / 667 ms (1.7x) | 1.13 s / 273 ms (4.1x) | – / – | 1.28 s / 304 ms (4.2x) |
| zquic | test:src/quic/connection_id.zig | ok | exit 0, All 4 tests passed. | exit 0, All 4 tests passed. | 552 ms / 293 ms (1.9x) | 552 ms / 115 ms (4.8x) | – / – | 5 ms / 2 ms (2.4x) |
| zquic | test:src/quic/connection_test_pmtud.zig | ok | exit 0, All 346 tests passed. | exit 0, All 346 tests passed. | 1.49 s / 840 ms (1.8x) | 1.49 s / 406 ms (3.7x) | – / – | 2.48 s / 585 ms (4.2x) |
| zquic | test:src/quic/fuzz.zig | ok | exit 0, All 327 tests passed. | exit 0, All 327 tests passed. | 1.12 s / 786 ms (1.4x) | 1.12 s / 232 ms (4.8x) | – / – | 1.15 s / 240 ms (4.8x) |
| zquic | test:src/quic/congestion/bbr.zig | ok | exit 0, All 36 tests passed. | exit 0, All 36 tests passed. | 504 ms / 296 ms (1.7x) | 504 ms / 158 ms (3.2x) | – / – | 5 ms / 2 ms (2.2x) |
| zquic | test:src/quic/netsim.zig | ok | exit 0, All 0 tests passed. | exit 0, All 0 tests passed. | 492 ms / 280 ms (1.8x) | 492 ms / 152 ms (3.2x) | – / – | 5 ms / 2 ms (2.4x) |
| zquic | test:src/quic/congestion/cubic.zig | ok | exit 0, All 19 tests passed. | exit 0, All 19 tests passed. | 499 ms / 308 ms (1.6x) | 499 ms / 186 ms (2.7x) | – / – | 5 ms / 2 ms (2.3x) |
| zquic | test:src/quic/integration_test.zig | ok | exit 0, All 376 tests passed. | exit 0, All 376 tests passed. | 1.16 s / 749 ms (1.5x) | 1.16 s / 1.10 s (1.1x) | – / – | 4.99 s / 2.44 s (2.0x) |
| zquic | test:src/quic/connection_test_basic.zig | ok | exit 0, All 375 tests passed. | exit 0, All 375 tests passed. | 1.17 s / 828 ms (1.4x) | 1.17 s / 1.04 s (1.1x) | – / – | 3.08 s / 737 ms (4.2x) |
| zquic | test:tools/server.zig | ok | exit 0, All 5 tests passed. | exit 0, All 5 tests passed. | 596 ms / 335 ms (1.8x) | 596 ms / 129 ms (4.6x) | – / – | 5 ms / 2 ms (2.6x) |
| zquic | test:src/quic/flow_control.zig | ok | exit 0, All 11 tests passed. | exit 0, All 11 tests passed. | 521 ms / 283 ms (1.8x) | 521 ms / 149 ms (3.5x) | – / – | 5 ms / 2 ms (2.4x) |
| zquic | test:src/quic/loss_recovery.zig | ok | exit 0, All 44 tests passed. | exit 0, All 44 tests passed. | 584 ms / 372 ms (1.6x) | 584 ms / 186 ms (3.1x) | – / – | 13 ms / 6 ms (2.2x) |
| zquic | test:src/quic/packet.zig | ok | exit 0, All 37 tests passed. | exit 0, All 37 tests passed. | 667 ms / 441 ms (1.5x) | 667 ms / 370 ms (1.8x) | – / – | 9 ms / 3 ms (3.1x) |
| zquic | test:tools/pem.zig | ok | exit 0, All 8 tests passed. | exit 0, All 8 tests passed. | 649 ms / 368 ms (1.8x) | 649 ms / 171 ms (3.8x) | – / – | 9 ms / 3 ms (3.2x) |
| zquic | test:src/quic/connection_test_frames.zig | ok | exit 0, All 390 tests passed. | exit 0, All 390 tests passed. | 1.16 s / 804 ms (1.4x) | 1.16 s / 1.12 s (1.0x) | – / – | 3.59 s / 990 ms (3.6x) |
| zquic | test:src/quic/connection_test_resumption.zig | ok | exit 0, All 333 tests passed. | exit 0, All 333 tests passed. | 1.12 s / 718 ms (1.6x) | 1.12 s / 997 ms (1.1x) | – / – | 1.45 s / 329 ms (4.4x) |
| zquic | test:src/quic/crypto.zig | ok | exit 0, All 56 tests passed. | exit 0, All 56 tests passed. | 582 ms / 415 ms (1.4x) | 582 ms / 384 ms (1.5x) | – / – | 6 ms / 4 ms (1.5x) |
| zquic | test:src/quic/congestion/common.zig | ok | exit 0, All 3 tests passed. | exit 0, All 3 tests passed. | 545 ms / 273 ms (2.0x) | 545 ms / 120 ms (4.5x) | – / – | 5 ms / 2 ms (1.9x) |
| zquic | test:src/quic/tls.zig | ok | exit 0, All 113 tests passed. | exit 0, All 113 tests passed. | 921 ms / 591 ms (1.6x) | 921 ms / 800 ms (1.2x) | – / – | 992 ms / 206 ms (4.8x) |
| zquic | test:src/quic/test_harness.zig | ok | exit 0, All 0 tests passed. | exit 0, All 0 tests passed. | 518 ms / 289 ms (1.8x) | 518 ms / 48 ms (10.9x) | – / – | 5 ms / 2 ms (2.5x) |
| zquic | test:src/quic/congestion/cc_test_harness.zig | ok | exit 0, All 61 tests passed. | exit 0, All 61 tests passed. | 557 ms / 326 ms (1.7x) | 557 ms / 244 ms (2.3x) | – / – | 6 ms / 2 ms (2.3x) |
| zquic | test:src/quic/pool.zig | ok | exit 0, All 5 tests passed. | exit 0, All 5 tests passed. | 551 ms / 376 ms (1.5x) | 551 ms / 185 ms (3.0x) | – / – | 6 ms / 5 ms (1.3x) |
| zquic | test:src/quic/varint.zig | ok | exit 0, All 10 tests passed. | exit 0, All 10 tests passed. | 531 ms / 309 ms (1.7x) | 531 ms / 191 ms (2.8x) | – / – | 18 ms / 3 ms (6.7x) |
| zquic | test:src/quic/connection_test_corruption.zig | ok | exit 0, All 327 tests passed. | exit 0, All 327 tests passed. | 1.31 s / 858 ms (1.5x) | 1.31 s / 1.18 s (1.1x) | – / – | 1.60 s / 380 ms (4.2x) |
| zquic | test:src/quic/connection.zig | ok | exit 0, All 44 tests passed. | exit 0, All 44 tests passed. | 647 ms / 330 ms (2.0x) | 647 ms / 165 ms (3.9x) | – / – | 16 ms / 5 ms (2.8x) |
| zquic | test:src/quic/connection_test_crypto.zig | ok | exit 0, All 404 tests passed. | exit 0, All 404 tests passed. | 1.20 s / 752 ms (1.6x) | 1.20 s / 1.11 s (1.1x) | – / – | 3.63 s / 850 ms (4.3x) |
| zquic | test:src/quic/frame.zig | ok | exit 0, All 52 tests passed. | exit 0, All 52 tests passed. | 532 ms / 310 ms (1.7x) | 532 ms / 203 ms (2.6x) | – / – | 9 ms / 4 ms (2.5x) |
| XirAsm | xirasm | ok | not run | not run | 1.86 s / 1.32 s (1.4x) | 1.86 s / 929 ms (2.0x) | – / – | – / – |
| XirAsm | test | ok | exit 0, All 358 tests passed. | exit 0, All 358 tests passed. | 2.10 s / 1.26 s (1.7x) | 2.10 s / 1.20 s (1.8x) | – / – | 21.62 s / 13.81 s (1.6x) |
| zprof | zprof | ok | not run | not run | 47 ms / 21 ms (2.2x) | 47 ms / 7 ms (6.7x) | – / – | – / – |
| zprof | test | ok | exit 0, All 12 tests passed. | exit 0, All 12 tests passed. | 548 ms / 329 ms (1.7x) | 548 ms / 171 ms (3.2x) | – / – | 8 ms / 6 ms (1.2x) |
| csv-zero | csvzero | ok | not run | not run | 426 ms / 264 ms (1.6x) | 426 ms / 245 ms (1.7x) | – / – | – / – |
| csv-zero | test | ok | exit 0, All 2 tests passed. | exit 0, All 2 tests passed. | 641 ms / 434 ms (1.5x) | 641 ms / 138 ms (4.6x) | – / – | 6 ms / 3 ms (2.3x) |
| ChipZ | test | ok | exit 0, All 7 tests passed. | exit 0, All 7 tests passed. | 645 ms / 317 ms (2.0x) | 645 ms / 170 ms (3.8x) | – / – | 6 ms / 4 ms (1.5x) |
| verse | test | ok | exit 0, All 6 tests passed. | exit 0, All 6 tests passed. | 559 ms / 328 ms (1.7x) | 559 ms / 280 ms (2.0x) | – / – | 6 ms / 3 ms (2.4x) |
| verse | test:src/verse.zig | bs: compile error | exit 0, 105 passed; 1 skipped; 0 failed. | src/ContentType.zig:88:25: error[bad-switch]: cannot enumerate values of type 'ContentType | 3.08 s / 1.67 s (1.8x) | 3.08 s / – | – / – | 128 ms / – |
| verse | basic | ok | not run | not run | 645 ms / 409 ms (1.6x) | 645 ms / 319 ms (2.0x) | – / – | – / – |
| verse | template | ok | not run | not run | 877 ms / 471 ms (1.9x) | 877 ms / 305 ms (2.9x) | – / – | – / – |
| verse | template-enum | ok | not run | not run | 713 ms / 421 ms (1.7x) | 713 ms / 189 ms (3.8x) | – / – | – / – |
| verse | template-extra | ok | not run | not run | 727 ms / 511 ms (1.4x) | 727 ms / 199 ms (3.7x) | – / – | – / – |
| verse | websocket | ok | not run | not run | 671 ms / 391 ms (1.7x) | 671 ms / 171 ms (3.9x) | – / – | – / – |
| marionette | marionette-run | bs: compile error | not run | src/fiber.zig:692:66: error[no-member]: union 'lang.CallingConvention' has no member named | 1.12 s / 777 ms (1.4x) | 1.12 s / – | – / – | – / – |
| marionette | marionette-tidy | ok | not run | not run | 583 ms / 354 ms (1.6x) | 583 ms / 192 ms (3.0x) | – / – | – / – |
| marionette | test | bs: compile error | exit 0, All 3 tests passed. | src/fiber.zig:692:66: error[no-member]: union 'lang.CallingConvention' has no member named | 875 ms / 417 ms (2.1x) | 875 ms / – | – / – | 36 ms / – |
| marionette | test:examples/root.zig | bs: compile error | exit 0, All 28 tests passed. | src/fiber.zig:692:66: error[no-member]: union 'lang.CallingConvention' has no member named | 1.33 s / 672 ms (2.0x) | 1.33 s / – | – / – | 1.15 s / – |
| marionette | test:src/root.zig | bs: compile error | exit 0, All 424 tests passed. | src/fiber.zig:692:66: error[no-member]: union 'lang.CallingConvention' has no member named | 3.43 s / 1.76 s (1.9x) | 3.43 s / – | – / – | 1.32 s / – |
| marionette | test:tests/root.zig | bs: compile error | exit 0, All 106 tests passed. | src/fiber.zig:692:66: error[no-member]: union 'lang.CallingConvention' has no member named | 1.67 s / 863 ms (1.9x) | 1.67 s / – | – / – | 4.98 s / – |
| marionette | test:validation/bounded_queue_concurrency.zig | bs: compile error | exit 0, All 5 tests passed. | src/fiber.zig:692:66: error[no-member]: union 'lang.CallingConvention' has no member named | 994 ms / 492 ms (2.0x) | 994 ms / – | – / – | 1.11 s / – |
| marionette | test:validation/kv_compat.zig | bs: compile error | exit 0, All 8 tests passed. | src/fiber.zig:692:66: error[no-member]: union 'lang.CallingConvention' has no member named | 1.03 s / 481 ms (2.1x) | 1.03 s / – | – / – | 504 ms / – |
| polyrole | test | ok | exit 0, All 0 tests passed. | exit 0, All 0 tests passed. | 668 ms / 357 ms (1.9x) | 668 ms / 168 ms (4.0x) | – / – | 8 ms / 2 ms (4.1x) |
| wild | wild | ok | not run | not run | 610 ms / 369 ms (1.7x) | 610 ms / 266 ms (2.3x) | – / – | – / – |
| wild | benchmark | ok | not run | not run | 669 ms / 341 ms (2.0x) | 669 ms / 218 ms (3.1x) | – / – | – / – |
| wild | test | ok | exit 0, All 0 tests passed. | exit 0, All 0 tests passed. | 592 ms / 368 ms (1.6x) | 592 ms / 197 ms (3.0x) | – / – | 5 ms / 2 ms (2.2x) |
| wild | test:tests/test_batch_read.zig | ok | exit 0, All 6 tests passed. | exit 0, All 6 tests passed. | 576 ms / 375 ms (1.5x) | 576 ms / 281 ms (2.1x) | – / – | 1.12 s / 1.04 s (1.1x) |
| wild | test:tests/test_wild_storage.zig | ok | exit 0, All 4 tests passed. | exit 0, All 4 tests passed. | 522 ms / 318 ms (1.6x) | 522 ms / 149 ms (3.5x) | – / – | 22 ms / 26 ms (0.9x) |
| wild | test:src/root.zig | ok | exit 0, All 1 tests passed. | exit 0, All 1 tests passed. | 590 ms / 284 ms (2.1x) | 590 ms / 145 ms (4.1x) | – / – | 7 ms / 3 ms (2.3x) |
| wild | test:src/test_slab_allocator.zig | ok | exit 0, All 7 tests passed. | exit 0, All 7 tests passed. | 631 ms / 341 ms (1.8x) | 631 ms / 152 ms (4.1x) | – / – | 37 ms / 26 ms (1.4x) |
| wild | test:src/client.zig | ok | exit 0, All 0 tests passed. | exit 0, All 0 tests passed. | 548 ms / 346 ms (1.6x) | 548 ms / 144 ms (3.8x) | – / – | 5 ms / 2 ms (2.0x) |
| zeptun | zeptun:src/cli/main.zig | ok | not run | not run | 995 ms / 574 ms (1.7x) | 995 ms / 508 ms (2.0x) | – / – | – / – |
| zeptun | test | ok | exit 0, 101 passed; 8 skipped; 0 failed. | exit 0, 101 passed; 8 skipped; 0 failed. | 1.08 s / 781 ms (1.4x) | 1.08 s / 502 ms (2.2x) | – / – | 2.77 s / 2.51 s (1.1x) |
| zeptun | test:src/bench/main.zig | ok | exit 0, All 6 tests passed. | exit 0, All 6 tests passed. | 578 ms / 328 ms (1.8x) | 578 ms / 189 ms (3.1x) | – / – | 34 ms / 40 ms (0.8x) |
| zeptun | test:src/ffi/ffi.zig | ok | exit 0, All 2 tests passed. | exit 0, All 2 tests passed. | 862 ms / 498 ms (1.7x) | 862 ms / 358 ms (2.4x) | – / – | 8 ms / 4 ms (2.1x) |
| zeptun | test:src/cli/main.zig | ok | exit 0, All 0 tests passed. | exit 0, All 0 tests passed. | 530 ms / 280 ms (1.9x) | 530 ms / 237 ms (2.2x) | – / – | 7 ms / 2 ms (3.3x) |
| s2s | test | ok | exit 0, All 3 tests passed. | exit 0, All 3 tests passed. | 624 ms / 462 ms (1.4x) | 624 ms / 580 ms (1.1x) | – / – | 12 ms / 3 ms (3.6x) |
| knoedel | test | bs: compile error | exit 0, All 20 tests passed. | src/ecs.zig:528:61: error[comptime-required]: unable to resolve comptime value | 834 ms / 447 ms (1.9x) | 834 ms / – | – / – | 1.26 s / – |
| serde.zig | test | ok | exit 0, All 9 tests passed. | exit 0, All 9 tests passed. | 812 ms / 491 ms (1.7x) | 812 ms / 328 ms (2.5x) | – / – | 22 ms / 13 ms (1.7x) |
| serde.zig | test:test/toon_test.zig | ok | exit 0, All 17 tests passed. | exit 0, All 17 tests passed. | 684 ms / 415 ms (1.6x) | 684 ms / 243 ms (2.8x) | – / – | 13 ms / 9 ms (1.5x) |
| serde.zig | test:test/serde_options_test.zig | ok | exit 0, All 63 tests passed. | exit 0, All 63 tests passed. | 930 ms / 494 ms (1.9x) | 930 ms / 343 ms (2.7x) | – / – | 18 ms / 7 ms (2.7x) |
| serde.zig | test:test/tokens_test.zig | ok | exit 0, All 6 tests passed. | exit 0, All 6 tests passed. | 677 ms / 370 ms (1.8x) | 677 ms / 218 ms (3.1x) | – / – | 6 ms / 4 ms (1.5x) |
| serde.zig | test:test/etf_test.zig | ok | exit 0, All 11 tests passed. | exit 0, All 11 tests passed. | 734 ms / 485 ms (1.5x) | 734 ms / 311 ms (2.4x) | – / – | 13 ms / 7 ms (1.8x) |
| serde.zig | test:src/root.zig | ok | exit 0, All 838 tests passed. | exit 0, All 838 tests passed. | 2.49 s / 1.63 s (1.5x) | 2.49 s / 1.50 s (1.7x) | – / – | 87 ms / 57 ms (1.5x) |
| serde.zig | test:test/json_diagnostics_test.zig | ok | exit 0, All 11 tests passed. | exit 0, All 11 tests passed. | 904 ms / 392 ms (2.3x) | 904 ms / 275 ms (3.3x) | – / – | 55 ms / 32 ms (1.7x) |
| serde.zig | test:bench/main.zig | ok | exit 0, All 3 tests passed. | exit 0, All 3 tests passed. | 560 ms / 399 ms (1.4x) | 560 ms / 172 ms (3.2x) | – / – | 5 ms / 2 ms (2.2x) |
| serde.zig | test:test/contracts_test.zig | ok | exit 0, All 4 tests passed. | exit 0, All 4 tests passed. | 866 ms / 509 ms (1.7x) | 866 ms / 424 ms (2.0x) | – / – | 7 ms / 3 ms (2.6x) |
| serde.zig | test:test/roundtrip_test.zig | ok | exit 0, All 13 tests passed. | exit 0, All 13 tests passed. | 829 ms / 496 ms (1.7x) | 829 ms / 297 ms (2.8x) | – / – | 14 ms / 6 ms (2.4x) |
| serde.zig | test:test/core_regressions_test.zig | ok | exit 0, All 22 tests passed. | exit 0, All 22 tests passed. | 1.44 s / 794 ms (1.8x) | 1.44 s / 696 ms (2.1x) | – / – | 94 ms / 55 ms (1.7x) |
| serde.zig | test:test/edge_cases_test.zig | ok | exit 0, All 36 tests passed. | exit 0, All 36 tests passed. | 676 ms / 397 ms (1.7x) | 676 ms / 208 ms (3.2x) | – / – | 10 ms / 5 ms (2.2x) |
| serde.zig | test:test/reader_test.zig | ok | exit 0, All 16 tests passed. | exit 0, All 16 tests passed. | 766 ms / 453 ms (1.7x) | 766 ms / 284 ms (2.7x) | – / – | 36 ms / 31 ms (1.1x) |
| serde.zig | test:test/stress_test.zig | ok | exit 0, All 20 tests passed. | exit 0, All 20 tests passed. | 1.43 s / 1.00 s (1.4x) | 1.43 s / 777 ms (1.8x) | – / – | 15 ms / 5 ms (2.9x) |
| serde.zig | test:test/adversarial_test.zig | ok | exit 0, All 52 tests passed. | exit 0, All 52 tests passed. | 659 ms / 397 ms (1.7x) | 659 ms / 200 ms (3.3x) | – / – | 11 ms / 3 ms (3.3x) |
| oma | test | ok | exit 0, All 2 tests passed. | exit 0, All 2 tests passed. | 495 ms / 317 ms (1.6x) | 495 ms / 154 ms (3.2x) | – / – | 5 ms / 2 ms (2.5x) |
| comptime-serde | test | ok | exit 0, All 139 tests passed. | exit 0, All 139 tests passed. | 896 ms / 534 ms (1.7x) | 896 ms / 606 ms (1.5x) | – / – | 15 ms / 9 ms (1.6x) |
| zitrus | zitrus | ok | not run | not run | 2.29 s / 1.52 s (1.5x) | 2.29 s / 1.56 s (1.5x) | – / – | – / – |
| zitrus | zitrus-mod-tests | ok | exit 0, 40 passed; 1 skipped; 0 failed. | exit 0, 40 passed; 1 skipped; 0 failed. | 914 ms / 476 ms (1.9x) | 914 ms / 335 ms (2.7x) | – / – | 13 ms / 8 ms (1.5x) |
| zitrus | zitrus-exe-tests | ok | exit 0, All 0 tests passed. | exit 0, All 0 tests passed. | 567 ms / 308 ms (1.8x) | 567 ms / 144 ms (3.9x) | – / – | 5 ms / 2 ms (2.3x) |
| zigdown | zigdown | bs: compile error | not run | zig-pkg/plutosvg-0.0.6-3-LyMxgXMyAAD6k7ItjCRXOfbv3dDsF-oPiTWZZgLdEiIB/lib/plutosvg.zig:91: | 12.44 s / 4.29 s (2.9x) | 12.44 s / – | – / – | – / – |
| zigdown | test | bs: compile error | exit 0, no summary | zig-pkg/plutosvg-0.0.6-3-LyMxgXMyAAD6k7ItjCRXOfbv3dDsF-oPiTWZZgLdEiIB/lib/plutosvg.zig:91: | 12.48 s / 4.01 s (3.1x) | 12.48 s / – | – / – | 69 ms / – |
| sandopolis | sandopolis | ok | not run | not run | 4.61 s / 2.71 s (1.7x) | 4.61 s / 1.65 s (2.8x) | – / – | – / – |
| sandopolis | test | bs: run differs (exit signal 6, no summary, died in system_machine.test.facade boots a sega cd from bios bytes and an in-memory iso vs exit 0, All 602 tests passed.) | exit 0, All 602 tests passed. | exit signal 6, no summary, died in system_machine.test.facade boots a sega cd from bios by | 3.96 s / 1.49 s (2.7x) | 3.96 s / 1.31 s (3.0x) | – / – | 124.79 s / 74.19 s (1.7x) |
| sandopolis | test:tests/property_tests.zig | ok | exit 0, All 25 tests passed. | exit 0, All 25 tests passed. | 1.57 s / 736 ms (2.1x) | 1.57 s / 540 ms (2.9x) | – / – | 16.01 s / 8.14 s (2.0x) |
| evm.zig | evmz:tools/main.zig | upstream fails to compile | – | src/interpreter/tail_dispatch.zig:283:28: error[unsupported]: unable to perform tail call: | 39 ms / 11.41 s (0.0x) | 39 ms / – | – / – | – / – |
| evm.zig | test | ok | exit 0, 7 of 7 tests passed | exit 0, 7 of 7 tests passed | 576 ms / 417 ms (1.4x) | 576 ms / 386 ms (1.5x) | – / – | 6 ms / 3 ms (2.2x) |
| evm.zig | mpt-key-tests | ok | exit 0, 2 of 2 tests passed | exit 0, 2 of 2 tests passed | 558 ms / 335 ms (1.7x) | 558 ms / 175 ms (3.2x) | – / – | 9 ms / 5 ms (1.7x) |
| evm.zig | test:pkg/mpt/test.zig | ok | exit 0, 55 of 55 tests passed | exit 0, 55 of 55 tests passed | 791 ms / 529 ms (1.5x) | 791 ms / 330 ms (2.4x) | – / – | 1.26 s / 513 ms (2.5x) |
| evm.zig | test:pkg/rlp/src/test.zig | ok | exit 0, 37 of 37 tests passed | exit 0, 37 of 37 tests passed | 808 ms / 457 ms (1.8x) | 808 ms / 284 ms (2.8x) | – / – | 22 ms / 14 ms (1.6x) |
| evm.zig | evmz-native-tests | upstream fails to compile | – | src/interpreter/tail_dispatch.zig:283:28: error[unsupported]: unable to perform tail call: | 37 ms / 11.99 s (0.0x) | 37 ms / – | – / – | – / – |
