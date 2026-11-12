# On-demand CI

CI runs on a pull request when it is requested or ready for review, once more in the merge
queue, and never on a plain push. This document is the contract every
`boonty-io` repository follows; `.github/workflows/ci-request.yml` in this
repository implements the request half.

## Events

| Event | What runs | Where |
| --- | --- | --- |
| push to a branch without a PR | nothing | — |
| PR labelled `ci:run`, or `/ci` comment by an org member | every suite the repo lists, except one that already passed or is running on this head (`/ci force` runs it anyway) | dispatched on the PR head |
| PR marked ready for review, or opened, reopened or pushed to while non-draft (five-type trigger set only) | every suite, unless this head was already dispatched | dispatched on the PR head |
| draft PR opened, reopened, or pushed to | no suite — with `ci-hint.yml`, a pending "Not run yet" line per required context | — |
| `merge_group` | every suite once more before landing | merge queue |
| push to `staging` / `main` | build / deploy workflows only | — |
| `workflow_dispatch` | any single suite, by hand | — |

Drafts never run on their own: a PR is marked ready when it is ready to be
reviewed, and from then on CI runs on every new head, so a rebase onto a
moved base or a fix pushed after review is tested without a label (consumers
on the five-type trigger set below). Marking a draft ready after its head was already requested (the AI
flow flips to ready once green) does not run it twice: the request is skipped
when the head sha already has a `workflow_dispatch` run, finished or not. A
failed head is not re-run by flipping; request it again. Dependabot and fork
PRs are skipped (read-only token); request them by label or `/ci`.

A label or `/ci` does not pay twice for the same commit either. Before it
dispatches a suite, `ci-request.yml` reads that suite's `workflow_dispatch`
runs on the PR head (`scripts/ci-request-already-ran.sh`, tested by
`test/ci-request-already-ran.test.sh` and `test/ci-request-dispatch.test.sh`):

- a run still queued or in progress, or a newest run that succeeded: the suite
  is not dispatched, and one PR comment links those runs;
- no run on this head (a new push or a rebase: new code), or a newest run that
  failed, was cancelled or never started: the suite is dispatched as before;
- the runs cannot be read: the suite is dispatched (a wasted run costs less than
  a suite that never runs).

So after one suite fails, `/ci` re-runs that suite and leaves the ones that
passed. `/ci force` (or `/ci force tests.yml`) from an org member dispatches
regardless, for a suite that passed but should run again, such as one that
depends on outside state. A new commit with the same tree as one that passed
(an amended message, an empty commit) is still a new head and runs: its
statuses live on the old commit.

### Opt-in: make every required line say something (`ci-hint.yml`)

Without it, an unrequested context and a running one both read "Expected —
Waiting for status to be reported", with nothing to click: a suite posts its
`ci/*` status only when it ends. A consumer that opts in gets, per context it
lists:

- on a new head that is not a request: PENDING "Not run yet: add the ci:run
  label or comment /ci" (on a draft, "mark the PR ready, " comes first),
  linking here. It never overwrites a status already on the head;
- on a full request (label, `/ci`, PR marked ready, new head on a ready PR): PENDING "Requested:
  running", linking the head branch's dispatched runs, so the line is
  clickable while the suite runs. It never overwrites a status posted after
  the request, and on "ready" never a real verdict (nothing is dispatched for
  a head that already ran). On a label or `/ci` it never overwrites a success
  either, since that suite is not dispatched again; `/ci force` does. A partial
  `/ci tests.yml` posts nothing.

The suite's own `ci-status` step replaces the line with the verdict; a pending
line never satisfies a required check. The per-context rule is
`scripts/ci-hint-should-post.sh` (tested by `test/ci-hint-should-post.test.sh`).

It is a separate reusable workflow because it needs `statuses: write`: a
reusable workflow cannot ask for more than its caller grants, so putting it in
`ci-request.yml` would break every consumer that has not opted in.

