#!/bin/sh
# shellcheck disable=SC2086 # $args is an argument list, split on purpose
# `zig build test` on an aarch64-macos host: executables with object,
# archive and C source inputs through the cache, as cache.sh checks them
# on ELF. Each build, edited in a scratch copy, must give the bytes of a
# build without the cache at the same file name (the code signature's
# identifier is the output's name), with its dSYM, must verify its
# signature and run, and edit builds check themselves against full builds
# (BS_CACHE_VERIFY, BS_CACHE_CHECK).
#   $1 bs  $2 upstream zig  $3 test/link_input  $4 scratch directory
set -eu
unset ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR BS_CACHE BS_CACHE_VERIFY BS_CACHE_CHECK
rm -rf "$4"
mkdir -p "$4"
bs=$(realpath "$1") zig=$2 src=$(realpath "$3") work=$(realpath "$4")
cd "$work"
cp "$src"/macho_main.c "$src"/macho_member.c "$src"/macho_other.c "$src"/tls.c "$src"/libc_main.zig "$src"/libc.c "$src"/force_undefined.c "$src"/force_undefined.zig .
export BS_ZIG="$zig"

fail() {
    echo "bs aarch64-macos link input cache check failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

# $1 what the build must say (BS_CACHE_TIMING), $2 what the program
# prints to stderr; the build's log stays in cached.log. The build without
# the cache runs once per set of inputs, in a directory of its own.
build() {
    BS_CACHE_TIMING=1 BS_CACHE_CHECK=1 BS_CACHE_VERIFY=1 "$bs" $args --cache-dir local --global-cache-dir global -femit-bin=main >log 2>&1 || fail "$1"
    cp log cached.log
    grep -qF -- "$1" log || fail "expected '$1'"
    full=full-$( (echo "$args"; cat ./*.zig ./*.c ./*.m ./*.o ./*.a 2>/dev/null) | shasum -a 256 | cut -c1-16)
    if [ ! -d "$full" ]; then
        mkdir "$full"
        BS_CACHE=off "$bs" $args --global-cache-dir global -femit-bin="$full/main" >log 2>&1 || { rm -rf "$full"; fail "$1: without the cache"; }
    fi
    cmp -s main "$full/main" || fail "$1: the output differs from a build without the cache"
    if [ -d "$full/main.dSYM" ]; then
        cmp -s main.dSYM/Contents/Resources/DWARF/main "$full/main.dSYM/Contents/Resources/DWARF/main" || fail "$1: the dSYM differs from a build without the cache"
    fi
    codesign --verify --strict main 2>>log || fail "$1: the output's signature"
    ./main >out 2>&1 || fail "$1: the program failed: $(cat out)"
    grep -qF -- "$2" out || fail "$1: the program printed '$(cat out)'"
}

lazy() {
    grep -qF "from the manifest" cached.log || fail "$1: expected a lazy edit build"
}
eager() {
    ! grep -qF "from the manifest" cached.log || fail "$1: expected an eager edit build"
}

# Objects and an archive: a GOT load of archive data, a constructor, C
# thread-locals (TLV descriptors), libSystem imports, a reference to a Zig
# export, and Objective-C exceptions, whose unwinding takes the objects'
# compact unwind and LSDA.
cat >main.zig <<'ZIG'
const std = @import("std");
extern fn read_second() c_int;
extern fn c_tls() c_int;
extern fn c_greet() [*:0]const u8;
extern fn c_try() c_int;
export fn zig_twice(x: c_int) c_int {
    return 2 * x;
}
pub fn main() void {
    std.debug.print("{d} {d} {s} {d}\n", .{ read_second(), c_tls(), c_greet(), c_try() });
}
ZIG
cat >greet.c <<'C'
#include <stdio.h>
int zig_twice(int);
static char buf[32];
const char *c_greet(void) { snprintf(buf, sizeof buf, "hello %d", zig_twice(21)); return buf; }
C
cat >try.m <<'M'
#import <Foundation/Foundation.h>
int c_try(void) {
    @try {
        @throw [NSException exceptionWithName:@"x" reason:@"y" userInfo:nil];
    } @catch (NSException *e) {
        return (int)[[e name] length] + 6;
    }
    return 0;
}
M
objects() {
    for c in macho_main macho_member macho_other tls greet; do "$zig" cc -c $c.c -o $c.o; done
    "$zig" cc -c try.m -o try.o
    rm -f libm1.a
    "$zig" ar --format=darwin rcs libm1.a macho_member.o macho_other.o
}
objects
args="build-exe -lobjc -framework Foundation main.zig macho_main.o tls.o greet.o try.o libm1.a"
build "no manifest" "126 712 hello 42 7"
build "not relinking" "126 712 hello 42 7"
rm -rf main main.dSYM
build "no input changed; relinked" "126 712 hello 42 7"
sed -i '' 's/{d} {d} {s} {d}\\n/{d} {d} {s} {d}!\\n/' main.zig
build "inputs changed, first $work/main.zig" "126 712 hello 42 7!"
lazy "the Zig code changed"
# Only an object changed: it relinks with the last build's atoms.
sed -i '' 's/hello %d/HELLO %d/' greet.c
objects
build "1 link inputs changed and nothing else; relinked" "126 712 HELLO 42 7!"
# An archive member changed.
sed -i '' 's/second = 41/second = 40/' macho_member.c
objects
build "1 link inputs changed and nothing else; relinked" "123 712 HELLO 42 7!"
# The changed object imports another name: a build.
sed -i '' 's/return buf; }/puts(""); return buf; }/' greet.c
objects
build "not relinking: the changed objects need other" "123 712 HELLO 42 7!"
# Without BS_CACHE_VERIFY, a lazy edit build leaves a log; a relink from
# it links what the edit build did.
sed -i '' 's/{d}!\\n/{d}?\\n/' main.zig
BS_CACHE_TIMING=1 "$bs" $args --cache-dir local --global-cache-dir global -femit-bin=main >cached.log 2>&1 || fail "an edit without verifying"
lazy "an edit without verifying"
mkdir edited
mv main edited/main
BS_CACHE_TIMING=1 "$bs" $args --cache-dir local --global-cache-dir global -femit-bin=main >log 2>&1 || fail "a relink from the log"
grep -qF "no input changed; relinked" log || fail "expected a relink from the log"
cmp -s main edited/main || fail "the relink from the log differs from the edit build's output"
codesign --verify --strict main 2>>log || fail "the relink from the log's signature"
{ ./main >out 2>&1 && grep -qF -- "7?" out; } || fail "the relink from the log lost the edit"

# A C source with -lc: its object is a link input.
args="build-exe -lc libc_main.zig libc.c"
build "no manifest" "1 123"
sed -i '' 's/return 2 \* x/return 3 * x/' libc_main.zig
build "inputs changed, first $work/libc_main.zig" "x=21 twice=63"
lazy "-lc: the Zig code changed"
sed -i '' 's/x=%d/X=%d/' libc.c
build "1 link inputs changed and nothing else; relinked" "X=21 twice=63"

# A C main, inside its section's atom after another function: the entry
# point is an alias (`Emit.finish`), which a relink makes again.
cat >cmain.c <<'C'
#include <stdio.h>
__attribute__((noinline)) int before(int x) { return x * 2; }
int main(void) { printf("c main %d\n", before(21)); return 0; }
C
"$zig" cc -O2 -c cmain.c -o cmain.o
args="build-exe -lc cmain.o"
build "no manifest" "c main 42"
rm -rf main main.dSYM
build "no input changed; relinked" "c main 42"
sed -i '' 's/x \* 2/x * 3/' cmain.c
"$zig" cc -O2 -c cmain.c -o cmain.o
build "1 link inputs changed and nothing else; relinked" "c main 63"

# `--force_undefined` names Darwin's symbols: it keeps a Zig export and
# pulls an archive member.
"$zig" cc -c force_undefined.c -o force_undefined.o
"$zig" ar --format=darwin rcs libfu.a force_undefined.o
args="build-exe -lc force_undefined.zig libfu.a --force_undefined _keep_me --force_undefined _fu_from_archive"
build "no manifest" "pulled, keep_me 42"
rm -rf main main.dSYM
build "no input changed; relinked" "pulled, keep_me 42"
sed -i '' 's/return 42/return 40 + 2/' force_undefined.zig
build "inputs changed, first $work/force_undefined.zig" "pulled, keep_me 42"
lazy "--force_undefined: the Zig code changed"
