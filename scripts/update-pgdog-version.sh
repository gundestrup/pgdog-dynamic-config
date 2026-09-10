#!/bin/sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname -- "$SCRIPT_DIR")"
VERSIONS_FILE="$PROJECT_DIR/versions.env"

if [ ! -f "$VERSIONS_FILE" ]; then
  echo "ERROR: $VERSIONS_FILE is missing" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: GitHub CLI (gh) is required" >&2
  exit 1
fi

LATEST_VERSION="$(gh api repos/pgdogdev/pgdog/releases/latest --jq '.tag_name')"
case "$LATEST_VERSION" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *)
    echo "ERROR: unexpected PgDog release tag: $LATEST_VERSION" >&2
    exit 1
    ;;
esac

CURRENT_VERSION="$(sed -n 's/^PGDOG_VERSION=//p' "$VERSIONS_FILE")"
if [ -z "$CURRENT_VERSION" ]; then
  echo "ERROR: PGDOG_VERSION is missing from $VERSIONS_FILE" >&2
  exit 1
fi

case "${1:-}" in
  --check)
    if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
      echo "PgDog version is current: $CURRENT_VERSION"
      exit 0
    fi
    echo "PgDog version is $CURRENT_VERSION; latest release is $LATEST_VERSION" >&2
    echo "Run ./scripts/update-pgdog-version.sh to update $VERSIONS_FILE" >&2
    exit 1
    ;;
  "")
    TMP_FILE="$(mktemp "$VERSIONS_FILE.tmp.XXXXXX")"
    trap 'rm -f "$TMP_FILE"' EXIT
    printf 'PGDOG_VERSION=%s\n' "$LATEST_VERSION" > "$TMP_FILE"
    mv "$TMP_FILE" "$VERSIONS_FILE"
    trap - EXIT
    echo "Updated PgDog version: $CURRENT_VERSION -> $LATEST_VERSION"
    ;;
  *)
    echo "Usage: $0 [--check]" >&2
    exit 2
    ;;
esac
