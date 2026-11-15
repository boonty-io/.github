#!/usr/bin/env bash
# Deployment environment protection as code, compared only. The desired state
# of a repository's environments lives in rulesets/environments/<repo>.json:
# a JSON array of
#   {name, can_admins_bypass, prevent_self_review,
#    reviewers: [{type, name}],            # name: a user's login or a team's slug
#    deployment_branch_policy: {protected_branches, custom_branch_policies},
#    branch_policies: [{name, type}]}      # the custom deployment branches
#
#   environments.sh plan <owner> <file>...   print the diff; exit 2 on drift
#
# There is no apply, on purpose: these environments guard the keys that
# apply uses, so a change to them is made by an owner in Settings, by hand,
# and this only reports whether live still matches the file. The repository
# is the file's basename without `.json`. A live environment that no file
# names is not reported. Comparison ignores order. Any failed read exits 1,
# never "unchanged". Needs `gh` with read access to the repository.
set -euo pipefail

usage() { echo "usage: $0 plan <owner> <file>..." >&2; exit 64; }
[ "${1:-}" = plan ] && [ $# -ge 3 ] || usage
owner="$2"; shift 2

NORM='def norm: {
  name, can_admins_bypass, prevent_self_review,
  reviewers: (.reviewers | sort_by(.type, .name)),
  deployment_branch_policy,
  branch_policies: (.branch_policies | sort_by(.type, .name))
};'

# Names go into `gh api` paths: letters, digits, `.`, `_` and `-` only, and
# never `.` or `..`.
valid() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$1" != . ] && [ "$1" != .. ]; }

for f in "$@"; do
  valid "$(basename "$f" .json)" || { echo "error: $f: invalid repository name \"$(basename "$f" .json)\"" >&2; exit 1; }
  jq -e 'type == "array" and all(.[]; (.name | type) == "string" and (.name | length) > 0)' "$f" >/dev/null 2>&1 \
    || { echo "error: $f is not a JSON array of named environments" >&2; exit 1; }
  dup="$(jq -r 'map(.name) | group_by(.) | map(select(length > 1) | .[0]) | join(", ")' "$f")"
  [ -z "$dup" ] || { echo "error: $f has duplicate environment names: $dup" >&2; exit 1; }
  for en in $(jq -r '.[].name | @base64' "$f"); do
    en="$(printf '%s' "$en" | base64 -d)"
    valid "$en" || { echo "error: $f: invalid environment name \"$en\"" >&2; exit 1; }
  done
done

live() { # live <owner/repo> <environment> → the environment in the file's shape
  local raw pol='[]'
  raw="$(gh api "repos/$1/environments/$2")" || return 1
  if jq -e '.deployment_branch_policy.custom_branch_policies == true' <<<"$raw" >/dev/null; then
    pol="$(gh api "repos/$1/environments/$2/deployment-branch-policies" --paginate)" || return 1
    pol="$(jq -sc '[.[].branch_policies[] | {name, type}]' <<<"$pol")" || return 1
  fi
  jq -c --argjson pol "$pol" '
    [.protection_rules[]? | select(.type == "required_reviewers")][0] as $r
    | {name, can_admins_bypass,
       prevent_self_review: ($r.prevent_self_review // false),
       reviewers: [($r.reviewers // [])[] | {type, name: (.reviewer.login // .reviewer.slug)}],
       deployment_branch_policy,
       branch_policies: $pol}' <<<"$raw"
}

drift=0
for f in "$@"; do
  name="$(basename "$f" .json)"; repo="$owner/$name"
  for en in $(jq -r '.[].name | @base64' "$f"); do
    en="$(printf '%s' "$en" | base64 -d)"
    want="$(jq -S --arg n "$en" "$NORM"' .[] | select(.name == $n) | norm' "$f")"
    have="$(live "$repo" "$en")" || { echo "error: could not read environment $en of $repo" >&2; exit 1; }
    have="$(jq -S "$NORM"' norm' <<<"$have")"
    if [ "$want" = "$have" ]; then
      echo "$name/$en: unchanged"
    else
      echo "$name/$en: drift"; drift=1
      diff <(echo "$have") <(echo "$want") | sed 's/^/    /' || true
    fi
  done
done
[ "$drift" -eq 0 ] || exit 2
