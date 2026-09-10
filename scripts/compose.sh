#!/bin/sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

PGDOG_VERSION="$(sed -n 's/^PGDOG_VERSION=//p' "$PROJECT_DIR/versions.env")"
if [ -z "$PGDOG_VERSION" ]; then
  echo "ERROR: PGDOG_VERSION is missing from $PROJECT_DIR/versions.env" >&2
  exit 1
fi
export PGDOG_VERSION

exec docker compose "$@"
