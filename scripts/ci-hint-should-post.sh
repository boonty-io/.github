#!/usr/bin/env bash
# Should ci-hint.yml post its pending line for one context? Pure function,
# tested by test/ci-hint-should-post.test.sh. Prints `yes` or `no`.
#
#   $1 go       true (a request) | false (a new head: the "Not run yet" hint)
#   $2 source   label | comment | ready  (only meaningful when go=true)
#   $3 started  ISO-8601 UTC time the hint job started
#   $4 created  created_at of the latest status for the context, empty if none
#   $5 desc     description of that status
#   $6 force    true for `/ci force`
#
# Rules: nothing on the head → post. On a new head, never overwrite anything.
# On a request, never overwrite a status posted after the job started (a suite
# that already answered), and on "ready" never overwrite a real verdict —
# ci-request.yml dispatches nothing for a head that already ran. On a label or
# `/ci`, never overwrite a real verdict either: ci-request.yml may skip that
# suite (it passed or is running on this head), and this script cannot tell
# which suite a context belongs to. Only `/ci force` overwrites a verdict.
set -euo pipefail
# $2 (source) is still passed by ci-hint.yml; every request follows one rule now, so it is not read.
go="${1:?go}"; started="${3:?started}"; created="${4:-}"; desc="${5:-}"; force="${6:-false}"
[ -n "$created" ] || { echo yes; exit 0; }
[ "$go" = "true" ] || { echo no; exit 0; }
[[ "$created" < "$started" ]] || { echo no; exit 0; }
case "$desc" in "Not run yet:"*|"Requested:"*) is_hint=1 ;; *) is_hint=0 ;; esac
if [ "$is_hint" -eq 0 ] && [ "$force" != "true" ]; then echo no; exit 0; fi
echo yes
