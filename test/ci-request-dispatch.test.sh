#!/usr/bin/env bash
# Runs the "Dispatch the suites" step of .github/workflows/ci-request.yml against a
# fake `gh`, to check which suites it dispatches on a head that already ran.
# Needs bash 4+, jq and python3 with PyYAML, as on ubuntu-latest.
# Run: test/ci-request-dispatch.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/.."
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0; n=0
ok() { n=$((n + 1)); echo "✓ $1"; }
ko() { n=$((n + 1)); echo "✗ $1"; fail=$((fail + 1)); }

python3 - "$root/.github/workflows/ci-request.yml" "$work/step.sh" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["request"]["steps"]
step = next(s for s in steps if s.get("name") == "Dispatch the suites")
open(sys.argv[2], "w").write(step["run"])
PY

# Fake gh: `api .../workflows/<wf>/runs...` answers $RUNS_DIR/<wf>.json (or fails when absent),
# `workflow run <wf>` and `pr comment --body-file <f>` are logged.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "api "*) wf="$(printf '%s' "$2" | sed -n 's#.*/actions/workflows/\([^/]*\)/runs.*#\1#p')"
           [ -r "$RUNS_DIR/$wf.json" ] || exit 1; cat "$RUNS_DIR/$wf.json" ;;
  "workflow run") echo "dispatch $3" >> "$GH_LOG" ;;
  "pr comment") while [ $# -gt 0 ]; do [ "$1" = --body-file ] && { echo "comment"; cat "$2"; } >> "$GH_LOG"; shift; done ;;
  *) echo "unexpected gh $*" >> "$GH_LOG"; exit 3 ;;
esac
SH
chmod +x "$work/bin/gh"

# case <name> <force> <a.yml fixture|-> <b.yml fixture|-> — runs the step in a fresh dir
run_case() {
  local d="$work/$1"; mkdir -p "$d/runs" "$d/ws/scripts"; : > "$d/log"
  cp "$root/scripts/ci-request-already-ran.sh" "$d/ws/scripts/"
  [ "$3" = - ] || cp "$here/fixtures/runs/$3" "$d/runs/a.yml.json"
  [ "$4" = - ] || cp "$here/fixtures/runs/$4" "$d/runs/b.yml.json"
  (cd "$d/ws" && env PATH="$work/bin:$PATH" RUNS_DIR="$d/runs" GH_LOG="$d/log" GITHUB_REPOSITORY=o/r \
    PR=9 HEAD_REF=feat/x HEAD_SHA=abcdef1234567 BASE=main DEFAULT_WORKFLOWS=a.yml,b.yml OVERRIDE_WORKFLOWS= \
    FORCE="$2" COMMAND=/ci bash -e "$work/step.sh" >"$d/out" 2>&1) || echo "exit $?" >> "$d/log"
  LOG="$(cat "$d/log")"
}
has() { printf '%s\n' "$LOG" | grep -qxF -- "$1"; }
hasnt() { ! printf '%s\n' "$LOG" | grep -qF -- "$1"; }

run_case fresh false none.json none.json
if has 'dispatch a.yml' && has 'dispatch b.yml' && hasnt comment; then ok "new head: both suites dispatched, no comment"; else ko "new head: $LOG"; fi

run_case one-passed false passed.json failed.json
if hasnt 'dispatch a.yml' && has 'dispatch b.yml' && has comment && printf '%s' "$LOG" | grep -q 'a.yml`: passed on this commit, https://github.com/o/r/actions/runs/4'; then
  ok "a passed, b failed: only b dispatched, comment links a's run"; else ko "one passed: $LOG"; fi

run_case running false running.json passed.json
if hasnt dispatch && has comment && printf '%s' "$LOG" | grep -q '/ci force'; then ok "running and passed: nothing dispatched, comment says how to force"; else ko "running: $LOG"; fi

run_case forced true passed.json running.json
if has 'dispatch a.yml' && has 'dispatch b.yml' && hasnt comment; then ok "/ci force: both dispatched over a pass and a running run"; else ko "forced: $LOG"; fi

run_case api-down false - -
if has 'dispatch a.yml' && has 'dispatch b.yml'; then ok "runs API unreadable: both dispatched"; else ko "api-down: $LOG"; fi

echo; echo "$((n - fail))/$n passed"
[ "$fail" -eq 0 ]
