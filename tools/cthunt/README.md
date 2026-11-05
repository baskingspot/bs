# cthunt: differential hunter for comptime evaluation and Sema

`tools/cthunt` generates random programs that compute values at comptime,
compiles each with upstream zig 0.17.1 (the oracle) and with bs, and
compares which parts each compiler rejects and, for the parts upstream
accepts, the values the program prints at run time. It is mchunt's
counterpart for the front half of the compiler: mchunt looks for
miscompiles of runtime code, cthunt for Sema and comptime evaluator bugs.

```sh
zig build -Doptimize=ReleaseFast
python3 tools/cthunt/hunt.py                     # hunt with zig-out/bin/bs until ^C
python3 tools/cthunt/hunt.py --count 500 --jobs 3 --seed 10000
python3 tools/cthunt/hunt.py --one 1234          # one seed, with its outcomes
python3 tools/cthunt/hunt.py --file p.zig        # one saved program, with its outcomes
python3 tools/cthunt/hunt.py --recheck           # rerun every saved finding
python3 tools/cthunt/gen.py 1234 > p.zig         # just the program
```

## Programs

A program is 8 to 16 independent tests. Each is a declaration `tN`
computed at comptime, wrapped as `// test N kind` … `// end N`, with a
`comptime { _ = tN; }` block of its own so that upstream reports every
test's errors, not only the first one main reaches. `main` prints
`tN <value>` for each test (a float also prints its bits, except a
NaN's, whose sign and payload are unspecified).

The kinds of test (`gen.py`, `Gen.KINDS`): integer and float arithmetic
at edge widths with wrapping, saturating and checked operators
(`t_arith`); a helper function with loops, switches and `inline for`
called many times, so that bs's comptime evaluator lowers it
(`t_fn_eval`); `@bitCast` and `@ptrCast` of aggregates and stores
through cast pointers (`t_bitcast`, `t_ptrcast`); packed structs and
unions (`t_packed`, `t_union`); slices and pointers into comptime arrays
and nested aggregates (`t_slices`, `t_memory`); optionals and error
unions (`t_opt_err`); `@typeInfo` and `@Int`/`@Struct`/`@Enum` round
trips (`t_typeinfo`); generic functions and `anytype` (`t_generic`);
strings (`t_strings`); vectors (`t_vector`); std code run at comptime:
sorting, parsing, formatting, hashing (`t_stdlib`); labeled switch
`continue`, recursion, `defer` and `errdefer` (`t_control`); packed
structs and unions of odd widths with explicit backing integers, enums
and bit pointers (`t_packed_odd`); error sets, their merges and
`@intFromError`/`@errorFromInt` round trips (`t_errors`); structs,
enums, unions and tuples rebuilt from `@typeInfo` (`t_reify`); tuples
(`t_tuples`); slices of slices (`t_slices2`); peer types from
`@TypeOf(a, b, ...)` and each peer coerced to it (`t_peer`);
`std.fmt.comptimePrint` of integers and floats (`t_fmt`); huge
`comptime_int` and `comptime_float` values and their conversions
(`t_comptime_num`); `@typeName` of generic instances (`t_typename`);
`StaticStringMap`, `EnumArray`, `EnumSet`, tokenizers,
`readInt`/`writeInt` and hashes (`t_std2`); many-pointer arithmetic,
`@memmove`/`@memset` and reinterpreting bytes through pointers
(`t_ptr_arith`); `inline else` over unions, enums, error sets and ranges
(`t_inline_switch`); recursive functions and types (`t_recursion`); and
destructuring of comptime-built tuples (`t_destructure`). A test is a
constant printed by `main`, or, for code that must run at run time
(`t_destructure`'s runtime half), a function `main` calls.

Programs are meant to be well defined, but a test may hit a comptime
error upstream reports (an overflow, the branch quota): each test has a
risk level that bounds how often it does something that can fail. Such
a test is still compared: bs must reject it too.

## Configurations

Every program compiles under upstream `zig` and three bs configurations:
`bs` as it is, `bs-walk` (`BS_COMPTIME_EVAL=0`: the ZIR walker only) and
`bs-eval1` (`BS_COMPTIME_EVAL=1`: the comptime evaluator takes every
function after one walker run). A finding that only `bs-eval1` shows is
an evaluator bug that `bs` reaches only after enough calls; one that all
three show is in the walker or in Sema proper.

## Findings

Saved in `.work/found/<class>-<seed>[-tN]/` with the whole program
(`orig.zig`), the failing test alone (`test.zig`) and every
configuration's outcome (`meta.json`). The classes:

- `bs-reject` / `bs-accept`: bs rejects a test upstream accepts, or
  accepts one upstream rejects.
- `wrong-value`: both accept a test and bs prints a different value.
- `bs-crash` / `bs-timeout`: bs crashes or hangs on the program.
- `bs-run-fail`: the program bs built crashed or failed at run time.

Each finding has a signature of its class, kind, failing configurations
and normalized error message; the hunt saves every finding, logs the
first of each signature, and counts them all in its summary. A
`wrong-value` whose comptime value is right but whose run time result
is not is a backend bug; route it to whoever owns the backend.

## Known noise

- NaN sign and payload differ between compilers; the hunter prints no
  bits for a NaN and normalizes `-nan` to `nan`.
- A many pointer prints its address (`u8@1290b7`), which the hunter
  normalizes to `u8@addr`; error values' integers differ between
  compilers, so tests print only their relations.
- Upstream folds f80 `@exp`, `@exp2`, `@log`, `@log2` and `@log10`
  with its host's libm (musl's x87 code), which can differ in the last
  bit from compiler_rt and so from upstream's own run time result; the
  generator does not emit them for f80.
