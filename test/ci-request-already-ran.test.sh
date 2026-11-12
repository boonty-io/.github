#!/usr/bin/env bash
# Cases for scripts/ci-request-already-ran.sh. Run: test/ci-request-already-ran.test.sh
# Each fixture is the `actions/workflows/<wf>/runs?head_sha=...` answer for one suite on one head, newest first.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
f="$here/../scripts/ci-request-already-ran.sh"
fail=0; n=0
expect() {
  local fixture="$1" want="$2"; n=$((n + 1))
  # "now" is 2026-11-12T12:00:00Z for every case
  local got; got="$("$f" "$here/fixtures/runs/$fixture" 1794484800)"
  local IFS=','
  for kv in $want; do
    if ! printf '%s\n' "$got" | grep -qxF -- "$kv"; then
      echo "✗ [$fixture] expected line '$kv', got:"; printf '%s\n' "$got" | sed 's/^/    /'
      fail=$((fail + 1)); return
    fi
  done
  echo "✓ [$fixture] $want"
}
# 1. no run of this suite on this head yet (a new push or a rebase): dispatch
expect none.json 'skip=false'
# 2. the last run failed: dispatch again
expect failed.json 'skip=false'
# 3. cancelled or never started: dispatch again
expect cancelled.json 'skip=false'
# 4. the last run passed: do not pay for the same result twice
expect passed.json 'skip=true,why=passed,url=https://github.com/o/r/actions/runs/4'
# 5. an earlier pass followed by a failure: the verdict on the head is the failure, so dispatch
expect passed-earlier.json 'skip=false'
# 6. still running or queued: the answer is on its way
expect running.json 'skip=true,why=running,url=https://github.com/o/r/actions/runs/5'
expect queued.json 'skip=true,why=running,url=https://github.com/o/r/actions/runs/6'
# 6b. a run queued or running for more than 6 hours is stuck (no runner, say): it does not count
expect stale-queued.json 'skip=false'
expect fresh-queued.json 'skip=true,why=running,url=https://github.com/o/r/actions/runs/9'
# 7. an answer it cannot read must not cost a skipped suite: dispatch
expect garbage.json 'skip=false'
expect does-not-exist.json 'skip=false'
echo; echo "$((n - fail))/$n passed"
[ "$fail" -eq 0 ]
