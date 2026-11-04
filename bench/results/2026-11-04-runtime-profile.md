# Where zap's generated code loses to ReleaseSafe (2026-11-04)

zap at main 4471cc7 (m7-moves; m7-slice0 lands after it), built ReleaseFast.
Upstream zig 0.17.0 `-OReleaseSafe` (LLVM). Amp orb, 4 vCPU, 7 GB.

Instruction counts come from callgrind (`--dump-instr --branch-sim
--cache-sim`), each executed instruction put in one category by its
disassembly. Upstream binaries for valgrind are built with
`-mcpu=x86_64_v3`, since native AVX-512 code does not run under valgrind; the
wall times use native builds. The orb has no hardware counters (`perf stat`
cannot count cycles), so stalls are estimated from ns per instruction and
from callgrind's simulated caches and branch predictor.

## Wall time

`bench/runtime.py` and `bench/realworld.py`, medians:

| Program | zap | Debug | ReleaseSafe | zap / RS | Ir zap / RS |
|---|---:|---:|---:|---:|---:|
| fib | 144 ms | 168 ms | 84 ms | 1.71× | 1.94× |
| sieve | 153 ms | 426 ms | 125 ms | 1.22× | 1.96× |
| sort | 220 ms | 487 ms | 92 ms | 2.39× | 4.75× |
| hash | 173 ms | 520 ms | 43 ms | 4.02× | 10.3× |
| nbody | 164 ms | 509 ms | 22 ms | 7.45× | 8.76× |
| fmt | 86 ms | 174 ms | 19 ms | 4.53× | 3.25× |
| vaxis | 565 ms | 888 ms | 230 ms | 2.46× | 2.40× (without rep) |
| zls-test | 889 ms | 1.43 s | 225 ms | 3.94× | |
| zig-fmt | 2.11 s | 3.93 s | | | |
| zig-sema | 5.94 s | 9.83 s | | | |

Upstream's release `zig` binary (ReleaseFast, with LLVM) takes 0.35 s for
zig-fmt and 0.64 s for zig-sema; the compiler cannot be built in ReleaseSafe
in 7 GB.

## Stalls

- Simulated D1 and LL misses are the same for zap and ReleaseSafe on every
  program: the extra loads and stores hit L1.
- zap's code runs at 0.08–0.14 ns per instruction, about as fast per
  instruction as ReleaseSafe's (0.06–0.24). The time gap is mostly the
  instruction count, except:
  - sieve is memory bound: twice the instructions cost 1.22× the time.
  - fmt is the reverse: 4.5× the time for 3.3× the instructions, from
    6.9 M simulated mispredicts against 0.9 M. At ~15 cycles each that is
    about a third of zap's run time, in `printIntAny`'s digit loop,
    `digitToChar`, and `Writer.write`.
  - sort's extra mispredicts (18.4 M against 6.7 M) are mostly the exits of
    `std.mem.swap`'s 4-iteration byte loop (`blockSwap`, `Context.swap`).

## Excess instructions by category

Millions of instructions, zap minus ReleaseSafe. valgrind counts every
iteration of a `rep movs`, so the rep row overstates its time.

| category | fib | sieve | sort | hash | nbody | fmt | vaxis |
|---|---:|---:|---:|---:|---:|---:|---:|
| calls, push/pop | +193 | +0 | +76 | +172 | +7 | +107 | +635 |
| mov reg-reg | +193 | +68 | +239 | +194 | +31 | +179 | +633 |
| stack loads/stores | +97 | +0 | +614 | +542 | +439 | +172 | +711 |
| other memory (incl. SSE) | -0 | -1 | +161 | +181 | +423 | -1 | -61 |
| lea | +24 | +110 | +185 | +62 | +31 | +22 | +255 |
| safety cmp+jcc | +48 | +76 | +120 | +66 | +8 | +52 | +103 |
| other cmp/test, jcc | +0 | +126 | +228 | +105 | +33 | +77 | +246 |
| jmp | +72 | +110 | +86 | +26 | +11 | +23 | +91 |
| alu, imm, extend, setcc | +72 | -9 | +209 | +312 | +55 | +84 | +295 |
| rep movs/stos | +1 | +51 | +26 | +37 | +1 | +14 | +4550 |
| total Ir zap / RS (M) | 1450 / 749 | 1082 / 551 | 2463 / 519 | 1879 / 183 | 1170 / 134 | 1052 / 323 | 9529 / 2072 |
| mispredicts zap / RS (M) | 11.4 / 4.7 | 0.0 / 0.0 | 18.4 / 6.7 | 1.5 / 1.4 | 3.0 / 0.0 | 6.9 / 0.9 | 22.3 / 4.8 |

The zap-built compiler (`zig fmt --check` over parts of std) and zls's test
suite have no ReleaseSafe profile; their own mix is calls and push/pop
12–15%, mov reg-reg 11–13%, stack loads and stores 16%, rep 3% (zig) and 22%
(zls). Half of zls-test's instructions are std's DWARF unwinder
(`SelfUnwinder.nextInner`, `dwarfRegisterBytes`, `StackIterator.next`),
which the testing allocator runs on every allocation and free; upstream
uses the same unwinder.

