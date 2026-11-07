#!/bin/sh
# shellcheck disable=SC2086 # $3 is an assignment or nothing, split on purpose
# `zig build test` on an aarch64-macos host: an executable's build that
# changed nothing leaves the output as the cache's last link left it, and
# an edit to an imported file is an edit build; a touch without a change,
# a verifying build (BS_CACHE_VERIFY, after which the next build relinks
# from the cache, whose manifest the verifying build did not replace) and
# a build without the cache build or not as they must. Every output is
# signed. An object, which the cache does not take there, answers from its
# inputs record (main.zig's InputsRecord).
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
    # The devshell puts GNU coreutils' stat first, whose -f is the filesystem,
    # so name the host's BSD stat.
    stamp=$(/usr/bin/stat -f '%i %Fm' main)
    codesign --verify --strict main 2>>log || fail "$1: the output's signature"
}

build "first" "hi 1"
first=$stamp
build "no change" "hi 1"
[ "$stamp" = "$first" ] || fail "a build that changed nothing rewrote the output"
touch greet.zig main.zig
build "touched" "hi 1"
[ "$stamp" = "$first" ] || fail "a build of touched but unchanged sources rewrote the output"
echo 'pub const n = 2;' >greet.zig
build "imported file edited" "hi 2" BS_CACHE_TIMING=1
[ "$stamp" != "$first" ] || fail "an edit to an imported file did not build"
grep -q "from the last build" log || fail "an edit to an imported file was not an edit build"
edited=$stamp
build "BS_CACHE_VERIFY" "hi 2" BS_CACHE_VERIFY=full
[ "$stamp" != "$edited" ] || fail "a verifying build answered from the cache"
verified=$stamp
build "no change after a verifying build" "hi 2" BS_CACHE_TIMING=1
grep -q "no input changed; relinked" log || fail "a build that changed nothing after a verifying build did not relink from the cache"
verified=$stamp
build "no change after the relink" "hi 2"
[ "$stamp" = "$verified" ] || fail "a build that changed nothing after a relink rewrote the output"
build "BS_CACHE=off" "hi 2" BS_CACHE=off
[ "$stamp" != "$verified" ] || fail "a build without the cache answered from the cache"

# An object: the inputs record.
obj() {
    "$bs" build-obj greet.zig --cache-dir local --global-cache-dir global -femit-bin=greet.o >log 2>&1 || fail "build-obj ($1)"
    stamp=$(/usr/bin/stat -f '%i %Fm' greet.o)
}
obj "first"
first=$stamp
obj "no change"
[ "$stamp" = "$first" ] || fail "an object's build that changed nothing rewrote it"
echo 'pub const n = 3;' >greet.zig
obj "edited"
[ "$stamp" != "$first" ] || fail "an edit to an object's source did not build"
