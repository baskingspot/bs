#!/bin/sh
# `zig build test`: a donor from a program whose `--dep`s give an import
# name another module. revo's two test programs swap their modules: in
# the first, capi's `@import("revo")` is the root module (a.zig); in the
# second, the root module is b.zig and `revo` names a.zig. The second
# build's donor is the first's, whose capi.zig is the same file with the
# same contents, so its nodes, naming the root module, passed for this
# build's: the import gave b.zig.
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
    echo "bs donor with other module deps failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

cat >a.zig <<'EOF2'
const capi = @import("capi");
pub const baselib: u8 = 3;
pub fn main() u8 {
    return capi.get();
}
EOF2
cat >b.zig <<'EOF2'
const capi = @import("capi");
pub fn main() u8 {
    return capi.get() + 1;
}
EOF2
cat >capi.zig <<'EOF2'
const revo = @import("revo");
pub fn get() u8 {
    return revo.baselib;
}
EOF2
# $1 the program, $2 its exit code, then its module arguments.
build() {
    p=$1 want=$2
    shift 2
    BS_CACHE_TIMING=1 BS_CACHE_CHECK=1 "$bs" build-exe -target x86_64-linux "$@" --cache-dir "local-$p" --global-cache-dir global "-femit-bin=$p" >log 2>&1 || fail "the build of $p"
    code=0
    "./$p" || code=$?
    [ "$code" = "$want" ] || fail "$p exited with $code, not $want"
}
build a 3 --dep capi -Mroot=a.zig --dep revo=root -Mcapi=capi.zig
build b 4 --dep capi -Mroot=b.zig --dep revo=revo -Mcapi=capi.zig --dep capi -Mrevo=a.zig
grep -q "replaying donor .*, another program's" log || fail "b did not replay a's donor"
