#!/usr/bin/env bash
# Fixture tests for scripts/rulesets.sh against a stub `gh` (no network).
# Run: test/rulesets.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sut="$here/../scripts/rulesets.sh"
F="$here/fixtures/rulesets"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repos"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Logs every call; serves the fixtures for repos/boonty-io/demo and the
# environments of repos/boonty-io/.github.
echo "gh $*" >> "$LOG"
[ "$1" = api ] || exit 9
shift
method=GET; input=""; path=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --input) input="$2"; shift 2 ;;
    --paginate|--silent) shift ;;
    --jq) shift 2 ;;
    *) path="$1"; shift ;;
  esac
done
[ -z "${FAIL_GET:-}" ] || { [ "$method" = GET ] && { echo "HTTP 404" >&2; exit 1; }; }
[ -z "${FAIL_ONE:-}" ] || { [ "$method $path" = "GET repos/boonty-io/demo/rulesets/12" ] && { echo "HTTP 500" >&2; exit 1; }; }
case "$method $path" in
  "GET repos/boonty-io/.github/environments/"*/deployment-branch-policies)
    n="${path#repos/boonty-io/.github/environments/}"; cat "$EFIX/env-${n%/deployment-branch-policies}-policies.json" ;;
  "GET repos/boonty-io/.github/environments/"*) cat "$EFIX/env-${path##*/}.json" ;;
  "GET repos/boonty-io/demo/rulesets") cat "$FIX/live-list.json" ;;
  "GET repos/boonty-io/demo/rulesets/"*) cat "$FIX/live-${path##*/}.json" ;;
  "PUT repos/boonty-io/demo/rulesets/"*) cp "$input" "$OUT/put-${path##*/}.json"; echo '{}' ;;
  "POST repos/boonty-io/demo/rulesets") cp "$input" "$OUT/post-$(jq -r .name "$input").json"; echo '{}' ;;
  *) echo "stub gh: unexpected $method $path" >&2; exit 9 ;;
esac
STUB
chmod +x "$T/bin/gh"
# A scrubbed PATH: the stub is the only gh the scripts can reach, never the
# real binary with real credentials. bash and jq are linked in, since they may
# live outside /usr/bin:/bin.
for t in bash jq; do ln -s "$(command -v "$t")" "$T/bin/$t"; done
SAFE_PATH="$T/bin:/usr/bin:/bin"
[ "$(PATH="$SAFE_PATH" command -v gh)" = "$T/bin/gh" ] || { echo "✗ the scrubbed PATH reaches a gh other than the stub"; exit 1; }
export LOG="$T/log" FIX="$F" EFIX="$here/fixtures/environments" OUT="$T"
fail=0; n=0
ok() { n=$((n+1)); echo "✓ $1"; }
ko() { n=$((n+1)); fail=$((fail+1)); echo "✗ $1"; [ -s "$T/out" ] && sed 's/^/    /' "$T/out"; }
run() { : > "$LOG"; rm -f "$T"/put-* "$T"/post-*; PATH="$SAFE_PATH" "$sut" "$@" > "$T/out" 2>&1; echo $?; }
desired() { cp "$F/$1" "$T/repos/demo.json"; echo "$T/repos/demo.json"; }
envs="$here/../scripts/environments.sh"
erun() { : > "$LOG"; PATH="$SAFE_PATH" "$envs" "$@" > "$T/out" 2>&1; echo $?; }
edesired() { mkdir -p "$T/envs"; cp "$here/fixtures/environments/$1" "$T/envs/.github.json"; echo "$T/envs/.github.json"; }
reads_only() { ! grep -qvE '^gh api repos/boonty-io/\.github/environments/[a-z-]+(/deployment-branch-policies)?( --paginate)?$' "$LOG"; }

# 1. plan with drift: Main unchanged (order-insensitive), Staging update, New create, Legacy unmanaged, org ruleset ignored; exit 2, no write
rc=$(run plan boonty-io "$(desired desired.json)")
if [ "$rc" = 2 ] && grep -qx 'demo/Main: unchanged' "$T/out" && grep -qx 'demo/Staging: update' "$T/out" \
   && grep -qx 'demo/New: create' "$T/out" && grep -qx 'demo/Legacy: unmanaged (left as is)' "$T/out" \
   && ! grep -q 'Org wide' "$T/out" && ! grep -qE -- '-X (PUT|POST|DELETE)' "$LOG"; then ok "plan reports drift, writes nothing (rc=$rc)"; else ko "plan with drift (rc=$rc)"; fi

