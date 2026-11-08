#!/usr/bin/env bash
# Tests for scripts/lean-diff-ok.sh on throwaway git repositories.
# Run: test/lean-diff-ok.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sut="$here/../scripts/lean-diff-ok.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
fail=0; n=0

# A repo with one commit on main and a branch `pr` holding the change.
repo() { # <name> → prints the repo dir; the caller adds the change on pr
  local d="$work/$1"
  git init -q -b main "$d"
  git -C "$d" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  printf 'old\n' > "$d/README.md"; git -C "$d" add README.md
  git -C "$d" -c user.name=t -c user.email=t@t commit -q -m readme
  git -C "$d" switch -q -c pr
  echo "$d"
}
commit() { git -C "$1" add -A && git -C "$1" -c user.name=t -c user.email=t@t commit -q -m change --allow-empty; }
expect() { # <name> <repo> <want exit>
  n=$((n + 1))
  "$sut" "$2" main "$(git -C "$2" rev-parse HEAD)" >/dev/null 2>&1; local rc=$?
  if [ "$rc" = "$3" ]; then echo "✓ $1 → $rc"; else echo "✗ $1: want $3, got $rc"; fail=$((fail + 1)); fi
}

d="$(repo docs)"; mkdir -p "$d/docs/a"; echo x > "$d/docs/a/b.md"; echo y > "$d/README.md"; commit "$d"
expect "docs and README only" "$d" 0
d="$(repo learnings)"; mkdir -p "$d/shared-learnings"; echo x > "$d/shared-learnings/x.md"; commit "$d"
expect "a learnings file" "$d" 0
d="$(repo delete)"; git -C "$d" rm -q README.md; commit "$d"
expect "a deleted README" "$d" 0
d="$(repo code)"; mkdir -p "$d/docs"; echo x > "$d/docs/a.md"; echo x > "$d/index.ts"; commit "$d"
expect "a .ts beside docs" "$d" 1
d="$(repo sh)"; mkdir -p "$d/docs"; echo x > "$d/docs/run.sh"; commit "$d"
expect "a script under docs/" "$d" 1
d="$(repo shared)"; mkdir -p "$d/shared"; echo x > "$d/shared/31.md"; commit "$d"
expect "shared/*.md is not docs" "$d" 1
d="$(repo agents)"; mkdir -p "$d/docs/x"; echo x > "$d/docs/x/AGENTS.md"; commit "$d"
expect "a nested AGENTS.md" "$d" 1
d="$(repo claude)"; mkdir -p "$d/docs"; echo x > "$d/docs/claude.md"; commit "$d"
expect "a nested claude.md, any case" "$d" 1
d="$(repo link)"; mkdir -p "$d/docs"; ln -s ../index.ts "$d/docs/a.md"; commit "$d"
expect "a symlink named docs/a.md" "$d" 1
d="$(repo exec)"; mkdir -p "$d/docs"; echo x > "$d/docs/a.md"; chmod +x "$d/docs/a.md"; commit "$d"
expect "an executable docs/a.md" "$d" 1
d="$(repo gitlink)"; sub="$(repo sub-src)"; git -C "$d" update-index --add --cacheinfo "160000,$(git -C "$sub" rev-parse HEAD),docs/sub.md"
git -C "$d" -c user.name=t -c user.email=t@t commit -q -m gitlink
expect "a gitlink named docs/sub.md" "$d" 1
d="$(repo newline)"; mkdir -p "$d/docs"; echo x > "$d/docs/a"$'\n'"b.md"; commit "$d"
expect "a path with a newline" "$d" 1
# A file that was executable on the base side: the old mode counts too.
d="$work/srcmode"; git init -q -b main "$d"; mkdir -p "$d/docs"; echo x > "$d/docs/a.md"; chmod +x "$d/docs/a.md"
git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@t commit -q -m base; git -C "$d" switch -q -c pr
chmod -x "$d/docs/a.md"; echo y > "$d/docs/a.md"; commit "$d"
expect "a docs file that was executable on the base" "$d" 1
d="$(repo empty)"; commit "$d"
expect "an empty diff" "$d" 2
# A replace ref that makes the non-docs head read as a docs-only commit.
d="$(repo replace)"; echo x > "$d/index.ts"; commit "$d"; real="$(git -C "$d" rev-parse HEAD)"
git -C "$d" switch -q -c fake main; mkdir -p "$d/docs"; echo x > "$d/docs/a.md"; commit "$d"
git -C "$d" replace "$real" "$(git -C "$d" rev-parse HEAD)"; git -C "$d" switch -q pr
n=$((n + 1)); "$sut" "$d" main "$real" >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ]; then echo "✓ a replace ref cannot pass a non-docs head → 1"; else echo "✗ replace ref: want 1, got $rc"; fail=$((fail + 1)); fi
# A graft that makes main descend from the non-docs head: honoured, the merge
# base would be the head itself and the diff empty (exit 2), never 1.
d="$(repo graft)"; echo x > "$d/index.ts"; commit "$d"; h="$(git -C "$d" rev-parse HEAD)"
mkdir -p "$d/.git/info"; echo "$(git -C "$d" rev-parse main) $h" > "$d/.git/info/grafts"
n=$((n + 1)); "$sut" "$d" main "$h" >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ]; then echo "✓ a graft file is ignored → 1"; else echo "✗ graft: want 1, got $rc"; fail=$((fail + 1)); fi
# The rules are ai-config's (scripts/gate.ts LEAN_SAFE_PATHS, LEAN_NEVER_PATHS,
# LEAN_MODES). This pins this repo's copy so a change here is deliberate; a
# change in ai-config must be copied here by hand (the server is the authority).
n=$((n + 1))
safe="$(sed -n "s/^LEAN_SAFE='\(.*\)'$/\1/p" "$sut")"; never="$(sed -n "s/^LEAN_NEVER='\(.*\)'$/\1/p" "$sut")"
if [ "$safe" = '^(shared-learnings/[^/]+\.md|docs/[^/]+(/[^/]+)*\.md|README\.md|CONTRIBUTING\.md)$' ] &&
   [ "$never" = '(^|/)(CLAUDE|CLAUDE\.local|AGENTS)\.md$' ]; then
  echo "✓ the rules equal the copy of ai-config's"
else
  echo "✗ the rules drifted: safe='$safe' never='$never'"; fail=$((fail + 1))
fi
echo; echo "$((n - fail))/$n passed"
[ "$fail" -eq 0 ]
