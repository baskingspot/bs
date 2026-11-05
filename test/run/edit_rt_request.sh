#!/bin/sh
# `zig build test`: an edit to a function that requests a compiler_rt
# helper stays a lazy edit build, and checks itself. The request analyzes
# the helper's declaration, which the record must reach as a full build
# does: the lazy build had visited it unreached and fallen back eagerly,
# and BS_CACHE_CHECK did not fail a lazy build that recorded gaps.
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
    echo "bs edit of a compiler_rt requester failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

# f80 to f16 and the f80 compare are compiler_rt calls.
cat >m.zig <<'EOF2'
var x80: f80 = 1.5;
var y16: f16 = 0;
fn conv() bool {
    y16 = @floatCast(x80);
    return x80 < 2.0 and y16 > 0.5;
}
pub fn main() u8 {
    return @as(u8, @intFromBool(conv())) + 1;
}
EOF2
build() {
    "$bs" build-exe -target x86_64-linux m.zig --cache-dir local --global-cache-dir global -femit-bin=out >log 2>&1 || fail "$1"
    code=0
    ./out || code=$?
    [ "$code" = "$2" ] || fail "$1: exit code $code, not $2"
}
build "the first build" 2
sed -i 's/x80 < 2.0/x80 < 1.0/' m.zig
BS_CACHE_VERIFY=1 BS_CACHE_CHECK=1 BS_CACHE_TIMING=1 build "the edit build" 1
grep -q "recorded the edits" log || fail "the edit build was not lazy"
