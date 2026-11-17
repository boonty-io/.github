#!/usr/bin/env bash
# Tests for the jq filter of the "Resolve an ai-config bump PR" step in
# .github/workflows/gates-verify.yml, read out of the workflow itself, so the
# branch rule there cannot drift from scripts/gates-verify.sh's exempt_bump.
# Run: test/gates-verify-resolve.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wf="$here/../.github/workflows/gates-verify.yml"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0

# The program is the single-quoted argument of `version="$(jq -r '...' pr.json`.
python3 - "$wf" > "$work/filter.jq" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r"version=\"\$\(jq -r '(.*?)' pr\.json", s, re.S)
if not m:
    sys.exit("resolve filter not found in " + sys.argv[1])
print(m.group(1))
PY
[ -s "$work/filter.jq" ] || { echo "✗ could not read the resolve filter from the workflow"; exit 1; }

title='chore(deps): bump @boonty-io/ai-config to v0.110.0'
expect() { # <want version or empty> <label> <headRefName> [isCrossRepository] [title]
  printf '{"state":"OPEN","isCrossRepository":%s,"title":"%s","headRefName":"%s"}\n' "${4:-false}" "${5:-$title}" "$3" > "$work/pr.json"
  got="$(jq -r -f "$work/filter.jq" "$work/pr.json" 2>/dev/null || true)"
  if [ "$got" = "$1" ]; then echo "✓ $2"; else echo "✗ $2: want '$1', got '$got'"; fail=$((fail + 1)); fi
}

expect 0.110.0 "the per-version branch of the title's version resolves" chore/bump-ai-config-v0.110.0
expect 0.110.0 "the stable branch resolves, the version from the title" chore/bump-ai-config-latest
expect "" "a per-version branch of another version does not" chore/bump-ai-config-v0.109.0
expect "" "a branch that only starts with the stable name does not" chore/bump-ai-config-latest-b
expect "" "a fork on the stable branch does not" chore/bump-ai-config-latest true
expect "" "the stable branch without a bump title does not" chore/bump-ai-config-latest false "feat: x"

# Both rules name the same stable branch.
if grep -qF '"chore/bump-ai-config-latest"' "$here/../scripts/gates-verify.sh"; then
  echo "✓ gates-verify.sh names the stable branch"
else
  echo "✗ gates-verify.sh does not name the stable branch"; fail=$((fail + 1))
fi

[ "$fail" -eq 0 ] && echo "all passed" || echo "$fail failed"
exit "$fail"
