#!/bin/sh
# `zig build test-build`: builds test/build/hello with `bs build` from a
# copy in a scratch directory and checks what the build runner reports.
#   $1 bs  $2 test/build/hello  $3 scratch directory
#   $4 the build web client bs embeds (build-web.wasm)
#   $5 the part to check, each its own build step: build, which compiles
#      the build runner into the global cache, then shape, fuzz and misc
#      at once, each in its own copy
set -eu
unset ZIG_LOCAL_CACHE_DIR ZIG_LIB_DIR
rm -rf "$3"
mkdir -p "$3"
bs=$(realpath "$1") src=$(realpath "$2") work=$(realpath "$3") wasm=$(realpath "$4") part=$5
cp -r "$src" "$work/hello"
cd "$work/hello"

fail() {
    echo "bs build check failed: $1" >&2
    [ -f "$work/log" ] && cat "$work/log" >&2
    exit 1
}
expect() { grep -qF -- "$1" "$work/log" || fail "expected '$1'"; }

case $part in
build)
# A full build: the configurer, the exe (which asks for LLVM), the install.
"$bs" build --summary all >"$work/log" 2>&1 || fail "bs build"
[ "$(./zig-out/bin/hello x 2>&1)" = "hello 1" ] || fail "zig-out/bin/hello prints 'hello 1'"
[ "$(ar t zig-out/lib/libanswer.a)" = "lib.o" ] || fail "zig-out/lib/libanswer.a holds lib.o"
grep -q hello_answer zig-out/lib/libanswer.a || fail "libanswer.a's index names hello_answer"

# Nothing changed: the compile steps are cache hits, the shared library's
# too, from its inputs record.
"$bs" build --summary all >"$work/log" 2>&1 || fail "bs build (no change)"
expect "compile exe hello debug native cached"
expect "compile lib shared debug native cached"
# A source the shared library reads changes: it compiles again. Touched
# without a change, it is a hit.
printf '\nexport fn hello_more() u32 {\n    return 1;\n}\n' >>src/lib.zig
"$bs" build --summary all >"$work/log" 2>&1 || fail "bs build (library edit)"
expect "compile lib shared debug native success"
nm -D zig-out/lib/libshared.so | grep -q hello_more || fail "libshared.so exports hello_more"
touch src/lib.zig
"$bs" build --summary all >"$work/log" 2>&1 || fail "bs build (library touched)"
expect "compile lib shared debug native cached"

# Run and test steps; the test runner speaks the build runner's protocol.
"$bs" build run >"$work/log" 2>&1 || fail "bs build run"
expect "hello 2"
"$bs" build test --summary all >"$work/log" 2>&1 || fail "bs build test"
expect "run test 4 pass (4 total)"
;;

shape)
# A C header translated to Zig (`bs translate-c --listen=-`), in a program
# that links glibc. A header edit translates again; a header touched but
# unchanged is a cache hit.
"$bs" build shape --summary all >"$work/log" 2>&1 || fail "bs build shape"
expect "triangle 3 30"
echo '#define SHAPE_SIDES 4' >c/sides.h
"$bs" build shape >"$work/log" 2>&1 || fail "bs build shape (header edit)"
expect "triangle 4 40"
touch c/shape.h
"$bs" build shape --summary all >"$work/log" 2>&1 || fail "bs build shape (header touched)"
expect "translate-c cached"
;;

fuzz)
# Fuzzing: the runner rebuilds the tests with -ffuzz, bs instruments them
# and links upstream's fuzzer, which finds the crash planted in "fuzz".
# As upstream's, the runner exits 0 after reporting a crash. The runner
# passes --seed to the fuzzer, and a fresh run with a fixed seed takes the
# same path every time. Seeds 1 and 3 find the crash in 0.68M and 0.78M
# runs; across 60 other seeds it took 0.1M to 4.9M runs, and 5M missed
# once. The second seed covers a change that moves the first one's path
# past the limit.
for seed in 1 3; do
    rm -rf .zig-cache/f .zig-cache/v
    "$bs" build test --fuzz=5M --seed=$seed >"$work/log" 2>&1 || true
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
    # shellcheck disable=SC2016 # awk's program, not the shell's
    objdump -d --no-show-raw-insn "$bin" | awk -v f="^<$1>:\$" '$2 ~ f { on = 1; next } /^$/ { on = 0 } on' |
        grep -c 'movb   \$0x1,.*(%rip)' || true
}
[ "$(stores 'main\\.test\\.fuzz.*\\.testOne')" -gt 0 ] || fail "the fuzz test's branches store to coverage counters"
[ "$(stores 'greet\\.pick')" -eq 0 ] || fail "greet.pick (-fno-fuzz) stores to no coverage counter"

