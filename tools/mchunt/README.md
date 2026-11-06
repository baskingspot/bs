# mchunt: differential miscompile hunter

`tools/mchunt` generates random, well-defined Zig programs, compiles each
with upstream zig 0.17.1 (Debug, the oracle) and with bs, runs both, and
compares what they print and how they exit. It looks for the miscompiles
`test/behavior`, std's tests and `test/c_abi` miss: odd integer widths,
wrapping, saturating and checked arithmetic, shifts, packed and extern
structs, arrays, slices, optionals, error unions, switches (including
labeled-switch state machines), loops with constant and variable trip
counts, inline functions and `inline for`, comptime calls of the same
functions the program also runs, and pointers to locals and globals,
aliased.

```sh
zig build -Doptimize=ReleaseFast
python3 tools/mchunt/hunt.py                         # hunt with zig-out/bin/bs until ^C
python3 tools/mchunt/hunt.py --follow --hours 8      # bs from origin/main, rebuilt when it moves
python3 tools/mchunt/hunt.py --one 1234              # one seed, with its outcomes
python3 tools/mchunt/hunt.py --file p.zig            # one saved program, with its outcomes
python3 tools/mchunt/hunt.py --ref-env BS_PROVE=off # bs against bs with a pass off; no upstream
python3 tools/mchunt/gen.py 1234 > p.zig             # just the program
python3 tools/mchunt/hunt.py --kind vector --mcpu x86_64_v2   # @Vector programs (vgen.py)
python3 tools/mchunt/hunt.py --kind vector --target aarch64-linux  # under qemu
python3 tools/mchunt/reduce.py tools/mchunt/.work/found/miscompile-1234
python3 tools/mchunt/reduce.py p.zig --bad bs --control bs-noinline > small.zig
```

## Configurations

Every program runs under upstream `zig` Debug and three bs
configurations: `bs` (Debug), `bs-safe` (`-OReleaseSafe`) and
`bs-noinline` (`BS_INLINE=0`). A mismatch also runs upstream
`-OReleaseSafe` (LLVM; ~15 s a program, so only then) and `bs` with
`BS_INLINE_SAFE=1`; when ReleaseSafe's optimizer crashes or times out
on the program, upstream Debug with `-fllvm` stands in for it. Which configurations disagree says where to look:
only `bs` and `bs-safe` with inlining on points at the inliner or at
the rewrite rules that run after it; every bs configuration points at
lowering, register allocation or Sema.

The classes of finding (`.work/found/<class>-<seed>/`):

- `miscompile`: a bs configuration compiles the program and prints or
  exits differently from upstream, and upstream ReleaseSafe agrees with
  upstream Debug.
- `bs-reject` / `bs-crash`: bs reports an error for, or crashes on, a
  program upstream compiles.
- `upstream-debug-bug`: upstream Debug disagrees with upstream
  ReleaseSafe, and bs agrees with ReleaseSafe; not bs's bug.
- `oracle-split`: upstream disagrees with itself and bs with both.

Seeds whose program upstream rejects (a comptime overflow the generator
did not foresee) are discarded; `upstream-signal` and `upstream-timeout`
count programs that upstream Debug's binary crashed or hung on.

`harness-error` counts runs that cannot be trusted: less than 2 GB free
for an hour, an empty or all-zero program, a failed write, or a binary
that is not an executable (a full disk leaves zeroed binaries whose
identical failures would otherwise compare equal). It is never a pass;
after three, hunt.py stops with exit status 3.

With `--ref-env VAR=VALUE`, bs under that environment replaces
upstream as the oracle (`bs-ref` in reports): a pass switched off must
not change any program's output or panic. With upstream out of the loop
a program takes a fraction of the time, and upstream's own backend bugs
drop out.

## Outcomes

A program prints `ck <n> <checksum>` after each call from `main` and
`ck end <checksum>` at exit, on stderr. The compared outcome is those
lines up to a panic, the panic message (`panic: integer overflow`), and
the exit status; stack traces are not compared.

