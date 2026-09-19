# pgdog-dynamic-config

[![codecov](https://codecov.io/gh/gundestrup/pgdog-dynamic-config/branch/main/graph/badge.svg)](https://codecov.io/gh/gundestrup/pgdog-dynamic-config)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)
![Shell](https://img.shields.io/badge/shell-sh-green)
![PgDog](https://img.shields.io/badge/Made_for-PgDog-blue)
![Status](https://img.shields.io/badge/status-active-success)
[![DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/gundestrup/pgdog-dynamic-config)
[![CI](https://github.com/gundestrup/pgdog-dynamic-config/actions/workflows/ci.yml/badge.svg)](https://github.com/gundestrup/pgdog-dynamic-config/actions/workflows/ci.yml)
[![Dockerfile](https://img.shields.io/badge/Docker-Dockerfile-2496ED?logo=docker)](pgdog/pgdog-dynamic-config.Dockerfile)
[![CodeFactor](https://www.codefactor.io/repository/github/gundestrup/pgdog-dynamic-config/badge)](https://www.codefactor.io/repository/github/gundestrup/pgdog-dynamic-config)
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=gundestrup_pgdog-dynamic-config&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=gundestrup_pgdog-dynamic-config)

A lightweight sidecar container for PgDog that dynamically discovers PostgreSQL databases and regenerates `pgdog.toml` and `users.toml` based on environment variables.

The container runs alongside PgDog, monitors database changes, updates configuration files, and triggers a PgDog reload when necessary.

---

## 🧠 Overview

`pgdog-dynamic-config` is designed to simplify configuration management for PgDog in dynamic PostgreSQL environments.

Instead of manually maintaining database and user definitions, this sidecar:

- Connects to PostgreSQL
- Discovers all non-template databases
- Regenerates PgDog configuration files
- Injects credentials from environment variables
- Reloads PgDog when configuration changes are detected
- The container is intended to run continuously as part of a Docker Compose stack.

## 🚀 Features

- Automatically discovers all non-template PostgreSQL databases
- Regenerates pgdog.toml and users.toml
- Injects passwords from environment variables
- Runs every `POLL_INTERVAL_SECONDS` (defaults to 5 minutes)
- Reloads PgDog when configuration changes
- Runs as a lightweight sidecar container
- Depends on passthrough_auth for authentication
- Requires the postgres user to have access to all databases
- Validates required credentials are set before generating config
- Uses a lock file to prevent concurrent runs from corrupting output

---

## 📁 Directory Structure

The sidecar expects PgDog configuration files to be located in:
 `./pgdog/`

This directory must contain:

- `pgdog.toml` (generated)
- `users.toml` (generated)

The sidecar writes both files directly into this directory.
This directory must be mounted as a volume in both the PgDog and sidecar containers.

---

## 🔧 Environment Variables

The sidecar is configured through the following environment variables:

### Required

- `POSTGRES_PASSWORD` — Password for the PostgreSQL superuser.
- `PGDOG_PASSWORD` — Password used by the `pgdog` user in `users.toml`.

### Optional

- `POSTGRES_HOST` — Hostname or IP of the PostgreSQL server. Defaults to `db`.
- `POSTGRES_USER` — PostgreSQL admin user. Defaults to `postgres`.
- `PGDOG_USER` — Name of the PgDog user in `users.toml`. Defaults to `pgdog`.
- `PGDOG_DATABASE` — PgDog database cluster the `pgdog` user connects to. Defaults to `pgdog`; this database must exist in PostgreSQL.

### Runtime / volume permissions

- `USER_ID` — User ID the sidecar and PgDog run as (defaults to `1000`).
- `GROUP_ID` — Group ID the sidecar and PgDog run as (defaults to `1000`).
- `TZ` — Timezone for the PostgreSQL container. Defaults to `UTC`.
- `POLL_INTERVAL_SECONDS` — Seconds between automatic config regeneration checks. Defaults to `300` (5 minutes).

```yaml
environment:
  POSTGRES_HOST: db
  POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
  PGDOG_PASSWORD: ${PGDOG_PASSWORD}
  PGDOG_USER: ${PGDOG_USER:-pgdog}
  PGDOG_DATABASE: ${PGDOG_DATABASE:-pgdog}
```

### Quick start

1. Copy `.env.example` to `.env` and fill in the passwords.
2. Make sure `./pgdog` is owned by the same UID/GID you set in `USER_ID`/`GROUP_ID` (default `1000:1000`) so the sidecar can write the generated TOML files.
3. Run `./scripts/compose.sh up -d` so the shared PgDog version is loaded from `versions.env`.

The pinned PgDog version is maintained in `versions.env`. Before a release, check and update it with:

```sh
./scripts/update-pgdog-version.sh --check
./scripts/update-pgdog-version.sh
```

## 🧩 Example Docker Compose Setup

A complete, ready-to-run stack is in `docker-compose.yml` in the project root:

- PostgreSQL with logging enabled
- PgDog
- `pgdog-dynamic-config` sidecar

The key points for the sidecar are:

- It shares the `./pgdog` volume with PgDog.
- It waits for PostgreSQL to be healthy.
- It joins PgDog's PID namespace (`pid: "service:pgdog"`) so `pkill -HUP pgdog` can trigger a configuration reload.
- Both PgDog and the sidecar run under the same `USER_ID`/`GROUP_ID` so the volume is writable and signal permissions work.

```yaml
services:
  db:
    container_name: db
    image: postgres:18.4-alpine3.22
    volumes:
      - ./data:/var/lib/postgresql
      - ./logs:/var/lib/postgresql/logs
    ports:
      - "5432:5432"
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-postgres}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      TZ: ${TZ:-UTC}
    command: >
      postgres
        -c logging_collector=on
        -c log_directory='/var/lib/postgresql/logs'
        -c log_filename='postgresql-%Y-%m-%d_%H%M%S.log'
        -c log_min_duration_statement=500
        -c log_line_prefix='%m [%p] %q%u@%d '
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER}"]
      interval: 10s
      timeout: 3s
      retries: 5
      start_period: 5s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    restart: unless-stopped

  pgdog:
    image: ghcr.io/pgdogdev/pgdog:${PGDOG_VERSION}
    container_name: pgdog
    user: ${USER_ID:-1000}:${GROUP_ID:-1000}
    ports:
      - "6432:6432"
    volumes:
      - ./pgdog:/pgdog:ro
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "pg_isready", "-h", "localhost", "-p", "6432"]
      interval: 10s
      timeout: 3s
      retries: 5
      start_period: 5s
    restart: unless-stopped

  pgdog-dynamic-config:
    build:
      context: .
      dockerfile: pgdog/pgdog-dynamic-config.Dockerfile
    container_name: pgdog-dynamic-config
    user: ${USER_ID:-1000}:${GROUP_ID:-1000}
    environment:
      POSTGRES_HOST: db
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      PGDOG_PASSWORD: ${PGDOG_PASSWORD}
      PGDOG_USER: ${PGDOG_USER:-pgdog}
      PGDOG_DATABASE: ${PGDOG_DATABASE:-pgdog}
    volumes:
      - ./pgdog:/pgdog
    depends_on:
      db:
        condition: service_healthy
      pgdog:
        condition: service_started
    pid: "service:pgdog"
    restart: unless-stopped
```

## 🔐 Authentication Requirements

This setup assumes:

- PgDog is configured with `passthrough_auth`.
- The `postgres` user has access to all databases.
- The sidecar can connect to PostgreSQL using superuser credentials.
- A database named after `PGDOG_DATABASE` (default `pgdog`) exists in PostgreSQL for the `pgdog` user.
- The `PGDOG_PASSWORD` matches the PostgreSQL password for the `pgdog` user, because `passthrough_auth` forwards the client password to the backend.

> **Security note:** `passthrough_auth = "enabled_plain"` sends passwords in plain text. Use this only on trusted networks, or enable TLS in PgDog and use `enabled` instead.

## 🐶 PgDog

For more information about PgDog, visit:

<https://github.com/pgdogdev/pgdog>

## 🧪 Tests

Integration tests use a test-specific Docker Compose (`tests/docker-compose.test.yml`) based on [PgDog's upstream compose pattern](https://github.com/pgdogdev/pgdog/blob/main/docker-compose.yml):

- `postgres:18` (latest 18.x)
- `ghcr.io/pgdogdev/pgdog:${PGDOG_VERSION}` by default, loaded from `versions.env`
- `ghcr.io/pgdogdev/pgdog:main` in the CI matrix (latest development version, to catch breaking changes)
- `pgdog-dynamic-config` sidecar (built from `./pgdog`)

The tests verify:

- All services start and become healthy.
- The **autonomous background loop** (`entrypoint.sh`) generates the initial config on its own — not via manual script invocation. The test sidecar runs with `POLL_INTERVAL_SECONDS=5` for fast cycles.
- `pgdog.toml` and `users.toml` are generated with correct content for multiple pre-existing databases.
- No passwords are leaked in container logs.
- PgDog accepts connections for `postgres`, `pgdog`, and additional databases.
- The autonomous loop detects a new database and user created at runtime and regenerates the config + reloads PgDog via SIGHUP, without any manual trigger.
- New database is accessible through PgDog immediately after the autonomous update.
- Idempotency — manually re-running the script with no changes reports "No changes".

### Running tests

```sh
./tests/integration-test.sh
```

The script starts the test stack (on ports `5433`/`6433` to avoid conflicts with production), runs all checks, and tears everything down on exit. No manual setup is required.

### Prerequisites

- Docker and Docker Compose installed.
- Ports `5433` and `6433` available on the host.
- `./pgdog` directory writable by UID `1000`.

## 📜 License

This project is licensed under the AGPL v3 license. See the [LICENSE](LICENSE) file for details.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for a detailed list of changes.
