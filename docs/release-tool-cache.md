# Release-tool installs: cache, retry, checksum

`.github/actions/install-release-tool` installs a pinned binary from a release tarball. On 2026-11-09, `github.com/<owner>/<repo>/releases/download/...` returned HTTP 504 on and off while `api.github.com` stayed up. Jobs that downloaded actionlint or gitleaks at run time failed before doing any work, for example webapp-admin#3035 (gitleaks) and ai-config#1522 (actionlint). The action makes such a job depend on the release CDN only when its cache has nothing.

## What the action does

- It restores the tarball from the Actions cache, under the key `release-tool-<name>-<version>-<sha256>`.
- On a miss, it downloads with `curl --retry 5 --retry-all-errors --retry-delay 10` and saves the tarball to the cache at once. A failed save is ignored.
- It checks the pinned sha256 on every run, cache hit included. A cached tarball that fails the check is downloaded again, never trusted.
- It installs the binary in `$RUNNER_TEMP/release-tools/bin`, outside the checkout, and puts that directory on `PATH`.

## Cache scope, and why consumers seed it

A run can restore only caches saved on its own ref or on the repository's default branch. A `pull_request` run can also restore caches saved on its base branch. Most Boonty suites run on `workflow_dispatch`, from `ci-request.yml`, on the PR branch itself. App work lands on `staging`, which is not the default branch. So, left alone, the first run on every new PR branch misses the cache, and if that run lands in an outage it fails exactly as before.

To avoid this, each consumer runs `templates/seed-release-tools.yml` on its default branch, daily and on manual dispatch. That keeps an entry every branch can read. The daily run also keeps the entry from being evicted after 7 days without use.

GitHub-hosted and Blacksmith runners keep separate caches, so a seeder's matrix lists every runner label that an install job uses.

A seeder's workflow file reaches the default branch only when the default branch does. On the app repositories, that means seeding starts with the first staging → main delivery after the seeder merges. Until then, the retries are the only protection on a cold cache.

## Not covered

- `actions/setup-*` tool-cache downloads, Gradle and Android SDK downloads, and container image pulls also depend on remote hosts. The action does not touch them.
- An outage longer than about a minute on a cold cache still fails the run.
- A red scheduled seeder run notifies only through GitHub's default workflow-failure email, which goes to whoever last changed the cron. A seeder that keeps failing leaves the cache cold without anyone noticing.

## Bumping a tool

Take the new sha256 from the `*_checksums.txt` asset of the same release, never from a tarball you downloaded yourself. Change the version, url and sha256 together, in the installing workflow and in the seeder. The seeder's drift check reads the seeder's own `url` and `sha256` inputs, and goes red when one of them appears in no other workflow of the repository.
