#!/bin/sh
# `zig build test`: an edit build of a module with `--dep`s that embeds a
# file. Its file inputs' keys carry the `--dep`s (`Incremental.inputKey`)
# but its embedded files' did not, so every build took the embedded file
# for another program's (`inputKeyHolds`): changed, its nodes analyzed
# again, and a donor of the same program replayed eagerly.
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
    echo "bs edit of a module with --deps that embeds a file failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

cat >m.zig <<'EOF2'
const lib = @import("lib");
const data = @embedFile("data.txt");
pub fn main() u8 {
    return data.len + lib.v;
}
EOF2
printf 'hello' >data.txt
echo 'pub const v = 3;' >lib.zig
build() {
    BS_CACHE_TIMING=1 "$bs" build-exe -target x86_64-linux --dep lib -Mroot=m.zig -Mlib=lib.zig \
        --cache-dir local --global-cache-dir global -femit-bin=out >log 2>&1 || fail "$1"
    code=0
    ./out || code=$?
    [ "$code" = "$2" ] || fail "$1: exit code $code, not $2"
}
build "the first build" 8
echo 'pub const v = 4;' >lib.zig
BS_CACHE_CHECK=1 BS_CACHE_VERIFY=1 build "the edit build" 9
grep -q "; 1 inputs changed, " log || fail "the edit build changed more inputs than lib.zig"
printf 'hello!' >data.txt
BS_CACHE_CHECK=1 BS_CACHE_VERIFY=1 build "the edit build of the embedded file" 10
