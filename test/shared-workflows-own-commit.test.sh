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
  refs="$(grep -A3 'repository: boonty-io/.github$' "$f" | grep -E '^\s+ref:' | sed 's/^ *//' | sort -u)"
  if [ -n "$refs" ] && [ "$refs" = 'ref: ${{ job.workflow_sha }}' ]; then ok "$wf checks out boonty-io/.github at job.workflow_sha"
  else ko "$wf checkout refs: ${refs:-none found}"; fi
  # every step guarded on an empty job.workflow_sha exits 1 within its own lines
  guards="$(grep -c "if: .*job.workflow_sha == ''" "$f")"
  failing="$(grep -A4 "if: .*job.workflow_sha == ''" "$f" | grep -c 'exit 1')"
  if [ "$guards" -ge 1 ] && [ "$failing" = "$guards" ]; then ok "$wf fails when job.workflow_sha is empty"
  else ko "$wf does not fail on an empty job.workflow_sha"; fi
done
echo; echo "$((n - fail))/$n passed"
[ "$fail" -eq 0 ]
