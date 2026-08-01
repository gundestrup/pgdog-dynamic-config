# AI_INSTRUCTIONS.md

> **Canonical instruction file for AI coding assistants working on this repository.**
> This file is the single source of truth for project conventions, architecture,
> and testing requirements. AI tools (Claude, Windsurf/Devin, Cursor, etc.)
> should read this file first and follow its guidance throughout any session.

---

## Project Overview

`pgdog-dynamic-config` is a lightweight Docker sidecar that dynamically
generates PgDog's `pgdog.toml` and `users.toml` configuration files by
discovering PostgreSQL databases at runtime. It reloads PgDog via SIGHUP
when the configuration changes.

**Stack:** Shell scripts (`/bin/sh`), Docker, Docker Compose, Alpine Linux.

**No compiled code, no framework, no language runtime** — just shell + Docker.

---

## Repository Structure

```text
.
├── docker-compose.yml              # Production compose stack (db + pgdog + sidecar)
├── .env.example                    # Template for environment variables
├── .dockerignore                   # Root-level Docker build context exclusions
├── .gitignore
├── README.md                       # User-facing documentation
├── CHANGELOG.md                    # Keep a Changelog format
├── LICENSE                         # AGPL v3
├── AI_INSTRUCTIONS.md              # THIS FILE — read first
├── .github/
│   └── workflows/
│       └── ci.yml                  # GitHub Actions: ShellCheck + markdownlint + integration tests
├── pgdog/
│   ├── generate-config.sh          # Core: discovers DBs, generates TOML, reloads PgDog
│   ├── entrypoint.sh               # Polling loop: runs generate-config.sh every N seconds
│   ├── pgdog-dynamic-config.Dockerfile  # Sidecar image (alpine:3.22 + postgresql-client + tini)
│   ├── .dockerignore               # Redundant — root .dockerignore is authoritative; safe to remove
│   └── .gitkeep
└── tests/
    ├── integration-test.sh         # Integration test suite (33 assertions)
    ├── docker-compose.test.yml     # Test compose (postgres:18, pgdog:main, ports 5433/6433)
    └── setup.sql                   # Pre-creates pgdog, appdb databases and users for tests
```

---

## Architecture: How It Works

1. **`entrypoint.sh`** runs an infinite loop: call `generate-config.sh`, then
   `sleep $POLL_INTERVAL_SECONDS` (default 300 = 5 min).
2. **`generate-config.sh`** connects to PostgreSQL via `psql`, lists all
   non-template databases, generates `pgdog.toml` and `users.toml` into
   `.tmp` files, then atomically moves them into place **only if changed**
   (compared with `cmp -s`). If changed, sends `SIGHUP` to PgDog via
   `pkill -HUP pgdog` (works because of `pid: "service:pgdog"` in compose).
3. **PgDog** reads config from its working directory (`/pgdog`), which is
   the shared volume mounted read-only in the PgDog container and
   read-write in the sidecar.
4. **SIGHUP reload** requires PgDog and the sidecar to run as the **same
   UID** (default 1000) so the sidecar can signal PgDog's process. They
   also share a PID namespace via `pid: "service:pgdog"`.

### Key Design Decisions

- **POSIX `sh`, not bash** — all scripts use `#!/bin/sh` for Alpine compatibility.
- **Atomic config updates** — write to `.tmp`, then `mv` to final path to
  prevent PgDog from reading a half-written file.
- **Idempotency** — `cmp -s` compares old and new configs; if identical,
  no reload is triggered.
- **Lock file** — `flock` on `/pgdog/.generate-config.lock` prevents
  concurrent runs from racing on temp files.
- **Passthrough auth** — PgDog uses `passthrough_auth = "enabled_plain"`,
  meaning passwords in `users.toml` must match the PostgreSQL backend
  passwords exactly. The sidecar does not manage PostgreSQL users.

---

