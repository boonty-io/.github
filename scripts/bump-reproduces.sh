#!/usr/bin/env bash
# Is this PR exactly the @boonty-io/ai-config bump to <version>, as the
# published release's own `boonty-ai sync` produces it?
#
#   bump-reproduces.sh <repo-dir> <base-ref> <head-sha> <version> <npmrc>
#
# <repo-dir>  a full clone holding <base-ref> and <head-sha> (the PR head
#             checkout, fetch-depth 0); only git reads it and only three
#             package files are taken from the head.
# <npmrc>     a userconfig with the registry token; it is deleted before
#             `sync` runs, and `sync` runs with an emptied environment.
#
# exit 0  every condition holds:
#   1. <version> is greater than the ai-config version at the merge base
#      (old) and at the tip of <base-ref> (tip), numerically: no downgrade,
#      no stale bump;
#   2. package.json, pnpm-lock.yaml and pnpm-workspace.yaml at the head equal
#      their merge-base copies byte for byte once the ai-config version
#      (old on the base side, <version> on the head side) is replaced by V on
#      the lines that name ai-config, and the ai-config `resolution:` line is
#      set aside; each file is at most 2 MB;
#   3. that resolution line pins the GitHub Packages tarball of <version>, and
#      its integrity equals the registry's dist.integrity;
#   4. npm installs that version into a temp dir with the same integrity;
#   5. in a scratch worktree at the merge base carrying the head's three
#      package files, the installed `boonty-ai sync` produces the head's
#      tree exactly: no file differs, none is untracked.
# exit 1  a condition fails.
# exit 2  something could not be read or installed.
set -uo pipefail
repo="${1:?repo dir}"; base="${2:?base ref}"; head="${3:?head sha}"; version="${4:?version}"; npmrc="${5:?npmrc}"
PKG='@boonty-io/ai-config'
MAX=2097152
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"; wt=""
cleanup() { rm -f "$npmrc"; [ -n "$wt" ] && git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1; rm -rf "$tmp"; }
trap cleanup EXIT
no() { echo "bump-reproduces: $1" >&2; exit 1; }
err() { echo "bump-reproduces: $1" >&2; exit 2; }
g() { GIT_GRAFT_FILE=/dev/null git -C "$repo" -c advice.graftFileDeprecated=false --no-replace-objects "$@"; }

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || no "version '$version' is not x.y.z"
mb="$(g merge-base "$base" "$head" 2>/dev/null)" || err "no merge base"
[[ "$mb" =~ ^[0-9a-f]{40}$ ]] || err "no merge base"

ver_of() { # <rev> → the ai-config version in that revision's package.json, digits only
  g show "$1:package.json" 2>/dev/null | jq -r --arg p "$PKG" \
    '(.devDependencies[$p] // .dependencies[$p] // "") | ltrimstr("^") | ltrimstr("~")' 2>/dev/null
}
newer() { # <a> <b>: is a > b, numerically by component
  local IFS=.; local -a x=($1) y=($2); local i
  for i in 0 1 2; do
    [ "${x[i]:-0}" -gt "${y[i]:-0}" ] && return 0
    [ "${x[i]:-0}" -lt "${y[i]:-0}" ] && return 1
  done
  return 1
}
old="$(ver_of "$mb")"; tip="$(ver_of "$base")"
[[ "$old" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || no "no ai-config version at the merge base"
[[ "$tip" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || no "no ai-config version at the base tip"
newer "$version" "$old" || no "$version is not newer than the merge base's $old"
newer "$version" "$tip" || no "$version is not newer than the base tip's $tip"

for f in package.json pnpm-lock.yaml pnpm-workspace.yaml; do
  for side in "$mb" "$head"; do
    if g cat-file -e "$side:$f" 2>/dev/null; then
      [ "$(g cat-file -s "$side:$f")" -le "$MAX" ] || no "$f is larger than 2 MB"
      g show "$side:$f" > "$tmp/$f.$side" || err "cannot read $f"
    fi
  done
  [ -e "$tmp/$f.$mb" ] || [ -e "$tmp/$f.$head" ] || { [ "$f" = pnpm-workspace.yaml ] && continue; no "no $f"; }
  [ -e "$tmp/$f.$mb" ] && [ -e "$tmp/$f.$head" ] || no "$f exists on one side only"
  python3 -I "$here/bump-normalize.py" "$old" < "$tmp/$f.$mb" > "$tmp/$f.base.n" 2> "$tmp/$f.base.res" || err "cannot normalise $f"
  python3 -I "$here/bump-normalize.py" "$version" < "$tmp/$f.$head" > "$tmp/$f.head.n" 2> "$tmp/$f.head.res" || err "cannot normalise $f"
  cmp -s "$tmp/$f.base.n" "$tmp/$f.head.n" || no "$f changes more than the ai-config version"
done

res="$(cat "$tmp/pnpm-lock.yaml.head.res")"
re="^resolution: \{integrity: (sha512-[A-Za-z0-9+/]+={0,2}), tarball: https://npm\.pkg\.github\.com/download/@boonty-io/ai-config/${version//./\\.}/[0-9a-f]{40}\}$"
[[ "$res" =~ $re ]] || no "the lockfile's ai-config resolution is not the GitHub Packages tarball of $version"
lock_int="${BASH_REMATCH[1]}"

reg_int="$(npm view --userconfig "$npmrc" "$PKG@$version" dist.integrity 2>/dev/null)" || err "registry unreadable"
[ -n "$reg_int" ] || err "registry gave no integrity"
[ "$reg_int" = "$lock_int" ] || no "lockfile integrity differs from the registry's"

inst="$tmp/inst"; mkdir -p "$inst"
(cd "$inst" && npm install --userconfig "$npmrc" --ignore-scripts --no-save --no-package-lock --no-audit --no-fund "$PKG@$version" >/dev/null 2>&1) \
  || err "npm install of $PKG@$version failed"
got_int="$(jq -r --arg k "node_modules/$PKG" '.packages[$k].integrity // ""' "$inst/node_modules/.package-lock.json" 2>/dev/null)"
[ "$got_int" = "$reg_int" ] || no "installed tarball integrity differs from the registry's"
bin="$inst/node_modules/.bin/boonty-ai"; [ -x "$bin" ] || err "installed package has no boonty-ai bin"
rm -f "$npmrc"

wt="$tmp/wt"
g worktree add -q --detach "$wt" "$mb" >/dev/null 2>&1 || err "cannot create a worktree at the merge base"
for f in package.json pnpm-lock.yaml pnpm-workspace.yaml; do
  [ -e "$tmp/$f.$head" ] && cp "$tmp/$f.$head" "$wt/$f"
done
node_dir="$(dirname "$(command -v node)")"
(cd "$wt" && env -i HOME="$tmp/home" PATH="$node_dir:/usr/bin:/bin" "$bin" sync >"$tmp/sync.log" 2>&1) \
  || no "boonty-ai sync failed: $(tail -1 "$tmp/sync.log")"
[ -z "$(git -C "$wt" ls-files --others --exclude-standard)" ] || no "sync wrote files the merge base does not track; a bump that adds a generated file is not exempt"
git -C "$wt" diff --quiet "$head" -- . || no "the head differs from what boonty-ai sync $version produces"
exit 0
