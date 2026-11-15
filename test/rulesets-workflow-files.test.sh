#!/usr/bin/env bash
# Static checks on .github/workflows/rulesets.yml.
#  - every rulesets/repos/*.json and rulesets/environments/*.json reaches its
#    script, dotfiles included: `.github.json` sat unapplied because a bare
#    `*.json` glob skips names starting with a dot.
#  - per event, the job's environment, mode, App credentials, token
#    permission and RULESETS_SKIP_BYPASS: only an apply may use the
#    `rulesets` environment (the write key); every plan uses `rulesets-plan`.
# Run: test/rulesets-workflow-files.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
wf=.github/workflows/rulesets.yml
fail=0
ok() { echo "✓ $1"; }
ko() { fail=$((fail+1)); echo "✗ $1"; }

files_check() { # files_check <script regex> <dir>
  local line args got="" want pat
  line="$(grep -E "$1" "$wf")" || { ko "no $1 call in $wf"; return; }
  # the file arguments: everything after "$OWNER" up to the redirection
  args="${line#*\"\$OWNER\"}"; args="${args%%>*}"
  for pat in $args; do
    case "$pat" in "$2"/*) ;; *) ko "unexpected argument $pat"; return ;; esac
    got+="$(compgen -G "$pat")"$'\n'
  done
  got="$(printf '%s' "$got" | sed '/^$/d' | sort -u)"
  want="$(find "$2" -maxdepth 1 -type f -name '*.json' | sort)"
  if [ -n "$want" ] && [ "$got" = "$want" ]; then ok "workflow passes every $2 file ($(wc -l <<<"$want" | tr -d ' '))"
  else ko "workflow file list differs from $2"; diff <(echo "$want") <(echo "$got") | sed 's/^/    /'; fi
}
files_check 'scripts/rulesets\.sh "\$MODE" "\$OWNER"' rulesets/repos
files_check 'scripts/environments\.sh plan "\$OWNER"' rulesets/environments

# wexpr <key>: the ${{ }} expression of the first `key:` line
wexpr() { sed -nE "s/^ *$1: \\\$\\{\\{ (.*) \\}\\} *\$/\\1/p" "$wf" | head -n1; }
# value <expression> <event> <mode input>: the expression evaluated the way
# GitHub does (&&/|| return an operand; '' is falsy, like in Python)
value() {
  python3 -I - "$1" "$2" "$3" <<'PY'
import re, sys
e, event, mode = sys.argv[1:]
if not re.fullmatch(r"[\s()=|&'\w.-]+", e): sys.exit("unsupported expression: " + e)
py = e.replace("&&", " and ").replace("||", " or ")
py = py.replace("github.event_name", repr(event)).replace("inputs.mode", repr(mode))
py = re.sub(r"secrets\.(\w+)", r"'\1'", py)
if re.search(r"[A-Za-z_]\w*\.\w", re.sub(r"'[^']*'", "", py)): sys.exit("unknown context in: " + e)
print(eval(py, {"__builtins__": {}}))
PY
}

E_ENV="$(wexpr environment)"; E_MODE="$(wexpr MODE)"; E_SKIP="$(wexpr RULESETS_SKIP_BYPASS)"
E_ID="$(wexpr app-id)"; E_KEY="$(wexpr private-key)"; E_PERM="$(wexpr permission-administration)"
for v in E_ENV E_MODE E_SKIP E_ID E_KEY E_PERM; do [ -n "${!v}" ] || ko "no ${v#E_} expression in $wf"; done

# event mode-input | environment mode skip-bypass app-id private-key permission
while read -r ev in_mode want; do
  [ "$in_mode" = - ] && in_mode=""
  got="$(value "$E_ENV" "$ev" "$in_mode") $(value "$E_MODE" "$ev" "$in_mode") $(value "$E_SKIP" "$ev" "$in_mode") $(value "$E_ID" "$ev" "$in_mode") $(value "$E_KEY" "$ev" "$in_mode") $(value "$E_PERM" "$ev" "$in_mode")"
  if [ "$got" = "${want//,/ }" ]; then ok "$ev ${in_mode:--}: $got"; else ko "$ev ${in_mode:--}: got '$got', want '${want//,/ }'"; fi
done <<'TABLE'
push - rulesets,apply,0,RULESETS_APP_ID,RULESETS_APP_PRIVATE_KEY,write
workflow_dispatch apply rulesets,apply,0,RULESETS_APP_ID,RULESETS_APP_PRIVATE_KEY,write
pull_request_target - rulesets-plan,plan,1,RULESETS_PLAN_APP_ID,RULESETS_PLAN_APP_PRIVATE_KEY,read
schedule - rulesets-plan,plan,1,RULESETS_PLAN_APP_ID,RULESETS_PLAN_APP_PRIVATE_KEY,read
workflow_dispatch plan rulesets-plan,plan,1,RULESETS_PLAN_APP_ID,RULESETS_PLAN_APP_PRIVATE_KEY,read
TABLE

# The environment comparison runs on plans only; apply never touches them.
if grep -B12 -E 'scripts/environments\.sh plan' "$wf" | grep -qE "^ +if: .*&& env\.MODE == 'plan'( \}\})?$"; then ok "environments are compared on plans only"
else ko "the environments step is not guarded by env.MODE == 'plan'"; fi

[ "$fail" -eq 0 ]
