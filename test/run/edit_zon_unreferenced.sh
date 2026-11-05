#!/bin/sh
# `zig build test`: builds after a ZON file that the program imports but
# never analyzes is deleted. As upstream, the import fails even so
# (`Frontend.zon_imports`), but Sema never read the file, so it was not
# an input of the cache, whose up-to-date check passed: bs exited 0.
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
    echo "bs build after an unanalyzed ZON import changed failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

cat >m.zig <<'EOF2'
const message: []const u8 = @import("message.zon");
pub fn main() u8 {
    return 3;
}
EOF2
echo '"hello"' >message.zon
build() {
    "$bs" build-exe -target x86_64-linux m.zig --cache-dir local --global-cache-dir global -femit-bin=out >log 2>&1 || fail "$1"
    code=0
    ./out || code=$?
    [ "$code" = 3 ] || fail "$1: exit code $code, not 3"
}
build "the first build"
rm message.zon
if "$bs" build-exe -target x86_64-linux m.zig --cache-dir local --global-cache-dir global -femit-bin=out >log 2>&1; then
    fail "the build without message.zon succeeded"
fi
grep -q 'message.zon' log || fail "the build without message.zon did not name it"
echo '"hello"' >message.zon
BS_CACHE_CHECK=1 BS_CACHE_VERIFY=1 build "the build after message.zon is back"
echo '"bye"' >message.zon
BS_CACHE_CHECK=1 BS_CACHE_VERIFY=1 build "the build after message.zon changed"
rm message.zon
if "$bs" build-exe -target x86_64-linux m.zig --cache-dir local --global-cache-dir global -femit-bin=out >log 2>&1; then
    fail "the second build without message.zon succeeded"
fi
