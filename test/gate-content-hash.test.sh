#!/usr/bin/env bash
# Tests for scripts/gate-content-hash.sh against a throwaway repository.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sut="$here/../scripts/gate-content-hash.sh"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
g() { git -C "$t" "$@" >/dev/null 2>&1; }
git init -q -b main "$t"
seq 1 30 > "$t/f.py"; printf 'x\n' > "$t/other.txt"; g add -A; g commit -m base
g checkout -b feat
{ seq 1 15; printf 'if x:\n    c()\n'; seq 16 30; } > "$t/f.py"; g commit -am change
fail=0; n=0
check() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "✓ $1"; else echo "✗ $1: '$2' vs '$3'"; fail=$((fail + 1)); fi; }
h0="$("$sut" "$t" main HEAD)"
check "is a sha256" "$(printf "%s" "$h0" | grep -cE "^[0-9a-f]{64}$")" 1; [[ "$h0" =~ ^[0-9a-f]{64}$ ]] || { echo "cannot hash the fixture"; exit 1; }
# the developer's git config does not change it
for c in diff.noprefix=true diff.context=7 diff.algorithm=histogram diff.mnemonicPrefix=true color.diff=always diff.renames=copies core.abbrev=12; do
  check "config $c ignored" "$(git -C "$t" config "${c%%=*}" "${c#*=}" && "$sut" "$t" main HEAD; git -C "$t" config --unset "${c%%=*}")" "$h0"
done
# a whitespace-only change does change it (patch-id --stable would not)
g checkout -b ws; { seq 1 15; printf 'if x:\n  c()\n'; seq 16 30; } > "$t/f.py"; g commit -am ws
[ "$("$sut" "$t" main HEAD)" != "$h0" ]; check "whitespace change detected" $? 0
g checkout feat
# base moves on a file the diff does not touch: unchanged after rebase
g checkout main; printf 'y\n' > "$t/other.txt"; g commit -am other; g checkout feat; g rebase main
check "disjoint base move keeps it" "$("$sut" "$t" main HEAD)" "$h0"
# base moves on a file the diff touches: changes
g checkout main; { echo z; seq 1 30; } > "$t/f.py"; g commit -am same; g checkout feat; g rebase main || g rebase --abort
[ "$("$sut" "$t" main HEAD)" != "$h0" ]; check "overlapping base move changes it" $? 0
echo; echo "$((n - fail))/$n passed"; [ "$fail" -eq 0 ]
