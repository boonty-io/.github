#!/usr/bin/env python3
"""on-demand-guard — refuse a consumer whose workflows break docs/on-demand-ci.md.

    python3 scripts/on-demand-guard.py <path to the consumer checkout>

Exit 0 and print the suite count when the contract holds; exit 1 with one
`✗ <file>: <rule>` line per breach otherwise.

Why it exists: the contract is only worth its saving while no suite quietly
goes back to `pull_request`. One re-added trigger is a full suite on every push
to every draft, and nothing else in CI would notice — the run would be green.
The rules below are the ones whose breach either spends minutes again or turns
a required context green without running it (see the doc's "Why dispatch").
"""
import os, re, sys

import yaml

SHARED = "boonty-io/.github/"
# The opt-in trigger set: labeled (request), ready_for_review / opened (auto-run
# when ready), reopened / synchronize (the "how to run CI" hint).
HINT_TYPES = ["labeled", "opened", "reopened", "synchronize", "ready_for_review"]
LONG_LIVED = {"main", "master", "staging", "develop"}
DISPATCH_INPUTS = {"pr", "base", "head_sha"}


def triggers(doc):
    on = doc.get("on", doc.get(True))  # PyYAML reads a bare `on:` key as True
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return {k: None for k in on}
    return on or {}


def steps_by_job(doc):
    for name, job in (doc.get("jobs") or {}).items():
        yield name, job or {}, (job or {}).get("steps") or []


def grants(doc, job, scope, levels):
    # A job-level `permissions` block replaces the workflow-level one entirely.
    perms = job["permissions"] if "permissions" in job else doc.get("permissions")
    if perms == "write-all":
        return True
    if perms == "read-all":
        return "read" in levels
    return isinstance(perms, dict) and perms.get(scope) in levels


DISPATCH_IF = re.compile(r"^\s*(\$\{\{\s*)?github\.event_name\s*==\s*'workflow_dispatch'(\s*\}\})?\s*$")
ALWAYS_IF = re.compile(r"(?<!!)\balways\(\)")
GUARD_WF = f"{SHARED}.github/workflows/on-demand-guard.yml@"


def local_calls(job):
    """`uses: ./.github/workflows/x.yml` on a job → 'x.yml', else None."""
    u = str(job.get("uses", ""))
    m = re.fullmatch(r"\./\.github/workflows/([\w.-]+\.ya?ml)", u)
    return m.group(1) if m else None


def uses_action(step, name):
    u = str(step.get("uses", ""))
    return u.startswith(f"{SHARED}.github/actions/{name}@") or u == f"./.github/actions/{name}"


