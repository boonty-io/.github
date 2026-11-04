# Merge by GitHub

A pull request merges itself once it is reviewed, gated and green. No session
has to stay alive for it, and nobody has to reach the queue orchestrator.

## The flow

1. The session runs the four Phase 5 gates as today, then
   `boonty-ai gate publish`. That posts, or updates, one PR comment that
   starts with `<!-- boonty-gates v1 -->`. The comment carries the head sha,
   the patch-id (`diff_hash`) and the four verdicts.
2. The session marks the PR ready and enables auto-merge
   (`gh pr merge --auto --squash`, or the repository's usual method).
3. `gates-verify` runs on the comment and on every new head. It posts
   `gates/verified`:
   - `success` when the newest receipt from someone with write access shows
     4/4 `pass` for the patch the head carries;
   - `failure` when a gate did not pass or the patch changed since the gates
     ran;
   - `pending` when no receipt exists yet.
4. Ready PRs run their `ci/*` suites on every new head (`docs/on-demand-ci.md`).
5. GitHub merges once every required check is green, plus the approval where
   the ruleset requires one.

**When the base moves.** `gh pr update-branch --rebase` gives the PR a new
head. Its CI re-runs on its own. `gates/verified` stays green when the patch is
unchanged, which is the usual case. If the rebase changed the patch, the
status turns red and the gates must run again.

**Trust.** The receipt is as trustworthy as today's local receipt files: a
person with write access could forge either. What changes is where it is
checked. GitHub checks it, from the default branch's workflow, against the
patch it is about to merge. The context is posted by GitHub Actions and the
ruleset pins it to that App (integration 15368), so a personal token cannot
post a green `gates/verified`.

## Enabling it in a repository

1. Add `.github/workflows/gates-verify.yml`:

   ```yaml
   name: gates-verify
   on:
     pull_request_target:
       types: [opened, reopened, synchronize, ready_for_review]
     issue_comment:
       types: [created, edited]
   permissions: {}
   concurrency:
     group: gates-verify-${{ github.event.pull_request.number || github.event.issue.number }}
     cancel-in-progress: true
   jobs:
     verify:
       if: github.event_name == 'pull_request_target' || (github.event.issue.pull_request && contains(github.event.comment.body, '<!-- boonty-gates v1 -->'))
       uses: boonty-io/.github/.github/workflows/gates-verify.yml@main
       permissions: { contents: read, pull-requests: read, statuses: write }
   ```

   `issue_comment` and `pull_request_target` run from the default branch, so
   the caller takes effect once it is on `main`.
2. In `rulesets/repos/<repo>.json`, add
   `{"context": "gates/verified", "integration_id": 15368}` to the required
   checks of each protected branch. Do it after step 1 has reached `main`, or
   every PR waits on a status nobody posts.
3. Turn on Settings → General → **Allow auto-merge**.

## What the queue orchestrator still does

It is no longer on the merge path. It keeps the cross-PR view: overlaps, merge
order between dependent PRs, stale drafts. A dependent PR stays draft until
the PR it depends on has merged, so auto-merge cannot land the two in the
wrong order.
