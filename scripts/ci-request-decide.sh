#!/usr/bin/env bash
# Decide whether a GitHub event is a request to run CI on a pull request.
#
# Reads the event payload (path in $GITHUB_EVENT_PATH, or $1) and prints
# `key=value` lines suitable for `>> "$GITHUB_OUTPUT"`:
#
#   go=true|false        run CI, or do nothing
#   pr=<number>          the pull request (only when go=true)
#   source=label|comment|ready  what made the request
#   workflows=<csv>      override from `/ci <a.yml,b.yml>`, else empty
#   hint=true            (only with go=false) a new head that has not been
#                        requested: post the "how to run CI" pending statuses
#   pr=<number>          also set with hint=true
#   reason=<text>        why go=false (only when go=false)
#
# Three request shapes, and nothing else:
#   1. `pull_request` / `labeled` where the label is $CI_LABEL (default `ci:run`).
#   2. `issue_comment` / `created` on a pull request whose body is `/ci` or
#      `/ci <workflows>` and whose author is OWNER, MEMBER or COLLABORATOR.
#   3. `pull_request` / `ready_for_review`, or `opened` as a non-draft: the PR
#      is ready to be reviewed, so CI runs without anyone asking. Drafts never
#      run on their own — that is the spend this model removes.
#
# `opened` (draft), `reopened` and `synchronize` are not requests: they give
# hint=true. Dependabot is skipped for 3 and for the hint: its token is
# read-only, so the dispatch and the status would fail.
#
# Everything else is `go=false` — a different label, a comment on an issue,
# a `/ci` from a first-time contributor, an edited comment. The decision is a pure function of the payload so it can be tested
# with fixtures and never needs the network.
set -euo pipefail

event_path="${1:-${GITHUB_EVENT_PATH:-}}"
event_name="${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME is required}"
ci_label="${CI_LABEL:-ci:run}"
ci_command="${CI_COMMAND:-/ci}"

if [ -z "$event_path" ] || [ ! -r "$event_path" ]; then
  echo "go=false"
  echo "reason=event payload not readable: '${event_path}'"
  exit 0
fi

no() {
  echo "go=false"
  # The reason quotes payload values (a label name, an association); strip
  # anything that could start a new `key=value` line in $GITHUB_OUTPUT.
  printf 'reason=%s\n' "$(printf '%s' "$1" | tr -d '\r\n')"
  exit 0
}

case "$event_name" in
  pull_request)
    action="$(jq -r '.action // ""' "$event_path")"
    pr="$(jq -r '.pull_request.number // ""' "$event_path")"
    author="$(jq -r '.pull_request.user.login // ""' "$event_path")"
    draft="$(jq -r '.pull_request.draft // false' "$event_path")"
    case "$action" in
      labeled) ;;
      ready_for_review|opened|reopened|synchronize)
        [ -n "$pr" ] || no "pull_request.number missing"
        [ "$author" != "dependabot[bot]" ] || no "Dependabot pull request: its token is read-only"
        if [ "$action" = "ready_for_review" ] || { [ "$action" = "opened" ] && [ "$draft" = "false" ]; }; then
          echo "go=true"
          echo "pr=${pr}"
          echo "source=ready"
          echo "workflows="
          exit 0
        fi
        echo "go=false"
        echo "hint=true"
        echo "pr=${pr}"
        printf 'reason=%s\n' "pull_request ${action} is not a request (draft or new head): hint only"
        exit 0
        ;;
      *) no "pull_request action is '${action}', not a request" ;;
    esac
    label="$(jq -r '.label.name // ""' "$event_path")"
    [ "$label" = "$ci_label" ] || no "label '${label}' is not '${ci_label}'"
    [ -n "$pr" ] || no "pull_request.number missing"
    echo "go=true"
    echo "pr=${pr}"
    echo "source=label"
    echo "workflows="
    ;;
  issue_comment)
    action="$(jq -r '.action // ""' "$event_path")"
    [ "$action" = "created" ] || no "issue_comment action is '${action}', not 'created'"
    is_pr="$(jq -r 'if .issue.pull_request then "yes" else "no" end' "$event_path")"
    [ "$is_pr" = "yes" ] || no "comment is on an issue, not a pull request"
    assoc="$(jq -r '.comment.author_association // ""' "$event_path")"
    case "$assoc" in
      OWNER|MEMBER|COLLABORATOR) ;;
      *) no "author_association '${assoc}' may not request CI" ;;
    esac
    body="$(jq -r '.comment.body // ""' "$event_path")"
    # First line only; `/ci` alone, or `/ci a.yml,b.yml` (workflow file names).
    first="$(printf '%s\n' "$body" | head -n 1 | tr -d '\r')"
    cmd_re="^${ci_command}([[:space:]]+([A-Za-z0-9_.,-]+))?[[:space:]]*$"
    if ! [[ "$first" =~ $cmd_re ]]; then
      no "comment does not start with '${ci_command}'"
    fi
    workflows="${BASH_REMATCH[2]:-}"
    pr="$(jq -r '.issue.number // ""' "$event_path")"
    [ -n "$pr" ] || no "issue.number missing"
    echo "go=true"
    echo "pr=${pr}"
    echo "source=comment"
    echo "workflows=${workflows}"
    ;;
  *)
    no "event '${event_name}' is not a CI request"
    ;;
esac
