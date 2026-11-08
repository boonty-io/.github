# Merge by GitHub

A pull request merges itself once it is reviewed, gated and green. No session
has to stay alive for it, and nobody has to reach the queue orchestrator.

## The flow

1. The session runs the four Phase 5 gates as today, then
   `boonty-ai gate publish`. That posts, or updates, one PR comment that
   starts with `boonty-gates/v1`. The comment carries the head sha, the base,
   the content hash of the diff (`content_sha256`, from
   `scripts/gate-content-hash.sh`) and the four verdicts.
2. The session marks the PR ready and enables auto-merge
   (`gh pr merge --auto --squash`, or the repository's usual method).
3. `gates-verify` runs on the comment and on every new head. It posts
   `gates/verified`:
   - `success` when the last-written receipt from someone with write, maintain
     or admin permission on the repository shows 4/4 `pass`, against the PR's
     current base, for the exact diff the head carries;
   - `failure` when a gate did not pass, the PR was retargeted, or any byte of
     the diff changed since the gates ran (whitespace included);
   - `pending` when no receipt exists yet.
4. Ready PRs run their `ci/*` suites on every new head (`docs/on-demand-ci.md`).
5. GitHub merges once every required check is green, plus the approval where
   the ruleset requires one.

**When the base moves.** `gh pr update-branch --rebase` gives the PR a new
head. Its CI re-runs on its own. `gates/verified` stays green when the base
moved only on files the diff does not touch: every diffed file then has the
same two blob ids, so the hash is identical. If the base touched a file the
diff touches, the hash changes, the status turns red and the gates must run
again. This is close to the local patch-receipt rule but weaker in one way:
locally `claim-verifier` re-runs even on a disjoint base move, here nothing
re-runs.

**The hash.** Both sides run `scripts/gate-content-hash.sh` (ai-config's
`gate publish` runs the same command): the sha256 of
`git diff-tree -r -z --full-index --no-renames` over merge-base..head, that is
each diffed file's modes, full blob ids, status and path. Nothing is rendered
as text, so no diff option, git config, attribute or `GIT_DIFF_OPTS` can make
a developer's receipt unmatchable. Unlike `git patch-id --stable`, it does not
ignore whitespace.

**Trust.** The receipt is as trustworthy as today's local receipt files: a
person with write access could forge either. What changes is where it is
checked: from the default branch's workflow, against the diff and base the PR
has when the check runs. The ruleset pins the context to GitHub Actions
(integration 15368). That stops a personal token or another App from posting
it, but not another workflow: anyone who can push a branch can add a workflow
that posts `gates/verified` with its own `GITHUB_TOKEN`. That is the same
trust level as forging a receipt, not a stronger one.

**Learnings PRs.** ai-config's learnings PRs (opened by `/close`) merge without
the four gates by rule, so they publish no receipt. With no writer's receipt
on the PR, `gates/verified` is `success` for such a PR when all of these hold,
read off the API and tied to the head the run checks:

- the repository is `boonty-io/ai-config`, the base is `main` and the head is
  a branch of that repository, not a fork;
- the title starts with `docs(shared-learnings): `;
- the file list is complete: its length equals GitHub's `changedFiles`, since
  the files endpoint stops at 3000;
- every path, and every path a file was renamed from, is one `.md` file
  directly under `shared-learnings/`, with no newline in it.

This is stricter than ai-config's own `auto-merge-eligible.sh`, which also
admits `docs:`/`chore:` titles and `shared/31-security-baseline.md`. A writer's
receipt on the PR always wins over the exemption. A failing receipt left on a
learnings PR keeps it red: delete that comment to fall back to the exemption.
The files endpoint reports paths, not file modes, so a symbolic link named
`shared-learnings/x.md` would match too. That needs write access and adds
nothing over the trust level above.

**Where it is required.** Require `gates/verified` on each repository's
integration branch only (`staging`; `main` for ai-config, this repository and
pos-android-e2e_autotests; `develop` for pos-app-android). Never require it
on a `main` that a `staging`→`main` delivery PR feeds: there is no delivery
exemption, so the delivery PR would wait forever. A consequence, by design:
hotfix PRs into such a `main` are not held by this check.

## Enabling it in a repository

1. Add `.github/workflows/gates-verify.yml`:

   ```yaml
   name: gates-verify
   on:
     pull_request_target:
       types: [opened, reopened, synchronize, ready_for_review, edited]
     issue_comment:
       types: [created, edited]
   permissions: {}
   concurrency:
     # A comment that is not a receipt gets a group of its own, so it can never
     # cancel the run of a new head and then skip its own job.
     group: gates-verify-${{ github.event.pull_request.number || github.event.issue.number }}-${{ (github.event_name == 'issue_comment' && !startsWith(github.event.comment.body, 'boonty-gates/v1')) && github.run_id || 'verify' }}
     cancel-in-progress: true
   jobs:
     verify:
       if: github.event_name == 'pull_request_target' || (github.event.issue.pull_request && startsWith(github.event.comment.body, 'boonty-gates/v1'))
       uses: boonty-io/.github/.github/workflows/gates-verify.yml@main
       permissions: { contents: read, pull-requests: read, statuses: write }
   ```

   `issue_comment` and `pull_request_target` run from the default branch, so
   the caller takes effect once it is on `main`.
2. In `rulesets/repos/<repo>.json`, add
   `{"context": "gates/verified", "integration_id": 15368}` to the required
   checks of the integration branch only ("Where it is required" above). Do
   it after step 1 has reached `main`, or every PR waits on a status nobody
   posts.
3. Turn on Settings → General → **Allow auto-merge**.

## What the queue orchestrator still does

It is no longer on the merge path. It keeps the cross-PR view: overlaps, merge
order between dependent PRs, stale drafts. A dependent PR stays draft until
the PR it depends on has merged, so auto-merge cannot land the two in the
wrong order.
