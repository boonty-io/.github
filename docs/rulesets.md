# Rulesets as code

Each repository's own rulesets are described in `rulesets/repos/<repo>.json`.
A merge to `main` applies them. Nobody edits a ruleset in the GitHub UI or with
a personal `gh api -X PUT` any more.

## How a change goes

1. Edit `rulesets/repos/<repo>.json`. To start a new repository's file:
   `scripts/rulesets.sh export boonty-io/<repo> > rulesets/repos/<repo>.json`.
2. Open a PR. The `rulesets` workflow runs `plan` and writes the diff against
   the live rulesets in its job summary.
3. Merge. The workflow runs `apply`: rulesets named in the file are created or
   updated to match. A live ruleset that no file names is reported
   `unmanaged` and left alone. Nothing is ever deleted.
4. Every day at 05:23 UTC, `plan` runs again. The run turns red when a live
   ruleset no longer matches its file (someone edited it by hand). Fix the
   file, or re-apply with `workflow_dispatch` in `apply` mode.

Organization rulesets and classic branch protection (still used by
`pos-app-android`) are outside this mechanism.

`scripts/rulesets.sh` is tested by `test/rulesets.test.sh` against a stub
`gh`. A failed read of a repository's rulesets stops the run before any write
to that repository, so a GitHub error can never look like "no rulesets" and
trigger a re-create. Repositories earlier in the run may already have been
applied; re-running converges, since an unchanged ruleset is left alone.

## One-time setup (an org owner)

1. Create a GitHub App owned by `boonty-io`, for example `boonty-rulesets`:
   - Repository permissions: **Administration: Read and write**,
     **Metadata: Read-only**. Nothing else.
   - No webhook, and installable only on this account.
2. Install it on **All repositories** of `boonty-io`.
3. In `boonty-io/.github` → Settings → Environments, create `rulesets` and
   add its secrets:
   - `RULESETS_APP_ID`: the App ID.
   - `RULESETS_APP_PRIVATE_KEY`: a private key generated for the App.

   Under **Deployment branches and tags**, choose *Selected branches* and
   allow `main` only. PR plans still work: they run with
   `pull_request_target`, which runs `main`'s workflow and script and takes
   only the PR's `rulesets/repos/*.json` as data, with a read-only token. A
   workflow edited on a branch cannot reach the key.
4. Run the `rulesets` workflow by hand in `plan` mode. It must report every
   ruleset `unchanged`.

The App's write token can change any ruleset in the org. Its key lives only
in the `rulesets` environment of this repository, which only `main` can use,
and `main` is itself protected (`rulesets/repos/.github.json`: PR, one
approval, required checks). A PR plan asks the App for Administration: read
only; every other run (apply, the daily plan, a dispatch, all from `main`)
asks for write. GitHub shows a ruleset's bypass actors only to a token that
can write it, so a PR plan leaves bypass actors out of the comparison
(`RULESETS_SKIP_BYPASS=1`, which `apply` refuses) and says so in its output;
the daily plan compares them. `plan` never writes, whatever its token.
