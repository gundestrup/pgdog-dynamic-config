#!/bin/sh

set -e

POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-300}"

trap 'echo "Received SIGTERM, exiting."; exit 0' TERM

while true; do
  # Don't let a transient failure (e.g. PostgreSQL briefly unreachable)
  # crash the sidecar; log it and retry on the next cycle instead.
  /pgdog/generate-config.sh || echo "generate-config.sh failed, will retry in ${POLL_INTERVAL_SECONDS}s" >&2
  sleep "$POLL_INTERVAL_SECONDS"
done
