#!/bin/sh

set -e

LOCK=/pgdog/.generate-config.lock
TMP=/pgdog/pgdog.toml.tmp
OUT=/pgdog/pgdog.toml
USERS_TMP=/pgdog/users.toml.tmp
USERS_OUT=/pgdog/users.toml

# Prevent concurrent runs (e.g. the background poll loop and a manual
# invocation overlapping) from racing on the shared temp files.
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "Another instance is already running, skipping this cycle"
  exit 0
fi

POSTGRES_HOST="${POSTGRES_HOST:-db}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
PGDOG_USER="${PGDOG_USER:-pgdog}"
PGDOG_DATABASE="${PGDOG_DATABASE:-pgdog}"

# Fail fast with a clear error if required credentials are missing,
# instead of silently generating a config with empty passwords.
if [ -z "${POSTGRES_PASSWORD:-}" ]; then
  echo "ERROR: POSTGRES_PASSWORD is not set" >&2
  exit 1
fi
if [ -z "${PGDOG_PASSWORD:-}" ]; then
  echo "ERROR: PGDOG_PASSWORD is not set" >&2
  exit 1
fi

export PGPASSWORD="$POSTGRES_PASSWORD"

# Clean up temporary files on exit
trap 'rm -f "$TMP" "$USERS_TMP"' EXIT

# Get all non-template databases
DBS=$(psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -t -A -c "SELECT datname FROM pg_database WHERE datistemplate = false;")

# Generate pgdog config
{
  echo '[general]'
  echo 'port = 6432'
  echo 'default_pool_size = 10'
  echo 'passthrough_auth = "enabled_plain"'
  echo 'openmetrics_port = 9090'
  echo 'openmetrics_namespace = "pgdog_"'
} > "$TMP"

while IFS= read -r DB; do
  [ -z "$DB" ] && continue
  {
    echo ''
    echo '[[databases]]'
    echo "name = \"$DB\""
    echo "host = \"$POSTGRES_HOST\""
    echo 'port = 5432'
    echo 'role = "primary"'
  } >> "$TMP"
done <<EOF
$DBS
EOF

# --- GENERATE users.toml ---

# Build database list for postgres user
DATABASES_LIST=""
while IFS= read -r DB; do
  [ -z "$DB" ] && continue
  if [ -n "$DATABASES_LIST" ]; then
    DATABASES_LIST="$DATABASES_LIST, "
  fi
  DATABASES_LIST="$DATABASES_LIST\"$DB\""
done <<EOF
$DBS
EOF

{
  echo '[[users]]'
  echo "name=\"$PGDOG_USER\""
  echo "password=\"$PGDOG_PASSWORD\""
  echo "database=\"$PGDOG_DATABASE\""

  echo ''

  echo '[[users]]'
  echo "name=\"$POSTGRES_USER\""
  echo "password=\"$POSTGRES_PASSWORD\""
  echo "databases=[$DATABASES_LIST]"
} > "$USERS_TMP"

# --- RELOAD pgdog.toml og users.toml if changed ---
if ! cmp -s "$TMP" "$OUT"; then
  echo "Config changed — updating PgDog config"
  mv "$TMP" "$OUT"
  mv "$USERS_TMP" "$USERS_OUT"
  pkill -HUP pgdog || true
else
  echo "No changes"
fi