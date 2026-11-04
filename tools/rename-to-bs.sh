#!/usr/bin/env bash
# Renames zap to bs in the working tree of a checkout, and moves the design
# notes to docs/slop/. Run from the repository root.
#
# The output depends only on the tree, so tools/rebase-past-rename.sh can
# replay it on each commit of a branch and land the branch past the rename
# commit without conflicts in the renamed lines. Keep it that way: no dates,
# no environment, no network.
#
# What it does, in order:
#   1. The package fingerprint, which is tied to the package name, gets one
#      fixed new value.
#   2. Three things whose size is the name's: the SipHash key in
#      src/link/Atom.zig keeps its 16 bytes; the panic test in build.zig
#      expects the column that the shorter bs_overflow call in
#      test/obj/main.zig moves to; the modules test expects the shorter
#      test/obj/mod/config.zon; and test/obj/cache.sh's sorted symbol
#      list puts bs_add first, where zap_add sorted last.
#   3. ZAP_ environment variables become BS_, the word ZAP becomes BS,
#      and every other zap, Zap becomes bs, Bs. The on-disk magic numbers
#      (ZAPMAN14, ZAPPACK5, ...) keep their bytes: the cache directories
#      move, so no old file is read under the new name.
#   4. docs/architecture.md moves to docs/slop/architecture.md, and every
#      reference follows it.
#   5. Pointers to the gitignored upstream/LICENSE point at LICENSE-ZIG.
#   6. Paths that carry the name are renamed.
#   7. zig fmt formats the Zig sources that `just lint` checks.
#
# bench/results/ holds dated records and stays verbatim. This script and
# tools/rebase-past-rename.sh keep naming the old spellings.
set -euo pipefail

# Without zig fmt, a replayed commit would undo the rename commit's
# formatting.
command -v zig >/dev/null || {
	echo "rename-to-bs.sh needs zig on PATH" >&2
	exit 1
}

keep=(
	':(exclude)bench/results'
	':(exclude)tools/rename-to-bs.sh'
	':(exclude)tools/rebase-past-rename.sh'
)

mapfile -t files < <(git grep -I -l -i -E 'zap|docs/architecture\.md|upstream/LICENSE' -- . "${keep[@]}" || true)
if [ "${#files[@]}" -gt 0 ]; then
	perl -pi -e '
		s/^(\s*\.fingerprint = )0x8ac41f4e15ab0cc9/${1}0xdf1e3b5c1cc8641c/;
		s/"zap symbol key!!"/"bs symbol key!!!"/;
		s/"main\.zig:14:39: 0x"/"main.zig:14:38: 0x"/;
		s/"zap 3 (\S+) 31 31 app/"zap 3 $1 30 31 app/;
		s/"c_two d_one zap_add "/"zap_add c_two d_one "/;
		s/ZAP_/BS_/g;
		s/\bZAP\b/BS/g;
		s/zap/bs/g;
		s/Zap/Bs/g;
		s{docs/architecture\.md}{docs/slop/architecture.md}g;
		s{upstream/LICENSE}{LICENSE-ZIG}g;
	' "${files[@]}"
fi

if [ -e docs/architecture.md ]; then
	mkdir -p docs/slop
	git mv -f docs/architecture.md docs/slop/architecture.md
fi

git ls-files -- . "${keep[@]}" | grep zap | while read -r path; do
	new=${path//zap/bs}
	mkdir -p "$(dirname "$new")"
	git mv -f "$path" "$new"
done

# A file that does not parse is left as it is; `just lint` reports it.
zig fmt src build.zig build.zig.zon tools bench >/dev/null || true
