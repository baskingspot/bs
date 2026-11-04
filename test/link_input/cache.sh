#!/bin/sh
# `zig build test`: an executable with object and archive inputs through
# the cache. The objects are link-only inputs: each build, edited in a
# scratch copy, must give the bytes of a build without the cache, and edit
# builds check themselves against full builds (BS_CACHE_VERIFY,
# BS_CACHE_CHECK). C sources' objects are link inputs the same way.
#   $1 bs  $2 upstream zig  $3 test/link_input  $4 scratch directory
#   $5 the part to check, each its own build step, so that they run at once:
#      objects, c-sources, lc-objects, shared, shared-objects
#   $6 a global cache holding std's ZIR, which the empty one starts from
set -eu
unset ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR BS_CACHE BS_CACHE_VERIFY BS_CACHE_CHECK
rm -rf "$4"
mkdir -p "$4"
bs=$(realpath "$1") zig=$2 src=$(realpath "$3") work=$(realpath "$4") part=$5
mkdir -p "$work/global/bs"
cp -r "$6/bs/zir" "$work/global/bs"
cd "$work"
cp "$src"/main.zig "$src"/lib.c "$src"/tls.c "$src"/tlsie.c "$src"/a1.c "$src"/a2.c "$src"/libc.c "$src"/libc_main.zig "$src"/copy.c "$src"/asm_main.zig "$src"/asm.h "$src"/asm_cpp.S "$src"/asm_plain.s .
export BS_ZIG="$zig"

