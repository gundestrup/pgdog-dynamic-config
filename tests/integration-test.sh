#!/bin/sh
#
# Integration tests for pgdog-dynamic-config.
#
# Uses a test-specific docker-compose (tests/docker-compose.test.yml) based on
# PgDog's upstream compose pattern:
#   - postgres:18 (latest 18.x)
#   - the pinned version in ../versions.env by default (override with PGDOG_IMAGE)
#   - pgdog-dynamic-config sidecar (built from ./pgdog)
#
# Verifies that:
#   1. All services start and become healthy.
#   2. The autonomous background loop (entrypoint.sh) generates the initial
#      config on its own — NOT via manual script invocation.
#   3. pgdog.toml and users.toml are generated with correct content.
#   4. No passwords leak in container logs.
#   5. PgDog accepts connections for pre-existing databases.
#   6. The autonomous loop detects a new database AND user created at
#      runtime and regenerates the config + reloads PgDog, without any
#      manual trigger (POLL_INTERVAL_SECONDS=5 for fast test cycles).
#   7. New database is accessible through PgDog after the autonomous update.
#   8. PgDog logs a configuration reload (SIGHUP reached the process).
#   9. The autonomous loop removes databases that were dropped — config
#      shrinks, not just grows.
#  10. Idempotency — manually re-running with no changes reports "No changes".
#  11. A users.toml-only change (e.g. rotated password) is installed — not
#      skipped just because pgdog.toml is unchanged.
#  12. Missing POSTGRES_PASSWORD / PGDOG_PASSWORD exits 1 with a clear error.
#  13. A second concurrent invocation reports "skipping this cycle".
#  14. The generated config passes `pgdog configcheck`.
#  15. The OpenMetrics endpoint serves pgdog_-prefixed metrics.
#
# Usage:
#   ./tests/integration-test.sh
#   PGDOG_IMAGE=ghcr.io/pgdogdev/pgdog:main ./tests/integration-test.sh
#
# Prerequisites:
#   - Docker and Docker Compose installed.
#   - Ports 5433 and 6433 available on the host.
#   - ./pgdog directory writable by UID 1000.
#

set -eu

# --- Config ---

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PGDOG_VERSION="$(sed -n 's/^PGDOG_VERSION=//p' "$PROJECT_DIR/versions.env")"
if [ -z "$PGDOG_VERSION" ]; then
  echo "ERROR: PGDOG_VERSION is missing from $PROJECT_DIR/versions.env" >&2
  exit 1
fi
export PGDOG_VERSION
TEST_COMPOSE="$SCRIPT_DIR/docker-compose.test.yml"
TIMEOUT=120
INTERVAL=5

# Container names (must match docker-compose.test.yml)
DB_CONTAINER="db-test"
PGDOG_CONTAINER="pgdog-test"
SIDECAR_CONTAINER="pgdog-dynamic-config-test"

# Host ports (mapped in docker-compose.test.yml)
PGDOG_PORT=6433

TEST_POSTGRES_PASSWORD="test-pg-pass-123"
TEST_PGDOG_PASSWORD="test-pgdog-pass-123"
TEST_NEW_USER_PASSWORD="test-new-pass-123"

# Compose helper
dc() {
  docker compose -f "$TEST_COMPOSE" "$@"
}

PASS=0
FAIL=0

COVERAGE_DIR="$PROJECT_DIR/coverage"
TEST_RESULTS_DIR="$PROJECT_DIR/test-results"
RESULTS_FILE="$(mktemp "${TMPDIR:-/tmp}/pgdog-test-results.XXXXXX")"

# --- Helpers ---

log() {
  printf '\n\033[1m=== %s ===\033[0m\n' "$1"
}

pass() {
  printf '  \033[32m✓\033[0m %s\n' "$1"
  printf 'PASS\t%s\n' "$1" >> "$RESULTS_FILE"
  PASS=$((PASS + 1))
}

fail() {
  printf '  \033[31m✗\033[0m %s\n' "$1"
  printf 'FAIL\t%s\n' "$1" >> "$RESULTS_FILE"
  FAIL=$((FAIL + 1))
}

# shellcheck disable=SC2317,SC2329
xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

