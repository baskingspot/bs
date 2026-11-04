#!/bin/sh
# `zig build test`: build-obj and build-lib through the cache. Each build
# of test/obj/lib.zig, edited in a scratch copy, must give the bytes of a
# build without the cache, and edit builds check themselves against full
# builds (ZAP_CACHE_VERIFY, ZAP_CACHE_CHECK).
#   $1 zap  $2 test/obj/lib.zig  $3 scratch directory
#   $4 build-obj or build-lib, each its own build step, so that they run at once
#   $5 a global cache holding std's ZIR, which the empty one starts from
set -eu
unset ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR ZAP_CACHE ZAP_CACHE_VERIFY ZAP_CACHE_CHECK
rm -rf "$3"
mkdir -p "$3"
zap=$(realpath "$1") src=$(realpath "$2") work=$(realpath "$3") cmd=$4
mkdir -p "$work/global/zap"
cp -r "$5/zap/zir" "$work/global/zap"
cd "$work"

fail() {
    echo "zap object cache check failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

# $1 command, $2 output, $3 what the build must say (ZAP_CACHE_TIMING).
# The build without the cache runs once per version of lib.zig.
build() {
    ZAP_CACHE_TIMING=1 ZAP_CACHE_CHECK=1 ZAP_CACHE_VERIFY=1 "$zap" "$1" lib.zig --cache-dir local --global-cache-dir global "-femit-bin=$2" >log 2>&1 || fail "$1 ($3)"
    grep -qF -- "$3" log || fail "$1: expected '$3'"
    full=full-$(sha256sum <lib.zig | cut -c1-16)-$2
    [ -f "$full" ] || ZAP_CACHE=off "$zap" "$1" lib.zig "-femit-bin=$full" >log 2>&1 || fail "$1 without the cache"
    cmp -s "$2" "$full" || fail "$1 ($3): the output differs from a build without the cache"
}

out=$([ $cmd = build-obj ] && echo lib.o || echo libx.a)
cp "$src" lib.zig
build $cmd $out "no manifest"
# Relinked from the manifest, with the numbered symbols.
rm $out
build $cmd $out "relinked"
# A lazy edit build.
sed 's/return counter + calls;/return counter + calls + 1;/' "$src" >lib.zig
build $cmd $out "linked 2"
# The imports change: built again eagerly.
sed 's/return c_twice(x) + 1;/return x + 1;/' "$src" >lib.zig
build $cmd $out "external symbols changed"
# An export comes back with the import.
cp "$src" lib.zig
build $cmd $out "replayed"
# The import becomes weak, then relinks with its flags from the manifest.
sed 's/return c_twice(x) + 1;/return @extern(?*const fn (u32) callconv(.c) u32, .{ .name = "c_twice", .linkage = .weak }).?(x) + 1;/' "$src" >lib.zig
build $cmd $out "external symbols changed"
rm $out
build $cmd $out "relinked"
[ $cmd = build-obj ] || [ "$(ar t libx.a)" = "lib.o" ] || fail "libx.a holds lib.o"
