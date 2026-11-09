#!/bin/sh
# `zig build test`: edit builds of a Zig 0.16 program that imports C.
# The translation is a dependency of its importer (`Dependee.c_import`),
# and an edit build translates the last build's `@cImport`s again before
# analysis (`Replay.create`): Zig edits replay, and header edits, header
# errors, a trimmed translation, a new header and dropping the import
# each build what a full build does, which BS_CACHE_VERIFY checks.
#   $1 bs  $2 scratch directory
#   $3 a global cache holding std's ZIR, which the empty one starts from
set -eu
unset ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR BS_CACHE BS_CACHE_VERIFY BS_CACHE_CHECK BS_CACHE_DONOR BS_ZIG_VERSION
rm -rf "$2"
mkdir -p "$2"
bs=$(realpath "$1") work=$(realpath "$2")
mkdir -p "$work/global/bs"
cp -r "$3/bs/zir" "$work/global/bs"
cd "$work"

fail() {
    echo "bs edit of a program that imports C failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

echo '.{ .lint = false, .zig_version = "0.16" }' >.bs.zon
# $1 the @cImport body, $2 the point's y.
write() {
    printf 'const std = @import("std");\nconst c = @cImport(%s);\n\npub fn main() void {\n    const p: c.struct_point = .{ .x = c.ANSWER, .y = %s };\n    std.debug.print("{d} {d}\\n", .{ p.x, p.y });\n}\n' "$1" "$2" >m.zig
}
# $1 the step, $2 the output expected, or empty for a compile error;
# $3 what the log must say, if anything.
build() {
    if BS_CACHE_VERIFY=1 BS_CACHE_CHECK=1 BS_CACHE_TIMING=1 "$bs" build-exe m.zig -I. --cache-dir local --global-cache-dir global -femit-bin=out >log 2>&1; then
        [ -n "$2" ] || fail "$1: compiled"
        [ "$(./out 2>&1)" = "$2" ] || fail "$1: wrong output"
    else
        [ -z "$2" ] || fail "$1"
    fi
    grep -q " [1-9][0-9]* differ\| [1-9][0-9]* missed" log && fail "$1: the edit build differs from a full build"
    [ -z "${3-}" ] || grep -qF "$3" log || fail "$1: expected '$3'"
}
printf '#define ANSWER 42\nstatic inline int twice(int x) { return 2 * x; }\nstruct point { int x; int y; };\n' >h.h
write '@cInclude("h.h")' 'c.twice(3)'
build "the first build" "42 6"
build "the build without changes" "42 6" "no input changed"
write '@cInclude("h.h")' 'c.twice(4)'
build "an edit to the Zig code" "42 8" "replayed"
sed 's/ANSWER 42/ANSWER 43/' h.h >h.new && mv h.new h.h
build "an edit to the header" "43 8" "replayed"
cp h.h h.good
echo 'int broken(' >>h.h
build "a header that does not translate" "" "C import failed"
mv h.good h.h
build "the header fixed" "43 8"
rm -rf local/o
build "the translation trimmed" "43 8"
echo '#define EXTRA 5' >e.h
write '{ @cInclude("h.h"); @cInclude("e.h"); }' 'c.twice(c.EXTRA)'
build "a second header" "43 10"
echo '#define EXTRA 7' >e.h
build "an edit to the second header" "43 14" "replayed"
printf 'const std = @import("std");\n\npub fn main() void {\n    std.debug.print("no C\\n", .{});\n}\n' >m.zig
build "the import dropped" "no C"