## Well-definedness

The generator (`gen.py`) avoids what Zig leaves unspecified or undefined
in safe builds: every variable is initialized, pointers never outlive
their target, an aggregate passed by value or used as a result location
is never reachable through another argument or a global the callee
touches, loops are bounded and calls form a DAG. Checked operations are
mostly made safe by construction (widened or halved operands, guards,
masked indices, nonzero divisors); about one in a hundred is left
unguarded, so a safety check that fires must fire the same way in both
compilers. Those are only emitted where an operand is certainly
runtime-known, since at comptime they would be compile errors, and a
function containing one is never called at comptime.

## Vector programs and targets

`--kind vector` generates programs with `vgen.py` instead: each test
function builds `@Vector`s of every length bs lowers differently (1, 3,
5, 17, 33 and whole 16-, 32- and 64-byte registers) and element type
(u1/i1 to u64, u24, i65, f16, f32, f64, bool) from runtime inputs, and
runs them through lane ops, wrapping and saturating arithmetic, shifts
by splats and by vectors, compares, select, shuffles with negative and
undefined mask lanes, `@reduce` of every op, casts and bitcasts, memory
(element stores, pointers, globals, struct fields, unaligned byte
buffers), calls, and comptime calls of the same helpers. A checkpoint
follows every statement (`ck <test>.<statement>`), so the first
mismatching line names the statement. Float results hash every NaN
alike and @min/@max add +0.0, since the backends differ on NaN payloads
and on which zero a tie returns; bitcasts reshape only byte-sized lanes,
since upstream's backends lay out other reshapes differently.

Upstream's backends are weaker oracles on vectors than on scalars. When
upstream Debug's binary crashes, ReleaseSafe (else `-fllvm`) is the
program's oracle (`oracle` in `meta.json`). When LLVM rejects the
program too, a mismatch is `unconfirmed` rather than `miscompile`:
upstream Debug alone is wrong too often (`-|` on i32 lanes at
`-mcpu=x86_64_v2`, for one).

`--target` and `--mcpu` add `-target` and `-mcpu` to every
configuration, upstream and bs alike; aarch64 binaries on an x86_64
host run under `qemu-aarch64-static -cpu cortex-a53`. Both are saved in
a finding's `meta.json`, so reduction, rechecks and `bisect_bs.py` use
them too.

## Reduction

`reduce.py` keeps the finding's property: upstream compiles and runs the
program to an exit or a panic, the failing bs configuration disagrees
with the same kinds of outcome, and a configuration that agreed at first
(the control, `bs-noinline` when inlining is implicated) keeps
agreeing, so reduction stays on one bug. It deletes statements and
declarations, hoists block bodies, and replaces expressions with an
operand, a branch, a builtin's argument or a literal, fixing the unused
and never-mutated errors Zig reports after each edit. A 300-line program
typically reduces to 10–30 lines in 10–30 minutes.

## Following main and branches

`--follow` builds bs from `origin/main` in a worktree under
`.work/tree` (binaries cached per commit in `.work/bs/<sha>/`), checks
for a new `origin/main` every 10 minutes, and when it moves rebuilds,
rechecks every saved finding (marking fixed ones with `fixed_in` in
their `meta.json`) and hunts with the new binary.

With `--branches 'm7-*'`, every head of a matching branch that appears
or moves while the hunter runs (the heads present on its first run are
the baseline; `--branches-now` takes them too) gets a campaign of
`--branch-programs` programs (2500 by default) before main resumes.
A finding on a branch is run again with bs from main: if main agrees
with upstream it is the branch's regression (`branch-miscompile` and so
on), and its reduction keeps main agreeing. Campaign results are
appended to `.work/campaigns.log`.

```sh
python3 tools/mchunt/hunt.py --follow --branches 'm7-*' --skip-branch m7-inline-cost
```
