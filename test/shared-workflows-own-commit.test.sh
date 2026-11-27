#!/usr/bin/env bash
# Static checks on every workflow here that checks out boonty-io/.github
# itself: it takes its scripts from its own commit (`job.workflow_sha`), never
# from a caller-supplied ref, and fails when that property is empty.
# Run: test/shared-workflows-own-commit.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
fail=0; n=0
ok() { n=$((n+1)); echo "✓ $1"; }
ko() { n=$((n+1)); fail=$((fail+1)); echo "✗ $1"; }
wfs="$(grep -lE 'repository: .?boonty-io/\.github.?[[:space:]]*$' .github/workflows/*.yml)"
[ "$(wc -l <<<"$wfs")" -ge 6 ] || { echo "✗ found only: $wfs"; exit 1; }
for f in $wfs; do
  wf="$(basename "$f" .yml)"
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
  # every job that checks out boonty-io/.github has such a guard
  if awk -v q="'" '
      /^  [A-Za-z0-9_-]+:[ \t]*$/ { if (co && !gd) bad=1; co=0; gd=0 }
      /repository: .?boonty-io\/\.github.?[ \t]*$/ { co=1 }
      index($0, "job.workflow_sha == " q q) { gd=1 }
      END { if (co && !gd) bad=1; exit bad }' "$f"; then ok "$wf guards every job that checks out boonty-io/.github"
  else ko "$wf has a job that checks out boonty-io/.github without the guard"; fi
  # each guard covers its checkout: the guard's `if:` contains the checkout's
  # own condition, so the guard runs whenever the checkout would
  if python3 - "$f" <<'PY'
import re, sys
steps = re.split(r"\n      - name:", open(sys.argv[1]).read())
norm = lambda c: re.sub(r"\s+", " ", c.replace("${{", "").replace("}}", "")).strip()
cond = lambda st: (m := re.search(r"\n        if: (.*)", st)) and norm(m.group(1)) or ""
guards = [cond(st) for st in steps if "job.workflow_sha == ''" in cond(st)]
outs = [cond(st).replace(" && job.workflow_sha != ''", "") for st in steps if re.search(r"repository: .?boonty-io/\.github.?\s*\n", st)]
sys.exit(0 if outs and all(any(c in g for g in guards) for c in outs) else 1)
PY
  then ok "$wf guards run whenever their checkout runs"; else ko "$wf has a checkout whose condition no guard covers"; fi
  # a step that runs after a failure (`!cancelled()` or `always()`) would run
  # after the guard too, so it must itself require a non-empty job.workflow_sha
  if python3 - "$f" <<'PY'
import re, sys
steps = re.split(r"\n      - name:", open(sys.argv[1]).read())
conds = [m.group(1) for st in steps if (m := re.search(r"\n        if: (.*)", st))]
late = [c for c in conds if ("!cancelled()" in c or "always()" in c) and "job.workflow_sha == ''" not in c]
sys.exit(0 if all("job.workflow_sha != ''" in c for c in late) else 1)
PY
  then ok "$wf runs no after-failure step without job.workflow_sha"; else ko "$wf has an after-failure step that can run with an empty job.workflow_sha"; fi
  # no empty `inputs:` key left under workflow_call
  if grep -A1 -E '^    inputs:\s*$' "$f" | grep -qvE '^(    inputs:\s*|      .*|--)$'; then ko "$wf leaves an empty inputs: key"; else ok "$wf has no empty inputs: key"; fi
done
# CI runs this file, so a dropped `run:` line cannot silently retire it
if grep -qE '^\s+- run: test/shared-workflows-own-commit\.test\.sh\s*$' .github/workflows/ci.yml; then ok "ci.yml runs this test"; else ko "ci.yml does not run this test"; fi

echo; echo "$((n - fail))/$n passed"
[ "$fail" -eq 0 ]
