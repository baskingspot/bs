#!/bin/sh
# `zig build test-build`: `bs build` of a Zig 0.16 project
# (src/Build16.zig), test/build16/project from a scratch copy: fetching a
# path dependency and, when the build asks, a lazy one from a tarball
# (the runner exits for it and runs again); the generated
# dependencies.zig, the same as upstream zig 0.16's; the runner's steps
# compiled by bs over 0.16's `--listen=-` protocol; compile errors; and
# the refused web UI. bs compiles 0.16's build runner and every step
# itself, with zig 0.16's lib directory (BS_UNFINISHED_0_16 until bs
# supports 0.16 in full).
#   $1 bs  $2 test/build16  $3 scratch directory
set -eu
unset ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR ZIG_LIB_DIR ZIG_BUILD_RUNNER BS_ZIG_VERSION
rm -rf "$3"
mkdir -p "$3"
bs=$(realpath "$1") src=$(realpath "$2") work=$(realpath "$3")
zig16=${BS_ZIG_0_16:-$HOME/.cache/bs/zig-$(uname -m)-linux-0.16.0/zig}
[ -x "$zig16" ] || { echo "bs build 0.16 check failed: no zig 0.16.0 at $zig16 (run .agents/setup, or set BS_ZIG_0_16)" >&2; exit 1; }

fail() {
    echo "bs build 0.16 check failed: $1" >&2
    [ -f "$work/log" ] && cat "$work/log" >&2
    exit 1
}
expect() { grep -qF -- "$1" "$work/log" || fail "expected '$1'"; }

# The lazy dependency, as a tarball with its hash. `zig fetch` wants a
# build.zig, beside which it puts the package's zig-pkg: an empty one in
# the scratch directory.
tar czf "$work/lazy.tar.gz" -C "$src" lazy
mkdir "$work/hashing"
: >"$work/hashing/build.zig"
hash=$(cd "$work/hashing" && ZIG_GLOBAL_CACHE_DIR="$work/hashing/global" "$zig16" fetch "$work/lazy.tar.gz") || fail "zig fetch"
cp -r "$src/project" "$work/project"
sed -e "s|LAZY_TARBALL|$work/lazy.tar.gz|" -e "s|LAZY_HASH|$hash|" "$src/project/build.zig.zon" >"$work/project/build.zig.zon"
cd "$work/project"

bsb() {
    BS_ZON_SELECTS=1 BS_UNFINISHED_0_16=1 BS_ZIG_0_16="$zig16" \
        "$bs" build --global-cache-dir "$work/global" "$@" >"$work/log" 2>&1
}

bsb run --summary all || fail "bs build run"
expect "hello from a 0.16 dependency"
expect "compile exe hello16 Debug native success"
[ ! -d zig-pkg ] || fail "the lazy dependency was fetched without -Dlazy"
bsb run --summary all || fail "bs build run (no change)"
expect "compile exe hello16 Debug native cached"

# The lazy dependency: the runner reports it missing, bs fetches it into
# zig-pkg and runs the runner again.
bsb lazy -Dlazy || fail "bs build lazy -Dlazy"
expect "hello from a lazy 0.16 dependency"
[ -d "zig-pkg/$hash" ] || fail "zig-pkg/$hash"

# Both versions of dependencies.zig, without and with the lazy package,
# are upstream zig 0.16's.
deps() { for f in .zig-cache/o/*/dependencies.zig; do sha256sum <"$f"; done | sort; }
deps >"$work/bs-deps"
rm -rf .zig-cache zig-pkg
ZIG_GLOBAL_CACHE_DIR="$work/global16" "$zig16" build lazy -Dlazy >"$work/log" 2>&1 || fail "zig 0.16 build lazy -Dlazy"
deps >"$work/zig-deps"
cmp -s "$work/bs-deps" "$work/zig-deps" || fail "dependencies.zig differs from zig 0.16's"

# --fetch fetches every package and runs nothing.
rm -rf .zig-cache zig-pkg
bsb --fetch=all || fail "bs build --fetch=all"
[ -d "zig-pkg/$hash" ] || fail "--fetch=all: zig-pkg/$hash"
! ls .zig-cache/bs/build-runner/*/build >/dev/null 2>&1 || fail "--fetch=all compiled the runner"

# A step's compile error reaches the runner, which reports it.
sed 's/greet.hello();/greet.hello();\n    return 1;/' main.zig >main.zig.new
mv main.zig.new main.zig
bsb run && fail "bs build run with a compile error succeeded"
expect "main.zig:5:12: error"
expect "compile exe hello16 Debug native"

# The runner's web UI is 0.16's, which bs does not serve.
for arg in --webui --fuzz --time-report; do
    bsb install "$arg" && fail "bs build $arg succeeded"
    expect "'$arg' starts Zig 0.16's build web UI, which bs does not serve"
done

# A step that runs `zig build --build-file` on a project of its own
# without a build.zig.zon (zls's tests do) gets the runner's
# BS_ZIG_VERSION, and bs builds that project in 0.16, with 0.16's runner
# and that build file, as zig 0.16 would.
mkdir "$work/nested"
printf 'const std = @import("std");\npub fn build(b: *std.Build) void {\n    _ = b.step("nothing", "");\n}\n' >"$work/nested/case.zig"
echo '.{ .lint = false }' >"$work/nested/.bs.zon"
cd "$work/nested"
BS_ZIG_VERSION=0.16 BS_UNFINISHED_0_16=1 BS_ZIG_0_16="$zig16" "$bs" build --build-file case.zig nothing --global-cache-dir "$work/global" >"$work/log" 2>&1 || fail "bs build of a project without build.zig.zon under BS_ZIG_VERSION=0.16"
ls .zig-cache/bs/build-runner/*/build >/dev/null 2>&1 || fail "BS_ZIG_VERSION=0.16 did not build with 0.16's runner"
# Each build file of a directory has a runner of its own, so that builds
# of several at once (zls's tests) do not overwrite each other's.
sed 's/"nothing", ""/"nothing", "case2"/' case.zig >case2.zig
BS_ZIG_VERSION=0.16 BS_UNFINISHED_0_16=1 BS_ZIG_0_16="$zig16" "$bs" build --build-file case2.zig nothing --global-cache-dir "$work/global" >"$work/log" 2>&1 || fail "bs build --build-file case2.zig"
[ "$(find .zig-cache/bs/build-runner -name build -type f | wc -l)" -eq 2 ] || fail "two build files share a runner"