```yaml
on:
  pull_request:
    types: [labeled, opened, reopened, synchronize, ready_for_review]
  issue_comment:
    types: [created]
# A group keeps one pending run, so hint-only events (a draft opened, reopened,
# pushed to) queue apart from requests: otherwise a push behind a queued
# `ci:run` replaces it. Hints cancel each other and never touch a request.
# The hint predicate appears twice (group, cancel-in-progress): keep them identical.
concurrency:
  group: ci-request-${{ github.event.pull_request.number || github.event.issue.number }}-${{ (github.event_name == 'pull_request' && (github.event.action == 'synchronize' || github.event.action == 'reopened' || (github.event.action == 'opened' && github.event.pull_request.draft))) && 'hint' || 'request' }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' && (github.event.action == 'synchronize' || github.event.action == 'reopened' || (github.event.action == 'opened' && github.event.pull_request.draft)) }}
jobs:
  request:
    uses: boonty-io/.github/.github/workflows/ci-request.yml@<sha> # main
    permissions: { contents: read, actions: write, pull-requests: write }
    with:
      workflows: tests.yml,ci.yml
  hint:
    uses: boonty-io/.github/.github/workflows/ci-hint.yml@<sha> # main
    permissions: { contents: read, pull-requests: read, statuses: write }
    with:
      contexts: ci/tests,ci/build
```

The guard accepts exactly `[labeled]` (label and `/ci` only: no auto-run on
ready, no hint) or that five-type set, and with the latter requires one
`ci-hint.yml` job with `contexts`, `statuses: write`, `contents: read` and
`pull-requests: read`. If it sets a workflow `concurrency`, the group must
split on `github.event.action` into `'hint'` and `'request'`, and
`cancel-in-progress` must not be a bare `true`. A consumer still on
`[labeled]` keeps working unchanged.

`/ci` alone dispatches every listed suite that has not passed on the head; `/ci tests.yml` dispatches one;
`/ci force` and `/ci force tests.yml` skip that check. A
name that is not in the repo's list is refused. Only `OWNER`, `MEMBER` and
`COLLABORATOR` comment authors are honoured. The label is removed as soon as
the request is taken, so applying it again requests another run.

## Why dispatch, not `pull_request: types: [labeled]`

A suite that fires on `labeled` fires on every label. Its jobs `if:`-skip,
and a skipped required check counts as a pass, so adding `dependencies` to a
PR would turn the whole suite green without running anything. That is the
failure mode the consumer-side guards (api-webapp
`scripts/assert-tests-workflow-honest.ts`, api-pos
`assert-pr-gates-unfiltered.sh`, webapp-admin
`workflow-pr-gates-unfiltered.test.ts`) exist to refuse.

With dispatch, a non-request produces **no run at all**. The required
contexts stay `expected` on the sha until a real request runs them, which
is exactly the visible "not ready" signal. Commit statuses and check runs
are per sha, so any push after a green run voids it without extra logic.

## Reporting the verdict: a commit status, not the check run

A run started by `workflow_dispatch` creates check runs on the commit, but
GitHub's pull-request rollup — the merge box, `gh pr checks`, and what a
ruleset evaluates — lists only suites started by `pull_request`, `push` or
`merge_group`. Measured on api-webapp#1529: 11 check suites on the head
commit, 5 in the rollup. So each suite's verdict job ends with the shared
`ci-status` action, which posts a commit status (`ci/tests`, `ci/build`,
`ci/verify`) that the rollup does show and a ruleset can require:

```yaml
  tests-complete:
    permissions:
      statuses: write
    steps:
      - name: Verdict
        run: …            # exits 1 when a required suite did not pass
      - if: always()
        uses: boonty-io/.github/.github/actions/ci-status@<sha> # main
        with:
          context: ci/tests
          job-status: ${{ job.status }}
          head-sha: ${{ inputs.head_sha }}
```

The status is `success` only when every step before it passed. When the
workflow never runs, nothing is posted and the context stays `expected`.
When the branch moved between the request and the run, the status is
`failure` with "request again".

## What a suite workflow must declare

```yaml
on:
  workflow_dispatch:
    inputs:
      pr:       { description: Pull request number,      required: false, type: string }
      base:     { description: Base branch of the PR,    required: false, type: string }
      head_sha: { description: Head sha when requested,  required: false, type: string }
      runner:   { description: github | blacksmith,      required: false, type: string, default: '' }
  merge_group:
```

Inside the suite: the `changes` job (dorny/paths-filter) passes
`base: ${{ inputs.base }}` on `workflow_dispatch` and needs `fetch-depth: 0`
there; `merge_group` is supported natively. **Before** paths-filter, a
`verify-request` step resolves the PR (`gh pr view`) and fails the job when
its base is not `inputs.base` or its head is not the commit checked out —
otherwise anyone with write access could dispatch the suite by hand with
`base=<head sha>`, get an empty diff, and certify a code commit as docs-only. Heavy jobs use
`runs-on: ${{ inputs.runner == 'github' && 'ubuntu-latest' || '<blacksmith label>' }}`
so a runner-specific failure can be reproduced on the other pool.

