#!/bin/sh
# `zig build test`: an executable with object and archive inputs through
# the cache. The objects are link-only inputs: each build, edited in a
# scratch copy, must give the bytes of a build without the cache, and edit
# builds check themselves against full builds (ZAP_CACHE_VERIFY,
# ZAP_CACHE_CHECK).
#   $1 zap  $2 upstream zig  $3 test/link_input  $4 scratch directory
set -eu
unset ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR ZAP_CACHE ZAP_CACHE_VERIFY ZAP_CACHE_CHECK
rm -rf "$4"
mkdir -p "$4"
zap=$(realpath "$1") zig=$2 src=$(realpath "$3") work=$(realpath "$4")
cd "$work"
cp "$src"/main.zig "$src"/lib.c "$src"/tls.c "$src"/tlsie.c "$src"/a1.c "$src"/a2.c .

fail() {
    echo "zap link input cache check failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

objects() {
    "$zig" cc -fcommon -c lib.c -o lib.o
    "$zig" cc -fPIC -c tls.c -o tls.o
    "$zig" cc -fPIC -c tlsie.c -o tlsie.o
    for a in a1 a2; do
        "$zig" cc -c $a.c -o $a.o
        rm -f lib$a.a
        "$zig" ar rcs lib$a.a $a.o
    done
}

# $1 what the build must say (ZAP_CACHE_TIMING), $2 what the program prints first.
build() {
    args="build-exe main.zig lib.o tls.o tlsie.o liba1.a -la2 -L."
    ZAP_CACHE_TIMING=1 ZAP_CACHE_CHECK=1 ZAP_CACHE_VERIFY=1 "$zap" $args --cache-dir local --global-cache-dir global -femit-bin=main >log 2>&1 || fail "$1"
    grep -qF -- "$1" log || fail "expected '$1'"
    ZAP_CACHE=off "$zap" $args -femit-bin=full >log 2>&1 || fail "$1: without the cache"
    cmp -s main full || fail "$1: the output differs from a build without the cache"
    ./main 2>out || fail "$1: the program failed"
    head -n 1 out | grep -qF -- "$2" || fail "$1: the program printed '$(head -n 1 out)'"
}

objects
build "no manifest" "hello from C"
build "not relinking" "hello from C"
# No relink from the manifest: the inputs' atoms are not in it.
rm main
build "the link has object or archive inputs" "hello from C"
# An object changed: built again, nothing to analyze.
sed -i 's/hello from C/HELLO from C/' lib.c
objects
build "inputs changed, first $work/lib.o" "HELLO from C"
# An archive's member changed.
sed -i 's/1 + a2/2 + a2/' a1.c
objects
build "inputs changed, first $work/liba1.a" "HELLO from C"
# The Zig code changed.
sed -i 's/{d} {d} {d}\\n", .{ c_tls()/{d} {d} {d}!\\n", .{ c_tls()/' main.zig
build "inputs changed, first $work/main.zig" "HELLO from C"
grep -qF -- "!" out || fail "the Zig edit did not take"
