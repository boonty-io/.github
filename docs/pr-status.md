# Draft PR status labels (`pr-status.yml`)

A draft PR carries exactly one label that says where its work stands: `pr:test`, `pr:implementation`, `pr:gates`, `pr:ci` or `pr:blocked`. The label follows the `phase` on line 1 of the PR's plan comment, the `boonty-plan/v1` comment that `boonty-ai plan publish` writes (ai-config `shared/48-plan-artifact.md`). Sessions never set the label: they publish the plan, and `boonty-ai gate check` and `gate publish` move the phase to `gates` and `ci` on their own.

Out of draft, closed or merged, a PR carries no `pr:*` label. GitHub's own ready, queue and merged state says it better. Converted back to draft, the label comes back from the plan.

The `pr:` namespace is separate from the `ai:*` labels. Those are issue claim steps (ai-config `shared/49-issue-claims.md`), and the batches page counts them per issue.

## Wiring

Copy [`templates/pr-status.yml`](../templates/pr-status.yml) into the repo's `.github/workflows/` and pin the `uses:` commit. It runs on:

- `issue_comment` `created` and `edited`, only for a PR comment that starts with `<!-- boonty-plan/v1 `. The job-level `if:` skips every other comment, so they bill nothing;
- `pull_request_target` `ready_for_review`, `converted_to_draft` and `closed`.

`runs_on` picks the runner. It is a JSON string or array and defaults to `"ubuntu-latest"`. Pass `'["self-hosted","deskmini"]'` to run on the minis.

A missing `pr:*` label is created on first use, so the caller does not depend on `boonty-ai issue labels --apply` having run.

## Why it can be trusted

- **Nothing from the event decides.** [`scripts/pr-status.sh`](../scripts/pr-status.sh) reads the PR (open or closed, draft or not) and its comments live. It takes the newest-updated plan comment whose author has admin, maintain or write permission on the repository. The permission comes from the collaborators API, never from `author_association`.
- **Line 1 only, strictly.** [`scripts/pr-status-decide.sh`](../scripts/pr-status-decide.sh) accepts at most 256 characters in the exact marker shape. The JSON must hold a `phase` and a `status` from fixed lists. Anything else means no label.
- **No PR code runs.** The only checkout is this repository, at the workflow's own commit, and only for the two scripts. Values reach them through `env:`.
- **Permissions.** The job needs `issues: write` (to create a missing `pr:*` label) and `pull-requests: write`: adding a label to a PR with `issues: write` alone is refused with HTTP 403. A caller grants both, since a reusable workflow gets no more than its caller grants.
- **No cascade.** Labels are written with the job's `GITHUB_TOKEN`, and events from that token start no workflow. A label write never triggers `ci-request`.
- **One run at a time per PR.** A run that waits reads the PR as it is when it starts, so the last run leaves the right label. The wanted label is added before the others are removed, so a crash leaves two labels, never zero.

Tests: `test/pr-status-decide.test.sh` covers the decision table and `test/pr-status.test.sh` covers the live reads and label writes against a fake `gh`.
