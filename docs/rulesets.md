# Rulesets as code

Each repository's own rulesets are described in `rulesets/repos/<repo>.json`.
A merge to `main` applies them. Nobody edits a ruleset in the GitHub UI or with
a personal `gh api -X PUT` any more.

## How a change goes

1. Edit `rulesets/repos/<repo>.json`. To start a new repository's file:
   `scripts/rulesets.sh export boonty-io/<repo> > rulesets/repos/<repo>.json`.
2. Open a PR. The `rulesets` workflow runs `plan` and writes the diff against
   the live rulesets in its job summary. The plan fails if the PR's head has
   no `rulesets/repos` or no `rulesets/environments`: it never plans a PR
   against `main`'s files instead. Rebase a branch older than either
   directory. A file name (the repository) or an environment name outside
   `[A-Za-z0-9._-]`, or one that is `.` or `..`, is refused before any call.
3. Merge. Once a reviewer of the `rulesets` environment (Othella or
   HugoSudefou) approves the run, the workflow runs `apply`: rulesets named in
   the file are created or updated to match. A live ruleset that no file names
   is reported `unmanaged` and left alone. Nothing is ever deleted.
4. Every day at 05:23 UTC, `plan` runs again. The run turns red when a live
   ruleset no longer matches its file (someone edited it by hand). Fix the
   file, or re-apply with `workflow_dispatch` in `apply` mode.

A branch's merge queue is a `merge_queue` rule in the same file, with
`strict_required_status_checks_policy: false` beside it
(`docs/merge-queue.md`). It is applied and compared like any other rule.

Organization rulesets and classic branch protection (still used by
`pos-app-android` `main`) are outside this mechanism. `pos-app-android`
`develop` moves from classic protection to `rulesets/repos/pos-app-android.json`.
Once that ruleset has applied and a first queue entry has landed, an admin
removes `develop`'s classic protection: until then, its strict setting still
applies.

`scripts/rulesets.sh` is tested by `test/rulesets.test.sh` against a stub
`gh`. A failed read of a repository's rulesets stops the run before any write
to that repository, so a GitHub error can never look like "no rulesets" and
trigger a re-create. Repositories earlier in the run may already have been
applied; re-running converges, since an unchanged ruleset is left alone.

## Environment protection

`rulesets/environments/.github.json` describes the two deployment environments
of this repository that hold the App keys: their reviewers, their deployment
branch policy (`main` only), `prevent_self_review` and `can_admins_bypass`.
Every plan (PR, daily, dispatch) compares it with the live environments
(`scripts/environments.sh plan`, tested in `test/rulesets.test.sh`) and exits
2 on drift: a notice on a PR, a red run on the schedule.

Nothing applies this file, `apply` included. These environments guard the
keys `apply` itself uses, so a change to them is made by an owner in
Settings → Environments, and the file is updated in the same PR. The
comparison only proves the two still agree.

| Environment     | Used by                          | App, permission                              | Reviewers               | Branches |
| --------------- | -------------------------------- | -------------------------------------------- | ----------------------- | -------- |
| `rulesets-plan` | every plan: PR, schedule, dispatch `plan` | `boonty-rulesets-read`, Administration: read | none                    | `main`   |
| `rulesets`      | apply only: push to `main`, dispatch `apply` | `boonty-rulesets`, Administration: read and write | Othella, HugoSudefou | `main`   |

A plan never waits for a reviewer, and the write key is used only by an
apply a reviewer approved. Reading an environment needs only read access to
this repository, which is public, so the read App needs no permission beyond
Administration: read and Metadata: read. `can_admins_bypass` is `true` on both, as live
today: a repository admin can still deploy to `rulesets` without a review.

### Bypass actors: the tradeoff

GitHub shows a ruleset's bypass actors only to a token that can write it.
Every plan now runs with the read-only App, so every plan leaves bypass
actors out of the comparison (`RULESETS_SKIP_BYPASS=1`) and says so. Before
this split the daily plan used the write key and caught a bypass actor edited
by hand. That check is given up, so that the write key never runs
unreviewed. An apply still compares bypass actors and re-asserts them for
every ruleset it updates: to check them, dispatch the workflow in `apply`
mode and have a reviewer approve it. A bypass actor that drifted on a ruleset
whose other fields match stays undetected until such an apply.

## One-time setup (an org owner)

1. Create a GitHub App owned by `boonty-io`, for example `boonty-rulesets`:
   - Repository permissions: **Administration: Read and write**,
     **Metadata: Read-only**. Nothing else.
   - No webhook, and installable only on this account.
2. Create a second App, `boonty-rulesets-read`: the same, but
   **Administration: Read-only**. It is the only key a plan can reach.
3. Install both on **All repositories** of `boonty-io`.
4. In `boonty-io/.github` → Settings → Environments, create `rulesets`:
   - Secrets `RULESETS_APP_ID` (the write App's ID) and
     `RULESETS_APP_PRIVATE_KEY` (a private key generated for it).
   - **Required reviewers**: Othella and HugoSudefou.
   - **Deployment branches and tags**: *Selected branches*, `main` only.
5. Create `rulesets-plan`:
   - Secrets `RULESETS_PLAN_APP_ID` and `RULESETS_PLAN_APP_PRIVATE_KEY`, for
     the read App.
   - No reviewer.
   - **Deployment branches and tags**: *Selected branches*, `main` only.

   Do this before merging a workflow that names `rulesets-plan`: GitHub
   creates a missing environment on first use, with no secrets and no
   branch policy, and every plan then fails.

   PR plans still run with `main` as their ref: they use
   `pull_request_target`, which runs `main`'s workflow and scripts and takes
   only the PR's `rulesets/repos/*.json` and `rulesets/environments/*.json`
   as data. A workflow edited on a branch cannot reach either key.
6. Run the `rulesets` workflow by hand in `plan` mode. It must report every
   ruleset and both environments `unchanged`.

The write App's token can change any ruleset in the org. Its key lives only
in the `rulesets` environment of this repository, which only `main` can use,
behind a required reviewer, and `main` is itself protected
(`rulesets/repos/.github.json`: PR with no required approval, required
checks, admin bypass only through a PR). `plan` never writes, whatever its
token.