# shellcheck disable=SC2317,SC2329
write_junit() {
  mkdir -p "$TEST_RESULTS_DIR"
  _tests=$(wc -l < "$RESULTS_FILE" | tr -d ' ')
  _fails=$(grep -c '^FAIL' "$RESULTS_FILE" || true)
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<testsuite name="pgdog-integration-tests" tests="%s" failures="%s">\n' "$_tests" "$_fails"
    while IFS="$(printf '\t')" read -r _status _name; do
      _esc=$(xml_escape "$_name")
      if [ "$_status" = "PASS" ]; then
        printf '  <testcase classname="integration-test" name="%s"/>\n' "$_esc"
      else
        printf '  <testcase classname="integration-test" name="%s"><failure message="assertion failed"/></testcase>\n' "$_esc"
      fi
    done < "$RESULTS_FILE"
    printf '</testsuite>\n'
  } > "$TEST_RESULTS_DIR/junit.xml"
}

assert_contains() {
  _file="$1"
  _pattern="$2"
  _msg="$3"
  if grep -q "$_pattern" "$_file" 2>/dev/null; then
    pass "$_msg"
  else
    fail "$_msg (expected '$_pattern' in $_file)"
  fi
}

wait_healthy() {
  _service="$1"
  _elapsed=0
  while [ "$_elapsed" -lt "$TIMEOUT" ]; do
    _status=$(docker inspect --format='{{.State.Health.Status}}' "$_service" 2>/dev/null || echo "none")
    if [ "$_status" = "healthy" ]; then
      return 0
    fi
    printf '  Waiting for %s to become healthy (status: %s, %ds elapsed)...\n' \
      "$_service" "$_status" "$_elapsed"
    sleep "$INTERVAL"
    _elapsed=$((_elapsed + INTERVAL))
  done
  return 1
}

wait_running() {
  _service="$1"
  _elapsed=0
  while [ "$_elapsed" -lt "$TIMEOUT" ]; do
    _status=$(docker inspect --format='{{.State.Status}}' "$_service" 2>/dev/null || echo "none")
    if [ "$_status" = "running" ]; then
      return 0
    fi
    printf '  Waiting for %s to be running (status: %s, %ds elapsed)...\n' \
      "$_service" "$_status" "$_elapsed"
    sleep "$INTERVAL"
    _elapsed=$((_elapsed + INTERVAL))
  done
  return 1
}

# Polls a file for a pattern without ever manually triggering generate-config.sh.
# Used to verify the autonomous background loop (entrypoint.sh) actually
# picks up changes on its own, rather than only testing manual invocation.
wait_for_pattern() {
  _file="$1"
  _pattern="$2"
  _timeout="$3"
  _elapsed=0
  while [ "$_elapsed" -lt "$_timeout" ]; do
    if grep -q "$_pattern" "$_file" 2>/dev/null; then
      return 0
    fi
    sleep 1
    _elapsed=$((_elapsed + 1))
  done
  return 1
}

# Polls a file until a pattern disappears — used to verify the autonomous
# loop regenerates config after a database is dropped.
wait_for_absence() {
  _file="$1"
  _pattern="$2"
  _timeout="$3"
  _elapsed=0
  while [ "$_elapsed" -lt "$_timeout" ]; do
    if ! grep -q "$_pattern" "$_file" 2>/dev/null; then
      return 0
    fi
    sleep 1
    _elapsed=$((_elapsed + 1))
  done
  return 1
}

# Invokes generate-config.sh in the sidecar container, retrying when the
# background loop happens to hold the lock at that moment. Extra args are
# passed to docker exec (e.g. -e VAR= to override environment). Result is
# in RUN_OUT / RUN_RC.
run_generate() {
  RUN_OUT=""
  RUN_RC=0
  _a=0
  while [ "$_a" -lt 5 ]; do
    RUN_OUT=$(docker exec "$@" "$SIDECAR_CONTAINER" /pgdog/generate-config.sh 2>&1) && RUN_RC=0 || RUN_RC=$?
    case "$RUN_OUT" in
      *"skipping this cycle"*) sleep 1; _a=$((_a + 1)) ;;
      *) return 0 ;;
    esac
  done
}

# --- Setup ---

log "Setup"

