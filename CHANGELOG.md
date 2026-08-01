# Changelog

All notable changes to `pgdog-dynamic-config` are documented in this file.

## [0.2.0] - 2026-08-01

Refactored the sidecar for PostgreSQL 18+ compatibility, added a full
integration test suite based on PgDog's upstream Docker Compose pattern,
and fixed several bugs in the config generation script and polling loop.

### Fixed

- **`pgdog/generate-config.sh`**
  - Removed the stray terminal prompt line that had been accidentally pasted into the top of the file.
  - Removed debug `echo` statements that logged PostgreSQL and PgDog passwords to stdout.
  - Added `POSTGRES_HOST` environment variable (defaults to `db`).
  - Added `PGDOG_USER` and `PGDOG_DATABASE` environment variables (both default to `pgdog`).
  - Quoted all variables and redirect targets to handle paths or names with spaces safely.
  - Added an `EXIT` trap to remove temporary `.tmp` files.
  - Rewrote database iteration with `while IFS= read -r` so database names containing spaces are handled correctly.
  - Populated the `postgres` user `databases` TOML array with all discovered databases (previously always empty).
  - Added explicit `role = "primary"` to each `[[databases]]` entry, matching PgDog's example configuration.
  - Added `-A` flag to `psql` to strip leading whitespace from database names (was causing `name = " postgres"` in generated config).
  - Fixed `POSTGRES_USER` being documented but unused — the script previously hardcoded `postgres` for both the admin connection and the generated `users.toml` entry, silently ignoring the configured value.
  - Added validation that `POSTGRES_PASSWORD` and `PGDOG_PASSWORD` are set before running, failing fast with a clear error instead of generating a config with empty passwords.
  - Added a `flock`-based lock file to prevent concurrent runs (e.g. the background poll loop and a manual invocation overlapping) from racing on the shared temp files.

- **`pgdog/entrypoint.sh`**
  - Fixed the polling loop crashing the entire sidecar container on any transient `generate-config.sh` failure (e.g. PostgreSQL briefly unreachable); failures are now logged and retried on the next cycle instead.
  - Added `POLL_INTERVAL_SECONDS` environment variable (defaults to `300`) to make the polling interval configurable, enabling integration tests to exercise the autonomous loop without waiting 5 minutes.

- **`pgdog/pgdog-dynamic-config.Dockerfile`**
  - Renamed the Dockerfile to remove the trailing space in the filename.
  - Pinned the base image to `alpine:3.22` instead of `alpine:latest`.
  - Added `tini` for proper PID 1 and signal reaping.
  - Created a non-root `pgdog` user (uid `1000`) and set `USER pgdog`.
  - Added a new `pgdog/entrypoint.sh` for graceful `SIGTERM` handling.
  - Updated `COPY` paths to use `pgdog/` prefix since build context changed to project root.

- **`docker-compose.yml`**
  - Replaced the invalid `pgdog/docker-composer.yml` fragment with a complete, root-level `docker-compose.yml`.
  - Added `services:` wrapper and fixed compose file structure.
  - Added `healthcheck` conditions to `depends_on` so services wait for PostgreSQL and PgDog to be ready.
  - Added `restart: unless-stopped` to all services.
  - Added `pid: "service:pgdog"` to the sidecar so `pkill -HUP pgdog` can signal PgDog across containers.
  - Added `user` and consistent `USER_ID`/`GROUP_ID` defaults for the sidecar and PgDog to align volume permissions.
  - Updated PostgreSQL image to `18.4-alpine3.22` and fixed volume mount for PG 18+ (`/var/lib/postgresql` instead of `/var/lib/postgresql/data`).
  - Removed `user:` directive from `db` service (PG 18+ entrypoint requires root for `chmod /var/run/postgresql`).
  - Updated log directory path for PG 18+ volume layout change.
  - Updated build context to project root (`.`) with `dockerfile: pgdog/pgdog-dynamic-config.Dockerfile`.
  - Pinned PgDog image to `v0.1.50` for production stability.

- **`README.md`**
  - Expanded environment variable documentation to include all optional and required variables.
  - Replaced the inline Docker Compose example with the corrected `docker-compose.yml` from the project root.
  - Documented the `pid: "service:pgdog"` reload fix and volume permission requirements.
  - Fixed a markdownlint warning by demoting the example compose section to a second-level heading.
  - Added a quick start section referencing the new `.env.example`.
  - Added notes that `PGDOG_DATABASE` must exist in PostgreSQL and that `PGDOG_PASSWORD` must match the backend password when using passthrough auth.
  - Added a security note explaining that `passthrough_auth = "enabled_plain"` sends passwords in plain text.
  - Updated testing section to reflect PgDog upstream-based test compose, multiple databases, and dynamic user/db test.

### Added

- **`pgdog/entrypoint.sh`** — a minimal wrapper that traps `SIGTERM` so the sidecar shuts down gracefully when `docker compose down` is run.
- **`pgdog/.dockerignore`** — excludes generated TOML, `.tmp`, and log files from the Docker build context (now at project root as `.dockerignore`).
- **`docker-compose.yml`** — a complete, runnable compose stack at the repository root.
- **`.env.example`** — a template for environment variables used by the compose stack.
- **`CHANGELOG.md`** — this file.
- **`tests/integration-test.sh`** — integration tests that spin up a test Docker Compose stack (based on PgDog's upstream pattern) and verify service health, config generation, password security, PgDog connectivity, and idempotency. Critically, the dynamic config update tests exercise the **autonomous background polling loop** (`entrypoint.sh` with `POLL_INTERVAL_SECONDS=5`) rather than manually invoking `generate-config.sh`, confirming the sidecar actually detects and applies new databases/users on its own.
- **`tests/docker-compose.test.yml`** — test-specific compose file using `postgres:18` and `ghcr.io/pgdogdev/pgdog:main` (latest) with pre-created databases via `setup.sql`.
- **`tests/setup.sql`** — SQL init script that pre-creates `pgdog`, `appdb` databases and `pgdog`, `appuser` users for integration testing.
- **`.dockerignore`** — root-level Docker build context exclusions.
- **`AI_INSTRUCTIONS.md`** — canonical instruction file for AI coding assistants (Claude, Windsurf/Devin, Cursor). Documents architecture, coding conventions, testing rules, common pitfalls, and templates for `CLAUDE.md`, `AGENTS.md`, and Windsurf workflows.
- **`.gitignore`** — added `pgdog/.generate-config.lock` to exclude the runtime lock file from version control.

### Removed

- `pgdog/docker-composer.yml` (invalid fragment, replaced by root `docker-compose.yml`).
- `pgdog/pgdog-dynamic-config.Dockerfile` (the old filename had a trailing space, replaced by the same name without the trailing space).

## [0.1.0] - 2026-02-25

Initial release — deployed and tested.