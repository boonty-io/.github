# Merge queue

A branch with a merge queue never asks a pull request to be "up to date with
the base". A PR is tested and gated on its own head; GitHub then builds a
commit of its own for each queue entry (the base, the entries ahead of it,
this PR), runs the required checks on that commit, and lands it when they
pass. Merging one PR no longer puts every sibling `BEHIND`, so nothing is
rebased, re-gated or re-run because the base moved.

This replaces the strict rulesets (`strict_required_status_checks_policy:
true`, "require branches to be up to date"). A branch has one or the other:
a queue rule with strict off, or strict with no queue. The rollout moves one
repository at a time (below), so both exist side by side until it ends; the
ai-config tooling reads the live rules of the base
(`gh api repos/<o>/<r>/rules/branches/<base>`) and takes the queue path only
where a `merge_queue` rule is present.

## The flow on a queue branch

1. The PR is gated and its `ci/*` suites run on its head, as before
   (`docs/on-demand-ci.md`, ai-config `shared/44`). Every required context
   must be green on the head: GitHub refuses to enqueue a PR that does not
   meet the ruleset.
2. The PR is enqueued: `gh pr merge <n> --repo <o>/<r> --match-head-commit
   <head>` (the queue's own merge method applies). `--match-head-commit`
   refuses the enqueue if the head moved since it was checked.
3. GitHub creates `gh-readonly-queue/<base>/pr-<n>-<sha>` and fires
   `merge_group` (`checks_requested`). Every workflow that produces a
   required context runs on that commit and posts on it.
4. All green: the entry lands, with the queue's merge method. A red or
   missing context removes the entry, and the entries behind it are rebuilt
   without it. A push to a queued PR removes it from the queue.

A PR whose base moved still needs a rebase when it **conflicts** (`DIRTY`):
`gh pr update-branch <n> --rebase` or a local rebase, then gates and CI on the
new head as for any new head. `BEHIND` alone is not a reason to rebase.

## What every required context needs

A context the queue entry never receives holds the entry until
`check_response_timeout_minutes`, then fails it. So, for each context in a
queue branch's ruleset, the workflow that produces it must:

- declare `merge_group:` in its `on:` (the queue reads it from the merge-group
  commit, that is from the base's files plus the PR's);
- not skip, on `merge_group`, the job that posts the context;
- post on the merge-group commit: `ci-status` posts on `GITHUB_SHA`, which is
  that commit, and ignores the empty `head_sha` input (`docs/on-demand-ci.md`).

PR-shaped checks (title, PR policy, branch policy, docs impact, trailer
checks) judge the PR, which GitHub already required green before the
enqueue. On `merge_group` they pass without judging again: the job runs and
succeeds, since a skipped job posts nothing.

`scripts/on-demand-guard.py` refuses a suite without `merge_group`. Before a
repository's queue ruleset merges, check every other producer by hand
against the list above.

## `gates/verified` in the queue

`gates/verified` is posted on the PR head, and the merge-group commit is
another sha. The shared `gates-verify.yml` therefore also runs on
`merge_group`:

- the `target` job names the queued PR from the queue ref
  (`scripts/merge-group-target.sh`; the ref must name the event's own base);
- `verify` runs the same decision as on the PR (`scripts/gates-verify.sh`:
  the last writer receipt, its base, and `content_sha256` against the PR's
  current head);
- the status goes on the merge-group commit. "No receipt yet" is `failure`
  there, never `pending`, and an entry whose ref names no PR gets `failure`.

Re-deciding rather than passing through costs seconds and keeps one meaning
for the context: a receipt for exactly this diff. It does not rely on GitHub
having held the PR head green until the moment of the enqueue.

A caller that adds `merge_group` must also give a queue entry its own
concurrency group: the PR number is empty on `merge_group`, so a group built
from it alone would let queue entries cancel each other. See the caller in
`docs/merge-by-github.md`.

## The queue rule

In `rulesets/repos/<repo>.json`, on the branch's ruleset: set
`strict_required_status_checks_policy` to `false` and add

```json
{
  "type": "merge_queue",
  "parameters": {
    "merge_method": "SQUASH",
    "grouping_strategy": "ALLGREEN",
    "max_entries_to_build": 5,
    "max_entries_to_merge": 5,
    "min_entries_to_merge": 1,
    "min_entries_to_merge_wait_minutes": 5,
    "check_response_timeout_minutes": 60
  }
}
```

- `merge_method`: `SQUASH` on an integration branch (`staging`, `develop`,
  ai-config and `.github` `main`). A `main` fed by `staging`→`main` delivery
  PRs uses `MERGE`, as those PRs merge today.
- `max_entries_to_build`: how many entries run CI at once. Each is a full run
  of the repository's suites. `pos-app-android` uses `2` (`ci/android` is a
  16-21 minute emulator run); the others `5`.
- `check_response_timeout_minutes`: longer than the slowest required suite.
- Under `ALLGREEN`, a failing entry costs one rebuild of every entry behind
  it. Never re-run a failed entry to get it through: a flake is quarantined
  (AGENTS.md).

## Side effects of a queue entry

A queue entry is a full CI run on a new commit. Before a repository moves:

- device runs: `pos-android-e2e_autotests`' device workflow skips
  `merge_group` (device time is scarce);
- shared state: a suite that writes a shared database (api-core
  `update-database`) needs a concurrency group;
- Vercel: a required `Vercel` context, and an `ci/e2e` that waits for a
  preview, need Vercel to build `gh-readonly-queue/*`. The repository's
  `vercel-ignore.sh` must build those refs, and a preview that runs
  migrations (crm) is checked first.

## Rollout and rollback

One repository at a time, in the order the merge-queue epic lists, each after
its producers are fixed. The ruleset PR merges only on the owner's go.

Rollback for one repository: revert its ruleset file to strict and no queue,
and merge it; the `rulesets` workflow applies it. The `merge_group` triggers
can stay, since they do nothing without a queue. A revert PR in this
repository goes through this repository's own queue once `.github` has one.
If that queue is what broke, the ruleset's `OrganizationAdmin` bypass actor
merges the revert, on the owner's go. That is why `.github` moves only after
two other repositories have held.

A repository with no file in `rulesets/repos/` yet (crm, docs) is first
exported (`docs/rulesets.md`) in a PR of its own that must plan `unchanged`.
Its queue change then follows.
