#!/usr/bin/env bash
# Set the `pr:<phase>` status label of one pull request from live reads.
#
#   REPO=<owner/name> PR=<number> GH_TOKEN=... scripts/pr-status.sh
#
# Never trusts the triggering event: it reads the PR (open/closed, draft) and
# its comments now, takes the newest-updated `boonty-plan/v1` comment whose
# author has admin, maintain or write permission (collaborators API, never
# author_association), hands line 1 to scripts/pr-status-decide.sh, then makes
# the PR carry exactly that label: it adds the wanted one first (creating it
# when missing), then removes every other `pr:*` label, so a crash leaves two,
# never zero. Labels written with the job's GITHUB_TOKEN start no workflow.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${REPO:?REPO is required}" "${PR:?PR is required}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "::error::bad REPO" >&2; exit 2; }
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "::error::bad PR" >&2; exit 2; }

pr="$(gh api "repos/$REPO/pulls/$PR")"
state="$(jq -r '.state' <<<"$pr")"
draft="$(jq -r '.draft' <<<"$pr")"

# Fetch first, so a failed read stops the run (set -e) instead of reading
# as "no plan comment" and stripping a correct label.
comments="$(gh api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" \
  --jq '.[] | select(.body | startswith("<!-- boonty-plan/v1 ")) | {updated_at, login: .user.login, line: (.body | split("\n")[0] | rtrimstr("\r") | .[0:300])} | @json')"
ordered="$(jq -sc 'sort_by(.updated_at) | reverse | .[]' <<<"$comments")"

line=""
declare -A perm=()
# Newest first; one JSON object per line so no body text can split a record.
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  login="$(jq -r '.login' <<<"$rec")"
  [[ "$login" =~ ^[A-Za-z0-9-]+(\[bot\])?$ ]] || continue
  if [ -z "${perm[$login]+x}" ]; then
    p="$(gh api "repos/$REPO/collaborators/$login/permission" --jq '.permission' 2>/dev/null || true)"
    case "$p" in admin|maintain|write) perm[$login]=1 ;; *) perm[$login]=0 ;; esac
  fi
  if [ "${perm[$login]}" = 1 ]; then
    line="$(jq -r '.line' <<<"$rec")"
    break
  fi
done <<<"$ordered"

decision="$(PR_STATE="$state" PR_DRAFT="$draft" PLAN_LINE="$line" "$here/pr-status-decide.sh")"
want="$(sed -n 's/^label=//p' <<<"$decision")"
reason="$(sed -n 's/^reason=//p' <<<"$decision")"
echo "pr-status: #$PR state=$state draft=$draft -> '${want:-none}' ($reason)"

have="$(gh api "repos/$REPO/issues/$PR/labels?per_page=100" --jq '.[].name | select(startswith("pr:"))')"

enc() { printf '%s' "$1" | jq -sRr @uri; }
if [ -n "$want" ] && ! grep -qxF -- "$want" <<<"$have"; then
  if ! gh api "repos/$REPO/labels/$(enc "$want")" >/dev/null 2>&1; then
    gh api -X POST "repos/$REPO/labels" -f name="$want" -f color=ededed \
      -f description="Draft PR status, set from its boonty-plan/v1 comment" >/dev/null 2>&1 || true
  fi
  gh api -X POST "repos/$REPO/issues/$PR/labels" -f "labels[]=$want" >/dev/null
fi
failed=0
while IFS= read -r old; do
  [ -n "$old" ] && [ "$old" != "$want" ] || continue
  if ! gh api -X DELETE "repos/$REPO/issues/$PR/labels/$(enc "$old")" >/dev/null 2>&1; then
    echo "::warning title=pr-status::could not remove '$old' from #$PR"
    failed=1
  fi
done <<<"$have"
# A label left behind is a wrong state: the run says so instead of passing.
exit "$failed"
