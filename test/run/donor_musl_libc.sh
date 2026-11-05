#!/bin/sh
# `zig build test`: donors across musl's `-lc`. A program built without
# libc and then with `-target x86_64-linux-musl -lc` shares its donor
# key, so each build replays the other's graph, whose builtin differs
# only in `link_libc`. Before, std's `Io.Threaded.addBuf` kept the
# donor's `usize` iovlen where musl's is `u32` (its body depends on its
# own declaration's type only since `Graph.addOwnNav`), and every
# `Syscall.fail` instance kept the donor's offset into `Thread` from
# its inlined `finish` (`Emit.layoutsHash`): stderr writes panicked.
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
    echo "bs donor across musl's -lc failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

mkdir a b c
cat >a/t.zig <<'EOF2'
const std = @import("std");
pub fn main() void {
    std.debug.print("hello {d}\n", .{42});
}
EOF2
cp a/t.zig b/t.zig
cp a/t.zig c/t.zig
# $1 the directory, then the target arguments.
build() {
    d=$1
    shift
    (cd "$d" && BS_CACHE_TIMING=1 BS_CACHE_CHECK=1 BS_CACHE_VERIFY=1 "$bs" build-exe "$@" t.zig --cache-dir local --global-cache-dir ../global -femit-bin=t) >log 2>&1 || fail "the build in $d"
    "./$d/t" 2>out || fail "the program built in $d"
    [ "$(cat out)" = "hello 42" ] || fail "the program built in $d printed $(cat out)"
}
build a
build b -target x86_64-linux-musl -lc
grep -q "replaying donor .*another program's" log || fail "the musl -lc build replayed no donor"
# And back: a build without libc from the musl one's donor.
rm -rf a/local
build c
grep -q "replaying donor .*another program's" log || fail "the build without libc replayed no donor"
