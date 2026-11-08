# Installing agent skills with bs

Status: proposed (2026-11-08), for the owner's review. Nothing is built.
This is the companion of docs/slop/zigdoc-in-bs.md, written from main
f5befc2.

The owner's request: a way to install agent skills (directories with a
`SKILL.md`, in the [Agent Skills](https://agentskills.io) format) from
baskingspot and from other sources. Fetching should reuse the package
fetcher and global cache bs already has for build.zig.zon dependencies,
with no new network code if possible.

## What exists

**What baskingspot publishes** (GitHub search for `SKILL.md` in the
org, and the repository trees, 2026-11-08):

- **baskingspot/skills** (public, no tags, HEAD 6888cc2). This is the
  distribution repository, one directory per skill under `skills/`:
  - `zig-017`: writing and porting Zig 0.17;
  - `zig-016`: the same for 0.16;
  - `tiger-style`: TigerBeetle's doctrine, restated.

  Each has a `SKILL.md` and `references/`. Together they are 128,598
  bytes. Its README installs with `npx skills add baskingspot/skills`
  (vercel-labs/skills) or `pi install git:github.com/baskingspot/skills`.
  Its `eval/scaffold/.agents/skills/` holds a vendored copy, checked
  against the source by `just check`. Its AGENTS.md says project-only
  skills belong in baskingspot/internal. It also says a skill that
  mentions zigdoc or ziglint must give their source URL, because neither
  ships with Zig.
- **Project skills in `.pi/skills/`** (pi's project directory):
  - baskingspot/fastmem: `zig`;
  - baskingspot/tls: `zig`, `glasswing-harness`;
  - baskingspot/websocket: `rfc6455`;
  - baskingspot/internal (private): `baskingspot-adopt`,
    `baskingspot-audit`, `baskingspot-brand`, `baskingspot-deps`,
    `baskingspot-maintenance`, `baskingspot-new-repo`,
    `baskingspot-voice`.

**Where agents look** (each tool's documentation):

| Agent | Project | User |
|---|---|---|
| Amp | `.agents/skills/` | `~/.config/agents/skills/` |
| Codex, Cline, Zed, Warp | `.agents/skills/` | `~/.agents/skills/` |
| Cursor, OpenCode, Gemini CLI, GitHub Copilot | `.agents/skills/` | each its own (`~/.cursor/skills/`, `~/.config/opencode/skills/`, …) |
| pi | `.pi/skills/` and `.agents/skills/` (cwd up to the repository root) | `~/.pi/agent/skills/`, `~/.agents/skills/` |
| Claude Code | `.claude/skills/` | `~/.claude/skills/` |

(vercel-labs/skills' docs/agents.md for the first four rows, pi's
docs/skills.md for pi.)

So `.agents/skills/` reaches Amp and pi, the two agents the org's
repositories show, and most others. Claude Code is the exception.

**How vercel-labs/skills does it** (its docs, for comparison):
- `skills add <owner/repo | URL | path>` discovers `SKILL.md` at the
  root, under `skills/<name>/`, and under the agent directories.
- It keeps one copy in `.agents/skills/<name>/` and links each agent's
  own directory to it.
- It records sources in a checked-in `skills-lock.json`, with a GitHub
  tree SHA per skill folder.
- Global installs go to `~/.agents/skills/`, with a lock in
  `~/.agents/.skill-lock.json`.

**What bs already has:**
- Zig 0.17.1's package fetcher lives in the build runner, not the
  compiler: `lib/compiler/Maker/Fetch.zig`, behind `Maker.zig`'s `fetch`
  command (`cmdFetch`, L1696). It handles `git+https://` (with a ref or
  commit after `#`), tarball URLs, git bundles and local paths, computes
  the package hash, and stores the package as
  `<global cache>/p/<hash>.tar.gz`.
- `bs build` already compiles that Maker with bs. `bs fetch` is not
  wired yet (zigdoc-in-bs.md, section 5), but the binary is there.

Checked on this orb with bs's compiled Maker:
- `maker fetch ... git+https://github.com/baskingspot/skills` printed
  `N-V-__8AACfmBACwyFNpbkd2NP5reC0Ky2ysoXYNk1c25_Xw` in 0.54 s, and the
  package is `p/N-V-…_Xw.tar.gz`, 122 KB. A repository with no
  build.zig.zon fetches fine.
- With `#<full commit>` it gives the same hash.
- A short commit (`#6888cc2`) fails: `error: ref not found`.
- A local directory (`/tmp/skills`) fetches too, with its own hash.

## The design

### The command

```
bs skills add <source> [<skill>...]     install skills from a source
bs skills list                          installed skills, their sources and pins
bs skills update [<skill>...]           move pins to the source's newest commit
bs skills remove <skill>...
bs skills install                       restore every pinned skill (a fresh clone, CI)
```

`add` without skill names lists what the source offers and installs
nothing. That makes the choice explicit, which matters because a skill
is instructions an agent will follow.

It is a separate command, not an option of `bs init`. `bs init` stays
upstream's `zig init` (owner's decision 2), and a project adds skills
whenever it wants, not only at creation.

### Sources

- A shorthand: `baskingspot` is `git+https://github.com/baskingspot/skills`.
- GitHub shorthand: `owner/repo` is `git+https://github.com/owner/repo`.
- Anything `zig fetch` takes: `git+https://…[#ref]`, a tarball URL, a git
  bundle, a local path.
- `bs`: the skill built into the bs binary (below).

Inside a fetched package, skills are found where agents keep them:
- a root `SKILL.md`;
- `skills/<name>/SKILL.md`;
- `.agents/skills/<name>/SKILL.md`;
- `.pi/skills/<name>/SKILL.md`;
- `.claude/skills/<name>/SKILL.md`.

That covers both the skills repository and the org's project skills.
The frontmatter's `name` must match the directory, as `skills-ref
validate` requires, and a skill that fails this is refused with the
reason.

**Private sources.** Upstream's fetcher sends no credentials, so a
private GitHub repository such as baskingspot/internal cannot be fetched
by URL. A local checkout works as a path source:
`bs skills add ../internal baskingspot-voice`.

### Where skills go

- The project's `.agents/skills/<name>/`, as copies, meant to be
  committed. Agents without bs (in CI, in an orb, a teammate's editor)
  see them, and the repository says exactly what its agents load.
- `--claude` also writes `.claude/skills/<name>` as a relative symlink to
  the copy, for Claude Code.
- The project root is the directory of the nearest `build.zig.zon`, or
  the working directory when there is none.
- No user-level install in v1 (open question 4).

### Pinning and updates

The pins live in `.agents/skills.zon`, beside what they describe:

```zon
.{
    .sources = .{
        .baskingspot = .{
            .url = "git+https://github.com/baskingspot/skills#6888cc2…",
            .hash = "N-V-__8AACfmBACwyFNpbkd2NP5reC0Ky2ysoXYNk1c25_Xw",
            .ref = "main",
            .skills = .{
                .@"zig-017" = .{ .path = "skills/zig-017", .tree = "<hash of the installed files>" },
            },
        },
    },
}
```

- `url` and `hash` have the meaning of a build.zig.zon dependency's
  fields. `url` carries the full commit, since the fetcher refuses short
  ones.
- `ref` is what `update` follows.
- `tree` is a hash of the installed copy. `update` and `install` refuse
  to overwrite a skill someone edited (its tree no longer matches)
  unless given `--force`, and they say which files differ.
- `install` checks `<global cache>/p/<hash>.tar.gz` first and fetches
  only when it is missing, as a build does for a dependency with a hash.

The alternative, a field in build.zig.zon, is valid today. Upstream's
manifest parser ignores unknown top-level fields "so that we can add
fields in future zig versions" (`Maker/Package/Manifest.zig` L203-205).
But that same comment is the risk: a later Zig could claim the name. It
would also mix agent setup into the package every dependent downloads,
and editing it re-runs the build's configure step. (Open question 2.)

### How it fetches

There is no network code in bs. `bs skills add` and `update` run bs's
compiled Maker as a child, the way `bs build` runs it:

```
maker fetch --zig-lib=<lib> --zig=<bs> --global-cache=<global> --seed=<random> <url>
```

and read the hash from its stdout. `update` resolves `ref` by fetching
`git+https://…#<ref>`, and needs the commit the ref resolved to, for the
pin. `fetch` prints only the hash. So bs reads the commit from the
package's git metadata if the Maker keeps it, or else asks the remote
with one `git ls-remote`. Which one is settled when this is built. The
Maker is built once per bs binary (about 3 s), and any `bs build` has
usually done it already.

bs extracts the chosen skill directories from the `.tar.gz` with std's
`std.tar` and `std.compress.flate`. That is std's code, not network code.

### What bs ships

- **Nothing is installed by default.** Neither `bs init` nor a build
  touches `.agents/`.
- **One built-in skill, `bs`, embedded in the binary.** It covers how an
  agent should use bs:
  - `bs doc` and its forms;
  - the diagnostic format, its codes and `fix` lines;
  - the opt-in ziglint rules and the ignore comment;
  - `bs build` against `zig build`.

  `bs skills add bs` installs the version that matches the binary. Its
  pin is the bs version, and `update` refreshes it after a bs upgrade. It
  is written to baskingspot/skills' rules (one sentence of content, one
  of trigger, a body under 500 lines) and checked by `skills-ref
  validate` in bs's CI.
- **`baskingspot` as the one named source.** `zig-017` is the skill that
  matches bs's pinned Zig. Once `bs doc` lands, that skill can name
  `bs doc` where it names zigdoc today. That edit belongs to
  baskingspot/skills, not to bs.

### Cost

None for builds: nothing here runs unless `bs skills` is called.
- `add` costs the fetch: 0.54 s for baskingspot/skills here, mostly
  network.
- `install` with a warm global cache costs reading the `.tar.gz` and
  copying a few files, in milliseconds.

### Tests

- `test/skills/`: a local-path source fixture with a root skill, a
  `skills/` layout and a `.pi/skills/` layout. It covers `add`, `list`,
  `remove`, `install` from the pin, the refusal on an edited copy, and a
  name mismatch.
- Network fetches are not tested in CI. The fetcher is upstream's and is
  exercised by every `bs build` of a project with dependencies.

## Open questions for the owner

1. **The command's shape.** `bs skills add|list|update|remove|install`,
   or an option of `bs init`. *Recommendation: `bs skills`.* `bs init`
   stays upstream's, and skills are added over a project's life.
2. **Where the pins live.** `.agents/skills.zon`, or a `.skills` field in
   build.zig.zon. *Recommendation: `.agents/skills.zon`.* build.zig.zon
   accepts the field today, but a future Zig may claim the name, every
   dependent downloads it, and editing it reconfigures the build.
3. **Copies or links.** *Recommendation: copies in `.agents/skills/`,
   committed,* with `--claude` for a symlink in `.claude/skills/`. Agents
   without bs see the same skills, and review sees changes as diffs.
4. **A user-level install.** *Recommendation: not in v1.* Later, `-g`
   writes `~/.agents/skills/`, which pi, Codex and several others read
   (Amp reads `~/.config/agents/skills/`; user directories differ more
   than project ones), with its own `~/.agents/skills.zon`. A project's pinned skills are reproducible,
   while a user's are not.
5. **The shorthands.** `baskingspot` and GitHub's `owner/repo`.
   *Recommendation: both.* They are what agents type, and each expands to
   a URL the fetcher takes.
6. **The built-in `bs` skill.** *Recommendation: ship it in the binary,*
   installed only on request. It is the one skill whose content must
   match the installed bs, so it should come from bs.
7. **Skills that dependencies ship.** A library could ship a skill in its
   package (websocket's `rfc6455`), and `bs skills add --deps` could
   install the skills of the project's build.zig.zon dependencies,
   pinned by the dependency's own hash, with no second pin.
   *Recommendation: later.* It is a small step once `add` exists, but it
   needs a convention for which skills a library exports.
8. **Private sources.** *Recommendation: local paths only.* Credentials
   would mean bs's own network code, which the brief rules out.
