#!/bin/sh
# `zig build test`: bs compiles a Zig 0.16 program with 0.16's meanings
# (test/language/zig016.zig), which prints what zig 0.16.0 prints for it.
#   $1 bs  $2 the program  $3 scratch directory
set -eu
unset ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR BS_CACHE BS_ZON_SELECTS
rm -rf "$3"
mkdir -p "$3"
bs=$(realpath "$1")
cp "$2" "$3/main.zig"
echo '.{ .lint = false }' >"$3/.bs.zon"
cd "$3"
BS_ZIG_VERSION=0.16 BS_UNFINISHED_0_16=1 "$bs" run main.zig --cache-dir local --global-cache-dir global >out 2>&1 || {
    echo "bs Zig 0.16 check failed: bs run exited $?" >&2
    cat out >&2
    exit 1
}
# zig 0.16.0's output.
want='{ 1, 2, 1, 2, 1, 2 } .{ 97, 98, 97, 98 } 7 6 [*c]u32 5 *u32 34 12 0 true 32 true 30201'
[ "$(cat out)" = "$want" ] || {
    printf 'bs Zig 0.16 check failed:\n  want %s\n  got  %s\n' "$want" "$(cat out)" >&2
    exit 1
}