# Clean up any previous test artifacts
rm -rf "$PROJECT_DIR/data" "$PROJECT_DIR/logs" "$COVERAGE_DIR" "$TEST_RESULTS_DIR"
rm -f "$PROJECT_DIR/pgdog/pgdog.toml" "$PROJECT_DIR/pgdog/users.toml"
rm -f "$PROJECT_DIR/pgdog/pgdog.toml.tmp" "$PROJECT_DIR/pgdog/users.toml.tmp"

# Ensure pgdog dir is writable by UID 1000 (sidecar runs as non-root)
mkdir -p "$PROJECT_DIR/pgdog"
chmod 777 "$PROJECT_DIR/pgdog" 2>/dev/null || true

# Tear down any leftover containers from previous runs
dc down -v --remove-orphans 2>/dev/null || true

pass "Test environment prepared"

# --- Start stack ---

log "Starting Docker Compose stack (postgres:18 + ${PGDOG_IMAGE:-ghcr.io/pgdogdev/pgdog:$PGDOG_VERSION})"

if dc up -d --build 2>&1; then
  pass "Docker Compose stack started"
else
  fail "Docker Compose stack failed to start"
  log "Tearing down"
  dc down -v --remove-orphans 2>/dev/null || true
  printf '\n\033[31m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
  exit 1
fi

# --- Cleanup on exit ---

# shellcheck disable=SC2317,SC2329
cleanup() {
  log "Tearing down"
  write_junit
  if [ "$FAIL" -gt 0 ]; then
    log "Container logs (failure diagnostics)"
    dc logs --tail=50 db pgdog pgdog-dynamic-config 2>/dev/null || true
  fi
  dc exec -T pgdog-dynamic-config rm -f /pgdog/pgdog.toml /pgdog/users.toml /pgdog/pgdog.toml.tmp /pgdog/users.toml.tmp 2>/dev/null || true
  docker rm -f "${COV_CONTAINER:-pgdog-coverage-run}" >/dev/null 2>&1 || true
  docker rm -f pgdog-metrics-check >/dev/null 2>&1 || true
  dc down -v --remove-orphans 2>/dev/null || true
  rm -rf "$PROJECT_DIR/data" "$PROJECT_DIR/logs"
  rm -f "$PROJECT_DIR/pgdog/pgdog.toml" "$PROJECT_DIR/pgdog/users.toml"
  rm -f "$PROJECT_DIR/pgdog/pgdog.toml.tmp" "$PROJECT_DIR/pgdog/users.toml.tmp"
  printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
}
trap cleanup EXIT

# --- Test 1: Services become healthy ---

log "Test 1: Services start and become healthy"

if wait_healthy "$DB_CONTAINER"; then
  pass "PostgreSQL ($DB_CONTAINER) is healthy"
else
  fail "PostgreSQL ($DB_CONTAINER) did not become healthy within ${TIMEOUT}s"
fi

if wait_running "$PGDOG_CONTAINER"; then
  pass "PgDog container is running"
else
  fail "PgDog container did not start within ${TIMEOUT}s"
fi

if wait_healthy "$PGDOG_CONTAINER"; then
  pass "PgDog is healthy"
else
  fail "PgDog did not become healthy within ${TIMEOUT}s"
fi

if wait_running "$SIDECAR_CONTAINER"; then
  pass "pgdog-dynamic-config container is running"
else
  fail "pgdog-dynamic-config container did not start within ${TIMEOUT}s"
fi

# --- Databases are pre-created by tests/setup.sql ---
# Wait for the autonomous background loop (entrypoint.sh) to generate the
# initial config on its own — NOT manually triggered. The test sidecar runs
# with POLL_INTERVAL_SECONDS=5 so this happens quickly.

log "Waiting for autonomous loop to generate initial config (no manual trigger)"

PGDOG_TOML="$PROJECT_DIR/pgdog/pgdog.toml"
USERS_TOML="$PROJECT_DIR/pgdog/users.toml"

if wait_for_pattern "$PGDOG_TOML" '\[general\]' 30; then
  pass "Autonomous loop generated pgdog.toml without manual trigger"
else
  fail "Autonomous loop did not generate pgdog.toml within 30s"
fi

# --- Test 2: Config files generated with correct content ---

