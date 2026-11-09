#!/usr/bin/env python3
"""Cases for scripts/on-demand-guard.py. Run: python3 test/on-demand-guard.test.py

Every case starts from GOOD (a consumer that follows docs/on-demand-ci.md),
applies one mutation, and asserts the guard refuses it with the rule's message.
A mutation that fails to apply is itself a failure, so a case can never pass
by testing the unmodified tree.
"""
import os, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "..", "scripts", "on-demand-guard.py")

REQUEST = """name: ci-request
on:
  pull_request:
    types: [labeled]
  issue_comment:
    types: [created]
permissions: {}
jobs:
  request:
    uses: boonty-io/.github/.github/workflows/ci-request.yml@main
    permissions:
      contents: read
      actions: write
      pull-requests: write
    with:
      workflows: tests.yml
      shared_ref: main
"""

SUITE = """name: tests
on:
  workflow_dispatch:
    inputs:
      pr: { required: false, type: string }
      base: { required: false, type: string }
      head_sha: { required: false, type: string }
  merge_group:
  push:
    branches: [staging, main]
permissions:
  contents: read
jobs:
  unit:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read
    steps:
      - uses: actions/checkout@0000000000000000000000000000000000000000
      - id: verify-request
        if: github.event_name == 'workflow_dispatch'
        uses: boonty-io/.github/.github/actions/verify-ci-request@main
        with:
          pr: ${{ inputs.pr }}
          base: ${{ inputs.base }}
          head_sha: ${{ inputs.head_sha }}
      - run: echo test
  guard:
    uses: boonty-io/.github/.github/workflows/on-demand-guard.yml@main
    with:
      shared_ref: main
  tests-complete:
    needs: [unit, guard]
    if: always()
    runs-on: ubuntu-latest
    permissions:
      statuses: write
    steps:
      - run: test "${{ needs.unit.result }}" = success
      - if: always()
        uses: boonty-io/.github/.github/actions/ci-status@main
        with:
          context: ci/tests
          job-status: ${{ job.status }}
          head-sha: ${{ inputs.head_sha }}
"""

OTHER = """name: lint-title
on:
  pull_request:
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
"""


def run(files):
    with tempfile.TemporaryDirectory() as d:
        wf = os.path.join(d, ".github", "workflows")
        os.makedirs(wf)
        for name, body in files.items():
            if body is not None:
                with open(os.path.join(wf, name), "w") as f:
                    f.write(body)
        p = subprocess.run([sys.executable, GUARD, d], capture_output=True, text=True)
        return p.returncode, p.stdout + p.stderr


def good():
    return {"ci-request.yml": REQUEST, "tests.yml": SUITE, "lint-title.yml": OTHER}


SHA = "0123456789abcdef0123456789abcdef01234567"


def sha_pinned():
    """GOOD as a caller pinned by commit: every boonty-io/.github reference at
    `@<sha> # main` (the form Dependabot keeps), no `shared_ref` input."""
    files = {}
    for name, body in good().items():
        body = body.replace("    with:\n      shared_ref: main\n", "").replace("      shared_ref: main\n", "")
        assert "shared_ref" not in body, name
        files[name] = body.replace("@main", f"@{SHA} # main")
    return files


def mutate(name, old, new):
    files = good()
    assert old in files[name], f"mutation did not apply: {old!r} not in {name}"
    files[name] = files[name].replace(old, new, 1)
    return files