## Environment Variables

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `POSTGRES_PASSWORD` | Yes | — | PostgreSQL superuser password |
| `PGDOG_PASSWORD` | Yes | — | Password for the `pgdog` user (must match PG) |
| `POSTGRES_HOST` | No | `db` | PostgreSQL hostname |
| `POSTGRES_USER` | No | `postgres` | PostgreSQL admin user |
| `PGDOG_USER` | No | `pgdog` | PgDog user name in `users.toml` |
| `PGDOG_DATABASE` | No | `pgdog` | Database for the pgdog user (must exist in PG) |
| `POLL_INTERVAL_SECONDS` | No | `300` | Seconds between config regeneration checks |
| `USER_ID` | No | `1000` | UID for sidecar and PgDog containers |
| `GROUP_ID` | No | `1000` | GID for sidecar and PgDog containers |
| `TZ` | No | `UTC` | Timezone for PostgreSQL container |

---

## Coding Conventions

- **Shell scripts:** POSIX `sh` only (`#!/bin/sh`). No bashisms. Use
  `$()` not backticks. Quote all variable expansions. Use `set -e`.
- **No comments unless explicitly requested** — follow the user's preference.
- **Docker images:** Pin to specific versions (e.g. `alpine:3.22`,
  `postgres:18.4-alpine3.22`). Never use `:latest` in production compose.
- **Test compose:** Uses `:main` for PgDog and `postgres:18` (unpinned)
  intentionally, to catch upstream breaking changes early.
- **TOML generation:** Hand-rolled `echo` statements. No TOML library
  (keep the sidecar minimal — Alpine + `postgresql-client` + `tini` only).
- **Security:** Never log passwords. The script must not echo
  `POSTGRES_PASSWORD` or `PGDOG_PASSWORD` to stdout/stderr.
- **File naming:** No trailing spaces in filenames. Use kebab-case for
  compose files, lowercase with dashes for Dockerfiles.

---

## Testing

### Running integration tests

```sh
./tests/integration-test.sh
```

This spins up a full Docker Compose stack on ports **5433/6433** (to
avoid conflicts with production), runs 33 assertions, and tears down on
exit. No manual setup required.

### What the tests cover

1. All services start and become healthy.
2. **Autonomous background loop** generates initial config without manual
   trigger (test sidecar uses `POLL_INTERVAL_SECONDS=5`).
3. Config files have correct content for multiple pre-existing databases.
4. No passwords leak in container logs.
5. PgDog accepts connections for `postgres`, `pgdog`, and `appdb`.
6. **Autonomous loop** detects a new database+user created at runtime and
   reloads PgDog — without any manual `docker exec` trigger.
7. New database is accessible through PgDog after the autonomous update.
8. Idempotency — manual re-run with no changes reports "No changes".

### Critical testing rule

**Never test the dynamic function by only manually invoking
`generate-config.sh`.** The autonomous polling loop (`entrypoint.sh`) is
the core feature and must be tested by waiting for it to detect changes
on its own. Use `wait_for_pattern` to poll the output file rather than
calling the script directly.

### Test credentials (hardcoded in test compose, not production)

- PostgreSQL: `test-pg-pass-123`
- PgDog user: `test-pgdog-pass-123`
- App user: `test-app-pass-123`
- New dynamic user: `test-new-pass-123`

### CI (GitHub Actions)

The workflow in `.github/workflows/ci.yml` runs on every push and pull
request to `main`/`master` with three parallel jobs:

- **ShellCheck** — lints all shell scripts for POSIX compliance and common errors.
- **markdownlint** — lints `README.md`, `CHANGELOG.md`, and `AI_INSTRUCTIONS.md`.
- **Integration tests** — runs the full `./tests/integration-test.sh` suite
  on an Ubuntu runner with Docker Compose. Dumps container logs on failure.

All three jobs must pass for a PR to be mergeable.

---

## Common Pitfalls

- **PostgreSQL 18+ volume mount:** PGDATA changed from
  `/var/lib/postgresql/data` to `/var/lib/postgresql/18/docker`. Mount
  to `/var/lib/postgresql` (not `/data`) and do not set `user:` on the
  `db` service (PG 18+ entrypoint needs root for `chmod`).
