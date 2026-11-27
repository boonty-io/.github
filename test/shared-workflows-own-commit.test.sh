#!/usr/bin/env bash
# Static checks: the reusable workflows that check out boonty-io/.github take
# their scripts from their own commit (`job.workflow_sha`), never from a
# caller-supplied ref, and fail when that property is empty.
# Run: test/shared-workflows-own-commit.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
fail=0; n=0
ok() { n=$((n+1)); echo "✓ $1"; }
ko() { n=$((n+1)); fail=$((fail+1)); echo "✗ $1"; }
for wf in ci-hint ci-request gates-verify on-demand-guard; do
  f=".github/workflows/$wf.yml"
  if grep -q 'shared_ref' "$f"; then ko "$wf declares or reads shared_ref"; else ok "$wf has no shared_ref"; fi
  # every boonty-io/.github checkout, quoted or not, is at job.workflow_sha
  checkouts="$(grep -cE "repository: ['\"]?boonty-io/\.github['\"]?\s*$" "$f")"
  pinned="$(grep -cF 'ref: ${{ job.workflow_sha }}' "$f")"
  if [ "$checkouts" -ge 1 ] && [ "$pinned" = "$checkouts" ]; then
    ok "$wf checks out boonty-io/.github at job.workflow_sha ($checkouts)"
  else ko "$wf: $checkouts checkouts, $pinned at job.workflow_sha"; fi
  # every step guarded on an empty job.workflow_sha exits 1 before the next step starts
  if awk -v q="'" '
      /^      - name:/ { if (g && !e) bad=1; g=0; e=0 }
      index($0, "job.workflow_sha == " q q) { g=1; n++ }
      g && /exit 1/ { e=1 }
      END { if (g && !e) bad=1; exit (bad || n == 0) }' "$f"; then ok "$wf fails when job.workflow_sha is empty"
  else ko "$wf does not fail on an empty job.workflow_sha"; fi
done
echo; echo "$((n - fail))/$n passed"
[ "$fail" -eq 0 ]
