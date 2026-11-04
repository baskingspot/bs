#!/bin/sh
# `zig build test`: a lazy edit build of a compiler_rt file whose old ZIR
# is gone (the global cache's maintenance evicts superseded ZIR first)
# must still build what a full build does. The file loads only when
# analysis requests its helper, after the other inputs were mapped, so
# the build cannot map its old instructions: it builds again eagerly.
#   $1 zap  $2 scratch directory  $3 zig lib directory
#   $4 a global cache holding std's ZIR, which the empty one starts from
set -eu
unset ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR ZAP_CACHE ZAP_CACHE_VERIFY ZAP_CACHE_CHECK ZAP_CACHE_DONOR
rm -rf "$2"
mkdir -p "$2"
zap=$(realpath "$1") work=$(realpath "$2") lib=$(realpath "$3")
mkdir -p "$work/global/zap"
cp -r "$4/zap/zir" "$work/global/zap"
cd "$work"

fail() {
    echo "zap compiler_rt edit without old ZIR failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

cp -rs "$lib" lib
rm lib/compiler_rt/fmod.zig
cp "$lib/compiler_rt/fmod.zig" lib/compiler_rt/fmod.zig
cat >m.zig <<'EOF'
const std = @import("std");

pub fn main() void {
    var a: f64 = 7.5;
    var b: f64 = 2.0;
    _ = .{ &a, &b };
    std.debug.print("{d}\n", .{@rem(a, b)});
}
EOF
build() {
    "$zap" build-exe -target x86_64-linux m.zig --zig-lib-dir lib --cache-dir local --global-cache-dir global -femit-bin=out >log 2>&1 || fail "$1"
    [ "$(./out 2>&1)" = "1.5" ] || fail "$1: wrong output"
}
build "the first build"
# Every ZIR file goes, the old fmod.zig's with them.
rm -rf global/zap/zir
printf '// moved\n' | cat - "$lib/compiler_rt/fmod.zig" >lib/compiler_rt/fmod.zig
ZAP_CACHE_VERIFY=1 ZAP_CACHE_CHECK=1 ZAP_CACHE_TIMING=1 build "the edit build"
grep -q "no old ZIR to map" log || fail "the edit build did not build again eagerly"
