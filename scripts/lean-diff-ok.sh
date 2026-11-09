#!/usr/bin/env bash
# Is merge-base(<base-ref>, <head-sha>)..<head-sha> a docs-only diff?
#
#   lean-diff-ok.sh <repo-dir> <base-ref> <head-sha>
#
# exit 0  docs-only: at least one entry, every path on LEAN_SAFE and none on
#         LEAN_NEVER (case-insensitive), no control character in a path, and
#         mode 100644 or 000000 (absent) on both sides: no symlink, gitlink or
#         executable bit.
# exit 1  not docs-only.
# exit 2  the diff cannot be read, or is empty.
#
# The rules are copies of ai-config scripts/gate.ts LEAN_SAFE_PATHS,
# LEAN_NEVER_PATHS and LEAN_MODES, the rules `gate lean` and `gate publish`
# apply on the client. Here they are the authority: a lean receipt only counts
# when this measure agrees. Replace refs and grafts are switched off, so
# neither can make a non-docs head read as a docs-only one.
set -uo pipefail
dir="${1:?repo dir}"; base="${2:?base ref}"; head="${3:?head sha}"
LEAN_SAFE='^(shared-learnings/[^/]+\.md|docs/[^/]+(/[^/]+)*\.md|README\.md|CONTRIBUTING\.md)$'
LEAN_NEVER='(^|/)(CLAUDE|CLAUDE\.local|AGENTS)\.md$'

g() { GIT_GRAFT_FILE=/dev/null git -C "$dir" --no-replace-objects "$@"; }
mb="$(g merge-base "$base" "$head" 2>/dev/null)" || exit 2
[[ "$mb" =~ ^[0-9a-f]{40}$ ]] || exit 2
raw="$(mktemp)"; trap 'rm -f "$raw"' EXIT
g diff --no-renames --no-relative --ignore-submodules=none --raw -z "$mb" "$head" > "$raw" 2>/dev/null || exit 2

entries=0; bad=0
# Each entry is two NUL-terminated fields: ":<src> <dst> <srcsha> <dstsha> <status>" then the path.
while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
  [[ "$meta" == :* ]] || exit 2
  read -r src dst _ _ status <<<"${meta#:}"
  case "$status" in R*|C*) exit 2 ;; esac
  entries=$((entries + 1))
  case "$src" in 100644|000000) ;; *) bad=1; continue ;; esac
  case "$dst" in 100644|000000) ;; *) bad=1; continue ;; esac
  if [[ "$path" =~ [[:cntrl:]] ]]; then bad=1; continue; fi
  [[ "$path" =~ $LEAN_SAFE ]] || { bad=1; continue; }
  shopt -s nocasematch
  if [[ "$path" =~ $LEAN_NEVER ]]; then bad=1; fi
  shopt -u nocasematch
done < "$raw"
[ "$entries" -gt 0 ] || exit 2
[ "$bad" -eq 0 ] || exit 1
exit 0
