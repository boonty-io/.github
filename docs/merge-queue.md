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
repository at a time (below), so both exist side by side until it ends. The
ai-config tooling is planned to read the live rules of the base
(`gh api repos/<o>/<r>/rules/branches/<base>`) and take the queue path only
where a `merge_queue` rule is present (step S2 of the merge-queue epic).

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
- the status goes on the merge-group commit, and only `success` passes
  there: "no receipt yet" is `failure`, never `pending`.
- a queue entry that cannot be verified still gets a status: a ref that
  names no PR, a PR that is closed or cannot be read, and a failed `target`
  job each get `failure` with the reason (`scripts/gates-verify-post.sh`,
  tested by `test/gates-verify-post.test.sh`). A failed checkout of the
  decision scripts, or a timed-out job, leaves no status: the entry then
  waits for `check_response_timeout_minutes` and fails.

The decision reads the PR's head when the run starts, not the head the queue
commit was built from. A push to a queued PR removes it from the queue, so a
push that lands between the enqueue and the run gives a verdict for a commit
that will not merge; the PR's new head goes through the queue again.

The queue caller runs from the queue commit, which carries the PR's own
changes (`docs/merge-by-github.md`, "Trust").

Re-deciding rather than passing through costs seconds and keeps one meaning
for the context: a receipt for exactly this diff. It does not rely on GitHub
having held the PR head green until the moment of the enqueue.

A caller that adds `merge_group` must also give a queue entry its own
concurrency group: the PR number is empty on `merge_group`, so a group built
from it alone would let queue entries cancel each other. See the caller in
`docs/merge-by-github.md`.

## The queue rule

In `rulesets/repos/<repo>.json`, on the branch's ruleset: set
`strict_required_status_checks_policy` to `false` and add the rule below. If
that ruleset also covers a branch that stays strict, move the queue branch
into a ruleset of its own instead, and name it so it sorts before the old one:
`rulesets.sh` applies by name, so the new ruleset is created before the old
one is narrowed. Its rollback differs (see "Rollout and rollback").

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
  of the repository's suites. `pos-app-android` should use `2` (`ci/android` is a
  16-21 minute emulator run); the others `5`.
- `check_response_timeout_minutes`: longer than the slowest required suite.
- `grouping_strategy`: always `ALLGREEN` on a branch that requires
  `gates/verified`. Every entry is then built and checked on its own
  `pr-<n>` commit, so `gates/verified` judges each PR. Under `HEADGREEN` only
  the head of a group must pass, and the PRs below it would land without
  their own queue verdict.
- Under `ALLGREEN`, a failing entry costs one rebuild of every entry behind
  it. Never re-run a failed entry to get it through: a flake is quarantined
  (AGENTS.md).

## Side effects of a queue entry

A queue entry is a full CI run on a new commit. Before a repository moves:

- device runs: `pos-android-e2e_autotests`' device workflow runs on
  `merge_group` today (`android-device-tests.yml` accepts a `merge_group`
  run). Making it skip `merge_group` is a prerequisite of that repository's
  move, since device time is scarce;
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
can stay, since they do nothing without a queue.

That revert is the whole rollback only when the queue rule went into a
ruleset that already existed. When the change moved the branch into a new
ruleset of its own (webapp-core `staging` went from "Protected branches" to
"Merge queue staging", because "Protected branches" also covers `main`), the
revert takes the new ruleset out of the file but not out of GitHub:
`rulesets.sh` never deletes, so it plans it `unmanaged` and its `merge_queue`
rule stays active. Roll such a change back in two steps:

1. Merge the revert. The old ruleset covers the branch again, strict, while
   the new one still holds the queue: the branch keeps its required checks
   throughout.
2. An admin disables or deletes the leftover ruleset (Settings → Rules → Rulesets,
   or `gh api -X DELETE repos/<owner>/<repo>/rulesets/<id>`). Only then
   is the queue gone.

Do not instead ship one forward PR that sets the new ruleset's `enforcement`
to `disabled` and widens the old one: `rulesets.sh` applies by name, so
"Merge queue staging" is disabled before "Protected branches" is widened, and
the branch has no rules in between.

A revert PR in this repository goes through this repository's own queue
once `.github` has one. If that queue is what broke, the ruleset's `OrganizationAdmin` bypass actor
merges the revert, on the owner's go. That is why `.github` moves only after
two other repositories have held.

A repository with no file in `rulesets/repos/` yet (crm) is first
exported (`docs/rulesets.md`) in a PR of its own that must plan `unchanged`.
Its queue change then follows.
