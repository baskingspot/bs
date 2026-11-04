#!/bin/sh
# `zig build test`: an executable with object and archive inputs through
# the cache. The objects are link-only inputs: each build, edited in a
# scratch copy, must give the bytes of a build without the cache, and edit
# builds check themselves against full builds (ZAP_CACHE_VERIFY,
# ZAP_CACHE_CHECK). C sources' objects are link inputs the same way.
#   $1 zap  $2 upstream zig  $3 test/link_input  $4 scratch directory
set -eu
unset ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR ZAP_CACHE ZAP_CACHE_VERIFY ZAP_CACHE_CHECK
rm -rf "$4"
mkdir -p "$4"
zap=$(realpath "$1") zig=$2 src=$(realpath "$3") work=$(realpath "$4")
cd "$work"
cp "$src"/main.zig "$src"/lib.c "$src"/tls.c "$src"/tlsie.c "$src"/a1.c "$src"/a2.c "$src"/libc.c "$src"/libc_main.zig "$src"/copy.c .
export ZAP_ZIG="$zig"

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

# $1 what the build must say (ZAP_CACHE_TIMING), $2 what the program
# prints; the build's log stays in cached.log.
args="build-exe main.zig lib.o tls.o tlsie.o liba1.a -la2 -L."
build() {
    ZAP_CACHE_TIMING=1 ZAP_CACHE_CHECK=1 ZAP_CACHE_VERIFY=1 "$zap" $args --cache-dir local --global-cache-dir global -femit-bin=main >log 2>&1 || fail "$1"
    cp log cached.log
    grep -qF -- "$1" log || fail "expected '$1'"
    ZAP_CACHE=off "$zap" $args --global-cache-dir global -femit-bin=full >log 2>&1 || fail "$1: without the cache"
    cmp -s main full || fail "$1: the output differs from a build without the cache"
    ./main >out 2>&1 || fail "$1: the program failed"
    grep -qF -- "$2" out || fail "$1: the program printed '$(cat out)'"
}

# Whether the last build was a lazy edit build, which links from the
# manifest: not after its objects changed, which may need what the last
# build did not generate.
lazy() {
    grep -qF "from the manifest" cached.log || fail "$1: expected a lazy edit build"
}
eager() {
    ! grep -qF "from the manifest" cached.log || fail "$1: expected an eager edit build"
}

objects
build "no manifest" "hello from C"
build "not relinking" "hello from C"
# A relink from the manifest converts the inputs again.
rm main
build "no input changed; relinked" "hello from C"
# An object changed: built again, nothing to analyze.
sed -i 's/hello from C/HELLO from C/' lib.c
objects
build "inputs changed, first $work/lib.o" "HELLO from C"
eager "an object changed"
# An archive's member changed.
sed -i 's/1 + a2/2 + a2/' a1.c
objects
build "inputs changed, first $work/liba1.a" "HELLO from C"
# The Zig code changed.
sed -i 's/{d} {d} {d}\\n", .{ c_tls()/{d} {d} {d}!\\n", .{ c_tls()/' main.zig
build "inputs changed, first $work/main.zig" "HELLO from C"
lazy "the Zig code changed"
grep -qF -- "!" out || fail "the Zig edit did not take"
# Without ZAP_CACHE_VERIFY, whose full build writes a new base, a lazy
# edit build leaves a log; a relink from it links what the edit build did.
sed -i 's/{d} {d} {d}!\\n"/{d} {d} {d}?\\n"/' main.zig
ZAP_CACHE_TIMING=1 "$zap" $args --cache-dir local --global-cache-dir global -femit-bin=main >cached.log 2>&1 || fail "an edit without verifying"
lazy "an edit without verifying"
mv main edited
ZAP_CACHE_TIMING=1 "$zap" $args --cache-dir local --global-cache-dir global -femit-bin=main >log 2>&1 || fail "a relink from the log"
grep -qF "no input changed; relinked" log || fail "expected a relink from the log"
cmp -s main edited || fail "the relink from the log differs from the edit build's output"
./main >out 2>&1 && grep -qF -- "?" out || fail "the relink from the log lost the edit"

# C sources: their records' objects are the link inputs. An edited source
# keeps its object's path, so the build must not take the old object for
# the last build's while Clang compiles the new one.
args="build-exe libc_main.zig libc.c -lc"
rm -rf local
build "first build" "x=21 twice=42"
build "not relinking" "x=21 twice=42"
sed -i 's/x=%d/X=%d/' libc.c
# The Zig code replays, eagerly: the object is not the manifest's yet.
build "0 inputs changed" "X=21 twice=42"
eager "a C source changed"
build "not relinking" "X=21 twice=42"
# Touched, not changed: the record hits, and the link is the last one.
touch libc.c
build "not relinking" "X=21 twice=42"
sed -i 's/return 2 \* x/return 3 * x/' libc_main.zig
build "inputs changed, first $work/libc_main.zig" "X=21 twice=63"

# -lc with objects: a C object's glibc imports, its reference to a Zig
# export, and the executable's copies of glibc data that GCC's -fPIE reads
# PC-relative.
cp "$src"/libc.c "$src"/libc_main.zig .
args="build-exe -lc -target x86_64-linux-gnu libc_main.zig libc.o copy.o"
lc_objects() {
    "$zig" cc -fPIC -c libc.c -o libc.o
    gcc -fPIE -c copy.c -o copy.o
}
if command -v gcc >/dev/null; then
    # Edits go to a file without exports: a file whose export ran again
    # builds eagerly.
    sed -i 's/c_fmt(21)/c_fmt(@import("lc_arg.zig").arg)/' libc_main.zig
    echo 'pub const arg = 21;' >lc_arg.zig
    lc_objects
    build "no manifest" "x=21 twice=42"
    rm main
    build "no input changed; relinked" "x=21 twice=42"
    echo 'pub const arg = 22;' >lc_arg.zig
    build "inputs changed, first $work/lc_arg.zig" "x=22 twice=44"
    lazy "-lc: the Zig code changed"
    sed -i 's/x=%d/X=%d/' libc.c
    lc_objects
    build "inputs changed, first $work/libc.o" "X=22 twice=44"
    eager "-lc: an object changed"
fi
