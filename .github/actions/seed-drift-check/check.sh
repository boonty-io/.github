#!/usr/bin/env bash
# seed-drift-check — fail unless every install-release-tool step in the seeder
# has a twin, with the same name, version, url and sha256, in another workflow.
#
# The cache key is release-tool-<name>-<version>-<sha256>, so a seed step
# that differs from its installer in any of name, version or sha256 seeds a
# key no install reads. The url is compared too, so a seeder cannot pass
# while fetching a different asset under the same key.
#
# Reads YAML with awk, no parser: inside each step whose `uses:` names
# install-release-tool, it takes the name/version/url/sha256 lines nested
# under that step's `with:`. Quotes and trailing comments are stripped.
#
# Usage: check.sh [seeder path]   (default .github/workflows/seed-release-tools.yml)
set -euo pipefail

self="${1:-.github/workflows/seed-release-tools.yml}"
[ -f "$self" ] || { echo "::error::seed-drift-check: $self not found"; exit 1; }

# Prints one `name|version|url|sha256` line per install-release-tool step.
keys() {
  awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    function flush() {
      if (on && f["name"] != "" && f["version"] != "" && f["url"] != "" && f["sha256"] != "")
        print f["name"] "|" f["version"] "|" f["url"] "|" f["sha256"]
      on = 0; wi = -1; split("", f)
    }
    /^[[:space:]]*-[[:space:]]/ { flush() }                 # a new step
    /^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[^[:space:]]*\/install-release-tool@/ { on = 1; next }
    on && /^[[:space:]]*with:[[:space:]]*$/ { wi = indent($0); next }
    on && wi >= 0 && NF && indent($0) <= wi { wi = -1 }       # left the with: block
    on && wi >= 0 && match($0, /^[[:space:]]+(name|version|url|sha256):/) {
      k = $0; sub(/^[[:space:]]+/, "", k); sub(/:.*/, "", k)
      v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); sub(/[[:space:]]+#.*$/, "", v)
      gsub(/["\047]/, "", v); sub(/[[:space:]]+$/, "", v)
      f[k] = v
    }
    END { flush() }
  ' "$@"
}

mapfile -t want < <(keys "$self")
[ "${#want[@]}" -gt 0 ] || { echo "::error::seed-drift-check: no install-release-tool step with name, version, url and sha256 in $self"; exit 1; }

others=()
for f in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -e "$f" ] && [ "$f" != "$self" ] && others+=("$f")
done
have="$( [ "${#others[@]}" -gt 0 ] && keys "${others[@]}" || true )"

rc=0
for k in "${want[@]}"; do
  if grep -qxF -- "$k" <<< "$have"; then
    echo "seeded and installed: ${k%%|*}"
  else
    echo "::error::seed-drift-check: $self seeds ${k} but no other workflow installs exactly that (name|version|url|sha256), so it seeds a key no install reads"
    rc=1
  fi
done
exit "$rc"
