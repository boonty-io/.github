#!/usr/bin/env bash
# Cases for scripts/coauthor-check.sh. Run: test/coauthor-check.test.sh
# Each case builds a throwaway repository: a base commit that may carry a
# matcher at .claude/hooks/check-commit-msg-coauthor.sh, then PR commits.
# The stub matcher rejects any message with a line starting
# "Co-Authored-By: Claude", which is all the script needs from it.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="$here/../scripts/coauthor-check.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0; n=0

# shellcheck disable=SC2016 # the stub's $1 is expanded when the stub runs
STUB='#!/usr/bin/env bash
if grep -q "^Co-Authored-By: Claude" "$1"; then echo "commit-msg: rejected — AI trailer" >&2; exit 1; fi
exit 0'

# repo <name> <matcher at base: yes|no>  → prints the repo dir; BASE is its HEAD
repo() {
  local d="$work/$1"
  git init -q -b main "$d"
  git -C "$d" config user.name t; git -C "$d" config user.email t@example.com
  git -C "$d" config commit.gpgsign false
  if [ "$2" = yes ]; then
    mkdir -p "$d/.claude/hooks"; printf '%s\n' "$STUB" > "$d/.claude/hooks/check-commit-msg-coauthor.sh"
  fi
  echo base > "$d/f"; git -C "$d" add -A; git -C "$d" commit -q -m "chore: base"
  echo "$d"
}
commit() { # <dir> <message>
  echo "$RANDOM" >> "$1/f"; git -C "$1" add -A; git -C "$1" commit -q -m "$2"
}

# expect <name> <dir> <base> <head> <want exit 0|1> <output substring>
expect() {
  n=$((n + 1))
  local out rc=0
  out="$(cd "$2" && BASE_SHA="$3" HEAD_SHA="$4" "$check" 2>&1)" || rc=$?
  if [ "$rc" != "$5" ] || [[ "$out" != *"$6"* ]]; then
    echo "✗ $1: want exit $5 and '$6', got exit $rc:"; printf '%s\n' "$out" | sed 's/^/    /'
    fail=$((fail + 1)); return
  fi
  echo "✓ $1"
}

# 1. a clean PR range passes
d="$(repo clean yes)"; b="$(git -C "$d" rev-parse HEAD)"
commit "$d" "feat: x"; commit "$d" $'fix: y\n\nAssisted-by: Claude Code'
expect "clean range passes" "$d" "$b" "$(git -C "$d" rev-parse HEAD)" 0 "2 commit"

# 2. one AI trailer anywhere in the range fails, naming that commit
d="$(repo dirty yes)"; b="$(git -C "$d" rev-parse HEAD)"
commit "$d" "feat: x"; commit "$d" $'fix: y\n\nCo-Authored-By: Claude <noreply@anthropic.com>'; bad="$(git -C "$d" rev-parse --short HEAD)"; commit "$d" "chore: z"
expect "AI trailer fails and names the commit" "$d" "$b" "$(git -C "$d" rev-parse HEAD)" 1 "$bad"

# 3. the matcher comes from BASE: a PR that neuters its own copy is still judged
d="$(repo neuter yes)"; b="$(git -C "$d" rev-parse HEAD)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/.claude/hooks/check-commit-msg-coauthor.sh"
commit "$d" $'feat: x\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
expect "matcher read from base, not head" "$d" "$b" "$(git -C "$d" rev-parse HEAD)" 1 "rejected"

# 4. a base without the matcher (consumer not bumped yet) is skipped, not failed
d="$(repo nomatcher no)"; b="$(git -C "$d" rev-parse HEAD)"
commit "$d" $'feat: x\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
expect "no matcher at base skips" "$d" "$b" "$(git -C "$d" rev-parse HEAD)" 0 "no .claude/hooks/check-commit-msg-coauthor.sh"

# 5. a range git cannot read fails instead of passing
d="$(repo broken yes)"; b="$(git -C "$d" rev-parse HEAD)"
expect "unreadable range fails" "$d" "$b" "0000000000000000000000000000000000000001" 1 "could not"

# 6. missing inputs fail
expect "missing BASE_SHA fails" "$d" "" "$b" 1 "BASE_SHA"

echo "$((n - fail))/$n passed"
[ "$fail" -eq 0 ]
