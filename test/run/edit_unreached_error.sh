#!/bin/sh
# `zig build test`: a lazy edit build reports errors only in units a full
# build reaches. `useAir` takes `thing`'s address, so it neither depends
# on `thing` nor is outdated when `thing` breaks: the lazy build assumes
# it reached as before and enters `thing` from it. But `create`, its only
# referrer, now fails before referring to it, so a full build never
# analyzes `thing`, and must not report its error (`Replay.errorsReached`;
# the edit hunter, seeds 5201 and 5202, on the zig compiler).
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
    echo "bs edit with an error in a unit no longer reached failed: $1" >&2
    [ -f log ] && cat log >&2
    exit 1
}

cat >air.zig <<'EOF'
const std = @import("std");
const leaf = @import("leaf.zig");
pub fn thing(k: u32) u32 {
    const s: [:leaf.sentinel]const u8 = "hi";
    var acc: u32 = s[0];
    var i: u32 = 0;
    while (i < k) : (i += 1) acc = std.math.rotl(u32, acc +% i *% 7 +% s[i % 2], 3);
    return acc;
}
EOF
cat >mid.zig <<'EOF'
const std = @import("std");
const air = @import("air.zig");
pub fn useAir(k: u32) void {
    var f: *const fn (u32) u32 = &air.thing;
    _ = &f;
    std.debug.print("{}\n", .{f(k)});
}
EOF
# $1 the sentinel, $2 `create`'s first statement.
write() {
    printf 'pub const sentinel: u8 = %s;\n' "$1" >leaf.zig
    printf 'const mid = @import("mid.zig");\npub fn main() void {\n    create(1);\n}\nfn create(n: u32) void {\n    %s\n    mid.useAir(k);\n}\n' "$2" >m.zig
}
# $1 the step, $2 the output expected, or empty for a compile error.
build() {
    if BS_CACHE_VERIFY=1 BS_CACHE_CHECK=1 "$bs" build-exe -target x86_64-linux m.zig --cache-dir local --global-cache-dir global -femit-bin=out >log 2>&1; then
        [ -n "$2" ] || fail "$1: compiled"
        [ "$(./out 2>&1)" = "$2" ] || fail "$1: wrong output"
    elif [ -n "$2" ]; then
        fail "$1"
    fi
}
write 0 'const k: u32 = n;'
build "the first build" 1664
write 1 'const k: u32 = "x"; _ = n;'
build "the build where create fails" ""
grep -q "m.zig:6:20: error\[type-mismatch\]" log || fail "create's error is missing"
if grep -q air.zig log; then fail "thing's error, which a full build does not reach, is reported"; fi
write 1 'const k: u32 = n;'
build "the build that reaches thing again" ""
grep -q "air.zig:4:41: error\[type-mismatch\]" log || fail "thing's error is missing"
write 0 'const k: u32 = n;'
build "the build with both fixed" 1664
