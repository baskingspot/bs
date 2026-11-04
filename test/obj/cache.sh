#!/bin/sh
# `zig build test`: build-obj and build-lib through the cache. Each build
# of test/obj/lib.zig, edited in a scratch copy, must give the bytes of a
# build without the cache, and edit builds check themselves against full
# builds (ZAP_CACHE_VERIFY, ZAP_CACHE_CHECK).
#   $1 zap  $2 test/obj/lib.zig  $3 scratch directory
#   $4 build-obj or build-lib, each its own build step, so that they run at once
#   $5 a global cache holding std's ZIR, which the empty one starts from
set -eu
unset ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR ZAP_CACHE ZAP_CACHE_VERIFY ZAP_CACHE_CHECK
rm -rf "$3"
mkdir -p "$3"
zap=$(realpath "$1") src=$(realpath "$2") work=$(realpath "$3") cmd=$4 seed=$(realpath "$5")
mkdir -p "$work/global/zap"
cp -r "$seed/zap/zir" "$work/global/zap"
cd "$work"

fail() {
    echo "zap object cache check failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

# $1 command, $2 output, $3 what the build must say (ZAP_CACHE_TIMING);
# $inputs, more files to build with. The build without the cache runs once
# per version of lib.zig and the inputs.
inputs=
build() {
    ZAP_CACHE_TIMING=1 ZAP_CACHE_CHECK=1 ZAP_CACHE_VERIFY=1 "$zap" "$1" lib.zig $inputs --cache-dir local --global-cache-dir global "-femit-bin=$2" >log 2>&1 || fail "$1 ($3)"
    grep -qF -- "$3" log || fail "$1: expected '$3'"
    full=full-$( (echo "$inputs"; cat lib.zig $inputs) | sha256sum | cut -c1-16)-$2
    [ -f "$full" ] || ZAP_CACHE=off "$zap" "$1" lib.zig $inputs "-femit-bin=$full" >log 2>&1 || fail "$1 without the cache"
    cmp -s "$2" "$full" || fail "$1 ($3): the output differs from a build without the cache"
}

out=$([ $cmd = build-obj ] && echo lib.o || echo libx.a)
cp "$src" lib.zig
build $cmd $out "no manifest"
# Relinked from the manifest, with the numbered symbols.
rm $out
build $cmd $out "relinked"
# A lazy edit build.
sed 's/return counter + calls;/return counter + calls + 1;/' "$src" >lib.zig
build $cmd $out "linked 2"
# The imports change: built again eagerly.
sed 's/return c_twice(x) + 1;/return x + 1;/' "$src" >lib.zig
build $cmd $out "external symbols changed"
# An export comes back with the import.
cp "$src" lib.zig
build $cmd $out "replayed"
# The import becomes weak, then relinks with its flags from the manifest.
sed 's/return c_twice(x) + 1;/return @extern(?*const fn (u32) callconv(.c) u32, .{ .name = "c_twice", .linkage = .weak }).?(x) + 1;/' "$src" >lib.zig
build $cmd $out "external symbols changed"
rm $out
build $cmd $out "relinked"
[ $cmd = build-obj ] || [ "$(ar t libx.a)" = "lib.o" ] || fail "libx.a holds lib.o"

# As upstream's: a static library holds its object inputs as members after
# the Zig object, then the C objects, and leaves archive inputs out, also
# when it relinks or edits through the cache; an object leaves them out too.
if [ $cmd = build-lib ]; then
    printf 'export fn d_one() u32 { return 1; }\n' >d.zig
    printf 'int c_two(void) { return 2; }\n' >c.c
    ZAP_CACHE=off "$zap" build-obj d.zig --global-cache-dir global -femit-bin=d.o >log 2>&1 || fail "build-obj d.zig"
    ZAP_CACHE=off "$zap" build-lib d.zig --global-cache-dir global -femit-bin=libd.a >log 2>&1 || fail "build-lib d.zig"
    inputs="d.o libd.a c.c"
    rm -rf local global
    mkdir -p global/zap
    cp -r "$seed/zap/zir" global/zap
    cp "$src" lib.zig
    build build-lib libx.a "recorded"
    [ "$(ar t libx.a | tr '\n' ' ')" = "lib.o d.o c.o " ] || fail "libx.a holds lib.o, d.o and c.o"
    rm libx.a
    build build-lib libx.a "relinked"
    sed 's/return counter + calls;/return counter + calls + 1;/' "$src" >lib.zig
    build build-lib libx.a "linked 2"
    [ "$(ar t libx.a | tr '\n' ' ')" = "lib.o d.o c.o " ] || fail "the edited libx.a holds lib.o, d.o and c.o"
    ZAP_CACHE=off "$zap" build-obj lib.zig libd.a --global-cache-dir global -femit-bin=with-archive.o >log 2>&1 || fail "build-obj with an archive"
    ZAP_CACHE=off "$zap" build-obj lib.zig --global-cache-dir global -femit-bin=without-archive.o >log 2>&1 || fail "build-obj"
    cmp -s with-archive.o without-archive.o || fail "build-obj leaves archive inputs out"
    # Objects alone, without a Zig root or C (libvaxis's C API library):
    # archived every build, so a changed object shows up.
    "$zap" build-lib -static --name o d.o --cache-dir local --global-cache-dir global -femit-bin=libo.a >log 2>&1 || fail "build-lib of an object"
    [ "$(ar t libo.a)" = "d.o" ] || fail "libo.a holds d.o"
    printf 'export fn d_one() u32 { return 11; }\n' >d.zig
    ZAP_CACHE=off "$zap" build-obj d.zig --global-cache-dir global -femit-bin=d.o >log 2>&1 || fail "build-obj of the edited d.zig"
    "$zap" build-lib -static --name o d.o --cache-dir local --global-cache-dir global -femit-bin=libo.a >log 2>&1 || fail "build-lib of the changed object"
    ar p libo.a d.o | cmp -s - d.o || fail "libo.a holds the changed d.o"
fi

# As upstream's: an object merges its object inputs and C objects after the
# Zig object (a relocatable link, link/ElfMerge.zig), also when it relinks
# or edits through the cache.
if [ $cmd = build-obj ]; then
    printf 'export fn d_one() u32 { return 1; }\n' >d.zig
    printf 'int c_two(void) { return 2; }\n' >c.c
    ZAP_CACHE=off "$zap" build-obj d.zig --global-cache-dir global -femit-bin=d.o >log 2>&1 || fail "build-obj d.zig"
    inputs="d.o c.c"
    rm -rf local global
    mkdir -p global/zap
    cp -r "$seed/zap/zir" global/zap
    cp "$src" lib.zig
    build build-obj lib.o "recorded"
    defined=$(nm lib.o | awk '$2 == "T" && ($3 == "d_one" || $3 == "c_two" || $3 == "zap_add") { print $3 }' | sort | tr '\n' ' ')
    [ "$defined" = "c_two d_one zap_add " ] || fail "lib.o defines zap_add, d_one and c_two (got '$defined')"
    rm lib.o
    build build-obj lib.o "relinked"
    sed 's/return counter + calls;/return counter + calls + 1;/' "$src" >lib.zig
    build build-obj lib.o "linked 2"
fi
