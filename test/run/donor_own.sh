#!/bin/sh
# `zig build test`: a program's own donor outlives other programs' donors
# of the same donor key. Six programs build in turn into one global cache,
# more than one per key used to keep; the first one's next first build (an
# empty local cache) must then replay its own donor lazily, and a new
# program another program's.
#   $1 bs  $2 scratch directory
#   $3 a global cache holding std's ZIR, which the empty one starts from
set -eu
unset ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR BS_CACHE BS_CACHE_VERIFY BS_CACHE_CHECK BS_CACHE_DONOR
rm -rf "$2"
mkdir -p "$2"
bs=$(realpath "$1") work=$(realpath "$2")
mkdir -p "$work/global/bs"
cp -r "$3/bs/zir" "$work/global/bs"
cd "$work"

fail() {
    echo "bs donor check failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

# $1 the program's number: its directory and exit code.
build() {
    mkdir -p "p$1"
    printf 'pub fn main() u8 {\n    return %d;\n}\n' "$1" >"p$1/main.zig"
    rm -rf "p$1/local"
    BS_CACHE_TIMING=1 BS_CACHE_CHECK=1 "$bs" build-exe "p$1/main.zig" --cache-dir "p$1/local" --global-cache-dir global "-femit-bin=p$1/out" >log 2>&1 || fail "build of p$1"
    code=0
    "./p$1/out" || code=$?
    [ "$code" = "$1" ] || fail "p$1 exited with $code"
}

for i in 0 1 2 3 4 5; do build "$i"; done
build 0
grep -q "replaying donor .*, the program's own" log || fail "p0 did not replay its own donor"
grep -q "the walk reached" log || fail "p0's own donor was not replayed lazily"
build 6
grep -q "replaying donor .*, another program's" log || fail "p6 did not replay another program's donor"