# 2. plan without drift: exit 0, an unmanaged live ruleset is not drift
rc=$(run plan boonty-io "$(desired desired-same.json)")
if [ "$rc" = 0 ] && grep -qx 'demo/Staging: unchanged' "$T/out"; then ok "plan without drift exits 0"; else ko "plan without drift (rc=$rc)"; fi

# 2b. an update alone is drift too
rc=$(run plan boonty-io "$(desired desired-update-only.json)")
if [ "$rc" = 2 ] && grep -qx 'demo/Staging: update' "$T/out" && ! grep -q ': create' "$T/out"; then ok "update alone is drift"; else ko "update alone (rc=$rc)"; fi

# 3. apply: PUT only the changed one (by id), POST the new one, never DELETE
rc=$(run apply boonty-io "$(desired desired.json)")
if [ "$rc" = 0 ] && [ -f "$T/put-12.json" ] && [ ! -f "$T/put-11.json" ] && [ -f "$T/post-New.json" ] \
   && [ "$(grep -c -- '-X PUT' "$LOG")" = 1 ] && ! grep -q -- '-X DELETE' "$LOG"; then ok "apply updates and creates, nothing else"; else ko "apply (rc=$rc)"; fi

# 4. the PUT body is exactly the desired ruleset: no id, no read-only fields
if [ -f "$T/put-12.json" ] && [ "$(jq -S . "$T/put-12.json")" = "$(jq -S '.[1]' "$F/desired.json")" ]; then ok "PUT body is the desired ruleset"; else ko "PUT body"; fi

# 5. a duplicate name in the desired file is refused before any call
rc=$(run plan boonty-io "$(desired desired-dup.json)")
if [ "$rc" = 1 ] && grep -q 'duplicate' "$T/out" && [ ! -s "$LOG" ]; then ok "duplicate names refused"; else ko "duplicate names (rc=$rc)"; fi

# 6. a desired file that is not an array is refused
rc=$(run plan boonty-io "$(desired desired-bad.json)")
if [ "$rc" = 1 ] && [ ! -s "$LOG" ]; then ok "non-array file refused"; else ko "non-array file (rc=$rc)"; fi

# 7. a failed read fails closed: no write, exit 1
rc=$(FAIL_GET=1 run apply boonty-io "$(desired desired.json)")
if [ "$rc" = 1 ] && ! grep -qE -- '-X (PUT|POST)' "$LOG"; then ok "failed read fails closed"; else ko "failed read (rc=$rc)"; fi

# 7b. one ruleset read failing (the list worked) also fails closed
rc=$(FAIL_ONE=1 run apply boonty-io "$(desired desired.json)")
if [ "$rc" = 1 ] && ! grep -qE -- '-X (PUT|POST)' "$LOG"; then ok "failed single read fails closed"; else ko "failed single read (rc=$rc)"; fi

# 8. export prints the repository's own rulesets, normalized, sorted by name, read-only fields dropped
rc=$(run export boonty-io/demo)
if [ "$rc" = 0 ] && [ "$(jq -r 'map(.name)|join(",")' "$T/out")" = "Legacy,Main,Staging" ] \
   && [ "$(jq '[.[]|keys[]]|unique|map(select(IN("id","_links","node_id","source","source_type","created_at","updated_at","current_user_can_bypass")))|length' "$T/out")" = 0 ]; then ok "export"; else ko "export (rc=$rc)"; fi

# 9. export then plan round-trips with no drift
cp "$T/out" "$T/repos/demo.json"
rc=$(run plan boonty-io "$T/repos/demo.json")
if [ "$rc" = 0 ] && ! grep -q 'update\|create\|unmanaged' "$T/out"; then ok "export round-trips"; else ko "round-trip (rc=$rc)"; fi

# 10. a usage error exits 64
rc=$(run nope)
if [ "$rc" = 64 ]; then ok "usage error"; else ko "usage error (rc=$rc)"; fi

# 11. a bypass-actor change alone is drift with a token that can read them
rc=$(run plan boonty-io "$(desired desired-bypass-only.json)")
if [ "$rc" = 2 ] && grep -qx 'demo/Main: update' "$T/out" && grep -q '"actor_id": 7' "$T/out"; then ok "bypass-actor change is drift"; else ko "bypass-actor drift (rc=$rc)"; fi

