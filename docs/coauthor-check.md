# AI Co-Authored-By check (`coauthor-check.yml`)

A commit's author and committer are the human who made it. AI help is recorded as an `Assisted-by: Claude Code` trailer, never as an AI `Co-Authored-By` (ai-config `shared/40-conventional-commits.md`). Once [boonty-io/ai-config#1749](https://github.com/boonty-io/ai-config/pull/1749) ships, Claude Code sessions in a synced consumer write that trailer and refuse an AI `Co-Authored-By` when they commit. This check covers every other commit: it fails a pull request when any commit in its range carries an AI `Co-Authored-By` trailer.

It is not a required context yet. Making it one is a change to `rulesets/`, in its own PR.

## Wiring

Copy [`templates/coauthor-check.yml`](../templates/coauthor-check.yml) into the repo's `.github/workflows/` and pin the `uses:` commit. It runs on `pull_request` `opened`, `synchronize` and `reopened`.

`runs_on` picks the runner. It is a JSON string or array and defaults to `"ubuntu-latest"`. Pass `'["self-hosted","deskmini"]'` to run on the minis.

## What it runs

[`scripts/coauthor-check.sh`](../scripts/coauthor-check.sh) holds no pattern. It runs the consumer's `.claude/hooks/check-commit-msg-coauthor.sh`, which `boonty-ai sync` copies from ai-config's matcher from the release that ships boonty-io/ai-config#1749 onward, on every commit message in `base..head`, merges included. It fails when:

- any commit is rejected by the matcher (the log names each one);
- the base commit, the matcher at the base, the range or a message cannot be read.

A base without the matcher, meaning a consumer on an ai-config release older than the matcher, is skipped. The skip is a green check, so it is written to the run's job summary as well as a notice. The check starts working with that repo's first ai-config bump that ships the matcher.

## What it does not cover

- **The squash message.** Only the PR's commit messages are scanned. A squash merge builds the landed message from the repository's squash settings, which can include the PR title and body, so a trailer typed into the PR body is not seen here.
- **Fork PRs.** The caller checks out `head.sha` from its own repository, so a PR from a fork is untested and can fail at checkout.

## Why it can be trusted

- **The matcher comes from the base.** The script reads it with `git show <base>:.claude/hooks/check-commit-msg-coauthor.sh` into a temporary directory and runs it there. A PR that edits or empties its own copy is still judged by the base's. The matcher looks for its `coauthor-allowlist` beside itself, which is that temporary directory, so no allowlist from the PR's tree is read.
- **No PR code runs.** The caller's checkout is used for its history only. The script comes from this repository, at the workflow's own commit.
- **Read-only.** `pull_request` with `contents: read`, and no secrets.

Tests: `test/coauthor-check.test.sh` builds throwaway repositories with a stub matcher, and covers a clean range, a rejected commit, a neutered head copy, a base without the matcher, an unreadable range and a missing input.
