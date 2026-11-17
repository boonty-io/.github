#!/usr/bin/env bash
# Decide the `pr:<phase>` status label of one pull request.
#
# Input (environment, never arguments, so no value reaches a shell parser):
#   PR_STATE    open | closed          (a live read of the PR, never event.action)
#   PR_DRAFT    true | false
#   PLAN_LINE   line 1 of the PR's plan comment (the newest-updated
#               `boonty-plan/v1` comment from a writer), or empty
#
# Output, for `>> "$GITHUB_OUTPUT"`:
#   label=pr:<phase>   the one label the PR should carry, or empty for none
#   reason=<text>      why, one line
#
# Only an open draft carries a label: out of draft, GitHub's own ready / queue
# / merged state takes over. Line 1 is parsed strictly: at most 256
# characters, the exact marker shape, a JSON object whose `phase` and
# `status` come from fixed lists. Anything else is no label.
set -euo pipefail

state="${PR_STATE:-}"
draft="${PR_DRAFT:-}"
line="${PLAN_LINE:-}"

out() {
  printf 'label=%s\n' "$1"
  printf 'reason=%s\n' "$(printf '%s' "$2" | tr -d '\r\n' | cut -c1-200)"
  exit 0
}

[ "$state" = "open" ] || out "" "PR is ${state:-unknown} (closed or merged): no label"
[ "$draft" = "true" ] || out "" "PR is not a draft: GitHub's ready state takes over"
[ -n "$line" ] || out "" "no plan comment from a writer"
[ "${#line}" -le 256 ] || out "" "plan line 1 is too long (${#line} chars)"

re='^<!-- boonty-plan/v1 (\{[^}]*\}) -->$'
[[ "$line" =~ $re ]] || out "" "plan line 1 does not have the marker shape"
json="${BASH_REMATCH[1]}"

phase="$(jq -er '.phase | select(type == "string")' <<<"$json" 2>/dev/null)" || out "" "plan line 1 is not json with a string phase"
status="$(jq -er '.status | select(type == "string")' <<<"$json" 2>/dev/null)" || out "" "plan line 1 has no string status"

case "$status" in
  planning|in-progress|blocked|ready|merged|closed) ;;
  *) out "" "plan status is not one of the allowed values" ;;
esac
case "$phase" in
  test|implementation|gates|ci|blocked) out "pr:$phase" "draft in phase $phase" ;;
  plan) out "" "plan phase: no label" ;;
  *) out "" "plan phase is not one of the allowed values" ;;
esac