log "Test 2: Config files generated with correct content"

if [ -f "$PGDOG_TOML" ]; then
  pass "pgdog.toml exists"
else
  fail "pgdog.toml does not exist"
fi

if [ -f "$USERS_TOML" ]; then
  pass "users.toml exists"
else
  fail "users.toml does not exist"
fi

# Validate pgdog.toml content
assert_contains "$PGDOG_TOML" '\[general\]' "pgdog.toml has [general] section"
assert_contains "$PGDOG_TOML" 'port = 6432' "pgdog.toml has port = 6432"
assert_contains "$PGDOG_TOML" 'passthrough_auth = "enabled_plain"' "pgdog.toml has passthrough_auth"
assert_contains "$PGDOG_TOML" '\[\[databases\]\]' "pgdog.toml has [[databases]] entries"
assert_contains "$PGDOG_TOML" 'role = "auto"' "pgdog.toml has role = auto (primary/replica auto-detected)"
assert_contains "$PGDOG_TOML" 'lsn_check_delay = 0' "pgdog.toml enables LSN checks for role detection"
assert_contains "$PGDOG_TOML" 'host = "db-test"' "pgdog.toml has host = db-test"
assert_contains "$PGDOG_TOML" 'name = "pgdog"' "pgdog.toml includes pgdog database"
assert_contains "$PGDOG_TOML" 'name = "appdb"' "pgdog.toml includes appdb database"

# Validate users.toml content
assert_contains "$USERS_TOML" '\[\[users\]\]' "users.toml has [[users]] entries"
assert_contains "$USERS_TOML" 'name="pgdog"' "users.toml has pgdog user"
assert_contains "$USERS_TOML" 'database="pgdog"' "users.toml has pgdog database"
assert_contains "$USERS_TOML" 'name="postgres"' "users.toml has postgres user"
assert_contains "$USERS_TOML" 'all_databases=true' "users.toml postgres user has all_databases"

# Security: passwords should not appear in container logs
log "Test 2b: No password leakage in container logs"

DB_LOGS=$(docker logs "$DB_CONTAINER" 2>&1 || true)
SIDECAR_LOGS=$(docker logs "$SIDECAR_CONTAINER" 2>&1 || true)

case "$DB_LOGS" in
  *"$TEST_POSTGRES_PASSWORD"*) fail "PostgreSQL password found in db container logs" ;;
  *) pass "PostgreSQL password not in db container logs" ;;
esac

case "$SIDECAR_LOGS" in
  *"$TEST_POSTGRES_PASSWORD"*) fail "PostgreSQL password found in sidecar logs" ;;
  *"$TEST_PGDOG_PASSWORD"*)   fail "PgDog password found in sidecar logs" ;;
  *) pass "No passwords leaked in sidecar logs" ;;
esac

# --- Test 2c: Generated config passes PgDog's own validation ---
#
# PgDog parses both files with deny_unknown_fields, so `pgdog configcheck`
# is authoritative validation of what the sidecar generated.

log "Test 2c: Generated config passes 'pgdog configcheck'"

if docker exec "$PGDOG_CONTAINER" pgdog --config /pgdog/pgdog.toml --users /pgdog/users.toml configcheck >/dev/null 2>&1; then
  pass "Generated pgdog.toml and users.toml pass 'pgdog configcheck'"
else
  fail "pgdog configcheck rejected the generated config"
fi

# --- Test 3: PgDog accepts connections for pre-existing databases ---

log "Test 3: PgDog accepts connections on port $PGDOG_PORT"

# Test as postgres user through PgDog
if PGPASSWORD="$TEST_POSTGRES_PASSWORD" \
  psql -h 127.0.0.1 -p "$PGDOG_PORT" -U postgres -d postgres -t -c "SELECT 1;" 2>/dev/null \
  | grep -q '^.*1.*'; then
  pass "Connection via PgDog as postgres succeeds"
else
  fail "Connection via PgDog as postgres failed"
fi

# Test as pgdog user through PgDog
if PGPASSWORD="$TEST_PGDOG_PASSWORD" \
  psql -h 127.0.0.1 -p "$PGDOG_PORT" -U pgdog -d pgdog -t -c "SELECT 1;" 2>/dev/null \
  | grep -q '^.*1.*'; then
  pass "Connection via PgDog as pgdog succeeds"
