# Scope: cold-local builds of C-main executables

Status: parked (2026-11-05). This is compile-time work only, and the
owner has parked compile-time work in favor of bugs and generated-code
speed. This note holds the measurement and the plan for when compile
time is back on the table.

## The gap

A C-main executable is one with no Zig root, only C sources and
libraries: siv's smoke, abi and app targets, and its guide examples.
Each costs bs about 60 ms more than upstream on a cold-local build
(empty local cache, warm global cache).

siv's smoke target (449e66f9) was measured with bs ReleaseFast on
large-link-inputs fb078dd, and upstream 0.17.1, on an orb:

    build-exe -cflags -std=c11 -Wall -Wextra -Werror -pedantic --
        test/c/smoke.c -Izig-out/include zig-out/lib/libsiv.so -lc
        --name smoke -target x86_64-linux-gnu

| | wall |
|---|---|
| upstream, cold-local | 47–54 ms |
| bs, cold-local | 111–125 ms |

BS_TIMING splits bs's time as follows:

- **Setup and cache check: 25 ms.** 10 ms of it is the `zig version`
  subprocess that every build with C sources runs. Clang compiles
  smoke.c alongside Sema.
- **Sema: 40–55 ms.** The build replays the program's own donor: about
  6100 units (1730 functions) of start code, std and compiler_rt, of
  which 18 are analyzed again. That is a lot of work for a program that
  has no Zig source.
- **Cache record: 23 ms.** It records 14,551 nodes, 2953 atoms and 703
  inputs, all of them the donor's.

The 76 MB libsiv.so no longer counts. Mapping it, and recording a large
link input by its stat (large-link-inputs), took that cost from about
120 ms to under 1 ms.

## Plan

1. **Cache `zig version`.** Store its output in the global cache, keyed
   by the zig binary's path and stat (inode, size, mtime), and run the
   subprocess only when the stat changes. This saves about 10 ms per
   build with C sources, cold or warm.
2. **Relink from the donor without replaying.** A C-root program's Zig
   part depends only on the compilation key (target, options) and on
   which names the shared libraries define (`exportTarget`, see
   "Cached" under shared libraries in architecture.md). The C objects
   do not affect it ("Object files never influence analysis or
   CodeGen"). A donor of the same key, whose library-defined names are
   the same, therefore already holds this build's units. The cold build
   could link the way `relinkIfUnchanged` does from the donor's
   manifest (`linkFrom`, with the C objects as link-only inputs),
   without loading units into Sema. Where that cannot be proven (a
   name a library now defines differently, or a donor with other link
   inputs), it falls back to today's donor replay.
3. **Install the donor's base instead of recording.** After that relink,
   hard-link the donor's manifest as this compilation's base, as
   `installDonorBase` already does for a lazy donor build, and append
   only the link inputs' stats in a log record. This replaces a full
   record of 14.5k nodes.

The target is about 50 ms cold-local on smoke. Edit-verify,
`--std --sched-check`, the cache shell tests and donor_*.sh must stay
green. Step 2 needs a test in which a library adds or drops a name that
the Zig part binds, between the donor's build and this one.
