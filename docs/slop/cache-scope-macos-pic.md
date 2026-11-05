# Scope: the cache on aarch64-macos, and for position-independent outputs

Status: scoping note (2026-11-05), not started. Two builds skip the
per-declaration cache today (`Job.cacheable` in main.zig): every
aarch64-macos build, and on x86_64-linux every position-independent
object or library. This note says what each would need, where the
linkers already have what the relink needs, and what the gap costs.

## What a cached build needs from the linker

A cached build links in one of three ways (`Incremental`):

1. **No-change relink** (`relinkIfUnchanged`): nothing changed, so the
   output's stat is checked and it is kept, or the manifest's atoms are
   linked again from the packs (`linkFrom`).
2. **Lazy edit build** (`finishLazy`): the edits are logged and the
   whole image is linked again from the manifest (`linkFrom`).
3. **Eager edit build**: units load from the cache into `Emit` and the
   normal link runs (`Emit.link`) over the loaded atoms.

Path 3 needs nothing new on any target: loaded atoms carry everything
`Emit.link` reads (relocations, unwind info, debug info). Paths 1 and 2
link without `Emit`, from the manifest alone: `linkFrom` builds the
linker's options from the manifest's link symbols (exports, imports and
their flags), the error values, the extern aliases and the link-only
inputs, and passes the atoms as numbers (`Elf.Symbols`) so the link
looks up no keys. With object or archive inputs it converts them again
and links by key (`linkWithInputs`). Every input of the link that is not
in the manifest must be a link-only input (`:link:<path>`), so that a
change to it is noticed.

## aarch64-macos

**What the Mach-O link reads that the manifest lacks.** `Emit.link`'s
Mach-O branch reads:

- **The dylib inputs** (`-lfoo` and `.dylib` arguments,
  `Emit.macho_libs`): their install names and versions become
  LC_LOAD_DYLIBs, and their export sets decide which library each import
  binds to (`MachO.Import.lib`). The paths become link-only inputs, as
  ELF's `link_shared` are. A relink parses them again (`MachODylib.parse`,
  as `loadShared` parses ELF libraries) or the manifest records each
  import's library index in its flags; parsing again is simpler and
  stays right if one changes, which replays eagerly anyway.
- **`-rpath`** (`Incremental.runpath` already exists for ELF), the
  install name and `--version` of a dylib, and the stack size: from the
  command line, which the compilation key covers.
- **The MachOInput objects and archives** (object arguments, C objects,
  libc++ and friends): converted again on every relink, as ELF's are
  (`convertMachOInputs`, `MachOInput.convert`). Their functions and
  objects come as `local_symbols`.

**What needs nothing in the manifest.** The ad-hoc code signature and the
chained fixups are computed from the image in every link (`MachO.build`),
and the dSYM from the atoms' debug info, which the pack stores. The
UUID is a hash of the output. Compact unwind comes from `Atom.unwind`,
which the pack stores for ELF's `.eh_frame` already. A relink costs the
signing pass (SHA-256 over every page), which a no-change build skips
because the output's stat still matches.

**Where Elf's numbered layout has no Mach-O equivalent yet.**

| Output | ELF relink | Mach-O today |
|---|---|---|
| Executable, Zig only | numbered (`Elf.Symbols`) | `MachO.Symbols` exists, numbers imports too and takes a pack's input (its tests link one); nothing calls it yet |
| Executable with object, archive or C inputs | keyed (`linkWithInputs`) | keyed link works (`local_symbols`); numbered refuses `local_symbols` |
| Dylib (`build-lib -dynamic`) | the numbered link takes shared objects (`dynamic_exports`); the cache does not use it yet (see PIC below) | `MachO.build` refuses `dylib` with `symbols`: the exports trie would need numbered exports |
| Object (`build-obj`, `-fPIC`) | `ElfObject.linkInput` over the pack | `MachOObject` links only an `Atom` slice; it needs a `linkInput` over the pack's atoms, as `ElfObject` has |
| Static library | `Archive.write` of the object | `Archive.writeDarwin` exists; needs the object above |

**Steps and rough size.** Each step is usable on its own:

1. **Executables of Zig only** (tests, `zig build` test and exe steps of
   pure Zig): `cacheable` admits aarch64-macos; `linkFrom` gets a Mach-O
   branch that builds `MachO.Options` (imports with their library,
   entry, values, aliases, debug, stack size) and calls the numbered
   link; dylib inputs become link-only inputs. About 250 lines in
   Incremental and main, no linker change. run.py's `cache: False` for
   aarch64-macos goes, so `--edit-verify` and `--sched-check` check the
   cache there as on Linux; the build.zig rebuild tests (`rebuild-without`
   and friends) gain an aarch64-macos variant on a Mac host.
2. **Inputs** (objects, archives, C sources, libc++): a Mach-O
   `linkWithInputs`, about 250 lines, mirroring ELF's: convert again,
   keyed link, and the check that a changed object did not move the Zig
   code's bindings (`objects_changed`).
3. **Objects and static libraries**: `MachOObject.linkInput` over the
   pack (linker side, about 100 lines) and the branch in `linkFrom`.
4. **Dylibs**: numbered exports in `MachO.build` (linker side, about 100
   lines), the manifest's `shared` output kind (shared with PIC below),
   and the branch in `linkFrom`.

