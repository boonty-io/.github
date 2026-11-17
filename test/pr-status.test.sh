#!/usr/bin/env bash
# Cases for scripts/pr-status.sh against a fake `gh`. Run: test/pr-status.test.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../scripts/pr-status.sh"
fail=0; n=0
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'GH'
#!/usr/bin/env bash
# Fake gh: answers from $CTL, logs every call to $CTL/calls.
echo "$*" >> "$CTL/calls"
args=("$@"); expr=""; method=GET; route=""
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --jq) expr="${args[$((i+1))]}" ;;
    -X) method="${args[$((i+1))]}" ;;
    repos/*) route="${args[$i]}" ;;
  esac
done
out() { if [ -n "$expr" ]; then jq -r "$expr" <<<"$1"; else printf '%s\n' "$1"; fi; }
case "$method $route" in
  "GET repos/o/r/pulls/7") out "$(cat "$CTL/pr.json")" ;;
  "GET repos/o/r/issues/7/comments?per_page=100") out "$(cat "$CTL/comments.json")" ;;
  GET\ repos/o/r/collaborators/*/permission)
    login="${route#repos/o/r/collaborators/}"; login="${login%/permission}"
    out "{\"permission\":\"$(jq -r --arg l "$login" '.[$l] // "none"' "$CTL/perms.json")\"}" ;;
  "GET repos/o/r/issues/7/labels?per_page=100") out "$(cat "$CTL/labels.json")" ;;
  GET\ repos/o/r/labels/*) [ -f "$CTL/label-exists" ] && echo '{}' || { echo "HTTP 404" >&2; exit 1; } ;;
  "POST repos/o/r/labels") echo '{}' ;;
  "POST repos/o/r/issues/7/labels") echo '[]' ;;
  DELETE\ repos/o/r/issues/7/labels/*) echo '[]' ;;
  *) echo "unrouted: $method $route" >&2; exit 1 ;;
esac
GH
chmod +x "$work/bin/gh"

m() { printf '<!-- boonty-plan/v1 {\\"phase\\":\\"%s\\",\\"status\\":\\"in-progress\\"} -->\\n### Plan' "$1"; }
comment() { printf '{"updated_at":"%s","user":{"login":"%s"},"body":"%s"}' "$1" "$2" "$3"; }

# setup <state> <draft> <comments json array> <labels json array> [perms json]
setup() {
  rm -rf "$work/ctl"; mkdir "$work/ctl"
  printf '{"state":"%s","draft":%s}' "$1" "$2" > "$work/ctl/pr.json"
  printf '%s' "$3" > "$work/ctl/comments.json"
  printf '%s' "$4" > "$work/ctl/labels.json"
  printf '%s' "${5:-{\"Othella\":\"admin\",\"hugo\":\"write\",\"mallory\":\"read\"\}}" > "$work/ctl/perms.json"
}
run() { CTL="$work/ctl" PATH="$work/bin:$PATH" REPO=o/r PR=7 GH_TOKEN=x "$script" > "$work/ctl/out" 2>&1; }
check() {
  local name="$1" ok="$2"; n=$((n + 1))
  if [ "$ok" = 1 ]; then echo "✓ $name"; else echo "✗ $name"; sed 's/^/    calls: /' "$work/ctl/calls"; sed 's/^/    out: /' "$work/ctl/out"; fail=$((fail + 1)); fi
}
called() { grep -qF -- "$1" "$work/ctl/calls"; }

# 1. a draft with a writer's plan in gates gets pr:gates, created when missing
setup open true "[$(comment 2026-11-17T10:00:00Z Othella "$(m gates)")]" '[]'
run; check "draft + writer plan -> adds pr:gates" "$(called 'POST repos/o/r/issues/7/labels -f labels[]=pr:gates' && called 'POST repos/o/r/labels' && echo 1 || echo 0)"

# 2. the newest writer comment wins over an older one
setup open true "[$(comment 2026-11-17T10:00:00Z Othella "$(m test)"),$(comment 2026-11-17T12:00:00Z hugo "$(m ci)")]" '[]'
run; check "newest writer wins" "$(called 'labels[]=pr:ci' && ! called 'labels[]=pr:test' && echo 1 || echo 0)"

# 3. a newer comment from a non-writer is ignored
setup open true "[$(comment 2026-11-17T10:00:00Z Othella "$(m test)"),$(comment 2026-11-17T12:00:00Z mallory "$(m ci)")]" '[]'
run; check "non-writer ignored" "$(called 'labels[]=pr:test' && ! called 'labels[]=pr:ci' && echo 1 || echo 0)"

# 4. moving phase: the new label is added, then the old one removed
setup open true "[$(comment 2026-11-17T10:00:00Z Othella "$(m ci)")]" '[{"name":"pr:gates"},{"name":"bug"}]'
touch "$work/ctl/label-exists"
run; check "phase change swaps labels, keeps others" "$(called 'labels[]=pr:ci' && called 'DELETE repos/o/r/issues/7/labels/pr%3Agates' && ! called 'labels/bug' && ! called 'POST repos/o/r/labels -f' && echo 1 || echo 0)"
add=$(grep -n 'labels\[\]=pr:ci' "$work/ctl/calls" | cut -d: -f1); del=$(grep -n 'DELETE' "$work/ctl/calls" | cut -d: -f1)
check "add before remove" "$([ "$add" -lt "$del" ] && echo 1 || echo 0)"

# 5. out of draft: every pr:* label goes, nothing is added
setup open false "[$(comment 2026-11-17T10:00:00Z Othella "$(m gates)")]" '[{"name":"pr:gates"}]'
run; check "ready PR loses its label" "$(called 'DELETE repos/o/r/issues/7/labels/pr%3Agates' && ! called '-X POST' && echo 1 || echo 0)"

# 6. closed: same
setup closed true "[$(comment 2026-11-17T10:00:00Z Othella "$(m gates)")]" '[{"name":"pr:ci"}]'
run; check "closed PR loses its label" "$(called 'labels/pr%3Aci' && ! called '-X POST' && echo 1 || echo 0)"

# 7. already right: no write at all
setup open true "[$(comment 2026-11-17T10:00:00Z Othella "$(m gates)")]" '[{"name":"pr:gates"}]'
run; check "no-op when already labelled" "$(! called '-X POST' && ! called '-X DELETE' && echo 1 || echo 0)"

# 8. a draft with no plan comment loses a stale label
setup open true '[]' '[{"name":"pr:test"}]'
run; check "no plan -> no label" "$(called 'labels/pr%3Atest' && ! called '-X POST' && echo 1 || echo 0)"

# 9. the decision reads line 1 only: a marker on line 2 of a writer's comment is not a plan
setup open true "[$(comment 2026-11-17T10:00:00Z Othella "hello\\n$(m gates)")]" '[]'
run; check "marker not on line 1 is ignored" "$(! called '-X POST' && echo 1 || echo 0)"

# 10. a login that is not a GitHub login shape is never looked up
setup open true "[$(comment 2026-11-17T10:00:00Z 'x;rm' "$(m gates)")]" '[]'
run; check "odd login skipped, no permission call" "$(! called 'collaborators/x;rm' && ! called '-X POST' && echo 1 || echo 0)"

echo "$((n - fail))/$n passed"
[ "$fail" -eq 0 ]
