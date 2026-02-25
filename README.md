# pgdog-dynamic-config

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)
![Shell](https://img.shields.io/badge/shell-bash-green)
![PgDog](https://img.shields.io/badge/Made_for-PgDog-blue)
![Status](https://img.shields.io/badge/status-active-success)

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
- Runs every 5 minutes
- Reloads PgDog when configuration changes
- Runs as a lightweight sidecar container
- Depends on passthrough_auth for authentication
- Requires the postgres user to have access to all databases
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
The sidecar requires the following environment variables:

```yaml
  POSTGRES_PASSWORD: ${POSTGRES_PASSWORD} # for postgres db
  PGDOG_PASSWORD: ${PGDOG_PASSWORD} # for the Postgres
```
### Variable Description
- POSTGRES_PASSWORD — Password for the PostgreSQL superuser
- PGDOG_PASSWORD — Password used by PgDog for authentication

```yaml
environment:
  POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
  PGDOG_PASSWORD: ${PGDOG_PASSWORD}
```

# 🧩 Example Docker Compose Setup
Below is an example stack consisting of:
- PostgreSQL with logging enabled
- PgDog
- pgdog-dynamic-config sidecar

```yaml
services:
  db:
    container_name: db
    image: postgres:18.2-alpine3.22 # dhi.io/postgres:18.2-debian13
    user: ${USER_ID}:${GROUP_ID}
    volumes:
      - ./data:/var/lib/postgresql/data
      - ./logs:/var/lib/postgresql/data/log
    ports:
    - "5432:5432"
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      TZ: ${TZ}
    command: >
      postgres
        -c logging_collector=on
        -c log_directory='logs'
        -c log_filename='postgresql-%Y-%m-%d_%H%M%S.log'
        -c log_min_duration_statement=500
        -c log_line_prefix='%m [%p] %q%u@%d '
    healthcheck:
      test: ['CMD', 'pg_isready', '-U', 'postgres']
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
  
  pgdog:
    image: ghcr.io/pgdogdev/pgdog:main
    container_name: pgdog
    ports:
      - "6432:6432"
    volumes:
      - ./pgdog/pgdog.toml:/pgdog/pgdog.toml
      - ./pgdog/users.toml:/pgdog/users.toml
    depends_on:
      - db
    healthcheck:
      test: ["CMD", "pg_isready", "-h", "localhost", "-p", "6432"]
      interval: 10s
      timeout: 3s
      retries: 5

  pgdog-dynamic-config:
    build:
      context: ./pgdog
      dockerfile: pgdog-dynamic-config.Dockerfile
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      PGDOG_PASSWORD: ${PGDOG_PASSWORD}
    volumes:
      - ./pgdog:/pgdog
    depends_on:
      - db
```
## 🔐 Authentication Requirements
This setup assumes:
- PgDog is configured with passthrough_auth
- The postgres user has access to all databases
- The sidecar can connect to PostgreSQL using superuser credentials

# 🐶 PgDog

For more information about PgDog, visit:

https://github.com/pgdogdev/pgdog

📜 License

This project is licensed under the AGPL v3 license. See the LICENSE file for details