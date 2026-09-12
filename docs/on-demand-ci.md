# On-demand CI

CI runs once per pull request when it is requested, once more in the merge
queue, and never on a plain push. This document is the contract every
`boonty-io` repository follows; `.github/workflows/ci-request.yml` in this
repository implements the request half.

## Events

| Event | What runs | Where |
| --- | --- | --- |
| push to a feature branch / PR sync | nothing | — |
| PR labelled `ci:run`, or `/ci` comment by an org member | every suite workflow the repo lists | dispatched on the PR head |
| PR marked ready for review | nothing — flipping is the *result* of green, never a trigger | — |
| `merge_group` | every suite once more before landing | merge queue |
| push to `staging` / `main` | build / deploy workflows only | — |
| `workflow_dispatch` | any single suite, by hand | — |

`/ci` alone dispatches every listed suite; `/ci tests.yml` dispatches one. A
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
        uses: boonty-io/.github/.github/actions/ci-status@main
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
there; `merge_group` is supported natively. Heavy jobs use
`runs-on: ${{ inputs.runner == 'github' && 'ubuntu-latest' || '<blacksmith label>' }}`
so a runner-specific failure can be reproduced on the other pool.

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

Rulesets on `staging` and `main` (payload in `rulesets/`) require the suite
status contexts (`ci/tests`, `ci/build`, `ci/verify`), the four `gates/*` commit statuses posted by the ai-config gate
runner, one approving review, resolved conversations, an up-to-date branch,
and the merge queue. Draft PRs are unmergeable already. `gh pr ready` is
refused by the ai-config PreToolUse hook until every required context is
green on HEAD.
