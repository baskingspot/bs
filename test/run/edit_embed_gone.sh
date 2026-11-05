#!/bin/sh
# `zig build test`: upstream's test/incremental change_embed_file. After
# the build that removes the last reference to an `@embedFile`d file
# that is gone, the manifest still lists the file, which that build no
# longer read; BS_CACHE_VERIFY's full build refused to compare with it
# ("changed since the last build").
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
    echo "bs edit around a deleted embedded file failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

# $1 what the main function writes.
write() {
    printf 'const std = @import("std");\nconst string = @embedFile("string.txt");\npub fn main() !void {\n    try std.Io.File.stdout().writeStreamingAll(io, %s);\n}\nconst io = std.Io.Threaded.global_single_threaded.io();\n' "$1" >m.zig
}
# $1 the step, $2 the output expected, or empty for a compile error.
build() {
    if BS_CACHE_VERIFY=1 BS_CACHE_CHECK=1 "$bs" build-exe -target x86_64-linux m.zig --cache-dir local --global-cache-dir global -femit-bin=out >log 2>&1; then
        [ -n "$2" ] || fail "$1: compiled"
        [ "$(./out)" = "$2" ] || fail "$1: wrong output"
    else
        if [ -n "$2" ] || ! grep -q 'failed opening "string.txt": FileNotFound' log; then
            fail "$1"
        fi
    fi
}
write string
echo 'Hello, World!' >string.txt
build "the first build" "Hello, World!"
rm string.txt
build "the build without the file" ""
write '"a hardcoded string\n"'
build "the build without its reference" "a hardcoded string"
write string
build "the build with the reference again" ""
echo "We're back, World!" >string.txt
build "the build with the file again" "We're back, World!"