class Guard(unittest.TestCase):
    def refuses(self, files, needle):
        code, out = run(files)
        self.assertEqual(code, 1, out)
        self.assertIn(needle, out)

    def test_good_consumer_passes_and_counts_its_suites(self):
        code, out = run(good())
        self.assertEqual(code, 0, out)
        self.assertIn("1 suite(s)", out)

    def test_no_request_workflow(self):
        files = good(); files["ci-request.yml"] = None
        self.refuses(files, "no .github/workflows/ci-request.yml")

    def test_request_not_calling_the_shared_workflow(self):
        self.refuses(mutate("ci-request.yml", "boonty-io/.github/.github/workflows/ci-request.yml@main", "./.github/workflows/x.yml"),
                     "does not call boonty-io/.github")

    def test_request_on_every_label_type(self):
        self.refuses(mutate("ci-request.yml", "types: [labeled]", "types: [labeled, synchronize]"),
                     "pull_request types must be exactly [labeled] or")

    HINT_JOB = """  hint:
    uses: boonty-io/.github/.github/workflows/ci-hint.yml@main
    permissions:
      contents: read
      pull-requests: read
      statuses: write
    with:
      contexts: ci/tests
"""

    def hinted(self, job=None):
        files = mutate("ci-request.yml", "types: [labeled]", "types: [labeled, opened, reopened, synchronize, ready_for_review]")
        files["ci-request.yml"] += self.HINT_JOB if job is None else job
        return files

    def test_request_with_hint_passes(self):
        code, out = run(self.hinted())
        self.assertEqual(code, 0, out)

    def test_hint_types_without_hint_job(self):
        self.refuses(self.hinted(""), "does not call ci-hint.yml")

    def test_hint_without_contexts(self):
        self.refuses(self.hinted(self.HINT_JOB.replace("      contexts: ci/tests\n", "      contexts: ''\n")), "with no `contexts`")

    def test_hint_without_statuses_write(self):
        self.refuses(self.hinted(self.HINT_JOB.replace("      statuses: write\n", "")), "lacks `statuses: write`")

    # The documented block, read from docs/on-demand-ci.md so the two cannot drift.
    with open(os.path.join(HERE, "..", "docs", "on-demand-ci.md")) as _f:
        _doc = _f.read()
    SPLIT = _doc[_doc.index("concurrency:\n  group: ci-request-"):]
    SPLIT = SPLIT[:SPLIT.index("\njobs:") + 1]

    def concurrent(self, block):
        files = self.hinted()
        assert "permissions: {}\n" in files["ci-request.yml"]
        files["ci-request.yml"] = files["ci-request.yml"].replace("permissions: {}\n", block + "permissions: {}\n", 1)
        return files

    def test_hint_with_split_concurrency_passes(self):
        code, out = run(self.concurrent(self.SPLIT))
        self.assertEqual(code, 0, out)

    def test_hint_with_one_concurrency_group(self):
        self.refuses(self.concurrent("concurrency:\n  group: ci-request-${{ github.event.pull_request.number }}\n"),
                     "one concurrency group for hints and requests")

    def test_hint_with_unconditional_cancel(self):
        cancel = next(l for l in self.SPLIT.splitlines() if l.startswith("  cancel-in-progress:"))
        for bad in ("true", "'true'", "${{ true }}"):
            self.refuses(self.concurrent(self.SPLIT.replace(cancel, "  cancel-in-progress: " + bad)), "cancels a pending request")

    def test_hint_with_string_concurrency(self):
        self.refuses(self.concurrent("concurrency: ci-request-${{ github.event.pull_request.number }}\n"),
                     "one concurrency group for hints and requests")

    def test_hint_with_one_job_level_concurrency_group(self):
        files = self.hinted()
        files["ci-request.yml"] = files["ci-request.yml"].replace(
            "  request:\n", "  request:\n    concurrency: ci-request-${{ github.event.pull_request.number }}\n", 1)
        self.refuses(files, "one concurrency group for hints and requests")

    def test_hint_with_permissions_shorthand(self):
        self.refuses(self.hinted(self.HINT_JOB.replace(
            "    permissions:\n      contents: read\n      pull-requests: read\n      statuses: write\n",
            "    permissions: write-all\n")), "the ci-hint.yml job must list its permissions")

    def test_hint_without_read_scopes(self):
        self.refuses(self.hinted(self.HINT_JOB.replace("      pull-requests: read\n", "")), "lacks `pull-requests: read`")
        self.refuses(self.hinted(self.HINT_JOB.replace("      contents: read\n", "")), "lacks `contents: read`")

    def test_hint_job_with_label_only_types(self):
        files = good(); files["ci-request.yml"] += self.HINT_JOB
        self.refuses(files, "calls ci-hint.yml but pull_request types are not")

    def test_empty_suite_list(self):
        self.refuses(mutate("ci-request.yml", "workflows: tests.yml", "workflows: ''"), "lists no suite")

    def test_listed_suite_missing(self):
        self.refuses(mutate("ci-request.yml", "workflows: tests.yml", "workflows: tests.yml,gone.yml"),
                     "gone.yml: listed in ci-request.yml but does not exist")

    def test_suite_back_on_pull_request(self):
        self.refuses(mutate("tests.yml", "  merge_group:\n", "  merge_group:\n  pull_request:\n"),
                     "tests.yml: runs on pull_request")

    def test_suite_on_pull_request_target(self):
        self.refuses(mutate("tests.yml", "  merge_group:\n", "  merge_group:\n  pull_request_target:\n"),
                     "tests.yml: runs on pull_request_target")

    def test_suite_on_every_push(self):
        self.refuses(mutate("tests.yml", "  push:\n    branches: [staging, main]\n", "  push:\n"),
                     "tests.yml: push trigger must name long-lived branches only")

    def test_suite_on_wildcard_push(self):
        self.refuses(mutate("tests.yml", "branches: [staging, main]", "branches: ['**']"),
                     "tests.yml: push trigger must name long-lived branches only")

    def test_suite_missing_dispatch_input(self):
        self.refuses(mutate("tests.yml", "      head_sha: { required: false, type: string }\n", ""),
                     "tests.yml: workflow_dispatch must declare inputs base, head_sha, pr")

    def test_suite_missing_merge_group(self):
        self.refuses(mutate("tests.yml", "  merge_group:\n", ""), "tests.yml: no merge_group trigger")

    def test_suite_without_verify(self):
        self.refuses(mutate("tests.yml", "verify-ci-request@main", "something-else@main"),
                     "tests.yml: no verify-ci-request step")

    def test_verify_not_limited_to_dispatch(self):
        self.refuses(mutate("tests.yml", "        if: github.event_name == 'workflow_dispatch'\n", ""),
                     "tests.yml: verify-ci-request step must be guarded by `if: github.event_name == 'workflow_dispatch'`")

    def test_verify_job_cannot_read_prs(self):
        self.refuses(mutate("tests.yml", "      pull-requests: read\n", ""),
                     "tests.yml: job `unit` uses verify-ci-request without pull-requests: read")

    def test_verify_before_checkout(self):
        files = mutate("tests.yml", "      - uses: actions/checkout@0000000000000000000000000000000000000000\n", "")
        files["tests.yml"] = files["tests.yml"].replace("      - run: echo test\n",
            "      - uses: actions/checkout@0000000000000000000000000000000000000000\n      - run: echo test\n", 1)
        self.refuses(files, "tests.yml: job `unit` runs verify-ci-request before actions/checkout")

    def test_suite_without_status(self):
        self.refuses(mutate("tests.yml", "ci-status@main", "other@main"), "tests.yml: no ci-status step")

    def test_status_not_always(self):
        self.refuses(mutate("tests.yml", "      - if: always()\n        uses: boonty-io", "      - uses: boonty-io"),
                     "tests.yml: ci-status step must run `if: always()`")

    def test_status_job_cannot_write_statuses(self):
        self.refuses(mutate("tests.yml", "      statuses: write\n", "      contents: read\n"),
                     "tests.yml: job `tests-complete` uses ci-status without statuses: write")

    def test_status_poster_not_listed(self):
        files = good(); files["orphan.yml"] = SUITE.replace("ci/tests", "ci/orphan")
        self.refuses(files, "orphan.yml: posts a ci-status but is not listed in ci-request.yml")

    def test_sha_pinned_caller_without_shared_ref(self):
        code, out = run(sha_pinned())
        self.assertEqual(code, 0, out)

    def test_sha_pinned_trailing_comment_is_not_part_of_the_ref(self):
        files = sha_pinned()
        old = f"ci-status@{SHA} # main"
        assert old in files["tests.yml"], "mutation did not apply"
        files["tests.yml"] = files["tests.yml"].replace(old, f"ci-status@{SHA}  # pinned by Dependabot", 1)
        code, out = run(files)
        self.assertEqual(code, 0, out)

    def test_sha_pinned_caller_with_one_ref_left_on_main(self):
        files = sha_pinned()
        old = f"ci-status@{SHA} # main"
        assert old in files["tests.yml"], "mutation did not apply"
        files["tests.yml"] = files["tests.yml"].replace(old, "ci-status@main", 1)
        self.refuses(files, "boonty-io/.github is referenced at more than one ref")

    def test_mixed_shared_refs(self):
        self.refuses(mutate("tests.yml", "ci-status@main", "ci-status@feat/x"),
                     "boonty-io/.github is referenced at more than one ref")

    def test_shared_ref_input_disagrees(self):
        self.refuses(mutate("ci-request.yml", "shared_ref: main", "shared_ref: feat/x"),
                     "boonty-io/.github is referenced at more than one ref")

    def test_suite_chained_by_workflow_run(self):
        self.refuses(mutate("tests.yml", "  merge_group:\n", "  merge_group:\n  workflow_run:\n    workflows: [lint-title]\n"),
                     "tests.yml: runs on workflow_run")

    def test_verify_guarded_by_negated_dispatch(self):
        self.refuses(mutate("tests.yml", "if: github.event_name == 'workflow_dispatch'", "if: github.event_name != 'workflow_dispatch'"),
                     "tests.yml: verify-ci-request step must be guarded by `if: github.event_name == 'workflow_dispatch'`")

    def test_status_negated_always(self):
        self.refuses(mutate("tests.yml", "      - if: always()\n        uses: boonty-io", "      - if: ${{ !always() }}\n        uses: boonty-io"),
                     "tests.yml: ci-status step must run `if: always()`")

    def test_guard_not_called(self):
        files = mutate("tests.yml", "  guard:\n    uses: boonty-io/.github/.github/workflows/on-demand-guard.yml@main\n    with:\n      shared_ref: main\n", "")
        files["tests.yml"] = files["tests.yml"].replace("needs: [unit, guard]", "needs: [unit]")
        self.refuses(files, "no suite calls boonty-io/.github/.github/workflows/on-demand-guard.yml")

    def test_guard_shared_ref_disagrees(self):
        self.refuses(mutate("tests.yml", "      shared_ref: main\n", "      shared_ref: feat/x\n"),
                     "boonty-io/.github is referenced at more than one ref")

    def test_tags_only_push_and_scalar_branch_are_fine(self):
        code, out = run(mutate("tests.yml", "    branches: [staging, main]\n", "    tags: ['v*']\n"))
        self.assertEqual(code, 0, out)
        code, out = run(mutate("tests.yml", "branches: [staging, main]", "branches: main"))
        self.assertEqual(code, 0, out)

    def test_read_all_grants_pull_request_read(self):
        code, out = run(mutate("tests.yml", "    permissions:\n      contents: read\n      pull-requests: read\n", "    permissions: read-all\n"))
        self.assertEqual(code, 0, out)

    def test_reusable_suite_is_followed(self):
        files = good()
        impl = SUITE.replace("""on:
  workflow_dispatch:
    inputs:
      pr: { required: false, type: string }
      base: { required: false, type: string }
      head_sha: { required: false, type: string }
  merge_group:
  push:
    branches: [staging, main]
""", "on:\n  workflow_call:\n")
        assert impl != SUITE
        files["_impl.yml"] = impl
        files["tests.yml"] = SUITE.split("jobs:")[0] + "jobs:\n  run:\n    uses: ./.github/workflows/_impl.yml\n    secrets: inherit\n"
        code, out = run(files)
        self.assertEqual(code, 0, out)


if __name__ == "__main__":
    unittest.main(verbosity=1)
