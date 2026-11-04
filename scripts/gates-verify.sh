#!/usr/bin/env bash
# Decide the `gates/verified` commit status of a pull request head.
#
#   gates-verify.sh <comments.json> <patch-id>
#
# <comments.json> is the PR's issue comments as the REST API returns them;
# <patch-id> is `git patch-id --stable` over merge-base(base, head)..head,
# computed by the caller. Prints two lines for $GITHUB_OUTPUT:
#
#   state=success|failure|pending
#   description=<one line, at most 140 characters>
#
# The receipt is the NEWEST comment that carries the plain-text
# `boonty-gates/v1` marker (not an HTML comment: some write paths escape `<`)
# and was written by an OWNER, MEMBER or COLLABORATOR (people who can push,
# so who could already write a gate receipt by hand). Its fenced json
# block is `{"v":1,"sha":…,"diff_hash":…,"gates":{<gate>:"pass"|"fail"}}`,
# posted by `boonty-ai gate publish` once the four Phase 5 gates pass.
#
# success  every gate in GATES is "pass" and diff_hash = <patch-id>. The sha is
#          not compared: a rebase that leaves the patch unchanged keeps the
#          verdict, and is exactly the case this exists for.
# failure  a gate is missing or not "pass", the patch changed since the gates
#          ran, the receipt is unreadable, or the patch-id is empty.
# pending  no receipt yet.
set -euo pipefail
comments="${1:?comments.json}"; patch_id="${2-}"
GATES="architecture-reviewer code-review security claim-verifier"
MARKER='boonty-gates/v1'

out() { # out <state> <description>
  echo "state=$1"
  printf 'description=%s\n' "$(printf '%s' "$2" | tr -d '\r\n' | cut -c1-140)"
  exit 0
}

body="$(jq -r --arg m "$MARKER" '
  [.[] | select((.body // "") | contains($m))
       | select(.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR")]
  | last | .body // empty' "$comments")"
[ -n "$body" ] || out pending "no gate receipt on this PR yet (boonty-ai gate publish)"
[ -n "$patch_id" ] || out failure "could not compute the patch-id of this head"

json="$(printf '%s\n' "$body" | awk '/^```json[[:space:]]*$/{f=1;next} f&&/^```/{exit} f')"
receipt="$(printf '%s' "$json" | jq -ce 'select(type == "object" and .v == 1)' 2>/dev/null)" \
  || out failure "gate receipt comment is unreadable; re-run boonty-ai gate publish"

short_of=""
for g in $GATES; do
  v="$(jq -r --arg g "$g" '.gates[$g] // "missing"' <<<"$receipt")"
  [ "$v" = pass ] || short_of="${short_of:+$short_of, }$g=$v"
done
[ -z "$short_of" ] || out failure "gates not all pass: $short_of"

want="$(jq -r '.diff_hash // ""' <<<"$receipt")"
# Receipts may carry an abbreviated id; compare on the shorter of the two.
len=${#want}; [ "${#patch_id}" -lt "$len" ] && len=${#patch_id}
if [ "$len" -lt 7 ] || [ "${want:0:$len}" != "${patch_id:0:$len}" ]; then
  out failure "patch changed since the gates ran (receipt ${want:0:12}, head ${patch_id:0:12}); re-gate"
fi
out success "4/4 gates pass for this patch (${patch_id:0:12})"
