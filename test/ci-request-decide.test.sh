#!/usr/bin/env bash
# Fixture tests for scripts/ci-request-decide.sh. Run: test/ci-request-decide.test.sh
# Each case: <event name> <fixture> <expected key=value lines, comma separated>.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
decide="$here/../scripts/ci-request-decide.sh"
fail=0; n=0

expect() {
  local event="$1" fixture="$2" want="$3" label="${4:-ci:run}"
  n=$((n + 1))
  local got
  got="$(GITHUB_EVENT_NAME="$event" CI_LABEL="$label" "$decide" "$here/fixtures/$fixture")"
  local IFS=','
  for kv in $want; do
    if ! printf '%s\n' "$got" | grep -qxF -- "$kv"; then
      echo "✗ [$event/$fixture] expected line '$kv', got:"; printf '%s\n' "$got" | sed 's/^/    /'
      fail=$((fail + 1)); return
    fi
  done
  echo "✓ [$event/$fixture] $want"
}

# 1. the label that means "run CI" → go
expect pull_request labeled-ci-run.json 'go=true,pr=42,source=label'
# 2. any other label → nothing (this is the case a `types: [labeled]` suite would have turned green-by-skip)
expect pull_request labeled-other.json 'go=false'
# 3. a new head on a draft is not a request: no run, only the "how to run CI" hint
expect pull_request synchronize.json 'go=false,hint=true,pr=42'
# 3b. a new head on a PR that is ready for review runs CI (a rebase or a fix after the gates)
expect pull_request synchronize-ready.json 'go=true,pr=42,source=ready,workflows='
# 3c. reopening a ready PR runs CI too
expect pull_request reopened-ready.json 'go=true,pr=42,source=ready'
# 4. a custom label name is honoured
expect pull_request labeled-other.json 'go=true,pr=42' 'dependencies'
# 5. `/ci` from a member on a PR → go, no workflow override
expect issue_comment comment-ci-member.json 'go=true,pr=7,source=comment,workflows='
# 6. `/ci tests.yml` → override carried through
expect issue_comment comment-ci-with-workflows.json 'go=true,pr=7,workflows=tests.yml'
# 6b. `/ci force` re-runs even what already passed on this head
expect issue_comment comment-ci-force.json 'go=true,pr=7,source=comment,workflows=,force=true'
# 6c. `/ci force tests.yml` forces a subset
expect issue_comment comment-ci-force-with-workflows.json 'go=true,pr=7,workflows=tests.yml,force=true'
# 6d. a plain `/ci`, the label and a ready PR never force
expect issue_comment comment-ci-member.json 'force=false'
expect pull_request labeled-ci-run.json 'force=false'
expect pull_request ready-for-review.json 'force=false'
# 7. `/ci` from a first-time contributor → nothing
expect issue_comment comment-ci-outsider.json 'go=false'
# 8. `/ci` on an issue (not a PR) → nothing
expect issue_comment comment-ci-on-issue.json 'go=false'
# 9. a comment that merely mentions /ci → nothing
expect issue_comment comment-mentions-ci.json 'go=false'
# 10. an edited comment is not a new request
expect issue_comment comment-edited.json 'go=false'
# 11. `/cix` must not match `/ci`
expect issue_comment comment-cix.json 'go=false'
# 12. an unrelated event → nothing
expect push labeled-ci-run.json 'go=false'
# 13. an unreadable payload → nothing, and exit 0
expect pull_request does-not-exist.json 'go=false'
# 15. marking the PR ready for review runs CI without a label
expect pull_request ready-for-review.json 'go=true,pr=42,source=ready,workflows='
# 16. a PR opened as ready runs CI too
expect pull_request opened-ready.json 'go=true,pr=42,source=ready'
# 17. a draft never runs on its own — hint only
expect pull_request opened-draft.json 'go=false,hint=true,pr=42'
# 18. Dependabot: read-only token, neither a run nor a hint
n=$((n + 1))
out="$(GITHUB_EVENT_NAME=pull_request "$decide" "$here/fixtures/opened-dependabot.json")"
if printf '%s\n' "$out" | grep -qx 'go=false' && ! printf '%s\n' "$out" | grep -q '^hint='; then
  echo "✓ [pull_request/opened-dependabot.json] go=false, no hint"
else
  echo "✗ [pull_request/opened-dependabot.json] expected go=false and no hint, got:"; printf '%s\n' "$out" | sed 's/^/    /'; fail=$((fail + 1))
fi
# 20. a fork PR: read-only token, neither a run nor a hint
n=$((n + 1))
out="$(GITHUB_EVENT_NAME=pull_request "$decide" "$here/fixtures/ready-fork.json")"
if printf '%s\n' "$out" | grep -qx 'go=false' && ! printf '%s\n' "$out" | grep -q '^hint='; then
  echo "✓ [pull_request/ready-fork.json] go=false, no hint"
else
  echo "✗ [pull_request/ready-fork.json] expected go=false and no hint, got:"; printf '%s\n' "$out" | sed 's/^/    /'; fail=$((fail + 1))
fi
# 19. any other pull_request action → nothing, no hint
n=$((n + 1))
out="$(GITHUB_EVENT_NAME=pull_request "$decide" "$here/fixtures/closed.json")"
if printf '%s\n' "$out" | grep -qx 'go=false' && ! printf '%s\n' "$out" | grep -q '^hint='; then
  echo "✓ [pull_request/closed.json] go=false, no hint"
else
  echo "✗ [pull_request/closed.json] expected go=false and no hint, got:"; printf '%s\n' "$out" | sed 's/^/    /'; fail=$((fail + 1))
fi
# 21. Dependabot pushing to a ready PR: read-only token, neither a run nor a hint
n=$((n + 1))
out="$(GITHUB_EVENT_NAME=pull_request "$decide" "$here/fixtures/synchronize-dependabot.json")"
if printf '%s\n' "$out" | grep -qx 'go=false' && ! printf '%s\n' "$out" | grep -q '^hint='; then
  echo "✓ [pull_request/synchronize-dependabot.json] go=false, no hint"
else
  echo "✗ [pull_request/synchronize-dependabot.json] expected go=false and no hint, got:"; printf '%s\n' "$out" | sed 's/^/    /'; fail=$((fail + 1))
fi
# 14. a label name carrying a newline cannot start a second output line
n=$((n + 1))
out="$(GITHUB_EVENT_NAME=pull_request "$decide" "$here/fixtures/labeled-newline.json")"
if [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "2" ] && ! printf '%s\n' "$out" | grep -qE '^(go=true|pr=)' ; then
  echo "✓ [pull_request/labeled-newline.json] reason is one line"
else
  echo "✗ [pull_request/labeled-newline.json] expected exactly two output lines with the newline stripped, got:"; printf '%s\n' "$out" | sed 's/^/    /'; fail=$((fail + 1))
fi

echo; echo "$((n - fail))/$n passed"
[ "$fail" -eq 0 ]
