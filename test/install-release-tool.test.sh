#!/usr/bin/env bash
# Tests for .github/actions/install-release-tool (install.sh with a fake curl,
# plus the save-step wiring in action.yml). Needs GNU sha256sum, bash 4+ and
# python3 with PyYAML, as on ubuntu-latest.
# shellcheck disable=SC2016,SC2034  # check() evals its single-quoted condition later, by design
# Run: test/install-release-tool.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sut="$here/../.github/actions/install-release-tool/install.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0; n=0
ok() { n=$((n + 1)); echo "✓ $1"; }
ko() { n=$((n + 1)); echo "✗ $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else ko "$1"; fi; }

# Fixture release: a tarball holding an executable `tool` at its root and one
# at `sub/dir/tool`, plus a corrupt copy.
mkdir -p "$work/src/sub/dir"
printf '#!/bin/sh\necho fixture-tool-ran\n' > "$work/src/tool"
cp "$work/src/tool" "$work/src/sub/dir/tool"
tar -czf "$work/release.tar.gz" -C "$work/src" tool sub
good_sha="$(sha256sum "$work/release.tar.gz" | cut -d' ' -f1)"
printf 'not a tarball' > "$work/corrupt.tar.gz"

# Fake curl: logs its argv, fails the first $FAKE_FAIL calls (counted in a
# file), then copies $FAKE_SRC to the -o path.
cat > "$work/curl" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
c=$(( $(cat "$FAKE_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$FAKE_COUNT"
[ "$c" -le "${FAKE_FAIL:-0}" ] && exit 22
while [ $# -gt 0 ]; do [ "$1" = -o ] && { cp "$FAKE_SRC" "$2"; exit 0; }; shift; done
exit 2
SH
chmod +x "$work/curl"

# One fresh runner per case. Prints nothing; sets $R to the case dir.
runner() {
  R="$work/case$n"; rm -rf "$R"; mkdir -p "$R/temp" "$R/ws"
  : > "$R/out"; : > "$R/path"; : > "$R/log"; rm -f "$R/count"
}
# run <cmd> [VAR=val ...] — the action's env, overridable per case.
run() {
  local cmd="$1"; shift
  env -i PATH="$PATH" RUNNER_TEMP="$R/temp" GITHUB_WORKSPACE="$R/ws" \
    GITHUB_OUTPUT="$R/out" GITHUB_PATH="$R/path" \
    CURL="$work/curl" FAKE_LOG="$R/log" FAKE_COUNT="$R/count" FAKE_SRC="$work/release.tar.gz" \
    NAME=tool VERSION=1.2.3 URL=https://example.test/tool.tar.gz SHA256="$good_sha" \
    TARBALL="$R/temp/release-tools/tool-1.2.3.tar.gz" RETRY_DELAY=0 \
    "$@" "$sut" "$cmd" >"$R/stdout" 2>"$R/stderr"
}
out() { grep "^$1=" "$R/out" | tail -1 | cut -d= -f2-; }

# --- prep
runner; run prep; rc=$?
check "prep exits 0" '[ $rc = 0 ]'
check "prep: key carries name, version and sha256" '[ "$(out key)" = "release-tool-tool-1.2.3-$good_sha" ]'
check "prep: tarball lives under RUNNER_TEMP" '[ "$(out tarball)" = "$R/temp/release-tools/tool-1.2.3.tar.gz" ]'

# --- cache miss
runner; mkdir -p "$R/temp/release-tools"; run install CACHE_HIT=; rc=$?
check "miss: exits 0" '[ $rc = 0 ]'
check "miss: curl called once" '[ "$(wc -l < "$R/log" | tr -d " ")" = 1 ]'
check "miss: save=true" '[ "$(out save)" = true ]'
check "miss: binary installed and runs" '[ "$("$(out path)")" = fixture-tool-ran ]'
check "miss: PATH dir is outside the workspace" '[ "$(cat "$R/path")" = "$R/temp/release-tools/bin" ]'
check "miss: tarball kept for the cache save" '[ -f "$R/temp/release-tools/tool-1.2.3.tar.gz" ]'

# --- retry flags as the action ships them (RETRY_DELAY unset → 10)
runner; mkdir -p "$R/temp/release-tools"; run install CACHE_HIT= RETRY_DELAY=; rc=$?
check "retry flags: --retry 5 --retry-all-errors --retry-delay 10 -f" \
  'grep -q -- "--retry 5 --retry-all-errors --retry-delay 10" "$R/log" && grep -q -- "-fsSL" "$R/log"'
check "https only, redirects included" \
  'grep -q -- "--proto =https --proto-redir =https" "$R/log"'

# --- cache hit, valid tarball: no network
runner; mkdir -p "$R/temp/release-tools"; cp "$work/release.tar.gz" "$R/temp/release-tools/tool-1.2.3.tar.gz"
run install CACHE_HIT=true FAKE_FAIL=99; rc=$?
check "hit: exits 0 with curl failing" '[ $rc = 0 ]'
check "hit: curl never called" '[ ! -s "$R/log" ]'
check "hit: save=false" '[ "$(out save)" = false ]'
check "hit: binary runs" '[ "$("$(out path)")" = fixture-tool-ran ]'

# --- cache hit, corrupt tarball: re-download, warn, do not save
runner; mkdir -p "$R/temp/release-tools"; cp "$work/corrupt.tar.gz" "$R/temp/release-tools/tool-1.2.3.tar.gz"
run install CACHE_HIT=true; rc=$?
check "corrupt hit: exits 0 after re-download" '[ $rc = 0 ]'
check "corrupt hit: warns" 'grep -q "::warning::" "$R/stdout"'
check "corrupt hit: save=false" '[ "$(out save)" = false ]'

# --- cache hit, corrupt tarball, download down: fail closed
runner; mkdir -p "$R/temp/release-tools"; cp "$work/corrupt.tar.gz" "$R/temp/release-tools/tool-1.2.3.tar.gz"
run install CACHE_HIT=true FAKE_FAIL=99; rc=$?
check "corrupt hit + outage: exits 1" '[ $rc = 1 ]'
check "corrupt hit + outage: nothing on PATH" '[ ! -s "$R/path" ]'

# --- miss, wrong sha256: fail closed, nothing installed or saved
runner; mkdir -p "$R/temp/release-tools"; run install CACHE_HIT= SHA256="$(printf '0%.0s' {1..64})"; rc=$?
check "bad sha: exits 1" '[ $rc = 1 ]'
check "bad sha: nothing on PATH" '[ ! -s "$R/path" ] && [ ! -e "$R/temp/release-tools/bin/tool" ]'
check "bad sha: no save output" '[ -z "$(out save)" ]'

# --- miss, download fails: fail closed
runner; mkdir -p "$R/temp/release-tools"; run install CACHE_HIT= FAKE_FAIL=99; rc=$?
check "outage on miss: exits 1" '[ $rc = 1 ] && grep -q "failed after retries" "$R/stderr"'

# --- nested member
runner; mkdir -p "$R/temp/release-tools"; run install CACHE_HIT= MEMBER=sub/dir/tool; rc=$?
check "member: nested path installed as NAME" '[ $rc = 0 ] && [ "$(out path)" = "$R/temp/release-tools/bin/tool" ] && [ "$("$(out path)")" = fixture-tool-ran ]'
runner; mkdir -p "$R/temp/release-tools"; run install CACHE_HIT= MEMBER=missing; rc=$?
check "member: absent member fails" '[ $rc = 1 ]'

# --- input validation (prep and install both refuse)
for bad in 'NAME=to;ol' 'NAME=Tool' 'NAME=' 'VERSION=1 2' 'VERSION=$(id)' 'SHA256=ABC' "SHA256=$(printf %s "$good_sha" | tr a-f A-F)" "SHA256=${good_sha}0"; do
  for cmd in prep install; do
    runner; mkdir -p "$R/temp/release-tools"; run "$cmd" CACHE_HIT= "$bad"; rc=$?
    check "$cmd refuses $bad" '[ $rc = 1 ] && [ ! -s "$R/log" ]'
  done
done
runner; mkdir -p "$R/temp/release-tools"; run install CACHE_HIT= URL=http://example.test/t.tgz; rc=$?
check "install refuses a non-https url" '[ $rc = 1 ] && [ ! -s "$R/log" ]'

# --- action.yml: the save step runs only when install.sh asked for it, and a
# failed save cannot redden the caller.
save_step="$(python3 - "$here/../.github/actions/install-release-tool/action.yml" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
save = [s for s in steps if str(s.get("uses", "")).startswith("actions/cache/save@")]
print(len(save), save[0].get("if") if save else "", save[0].get("continue-on-error") if save else "")
PY
)"
check "action.yml: one save step, gated on save == 'true', continue-on-error" \
  '[ "$save_step" = "1 steps.install.outputs.save == '"'"'true'"'"' True" ]'

echo "$((n - fail))/$n passed"
[ "$fail" = 0 ]
