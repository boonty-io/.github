#!/usr/bin/env bash
# Runs the drift check of templates/seed-release-tools.yml in fixture repos
# where the template is installed as .github/workflows/seed-release-tools.yml:
# it must pass only when every url and sha256 the seeder seeds appears in
# another workflow.
# Run: test/seed-release-tools-template.test.sh (needs python3 with PyYAML)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template="$here/../templates/seed-release-tools.yml"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0; n=0

# The check's own `run:` body, so the test exercises exactly what ships.
python3 - "$template" > "$work/check.sh" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["seed"]["steps"]
[check] = [s for s in steps if s.get("name") == "Seeded pins match the workflows that install them"]
print(check["run"])
PY
url=https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz
sha=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8

# expect <name> <want exit> <installing ci.yml content> [perl edit for the seeder]
expect() {
  n=$((n + 1))
  local d="$work/case$n"; mkdir -p "$d/.github/workflows"
  cp "$template" "$d/.github/workflows/seed-release-tools.yml"
  [ -n "${4:-}" ] && perl -0pi -e "$4" "$d/.github/workflows/seed-release-tools.yml"
  [ -n "$3" ] && printf '%s\n' "$3" > "$d/.github/workflows/ci.yml"
  (cd "$d" && bash "$work/check.sh") >/dev/null 2>&1; local rc=$?
  if [ "$rc" = "$2" ]; then echo "✓ $1 → $rc"; else echo "✗ $1: want $2, got $rc"; fail=$((fail + 1)); fi
}

both="url: $url
sha256: $sha"
expect "installing workflow carries url and sha256" 0 "$both"
expect "sha256 missing from the installing workflow" 1 "url: $url"
expect "url missing from the installing workflow" 1 "sha256: $sha"
expect "installing workflow on another version" 1 "url: ${url//1.7.12/1.7.11}
sha256: $sha"
expect "no other workflow at all" 1 ""
expect "seed step's own sha256 differs" 1 "$both" "s/sha256: $sha/sha256: ${sha%?}0/"
expect "seed step's own url differs" 1 "$both" 's/v1\.7\.12\/actionlint_1\.7\.12/v1.7.11\/actionlint_1.7.11/'
expect "seed step's quoted pins still read" 0 "$both" "s/sha256: $sha/sha256: '$sha'/"
expect "seeder with no url or sha256 input" 1 "$both" 's/^\s+(url|sha256):.*\n//mg'
n=$((n + 1)); d="$work/yaml"; mkdir -p "$d/.github/workflows"
cp "$template" "$d/.github/workflows/seed-release-tools.yml"; printf '%s\n' "$both" > "$d/.github/workflows/ci.yaml"
(cd "$d" && bash "$work/check.sh") >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then echo "✓ installing workflow named .yaml → 0"; else echo "✗ installing workflow named .yaml: want 0, got $rc"; fail=$((fail + 1)); fi
echo "$((n - fail))/$n passed"
[ "$fail" = 0 ]