fail() {
    echo "bs link input cache check failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

objects() {
    "$zig" cc -fcommon -c lib.c -o lib.o
    "$zig" cc -fPIC -c tls.c -o tls.o
    "$zig" cc -fPIC -c tlsie.c -o tlsie.o
    for a in a1 a2; do
        "$zig" cc -c $a.c -o $a.o
        rm -f lib$a.a
        "$zig" ar rcs lib$a.a $a.o
    done
}

# $1 what the build must say (BS_CACHE_TIMING), $2 what the program
# prints; the build's log stays in cached.log. The build without the cache
# runs once per set of inputs: a build that changed none compares with the
# last one's bytes.
build() {
    BS_CACHE_TIMING=1 BS_CACHE_CHECK=1 BS_CACHE_VERIFY=1 "$bs" $args --cache-dir local --global-cache-dir global -femit-bin=main >log 2>&1 || fail "$1"
    cp log cached.log
    grep -qF -- "$1" log || fail "expected '$1'"
    full=full-$( (echo "$args"; cat ./*.zig ./*.c ./*.h ./*.S ./*.s ./*.o ./*.a ./*.so 2>/dev/null) | sha256sum | cut -c1-16)
    [ -f "$full" ] || BS_CACHE=off "$bs" $args --global-cache-dir global -femit-bin="$full" >log 2>&1 || fail "$1: without the cache"
    cmp -s main "$full" || fail "$1: the output differs from a build without the cache"
    ./main >out 2>&1 || fail "$1: the program failed"
    grep -qF -- "$2" out || fail "$1: the program printed '$(cat out)'"
}

# Whether the last build was a lazy edit build, which links from the
# manifest: not after its objects changed, which may need what the last
# build did not generate.
lazy() {
    grep -qF "from the manifest" cached.log || fail "$1: expected a lazy edit build"
}
eager() {
    ! grep -qF "from the manifest" cached.log || fail "$1: expected an eager edit build"
}

case $part in
objects)
args="build-exe main.zig lib.o tls.o tlsie.o liba1.a -la2 -L."
objects
build "no manifest" "hello from C"
build "not relinking" "hello from C"
# A relink from the manifest converts the inputs again.
rm main
build "no input changed; relinked" "hello from C"
# An object changed: built again, nothing to analyze.
sed -i 's/hello from C/HELLO from C/' lib.c
objects
build "inputs changed, first $work/lib.o" "HELLO from C"
eager "an object changed"
# Data that the Zig code's comptime extern pointers name moves in its
# section: the slots and the variable's data are bound again.
sed -i 's|/\* PAD \*/|int c_pad[16] = {1};|' lib.c
objects
build "inputs changed, first $work/lib.o" "extern data data 30 30"
eager "extern data moved"
# An archive's member changed.
sed -i 's/1 + a2/2 + a2/' a1.c
objects
build "inputs changed, first $work/liba1.a" "HELLO from C"
# The Zig code changed.
sed -i 's/{d} {d} {d}\\n", .{ c_tls()/{d} {d} {d}!\\n", .{ c_tls()/' main.zig
build "inputs changed, first $work/main.zig" "HELLO from C"
lazy "the Zig code changed"
grep -qF -- "!" out || fail "the Zig edit did not take"
# An edit to data that a comptime extern pointer names: a lazy build
# cannot bind it to the objects, which its relink converts, so it goes
# eager.
sed -i 's/.msg = c_msg + 7/.msg = c_msg + 6/' main.zig
build "a declaration's data takes the address of a link input's symbol" "extern data  data 30 30"
eager "the extern data's offset changed"
# A constant that a function reads, whose addresses the link binds as
# the slots (aliases of `extaddr` keys): a lazy edit relinks with them.
sed -i 's/{ c_msg, c_msg + 7 }/{ c_msg, c_msg + 8 }/' main.zig
build "inputs changed, first $work/main.zig" "extern data ata 26 111 2"
lazy "a function's constant changed"
# A new external symbol in one: the externs changed, so it is eager.
sed -i 's/fn_table\[i\](1) });/fn_table[i](1) });\n    std.debug.print("more {d}\\n", .{([_]*const fn () callconv(.c) c_int{@extern(*const fn () callconv(.c) c_int, .{ .name = "unused_member_fn" })})[i]()});/' main.zig
build "external symbols changed" "more 1"
eager "a function's constant names a new symbol"
# Without BS_CACHE_VERIFY, whose full build writes a new base, a lazy
# edit build leaves a log; a relink from it links what the edit build did.
sed -i 's/{d} {d} {d}!\\n"/{d} {d} {d}?\\n"/' main.zig
BS_CACHE_TIMING=1 "$bs" $args --cache-dir local --global-cache-dir global -femit-bin=main >cached.log 2>&1 || fail "an edit without verifying"
lazy "an edit without verifying"
mv main edited
BS_CACHE_TIMING=1 "$bs" $args --cache-dir local --global-cache-dir global -femit-bin=main >log 2>&1 || fail "a relink from the log"
grep -qF "no input changed; relinked" log || fail "expected a relink from the log"
cmp -s main edited || fail "the relink from the log differs from the edit build's output"
./main >out 2>&1 && grep -qF -- "?" out || fail "the relink from the log lost the edit"
;;

c-sources)
# C sources: their records' objects are the link inputs. An edited source
# keeps its object's path, so the build must not take the old object for
# the last build's while Clang compiles the new one.
args="build-exe libc_main.zig libc.c -lc"
# A cold first build: the global cache has no donor yet.
build "cache: recorded" "x=21 twice=42"
build "not relinking" "x=21 twice=42"
sed -i 's/x=%d/X=%d/' libc.c
# The Zig code replays, eagerly: the object is not the manifest's yet.
build "0 inputs changed" "X=21 twice=42"
eager "a C source changed"
build "not relinking" "X=21 twice=42"
# Touched, not changed: the record hits, and the link is the last one.
touch libc.c
build "not relinking" "X=21 twice=42"
sed -i 's/return 2 \* x/return 3 * x/' libc_main.zig
build "inputs changed, first $work/libc_main.zig" "X=21 twice=63"

# Assembly: `.S` records its include from the depfile; `.s` has none, so
# its record holds the source alone, and an edit to either compiles again.
args="build-exe asm_main.zig asm_cpp.S asm_plain.s"
build "cache: recorded" "42 42"
build "not relinking" "42 42"
sed -i 's/imul %rsi, %rax/imul %rsi, %rax\n\tadd $1, %rax/' asm_plain.s
build "0 inputs changed" "42 43"
sed -i 's/ASM_ADD 40/ASM_ADD 50/' asm.h
build "0 inputs changed" "52 43"

# -lc alone: a lazy edit links from the manifest by number, and binds a
# function's constant's glibc addresses as the slots.
cat >lc.zig <<'ZIG'
const std = @import("std");
extern fn strlen([*:0]const u8) usize;
extern fn abs(c_int) c_int;
pub fn main() void {
    var i: usize = 0;
    _ = &i;
    const fns = [_]*const fn (c_int) callconv(.c) c_int{&abs};
    std.debug.print("lc {d} {d}\n", .{ fns[i](-3), strlen("four") });
}
ZIG
args="build-exe -lc lc.zig"
rm -rf local
build "" "lc 3 4"
rm main
build "no input changed; relinked" "lc 3 4"
sed -i 's/fns\[i\](-3)/fns[i](-5)/' lc.zig
build "inputs changed, first $work/lc.zig" "lc 5 4"
lazy "-lc: a function's constant changed"

# A library of C only: an unchanged build keeps the archive and takes the
# objects from the batch summary, and a header edit after it still
# compiles again and writes the archive. The files are older than the
# racy window, so that the first build writes the summary.
printf '#define LIBV 1\n' >libv.h
printf '#include "libv.h"\nint libv_a(void) { return LIBV; }\n' >libv_a.c
printf '#include "libv.h"\nint libv_b(void) { return LIBV + 1; }\n' >libv_b.c
touch -d '1 minute ago' libv.h libv_a.c libv_b.c
clib() { BS_CACHE_TIMING=1 "$bs" build-lib libv_a.c libv_b.c --cache-dir local --global-cache-dir global -femit-bin=libv.a >log 2>&1 || fail "C library: $1"; }
clib "first build"
first=$(stat -c %i libv.a)
clib "no change"
[ "$(stat -c %i libv.a)" = "$first" ] || fail "C library: an unchanged build wrote the archive"
grep -qF "cache: 2 C objects from the batch summary" log || fail "C library: an unchanged build did not use the batch summary"
sed -i 's/LIBV 1/LIBV 7/' libv.h
clib "header edit"
objdump -d libv.a | grep -A4 '<libv_a>:' | grep -qF '$0x7' || fail "C library: the header edit is not in the archive"
rm libv.a
clib "archive deleted"
[ -f libv.a ] || fail "C library: a deleted archive was not written"
;;

lc-objects)
# -lc with objects: a C object's glibc imports, its reference to a Zig
# export, and the executable's copies of glibc data that GCC's -fPIE reads
# PC-relative.
args="build-exe -lc -target x86_64-linux-gnu libc_main.zig libc.o copy.o"
lc_objects() {
    "$zig" cc -fPIC -c libc.c -o libc.o
    gcc -fPIE -c copy.c -o copy.o
}
if command -v gcc >/dev/null; then
    lc_objects
    build "no manifest" "x=21 twice=42"
    rm main
    build "no input changed; relinked" "x=21 twice=42"
    # Lazy, though std.start's `@export(&main, ...)` depends on `main`.
    sed -i 's/c_fmt(21)/c_fmt(22)/' libc_main.zig
    build "inputs changed, first $work/libc_main.zig" "x=22 twice=44"
    lazy "-lc: the Zig code changed"
    sed -i 's/x=%d/X=%d/' libc.c
    lc_objects
    build "inputs changed, first $work/libc.o" "X=22 twice=44"
    eager "-lc: an object changed"
fi
;;

shared | shared-objects)
# Shared libraries: link-only inputs too, after the objects. A relink
# parses them again for the dynamic tables; a changed one replays eagerly.
cp "$src"/shared.c "$src"/shared.map "$src"/shared_main.zig "$src"/shared_user.c .
so() {
    "$zig" cc -shared -fPIC shared.c -Wl,--version-script=shared.map -Wl,-soname,libshared.so -o libshared.so
}
cat >so_main.zig <<'ZIG'
const std = @import("std");
extern fn shared_get() c_int;
extern fn shared_twice(x: c_int) c_int;
pub fn main() void {
    std.debug.print("{d} {d}\n", .{ shared_get(), shared_twice(21) });
}
ZIG
so
;;
*)
    fail "unknown part '$part'"
    ;;
