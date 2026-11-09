#!/bin/sh
# `zig build test`: each Zig language has caches of its own. The same
# program, in the same directories with the same lib directory, is built
# in 0.17 and then, with BS_TEST_LANGUAGE_KEYS, in 0.16 (with 0.17's
# frontend and Sema, so that both read the same sources). The 0.16 builds must reuse
# nothing of 0.17's: not its compilation, ZIR, stat index, store entries,
# donors or `bs run` binary, and each language must still find its own.
#   $1 bs  $2 a program that imports std  $3 scratch directory
set -eu
unset ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR BS_CACHE BS_CACHE_VERIFY BS_CACHE_CHECK BS_ZIG_VERSION
rm -rf "$3"
mkdir -p "$3"
bs=$(realpath "$1") work=$(realpath "$3")
lib=$("$bs" env | sed -n 's/^ *\.lib_dir = "\(.*\)",$/\1/p')
[ -n "$lib" ] || { echo "bs language keys check failed: no lib_dir in bs env" >&2; exit 1; }
cp "$2" "$work/main.zig"
cd "$work"

fail() {
    echo "bs language keys check failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

# $1 language, $2 local cache, then what the build must say
# (BS_CACHE_TIMING, BS_FRONTEND_TIMING), each a fixed string.
build() {
    lang=$1 local=$2
    shift 2
    BS_ZIG_VERSION=$lang BS_TEST_LANGUAGE_KEYS=1 BS_CACHE_TIMING=1 BS_FRONTEND_TIMING=1 "$bs" build-exe main.zig --zig-lib-dir "$lib" --cache-dir "$local" --global-cache-dir global "-femit-bin=main-$lang" >log 2>&1 || fail "$lang build in $local"
    for want in "$@"; do grep -qF -- "$want" log || fail "$lang build in $local: expected '$want'"; done
}

build 0.17 local "no manifest"
# Another local cache, so that 0.16 starts from the global one alone,
# which holds 0.17's std ZIR, stats, store entries and donor.
build 0.16 local16 "no manifest" " 0 stat hits," "no usable donor (0 candidates)" " 0 reused,"
lowered=$(sed -n 's/^frontend: .* \([0-9]*\) lowered;.*/\1/p' log)
[ "${lowered:-0}" -gt 500 ] || fail "0.16 lowered $lowered files: it took 0.17's ZIR"
# The same local cache as 0.17's: 0.16's compilation is another one.
build 0.16 local "no manifest" "replaying donor"
build 0.16 local "not relinking"
build 0.17 local "not relinking"
# A fresh local cache: each language replays its own donor.
build 0.17 fresh17 "replaying donor"
build 0.16 fresh16 "replaying donor"

# `bs run` keeps each language's program apart.
for lang in 0.17 0.16; do
    BS_ZIG_VERSION=$lang BS_TEST_LANGUAGE_KEYS=1 "$bs" run main.zig --zig-lib-dir "$lib" --cache-dir run --global-cache-dir global >log 2>&1 || fail "bs run in $lang"
done
# On macOS each binary has a main.dSYM beside it, holding another `main`.
[ "$(find run/bs/o -name main -type f -not -path '*.dSYM/*' | wc -l)" -eq 2 ] || fail "bs run: expected a binary per language"