else
  fail "Connection via PgDog as pgdog failed"
fi

# Test as postgres to appdb through PgDog (postgres has all databases in its array)
if PGPASSWORD="$TEST_POSTGRES_PASSWORD" \
  psql -h 127.0.0.1 -p "$PGDOG_PORT" -U postgres -d appdb -t -c "SELECT 1;" 2>/dev/null \
  | grep -q '^.*1.*'; then
  pass "Connection via PgDog as postgres to appdb succeeds"
else
  fail "Connection via PgDog as postgres to appdb failed"
fi

# --- Test 3b: OpenMetrics endpoint serves pgdog_ metrics ---
#
# The generated config sets openmetrics_port = 9090 and namespace pgdog_.
# PgDog only starts the metrics listener from startup config — a SIGHUP
# reload never spawns it — and the main pgdog-test container booted before
# the sidecar generated anything, so a fresh instance is started with the
# generated config to verify the endpoint comes up on a cold start.

log "Test 3b: OpenMetrics endpoint"

_net=$(docker inspect "$SIDECAR_CONTAINER" --format '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null)
_metrics=""
docker rm -f pgdog-metrics-check >/dev/null 2>&1 || true
if docker run -d --name pgdog-metrics-check --network "$_net" \
  --user 1000:1000 -v "$PROJECT_DIR/pgdog:/pgdog:ro" -w /pgdog \
  "${PGDOG_IMAGE:-ghcr.io/pgdogdev/pgdog:$PGDOG_VERSION}" pgdog run >/dev/null 2>&1; then
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    _metrics=$(docker exec "$SIDECAR_CONTAINER" wget -qO- http://pgdog-metrics-check:9090/metrics 2>/dev/null) && break
    sleep 1
  done
fi
docker rm -f pgdog-metrics-check >/dev/null 2>&1 || true
case "$_metrics" in
  *pgdog_*) pass "OpenMetrics endpoint serves pgdog_-prefixed metrics" ;;
  *) fail "OpenMetrics endpoint did not return pgdog_ metrics" ;;
esac

# --- Test 4: Autonomous dynamic config update — new database AND user ---
#
# This is the core "dynamic" behavior test: it verifies the background
# polling loop in entrypoint.sh (not a manual script invocation) detects
# the new database/user and regenerates the config on its own.

log "Test 4: Autonomous loop picks up new database and user (no manual trigger)"

# Snapshot users.toml — with all_databases=true it must NOT change when
# databases are added or dropped; only pgdog.toml needs regeneration.
USERS_TOML_BEFORE="$(cat "$USERS_TOML")"

# Create a new database and user in PostgreSQL
docker exec "$DB_CONTAINER" psql -U postgres -c "CREATE USER newuser WITH PASSWORD '$TEST_NEW_USER_PASSWORD';" 2>/dev/null
docker exec "$DB_CONTAINER" psql -U postgres -c "CREATE DATABASE newdb OWNER newuser;" 2>/dev/null
pass "Created newuser and newdb in PostgreSQL"

# Wait for the autonomous loop (POLL_INTERVAL_SECONDS=5) to detect and
# regenerate the config WITHOUT any manual docker exec trigger.
if wait_for_pattern "$PGDOG_TOML" 'name = "newdb"' 30; then
  pass "Autonomous loop detected new database newdb without manual trigger"
else
  fail "Autonomous loop did not pick up newdb within 30s"
fi

# users.toml must not change — postgres has all_databases=true, so new
# databases are covered without a rewrite (fewer regenerations/reloads).
if [ "$(cat "$USERS_TOML")" = "$USERS_TOML_BEFORE" ]; then
  pass "users.toml unchanged after database add (all_databases)"
else
  fail "users.toml was rewritten after database add — all_databases should make it static"
fi

# Allow PgDog's SIGHUP reload (triggered by the autonomous loop) to complete
sleep 2

# PgDog logs "reloading configuration" when the SIGHUP lands — proves the
# signal reached the process, not just that the file changed on disk.
PGDOG_LOGS=$(docker logs "$PGDOG_CONTAINER" 2>&1 || true)
case "$PGDOG_LOGS" in
  *"reloading configuration"*) pass "PgDog logged 'reloading configuration' after autonomous update" ;;
  *) fail "PgDog did not log a configuration reload after autonomous update" ;;
