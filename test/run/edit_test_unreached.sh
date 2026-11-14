#!/bin/sh
# `zig build test`: `bs test` after an edit that stops a file from being
# imported. The file's tests must not run. An eager edit build loaded the
# last build's `builtin.test_functions`, whose pointers to the old tests
# made their file's root type again, and that file's scan queued its
# tests; a lazy one linked the old list's data, which named functions it
# no longer linked (`Incremental.recordDelta`). The flag sits in a file
# (an eager build) and in a module whose root moves (a lazy build that
# replays the first build as a donor).
#   $1 bs  $2 scratch directory
#   $3 a global cache holding std's ZIR, which the empty one starts from
set -eu
unset ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR BS_CACHE BS_CACHE_VERIFY BS_CACHE_CHECK BS_CACHE_DONOR BS_CACHE_REPLAY
rm -rf "$2"
mkdir -p "$2"
bs=$(realpath "$1") work=$(realpath "$2")
zir=$(realpath "$3")/bs/zir

fail() {
    echo "bs test after an import of a file with tests went failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

# $1 the directory, $2 how root.zig reads the flag, $3 where it imports
# other.zig: `comptime` or `test`.
project() {
    mkdir -p "$work/$1/global/bs" "$work/$1/a" "$work/$1/b"
    cp -r "$zir" "$work/$1/global/bs"
    cd "$work/$1"
    printf 'const on = %s;\n\n%s {\n    if (on) _ = @import("other.zig");\n}\n\ntest "root" {}\n' "$2" "$3" >root.zig
    printf 'test "other" {\n    return error.OtherRan;\n}\n' >other.zig
    echo 'pub const flag = true;' >a/opts.zig
    echo 'pub const flag = false;' >b/opts.zig
}
# $1 the step, $2 whether other.zig's test runs, then the arguments.
build() {
    step=$1 other=$2
    shift 2
    "$bs" test --test-no-exec -target x86_64-linux "$@" --cache-dir local --global-cache-dir global -femit-bin=t >log 2>&1 || fail "$step"
    if [ "$other" = yes ]; then
        if ./t >log 2>&1; then fail "$step: other.zig's test did not run"; fi
        grep -q "other.test.other...FAIL (OtherRan)" log || fail "$step: other.zig's test did not run"
    else
        ./t >log 2>&1 || fail "$step: other.zig's test ran"
        grep -q "tests passed" log || fail "$step: no tests ran"
    fi
}

# The flag in a file: the edit builds are eager.
for at in comptime test; do
    project "file-$at" '@import("flag.zig").flag' "$at"
    cp a/opts.zig flag.zig
    build "the first build ($at)" yes root.zig
    cp b/opts.zig flag.zig
    BS_CACHE_REPLAY=eager BS_CACHE_VERIFY=1 BS_CACHE_CHECK=1 build "the eager build without other.zig ($at)" no root.zig
    cp a/opts.zig flag.zig
    BS_CACHE_REPLAY=eager BS_CACHE_VERIFY=1 BS_CACHE_CHECK=1 build "the eager build with other.zig again ($at)" yes root.zig
done

# The flag in a module: lazy builds, the first from a donor.
project module '@import("opts").flag' comptime
build "the first build (module)" yes --dep opts -Mroot=root.zig -Mopts=a/opts.zig
BS_CACHE_VERIFY=1 BS_CACHE_CHECK=1 build "the lazy build without other.zig" no --dep opts -Mroot=root.zig -Mopts=b/opts.zig
cp a/opts.zig b/opts.zig
BS_CACHE_VERIFY=1 BS_CACHE_CHECK=1 build "the lazy build with other.zig again" yes --dep opts -Mroot=root.zig -Mopts=b/opts.zig