# Unlimited fuzzing serves the web UI; its client is the wasm bs embeds,
# built with upstream zig ($4). The background job opens its redirect
# after the fork, so the log is created first: the loop below could
# otherwise read it before it exists (sed's exit 2 ends the script).
: >"$work/web"
setsid "$bs" build test --fuzz --webui=127.0.0.1:0 >"$work/web" 2>&1 &
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
[ "$(sha256sum <"$work/main.wasm")" = "$(sha256sum <"$wasm")" ] || fail "the served main.wasm is bs's embedded client"
kill -- -$web
trap - EXIT
;;

misc)
# Docs: upstream's viewer, its page, and the modules' sources.
"$bs" build docs >"$work/log" 2>&1 || fail "bs build docs"
for f in index.html main.js main.wasm sources.tar; do [ -s "zig-out/docs/$f" ] || fail "zig-out/docs/$f"; done
tar tf zig-out/docs/sources.tar | grep -qx test/main.zig || fail "sources.tar holds test/main.zig"

# `bs env` for tools that ask the compiler (zls's tests).
"$bs" env | grep -q '\.lib_dir = ' || fail "bs env prints .lib_dir"
# `bs ast-check` on stdin, as zls runs it for unused-variable fixes.
printf 'fn f() void {\n    const y = 1;\n}\n' | "$bs" ast-check --color off 2>"$work/log" && fail "bs ast-check fails on an unused constant"
expect "<stdin>:2:11: error: unused local constant"

# A custom test runner imports the modules the tested module does, as
# upstream's.
mkdir "$work/runner"
printf 'pub const n = 7;\n' >"$work/runner/m.zig"
printf 'test {}\n' >"$work/runner/t.zig"
printf 'const m = @import("m");\npub fn main() u8 {\n    return if (m.n == 7) 0 else 1;\n}\n' >"$work/runner/r.zig"
(cd "$work/runner" && "$bs" test --dep m -Mroot=t.zig -Mm=m.zig --test-runner r.zig) >"$work/log" 2>&1 || fail "bs test with a custom runner importing the tested module's import"

# An edit: the output changes in place.
sed -i 's/"hello"/"howdy"/' src/greet.zig
"$bs" build >"$work/log" 2>&1 || fail "bs build (edit)"
[ "$(./zig-out/bin/hello 2>&1)" = "howdy 0" ] || fail "the edited hello prints 'howdy 0'"

# A compile error travels as an error bundle, with bs's code.
sed -i 's/args.len - 1/args.len - "x"/' src/main.zig
if "$bs" build >"$work/log" 2>&1; then fail "bs build succeeded with a compile error"; fi
expect "src/main.zig:6:"
expect "error: [type-mismatch]"
sed -i 's/args.len - "x"/args.len - 1/' src/main.zig

# Candidates and the migration hint travel as notes without a location.
sed -i 's/std.debug.print/std.io.print/' src/main.zig
if "$bs" build >"$work/log" 2>&1; then fail "bs build succeeded with std.io"; fi
expect "error: [no-member] root source file struct 'std' has no member named 'io'"
expect "note: candidates: Io"
expect "note: hint: std.io is now std.Io"
sed -i 's/std.io.print/std.debug.print/' src/main.zig

# ReleaseSafe: -Osafe on the root module, which greet inherits.
"$bs" build run -Doptimize=ReleaseSafe >"$work/log" 2>&1 || fail "bs build run in ReleaseSafe"
expect " 2 safe"

# ReleaseFast and ReleaseSmall: bs's one code generation without safety
# checks, so a bare union has no safety tag, as upstream's.
"$bs" build run -Doptimize=ReleaseFast >"$work/log" 2>&1 || fail "bs build run in ReleaseFast"
expect " 2 fast untagged"
"$bs" build run -Doptimize=ReleaseSmall >"$work/log" 2>&1 || fail "bs build run in ReleaseSmall"
expect " 2 small untagged"

# build.zig itself fails to compile.
line=$(($(wc -l <build.zig) + 1))
echo "fn unused() void { const y = 1; }" >>build.zig
if "$bs" build >"$work/log" 2>&1; then fail "bs build succeeded with a broken build.zig"; fi
expect "build.zig:$line:26: error: [unused] unused local constant"
;;
*)
    fail "unknown part '$part'"
    ;;
esac
