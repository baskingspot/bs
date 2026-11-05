#!/bin/sh
# `zig build test`: lazy edit builds after a function's type changes. Its
# inline decision's node keeps its key and result (`noinline`), so a
# lazy build that did not rewrite its subject left it naming the old
# function item, whose instruction the record remaps to the new code;
# the next build that decoded it interned a function of the old type
# with the new body and crashed analyzing it.
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
    echo "bs edit after a function's type changed failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

cat >m.zig <<'EOF2'
noinline fn f() u32 {
    return 7;
}
fn callF() u32 {
    if (@typeInfo(@TypeOf(f)).@"fn".param_types.len == 0) return f();
    return f(3);
}
pub fn main() u8 {
    return @intCast(callF());
}
EOF2
build() {
    "$bs" build-exe -target x86_64-linux m.zig --cache-dir local --global-cache-dir global -femit-bin=out >log 2>&1 || fail "$1"
    code=0
    ./out || code=$?
    [ "$code" = "$2" ] || fail "$1: exit code $code, not $2"
}
build "the first build" 7
sed -i 's/fn f() u32 {/fn f(a: u32) u32 {/; s/return 7;/return a + 4;/' m.zig
BS_CACHE_CHECK=1 build "the edit build that adds a parameter" 7
sed -i 's/return a + 4;/return a + 5;/' m.zig
BS_CACHE_CHECK=1 BS_CACHE_VERIFY=1 build "the edit build after it" 8
