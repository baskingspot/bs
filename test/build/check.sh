#!/bin/sh
# `zig build test-build`: builds test/build/hello with `zap build` from a
# copy in a scratch directory and checks what the build runner reports.
#   $1 zap  $2 test/build/hello  $3 scratch directory
#   $4 the build web client zap embeds (build-web.wasm)
set -eu
unset ZIG_LOCAL_CACHE_DIR ZIG_LIB_DIR
rm -rf "$3"
mkdir -p "$3"
zap=$(realpath "$1") src=$(realpath "$2") work=$(realpath "$3") wasm=$(realpath "$4")
cp -r "$src" "$work/hello"
cd "$work/hello"

fail() {
    echo "zap build check failed: $1" >&2
    [ -f "$work/log" ] && cat "$work/log" >&2
    exit 1
}
expect() { grep -qF -- "$1" "$work/log" || fail "expected '$1'"; }

# A full build: the configurer, the exe (which asks for LLVM), the install.
"$zap" build --summary all >"$work/log" 2>&1 || fail "zap build"
[ "$(./zig-out/bin/hello x 2>&1)" = "hello 1" ] || fail "zig-out/bin/hello prints 'hello 1'"
[ "$(ar t zig-out/lib/libanswer.a)" = "lib.o" ] || fail "zig-out/lib/libanswer.a holds lib.o"
grep -q hello_answer zig-out/lib/libanswer.a || fail "libanswer.a's index names hello_answer"

# Nothing changed: the compile step is a cache hit.
"$zap" build --summary all >"$work/log" 2>&1 || fail "zap build (no change)"
expect "compile exe hello debug native cached"

# Run and test steps; the test runner speaks the build runner's protocol.
"$zap" build run >"$work/log" 2>&1 || fail "zap build run"
expect "hello 2"
"$zap" build test --summary all >"$work/log" 2>&1 || fail "zap build test"
expect "run test 4 pass (4 total)"

# A C header translated to Zig (`zap translate-c --listen=-`), in a program
# that links glibc. A header edit translates again; a header touched but
# unchanged is a cache hit.
"$zap" build shape --summary all >"$work/log" 2>&1 || fail "zap build shape"
expect "triangle 3 30"
echo '#define SHAPE_SIDES 4' >c/sides.h
"$zap" build shape >"$work/log" 2>&1 || fail "zap build shape (header edit)"
expect "triangle 4 40"
touch c/shape.h
"$zap" build shape --summary all >"$work/log" 2>&1 || fail "zap build shape (header touched)"
expect "translate-c cached"

# Fuzzing: the runner rebuilds the tests with -ffuzz, zap instruments them
# and links upstream's fuzzer, which finds the crash planted in "fuzz".
# As upstream's, the runner exits 0 after reporting a crash. The runner
# passes --seed to the fuzzer, and a fresh run with a fixed seed takes the
# same path every time. Seeds 1 and 3 find the crash in 0.68M and 0.78M
# runs; across 60 other seeds it took 0.1M to 4.9M runs, and 5M missed
# once. The second seed covers a change that moves the first one's path
# past the limit.
for seed in 1 3; do
    rm -rf .zig-cache/f .zig-cache/v
    "$zap" build test --fuzz=5M --seed=$seed >"$work/log" 2>&1 || true
    grep -qF "panic: planted crash" "$work/log" && break
done
expect "panic: planted crash"
expect "input saved to '.zig-cache/f/crash'"
# Per-module -fno-fuzz: the runner passes greet's `.fuzz = false`, so the
# fuzz test's own branches store to coverage counters and greet.pick's
# do not.
bin=$(sed -n "s|^failed command: \(\./\.zig-cache/o/[0-9a-f]*/test\) .*|\1|p" "$work/log")
[ -n "$bin" ] || fail "the log names the fuzz test binary"
stores() {
    objdump -d --no-show-raw-insn "$bin" | awk -v f="^<$1>:\$" '$2 ~ f { on = 1; next } /^$/ { on = 0 } on' |
        grep -c 'movb   \$0x1,.*(%rip)' || true
}
[ "$(stores 'main\\.test\\.fuzz.*\\.testOne')" -gt 0 ] || fail "the fuzz test's branches store to coverage counters"
[ "$(stores 'greet\\.pick')" -eq 0 ] || fail "greet.pick (-fno-fuzz) stores to no coverage counter"

