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
# Logs every call; serves the fixtures for repos/boonty-io/demo.
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
  "GET repos/boonty-io/demo/rulesets") cat "$FIX/live-list.json" ;;
  "GET repos/boonty-io/demo/rulesets/"*) cat "$FIX/live-${path##*/}.json" ;;
  "PUT repos/boonty-io/demo/rulesets/"*) cp "$input" "$OUT/put-${path##*/}.json"; echo '{}' ;;
  "POST repos/boonty-io/demo/rulesets") cp "$input" "$OUT/post-$(jq -r .name "$input").json"; echo '{}' ;;
  *) echo "stub gh: unexpected $method $path" >&2; exit 9 ;;
esac
STUB
chmod +x "$T/bin/gh"
export LOG="$T/log" FIX="$F" OUT="$T"
fail=0; n=0
ok() { n=$((n+1)); echo "✓ $1"; }
ko() { n=$((n+1)); fail=$((fail+1)); echo "✗ $1"; [ -s "$T/out" ] && sed 's/^/    /' "$T/out"; }
run() { : > "$LOG"; rm -f "$T"/put-* "$T"/post-*; PATH="$T/bin:$PATH" "$sut" "$@" > "$T/out" 2>&1; echo $?; }
desired() { cp "$F/$1" "$T/repos/demo.json"; echo "$T/repos/demo.json"; }

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

echo; echo "$((n - fail))/$n passed"
[ "$fail" -eq 0 ]
