#!/usr/bin/env bash
# Steps of action.yml, kept in a file so test/install-release-tool.test.sh can
# run them. Inputs arrive as environment variables, never as interpolated
# shell, so no input value is ever parsed as code.
#
#   install.sh prep     validate inputs; output `tarball` and `key`
#   install.sh install  download on a miss, verify, extract, put on PATH;
#                       output `path`, and `save=true` when the cache needs it
set -euo pipefail

# Overridable for the test; the action never sets them.
CURL="${CURL:-curl}"
RETRY_DELAY="${RETRY_DELAY:-10}"

die() { echo "::error::install-release-tool: $*" >&2; exit 1; }

validate() {
  [[ "$NAME" =~ ^[a-z0-9_-]+$ ]] || die "name must match [a-z0-9_-]+, got '$NAME'"
  [[ "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || die "version must match [A-Za-z0-9._-]+, got '$VERSION'"
  [[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || die "sha256 must be 64 lowercase hex characters"
}

# shellcheck disable=SC2153  # URL comes from the action env
download() {
  # --retry-all-errors retries a 5xx (the 2026-11-09 failure) and a 404 alike;
  # -f keeps an HTTP error body from landing on disk as a "successful" file.
  # Five retries 10 s apart ride out a blip; a long outage still fails, which
  # is what the cache is for.
  "$CURL" --proto '=https' --tlsv1.2 -fsSL \
    --retry 5 --retry-all-errors --retry-delay "$RETRY_DELAY" \
    -o "$TARBALL" "$URL"
}

verify() { echo "${SHA256}  ${TARBALL}" | sha256sum -c --status -; }

case "${1:-}" in
  prep)
    validate
    dir="$RUNNER_TEMP/release-tools"
    mkdir -p "$dir"
    {
      echo "tarball=$dir/$NAME-$VERSION.tar.gz"
      echo "key=release-tool-$NAME-$VERSION-$SHA256"
    } >> "$GITHUB_OUTPUT"
    ;;
  install)
    validate
    [[ "$URL" == https://* ]] || die "url must be https://"
    member="${MEMBER:-$NAME}"
    save=false
    if [ "${CACHE_HIT:-}" = "true" ] && verify; then
      echo "$NAME $VERSION: tarball restored from cache, sha256 verified"
    else
      if [ "${CACHE_HIT:-}" = "true" ]; then
        # The key carries the sha256, so this entry can never become valid:
        # fetch fresh bytes rather than fail on every run forever.
        echo "::warning::install-release-tool: cached $NAME $VERSION failed sha256, downloading again"
      fi
      rm -f "$TARBALL"
      download || die "download of $NAME $VERSION failed after retries: $URL"
      verify || die "sha256 mismatch for $NAME $VERSION ($URL)"
      echo "$NAME $VERSION: downloaded, sha256 verified"
      # Never save over a hit: the entry exists and is immutable.
      [ "${CACHE_HIT:-}" = "true" ] || save=true
    fi
    work="$(mktemp -d "$RUNNER_TEMP/release-tool.XXXXXX")"
    tar -xzf "$TARBALL" -C "$work" "$member" || die "'$member' not found in $NAME tarball"
    bin="$RUNNER_TEMP/release-tools/bin"
    mkdir -p "$bin"
    install -m 0755 "$work/$member" "$bin/$NAME"
    rm -rf "$work"
    echo "$bin" >> "$GITHUB_PATH"
    {
      echo "path=$bin/$NAME"
      echo "save=$save"
    } >> "$GITHUB_OUTPUT"
    ;;
  *) die "usage: install.sh prep|install" ;;
esac
