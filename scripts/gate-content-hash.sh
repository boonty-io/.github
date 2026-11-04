#!/usr/bin/env bash
# gate-content-hash.sh <repo-dir> <base-ref> <head-sha>
#
# Prints the sha256 of `git diff-tree -r -z --full-index --no-renames` over
# merge-base(base, head)..head: for every file the diff touches, its two modes,
# its two full blob ids, its status and its path. That is the content of the
# diff without any text rendering, so no diff option, git config (global or
# repo-local), attribute or GIT_DIFF_OPTS can change it, and the same commits
# hash the same on a developer's machine and on a runner. It is the
# `content_sha256` of a boonty-gates/v1 receipt; ai-config's `gate publish`
# runs the same command (keep the two in step: docs/merge-by-github.md).
#
# Unlike `git patch-id --stable` it does not ignore whitespace (a blob id
# changes), and since both blob ids are full content addresses, any change to a
# file the diff touches (a rebase onto a base that edited it included) changes
# it, while a base move on other files does not.
set -euo pipefail
dir="${1:?repo dir}"; base="${2:?base ref}"; head="${3:?head sha}"
mb="$(git -C "$dir" merge-base "$base" "$head")"
git -C "$dir" diff-tree -r -z --full-index --no-renames --ignore-submodules=none "$mb" "$head" \
  | sha256sum | awk '{print $1}'
