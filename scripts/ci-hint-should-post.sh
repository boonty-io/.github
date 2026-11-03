#!/usr/bin/env bash
# Should ci-hint.yml post its pending line for one context? Pure function,
# tested by test/ci-hint-should-post.test.sh. Prints `yes` or `no`.
#
#   $1 go       true (a request) | false (a new head: the "Not run yet" hint)
#   $2 source   label | comment | ready  (only meaningful when go=true)
#   $3 started  ISO-8601 UTC time the hint job started
#   $4 created  created_at of the latest status for the context, empty if none
#   $5 desc     description of that status
#
# Rules: nothing on the head → post. On a new head, never overwrite anything.
# On a request, never overwrite a status posted after the job started (a suite
# that already answered), and on "ready" never overwrite a real verdict —
# ci-request.yml dispatches nothing for a head that already ran.
set -euo pipefail
go="${1:?go}"; source="${2:-}"; started="${3:?started}"; created="${4:-}"; desc="${5:-}"
[ -n "$created" ] || { echo yes; exit 0; }
[ "$go" = "true" ] || { echo no; exit 0; }
[[ "$created" < "$started" ]] || { echo no; exit 0; }
case "$desc" in "Not run yet:"*|"Requested:"*) is_hint=1 ;; *) is_hint=0 ;; esac
if [ "$source" = "ready" ] && [ "$is_hint" -eq 0 ]; then echo no; exit 0; fi
echo yes