# Unlimited fuzzing serves the web UI; its client is the wasm zap embeds,
# built with upstream zig ($4).
setsid "$zap" build test --fuzz --webui=127.0.0.1:0 >"$work/web" 2>&1 &
web=$!
trap 'kill -- -$web 2>/dev/null || true' EXIT
port=
for _ in $(seq 300); do
    port=$(sed -n 's|.*web interface listening at http://127\.0\.0\.1:\([0-9]*\)/.*|\1|p' "$work/web")
    [ -n "$port" ] && break
    sleep 0.2
done
[ -n "$port" ] || { cp "$work/web" "$work/log"; fail "the web UI listens"; }
curl -sf -o "$work/main.wasm" "http://127.0.0.1:$port/main.wasm" || fail "GET /main.wasm"
[ "$(sha256sum <"$work/main.wasm")" = "$(sha256sum <"$wasm")" ] || fail "the served main.wasm is zap's embedded client"
kill -- -$web
trap - EXIT

# Docs: upstream's viewer, its page, and the modules' sources.
"$zap" build docs >"$work/log" 2>&1 || fail "zap build docs"
for f in index.html main.js main.wasm sources.tar; do [ -s "zig-out/docs/$f" ] || fail "zig-out/docs/$f"; done
tar tf zig-out/docs/sources.tar | grep -qx test/main.zig || fail "sources.tar holds test/main.zig"

# `zap env` for tools that ask the compiler (zls's tests).
"$zap" env | grep -q '\.lib_dir = ' || fail "zap env prints .lib_dir"
# `zap ast-check` on stdin, as zls runs it for unused-variable fixes.
printf 'fn f() void {\n    const y = 1;\n}\n' | "$zap" ast-check --color off 2>"$work/log" && fail "zap ast-check fails on an unused constant"
expect "<stdin>:2:11: error: unused local constant"

# An edit: the output changes in place.
sed -i 's/"hello"/"howdy"/' src/greet.zig
"$zap" build >"$work/log" 2>&1 || fail "zap build (edit)"
[ "$(./zig-out/bin/hello 2>&1)" = "howdy 0" ] || fail "the edited hello prints 'howdy 0'"

# A compile error travels as an error bundle, with zap's code.
sed -i 's/args.len - 1/args.len - "x"/' src/main.zig
if "$zap" build >"$work/log" 2>&1; then fail "zap build succeeded with a compile error"; fi
expect "src/main.zig:6:"
expect "error: [type-mismatch]"
sed -i 's/args.len - "x"/args.len - 1/' src/main.zig

# Candidates and the migration hint travel as notes without a location.
sed -i 's/std.debug.print/std.io.print/' src/main.zig
if "$zap" build >"$work/log" 2>&1; then fail "zap build succeeded with std.io"; fi
expect "error: [no-member] root source file struct 'std' has no member named 'io'"
expect "note: candidates: Io"
expect "note: hint: std.io is now std.Io"
sed -i 's/std.io.print/std.debug.print/' src/main.zig

# A step zap does not build fails with a diagnostic, not a crash.
if "$zap" build -Doptimize=ReleaseFast >"$work/log" 2>&1; then fail "zap build succeeded in ReleaseFast"; fi
expect "error: [unsupported] zap builds only Debug ('-Ofast')"

# build.zig itself fails to compile.
line=$(($(wc -l <build.zig) + 1))
echo "fn unused() void { const y = 1; }" >>build.zig
if "$zap" build >"$work/log" 2>&1; then fail "zap build succeeded with a broken build.zig"; fi
expect "build.zig:$line:26: error: [unused] unused local constant"
