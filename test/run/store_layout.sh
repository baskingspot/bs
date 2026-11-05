#!/bin/sh
# `zig build test`: a store entry reused across compilations whose types
# lay out differently. A test without libc and one with `-lc` share the
# store seed (bs and the target), and std.testing's `io_instance`, an
# `undefined` `Io.Threaded`, has the same key, source and value in both,
# but takes 880 bytes without libc and 1136 with it (`posix.Sigaction`).
# The record reused the first build's entry for the second, whose relink
# then gave the variable 880 bytes.
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
    echo "bs store entry across layouts failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

mkdir a b
cat >a/t.zig <<'EOF2'
const std = @import("std");
test "io" {
    try std.testing.expectEqual(@sizeOf(std.Io.Threaded), @sizeOf(@TypeOf(std.testing.io_instance)));
    _ = std.testing.io;
}
EOF2
cp a/t.zig b/t.zig
# $1 the directory, then the arguments. Without donors, so that each
# build analyzes its program and only the store is shared.
build() {
    d=$1
    shift
    (cd "$d" && BS_CACHE_DONOR=off BS_CACHE_TIMING=1 "$bs" test --test-no-exec "$@" t.zig -target x86_64-linux-gnu --cache-dir local --global-cache-dir ../global -femit-bin=t) >log 2>&1 || fail "the build in $d"
}
build a
build b -lc
(cd b && BS_CACHE=off "$bs" test --test-no-exec -lc t.zig -target x86_64-linux-gnu --global-cache-dir ../global -femit-bin=full) >log 2>&1 || fail "the build without the cache"
cmp -s b/t b/full || fail "the -lc build differs from a build without the cache"
rm b/t
build b -lc
grep -qF "no input changed; relinked" log || fail "expected a relink"
cmp -s b/t b/full || fail "the relink differs from a build without the cache"
