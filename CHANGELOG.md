# Changelog

All notable changes to `pgdog-dynamic-config` are documented in this file.

## [Unreleased]

### Added

- `.devin/config.json` with Devin CLI project permissions allow-listing the quality-gate commands (Semgrep, ShellCheck, Docker, test/helper scripts)
- `.sonarcloud.properties` classifying `tests/` as test code and excluding `coverage/`, `test-results/`, `data/`, `logs/`, and generated `pgdog/` artifacts — so SonarCloud AutoScan does not count test infrastructure or generated files as production code.
- `scripts/hooks/pre-commit` running ShellCheck on all shell scripts; enable with `git config core.hooksPath scripts/hooks`.
- `.vscode/settings.json` is now tracked — it carries the project setting `semgrep.scan.onlyGitDirty: false` (scan the whole tree, not just dirty files).
- Codecov coverage badge in `README.md`.
- Codecov integration: the integration test now produces a Cobertura coverage report via `kcov` (run in a throwaway `postgres:18` container on the test network, since `kcov` is not packaged for Alpine) written to `coverage/`, and a JUnit XML report of all assertions in `test-results/junit.xml`. CI uploads both to Codecov on the pinned matrix leg — coverage via `codecov/codecov-action` (pinned SHA) and test results via `codecov-cli`. Added `codecov.yml` with status thresholds.

### Changed

- Bumped the pinned PgDog version to `v0.1.59` in `versions.env` to match the latest upstream release.
- Corrected the `shell-bash` badge in `README.md` to `shell-sh` — the scripts are POSIX `sh`, not Bash.
- `versions.env` file mode changed from `600` to `644` — it is not a secret.
- Updated GitHub Actions to Node 24 runtimes: `actions/checkout` to v7.0.1 and `DavidAnson/markdownlint-cli2-action` to v24.2.0 (still pinned to full commit SHAs).

### Fixed

- Added an explicit `permissions: contents: read` block to the CI workflow so the `GITHUB_TOKEN` is limited to read-only access (CodeQL `actions/missing-workflow-permissions`, 5 alerts).
- `AGENTS.md` repository-structure section listed removed files (`pgdog/.dockerignore`, `pgdog/.gitkeep`) and the CI job list omitted the Semgrep job — both corrected.
- Fixed `README.md` markdownlint errors introduced by the Codecov badge (double blank line, missing trailing newline).
- Fixed integration test teardown failing on CI runners with "Permission denied": generated TOML files owned by UID 1000 are now removed inside the sidecar container before `docker compose down`.

## [0.2.3] - 2026-09-11

### Added

- Added a SonarCloud quality gate badge to `README.md`.

### Fixed

- Passed the GitHub Actions token to the PgDog release check so CI can query the public GitHub API through the GitHub CLI.
- Replaced `chmod 777` on the `pgdog` directory in CI with `sudo chown 1000:1000` to avoid granting world-writable permissions (SonarCloud `githubactions:S2612`).
- Pinned the Semgrep install in CI to `semgrep==1.176.1` with `--only-binary :all:` so dependency versions are locked and no setup scripts execute during installation (SonarCloud `githubactions:S8541`, `githubactions:S8544`).

## [0.2.2] - 2026-09-10

### Added

- Added README badges for DeepWiki documentation, GitHub Actions CI, the sidecar Dockerfile, and CodeFactor analysis.
- Added Semgrep configuration and a Semgrep security scan to the GitHub Actions workflow.
- Added shared PgDog version and release-check scripts in `versions.env` and `scripts/`.

### Changed

- Pinned GitHub Actions dependencies to full commit SHAs in `.github/workflows/ci.yml` to prevent mutable action references.
- Centralized the pinned PgDog version in `versions.env`, updated Compose and tests to use it, and added CI coverage for both the pinned release and `main`.
- Added CI validation that checks the pinned version against the latest upstream PgDog release.
- **`AI_INSTRUCTIONS.md` → `AGENTS.md`** — renamed the AI instruction file to `AGENTS.md` following the [agents.md](https://agents.md) open convention. `AGENTS.md` is now the single source of truth for all coding agents working on this project. Updated all references in `.github/workflows/ci.yml` and within the file itself.

## [0.2.1] - 2026-08-01

Linting and cleanup pass. No functional changes — the sidecar behavior is
unchanged. All changes are stylistic or remove dead code, and keep the
repository passing ShellCheck and markdownlint cleanly.

### Changed

- **`pgdog/generate-config.sh`**
  - Grouped the per-database `echo` statements into a single redirection block, reducing repeated `>> "$TMP"` writes without changing output.

- **`README.md`**
  - Applied markdownlint formatting fixes: blank lines before list blocks and headings, autolink syntax for the PgDog URL (`<https://...>`), and a trailing newline at end of file.

### Removed

- **`tests/integration-test.sh`**
  - Removed unused `DB_PORT` and `TEST_APP_PASSWORD` variables.
  - Removed unused `assert_not_contains` helper.

### Added

- **`.markdownlint.json`** — repository markdownlint configuration disabling `MD013` (line length) and `MD033` (inline HTML), matching the conventions already used in `README.md`.

### Fixed

- **`tests/integration-test.sh`**
  - Added a scoped `# shellcheck disable=SC2317,SC2329` directive on the `cleanup` function so ShellCheck no longer warns about the trap handler not being explicitly invoked (code varies between ShellCheck versions).
- **`.markdownlint.json`**
  - Configured `MD024` with `siblings_only: true` to allow repeated `### Fixed`/`### Added`/`### Removed` headings across separate version sections in the changelog.

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
- **`.github/workflows/ci.yml`** — GitHub Actions CI pipeline with three jobs: ShellCheck (lints all shell scripts), markdownlint (lints README, CHANGELOG, AI_INSTRUCTIONS), and integration tests (runs the full 33-assertion suite on every push and pull request).

### Removed

- `pgdog/docker-composer.yml` (invalid fragment, replaced by root `docker-compose.yml`).
- `pgdog/pgdog-dynamic-config.Dockerfile` (the old filename had a trailing space, replaced by the same name without the trailing space).

## [0.1.0] - 2026-02-25

Initial release — deployed and tested.
