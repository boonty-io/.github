#!/usr/bin/env bash
# Apply the on-demand-ci ruleset to one repository, merging that repo's own
# suite contexts into the required checks. Needs repo admin.
#
#   rulesets/apply.sh boonty-io/api-webapp "ci/tests,ci/build,ci/verify"
#
# Idempotent: updates the ruleset named `on-demand-ci` when it exists.
# It does NOT delete the repo's existing "Protected branches" ruleset —
# retire that one by hand once this one is verified, so the required set
# never has a gap.
#
# Each suite context is pinned to integration_id 15368 (GitHub Actions): a
# commit status can be posted by any token with repo:status, so an unpinned
# `ci/*` context could be faked by a PAT. `ci-status` posts with github.token,
# which GitHub attributes to that App. The `gates/*` contexts stay unpinned:
# the gate runner posts them from a developer's own token.
set -euo pipefail
repo="${1:?owner/repo}"; contexts="${2:?comma-separated suite contexts}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload="$(jq --arg ctx "$contexts" '
  .rules |= map(if .type == "required_status_checks" then
    .parameters.required_status_checks += ($ctx | split(",") | map({context: ., integration_id: 15368})) else . end)' \
  "$here/on-demand-ci.ruleset.json")"
existing="$(gh api "repos/$repo/rulesets" --jq '.[] | select(.name == "on-demand-ci") | .id' || true)"
if [ -n "$existing" ]; then
  gh api -X PUT "repos/$repo/rulesets/$existing" --input <(printf '%s' "$payload") --jq '{id,name,enforcement}'
else
  gh api -X POST "repos/$repo/rulesets" --input <(printf '%s' "$payload") --jq '{id,name,enforcement}'
fi