esac
case "$PGDOG_LOGS" in
  *"automatic database role detection is enabled"*) pass "PgDog detected database role automatically" ;;
  *) fail "PgDog did not report automatic role detection" ;;
esac

# --- Test 5: New user connects through PgDog after dynamic update ---

log "Test 5: New user connects through PgDog after dynamic update"

# The generate-config.sh only creates users for pgdog and postgres.
# The postgres user has all_databases=true, which covers newdb,
# so we test connecting as postgres to newdb.
if PGPASSWORD="$TEST_POSTGRES_PASSWORD" \
  psql -h 127.0.0.1 -p "$PGDOG_PORT" -U postgres -d newdb -t -c "SELECT 1;" 2>/dev/null \
  | grep -q '^.*1.*'; then
  pass "Connection via PgDog as postgres to newdb succeeds"
else
  fail "Connection via PgDog as postgres to newdb failed"
fi

# --- Test 5b: Autonomous loop removes a dropped database ---
#
# PgDog pools backend connections, so a plain DROP DATABASE can fail with
# "being accessed by other users"; WITH (FORCE) terminates them first.

log "Test 5b: Autonomous loop removes dropped database (no manual trigger)"

docker exec "$DB_CONTAINER" psql -U postgres -c "DROP DATABASE newdb WITH (FORCE);" 2>/dev/null || true
docker exec "$DB_CONTAINER" psql -U postgres -c "DROP USER newuser;" 2>/dev/null || true

if docker exec "$DB_CONTAINER" psql -U postgres -t -A -c "SELECT 1 FROM pg_database WHERE datname='newdb';" 2>/dev/null | grep -q '^1$'; then
  fail "newdb still exists in PostgreSQL after DROP DATABASE ... WITH (FORCE)"
else
  pass "newdb dropped in PostgreSQL"
fi

# The autonomous loop (POLL_INTERVAL_SECONDS=5) must regenerate the config
# and shrink it — this exercises the same change-detection path as adds.
if wait_for_absence "$PGDOG_TOML" 'name = "newdb"' 30; then
  pass "Autonomous loop removed newdb from pgdog.toml"
else
  fail "newdb still present in pgdog.toml 30s after drop"
fi

if [ "$(cat "$USERS_TOML")" = "$USERS_TOML_BEFORE" ]; then
  pass "users.toml unchanged after database drop (all_databases)"
else
  fail "users.toml was rewritten after database drop — all_databases should make it static"
fi

# --- Test 6: Idempotency — no change when config is unchanged ---
#
# This tests generate-config.sh's own change-detection logic directly
# (manual invocation), which is a distinct concern from the autonomous
# loop tested above.

log "Test 6: Idempotency — no change when config is unchanged"

# Regenerate config after cleanup — first run may detect the cleanup change
docker exec "$SIDECAR_CONTAINER" /pgdog/generate-config.sh 2>&1 || true
sleep 1

# Now run again — should detect no changes. Retry a few times in case the
# background loop (POLL_INTERVAL_SECONDS=5) is holding the lock at the
# exact moment we run manually.
_idempotency_ok=0
for _attempt in 1 2 3 4 5; do
  SIDECAR_OUTPUT=$(docker exec "$SIDECAR_CONTAINER" /pgdog/generate-config.sh 2>&1 || true)
  case "$SIDECAR_OUTPUT" in
    *"No changes"*) _idempotency_ok=1; break ;;
    *"skipping this cycle"*) sleep 1 ;;
    *) break ;;
  esac
done

if [ "$_idempotency_ok" = "1" ]; then
  pass "Script correctly detects no changes on re-run"
else
  fail "Script did not report 'No changes' on re-run (output: $SIDECAR_OUTPUT)"
fi

# --- Test 6b: users.toml-only changes are installed ---
#
# Regression test: previously only pgdog.toml was compared before deciding
# to install, so a changed users.toml (e.g. rotated password) was silently
# dropped while reporting "No changes". The generate+verify runs inside a
# single exec so the background poll loop cannot restore the file in
# between.

