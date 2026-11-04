#!/usr/bin/env bash
# Fixture tests for scripts/gates-verify.sh. Run: test/gates-verify.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sut="$here/../scripts/gates-verify.sh"
F="$here/fixtures/gates"
fail=0; n=0
expect() { # <fixture> <computed patch-id> <want state> [grep for the description]
  n=$((n + 1))
  local got; got="$("$sut" "$F/$1" "$2" 2>&1)"
  if printf '%s\n' "$got" | grep -qx "state=$3" && { [ -z "${4:-}" ] || printf '%s\n' "$got" | grep -q "^description=.*$4"; }; then
    echo "✓ [$1 @ $2] state=$3"
  else
    echo "✗ [$1 @ $2] want state=$3 ${4:+(description ~ $4)}, got:"; printf '%s\n' "$got" | sed 's/^/    /'; fail=$((fail + 1))
  fi
}
expect pass.json 1111111 success '4/4 gates pass'
# the head was rebased without changing the patch: still verified
expect pass.json 1111111abcdef success
# the patch changed after the gates ran
expect pass.json 2222222 failure 'patch changed'
expect gate-fail.json 1111111 failure 'code-review'
expect gate-missing.json 1111111 failure 'claim-verifier'
# nothing published yet: pending, never a pass
expect none.json 1111111 pending 'no gate receipt'
# a receipt from someone without write access is ignored
expect untrusted.json 1111111 pending 'no gate receipt'
# the newest trusted receipt wins, both ways
expect newer-fail.json 1111111 failure 'code-review'
expect newer-pass.json 1111111 success
expect malformed.json 1111111 failure 'unreadable'
# an empty computed patch-id (the diff could not be taken) never passes
expect pass.json '' failure 'patch-id'
# output is exactly key=value lines: the description cannot inject a second line
n=$((n + 1))
lines="$("$sut" "$F/pass.json" 2222222 | wc -l | tr -d ' ')"
if [ "$lines" = 2 ]; then echo "✓ two output lines"; else echo "✗ expected two output lines, got $lines"; fail=$((fail + 1)); fi
# a verdict value carrying a newline cannot add a `state=success` line
n=$((n + 1))
got="$("$sut" "$F/gate-inject.json" 1111111)"
if [ "$(printf '%s\n' "$got" | wc -l | tr -d ' ')" = 2 ] && [ "$(printf '%s\n' "$got" | grep -c '^state=')" = 1 ] && printf '%s\n' "$got" | grep -qx 'state=failure'; then
  echo "✓ injected verdict stays one line"
else
  echo "✗ injected verdict:"; printf '%s\n' "$got" | sed 's/^/    /'; fail=$((fail + 1))
fi
echo; echo "$((n - fail))/$n passed"
[ "$fail" -eq 0 ]
