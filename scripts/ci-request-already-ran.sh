#!/usr/bin/env bash
# Has one suite already answered for one head? Pure function of the
# `GET actions/workflows/<suite>/runs?head_sha=<sha>&event=workflow_dispatch`
# answer (path in $1, newest run first), tested by
# test/ci-request-already-ran.test.sh. Prints `key=value` lines:
#
#   skip=true why=running url=<run>   a run of the suite on this head is queued or in progress
#   skip=true why=passed url=<run>    the newest run of the suite on this head succeeded
#   skip=false                        no run yet, or the newest one failed, was cancelled or never started
#
# ci-request.yml does not dispatch a suite that answers skip=true: running it
# again on the same commit buys the same verdict twice. A new push or a rebase
# is a new head with no run, so it always runs. An answer this script cannot
# read gives skip=false: a wasted run is cheaper than a suite that never runs.
set -euo pipefail
runs="${1:-}"
if [ -z "$runs" ] || [ ! -r "$runs" ] || ! jq -e '.workflow_runs | type == "array"' "$runs" >/dev/null 2>&1; then
  echo "skip=false"; exit 0
fi
running="$(jq -r '[.workflow_runs[] | select(.status != "completed")][0].html_url // ""' "$runs")"
if [ -n "$running" ]; then
  echo "skip=true"; echo "why=running"; echo "url=${running}"; exit 0
fi
newest="$(jq -r '.workflow_runs[0] | select(.conclusion == "success") | .html_url // ""' "$runs")"
if [ -n "$newest" ]; then
  echo "skip=true"; echo "why=passed"; echo "url=${newest}"; exit 0
fi
echo "skip=false"