esac

case $part in
shared)
# Without objects: the numbered relink.
args="build-exe -lc -lshared -L. so_main.zig"
build "no manifest" "42 42"
build "not relinking" "42 42"
rm main
build "no input changed; relinked" "42 42"
sed -i 's/shared_twice(21)/shared_twice(22)/' so_main.zig
build "inputs changed, first $work/so_main.zig" "42 44"
lazy ".so: the Zig code changed"
sed -i 's/shared_twice(22)/shared_twice(23)/' so_main.zig
BS_CACHE_TIMING=1 "$bs" $args --cache-dir local --global-cache-dir global -femit-bin=main >cached.log 2>&1 || fail ".so: an edit without verifying"
lazy ".so: an edit without verifying"
mv main edited
BS_CACHE_TIMING=1 "$bs" $args --cache-dir local --global-cache-dir global -femit-bin=main >log 2>&1 || fail ".so: a relink from the log"
grep -qF "no input changed; relinked" log || fail ".so: expected a relink from the log"
cmp -s main edited || fail ".so: the relink from the log differs from the edit build's output"
# The same symbols, other code.
sed -i 's/return 2 \* x/return x + x/' shared.c
so
build "inputs changed, first $work/libshared.so" "42 46"
eager ".so: the library changed"
# A library that no longer defines a name the Zig code imports.
sed -i 's/^int shared_twice.*$//; s/global: shared_twice;//' shared.c shared.map
so
if BS_CACHE_TIMING=1 BS_CACHE_CHECK=1 "$bs" $args --cache-dir local --global-cache-dir global -femit-bin=main >log 2>&1; then
    fail ".so: a dropped symbol linked"
fi
grep -qF "shared_twice" log || fail ".so: the error does not name the dropped symbol"
! grep -qiE "panic|unreachable" log || fail ".so: a dropped symbol crashed bs"
;;

shared-objects)
# With objects: the keyed relink, whose C object reads the library's data
# PC-relative (GCC's -fPIE), so the executable copies it.
if command -v gcc >/dev/null; then
    gcc -fPIE -c shared_user.c -o shared_user.o
    args="build-exe -lc -lshared -L. shared_main.zig shared_user.o"
    build "no manifest" "42 143 42 143"
    rm main
    build "no input changed; relinked" "42 143 42 143"
    sed -i 's/shared_twice(21)/shared_twice(22)/' shared_main.zig
    build "inputs changed, first $work/shared_main.zig" "42 143 44 143"
    lazy ".so with objects: the Zig code changed"
    sed -i 's/return 2 \* x/return x + x/' shared.c
    so
    build "inputs changed, first $work/libshared.so" "42 143 44 143"
    eager ".so with objects: the library changed"
fi
;;
esac
