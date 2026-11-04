#!/usr/bin/env bash
# Moves the current branch past the zap-to-bs rename commit, with no
# conflicts in the renamed lines. Run from the repository root, with zig on
# PATH and no uncommitted changes to tracked files.
#
#   tools/rebase-past-rename.sh [RENAME_COMMIT [ONTO]]
#
# RENAME_COMMIT defaults to the commit on origin/main whose subject is
# "all: rename zap to bs", and ONTO to origin/main. Fetch first.
#
# 1. Rebase the branch onto the rename commit's parent. Conflicts here are
#    ordinary ones with other work on main: resolve them, finish with
#    `git rebase --continue`, and run this script again.
# 2. Rebuild each commit of the branch on top of the rename commit, as
#    tools/rename-to-bs.sh's output on that commit's tree. The rename commit
#    is the same script's output on its parent, so each rebuilt commit
#    differs from the one before it only by the branch's own change, renamed.
#    Messages and authors are kept.
# 3. Rebase the branch onto ONTO, for the commits that landed after the
#    rename. Conflicts here are ordinary ones again.
set -euo pipefail

subject='all: rename zap to bs'
if [ $# -gt 0 ]; then
	rename=$(git rev-parse --verify "$1^{commit}")
else
	rename=$(git log origin/main --format=%H --fixed-strings --grep="$subject" -1)
	if [ -z "$rename" ]; then
		echo "no commit \"$subject\" on origin/main; fetch, or pass the commit" >&2
		exit 1
	fi
fi
before=$(git rev-parse "$rename^")
onto=${2:-origin/main}

branch=$(git symbolic-ref --quiet --short HEAD) || {
	echo "check out a branch first" >&2
	exit 1
}
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	echo "commit or stash your changes to tracked files first" >&2
	exit 1
fi
if git merge-base --is-ancestor "$rename" HEAD; then
	echo "$branch already contains $(git rev-parse --short "$rename"); rebase it onto $onto as usual"
	exit 0
fi

# The script as of the rename commit, kept outside the tree: the replay
# checks out trees from before the rename.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git show "$rename:tools/rename-to-bs.sh" >"$tmp/rename-to-bs.sh"

if ! git rebase "$before"; then
	echo "resolve the conflicts with main, run 'git rebase --continue', then run $0 again" >&2
	exit 1
fi

commits=$(git rev-list --reverse "$before..HEAD")
git checkout --quiet --detach "$rename"
for c in $commits; do
	git read-tree --reset -u "$c"
	bash "$tmp/rename-to-bs.sh"
	git add -u
	git commit --quiet --allow-empty --no-verify -C "$c"
done
git branch -f "$branch" HEAD
git checkout --quiet "$branch"
echo "$branch: $(printf '%s\n' "$commits" | grep -c .) commits replayed on $(git rev-parse --short "$rename")"

if git merge-base --is-ancestor "$rename" "$onto" 2>/dev/null; then
	if ! git rebase "$onto"; then
		echo "resolve the conflicts with $onto and run 'git rebase --continue'; the rename is done" >&2
		exit 1
	fi
	echo "$branch: on $onto"
fi
