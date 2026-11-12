#!/usr/bin/env bash
# Cases for scripts/ci-hint-should-post.sh. Run: test/ci-hint-should-post.test.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
f="$here/../scripts/ci-hint-should-post.sh"
fail=0; n=0
S=2026-11-03T21:00:00Z; OLD=2026-11-03T20:00:00Z; NEW=2026-11-03T21:00:05Z
expect() { local want="$1"; shift; n=$((n + 1)); local got; got="$("$f" "$@")"
  if [ "$got" = "$want" ]; then echo "✓ $want <- $*"; else echo "✗ want $want, got $got <- $*"; fail=$((fail + 1)); fi; }
# 1. new head, nothing posted → hint
expect yes false '' "$S" '' ''
# 2. new head that already carries a status → never overwrite
expect no false '' "$S" "$OLD" 'passed (workflow_dispatch)'
# 3. label request over an old verdict → leave it: ci-request may skip that suite
expect no true label "$S" "$OLD" 'failed (workflow_dispatch)'
# 4. request, but a suite answered after the job started → leave it
expect no true label "$S" "$NEW" 'passed (workflow_dispatch)'
# 5. ready over a real verdict → leave it (nothing is dispatched)
expect no true ready "$S" "$OLD" 'passed (workflow_dispatch)'
# 6. ready over the hint → running
expect yes true ready "$S" "$OLD" 'Not run yet: mark the PR ready, add the ci:run label or comment /ci'
# 7. ready, nothing posted → running
expect yes true ready "$S" '' ''
# 8. /ci over an earlier "Requested" line → running again
expect yes true comment "$S" "$OLD" 'Requested: running (see the runs on this branch)'
# 9. label or /ci over a real verdict → leave it
expect no true label "$S" "$OLD" 'passed (workflow_dispatch)' false
expect no true comment "$S" "$OLD" 'failed (workflow_dispatch)' false
# 10. `/ci force` dispatches every suite: running over any verdict
expect yes true comment "$S" "$OLD" 'passed (workflow_dispatch)' true
expect yes true comment "$S" "$OLD" 'failed (workflow_dispatch)' true
# 11. label over the hint or over nothing → running
expect yes true label "$S" "$OLD" 'Not run yet: add the ci:run label or comment /ci' false
expect yes true label "$S" '' '' false
echo; echo "$((n - fail))/$n passed"
[ "$fail" -eq 0 ]