log "Test 6b: users.toml-only change triggers update"

_users_ok=0
for _attempt in 1 2 3 4 5; do
  _out=$(docker exec -e PGDOG_PASSWORD=rotated-secret-456 "$SIDECAR_CONTAINER" sh -c \
    '/pgdog/generate-config.sh; grep -q rotated-secret-456 /pgdog/users.toml && echo INSTALLED' 2>&1)
  case "$_out" in
    *"skipping this cycle"*) sleep 1 ;;
    *"Config changed"*INSTALLED*) _users_ok=1; break ;;
    *) break ;;
  esac
done

if [ "$_users_ok" = "1" ]; then
  pass "users.toml-only change reports 'Config changed' and is installed"
else
  fail "users.toml-only change was not installed (output: $_out)"
fi

# Restore real credentials — either our run or the next poll cycle fixes
# the file; asserting absence of the marker is deterministic either way.
run_generate
if ! grep -q 'rotated-secret-456' "$USERS_TOML"; then
  pass "users.toml restored with real credentials"
else
  fail "users.toml still contains rotated credentials"
fi

# --- Test 7: Credential validation fails fast ---
#
# generate-config.sh must exit 1 with a clear error when a required
# password is missing, instead of generating a config with empty values.

log "Test 7: Credential validation"

run_generate -e POSTGRES_PASSWORD=
if [ "$RUN_RC" -eq 1 ] && printf '%s\n' "$RUN_OUT" | grep -q 'ERROR: POSTGRES_PASSWORD is not set'; then
  pass "Missing POSTGRES_PASSWORD exits 1 with clear error"
else
  fail "Missing POSTGRES_PASSWORD not handled (rc=$RUN_RC, output: $RUN_OUT)"
fi

run_generate -e PGDOG_PASSWORD=
if [ "$RUN_RC" -eq 1 ] && printf '%s\n' "$RUN_OUT" | grep -q 'ERROR: PGDOG_PASSWORD is not set'; then
  pass "Missing PGDOG_PASSWORD exits 1 with clear error"
else
  fail "Missing PGDOG_PASSWORD not handled (rc=$RUN_RC, output: $RUN_OUT)"
fi

# --- Test 8: Concurrent run detection (lock file) ---
#
# Holding the lock while invoking generate-config.sh must produce
# "skipping this cycle" and exit 0 — this is the mechanism that keeps the
# autonomous loop and manual invocations from racing on the temp files.

log "Test 8: Concurrent run detection (lock file)"

_lock_out=$(docker exec "$SIDECAR_CONTAINER" \
  sh -c 'flock /pgdog/.generate-config.lock sleep 4 & sleep 1; /pgdog/generate-config.sh' 2>&1) \
  && _lock_rc=0 || _lock_rc=$?
if [ "$_lock_rc" -eq 0 ] && printf '%s\n' "$_lock_out" | grep -q 'skipping this cycle'; then
  pass "Concurrent invocation reports 'skipping this cycle' and exits 0"
else
  fail "Lock contention not handled (rc=$_lock_rc, output: $_lock_out)"
fi

# --- Test 9: No unexpected warnings or errors in PgDog logs ---
#
# PgDog reports semantically broken — but syntactically valid — config as
# WARN lines (e.g. 'role set to "auto" but LSN checks are disabled'),
# which pgdog configcheck does not flag. Assert no WARN/ERROR beyond the
# known-benign operational notices: missing config at boot (PgDog starts
# before the sidecar writes it), random admin password, passthrough_auth
# plaintext notice, and role-detection elections.

log "Test 9: No unexpected warnings or errors in PgDog logs"

UNEXPECTED_LOGS=$(docker logs "$PGDOG_CONTAINER" 2>&1 \
  | grep -E ' (WARN|ERROR) ' \
  | grep -v 'admin password has been randomly generated' \
  | grep -v 'passthrough_auth.*plaintext' \
  | grep -v "doesn't exist, loading defaults instead" \
  | grep -v 'new primary chosen' \
  | grep -v 'database role changed in shard' || true)
if [ -z "$UNEXPECTED_LOGS" ]; then
  pass "No unexpected WARN/ERROR in PgDog logs"