In all, about 600–900 lines with tests; step 1 covers most Mac builds.
Verification needs a Mac (satellite): `BS_CACHE_CHECK`, behavior with
`--edit-verify --sched-check`, std's tier swap, and the corpus matrix.

**What the gap costs.** Every Mac build is a full build, including
builds that change nothing: `InputsRecord` (the whole-build skip) is
taken only by position-independent builds, so a no-change `bs
build-exe` or a no-change step of `bs build` compiles again. Full builds
on a 12-core Mac satellite (ReleaseFast bs at main 6e62a64, median of
five) against an edit and a no-change build of the same programs on a
4-core x86_64 orb:

| Program | Mac, every build | Linux full | Linux edit | Linux no change |
|---|---|---|---|---|
| hello | 63 ms | 150 ms | 9 ms | 1 ms |
| libvaxis test | 192 ms | 292 ms | 14 ms | 2 ms |
| libvaxis example-text_input | 112 ms | 258 ms | 14 ms | 2 ms |
| zls | 480 ms | 1007 ms | 38 ms | 2 ms |

(The libvaxis test is `test:src/main.zig` on the Mac and the corpus's
`test` target on Linux.) The Mac is fast enough that no single compile
is slow, but each is 10–20 times what a cached edit would take, and
30–250 times a no-change build. Through the build runner it adds up:
libvaxis's `bs build test` with nothing changed takes 3.5 s on the Mac
against upstream's 0.5 s, and `bs build install` 0.78 s against 0.10 s,
because every compile step compiles again (with fix-macho-zerofill;
before it, `bs build` crashed on the Mac).

**A cheap interim fix.** Let `InputsRecord` take uncached aarch64-macos
builds too (its condition in `compile` is `job.opts.pic`; it would be
"not cacheable"). No-change builds and unchanged `bs build` steps on the
Mac would then cost a stat of their inputs (1–2 ms) instead of a full
build, which brings no-change `bs build test` and `bs build install`
near upstream's. About 5 lines plus a test on a Mac host; independent of the
steps above, and dropped once step 1 lands.

## Position-independent outputs (x86_64-linux)

**What is uncached.** `-fPIC` and `-fPIE` matter only on objects and
libraries (on executables bs ignores them and links static, non-PIE, as
main.zig's argument parsing says), and so does the implied PIC of `-lc`
objects and libraries and of `-dynamic` libraries. Those builds skip the
cache (`cacheable`: "the numbered link has no position-independent
layout yet"); `InputsRecord` keeps their no-change builds cheap, but
every edit is a full build.

**Why, and what is left.** The comment predates the linker work: the
numbered link takes PIC and shared images since 2026-11-04
(architecture.md, "Cache" under the PIC section), with numbered imports
and exports and `_DYNAMIC`, byte for byte the keyed link's output. What
is left is the cache side:

- `cacheable` drops `!pic` (x86_64-linux; aarch64-linux refuses PIC
  outputs altogether so far).
- The manifest records the output kind `shared` (`Manifest.Output`) and
  whether code is PIC; `linkFrom` passes `.pic`, base address 0 for a
  shared object, and its `ElfDynamic.Options` (exports, soname,
  runpath, imports, and with `-lc` `Glibc.sharedObjectOptions`) with
  their numbers, as `Emit.link`'s shared branch builds them.
- The donor key gains PIC and `shared`: a first build must not replay
  a non-PIC donor, whose function atoms that do not read builtin.zig
  would stay green.
- `linkWithInputs` gains the shared output (objects linked into a
  `.so` export their globals, `dynamicExports`), and shared library
  inputs of a shared output become link-only inputs as for executables.
- Tests: test/pic gains the rebuild and edit cases, and `BS_CACHE_CHECK`
  edit-verify runs over a `-fPIC` object and a `-dynamic` library.

About 300–450 lines with tests, all in Incremental, main and the
manifest. Once it lands, `InputsRecord` serves only aarch64-macos (if
the interim fix above is taken) and goes with the Mac cache.

**What it costs real projects.** Of the corpus's compile steps, the
position-independent ones with Zig in them are libvaxis's `vaxis-c-api`
(`build-obj -fPIC -lc`), libxev's `xev` (`build-lib -lc`) and zio's `zio`
(`build-lib -lc`, which exports nothing and builds in 4 ms); zine's ~180
`-lc` objects are C only, which the C records already cache, and
ghostty's `-fPIC` test and linuxwave's `-fPIE` executable are cached
because bs ignores those flags there. A one-line edit (ReleaseFast bs at
main 6e62a64, 4-core orb, median of three):

| Step | Edit today (full build) | No change | Same step without PIC, edit |
|---|---|---|---|
| libvaxis `vaxis-c-api` | 482 ms | 2 ms | does not compile without `-lc` |
| libxev `xev` | 163 ms | 2 ms | 31 ms |

So each edit of a C API library costs a full build: 5 times a cached
edit for xev, and about 30 times for vaxis-c-api, judging by the 14 ms
edits of libvaxis's other steps. The steps are few in the corpus, but they are what a project
shipping a C library (libghostty-vt as a `.so`, for example) rebuilds
on every edit.
