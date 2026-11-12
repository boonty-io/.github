#!/usr/bin/env bash
# merge-group-target.sh <merge_group.head_ref> <merge_group.base_ref>
#
# Names the pull request a merge-queue entry is for. GitHub builds each entry
# on `refs/heads/gh-readonly-queue/<base>/pr-<n>-<sha>`: the base the queue
# merges into, then the PR the entry adds on top of the entries ahead of it.
# Prints `pr=<n>` and `base=<base>` (GITHUB_OUTPUT lines) and exits 0, or
# prints nothing and exits 1 when the ref is not that shape or names another
# base than the event's base_ref. Each line is matched whole, so a newline in
# either input can never add a line to GITHUB_OUTPUT.
# Tested by test/merge-group-target.test.sh.
set -uo pipefail
head_ref="${1:-}" base_ref="${2:-}"
nl=$'\n'
case "$head_ref$base_ref" in *"$nl"*|*$'\r'*) exit 1 ;; esac
[[ "$base_ref" =~ ^refs/heads/(.+)$ ]] || exit 1
base="${BASH_REMATCH[1]}"
[[ "$head_ref" =~ ^refs/heads/gh-readonly-queue/(.+)/pr-([1-9][0-9]*)-[0-9a-f]{40}$ ]] || exit 1
[ "${BASH_REMATCH[1]}" = "$base" ] || exit 1
printf 'pr=%s\nbase=%s\n' "${BASH_REMATCH[2]}" "$base"
