#!/usr/bin/env bash
# gate-content-hash.sh <repo-dir> <base-ref> <head-sha>
#
# Prints the sha256 of the diff merge-base(base, head)..head, rendered with every
# option that changes its text pinned, so the same commits hash the same on a
# developer's machine (whatever their git config) and on a runner. It is the
# `content_sha256` of a boonty-gates/v1 receipt; ai-config's `gate publish`
# runs the same command (keep the two in step: docs/merge-by-github.md).
#
# Unlike `git patch-id --stable` it does not ignore whitespace, and --full-index
# puts both blob ids of every diffed file in the text, so any change to a file
# the diff touches (a rebase onto a base that edited it included) changes it.
set -euo pipefail
dir="${1:?repo dir}"; base="${2:?base ref}"; head="${3:?head sha}"
mb="$(git -C "$dir" merge-base "$base" "$head")"
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 \
git -C "$dir" -c core.quotePath=true -c diff.suppressBlankEmpty=false \
  diff --no-color --no-ext-diff --no-textconv --full-index --binary --no-renames \
  --no-relative -U3 --diff-algorithm=myers --indent-heuristic \
  --submodule=short --ignore-submodules=none -O/dev/null \
  --src-prefix=a/ --dst-prefix=b/ "$mb" "$head" | sha256sum | awk '{print $1}'
