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
python3 tools/mchunt/reduce.py tools/mchunt/.work/found/miscompile-1234
python3 tools/mchunt/reduce.py p.zig --bad bs --control bs-noinline > small.zig
```

## Configurations

Every program runs under upstream `zig` Debug and three bs
configurations: `bs` (Debug), `bs-safe` (`-OReleaseSafe`) and
`bs-noinline` (`BS_INLINE=0`). A mismatch also runs upstream
`-OReleaseSafe` (LLVM; ~15 s a program, so only then) and `bs` with
`BS_INLINE_SAFE=1`. Which configurations disagree says where to look:
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
