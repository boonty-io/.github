#!/usr/bin/env bash
# Decide the `gates/verified` commit status of a pull request head.
#
#   gates-verify.sh <comments.json> <writers.txt> <base-branch> <content-sha256> [<facts.json>]
#
# <comments.json>   the PR's issue comments as the REST API returns them.
# <writers.txt>     logins (one per line) whose permission on the repository
#                   is write, maintain or admin; the caller asks the API.
# <base-branch>     the PR's current base branch name.
# <content-sha256>  sha256 of the pinned diff merge-base(base, head)..head, as
#                   computed by scripts/gate-content-hash.sh (the same command
#                   `boonty-ai gate publish` runs).
# <facts.json>      optional, written by the workflow from the API:
#                   {"repo","title","cross_repo","changed_files",
#                    "files":[{"filename","previous_filename"?}]}.
#                   Read only when there is no writer's receipt (see below).
#                   Empty or absent: no exemption.
#
# Prints two lines for $GITHUB_OUTPUT:
#
#   state=success|failure|pending
#   description=<one line, at most 140 characters>
#
# The receipt is the most recently written (updated_at) comment whose body
# STARTS with the plain-text `boonty-gates/v1` marker (not an HTML comment:
# some write paths escape `<`) and whose author is in <writers.txt>. Its fenced
# json block is
#   {"v":1,"sha":…,"base":…,"content_sha256":…,"gates":{<gate>:"pass"|…}}
# posted by `boonty-ai gate publish` once the four Phase 5 gates pass.
#
# success  every gate in GATES is "pass", the receipt's base is the PR's base,
#          and content_sha256 equals <content-sha256>. The head sha is not
#          compared: a rebase onto a base that touched none of the diff's files
#          leaves the pinned diff, full blob ids included, byte-identical. Any
#          change to a diffed file, whitespace included, changes the hash.
# failure  a gate is missing or not "pass", the base or the content changed
#          since the gates ran, the receipt is unreadable, or the hash is empty.
# pending  no receipt yet.
#
# Exemption, only when no writer's receipt exists (a receipt, passing or not,
# is always judged as above): `success` for an ai-config learnings PR, which
# merges without the four gates by rule (ai-config shared/45, shared/48):
# base main, head in this repository, title `docs(shared-learnings): …`, a
# complete file list (its length is GitHub's changed_files: pulls/files stops
# at 3000), and every path and every renamed-from path one file directly
# under shared-learnings/ ending .md, with no newline. There is no delivery
# exemption: gates/verified is required on integration branches only, never
# on a main fed by a staging→main PR (docs/merge-by-github.md).
set -euo pipefail
comments="${1:?comments.json}"; writers="${2:?writers.txt}"; base="${3-}"; content="${4-}"; facts="${5-}"
GATES="architecture-reviewer code-review security claim-verifier"
MARKER='boonty-gates/v1'

out() { # out <state> <description>
  echo "state=$1"
  printf 'description=%s\n' "$(printf '%s' "$2" | tr -d '\r\n' | cut -c1-140)"
  exit 0
}

body="$(jq -r --arg m "$MARKER" --rawfile w "$writers" '
  ($w | split("\n") | map(select(length > 0))) as $ok
  | [.[] | select((.body // "") | startswith($m))
         | select(.user.login as $l | $ok | index($l))]
  | sort_by(.updated_at // .created_at // "") | last | .body // empty' "$comments")"
[ -n "$body" ] || {
  # Anything unreadable, missing or of the wrong type fails the predicate and
  # stays pending; jq errors are swallowed for the same reason.
  if [ -n "$facts" ] && [ -s "$facts" ] && jq -e --arg base "$base" '
      def path_ok: type == "string" and test("\\Ashared-learnings/[^/\n]+\\.md\\z");
      type == "object"
      and .repo == "boonty-io/ai-config"
      and $base == "main"
      and .cross_repo == false
      and (.title | type) == "string"
      and (.title | test("\\Adocs\\(shared-learnings\\): .+"))
      and (.files | type) == "array"
      and (.files | length) > 0
      and (.changed_files | type) == "number"
      and (.files | length) == .changed_files
      and all(.files[];
            type == "object"
            and (.filename | path_ok)
            and (.previous_filename == null or (.previous_filename | path_ok)))
    ' "$facts" >/dev/null 2>&1; then
    out success "exempt: learnings PR, $(jq -r '.files | length' "$facts") file(s) under shared-learnings/, no gate receipt needed"
  fi
  out pending "no gate receipt on this PR yet (boonty-ai gate publish)"
}
[[ "$content" =~ ^[0-9a-f]{64}$ ]] || out failure "could not compute the content hash of this head"

json="$(printf '%s\n' "$body" | awk '/^```json[[:space:]]*$/{f=1;next} f&&/^```/{exit} f')"
receipt="$(printf '%s' "$json" | jq -ce 'select(type == "object" and .v == 1 and (.gates | type) == "object")' 2>/dev/null)" \
  || out failure "gate receipt comment is unreadable; re-run boonty-ai gate publish"

short_of=""
for g in $GATES; do
  v="$(jq -r --arg g "$g" '.gates[$g] // "missing" | tostring' <<<"$receipt")"
  [ "$v" = pass ] || short_of="${short_of:+$short_of, }$g=$v"
done
[ -z "$short_of" ] || out failure "gates not all pass: $short_of"

got_base="$(jq -r '.base // "" | tostring' <<<"$receipt")"
[ -n "$base" ] && [ "${got_base#origin/}" = "$base" ] \
  || out failure "gated against base '${got_base}', PR targets '${base}'; re-gate"

want="$(jq -r '.content_sha256 // "" | tostring' <<<"$receipt")"
[ "$want" = "$content" ] \
  || out failure "diff changed since the gates ran (receipt ${want:0:12}, head ${content:0:12}); re-gate"
out success "4/4 gates pass for this diff (${content:0:12})"
