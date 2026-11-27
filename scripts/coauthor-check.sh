#!/usr/bin/env bash
# coauthor-check — fail a PR whose commits attribute authorship to an AI
# assistant with a Co-Authored-By trailer (ai-config shared/40: the human is
# the author; AI help is an `Assisted-by: Claude Code` trailer).
#
# Run from the caller's checkout, with its history fetched, by
# .github/workflows/coauthor-check.yml. Env:
#   BASE_SHA  the PR's base commit (pull_request.base.sha)
#   HEAD_SHA  the PR's head commit (pull_request.head.sha)
#
# The pattern is not restated here. Every consumer synced by ai-config carries
# its matcher at .claude/hooks/check-commit-msg-coauthor.sh, and this script
# runs that file AS IT IS ON BASE_SHA, never the head's copy: a PR cannot
# neuter the check that judges it. A base without the matcher (a consumer on
# an ai-config release older than the matcher) is skipped with a notice.
#
# Every commit in BASE_SHA..HEAD_SHA is judged, merges included. A range git
# cannot read fails: a scan that could not run has not passed.
set -uo pipefail

MATCHER_PATH=.claude/hooks/check-commit-msg-coauthor.sh

for v in BASE_SHA HEAD_SHA; do
  if [ -z "${!v:-}" ]; then
    echo "::error title=coauthor-check::$v is not set."
    exit 1
  fi
done

work="$(mktemp -d)" || exit 1
trap 'rm -rf "$work"' EXIT

if ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
  echo "::error title=coauthor-check::could not read the base commit ${BASE_SHA}."
  exit 1
fi
if ! git cat-file -e "${BASE_SHA}:${MATCHER_PATH}" 2>/dev/null; then
  echo "::notice title=coauthor-check::no ${MATCHER_PATH} on the base ${BASE_SHA}: this repository's ai-config predates the matcher, so nothing was checked."
  exit 0
fi
if ! git show "${BASE_SHA}:${MATCHER_PATH}" > "$work/matcher.sh"; then
  echo "::error title=coauthor-check::could not read ${MATCHER_PATH} at ${BASE_SHA}."
  exit 1
fi

if ! shas="$(git rev-list "${BASE_SHA}..${HEAD_SHA}" 2>/dev/null)"; then
  echo "::error title=coauthor-check::could not list the commits in ${BASE_SHA}..${HEAD_SHA}."
  exit 1
fi

n=0; bad=0
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  n=$((n + 1))
  if ! git log -1 --format=%B "$sha" > "$work/msg"; then
    echo "::error title=coauthor-check::could not read the message of ${sha}."
    exit 1
  fi
  if ! out="$(bash "$work/matcher.sh" "$work/msg" 2>&1)"; then
    bad=$((bad + 1))
    echo "::error title=coauthor-check::$(git rev-parse --short "$sha") carries an AI Co-Authored-By trailer. Record AI help as 'Assisted-by: Claude Code' instead."
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
done <<< "$shas"

if [ "$bad" -gt 0 ]; then
  echo "${bad} of ${n} commit(s) rejected."
  exit 1
fi
echo "${n} commit(s) checked, none carries an AI Co-Authored-By trailer."