else
  fail "Unexpected PgDog log lines: $UNEXPECTED_LOGS"
fi

# --- Coverage collection (kcov, best-effort) ---
#
# Runs generate-config.sh and entrypoint.sh under kcov inside a throwaway
# container on the test network (the postgres:18 image already pulled by
# the stack has apt; kcov is not packaged for Alpine). The wrapper invokes
# generate-config.sh in several modes so all branches are measured:
# unchanged config, missing credentials, lock contention, changed config,
# and the entrypoint poll loop incl. its SIGTERM trap. Produces Cobertura
# XML in ./coverage for Codecov upload in CI. Failure here is non-fatal.

log "Collecting coverage report (kcov)"

_cobertura=""
COV_CONTAINER="pgdog-coverage-run"
_net=$(docker inspect "$SIDECAR_CONTAINER" --format '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null)
if [ -n "$_net" ]; then
  docker stop "$SIDECAR_CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$COVERAGE_DIR"
  mkdir -p "$COVERAGE_DIR"
  docker rm -f "$COV_CONTAINER" >/dev/null 2>&1 || true
  if docker run -d --name "$COV_CONTAINER" --cap-add SYS_PTRACE --security-opt seccomp=unconfined \
    --network "$_net" \
    -v "$PROJECT_DIR/pgdog:/pgdog" -v "$COVERAGE_DIR:/coverage" \
    -e POSTGRES_HOST="$DB_CONTAINER" \
    -e POSTGRES_USER=postgres \
    -e POSTGRES_PASSWORD="$TEST_POSTGRES_PASSWORD" \
    -e PGDOG_PASSWORD="$TEST_PGDOG_PASSWORD" \
    -e PGDOG_USER=pgdog \
    -e PGDOG_DATABASE=pgdog \
    postgres:18 sleep 600 >/dev/null 2>&1; then
    docker exec "$COV_CONTAINER" sh -c 'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq kcov >/dev/null 2>&1' || true
    docker exec "$COV_CONTAINER" kcov --include-pattern=/pgdog /coverage /pgdog/generate-config.sh >/dev/null 2>&1 || true
    docker exec -e POSTGRES_PASSWORD= "$COV_CONTAINER" kcov --include-pattern=/pgdog /coverage /pgdog/generate-config.sh >/dev/null 2>&1 || true
    docker exec -e PGDOG_PASSWORD= "$COV_CONTAINER" kcov --include-pattern=/pgdog /coverage /pgdog/generate-config.sh >/dev/null 2>&1 || true
    docker exec "$COV_CONTAINER" sh -c 'rm -f /pgdog/pgdog.toml /pgdog/users.toml && kcov --include-pattern=/pgdog /coverage /pgdog/generate-config.sh' >/dev/null 2>&1 || true
    docker exec "$COV_CONTAINER" sh -c 'flock /pgdog/.generate-config.lock sleep 4 & sleep 1; kcov --include-pattern=/pgdog /coverage /pgdog/generate-config.sh' >/dev/null 2>&1 || true
    docker exec -e POLL_INTERVAL_SECONDS=2 "$COV_CONTAINER" timeout -s TERM 8 kcov --include-pattern=/pgdog /coverage /pgdog/entrypoint.sh >/dev/null 2>&1 || true
    docker exec "$COV_CONTAINER" sh -c 'rm -f /pgdog/pgdog.toml /pgdog/users.toml /pgdog/pgdog.toml.tmp /pgdog/users.toml.tmp /pgdog/.generate-config.lock' >/dev/null 2>&1 || true
    docker rm -f "$COV_CONTAINER" >/dev/null 2>&1 || true
  fi
  _cobertura=$(find "$COVERAGE_DIR" -name cobertura.xml -print -quit 2>/dev/null)
fi

if [ -n "$_cobertura" ] && [ -f "$_cobertura" ]; then
  printf '  \033[32m✓\033[0m Coverage report collected: %s\n' "$_cobertura"
else
  printf '  \033[33m!\033[0m Coverage collection skipped or failed (non-fatal)\n'
fi

# --- Summary ---

log "Test Summary"
printf '\n  \033[32mPassed: %d\033[0m\n' "$PASS"
printf '  \033[31mFailed: %d\033[0m\n' "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
