#!/usr/bin/env bash
# Tests for scripts/gates-verify-facts.sh, with `gh` replaced by a stub on PATH.
# Run: test/gates-verify-facts.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sut="$here/../scripts/gates-verify-facts.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MOVED=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# The stub answers the three reads the script makes. Each can be made to fail
# (STUB_*_FAIL=1) or to report another head (STUB_VIEW_HEAD, STUB_AGAIN_HEAD).
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "pr view "*"--json title,isCrossRepository,changedFiles,headRefOid"*)
    [ "${STUB_VIEW_FAIL:-}" = 1 ] && exit 1
    printf '{"title":"docs(shared-learnings): add x","isCrossRepository":false,"changedFiles":2,"headRefOid":"%s"}\n' "$STUB_VIEW_HEAD" ;;
  "pr view "*"--json headRefOid --jq .headRefOid"*)
    [ "${STUB_AGAIN_FAIL:-}" = 1 ] && exit 1
    echo "$STUB_AGAIN_HEAD" ;;
  "api repos/"*"/pulls/"*"/files --paginate"*)
    echo '{"filename":"shared-learnings/a.md","previous_filename":null}'
    [ "${STUB_FILES_FAIL:-}" = 1 ] && exit 1
    echo '{"filename":"shared-learnings/b.md","previous_filename":"shared-learnings/c.md"}' ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$work/bin/gh"

fail=0; n=0
case_() { # <name> <want: facts|none> [VAR=value ...]
  n=$((n + 1)); local name="$1" want="$2"; shift 2
  rm -f "$work/facts.json"
  local printed
  printed="$(env PATH="$work/bin:$PATH" STUB_VIEW_HEAD="$HEAD" STUB_AGAIN_HEAD="$HEAD" "$@" \
    "$sut" boonty-io/ai-config 7 "$HEAD" "$work/facts.json" 2>/dev/null)"; local rc=$?
  local ok=1
  if [ "$want" = facts ]; then
    [ "$rc" = 0 ] && [ "$printed" = "$work/facts.json" ] &&
      jq -e '.repo == "boonty-io/ai-config" and .title == "docs(shared-learnings): add x"
             and .cross_repo == false and .changed_files == 2
             and .files == [{"filename":"shared-learnings/a.md","previous_filename":null},
                            {"filename":"shared-learnings/b.md","previous_filename":"shared-learnings/c.md"}]' \
        "$work/facts.json" >/dev/null 2>&1 || ok=0
  else
    [ "$rc" = 0 ] && [ -z "$printed" ] && [ ! -e "$work/facts.json" ] || ok=0
  fi
  if [ "$ok" = 1 ]; then echo "✓ $name → $want"; else echo "✗ $name: want $want, rc=$rc printed='$printed'"; fail=$((fail + 1)); fi
}
case_ "every read succeeds on the same head" facts
case_ "the first view reports another head" none STUB_VIEW_HEAD="$MOVED"
case_ "the head moved before the second read" none STUB_AGAIN_HEAD="$MOVED"
case_ "the first view fails" none STUB_VIEW_FAIL=1
case_ "the file list fails after a first page" none STUB_FILES_FAIL=1
case_ "the second head read fails" none STUB_AGAIN_FAIL=1
echo; echo "$((n - fail))/$n passed"
[ "$fail" -eq 0 ]
