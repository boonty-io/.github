#!/usr/bin/env bash
# Apply the on-demand-ci ruleset to one repository, merging that repo's own
# suite contexts into the required checks. Needs repo admin.
#
#   rulesets/apply.sh boonty-io/api-webapp "lint,format,typecheck,build,unit,integration,e2e (1),…,tests-complete,verify"
#
# Idempotent: updates the ruleset named `on-demand-ci` when it exists.
# It does NOT delete the repo's existing "Protected branches" ruleset —
# retire that one by hand once this one is verified, so the required set
# never has a gap.
set -euo pipefail
repo="${1:?owner/repo}"; contexts="${2:?comma-separated suite contexts}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload="$(jq --arg ctx "$contexts" '
  .rules |= map(if .type == "required_status_checks" then
    .parameters.required_status_checks += ($ctx | split(",") | map({context: .})) else . end)' \
  "$here/on-demand-ci.ruleset.json")"
existing="$(gh api "repos/$repo/rulesets" --jq '.[] | select(.name == "on-demand-ci") | .id' || true)"
if [ -n "$existing" ]; then
  gh api -X PUT "repos/$repo/rulesets/$existing" --input <(printf '%s' "$payload") --jq '{id,name,enforcement}'
else
  gh api -X POST "repos/$repo/rulesets" --input <(printf '%s' "$payload") --jq '{id,name,enforcement}'
fi
