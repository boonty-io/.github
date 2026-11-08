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
# --- exemption: facts.json (5th argument), read only when no writer's receipt ---
# The predicate runs in jq (Oniguruma: \A, \z, \n in a class). The first case
# below proves those anchors match a valid PR, so the negative cases are not
# passing on a regex that matches nothing.
expectf() { # <comments fixture> <base> <facts fixture> <want state> [grep for the description]
  n=$((n + 1))
  local got; got="$("$sut" "$F/$1" "$F/writers.txt" "$2" "$H1" "$F/facts/$3" 2>&1)"
  if printf '%s\n' "$got" | grep -qx "state=$4" && { [ -z "${5:-}" ] || printf '%s\n' "$got" | grep -q "^description=.*$5"; }; then
    echo "✓ [$1 + facts/$3 @ $2] state=$4"
  else
    echo "✗ [$1 + facts/$3 @ $2] want state=$4 ${5:+(description ~ $5)}, got:"; printf '%s\n' "$got" | sed 's/^/    /'; fail=$((fail + 1))
  fi
}
# learnings PR (ai-config only): docs(shared-learnings) title, every path under shared-learnings/*.md
expectf none.json main learnings.json success 'exempt: learnings'
expectf none.json main learnings-extra-path.json pending 'no gate receipt'
# a rename INTO shared-learnings/ moves a file out of somewhere else
expectf none.json main learnings-renamed-in.json pending 'no gate receipt'
expectf none.json main learnings-subdir.json pending 'no gate receipt'
expectf none.json main learnings-not-md.json pending 'no gate receipt'
expectf none.json main learnings-other-repo.json pending 'no gate receipt'
expectf none.json main learnings-plain-docs.json pending 'no gate receipt'
expectf none.json main learnings-breaking.json pending 'no gate receipt'
expectf none.json main learnings-title-unanchored.json pending 'no gate receipt'
expectf none.json main learnings-no-files.json pending 'no gate receipt'
expectf none.json main learnings-files-string.json pending 'no gate receipt'
# an object of valid entries iterates like an array: only the type check refuses it
expectf none.json main learnings-files-object.json pending 'no gate receipt'
# wrong types elsewhere compare unequal or make jq fail: still pending
expectf none.json main learnings-count-string.json pending 'no gate receipt'
expectf none.json main learnings-entry-string.json pending 'no gate receipt'
expectf none.json main learnings-top-array.json pending 'no gate receipt'
expectf none.json main learnings-title-number.json pending 'no gate receipt'
expectf none.json main learnings-path-number.json pending 'no gate receipt'
expectf none.json main learnings-no-repo.json pending 'no gate receipt'
# paths: no newline anywhere, anchored at both ends of the string
expectf none.json main learnings-newline-inside.json pending 'no gate receipt'
expectf none.json main learnings-newline-trailing.json pending 'no gate receipt'
# a newline with no slash after it: only the class's \n refuses it
expectf none.json main learnings-newline-noslash.json pending 'no gate receipt'
# the file list must be complete: GitHub truncates pulls/files at 3000
expectf none.json main learnings-truncated.json pending 'no gate receipt'
expectf none.json main learnings-no-count.json pending 'no gate receipt'
# same-repo head, into main
expectf none.json main learnings-fork.json pending 'no gate receipt'
expectf none.json main learnings-cross-string.json pending 'no gate receipt'
expectf none.json main learnings-no-cross.json pending 'no gate receipt'
expectf none.json staging learnings.json pending 'no gate receipt'
# unreadable facts never exempt
expectf none.json main malformed.json pending 'no gate receipt'
# a writer's receipt is judged as before, whatever the facts say
expectf gate-fail.json main learnings.json failure 'code-review'
expectf pass.json staging learnings.json success '4/4 gates pass'
# an empty facts path is the same as no facts
n=$((n + 1))
got="$("$sut" "$F/none.json" "$F/writers.txt" main "$H1" "" 2>&1)"
if printf '%s\n' "$got" | grep -qx 'state=pending'; then echo "✓ empty facts path → pending"; else echo "✗ empty facts path:"; printf '%s\n' "$got" | sed 's/^/    /'; fail=$((fail + 1)); fi
# --- lean receipt: roster "lean", judged against the server's own docs-only measure (6th argument) ---
expectl() { # <comments fixture> <docs_only argument> <want state> [grep for the description]
  n=$((n + 1))
  local got; got="$("$sut" "$F/$1" "$F/writers.txt" staging "$H1" "" "$2" 2>&1)"
  if printf '%s\n' "$got" | grep -qx "state=$3" && { [ -z "${4:-}" ] || printf '%s\n' "$got" | grep -q "^description=.*$4"; }; then
    echo "✓ [$1 docs_only=$2] state=$3"
  else
    echo "✗ [$1 docs_only=$2] want state=$3 ${4:+(description ~ $4)}, got:"; printf '%s\n' "$got" | sed 's/^/    /'; fail=$((fail + 1))
  fi
}
expectl lean-pass.json true success 'lean receipt'
# the server measured a diff that is not docs-only, or could not measure it
expectl lean-pass.json false failure 'not docs-only'
expectl lean-pass.json '' failure 'not docs-only'
expectl lean-pass.json yes failure 'not docs-only'
# a lean receipt carries code-review only, passing; anything else is refused
expectl lean-cr-fail.json true failure 'lean receipt'
expectl lean-no-gates.json true failure 'lean receipt'
expectl lean-extra-gates.json true failure 'lean receipt'
# an unknown roster is refused; "full" or no roster is judged as before
expectl roster-other.json true failure 'roster'
expectl roster-full.json false success '4/4 gates pass'
expectl pass.json false success '4/4 gates pass'
# a lean receipt is still bound to the diff and the base
n=$((n + 1))
got="$("$sut" "$F/lean-pass.json" "$F/writers.txt" staging "$H2" "" true 2>&1)"
if printf '%s\n' "$got" | grep -qx 'state=failure' && printf '%s\n' "$got" | grep -q 'diff changed'; then echo "✓ lean receipt on a changed diff → failure"; else echo "✗ lean receipt on a changed diff:"; printf '%s\n' "$got" | sed 's/^/    /'; fail=$((fail + 1)); fi
n=$((n + 1))
got="$("$sut" "$F/lean-pass.json" "$F/writers.txt" main "$H1" "" true 2>&1)"
if printf '%s\n' "$got" | grep -qx 'state=failure' && printf '%s\n' "$got" | grep -q 'gated against base'; then echo "✓ lean receipt on another base → failure"; else echo "✗ lean receipt on another base:"; printf '%s\n' "$got" | sed 's/^/    /'; fail=$((fail + 1)); fi
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
