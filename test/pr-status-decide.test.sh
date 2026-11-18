#!/usr/bin/env bash
# Cases for scripts/pr-status-decide.sh. Run: test/pr-status-decide.test.sh
# Each case: <state> <draft> <plan line 1> <expected label ('' = none)> [reason substring]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
decide="$here/../scripts/pr-status-decide.sh"
fail=0; n=0

expect() {
  local state="$1" draft="$2" line="$3" want="$4" why="${5:-}"
  n=$((n + 1))
  local got label reason
  got="$(PR_STATE="$state" PR_DRAFT="$draft" PLAN_LINE="$line" "$decide")"
  label="$(printf '%s\n' "$got" | sed -n 's/^label=//p')"
  reason="$(printf '%s\n' "$got" | sed -n 's/^reason=//p')"
  if [ "$label" != "$want" ] || { [ -n "$why" ] && [[ "$reason" != *"$why"* ]]; }; then
    echo "✗ [$state draft=$draft '$line'] want label='$want' reason~'$why', got:"; printf '%s\n' "$got" | sed 's/^/    /'
    fail=$((fail + 1)); return
  fi
  echo "✓ [$state draft=$draft] label='$label'"
}

m() { printf '<!-- boonty-plan/v1 {"phase":"%s","status":"%s"} -->' "$1" "${2:-in-progress}"; }

# 1. every phase a draft can carry maps to its label
for p in test implementation gates ci blocked; do expect open true "$(m "$p")" "pr:$p"; done
# 2. the plan phase carries no label (no draft yet in practice; nothing to show)
expect open true "$(m plan planning)" '' 'plan'
# 3. out of draft, closed or merged: no label, whatever the plan says
expect open false "$(m gates)" '' 'not a draft'
expect closed true "$(m gates)" '' 'closed'
expect closed false "$(m ci)" '' 'closed'
# 4. a draft with no plan comment: no label
expect open true '' '' 'no plan'
# 5. line 1 is parsed strictly: an unknown phase, a bad or missing status, non-JSON, a wrong marker
expect open true "$(m deploy)" '' 'phase'
expect open true "$(m gates shipped)" '' 'status'
expect open true '<!-- boonty-plan/v1 {"phase":"gates"} -->' '' 'status'
expect open true '<!-- boonty-plan/v1 {not json} -->' '' 'json'
expect open true '<!-- boonty-plan/v2 {"phase":"gates","status":"in-progress"} -->' '' 'marker'
expect open true " $(m gates)" '' 'marker'
expect open true "$(m gates) trailing" '' 'marker'
# 6. size cap: a 300-char line is refused before any parsing
long="<!-- boonty-plan/v1 {\"phase\":\"gates\",\"status\":\"in-progress\",\"x\":\"$(printf 'a%.0s' $(seq 1 260))\"} -->"
expect open true "$long" '' 'long'
# 7. a phase value that tries to smuggle a second key=value line is refused
expect open true '<!-- boonty-plan/v1 {"phase":"gates\nlabel=pr:ci","status":"in-progress"} -->' '' 'phase'
# 8. draft flag must be literally true
expect open yes "$(m gates)" '' 'not a draft'

echo "$((n - fail))/$n passed"
[ "$fail" -eq 0 ]