- **SIGHUP permissions:** PgDog must run as the same UID as the sidecar
  (default 1000). If PgDog runs as root and the sidecar as UID 1000,
  `pkill -HUP pgdog` silently fails.
- **`psql -t` adds leading whitespace:** Always use `psql -t -A` to get
  clean unaligned output without leading spaces.
- **`set -e` in entrypoint.sh:** A bare command in a `while` loop will
  exit the script on failure. Use `|| echo "..."` to catch transient
  failures and continue the loop.
- **Concurrent runs:** The background loop and a manual `docker exec`
  can overlap. The `flock` lock prevents corruption, but tests should
  retry on "skipping this cycle" output.

---

## PgDog Upstream Reference

- **Repository:** <https://github.com/pgdogdev/pgdog>
- **Docs:** <https://docs.pgdog.dev/configuration/>
- **Upstream compose:** <https://github.com/pgdogdev/pgdog/blob/main/docker-compose.yml>
- **Config reload:** SIGHUP or `RELOAD` admin command
- **Config files:** `pgdog.toml` (databases, general settings) and
  `users.toml` (user credentials, database access lists)

---

## Instructions for AI Assistants

### Claude (CLAUDE.md)

If creating a `CLAUDE.md` file for this project, it should contain:

```markdown
# CLAUDE.md

Read AI_INSTRUCTIONS.md first — it is the canonical instruction file for
this repository. Follow its coding conventions, testing rules, and
architecture notes for all changes.

Key points:
- POSIX sh only (no bashisms). Scripts run on Alpine Linux.
- Test the autonomous polling loop, not just manual script invocation.
- Never log passwords. Pin Docker image versions in production.
- Run `./tests/integration-test.sh` to verify all changes.
```

### Windsurf / Devin (.windsurf/workflows or .devin/workflows)

If creating Windsurf or Devin workflows, reference this document.
Workflow files go in `.windsurf/workflows/` or `.devin/workflows/` as
`.md` files with YAML frontmatter:

```markdown
---
description: Run integration tests for pgdog-dynamic-config
---
1. Read AI_INSTRUCTIONS.md for project context and testing rules.
2. Run `./tests/integration-test.sh` from the project root.
3. All 33 assertions must pass with 0 failures.
4. If tests fail, check the "Common Pitfalls" section of AI_INSTRUCTIONS.md.
```

```markdown
---
description: Add a new environment variable to the sidecar
---
1. Read AI_INSTRUCTIONS.md for architecture and conventions.
2. Add the variable to `pgdog/generate-config.sh` with a default:
   `VAR_NAME="${VAR_NAME:-default}"`
3. Add to `.env.example` with a comment.
4. Add to `docker-compose.yml` environment section for the sidecar.
5. Add to `tests/docker-compose.test.yml` if needed for tests.
6. Document in `README.md` environment variables table.
7. Add a CHANGELOG.md entry under "Fixed" or "Added".
8. Run `./tests/integration-test.sh` to verify.
```

### General rules for all AI tools

- **Read `AI_INSTRUCTIONS.md` before making any changes.**
- **Run `./tests/integration-test.sh` after any code change.**
- **Update `CHANGELOG.md` for every change** (Keep a Changelog format).
- **Keep the sidecar minimal** — no extra packages beyond
  `postgresql-client`, `tini`, and base Alpine.
- **Do not add comments to code** unless explicitly requested.
- **Prefer minimal edits** — fix root causes, not symptoms.

### AGENTS.md (Devin native format)

If creating an `AGENTS.md` file for Devin, it should mirror the key
points from `AI_INSTRUCTIONS.md`:

```markdown
# AGENTS.md

Read AI_INSTRUCTIONS.md for full project context. Key rules:
- POSIX sh only (no bashisms). Scripts run on Alpine Linux.
- Test the autonomous polling loop, not just manual script invocation.
- Never log passwords. Pin Docker image versions in production.
- Run ./tests/integration-test.sh to verify all changes.
- Update CHANGELOG.md for every change.
- Keep the sidecar minimal: postgresql-client + tini + base Alpine only.
```
