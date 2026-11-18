Return EXACTLY this shape and nothing else:

verdict: pass|fail
findings:
- file: <repo-relative path>
  line: <integer>
  severity: block|warn|nit
  note: <one sentence>
summary: <at most 1200 characters>

Write `findings: none` for a clean run. `fail` requires at least one `block`; `pass` forbids one. At most 5 findings, most severe first: the runner keeps the first 5 by severity and drops the rest with a count. No praise, no restating the diff, no prose outside the block. The summary cap is counted in CHARACTERS (1200, which is 300 tokens at the runner's chars / 4 rule): the runner keeps the first 1200 characters, truncates the rest and counts them on the receipt. Truncation is not a violation and costs you no retry, but the cut is blind — say the load-bearing thing first.