# 12. RULESETS_SKIP_BYPASS=1 (a read-only token, which GitHub shows no bypass
#     actors): plan leaves them out of both sides, says so, and reports no drift
rc=$(RULESETS_SKIP_BYPASS=1 run plan boonty-io "$(desired desired-bypass-only.json)")
if [ "$rc" = 0 ] && grep -qx 'demo/Main: unchanged' "$T/out" && grep -q '^note: bypass actors are not compared' "$T/out" \
   && ! grep -q 'bypass_actors' "$T/out"; then ok "skip-bypass plan ignores bypass actors and says so"; else ko "skip-bypass plan (rc=$rc)"; fi

# 12b. other drift is still reported under RULESETS_SKIP_BYPASS=1
rc=$(RULESETS_SKIP_BYPASS=1 run plan boonty-io "$(desired desired-update-only.json)")
if [ "$rc" = 2 ] && grep -qx 'demo/Staging: update' "$T/out"; then ok "skip-bypass plan still reports other drift"; else ko "skip-bypass other drift (rc=$rc)"; fi

# 13. apply refuses RULESETS_SKIP_BYPASS=1 before any call: its PUT body would
#     carry no bypass actors and clear them
rc=$(RULESETS_SKIP_BYPASS=1 run apply boonty-io "$(desired desired.json)")
if [ "$rc" = 64 ] && [ ! -s "$LOG" ]; then ok "apply refuses skip-bypass"; else ko "apply skip-bypass (rc=$rc)"; fi

# 14. a merge_queue rule (strict off) is applied as written: one PUT, the
#     queue rule and the non-strict checks in the body
rc=$(run apply boonty-io "$(desired desired-merge-queue.json)")
if [ "$rc" = 0 ] && [ -f "$T/put-12.json" ] && [ "$(jq -S . "$T/put-12.json")" = "$(jq -S '.[1]' "$F/desired-merge-queue.json")" ] \
   && [ "$(jq -r '.rules[] | select(.type == "merge_queue") | .parameters.merge_method' "$T/put-12.json")" = SQUASH ] \
   && [ "$(jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy' "$T/put-12.json")" = false ]; then
  ok "merge_queue rule applied as written"; else ko "merge_queue apply (rc=$rc)"; fi

# 15. a live ruleset already carrying that queue, its rules in another order,
#     is unchanged: the queue never reads as drift once applied
Q="$T/fix-queue"; mkdir -p "$Q"; cp "$F"/live-*.json "$Q"/
jq -c '.[1] | {id: 12, source_type: "Repository"} + . | .rules |= reverse' "$F/desired-merge-queue.json" > "$Q/live-12.json"
rc=$(FIX="$Q" run plan boonty-io "$(desired desired-merge-queue.json)")
if [ "$rc" = 0 ] && grep -qx 'demo/Staging: unchanged' "$T/out"; then ok "applied queue reads unchanged"; else ko "queue round-trip (rc=$rc)"; fi

# 16. GitHub returns a rule's parameters in its own key order (the live
#     webapp-core merge queue did, and the daily plan read it as drift on
#     2026-11-13): key order alone is never drift
jq -c '.[1] | {id: 12, source_type: "Repository"} + . | .rules |= map(if .parameters then .parameters |= (to_entries | reverse | from_entries) else . end)' \
  "$F/desired-merge-queue.json" > "$Q/live-12.json"
rc=$(FIX="$Q" run plan boonty-io "$(desired desired-merge-queue.json)")
if [ "$rc" = 0 ] && grep -qx 'demo/Staging: unchanged' "$T/out"; then ok "key order alone is not drift"; else ko "key order drift (rc=$rc)"; fi

# Environments (scripts/environments.sh): plan only, never a write.

# E1. live matches the file (reviewers listed in another order): exit 0, GETs only
rc=$(erun plan boonty-io "$(edesired desired-same.json)")
if [ "$rc" = 0 ] && grep -qx '.github/rulesets: unchanged' "$T/out" && grep -qx '.github/rulesets-plan: unchanged' "$T/out" \
   && [ -s "$LOG" ] && reads_only; then ok "environments without drift exit 0, reads only"; else ko "environments without drift (rc=$rc)"; fi

# E2. a reviewer removed from the file is drift: exit 2, the diff names them
rc=$(erun plan boonty-io "$(edesired desired-reviewer.json)")
if [ "$rc" = 2 ] && grep -qx '.github/rulesets: drift' "$T/out" && grep -q 'HugoSudefou' "$T/out" \
   && grep -qx '.github/rulesets-plan: unchanged' "$T/out" && reads_only; then ok "reviewer drift exits 2"; else ko "reviewer drift (rc=$rc)"; fi

