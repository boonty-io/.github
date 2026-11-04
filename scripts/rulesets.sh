#!/usr/bin/env bash
# Repository rulesets as code. The desired state of each repository lives in
# rulesets/repos/<repo>.json: a JSON array of rulesets, the fields GitHub's
# REST API takes on create/update (name, target, enforcement, conditions,
# bypass_actors, rules). Names are unique per file.
#
#   rulesets.sh plan   <owner> <file>...   print the diff; exit 2 on drift
#   rulesets.sh apply  <owner> <file>...   create / update to match
#   rulesets.sh export <owner/repo>        print a repo's live state as a file
#
# The repository is the file's basename without `.json`. Only rulesets whose
# source is the repository itself are managed: organization rulesets are
# ignored, and a live ruleset that no file names is reported "unmanaged" and
# left alone — this never deletes. Comparison ignores order (rules by type,
# required checks by context, bypass actors). Any failed read stops the run
# before a write (exit 1). Needs `gh` authenticated with Administration
# read (plan, export) or read/write (apply) on the repositories.
#
# GitHub shows a ruleset's bypass actors only to a token that can write it:
# with a read-only token every live ruleset looks like it has none. Set
# RULESETS_SKIP_BYPASS=1 to plan with such a token: bypass actors are then
# left out of both sides and the output says so. apply refuses it, since its
# request bodies would then carry no bypass actors and clear them.
set -euo pipefail

usage() { echo "usage: $0 plan|apply <owner> <file>... | export <owner/repo>" >&2; exit 64; }

# The writable fields, in a canonical order.
NORM='def norm: {
  name, target, enforcement,
  conditions: (.conditions // {}),
  bypass_actors: ((.bypass_actors // []) | map({actor_id, actor_type, bypass_mode}) | sort_by(.actor_type, (.actor_id | tostring))),
  rules: ((.rules // []) | map(
    if .type == "required_status_checks" then .parameters.required_status_checks |= sort_by(.context, (.integration_id | tostring)) else . end)
    | sort_by(.type, (.parameters | tostring)))
};'

# Both readers run in `x="$(f)" || exit 1` context, where `set -e` is off,
# so every call checks its own status: a failed read must never look like
# "this repo has no rulesets" (that would make apply re-create them all).
list() { # list <owner/repo> → [{name, id}] of the repo's own rulesets
  local raw
  raw="$(gh api "repos/$1/rulesets" --paginate)" || return 1
  jq -c '[.[] | select(.source_type == "Repository") | {name, id}]' <<<"$raw" || return 1
}

live() { # live <owner/repo> <list> → normalized array of those rulesets, sorted by name
  local repo="$1" id one all="[]"
  for id in $(jq -r '.[].id' <<<"$2"); do
    one="$(gh api "repos/$repo/rulesets/$id")" || return 1
    all="$(jq -c --argjson one "$one" '. + [$one]' <<<"$all")" || return 1
  done
  jq "$NORM"' map(norm) | sort_by(.name)' <<<"$all"
}

check_file() {
  local f="$1"
  jq -e 'type == "array"' "$f" >/dev/null 2>&1 || { echo "error: $f is not a JSON array of rulesets" >&2; exit 1; }
  local dup
  dup="$(jq -r 'map(.name) | group_by(.) | map(select(length > 1) | .[0]) | join(", ")' "$f")"
  [ -z "$dup" ] || { echo "error: $f has duplicate ruleset names: $dup" >&2; exit 1; }
  jq -e 'all(.[]; (.name | type) == "string" and (.name | length) > 0)' "$f" >/dev/null || { echo "error: $f has a ruleset without a name" >&2; exit 1; }
}

cmd="${1:-}"; shift || true
case "$cmd" in
  export)
    [ $# -eq 1 ] || usage
    l="$(list "$1")" || { echo "error: could not list the rulesets of $1" >&2; exit 1; }
    out="$(live "$1" "$l")" || { echo "error: could not read the rulesets of $1" >&2; exit 1; }
    printf '%s\n' "$out"
    exit 0
    ;;
  plan|apply) [ $# -ge 2 ] || usage ;;
  *) usage ;;
esac

skip_bypass="${RULESETS_SKIP_BYPASS:-}"
case "$skip_bypass" in
  ""|0) skip_bypass="" ;;
  1) [ "$cmd" = plan ] || { echo "error: RULESETS_SKIP_BYPASS=1 is for plan only: apply would clear bypass actors" >&2; exit 64; }
     echo "note: bypass actors are not compared (RULESETS_SKIP_BYPASS=1: the token cannot read them)" ;;
  *) echo "error: RULESETS_SKIP_BYPASS must be 1 or empty" >&2; exit 64 ;;
esac
# Applied to both sides of a comparison only; never to a request body.
view() { if [ -n "$skip_bypass" ]; then jq -c 'del(.bypass_actors)'; else cat; fi; }

owner="$1"; shift
for f in "$@"; do check_file "$f"; done   # every file is valid before any call

drift=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
for f in "$@"; do
  name="$(basename "$f" .json)"; repo="$owner/$name"
  want="$(jq "$NORM"' map(norm) | sort_by(.name)' "$f")"
  l="$(list "$repo")" || { echo "error: could not list the rulesets of $repo" >&2; exit 1; }
  have="$(live "$repo" "$l")" || { echo "error: could not read the rulesets of $repo" >&2; exit 1; }
  for rs in $(jq -r '.[].name | @base64' <<<"$want"); do
    rn="$(printf '%s' "$rs" | base64 -d)"
    w="$(jq -c --arg n "$rn" '.[] | select(.name == $n)' <<<"$want")"
    h="$(jq -c --arg n "$rn" '.[] | select(.name == $n)' <<<"$have")"
    if [ -z "$h" ]; then
      echo "$name/$rn: create"; drift=1
      if [ "$cmd" = apply ]; then
        printf '%s' "$w" > "$tmp/body.json"
        gh api -X POST "repos/$repo/rulesets" --input "$tmp/body.json" --silent
      fi
    elif [ "$(view <<<"$w")" = "$(view <<<"$h")" ]; then
      echo "$name/$rn: unchanged"
    else
      echo "$name/$rn: update"; drift=1
      diff <(view <<<"$h" | jq -S .) <(view <<<"$w" | jq -S .) | sed 's/^/    /' || true
      if [ "$cmd" = apply ]; then
        id="$(jq -r --arg n "$rn" '.[] | select(.name == $n) | .id' <<<"$l")"
        printf '%s' "$w" > "$tmp/body.json"
        gh api -X PUT "repos/$repo/rulesets/$id" --input "$tmp/body.json" --silent
      fi
    fi
  done
  jq -r --argjson want "$want" '.[].name | select(. as $n | $want | map(.name) | index($n) | not)' <<<"$have" \
    | while IFS= read -r rn; do echo "$name/$rn: unmanaged (left as is)"; done
done

if [ "$cmd" = plan ] && [ "$drift" -eq 1 ]; then exit 2; fi
exit 0
