#!/usr/bin/env bash
# Write the facts `scripts/gates-verify.sh` reads for the learnings exemption.
#
#   gates-verify-facts.sh <owner/repo> <pr-number> <head-sha> <out.json>
#
# Reads with `gh` (from PATH, authenticated by GH_TOKEN):
#   1. gh pr view --json title,isCrossRepository,changedFiles,headRefOid
#   2. gh api --paginate repos/<repo>/pulls/<pr>/files (filename, previous_filename)
#   3. gh pr view --json headRefOid, again
#
# Writes {"repo","title","cross_repo","changed_files","files":[…]} to <out.json>
# and prints its path, only when every read succeeds and the head both reads
# report is <head-sha>: the facts then describe that head and no other.
# Otherwise it writes nothing, prints nothing and exits 0, so the caller passes
# an empty facts path and the decision grants no exemption.
set -euo pipefail
repo="${1:?owner/repo}"; pr="${2:?pr number}"; head="${3:?head sha}"; out="${4:?out.json}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

nothing() { echo "::notice title=gates-verify::$1; no exemption on this run" >&2; exit 0; }

gh pr view "$pr" --repo "$repo" --json title,isCrossRepository,changedFiles,headRefOid > "$tmp/view.json" \
  || nothing "could not read the pull request"
[ "$(jq -r '.headRefOid // ""' "$tmp/view.json")" = "$head" ] \
  || nothing "the pull request head is not $head"
gh api "repos/$repo/pulls/$pr/files" --paginate --jq '.[] | {filename, previous_filename}' > "$tmp/files.jsonl" \
  || nothing "could not read the file list"
jq -s . "$tmp/files.jsonl" > "$tmp/files.json" \
  || nothing "could not parse the file list"
again="$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq .headRefOid)" \
  || nothing "could not read the pull request head again"
[ "$again" = "$head" ] \
  || nothing "the head moved while its facts were read"

jq -n --arg repo "$repo" --slurpfile v "$tmp/view.json" --slurpfile f "$tmp/files.json" \
  '{repo: $repo, title: $v[0].title, cross_repo: $v[0].isCrossRepository,
    changed_files: $v[0].changedFiles, files: $f[0]}' > "$out"
echo "$out"