# E3. a deployment branch beyond main is drift
rc=$(erun plan boonty-io "$(edesired desired-branch.json)")
if [ "$rc" = 2 ] && grep -qx '.github/rulesets-plan: drift' "$T/out" && grep -q 'staging' "$T/out"; then ok "branch policy drift exits 2"; else ko "branch policy drift (rc=$rc)"; fi

# E4. prevent_self_review differing is drift
rc=$(erun plan boonty-io "$(edesired desired-self-review.json)")
if [ "$rc" = 2 ] && grep -qx '.github/rulesets: drift' "$T/out" && grep -q 'prevent_self_review' "$T/out"; then ok "prevent_self_review drift exits 2"; else ko "prevent_self_review drift (rc=$rc)"; fi

# E5. a failed read fails closed with exit 1, never "unchanged"
rc=$(FAIL_GET=1 erun plan boonty-io "$(edesired desired-same.json)")
if [ "$rc" = 1 ] && ! grep -q 'unchanged' "$T/out"; then ok "environment read failure exits 1"; else ko "environment read failure (rc=$rc)"; fi

# E6. duplicate names are refused before any call
rc=$(erun plan boonty-io "$(edesired desired-dup.json)")
if [ "$rc" = 1 ] && grep -q 'duplicate' "$T/out" && [ ! -s "$LOG" ]; then ok "duplicate environment names refused"; else ko "duplicate environment names (rc=$rc)"; fi

# E7. there is no apply: anything but plan is a usage error, before any call
rc=$(erun apply boonty-io "$(edesired desired-same.json)")
if [ "$rc" = 64 ] && [ ! -s "$LOG" ]; then ok "environments has no apply"; else ko "environments apply (rc=$rc)"; fi

# Names reach `gh api repos/<owner>/<repo>/...` paths: a repository (the
# file's basename) or an environment name outside [A-Za-z0-9._-], or one that
# is `.` or `..`, is refused before any call.

# E8. an environment name with a path separator
jq '.[0].name = "../../orgs/boonty-io"' "$here/fixtures/environments/desired-same.json" > "$T/bad-env.json"
mkdir -p "$T/envs"; cp "$T/bad-env.json" "$T/envs/.github.json"
rc=$(erun plan boonty-io "$T/envs/.github.json")
if [ "$rc" = 1 ] && grep -q 'invalid environment name' "$T/out" && [ ! -s "$LOG" ]; then ok "environment name with a slash refused"; else ko "environment name with a slash (rc=$rc)"; fi

# E9. an environment name that is `..`
jq '.[0].name = ".."' "$here/fixtures/environments/desired-same.json" > "$T/envs/.github.json"
rc=$(erun plan boonty-io "$T/envs/.github.json")
if [ "$rc" = 1 ] && grep -q 'invalid environment name' "$T/out" && [ ! -s "$LOG" ]; then ok "environment name .. refused"; else ko "environment name .. (rc=$rc)"; fi

# E10. an environments file whose repository would be `..`
mkdir -p "$T/dots"; cp "$here/fixtures/environments/desired-same.json" "$T/dots/...json"
rc=$(erun plan boonty-io "$T/dots/...json")
if [ "$rc" = 1 ] && grep -q 'invalid repository name' "$T/out" && [ ! -s "$LOG" ]; then ok "environments repository .. refused"; else ko "environments repository .. (rc=$rc)"; fi

# 17. a rulesets file whose repository would be `..`, and one with a space
cp "$F/desired.json" "$T/dots/...json"
rc=$(run plan boonty-io "$T/dots/...json")
if [ "$rc" = 1 ] && grep -q 'invalid repository name' "$T/out" && [ ! -s "$LOG" ]; then ok "rulesets repository .. refused"; else ko "rulesets repository .. (rc=$rc)"; fi
cp "$F/desired.json" "$T/dots/a b.json"
rc=$(run apply boonty-io "$T/dots/a b.json")
if [ "$rc" = 1 ] && grep -q 'invalid repository name' "$T/out" && [ ! -s "$LOG" ]; then ok "rulesets repository with a space refused"; else ko "rulesets repository with a space (rc=$rc)"; fi

echo; echo "$((n - fail))/$n passed"
[ "$fail" -eq 0 ]
