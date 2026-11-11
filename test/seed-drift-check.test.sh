#!/usr/bin/env bash
# Tests for .github/actions/seed-drift-check/check.sh in fixture repositories.
# Run: test/seed-drift-check.test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sut="$here/../.github/actions/seed-drift-check/check.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0; n=0

url=https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz
sha=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
gurl=https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz
gsha=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb

# step <name> <version> <url> <sha256> [indent] — an install-release-tool step
step() {
  local p="${5:-      }"
  printf '%s- name: Install %s\n%s  uses: boonty-io/.github/.github/actions/install-release-tool@0123456789abcdef0123456789abcdef01234567 # main\n%s  with:\n%s    name: %s\n%s    version: %s\n%s    url: %s\n%s    sha256: %s\n' \
    "$p" "$1" "$p" "$p" "$p" "$1" "$p" "$2" "$p" "$3" "$p" "$4"
}
wf() { printf 'name: x\non: push\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n%s' "$1"; }

# expect <name> <want exit> <seeder steps> <ci.yml steps, or "-" for no ci.yml>
expect() {
  n=$((n + 1))
  local d="$work/case$n"; mkdir -p "$d/.github/workflows"
  wf "$3" > "$d/.github/workflows/seed-release-tools.yml"
  [ "$4" = - ] || wf "$4" > "$d/.github/workflows/ci.yml"
  (cd "$d" && "$sut") >"$d/out" 2>&1; local rc=$?
  if [ "$rc" = "$2" ]; then echo "✓ $1 → $rc"; else echo "✗ $1: want $2, got $rc"; sed 's/^/    /' "$d/out"; fail=$((fail + 1)); fi
}

al="$(step actionlint 1.7.12 "$url" "$sha")"
gl="$(step gitleaks 8.30.1 "$gurl" "$gsha")"

expect "twin present" 0 "$al" "$al"
expect "two tools, both installed" 0 "$al
$gl" "$gl
$al"
expect "two tools, one not installed" 1 "$al
$gl" "$al"
expect "installer on another sha256" 1 "$al" "$(step actionlint 1.7.12 "$url" "${sha%?}0")"
expect "installer on another url" 1 "$al" "$(step actionlint 1.7.12 "${url/amd64/arm64}" "$sha")"
expect "seed step on another version" 1 "$(step actionlint 1.7.11 "$url" "$sha")" "$al"
expect "seed step under another name" 1 "$(step gitleaks 1.7.12 "$url" "$sha")" "$al"
expect "no other workflow" 1 "$al" -
expect "seeder has no install step" 1 "      - run: echo hi
" "$al"
expect "quoted values and trailing comments" 0 "$(step actionlint "'1.7.12'" "$url" "\"$sha\" # pinned")" "$al"
expect "4-space indent in the installer" 0 "$al" "$(step actionlint 1.7.12 "$url" "$sha" '            ')"
expect "pins outside a with: block do not count" 1 "$al" "      - run: echo name: actionlint version: 1.7.12 url: $url sha256: $sha
"
expect "step name after uses is not the input name" 0 "$al" "      - uses: boonty-io/.github/.github/actions/install-release-tool@0123456789abcdef0123456789abcdef01234567
        name: Install actionlint (step name)
        with:
          name: actionlint
          version: 1.7.12
          url: $url
          sha256: $sha
"
expect "step name after the with: block is not the input name" 0 "$al" "      - uses: boonty-io/.github/.github/actions/install-release-tool@0123456789abcdef0123456789abcdef01234567
        with:
          name: actionlint
          version: 1.7.12
          url: $url
          sha256: $sha
        name: Install actionlint (step name after with)
"
expect "seed name only a substring of the installer's" 1 "$(step lint 1.7.12 "$url" "$sha")" "$al"
expect "seeder and installer both missing url" 1 "      - uses: boonty-io/.github/.github/actions/install-release-tool@0123456789abcdef0123456789abcdef01234567
        with:
          name: actionlint
          version: 1.7.12
          sha256: $sha
" "      - uses: boonty-io/.github/.github/actions/install-release-tool@0123456789abcdef0123456789abcdef01234567
        with:
          name: actionlint
          version: 1.7.12
          sha256: $sha
"
expect "input missing from the installer" 1 "$al" "      - uses: boonty-io/.github/.github/actions/install-release-tool@0123456789abcdef0123456789abcdef01234567
        with:
          name: actionlint
          version: 1.7.12
          sha256: $sha
"

# An installer in a .yaml file counts.
n=$((n + 1)); d="$work/yaml"; mkdir -p "$d/.github/workflows"
wf "$al" > "$d/.github/workflows/seed-release-tools.yml"; wf "$al" > "$d/.github/workflows/ci.yaml"
(cd "$d" && "$sut") >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then echo "✓ installer in a .yaml workflow → 0"; else echo "✗ installer in a .yaml workflow: want 0, got $rc"; fail=$((fail + 1)); fi

echo "$((n - fail))/$n passed"
[ "$fail" = 0 ]