Use the shared verifier rather than a local copy:

```yaml
      - uses: actions/checkout@<sha>          # first: the guard refuses the reverse order
      - id: verify-request
        if: github.event_name == 'workflow_dispatch'
        uses: boonty-io/.github/.github/actions/verify-ci-request@<sha> # main
        with:
          pr: ${{ inputs.pr }}
          base: ${{ inputs.base }}
          head_sha: ${{ inputs.head_sha }}
```

The job needs `permissions: pull-requests: read`.

## Keeping it honest: the guard

One suite in each consumer calls `.github/workflows/on-demand-guard.yml` as a
job its verdict depends on. `scripts/on-demand-guard.py` refuses a suite back on
`pull_request`/`pull_request_target` or on an unfiltered `push`, a missing
dispatch input or `merge_group`, a missing or misplaced verify step, a missing
`ci-status`, a status-posting workflow absent from `ci-request.yml`, and more
than one `boonty-io/.github` ref. Lightweight PR-shaped checks (title, commit
policy, docs impact) are not suites and may stay on `pull_request`.

## Pinning `boonty-io/.github`

A consumer pins every `boonty-io/.github` reference (shared workflows and
actions) to one commit of `main`, written `@<sha> # main`. A merge here then
changes no consumer's CI until that consumer takes the new commit. The shared
workflows check out their own scripts at `job.workflow_sha`, the commit the
`uses:` line names, so the `shared_ref` input is deprecated: it is ignored
unless that property is empty, and a run where it is empty logs a warning. A
consumer that pins by commit passes no `shared_ref`: the guard counts it as a
ref, so `shared_ref: main` next to `@<sha>` is refused as a second ref. To test a branch of this
repository from a consumer, point the `uses:` lines at that branch: the
scripts follow the `uses:` ref. A `shared_ref` naming another branch is used
only when `job.workflow_sha` is empty, and that run logs a warning.

Dependabot keeps the pins current. `boonty-io/.github` has no tags, so
Dependabot moves the pin to the latest commit on `main`. Its configuration is
read from the consumer's default branch, so the entry lands there. Add the
group to the consumer's existing `github-actions` entry rather than a second
one, and set `target-branch` to the branch the consumer integrates on:

```yaml
  - package-ecosystem: 'github-actions'
    directories: ['/', '/.github/actions/*']
    target-branch: 'staging'          # the integration branch
    schedule: { interval: 'weekly' }
    groups:
      boonty-io-github:
        patterns: ['boonty-io/.github*']
```

One grouped PR moves every reference together, so the guard's one-ref rule
holds on the bump PR too.

## Runner routing (static tier)

- Short jobs (lint, typecheck, unit ≤ 5 min, actionlint, audit, verdicts) →
  `ubuntu-latest`. The org's Enterprise plan includes 50,000 minutes/month
  and after the Blacksmith move the org uses ~25,000; the GitHub minute is
  free, the 2× speed-up saves seconds.
- Heavy jobs (integration, e2e, Android assemble, anything > 5 min or
  cache-bound) → `blacksmith-4vcpu-ubuntu-2404` (or the `-arm` variant for
  Node-only repos; ARM is 0.625 of the x64 price). Public repos stay on
  `ubuntu-latest`.

## Making it enforceable

Each repository's ruleset file (`rulesets/repos/<repo>.json`,
`docs/rulesets.md`) lists the contexts its branches require: the suite
contexts (`ci/tests`, `ci/build`, `ci/verify`) where the repository runs them,
and `gates/verified` where it has moved to merge by GitHub
(`docs/merge-by-github.md`). A branch with a merge queue
(`docs/merge-queue.md`) does not require an up-to-date branch: the queue runs
every required suite again on its own commit. A context the file pins to the
GitHub Actions App (`"integration_id": 15368`) counts only when a workflow
posts it, so a PAT holding `repo:status` cannot satisfy it. A context listed
without an `integration_id` accepts a status from any source; the file is
what to read for which is which. Draft PRs are unmergeable already. `gh pr ready` is
refused by the ai-config PreToolUse hook until every required context is
green on HEAD.
