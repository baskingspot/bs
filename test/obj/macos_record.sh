#!/bin/sh
# shellcheck disable=SC2086 # $3 is an assignment or nothing, split on purpose
# `zig build test` on an aarch64-macos host: bs uses no cache there yet, so
# a build that changed nothing answers from its inputs record (main.zig's
# InputsRecord) and leaves the output as it was. An edit to an imported
# file builds again; a touch without a change, a verifying build
# (BS_CACHE_VERIFY) and a build without the cache build or not as they
# must.
#   $1 bs  $2 scratch directory
set -eu
unset ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR BS_CACHE BS_CACHE_VERIFY BS_CACHE_CHECK
rm -rf "$2"
mkdir -p "$2"
bs=$(realpath "$1") work=$(realpath "$2")
cd "$work"

fail() {
    echo "bs inputs record check failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

cat >main.zig <<'EOF'
const std = @import("std");
const greet = @import("greet.zig");
pub fn main() void {
    std.debug.print("hi {d}\n", .{greet.n});
}
EOF
echo 'pub const n = 1;' >greet.zig

# $1 what the build is, $2 what the program must print, $3 an environment
# variable to build with (not an assignment before the call, which POSIX
# shells keep after a function returns); then the output's inode and
# modification time, to the nanosecond, in $stamp.
build() {
    env ${3:-} "$bs" build-exe main.zig --cache-dir local --global-cache-dir global -femit-bin=main >log 2>&1 || fail "build ($1)"
    [ "$(./main 2>&1)" = "$2" ] || fail "$1: main prints '$2'"
    stamp=$(stat -f '%i %Fm' main)
}

build "first" "hi 1"
first=$stamp
build "no change" "hi 1"
[ "$stamp" = "$first" ] || fail "a build that changed nothing rewrote the output"
touch greet.zig main.zig
build "touched" "hi 1"
[ "$stamp" = "$first" ] || fail "a build of touched but unchanged sources rewrote the output"
echo 'pub const n = 2;' >greet.zig
build "imported file edited" "hi 2"
[ "$stamp" != "$first" ] || fail "an edit to an imported file did not build"
edited=$stamp
build "BS_CACHE_VERIFY" "hi 2" BS_CACHE_VERIFY=full
[ "$stamp" != "$edited" ] || fail "a verifying build answered from the record"
verified=$stamp
build "no change after a verifying build" "hi 2"
[ "$stamp" = "$verified" ] || fail "a build that changed nothing after a verifying build rewrote the output"
build "BS_CACHE=off" "hi 2" BS_CACHE=off
[ "$stamp" != "$verified" ] || fail "a build without the cache answered from the record"
