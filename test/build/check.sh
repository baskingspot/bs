#!/bin/sh
# `zig build test-build`: builds test/build/hello with `zap build` from a
# copy in a scratch directory and checks what the build runner reports.
#   $1 zap  $2 test/build/hello  $3 scratch directory
set -eu
unset ZIG_LOCAL_CACHE_DIR ZIG_LIB_DIR
rm -rf "$3"
mkdir -p "$3"
zap=$(realpath "$1") src=$(realpath "$2") work=$(realpath "$3")
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

# Nothing changed: the compile step is a cache hit.
"$zap" build --summary all >"$work/log" 2>&1 || fail "zap build (no change)"
expect "compile exe hello debug native cached"

# Run and test steps; the test runner speaks the build runner's protocol.
"$zap" build run >"$work/log" 2>&1 || fail "zap build run"
expect "hello 2"
"$zap" build test --summary all >"$work/log" 2>&1 || fail "zap build test"
expect "run test 2 pass (2 total)"

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
echo "fn unused() void { const y = 1; }" >>build.zig
if "$zap" build >"$work/log" 2>&1; then fail "zap build succeeded with a broken build.zig"; fi
expect "build.zig:23:26: error: [unused] unused local constant"
