#!/bin/sh
# `zig build test`: a lazy edit build of a test that adds an error name.
# The test runner links the error name table through `@errorName`, but
# its nodes are unchanged, and no node the build wrote or decided refers
# to the table: the build skipped the check of the link's inputs, which
# falls back when the table changes, and linked the old one.
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
    echo "bs edit adding an error name to a test failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

cat >t.zig <<'EOF2'
const std = @import("std");
pub const Error = error{ Bad, Empty };
pub fn check(n: u32) Error!u32 {
    if (n == 0) return error.Empty;
    if (n > 1000) return error.Bad;
    return n + 1;
}
test "check" {
    try std.testing.expectEqual(@as(u32, 5), try check(4));
}
EOF2
build() {
    "$bs" test --test-no-exec -target x86_64-linux t.zig --cache-dir local --global-cache-dir global -femit-bin=t >log 2>&1 || fail "$1"
    ./t >log 2>&1 || fail "$1: the tests failed"
}
build "the first build"
sed -i 's/error{ Bad, Empty }/error{ Bad, Empty, Zz }/' t.zig
BS_CACHE_VERIFY=1 BS_CACHE_CHECK=1 build "the edit build"
