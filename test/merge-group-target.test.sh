#!/usr/bin/env bash
# Tests for scripts/merge-group-target.sh. Run: test/merge-group-target.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sut="$here/../scripts/merge-group-target.sh"
S=0123456789abcdef0123456789abcdef01234567
fail=0; n=0
expect() { # <head_ref> <base_ref> <want rc> [<want stdout>]
  n=$((n + 1))
  local got rc
  got="$("$sut" "$1" "$2" 2>/dev/null)"; rc=$?
  if [ "$rc" = "$3" ] && { [ "$rc" != 0 ] || [ "$got" = "$4" ]; }; then
    echo "✓ [$1 | $2] rc=$rc"
  else
    echo "✗ [$1 | $2] want rc=$3 ${4:+stdout=$(printf '%q' "$4")}, got rc=$rc stdout=$(printf '%q' "$got")"; fail=$((fail + 1))
  fi
}
nl=$'\n'
# the shape GitHub gives: refs/heads/gh-readonly-queue/<base>/pr-<n>-<sha>
expect "refs/heads/gh-readonly-queue/staging/pr-42-$S" refs/heads/staging 0 "pr=42${nl}base=staging"
expect "refs/heads/gh-readonly-queue/main/pr-7-$S" refs/heads/main 0 "pr=7${nl}base=main"
# a base with a slash is kept whole
expect "refs/heads/gh-readonly-queue/release/2026.11/pr-3-$S" refs/heads/release/2026.11 0 "pr=3${nl}base=release/2026.11"
# the queue ref must name the same base as the event's base_ref
expect "refs/heads/gh-readonly-queue/main/pr-42-$S" refs/heads/staging 1
# not a queue ref at all
expect "refs/heads/feat/x" refs/heads/staging 1
expect "refs/heads/gh-readonly-queue/staging/pr-42" refs/heads/staging 1
expect "refs/heads/gh-readonly-queue/staging/pr-x-$S" refs/heads/staging 1
expect "refs/heads/gh-readonly-queue/staging/pr-42-${S:0:12}" refs/heads/staging 1
expect "refs/heads/gh-readonly-queue/staging/pr-042-$S" refs/heads/staging 1
expect "gh-readonly-queue/staging/pr-42-$S" refs/heads/staging 1
# trailing junk or a newline cannot smuggle a second line into GITHUB_OUTPUT
expect "refs/heads/gh-readonly-queue/staging/pr-42-$S${nl}pr=1" refs/heads/staging 1
expect "refs/heads/gh-readonly-queue/sta${nl}ging/pr-42-$S" "refs/heads/sta${nl}ging" 1
# empty inputs
expect "" refs/heads/staging 1
expect "refs/heads/gh-readonly-queue/staging/pr-42-$S" "" 1
echo "$((n - fail))/$n passed"
[ "$fail" = 0 ]
