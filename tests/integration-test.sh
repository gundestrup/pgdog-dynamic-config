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
#   8. Idempotency — manually re-running with no changes reports "No changes".
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
assert_contains "$PGDOG_TOML" 'role = "primary"' "pgdog.toml has role = primary"
assert_contains "$PGDOG_TOML" 'host = "db-test"' "pgdog.toml has host = db-test"
assert_contains "$PGDOG_TOML" 'name = "pgdog"' "pgdog.toml includes pgdog database"
assert_contains "$PGDOG_TOML" 'name = "appdb"' "pgdog.toml includes appdb database"

# Validate users.toml content
assert_contains "$USERS_TOML" '\[\[users\]\]' "users.toml has [[users]] entries"
assert_contains "$USERS_TOML" 'name="pgdog"' "users.toml has pgdog user"
assert_contains "$USERS_TOML" 'database="pgdog"' "users.toml has pgdog database"
assert_contains "$USERS_TOML" 'name="postgres"' "users.toml has postgres user"
assert_contains "$USERS_TOML" 'databases=\[' "users.toml has databases array for postgres"
assert_contains "$USERS_TOML" '"appdb"' "users.toml postgres databases array includes appdb"

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

# --- Test 4: Autonomous dynamic config update — new database AND user ---
#
# This is the core "dynamic" behavior test: it verifies the background
# polling loop in entrypoint.sh (not a manual script invocation) detects
# the new database/user and regenerates the config on its own.

log "Test 4: Autonomous loop picks up new database and user (no manual trigger)"

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

# Verify the new database appears in users.toml postgres databases array
assert_contains "$USERS_TOML" '"newdb"' "users.toml postgres databases array includes newdb"

# Allow PgDog's SIGHUP reload (triggered by the autonomous loop) to complete
sleep 2

# --- Test 5: New user connects through PgDog after dynamic update ---

log "Test 5: New user connects through PgDog after dynamic update"

# The generate-config.sh only creates users for pgdog and postgres.
# The postgres user's databases array should include newdb,
# so we test connecting as postgres to newdb.
if PGPASSWORD="$TEST_POSTGRES_PASSWORD" \
  psql -h 127.0.0.1 -p "$PGDOG_PORT" -U postgres -d newdb -t -c "SELECT 1;" 2>/dev/null \
  | grep -q '^.*1.*'; then
  pass "Connection via PgDog as postgres to newdb succeeds"
else
  fail "Connection via PgDog as postgres to newdb failed"
fi

# Clean up the test database and user
docker exec "$DB_CONTAINER" psql -U postgres -c "DROP DATABASE newdb;" 2>/dev/null || true
docker exec "$DB_CONTAINER" psql -U postgres -c "DROP USER newuser;" 2>/dev/null || true

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

# --- Coverage collection (kcov, best-effort) ---
#
# Runs generate-config.sh under kcov inside a throwaway container on the
# test network (the postgres:18 image already pulled by the stack has apt;
# kcov is not packaged for Alpine). Produces Cobertura XML in ./coverage
# for Codecov upload in CI. Failure here is non-fatal.

log "Collecting coverage report (kcov)"

_cobertura=""
_net=$(docker inspect "$SIDECAR_CONTAINER" --format '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null)
if [ -n "$_net" ]; then
  docker stop "$SIDECAR_CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$COVERAGE_DIR"
  mkdir -p "$COVERAGE_DIR"
  docker run --rm --cap-add SYS_PTRACE --security-opt seccomp=unconfined \
    --network "$_net" \
    -v "$PROJECT_DIR/pgdog:/pgdog" -v "$COVERAGE_DIR:/coverage" \
    -e POSTGRES_HOST="$DB_CONTAINER" \
    -e POSTGRES_USER=postgres \
    -e POSTGRES_PASSWORD="$TEST_POSTGRES_PASSWORD" \
    -e PGDOG_PASSWORD="$TEST_PGDOG_PASSWORD" \
    -e PGDOG_USER=pgdog \
    -e PGDOG_DATABASE=pgdog \
    postgres:18 sh -c 'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq kcov >/dev/null 2>&1 && kcov --include-pattern=/pgdog /coverage /pgdog/generate-config.sh; rm -f /pgdog/pgdog.toml /pgdog/users.toml /pgdog/pgdog.toml.tmp /pgdog/users.toml.tmp' >/dev/null 2>&1 || true
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
