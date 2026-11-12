#!/usr/bin/env bash
# Tests for scripts/gates-verify-post.sh against a stub `gh` (no network).
# Run: test/gates-verify-post.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sut="$here/../scripts/gates-verify-post.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
# One argument per line, so a test can read the -f fields back.
printf '%s\n' "$@" > "$LOG"
STUB
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" LOG="$T/log" GITHUB_REPOSITORY=boonty-io/demo GH_TOKEN=x
Q=1111111111111111111111111111111111111111
H=2222222222222222222222222222222222222222
URL=https://example.invalid/run
fail=0; n=0
field() { sed -n "s/^$1=//p" "$LOG"; }
# expect <name> <want rc> <want sha|-> <want state> <want description> -- <args...>
expect() {
  local name="$1" rc_want="$2" sha_want="$3" state_want="$4" desc_want="$5"; shift 6
  n=$((n + 1)); rm -f "$LOG"
  "$sut" "$@" > /dev/null 2>&1; local rc=$?
  local path="" state="" desc=""
  if [ -f "$LOG" ]; then path="$(sed -n 4p "$LOG")"; state="$(field state)"; desc="$(field description)"; fi
  if [ "$sha_want" = - ]; then
    { [ "$rc" = "$rc_want" ] && [ ! -f "$LOG" ]; } && { echo "✓ $name"; return; }
  elif [ "$rc" = "$rc_want" ] && [ "$path" = "repos/boonty-io/demo/statuses/$sha_want" ] &&
       [ "$state" = "$state_want" ] && [ "$desc" = "$desc_want" ]; then
    echo "✓ $name"; return
  fi
  echo "✗ $name: rc=$rc path=$path state=$state desc=$(printf '%q' "$desc")"; fail=$((fail + 1))
}
long="$(printf 'x%.0s' $(seq 1 200))"

# pull request events: the head, the state as given (unchanged behaviour)
expect "PR success on the head" 0 "$H" success "4/4 pass" -- pull_request_target "" "$H" 7 success "4/4 pass" "$URL"
expect "PR pending stays pending" 0 "$H" pending "no receipt" -- pull_request_target "" "$H" 7 pending "no receipt" "$URL"
expect "PR empty state is failure" 0 "$H" failure "gates-verify could not decide; see the run" -- issue_comment "" "$H" 7 "" "" "$URL"
expect "PR without a head posts nothing" 1 - "" "" -- pull_request_target "" "" 7 success "x" "$URL"
# merge_group: the queue sha, never the head; only success passes
expect "queue success on the queue sha" 0 "$Q" success "#7: 4/4 pass" -- merge_group "$Q" "$H" 7 success "4/4 pass" "$URL"
expect "queue pending becomes failure" 0 "$Q" failure "#7: no receipt" -- merge_group "$Q" "$H" 7 pending "no receipt" "$URL"
expect "queue empty state is failure" 0 "$Q" failure "#7: gates-verify could not decide; see the run" -- merge_group "$Q" "" 7 "" "" "$URL"
expect "queue unknown state is failure" 0 "$Q" failure "#7: x" -- merge_group "$Q" "$H" 7 bogus "x" "$URL"
expect "queue error state is failure" 0 "$Q" failure "#7: x" -- merge_group "$Q" "$H" 7 error "x" "$URL"
expect "queue with no PR still posts" 0 "$Q" failure "merge queue - the queue ref names no pull request" -- merge_group "$Q" "" "" "" "merge queue - the queue ref names no pull request" "$URL"
expect "queue description is cut to 140" 0 "$Q" failure "#7: ${long:0:136}" -- merge_group "$Q" "$H" 7 pending "$long" "$URL"
expect "queue description loses newlines" 0 "$Q" failure "#7: a b" -- merge_group "$Q" "$H" 7 pending $'a\nb' "$URL"
expect "queue without a queue sha posts nothing" 1 - "" "" -- merge_group "" "$H" 7 success "x" "$URL"
expect "queue sha must be 40 hex" 1 - "" "" -- merge_group "${Q:0:12}" "$H" 7 success "x" "$URL"
echo "$((n - fail))/$n passed"
[ "$fail" = 0 ]
