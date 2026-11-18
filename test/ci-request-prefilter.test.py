#!/usr/bin/env python3
"""Cases for the job-level `if:` in templates/ci-request.yml. Run: python3 test/ci-request-prefilter.test.py

A caller job whose `if:` is false is skipped and bills nothing, so the
prefilter turns the runs that can never be a request (any other label, any
comment that is not `/ci`) into free ones. It must stay a superset of
scripts/ci-request-decide.sh: every fixture that script answers go=true or
hint=true must pass it, or a real request (or the hint) would silently stop
running. The expression is read from the template, evaluated here with a
minimal translation of the GitHub expression syntax it uses (==, !=, &&, ||,
!, parentheses, string literals, startsWith, github.* lookups).
"""
import json, os, re, subprocess, sys, unittest

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
FIXTURES = os.path.join(HERE, "fixtures")
DECIDE = os.path.join(ROOT, "scripts", "ci-request-decide.sh")
TEMPLATE = os.path.join(ROOT, "templates", "ci-request.yml")


class Ctx:
    def __init__(self, event_name, event):
        self.event_name, self.event = event_name, event

    def lookup(self, path):
        if path == "github.event_name":
            return self.event_name
        cur = self.event
        for key in path.split(".")[2:]:
            cur = cur.get(key) if isinstance(cur, dict) else None
        return cur


def evaluate(expr, ctx):
    """Evaluate a GitHub Actions expression (the subset the template uses)."""
    tokens = re.findall(r"\s*('(?:[^']|'')*'|==|!=|&&|\|\||!|\(|\)|,|[A-Za-z_][A-Za-z0-9_.\-]*)", expr)
    if "".join(tokens).replace(" ", "") != expr.replace(" ", ""):
        raise ValueError(f"untokenisable expression: {expr}")
    pos = 0

    def peek():
        return tokens[pos].strip() if pos < len(tokens) else None

    def take():
        nonlocal pos
        pos += 1
        return tokens[pos - 1].strip()

    def eq(a, b):  # GitHub compares strings case-insensitively
        if isinstance(a, str) and isinstance(b, str):
            return a.lower() == b.lower()
        return a == b

    def primary():
        t = take()
        if t == "(":
            v = or_()
            assert take() == ")"
            return v
        if t == "!":
            return not truthy(primary())
        if t.startswith("'"):
            return t[1:-1].replace("''", "'")
        if t == "startsWith":
            assert take() == "("
            a = or_()
            assert take() == ","
            b = or_()
            assert take() == ")"
            return isinstance(a, str) and isinstance(b, str) and a.lower().startswith(b.lower())
        if t in ("true", "false"):
            return t == "true"
        if t.startswith("github."):
            return ctx.lookup(t)
        raise ValueError(f"unsupported token {t!r} in {expr}")

    def cmp():
        v = primary()
        while peek() in ("==", "!="):
            op, r = take(), primary()
            v = eq(v, r) if op == "==" else not eq(v, r)
        return v

    def and_():
        v = cmp()
        while peek() == "&&":
            take()
            r = cmp()
            v = r if truthy(v) else v
        return v

    def or_():
        v = and_()
        while peek() == "||":
            take()
            r = and_()
            v = v if truthy(v) else r
        return v

    out = or_()
    if pos != len(tokens):
        raise ValueError(f"trailing tokens in {expr}")
    return out


def truthy(v):
    return v not in (None, False, "", 0)


def inner(s):
    m = re.fullmatch(r"\s*\$\{\{(.*)\}\}\s*", s, re.S)
    return m.group(1).strip() if m else s.strip()


def event_name_of(fixture):
    return "issue_comment" if fixture.startswith("comment-") else "pull_request"


def decide(fixture):
    env = dict(os.environ, GITHUB_EVENT_NAME=event_name_of(fixture), CI_LABEL="ci:run", CI_COMMAND="/ci")
    out = subprocess.run([DECIDE, os.path.join(FIXTURES, fixture)], env=env, capture_output=True, text=True, check=True).stdout
    return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)


FIXTURE_FILES = sorted(f for f in os.listdir(FIXTURES) if f.endswith(".json"))


class Prefilter(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(TEMPLATE) as fh:
            cls.wf = yaml.safe_load(fh)
        cls.request_if = cls.wf["jobs"]["request"]["if"]
        group = cls.wf["concurrency"]["group"]
        cls.group_tail = inner(group[group.rindex("${{"):])

    def ctx(self, fixture):
        with open(os.path.join(FIXTURES, fixture)) as fh:
            return Ctx(event_name_of(fixture), json.load(fh))

    def passes(self, fixture):
        return truthy(evaluate(inner(self.request_if), self.ctx(fixture)))

    def test_fixtures_are_present(self):
        self.assertGreater(len(FIXTURE_FILES), 10)

    def test_every_request_or_hint_passes_the_prefilter(self):
        for f in FIXTURE_FILES:
            d = decide(f)
            if d.get("go") == "true" or d.get("hint") == "true":
                with self.subTest(fixture=f):
                    self.assertTrue(self.passes(f), f"{f}: decide says {d}, but the job would be skipped")

    def test_non_requests_are_skipped(self):
        # The runs this prefilter exists to make free.
        for f in ("labeled-other.json", "comment-mentions-ci.json", "comment-ci-on-issue.json"):
            with self.subTest(fixture=f):
                self.assertEqual(decide(f).get("go"), "false")
                self.assertFalse(self.passes(f), f"{f} is never a request but would still bill a job")

    def test_both_jobs_share_one_prefilter(self):
        self.assertEqual(self.wf["jobs"]["hint"]["if"], self.request_if)

    def test_skipped_runs_queue_apart_from_requests(self):
        # A group keeps one pending run: a skipped run sharing the request
        # group would replace a queued `ci:run` and the request would be lost.
        for f in FIXTURE_FILES:
            with self.subTest(fixture=f):
                slot = evaluate(self.group_tail, self.ctx(f))
                if self.passes(f):
                    self.assertIn(slot, ("hint", "request"))
                else:
                    self.assertEqual(slot, "noop")

    def test_hints_still_split_from_requests(self):
        self.assertEqual(evaluate(self.group_tail, self.ctx("synchronize.json")), "hint")
        # A ready PR's new head is a request that shares the hint slot: a later
        # push cancels it, and that push is itself requested.
        self.assertEqual(decide("synchronize-ready.json").get("go"), "true")
        self.assertEqual(evaluate(self.group_tail, self.ctx("synchronize-ready.json")), "hint")
        self.assertEqual(evaluate(self.group_tail, self.ctx("labeled-ci-run.json")), "request")
        self.assertEqual(evaluate(self.group_tail, self.ctx("comment-ci-member.json")), "request")


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=1).result.wasSuccessful() else 1)
