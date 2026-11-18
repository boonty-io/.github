<!-- claude-projects-attribution: {"github_login":"Othella"} -->
_Requested by **Boonty** · [project thread](https://claude.ai/code/project/chan_01YTZD1Ss2tmGA7wU3YW3MUH?thread=cmsg_01YTZD1Ss2tmGA7wU3YW3MUH54VhuquiQ4nPfy6kRgtDDW)_

Step 3 of boonty-io/ai-config#1684. A draft PR carries exactly one label that says where its work stands: `pr:test`, `pr:implementation`, `pr:gates`, `pr:ci` or `pr:blocked`. The label follows line 1 of the PR's `boonty-plan/v1` plan comment, which `boonty-ai plan publish` writes (boonty-io/ai-config#1685). Sessions never set the label. Out of draft, closed or merged, the PR carries no `pr:*` label, because GitHub's own state takes over.

## Changes

- `.github/workflows/pr-status.yml` (reusable): one job, with per-PR concurrency and the `runs_on` input (default `"ubuntu-latest"`; the minis via `'["self-hosted","deskmini"]'`). It checks out only this repository, at `job.workflow_sha`, for the two scripts, and never checks out PR code.
- `scripts/pr-status.sh`: does the live reads. It fetches the PR (state, draft) and its comments, then takes the newest-updated plan comment whose author has admin, maintain or write permission. Permission comes from the collaborators API, never from `author_association`, and an author whose login is not GitHub-shaped is never looked up. It adds the wanted label first (creating it when missing), then removes every other `pr:*` label. Labels are written with `GITHUB_TOKEN`, whose events start no workflow, so a label write never triggers `ci-request`.
- `scripts/pr-status-decide.sh`: the pure decision. Input arrives through environment variables only. It reads line 1 only: at most 256 characters, the exact marker shape, a `phase` and a `status` from fixed lists. Anything else means no label.
- `templates/pr-status.yml`: the caller. It runs on `issue_comment` `created` and `edited`, with a job-level `if:` that requires `github.event.issue.pull_request` and a body starting with the marker, so every other comment bills nothing. It also runs on `pull_request_target` `ready_for_review`, `converted_to_draft` and `closed`.
- `docs/pr-status.md`, plus both tests wired into `ci.yml`.

Rollout: after this merges, one caller PR per repo (8 repos) pins its merged commit. `pr:*` is added to ai-config's `issue labels` list. The job creates a missing label itself, so caller order does not matter.

## Mutation checks

Each arm edits one line of a script, runs the listed test, and restores the file from a copy (the restore is asserted byte for byte):

| arm | mutation | result |
| --- | --- | --- |
| B1 | draft check off (`true \|\| out`) | killed: decide 18/20, pr-status 10/11 |
| B2 | the 256-char cap off | killed: decide 19/20 |
| B3 | any phase accepted | killed: decide 17/20 |
| B4 | status allow-list off | killed: decide 19/20 |
| B5 | every login counts as a writer | killed: pr-status 10/11 |
| B6 | oldest comment first | killed: pr-status 10/11 |
| B7 | the removal loop also drops the wanted label | killed: pr-status 10/11 |
| B8 | login shape check off | killed: pr-status 10/11 |

Every existing `test/*.test.sh` and `test/on-demand-guard.test.py` passes on this head.

## Plan artifact

not published — the plan is the `boonty-plan/v1` comment on boonty-io/ai-config#1684.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

<!-- codesmith:footer -->
---
<a href="https://backend.blacksmith.sh/track/enable-autofix?expires=1797551937&installation_model_id=432014&pr_number=54&ref=codesmith_pr_footer&repository=boonty-io%2F.github&return_to=https%3A%2F%2Fgithub.com%2Fboonty-io%2F.github%2Fpull%2F54&signature=74b5670eb4277e4ac3bb18dc796dfa214f8a2de0b5ae4a8ca206db1da1bec4df"><picture><source media="(prefers-color-scheme: dark)" srcset="https://pr-comments-assets.blacksmith.sh/codesmith/autofix-with-codesmith-dark.svg"><source media="(prefers-color-scheme: light)" srcset="https://pr-comments-assets.blacksmith.sh/codesmith/autofix-with-codesmith-light.svg"><img alt="Autofix with [code]smith" src="https://pr-comments-assets.blacksmith.sh/codesmith/autofix-with-codesmith-dark-3x.png" width="190" height="28"></picture></a>
<sup><a href="https://app.blacksmith.sh/boonty-io/codesmith/.github/pr/54?autoLogin=true&ref=codesmith_pr_footer">Open in [code]smith</a> · Need help on this PR? Tag <code>@codesmith-bot</code> with what you need.</sup>

<!-- codesmith:autofix:disabled -->
<!-- /codesmith:footer -->