## Causes, per program

- **fib**: callee-saved push/pop on every call (+193); register copies
  around the call (+193); the error return trace pointer (rax) stored at
  entry and reloaded before each call (+97); a jump to the shared epilogue
  (+72); overflow checks on `n - 1` and `n - 2` that `n >= 2` proves (+48).
  Swings of ±10% between builds are code placement.
- **sieve**: address computed with `lea` and then accessed instead of a
  folded addressing mode (+110); the back edge is a `jmp` to the loop test
  (+110); bounds checks inside the loops (+76 jcc, as many cmp); slice
  lengths copied between registers.
- **sort**: `std.mem.swap` on u32s is a byte loop with a runtime `4 == 4`
  length check and four mispredict-prone iterations; pdq's `Context.swap`
  and the comparator are calls, not inlined; slice arguments spilled and
  reloaded (448 M stack loads against 6 M); bounds checks (+120).
- **hash**: `Wyhash.hash` runs 312 instructions per call. Its 48-byte state
  is copied field by field through memory; its length-generic paths run for
  a constant length of 8 (`cmp %rbx,%rbx; ja`, `mov $1; xor $1; test`, `4 >
  len` checks); the 64×64→128 multiply goes through memory with three
  `imul`s, and `>> 64` through the generic wide shift. `Wyhash.init` and
  `HashMap.capacity` are calls.
- **nbody**: `advance()`'s vec3 temporaries live on the stack: 439 M stack
  loads and stores and 356 M SSE memory operations, against 37 M. ReleaseSafe
  also vectorizes.
- **fmt**: `digitToChar` is a call; register copies (+179); the
  mispredicts above. `Writer.write` stays on its buffered fast path: there
  are no per-call indirect calls (10 in the whole run), so devirtualization
  would not change fmt.
- **vaxis**: calls into small std and vaxis functions (`appendSlice*`,
  `ensureUnusedCapacity`, `sliceAsBytes`, `eql`, `utf8.decode`); copies;
  stack traffic. Of the rep instructions, 1.9 G are
  `precomputedGraphemeBreak` copying its 2205-byte comptime table to the
  stack on every call to pass it by value to `table.get` (upstream Debug
  copies it twice), and 2 G are 136-byte `Cell` copies into temporaries and
  argument slots.

## Order of the queue

By the gap each step closes, weighted by wall time, and by what later steps
need:

1. **64-byte function alignment.** Small, and it takes the code-placement
   noise out of every later measurement (fib's ±10%).
2. **Rewrite-rule table**, with constant folding of compares and boolean
   ops and x86 addressing-mode folding as its first rules (lea +24–255 M
   everywhere; hash's constant tests). The inlining cost model only pays
   when the specialized branches fold, and phiopt and memcombine are rules
   in it.
3. **Struct splitting (SROA)** of non-escaping aggregates: nbody's gap is
   mostly this; hash's state is 48 bytes, so the limit should be all-scalar
   fields rather than 32 bytes. Slices and error unions belong here too:
   the SSA keeps pairs in memory (no pair class yet), behind much of
   sort's and vaxis's stack traffic.
4. **Inlining cost model** for constant and comptime-callback arguments:
   hash (`Wyhash.hash` at length 8, `init`, `capacity`), sort
   (`Context.swap`, comparators), fmt (`digitToChar`), vaxis's small calls.
5. **Register coalescing and callee-saved saves** (not on the list): mov
   reg-reg is 11–13% of every real program and +179–633 M on the
   benchmarks; fib's push/pop.
6. **branchelim and phiopt**: fmt's mispredicts, a third of its time.
7. **prove/BCE**: safety cmp+jcc is 5–10% of instructions, but they are
   well predicted, so the time win is smaller than the count.
8. **Loop rotation**, with the return block duplicated into its jumps
   (fib's epilogue jump).
9. **memcombine**, together with full unrolling of loops with a small
   constant trip count (not on the list): sort's `std.mem.swap` needs both.
10. **Invariant load hoisting, CSE, tighten**: sieve and sort, small.
11. **Induction-variable stepping**: sieve, small.
12. **DSE**: the 0xaa fills zap emits barely show (rep stos is
    std's own `@memset(undefined)` in allocators).
13. **Devirtualization**: no program in this set makes per-call indirect
    calls (fmt 10, vaxis 0.02 M, zls 0.3 M).

Three items the profile shows that are not on the list:

- 128-bit multiply and constant shifts by 64 in register pairs (hash).
- Passing a comptime-known aggregate by value as a reference to its
  constant instead of copying it (vaxis's grapheme table).
- Copying a large value straight to its destination instead of through a
  temporary (vaxis's `Cell`, the unwinder's 136- and 352-byte contexts in
  zls).
