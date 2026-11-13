#!/usr/bin/env bash
# The rulesets workflow must hand every rulesets/repos/*.json to rulesets.sh,
# dotfiles included: `.github.json` sat unapplied because a bare `*.json`
# glob skips names starting with a dot.
# Run: test/rulesets-workflow-files.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
wf=.github/workflows/rulesets.yml
line="$(grep -E 'scripts/rulesets\.sh "\$MODE" "\$OWNER"' "$wf")" || { echo "✗ no rulesets.sh call in $wf"; exit 1; }
# the file arguments: everything after "$OWNER" up to the redirection
args="${line#*\"\$OWNER\"}"; args="${args%%>*}"
got=""
for pat in $args; do
  case "$pat" in rulesets/repos/*) ;; *) echo "✗ unexpected argument $pat"; exit 1 ;; esac
  got+="$(compgen -G "$pat")"$'\n'
done
got="$(printf '%s' "$got" | sed '/^$/d' | sort -u)"
want="$(find rulesets/repos -maxdepth 1 -type f -name '*.json' | sort)"
if [ "$got" = "$want" ]; then echo "✓ workflow applies every rulesets/repos file ($(wc -l <<<"$want" | tr -d ' '))"; exit 0; fi
echo "✗ workflow file list differs from rulesets/repos"
diff <(echo "$want") <(echo "$got") | sed 's/^/    /'
exit 1
