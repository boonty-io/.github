#!/usr/bin/env bash
# gates-verify-post.sh <event> <queue_sha> <head_sha> <pr> <state> <description> <target_url>
#
# Posts the `gates/verified` commit status for gates-verify.yml (needs
# GH_TOKEN and GITHUB_REPOSITORY).
#
# - A pull request event posts <state> on <head_sha>, as given.
# - A `merge_group` event posts on <queue_sha>, never on the PR head. Any
#   state but `success` becomes `failure`: a pending, empty or unknown state
#   would hold the queue entry until the queue's timeout. The description
#   names the PR when there is one, loses any CR/LF, and is cut to GitHub's
#   140 characters.
#
# Exits 1 without posting when the sha it would post on is not 40 hex
# characters. Tested by test/gates-verify-post.test.sh.
set -euo pipefail
event="${1:-}" queue_sha="${2:-}" head_sha="${3:-}" pr="${4:-}"
state="${5:-}" description="${6:-}" target_url="${7:-}"
[ -n "$description" ] || description="gates-verify could not decide; see the run"

if [ "$event" = merge_group ]; then
  sha="$queue_sha"
  [ "$state" = success ] || state=failure
  [ -z "$pr" ] || description="#$pr: $description"
  description="${description//$'\n'/ }"
  description="${description//$'\r'/ }"
  description="${description:0:140}"
else
  sha="$head_sha"
  [ -n "$state" ] || state=failure
fi

[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || {
  echo "::error title=gates-verify::no commit to post gates/verified on ('$sha')"
  exit 1
}
gh api -X POST "repos/$GITHUB_REPOSITORY/statuses/$sha" \
  -f state="$state" -f context=gates/verified \
  -f description="$description" -f target_url="$target_url" --silent
echo "gates/verified=$state on $sha: $description"
