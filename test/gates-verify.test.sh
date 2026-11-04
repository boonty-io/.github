#!/usr/bin/env bash
# Fixture tests for scripts/gates-verify.sh. Run: test/gates-verify.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sut="$here/../scripts/gates-verify.sh"
F="$here/fixtures/gates"
H1=1111111111111111111111111111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222222222222222222222222222
fail=0; n=0
expect() { # <fixture> <base> <computed content hash> <want state> [grep for the description]
  n=$((n + 1))
  local got; got="$("$sut" "$F/$1" "$F/writers.txt" "$2" "$3" 2>&1)"
  if printf '%s\n' "$got" | grep -qx "state=$4" && { [ -z "${5:-}" ] || printf '%s\n' "$got" | grep -q "^description=.*$5"; }; then
    echo "✓ [$1 @ $2 ${3:0:7}] state=$4"
  else
    echo "✗ [$1 @ $2 ${3:0:7}] want state=$4 ${5:+(description ~ $5)}, got:"; printf '%s\n' "$got" | sed 's/^/    /'; fail=$((fail + 1))
  fi
}
expect pass.json staging "$H1" success '4/4 gates pass'
# the diff changed after the gates ran (any byte, whitespace included)
expect pass.json staging "$H2" failure 'diff changed'
# one differing character at the end is a different diff
expect pass.json staging "${H1:0:63}2" failure 'diff changed'
# an abbreviated hash never matches
expect pass.json staging "${H1:0:12}" failure 'content hash'
# an empty computed hash (the diff could not be taken) never passes
expect pass.json staging '' failure 'content hash'
# the PR was retargeted after the gates ran
expect other-base.json staging "$H1" failure "gated against base 'main'"
expect origin-base.json staging "$H1" success
expect pass.json '' "$H1" failure 'gated against base'
expect gate-fail.json staging "$H1" failure 'code-review'
expect gate-missing.json staging "$H1" failure 'claim-verifier'
# nothing published yet: pending, never a pass
expect none.json staging "$H1" pending 'no gate receipt'
# a receipt from someone without write access is ignored, whatever their association
expect untrusted.json staging "$H1" pending 'no gate receipt'
expect reader-member.json staging "$H1" pending 'no gate receipt'
# the receipt last written wins, both ways
expect newer-fail.json staging "$H1" failure 'code-review'
expect newer-pass.json staging "$H1" success
# publish updates its comment in place: updated_at, not creation order, decides
expect updated-later.json staging "$H1" success
expect malformed.json staging "$H1" failure 'unreadable'
# a receipt whose gates are not an object fails closed, with output
expect gates-array.json staging "$H1" failure 'unreadable'
# a writer's comment that only mentions the marker is not a receipt
expect mention.json staging "$H1" success
# output is exactly key=value lines: the description cannot inject a second line
n=$((n + 1))
lines="$("$sut" "$F/pass.json" "$F/writers.txt" staging "$H2" | wc -l | tr -d ' ')"
if [ "$lines" = 2 ]; then echo "✓ two output lines"; else echo "✗ expected two output lines, got $lines"; fail=$((fail + 1)); fi
# a verdict value carrying a newline cannot add a `state=success` line
n=$((n + 1))
got="$("$sut" "$F/gate-inject.json" "$F/writers.txt" staging "$H1")"
if [ "$(printf '%s\n' "$got" | wc -l | tr -d ' ')" = 2 ] && [ "$(printf '%s\n' "$got" | grep -c '^state=')" = 1 ] && printf '%s\n' "$got" | grep -qx 'state=failure'; then
  echo "✓ injected verdict stays one line"
else
  echo "✗ injected verdict:"; printf '%s\n' "$got" | sed 's/^/    /'; fail=$((fail + 1))
fi
echo; echo "$((n - fail))/$n passed"
[ "$fail" -eq 0 ]