def main(root):
    wf_dir = os.path.join(root, ".github", "workflows")
    errors, refs = [], set()

    def err(f, msg):
        errors.append(f"✗ {f}: {msg}")

    docs = {}
    for f in sorted(os.listdir(wf_dir)) if os.path.isdir(wf_dir) else []:
        if f.endswith((".yml", ".yaml")):
            with open(os.path.join(wf_dir, f)) as fh:
                text = fh.read()
            docs[f] = yaml.safe_load(text) or {}
            refs.update(re.findall(re.escape(SHARED) + r"\.github/(?:workflows|actions)/[\w.-]+@([^\s'\"]+)", text))

    req = docs.get("ci-request.yml")
    if req is None:
        print("✗ no .github/workflows/ci-request.yml — this repository has no on-demand CI entry point")
        return 1

    on = triggers(req)
    if set(on) != {"pull_request", "issue_comment"}:
        err("ci-request.yml", f"must trigger on exactly pull_request and issue_comment, got {sorted(map(str, on))}")
    pr_types = (on.get("pull_request") or {}).get("types")
    if pr_types not in (["labeled"], HINT_TYPES):
        err("ci-request.yml", f"pull_request types must be exactly [labeled] or {HINT_TYPES}")
    if (on.get("issue_comment") or {}).get("types") != ["created"]:
        err("ci-request.yml", "issue_comment types must be exactly [created]")

    callers = [j for j in (req.get("jobs") or {}).values()
               if str((j or {}).get("uses", "")).startswith(f"{SHARED}.github/workflows/ci-request.yml@")]
    if len(callers) != 1:
        err("ci-request.yml", "does not call boonty-io/.github/.github/workflows/ci-request.yml (exactly once)")
        suites = []
    else:
        w = callers[0].get("with") or {}
        suites = [s.strip() for s in str(w.get("workflows") or "").split(",") if s.strip()]
        if "shared_ref" in w:
            refs.add(str(w["shared_ref"]))
        if not suites:
            err("ci-request.yml", "lists no suite in `workflows`")
        hints = [j for j in (req.get("jobs") or {}).values()
                 if str((j or {}).get("uses", "")).startswith(f"{SHARED}.github/workflows/ci-hint.yml@")]
        if pr_types == HINT_TYPES:
            if len(hints) != 1:
                err("ci-request.yml", "triggers on new heads but does not call ci-hint.yml (exactly once)")
            else:
                if not str((hints[0].get("with") or {}).get("contexts") or "").strip():
                    err("ci-request.yml", "calls ci-hint.yml with no `contexts` — the hint would post nothing")
                hperms = hints[0].get("permissions") or {}
                for scope, level in (("statuses", "write"), ("contents", "read"), ("pull-requests", "read")):
                    if hperms.get(scope) != level:
                        err("ci-request.yml", f"the ci-hint.yml job lacks `{scope}: {level}`")
            # A group keeps one pending run: a hint (every push) sharing the
            # request's group would replace a queued request (docs, "Opt-in").
            conc = req.get("concurrency")
            if conc is not None:
                group = str(conc.get("group", "")) if isinstance(conc, dict) else str(conc)
                if not ("github.event.action" in group and "'hint'" in group and "'request'" in group):
                    err("ci-request.yml", "one concurrency group for hints and requests — a push would replace a pending request; split on github.event.action ('hint' / 'request')")
                if isinstance(conc, dict) and conc.get("cancel-in-progress") is True:
                    err("ci-request.yml", "concurrency `cancel-in-progress: true` cancels a pending request on every push — cancel hint runs only")
        elif hints:
            err("ci-request.yml", f"calls ci-hint.yml but pull_request types are not {HINT_TYPES}")

    guard_called, called = False, set()
    for s in suites:
        doc = docs.get(s)
        if doc is None:
            err(s, "listed in ci-request.yml but does not exist")
            continue
        t = triggers(doc)
        for bad in ("pull_request", "pull_request_target", "workflow_run"):
            if bad in t:
                err(s, f"runs on {bad} — a suite runs only when requested (ci:run label or /ci)")
        if "push" in t:
            push = t["push"] or {}
            br = push.get("branches")
            br = [br] if isinstance(br, str) else br
            tags_only = not br and "tags" in push and "branches-ignore" not in push
            if not tags_only and (not br or not set(br) <= LONG_LIVED):
                err(s, f"push trigger must name long-lived branches only ({', '.join(sorted(LONG_LIVED))})")
        inputs = set(((t.get("workflow_dispatch") or {}).get("inputs") or {}))
        if not DISPATCH_INPUTS <= inputs:
            err(s, "workflow_dispatch must declare inputs " + ", ".join(sorted(DISPATCH_INPUTS)))
        if "merge_group" not in t:
            err(s, "no merge_group trigger")

        seen_verify = seen_status = False
        walk, seen_docs = [(s, doc)], {s}
        while walk:
            here, d = walk.pop()
            for _, job, _ in steps_by_job(d):
                if str(job.get("uses", "")).startswith(GUARD_WF):
                    guard_called = True
                    if "shared_ref" in (job.get("with") or {}):
                        refs.add(str(job["with"]["shared_ref"]))
                callee = local_calls(job)
                if callee and callee in docs and callee not in seen_docs:
                    seen_docs.add(callee); called.add(callee); walk.append((callee, docs[callee]))
        for jname, job, steps in (x for f in sorted(seen_docs) for x in steps_by_job(docs[f])):
            checked_out = False
            for st in steps:
                if str(st.get("uses", "")).startswith("actions/checkout@"):
                    checked_out = True
                if uses_action(st, "verify-ci-request"):
                    seen_verify = True
                    if not DISPATCH_IF.match(str(st.get("if", ""))):
                        err(s, "verify-ci-request step must be guarded by `if: github.event_name == 'workflow_dispatch'`")
                    if not grants(doc, job, "pull-requests", {"read", "write"}):
                        err(s, f"job `{jname}` uses verify-ci-request without pull-requests: read")
                    if not checked_out:
                        err(s, f"job `{jname}` runs verify-ci-request before actions/checkout")
                if uses_action(st, "ci-status"):
                    seen_status = True
                    if not ALWAYS_IF.search(str(st.get("if", ""))):
                        err(s, "ci-status step must run `if: always()` so a failure is posted too")
                    if not grants(doc, job, "statuses", {"write"}):
                        err(s, f"job `{jname}` uses ci-status without statuses: write")
        if not seen_verify:
            err(s, "no verify-ci-request step — dispatch inputs would be trusted unchecked")
        if not seen_status:
            err(s, "no ci-status step — its verdict would never reach the PR rollup")

    if suites and not guard_called:
        err("ci-request.yml", "no suite calls boonty-io/.github/.github/workflows/on-demand-guard.yml — the contract would be unguarded")

    for f, doc in docs.items():
        if f in suites or f in called:
            continue
        if any(uses_action(st, "ci-status") for _, _, sts in steps_by_job(doc) for st in sts):
            err(f, "posts a ci-status but is not listed in ci-request.yml — it is never dispatched, so its context stays `expected`")

    if len(refs) > 1:
        errors.append(f"✗ boonty-io/.github is referenced at more than one ref: {sorted(refs)} — pin one")

    if errors:
        print("\n".join(errors))
        return 1
    print(f"✓ on-demand CI contract holds: {len(suites)} suite(s) — {', '.join(suites)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
