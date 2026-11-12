#!/usr/bin/env bash
# Runs the "Post the pending lines" step of .github/workflows/ci-hint.yml against a
# fake `gh`: on a label or `/ci`, a context that already reads success stays success
# (ci-request.yml does not dispatch that suite again), unless `/ci force`.
# Needs bash 4+, jq and python3 with PyYAML, as on ubuntu-latest.
# Run: test/ci-hint-post.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/.."
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0; n=0
ok() { n=$((n + 1)); echo "✓ $1"; }
ko() { n=$((n + 1)); echo "✗ $1"; fail=$((fail + 1)); }

python3 - "$root/.github/workflows/ci-hint.yml" "$work/step.sh" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["hint"]["steps"]
step = next(s for s in steps if s.get("name") == "Post the pending lines")
open(sys.argv[2], "w").write(step["run"])
PY

# Fake gh: `pr view` answers a ready same-repo PR; `api .../statuses` (GET) applies the step's own
# --jq to the JSON in $STATUSES; `api -X POST .../statuses/...` logs the context it would set to pending.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") echo '{"headRefOid":"abc123","headRefName":"feat/x","isCrossRepository":false,"isDraft":false}' ;;
  "api -X") for a in "$@"; do case "$a" in context=*) echo "pending ${a#context=}" >> "$GH_LOG" ;; esac; done ;;
  "api "*) q=; while [ $# -gt 0 ]; do [ "$1" = --jq ] && q="$2"; shift; done
           printf '%s' "$STATUSES" | jq -r "$q" ;;
  *) echo "unexpected gh $*" >> "$GH_LOG"; exit 3 ;;
esac
SH
chmod +x "$work/bin/gh"

OLD=2026-11-03T20:00:00Z
ROWS='[{"context":"ci/a","created_at":"'$OLD'","description":"passed (workflow_dispatch)","state":"success"},{"context":"ci/b","created_at":"'$OLD'","description":"failed (workflow_dispatch)","state":"failure"}]'
run_case() {
  local d="$work/$1"; mkdir -p "$d/ws/scripts"; : > "$d/log"
  cp "$root/scripts/ci-hint-should-post.sh" "$d/ws/scripts/"
  (cd "$d/ws" && env PATH="$work/bin:$PATH" GH_LOG="$d/log" GITHUB_REPOSITORY=o/r STATUSES="$ROWS" \
    GO=true SOURCE="$2" FORCE="$3" PR=9 STARTED=2026-11-03T21:00:00Z CONTEXTS=ci/a,ci/b LABEL=ci:run COMMAND=/ci \
    DOCS=https://example.invalid bash -e "$work/step.sh" >"$d/out" 2>&1) || echo "exit $?" >> "$d/log"
  LOG="$(cat "$d/log")"
}
has() { printf '%s\n' "$LOG" | grep -qxF -- "$1"; }

run_case label label false
if ! has 'pending ci/a' && has 'pending ci/b'; then ok "label: success left alone, failure set to running"; else ko "label: $LOG"; fi
run_case force comment true
if has 'pending ci/a' && has 'pending ci/b'; then ok "/ci force: both set to running"; else ko "force: $LOG"; fi

echo; echo "$((n - fail))/$n passed"
[ "$fail" -eq 0 ]
